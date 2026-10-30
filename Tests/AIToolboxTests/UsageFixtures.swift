import Foundation

@testable import AIToolbox

/// Synthetic usage shared by the layout tests and the documentation renders, so the
/// screenshots show exactly the layout the tests measure.
enum UsageFixtures {
    /// A week of plausible agentic use ending on `date`: most input served from cache,
    /// output a small fraction of input, a quiet day in the middle.
    static func snapshot(at date: Date, scale: Double = 1, models: Int = 3) -> UsageSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let outputs: [Int64] = [182_000, 96_000, 0, 241_000, 158_000, 305_000, 127_000]
        var daily: [DailyUsage] = []
        var totals = UsageTotals()
        for (offset, output) in outputs.enumerated() {
            let day = calendar.date(byAdding: .day, value: offset - outputs.count + 1, to: today)!
            let out = Int64(Double(output) * scale)
            guard out > 0 else { continue }
            let input = out * 38
            let day_totals = UsageTotals(
                requests: out / 1_400, turns: out / 9_000, toolCalls: out / 1_900,
                inputTokens: input, cacheReadTokens: input * 86 / 100, cacheWriteTokens: input * 4 / 100,
                outputTokens: out, reasoningTokens: out * 3 / 10
            )
            daily.append(DailyUsage(date: day, totals: day_totals))
            totals.requests += day_totals.requests
            totals.turns += day_totals.turns
            totals.toolCalls += day_totals.toolCalls
            totals.inputTokens += day_totals.inputTokens
            totals.cacheReadTokens += day_totals.cacheReadTokens
            totals.cacheWriteTokens += day_totals.cacheWriteTokens
            totals.outputTokens += day_totals.outputTokens
            totals.reasoningTokens += day_totals.reasoningTokens
        }
        // Earlier history, so the lifetime card is not just the week.
        let first = calendar.date(byAdding: .day, value: -41, to: today)!
        let history = UsageTotals(
            requests: 2_310, turns: 402, toolCalls: 1_780, inputTokens: 118_000_000,
            cacheReadTokens: 101_000_000, cacheWriteTokens: 4_300_000,
            outputTokens: 3_050_000, reasoningTokens: 910_000)
        daily.insert(DailyUsage(date: first, totals: history), at: 0)
        totals.requests += history.requests
        totals.turns += history.turns
        totals.toolCalls += history.toolCalls
        totals.inputTokens += history.inputTokens
        totals.cacheReadTokens += history.cacheReadTokens
        totals.cacheWriteTokens += history.cacheWriteTokens
        totals.outputTokens += history.outputTokens
        totals.reasoningTokens += history.reasoningTokens

        let names = ["model-alpha", "model-beta", "model-gamma", "model-delta", "model-epsilon"]
        let shares = [0.62, 0.27, 0.08, 0.02, 0.01]
        let rows = (0..<min(models, names.count)).map { index in
            ModelUsage(
                modelID: names[index],
                requests: Int64(Double(totals.requests) * shares[index]),
                inputTokens: Int64(Double(totals.inputTokens) * shares[index]),
                outputTokens: Int64(Double(totals.outputTokens) * shares[index]))
        }
        return UsageSnapshot(
            refreshedAt: date, totals: totals, daily: daily, models: rows,
            coverage: UsageCoverage(fileCount: 48))
    }
}

struct FixtureProvider: UsageProvider {
    let id: UsageProviderID
    let snapshot: UsageSnapshot?
    func load() throws -> UsageSnapshot {
        guard let snapshot else { throw ProviderReadError.noRecords(id) }
        return snapshot
    }
}
