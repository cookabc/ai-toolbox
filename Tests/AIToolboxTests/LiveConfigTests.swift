import Foundation
import XCTest
@testable import AIToolbox

final class LiveConfigTests: XCTestCase {
    func testMaskShowsOnlyTheEndOfLongKeys() {
        XCTAssertEqual(SecretDisplay.mask("sk-abcdefghijk"), "••••hijk")
        XCTAssertEqual(SecretDisplay.mask("short"), "••••", "a short key would be half revealed")
        XCTAssertEqual(SecretDisplay.mask(""), "未设置")
    }

    func testClaudeClearRemovesTheOverlayAndProviderKeysOnly() throws {
        let url = try uniqueURL("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try """
        { "env": {
            "ANTHROPIC_API_KEY": "sk-keep-out",
            "ANTHROPIC_BASE_URL": "https://example.test",
            "ANTHROPIC_MODEL": "opus",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "opus",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1000000",
            "CLAUDE_CODE_EFFORT_LEVEL": "high"
        }}
        """.data(using: .utf8)!.write(to: url)
        try ClaudeLiveSettingsStore.clearAPIOverlay(at: url, providerKeys: ["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
        let loaded = try ClaudeLiveSettingsStore.load(from: url)
        XCTAssertFalse(loaded.settings.hasAPIKey)
        XCTAssertEqual(loaded.settings.baseURL, "")
        let env = try env(of: url)
        XCTAssertEqual(env["CLAUDE_CODE_EFFORT_LEVEL"], "high", "no provider owns it, so it is the user's")
        XCTAssertNil(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "a provider owned it")
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".ai-toolbox.bak"))
    }

    func testClaudeBaseURLNormalizationStripsOpenAIStyleVersionSegment() {
        // Claude Code appends "/v1/messages" itself, so a base URL shared with
        // Codex must lose its own OpenAI-style version segment first.
        XCTAssertEqual(ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/v1"), "https://relay.test")
        XCTAssertEqual(ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/v1/"), "https://relay.test")
        XCTAssertEqual(ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/api/v1"), "https://relay.test/api")
        XCTAssertEqual(ClaudeLiveSettingsStore.normalizedBaseURL("  https://relay.test/v1  "), "https://relay.test")
        XCTAssertEqual(ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/"), "https://relay.test")
        XCTAssertEqual(ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test"), "https://relay.test")
        // A path that merely starts with "v1" is not a version segment.
        XCTAssertEqual(ClaudeLiveSettingsStore.normalizedBaseURL("https://relay.test/v1beta"), "https://relay.test/v1beta")
    }

    // MARK: - Codex config edits

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
            original, id: "relay", name: "Relay", baseURL: "https://relay.test/v1",
            apiKey: "sk-relay-aaaa", makeCurrent: true, model: "k3"
        )
        XCTAssertEqual(added, """
        model = "k3"
        model_provider = "relay"
        personality = "pragmatic"

        [plugins.chrome]
        enabled = true

        [tui]
        theme = "solarized-light"

        [model_providers.relay]
        name = "Relay"
        base_url = "https://relay.test/v1"
        wire_api = "responses"
        experimental_bearer_token = "sk-relay-aaaa"

        """)
        let settings = try CodexTomlEditor.load(added)
        XCTAssertEqual(settings.currentProviderID, "relay")
        XCTAssertEqual(settings.model, "k3")
        XCTAssertEqual(settings.providers.map(\.id), ["openai", "relay"])
        XCTAssertEqual(CodexTomlEditor.secret(in: added, id: "relay"), "sk-relay-aaaa")

        let removed = try CodexTomlEditor.removeProvider(added, id: "relay")
        XCTAssertFalse(removed.contains("model_providers.relay"))
        XCTAssertTrue(removed.contains("[plugins.chrome]"))
        XCTAssertEqual(try CodexTomlEditor.load(removed).currentProviderID, "openai")
    }

    func testCodexRejectsReservedAndInvalidIDs() {
        XCTAssertThrowsError(try CodexTomlEditor.upsertProvider(
            "", id: "openai", name: "x", baseURL: "https://example.test", apiKey: "k", makeCurrent: true, model: nil
        )) { XCTAssertEqual($0 as? LiveConfigError, .reservedProviderID) }
        XCTAssertThrowsError(try CodexTomlEditor.upsertProvider(
            "", id: "1bad", name: "x", baseURL: "https://example.test", apiKey: "k", makeCurrent: true, model: nil
        )) { XCTAssertEqual($0 as? LiveConfigError, .invalidProviderID) }
        XCTAssertThrowsError(try CodexTomlEditor.upsertProvider(
            "", id: "智谱", name: "x", baseURL: "https://example.test", apiKey: "k", makeCurrent: true, model: nil
        )) { XCTAssertEqual($0 as? LiveConfigError, .invalidProviderID) }
    }

    func testCodexEditKeepsExistingTokenAndHandWrittenWireAPI() throws {
        let first = """
        [model_providers.relay]
        # rotated monthly
        name = "Relay"
        base_url = "https://a.test"
        wire_api = "chat"
        experimental_bearer_token = "sk-old-token"
        query_params = { "api-version" = "2025-01-01" }
        """
        let edited = try CodexTomlEditor.upsertProvider(
            first, id: "relay", name: "Relay 2", baseURL: "https://b.test", apiKey: nil, makeCurrent: false, model: nil
        )
        XCTAssertEqual(CodexTomlEditor.secret(in: edited, id: "relay"), "sk-old-token")
        let fields = CodexTomlEditor.providerFields(in: edited, id: "relay")
        XCTAssertEqual(fields["name"], "Relay 2")
        XCTAssertEqual(fields["base_url"], "https://b.test")
        XCTAssertEqual(fields["wire_api"], "chat", "a wire_api set by hand is not ours to change")
        XCTAssertTrue(edited.contains("# rotated monthly"), "comments inside the table survive")
        XCTAssertTrue(edited.contains(#"query_params = { "api-version" = "2025-01-01" }"#))
        XCTAssertNil(CodexTomlEditor.rootString(edited, key: "model"), "saving without switching changes no root key")
    }

    func testCodexFallbackToBuiltInOpenAIDropsRelayModelAndOurCatalog() throws {
        let relay = try CodexTomlEditor.upsertProvider(
            "model = \"gpt-5\"\npersonality = \"pragmatic\"\n", id: "relay", name: "Relay",
            baseURL: "https://relay.test/v1", apiKey: "sk-relay", makeCurrent: true, model: "deepseek-v4.1-flash",
            modelCatalog: "/Users/someone/.codex/ai-toolbox-models.json"
        )
        XCTAssertEqual(try CodexTomlEditor.load(relay).model, "deepseek-v4.1-flash")
        XCTAssertTrue(CodexTomlEditor.pointsAtPublishedCatalog(relay))

        // Switching back to the ChatGPT login must not leave that model behind: the
        // account rejects it with a 400 on every request.
        let official = try CodexTomlEditor.switchToBuiltInOpenAI(relay)
        let settings = try CodexTomlEditor.load(official)
        XCTAssertEqual(settings.currentProviderID, "openai")
        XCTAssertEqual(settings.model, "")
        XCTAssertNil(CodexTomlEditor.rootString(official, key: CodexTomlEditor.modelCatalogKey))
        XCTAssertTrue(official.contains("personality = \"pragmatic\""))
        XCTAssertTrue(official.contains("[model_providers.relay]"))
    }

    func testCodexDeletingTheCurrentProviderAlsoDropsItsModel() throws {
        let relay = try CodexTomlEditor.upsertProvider(
            "model = \"gpt-5\"\n", id: "relay", name: "Relay", baseURL: "https://relay.test/v1",
            apiKey: "sk-relay", makeCurrent: true, model: "deepseek-v4.1-flash"
        )
        let removed = try CodexTomlEditor.removeProvider(relay, id: "relay")
        let settings = try CodexTomlEditor.load(removed)
        XCTAssertEqual(settings.currentProviderID, "openai")
        XCTAssertEqual(settings.model, "")
        XCTAssertFalse(removed.contains("model_providers.relay"))
    }

    /// A catalog somebody configured by hand is never the app's to throw away: once
    /// removed, nothing here knows how to put it back.
    func testCodexLeavesAHandWrittenCatalogAlone() throws {
        let text = """
        model = "gpt-5"
        model_provider = "relay"
        model_catalog_json = "/Users/someone/their-own-catalog.json"
        """
        XCTAssertFalse(CodexTomlEditor.pointsAtPublishedCatalog(text))
        XCTAssertEqual(
            CodexTomlEditor.rootString(try CodexTomlEditor.switchToBuiltInOpenAI(text), key: CodexTomlEditor.modelCatalogKey),
            "/Users/someone/their-own-catalog.json"
        )
    }

    // MARK: - Slugs

    func testSlugsAreAlwaysValidCodexIDs() {
        for name in ["智谱清言", "Kimi K2", "  ", "123 Relay", "Ünïcødé", "a/b\\c", String(repeating: "长", count: 50), "openai"] {
            let slug = ProviderSlug.suggest(from: name, existing: [])
            XCTAssertTrue(ProviderIDRules.isValid(slug), "\(name) → \(slug)")
            XCTAssertFalse(ProviderIDRules.reservedCodexIDs.contains(slug), "\(name) → \(slug)")
        }
        XCTAssertEqual(ProviderSlug.suggest(from: "智谱", existing: []), "zhi-pu")
        XCTAssertEqual(ProviderSlug.suggest(from: "Relay", existing: ["relay"]), "relay-2")
        XCTAssertEqual(ProviderSlug.suggest(from: "OpenAI", existing: []), "openai-2")
    }

    // MARK: - View model, end to end through the files

    @MainActor
    func testActivatingAClaudeProviderWritesSettings() async throws {
        let fixture = try Fixture()
        let provider = StoredProvider(
            app: .claude, name: "Test", slug: "test", baseURL: "https://example.test/v1", model: "haiku", apiKey: "sk-view-model-key"
        )
        try fixture.library.save([provider])

        let model = fixture.model()
        model.activate(provider)
        await model.waitUntilIdle()

        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
        let loaded = try ClaudeLiveSettingsStore.load(from: fixture.paths.claudeSettings)
        XCTAssertEqual(loaded.settings.baseURL, "https://example.test")
        XCTAssertEqual(loaded.secret, "sk-view-model-key")
        XCTAssertEqual(model.activeProviderID(for: .claude), provider.id)
        XCTAssertFalse(model.liveConfigIsUnmanaged)
    }

    /// Two providers on one relay with different keys are different providers.
    @MainActor
    func testActiveClaudeProviderIsMatchedByKeyToo() async throws {
        let fixture = try Fixture()
        let first = StoredProvider(app: .claude, name: "A", slug: "a", baseURL: "https://relay.test", model: "m", apiKey: "sk-first-key")
        let second = StoredProvider(app: .claude, name: "B", slug: "b", baseURL: "https://relay.test", model: "m", apiKey: "sk-second-key")
        try fixture.library.save([first, second])
        let model = fixture.model()
        model.activate(second)
        await model.waitUntilIdle()
        XCTAssertEqual(model.activeProviderID(for: .claude), second.id)
    }

    @MainActor
    func testStatusIsScopedToItsToolAndSaveWithoutSwitchKeepsCurrentProvider() async throws {
        let fixture = try Fixture(codexConfig: "model = \"gpt-5\"\nmodel_provider = \"openai\"\n", claudeSettings: #"{ "env": {} }"#)
        let model = fixture.model()
        model.app = .codex
        model.beginCreate()
        model.draftName = "ANexto"
        model.draftSlug = "anexto"
        model.draftBaseURL = "https://relay.test/v1"
        model.draftModel = "deepseek-v4.1-flash"
        model.draftAPIKey = "sk-test"
        model.saveDraft(activate: false)
        await model.waitUntilIdle()

        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.statusMessage)
        XCTAssertEqual(model.draftMode, .none)
        XCTAssertEqual(model.codexLive.currentProviderID, "openai")
        XCTAssertEqual(model.codexLive.model, "gpt-5")
        XCTAssertFalse(try fixture.codexText().contains("anexto"), "saving is not switching")

        model.app = .claude
        XCTAssertNil(model.statusMessage, "Codex 的结果不应显示在 Claude Code 标签下")
        model.app = .codex
        XCTAssertNotNil(model.statusMessage)
    }

    @MainActor
    func testClaudeAndCodexProvidersAreFilteredSeparately() throws {
        let fixture = try Fixture()
        try fixture.library.save([
            StoredProvider(app: .claude, name: "Claude A", slug: "a", baseURL: "https://a.test", model: "m1", apiKey: "k1"),
            StoredProvider(app: .codex, name: "Codex B", slug: "b", baseURL: "https://b.test", model: "m2", apiKey: "k2"),
        ])
        let model = fixture.model()
        model.app = .claude
        XCTAssertEqual(model.visibleProviders.map(\.name), ["Claude A"])
        model.app = .codex
        XCTAssertEqual(model.visibleProviders.map(\.name), ["Codex B"])
    }

    /// Codex rewrites its own config — trusting a project, installing a plugin. A
    /// switch made from an older copy of the file used to write that copy back and
    /// silently undo those changes.
    @MainActor
    func testActivationKeepsChangesMadeToConfigSinceItWasRead() async throws {
        let fixture = try Fixture(codexConfig: "model = \"gpt-5\"\nmodel_provider = \"openai\"\n")
        let relay = StoredProvider(app: .codex, name: "Relay", slug: "relay", baseURL: "https://relay.test/v1", model: "m", apiKey: "sk-r")
        try fixture.library.save([relay])
        let model = fixture.model()

        try fixture.writeCodex(fixture.codexText() + "\n[projects.\"/Users/someone/new-project\"]\ntrust_level = \"trusted\"\n")
        model.activate(relay)
        await model.waitUntilIdle()

        let text = try fixture.codexText()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(text.contains("[projects.\"/Users/someone/new-project\"]\ntrust_level = \"trusted\""))
        XCTAssertEqual(CodexTomlEditor.rootString(text, key: "model_provider"), "relay")
    }

    /// Deleting right after switching used to write back the config as it was before
    /// the switch, reverting it.
    @MainActor
    func testDeletingAnotherProviderRightAfterASwitchKeepsTheSwitch() async throws {
        let fixture = try Fixture(codexConfig: "model_provider = \"openai\"\n")
        let a = StoredProvider(app: .codex, name: "A", slug: "a", baseURL: "https://a.test/v1", model: "ma", apiKey: "sk-a")
        let b = StoredProvider(app: .codex, name: "B", slug: "b", baseURL: "https://b.test/v1", model: "mb", apiKey: "sk-b")
        try fixture.library.save([a, b])
        let model = fixture.model()
        model.activate(b)
        model.activate(a)
        model.delete(b)
        await model.waitUntilIdle()

        let text = try fixture.codexText()
        XCTAssertEqual(CodexTomlEditor.rootString(text, key: "model_provider"), "a")
        XCTAssertEqual(CodexTomlEditor.rootString(text, key: "model"), "ma")
        XCTAssertFalse(text.contains("[model_providers.b]"))
        XCTAssertEqual(model.providers.map(\.slug), ["a"])
    }

    /// Editing the provider that is live and pressing "保存" must not leave the live
    /// config running on the values that were just replaced.
    @MainActor
    func testEditingTheActiveProviderUpdatesTheLiveConfig() async throws {
        let fixture = try Fixture(codexConfig: "model_provider = \"openai\"\n", claudeSettings: "{}")
        let codex = StoredProvider(app: .codex, name: "Relay", slug: "relay", baseURL: "https://old.test/v1", model: "m", apiKey: "sk-old")
        let claude = StoredProvider(app: .claude, name: "Gateway", slug: "gateway", baseURL: "https://gw.test", model: "old", apiKey: "sk-gw")
        try fixture.library.save([codex, claude])
        let model = fixture.model()
        model.activate(codex)
        model.activate(claude)
        await model.waitUntilIdle()

        model.app = .codex
        model.beginEdit(codex)
        model.draftBaseURL = "https://new.test/v1"
        model.draftAPIKey = "sk-new"
        model.saveDraft(activate: false)
        await model.waitUntilIdle()
        let fields = CodexTomlEditor.providerFields(in: try fixture.codexText(), id: "relay")
        XCTAssertEqual(fields["base_url"], "https://new.test/v1")
        XCTAssertEqual(fields["experimental_bearer_token"], "sk-new")
        XCTAssertEqual(model.activeProviderID(for: .codex), codex.id)

        model.app = .claude
        model.beginEdit(claude)
        model.draftModel = "new"
        model.saveDraft(activate: false)
        await model.waitUntilIdle()
        XCTAssertEqual(try ClaudeLiveSettingsStore.load(from: fixture.paths.claudeSettings).settings.model, "new")
        XCTAssertEqual(model.activeProviderID(for: .claude), claude.id, "still the active provider")
        XCTAssertFalse(model.liveConfigIsUnmanaged)
    }

    @MainActor
    func testEditingAnInactiveProviderSyncsItsExistingTableOnly() async throws {
        let fixture = try Fixture(codexConfig: "model_provider = \"openai\"\n\n[model_providers.relay]\nname = \"Relay\"\nbase_url = \"https://old.test/v1\"\n")
        let relay = StoredProvider(app: .codex, name: "Relay", slug: "relay", baseURL: "https://old.test/v1", model: "m", apiKey: "")
        let other = StoredProvider(app: .codex, name: "Other", slug: "other", baseURL: "https://other.test/v1", model: "m", apiKey: "")
        try fixture.library.save([relay, other])
        let model = fixture.model()
        model.app = .codex
        model.beginEdit(relay)
        model.draftBaseURL = "https://new.test/v1"
        model.saveDraft(activate: false)
        await model.waitUntilIdle()
        model.beginEdit(other)
        model.draftName = "Other 2"
        model.saveDraft(activate: false)
        await model.waitUntilIdle()

        let text = try fixture.codexText()
        XCTAssertEqual(CodexTomlEditor.providerFields(in: text, id: "relay")["base_url"], "https://new.test/v1")
        XCTAssertFalse(text.contains("[model_providers.other]"), "a provider Codex does not know is not added by saving")
        XCTAssertEqual(CodexTomlEditor.rootString(text, key: "model_provider"), "openai")
    }

    /// The relay's model has to be published, or Codex's picker never offers it.
    /// Going back to the official login removes both the key and the file.
    @MainActor
    func testActivatingPublishesTheCodexCatalogAndOfficialRemovesIt() async throws {
        let fixture = try Fixture(codexConfig: "model = \"gpt-5\"\nmodel_provider = \"openai\"\n", officialCatalog: true)
        let provider = StoredProvider(
            app: .codex, name: "ARouter", slug: "arouter", baseURL: "https://router.test/v1", model: "deepseek-v4.1-flash", apiKey: "sk-router"
        )
        try fixture.library.save([provider])
        let model = fixture.model()
        model.app = .codex
        model.activate(provider)
        await model.waitUntilIdle()

        XCTAssertNil(model.errorMessage)
        let config = try fixture.codexText()
        XCTAssertEqual(CodexTomlEditor.rootString(config, key: CodexTomlEditor.modelCatalogKey), fixture.paths.codexModelCatalog.path)
        let published = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.codexModelCatalog)) as? [String: Any]
        let models = published?["models"] as? [[String: Any]]
        XCTAssertEqual(models?.first?["slug"] as? String, "deepseek-v4.1-flash")
        XCTAssertEqual(models?.first?["visibility"] as? String, "list")

        model.useCodexOfficial()
        await model.waitUntilIdle()
        let official = try fixture.codexText()
        XCTAssertNil(CodexTomlEditor.rootString(official, key: CodexTomlEditor.modelCatalogKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.codexModelCatalog.path))
        XCTAssertTrue(model.codexUsesOfficialLogin)
    }

    /// Switching away from the official login used to overwrite its model with the
    /// relay's, and switching back only deleted it: the model the user had chosen
    /// was gone. It is remembered and restored now.
    @MainActor
    func testTheOfficialModelComesBackAfterARelay() async throws {
        let fixture = try Fixture(codexConfig: "model_provider = \"openai\"\nmodel = \"gpt-6-sol\"\n")
        let relay = StoredProvider(app: .codex, name: "R", slug: "r", baseURL: "https://r.test/v1", model: "relay-model", apiKey: "sk")
        let other = StoredProvider(app: .codex, name: "O", slug: "o", baseURL: "https://o.test/v1", model: "other-model", apiKey: "sk")
        try fixture.library.save([relay, other])
        let model = fixture.model()
        model.activate(relay)
        model.activate(other)
        await model.waitUntilIdle()
        XCTAssertEqual(CodexTomlEditor.rootString(try fixture.codexText(), key: "model"), "other-model")

        model.useCodexOfficial()
        await model.waitUntilIdle()
        XCTAssertEqual(CodexTomlEditor.rootString(try fixture.codexText(), key: "model"), "gpt-6-sol",
                       "relay to relay must not replace the remembered official model")

        model.activate(relay)
        model.delete(relay)
        await model.waitUntilIdle()
        let text = try fixture.codexText()
        XCTAssertEqual(CodexTomlEditor.rootString(text, key: "model_provider"), "openai")
        XCTAssertEqual(CodexTomlEditor.rootString(text, key: "model"), "gpt-6-sol")
    }

    /// Without an official catalog to borrow instructions from, the switch still
    /// happens and says why the model is missing from the picker.
    @MainActor
    func testAnUnpublishableModelIsReportedInsteadOfBreakingTheConfig() async throws {
        let fixture = try Fixture(codexConfig: "model = \"gpt-5\"\nmodel_provider = \"openai\"\n")
        let provider = StoredProvider(
            app: .codex, name: "ARouter", slug: "arouter", baseURL: "https://router.test/v1", model: "deepseek-v4.1-flash", apiKey: "sk-router"
        )
        try fixture.library.save([provider])
        let model = fixture.model()
        model.app = .codex
        model.activate(provider)
        await model.waitUntilIdle()

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.statusMessage?.contains("官方模型目录") == true)
        let config = try fixture.codexText()
        XCTAssertNil(CodexTomlEditor.rootString(config, key: CodexTomlEditor.modelCatalogKey))
        XCTAssertEqual(try CodexTomlEditor.load(config).model, "deepseek-v4.1-flash")
        XCTAssertEqual(try CodexTomlEditor.load(config).currentProviderID, "arouter")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.codexModelCatalog.path))
    }

    /// The docs promised a hand-written `model_catalog_json` would not be
    /// overwritten; switching used to overwrite it anyway.
    @MainActor
    func testAHandWrittenCatalogSurvivesASwitch() async throws {
        let fixture = try Fixture(
            codexConfig: "model_provider = \"openai\"\nmodel_catalog_json = \"/Users/someone/mine.json\"\n",
            officialCatalog: true
        )
        let provider = StoredProvider(app: .codex, name: "R", slug: "r", baseURL: "https://r.test/v1", model: "m", apiKey: "sk")
        try fixture.library.save([provider])
        let model = fixture.model()
        model.app = .codex
        model.activate(provider)
        await model.waitUntilIdle()

        XCTAssertEqual(CodexTomlEditor.rootString(try fixture.codexText(), key: CodexTomlEditor.modelCatalogKey), "/Users/someone/mine.json")
        XCTAssertTrue(model.statusMessage?.contains("model_catalog_json") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.codexModelCatalog.path))
    }

    @MainActor
    func testAMissingConfigTomlIsCreatedOnSwitch() async throws {
        let fixture = try Fixture()
        let provider = StoredProvider(app: .codex, name: "R", slug: "r", baseURL: "https://r.test/v1", model: "m", apiKey: "sk")
        try fixture.library.save([provider])
        let model = fixture.model()
        XCTAssertEqual(model.codexState, .absent)
        XCTAssertTrue(model.codexUsesOfficialLogin, "Codex without a config uses its official login")
        model.activate(provider)
        await model.waitUntilIdle()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.codexState, .ready)
        XCTAssertEqual(CodexTomlEditor.rootString(try fixture.codexText(), key: "model_provider"), "r")
    }

    @MainActor
    func testAMissingCodexHomeIsReported() async throws {
        let fixture = try Fixture(codexHome: false)
        let provider = StoredProvider(app: .codex, name: "R", slug: "r", baseURL: "https://r.test/v1", model: "m", apiKey: "sk")
        let model = fixture.model()
        XCTAssertEqual(model.codexState, .noCodexHome)
        model.app = .codex
        model.activate(provider)
        await model.waitUntilIdle()
        XCTAssertEqual(model.errorMessage, LiveConfigError.missingCodexHome.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.codexHome.path))
    }

    @MainActor
    func testAnUnparseableConfigIsReportedAndNeverWritten() async throws {
        let broken = "model = \"gpt-5\"\nthis is not toml\n"
        let fixture = try Fixture(codexConfig: broken)
        let provider = StoredProvider(app: .codex, name: "R", slug: "r", baseURL: "https://r.test/v1", model: "m", apiKey: "sk")
        let model = fixture.model()
        model.app = .codex
        guard case .unreadable(let message) = model.codexState else { return XCTFail("expected unreadable") }
        XCTAssertTrue(message.contains("第 2 行"))
        model.activate(provider)
        await model.waitUntilIdle()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try fixture.codexText(), broken)
    }

    @MainActor
    func testANonLatinNameGetsAWorkingCodexID() async throws {
        let fixture = try Fixture(codexConfig: "[model_providers.zhi-pu-qing-yan]\nname = \"hand written\"\nbase_url = \"https://x.test\"\n")
        let model = fixture.model()
        model.app = .codex
        model.beginCreate()
        model.draftName = "智谱清言"
        model.draftBaseURL = "https://open.bigmodel.test/api/paas/v4"
        model.draftModel = "glm-5"
        model.draftAPIKey = "sk-zhipu"
        model.saveDraft(activate: true)
        await model.waitUntilIdle()

        XCTAssertNil(model.errorMessage)
        let saved = try XCTUnwrap(model.providers.first)
        XCTAssertEqual(saved.slug, "zhi-pu-qing-yan-2", "a table written by hand is never adopted by accident")
        let text = try fixture.codexText()
        XCTAssertEqual(CodexTomlEditor.rootString(text, key: "model_provider"), "zhi-pu-qing-yan-2")
        XCTAssertEqual(CodexTomlEditor.providerFields(in: text, id: "zhi-pu-qing-yan")["name"], "hand written")
    }

    @MainActor
    func testImportCapturesTheCredentialStyle() async throws {
        let fixture = try Fixture(claudeSettings: """
        { "env": { "ANTHROPIC_BASE_URL": "https://relay.test", "ANTHROPIC_AUTH_TOKEN": "sk-bearer", "ANTHROPIC_MODEL": "m" } }
        """)
        let model = fixture.model()
        model.app = .claude
        XCTAssertTrue(model.liveConfigIsUnmanaged)
        model.importLiveConfig()
        await model.waitUntilIdle()
        let imported = try XCTUnwrap(model.providers.first)
        XCTAssertEqual(imported.credential, .authToken)
        XCTAssertEqual(imported.apiKey, "sk-bearer")
        XCTAssertEqual(model.activeProviderID(for: .claude), imported.id)
        XCTAssertFalse(model.liveConfigIsUnmanaged)
    }

    @MainActor
    func testAnUnreadableLibraryIsNeverOverwritten() async throws {
        let fixture = try Fixture()
        try Data("{ not json".utf8).write(to: fixture.library.url)
        let model = fixture.model()
        XCTAssertNotNil(model.readProblem)
        model.beginCreate()
        model.draftName = "New"
        model.draftBaseURL = "https://new.test"
        model.saveDraft(activate: false)
        await model.waitUntilIdle()
        XCTAssertEqual(model.errorMessage, LiveConfigError.libraryUnreadable.localizedDescription)
        XCTAssertEqual(try String(contentsOf: fixture.library.url, encoding: .utf8), "{ not json")
    }

    @MainActor
    func testTheDocumentationModelNeverWrites() async throws {
        let model = LiveConfigViewModel.documentation(app: .codex)
        let provider = try XCTUnwrap(model.visibleProviders.first)
        model.useCodexOfficial()
        model.delete(provider)
        await model.waitUntilIdle()
        XCTAssertEqual(model.visibleProviders.count, 1)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testDraftValidation() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.app = .codex
        model.beginCreate()
        model.draftName = "Relay"
        model.draftBaseURL = "relay.test/v1"
        model.saveDraft(activate: false)
        XCTAssertTrue(model.errorMessage?.contains("http") == true)
        model.draftBaseURL = "https://relay.test/v1"
        model.draftSlug = "openai"
        model.saveDraft(activate: false)
        XCTAssertEqual(model.errorMessage, LiveConfigError.reservedProviderID.localizedDescription)
        model.draftSlug = ""
        model.saveDraft(activate: false)
        await model.waitUntilIdle()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.providers.map(\.slug), ["relay"])
    }

    // MARK: - Helpers

    private func uniqueURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }

    private func env(of url: URL) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return object?["env"] as? [String: String] ?? [:]
    }
}

/// A throwaway home with its own Claude and Codex config locations.
private struct Fixture {
    let root: URL
    let paths: LiveConfigPaths
    let library: ProviderLibraryStore

    init(codexConfig: String? = nil, claudeSettings: String? = nil, officialCatalog: Bool = false,
         codexHome: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-config-\(UUID().uuidString)")
        let codex = root.appending(path: ".codex")
        let claude = root.appending(path: ".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        if codexHome { try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true) }
        paths = LiveConfigPaths(claudeSettings: claude.appending(path: "settings.json"),
                                codexConfig: codex.appending(path: "config.toml"))
        library = ProviderLibraryStore(url: root.appending(path: "providers.json"))
        if let codexConfig { try Data(codexConfig.utf8).write(to: paths.codexConfig) }
        if let claudeSettings { try Data(claudeSettings.utf8).write(to: paths.claudeSettings) }
        if officialCatalog {
            try Data("""
            { "models": [ {
                "slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list", "priority": 1,
                "context_window": 272000, "max_context_window": 872000, "shell_type": "unified_exec",
                "truncation_policy": { "mode": "tokens", "limit": 10000 },
                "model_messages": { "instructions_template": "You are Codex." }
            } ] }
            """.utf8).write(to: paths.codexOfficialCatalog)
        }
    }

    @MainActor
    func model() -> LiveConfigViewModel {
        let model = LiveConfigViewModel(paths: paths, library: library)
        model.reload()
        return model
    }

    func codexText() throws -> String {
        try String(contentsOf: paths.codexConfig, encoding: .utf8)
    }

    func writeCodex(_ text: String) throws {
        try Data(text.utf8).write(to: paths.codexConfig)
    }
}
