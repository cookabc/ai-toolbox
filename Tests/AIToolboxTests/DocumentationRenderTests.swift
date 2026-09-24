import AppKit
import SwiftUI
import XCTest
@testable import AIToolbox

/// Opt-in documentation renders use the real views and synthetic records only.
@MainActor
final class DocumentationRenderTests: XCTestCase {
    func testRenderDocumentation() async throws {
        guard ProcessInfo.processInfo.environment["USAGE_RENDER_DOCS"] == "1" else {
            throw XCTSkip("Set USAGE_RENDER_DOCS=1 to regenerate README images")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appending(path: "docs/images")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let icon = try XCTUnwrap(NSImage(contentsOf: root.appending(path: "Assets/AppIcon.png")))
        app.applicationIconImage = icon
        let instant = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 41))!
        let providers = [UsageProviderID.codex, .claude].enumerated().map { index, id in
            FixtureProvider(id: id, snapshot: UsageFixtures.snapshot(at: instant, scale: [1, 0.4][index]))
        }
        let model = UsageViewModel(providers: providers, preferences: nil, now: { instant })
        model.refreshAll()
        for _ in 0..<100 {
            if !model.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sourceIDs.count, 2)
        model.selectedProvider = .codex

        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try render(
                panel(model: model, showsConfig: false),
                dark: dark,
                to: output.appending(path: "detail-\(dark ? "dark" : "light").png")
            )
            try render(
                panel(
                    model: model,
                    showsConfig: true,
                    configViewModel: LiveConfigViewModel.documentation(app: .codex)
                ),
                dark: dark,
                to: output.appending(path: "config-\(dark ? "dark" : "light").png")
            )
        }

        app.appearance = NSAppearance(named: .aqua)
        let hero = HStack(spacing: 64) {
            VStack(alignment: .leading, spacing: 22) {
                Image(nsImage: icon).resizable().frame(width: 88, height: 88)
                Text(AppBranding.title).font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.25))
                Text("把 Codex 与 Claude Code 的用量\n和供应商配置，放进菜单栏。")
                    .font(.system(size: 24, weight: .medium)).lineSpacing(8)
                    .foregroundStyle(Color(red: 0.35, green: 0.40, blue: 0.50))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Label("原生 macOS", systemImage: "macwindow")
                    Label("本地数据", systemImage: "internaldrive")
                    Label("安全写入配置", systemImage: "checkmark.shield")
                }.font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(width: 440, alignment: .leading)
            framedPanel(model: model)
        }
        .frame(width: 1120, height: 720)
        .background(LinearGradient(colors: [Color(red: 0.95, green: 0.97, blue: 1),
                                           Color(red: 0.96, green: 0.95, blue: 0.99)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .light)
        try render(hero, dark: false, to: output.appending(path: "hero.png"))
    }

    /// The panel as it hangs from the menu bar, without the screenshot margin.
    private func framedPanel(model: UsageViewModel) -> some View {
        UsagePopoverView(model: model, initialSelectedTool: .codex, initialShowsConfig: false)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
            .shadow(color: .indigo.opacity(0.14), radius: 28, y: 14)
    }

    private func panel(
        model: UsageViewModel,
        showsConfig: Bool,
        configViewModel: LiveConfigViewModel? = nil
    ) -> some View {
        UsagePopoverView(
            model: model,
            initialSelectedTool: .codex,
            initialShowsConfig: showsConfig,
            configViewModel: configViewModel
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
        .padding(28)
    }

    private func render<V: View>(_ content: V, dark: Bool, to url: URL) throws {
        let wrapped = content
            .background(dark ? Color(red: 0.07, green: 0.09, blue: 0.14) : Color(red: 0.94, green: 0.95, blue: 0.98))
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: wrapped)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // The panel sizes itself from its measured body height, which converges over a
        // layout pass or two. Measuring once captures a pre-convergence frame (visible
        // as dead space in the screenshot), so let it settle first.
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let settled = view.fittingSize
            if abs(settled.height - view.frame.height) < 0.5 { break }
            view.frame = NSRect(origin: .zero, size: settled)
        }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
