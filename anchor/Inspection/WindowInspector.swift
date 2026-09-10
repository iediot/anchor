import AppKit

enum CaptureAvailability {
    case adapterPlanned(IntegrationKind)
    case geometryOnly

    var label: String {
        switch self {
        case .adapterPlanned(let kind): return "\(kind.displayName) adapter planned"
        case .geometryOnly: return "geometry only"
        }
    }
}

enum TitleSource: String {
    case windowServer = "window server"
    case accessibility = "accessibility"
    case unavailable = "unavailable"
}

enum FullScreenSignal: String {
    case ordinary = "ordinary window"
    case accessibilityFullScreen = "fullscreen confirmed by accessibility"
    case coversDisplay = "covers the whole display, fullscreen not confirmed"
    case tilesDisplayHalf = "tiles half the display, split view not confirmed"
    case unknown = "unknown, accessibility unavailable"
}

struct InspectedWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let bundleID: String?
    let title: String?
    let titleSource: TitleSource
    let serverFrame: CGRect
    let appKitFrame: CGRect
    let layer: Int
    let alpha: CGFloat
    let screenName: String?
    let inScope: Bool
    let scopeReason: String
    let availability: CaptureAvailability
    let fullScreen: FullScreenSignal
    let axTitleMatched: Bool
    let documentPath: String?
}

struct WindowScan {
    let windows: [InspectedWindow]
    let target: DisplayTarget
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let lostPinnedDisplay: Bool
    let capturedAt: Date

    var inScope: [InspectedWindow] { windows.filter(\.inScope) }
    var outOfScope: [InspectedWindow] { windows.filter { !$0.inScope } }

    // every on-screen window of one app, whatever display it landed on
    // scope membership and window identity are separate questions
    func windows(ofBundleID bundleID: String) -> [InspectedWindow] {
        windows.filter { $0.bundleID == bundleID }
    }
}

enum WindowInspector {
    // the on-screen option already drops minimized windows and other spaces
    // so the list is the current desktop of every display, which we then narrow to one display
    static func scan(preferredOwner: pid_t?, pinnedTarget: DisplayTarget? = nil) -> WindowScan {
        let raw = rawWindows()
        let now = Date()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = raw.compactMap { entry in candidate(from: entry, ownPID: ownPID) }
        let target = pinnedTarget.flatMap { DisplayTarget.repin($0, at: now) }
            ?? DisplayTarget.resolve(from: candidates, preferredOwner: preferredOwner)
        let lostPin = pinnedTarget != nil && target.pinnedFrom == nil
        let granted = Permissions.accessibilityGranted
        let recording = Permissions.screenRecordingGranted

        var axCache: [pid_t: [AXWindowFacts]] = [:]
        var windows: [InspectedWindow] = []
        for candidate in candidates {
            let onTarget = ScreenGeometry.screen(coveringAppKit: candidate.appKitFrame) === target.screen
            let reason = scopeReason(candidate, onTarget: onTarget, target: target)
            let facts: AXWindowFacts?
            if granted {
                if axCache[candidate.pid] == nil {
                    axCache[candidate.pid] = AccessibilityWindows.windows(pid: candidate.pid)
                }
                facts = AccessibilityWindows.match(axCache[candidate.pid] ?? [], toFrame: candidate.serverFrame)
            } else {
                facts = nil
            }
            let (title, titleSource) = resolveTitle(candidate, facts: facts)
            windows.append(InspectedWindow(id: candidate.id,
                                           pid: candidate.pid,
                                           ownerName: candidate.ownerName,
                                           bundleID: candidate.bundleID,
                                           title: title,
                                           titleSource: titleSource,
                                           serverFrame: candidate.serverFrame,
                                           appKitFrame: candidate.appKitFrame,
                                           layer: candidate.layer,
                                           alpha: candidate.alpha,
                                           screenName: ScreenGeometry.screen(coveringAppKit: candidate.appKitFrame)?.localizedName,
                                           inScope: reason == nil,
                                           scopeReason: reason ?? "on the target display and an ordinary window",
                                           availability: availability(for: candidate.bundleID),
                                           fullScreen: fullScreenSignal(candidate, facts: facts, granted: granted, target: target),
                                           axTitleMatched: facts != nil,
                                           documentPath: facts?.documentPath))
        }
        return WindowScan(windows: windows,
                          target: target,
                          accessibilityGranted: granted,
                          screenRecordingGranted: recording,
                          lostPinnedDisplay: lostPin,
                          capturedAt: now)
    }

    // the window server only fills in a name when screen recording is granted
    // accessibility gives the same title without asking for a screen capture permission
    private static func resolveTitle(_ candidate: WindowCandidate, facts: AXWindowFacts?) -> (String?, TitleSource) {
        if let title = candidate.title { return (title, .windowServer) }
        if let title = facts?.title, !title.isEmpty { return (title, .accessibility) }
        return (nil, .unavailable)
    }

    static func rawWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private static func candidate(from entry: [String: Any], ownPID: pid_t) -> WindowCandidate? {
        guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let running = NSRunningApplication(processIdentifier: pid)
        return WindowCandidate(id: number,
                               pid: pid,
                               isSelf: pid == ownPID,
                               ownerName: entry[kCGWindowOwnerName as String] as? String ?? running?.localizedName ?? "unknown",
                               bundleID: running?.bundleIdentifier,
                               title: (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               serverFrame: bounds,
                               appKitFrame: ScreenGeometry.appKit(fromWindowServer: bounds),
                               layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                               alpha: entry[kCGWindowAlpha as String] as? CGFloat ?? 1)
    }

    // returns nil when the window belongs in scope, otherwise why it was excluded
    private static func scopeReason(_ candidate: WindowCandidate, onTarget: Bool, target: DisplayTarget) -> String? {
        if candidate.isSelf { return "anchor's own window" }
        if candidate.layer != 0 { return "window layer \(candidate.layer) is desktop furniture or an overlay" }
        if candidate.alpha <= 0.01 { return "fully transparent" }
        if candidate.serverFrame.width < 40 || candidate.serverFrame.height < 40 { return "too small to be an ordinary window" }
        if !onTarget { return "on \(ScreenGeometry.screen(coveringAppKit: candidate.appKitFrame)?.localizedName ?? "another display")" }
        return nil
    }

    private static func availability(for bundleID: String?) -> CaptureAvailability {
        if let kind = IntegrationKind.matching(bundleID: bundleID) { return .adapterPlanned(kind) }
        return .geometryOnly
    }

    private static func fullScreenSignal(_ candidate: WindowCandidate,
                                         facts: AXWindowFacts?,
                                         granted: Bool,
                                         target: DisplayTarget) -> FullScreenSignal {
        if let confirmed = facts?.isFullScreen {
            return confirmed ? .accessibilityFullScreen : .ordinary
        }
        guard let screen = ScreenGeometry.screen(coveringAppKit: candidate.appKitFrame) else {
            return granted ? .unknown : .unknown
        }
        let frame = candidate.appKitFrame
        let coversHeight = abs(frame.height - screen.frame.height) < 2
        if coversHeight && abs(frame.width - screen.frame.width) < 2 { return .coversDisplay }
        if coversHeight && frame.width < screen.frame.width - 2 { return .tilesDisplayHalf }
        return granted ? .ordinary : .unknown
    }
}

struct WindowCandidate {
    let id: CGWindowID
    let pid: pid_t
    let isSelf: Bool
    let ownerName: String
    let bundleID: String?
    let title: String?
    let serverFrame: CGRect
    let appKitFrame: CGRect
    let layer: Int
    let alpha: CGFloat
}
