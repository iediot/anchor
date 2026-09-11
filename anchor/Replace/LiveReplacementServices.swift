import AppKit
import ApplicationServices

// the real machine for a replacement
// closing is a press of the window's own close button, so the application keeps its
// unsaved document and busy terminal prompts and anchor never answers one
@MainActor
final class LiveReplacementServices: ReplacementServices {
    let store: SnapshotStore?
    let includeBrowserTabs: Bool

    // the display the first scan chose, kept for the rest of the operation so closing a
    // window and handing focus to another application cannot move the target
    private var pinned: DisplayTarget?

    init(store: SnapshotStore?, includeBrowserTabs: Bool) {
        self.store = store
        self.includeBrowserTabs = includeBrowserTabs
    }

    func outgoingScope() -> OutgoingScan {
        let scan = WindowInspector.scan(preferredOwner: FocusTracker.shared.lastExternalPID,
                                        pinnedTarget: pinned)
        if pinned == nil { pinned = scan.target }
        return OutgoingScan(destination: DestinationDisplay(scan.target),
                            windows: ReplacementScope.outgoing(from: scan),
                            accessibilityGranted: scan.accessibilityGranted)
    }

    func closeSupport(for window: OutgoingWindow) -> CloseSupport {
        guard Permissions.accessibilityGranted else {
            return .unknown("accessibility is not granted, so anchor cannot see this window's controls")
        }
        guard let element = AccessibilityWindows.element(pid: window.pid, matchingFrame: window.serverFrame) else {
            return .unknown("anchor could not tie this window to exactly one accessibility window")
        }
        guard let button = AccessibilityWindows.closeControl(element) else {
            return .unsupported("it has no close button of its own, and anchor never quits an application to close one window")
        }
        guard AccessibilityWindows.isEnabled(button) != false else {
            return .unsupported("its close button is disabled right now")
        }
        return .supported("anchor presses this window's own close button, exactly as clicking it would")
    }

    func requestClose(_ window: OutgoingWindow) async -> CloseRequest {
        guard let element = AccessibilityWindows.element(pid: window.pid, matchingFrame: window.serverFrame),
              let button = AccessibilityWindows.closeControl(element)
        else { return .refused("anchor could not find this window's close button any more") }
        let status = AccessibilityWindows.press(button)
        guard status == .success else {
            return .refused("the close button refused the request with accessibility status \(status.rawValue)")
        }
        return .requested("anchor pressed this window's close button")
    }

    func isRunning(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    func captureOutgoing() async -> CaptureCoordinator.Outcome {
        var outcome = await CaptureCoordinator.capture(options: CaptureCoordinator.Options(includeBrowserTabs: includeBrowserTabs,
                                                                            name: nil,
                                                                            captureThumbnail: true),
                                         focusPID: FocusTracker.shared.lastExternalPID,
                                         store: store)
        if let snapshot = outcome.snapshot, let data = outcome.thumbnail, let store {
            do {
                try ThumbnailStore.alongside(store).write(data, for: snapshot.id)
            } catch {
                outcome.thumbnailFailure = .notStored(error.localizedDescription)
            }
        }
        return outcome
    }
}
