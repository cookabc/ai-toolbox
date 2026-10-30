import Foundation

/// What the Codex half of the panel can do with `config.toml` right now.
enum CodexFileState: Equatable, Sendable {
    /// The file exists and parses.
    case ready
    /// `~/.codex` exists without a `config.toml`; switching to a provider creates it.
    case absent
    /// Codex has never run on this machine.
    case noCodexHome
    case unreadable(String)
}

/// Every read and write of the live configs, free of UI state so it can run off the
/// main thread. Each method is one complete read-modify-write of the files as they
/// are at that moment — see `ConfigFile` for why that matters.
struct LiveConfigStore: Sendable {
    let paths: LiveConfigPaths
    let library: ProviderLibraryStore

    struct CodexSnapshot: Sendable {
        var settings: CodexLiveSettings
        var text: String?
        var state: CodexFileState
    }

    func readCodex() -> CodexSnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: paths.codexHome.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return CodexSnapshot(settings: .official, text: nil, state: .noCodexHome)
        }
        do {
            guard let data = try ConfigFile.read(paths.codexConfig) else {
                return CodexSnapshot(settings: .official, text: nil, state: .absent)
            }
            let text = try Self.utf8(data, name: "config.toml")
            return CodexSnapshot(settings: try CodexTomlEditor.load(text), text: text, state: .ready)
        } catch {
            return CodexSnapshot(
                settings: .official, text: nil, state: .unreadable(error.localizedDescription))
        }
    }

    /// Makes `provider` the one its tool uses. Returns a caveat worth showing beside
    /// the status line, or `nil`.
    func activate(_ provider: StoredProvider, removingClaudeKeys: Set<String>) throws -> String? {
        switch provider.app {
        case .claude:
            try ClaudeLiveSettingsStore.save(
                to: paths.claudeSettings,
                ClaudeLiveSettingsStore.edit(
                    baseURL: provider.baseURL,
                    model: provider.model,
                    apiKey: provider.apiKey,
                    credential: provider.credential,
                    extraEnv: provider.extraEnv,
                    removingKeys: removingClaudeKeys
                ))
            return nil
        case .codex:
            return try writeCodex(provider, makeCurrent: true)
        }
    }

    /// Brings an existing `[model_providers.<slug>]` table in line with an edited
    /// provider, so a profile or `-c model_provider=…` that names it gets the new
    /// endpoint too. A provider Codex does not know yet is not added: saving is not
    /// switching.
    func syncCodexTable(_ provider: StoredProvider) throws {
        guard provider.app == .codex, readCodex().state == .ready else { return }
        _ = try writeCodex(provider, makeCurrent: false)
    }

    func useCodexOfficial() throws {
        let officialModel = rememberedOfficialModel()
        try ConfigFile.update(paths.codexConfig) { data in
            guard let data else { return nil }
            let text = try Self.utf8(data, name: "config.toml")
            return Data(try CodexTomlEditor.switchToBuiltInOpenAI(text, officialModel: officialModel).utf8)
        }
        removeCatalogIfUnused()
    }

    func removeCodexProvider(_ slug: String) throws {
        let officialModel = rememberedOfficialModel()
        try ConfigFile.update(paths.codexConfig) { data in
            guard let data else { return nil }
            let text = try Self.utf8(data, name: "config.toml")
            return Data(try CodexTomlEditor.removeProvider(text, id: slug, officialModel: officialModel).utf8)
        }
        removeCatalogIfUnused()
    }

    func clearClaude(providerKeys: Set<String>) throws {
        try ClaudeLiveSettingsStore.clearAPIOverlay(at: paths.claudeSettings, providerKeys: providerKeys)
    }

    /// Applies `change` to the library as it is on disk.
    func updateLibrary(_ change: (inout [StoredProvider]) throws -> Void) throws {
        var providers = try library.load()
        try change(&providers)
        try library.save(providers)
    }

    static func utf8(_ data: Data, name: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw LiveConfigError.notUTF8(name) }
        return text
    }

    // MARK: - Codex

    /// Where the official login's model is kept while a relay is active, next to the
    /// provider library.
    private var officialModelURL: URL {
        library.url.deletingLastPathComponent().appending(path: "codex-official-model.txt")
    }

    private func rememberedOfficialModel() -> String? {
        let data = try? ConfigFile.read(officialModelURL)
        let model = data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return model?.isEmpty == false ? model : nil
    }

    private func rememberOfficialModel(_ model: String) {
        try? ConfigFile.write(Data(model.utf8), to: officialModelURL)
    }

    private func writeCodex(_ provider: StoredProvider, makeCurrent: Bool) throws -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: paths.codexHome.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw LiveConfigError.missingCodexHome }
        // Written before `config.toml`, which may only ever point at a catalog that
        // already exists.
        let publication = makeCurrent ? publishCatalog(for: provider) : CatalogPublication()
        var keptHandWritten = false
        var leavingOfficialModel: String?
        try ConfigFile.update(paths.codexConfig) { data in
            let text = try data.map { try Self.utf8($0, name: "config.toml") } ?? ""
            if !makeCurrent, !CodexTomlEditor.hasProvider(text, id: provider.slug) { return nil }
            leavingOfficialModel = makeCurrent ? CodexTomlEditor.officialModel(in: text) : nil
            keptHandWritten =
                CodexTomlEditor.rootString(text, key: CodexTomlEditor.modelCatalogKey) != nil
                && !CodexTomlEditor.pointsAtPublishedCatalog(text)
            let next = try CodexTomlEditor.upsertProvider(
                text,
                id: provider.slug,
                name: provider.name,
                baseURL: provider.baseURL,
                apiKey: provider.apiKey.isEmpty ? nil : provider.apiKey,
                makeCurrent: makeCurrent,
                model: provider.model,
                modelCatalog: keptHandWritten ? nil : publication.path
            )
            return Data(next.utf8)
        }
        removeCatalogIfUnused()
        if let leavingOfficialModel { rememberOfficialModel(leavingOfficialModel) }
        if makeCurrent, keptHandWritten, publication.path != nil {
            return L10n.Config.keptHandWrittenCatalog
        }
        return publication.note
    }

    /// The outcome of publishing a provider's model to Codex's catalog: the path to
    /// point `model_catalog_json` at, and the sentence to show when it could not be
    /// published. Best effort — the switch itself works either way, so a missing
    /// catalog costs the picker entry, not the provider.
    private struct CatalogPublication {
        var path: String?
        var note: String?
    }

    private func publishCatalog(for provider: StoredProvider) -> CatalogPublication {
        let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return CatalogPublication() }
        do {
            let data = try CodexModelCatalog.make(
                providerName: provider.name, model: model, officialCatalog: paths.codexOfficialCatalog
            )
            try ConfigFile.write(data, to: paths.codexModelCatalog)
            return CatalogPublication(path: paths.codexModelCatalog.path)
        } catch {
            return CatalogPublication(note: error.localizedDescription)
        }
    }

    /// The published catalog describes one provider; once `config.toml` stops
    /// pointing at it, it would only describe the wrong one.
    private func removeCatalogIfUnused() {
        let data = try? ConfigFile.read(paths.codexConfig)
        if let text = data.flatMap({ String(data: $0, encoding: .utf8) }),
            CodexTomlEditor.pointsAtPublishedCatalog(text)
        {
            return
        }
        ConfigFile.remove(paths.codexModelCatalog)
    }
}
