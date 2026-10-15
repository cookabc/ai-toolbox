import Foundation
import SwiftUI

typealias UsageLoader = @Sendable () throws -> UsageSnapshot

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var states: [UsageProviderID: ProviderState] = [:] {
        didSet { PerfSignpost.publish("states") }
    }
    @Published var selectedProvider: UsageProviderID = .codex {
        didSet { preferences?.set(selectedProvider.rawValue, forKey: Self.selectionKey) }
    }

    static let refreshInterval: TimeInterval = 30

    private let loaders: [UsageProviderID: UsageLoader]
    private let preferences: UserDefaults?
    private let now: @Sendable () -> Date
    private var refreshTimer: Timer?
    private var generations: [UsageProviderID: Int] = [:]
    private var lastPanelRefresh = Date.distantPast

    private static let selectionKey = "selectedUsageProvider"

    var snapshot: UsageSnapshot? { states[selectedProvider]?.snapshot }
    var errorMessage: String? { states[selectedProvider]?.errorMessage }
    var isRefreshing: Bool { states[selectedProvider]?.showsProgress == true }
    var sourceIDs: [UsageProviderID] {
        UsageProviderID.allCases.filter { loaders[$0] != nil }
    }

    init(loader: @escaping UsageLoader, now: @escaping @Sendable () -> Date = { Date() }) {
        loaders = [.codex: loader]
        preferences = nil
        self.now = now
    }

    init(providers: [any UsageProvider], preferences: UserDefaults? = .standard,
         now: @escaping @Sendable () -> Date = { Date() }) {
        loaders = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider.id, { try provider.load() } as UsageLoader)
        })
        self.preferences = preferences
        self.now = now
        selectedProvider = UsageProviderID(rawValue: preferences?.string(forKey: Self.selectionKey) ?? "") ?? .codex
    }

    func start() {
        guard refreshTimer == nil else { return }
        refreshAll()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSelected() }
        }
        // Lets the system batch this wakeup with others; the exact second never matters.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        var updated = states
        var changed = false
        for id in sourceIDs {
            generations[id, default: 0] += 1
            guard var state = updated[id], state.isRefreshing || state.showsProgress else { continue }
            state.isRefreshing = false
            state.showsProgress = false
            updated[id] = state
            changed = true
        }
        if changed { states = updated }
    }

    /// A manual refresh of the selected tool. Shows progress.
    func refresh() {
        refresh(selectedProvider, visible: true)
    }

    /// Opening the panel should never show numbers that are half a minute old, but
    /// clicking the icon twice in a row should not queue two reads either.
    func panelDidOpen() {
        let instant = now()
        guard instant.timeIntervalSince(lastPanelRefresh) > 5 else { return }
        lastPanelRefresh = instant
        refreshAll()
    }

    func refreshAll() {
        for id in sourceIDs { refresh(id, visible: false) }
    }

    /// The periodic read covers only the tool on screen. Reading the others every
    /// interval would re-render the panel for numbers nobody is looking at; a tab
    /// switch reads its own tool instead.
    func refreshSelected() {
        refresh(selectedProvider, visible: false)
    }

    /// Selecting a tab is when the other tool's figures become something the user is
    /// waiting for, so the read the timer no longer performs for it happens here.
    func select(_ id: UsageProviderID) {
        selectedProvider = id
        refresh(id, visible: states[id]?.snapshot == nil)
    }

    private func refresh(_ id: UsageProviderID, visible: Bool) {
        guard let loader = loaders[id] else { return }
        var state = states[id] ?? ProviderState()
        // Nothing on screen yet means the user is waiting, whatever started the read.
        let shouldShow = visible || state.snapshot == nil
        guard state.isRefreshing != true else {
            if shouldShow, state.showsProgress != true {
                state.showsProgress = true
                states[id] = state
            }
            return
        }
        // One published write per phase: the panel observes the whole dictionary, so
        // each extra mutation here is another full render.
        state.isRefreshing = true
        state.showsProgress = shouldShow
        states[id] = state
        generations[id, default: 0] += 1
        let generation = generations[id, default: 0]
        Task {
            let result = await Task.detached(priority: .utility) {
                Result<UsageSnapshot, Error> { try loader() }
            }.value
            guard generations[id] == generation else { return }
            var settled = states[id] ?? ProviderState()
            settled.isRefreshing = false
            settled.showsProgress = false
            switch result {
            case .success(let snapshot):
                settled.snapshot = snapshot
                settled.errorMessage = nil
            case .failure(let error):
                settled.errorMessage = error.localizedDescription
            }
            states[id] = settled
        }
    }

    // MARK: - Reading the selected tool

    /// Whether the last successful read happened today. A read from yesterday knows
    /// nothing about today, so today's figures are unknown rather than zero.
    func isCurrent(_ id: UsageProviderID) -> Bool {
        guard let snapshot = states[id]?.snapshot else { return false }
        return Calendar.current.isDate(snapshot.refreshedAt, inSameDayAs: now())
    }

    func today(_ id: UsageProviderID? = nil) -> UsageTotals? {
        let id = id ?? selectedProvider
        guard isCurrent(id), let snapshot = states[id]?.snapshot else { return nil }
        return snapshot.totals(on: now())
    }

    func recentDays(_ count: Int) -> [DailyUsage] {
        snapshot?.recentDays(count, endingAt: now()) ?? []
    }

    var currentDate: Date { now() }

    /// What the menu-bar item says to VoiceOver.
    var statusText: String {
        L10n.App.menuBarStatus(tool: selectedProvider.title, todayOutput: today().map { Format.token($0.outputTokens) })
    }

    func sourceWarning(_ id: UsageProviderID) -> String? {
        guard let state = states[id], let snapshot = state.snapshot else { return nil }
        if state.errorMessage != nil { return L10n.Usage.staleAfterFailure }
        if !isCurrent(id) { return L10n.Usage.notReadToday }
        let coverage = snapshot.coverage
        if coverage.skippedRecords > 0 {
            return L10n.Usage.skippedRecords(coverage.skippedRecords)
        }
        if coverage.undatedRecords > 0 {
            return L10n.Usage.undatedRecords(coverage.undatedRecords)
        }
        return nil
    }

    func reports(_ metric: UsageMetric) -> Bool {
        snapshot?.coverage.reported.contains(metric) == true
    }

    /// A metric no record reports is unknown, which reads as "—", not "0".
    func display(_ value: Int64, _ metric: UsageMetric) -> String {
        reports(metric) ? Format.token(value) : L10n.Usage.unknown
    }
}
