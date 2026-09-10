import AppKit

struct RecentProjectEntry {
    let path: String
    let projectName: String?
    let frameTitle: String?
    let openedAt: Date?
}

// jetbrains ides ship no scripting dictionary so windows are matched by title
// the recent projects file is read only and is a candidate list, never proof a project is open
enum JetBrainsProbe {
    private static let configRoot = ("~/Library/Application Support/JetBrains" as NSString).expandingTildeInPath

    static func run(_ kind: IntegrationKind, scan: WindowScan) async -> ProbeResult {
        let prefix = kind == .pycharm ? "PyCharm" : "CLion"
        guard let stateFile = newestStateFile(prefix: prefix) else {
            return ProbeResult(kind: kind, ranAt: Date(),
                               summary: "no recentProjects.xml found under the jetbrains config directory",
                               succeeded: false, rows: [], notes: [])
        }

        let entries = parse(stateFile)
        let onScreen = scan.windows(ofBundleID: kind.bundleID)
        let inScope = onScreen.filter(\.inScope)
        var rows: [ProbeRow] = [ProbeRow(label: "state file", detail: stateFile)]
        var resolved = 0
        var ambiguous = 0
        var untitled = 0

        for window in onScreen {
            let placement = window.inScope ? "on the destination display" : window.scopeReason
            guard let title = window.title else {
                untitled += 1
                rows.append(ProbeRow(label: "window \(window.id)",
                                     detail: "no title available, accessibility is needed for a title, \(placement)"))
                continue
            }
            let hits = candidates(title: title, among: entries)
            let verdict: String
            switch hits.count {
            case 0: verdict = "no recent project matched the leading title segment"
            case 1: resolved += 1; verdict = "\(hits[0].path) matched on the leading title segment"
            default:
                ambiguous += 1
                verdict = "ambiguous, \(hits.count) recent projects share this name (\(hits.map(\.path).joined(separator: ", "))), none chosen"
            }
            rows.append(ProbeRow(label: "window \(window.id) \(title)", detail: "\(verdict), \(placement)"))
        }
        for entry in entries.prefix(8) {
            rows.append(ProbeRow(label: "recent candidate",
                                 detail: "\(entry.path) name \(entry.projectName ?? "unknown") last frame title \(entry.frameTitle ?? "none")"))
        }

        var notes = [
            "the window title's leading segment is the project name, the trailing segment is the open file",
            "the state file is written when the ide saves state so it lags a live window and can be stale",
            "the file layout is version specific, this run read the newest matching config directory",
            "a matched recent project is a candidate confirmed by a live window title, an unmatched one is not evidence of anything",
            "no recent project was opened and nothing was written back"
        ]
        if onScreen.isEmpty {
            notes.append("no window of this app is on the current desktop of any display, so nothing could be matched and this is not evidence that matching fails")
        }
        if untitled > 0 {
            notes.append("\(untitled) windows had no readable title, which blocks matching rather than disproving it")
        }

        let summary = onScreen.isEmpty
            ? "no windows on the current desktop, read \(entries.count) recent project candidates, nothing matched or refuted"
            : "\(resolved) of \(onScreen.count) on-screen windows matched exactly one recent project, \(ambiguous) ambiguous, \(untitled) untitled"
        let evidence = ProbeEvidence(scanCapturedAt: scan.capturedAt,
                                     scriptedWindows: 0,
                                     onScreenWindows: onScreen.count,
                                     inScopeWindows: inScope.count,
                                     uniquePairs: resolved,
                                     identifiedPairs: 0,
                                     identityConflicts: 0,
                                     ambiguousPairs: ambiguous,
                                     contestedPairs: 0,
                                     excludedByReportedState: 0,
                                     unmatchedScriptedWindows: onScreen.count - resolved - ambiguous,
                                     matchingBasis: "window title matched against the ide's recent projects file",
                                     relationship: .notApplicable)
        return ProbeResult(kind: kind, ranAt: Date(), summary: summary,
                           succeeded: true, rows: rows, notes: notes, evidence: evidence)
    }

    static func newestStateFile(prefix: String) -> String? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: configRoot) else { return nil }
        let candidates = names
            .filter { $0.hasPrefix(prefix) }
            .map { "\(configRoot)/\($0)/options/recentProjects.xml" }
            .filter { manager.fileExists(atPath: $0) }
        return candidates.sorted().last
    }

    static func parse(_ path: String) -> [RecentProjectEntry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let reader = RecentProjectsReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries.sorted { ($0.openedAt ?? .distantPast) > ($1.openedAt ?? .distantPast) }
    }

    // every candidate is returned so two projects with the same name stay ambiguous
    // rather than silently resolving to whichever was listed first
    static func candidates(title: String, among entries: [RecentProjectEntry]) -> [RecentProjectEntry] {
        let head = leadingSegment(title)
        guard !head.isEmpty else { return [] }
        return entries.filter { entry in
            if let name = entry.projectName, name.caseInsensitiveCompare(head) == .orderedSame { return true }
            if let frame = entry.frameTitle, leadingSegment(frame).caseInsensitiveCompare(head) == .orderedSame { return true }
            return (entry.path as NSString).lastPathComponent.caseInsensitiveCompare(head) == .orderedSame
        }
    }

    // titles look like project then a dash then the open file
    static func leadingSegment(_ title: String) -> String {
        for separator in [" \u{2013} ", " \u{2014} ", " - "] where title.contains(separator) {
            return String(title.components(separatedBy: separator)[0]).trimmingCharacters(in: .whitespaces)
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

private final class RecentProjectsReader: NSObject, XMLParserDelegate {
    var entries: [RecentProjectEntry] = []

    private var currentKey: String?
    private var currentFrameTitle: String?
    private var currentName: String?
    private var currentOpened: Date?

    private var home: String { NSHomeDirectory() }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "entry":
            currentKey = attributes["key"]
            currentFrameTitle = nil
            currentName = nil
            currentOpened = nil
        case "RecentProjectMetaInfo":
            currentFrameTitle = attributes["frameTitle"]
        case "option":
            guard let name = attributes["name"], let value = attributes["value"] else { return }
            if name == "customProjectName" { currentName = value }
            if name == "projectOpenTimestamp", let millis = Double(value) {
                currentOpened = Date(timeIntervalSince1970: millis / 1000)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        guard elementName == "entry", let key = currentKey else { return }
        let path = key.replacingOccurrences(of: "$USER_HOME$", with: home)
        // light edit and other pseudo entries are not real project directories
        if !path.hasPrefix("/") {
            currentKey = nil
            return
        }
        entries.append(RecentProjectEntry(path: path,
                                          projectName: currentName,
                                          frameTitle: currentFrameTitle,
                                          openedAt: currentOpened))
        currentKey = nil
    }
}
