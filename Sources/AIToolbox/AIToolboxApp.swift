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
    usageModel.start()  // Prewarm before the first menu-bar click.
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
      let legacy = UserDefaults(suiteName: legacyBundleIdentifier)
    else { return }
    for key in ["selectedUsageProvider", "selectedTool"] {
      if let value = legacy.string(forKey: key) {
        preferences.set(value, forKey: key)
      }
    }
  }
}

/// Keep the menu-bar item icon-only. The selected tool's output stays in the panel
/// and in the accessibility label; switching tools cannot change the item's width.
struct MenuBarLabel: View {
  @ObservedObject var model: UsageViewModel

  var body: some View {
    Label("用量", systemImage: "chart.bar.fill")
      .labelStyle(.iconOnly)
      .accessibilityLabel(model.statusText)
  }
}
