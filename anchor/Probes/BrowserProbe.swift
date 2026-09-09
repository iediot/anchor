import AppKit

// counts tabs per window without reading any url or title text
// browser persistence policy is unsettled so nothing personal is collected here
enum BrowserProbe {
    private static let safariScript = """
    tell application "Safari"
        set report to ""
        repeat with w in windows
            set wid to "?"
            set tabCount to -1
            set currentIndex to -1
            try
                set wid to (id of w) as text
            end try
            try
                set tabCount to (count of tabs of w)
            end try
            try
                set currentIndex to (index of current tab of w)
            end try
            set report to report & wid & "|" & tabCount & "|" & currentIndex & linefeed
        end repeat
        return report
    end tell
    """

    private static let chromeScript = """
    tell application "Google Chrome"
        set report to ""
        repeat with w in windows
            set wid to "?"
            set tabCount to -1
            set currentIndex to -1
            try
                set wid to (id of w) as text
            end try
            try
                set tabCount to (count of tabs of w)
            end try
            try
                set currentIndex to (active tab index of w)
            end try
            set report to report & wid & "|" & tabCount & "|" & currentIndex & linefeed
        end repeat
        return report
    end tell
    """

    static func run(_ kind: IntegrationKind, scan: WindowScan) async -> ProbeResult {
        let script = kind == .safari ? safariScript : chromeScript
        let outcome = await ScriptRunner.shared.run(script)
        guard case .text(let text) = outcome else {
            return ProbeResult(kind: kind, ranAt: Date(),
                               summary: outcome.failureDescription ?? "no result",
                               succeeded: false, rows: [], notes: [])
        }

        let serverIDs = Set(scan.windows.filter { $0.bundleID == kind.bundleID }.map { UInt32($0.id) })
        var rows: [ProbeRow] = []
        var matchedIDs = 0
        var scriptWindows = 0

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            scriptWindows += 1
            let scriptID = UInt32(parts[0])
            let matches = scriptID.map(serverIDs.contains) ?? false
            if matches { matchedIDs += 1 }
            rows.append(ProbeRow(label: "automation window \(parts[0])",
                                 detail: "\(parts[1]) tabs, selected tab index \(parts[2]), window server id match: \(matches ? "yes" : "no")"))
        }

        var notes = [
            "tab urls and titles were deliberately not read, browser persistence policy is still open",
            "window server ids come from the same scan that produced the scoped window list"
        ]
        if scriptWindows > 0 && matchedIDs == 0 {
            notes.append("automation window ids do not equal window server ids for this app, window matching needs another key")
        }
        let summary = scriptWindows == 0
            ? "no scriptable windows reported"
            : "\(scriptWindows) windows reported, \(matchedIDs) matched a window server id"
        return ProbeResult(kind: kind, ranAt: Date(), summary: summary, succeeded: true, rows: rows, notes: notes)
    }
}
