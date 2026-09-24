import Foundation
import XCTest
@testable import AIToolbox

@MainActor
final class MultiProviderTests: XCTestCase {
    func testSwitchingAndFailureIsolation() async throws {
        let model = UsageViewModel(providers: [
            FakeProvider(id: .codex, fails: true),
            FakeProvider(id: .claude, fails: false),
        ], preferences: nil)
        model.refreshAll()
        for _ in 0..<200 {
            if model.sourceIDs.allSatisfy({ model.states[$0]?.isRefreshing == false }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.states[.claude]?.snapshot, .empty)
        model.selectedProvider = .codex
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.errorMessage)
        model.selectedProvider = .claude
        XCTAssertNotNil(model.snapshot)
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    func testSelectionPersistsAndDoesNotLeakOtherSourceSnapshot() throws {
        let suite = "MultiProviderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providers = [FakeProvider(id: .codex, fails: false), FakeProvider(id: .claude, fails: false)]
        let model = UsageViewModel(providers: providers, preferences: defaults)
        model.selectedProvider = .claude
        XCTAssertEqual(UsageViewModel(providers: providers, preferences: defaults).selectedProvider, .claude)
        XCTAssertNil(model.snapshot)
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
