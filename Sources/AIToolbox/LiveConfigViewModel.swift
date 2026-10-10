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

    /// A destructive action waiting for the user to confirm it. Held here rather than
    /// in the view so the panel can present it above everything — header included —
    /// and so the decision itself is testable without a window.
    enum PendingConfirmation: Equatable {
        case deleteProvider(StoredProvider)
        case clearClaudeOverlay

        var title: String {
            switch self {
            case .deleteProvider(let provider): L10n.Config.deleteTitle(provider.name)
            case .clearClaudeOverlay: L10n.Config.clearClaudeTitle
            }
        }

        var message: String {
            switch self {
            case .deleteProvider(let provider):
                provider.app == .codex ? L10n.Config.deleteCodexMessage : L10n.Config.deleteClaudeMessage
            case .clearClaudeOverlay: L10n.Config.clearClaudeMessage
            }
        }

        var confirmTitle: String {
            switch self {
            case .deleteProvider: L10n.Config.delete
            case .clearClaudeOverlay: L10n.Config.clearClaudeConfirm
            }
        }
    }

    @Published var app: LiveConfigApp = .claude
    @Published private(set) var providers: [StoredProvider] = []
    @Published private(set) var claudeLive = ClaudeLiveSettings.empty
    @Published private(set) var codexLive = CodexLiveSettings.official
    @Published private(set) var codexState: CodexFileState = .absent
    @Published private(set) var claudeReadError: String?
    @Published private(set) var libraryReadError: String?

    @Published var draftMode: DraftMode = .none
    @Published var draftName = ""
    @Published var draftSlug = ""
    @Published var draftBaseURL = ""
    @Published var draftModel = ""
    @Published var draftAPIKey = ""
    @Published var draftCredential: ClaudeCredential = .apiKey
    /// Per-provider `settings.json` keys, edited as raw strings. Empty values mean
    /// "this provider does not own this key", which is what lets a switch hand the
    /// key back instead of leaving another provider's value behind.
    @Published var draftExtraEnv: [String: String] = [:]
    @Published var revealDraftKey = false
    @Published private(set) var isBusy = false

    /// The result of the last action, kept per tool so a Codex result never shows up
    /// under Claude Code.
    @Published private(set) var messages: [LiveConfigApp: Message] = [:]

    /// Probe results keyed by provider id. Kept out of `messages` on purpose: a
    /// slow endpoint must not look like a failed edit.
    @Published private(set) var probeStates: [UUID: ProbeState] = [:]

    @Published private(set) var pendingConfirmation: PendingConfirmation?

    private let store: LiveConfigStore
    private var claudeSecret = ""
    private var hasLoaded = false
    /// Seeded with sample data for screenshots and layout tests. Such a model must
    /// never read or write the user's real files, whatever the view asks of it.
    private var isFixture = false
    /// Actions run one after another, each on the files as the previous one left them.
    private var queue: Task<Void, Never>?
    private var runningActions = 0

    init(paths: LiveConfigPaths = .default, library: ProviderLibraryStore = ProviderLibraryStore()) {
        store = LiveConfigStore(paths: paths, library: library)
    }

    // MARK: - Reading

    func loadOnce() {
        guard !hasLoaded else { return }
        reload()
    }

    /// Re-reads the library and both live configs. An open draft is left alone, so
    /// this is safe to call whenever the panel opens.
    func reload() {
        hasLoaded = true
        guard !isFixture else { return }
        do {
            providers = try store.library.load()
            libraryReadError = nil
        } catch {
            libraryReadError = L10n.Config.libraryUnreadable(
                path: store.library.url.path, reason: error.localizedDescription)
        }
        do {
            let loaded = try ClaudeLiveSettingsStore.load(from: store.paths.claudeSettings)
            claudeLive = loaded.settings
            claudeSecret = loaded.secret
            claudeReadError = nil
        } catch {
            claudeLive = .empty
            claudeSecret = ""
            claudeReadError = L10n.Config.claudeUnreadable(error.localizedDescription)
        }
        let codex = store.readCodex()
        codexLive = codex.settings
        codexState = codex.state
    }

    /// For tests: returns once every queued action has finished.
    func waitUntilIdle() async {
        await queue?.value
    }

    // MARK: - Derived state

    var visibleProviders: [StoredProvider] {
        providers.filter { $0.app == app }
    }

    var activeProviderID: UUID? { activeProviderID(for: app) }

    /// The saved provider the live config currently describes. For Claude Code that
    /// means the same endpoint, model and key, so two providers on one relay with
    /// different keys are told apart.
    func activeProviderID(for app: LiveConfigApp) -> UUID? {
        switch app {
        case .claude:
            guard claudeLive.hasOverlay else { return nil }
            let url = ClaudeLiveSettingsStore.normalizedBaseURL(claudeLive.baseURL)
            let model = claudeLive.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return providers.first { provider in
                let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                return provider.app == .claude
                    && ClaudeLiveSettingsStore.normalizedBaseURL(provider.baseURL) == url
                    && provider.model.trimmingCharacters(in: .whitespacesAndNewlines) == model
                    && key == claudeSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                    && (key.isEmpty || provider.credential == claudeLive.credential)
            }?.id
        case .codex:
            guard codexState == .ready else { return nil }
            return providers.first { $0.app == .codex && $0.slug == codexLive.currentProviderID }?.id
        }
    }

    /// True when the live file points somewhere the library does not describe yet.
    var liveConfigIsUnmanaged: Bool {
        switch app {
        case .claude:
            return claudeLive.hasOverlay && activeProviderID(for: .claude) == nil
        case .codex:
            guard codexState == .ready else { return false }
            let known = Set(providers.filter { $0.app == .codex }.map(\.slug))
            return codexLive.providers.contains { !$0.isBuiltIn && !known.contains($0.id) }
        }
    }

    var codexUsesOfficialLogin: Bool {
        codexLive.currentProviderID == CodexTomlEditor.builtInOpenAI.id
    }

    /// Claude Code is on its own login when `settings.json` carries none of the keys
    /// a provider writes. Unknown while the file cannot be read.
    var claudeUsesOfficialLogin: Bool {
        claudeReadError == nil && !claudeLive.hasOverlay
    }

    /// A problem reading the files the selected tab depends on. Unlike `errorMessage`
    /// it describes the files as they are, not the last action.
    var readProblem: String? {
        if let libraryReadError { return libraryReadError }
        switch app {
        case .claude: return claudeReadError
        case .codex:
            if case .unreadable(let message) = codexState { return message }
            return nil
        }
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
        case .claude: store.paths.claudeSettings.deletingLastPathComponent()
        case .codex: store.paths.codexHome
        }
    }

    var editingProvider: StoredProvider? {
        guard case .edit(let id) = draftMode else { return nil }
        return providers.first { $0.id == id }
    }

    // MARK: - Draft

    func beginCreate() {
        draftMode = .create
        draftName = ""
        draftSlug = ""
        draftBaseURL = ""
        draftModel = ""
        draftAPIKey = ""
        draftCredential = .apiKey
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
        draftCredential = provider.credential
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

    /// Saves the draft into the library. `activate` also makes it the live provider.
    ///
    /// Editing the provider that is live updates the live config as well: "save
    /// without switching" means "keep the same provider active", not "leave the
    /// active one running on the values you just replaced".
    func saveDraft(activate: Bool) {
        let target = app
        do {
            guard libraryReadError == nil else { throw LiveConfigError.libraryUnreadable }
            let (saved, wasActive) = try draftProvider(for: target)
            let removing = claudeRemovingKeys(for: saved, among: providers)
            let appliesLive = activate || wasActive
            perform(target, onSuccess: { [weak self] in
                self?.probeStates.removeValue(forKey: saved.id)
                self?.cancelDraft()
            }) { store in
                var note: String?
                if appliesLive {
                    note = try store.activate(saved, removingClaudeKeys: removing)
                }
                try store.updateLibrary { providers in
                    if let index = providers.firstIndex(where: { $0.id == saved.id }) {
                        providers[index] = saved
                    } else {
                        providers.append(saved)
                    }
                }
                if !appliesLive {
                    do { try store.syncCodexTable(saved) } catch { note = error.localizedDescription }
                }
                let base = activate ? L10n.Config.savedAndSwitched(saved.name)
                    : wasActive ? L10n.Config.savedLiveUpdated(saved.name)
                    : L10n.Config.savedLiveUnchanged(saved.name)
                return statusLine(base, note: note)
            }
        } catch {
            setError(error.localizedDescription, for: target)
        }
    }

    func activate(_ provider: StoredProvider) {
        let removing = claudeRemovingKeys(for: provider, among: providers)
        perform(provider.app) { store in
            let note = try store.activate(provider, removingClaudeKeys: removing)
            return statusLine(L10n.Config.switched(provider.name), note: note)
        }
    }

    /// Switches Codex back to the built-in OpenAI provider and official login.
    /// The model is cleared with it: the relay's model ID is not one the ChatGPT
    /// account accepts, so keeping it would fail every request.
    func useCodexOfficial() {
        perform(.codex) { store in
            try store.useCodexOfficial()
            return L10n.Config.switchedToOfficialOpenAI
        }
    }

    // MARK: - Confirmation

    func requestDelete(_ provider: StoredProvider) {
        pendingConfirmation = .deleteProvider(provider)
    }

    func requestClearClaudeOverlay() {
        pendingConfirmation = .clearClaudeOverlay
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        switch pending {
        case .deleteProvider(let provider): delete(provider)
        case .clearClaudeOverlay: clearClaudeOverlay()
        }
    }

    func cancelPending() {
        pendingConfirmation = nil
    }

    func delete(_ provider: StoredProvider) {
        guard libraryReadError == nil else {
            setError(LiveConfigError.libraryUnreadable.localizedDescription, for: provider.app)
            return
        }
        perform(provider.app, onSuccess: { [weak self] in
            guard let self else { return }
            probeStates.removeValue(forKey: provider.id)
            if case .edit(let editing) = draftMode, editing == provider.id { cancelDraft() }
        }) { store in
            // The live config goes first: if it cannot be edited, the library still
            // describes it and nothing is half done.
            if provider.app == .codex { try store.removeCodexProvider(provider.slug) }
            try store.updateLibrary { $0.removeAll { $0.id == provider.id } }
            return L10n.Config.deleted(provider.name)
        }
    }

    /// Turns whatever the live config currently points at into library entries.
    func importLiveConfig() {
        let target = app
        guard libraryReadError == nil else {
            setError(LiveConfigError.libraryUnreadable.localizedDescription, for: target)
            return
        }
        perform(target) { store in
            var count = 0
            try store.updateLibrary { providers in
                switch target {
                case .claude:
                    let (live, secret) = try ClaudeLiveSettingsStore.load(from: store.paths.claudeSettings)
                    guard live.hasOverlay else { return }
                    let name = URL(string: live.baseURL)?.host ?? L10n.Config.importedClaudeName
                    let taken = Set(providers.filter { $0.app == .claude }.map(\.slug))
                    providers.append(StoredProvider(
                        app: .claude,
                        name: name,
                        slug: ProviderSlug.suggest(from: name, existing: taken),
                        baseURL: live.baseURL,
                        model: live.model,
                        apiKey: secret,
                        credential: live.credential,
                        // Captures the model aliases and other per-provider keys that are
                        // in settings.json right now, so importing a working setup keeps
                        // it working instead of dropping half of it.
                        extraEnv: live.extraEnv
                    ))
                    count = 1
                case .codex:
                    guard let text = store.readCodex().text else { return }
                    let live = try CodexTomlEditor.load(text)
                    let known = Set(providers.filter { $0.app == .codex }.map(\.slug))
                    for record in live.providers where !record.isBuiltIn && !known.contains(record.id) {
                        providers.append(StoredProvider(
                            app: .codex,
                            name: record.name,
                            slug: record.id,
                            baseURL: record.baseURL,
                            model: record.id == live.currentProviderID ? live.model : "",
                            apiKey: CodexTomlEditor.secret(in: text, id: record.id)
                        ))
                        count += 1
                    }
                }
            }
            return count > 0 ? L10n.Config.imported(count) : L10n.Config.nothingToImport
        }
    }

    func clearClaudeOverlay() {
        let owned = Set(providers.filter { $0.app == .claude }.flatMap(\.extraEnv.keys))
        perform(.claude) { store in
            try store.clearClaude(providerKeys: owned)
            return L10n.Config.clearedClaude
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
        guard case .done(let result) = probeStates[provider.id] else { return nil }
        return result
    }

    /// Reachability check for one provider. Read-only, so it does not touch
    /// `isBusy`: the panel stays usable while a slow endpoint is being tried.
    func test(_ provider: StoredProvider) {
        guard probeStates[provider.id] != .running else { return }
        probeStates[provider.id] = .running
        Task {
            let result = await EndpointProbe.probe(provider)
            probeStates[provider.id] = .done(result)
        }
    }

    // MARK: - Helpers

    private func draftProvider(for target: LiveConfigApp) throws -> (StoredProvider, wasActive: Bool) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LiveConfigError.missingField(L10n.Config.name) }
        guard !baseURL.isEmpty else { throw LiveConfigError.missingField(L10n.Config.baseURL) }
        guard let components = URLComponents(string: baseURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              !(components.host ?? "").isEmpty else {
            throw LiveConfigError.missingField(L10n.Config.fieldBaseURLScheme)
        }
        let key = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only Claude Code has these keys. Blank fields are dropped, so clearing one
        // means "hand it back" rather than "write an empty value".
        let extraEnv = target == .claude
            ? draftExtraEnv.compactMapValues { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            : [:]

        switch draftMode {
        case .edit(let id):
            guard var provider = providers.first(where: { $0.id == id }) else {
                throw LiveConfigError.writeFailed(L10n.Config.editedProviderGone)
            }
            let wasActive = activeProviderID(for: provider.app) == id
            provider.name = name
            provider.baseURL = baseURL
            provider.model = model
            provider.credential = draftCredential
            provider.extraEnv = extraEnv
            if !key.isEmpty { provider.apiKey = key }
            return (provider, wasActive)
        case .create:
            let saved = Set(providers.filter { $0.app == target }.map(\.slug))
            var slug = draftSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            if slug.isEmpty {
                // Tables written by hand are avoided too: adopting one by accident
                // would overwrite its endpoint and key on the first switch.
                let taken = target == .codex ? saved.union(codexLive.providers.map(\.id)) : saved
                slug = ProviderSlug.suggest(from: name, existing: taken)
            } else if target == .codex {
                guard ProviderIDRules.isValid(slug) else { throw LiveConfigError.invalidProviderID }
                guard !ProviderIDRules.reservedCodexIDs.contains(slug) else { throw LiveConfigError.reservedProviderID }
                guard !saved.contains(slug) else { throw LiveConfigError.duplicateProviderID(slug) }
            }
            return (StoredProvider(
                app: target, name: name, slug: slug, baseURL: baseURL, model: model,
                apiKey: key, credential: draftCredential, extraEnv: extraEnv
            ), false)
        case .none:
            throw LiveConfigError.missingField(L10n.Config.fieldProvider)
        }
    }

    /// Keys some *other* Claude provider owns and this one does not. Passing these
    /// to the write path is what stops one relay's model aliases from lingering
    /// after a switch to a different relay. Keys no provider claims are never in
    /// this set, so a hand-written setting is always left alone.
    private func claudeRemovingKeys(for provider: StoredProvider, among providers: [StoredProvider]) -> Set<String> {
        guard provider.app == .claude else { return [] }
        var keys = Set<String>()
        for other in providers where other.app == .claude && other.id != provider.id {
            keys.formUnion(other.extraEnv.keys)
        }
        keys.subtract(provider.extraEnv.keys)
        return keys
    }

    /// Runs `work` off the main thread after every earlier action, then re-reads the
    /// files so the panel shows what is actually on disk, whether the action worked
    /// or not.
    private func perform(
        _ target: LiveConfigApp,
        onSuccess: (() -> Void)? = nil,
        _ work: @escaping @Sendable (LiveConfigStore) throws -> String?
    ) {
        guard !isFixture else { return }
        // The previous message stays put until this action replaces it. Clearing it
        // here removed and re-added the notice row around every action, and each of
        // those moves the content-fitted panel — the bounce seen on every switch.
        runningActions += 1
        isBusy = true
        let store = self.store
        let previous = queue
        queue = Task {
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) {
                Result { try work(store) }
            }.value
            reload()
            switch result {
            case .success(let status):
                onSuccess?()
                if let status { setStatus(status, for: target) }
            case .failure(let error):
                setError(error.localizedDescription, for: target)
            }
            runningActions -= 1
            isBusy = runningActions > 0
        }
    }

    private func setStatus(_ text: String, for target: LiveConfigApp) {
        messages[target] = Message(text: text, isError: false)
    }

    private func setError(_ text: String, for target: LiveConfigApp) {
        messages[target] = Message(text: text, isError: true)
    }
}

/// A status line plus the caveat an action has to carry, e.g. that the switch
/// worked but Codex will not list the model until it can be published.
private func statusLine(_ text: String, note: String?) -> String {
    guard let note else { return text }
    return L10n.Config.withNote(text, note)
}

extension LiveConfigViewModel {
    static func documentation(app: LiveConfigApp) -> LiveConfigViewModel {
        let model = LiveConfigViewModel()
        model.seedDocumentation(app: app)
        return model
    }

    func seedDocumentation(app: LiveConfigApp) {
        hasLoaded = true
        isFixture = true
        self.app = app
        let relayID = UUID()
        let claudeID = UUID()
        providers = [
            StoredProvider(
                id: relayID,
                app: .codex,
                name: "中转网关",
                slug: "relay-api",
                baseURL: "https://relay.example/v1",
                model: "gpt-5",
                apiKey: "sk-doc-relay-key"
            ),
            StoredProvider(
                id: claudeID,
                app: .claude,
                name: "公司网关",
                slug: "company-gateway",
                baseURL: "https://api.company.test/v1",
                model: "claude-sonnet-4",
                apiKey: "sk-ant-doc-key"
            ),
        ]
        switch app {
        case .codex:
            codexState = .ready
            codexLive = CodexLiveSettings(
                model: "gpt-5",
                currentProviderID: "relay-api",
                providers: [
                    CodexTomlEditor.builtInOpenAI,
                    CodexProviderRecord(
                        id: "relay-api",
                        name: "中转网关",
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
                baseURL: ClaudeLiveSettingsStore.normalizedBaseURL(claude.baseURL),
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
                detail: L10n.Probe.healthyDetail
            ))
        }
    }

    /// Fixture states beyond the README's, for the state gallery the visual review
    /// is done against. Sample data only; like `seedDocumentation`, a model seeded
    /// this way never reads or writes the user's files.
    enum GalleryScenario {
        /// Three providers: the live one, one whose probe failed, one never probed.
        case crowded
        /// The live config points somewhere the library does not describe.
        case unmanaged
        /// The provider library cannot be read, and the last action failed.
        case unreadable
        /// No saved providers; the tool is on its own login.
        case official
    }

    static func gallery(app: LiveConfigApp, _ scenario: GalleryScenario) -> LiveConfigViewModel {
        let model = LiveConfigViewModel()
        model.seedDocumentation(app: app)
        model.seedGallery(scenario)
        return model
    }

    func seedGallery(_ scenario: GalleryScenario) {
        switch scenario {
        case .crowded:
            let failing = StoredProvider(
                app: app, name: "备用中转", slug: "backup-relay",
                baseURL: "https://backup.example/v1/",
                model: app == .codex ? "gpt-5-codex" : "claude-opus-4",
                apiKey: "sk-doc-backup-key", credential: .authToken)
            let idle = StoredProvider(
                app: app, name: "本地网关（实验）", slug: "local-lab",
                baseURL: "http://192.168.1.20:8080/v1", model: "", apiKey: "")
            providers += [failing, idle]
            probeStates[failing.id] = .done(EndpointProbeResult(
                verdict: .badRoute, status: 404, latency: 0.128,
                detail: app == .claude ? L10n.Probe.badRouteClaude : L10n.Probe.badRouteCodex))
            probeStates[idle.id] = .running
            messages[app] = Message(text: L10n.Config.switched(providers.first { $0.app == app }!.name), isError: false)
        case .unmanaged:
            switch app {
            case .codex:
                codexLive.providers.append(CodexProviderRecord(
                    id: "hand-written", name: "hand-written", baseURL: "https://manual.example/v1",
                    hasAPIKey: true, maskedAPIKey: SecretDisplay.mask("sk-manual-0000"), isBuiltIn: false))
            case .claude:
                claudeLive = ClaudeLiveSettings(
                    baseURL: "https://unsaved.example", model: "claude-sonnet-4", hasAPIKey: true,
                    maskedAPIKey: SecretDisplay.mask("sk-unsaved-0000"))
                claudeSecret = "sk-unsaved-0000"
            }
        case .unreadable:
            libraryReadError = L10n.Config.libraryUnreadable(
                path: "~/Library/Application Support/AIToolbox/providers.json",
                reason: "数据格式不正确。")
            messages[app] = Message(text: LiveConfigError.libraryUnreadable.localizedDescription, isError: true)
        case .official:
            providers.removeAll { $0.app == app }
            probeStates = [:]
            switch app {
            case .codex:
                codexLive = .official
            case .claude:
                claudeLive = .empty
                claudeSecret = ""
            }
        }
    }
}
