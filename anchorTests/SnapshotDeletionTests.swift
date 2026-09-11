import XCTest
@testable import anchor

// deleting a saved layout must move one file and nothing else
// every record here is disposable, and whatever reaches the trash is removed again
@MainActor
final class SnapshotDeletionTests: XCTestCase {
    private var root: URL!
    private var store: SnapshotStore!
    private var trashed: [URL] = []
    private var askedDuringRun: Bool?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-delete-\(UUID().uuidString)", isDirectory: true)
        store = SnapshotStore(root: root)
    }

    override func tearDown() {
        for url in trashed { try? FileManager.default.removeItem(at: url) }
        trashed = []
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func save(name: String? = nil, resources: WindowResources? = nil) -> Snapshot {
        let window = RestoreFixtures.window(resources: resources ?? RestoreFixtures.browser(["https://example.com"]))
        var snapshot = RestoreFixtures.snapshot([window])
        snapshot.name = name
        try? store.create(snapshot)
        return snapshot
    }

    private func trash(_ id: String) throws {
        if let moved = try store.trash(id: id) { trashed.append(moved) }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testOnlyTheChosenFileLeavesTheFolder() throws {
        let kept = save(name: "kept")
        let gone = save(name: "gone")
        try trash(gone.id)
        XCTAssertFalse(exists(store.fileURL(for: gone.id)))
        XCTAssertTrue(exists(store.fileURL(for: kept.id)))
        XCTAssertEqual(store.loadAll().snapshots.map(\.id), [kept.id])
    }

    func testTheFileReachesTheTrashRatherThanDisappearing() throws {
        let snapshot = save()
        let moved = try store.trash(id: snapshot.id)
        let destination = try XCTUnwrap(moved)
        trashed.append(destination)
        XCTAssertTrue(exists(destination))
    }

    // the name is a label inside the file, it must never be able to pick the target
    func testANameThatLooksLikeAPathDeletesOnlyItsOwnFile() throws {
        let neighbour = save(name: "neighbour")
        let hostile = save(name: "../../\(neighbour.id)")
        try trash(hostile.id)
        XCTAssertTrue(exists(store.fileURL(for: neighbour.id)))
        XCTAssertFalse(exists(store.fileURL(for: hostile.id)))
    }

    func testNothingTheSnapshotPointsAtIsTouched() throws {
        let project = root.appendingPathComponent("project.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("a real file the layout refers to".utf8).write(to: project)
        let resources = WindowResources(kind: .jetBrains,
                                        status: .captured,
                                        jetBrains: JetBrainsResource(projectPath: project.path,
                                                                     matchProvenance: "test",
                                                                     ambiguousCandidates: [],
                                                                     titleFileHint: nil,
                                                                     workspaceFile: nil,
                                                                     editorFiles: [],
                                                                     editorFileState: "none"))
        let snapshot = save(resources: resources)
        try trash(snapshot.id)
        XCTAssertTrue(exists(project), "deleting a saved layout must never touch what it refers to")
    }

    func testAnIdentifierThatIsNotAFileNameIsRefused() {
        let kept = save()
        XCTAssertThrowsError(try store.trash(id: "../../../etc/hosts"))
        XCTAssertThrowsError(try store.trash(id: "\(kept.id)/../\(kept.id)"))
        XCTAssertTrue(exists(store.fileURL(for: kept.id)))
    }

    func testAnUnknownIdentifierIsReportedAndNothingMoves() {
        let kept = save()
        XCTAssertThrowsError(try store.trash(id: SnapshotStore.newIdentifier()))
        XCTAssertTrue(exists(store.fileURL(for: kept.id)))
    }

    func testThePanelDropsTheEntryOnlyAfterTheFileMoved() throws {
        let gone = save(name: "gone")
        _ = save(name: "kept")
        let model = SavedStatesModel(store: store)
        XCTAssertEqual(model.snapshots.count, 2)
        model.requestDelete(gone.id)
        XCTAssertEqual(model.confirmingDelete, gone.id)
        model.confirmDelete(gone.id)
        if let moved = trashedURL(for: gone.id) { trashed.append(moved) }
        XCTAssertNil(model.confirmingDelete)
        XCTAssertNil(model.deleteError)
        XCTAssertEqual(model.snapshots.count, 1)
        XCTAssertFalse(model.snapshots.contains { $0.id == gone.id })
    }

    // a delete that fails leaves the list alone and says why
    func testAFailedDeleteKeepsTheEntryAndReportsTheReason() {
        let snapshot = save(name: "vanishing")
        _ = save(name: "kept")
        let model = SavedStatesModel(store: store)
        try? FileManager.default.removeItem(at: store.fileURL(for: snapshot.id))
        model.requestDelete(snapshot.id)
        model.confirmDelete(snapshot.id)
        XCTAssertNotNil(model.deleteError)
        XCTAssertEqual(model.snapshots.count, 2, "the entry stays until anchor reads the folder again")
        XCTAssertTrue(model.snapshots.contains { $0.id == snapshot.id })
    }

    // asked from inside a run, while the coordinator that model shares is still going
    func testAnEntryInAnActiveOperationCannotBeDeleted() async {
        let snapshot = save(name: "running")
        let model = SavedStatesModel(store: store)
        let executor = RecordingExecutor()
        executor.onOpen = { [weak self] in
            self?.askedDuringRun = model.canDelete(snapshot.id)
            model.requestDelete(snapshot.id)
            model.confirmDelete(snapshot.id)
        }
        let plan = RestorePlanner.build(snapshot: snapshot,
                                        destination: RestoreFixtures.destination(),
                                        environment: StubEnvironment())
        await model.restore.run(plan: plan, executor: executor)
        XCTAssertEqual(askedDuringRun, false, "a run was going, so the entry was not deletable")
        XCTAssertNil(model.confirmingDelete)
        XCTAssertTrue(exists(store.fileURL(for: snapshot.id)))
        XCTAssertEqual(model.snapshots.count, 1)
    }

    // the trash keeps the file under its own name unless something already sits there
    private func trashedURL(for id: String) -> URL? {
        guard let trash = try? FileManager.default.url(for: .trashDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil,
                                                       create: false) else { return nil }
        let candidate = trash.appendingPathComponent("\(id).json")
        return exists(candidate) ? candidate : nil
    }
}
