# 面板 UI 响应基线（036_ai-toolbox）

复测命令（唯一口径，改前改后都用它）：

```bash
swift test --filter PanelPerformanceTests
```

门禁与指标都在这一个测试类里：`Tests/AIToolboxTests/PanelPerformanceTests.swift`。

## 测量方式

菜单栏 app 的 popover 不适合 XCUITest（状态项不在被测 app 的元素树里，transient popover
会在失焦时被销毁），所以基线是**进程内**的：`NSHostingView` 真实加载 `UsagePopoverView`，
`fittingSize` 收敛到稳定高度后用 `cacheDisplay` 强制绘制成位图。

- 功能门禁（防止优化把界面改坏）：`testPanelPaintsContent` 断言绘制结果的墨点覆盖率
  > 2%；`testModeSwitchChangesOutput` 断言 usage 页与 config 页的差异像素 > 200。
- 数据源固定：`UsageFixtures.snapshot(at:models:)` 配一个固定时刻
  （`Date(timeIntervalSince1970: 1_760_000_000)`），数字不随本机 transcript 数量漂移。
- 量的是**有数据的面板**：没有 snapshot 时画的是空状态，比真实首帧便宜得多，拿它当基线会
  低估优化空间。

## 口径二：unified log / Instruments 打点

`UsageViewModel.states` 的每次写入同时发一条 `io.github.cookabc.ai-toolbox` 日志行
（`publish field=states`）和一个 `os_signpost` 事件，仅 DEBUG
（`Sources/AIToolbox/PerfSignposts.swift`）。这样写入门控能在测试自己的 Combine 计数之外被读到：

```bash
swift test --filter PanelPerformanceTests
/usr/bin/log show --last 90s --predicate 'subsystem == "io.github.cookabc.ai-toolbox"' \
  --info --debug --style compact | grep -c 'publish field=states'
```

2026-10-15 实测：同一轮里 Combine 计数仍是 `PUBLISHES_TIMER_CYCLE 2` / `PUBLISHES_FULL_REFRESH 4`，
日志侧收到 26 条 `publish field=states`（该窗口跑了 5 个用例）。
`log` 在 zsh 里是个函数，必须写 `/usr/bin/log`；`os_signpost` 事件不进 `log show`，
只在 Instruments 的时间轴里可见。真实会话（面板可见、30s 定时器）同样能这么收，但需要人手把面板打开。

## before / after

| 指标 | 改前 | 改后 |
| --- | --- | --- |
| `RENDER_US` 单次整帧绘制 p50 | 23 067 | 21 628 |
| `RENDER_US` p95 | 30 445 | 22 485 |
| `PUBLISHES_TIMER_CYCLE` 定时读取一轮的 `@Published` 写入 | 6（2 个工具 × 3） | **2** |
| `PUBLISHES_FULL_REFRESH` 全量读取一轮 | 8（2 个工具 × 4） | **4** |
| `RELOAD_US` 打开面板时的配置读取 p50 / p95 | 299 / 358 | 296 / 424（未改，同一噪声内） |

面板可见期间，每 30 秒的主线程整树重绘从 6 次降到 2 次。单次重绘约 21ms，也就是说
**每秒被界面自身占用的主线程时间从约 4.2ms 降到 1.4ms**；点击一次刷新少 2 次重绘。

改前的 6 次来自旧代码路径（`git show 323280a:Sources/AIToolbox/UsageViewModel.swift`）：
一次静默读取 = `states` 写入（开始）+ `states` 写入（落地）+ 一次无条件的
`visibleRefreshes.remove` 写入，共 3 次；定时器调 `refreshAll()`，每个工具各一遍。
首次读取还要多一次 `visibleRefreshes.insert`，所以那一轮是 4 次/工具。

## 改了什么

`Sources/AIToolbox/UsageViewModel.swift`：

1. 进度标记从独立的 `@Published Set<UsageProviderID>` 合并进 `ProviderState.showsProgress`。
   面板观察的是同一个 `ObservableObject`，每次写入都是一次全树 body 重算，两个集合表达
   同一件事就要付两次重绘。
2. 定时器只读屏幕上那个工具（`refreshSelected()`）。定时读取其余工具是在为重绘 nobody
   在看的数字买单。
3. 切标签时补上那一次读取：`select(_:)` 选中并读取，没有数据时显示进度，已有数据时静默更新。
   打开面板仍然 `refreshAll()`，所以四个卡片的首帧数据齐全。
4. `stop()` 从"每个工具一次写入"改成"最多一次字典写入，且只在真有在跑的读取时"。

## 试过并否掉的（含测量）

- **PixelArt / 形状路径缓存**：假设来自 goal 里"热点在 PixelArt/PixelControls"。实测单个
  glyph 的 `path(in:)` 构建 1–65µs，`Canvas` 满幅 dither 填充 340×3 约 213µs/条——都不在
  20ms 的帧预算里。Time Profiler 的主线程样本约 57% 落在自动布局 + `Text` 叶子（用量页
  约 70 个 `Text`），不是绘图。
- **把 `LiveConfigViewModel.reload()` 改成异步**：fixture 上 p50 0.30ms、p95 0.42ms；
  用户真实 `~/.codex`/`~/.claude` 上 p50 0.68ms、p95 1.54ms。相对一次 21ms 的重绘，
  异步化换来的是每次打开面板多一次状态跳变，不值得。
- **`@Observable` 迁移**（可以按属性追踪、把重算范围缩到真正读它的视图）：工程下限是
  `.macOS(.v13)`，`@Observable` 要 macOS 14。除非放弃 13，否则不可用。
- **`PanelTopAnchor` 的 0.1s watchdog**：看着像高频热点，实际是刻意的、有注释的设计，
  且只在面板可见时跑，成本远低于一次重绘。不动。

## 控件标识符

`Sources/AIToolbox/PanelID.swift` 是标识符契约（`panel.refresh`、`panel.tool.<app>`、
`panel.modeUsage`、`panel.card.today|trend|lifetime|models`、`panel.dialogConfirm|Cancel`、
`panel.configSave|configSaveAndSwitch|configCancelDraft|configAddProvider|configAdvanced`）。
标签会随本地化变，标识符不该变。

> 进程内**没有**校验标识符可发现性：SwiftUI 的无障碍树在无人当客户端查询时是懒建的，
> 同一份代码连续两次遍历得到 0 个和 8 个标识符。这类断言会随机失败，因此只留像素门禁；
> 标识符留给真正走无障碍 API 的 XCUITest（需要开发者证书签名，见 vitals 的同类说明）。
