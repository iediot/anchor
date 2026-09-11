import AppKit
import XCTest
@testable import anchor

final class CaptureCoordinatorTests: XCTestCase {
    private func window(id: CGWindowID,
                        _ rect: CGRect,
                        fullScreen: FullScreenSignal = .ordinary,
                        title: String? = "window") -> InspectedWindow {
        InspectedWindow(id: id,
                        pid: 1,
                        ownerName: "Test",
                        bundleID: "test.app",
                        title: title,
                        titleSource: title == nil ? .unavailable : .accessibility,
                        serverFrame: rect,
                        appKitFrame: rect,
                        layer: 0,
                        alpha: 1,
                        screenName: "Test Display",
                        inScope: true,
                        scopeReason: "on the target display",
                        availability: .geometryOnly,
                        fullScreen: fullScreen,
                        axTitleMatched: true,
                        documentPath: nil)
    }

    private func scan(_ windows: [InspectedWindow]) throws -> WindowScan {
        let screen = try XCTUnwrap(NSScreen.main, "these checks need an attached display")
        let target = DisplayTarget(screen: screen,
                                   displayID: ScreenGeometry.displayID(of: screen),
                                   name: screen.localizedName,
                                   frame: screen.frame,
                                   visibleFrame: screen.visibleFrame,
                                   backingScale: screen.backingScaleFactor,
                                   source: .frontmostWindow,
                                   decidedBy: nil,
                                   pinnedFrom: nil)
        return WindowScan(windows: windows,
                          target: target,
                          accessibilityGranted: true,
                          screenRecordingGranted: false,
                          lostPinnedDisplay: false,
                          capturedAt: Date())
    }

    func testAStableScreenReportsNoDrift() throws {
        let windows = [window(id: 1, CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertTrue(CaptureCoordinator.drift(before: try scan(windows), after: try scan(windows)).isEmpty)
    }

    func testWindowsAppearingOrLeavingDuringCaptureAreReported() throws {
        let before = try scan([window(id: 1, CGRect(x: 0, y: 0, width: 100, height: 100)),
                               window(id: 2, CGRect(x: 0, y: 0, width: 100, height: 100))])
        let after = try scan([window(id: 1, CGRect(x: 0, y: 0, width: 100, height: 100)),
                              window(id: 3, CGRect(x: 0, y: 0, width: 100, height: 100))])
        let issues = CaptureCoordinator.drift(before: before, after: after)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .inconsistency)
        XCTAssertTrue(issues[0].message.contains("1 went away and 1 appeared"))
    }

    func testAWindowMovingDuringCaptureIsReported() throws {
        let before = try scan([window(id: 1, CGRect(x: 0, y: 0, width: 100, height: 100))])
        let after = try scan([window(id: 1, CGRect(x: 40, y: 0, width: 100, height: 100))])
        let issues = CaptureCoordinator.drift(before: before, after: after)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].message.contains("moved or resized"))
    }

    // a window anchor cannot capture must say so rather than look restorable
    func testUnsupportedWindowsCarryAnExplicitLimitation() {
        let notes = CaptureCoordinator.limitations(window(id: 1, CGRect(x: 0, y: 0, width: 100, height: 100)),
                                                   resources: .empty(.unsupported, .appNotSupported, "no adapter for this application"))
        XCTAssertTrue(notes.contains("no adapter for this application"))
        XCTAssertTrue(notes.contains { $0.contains("not restorable") })
    }

    func testCapturedBrowserWindowsAlwaysDeclareThePrivateWindowUncertainty() {
        let resources = WindowResources(kind: .browser,
                                        status: .captured,
                                        detail: nil,
                                        browser: BrowserResource(scriptWindowID: 1,
                                                                 selectedTabIndex: 1,
                                                                 tabs: [],
                                                                 privateWindowDetection: BrowserCapture.privateDetectionNote))
        let notes = CaptureCoordinator.limitations(window(id: 1, CGRect(x: 0, y: 0, width: 100, height: 100)),
                                                   resources: resources)
        XCTAssertTrue(notes.contains(BrowserCapture.privateDetectionLimitation))
    }

    func testObservedFullScreenModeIsRecordedWithItsUncertainty() {
        let notes = CaptureCoordinator.limitations(window(id: 1,
                                                          CGRect(x: 0, y: 0, width: 100, height: 100),
                                                          fullScreen: .coversDisplay),
                                                   resources: .empty(.unsupported, .appNotSupported, nil))
        XCTAssertTrue(notes.contains { $0.contains("unverified") && $0.contains("covers the whole display") })
    }

    func testAnUnreadableTitleIsRecordedAsALimitation() {
        let notes = CaptureCoordinator.limitations(window(id: 1,
                                                          CGRect(x: 0, y: 0, width: 100, height: 100),
                                                          title: nil),
                                                   resources: .empty(.unsupported, .appNotSupported, nil))
        XCTAssertTrue(notes.contains { $0.contains("no window title was readable") })
    }

    func testEveryIntegrationMapsToItsResourceKind() {
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .safari), .browser)
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .chrome), .browser)
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .terminal), .terminal)
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .iTerm), .terminal)
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .pycharm), .jetBrains)
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .clion), .jetBrains)
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .xcode), .xcode)
        XCTAssertEqual(CaptureCoordinator.resourceKind(for: .finder), .finder)
    }
}
