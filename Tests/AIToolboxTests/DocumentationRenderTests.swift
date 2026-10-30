import AppKit
import SwiftUI
import XCTest

@testable import AIToolbox

/// Opt-in renders of the real views with synthetic records only.
///
/// - `USAGE_RENDER_DOCS=1` regenerates the README images in `docs/images`.
/// - `USAGE_RENDER_GALLERY=<directory>` writes every page and state — loading,
///   empty, errors, dialogs, forms, both appearances — for the visual review.
///   Increase Contrast cannot be rendered here: AppKit hands back the plain
///   appearance for the high-contrast names, so those inks are covered by
///   `PixelDesignTests` instead.
/// - `USAGE_RENDER_ICON=1` regenerates `Assets/AppIcon.png` and the iconset the
///   package script builds the `.icns` from.
@MainActor
final class DocumentationRenderTests: XCTestCase {
    private let instant = Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 41))!

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUp() {
        super.setUp()
        for key in [
            "selectedTool", UsageDetailView.lifetimeExpandedKey, UsageDetailView.modelsExpandedKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - README

    func testRenderDocumentation() async throws {
        guard ProcessInfo.processInfo.environment["USAGE_RENDER_DOCS"] == "1" else {
            throw XCTSkip("Set USAGE_RENDER_DOCS=1 to regenerate README images")
        }
        let output = root.appending(path: "docs/images")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try await usageModel()

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await render(
                panel(model: model), dark: dark, to: output.appending(path: "detail-\(suffix).png"))
            try await render(
                panel(model: model, config: LiveConfigViewModel.documentation(app: .codex)),
                dark: dark, to: output.appending(path: "config-\(suffix).png"))
        }
        try await render(
            hero(model: model), dark: false, framed: false, to: output.appending(path: "hero.png"))
    }

    // MARK: - Gallery

    func testRenderGallery() async throws {
        guard let path = ProcessInfo.processInfo.environment["USAGE_RENDER_GALLERY"] else {
            throw XCTSkip("Set USAGE_RENDER_GALLERY=<directory> to render every state")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func file(_ name: String) -> URL { output.appending(path: "\(name).png") }

        let usage = try await usageModel(models: 4)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await render(panel(model: usage), dark: dark, to: file("usage-codex-\(suffix)"))
            try await render(
                panel(model: usage, tool: .claude), dark: dark, to: file("usage-claude-\(suffix)"))
            try await render(
                panel(model: try await loadingModel()), dark: dark, to: file("usage-loading-\(suffix)"))
            let failing = try await failingModel()
            try await render(
                panel(model: failing), dark: dark, until: { !failing.isRefreshing },
                to: file("usage-error-\(suffix)"))
            let stale = try await staleModel()
            try await render(
                panel(model: stale), dark: dark, until: { !stale.isRefreshing },
                to: file("usage-stale-\(suffix)"))
            for app in LiveConfigApp.allCases {
                try await render(
                    panel(model: usage, tool: app, config: .documentation(app: app)),
                    dark: dark, to: file("config-\(app.rawValue)-\(suffix)"))
                try await render(
                    panel(model: usage, tool: app, config: .gallery(app: app, .crowded)),
                    dark: dark, to: file("config-\(app.rawValue)-crowded-\(suffix)"))
            }
        }

        // Reduce Motion: the spinner becomes an hourglass, the loading blocks stand still.
        try await render(
            panel(model: try await loadingModel()).environment(\.reduceMotionOverride, true), dark: false,
            to: file("usage-loading-reduced-motion-light"))
        try await render(
            panel(model: usage, tool: .codex, config: .gallery(app: .codex, .crowded))
                .environment(\.reduceMotionOverride, true),
            dark: false, to: file("config-codex-crowded-reduced-motion-light"))

        UserDefaults.standard.set(false, forKey: UsageDetailView.lifetimeExpandedKey)
        UserDefaults.standard.set(false, forKey: UsageDetailView.modelsExpandedKey)
        try await render(panel(model: usage), dark: false, to: file("usage-collapsed-light"))
        UserDefaults.standard.removeObject(forKey: UsageDetailView.lifetimeExpandedKey)
        UserDefaults.standard.removeObject(forKey: UsageDetailView.modelsExpandedKey)

        for app in LiveConfigApp.allCases {
            for scenario in [LiveConfigViewModel.GalleryScenario.unmanaged, .unreadable, .official] {
                try await render(
                    panel(model: usage, tool: app, config: .gallery(app: app, scenario)), dark: false,
                    to: file("config-\(app.rawValue)-\(scenario)-light"))
            }
        }

        // Forms.
        let createCodex = LiveConfigViewModel.documentation(app: .codex)
        createCodex.beginCreate()
        createCodex.draftName = "Company gateway"
        createCodex.draftBaseURL = "https://gateway.company.test/v1"
        try await render(
            panel(model: usage, tool: .codex, config: createCodex), dark: false,
            to: file("draft-create-codex-light"))

        let createClaude = LiveConfigViewModel.documentation(app: .claude)
        createClaude.beginCreate()
        createClaude.draftName = "Relay gateway"
        createClaude.draftModel = "claude-sonnet-4"
        createClaude.draftCredential = .authToken
        try await render(
            panel(model: usage, tool: .claude, config: createClaude, showsAdvanced: true), dark: true,
            to: file("draft-create-claude-dark"))

        let editClaude = LiveConfigViewModel.documentation(app: .claude)
        editClaude.beginEdit(editClaude.visibleProviders[0])
        editClaude.revealDraftKey = true
        editClaude.draftAPIKey = "sk-ant-visible-while-typing"
        try await render(
            panel(model: usage, tool: .claude, config: editClaude), dark: false,
            to: file("draft-edit-claude-light"))

        // Dialogs, raised after the panel appears: opening the panel drops a pending one.
        let deleting = LiveConfigViewModel.documentation(app: .codex)
        try await render(
            panel(model: usage, tool: .codex, config: deleting), dark: false,
            after: { deleting.requestDelete(deleting.visibleProviders[0]) },
            to: file("dialog-delete-codex-light"))
        let clearing = LiveConfigViewModel.documentation(app: .claude)
        try await render(
            panel(model: usage, tool: .claude, config: clearing), dark: true,
            after: { clearing.requestClearClaudeOverlay() },
            to: file("dialog-clear-claude-dark"))

        try await render(iconSheet(), dark: false, framed: false, to: file("icons-light"))
        try await render(iconSheet(), dark: true, framed: false, to: file("icons-dark"))
    }

    // MARK: - App icon

    func testRenderAppIcon() throws {
        guard ProcessInfo.processInfo.environment["USAGE_RENDER_ICON"] == "1" else {
            throw XCTSkip("Set USAGE_RENDER_ICON=1 to regenerate the app icon")
        }
        let assets = root.appending(path: "Assets")
        let iconset = assets.appending(path: "AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        func write(_ canvasSize: Int, scale: Int, to url: URL) throws {
            let rep = try XCTUnwrap(
                AppIconArt.bitmap(AppIconArt.canvas(size: canvasSize), pixelsPerCell: scale))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        try write(32, scale: 32, to: assets.appending(path: "AppIcon.png"))
        // Each slot is drawn at a whole number of pixels per cell; 16 px gets its own art.
        let slots: [(name: String, canvas: Int, scale: Int)] = [
            ("icon_16x16", 16, 1), ("icon_16x16@2x", 32, 1),
            ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
            ("icon_128x128", 32, 4), ("icon_128x128@2x", 32, 8),
            ("icon_256x256", 32, 8), ("icon_256x256@2x", 32, 16),
            ("icon_512x512", 32, 16), ("icon_512x512@2x", 32, 32),
        ]
        for slot in slots {
            try write(slot.canvas, scale: slot.scale, to: iconset.appending(path: "\(slot.name).png"))
        }
    }

    // MARK: - Fixtures

    private func usageModel(models: Int = 3) async throws -> UsageViewModel {
        let providers = [UsageProviderID.codex, .claude].enumerated().map { index, id in
            FixtureProvider(
                id: id,
                snapshot: UsageFixtures.snapshot(at: instant, scale: [1, 0.4][index], models: models))
        }
        let model = UsageViewModel(providers: providers, preferences: nil, now: { [instant] in instant })
        model.refreshAll()
        try await settle(model)
        XCTAssertEqual(model.sourceIDs.count, 2)
        return model
    }

    private func loadingModel() async throws -> UsageViewModel {
        let model = UsageViewModel(
            providers: [BlockedProvider(id: .codex)], preferences: nil, now: { [instant] in instant })
        model.refreshAll()
        XCTAssertTrue(model.isRefreshing)
        return model
    }

    private func failingModel() async throws -> UsageViewModel {
        let model = UsageViewModel(
            providers: [FixtureProvider(id: .codex, snapshot: nil)], preferences: nil,
            now: { [instant] in instant })
        model.refreshAll()
        try await settle(model)
        XCTAssertNotNil(model.errorMessage)
        return model
    }

    /// Read once, then every later read fails: the data on screen is the last good read.
    private func staleModel() async throws -> UsageViewModel {
        let provider = FlakyProvider(id: .codex, snapshot: UsageFixtures.snapshot(at: instant))
        let model = UsageViewModel(providers: [provider], preferences: nil, now: { [instant] in instant })
        model.refreshAll()
        try await settle(model)
        model.refresh()
        try await settle(model)
        XCTAssertNotNil(model.sourceWarning(.codex))
        return model
    }

    private func settle(_ model: UsageViewModel) async throws {
        for _ in 0..<200 {
            if !model.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Views

    private func panel(
        model: UsageViewModel,
        tool: LiveConfigApp = .codex,
        config: LiveConfigViewModel? = nil,
        showsAdvanced: Bool = false
    ) -> some View {
        UserDefaults.standard.set(tool.rawValue, forKey: "selectedTool")
        model.selectedProvider = tool.usageProvider
        return PanelFrame(
            content: UsagePopoverView(
                model: model,
                initialSelectedTool: tool,
                initialShowsConfig: config != nil,
                configViewModel: config,
                initialShowsAdvanced: showsAdvanced
            ))
    }

    private func hero(model: UsageViewModel) -> some View {
        UserDefaults.standard.set(LiveConfigApp.codex.rawValue, forKey: "selectedTool")
        model.selectedProvider = .codex
        return HeroArtwork(
            panel: UsagePopoverView(model: model, initialSelectedTool: .codex, initialShowsConfig: false))
    }

    private func iconSheet() -> some View {
        IconSheet()
    }

    // MARK: - Rendering

    private func render<V: View>(
        _ content: V,
        dark: Bool,
        framed: Bool = true,
        after: (() -> Void)? = nil,
        until settled: (() -> Bool)? = nil,
        to url: URL
    ) async throws {
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        NSApplication.shared.appearance = NSAppearance(named: name)
        let wrapped =
            content
            .padding(framed ? 28 : 0)
            .background(
                dark ? Color(red: 0.06, green: 0.07, blue: 0.12) : Color(red: 0.86, green: 0.89, blue: 0.94)
            )
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: wrapped)
        view.appearance = NSAppearance(named: name)

        // The panel sizes itself from its measured body height, which converges over a
        // layout pass or two. Measuring once captures a pre-convergence frame (visible
        // as dead space in the screenshot), so let it settle first.
        func converge() {
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            for _ in 0..<10 {
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                let settled = view.fittingSize
                if abs(settled.height - view.frame.height) < 0.5 { break }
                view.frame = NSRect(origin: .zero, size: settled)
            }
        }
        converge()
        if let after {
            after()
            converge()
        }
        // Opening the panel starts a read; wait for it when the state under test is
        // the one after that read, not the read itself.
        // Spinning the run loop would not do: this test runs on the main actor, and
        // the read's continuation needs the main actor free, which only a suspension
        // gives it.
        if let settled {
            let deadline = Date().addingTimeInterval(3)
            while !settled(), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            converge()
        }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        NSApplication.shared.appearance = nil
    }
}

// MARK: - Render-only views

/// The panel as it hangs from the menu bar: the system's rounded window corners
/// and its shadow.
private struct PanelFrame<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

/// The README's opening image, in the panel's own pixel language.
private struct HeroArtwork<Panel: View>: View {
    let panel: Panel

    var body: some View {
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    PixelLamp(color: Ink.brandCyan)
                    Text("Local usage · menu bar tool")
                        .font(.pixel())
                        .foregroundStyle(Ink.brandCyan)
                }
                .padding(.bottom, 30)
                AppIconImage(pixelsPerCell: 3)
                    .padding(.bottom, 22)
                Text(L10n.App.title)
                    .font(.pixel(4))
                    .foregroundStyle(.white)
                Text("Usage and config,\nright in the menu bar.")
                    .font(.pixel(2))
                    .lineSpacing(6)
                    .foregroundStyle(Color.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                HStack(spacing: 0) {
                    Rectangle().fill(Ink.brandCyan).frame(width: 64)
                    Rectangle().fill(Ink.brandBlue).frame(width: 64)
                    Rectangle().fill(Ink.brandViolet).frame(width: 64)
                }
                .frame(height: 6)
                .padding(.vertical, 30)
                Text(
                    "Codex and Claude Code usage, trends and provider configuration, in one native macOS panel."
                )
                .font(.system(size: 16))
                .lineSpacing(5)
                .foregroundStyle(Color.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 24)
                HStack(spacing: 20) {
                    feature(.usage, "Local logs")
                    feature(.swap, "One-click switch")
                    feature(.save, "Atomic writes")
                }
                .foregroundStyle(Color.white.opacity(0.78))
            }
            .frame(width: 460, height: 600, alignment: .leading)
            PanelFrame(content: panel)
        }
        .padding(.horizontal, 56)
        .frame(width: 1120, height: 720)
        .background { HeroBackground() }
        .environment(\.colorScheme, .light)
    }

    private func feature(_ icon: PixelIcon, _ title: String) -> some View {
        HStack(spacing: 6) {
            PixelIconView(icon)
            Text(title).font(.pixel())
        }
    }
}

/// Night-sky bands joined by dithered seams, with a scatter of pixel stars.
private struct HeroBackground: View {
    var body: some View {
        Canvas { context, size in
            let bands: [(Color, CGFloat)] = [
                (Ink.fixed(0x1E2766), 0), (Ink.fixed(0x182059), 0.34), (Ink.fixed(0x121947), 0.67),
            ]
            for (index, band) in bands.enumerated() {
                let top = (band.1 * size.height).rounded()
                let bottom =
                    index + 1 < bands.count ? (bands[index + 1].1 * size.height).rounded() : size.height
                context.fill(
                    Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)), with: .color(band.0))
                if index + 1 < bands.count {
                    let seam = DitherPattern(cell: 4).path(
                        in: CGRect(x: 0, y: bottom - 8, width: size.width, height: 16))
                    context.fill(seam, with: .color(bands[index + 1].0))
                }
            }
            var generator = SeededGenerator(seed: 7)
            for _ in 0..<70 {
                let x = (CGFloat(generator.next() % 280) * 4)
                let y = (CGFloat(generator.next() % 180) * 4)
                let big = generator.next() % 6 == 0
                let star = CGRect(x: x, y: y, width: big ? 4 : 2, height: big ? 4 : 2)
                context.fill(Path(star), with: .color(.white.opacity(big ? 0.7 : 0.35)))
            }
        }
    }
}

/// A tiny deterministic generator, so the hero's stars do not move between renders.
private struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}

/// The app icon drawn from its pixel art at a whole number of points per cell.
private struct AppIconImage: View {
    let pixelsPerCell: Int

    var body: some View {
        let canvas = AppIconArt.canvas(size: 32)
        Canvas { context, _ in
            for y in 0..<canvas.size {
                for x in 0..<canvas.size {
                    guard let hex = canvas[x, y] else { continue }
                    let cell = CGFloat(pixelsPerCell)
                    context.fill(
                        Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)),
                        with: .color(Ink.fixed(hex)))
                }
            }
        }
        .frame(width: CGFloat(32 * pixelsPerCell), height: CGFloat(32 * pixelsPerCell))
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(32 * pixelsPerCell) * 0.225, style: .continuous))
    }
}

/// Every icon and mark at 1× and 3×, for checking the art itself.
private struct IconSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 9), spacing: 12) {
                ForEach(Array(PixelIcon.allCases.enumerated()), id: \.offset) { _, icon in
                    VStack(spacing: 6) {
                        PixelIconView(icon, scale: 3)
                        PixelIconView(icon)
                        Text(String(describing: icon)).font(.system(size: 9)).foregroundStyle(Ink.textMuted)
                    }
                    .foregroundStyle(Ink.text)
                }
            }
            HStack(spacing: 24) {
                ToolBrandMark(app: .claude).scaleEffect(3).frame(width: 48, height: 48)
                ToolBrandMark(app: .codex).scaleEffect(3).frame(width: 48, height: 48).foregroundStyle(
                    Ink.text)
                AppMark(scale: 4).padding(8).background(Ink.chrome)
                TerminalIllustration(mode: .empty)
                TerminalIllustration(mode: .loading)
                TerminalIllustration(mode: .error)
                AppIconImage(pixelsPerCell: 2)
            }
        }
        .padding(24)
        .background(Ink.canvas)
    }
}

// MARK: - Fixture providers

/// Never answers: the panel stays in its first-read state.
private final class BlockedProvider: UsageProvider, @unchecked Sendable {
    let id: UsageProviderID
    init(id: UsageProviderID) { self.id = id }
    func load() throws -> UsageSnapshot {
        Thread.sleep(forTimeInterval: 30)
        throw ProviderReadError.noRecords(id)
    }
}

/// Answers once, then fails on every later read.
private final class FlakyProvider: UsageProvider, @unchecked Sendable {
    let id: UsageProviderID
    let snapshot: UsageSnapshot
    private let lock = NSLock()
    private var calls = 0

    init(id: UsageProviderID, snapshot: UsageSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }

    func load() throws -> UsageSnapshot {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        guard call == 1 else { throw ProviderReadError.incompatible(id) }
        return snapshot
    }
}
