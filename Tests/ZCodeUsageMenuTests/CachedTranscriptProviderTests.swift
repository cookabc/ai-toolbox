import Foundation
import XCTest
@testable import ZCodeUsageMenu

final class CachedTranscriptProviderTests: XCTestCase {
    func testUnchangedFilesReuseSnapshotAndChangedFilesInvalidate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "session.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let provider = TimestampProvider()
        let cache = CachedTranscriptProvider(provider: provider, roots: [root])
        let first = try cache.load()
        let cached = try cache.load()
        XCTAssertGreaterThanOrEqual(cached.refreshedAt, first.refreshedAt)
        XCTAssertEqual(provider.callCount, 1)
        try Data("{}\n{}\n".utf8).write(to: file)
        XCTAssertNotEqual(try cache.load().refreshedAt, first.refreshedAt)
        XCTAssertEqual(provider.callCount, 2)
    }
}

private final class TimestampProvider: UsageProvider, @unchecked Sendable {
    let id = UsageProviderID.codex
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    func load() throws -> UsageSnapshot {
        lock.withLock { calls += 1 }
        return UsageSnapshot(refreshedAt: Date(), totals: .zero, today: .zero, models: [])
    }
}
