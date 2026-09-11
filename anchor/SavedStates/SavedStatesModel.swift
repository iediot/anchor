import AppKit
import SwiftUI

// where the attached panel currently is, kept in the model so dismissing the panel
// and opening it again comes back to the same place and to any running operation
enum PanelRoute: Equatable {
    case home
    case detail(String)
    case preview
    case operation
    case replacement
}

@MainActor
@Observable
final class SavedStatesModel {
    private(set) var snapshots: [Snapshot] = []
    private(set) var failures: [SnapshotLoadFailure] = []
    private(set) var storeError: String?
    private(set) var saving = false
    private(set) var lastOutcome: CaptureCoordinator.Outcome?
    private(set) var renameError: String?
    private(set) var deleteError: String?
    // the entry whose name is being edited, and the entry waiting for a delete confirmation
    private(set) var renaming: String?
    private(set) var confirmingDelete: String?
    var selectedID: String?
    var draftName: String = ""
    // asked for when the panel opens on the grid and after a save, so the newest cards
    // and the save tile are in view, cleared by the grid once it has scrolled
    var revealNewest = false

    var route: PanelRoute = .home
    let restore: RestoreCoordinator
    let replacement: ReplacementCoordinator
    let launch = LaunchDiagnosticsCoordinator()
    private(set) var plan: RestorePlan?
    private(set) var planning = false
    private(set) var planError: String?
    private(set) var planRebuiltNotice: String?
    private(set) var destination: DisplayTarget?
    private var environment: LiveRestoreEnvironment?

    // one operation at a time, and no second press of the same button
    var busy: Bool { saving || planning || restore.isRunning || replacement.isRunning || launch.isRunning }

    // the explanation is shown once, the choice it takes becomes the standing setting
    var browserDisclosurePending = false
    private var pendingReplacement: ReplacementCoordinator.Mode?

    var includeBrowserTabs: Bool {
        didSet { defaults.set(includeBrowserTabs, forKey: Keys.includeBrowserTabs) }
    }

    private(set) var browserDisclosureShown: Bool {
        didSet { defaults.set(browserDisclosureShown, forKey: Keys.disclosureShown) }
    }

    private enum Keys {
        static let includeBrowserTabs = "anchor.includeBrowserTabs"
        static let disclosureShown = "anchor.browserDisclosureShown"
    }

    private let defaults = UserDefaults.standard
    private let store: SnapshotStore?

    init(store: SnapshotStore? = nil) {
        let restore = RestoreCoordinator()
        self.restore = restore
        replacement = ReplacementCoordinator(restore: restore)
        if let store {
            self.store = store
            storeError = nil
        } else {
            let made = SnapshotStore.makeDefault()
            self.store = made.store
            storeError = made.error
        }
        includeBrowserTabs = (defaults.object(forKey: Keys.includeBrowserTabs) as? Bool) ?? true
        browserDisclosureShown = defaults.bool(forKey: Keys.disclosureShown)
        reload()
    }

    var storeLocation: String { store?.root.path ?? "unavailable" }

    var selected: Snapshot? {
        guard let selectedID else { return snapshots.first }
        return snapshots.first { $0.id == selectedID } ?? snapshots.first
    }

    var recent: [Snapshot] { Array(snapshots.prefix(8)) }

    // the grid reads oldest first, left to right, while everything else keeps the
    // newest first order the store loads
    var oldestFirst: [Snapshot] {
        snapshots.sorted { left, right in
            left.createdAt == right.createdAt ? left.id < right.id : left.createdAt < right.createdAt
        }
    }

    func reload() {
        guard let store else { return }
        let loaded = store.loadAll()
        snapshots = loaded.snapshots
        failures = loaded.failures
        if let selectedID, !snapshots.contains(where: { $0.id == selectedID }) {
            self.selectedID = snapshots.first?.id
        }
        syncDraftName()
    }

    func select(_ id: String) {
        selectedID = id
        syncDraftName()
    }

    func show(_ route: PanelRoute) {
        self.route = route
        if case .detail(let id) = route { select(id) }
    }

    func backToHome() {
        // any reading still in flight belongs to the screen that was just left
        previewTicket += 1
        route = .home
    }

    // the destination is resolved the same way capture resolves it, from the last
    // application that was active before anchor, so opening this panel cannot redefine it
    @discardableResult
    func resolveDestination() -> DestinationDisplay {
        let scan = WindowInspector.scan(preferredOwner: FocusTracker.shared.lastExternalPID)
        destination = scan.target
        return DestinationDisplay(scan.target)
    }

    // the route changes here rather than inside the task, so opening a layout is one
    // state change a caller can animate
    func requestPreview(for id: String) {
        guard !busy, snapshots.contains(where: { $0.id == id }) else { return }
        select(id)
        plan = nil
        route = .preview
        Task { await preparePreview(for: id) }
    }

    // a reading that is no longer the one on screen must not move the panel or write
    // over another selection, so every reading carries the ticket it started with
    private var previewTicket = 0

    private func openPreviewTicket() -> Int {
        previewTicket += 1
        return previewTicket
    }

    private func previewIsCurrent(_ ticket: Int, _ id: String) -> Bool {
        ticket == previewTicket && selectedID == id && route == .preview
    }

    func preparePreview(for id: String) async {
        guard !busy, let snapshot = snapshots.first(where: { $0.id == id }) else { return }
        let ticket = openPreviewTicket()
        planning = true
        defer { planning = false }
        select(id)
        route = .preview
        plan = nil
        planError = nil
        planRebuiltNotice = nil
        let built = await buildPlan(snapshot)
        guard previewIsCurrent(ticket, id) else { return }
        plan = built
        await replacement.beginPreflight(plan: built, services: services())
    }

    private func services() -> LiveReplacementServices {
        LiveReplacementServices(store: store, includeBrowserTabs: includeBrowserTabs)
    }

    func requestReplacement(_ mode: ReplacementCoordinator.Mode) {
        guard !busy, plan != nil, replacement.canConfirm else { return }
        // saving on the way out is still a save, so the one browser question comes first
        guard mode == .replaceWithoutSaving || browserDisclosureShown else {
            pendingReplacement = mode
            browserDisclosurePending = true
            return
        }
        Task { await replace(mode) }
    }

    // the preview is the confirmation, and the coordinator checks the screen again itself
    // before it saves or closes anything
    func replace(_ mode: ReplacementCoordinator.Mode) async {
        guard !busy,
              let current = plan,
              let environment,
              let snapshot = snapshots.first(where: { $0.id == current.snapshotID })
        else { return }
        route = .replacement
        await replacement.run(mode: mode,
                              plan: current,
                              services: services(),
                              executor: LiveRestoreExecutor(environment: environment))
        reload()
        guard replacement.refreshRequired else { return }
        planning = true
        let rebuilt = await buildPlan(snapshot)
        plan = rebuilt
        await replacement.beginPreflight(plan: rebuilt, services: services())
        planning = false
        planRebuiltNotice = "the screen changed, so anchor stopped and read it again. check this preview and confirm once more"
        route = .preview
    }

    // the temporary launch diagnostic, on the same gate as save, reopen and replacement
    // so a diagnostic run and a real operation can never overlap
    func requestLaunchDiagnostic(_ mode: LaunchDiagnosticMode, projectPath: String) {
        guard !busy else { return }
        Task { await runLaunchDiagnostic(mode, projectPath: projectPath) }
    }

    func runLaunchDiagnostic(_ mode: LaunchDiagnosticMode, projectPath: String) async {
        guard !busy else { return }
        let request = ProjectOpenRequest(app: .pycharm,
                                         itemID: "launch-diagnostic",
                                         path: projectPath,
                                         projectName: (projectPath as NSString).lastPathComponent)
        let granted = Permissions.accessibilityGranted
        // no automation is looked up, this application is not scripted and the launch
        // stage must touch nothing but the launch
        let environment = LiveRestoreEnvironment(accessibilityGranted: granted, automation: [:])
        var rectangle: LaunchRectangle?
        if mode == .place {
            rectangle = LaunchRectangleSource.resolve(projectPath: projectPath,
                                                      snapshots: snapshots,
                                                      destination: resolveDestination())
        }
        await launch.run(mode: mode,
                         project: request,
                         rectangle: rectangle,
                         accessibilityGranted: granted,
                         probe: LiveLaunchProcessProbe(),
                         executor: LiveRestoreExecutor(environment: environment))
    }

    func requestPartialCaptureDecision() {
        Task {
            await replacement.continueAfterPartialCapture()
            reload()
        }
    }

    private func buildPlan(_ snapshot: Snapshot) async -> RestorePlan {
        let destination = resolveDestination()
        let environment = await LiveRestoreEnvironment.gather(bundleIDs: snapshot.windows.compactMap(\.bundleID))
        self.environment = environment
        return RestorePlanner.build(snapshot: snapshot, destination: destination, environment: environment)
    }

    func requestExecute() {
        guard !busy, plan != nil else { return }
        Task { await execute() }
    }

    // the preview is the confirmation, so execution rechecks the destination first and
    // asks again rather than acting on a preview that describes a screen that changed
    func execute() async {
        guard !busy, let current = plan, let snapshot = snapshots.first(where: { $0.id == current.snapshotID }) else { return }
        planning = true
        let fresh = resolveDestination()
        planning = false
        guard fresh.fingerprint == current.destination.fingerprint else {
            planning = true
            plan = await buildPlan(snapshot)
            planning = false
            planRebuiltNotice = "the destination display changed after this preview was built, so anchor built it again. read it and confirm once more"
            route = .preview
            return
        }
        guard let environment else { return }
        planRebuiltNotice = nil
        route = .operation
        await restore.run(plan: current, executor: LiveRestoreExecutor(environment: environment))
    }

    // the snapshot a run is built on, so its entry cannot be deleted underneath it
    var operationSnapshotID: String? {
        guard restore.isRunning || replacement.isRunning || replacement.stage == .awaitingCaptureDecision else {
            return nil
        }
        return plan?.snapshotID
    }

    func canDelete(_ id: String) -> Bool {
        !busy && operationSnapshotID != id
    }

    func beginRename(_ id: String) {
        guard !busy else { return }
        select(id)
        renaming = id
        confirmingDelete = nil
    }

    func cancelRename() {
        renaming = nil
        renameError = nil
        syncDraftName()
    }

    func commitRename() {
        renameSelected()
        guard renameError == nil else { return }
        renaming = nil
    }

    func requestDelete(_ id: String) {
        guard canDelete(id) else { return }
        confirmingDelete = id
        renaming = nil
        deleteError = nil
    }

    func cancelDelete() {
        confirmingDelete = nil
        deleteError = nil
    }

    // the identifier is what the store resolves, never a name, and only the one
    // snapshot file moves, anything the snapshot refers to is left alone
    func confirmDelete(_ id: String) {
        guard let store, canDelete(id) else { return }
        do {
            try store.trash(id: id)
        } catch {
            // the entry stays in the list, the failure is the only thing that changed
            deleteError = error.localizedDescription
            return
        }
        deleteError = nil
        confirmingDelete = nil
        if renaming == id { renaming = nil }
        if plan?.snapshotID == id { plan = nil }
        reload()
        if routeTargets(id) { route = .home }
    }

    private func routeTargets(_ id: String) -> Bool {
        switch route {
        case .detail(let shown): return shown == id
        case .preview: return true
        default: return false
        }
    }

    func syncDraftName() {
        draftName = selected?.name ?? ""
        renameError = nil
    }

    // the first save asks once, every later save uses the standing setting
    func requestSave() {
        guard !busy else { return }
        if browserDisclosureShown {
            Task { await save(includeBrowserTabs: includeBrowserTabs) }
        } else {
            browserDisclosurePending = true
        }
    }

    func answerDisclosure(includeBrowserTabs include: Bool) {
        browserDisclosurePending = false
        browserDisclosureShown = true
        includeBrowserTabs = include
        if let mode = pendingReplacement {
            pendingReplacement = nil
            Task { await replace(mode) }
            return
        }
        Task { await save(includeBrowserTabs: include) }
    }

    func cancelDisclosure() {
        browserDisclosurePending = false
        pendingReplacement = nil
    }

    func save(includeBrowserTabs include: Bool) async {
        guard !busy else { return }
        saving = true
        defer { saving = false }
        let outcome = await CaptureCoordinator.capture(
            options: CaptureCoordinator.Options(includeBrowserTabs: include, name: nil),
            focusPID: FocusTracker.shared.lastExternalPID,
            store: store)
        lastOutcome = outcome
        reload()
        if let saved = outcome.snapshot {
            select(saved.id)
            revealNewest = true
        }
    }

    func renameSelected() {
        guard let store, var snapshot = selected else { return }
        snapshot.name = SnapshotName.normalize(draftName)
        do {
            try store.update(snapshot)
            renameError = nil
            reload()
        } catch {
            renameError = error.localizedDescription
        }
    }
}
