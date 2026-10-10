import Foundation

/// Token and activity counters for one period.
///
/// `inputTokens` is the **whole prompt**, cached part included, for both tools. The
/// two logs disagree on this — Codex reports the whole prompt and marks the cached
/// share inside it, Claude Code reports only the uncached part and lists the cache
/// separately — so the readers normalise to one meaning before anything is added up.
/// Without that, the same "Input" number would mean different things in the two tabs.
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
    /// English groups large numbers by thousands, so 127,000 reads 127K. Below
    /// 10,000 the number is shown in full — the cutoff is deliberately not lowered
    /// to 1,000: that would put four-digit values on the three-significant-digit
    /// rule below, and 9,999 would read "10.0K", a real 9,999 shown as if it were
    /// 10,000. The exact count is in the tooltip and the VoiceOver label anyway.
    /// Compact values keep three significant digits, the same precision the panel
    /// has always shown.
    static func token(_ value: Int64) -> String {
        let magnitude = value.magnitude
        guard magnitude >= 10_000 else { return exact(value) }
        let sign = value < 0 ? "-" : ""
        // Each tier keeps three significant digits. Rounding can carry a value into
        // the next tier (999,500 is 1.00M, not 1000K), so the tier is chosen from the
        // rounded value rather than the raw one. The last tier has nothing above it,
        // so a large enough value keeps its digits instead of carrying (1e15 is
        // 1000T); that wart predates this tier set and is left as it is.
        let tiers: [(divisor: Double, unit: String)] = [(1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T")]
        for (index, tier) in tiers.enumerated() {
            let scaled = Double(magnitude) / tier.divisor
            let isLast = index == tiers.count - 1
            if !isLast, scaled >= 999.5 { continue }
            let digits = scaled < 9.995 ? 2 : scaled < 99.95 ? 1 : 0
            return sign + String(format: "%.\(digits)f", locale: posix, scaled) + tier.unit
        }
        return exact(value)
    }

    /// A count of things (requests, turns, tool calls): exact below 10,000, compact
    /// above. The threshold matches `token`'s, so the two agree on where compacting
    /// starts.
    static func count(_ value: Int64) -> String {
        value.magnitude >= 10_000 ? token(value) : exact(value)
    }

    /// The full number with digit grouping, for tooltips and VoiceOver.
    static func exact(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic).locale(locale))
    }

    static var locale: Locale { L10n.locale }

    /// Decimal separators inside compact numbers are always ".", so a region that
    /// writes decimals with a comma cannot turn 1.5K into 1,5K; `String(format:)`
    /// would otherwise follow the process locale.
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The day-of-week label over a trend column. `.short` (Tu) rather than
    /// `.narrow` (T): an English narrow form is ambiguous — T is both Tuesday and
    /// Thursday, S both Saturday and Sunday — and the columns are far wider than
    /// the numbers above the bars, so the extra character costs nothing.
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.short).locale(locale))
    }

    /// Drawn in pixel type beside the lifetime card's title, so it goes through
    /// `pixelSpaced` too; `monthDay` below never reaches the pixel font, so it does
    /// not need to.
    static func day(_ date: Date) -> String {
        pixelSpaced(date.formatted(.dateTime.year().month().day().locale(locale)))
    }

    static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(locale))
    }

    /// Drawn in pixel type in the panel header, so it is passed through
    /// `pixelSpaced` first.
    static func time(_ date: Date, withDate: Bool) -> String {
        pixelSpaced(
            withDate
                ? date.formatted(.dateTime.month().day().hour().minute().locale(locale))
                : date.formatted(.dateTime.hour().minute().locale(locale)))
    }

    /// Replaces the no-break spaces Foundation puts in an English time — the narrow
    /// no-break space (U+202F) before "PM", or a plain no-break space (U+00A0) on
    /// older systems — with ordinary spaces. The pixel font draws a plain space but
    /// neither no-break variant, so without this the header stamp would fall back to
    /// the system font for that one character and the word spacing would change
    /// mid-line.
    private static func pixelSpaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }
}
