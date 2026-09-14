import Foundation
import XCTest
@testable import ZCodeUsageMenu

final class TranscriptUsageProviderTests: XCTestCase {
    private var root: URL!
    private let instant = Date(timeIntervalSince1970: 1_789_387_200)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testCodexScansBothRootsDeduplicatesGloballyAndIgnoresCumulativeCounters() throws {
        let older = iso(instant.addingTimeInterval(-30))
        let newer = iso(instant)
        try write("sessions/2026/09/live.jsonl", lines: [
            codex("same", input: 40, output: 4, time: newer, turn: "turn"),
            ["type": "turn_context", "payload": ["turn_id": "turn", "model": "gpt-synthetic"]],
            ["type": "turn_token_usage", "payload": ["usage": tokens(input: 9000, output: 9000)]],
            ["type": "thread_token_usage", "payload": ["usage": tokens(input: 9000, output: 9000)]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": tokens(input: 9000, output: 9000)]]]
        ])
        try write("archived_sessions/deep/archive.jsonl", lines: [
            codex("same", input: 10, output: 1, time: older),
            codex("archived-only", input: 7, output: 2, time: newer)
        ])
        try write("other/ignored.jsonl", lines: [codex("ignored", input: 999, output: 999)])
        let snapshot = try codexProvider().load()
        XCTAssertEqual(snapshot.totals.requests, 2)
        XCTAssertEqual(snapshot.totals.inputTokens, 47)
        XCTAssertEqual(snapshot.totals.outputTokens, 6)
        XCTAssertEqual(snapshot.models.map(\.modelID), ["gpt-synthetic", "unknown"])
        XCTAssertTrue(snapshot.models.allSatisfy { $0.providerID == "codex" })
        XCTAssertEqual(snapshot.coverage.fileCount, 2)
        XCTAssertEqual(snapshot.coverage.skippedRecords, 0)
        XCTAssertEqual(snapshot.coverage.cacheWriteLabel, "写入")
        XCTAssertEqual(codexProvider().id, .codex)
    }

    func testCodexLatestSnapshotReplacesRatherThanAccumulatesFields() throws {
        var latest = codex("response", input: 20, output: 5)
        latest["payload"] = ["response_id": "response", "usage": ["input_tokens": 20, "output_tokens": 5]]
        try write("sessions/a.jsonl", lines: [codex("response", input: 100, output: 50), latest])
        let snapshot = try codexProvider().load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.totals.inputTokens, 20)
        XCTAssertEqual(snapshot.totals.outputTokens, 5)
        XCTAssertEqual(snapshot.coverage.metrics, [.requests, .input, .output])
    }

    func testClaudeStreamingSnapshotsAndCompositeRequestIdentity() throws {
        try write("project/session.jsonl", lines: [
            claude("message", request: "request-1", input: 100, output: 20, time: iso(instant.addingTimeInterval(-2))),
            claude("message", request: "request-1", input: 100, output: 35, time: iso(instant)),
            claude("message", request: "request-2", input: 7, output: 4, time: iso(instant)),
            ["type": "user", "message": ["id": "user", "usage": tokens(input: 999, output: 999)]]
        ])
        let snapshot = try claudeProvider().load()
        XCTAssertEqual(snapshot.totals.requests, 2)
        XCTAssertEqual(snapshot.totals.inputTokens, 107)
        XCTAssertEqual(snapshot.totals.outputTokens, 39)
        XCTAssertEqual(snapshot.models.first?.requests, 2)
        XCTAssertEqual(snapshot.models.first?.providerID, "claude")
        XCTAssertEqual(snapshot.models.first?.id, "claude:claude-synthetic")
        XCTAssertEqual(snapshot.coverage.cacheWriteLabel, "创建")
        XCTAssertEqual(claudeProvider().id, .claude)
    }

    func testClaudeIncludesOnlyProjectFilesAndExactSubagentLayout() throws {
        try write("project/main.jsonl", lines: [claude("main", input: 10, output: 1)])
        try write("project/session/subagents/agent.jsonl", lines: [claude("agent", input: 20, output: 2)])
        for path in ["root.jsonl", "project/session/wrong.jsonl", "project/session/subagents/deeper/wrong.jsonl", "project/session/other/wrong.jsonl"] {
            try write(path, lines: [claude(path, input: 999, output: 999)])
        }
        let snapshot = try claudeProvider().load()
        XCTAssertEqual(snapshot.totals.requests, 2)
        XCTAssertEqual(snapshot.totals.inputTokens, 30)
        XCTAssertEqual(snapshot.coverage.fileCount, 2)
    }

    func testClaudeDeduplicatesAcrossMainAndSubagentFilesByTimestamp() throws {
        try write("project/main.jsonl", lines: [claude("same", input: 30, output: 9, time: iso(instant))])
        try write("project/session/subagents/agent.jsonl", lines: [
            claude("same", input: 10, output: 2, time: iso(instant.addingTimeInterval(-10)))
        ])
        let snapshot = try claudeProvider().load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.totals.outputTokens, 9)
    }

    func testMissingFieldsAreUnavailableButExplicitZeroIsMeasured() throws {
        var absent = claude("absent", input: 2, output: 3)
        absent["message"] = ["id": "absent", "usage": ["input_tokens": 2, "output_tokens": 3]]
        try write("project/a.jsonl", lines: [claude("zero", input: 0, output: 0), absent])
        let mixed = try claudeProvider().load()
        XCTAssertEqual(mixed.coverage.metrics, [.requests, .input, .output])
        XCTAssertEqual(mixed.models.first(where: { $0.modelID == "unknown" })?.requests, 1)
        XCTAssertFalse(mixed.coverage.supportsInputComposition)
        XCTAssertEqual(mixed.totals.turns, 0)
        XCTAssertEqual(mixed.totals.toolCalls, 0)

        try write("project/a.jsonl", lines: [claude("zero", input: 0, output: 0)])
        let zero = try claudeProvider().load()
        XCTAssertEqual(zero.coverage.metrics, [.requests, .input, .output, .reasoning, .cacheRead, .cacheWrite])
        XCTAssertEqual(zero.totals.cacheReadInputTokens, 0)
    }

    func testCodexRealFieldNamesIncludeCacheWriteInputTokens() throws {
        // Codex writes cache_write_input_tokens (not cache_creation_input_tokens);
        // missing this key made the cache-write column render as unavailable.
        var line = codex("real", input: 32837, output: 118)
        line["payload"] = ["response_id": "real", "usage": [
            "input_tokens": 32837, "cached_input_tokens": 13610,
            "cache_write_input_tokens": 19224, "output_tokens": 118,
            "reasoning_output_tokens": 11, "total_tokens": 32837
        ]]
        try write("sessions/real.jsonl", lines: [line])
        let snapshot = try codexProvider().load()
        XCTAssertEqual(snapshot.totals.cacheCreationInputTokens, 19224)
        XCTAssertEqual(snapshot.totals.cacheReadInputTokens, 13610)
        XCTAssertEqual(snapshot.totals.reasoningTokens, 11)
        XCTAssertTrue(snapshot.coverage.metrics.contains(.cacheWrite))
    }

    func testReportedInputIsNeverReducedByCachesAndReasoningIsMeasured() throws {
        var codexLine = codex("codex", input: 10, output: 5)
        codexLine["payload"] = ["response_id": "codex", "usage": [
            "input_tokens": 10, "output_tokens": 5, "cached_input_tokens": 80,
            "cache_creation_input_tokens": 20, "reasoning_output_tokens": 3
        ]]
        try write("sessions/a.jsonl", lines: [codexLine])
        let codexSnapshot = try codexProvider().load()
        XCTAssertEqual(codexSnapshot.totals.inputTokens, 10)
        XCTAssertEqual(codexSnapshot.totals.cacheReadInputTokens, 80)
        XCTAssertEqual(codexSnapshot.totals.cacheCreationInputTokens, 20)
        XCTAssertEqual(codexSnapshot.totals.reasoningTokens, 3)
        XCTAssertFalse(codexSnapshot.coverage.supportsInputComposition)

        var claudeLine = claude("claude", input: 10, output: 5)
        claudeLine["message"] = ["id": "claude", "usage": [
            "input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 80,
            "cache_creation_input_tokens": 20, "output_details": ["thinking_tokens": 3]
        ]]
        try write("project/a.jsonl", lines: [claudeLine])
        let claudeSnapshot = try claudeProvider().load()
        XCTAssertEqual(claudeSnapshot.totals.inputTokens, 10)
        XCTAssertEqual(claudeSnapshot.totals.cacheReadInputTokens, 80)
        XCTAssertEqual(claudeSnapshot.totals.cacheCreationInputTokens, 20)
        XCTAssertEqual(claudeSnapshot.totals.reasoningTokens, 3)
        XCTAssertTrue(claudeSnapshot.coverage.metrics.contains(.reasoning))
        XCTAssertFalse(claudeSnapshot.coverage.supportsInputComposition)
    }

    func testMalformedLinesAndUnterminatedTailAreSkippedWithoutLosingGoodRecords() throws {
        let file = try write("sessions/a.jsonl", lines: [codex("good", input: 1, output: 2)])
        var data = try Data(contentsOf: file)
        data.append(Data("{broken}\n{\"type\":\"unknown\",\"body\":{\"anything\":[1,2]}}\n".utf8))
        data.append(try JSONSerialization.data(withJSONObject: codex("tail", input: 999, output: 999)))
        try data.write(to: file)
        let snapshot = try codexProvider().load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.coverage.skippedRecords, 2)
        XCTAssertFalse(snapshot.coverage.note.contains(root.path))
    }

    func testSharedStreamingReaderBoundsLinesHandlesCRLFAndRecovers() throws {
        let file = root.appendingPathComponent("stream.jsonl")
        let text = "{\"n\":1}\r\n" + String(repeating: "x", count: 100) + "\n\n{\"n\":2}\n{\"n\":3}"
        try Data(text.utf8).write(to: file)
        var values: [Int] = []
        struct Number: Decodable { let n: Int }
        let skipped = TranscriptJSONL.read(file, maxLineBytes: 16, chunkBytes: 3) {
            values.append(try JSONDecoder().decode(Number.self, from: $0).n)
        }
        XCTAssertEqual(values, [1, 2])
        XCTAssertEqual(skipped, 2)
    }

    func testNegativeInvalidAndOverflowingIndividualCountersAreRejected() throws {
        var negative = codex("negative", input: -1, output: 2)
        var excessive = codex("excessive", input: 1, output: 2)
        negative["payload"] = ["response_id": "negative", "usage": ["input_tokens": -1, "output_tokens": 2]]
        excessive["payload"] = ["response_id": "excessive", "usage": ["input_tokens": "9223372036854775808", "output_tokens": 2]]
        let file = try write("sessions/a.jsonl", lines: [
            codex("good", input: 1, output: 2), negative, excessive,
            ["type": "token_usage_record", "payload": ["response_id": "empty", "usage": [:]]]
        ])
        var data = try Data(contentsOf: file)
        data.append(Data("{\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"overflow\",\"usage\":{\"input_tokens\":9223372036854775808}}}\n".utf8))
        try data.write(to: file)
        let snapshot = try codexProvider().load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.coverage.skippedRecords, 4)
    }

    func testAggregateOverflowSaturatesSafelyIncludingModelsAndToday() throws {
        try write("sessions/a.jsonl", lines: [
            codex("one", input: Int64.max, output: Int64.max, time: iso(instant)),
            codex("two", input: 10, output: 10, time: iso(instant))
        ])
        let snapshot = try codexProvider().load()
        XCTAssertEqual(snapshot.totals.inputTokens, Int64.max)
        XCTAssertEqual(snapshot.totals.outputTokens, Int64.max)
        XCTAssertEqual(snapshot.today.outputTokens, Int64.max)
        XCTAssertEqual(snapshot.models.first?.outputTokens, Int64.max)
        XCTAssertEqual(snapshot.totals.requests, 2)
    }

    func testTimestampsUseFractionalAndPlainISOAndExclusiveLocalDayEnd() throws {
        let start = Calendar.current.startOfDay(for: instant)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let lines = [
            claude("start", input: 1, output: 1, time: iso(start, fractional: false)),
            claude("fractional", input: 2, output: 2, time: iso(start.addingTimeInterval(0.125))),
            claude("last", input: 4, output: 4, time: iso(end.addingTimeInterval(-0.125))),
            claude("before", input: 8, output: 8, time: iso(start.addingTimeInterval(-1))),
            claude("end", input: 16, output: 16, time: iso(end)),
            claude("invalid", input: 32, output: 32, time: "not-a-date")
        ]
        try write("project/a.jsonl", lines: lines)
        let snapshot = try claudeProvider().load()
        XCTAssertEqual(snapshot.today.requests, 3)
        XCTAssertEqual(snapshot.today.inputTokens, 7)
        XCTAssertEqual(snapshot.totals.requests, 6)
        XCTAssertEqual(snapshot.totals.inputTokens, 63)
        XCTAssertEqual(snapshot.refreshedAt, instant)
        XCTAssertTrue(snapshot.coverage.note.contains("无有效时间"))
    }

    func testSymlinkFilesAndDirectoriesAreNotFollowed() throws {
        let target = try write("outside/hidden.jsonl", lines: [codex("hidden", input: 999, output: 999)])
        try write("sessions/real.jsonl", lines: [codex("real", input: 1, output: 1)])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sessions/linked.jsonl"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("archived_sessions"), withDestinationURL: target.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sessions/nested"), withDestinationURL: target.deletingLastPathComponent())
        let codexSnapshot = try codexProvider().load()
        XCTAssertEqual(codexSnapshot.totals.requests, 1)
        XCTAssertEqual(codexSnapshot.coverage.fileCount, 1)

        let claudeRoot = root.appendingPathComponent("claude-projects")
        try write("claude-projects/project/real.jsonl", lines: [claude("real", input: 1, output: 1)])
        try FileManager.default.createSymbolicLink(at: claudeRoot.appendingPathComponent("project/link.jsonl"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: claudeRoot.appendingPathComponent("linked-project"), withDestinationURL: target.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: claudeRoot.appendingPathComponent("project/session"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claudeRoot.appendingPathComponent("project/session/subagents"), withDestinationURL: target.deletingLastPathComponent())
        let claudeSnapshot = try ClaudeUsageProvider(rootURL: claudeRoot).load()
        XCTAssertEqual(claudeSnapshot.totals.requests, 1)
        XCTAssertEqual(claudeSnapshot.coverage.fileCount, 1)
    }

    func testMissingEmptyAndIncompatibleDirectoriesHaveSanitizedErrors() throws {
        let missing = root.appendingPathComponent("missing")
        assertError(.missing(.codex)) { try CodexUsageProvider(rootURL: missing).load() }
        assertError(.missing(.claude)) { try ClaudeUsageProvider(rootURL: missing).load() }
        assertError(.noRecords(.codex)) { try codexProvider().load() }
        assertError(.noRecords(.claude)) { try claudeProvider().load() }
        let file = try write("sessions/broken.jsonl", lines: [])
        try Data("{broken}\n".utf8).write(to: file)
        assertError(.incompatible(.codex)) { try codexProvider().load() }
    }

    func testDefaultsAreUnderHomeAndProviderNamesAreDistinct() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(CodexUsageProvider().rootURL, home.appending(path: ".codex"))
        XCTAssertEqual(ClaudeUsageProvider().rootURL, home.appending(path: ".claude/projects"))
    }

    private func codexProvider() -> CodexUsageProvider {
        let date = instant
        return CodexUsageProvider(rootURL: root, now: { date })
    }
    private func claudeProvider() -> ClaudeUsageProvider {
        let date = instant
        return ClaudeUsageProvider(rootURL: root, now: { date })
    }
    private func iso(_ date: Date, fractional: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.string(from: date)
    }
    private func tokens(input: Int64, output: Int64) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "reasoning_output_tokens": 0,
         "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
    }
    private func codex(_ response: String, input: Int64, output: Int64,
                       time: String? = nil, turn: String = "missing") -> [String: Any] {
        ["type": "token_usage_record", "timestamp": time ?? iso(instant),
         "payload": ["response_id": response, "turn_id": turn, "usage": tokens(input: input, output: output),
                     "turn_token_usage": tokens(input: 9999, output: 9999),
                     "thread_token_usage": tokens(input: 9999, output: 9999)]]
    }
    private func claude(_ message: String, request: String = "request", input: Int64, output: Int64,
                        time: String? = nil) -> [String: Any] {
        ["type": "assistant", "timestamp": time ?? iso(instant), "requestId": request,
         "message": ["id": message, "model": "claude-synthetic", "usage": tokens(input: input, output: output),
                     "content": [["type": "text", "text": "Synthetic body deliberately ignored"]]]]
    }
    @discardableResult
    private func write(_ path: String, lines: [[String: Any]]) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(10)
        }
        try data.write(to: file)
        return file
    }
    private func assertError(_ expected: ProviderReadError, operation: () throws -> UsageSnapshot,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains(root.path), file: file, line: line)
        }
    }
}
