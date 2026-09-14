import Foundation
import XCTest
@testable import ZCodeUsageMenu

final class DatabaseReadCopyTests: XCTestCase {
    func testCopyIsPrivateAndReusedUntilSourceChanges() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("original".utf8).write(to: source)
        let reader = DatabaseReadCopy()
        let first = try reader.read(source: source) { copy in
            XCTAssertNotEqual(copy, source)
            XCTAssertEqual(try Data(contentsOf: copy), Data("original".utf8))
            try Data("copy only".utf8).write(to: copy)
            return copy
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertEqual(try reader.read(source: source) { $0 }, first)
        try Data("updated source".utf8).write(to: source)
        XCTAssertNotEqual(try reader.read(source: source) { $0 }, first)
    }

    func testExistingWALAndChangesDuringReadAreRejected() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: wal)
        }
        try Data("original".utf8).write(to: source)
        try Data().write(to: wal)
        let reader = DatabaseReadCopy()
        XCTAssertThrowsError(try reader.read(source: source) { _ in XCTFail("Must not read a copy without its WAL") })
        try FileManager.default.removeItem(at: wal)
        XCTAssertThrowsError(try reader.read(source: source) { _ in
            try Data("changed during query".utf8).write(to: source)
        })
    }
}
