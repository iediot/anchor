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
    private(set) var log = OperationLog()

    // a plain open waits for nothing while other applications are still being asked to
    // open, so its window is looked for once every launch has been requested
    static let genericReadiness: TimeInterval = 6
    // an application that was already running may reuse a window rather than open one,
    // so a new window is given this long to appear before a reused one is considered
    static let freshWindowGrace: TimeInterval = 1.5

    private struct PendingPlacement {
        let window: RestorePlanWindow
        let bundleID: String
        let before: Set<CGWindowID>
    }

    private var pending: [PendingPlacement] = []

    var isRunning: Bool { phase == .running }

    // every open this run asked for, so a repeated window can be attributed
    var launchRequests: Int { log.launchRequests }

    var report: String { log.lines().joined(separator: "\n") }

    // opened, and then the layout could not be applied to it
    var notPlaced: Int {
        reports.filter { report in
            guard report.state == .opened || report.state == .reused else { return false }
            return report.items.contains { $0.kind == .layout && $0.state == .failed }
        }.count
    }

    var summary: String {
        let opened = reports.filter { $0.state == .opened || $0.state == .reused }.count
        let failed = reports.filter { $0.state == .failed }.count
        let skipped = reports.filter { $0.state == .skipped }.count
        let cancelled = reports.filter { $0.state == .cancelled }.count
        var parts = ["\(opened) of \(reports.count) windows opened"]
        if failed > 0 { parts.append("\(failed) failed") }
        // a window that opened and then would not take its rectangle is a partial success,
        // so it is counted here rather than disappearing into the opened total
        if notPlaced > 0 { parts.append("\(notPlaced) opened but not placed as asked") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if cancelled > 0 { parts.append("\(cancelled) never started because you cancelled") }
        return parts.joined(separator: ", ")
    }

    func cancel() {
        guard phase == .running else { return }
        cancelRequested = true
    }

    func run(plan: RestorePlan, executor: RestoreExecutor, operationID: String? = nil, trigger: String? = nil) async {
        guard phase != .running else { return }
        let groups = RestoreExecutionOrder.ordered(plan.groups)
        log.begin(id: operationID ?? OperationID.make(), trigger: trigger)
        log.record("reopen", "\(plan.actionableWindowCount) windows to open on \(plan.destination.name)")
        prepare(plan, groups: groups)
        phase = .running
        // whatever way this run leaves, it concludes, so the panel is never left busy
        defer { conclude() }

        outer: for group in groups {
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
        // every launch has been asked for by now, so this holds nothing up
        await placePending(plan: plan, executor: executor)
    }

    private func prepare(_ plan: RestorePlan, groups: [RestoreGroup]) {
        cancelRequested = false
        pending = []
        planID = plan.id
        snapshotName = plan.snapshotName
        startedAt = Date()
        finishedAt = nil
        // the report list is built in execution order so reading it top down is what happens
        reports = groups.flatMap(\.windows).filter(\.isActionable).map { window in
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
        log.record("reopen finished", summary)
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
                log.record("reuse", "\(window.appName) window \(id) was already open, nothing was launched")
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
        // one open per window of one confirmed run, counted where it is issued
        switch window.action {
        case .openBrowserWindow(let request):
            log.countLaunch()
            log.record("open", "\(window.appName) window, request \(log.launchRequests)")
            outcome = await executor.openBrowserWindow(request)
        case .openTerminalSession(let request):
            log.countLaunch()
            log.record("open", "\(window.appName) window, request \(log.launchRequests)")
            outcome = await executor.openTerminalSession(request)
        case .openProject(let request):
            log.countLaunch()
            log.record("open", "\(request.projectName) in \(window.appName), request \(log.launchRequests)")
            outcome = await executor.openProject(request)
        case .openApplication(let request):
            log.countLaunch()
            log.record("open", "\(window.appName), request \(log.launchRequests)")
            outcome = await executor.openApplication(request)
        case .nothing(let reason):
            finish(window.id, state: .skipped, summary: reason, items: plannedItems(window, state: .skipped, detail: reason))
            return
        }

        log.record("launch", outcome.succeeded
            ? "\(window.appName) took the open"
            : "\(window.appName) did not open anything")

        var items = plannedItems(window, state: outcome.succeeded ? .opened : .failed, detail: nil)
        for (id, result) in outcome.items {
            setItem(&items, id, result.state, result.detail)
        }

        var evidence = outcome.window
        if evidence.windowID == nil, outcome.succeeded {
            switch window.action {
            case .openProject(let request):
                // an ide opens a splash first, so the wait is longer and the window has
                // to carry the project before anchor will touch it
                evidence = await executor.awaitProjectWindow(request, excluding: before, timeout: 40)
            case .openApplication:
                // opening comes first, so nothing is waited for here at all
                evidence = .none("anchor did not wait here, this application's window is looked for once every launch has been asked for")
            default:
                evidence = await executor.observeNewWindow(bundleID: bundleID, excluding: before, timeout: 8)
            }
            if case .openApplication = window.action {
                log.record("identify", "deferred until every launch has been asked for")
            } else {
                log.record("identify", evidence.windowID.map { "window \($0)" } ?? "no window was identified")
            }
        }
        finish(window.id,
               state: outcome.succeeded ? .opened : .failed,
               summary: outcome.summary,
               items: items,
               evidence: evidence.label)

        guard outcome.succeeded else { return }
        if case .openApplication = window.action {
            hold(window, bundleID: bundleID, before: before, plan: plan)
            return
        }
        guard let identified = evidence.windowID else {
            // the application opened, anchor simply never got a window it was sure of
            record(placement: "\(window.appName) opened but anchor could not tell which window was this one, so nothing was placed and the window was left where the application put it",
                   on: window.id,
                   state: .failed)
            log.record("place", "skipped, no window was identified")
            return
        }
        guard !cancelRequested else {
            record(placement: "no layout was applied, you cancelled while anchor was waiting for this window",
                   on: window.id,
                   state: .skipped)
            return
        }
        await applyLayout(window, windowID: identified, plan: plan, executor: executor)
    }

    // a plain open that is worth placing later, kept until every launch has been asked for
    private func hold(_ window: RestorePlanWindow,
                      bundleID: String,
                      before: Set<CGWindowID>,
                      plan: RestorePlan) {
        guard window.layout.frame != nil else {
            record(placement: window.layout.summary, on: window.id, state: .skipped)
            return
        }
        guard plan.permissions.accessibilityGranted else {
            record(placement: "no layout was applied, accessibility is not granted", on: window.id, state: .skipped)
            return
        }
        guard !bundleID.isEmpty else {
            record(placement: "this window was saved with no application identifier, so anchor cannot tell which window is its own",
                   on: window.id,
                   state: .skipped)
            return
        }
        pending.append(PendingPlacement(window: window, bundleID: bundleID, before: before))
        record(placement: "anchor is opening the other applications first and will place this window after that",
               on: window.id,
               state: .skipped)
    }

    private enum PendingCandidate {
        case found(CGWindowID, String)
        case ambiguous(String)
        case notYet
    }

    // the second pass. every launch has been requested, so a short bounded wait here
    // cannot hold a launch up, and a failure to place one window never touches another
    private func placePending(plan: RestorePlan, executor: RestoreExecutor) async {
        guard !pending.isEmpty else { return }
        log.record("place pass", "\(pending.count) applications to look at")
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.genericReadiness)
        var waiting = pending
        pending = []
        while !waiting.isEmpty, !cancelRequested {
            let mayReuse = Date().timeIntervalSince(startedAt) >= Self.freshWindowGrace
            var later: [PendingPlacement] = []
            for entry in waiting {
                switch candidate(entry, plan: plan, executor: executor, mayReuse: mayReuse) {
                case .found(let id, let reason):
                    log.record("identify", "window \(id) for \(entry.window.appName)")
                    note(evidence: reason, on: entry.window.id)
                    await applyLayout(entry.window, windowID: id, plan: plan, executor: executor)
                case .ambiguous(let reason):
                    log.record("place", "skipped, more than one window could be this one")
                    record(placement: reason, on: entry.window.id, state: .failed)
                case .notYet:
                    later.append(entry)
                }
            }
            waiting = later
            if waiting.isEmpty || Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        for entry in waiting {
            log.record("place", "skipped, no window was identified for \(entry.window.appName)")
            let reason = cancelRequested
                ? "\(entry.window.appName) opened and you cancelled before anchor placed it, so it was left where it is"
                : "\(entry.window.appName) opened but showed no window anchor could tie to this saved one within \(Int(Self.genericReadiness)) seconds, so nothing was moved"
            record(placement: reason, on: entry.window.id, state: .failed)
        }
    }

    // a window this open produced, or the single window of an application that was already
    // running, and never a choice between several
    private func candidate(_ entry: PendingPlacement,
                           plan: RestorePlan,
                           executor: RestoreExecutor,
                           mayReuse: Bool) -> PendingCandidate {
        let live = executor.liveWindows(bundleID: entry.bundleID)
        let fresh = live.filter { !entry.before.contains($0.id) }
        if fresh.count == 1, let found = fresh.first {
            return .found(found.id, "window \(found.id) is the one window \(entry.window.appName) opened while this run was going")
        }
        if fresh.count > 1 {
            return .ambiguous("\(entry.window.appName) opened \(fresh.count) windows and anchor cannot tell which one this saved window is, so none of them was moved")
        }
        guard mayReuse else { return .notYet }
        // nothing new appeared, so the application reused a window it already had. that is
        // only unambiguous when this state holds one window of it and the display holds one
        guard saved(of: entry.bundleID, in: plan) == 1 else { return .notYet }
        let here = live.filter { RestoreReuse.isOn(plan.destination, frame: $0.appKitFrame) }
        guard here.count == 1, let found = here.first else { return .notYet }
        return .found(found.id, "window \(found.id) is the only \(entry.window.appName) window on \(plan.destination.name) and this state holds one saved window of it")
    }

    private func saved(of bundleID: String, in plan: RestorePlan) -> Int {
        plan.groups
            .filter { $0.bundleID == bundleID }
            .flatMap(\.windows)
            .filter(\.isActionable)
            .count
    }

    private func note(evidence: String, on id: String) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[index].evidence = evidence
    }

    // only a window this operation created, or one confidently reused on the destination,
    // is ever moved, and never one the application put on another display
    private func applyLayout(_ window: RestorePlanWindow,
                             windowID: CGWindowID,
                             plan: RestorePlan,
                             executor: RestoreExecutor) async {
        guard let frame = window.layout.frame else {
            log.record("place", "skipped, this window has no rectangle to apply")
            record(placement: window.layout.summary, on: window.id, state: .skipped)
            return
        }
        guard plan.permissions.accessibilityGranted else {
            log.record("place", "skipped, accessibility is not granted")
            record(placement: "no layout was applied, accessibility is not granted",
                   on: window.id,
                   state: .skipped)
            return
        }
        let live = executor.liveWindows(bundleID: window.bundleID ?? "").first { $0.id == windowID }
        if let live, !RestoreReuse.isOn(plan.destination, frame: live.appKitFrame) {
            log.record("place", "skipped, the window is not on the destination display")
            record(placement: "the application put this window outside \(plan.destination.name), so anchor left it alone rather than dragging it across",
                   on: window.id,
                   state: .skipped)
            return
        }
        let outcome = await executor.place(windowID: windowID, appKitFrame: frame)
        guard case .applied = outcome else {
            log.record("place", "window \(windowID) refused")
            record(placement: outcome.label, on: window.id, state: .failed)
            return
        }
        log.record("place", "window \(windowID) accepted")
        let settled = await PlacementSettle.verify(windowID: windowID,
                                                   bundleID: window.bundleID ?? "",
                                                   requested: frame,
                                                   executor: executor)
        log.record("settle", settled.state == .opened ? "held" : "drifted and was left alone")
        record(placement: settled.text, on: window.id, state: settled.state)
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
