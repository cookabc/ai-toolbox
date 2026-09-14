import AppKit
import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var model: UsageViewModel

    init() {
        // Preserve the selected tool when upgrading from the previous bundle ID.
        let preferences = UserDefaults.standard
        if preferences.string(forKey: "selectedUsageProvider") == nil,
           let previous = preferences.persistentDomain(forName: "local.zcode.usage-menu")?["selectedUsageProvider"] as? String,
           UsageProviderID(rawValue: previous) != nil {
            preferences.set(previous, forKey: "selectedUsageProvider")
        }
        let codexRoot = UsageProviderID.codex.directory
        let usageModel = UsageViewModel(providers: [
            ZCodeUsageProvider(),
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
}
