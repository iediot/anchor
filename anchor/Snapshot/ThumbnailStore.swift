import Foundation

// the blurred picture of one saved layout, filed under that layout's own identifier
// it sits beside the snapshots rather than inside them, so a snapshot file keeps the
// shape it has always had and a layout with no picture is simply one with no file here
// nothing sharp is ever handed to this type, the bytes are already downscaled and blurred
nonisolated final class ThumbnailStore {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    // beside the snapshot folder, under the same application support directory
    static func alongside(_ snapshots: SnapshotStore) -> ThumbnailStore {
        let root = snapshots.root
            .deletingLastPathComponent()
            .appendingPathComponent("Thumbnails", isDirectory: true)
        return ThumbnailStore(root: root)
    }

    // the same guard the snapshot store uses, so an identifier can never become a path
    func fileURL(for id: String) -> URL? {
        guard SnapshotStore.isSafeIdentifier(id) else { return nil }
        return root.appendingPathComponent("\(id).png", isDirectory: false)
    }

    func data(for id: String) -> Data? {
        guard let url = fileURL(for: id) else { return nil }
        return FileManager.default.contents(atPath: url.path)
    }

    func exists(id: String) -> Bool {
        guard let url = fileURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // written to a scratch file first, so a reader never sees half a picture
    func write(_ data: Data, for id: String) throws {
        guard let destination = fileURL(for: id) else {
            throw SnapshotStoreError.invalidIdentifier(id)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw SnapshotStoreError.rootUnavailable(error.localizedDescription)
        }
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: false)
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
        } catch {
            throw SnapshotStoreError.writeFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw SnapshotStoreError.writeFailed(error.localizedDescription)
        }
    }

    // the picture of a deleted layout follows it to the trash, and a layout that never
    // had one is not an error
    @discardableResult
    func trash(id: String) throws -> URL? {
        guard let url = fileURL(for: id) else { throw SnapshotStoreError.invalidIdentifier(id) }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var moved: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &moved)
        } catch {
            throw SnapshotStoreError.trashFailed(error.localizedDescription)
        }
        return moved as URL?
    }
}
