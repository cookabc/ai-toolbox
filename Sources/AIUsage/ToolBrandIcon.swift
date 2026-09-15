import AppKit
import SwiftUI

enum ToolBrandIcon {
    private static func resourceURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
    }

    static func image(for app: LiveConfigApp, size: CGFloat = 14) -> NSImage? {
        let resource = app == .claude ? "BrandClaude" : "BrandCodex"
        guard let url = resourceURL(named: resource),
              let image = NSImage(contentsOf: url) else { return nil }
        if app == .codex {
            image.isTemplate = true
        }
        image.size = NSSize(width: size, height: size)
        return image
    }
}

struct ToolBrandImage: View {
    let app: LiveConfigApp
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = ToolBrandIcon.image(for: app, size: size) {
                if app == .codex {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.primary)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
