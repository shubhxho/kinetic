//
//  ContentView.swift
//  Kinetic Studio
//
//  Window layout: transport toolbar, three resizable columns (scene tree,
//  viewport, inspector), a scrubbable timeline, a telemetry drawer, and a status
//  bar. ⌘K opens the command palette.
//

import AppKit
import Kinetic
import KineticRender
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = StudioModel()
    @State private var bottomHeight: CGFloat = 208
    @State private var bottomTab = BottomTab.telemetry

    enum BottomTab: String, CaseIterable {
        case telemetry = "Telemetry"
        case joints = "Joints"
        case actuators = "Actuators"
        case log = "Log"

        var systemImage: String {
            switch self {
            case .telemetry: return "waveform.path.ecg"
            case .joints: return "slider.horizontal.3"
            case .actuators: return "bolt.horizontal"
            case .log: return "text.alignleft"
            }
        }
    }

    private var theme: StudioTheme { StudioTheme(isDark: model.isDark) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                PanelDivider()

                HStack(spacing: 0) {
                    if model.showSidebar {
                        SceneTreePanel(model: model)
                            .frame(width: model.sidebarWidth)
                        ResizeHandle(axis: .horizontal) { delta in
                            model.sidebarWidth = min(max(model.sidebarWidth + delta, 190), 420)
                        }
                    }

                    viewport

                    if model.showInspector {
                        ResizeHandle(axis: .horizontal) { delta in
                            model.inspectorWidth = min(max(model.inspectorWidth - delta, 240), 460)
                        }
                        InspectorPanel(model: model)
                            .frame(width: model.inspectorWidth)
                    }
                }
                .frame(maxHeight: .infinity)

                PanelDivider()
                TimelineBar(model: model)

                if model.showBottomPanel {
                    ResizeHandle(axis: .vertical) { delta in
                        bottomHeight = min(max(bottomHeight - delta, 120), 560)
                    }
                    bottomPanel.frame(height: bottomHeight)
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
        .preferredColorScheme(model.isDark ? .dark : .light)
        .animation(.easeOut(duration: 0.12), value: model.showCommandPalette)
        .onAppear(perform: install)
    }

    private func install() {
        model.applyAppearance()
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

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                KineticMark().frame(width: 15, height: 15)
                Text("Kinetic")
                    .font(Typo.title)
                    .foregroundStyle(theme.text)
            }

            Rectangle().fill(theme.border).frame(width: 1, height: 18)

            ToolbarButton(systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                          label: model.isPlaying ? "Pause" : "Play",
                          isActive: model.isPlaying) { model.togglePlayback() }
            ToolbarButton(systemImage: "forward.frame.fill") { model.stepOnce() }
            ToolbarButton(systemImage: "arrow.counterclockwise") { model.reset() }

            speedControl

            Rectangle().fill(theme.border).frame(width: 1, height: 18)

            ToolbarButton(systemImage: "viewfinder") { model.commands.frameScene() }
            cameraPresets

            Spacer(minLength: 8)

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
                .frame(minWidth: 240)
                .overlay(RoundedRectangle(cornerRadius: Metric.radius)
                    .stroke(theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            ToolbarButton(systemImage: "folder") { openModel() }
            ToolbarButton(systemImage: model.isRecording ? "stop.circle.fill" : "record.circle",
                          isActive: model.isRecording,
                          tone: model.isRecording ? nil : Palette.danger) {
                model.isRecording ? model.stopRecording() : startRecording()
            }
            ToolbarButton(systemImage: "antenna.radiowaves.left.and.right",
                          isActive: model.bridgeIsRunning) { model.toggleBridge() }
            ToolbarButton(systemImage: model.isDark ? "moon.fill" : "sun.max.fill") {
                model.isDark.toggle()
                model.applyAppearance()
            }
            ToolbarButton(systemImage: "sidebar.left", isActive: model.showSidebar) {
                model.showSidebar.toggle()
            }
            ToolbarButton(systemImage: "sidebar.right", isActive: model.showInspector) {
                model.showInspector.toggle()
            }
            ToolbarButton(systemImage: "rectangle.bottomthird.inset.filled",
                          isActive: model.showBottomPanel) {
                model.showBottomPanel.toggle()
            }
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: Metric.toolbarHeight)
        .background(theme.background)
    }

    private var speedControl: some View {
        HStack(spacing: 2) {
            ForEach([0.1, 0.25, 1.0, 2.0], id: \.self) { scale in
                Button { model.timeScale = scale } label: {
                    Text(scale < 1 ? String(format: "%.2g×", scale) : "\(Int(scale))×")
                        .font(Typo.monoSmall)
                        .foregroundStyle(model.timeScale == scale ? .white : theme.secondary)
                        .frame(width: 32, height: 22)
                        .background(model.timeScale == scale ? theme.accent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: Metric.radius).stroke(theme.border, lineWidth: 1))
    }

    private var cameraPresets: some View {
        HStack(spacing: 2) {
            ForEach(CameraPreset.allCases, id: \.self) { preset in
                Button { model.commands.setCamera(preset) } label: {
                    Text(preset.rawValue.prefix(3).uppercased())
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.secondary)
                        .frame(width: 30, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: Metric.radius).stroke(theme.border, lineWidth: 1))
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
                    onStats: { model.stats = $0 },
                    onSelect: { model.selectedGeom = $0 },
                    onWillStep: { model.sample() })
                .id(ObjectIdentifier(model.world))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 22))
                    Text("Metal is unavailable on this machine.").font(Typo.body)
                }
                .foregroundStyle(theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            statOverlay
            axisGizmo
            if model.isScrubbing { scrubbingBanner }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statOverlay: some View {
        HStack(spacing: 6) {
            StatTile(label: "time", value: String(format: "%.2f", model.displayTime), unit: "s")
            StatTile(label: "realtime", value: String(format: "%.2f", model.stats.realtimeFactor),
                     unit: "×",
                     tone: model.stats.realtimeFactor >= 0.95 ? Palette.success : Palette.warning)
            StatTile(label: "step", value: String(format: "%.2f", model.stats.stepMilliseconds),
                     unit: "ms")
            StatTile(label: "contacts", value: "\(model.stats.contactCount)")
            StatTile(label: "fps", value: String(format: "%.0f", model.stats.frameRate))
        }
        .frame(width: 560)
        .padding(Metric.gutter)
        .allowsHitTesting(false)
    }

    private var scrubbingBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("Reviewing history — the simulation is paused")
                    .font(Typo.small.weight(.medium))
                Button("Jump to live") { model.resumeLive() }
                    .buttonStyle(.plain)
                    .font(Typo.small.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.warning.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .foregroundStyle(Palette.warning)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Metric.radius)
                .stroke(Palette.warning.opacity(0.4), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Metric.radius))
            .padding(.bottom, Metric.gutter)
        }
        .frame(maxWidth: .infinity)
    }

    /// Orientation reference in the corner; Kinetic is Z-up.
    private var axisGizmo: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    let camera = model.commands.camera
                    let azimuth = Double(camera?.azimuth ?? -0.9)
                    let elevation = Double(camera?.elevation ?? 0.42)
                    let length = min(size.width, size.height) * 0.36

                    // Project each world axis through the camera's yaw/pitch.
                    func project(_ v: (Double, Double, Double)) -> CGPoint {
                        let x = v.0 * cos(-azimuth) - v.1 * sin(-azimuth)
                        let y = v.0 * sin(-azimuth) + v.1 * cos(-azimuth)
                        let screenX = x
                        let screenY = -(v.2 * cos(elevation) - y * sin(elevation))
                        return CGPoint(x: centre.x + screenX * length,
                                       y: centre.y + screenY * length)
                    }

                    let axes: [((Double, Double, Double), Color, String)] = [
                        ((1, 0, 0), Color(red: 0.94, green: 0.27, blue: 0.34), "X"),
                        ((0, 1, 0), Color(red: 0.20, green: 0.80, blue: 0.45), "Y"),
                        ((0, 0, 1), Color(red: 0.20, green: 0.55, blue: 1.00), "Z"),
                    ]
                    for (vector, color, label) in axes {
                        let tip = project(vector)
                        var path = Path()
                        path.move(to: centre)
                        path.addLine(to: tip)
                        context.stroke(path, with: .color(color),
                                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        context.fill(Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5,
                                                            width: 10, height: 10)),
                                     with: .color(color))
                        context.draw(Text(label).font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white), at: tip)
                    }
                }
                .frame(width: 74, height: 74)
                .background(theme.surface.opacity(0.75))
                .clipShape(Circle())
                .overlay(Circle().stroke(theme.borderSubtle, lineWidth: 1))
                .padding(Metric.gutter)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(BottomTab.allCases, id: \.self) { tab in
                    Button { bottomTab = tab } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.systemImage).font(.system(size: 10))
                            Text(tab.rawValue)
                                .font(Typo.small.weight(bottomTab == tab ? .semibold : .regular))
                        }
                        .foregroundStyle(bottomTab == tab ? theme.text : theme.tertiary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(bottomTab == tab ? theme.surface : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if model.isRecording {
                    HStack(spacing: 5) {
                        Circle().fill(Palette.danger).frame(width: 6, height: 6)
                        Text("recording · \(model.recordedFrames) frames")
                            .font(Typo.monoSmall)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.top, 6)

            switch bottomTab {
            case .telemetry: TelemetryPanel(model: model)
            case .joints: JointPanel(model: model)
            case .actuators: ActuatorPanel(model: model)
            case .log: ConsolePanel(model: model)
            }
        }
        .background(theme.background)
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

            if model.bridgeIsRunning {
                HStack(spacing: 5) {
                    Circle().fill(Palette.success).frame(width: 5, height: 5)
                    Text("ws://localhost:\(model.bridgePort) · \(model.bridgeConnections) client\(model.bridgeConnections == 1 ? "" : "s")")
                        .font(Typo.monoSmall)
                        .foregroundStyle(Palette.success)
                }
            }
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

/// Draggable splitter between panes.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }

    @Environment(\.studioTheme) private var theme
    let axis: Axis
    let onDrag: (CGFloat) -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(hovering ? theme.accent.opacity(0.6) : theme.border)
            Rectangle()
                .fill(Color.clear)
                .frame(width: axis == .horizontal ? 9 : nil,
                       height: axis == .vertical ? 9 : nil)
                .contentShape(Rectangle())
        }
        .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
        .overlay(
            Rectangle()
                .fill(Color.clear)
                .frame(width: axis == .horizontal ? 9 : nil,
                       height: axis == .vertical ? 9 : nil)
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    if inside {
                        (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
                            .push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            onDrag(axis == .horizontal ? value.translation.width
                                                       : value.translation.height)
                        })
        )
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
