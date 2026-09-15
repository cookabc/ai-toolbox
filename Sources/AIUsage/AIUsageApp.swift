import AppKit
import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var model: UsageViewModel

    init() {
        UserDefaults.standard.set(0.05, forKey: "NSInitialToolTipDelay")
        Self.migrateLegacyPreferencesIfNeeded()
        let codexRoot = UsageProviderID.codex.directory
        let usageModel = UsageViewModel(providers: [
            CachedTranscriptProvider(provider: CodexUsageProvider(), roots: [codexRoot.appending(path: "sessions"), codexRoot.appending(path: "archived_sessions")]),
            CachedTranscriptProvider(provider: ClaudeUsageProvider(), roots: [UsageProviderID.claude.directory])
        ])
        usageModel.start() // Prewarm before the first menu-bar click.
        _model = StateObject(wrappedValue: usageModel)
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
        } label: {
            Label(model.statusText, systemImage: "chart.bar.fill")
        }
        .menuBarExtraStyle(.window)
    }

    private static let legacyBundleIdentifier = "io.github.cookabc.ai-usage"

    private static func migrateLegacyPreferencesIfNeeded() {
        let preferences = UserDefaults.standard
        guard preferences.string(forKey: "selectedUsageProvider") == nil,
              let legacy = UserDefaults(suiteName: legacyBundleIdentifier) else { return }
        for key in ["selectedUsageProvider", "selectedTool"] {
            if let value = legacy.string(forKey: key) {
                preferences.set(value, forKey: key)
            }
        }
    }
}
