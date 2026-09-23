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
        // Written without the trailing slash: Claude Code appends "/v1/messages"
        // itself, so "https://relay.test//v1/messages" would 404.
        XCTAssertEqual(loaded.settings.baseURL, "https://relay.test")
        XCTAssertEqual(loaded.settings.model, "sonnet")
        XCTAssertEqual(loaded.secret, "sk-test-secret-key")
        XCTAssertEqual(loaded.settings.maskedAPIKey, "••••-key")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let env = object?["env"] as? [String: String]
        XCTAssertEqual(env?["CLAUDE_CODE_EFFORT_LEVEL"], "high")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".ai-toolbox.bak"))
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

    func testClaudeBaseURLNormalizationStripsOpenAIStyleVersionSegment() {
        // Claude Code appends "/v1/messages" itself, so a base URL shared with
        // Codex must lose its own OpenAI-style version segment first.
        XCTAssertEqual(
            ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/v1"),
            "https://relay.test"
        )
        XCTAssertEqual(
            ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/v1/"),
            "https://relay.test"
        )
        XCTAssertEqual(
            ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/api/v1"),
            "https://relay.test/api"
        )
        XCTAssertEqual(
            ClaudeLiveSettingsStore.normalizedBaseURL("  https://relay.test/v1  "),
            "https://relay.test"
        )
        // Already in Claude Code form: only the trailing slash goes away.
        XCTAssertEqual(
            ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/"),
            "https://relay.test"
        )
        XCTAssertEqual(
            ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test"),
            "https://relay.test"
        )
        // A path that merely starts with "v1" is not a version segment.
        XCTAssertEqual(
            ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/v1beta"),
            "https://relay.test/v1beta"
        )
    }

    func testClaudeSaveRewritesOpenAIStyleBaseURLToHostRoot() throws {
        let url = try uniqueURL("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ClaudeLiveSettingsStore.save(
            to: url,
            baseURL: "https://router.example/v1",
            model: "deepseek-v4.1-flash",
            apiKey: "sk-test",
            keepExistingKeyIfEmpty: false
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let env = object?["env"] as? [String: String]
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"], "https://router.example")
        XCTAssertEqual(env?["ANTHROPIC_MODEL"], "deepseek-v4.1-flash")
    }

    @MainActor
    func testActiveClaudeProviderMatchesDespiteVersionSegmentNormalization() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = LiveConfigPaths(
            claudeSettings: directory.appending(path: "settings.json"),
            codexConfig: directory.appending(path: "config.toml")
        )
        let library = ProviderLibraryStore(url: directory.appending(path: "providers.json"))
        // The stored provider keeps the OpenAI-style URL while the live file holds
        // the normalized one; the card must still read as the active provider.
        let provider = StoredProvider(
            app: .claude, name: "ARouter", slug: "arouter",
            baseURL: "https://router.example/v1", model: "deepseek-v4.1-flash", apiKey: "sk-a"
        )
        try library.save([provider])
        let model = LiveConfigViewModel(paths: paths, library: library)
        model.reload()
        model.activate(provider)
        for _ in 0..<100 where model.isBusy { await Task.yield() }

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activeProviderID, provider.id)
        XCTAssertFalse(model.liveConfigIsUnmanaged)
        let loaded = try ClaudeLiveSettingsStore.load(from: paths.claudeSettings)
        XCTAssertEqual(loaded.settings.baseURL, "https://router.example")
    }

    func testCodexFallbackToBuiltInOpenAIDropsRelayModel() throws {
        // Activating a relay writes its model into the root `model` key.
        let relay = try CodexTomlEditor.upsertProvider(
            "model = \"gpt-5\"\npersonality = \"pragmatic\"\n",
            id: "relay",
            name: "Relay",
            baseURL: "https://relay.test/v1",
            apiKey: "sk-relay",
            makeCurrent: true,
            model: "deepseek-v4.1-flash"
        )
        XCTAssertEqual(CodexTomlEditor.load(relay).model, "deepseek-v4.1-flash")

        // Switching back to the ChatGPT login must not leave that model behind:
        // the account rejects it with a 400 on every request.
        let official = CodexTomlEditor.switchToBuiltInOpenAI(relay)
        let settings = CodexTomlEditor.load(official)
        XCTAssertEqual(settings.currentProviderID, "openai")
        XCTAssertEqual(settings.model, "")
        XCTAssertFalse(official.contains("model = \"deepseek-v4.1-flash\""))
        XCTAssertTrue(official.contains("personality = \"pragmatic\""))
        XCTAssertTrue(official.contains("[model_providers.relay]"))
    }

    func testCodexDeletingTheCurrentProviderAlsoDropsItsModel() throws {
        let relay = try CodexTomlEditor.upsertProvider(
            "model = \"gpt-5\"\n",
            id: "relay",
            name: "Relay",
            baseURL: "https://relay.test/v1",
            apiKey: "sk-relay",
            makeCurrent: true,
            model: "deepseek-v4.1-flash"
        )
        let removed = try CodexTomlEditor.removeProvider(relay, id: "relay")
        let settings = CodexTomlEditor.load(removed)
        XCTAssertEqual(settings.currentProviderID, "openai")
        XCTAssertEqual(settings.model, "")
        XCTAssertFalse(removed.contains("model_providers.relay"))
    }

    func testCodexRemoveRootStringLeavesTableKeysAlone() {
        let text = """
        model = "deepseek-v4.1-flash"
        model_provider = "relay"

        [model_providers.relay]
        name = "Relay"
        base_url = "https://relay.test/v1"
        """
        let stripped = CodexTomlEditor.removeRootString(text, key: "model")
        XCTAssertNil(CodexTomlEditor.rootString(stripped, key: "model"))
        XCTAssertEqual(CodexTomlEditor.rootString(stripped, key: "model_provider"), "relay")
        XCTAssertEqual(CodexTomlEditor.providerFields(in: stripped, id: "relay")["base_url"], "https://relay.test/v1")
    }

    /// The relay's model has to be published, or Codex's picker never offers it and
    /// logs that it found no metadata for the model. Only the provider that becomes
    /// current publishes, so the catalog always describes `model_provider`.
    func testCodexPublishesTheCurrentProvidersModelCatalog() throws {
        let catalogPath = "/Users/someone/ai-toolbox-models.json"
        let relay = try CodexTomlEditor.upsertProvider(
            "model = \"gpt-5\"\n",
            id: "relay",
            name: "Relay",
            baseURL: "https://relay.test/v1",
            apiKey: "sk-relay",
            makeCurrent: true,
            model: "deepseek-v4.1-flash",
            modelCatalog: catalogPath
        )
        XCTAssertEqual(
            CodexTomlEditor.rootString(relay, key: CodexTomlEditor.modelCatalogKey),
            catalogPath
        )
        XCTAssertEqual(CodexTomlEditor.load(relay).model, "deepseek-v4.1-flash")

        // Saving without switching must not publish: the active provider is unchanged.
        let savedOnly = try CodexTomlEditor.upsertProvider(
            relay,
            id: "other",
            name: "Other",
            baseURL: "https://other.test/v1",
            apiKey: "sk-other",
            makeCurrent: false,
            model: "k3",
            modelCatalog: "/Users/someone/other-catalog.json"
        )
        XCTAssertEqual(
            CodexTomlEditor.rootString(savedOnly, key: CodexTomlEditor.modelCatalogKey),
            catalogPath
        )

        // The official login reads Codex's own catalog, so ours has to go with the
        // relay — it hides the official models the account can actually use.
        let official = CodexTomlEditor.switchToBuiltInOpenAI(relay)
        XCTAssertNil(CodexTomlEditor.rootString(official, key: CodexTomlEditor.modelCatalogKey))
        XCTAssertTrue(official.contains("[model_providers.relay]"))
    }

    /// A catalog somebody configured by hand is never the app's to throw away: once
    /// removed, nothing here knows how to put it back.
    func testCodexLeavesAHandWrittenCatalogAlone() throws {
        let text = """
        model = "gpt-5"
        model_provider = "openai"
        model_catalog_json = "/Users/someone/their-own-catalog.json"
        """
        XCTAssertEqual(CodexTomlEditor.setModelCatalog(text, path: nil), text)
        XCTAssertEqual(
            CodexTomlEditor.rootString(CodexTomlEditor.switchToBuiltInOpenAI(text), key: CodexTomlEditor.modelCatalogKey),
            "/Users/someone/their-own-catalog.json"
        )
    }

    /// End to end through the panel: activating a relay publishes the catalog file and
    /// points `config.toml` at it; going back to the official login removes both.
    @MainActor
    func testViewModelPublishesTheCodexCatalogWithInjectedPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = LiveConfigPaths(
            claudeSettings: directory.appending(path: "settings.json"),
            codexConfig: directory.appending(path: "config.toml")
        )
        try officialCatalogFixture().data(using: .utf8)!.write(to: paths.codexOfficialCatalog)
        try "model = \"gpt-5\"\nmodel_provider = \"openai\"\n".data(using: .utf8)!.write(to: paths.codexConfig)
        let library = ProviderLibraryStore(url: directory.appending(path: "providers.json"))
        let provider = StoredProvider(
            app: .codex,
            name: "ARouter",
            slug: "arouter",
            baseURL: "https://router.test/v1",
            model: "deepseek-v4.1-flash",
            apiKey: "sk-router"
        )
        try library.save([provider])

        let model = LiveConfigViewModel(paths: paths, library: library)
        model.reload()
        model.app = .codex
        model.activate(provider)
        for _ in 0..<400 where model.isBusy {
            await Task.yield()
        }

        XCTAssertNil(model.errorMessage)
        let config = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        XCTAssertEqual(
            CodexTomlEditor.rootString(config, key: CodexTomlEditor.modelCatalogKey),
            paths.codexModelCatalog.path
        )
        let published = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.codexModelCatalog)) as? [String: Any]
        let models = published?["models"] as? [[String: Any]]
        XCTAssertEqual(models?.first?["slug"] as? String, "deepseek-v4.1-flash")
        XCTAssertEqual(models?.first?["visibility"] as? String, "list")

        model.useCodexOfficial()
        for _ in 0..<400 where model.isBusy {
            await Task.yield()
        }
        let official = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        XCTAssertNil(CodexTomlEditor.rootString(official, key: CodexTomlEditor.modelCatalogKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexModelCatalog.path))
    }

    /// A relay model cannot be published without instructions, and Codex refuses to
    /// load a config that points at such an entry. Without an official catalog to
    /// borrow from, the switch still happens and says why the model is missing from
    /// the picker.
    @MainActor
    func testViewModelReportsAnUnpublishableModelInsteadOfBreakingTheConfig() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = LiveConfigPaths(
            claudeSettings: directory.appending(path: "settings.json"),
            codexConfig: directory.appending(path: "config.toml")
        )
        try "model = \"gpt-5\"\nmodel_provider = \"openai\"\n".data(using: .utf8)!.write(to: paths.codexConfig)
        let library = ProviderLibraryStore(url: directory.appending(path: "providers.json"))
        let provider = StoredProvider(
            app: .codex,
            name: "ARouter",
            slug: "arouter",
            baseURL: "https://router.test/v1",
            model: "deepseek-v4.1-flash",
            apiKey: "sk-router"
        )
        try library.save([provider])

        let model = LiveConfigViewModel(paths: paths, library: library)
        model.reload()
        model.app = .codex
        model.activate(provider)
        for _ in 0..<400 where model.isBusy {
            await Task.yield()
        }

        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.statusMessage)
        let config = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        XCTAssertNil(CodexTomlEditor.rootString(config, key: CodexTomlEditor.modelCatalogKey))
        XCTAssertEqual(CodexTomlEditor.load(config).model, "deepseek-v4.1-flash")
        XCTAssertEqual(CodexTomlEditor.load(config).currentProviderID, "arouter")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexModelCatalog.path))
    }

    /// The catalog Codex downloads for itself: the relay entry borrows its prompt.
    private func officialCatalogFixture() -> String {
        """
        { "models": [
            {
                "slug": "gpt-6-astra",
                "display_name": "GPT-6-Astra",
                "visibility": "list",
                "priority": 1,
                "context_window": 272000,
                "max_context_window": 872000,
                "shell_type": "unified_exec",
                "truncation_policy": { "mode": "tokens", "limit": 10000 },
                "model_messages": { "instructions_template": "You are Codex." }
            }
        ]}
        """
    }

    private func uniqueURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }
}
