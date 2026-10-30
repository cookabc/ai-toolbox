import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel
    @StateObject private var configModel = LiveConfigViewModel()
    @State private var selectedTool: LiveConfigApp = .codex
    @State private var showsConfig = false
    private let initialShowsAdvanced: Bool

    init(
        model: UsageViewModel,
        initialSelectedTool: LiveConfigApp = .codex,
        initialShowsConfig: Bool = false,
        configViewModel: LiveConfigViewModel? = nil,
        initialShowsAdvanced: Bool = false
    ) {
        self.model = model
        self.initialShowsAdvanced = initialShowsAdvanced
        _selectedTool = State(initialValue: initialSelectedTool)
        _showsConfig = State(initialValue: initialShowsConfig)
        _configModel = StateObject(wrappedValue: configViewModel ?? LiveConfigViewModel())
        _bodyHeight = State(
            initialValue: Self.cachedHeight(
                Self.bodyHeightKey(tool: initialSelectedTool, config: initialShowsConfig),
                fallback: Self.panelMaxHeight
            ))
        _chromeHeight = State(initialValue: Self.cachedHeight(Self.chromeHeightKey, fallback: 0))
    }

    /// The panel is content-fitted, so it never leaves a blank area under short
    /// content, but capped so a long provider list cannot run off the bottom of the
    /// screen.
    ///
    /// A fitted height means the window changes size as you switch tools, and AppKit
    /// resizes a window by keeping its *origin* (bottom-left). The panel hangs from
    /// the menu bar, so its **top** edge is the one that must not move. `PanelTopAnchor`
    /// takes this height and applies it together with the menu-bar anchoring, which is
    /// what makes a fitted height safe here — see that type for why the two belong in
    /// one operation.
    ///
    /// This is the **total** panel height, chrome included; the body is capped at
    /// `panelMaxHeight - chromeHeight` so the whole panel — not just the body — stays
    /// within the limit.
    ///
    /// 660pt fits the usage page with four models and no scrolling, and still leaves
    /// room on the smallest current MacBook screen (about 875pt below the menu bar).
    static let panelWidth: CGFloat = 400
    static let panelMaxHeight: CGFloat = 660

    /// The chrome's rows have fixed, grid-aligned heights: the header, the tab row
    /// (a 32-point well plus 8 below it) and the 2-point edge under them.
    static let headerHeight: CGFloat = 44
    static let tabRowHeight: CGFloat = 40
    static let chromeEdge: CGFloat = Pixel.border
    static var designChromeHeight: CGFloat { headerHeight + tabRowHeight + chromeEdge }

    /// While a confirmation is up the panel is at least this tall, so a short page
    /// (one provider, no list) still has room for the dialog.
    static let dialogMinimumHeight: CGFloat = 340

    /// Natural height of the mode-dependent content, measured during layout.
    ///
    /// Seeded from the **last measured height for this tool and mode** rather than from
    /// the maximum. Both a 0 seed and a maximum seed force a resize on every open — the
    /// first frame is wrong by the whole height difference, the window is already on
    /// screen when it is corrected, and a resize is what moves the top edge. Remembering
    /// the height makes the first frame right for every tool you have already looked at,
    /// which removes the jump at open rather than correcting it afterwards.
    @State private var bodyHeight: CGFloat = panelMaxHeight
    /// Height of the header + mode bar, measured so the body's cap stays correct when
    /// the chrome changes instead of relying on a hard-coded number. Also remembered,
    /// for the same reason — it is part of the first frame's height.
    @State private var chromeHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            chrome
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ChromeHeightKey.self, value: proxy.size.height)
                    }
                }
            panelBody
        }
        .disabled(isPresentingDialog)
        .accessibilityHidden(isPresentingDialog)
        .frame(width: Self.panelWidth)
        .frame(height: panelHeight, alignment: .top)
        .overlay { dialog }
        .tint(Ink.accent)
        .background(Ink.canvas)
        .background(
            PanelTopAnchor(height: panelHeight, onOpen: panelDidOpen).frame(width: 0, height: 0)
        )
        .onPreferenceChange(ChromeHeightKey.self) { measured in
            if abs(measured - chromeHeight) > 0.5 { chromeHeight = measured }
        }
        .onChange(of: bodyHeight) { newValue in
            Self.rememberHeight(newValue, Self.bodyHeightKey(tool: selectedTool, config: showsConfig))
        }
        .onChange(of: chromeHeight) { newValue in
            Self.rememberHeight(newValue, Self.chromeHeightKey)
        }
        .animation(nil, value: selectedTool)
        .animation(nil, value: showsConfig)
        .onAppear(perform: syncOnAppear)
    }

    /// The only region whose content differs between tools and modes.
    ///
    /// The scroll view is given a **definite** height — `min(content, cap)` — rather
    /// than a flexible one. Both alternatives are broken here, and neither is obvious:
    ///
    /// - A plain flexible `ScrollView` accepts whatever height it is proposed, so
    ///   `MenuBarExtra` opening the window small leaves the body at ~0pt and the panel
    ///   shows only its header. It is a stable (self-consistent) wrong answer, so it
    ///   never recovers.
    /// - `fixedSize` on the scroll view makes it as tall as its content, ignoring the
    ///   cap — tall content is then clipped by the window and cannot be scrolled to.
    ///
    /// So the content is measured, and the height is set explicitly. `bodyHeight` starts
    /// from the height remembered for this tool and mode, so the first frame is already
    /// close and the window has less to grow or shrink through.
    @ViewBuilder
    private var panelBody: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if showsConfig {
                    LiveConfigView(model: configModel, initialShowsAdvanced: initialShowsAdvanced)
                } else {
                    UsageDetailView(model: model, openDataDirectory: openDataDirectory)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelBodyHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .frame(height: min(max(bodyHeight, 1), maxBodyHeight))
        .onPreferenceChange(PanelBodyHeightKey.self) { measured in
            if abs(measured - bodyHeight) > 0.5 { bodyHeight = measured }
        }
    }

    /// What the body may occupy once the chrome has taken its share of the panel.
    /// Derived rather than hard-coded so `panelMaxHeight` stays the *total* limit even
    /// if the header changes.
    private var maxBodyHeight: CGFloat {
        max(1, Self.panelMaxHeight - chromeHeight)
    }

    /// The panel's total height: measured content plus measured chrome, clamped to
    /// `panelMaxHeight`.
    ///
    /// Set explicitly on the root view rather than letting the stack sum its children.
    /// Left to sum, the seed values (`bodyHeight` at the cap while `chromeHeight` is
    /// still unmeasured) produce a first frame of cap + chrome — a full chrome height over the
    /// limit — and an over-tall frame shrinking is exactly the resize that drags the top
    /// edge away from the menu bar. Clamping the total means the first frame is already
    /// within the limit.
    private var panelHeight: CGFloat {
        let fitted = min(maxBodyHeight, max(bodyHeight, 1)) + chromeHeight
        guard isPresentingDialog else { return fitted }
        return min(Self.panelMaxHeight, max(fitted, Self.dialogMinimumHeight))
    }

    // MARK: - Remembered heights

    private static func bodyHeightKey(tool: LiveConfigApp, config: Bool) -> String {
        "panelBodyHeight.\(tool.rawValue).\(config ? "config" : "usage")"
    }

    private static let chromeHeightKey = "panelChromeHeight"

    /// A remembered height is only ever used as a starting point — it is clamped and
    /// replaced by the first real measurement — so a stale value costs one extra frame
    /// rather than a wrong layout.
    private static func cachedHeight(_ key: String, fallback: CGFloat) -> CGFloat {
        let value = UserDefaults.standard.double(forKey: key)
        guard value > 1 else { return fallback }
        return min(CGFloat(value), panelMaxHeight)
    }

    private static func rememberHeight(_ value: CGFloat, _ key: String) {
        guard value > 1, value <= panelMaxHeight else { return }
        UserDefaults.standard.set(Double(value), forKey: key)
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            header
            toolModeBar
            Rectangle().fill(Ink.chromeLine).frame(height: Self.chromeEdge)
        }
        .background(Ink.chrome)
    }

    private var header: some View {
        HStack(spacing: Pixel.Space.m) {
            AppMark(scale: 2)
            Text(L10n.App.title)
                .font(.pixel(2))
                .foregroundStyle(Ink.chromeText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let stamp = headerStamp {
                Text(stamp.text)
                    .font(.pixel())
                    .foregroundStyle(stamp.isProblem ? Ink.fixed(0xFFC86E) : Ink.chromeMuted)
                    .lineLimit(1)
            }
            headerToolbar
        }
        .padding(.horizontal, Pixel.Space.xl)
        .frame(height: Self.headerHeight)
    }

    private var headerIsBusy: Bool {
        showsConfig ? configModel.isBusy : model.isRefreshing
    }

    private var headerToolbar: some View {
        HStack(spacing: 0) {
            Button {
                if showsConfig {
                    configModel.reload()
                } else {
                    model.refresh()
                }
            } label: {
                Group {
                    if headerIsBusy {
                        PixelSpinner()
                    } else {
                        PixelIconView(.refresh)
                    }
                }
            }
            .buttonStyle(PixelIconButtonStyle(context: .chrome))
            .pixelFocusEffect()
            .disabled(headerIsBusy)
            .keyboardShortcut("r", modifiers: .command)
            .help(showsConfig ? L10n.Header.reloadConfig : L10n.Header.refreshUsage)
            .accessibilityLabel(showsConfig ? L10n.Header.reloadConfig : L10n.Header.refreshUsage)
            .accessibilityValue(headerIsBusy ? L10n.Common.busy : "")
            .panelID(PanelID.refresh)

            Button(action: openDataDirectory) {
                PixelIconView(.folder)
            }
            .buttonStyle(PixelIconButtonStyle(context: .chrome))
            .pixelFocusEffect()
            .help(L10n.Header.openDataDirectory)
            .accessibilityLabel(L10n.Header.openDataDirectory)
            .panelID(PanelID.openDataDirectory)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                PixelIconView(.power)
            }
            .buttonStyle(PixelIconButtonStyle(context: .chrome))
            .pixelFocusEffect()
            .keyboardShortcut("q", modifiers: .command)
            .help(L10n.Header.quit)
            .accessibilityLabel(L10n.Header.quit)
            .panelID(PanelID.quit)
        }
    }

    private var toolModeBar: some View {
        HStack(spacing: Pixel.Space.m) {
            PixelTabWell {
                ForEach(LiveConfigApp.allCases) { app in
                    let isSelected = selectedTool == app
                    Button {
                        selectTool(app)
                    } label: {
                        HStack(spacing: Pixel.Space.s) {
                            ToolBrandMark(app: app)
                            Text(app.title)
                        }
                    }
                    .buttonStyle(PixelTabStyle(isSelected: isSelected))
                    .pixelFocusEffect()
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .panelID(PanelID.tool(app))
                }
            }
            // Both wells are sized to their longest label, which the two tabs share
            // equally: "Claude Code" here, "Config" there. The two widths together with
            // the row's gaps and padding come to `panelWidth` exactly, so a wider label
            // needs this pair rebalanced rather than one of them widened.
            .frame(width: 216, height: 32)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.Header.toolPicker)

            Spacer(minLength: 0)

            PixelTabWell {
                modeTab(
                    L10n.Mode.usage, help: L10n.Mode.usageHelp, icon: .usage,
                    id: PanelID.modeUsage, isSelected: !showsConfig
                ) {
                    guard showsConfig else { return }
                    showsConfig = false
                }
                modeTab(
                    L10n.Mode.config, help: L10n.Mode.configHelp, icon: .config,
                    id: PanelID.modeConfig, isSelected: showsConfig
                ) {
                    guard !showsConfig else { return }
                    showsConfig = true
                }
            }
            .frame(width: 144, height: 32)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.Header.modePicker)
        }
        .padding(.horizontal, Pixel.Space.xl)
        .padding(.bottom, Pixel.Space.m)
        .frame(height: Self.tabRowHeight, alignment: .top)
    }

    private func modeTab(
        _ title: String, help: String, icon: PixelIcon, id: String, isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Pixel.Space.xs) {
                PixelIconView(icon)
                Text(title)
            }
        }
        .buttonStyle(PixelTabStyle(isSelected: isSelected))
        .pixelFocusEffect()
        .help(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .panelID(id)
    }

    /// The freshness of what is on screen, or what is happening to it.
    private var headerStamp: (text: String, isProblem: Bool)? {
        if showsConfig { return nil }
        if model.isRefreshing { return (L10n.Header.reading, false) }
        if model.errorMessage != nil && model.snapshot == nil { return (L10n.Header.readFailed, true) }
        if let refreshedAt = model.snapshot?.refreshedAt {
            let time = Format.time(refreshedAt, withDate: !model.isCurrent(model.selectedProvider))
            return (L10n.Header.updated(time), false)
        }
        return nil
    }

    // MARK: - Dialog

    private var isPresentingDialog: Bool { configModel.pendingConfirmation != nil }

    @ViewBuilder private var dialog: some View {
        if let pending = configModel.pendingConfirmation {
            PixelDialog(
                title: pending.title,
                message: pending.message,
                confirmTitle: pending.confirmTitle,
                cancelTitle: L10n.Config.cancel,
                onConfirm: { configModel.confirmPending() },
                onCancel: { configModel.cancelPending() }
            )
        }
    }

    // MARK: - Selection and lifecycle

    private func selectTool(_ tool: LiveConfigApp) {
        guard selectedTool != tool else { return }
        selectedTool = tool
        model.select(tool.usageProvider)
        configModel.app = tool
        persistSelectedTool(tool)
    }

    private func syncOnAppear() {
        let saved = UserDefaults.standard.string(forKey: Self.selectedToolKey)
        let tool =
            LiveConfigApp(rawValue: saved ?? "")
            ?? LiveConfigApp(usageProvider: model.selectedProvider)
            ?? .codex
        selectedTool = tool
        model.selectedProvider = tool.usageProvider
        configModel.app = tool
        persistSelectedTool(tool)
        panelDidOpen()
    }

    /// Both halves go stale while the panel is closed: transcripts keep growing and
    /// the CLIs rewrite their own config files. Reloading the config never touches an
    /// open draft, so it is safe to do on every open. A confirmation belongs to the
    /// moment it was asked in, so one left open when the panel closed is dropped.
    private func panelDidOpen() {
        model.panelDidOpen()
        configModel.cancelPending()
        configModel.reload()
    }

    private func persistSelectedTool(_ tool: LiveConfigApp) {
        UserDefaults.standard.set(tool.rawValue, forKey: Self.selectedToolKey)
    }

    private static let selectedToolKey = "selectedTool"

    /// Opens the directory the current view reads, or the closest folder above it
    /// that exists: a tool that has never run has no directory yet, and a button
    /// that silently does nothing reads as broken.
    private func openDataDirectory() {
        var directory = showsConfig ? configModel.configDirectory : model.selectedProvider.directory
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while !FileManager.default.fileExists(atPath: directory.path),
            directory.standardizedFileURL.path != home
        {
            directory.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(directory)
    }
}

/// Reports the natural height of the panel body's content, which the panel uses to
/// size itself (clamped to the panel's remaining budget).
private struct PanelBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the height of the header + mode bar, so the body's cap can be derived
/// instead of hard-coded.
private struct ChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
