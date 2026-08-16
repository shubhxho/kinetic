//
//  Panels.swift
//  Kinetic Studio
//
//  The panels that read and drive the simulation, built on SwiftUI's own
//  containers: `List` for anything scrollable and selectable, `Form` with
//  `Section` for settings, `LabeledContent` for label/value pairs, and real
//  `Toggle`, `Slider`, `Stepper` and `Picker` controls throughout.
//

import Kinetic
import KineticRender
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scene tree

/// Scenes and the loaded model, in a sidebar `List` with real selection.
struct SceneTreePanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @State private var expanded: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7]
    @State private var query = ""

    var body: some View {
        List(selection: Binding(
            get: { model.selectedGeom },
            set: { model.selectedGeom = $0; model.settings.selection = $0.map { [$0] } ?? [] }
        )) {
            Section("Scenes") {
                ForEach(SceneLibrary.all, id: \.id) { entry in
                    Button {
                        model.load(sceneIdentifier: entry.id)
                    } label: {
                        Label(entry.title, systemImage: icon(for: entry.id))
                            .foregroundStyle(model.sceneIdentifier == entry.id
                                             ? theme.accent : theme.text)
                    }
                    .buttonStyle(.plain)
                    .help(entry.summary)
                }
            }

            Section("Model") {
                ForEach(0..<model.world.articulationCount, id: \.self) { articulation in
                    DisclosureGroup(isExpanded: expansion(for: articulation)) {
                        ForEach(0..<model.world.linkCount(articulation: articulation),
                                id: \.self) { link in
                            linkRow(articulation: articulation, link: link)
                        }
                    } label: {
                        LabeledContent {
                            Text("\(model.world.linkCount(articulation: articulation))")
                                .font(Typo.monoSmall)
                                .monospacedDigit()
                                .foregroundStyle(theme.tertiary)
                        } label: {
                            Text(model.world.name(articulation: articulation))
                                .font(Typo.small.weight(.medium))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Filter links")
        .background(theme.background)
    }

    private func expansion(for articulation: Int) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(articulation) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(articulation)
                } else {
                    expanded.remove(articulation)
                }
            })
    }

    @ViewBuilder
    private func linkRow(articulation: Int, link: Int) -> some View {
        let name = model.world.name(articulation: articulation, link: link)
        let kind = model.world.jointKind(articulation: articulation, link: link)
        let geom = model.world.geomInfo.first {
            $0.articulation == articulation && $0.link == link
        }

        if query.isEmpty || name.localizedCaseInsensitiveContains(query) {
            LabeledContent {
                if kind != .fixed {
                    Text(shortName(kind))
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
            } label: {
                Label {
                    Text(name).font(Typo.small).lineLimit(1)
                } icon: {
                    Image(systemName: kind == .fixed ? "pin" : "circle.hexagongrid")
                        .foregroundStyle(kind == .fixed ? theme.tertiary : theme.accent)
                }
            }
            .tag(geom?.index ?? -1)
            .help("\(name) · \(kind)")
        }
    }

    private func icon(for id: String) -> String {
        switch id {
        case "stack": return "square.stack.3d.up"
        case "arm": return "figure.arms.open"
        case "quadruped": return "pawprint"
        case "cartpole": return "chart.line.uptrend.xyaxis"
        case "chain": return "link"
        case "dominoes": return "rectangle.grid.3x2"
        default: return "cube"
        }
    }

    private func shortName(_ kind: JointKind) -> String {
        switch kind {
        case .fixed: return "fix"
        case .revolute: return "rev"
        case .prismatic: return "pri"
        case .spherical: return "sph"
        case .free: return "free"
        }
    }
}

// MARK: - Inspector

/// State, solver parameters and display options, as a real `Form`.
struct InspectorPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    var body: some View {
        Form {
            SimulationReadouts()

            selectionSection
            solverSection

            Section("Display") {
                Toggle("Grid", isOn: $model.settings.showGrid)
                Toggle("Contacts", isOn: $model.settings.showContacts)
                Toggle("Contact forces", isOn: $model.settings.showContactForces)
                Toggle("Collision shapes", isOn: $model.settings.showCollisionGeometry)
                Toggle("Link frames", isOn: $model.settings.showLinkFrames)
                Toggle("Centre of mass", isOn: $model.settings.showCenterOfMass)
                Toggle("Trails", isOn: $model.settings.showTrails)
                Toggle("Wireframe", isOn: $model.settings.wireframe)
            }

            telemetrySection
        }
        .formStyle(.grouped)
        .background(theme.background)
    }

    @ViewBuilder
    private var solverSection: some View {
        Section("Solver") {
            LabeledContent("Timestep (ms)") {
                Slider(value: Binding(
                    get: { model.world.options.timestep * 1000 },
                    set: { model.world.options.timestep = $0 / 1000 }),
                       in: 0.2...10)
                .controlSize(.small)
            }
            LabeledContent("Iterations") {
                Stepper(value: Binding(
                    get: { model.world.options.solverIterations },
                    set: { model.world.options.solverIterations = $0 }),
                        in: 1...200) {
                    Text("\(model.world.options.solverIterations)")
                        .font(Typo.mono)
                        .monospacedDigit()
                }
            }
            LabeledContent("Gravity z") {
                Slider(value: Binding(
                    get: { model.world.options.gravity.z },
                    set: { model.world.options.gravity.z = $0 }),
                       in: -25...5)
                .controlSize(.small)
            }
            Picker("Integrator", selection: Binding(
                get: { model.world.options.integrator },
                set: { model.world.options.integrator = $0 })) {
                Text("Semi-implicit Euler").tag(Integrator.semiImplicitEuler)
                Text("Runge-Kutta 4").tag(Integrator.rungeKutta4)
                Text("Implicit (fast)").tag(Integrator.implicitFast)
            }
            Toggle("Warm start", isOn: Binding(
                get: { model.world.options.warmStart },
                set: { model.world.options.warmStart = $0 }))
            Toggle("Joint limits", isOn: Binding(
                get: { model.world.options.enableJointLimits },
                set: { model.world.options.enableJointLimits = $0 }))
            Toggle("Threaded narrowphase", isOn: Binding(
                get: { model.world.options.multithreaded },
                set: { model.world.options.multithreaded = $0 }))
        }
    }

    @ViewBuilder
    private var telemetrySection: some View {
        Section {
            LabeledContent("Status") {
                Label(model.bridgeIsRunning ? "Listening" : "Stopped",
                      systemImage: model.bridgeIsRunning ? "dot.radiowaves.up.forward"
                                                         : "stop.circle")
                    .foregroundStyle(model.bridgeIsRunning ? Palette.success : theme.tertiary)
            }
            LabeledContent("Address", value: "ws://localhost:\(model.bridgePort)")
            LabeledContent("Clients", value: "\(model.bridgeConnections)")
            Button(model.bridgeIsRunning ? "Stop server" : "Start server") {
                model.toggleBridge()
            }
            .buttonStyle(.kinetic(active: model.bridgeIsRunning))
        } header: {
            Text("Telemetry")
        } footer: {
            Text("Any Foxglove client can connect to this address and see the live scene, "
                 + "transforms and every plottable channel.")
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
        }
    }

    @ViewBuilder
    private var selectionSection: some View {
        Section("Selection") {
            if let index = model.selectedGeom, model.world.geomInfo.indices.contains(index) {
                let geom = model.world.geomInfo[index]
                let poses = model.world.geomPoses()
                LabeledContent("Geom", value: geom.name)
                LabeledContent("Articulation",
                               value: model.world.name(articulation: geom.articulation))
                LabeledContent("Link", value: model.world.name(articulation: geom.articulation,
                                                               link: geom.link))
                LabeledContent("Shape", value: describe(geom.shape))
                LabeledContent("Mass", value: model.world.mass(articulation: geom.articulation,
                                                               link: geom.link),
                               format: .number.precision(.fractionLength(4)))
                if index < poses.count {
                    let p = poses[index].position
                    let rpy = poses[index].orientation.eulerRPY
                    LabeledContent("Position",
                                   value: String(format: "%.3f  %.3f  %.3f", p.x, p.y, p.z))
                    LabeledContent("Roll pitch yaw",
                                   value: String(format: "%.2f  %.2f  %.2f", rpy.x, rpy.y, rpy.z))
                }
            } else {
                Text("Click a body in the viewport to inspect it.")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
            }
        }
    }

    private func describe(_ shape: Kinetic.Shape) -> String {
        switch shape {
        case .sphere(let r): return String(format: "sphere r=%.3f", r)
        case .box(let h): return String(format: "box %.2f×%.2f×%.2f", h.x * 2, h.y * 2, h.z * 2)
        case .capsule(let r, let l): return String(format: "capsule r=%.3f l=%.3f", r, l * 2)
        case .cylinder(let r, let l): return String(format: "cylinder r=%.3f l=%.3f", r, l * 2)
        case .plane: return "plane"
        case .convexHull(let m, _): return "hull #\(m)"
        }
    }
}

// MARK: - Actuators

struct ActuatorPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    var body: some View {
        Group {
            if model.world.actuatorCount == 0 {
                ContentUnavailableView("No actuators", systemImage: "bolt.slash",
                                       description: Text("This model has none."))
            } else {
                List {
                    Section("Actuators") {
                        ForEach(0..<model.world.actuatorCount, id: \.self) { index in
                            actuatorRow(index)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(theme.background)
    }

    @ViewBuilder
    private func actuatorRow(_ index: Int) -> some View {
        let names = model.world.actuatorNames
        let name = index < names.count ? names[index] : "u[\(index)]"
        let force = model.world.actuatorForces[index]

        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(model.world.control[index],
                         format: .number.precision(.fractionLength(3)))
                        .font(Typo.mono)
                        .monospacedDigit()
                    Text(force, format: .number.precision(.fractionLength(1)))
                        .font(Typo.monoSmall)
                        .monospacedDigit()
                        .foregroundStyle(abs(force) > 1e-6 ? Palette.accent : theme.tertiary)
                        .frame(width: 56, alignment: .trailing)
                }
            } label: {
                Text(name).font(Typo.small)
            }
            Slider(value: Binding(
                get: { model.world.control[index] },
                set: { model.world.control[index] = $0; model.objectWillChange.send() }),
                   in: -3.2...3.2)
            .controlSize(.mini)
            .tint(theme.accent)
            .accessibilityLabel("\(name) control")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Joints

/// Direct manipulation of every scalar joint: writes straight into `qpos` and
/// re-runs forward kinematics, so a paused model can be posed by hand.
struct JointPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @State private var query = ""

    private var handles: [StudioModel.JointHandle] {
        let all = model.jointHandles()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if model.jointHandles().isEmpty {
                ContentUnavailableView("No scalar joints", systemImage: "slider.horizontal.3",
                                       description: Text("This model has none."))
            } else {
                List {
                    Section {
                        ForEach(handles) { handle in
                            jointRow(handle)
                        }
                    } header: {
                        HStack {
                            Text("Joints")
                            Spacer()
                            Button("Zero pose") {
                                for handle in model.jointHandles() {
                                    model.setJoint(handle, to: 0)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(Typo.monoSmall)
                        }
                    }
                }
                .listStyle(.inset)
                .searchable(text: $query, prompt: "Filter joints")
            }
        }
        .background(theme.background)
    }

    @ViewBuilder
    private func jointRow(_ handle: StudioModel.JointHandle) -> some View {
        let value = handle.coordinateIndex < model.world.coordinateCount
            ? model.world.positions[handle.coordinateIndex] : 0
        let velocity = handle.dofIndex < model.world.dofCount
            ? model.world.velocities[handle.dofIndex] : 0

        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(value, format: .number.precision(.fractionLength(3)))
                        .font(Typo.mono)
                        .monospacedDigit()
                    Text(velocity, format: .number.precision(.fractionLength(2)))
                        .font(Typo.monoSmall)
                        .monospacedDigit()
                        .foregroundStyle(abs(velocity) > 1e-4 ? Palette.accent : theme.tertiary)
                        .frame(width: 48, alignment: .trailing)
                }
            } label: {
                Text(handle.name).font(Typo.small).lineLimit(1)
            }
            Slider(value: Binding(get: { value },
                                  set: { model.setJoint(handle, to: $0) }),
                   in: handle.limits)
            .controlSize(.mini)
            .tint(theme.accent)
            .accessibilityLabel(handle.name)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Telemetry

struct TelemetryPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @EnvironmentObject private var live: LiveStats
    @ObservedObject var plots: PlotStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Telemetry")
                    .font(Typo.sectionLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.tertiary)

                Picker("Window", selection: $model.plotWindowSeconds) {
                    Text("2s").tag(2.0)
                    Text("8s").tag(8.0)
                    Text("30s").tag(30.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Menu {
                    ForEach(model.availableChannels) { channel in
                        Button(channel.label) { model.addPlot(channel) }
                    }
                } label: {
                    Label("Add channel", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.vertical, 8)

            if plots.series.isEmpty {
                ContentUnavailableView("No channels", systemImage: "waveform.path.ecg",
                                       description: Text("Add one to start plotting."))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(plots.series) { series in
                            TimeSeriesPlot(series: series,
                                           windowSeconds: model.plotWindowSeconds,
                                           currentTime: live.value.simulationTime,
                                           onRemove: { model.removePlot(series.id) })
                                .frame(width: 280)
                        }
                    }
                    .padding(.horizontal, Metric.gutter)
                    .padding(.bottom, 10)
                }
            }
        }
        .background(theme.background)
    }
}

// MARK: - Console

struct ConsolePanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    var body: some View {
        List {
            ForEach(model.console) { line in
                LabeledContent {
                    Text(line.text)
                        .font(Typo.monoSmall)
                        .foregroundStyle(color(for: line.level))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(line.time, format: .dateTime.hour().minute().second())
                        .font(Typo.monoSmall)
                        .monospacedDigit()
                        .foregroundStyle(theme.tertiary)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .background(theme.background)
        .overlay {
            if model.console.isEmpty {
                ContentUnavailableView("Log is empty", systemImage: "text.alignleft")
            }
        }
    }

    private func color(for level: ConsoleLine.Level) -> Color {
        switch level {
        case .info: return theme.secondary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.danger
        }
    }
}

/// The inspector's live numbers.
///
/// Split out of `InspectorPanel` so that a stats update re-evaluates these two
/// sections instead of the entire form — the solver sliders and display toggles
/// below them have no reason to be rebuilt ten times a second.
private struct SimulationReadouts: View {
    @EnvironmentObject private var live: LiveStats

    /// Live figures are laid out in a fixed column for the same reason the HUD's
    /// are: a value that resizes as it changes drags the whole form's layout with
    /// it on every update.
    private func figure(_ value: Double, places: Int) -> some View {
        Text(value, format: .number.precision(.fractionLength(places)))
            .monospacedDigit()
            .frame(width: 78, alignment: .trailing)
    }

    private func figure(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .frame(width: 78, alignment: .trailing)
    }

    var body: some View {
        let stats = live.value
        Section("Simulation") {
            LabeledContent("Time") { figure(stats.simulationTime, places: 3) }
            LabeledContent("Step (ms)") { figure(stats.stepMilliseconds, places: 3) }
            LabeledContent("Realtime") {
                figure(stats.realtimeFactor, places: 2)
                    .foregroundStyle(stats.realtimeFactor >= 0.95
                                     ? Palette.success : Palette.warning)
            }
            LabeledContent("Contacts") { figure("\(stats.contactCount)") }
            LabeledContent("Constraints") { figure("\(stats.constraintCount)") }
            LabeledContent("Frame rate") { figure(stats.frameRate, places: 0) }
        }

        Section("Energy") {
            LabeledContent("Kinetic") { figure(stats.kineticEnergy, places: 4) }
            LabeledContent("Potential") { figure(stats.potentialEnergy, places: 4) }
            LabeledContent("Total") {
                figure(stats.kineticEnergy + stats.potentialEnergy, places: 4)
            }
        }
    }
}
