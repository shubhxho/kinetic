//
//  CommandPalette.swift
//  Kinetic Studio
//
//  ⌘K. Every action in the app is reachable by typing, which keeps the toolbar
//  small without hiding functionality in menus.
//

import SwiftUI

struct StudioCommand: Identifiable {
    enum Category: String {
        case scene = "Scene"
        case transport = "Transport"
        case display = "Display"
        case telemetry = "Telemetry"
        case file = "File"
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let category: Category
    let systemImage: String
    let shortcut: String?
    let action: () -> Void

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        return title.lowercased().contains(needle)
            || subtitle.lowercased().contains(needle)
            || category.rawValue.lowercased().contains(needle)
    }
}

struct CommandPalette: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var commands: [StudioCommand] { model.commandList() }
    private var results: [StudioCommand] { commands.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.tertiary)
                TextField("Search commands and scenes…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text)
                    .focused($focused)
                    .onSubmit(run)
                Text("esc")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            PanelDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            row(command, isSelected: index == selection)
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    run()
                                }
                        }
                        if results.isEmpty {
                            Text("No matching command")
                                .font(Typo.small)
                                .foregroundStyle(theme.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new) }
                }
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 560)
        .background(theme.elevated)
        .overlay(RoundedRectangle(cornerRadius: Metric.radiusLarge)
            .stroke(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metric.radiusLarge))
        .shadow(color: .black.opacity(0.45), radius: 32, y: 12)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func run() {
        guard results.indices.contains(selection) else { return }
        results[selection].action()
        isPresented = false
    }

    @ViewBuilder
    private func row(_ command: StudioCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.systemImage)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.white : theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(Typo.body.weight(.medium))
                    .foregroundStyle(isSelected ? Color.white : theme.text)
                Text(command.subtitle)
                    .font(Typo.monoSmall)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(command.category.rawValue)
                .font(Typo.monoSmall)
                .foregroundStyle(isSelected ? Color.white.opacity(0.7) : theme.tertiary)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(Typo.monoSmall)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : theme.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((isSelected ? Color.white : theme.text).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(isSelected ? theme.accent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius))
        .contentShape(Rectangle())
    }
}
