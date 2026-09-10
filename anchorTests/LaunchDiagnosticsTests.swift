import XCTest
@testable import anchor

@MainActor
final class StubLaunchProbe: LaunchProcessProbe {
    var pids: [pid_t] = []
    private(set) var queries = 0

    func runningPIDs(bundleID: String) -> [pid_t] {
        queries += 1
        return pids
    }
}

@MainActor
final class LaunchDiagnosticsTests: XCTestCase {
    private var executor = RecordingExecutor()
    private var probe = StubLaunchProbe()
    private var coordinator = LaunchDiagnosticsCoordinator()

    override func setUp() {
        super.setUp()
        executor = RecordingExecutor()
        probe = StubLaunchProbe()
        coordinator = LaunchDiagnosticsCoordinator()
        coordinator.identifyTimeout = 0.5
    }

    private func request(_ path: String = "/Users/test/project") -> ProjectOpenRequest {
        ProjectOpenRequest(app: .pycharm, itemID: "launch-diagnostic", path: path, projectName: "project")
    }

    private func rectangle() -> LaunchRectangle {
        LaunchRectangle(frame: CGRect(x: 20, y: 30, width: 900, height: 800), provenance: "a test rectangle")
    }

    private func run(_ mode: LaunchDiagnosticMode,
                     rectangle: LaunchRectangle? = nil,
                     granted: Bool = true) async {
        await coordinator.run(mode: mode,
                              project: request(),
                              rectangle: rectangle,
                              accessibilityGranted: granted,
                              probe: probe,
                              executor: executor)
    }

    private var placeCalls: Int { executor.placeCalls.count }

    // the whole point of the first mode: the launch and nothing else
    func testLaunchOnlyTouchesNoWindowAndWritesNothing() async {
        await run(.launchOnly)
        XCTAssertEqual(executor.calls.count, 1)
        XCTAssertEqual(executor.openCalls.count, 1)
        XCTAssertEqual(executor.liveWindowQueries, 0)
        XCTAssertEqual(placeCalls, 0)
        XCTAssertFalse(executor.calls.contains { if case .awaitProject = $0 { return true }; return false })
        XCTAssertTrue(coordinator.summary?.contains("launch only") == true)
    }

    func testLaunchOnlyStillReportsWhetherThisWasAColdLaunch() async {
        probe.pids = [4242]
        await run(.launchOnly)
        XCTAssertTrue(coordinator.stages.first?.detail.contains("not a cold launch") == true)
        XCTAssertEqual(executor.liveWindowQueries, 0)
    }

    func testAFailedLaunchStopsBeforeAnyLaterStage() async {
        executor.projectOutcome = { _ in .failed("the ide is not installed") }
        await run(.identify)
        XCTAssertEqual(executor.openCalls.count, 1)
        XCTAssertFalse(executor.calls.contains { if case .awaitProject = $0 { return true }; return false })
        XCTAssertEqual(placeCalls, 0)
        XCTAssertTrue(coordinator.summary?.contains("launch call failed") == true)
    }

    func testIdentificationReadsAndNeverPlaces() async {
        await run(.identify)
        XCTAssertEqual(executor.openCalls.count, 1)
        XCTAssertTrue(executor.calls.contains { if case .awaitProject = $0 { return true }; return false })
        XCTAssertEqual(placeCalls, 0)
        XCTAssertEqual(executor.liveWindowQueries, 1)
        XCTAssertTrue(coordinator.summary?.contains("wrote no accessibility attribute") == true)
    }

    func testIdentificationWithoutAccessibilityIdentifiesNothing() async {
        await run(.identify, granted: false)
        XCTAssertFalse(executor.calls.contains { if case .awaitProject = $0 { return true }; return false })
        XCTAssertEqual(placeCalls, 0)
        XCTAssertTrue(coordinator.stages.contains { $0.detail.contains("accessibility is not granted") })
    }

    func testPlacementUsesTheRectangleItWasGiven() async {
        executor.live[IntegrationKind.pycharm.bundleID] = [RestoreFixtures.liveWindow(id: 902)]
        executor.projectWindow = .corroborated(902, "the window carries the project")
        await run(.place, rectangle: rectangle())
        XCTAssertEqual(placeCalls, 1)
        XCTAssertTrue(executor.calls.contains(.place(902, rectangle().frame)))
        XCTAssertTrue(coordinator.summary?.contains("all three stages ran") == true)
    }

    func testPlacementNeverRunsWithoutAnIdentifiedWindow() async {
        executor.projectWindow = .none("no project window appeared")
        await run(.place, rectangle: rectangle())
        XCTAssertEqual(placeCalls, 0)
        XCTAssertTrue(coordinator.summary?.contains("nothing was placed") == true)
    }

    func testPlacementWithoutARectanglePlacesNothing() async {
        executor.projectWindow = .corroborated(902, "the window carries the project")
        await run(.place, rectangle: nil)
        XCTAssertEqual(placeCalls, 0)
        XCTAssertTrue(coordinator.stages.contains { $0.name == "place" && $0.detail.contains("no rectangle") })
    }

    func testASecondRunWhileOneIsRunningDoesNothing() async {
        executor.projectDelay = 0.2
        async let first: Void = run(.launchOnly)
        async let second: Void = run(.launchOnly)
        _ = await (first, second)
        XCTAssertEqual(executor.openCalls.count, 1)
    }

    func testTheCopiedResultCarriesStagesAndNoEnvironment() async {
        await run(.launchOnly)
        let report = coordinator.report
        XCTAssertTrue(report.contains("project path: /Users/test/project"))
        XCTAssertTrue(report.contains(LaunchDiagnosticMode.launchOnly.label))
        XCTAssertTrue(report.contains("launch"))
        XCTAssertFalse(report.lowercased().contains("environment"))
    }

    // the panel reads the screen when it opens, and that must be impossible mid run
    func testAnOperationGateBlocksTheRestOfTheAppWhileALaunchRuns() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor-launch-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnapshotStore(root: root)
        let snapshot = RestoreFixtures.snapshot([RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))])
        try store.create(snapshot)
        let model = SavedStatesModel(store: store)
        XCTAssertEqual(model.snapshots.count, 1)
        XCTAssertFalse(model.busy)

        executor.projectDelay = 0.4
        let running = Task {
            await model.launch.run(mode: .launchOnly,
                                   project: request(),
                                   rectangle: nil,
                                   accessibilityGranted: true,
                                   probe: probe,
                                   executor: executor)
        }
        while !model.launch.isRunning { await Task.yield() }
        XCTAssertTrue(model.busy)
        await model.preparePreview(for: snapshot.id)
        XCTAssertNil(model.plan)
        XCTAssertEqual(model.route, .home)
        await running.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(executor.liveWindowQueries, 0)
    }

    func testTheSavedRectangleForThatProjectIsTheOneOffered() {
        let path = "/Users/test/project"
        let record = RestoreFixtures.window(app: "PyCharm",
                                            bundleID: IntegrationKind.pycharm.bundleID,
                                            frame: CGRect(x: 0, y: 0, width: 844, height: 868),
                                            resources: RestoreFixtures.jetBrains(project: path))
        let snapshot = RestoreFixtures.snapshot([record])
        let resolved = LaunchRectangleSource.resolve(projectPath: path,
                                                     snapshots: [snapshot],
                                                     destination: RestoreFixtures.destination())
        XCTAssertEqual(resolved?.frame.width, 844)
        XCTAssertTrue(resolved?.provenance.contains("saved for this project") == true)
    }

    func testWithoutASavedRectangleTheFallbackIsStated() {
        let resolved = LaunchRectangleSource.resolve(projectPath: "/Users/test/other",
                                                     snapshots: [],
                                                     destination: RestoreFixtures.destination())
        XCTAssertTrue(resolved?.provenance.contains("no saved state") == true)
        XCTAssertEqual(resolved?.frame.width, 1008)
    }
}
