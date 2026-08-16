//
//  Panels.swift
//  Kinetic Studio
//
//  The dockable panels: scene tree, inspector, actuator console, telemetry
//  strip, and the log.
//

import Kinetic
import KineticRender
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scene tree

struct SceneTreePanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @State private var expanded: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7]

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Scenes")
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(SceneLibrary.all, id: \.id) { entry in
                        Button {
                            model.load(sceneIdentifier: entry.id)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: icon(for: entry.id))
                                    .font(.system(size: 10))
                                    .frame(width: 14)
                                    .foregroundStyle(model.sceneIdentifier == entry.id
                                                     ? theme.accent : theme.tertiary)
                                Text(entry.title)
                                    .font(Typo.small)
                                    .foregroundStyle(theme.text)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Metric.gutter)
                            .frame(height: 22)
                            .background(model.sceneIdentifier == entry.id
                                        ? theme.accent.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)

                PanelDivider()

                SectionLabel(text: "Model", trailing: "\(model.world.linkCount) links")
                VStack(spacing: 1) {
                    ForEach(0..<model.world.articulationCount, id: \.self) { articulation in
                        articulationRow(articulation)
                        if expanded.contains(articulation) {
                            ForEach(0..<model.world.linkCount(articulation: articulation),
                                    id: \.self) { link in
                                linkRow(articulation: articulation, link: link)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(width: Metric.sidebarWidth)
        .background(theme.background)
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

    @ViewBuilder
    private func articulationRow(_ index: Int) -> some View {
        Button {
            if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded.contains(index) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.tertiary)
                    .frame(width: 10)
                Text(model.world.name(articulation: index))
                    .font(Typo.small.weight(.medium))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 4)
                Text("\(model.world.linkCount(articulation: index))")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
            }
            .padding(.horizontal, Metric.gutter)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linkRow(articulation: Int, link: Int) -> some View {
        let kind = model.world.jointKind(articulation: articulation, link: link)
        let isSelected = model.selectedGeom.map {
            model.world.geomInfo.indices.contains($0)
                && model.world.geomInfo[$0].articulation == articulation
                && model.world.geomInfo[$0].link == link
        } ?? false

        Button {
            if let geom = model.world.geomInfo.first(where: {
                $0.articulation == articulation && $0.link == link
            }) {
                model.selectedGeom = geom.index
                model.settings.selection = [geom.index]
            }
        } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(kind == .fixed ? theme.tertiary : theme.accent)
                    .frame(width: 2, height: 12)
                    .opacity(kind == .fixed ? 0.4 : 1)
                Text(model.world.name(articulation: articulation, link: link))
                    .font(Typo.small)
                    .foregroundStyle(isSelected ? theme.accent : theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if kind != .fixed {
                    Text(shortName(kind))
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
            .padding(.leading, Metric.gutter + 14)
            .padding(.trailing, Metric.gutter)
            .frame(height: 20)
            .background(isSelected ? theme.accent.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

struct InspectorPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SectionLabel(text: "Simulation")
                FieldRow(label: "time", value: String(format: "%.3f s", model.stats.simulationTime))
                FieldRow(label: "step", value: String(format: "%.3f ms", model.stats.stepMilliseconds))
                FieldRow(label: "realtime",
                         value: String(format: "%.2f×", model.stats.realtimeFactor),
                         accent: model.stats.realtimeFactor >= 0.95 ? Palette.success
                                                                    : Palette.warning)
                FieldRow(label: "contacts", value: "\(model.stats.contactCount)")
                FieldRow(label: "constraints", value: "\(model.stats.constraintCount)")
                FieldRow(label: "frame rate", value: String(format: "%.0f fps", model.stats.frameRate))
                FieldRow(label: "draw", value: String(format: "%.2f ms", model.stats.drawMilliseconds))

                PanelDivider()
                SectionLabel(text: "Energy")
                FieldRow(label: "kinetic", value: String(format: "%.4f J", model.stats.kineticEnergy))
                FieldRow(label: "potential",
                         value: String(format: "%.4f J", model.stats.potentialEnergy))
                FieldRow(label: "total",
                         value: String(format: "%.4f J",
                                       model.stats.kineticEnergy + model.stats.potentialEnergy))

                PanelDivider()
                selectionSection

                PanelDivider()
                SectionLabel(text: "Solver")
                ParameterSlider(label: "timestep (ms)",
                                value: Binding(
                                    get: { model.world.options.timestep * 1000 },
                                    set: { model.world.options.timestep = $0 / 1000 }),
                                range: 0.2...10, format: "%.2f")
                ParameterSlider(label: "iterations",
                                value: Binding(
                                    get: { Double(model.world.options.solverIterations) },
                                    set: { model.world.options.solverIterations = Int($0) }),
                                range: 1...120, format: "%.0f")
                ParameterSlider(label: "gravity z",
                                value: Binding(
                                    get: { model.world.options.gravity.z },
                                    set: { model.world.options.gravity.z = $0 }),
                                range: -25...5, format: "%.2f")
                ToggleRow(label: "warm start",
                          value: Binding(get: { model.world.options.warmStart },
                                         set: { model.world.options.warmStart = $0 }))
                ToggleRow(label: "joint limits",
                          value: Binding(get: { model.world.options.enableJointLimits },
                                         set: { model.world.options.enableJointLimits = $0 }))

                PanelDivider()
                SectionLabel(text: "Display")
                ToggleRow(label: "grid", value: $model.settings.showGrid, shortcut: "G")
                ToggleRow(label: "contacts", value: $model.settings.showContacts, shortcut: "C")
                ToggleRow(label: "contact forces", value: $model.settings.showContactForces)
                ToggleRow(label: "collision shapes",
                          value: $model.settings.showCollisionGeometry, shortcut: "K")
                ToggleRow(label: "link frames", value: $model.settings.showLinkFrames)
                ToggleRow(label: "centre of mass", value: $model.settings.showCenterOfMass)
                ToggleRow(label: "trails", value: $model.settings.showTrails, shortcut: "T")
                ToggleRow(label: "wireframe", value: $model.settings.wireframe, shortcut: "W")

                PanelDivider()
                SectionLabel(text: "Telemetry")
                FieldRow(label: "status",
                         value: model.bridgeIsRunning ? "listening" : "stopped",
                         accent: model.bridgeIsRunning ? Palette.success : theme.tertiary)
                FieldRow(label: "address", value: "ws://localhost:\(model.bridgePort)")
                FieldRow(label: "clients", value: "\(model.bridgeConnections)")
                HStack(spacing: 8) {
                    ToolbarButton(systemImage: model.bridgeIsRunning ? "stop.fill" : "antenna.radiowaves.left.and.right",
                                  label: model.bridgeIsRunning ? "Stop server" : "Start server",
                                  isActive: model.bridgeIsRunning) {
                        model.toggleBridge()
                    }
                    Spacer()
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.vertical, 6)
                Text("Any Foxglove client can connect to this address and see the live scene, "
                     + "transforms and every plottable channel.")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metric.gutter)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: Metric.inspectorWidth)
        .background(theme.background)
    }

    @ViewBuilder
    private var selectionSection: some View {
        SectionLabel(text: "Selection")
        if let index = model.selectedGeom, model.world.geomInfo.indices.contains(index) {
            let geom = model.world.geomInfo[index]
            let poses = model.world.geomPoses()
            FieldRow(label: "geom", value: geom.name)
            FieldRow(label: "articulation", value: model.world.name(articulation: geom.articulation))
            FieldRow(label: "link",
                     value: model.world.name(articulation: geom.articulation, link: geom.link))
            FieldRow(label: "shape", value: describe(geom.shape))
            FieldRow(label: "mass",
                     value: String(format: "%.4f kg",
                                   model.world.mass(articulation: geom.articulation,
                                                    link: geom.link)))
            if index < poses.count {
                let p = poses[index].position
                let rpy = poses[index].orientation.eulerRPY
                FieldRow(label: "position",
                         value: String(format: "%.3f %.3f %.3f", p.x, p.y, p.z))
                FieldRow(label: "rpy",
                         value: String(format: "%.2f %.2f %.2f", rpy.x, rpy.y, rpy.z))
            }
        } else {
            Text("Click a body in the viewport to inspect it.")
                .font(Typo.small)
                .foregroundStyle(theme.tertiary)
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 8)
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

// MARK: - Actuator console

struct ActuatorPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @State private var tick = 0

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Actuators", trailing: "\(model.world.actuatorCount)")
            if model.world.actuatorCount == 0 {
                Text("This model has no actuators.")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, Metric.gutter)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(0..<model.world.actuatorCount, id: \.self) { index in
                            actuatorRow(index)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func actuatorRow(_ index: Int) -> some View {
        let force = model.world.actuatorForces[index]
        VStack(spacing: 1) {
            HStack {
                Text("u[\(index)]")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                Spacer()
                Text(String(format: "%.3f", model.world.control[index]))
                    .font(Typo.mono)
                    .foregroundStyle(theme.text)
                Text(String(format: "%+.1f N", force))
                    .font(Typo.monoSmall)
                    .foregroundStyle(abs(force) > 1e-6 ? Palette.accent : theme.tertiary)
                    .frame(width: 62, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { model.world.control[index] },
                set: { model.world.control[index] = $0; tick &+= 1 }
            ), in: -3.2...3.2)
            .controlSize(.mini)
            .tint(theme.accent)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 2)
    }
}

// MARK: - Telemetry strip

struct TelemetryPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @State private var showChannelPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("TELEMETRY")
                    .font(Typo.sectionLabel)
                    .kerning(0.6)
                    .foregroundStyle(theme.tertiary)
                Chip(text: "\(model.series.count) channels")
                Spacer()
                HStack(spacing: 4) {
                    Text("window")
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                    ForEach([2.0, 8.0, 30.0], id: \.self) { seconds in
                        Button {
                            model.plotWindowSeconds = seconds
                        } label: {
                            Text("\(Int(seconds))s")
                                .font(Typo.monoSmall)
                                .foregroundStyle(model.plotWindowSeconds == seconds
                                                 ? Color.white : theme.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(model.plotWindowSeconds == seconds
                                            ? theme.accent : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ToolbarButton(systemImage: "plus", label: "Channel") {
                    showChannelPicker.toggle()
                }
                .popover(isPresented: $showChannelPicker, arrowEdge: .top) {
                    channelPicker
                }
            }
            .padding(.horizontal, Metric.gutter)
            .padding(.vertical, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.series) { series in
                        TimeSeriesPlot(series: series,
                                       windowSeconds: model.plotWindowSeconds,
                                       currentTime: model.stats.simulationTime,
                                       onRemove: { model.removePlot(series.id) })
                            .frame(width: 268)
                    }
                    if model.series.isEmpty {
                        Text("Add a channel to start plotting.")
                            .font(Typo.small)
                            .foregroundStyle(theme.tertiary)
                            .frame(height: 80)
                    }
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 10)
            }
        }
        .background(theme.background)
    }

    private var channelPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.availableChannels) { channel in
                    Button {
                        model.addPlot(channel)
                        showChannelPicker = false
                    } label: {
                        HStack {
                            Text(channel.label)
                                .font(Typo.small)
                                .foregroundStyle(theme.text)
                            Spacer()
                            Text(String(format: "%.3f", channel.value(in: model.world)))
                                .font(Typo.monoSmall)
                                .foregroundStyle(theme.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 260, height: 340)
    }
}

// MARK: - Console

struct ConsolePanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Log", trailing: "\(model.console.count)")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.console) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(timestamp(line.time))
                                    .font(Typo.monoSmall)
                                    .foregroundStyle(theme.tertiary)
                                Text(line.text)
                                    .font(Typo.monoSmall)
                                    .foregroundStyle(color(for: line.level))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Metric.gutter)
                            .id(line.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.console.count) { _, _ in
                    if let last = model.console.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(theme.background)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
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
