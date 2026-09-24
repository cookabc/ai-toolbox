import Foundation
import XCTest
@testable import AIToolbox

final class CodexModelCatalogTests: XCTestCase {
    /// What Codex itself downloads. The relay entry borrows the prompt from here,
    /// because a catalog entry without instructions fails to load at all.
    private let officialCatalog = """
    { "models": [
        {
            "slug": "hidden-model",
            "display_name": "Hidden",
            "visibility": "hide",
            "priority": 9,
            "context_window": 400000,
            "model_messages": { "instructions_template": "hidden prompt" }
        },
        {
            "slug": "gpt-6-astra",
            "display_name": "GPT-6-Astra",
            "visibility": "list",
            "priority": 1,
            "context_window": 272000,
            "max_context_window": 872000,
            "effective_context_window_percent": 95,
            "supported_reasoning_levels": [{ "effort": "low", "description": "Fast" }],
            "shell_type": "unified_exec",
            "truncation_policy": { "mode": "tokens", "limit": 10000 },
            "model_messages": { "instructions_template": "You are Codex." }
        }
    ]}
    """

    /// Relays often serve official models under their own names. The catalog must
    /// not then hold two entries with one slug, and the relay's entry is that model.
    func testARelayServingAnOfficialModelReplacesItsEntry() throws {
        let data = try CodexModelCatalog.make(
            providerName: "Relay", model: "hidden-model", officialCatalog: try fixture(officialCatalog)
        )
        let models = try models(in: data)
        let slugs = models.compactMap { $0["slug"] as? String }
        XCTAssertEqual(slugs, ["hidden-model", "gpt-6-astra"])
        XCTAssertEqual(models.first?["visibility"] as? String, "list")
        XCTAssertEqual(models.first?["context_window"] as? Int, 400_000, "metadata of the same model")
        XCTAssertEqual((models.first?["model_messages"] as? [String: Any])?["instructions_template"] as? String, "hidden prompt")
    }

    func testRelayEntryIsListedAndOfficialEntriesStayResolvable() throws {
        let data = try CodexModelCatalog.make(
            providerName: "ARouter",
            model: "deepseek-v4.1-flash",
            officialCatalog: try fixture(officialCatalog)
        )
        let models = try models(in: data)

        XCTAssertEqual(models.count, 3)
        let relay = try XCTUnwrap(models.first)
        XCTAssertEqual(relay["slug"] as? String, "deepseek-v4.1-flash")
        XCTAssertEqual(relay["display_name"] as? String, "deepseek-v4.1-flash")
        XCTAssertEqual(relay["description"] as? String, "由 ARouter 提供")
        XCTAssertEqual(relay["visibility"] as? String, "list")
        XCTAssertEqual(relay["supported_in_api"] as? Bool, true)
        // Metadata comes from the official entry, so Codex stops falling back.
        XCTAssertEqual(relay["context_window"] as? Int, 272_000)
        XCTAssertEqual(relay["max_context_window"] as? Int, 872_000)
        XCTAssertEqual(relay["effective_context_window_percent"] as? Int, 95)
        // The picker ranks the relay's model first, and the published prompt is the
        // official one rather than an invented substitute.
        XCTAssertEqual(relay["priority"] as? Int, 1)
        XCTAssertEqual(relay["shell_type"] as? String, "unified_exec")
        let messages = relay["model_messages"] as? [String: Any]
        XCTAssertEqual(messages?["instructions_template"] as? String, "You are Codex.")

        // Official models keep their metadata for slugs the rest of the config still
        // names, but they are taken out of the picker: the relay does not serve them.
        for official in models.dropFirst() {
            XCTAssertEqual(official["visibility"] as? String, "hide")
            XCTAssertNotNil(official["model_messages"])
        }
        XCTAssertEqual(models.last?["slug"] as? String, "gpt-6-astra")
        XCTAssertEqual(models.last?["context_window"] as? Int, 272_000)
    }

    /// The shortest entry Codex accepts, and the reason the prompt is borrowed:
    /// without instructions the whole config fails to load, which is worse than the
    /// warning this feature removes.
    func testEntryKeepsCodexLoadableWithIncompleteOfficialCatalog() throws {
        let thin = """
        { "models": [{ "slug": "only", "display_name": "Only", "visibility": "list", "base_instructions": "Be brief." }] }
        """
        let data = try CodexModelCatalog.make(providerName: "", model: "k3", officialCatalog: try fixture(thin))
        let relay = try XCTUnwrap(try models(in: data).first)

        XCTAssertEqual(relay["base_instructions"] as? String, "Be brief.")
        XCTAssertEqual(relay["context_window"] as? Int, CodexModelCatalog.defaultContextWindow)
        XCTAssertEqual(relay["description"] as? String, "由 k3 提供")
    }

    func testMissingOfficialCatalogIsReported() throws {
        let url = try fixture(nil)
        XCTAssertThrowsError(try CodexModelCatalog.make(providerName: "ARouter", model: "k3", officialCatalog: url)) { error in
            XCTAssertEqual(error as? LiveConfigError, .missingModelCatalog(url))
        }
        XCTAssertThrowsError(try CodexModelCatalog.make(providerName: "ARouter", model: "  ", officialCatalog: url)) { error in
            XCTAssertEqual(error as? LiveConfigError, .missingField("模型"))
        }
    }

    // MARK: - Helpers

    private func models(in data: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["models"] as? [[String: Any]])
    }

    /// Writes a catalog fixture to a temporary directory and returns its URL.
    private func fixture(_ contents: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "models_cache.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        if let contents {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.data(using: .utf8)!.write(to: url)
        }
        return url
    }
}
