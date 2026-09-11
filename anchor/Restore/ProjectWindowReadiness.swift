import AppKit

// which of an application's windows is the project window anchor asked for
// the first window an ide shows is a splash or a welcome screen, and placing that one
// leaves the real project window wherever the ide decided to put it
enum ProjectWindowIdentity {
    // xcode's accessibility document is the file open in the editor, not the project it
    // belongs to, so the project path on its own matches nothing once a file is open
    // jetbrains has no such attribute so its match stays the title rule capture uses
    static func evidence(request: ProjectOpenRequest,
                         window: LiveWindow,
                         accessibilityGranted: Bool) -> String? {
        guard accessibilityGranted else { return nil }
        switch request.app {
        case .xcode:
            return xcode(request: request, window: window)
        case .pycharm, .clion:
            guard let title = window.title else { return nil }
            // the welcome window can carry a real project name in its leading segment, so
            // it is never the project window and is never moved
            guard !JetBrainsWindowTitle.role(title: title, kind: request.app).isWelcome else { return nil }
            guard JetBrainsProbe.leadingSegment(title).caseInsensitiveCompare(request.projectName) == .orderedSame
            else { return nil }
            return "the window title starts with \(request.projectName), which is the same heuristic the capture side uses and is not proof"
        case .safari, .chrome, .terminal, .iTerm, .finder:
            return nil
        }
    }

    // two ways an xcode window can be the project window, both read only
    // it advertises the project itself, which is what an editor with no file open reports,
    // or it is editing a file inside the project's own folder and its title names the
    // project as well. neither half of the second is evidence on its own
    private static func xcode(request: ProjectOpenRequest, window: LiveWindow) -> String? {
        guard let document = window.documentPath else { return nil }
        let project = (request.path as NSString).standardizingPath
        let path = (document as NSString).standardizingPath
        if path == project {
            return "the window advertises the project as its own document"
        }
        guard isInside(folder(of: project), path) else { return nil }
        guard let title = window.title else { return nil }
        let name = projectName(of: project)
        // the title is the project, a dash, then the file, the same shape the ides use
        guard JetBrainsProbe.leadingSegment(title).caseInsensitiveCompare(name) == .orderedSame else { return nil }
        return "the window is editing a file inside the project's own folder and its title starts with \(name), which is corroboration and not proof"
    }

    static let projectBundles = ["xcodeproj", "xcworkspace"]

    // the folder the project bundle sits in, which is what its files sit under
    static func folder(of project: String) -> String {
        guard projectBundles.contains((project as NSString).pathExtension.lowercased()) else { return project }
        return (project as NSString).deletingLastPathComponent
    }

    // the name xcode puts in a window title, which is the bundle without its extension
    static func projectName(of project: String) -> String {
        let last = (project as NSString).lastPathComponent
        guard projectBundles.contains((last as NSString).pathExtension.lowercased()) else { return last }
        return (last as NSString).deletingPathExtension
    }

    static func isInside(_ folder: String, _ path: String) -> Bool {
        guard folder.count > 1 else { return false }
        let root = folder.hasSuffix("/") ? folder : folder + "/"
        return path == folder || path.hasPrefix(root)
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
