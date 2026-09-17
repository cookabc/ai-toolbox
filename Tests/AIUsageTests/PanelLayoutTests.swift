import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

/// The menu-bar panel is content-fitted, which means its window changes size as you
/// switch tools — and that is where every bug in this area has come from.
///
/// Four things have to hold at once, and each has already been broken once:
///
/// 1. **No collapse.** `MenuBarExtra` opens the window small. A *flexible* `ScrollView`
///    happily accepts that small proposal, so the body measures ~0 and the panel shows
///    only its header — a stable wrong answer that never self-corrects.
/// 2. **No dead space.** Pinning one fixed height stops the drift but makes every short
///    state reserve the tallest state's height, leaving a large blank area.
/// 3. **Cap + scroll.** Content taller than the cap must be capped *and* scrollable;
///    `fixedSize` on the scroll view instead makes it content-tall so the overflow is
///    clipped and unreachable.
/// 4. **Window follows content.** `MenuBarExtra` does not keep the window in lockstep
///    with the content: a panel was measured at 593pt while its content had settled at
///    323pt. The window has no background of its own, so the 270pt left uncovered is
///    simply transparent — a blank panel hanging under the menu-bar icon. AppKit also
///    resizes from the *origin*, so a window that grows or shrinks on its own takes the
///    top edge with it.
///
/// The first three are satisfied by measuring the body and giving the scroll view a
/// definite height, so these tests drive the layout from both a small and a large
/// opening size. The fourth is `PanelTopAnchor`'s job — it applies the content height
/// and the menu-bar anchoring as one operation.
@MainActor
final class PanelLayoutTests: XCTestCase {
    private let instant = Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 41)
    )!

    override func setUp() {
        super.setUp()
        // UsagePopoverView.syncOnAppear() restores selectedTool from this default, so a
        // leaked value would silently make every render measure the same tool.
        UserDefaults.standard.removeObject(forKey: "selectedTool")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedTool")
        super.tearDown()
    }

    /// Regression for the panel collapsing to just its header.
    ///
    /// Opening heights of 40pt simulate `MenuBarExtra` presenting a small window; a
    /// layout that adopts that proposal renders only the chrome.
    func testPanelDoesNotCollapseWhenOpenedSmall() throws {
        for app in LiveConfigApp.allCases {
            let (panel, body) = try configCase(app)
            let settled = settle(panel, start: 40)
            XCTAssertEqual(
                settled, Int((body + chromeHeight).rounded()), accuracy: 2,
                "\(app.rawValue) collapsed when opened small: got \(settled)pt, expected \(Int(body + chromeHeight))pt"
            )
            XCTAssertGreaterThan(settled, 200, "\(app.rawValue) rendered as header-only")
        }
    }

    /// Every state must settle to the same height regardless of the size it opened at —
    /// that is what makes the result independent of `MenuBarEdge`'s presentation.
    func testSettledHeightIsIndependentOfOpeningSize() throws {
        for app in LiveConfigApp.allCases {
            let (panel, _) = try configCase(app)
            let heights = [40.0, 602.0, 900.0].map { settle(panel, start: $0) }
            XCTAssertEqual(Set(heights).count, 1, "\(app.rawValue) settled differently by opening size: \(heights)")
        }
    }

    /// Regression for the blank area: a short panel must actually be short.
    func testShortContentDoesNotReserveFullHeight() throws {
        for app in LiveConfigApp.allCases {
            let (panel, body) = try configCase(app)
            let settled = settle(panel, start: 602)
            XCTAssertEqual(settled, Int((body + chromeHeight).rounded()), accuracy: 2)
            XCTAssertLessThan(settled, Int(UsagePopoverView.panelMaxHeight),
                              "\(app.rawValue) must not reserve the full panel height")
        }
    }

    /// The cap is on the **whole panel**, and the body's overflow must be scrollable
    /// rather than clipped.
    func testOverflowingContentIsCappedAndScrolls() throws {
        let config = try overflowingConfig()
        let bare = bareBody(config)
        XCTAssertGreaterThan(bare, UsagePopoverView.panelMaxHeight, "fixture must overflow the cap")

        for start in [40.0, 602.0, 900.0] {
            UserDefaults.standard.set("claude", forKey: "selectedTool")
            let panel = configView(.claude, config: config)
            let info = try scrollInfo(panel, start: start)
            XCTAssertEqual(info.window, Int(UsagePopoverView.panelMaxHeight),
                           "the panel must cap at the total limit, not body-cap + chrome")
            XCTAssertLessThanOrEqual(
                info.viewport, UsagePopoverView.panelMaxHeight - chromeHeight + 1,
                "the body must be capped, not grown to fit all content"
            )
            XCTAssertGreaterThan(info.document, info.viewport + 1,
                                 "tall content must scroll, not be clipped")
        }
    }

    /// Taller content must produce a taller panel, i.e. the height tracks content
    /// rather than being pinned.
    func testPanelHeightTracksContent() async throws {
        let compact = await usageView(provider: .codex, models: 0)
        let tall = await usageView(provider: .codex, models: 4)
        XCTAssertLessThan(settle(compact, start: 900), settle(tall, start: 900),
                          "more model rows must mean a taller panel")
    }

    /// The original symptom: the *top* edge must stay at the menu bar when the height
    /// changes.
    ///
    /// The target is the menu bar's bottom edge, read from the screen — **not** wherever
    /// the window happens to be. Learning it from the window is what let the drift
    /// become permanent: once the top had slipped, the slipped position was adopted as
    /// the reference and never corrected. This test therefore starts the window in the
    /// wrong place on purpose; a correct anchor fixes it rather than preserving it.
    func testTopEdgeIsPinnedToMenuBarAcrossHeightChanges() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 200, width: UsagePopoverView.panelWidth, height: 602),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Color.white
            .background(PanelTopAnchor().frame(width: 0, height: 0)))
        host.sizingOptions = []   // let the window resize independently, as MenuBarExtra does
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        // Compare against the anchor's own reference — the screen the window is on.
        // `NSScreen.main` is context-sensitive (it follows the key window and shifts as
        // windows are created and closed), so it is not a stable oracle in a test run.
        let menuBarBottom = try XCTUnwrap(window.screen).visibleFrame.maxY
        XCTAssertNotEqual(window.frame.maxY, menuBarBottom, accuracy: 0.5,
                          "the harness must start misplaced, or this proves nothing")

        for height in [244.0, 602.0, 306.0, 602.0, 125.0, 479.0] {
            window.setContentSize(NSSize(width: UsagePopoverView.panelWidth, height: height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            XCTAssertEqual(window.frame.maxY, menuBarBottom, accuracy: 0.5,
                           "top edge must sit at the menu bar when the panel is \(height)pt")
            XCTAssertEqual(window.frame.height, height, accuracy: 0.5)
        }
    }

    /// Regression for the transparent region: the window must end up exactly as tall as
    /// the content, not left at the height it happened to open with.
    ///
    /// A panel measured 593pt while its content had settled at 323pt, and the 270pt the
    /// content did not cover was transparent — which is what "there is a transparent
    /// panel between the content and the icon" actually was. The opening height is
    /// deliberately wrong here so that a pass proves the anchor drove it.
    func testWindowHeightFollowsTheContentNotTheOpeningHeight() throws {
        let contentHeight: CGFloat = 323
        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 200, width: UsagePopoverView.panelWidth, height: 593),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Color.clear
            .frame(width: UsagePopoverView.panelWidth, height: contentHeight)
            .background(PanelTopAnchor(height: contentHeight).frame(width: 0, height: 0)))
        host.sizingOptions = []   // let the window keep the wrong size until the anchor fixes it
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let menuBarBottom = try XCTUnwrap(window.screen).visibleFrame.maxY
        XCTAssertEqual(window.frame.height, contentHeight, accuracy: 0.5,
                       "the window must be as tall as its content, not as tall as it opened")
        XCTAssertEqual(window.frame.maxY, menuBarBottom, accuracy: 0.5,
                       "and it must still hang from the menu bar")
    }

    /// The anchor observes `didMove`, and its own correction posts `didMove` too. The
    /// absolute, screen-derived target is what keeps that a no-op instead of an endless
    /// move loop, so this guards the hazard the design introduces.
    func testTopCorrectionSettlesWithoutLooping() {
        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 200, width: UsagePopoverView.panelWidth, height: 602),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Color.white
            .background(PanelTopAnchor().frame(width: 0, height: 0)))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        var moves = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { _ in moves += 1 }

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let settled = moves
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let idle = moves
        NotificationCenter.default.removeObserver(token)

        XCTAssertEqual(settled, idle,
                       "the anchor kept moving an idle window: correction is looping")
    }

    /// Regression for the oversized first frame.
    ///
    /// The panel's height is the sum of two independently measured values, and
    /// `bodyHeight` is seeded at the cap while `chromeHeight` is still unmeasured.
    /// Left to sum freely that yields cap + chrome — 704pt against a 602pt limit — and
    /// an over-tall frame *shrinking* drags the top edge down, which is the gap the
    /// user sees. The total must be clamped, not just its parts.
    func testFirstFrameIsWithinTheCap() {
        for app in LiveConfigApp.allCases {
            UserDefaults.standard.set(app.rawValue, forKey: "selectedTool")
            let panel = UsagePopoverView(
                model: UsageViewModel(providers: [], preferences: nil),
                initialSelectedTool: app,
                initialShowsConfig: true,
                configViewModel: LiveConfigViewModel.documentation(app: app)
            )
            let host = NSHostingView(rootView: panel)
            host.appearance = NSAppearance(named: .aqua)
            XCTAssertLessThanOrEqual(
                host.fittingSize.height, UsagePopoverView.panelMaxHeight + 1,
                "\(app.rawValue) first frame exceeds the cap: \(host.fittingSize.height)"
            )
        }
    }

    func testPanelWidthIsStable() async throws {
        let view = await usageView(provider: .codex, models: 4)
        XCTAssertEqual(NSHostingView(rootView: view).fittingSize.width, UsagePopoverView.panelWidth)
    }

    /// Regression for the panel sliding while a refresh was in flight.
    ///
    /// The header spinner used to rotate via
    /// `withAnimation(…repeatForever(autoreverses: false))` started in `onAppear`. An
    /// endless animation never completes, so it was still in flight when the refresh
    /// inserted the "· 正在刷新…" subtitle and re-laid-out the chrome around it — and
    /// those views inherited it and slid upward forever. It survived closing and
    /// reopening the panel and cleared only on relaunch, which is what identified it.
    /// Measured before the fix: **26** layers moving, the title and both tool tabs among
    /// them. The angle now comes from a `TimelineView`, so only the spinner may move.
    ///
    /// Usage mode is the case that matters: starting a refresh inserts the subtitle *and*
    /// the spinner in the same update. Config mode never re-lays-out the chrome, so it
    /// does not reach the bug.
    func testRefreshSpinnerDoesNotMoveThePanel() throws {
        UserDefaults.standard.set(LiveConfigApp.codex.rawValue, forKey: "selectedTool")
        let model = UsageViewModel(
            providers: [SlowFixtureProvider(id: .codex, delay: 6)],
            preferences: nil,
            now: { [instant] in instant }
        )
        let host = NSHostingView(rootView: UsagePopoverView(
            model: model, initialSelectedTool: .codex, initialShowsConfig: false
        ))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UsagePopoverView.panelWidth, height: 602),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        pump(host, for: 0.6)
        XCTAssertTrue(model.isRefreshing == false, "the fixture must start idle")

        // The spinner and the subtitle appear together, which is the trigger.
        model.refresh()
        XCTAssertTrue(model.isRefreshing, "the slow fixture must still be refreshing")

        // Let the one-off re-layout settle; after this, anything still moving is a
        // leaked animation rather than layout catching up.
        pump(host, for: 0.9)
        let heightBefore = window.frame.height

        var previous = structuralGeometry(host)
        var offenders: [String: String] = [:]
        for _ in 0..<15 {
            pump(host, for: 0.1)
            let current = structuralGeometry(host)
            for (path, value) in current where previous[path] != nil && previous[path] != value {
                offenders[path] = "was \(previous[path]!)\n     now \(value)"
            }
            previous = current
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "the panel moved while the refresh spinner was running (the spinner itself is "
            + "excluded — it is under \(Int(Self.structuralWidth))pt wide): \(offenders)"
        )
        XCTAssertEqual(
            window.frame.height, heightBefore, accuracy: 0.5,
            "the panel resized while the refresh spinner was running"
        )
    }

    // MARK: - Helpers

    /// Measured chrome height, matching the constant the panel derives its cap from.
    private var chromeHeight: CGFloat { 102 }

    private func configCase(_ app: LiveConfigApp) throws -> (UsagePopoverView, CGFloat) {
        UserDefaults.standard.set(app.rawValue, forKey: "selectedTool")
        let config = LiveConfigViewModel.documentation(app: app)
        return (configView(app, config: config), bareBody(config))
    }

    private func configView(_ app: LiveConfigApp, config: LiveConfigViewModel) -> UsagePopoverView {
        UserDefaults.standard.set(app.rawValue, forKey: "selectedTool")
        return UsagePopoverView(
            model: UsageViewModel(providers: [], preferences: nil),
            initialSelectedTool: app,
            initialShowsConfig: true,
            configViewModel: config
        )
    }

    private func bareBody(_ config: LiveConfigViewModel) -> CGFloat {
        let bare = NSHostingView(rootView:
            VStack(spacing: 0) { LiveConfigView(model: config) }
                .frame(width: UsagePopoverView.panelWidth, alignment: .top)
        )
        bare.appearance = NSAppearance(named: .aqua)
        bare.frame = NSRect(origin: .zero, size: bare.fittingSize)
        bare.layoutSubtreeIfNeeded()
        return bare.fittingSize.height
    }

    /// 16 providers — far taller than the cap. Uses Claude providers because Codex
    /// cards only render when a live `config.toml` exists, which would make the
    /// fixture measure an error label instead of a list.
    private func overflowingConfig() throws -> LiveConfigViewModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "panel-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let store = ProviderLibraryStore(url: root.appending(path: "providers.json"))
        try store.save((0..<16).map { index in
            StoredProvider(
                app: .claude, name: "Provider \(index)", slug: "provider-\(index)",
                baseURL: "https://relay\(index).example/v1", model: "claude-sonnet-4", apiKey: "sk-\(index)"
            )
        })
        try #"{"env":{"ANTHROPIC_BASE_URL":"https://relay0.example"}}"#
            .write(to: root.appending(path: "settings.json"), atomically: true, encoding: .utf8)

        let config = LiveConfigViewModel(
            paths: LiveConfigPaths(
                claudeSettings: root.appending(path: "settings.json"),
                codexConfig: root.appending(path: "config.toml")
            ),
            library: store
        )
        config.app = .claude   // defaults to .claude, but be explicit: a Codex fixture yields 0 providers
        config.reload()
        XCTAssertEqual(config.visibleProviders.count, 16, "fixture must actually produce a long list")
        return config
    }

    /// `refreshAll()` returns immediately while the loader runs on a background task,
    /// so a render taken straight after would capture the pre-load (empty) state.
    private func usageView(provider: UsageProviderID, models: Int) async -> UsagePopoverView {
        let model = UsageViewModel(
            providers: [
                FixtureProvider(id: .codex, snapshot: snapshot(output: 10_500_000, models: models)),
                FixtureProvider(id: .claude, snapshot: snapshot(output: 334_000, models: models)),
            ],
            preferences: nil,
            now: { [instant] in instant }
        )
        model.refreshAll()
        for _ in 0..<200 {
            if !model.isRefreshing { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        UserDefaults.standard.set(provider.rawValue, forKey: "selectedTool")
        model.selectedProvider = provider
        return UsagePopoverView(
            model: model,
            initialSelectedTool: LiveConfigApp(usageProvider: provider)!,
            initialShowsConfig: false
        )
    }

    /// Opens a window at `start` and lets AppKit lay the panel out, then reports the
    /// resulting window height — which is what the real panel settles at.
    private func settle(_ view: UsagePopoverView, start: CGFloat) -> Int {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UsagePopoverView.panelWidth, height: start),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        let height = Int(window.frame.height.rounded())
        window.close()
        return height
    }

    private func scrollInfo(_ view: UsagePopoverView, start: CGFloat) throws
        -> (window: Int, document: CGFloat, viewport: CGFloat) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UsagePopoverView.panelWidth, height: start),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        defer { window.close() }
        let scroller = try XCTUnwrap(findScrollViews(in: host).first)
        return (Int(window.frame.height.rounded()),
                scroller.documentView?.frame.height ?? 0,
                scroller.contentView.bounds.height)
    }

    private func findScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroller = view as? NSScrollView { found.append(scroller) }
        for sub in view.subviews { found += findScrollViews(in: sub) }
        return found
    }

    /// Layers at least this wide are structure — the content, the chrome, the rows. The
    /// spinner glyph is ~18pt, so excluding narrow layers is what lets the test say
    /// "nothing but the spinner moved" without having to identify the spinner itself.
    private static let structuralWidth: CGFloat = 100

    private func pump(_ host: NSView, for seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Frame, position and transform of every structural layer, keyed by its path in the
    /// layer tree. `cacheDisplay` cannot see an in-flight animation — it renders model
    /// values — so the tree is compared between samples instead of being screenshotted.
    private func structuralGeometry(_ view: NSView) -> [String: String] {
        var out: [String: String] = [:]
        collect(view.layer, path: "", into: &out)
        return out
    }

    private func collect(_ layer: CALayer?, path: String, into out: inout [String: String]) {
        guard let layer else { return }
        let name = "\(path)/\(String(describing: type(of: layer)))"
        if layer.frame.width >= Self.structuralWidth {
            let t = layer.transform
            out[name] = String(
                format: "frame=%.2f,%.2f %.2fx%.2f pos=%.2f,%.2f t=[%.3f %.3f %.3f %.3f %.3f %.3f]",
                layer.frame.origin.x, layer.frame.origin.y, layer.frame.width, layer.frame.height,
                layer.position.x, layer.position.y, t.m11, t.m12, t.m21, t.m22, t.m41, t.m42
            )
        }
        for (index, sub) in (layer.sublayers ?? []).enumerated() {
            collect(sub, path: "\(name)#\(index)", into: &out)
        }
    }

    private func snapshot(output: Int64, models: Int) -> UsageSnapshot {
        let totals = UsageTotals(
            turns: 24, requests: 128, inputTokens: 3_700_000, outputTokens: output,
            reasoningTokens: 42_000, cacheReadInputTokens: 2_900_000,
            cacheCreationInputTokens: 200_000, toolCalls: 82
        )
        let rows = (0..<models).map { index in
            ModelUsage(modelID: "Model \(index)", providerID: "local", requests: 96, outputTokens: 180_000)
        }
        return UsageSnapshot(refreshedAt: instant, totals: totals, today: totals, models: rows)
    }
}

private struct FixtureProvider: UsageProvider {
    let id: UsageProviderID
    let snapshot: UsageSnapshot?
    func load() throws -> UsageSnapshot {
        guard let snapshot else { throw ProviderReadError.noRecords(id) }
        return snapshot
    }
}

/// A provider that stays in flight long enough to watch the panel while the header
/// spinner is running. `load()` is synchronous and `UsageViewModel` runs it on a detached
/// task, so the sleep parks that task instead of the main actor — the panel keeps
/// laying out and animating while the refresh is still pending.
private struct SlowFixtureProvider: UsageProvider {
    let id: UsageProviderID
    let delay: TimeInterval

    func load() throws -> UsageSnapshot {
        Thread.sleep(forTimeInterval: delay)
        let totals = UsageTotals(
            turns: 1, requests: 1, inputTokens: 1, outputTokens: 1, reasoningTokens: 0,
            cacheReadInputTokens: 0, cacheCreationInputTokens: 0, toolCalls: 0
        )
        return UsageSnapshot(refreshedAt: Date(), totals: totals, today: totals, models: [])
    }
}
