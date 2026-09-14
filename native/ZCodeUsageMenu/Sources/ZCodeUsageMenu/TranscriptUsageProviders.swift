import Foundation

struct CodexUsageProvider: UsageProvider {
    let id = UsageProviderID.codex
    let rootURL: URL
    private let now: @Sendable () -> Date

    init(rootURL: URL = UsageProviderID.codex.directory,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootURL = rootURL
        self.now = now
    }

    func load() throws -> UsageSnapshot {
        try TranscriptFiles.requireDirectory(rootURL, provider: id)
        let files = ["sessions", "archived_sessions"].flatMap {
            TranscriptFiles.recursiveJSONL(rootURL.appendingPathComponent($0))
        }.sorted { $0.path < $1.path }
        var collector = TranscriptCollector(provider: id, refreshedAt: now())
        let decoder = JSONDecoder()
        let dates = TranscriptDates()
        for file in files {
            // Only turn/model metadata survives this pass, never message bodies.
            var models: [String: String] = [:]
            _ = TranscriptJSONL.read(file) { line in
                guard try decoder.decode(TranscriptHeader.self, from: line).type == "turn_context" else { return }
                let context = try decoder.decode(CodexContext.self, from: line).payload
                if let turn = context.turn_id, let model = nonempty(context.model) { models[turn] = model }
            }
            collector.skipped += TranscriptJSONL.read(file) { line in
                guard try decoder.decode(TranscriptHeader.self, from: line).type == "token_usage_record" else { return }
                let record = try decoder.decode(CodexRecord.self, from: line)
                guard let response = nonempty(record.payload.response_id),
                      let usage = record.payload.usage, usage.hasMeasurements else {
                    throw TranscriptParseError.invalidRecord
                }
                collector.insert(key: TranscriptResponseID(message: response, request: nil),
                                 usage: usage,
                                 model: record.payload.turn_id.flatMap { models[$0] } ?? "unknown",
                                 date: dates.parse(record.timestamp))
            }
        }
        return try collector.snapshot(fileCount: files.count, cacheWriteLabel: "写入")
    }
}

struct ClaudeUsageProvider: UsageProvider {
    let id = UsageProviderID.claude
    /// The projects directory (normally ~/.claude/projects), not ~/.claude.
    let rootURL: URL
    private let now: @Sendable () -> Date

    init(rootURL: URL = UsageProviderID.claude.directory,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootURL = rootURL
        self.now = now
    }

    func load() throws -> UsageSnapshot {
        try TranscriptFiles.requireDirectory(rootURL, provider: id)
        var files: [URL] = []
        for project in TranscriptFiles.children(rootURL) where TranscriptFiles.isDirectory(project) {
            for entry in TranscriptFiles.children(project) {
                if TranscriptFiles.isJSONL(entry) { files.append(entry) }
                if TranscriptFiles.isDirectory(entry) {
                    let subagents = entry.appendingPathComponent("subagents")
                    files += TranscriptFiles.children(subagents).filter(TranscriptFiles.isJSONL)
                }
            }
        }
        files.sort { $0.path < $1.path }
        var collector = TranscriptCollector(provider: id, refreshedAt: now())
        let decoder = JSONDecoder()
        let dates = TranscriptDates()
        for file in files {
            collector.skipped += TranscriptJSONL.read(file) { line in
                guard try decoder.decode(TranscriptHeader.self, from: line).type == "assistant" else { return }
                let record = try decoder.decode(ClaudeRecord.self, from: line)
                guard let message = nonempty(record.message.id),
                      let usage = record.message.usage, usage.hasMeasurements else {
                    throw TranscriptParseError.invalidRecord
                }
                collector.insert(key: TranscriptResponseID(message: message, request: nonempty(record.requestId)),
                                 usage: usage, model: nonempty(record.message.model) ?? "unknown",
                                 date: dates.parse(record.timestamp))
            }
        }
        return try collector.snapshot(fileCount: files.count, cacheWriteLabel: "创建")
    }
}

/// Reads one bounded line at a time. Unterminated tails and over-limit lines are
/// counted once and skipped. Neither errors nor diagnostics contain file paths.
/// The callback must retain only IDs/metadata/usage, not the supplied line.
enum TranscriptJSONL {
    static func read(_ url: URL, maxLineBytes: Int = 1_048_576, chunkBytes: Int = 65_536,
                     consume: (Data) throws -> Void) -> Int {
        guard maxLineBytes > 0, chunkBytes > 0,
              TranscriptFiles.isJSONL(url),
              let handle = try? FileHandle(forReadingFrom: url) else { return 1 }
        defer { try? handle.close() }
        var line = Data()
        var oversized = false
        var skipped = 0
        do {
            while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let newline = chunk[start...].firstIndex(of: 10)
                    let end = newline ?? chunk.endIndex
                    if !oversized {
                        if end - start > maxLineBytes - line.count {
                            line.removeAll(keepingCapacity: true)
                            oversized = true
                        } else {
                            line.append(contentsOf: chunk[start..<end])
                        }
                    }
                    if let newline {
                        if oversized { skipped += 1 }
                        else if !line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) {
                            do { try consume(line) } catch { skipped += 1 }
                        }
                        line.removeAll(keepingCapacity: true)
                        oversized = false
                        start = newline + 1
                    } else { break }
                }
            }
            if oversized || !line.isEmpty { skipped += 1 }
        } catch { skipped += 1 }
        return skipped
    }
}

private enum TranscriptFiles {
    static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func isJSONL(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func requireDirectory(_ url: URL, provider: UsageProviderID) throws {
        guard isDirectory(url) else { throw ProviderReadError.missing(provider) }
    }

    static func children(_ url: URL) -> [URL] {
        guard isDirectory(url) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
    }

    static func recursiveJSONL(_ root: URL) -> [URL] {
        guard isDirectory(root) else { return [] }
        var pending = [root]
        var files: [URL] = []
        while let directory = pending.popLast() {
            for entry in children(directory) {
                if isDirectory(entry) { pending.append(entry) }
                else if isJSONL(entry) { files.append(entry) }
            }
        }
        return files
    }
}

private enum TranscriptParseError: Error { case invalidRecord }

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private struct TranscriptHeader: Decodable { let type: String? }
private struct CodexContext: Decodable {
    struct Payload: Decodable { let turn_id: String?; let model: String? }
    let payload: Payload
}
private struct CodexRecord: Decodable {
    struct Payload: Decodable {
        let response_id: String?
        let turn_id: String?
        let usage: TranscriptTokens?
    }
    let timestamp: String?
    let payload: Payload
}
private struct ClaudeRecord: Decodable {
    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: TranscriptTokens?
    }
    let timestamp: String?
    let requestId: String?
    let message: Message
}

/// Decode only measured counters. Message content and cumulative turn/thread
/// counters are deliberately absent from the decoding schema.
private struct TranscriptTokens: Decodable {
    let input: Int64?
    let output: Int64?
    let reasoning: Int64?
    let cacheRead: Int64?
    let cacheWrite: Int64?

    private enum CodingKeys: String, CodingKey {
        case input_tokens, output_tokens, reasoning_output_tokens
        case cache_read_input_tokens, cache_creation_input_tokens, cached_input_tokens
        case input_tokens_details, output_tokens_details, output_details
    }
    private struct InputDetails: Decodable { let cached_tokens: Int64? }
    private struct OutputDetails: Decodable { let reasoning_tokens: Int64?; let thinking_tokens: Int64? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int64.self, forKey: .input_tokens)
        output = try c.decodeIfPresent(Int64.self, forKey: .output_tokens)
        cacheRead = try c.decodeIfPresent(Int64.self, forKey: .cache_read_input_tokens)
            ?? c.decodeIfPresent(Int64.self, forKey: .cached_input_tokens)
            ?? c.decodeIfPresent(InputDetails.self, forKey: .input_tokens_details)?.cached_tokens
        cacheWrite = try c.decodeIfPresent(Int64.self, forKey: .cache_creation_input_tokens)
        reasoning = try c.decodeIfPresent(Int64.self, forKey: .reasoning_output_tokens)
            ?? c.decodeIfPresent(OutputDetails.self, forKey: .output_details)?.thinking_tokens
            ?? c.decodeIfPresent(OutputDetails.self, forKey: .output_tokens_details)?.reasoning_tokens
        guard [input, output, reasoning, cacheRead, cacheWrite].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw TranscriptParseError.invalidRecord
        }
    }

    var metrics: Set<UsageMetric> {
        var result: Set<UsageMetric> = []
        if input != nil { result.insert(.input) }
        if output != nil { result.insert(.output) }
        if reasoning != nil { result.insert(.reasoning) }
        if cacheRead != nil { result.insert(.cacheRead) }
        if cacheWrite != nil { result.insert(.cacheWrite) }
        return result
    }
    var hasMeasurements: Bool { !metrics.isEmpty }
}

private final class TranscriptDates {
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

private struct TranscriptResponseID: Hashable {
    let message: String
    let request: String?
}
private struct TranscriptSample {
    let usage: TranscriptTokens
    let model: String
    let date: Date?
}

private func addingTokens(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : sum
}

private struct TranscriptCounters {
    var requests: Int64 = 0
    var input: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0

    mutating func add(_ tokens: TranscriptTokens) {
        requests = addingTokens(requests, 1)
        input = addingTokens(input, tokens.input ?? 0)
        output = addingTokens(output, tokens.output ?? 0)
        reasoning = addingTokens(reasoning, tokens.reasoning ?? 0)
        cacheRead = addingTokens(cacheRead, tokens.cacheRead ?? 0)
        cacheWrite = addingTokens(cacheWrite, tokens.cacheWrite ?? 0)
    }
    var totals: UsageTotals {
        UsageTotals(turns: 0, requests: requests, inputTokens: input, outputTokens: output,
                    reasoningTokens: reasoning, cacheReadInputTokens: cacheRead,
                    cacheCreationInputTokens: cacheWrite, toolCalls: 0)
    }
}

private struct TranscriptCollector {
    let provider: UsageProviderID
    let refreshedAt: Date
    var skipped = 0
    private var responses: [TranscriptResponseID: TranscriptSample] = [:]

    init(provider: UsageProviderID, refreshedAt: Date) {
        self.provider = provider
        self.refreshedAt = refreshedAt
    }

    mutating func insert(key: TranscriptResponseID, usage: TranscriptTokens, model: String, date: Date?) {
        // Timestamps order copies across files/archives. Ties or missing dates
        // use the last occurrence in deterministic file/line order.
        if let oldDate = responses[key]?.date, let date, date < oldDate { return }
        responses[key] = TranscriptSample(usage: usage, model: model, date: date)
    }

    func snapshot(fileCount: Int, cacheWriteLabel: String) throws -> UsageSnapshot {
        guard !responses.isEmpty else {
            if skipped > 0 { throw ProviderReadError.incompatible(provider) }
            throw ProviderReadError.noRecords(provider)
        }
        var total = TranscriptCounters()
        var today = TranscriptCounters()
        var byModel: [String: TranscriptCounters] = [:]
        var metrics: Set<UsageMetric>?
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: refreshedAt)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var undated = false
        for sample in responses.values {
            total.add(sample.usage)
            byModel[sample.model, default: TranscriptCounters()].add(sample.usage)
            metrics = metrics.map { $0.intersection(sample.usage.metrics) } ?? sample.usage.metrics
            if let date = sample.date {
                if date >= start && date < end { today.add(sample.usage) }
            } else { undated = true }
        }
        var measured = metrics ?? []
        measured.insert(.requests)
        let models: [ModelUsage] = byModel.map { model, counters in
            ModelUsage(modelID: model, providerID: provider.rawValue,
                       requests: counters.requests, outputTokens: counters.output)
        }
        let sortedModels = models.sorted { lhs, rhs in
            if lhs.outputTokens == rhs.outputTokens { return lhs.modelID < rhs.modelID }
            return lhs.outputTokens > rhs.outputTokens
        }
        var note = "本地会话已记录用量；非账单或额度；仅展示记录完整的指标"
        if undated { note += "；无有效时间的记录不计入今日" }
        return UsageSnapshot(refreshedAt: refreshedAt, totals: total.totals, today: today.totals, models: sortedModels,
                             coverage: .transcripts(note: note, fileCount: fileCount,
                                                    skippedRecords: skipped, metrics: measured,
                                                    cacheWriteLabel: cacheWriteLabel))
    }
}
