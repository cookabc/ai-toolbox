import AppKit
import SwiftUI

enum ConsoleInk {
  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255,
          alpha: 1
        )
      })
  }

  static let chrome = adaptive(light: 0xFFFFFF, dark: 0x112134)
  static let chromeText = adaptive(light: 0x172D36, dark: 0xFFFFFF)
  static let chromeMuted = adaptive(light: 0x5A6B70, dark: 0xD6E8E6)
  static let chromeGroup = adaptive(light: 0xEFF2F2, dark: 0x344350)
  static let chromeSelected = adaptive(light: 0xFFFFFF, dark: 0x485A65)
  static let chromeSelectedText = adaptive(light: 0x172D36, dark: 0xFFFFFF)
  static let chromeModeSelected = adaptive(light: 0xDFEFEC, dark: 0x485A65)
  static let accent = adaptive(light: 0x0A6B6B, dark: 0x6BE5D4)
  static let signal = accent
  static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x112134)
}

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
      .background(ConsoleInk.chrome)
      .overlay(alignment: .bottom) {
        Rectangle().fill(ConsoleInk.signal.opacity(0.32)).frame(height: 1)
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
    .tint(ConsoleInk.accent)
    .background(Color(nsColor: .windowBackgroundColor))
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
    .confirmationDialog(
      "清除 Claude Code 的 API 覆盖项？", isPresented: $pendingClearClaude, titleVisibility: .visible
    ) {
      Button("清除覆盖项", role: .destructive) { configModel.clearClaudeOverlay() }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "将从 ~/.claude/settings.json 移除 Base URL、模型、API Key、模型别名，以及已保存供应商接管的 Key，让 Claude Code 回到它自己的登录。其余 env 项保留，供应商库不受影响。"
      )
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
  /// still unmeasured) produce a first frame of cap + chrome — a full chrome height over the
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

  private var usageBody: some View {
    UsageDetailView(model: model, openDataDirectory: openDataDirectory)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(AppBranding.title)
          .font(.system(size: 16, weight: .bold, design: .rounded))
          .foregroundStyle(ConsoleInk.chromeText)
        if !headerSubtitle.isEmpty {
          Text(headerSubtitle.replacingOccurrences(of: "· ", with: ""))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(ConsoleInk.chromeMuted)
        }
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
      .frame(width: 260, height: 36)
      .background(ConsoleInk.chromeGroup, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

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
      .background(ConsoleInk.chromeGroup, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
      .foregroundStyle(isSelected ? ConsoleInk.chromeSelectedText : ConsoleInk.chromeMuted)
      .frame(maxWidth: .infinity, minHeight: 28)
      .padding(.horizontal, 6)
      .background(
        isSelected ? ConsoleInk.chromeSelected : Color.clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .shadow(color: .black.opacity(isSelected ? 0.06 : 0), radius: 2, y: 1)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func modeTab(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: icon)
        .font(.caption.weight(isSelected ? .semibold : .medium))
        .symbolVariant(isSelected ? .fill : .none)
        .foregroundStyle(isSelected ? ConsoleInk.signal : ConsoleInk.chromeMuted)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(
          isSelected ? ConsoleInk.chromeModeSelected : Color.clear,
          in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }

  private var headerSubtitle: String {
    if showsConfig { return "" }
    if model.isRefreshing { return "· 正在读取…" }
    if model.errorMessage != nil && model.snapshot == nil { return "· 读取失败" }
    if let refreshedAt = model.snapshot?.refreshedAt {
      return "· \(Format.time(refreshedAt, withDate: !model.isCurrent(model.selectedProvider))) 更新"
    }
    return ""
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
  /// open draft, so it is safe to do on every open.
  private func panelDidOpen() {
    model.panelDidOpen()
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
      .background(cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(
            active ? ConsoleInk.accent.opacity(0.52) : Color.primary.opacity(0.12),
            lineWidth: 1
          )
      }
      .overlay(alignment: .leading) {
        if active {
          Rectangle()
            .fill(ConsoleInk.signal)
            .frame(width: 4)
            .padding(.vertical, 9)
        }
      }
  }

  private var cardBackground: Color {
    active ? ConsoleInk.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor)
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
      .foregroundStyle(disabled ? ConsoleInk.chromeMuted.opacity(0.35) : ConsoleInk.chromeText)
      .frame(width: 32, height: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .help(help)
    .accessibilityLabel(help)
  }
}

/// The refresh icon while a reload is in flight.
///
/// The angle comes from the timeline rather than from a
/// `withAnimation(…repeatForever(autoreverses: false))` started in `onAppear`. An endless
/// animation never completes, so it is still in flight when the next layout pass
/// repositions the views around it: the panel's own title and tool-tab labels are
/// re-laid-out in that same transaction, inherit the endless animation, and then slide
/// forever — a drift that survives closing and reopening the panel and only goes away
/// when the app is relaunched. A timeline has no animation for anything to inherit: the
/// angle is a pure function of the date.
private struct SpinningSymbol: View {
  let systemName: String

  private static let period: TimeInterval = 0.8

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      Image(systemName: systemName)
        .rotationEffect(.degrees(Self.angle(at: context.date)))
    }
  }

  private static func angle(at date: Date) -> Double {
    let phase = date.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: period)
    return phase / period * 360
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
