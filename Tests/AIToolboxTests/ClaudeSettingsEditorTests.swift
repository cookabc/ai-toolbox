import Foundation
import XCTest
@testable import AIToolbox

final class ClaudeSettingsEditorTests: XCTestCase {
    private func edit(set: [(String, String)] = [], remove: Set<String> = []) -> ClaudeSettingsEditor.Edit {
        ClaudeSettingsEditor.Edit(set: set.map { (key: $0.0, value: $0.1) }, remove: remove)
    }

    private func apply(_ edit: ClaudeSettingsEditor.Edit, to text: String?) throws -> String {
        String(decoding: try ClaudeSettingsEditor.apply(edit, to: text.map { Data($0.utf8) }), as: UTF8.self)
    }

    /// Everything outside `env` is byte-for-byte what it was: order, spacing, the
    /// user's own formatting, unescaped slashes.
    func testOnlyTheEnvObjectChanges() throws {
        let original = """
        {
          "permissions": {"allow": ["Bash(git log:*)"], "deny": []},
          "env": {
            "ANTHROPIC_BASE_URL": "https://old.example/anthropic",
            "MY_FLAG": true,
            "MAX_TOKENS": 32000,
            "ANTHROPIC_MODEL": "old"
          },
          "theme": "dark",
          "hooks": { "Stop": [ { "command": "say done" } ] }
        }

        """
        let result = try apply(edit(set: [("ANTHROPIC_MODEL", "new"), ("ANTHROPIC_API_KEY", "sk/with/slashes")],
                                    remove: ["ANTHROPIC_BASE_URL"]), to: original)
        XCTAssertEqual(result, """
        {
          "permissions": {"allow": ["Bash(git log:*)"], "deny": []},
          "env": {
            "MY_FLAG": true,
            "MAX_TOKENS": 32000,
            "ANTHROPIC_MODEL": "new",
            "ANTHROPIC_API_KEY": "sk/with/slashes"
          },
          "theme": "dark",
          "hooks": { "Stop": [ { "command": "say done" } ] }
        }

        """)
    }

    func testEnvIsAddedWhenAbsent() throws {
        XCTAssertEqual(try apply(edit(set: [("A", "1")]), to: "{\n  \"theme\": \"dark\"\n}\n"),
                       "{\n  \"env\": {\n    \"A\": \"1\"\n  },\n  \"theme\": \"dark\"\n}\n")
        XCTAssertEqual(try apply(edit(set: [("A", "1")]), to: "{}"), "{\n  \"env\": {\n    \"A\": \"1\"\n  }\n}")
        XCTAssertEqual(try apply(edit(set: [("A", "1")]), to: nil), "{\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n")
        XCTAssertEqual(try apply(edit(set: [("A", "1")]), to: "  \n"), "{\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n")
        let compact = try apply(edit(set: [("A", "1")]), to: #"{"theme":"dark"}"#)
        let object = try JSONSerialization.jsonObject(with: Data(compact.utf8)) as? [String: Any]
        XCTAssertEqual((object?["env"] as? [String: String])?["A"], "1")
        XCTAssertEqual(object?["theme"] as? String, "dark")
    }

    func testRemovingEverythingLeavesAnEmptyObject() throws {
        XCTAssertEqual(try apply(edit(remove: ["A"]), to: "{\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n"),
                       "{\n  \"env\": {}\n}\n")
    }

    func testCompactEnvIsReindented() throws {
        let result = try apply(edit(set: [("B", "2")]), to: "{\n  \"env\": {\"A\": \"1\"}\n}\n")
        XCTAssertEqual(result, "{\n  \"env\": {\n    \"A\": \"1\",\n    \"B\": \"2\"\n  }\n}\n")
    }

    func testValuesAreEscaped() throws {
        let result = try apply(edit(set: [("A", "quote \" backslash \\ newline \n 中文")]), to: "{}")
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        XCTAssertEqual((object?["env"] as? [String: String])?["A"], "quote \" backslash \\ newline \n 中文")
    }

    func testKeysContainingEscapesAreMatched() throws {
        let result = try apply(edit(remove: ["A/B"]), to: #"{"env": {"A\/B": "1", "C": "2"}}"#)
        let env = (try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])?["env"] as? [String: String]
        XCTAssertEqual(env, ["C": "2"])
    }

    func testInvalidDocumentsAreRefused() {
        XCTAssertThrowsError(try apply(edit(set: [("A", "1")]), to: "{ broken"))
        XCTAssertThrowsError(try apply(edit(set: [("A", "1")]), to: "[1, 2]"))
        XCTAssertThrowsError(try apply(edit(set: [("A", "1")]), to: #"{"env": null}"#))
        XCTAssertThrowsError(try apply(edit(set: [("A", "1")]), to: #"{"env": "x"}"#))
    }

    func testEnvValuesAreReadAsWritten() throws {
        let env = try ClaudeSettingsEditor.env(in: Data(#"{"env": {"S": "x", "N": 3, "B": true}}"#.utf8))
        XCTAssertEqual(env, ["S": "x", "N": "3", "B": "true"])
    }
}
