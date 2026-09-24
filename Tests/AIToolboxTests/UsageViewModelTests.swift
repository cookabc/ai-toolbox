import Foundation
import XCTest
@testable import AIToolbox

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
        XCTAssertEqual(model.today()?.outputTokens, 42_000)
        XCTAssertNil(model.errorMessage)
    }

    func testFailureKeepsLastSuccessfulSnapshot() async throws {
        let loader = SequencedLoader([
            .success(makeSnapshot(todayOutput: 1_000)),
            .failure(ProviderReadError.incompatible(.codex)),
        ])
        let model = UsageViewModel(loader: loader.load)

        model.refresh()
        try await waitUntil { !model.isRefreshing }
        let first = model.snapshot
        XCTAssertEqual(model.today()?.outputTokens, 1_000)

        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.snapshot, first)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(model.sourceWarning(.codex))
    }

    /// A background refresh must not flash progress in the header when there is
    /// already something on screen; the first read, with nothing to show, must.
    func testTimerRefreshesAreSilentOnceDataIsShown() async throws {
        let gate = BlockingLoader(result: .success(makeSnapshot(todayOutput: 1)))
        let model = UsageViewModel(loader: gate.load)
        model.refreshAll()
        XCTAssertTrue(model.isRefreshing, "nothing on screen yet, so the first read is visible")
        gate.release.signal()
        try await waitUntil { !model.isRefreshing }

        model.refreshAll()
        try await waitUntil { gate.callCount == 2 }
        XCTAssertFalse(model.isRefreshing)
        gate.release.signal()
        try await waitUntil { model.states[.codex]?.isRefreshing == false }
    }

    func testManualRefreshDuringASilentOneBecomesVisible() async throws {
        let gate = BlockingLoader(result: .success(makeSnapshot(todayOutput: 1)))
        let model = UsageViewModel(loader: gate.load)
        model.refresh()
        gate.release.signal()
        try await waitUntil { !model.isRefreshing }

        model.refreshAll()
        try await waitUntil { gate.callCount == 2 }
        model.refresh()
        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(gate.callCount, 2, "joins the read in flight instead of starting another")
        gate.release.signal()
        try await waitUntil { !model.isRefreshing }
    }

    func testPreviousDaySnapshotHasNoToday() async throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        var old = makeSnapshot(todayOutput: 1_000, on: yesterday)
        old.refreshedAt = yesterday
        let fixture = old
        let model = UsageViewModel(loader: { fixture })
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertNil(model.today())
        XCTAssertEqual(model.statusText, "Codex 今日输出暂无")
        XCTAssertNotNil(model.sourceWarning(.codex))
        XCTAssertEqual(model.snapshot?.totals, old.totals)
    }

    /// The snapshot holds days, not "today": after midnight the same snapshot must
    /// report the new day as empty, not keep yesterday's number.
    func testTodayComesFromTheCurrentDate() async throws {
        let clock = Clock(Date())
        let model = UsageViewModel(loader: { [snapshot = makeSnapshot(todayOutput: 500)] in snapshot },
                                   now: { clock.now })
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.today()?.outputTokens, 500)
        XCTAssertEqual(model.recentDays(7).last?.totals.outputTokens, 500)
        clock.now = Calendar.current.date(byAdding: .day, value: 1, to: clock.now)!
        XCTAssertNil(model.today(), "a read from yesterday knows nothing about today")
    }

    func testUnreportedMetricsReadAsUnknown() async throws {
        var snapshot = makeSnapshot(todayOutput: 1)
        snapshot.coverage.reported = [.cacheRead]
        let fixture = snapshot
        let model = UsageViewModel(loader: { fixture })
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.display(0, .cacheRead), "0")
        XCTAssertEqual(model.display(0, .reasoning), "—")
    }

    func testPartialCoverageIsExplained() async throws {
        var snapshot = makeSnapshot(todayOutput: 1_000)
        snapshot.coverage.skippedRecords = 3
        let fixture = snapshot
        let model = UsageViewModel(loader: { fixture })
        model.refresh()
        try await waitUntil { !model.isRefreshing }
        XCTAssertEqual(model.statusText, "Codex 今日输出 1.0k")
        XCTAssertTrue(model.sourceWarning(.codex)?.contains("3") == true)
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

    func testOpeningThePanelTwiceInARowReadsOnce() async throws {
        let gate = BlockingLoader(result: .success(makeSnapshot(todayOutput: 1)))
        let model = UsageViewModel(loader: gate.load)
        model.panelDidOpen()
        gate.release.signal()
        try await waitUntil { !model.isRefreshing }
        model.panelDidOpen()
        XCTAssertEqual(gate.callCount, 1)
    }

    func testUnknownSavedSelectionFallsBackToCodex() throws {
        let suite = "UsageViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("overview", forKey: "selectedUsageProvider")
        let model = UsageViewModel(
            providers: [FakeProvider(id: .codex), FakeProvider(id: .claude)],
            preferences: defaults
        )
        XCTAssertEqual(model.selectedProvider, .codex)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
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

    private func makeSnapshot(todayOutput: Int64, on date: Date = Date()) -> UsageSnapshot {
        let today = UsageTotals(requests: 3, turns: 2, toolCalls: 1, inputTokens: 5_000,
                                cacheReadTokens: 4_000, outputTokens: todayOutput, reasoningTokens: 100)
        return UsageSnapshot(
            refreshedAt: date,
            totals: UsageTotals(requests: 20, turns: 10, toolCalls: 4, inputTokens: 100_000,
                                cacheReadTokens: 90_000, outputTokens: todayOutput + 5_000, reasoningTokens: 1_000),
            daily: [DailyUsage(date: Calendar.current.startOfDay(for: date), totals: today)],
            models: []
        )
    }
}

private struct FakeProvider: UsageProvider {
    let id: UsageProviderID
    func load() throws -> UsageSnapshot { .empty }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class BlockingLoader: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private let result: Result<UsageSnapshot, Error>

    init(result: Result<UsageSnapshot, Error>) {
        self.result = result
    }

    var callCount: Int { lock.withLock { calls } }
    var hasStarted: Bool { callCount > 0 }

    func load() throws -> UsageSnapshot {
        lock.withLock { calls += 1 }
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
        try lock.withLock { results.removeFirst() }.get()
    }
}
