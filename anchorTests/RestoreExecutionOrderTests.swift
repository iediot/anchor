import XCTest
@testable import anchor

@MainActor
final class RestoreExecutionOrderTests: XCTestCase {
    private var environment = StubEnvironment()
    private var executor = RecordingExecutor()
    private var coordinator = RestoreCoordinator()

    override func setUp() {
        super.setUp()
        environment = StubEnvironment()
        executor = RecordingExecutor()
        coordinator = RestoreCoordinator()
    }

    private func safari(_ url: String = "https://one.example") -> WindowRecord {
        RestoreFixtures.window(resources: RestoreFixtures.browser([url]))
    }

    private func chrome(_ url: String = "https://two.example") -> WindowRecord {
        RestoreFixtures.window(app: "Google Chrome",
                               bundleID: "com.google.Chrome",
                               resources: RestoreFixtures.browser([url]))
    }

    private func terminal(_ directory: String = "/tmp/one") -> WindowRecord {
        RestoreFixtures.window(app: "Terminal",
                               bundleID: "com.apple.Terminal",
                               resources: RestoreFixtures.terminal([directory]))
    }

    private func pycharm(_ project: String = "/Users/test/project") -> WindowRecord {
        RestoreFixtures.window(app: "PyCharm",
                               bundleID: IntegrationKind.pycharm.bundleID,
                               resources: RestoreFixtures.jetBrains(project: project))
    }

    private func plan(_ records: [WindowRecord]) -> RestorePlan {
        RestorePlanner.build(snapshot: RestoreFixtures.snapshot(records),
                             destination: RestoreFixtures.destination(),
                             environment: environment)
    }

    private func kinds(_ calls: [RecordingExecutor.Call]) -> [String] {
        calls.compactMap { call in
            switch call {
            case .browser: return "browser"
            case .terminal: return "terminal"
            case .project: return "project"
            default: return nil
            }
        }
    }

    func testGroupsAreOrderedBrowsersThenTerminalsThenProjects() {
        let built = plan([pycharm(), terminal(), safari()])
        XCTAssertEqual(built.groups.map(\.appName), ["Safari", "Terminal", "PyCharm"])
    }

    func testTwoBrowsersKeepTheOrderTheSnapshotGaveThem() {
        let built = plan([chrome(), pycharm(), safari()])
        XCTAssertEqual(built.groups.map(\.appName), ["Google Chrome", "Safari", "PyCharm"])
    }

    // the plan is not the authority, the coordinator orders what it runs
    func testAPlanListingPyCharmFirstStillOpensSafariFirst() async {
        let built = plan([pycharm(), safari()])
        let reversed = RestoreFixtures.reordered(built, groups: built.groups.reversed())
        XCTAssertEqual(reversed.groups.map(\.appName), ["PyCharm", "Safari"])
        await coordinator.run(plan: reversed, executor: executor)
        XCTAssertEqual(kinds(executor.calls), ["browser", "project"])
    }

    func testTheReportListIsInExecutionOrder() async {
        let built = plan([pycharm(), safari()])
        let reversed = RestoreFixtures.reordered(built, groups: built.groups.reversed())
        await coordinator.run(plan: reversed, executor: executor)
        XCTAssertEqual(coordinator.reports.map(\.appName), ["Safari", "PyCharm"])
    }

    // the complaint was safari waiting behind a slow ide, so the browser call must not
    // be held up by one
    func testASlowProjectDoesNotHoldUpTheBrowserWindow() async {
        executor.projectDelay = 0.6
        let built = plan([pycharm(), safari()])
        let reversed = RestoreFixtures.reordered(built, groups: built.groups.reversed())
        let started = Date()
        var browserAt: Date?
        executor.onOpen = { if browserAt == nil { browserAt = Date() } }
        await coordinator.run(plan: reversed, executor: executor)
        XCTAssertEqual(kinds(executor.calls).first, "browser")
        XCTAssertLessThan(browserAt?.timeIntervalSince(started) ?? .infinity, 0.6)
    }

    func testTwoWindowsOfOneApplicationKeepTheirOrder() async {
        let first = safari("https://first.example")
        let second = safari("https://second.example")
        await coordinator.run(plan: plan([first, second, pycharm()]), executor: executor)
        let opened = executor.calls.compactMap { call -> String? in
            if case .browser(let request) = call {
                if case .web(let url) = request.tabs[0].content { return url }
            }
            return nil
        }
        XCTAssertEqual(opened, ["https://first.example", "https://second.example"])
    }

    func testCancellingAfterTheBrowserLeavesTheProjectUnstarted() async {
        let built = plan([pycharm(), safari()])
        let reversed = RestoreFixtures.reordered(built, groups: built.groups.reversed())
        executor.onOpen = { [weak coordinator] in coordinator?.cancel() }
        await coordinator.run(plan: reversed, executor: executor)
        XCTAssertEqual(kinds(executor.calls), ["browser"])
        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertEqual(coordinator.reports.last?.state, .cancelled)
    }

    func testAFailedBrowserStillLetsTheProjectRun() async {
        executor.browserOutcome = { _ in .failed("the browser refused") }
        let built = plan([pycharm(), safari()])
        await coordinator.run(plan: built, executor: executor)
        XCTAssertEqual(kinds(executor.calls), ["browser", "project"])
        XCTAssertEqual(coordinator.reports.first?.state, .failed)
        XCTAssertEqual(coordinator.reports.last?.state, .opened)
    }

    func testTheOrderIsStatedInThePreviewWhenThereIsMoreThanOneGroup() {
        XCTAssertTrue(plan([pycharm(), safari()]).notes.contains { $0.text == RestoreExecutionOrder.note })
        XCTAssertFalse(plan([safari()]).notes.contains { $0.text == RestoreExecutionOrder.note })
    }
}
