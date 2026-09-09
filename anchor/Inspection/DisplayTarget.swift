import AppKit

struct DisplayTarget {
    enum Source: String {
        case lastActiveApplication = "frontmost window of the last app active before anchor"
        case frontmostWindow = "frontmost ordinary window in the window server list"
        case pointer = "pointer location, no usable window found"
        case mainDisplay = "main display fallback"
    }

    let screen: NSScreen
    let displayID: CGDirectDisplayID?
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScale: CGFloat
    let source: Source
    let decidedBy: String?

    var isPrimary: Bool { screen === NSScreen.screens.first }

    // menu interaction must never pick anchor's own display, so self owned windows are already gone
    static func resolve(from candidates: [WindowCandidate], preferredOwner: pid_t?) -> DisplayTarget {
        let ordinary = candidates.filter { !$0.isSelf && $0.layer == 0 && $0.alpha > 0.01 }

        if let preferredOwner, let window = ordinary.first(where: { $0.pid == preferredOwner }),
           let screen = ScreenGeometry.screen(coveringAppKit: window.appKitFrame) {
            return make(screen, .lastActiveApplication, describe(window))
        }
        if let window = ordinary.first, let screen = ScreenGeometry.screen(coveringAppKit: window.appKitFrame) {
            return make(screen, .frontmostWindow, describe(window))
        }
        if let screen = ScreenGeometry.screen(containingAppKit: NSEvent.mouseLocation) {
            return make(screen, .pointer, nil)
        }
        let fallback = NSScreen.main ?? NSScreen.screens.first!
        return make(fallback, .mainDisplay, nil)
    }

    private static func describe(_ window: WindowCandidate) -> String {
        guard let title = window.title else { return window.ownerName }
        return "\(window.ownerName) — \(title)"
    }

    private static func make(_ screen: NSScreen, _ source: Source, _ decidedBy: String?) -> DisplayTarget {
        DisplayTarget(screen: screen,
                      displayID: ScreenGeometry.displayID(of: screen),
                      name: screen.localizedName,
                      frame: screen.frame,
                      visibleFrame: screen.visibleFrame,
                      backingScale: screen.backingScaleFactor,
                      source: source,
                      decidedBy: decidedBy)
    }
}
