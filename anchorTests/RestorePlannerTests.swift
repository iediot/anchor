import XCTest
@testable import anchor

@MainActor
final class RestorePlannerTests: XCTestCase {
    private var environment = StubEnvironment()

    override func setUp() {
        super.setUp()
        environment = StubEnvironment()
    }

    private func plan(_ windows: [WindowRecord],
                      completeness: SnapshotCompleteness = .complete,
                      destination: DestinationDisplay? = nil) -> RestorePlan {
        RestorePlanner.build(snapshot: RestoreFixtures.snapshot(windows, completeness: completeness),
                             destination: destination ?? RestoreFixtures.destination(),
                             environment: environment)
    }

    private func onlyWindow(_ plan: RestorePlan) -> RestorePlanWindow {
        XCTAssertEqual(plan.windows.count, 1)
        return plan.windows[0]
    }

    private func browserRequest(_ window: RestorePlanWindow) -> BrowserOpenRequest? {
        if case .openBrowserWindow(let request) = window.action { return request }
        return nil
    }

    func testTabsKeepTheirOrderAndTheSelectedTabIsCarriedOver() {
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example",
                                                                               "https://two.example",
                                                                               "https://three.example"],
                                                                              selected: 2))
        let window = onlyWindow(plan([record]))
        guard let request = browserRequest(window) else { return XCTFail("expected a browser action") }
        XCTAssertEqual(request.tabs.map(\.content), [.web("https://one.example"),
                                                     .web("https://two.example"),
                                                     .web("https://three.example")])
        XCTAssertEqual(request.selectedTab, 2)
        XCTAssertEqual(request.app, .safari)
    }

    func testAnUnsupportedSchemeIsReportedAndLeftOutOfTheRequest() {
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example",
                                                                               "javascript:alert(1)"]))
        let window = onlyWindow(plan([record]))
        guard let request = browserRequest(window) else { return XCTFail("expected a browser action") }
        XCTAssertEqual(request.tabs.count, 1)
        guard case .unsupportedScheme = window.items[1].status else {
            return XCTFail("the second tab should be reported as an unsupported address")
        }
    }

    func testAnOrdinaryBlankTabIsPlannedAsABlankTab() {
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["about:blank"]))
        let window = onlyWindow(plan([record]))
        XCTAssertEqual(browserRequest(window)?.tabs.map(\.content), [.blank])
        XCTAssertEqual(window.items[0].kind, .blankTab)
        XCTAssertTrue(window.items[0].status.isActionable)
    }

    func testAMissingLocalFileIsMissingRatherThanUnsupported() {
        environment.files["/tmp/gone.html"] = .missing
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["file:///tmp/gone.html"]))
        let window = onlyWindow(plan([record]))
        guard case .missingPath = window.items[0].status else {
            return XCTFail("a file that is gone is a missing path")
        }
        XCTAssertFalse(window.isActionable)
    }

    func testAnUnreadablePathIsNotReportedAsMissing() {
        environment.files["/tmp/locked.html"] = .inaccessible("this build is not allowed to read it")
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["file:///tmp/locked.html"]))
        let window = onlyWindow(plan([record]))
        guard case .inaccessiblePath = window.items[0].status else {
            return XCTFail("an unreadable path is not the same as a missing one")
        }
    }

    func testLosingTheSelectedTabIsStatedAsALimitation() {
        environment.files["/tmp/gone.html"] = .missing
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example",
                                                                               "file:///tmp/gone.html"],
                                                                              selected: 2))
        let window = onlyWindow(plan([record]))
        XCTAssertNil(browserRequest(window)?.selectedTab)
        XCTAssertTrue(window.limitations.contains { $0.contains("selected when this state was saved") })
    }

    func testAWindowWhoseTabsAreAllUnusableOpensNothing() {
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["javascript:alert(1)"]))
        let window = onlyWindow(plan([record]))
        XCTAssertFalse(window.isActionable)
        XCTAssertEqual(window.action, .nothing("no tab in this window can be reopened"))
    }

    func testTerminalOpensOneWindowAndSaysTheOtherSessionsAreNotGrouped() {
        let record = RestoreFixtures.window(app: "Terminal",
                                            bundleID: "com.apple.Terminal",
                                            resources: RestoreFixtures.terminal(["/tmp/one", "/tmp/two"],
                                                                                selectedIndex: 2))
        let window = onlyWindow(plan([record]))
        guard case .openTerminalSession(let request) = window.action else {
            return XCTFail("expected a terminal action")
        }
        XCTAssertEqual(request.directory, "/tmp/two")
        guard case .unsupported = window.items[0].status else {
            return XCTFail("the session anchor cannot group must say so")
        }
        XCTAssertTrue(window.limitations.contains { $0.contains("no tab creation anchor has verified") })
    }

    func testASessionWithNoCapturedDirectoryIsACaptureOmission() {
        let record = RestoreFixtures.window(app: "Terminal",
                                            bundleID: "com.apple.Terminal",
                                            resources: RestoreFixtures.terminal([nil]))
        let window = onlyWindow(plan([record]))
        guard case .omittedAtCapture = window.items[0].status else {
            return XCTFail("a directory that was never captured is an omission, not a malformed record")
        }
        XCTAssertFalse(window.isActionable)
    }

    func testAMissingSavedDirectoryIsReportedMissing() {
        environment.files["/tmp/gone"] = .missing
        let record = RestoreFixtures.window(app: "Terminal",
                                            bundleID: "com.apple.Terminal",
                                            resources: RestoreFixtures.terminal(["/tmp/gone"]))
        let window = onlyWindow(plan([record]))
        guard case .missingPath = window.items[0].status else { return XCTFail("expected a missing directory") }
        XCTAssertFalse(window.isActionable)
    }

    func testXcodeOpensTheProjectAndReportsTheActiveFileAsUnsupported() {
        let record = RestoreFixtures.window(app: "Xcode",
                                            bundleID: "com.apple.dt.Xcode",
                                            resources: RestoreFixtures.xcode(project: "/Users/test/thing.xcodeproj",
                                                                             activeFile: "/Users/test/thing/main.swift"))
        let window = onlyWindow(plan([record]))
        guard case .openProject(let request) = window.action else { return XCTFail("expected a project action") }
        XCTAssertEqual(request.path, "/Users/test/thing.xcodeproj")
        let activeFile = window.items.first { $0.kind == .activeFile }
        guard case .unsupported = activeFile?.status else {
            return XCTFail("the active file has no verified mechanism and must say so")
        }
    }

    func testXcodeWithNoSavedProjectOpensNothing() {
        let record = RestoreFixtures.window(app: "Xcode",
                                            bundleID: "com.apple.dt.Xcode",
                                            resources: RestoreFixtures.xcode(project: nil))
        let window = onlyWindow(plan([record]))
        XCTAssertFalse(window.isActionable)
    }

    func testAnAmbiguousJetBrainsProjectOpensNothing() {
        let record = RestoreFixtures.window(app: "PyCharm",
                                            bundleID: "com.jetbrains.pycharm",
                                            resources: RestoreFixtures.jetBrains(project: nil,
                                                                                 candidates: ["/a/thing", "/b/thing"]))
        let window = onlyWindow(plan([record]))
        XCTAssertFalse(window.isActionable)
        guard case .ambiguousIdentity = window.items[0].status else {
            return XCTFail("two candidates identify nothing")
        }
    }

    func testJetBrainsProjectIsHeuristicAndItsEditorFilesAreNotRestored() {
        let record = RestoreFixtures.window(app: "PyCharm",
                                            bundleID: "com.jetbrains.pycharm",
                                            resources: RestoreFixtures.jetBrains(project: "/Users/test/thing",
                                                                                 editorFiles: ["/Users/test/thing/a.py"]))
        let window = onlyWindow(plan([record]))
        guard case .openProject = window.action else { return XCTFail("expected a project action") }
        guard case .readyWithLimitation = window.items[0].status else {
            return XCTFail("a title matched project is a heuristic and must be labelled")
        }
        let editor = window.items.first { $0.kind == .editorFile }
        guard case .unsupported = editor?.status else {
            return XCTFail("anchor has no verified way to reopen the saved editor list")
        }
    }

    func testAWindowWithNoAdapterIsNeverLaunched() {
        let record = RestoreFixtures.window(app: "Notes",
                                            bundleID: "com.apple.Notes",
                                            resources: .empty(.unsupported, .appNotSupported, "no adapter"))
        let window = onlyWindow(plan([record]))
        XCTAssertFalse(window.isActionable)
        guard case .unsupported = window.items[0].status else { return XCTFail("expected an unsupported window") }
    }

    func testBrowserTabsLeftOutOfTheSaveAreReportedAsSuch() {
        let resources = WindowResources.empty(.browser, .omittedByUser, CaptureCoordinator.browserOmissionDetail)
        let window = onlyWindow(plan([RestoreFixtures.window(resources: resources)]))
        XCTAssertFalse(window.isActionable)
        guard case .omittedAtCapture = window.items[0].status else {
            return XCTFail("an omission at capture time is not a missing resource")
        }
    }

    func testAWindowThatCaptureCouldNotResolveIsAnIdentityProblem() {
        let resources = WindowResources.empty(.terminal, .windowNotResolved, "two windows fit this one")
        let record = RestoreFixtures.window(app: "Terminal", bundleID: "com.apple.Terminal", resources: resources)
        let window = onlyWindow(plan([record]))
        guard case .ambiguousIdentity = window.items[0].status else {
            return XCTFail("an unresolved capture is an identity problem")
        }
    }

    func testDeniedAutomationBlocksTheWindowBeforeAnythingIsAsked() {
        environment.automation["com.apple.Safari"] = .denied
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))
        let window = onlyWindow(plan([record]))
        XCTAssertFalse(window.isActionable)
        guard case .permissionNeeded = window.items[0].status else { return XCTFail("expected a permission answer") }
    }

    func testAnApplicationThatIsNotInstalledBlocksItsWindows() {
        environment.apps["com.google.Chrome"] = .notInstalled
        let record = RestoreFixtures.window(app: "Google Chrome",
                                            bundleID: "com.google.Chrome",
                                            resources: RestoreFixtures.browser(["https://one.example"]))
        let window = onlyWindow(plan([record]))
        XCTAssertFalse(window.isActionable)
        guard case .appUnavailable = window.items[0].status else { return XCTFail("expected an unavailable app") }
    }

    func testWithoutAccessibilityTheLayoutIsAPermissionItem() {
        environment.accessibilityGranted = false
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))
        let built = plan([record])
        let layout = built.windows[0].items.first { $0.kind == .layout }
        guard case .permissionNeeded = layout?.status else { return XCTFail("expected a permission item") }
        XCTAssertTrue(built.notes.contains { $0.severity == .blocker })
    }

    func testAFullscreenSnapshotSaysNativeModeIsNotReconstructed() {
        let record = RestoreFixtures.window(fullScreen: "fullscreen confirmed by accessibility",
                                            resources: RestoreFixtures.browser(["https://one.example"]))
        let layout = onlyWindow(plan([record])).items.first { $0.kind == .layout }
        guard case .readyWithLimitation(let note) = layout?.status else {
            return XCTFail("expected a stated limitation")
        }
        XCTAssertTrue(note.contains("does not reconstruct native fullscreen"))
    }

    func testAnUnusableRectangleStillLetsTheWindowOpen() {
        let record = RestoreFixtures.window(frame: CGRect(x: 0, y: 0, width: 0, height: 0),
                                            resources: RestoreFixtures.browser(["https://one.example"]))
        let window = onlyWindow(plan([record]))
        XCTAssertTrue(window.isActionable)
        guard case .unavailable = window.layout else { return XCTFail("a zero sized record has no layout") }
        let layout = window.items.first { $0.kind == .layout }
        guard case .malformed = layout?.status else { return XCTFail("expected a malformed layout item") }
    }

    func testAPartialSnapshotIsNotPresentedAsAPromise() {
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))
        let built = plan([record], completeness: .partial)
        XCTAssertTrue(built.notes.contains { $0.text.contains("partial capture") })
        XCTAssertTrue(built.notes.contains { $0.text == RestorePlanner.developmentNote })
    }

    // the plan is built from questions only, and the executor is never involved
    func testBuildingAPlanPerformsNoOperation() {
        let executor = RecordingExecutor()
        let record = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example",
                                                                                "file:///tmp/thing.html"]))
        let terminal = RestoreFixtures.window(app: "Terminal",
                                              bundleID: "com.apple.Terminal",
                                              resources: RestoreFixtures.terminal(["/tmp/one"]))
        let built = plan([record, terminal])
        XCTAssertEqual(built.groups.count, 2)
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertFalse(environment.fileQueries.isEmpty)
    }

    func testWindowsAreGroupedByApplicationInTheOrderTheyWereSaved() {
        let safari = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://one.example"]))
        let terminal = RestoreFixtures.window(app: "Terminal",
                                              bundleID: "com.apple.Terminal",
                                              resources: RestoreFixtures.terminal(["/tmp/one"]))
        let safariTwo = RestoreFixtures.window(resources: RestoreFixtures.browser(["https://two.example"]))
        let built = plan([safari, terminal, safariTwo])
        XCTAssertEqual(built.groups.map(\.appName), ["Safari", "Terminal"])
        XCTAssertEqual(built.groups[0].windows.count, 2)
        XCTAssertEqual(built.actionableWindowCount, 3)
    }
}
