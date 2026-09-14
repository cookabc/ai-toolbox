import AppKit
import SwiftUI

@main
struct ZCodeUsageMenuApp: App {
    @StateObject private var model: UsageViewModel

    init() {
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
