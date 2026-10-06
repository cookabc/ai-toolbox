# AI 工具台 / AIToolbox

<p align="center">
  <img src="docs/images/hero.png" width="720" alt="AI 工具台：用量与配置，尽在菜单栏">
</p>

macOS 菜单栏应用：把 Codex 与 Claude Code 的本地用量、趋势和供应商配置收进
一个原生面板。数据全部来自本机日志，不查询任何远端账单或订阅额度。

Swift 6 编写，无外部 SPM 依赖，要求 macOS 13+。

## 界面

| 用量详情 | 供应商配置 |
| --- | --- |
| ![用量详情（浅色）](docs/images/detail-light.png) | ![供应商配置（浅色）](docs/images/config-light.png) |

暗色模式同样适配（`docs/images/detail-dark.png`、`docs/images/config-dark.png`）。

## 构建与测试

```bash
swift build
swift test
```

包产物为可执行 target（`AIToolbox`），界面资源随包打包。

## 打包与安装

```bash
bash scripts/package-app.sh
```

脚本未设可执行位，用 `bash` 显式运行。产物为 `dist/AIToolbox.app`（ad-hoc
签名）。安装到 /Applications：

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
