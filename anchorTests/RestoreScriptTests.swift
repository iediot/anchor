import XCTest
@testable import anchor

@MainActor
final class RestoreScriptTests: XCTestCase {
    private func installed(_ kind: IntegrationKind) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) != nil
    }

    private func compile(_ source: String, _ label: String) {
        guard let script = NSAppleScript(source: source) else {
            return XCTFail("\(label) could not be created")
        }
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error),
                      "\(label) did not compile: \(error ?? [:])")
    }

    func testEveryRestoreScriptCompilesAgainstTheInstalledDictionary() {
        if installed(.safari) { compile(RestoreScripts.safari, "the safari script") }
        if installed(.terminal) { compile(RestoreScripts.terminal, "the terminal script") }
        if installed(.chrome) { compile(RestoreScripts.chrome, "the chrome script") }
        if installed(.iTerm) { compile(RestoreScripts.iTerm, "the iterm script") }
        XCTAssertTrue(installed(.safari) || installed(.terminal),
                      "this machine has neither safari nor terminal, so nothing was compiled")
    }

    // the collision that broke a capture script was a scratch name that is also
    // dictionary terminology, so every scratch name here stays prefixed
    func testEveryScratchNameIsPrefixed() {
        for (label, source) in [("safari", RestoreScripts.safari),
                                ("chrome", RestoreScripts.chrome),
                                ("terminal", RestoreScripts.terminal),
                                ("iterm", RestoreScripts.iTerm)] {
            for line in source.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("set ") else { continue }
                let words = trimmed.dropFirst(4).split(separator: " ")
                // only a plain assignment declares a scratch name, a property assignment
                // reads as set something of something to a value
                guard words.count > 1, words[1] == "to", let name = words.first else { continue }
                XCTAssertTrue(name.hasPrefix("pv"),
                              "the \(label) script assigns to \(name), which is not a prefixed scratch name")
            }
        }
    }

    // phase 3 opens work, it never closes or replaces any
    func testNoRestoreScriptCanCloseOrQuitAnything() {
        for (label, source) in [("safari", RestoreScripts.safari),
                                ("chrome", RestoreScripts.chrome),
                                ("terminal", RestoreScripts.terminal),
                                ("iterm", RestoreScripts.iTerm)] {
            for forbidden in ["close", "quit", "delete", "terminate"] {
                XCTAssertFalse(source.lowercased().contains(forbidden),
                               "the \(label) script mentions \(forbidden)")
            }
        }
    }

    // the arguments reach the handler as apple event values, so nothing a saved address
    // contains can become script text
    func testHandlerArgumentsSurviveAsValuesRatherThanText() async {
        let source = """
        on anchoropen(pvvalues, pvsecond)
            return {"ok", pvsecond, "", pvvalues}
        end anchoropen
        """
        let awkward = ["https://example.com/a\"b'c\\\\d",
                       "\" & (do shell script \"echo no\") & \"",
                       "https://example.com/\u{1F600}?x=1&y=2"]
        let outcome = await ScriptRunner.shared.runHandler(source,
                                                           handler: RestoreScripts.handler,
                                                           arguments: [.list(awkward.map { .text($0) }), .text("2")],
                                                           timeout: 10)
        guard case .value(let value) = outcome else {
            return XCTFail("the handler did not return a value: \(outcome.failureDescription ?? "no reason")")
        }
        let reply = RestoreScripts.parse(value)
        XCTAssertEqual(reply.state, "ok")
        XCTAssertEqual(reply.windowID, "2")
        XCTAssertEqual(reply.itemStates, awkward)
    }
}
