import Foundation

/// The edits AI 工具台 makes to `~/.codex/config.toml`, as pure text-to-text
/// functions. Every edit goes through `TomlDocument`, so it touches only the keys it
/// names and refuses a file it cannot parse instead of guessing at it.
enum CodexTomlEditor {
    /// Root key Codex reads the model picker's catalog from.
    static let modelCatalogKey = "model_catalog_json"
    static let providersTable = "model_providers"

    static let builtInOpenAI = CodexProviderRecord(
        id: "openai",
        name: L10n.Config.officialOpenAI,
        baseURL: "",
        hasAPIKey: false,
        maskedAPIKey: L10n.Config.officialCodexKey,
        isBuiltIn: true
    )

    static func load(_ text: String) throws -> CodexLiveSettings {
        let document = try parse(text)
        let custom = document.childTables(of: [providersTable]).map { id in
            let fields = document.strings(in: [providersTable, id])
            let secret = fields["experimental_bearer_token"] ?? ""
            let envKey = fields["env_key"] ?? ""
            return CodexProviderRecord(
                id: id,
                name: fields["name"] ?? id,
                baseURL: fields["base_url"] ?? "",
                hasAPIKey: !secret.isEmpty || !envKey.isEmpty,
                maskedAPIKey: !secret.isEmpty
                    ? SecretDisplay.mask(secret)
                    : (envKey.isEmpty ? L10n.Config.notSet : L10n.Config.environmentKey(envKey)),
                isBuiltIn: false
            )
        }
        return CodexLiveSettings(
            model: document.string("model") ?? "",
            currentProviderID: document.string("model_provider") ?? builtInOpenAI.id,
            providers: [builtInOpenAI] + custom
        )
    }

    static func secret(in text: String, id: String) -> String {
        (try? parse(text))?.string("experimental_bearer_token", in: [providersTable, id]) ?? ""
    }

    static func rootString(_ text: String, key: String) -> String? {
        (try? parse(text))?.string(key)
    }

    static func hasProvider(_ text: String, id: String) -> Bool {
        (try? parse(text))?.hasTable([providersTable, id]) ?? false
    }

    static func providerFields(in text: String, id: String) -> [String: String] {
        (try? parse(text))?.strings(in: [providersTable, id]) ?? [:]
    }

    /// Writes one provider's table and, with `makeCurrent`, makes it the active one.
    ///
    /// Only the keys the app owns are touched. `wire_api` is written for a new table
    /// but left alone on an existing one, because a value somebody set by hand is
    /// the one thing this app has no way of knowing better. An empty `apiKey` keeps
    /// whatever credential the table already has.
    static func upsertProvider(
        _ text: String,
        id: String,
        name: String,
        baseURL: String,
        apiKey: String?,
        makeCurrent: Bool,
        model: String?,
        modelCatalog: String? = nil
    ) throws -> String {
        guard ProviderIDRules.isValid(id) else { throw LiveConfigError.invalidProviderID }
        guard !ProviderIDRules.reservedCodexIDs.contains(id) else { throw LiveConfigError.reservedProviderID }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw LiveConfigError.missingField("Base URL") }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? id : trimmedName
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var document = try parse(text)
        let table = [providersTable, id]
        guard !document.isDefinedOutsideItsTable(table) else { throw LiveConfigError.unsupportedCodexLayout(id) }
        if document.hasTable(table) {
            try document.setString("name", displayName, in: table)
            try document.setString("base_url", trimmedURL, in: table, after: "name")
            if document.string("wire_api", in: table) == nil {
                try document.setString("wire_api", "responses", in: table, after: "base_url")
            }
            if !key.isEmpty {
                try document.setString("experimental_bearer_token", key, in: table)
                // A saved key replaces whatever else the table authenticated with, so
                // the key the panel shows is the key Codex sends.
                try document.remove("env_key", in: table)
            }
        } else {
            var values = [("name", displayName), ("base_url", trimmedURL), ("wire_api", "responses")]
            if !key.isEmpty { values.append(("experimental_bearer_token", key)) }
            try document.appendTable(table, values: values)
        }
        if makeCurrent {
            try select(id, model: model, catalog: modelCatalog, in: &document)
        }
        return document.text
    }

    /// Removes a provider's table. When it was the active one, Codex falls back to
    /// the built-in provider, with `officialModel` as its model.
    static func removeProvider(_ text: String, id: String, officialModel: String? = nil) throws -> String {
        guard !ProviderIDRules.reservedCodexIDs.contains(id) else { throw LiveConfigError.reservedProviderID }
        var document = try parse(text)
        let table = [providersTable, id]
        guard document.hasTable(table) else { return text }
        guard !document.isDefinedOutsideItsTable(table) else { throw LiveConfigError.unsupportedCodexLayout(id) }
        try document.removeTable(table)
        if (document.string("model_provider") ?? builtInOpenAI.id) == id {
            try selectBuiltInOpenAI(officialModel: officialModel, in: &document)
        }
        return document.text
    }

    /// The built-in provider signs in with the ChatGPT account and only accepts
    /// OpenAI model IDs. Leaving a relay's `model` in place makes every request fail
    /// with "The '<model>' model is not supported when using Codex with a ChatGPT
    /// account". So the relay's model goes, and `officialModel` — the one the
    /// official login used before the first switch away — comes back. Without one,
    /// Codex picks its own default.
    static func switchToBuiltInOpenAI(_ text: String, officialModel: String? = nil) throws -> String {
        var document = try parse(text)
        try selectBuiltInOpenAI(officialModel: officialModel, in: &document)
        return document.text
    }

    /// The model the built-in provider runs with, when it is the active one. Worth
    /// remembering before a switch away overwrites it with a relay's model.
    static func officialModel(in text: String) -> String? {
        guard let document = try? parse(text),
              (document.string("model_provider") ?? builtInOpenAI.id) == builtInOpenAI.id else { return nil }
        return document.string("model")
    }

    /// Whether `model_catalog_json` names the file this app publishes. A catalog
    /// configured by hand is never ours to remove: nothing here could restore it.
    static func pointsAtPublishedCatalog(_ text: String) -> Bool {
        guard let current = rootString(text, key: modelCatalogKey) else { return false }
        return URL(fileURLWithPath: current).lastPathComponent == CodexModelCatalog.fileName
    }

    // MARK: - Private

    private static func parse(_ text: String) throws -> TomlDocument {
        do {
            return try TomlDocument(text)
        } catch let error as TomlDocument.ParseError {
            throw LiveConfigError.unparseableCodexConfig(line: error.line)
        }
    }

    private static func select(_ id: String, model: String?, catalog: String?, in document: inout TomlDocument) throws {
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !model.isEmpty { try document.setString("model", model) }
        try document.setString("model_provider", id, after: "model")
        try setCatalog(catalog, in: &document)
    }

    private static func selectBuiltInOpenAI(officialModel: String?, in document: inout TomlDocument) throws {
        try document.setString("model_provider", builtInOpenAI.id, after: "model")
        if let officialModel, !officialModel.isEmpty {
            try document.setString("model", officialModel)
        } else {
            try document.remove("model")
        }
        // The published catalog lists only the relay's model and hides the official
        // ones, so it has to go with the relay.
        try setCatalog(nil, in: &document)
    }

    private static func setCatalog(_ path: String?, in document: inout TomlDocument) throws {
        if let path {
            try document.setString(modelCatalogKey, path, after: "model_provider")
        } else if let current = document.string(modelCatalogKey),
                  URL(fileURLWithPath: current).lastPathComponent == CodexModelCatalog.fileName {
            try document.remove(modelCatalogKey)
        }
    }
}
