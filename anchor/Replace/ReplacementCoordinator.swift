import AppKit

// one replacement, one step at a time
// preflight, an optional durable save, scoped closes, then the existing restore engine
// nothing is closed before the save is on disk, and nothing is reopened until every
// intended window is confirmed closed
@MainActor
@Observable
final class ReplacementCoordinator {
    enum Mode: String {
        case saveThenReplace
        case replaceWithoutSaving

        var label: String {
            switch self {
            case .saveThenReplace: return "save the current state, then replace it"
            case .replaceWithoutSaving: return "replace without saving the current state"
            }
        }
    }

    enum Stage: Equatable {
        case idle
        case preflight
        case awaitingCaptureDecision
        case saving
        case closing
        case reopening
        case finished
        case stopped
    }

    struct CloseReport: Identifiable, Equatable {
        enum State: String {
            case pending
            case requested
            case closed
            case alreadyGone
            case remaining
            case refused
            case notReached
        }

        let id: CGWindowID
        let appName: String
        let title: String?
        var state: State
        var detail: String
    }

    // a save that finished with less than the screen held, waiting for a decision
    struct PartialCapture: Equatable {
        let snapshotID: String
        let completeness: SnapshotCompleteness
        let summary: String
        let omissions: [String]
    }

    private(set) var stage: Stage = .idle
    private(set) var mode: Mode?
    private(set) var preflight: ReplacementPreflight?
    private(set) var closeReports: [CloseReport] = []
    private(set) var outgoingSnapshotID: String?
    private(set) var outgoingSaveSummary: String?
    private(set) var partialCapture: PartialCapture?
    private(set) var stopReason: String?
    private(set) var refreshRequired = false
    private(set) var appearedAfterConfirmation = 0
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var cancelRequested = false
    private(set) var log = OperationLog()

    // bounded waits, short in tests so a refusal does not take half a minute
    var closeTimeout: TimeInterval = 25
    var pollInterval: TimeInterval = 0.25

    let restore: RestoreCoordinator

    private var pending: Pending?

    private struct Pending {
        let mode: Mode
        let plan: RestorePlan
        let services: any ReplacementServices
        let executor: any RestoreExecutor
    }

    // what the user chose to leave out of this operation, neither choice edits a snapshot
    var excludedOutgoing: Set<CGWindowID> = []
    var excludedIncoming: Set<String> = []

    init(restore: RestoreCoordinator) {
        self.restore = restore
    }

    // a decision that is still waiting is part of the operation, so nothing else may start
    var isRunning: Bool {
        switch stage {
        case .saving, .closing, .reopening, .awaitingCaptureDecision: return true
        case .idle, .preflight, .finished, .stopped: return false
        }
    }

    // the switch did all of it: nothing stopped it, every window it meant to close is
    // gone, the save it took was whole, and the reopen it ran left nothing to read
    var fullySucceeded: Bool {
        guard stage == .finished, !cancelRequested, stopReason == nil, partialCapture == nil else { return false }
        let closed = closeReports.allSatisfy { $0.state == .closed || $0.state == .alreadyGone }
        return closed && restore.fullySucceeded
    }

    var canConfirm: Bool {
        guard let preflight, stage == .preflight || stage == .idle else { return false }
        return preflight.accessibilityGranted && preflight.blocking(excluding: excludedOutgoing).isEmpty
    }

    func beginPreflight(plan: RestorePlan, services: any ReplacementServices) async {
        guard !isRunning else { return }
        let scan = services.outgoingScope()
        let entries = scan.windows.map { window in
            OutgoingEntry(window: window, support: services.closeSupport(for: window))
        }
        preflight = ReplacementPreflight(destination: scan.destination,
                                         entries: entries,
                                         accessibilityGranted: scan.accessibilityGranted,
                                         notes: ReplacementScope.notes(entries: entries,
                                                                       accessibilityGranted: scan.accessibilityGranted,
                                                                       incoming: plan),
                                         builtAt: Date())
        excludedOutgoing = []
        excludedIncoming = []
        closeReports = []
        partialCapture = nil
        stopReason = nil
        refreshRequired = false
        appearedAfterConfirmation = 0
        outgoingSnapshotID = nil
        outgoingSaveSummary = nil
        mode = nil
        stage = .preflight
    }

    func exclude(outgoing id: CGWindowID, _ excluded: Bool) {
        guard stage == .preflight else { return }
        if excluded { excludedOutgoing.insert(id) } else { excludedOutgoing.remove(id) }
    }

    func exclude(incoming id: String, _ excluded: Bool) {
        guard stage == .preflight else { return }
        if excluded { excludedIncoming.insert(id) } else { excludedIncoming.remove(id) }
    }

    func cancel() {
        if stage == .reopening {
            restore.cancel()
            cancelRequested = true
            return
        }
        guard isRunning || stage == .awaitingCaptureDecision else { return }
        cancelRequested = true
        if stage == .awaitingCaptureDecision {
            stop("you cancelled after the save finished. nothing was closed and nothing was reopened, and the saved state stays in your history")
        }
    }

    func run(mode requested: Mode,
             plan: RestorePlan,
             services: any ReplacementServices,
             executor: any RestoreExecutor) async {
        guard stage == .preflight, canConfirm, !restore.isRunning else { return }
        guard let confirmed = preflight else { return }
        // nothing to reopen means nothing to replace, so no window is ever closed for it
        let incoming = plan.excluding(windowIDs: excludedIncoming)
        guard incoming.actionableWindowCount > 0 else {
            log.begin(id: OperationID.make(), trigger: requested.label)
            log.record("refused", "the selected saved state has nothing anchor can reopen")
            mode = requested
            closeReports = []
            stop("nothing in this saved state can be reopened onto this display, so anchor closed nothing")
            return
        }
        mode = requested
        cancelRequested = false
        stopReason = nil
        refreshRequired = false
        startedAt = Date()
        finishedAt = nil
        log.begin(id: OperationID.make(), trigger: requested.label)
        log.record("confirmed",
                   "\(confirmed.included(excluding: excludedOutgoing).count) windows to close on \(confirmed.destination.name), \(incoming.actionableWindowCount) to reopen")
        pending = Pending(mode: requested, plan: plan, services: services, executor: executor)
        closeReports = confirmed.included(excluding: excludedOutgoing).map { entry in
            CloseReport(id: entry.id,
                        appName: entry.window.appName,
                        title: entry.window.title,
                        state: .pending,
                        detail: "waiting")
        }

        // the preview can be older than the screen, so the whole scope is checked again
        // before anything is saved or closed
        stage = .closing
        guard revalidate(confirmed: confirmed, plan: plan, services: services) else { return }

        if requested == .saveThenReplace {
            stage = .saving
            let outcome = await services.captureOutgoing()
            guard let snapshot = outcome.snapshot, outcome.storeError == nil else {
                let reason = outcome.storeError ?? "the capture produced no saved state"
                stop("the current state could not be saved, \(reason). nothing was closed")
                return
            }
            outgoingSnapshotID = snapshot.id
            outgoingSaveSummary = outcome.summary
            log.record("saved", "the outgoing state was stored as \(snapshot.id)")
            if outcome.thumbnailFailure != nil {
                log.record("thumbnail", "unavailable, the saved layout uses its schematic preview")
            }
            if snapshot.completeness != .complete {
                partialCapture = PartialCapture(snapshotID: snapshot.id,
                                                completeness: snapshot.completeness,
                                                summary: outcome.summary,
                                                omissions: snapshot.issues
                                                    .filter { $0.severity != .note }
                                                    .map { "\($0.scope): \($0.message)" })
                stage = .awaitingCaptureDecision
                return
            }
        }
        await closeAndReopen(plan: plan, services: services, executor: executor)
    }

    // the explicit decision after a partial or inconsistent save, nothing closes without it
    func continueAfterPartialCapture() async {
        guard stage == .awaitingCaptureDecision, let pending else { return }
        partialCapture = nil
        await closeAndReopen(plan: pending.plan, services: pending.services, executor: pending.executor)
    }

    private func closeAndReopen(plan: RestorePlan,
                                services: any ReplacementServices,
                                executor: any RestoreExecutor) async {
        guard let confirmed = preflight else { return }
        stage = .closing
        let intended = confirmed.included(excluding: excludedOutgoing)

        for entry in intended {
            if cancelRequested {
                stop("you cancelled, so anchor stopped closing windows and reopened nothing")
                return
            }
            let scan = services.outgoingScope()
            guard scan.destination.fingerprint == confirmed.destination.fingerprint else {
                stop("the destination display changed while anchor was closing windows, so it stopped", refresh: true)
                return
            }
            guard let live = scan.windows.first(where: { $0.id == entry.id }) else {
                mark(entry.id, .alreadyGone, "this window was gone before anchor reached it, so anchor closed nothing for it")
                continue
            }
            guard live.pid == entry.window.pid, live.bundleID == entry.window.bundleID else {
                mark(entry.id, .remaining, "this window number now belongs to a different process, so anchor did not close it")
                stop("a window in this operation is no longer the window anchor was shown, so it stopped rather than closing work it was never given", refresh: true)
                return
            }
            let support = services.closeSupport(for: live)
            guard support.isSupported else {
                mark(entry.id, .remaining, support.label)
                stop("anchor can no longer close \(entry.window.appName)'s window on its own, so it stopped instead of quitting the application", refresh: true)
                return
            }
            mark(entry.id, .requested, "anchor asked \(entry.window.appName) to close this window and is waiting for it to go")
            log.countClose()
            log.record("close", "\(entry.window.appName) window \(entry.id), request \(log.closeRequests)")
            let request = await services.requestClose(live)
            if case .refused(let reason) = request {
                mark(entry.id, .refused, reason)
                stop("\(entry.window.appName) refused to close a window, so anchor stopped and reopened nothing")
                return
            }
            switch await observe(live, services: services) {
            case .closed:
                mark(entry.id, .closed, "closed")
            case .closedWithExit:
                mark(entry.id, .closed, "closed, and \(entry.window.appName) exited with it")
                stop("\(entry.window.appName) exited while anchor was closing one of its windows, which anchor did not ask for, so it stopped and reopened nothing")
                return
            case .stillOpen(let reason):
                mark(entry.id, .remaining, reason)
                stop("a window did not close, so anchor stopped and reopened nothing. answer or dismiss whatever the application is asking, then try again")
                return
            }
        }

        if cancelRequested {
            stop("you cancelled, so anchor reopened nothing. the windows it already closed stay closed")
            return
        }

        // a successful close stage says nothing about the destination still being there
        let fresh = services.outgoingScope()
        guard fresh.destination.fingerprint == confirmed.destination.fingerprint,
              fresh.destination.fingerprint == plan.destination.fingerprint else {
            stop("the destination display changed after the windows were closed, so anchor reopened nothing. the saved state is untouched", refresh: true)
            return
        }
        appearedAfterConfirmation = fresh.windows.filter { window in
            !confirmed.entries.contains { $0.id == window.id }
        }.count

        stage = .reopening
        log.record("closing finished", "\(closedCount) of \(closeReports.count) windows closed")
        // the reopening shares this operation id so one report covers both halves
        await restore.run(plan: plan.excluding(windowIDs: excludedIncoming),
                          executor: executor,
                          operationID: log.id,
                          trigger: mode?.label)
        pending = nil
        finishedAt = Date()
        stage = .finished
    }

    private enum ClosureObservation {
        case closed
        case closedWithExit
        case stillOpen(String)
    }

    // the window server is the evidence that a window went, not the close request returning
    private func observe(_ window: OutgoingWindow, services: any ReplacementServices) async -> ClosureObservation {
        let deadline = Date().addingTimeInterval(closeTimeout)
        repeat {
            let scan = services.outgoingScope()
            if !scan.windows.contains(where: { $0.id == window.id }) {
                return services.isRunning(pid: window.pid) ? .closed : .closedWithExit
            }
            if cancelRequested {
                return .stillOpen("you cancelled while anchor was waiting for this window to close, so it is still open")
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        } while Date() < deadline
        return .stillOpen("the window was still open \(Int(closeTimeout)) seconds after anchor asked for it. an unsaved document or a running job may be waiting for your answer")
    }

    private func revalidate(confirmed: ReplacementPreflight,
                            plan: RestorePlan,
                            services: any ReplacementServices) -> Bool {
        let scan = services.outgoingScope()
        guard scan.destination.fingerprint == confirmed.destination.fingerprint,
              scan.destination.fingerprint == plan.destination.fingerprint else {
            stop("the destination display changed after this preview was built, so anchor closed nothing. read the refreshed preview and confirm again", refresh: true)
            return false
        }
        guard scan.accessibilityGranted else {
            stop("accessibility is no longer granted, so anchor cannot close windows. nothing was closed")
            return false
        }
        let drifted = confirmed.included(excluding: excludedOutgoing).filter { entry in
            guard let live = scan.windows.first(where: { $0.id == entry.id }) else { return false }
            return live.pid != entry.window.pid || live.bundleID != entry.window.bundleID
        }
        guard drifted.isEmpty else {
            stop("\(drifted.count) windows in this operation are no longer the windows anchor was shown, so it closed nothing. read the refreshed preview and confirm again", refresh: true)
            return false
        }
        return true
    }

    // a stopped run schedules nothing else, and the continuation it was holding is dropped
    private func stop(_ reason: String, refresh: Bool = false) {
        pending = nil
        log.record("stopped", reason)
        for index in closeReports.indices where closeReports[index].state == .pending {
            closeReports[index].state = .notReached
            closeReports[index].detail = "anchor stopped before it reached this window, so it is still open"
        }
        stopReason = reason
        refreshRequired = refresh
        finishedAt = Date()
        stage = .stopped
    }

    private func mark(_ id: CGWindowID, _ state: CloseReport.State, _ detail: String) {
        guard let index = closeReports.firstIndex(where: { $0.id == id }) else { return }
        closeReports[index].state = state
        closeReports[index].detail = detail
    }

    var closedCount: Int { closeReports.filter { $0.state == .closed }.count }
    var remainingCount: Int { closeReports.filter { $0.state != .closed && $0.state != .alreadyGone }.count }

    var summary: String {
        var parts: [String] = []
        switch mode {
        case .saveThenReplace:
            parts.append(outgoingSnapshotID == nil
                ? "the current state was not saved"
                : "the current state was saved first")
        case .replaceWithoutSaving:
            parts.append("the current state was not saved, at your request")
        case nil:
            break
        }
        parts.append("\(closedCount) of \(closeReports.count) windows closed")
        if remainingCount > 0 { parts.append("\(remainingCount) still open") }
        if appearedAfterConfirmation > 0 {
            parts.append("\(appearedAfterConfirmation) windows appeared after you confirmed and were left alone")
        }
        if stage == .finished || stage == .reopening { parts.append(restore.summary) }
        return parts.joined(separator: ", ")
    }

    var report: String {
        var lines = log.lines()
        if restore.launchRequests > 0 || stage == .finished {
            lines.append("reopen counts: launch requests \(restore.launchRequests)")
        }
        if let stopReason { lines.append("stopped: \(stopReason)") }
        lines.append("outcome: \(summary)")
        return lines.joined(separator: "\n")
    }

    // the outgoing save is never removed, whatever the reopening did
    var snapshotNotice: String? {
        guard let outgoingSnapshotID else { return nil }
        let failed = restore.reports.contains { $0.state == .failed || $0.state == .cancelled }
        let kept = "the state anchor saved before closing is in your history and was not touched"
        return failed || stage == .stopped
            ? "\(kept). reopening did not finish, so keep it until you have what you need"
            : kept
    }
}
