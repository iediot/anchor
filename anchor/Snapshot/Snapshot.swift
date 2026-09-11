import CoreGraphics
import Foundation

// the on disk snapshot format
// every record is written by anchor and read back by anchor, so the schema carries
// its own version and nothing here depends on a runtime identity surviving a relaunch
nonisolated enum SnapshotSchema {
    static let current = 1
}

nonisolated struct RectRecord: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var summary: String {
        let f = { (v: Double) in String(format: "%.0f", v) }
        return "\(f(x)),\(f(y)) \(f(width))x\(f(height))"
    }
}

// read first so a file written by another schema version still shows its date and name
nonisolated struct SnapshotHeader: Codable {
    var schemaVersion: Int
    var id: String
    var createdAt: Date
    var name: String?
}

nonisolated enum SnapshotCompleteness: String, Codable {
    case complete
    case partial
    case inconsistent

    var label: String {
        switch self {
        case .complete: return "full capture, every scoped window yielded its supported resources"
        case .partial: return "partial capture, some resources were omitted or unavailable"
        case .inconsistent: return "inconsistent capture, the screen changed while anchor was reading it"
        }
    }
}

nonisolated struct HostRecord: Codable {
    var operatingSystem: String
    var anchorVersion: String
}

nonisolated struct DisplayRecord: Codable {
    var displayID: UInt32?
    var name: String
    var frame: RectRecord
    var visibleFrame: RectRecord
    var backingScale: Double
    var isPrimary: Bool
    var attachedDisplays: Int
    var selectionSource: String
    var selectionDetail: String?
}

nonisolated enum ResourceKind: String, Codable {
    case browser
    case terminal
    case jetBrains
    case xcode
    case finder
    case unsupported

    var label: String {
        switch self {
        case .finder: return "finder folder"
        case .browser: return "browser tabs"
        case .terminal: return "terminal directories"
        case .jetBrains: return "jetbrains project"
        case .xcode: return "xcode project"
        case .unsupported: return "no adapter"
        }
    }
}

// an omission, a denial and a genuinely empty app are three different answers
nonisolated enum ResourceStatus: String, Codable {
    case captured
    case capturedEmpty
    case omittedByUser
    case windowNotResolved
    case resourceNotIdentified
    case automationDenied
    case automationNotGranted
    case accessibilityNotGranted
    case adapterFailed
    case adapterTimedOut
    case adapterUnavailable
    case appNotSupported

    var label: String {
        switch self {
        case .captured: return "captured"
        case .capturedEmpty: return "adapter ran and the app reported nothing to capture"
        case .omittedByUser: return "omitted at the user's request"
        case .windowNotResolved: return "window not resolved, no content attached"
        case .resourceNotIdentified: return "resource not identified"
        case .automationDenied: return "automation denied"
        case .automationNotGranted: return "automation not granted"
        case .accessibilityNotGranted: return "accessibility not granted"
        case .adapterFailed: return "adapter failed"
        case .adapterTimedOut: return "adapter timed out"
        case .adapterUnavailable: return "adapter unavailable"
        case .appNotSupported: return "no adapter for this application"
        }
    }

    // anything but a real read leaves the snapshot short of full capture
    var isOmission: Bool {
        switch self {
        case .captured, .capturedEmpty: return false
        default: return true
        }
    }
}

nonisolated struct BrowserTabRecord: Codable {
    var index: Int
    var url: String?
    var title: String?
    var issue: String?
}

nonisolated struct BrowserResource: Codable {
    var scriptWindowID: Int?
    var selectedTabIndex: Int?
    var tabs: [BrowserTabRecord]
    var privateWindowDetection: String
}

nonisolated struct TerminalTabRecord: Codable {
    var index: Int
    var tty: String?
    var selected: Bool?
    var directory: String?
    var directorySource: String?
    var issue: String?
}

nonisolated struct TerminalResource: Codable {
    var scriptWindowID: Int?
    var tabs: [TerminalTabRecord]
}

nonisolated struct JetBrainsResource: Codable {
    var projectPath: String?
    var matchProvenance: String
    var ambiguousCandidates: [String]
    var titleFileHint: String?
    var workspaceFile: String?
    var editorFiles: [String]
    var editorFileState: String
}

// the folder one finder window was showing, from the window itself
// accessibility names it for some windows, finder's own scripting for the rest, and a
// window that named neither keeps no path at all rather than one taken from its title
nonisolated struct FinderResource: Codable {
    var scriptWindowID: Int?
    var path: String?
    var pathSource: String?
    var issue: String?
}

nonisolated struct XcodeResource: Codable {
    var scriptWindowID: Int?
    var workingDocumentPath: String?
    var workingDocumentIssue: String?
    var accessibilityActiveFile: String?
}

// kind says which adapter owned the window, status says what actually happened
// the payload is present only when that adapter produced something
nonisolated struct WindowResources: Codable {
    var kind: ResourceKind
    var status: ResourceStatus
    var detail: String?
    var browser: BrowserResource?
    var terminal: TerminalResource?
    var jetBrains: JetBrainsResource?
    var xcode: XcodeResource?
    var finder: FinderResource?

    static func empty(_ kind: ResourceKind, _ status: ResourceStatus, _ detail: String? = nil) -> WindowResources {
        WindowResources(kind: kind, status: status, detail: detail)
    }
}

nonisolated struct WindowRecord: Codable, Identifiable {
    var id: String
    // runtime ids are matching aids for one login session, never durable identity
    var runtimeWindowID: UInt32?
    var appName: String
    var bundleID: String?
    var appVersion: String?
    var title: String?
    var titleSource: String
    var appKitFrame: RectRecord
    var displayRelativeFrame: RectRecord
    var windowServerFrame: RectRecord
    var fullScreenSignal: String
    var accessibilityDocument: String?
    var resources: WindowResources
    var limitations: [String]
}

nonisolated enum IssueSeverity: String, Codable {
    case note
    case omission
    case inconsistency
}

nonisolated struct CaptureIssue: Codable, Identifiable {
    var id: String
    var severity: IssueSeverity
    var scope: String
    var message: String

    init(severity: IssueSeverity, scope: String, message: String) {
        id = UUID().uuidString
        self.severity = severity
        self.scope = scope
        self.message = message
    }
}

nonisolated struct AdapterRun: Codable, Identifiable {
    var id: String
    var app: String
    var bundleID: String
    var startedAt: Date
    var finishedAt: Date
    var outcome: String
    var windowsAttempted: Int
    var windowsCaptured: Int
    // optional so snapshots written before window identity existed still decode
    var matchingBasis: String?

    init(app: String,
         bundleID: String,
         startedAt: Date,
         finishedAt: Date,
         outcome: String,
         windowsAttempted: Int,
         windowsCaptured: Int,
         matchingBasis: String?) {
        id = UUID().uuidString
        self.app = app
        self.bundleID = bundleID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.windowsAttempted = windowsAttempted
        self.windowsCaptured = windowsCaptured
        self.matchingBasis = matchingBasis
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

nonisolated struct Snapshot: Codable, Identifiable {
    var schemaVersion: Int
    var id: String
    var createdAt: Date
    var name: String?
    var completeness: SnapshotCompleteness
    var host: HostRecord
    var display: DisplayRecord
    var windows: [WindowRecord]
    var adapters: [AdapterRun]
    var issues: [CaptureIssue]

    var header: SnapshotHeader {
        SnapshotHeader(schemaVersion: schemaVersion, id: id, createdAt: createdAt, name: name)
    }

    var capturedResourceCount: Int {
        windows.filter { !$0.resources.status.isOmission }.count
    }

    var omittedResourceCount: Int {
        windows.filter { $0.resources.status.isOmission }.count
    }
}

nonisolated enum SnapshotName {
    static let maxLength = 120

    // a name is a label inside the file, it never reaches the filesystem
    // newlines are folded so one line always renders in a menu
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else { return nil }
        return String(folded.prefix(maxLength))
    }
}
