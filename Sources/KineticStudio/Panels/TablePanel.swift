//
//  TablePanel.swift
//  Kinetic Studio
//
//  Foxglove's Table panel lays one repeated message field out per column. The
//  simulator equivalent is: pick a collection the engine already keeps as an
//  array — geoms, links, contacts, actuators, sensors — and show it as columns.
//
//  Deliberately not SwiftUI's `Table`. `Table` wants one static row type with
//  columns bound to key paths, and every source here has a different column set
//  with per-cell alignment and monospaced tabular numbers that `Table`'s styling
//  does not reach. A header row over a `LazyVStack` gives the same sorting and
//  selection behaviour with full control of the cell, and stays lazy for the
//  contact list, which is the only source that gets long.
//

import Kinetic
import SwiftUI

// MARK: - Source

enum StudioTableSource: String, CaseIterable, Identifiable, Hashable {
    case geoms, links, contacts, actuators, sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .geoms: return "Geoms"
        case .links: return "Links"
        case .contacts: return "Contacts"
        case .actuators: return "Actuators"
        case .sensors: return "Sensors"
        }
    }
}

// MARK: - Column and cell model

private struct StudioTableColumn: Identifiable {
    let id: String
    let title: String
    /// `nil` means the column absorbs the leftover width. Exactly one column per
    /// source is flexible, and it is always the name column.
    let width: CGFloat?
    let numeric: Bool
}

private enum StudioTableCell {
    case text(String)
    case number(Double, decimals: Int)
    case count(Int)
    case flag(Bool)

    var numericKey: Double? {
        switch self {
        case .number(let value, _): return value
        case .count(let value): return Double(value)
        case .flag(let value): return value ? 1 : 0
        case .text: return nil
        }
    }

    var textKey: String {
        switch self {
        case .text(let value): return value
        default: return rendered
        }
    }

    var rendered: String {
        switch self {
        case .text(let value): return value
        case .number(let value, let decimals):
            if !value.isFinite { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
            let magnitude = abs(value)
            // Scientific notation only where fixed point would lie about the
            // value (all zeros) or blow the column width.
            if magnitude != 0, magnitude < 1e-4 || magnitude >= 1e6 {
                return String(format: "%.2e", value)
            }
            return String(format: "%.\(decimals)f", value)
        case .count(let value): return String(value)
        case .flag(let value): return value ? "yes" : "—"
        }
    }
}

private struct StudioTableRow: Identifiable {
    let id: Int
    /// Set where the row maps onto a geom, which is what the viewport can select.
    let geom: Int?
    let cells: [StudioTableCell]
}

// MARK: - Panel

struct TablePanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    @State private var source: StudioTableSource = .contacts
    @State private var filter = ""
    @State private var sortColumn: String?
    @State private var ascending = true

    var body: some View {
        let columns = columns(for: source)
        let rows = sorted(filtered(rows(for: source)), columns: columns)

        return VStack(spacing: 0) {
            header(rowCount: rows.count)
            PanelDivider()
            headerRow(columns)
            PanelDivider()
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            TableBodyRow(
                                row: row,
                                columns: columns,
                                isSelected: row.geom != nil && row.geom == model.selectedGeom,
                                onSelect: { select(row) })
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .background(theme.background)
    }

    // MARK: Chrome

    private func header(rowCount: Int) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $source) {
                ForEach(StudioTableSource.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.tertiary)
            TextField("filter", text: $filter)
                .textFieldStyle(.plain)
                .font(Typo.mono)
                .foregroundStyle(theme.text)
                .frame(minWidth: 80)

            Chip(text: "\(rowCount)")
        }
        .padding(.horizontal, Metric.gutter)
        .frame(height: 34)
        .modifier(TablePanelChrome())
        .onChange(of: source) { _, _ in
            // Column ids are per-source; a stale sort key would silently sort by
            // nothing.
            sortColumn = nil
            ascending = true
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(emptyMessage)
                .font(Typo.small)
                .foregroundStyle(theme.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        if !filter.isEmpty { return "No \(source.title.lowercased()) match “\(filter)”." }
        switch source {
        case .contacts: return "Nothing is touching."
        case .actuators: return "This model has no actuators."
        case .sensors: return "This model has no sensors."
        case .geoms: return "This model has no geometry."
        case .links: return "This model has no links."
        }
    }

    private func headerRow(_ columns: [StudioTableColumn]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Button {
                    if sortColumn == column.id {
                        ascending.toggle()
                    } else {
                        sortColumn = column.id
                        // Numbers are most useful largest-first; names A→Z.
                        ascending = !column.numeric
                    }
                } label: {
                    HStack(spacing: 3) {
                        if column.numeric { Spacer(minLength: 0) }
                        Text(column.title.uppercased())
                            .font(Typo.sectionLabel)
                            .kerning(0.5)
                            .foregroundStyle(sortColumn == column.id ? theme.accent
                                                                     : theme.tertiary)
                            .lineLimit(1)
                        if sortColumn == column.id {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                        if !column.numeric { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .frame(width: column.width)
                    .frame(maxWidth: column.width == nil ? .infinity : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metric.gutter - 6)
        .background(theme.surface)
    }

    // MARK: Selection

    private func select(_ row: StudioTableRow) {
        guard let geom = row.geom else { return }
        model.selectedGeom = geom
        // The viewport highlights from the render settings, not from the model's
        // selection field, so both have to move for the row click to be visible
        // in 3D.
        model.settings.selection = [geom]
    }

    // MARK: Filtering and sorting

    private func filtered(_ rows: [StudioTableRow]) -> [StudioTableRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            row.cells.contains { cell in
                if case .text(let value) = cell { return value.lowercased().contains(needle) }
                return false
            }
        }
    }

    private func sorted(_ rows: [StudioTableRow],
                        columns: [StudioTableColumn]) -> [StudioTableRow] {
        guard let sortColumn,
              let index = columns.firstIndex(where: { $0.id == sortColumn }) else { return rows }
        return rows.sorted { lhs, rhs in
            guard index < lhs.cells.count, index < rhs.cells.count else { return false }
            let a = lhs.cells[index]
            let b = rhs.cells[index]
            if let x = a.numericKey, let y = b.numericKey {
                if x == y { return lhs.id < rhs.id }
                return ascending ? x < y : x > y
            }
            let x = a.textKey
            let y = b.textKey
            if x == y { return lhs.id < rhs.id }
            return ascending ? x.localizedStandardCompare(y) == .orderedAscending
                             : x.localizedStandardCompare(y) == .orderedDescending
        }
    }

    // MARK: Columns

    private func columns(for source: StudioTableSource) -> [StudioTableColumn] {
        switch source {
        case .geoms:
            return [
                StudioTableColumn(id: "name", title: "Geom", width: nil, numeric: false),
                StudioTableColumn(id: "shape", title: "Shape", width: 72, numeric: false),
                StudioTableColumn(id: "body", title: "Body", width: 96, numeric: false),
                StudioTableColumn(id: "x", title: "X", width: 68, numeric: true),
                StudioTableColumn(id: "y", title: "Y", width: 68, numeric: true),
                StudioTableColumn(id: "z", title: "Z", width: 68, numeric: true),
                StudioTableColumn(id: "collides", title: "Collides", width: 56, numeric: true),
            ]
        case .links:
            return [
                StudioTableColumn(id: "name", title: "Link", width: nil, numeric: false),
                StudioTableColumn(id: "joint", title: "Joint", width: 72, numeric: false),
                StudioTableColumn(id: "mass", title: "Mass", width: 72, numeric: true),
                StudioTableColumn(id: "x", title: "X", width: 68, numeric: true),
                StudioTableColumn(id: "y", title: "Y", width: 68, numeric: true),
                StudioTableColumn(id: "z", title: "Z", width: 68, numeric: true),
                StudioTableColumn(id: "vel", title: "Velocity", width: 76, numeric: true),
            ]
        case .contacts:
            return [
                StudioTableColumn(id: "a", title: "Geom A", width: nil, numeric: false),
                StudioTableColumn(id: "b", title: "Geom B", width: 128, numeric: false),
                StudioTableColumn(id: "fn", title: "Normal force", width: 92, numeric: true),
                StudioTableColumn(id: "depth", title: "Depth", width: 80, numeric: true),
                StudioTableColumn(id: "x", title: "X", width: 68, numeric: true),
                StudioTableColumn(id: "y", title: "Y", width: 68, numeric: true),
                StudioTableColumn(id: "z", title: "Z", width: 68, numeric: true),
            ]
        case .actuators:
            return [
                StudioTableColumn(id: "name", title: "Actuator", width: nil, numeric: false),
                StudioTableColumn(id: "ctrl", title: "Control", width: 88, numeric: true),
                StudioTableColumn(id: "force", title: "Force", width: 88, numeric: true),
                StudioTableColumn(id: "effort", title: "|Force|", width: 88, numeric: true),
            ]
        case .sensors:
            return [
                StudioTableColumn(id: "name", title: "Sensor", width: nil, numeric: false),
                StudioTableColumn(id: "kind", title: "Kind", width: 132, numeric: false),
                StudioTableColumn(id: "index", title: "Index", width: 56, numeric: true),
                StudioTableColumn(id: "value", title: "Value", width: 104, numeric: true),
            ]
        }
    }

    // MARK: Rows

    private func rows(for source: StudioTableSource) -> [StudioTableRow] {
        switch source {
        case .geoms: return geomRows()
        case .links: return linkRows()
        case .contacts: return contactRows()
        case .actuators: return actuatorRows()
        case .sensors: return sensorRows()
        }
    }

    private func geomRows() -> [StudioTableRow] {
        let world = model.world
        let infos = world.geomInfo
        let poses = world.geomPoses()
        return infos.map { info in
            let position = poses.indices.contains(info.index) ? poses[info.index].position
                                                              : Vec3.zero
            return StudioTableRow(id: info.index, geom: info.index, cells: [
                .text(info.name.isEmpty ? "geom[\(info.index)]" : info.name),
                .text(tableShapeLabel(info.shape)),
                .text(world.name(articulation: info.articulation, link: info.link)),
                .number(position.x, decimals: 4),
                .number(position.y, decimals: 4),
                .number(position.z, decimals: 4),
                .flag(info.collidable),
            ])
        }
    }

    private func linkRows() -> [StudioTableRow] {
        let world = model.world
        let poses = world.linkPoses()
        let velocities = Array(world.velocities)
        let geoms = world.geomInfo
        var rows: [StudioTableRow] = []
        // `linkPoses()` is indexed by global link number, which is the
        // concatenation of each articulation's links in order.
        var globalIndex = 0
        for articulation in 0..<world.articulationCount {
            let dofBase = world.dofOffset(articulation: articulation)
            for link in 0..<world.linkCount(articulation: articulation) {
                let kind = world.jointKind(articulation: articulation, link: link)
                let position = poses.indices.contains(globalIndex) ? poses[globalIndex].position
                                                                   : Vec3.zero
                // Scalar joints report their own speed; multi-dof joints report
                // the magnitude across their block, which is the honest summary.
                let dofIndex = dofBase + world.jointDofIndex(articulation: articulation,
                                                            link: link)
                var speed = 0.0
                for offset in 0..<kind.dofCount where dofIndex + offset < velocities.count {
                    let value = velocities[dofIndex + offset]
                    speed += value * value
                }
                let geom = geoms.first { $0.articulation == articulation && $0.link == link }
                rows.append(StudioTableRow(id: globalIndex, geom: geom?.index, cells: [
                    .text(world.name(articulation: articulation, link: link)),
                    .text(tableJointLabel(kind)),
                    .number(world.mass(articulation: articulation, link: link), decimals: 4),
                    .number(position.x, decimals: 4),
                    .number(position.y, decimals: 4),
                    .number(position.z, decimals: 4),
                    .number(speed.squareRoot(), decimals: 4),
                ]))
                globalIndex += 1
            }
        }
        return rows
    }

    private func contactRows() -> [StudioTableRow] {
        let world = model.world
        let geoms = world.geomInfo
        func name(_ index: Int) -> String {
            guard geoms.indices.contains(index) else { return "geom[\(index)]" }
            let info = geoms[index]
            return info.name.isEmpty ? "geom[\(index)]" : info.name
        }
        return world.contacts().enumerated().map { index, contact in
            StudioTableRow(id: index, geom: contact.geomA, cells: [
                .text(name(contact.geomA)),
                .text(name(contact.geomB)),
                .number(contact.normalForce, decimals: 3),
                .number(contact.depth, decimals: 5),
                .number(contact.point.x, decimals: 4),
                .number(contact.point.y, decimals: 4),
                .number(contact.point.z, decimals: 4),
            ])
        }
    }

    private func actuatorRows() -> [StudioTableRow] {
        let world = model.world
        let control = Array(world.control)
        let forces = Array(world.actuatorForces)
        return (0..<world.actuatorCount).map { index in
            let force = index < forces.count ? forces[index] : 0
            return StudioTableRow(id: index, geom: nil, cells: [
                .text("u[\(index)]"),
                .number(index < control.count ? control[index] : 0, decimals: 4),
                .number(force, decimals: 4),
                .number(abs(force), decimals: 4),
            ])
        }
    }

    private func sensorRows() -> [StudioTableRow] {
        let world = model.world
        let readings = Array(world.sensorReadings)
        var rows: [StudioTableRow] = []
        var offset = 0
        for (index, name) in world.sensorNames.enumerated() {
            let kind = world.sensorKinds.indices.contains(index) ? world.sensorKinds[index]
                                                                 : SensorKind.jointPosition
            let components = tableSensorComponents(kind)
            for (component, label) in components.enumerated() {
                let flat = offset + component
                guard flat < readings.count else { break }
                rows.append(StudioTableRow(id: flat, geom: nil, cells: [
                    .text(components.count == 1 ? name : "\(name).\(label)"),
                    .text(tableSensorKindLabel(kind)),
                    .count(flat),
                    .number(readings[flat], decimals: 5),
                ]))
            }
            offset += components.count
        }
        return rows
    }
}

// MARK: - Body row

private struct TableBodyRow: View {
    @Environment(\.studioTheme) private var theme
    let row: StudioTableRow
    let columns: [StudioTableColumn]
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                cell(index: index, column: column)
            }
        }
        .padding(.horizontal, Metric.gutter - 6)
        .frame(height: 22)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }

    private var background: Color {
        if isSelected { return theme.accent.opacity(0.16) }
        if hovering { return theme.border.opacity(0.28) }
        // Zebra striping keeps a wide row readable across seven columns.
        return row.id.isMultiple(of: 2) ? Color.clear : theme.surface.opacity(0.6)
    }

    @ViewBuilder
    private func cell(index: Int, column: StudioTableColumn) -> some View {
        let value = index < row.cells.count ? row.cells[index] : StudioTableCell.text("—")
        Text(value.rendered)
            .font(column.numeric ? Typo.mono : Typo.small)
            .monospacedDigit()
            .foregroundStyle(tint(value))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .frame(width: column.width, alignment: column.numeric ? .trailing : .leading)
            .frame(maxWidth: column.width == nil ? .infinity : nil,
                   alignment: column.numeric ? .trailing : .leading)
    }

    private func tint(_ cell: StudioTableCell) -> Color {
        switch cell {
        case .flag(let value): return value ? Palette.success : theme.tertiary
        case .number(let value, _): return value == 0 ? theme.tertiary : theme.text
        case .count: return theme.secondary
        case .text: return isSelected ? theme.accent : theme.text
        }
    }
}

// MARK: - Labels

private func tableShapeLabel(_ shape: Kinetic.Shape) -> String {
    switch shape {
    case .sphere: return "sphere"
    case .box: return "box"
    case .capsule: return "capsule"
    case .cylinder: return "cylinder"
    case .plane: return "plane"
    case .convexHull: return "hull"
    }
}

private func tableJointLabel(_ kind: JointKind) -> String {
    switch kind {
    case .fixed: return "fixed"
    case .revolute: return "revolute"
    case .prismatic: return "prismatic"
    case .spherical: return "spherical"
    case .free: return "free"
    }
}

private func tableSensorKindLabel(_ kind: SensorKind) -> String {
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

private func tableSensorComponents(_ kind: SensorKind) -> [String] {
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

// MARK: - Chrome background

/// Inline glass so the panel carries no dependency on the shared design system's
/// glass components, which are being written in parallel.
private struct TablePanelChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}
