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
        let cache = CachedTranscriptProvider(provider: TimestampProvider(), roots: [root])
        let first = try cache.load()
        XCTAssertEqual(try cache.load().refreshedAt, first.refreshedAt)
        try Data("{}\n{}\n".utf8).write(to: file)
        XCTAssertNotEqual(try cache.load().refreshedAt, first.refreshedAt)
    }
}

private struct TimestampProvider: UsageProvider {
    let id = UsageProviderID.codex
    func load() throws -> UsageSnapshot {
        UsageSnapshot(refreshedAt: Date(), totals: .zero, today: .zero, models: [])
    }
}
