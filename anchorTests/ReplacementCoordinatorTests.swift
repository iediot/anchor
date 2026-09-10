import XCTest
@testable import anchor

@MainActor
final class ReplacementCoordinatorTests: XCTestCase {
    private var services = StubReplacementServices()
    private var executor = RecordingExecutor()
    private var environment = StubEnvironment()
    private var restore = RestoreCoordinator()
    private var coordinator = ReplacementCoordinator(restore: RestoreCoordinator())

    override func setUp() {
        super.setUp()
        services = StubReplacementServices()
        executor = RecordingExecutor()
        environment = StubEnvironment()
        restore = RestoreCoordinator()
        coordinator = ReplacementCoordinator(restore: restore)
        coordinator.closeTimeout = 0.4
        coordinator.pollInterval = 0.05
        services.captureOutcome = ReplacementFixtures.outcome()
    }

    private func plan(_ windows: [WindowRecord]? = nil) -> RestorePlan {
        let records = windows ?? [RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))]
        return RestorePlanner.build(snapshot: RestoreFixtures.snapshot(records),
                                    destination: services.destination,
                                    environment: environment)
    }

    private func confirm(_ built: RestorePlan) async {
        await coordinator.beginPreflight(plan: built, services: services)
    }

    private func run(_ mode: ReplacementCoordinator.Mode, _ built: RestorePlan) async {
        await coordinator.run(mode: mode, plan: built, services: services, executor: executor)
    }

    // the happy path, and the order that matters: every close is confirmed before the
    // first thing is opened
    func testReplacementClosesEverythingBeforeItReopensAnything() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12)]
        var remainingWhenOpening: Int?
        executor.onOpen = { [weak services] in remainingWhenOpening = services?.windows.count }
        let built = plan()
        await confirm(built)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .finished)
        XCTAssertEqual(services.closeCalls, [11, 12])
        XCTAssertEqual(coordinator.closedCount, 2)
        XCTAssertEqual(remainingWhenOpening, 0)
        XCTAssertFalse(coordinator.restore.reports.isEmpty)
    }

    func testSaveFailureClosesNothing() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        services.captureOutcome = ReplacementFixtures.outcome(storeError: "the disk is full")
        let built = plan()
        await confirm(built)
        await run(.saveThenReplace, built)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertTrue(coordinator.restore.reports.isEmpty)
        XCTAssertTrue(coordinator.stopReason?.contains("the disk is full") == true)
        XCTAssertEqual(coordinator.closeReports.first?.state, .notReached)
    }

    func testAPartialSaveWaitsForAnExplicitDecisionBeforeClosing() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        services.captureOutcome = ReplacementFixtures.outcome(
            completeness: .partial,
            issues: [CaptureIssue(severity: .omission, scope: "Safari", message: "one window kept its geometry only")])
        let built = plan()
        await confirm(built)
        await run(.saveThenReplace, built)
        XCTAssertEqual(coordinator.stage, .awaitingCaptureDecision)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertEqual(coordinator.partialCapture?.completeness, .partial)
        XCTAssertEqual(coordinator.partialCapture?.omissions.count, 1)

        await coordinator.continueAfterPartialCapture()
        XCTAssertEqual(coordinator.stage, .finished)
        XCTAssertEqual(services.closeCalls, [11])
    }

    func testCancellingAPartialSaveClosesNothing() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        services.captureOutcome = ReplacementFixtures.outcome(completeness: .inconsistent)
        let built = plan()
        await confirm(built)
        await run(.saveThenReplace, built)
        coordinator.cancel()
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertTrue(coordinator.restore.reports.isEmpty)
        XCTAssertNotNil(coordinator.outgoingSnapshotID)
    }

    func testCancellingAfterOneCloseStopsTheRestAndReopensNothing() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12)]
        services.onClose = { [weak coordinator] _ in coordinator?.cancel() }
        let built = plan()
        await confirm(built)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertEqual(coordinator.closedCount, 1)
        XCTAssertTrue(coordinator.restore.reports.isEmpty)
        XCTAssertEqual(coordinator.closeReports.last?.state, .notReached)
    }

    func testARefusedCloseStopsTheOperation() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12)]
        services.refuses = [11]
        let built = plan()
        await confirm(built)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertEqual(coordinator.closeReports.first?.state, .refused)
        XCTAssertTrue(coordinator.restore.reports.isEmpty)
    }

    // an unanswered unsaved work prompt looks exactly like this
    func testAWindowThatNeverClosesStopsTheOperation() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12)]
        services.neverCloses = [11]
        let built = plan()
        await confirm(built)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertEqual(coordinator.closeReports.first?.state, .remaining)
        XCTAssertTrue(coordinator.restore.reports.isEmpty)
    }

    func testAnApplicationExitingDuringACloseStopsTheOperation() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12, pid: 777)]
        services.onClose = { [weak services] window in services?.exited.insert(window.pid) }
        let built = plan()
        await confirm(built)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertTrue(coordinator.stopReason?.contains("exited") == true)
        XCTAssertTrue(coordinator.restore.reports.isEmpty)
    }

    func testAWindowWhoseProcessChangedIsNeverClosed() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12)]
        let built = plan()
        await confirm(built)
        services.windows = [ReplacementFixtures.window(id: 11, pid: 999), ReplacementFixtures.window(id: 12)]
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertTrue(coordinator.refreshRequired)
        XCTAssertTrue(coordinator.restore.reports.isEmpty)
    }

    func testWindowsThatAppearAfterConfirmationAreNeverClosed() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        let built = plan()
        await confirm(built)
        services.windows.append(ReplacementFixtures.window(id: 99, title: "opened after you confirmed"))
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertEqual(coordinator.appearedAfterConfirmation, 1)
        XCTAssertEqual(coordinator.stage, .finished)
    }

    func testADestinationChangeStopsAndAsksForAFreshPreview() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        let built = plan()
        await confirm(built)
        services.destination = RestoreFixtures.destination(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                           visible: CGRect(x: 0, y: 0, width: 1000, height: 760),
                                                           displayID: 2,
                                                           name: "Another Display")
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .stopped)
        XCTAssertTrue(services.closeCalls.isEmpty)
        XCTAssertTrue(coordinator.refreshRequired)
    }

    func testAWindowAnchorCannotCloseBlocksUntilItIsLeftOpen() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12, app: "Odd App")]
        services.support[12] = .unsupported("it has no close button of its own")
        let built = plan()
        await confirm(built)
        XCTAssertFalse(coordinator.canConfirm)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.stage, .preflight)
        XCTAssertTrue(services.closeCalls.isEmpty)

        coordinator.exclude(outgoing: 12, true)
        XCTAssertTrue(coordinator.canConfirm)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertEqual(coordinator.stage, .finished)
    }

    func testWithoutAccessibilityNothingCanBeConfirmed() async {
        services.accessibilityGranted = false
        services.windows = [ReplacementFixtures.window(id: 11)]
        let built = plan()
        await confirm(built)
        XCTAssertFalse(coordinator.canConfirm)
        await run(.replaceWithoutSaving, built)
        XCTAssertTrue(services.closeCalls.isEmpty)
    }

    func testASecondRunWhileOneIsRunningDoesNothing() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        let built = plan()
        await confirm(built)
        async let first: Void = run(.replaceWithoutSaving, built)
        async let second: Void = run(.replaceWithoutSaving, built)
        _ = await (first, second)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertEqual(coordinator.stage, .finished)

        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(services.closeCalls, [11])
    }

    func testAnIncomingWindowLeftOutIsNotReopenedAndTheSnapshotIsUnchanged() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        let records = [RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"])),
                       RestoreFixtures.window(app: "Terminal",
                                              bundleID: "com.apple.Terminal",
                                              resources: RestoreFixtures.terminal(["/tmp/one"]))]
        let built = plan(records)
        await confirm(built)
        coordinator.exclude(incoming: records[1].id, true)
        await run(.replaceWithoutSaving, built)
        XCTAssertEqual(coordinator.restore.reports.count, 1)
        XCTAssertEqual(coordinator.restore.reports.first?.appName, "Safari")
        XCTAssertEqual(built.actionableWindowCount, 2)
    }

    // reopening failing is not a reason to lose the state anchor saved on the way in
    func testTheOutgoingSaveIsKeptWhenReopeningFails() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        executor.browserOutcome = { _ in .failed("the browser refused") }
        let built = plan()
        await confirm(built)
        await run(.saveThenReplace, built)
        XCTAssertEqual(coordinator.stage, .finished)
        XCTAssertNotNil(coordinator.outgoingSnapshotID)
        XCTAssertEqual(coordinator.restore.reports.first?.state, .failed)
        XCTAssertTrue(coordinator.snapshotNotice?.contains("not touched") == true)
        XCTAssertTrue(coordinator.snapshotNotice?.contains("keep it") == true)
    }

    func testReplacingWithoutSavingNeverCaptures() async {
        services.windows = [ReplacementFixtures.window(id: 11)]
        let built = plan()
        await confirm(built)
        await run(.replaceWithoutSaving, built)
        XCTAssertFalse(services.calls.contains(.capture))
        XCTAssertNil(coordinator.outgoingSnapshotID)
    }

    // the only thing a replacement asks of an application is to close one window
    // there is no quit, terminate or signal in the services a replacement is given
    func testOnlyTheIntendedWindowIsEverTouched() async {
        services.windows = [ReplacementFixtures.window(id: 11), ReplacementFixtures.window(id: 12, app: "Notes")]
        let built = plan()
        await confirm(built)
        coordinator.exclude(outgoing: 12, true)
        await run(.saveThenReplace, built)
        XCTAssertEqual(services.closeCalls, [11])
        XCTAssertTrue(services.windows.contains { $0.id == 12 })
        XCTAssertEqual(coordinator.stage, .finished)
    }
}
