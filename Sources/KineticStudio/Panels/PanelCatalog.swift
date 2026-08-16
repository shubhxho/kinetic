//
//  PanelCatalog.swift
//  Kinetic Studio
//
//  The registry of panel types the layout engine can place. Deliberately a plain
//  enum rather than a protocol with registered instances: the layout tree is
//  Codable and persisted, so a panel's identity has to survive as a stable
//  string that outlives whatever view happens to render it today.
//

import Foundation

enum PanelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case viewport3D
    case plot
    case rawMessages
    case table
    case stateTransitions
    case diagnostics
    case log
    case jointControl
    case actuatorControl
    case sceneTree
    case inspector
    case mlInsights

    var title: String {
        switch self {
        case .viewport3D: return "3D Viewport"
        case .plot: return "Plot"
        case .rawMessages: return "Raw Messages"
        case .table: return "Table"
        case .stateTransitions: return "State Transitions"
        case .diagnostics: return "Diagnostics"
        case .log: return "Log"
        case .jointControl: return "Joint Control"
        case .actuatorControl: return "Actuator Control"
        case .sceneTree: return "Scene Tree"
        case .inspector: return "Inspector"
        case .mlInsights: return "ML Insights"
        }
    }

    var systemImage: String {
        switch self {
        case .viewport3D: return "cube.transparent"
        case .plot: return "waveform.path.ecg"
        case .rawMessages: return "curlybraces"
        case .table: return "tablecells"
        case .stateTransitions: return "arrow.triangle.branch"
        case .diagnostics: return "stethoscope"
        case .log: return "text.alignleft"
        case .jointControl: return "slider.horizontal.3"
        case .actuatorControl: return "bolt.horizontal"
        case .sceneTree: return "list.bullet.indent"
        case .inspector: return "square.on.square.dashed"
        case .mlInsights: return "sparkles"
        }
    }

    /// One line, sentence case, no trailing period — the picker stacks these
    /// under the title and anything longer wraps into the next row.
    var summary: String {
        switch self {
        case .viewport3D: return "Rendered scene with camera, gizmos and contact overlays"
        case .plot: return "Time series of any numeric channel, scrubbed with the timeline"
        case .rawMessages: return "Decoded message payloads for a single topic"
        case .table: return "Repeated message fields laid out as sortable columns"
        case .stateTransitions: return "Discrete state changes drawn as a timeline of bands"
        case .diagnostics: return "Solver health, constraint residuals and step budget"
        case .log: return "Console output from the engine, bridge and scripts"
        case .jointControl: return "Drive joint positions directly and watch limits"
        case .actuatorControl: return "Command actuators and inspect applied effort"
        case .sceneTree: return "Body, joint and geometry hierarchy of the loaded model"
        case .inspector: return "Properties of the current selection"
        case .mlInsights: return "Policy inputs, action distributions and reward terms"
        }
    }
}

extension PanelKind {
    /// Ordering for the "change panel type" menu: viewport-like things first,
    /// then analysis, then control, then editors.
    static var pickerOrder: [PanelKind] {
        [.viewport3D, .plot, .table, .stateTransitions,
         .rawMessages, .diagnostics, .log, .mlInsights,
         .jointControl, .actuatorControl,
         .sceneTree, .inspector]
    }
}
