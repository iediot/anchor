import XCTest
@testable import anchor

@MainActor
final class ReplacementScopeTests: XCTestCase {
    private func inspected(id: CGWindowID,
                           app: String = "Safari",
                           bundleID: String? = "com.apple.Safari",
                           inScope: Bool,
                           reason: String) -> InspectedWindow {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        return InspectedWindow(id: id,
                               pid: 501,
                               ownerName: app,
                               bundleID: bundleID,
                               title: "a window",
                               titleSource: .accessibility,
                               serverFrame: frame,
                               appKitFrame: frame,
                               layer: 0,
                               alpha: 1,
                               screenName: "Test Display",
                               inScope: inScope,
                               scopeReason: reason,
                               availability: .geometryOnly,
                               fullScreen: .ordinary,
                               axTitleMatched: true,
                               documentPath: nil)
    }

    private func scan(_ windows: [InspectedWindow]) -> WindowScan {
        WindowScan(windows: windows,
                   target: DisplayTarget.resolve(from: [], preferredOwner: nil),
                   accessibilityGranted: true,
                   screenRecordingGranted: true,
                   lostPinnedDisplay: false,
                   capturedAt: Date())
    }

    // another display, another desktop, anchor's own panel and desktop furniture are all
    // already out of scope, and a replacement never widens that
    func testOnlyWindowsOnTheDestinationAreOutgoing() {
        let windows = [inspected(id: 11, inScope: true, reason: "on the target display"),
                       inspected(id: 12, inScope: false, reason: "on another display"),
                       inspected(id: 13, app: "Anchor", bundleID: "com.anchor", inScope: false, reason: "anchor's own window"),
                       inspected(id: 14, inScope: false, reason: "window layer 3 is desktop furniture or an overlay")]
        let outgoing = ReplacementScope.outgoing(from: scan(windows))
        XCTAssertEqual(outgoing.map(\.id), [11])
    }

    func testEveryOutgoingWindowKeepsItsProcessAndApplication() {
        let outgoing = ReplacementScope.outgoing(from: scan([inspected(id: 11, inScope: true, reason: "on the target display")]))
        XCTAssertEqual(outgoing.first?.pid, 501)
        XCTAssertEqual(outgoing.first?.bundleID, "com.apple.Safari")
        XCTAssertEqual(outgoing.first?.appName, "Safari")
    }

    func testAnUnsupportedWindowIsCountedAsABlockerUntilItIsLeftOut() {
        let entries = [OutgoingEntry(window: ReplacementFixtures.window(id: 11), support: .supported("close button")),
                       OutgoingEntry(window: ReplacementFixtures.window(id: 12), support: .unsupported("no close button")),
                       OutgoingEntry(window: ReplacementFixtures.window(id: 13), support: .unknown("cannot tell"))]
        let preflight = ReplacementPreflight(destination: RestoreFixtures.destination(),
                                             entries: entries,
                                             accessibilityGranted: true,
                                             notes: [],
                                             builtAt: Date())
        XCTAssertEqual(preflight.blocking(excluding: []).map(\.id), [12, 13])
        XCTAssertEqual(preflight.blocking(excluding: [12, 13]).count, 0)
        XCTAssertEqual(preflight.included(excluding: [12, 13]).map(\.id), [11])
    }

    func testThePyCharmLimitationIsStatedWhenItIsInScope() {
        let environment = StubEnvironment()
        let incoming = RestorePlanner.build(snapshot: RestoreFixtures.snapshot([]),
                                            destination: RestoreFixtures.destination(),
                                            environment: environment)
        let entries = [OutgoingEntry(window: ReplacementFixtures.window(id: 11,
                                                                        bundleID: IntegrationKind.pycharm.bundleID,
                                                                        app: "PyCharm"),
                                     support: .supported("close button"))]
        let notes = ReplacementScope.notes(entries: entries, accessibilityGranted: true, incoming: incoming)
        XCTAssertTrue(notes.contains { $0.text == KnownIssues.pycharm })
    }

    func testASavedPyCharmWindowCarriesTheLimitationIntoThePreview() {
        let record = RestoreFixtures.window(app: "PyCharm",
                                            bundleID: IntegrationKind.pycharm.bundleID,
                                            resources: RestoreFixtures.jetBrains(project: "/Users/test/project"))
        let built = RestorePlanner.build(snapshot: RestoreFixtures.snapshot([record]),
                                         destination: RestoreFixtures.destination(),
                                         environment: StubEnvironment())
        XCTAssertTrue(built.notes.contains { $0.text == KnownIssues.pycharm })
    }

    func testLeavingAWindowOutChangesThePlanAndNotTheSnapshot() {
        let records = [RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"])),
                       RestoreFixtures.window(app: "Terminal",
                                              bundleID: "com.apple.Terminal",
                                              resources: RestoreFixtures.terminal(["/tmp/one"]))]
        let snapshot = RestoreFixtures.snapshot(records)
        let built = RestorePlanner.build(snapshot: snapshot,
                                         destination: RestoreFixtures.destination(),
                                         environment: StubEnvironment())
        let filtered = built.excluding(windowIDs: [records[1].id])
        XCTAssertEqual(filtered.actionableWindowCount, 1)
        XCTAssertEqual(built.actionableWindowCount, 2)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertTrue(filtered.notes.contains { $0.text.contains("left out of this operation") })
    }
}
