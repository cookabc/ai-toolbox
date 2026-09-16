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

    enum ProbeState: Equatable {
        case running
        case done(EndpointProbeResult)
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
    /// Per-provider `settings.json` keys, edited as raw strings. Empty values mean
    /// "this provider does not own this key", which is what lets a switch hand the
    /// key back instead of leaving another provider's value behind.
    @Published var draftExtraEnv: [String: String] = [:]
    @Published var revealDraftKey = false
    @Published var isBusy = false

    /// Kept per tool so a Codex result never shows up under Claude Code.
    @Published private(set) var messages: [LiveConfigApp: Message] = [:]

    /// Probe results keyed by provider id. Kept out of `messages` on purpose: a
    /// slow endpoint must not look like a failed edit.
    @Published private(set) var probeStates: [UUID: ProbeState] = [:]

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
            let url = ClaudeLiveSettingsStore.normalizedBaseURL(claudeLive.baseURL)
            let model = claudeLive.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty || !model.isEmpty else { return nil }
            return visibleProviders.first {
                ClaudeLiveSettingsStore.normalizedBaseURL($0.baseURL) == url
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
        draftExtraEnv = [:]
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
        draftExtraEnv = provider.extraEnv
        revealDraftKey = false
        messages[app] = nil
    }

    /// Fills every Claude Code model alias with the provider's own model. This is
    /// the useful half of the old broadcast behaviour, but visible and opt-in: a
    /// relay that serves one model for every alias can say so explicitly.
    func fillFamilyModelsWithProviderModel() {
        let model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        for key in ClaudeLiveSettingsStore.familyModels {
            draftExtraEnv[key] = model
        }
    }

    func clearDraftExtraEnv() {
        draftExtraEnv = [:]
    }

    func cancelDraft() {
        draftMode = .none
        draftAPIKey = ""
        draftExtraEnv = [:]
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
            let trimmedModel = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only Claude Code has these keys. Blank fields are dropped, so clearing
            // one means "hand it back" rather than "write an empty value".
            let extraEnv: [String: String] = target == .claude
                ? draftExtraEnv.compactMapValues { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                : [:]
            let saved: StoredProvider
            switch draftMode {
            case .edit(let id):
                guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
                updated[index].name = name
                updated[index].slug = slug
                updated[index].baseURL = baseURL
                updated[index].model = trimmedModel
                updated[index].extraEnv = extraEnv
                if !key.isEmpty { updated[index].apiKey = key }
                saved = updated[index]
                // The endpoint or model may have changed, so any earlier result no
                // longer describes this provider.
                probeStates.removeValue(forKey: id)
            case .create:
                saved = StoredProvider(
                    app: target,
                    name: name,
                    slug: slug,
                    baseURL: baseURL,
                    model: trimmedModel,
                    apiKey: key,
                    extraEnv: extraEnv
                )
                updated.append(saved)
            case .none:
                return
            }

            try library.save(updated)
            providers = updated
            draftMode = .none
            draftAPIKey = ""
            draftExtraEnv = [:]

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
            probeStates.removeValue(forKey: provider.id)
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
                    apiKey: claudeSecret,
                    // Captures the model aliases and other per-provider keys that are
                    // in settings.json right now, so importing a working setup keeps
                    // it working instead of dropping half of it.
                    extraEnv: claudeLive.extraEnv
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

    // MARK: - Probing

    func probeState(for provider: StoredProvider) -> ProbeState? {
        probeStates[provider.id]
    }

    func isProbing(_ provider: StoredProvider) -> Bool {
        probeStates[provider.id] == .running
    }

    func probeResult(for provider: StoredProvider) -> EndpointProbeResult? {
        guard let state = probeStates[provider.id] else { return nil }
        if case .done(let result) = state { return result }
        return nil
    }

    /// Reachability check for one provider.
    ///
    /// Intentionally does not touch `isBusy`: probing is read-only, so the panel
    /// stays usable while a slow endpoint is being tried.
    func test(_ provider: StoredProvider) {
        guard probeStates[provider.id] != .running else { return }
        probeStates[provider.id] = .running
        Task {
            let result = await EndpointProbe.probe(provider)
            probeStates[provider.id] = .done(result)
        }
    }

    // MARK: - Writing to the live configs

    private func applyOptimistic(_ provider: StoredProvider) {
        switch provider.app {
        case .claude:
            let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            claudeLive = ClaudeLiveSettings(
                baseURL: ClaudeLiveSettingsStore.normalizedBaseURL(provider.baseURL),
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
                keepExistingKeyIfEmpty: true,
                extraEnv: provider.extraEnv,
                removingKeys: claudeRemovingKeys(for: provider)
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
        let removingKeys = claudeRemovingKeys(for: provider)
        try await Task.detached(priority: .userInitiated) {
            switch provider.app {
            case .claude:
                try ClaudeLiveSettingsStore.save(
                    to: paths.claudeSettings,
                    baseURL: provider.baseURL,
                    model: provider.model,
                    apiKey: provider.apiKey.isEmpty ? nil : provider.apiKey,
                    keepExistingKeyIfEmpty: true,
                    extraEnv: provider.extraEnv,
                    removingKeys: removingKeys
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
            let next = CodexTomlEditor.switchToBuiltInOpenAI(codexSnapshot)
            try CodexLiveSettingsStore.write(next, to: paths.codexConfig)
        }.value
    }

    /// Switches Codex back to the built-in OpenAI provider and official login.
    /// The model is cleared with it: the relay's model ID is not one the ChatGPT
    /// account accepts, so keeping it would fail every request.
    func useCodexOfficial() {
        codexLive = CodexLiveSettings(
            model: "",
            currentProviderID: "openai",
            providers: codexLive.providers
        )
        runAsync(.codex) {
            try await self.writeCodexOfficial()
        }
    }

    // MARK: - Helpers

    /// Keys some *other* Claude provider owns and this one does not. Passing these
    /// to the write path is what stops one relay's model aliases from lingering
    /// after a switch to a different relay. Keys no provider claims are never in
    /// this set, so a hand-written setting is always left alone.
    private func claudeRemovingKeys(for provider: StoredProvider) -> Set<String> {
        var keys = Set<String>()
        for other in providers where other.app == .claude && other.id != provider.id {
            keys.formUnion(other.extraEnv.keys)
        }
        keys.subtract(provider.extraEnv.keys)
        return keys
    }

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
        // One seeded probe result so the rendered panel shows the reachability badge.
        if let sample = providers.first(where: { $0.app == app }) {
            probeStates[sample.id] = .done(EndpointProbeResult(
                verdict: .healthy,
                status: 200,
                latency: 0.34,
                detail: "端点可达，路由与凭据都正常。"
            ))
        }
    }
}
