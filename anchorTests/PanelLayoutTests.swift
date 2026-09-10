import SwiftUI
import XCTest
@testable import anchor

// a status item panel proposes no height of its own, which is what collapsed the history
// region, so every measurement here proposes zero height the way the panel does
@MainActor
final class PanelLayoutTests: XCTestCase {
    private var root: URL!
    private var model: SavedStatesModel!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-panel-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(root: root)
        for index in 0..<4 {
            let window = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://example.com/\(index)"]))
            var snapshot = RestoreFixtures.snapshot([window])
            snapshot.name = "state \(index)"
            try? store.create(snapshot)
        }
        model = SavedStatesModel(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func panelHeight(_ view: some View) -> CGFloat {
        NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: PanelLayoutTests.width, height: 0))
            .height
    }

    private static let width: CGFloat = 380

    private var panel: some View {
        AnchorPanelView(model: model, diagnostics: DiagnosticsModel())
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                VStack(alignment: .leading) {
                    Text("state \(index)")
                    Text("2 windows").font(.caption2)
                }
                .padding(.vertical, 5)
            }
        }
    }

    func testTheStoreUnderTestActuallyHasSavedStates() {
        XCTAssertEqual(model.snapshots.count, 4)
        XCTAssertTrue(model.failures.isEmpty)
    }

    // the defect, reproduced: with only a maximum the region takes the zero the panel
    // proposes, so the rows under the heading were never drawn
    func testAScrollRegionWithOnlyAMaximumCollapsesToNothing() {
        XCTAssertEqual(panelHeight(ScrollView { rows }.frame(maxHeight: 260)), 0)
        XCTAssertEqual(panelHeight(ScrollView { LazyVStack { rows } }.frame(maxHeight: 260)), 0)
    }

    func testAMeasuredViewportKeepsTheSameContentVisible() {
        let height = panelHeight(PanelScroll(maxHeight: 260) { rows })
        XCTAssertGreaterThan(height, 40)
        XCTAssertLessThanOrEqual(height, 260)
    }

    func testALongHistoryStopsAtTheCapRatherThanGrowingForever() {
        let many = VStack { ForEach(0..<200, id: \.self) { Text("state \($0)") } }
        XCTAssertEqual(panelHeight(PanelScroll(maxHeight: 260) { many }), 260, accuracy: 1)
    }

    func testAShortHistoryOpensCompactRatherThanAtTheCap() {
        let height = panelHeight(PanelScroll(maxHeight: 460, initialHeight: 92) { rows })
        XCTAssertEqual(height, 92, accuracy: 1)
    }

    func testHomeLeavesRoomForTheSavedStateRows() {
        model.show(.home)
        let height = panelHeight(panel)
        XCTAssertGreaterThan(height, 380, "the history region collapsed again")
        XCTAssertLessThanOrEqual(height, usableHeight)
    }

    func testTheEmptyStateStillRendersWithoutRows() {
        let empty = SavedStatesModel(store: SnapshotStore(root: root.appendingPathComponent("empty")))
        XCTAssertTrue(empty.snapshots.isEmpty)
        let height = panelHeight(AnchorPanelView(model: empty, diagnostics: DiagnosticsModel()))
        XCTAssertGreaterThan(height, 200)
        XCTAssertLessThanOrEqual(height, usableHeight)
    }

    func testTheDetailScreenIsTallEnoughToReachThePreviewButton() {
        guard let first = model.snapshots.first else { return XCTFail("no fixture snapshot") }
        model.show(.detail(first.id))
        let height = panelHeight(panel)
        XCTAssertGreaterThan(height, 380, "the detail region collapsed")
        XCTAssertLessThanOrEqual(height, usableHeight)
    }

    func testTheRunReportScreenHasAViewportBeforeAnythingHasRun() {
        model.show(.operation)
        let height = panelHeight(panel)
        XCTAssertGreaterThan(height, 200)
        XCTAssertLessThanOrEqual(height, usableHeight)
    }

    func testEveryViewportLeavesRoomForTheFixedPartsOfThePanel() {
        for reserved in [200.0, 260.0, 340.0] {
            let viewport = PanelMetrics.viewport(reserving: reserved)
            XCTAssertGreaterThanOrEqual(viewport, 180)
            XCTAssertLessThanOrEqual(viewport, 460)
        }
    }

    private var usableHeight: CGFloat {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
    }
}
