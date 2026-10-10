# AI 工具台 / AIToolbox

<p align="center">
  <img src="docs/images/hero.png" width="720" alt="AI 工具台：用量与配置，尽在菜单栏">
</p>

macOS 菜单栏应用：把 Codex 与 Claude Code 的本地用量、趋势和供应商配置收进
一个像素风面板。数据全部来自本机日志，不查询任何远端账单或订阅额度。

Swift 6 编写，无外部 SPM 依赖，要求 macOS 13+。

## 界面

| 用量详情 | 供应商配置 |
| --- | --- |
| ![用量详情（浅色）](docs/images/detail-light.png) | ![供应商配置（浅色）](docs/images/config-light.png) |

跟随系统的浅色与深色外观（`docs/images/detail-dark.png`、`docs/images/config-dark.png`）。

- **用量**：今日输出、输入构成（缓存读、缓存写、未缓存）、近 7 天逐日输出、
  累计用量和模型排行。累计和模型两张卡片可以折叠，折叠状态会记住。
- **配置**：官方登录与已保存的供应商列成一组，「使用中」的那一项按下、
  其余可切换；可测试端点、编辑、删除、导入当前生效的配置。删除供应商和
  切回 Claude Code 官方登录前会先确认。

## 设计

- 网格：1 个像素 = 1 pt，边框 2 pt，阶梯切角，硬投影，在 1x 与 Retina 屏上都不发虚。
- 字体：标题、标签和数字用方舟像素字体（Ark Pixel 12px，简体中文）；带句号的
  说明文字用系统字体，保证长文本可读。
- 色板取自应用图标（午夜蓝、青、蓝、紫），浅色和深色各一套，正文对比度达到
  WCAG AA；系统开启「增强对比度」时文字和边框会自动加深。
- 动效只有步进式的加载提示；系统开启「减少动态效果」时改为静止的沙漏和方块。
- 数字按中文习惯显示：1 万以下为完整数字，以上用「万」「亿」并保留三位有效
  数字；悬停可看到精确值。

## 构建与测试

```bash
swift build
swift test
```

包产物为可执行 target（`AIToolbox`），界面资源（像素字体及其授权文件）随包打包。

可选的渲染任务（只用示例数据）：

```bash
USAGE_RENDER_DOCS=1 swift test --filter DocumentationRenderTests/testRenderDocumentation   # 更新 docs/images
USAGE_RENDER_GALLERY=/tmp/gallery swift test --filter DocumentationRenderTests/testRenderGallery  # 全部页面与状态
USAGE_RENDER_ICON=1 swift test --filter DocumentationRenderTests/testRenderAppIcon         # 重新生成应用图标
```

## 打包与安装

```bash
bash scripts/package-app.sh
```

脚本未设可执行位，用 `bash` 显式运行。产物为 `dist/AIToolbox.app`（ad-hoc
签名）。图标直接取 `Assets/AppIcon.iconset` 中逐尺寸绘制的像素图，不做缩放。
安装到 /Applications：

```bash
pgrep -x AIToolbox || true          # 确认未运行
rm -rf /Applications/AIToolbox.app
cp -R dist/AIToolbox.app /Applications/
open /Applications/AIToolbox.app
```

## 首次运行

启动后图标出现在菜单栏右侧（状态项区），点击打开用量与配置面板。应用为
`LSUIElement`，不出现在 Dock；如需开机自启，在「系统设置 → 通用 → 登录项」
里手动添加本应用。

界面只有简体中文；`Info.plist` 把 zh-Hans 声明为唯一本地化，面板里的系统
部件（文本框右键菜单、系统错误信息）也随之显示中文。

## 数据来源与隐私

- Codex 用量：本机 `~/.codex/sessions/` 会话日志
- Claude Code 用量：本机 `~/.claude/projects/` 会话日志
- 供应商配置库：`~/Library/Application Support/AIToolbox/providers.json`

应用只读这些本机文件，不发起任何远端用量查询。配置面板修改
`~/.codex/config.toml` 与 `~/.claude/settings.json` 时为原子写入，原文件
自动备份为同目录 `.ai-toolbox.bak`；只改自己负责的键，不动其余配置。

## 卸载

1. 退出应用（菜单栏图标 → 退出）
2. 删除 `/Applications/AIToolbox.app`
3. 如需清掉配置库：删除
   `~/Library/Application Support/AIToolbox/`
4. `.ai-toolbox.bak` 备份文件不会被自动清理，确认无需回滚后可手动删除

## 分发说明

产物为 ad-hoc 签名，仅供本机构建自用；拷贝到其他 Mac 会被 Gatekeeper
拦截。对外分发需要 Developer ID 签名加公证后再发布。

## 第三方资源

像素字体为 [方舟像素字体（Ark Pixel Font）](https://github.com/TakWolf/ark-pixel-font)
12px 比例宽度简体中文版，© TakWolf，依 SIL Open Font License 1.1 授权，
未经修改随应用分发；授权全文见
`Sources/AIToolbox/Resources/ArkPixel-OFL.txt`。
