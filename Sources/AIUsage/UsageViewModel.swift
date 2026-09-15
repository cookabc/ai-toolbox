import Foundation
import SwiftUI

typealias UsageLoader = @Sendable () throws -> UsageSnapshot

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var states: [UsageProviderID: ProviderState] = [:]
    @Published var selectedProvider: UsageProviderID = .codex {
        didSet { preferences?.set(selectedProvider.rawValue, forKey: "selectedUsageProvider") }
    }

    private let loaders: [UsageProviderID: UsageLoader]
    private let preferences: UserDefaults?
    private var refreshTimer: Timer?
    private var hasStarted = false
    private var generations: [UsageProviderID: Int] = [:]
    private var now: @Sendable () -> Date = { Date() }

    var snapshot: UsageSnapshot? { states[selectedProvider]?.snapshot }
    var errorMessage: String? { states[selectedProvider]?.errorMessage }
    var isRefreshing: Bool {
        states.values.contains { $0.isRefreshing }
    }
    var sourceIDs: [UsageProviderID] {
        UsageProviderID.allCases.filter { loaders[$0] != nil }
    }

    init(loader: @escaping UsageLoader) {
        loaders = [.codex: loader]
        preferences = nil
    }

    init(providers: [any UsageProvider], preferences: UserDefaults? = .standard,
         now: @escaping @Sendable () -> Date = { Date() }) {
        loaders = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider.id, { try provider.load() } as UsageLoader)
        })
        self.preferences = preferences
        self.now = now
        selectedProvider = Self.restoredProvider(from: preferences?.string(forKey: "selectedUsageProvider"))
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
        refresh(selectedProvider)
    }

    func refreshAll() { for id in sourceIDs { refresh(id) } }

    private func refresh(_ id: UsageProviderID) {
        guard let loader = loaders[id], states[id]?.isRefreshing != true else { return }
        states[id, default: ProviderState()].isRefreshing = true
        generations[id, default: 0] += 1
        let generation = generations[id, default: 0]
        Task {
            let result = await Task.detached(priority: .utility) {
                Result<UsageSnapshot, Error> { try loader() }
            }.value
            guard generations[id] == generation else { return }
            states[id, default: ProviderState()].isRefreshing = false
            switch result {
            case .success(let snapshot):
                states[id, default: ProviderState()].snapshot = snapshot
                states[id, default: ProviderState()].errorMessage = nil
            case .failure(let error):
                states[id, default: ProviderState()].errorMessage = error.localizedDescription
            }
        }
    }

    var statusText: String {
        guard let snapshot, isToday(selectedProvider),
              (snapshot.coverage.todayMetrics ?? snapshot.coverage.metrics).contains(.output) else {
            return "\(selectedProvider.title) —"
        }
        let partial = sourceWarning(selectedProvider) != nil ? "（部分）" : ""
        return "\(selectedProvider.title) \(Format.token(snapshot.today.outputTokens)) 输出\(partial)"
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
        states[selectedProvider]?.snapshot?.refreshedAt
    }

    func supports(_ metric: UsageMetric) -> Bool {
        snapshot?.coverage.metrics.contains(metric) == true
    }

    func display(_ value: Int64, metric: UsageMetric) -> String {
        supports(metric) ? Format.token(value) : "—"
    }

    private static func restoredProvider(from saved: String?) -> UsageProviderID {
        switch saved {
        case UsageProviderID.claude.rawValue: .claude
        case UsageProviderID.codex.rawValue: .codex
        default: .codex
        }
    }
}
