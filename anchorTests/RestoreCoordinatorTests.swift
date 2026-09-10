import XCTest
@testable import anchor

@MainActor
final class RestoreCoordinatorTests: XCTestCase {
    private var environment = StubEnvironment()
    private var executor = RecordingExecutor()
    private var coordinator = RestoreCoordinator()

    override func setUp() {
        super.setUp()
        environment = StubEnvironment()
        executor = RecordingExecutor()
        coordinator = RestoreCoordinator()
    }

    private func plan(_ windows: [WindowRecord]) -> RestorePlan {
        RestorePlanner.build(snapshot: RestoreFixtures.snapshot(windows),
                             destination: RestoreFixtures.destination(),
                             environment: environment)
    }

    private func safariWindow(_ urls: [String] = ["https://one.example"]) -> WindowRecord {
        RestoreFixtures.window(resources: RestoreFixtures.browser(urls))
    }

    private func terminalWindow(_ directory: String = "/tmp/one") -> WindowRecord {
        RestoreFixtures.window(app: "Terminal",
                               bundleID: "com.apple.Terminal",
                               resources: RestoreFixtures.terminal([directory]))
    }

    private func xcodeWindow(_ project: String = "/Users/test/thing.xcodeproj") -> WindowRecord {
        RestoreFixtures.window(app: "Xcode",
                               bundleID: "com.apple.dt.Xcode",
                               resources: RestoreFixtures.xcode(project: project))
    }

    func testEveryActionableWindowIsOpenedAndPlaced() async {
        executor.live["com.apple.Safari"] = [RestoreFixtures.liveWindow(id: 900,
                                                                        frame: CGRect(x: 10, y: 20, width: 700, height: 800))]
        await coordinator.run(plan: plan([safariWindow(), terminalWindow()]), executor: executor)
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(coordinator.reports.count, 2)
        XCTAssertTrue(coordinator.reports.allSatisfy { $0.state == .opened })
        XCTAssertEqual(executor.openCalls.count, 2)
        XCTAssertEqual(executor.placeCalls.count, 2)
    }

    func testAWindowThatWasNeverIdentifiedIsNotPlaced() async {
        executor.browserOutcome = { _ in
            ExecutionOutcome(succeeded: true, summary: "opened", window: .none("the app named no window"), items: [:])
        }
        executor.observation = .none("no new window appeared")
        await coordinator.run(plan: plan([safariWindow()]), executor: executor)
        XCTAssertTrue(executor.placeCalls.isEmpty)
        XCTAssertEqual(coordinator.reports[0].state, .opened)
        XCTAssertTrue(coordinator.reports[0].evidence?.contains("no new window") == true)
    }

    func testAnAmbiguousObservationLeavesTheLayoutAlone() async {
        executor.browserOutcome = { _ in
            ExecutionOutcome(succeeded: true, summary: "opened", window: .none("no id"), items: [:])
        }
        executor.observation = .ambiguous([11, 12], "two windows appeared")
        await coordinator.run(plan: plan([safariWindow()]), executor: executor)
        XCTAssertTrue(executor.placeCalls.isEmpty)
        XCTAssertTrue(coordinator.reports[0].evidence?.contains("2 windows could be the one") == true)
    }

    func testAWindowTheApplicationPutOnAnotherDisplayIsLeftWhereItIs() async {
        executor.live["com.apple.Safari"] = [RestoreFixtures.liveWindow(id: 900,
                                                                        frame: CGRect(x: 3000, y: 0, width: 700, height: 800))]
        await coordinator.run(plan: plan([safariWindow()]), executor: executor)
        XCTAssertTrue(executor.placeCalls.isEmpty)
        XCTAssertTrue(coordinator.reports[0].placement?.contains("left it alone") == true)
    }

    func testAFailedTabIsReportedAgainstThatTabOnly() async {
        executor.browserOutcome = { request in
            var items: [String: ItemOutcome] = [:]
            for (offset, tab) in request.tabs.enumerated() {
                items[tab.itemID] = offset == 1
                    ? ItemOutcome(state: .failed, detail: "the tab could not be created")
                    : ItemOutcome(state: .opened, detail: nil)
            }
            return ExecutionOutcome(succeeded: true, summary: "1 of 2 tabs opened", window: .reportedByApp(900), items: items)
        }
        await coordinator.run(plan: plan([safariWindow(["https://one.example", "https://two.example"])]),
                              executor: executor)
        let report = coordinator.reports[0]
        XCTAssertEqual(report.state, .opened)
        XCTAssertEqual(report.items.filter { $0.state == .failed }.count, 1)
        XCTAssertEqual(report.items.filter { $0.state == .opened }.count, 2)
    }

    func testARefusedApplicationStopsItsOwnWindowsOnly() async {
        executor.automationAnswer = .denied
        await coordinator.run(plan: plan([safariWindow(), xcodeWindow()]), executor: executor)
        let safari = coordinator.reports[0]
        XCTAssertEqual(safari.state, .failed)
        XCTAssertTrue(safari.summary.contains("denied"))
        XCTAssertEqual(executor.openCalls.count, 1)
        XCTAssertEqual(coordinator.reports[1].state, .opened)
    }

    func testCancellingStopsTheRestAndSaysOpenedWindowsStay() async {
        executor.onOpen = { [weak coordinator] in coordinator?.cancel() }
        await coordinator.run(plan: plan([safariWindow(), terminalWindow(), xcodeWindow()]), executor: executor)
        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertEqual(executor.openCalls.count, 1)
        XCTAssertEqual(coordinator.reports[0].state, .opened)
        XCTAssertEqual(coordinator.reports[1].state, .cancelled)
        XCTAssertTrue(coordinator.reports[1].summary.contains("stay open"))
    }

    func testAProjectAlreadyOpenOnTheDestinationIsReusedRatherThanOpenedAgain() async {
        executor.live["com.apple.dt.Xcode"] = [RestoreFixtures.liveWindow(id: 55,
                                                                          document: "/Users/test/thing.xcodeproj",
                                                                          frame: CGRect(x: 40, y: 40, width: 900, height: 700))]
        await coordinator.run(plan: plan([xcodeWindow()]), executor: executor)
        XCTAssertTrue(executor.openCalls.isEmpty)
        XCTAssertEqual(coordinator.reports[0].state, .reused)
        XCTAssertEqual(executor.placeCalls.count, 1)
    }

    func testAProjectOpenOnAnotherDisplayIsSkippedAndNeverMoved() async {
        executor.live["com.apple.dt.Xcode"] = [RestoreFixtures.liveWindow(id: 55,
                                                                          document: "/Users/test/thing.xcodeproj",
                                                                          frame: CGRect(x: 4000, y: 0, width: 900, height: 700))]
        await coordinator.run(plan: plan([xcodeWindow()]), executor: executor)
        XCTAssertTrue(executor.openCalls.isEmpty)
        XCTAssertTrue(executor.placeCalls.isEmpty)
        XCTAssertEqual(coordinator.reports[0].state, .skipped)
        XCTAssertTrue(coordinator.reports[0].summary.contains("outside the destination display"))
    }

    func testTwoWindowsThatCouldBeTheSameProjectAreLeftAlone() async {
        executor.live["com.apple.dt.Xcode"] = [
            RestoreFixtures.liveWindow(id: 55, document: "/Users/test/thing.xcodeproj"),
            RestoreFixtures.liveWindow(id: 56, document: "/Users/test/thing.xcodeproj")
        ]
        await coordinator.run(plan: plan([xcodeWindow()]), executor: executor)
        XCTAssertTrue(executor.openCalls.isEmpty)
        XCTAssertEqual(coordinator.reports[0].state, .skipped)
    }

    func testWithoutAccessibilityNothingIsMoved() async {
        environment.accessibilityGranted = false
        await coordinator.run(plan: plan([safariWindow()]), executor: executor)
        XCTAssertEqual(executor.openCalls.count, 1)
        XCTAssertTrue(executor.placeCalls.isEmpty)
        XCTAssertTrue(coordinator.reports[0].placement?.contains("accessibility is not granted") == true)
    }

    func testWindowsWithNothingToDoAreNotInTheRunAtAll() async {
        let blocked = RestoreFixtures.window(resources: .empty(.unsupported, .appNotSupported, "no adapter"))
        await coordinator.run(plan: plan([safariWindow(), blocked]), executor: executor)
        XCTAssertEqual(coordinator.reports.count, 1)
        XCTAssertEqual(executor.openCalls.count, 1)
    }

    func testASecondRunIsRefusedWhileOneIsStillGoing() async {
        let built = plan([safariWindow()])
        executor.onOpen = { [weak coordinator, weak executor] in
            guard let coordinator, let executor else { return }
            // a second press must not start a second operation
            Task { await coordinator.run(plan: built, executor: executor) }
        }
        await coordinator.run(plan: built, executor: executor)
        XCTAssertEqual(executor.openCalls.count, 1)
        XCTAssertEqual(coordinator.reports.count, 1)
    }

    func testTheReportSurvivesAfterTheRunSoItCanBeReadLater() async {
        executor.browserOutcome = { _ in .failed("safari refused") }
        await coordinator.run(plan: plan([safariWindow()]), executor: executor)
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(coordinator.reports[0].state, .failed)
        XCTAssertTrue(coordinator.summary.contains("1 failed"))
        XCTAssertNotNil(coordinator.finishedAt)
    }

    func testARefusedMoveIsReportedAgainstTheLayoutItem() async {
        executor.placement = .refused("the application would not accept a new size")
        await coordinator.run(plan: plan([safariWindow()]), executor: executor)
        let layout = coordinator.reports[0].items.first { $0.kind == .layout }
        XCTAssertEqual(layout?.state, .failed)
        XCTAssertTrue(coordinator.reports[0].placement?.contains("would not accept") == true)
    }

    // an ide shows a splash first, so a project waits for its own window instead of
    // taking whatever appeared
    func testAProjectWaitsForItsOwnWindowRatherThanTheFirstNewOne() async {
        executor.projectOutcome = { request in
            ExecutionOutcome(succeeded: true,
                             summary: "handed over",
                             window: .none("no window id"),
                             items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
        }
        executor.projectWindow = .corroborated(77, "the window title starts with thing")
        await coordinator.run(plan: plan([xcodeWindow()]), executor: executor)
        XCTAssertTrue(executor.calls.contains(.awaitProject("thing.xcodeproj")))
        XCTAssertFalse(executor.calls.contains(.observe("com.apple.dt.Xcode")))
        XCTAssertEqual(executor.placeCalls.count, 1)
    }

    func testABrowserStillUsesThePlainObservation() async {
        executor.browserOutcome = { _ in
            ExecutionOutcome(succeeded: true, summary: "opened", window: .none("no id"), items: [:])
        }
        await coordinator.run(plan: plan([safariWindow()]), executor: executor)
        XCTAssertTrue(executor.calls.contains(.observe("com.apple.Safari")))
        XCTAssertFalse(executor.calls.contains { if case .awaitProject = $0 { return true }; return false })
    }

    func testAProjectWindowThatNeverArrivesPlacesNothing() async {
        executor.projectOutcome = { request in
            ExecutionOutcome(succeeded: true,
                             summary: "handed over",
                             window: .none("no window id"),
                             items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
        }
        executor.projectWindow = .none("2 windows have appeared but none of them is the thing window yet, and anchor stopped waiting")
        await coordinator.run(plan: plan([xcodeWindow()]), executor: executor)
        XCTAssertTrue(executor.placeCalls.isEmpty)
        XCTAssertTrue(coordinator.reports[0].evidence?.contains("stopped waiting") == true)
    }

    // a starting ide can accept a rectangle and then move the window itself
    func testAWindowMovedOnceAfterPlacementIsPutBack() async {
        prepareProjectWindow()
        var attempts = 0
        executor.onPlace = { [weak executor] id, frame in
            attempts += 1
            let landed = attempts == 1 ? CGRect(x: 0, y: 81, width: 756, height: 868) : frame
            executor?.keep(id, at: landed)
        }
        await coordinator.run(plan: plan([xcodeWindow()]), executor: executor)
        XCTAssertEqual(executor.placeCalls.count, 2)
        XCTAssertTrue(coordinator.reports[0].placement?.contains("put it back") == true)
        let layout = coordinator.reports[0].items.first { $0.kind == .layout }
        XCTAssertEqual(layout?.state, .opened)
    }

    func testAnApplicationThatKeepsItsOwnSizeIsReportedNotFought() async {
        prepareProjectWindow()
        executor.onPlace = { [weak executor] id, _ in
            executor?.keep(id, at: CGRect(x: 0, y: 81, width: 756, height: 868))
        }
        await coordinator.run(plan: plan([xcodeWindow()]), executor: executor)
        XCTAssertEqual(executor.placeCalls.count, 2, "anchor must correct at most once")
        XCTAssertTrue(coordinator.reports[0].placement?.contains("left it there") == true)
        let layout = coordinator.reports[0].items.first { $0.kind == .layout }
        XCTAssertEqual(layout?.state, .failed)
    }

    private func prepareProjectWindow() {
        executor.projectOutcome = { request in
            ExecutionOutcome(succeeded: true,
                             summary: "handed over",
                             window: .none("no window id"),
                             items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
        }
        executor.projectWindow = .corroborated(77, "the window carries the project")
        executor.live["com.apple.dt.Xcode"] = [RestoreFixtures.liveWindow(id: 77,
                                                                          frame: CGRect(x: 10, y: 20, width: 700, height: 800))]
    }

    func testTitleAloneNeverIdentifiesAnExistingXcodeProject() {
        let request = ProjectOpenRequest(app: .xcode,
                                         itemID: "item",
                                         path: "/Users/test/thing.xcodeproj",
                                         projectName: "thing.xcodeproj")
        let finding = RestoreReuse.find(request: request,
                                        among: [RestoreFixtures.liveWindow(id: 5, title: "thing.xcodeproj")],
                                        destination: RestoreFixtures.destination(),
                                        accessibilityGranted: true)
        XCTAssertEqual(finding, .notOpen)
    }

    func testWithoutAccessibilityReuseIsNotGuessed() {
        let request = ProjectOpenRequest(app: .pycharm, itemID: "item", path: "/a/thing", projectName: "thing")
        let finding = RestoreReuse.find(request: request,
                                        among: [RestoreFixtures.liveWindow(id: 5, title: "thing – main.py")],
                                        destination: RestoreFixtures.destination(),
                                        accessibilityGranted: false)
        XCTAssertEqual(finding, .notOpen)
    }
}
