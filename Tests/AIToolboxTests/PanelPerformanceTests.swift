import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AIToolbox

/// 固定时刻，让每次跑出的 fixture 完全一致。
private let panelTestDate = Date(timeIntervalSince1970: 1_760_000_000)

/// 数 `@Published` 写入次数用；只在这条测试的主线程上读写。
private final class MainCounter: @unchecked Sendable {
  var value = 0
}

/// 面板 UI 响应基线：渲染耗时与打开面板的主线程耗时。
///
/// 与 037-vitals 用同一口径，便于跨工程比较：
/// `NSHostingView` 真实加载视图，`cacheDisplay` 强制绘制成位图后统计分布。
/// 数据源是 fixture（`UsageFixtures` / `LiveConfigViewModel.documentation`），
/// 因此不随本机 transcript 数量或真实配置文件漂移。
///
/// 量的是**有数据的面板**：没有 snapshot 时画的是空状态，那比真实首帧便宜得多，
/// 拿它当基线会低估优化空间。
///
/// 这些数字是**改前**基线，优化后必须用同一条命令复测。
@MainActor
final class PanelPerformanceTests: XCTestCase {
  private func makeUsageModel() async -> UsageViewModel {
    let model = UsageViewModel(
      providers: [FixtureProvider(id: .codex, snapshot: UsageFixtures.snapshot(at: panelTestDate, models: 4))],
      preferences: nil,
      now: { panelTestDate }
    )
    model.refreshAll()
    for _ in 0..<200 {
      if model.snapshot != nil { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNotNil(model.snapshot, "fixture 没读到，量到的会是空状态而非真实面板")
    return model
  }

  private func makePanel(showsConfig: Bool) async -> UsagePopoverView {
    UsagePopoverView(
      model: await makeUsageModel(),
      initialSelectedTool: .codex,
      initialShowsConfig: showsConfig,
      configViewModel: .documentation(app: .codex))
  }

  /// 面板自己按测量结果定高，首帧前几轮是错的；先收敛再计时，量到的才是稳定态。
  private func paint(_ view: UsagePopoverView) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    for _ in 0..<10 {
      host.layoutSubtreeIfNeeded()
      let fitted = host.fittingSize
      if abs(fitted.height - host.frame.height) < 0.5 { break }
      host.frame = NSRect(origin: .zero, size: fitted)
    }
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }

  private func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 8, h > 8, let base = rep.colorAt(x: 2, y: 2) else { return 0 }
    var counted = 0, inked = 0
    var x = 0
    while x < w {
      var y = 0
      while y < h {
        if let c = rep.colorAt(x: x, y: y) {
          let delta = abs(c.redComponent - base.redComponent)
            + abs(c.greenComponent - base.greenComponent)
            + abs(c.blueComponent - base.blueComponent)
          if delta > 0.12 { inked += 1 }
          counted += 1
        }
        y += 3
      }
      x += 3
    }
    return counted > 0 ? Double(inked) / Double(counted) : 0
  }

  private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    let w = min(a.pixelsWide, b.pixelsWide), h = min(a.pixelsHigh, b.pixelsHigh)
    var differs = 0
    for x in stride(from: 0, to: w, by: 2) {
      for y in stride(from: 0, to: h, by: 2) {
        guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
        let delta = abs(ca.redComponent - cb.redComponent)
          + abs(ca.greenComponent - cb.greenComponent)
          + abs(ca.blueComponent - cb.blueComponent)
        if delta > 0.12 { differs += 1 }
      }
    }
    return differs
  }

  private func percentile(_ samples: [UInt64], _ q: Double) -> UInt64 {
    let index = max(0, min(samples.count - 1, Int((Double(samples.count) * q).rounded()) - 1))
    return samples[index]
  }

  /// 等所有读取落地。`objectWillChange` 的计数只在读取结束后才可比。
  private func waitUntilIdle(_ model: UsageViewModel) async {
    for _ in 0..<200 {
      if model.sourceIDs.allSatisfy({ model.states[$0]?.isRefreshing != true }) { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("读取超过 1 秒仍未结束")
  }

  // MARK: - 功能门禁

  func testPanelPaintsContent() async throws {
    let rep = try paint(await makePanel(showsConfig: false))
    XCTAssertGreaterThanOrEqual(rep.pixelsWide, Int(UsagePopoverView.panelWidth) - 2)
    let coverage = inkCoverage(rep)
    XCTAssertGreaterThan(coverage, 0.02, "画面接近空白（覆盖率 \(coverage)），渲染链路可能已断")
  }

  /// 模式切换必须真的驱动到像素：config 页与 usage 页画出来不同。
  func testModeSwitchChangesOutput() async throws {
    let usage = try paint(await makePanel(showsConfig: false))
    let config = try paint(await makePanel(showsConfig: true))
    let differs = differingPixels(usage, config)
    XCTAssertGreaterThan(differs, 200, "切换模式后画面几乎没变（差异像素 \(differs)）")
  }

  // MARK: - 重绘次数

  /// 一次读取让整棵面板重绘几次。
  ///
  /// 面板观察的是同一个 `ObservableObject`，每次 `@Published` 写入都是一次全树 body
  /// 重算——上面量到的单次渲染耗时正是因此被反复支付。改前：定时读取每 30 秒为**每个**
  /// 工具跑一遍，每遍 3 次写入（开始、落地、以及一次无条件的进度集合写入）；
  /// 改后：定时只读屏幕上那个工具，每遍 2 次。
  func testRefreshInvalidationCount() async throws {
    let model = UsageViewModel(
      providers: [
        FixtureProvider(id: .codex, snapshot: UsageFixtures.snapshot(at: panelTestDate, models: 4)),
        FixtureProvider(id: .claude, snapshot: UsageFixtures.snapshot(at: panelTestDate, models: 3)),
      ],
      preferences: nil,
      now: { panelTestDate })
    model.refreshAll()
    await waitUntilIdle(model)

    let counter = MainCounter()
    let subscription = model.objectWillChange.sink { _ in counter.value += 1 }
    defer { subscription.cancel() }

    // 定时读取：只有选中的工具。
    model.refreshSelected()
    await waitUntilIdle(model)
    let timerCycle = counter.value
    print("PUBLISHES_TIMER_CYCLE \(timerCycle)")
    XCTAssertLessThanOrEqual(timerCycle, 2, "一次静默读取应只有开始与落地两次发布")

    // 全量读取（打开面板时）：每个工具各一次。
    counter.value = 0
    model.refreshAll()
    await waitUntilIdle(model)
    let fullCycle = counter.value
    print("PUBLISHES_FULL_REFRESH \(fullCycle)")
    XCTAssertLessThanOrEqual(fullCycle, 2 * model.sourceIDs.count,
                             "全量刷新按工具计，每工具开始与落地各一次")
  }

  // MARK: - 耗时基线

  /// 面板整帧绘制（含视图树构建与首帧布局）。
  func testPanelRenderCost() async throws {
    let panel = await makePanel(showsConfig: false)
    _ = try paint(panel)  // 预热：首帧含字体与位图上下文建立开销
    var samples: [UInt64] = []
    samples.reserveCapacity(24)
    for _ in 0..<24 {
      let start = DispatchTime.now().uptimeNanoseconds
      _ = try paint(panel)
      samples.append((DispatchTime.now().uptimeNanoseconds - start) / 1000)
    }
    samples.sort()
    print("RENDER_US p50=\(percentile(samples, 0.5)) p95=\(percentile(samples, 0.95)) max=\(samples.last!) n=\(samples.count)")
    XCTAssertLessThan(percentile(samples, 0.95), 150_000, "单次面板渲染 p95 超过 150ms 预算")
  }

  /// 打开面板时主线程上的同步文件读取（`LiveConfigViewModel.reload()`）。
  ///
  /// 用临时目录里的真实形状文件，不碰用户的 `~/.codex` 与 `~/.claude`。
  /// 面板可见期间该调用每次打开都会跑一遍，且它整个在 MainActor 上。
  func testReloadMainThreadCost() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "aitoolbox-reload-\(UUID().uuidString)", directoryHint: .isDirectory)
    let codexHome = root.appending(path: ".codex", directoryHint: .isDirectory)
    let claudeHome = root.appending(path: ".claude", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = (1...8).map { index in
      StoredProvider(app: .codex, name: "Relay \(index)", slug: "relay-\(index)",
                     baseURL: "https://relay\(index).example/v1", model: "gpt-5",
                     apiKey: "sk-relay-\(index)-key")
    }
    try ProviderLibraryStore(url: root.appending(path: "providers.json"))
      .save(library)
    let codexToml = library.map { provider in
      """
      [model_providers.\(provider.slug)]
      name = "\(provider.name)"
      base_url = "\(provider.baseURL)"
      wire_api = "chat"

      """
    }.joined() + "model = \"gpt-5\"\n"
    try codexToml.write(
      to: codexHome.appending(path: "config.toml"), atomically: true, encoding: .utf8)
    try """
      {
        "env": {
          "ANTHROPIC_BASE_URL": "https://relay.example/v1",
          "ANTHROPIC_MODEL": "claude-sonnet-4",
          "ANTHROPIC_AUTH_TOKEN": "sk-ant-doc-token"
        },
        "permissions": { "defaultMode": "acceptEdits" }
      }
      """.write(
      to: claudeHome.appending(path: "settings.json"), atomically: true, encoding: .utf8)

    let paths = LiveConfigPaths(
      claudeSettings: claudeHome.appending(path: "settings.json"),
      codexConfig: codexHome.appending(path: "config.toml"))
    let model = LiveConfigViewModel(
      paths: paths, library: ProviderLibraryStore(url: root.appending(path: "providers.json")))

    model.reload()  // 预热：首次含 JSON/TOML 解析器的懒初始化
    var samples: [UInt64] = []
    samples.reserveCapacity(15)
    for _ in 0..<15 {
      let start = DispatchTime.now().uptimeNanoseconds
      model.reload()
      samples.append((DispatchTime.now().uptimeNanoseconds - start) / 1000)
    }
    samples.sort()
    print("RELOAD_US p50=\(percentile(samples, 0.5)) p95=\(percentile(samples, 0.95)) max=\(samples.last!) n=\(samples.count)")
    // 上限先宽：这是改前基线，优化后收紧到 1/10。
    XCTAssertLessThan(percentile(samples, 0.95), 200_000)
  }
}
