import SwiftUI

/// Identifiers for the controls an automated test has to find.
///
/// These are a contract with the harness: labels and layout change freely, an
/// identifier must not, because a renamed one fails the smoke test silently — the
/// test simply finds nothing.
enum PanelID {
  static let refresh = "panel.refresh"
  static let openDataDirectory = "panel.openDataDirectory"
  static let quit = "panel.quit"
  static let modeUsage = "panel.modeUsage"
  static let modeConfig = "panel.modeConfig"
  static let dialogConfirm = "panel.dialogConfirm"
  static let dialogCancel = "panel.dialogCancel"

  /// A tool tab. The raw value is the stable part, so a new tool needs no new name here.
  static func tool(_ app: LiveConfigApp) -> String { "panel.tool.\(app.rawValue)" }

  /// The usage page's card for a tool tab.
  static let todayCard = "panel.card.today"
  static let trendCard = "panel.card.trend"
  static let lifetimeCard = "panel.card.lifetime"
  static let modelsCard = "panel.card.models"

  static let configSave = "panel.configSave"
  static let configSaveAndSwitch = "panel.configSaveAndSwitch"
  static let configCancelDraft = "panel.configCancelDraft"
  static let configAddProvider = "panel.configAddProvider"
  static let configAdvanced = "panel.configAdvanced"
}

extension View {
  /// Tag a control for the harness. Separate from `.accessibilityLabel` because the
  /// label is user-facing text that localisation moves.
  func panelID(_ id: String) -> some View {
    accessibilityIdentifier(id)
  }
}
