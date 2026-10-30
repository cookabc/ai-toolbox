import Foundation
import XCTest

@testable import AIToolbox

final class ConfigFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "config-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// A dotfiles setup links `~/.codex/config.toml` into a repository. Writing must
    /// update the repository's file and leave the link in place.
    func testWritesThroughSymbolicLinks() throws {
        let dotfiles = root.appending(path: "dotfiles/config.toml")
        try FileManager.default.createDirectory(
            at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dotfiles)
        let link = root.appending(path: "config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles)

        try ConfigFile.update(link) { _ in Data("new".utf8) }

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), dotfiles.path)
        XCTAssertEqual(try String(contentsOf: dotfiles, encoding: .utf8), "new")
        let backup = URL(fileURLWithPath: link.path + ConfigFile.backupSuffix)
        let backupType =
            try FileManager.default.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType
        XCTAssertEqual(
            backupType, .typeRegular, "the backup holds the old contents, not a link to the new ones")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
    }

    func testFilesAreOwnerOnlyAndReplacedAtomically() throws {
        let file = root.appending(path: "settings.json")
        try Data("{}".utf8).write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        try ConfigFile.update(file) { _ in Data("{\"a\":1}".utf8) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual(
            attributes[.systemFileNumber] as? Int, before, "a new inode means rename, not rewrite in place")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasSuffix(".tmp")
        }
        XCTAssertEqual(leftovers, [])
    }

    /// Another program writing between our read and our write must not be undone:
    /// the edit is redone on its version.
    func testAConcurrentWriteIsNotOverwritten() throws {
        let file = root.appending(path: "config.toml")
        try Data("a = 1\n".utf8).write(to: file)
        var calls = 0
        try ConfigFile.update(file) { data in
            calls += 1
            if calls == 1 { try Data("a = 1\nb = 2\n".utf8).write(to: file) }
            return (data ?? Data()) + Data("c = 3\n".utf8)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a = 1\nb = 2\nc = 3\n")
    }

    func testUnchangedContentsAreNotWritten() throws {
        let file = root.appending(path: "config.toml")
        try Data("same".utf8).write(to: file)
        XCTAssertFalse(try ConfigFile.update(file) { $0 })
        XCTAssertFalse(try ConfigFile.update(file) { _ in nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ConfigFile.backupSuffix))
    }

    func testMissingFilesAreCreated() throws {
        let file = root.appending(path: "nested/config.toml")
        var received: Data?? = .none
        try ConfigFile.update(file) { data in
            received = .some(data)
            return Data("created".utf8)
        }
        XCTAssertEqual(received, .some(nil))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "created")
        XCTAssertNil(try ConfigFile.read(root.appending(path: "absent")))
    }
}
