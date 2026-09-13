import Foundation
import XCTest
@testable import ZCodeUsageMenu

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
