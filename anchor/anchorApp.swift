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
    // the status item, the panel and the diagnostics window are all placed by the
    // presenter, which also owns the one instance of each model
    @NSApplicationDelegateAdaptor(StatusPanelPresenter.self) private var presenter

    var body: some Scene {
        // anchor shows no window of its own at launch, this scene exists so the
        // application has one and is never opened
        Settings {
            EmptyView()
        }
    }
}
