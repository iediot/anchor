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
        MenuBarExtra("Anchor", systemImage: "mappin.and.ellipse") {
            AnchorPanelView(model: savedStates, diagnostics: model)
                .onAppear {
                    savedStates.reload()
                    savedStates.resolveDestination()
                    model.refreshPermissions()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Anchor Diagnostics", id: DiagnosticsWindow.id) {
            ContentView(model: model)
        }
        .defaultSize(width: 720, height: 620)
    }
}

enum DiagnosticsWindow {
    static let id = "diagnostics"
}
