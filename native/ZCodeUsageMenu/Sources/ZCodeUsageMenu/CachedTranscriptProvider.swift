import Foundation

// The lock owns both the cached signature and snapshot, and serializes the entire
// synchronous load. No SQLite handle or transcript content is retained here.
final class CachedTranscriptProvider: UsageProvider, @unchecked Sendable {
    let id: UsageProviderID
    private let provider: any UsageProvider
    private let roots: [URL]
    private let lock = NSLock()
    private var signature: [String]?
    private var snapshot: UsageSnapshot?

    init(provider: any UsageProvider, roots: [URL]) {
        self.id = provider.id
        self.provider = provider
        self.roots = roots
    }

    func load() throws -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let current = fileSignature()
        if current == signature, let snapshot { return snapshot }
        let loaded = try provider.load()
        // If a writer appended during the scan, the pre-scan signature causes a
        // fresh read on the next tick, instead of treating incomplete data as cached.
        snapshot = loaded
        signature = current
        return loaded
    }

    private func fileSignature() -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        var result = [String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)]
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                result.append("missing:" + root.path)
                continue
            }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "jsonl" else { continue }
                result.append("\(url.path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values.fileResourceIdentifier))")
            }
        }
        return result.sorted()
    }
}
