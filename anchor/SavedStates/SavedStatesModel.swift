import AppKit
import SwiftUI

@MainActor
@Observable
final class SavedStatesModel {
    private(set) var snapshots: [Snapshot] = []
    private(set) var failures: [SnapshotLoadFailure] = []
    private(set) var storeError: String?
    private(set) var saving = false
    private(set) var lastOutcome: CaptureCoordinator.Outcome?
    private(set) var renameError: String?
    var selectedID: String?
    var draftName: String = ""

    // the explanation is shown once, the choice it takes becomes the standing setting
    var browserDisclosurePending = false

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

    func syncDraftName() {
        draftName = selected?.name ?? ""
        renameError = nil
    }

    // the first save asks once, every later save uses the standing setting
    func requestSave() {
        guard !saving else { return }
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
        Task { await save(includeBrowserTabs: include) }
    }

    func cancelDisclosure() {
        browserDisclosurePending = false
    }

    func save(includeBrowserTabs include: Bool) async {
        guard !saving else { return }
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
