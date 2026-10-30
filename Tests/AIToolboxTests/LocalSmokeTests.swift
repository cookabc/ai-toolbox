import Foundation
import XCTest

@testable import AIToolbox

/// Reads this machine's real transcripts. Aggregates only; nothing is printed that
/// could identify a conversation.
final class LocalSmokeTests: XCTestCase {
    func testLocalSourcesWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["USAGE_LOCAL_SMOKE"] == "1" else {
            throw XCTSkip("Set USAGE_LOCAL_SMOKE=1 to read this machine's transcripts")
        }
        for id in UsageProviderID.allCases {
            let provider = TranscriptUsageProvider(id)
            let clock = ContinuousClock()
            let cold = clock.now
            let snapshot = try provider.load()
            let coldTime = clock.now - cold
            let warm = clock.now
            _ = try provider.load()
            let warmTime = clock.now - warm
            let t = snapshot.totals
            print(
                "SMOKE \(id.rawValue) files=\(snapshot.coverage.fileCount) req=\(t.requests) turns=\(t.turns) tools=\(t.toolCalls) in=\(t.inputTokens) cr=\(t.cacheReadTokens) cw=\(t.cacheWriteTokens) out=\(t.outputTokens) rs=\(t.reasoningTokens) skipped=\(snapshot.coverage.skippedRecords) undated=\(snapshot.coverage.undatedRecords) days=\(snapshot.daily.count) models=\(snapshot.models.map(\.modelID)) cold=\(coldTime) warm=\(warmTime)"
            )
        }
    }
}

final class StressTests: XCTestCase {
    /// Point `USAGE_STRESS_ROOT` at a generated Codex home to time a large history.
    func testLargeHistory() throws {
        guard let root = ProcessInfo.processInfo.environment["USAGE_STRESS_ROOT"] else {
            throw XCTSkip("Set USAGE_STRESS_ROOT to a synthetic Codex home")
        }
        let provider = TranscriptUsageProvider(.codex, rootURL: URL(fileURLWithPath: root))
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = try provider.load()
        let cold = clock.now - start
        let again = clock.now
        _ = try provider.load()
        let warm = clock.now - again
        let file = URL(fileURLWithPath: root).appending(path: "sessions/s0.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let appended = clock.now
        _ = try provider.load()
        print(
            "STRESS files=\(snapshot.coverage.fileCount) req=\(snapshot.totals.requests) tools=\(snapshot.totals.toolCalls) turns=\(snapshot.totals.turns) cold=\(cold) warm=\(warm) afterAppend=\(clock.now - appended)"
        )
    }
}

/// Parses this machine's real config files and simulates edits in memory. Never
/// writes, and prints no values.
final class LocalConfigSmokeTests: XCTestCase {
    func testRealConfigsRoundTripAndEditMinimally() throws {
        guard ProcessInfo.processInfo.environment["USAGE_LOCAL_SMOKE"] == "1" else {
            throw XCTSkip("Set USAGE_LOCAL_SMOKE=1 to parse this machine's config files")
        }
        let paths = LiveConfigPaths.default
        if let data = try ConfigFile.read(paths.codexConfig), let text = String(data: data, encoding: .utf8) {
            let document = try TomlDocument(text)
            XCTAssertEqual(document.text, text, "an untouched parse must round-trip exactly")
            let relay = try CodexTomlEditor.upsertProvider(
                text, id: "smoke-relay", name: "Smoke", baseURL: "https://smoke.test/v1",
                apiKey: "sk-simulated", makeCurrent: true, model: "smoke-model")
            let back = try CodexTomlEditor.removeProvider(relay, id: "smoke-relay")
            let before = Set(text.components(separatedBy: "\n"))
            let changed = back.components(separatedBy: "\n").filter { !before.contains($0) }
            let lost = text.components(separatedBy: "\n").filter {
                !Set(back.components(separatedBy: "\n")).contains($0)
            }
            print(
                "SMOKE codex statements=\(document.statements.count) tables=\(document.childTables(of: ["plugins"]).count) plugin tables; after switch+remove: added=\(changed.map { $0.split(separator: "=").first.map(String.init) ?? $0 }) lost=\(lost.map { $0.split(separator: "=").first.map(String.init) ?? $0 })"
            )
        }
        if let data = try ConfigFile.read(paths.claudeSettings) {
            let env = try ClaudeSettingsEditor.env(in: data)
            let same = ClaudeSettingsEditor.Edit(
                set: env.filter { !$0.key.contains("KEY") && !$0.key.contains("TOKEN") }
                    .sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) })
            let unchanged = try ClaudeSettingsEditor.apply(same, to: data)
            print("SMOKE claude envKeys=\(env.keys.sorted()) setSameValuesChangesBytes=\(unchanged != data)")
            let edited = try ClaudeSettingsEditor.apply(
                ClaudeSettingsEditor.Edit(set: [(key: "ANTHROPIC_MODEL", value: "smoke")]), to: data)
            let oldObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let newObject = try JSONSerialization.jsonObject(with: edited) as! [String: Any]
            print(
                "SMOKE claude topLevelKeys same=\(Set(oldObject.keys) == Set(newObject.keys)) otherValuesSame=\(NSDictionary(dictionary: oldObject.filter { $0.key != "env" }).isEqual(to: newObject.filter { $0.key != "env" }))"
            )
        }
    }
}
