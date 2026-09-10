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
    @State private var savedStates = SavedStatesModel()

    var body: some Scene {
        MenuBarExtra("Anchor", systemImage: "mappin.and.ellipse") {
            MenuContent(model: model, savedStates: savedStates)
        }

        Window("Anchor Saved States", id: SavedStatesWindow.id) {
            SavedStatesView(model: savedStates)
        }
        .defaultSize(width: 900, height: 640)

        Window("Anchor Diagnostics", id: DiagnosticsWindow.id) {
            ContentView(model: model)
        }
        .defaultSize(width: 720, height: 620)
    }
}

enum DiagnosticsWindow {
    static let id = "diagnostics"
}

enum SavedStatesWindow {
    static let id = "saved-states"
}

private struct MenuContent: View {
    @Bindable var model: DiagnosticsModel
    @Bindable var savedStates: SavedStatesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(savedStates.saving ? "Saving…" : "Save Current State") {
            show(SavedStatesWindow.id)
            savedStates.requestSave()
        }
        .disabled(savedStates.saving)
        Toggle("Include Browser Tabs", isOn: $savedStates.includeBrowserTabs)
        Divider()
        if savedStates.recent.isEmpty {
            Text("No saved states yet")
        } else {
            ForEach(savedStates.recent) { snapshot in
                Button(label(snapshot)) {
                    savedStates.select(snapshot.id)
                    show(SavedStatesWindow.id)
                }
            }
        }
        Button("Browse Saved States…") {
            savedStates.reload()
            show(SavedStatesWindow.id)
        }
        Divider()
        Button("Inspect Current Screen") {
            model.inspect()
            show(DiagnosticsWindow.id)
        }
        Button("Open Diagnostics") { show(DiagnosticsWindow.id) }
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

    private func label(_ snapshot: Snapshot) -> String {
        let stamp = SavedStatesFormat.date(snapshot.createdAt)
        guard let name = snapshot.name else { return stamp }
        return "\(name) — \(stamp)"
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
