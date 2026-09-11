import XCTest
@testable import anchor

// the panel hangs to the left of the status icon and never leaves the usable screen
final class PanelPlacementTests: XCTestCase {
    private let usable = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let size = CGSize(width: PanelMetrics.width, height: 420)

    private func icon(atX x: CGFloat) -> CGRect {
        CGRect(x: x, y: 950, width: 24, height: 24)
    }

    // the icon sits roughly in the middle of the reserved strip
    func testTheIconSitsInTheReservedStrip() {
        let anchor = icon(atX: 1200)
        let frame = PanelPlacement.frame(anchor: anchor, size: size, usable: usable)
        XCTAssertEqual(frame.maxX - PanelMetrics.decorationStrip / 2, anchor.midX, accuracy: 0.5)
        XCTAssertGreaterThan(frame.maxX, anchor.maxX - PanelMetrics.decorationStrip)
    }

    func testTheGridStaysLeftOfTheReservedStrip() {
        let frame = PanelPlacement.frame(anchor: icon(atX: 1200), size: size, usable: usable)
        // the strip is the right hand slice of the panel, the working column ends before it
        XCTAssertEqual(frame.maxX - PanelMetrics.decorationStrip,
                       frame.minX + PanelMetrics.contentWidth,
                       accuracy: 0.5)
    }

    func testThePanelHangsBelowTheIcon() {
        let anchor = icon(atX: 1200)
        let frame = PanelPlacement.frame(anchor: anchor, size: size, usable: usable)
        XCTAssertEqual(frame.maxY, anchor.minY - PanelMetrics.menuBarGap, accuracy: 0.5)
        XCTAssertLessThan(frame.maxY, anchor.minY)
    }

    func testAnIconNearTheLeftEdgeClampsInsteadOfHangingOffScreen() {
        let frame = PanelPlacement.frame(anchor: icon(atX: 40), size: size, usable: usable)
        XCTAssertGreaterThanOrEqual(frame.minX, usable.minX)
        XCTAssertEqual(frame.minX, usable.minX + PanelMetrics.screenInset, accuracy: 0.5)
    }

    func testAnIconAtTheRightEdgeKeepsThePanelOnScreen() {
        let frame = PanelPlacement.frame(anchor: icon(atX: 1500), size: size, usable: usable)
        XCTAssertLessThanOrEqual(frame.maxX, usable.maxX)
    }

    func testATallPanelStopsAtTheBottomOfTheUsableArea() {
        let tall = CGSize(width: PanelMetrics.width, height: 2000)
        let frame = PanelPlacement.frame(anchor: icon(atX: 1200), size: tall, usable: usable)
        XCTAssertGreaterThanOrEqual(frame.minY, usable.minY)
    }

    // a second display starts at its own origin, the panel belongs to that screen
    func testAPanelOnASecondDisplayUsesThatDisplaysBounds() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = PanelPlacement.frame(anchor: CGRect(x: -1800, y: 1090, width: 24, height: 24),
                                         size: size,
                                         usable: second)
        XCTAssertGreaterThanOrEqual(frame.minX, second.minX)
        XCTAssertLessThanOrEqual(frame.maxX, second.maxX)
    }
}
