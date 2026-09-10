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
        // the window style of a menu bar extra is a real status item anchor with native
        // positioning, focus and dismissal, and unlike a menu it can hold a list, a
        // detail view and a preview, so no custom panel is needed here
        // the supplied anchor silhouette, marked as a template so the menu bar draws it
        // black in light appearance and white in dark appearance
        MenuBarExtra("Anchor", image: "MenuBarAnchor") {
            AnchorPanelView(model: savedStates, diagnostics: model)
                .onAppear {
                    // opening the panel while something is running must not re-read the
                    // screen underneath that operation
                    guard !savedStates.busy else { return }
                    savedStates.reload()
                    savedStates.resolveDestination()
                    model.refreshPermissions()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Anchor Diagnostics", id: DiagnosticsWindow.id) {
            ContentView(model: model, savedStates: savedStates)
        }
        .defaultSize(width: 720, height: 620)
    }
}

enum DiagnosticsWindow {
    static let id = "diagnostics"
}
