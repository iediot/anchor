import CoreGraphics
import Foundation

// what anchor intends to do with one saved state, decided before anything is opened
// a plan is built by reading only, it is immutable, and it is the only thing execution reads

enum RestoreItemKind: String {
    case browserTab
    case blankTab
    case terminalSession
    case project
    case activeFile
    case editorFile
    case layout
    case window

    var label: String {
        switch self {
        case .browserTab: return "tab"
        case .blankTab: return "blank tab"
        case .terminalSession: return "shell session"
        case .project: return "project"
        case .activeFile: return "active file"
        case .editorFile: return "editor file"
        case .layout: return "window layout"
        case .window: return "window"
        }
    }
}

// one answer per item, so a missing path never reads like an unsupported one
enum RestoreItemStatus: Equatable {
    case ready
    case readyWithLimitation(String)
    case omittedAtCapture(String)
    case missingPath(String)
    case inaccessiblePath(String)
    case unsupportedScheme(String)
    case malformed(String)
    case appUnavailable(String)
    case permissionNeeded(String)
    case ambiguousIdentity(String)
    case unsupported(String)

    var isActionable: Bool {
        switch self {
        case .ready, .readyWithLimitation: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .ready: return "ready"
        case .readyWithLimitation(let note): return "ready, \(note)"
        case .omittedAtCapture(let note): return "not captured, \(note)"
        case .missingPath(let note): return "missing, \(note)"
        case .inaccessiblePath(let note): return "not readable, \(note)"
        case .unsupportedScheme(let note): return "unsupported address, \(note)"
        case .malformed(let note): return "unusable record, \(note)"
        case .appUnavailable(let note): return "application unavailable, \(note)"
        case .permissionNeeded(let note): return "permission needed, \(note)"
        case .ambiguousIdentity(let note): return "identity unresolved, \(note)"
        case .unsupported(let note): return "not supported, \(note)"
        }
    }
}

struct RestorePlanItem: Identifiable, Equatable {
    let id: String
    let kind: RestoreItemKind
    let title: String
    // the full address or path, kept out of routine text and shown only on demand
    let detail: String?
    let status: RestoreItemStatus
}

// a browser tab anchor is willing to open, already validated
enum RestoreTabContent: Equatable {
    case web(String)
    case localFile(String)
    case blank
}

struct RestoreTab: Equatable {
    let itemID: String
    let content: RestoreTabContent
    let sourceIndex: Int
}

struct BrowserOpenRequest: Equatable {
    let app: IntegrationKind
    let tabs: [RestoreTab]
    // index into tabs, not the saved tab number
    let selectedTab: Int?
}

struct TerminalOpenRequest: Equatable {
    let app: IntegrationKind
    let itemID: String
    let directory: String
}

struct ProjectOpenRequest: Equatable {
    let app: IntegrationKind
    let itemID: String
    let path: String
    let projectName: String
}

enum RestoreAction: Equatable {
    case openBrowserWindow(BrowserOpenRequest)
    case openTerminalSession(TerminalOpenRequest)
    case openProject(ProjectOpenRequest)
    case nothing(String)

    var isActionable: Bool {
        if case .nothing = self { return false }
        return true
    }

    // a project is handed to the installed application itself, only the scripted
    // applications need automation consent
    var needsAutomation: Bool {
        switch self {
        case .openBrowserWindow, .openTerminalSession: return true
        case .openProject, .nothing: return false
        }
    }

    var summary: String {
        switch self {
        case .openBrowserWindow(let request):
            return "open a new \(request.app.displayName) window with \(request.tabs.count) tabs"
        case .openTerminalSession(let request):
            return "open a new \(request.app.displayName) window at \(request.directory)"
        case .openProject(let request):
            return "open \(request.projectName) in \(request.app.displayName)"
        case .nothing(let reason):
            return "nothing will be opened, \(reason)"
        }
    }
}

struct MappedFrame: Equatable {
    let appKitFrame: CGRect
    let scale: CGFloat
    let wasScaled: Bool
    let wasClamped: Bool
    let notes: [String]
}

enum LayoutPlan: Equatable {
    case mapped(MappedFrame)
    case unavailable(String)

    var frame: CGRect? {
        if case .mapped(let mapped) = self { return mapped.appKitFrame }
        return nil
    }

    var summary: String {
        switch self {
        case .mapped(let mapped):
            let notes = mapped.notes.isEmpty ? "" : ", " + mapped.notes.joined(separator: ", ")
            return "place at \(ScreenGeometry.describe(mapped.appKitFrame))\(notes)"
        case .unavailable(let reason):
            return "no layout, \(reason)"
        }
    }
}

struct RestorePlanWindow: Identifiable, Equatable {
    let id: String
    let appName: String
    let bundleID: String?
    let title: String?
    let sourceFrame: RectRecord
    let action: RestoreAction
    let layout: LayoutPlan
    let items: [RestorePlanItem]
    let limitations: [String]

    var isActionable: Bool { action.isActionable }
    var readyItemCount: Int { items.filter { $0.status.isActionable }.count }
    var blockedItemCount: Int { items.filter { !$0.status.isActionable }.count }
}

struct RestoreGroup: Identifiable, Equatable {
    let id: String
    let appName: String
    let bundleID: String?
    let kind: ResourceKind
    let appDetail: String
    let windows: [RestorePlanWindow]

    var isActionable: Bool { windows.contains { $0.isActionable } }
    var needsAutomation: Bool { windows.contains { $0.action.needsAutomation } }
}

enum PlanNoteSeverity: String {
    case note
    case limitation
    case blocker
}

struct PlanNote: Identifiable, Equatable {
    let id: String
    let severity: PlanNoteSeverity
    let text: String

    init(_ severity: PlanNoteSeverity, _ text: String) {
        id = UUID().uuidString
        self.severity = severity
        self.text = text
    }
}

// the display anchor would restore onto, taken from the same resolution capture uses
struct DestinationDisplay: Equatable {
    let displayID: UInt32?
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScale: Double
    let selectionSource: String
    let selectionDetail: String?

    // material change means a different display or a different usable area
    // a changed window set alone is not material here because nothing is closed
    var fingerprint: String {
        let id = displayID.map(String.init) ?? name
        return "\(id)|\(ScreenGeometry.describe(frame))|\(ScreenGeometry.describe(visibleFrame))"
    }
}

struct PlanPermissions: Equatable {
    let accessibilityGranted: Bool
    let automation: [String: String]
}

struct RestorePlan: Identifiable, Equatable {
    let id: String
    let snapshotID: String
    let snapshotName: String?
    let snapshotCreatedAt: Date
    let completeness: SnapshotCompleteness
    let source: DisplayRecord
    let destination: DestinationDisplay
    let groups: [RestoreGroup]
    let notes: [PlanNote]
    let permissions: PlanPermissions
    let builtAt: Date

    var windows: [RestorePlanWindow] { groups.flatMap(\.windows) }
    var actionableWindows: [RestorePlanWindow] { windows.filter(\.isActionable) }
    var actionableWindowCount: Int { actionableWindows.count }
    var blockedItemCount: Int { windows.reduce(0) { $0 + $1.blockedItemCount } }
    var readyItemCount: Int { windows.reduce(0) { $0 + $1.readyItemCount } }

    var headline: String {
        guard actionableWindowCount > 0 else {
            return "nothing in this saved state can be reopened by this build"
        }
        return "\(actionableWindowCount) windows would be opened on \(destination.name), \(readyItemCount) items ready, \(blockedItemCount) not available"
    }

    static func == (lhs: RestorePlan, rhs: RestorePlan) -> Bool { lhs.id == rhs.id }
}
