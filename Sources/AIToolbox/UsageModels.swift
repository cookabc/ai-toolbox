import Foundation

/// Token and activity counters for one period.
///
/// `inputTokens` is the **whole prompt**, cached part included, for both tools. The
/// two logs disagree on this — Codex reports the whole prompt and marks the cached
/// share inside it, Claude Code reports only the uncached part and lists the cache
/// separately — so the readers normalise to one meaning before anything is added up.
/// Without that, the same "输入" number would mean different things in the two tabs.
struct UsageTotals: Equatable, Sendable {
    var requests: Int64 = 0
    var turns: Int64 = 0
    var toolCalls: Int64 = 0
    var inputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var outputTokens: Int64 = 0
    /// Part of `outputTokens`, not in addition to it.
    var reasoningTokens: Int64 = 0

    static let zero = UsageTotals()

    var freshInputTokens: Int64 {
        max(0, inputTokens - cacheReadTokens - cacheWriteTokens)
    }

    var cacheReadShare: Double { share(cacheReadTokens) }

    var cacheWriteShare: Double {
        guard inputTokens > 0 else { return 0 }
        return min(1 - cacheReadShare, share(cacheWriteTokens))
    }

    var freshInputShare: Double {
        guard inputTokens > 0 else { return 0 }
        return max(0, 1 - cacheReadShare - cacheWriteShare)
    }

    private func share(_ part: Int64) -> Double {
        guard inputTokens > 0 else { return 0 }
        return min(1, max(0, Double(part) / Double(inputTokens)))
    }
}

struct ModelUsage: Equatable, Identifiable, Sendable {
    let modelID: String
    let requests: Int64
    let inputTokens: Int64
    let outputTokens: Int64

    var id: String { modelID }
}

struct DailyUsage: Equatable, Sendable {
    /// Local midnight that starts the day.
    let date: Date
    let totals: UsageTotals
}

struct UsageSnapshot: Equatable, Sendable {
    var refreshedAt: Date
    var totals: UsageTotals
    /// One entry per local day that has activity, oldest first.
    var daily: [DailyUsage]
    var models: [ModelUsage]
    var coverage = UsageCoverage()

    static let empty = UsageSnapshot(refreshedAt: .now, totals: .zero, daily: [], models: [])

    /// Activity on the local day containing `date`. Computed from the per-day buckets
    /// rather than stored, so "today" stays right across midnight even before the next
    /// read finishes.
    func totals(on date: Date, calendar: Calendar = .current) -> UsageTotals {
        let start = calendar.startOfDay(for: date)
        return daily.last { $0.date == start }?.totals ?? .zero
    }

    /// The last `count` days ending with the day containing `date`, oldest first, with
    /// empty days filled in so a chart has one bar per day.
    func recentDays(_ count: Int, endingAt date: Date, calendar: Calendar = .current) -> [DailyUsage] {
        let end = calendar.startOfDay(for: date)
        let byDate = Dictionary(daily.map { ($0.date, $0.totals) }, uniquingKeysWith: { $1 })
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            return DailyUsage(date: day, totals: byDate[day] ?? .zero)
        }
    }

    var firstActiveDay: Date? { daily.first?.date }
}

enum Format {
    static func token(_ value: Int64) -> String {
        let number = Double(value)
        if abs(number) >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if abs(number) >= 10_000_000 { return String(format: "%.0fM", number / 1_000_000) }
        if abs(number) >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if abs(number) >= 10_000 { return String(format: "%.0fk", number / 1_000) }
        if abs(number) >= 1_000 { return String(format: "%.1fk", number / 1_000) }
        return "\(value)"
    }

    static func count(_ value: Int64) -> String {
        value >= 10_000 ? token(value) : value.formatted(.number.grouping(.automatic).locale(locale))
    }

    /// The interface is written in Chinese, so its dates are too, whatever the
    /// system region: "Aug 4, 2026" in the middle of Chinese text reads as a bug.
    static let locale = Locale(identifier: "zh_CN")

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.narrow).locale(locale))
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(locale))
    }

    static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(locale))
    }

    static func time(_ date: Date, withDate: Bool) -> String {
        withDate
            ? date.formatted(.dateTime.month().day().hour().minute().locale(locale))
            : date.formatted(.dateTime.hour().minute().locale(locale))
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
