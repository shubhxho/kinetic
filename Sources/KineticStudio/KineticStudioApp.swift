//
//  KineticStudioApp.swift
//  Kinetic Studio
//
//  Entry point and menu wiring.
//

import AppKit
import SwiftUI

@main
struct KineticStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Kinetic Studio", id: "studio") {
            ContentView()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Model…") {
                    NotificationCenter.default.post(name: .studioOpenModel, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("Kinetic Documentation",
                     destination: URL(string: "https://github.com/kinetic-sim/kinetic")!)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from a bare SwiftPM binary still needs an explicit activation
        // policy to get a Dock icon, a menu bar and keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
