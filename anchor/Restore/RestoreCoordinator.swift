import AppKit

// runs one plan, one item at a time, and reports what actually happened
// it never closes, quits or rolls back anything, and it never repeats a creation command
// after a timeout because the application may already have carried it out
@MainActor
@Observable
final class RestoreCoordinator {
    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
    }

    enum WindowState: String {
        case pending
        case running
        case opened
        case reused
        case skipped
        case failed
        case cancelled
    }

    struct ItemReport: Identifiable, Equatable {
        let id: String
        let kind: RestoreItemKind
        let title: String
        var state: ItemOutcome.State
        var detail: String?
    }

    struct WindowReport: Identifiable, Equatable {
        let id: String
        let appName: String
        let title: String?
        var state: WindowState
        var summary: String
        var evidence: String?
        var placement: String?
        var items: [ItemReport]
    }

    private(set) var phase: Phase = .idle
    private(set) var reports: [WindowReport] = []
    private(set) var planID: String?
    private(set) var snapshotName: String?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var cancelRequested = false

    var isRunning: Bool { phase == .running }

    var summary: String {
        let opened = reports.filter { $0.state == .opened || $0.state == .reused }.count
        let failed = reports.filter { $0.state == .failed }.count
        let skipped = reports.filter { $0.state == .skipped }.count
        let cancelled = reports.filter { $0.state == .cancelled }.count
        var parts = ["\(opened) of \(reports.count) windows opened"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if cancelled > 0 { parts.append("\(cancelled) never started because you cancelled") }
        return parts.joined(separator: ", ")
    }

    func cancel() {
        guard phase == .running else { return }
        cancelRequested = true
    }

    func run(plan: RestorePlan, executor: RestoreExecutor) async {
        guard phase != .running else { return }
        prepare(plan)
        phase = .running

        outer: for group in plan.groups {
            let actionable = group.windows.filter(\.isActionable)
            guard !actionable.isEmpty else { continue }
            if cancelRequested { break }

            var blocked: String?
            if let bundleID = group.bundleID, group.needsAutomation {
                let access = await executor.requestAutomation(bundleID: bundleID)
                if access != .granted {
                    blocked = "permission to control \(group.appName) is \(access.label), so nothing was opened for it"
                }
            }

            for window in actionable {
                if cancelRequested { break outer }
                if let blocked {
                    finish(window.id, state: .failed, summary: blocked, items: plannedItems(window, state: .skipped, detail: blocked))
                    continue
                }
                await perform(window, group: group, plan: plan, executor: executor)
            }
        }
        conclude()
    }

    private func prepare(_ plan: RestorePlan) {
        cancelRequested = false
        planID = plan.id
        snapshotName = plan.snapshotName
        startedAt = Date()
        finishedAt = nil
        reports = plan.actionableWindows.map { window in
            WindowReport(id: window.id,
                         appName: window.appName,
                         title: window.title,
                         state: .pending,
                         summary: window.action.summary,
                         evidence: nil,
                         placement: nil,
                         items: window.items.map { item in
                             ItemReport(id: item.id,
                                        kind: item.kind,
                                        title: item.title,
                                        state: .skipped,
                                        detail: item.status.isActionable ? "waiting" : item.status.label)
                         })
        }
    }

    private func conclude() {
        for index in reports.indices where reports[index].state == .pending || reports[index].state == .running {
            reports[index].state = .cancelled
            reports[index].summary = "not started, you cancelled before anchor reached it. windows already opened stay open"
        }
        finishedAt = Date()
        phase = cancelRequested ? .cancelled : .finished
    }

    private func perform(_ window: RestorePlanWindow,
                         group: RestoreGroup,
                         plan: RestorePlan,
                         executor: RestoreExecutor) async {
        mark(window.id, .running, "running")
        let bundleID = group.bundleID ?? ""
        let before = Set(executor.liveWindows(bundleID: bundleID).map(\.id))

        if case .openProject(let request) = window.action {
            let finding = RestoreReuse.find(request: request,
                                            among: executor.liveWindows(bundleID: bundleID),
                                            destination: plan.destination,
                                            accessibilityGranted: plan.permissions.accessibilityGranted)
            switch finding {
            case .onDestination(let id, let reason):
                var items = plannedItems(window, state: .opened, detail: nil)
                setItem(&items, request.itemID, .opened, "the project was already open on this display")
                finish(window.id,
                       state: .reused,
                       summary: "\(request.projectName) was already open on \(plan.destination.name), so anchor reused that window and opened nothing",
                       items: items,
                       evidence: reason)
                await applyLayout(window, windowID: id, plan: plan, executor: executor)
                return
            case .elsewhere(let reason):
                let detail = "\(request.projectName) is already open outside the destination display. anchor left that window where it is and did not touch its editor state"
                finish(window.id,
                       state: .skipped,
                       summary: detail,
                       items: plannedItems(window, state: .skipped, detail: detail),
                       evidence: reason)
                return
            case .ambiguous(let reason):
                finish(window.id,
                       state: .skipped,
                       summary: "anchor could not tell which existing window belongs to \(request.projectName), so it opened nothing",
                       items: plannedItems(window, state: .skipped, detail: reason),
                       evidence: reason)
                return
            case .notOpen:
                break
            }
        }

        let outcome: ExecutionOutcome
        switch window.action {
        case .openBrowserWindow(let request): outcome = await executor.openBrowserWindow(request)
        case .openTerminalSession(let request): outcome = await executor.openTerminalSession(request)
        case .openProject(let request): outcome = await executor.openProject(request)
        case .nothing(let reason):
            finish(window.id, state: .skipped, summary: reason, items: plannedItems(window, state: .skipped, detail: reason))
            return
        }

        var items = plannedItems(window, state: outcome.succeeded ? .opened : .failed, detail: nil)
        for (id, result) in outcome.items {
            setItem(&items, id, result.state, result.detail)
        }

        var evidence = outcome.window
        if evidence.windowID == nil, outcome.succeeded {
            if case .openProject(let request) = window.action {
                // an ide opens a splash first, so the wait is longer and the window has
                // to carry the project before anchor will touch it
                evidence = await executor.awaitProjectWindow(request, excluding: before, timeout: 40)
            } else {
                evidence = await executor.observeNewWindow(bundleID: bundleID, excluding: before, timeout: 8)
            }
        }
        finish(window.id,
               state: outcome.succeeded ? .opened : .failed,
               summary: outcome.summary,
               items: items,
               evidence: evidence.label)

        guard outcome.succeeded, let identified = evidence.windowID else { return }
        guard !cancelRequested else {
            record(placement: "no layout was applied, you cancelled while anchor was waiting for this window",
                   on: window.id,
                   state: .skipped)
            return
        }
        await applyLayout(window, windowID: identified, plan: plan, executor: executor)
    }

    // only a window this operation created, or one confidently reused on the destination,
    // is ever moved, and never one the application put on another display
    private func applyLayout(_ window: RestorePlanWindow,
                             windowID: CGWindowID,
                             plan: RestorePlan,
                             executor: RestoreExecutor) async {
        guard let frame = window.layout.frame else {
            record(placement: window.layout.summary, on: window.id, state: .skipped)
            return
        }
        guard plan.permissions.accessibilityGranted else {
            record(placement: "no layout was applied, accessibility is not granted",
                   on: window.id,
                   state: .skipped)
            return
        }
        let live = executor.liveWindows(bundleID: window.bundleID ?? "").first { $0.id == windowID }
        if let live, !RestoreReuse.isOn(plan.destination, frame: live.appKitFrame) {
            record(placement: "the application put this window outside \(plan.destination.name), so anchor left it alone rather than dragging it across",
                   on: window.id,
                   state: .skipped)
            return
        }
        let outcome = await executor.place(windowID: windowID, appKitFrame: frame)
        guard case .applied = outcome else {
            record(placement: outcome.label, on: window.id, state: .failed)
            return
        }
        let settled = await settle(windowID: windowID,
                                   bundleID: window.bundleID ?? "",
                                   requested: frame,
                                   executor: executor)
        record(placement: settled.text, on: window.id, state: settled.state)
    }

    // an application can accept a rectangle and then move the window itself while it is
    // still starting, so the result is read again once and corrected at most once
    private func settle(windowID: CGWindowID,
                        bundleID: String,
                        requested: CGRect,
                        executor: RestoreExecutor) async -> (text: String, state: ItemOutcome.State) {
        let asked = RectRecord(requested).summary
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let first = frame(of: windowID, bundleID: bundleID, executor: executor) else {
            return ("requested \(asked), the application accepted it, and anchor could not read the window back to confirm where it ended up", .opened)
        }
        guard let drift = LayoutMapping.describeAdjustment(requested: requested, actual: first) else {
            return ("requested \(asked) and the application kept it", .opened)
        }
        let again = await executor.place(windowID: windowID, appKitFrame: requested)
        guard case .applied = again else {
            return ("requested \(asked), \(drift), and a second attempt was refused: \(again.label)", .failed)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let second = frame(of: windowID, bundleID: bundleID, executor: executor) else {
            return ("requested \(asked), \(drift), and the window stopped being listed before anchor could confirm the correction", .opened)
        }
        guard let stillDrifting = LayoutMapping.describeAdjustment(requested: requested, actual: second) else {
            return ("requested \(asked), the application moved it once while it was starting and anchor put it back", .opened)
        }
        return ("requested \(asked), \(stillDrifting), and anchor left it there rather than fighting the application", .failed)
    }

    private func frame(of windowID: CGWindowID, bundleID: String, executor: RestoreExecutor) -> CGRect? {
        executor.liveWindows(bundleID: bundleID).first { $0.id == windowID }?.appKitFrame
    }

    private func plannedItems(_ window: RestorePlanWindow,
                              state: ItemOutcome.State,
                              detail: String?) -> [ItemReport] {
        window.items.map { item in
            ItemReport(id: item.id,
                       kind: item.kind,
                       title: item.title,
                       state: item.status.isActionable ? state : .skipped,
                       detail: item.status.isActionable ? detail : item.status.label)
        }
    }

    private func setItem(_ items: inout [ItemReport], _ id: String, _ state: ItemOutcome.State, _ detail: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        items[index].detail = detail
    }

    private func mark(_ id: String, _ state: WindowState, _ summary: String) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[index].state = state
        reports[index].summary = summary
    }

    private func finish(_ id: String,
                        state: WindowState,
                        summary: String,
                        items: [ItemReport],
                        evidence: String? = nil) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[index].state = state
        reports[index].summary = summary
        reports[index].items = items
        reports[index].evidence = evidence
    }

    private func record(placement text: String, on id: String, state: ItemOutcome.State) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[index].placement = text
        guard let item = reports[index].items.firstIndex(where: { $0.kind == .layout }) else { return }
        reports[index].items[item].state = state
        reports[index].items[item].detail = text
    }
}

// whether an application already has the project open, and where
enum RestoreReuse {
    enum Finding: Equatable {
        case notOpen
        case onDestination(CGWindowID, String)
        case elsewhere(String)
        case ambiguous(String)
    }

    static func isOn(_ display: DestinationDisplay, frame: CGRect) -> Bool {
        let overlap = display.frame.intersection(frame)
        guard !overlap.isNull, frame.width > 0, frame.height > 0 else { return false }
        return overlap.width * overlap.height > frame.width * frame.height / 2
    }

    static func find(request: ProjectOpenRequest,
                     among live: [LiveWindow],
                     destination: DestinationDisplay,
                     accessibilityGranted: Bool) -> Finding {
        let matches = live.compactMap { window -> (LiveWindow, String)? in
            guard let reason = ProjectWindowIdentity.evidence(request: request,
                                                              window: window,
                                                              accessibilityGranted: accessibilityGranted) else { return nil }
            return (window, reason)
        }
        guard !matches.isEmpty else { return .notOpen }
        guard matches.count == 1, let match = matches.first else {
            return .ambiguous("\(matches.count) open windows look like \(request.projectName)")
        }
        if isOn(destination, frame: match.0.appKitFrame) {
            return .onDestination(match.0.id, match.1)
        }
        return .elsewhere(match.1)
    }
}
