import AppKit

// which of an application's windows is the project window anchor asked for
// the first window an ide shows is a splash or a welcome screen, and placing that one
// leaves the real project window wherever the ide decided to put it
enum ProjectWindowIdentity {
    // xcode advertises the file it has open, jetbrains has no such attribute so its
    // match stays the title rule the capture side already uses
    static func evidence(request: ProjectOpenRequest,
                         window: LiveWindow,
                         accessibilityGranted: Bool) -> String? {
        guard accessibilityGranted else { return nil }
        switch request.app {
        case .xcode:
            guard let document = window.documentPath else { return nil }
            let path = (document as NSString).standardizingPath
            guard path == request.path else { return nil }
            return "the window advertises \(path) as its own document"
        case .pycharm, .clion:
            guard let title = window.title else { return nil }
            // the welcome window can carry a real project name in its leading segment, so
            // it is never the project window and is never moved
            guard !JetBrainsWindowTitle.role(title: title, kind: request.app).isWelcome else { return nil }
            guard JetBrainsProbe.leadingSegment(title).caseInsensitiveCompare(request.projectName) == .orderedSame
            else { return nil }
            return "the window title starts with \(request.projectName), which is the same heuristic the capture side uses and is not proof"
        case .safari, .chrome, .terminal, .iTerm:
            return nil
        }
    }
}

enum ProjectWindowReadiness {
    enum Resolution: Equatable {
        case ready(CGWindowID, String)
        case notYet(String)
        case ambiguous([CGWindowID], String)
        case unavailable(String)
    }

    // a window smaller than a placeable one is a splash or a progress panel
    static var minimumSize: CGSize { LayoutMapping.minimumSize }

    static func resolve(request: ProjectOpenRequest,
                        candidates: [LiveWindow],
                        excluding: Set<CGWindowID>,
                        accessibilityGranted: Bool) -> Resolution {
        guard accessibilityGranted else {
            return .unavailable("accessibility is not granted, so anchor cannot tell the project window from the startup window and placed nothing")
        }
        let fresh = candidates.filter { !excluding.contains($0.id) }
        let matched = fresh.compactMap { window -> (LiveWindow, String)? in
            guard let reason = ProjectWindowIdentity.evidence(request: request,
                                                              window: window,
                                                              accessibilityGranted: true) else { return nil }
            guard window.appKitFrame.width >= minimumSize.width,
                  window.appKitFrame.height >= minimumSize.height else { return nil }
            return (window, reason)
        }
        if matched.count > 1 {
            return .ambiguous(matched.map(\.0.id),
                              "\(matched.count) new windows claim to be \(request.projectName)")
        }
        if let found = matched.first {
            return .ready(found.0.id, found.1)
        }
        guard !fresh.isEmpty else {
            return .notYet("no window has appeared for \(request.app.displayName) yet")
        }
        return .notYet("\(fresh.count) windows have appeared but none of them is the \(request.projectName) window yet")
    }
}
