#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ZCode UI Enhancer 安装器（Windows）

把 inject/blocks 下的三个注入块打进本地 ZCode 渲染入口，
并自动处理打包、unpacked 补齐（防终端打不开）与自动换包。

用法:
  python install.py                       # 探测 ZCode 安装并安装
  python install.py --app-dir "E:\\xxx\\resources"
  python install.py --wallpaper 我的壁纸.png
  python install.py --uninstall           # 回滚到安装前的 app.asar
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BLOCKS = [
    # (文件名, 开标签, 标记注释, 插入位置)
    ('background.css', '<style>', '/* ===== ZCode 自定义壁纸背景', 'after-stylesheet'),
    ('comet.js', '<script>', '/* ===== ZCode 彗星尾', 'before-body'),
    ('tps.js', '<script>', '/* ===== ZCode 输出速率计', 'before-body'),
]
ASAR_PY = os.path.join(HERE, 'update', '_asar.py')  # 预留：纯 python 实现可去 npx 依赖

def find_resources_dir():
    cands = [
        os.environ.get('ZCODE_RESOURCES', ''),
        r'E:\Programs\ZCode\resources',
        os.path.join(os.environ.get('PROGRAMFILES', ''), 'ZCode', 'resources') if os.environ.get('PROGRAMFILES') else '',
        os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', 'ZCode', 'resources'),
    ]
    for c in cands:
        if c and os.path.isfile(os.path.join(c, 'app.asar')):
            return c
    return None

def run(cmd, cwd=None):
    print('>>', cmd)
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'命令失败: {cmd}\n{r.stdout}\n{r.stderr}')
    return r.stdout

def asar_extract(res, et):
    run(f'npx --yes @electron/asar extract app.asar {et}', cwd=res)

def asar_pack(res, et):
    run(f'npx --yes @electron/asar pack {et} app.asar.new --unpack-dir "**/{{node-pty,ssh2}}/**"', cwd=res)

def fix_unpacked(res, et):
    for m in ('node-pty', 'ssh2'):
        src = os.path.join(et, 'node_modules', m)
        dst = os.path.join(res, 'app.asar.unpacked', 'node_modules')
        if os.path.isdir(src):
            run(f'cp -rn "{src}/." "{dst}/"') if os.name != 'nt' else None
            # Windows 下用 robocopy/xcopy
            if os.name == 'nt':
                run(f'robocopy "{src}" "{dst}\\" /E /XO /NFL /NDL /NJH /NJS >nul 2>&1')

def merge_blocks(idx_path):
    with open(idx_path, encoding='utf-8') as f:
        html = f.read()
    assert all(m not in html for _, _, m, _ in BLOCKS), '检测到已有注入，先 --uninstall 或手动还原'
    lines = html.split('\n')
    for fname, opener, marker, where in BLOCKS:
        with open(os.path.join(HERE, 'inject', 'blocks', fname), encoding='utf-8') as f:
            block = f.read().rstrip('\n')
        closer = opener.replace('<', '</')
        wrapped = opener + '\n' + block + '\n' + closer
        if where == 'after-stylesheet':
            li = next(i for i, l in enumerate(lines) if 'rel="stylesheet"' in l)
            lines = lines[:li + 1] + wrapped.split('\n') + lines[li + 1:]
        else:
            bi = next(i for i, l in enumerate(lines) if l.strip() == '</body>')
            lines = lines[:bi] + wrapped.split('\n') + lines[bi:]
    open(idx_path, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))

def write_watcher(res):
    bat = r'''@echo off
setlocal
cd /d %~dp0
if "%~1"=="now" goto swap
:waitloop
ping -n 3 127.0.0.1 >nul
tasklist /FI "IMAGENAME eq ZCode.exe" 2>nul | find /I "ZCode.exe" >nul
if not errorlevel 1 goto waitloop
ping -n 9 127.0.0.1 >nul
tasklist /FI "IMAGENAME eq ZCode.exe" 2>nul | find /I "ZCode.exe" >nul
if not errorlevel 1 goto waitloop
:swap
cd /d %~dp0
if not exist app.asar.new (
  echo %date% %time% app.asar.new missing, back to waiting >> apply-new-ui.log
  goto waitloop
)
set /a tries=0
:retry
move /y app.asar app.asar.old_v2 >nul 2>&1
if errorlevel 1 (
  set /a tries+=1
  if %tries% GEQ 30 (
    echo %date% %time% app.asar locked, back to waiting >> apply-new-ui.log
    goto waitloop
  )
  ping -n 3 127.0.0.1 >nul
  goto retry
)
move /y app.asar.new app.asar >nul 2>&1
if errorlevel 1 (
  move /y app.asar.old_v2 app.asar >nul 2>&1
  goto waitloop
)
findstr /C:"__zcodeTps" app.asar >nul 2>&1
if errorlevel 1 (
  del /f /q app.asar
  move /y app.asar.old_v2 app.asar >nul 2>&1
  goto waitloop
)
if exist app.asar.new.unpacked rd /s /q app.asar.new.unpacked
del "%~f0"
'''
    bat = bat.replace('\r\n', '\n').replace('\n', '\r\n')
    open(os.path.join(res, 'apply-new-ui.bat'), 'w', newline='').write(bat)
    return 'apply-new-ui.bat'

def main():
    ap = argparse.ArgumentParser(description='ZCode UI Enhancer 安装器')
    ap.add_argument('--app-dir', help='ZCode resources 目录（不传则自动探测）')
    ap.add_argument('--wallpaper', help='壁纸图片路径（复制为 out/renderer/assets/zcode-bg.png）')
    ap.add_argument('--uninstall', action='store_true', help='回滚到旧包')
    args = ap.parse_args()

    res = args.app_dir or find_resources_dir()
    if not res:
        sys.exit('找不到 ZCode 安装，请用 --app-dir 指定 resources 目录')
    asar = os.path.join(res, 'app.asar')
    if not os.path.isfile(asar):
        sys.exit(f'app.asar 不存在: {asar}')

    if args.uninstall:
        old = os.path.join(res, 'app.asar.old_v2')
        if not os.path.isfile(old):
            sys.exit('没有 app.asar.old_v2 可回滚')
        run(f'move /y "{asar}" "app.asar.injected" 2>nul', cwd=res)
        run(f'move /y "app.asar.old_v2" "app.asar"', cwd=res)
        print('已回滚。提示：旧注入保留在 app.asar.injected，可手动删除。')
        return

    print(f'[1/6] 备份官方包 -> app.asar.old_v2')
    if not os.path.isfile(os.path.join(res, 'app.asar.old_v2')):
        shutil.copy2(asar, os.path.join(res, 'app.asar.old_v2'))

    print('[2/6] 解包 app.asar')
    et = os.path.join(res, 'app_extract')
    if os.path.isdir(et):
        shutil.rmtree(et)
    asar_extract(res, et)

    if args.wallpaper and os.path.isfile(args.wallpaper):
        print('[3/6] 复制壁纸')
        shutil.copy2(args.wallpaper, os.path.join(et, 'out', 'renderer', 'assets', 'zcode-bg.png'))

    print('[4/6] 合并注入块 -> index.html')
    merge_blocks(os.path.join(et, 'out', 'renderer', 'index.html'))

    print('[5/6] 打包 app.asar.new（--unpack-dir node-pty/ssh2）')
    asar_pack(res, et)

    print('[6/6] 补齐 app.asar.unpacked（防止集成终端 node-pty 打不开）')
    fix_unpacked(res, et)

    bat = write_watcher(res)
    print('\n完成！ZCode 还在运行，为防止换包竞态：')
    print(f'  1. 完全退出 ZCode（托盘也退出）')
    print(f'  2. 等 15 秒（watcher 会自动把装扮包换上去并自删）')
    print(f'  3. 重新打开 ZCode 即可看到效果')
    print(f'\n回滚：python install.py --uninstall；或把 resources\\app.asar.old_v2 对调回 app.asar')

if __name__ == '__main__':
    main()