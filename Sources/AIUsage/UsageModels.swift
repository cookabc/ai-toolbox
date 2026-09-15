import Foundation

struct UsageTotals: Equatable, Sendable {
    let turns: Int64
    let requests: Int64
    let inputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let cacheReadInputTokens: Int64
    let cacheCreationInputTokens: Int64
    let toolCalls: Int64

    static let zero = UsageTotals(
        turns: 0, requests: 0, inputTokens: 0, outputTokens: 0,
        reasoningTokens: 0, cacheReadInputTokens: 0,
        cacheCreationInputTokens: 0, toolCalls: 0
    )

    var freshInputTokens: Int64 {
        max(0, inputTokens - cacheReadInputTokens - cacheCreationInputTokens)
    }

    var cacheReadShare: Double {
        guard inputTokens > 0 else { return 0 }
        return min(1, max(0, Double(cacheReadInputTokens) / Double(inputTokens)))
    }

    var cacheCreationShare: Double {
        guard inputTokens > 0 else { return 0 }
        return min(1 - cacheReadShare, max(0, Double(cacheCreationInputTokens) / Double(inputTokens)))
    }

    var freshInputShare: Double {
        guard inputTokens > 0 else { return 0 }
        return 1 - cacheReadShare - cacheCreationShare
    }
}

struct ModelUsage: Equatable, Identifiable, Sendable {
    let modelID: String
    let providerID: String
    let requests: Int64
    let outputTokens: Int64

    var id: String { "\(providerID):\(modelID)" }
}

struct UsageSnapshot: Equatable, Sendable {
    let refreshedAt: Date
    let totals: UsageTotals
    let today: UsageTotals
    let models: [ModelUsage]
    var coverage = UsageCoverage()

    static let empty = UsageSnapshot(
        refreshedAt: .now, totals: .zero, today: .zero, models: []
    )
}

enum UsageError: LocalizedError, Equatable, Sendable {
    case query(String)

    var errorDescription: String? {
        switch self {
        case .query(let message): message
        }
    }
}

enum Format {
    static func token(_ value: Int64) -> String {
        let number = Double(value)
        if abs(number) >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if abs(number) >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if abs(number) >= 1_000 { return String(format: "%.0fk", number / 1_000) }
        return "\(value)"
    }

    static func count(_ value: Int64) -> String {
        value >= 10_000 ? "\(value / 1_000)k" : "\(value)"
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func cost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
