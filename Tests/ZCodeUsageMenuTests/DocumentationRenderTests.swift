import AppKit
import SwiftUI
import XCTest
@testable import ZCodeUsageMenu

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
        let providers = [UsageProviderID.zcode, .codex, .claude].enumerated().map { index, id in
            DocumentationProvider(id: id, snapshot: fixture(at: instant, index: index))
        }
        let model = UsageViewModel(providers: providers, preferences: nil, now: { instant })
        model.refreshAll()
        for _ in 0..<100 {
            if !model.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.availableSources.count, 3)
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            model.selectedProvider = .zcode
            let panel = UsagePopoverView(model: model)
                .environment(\.colorScheme, dark ? .dark : .light)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(dark ? 0.25 : 0.10), radius: 16, y: 8)
                .padding(28)
                .background(dark ? Color(red: 0.07, green: 0.09, blue: 0.14) : Color(red: 0.94, green: 0.95, blue: 0.98))
            try render(panel, dark: dark, to: output.appending(path: "detail-\(dark ? "dark" : "light").png"))
        }
        app.appearance = NSAppearance(named: .aqua)
        model.selectedProvider = .overview
        let hero = HStack(spacing: 54) {
            VStack(alignment: .leading, spacing: 22) {
                Image(nsImage: icon).resizable().frame(width: 88, height: 88)
                Text("AI Usage").font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.25))
                Text("Your coding tools.\nOne quiet corner.")
                    .font(.system(size: 26, weight: .medium)).lineSpacing(6)
                    .foregroundStyle(Color(red: 0.35, green: 0.40, blue: 0.50))
                Text("ZCode  /  Codex  /  Claude Code")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Label("Native macOS", systemImage: "macwindow")
                    Label("Local data", systemImage: "internaldrive")
                }.font(.system(size: 13)).foregroundStyle(.secondary)
            }.frame(width: 400, alignment: .leading)
            UsagePopoverView(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
                .shadow(color: .indigo.opacity(0.14), radius: 28, y: 14)
        }
        .frame(width: 1080, height: 650)
        .background(LinearGradient(colors: [Color(red: 0.95, green: 0.97, blue: 1),
                                           Color(red: 0.96, green: 0.95, blue: 0.99)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .light)
        try render(hero, dark: false, to: output.appending(path: "hero.png"))
    }

    private func render<V: View>(_ content: V, dark: Bool, to url: URL) throws {
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func fixture(at date: Date, index: Int) -> UsageSnapshot {
        func totals(output: Int64) -> UsageTotals {
            UsageTotals(turns: 24, requests: 128, inputTokens: 3_700_000, outputTokens: output,
                        reasoningTokens: 42_000, cacheReadInputTokens: 2_900_000,
                        cacheCreationInputTokens: 200_000, toolCalls: 82)
        }
        return UsageSnapshot(refreshedAt: date,
                             totals: totals(output: [14_200_000, 10_500_000, 334_000][index]),
                             today: totals(output: [248_000, 27_000, 12_000][index]),
                             models: [ModelUsage(modelID: "Model Alpha", providerID: "local", requests: 96, outputTokens: 180_000),
                                      ModelUsage(modelID: "Model Beta", providerID: "local", requests: 32, outputTokens: 68_000)])
    }
}

private struct DocumentationProvider: UsageProvider {
    let id: UsageProviderID
    let snapshot: UsageSnapshot
    func load() throws -> UsageSnapshot { snapshot }
}
