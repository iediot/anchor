import AppKit

// turns one saved state plus the current destination into an immutable plan
// preflight is read only, nothing here launches an app, opens a window, touches a project
// or asks the network whether a saved address still resolves
enum RestorePlanner {
    static let previewNote = "this preview is the confirmation. nothing is closed or opened until you choose one of the actions at the end of it"

    static func build(snapshot: Snapshot,
                      destination: DestinationDisplay,
                      environment: RestoreEnvironment) -> RestorePlan {
        var notes: [PlanNote] = []
        notes.append(PlanNote(.note, RestorePlanner.previewNote))
        notes.append(PlanNote(.note, "nothing has been opened, closed or saved yet, this preview reads saved records, local paths and installed applications only"))

        if snapshot.completeness != .complete {
            notes.append(PlanNote(.limitation, "the saved state itself is a \(SavedStatesFormat.completeness(snapshot.completeness)), so it describes less than the screen held. a complete record is still not a promise that reopening succeeds"))
        }
        if !environment.accessibilityGranted {
            notes.append(PlanNote(.blocker, "accessibility is not granted, so anchor cannot place any window and every layout is skipped"))
        }
        if snapshot.display.displayID != destination.displayID {
            notes.append(PlanNote(.limitation, "this state was saved on \(snapshot.display.name) and would be reopened on \(destination.name)"))
        }
        notes.append(PlanNote(.limitation, "anchor places windows on the destination display only. it does not move windows between desktops and cannot promise which desktop an application opens a window on"))

        var groups: [RestoreGroup] = []
        var seen: [String] = []
        var byApp: [String: [WindowRecord]] = [:]
        for window in snapshot.windows {
            let key = window.bundleID ?? window.appName
            if byApp[key] == nil { seen.append(key) }
            byApp[key, default: []].append(window)
        }

        for key in seen {
            let records = byApp[key] ?? []
            guard let first = records.first else { continue }
            let bundleID = first.bundleID
            let integration = IntegrationKind.matching(bundleID: bundleID)
            let presence = bundleID.map(environment.presence) ?? .notInstalled
            let automation = bundleID.map(environment.automationStatus) ?? .undetermined
            let windows = records.map { record in
                window(record,
                       integration: integration,
                       presence: presence,
                       automation: automation,
                       snapshot: snapshot,
                       destination: destination,
                       environment: environment)
            }
            let scripted = windows.contains { $0.action.needsAutomation }
            groups.append(RestoreGroup(id: key,
                                       appName: first.appName,
                                       bundleID: bundleID,
                                       kind: first.resources.kind,
                                       appDetail: appDetail(presence: presence,
                                                            automation: automation,
                                                            integration: integration,
                                                            scripted: scripted),
                                       windows: windows))
        }

        if groups.contains(where: { KnownIssues.affectsPyCharm(bundleID: $0.bundleID) }) {
            notes.append(PlanNote(.limitation, KnownIssues.pycharm))
        }

        for group in groups where group.needsAutomation {
            if let bundleID = group.bundleID, environment.automationStatus(of: bundleID) == .undetermined {
                notes.append(PlanNote(.note, "anchor will ask for permission to control \(group.appName) when you confirm, and will report the affected items if you refuse"))
            }
        }

        // the preview lists what happens in the order it will happen
        let ordered = RestoreExecutionOrder.ordered(groups)
        if ordered.count > 1 {
            notes.append(PlanNote(.note, RestoreExecutionOrder.note))
        }

        let automationDetail = Dictionary(uniqueKeysWithValues: groups.compactMap { group -> (String, String)? in
            guard let bundleID = group.bundleID else { return nil }
            return (bundleID, environment.automationStatus(of: bundleID).label)
        })

        return RestorePlan(id: UUID().uuidString,
                           snapshotID: snapshot.id,
                           snapshotName: snapshot.name,
                           snapshotCreatedAt: snapshot.createdAt,
                           completeness: snapshot.completeness,
                           source: snapshot.display,
                           destination: destination,
                           groups: ordered,
                           notes: notes,
                           permissions: PlanPermissions(accessibilityGranted: environment.accessibilityGranted,
                                                        automation: automationDetail),
                           builtAt: Date())
    }

    private static func appDetail(presence: AppPresence,
                                  automation: AutomationAccess,
                                  integration: IntegrationKind?,
                                  scripted: Bool) -> String {
        guard integration != nil else { return "\(presence.detail), anchor has no adapter for this application" }
        guard scripted else { return "\(presence.detail), opened through the installed application itself" }
        return "\(presence.detail), automation \(automation.label)"
    }

    // one saved window becomes one intended action, one layout and its items
    private static func window(_ record: WindowRecord,
                               integration: IntegrationKind?,
                               presence: AppPresence,
                               automation: AutomationAccess,
                               snapshot: Snapshot,
                               destination: DestinationDisplay,
                               environment: RestoreEnvironment) -> RestorePlanWindow {
        var items: [RestorePlanItem] = []
        var limitations = record.limitations
        var action = RestoreAction.nothing("anchor has no supported way to reopen this window")

        let blocked = blockingReason(record: record,
                                     integration: integration,
                                     presence: presence,
                                     automation: automation)

        if let blocked {
            items.append(RestorePlanItem(id: "\(record.id).blocked",
                                         kind: itemKind(record.resources.kind),
                                         title: title(record),
                                         detail: nil,
                                         status: blocked.status))
            action = .nothing(blocked.summary)
        } else if let integration {
            let built = build(record: record,
                              integration: integration,
                              environment: environment)
            items = built.items
            action = built.action
            limitations.append(contentsOf: built.limitations)
        }

        let layout = LayoutMapping.map(window: record, source: snapshot.display, destination: destination)
        if action.isActionable {
            items.append(layoutItem(record: record,
                                    layout: layout,
                                    accessibilityGranted: environment.accessibilityGranted))
        }

        return RestorePlanWindow(id: record.id,
                                 appName: record.appName,
                                 bundleID: record.bundleID,
                                 title: record.title,
                                 sourceFrame: record.displayRelativeFrame,
                                 action: action,
                                 layout: layout,
                                 items: items,
                                 limitations: limitations)
    }

    private struct Blocked {
        let status: RestoreItemStatus
        let summary: String
    }

    // why a window is not reopened at all, decided before any resource is looked at
    private static func blockingReason(record: WindowRecord,
                                       integration: IntegrationKind?,
                                       presence: AppPresence,
                                       automation: AutomationAccess) -> Blocked? {
        let resources = record.resources
        if resources.kind == .unsupported || integration == nil {
            let detail = "anchor has no adapter for \(record.appName), so this window was saved as geometry only and anchor will not launch the application and call that a restored state"
            return Blocked(status: .unsupported(detail), summary: detail)
        }
        guard let integration else { return nil }
        if !presence.installed {
            let detail = "\(integration.displayName) is not installed on this mac"
            return Blocked(status: .appUnavailable(detail), summary: detail)
        }
        switch resources.status {
        case .captured, .capturedEmpty:
            break
        case .omittedByUser:
            let detail = resources.detail ?? "this window's content was left out of the save at your request"
            return Blocked(status: .omittedAtCapture(detail), summary: detail)
        case .windowNotResolved, .resourceNotIdentified:
            let detail = resources.detail ?? "the saved window's content could not be tied to this window when it was captured"
            return Blocked(status: .ambiguousIdentity(detail), summary: detail)
        default:
            let detail = resources.detail ?? resources.status.label
            return Blocked(status: .omittedAtCapture(detail), summary: detail)
        }
        // only the scripted applications need automation consent to reopen anything
        if resources.kind == .browser || resources.kind == .terminal, automation == .denied {
            let detail = "automation for \(integration.displayName) is denied in privacy settings, so anchor cannot ask it to open anything"
            return Blocked(status: .permissionNeeded(detail), summary: detail)
        }
        if resources.status == .capturedEmpty {
            let detail = resources.detail ?? "the adapter ran and \(integration.displayName) reported nothing to reopen for this window"
            return Blocked(status: .omittedAtCapture(detail), summary: detail)
        }
        return nil
    }

    private struct Built {
        var action: RestoreAction
        var items: [RestorePlanItem]
        var limitations: [String]
    }

    private static func build(record: WindowRecord,
                              integration: IntegrationKind,
                              environment: RestoreEnvironment) -> Built {
        switch record.resources.kind {
        case .browser: return browser(record, integration: integration, environment: environment)
        case .terminal: return terminal(record, integration: integration, environment: environment)
        case .xcode: return xcode(record, integration: integration, environment: environment)
        case .jetBrains: return jetBrains(record, integration: integration, environment: environment)
        case .unsupported: return Built(action: .nothing("no adapter"), items: [], limitations: [])
        }
    }

    private static func browser(_ record: WindowRecord,
                                integration: IntegrationKind,
                                environment: RestoreEnvironment) -> Built {
        guard let resource = record.resources.browser else {
            return Built(action: .nothing("no tab was saved for this window"), items: [], limitations: [])
        }
        var items: [RestorePlanItem] = []
        var tabs: [RestoreTab] = []
        var selected: Int?

        for tab in resource.tabs {
            let id = "\(record.id).tab.\(tab.index)"
            let label = tab.title ?? tab.url ?? "tab \(tab.index)"
            let decision = ResourceValidation.decideTab(url: tab.url, fileStatus: environment.fileStatus)
            let status: RestoreItemStatus
            var content: RestoreTabContent?
            switch decision {
            case .blank:
                status = .ready
                content = .blank
            case .web(let url):
                status = .ready
                content = .web(url)
            case .localFile(let url):
                status = .readyWithLimitation("a local file, opened as a file address")
                content = .localFile(url)
            case .unsupported(let reason): status = .unsupportedScheme(reason)
            case .malformed(let reason): status = .malformed(reason)
            case .missing(let path): status = .missingPath("no file exists at \(path) any more")
            case .inaccessible(let reason): status = .inaccessiblePath(reason)
            }
            items.append(RestorePlanItem(id: id,
                                         kind: decision == .blank ? .blankTab : .browserTab,
                                         title: label,
                                         detail: tab.url ?? tab.issue,
                                         status: status))
            if let content {
                if tab.index == resource.selectedTabIndex { selected = tabs.count + 1 }
                tabs.append(RestoreTab(itemID: id, content: content, sourceIndex: tab.index))
            }
        }

        var limitations: [String] = []
        if resource.selectedTabIndex != nil, selected == nil, !tabs.isEmpty {
            limitations.append("the tab that was selected when this state was saved cannot be reopened, so the new window opens on its first tab")
        }
        guard !tabs.isEmpty else {
            return Built(action: .nothing("no tab in this window can be reopened"), items: items, limitations: limitations)
        }
        limitations.append("a new \(integration.displayName) window is created for this saved window, existing windows are left alone and tabs are never merged into them")
        return Built(action: .openBrowserWindow(BrowserOpenRequest(app: integration, tabs: tabs, selectedTab: selected)),
                     items: items,
                     limitations: limitations)
    }

    private static func terminal(_ record: WindowRecord,
                                 integration: IntegrationKind,
                                 environment: RestoreEnvironment) -> Built {
        guard let resource = record.resources.terminal else {
            return Built(action: .nothing("no session was saved for this window"), items: [], limitations: [])
        }
        // one saved window becomes one new window, because neither terminal exposes a tab
        // creation anchor has verified, and typing into a session to fake one is not allowed
        let groupingLimitation = "\(integration.displayName) exposes no tab creation anchor has verified, so anchor opens one new window for this saved window and reports the other saved sessions rather than pretending to group them"

        let decisions = resource.tabs.map { tab in
            (tab, ResourceValidation.decideDirectory(tab.directory, fileStatus: environment.fileStatus))
        }
        // the session that was selected wins, otherwise the first one with a usable directory
        let readyIndexes = decisions.indices.filter { index in
            if case .ready = decisions[index].1 { return true }
            return false
        }
        let chosenIndex = readyIndexes.first { decisions[$0].0.selected == true } ?? readyIndexes.first

        var items: [RestorePlanItem] = []
        var chosen: (id: String, directory: String)?
        for (offset, entry) in decisions.enumerated() {
            let (tab, decision) = entry
            let id = "\(record.id).session.\(tab.index)"
            let label = tab.directory.map { ($0 as NSString).lastPathComponent } ?? "session \(tab.index)"
            let status: RestoreItemStatus
            switch decision {
            case .ready(let path):
                if offset == chosenIndex {
                    chosen = (id, path)
                    status = .ready
                } else {
                    status = .unsupported(groupingLimitation)
                }
            case .missing(let reason): status = .missingPath(reason)
            case .inaccessible(let reason): status = .inaccessiblePath(reason)
            case .malformed(let reason):
                status = tab.directory == nil
                    ? .omittedAtCapture(tab.issue ?? "no directory was captured for this session")
                    : .malformed(reason)
            }
            items.append(RestorePlanItem(id: id,
                                         kind: .terminalSession,
                                         title: label,
                                         detail: tab.directory ?? tab.issue,
                                         status: status))
        }

        guard let chosen else {
            return Built(action: .nothing("no saved session in this window has a directory anchor can open"),
                         items: items,
                         limitations: [])
        }
        var limitations = ["a new \(integration.displayName) window is opened at the saved directory. anchor never types into an existing session and never resumes a saved command, an ssh session, tmux or anything that was running"]
        if readyIndexes.count > 1 {
            limitations.append(groupingLimitation)
        }
        return Built(action: .openTerminalSession(TerminalOpenRequest(app: integration,
                                                                     itemID: chosen.id,
                                                                     directory: chosen.directory)),
                     items: items,
                     limitations: limitations)
    }

    private static func xcode(_ record: WindowRecord,
                              integration: IntegrationKind,
                              environment: RestoreEnvironment) -> Built {
        guard let resource = record.resources.xcode else {
            return Built(action: .nothing("no project was saved for this window"), items: [], limitations: [])
        }
        var items: [RestorePlanItem] = []
        let projectID = "\(record.id).project"
        let decision = ResourceValidation.decideProject(resource.workingDocumentPath, fileStatus: environment.fileStatus)
        var action = RestoreAction.nothing("no project path was saved for this window")
        var limitations: [String] = []

        switch decision {
        case .ready(let path):
            let name = (path as NSString).lastPathComponent
            items.append(RestorePlanItem(id: projectID,
                                         kind: .project,
                                         title: name,
                                         detail: path,
                                         status: .ready))
            action = .openProject(ProjectOpenRequest(app: integration, itemID: projectID, path: path, projectName: name))
            limitations.append("xcode may reuse a window it already has open for this project rather than creating a new one. anchor reports reuse and never moves a window that is open somewhere else")
        case .missing(let reason):
            items.append(item(projectID, .project, resource.workingDocumentPath, .missingPath(reason)))
            action = .nothing(reason)
        case .inaccessible(let reason):
            items.append(item(projectID, .project, resource.workingDocumentPath, .inaccessiblePath(reason)))
            action = .nothing(reason)
        case .malformed(let reason):
            let detail = resource.workingDocumentIssue ?? reason
            items.append(item(projectID, .project, resource.workingDocumentPath, .malformed(detail)))
            action = .nothing(detail)
        }

        if let file = resource.accessibilityActiveFile {
            let status: RestoreItemStatus
            switch ResourceValidation.decideProject(file, fileStatus: environment.fileStatus) {
            case .ready:
                status = .unsupported("anchor has no verified way to open a file in the intended project window, so the project is opened and xcode decides which files it shows")
            case .missing(let reason): status = .missingPath(reason)
            case .inaccessible(let reason): status = .inaccessiblePath(reason)
            case .malformed(let reason): status = .malformed(reason)
            }
            items.append(RestorePlanItem(id: "\(record.id).activeFile",
                                         kind: .activeFile,
                                         title: (file as NSString).lastPathComponent,
                                         detail: file,
                                         status: status))
        }
        return Built(action: action, items: items, limitations: limitations)
    }

    private static func jetBrains(_ record: WindowRecord,
                                  integration: IntegrationKind,
                                  environment: RestoreEnvironment) -> Built {
        guard let resource = record.resources.jetBrains else {
            return Built(action: .nothing("no project was saved for this window"), items: [], limitations: [])
        }
        var items: [RestorePlanItem] = []
        let projectID = "\(record.id).project"
        var action = RestoreAction.nothing("no project was identified for this window")
        var limitations: [String] = []

        // an older snapshot can hold a project matched from a welcome window title, so the
        // saved record is judged again here rather than trusted
        if let reason = JetBrainsWindowTitle.role(record: record).welcomeReason {
            let detail = "\(reason). anchor will not open a project for it, and reopening this saved state leaves the ide alone"
            items.append(item(projectID, .project, resource.projectPath, .unsupported(detail)))
            return Built(action: .nothing(detail), items: items, limitations: [])
        }

        if resource.projectPath == nil, !resource.ambiguousCandidates.isEmpty {
            let detail = "\(resource.ambiguousCandidates.count) recent projects share this window's name, so none was saved as its project"
            items.append(item(projectID, .project, nil, .ambiguousIdentity(detail)))
            action = .nothing(detail)
        } else {
            switch ResourceValidation.decideProject(resource.projectPath, fileStatus: environment.fileStatus) {
            case .ready(let path):
                let name = (path as NSString).lastPathComponent
                items.append(RestorePlanItem(id: projectID,
                                             kind: .project,
                                             title: name,
                                             detail: path,
                                             status: .readyWithLimitation("the project match is a heuristic from the window title and the ide's recent projects file")))
                action = .openProject(ProjectOpenRequest(app: integration, itemID: projectID, path: path, projectName: name))
                limitations.append(resource.matchProvenance)
                limitations.append("the ide may reuse a window it already has open for this project. anchor reports reuse and never moves or edits a window that is open somewhere else")
                limitations.append("the ide restores its own editor state when it opens a project, which is not the same as anchor recovering the saved list of files")
            case .missing(let reason):
                items.append(item(projectID, .project, resource.projectPath, .missingPath(reason)))
                action = .nothing(reason)
            case .inaccessible(let reason):
                items.append(item(projectID, .project, resource.projectPath, .inaccessiblePath(reason)))
                action = .nothing(reason)
            case .malformed(let reason):
                items.append(item(projectID, .project, resource.projectPath, .malformed(reason)))
                action = .nothing(reason)
            }
        }

        for (offset, file) in resource.editorFiles.enumerated() {
            let status: RestoreItemStatus
            switch ResourceValidation.decideProject(file, fileStatus: environment.fileStatus) {
            case .ready:
                status = .unsupported("anchor has no verified way to open a saved file list in a jetbrains project without rewriting the ide's own workspace file, which it never does")
            case .missing(let reason): status = .missingPath(reason)
            case .inaccessible(let reason): status = .inaccessiblePath(reason)
            case .malformed(let reason): status = .malformed(reason)
            }
            items.append(RestorePlanItem(id: "\(record.id).editorFile.\(offset)",
                                         kind: .editorFile,
                                         title: (file as NSString).lastPathComponent,
                                         detail: file,
                                         status: status))
        }
        return Built(action: action, items: items, limitations: limitations)
    }

    private static func layoutItem(record: WindowRecord,
                                   layout: LayoutPlan,
                                   accessibilityGranted: Bool) -> RestorePlanItem {
        let status: RestoreItemStatus
        switch layout {
        case .unavailable(let reason):
            status = .malformed(reason)
        case .mapped(let mapped):
            if !accessibilityGranted {
                status = .permissionNeeded("accessibility is needed before anchor can move or size a window")
            } else if record.fullScreenSignal != FullScreenSignal.ordinary.rawValue {
                status = .readyWithLimitation("this window was saved as \(record.fullScreenSignal). anchor does not reconstruct native fullscreen or split view and will place an ordinary window at \(RectRecord(mapped.appKitFrame).summary)")
            } else if mapped.wasScaled || mapped.wasClamped {
                status = .readyWithLimitation(mapped.notes.joined(separator: ", "))
            } else {
                status = .ready
            }
        }
        return RestorePlanItem(id: "\(record.id).layout",
                               kind: .layout,
                               title: "window layout",
                               detail: layout.summary,
                               status: status)
    }

    private static func item(_ id: String,
                             _ kind: RestoreItemKind,
                             _ detail: String?,
                             _ status: RestoreItemStatus) -> RestorePlanItem {
        RestorePlanItem(id: id,
                        kind: kind,
                        title: detail.map { ($0 as NSString).lastPathComponent } ?? kind.label,
                        detail: detail,
                        status: status)
    }

    private static func itemKind(_ kind: ResourceKind) -> RestoreItemKind {
        switch kind {
        case .browser: return .browserTab
        case .terminal: return .terminalSession
        case .jetBrains, .xcode: return .project
        case .unsupported: return .window
        }
    }

    private static func title(_ record: WindowRecord) -> String {
        record.title ?? record.appName
    }
}
