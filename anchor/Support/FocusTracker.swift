import AppKit

// the last application that was active before anchor took focus
// a menu click or a panel opening must never be allowed to choose the target display
@Observable
final class FocusTracker {
    static let shared = FocusTracker()

    private(set) var lastExternalPID: pid_t?

    // the observer lives as long as the app does so it is never torn down
    private var observer: NSObjectProtocol?

    private init() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ownPID
                else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.lastExternalPID = pid }
            }
    }
}
