import AppKit

// xcode exposes a document per window so the project path can be read per window
// the recent documents list is a separate candidate source and is not evidence of an open window
enum XcodeProbe {
    private static let script = """
    tell application "Xcode"
        set report to ""
        repeat with w in windows
            set wid to "?"
            set wname to "?"
            set docPath to ""
            try
                set wid to (id of w) as text
            end try
            try
                set wname to name of w
            end try
            try
                set d to document of w
                if d is not missing value then set docPath to POSIX path of (file of d)
            end try
            set report to report & wid & "|" & wname & "|" & docPath & linefeed
        end repeat
        return report
    end tell
    """

    static func run(scan: WindowScan) async -> ProbeResult {
        let outcome = await ScriptRunner.shared.run(script)
        guard case .text(let text) = outcome else {
            return ProbeResult(kind: .xcode, ranAt: Date(),
                               summary: outcome.failureDescription ?? "no result",
                               succeeded: false, rows: [], notes: [])
        }

        let serverIDs = Set(scan.windows.filter { $0.bundleID == IntegrationKind.xcode.bundleID }.map { UInt32($0.id) })
        var rows: [ProbeRow] = []
        var withPath = 0
        var windows = 0
        var idMatches = 0

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            windows += 1
            let matches = UInt32(parts[0]).map(serverIDs.contains) ?? false
            if matches { idMatches += 1 }
            if !parts[2].isEmpty { withPath += 1 }
            rows.append(ProbeRow(label: "window \(parts[0]) \(parts[1])",
                                 detail: "\(parts[2].isEmpty ? "no document path" : parts[2]), window server id match: \(matches ? "yes" : "no")"))
        }

        var notes = [
            "the path comes from the window's own document so it is per window rather than per app",
            "recent documents are stored as bookmark blobs and only prove past use, not a currently open project"
        ]
        if windows > 0 && withPath == 0 {
            notes.append("no window exposed a document path, project discovery would need another source")
        }
        let summary = windows == 0
            ? "no scriptable windows reported"
            : "\(withPath) of \(windows) windows exposed a document path, \(idMatches) matched a window server id"
        return ProbeResult(kind: .xcode, ranAt: Date(), summary: summary, succeeded: true, rows: rows, notes: notes)
    }
}
