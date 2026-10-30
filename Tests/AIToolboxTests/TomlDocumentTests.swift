import Foundation
import XCTest

@testable import AIToolbox

final class TomlDocumentTests: XCTestCase {
    /// Shaped like a real `~/.codex/config.toml`: multi-line arrays, quoted keys with
    /// dots and slashes, comments, blank lines.
    private let realistic = """
        # Codex configuration
        model_auto_compact_token_limit = 900000
        web_search = "live"
        notify = [
            "/Users/someone/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/Client",
            "turn-ended", # trailing comment inside an array
        ]
        model_provider = "openai" # default provider
        model = 'gpt-6-sol'

        [marketplaces.openai-bundled]
        source_type = "local"

        [plugins."documents@openai-primary-runtime"]
        enabled = true

        [projects."/Users/someone/Documents"]
        trust_level = "trusted"

        [profiles.fast] # quick profile
        model = "gpt-6-luna"
        matrix = [
          [1, 2],
          [3, 4]
        ]
        developer_instructions = \"\"\"
        Answer like this:
        [summary]
        model = "not a key"
        \"\"\"
        """

    func testUntouchedFilesRoundTripExactly() throws {
        XCTAssertEqual(try TomlDocument(realistic).text, realistic)
        let crlf = realistic.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try TomlDocument(crlf).text, crlf)
    }

    func testReadsOnlyWhatIsReallyAtTheRoot() throws {
        let document = try TomlDocument(realistic)
        XCTAssertEqual(document.string("model"), "gpt-6-sol")
        XCTAssertEqual(
            document.string("model_provider"), "openai", "the trailing comment is not part of the value")
        XCTAssertEqual(
            document.string("model", in: ["profiles", "fast"]), "gpt-6-luna",
            "a header with a comment after it is still a header")
        XCTAssertNil(document.string("summary"))
        XCTAssertEqual(document.childTables(of: ["plugins"]), ["documents@openai-primary-runtime"])
        XCTAssertEqual(
            document.string("trust_level", in: ["projects", "/Users/someone/Documents"]), "trusted")
        XCTAssertEqual(
            document.string("developer_instructions", in: ["profiles", "fast"]),
            "Answer like this:\n[summary]\nmodel = \"not a key\"\n")
    }

    /// The old line-based editor did not recognise `[profiles.fast] # …` as a
    /// header, so it took the profile's `model` for the root one and rewrote it.
    func testSettingARootKeyNeverTouchesATable() throws {
        let text = """
            model_provider = "openai"

            [profiles.fast] # quick profile
            model = "gpt-5-mini"
            """
        var document = try TomlDocument(text)
        try document.setString("model", "k3", after: "model_provider")
        XCTAssertEqual(
            document.text,
            """
            model_provider = "openai"
            model = "k3"

            [profiles.fast] # quick profile
            model = "gpt-5-mini"
            """)
    }

    func testReplacingAValueKeepsItsKeySpellingAndComment() throws {
        var document = try TomlDocument("model=\"a\"   # default\n\"model_provider\" = 'openai'\n")
        try document.setString("model", "b")
        try document.setString("model_provider", "relay")
        XCTAssertEqual(document.text, "model=\"b\"   # default\n\"model_provider\" = \"relay\"\n")
    }

    func testKeysAfterAnArrayOfTablesAreNotRoot() throws {
        let document = try TomlDocument("[[hooks]]\nmodel = \"x\"\n")
        XCTAssertNil(document.string("model"))
    }

    func testRootKeysAreInsertedAboveTheFirstTableAndItsComment() throws {
        var document = try TomlDocument("# Providers\n[model_providers.relay]\nname = \"R\"\n")
        try document.setString("model_provider", "relay")
        XCTAssertEqual(
            document.text, "model_provider = \"relay\"\n# Providers\n[model_providers.relay]\nname = \"R\"\n")
    }

    func testInsertionIntoAFileWithoutTrailingNewline() throws {
        var document = try TomlDocument("model = \"a\"")
        try document.setString("model_provider", "relay", after: "model")
        XCTAssertEqual(document.text, "model = \"a\"\nmodel_provider = \"relay\"\n")

        var tables = try TomlDocument("[tui]\ntheme = \"dark\"")
        try tables.appendTable(["model_providers", "relay"], values: [("name", "R")])
        XCTAssertEqual(tables.text, "[tui]\ntheme = \"dark\"\n\n[model_providers.relay]\nname = \"R\"\n")
    }

    func testInsertedLinesFollowTheFilesLineEndings() throws {
        var document = try TomlDocument("model = \"a\"\r\n\r\n[tui]\r\ntheme = \"dark\"\r\n")
        try document.setString("model_provider", "relay", after: "model")
        try document.appendTable(["model_providers", "relay"], values: [("name", "R")])
        XCTAssertEqual(
            document.text,
            "model = \"a\"\r\nmodel_provider = \"relay\"\r\n\r\n[tui]\r\ntheme = \"dark\"\r\n\r\n[model_providers.relay]\r\nname = \"R\"\r\n"
        )
    }

    /// A quoted header names the same table as a bare one. Missing that used to
    /// append a second definition, which Codex refuses to load.
    func testQuotedHeadersAreTheSameTable() throws {
        let text = "[model_providers.\"relay\"]\nname = \"Relay\"\nbase_url = \"https://a.test\"\n"
        let next = try CodexTomlEditor.upsertProvider(
            text, id: "relay", name: "Relay", baseURL: "https://b.test",
            apiKey: nil, makeCurrent: false, model: nil)
        XCTAssertEqual(next.components(separatedBy: "[model_providers.").count - 1, 1)
        XCTAssertEqual(CodexTomlEditor.providerFields(in: next, id: "relay")["base_url"], "https://b.test")
    }

    func testRemovingATableKeepsTheCommentThatIntroducesTheNextOne() throws {
        var document = try TomlDocument(
            """
            model = "m"

            [model_providers.relay]
            # the relay
            name = "R"

            [model_providers.relay.http_headers]
            X-Team = "a"

            # Profiles below
            [profiles.x]
            model = "y"
            """)
        try document.removeTable(["model_providers", "relay"])
        XCTAssertEqual(
            document.text,
            """
            model = "m"

            # Profiles below
            [profiles.x]
            model = "y"
            """)
    }

    func testRemovingTheLastTableLeavesNoDanglingBlankLine() throws {
        var document = try TomlDocument("model = \"m\"\n\n[model_providers.relay]\nname = \"R\"\n")
        try document.removeTable(["model_providers", "relay"])
        XCTAssertEqual(document.text, "model = \"m\"\n")
    }

    /// Removing a table must not reach into a multi-line string elsewhere.
    func testRemovingATableLeavesMultiLineStringsAlone() throws {
        let preserved = "notes = \"\"\"\na\n\n\n\nb\n\"\"\"\n"
        var document = try TomlDocument(preserved + "\n[model_providers.relay]\nname = \"R\"\n")
        try document.removeTable(["model_providers", "relay"])
        XCTAssertEqual(document.text, preserved)
    }

    func testProvidersDefinedOutsideTheirOwnTableAreNotEdited() throws {
        for text in [
            "model_providers.relay.name = \"R\"\n",
            "model_providers = { relay = { name = \"R\" } }\n",
            "[model_providers]\nrelay = { name = \"R\" }\n",
            "[model_providers]\nrelay.name = \"R\"\n",
        ] {
            XCTAssertThrowsError(
                try CodexTomlEditor.upsertProvider(
                    text, id: "relay", name: "R", baseURL: "https://r.test", apiKey: nil, makeCurrent: true,
                    model: nil
                ), text
            ) { XCTAssertEqual($0 as? LiveConfigError, .unsupportedCodexLayout("relay")) }
        }
        // An unrelated provider in a `[model_providers]` table is no obstacle.
        XCTAssertNoThrow(
            try CodexTomlEditor.upsertProvider(
                "[model_providers]\nother = { name = \"O\" }\n", id: "relay", name: "R",
                baseURL: "https://r.test", apiKey: nil, makeCurrent: false, model: nil
            ))
    }

    func testMalformedFilesAreRejectedWithTheirLine() {
        for (text, line) in [
            ("model = \"a\"\nnot toml\n", 2),
            ("a = \"unterminated\n", 1),
            ("a = [1, 2\n", 2),
            ("[table\n", 1),
            ("a = 1 2\n", 1),
            ("a = \"\"\"never closed\n", 2),
        ] {
            XCTAssertThrowsError(try TomlDocument(text), text) { error in
                XCTAssertEqual((error as? TomlDocument.ParseError)?.line, line, text)
            }
        }
    }

    func testValueSyntaxIsUnderstood() throws {
        let document = try TomlDocument(
            """
            a = "tab\\there \\u00e9 \\"quoted\\" # not a comment" # comment
            b = 'C:\\raw\\path'
            c = 1979-05-27 07:32:00Z
            d = { x = 1, y = [1, { z = "}" }] }
            e = \"\"\"
            one \\
              two\"\"\"
            f = '''
            line\"\"\"'''
            g = +inf
            """)
        XCTAssertEqual(document.string("a"), "tab\there é \"quoted\" # not a comment")
        XCTAssertEqual(document.string("b"), "C:\\raw\\path")
        XCTAssertNil(document.string("c"))
        XCTAssertEqual(document.string("e"), "one two")
        XCTAssertEqual(document.string("f"), "line\"\"\"")
    }

    func testQuotedValuesRoundTripAnything() throws {
        for value in [
            "plain", "with \"quotes\"", "back\\slash", "new\nline", "tab\t", "bell\u{7}", "中文 🚀", "#hash",
        ] {
            var document = try TomlDocument("")
            try document.setString("key", value)
            XCTAssertEqual(try TomlDocument(document.text).string("key"), value)
            XCTAssertEqual(document.text.filter { $0 == "\n" }.count, 1, "a value never spans lines")
        }
    }
}
