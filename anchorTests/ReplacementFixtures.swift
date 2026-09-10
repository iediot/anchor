import CoreGraphics
import Foundation
@testable import anchor

// a machine a replacement can act on, which records every request and performs none
// the protocol carries no quit, terminate or signal, so a test cannot ask for one
@MainActor
final class StubReplacementServices: ReplacementServices {
    enum Call: Equatable {
        case scope
        case support(CGWindowID)
        case close(CGWindowID)
        case running(pid_t)
        case capture
    }

    private(set) var calls: [Call] = []
    var destination = RestoreFixtures.destination()
    var windows: [OutgoingWindow] = []
    var accessibilityGranted = true
    var support: [CGWindowID: CloseSupport] = [:]
    var defaultSupport = CloseSupport.supported("test close control")
    var refuses: Set<CGWindowID> = []
    var neverCloses: Set<CGWindowID> = []
    var exited: Set<pid_t> = []
    var captureOutcome = CaptureCoordinator.Outcome(snapshot: nil,
                                                    storeError: nil,
                                                    summary: "no capture was configured")
    var onScope: (() -> Void)?
    var onClose: ((OutgoingWindow) -> Void)?

    var closeCalls: [CGWindowID] {
        calls.compactMap { if case .close(let id) = $0 { return id } else { return nil } }
    }

    func outgoingScope() -> OutgoingScan {
        calls.append(.scope)
        onScope?()
        return OutgoingScan(destination: destination,
                            windows: windows,
                            accessibilityGranted: accessibilityGranted)
    }

    func closeSupport(for window: OutgoingWindow) -> CloseSupport {
        calls.append(.support(window.id))
        return support[window.id] ?? defaultSupport
    }

    func requestClose(_ window: OutgoingWindow) async -> CloseRequest {
        calls.append(.close(window.id))
        onClose?(window)
        if refuses.contains(window.id) { return .refused("the test refused this close") }
        if !neverCloses.contains(window.id) {
            windows.removeAll { $0.id == window.id }
        }
        return .requested("the test pressed the close control")
    }

    func isRunning(pid: pid_t) -> Bool {
        calls.append(.running(pid))
        return !exited.contains(pid)
    }

    func captureOutgoing() async -> CaptureCoordinator.Outcome {
        calls.append(.capture)
        return captureOutcome
    }
}

@MainActor
enum ReplacementFixtures {
    static func window(id: CGWindowID,
                       pid: pid_t = 501,
                       bundleID: String? = "com.apple.Safari",
                       app: String = "Safari",
                       title: String? = "a window",
                       frame: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400)) -> OutgoingWindow {
        OutgoingWindow(id: id,
                       pid: pid,
                       bundleID: bundleID,
                       appName: app,
                       title: title,
                       appKitFrame: frame,
                       serverFrame: frame)
    }

    static func outcome(completeness: SnapshotCompleteness = .complete,
                        storeError: String? = nil,
                        issues: [CaptureIssue] = []) -> CaptureCoordinator.Outcome {
        guard storeError == nil else {
            return CaptureCoordinator.Outcome(snapshot: nil,
                                              storeError: storeError,
                                              summary: "capture ran but nothing could be stored")
        }
        var snapshot = RestoreFixtures.snapshot([], completeness: completeness)
        snapshot.issues = issues
        return CaptureCoordinator.Outcome(snapshot: snapshot, storeError: nil, summary: "saved")
    }
}
