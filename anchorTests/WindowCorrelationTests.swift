import XCTest
@testable import anchor

final class WindowCorrelationTests: XCTestCase {
    private func scripted(id: Int?,
                          _ rect: CGRect,
                          visible: Bool? = true,
                          minimized: Bool? = false) -> ScriptedWindow {
        ScriptedWindow(scriptID: id, bounds: rect, visible: visible, miniaturized: minimized, index: 1)
    }

    private func onScreen(id: CGWindowID, _ rect: CGRect) -> InspectedWindow {
        InspectedWindow(id: id,
                        pid: 1,
                        ownerName: "Test",
                        bundleID: "test.app",
                        title: nil,
                        titleSource: .unavailable,
                        serverFrame: rect,
                        appKitFrame: rect,
                        layer: 0,
                        alpha: 1,
                        screenName: "Test Display",
                        inScope: true,
                        scopeReason: "test",
                        availability: .geometryOnly,
                        fullScreen: .ordinary,
                        axTitleMatched: false,
                        documentPath: nil)
    }

    private func correlate(_ scripted: [ScriptedWindow], _ onScreen: [InspectedWindow]) -> CorrelationReport {
        WindowCorrelation.correlate(scripted: scripted, onScreen: onScreen, inScopeCount: onScreen.count)
    }

    // one on-screen window claimed by two reported windows
    // this is the terminal case that was previously reported as two unique pairs
    func testTwoReportedWindowsFittingOneOnScreenWindowAreContested() {
        let server = CGRect(x: 756, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 3580, CGRect(x: 756, y: 33, width: 756, height: 868)),
                                scripted(id: 2880, CGRect(x: 756, y: 35, width: 756, height: 865))],
                               [onScreen(id: 3580, server)])
        XCTAssertEqual(report.contestedCount, 2)
        XCTAssertEqual(report.uniqueCount, 0)
        for match in report.matches {
            guard case .contested(let id, let competing) = match else {
                return XCTFail("expected a contested pairing, got \(match)")
            }
            XCTAssertEqual(id, 3580)
            XCTAssertEqual(competing, 2)
        }
    }

    // and the contested pair must not produce an id conclusion of any kind
    func testContestedPairsCarryNoIDEvidence() {
        let server = CGRect(x: 756, y: 33, width: 756, height: 868)
        let report = correlate([scripted(id: 3580, CGRect(x: 756, y: 33, width: 756, height: 868)),
                                scripted(id: 2880, CGRect(x: 756, y: 35, width: 756, height: 865))],
                               [onScreen(id: 3580, server)])
        XCTAssertEqual(report.relationship, .unresolvedNoUniquePair)
    }

    // a real one-to-one pairing elsewhere must not be rescued by a contested pairing
    func testContestedPairsDoNotContaminateAResolvedPair() {
        let contestedRect = CGRect(x: 756, y: 33, width: 756, height: 868)
        let ownRect = CGRect(x: 0, y: 33, width: 400, height: 300)
        let report = correlate([scripted(id: 3580, contestedRect),
                                scripted(id: 2880, CGRect(x: 756, y: 35, width: 756, height: 865)),
                                scripted(id: 77, ownRect)],
                               [onScreen(id: 3580, contestedRect), onScreen(id: 77, ownRect)])
        XCTAssertEqual(report.contestedCount, 2)
        XCTAssertEqual(report.uniqueCount, 1)
        XCTAssertEqual(report.relationship, .observedEqual(pairs: 1))
    }

    // one reported window fitting two on-screen windows
    func testOneReportedWindowFittingTwoOnScreenWindowsIsAmbiguous() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let report = correlate([scripted(id: 4242, rect)],
                               [onScreen(id: 91, rect), onScreen(id: 92, rect)])
        XCTAssertEqual(report.matches, [.ambiguousCandidates([91, 92])])
        XCTAssertEqual(report.ambiguousCount, 1)
        XCTAssertEqual(report.uniqueCount, 0)
        XCTAssertEqual(report.relationship, .unresolvedNoUniquePair)
    }

    func testSimpleOneToOnePairResolves() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let report = correlate([scripted(id: 4242, rect)], [onScreen(id: 91, rect)])
        XCTAssertEqual(report.uniqueCount, 1)
        XCTAssertEqual(report.relationship, .observedDifferent(pairs: 1))
        XCTAssertTrue(report.matches[0].resolvesScope)
    }

    func testEqualIDsAreObservedOnAResolvedPair() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let report = correlate([scripted(id: 91, rect)], [onScreen(id: 91, rect)])
        XCTAssertEqual(report.relationship, .observedEqual(pairs: 1))
    }

    // an empty candidate set is missing evidence, never proof that the namespaces differ
    func testNoCandidatesNeverConcludesDifferentNamespaces() {
        let report = correlate([scripted(id: 4242, CGRect(x: 0, y: 0, width: 800, height: 600))], [])
        XCTAssertEqual(report.relationship, .noCandidates)
        XCTAssertEqual(report.uniqueCount, 0)
    }

    func testNoScriptedWindowsIsItsOwnOutcome() {
        let report = correlate([], [onScreen(id: 7, CGRect(x: 0, y: 0, width: 800, height: 600))])
        XCTAssertEqual(report.relationship, .noScriptedWindows)
    }

    func testMinimizedReportedWindowIsExcludedFromMatching() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let report = correlate([scripted(id: 4242, rect, minimized: true)], [onScreen(id: 91, rect)])
        XCTAssertEqual(report.excludedCount, 1)
        XCTAssertEqual(report.uniqueCount, 0)
        XCTAssertEqual(report.relationship, .unresolvedNoUniquePair)
        XCTAssertFalse(report.matches[0].resolvesScope)
    }

    func testHiddenReportedWindowIsExcludedFromMatching() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let report = correlate([scripted(id: 4242, rect, visible: false)], [onScreen(id: 91, rect)])
        XCTAssertEqual(report.excludedCount, 1)
        XCTAssertEqual(report.uniqueCount, 0)
    }

    // excluding a hidden twin must free its rival to resolve normally
    func testExcludingAHiddenTwinLeavesTheVisibleWindowResolved() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let report = correlate([scripted(id: 91, rect),
                                scripted(id: 4242, rect, minimized: true)],
                               [onScreen(id: 91, rect)])
        XCTAssertEqual(report.uniqueCount, 1)
        XCTAssertEqual(report.excludedCount, 1)
        XCTAssertEqual(report.relationship, .observedEqual(pairs: 1))
    }

    func testDisagreeingResolvedPairsAreReportedAsInconsistent() {
        let first = CGRect(x: 0, y: 0, width: 400, height: 300)
        let second = CGRect(x: 500, y: 0, width: 400, height: 300)
        let report = correlate([scripted(id: 91, first), scripted(id: 4242, second)],
                               [onScreen(id: 91, first), onScreen(id: 92, second)])
        XCTAssertEqual(report.relationship, .inconsistent(equal: 1, different: 1))
    }

    func testTopEdgeMayDifferByATitleBar() {
        let report = correlate([scripted(id: 1, CGRect(x: 100, y: 78, width: 800, height: 572))],
                               [onScreen(id: 91, CGRect(x: 100, y: 50, width: 800, height: 600))])
        XCTAssertEqual(report.matches, [.unique(91, topEdgeDelta: -28)])
    }

    func testTopEdgeDriftInEitherDirectionPairs() {
        let report = correlate([scripted(id: 1, CGRect(x: 100, y: 22, width: 800, height: 628))],
                               [onScreen(id: 91, CGRect(x: 100, y: 50, width: 800, height: 600))])
        XCTAssertEqual(report.matches, [.unique(91, topEdgeDelta: 28)])
    }

    func testTopEdgeBeyondTheAllowanceDoesNotPair() {
        let report = correlate([scripted(id: 1, CGRect(x: 100, y: 200, width: 800, height: 450))],
                               [onScreen(id: 91, CGRect(x: 100, y: 50, width: 800, height: 600))])
        XCTAssertEqual(report.matches, [.unmatched])
    }

    // a layout repeated on another desktop must stay ambiguous rather than pair by luck
    func testSideEdgesMustLineUp() {
        let report = correlate([scripted(id: 1, CGRect(x: 100, y: 50, width: 800, height: 600))],
                               [onScreen(id: 91, CGRect(x: 400, y: 50, width: 800, height: 600))])
        XCTAssertEqual(report.matches, [.unmatched])
    }
}

final class JetBrainsMatchingTests: XCTestCase {
    private func entry(_ path: String, name: String?) -> RecentProjectEntry {
        RecentProjectEntry(path: path, projectName: name, frameTitle: nil, openedAt: nil)
    }

    // two checkouts of the same project name must not resolve to whichever was listed first
    func testSameNamedProjectsStayAmbiguous() {
        let entries = [entry("/a/anchor", name: nil), entry("/b/anchor", name: nil)]
        let hits = JetBrainsProbe.candidates(title: "anchor \u{2013} main.swift", among: entries)
        XCTAssertEqual(hits.count, 2)
    }

    func testLeadingSegmentIsTheProjectName() {
        XCTAssertEqual(JetBrainsProbe.leadingSegment("gameboy_emu \u{2013} icon.png"), "gameboy_emu")
        XCTAssertEqual(JetBrainsProbe.leadingSegment("plain"), "plain")
    }

    func testUnrelatedTitleMatchesNothing() {
        let entries = [entry("/a/anchor", name: nil)]
        XCTAssertTrue(JetBrainsProbe.candidates(title: "something else \u{2013} x", among: entries).isEmpty)
    }
}
