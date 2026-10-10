import Foundation
import XCTest
@testable import AIToolbox

final class PerProviderConfigTests: XCTestCase {
    // MARK: - The broadcast is gone

    /// The regression guard for the behaviour that overwrote aliases the user had
    /// set for a reason: saving a provider's model must not touch keys the provider
    /// does not declare.
    func testSavingAModelNoLongerRewritesFamilyAliases() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write("""
        { "env": {
            "ANTHROPIC_BASE_URL": "https://a.test",
            "ANTHROPIC_MODEL": "old-model",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4",
            "CLAUDE_CODE_SUBAGENT_MODEL": "claude-haiku-4",
            "CLAUDE_CODE_EFFORT_LEVEL": "high"
        }}
        """, to: url)

        try save(url, baseURL: "https://b.test", model: "deepseek-v4.1-flash")

        let env = try env(of: url)
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "deepseek-v4.1-flash")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "claude-opus-4")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "claude-haiku-4")
        XCTAssertEqual(env["CLAUDE_CODE_EFFORT_LEVEL"], "high")
    }

    /// The useful half of the old behaviour survives — but only when the provider
    /// explicitly declares it. A relay that serves one model for every alias can
    /// still say so.
    func testDeclaredPerProviderKeysAreWritten() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try save(url, baseURL: "https://relay.test/v1", model: "deepseek-v4.1-flash", extraEnv: [
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4.1-flash",
            "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4.1-flash",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1048576",
        ])

        let env = try env(of: url)
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://relay.test")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "deepseek-v4.1-flash")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"], "deepseek-v4.1-flash")
        XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "1048576")
        // An alias the provider did not declare stays absent.
        XCTAssertNil(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
    }

    /// Switching from a relay that claimed the aliases to one that does not must
    /// hand them back, or the second relay inherits a model it never heard of.
    func testSwitchingAwayFromAProviderRemovesTheKeysItOwned() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try save(url, baseURL: "https://relay-a.test/v1", model: "model-a", extraEnv: [
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "model-a",
            "CLAUDE_CODE_EFFORT_LEVEL": "high",
        ])
        try save(url, baseURL: "https://relay-b.test/v1", model: "model-b",
                 extraEnv: ["CLAUDE_CODE_EFFORT_LEVEL": "low"],
                 removingKeys: ["ANTHROPIC_DEFAULT_OPUS_MODEL"])

        let env = try env(of: url)
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"])
        XCTAssertEqual(env["CLAUDE_CODE_EFFORT_LEVEL"], "low")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "model-b")
    }

    /// Only the curated list can be written, so a hand-edited providers.json cannot
    /// turn a provider into a way to inject arbitrary environment variables.
    func testKeysOutsideTheCuratedListAreIgnored() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try save(url, baseURL: "https://relay.test/v1", model: "m",
                 extraEnv: ["AWS_SECRET_ACCESS_KEY": "nope", "PATH": "/evil"])

        let env = try env(of: url)
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(env["PATH"])
    }

    /// A key no provider owns never lands in `removingKeys`, so a hand-written
    /// setting survives every switch.
    func testKeysNoProviderOwnsAreNeverRemoved() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(#"{ "env": { "ANTHROPIC_MODEL": "m", "MY_OWN_SETTING": "keep-me" } }"#, to: url)
        try save(url, baseURL: "https://relay.test/v1", model: "m2", removingKeys: ["ANTHROPIC_DEFAULT_OPUS_MODEL"])
        XCTAssertEqual(try env(of: url)["MY_OWN_SETTING"], "keep-me")
    }

    /// Switching to a provider without a key must not leave the previous provider's
    /// key in place: Claude Code would send it to the new provider's host.
    func testAProviderWithoutAKeyDoesNotInheritThePreviousOne() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try save(url, baseURL: "https://relay-a.test", model: "m", apiKey: "sk-relay-a-secret")
        try save(url, baseURL: "https://local-proxy.test", model: "m", apiKey: "")
        let env = try env(of: url)
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
    }

    /// Many relays only accept `Authorization: Bearer`, which Claude Code sends for
    /// `ANTHROPIC_AUTH_TOKEN`. The two variables are exclusive.
    func testCredentialStyleChoosesTheVariable() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try save(url, baseURL: "https://relay.test", model: "m", apiKey: "sk-token", credential: .authToken)
        var env = try env(of: url)
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "sk-token")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        let loaded = try ClaudeLiveSettingsStore.load(from: url)
        XCTAssertEqual(loaded.settings.credential, .authToken)
        XCTAssertEqual(loaded.secret, "sk-token")

        try save(url, baseURL: "https://relay.test", model: "m", apiKey: "sk-key", credential: .apiKey)
        env = try self.env(of: url)
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-key")
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(try ClaudeLiveSettingsStore.load(from: url).settings.credential, .apiKey)
    }

    // MARK: - Reading and storage

    /// What the "Import" action relies on: the aliases already in settings.json come back
    /// as the provider's own keys, so importing a working setup keeps it working.
    func testLoadCapturesPerProviderKeys() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write("""
        { "env": {
            "ANTHROPIC_BASE_URL": "https://relay.test",
            "ANTHROPIC_MODEL": "m",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "m",
            "CLAUDE_CODE_EFFORT_LEVEL": "high",
            "UNRELATED": "x"
        }}
        """, to: url)

        let loaded = try ClaudeLiveSettingsStore.load(from: url)
        XCTAssertEqual(loaded.settings.extraEnv["ANTHROPIC_DEFAULT_SONNET_MODEL"], "m")
        XCTAssertEqual(loaded.settings.extraEnv["CLAUDE_CODE_EFFORT_LEVEL"], "high")
        XCTAssertNil(loaded.settings.extraEnv["UNRELATED"])
        XCTAssertNil(loaded.settings.extraEnv["ANTHROPIC_BASE_URL"])
    }

    /// A library written before per-provider config and credential styles existed
    /// must still load; the new fields come back with their defaults.
    func testLibraryDecodesProvidersSavedByEarlierVersions() throws {
        let id = UUID()
        let legacy = """
        {
          "version": 1,
          "providers": [
            {
              "id": "\(id.uuidString)",
              "app": "claude",
              "name": "Old Relay",
              "slug": "old-relay",
              "baseURL": "https://old.test/v1",
              "model": "old-model",
              "apiKey": "sk-old"
            }
          ]
        }
        """
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(legacy, to: url)

        let providers = try ProviderLibraryStore(url: url).load()
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].name, "Old Relay")
        XCTAssertEqual(providers[0].extraEnv, [:])
        XCTAssertEqual(providers[0].credential, .apiKey)
    }

    func testLibraryRoundTripsEveryField() throws {
        let url = try uniqueURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProviderLibraryStore(url: url)
        let provider = StoredProvider(
            app: .claude, name: "Relay", slug: "relay", baseURL: "https://relay.test/v1", model: "m",
            apiKey: "sk-x", credential: .authToken, extraEnv: ["ANTHROPIC_DEFAULT_OPUS_MODEL": "m"]
        )
        try store.save([provider])
        XCTAssertEqual(try store.load(), [provider])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("https://relay.test/v1"), "slashes are not escaped")
    }

    // MARK: - Helpers

    private func save(
        _ url: URL,
        baseURL: String,
        model: String,
        apiKey: String = "",
        credential: ClaudeCredential = .apiKey,
        extraEnv: [String: String] = [:],
        removingKeys: Set<String> = []
    ) throws {
        try ClaudeLiveSettingsStore.save(to: url, ClaudeLiveSettingsStore.edit(
            baseURL: baseURL, model: model, apiKey: apiKey, credential: credential,
            extraEnv: extraEnv, removingKeys: removingKeys
        ))
    }

    private func uniqueURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "settings.json")
    }

    private func write(_ json: String, to url: URL) throws {
        try json.data(using: .utf8)!.write(to: url)
    }

    private func env(of url: URL) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?["env"] as? [String: String] ?? [:]
    }
}
