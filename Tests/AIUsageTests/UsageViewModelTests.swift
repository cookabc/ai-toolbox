import Foundation
import XCTest
@testable import AIUsage

@MainActor
final class UsageViewModelTests: XCTestCase {
    func testRefreshReturnsImmediatelyWhileLoaderRunsInBackground() async throws {
        let gate = BlockingLoader(result: .success(makeSnapshot(todayOutput: 42_000)))
        let model = UsageViewModel(loader: gate.load)

        let startedAt = ContinuousClock.now
        model.refresh()
        let elapsed = startedAt.duration(to: .now)

        XCTAssertTrue(model.isRefreshing)
        XCTAssertLessThan(elapsed, .milliseconds(50), "refresh must schedule work, not block the main actor")
        try await waitUntil { gate.hasStarted }

        gate.release.signal()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.snapshot?.today.outputTokens, 42_000)
        XCTAssertNil(model.errorMessage)
    }

    func testFailureKeepsLastSuccessfulSnapshot() async throws {
        let loader = SequencedLoader([
            .success(makeSnapshot(todayOutput: 1_000)),
            .failure(UsageError.query("temporary database lock")),
        ])
        let model = UsageViewModel(loader: loader.load)

        model.refresh()
        try await waitUntil { !model.isRefreshing }
        let first = model.snapshot
        XCTAssertEqual(first?.today.outputTokens, 1_000)

        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.snapshot, first)
        XCTAssertTrue(model.errorMessage?.contains("temporary database lock") == true)
        XCTAssertTrue(model.statusText.contains("部分"))
        model.selectedProvider = .overview
        XCTAssertTrue(model.statusText.contains("部分"))
    }

    func testPreviousDaySnapshotIsExcludedFromTodayAndOverview() async throws {
        let original = makeSnapshot(todayOutput: 1_000)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let old = UsageSnapshot(refreshedAt: yesterday, totals: original.totals,
                                today: original.today, models: [])
        let model = UsageViewModel(loader: { old })
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.todayDisplay(1_000, metric: .output), "—")
        XCTAssertEqual(model.statusText, "ZCode —")
        XCTAssertNotNil(model.sourceWarning(.zcode))
        XCTAssertEqual(model.snapshot?.totals, original.totals)
        model.selectedProvider = .overview
        XCTAssertEqual(model.statusText, "总览 —")
    }

    func testPartialRecordsMarkOverviewAndTodayCoverageIsIndependent() async throws {
        var snapshot = makeSnapshot(todayOutput: 1_000)
        snapshot.coverage.metrics.remove(.output)
        snapshot.coverage.todayMetrics = [.output]
        snapshot.coverage.skippedRecords = 1
        let fixture = snapshot
        let model = UsageViewModel(loader: { fixture })
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.display(1_000, metric: .output), "—")
        XCTAssertEqual(model.todayDisplay(1_000, metric: .output), "1k")
        model.selectedProvider = .overview
        XCTAssertEqual(model.statusText, "总览 1k 输出（部分）")
    }

    func testCostUsesAllPricedModelsAndIgnoresInvalidPrices() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"m0":{"output":1},"m4":{"output":2},"m5":{"output":-10}}"#.utf8).write(to: url)
        let models = (0..<6).map {
            ModelUsage(modelID: "m\($0)", providerID: "p", requests: 1, outputTokens: 1_000_000)
        }
        let snapshot = UsageSnapshot(refreshedAt: .now, totals: .zero, today: .zero, models: models)
        let model = UsageViewModel(loader: { snapshot }, pricesURL: url)
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.optionalOutputCost, 3)
    }

    func testSecondRefreshDoesNotStartOverlappingRead() async throws {
        let gate = BlockingLoader(result: .success(makeSnapshot(todayOutput: 7)))
        let model = UsageViewModel(loader: gate.load)

        model.refresh()
        try await waitUntil { gate.hasStarted }
        model.refresh()
        XCTAssertEqual(gate.callCount, 1)

        gate.release.signal()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(gate.callCount, 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for async refresh")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSnapshot(todayOutput: Int64) -> UsageSnapshot {
        UsageSnapshot(
            refreshedAt: .now,
            totals: UsageTotals(
                turns: 10, requests: 20, inputTokens: 100_000, outputTokens: todayOutput,
                reasoningTokens: 1_000, cacheReadInputTokens: 90_000,
                cacheCreationInputTokens: 0, toolCalls: 4
            ),
            today: UsageTotals(
                turns: 2, requests: 3, inputTokens: 5_000, outputTokens: todayOutput,
                reasoningTokens: 100, cacheReadInputTokens: 4_000,
                cacheCreationInputTokens: 0, toolCalls: 1
            ),
            models: []
        )
    }
}

private final class BlockingLoader: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private let result: Result<UsageSnapshot, Error>

    init(result: Result<UsageSnapshot, Error>) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls > 0
    }

    func load() throws -> UsageSnapshot {
        lock.lock()
        calls += 1
        lock.unlock()
        started.signal()
        _ = release.wait(timeout: .now() + 2)
        return try result.get()
    }
}

private final class SequencedLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<UsageSnapshot, Error>]

    init(_ results: [Result<UsageSnapshot, Error>]) {
        self.results = results
    }

    func load() throws -> UsageSnapshot {
        lock.lock()
        let result = results.removeFirst()
        lock.unlock()
        return try result.get()
    }
}
