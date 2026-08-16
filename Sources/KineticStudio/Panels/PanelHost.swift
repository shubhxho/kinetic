//
//  PanelHost.swift
//  Kinetic Studio
//
//  Renders a PanelNode tree. This file knows how to frame, split, drag and close
//  a panel and nothing whatsoever about what a panel displays — bodies arrive
//  through the `content` closure, which is the single seam between the layout
//  engine and the rest of the app.
//

import AppKit
import SwiftUI

private enum PanelMetric {
    static let header: CGFloat = 22
    static let divider: CGFloat = 1
    static let grab: CGFloat = 9
}

// MARK: - Host

/// Root of the panel system. Hand it a store and a closure that turns a
/// `PanelInstance` into a view; everything else is layout.
struct PanelHostView<Content: View>: View {
    @ObservedObject var store: PanelLayoutStore
    private let content: (PanelInstance) -> Content

    init(store: PanelLayoutStore,
         @ViewBuilder content: @escaping (PanelInstance) -> Content) {
        self.store = store
        self.content = content
    }

    var body: some View {
        PanelNodeView(store: store, node: store.root, path: [], content: content)
    }
}

extension PanelHostView where Content == PanelEmptyState {
    /// Layout-only host: every leaf renders the empty state. Useful before real
    /// panels are wired in, and as the documented shape of the content closure.
    init(store: PanelLayoutStore) {
        self.init(store: store, content: { PanelEmptyState(kind: $0.kind) })
    }
}

// MARK: - Recursion

private struct PanelNodeView<Content: View>: View {
    @ObservedObject var store: PanelLayoutStore
    let node: PanelNode
    /// Index path from the root, so a dragged divider can address its own split
    /// without the tree carrying identity for splits.
    let path: [Int]
    let content: (PanelInstance) -> Content

    var body: some View {
        switch node {
        case .leaf(let instance):
            PanelFrame(store: store, instance: instance) { content(instance) }
        case .split(let split):
            PanelSplitView(store: store, split: split, path: path, content: content)
        }
    }
}

/// Divides its space between two panes and a draggable divider.
///
/// Implemented with SwiftUI's `Layout` protocol — the supported extension point
/// for custom layout — rather than `HSplitView`/`VSplitView`. Those are backed by
/// `NSSplitView` and Auto Layout, and nesting them to the depth a panel tree
/// reaches turns every display cycle into a constraint-solving storm: profiling
/// a four-pane workspace showed the main thread almost entirely inside
/// `updateConstraintsForSubtreeIfNeeded` with nothing on screen moving.
///
/// `Layout` also keeps the stored fraction authoritative, so divider positions
/// survive a relaunch, which a split view's self-managed geometry would not.
struct PanelSplitLayout: Layout {
    var axis: PanelAxis
    var fraction: Double
    var dividerThickness: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    /// Resolve alignment guides from the bounds instead of from the children.
    ///
    /// `Layout`'s default implementation answers an alignment query by placing
    /// every subview and reading the winner's guide. A panel tree nests splits
    /// several deep, and the enclosing stack asks for a guide on every layout
    /// pass, so each query at the root forces a full placement of the level below
    /// it, which forces the level below that — the profile was a tower of
    /// `explicitAlignment` frames hundreds deep. Panes never export a custom
    /// guide, so the honest answer is the one derived from the frame, and it
    /// costs nothing.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        switch guide {
        case .leading: return bounds.minX
        case .trailing: return bounds.maxX
        default: return bounds.midX
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        switch guide {
        case .top: return bounds.minY
        case .bottom: return bounds.maxY
        default: return bounds.midY
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        guard subviews.count == 3 else { return }
        let total = axis == .horizontal ? bounds.width : bounds.height
        let available = max(total - dividerThickness, 0)
        let first = (available * fraction).rounded()
        let second = max(available - first, 0)

        if axis == .horizontal {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: first, height: bounds.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + first, y: bounds.minY),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: dividerThickness,
                                                         height: bounds.height))
            subviews[2].place(at: CGPoint(x: bounds.minX + first + dividerThickness,
                                          y: bounds.minY),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: second, height: bounds.height))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: first))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + first),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width,
                                                         height: dividerThickness))
            subviews[2].place(at: CGPoint(x: bounds.minX,
                                          y: bounds.minY + first + dividerThickness),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: second))
        }
    }
}

private struct PanelSplitView<Content: View>: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var store: PanelLayoutStore
    let split: PanelNode.Split
    let path: [Int]
    let content: (PanelInstance) -> Content

    /// Last measured extent along the split axis, used only to convert a drag
    /// into a fraction. It is read from a zero-impact background probe rather
    /// than a GeometryReader wrapping the content, so measuring cannot feed back
    /// into sizing.
    @State private var extent: CGFloat = 0

    var body: some View {
        PanelSplitLayout(axis: split.axis, fraction: split.fraction,
                         dividerThickness: PanelMetric.divider) {
            child(split.first, index: 0)
            divider
            child(split.second, index: 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, size in
                        extent = split.axis == .horizontal ? size.width : size.height
                    }
            }
        }
    }

    private var divider: some View {
        Divider()
            .overlay {
                // The line is a hairline; the grab area is not. Separating them is
                // what makes a 1pt divider comfortable to hit.
                Rectangle()
                    .fill(.clear)
                    .frame(width: split.axis == .horizontal ? PanelMetric.grab : nil,
                           height: split.axis == .vertical ? PanelMetric.grab : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (split.axis == .horizontal ? NSCursor.resizeLeftRight
                                                       : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(spaceName))
                            .onChanged { value in
                                guard extent > 1 else { return }
                                let position = split.axis == .horizontal
                                    ? value.location.x : value.location.y
                                store.setFraction(path, to: Double(position / extent))
                            })
            }
            .coordinateSpace(name: spaceName)
    }

    private var spaceName: String { "split-\(path.map(String.init).joined(separator: "-"))" }

    // Type-erased purely to break the otherwise infinite `Body` recursion of a
    // view that contains itself.
    private func child(_ node: PanelNode, index: Int) -> AnyView {
        AnyView(
            PanelNodeView(store: store, node: node, path: path + [index], content: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

// MARK: - Leaf chrome

/// The frame around one panel: a 22pt header that stays out of the way until you
/// point at it, and the panel's own body underneath.
struct PanelFrame<Content: View>: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var store: PanelLayoutStore
    let instance: PanelInstance
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    private var isFocused: Bool { store.focusedPanelID == instance.id }
    private var revealed: Bool { hovering || isFocused }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(theme.background)
        .overlay(
            Rectangle()
                .stroke(isFocused ? theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false))
        .contentShape(Rectangle())
        // Simultaneous so controls inside the panel body still get the click.
        .simultaneousGesture(TapGesture().onEnded { store.focus(instance.id) })
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: instance.kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(revealed ? theme.secondary : theme.tertiary)
            Text(instance.kind.title)
                .font(Typo.small.weight(.medium))
                .foregroundStyle(revealed ? theme.text : theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            actions
                // Kept in the layout at all times so the title never shifts when
                // the pointer arrives.
                .opacity(revealed ? 1 : 0)
                .allowsHitTesting(revealed)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: PanelMetric.header)
        .background(revealed ? theme.surface : theme.background)
        .animation(.easeOut(duration: 0.1), value: revealed)
    }

    private var actions: some View {
        HStack(spacing: 1) {
            Menu {
                ForEach(PanelKind.pickerOrder, id: \.self) { kind in
                    Button {
                        store.replace(instance.id, with: kind)
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                    .help(kind.summary)
                }
            } label: {
                PanelHeaderGlyph(systemImage: "rectangle.3.group")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change panel type")

            Menu {
                Button("Split Right") { store.split(instance.id, axis: .horizontal) }
                Button("Split Down") { store.split(instance.id, axis: .vertical) }
                Divider()
                Menu("Split Right As") {
                    ForEach(PanelKind.pickerOrder, id: \.self) { kind in
                        Button(kind.title) {
                            store.split(instance.id, axis: .horizontal, kind: kind)
                        }
                    }
                }
                Menu("Split Down As") {
                    ForEach(PanelKind.pickerOrder, id: \.self) { kind in
                        Button(kind.title) {
                            store.split(instance.id, axis: .vertical, kind: kind)
                        }
                    }
                }
            } label: {
                PanelHeaderGlyph(systemImage: "square.split.2x1")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Split panel")

            PanelHeaderButton(systemImage: "xmark", help: "Close panel") {
                store.close(instance.id)
            }
            .disabled(store.panelCount <= 1)
        }
    }
}

private struct PanelHeaderGlyph: View {
    @Environment(\.studioTheme) private var theme
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.secondary)
            .frame(width: 18, height: 16)
            .contentShape(Rectangle())
    }
}

private struct PanelHeaderButton: View {
    @Environment(\.studioTheme) private var theme
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? theme.text : theme.secondary)
                .frame(width: 18, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hovering ? theme.border.opacity(0.6) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Empty state

/// Shown when a leaf has no body to render — an unimplemented panel kind, or a
/// panel whose data source has gone away.
struct PanelEmptyState: View {
    @Environment(\.studioTheme) private var theme
    let kind: PanelKind
    var message: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(theme.tertiary)
            Text(kind.title)
                .font(Typo.small.weight(.medium))
                .foregroundStyle(theme.secondary)
            Text(message ?? kind.summary)
                .font(Typo.small)
                .foregroundStyle(theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(Metric.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

// MARK: - Commands

/// Keyboard actions as data. The store owns the behaviour and this table owns
/// the key bindings, so the same actions can be driven from a menu bar, the
/// command palette, or a test without duplicating the logic.
@MainActor
struct PanelCommandAction: Identifiable {
    let id: String
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let perform: (PanelLayoutStore) -> Void

    static let splitRight = PanelCommandAction(
        id: "panel.splitRight", title: "Split Right",
        key: "\\", modifiers: .command) { $0.splitFocusedRight() }

    static let splitDown = PanelCommandAction(
        id: "panel.splitDown", title: "Split Down",
        key: "\\", modifiers: [.command, .shift]) { $0.splitFocusedDown() }

    static let closePanel = PanelCommandAction(
        id: "panel.close", title: "Close Panel",
        key: "w", modifiers: .command) { $0.closeFocused() }

    static let focusNext = PanelCommandAction(
        id: "panel.focusNext", title: "Focus Next Panel",
        key: "]", modifiers: [.command, .option]) { $0.focusNextPanel() }

    static let focusPrevious = PanelCommandAction(
        id: "panel.focusPrevious", title: "Focus Previous Panel",
        key: "[", modifiers: [.command, .option]) { $0.focusNextPanel(reverse: true) }

    static let all: [PanelCommandAction] = [
        splitRight, splitDown, closePanel, focusNext, focusPrevious,
    ]
}

/// Drop into a `Scene`'s `commands` to bind the actions above.
@MainActor
struct PanelCommands: Commands {
    let store: PanelLayoutStore

    var body: some Commands {
        CommandMenu("Panel") {
            ForEach(PanelCommandAction.all) { action in
                Button(action.title) { action.perform(store) }
                    .keyboardShortcut(action.key, modifiers: action.modifiers)
            }
            Divider()
            Menu("Layout") {
                ForEach(PanelLayoutPreset.builtins) { preset in
                    Button(preset.name) { store.apply(preset) }
                }
            }
        }
    }
}
