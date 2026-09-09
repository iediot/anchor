import AppKit

// terminal has no working directory property so the tty is resolved through libproc instead
// no shell startup file is read or changed and no history or contents are collected
enum TerminalProbe {
    private static let terminalScript = """
    tell application "Terminal"
        set report to ""
        repeat with w in windows
            set wid to "?"
            try
                set wid to (id of w) as text
            end try
            repeat with t in tabs of w
                set ttyPath to "?"
                set isSelected to false
                try
                    set ttyPath to tty of t
                end try
                try
                    set isSelected to selected of t
                end try
                set report to report & wid & "|" & ttyPath & "|" & isSelected & linefeed
            end repeat
        end repeat
        return report
    end tell
    """

    private static let itermScript = """
    tell application "iTerm"
        set report to ""
        repeat with w in windows
            set wid to "?"
            try
                set wid to (id of w) as text
            end try
            repeat with t in tabs of w
                repeat with s in sessions of t
                    set ttyPath to "?"
                    try
                        set ttyPath to tty of s
                    end try
                    set report to report & wid & "|" & ttyPath & "|" & "session" & linefeed
                end repeat
            end repeat
        end repeat
        return report
    end tell
    """

    static func run(_ kind: IntegrationKind, scan: WindowScan) async -> ProbeResult {
        let script = kind == .terminal ? terminalScript : itermScript
        let outcome = await ScriptRunner.shared.run(script)
        guard case .text(let text) = outcome else {
            return ProbeResult(kind: kind, ranAt: Date(),
                               summary: outcome.failureDescription ?? "no result",
                               succeeded: false, rows: [], notes: [])
        }

        let serverIDs = Set(scan.windows.filter { $0.bundleID == kind.bundleID }.map { UInt32($0.id) })
        var rows: [ProbeRow] = []
        var resolved = 0
        var tabs = 0
        var idMatches = 0

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            tabs += 1
            let matches = UInt32(parts[0]).map(serverIDs.contains) ?? false
            if matches { idMatches += 1 }
            let tty = parts[1]
            let lookup = ProcessLookup.foregroundDirectory(onTTY: tty)
            if lookup.directory != nil { resolved += 1 }
            let directory = lookup.directory ?? "unresolved"
            rows.append(ProbeRow(label: "window \(parts[0]) \(tty)",
                                 detail: "\(directory) via \(lookup.method), selected \(parts[2]), window server id match: \(matches ? "yes" : "no")"))
        }

        let notes = [
            "the tab exposes a tty only, the directory comes from the foreground process group on that tty",
            "resolution needs no extra permission for processes owned by the same user and no root access",
            "a tab running a job in a different directory reports that job's directory, not the shell's"
        ]
        let summary = tabs == 0
            ? "no scriptable tabs reported"
            : "\(resolved) of \(tabs) tabs resolved to a directory, \(idMatches) windows matched a window server id"
        return ProbeResult(kind: kind, ranAt: Date(), summary: summary, succeeded: true, rows: rows, notes: notes)
    }
}
