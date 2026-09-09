//
//  anchorApp.swift
//  anchor
//
//  Created by Nicolae-Eduard Tabirca on 09/09/2026.
//

import AppKit
import SwiftUI

@main
struct anchorApp: App {
    @State private var model = DiagnosticsModel()

    var body: some Scene {
        MenuBarExtra("Anchor", systemImage: "mappin.and.ellipse") {
            MenuContent(model: model)
        }

        Window("Anchor Diagnostics", id: DiagnosticsWindow.id) {
            ContentView(model: model)
        }
        .defaultSize(width: 720, height: 620)
    }
}

enum DiagnosticsWindow {
    static let id = "diagnostics"
}

private struct MenuContent: View {
    @Bindable var model: DiagnosticsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Inspect Current Screen") {
            model.inspect()
            show()
        }
        Button("Open Diagnostics") { show() }
        Divider()
        Text(model.accessibilityGranted ? "Accessibility: granted" : "Accessibility: not granted")
        if !model.accessibilityGranted {
            Button("Grant Accessibility Access…") { Permissions.requestAccessibility() }
            Button("Open Privacy Settings…") { Permissions.openAccessibilitySettings() }
        }
        Divider()
        Button("Quit Anchor") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: DiagnosticsWindow.id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
