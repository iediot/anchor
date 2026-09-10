import AppKit

// what an application says about one of its own windows, before any claim that it
// is the same object as a window server window
struct ScriptedWindow {
    let scriptID: Int?
    let bounds: CGRect?
    let visible: Bool?
    let miniaturized: Bool?
    let index: Int?
}

enum WindowMatch: Equatable {
    case unique(CGWindowID, topEdgeDelta: CGFloat)
    case identified(CGWindowID, topEdgeDelta: CGFloat)
    case identityConflict(CGWindowID, String)
    case ambiguousCandidates([CGWindowID])
    case contested(CGWindowID, competingReportedWindows: Int)
    case excludedByReportedState(String)
    case unmatched

    // paired on geometry alone, which is what may be read back as id evidence
    var isUnique: Bool { if case .unique = self { return true }; return false }

    // paired on the id the app reported, after checking process and geometry
    var isIdentified: Bool { if case .identified = self { return true }; return false }

    var matchedWindow: CGWindowID? {
        switch self {
        case .unique(let id, _), .identified(let id, _): return id
        default: return nil
        }
    }

    // an unresolved pairing must not be handed downstream as a window to capture or close
    var resolvesScope: Bool { isUnique || isIdentified }
}

// the relationship between an app's own window ids and window server ids
// only a pairing both endpoints agree on can settle it, a set overlap on its own cannot
enum IDRelationship: Equatable {
    case notApplicable
    case noScriptedWindows
    case noCandidates
    case noScriptedIDs
    case unresolvedNoUniquePair
    case observedEqual(pairs: Int)
    case observedDifferent(pairs: Int)
    case inconsistent(equal: Int, different: Int)

    var label: String {
        switch self {
        case .notApplicable:
            return "this app has no scripting dictionary, so there are no automation ids to relate"
        case .noScriptedWindows:
            return "the app reported no windows, nothing to compare"
        case .noCandidates:
            return "no window of this app is on the current desktop of any display, so there was nothing to compare against and the id relationship stays unresolved"
        case .noScriptedIDs:
            return "the app reported windows but no usable id, id relationship unresolved"
        case .unresolvedNoUniquePair:
            return "no reported window paired to exactly one on-screen window that no other reported window also claimed, so the id relationship stays unresolved"
        case .observedEqual(let pairs):
            return "on \(pairs) window\(pairs == 1 ? "" : "s") paired in this run the automation id equalled the window server id, an observation about those windows and not a guarantee for the app"
        case .observedDifferent(let pairs):
            return "on \(pairs) window\(pairs == 1 ? "" : "s") paired in this run the automation id differed from the window server id, an observation about those windows and not a guarantee for the app"
        case .inconsistent(let equal, let different):
            return "paired windows disagree, \(equal) equal and \(different) different, treat ids as unreliable"
        }
    }
}

struct CorrelationReport {
    let relationship: IDRelationship
    let matches: [WindowMatch]
    let basis: WindowIdentityBasis
    let scriptedCount: Int
    let onScreenCount: Int
    let inScopeCount: Int

    var uniqueCount: Int { matches.filter(\.isUnique).count }
    var identifiedCount: Int { matches.filter(\.isIdentified).count }
    var resolvedCount: Int { matches.filter(\.resolvesScope).count }
    var identityConflictCount: Int {
        matches.filter { if case .identityConflict = $0 { return true }; return false }.count
    }
    var ambiguousCount: Int {
        matches.filter { if case .ambiguousCandidates = $0 { return true }; return false }.count
    }
    var contestedCount: Int {
        matches.filter { if case .contested = $0 { return true }; return false }.count
    }
    var excludedCount: Int {
        matches.filter { if case .excludedByReportedState = $0 { return true }; return false }.count
    }
    var unmatchedCount: Int { matches.filter { $0 == .unmatched }.count }
}

enum WindowCorrelation {
    // three edges are held tight and only the top edge may drift, because an app may
    // report its content rect while the window server reports the frame around it
    // the drift can go either way depending on which rect the app chose
    // the tolerance stays small on purpose, a wide one would merge the tiled layouts
    // people repeat across desktops and turn a real ambiguity into a false pairing
    static let edgeTolerance: CGFloat = 4
    static let titleBarAllowance: CGFloat = 64

    // geometry only, ids are never consulted here
    // using an id to pick a pairing and then reading that pairing back as evidence
    // about ids would be circular
    static func candidates(for scripted: ScriptedWindow, among onScreen: [InspectedWindow]) -> [(CGWindowID, CGFloat)] {
        guard let bounds = scripted.bounds else { return [] }
        return onScreen.compactMap { candidate in
            compatible(bounds: bounds, frame: candidate.serverFrame).map { (candidate.id, $0) }
        }
    }

    // returns the top edge difference when the two rects describe the same window
    static func compatible(bounds: CGRect, frame: CGRect) -> CGFloat? {
        guard abs(frame.minX - bounds.minX) <= edgeTolerance,
              abs(frame.maxX - bounds.maxX) <= edgeTolerance,
              abs(frame.maxY - bounds.maxY) <= edgeTolerance
        else { return nil }
        let topDelta = frame.minY - bounds.minY
        guard abs(topDelta) <= titleBarAllowance else { return nil }
        return topDelta
    }

    // a window the app calls minimized or not visible cannot be one of the on-screen
    // windows, the converse does not hold so a visible window still has to pair on geometry
    static func exclusionReason(_ scripted: ScriptedWindow) -> String? {
        if scripted.miniaturized == true { return "the app reports this window as minimized" }
        if scripted.visible == false { return "the app reports this window as not visible" }
        return nil
    }

    // pairings are resolved over the whole reported set at once
    // a pair counts as unique only when the reported window has one candidate and
    // no other reported window claims that same on-screen window
    // a skipped entry is already settled elsewhere, it neither takes nor contests a window
    static func geometryMatches(scripted: [ScriptedWindow],
                                onScreen: [InspectedWindow],
                                skipping: Set<Int> = []) -> [WindowMatch] {
        var perWindow: [[(CGWindowID, CGFloat)]] = []
        var excluded: [String?] = []
        for (index, window) in scripted.enumerated() {
            let reason = exclusionReason(window)
            excluded.append(reason)
            let eligible = reason == nil && !skipping.contains(index)
            perWindow.append(eligible ? candidates(for: window, among: onScreen) : [])
        }

        var claimants: [CGWindowID: Int] = [:]
        for hits in perWindow where hits.count == 1 {
            claimants[hits[0].0, default: 0] += 1
        }

        var matches: [WindowMatch] = []
        for (index, hits) in perWindow.enumerated() {
            if let reason = excluded[index] {
                matches.append(.excludedByReportedState(reason))
                continue
            }
            if hits.isEmpty {
                matches.append(.unmatched)
                continue
            }
            if hits.count > 1 {
                matches.append(.ambiguousCandidates(hits.map(\.0)))
                continue
            }
            let (serverID, delta) = hits[0]
            let competing = claimants[serverID] ?? 0
            if competing > 1 {
                matches.append(.contested(serverID, competingReportedWindows: competing))
            } else {
                matches.append(.unique(serverID, topEdgeDelta: delta))
            }
        }
        return matches
    }

    // the id an app reports is trusted only after the named window is checked to belong to
    // the scripted process and to describe the same rectangle
    // anything it cannot settle falls back to the geometry rules unchanged
    static func identityMatches(scripted: [ScriptedWindow],
                                onScreen: [InspectedWindow],
                                pid: pid_t) -> [WindowMatch] {
        var eligible: [Bool] = []
        var reportedIDCounts: [Int: Int] = [:]
        for window in scripted {
            let ok = exclusionReason(window) == nil
            eligible.append(ok)
            if ok, let id = window.scriptID { reportedIDCounts[id, default: 0] += 1 }
        }

        let byServerID = Dictionary(onScreen.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var settled: [Int: WindowMatch] = [:]
        var claimed: Set<CGWindowID> = []

        for (index, window) in scripted.enumerated() {
            guard eligible[index], let scriptID = window.scriptID else { continue }
            // two reported windows carrying one id cannot identify anything
            guard reportedIDCounts[scriptID] == 1 else { continue }
            guard scriptID > 0, scriptID <= Int(CGWindowID.max) else { continue }
            guard let candidate = byServerID[CGWindowID(scriptID)] else { continue }
            guard candidate.pid == pid else {
                settled[index] = .identityConflict(candidate.id,
                                                   "the reported id names window server window \(candidate.id), which belongs to process \(candidate.pid) rather than the scripted process \(pid), so it was refused")
                continue
            }
            guard let bounds = window.bounds else {
                settled[index] = .identityConflict(candidate.id,
                                                   "the reported id names window server window \(candidate.id) but the app reported no bounds, so nothing corroborates it")
                continue
            }
            guard let delta = compatible(bounds: bounds, frame: candidate.serverFrame) else {
                settled[index] = .identityConflict(candidate.id,
                                                   "the reported id names window server window \(candidate.id) but the two geometries disagree, so it was refused")
                continue
            }
            settled[index] = .identified(candidate.id, topEdgeDelta: delta)
            claimed.insert(candidate.id)
        }

        // one to one is kept by taking the identified windows out of the fallback pool
        let remaining = onScreen.filter { !claimed.contains($0.id) }
        let fallback = geometryMatches(scripted: scripted,
                                       onScreen: remaining,
                                       skipping: Set(settled.keys))
        return scripted.indices.map { settled[$0] ?? fallback[$0] }
    }

    // the operative matches may use the reported id, the id relationship reported alongside
    // them never does, it is judged only on windows paired by geometry alone
    static func correlate(scripted: [ScriptedWindow],
                          onScreen: [InspectedWindow],
                          inScopeCount: Int,
                          identity: WindowIdentityBasis = .geometryOnly("no identity basis was supplied")) -> CorrelationReport {
        let geometry = geometryMatches(scripted: scripted, onScreen: onScreen)
        let operative: [WindowMatch]
        if case .windowServerNumber(let pid) = identity {
            operative = identityMatches(scripted: scripted, onScreen: onScreen, pid: pid)
        } else {
            operative = geometry
        }
        return CorrelationReport(relationship: relationship(scripted: scripted, matches: geometry, onScreen: onScreen),
                                 matches: operative,
                                 basis: identity,
                                 scriptedCount: scripted.count,
                                 onScreenCount: onScreen.count,
                                 inScopeCount: inScopeCount)
    }

    // only a resolved pairing may contribute, a contested or ambiguous one carries no id evidence
    static func relationship(scripted: [ScriptedWindow],
                             matches: [WindowMatch],
                             onScreen: [InspectedWindow]) -> IDRelationship {
        if scripted.isEmpty { return .noScriptedWindows }
        if onScreen.isEmpty { return .noCandidates }
        if scripted.allSatisfy({ $0.scriptID == nil }) { return .noScriptedIDs }

        var equal = 0
        var different = 0
        for (window, match) in zip(scripted, matches) {
            guard case .unique(let serverID, _) = match, let scriptID = window.scriptID else { continue }
            if scriptID == Int(serverID) { equal += 1 } else { different += 1 }
        }
        if equal > 0 && different > 0 { return .inconsistent(equal: equal, different: different) }
        if equal > 0 { return .observedEqual(pairs: equal) }
        if different > 0 { return .observedDifferent(pairs: different) }
        return .unresolvedNoUniquePair
    }

    static func describe(_ match: WindowMatch) -> String {
        switch match {
        case .unique(let id, let delta):
            return "paired to window server id \(id) on geometry alone, top edge differs by \(Int(delta))pt"
        case .identified(let id, let delta):
            return "paired to window server id \(id) by the id the app reported, confirmed to belong to the scripted process and to the same rectangle, top edge differs by \(Int(delta))pt"
        case .identityConflict(_, let reason):
            return "not matched, \(reason), scope stays unresolved"
        case .ambiguousCandidates(let ids):
            return "ambiguous, \(ids.count) on-screen windows fit this geometry (\(ids.map(String.init).joined(separator: ", "))), none chosen and scope stays unresolved"
        case .contested(let id, let competing):
            return "contested, \(competing) reported windows all fit on-screen window \(id), none chosen and scope stays unresolved"
        case .excludedByReportedState(let reason):
            return "not matched, \(reason), so it cannot be one of the on-screen windows"
        case .unmatched:
            return "no on-screen window fits this geometry, scope stays unresolved"
        }
    }
}

extension ScriptedWindow {
    // every probe script emits the same leading fields so one parser covers them all
    static let fieldSeparator = "<|>"
    static let leadingFieldCount = 8

    static func parse(_ fields: [String]) -> ScriptedWindow {
        ScriptedWindow(scriptID: Int(fields[safe: 0] ?? ""),
                       bounds: rect(fields),
                       visible: flag(fields[safe: 5]),
                       miniaturized: flag(fields[safe: 6]),
                       index: Int(fields[safe: 7] ?? ""))
    }

    private static func rect(_ fields: [String]) -> CGRect? {
        guard let left = Double(fields[safe: 1] ?? ""),
              let top = Double(fields[safe: 2] ?? ""),
              let right = Double(fields[safe: 3] ?? ""),
              let bottom = Double(fields[safe: 4] ?? ""),
              right > left, bottom > top
        else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func flag(_ value: String?) -> Bool? {
        guard let value else { return nil }
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
    }

    var stateDescription: String {
        var parts: [String] = []
        parts.append("id \(scriptID.map(String.init) ?? "none")")
        parts.append(bounds.map { "bounds \(ScreenGeometry.describe($0))" } ?? "bounds unavailable")
        if let visible { parts.append(visible ? "visible" : "not visible") }
        if let miniaturized { parts.append(miniaturized ? "minimized" : "not minimized") }
        if let index { parts.append("front to back index \(index)") }
        return parts.joined(separator: ", ")
    }
}

extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
