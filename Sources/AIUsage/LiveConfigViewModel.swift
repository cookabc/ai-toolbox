import Foundation
import SwiftUI

@MainActor
final class LiveConfigViewModel: ObservableObject {
    enum DraftMode: Equatable {
        case none
        case create
        case edit(UUID)
    }

    struct Message: Equatable {
        var text: String
        var isError: Bool
    }

    @Published var app: LiveConfigApp = .claude
    @Published private(set) var providers: [StoredProvider] = []
    @Published private(set) var claudeLive = ClaudeLiveSettings(
        baseURL: "", model: "", hasAPIKey: false, maskedAPIKey: "未设置"
    )
    @Published private(set) var codexLive = CodexLiveSettings(
        model: "", currentProviderID: "openai", providers: [CodexTomlEditor.builtInOpenAI]
    )
    @Published private(set) var hasCodexFile = false

    @Published var draftMode: DraftMode = .none
    @Published var draftName = ""
    @Published var draftSlug = ""
    @Published var draftBaseURL = ""
    @Published var draftModel = ""
    @Published var draftAPIKey = ""
    @Published var revealDraftKey = false
    @Published var isBusy = false

    /// Kept per tool so a Codex result never shows up under Claude Code.
    @Published private(set) var messages: [LiveConfigApp: Message] = [:]

    private let paths: LiveConfigPaths
    private let library: ProviderLibraryStore
    private var codexText = ""
    private var claudeSecret = ""
    private var hasLoaded = false

    init(paths: LiveConfigPaths = .default, library: ProviderLibraryStore = ProviderLibraryStore()) {
        self.paths = paths
        self.library = library
    }

    // MARK: - Reading

    /// The menu-bar panel closes on any outside click; re-showing it must not
    /// re-read over what the user already typed.
    func loadOnce() {
        guard !hasLoaded else { return }
        reload()
    }

    /// Re-reads the library and both live configs. An open draft is left alone.
    func reload() {
        hasLoaded = true
        do {
            providers = try library.load()
            clearError(for: app)
        } catch {
            setError("无法读取供应商库：\(error.localizedDescription)", for: app)
        }
        do {
            let loaded = try ClaudeLiveSettingsStore.load(from: paths.claudeSettings)
            claudeLive = loaded.settings
            claudeSecret = loaded.secret
            clearError(for: .claude)
        } catch {
            claudeLive = ClaudeLiveSettings(baseURL: "", model: "", hasAPIKey: false, maskedAPIKey: "未设置")
            claudeSecret = ""
            setError(error.localizedDescription, for: .claude)
        }
        do {
            let loaded = try CodexLiveSettingsStore.load(from: paths.codexConfig)
            codexLive = loaded.settings
            codexText = loaded.text
            hasCodexFile = true
            clearError(for: .codex)
        } catch let error as LiveConfigError {
            hasCodexFile = false
            codexLive = CodexLiveSettings(model: "", currentProviderID: "openai", providers: [CodexTomlEditor.builtInOpenAI])
            codexText = ""
            if case .missingFile = error {
                clearError(for: .codex) // Stated inline in the panel; not a failed action.
            } else {
                setError(error.localizedDescription, for: .codex)
            }
        } catch {
            hasCodexFile = false
            setError(error.localizedDescription, for: .codex)
        }
    }

    // MARK: - Derived state

    var visibleProviders: [StoredProvider] {
        providers.filter { $0.app == app }
    }

    var activeProviderID: UUID? {
        switch app {
        case .claude:
            let url = claudeLive.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = claudeLive.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty || !model.isEmpty else { return nil }
            return visibleProviders.first {
                $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == url
                    && $0.model.trimmingCharacters(in: .whitespacesAndNewlines) == model
            }?.id
        case .codex:
            return visibleProviders.first { $0.slug == codexLive.currentProviderID }?.id
        }
    }

    /// True when the live file points somewhere the library does not describe yet.
    var liveConfigIsUnmanaged: Bool {
        switch app {
        case .claude:
            let hasOverlay = !claudeLive.baseURL.isEmpty || !claudeLive.model.isEmpty || claudeLive.hasAPIKey
            return hasOverlay && activeProviderID == nil
        case .codex:
            guard hasCodexFile else { return false }
            let known = Set(visibleProviders.map(\.slug))
            return codexLive.providers.contains { !$0.isBuiltIn && !known.contains($0.id) }
        }
    }

    var codexUsesOfficialLogin: Bool {
        app == .codex && codexLive.currentProviderID == "openai"
    }

    var errorMessage: String? {
        guard let message = messages[app], message.isError else { return nil }
        return message.text
    }

    var statusMessage: String? {
        guard let message = messages[app], !message.isError else { return nil }
        return message.text
    }

    var configDirectory: URL {
        switch app {
        case .claude: paths.claudeSettings.deletingLastPathComponent()
        case .codex: paths.codexConfig.deletingLastPathComponent()
        }
    }

    // MARK: - Draft

    func beginCreate() {
        draftMode = .create
        draftName = ""
        draftSlug = ""
        draftBaseURL = ""
        draftModel = ""
        draftAPIKey = ""
        revealDraftKey = false
        messages[app] = nil
    }

    func beginEdit(_ provider: StoredProvider) {
        draftMode = .edit(provider.id)
        draftName = provider.name
        draftSlug = provider.slug
        draftBaseURL = provider.baseURL
        draftModel = provider.model
        draftAPIKey = ""
        revealDraftKey = false
        messages[app] = nil
    }

    func cancelDraft() {
        draftMode = .none
        draftAPIKey = ""
    }

    /// Saves the draft into the library. `activate` also writes the live config.
    func saveDraft(activate: Bool) {
        let target = app
        run(target) {
            guard draftMode != .none else { return }
            let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw LiveConfigError.missingField("名称") }
            guard !baseURL.isEmpty else { throw LiveConfigError.missingField("Base URL") }

            var updated = providers
            let existingSlugs = Set(
                providers.filter { $0.app == target && $0.id != editingID }.map(\.slug)
            )
            var slug = draftSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            if slug.isEmpty {
                slug = ProviderSlug.suggest(from: name, existing: existingSlugs)
            } else if target == .codex {
                guard ProviderIDRules.isValid(slug) else { throw LiveConfigError.invalidProviderID }
                guard !ProviderIDRules.reservedCodexIDs.contains(slug) else {
                    throw LiveConfigError.reservedProviderID
                }
                guard !existingSlugs.contains(slug) else {
                    throw LiveConfigError.duplicateProviderID(slug)
                }
            }

            let key = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved: StoredProvider
            switch draftMode {
            case .edit(let id):
                guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
                updated[index].name = name
                updated[index].slug = slug
                updated[index].baseURL = baseURL
                updated[index].model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { updated[index].apiKey = key }
                saved = updated[index]
            case .create:
                saved = StoredProvider(
                    app: target,
                    name: name,
                    slug: slug,
                    baseURL: baseURL,
                    model: draftModel.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: key
                )
                updated.append(saved)
            case .none:
                return
            }

            try library.save(updated)
            providers = updated
            draftMode = .none
            draftAPIKey = ""

            if activate {
                try apply(saved)
                setStatus("已保存并切换到 \(saved.name)", for: target)
            } else {
                setStatus("已保存 \(saved.name)，未改变当前生效配置", for: target)
            }
            reload()
        }
    }

    func activate(_ provider: StoredProvider) {
        applyOptimistic(provider)
        runAsync(provider.app) {
            try await self.writeActivate(provider)
        }
    }

    func delete(_ provider: StoredProvider) {
        run(provider.app) {
            let updated = providers.filter { $0.id != provider.id }
            try library.save(updated)
            providers = updated
            if provider.app == .codex, hasCodexFile {
                let next = try CodexTomlEditor.removeProvider(codexText, id: provider.slug)
                try CodexLiveSettingsStore.write(next, to: paths.codexConfig)
            }
            if case .edit(let editing) = draftMode, editing == provider.id { draftMode = .none }
            setStatus("已删除 \(provider.name)", for: provider.app)
            reload()
        }
    }

    /// Turns whatever the live config currently points at into library entries.
    func importLiveConfig() {
        let target = app
        run(target) {
            var updated = providers
            var imported = 0
            switch target {
            case .claude:
                guard !claudeLive.baseURL.isEmpty || !claudeLive.model.isEmpty || claudeLive.hasAPIKey else { return }
                let existing = Set(updated.filter { $0.app == .claude }.map(\.slug))
                let name = hostLabel(claudeLive.baseURL) ?? "当前 Claude 配置"
                updated.append(StoredProvider(
                    app: .claude,
                    name: name,
                    slug: ProviderSlug.suggest(from: name, existing: existing),
                    baseURL: claudeLive.baseURL,
                    model: claudeLive.model,
                    apiKey: claudeSecret
                ))
                imported = 1
            case .codex:
                let known = Set(updated.filter { $0.app == .codex }.map(\.slug))
                for record in codexLive.providers where !record.isBuiltIn && !known.contains(record.id) {
                    updated.append(StoredProvider(
                        app: .codex,
                        name: record.name,
                        slug: record.id,
                        baseURL: record.baseURL,
                        model: record.id == codexLive.currentProviderID ? codexLive.model : "",
                        apiKey: CodexTomlEditor.secret(in: codexText, id: record.id)
                    ))
                    imported += 1
                }
            }
            guard imported > 0 else { return }
            try library.save(updated)
            providers = updated
            setStatus("已导入 \(imported) 个现有配置", for: target)
        }
    }

    func clearClaudeOverlay() {
        run(.claude) {
            try ClaudeLiveSettingsStore.clearAPIOverlay(at: paths.claudeSettings)
            setStatus("已清除 Claude Code 的 API 覆盖项", for: .claude)
            reload()
        }
    }

    // MARK: - Writing to the live configs

    private func applyOptimistic(_ provider: StoredProvider) {
        switch provider.app {
        case .claude:
            let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            claudeLive = ClaudeLiveSettings(
                baseURL: provider.baseURL,
                model: provider.model,
                hasAPIKey: key.isEmpty ? claudeLive.hasAPIKey : true,
                maskedAPIKey: key.isEmpty ? claudeLive.maskedAPIKey : SecretDisplay.mask(key)
            )
        case .codex:
            codexLive = CodexLiveSettings(
                model: provider.model.isEmpty ? codexLive.model : provider.model,
                currentProviderID: provider.slug,
                providers: codexLive.providers
            )
        }
    }

    private func apply(_ provider: StoredProvider) throws {
        switch provider.app {
        case .claude:
            try ClaudeLiveSettingsStore.save(
                to: paths.claudeSettings,
                baseURL: provider.baseURL,
                model: provider.model,
                apiKey: provider.apiKey.isEmpty ? nil : provider.apiKey,
                keepExistingKeyIfEmpty: true
            )
        case .codex:
            guard hasCodexFile else { throw LiveConfigError.missingFile(paths.codexConfig) }
            let next = try CodexTomlEditor.upsertProvider(
                codexText,
                id: provider.slug,
                name: provider.name,
                baseURL: provider.baseURL,
                apiKey: provider.apiKey.isEmpty ? nil : provider.apiKey,
                makeCurrent: true,
                model: provider.model
            )
            try CodexLiveSettingsStore.write(next, to: paths.codexConfig)
        }
    }

    private func writeActivate(_ provider: StoredProvider) async throws {
        let paths = self.paths
        let codexSnapshot = codexText
        let hasFile = hasCodexFile
        try await Task.detached(priority: .userInitiated) {
            switch provider.app {
            case .claude:
                try ClaudeLiveSettingsStore.save(
                    to: paths.claudeSettings,
                    baseURL: provider.baseURL,
                    model: provider.model,
                    apiKey: provider.apiKey.isEmpty ? nil : provider.apiKey,
                    keepExistingKeyIfEmpty: true
                )
            case .codex:
                guard hasFile else { throw LiveConfigError.missingFile(paths.codexConfig) }
                let next = try CodexTomlEditor.upsertProvider(
                    codexSnapshot,
                    id: provider.slug,
                    name: provider.name,
                    baseURL: provider.baseURL,
                    apiKey: provider.apiKey.isEmpty ? nil : provider.apiKey,
                    makeCurrent: true,
                    model: provider.model
                )
                try CodexLiveSettingsStore.write(next, to: paths.codexConfig)
            }
        }.value
    }

    private func writeCodexOfficial() async throws {
        let paths = self.paths
        let codexSnapshot = codexText
        let hasFile = hasCodexFile
        try await Task.detached(priority: .userInitiated) {
            guard hasFile else { throw LiveConfigError.missingFile(paths.codexConfig) }
            let next = CodexTomlEditor.switchProvider(codexSnapshot, to: "openai", model: nil)
            try CodexLiveSettingsStore.write(next, to: paths.codexConfig)
        }.value
    }

    /// Switches Codex back to the built-in OpenAI provider and official login.
    func useCodexOfficial() {
        codexLive = CodexLiveSettings(
            model: codexLive.model,
            currentProviderID: "openai",
            providers: codexLive.providers
        )
        runAsync(.codex) {
            try await self.writeCodexOfficial()
        }
    }

    // MARK: - Helpers

    private var editingID: UUID? {
        if case .edit(let id) = draftMode { return id }
        return nil
    }

    private func hostLabel(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host
    }

    private func run(_ target: LiveConfigApp, _ work: () throws -> Void) {
        messages[target] = nil
        isBusy = true
        defer { isBusy = false }
        do { try work() }
        catch { setError(error.localizedDescription, for: target) }
    }

    private func runAsync(_ target: LiveConfigApp, _ work: @escaping () async throws -> Void) {
        messages[target] = nil
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await work() }
            catch {
                setError(error.localizedDescription, for: target)
                reload()
            }
        }
    }

    private func setStatus(_ text: String, for target: LiveConfigApp) {
        messages[target] = Message(text: text, isError: false)
    }

    private func setError(_ text: String, for target: LiveConfigApp) {
        messages[target] = Message(text: text, isError: true)
    }

    private func clearError(for target: LiveConfigApp) {
        if messages[target]?.isError == true { messages[target] = nil }
    }
}

extension LiveConfigViewModel {
    static func documentation(app: LiveConfigApp) -> LiveConfigViewModel {
        let model = LiveConfigViewModel()
        model.seedDocumentation(app: app)
        return model
    }

    func seedDocumentation(app: LiveConfigApp) {
        hasLoaded = true
        self.app = app
        let relayID = UUID()
        let claudeID = UUID()
        providers = [
            StoredProvider(
                id: relayID,
                app: .codex,
                name: "Relay API",
                slug: "relay-api",
                baseURL: "https://relay.example/v1",
                model: "gpt-5",
                apiKey: "sk-doc-relay-key"
            ),
            StoredProvider(
                id: claudeID,
                app: .claude,
                name: "Company Gateway",
                slug: "company-gateway",
                baseURL: "https://api.company.test/v1",
                model: "claude-sonnet-4",
                apiKey: "sk-ant-doc-key"
            ),
        ]
        switch app {
        case .codex:
            hasCodexFile = true
            codexLive = CodexLiveSettings(
                model: "gpt-5",
                currentProviderID: "relay-api",
                providers: [
                    CodexTomlEditor.builtInOpenAI,
                    CodexProviderRecord(
                        id: "relay-api",
                        name: "Relay API",
                        baseURL: "https://relay.example/v1",
                        hasAPIKey: true,
                        maskedAPIKey: SecretDisplay.mask("sk-doc-relay-key"),
                        isBuiltIn: false
                    ),
                ]
            )
        case .claude:
            let claude = providers.first { $0.id == claudeID }!
            claudeLive = ClaudeLiveSettings(
                baseURL: claude.baseURL,
                model: claude.model,
                hasAPIKey: true,
                maskedAPIKey: SecretDisplay.mask(claude.apiKey)
            )
            claudeSecret = claude.apiKey
        }
    }
}
