//
//  PanelLayout.swift
//  Kinetic Studio
//
//  The layout model. Deliberately free of SwiftUI: a workspace is a binary split
//  tree of value types, every mutation returns a brand new tree, and the whole
//  thing round-trips through JSON. That makes layout behaviour unit-testable
//  without a window, and makes undo/redo or preset switching a plain assignment.
//

import Combine
import Foundation

// MARK: - Tree

/// Which way a split cuts its box.
///
/// `.horizontal` places children side by side (the divider is a vertical line
/// you drag left/right); `.vertical` stacks them (divider drags up/down). This
/// matches `ResizeHandle.Axis` in ContentView so the two systems read alike.
enum PanelAxis: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}

/// One placed panel. The identity is the `id`, not the `kind` — the same kind
/// can appear many times, and a panel keeps its identity (and its settings)
/// across splits and moves.
struct PanelInstance: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: PanelKind
    /// Free-form per-panel configuration owned by whatever view renders the
    /// panel. Kept as strings so the layout can be persisted without the layout
    /// engine knowing a single thing about any panel's schema.
    var settings: [String: String]

    init(id: UUID = UUID(), kind: PanelKind, settings: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, settings
    }

    // Settings are optional on the way in so a layout written before a panel
    // gained configuration still decodes.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  kind: try container.decode(PanelKind.self, forKey: .kind),
                  settings: try container.decodeIfPresent([String: String].self,
                                                          forKey: .settings) ?? [:])
    }
}

enum PanelNode: Codable, Hashable, Sendable {
    case leaf(PanelInstance)
    indirect case split(Split)

    typealias Axis = PanelAxis

    struct Split: Codable, Hashable, Sendable {
        var axis: Axis
        /// Share of the available extent given to `first`, clamped to
        /// `PanelNode.fractionRange` so a pane can never be dragged to nothing.
        private(set) var fraction: Double
        var first: PanelNode
        var second: PanelNode

        init(axis: Axis, fraction: Double, first: PanelNode, second: PanelNode) {
            self.axis = axis
            self.fraction = PanelNode.clamp(fraction)
            self.first = first
            self.second = second
        }

        mutating func setFraction(_ value: Double) {
            fraction = PanelNode.clamp(value)
        }

        func withFraction(_ value: Double) -> Split {
            Split(axis: axis, fraction: value, first: first, second: second)
        }

        // Hand-rolled so a hand-edited or older file with a wild fraction is
        // clamped on the way in rather than producing an unusable pane.
        private enum CodingKeys: String, CodingKey {
            case axis, fraction, first, second
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(axis: try container.decode(Axis.self, forKey: .axis),
                      fraction: try container.decode(Double.self, forKey: .fraction),
                      first: try container.decode(PanelNode.self, forKey: .first),
                      second: try container.decode(PanelNode.self, forKey: .second))
        }
    }

    static let fractionRange: ClosedRange<Double> = 0.05...0.95

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, fractionRange.lowerBound), fractionRange.upperBound)
    }
}

// MARK: - Coding

extension PanelNode {
    private enum CodingKeys: String, CodingKey {
        case type, panel, split
    }

    private enum NodeType: String, Codable {
        case leaf, split
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .leaf:
            self = .leaf(try container.decode(PanelInstance.self, forKey: .panel))
        case .split:
            self = .split(try container.decode(Split.self, forKey: .split))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let instance):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(instance, forKey: .panel)
        case .split(let split):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

// MARK: - Construction helpers

extension PanelNode {
    static func panel(_ kind: PanelKind, settings: [String: String] = [:]) -> PanelNode {
        .leaf(PanelInstance(kind: kind, settings: settings))
    }

    /// Children side by side.
    static func row(_ fraction: Double, _ first: PanelNode, _ second: PanelNode) -> PanelNode {
        .split(Split(axis: .horizontal, fraction: fraction, first: first, second: second))
    }

    /// Children stacked.
    static func column(_ fraction: Double, _ first: PanelNode, _ second: PanelNode) -> PanelNode {
        .split(Split(axis: .vertical, fraction: fraction, first: first, second: second))
    }
}

// MARK: - Queries

extension PanelNode {
    /// Every panel in reading order: left to right, top to bottom. Stable across
    /// mutations of unrelated branches, which is what makes "focus the next
    /// panel" and keyboard traversal predictable.
    var panels: [PanelInstance] {
        switch self {
        case .leaf(let instance):
            return [instance]
        case .split(let split):
            return split.first.panels + split.second.panels
        }
    }

    var panelCount: Int {
        switch self {
        case .leaf: return 1
        case .split(let split): return split.first.panelCount + split.second.panelCount
        }
    }

    func find(_ id: UUID) -> PanelInstance? {
        switch self {
        case .leaf(let instance):
            return instance.id == id ? instance : nil
        case .split(let split):
            return split.first.find(id) ?? split.second.find(id)
        }
    }

    func contains(_ id: UUID) -> Bool {
        find(id) != nil
    }

    /// Index path of child choices (0 = first, 1 = second) from the receiver to
    /// the leaf holding `id`. The rendering layer hands the same shape back to
    /// `setFraction` when a divider is dragged.
    func path(to id: UUID) -> [Int]? {
        switch self {
        case .leaf(let instance):
            return instance.id == id ? [] : nil
        case .split(let split):
            if let sub = split.first.path(to: id) { return [0] + sub }
            if let sub = split.second.path(to: id) { return [1] + sub }
            return nil
        }
    }

    /// First leaf in reading order — the fallback target when nothing is focused.
    var firstPanelID: UUID? {
        panels.first?.id
    }
}

// MARK: - Mutations

extension PanelNode {
    /// Replaces the leaf `id` with a split holding the original panel first and
    /// `newPanel` second. A no-op when `id` is not present, so callers can fire
    /// commands at a stale focus id without guarding.
    func split(_ id: UUID, axis: Axis, newPanel: PanelKind) -> PanelNode {
        split(id, axis: axis, newPanel: PanelInstance(kind: newPanel))
    }

    /// Instance-taking variant: the caller keeps the new panel's id so it can
    /// move focus onto it after the split.
    func split(_ id: UUID, axis: Axis, newPanel: PanelInstance) -> PanelNode {
        switch self {
        case .leaf(let instance):
            guard instance.id == id else { return self }
            return .split(Split(axis: axis, fraction: 0.5,
                                first: .leaf(instance), second: .leaf(newPanel)))
        case .split(let split):
            return .split(Split(axis: split.axis, fraction: split.fraction,
                                first: split.first.split(id, axis: axis, newPanel: newPanel),
                                second: split.second.split(id, axis: axis, newPanel: newPanel)))
        }
    }

    /// Removes a leaf and collapses the split that held it, promoting the
    /// sibling into the parent's slot. Returns nil once the tree is empty, which
    /// is the store's signal that the workspace has no panels left.
    func close(_ id: UUID) -> PanelNode? {
        switch self {
        case .leaf(let instance):
            return instance.id == id ? nil : self
        case .split(let split):
            let first = split.first.close(id)
            let second = split.second.close(id)
            guard let first else { return second }
            guard let second else { return first }
            return .split(Split(axis: split.axis, fraction: split.fraction,
                                first: first, second: second))
        }
    }

    /// Swaps the panel type in place. Settings are dropped because they belong
    /// to the outgoing kind's schema and would be meaningless to the new one.
    func replace(_ id: UUID, with kind: PanelKind) -> PanelNode {
        transform(id) { PanelInstance(id: $0.id, kind: kind) }
    }

    func setSettings(_ id: UUID, _ settings: [String: String]) -> PanelNode {
        transform(id) { PanelInstance(id: $0.id, kind: $0.kind, settings: settings) }
    }

    func setSetting(_ id: UUID, key: String, value: String?) -> PanelNode {
        transform(id) { instance in
            var settings = instance.settings
            settings[key] = value
            return PanelInstance(id: instance.id, kind: instance.kind, settings: settings)
        }
    }

    /// Moves the divider of the split reached by `splitPath`. An empty path
    /// means the root. Paths that miss a split leave the tree untouched.
    func setFraction(_ splitPath: [Int], to fraction: Double) -> PanelNode {
        guard case .split(let split) = self else { return self }
        guard let step = splitPath.first else {
            return .split(split.withFraction(fraction))
        }
        let rest = Array(splitPath.dropFirst())
        if step == 0 {
            return .split(Split(axis: split.axis, fraction: split.fraction,
                                first: split.first.setFraction(rest, to: fraction),
                                second: split.second))
        }
        return .split(Split(axis: split.axis, fraction: split.fraction,
                            first: split.first,
                            second: split.second.setFraction(rest, to: fraction)))
    }

    /// Fraction currently stored at `splitPath`, or nil if the path is not a split.
    func fraction(at splitPath: [Int]) -> Double? {
        guard case .split(let split) = self else { return nil }
        guard let step = splitPath.first else { return split.fraction }
        let rest = Array(splitPath.dropFirst())
        return step == 0 ? split.first.fraction(at: rest) : split.second.fraction(at: rest)
    }

    private func transform(_ id: UUID,
                           _ body: (PanelInstance) -> PanelInstance) -> PanelNode {
        switch self {
        case .leaf(let instance):
            return instance.id == id ? .leaf(body(instance)) : self
        case .split(let split):
            return .split(Split(axis: split.axis, fraction: split.fraction,
                                first: split.first.transform(id, body),
                                second: split.second.transform(id, body)))
        }
    }
}

// MARK: - Presets

struct PanelLayoutPreset: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var root: PanelNode

    var id: String { name }

    init(name: String, root: PanelNode) {
        self.name = name
        self.root = root
    }
}

extension PanelLayoutPreset {
    /// Workspaces shipped with the app. Each one is rebuilt on access so the
    /// panel ids are fresh — applying the same preset twice must not produce two
    /// trees that share leaf identity.
    static var builtins: [PanelLayoutPreset] {
        [simulate, analyse, debug, foxglove]
    }

    /// Viewport dominant, scene context on the left, properties and telemetry to
    /// the right — the default when nothing has been saved yet.
    static var simulate: PanelLayoutPreset {
        PanelLayoutPreset(
            name: "Simulate",
            root: .row(0.18,
                       .panel(.sceneTree),
                       .row(0.72,
                            .column(0.74, .panel(.viewport3D), .panel(.plot)),
                            .column(0.58, .panel(.inspector), .panel(.jointControl)))))
    }

    static var analyse: PanelLayoutPreset {
        PanelLayoutPreset(
            name: "Analyse",
            root: .column(0.5,
                          .row(0.5, .panel(.plot), .panel(.plot)),
                          .row(0.5, .panel(.plot), .panel(.table))))
    }

    static var debug: PanelLayoutPreset {
        PanelLayoutPreset(
            name: "Debug",
            root: .row(0.55,
                       .column(0.66, .panel(.viewport3D), .panel(.diagnostics)),
                       .column(0.55, .panel(.rawMessages), .panel(.log))))
    }

    /// A 2x2 grid in the shape of a stock Foxglove workspace, for anyone
    /// arriving from that tool.
    static var foxglove: PanelLayoutPreset {
        PanelLayoutPreset(
            name: "Foxglove",
            root: .row(0.5,
                       .column(0.5, .panel(.viewport3D), .panel(.rawMessages)),
                       .column(0.5, .panel(.plot), .panel(.log))))
    }

    static var `default`: PanelLayoutPreset { simulate }
}

// MARK: - Store

/// Owns the live tree, applies the pure operations above, and mirrors the result
/// into `UserDefaults`. Every mutation is a whole-tree replacement, so SwiftUI
/// diffing and any future undo stack both get a clean value to work with.
@MainActor
final class PanelLayoutStore: ObservableObject {
    /// Versioned on purpose: a future tree shape ships under `.v2` and simply
    /// finds nothing at its key, falling back to a builtin instead of trying to
    /// migrate a format we no longer understand.
    static let storageKey = "studio.panels.layout.v1"

    @Published private(set) var root: PanelNode {
        didSet { persist() }
    }

    /// The panel keyboard commands act on. Kept here rather than in SwiftUI's
    /// focus system because a panel's body may contain its own focusable
    /// controls, and `⌘W` must still mean "close this panel".
    @Published var focusedPanelID: UUID?

    /// Name of the preset last applied, cleared as soon as the user edits the
    /// layout so the UI never claims to be showing a preset it has diverged from.
    @Published private(set) var activePresetName: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         fallback: PanelLayoutPreset = .default) {
        self.defaults = defaults
        let restored = Self.restore(from: defaults)
        self.root = restored?.root ?? fallback.root
        self.activePresetName = restored?.name ?? fallback.name
        self.focusedPanelID = self.root.firstPanelID
    }

    // MARK: Queries

    var panels: [PanelInstance] { root.panels }

    var panelCount: Int { root.panelCount }

    func find(_ id: UUID) -> PanelInstance? { root.find(id) }

    var focusedPanel: PanelInstance? {
        guard let focusedPanelID else { return nil }
        return root.find(focusedPanelID)
    }

    /// Focus, or the first panel if focus is stale — command handlers need a
    /// target even when the user has not clicked a panel yet.
    var commandTargetID: UUID? {
        if let focusedPanelID, root.contains(focusedPanelID) { return focusedPanelID }
        return root.firstPanelID
    }

    // MARK: Mutations

    func focus(_ id: UUID) {
        guard focusedPanelID != id else { return }
        focusedPanelID = id
    }

    @discardableResult
    func split(_ id: UUID, axis: PanelAxis, kind: PanelKind? = nil) -> UUID? {
        guard let existing = root.find(id) else { return nil }
        // Splitting duplicates the panel by default: the common gesture is
        // "show me this again next to itself" (two plots, two camera angles).
        let instance = PanelInstance(kind: kind ?? existing.kind)
        root = root.split(id, axis: axis, newPanel: instance)
        activePresetName = nil
        focusedPanelID = instance.id
        return instance.id
    }

    func close(_ id: UUID) {
        guard let next = root.close(id) else { return }  // never close the last panel
        root = next
        activePresetName = nil
        if focusedPanelID == id || focusedPanelID.map({ !next.contains($0) }) == true {
            focusedPanelID = next.firstPanelID
        }
    }

    func replace(_ id: UUID, with kind: PanelKind) {
        root = root.replace(id, with: kind)
        activePresetName = nil
    }

    func setFraction(_ splitPath: [Int], to fraction: Double) {
        root = root.setFraction(splitPath, to: fraction)
        activePresetName = nil
    }

    /// Panels persist their own configuration through here; the store treats the
    /// bag as opaque.
    func setSetting(_ id: UUID, key: String, value: String?) {
        root = root.setSetting(id, key: key, value: value)
    }

    func setSettings(_ id: UUID, _ settings: [String: String]) {
        root = root.setSettings(id, settings)
    }

    func apply(_ preset: PanelLayoutPreset) {
        root = preset.root
        activePresetName = preset.name
        focusedPanelID = root.firstPanelID
    }

    func resetToDefault() {
        apply(.default)
    }

    // MARK: Command actions

    var canCloseFocusedPanel: Bool { panelCount > 1 }

    func splitFocusedRight() {
        guard let id = commandTargetID else { return }
        split(id, axis: .horizontal)
    }

    func splitFocusedDown() {
        guard let id = commandTargetID else { return }
        split(id, axis: .vertical)
    }

    func closeFocused() {
        guard let id = commandTargetID else { return }
        close(id)
    }

    /// Moves focus through `panels` order, wrapping — the tree has no notion of
    /// geometry, so "next" means reading order rather than spatial adjacency.
    func focusNextPanel(reverse: Bool = false) {
        let all = panels
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.id == focusedPanelID } ?? 0
        let step = reverse ? -1 : 1
        let next = (current + step + all.count) % all.count
        focusedPanelID = all[next].id
    }

    // MARK: Persistence

    private func persist() {
        let preset = PanelLayoutPreset(name: activePresetName ?? "Custom", root: root)
        guard let data = try? JSONEncoder().encode(preset) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Any decode failure is treated as "no saved layout": a corrupt blob must
    /// cost the user their arrangement, never the launch.
    private static func restore(from defaults: UserDefaults) -> PanelLayoutPreset? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard let preset = try? JSONDecoder().decode(PanelLayoutPreset.self, from: data) else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        return preset
    }
}
