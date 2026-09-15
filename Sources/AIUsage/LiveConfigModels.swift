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

struct ClaudeLiveSettings: Equatable, Sendable {
    var baseURL: String
    var model: String
    var hasAPIKey: Bool
    var maskedAPIKey: String
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
}

enum LiveConfigError: LocalizedError, Equatable, Sendable {
    case invalidProviderID
    case reservedProviderID
    case duplicateProviderID(String)
    case missingField(String)
    case missingFile(URL)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderID: "供应商 ID 只能使用字母、数字、连字符和下划线，并以字母开头。"
        case .reservedProviderID: "openai、ollama、lmstudio 是 Codex 内置 ID，不能用作自定义供应商。"
        case .duplicateProviderID(let id): "已存在 ID 为 \(id) 的供应商。"
        case .missingField(let name): "请填写\(name)。"
        case .missingFile(let url): "找不到配置文件：\(url.path)"
        case .writeFailed(let message): "写入配置失败：\(message)"
        }
    }
}

enum SecretDisplay {
    static func mask(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未设置" }
        if trimmed.count <= 4 { return String(repeating: "•", count: trimmed.count) }
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
