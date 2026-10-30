import Foundation
import XCTest

@testable import AIToolbox

final class TranscriptUsageProviderTests: XCTestCase {
    private var root: URL!
    private let instant = Date(timeIntervalSince1970: 1_789_387_200)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "transcript-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - Codex

    func testCodexScansBothRootsDeduplicatesGloballyAndIgnoresCumulativeCounters() throws {
        let older = iso(instant.addingTimeInterval(-30))
        let newer = iso(instant)
        try write(
            "sessions/2026/09/live.jsonl",
            lines: [
                [
                    "type": "turn_context", "timestamp": newer,
                    "payload": ["turn_id": "turn", "model": "gpt-synthetic"],
                ],
                codex("same", input: 40, output: 4, time: newer, turn: "turn"),
                [
                    "type": "event_msg",
                    "payload": [
                        "type": "token_count",
                        "info": ["total_token_usage": usage(input: 9000, output: 9000)],
                    ],
                ],
            ])
        try write(
            "archived_sessions/deep/archive.jsonl",
            lines: [
                codex("same", input: 10, output: 1, time: older),
                codex("archived-only", input: 7, output: 2, time: newer),
            ])
        try write("other/ignored.jsonl", lines: [codex("ignored", input: 999, output: 999)])
        let snapshot = try provider(.codex).load()
        XCTAssertEqual(snapshot.totals.requests, 2)
        XCTAssertEqual(snapshot.totals.inputTokens, 47)
        XCTAssertEqual(snapshot.totals.outputTokens, 6)
        XCTAssertEqual(snapshot.models.map(\.modelID), ["gpt-synthetic", "unknown"])
        XCTAssertEqual(snapshot.coverage.fileCount, 2)
        XCTAssertEqual(snapshot.coverage.skippedRecords, 0)
    }

    /// The model is joined through the turn even when the turn's context is in
    /// another file, as it is for a session resumed from the archive.
    func testCodexModelIsResolvedAcrossFiles() throws {
        try write(
            "archived_sessions/a.jsonl",
            lines: [
                ["type": "turn_context", "payload": ["turn_id": "t1", "model": "gpt-archived"]]
            ])
        try write("sessions/b.jsonl", lines: [codex("r", input: 1, output: 1, turn: "t1")])
        XCTAssertEqual(try provider(.codex).load().models.map(\.modelID), ["gpt-archived"])
    }

    /// Codex's `input_tokens` is the whole prompt and the cache is part of it; its
    /// reasoning is part of the output.
    func testCodexInputAlreadyIncludesTheCache() throws {
        var line = codex("real", input: 0, output: 0)
        line["payload"] = [
            "response_id": "real",
            "usage": [
                "input_tokens": 32_837, "cached_input_tokens": 13_610,
                "cache_write_input_tokens": 19_224, "output_tokens": 118,
                "reasoning_output_tokens": 11, "total_tokens": 32_955,
            ],
        ]
        try write("sessions/real.jsonl", lines: [line])
        let totals = try provider(.codex).load().totals
        XCTAssertEqual(totals.inputTokens, 32_837)
        XCTAssertEqual(totals.cacheReadTokens, 13_610)
        XCTAssertEqual(totals.cacheWriteTokens, 19_224)
        XCTAssertEqual(totals.freshInputTokens, 3)
        XCTAssertEqual(totals.outputTokens, 118)
        XCTAssertEqual(totals.reasoningTokens, 11)
    }

    func testCodexCountsTurnsAndToolCallsOnce() throws {
        let call: [String: Any] = [
            "type": "response_item", "timestamp": iso(instant),
            "payload": ["type": "function_call", "call_id": "c1", "name": "exec", "arguments": "{}"],
        ]
        let custom: [String: Any] = [
            "type": "response_item", "timestamp": iso(instant),
            "payload": ["type": "custom_tool_call", "call_id": "c2"],
        ]
        let output: [String: Any] = [
            "type": "response_item", "timestamp": iso(instant),
            "payload": ["type": "function_call_output", "call_id": "c1"],
        ]
        try write(
            "sessions/a.jsonl",
            lines: [
                [
                    "type": "turn_context", "timestamp": iso(instant),
                    "payload": ["turn_id": "t1", "model": "m"],
                ],
                call, output, custom, call,
                codex("r1", input: 1, output: 1, turn: "t1"),
                codex("r2", input: 1, output: 1, turn: "t1"),
            ])
        // The same session copied into the archive must not double anything.
        try FileManager.default.createDirectory(
            at: root.appending(path: "archived_sessions"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: root.appending(path: "sessions/a.jsonl"),
            to: root.appending(path: "archived_sessions/a.jsonl"))
        let snapshot = try provider(.codex).load()
        XCTAssertEqual(snapshot.totals.turns, 1)
        XCTAssertEqual(snapshot.totals.toolCalls, 2)
        XCTAssertEqual(snapshot.totals.requests, 2)
        XCTAssertEqual(snapshot.totals(on: instant).toolCalls, 2)
    }

    // MARK: - Claude Code

    func testClaudeStreamingCopiesCollapseToTheLastOne() throws {
        try write(
            "project/session.jsonl",
            lines: [
                claude(
                    "message", request: "request-1", input: 100, output: 0,
                    time: iso(instant.addingTimeInterval(-2))),
                claude("message", request: "request-1", input: 100, output: 35, time: iso(instant)),
                claude("message", request: "request-2", input: 7, output: 4, time: iso(instant)),
                [
                    "type": "user",
                    "message": ["role": "user", "id": "user", "usage": usage(input: 999, output: 999)],
                ],
            ])
        let snapshot = try provider(.claude).load()
        XCTAssertEqual(snapshot.totals.requests, 2)
        XCTAssertEqual(snapshot.totals.inputTokens, 107)
        XCTAssertEqual(snapshot.totals.outputTokens, 39)
        XCTAssertEqual(snapshot.models.first?.id, "claude-synthetic")
    }

    /// Claude's `input_tokens` excludes the cache, so the cache is added back to give
    /// the same meaning Codex uses.
    func testClaudeInputIsNormalisedToIncludeTheCache() throws {
        var line = claude("m", input: 0, output: 0)
        line["message"] = [
            "id": "m", "role": "assistant", "model": "claude-synthetic",
            "usage": [
                "input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 80,
                "cache_creation_input_tokens": 20, "output_tokens_details": ["thinking_tokens": 3],
            ],
        ]
        try write("project/a.jsonl", lines: [line])
        let snapshot = try provider(.claude).load()
        XCTAssertEqual(snapshot.totals.inputTokens, 110)
        XCTAssertEqual(snapshot.totals.cacheReadTokens, 80)
        XCTAssertEqual(snapshot.totals.cacheWriteTokens, 20)
        XCTAssertEqual(snapshot.totals.freshInputTokens, 10)
        XCTAssertEqual(snapshot.totals.reasoningTokens, 3)
        XCTAssertEqual(snapshot.coverage.reported, [.cacheRead, .cacheWrite, .reasoning])
    }

    func testClaudeIncludesOnlyProjectFilesAndExactSubagentLayout() throws {
        try write("project/main.jsonl", lines: [claude("main", input: 10, output: 1)])
        try write("project/session/subagents/agent.jsonl", lines: [claude("agent", input: 20, output: 2)])
        for path in [
            "root.jsonl", "project/session/wrong.jsonl", "project/session/subagents/deeper/wrong.jsonl",
            "project/session/other/wrong.jsonl",
        ] {
            try write(path, lines: [claude(path, input: 999, output: 999)])
        }
        let snapshot = try provider(.claude).load()
        XCTAssertEqual(snapshot.totals.requests, 2)
        XCTAssertEqual(snapshot.totals.inputTokens, 30)
        XCTAssertEqual(snapshot.coverage.fileCount, 2)
    }

    func testClaudeDeduplicatesAcrossMainAndSubagentFilesByTimestamp() throws {
        try write("project/main.jsonl", lines: [claude("same", input: 30, output: 9, time: iso(instant))])
        try write(
            "project/session/subagents/agent.jsonl",
            lines: [
                claude("same", input: 10, output: 2, time: iso(instant.addingTimeInterval(-10)))
            ])
        let snapshot = try provider(.claude).load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.totals.outputTokens, 9)
    }

    /// A turn is a prompt the user typed (or a notification the model acts on).
    /// Tool results, meta lines, local slash commands and subagent prompts are not.
    func testClaudeTurnsAndToolCalls() throws {
        func user(_ content: Any, prompt: String, sidechain: Bool = false, meta: Bool = false) -> [String:
            Any]
        {
            var line: [String: Any] = [
                "type": "user", "timestamp": iso(instant), "promptId": prompt, "uuid": UUID().uuidString,
                "isSidechain": sidechain, "message": ["role": "user", "content": content],
            ]
            if meta { line["isMeta"] = true }
            return line
        }
        var withTools = claude("a1", input: 1, output: 1)
        withTools["message"] = [
            "id": "a1", "role": "assistant", "model": "m", "usage": usage(input: 1, output: 1),
            "content": [
                ["type": "thinking", "thinking": "x"],
                ["type": "tool_use", "id": "tool-1", "name": "Bash", "input": [:]],
                ["type": "tool_use", "id": "tool-2", "name": "Read", "input": [:]],
            ],
        ]
        var streamedAgain = withTools
        streamedAgain["timestamp"] = iso(instant.addingTimeInterval(1))
        try write(
            "project/a.jsonl",
            lines: [
                user("<local-command-caveat>Caveat</local-command-caveat>", prompt: "p0", meta: true),
                user("<command-name>/mcp</command-name>", prompt: "p0"),
                user("fix the bug", prompt: "p1"),
                withTools, streamedAgain,
                user([["type": "tool_result", "tool_use_id": "tool-1", "content": "ok"]], prompt: "p1"),
                user([["type": "text", "text": "and add a test"]], prompt: "p2"),
                user("subagent brief", prompt: "p1", sidechain: true),
            ])
        let totals = try provider(.claude).load().totals
        XCTAssertEqual(totals.turns, 2)
        XCTAssertEqual(totals.toolCalls, 2)
        XCTAssertEqual(totals.requests, 1)
    }

    func testClaudeSyntheticErrorMessagesAreNotRequests() throws {
        var synthetic = claude("s", input: 0, output: 0)
        synthetic["message"] = [
            "id": "s", "role": "assistant", "model": "<synthetic>", "usage": usage(input: 0, output: 0),
        ]
        try write("project/a.jsonl", lines: [claude("real", input: 5, output: 5), synthetic])
        let snapshot = try provider(.claude).load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.models.map(\.modelID), ["claude-synthetic"])
    }

    // MARK: - Shared behaviour

    func testDailyBucketsFollowLocalMidnight() throws {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: instant)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        try write(
            "project/a.jsonl",
            lines: [
                claude("start", input: 1, output: 1, time: iso(start, fractional: false)),
                claude("fractional", input: 2, output: 2, time: iso(start.addingTimeInterval(0.125))),
                claude("last", input: 4, output: 4, time: iso(end.addingTimeInterval(-0.125))),
                claude("before", input: 8, output: 8, time: iso(start.addingTimeInterval(-1))),
                claude("end", input: 16, output: 16, time: iso(end)),
                claude("invalid", input: 32, output: 32, time: "not-a-date"),
            ])
        let snapshot = try provider(.claude).load()
        let today = snapshot.totals(on: instant)
        XCTAssertEqual(today.requests, 3)
        XCTAssertEqual(today.outputTokens, 7)
        XCTAssertEqual(snapshot.totals.requests, 6)
        XCTAssertEqual(snapshot.totals.outputTokens, 63)
        XCTAssertEqual(
            snapshot.daily.map(\.date), [calendar.date(byAdding: .day, value: -1, to: start)!, start, end])
        XCTAssertEqual(snapshot.coverage.undatedRecords, 1)
        XCTAssertTrue(snapshot.coverage.isPartial)
        XCTAssertEqual(snapshot.refreshedAt, instant)
    }

    func testMissingOptionalFieldsAreUnreportedButExplicitZeroIsReported() throws {
        var bare = claude("bare", input: 2, output: 3)
        bare["message"] = [
            "id": "bare", "role": "assistant", "usage": ["input_tokens": 2, "output_tokens": 3],
        ]
        try write("project/a.jsonl", lines: [bare])
        let unreported = try provider(.claude).load()
        XCTAssertEqual(unreported.coverage.reported, [])
        XCTAssertEqual(unreported.models.map(\.modelID), ["unknown"])

        try write("project/a.jsonl", lines: [bare, claude("zero", input: 0, output: 0)])
        XCTAssertEqual(try provider(.claude).load().coverage.reported, [.cacheRead, .cacheWrite])
    }

    func testMalformedLinesAreCountedOnlyWhenTheyWereUsageRecords() throws {
        let file = try write("sessions/a.jsonl", lines: [codex("good", input: 1, output: 2)])
        var data = try Data(contentsOf: file)
        data.append(
            Data(
                "{broken}\n{\"type\":\"token_usage_record\",broken\n{\"type\":\"unknown\",\"body\":{\"anything\":[1,2]}}\n"
                    .utf8))
        try data.write(to: file)
        let snapshot = try provider(.codex).load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.coverage.skippedRecords, 1)
    }

    func testInvalidCountersRejectTheRecord() throws {
        var negative = codex("negative", input: 0, output: 0)
        negative["payload"] = ["response_id": "negative", "usage": ["input_tokens": -1, "output_tokens": 2]]
        var text = codex("text", input: 0, output: 0)
        text["payload"] = ["response_id": "text", "usage": ["input_tokens": "12", "output_tokens": 2]]
        let file = try write(
            "sessions/a.jsonl",
            lines: [
                codex("good", input: 1, output: 2), negative, text,
                ["type": "token_usage_record", "payload": ["response_id": "empty", "usage": [:]]],
            ])
        var data = try Data(contentsOf: file)
        data.append(
            Data(
                "{\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"overflow\",\"usage\":{\"input_tokens\":9223372036854775808}}}\n"
                    .utf8))
        try data.write(to: file)
        let snapshot = try provider(.codex).load()
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(snapshot.coverage.skippedRecords, 4)
    }

    func testAggregateOverflowSaturates() throws {
        try write(
            "sessions/a.jsonl",
            lines: [
                codex("one", input: Int64.max, output: Int64.max),
                codex("two", input: 10, output: 10),
            ])
        let snapshot = try provider(.codex).load()
        XCTAssertEqual(snapshot.totals.inputTokens, Int64.max)
        XCTAssertEqual(snapshot.totals.outputTokens, Int64.max)
        XCTAssertEqual(snapshot.totals(on: instant).outputTokens, Int64.max)
        XCTAssertEqual(snapshot.models.first?.outputTokens, Int64.max)
        XCTAssertEqual(snapshot.totals.requests, 2)
    }

    /// A line bigger than any reasonable buffer — a pasted file, a long tool output —
    /// must not cost memory proportional to its size, nor hide the records around it.
    func testOversizedLinesAreBoundedAndDoNotHideNeighbours() throws {
        let file = root.appending(path: "large.jsonl")
        let body = String(repeating: "x", count: 4_096)
        let text =
            "{\"type\":\"user\",\"content\":\"\(body)\"}\n"
            + "{\"type\":\"token_usage_record\",\"pad\":\"\(body)\"}\n"
            + "{\"n\":1}\n"
        try Data(text.utf8).write(to: file)
        var seen: [Data] = []
        let result = try XCTUnwrap(
            TranscriptJSONL.read(
                path: file.path, maxLineBytes: 1_024, chunkBytes: 100,
                mentionsUsage: { bytes in bytes.firstRange(of: Data("token_usage_record".utf8)) != nil },
                consume: { seen.append($0) }
            ))
        XCTAssertEqual(seen, [Data("{\"n\":1}".utf8)])
        XCTAssertEqual(result.skipped, 1, "only the oversized usage record counts as lost")
        XCTAssertEqual(result.endOffset, Int64(text.utf8.count))
    }

    func testReaderHandlesCRLFBlankLinesAndChunkBoundaries() throws {
        let file = root.appendingPathComponent("stream.jsonl")
        try Data("{\"n\":1}\r\n\n   \n{\"n\":2}\n{\"n\":3}".utf8).write(to: file)
        struct Number: Decodable { let n: Int }
        var values: [Int] = []
        let result = try XCTUnwrap(
            TranscriptJSONL.read(path: file.path, chunkBytes: 3) {
                values.append(try JSONDecoder().decode(Number.self, from: $0).n)
            })
        XCTAssertEqual(values, [1, 2, 3], "a complete unterminated tail is still shown")
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.endOffset, 22, "but not committed, so it is read again once finished")
    }

    func testSymlinksAreNotFollowed() throws {
        let target = try write("outside/hidden.jsonl", lines: [codex("hidden", input: 999, output: 999)])
        try write("sessions/real.jsonl", lines: [codex("real", input: 1, output: 1)])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sessions/linked.jsonl"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("archived_sessions"),
            withDestinationURL: target.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("sessions/nested"),
            withDestinationURL: target.deletingLastPathComponent())
        let codexSnapshot = try provider(.codex).load()
        XCTAssertEqual(codexSnapshot.totals.requests, 1)
        XCTAssertEqual(codexSnapshot.coverage.fileCount, 1)

        let claudeRoot = root.appendingPathComponent("claude-projects")
        try write("claude-projects/project/real.jsonl", lines: [claude("real", input: 1, output: 1)])
        try FileManager.default.createSymbolicLink(
            at: claudeRoot.appendingPathComponent("project/link.jsonl"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: claudeRoot.appendingPathComponent("linked-project"),
            withDestinationURL: target.deletingLastPathComponent())
        try FileManager.default.createDirectory(
            at: claudeRoot.appendingPathComponent("project/session"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: claudeRoot.appendingPathComponent("project/session/subagents"),
            withDestinationURL: target.deletingLastPathComponent())
        let claudeSnapshot = try TranscriptUsageProvider(
            .claude, rootURL: claudeRoot, now: { [instant] in instant }
        ).load()
        XCTAssertEqual(claudeSnapshot.totals.requests, 1)
        XCTAssertEqual(claudeSnapshot.coverage.fileCount, 1)
    }

    func testMissingEmptyAndIncompatibleDirectoriesHaveSanitisedErrors() throws {
        let missing = root.appendingPathComponent("missing")
        assertError(.missing(.codex)) { try TranscriptUsageProvider(.codex, rootURL: missing).load() }
        assertError(.missing(.claude)) { try TranscriptUsageProvider(.claude, rootURL: missing).load() }
        assertError(.noRecords(.codex)) { try provider(.codex).load() }
        assertError(.noRecords(.claude)) { try provider(.claude).load() }
        let file = try write("sessions/broken.jsonl", lines: [])
        try Data("{\"type\":\"token_usage_record\",broken}\n".utf8).write(to: file)
        assertError(.incompatible(.codex)) { try provider(.codex).load() }
    }

    func testDefaultRootsAreUnderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(TranscriptUsageProvider(.codex).rootURL, home.appending(path: ".codex"))
        XCTAssertEqual(TranscriptUsageProvider(.claude).rootURL, home.appending(path: ".claude/projects"))
    }

    // MARK: - Incremental reads

    func testAppendedLinesAreReadIncrementally() throws {
        let provider = provider(.codex)
        let file = try write("sessions/a.jsonl", lines: [codex("r1", input: 1, output: 1)])
        XCTAssertEqual(try provider.load().totals.requests, 1)
        try append(file, codex("r2", input: 2, output: 2))
        let second = try provider.load()
        XCTAssertEqual(second.totals.requests, 2)
        XCTAssertEqual(second.totals.outputTokens, 3)
        XCTAssertEqual(try provider.load().totals, second.totals, "an unchanged tree reuses the aggregate")
    }

    /// A record whose newline has not been written yet is shown, then replaced — not
    /// added — once the line is complete.
    func testAPartialTailIsReplacedWhenItIsFinished() throws {
        let provider = provider(.codex)
        let file = try write("sessions/a.jsonl", lines: [codex("r1", input: 1, output: 1)])
        let tail = try JSONSerialization.data(
            withJSONObject: codex("r2", input: 5, output: 5), options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        XCTAssertEqual(try provider.load().totals.requests, 2)
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        try append(file, codex("r3", input: 1, output: 1))
        let finished = try provider.load()
        XCTAssertEqual(finished.totals.requests, 3)
        XCTAssertEqual(finished.totals.outputTokens, 7)
    }

    func testRewrittenOrTruncatedFilesAreReadAgainInFull() throws {
        let provider = provider(.codex)
        let file = try write(
            "sessions/a.jsonl", lines: [codex("r1", input: 1, output: 1), codex("r2", input: 1, output: 1)])
        XCTAssertEqual(try provider.load().totals.requests, 2)

        try write("sessions/a.jsonl", lines: [codex("r3", input: 4, output: 4)])
        let truncated = try provider.load()
        XCTAssertEqual(truncated.totals.requests, 1)
        XCTAssertEqual(truncated.totals.outputTokens, 4)

        // Rewritten in place: same inode, same length, different record. A resumed
        // read would keep the stale "r3" and count two requests below.
        let rewritten = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
            .replacingOccurrences(of: "\"r3\"", with: "\"r5\"")
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()
        try append(file, codex("r5", input: 1, output: 1))
        XCTAssertEqual(try provider.load().totals.requests, 1)
    }

    func testDeletedFilesLeaveTheTotals() throws {
        let provider = provider(.codex)
        try write("sessions/a.jsonl", lines: [codex("r1", input: 1, output: 1)])
        let b = try write("sessions/b.jsonl", lines: [codex("r2", input: 1, output: 1)])
        XCTAssertEqual(try provider.load().totals.requests, 2)
        try FileManager.default.removeItem(at: b)
        XCTAssertEqual(try provider.load().totals.requests, 1)
    }

    /// Crossing midnight changes what "today" is without any file changing.
    func testCrossingMidnightRebuildsTheDays() throws {
        let clock = MutableClock(instant)
        let provider = TranscriptUsageProvider(.codex, rootURL: root, now: { clock.now })
        try write("sessions/a.jsonl", lines: [codex("r1", input: 1, output: 1)])
        let first = try provider.load()
        clock.now = instant.addingTimeInterval(86_400)
        let next = try provider.load()
        XCTAssertEqual(next.refreshedAt, clock.now)
        XCTAssertEqual(next.totals(on: clock.now), .zero)
        XCTAssertEqual(next.totals, first.totals)
    }

    // MARK: - Fixtures

    private func provider(_ id: UsageProviderID) -> TranscriptUsageProvider {
        let date = instant
        return TranscriptUsageProvider(id, rootURL: root, now: { date })
    }

    private func iso(_ date: Date, fractional: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func usage(input: Int64, output: Int64) -> [String: Any] {
        [
            "input_tokens": input, "output_tokens": output,
            "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
        ]
    }

    private func codex(
        _ response: String, input: Int64, output: Int64,
        time: String? = nil, turn: String = "missing"
    ) -> [String: Any] {
        [
            "type": "token_usage_record", "timestamp": time ?? iso(instant),
            "payload": [
                "response_id": response, "turn_id": turn,
                "usage": ["input_tokens": input, "output_tokens": output],
                "turn_token_usage": usage(input: 9999, output: 9999),
                "thread_token_usage": usage(input: 9999, output: 9999),
            ],
        ]
    }

    private func claude(
        _ message: String, request: String = "request", input: Int64, output: Int64,
        time: String? = nil
    ) -> [String: Any] {
        [
            "type": "assistant", "timestamp": time ?? iso(instant), "requestId": request,
            "message": [
                "id": message, "role": "assistant", "model": "claude-synthetic",
                "usage": usage(input: input, output: output),
                "content": [["type": "text", "text": "Synthetic body deliberately ignored"]],
            ],
        ]
    }

    @discardableResult
    private func write(_ path: String, lines: [[String: Any]]) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(10)
        }
        try data.write(to: file)
        return file
    }

    private func append(_ file: URL, _ line: [String: Any]) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(
            contentsOf: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) + Data([10]))
    }

    private func assertError(
        _ expected: ProviderReadError, operation: () throws -> UsageSnapshot,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ProviderReadError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains(root.path), file: file, line: line)
        }
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class TranscriptDatesTests: XCTestCase {
    /// The hand-written parser must agree with the formatter it replaces, or fall
    /// back to it — never produce a different date.
    func testFastPathAgreesWithTheFormatter() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let date = Date(timeIntervalSince1970: Double.random(in: 0...4_102_444_800, using: &generator))
            for text in [fractional.string(from: date), plain.string(from: date)] {
                let fast = TranscriptDates.parseRFC3339(text)
                let slow = fractional.date(from: text) ?? plain.date(from: text)
                XCTAssertNotNil(fast, text)
                XCTAssertEqual(
                    fast?.timeIntervalSince1970 ?? 0, slow?.timeIntervalSince1970 ?? -1, accuracy: 0.0005,
                    text)
            }
        }
    }

    func testOffsetsFractionsAndRejections() {
        let parse = TranscriptDates.parseRFC3339
        XCTAssertEqual(
            parse("2026-09-22T06:46:26.949Z")?.timeIntervalSince1970 ?? 0, 1_790_059_586.949, accuracy: 0.0005
        )
        XCTAssertEqual(parse("2026-09-22T14:46:26+08:00"), parse("2026-09-22T06:46:26Z"))
        XCTAssertEqual(parse("2026-09-21T22:46:26-08:00"), parse("2026-09-22T06:46:26Z"))
        XCTAssertEqual(parse("2024-02-29T00:00:00Z"), Date(timeIntervalSince1970: 1_709_164_800))
        XCTAssertEqual(
            parse("2026-09-22T06:46:26.123456789Z")?.timeIntervalSince1970 ?? 0, 1_790_059_586.123457,
            accuracy: 0.000_01)
        for invalid in [
            "", "not-a-date", "2026-09-22", "2026-02-29T00:00:00Z", "2026-13-01T00:00:00Z",
            "2026-09-22T24:00:00Z", "2026-09-22T06:46:26", "2026-09-22T06:46:26.Z",
            "2026-09-22T06:46:26Zjunk", "2026-09-22 06:46:26Z",
        ] {
            XCTAssertNil(parse(invalid), invalid)
        }
        XCTAssertNotNil(TranscriptDates().parse("2026-09-22T06:46:26.949Z"))
        XCTAssertNil(TranscriptDates().parse("not-a-date"))
    }
}
