import AppKit

enum IntegrationKind: String, CaseIterable, Identifiable {
    case safari
    case chrome
    case terminal
    case iTerm
    case pycharm
    case clion
    case xcode

    var id: String { rawValue }

    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .terminal: return "com.apple.Terminal"
        case .iTerm: return "com.googlecode.iterm2"
        case .pycharm: return "com.jetbrains.pycharm"
        case .clion: return "com.jetbrains.CLion"
        case .xcode: return "com.apple.dt.Xcode"
        }
    }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm2"
        case .pycharm: return "PyCharm"
        case .clion: return "CLion"
        case .xcode: return "Xcode"
        }
    }

    // jetbrains ides ship no scripting dictionary so they are probed through accessibility instead
    var usesAppleEvents: Bool {
        switch self {
        case .pycharm, .clion: return false
        default: return true
        }
    }

    static func matching(bundleID: String?) -> IntegrationKind? {
        guard let bundleID else { return nil }
        return allCases.first { $0.bundleID == bundleID }
    }
}

struct InstalledApp {
    let kind: IntegrationKind
    let installedPath: String?
    let version: String?
    let isRunning: Bool

    var isInstalled: Bool { installedPath != nil }
}

enum AppCatalog {
    // read-only lookup, nothing here launches an application
    static func survey() -> [InstalledApp] {
        IntegrationKind.allCases.map { kind in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID)
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: kind.bundleID)
                .contains { !$0.isTerminated }
            return InstalledApp(kind: kind,
                                installedPath: url?.path,
                                version: url.flatMap(shortVersion),
                                isRunning: running)
        }
    }

    private static func shortVersion(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
}
