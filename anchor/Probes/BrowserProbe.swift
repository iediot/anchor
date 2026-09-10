import AppKit

// asks the browser about its own windows and geometry only
// no url and no tab title is read, the browser persistence policy is still open
enum BrowserProbe {
    // every scratch variable carries a prefix that is not dictionary terminology
    // a bare name like tabs reads as an application object and the tell block fails
    private static func source(_ appName: String, tabCount: String, current: String) -> String {
        """
        tell application "\(appName)"
            set pvReport to ""
            repeat with pvWindow in windows
                set pvID to "?"
                set pvLeft to "?"
                set pvTop to "?"
                set pvRight to "?"
                set pvBottom to "?"
                set pvVisible to "?"
                set pvMinimized to "?"
                set pvIndex to "?"
                set pvTabCount to "?"
                set pvSelectedTab to "?"
                try
                    set pvID to (id of pvWindow) as text
                end try
                try
                    set pvRect to bounds of pvWindow
                    set pvLeft to (item 1 of pvRect) as text
                    set pvTop to (item 2 of pvRect) as text
                    set pvRight to (item 3 of pvRect) as text
                    set pvBottom to (item 4 of pvRect) as text
                end try
                try
                    set pvVisible to (visible of pvWindow) as text
                end try
                try
                    set pvMinimized to (miniaturized of pvWindow) as text
                end try
                try
                    set pvIndex to (index of pvWindow) as text
                end try
                try
                    set pvTabCount to (\(tabCount)) as text
                end try
                try
                    set pvSelectedTab to (\(current)) as text
                end try
                set pvReport to pvReport & pvID & "<|>" & pvLeft & "<|>" & pvTop & "<|>" & pvRight & "<|>" & pvBottom & "<|>" & pvVisible & "<|>" & pvMinimized & "<|>" & pvIndex & "<|>" & pvTabCount & "<|>" & pvSelectedTab & linefeed
            end repeat
            return pvReport
        end tell
        """
    }

    private static func script(for kind: IntegrationKind) -> String {
        kind == .safari
            ? source("Safari", tabCount: "count of tabs of pvWindow", current: "index of current tab of pvWindow")
            : source("Google Chrome", tabCount: "count of tabs of pvWindow", current: "active tab index of pvWindow")
    }

    static func run(_ kind: IntegrationKind, scan: WindowScan) async -> ProbeResult {
        let outcome = await ScriptRunner.shared.run(script(for: kind))
        guard case .text(let text) = outcome else {
            return ProbeResult(kind: kind, ranAt: Date(),
                               summary: outcome.failureDescription ?? "no result",
                               succeeded: false, rows: [], notes: [])
        }

        var scripted: [ScriptedWindow] = []
        var tabFields: [(String, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: ScriptedWindow.fieldSeparator)
            guard fields.count >= ScriptedWindow.leadingFieldCount else { continue }
            scripted.append(ScriptedWindow.parse(fields))
            tabFields.append((fields[safe: 8] ?? "?", fields[safe: 9] ?? "?"))
        }

        let onScreen = scan.windows(ofBundleID: kind.bundleID)
        let report = WindowCorrelation.correlate(scripted: scripted,
                                                 onScreen: onScreen,
                                                 inScopeCount: onScreen.filter(\.inScope).count,
                                                 identity: WindowIdentity.basis(for: kind))

        var rows: [ProbeRow] = []
        for (index, window) in scripted.enumerated() {
            let tabs = tabFields[index]
            rows.append(ProbeRow(label: "reported window \(index + 1)",
                                 detail: "\(window.stateDescription), \(tabs.0) tabs, selected tab index \(tabs.1)"))
            rows.append(ProbeRow(label: "    pairing",
                                 detail: WindowCorrelation.describe(report.matches[index])))
        }
        for window in onScreen {
            rows.append(ProbeRow(label: "on-screen window \(window.id)",
                                 detail: "\(ScreenGeometry.describe(window.serverFrame)) on \(window.screenName ?? "unknown display"), \(window.inScope ? "on the destination display" : window.scopeReason)"))
        }

        let notes = [
            "tab urls and titles were deliberately not read, browser persistence policy is still open",
            "tab counts prove tabs are addressable per window, they say nothing about window identity",
            "geometry pairing compares the app's reported bounds to window server bounds, the top edge is allowed to differ because the two may describe different rects",
            "a window the app calls minimized or not visible is excluded from pairing, a window it calls visible still has to pair on geometry because visibility is not proof of being on the active desktop"
        ]
        return ProbeResult(kind: kind,
                           ranAt: Date(),
                           summary: summary(report),
                           succeeded: true,
                           rows: rows,
                           notes: notes,
                           evidence: evidence(report, scan: scan))
    }

    static func summary(_ report: CorrelationReport) -> String {
        "\(report.scriptedCount) windows reported, \(report.onScreenCount) on screen, \(report.resolvedCount) resolved (\(report.identifiedCount) by reported id), \(report.ambiguousCount) ambiguous, \(report.contestedCount) contested. matching basis: \(report.basis.label)"
    }

    static func evidence(_ report: CorrelationReport, scan: WindowScan) -> ProbeEvidence {
        ProbeEvidence(scanCapturedAt: scan.capturedAt,
                      scriptedWindows: report.scriptedCount,
                      onScreenWindows: report.onScreenCount,
                      inScopeWindows: report.inScopeCount,
                      uniquePairs: report.uniqueCount,
                      identifiedPairs: report.identifiedCount,
                      identityConflicts: report.identityConflictCount,
                      ambiguousPairs: report.ambiguousCount,
                      contestedPairs: report.contestedCount,
                      excludedByReportedState: report.excludedCount,
                      unmatchedScriptedWindows: report.unmatchedCount,
                      matchingBasis: report.basis.label,
                      relationship: report.relationship)
    }
}
