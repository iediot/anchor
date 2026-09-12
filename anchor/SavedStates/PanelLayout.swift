import AppKit
import SwiftUI

// a status item panel is laid out at its fitting size, and a scroll view has no height
// of its own, so one with only a maximum collapses to nothing
// the viewport is measured from the content instead and then capped
struct PanelScroll<Content: View>: View {
    let maxHeight: CGFloat
    // set by whoever wants the newest end shown, and cleared here once it has been
    // the request lives outside this view, so rebuilding the region cannot repeat it
    var revealBottom: Binding<Bool>?
    // softens the top and bottom edges, so scrolling content is not cut off flat
    var fadeEdges = false
    // the region keeps its whole box even when the content is short, so the panel around
    // it does not change size. the content sits at the top of it, on its own padding
    var fillsItsBox = false
    // the strip along the top the bar covers, which content has to clear
    // it is counted once: as room the content must fit below, and as the padding that
    // lets the first row scroll clear of the bar
    var topClearance: CGFloat = 0
    // the anchor in the strip stands in for the native indicator, so the region tells it
    // where it is and takes the places a drag of it asks for
    var scroll: GridScroll?
    var selectedTile: String?
    @ViewBuilder let content: Content

    @State private var measured: CGFloat = 0
    @State private var position = ScrollPosition()
    @State private var span = ScrollSpan()

    var body: some View {
        Group {
            if fits {
                still
            } else {
                scrolling
            }
        }
        .frame(height: height)
        .onAppear { reportFit() }
        .onChange(of: fits) { reportFit() }
    }

    // content that fits leaves the anchor resting at the bottom with nothing to drag
    private func reportFit() {
        guard let scroll else { return }
        scroll.scrollable = !fits
        guard fits else { return }
        scroll.progress = 1
        scroll.requested = nil
    }

    // everything fits, so there is no scroll view: nothing scrolls, nothing bounces, and
    // nothing is scrolled to an end that is already on screen
    private var still: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topClearance)
            measuredContent
                .frame(maxHeight: .infinity, alignment: scroll == nil ? .top : .center)
        }
        .onAppear { revealBottom?.wrappedValue = false }
        .onChange(of: revealBottom?.wrappedValue ?? false) { revealBottom?.wrappedValue = false }
    }

    private var scrolling: some View {
        ScrollViewReader { proxy in
            ScrollView {
                measuredContent
                    // the first row has to be able to come out from under the bar
                    .padding(.top, topClearance)
                // a named end, the reveal and the anchor both reach for it
                Color.clear
                    .frame(height: 0)
                    .id(PanelScrollAnchor.bottom)
            }
            // the anchor on the right shows this instead, and hiding the bars takes
            // nothing away from the wheel, the trackpad or the keyboard
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollSpan.self) { geometry in
                ScrollSpan(offset: geometry.contentOffset.y,
                           start: -geometry.contentInsets.top,
                           length: geometry.contentSize.height
                               + geometry.contentInsets.top
                               + geometry.contentInsets.bottom
                               - geometry.containerSize.height)
            } action: { _, latest in
                // only the two ends are kept, so an ordinary scroll does not lay the
                // region out again on every frame of it
                let ends = ScrollSpan(start: latest.start, length: latest.length)
                if ends != span { span = ends }
                guard let scroll, !scroll.dragging else { return }
                scroll.progress = latest.progress
            }
            // a drag of the anchor moves the grid, and nothing here moves the anchor back
            .onChange(of: scroll?.requested) {
                guard let requested = scroll?.requested, span.length > 0.5 else { return }
                position.scrollTo(y: span.offset(for: requested))
            }
            .overlay(alignment: .top) { blurEdge(top: true) }
            .overlay(alignment: .bottom) { blurEdge(top: false) }
            .onAppear { reveal(proxy) }
            .onChange(of: revealBottom?.wrappedValue ?? false) { reveal(proxy) }
            .onChange(of: measured) { reveal(proxy) }
            .onChange(of: selectedTile) { _, id in
                guard let id else { return }
                proxy.scrollTo(PanelScrollAnchor.tile(id), anchor: .bottom)
            }
        }
    }

    // the content's own height, measured the same way in both, so which one is showing
    // can never change the answer and the two cannot swap back and forth
    private var measuredContent: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                measured = height
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

    // the content, its padding and the strip the footer covers, all against the room
    // there actually is. until it has been measured the scrolling region is the safe one
    private var fits: Bool {
        measured > 0 && measured <= maxHeight - topClearance
    }

    // an explicit height is the point, a maximum alone is what the panel collapses
    private var height: CGFloat {
        // until it has been measured the region opens at its full size, which is what
        // the panel is laid out at anyway
        guard measured > 0 else { return maxHeight }
        guard fits else { return maxHeight }
        return fillsItsBox ? maxHeight : min(measured + topClearance, maxHeight)
    }
}

// the cards, all of them siblings in one container, so a card that moves to another row
// when one is saved or deleted travels there instead of being taken out of one stack and
// put into another
// they are placed oldest first, left to right and then down, with the short row at the
// top, so the bottom row is always a full one and the newest cards are the bottom right
struct TileGrid: Layout {
    let columns: Int
    let spacing: CGFloat
    let size: CGSize

    struct Slot {
        let row: Int
        let column: Int
    }

    static func slot(_ index: Int, count: Int, columns: Int) -> Slot {
        guard columns > 0 else { return Slot(row: index, column: 0) }
        let remainder = count % columns
        guard remainder > 0 else {
            return Slot(row: index / columns, column: index % columns)
        }
        // the first row is the short one, every row under it is full
        guard index >= remainder else { return Slot(row: 0, column: index) }
        let after = index - remainder
        return Slot(row: 1 + after / columns, column: after % columns)
    }

    static func rows(count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let remainder = count % columns
        return count / columns + (remainder > 0 ? 1 : 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.rows(count: subviews.count, columns: columns)
        guard rows > 0 else { return .zero }
        let width = CGFloat(columns) * size.width + CGFloat(columns - 1) * spacing
        let height = CGFloat(rows) * size.height + CGFloat(rows - 1) * spacing
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.indices {
            let slot = Self.slot(index, count: subviews.count, columns: columns)
            let origin = CGPoint(x: bounds.minX + CGFloat(slot.column) * (size.width + spacing),
                                 y: bounds.minY + CGFloat(slot.row) * (size.height + spacing))
            subviews[index].place(at: origin,
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(size))
        }
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
    static let rightNudge: CGFloat = 8
    static let screenInset: CGFloat = 6

    // where the icon's ring falls across the panel when the placement is not pushed by a
    // screen edge, which is what the chain hangs from until a real placement says better
    static var chainColumn: CGFloat {
        width - decorationStrip / 2 - rightNudge + AnchorArt.ringOffset
    }

    static func gridHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return tileHeight * CGFloat(rows) + tileSpacing * CGFloat(rows - 1) + gridPadding * 2
    }

    // one row of cards, padding and spacing included
    static let visibleRows = 1

    // the grid has no header above it, only the footer and whatever notice is showing
    static let gridChrome: CGFloat = 150

    // the bar the settings and save controls sit on, the grid scrolls under it
    static let barHeight: CGFloat = 30

    // both screens open with a round control on this line, measured down from the top of
    // the panel, so the cog and the back chevron land in the same place
    static let headControl: CGFloat = 24
    static let headLine: CGFloat = 17
    static var headInset: CGFloat { headLine - headControl / 2 }

    // the layout screen fills the same box the grid does, so opening one does not
    // resize the panel
    static var panelHeight: CGFloat { gridViewport(chrome: gridChrome) + barHeight }

    // what is left for the preview and any warning once the name row and the actions
    // have taken their fixed share
    static var detailMiddleHeight: CGFloat { max(32, panelHeight - 56) }

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
