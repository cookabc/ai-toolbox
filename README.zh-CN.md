[English](README.md) · **简体中文**

# AI Toolbox / AIToolbox

<p align="center">
  <img src="docs/images/hero.png" width="720" alt="AI Toolbox：用量与配置，就在菜单栏中">
</p>

一个 macOS 菜单栏应用，把 Codex 和 Claude Code 在本机的用量、趋势与供应商配置汇总到一个像素风格的面板里。所有数据都来自这台 Mac 自己的日志，从不会向远端查询账单或订阅配额。

用 Swift 6 编写，不依赖任何外部 SPM 包，要求 macOS 13 及以上。

## 界面

| 用量详情 | 供应商配置 |
| --- | --- |
| ![用量详情（浅色）](docs/images/detail-light.png) | ![供应商配置（浅色）](docs/images/config-light.png) |

它会跟随系统的浅色与深色外观（`docs/images/detail-dark.png`、`docs/images/config-dark.png`）。

- **用量**：今日输出量、输入构成（缓存读取、缓存写入、未缓存）、最近 7 天的每日输出量、累计用量和模型排行。累计用量与模型两张卡片可以折叠，折叠状态会被记住。
- **配置**：官方登录与已保存的供应商构成同一组。正在使用的那一项处于按下状态，其余可以切换过去；每一项都可以测试、编辑或删除，当前生效的配置也可以导入。删除供应商和切回 Claude Code 官方登录这两项操作都会先确认。

## 设计

- 栅格：1 像素 = 1 pt，2 pt 描边，阶梯圆角和硬阴影，因此在 1x 和 Retina 屏幕上都不会发虚。
- 字体：标题、标签和数字使用 Ark Pixel 字体（Ark Pixel 12px，拉丁字形）；正文保持系统字体，让长段落仍然易读。
- 配色取自应用图标（午夜藏青、青色、蓝色、紫色），浅色和深色各一套，正文满足 WCAG AA；开启"增强对比度"后文字与描边会加深。
- 动效只限于一个逐格推进的加载指示器；开启"减弱动态效果"后，它会变成静止的沙漏与方块。
- 数字遵循英文分组方式：10,000 以下显示完整数字，以上使用 K / M / B / T 并保留三位有效数字；悬停可以查看精确值。

## 构建与测试

构建需要 Xcode 26 或更高版本（Swift 6.2+），以支持 `isolated deinit`。GitHub Actions 使用 Xcode 26.3。应用的最低运行版本仍为 macOS 13。

```bash
swift build
swift test
```

包产物是一个可执行 target（`AIToolbox`）；界面资源（像素字体及其许可证文件）随 bundle 一起分发。

可选的渲染任务（仅使用示例数据）：

```bash
USAGE_RENDER_DOCS=1 swift test --filter DocumentationRenderTests/testRenderDocumentation   # 更新 docs/images
USAGE_RENDER_GALLERY=/tmp/gallery swift test --filter DocumentationRenderTests/testRenderGallery  # 每个页面和状态
USAGE_RENDER_ICON=1 swift test --filter DocumentationRenderTests/testRenderAppIcon         # 重新生成应用图标
```

## 打包与安装

```bash
bash scripts/package-app.sh
```

该脚本没有设置可执行位，因此需要显式通过 `bash` 运行。产物为 `dist/AIToolbox.app`（ad-hoc 签名）。图标直接来自 `Assets/AppIcon.iconset` 中逐尺寸的像素图，未做重采样。要安装到 /Applications：

```bash
pgrep -x AIToolbox || true          # 确认它没有在运行
rm -rf /Applications/AIToolbox.app
cp -R dist/AIToolbox.app /Applications/
open /Applications/AIToolbox.app
```

## 首次运行

启动后，图标会出现在菜单栏右侧（状态栏区域）；点击它会打开用量与配置面板。应用是 `LSUIElement`，所以不会出现在 Dock 中；要在登录时启动，请在"系统设置 → 通用 → 登录项"中自行添加。

界面只有英文；`Info.plist` 只声明了 `en` 这一种本地化语言，因此面板里的系统部件（文本输入框的上下文菜单、系统错误提示）也都会显示英文。

## 数据来源与隐私

- Codex 用量：这台 Mac 的 `~/.codex/sessions/` 会话日志
- Claude Code 用量：这台 Mac 的 `~/.claude/projects/` 会话日志
- 供应商库：`~/Library/Application Support/AIToolbox/providers.json`

应用只读取这些本地文件，不会发起任何远端用量查询。当配置面板修改 `~/.codex/config.toml` 或 `~/.claude/settings.json` 时，它会以原子方式写入，并在原文件旁备份为 `.ai-toolbox.bak`，只改动自己负责的键，其余配置保持不变。

## 卸载

1. 退出应用（菜单栏图标 → 退出）
2. 删除 `/Applications/AIToolbox.app`
3. 如果要一并删除供应商库，删除 `~/Library/Application Support/AIToolbox/`
4. `.ai-toolbox.bak` 备份从不会自动清理；确认不再需要回滚后请手动删除

## 分发

产物使用 ad-hoc 签名，仅用于本地构建；拷贝到另一台 Mac 上会被 Gatekeeper 拦截。要公开发布，需要先做 Developer ID 签名与公证。

GitHub Actions 在推送和拉取请求时运行默认测试并构建本地 app bundle。可选的实时数据测试与渲染测试仍需手动开启。CI 没有分发凭据，也不会发布 release。

## 许可证

应用代码以 [MIT License](LICENSE) 发布。随附的 Ark Pixel 字体仍遵循其自身的 [SIL Open Font License 1.1](Sources/AIToolbox/Resources/ArkPixel-OFL.txt)；见下方"第三方资源"。

## 第三方资源

像素字体是 [Ark Pixel Font](https://github.com/TakWolf/ark-pixel-font) 12px 比例字形的拉丁字形版本，© TakWolf，以 SIL Open Font License 1.1 授权，随应用原样分发；完整许可证文本位于 `Sources/AIToolbox/Resources/ArkPixel-OFL.txt`。
