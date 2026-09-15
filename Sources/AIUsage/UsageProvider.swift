import Foundation

enum UsageProviderID: String, CaseIterable, Identifiable, Sendable {
    case codex, claude

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .codex: return home.appending(path: ".codex")
        case .claude: return home.appending(path: ".claude/projects")
        }
    }
}

enum UsageMetric: String, CaseIterable, Hashable, Sendable {
    case turns, requests, input, output, reasoning, cacheRead, cacheWrite, tools
}

struct UsageCoverage: Equatable, Sendable {
    var metrics: Set<UsageMetric> = Set(UsageMetric.allCases)
    var note: String = "本地用量记录；非账单或额度"
    var fileCount: Int = 0
    var skippedRecords: Int = 0
    var cacheWriteLabel: String = "创建"
    var supportsInputComposition: Bool = true
    var todayMetrics: Set<UsageMetric>?
    var hasUndatedRecords: Bool = false

    var isPartial: Bool { skippedRecords > 0 || hasUndatedRecords }

    static func transcripts(note: String, fileCount: Int, skippedRecords: Int = 0,
                            metrics: Set<UsageMetric>, cacheWriteLabel: String) -> UsageCoverage {
        UsageCoverage(metrics: metrics, note: note, fileCount: fileCount,
                      skippedRecords: skippedRecords, cacheWriteLabel: cacheWriteLabel,
                      supportsInputComposition: false)
    }
}

protocol UsageProvider: Sendable {
    var id: UsageProviderID { get }
    func load() throws -> UsageSnapshot
}

enum ProviderReadError: LocalizedError, Sendable {
    case missing(UsageProviderID)
    case noRecords(UsageProviderID)
    case incompatible(UsageProviderID)

    var errorDescription: String? {
        switch self {
        case .missing(let id): "未检测到 \(id.title) 的本地记录目录（不代表工具未安装）。"
        case .noRecords(let id): "\(id.title) 目录存在，尚无可识别的用量记录。"
        case .incompatible(let id): "\(id.title) 的记录无法解析或格式暂不支持。"
        }
    }
}

struct ProviderState: Sendable {
    var snapshot: UsageSnapshot?
    var errorMessage: String?
    var isRefreshing = false
}
