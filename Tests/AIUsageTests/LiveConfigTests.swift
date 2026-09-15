import Foundation
import XCTest
@testable import AIUsage

final class LiveConfigTests: XCTestCase {
    func testMaskKeepsLastFourCharacters() {
        XCTAssertEqual(SecretDisplay.mask("sk-abcdefghijk"), "••••hijk")
        XCTAssertEqual(SecretDisplay.mask(""), "未设置")
    }

    func testClaudeSavePreservesUnrelatedEnvAndMasksKey() throws {
        let url = try uniqueURL("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ClaudeLiveSettingsStore.save(
            to: url,
            baseURL: "https://example.test/v1",
            model: "opus",
            apiKey: "sk-test-secret-key",
            keepExistingKeyIfEmpty: false
        )
        let extra = """
        { "env": { "ANTHROPIC_API_KEY": "sk-test-secret-key", "ANTHROPIC_BASE_URL": "https://example.test/v1", "CLAUDE_CODE_EFFORT_LEVEL": "high" } }
        """
        try extra.data(using: .utf8)!.write(to: url)
        try ClaudeLiveSettingsStore.save(
            to: url,
            baseURL: "https://relay.test/",
            model: "sonnet",
            apiKey: nil,
            keepExistingKeyIfEmpty: true
        )
        let loaded = try ClaudeLiveSettingsStore.load(from: url)
        XCTAssertEqual(loaded.settings.baseURL, "https://relay.test/")
        XCTAssertEqual(loaded.settings.model, "sonnet")
        XCTAssertEqual(loaded.secret, "sk-test-secret-key")
        XCTAssertEqual(loaded.settings.maskedAPIKey, "••••-key")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let env = object?["env"] as? [String: String]
        XCTAssertEqual(env?["CLAUDE_CODE_EFFORT_LEVEL"], "high")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".ai-usage.bak"))
    }

    func testClaudeClearRemovesAPIOverlayOnly() throws {
        let url = try uniqueURL("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try """
        { "env": {
            "ANTHROPIC_API_KEY": "sk-keep-out",
            "ANTHROPIC_BASE_URL": "https://example.test",
            "ANTHROPIC_MODEL": "opus",
            "CLAUDE_CODE_EFFORT_LEVEL": "high"
        }}
        """.data(using: .utf8)!.write(to: url)
        try ClaudeLiveSettingsStore.clearAPIOverlay(at: url)
        let loaded = try ClaudeLiveSettingsStore.load(from: url)
        XCTAssertFalse(loaded.settings.hasAPIKey)
        XCTAssertEqual(loaded.settings.baseURL, "")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let env = object?["env"] as? [String: String]
        XCTAssertEqual(env?["CLAUDE_CODE_EFFORT_LEVEL"], "high")
        XCTAssertNil(env?["ANTHROPIC_API_KEY"])
    }

    func testCodexUpsertAndSwitchPreserveUnrelatedTables() throws {
        let original = """
        model = "gpt-5"
        personality = "pragmatic"

        [plugins.chrome]
        enabled = true

        [tui]
        theme = "solarized-light"
        """
        let added = try CodexTomlEditor.upsertProvider(
            original,
            id: "relay",
            name: "Relay",
            baseURL: "https://relay.test/v1",
            apiKey: "sk-relay-aaaa",
            makeCurrent: true,
            model: "k3"
        )
        XCTAssertTrue(added.contains("personality = \"pragmatic\""))
        XCTAssertTrue(added.contains("[plugins.chrome]"))
        XCTAssertTrue(added.contains("[tui]"))
        XCTAssertTrue(added.contains("theme = \"solarized-light\""))
        let settings = CodexTomlEditor.load(added)
        XCTAssertEqual(settings.currentProviderID, "relay")
        XCTAssertEqual(settings.model, "k3")
        XCTAssertEqual(settings.providers.map(\.id), ["openai", "relay"])
        XCTAssertEqual(CodexTomlEditor.secret(in: added, id: "relay"), "sk-relay-aaaa")

        let switched = CodexTomlEditor.switchProvider(added, to: "openai", model: nil)
        XCTAssertEqual(CodexTomlEditor.load(switched).currentProviderID, "openai")
        XCTAssertTrue(switched.contains("[model_providers.relay]"))

        let removed = try CodexTomlEditor.removeProvider(switched, id: "relay")
        XCTAssertFalse(removed.contains("model_providers.relay"))
        XCTAssertTrue(removed.contains("[plugins.chrome]"))
        XCTAssertEqual(CodexTomlEditor.load(removed).currentProviderID, "openai")
    }

    func testCodexRejectsReservedAndInvalidIDs() {
        XCTAssertThrowsError(try CodexTomlEditor.upsertProvider(
            "", id: "openai", name: "x", baseURL: "https://example.test", apiKey: "k", makeCurrent: true, model: nil
        )) { error in
            XCTAssertEqual(error as? LiveConfigError, .reservedProviderID)
        }
        XCTAssertThrowsError(try CodexTomlEditor.upsertProvider(
            "", id: "1bad", name: "x", baseURL: "https://example.test", apiKey: "k", makeCurrent: true, model: nil
        )) { error in
            XCTAssertEqual(error as? LiveConfigError, .invalidProviderID)
        }
    }

    func testCodexEditKeepsExistingTokenWhenKeyOmitted() throws {
        let first = try CodexTomlEditor.upsertProvider(
            "model = \"a\"\n",
            id: "relay",
            name: "Relay",
            baseURL: "https://a.test",
            apiKey: "sk-old-token",
            makeCurrent: true,
            model: nil
        )
        let edited = try CodexTomlEditor.upsertProvider(
            first,
            id: "relay",
            name: "Relay 2",
            baseURL: "https://b.test",
            apiKey: nil,
            makeCurrent: false,
            model: nil
        )
        XCTAssertEqual(CodexTomlEditor.secret(in: edited, id: "relay"), "sk-old-token")
        XCTAssertEqual(CodexTomlEditor.providerFields(in: edited, id: "relay")["name"], "Relay 2")
        XCTAssertEqual(CodexTomlEditor.providerFields(in: edited, id: "relay")["base_url"], "https://b.test")
    }

    func testProviderLibraryRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderLibraryStore(url: directory.appending(path: "providers.json"))
        let providers = [
            StoredProvider(app: .claude, name: "Kimi", slug: "kimi", baseURL: "https://kimi.test", model: "k3", apiKey: "sk-a"),
            StoredProvider(app: .codex, name: "Relay", slug: "relay", baseURL: "https://relay.test", model: "gpt-5", apiKey: "sk-b"),
        ]
        try store.save(providers)
        XCTAssertEqual(try store.load(), providers)
    }

    @MainActor
    func testViewModelActivatesClaudeProviderThroughInjectedPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = LiveConfigPaths(
            claudeSettings: directory.appending(path: "settings.json"),
            codexConfig: directory.appending(path: "config.toml")
        )
        let library = ProviderLibraryStore(url: directory.appending(path: "providers.json"))
        let provider = StoredProvider(
            app: .claude, name: "Test", slug: "test", baseURL: "https://example.test", model: "haiku", apiKey: "sk-view-model-key"
        )
        try library.save([provider])

        let model = LiveConfigViewModel(paths: paths, library: library)
        model.reload()
        model.activate(provider)
        for _ in 0..<100 where model.isBusy {
            await Task.yield()
        }

        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
        let loaded = try ClaudeLiveSettingsStore.load(from: paths.claudeSettings)
        XCTAssertEqual(loaded.settings.baseURL, "https://example.test")
        XCTAssertEqual(loaded.secret, "sk-view-model-key")
    }

    @MainActor
    func testStatusIsScopedToItsToolAndSaveWithoutSwitchKeepsCurrentProvider() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = LiveConfigPaths(
            claudeSettings: directory.appending(path: "settings.json"),
            codexConfig: directory.appending(path: "config.toml")
        )
        let library = ProviderLibraryStore(url: directory.appending(path: "providers.json"))
        try #"{ "env": {} }"#.data(using: .utf8)!.write(to: paths.claudeSettings)
        try """
        model = "gpt-5"
        model_provider = "openai"
        """.data(using: .utf8)!.write(to: paths.codexConfig)

        let model = LiveConfigViewModel(paths: paths, library: library)
        model.loadOnce()
        model.app = .codex
        model.beginCreate()
        model.draftName = "ANexto"
        model.draftSlug = "anexto"
        model.draftBaseURL = "https://relay.test/v1"
        model.draftModel = "deepseek-v4.1-flash"
        model.draftAPIKey = "sk-test"
        model.saveDraft(activate: false)

        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.statusMessage)
        XCTAssertEqual(model.codexLive.currentProviderID, "openai")
        XCTAssertEqual(model.codexLive.model, "gpt-5")

        model.app = .claude
        XCTAssertNil(model.statusMessage, "Codex 的结果不应显示在 Claude Code 标签下")
        model.app = .codex
        XCTAssertNotNil(model.statusMessage)
    }

    @MainActor
    func testClaudeAndCodexProvidersAreFilteredSeparately() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ProviderLibraryStore(url: directory.appending(path: "providers.json"))
        try library.save([
            StoredProvider(app: .claude, name: "Claude A", slug: "a", baseURL: "https://a.test", model: "m1", apiKey: "k1"),
            StoredProvider(app: .codex, name: "Codex B", slug: "b", baseURL: "https://b.test", model: "m2", apiKey: "k2"),
        ])
        let model = LiveConfigViewModel(
            paths: LiveConfigPaths(
                claudeSettings: directory.appending(path: "settings.json"),
                codexConfig: directory.appending(path: "config.toml")
            ),
            library: library
        )
        model.reload()
        model.app = .claude
        XCTAssertEqual(model.visibleProviders.map(\.name), ["Claude A"])
        model.app = .codex
        XCTAssertEqual(model.visibleProviders.map(\.name), ["Codex B"])
    }

    private func uniqueURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }
}
