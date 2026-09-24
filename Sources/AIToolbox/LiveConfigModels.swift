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
        case .apiKey: "API Key"
        case .authToken: "Auth Token"
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
    /// to own. Read back so "导入当前配置" can capture a working setup in full.
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

    static let empty = ClaudeLiveSettings(baseURL: "", model: "", hasAPIKey: false, maskedAPIKey: "未设置")

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
        case .invalidProviderID: "供应商 ID 只能使用英文字母、数字、连字符和下划线，以字母开头，最长 32 个字符。"
        case .reservedProviderID: "openai、ollama、lmstudio 是 Codex 内置 ID，不能用作自定义供应商。"
        case .duplicateProviderID(let id): "已存在 ID 为 \(id) 的供应商。"
        case .missingField(let name): "请填写\(name)。"
        case .missingCodexHome: "未找到 ~/.codex 目录。请先运行一次 Codex，再回来切换供应商。"
        case .missingModelCatalog(let url):
            "Codex 还没有下载官方模型目录（\(url.path)）。目录条目必须自带系统指令，"
                + "所以这次没有把模型发布到 Codex 的模型列表；用官方登录运行一次 Codex 后重新切换即可。"
        case .unparseableCodexConfig(let line):
            "~/.codex/config.toml 第 \(line) 行有无法解析的内容。为避免破坏配置，没有做任何修改。"
        case .unsupportedCodexLayout(let id):
            "config.toml 里的 \(id) 供应商不是用独立的 [model_providers.\(id)] 表定义的"
                + "（例如写成了内联表或点号键）。为避免产生重复定义，没有修改它。"
        case .notUTF8(let name): "\(name) 不是 UTF-8 文本，没有做任何修改。"
        case .libraryUnreadable: "供应商库无法读取。为避免覆盖其中的内容，暂停保存供应商。"
        case .writeFailed(let message): "写入配置失败：\(message)"
        }
    }
}

enum SecretDisplay {
    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未设置" }
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
    /// The catalog AI 工具台 publishes for the active Codex provider, and the
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
