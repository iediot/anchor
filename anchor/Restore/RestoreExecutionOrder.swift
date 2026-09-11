import Foundation

// quick things first
// the coordinator opens one window at a time and an ide is seconds away from being
// ready, so a browser window should not wait behind it
enum RestoreExecutionOrder {
    static let note = "anchor opens plain applications first, then browser windows, then terminals, then projects and ides, so a slow ide start cannot hold up the quick ones"

    enum Tier: Int, Comparable {
        // a plain open waits for nothing at all, so it never holds anything up
        case application
        case browser
        case terminal
        case project
        case other

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func tier(_ action: RestoreAction) -> Tier {
        switch action {
        case .openApplication: return .application
        case .openBrowserWindow: return .browser
        case .openTerminalSession: return .terminal
        case .openProject: return .project
        case .nothing: return .other
        }
    }

    // a group takes the tier of its quickest window, which is the only thing that decides
    // when the group starts
    static func tier(_ group: RestoreGroup) -> Tier {
        group.windows.map { tier($0.action) }.min() ?? .other
    }

    // stable, so two groups in the same tier keep the order they were given and the
    // windows inside a group are never reordered
    static func ordered(_ groups: [RestoreGroup]) -> [RestoreGroup] {
        groups.enumerated()
            .sorted { left, right in
                let lhs = tier(left.element)
                let rhs = tier(right.element)
                return lhs == rhs ? left.offset < right.offset : lhs < rhs
            }
            .map(\.element)
    }
}
