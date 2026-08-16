//
//  ContentView.swift
//  Kinetic Studio
//
//  Window layout: a transport toolbar, a three-column body (scene tree,
//  viewport, inspector), a resizable telemetry drawer, and a status bar.
//

import AppKit
import Kinetic
import KineticRender
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = StudioModel()
    @State private var bottomHeight: CGFloat = 210
    @State private var bottomTab = BottomTab.telemetry

    enum BottomTab: String, CaseIterable {
        case telemetry = "Telemetry"
        case actuators = "Actuators"
        case log = "Log"
    }

    private var theme: StudioTheme { StudioTheme(isDark: model.isDark) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            PanelDivider()

            HStack(spacing: 0) {
                if model.showSidebar {
                    SceneTreePanel(model: model)
                    VerticalDivider()
                }

                viewport

                if model.showInspector {
                    VerticalDivider()
                    InspectorPanel(model: model)
                }
            }
            .frame(maxHeight: .infinity)

            if model.showBottomPanel {
                resizeHandle
                bottomPanel
                    .frame(height: bottomHeight)
            }

            PanelDivider()
            statusBar
        }
        .background(theme.background)
        .environment(\.studioTheme, theme)
        .preferredColorScheme(model.isDark ? .dark : .light)
        .onAppear {
            model.applyAppearance()
            NotificationCenter.default.addObserver(forName: .studioOpenModel, object: nil,
                                                  queue: .main) { _ in
                openModel()
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                KineticMark()
                    .frame(width: 16, height: 16)
                Text("Kinetic")
                    .font(Typo.title)
                    .foregroundStyle(theme.text)
                Text("Studio")
                    .font(Typo.title.weight(.regular))
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.trailing, 4)

            Rectangle().fill(theme.border).frame(width: 1, height: 18)

            ToolbarButton(systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                          label: model.isPlaying ? "Pause" : "Play",
                          isActive: model.isPlaying) {
                model.isPlaying.toggle()
            }
            ToolbarButton(systemImage: "forward.frame.fill") { model.stepOnce() }
            ToolbarButton(systemImage: "arrow.counterclockwise") { model.reset() }

            speedControl

            Rectangle().fill(theme.border).frame(width: 1, height: 18)

            ToolbarButton(systemImage: "viewfinder", label: "Frame") { model.commands.frameScene() }
            cameraPresets

            Spacer(minLength: 8)

            Text(model.sceneTitle)
                .font(Typo.small.weight(.medium))
                .foregroundStyle(theme.secondary)
            Chip(text: "\(model.world.dofCount) dof")
            Chip(text: "\(model.world.geomCount) geoms")

            Spacer(minLength: 8)

            ToolbarButton(systemImage: "folder", label: "Open") { openModel() }
            ToolbarButton(systemImage: model.isRecording ? "stop.circle.fill" : "record.circle",
                          label: model.isRecording ? "Stop" : "Record",
                          isActive: model.isRecording,
                          tone: model.isRecording ? nil : Palette.danger) {
                model.isRecording ? model.stopRecording() : startRecording()
            }
            ToolbarButton(systemImage: "antenna.radiowaves.left.and.right",
                          isActive: model.bridgeIsRunning) {
                model.toggleBridge()
            }
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
                Button {
                    model.timeScale = scale
                } label: {
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
        .overlay(RoundedRectangle(cornerRadius: Metric.radius)
            .stroke(theme.border, lineWidth: 1))
    }

    private var cameraPresets: some View {
        HStack(spacing: 2) {
            ForEach(CameraPreset.allCases, id: \.self) { preset in
                Button {
                    model.commands.setCamera(preset)
                } label: {
                    Text(preset.rawValue.prefix(3).uppercased())
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.secondary)
                        .frame(width: 30, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: Metric.radius)
            .stroke(theme.border, lineWidth: 1))
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
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                    Text("Metal is unavailable on this machine.")
                        .font(Typo.body)
                }
                .foregroundStyle(theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            viewportOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var viewportOverlay: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatTile(label: "time", value: String(format: "%.2f", model.stats.simulationTime),
                             unit: "s")
                    StatTile(label: "realtime",
                             value: String(format: "%.2f", model.stats.realtimeFactor), unit: "×",
                             tone: model.stats.realtimeFactor >= 0.95 ? Palette.success
                                                                      : Palette.warning)
                    StatTile(label: "step",
                             value: String(format: "%.2f", model.stats.stepMilliseconds), unit: "ms")
                    StatTile(label: "contacts", value: "\(model.stats.contactCount)")
                }
                .frame(width: 460)
            }
            Spacer()
        }
        .padding(Metric.gutter)
        .allowsHitTesting(false)
    }

    // MARK: Bottom panel

    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(theme.border).frame(height: 1)
            Rectangle().fill(Color.clear).frame(height: 7).contentShape(Rectangle())
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    bottomHeight = max(110, min(520, bottomHeight - value.translation.height))
                })
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(BottomTab.allCases, id: \.self) { tab in
                    Button {
                        bottomTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(Typo.small.weight(bottomTab == tab ? .semibold : .regular))
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
                        Text("recording \(model.recordedFrames) frames")
                            .font(Typo.monoSmall)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.top, 6)

            switch bottomTab {
            case .telemetry: TelemetryPanel(model: model)
            case .actuators: ActuatorPanel(model: model)
            case .log: ConsolePanel(model: model)
            }
        }
        .background(theme.background)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label {
                Text(model.isPlaying ? "running" : "paused")
                    .font(Typo.monoSmall)
            } icon: {
                Circle()
                    .fill(model.isPlaying ? Palette.success : theme.tertiary)
                    .frame(width: 6, height: 6)
            }
            .foregroundStyle(theme.secondary)

            Text("\(model.world.coordinateCount) nq · \(model.world.dofCount) nv · "
                 + "\(model.world.linkCount) links")
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)

            Spacer()

            if model.bridgeIsRunning {
                Text("ws://localhost:\(model.bridgePort) · \(model.bridgeConnections) client\(model.bridgeConnections == 1 ? "" : "s")")
                    .font(Typo.monoSmall)
                    .foregroundStyle(Palette.success)
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

extension Notification.Name {
    static let studioOpenModel = Notification.Name("studio.openModel")
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
