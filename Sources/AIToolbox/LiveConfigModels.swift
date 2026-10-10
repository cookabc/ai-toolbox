import Foundation

enum LiveConfigApp: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, codex

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// How Claude Code sends a provider's key. Official Anthropic endpoints take
/// `x-api-key`; many relays only accept `Authorization: Bearer`, which Claude Code
/// sends for `ANTHROPIC_AUTH_TOKEN`.
enum ClaudeCredential: String, Codable, CaseIterable, Sendable {
    case apiKey, authToken

    var variable: String {
        switch self {
        case .apiKey: ClaudeLiveSettingsStore.apiKey
        case .authToken: ClaudeLiveSettingsStore.authToken
        }
    }

    var label: String {
        switch self {
        case .apiKey: L10n.Config.credentialAPIKey
        case .authToken: L10n.Config.credentialAuthToken
        }
    }

    var help: String {
        switch self {
        case .apiKey: L10n.Config.credentialAPIKeyHelp
        case .authToken: L10n.Config.credentialAuthTokenHelp
        }
    }
}

struct ClaudeLiveSettings: Equatable, Sendable {
    var baseURL: String
    var model: String
    var hasAPIKey: Bool
    var maskedAPIKey: String
    var credential: ClaudeCredential
    /// Values currently set in `settings.json` for the keys a provider is allowed
    /// to own. Read back so the "Import" action can capture a working setup in full.
    var extraEnv: [String: String]

    init(
        baseURL: String,
        model: String,
        hasAPIKey: Bool,
        maskedAPIKey: String,
        credential: ClaudeCredential = .apiKey,
        extraEnv: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.model = model
        self.hasAPIKey = hasAPIKey
        self.maskedAPIKey = maskedAPIKey
        self.credential = credential
        self.extraEnv = extraEnv
    }

    static let empty = ClaudeLiveSettings(baseURL: "", model: "", hasAPIKey: false, maskedAPIKey: L10n.Config.notSet)

    var hasOverlay: Bool { !baseURL.isEmpty || !model.isEmpty || hasAPIKey }
}

struct CodexProviderRecord: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var hasAPIKey: Bool
    var maskedAPIKey: String
    var isBuiltIn: Bool
}

struct CodexLiveSettings: Equatable, Sendable {
    var model: String
    var currentProviderID: String
    var providers: [CodexProviderRecord]

    static let official = CodexLiveSettings(
        model: "", currentProviderID: CodexTomlEditor.builtInOpenAI.id, providers: [CodexTomlEditor.builtInOpenAI]
    )
}

enum LiveConfigError: LocalizedError, Equatable, Sendable {
    case invalidProviderID
    case reservedProviderID
    case duplicateProviderID(String)
    case missingField(String)
    case missingCodexHome
    case missingModelCatalog(URL)
    case unparseableCodexConfig(line: Int)
    case unsupportedCodexLayout(String)
    case notUTF8(String)
    case libraryUnreadable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderID: L10n.Errors.invalidProviderID
        case .reservedProviderID: L10n.Errors.reservedProviderID
        case .duplicateProviderID(let id): L10n.Errors.duplicateProviderID(id)
        case .missingField(let name): L10n.Errors.missingField(name)
        case .missingCodexHome: L10n.Errors.missingCodexHome
        case .missingModelCatalog(let url): L10n.Errors.missingModelCatalog(url.path)
        case .unparseableCodexConfig(let line): L10n.Errors.unparseableCodexConfig(line: line)
        case .unsupportedCodexLayout(let id): L10n.Errors.unsupportedCodexLayout(id)
        case .notUTF8(let name): L10n.Errors.notUTF8(name)
        case .libraryUnreadable: L10n.Errors.libraryUnreadable
        case .writeFailed(let message): L10n.Errors.writeFailed(message)
        }
    }
}

enum SecretDisplay {
    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.Config.notSet }
        if trimmed.count <= 8 { return String(repeating: "•", count: min(trimmed.count, 4)) }
        return "••••\(trimmed.suffix(4))"
    }
}

enum ProviderIDRules {
    static let reservedCodexIDs: Set<String> = ["openai", "ollama", "lmstudio"]

    static func isValid(_ id: String) -> Bool {
        let pattern = #"^[A-Za-z][A-Za-z0-9_-]{0,31}$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }
}

struct LiveConfigPaths: Sendable {
    var claudeSettings: URL
    var codexConfig: URL
    /// The catalog AI Toolbox publishes for the active Codex provider, and the
    /// official catalog Codex downloaded for itself. The second is what supplies
    /// the system prompt every published entry has to carry, so both live beside
    /// the `config.toml` they belong to.
    var codexModelCatalog: URL
    var codexOfficialCatalog: URL

    var codexHome: URL { codexConfig.deletingLastPathComponent() }

    init(
        claudeSettings: URL,
        codexConfig: URL,
        codexModelCatalog: URL? = nil,
        codexOfficialCatalog: URL? = nil
    ) {
        let codexHome = codexConfig.deletingLastPathComponent()
        self.claudeSettings = claudeSettings
        self.codexConfig = codexConfig
        self.codexModelCatalog = codexModelCatalog ?? codexHome.appending(path: CodexModelCatalog.fileName)
        self.codexOfficialCatalog = codexOfficialCatalog ?? codexHome.appending(path: "models_cache.json")
    }

    static var `default`: LiveConfigPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LiveConfigPaths(
            claudeSettings: home.appending(path: ".claude/settings.json"),
            codexConfig: home.appending(path: ".codex/config.toml")
        )
    }
}

extension LiveConfigApp {
    var usageProvider: UsageProviderID {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }

    init?(usageProvider: UsageProviderID) {
        switch usageProvider {
        case .codex: self = .codex
        case .claude: self = .claude
        }
    }
}
