import AppKit

// the installed dictionary extends document with a text path property and also carries file
// both are read separately so a missing property, a missing value and a failed coercion stay distinct
enum XcodeProbe {
    private static let script = """
    tell application "Xcode"
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
            set docState to "no document read"
            set pathValue to ""
            set pathError to ""
            set fileValue to ""
            set fileError to ""
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
            set d to missing value
            try
                set d to document of w
                if d is missing value then
                    set docState to "window has no document"
                else
                    set docState to "document present"
                end if
            on error errText
                set docState to "reading document failed: " & errText
            end try
            if d is not missing value then
                try
                    set pathValue to (path of d) as text
                on error errText
                    set pathError to errText
                end try
                try
                    set fileValue to POSIX path of (file of d)
                on error errText
                    set fileError to errText
                end try
            end if
            set report to report & wid & "<|>" & l & "<|>" & t & "<|>" & r & "<|>" & b & "<|>" & vis & "<|>" & mini & "<|>" & idx & "<|>" & docState & "<|>" & pathValue & "<|>" & pathError & "<|>" & fileValue & "<|>" & fileError & linefeed
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

        var scripted: [ScriptedWindow] = []
        var stages: [[String]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: ScriptedWindow.fieldSeparator)
            guard fields.count >= ScriptedWindow.leadingFieldCount else { continue }
            scripted.append(ScriptedWindow.parse(fields))
            stages.append(Array(fields.dropFirst(ScriptedWindow.leadingFieldCount)))
        }

        let onScreen = scan.windows(ofBundleID: IntegrationKind.xcode.bundleID)
        let report = WindowCorrelation.correlate(scripted: scripted,
                                                 onScreen: onScreen,
                                                 inScopeCount: onScreen.filter(\.inScope).count,
                                                 identity: WindowIdentity.basis(for: .xcode))

        var rows: [ProbeRow] = []
        var resolvedPaths = 0
        for (index, window) in scripted.enumerated() {
            let stage = stages[index]
            let docState = stage[safe: 0] ?? "unknown"
            let pathValue = stage[safe: 1] ?? ""
            let pathError = stage[safe: 2] ?? ""
            let fileValue = stage[safe: 3] ?? ""
            let fileError = stage[safe: 4] ?? ""
            if !pathValue.isEmpty || !fileValue.isEmpty { resolvedPaths += 1 }

            rows.append(ProbeRow(label: "reported window \(index + 1)", detail: window.stateDescription))
            rows.append(ProbeRow(label: "    pairing",
                                 detail: WindowCorrelation.describe(report.matches[index])))
            rows.append(ProbeRow(label: "    document", detail: docState))
            rows.append(ProbeRow(label: "    path property", detail: describe(value: pathValue, error: pathError, docState: docState)))
            rows.append(ProbeRow(label: "    file property", detail: describe(value: fileValue, error: fileError, docState: docState)))
            // an unresolved pairing may not be given a window, otherwise a later capture
            // or close would act on the wrong one
            if case .unique(let serverID, _) = report.matches[index],
               let matched = onScreen.first(where: { $0.id == serverID }) {
                rows.append(ProbeRow(label: "    accessibility document",
                                     detail: matched.documentPath ?? "no accessibility document attribute, or accessibility is not granted"))
            } else {
                rows.append(ProbeRow(label: "    accessibility document",
                                     detail: "not read, this reported window is not paired to a single on-screen window"))
            }
        }
        for window in onScreen {
            rows.append(ProbeRow(label: "on-screen window \(window.id)",
                                 detail: "\(ScreenGeometry.describe(window.serverFrame)) on \(window.screenName ?? "unknown display"), accessibility document \(window.documentPath ?? "none"), \(window.inScope ? "on the destination display" : window.scopeReason)"))
        }

        var notes = [
            "the installed dictionary extends document with a text path property, so path and file are read as two separate stages",
            "an empty value with no error means the property exists and had no value, an error means the read or the coercion failed",
            "the accessibility document attribute is an independent per-window source that needs no apple event",
            "recent documents are bookmark blobs proving past use only and are never reported as an open project",
            "a path found here is resource discovery for that reported window, it becomes a scoped window only once the pairing resolves"
        ]
        if resolvedPaths == 0 && !scripted.isEmpty {
            notes.append("no window yielded a path by any route, so project discovery for this xcode version is unresolved rather than unsupported")
        }
        let summary = "\(resolvedPaths) of \(scripted.count) reported windows yielded a project path. \(BrowserProbe.summary(report))"
        return ProbeResult(kind: .xcode,
                           ranAt: Date(),
                           summary: summary,
                           succeeded: true,
                           rows: rows,
                           notes: notes,
                           evidence: BrowserProbe.evidence(report, scan: scan))
    }

    private static func describe(value: String, error: String, docState: String) -> String {
        if !error.isEmpty { return "failed: \(error)" }
        if !value.isEmpty { return value }
        if docState != "document present" { return "not read, \(docState)" }
        return "no value, the property exists but was empty"
    }
}
