import Foundation

/// Token counters from one usage record, already normalised to the meaning
/// `UsageTotals` documents: `input` is the whole prompt, cache included, and
/// `reasoning` is part of `output`.
struct TranscriptTokens: Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var reasoning: Int64 = 0
    /// Which optional counters the record actually carried. A bit mask rather than a
    /// `Set`, because there is one of these per response in the whole history.
    var reportedMask: UInt8 = 0

    var reported: Set<UsageMetric> {
        Set(UsageMetric.allCases.enumerated().compactMap { index, metric in
            reportedMask & (1 << index) != 0 ? metric : nil
        })
    }

    mutating func report(_ metric: UsageMetric) {
        let index = UsageMetric.allCases.firstIndex(of: metric)!
        reportedMask |= 1 << index
    }
}

/// Turns one JSONL line into records. Every line is decoded at most once, and only
/// lines whose bytes could matter are decoded at all: most of a transcript is
/// message bodies and tool output, which never need to become Swift values.
struct TranscriptLineParser {
    let format: UsageProviderID
    private let decoder = JSONDecoder()
    private let dates = TranscriptDates()
    /// Model names repeat on every record; share one string per name.
    private var modelNames: [String: String] = [:]

    init(format: UsageProviderID) {
        self.format = format
    }

    /// Cheap byte test run before decoding. False positives only cost a decode.
    static func mayMatter(_ line: UnsafeRawBufferPointer, format: UsageProviderID) -> Bool {
        switch format {
        case .codex:
            Self.contains(line, Self.codexUsage) || Self.contains(line, Self.codexTurn)
                || Self.contains(line, Self.codexCall)
        case .claude:
            Self.contains(line, Self.claudeAssistant) || Self.contains(line, Self.claudeUser)
        }
    }

    /// Whether an unreadable line was probably a usage record, i.e. whether losing
    /// it means the totals are incomplete.
    static func mentionsUsage(_ line: UnsafeRawBufferPointer, format: UsageProviderID) -> Bool {
        contains(line, format == .codex ? codexUsage : claudeAssistant)
    }

    mutating func consume(_ line: Data, into records: inout TranscriptRecords) throws {
        switch format {
        case .codex: try consumeCodex(line, into: &records)
        case .claude: try consumeClaude(line, into: &records)
        }
    }

    // MARK: Codex

    private mutating func consumeCodex(_ line: Data, into records: inout TranscriptRecords) throws {
        let record = try decoder.decode(CodexLine.self, from: line)
        let date = dates.parse(record.timestamp)
        switch record.type {
        case "token_usage_record":
            guard let payload = record.payload, let response = nonempty(payload.response_id),
                  let usage = payload.usage else { throw TranscriptParseError.invalidRecord }
            let tokens = try usage.codexTokens()
            records.insert(TranscriptKey(message: response, request: nil), TranscriptSample(
                tokens: tokens, model: nil, turnID: nonempty(payload.turn_id), date: date
            ))
            if let turn = nonempty(payload.turn_id) { records.noteTurn(turn, at: date) }
        case "turn_context":
            guard let payload = record.payload, let turn = nonempty(payload.turn_id) else { return }
            records.noteTurn(turn, at: date)
            if let model = nonempty(payload.model) { records.turnModels[turn] = intern(model) }
        case "response_item":
            guard let payload = record.payload, let type = payload.type,
                  type.hasSuffix("_call"),
                  let call = nonempty(payload.call_id) ?? nonempty(payload.id) else { return }
            records.noteTool(call, at: date)
        default:
            return
        }
    }

    // MARK: Claude Code

    private mutating func consumeClaude(_ line: Data, into records: inout TranscriptRecords) throws {
        let record = try decoder.decode(ClaudeLine.self, from: line)
        let date = dates.parse(record.timestamp)
        switch record.type {
        case "assistant":
            guard let message = record.message, let id = nonempty(message.id),
                  let usage = message.usage else { throw TranscriptParseError.invalidRecord }
            // Written by Claude Code itself for errors and interruptions; no request
            // reached a model.
            if message.model == "<synthetic>" { return }
            records.insert(TranscriptKey(message: id, request: nonempty(record.requestId)), TranscriptSample(
                tokens: try usage.claudeTokens(), model: nonempty(message.model).map { intern($0) },
                turnID: nil, date: date
            ))
            for tool in message.toolUseIDs { records.noteTool(tool, at: date) }
        case "user":
            // A turn is one prompt the model answers: typed text or a notification it
            // is asked to act on. Tool results, meta records and local slash commands
            // share the prompt's ID or never reach the model, so they are not turns.
            guard record.isSidechain != true, record.isMeta != true,
                  let message = record.message, message.startsTurn,
                  let turn = nonempty(record.promptId) ?? nonempty(record.uuid) else { return }
            records.noteTurn(turn, at: date)
        default:
            return
        }
    }

    private mutating func intern(_ name: String) -> String {
        if let shared = modelNames[name] { return shared }
        modelNames[name] = name
        return name
    }

    // MARK: Byte markers

    private static let codexUsage = Array("token_usage_record".utf8)
    private static let codexTurn = Array("\"turn_context\"".utf8)
    private static let codexCall = Array("_call\"".utf8)
    private static let claudeAssistant = Array("\"assistant\"".utf8)
    private static let claudeUser = Array("\"user\"".utf8)

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress!, needle.count) != nil }
    }
}

extension TranscriptRecords {
    mutating func insert(_ key: TranscriptKey, _ sample: TranscriptSample) {
        if let existing = samples[key], !sample.shouldReplace(existing) { return }
        samples[key] = sample
    }

    mutating func noteTurn(_ id: String, at date: Date?) {
        Self.note(id, at: date, in: &turns)
    }

    mutating func noteTool(_ id: String, at date: Date?) {
        Self.note(id, at: date, in: &tools)
    }

    /// Keeps the earliest known time for each ID; an ID seen without a time keeps
    /// the time it is later seen with.
    private static func note(_ id: String, at date: Date?, in table: inout [String: Date?]) {
        guard let existing = table[id] else {
            table[id] = .some(date)
            return
        }
        switch (existing, date) {
        case (nil, let date?): table[id] = .some(date)
        case (let old?, let date?) where date < old: table[id] = .some(date)
        default: break
        }
    }
}

enum TranscriptParseError: Error { case invalidRecord }

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

// MARK: - Decoding schemas

/// Each field is decoded leniently: a transcript line is only as useful as the
/// fields this reader needs, and an unexpected shape elsewhere in it must not throw
/// the line away. `usage` is the exception — see `RawUsage`.
private struct CodexLine: Decodable {
    let type: String?
    let timestamp: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        let turn_id: String?
        let model: String?
        let response_id: String?
        let call_id: String?
        let id: String?
        let usage: RawUsage?

        private enum CodingKeys: String, CodingKey {
            case type, turn_id, model, response_id, call_id, id, usage
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            turn_id = try? c.decodeIfPresent(String.self, forKey: .turn_id)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            response_id = try? c.decodeIfPresent(String.self, forKey: .response_id)
            call_id = try? c.decodeIfPresent(String.self, forKey: .call_id)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            usage = try c.decodeIfPresent(RawUsage.self, forKey: .usage)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, timestamp, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        // Only a usage record's payload is allowed to fail the line.
        if type == "token_usage_record" {
            payload = try c.decodeIfPresent(Payload.self, forKey: .payload)
        } else {
            payload = try? c.decodeIfPresent(Payload.self, forKey: .payload)
        }
    }
}

private struct ClaudeLine: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let promptId: String?
    let uuid: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: RawUsage?
        let toolUseIDs: [String]
        let startsTurn: Bool

        private enum CodingKeys: String, CodingKey { case id, model, usage, content, role }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let role = try? c.decodeIfPresent(String.self, forKey: .role)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            if role == "assistant" {
                usage = try c.decodeIfPresent(RawUsage.self, forKey: .usage)
                let blocks = (try? c.decodeIfPresent([AssistantBlock].self, forKey: .content)) ?? nil
                toolUseIDs = blocks?.compactMap { block in
                    guard block.type == "tool_use" || block.type == "server_tool_use" else { return nil }
                    return block.id
                } ?? []
                startsTurn = false
            } else {
                usage = nil
                toolUseIDs = []
                if let text = try? c.decodeIfPresent(String.self, forKey: .content) {
                    startsTurn = Self.isPrompt(text)
                } else if let blocks = try? c.decodeIfPresent([UserBlock].self, forKey: .content) {
                    startsTurn = blocks.contains { $0.type == "text" && Self.isPrompt($0.text ?? "") }
                        || blocks.contains { $0.type == "image" }
                } else {
                    startsTurn = false
                }
            }
        }

        /// Local slash commands are echoed into the transcript but never sent.
        private static func isPrompt(_ text: String) -> Bool {
            let trimmed = text.drop { $0.isWhitespace }
            guard !trimmed.isEmpty else { return false }
            return !(trimmed.hasPrefix("<local-command-") || trimmed.hasPrefix("<command-name>")
                || trimmed.hasPrefix("<command-message>"))
        }
    }

    private struct AssistantBlock: Decodable {
        let type: String?
        let id: String?
    }

    private struct UserBlock: Decodable {
        let type: String?
        let text: String?
    }

    private enum CodingKeys: String, CodingKey {
        case type, timestamp, requestId, promptId, uuid, isSidechain, isMeta, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
        promptId = try? c.decodeIfPresent(String.self, forKey: .promptId)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        isMeta = try? c.decodeIfPresent(Bool.self, forKey: .isMeta)
        if type == "assistant" {
            message = try c.decodeIfPresent(Message.self, forKey: .message)
        } else if type == "user" {
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
        } else {
            message = nil
        }
    }
}

/// The counters exactly as a record writes them. Strict on purpose: a negative,
/// fractional or overflowing counter means the record cannot be trusted, and a
/// skipped record is reported as partial data rather than quietly miscounted.
/// Cumulative per-turn and per-thread totals live in sibling fields and are
/// deliberately not part of this schema.
private struct RawUsage: Decodable {
    let input_tokens: Int64?
    let output_tokens: Int64?
    let reasoning_output_tokens: Int64?
    let cached_input_tokens: Int64?
    let cache_read_input_tokens: Int64?
    let cache_creation_input_tokens: Int64?
    let cache_write_input_tokens: Int64?
    let input_tokens_details: InputDetails?
    let output_tokens_details: OutputDetails?
    let output_details: OutputDetails?

    struct InputDetails: Decodable { let cached_tokens: Int64? }
    struct OutputDetails: Decodable { let reasoning_tokens: Int64?; let thinking_tokens: Int64? }

    private var all: [Int64?] {
        [input_tokens, output_tokens, reasoning_output_tokens, cached_input_tokens,
         cache_read_input_tokens, cache_creation_input_tokens, cache_write_input_tokens,
         input_tokens_details?.cached_tokens, output_tokens_details?.reasoning_tokens,
         output_tokens_details?.thinking_tokens, output_details?.thinking_tokens]
    }

    private func validated() throws {
        guard input_tokens != nil || output_tokens != nil,
              all.allSatisfy({ ($0 ?? 0) >= 0 }) else { throw TranscriptParseError.invalidRecord }
    }

    /// Codex follows the OpenAI convention: `input_tokens` is the whole prompt and
    /// the cached part is a subset of it, as is reasoning of output.
    func codexTokens() throws -> TranscriptTokens {
        try validated()
        var tokens = TranscriptTokens(input: input_tokens ?? 0, output: output_tokens ?? 0)
        if let read = cached_input_tokens ?? input_tokens_details?.cached_tokens ?? cache_read_input_tokens {
            tokens.cacheRead = read
            tokens.report(.cacheRead)
        }
        if let write = cache_write_input_tokens ?? cache_creation_input_tokens {
            tokens.cacheWrite = write
            tokens.report(.cacheWrite)
        }
        if let reasoning = reasoning_output_tokens ?? output_tokens_details?.reasoning_tokens {
            tokens.reasoning = reasoning
            tokens.report(.reasoning)
        }
        return tokens
    }

    /// Claude Code follows the Anthropic convention: `input_tokens` is only the part
    /// of the prompt after the last cache breakpoint, and cache reads and writes are
    /// reported beside it. Adding them back gives the whole prompt.
    func claudeTokens() throws -> TranscriptTokens {
        try validated()
        let read = cache_read_input_tokens ?? cached_input_tokens
        let write = cache_creation_input_tokens ?? cache_write_input_tokens
        var tokens = TranscriptTokens(
            input: saturating(saturating(input_tokens ?? 0, read ?? 0), write ?? 0),
            output: output_tokens ?? 0
        )
        if let read { tokens.cacheRead = read; tokens.report(.cacheRead) }
        if let write { tokens.cacheWrite = write; tokens.report(.cacheWrite) }
        if let thinking = output_tokens_details?.thinking_tokens ?? output_details?.thinking_tokens
            ?? output_tokens_details?.reasoning_tokens {
            tokens.reasoning = thinking
            tokens.report(.reasoning)
        }
        return tokens
    }
}

final class TranscriptDates {
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = Self.parseRFC3339(value) { return date }
        return fractional.date(from: value) ?? plain.date(from: value)
    }

    /// The `2026-09-22T06:46:26.949Z` form both tools write, parsed by hand.
    /// `ISO8601DateFormatter` costs tens of microseconds a call, and there is one
    /// timestamp per record: on a large history the formatter alone took most of a
    /// first read. Anything this does not recognise falls back to the formatter.
    static func parseRFC3339(_ value: String) -> Date? {
        var value = value
        return value.withUTF8 { bytes -> Date? in
            let count = bytes.count
            guard count >= 20 else { return nil }
            func number(_ start: Int, _ length: Int) -> Int? {
                var result = 0
                for index in start..<(start + length) {
                    let digit = Int(bytes[index]) - 48
                    guard (0...9).contains(digit) else { return nil }
                    result = result * 10 + digit
                }
                return result
            }
            guard let year = number(0, 4), bytes[4] == 45, let month = number(5, 2), bytes[7] == 45,
                  let day = number(8, 2), bytes[10] == 84 || bytes[10] == 116,
                  let hour = number(11, 2), bytes[13] == 58, let minute = number(14, 2), bytes[16] == 58,
                  let second = number(17, 2),
                  (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year),
                  hour < 24, minute < 60, second < 60
            else { return nil }

            var index = 19
            var fraction = 0.0
            if bytes[index] == 46 {
                index += 1
                var scale = 0.1
                let digitsStart = index
                while index < count, (48...57).contains(bytes[index]) {
                    fraction += Double(bytes[index] - 48) * scale
                    scale /= 10
                    index += 1
                }
                guard index > digitsStart else { return nil }
            }
            guard index < count else { return nil }
            var offset = 0
            switch bytes[index] {
            case 90, 122:
                index += 1
            case 43, 45:
                guard index + 6 == count, bytes[index + 3] == 58,
                      let hours = number(index + 1, 2), let minutes = number(index + 4, 2),
                      hours < 24, minutes < 60 else { return nil }
                offset = (hours * 3_600 + minutes * 60) * (bytes[index] == 45 ? -1 : 1)
                index += 6
            default:
                return nil
            }
            guard index == count else { return nil }

            // Days since 1970-01-01 in the proleptic Gregorian calendar.
            let shiftedYear = month <= 2 ? year - 1 : year
            let era = shiftedYear / 400
            let yearOfEra = shiftedYear - era * 400
            let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        }
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

// MARK: - Line reader

enum TranscriptJSONL {
    struct Result {
        var skipped: Int
        /// Just past the last newline. An unterminated tail is left for the next read,
        /// because on a live transcript it is most likely still being written.
        var endOffset: Int64
        var fingerprint: Data
    }

    /// Far above any line either tool writes in practice; a bound so one corrupt,
    /// newline-free file cannot take the whole address space.
    static let maxLineBytes = 64 << 20
    static let fingerprintBytes = 64

    /// Streams complete lines from `offset` to the end of the file. Returns `nil`
    /// when the file cannot be read. `mayMatter` decides whether a line is worth
    /// handing to `consume`; a line that fails to decode is counted as skipped only
    /// when `mentionsUsage` says it was probably a usage record.
    ///
    /// Plain `read(2)` into one reused buffer: most of a transcript is message bodies
    /// that are tested and dropped without ever being copied. `FileHandle` would
    /// hand back a fresh autoreleased buffer per chunk, and without a pool to drain
    /// them a first read held the whole history in memory at once.
    ///
    /// The `Data` passed to `consume` may point into that buffer and is only valid
    /// for the duration of the call.
    static func read(
        path: String,
        from offset: Int64 = 0,
        maxLineBytes: Int = maxLineBytes,
        chunkBytes: Int = 1 << 20,
        mayMatter: (UnsafeRawBufferPointer) -> Bool = { _ in true },
        mentionsUsage: (UnsafeRawBufferPointer) -> Bool = { _ in true },
        consume: (Data) throws -> Void
    ) -> Result? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard lseek(descriptor, off_t(max(0, offset)), SEEK_SET) == off_t(max(0, offset)) else { return nil }

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, chunkBytes), alignment: 16)
        defer { buffer.deallocate() }
        var skipped = 0
        var position = max(0, offset)
        var endOffset = position
        // A line that straddles a chunk boundary is assembled here; every other line
        // is handled in place.
        var carry = Data()
        var oversized = false

        func handle(_ bytes: UnsafeRawBufferPointer, oversized: Bool) {
            if oversized {
                if mentionsUsage(bytes) { skipped += 1 }
                return
            }
            guard bytes.contains(where: { $0 != 32 && $0 != 9 && $0 != 13 }), mayMatter(bytes) else { return }
            let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                            count: bytes.count, deallocator: .none)
            do { try consume(line) } catch { if mentionsUsage(bytes) { skipped += 1 } }
        }

        func accumulate(_ bytes: UnsafeRawBufferPointer) {
            guard !oversized else { return }
            if carry.count + bytes.count > maxLineBytes {
                // Keep a bounded prefix: enough to tell what kind of line it was.
                carry.append(contentsOf: bytes.prefix(max(0, min(65_536, maxLineBytes - carry.count))))
                oversized = true
            } else {
                carry.append(contentsOf: bytes)
            }
        }

        while true {
            let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            let chunk = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
            let base = chunk.baseAddress!
            var start = 0
            while start < count {
                guard let found = memchr(base + start, 10, count - start) else {
                    accumulate(UnsafeRawBufferPointer(rebasing: chunk[start..<count]))
                    break
                }
                let end = base.distance(to: UnsafeRawPointer(found))
                let piece = UnsafeRawBufferPointer(rebasing: chunk[start..<end])
                if carry.isEmpty && !oversized {
                    handle(piece, oversized: piece.count > maxLineBytes)
                } else {
                    accumulate(piece)
                    carry.withUnsafeBytes { handle($0, oversized: oversized) }
                    carry.removeAll(keepingCapacity: carry.count <= 1 << 20)
                    oversized = false
                }
                start = end + 1
                endOffset = position + Int64(start)
            }
            position += Int64(count)
        }
        // A complete record without its newline yet is still worth showing now. It
        // is consumed but not committed: every record is keyed, so reading it again
        // once the line is finished replaces rather than adds. A tail that does not
        // decode is simply incomplete and is not counted as skipped.
        if !oversized, !carry.isEmpty {
            carry.withUnsafeBytes { bytes in
                if mayMatter(bytes) { try? consume(carry) }
            }
        }
        return Result(skipped: skipped, endOffset: endOffset,
                      fingerprint: fingerprint(of: path, upTo: endOffset))
    }

    /// The first and last `fingerprintBytes` of the file's first `offset` bytes.
    static func fingerprint(of path: String, upTo offset: Int64) -> Data {
        guard offset > 0 else { return Data() }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return Data() }
        defer { close(descriptor) }
        let length = Int(min(Int64(fingerprintBytes), offset))
        var result = Data(count: length * 2)
        let complete = result.withUnsafeMutableBytes { bytes -> Bool in
            pread(descriptor, bytes.baseAddress, length, 0) == length
                && pread(descriptor, bytes.baseAddress! + length, length, off_t(offset) - off_t(length)) == length
        }
        if !complete { result.removeAll() }
        return result
    }
}
