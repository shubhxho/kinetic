//
//  ContentView.swift
//  Kinetic Studio
//
//  The window, assembled from SwiftUI's own shell: `NavigationSplitView` for the
//  sidebar, `.inspector` for the trailing pane, `.toolbar` for the transport
//  controls, and `.safeAreaInset` for the timeline and status bar.
//
//  Using the real shell rather than nesting HStacks is what gets the sidebar
//  toggle, the traffic-light inset, column widths the window remembers,
//  full-screen behaviour and Reduce Motion — none of which a hand-built
//  three-column layout provides.
//

import AppKit
import Kinetic
import KineticBridge
import KineticRender
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = StudioModel()
    @StateObject private var panels = PanelLayoutStore()
    @StateObject private var foxglove = FoxgloveModeController()
    @StateObject private var measurement = MeasurementState()

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var inspectorPresented = true
    @State private var timelineVisible = true

    private var theme: StudioTheme { StudioTheme(isDark: model.isDark) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SceneTreePanel(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 248, max: 420)
        } detail: {
            // A plain stack, not `.safeAreaInset`. The inset modifier resolves an
            // alignment guide against the inset content every layout pass, and
            // resolving a guide through the panel tree forces a full placement of
            // every pane — the profile was almost entirely nested
            // `explicitAlignment` recursion. Stacking the bars costs nothing and
            // the viewport does not need to draw underneath them.
            VStack(spacing: 0) {
                PanelHostView(store: panels) { instance in
                    panelContent(instance)
                }
                if timelineVisible {
                    Divider()
                    TimelineBar(model: model)
                }
                Divider()
                statusBar
            }
        }
        .navigationTitle(model.sceneTitle)
        .navigationSubtitle("\(model.world.dofCount) dof · \(model.world.linkCount) links")
        .toolbar { toolbarContent }
        .inspector(isPresented: $inspectorPresented) {
            InspectorPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 460)
        }
        .background(theme.background)
        .environmentObject(model.live)
        .environment(\.studioTheme, theme)
        .environment(\.foxgloveVocabulary, foxglove.vocabulary)
        .preferredColorScheme(model.isDark ? .dark : .light)
        .onAppear(perform: install)
        .sheet(isPresented: $model.showCommandPalette) {
            CommandPalette(model: model, isPresented: $model.showCommandPalette)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.togglePlayback()
            } label: {
                Label(model.isPlaying ? "Pause" : "Play",
                      systemImage: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .help(model.isPlaying ? "Pause the simulation" : "Run the simulation")

            Button {
                model.stepOnce()
            } label: {
                Label("Step", systemImage: "forward.frame.fill")
            }
            .help("Advance one timestep")

            Button {
                model.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Return to the model's default pose")
        }

        ToolbarItem(placement: .principal) {
            Picker("Speed", selection: $model.timeScale) {
                Text("0.1×").tag(0.1)
                Text("0.25×").tag(0.25)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
            }
            .pickerStyle(.segmented)
            .help("Simulation speed relative to wall clock")
        }

        ToolbarItem {
            Menu {
                ForEach(PanelLayoutPreset.builtins, id: \.name) { preset in
                    Button(preset.name) { panels.apply(preset) }
                }
                Divider()
                Button("Split Right") { panels.splitFocusedRight() }
                Button("Split Down") { panels.splitFocusedDown() }
                Button("Close Panel") { panels.closeFocused() }
                    .disabled(!panels.canCloseFocusedPanel)
                Divider()
                Button("Reset Layout") { panels.resetToDefault() }
            } label: {
                Label(panels.activePresetName ?? "Custom", systemImage: "rectangle.split.2x2")
            }
            .help("Workspace layout")
        }

        ToolbarItem {
            Button { model.commands.frameScene() } label: {
                Label("Frame", systemImage: "viewfinder")
            }
            .help("Fit the camera to the model")
        }

        ToolbarItem { FoxgloveSwitch(controller: foxglove) }

        ToolbarItemGroup {
            Button { model.showCommandPalette = true } label: {
                Label("Commands", systemImage: "magnifyingglass")
            }
            .help("Command palette (⌘K)")

            Button { openModel() } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Import a URDF or MJCF model")

            Button {
                model.isRecording ? model.stopRecording() : startRecording()
            } label: {
                Label(model.isRecording ? "Stop recording" : "Record",
                      systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .help(model.isRecording ? "Finish the recording" : "Record to a .kinlog")

            Toggle(isOn: $model.isDark) {
                Label("Appearance", systemImage: model.isDark ? "moon.fill" : "sun.max.fill")
            }
            .onChange(of: model.isDark) { _, _ in model.applyAppearance() }
            .help("Switch between light and dark")

            Toggle(isOn: $timelineVisible) {
                Label("Timeline", systemImage: "rectangle.bottomthird.inset.filled")
            }
            .help("Show the timeline")
        }
    }

    // MARK: Wiring

    private func install() {
        model.applyAppearance()
        // Starts the run at launch. Only used for measuring: the window's idle
        // and running costs are very different numbers, and driving the transport
        // through the UI to reach the second one is not something a profiler can
        // do on its own.
        if ProcessInfo.processInfo.environment["KINETIC_AUTOPLAY"] != nil {
            model.isPlaying = true
        }

        // The Foxglove controller owns the switch but not the simulation, so it
        // reaches back through closures rather than holding the model.
        foxglove.onStartServer = { port in
            model.bridgePort = port
            model.startBridge()
        }
        foxglove.onStopServer = { model.stopBridge() }
        foxglove.onLog = { model.log("foxglove: \($0)") }
        foxglove.onApplyWorkspace = { workspace in
            panels.apply(workspace == .foxglove ? .foxglove : .default)
        }

        NotificationCenter.default.addObserver(forName: .studioOpenModel, object: nil,
                                               queue: .main) { _ in openModel() }
        NotificationCenter.default.addObserver(forName: .studioToggleRecording, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                model.isRecording ? model.stopRecording() : startRecording()
            }
        }
        NotificationCenter.default.addObserver(forName: .studioShowCommandPalette, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { model.showCommandPalette.toggle() }
        }
    }

    // MARK: Panel content

    /// Maps a panel kind onto a view. This is the only place that knows both
    /// halves, which is why the layout engine and the panels can evolve apart.
    @ViewBuilder
    private func panelContent(_ instance: PanelInstance) -> some View {
        switch instance.kind {
        case .viewport3D: viewport
        case .plot: TelemetryPanel(model: model, plots: model.plots)
        case .rawMessages: RawMessagesPanel(model: model)
        case .table: TablePanel(model: model)
        case .stateTransitions: StateTransitionsPanel(model: model)
        case .diagnostics: DiagnosticsPanel(model: model)
        case .log: ConsolePanel(model: model)
        case .jointControl: JointPanel(model: model)
        case .actuatorControl: ActuatorPanel(model: model)
        case .sceneTree: SceneTreePanel(model: model)
        case .inspector: InspectorPanel(model: model)
        case .mlInsights: MLInsightsPanel(model: model)
        }
    }

    // MARK: Viewport

    @ViewBuilder
    private var viewport: some View {
        if let renderer = model.renderer {
            SimulationViewport(
                world: model.world,
                renderer: renderer,
                settings: $model.settings,
                isPlaying: $model.isPlaying,
                timeScale: $model.timeScale,
                commands: model.commands,
                onStats: { model.publish(stats: $0) },
                onSelect: { model.selectedGeom = $0 },
                onWillStep: { model.sample() })
            .id(ObjectIdentifier(model.world))
            .overlay { MeasurementTool(model: model, state: measurement) }
            .overlay(alignment: .topLeading) {
                ViewportHUD(model: model).padding(Metric.gutter)
            }
            .overlay(alignment: .bottomLeading) {
                ViewportToolbar(model: model).padding(Metric.gutter)
            }
            .overlay(alignment: .bottomTrailing) {
                AxisGizmoView(model: model).padding(Metric.gutter)
            }
            .overlay(alignment: .bottom) { ScrubbingBanner(model: model) }
            .overlay(alignment: .top) { SelectionCallout(model: model) }
        } else {
            ContentUnavailableView("Metal is unavailable",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("This machine has no usable GPU, so the "
                                                     + "viewport cannot render. The CLI's "
                                                     + "headless renderer still works."))
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label {
                Text(model.isScrubbing ? "reviewing" : (model.isPlaying ? "running" : "paused"))
                    .font(Typo.monoSmall)
            } icon: {
                Circle()
                    .fill(model.isScrubbing ? Palette.warning
                                            : (model.isPlaying ? Palette.success : theme.tertiary))
                    .frame(width: 6, height: 6)
            }
            .foregroundStyle(theme.secondary)

            Text("\(model.world.coordinateCount) nq · \(model.world.dofCount) nv · "
                 + "\(model.world.linkCount) links · \(model.world.geomCount) geoms")
                .font(Typo.monoSmall)
                .monospacedDigit()
                .foregroundStyle(theme.tertiary)

            Spacer()

            FoxgloveStatusStrip(controller: foxglove)

            FrameRateReadout()
            Text(World.versionString)
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: 24)
        .background(.bar)
        .onChange(of: model.bridgeConnections) { _, count in
            foxglove.updateServerConnections(count)
        }
    }

    // MARK: Actions

    private func openModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "urdf") ?? .xml,
            UTType(filenameExtension: "xml") ?? .xml,
            .xml,
        ]
        panel.message = "Choose a URDF or MJCF model"
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url: url)
        }
    }

    private func startRecording() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.sceneIdentifier).kinlog"
        panel.message = "Where should the recording be written?"
        if panel.runModal() == .OK, let url = panel.url {
            model.startRecording(to: url)
        }
    }
}

extension Notification.Name {
    static let studioOpenModel = Notification.Name("studio.openModel")
    static let studioToggleRecording = Notification.Name("studio.toggleRecording")
    static let studioShowCommandPalette = Notification.Name("studio.showCommandPalette")
}

/// The wordmark glyph: three stacked bars sheared into motion.
struct KineticMark: View {
    @Environment(\.studioTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            Path { path in
                for i in 0..<3 {
                    let y = h * (0.12 + Double(i) * 0.32)
                    let inset = w * (0.06 + Double(i) * 0.14)
                    path.move(to: CGPoint(x: inset, y: y))
                    path.addLine(to: CGPoint(x: w * 0.94, y: y))
                }
            }
            .stroke(theme.text, style: StrokeStyle(lineWidth: max(w * 0.11, 1), lineCap: .round))
        }
    }
}

/// The frame-rate figure in the status bar.
///
/// Its own view so that the ten-times-a-second stats update invalidates a single
/// `Text` rather than the window's whole status bar.
private struct FrameRateReadout: View {
    @Environment(\.studioTheme) private var theme
    @EnvironmentObject private var live: LiveStats

    var body: some View {
        // Fixed width: a status figure that resizes as it changes invalidates the
        // layout of everything around it.
        Text(live.value.frameRate, format: .number.precision(.fractionLength(0)))
            .font(Typo.monoSmall)
            .monospacedDigit()
            .foregroundStyle(theme.tertiary)
            .frame(width: 26, alignment: .trailing)
    }
}
