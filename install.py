#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ZCode UI Enhancer（macOS edition）安装器

把 inject/ 下的注入块（neon.css + tps.js）打进本地 ZCode 桌面端的 app.asar 渲染入口。
macOS 没有 Windows 的文件锁问题：运行中的 ZCode 持有旧 inode，原子替换后下次启动生效，
因此不需要原版的 .bat watcher 轮询。

为什么自动重装走 ZCode hook 而不是 launchd：
  macOS 的 App Management 保护（TCC）禁止非授权进程写入 /Applications 下的 app bundle。
  实测 launchd 拉起的进程对 bundle 内任何写操作都会 EPERM，而 ZCode 会话内派生的进程
  继承 ZCode 的授权、可以写 bundle。所以把「检测 + 后台重装」挂在 SessionStart hook 上：
  升级后第一次打开 ZCode，hook 自动重装，重启 ZCode 即生效。

用法:
  python3 install.py                    # 安装（自动探测 /Applications/ZCode.app）
  python3 install.py --uninstall        # 回滚到安装前的 app.asar
  python3 install.py --status           # 查看注入与 hook 状态
  python3 install.py --install-hook     # 安装 SessionStart hook（升级后自动重注入）
  python3 install.py --remove-hook      # 移除 SessionStart hook
  python3 install.py --auto             # 仅供 hook 调用：幂等静默模式

设计要点:
  - 原子换包: 打包到 app.asar.new 校验后 os.replace，失败不碰原包
  - 幂等: index.html 已含 __zcodeTps 标记时跳过；hook 重复触发由 flock 串行化
  - hook 环境无用户 PATH，npx/node 通过 find_npx() 全盘探测并注入 env
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APP_NAME = 'ZCode'
LABEL = 'dev.zcode.ui-enhancer'
HOOK_TAG = 'zcode-ui-enhancer'
CONFIG_PATH = os.path.expanduser('~/.zcode/cli/config.json')
SNAPSHOT_DIR = os.path.expanduser('~/Library/Application Support/%s' % HOOK_TAG)
LOG_PATH = os.path.expanduser('~/Library/Logs/%s.log' % HOOK_TAG)
# is_injected() 的探针：查「最新加入的模块」的标记——老安装缺新模块时返回未注入，
# 触发重跑 merge（逐模块幂等会只补缺的），避免「有 tps 就误判全装」的盲区。
MARKER = '__zcodeUsagePanel'

# (注入块文件, 开标签, 标记注释, 插入位置, 该模块的幂等标记)
# 注意顺序：badge-theme 最先（写 --zb-* 变量供徽章读）→ badge-dock（收养徽章）→ 各徽章。
BLOCKS = [
    ('neon.css', '<style>', '/* ===== ZCode 霓虹主题包', 'after-stylesheet', '__zcodeNeon'),
    ('badge-theme.js', '<script>', '/* ===== ZCode 徽章主题', 'before-body', '__zcodeBadgeTheme'),
    ('badge-dock.js', '<script>', '/* ===== ZCode 徽章 dock', 'before-body', '__zcodeBadgeDock'),
    ('tps.js', '<script>', '/* ===== ZCode 输出速率计', 'before-body', '__zcodeTps'),
    ('context-gauge.js', '<script>', '/* ===== ZCode 上下文水位计', 'before-body', '__zcodeCtxGauge'),
    ('code-actions.js', '<script>', '/* ===== ZCode 代码块工具', 'before-body', '__zcodeCodeActions'),
    ('nav-dots.js', '<script>', '/* ===== ZCode 消息锚点导航', 'before-body', '__zcodeNavDots'),
    ('usage-panel.js', '<script>', '/* ===== ZCode 全量用量面板', 'before-body', '__zcodeUsagePanel'),
]

# usage-export.py 不进 index.html：由 SessionStart hook 以 --serve 模式拉起，
# 在 127.0.0.1:7391 提供 /usage 端点（实时聚合 db.sqlite），渲染层 fetch 它。
# ZCode 渲染层 webSecurity:true 会挡 file:// fetch，但 CORS 放行的 localhost 可通。
USAGE_EXPORT = 'usage-export.py'
USAGE_HOOK_TAG = 'zcode-ui-enhancer-usage'
USAGE_LOG = os.path.expanduser('~/Library/Logs/%s.log' % USAGE_HOOK_TAG)
USAGE_HOOK_COMMAND = ('nohup python3 "%(py)s" --serve >>"%(log)s" 2>&1 &'
                      % {'py': os.path.join(SNAPSHOT_DIR, 'inject', USAGE_EXPORT), 'log': USAGE_LOG})

HOOK_COMMAND = ('nohup python3 "%(py)s" --auto >>"%(log)s" 2>&1 &'
                % {'py': os.path.join(SNAPSHOT_DIR, 'install.py'), 'log': LOG_PATH})


def log(msg):
    if '--auto' in sys.argv:
        print(time.strftime('[%Y-%m-%d %H:%M:%S] ') + msg, flush=True)
    else:
        print(msg, flush=True)


def find_resources_dir():
    cands = [
        os.environ.get('ZCODE_RESOURCES', ''),
        '/Applications/%s.app/Contents/Resources' % APP_NAME,
        os.path.expanduser('~/Applications/%s.app/Contents/Resources' % APP_NAME),
    ]
    for c in cands:
        if c and os.path.isfile(os.path.join(c, 'app.asar')):
            return c
    return None


def find_npx():
    """hook/launchd 的 PATH 可能只有 /usr/bin:/bin，nvm/homebrew 的 npx 要全盘找。"""
    cands = [shutil.which('npx')]
    cands += sorted(glob.glob(os.path.expanduser('~/.nvm/versions/node/*/bin/npx')), reverse=True)
    cands += ['/opt/homebrew/bin/npx', '/usr/local/bin/npx']
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            env = dict(os.environ)
            env['PATH'] = os.path.dirname(c) + os.pathsep + env.get('PATH', '/usr/bin:/bin')
            return c, env
    raise RuntimeError('找不到 npx，请先安装 Node.js（nvm/homebrew 均可）')


def asar(npx, env, *args):
    r = subprocess.run([npx, '--yes', '@electron/asar'] + list(args),
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError('asar %s 失败:\n%s\n%s' % (' '.join(args), r.stdout, r.stderr))
    return r.stdout


def is_injected(asar_path):
    """注入文本位于 asar 中段，mmap 全文件搜索（300MB 量级 ~0.2s）。
    注意用 find() 而非 in：Python 3.14 起 mmap 对 bytes 的 in 走迭代回退，恒为 False。"""
    import mmap
    with open(asar_path, 'rb') as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
            return mm.find(MARKER.encode()) != -1


def merge_blocks(idx_path):
    """逐模块幂等合并：标记不在 → 插入；标记在但内容与 inject/ 文件不一致 → 换新。
    后者曾造成事故：只查标记导致代码修复后重跑 install 仍打进旧代码（跳过合并），
    旧代码在启动路径上崩溃 → ZCode 白屏。内容比对是防复发的关键。"""
    with open(idx_path, encoding='utf-8') as f:
        html = f.read()
    for probe in ('rel="stylesheet"', '</body>'):
        if probe not in html:
            raise RuntimeError('index.html 缺少注入锚点 %r，ZCode 版本结构可能已变，先跑 update/analyze_ui_compat.py' % probe)
    lines = html.split('\n')
    changed = []
    for fname, opener, marker, where, mod_marker in BLOCKS:
        with open(os.path.join(HERE, 'inject', fname), encoding='utf-8') as f:
            block = f.read().rstrip('\n')
        closer = opener.replace('<', '</')
        wrapped = opener + '\n' + block + '\n' + closer
        if mod_marker in html:
            # 标记已在：比对块内容，一致才跳过
            if _block_in_lines(lines, marker, wrapped):
                continue
            lines = _replace_block(lines, marker, wrapped, opener)
            changed.append(fname + '(更新)')
        else:
            if where == 'after-stylesheet':
                li = next(i for i, l in enumerate(lines) if 'rel="stylesheet"' in l)
                lines = lines[:li + 1] + wrapped.split('\n') + lines[li + 1:]
            else:
                bi = next(i for i, l in enumerate(lines) if l.strip() == '</body>')
                lines = lines[:bi] + wrapped.split('\n') + lines[bi:]
            changed.append(fname)
    if not changed:
        log('全部注入块与最新代码一致，跳过合并（幂等）')
        return False
    with open(idx_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))
    log('  合并模块: %s' % ', '.join(changed))
    return True


def _block_in_lines(lines, marker, wrapped):
    """wrapped 块（按行）是否完整存在于 lines 中。"""
    wl = wrapped.split('\n')
    for i in range(len(lines) - len(wl) + 1):
        if lines[i:i + len(wl)] == wl:
            return True
    return False


def _replace_block(lines, marker, wrapped, opener):
    """按标记定位旧块（与 strip_blocks 同定位法），整块替换为 wrapped。"""
    closer = opener.replace('<', '</')
    mi = next(i for i, l in enumerate(lines) if marker in l)
    oi = max(i for i in range(mi) if lines[i].strip() == opener)
    ci = next(i for i in range(mi, len(lines)) if lines[i].strip() == closer)
    return lines[:oi] + wrapped.split('\n') + lines[ci + 1:]


def fix_unpacked(res, et):
    """打包时 --unpack-dir 的原生模块要并入 app.asar.unpacked（Electron 按 asar 路径 + .unpacked 寻址）。"""
    for m in ('node-pty', 'ssh2'):
        src = os.path.join(et, 'node_modules', m)
        dst = os.path.join(res, 'app.asar.unpacked', 'node_modules', m)
        if os.path.isdir(src):
            os.makedirs(dst, exist_ok=True)
            shutil.copytree(src, dst, dirs_exist_ok=True)


def notify(msg):
    """后台重装完成时尽力弹一条系统通知，失败不影响安装结果。"""
    try:
        subprocess.run(['osascript', '-e',
                        'display notification "%s" with title "zcode-ui-enhancer"' % msg],
                       capture_output=True, timeout=10)
    except Exception:
        pass


def do_install(res):
    asar_path = os.path.join(res, 'app.asar')
    et = os.path.join(res, 'app_extract')
    npx, env = find_npx()

    log('[1/6] 备份官方包 -> app.asar.old_v2')
    # 关键修复：只在「当前 asar 是干净的（未注入）」时才更新备份。
    # 旧逻辑只在 old_v2 不存在时备份一次——于是 old_v2 永远是「第一次注入前的旧版」，
    # 重装 ZCode 后 uninstall 会把版本错配的旧包换回去（曾导致无法启动）。
    # 现在：当前包干净才备份 → old_v2 始终是「最近的干净官方版」。
    old = os.path.join(res, 'app.asar.old_v2')
    if not is_injected(asar_path):
        shutil.copy2(asar_path, old)
    elif not os.path.isfile(old):
        # 当前已注入且没有干净备份：无法安全备份，留个标记让 uninstall 走 strip 兜底
        log('  当前已注入且无干净备份，跳过备份（uninstall 将用 strip 兜底）')

    log('[2/6] 解包 app.asar')
    if os.path.isdir(et):
        shutil.rmtree(et)
    asar(npx, env, 'extract', asar_path, et)

    idx = os.path.join(et, 'out', 'renderer', 'index.html')
    if not os.path.isfile(idx):
        raise RuntimeError('解包后没有 out/renderer/index.html，ZCode 结构已变')

    log('[3/6] 合并注入块 -> index.html')
    if not merge_blocks(idx):
        shutil.rmtree(et, ignore_errors=True)
        return False

    log('[4/6] 打包 app.asar.new（--unpack-dir node-pty/ssh2）')
    new_asar = os.path.join(res, 'app.asar.new')
    if os.path.exists(new_asar):
        os.remove(new_asar)
    asar(npx, env, 'pack', et, new_asar, '--unpack-dir', '**/{node-pty,ssh2}/**')
    # 校验新包可读再换
    out = asar(npx, env, 'list', new_asar)
    if 'out/renderer/index.html' not in out:
        raise RuntimeError('新包校验失败（缺 index.html），放弃替换')

    log('[5/6] 补齐 app.asar.unpacked')
    fix_unpacked(res, et)

    log('[6/6] 原子替换 app.asar')
    os.replace(new_asar, asar_path)
    shutil.rmtree(et, ignore_errors=True)
    new_unpacked = new_asar + '.unpacked'
    if os.path.isdir(new_unpacked):
        shutil.rmtree(new_unpacked, ignore_errors=True)
    return True


def cmd_install(res):
    try:
        changed = do_install(res)
    except PermissionError as e:
        sys.exit('没有写 ZCode bundle 的权限（macOS App Management 保护）。'
                 '请在 ZCode 会话或终端里运行本命令，而不是 launchd/其他受限上下文:\n%s' % e)
    except RuntimeError as e:
        sys.exit('安装失败（原包未受影响）:\n%s' % e)
    if changed:
        log('\n完成！重启 ZCode 即可看到效果（正在运行的实例不受影响）。')
        log('回滚: python3 install.py --uninstall')
        log('升级自动重注入: python3 install.py --install-hook')
    else:
        log('无需重复安装。')


def strip_blocks(idx_path):
    """uninstall 兜底：从已注入的 index.html 里按标记剥离注入块（备份丢失时用）。"""
    with open(idx_path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    removed = 0
    for fname, opener, marker, where, _mod in BLOCKS:
        mi = next((i for i, l in enumerate(lines) if marker in l), None)
        if mi is None:
            continue
        closer = opener.replace('<', '</')
        oi = max(i for i in range(mi) if lines[i].strip() == opener)      # 紧邻 marker 上方的裸开标签必是我们的
        ci = next(i for i in range(mi, len(lines)) if lines[i].strip() == closer)
        del lines[oi:ci + 1]
        removed += 1
    with open(idx_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))
    return removed


def uninstall_by_strip(res):
    """无 old_v2 备份时的回滚：解包当前 asar → 剥离注入 → 打包原子替换。"""
    asar_path = os.path.join(res, 'app.asar')
    et = os.path.join(res, 'app_extract')
    npx, env = find_npx()
    if os.path.isdir(et):
        shutil.rmtree(et)
    asar(npx, env, 'extract', asar_path, et)
    idx = os.path.join(et, 'out', 'renderer', 'index.html')
    if not os.path.isfile(idx):
        raise RuntimeError('解包后没有 out/renderer/index.html')
    removed = strip_blocks(idx)
    if removed != len(BLOCKS):
        raise RuntimeError('只剥离了 %d/%d 个注入块，结构异常，放弃替换' % (removed, len(BLOCKS)))
    new_asar = os.path.join(res, 'app.asar.new')
    if os.path.exists(new_asar):
        os.remove(new_asar)
    asar(npx, env, 'pack', et, new_asar, '--unpack-dir', '**/{node-pty,ssh2}/**')
    fix_unpacked(res, et)
    os.replace(new_asar, asar_path)
    shutil.rmtree(et, ignore_errors=True)
    shutil.rmtree(new_asar + '.unpacked', ignore_errors=True)


def cmd_uninstall(res):
    asar_path = os.path.join(res, 'app.asar')
    old = os.path.join(res, 'app.asar.old_v2')
    if os.path.isfile(old):
        if os.path.exists(asar_path):
            os.replace(asar_path, os.path.join(res, 'app.asar.injected'))
        os.replace(old, asar_path)
        log('已回滚到官方包。旧注入保留在 app.asar.injected，确认没问题后可手动删除。')
    else:
        try:
            uninstall_by_strip(res)
        except (RuntimeError, PermissionError) as e:
            sys.exit('剥离式回滚失败（原包未受影响）:\n%s\n\n备用方案: 重新安装 ZCode 官方包即可彻底还原。' % e)
        log('没有 old_v2 备份，已从当前包剥离注入块并打包替换（等效官方包）。')
    if is_injected(asar_path):
        log('警告: app.asar 仍含注入标记，未回滚成功。')


def refresh_snapshot():
    """把安装器+注入块快照到固定路径，repo 目录被挪走/删除不影响 hook。"""
    os.makedirs(SNAPSHOT_DIR, exist_ok=True)
    for item in ('install.py', 'inject', 'update', 'tests'):
        src = os.path.join(HERE, item)
        dst = os.path.join(SNAPSHOT_DIR, item)
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
        elif os.path.isfile(src):
            shutil.copy2(src, dst)


def load_config():
    if os.path.isfile(CONFIG_PATH):
        with open(CONFIG_PATH, encoding='utf-8') as f:
            return json.load(f)
    return {}


def save_config(cfg):
    if os.path.isfile(CONFIG_PATH):
        shutil.copy2(CONFIG_PATH, CONFIG_PATH + '.bak-' + HOOK_TAG)
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)


def _upsert_session_hook(entries, tag, hook_obj):
    """在 SessionStart entries 里按 tag 幂等地插入/更新一个 hook。"""
    for entry in entries:
        for h in entry.get('hooks', []):
            if tag in h.get('command', ''):
                h.update(hook_obj)   # 快照路径变化时同步
                return
    entries.append({'hooks': [hook_obj]})


def _is_our_hook(command):
    """是否本工具（含已废弃模块）的 hook——快照路径是唯一可靠标识。
    废弃模块（如 search-server）的快照文件可能已删，但 command 仍指向快照目录。"""
    return SNAPSHOT_DIR in command


def cmd_install_hook():
    refresh_snapshot()
    cfg = load_config()
    hooks = cfg.setdefault('hooks', {})
    hooks['enabled'] = True
    events = hooks.setdefault('events', {})
    entries = events.setdefault('SessionStart', [])
    # 先清理本工具已废弃的 hook（如旧版 search-server），再 upsert 当前的。
    # upsert 只增不删，废弃 hook 不主动清会一直留在 config 里。
    active_cmds = (HOOK_COMMAND, USAGE_HOOK_COMMAND)
    for entry in entries:
        entry['hooks'] = [h for h in entry.get('hooks', [])
                          if not _is_our_hook(h.get('command', '')) or h.get('command', '') in active_cmds]
    entries[:] = [e for e in entries if e.get('hooks')]
    # schema: SessionStart 是 {matcher?, hooks:[...]} 的数组，hook 对象嵌在 hooks 键下
    _upsert_session_hook(entries, HOOK_TAG, {
        'type': 'command',
        'command': HOOK_COMMAND,
        'timeoutMs': 5000,
        'statusMessage': '检查 UI 增强注入状态',
    })
    _upsert_session_hook(entries, USAGE_HOOK_TAG, {
        'type': 'command',
        'command': USAGE_HOOK_COMMAND,
        'timeoutMs': 8000,
        'statusMessage': '拉起用量服务 /usage',
    })
    save_config(cfg)
    log('SessionStart hook 已安装: 自动重注入 + 用量服务')
    log('  配置: %s' % CONFIG_PATH)
    log('  快照: %s' % SNAPSHOT_DIR)
    log('  日志: %s / %s' % (LOG_PATH, USAGE_LOG))
    log('新开会话后生效。')


def cmd_remove_hook():
    cfg = load_config()
    events = cfg.get('hooks', {}).get('events', {})
    removed = 0
    for event, entries in events.items():
        keep = []
        for entry in entries:
            hs = [h for h in entry.get('hooks', [])
                  if HOOK_TAG not in h.get('command', '')
                  and USAGE_HOOK_TAG not in h.get('command', '')
                  and 'zcode-ui-enhancer-search' not in h.get('command', '')]
            if len(hs) != len(entry.get('hooks', [])):
                removed += 1
            if hs:
                entry['hooks'] = hs
                keep.append(entry)
        events[event] = keep
    save_config(cfg)
    log('已移除 %d 个 hook（%s）' % (removed, CONFIG_PATH))


def cmd_auto(res):
    """hook 模式: 会话启动时触发。幂等，任何失败只写日志、以 0 退出。"""
    import fcntl
    time.sleep(5)  # 等 ZCode 升级器写完；也让同一时刻的多次触发先坍缩再抢锁
    os.makedirs(SNAPSHOT_DIR, exist_ok=True)
    lock = os.path.join(SNAPSHOT_DIR, 'auto.lock')
    try:
        fd = open(lock, 'w')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        log('并发触发或锁不可用（errno=%s），退出' % getattr(e, 'errno', '?'))
        return
    try:
        if is_injected(os.path.join(res, 'app.asar')):
            log('已注入，无需处理')
            return
        try:
            changed = do_install(res)
        except PermissionError as e:
            log('没有写 bundle 的权限（macOS App Management）。请在 ZCode 会话或终端里手动运行 install.py: %s' % e)
            return
        if changed:
            log('升级后自动重注入完成，重启 ZCode 生效')
            notify('检测到 ZCode 升级，UI 增强已重装，重启 ZCode 生效')
        else:
            log('跳过（已是注入版）')
    except Exception as e:  # noqa: BLE001 - auto 模式吞掉一切异常只留日志
        log('自动重注入失败（原包未受影响，下次会话或手动重试）: %s' % e)
    finally:
        fd.close()
        if os.path.exists(lock):
            os.remove(lock)


def cmd_status(res):
    asar_path = os.path.join(res, 'app.asar')
    try:
        injected = is_injected(asar_path)
    except OSError as e:
        sys.exit('读不到 app.asar: %s' % e)
    print('ZCode resources : %s' % res)
    print('注入状态        : %s' % ('已注入' if injected else '未注入'))
    print('备份包          : %s' % ('存在 (app.asar.old_v2)' if os.path.isfile(os.path.join(res, 'app.asar.old_v2')) else '无'))
    cfg = load_config()
    hook_on = False
    for entry in cfg.get('hooks', {}).get('events', {}).get('SessionStart', []):
        for h in entry.get('hooks', []):
            if HOOK_TAG in h.get('command', ''):
                hook_on = True
    print('自动重注入 hook : %s' % ('已安装' if hook_on else '未安装'))
    print('日志            : %s' % LOG_PATH)


def main():
    ap = argparse.ArgumentParser(description='ZCode UI Enhancer (macOS edition)')
    ap.add_argument('--app-dir', help='ZCode resources 目录（默认自动探测）')
    ap.add_argument('--uninstall', action='store_true', help='回滚到官方包')
    ap.add_argument('--auto', action='store_true', help='hook 静默模式')
    ap.add_argument('--install-hook', action='store_true', help='安装 SessionStart 自动重注入 hook')
    ap.add_argument('--remove-hook', action='store_true', help='移除 hook')
    ap.add_argument('--status', action='store_true', help='查看状态')
    args = ap.parse_args()

    res = args.app_dir or find_resources_dir()
    if not res and not args.remove_hook:
        sys.exit('找不到 ZCode 安装（/Applications/ZCode.app），可用 --app-dir 指定 resources 目录')
    if not res:
        res = ''

    if args.uninstall:
        cmd_uninstall(res)
    elif args.auto:
        cmd_auto(res)
    elif args.install_hook:
        cmd_install_hook()
    elif args.remove_hook:
        cmd_remove_hook()
    elif args.status:
        cmd_status(res)
    else:
        cmd_install(res)


if __name__ == '__main__':
    main()
