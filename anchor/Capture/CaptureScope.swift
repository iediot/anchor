import AppKit

// which scoped window an adapter is allowed to attach content to
// an unresolved window keeps its geometry and loses its content, never the other way round
enum ScopeOutcome: Equatable {
    case resolved(scriptWindowID: Int)
    case unresolved(String)

    var scriptWindowID: Int? {
        if case .resolved(let id) = self { return id }
        return nil
    }

    var reason: String? {
        if case .unresolved(let reason) = self { return reason }
        return nil
    }
}

struct ScopeResolution: Equatable {
    let serverID: CGWindowID
    let outcome: ScopeOutcome
}

// the pairing rules already say which reported window is which on-screen window
// this turns that verdict into a decision about capture, for scoped windows only
enum CaptureScope {
    static func resolve(scripted: [ScriptedWindow],
                        matches: [WindowMatch],
                        scopedWindows: [InspectedWindow]) -> [ScopeResolution] {
        scopedWindows.map { window in
            ScopeResolution(serverID: window.id,
                            outcome: outcome(for: window.id, scripted: scripted, matches: matches))
        }
    }

    private static func outcome(for serverID: CGWindowID,
                                scripted: [ScriptedWindow],
                                matches: [WindowMatch]) -> ScopeOutcome {
        var sawUniqueWithoutID = false
        var contestedBy = 0
        var ambiguous = false
        var conflict: String?

        for (window, match) in zip(scripted, matches) {
            switch match {
            case .unique(let matched, _) where matched == serverID,
                 .identified(let matched, _) where matched == serverID:
                if let scriptID = window.scriptID { return .resolved(scriptWindowID: scriptID) }
                sawUniqueWithoutID = true
            case .identityConflict(let matched, let reason) where matched == serverID:
                conflict = reason
            case .contested(let matched, let competing) where matched == serverID:
                contestedBy = max(contestedBy, competing)
            case .ambiguousCandidates(let candidates) where candidates.contains(serverID):
                ambiguous = true
            default:
                continue
            }
        }

        if let conflict {
            return .unresolved("\(conflict), so no content was attached")
        }
        if contestedBy > 1 {
            return .unresolved("\(contestedBy) windows reported by the app fit this on-screen window, so none of them was chosen and no content was attached")
        }
        if ambiguous {
            return .unresolved("a window reported by the app fits this on-screen window and others equally well, so the association stays unresolved and no content was attached")
        }
        if sawUniqueWithoutID {
            return .unresolved("this window paired to a window the app reported without a usable id, so it could not be addressed")
        }
        return .unresolved("no window reported by the app fits this on-screen window, so no content was attached")
    }
}
