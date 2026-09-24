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

    /// The directory the transcripts are read from. Codex keeps them in two trees
    /// under its home, Claude Code in one per-project tree.
    var directory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .codex: return home.appending(path: ".codex")
        case .claude: return home.appending(path: ".claude/projects")
        }
    }
}

/// The counters a log format may or may not report. Everything else is always
/// present in a valid record, so only these can be shown as "—".
enum UsageMetric: String, CaseIterable, Hashable, Sendable {
    case cacheRead, cacheWrite, reasoning
}

struct UsageCoverage: Equatable, Sendable {
    var fileCount = 0
    /// Usage records that were present but could not be read.
    var skippedRecords = 0
    /// Usage records without a usable timestamp: counted in the lifetime totals, but
    /// in no day.
    var undatedRecords = 0
    /// Metrics at least one record reported. A metric no record reports is unknown,
    /// which is not the same as zero.
    var reported: Set<UsageMetric> = Set(UsageMetric.allCases)

    var isPartial: Bool { skippedRecords > 0 || undatedRecords > 0 }
}

protocol UsageProvider: Sendable {
    var id: UsageProviderID { get }
    func load() throws -> UsageSnapshot
}

enum ProviderReadError: LocalizedError, Equatable, Sendable {
    case missing(UsageProviderID)
    case noRecords(UsageProviderID)
    case incompatible(UsageProviderID)

    var errorDescription: String? {
        switch self {
        case .missing(let id): "未找到 \(id.title) 的本地记录目录。用它完成一次对话后，这里就会有数据。"
        case .noRecords(let id): "\(id.title) 的记录目录存在，但还没有可识别的用量记录。"
        case .incompatible(let id): "\(id.title) 的记录无法解析，可能是日志格式有变化。"
        }
    }
}

struct ProviderState: Sendable {
    var snapshot: UsageSnapshot?
    var errorMessage: String?
    var isRefreshing = false
}
