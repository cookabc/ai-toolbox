import Foundation
import XCTest
@testable import AIUsage

@MainActor
final class MultiProviderTests: XCTestCase {
    func testSwitchingAndFailureIsolation() async throws {
        let model = UsageViewModel(providers: [
            FakeProvider(id: .zcode, fails: false),
            FakeProvider(id: .codex, fails: true),
            FakeProvider(id: .claude, fails: false)
        ], preferences: nil)
        model.refreshAll()
        for _ in 0..<200 {
            if model.sourceIDs.allSatisfy({ model.states[$0]?.isRefreshing == false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.availableSources, [.zcode, .claude])
        model.selectedProvider = .codex
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.display(0, metric: .tools), "—")
        model.selectedProvider = .claude
        XCTAssertNotNil(model.snapshot)
        XCTAssertNil(model.errorMessage)
        model.selectedProvider = .overview
        XCTAssertTrue(model.statusText.contains("总览"))
        model.stop()
    }

    func testSelectionPersistsAndDoesNotLeakOtherSourceSnapshot() throws {
        let suite = "MultiProviderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providers = [FakeProvider(id: .zcode, fails: false), FakeProvider(id: .claude, fails: false)]
        let model = UsageViewModel(providers: providers, preferences: defaults)
        model.selectedProvider = .claude
        XCTAssertEqual(UsageViewModel(providers: providers, preferences: defaults).selectedProvider, .claude)
        XCTAssertNil(model.snapshot)
    }

    func testLocalSourcesWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["USAGE_LOCAL_SMOKE"] == "1" else {
            throw XCTSkip("Optional local aggregate-only smoke test")
        }
        for provider: any UsageProvider in [ZCodeUsageProvider(), CodexUsageProvider(), ClaudeUsageProvider()] {
            let start = Date()
            let snapshot = try provider.load()
            XCTAssertGreaterThan(snapshot.totals.requests, 0)
            print("\(provider.id.rawValue): records=\(snapshot.totals.requests), files=\(snapshot.coverage.fileCount), skipped=\(snapshot.coverage.skippedRecords), elapsed=\(Date().timeIntervalSince(start))s")
        }
    }
}

private struct FakeProvider: UsageProvider {
    let id: UsageProviderID
    let fails: Bool
    func load() throws -> UsageSnapshot {
        if fails { throw ProviderReadError.noRecords(id) }
        return .empty
    }
}
