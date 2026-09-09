//
//  ContentView.swift
//  anchor
//
//  Created by Nicolae-Eduard Tabirca on 09/09/2026.
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: DiagnosticsModel

    var body: some View {
        DiagnosticsView(model: model)
    }
}

#Preview {
    ContentView(model: DiagnosticsModel())
}
