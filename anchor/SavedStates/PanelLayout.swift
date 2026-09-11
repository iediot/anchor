import AppKit
import SwiftUI

// a status item panel is laid out at its fitting size, and a scroll view has no height
// of its own, so one with only a maximum collapses to nothing
// the viewport is measured from the content instead and then capped
struct PanelScroll<Content: View>: View {
    let maxHeight: CGFloat
    // used until the content has been measured, so a short region does not open tall
    var initialHeight: CGFloat?
    // set by whoever wants the newest end shown, and cleared here once it has been
    // the request lives outside this view, so rebuilding the region cannot repeat it
    var revealBottom: Binding<Bool>?
    // softens the top and bottom edges, so scrolling content is not cut off flat
    var fadeEdges = false
    @ViewBuilder let content: Content

    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        measured = height
                    }
                // a named end, so a scrollbar of our own can reach it later
                Color.clear
                    .frame(height: 0)
                    .id(PanelScrollAnchor.bottom)
            }
            .frame(height: height)
            .overlay(alignment: .top) { blurEdge(top: true) }
            .overlay(alignment: .bottom) { blurEdge(top: false) }
            .onAppear { reveal(proxy) }
            .onChange(of: revealBottom?.wrappedValue ?? false) { reveal(proxy) }
            .onChange(of: measured) { reveal(proxy) }
        }
    }

    // a strip of blur that fades inwards, so content passing an edge softens instead of
    // being cut off flat
    @ViewBuilder
    private func blurEdge(top: Bool) -> some View {
        if fadeEdges, height > 40 {
            WithinWindowBlur()
                .frame(height: 16)
                .mask(LinearGradient(colors: [.black, .clear],
                                     startPoint: top ? .top : .bottom,
                                     endPoint: top ? .bottom : .top))
                .allowsHitTesting(false)
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard revealBottom?.wrappedValue == true, measured > 0 else { return }
        proxy.scrollTo(PanelScrollAnchor.bottom, anchor: .bottom)
        revealBottom?.wrappedValue = false
    }

    // an explicit height is the point, a maximum alone is what the panel collapses
    private var height: CGFloat {
        guard measured > 0 else { return min(initialHeight ?? maxHeight, maxHeight) }
        return min(measured, maxHeight)
    }
}

// a blur of the panel's own content behind it, not a flat material fill
struct WithinWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .popover
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// stable identifiers inside a scrolling region
enum PanelScrollAnchor {
    static let bottom = "panel.bottom"

    static func tile(_ id: String) -> String { "panel.tile.\(id)" }
}

enum PanelMetrics {
    // the smaller cards make a smaller panel, three of them across and still landscape
    static let width: CGFloat = 410

    // the strip on the right is kept clear for decoration later
    static let decorationStrip: CGFloat = 32

    static var contentWidth: CGFloat { width - decorationStrip }

    static let tileWidth: CGFloat = 114
    static let tileThumbnailHeight: CGFloat = 74
    static let tileHeight: CGFloat = 92
    static let tileSpacing: CGFloat = 8
    static let gridPadding: CGFloat = 10

    // as many cards as the row actually fits, the panel width does not follow them
    static var columns: Int {
        let usable = contentWidth - gridPadding * 2 + tileSpacing
        return max(1, Int((usable + 0.5) / (tileWidth + tileSpacing)))
    }

    // the panel hangs from the status icon, and sits far enough right that the icon is
    // roughly in the middle of the reserved strip
    static let menuBarGap: CGFloat = 6
    // a nudge further right, past the middle of the icon
    static let rightNudge: CGFloat = 7
    static let screenInset: CGFloat = 6

    static func gridHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return tileHeight * CGFloat(rows) + tileSpacing * CGFloat(rows - 1) + gridPadding * 2
    }

    // exactly two rows of cards, padding and spacing included
    static let visibleRows = 2

    // the grid has no header above it, only the footer and whatever notice is showing
    static let gridChrome: CGFloat = 150

    // the bar the settings and save controls sit on, the grid scrolls under it
    static let footerHeight: CGFloat = 36

    // the layout screen fills the same box the grid does, so opening one does not
    // resize the panel
    static var panelHeight: CGFloat { gridViewport(chrome: gridChrome) + footerHeight }

    // what is left for the preview and any warning once the name row and the actions
    // have taken their fixed share
    static var detailMiddleHeight: CGFloat { max(90, panelHeight - 82) }

    static func gridViewport(chrome: CGFloat) -> CGFloat {
        max(gridHeight(rows: 1), min(gridHeight(rows: visibleRows), usableHeight - chrome))
    }

    // the panel hangs under the menu bar, so a viewport plus the fixed parts around it
    // has to stay inside the usable height of the display the icon is on
    static func viewport(reserving chrome: CGFloat) -> CGFloat {
        max(180, min(460, usableHeight - chrome))
    }

    static var usableHeight: CGFloat {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
    }
}
