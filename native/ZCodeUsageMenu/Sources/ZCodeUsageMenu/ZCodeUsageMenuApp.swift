import AppKit
import SwiftUI

@main
struct ZCodeUsageMenuApp: App {
    @StateObject private var model: UsageViewModel

    init() {
        let usageModel = UsageViewModel()
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
