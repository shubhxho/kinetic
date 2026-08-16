//
//  TablePanel.swift
//  Kinetic Studio
//
//  A sortable, selectable table over whatever the simulation currently holds.
//
//  Built on SwiftUI's `Table`, not a stack of rows. That buys column resizing
//  and reordering, click-to-sort headers, shift- and command-click range
//  selection, keyboard navigation and VoiceOver row reading — all of which a
//  `LazyVStack` would have to reimplement, and none of which it would get
//  exactly right.
//

import Kinetic
import SwiftUI

/// Which of the simulation's collections the table is showing.
enum StudioTableSource: String, CaseIterable, Hashable, Identifiable {
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

    var systemImage: String {
        switch self {
        case .geoms: return "cube"
        case .links: return "point.3.connected.trianglepath.dotted"
        case .contacts: return "smallcircle.filled.circle"
        case .actuators: return "bolt.horizontal"
        case .sensors: return "sensor"
        }
    }
}

// MARK: - Row models

struct GeomRow: Identifiable {
    let id: Int
    var name: String
    var shape: String
    var articulation: String
    var link: String
    var x: Double, y: Double, z: Double
    var collidable: Bool
    var visible: Bool
}

struct LinkRow: Identifiable {
    let id: Int
    var name: String
    var joint: String
    var mass: Double
    var x: Double, y: Double, z: Double
    var speed: Double
    var angularSpeed: Double
}

struct ContactRow: Identifiable {
    let id: Int
    var geomA: String
    var geomB: String
    var normalForce: Double
    var depth: Double
    var x: Double, y: Double, z: Double
}

struct ActuatorRow: Identifiable {
    let id: Int
    var name: String
    var control: Double
    var force: Double
    var magnitude: Double
}

struct SensorRow: Identifiable {
    let id: Int
    var name: String
    var kind: String
    var component: String
    var value: Double
}

// MARK: - Panel

struct TablePanel: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    @State private var source: StudioTableSource = .contacts
    @State private var query = ""

    @State private var geomSort = [KeyPathComparator(\GeomRow.name)]
    @State private var linkSort = [KeyPathComparator(\LinkRow.name)]
    @State private var contactSort = [KeyPathComparator(\ContactRow.normalForce,
                                                       order: .reverse)]
    @State private var actuatorSort = [KeyPathComparator(\ActuatorRow.id)]
    @State private var sensorSort = [KeyPathComparator(\SensorRow.id)]

    @State private var geomSelection = Set<GeomRow.ID>()
    @State private var linkSelection = Set<LinkRow.ID>()
    @State private var contactSelection = Set<ContactRow.ID>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .background(theme.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Source", selection: $source) {
                ForEach(StudioTableSource.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            Text(countLabel)
                .font(Typo.monoSmall)
                .monospacedDigit()
                .foregroundStyle(theme.tertiary)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 6)
        .searchable(text: $query, placement: .automatic, prompt: "Filter rows")
    }

    private var countLabel: String {
        switch source {
        case .geoms: return "\(geomRows.count) geoms"
        case .links: return "\(linkRows.count) links"
        case .contacts: return "\(contactRows.count) contacts"
        case .actuators: return "\(actuatorRows.count) actuators"
        case .sensors: return "\(sensorRows.count) channels"
        }
    }

    @ViewBuilder
    private var table: some View {
        switch source {
        case .geoms: geomTable
        case .links: linkTable
        case .contacts: contactTable
        case .actuators: actuatorTable
        case .sensors: sensorTable
        }
    }

    // MARK: Geoms

    private var geomTable: some View {
        Table(geomRows.sorted(using: geomSort), selection: $geomSelection,
              sortOrder: $geomSort) {
            TableColumn("Name", value: \.name) { row in
                Label(row.name, systemImage: "cube")
                    .labelStyle(.titleAndIcon)
                    .font(Typo.small)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Shape", value: \.shape) { Text($0.shape).font(Typo.monoSmall) }
            TableColumn("Articulation", value: \.articulation) {
                Text($0.articulation).font(Typo.small)
            }
            TableColumn("Link", value: \.link) { Text($0.link).font(Typo.small) }
            TableColumn("X", value: \.x) { numeric($0.x) }.width(64)
            TableColumn("Y", value: \.y) { numeric($0.y) }.width(64)
            TableColumn("Z", value: \.z) { numeric($0.z) }.width(64)
            // Not sortable: Bool is not Comparable, so it cannot key a sort
            // descriptor. Sorting by "collides" is not a thing anyone asks for.
            TableColumn("Collides") { row in
                Image(systemName: row.collidable ? "checkmark" : "minus")
                    .foregroundStyle(row.collidable ? Palette.success : theme.tertiary)
                    .help(row.collidable ? "Participates in collision" : "Visual only")
            }
            .width(60)
        }
        .onChange(of: geomSelection) { _, new in
            model.selectedGeom = new.first
            model.settings.selection = Set(new)
        }
    }

    private var geomRows: [GeomRow] {
        let poses = model.world.geomPoses()
        return model.world.geomInfo.enumerated().compactMap { index, info in
            guard index < poses.count else { return nil }
            let p = poses[index].position
            let row = GeomRow(
                id: info.index, name: info.name, shape: describe(info.shape),
                articulation: model.world.name(articulation: info.articulation),
                link: model.world.name(articulation: info.articulation, link: info.link),
                x: p.x, y: p.y, z: p.z,
                collidable: info.collidable, visible: info.visible)
            return matches(row.name, row.shape, row.articulation, row.link) ? row : nil
        }
    }

    // MARK: Links

    private var linkTable: some View {
        Table(linkRows.sorted(using: linkSort), selection: $linkSelection, sortOrder: $linkSort) {
            TableColumn("Name", value: \.name) { Text($0.name).font(Typo.small) }
                .width(min: 120, ideal: 170)
            TableColumn("Joint", value: \.joint) { Text($0.joint).font(Typo.monoSmall) }
                .width(70)
            TableColumn("Mass", value: \.mass) { numeric($0.mass, unit: "kg") }.width(78)
            TableColumn("X", value: \.x) { numeric($0.x) }.width(64)
            TableColumn("Y", value: \.y) { numeric($0.y) }.width(64)
            TableColumn("Z", value: \.z) { numeric($0.z) }.width(64)
            TableColumn("Speed", value: \.speed) { numeric($0.speed, unit: "m/s") }.width(80)
            TableColumn("ω", value: \.angularSpeed) {
                numeric($0.angularSpeed, unit: "rad/s")
            }
            .width(88)
        }
    }

    private var linkRows: [LinkRow] {
        let poses = model.world.linkPoses()
        let velocities = model.world.linkVelocities()
        var rows: [LinkRow] = []
        for articulation in 0..<model.world.articulationCount {
            for link in 0..<model.world.linkCount(articulation: articulation) {
                let index = model.world.globalLinkIndex(articulation: articulation, link: link)
                guard index < poses.count else { continue }
                let name = model.world.name(articulation: articulation, link: link)
                let joint = "\(model.world.jointKind(articulation: articulation, link: link))"
                guard matches(name, joint) else { continue }
                let p = poses[index].position
                var linear = Vec3.zero
                var angular = Vec3.zero
                if index < velocities.count {
                    linear = velocities[index].linear
                    angular = velocities[index].angular
                }
                let mass = model.world.mass(articulation: articulation, link: link)
                let row = LinkRow(id: index, name: name, joint: joint, mass: mass,
                                  x: p.x, y: p.y, z: p.z,
                                  speed: linear.length, angularSpeed: angular.length)
                rows.append(row)
            }
        }
        return rows
    }

    // MARK: Contacts

    private var contactTable: some View {
        Table(contactRows.sorted(using: contactSort), selection: $contactSelection,
              sortOrder: $contactSort) {
            TableColumn("Geom A", value: \.geomA) { Text($0.geomA).font(Typo.small) }
            TableColumn("Geom B", value: \.geomB) { Text($0.geomB).font(Typo.small) }
            TableColumn("Normal force", value: \.normalForce) { row in
                numeric(row.normalForce, unit: "N",
                        tone: row.normalForce > 0 ? Palette.accent : nil)
            }
            .width(110)
            TableColumn("Depth", value: \.depth) { numeric($0.depth * 1000, unit: "mm") }
                .width(92)
            TableColumn("X", value: \.x) { numeric($0.x) }.width(64)
            TableColumn("Y", value: \.y) { numeric($0.y) }.width(64)
            TableColumn("Z", value: \.z) { numeric($0.z) }.width(64)
        }
    }

    private var contactRows: [ContactRow] {
        let info = model.world.geomInfo
        func name(_ index: Int) -> String {
            info.indices.contains(index) ? info[index].name : "geom\(index)"
        }
        return model.world.contacts().enumerated().compactMap { index, contact in
            let a = name(contact.geomA), b = name(contact.geomB)
            guard matches(a, b) else { return nil }
            return ContactRow(id: index, geomA: a, geomB: b,
                              normalForce: contact.normalForce, depth: contact.depth,
                              x: contact.point.x, y: contact.point.y, z: contact.point.z)
        }
    }

    // MARK: Actuators

    private var actuatorTable: some View {
        Table(actuatorRows.sorted(using: actuatorSort), sortOrder: $actuatorSort) {
            TableColumn("#", value: \.id) { Text("\($0.id)").font(Typo.monoSmall) }.width(34)
            TableColumn("Name", value: \.name) { Text($0.name).font(Typo.small) }
                .width(min: 120, ideal: 180)
            TableColumn("Control", value: \.control) { numeric($0.control) }.width(86)
            TableColumn("Force", value: \.force) { row in
                numeric(row.force, unit: "N",
                        tone: abs(row.force) > 1e-6 ? Palette.accent : nil)
            }
            .width(96)
        }
    }

    private var actuatorRows: [ActuatorRow] {
        let names = model.world.actuatorNames
        return (0..<model.world.actuatorCount).compactMap { index in
            let name = index < names.count ? names[index] : "u[\(index)]"
            guard matches(name) else { return nil }
            let force = model.world.actuatorForces[index]
            return ActuatorRow(id: index, name: name,
                               control: model.world.control[index],
                               force: force, magnitude: abs(force))
        }
    }

    // MARK: Sensors

    private var sensorTable: some View {
        Table(sensorRows.sorted(using: sensorSort), sortOrder: $sensorSort) {
            TableColumn("Sensor", value: \.name) { Text($0.name).font(Typo.small) }
                .width(min: 120, ideal: 180)
            TableColumn("Kind", value: \.kind) { Text($0.kind).font(Typo.monoSmall) }
            TableColumn("Component", value: \.component) {
                Text($0.component).font(Typo.monoSmall)
            }
            .width(90)
            TableColumn("Value", value: \.value) { numeric($0.value) }.width(96)
        }
    }

    private var sensorRows: [SensorRow] {
        var rows: [SensorRow] = []
        var flat = 0
        let axes = ["x", "y", "z", "w"]
        for (index, name) in model.world.sensorNames.enumerated() {
            let kind = index < model.world.sensorKinds.count
                ? model.world.sensorKinds[index] : .jointPosition
            for component in 0..<kind.dimension {
                defer { flat += 1 }
                guard flat < model.world.sensorReadings.count else { continue }
                let label = kind.dimension == 1 ? "—" : axes[min(component, 3)]
                guard matches(name, "\(kind)") else { continue }
                rows.append(SensorRow(id: flat, name: name, kind: "\(kind)",
                                      component: label,
                                      value: model.world.sensorReadings[flat]))
            }
        }
        return rows
    }

    // MARK: Helpers

    @ViewBuilder
    private func numeric(_ value: Double, unit: String? = nil, tone: Color? = nil) -> some View {
        HStack(spacing: 2) {
            Text(value, format: .number.precision(.fractionLength(abs(value) < 10 ? 4 : 2)))
                .font(Typo.mono)
                .monospacedDigit()
                .foregroundStyle(tone ?? theme.text)
            if let unit {
                Text(unit).font(Typo.monoSmall).foregroundStyle(theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func matches(_ fields: String...) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        return fields.contains { $0.lowercased().contains(needle) }
    }

    private func describe(_ shape: Kinetic.Shape) -> String {
        switch shape {
        case .sphere(let r): return String(format: "sphere %.3f", r)
        case .box(let h): return String(format: "box %.2f×%.2f×%.2f", h.x * 2, h.y * 2, h.z * 2)
        case .capsule(let r, let l): return String(format: "capsule %.3f/%.3f", r, l * 2)
        case .cylinder(let r, let l): return String(format: "cylinder %.3f/%.3f", r, l * 2)
        case .plane: return "plane"
        case .convexHull(let m, _): return "hull #\(m)"
        }
    }
}
