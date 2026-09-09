#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 critical-<版本>/index.html 剥离全部注入块，还原官方基线 index.html。
用法: python strip_baseline.py <critical目录>/index.html <输出目录>
注入块按标记注释定位（不依赖行号），支持: 壁纸style / 彗星尾 / TPS 速率计。
CSS 不会自动处理——官方 CSS 请从解包目录的 assets/styles-*.css 复制。"""
import sys, os, re

src, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
idx = open(src, encoding='utf-8').read()
orig_len = idx.count('\n')

# 注入块的起始标记（在 <style>/<script> 开标签之后）
for opener, marker in [('<style>', '/* ===== ZCode 自定义壁纸背景'),
                       ('<script>', '/* ===== ZCode 彗星尾'),
                       ('<script>', '/* ===== ZCode 输出速率计')]:
    mi = idx.find(marker)
    if mi == -1:
        print(f'  未找到: {marker[:20]}...（可能本就无此块）')
        continue
    start = idx.rfind(opener, 0, mi)
    closer = opener.replace('<', '</')
    end = idx.find(closer, mi) + len(closer)
    # 吃掉块后紧跟的换行
    while end < len(idx) and idx[end] == '\n':
        end += 1
    idx = idx[:start] + idx[end:]
    print(f'  已剥离: {marker[10:30]}...')

open(outdir + '/index.html', 'w', encoding='utf-8', newline='\n').write(idx)
for m in ['zcode-bg', '__zcodeTrail', '__zcodeTps', 'color-mix']:
    print(f'  残留 {m}: {idx.count(m)}')
print(f'  行数: {orig_len} -> {idx.count(chr(10))}')
