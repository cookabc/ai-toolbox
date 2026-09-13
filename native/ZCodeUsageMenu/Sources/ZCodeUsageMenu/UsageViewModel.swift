import Foundation
import SwiftUI

typealias UsageLoader = @Sendable () throws -> UsageSnapshot

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private let loader: UsageLoader
    private let pricesURL: URL
    private var prices: [String: UsagePrice] = [:]
    private var refreshTimer: Timer?
    private var hasStarted = false

    init(
        repository: UsageRepository = UsageRepository(),
        pricesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/cli/usage-prices.json")
    ) {
        self.loader = { try repository.load() }
        self.pricesURL = pricesURL
    }

    init(
        loader: @escaping UsageLoader,
        pricesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/cli/usage-prices.json")
    ) {
        self.loader = loader
        self.pricesURL = pricesURL
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Schedules blocking disk/SQLite work off the main actor, so the popover can draw immediately.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let loader = loader
        let pricesURL = pricesURL
        Task {
            let result = await Task.detached(priority: .utility) {
                Result<RefreshPayload, Error> {
                    RefreshPayload(
                        snapshot: try loader(),
                        prices: Self.loadPrices(at: pricesURL)
                    )
                }
            }.value

            isRefreshing = false
            switch result {
            case .success(let payload):
                snapshot = payload.snapshot
                prices = payload.prices
                errorMessage = nil
            case .failure(let error):
                // Preserve the old snapshot when ZCode is writing/upgrading its database.
                errorMessage = error.localizedDescription
            }
        }
    }

    var statusText: String {
        guard let snapshot else { return "—" }
        return "\(Format.token(snapshot.today.outputTokens)) 输出"
    }

    var optionalOutputCost: Double? {
        guard let snapshot else { return nil }
        let total = snapshot.models.reduce(0.0) { result, model in
            result + (Double(model.outputTokens) / 1_000_000) * (prices[model.modelID]?.output ?? 0)
        }
        return total > 0 ? total : nil
    }

    nonisolated private static func loadPrices(at url: URL) -> [String: UsagePrice] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: UsagePrice].self, from: data)) ?? [:]
    }
}

private struct RefreshPayload: Sendable {
    let snapshot: UsageSnapshot
    let prices: [String: UsagePrice]
}
