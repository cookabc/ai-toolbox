import Foundation
import SwiftUI

typealias UsageLoader = @Sendable () throws -> UsageSnapshot

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var states: [UsageProviderID: ProviderState] = [:]
    @Published var selectedProvider: UsageProviderID = .zcode {
        didSet { preferences?.set(selectedProvider.rawValue, forKey: "selectedUsageProvider") }
    }

    private let loaders: [UsageProviderID: UsageLoader]
    private let pricesURL: URL
    private let preferences: UserDefaults?
    private var prices: [String: UsagePrice] = [:]
    private var refreshTimer: Timer?
    private var hasStarted = false
    private var generations: [UsageProviderID: Int] = [:]

    var snapshot: UsageSnapshot? { states[selectedProvider]?.snapshot }
    var errorMessage: String? { states[selectedProvider]?.errorMessage }
    var isRefreshing: Bool {
        if selectedProvider == .overview { return states.values.contains { $0.isRefreshing } }
        return states[selectedProvider]?.isRefreshing ?? false
    }
    var availableSources: [UsageProviderID] {
        UsageProviderID.allCases.filter { $0 != .overview && states[$0]?.snapshot != nil }
    }
    var sourceIDs: [UsageProviderID] {
        UsageProviderID.allCases.filter { $0 != .overview && loaders[$0] != nil }
    }

    init(
        repository: UsageRepository = UsageRepository(),
        pricesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/cli/usage-prices.json")
    ) {
        loaders = [.zcode: { try repository.load() }]
        self.pricesURL = pricesURL
        preferences = nil
    }

    init(
        loader: @escaping UsageLoader,
        pricesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/cli/usage-prices.json")
    ) {
        loaders = [.zcode: loader]
        self.pricesURL = pricesURL
        preferences = nil
    }

    init(providers: [any UsageProvider], preferences: UserDefaults? = .standard) {
        loaders = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider.id, { try provider.load() } as UsageLoader)
        })
        pricesURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/cli/usage-prices.json")
        self.preferences = preferences
        if let saved = preferences?.string(forKey: "selectedUsageProvider"),
           let id = UsageProviderID(rawValue: saved) { selectedProvider = id }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshAll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasStarted = false
        for id in sourceIDs {
            generations[id, default: 0] += 1
            states[id, default: ProviderState()].isRefreshing = false
        }
    }

    func refresh() {
        if selectedProvider == .overview { refreshAll() }
        else { refresh(selectedProvider) }
    }

    func refreshAll() { for id in sourceIDs { refresh(id) } }

    private func refresh(_ id: UsageProviderID) {
        guard let loader = loaders[id], states[id]?.isRefreshing != true else { return }
        states[id, default: ProviderState()].isRefreshing = true
        generations[id, default: 0] += 1
        let generation = generations[id, default: 0]
        let pricesURL = pricesURL
        Task {
            let result = await Task.detached(priority: .utility) {
                Result<RefreshPayload, Error> {
                    RefreshPayload(snapshot: try loader(), prices: id == .zcode ? Self.loadPrices(at: pricesURL) : [:])
                }
            }.value
            guard generations[id] == generation else { return }
            states[id, default: ProviderState()].isRefreshing = false
            switch result {
            case .success(let payload):
                states[id, default: ProviderState()].snapshot = payload.snapshot
                states[id, default: ProviderState()].errorMessage = nil
                if id == .zcode { prices = payload.prices }
            case .failure(let error):
                states[id, default: ProviderState()].errorMessage = error.localizedDescription
            }
        }
    }

    var statusText: String {
        if selectedProvider == .overview {
            let values = availableSources.compactMap { id -> Int64? in
                guard let snapshot = states[id]?.snapshot, snapshot.coverage.metrics.contains(.output) else { return nil }
                return snapshot.today.outputTokens
            }
            guard !values.isEmpty else { return "总览 —" }
            let total = values.reduce(Int64(0)) { a, b in
                let (sum, overflow) = a.addingReportingOverflow(b)
                return overflow ? Int64.max : sum
            }
            return "总览 \(Format.token(total)) 输出\(values.count < sourceIDs.count ? "（部分）" : "")"
        }
        guard let snapshot, snapshot.coverage.metrics.contains(.output) else { return "\(selectedProvider.title) —" }
        return "\(selectedProvider.title) \(Format.token(snapshot.today.outputTokens)) 输出"
    }

    func supports(_ metric: UsageMetric) -> Bool {
        snapshot?.coverage.metrics.contains(metric) == true
    }

    func display(_ value: Int64, metric: UsageMetric) -> String {
        supports(metric) ? Format.token(value) : "—"
    }

    var optionalOutputCost: Double? {
        guard selectedProvider == .zcode, let snapshot else { return nil }
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
