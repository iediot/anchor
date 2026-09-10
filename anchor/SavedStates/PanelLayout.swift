import AppKit
import SwiftUI

// a status item panel is laid out at its fitting size, and a scroll view has no height
// of its own, so one with only a maximum collapses to nothing
// the viewport is measured from the content instead and then capped
struct PanelScroll<Content: View>: View {
    let maxHeight: CGFloat
    // used until the content has been measured, so a short region does not open tall
    var initialHeight: CGFloat?
    @ViewBuilder let content: Content

    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    measured = height
                }
        }
        .frame(height: height)
    }

    // an explicit height is the point, a maximum alone is what the panel collapses
    private var height: CGFloat {
        guard measured > 0 else { return min(initialHeight ?? maxHeight, maxHeight) }
        return min(measured, maxHeight)
    }
}

enum PanelMetrics {
    // one history row, both of its lines are limited to one line so this holds
    static let rowHeight: CGFloat = 46

    // the panel hangs under the menu bar, so a viewport plus the fixed parts around it
    // has to stay inside the usable height of the display the icon is on
    static func viewport(reserving chrome: CGFloat) -> CGFloat {
        let usable = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        return max(180, min(460, usable - chrome))
    }
}
