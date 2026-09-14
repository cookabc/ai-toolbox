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
    private var now: @Sendable () -> Date = { Date() }

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

    init(providers: [any UsageProvider], preferences: UserDefaults? = .standard,
         now: @escaping @Sendable () -> Date = { Date() }) {
        loaders = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider.id, { try provider.load() } as UsageLoader)
        })
        pricesURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/cli/usage-prices.json")
        self.preferences = preferences
        self.now = now
        let saved = preferences?.string(forKey: "selectedUsageProvider")
        selectedProvider = saved.flatMap(UsageProviderID.init(rawValue:)) ?? .overview
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
                guard let snapshot = states[id]?.snapshot, isToday(id),
                      (snapshot.coverage.todayMetrics ?? snapshot.coverage.metrics).contains(.output) else { return nil }
                return snapshot.today.outputTokens
            }
            guard !values.isEmpty else { return "总览 —" }
            let total = values.reduce(Int64(0)) { a, b in
                let (sum, overflow) = a.addingReportingOverflow(b)
                return overflow ? Int64.max : sum
            }
            let partial = values.count < sourceIDs.count || sourceIDs.contains { sourceWarning($0) != nil }
            return "总览 \(Format.token(total)) 输出\(partial ? "（部分）" : "")"
        }
        guard let snapshot, isToday(selectedProvider),
              (snapshot.coverage.todayMetrics ?? snapshot.coverage.metrics).contains(.output) else { return "\(selectedProvider.title) —" }
        return "\(selectedProvider.title) \(Format.token(snapshot.today.outputTokens)) 输出\(sourceWarning(selectedProvider) == nil ? "" : "（部分）")"
    }

    func isToday(_ id: UsageProviderID) -> Bool {
        guard let snapshot = states[id]?.snapshot else { return false }
        return Calendar.current.isDate(snapshot.refreshedAt, inSameDayAs: now())
    }

    func sourceWarning(_ id: UsageProviderID) -> String? {
        guard let state = states[id], let snapshot = state.snapshot else { return nil }
        if !isToday(id) { return "今日数据尚未更新；累计显示上次成功数据" }
        if state.errorMessage != nil { return "刷新失败，显示上次成功数据" }
        if snapshot.coverage.skippedRecords > 0 { return "有 \(snapshot.coverage.skippedRecords) 条记录无法确认用量；已读取的数据仍可查看" }
        if snapshot.coverage.hasUndatedRecords { return "部分用量记录没有时间，仅计入累计" }
        return nil
    }

    func todayDisplay(_ value: Int64, metric: UsageMetric, provider: UsageProviderID? = nil) -> String {
        let id = provider ?? selectedProvider
        guard isToday(id), let snapshot = states[id]?.snapshot,
              (snapshot.coverage.todayMetrics ?? snapshot.coverage.metrics).contains(metric) else { return "—" }
        return Format.token(value)
    }

    var lastCheckedAt: Date? {
        if selectedProvider == .overview { return nil }
        return states[selectedProvider]?.snapshot?.refreshedAt
    }

    func supports(_ metric: UsageMetric) -> Bool {
        snapshot?.coverage.metrics.contains(metric) == true
    }

    func display(_ value: Int64, metric: UsageMetric) -> String {
        supports(metric) ? Format.token(value) : "—"
    }

    var optionalOutputCost: Double? {
        guard selectedProvider == .zcode, let snapshot else { return nil }
        let priced = snapshot.models.compactMap { model -> Double? in
            guard let price = prices[model.modelID]?.output, price.isFinite, price >= 0 else { return nil }
            return (Double(model.outputTokens) / 1_000_000) * price
        }
        guard !priced.isEmpty else { return nil }
        let total = priced.reduce(0, +)
        return total.isFinite ? total : nil
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
