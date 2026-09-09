# ZCode UI Enhancer

非官方 ZCode 桌面端渲染层增强工具：**壁纸主题 + 霓虹炫酷包 + 彗星尾动效 + tokens/s 输出速率计**。
通过把注入块合并进 `app.asar` 内的渲染入口实现，纯本地、不改动任何业务逻辑。

> ⚠️ 非官方修改。注入会对 `resources/app.asar` 做物理改写，ZCode 每次升级会覆盖它，需重装。
> 请自行评估风险；保留 `app.asar.old_v2` 可一键回滚。本工具不分发 ZCode 的任何官方资源。

## 功能

| 模块 | 说明 |
|---|---|
| 壁纸主题 | 自定义背景铺满窗口 + 半透明面板（激进档 2：23%~29%） |
| 霓虹炫酷包 | 蓝紫渐变主按钮/滚动条/卡片描边/流光子标题/呼吸光 |
| 彗星尾 | 鼠标轨迹光痕粒子特效（`__zcodeTrail`） |
| TPS 速率计 | 流式回复时实时显示 tok/s + 30s 速率曲线 + Σ/峰值/均值徽章（`__zcodeTps`） |

## 安装（Windows）

```bash
git clone https://github.com/<你>/zcode-ui-enhancer
cd zcode-ui-enhancer
python install.py --wallpaper "你的壁纸.png"
# 按提示：完全退出 ZCode → 等 15 秒 → 重开
```

- 自动探测安装目录，或用 `--app-dir` 指定（`...\ZCode\resources`）。
- 不传 `--wallpaper` 则保留原壁纸（首次安装无壁纸时只有特效）。
- 回滚：`python install.py --uninstall`

## 升级 ZCode 后重装

安装器会重新解包合并；建议升级后对比官方样式变化（见 `update/`）：

```bash
python update/analyze_ui_compat.py <上版官方基线> <新解包目录/out/renderer>
# 关键：CSS 文件名(styles-*.css)是内容哈希，同名=样式层未变，可放心沿用注入
python install.py --app-dir "...\ZCode\resources"
```

## 目录

```
assets/             # 壁纸（zcode-bg.png，gitignored，用户自备）
inject/blocks/      # 三个注入块（ground truth）
  background.css    #   壁纸 + token 覆盖 + 炫酷包（<style>）
  comet.js          #   彗星尾（__zcodeTrail）
  tps.js            #   tokens/s 速率计（__zcodeTps）
install.py          # 一键安装/回滚（解包→合并→打包→unpacked 补齐→挂自动换包）
update/             # 升级兼容分析/合并/剥离基线脚本
tests/test-logic.js # TPS 计数逻辑 9 项单测（node tests/test-logic.js 要求注入前跑）
```

## TPS 速率计的计数原理（README 摘要）

- MutationObserver 监听整个 body；CJK≈1 tok/字、英文≈4 字符/tok（估算，标 EST）。
- 四层防误计：① 净增量（删旧插新抵消，点击/重渲染不误计）② 批次闸门（>100 token 的负载视为历史加载，忽略）③ 徽章自刷新跳过 ④ React 注释节点不计。
- 速率 4s 滑动窗口，分母封顶 4s（防回合越长越被稀释）；回合结束显示均值后淡出。

## License

MIT（壁纸图片资产不在本仓库内，用户自备并自负版权）。