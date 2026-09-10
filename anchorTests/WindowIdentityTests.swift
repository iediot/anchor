import AppKit
import XCTest
@testable import anchor

final class WindowIdentityTests: XCTestCase {
    private let appPID: pid_t = 936

    private func scripted(id: Int?,
                          _ rect: CGRect,
                          visible: Bool? = true,
                          minimized: Bool? = false) -> ScriptedWindow {
        ScriptedWindow(scriptID: id, bounds: rect, visible: visible, miniaturized: minimized, index: 1)
    }

    private func window(id: CGWindowID,
                        _ rect: CGRect,
                        pid: pid_t? = nil,
                        title: String? = "window",
                        inScope: Bool = true) -> InspectedWindow {
        InspectedWindow(id: id,
                        pid: pid ?? appPID,
                        ownerName: "Terminal",
                        bundleID: "com.apple.Terminal",
                        title: title,
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

    private func correlate(_ scripted: [ScriptedWindow],
                           _ onScreen: [InspectedWindow],
                           identity: WindowIdentityBasis) -> CorrelationReport {
        WindowCorrelation.correlate(scripted: scripted,
                                    onScreen: onScreen,
                                    inScopeCount: onScreen.filter(\.inScope).count,
                                    identity: identity)
    }

    // the live terminal layout that produced the user's failure
    // reported 3580 and 2880 both fit on-screen 3580 under the geometry tolerance
    private let reportedTerminalWindows = [
        (3580, CGRect(x: 756, y: 33, width: 756, height: 868)),
        (2880, CGRect(x: 756, y: 35, width: 756, height: 865)),
        (2762, CGRect(x: 0, y: 33, width: 756, height: 868))
    ]

    func testRepeatedLayoutResolvesByReportedWindowID() {
        let onScreenRect = CGRect(x: 756, y: 33, width: 756, height: 868)
        let report = correlate(reportedTerminalWindows.map { scripted(id: $0.0, $0.1) },
                               [window(id: 3580, onScreenRect)],
                               identity: .windowServerNumber(pid: appPID))

        XCTAssertEqual(report.matches[0], .identified(3580, topEdgeDelta: 0))
        // the other reported windows are on other desktops, they must not contest this one
        XCTAssertEqual(report.matches[1], .unmatched)
        XCTAssertEqual(report.matches[2], .unmatched)
        XCTAssertEqual(report.identifiedCount, 1)
        XCTAssertEqual(report.contestedCount, 0)
        XCTAssertEqual(report.resolvedCount, 1)
    }

    // the same input without identity evidence must behave exactly as before
    func testTheSameLayoutStaysContestedOnGeometryAlone() {
        let onScreenRect = CGRect(x: 756, y: 33, width: 756, height: 868)
        let report = correlate(reportedTerminalWindows.map { scripted(id: $0.0, $0.1) },
                               [window(id: 3580, onScreenRect)],
                               identity: .geometryOnly("not verified for this app"))
        XCTAssertEqual(report.contestedCount, 2)
        XCTAssertEqual(report.identifiedCount, 0)
        XCTAssertEqual(report.resolvedCount, 0)
    }

    func testTwoOnScreenWindowsOfOneAppEachTakeTheirOwnReportedWindow() {
        let left = CGRect(x: 0, y: 33, width: 756, height: 868)
        let right = CGRect(x: 756, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 2762, left), scripted(id: 3580, right)],
                               [window(id: 3580, right), window(id: 2762, left)],
                               identity: .windowServerNumber(pid: appPID))
        XCTAssertEqual(report.matches[0].matchedWindow, 2762)
        XCTAssertEqual(report.matches[1].matchedWindow, 3580)
        XCTAssertEqual(report.identifiedCount, 2)
    }

    // identical titles are not evidence of anything, matching never reads them
    func testDuplicateTitlesDoNotImplyUniqueness() {
        let rect = CGRect(x: 0, y: 33, width: 600, height: 600)
        let onScreen = [window(id: 11, rect, title: "Downloads"), window(id: 12, rect, title: "Downloads")]

        let geometry = correlate([scripted(id: 11, rect)], onScreen, identity: .geometryOnly("none"))
        XCTAssertEqual(geometry.ambiguousCount, 1)
        XCTAssertEqual(geometry.resolvedCount, 0)

        let identified = correlate([scripted(id: 11, rect), scripted(id: 12, rect)],
                                   onScreen,
                                   identity: .windowServerNumber(pid: appPID))
        XCTAssertEqual(identified.identifiedCount, 2)
        XCTAssertEqual(identified.matches[0].matchedWindow, 11)
        XCTAssertEqual(identified.matches[1].matchedWindow, 12)
    }

    func testIdentityThatContradictsGeometryIsRefused() {
        let reported = CGRect(x: 0, y: 33, width: 756, height: 868)
        let elsewhere = CGRect(x: 900, y: 400, width: 300, height: 200)
        let report = correlate([scripted(id: 3580, reported)],
                               [window(id: 3580, elsewhere)],
                               identity: .windowServerNumber(pid: appPID))

        guard case .identityConflict(let id, let reason) = report.matches[0] else {
            return XCTFail("expected the conflicting id to be refused, got \(report.matches[0])")
        }
        XCTAssertEqual(id, 3580)
        XCTAssertTrue(reason.contains("geometries disagree"))
        XCTAssertEqual(report.resolvedCount, 0)
        XCTAssertEqual(report.identityConflictCount, 1)
    }

    func testIdentityNamingAnotherProcessIsRefused() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 3580, rect)],
                               [window(id: 3580, rect, pid: 4242)],
                               identity: .windowServerNumber(pid: appPID))

        guard case .identityConflict(_, let reason) = report.matches[0] else {
            return XCTFail("expected the foreign process to be refused, got \(report.matches[0])")
        }
        XCTAssertTrue(reason.contains("belongs to process 4242"))
        XCTAssertEqual(report.resolvedCount, 0)
    }

    func testTwoReportedWindowsSharingOneIDIdentifyNothing() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 3580, rect), scripted(id: 3580, rect)],
                               [window(id: 3580, rect)],
                               identity: .windowServerNumber(pid: appPID))
        XCTAssertEqual(report.identifiedCount, 0)
        XCTAssertEqual(report.contestedCount, 2)
    }

    func testAReportedWindowWithNoIDFallsBackToGeometry() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: nil, rect)],
                               [window(id: 3580, rect)],
                               identity: .windowServerNumber(pid: appPID))
        XCTAssertEqual(report.matches[0], .unique(3580, topEdgeDelta: 0))
        XCTAssertEqual(report.identifiedCount, 0)
        XCTAssertEqual(report.uniqueCount, 1)
    }

    // after a relaunch the app hands back ids that no window server window carries
    func testStaleIdentifiersFallBackToTheGeometryRulesUnchanged() {
        let onScreenRect = CGRect(x: 756, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 90001, CGRect(x: 756, y: 33, width: 756, height: 868)),
                                scripted(id: 90002, CGRect(x: 756, y: 35, width: 756, height: 865))],
                               [window(id: 3580, onScreenRect)],
                               identity: .windowServerNumber(pid: appPID))
        XCTAssertEqual(report.identifiedCount, 0)
        XCTAssertEqual(report.contestedCount, 2)
        XCTAssertEqual(report.resolvedCount, 0)
    }

    func testAMinimizedReportedWindowIsExcludedEvenWhenItsIDIsOnScreen() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 3580, rect, minimized: true)],
                               [window(id: 3580, rect)],
                               identity: .windowServerNumber(pid: appPID))
        guard case .excludedByReportedState = report.matches[0] else {
            return XCTFail("expected the app's own minimized state to exclude it, got \(report.matches[0])")
        }
        XCTAssertEqual(report.resolvedCount, 0)
    }

    // a window taken by identity must not still be offered to the geometry fallback
    func testAnIdentifiedWindowLeavesTheFallbackPool() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 3580, rect), scripted(id: nil, rect)],
                               [window(id: 3580, rect)],
                               identity: .windowServerNumber(pid: appPID))
        XCTAssertEqual(report.matches[0], .identified(3580, topEdgeDelta: 0))
        XCTAssertEqual(report.matches[1], .unmatched)
    }

    // the id relationship is an observation about geometry pairings and must stay that way
    func testTheIDRelationshipIsStillJudgedOnGeometryPairingsOnly() {
        let rect = CGRect(x: 0, y: 33, width: 756, height: 868)
        let identified = correlate([scripted(id: 3580, rect)],
                                   [window(id: 3580, rect)],
                                   identity: .windowServerNumber(pid: appPID))
        XCTAssertEqual(identified.relationship, .observedEqual(pairs: 1))

        let contested = correlate(reportedTerminalWindows.map { scripted(id: $0.0, $0.1) },
                                  [window(id: 3580, CGRect(x: 756, y: 33, width: 756, height: 868))],
                                  identity: .windowServerNumber(pid: appPID))
        // identity resolved a window, geometry alone still could not, so the relationship stays open
        XCTAssertEqual(contested.identifiedCount, 1)
        XCTAssertEqual(contested.relationship, .unresolvedNoUniquePair)
    }

    func testAnUnverifiedApplicationKeepsGeometryOnly() {
        for kind in [IntegrationKind.chrome, .iTerm, .pycharm, .clion] {
            guard case .geometryOnly(let reason) = WindowIdentity.basis(for: kind) else {
                return XCTFail("\(kind.displayName) must not use reported ids without evidence")
            }
            XCTAssertTrue(reason.contains(kind.displayName))
        }
    }

    func testAnAppThatIsNotRunningHasNoIdentityBasis() {
        // no anchor test run has two safaris, so this exercises the not-running branch honestly
        let basis = WindowIdentity.basis(for: .safari)
        if case .windowServerNumber(let pid) = basis {
            XCTAssertGreaterThan(pid, 0)
        } else if case .geometryOnly(let reason) = basis {
            XCTAssertTrue(reason.contains("Safari"))
        }
    }

    // the premise: the cocoa scripting key these dictionaries name is the window number,
    // and the window number is the window server id
    func testCocoaUniqueIDKeyIsTheWindowNumber() throws {
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 120),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let key = try XCTUnwrap(window.value(forKey: "uniqueID") as? NSNumber)
        XCTAssertEqual(key.intValue, window.windowNumber)

        let listed = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        XCTAssertTrue(listed.contains(CGWindowID(window.windowNumber)))
    }

    func testInstalledDictionariesStillBindWindowIDToTheUniqueIDKey() throws {
        for kind in WindowIdentity.windowNumberApps.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) else { continue }
            let text = try dictionaryText(forAppAt: bundle)
            let windowClass = try XCTUnwrap(Self.windowClass(in: text),
                                            "\(kind.displayName) declares no window class")
            XCTAssertTrue(windowClass.contains("name=\"id\""), "\(kind.displayName) window has no id property")
            XCTAssertTrue(windowClass.contains("uniqueID"),
                          "\(kind.displayName) no longer backs its window id with the cocoa uniqueID key")
        }
    }

    // the dictionary plus anything it pulls in by include
    private func dictionaryText(forAppAt bundle: URL) throws -> String {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        var text = ""
        for name in names where name.hasSuffix(".sdef") {
            text += (try? String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        if text.contains("CocoaStandard.sdef"), !text.contains("<!--<xi:include") {
            text += (try? String(contentsOfFile: "/System/Library/ScriptingDefinitions/CocoaStandard.sdef",
                                 encoding: .utf8)) ?? ""
        }
        return text
    }

    private static func windowClass(in text: String) -> String? {
        guard let start = text.range(of: "<class name=\"window\""),
              let end = text.range(of: "</class>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }
}
