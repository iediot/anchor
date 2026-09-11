import CoreGraphics
import Foundation
@testable import anchor

// builders for restore tests, so each test states only the thing it is about
@MainActor
enum RestoreFixtures {
    static func destination(frame: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visible: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 944),
                            displayID: UInt32? = 1,
                            name: String = "Test Display",
                            backingScale: Double = 2) -> DestinationDisplay {
        DestinationDisplay(displayID: displayID,
                           name: name,
                           frame: frame,
                           visibleFrame: visible,
                           backingScale: backingScale,
                           selectionSource: "test",
                           selectionDetail: nil)
    }

    static func window(id: String = UUID().uuidString,
                       app: String = "Safari",
                       bundleID: String? = "com.apple.Safari",
                       title: String? = "window",
                       frame: CGRect = CGRect(x: 10, y: 20, width: 700, height: 800),
                       fullScreen: String = "ordinary window",
                       document: String? = nil,
                       resources: WindowResources,
                       limitations: [String] = []) -> WindowRecord {
        WindowRecord(id: id,
                     runtimeWindowID: 42,
                     appName: app,
                     bundleID: bundleID,
                     appVersion: "1.0",
                     title: title,
                     titleSource: "accessibility",
                     appKitFrame: RectRecord(frame),
                     displayRelativeFrame: RectRecord(frame),
                     windowServerFrame: RectRecord(frame),
                     fullScreenSignal: fullScreen,
                     accessibilityDocument: document,
                     resources: resources,
                     limitations: limitations)
    }

    static func browser(_ urls: [String?], selected: Int? = 1, titles: [String?] = []) -> WindowResources {
        let tabs = urls.enumerated().map { offset, url in
            BrowserTabRecord(index: offset + 1,
                             url: url,
                             title: offset < titles.count ? titles[offset] : "tab \(offset + 1)",
                             issue: url == nil ? "the address was not readable" : nil)
        }
        return WindowResources(kind: .browser,
                               status: .captured,
                               detail: nil,
                               browser: BrowserResource(scriptWindowID: 7,
                                                        selectedTabIndex: selected,
                                                        tabs: tabs,
                                                        privateWindowDetection: BrowserCapture.privateDetectionNote))
    }

    static func terminal(_ directories: [String?], selectedIndex: Int? = nil) -> WindowResources {
        let tabs = directories.enumerated().map { offset, directory in
            TerminalTabRecord(index: offset + 1,
                              tty: directory == nil ? nil : "/dev/ttys00\(offset)",
                              selected: selectedIndex.map { $0 == offset + 1 },
                              directory: directory,
                              directorySource: directory == nil ? nil : "foreground process group",
                              issue: directory == nil ? "the tab reported no tty" : nil)
        }
        return WindowResources(kind: .terminal,
                               status: .captured,
                               detail: nil,
                               terminal: TerminalResource(scriptWindowID: 3, tabs: tabs))
    }

    static func xcode(project: String?, activeFile: String? = nil) -> WindowResources {
        WindowResources(kind: .xcode,
                        status: project == nil ? .resourceNotIdentified : .captured,
                        detail: project == nil ? "window has no document" : nil,
                        xcode: XcodeResource(scriptWindowID: 9,
                                             workingDocumentPath: project,
                                             workingDocumentIssue: project == nil ? "window has no document" : nil,
                                             accessibilityActiveFile: activeFile))
    }

    static func jetBrains(project: String?,
                          candidates: [String] = [],
                          editorFiles: [String] = []) -> WindowResources {
        WindowResources(kind: .jetBrains,
                        status: project == nil ? .resourceNotIdentified : .captured,
                        detail: nil,
                        jetBrains: JetBrainsResource(projectPath: project,
                                                     matchProvenance: "the leading segment of the live window title matched exactly one recent project",
                                                     ambiguousCandidates: candidates,
                                                     titleFileHint: nil,
                                                     workspaceFile: nil,
                                                     editorFiles: editorFiles,
                                                     editorFileState: "persisted by the ide"))
    }

    static func snapshot(_ windows: [WindowRecord],
                         completeness: SnapshotCompleteness = .complete,
                         display: DisplayRecord? = nil) -> Snapshot {
        Snapshot(schemaVersion: SnapshotSchema.current,
                 id: SnapshotStore.newIdentifier(),
                 createdAt: Date(timeIntervalSince1970: 1_780_000_000),
                 name: "fixture",
                 completeness: completeness,
                 host: HostRecord(operatingSystem: "test os", anchorVersion: "1.0 (1)"),
                 display: display ?? SnapshotFixtures.display(),
                 windows: windows,
                 adapters: [],
                 issues: [])
    }

    // the same plan with its groups in a different order, for proving that execution
    // order comes from the coordinator and not from the order a plan happens to carry
    static func reordered(_ plan: RestorePlan, groups: [RestoreGroup]) -> RestorePlan {
        RestorePlan(id: plan.id,
                    snapshotID: plan.snapshotID,
                    snapshotName: plan.snapshotName,
                    snapshotCreatedAt: plan.snapshotCreatedAt,
                    completeness: plan.completeness,
                    source: plan.source,
                    destination: plan.destination,
                    groups: groups,
                    notes: plan.notes,
                    permissions: plan.permissions,
                    builtAt: plan.builtAt)
    }

    static func liveWindow(id: CGWindowID,
                           pid: pid_t = 501,
                           title: String? = nil,
                           document: String? = nil,
                           frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> LiveWindow {
        LiveWindow(id: id,
                   pid: pid,
                   title: title,
                   documentPath: document,
                   appKitFrame: frame,
                   serverFrame: frame)
    }
}

// a machine that only answers questions, and remembers every question it was asked
@MainActor
final class StubEnvironment: RestoreEnvironment {
    var accessibilityGranted = true
    var defaultFile: FileStatus = .present(isDirectory: true)
    var files: [String: FileStatus] = [:]
    var apps: [String: AppPresence] = [:]
    var defaultApp = AppPresence(installed: true, path: "/Applications/Test.app", running: true, pids: [501])
    var automation: [String: AutomationAccess] = [:]
    var defaultAutomation = AutomationAccess.granted
    var live: [String: [LiveWindow]] = [:]
    private(set) var fileQueries: [String] = []

    func fileStatus(_ path: String) -> FileStatus {
        fileQueries.append(path)
        return files[path] ?? defaultFile
    }

    func presence(of bundleID: String) -> AppPresence { apps[bundleID] ?? defaultApp }

    func automationStatus(of bundleID: String) -> AutomationAccess { automation[bundleID] ?? defaultAutomation }

    func liveWindows(bundleID: String) -> [LiveWindow] { live[bundleID] ?? [] }
}

// every operation a restore may perform, recorded and never really performed
// the protocol carries no close or quit, so a test cannot even ask for one
@MainActor
final class RecordingExecutor: RestoreExecutor {
    enum Call: Equatable {
        case automation(String)
        case browser(BrowserOpenRequest)
        case terminal(TerminalOpenRequest)
        case project(ProjectOpenRequest)
        case application(AppOpenRequest)
        case observe(String)
        case awaitProject(String)
        case place(CGWindowID, CGRect)
    }

    private(set) var calls: [Call] = []
    var automationAnswer = AutomationAccess.granted
    var live: [String: [LiveWindow]] = [:]
    var browserOutcome: (BrowserOpenRequest) -> ExecutionOutcome = { request in
        ExecutionOutcome(succeeded: true,
                         summary: "opened",
                         window: .reportedByApp(900),
                         items: Dictionary(uniqueKeysWithValues: request.tabs.map { ($0.itemID, ItemOutcome(state: .opened, detail: nil)) }))
    }
    var terminalOutcome: (TerminalOpenRequest) -> ExecutionOutcome = { request in
        ExecutionOutcome(succeeded: true,
                         summary: "opened",
                         window: .reportedByApp(901),
                         items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
    }
    var projectOutcome: (ProjectOpenRequest) -> ExecutionOutcome = { request in
        ExecutionOutcome(succeeded: true,
                         summary: "handed over",
                         window: .none("no window id"),
                         items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
    }
    var applicationOutcome: (AppOpenRequest) -> ExecutionOutcome = { request in
        ExecutionOutcome(succeeded: true,
                         summary: "opened",
                         window: .none("no window id"),
                         items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
    }
    var observation: WindowEvidence = .observed(902)
    // counted rather than recorded as a call, so existing call assertions keep their shape
    private(set) var liveWindowQueries = 0
    // a slow ide, for proving a quick window does not wait behind one
    var projectDelay: TimeInterval = 0
    var projectWindow: WindowEvidence = .observed(902)
    // live windows may differ per call, which is what a starting ide looks like
    var liveRounds: [String: [[LiveWindow]]] = [:]
    var placement: PlacementOutcome = .applied(requested: .zero, actual: .zero, adjustment: nil)
    var onOpen: (() -> Void)?
    // by default an application keeps the rectangle it was given
    var onPlace: ((CGWindowID, CGRect) -> Void)?

    func requestAutomation(bundleID: String) async -> AutomationAccess {
        calls.append(.automation(bundleID))
        return automationAnswer
    }

    func liveWindows(bundleID: String) -> [LiveWindow] {
        liveWindowQueries += 1
        if var rounds = liveRounds[bundleID], !rounds.isEmpty {
            let next = rounds.removeFirst()
            if !rounds.isEmpty { liveRounds[bundleID] = rounds }
            return next
        }
        return live[bundleID] ?? []
    }

    func openBrowserWindow(_ request: BrowserOpenRequest) async -> ExecutionOutcome {
        calls.append(.browser(request))
        onOpen?()
        return browserOutcome(request)
    }

    func openTerminalSession(_ request: TerminalOpenRequest) async -> ExecutionOutcome {
        calls.append(.terminal(request))
        onOpen?()
        return terminalOutcome(request)
    }

    func openProject(_ request: ProjectOpenRequest) async -> ExecutionOutcome {
        calls.append(.project(request))
        onOpen?()
        if projectDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(projectDelay * 1_000_000_000))
        }
        return projectOutcome(request)
    }

    func openApplication(_ request: AppOpenRequest) async -> ExecutionOutcome {
        calls.append(.application(request))
        onOpen?()
        return applicationOutcome(request)
    }

    func observeNewWindow(bundleID: String, excluding: Set<CGWindowID>, timeout: TimeInterval) async -> WindowEvidence {
        calls.append(.observe(bundleID))
        return observation
    }

    func awaitProjectWindow(_ request: ProjectOpenRequest,
                            excluding: Set<CGWindowID>,
                            timeout: TimeInterval) async -> WindowEvidence {
        calls.append(.awaitProject(request.projectName))
        return projectWindow
    }

    func place(windowID: CGWindowID, appKitFrame: CGRect) async -> PlacementOutcome {
        calls.append(.place(windowID, appKitFrame))
        if let onPlace {
            onPlace(windowID, appKitFrame)
        } else {
            keep(windowID, at: appKitFrame)
        }
        return placement
    }

    func keep(_ windowID: CGWindowID, at frame: CGRect) {
        for (bundleID, windows) in live {
            guard let index = windows.firstIndex(where: { $0.id == windowID }) else { continue }
            let existing = windows[index]
            live[bundleID]?[index] = LiveWindow(id: existing.id,
                                                pid: existing.pid,
                                                title: existing.title,
                                                documentPath: existing.documentPath,
                                                appKitFrame: frame,
                                                serverFrame: frame)
        }
    }

    var openCalls: [Call] {
        calls.filter { call in
            switch call {
            case .browser, .terminal, .project, .application: return true
            default: return false
            }
        }
    }

    var placeCalls: [Call] {
        calls.filter { if case .place = $0 { return true }; return false }
    }
}
