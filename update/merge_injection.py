#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 critical-<版本>/index.html 里的注入块合并进新版本解包的 index.html。
用法: python merge_injection.py <critical目录>/index.html <新版index.html>
块按标记注释定位（壁纸style / 彗星尾 / TPS），插入位置：style→stylesheet link 后，script→</body> 前。
壁纸需另行复制: cp critical-<版本>/assets/zcode-bg.png <新解包>/out/renderer/assets/"""
import sys

crit_path, new_path = sys.argv[1], sys.argv[2]
crit = open(crit_path, encoding='utf-8').read()

blocks = []
for opener, marker, closer in [
        ('<style>', '/* ===== ZCode 自定义壁纸背景', '</style>'),
        ('<script>', '/* ===== ZCode 彗星尾', '</script>'),
        ('<script>', '/* ===== ZCode 输出速率计', '</script>')]:
    mi = crit.find(marker)
    assert mi != -1, f'critical 里找不到标记: {marker}'
    start = crit.rfind(opener, 0, mi)
    end = crit.find(closer, mi) + len(closer)
    blocks.append(crit[start:end])
    print(f'  提取块: {marker[10:30]}... ({end-start} 字符)')

style_blocks = [b for b in blocks if b.startswith('<style>')]
script_blocks = [b for b in blocks if b.startswith('<script>')]
assert len(style_blocks) == 1 and len(script_blocks) == 2

new = open(new_path, encoding='utf-8').read()
for m in ['zcode-bg', '__zcodeTrail', '__zcodeTps']:
    assert m not in new, f'新版 index.html 已含 {m}，疑似重复注入'

# style 插到 stylesheet link 之后
lines = new.split('\n')
link_idx = next(i for i, l in enumerate(lines) if 'rel="stylesheet"' in l)
lines = lines[:link_idx + 1] + style_blocks[0].split('\n') + lines[link_idx + 1:]

# scripts 插到 </body> 前
body_idx = next(i for i, l in enumerate(lines) if l.strip() == '</body>')
lines = lines[:body_idx] + script_blocks[0].split('\n') + script_blocks[1].split('\n') + lines[body_idx:]

open(new_path, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
print(f'  合并完成，总行数: {len(lines)}')
