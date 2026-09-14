# ZCode Usage Menu（macOS）

**独立的 macOS 菜单栏用量面板**：只读 ZCode 本地用量数据库，展示今日/累计 token、缓存命中、工具调用和模型排行。**不修改 ZCode.app、不注入 `app.asar`、不会影响 ZCode 启动。**

> ⚠️ **旧的 `app.asar` 渲染层注入方案已退役。** 它在本机 ZCode 3.11.2 上曾造成 renderer 白屏和无法进入应用。请勿运行根目录的 `install.py`、`install.py --install-hook` 或向 ZCode 安装包注入 `inject/*.js`。它们仅作为历史实现保留，不是支持的安装路径。

## 多工具面板

顶部可切换 **总览 / ZCode / Codex / Claude Code**，选择会保存。各来源独立后台刷新；某个来源读取失败时不影响其他来源。总览按工具列出已记录输出，菜单栏只汇总输出；来源不齐全时标注“部分”。这不是厂商账单或额度统计。

- **ZCode**：只读 `~/.zcode/cli/db/db.sqlite`，保留现有 SQL 聚合。
- **Codex**：扫描 `~/.codex/sessions` 和 `archived_sessions` 的 JSONL。只累加逐响应 `payload.usage`，以响应 ID 去重，不累加回合/线程累计字段。模型通过回合上下文关联。
- **Claude Code**：扫描 `~/.claude/projects` 的主会话及 subagents JSONL，只解码 assistant 消息的 usage。相同消息/请求的多份记录只保留最新记录。
- 日志读取按行限制内存，不保留会话正文或工具参数，不扫描认证配置。解析不了的记录标注为部分数据；缺失字段显示“—”，显式零值才显示 0。
- Codex/Claude 的输入和缓存按原始记录分别显示，不套用 ZCode 的非缓存输入减法。两者的回合和工具计数暂不支持。
- 本机首次 Codex 扫描约 17 秒，期间面板仍可切换；未变化的文件复用内存快照，文件变化或跨日后重新扫描。价格估算暂限 ZCode。
- 自动测试使用合成数据。显式真实数据校验：`USAGE_LOCAL_SMOKE=1 swift test --filter MultiProviderTests/testLocalSourcesWhenExplicitlyEnabled`（在 Swift 工程目录运行，仅输出聚合数和耗时）。

## 功能

- 菜单栏常驻显示当天输出，例如 `185k 输出`；应用启动即后台预热，点击菜单栏只读内存快照；每 30 秒后台刷新，点击展开后可手动刷新。
- 原生 SwiftUI Popover，使用自适应 Material 卡片和 macOS 语义色，深浅色自动适配：
  - **今日主卡**：大号今日输出、输入/回合/请求/工具调用，以及缓存读/缓存创建/非缓存输入的构成条。
  - **累计卡**：Token（输入、输出、推理、缓存读）与活动（回合、请求、工具调用）分组展示。
  - **模型卡**：前四个模型按已记录输出排序，使用相对水平条比较输出量。
  - **可选成本**：在 `~/.zcode/cli/usage-prices.json` 填入输出单价后显示。
  - **状态与操作**：刷新失败时保留旧数据并提示；顶部提供刷新和菜单（打开数据目录、退出）。
- 自动跟随 macOS 浅色/深色模式。
- 读取失败时保留上一次成功数据，并提供明确的无数据状态。
- ZCode 没有启动也能读取历史数据；菜单栏 App 自己退出或崩溃不会影响 ZCode。

## 安装与启动

本机已构建好的应用位于：

```text
native/ZCodeUsageMenu/dist/ZCodeUsageMenu.app
```

在 Finder 中双击 `ZCodeUsageMenu.app`，或终端执行：

```bash
open native/ZCodeUsageMenu/dist/ZCodeUsageMenu.app
```

应用是菜单栏模式，不会出现在 Dock 中。点击菜单栏的工具名称与输出数字打开详情；顶部切换工具，右上角 `…` 菜单提供刷新、打开当前来源目录和退出。

> 首次打开 macOS 可能提示“无法验证开发者”。这是本地构建且使用 ad-hoc 签名的正常现象：在 Finder 中右键 App → **打开** → 再确认打开即可。

## 数据来源与统计口径

应用以只读方式打开：

```text
~/.zcode/cli/db/db.sqlite
```

统计语义与项目旧版 `usage-export.py` 一致：

- `turn_usage`：累计/今日的回合、请求、输入、输出、推理、缓存读和工具调用。
- “今日”按 macOS 本地时间的 00:00 过滤 `started_at`。
- `input_tokens` 包含缓存读，界面把 `cache_read_input_tokens` 单独显示，不把它误表述为新增上下文。
- 模型排行使用 `model_usage JOIN part(step-finish)` 的逐请求 token；不关联 `turn_usage`，避免一个回合多个请求造成重复统计。
- 有些请求没有 `step-finish` 记录，因此模型排行可能少于累计输出——界面对此有说明。

可选成本文件格式（金额为每 1M output token 的美元单价）：

```json
{
  "GLM-5.3": { "output": 2.0 },
  "k3": { "output": 1.5 }
}
```

## 从源码构建

依赖：macOS 13+、Xcode / Swift 6、系统 `sqlite3`。

```bash
cd native/ZCodeUsageMenu
swift test              # 数据层集成测试
swift build -c release  # 编译 release 二进制
```

打包 `.app`：

```bash
cd native/ZCodeUsageMenu
rm -rf dist
mkdir -p dist/ZCodeUsageMenu.app/Contents/MacOS
cp .build/release/ZCodeUsageMenu dist/ZCodeUsageMenu.app/Contents/MacOS/
cp Info.plist dist/ZCodeUsageMenu.app/Contents/Info.plist
codesign --force --deep --sign - dist/ZCodeUsageMenu.app
```

## 测试

```bash
cd native/ZCodeUsageMenu
swift test
```

集成测试构建迷你 SQLite 数据库，覆盖：累计/当天聚合、缓存读统计、模型输出不重复计数及数据库缺失错误。

## 旧注入代码（历史归档）

`inject/`、`install.py`、`demo/` 与 `tests/test-*.js` 是旧实验性渲染层注入实现，保留供代码参考。它们**不应对 ZCode 3.11.2+ 运行**。

如果历史 hook 曾自动改写过 `app.asar`，请确保 `~/.zcode/cli/config.json` 中没有执行 `install.py --auto` 的 `SessionStart` hook。当前环境已经移除了该 hook。

## License

MIT。旧注入架构继承自 [Rick_ZhangR1/zcode-ui-enhancer](https://gitee.com/Rick_ZhangR1/zcode-ui-enhancer) 的 MIT 授权。
