//
//  ContentView.swift
//  anchor
//
//  Created by Nicolae-Eduard Tabirca on 09/09/2026.
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: DiagnosticsModel
    @Bindable var savedStates: SavedStatesModel

    var body: some View {
        DiagnosticsView(model: model, savedStates: savedStates)
    }
}

#Preview {
    ContentView(model: DiagnosticsModel(), savedStates: SavedStatesModel())
}
