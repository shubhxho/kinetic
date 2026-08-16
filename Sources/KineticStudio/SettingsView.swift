//
//  SettingsView.swift
//  Kinetic Studio
//
//  The standard macOS preferences window, through SwiftUI's `Settings` scene —
//  which gets the ⌘, shortcut, the correct window chrome and the toolbar-style
//  tab bar without any of it being rebuilt here.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("studio.telemetryPort") private var telemetryPort = 8765
    @AppStorage("studio.publishRate") private var publishRate = 30.0
    @AppStorage("studio.historySeconds") private var historySeconds = 20.0
    @AppStorage("studio.viewportFrameRate") private var viewportFrameRate = 120
    @AppStorage("studio.pausedFrameRate") private var pausedFrameRate = 30

    var body: some View {
        // `Tab` needs macOS 15; the package targets 14, so this uses the
        // long-standing `tabItem` form, which produces the identical
        // preferences-style tab bar.
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            viewportTab
                .tabItem { Label("Viewport", systemImage: "cube") }
            telemetryTab
                .tabItem { Label("Telemetry", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .frame(width: 480, height: 320)
    }

    private var generalTab: some View {
        Form {
            Section {
                Slider(value: $historySeconds, in: 5...60, step: 5) {
                    Text("History window")
                } minimumValueLabel: {
                    Text("5s")
                } maximumValueLabel: {
                    Text("60s")
                }
                LabeledContent("Retained", value: "\(Int(historySeconds)) seconds")
            } header: {
                Text("Timeline")
            } footer: {
                Text("One snapshot per step holds the full state, so a longer window costs "
                     + "memory in proportion to the model's size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var viewportTab: some View {
        Form {
            Section {
                Picker("While running", selection: $viewportFrameRate) {
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                Picker("While paused", selection: $pausedFrameRate) {
                    Text("10 fps").tag(10)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            } header: {
                Text("Frame rate")
            } footer: {
                Text("A paused viewport has nothing new to show. Lowering its rate is most of "
                     + "a CPU core.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var telemetryTab: some View {
        Form {
            Section("Server") {
                TextField("Port", value: $telemetryPort, format: .number.grouping(.never))
                Slider(value: $publishRate, in: 5...120, step: 5) {
                    Text("Publish rate")
                } minimumValueLabel: {
                    Text("5")
                } maximumValueLabel: {
                    Text("120")
                }
                LabeledContent("Rate", value: "\(Int(publishRate)) Hz")
            }
        }
        .formStyle(.grouped)
    }
}
