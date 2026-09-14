import Foundation
import Darwin

/// A fallback for an idle WAL-mode database whose read-only open cannot initialize
/// its sidecars. Never opens the source for writing or ignores an existing WAL.
final class DatabaseReadCopy: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?
    private var signature: Signature?

    deinit { if let directory { try? FileManager.default.removeItem(at: directory) } }

    func read<T>(source: URL, load: (URL) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let before = try sourceSignature(source)
        if before != signature || directory == nil {
            let temporary = FileManager.default.temporaryDirectory.appending(path: "ai-usage-db-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let copy = temporary.appending(path: "db.sqlite")
            do {
                // APFS gives an atomic, copy-on-write clone without copying a large
                // database on every refresh. Other filesystems use a guarded copy.
                if clonefile(source.path, copy.path, 0) != 0 {
                    try FileManager.default.copyItem(at: source, to: copy)
                }
                guard try sourceSignature(source) == before else { throw UsageError.databaseChanging }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = temporary
            signature = before
        }
        guard let directory else { throw UsageError.databaseChanging }
        let result = try load(directory.appending(path: "db.sqlite"))
        guard try sourceSignature(source) == before else { throw UsageError.databaseChanging }
        return result
    }

    private func sourceSignature(_ source: URL) throws -> Signature {
        for suffix in ["-wal", "-journal"] {
            if FileManager.default.fileExists(atPath: source.path + suffix) {
                throw UsageError.databaseChanging
            }
        }
        // URL.resourceValues can return cached metadata on the same URL instance.
        // Fresh stat information is essential for detecting concurrent writes.
        let values = try FileManager.default.attributesOfItem(atPath: source.path)
        return Signature(path: source.path, size: (values[.size] as? NSNumber)?.intValue,
                         modified: values[.modificationDate] as? Date,
                         identity: String(describing: values[.systemFileNumber]))
    }

    private struct Signature: Equatable {
        let path: String
        let size: Int?
        let modified: Date?
        let identity: String
    }
}
