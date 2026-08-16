//
//  FoxgloveMode.swift
//  Kinetic Studio
//
//  Foxglove mode is one switch that changes what kind of application Studio is.
//  Off, it is a simulator: a viewport with an inspector, talking about channels
//  and a scene. On, it is a Foxglove workspace: a panel grid talking about
//  topics and connections, either serving its own simulation or attached to a
//  Kinetic instance running somewhere else.
//
//  Three things move when the switch flips, and all three live here so the rest
//  of the app never has to ask "are we in Foxglove mode":
//
//    1. Transport — the local bridge starts (local source) or the client
//       connects (remote source).
//    2. Layout — the workspace preset changes. Applied through a closure rather
//       than a direct reference to the layout store, because the mode has no
//       business knowing how panels are stored, and the app wires the two
//       together in one place.
//    3. Language — every user-facing noun comes from `vocabulary`. A view that
//       hard-codes "channels" is a view that lies to a Foxglove user, so the
//       strings are data, not literals.
//

import Combine
import Foundation
import KineticBridge
import SwiftUI

// MARK: - Vocabulary

/// The nouns the interface speaks in. Two dialects for the same objects: what
/// Kinetic calls a channel, Foxglove calls a topic, and a user who arrived from
/// one tool should never have to learn the other's word for the same thing.
public struct FoxgloveVocabulary: Equatable, Sendable {
    public var modeName: String
    public var channel: String
    public var channelPlural: String
    public var panel: String
    public var panelPlural: String
    public var workspace: String
    public var server: String
    public var viewer: String
    public var viewerPlural: String
    public var source: String

    public static let native = FoxgloveVocabulary(
        modeName: "Studio",
        channel: "channel", channelPlural: "channels",
        panel: "panel", panelPlural: "panels",
        workspace: "layout",
        server: "telemetry server",
        viewer: "viewer", viewerPlural: "viewers",
        source: "simulation")

    public static let foxglove = FoxgloveVocabulary(
        modeName: "Foxglove",
        channel: "topic", channelPlural: "topics",
        panel: "panel", panelPlural: "panels",
        workspace: "workspace",
        server: "WebSocket server",
        viewer: "client", viewerPlural: "clients",
        source: "data source")

    /// "1 topic" / "4 topics" — pluralisation belongs next to the nouns.
    public func channels(_ count: Int) -> String {
        "\(count) \(count == 1 ? channel : channelPlural)"
    }

    public func viewers(_ count: Int) -> String {
        "\(count) \(count == 1 ? viewer : viewerPlural)"
    }

    public func panels(_ count: Int) -> String {
        "\(count) \(count == 1 ? panel : panelPlural)"
    }

    /// Sentence-case form for headers and buttons.
    public func titled(_ noun: String) -> String {
        guard let first = noun.first else { return noun }
        return first.uppercased() + noun.dropFirst()
    }
}

private struct VocabularyKey: EnvironmentKey {
    static let defaultValue = FoxgloveVocabulary.native
}

extension EnvironmentValues {
    /// Views read their nouns from here, the same way they read colours from
    /// `studioTheme`, so relabelling the app is one `.environment` call.
    var foxgloveVocabulary: FoxgloveVocabulary {
        get { self[VocabularyKey.self] }
        set { self[VocabularyKey.self] = newValue }
    }
}

// MARK: - Controller

@MainActor
public final class FoxgloveModeController: ObservableObject {

    /// Where the data comes from while the mode is on.
    public enum Source: Equatable, Sendable {
        /// This process's own world, served by `FoxgloveBridge`.
        case localSimulation
        /// Another machine's `foxglove.websocket.v1` server.
        case remote(URL)

        public var isRemote: Bool {
            if case .remote = self { return true }
            return false
        }

        public var url: URL? {
            if case .remote(let url) = self { return url }
            return nil
        }
    }

    /// Which layout preset the app should be showing.
    public enum Workspace: String, Sendable {
        case native
        case foxglove
    }

    // MARK: The switch

    /// The Foxglove switch. Everything else in this class is a consequence of it.
    @Published public var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            apply()
        }
    }

    /// Local simulation or a remote server. Changing it while the mode is on
    /// re-points the transport immediately.
    @Published public var source: Source = .localSimulation {
        didSet {
            guard oldValue != source else { return }
            if isEnabled { apply() }
        }
    }

    /// Whether Kinetic's own bridge is serving. Independent of `isEnabled` on
    /// purpose: a user can serve telemetry to a colleague's Foxglove without
    /// turning their own Studio into one.
    @Published public var serverEnabled = false {
        didSet {
            guard oldValue != serverEnabled else { return }
            serverEnabled ? onStartServer?(portNumber) : onStopServer?()
        }
    }

    /// Host or full URL for `.remote`. Free text so `robot.local`, `10.0.0.4`
    /// and `wss://relay.example/kinetic` are all accepted.
    @Published public var address = "localhost"
    @Published public var port = 8765

    /// Clients attached to our server, pushed in by whoever owns the bridge.
    @Published public private(set) var serverConnections = 0

    /// Topics subscribed automatically on connect: the ones Studio can actually
    /// render without further configuration.
    public var autoSubscribeTopics = ["/kinetic/state", "/kinetic/profile", "/kinetic/sensors"]

    /// The consuming half of the bridge. Public because panels bind to its
    /// `@Published` state directly rather than through this controller.
    public let client: FoxgloveClient

    // MARK: Wiring
    //
    // Closures rather than references: the mode drives the app, and injecting
    // the app's objects here would make this class untestable and couple it to
    // files it does not own.

    public var onStartServer: ((UInt16) -> Void)?
    public var onStopServer: (() -> Void)?
    public var onApplyWorkspace: ((Workspace) -> Void)?
    public var onLog: ((String) -> Void)?

    public init(client: FoxgloveClient = FoxgloveClient()) {
        self.client = client
        client.onLog = { [weak self] message in
            // Socket callbacks arrive off the main queue; the console is UI.
            Task { @MainActor in self?.onLog?("foxglove: \(message)") }
        }
    }

    // MARK: Derived state

    public var vocabulary: FoxgloveVocabulary { isEnabled ? .foxglove : .native }

    public var workspace: Workspace { isEnabled ? .foxglove : .native }

    public var portNumber: UInt16 { UInt16(clamping: port) }

    public var connectionState: FoxgloveClient.ConnectionState { client.connectionState }

    /// What the switch shows next to the dot.
    public var displayAddress: String {
        switch source {
        case .localSimulation: return "ws://localhost:\(port)"
        case .remote(let url): return url.absoluteString
        }
    }

    /// The count that matters for the current source: clients attached to us
    /// when serving, topics arriving when consuming.
    public var displayCount: String {
        switch source {
        case .localSimulation: return vocabulary.viewers(serverConnections)
        case .remote: return vocabulary.channels(client.channels.count)
        }
    }

    public var statusTone: Color {
        switch source {
        case .localSimulation:
            if !serverEnabled { return Palette.textTertiary }
            return serverConnections > 0 ? Palette.success : Palette.warning
        case .remote:
            switch client.connectionState {
            case .connected: return Palette.success
            case .connecting: return Palette.warning
            case .failed: return Palette.danger
            case .disconnected: return Palette.textTertiary
            }
        }
    }

    public var statusText: String {
        switch source {
        case .localSimulation:
            return serverEnabled ? "serving" : "idle"
        case .remote:
            switch client.connectionState {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .failed(let reason): return reason
            }
        }
    }

    // MARK: Actions

    public func toggle() {
        isEnabled.toggle()
    }

    /// Parses `address` and `port` into a websocket URL, tolerating a bare host,
    /// a host:port pair, or a full ws:// or wss:// URL.
    public func remoteURL() -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "ws://" + text }
        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty else { return nil }
        if components.port == nil { components.port = port }
        return components.url
    }

    /// Connect button: switches the source to remote and turns the mode on.
    public func connectToRemote() {
        guard let url = remoteURL() else {
            onLog?("foxglove: '\(address)' is not a usable websocket address")
            return
        }
        source = .remote(url)
        if isEnabled {
            apply()
        } else {
            isEnabled = true
        }
    }

    public func disconnectFromRemote() {
        client.disconnect()
        source = .localSimulation
    }

    /// Points the client at this process's own server.
    ///
    /// This is the integration test for the two halves of the bridge, exposed as
    /// a real feature because it is also genuinely useful: it renders Studio's
    /// own telemetry through exactly the path a remote viewer sees, so anything
    /// wrong with the encoding shows up locally.
    public func connectToOwnServer() {
        serverEnabled = true
        address = "ws://localhost:\(port)"
        connectToRemote()
    }

    public func updateServerConnections(_ count: Int) {
        guard serverConnections != count else { return }
        serverConnections = count
    }

    public func setSubscribed(_ subscribed: Bool, to topic: String) {
        client.setSubscribed(subscribed, to: topic)
    }

    // MARK: Application of state

    private func apply() {
        onApplyWorkspace?(workspace)

        guard isEnabled else {
            client.disconnect()
            onLog?("foxglove mode off")
            return
        }

        switch source {
        case .localSimulation:
            client.disconnect()
            serverEnabled = true
            onLog?("foxglove mode on — serving ws://localhost:\(port)")
        case .remote(let url):
            client.connect(to: url)
            for topic in autoSubscribeTopics { client.subscribe(to: topic) }
            onLog?("foxglove mode on — following \(url.absoluteString)")
        }
    }
}

// MARK: - Glass

/// Liquid Glass on macOS 26, `.ultraThinMaterial` below it. Written here rather
/// than borrowed so the switch keeps working regardless of what the shared glass
/// layer looks like on any given day; the geometry matches it either way.
private struct FoxgloveGlass: ViewModifier {
    @Environment(\.studioTheme) private var theme
    var tint: Color
    var cornerRadius: CGFloat
    var interactive: Bool

    @available(macOS 26.0, *)
    private var glass: Glass {
        let base = Glass.regular.tint(tint)
        return interactive ? base.interactive() : base
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(tint.opacity(0.16)))
                .background(shape.fill(theme.isDark ? Color.black.opacity(0.34)
                                                    : Color.white.opacity(0.52)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(theme.isDark ? Color.white.opacity(0.12)
                                                         : Color.black.opacity(0.08),
                                            lineWidth: 1))
        }
    }
}

private extension View {
    func foxgloveGlass(tint: Color,
                       cornerRadius: CGFloat = Metric.radiusLarge,
                       interactive: Bool = false) -> some View {
        modifier(FoxgloveGlass(tint: tint, cornerRadius: cornerRadius, interactive: interactive))
    }
}

/// The state dot. A ring at rest, a filled glow when live — readable at a glance
/// from across a desk, which a colour change alone is not.
private struct ConnectionDot: View {
    let tone: Color
    var active: Bool

    var body: some View {
        Circle()
            .fill(tone)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(tone.opacity(0.35), lineWidth: active ? 3 : 0))
            .shadow(color: active ? tone.opacity(0.7) : .clear, radius: 4)
            .animation(.easeOut(duration: 0.2), value: active)
    }
}

// MARK: - The switch

/// The Foxglove switch: a tactile, glassy toggle with the connection state, the
/// address, and the count that matters for the current source. Clicking the body
/// flips the mode; clicking the chevron opens the settings popover.
struct FoxgloveSwitch: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var controller: FoxgloveModeController
    @ObservedObject private var client: FoxgloveClient

    @State private var hovering = false
    @State private var showingDetails = false

    /// The client is a second observable hanging off the controller, and nested
    /// `ObservableObject`s do not propagate; observing it explicitly is what
    /// keeps the topic count and connection state live.
    init(controller: FoxgloveModeController) {
        _controller = ObservedObject(wrappedValue: controller)
        _client = ObservedObject(wrappedValue: controller.client)
    }

    private var tint: Color {
        controller.isEnabled ? Palette.violet : theme.border
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(controller.isEnabled ? Palette.violet : theme.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Foxglove")
                            .font(Typo.title)
                            .foregroundStyle(theme.text)
                        Text(controller.isEnabled ? controller.displayAddress : "off")
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                            .lineLimit(1)
                    }
                    ConnectionDot(tone: controller.statusTone,
                                  active: controller.isEnabled)
                    if controller.isEnabled {
                        Chip(text: controller.displayCount, tone: Palette.violet)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isEnabled
                  ? "Foxglove mode on — \(controller.statusText)"
                  : "Switch Studio into a Foxglove workspace")

            Button {
                showingDetails.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                FoxglovePopover(controller: controller)
                    .environment(\.studioTheme, theme)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foxgloveGlass(tint: tint.opacity(hovering ? 0.9 : 0.7), interactive: true)
        .scaleEffect(hovering ? 1.01 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: controller.isEnabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - Popover

private struct FoxglovePopover: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var controller: FoxgloveModeController
    @ObservedObject private var client: FoxgloveClient

    init(controller: FoxgloveModeController) {
        _controller = ObservedObject(wrappedValue: controller)
        _client = ObservedObject(wrappedValue: controller.client)
    }

    private var vocabulary: FoxgloveVocabulary { controller.vocabulary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            connectionForm
            Divider()
            topicList
        }
        .frame(width: 320)
        .background(theme.surface)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ConnectionDot(tone: controller.statusTone, active: controller.isEnabled)
            Text(controller.statusText)
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: $controller.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Palette.violet)
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 10)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "connection")

            HStack(spacing: 6) {
                Text("address")
                    .font(Typo.small)
                    .foregroundStyle(theme.secondary)
                    .frame(width: 54, alignment: .leading)
                TextField("localhost", text: $controller.address)
                    .textFieldStyle(.plain)
                    .font(Typo.mono)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: Metric.radius)
                        .fill(theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: Metric.radius)
                        .stroke(theme.border, lineWidth: 1))
                    .onSubmit { controller.connectToRemote() }
            }
            .padding(.horizontal, Metric.gutter)

            HStack(spacing: 6) {
                Text("port")
                    .font(Typo.small)
                    .foregroundStyle(theme.secondary)
                    .frame(width: 54, alignment: .leading)
                Text("\(controller.port)")
                    .font(Typo.mono)
                    .foregroundStyle(theme.text)
                Stepper("", value: $controller.port, in: 1...65535)
                    .labelsHidden()
                    .controlSize(.mini)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metric.gutter)

            HStack(spacing: 6) {
                if controller.source.isRemote && client.connectionState != .disconnected {
                    ToolbarButton(systemImage: "bolt.slash", label: "Disconnect",
                                  tone: Palette.danger) {
                        controller.disconnectFromRemote()
                    }
                } else {
                    ToolbarButton(systemImage: "bolt.horizontal", label: "Connect") {
                        controller.connectToRemote()
                    }
                }
                ToolbarButton(systemImage: "antenna.radiowaves.left.and.right",
                              label: controller.serverEnabled ? "Stop server" : "Serve",
                              isActive: controller.serverEnabled) {
                    controller.serverEnabled.toggle()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metric.gutter)

            if controller.serverEnabled {
                FieldRow(label: vocabulary.titled(vocabulary.viewerPlural),
                         value: "\(controller.serverConnections)")
            }
        }
        .padding(.bottom, 8)
    }

    private var topicList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: vocabulary.channelPlural,
                         trailing: "\(client.channels.count)")
            if client.channels.isEmpty {
                Text(controller.source.isRemote
                     ? "waiting for the server to advertise"
                     : "connect to a server to list \(vocabulary.channelPlural)")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, Metric.gutter)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(client.channels) { channel in
                            ToggleRow(label: channel.topic,
                                      value: binding(for: channel.topic),
                                      shortcut: channel.schemaName)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    /// Per-topic checkbox. The controller owns the intent; the client replays it
    /// after a reconnect, so the checkbox stays truthful across a drop.
    private func binding(for topic: String) -> Binding<Bool> {
        Binding(get: { client.subscribedTopics.contains(topic) },
                set: { controller.setSubscribed($0, to: topic) })
    }
}

// MARK: - Status strip

/// The compact variant for the status bar: same information, one line, no
/// controls. Clicking it toggles the mode.
struct FoxgloveStatusStrip: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var controller: FoxgloveModeController
    @ObservedObject private var client: FoxgloveClient

    init(controller: FoxgloveModeController) {
        _controller = ObservedObject(wrappedValue: controller)
        _client = ObservedObject(wrappedValue: controller.client)
    }

    var body: some View {
        Button {
            controller.toggle()
        } label: {
            HStack(spacing: 6) {
                ConnectionDot(tone: controller.statusTone, active: controller.isEnabled)
                Text("foxglove")
                    .font(Typo.monoSmall)
                    .foregroundStyle(controller.isEnabled ? theme.text : theme.tertiary)
                if controller.isEnabled {
                    Text(controller.displayAddress)
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                        .lineLimit(1)
                    Text(controller.displayCount)
                        .font(Typo.monoSmall)
                        .foregroundStyle(theme.tertiary)
                    if client.messagesReceived > 0 {
                        Text("\(client.messagesReceived) msg")
                            .font(Typo.monoSmall)
                            .foregroundStyle(theme.tertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controller.statusText)
    }
}
