import SwiftUI

// what the grid's scrolling region and the anchor in the strip say to each other
// the region reports where it is, a drag of the anchor asks it to move, and while that
// drag is going the region's own reports are ignored, so the two cannot chase each other
@Observable
final class GridScroll {
    // 0 at the top of the grid, 1 at its newest end
    var progress: Double = 1
    // false while every card fits, which is when there is nothing to drag
    var scrollable = false
    // where a drag wants the grid, taken by the region and cleared when the drag ends
    var requested: Double?
    var dragging = false
}

// where a scrolling region sits between its two ends
struct ScrollSpan: Equatable {
    var offset: CGFloat = 0
    var start: CGFloat = 0
    var length: CGFloat = 0

    var progress: Double {
        guard length > 0.5 else { return 1 }
        return min(max(Double((offset - start) / length), 0), 1)
    }

    func offset(for progress: Double) -> CGFloat {
        start + CGFloat(min(max(progress, 0), 1)) * length
    }
}

// the supplied silhouette is drawn in a box a good deal wider than its ink, and its ring
// is a shade right of the middle of that box, so the hanging copy is measured off the
// artwork rather than off its frame
// the numbers are the drawn pixels of the asset, in the 18pt box the menu bar gives it
enum AnchorArt {
    // the size the status item draws it at, so the hanging copy looks the same size
    static let box: CGFloat = 18
    // the middle of the ring, across the box and down from its top
    static let ringX: CGFloat = 10
    static let ringY: CGFloat = 3.5
    static let ringInk: CGFloat = 4

    // how far right of the box's own middle the ring sits
    static var ringOffset: CGFloat { ringX - box / 2 }

    // the drawn anchor leans clockwise, so the hanging copy is turned back by this much
    // the asset itself, the app icon and the menu bar icon are left leaning
    static let tilt: Double = -11
    // it is turned about its own ring, the point it hangs from, so straightening it
    // cannot take it off the chain's line
    static var ringUnit: UnitPoint { UnitPoint(x: ringX / box, y: ringY / box) }

    // the chain hangs this much right of where the ring measures out. the drawn ring is
    // not quite round and the straightening turns what is left of that, so the two are
    // trued up by eye rather than by the pixels
    static let chainTrue: CGFloat = 0.25

    // how far left of the ring in the menu bar the chain and the anchor sit together
    // nothing at the moment: they hang straight under it. the panel and the icon are
    // never moved for this, only the column inside the strip
    static let nudge: CGFloat = 0

    // the strip is 32pt of reserved layout, the drawing runs a little wider so the
    // nudged anchor is not sliced. it takes no room, an overlay never does
    static var drawingWidth: CGFloat { PanelMetrics.decorationStrip + 12 }
}

// one description of the chain, so the tail left in the menu bar and the length hanging
// in the panel are the same chain
enum ChainMetrics {
    static let link = CGSize(width: 3, height: 5.8)
    static let overlap: CGFloat = 1.6
    static let lineWidth: CGFloat = 0.65
}

// a run of small links drawn down from the top of its rect and cut off wherever the rect
// ends, so the chain's length is whatever frame it is given
struct ChainLinks: Shape {
    // where the links are strung, measured across the rect. the line lives in the path
    // rather than in the frame, because a clipped frame's origin is snapped to the pixel
    // grid and a part point of it would be rounded away
    var centre: CGFloat?
    var link = ChainMetrics.link
    var overlap = ChainMetrics.overlap
    // how far above the rect the first link starts, so a chain coming through an edge
    // has no visible beginning
    var lead: CGFloat = ChainMetrics.link.height * 0.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let line = rect.minX + (centre ?? rect.width / 2)
        let step = max(0.5, link.height - overlap)
        var top = rect.minY - lead
        var thin = false
        while top < rect.maxY {
            if thin {
                // the edge of the next link passes through the open face
                path.move(to: CGPoint(x: line, y: top + 0.35))
                path.addLine(to: CGPoint(x: line, y: top + link.height - 0.35))
            } else {
                path.addRoundedRect(in: CGRect(x: line - link.width / 2,
                                               y: top, width: link.width, height: link.height),
                                    cornerSize: CGSize(width: link.width / 2, height: link.width / 2))
            }
            top += step
            thin.toggle()
        }
        return path
    }
}

// the anchor and its chain in the strip kept clear down the right of the panel
// on the grid it is the scrollbar as well: it follows the scrolling, and dragging it
// moves the grid. anywhere else it is decoration and takes no clicks
struct AnchorChainStrip: View {
    private var ink: Color { .primary }
    var scroll: GridScroll
    // bumped once for each actual opening of the panel, which is what the drop plays for
    var opening: Int
    // where the ring left in the menu bar falls across the panel
    var column: CGFloat
    // the grid is the screen, so the anchor stands for its scrolling
    var interactive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dropped = false
    @State private var settled = false
    @State private var dragFrom: Double?

    // a hand-sized target, no wider than it needs to be so it cannot reach back over the
    // last card in a row
    private let gripWidth: CGFloat = 22
    private let gripHeight: CGFloat = 26
    // it has to clear the bar at the top. the reserve at the foot is by eye, between the
    // bar's own and the floor, so it hangs low without sitting on the edge
    private var topInset: CGFloat { PanelMetrics.barHeight + 2 }
    private let bottomInset: CGFloat = 18
    // the drop comes in over the panel's own top edge, not from the top of the travel, so
    // it reads as coming down from the ring in the menu bar. the strip's clip hides the
    // part still above the edge, and the chain has paid out nothing yet
    private let dropFrom: CGFloat = -6

    var body: some View {
        GeometryReader { proxy in
            let travel = travelHeight(in: proxy.size.height)
            let top = dropped ? topInset + travel * CGFloat(scroll.progress) : dropFrom
            // one line for all three: the chain hangs on it and the anchor's own ring,
            // not the middle of its box, is what sits on it
            let centre = markCentre(in: proxy.size.width)
            let line = centre + AnchorArt.ringOffset + AnchorArt.chainTrue
            let eye = top + AnchorArt.ringY
            let chain = max(0.1, eye - 2.2)
            ZStack(alignment: .topLeading) {
                // the box is the whole strip and sits at its corner, so the clip never
                // moves and only the length of the chain is cut. where it hangs is the
                // path's business
                ChainLinks(centre: line)
                    .stroke(ink,
                            style: StrokeStyle(lineWidth: ChainMetrics.lineWidth, lineCap: .round))
                    .frame(width: proxy.size.width, height: chain, alignment: .topLeading)
                    .clipped()
                    .mask(alignment: .bottom) {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 1.5)
                        }
                    }
                    .allowsHitTesting(false)
                mark
                    // the target is centred on the same box, so it travels with it
                    .frame(width: gripWidth, height: gripHeight)
                    .contentShape(Rectangle())
                    .gesture(drag(travel: travel))
                    .allowsHitTesting(draggable)
                    // an offset, not a position: a transform carries a part of a point,
                    // where a frame placed on a fraction is snapped to the pixel grid
                    .offset(x: centre - gripWidth / 2,
                            y: top + AnchorArt.box / 2 - gripHeight / 2)
                // a small joining link reaches into the eye without crossing the shaft
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 0, y: 2.8))
                }
                .stroke(ink,
                        style: StrokeStyle(lineWidth: ChainMetrics.lineWidth, lineCap: .round))
                .frame(width: ChainMetrics.lineWidth, height: 2.8)
                .offset(x: line, y: eye - 3)
                .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        // an indicator, like the bars it stands in for, and the grid is reachable by
        // wheel, trackpad and keyboard without it
        .accessibilityHidden(true)
        .task(id: opening) { await drop() }
    }

    // the supplied silhouette again, as a template and at the size the status item draws
    // it, so it is one colour, legible in either appearance, and the same anchor
    private var mark: some View {
        Image("MenuBarAnchor")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: AnchorArt.box, height: AnchorArt.box)
            .rotationEffect(.degrees(AnchorArt.tilt), anchor: AnchorArt.ringUnit)
            .foregroundStyle(ink)
    }

    private var dragging: Bool { interactive && scroll.dragging }

    // nothing to drag until the chain has settled, and nothing to drag to while the
    // cards all fit
    private var draggable: Bool { interactive && scroll.scrollable && settled }

    // the middle of the anchor's box: under the ring in the menu bar, less the nudge,
    // and never far enough across to leave the strip it is drawn in
    private func markCentre(in width: CGFloat) -> CGFloat {
        let ring = column - (PanelMetrics.width - width) - AnchorArt.nudge
        return min(max(ring - AnchorArt.ringOffset, AnchorArt.box / 2),
                   width - AnchorArt.box / 2)
    }

    private func travelHeight(in height: CGFloat) -> CGFloat {
        max(0, height - topInset - bottomInset - AnchorArt.box)
    }

    // the drop plays for an opening of the panel, not for anything the model does, so
    // navigating or saving leaves the anchor where the scrolling put it
    private func drop() async {
        guard !reduceMotion else {
            dropped = true
            settled = true
            return
        }
        dropped = false
        settled = false
        // the grid reaches the end it opens on first, and the anchor drops to that
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        withAnimation(PanelMotion.anchorDrop) {
            dropped = true
        } completion: {
            settled = true
        }
    }

    // the grid follows the anchor, and the grid's own reports are held off until the
    // drag ends, so the two cannot push each other
    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                guard travel > 0 else { return }
                let from = dragFrom ?? scroll.progress
                dragFrom = from
                scroll.dragging = true
                let next = min(max(from + Double(value.translation.height / travel), 0), 1)
                scroll.progress = next
                scroll.requested = next
            }
            .onEnded { _ in
                dragFrom = nil
                scroll.dragging = false
                scroll.requested = nil
            }
    }
}
