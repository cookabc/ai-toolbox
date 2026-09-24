import AppKit
import SwiftUI

@MainActor
enum ToolBrandIcon {
    /// Parsed once per tool. The tabs re-render on every refresh, and an SVG read
    /// from disk and rasterised each time is wasted work.
    private static var cache: [LiveConfigApp: NSImage] = [:]

    static func image(for app: LiveConfigApp) -> NSImage? {
        if let cached = cache[app] { return cached }
        let name = app == .claude ? "BrandClaude" : "BrandCodex"
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg")
                ?? Bundle.module.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        // The Codex mark is monochrome and follows the text colour; Claude's keeps its own.
        image.isTemplate = app == .codex
        cache[app] = image
        return image
    }
}

struct ToolBrandImage: View {
    let app: LiveConfigApp
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = ToolBrandIcon.image(for: app) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.primary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
