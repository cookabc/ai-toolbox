#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ZCode 新版本 UI 兼容性分析（升级恢复注入前先跑这个）
长期存放于 workspace（E:\\ZcodeSpace\\zcode-ui-backup），安装器不会清这里。

用法:
  python analyze_ui_compat.py <旧renderer目录> <新renderer目录>
例:
  python analyze_ui_compat.py baseline-3.10.2-official <新解包>\\out\\renderer

两个目录都应包含 index.html 和 assets/styles-*.css（新目录是解包后的 out/renderer）。
基线目录做法：从上一版 critical-<ver>\\index.html 剥离注入块还原官方版
（3.10.1 注入版: style=361~513行, script=540~610行）。
输出:
  1. index.html 结构差异概要（资产文件名变化、行级差异统计）
  2. CSS 自定义属性(--token) 定义与使用量的新旧对比（重点: 我们覆盖的 token 用量暴增=新功能依赖它）
  3. 注入规则涉及的类名(.bg-card/.bg-primary/...)在新旧 CSS 中的出现次数对比
  4. 关键前提检查: Tailwind reset 是否还在、zai-dark 机制是否还在
提示: CSS 文件名是内容哈希（styles-XXXX.css），新旧同名 ⇒ CSS 未变，可跳过 2/3 节。
"""
import re
import sys
import difflib
from pathlib import Path

# 注入规则直接覆盖的 token —— 这些的"使用次数变化"要重点看
OVERRIDDEN_TOKENS = [
    "background-win-alt", "color-background", "color-panel", "color-card",
    "color-header", "color-sidebar", "color-tab", "color-tab-active",
    "color-menu", "color-popover", "color-input", "color-hover", "color-selected",
]
# 注入规则直接改样式的类名 —— 出现次数变化说明新版本 UI 结构变了
WATCH_CLASSES = [
    "bg-card", "bg-primary", "bg-sidebar", "bg-header", "bg-panel",
    "bg-menu", "bg-popover", "bg-background", "bg-tab", "bg-input",
    "text-primary-foreground",
]

TOKEN_DEF = re.compile(r"(--[a-zA-Z][a-zA-Z0-9-]*)\s*:")
TOKEN_USE = re.compile(r"var\(\s*(--[a-zA-Z][a-zA-Z0-9-]*)")


def load_renderer(rdir: Path):
    idx = rdir / "index.html"
    csss = sorted((rdir / "assets").glob("styles-*.css")) if (rdir / "assets").is_dir() else []
    idx_text = idx.read_text(encoding="utf-8", errors="replace") if idx.exists() else ""
    css_text = "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in csss)
    return idx_text, css_text, [p.name for p in csss]


def counter(text, rx):
    c = {}
    for m in rx.findall(text):
        c[m] = c.get(m, 0) + 1
    return c


def delta_map(old, new, label):
    keys = sorted(set(old) | set(new))
    rows = [(k, old.get(k, 0), new.get(k, 0)) for k in keys]
    added = [r for r in rows if r[1] == 0]
    removed = [r for r in rows if r[2] == 0]
    changed = [r for r in rows if r[1] > 0 and r[2] > 0 and r[1] != r[2]]
    print(f"\n## {label}: 新增定义 {len(added)} 个, 移除 {len(removed)} 个, 用量变化 {len(changed)} 个")
    if added:
        print("  [新增 token] " + ", ".join(k for k, _, _ in added[:40]) + (" ..." if len(added) > 40 else ""))
    if removed:
        print("  [移除 token] " + ", ".join(k for k, _, _ in removed[:40]) + (" ..." if len(removed) > 40 else ""))
    big = sorted(changed, key=lambda r: -abs(r[2] - r[1]))[:15]
    for k, a, b in big:
        mark = "  <-- 注入覆盖了它, 注意!" if any(t in k for t in OVERRIDDEN_TOKENS) else ""
        print(f"  {k}: {a} -> {b}{mark}")


def main():
    old_dir, new_dir = Path(sys.argv[1]), Path(sys.argv[2])
    oi, oc, oss = load_renderer(old_dir)
    ni, nc, nss = load_renderer(new_dir)
    if not ni:
        sys.exit(f"新目录里没有 index.html: {new_dir}")

    print("=" * 72)
    print("1) index.html 结构差异")
    print(f"   行数: {len(oi.splitlines())} -> {len(ni.splitlines())}")
    print(f"   styles css: {oss} -> {nss}")
    if oss and nss and set(oss) == set(nss):
        print("   >>> CSS 文件名(内容哈希)相同 ⇒ CSS 未变, 第2/3节仅供参考")
    sm = difflib.SequenceMatcher(None, oi.splitlines(), ni.splitlines())
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        print(f"   [{tag}] 旧{i1+1}-{i2}行 -> 新{j1+1}-{j2}行")
        for line in oi.splitlines()[i1:i2][:6]:
            print(f"     - {line.strip()[:150]}")
        for line in ni.splitlines()[j1:j2][:6]:
            print(f"     + {line.strip()[:150]}")

    print("=" * 72)
    print("2) CSS token 对比")
    delta_map(counter(oc, TOKEN_DEF), counter(nc, TOKEN_DEF), "token 定义")
    ouse, nuse = counter(oc, TOKEN_USE), counter(nc, TOKEN_USE)
    hot = [(k, ouse.get(k, 0), nuse.get(k, 0)) for k in OVERRIDDEN_TOKENS]
    print("\n## 注入覆盖的 token, 使用次数变化 (旧->新):")
    for k, a, b in hot:
        flag = "  <-- 用量变化大, 新功能可能在用!" if abs(b - a) > 20 else ""
        print(f"   {k}: {a} -> {b}{flag}")

    print("=" * 72)
    print("3) 注入涉及的类名出现次数 (css 选择器层面)")
    for cls in WATCH_CLASSES:
        a, b = oc.count(cls), nc.count(cls)
        mark = "  <-- 数量变了, 全局覆盖规则要复核" if a != b else ""
        print(f"   .{cls}: {a} -> {b}{mark}")

    print("=" * 72)
    print("4) 关键前提")
    print(f"   Tailwind reset(html,body,#root background:0 0 !important): "
          f"旧={'background:0 0!important' in oc.replace(' ', '')}, "
          f"新={'background:0 0!important' in nc.replace(' ', '')}")
    print(f"   index.html 里 zai-dark 判定: 旧={'zai-dark' in oi}, 新={'zai-dark' in ni}")
    print(f"   index.html 里 classList.toggle('dark'): 旧={'.dark' in oi and 'toggle' in oi}, 新={'.dark' in ni and 'toggle' in ni}")
    print("=" * 72)
    print("提示: 新增 token / 用量暴增的覆盖 token / 次数变化的类名 = 新版本改动的信号,")
    print("      注入前逐项确认这些新功能块在半透明背景下仍然可见。")


if __name__ == "__main__":
    main()
