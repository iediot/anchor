import AppKit
import ApplicationServices

// moving a window is the one thing anchor does to a window it did not create in this
// operation, and only when that window was confidently identified on the destination
// accessibility positions are in the window server's top left space, appkit rects are not
enum WindowPlacement {
    static func serverFrame(ofWindow id: CGWindowID) -> (pid: pid_t, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        guard let entry = list.first,
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return (pid, bounds)
    }

    static func place(windowID: CGWindowID, appKitFrame: CGRect) -> PlacementOutcome {
        guard Permissions.accessibilityGranted else {
            return .unavailable("accessibility is not granted, so anchor cannot move or size a window")
        }
        guard LayoutMapping.finite(appKitFrame), appKitFrame.width > 0, appKitFrame.height > 0 else {
            return .unavailable("the requested rectangle is not usable")
        }
        guard let current = serverFrame(ofWindow: windowID) else {
            return .unavailable("window \(windowID) is no longer listed by the window server")
        }
        let matches = AccessibilityWindows.elements(pid: current.pid).filter { entry in
            guard let frame = entry.facts.frame else { return false }
            return abs(frame.minX - current.frame.minX) < 2 && abs(frame.minY - current.frame.minY) < 2
                && abs(frame.width - current.frame.width) < 2 && abs(frame.height - current.frame.height) < 2
        }
        guard matches.count == 1, let target = matches.first else {
            return .unavailable("the window could not be tied to one accessibility window, \(matches.count) fit its rectangle")
        }

        let requested = ScreenGeometry.windowServer(fromAppKit: appKitFrame)
        var origin = requested.origin
        var size = requested.size
        var refused: [String] = []
        if let value = AXValueCreate(.cgPoint, &origin) {
            let status = AXUIElementSetAttributeValue(target.element, kAXPositionAttribute as CFString, value)
            if status != .success { refused.append("the position was refused with accessibility status \(status.rawValue)") }
        }
        if let value = AXValueCreate(.cgSize, &size) {
            let status = AXUIElementSetAttributeValue(target.element, kAXSizeAttribute as CFString, value)
            if status != .success { refused.append("the size was refused with accessibility status \(status.rawValue)") }
        }
        // the position is set again because resizing can push a window back out of place
        if refused.isEmpty, let value = AXValueCreate(.cgPoint, &origin) {
            _ = AXUIElementSetAttributeValue(target.element, kAXPositionAttribute as CFString, value)
        }

        guard let applied = AccessibilityWindows.currentFrame(target.element) else {
            return .refused("the window did not report a rectangle back after the move")
        }
        if !refused.isEmpty {
            return .refused(refused.joined(separator: ", ") + ", it is at \(RectRecord(ScreenGeometry.appKit(fromWindowServer: applied)).summary)")
        }
        let actual = ScreenGeometry.appKit(fromWindowServer: applied)
        return .applied(requested: appKitFrame,
                        actual: actual,
                        adjustment: LayoutMapping.describeAdjustment(requested: appKitFrame, actual: actual))
    }
}
