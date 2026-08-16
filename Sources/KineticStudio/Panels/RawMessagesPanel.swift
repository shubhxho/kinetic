//
//  RawMessagesPanel.swift
//  Kinetic Studio
//
//  Foxglove's Raw Messages panel inspects the decoded payload of one topic. A
//  simulator has no topics — it has the whole state vector — so this inspects
//  that instead: generalised coordinates grouped by articulation, the live
//  contact set, sensor readings grouped by sensor, and the step profile.
//
//  Two performance rules shape the code:
//
//  1. The tree is flattened to an array of rows every time the world publishes,
//     but only *open* branches emit children, so a collapsed panel costs almost
//     nothing.
//  2. Rows carry raw `Double`s, never formatted strings. `String(format:)` is
//     roughly two orders of magnitude more expensive than copying a Double, and
//     inside a `LazyVStack` the row body — and therefore the formatting — only
//     runs for rows the scroll view actually realises. Several hundred rows at
//     display rate stay cheap because of this split.
//

import AppKit
import Kinetic
import SwiftUI

// MARK: - Row model

/// A leaf's payload. Kept as numbers so formatting can be deferred to the row
/// body, which SwiftUI only evaluates for visible rows.
private enum RawValue {
    case scalar(Double)
    case integer(Int)
    case vector(Vec3)
    case text(String)
}

private struct RawRow: Identifiable {
    enum Kind {
        case group(isOpen: Bool, detail: String?)
        case leaf(RawValue)
    }

    /// Positional identity. The flattened list is rebuilt wholesale each frame
    /// and rows only move when the tree's *shape* changes, which is exactly when
    /// SwiftUI should treat them as different rows.
    let id: Int
    let path: String
    let label: String
    let depth: Int
    let kind: Kind

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }
}

// MARK: - Tree builder

/// Flattens the tree into rows, honouring expansion and the filter.
///
/// A class rather than a struct: the emit methods recurse through a caller
/// supplied closure, and recursing through `inout self` would trip exclusivity.
private final class RawTreeBuilder {
    private let needle: String
    private let expanded: Set<String>
    /// One entry per open ancestor: true when that ancestor already matched the
    /// filter, in which case everything beneath it is shown wholesale.
    private var matchedAncestors: [Bool] = []
    private(set) var rows: [RawRow] = []

    init(filter: String, expanded: Set<String>) {
        self.needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        self.expanded = expanded
    }

    private var isFiltering: Bool { !needle.isEmpty }
    private var ancestorMatched: Bool { matchedAncestors.last ?? !isFiltering }

    /// Path and label are both tested: the label is the human-readable tail of
    /// the path (a joint name, a contacting geom pair) and people type those.
    private func matches(_ path: String, _ label: String) -> Bool {
        path.lowercased().contains(needle) || label.lowercased().contains(needle)
    }

    func group(_ path: String, _ label: String, depth: Int, detail: String? = nil,
               _ build: () -> Void) {
        let selfMatched = ancestorMatched || matches(path, label)
        // A filter force-opens the tree. You typed a query to see the matches,
        // not to go hunting for which branch is hiding them.
        let isOpen = isFiltering || expanded.contains(path)
        let headerIndex = rows.count
        rows.append(RawRow(id: headerIndex, path: path, label: label, depth: depth,
                           kind: .group(isOpen: isOpen, detail: detail)))
        matchedAncestors.append(selfMatched)
        if isOpen { build() }
        matchedAncestors.removeLast()
        // A branch that neither matched itself nor produced a matching child is
        // noise while filtering.
        if isFiltering, rows.count == headerIndex + 1, !selfMatched {
            rows.removeLast()
        }
    }

    func leaf(_ path: String, _ label: String, depth: Int, _ value: RawValue) {
        guard !isFiltering || ancestorMatched || matches(path, label) else { return }
        rows.append(RawRow(id: rows.count, path: path, label: label, depth: depth,
                           kind: .leaf(value)))
    }
}

// MARK: - Formatting

private enum RawFormat {
    /// Fixed decimals so columns of numbers line up under `.monospacedDigit()`;
    /// scientific notation only where fixed point would be all zeros or unreadably
    /// long.
    static func number(_ value: Double) -> String {
        if value == 0 { return "0.000000" }
        if !value.isFinite { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let magnitude = abs(value)
        if magnitude < 1e-4 || magnitude >= 1e5 { return String(format: "%.4e", value) }
        return String(format: "%.6f", value)
    }

    static func vector(_ v: Vec3) -> String {
        "\(number(v.x))  \(number(v.y))  \(number(v.z))"
    }

    static func value(_ value: RawValue) -> String {
        switch value {
        case .scalar(let d): return number(d)
        case .integer(let i): return String(i)
        case .vector(let v): return vector(v)
        case .text(let s): return s
        }
    }

    static func rowValue(_ row: RawRow) -> String {
        switch row.kind {
        case .group(_, let detail): return detail ?? row.label
        case .leaf(let value): return self.value(value)
        }
    }
}

private func rawSensorKindLabel(_ kind: SensorKind) -> String {
    switch kind {
    case .jointPosition: return "joint position"
    case .jointVelocity: return "joint velocity"
    case .actuatorForce: return "actuator force"
    case .accelerometer: return "accelerometer"
    case .gyroscope: return "gyroscope"
    case .framePosition: return "frame position"
    case .frameOrientation: return "frame orientation"
    case .frameLinearVelocity: return "frame linear velocity"
    case .forceTorque: return "force / torque"
    case .contactNormalForce: return "contact normal force"
    case .rangefinder: return "rangefinder"
    }
}

/// Component names for one sensor's slice of the reading buffer.
private func rawSensorComponents(_ kind: SensorKind) -> [String] {
    switch kind {
    case .jointPosition, .jointVelocity, .actuatorForce, .contactNormalForce, .rangefinder:
        return ["value"]
    case .accelerometer, .gyroscope, .framePosition, .frameLinearVelocity:
        return ["x", "y", "z"]
    case .frameOrientation:
        return ["w", "x", "y", "z"]
    case .forceTorque:
        return ["fx", "fy", "fz", "tx", "ty", "tz"]
    }
}

private func rawJointKindLabel(_ kind: JointKind) -> String {
    switch kind {
    case .fixed: return "fixed"
    case .revolute: return "revolute"
    case .prismatic: return "prismatic"
    case .spherical: return "spherical"
    case .free: return "free"
    }
}

// MARK: - Panel

struct RawMessagesPanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    @State private var filter = ""
    @State private var expanded: Set<String> = RawMessagesPanel.defaultOpen
    /// Path of the row whose copy button was last pressed, for the flash of
    /// confirmation. Cleared on a short timer.
    @State private var copiedPath: String?

    private static let defaultOpen: Set<String> = ["/state", "/contacts", "/profile"]

    var body: some View {
        let rows = buildRows()
        return VStack(spacing: 0) {
            header(rowCount: rows.count)
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            RawMessageRow(
                                row: row,
                                justCopied: copiedPath == row.path,
                                onToggle: { toggle(row) },
                                onCopyPath: { copy(row.path, from: row) },
                                onCopyValue: { copy(RawFormat.rowValue(row), from: row) })
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(theme.background)
    }

    // MARK: Chrome

    private func header(rowCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.tertiary)
            TextField("filter by path", text: $filter)
                .textFieldStyle(.plain)
                .font(Typo.mono)
                .foregroundStyle(theme.text)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiary)
                }
                .buttonStyle(.plain)
            }
            Chip(text: "\(rowCount) rows")
            ToolbarButton(systemImage: "chevron.down.2") {
                expanded = allGroupPaths()
            }
            ToolbarButton(systemImage: "chevron.right.2") {
                expanded = []
            }
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: 34)
        .modifier(RawMessagesChrome(theme: theme))
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(filter.isEmpty ? "Nothing to inspect." : "No path matches “\(filter)”.")
                .font(Typo.small)
                .foregroundStyle(theme.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Interaction

    private func toggle(_ row: RawRow) {
        guard row.isGroup else { return }
        if expanded.contains(row.path) {
            expanded.remove(row.path)
        } else {
            expanded.insert(row.path)
        }
    }

    private func copy(_ text: String, from row: RawRow) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedPath = row.path
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if copiedPath == row.path { copiedPath = nil }
        }
    }

    /// Every branch path in the tree.
    ///
    /// A branch only emits its children when it is already open, so one pass
    /// cannot see the whole tree. Re-running against a set that grows with each
    /// pass reaches a fixed point in `depth` iterations, and the tree is four
    /// levels deep.
    private func allGroupPaths() -> Set<String> {
        var found: Set<String> = Self.defaultOpen
        var previous = -1
        while found.count != previous {
            previous = found.count
            let pass = RawTreeBuilder(filter: "", expanded: found)
            emit(into: pass)
            for row in pass.rows where row.isGroup { found.insert(row.path) }
        }
        return found
    }

    // MARK: Tree

    private func buildRows() -> [RawRow] {
        let builder = RawTreeBuilder(filter: filter, expanded: expanded)
        emit(into: builder)
        return builder.rows
    }

    private func emit(into builder: RawTreeBuilder) {
        let world = model.world
        let options = world.options

        // Snapshot the C-backed buffers once. `world.positions` and friends are
        // computed properties that rebuild an UnsafeMutableBufferPointer on every
        // access, so reading them per row would cross the bridge thousands of
        // times per frame.
        let qpos = Array(world.positions)
        let qvel = Array(world.velocities)
        let ctrl = Array(world.control)
        let actuatorForces = Array(world.actuatorForces)
        let sensorValues = Array(world.sensorReadings)
        let geoms = world.geomInfo
        let contacts = world.contacts()
        let profile = world.profile

        var coordinateNames: [Int: String] = [:]
        var dofNames: [Int: String] = [:]
        for handle in model.jointHandles() {
            coordinateNames[handle.coordinateIndex] = handle.name
            dofNames[handle.dofIndex] = handle.name
        }

        func geomName(_ index: Int) -> String {
            guard geoms.indices.contains(index) else { return "geom[\(index)]" }
            let info = geoms[index]
            return info.name.isEmpty ? "geom[\(index)]" : info.name
        }

        func coordinateRange(_ articulation: Int) -> Range<Int> {
            let lower = world.coordinateOffset(articulation: articulation)
            let upper = articulation + 1 < world.articulationCount
                ? world.coordinateOffset(articulation: articulation + 1)
                : world.coordinateCount
            return lower..<max(lower, min(upper, qpos.count))
        }

        func dofRange(_ articulation: Int) -> Range<Int> {
            let lower = world.dofOffset(articulation: articulation)
            let upper = articulation + 1 < world.articulationCount
                ? world.dofOffset(articulation: articulation + 1)
                : world.dofCount
            return lower..<max(lower, min(upper, qvel.count))
        }

        builder.leaf("/time", "time", depth: 0, .scalar(world.time))

        builder.group("/state", "state", depth: 0,
                      detail: "\(world.coordinateCount)q · \(world.dofCount)v") {
            builder.group("/state/qpos", "qpos", depth: 1, detail: "\(qpos.count)") {
                for articulation in 0..<world.articulationCount {
                    let name = world.name(articulation: articulation)
                    let path = "/state/qpos/\(name)"
                    let range = coordinateRange(articulation)
                    builder.group(path, name, depth: 2, detail: "\(range.count)") {
                        for index in range {
                            let label = coordinateNames[index] ?? "q[\(index)]"
                            builder.leaf("\(path)/\(index)", label, depth: 3, .scalar(qpos[index]))
                        }
                    }
                }
            }

            builder.group("/state/qvel", "qvel", depth: 1, detail: "\(qvel.count)") {
                for articulation in 0..<world.articulationCount {
                    let name = world.name(articulation: articulation)
                    let path = "/state/qvel/\(name)"
                    let range = dofRange(articulation)
                    builder.group(path, name, depth: 2, detail: "\(range.count)") {
                        for index in range {
                            let label = dofNames[index] ?? "v[\(index)]"
                            builder.leaf("\(path)/\(index)", label, depth: 3, .scalar(qvel[index]))
                        }
                    }
                }
            }

            builder.group("/state/ctrl", "ctrl", depth: 1, detail: "\(ctrl.count)") {
                for index in ctrl.indices {
                    builder.leaf("/state/ctrl/\(index)", "u[\(index)]", depth: 2,
                                 .scalar(ctrl[index]))
                }
            }

            builder.group("/state/actuator_force", "actuator force", depth: 1,
                          detail: "\(actuatorForces.count)") {
                for index in actuatorForces.indices {
                    builder.leaf("/state/actuator_force/\(index)", "f[\(index)]", depth: 2,
                                 .scalar(actuatorForces[index]))
                }
            }

            builder.group("/state/joints", "joints", depth: 1,
                          detail: "\(coordinateNames.count)") {
                for articulation in 0..<world.articulationCount {
                    let articulationName = world.name(articulation: articulation)
                    for link in 0..<world.linkCount(articulation: articulation) {
                        let kind = world.jointKind(articulation: articulation, link: link)
                        guard kind != .fixed else { continue }
                        let name = world.name(articulation: articulation, link: link)
                        let path = "/state/joints/\(articulationName)/\(name)"
                        builder.group(path, name, depth: 2, detail: rawJointKindLabel(kind)) {
                            builder.leaf("\(path)/kind", "kind", depth: 3,
                                         .text(rawJointKindLabel(kind)))
                            builder.leaf("\(path)/mass", "link mass", depth: 3,
                                         .scalar(world.mass(articulation: articulation,
                                                            link: link)))
                            if let limits = world.jointLimits(articulation: articulation,
                                                             link: link) {
                                builder.leaf("\(path)/lower", "lower limit", depth: 3,
                                             .scalar(limits.lowerBound))
                                builder.leaf("\(path)/upper", "upper limit", depth: 3,
                                             .scalar(limits.upperBound))
                            }
                        }
                    }
                }
            }
        }

        builder.group("/contacts", "contacts", depth: 0, detail: "\(contacts.count)") {
            for (index, contact) in contacts.enumerated() {
                let a = geomName(contact.geomA)
                let b = geomName(contact.geomB)
                let path = "/contacts/\(index)"
                builder.group(path, "\(a) ↔ \(b)", depth: 1,
                              detail: RawFormat.number(contact.normalForce)) {
                    builder.leaf("\(path)/point", "point", depth: 2, .vector(contact.point))
                    builder.leaf("\(path)/normal", "normal", depth: 2, .vector(contact.normal))
                    builder.leaf("\(path)/force", "force", depth: 2, .vector(contact.force))
                    builder.leaf("\(path)/normal_force", "normal force", depth: 2,
                                 .scalar(contact.normalForce))
                    builder.leaf("\(path)/depth", "depth", depth: 2, .scalar(contact.depth))
                    builder.leaf("\(path)/geom_a", "geom a", depth: 2, .text(a))
                    builder.leaf("\(path)/geom_b", "geom b", depth: 2, .text(b))
                }
            }
        }

        builder.group("/sensors", "sensors", depth: 0, detail: "\(world.sensorNames.count)") {
            var offset = 0
            for (index, name) in world.sensorNames.enumerated() {
                let kind = world.sensorKinds.indices.contains(index)
                    ? world.sensorKinds[index] : SensorKind.jointPosition
                let components = rawSensorComponents(kind)
                let path = "/sensors/\(name)"
                let base = offset
                builder.group(path, name, depth: 1, detail: rawSensorKindLabel(kind)) {
                    for (component, label) in components.enumerated()
                    where base + component < sensorValues.count {
                        builder.leaf("\(path)/\(label)", label, depth: 2,
                                     .scalar(sensorValues[base + component]))
                    }
                }
                offset += components.count
            }
        }

        builder.group("/profile", "step profile", depth: 0,
                      detail: String(format: "%.3f ms", profile.total)) {
            builder.group("/profile/timing", "timing (ms)", depth: 1,
                          detail: String(format: "%.3f", profile.total)) {
                builder.leaf("/profile/timing/kinematics", "kinematics", depth: 2,
                             .scalar(profile.kinematics))
                builder.leaf("/profile/timing/inertia", "inertia", depth: 2,
                             .scalar(profile.inertia))
                builder.leaf("/profile/timing/bias", "bias", depth: 2, .scalar(profile.bias))
                builder.leaf("/profile/timing/collision", "collision", depth: 2,
                             .scalar(profile.collision))
                builder.leaf("/profile/timing/constraint_setup", "constraint setup", depth: 2,
                             .scalar(profile.constraintSetup))
                builder.leaf("/profile/timing/solve", "solve", depth: 2, .scalar(profile.solve))
                builder.leaf("/profile/timing/integrate", "integrate", depth: 2,
                             .scalar(profile.integrate))
                builder.leaf("/profile/timing/sensors", "sensors", depth: 2,
                             .scalar(profile.sensors))
                builder.leaf("/profile/timing/total", "total", depth: 2, .scalar(profile.total))
            }
            builder.group("/profile/counts", "counts", depth: 1,
                          detail: "\(profile.contactCount) contacts") {
                builder.leaf("/profile/counts/contacts", "contacts", depth: 2,
                             .integer(profile.contactCount))
                builder.leaf("/profile/counts/constraints", "constraints", depth: 2,
                             .integer(profile.constraintCount))
                builder.leaf("/profile/counts/broadphase_pairs", "broadphase pairs", depth: 2,
                             .integer(profile.broadphasePairs))
            }
            builder.group("/profile/solver", "solver", depth: 1,
                          detail: "\(profile.solverIterations)/\(options.solverIterations)") {
                builder.leaf("/profile/solver/iterations", "iterations used", depth: 2,
                             .integer(profile.solverIterations))
                builder.leaf("/profile/solver/iterations_configured", "iterations configured",
                             depth: 2, .integer(options.solverIterations))
                builder.leaf("/profile/solver/residual", "residual", depth: 2,
                             .scalar(profile.solverResidual))
                builder.leaf("/profile/solver/tolerance", "tolerance", depth: 2,
                             .scalar(options.solverTolerance))
                builder.leaf("/profile/solver/warm_start", "warm start", depth: 2,
                             .text(options.warmStart ? "on" : "off"))
                builder.leaf("/profile/solver/timestep", "timestep", depth: 2,
                             .scalar(options.timestep))
            }
        }
    }
}

// MARK: - Row

private struct RawMessageRow: View {
    @Environment(\.studioTheme) private var theme
    let row: RawRow
    let justCopied: Bool
    let onToggle: () -> Void
    let onCopyPath: () -> Void
    let onCopyValue: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Indent guide. Depth is small (<= 3) so a fixed inset reads better
            // than nested containers.
            Spacer(minLength: 0)
                .frame(width: CGFloat(row.depth) * 13)

            switch row.kind {
            case .group(let isOpen, _):
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.tertiary)
                    .frame(width: 10)
            case .leaf:
                Rectangle()
                    .fill(theme.border)
                    .frame(width: 1, height: 9)
                    .frame(width: 10)
            }

            Text(row.label)
                .font(row.isGroup ? Typo.small.weight(.semibold) : Typo.small)
                .foregroundStyle(row.isGroup ? theme.text : theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if hovering || justCopied {
                Button(action: onCopyPath) {
                    Image(systemName: justCopied ? "checkmark" : "curlybraces")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(justCopied ? Palette.success : theme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy path")

                Button(action: onCopyValue) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy value")
            }

            valueText
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: 20)
        .background(hovering ? theme.border.opacity(0.28) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button("Copy path", action: onCopyPath)
            Button("Copy value", action: onCopyValue)
        }
    }

    /// Formatting happens here and nowhere else: inside a `LazyVStack` this body
    /// only runs for rows that are on screen.
    @ViewBuilder
    private var valueText: some View {
        switch row.kind {
        case .group(_, let detail):
            if let detail {
                Text(detail)
                    .font(Typo.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiary)
            }
        case .leaf(let value):
            Text(RawFormat.value(value))
                .font(Typo.mono)
                .monospacedDigit()
                .foregroundStyle(tint(for: value))
                .lineLimit(1)
        }
    }

    private func tint(for value: RawValue) -> Color {
        switch value {
        case .text: return Palette.cyan
        case .scalar(let d): return d == 0 ? theme.tertiary : theme.text
        case .integer(let i): return i == 0 ? theme.tertiary : theme.text
        case .vector: return theme.text
        }
    }
}

// MARK: - Chrome background

/// Floating chrome gets real glass on macOS 26 and a material everywhere else.
/// Kept inline and self-contained so this file has no dependency on the design
/// system's glass components.
private struct RawMessagesChrome: ViewModifier {
    let theme: StudioTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}
