import XCTest
@testable import anchor

final class CaptureScopeTests: XCTestCase {
    private func scripted(id: Int?, _ rect: CGRect) -> ScriptedWindow {
        ScriptedWindow(scriptID: id, bounds: rect, visible: true, miniaturized: false, index: 1)
    }

    private func window(id: CGWindowID, _ rect: CGRect, inScope: Bool = true) -> InspectedWindow {
        InspectedWindow(id: id,
                        pid: 1,
                        ownerName: "Test",
                        bundleID: "test.app",
                        title: "window",
                        titleSource: .accessibility,
                        serverFrame: rect,
                        appKitFrame: rect,
                        layer: 0,
                        alpha: 1,
                        screenName: "Test Display",
                        inScope: inScope,
                        scopeReason: inScope ? "on the target display" : "on another display",
                        availability: .geometryOnly,
                        fullScreen: .ordinary,
                        axTitleMatched: true,
                        documentPath: nil)
    }

    private func resolve(_ scripted: [ScriptedWindow],
                         _ onScreen: [InspectedWindow],
                         identity: WindowIdentityBasis = .geometryOnly("test")) -> [ScopeResolution] {
        let scoped = onScreen.filter(\.inScope)
        let report = WindowCorrelation.correlate(scripted: scripted,
                                                 onScreen: onScreen,
                                                 inScopeCount: scoped.count,
                                                 identity: identity)
        return CaptureScope.resolve(scripted: scripted, matches: report.matches, scopedWindows: scoped)
    }

    func testUniquePairingIsTheOnlyWayToEarnContent() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let resolutions = resolve([scripted(id: 3580, rect)], [window(id: 3580, rect)])
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions[0].outcome, .resolved(scriptWindowID: 3580))
    }

    // the contested terminal layout the user already has must attach no directory
    func testContestedWindowGetsNoContent() {
        let server = CGRect(x: 756, y: 33, width: 756, height: 868)
        let resolutions = resolve([scripted(id: 3580, CGRect(x: 756, y: 33, width: 756, height: 868)),
                                   scripted(id: 2880, CGRect(x: 756, y: 35, width: 756, height: 865))],
                                  [window(id: 3580, server)])
        XCTAssertNil(resolutions[0].outcome.scriptWindowID)
        XCTAssertTrue(resolutions[0].outcome.reason?.contains("2 windows reported by the app") == true)
    }

    func testAmbiguousWindowGetsNoContent() {
        let bounds = CGRect(x: 0, y: 33, width: 500, height: 500)
        let resolutions = resolve([scripted(id: 11, bounds)],
                                  [window(id: 11, bounds), window(id: 12, bounds)])
        XCTAssertEqual(resolutions.count, 2)
        for resolution in resolutions {
            XCTAssertNil(resolution.outcome.scriptWindowID)
            XCTAssertTrue(resolution.outcome.reason?.contains("equally well") == true)
        }
    }

    func testWindowPairedToAReportedWindowWithoutAnIDStaysUnresolved() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let resolutions = resolve([scripted(id: nil, rect)], [window(id: 900, rect)])
        XCTAssertNil(resolutions[0].outcome.scriptWindowID)
        XCTAssertTrue(resolutions[0].outcome.reason?.contains("without a usable id") == true)
    }

    func testWindowTheAppNeverReportedStaysUnresolved() {
        let resolutions = resolve([], [window(id: 900, CGRect(x: 0, y: 33, width: 500, height: 500))])
        XCTAssertNil(resolutions[0].outcome.scriptWindowID)
        XCTAssertTrue(resolutions[0].outcome.reason?.contains("no window reported by the app") == true)
    }

    // a window on another display is never offered content, even when it pairs cleanly
    func testOutOfScopeWindowsAreNotResolvedAtAll() {
        let scopedRect = CGRect(x: 0, y: 33, width: 500, height: 500)
        let otherRect = CGRect(x: 4000, y: 33, width: 500, height: 500)
        let resolutions = resolve([scripted(id: 11, scopedRect), scripted(id: 22, otherRect)],
                                  [window(id: 11, scopedRect),
                                   window(id: 22, otherRect, inScope: false)])
        XCTAssertEqual(resolutions.map(\.serverID), [11])
        XCTAssertEqual(resolutions[0].outcome, .resolved(scriptWindowID: 11))
    }

    func testMinimizedReportedWindowsCannotClaimAScopedWindow() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let hidden = ScriptedWindow(scriptID: 5, bounds: rect, visible: true, miniaturized: true, index: 1)
        let resolutions = resolve([hidden], [window(id: 5, rect)])
        XCTAssertNil(resolutions[0].outcome.scriptWindowID)
    }

    // the user's repeated safari and terminal layout, now resolvable
    func testAWindowIdentifiedByItsReportedIDEarnsContent() {
        let onScreenRect = CGRect(x: 756, y: 33, width: 756, height: 868)
        let resolutions = resolve([scripted(id: 3580, CGRect(x: 756, y: 33, width: 756, height: 868)),
                                   scripted(id: 2880, CGRect(x: 756, y: 35, width: 756, height: 865))],
                                  [window(id: 3580, onScreenRect)],
                                  identity: .windowServerNumber(pid: 1))
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions[0].outcome, .resolved(scriptWindowID: 3580))
    }

    func testARefusedIdentityExplainsItselfAndAttachesNothing() {
        let resolutions = resolve([scripted(id: 3580, CGRect(x: 0, y: 33, width: 756, height: 868))],
                                  [window(id: 3580, CGRect(x: 900, y: 400, width: 300, height: 200))],
                                  identity: .windowServerNumber(pid: 1))
        XCTAssertNil(resolutions[0].outcome.scriptWindowID)
        XCTAssertTrue(resolutions[0].outcome.reason?.contains("geometries disagree") == true)
    }

    func testIdentityDoesNotReachWindowsOnAnotherDisplay() {
        let scopedRect = CGRect(x: 0, y: 33, width: 500, height: 500)
        let otherRect = CGRect(x: 4000, y: 33, width: 500, height: 500)
        let resolutions = resolve([scripted(id: 11, scopedRect), scripted(id: 22, otherRect)],
                                  [window(id: 11, scopedRect),
                                   window(id: 22, otherRect, inScope: false)],
                                  identity: .windowServerNumber(pid: 1))
        XCTAssertEqual(resolutions.map(\.serverID), [11])
        XCTAssertEqual(resolutions[0].outcome, .resolved(scriptWindowID: 11))
    }
}
