import AppKit

// one live window on the destination that a replacement intends to close
// it is a record of what was seen at preflight, never an authority to close whatever
// carries that number later
struct OutgoingWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let title: String?
    let appKitFrame: CGRect
    let serverFrame: CGRect
}

// whether this build has a supported way to close one window on its own
// quitting an application to close one of its windows is not a way
enum CloseSupport: Equatable {
    case supported(String)
    case unsupported(String)
    case unknown(String)

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .supported(let reason): return reason
        case .unsupported(let reason): return "anchor has no supported way to close this window, \(reason)"
        case .unknown(let reason): return "anchor cannot tell whether this window closes on its own, \(reason)"
        }
    }
}

enum CloseRequest: Equatable {
    case requested(String)
    case refused(String)
}

// what the destination holds right now, read only
struct OutgoingScan: Equatable {
    let destination: DestinationDisplay
    let windows: [OutgoingWindow]
    let accessibilityGranted: Bool
}

struct OutgoingEntry: Identifiable, Equatable {
    let window: OutgoingWindow
    let support: CloseSupport

    var id: CGWindowID { window.id }
}

struct ReplacementPreflight: Equatable {
    let destination: DestinationDisplay
    let entries: [OutgoingEntry]
    let accessibilityGranted: Bool
    let notes: [PlanNote]
    let builtAt: Date

    func included(excluding excluded: Set<CGWindowID>) -> [OutgoingEntry] {
        entries.filter { !excluded.contains($0.id) }
    }

    // an included window anchor is not sure it can close stops the whole operation
    // until the user leaves it out on purpose
    func blocking(excluding excluded: Set<CGWindowID>) -> [OutgoingEntry] {
        included(excluding: excluded).filter { !$0.support.isSupported }
    }
}

// everything a replacement is allowed to do to the machine
// there is deliberately no quit, terminate, signal or force operation here
@MainActor
protocol ReplacementServices {
    func outgoingScope() -> OutgoingScan
    func closeSupport(for window: OutgoingWindow) -> CloseSupport
    func requestClose(_ window: OutgoingWindow) async -> CloseRequest
    func isRunning(pid: pid_t) -> Bool
    func captureOutgoing() async -> CaptureCoordinator.Outcome
}

enum ReplacementScope {
    // the inspector has already dropped minimized windows, other desktops, other displays,
    // desktop furniture and anchor's own panels, so scope is exactly what it kept
    static func outgoing(from scan: WindowScan) -> [OutgoingWindow] {
        scan.inScope.map { window in
            OutgoingWindow(id: window.id,
                           pid: window.pid,
                           bundleID: window.bundleID,
                           appName: window.ownerName,
                           title: window.title,
                           appKitFrame: window.appKitFrame,
                           serverFrame: window.serverFrame)
        }
    }

    static func notes(entries: [OutgoingEntry],
                      accessibilityGranted: Bool,
                      incoming: RestorePlan) -> [PlanNote] {
        var notes: [PlanNote] = []
        if !accessibilityGranted {
            notes.append(PlanNote(.blocker, "accessibility is not granted, so anchor cannot close any window and cannot replace anything"))
        }
        notes.append(PlanNote(.note, "replacing closes the windows listed below on \(incoming.destination.name) only. windows on another display or another desktop are never touched, and no application is quit"))
        notes.append(PlanNote(.limitation, "a saved state records where things were, not what was in them. it does not save unsaved documents, and it does not save anything a terminal was running"))
        let unsupported = entries.filter { !$0.support.isSupported }
        if !unsupported.isEmpty {
            notes.append(PlanNote(.limitation, "\(unsupported.count) of these windows cannot be closed one at a time by anchor. leave them out to continue, and they stay open"))
        }
        // the incoming half of the preview carries the same warning from the planner
        if entries.contains(where: { KnownIssues.affectsPyCharm(bundleID: $0.window.bundleID) }),
           !incoming.notes.contains(where: { $0.text == KnownIssues.pycharm }) {
            notes.append(PlanNote(.limitation, KnownIssues.pycharm))
        }
        return notes
    }
}
