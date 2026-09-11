import ApplicationServices
import Foundation

struct AXWindowFacts {
    let title: String?
    let subrole: String?
    let frame: CGRect?
    let isFullScreen: Bool?
    let isMinimized: Bool?
    let documentPath: String?
}

// accessibility gives fullscreen and subrole facts the window server list does not carry
// there is no public way to read a window server id from an accessibility element
// so windows are paired by frame, which is why an exact frame match is required
enum AccessibilityWindows {
    nonisolated static func windows(pid: pid_t) -> [AXWindowFacts] {
        elements(pid: pid).map(\.facts)
    }

    // an application that is still starting answers accessibility when it feels like it,
    // and the system default leaves a read waiting far longer than a poll can afford
    // the timeout is set on the application element, which is what every read goes through
    nonisolated static let messagingTimeout: Float = 2

    // the element is needed to place a window, the facts alone cannot be moved
    nonisolated static func elements(pid: pid_t) -> [(element: AXUIElement, facts: AXWindowFacts)] {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return [] }
        return elements.map { ($0, facts($0)) }
    }

    nonisolated static func currentFrame(_ element: AXUIElement) -> CGRect? {
        frame(element)
    }

    // one window element, only when exactly one of the app's windows sits at that rectangle
    nonisolated static func element(pid: pid_t, matchingFrame rect: CGRect) -> AXUIElement? {
        let hits = elements(pid: pid).filter { entry in
            guard let other = entry.facts.frame else { return false }
            return abs(other.minX - rect.minX) < 2 && abs(other.minY - rect.minY) < 2
                && abs(other.width - rect.width) < 2 && abs(other.height - rect.height) < 2
        }
        return hits.count == 1 ? hits[0].element : nil
    }

    // the window's own close button, which is what a click on it would press
    // there is no quit, terminate or force close here on purpose
    nonisolated static func closeControl(_ element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    nonisolated static func isEnabled(_ element: AXUIElement) -> Bool? {
        bool(element, kAXEnabledAttribute)
    }

    nonisolated static func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    nonisolated static func match(_ candidates: [AXWindowFacts], toFrame frame: CGRect) -> AXWindowFacts? {
        let hits = candidates.filter { candidate in
            guard let other = candidate.frame else { return false }
            return abs(other.minX - frame.minX) < 2 && abs(other.minY - frame.minY) < 2
                && abs(other.width - frame.width) < 2 && abs(other.height - frame.height) < 2
        }
        return hits.count == 1 ? hits[0] : nil
    }

    nonisolated private static func facts(_ element: AXUIElement) -> AXWindowFacts {
        AXWindowFacts(title: string(element, kAXTitleAttribute),
                      subrole: string(element, kAXSubroleAttribute),
                      frame: frame(element),
                      isFullScreen: bool(element, "AXFullScreen"),
                      isMinimized: bool(element, kAXMinimizedAttribute),
                      documentPath: documentPath(element))
    }

    // a document window advertises its own file, which needs accessibility only
    // and never an apple event or a recent documents list
    nonisolated private static func documentPath(_ element: AXUIElement) -> String? {
        guard let raw = string(element, kAXDocumentAttribute) else { return nil }
        if let url = URL(string: raw), url.isFileURL { return url.path }
        return raw.isEmpty ? nil : raw
    }

    nonisolated private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin: CGPoint = axValue(element, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(element, kAXSizeAttribute, .cgSize)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    nonisolated private static func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(raw as! AXValue, type, out) else { return nil }
        return out.pointee
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    nonisolated private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? Bool
    }
}
