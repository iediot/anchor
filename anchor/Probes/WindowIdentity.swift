import AppKit

// how a window an app reports may be tied to a window server window
// geometry alone cannot separate the repeated layouts people keep across desktops
enum WindowIdentityBasis: Equatable {
    case geometryOnly(String)
    case windowServerNumber(pid: pid_t)

    var usesWindowNumber: Bool {
        if case .windowServerNumber = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .geometryOnly(let reason):
            return "geometry only, \(reason)"
        case .windowServerNumber(let pid):
            return "the window id the app reports, checked against process \(pid) and against geometry, with geometry alone as the fallback"
        }
    }
}

enum WindowIdentity {
    // these dictionaries bind the window id property to the cocoa uniqueID key on an appkit
    // window class, and that key returns the window number, which is the window server id
    // an app not listed here has never been checked and keeps geometry only
    static let windowNumberApps: Set<IntegrationKind> = [.safari, .terminal, .xcode]

    static func basis(for kind: IntegrationKind) -> WindowIdentityBasis {
        guard windowNumberApps.contains(kind) else {
            return .geometryOnly("anchor has not established that \(kind.displayName) reports the window server number as its window id")
        }
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: kind.bundleID)
            .filter { !$0.isTerminated }
        guard running.count == 1, let pid = running.first?.processIdentifier else {
            if running.isEmpty {
                return .geometryOnly("\(kind.displayName) is not running")
            }
            // an apple event reaches one process, and we cannot tell which one
            return .geometryOnly("\(running.count) instances of \(kind.displayName) are running, so the scripted process cannot be pinned")
        }
        return .windowServerNumber(pid: pid)
    }
}
