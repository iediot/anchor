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
    let pinnedFrom: Date?

    var isPrimary: Bool { screen === NSScreen.screens.first }

    var originDescription: String {
        guard let pinnedFrom else { return source.rawValue }
        return "\(source.rawValue), kept from the selection made at \(ProbeEvidence.stamp(pinnedFrom))"
    }

    // a rescan taken for a probe must not let anchor's own focus redefine the destination
    // the screen is looked up again by display id so a changed layout is noticed
    static func repin(_ previous: DisplayTarget, at date: Date) -> DisplayTarget? {
        guard let displayID = previous.displayID,
              let screen = NSScreen.screens.first(where: { ScreenGeometry.displayID(of: $0) == displayID })
        else { return nil }
        return DisplayTarget(screen: screen,
                             displayID: displayID,
                             name: screen.localizedName,
                             frame: screen.frame,
                             visibleFrame: screen.visibleFrame,
                             backingScale: screen.backingScaleFactor,
                             source: previous.source,
                             decidedBy: previous.decidedBy,
                             pinnedFrom: previous.pinnedFrom ?? date)
    }

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
                      decidedBy: decidedBy,
                      pinnedFrom: nil)
    }
}
