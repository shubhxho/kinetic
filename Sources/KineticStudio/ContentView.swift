//
//  ContentView.swift
//  Kinetic Studio
//
//  The window: a Liquid Glass transport bar, a dockable panel workspace, a
//  scrubbable timeline over recorded state, and a status bar. ⌘K opens the
//  command palette.
//
//  The layout itself lives in Panels/PanelLayout.swift — this file only decides
//  which view a given panel kind renders, so adding a panel type is a single
//  case here plus an entry in the catalogue.
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

    @State private var timelineVisible = true

    private var theme: StudioTheme { StudioTheme(isDark: model.isDark) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                PanelDivider()

                PanelHostView(store: panels) { instance in
                    panelContent(instance)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if timelineVisible {
                    PanelDivider()
                    TimelineBar(model: model)
                }

                PanelDivider()
                statusBar
            }

            if model.showCommandPalette {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { model.showCommandPalette = false }
                CommandPalette(model: model, isPresented: $model.showCommandPalette)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .background(theme.background)
        .environment(\.studioTheme, theme)
        .environment(\.foxgloveVocabulary, foxglove.vocabulary)
        .preferredColorScheme(model.isDark ? .dark : .light)
        .animation(.easeOut(duration: 0.12), value: model.showCommandPalette)
        .onAppear(perform: install)
    }

    // MARK: Wiring

    private func install() {
        model.applyAppearance()

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
        case .plot: TelemetryPanel(model: model)
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

    // MARK: Toolbar

    private var toolbar: some View {
        GlassBar {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    KineticMark().frame(width: 15, height: 15)
                    Text("Kinetic")
                        .font(Typo.title)
                        .foregroundStyle(theme.text)
                }

                Rectangle().fill(theme.border).frame(width: 1, height: 18)

                GlassButton(model.isPlaying ? "Pause" : "Play",
                            systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                            isActive: model.isPlaying) { model.togglePlayback() }
                GlassButton(systemImage: "forward.frame.fill") { model.stepOnce() }
                GlassButton(systemImage: "arrow.counterclockwise") { model.reset() }

                speedControl

                Rectangle().fill(theme.border).frame(width: 1, height: 18)

                GlassButton(systemImage: "viewfinder") { model.commands.frameScene() }
                layoutMenu

                Spacer(minLength: 8)

                paletteButton

                Spacer(minLength: 8)

                FoxgloveSwitch(controller: foxglove)

                GlassButton(systemImage: "folder") { openModel() }
                GlassButton(systemImage: model.isRecording ? "stop.circle.fill" : "record.circle",
                            isActive: model.isRecording) {
                    model.isRecording ? model.stopRecording() : startRecording()
                }
                GlassButton(systemImage: model.isDark ? "moon.fill" : "sun.max.fill") {
                    model.isDark.toggle()
                    model.applyAppearance()
                }
                GlassButton(systemImage: "rectangle.bottomthird.inset.filled",
                            isActive: timelineVisible) {
                    timelineVisible.toggle()
                }
            }
            .padding(.horizontal, Metric.gutter)
        }
        .frame(height: Metric.toolbarHeight)
    }

    private var paletteButton: some View {
        Button { model.showCommandPalette = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                Text(model.sceneTitle)
                    .font(Typo.small.weight(.medium))
                Text("⌘K")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(minWidth: 220)
            .glassSurface(cornerRadius: Metric.radius)
        }
        .buttonStyle(.plain)
    }

    private var layoutMenu: some View {
        Menu {
            ForEach(PanelLayoutPreset.builtins, id: \.name) { preset in
                Button(preset.name) { panels.apply(preset) }
            }
            Divider()
            Button("Split Right") { panels.splitFocusedRight() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Split Down") { panels.splitFocusedDown() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Close Panel") { panels.closeFocused() }
                .disabled(!panels.canCloseFocusedPanel)
            Divider()
            Button("Reset Layout") { panels.resetToDefault() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.split.2x2")
                    .font(.system(size: 11, weight: .semibold))
                Text(panels.activePresetName ?? "Custom")
                    .font(Typo.small.weight(.medium))
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassSurface(cornerRadius: Metric.radius)
    }

    private var speedControl: some View {
        GlassSegmentedControl([0.1, 0.25, 1.0, 2.0], selection: $model.timeScale) { scale in
            scale < 1 ? String(format: "%.2g×", scale) : "\(Int(scale))×"
        }
    }

    // MARK: Viewport

    @ViewBuilder
    private var viewport: some View {
        ZStack(alignment: .topLeading) {
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

                MeasurementTool(model: model, state: measurement)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 22))
                    Text("Metal is unavailable on this machine.").font(Typo.body)
                }
                .foregroundStyle(theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ViewportHUD(model: model)
                .padding(Metric.gutter)

            HStack {
                Spacer()
                VStack {
                    Spacer()
                    AxisGizmoView(model: model)
                        .padding(Metric.gutter)
                }
            }

            VStack {
                Spacer()
                HStack {
                    ViewportToolbar(model: model)
                        .padding(Metric.gutter)
                    Spacer()
                }
            }

            ScrubbingBanner(model: model)
            SelectionCallout(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isScrubbing ? Palette.warning
                                            : (model.isPlaying ? Palette.success : theme.tertiary))
                    .frame(width: 6, height: 6)
                Text(model.isScrubbing ? "reviewing" : (model.isPlaying ? "running" : "paused"))
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.secondary)
            }

            Text("\(model.world.coordinateCount) nq · \(model.world.dofCount) nv · "
                 + "\(model.world.linkCount) links · \(model.world.geomCount) geoms")
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)

            Spacer()

            FoxgloveStatusStrip(controller: foxglove)

            Text(String(format: "%.0f fps · %d instances", model.stats.frameRate,
                        model.stats.instanceCount))
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
            Text(World.versionString)
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: 24)
        .background(theme.background)
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
