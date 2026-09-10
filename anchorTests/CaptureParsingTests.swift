import XCTest
@testable import anchor

final class CaptureParsingTests: XCTestCase {
    private func list(_ rows: [[String]]) -> ScriptValue {
        .list(rows.map { row in .list(row.map { .text($0) }) })
    }

    // every value arrives as its own list item, so nothing has to survive a delimiter
    func testBrowserTabsKeepArbitraryText() {
        let awkward = SnapshotFixtures.awkwardStrings
        let rows = awkward.map { ["ok", $0, "ok", "title \($0)"] }
        let value = ScriptValue.list([.text("3"), list(rows)])

        let resource = BrowserCapture.parseTabs(value, windowID: 7)
        XCTAssertEqual(resource.scriptWindowID, 7)
        XCTAssertEqual(resource.selectedTabIndex, 3)
        XCTAssertEqual(resource.tabs.count, awkward.count)
        for (index, original) in awkward.enumerated() {
            XCTAssertEqual(resource.tabs[index].url, original.isEmpty ? nil : original)
            XCTAssertEqual(resource.tabs[index].title, "title \(original)")
            XCTAssertNil(resource.tabs[index].issue)
        }
    }

    func testBrowserTabFailuresAreRecordedPerTab() {
        let value = ScriptValue.list([.text(""),
                                      list([["ok", "https://example.com", "ok", "Example"],
                                            ["error", "Safari got an error: -1728", "ok", "Untitled"],
                                            ["ok", "https://example.com/two", "error", "no title"]])])
        let resource = BrowserCapture.parseTabs(value, windowID: 1)
        XCTAssertNil(resource.selectedTabIndex)
        XCTAssertNil(resource.tabs[1].url)
        XCTAssertTrue(resource.tabs[1].issue?.contains("-1728") == true)
        XCTAssertEqual(resource.tabs[1].title, "Untitled")
        XCTAssertNil(resource.tabs[2].title)
        XCTAssertEqual(resource.tabs[2].url, "https://example.com/two")
        XCTAssertNil(resource.tabs[0].issue)
    }

    func testBrowserResourceAlwaysCarriesThePrivateWindowLimitation() {
        let resource = BrowserCapture.parseTabs(.list([.text("1"), list([])]), windowID: 2)
        XCTAssertTrue(resource.tabs.isEmpty)
        XCTAssertTrue(resource.privateWindowDetection.contains("cannot confirm"))
    }

    // an unusable tty must produce a visible omission rather than a guessed directory
    func testTerminalTabWithNoResolvableTTYKeepsNoDirectory() {
        let value = list([["ok", "/dev/ttys999", "true"],
                          ["error", "Terminal got an error", "false"]])
        let resource = TerminalCapture.resolveDirectories(value, windowID: 4)

        XCTAssertEqual(resource.tabs.count, 2)
        XCTAssertEqual(resource.tabs[0].tty, "/dev/ttys999")
        XCTAssertNil(resource.tabs[0].directory)
        XCTAssertNil(resource.tabs[0].directorySource)
        XCTAssertNotNil(resource.tabs[0].issue)
        XCTAssertEqual(resource.tabs[0].selected, true)
        XCTAssertNil(resource.tabs[1].tty)
        XCTAssertEqual(resource.tabs[1].selected, false)
    }

    func testGeometryPassParsesTheReportedWindowList() {
        let value = list([["3580", "0", "33", "756", "901", "true", "false", "1"],
                          ["?", "?", "?", "?", "?", "?", "?", "?"]])
        let windows = WindowGeometryScript.parse(value)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].scriptID, 3580)
        XCTAssertEqual(windows[0].bounds, CGRect(x: 0, y: 33, width: 756, height: 868))
        XCTAssertEqual(windows[0].visible, true)
        XCTAssertNil(windows[1].scriptID)
        XCTAssertNil(windows[1].bounds)
    }

    func testScriptValueTreeReadsNestedReplies() {
        let value = ScriptValue.list([.text("outer"), .list([.text("a"), .text("b")])])
        XCTAssertEqual(value.items.first?.text, "outer")
        XCTAssertEqual(value.items.last?.strings, ["a", "b"])
        XCTAssertTrue(ScriptValue.text("solo").items.isEmpty)
    }
}
