import AppKit

// window server rects use a top-left origin anchored on the primary display
// appkit rects use a bottom-left origin, so every conversion pivots on the primary display height
enum ScreenGeometry {
    static var primaryTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func appKit(fromWindowServer rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func windowServer(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    // largest frame intersection wins so a spanning window lands on one display only
    static func screen(coveringAppKit rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    static func screen(containingAppKit point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func describe(_ rect: CGRect) -> String {
        let f = { (v: CGFloat) in String(format: "%.0f", v) }
        return "\(f(rect.minX)),\(f(rect.minY)) \(f(rect.width))x\(f(rect.height))"
    }
}
