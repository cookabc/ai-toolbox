import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var model: UsageViewModel
    @StateObject private var configModel = LiveConfigViewModel()
    @State private var selectedTool: LiveConfigApp = .codex
    @State private var showsConfig = false
    @State private var pendingClearClaude = false

    init(
        model: UsageViewModel,
        initialSelectedTool: LiveConfigApp = .codex,
        initialShowsConfig: Bool = false,
        configViewModel: LiveConfigViewModel? = nil
    ) {
        self.model = model
        _selectedTool = State(initialValue: initialSelectedTool)
        _showsConfig = State(initialValue: initialShowsConfig)
        _configModel = StateObject(wrappedValue: configViewModel ?? LiveConfigViewModel())
        _bodyHeight = State(initialValue: Self.cachedHeight(
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
    static let panelWidth: CGFloat = 400
    static let panelMaxHeight: CGFloat = 602

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
            VStack(spacing: 0) {
                header
                toolModeBar
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ChromeHeightKey.self, value: proxy.size.height)
                }
            }
            panelBody
        }
        .frame(width: Self.panelWidth)
        .frame(height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(PanelTopAnchor(height: panelHeight).frame(width: 0, height: 0))
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
        .confirmationDialog("清除 Claude Code 的 API 覆盖项？", isPresented: $pendingClearClaude, titleVisibility: .visible) {
            Button("清除覆盖项", role: .destructive) { configModel.clearClaudeOverlay() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 ~/.claude/settings.json 移除 Base URL、模型和 API Key 等覆盖项，其余 env 项保留。供应商库不受影响。")
        }
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
                    LiveConfigView(model: configModel)
                } else {
                    usageBody
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
    /// still unmeasured) produce a first frame of cap + chrome — 704pt against a 602pt
    /// limit — and an over-tall frame shrinking is exactly the resize that drags the top
    /// edge away from the menu bar. Clamping the total means the first frame is already
    /// within the limit.
    private var panelHeight: CGFloat {
        min(maxBodyHeight, max(bodyHeight, 1)) + chromeHeight
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

    @ViewBuilder
    private var usageBody: some View {
        if let warning = model.sourceWarning(model.selectedProvider) {
            staleBanner(warning)
        }
        if let snapshot = model.snapshot {
            VStack(spacing: 10) {
                Text(snapshot.coverage.note)
                    .font(.caption2).foregroundStyle(.secondary)
                todayCard(snapshot.today)
                lifetimeCard(snapshot.totals)
                if !snapshot.models.isEmpty { modelsCard(snapshot.models) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        } else {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(AppBranding.title)
                .font(.system(.headline, design: .rounded))
            if !headerSubtitle.isEmpty {
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            headerToolbar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerIsBusy: Bool {
        showsConfig ? configModel.isBusy : model.isRefreshing
    }

    @ViewBuilder
    private var headerToolbar: some View {
        HStack(spacing: 0) {
            if showsConfig && selectedTool == .claude {
                HeaderIconButton(
                    systemName: "eraser",
                    help: "清除 Claude API 覆盖项",
                    disabled: configModel.isBusy
                ) {
                    pendingClearClaude = true
                }
            }

            HeaderIconButton(
                systemName: "arrow.clockwise",
                help: showsConfig ? "重新读取配置（⌘R）" : "刷新用量（⌘R）",
                disabled: headerIsBusy,
                spinning: headerIsBusy
            ) {
                if showsConfig {
                    configModel.reload()
                } else {
                    model.refresh()
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            HeaderIconButton(
                systemName: "folder",
                help: "打开数据目录"
            ) {
                openDataDirectory()
            }

            HeaderIconButton(
                systemName: "power",
                help: "退出 \(AppBranding.title)（⌘Q）"
            ) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .frame(height: 32)
    }

    private var toolModeBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(LiveConfigApp.allCases) { app in
                    toolTab(app)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(4)
            .frame(minHeight: 36)
            .background(Color.primary.opacity(0.06), in: Capsule())

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                modeTab(title: "用量", icon: "chart.bar", isSelected: !showsConfig) {
                    guard showsConfig else { return }
                    showsConfig = false
                }
                .frame(maxWidth: .infinity)
                modeTab(title: "配置", icon: "slider.horizontal.3", isSelected: showsConfig) {
                    guard !showsConfig else { return }
                    showsConfig = true
                }
                .frame(maxWidth: .infinity)
            }
            .padding(4)
            .frame(width: 92, height: 36)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func toolTab(_ app: LiveConfigApp) -> some View {
        let isSelected = selectedTool == app
        return Button {
            selectTool(app)
        } label: {
            HStack(spacing: 5) {
                ToolBrandImage(app: app, size: 14)
                Text(app.title)
                    .lineLimit(1)
            }
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.horizontal, 6)
            .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear, in: Capsule())
            .shadow(color: .black.opacity(isSelected ? 0.06 : 0), radius: 2, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func modeTab(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var headerSubtitle: String {
        if showsConfig { return "" }
        if model.isRefreshing { return "· 正在刷新…" }
        if model.errorMessage != nil && model.snapshot == nil { return "· 读取失败" }
        if let refreshedAt = model.lastCheckedAt {
            let dateStyle: Date.FormatStyle.DateStyle = model.isToday(model.selectedProvider) ? .omitted : .abbreviated
            return "· \(refreshedAt.formatted(date: dateStyle, time: .shortened)) 检查"
        }
        return "· 等待读取"
    }

    // MARK: - Today

    private func todayCard(_ totals: UsageTotals) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日输出")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(model.todayDisplay(totals.outputTokens, metric: .output))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    Spacer(minLength: 8)
                    LazyVGrid(
                        columns: [GridItem(.fixed(82), alignment: .leading), GridItem(.fixed(82), alignment: .leading)],
                        alignment: .leading,
                        spacing: 5
                    ) {
                        compactMetric("输入", model.todayDisplay(totals.inputTokens, metric: .input))
                        compactMetric("回合", model.todayDisplay(totals.turns, metric: .turns))
                        compactMetric("请求", model.todayDisplay(totals.requests, metric: .requests))
                        compactMetric("工具", model.todayDisplay(totals.toolCalls, metric: .tools))
                    }
                }
                Divider().opacity(0.55)
                if model.snapshot?.coverage.supportsInputComposition == true && model.isToday(model.selectedProvider) {
                    inputComposition(totals)
                } else {
                    HStack {
                        compactMetric("缓存读", model.todayDisplay(totals.cacheReadInputTokens, metric: .cacheRead))
                        compactMetric("缓存" + (model.snapshot?.coverage.cacheWriteLabel ?? "写入"), model.todayDisplay(totals.cacheCreationInputTokens, metric: .cacheWrite))
                    }
                    Text("输入及缓存均按来源记录；不推算非缓存输入")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func inputComposition(_ totals: UsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("输入构成")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if totals.inputTokens > 0 {
                    Text("缓存 \(Format.percent(totals.cacheReadShare))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("暂无输入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            CompositionBar(totals: totals)
                .frame(height: 6)
                .accessibilityLabel("输入构成：缓存读 \(model.display(totals.cacheReadInputTokens, metric: .cacheRead))，缓存创建 \(Format.token(totals.cacheCreationInputTokens))，非缓存输入 \(Format.token(totals.freshInputTokens))")
            HStack(spacing: 8) {
                compositionLegend("缓存读", totals.cacheReadInputTokens, color: .cyan)
                compositionLegend("创建", totals.cacheCreationInputTokens, color: .indigo)
                compositionLegend("非缓存", totals.freshInputTokens, color: .gray)
            }
        }
    }

    private func compositionLegend(_ title: String, _ value: Int64, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(title) \(Format.token(value))")
                .lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // MARK: - Lifetime

    private func lifetimeCard(_ totals: UsageTotals) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 7) {
                sectionHeading("累计用量", icon: "clock.arrow.circlepath")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    statTile("输入", model.display(totals.inputTokens, metric: .input), accent: .cyan)
                    statTile("输出", model.display(totals.outputTokens, metric: .output), accent: .indigo)
                    statTile("推理", model.display(totals.reasoningTokens, metric: .reasoning), accent: .purple)
                    statTile("缓存读", model.display(totals.cacheReadInputTokens, metric: .cacheRead), accent: .teal)
                }
                HStack(spacing: 5) {
                    activityMetric("回合", model.display(totals.turns, metric: .turns))
                    Text("·").foregroundStyle(.tertiary)
                    activityMetric("请求", model.display(totals.requests, metric: .requests))
                    Text("·").foregroundStyle(.tertiary)
                    activityMetric("工具", model.display(totals.toolCalls, metric: .tools))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func statTile(_ title: String, _ value: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityMetric(_ title: String, _ value: String) -> some View {
        Text("\(title) \(value)")
            .monospacedDigit()
    }

    // MARK: - Models

    private func modelsCard(_ models: [ModelUsage]) -> some View {
        SurfaceCard(compact: true) {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeading("模型（按输出排序）", icon: "cpu")
                let maximum = max(1, models.map(\.outputTokens).max() ?? 1)
                ForEach(Array(models.prefix(4))) { item in
                    ModelRow(item: item, maximumOutput: maximum)
                }
                Text("仅含可识别的本地用量；非账单")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - States / helpers

    private func staleBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.errorMessage != nil {
                Button("重试") { model.refresh() }
                    .buttonStyle(.borderless)
                    .disabled(model.isRefreshing)
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.10))
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: model.isRefreshing ? "externaldrive" : "externaldrive.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Text(model.isRefreshing ? "正在读取本地记录" : (model.errorMessage == nil ? "还没有可读的用量数据" : "暂时无法读取 \(model.selectedProvider.title)"))
                .font(.headline)
            Text(model.isRefreshing ? "首次读取可能需要一些时间，可先切换到其他工具。" : (model.errorMessage ?? "等待所选工具写入可识别的本地用量记录。"))
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280)
            HStack(spacing: 12) {
                Button("重新读取") { model.refresh() }
                    .disabled(model.isRefreshing)
                Button("打开数据目录") { openDataDirectory() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectTool(_ tool: LiveConfigApp) {
        guard selectedTool != tool else { return }
        selectedTool = tool
        model.selectedProvider = tool.usageProvider
        configModel.app = tool
        persistSelectedTool(tool)
    }

    private func syncOnAppear() {
        let saved = UserDefaults.standard.string(forKey: Self.selectedToolKey)
        let tool = LiveConfigApp(rawValue: saved ?? "")
            ?? LiveConfigApp(usageProvider: model.selectedProvider)
            ?? .codex
        selectedTool = tool
        model.selectedProvider = tool.usageProvider
        configModel.app = tool
        persistSelectedTool(tool)
        configModel.loadOnce()
    }

    private func persistSelectedTool(_ tool: LiveConfigApp) {
        UserDefaults.standard.set(tool.rawValue, forKey: Self.selectedToolKey)
    }

    private static let selectedToolKey = "selectedTool"

    private func openDataDirectory() {
        NSWorkspace.shared.open(showsConfig ? configModel.configDirectory : model.selectedProvider.directory)
    }
}

struct SurfaceCard<Content: View>: View {
    let compact: Bool
    let active: Bool
    @ViewBuilder let content: Content

    init(compact: Bool = false, active: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.active = active
        self.content = content()
    }

    var body: some View {
        content
            .padding(compact ? 10 : 12)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(active ? 0.05 : 0.035), radius: 4, x: 0, y: 2)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        active ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.07),
                        lineWidth: active ? 1 : 0.5
                    )
            }
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 8)
                }
            }
    }

    private var cardBackground: Color {
        active ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)
    }
}

private struct CompositionBar: View {
    let totals: UsageTotals

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let hasInput = totals.inputTokens > 0
            let readWidth = width * totals.cacheReadShare
            let creationWidth = width * totals.cacheCreationShare
            let freshWidth = width * totals.freshInputShare
            HStack(spacing: 2) {
                segment(.cyan, width: readWidth)
                segment(.indigo, width: creationWidth)
                segment(.gray.opacity(0.45), width: freshWidth)
            }
            .frame(width: width, alignment: .leading)
            .background(Color.primary.opacity(hasInput ? 0.05 : 0.10), in: Capsule())
            .clipShape(Capsule())
        }
    }

    private func segment(_ color: Color, width: CGFloat) -> some View {
        color
            .frame(width: max(0, width))
            .opacity(width > 0 ? 0.85 : 0)
    }
}

private struct ModelRow: View {
    let item: ModelUsage
    let maximumOutput: Int64

    private var share: Double {
        guard maximumOutput > 0 else { return 0 }
        return min(1, max(0, Double(item.outputTokens) / Double(maximumOutput)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(item.modelID)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(Format.token(item.outputTokens))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(item.providerID)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(Format.count(item.requests)) 请求")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * share))
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.modelID)，已记录输出 \(Format.token(item.outputTokens))，\(Format.count(item.requests)) 请求")
    }
}

private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var disabled: Bool = false
    var spinning: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if spinning {
                    SpinningSymbol(systemName: systemName)
                } else {
                    Image(systemName: systemName)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : Color.primary)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SpinningSymbol: View {
    let systemName: String
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: systemName)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
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
