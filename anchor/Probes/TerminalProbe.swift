import AppKit

// terminal has no working directory property so the tty is resolved through libproc
// no shell startup file is read or changed and no history or contents are collected
enum TerminalProbe {
    private static let terminalScript = """
    tell application "Terminal"
        set report to ""
        repeat with w in windows
            set wid to "?"
            set l to "?"
            set t to "?"
            set r to "?"
            set b to "?"
            set vis to "?"
            set mini to "?"
            set idx to "?"
            try
                set wid to (id of w) as text
            end try
            try
                set bnds to bounds of w
                set l to (item 1 of bnds) as text
                set t to (item 2 of bnds) as text
                set r to (item 3 of bnds) as text
                set b to (item 4 of bnds) as text
            end try
            try
                set vis to (visible of w) as text
            end try
            try
                set mini to (miniaturized of w) as text
            end try
            try
                set idx to (index of w) as text
            end try
            set ttys to ""
            repeat with tb in tabs of w
                set ttyPath to "?"
                set sel to "?"
                try
                    set ttyPath to tty of tb
                end try
                try
                    set sel to (selected of tb) as text
                end try
                set ttys to ttys & ttyPath & "," & sel & ";"
            end repeat
            set report to report & wid & "<|>" & l & "<|>" & t & "<|>" & r & "<|>" & b & "<|>" & vis & "<|>" & mini & "<|>" & idx & "<|>" & ttys & linefeed
        end repeat
        return report
    end tell
    """

    private static let itermScript = """
    tell application "iTerm"
        set report to ""
        repeat with w in windows
            set wid to "?"
            set l to "?"
            set t to "?"
            set r to "?"
            set b to "?"
            set vis to "?"
            set mini to "?"
            set idx to "?"
            try
                set wid to (id of w) as text
            end try
            try
                set bnds to bounds of w
                set l to (item 1 of bnds) as text
                set t to (item 2 of bnds) as text
                set r to (item 3 of bnds) as text
                set b to (item 4 of bnds) as text
            end try
            try
                set vis to (visible of w) as text
            end try
            try
                set mini to (miniaturized of w) as text
            end try
            try
                set idx to (index of w) as text
            end try
            set ttys to ""
            repeat with tb in tabs of w
                repeat with s in sessions of tb
                    set ttyPath to "?"
                    try
                        set ttyPath to tty of s
                    end try
                    set ttys to ttys & ttyPath & ",session;"
                end repeat
            end repeat
            set report to report & wid & "<|>" & l & "<|>" & t & "<|>" & r & "<|>" & b & "<|>" & vis & "<|>" & mini & "<|>" & idx & "<|>" & ttys & linefeed
        end repeat
        return report
    end tell
    """

    static func run(_ kind: IntegrationKind, scan: WindowScan) async -> ProbeResult {
        let outcome = await ScriptRunner.shared.run(kind == .terminal ? terminalScript : itermScript)
        guard case .text(let text) = outcome else {
            return ProbeResult(kind: kind, ranAt: Date(),
                               summary: outcome.failureDescription ?? "no result",
                               succeeded: false, rows: [], notes: [])
        }

        var scripted: [ScriptedWindow] = []
        var tabLists: [[(tty: String, selected: String)]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: ScriptedWindow.fieldSeparator)
            guard fields.count >= ScriptedWindow.leadingFieldCount else { continue }
            scripted.append(ScriptedWindow.parse(fields))
            tabLists.append(parseTabs(fields[safe: 8] ?? ""))
        }

        let onScreen = scan.windows(ofBundleID: kind.bundleID)
        let report = WindowCorrelation.correlate(scripted: scripted,
                                                 onScreen: onScreen,
                                                 inScopeCount: onScreen.filter(\.inScope).count,
                                                 identity: WindowIdentity.basis(for: kind))

        var rows: [ProbeRow] = []
        var resolved = 0
        var tabs = 0
        for (index, window) in scripted.enumerated() {
            rows.append(ProbeRow(label: "reported window \(index + 1)", detail: window.stateDescription))
            rows.append(ProbeRow(label: "    pairing",
                                 detail: WindowCorrelation.describe(report.matches[index])))
            for tab in tabLists[index] {
                tabs += 1
                let lookup = ProcessLookup.foregroundDirectory(onTTY: tab.tty)
                if lookup.directory != nil { resolved += 1 }
                rows.append(ProbeRow(label: "    tab \(tab.tty)",
                                     detail: "\(lookup.directory ?? "unresolved") via \(lookup.method), selected \(tab.selected)"))
            }
        }
        for window in onScreen {
            rows.append(ProbeRow(label: "on-screen window \(window.id)",
                                 detail: "\(ScreenGeometry.describe(window.serverFrame)) on \(window.screenName ?? "unknown display"), \(window.inScope ? "on the destination display" : window.scopeReason)"))
        }

        let notes = [
            "the tab exposes a tty only, the directory comes from the foreground process group on that tty",
            "that group is the shell at an idle prompt and the running job otherwise, so a resolved directory is the tab's current directory and not proof of the shell's own directory",
            "resolution needs no extra permission for processes owned by the same user and no root access",
            "a resolved directory says nothing about whether the app's window ids match window server ids"
        ]
        let directories = tabs == 0 ? "no tabs reported" : "\(resolved) of \(tabs) tabs resolved to a directory"
        return ProbeResult(kind: kind,
                           ranAt: Date(),
                           summary: "\(directories). \(BrowserProbe.summary(report))",
                           succeeded: true,
                           rows: rows,
                           notes: notes,
                           evidence: BrowserProbe.evidence(report, scan: scan))
    }

    private static func parseTabs(_ field: String) -> [(tty: String, selected: String)] {
        field.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ",", maxSplits: 1).map(String.init)
            guard let tty = parts.first, !tty.isEmpty else { return nil }
            return (tty, parts.count > 1 ? parts[1] : "unknown")
        }
    }
}
