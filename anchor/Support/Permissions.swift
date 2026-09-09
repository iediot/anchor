import AppKit
import ApplicationServices
import CoreGraphics

enum AutomationAccess: Equatable {
    case granted
    case denied
    case undetermined
    case targetNotRunning
    case other(OSStatus)

    var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "not requested yet"
        case .targetNotRunning: return "app not running"
        case .other(let status): return "unclear (status \(status))"
        }
    }
}

enum Permissions {
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    // preflight never prompts, anchor only reports this because it decides whether
    // the window server fills in window names
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // shows the system prompt once, the user still has to finish in settings
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // blocks while the system decides, so call it on the script queue rather than directly
    nonisolated static func automationAccessBlocking(for bundleID: String, askUser: Bool) -> AutomationAccess {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = OSStatus(bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target)
        })
        guard created == noErr else { return .other(created) }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askUser)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        case OSStatus(Int32(procNotFound)): return .targetNotRunning
        default: return .other(status)
        }
    }
}
