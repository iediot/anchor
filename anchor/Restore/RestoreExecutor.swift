import AppKit

// the operations a restore is allowed to perform
// there is deliberately no close, quit, move-anything-else or write operation here
// phase 3 opens work and reports what happened, replacement belongs to a later phase
protocol RestoreExecutor {
    func requestAutomation(bundleID: String) async -> AutomationAccess
    func liveWindows(bundleID: String) -> [LiveWindow]
    func openBrowserWindow(_ request: BrowserOpenRequest) async -> ExecutionOutcome
    func openTerminalSession(_ request: TerminalOpenRequest) async -> ExecutionOutcome
    func openProject(_ request: ProjectOpenRequest) async -> ExecutionOutcome
    func observeNewWindow(bundleID: String, excluding: Set<CGWindowID>, timeout: TimeInterval) async -> WindowEvidence
    func awaitProjectWindow(_ request: ProjectOpenRequest, excluding: Set<CGWindowID>, timeout: TimeInterval) async -> WindowEvidence
    func place(windowID: CGWindowID, appKitFrame: CGRect) async -> PlacementOutcome
}

// how the window an operation produced was identified, never a stored runtime id
enum WindowEvidence: Equatable {
    case reportedByApp(CGWindowID)
    case observed(CGWindowID)
    case corroborated(CGWindowID, String)
    case reused(CGWindowID, String)
    case ambiguous([CGWindowID], String)
    case none(String)

    var windowID: CGWindowID? {
        switch self {
        case .reportedByApp(let id), .observed(let id), .reused(let id, _), .corroborated(let id, _): return id
        case .ambiguous, .none: return nil
        }
    }

    var label: String {
        switch self {
        case .reportedByApp(let id):
            return "the application named window \(id) as the one it created and the window server agrees it owns it"
        case .observed(let id):
            return "window \(id) is the one window that appeared for this application while the operation ran"
        case .corroborated(let id, let reason):
            return "window \(id) is the project window anchor waited for, \(reason)"
        case .reused(let id, let reason):
            return "window \(id) was already open, \(reason)"
        case .ambiguous(let ids, let reason):
            return "\(ids.count) windows could be the one, \(reason), so anchor left the layout alone"
        case .none(let reason):
            return "no new window was identified, \(reason)"
        }
    }
}

struct ItemOutcome: Equatable {
    enum State: String {
        case opened
        case skipped
        case failed
    }

    var state: State
    var detail: String?
}

struct ExecutionOutcome {
    var succeeded: Bool
    var summary: String
    var window: WindowEvidence
    var items: [String: ItemOutcome]

    static func failed(_ summary: String) -> ExecutionOutcome {
        ExecutionOutcome(succeeded: false, summary: summary, window: .none(summary), items: [:])
    }
}

enum PlacementOutcome: Equatable {
    case applied(requested: CGRect, actual: CGRect, adjustment: String?)
    case refused(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .applied(let requested, _, let adjustment):
            guard let adjustment else { return "placed at \(RectRecord(requested).summary)" }
            return adjustment
        case .refused(let reason): return "the window was not moved, \(reason)"
        case .unavailable(let reason): return "no layout was applied, \(reason)"
        }
    }

    var succeeded: Bool {
        if case .applied = self { return true }
        return false
    }
}
