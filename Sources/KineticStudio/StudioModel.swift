//
//  StudioModel.swift
//  Kinetic Studio
//
//  Application state: the world under inspection, render settings, live plot
//  channels, recording, and the telemetry bridge. The simulation itself is
//  stepped by the viewport's display link, so everything here observes state
//  that is already on the main thread.
//

import Combine
import Foundation
import QuartzCore
import Kinetic
import KineticBridge
import KineticRender
import SwiftUI

// MARK: - Plot channels

/// A fixed-capacity ring buffer of (time, value) samples.
struct PlotSeries: Identifiable {
    let id = UUID()
    var channel: LiveChannel
    var color: Color
    private(set) var times: [Double] = []
    private(set) var values: [Double] = []
    private let capacity: Int
    private var head = 0

    init(channel: LiveChannel, color: Color, capacity: Int = 3000) {
        self.channel = channel
        self.color = color
        self.capacity = capacity
        times.reserveCapacity(capacity)
        values.reserveCapacity(capacity)
    }

    mutating func append(time: Double, value: Double) {
        if times.count < capacity {
            times.append(time)
            values.append(value)
        } else {
            times[head] = time
            values[head] = value
            head = (head + 1) % capacity
        }
    }

    mutating func clear() {
        times.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Samples in chronological order, oldest first.
    var ordered: [(t: Double, v: Double)] {
        guard times.count == capacity else {
            return zip(times, values).map { ($0, $1) }
        }
        var out: [(Double, Double)] = []
        out.reserveCapacity(capacity)
        for i in 0..<capacity {
            let index = (head + i) % capacity
            out.append((times[index], values[index]))
        }
        return out
    }

    var latest: Double { values.isEmpty ? 0 : values[(head - 1 + values.count) % values.count] }
}

/// Something in the running world that can be plotted.
struct LiveChannel: Hashable, Identifiable {
    enum Source: Hashable {
        case position(Int)
        case velocity(Int)
        case control(Int)
        case actuatorForce(Int)
        case sensor(Int)
        case stepTime
        case contactCount
        case solverResidual
        case totalEnergy
        case comHeight
    }

    var source: Source
    var label: String
    var id: Source { source }

    func value(in world: World) -> Double {
        switch source {
        case .position(let i): return i < world.coordinateCount ? world.positions[i] : 0
        case .velocity(let i): return i < world.dofCount ? world.velocities[i] : 0
        case .control(let i): return i < world.actuatorCount ? world.control[i] : 0
        case .actuatorForce(let i): return i < world.actuatorCount ? world.actuatorForces[i] : 0
        case .sensor(let i): return i < world.sensorDataCount ? world.sensorReadings[i] : 0
        case .stepTime: return world.profile.total
        case .contactCount: return Double(world.profile.contactCount)
        case .solverResidual: return world.profile.solverResidual
        case .totalEnergy: return world.totalEnergy
        case .comHeight: return world.centerOfMass.z
        }
    }
}

struct ConsoleLine: Identifiable {
    enum Level {
        case info, success, warning, error
    }
    let id = UUID()
    let time: Date
    let level: Level
    let text: String
}

// MARK: - Model

@MainActor
final class StudioModel: ObservableObject {
    @Published var world: World
    @Published var settings = RenderSettings()
    @Published var isPlaying = false
    @Published var timeScale: Double = 1.0
    @Published var stats = ViewportStats()
    @Published var selectedGeom: Int?
    @Published var sceneTitle = "6-DOF arm"
    @Published var sceneIdentifier = "arm"
    @Published var console: [ConsoleLine] = []
    @Published var series: [PlotSeries] = []
    @Published var availableChannels: [LiveChannel] = []
    @Published var isDark = true
    @Published var bridgePort: UInt16 = 8765
    @Published var bridgeConnections = 0
    @Published var isRecording = false
    @Published var recordedFrames = 0
    @Published var showInspector = true
    @Published var showSidebar = true
    @Published var showBottomPanel = true
    @Published var plotWindowSeconds: Double = 8
    /// Bumped whenever the world's state is discontinuous — a reset or a new
    /// model. Panels that hold a baseline (energy drift, sparklines) rebase on a
    /// change rather than trying to infer one from a time discontinuity, which
    /// a scrub also produces.
    @Published private(set) var resetGeneration = 0
    @Published var isScrubbing = false
    @Published var scrubIndex = 0
    @Published var showCommandPalette = false
    @Published var sidebarWidth: Double = Double(Metric.sidebarWidth)
    @Published var inspectorWidth: Double = Double(Metric.inspectorWidth)

    /// Rolling window of past states; the timeline scrubs through this.
    let history = StateHistory()

    let renderer: Renderer?
    let commands = ViewportCommands()

    /// Wall-clock time of the last published stats update.
    private var lastStatsPublish: CFTimeInterval = 0
    private var liveState: [Double]?
    private var bridge: FoxgloveBridge?
    private var recorder: LogRecorder?
    private var bridgeTimer: Timer?

    init() {
        renderer = Renderer(sampleCount: 4)
        world = SceneLibrary.articulatedArm()
        settings.theme = .dark
        log("Kinetic Studio ready — \(World.versionString)", .success)
        if renderer == nil {
            log("no Metal device available; the viewport is disabled", .error)
        }
        rebuildChannels()
        applyDefaultPlots()
        history.configure(for: world)
    }

    var bridgeIsRunning: Bool { bridge?.isRunning ?? false }

    /// Publishes viewport statistics at a bounded rate.
    ///
    /// The viewport produces these every rendered frame, and assigning a
    /// `@Published` property that often makes SwiftUI re-evaluate every panel in
    /// the workspace — several of which snapshot the entire world state to build
    /// their rows. A readout of step time and contact count does not need to be
    /// fresher than 10 Hz, and the difference is most of a CPU core.
    func publish(stats newStats: ViewportStats) {
        let now = CACurrentMediaTime()
        guard now - lastStatsPublish >= 0.1 else { return }
        lastStatsPublish = now
        stats = newStats
    }

    /// The time shown in the UI: the playhead while scrubbing, otherwise live.
    var displayTime: Double {
        isScrubbing && !history.isEmpty ? history.frame(at: scrubIndex).time : stats.simulationTime
    }

    // MARK: Scene management

    func load(sceneIdentifier id: String) {
        guard let entry = SceneLibrary.all.first(where: { $0.id == id }) else { return }
        let built = entry.build()
        adopt(built, title: entry.title, identifier: id)
        log("loaded scene \(entry.title)", .info)
    }

    func load(url: URL) {
        do {
            let loaded: World
            switch url.pathExtension.lowercased() {
            case "urdf":
                loaded = try URDF.load(contentsOf: url).world
            case "xml", "mjcf":
                loaded = try MJCF.load(contentsOf: url).world
            default:
                let data = try Data(contentsOf: url)
                let head = String(data: data.prefix(4096), encoding: .utf8) ?? ""
                if head.contains("<mujoco") {
                    loaded = try MJCF.load(data: data).world
                } else if head.contains("<robot") {
                    loaded = try URDF.load(data: data).world
                } else {
                    log("unrecognised model format: \(url.lastPathComponent)", .error)
                    return
                }
            }
            adopt(loaded, title: url.deletingPathExtension().lastPathComponent,
                  identifier: url.path)
            log("imported \(url.lastPathComponent) — \(loaded.linkCount) links, "
                + "\(loaded.dofCount) dof", .success)
        } catch {
            log("import failed: \(error)", .error)
        }
    }

    private func adopt(_ newWorld: World, title: String, identifier: String) {
        stopRecording()
        world = newWorld
        sceneTitle = title
        sceneIdentifier = identifier
        selectedGeom = nil
        settings.selection = []
        rebuildChannels()
        applyDefaultPlots()
        history.configure(for: newWorld)
        resetGeneration += 1
        isScrubbing = false
        scrubIndex = 0
        if let bridge, bridge.isRunning {
            stopBridge()
            startBridge()
        }
        commands.frameScene()
    }

    func reset() {
        world.reset()
        resetGeneration += 1
        for index in series.indices { series[index].clear() }
        history.clear()
        isScrubbing = false
        scrubIndex = 0
        log("state reset", .info)
    }

    func stepOnce() {
        if isScrubbing { resumeLive() }
        commands.singleStep()
    }

    func togglePlayback() {
        if isScrubbing { resumeLive() }
        isPlaying.toggle()
    }

    // MARK: Scrubbing

    /// Moves the playhead into the recorded window and pauses the simulation.
    func scrub(toIndex index: Int) {
        guard history.count > 0 else { return }
        let clamped = max(0, min(index, history.count - 1))
        if !isScrubbing {
            liveState = world.saveState()
            isScrubbing = true
            isPlaying = false
        }
        scrubIndex = clamped
        history.restore(clamped, into: world)
    }

    func scrub(toFraction fraction: Double) {
        guard history.count > 1 else { return }
        scrub(toIndex: Int((Double(history.count - 1) * fraction).rounded()))
    }

    /// Returns to the newest state and hands control back to the simulation.
    func resumeLive() {
        guard isScrubbing else { return }
        if let liveState { world.loadState(liveState) }
        liveState = nil
        isScrubbing = false
        scrubIndex = max(history.count - 1, 0)
    }

    // MARK: Channels

    func rebuildChannels() {
        var channels: [LiveChannel] = []
        channels.append(LiveChannel(source: .stepTime, label: "step time (ms)"))
        channels.append(LiveChannel(source: .contactCount, label: "contacts"))
        channels.append(LiveChannel(source: .totalEnergy, label: "total energy (J)"))
        channels.append(LiveChannel(source: .comHeight, label: "com height (m)"))
        channels.append(LiveChannel(source: .solverResidual, label: "solver residual"))

        var sensorIndex = 0
        for (i, name) in world.sensorNames.enumerated() {
            let dimension = i < world.sensorKinds.count ? world.sensorKinds[i].dimension : 1
            for k in 0..<dimension {
                let suffix = dimension == 1 ? "" : ".\(["x", "y", "z", "w"][min(k, 3)])"
                channels.append(LiveChannel(source: .sensor(sensorIndex),
                                            label: "\(name)\(suffix)"))
                sensorIndex += 1
            }
        }
        for i in 0..<world.actuatorCount {
            channels.append(LiveChannel(source: .control(i), label: "ctrl[\(i)]"))
            channels.append(LiveChannel(source: .actuatorForce(i), label: "force[\(i)]"))
        }
        for i in 0..<min(world.dofCount, 64) {
            channels.append(LiveChannel(source: .velocity(i), label: "qvel[\(i)]"))
        }
        for i in 0..<min(world.coordinateCount, 64) {
            channels.append(LiveChannel(source: .position(i), label: "qpos[\(i)]"))
        }
        availableChannels = channels
    }

    private func applyDefaultPlots() {
        series.removeAll()
        let defaults: [LiveChannel] = [
            LiveChannel(source: .stepTime, label: "step time (ms)"),
            LiveChannel(source: .contactCount, label: "contacts"),
            LiveChannel(source: .comHeight, label: "com height (m)"),
        ]
        for (i, channel) in defaults.enumerated() {
            series.append(PlotSeries(channel: channel,
                                     color: Palette.series[i % Palette.series.count]))
        }
    }

    func addPlot(_ channel: LiveChannel) {
        guard !series.contains(where: { $0.channel == channel }) else { return }
        series.append(PlotSeries(channel: channel,
                                 color: Palette.series[series.count % Palette.series.count]))
    }

    func removePlot(_ id: UUID) {
        series.removeAll { $0.id == id }
    }

    /// Called once per simulated step from the viewport.
    func sample() {
        guard !isScrubbing else { return }
        let time = world.time
        for index in series.indices {
            series[index].append(time: time, value: series[index].channel.value(in: world))
        }
        history.record(world)
        scrubIndex = max(history.count - 1, 0)
        recorder?.record(world)
        if recorder != nil { recordedFrames += 1 }
        bridge?.publishIfNeeded()
    }

    // MARK: Joint control

    struct JointHandle: Identifiable {
        var id: Int { coordinateIndex }
        var name: String
        var articulation: Int
        var link: Int
        var coordinateIndex: Int
        var dofIndex: Int
        var kind: JointKind
        var limits: ClosedRange<Double>
    }

    /// Every scalar joint in the model, ready to pose directly.
    func jointHandles() -> [JointHandle] {
        var out: [JointHandle] = []
        for articulation in 0..<world.articulationCount {
            let qOffset = world.coordinateOffset(articulation: articulation)
            let vOffset = world.dofOffset(articulation: articulation)
            for link in 0..<world.linkCount(articulation: articulation) {
                let kind = world.jointKind(articulation: articulation, link: link)
                guard kind == .revolute || kind == .prismatic else { continue }
                let limits = world.jointLimits(articulation: articulation, link: link)
                    ?? (kind == .revolute ? -Double.pi...Double.pi : -1.0...1.0)
                out.append(JointHandle(
                    name: world.name(articulation: articulation, link: link),
                    articulation: articulation, link: link,
                    coordinateIndex: qOffset
                        + world.jointCoordinateIndex(articulation: articulation, link: link),
                    dofIndex: vOffset + world.jointDofIndex(articulation: articulation, link: link),
                    kind: kind, limits: limits))
            }
        }
        return out
    }

    func setJoint(_ handle: JointHandle, to value: Double) {
        guard handle.coordinateIndex < world.coordinateCount else { return }
        world.positions[handle.coordinateIndex] = value
        world.velocities[handle.dofIndex] = 0
        world.forward()
        objectWillChange.send()
    }

    // MARK: Commands

    func commandList() -> [StudioCommand] {
        var commands: [StudioCommand] = []

        for entry in SceneLibrary.all {
            commands.append(StudioCommand(
                title: "Open \(entry.title)", subtitle: entry.summary, category: .scene,
                systemImage: "cube.transparent", shortcut: nil,
                action: { [weak self] in self?.load(sceneIdentifier: entry.id) }))
        }

        commands.append(contentsOf: [
            StudioCommand(title: isPlaying ? "Pause" : "Play",
                          subtitle: "Start or stop stepping the simulation",
                          category: .transport, systemImage: "playpause", shortcut: "space",
                          action: { [weak self] in self?.togglePlayback() }),
            StudioCommand(title: "Step one frame", subtitle: "Advance a single timestep",
                          category: .transport, systemImage: "forward.frame", shortcut: ".",
                          action: { [weak self] in self?.stepOnce() }),
            StudioCommand(title: "Reset state", subtitle: "Return to the model's default pose",
                          category: .transport, systemImage: "arrow.counterclockwise",
                          shortcut: "⌘R", action: { [weak self] in self?.reset() }),
            StudioCommand(title: "Jump to live", subtitle: "Leave the timeline and resume",
                          category: .transport, systemImage: "forward.end", shortcut: nil,
                          action: { [weak self] in self?.resumeLive() }),
            StudioCommand(title: "Frame scene", subtitle: "Fit the camera to the model",
                          category: .display, systemImage: "viewfinder", shortcut: "F",
                          action: { [weak self] in self?.commands.frameScene() }),
            StudioCommand(title: "Toggle grid", subtitle: "Show or hide the ground grid",
                          category: .display, systemImage: "grid", shortcut: "G",
                          action: { [weak self] in self?.settings.showGrid.toggle() }),
            StudioCommand(title: "Toggle contacts",
                          subtitle: "Contact points and force arrows",
                          category: .display, systemImage: "smallcircle.filled.circle",
                          shortcut: "C",
                          action: { [weak self] in self?.settings.showContacts.toggle() }),
            StudioCommand(title: "Toggle collision shapes",
                          subtitle: "Draw the collision proxies instead of the visual mesh",
                          category: .display, systemImage: "square.on.square.dashed",
                          shortcut: "K",
                          action: { [weak self] in
                              self?.settings.showCollisionGeometry.toggle()
                          }),
            StudioCommand(title: "Toggle wireframe", subtitle: "Draw geometry as lines",
                          category: .display, systemImage: "grid.circle", shortcut: "W",
                          action: { [weak self] in self?.settings.wireframe.toggle() }),
            StudioCommand(title: "Toggle link frames", subtitle: "Per-link coordinate axes",
                          category: .display, systemImage: "move.3d", shortcut: nil,
                          action: { [weak self] in self?.settings.showLinkFrames.toggle() }),
            StudioCommand(title: "Toggle trails", subtitle: "Trace link paths through space",
                          category: .display, systemImage: "scribble", shortcut: "T",
                          action: { [weak self] in self?.settings.showTrails.toggle() }),
            StudioCommand(title: isDark ? "Switch to light theme" : "Switch to dark theme",
                          subtitle: "Viewport and interface appearance",
                          category: .display, systemImage: "circle.lefthalf.filled", shortcut: nil,
                          action: { [weak self] in
                              guard let self else { return }
                              self.isDark.toggle()
                              self.applyAppearance()
                          }),
            StudioCommand(title: bridgeIsRunning ? "Stop telemetry server" : "Start telemetry server",
                          subtitle: "Foxglove-compatible WebSocket on port \(bridgePort)",
                          category: .telemetry, systemImage: "antenna.radiowaves.left.and.right",
                          shortcut: nil, action: { [weak self] in self?.toggleBridge() }),
            StudioCommand(title: "Open model…", subtitle: "Import a URDF or MJCF file",
                          category: .file, systemImage: "folder", shortcut: "⌘O",
                          action: { NotificationCenter.default.post(name: .studioOpenModel,
                                                                    object: nil) }),
            StudioCommand(title: isRecording ? "Stop recording" : "Record to .kinlog",
                          subtitle: "Write a seekable log of the run",
                          category: .file, systemImage: "record.circle", shortcut: "⌘⇧R",
                          action: { NotificationCenter.default.post(name: .studioToggleRecording,
                                                                    object: nil) }),
        ])
        return commands
    }

    // MARK: Recording

    func startRecording(to url: URL) {
        do {
            recorder = try LogRecorder(url: url, world: world, title: sceneTitle)
            recordedFrames = 0
            isRecording = true
            log("recording to \(url.lastPathComponent)", .success)
        } catch {
            log("recording failed: \(error)", .error)
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        recorder.finish()
        log("recorded \(recorder.frameCount) frames", .success)
        self.recorder = nil
        isRecording = false
    }

    // MARK: Bridge

    func startBridge() {
        let bridge = FoxgloveBridge(world: world)
        bridge.onLog = { [weak self] message in
            Task { @MainActor in self?.log("bridge: \(message)", .info) }
        }
        do {
            try bridge.start(port: bridgePort)
            self.bridge = bridge
            log("telemetry live at ws://localhost:\(bridgePort)", .success)
            bridgeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.bridgeConnections = self?.bridge?.connectionCount ?? 0
                }
            }
            objectWillChange.send()
        } catch {
            log("could not start telemetry server: \(error)", .error)
        }
    }

    func stopBridge() {
        bridge?.stop()
        bridge = nil
        bridgeTimer?.invalidate()
        bridgeTimer = nil
        bridgeConnections = 0
        log("telemetry stopped", .info)
        objectWillChange.send()
    }

    func toggleBridge() {
        bridgeIsRunning ? stopBridge() : startBridge()
    }

    // MARK: Console

    func log(_ text: String, _ level: ConsoleLine.Level = .info) {
        console.append(ConsoleLine(time: Date(), level: level, text: text))
        if console.count > 500 { console.removeFirst(console.count - 500) }
    }

    // MARK: Appearance

    func applyAppearance() {
        settings.theme = isDark ? .dark : .light
    }
}
