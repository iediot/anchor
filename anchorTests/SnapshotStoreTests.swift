import XCTest
@testable import anchor

final class SnapshotStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // a locked fixture directory has to be writable again before it can be removed
        if let names = try? FileManager.default.subpathsOfDirectory(atPath: root.path) {
            for name in names {
                let path = root.appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
                }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func store(_ sub: String = "Snapshots") -> SnapshotStore {
        SnapshotStore(root: root.appendingPathComponent(sub, isDirectory: true))
    }

    // urls and titles carry arbitrary text, including the separators anchor's probes used
    func testRoundTripPreservesAwkwardTabStrings() throws {
        let tabs = SnapshotFixtures.awkwardStrings.enumerated().map { index, value in
            BrowserTabRecord(index: index + 1, url: value, title: value, issue: nil)
        }
        let subject = store()
        let original = SnapshotFixtures.snapshot(windows: [SnapshotFixtures.browserWindow(tabs: tabs)])
        try subject.create(original)

        let loaded = subject.loadAll()
        XCTAssertEqual(loaded.failures.count, 0)
        let restored = try XCTUnwrap(loaded.snapshots.first)
        let restoredTabs = try XCTUnwrap(restored.windows.first?.resources.browser?.tabs)
        XCTAssertEqual(restoredTabs.map(\.url), tabs.map(\.url))
        XCTAssertEqual(restoredTabs.map(\.title), tabs.map(\.title))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRoundTripPreservesTypedResourceStatuses() throws {
        let subject = store()
        let windows = [
            SnapshotFixtures.window(resources: .empty(.terminal, .windowNotResolved, "contested")),
            SnapshotFixtures.window(resources: .empty(.browser, .automationDenied, "denied")),
            SnapshotFixtures.window(resources: .empty(.jetBrains, .accessibilityNotGranted, "no title")),
            SnapshotFixtures.window(resources: .empty(.xcode, .capturedEmpty, nil))
        ]
        try subject.create(SnapshotFixtures.snapshot(completeness: .partial, windows: windows))

        let restored = try XCTUnwrap(subject.loadAll().snapshots.first)
        XCTAssertEqual(restored.windows.map(\.resources.status),
                       [.windowNotResolved, .automationDenied, .accessibilityNotGranted, .capturedEmpty])
        XCTAssertEqual(restored.completeness, .partial)
        // an empty read and an omission must not collapse into each other
        XCTAssertEqual(restored.omittedResourceCount, 3)
        XCTAssertEqual(restored.capturedResourceCount, 1)
    }

    // a name is a label inside the file, the file name comes from the generated id
    func testNameNeverBecomesAFilePath() throws {
        let subject = store()
        let snapshot = SnapshotFixtures.snapshot(name: "../../../escape/attempt")
        try subject.create(snapshot)

        let names = try FileManager.default.contentsOfDirectory(atPath: subject.root.path)
        XCTAssertEqual(names, ["\(snapshot.id).json"])
        XCTAssertEqual(subject.loadAll().snapshots.first?.name, "../../../escape/attempt")
    }

    func testNameNormalizationFoldsNewlinesAndEmptyNames() {
        XCTAssertNil(SnapshotName.normalize("   \n  "))
        XCTAssertNil(SnapshotName.normalize(nil))
        XCTAssertEqual(SnapshotName.normalize(" morning\nsetup "), "morning setup")
        XCTAssertEqual(SnapshotName.normalize(String(repeating: "a", count: 400))?.count, SnapshotName.maxLength)
    }

    func testRejectsAnIdentifierThatIsNotAFileNameToken() {
        let subject = store()
        var snapshot = SnapshotFixtures.snapshot()
        snapshot.id = "../evil"
        XCTAssertThrowsError(try subject.create(snapshot))
    }

    // a repeated identifier must not silently replace stored history
    func testCreateRefusesToOverwriteAndLeavesNoPartialFile() throws {
        let subject = store()
        let first = SnapshotFixtures.snapshot(name: "first")
        try subject.create(first)
        var second = SnapshotFixtures.snapshot(name: "second")
        second.id = first.id

        XCTAssertThrowsError(try subject.create(second))
        XCTAssertEqual(subject.loadAll().snapshots.first?.name, "first")
        let names = try FileManager.default.contentsOfDirectory(atPath: subject.root.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".partial") }, [])
    }

    func testUpdateReplacesOnlyAnExistingSnapshot() throws {
        let subject = store()
        var snapshot = SnapshotFixtures.snapshot()
        try subject.create(snapshot)
        snapshot.name = "named later"
        try subject.update(snapshot)
        XCTAssertEqual(subject.loadAll().snapshots.first?.name, "named later")

        var missing = SnapshotFixtures.snapshot()
        missing.name = "never stored"
        XCTAssertThrowsError(try subject.update(missing))
    }

    func testWriteFailsWhenTheStoreDirectoryCannotBeCreated() throws {
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let subject = SnapshotStore(root: locked.appendingPathComponent("Snapshots", isDirectory: true))

        XCTAssertThrowsError(try subject.create(SnapshotFixtures.snapshot())) { error in
            guard case SnapshotStoreError.rootUnavailable = error else {
                return XCTFail("expected the root to be reported unavailable, got \(error)")
            }
        }
        XCTAssertEqual(subject.loadAll().snapshots.count, 0)
    }

    func testWriteFailsWhenTheStoreDirectoryIsReadOnly() throws {
        let subject = store("ReadOnly")
        try FileManager.default.createDirectory(at: subject.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: subject.root.path)

        XCTAssertThrowsError(try subject.create(SnapshotFixtures.snapshot())) { error in
            guard case SnapshotStoreError.writeFailed = error else {
                return XCTFail("expected a write failure, got \(error)")
            }
        }
    }

    // one unreadable file must cost only itself
    func testCorruptAndFutureVersionFilesDoNotHideOtherSnapshots() throws {
        let subject = store()
        let good = SnapshotFixtures.snapshot(name: "readable")
        try subject.create(good)

        try Data("this is not json".utf8)
            .write(to: subject.root.appendingPathComponent("aaaacorrupt.json"))
        let future = """
        {"schemaVersion": 99, "id": "future-snapshot", "createdAt": "2026-09-10T09:00:00Z", "name": "from later"}
        """
        try Data(future.utf8).write(to: subject.root.appendingPathComponent("bbbbfuture.json"))

        let loaded = subject.loadAll()
        XCTAssertEqual(loaded.snapshots.map(\.name), ["readable"])
        XCTAssertEqual(loaded.failures.count, 2)

        let corrupt = try XCTUnwrap(loaded.failures.first { $0.fileName == "aaaacorrupt.json" })
        XCTAssertNil(corrupt.header)
        let unknownVersion = try XCTUnwrap(loaded.failures.first { $0.fileName == "bbbbfuture.json" })
        XCTAssertEqual(unknownVersion.header?.schemaVersion, 99)
        XCTAssertEqual(unknownVersion.header?.name, "from later")
        XCTAssertTrue(unknownVersion.reason.contains("schema version 99"))
    }

    func testFileWithAReadableHeaderButABrokenBodyReportsBoth() throws {
        let subject = store()
        try FileManager.default.createDirectory(at: subject.root, withIntermediateDirectories: true)
        let partial = """
        {"schemaVersion": \(SnapshotSchema.current), "id": "half-written", "createdAt": "2026-09-10T09:00:00Z"}
        """
        try Data(partial.utf8).write(to: subject.root.appendingPathComponent("half.json"))

        let loaded = subject.loadAll()
        XCTAssertEqual(loaded.snapshots.count, 0)
        XCTAssertEqual(loaded.failures.first?.header?.id, "half-written")
        XCTAssertTrue(loaded.failures.first?.reason.contains("body is not") == true)
    }

    func testSnapshotsAreListedNewestFirst() throws {
        let subject = store()
        let older = SnapshotFixtures.snapshot(name: "older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = SnapshotFixtures.snapshot(name: "newer", createdAt: Date(timeIntervalSince1970: 2_000))
        try subject.create(older)
        try subject.create(newer)
        XCTAssertEqual(subject.loadAll().snapshots.map(\.name), ["newer", "older"])
    }
}
