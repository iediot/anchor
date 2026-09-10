import XCTest
@testable import anchor

@MainActor
final class WelcomeScreenTests: XCTestCase {
    private let welcomeTitle = "WelcomeScreen – Welcome to PyCharm"
    private let projectPath = "/Users/test/PycharmProjects/WelcomeScreen"

    private func role(_ title: String?, _ kind: IntegrationKind = .pycharm) -> JetBrainsWindowRole {
        JetBrainsWindowTitle.role(title: title, kind: kind)
    }

    // the reported title, where the leading segment is also a real recent project
    func testTheIdeWelcomeWindowIsRecognisedByWhatTheIdeWrote() {
        XCTAssertTrue(role(welcomeTitle).isWelcome)
        XCTAssertTrue(role("Welcome to PyCharm").isWelcome)
        XCTAssertTrue(role("anything – welcome to pycharm").isWelcome)
    }

    // a real project may be called WelcomeScreen, and it stays a project
    func testAProjectNamedWelcomeScreenIsStillAProject() {
        XCTAssertFalse(role("WelcomeScreen – main.py").isWelcome)
        XCTAssertFalse(role("WelcomeScreen").isWelcome)
        XCTAssertFalse(role("Welcome to PyCharm – notes.md").isWelcome)
        XCTAssertFalse(role("Building with the Claude API – tools.ipynb").isWelcome)
    }

    func testTheMarkerBelongsToOneIdeAndNotToAnyWindow() {
        XCTAssertFalse(role(welcomeTitle, .clion).isWelcome)
        XCTAssertTrue(role("WelcomeScreen – Welcome to CLion", .clion).isWelcome)
        XCTAssertFalse(role(welcomeTitle, .safari).isWelcome)
        XCTAssertFalse(role(nil).isWelcome)
    }

    private func plan(_ record: WindowRecord) -> RestorePlan {
        RestorePlanner.build(snapshot: RestoreFixtures.snapshot([record]),
                             destination: RestoreFixtures.destination(),
                             environment: StubEnvironment())
    }

    private func jetBrainsRecord(title: String, project: String?) -> WindowRecord {
        RestoreFixtures.window(app: "PyCharm",
                               bundleID: IntegrationKind.pycharm.bundleID,
                               title: title,
                               resources: RestoreFixtures.jetBrains(project: project))
    }

    // the snapshot already on disk holds a project for that welcome window, and it is
    // judged again rather than trusted
    func testAnOlderSnapshotWithAProjectOnAWelcomeWindowOpensNothing() {
        let built = plan(jetBrainsRecord(title: welcomeTitle, project: projectPath))
        XCTAssertEqual(built.actionableWindowCount, 0)
        XCTAssertTrue(built.headline.contains("nothing in this saved state can be reopened"))
        let window = built.windows[0]
        if case .nothing(let reason) = window.action {
            XCTAssertTrue(reason.contains("welcome window"))
        } else {
            XCTFail("a welcome window must not produce an open action")
        }
    }

    func testARealProjectStillProducesAnOpenAction() {
        let built = plan(jetBrainsRecord(title: "WelcomeScreen – main.py", project: projectPath))
        XCTAssertEqual(built.actionableWindowCount, 1)
        if case .openProject(let request) = built.windows[0].action {
            XCTAssertEqual(request.path, projectPath)
        } else {
            XCTFail("a project window must still open its project")
        }
    }

    private func request() -> ProjectOpenRequest {
        ProjectOpenRequest(app: .pycharm, itemID: "item", path: projectPath, projectName: "WelcomeScreen")
    }

    // never corroborated, so it is never waited for and never resized
    func testAWelcomeWindowIsNeverTakenForTheProjectWindow() {
        let welcome = RestoreFixtures.liveWindow(id: 500, title: welcomeTitle)
        XCTAssertNil(ProjectWindowIdentity.evidence(request: request(),
                                                    window: welcome,
                                                    accessibilityGranted: true))
        XCTAssertEqual(RestoreReuse.find(request: request(),
                                         among: [welcome],
                                         destination: RestoreFixtures.destination(),
                                         accessibilityGranted: true),
                       .notOpen)
        let resolution = ProjectWindowReadiness.resolve(request: request(),
                                                        candidates: [welcome],
                                                        excluding: [],
                                                        accessibilityGranted: true)
        if case .notYet = resolution {} else { XCTFail("a welcome window must not end the readiness wait") }
    }

    func testTheRealProjectWindowIsStillCorroborated() {
        let live = RestoreFixtures.liveWindow(id: 501, title: "WelcomeScreen – main.py")
        XCTAssertNotNil(ProjectWindowIdentity.evidence(request: request(),
                                                       window: live,
                                                       accessibilityGranted: true))
    }
}

@MainActor
final class ReplacementReplayTests: XCTestCase {
    private var services = StubReplacementServices()
    private var executor = RecordingExecutor()
    private var restore = RestoreCoordinator()
    private var coordinator = ReplacementCoordinator(restore: RestoreCoordinator())

    override func setUp() {
        super.setUp()
        services = StubReplacementServices()
        executor = RecordingExecutor()
        restore = RestoreCoordinator()
        coordinator = ReplacementCoordinator(restore: restore)
        coordinator.closeTimeout = 0.4
        coordinator.pollInterval = 0.05
        services.captureOutcome = ReplacementFixtures.outcome()
        services.windows = [ReplacementFixtures.window(id: 11)]
    }

    private func plan(_ records: [WindowRecord]) -> RestorePlan {
        RestorePlanner.build(snapshot: RestoreFixtures.snapshot(records),
                             destination: services.destination,
                             environment: StubEnvironment())
    }

    private func browserPlan() -> RestorePlan {
        plan([RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))])
    }

    private func welcomePlan() -> RestorePlan {
        plan([RestoreFixtures.window(app: "PyCharm",
                                     bundleID: IntegrationKind.pycharm.bundleID,
                                     title: "WelcomeScreen – Welcome to PyCharm",
                                     resources: RestoreFixtures.jetBrains(project: "/Users/test/PycharmProjects/WelcomeScreen"))])
    }

    // a state with nothing to reopen must never be a reason to close anything
    func testAnIncomingStateWithNothingToOpenClosesNothing() async {
        let built = welcomePlan()
        await coordinator.beginPreflight(plan: built, services: services)
        await coordinator.run(mode: .replaceWithoutSaving, plan: built, services: services, executor: executor)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertTrue(coordinator.stopReason?.contains("nothing in this saved state") == true)
    }

    func testLeavingEveryIncomingWindowOutAlsoClosesNothing() async {
        let built = browserPlan()
        await coordinator.beginPreflight(plan: built, services: services)
        for window in built.actionableWindows {
            coordinator.exclude(incoming: window.id, true)
        }
        await coordinator.run(mode: .replaceWithoutSaving, plan: built, services: services, executor: executor)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertTrue(executor.calls.isEmpty)
    }

    // one confirmed operation asks for each launch exactly once
    func testOneConfirmationLaunchesEachWindowOnce() async {
        let built = plan([RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"])),
                          RestoreFixtures.window(app: "Terminal",
                                                 bundleID: "com.apple.Terminal",
                                                 resources: RestoreFixtures.terminal(["/tmp/one"]))])
        await coordinator.beginPreflight(plan: built, services: services)
        await coordinator.run(mode: .replaceWithoutSaving, plan: built, services: services, executor: executor)
        XCTAssertEqual(coordinator.stage, .finished)
        XCTAssertEqual(restore.launchRequests, 2)
        XCTAssertEqual(executor.openCalls.count, 2)
        XCTAssertEqual(coordinator.log.closeRequests, 1)
    }

    // navigating the panel, reloading and asking again must not replay the operation
    func testNavigationAndReloadAfterAnOperationReplayNothing() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(root: root)
        let snapshot = RestoreFixtures.snapshot([RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))])
        try store.create(snapshot)
        let model = SavedStatesModel(store: store)
        let built = RestorePlanner.build(snapshot: snapshot,
                                         destination: services.destination,
                                         environment: StubEnvironment())
        await model.replacement.beginPreflight(plan: built, services: services)
        await model.replacement.run(mode: .replaceWithoutSaving,
                                    plan: built,
                                    services: services,
                                    executor: executor)
        let opens = executor.openCalls.count
        let closes = services.closeCalls.count
        XCTAssertEqual(opens, 1)

        model.show(.detail(snapshot.id))
        model.backToHome()
        model.show(.replacement)
        model.reload()
        model.show(.home)
        XCTAssertEqual(executor.openCalls.count, opens)
        XCTAssertEqual(services.closeCalls.count, closes)
    }

    // a stopped run holds no continuation that a later press could resume
    func testACancelledRunDropsItsContinuation() async {
        let built = browserPlan()
        services.captureOutcome = ReplacementFixtures.outcome(completeness: .partial)
        await coordinator.beginPreflight(plan: built, services: services)
        await coordinator.run(mode: .saveThenReplace, plan: built, services: services, executor: executor)
        XCTAssertEqual(coordinator.stage, .awaitingCaptureDecision)
        coordinator.cancel()
        XCTAssertEqual(coordinator.stage, .stopped)

        await coordinator.continueAfterPartialCapture()
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertTrue(executor.calls.isEmpty)
    }

    func testTheReportNamesTheOperationTheActionAndTheCounts() async {
        let built = browserPlan()
        await coordinator.beginPreflight(plan: built, services: services)
        await coordinator.run(mode: .replaceWithoutSaving, plan: built, services: services, executor: executor)
        let report = coordinator.report
        XCTAssertTrue(report.contains("anchor operation \(coordinator.log.id)"))
        XCTAssertTrue(report.contains(ReplacementCoordinator.Mode.replaceWithoutSaving.label))
        XCTAssertTrue(report.contains("close requests 1"))
        XCTAssertTrue(report.contains("reopen counts: launch requests 1"))
        XCTAssertFalse(report.contains("https://one.example"))
    }
}
