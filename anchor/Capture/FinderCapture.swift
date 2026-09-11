import AppKit

// the folder one finder window is showing
// accessibility already names it for some windows, so finder is scripted only for the
// windows it does not name
// finder reports its own bounds in a rectangle that does not line up with the window
// server's frame, so pairing on geometry alone leaves its windows unresolved. the folder
// name both sides report settles the ones geometry cannot, and a window that neither
// settles keeps no path at all rather than one taken from its title
enum FinderCapture {
    static let kind = IntegrationKind.finder

    struct Row {
        let scriptID: Int?
        let name: String
        let path: String?
        let bounds: CGRect?

        // finder answered something about this window rather than refusing every property
        var isUsable: Bool { !name.isEmpty || path != nil || bounds != nil }
    }

    static func capture(scan: WindowScan) async -> AdapterOutput {
        let scoped = scan.windows(ofBundleID: kind.bundleID).filter(\.inScope)
        var output = AdapterOutput()
        output.windowsAttempted = scoped.count
        guard !scoped.isEmpty else {
            output.outcome = "no finder window was on the destination display"
            return output
        }

        var pending: [InspectedWindow] = []
        for window in scoped {
            guard let path = folder(window.documentPath) else {
                pending.append(window)
                continue
            }
            output.resources[window.id] = resource(path: path,
                                                   source: "the window's own accessibility document",
                                                   scriptWindowID: nil)
            output.windowsCaptured += 1
        }

        guard !pending.isEmpty else {
            output.matchingBasis = "each window named its own folder, no apple event was sent"
            output.outcome = "\(output.windowsCaptured) finder windows named their folder through accessibility, finder was not scripted"
            return output
        }

        // the concrete class is asked first, because only a finder window is a folder
        // window with a target, and the general one is the fallback
        var rows: [Row] = []
        var asked = "finder windows"
        var failure: String?
        for selector in ["Finder window", "window"] {
            let outcome = await ScriptRunner.shared.runStructured(windowsScript(selector))
            guard case .value(let value) = outcome else {
                failure = outcome.failureDescription ?? "finder returned no result"
                break
            }
            failure = nil
            let parsed = parse(value)
            if parsed.contains(where: \.isUsable) {
                rows = parsed
                asked = selector
                break
            }
            // keep what the first ask produced, so the report says what finder did answer
            if rows.isEmpty {
                rows = parsed
                asked = selector
            }
        }
        if let description = failure {
            for window in pending {
                output.resources[window.id] = .empty(.finder,
                                                     ScriptedCapture.failureStatus(description),
                                                     description)
            }
            output.outcome = "finder did not answer, \(description)"
            output.issues.append(CaptureIssue(severity: .omission,
                                              scope: kind.displayName,
                                              message: "\(pending.count) finder windows kept their geometry only, \(description)"))
            return output
        }

        output.matchingBasis = "asked for \(asked). \(reported(rows))"
        for (window, pairing) in pair(pending, with: rows) {
            switch pairing {
            case .paired(let index, let basis):
                let row = rows[index]
                guard let path = folder(row.path) else {
                    output.resources[window.id] = unpaired(row,
                                                           reason: "finder paired this window \(basis) but reported no folder of its own for it")
                    continue
                }
                output.resources[window.id] = resource(path: path,
                                                       source: "the folder finder reports as this window's target, which is its active tab, paired \(basis)",
                                                       scriptWindowID: row.scriptID)
                output.windowsCaptured += 1
            case .unresolved(let reason):
                output.resources[window.id] = .empty(.finder, .windowNotResolved, reason)
            }
        }
        output.outcome = "\(output.windowsCaptured) of \(scoped.count) finder windows carry the folder they were showing"
        if output.windowsCaptured < scoped.count {
            output.issues.append(CaptureIssue(severity: .omission,
                                              scope: kind.displayName,
                                              message: "\(scoped.count - output.windowsCaptured) finder windows kept their geometry only, so reopening them opens a plain finder window"))
        }
        return output
    }

    enum Pairing {
        case paired(Int, String)
        case unresolved(String)
    }

    // geometry first, exactly as every other adapter pairs, then the folder name, then the
    // one to one case, and a row two windows both claim settles neither of them
    static func pair(_ windows: [InspectedWindow], with rows: [Row]) -> [(InspectedWindow, Pairing)] {
        var chosen: [Int?] = []
        var reasons: [String] = []
        let withFolder = rows.indices.filter { rows[$0].path != nil }
        for window in windows {
            let byGeometry = rows.indices.filter { index in
                guard let bounds = rows[index].bounds else { return false }
                return WindowCorrelation.compatible(bounds: bounds, frame: window.serverFrame) != nil
            }
            if byGeometry.count == 1 {
                chosen.append(byGeometry[0])
                reasons.append("on the rectangle finder reports")
                continue
            }
            let byName = rows.indices.filter { sameName(rows[$0].name, window.title) }
            if byName.count == 1 {
                chosen.append(byName[0])
                reasons.append("on the folder name finder and the window server both report")
                continue
            }
            // one window on the destination display, one window finder says is showing a
            // folder. there is nothing to choose between, so it is not a choice
            if windows.count == 1, withFolder.count == 1 {
                chosen.append(withFolder[0])
                reasons.append("as the only window finder says is showing a folder, and the only one on the destination display")
                continue
            }
            chosen.append(nil)
            if byGeometry.count > 1 || byName.count > 1 {
                reasons.append("more than one window finder reported fits this one, so none of them was chosen. \(reported(rows))")
            } else {
                reasons.append("no window finder reported sits where this one is or carries its name. \(reported(rows))")
            }
        }

        var claims: [Int: Int] = [:]
        for index in chosen.compactMap({ $0 }) { claims[index, default: 0] += 1 }

        return windows.enumerated().map { offset, window -> (InspectedWindow, Pairing) in
            guard let index = chosen[offset] else { return (window, .unresolved(reasons[offset])) }
            guard claims[index] == 1 else {
                return (window, .unresolved("more than one window on screen matched the same finder window, so none of them was chosen"))
            }
            return (window, .paired(index, reasons[offset]))
        }
    }

    static func sameName(_ reported: String, _ title: String?) -> Bool {
        guard let title else { return false }
        let left = reported.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.compare(right, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    // what finder answered, so a window that stays unresolved says why in its own record
    // names only, which a saved state already holds as window titles
    static func reported(_ rows: [Row]) -> String {
        guard !rows.isEmpty else { return "finder reported no windows" }
        let parts = rows.map { row in
            "\(row.name.isEmpty ? "unnamed" : row.name), \(row.bounds == nil ? "no rectangle" : "a rectangle"), \(row.path == nil ? "no folder" : "a folder")"
        }
        return "finder reported \(rows.count) windows: \(parts.joined(separator: "; "))"
    }

    // one pass, every window with what it is showing, nothing else about it
    // the windows are walked by index rather than with a repeat over a list, because
    // finder answers a one window request with the window itself rather than a list of
    // one, and a repeat over a single window walks the items inside it instead
    static func windowsScript(_ selector: String) -> String {
        """
    tell application "Finder"
        set pvOut to {}
        set pvCount to 0
        try
            set pvCount to (count of \(selector)s)
        end try
        repeat with pvIndex from 1 to pvCount
            set pvID to "?"
            set pvName to ""
            set pvURL to ""
            set pvLeft to "?"
            set pvTop to "?"
            set pvRight to "?"
            set pvBottom to "?"
            try
                set pvWin to \(selector) pvIndex
                try
                    set pvID to (id of pvWin) as text
                end try
                try
                    set pvName to (name of pvWin) as text
                end try
                try
                    set pvURL to (URL of (target of pvWin)) as text
                end try
                try
                    set pvRect to bounds of pvWin
                    set pvLeft to (item 1 of pvRect) as text
                    set pvTop to (item 2 of pvRect) as text
                    set pvRight to (item 3 of pvRect) as text
                    set pvBottom to (item 4 of pvRect) as text
                end try
            end try
            set end of pvOut to {pvID, pvName, pvURL, pvLeft, pvTop, pvRight, pvBottom}
        end repeat
        return pvOut
    end tell
    """
    }

    static func parse(_ value: ScriptValue) -> [Row] {
        value.items.map { item in
            let fields = item.strings
            func field(_ index: Int) -> String { fields[safe: index] ?? "" }
            return Row(scriptID: Int(field(0)),
                       name: field(1),
                       path: field(2).isEmpty ? nil : field(2),
                       bounds: rect(left: field(3), top: field(4), right: field(5), bottom: field(6)))
        }
    }

    private static func rect(left: String, top: String, right: String, bottom: String) -> CGRect? {
        guard let minX = Double(left), let minY = Double(top),
              let maxX = Double(right), let maxY = Double(bottom),
              maxX > minX, maxY > minY
        else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func resource(path: String, source: String, scriptWindowID: Int?) -> WindowResources {
        var resources = WindowResources.empty(.finder, .captured)
        resources.finder = FinderResource(scriptWindowID: scriptWindowID,
                                          path: path,
                                          pathSource: source,
                                          issue: nil)
        return resources
    }

    private static func unpaired(_ row: Row, reason: String) -> WindowResources {
        var resources = WindowResources.empty(.finder, .resourceNotIdentified, reason)
        resources.finder = FinderResource(scriptWindowID: row.scriptID,
                                          path: nil,
                                          pathSource: nil,
                                          issue: reason)
        return resources
    }

    // a file url or a plain path, anything else is not a folder anchor will reopen
    static func folder(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.isFileURL { return url.path }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return nil }
        return (raw as NSString).standardizingPath
    }
}
