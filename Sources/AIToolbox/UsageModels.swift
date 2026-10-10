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
    /// A token count in the interface language's own large-number units.
    ///
    /// Chinese groups large numbers by 万 (10⁴) and 亿 (10⁸), not by thousands, so
    /// 127,000 reads 12.7万 rather than 127k. Below 万 the number is shown in full.
    /// Compact values keep three significant digits, the same precision the panel
    /// has always shown; the exact count is in the tooltip and the VoiceOver label.
    static func token(_ value: Int64) -> String {
        let magnitude = value.magnitude
        guard magnitude >= 10_000 else { return exact(value) }
        let sign = value < 0 ? "-" : ""
        // Each tier keeps three significant digits. Rounding can carry a value into
        // the next tier (99,995 is 10.0万, not 10.00万), so the tier is chosen from the
        // rounded value rather than the raw one.
        let tiers: [(divisor: Double, unit: String)] = [(1e4, "万"), (1e8, "亿")]
        for (index, tier) in tiers.enumerated() {
            let scaled = Double(magnitude) / tier.divisor
            let isLast = index == tiers.count - 1
            if !isLast, scaled >= 9_999.5 { continue }
            let digits = scaled < 9.995 ? 2 : scaled < 99.95 ? 1 : 0
            return sign + String(format: "%.\(digits)f", locale: posix, scaled) + tier.unit
        }
        return exact(value)
    }

    /// A count of things (requests, turns, tool calls): exact below 万, compact above.
    static func count(_ value: Int64) -> String {
        value.magnitude >= 10_000 ? token(value) : exact(value)
    }

    /// The full number with digit grouping, for tooltips and VoiceOver.
    static func exact(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic).locale(locale))
    }

    static var locale: Locale { L10n.locale }

    /// Decimal separators inside compact numbers are always ".", which zh-Hans also
    /// uses; `String(format:)` would otherwise follow the process locale.
    private static let posix = Locale(identifier: "en_US_POSIX")

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
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }
}
