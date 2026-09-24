import AppKit
import SwiftUI

@main
struct AIToolboxApp: App {
    @StateObject private var model: UsageViewModel

    init() {
        UserDefaults.standard.set(0.05, forKey: "NSInitialToolTipDelay")
        Self.migrateLegacyPreferencesIfNeeded()
        let usageModel = UsageViewModel(providers: [
            TranscriptUsageProvider(.codex),
            TranscriptUsageProvider(.claude),
        ])
        usageModel.start() // Prewarm before the first menu-bar click.
        _model = StateObject(wrappedValue: usageModel)
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
        } label: {
            MenuBarLabel(model: model)
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

/// The menu-bar item: a glyph and today's output for the selected tool. Kept to
/// one short number, because the menu bar is shared with everything else the user
/// runs and a crowded one hides items behind the notch. A `Label` because that is
/// what `MenuBarExtra` reliably renders into a status item.
private struct MenuBarLabel: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        Label(model.today().map { Format.token($0.outputTokens) } ?? "—", systemImage: "chart.bar.fill")
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(model.statusText)
    }
}
