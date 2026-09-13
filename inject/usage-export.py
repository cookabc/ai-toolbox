#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ZCode 用量导出器：把 cli/db/db.sqlite 聚合成 inject 面板可读的 usage.json

由 SessionStart hook 在会话启动时调用（与 install.py --auto 同一挂载点），
渲染层 usage-panel.js 轮询 fetch 产物。只读查询 + 原子写，不动任何业务数据。

口径说明（与渲染层 DOM 估算的本质区别）：
  - 数据源是 CLI 层落库的精确 token 计数，跨会话、跨窗口、含后台会话；
  - turn_usage.input_tokens 含 cache_read（命中 prompt 缓存的部分），
    所以「输入」不等于「计费新 token」，面板分项列出缓存读；
  - 没有官方价目表（本地库无价格字段），成本 = 用户数 / 1M tok × 自填单价，
    单价从 ~/.zcode/cli/usage-prices.json 读，缺省只显示 token 量不显示 $。

产物 schema（usage-panel.js 按此渲染）：
{
  "generated_at": 毫秒时间戳,
  "totals":  {turns, requests, input_tokens, output_tokens, reasoning_tokens,
              cache_read_input_tokens, cache_creation_input_tokens, tool_calls},
  "today":   {同上, 按 started_at 当日 0 点过滤},
  "by_model": [{model_id, provider_id, requests, output_tokens}, ... 前 8],
  "recent_sessions": [{session_id, title, turns, output_tokens, time_updated}, ... 前 6]
}
"""
import json
import os
import sqlite3
import sys
import time

DB = os.environ.get('ZCODE_USAGE_DB') or os.path.expanduser('~/.zcode/cli/db/db.sqlite')
OUT = os.environ.get('ZCODE_USAGE_OUT') or os.path.expanduser('~/.zcode/cli/usage.json')
PRICES = os.environ.get('ZCODE_USAGE_PRICES') or os.path.expanduser('~/.zcode/cli/usage-prices.json')

SUM_COLS = ('turns', 'requests', 'input_tokens', 'output_tokens', 'reasoning_tokens',
            'cache_read_input_tokens', 'cache_creation_input_tokens', 'tool_calls')


def q_totals(db, where='', args=()):
    r = db.execute(
        'SELECT COUNT(*), COALESCE(SUM(model_request_count),0), COALESCE(SUM(input_tokens),0),'
        ' COALESCE(SUM(output_tokens),0), COALESCE(SUM(reasoning_tokens),0),'
        ' COALESCE(SUM(cache_read_input_tokens),0), COALESCE(SUM(cache_creation_input_tokens),0),'
        ' COALESCE(SUM(tool_call_count),0) FROM turn_usage %s' % where, args).fetchone()
    return dict(zip(SUM_COLS, r))


def compute():
    """实时聚合并返回 usage dict（/usage 端点每次请求调用，turn_usage 聚合几十 ms）。"""
    db = sqlite3.connect('file:%s?mode=ro' % DB, uri=True)
    db.row_factory = sqlite3.Row
    now_ms = int(time.time() * 1000)
    lt = time.localtime()
    day0 = int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1)) * 1000)

    data = {
        'generated_at': now_ms,
        'totals': q_totals(db),
        'today': q_totals(db, 'WHERE started_at >= ?', (day0,)),
        # by_model 的 token 走 part(step-finish) 逐请求精确值（约 77% 请求有，其余未落 token）。
        # 不能 JOIN turn_usage：一回合多请求会笛卡尔积放大 output（31 请求回合重复计 31 次）。
        'by_model': [dict(r) for r in db.execute(
            'SELECT m.model_id, m.provider_id, COUNT(*) AS requests,'
            " COALESCE(SUM(CAST(json_extract(p.data, '$.tokens.output') AS INTEGER)),0) AS output_tokens,"
            " COALESCE(SUM(CAST(json_extract(p.data, '$.tokens.input') AS INTEGER)),0) AS input_tokens"
            ' FROM model_usage m'
            ' JOIN part p ON p.message_id = m.assistant_message_id'
            "   AND json_extract(p.data, '$.type') = 'step-finish'"
            ' GROUP BY m.model_id, m.provider_id ORDER BY requests DESC LIMIT 8')],
        'recent_sessions': [dict(r) for r in db.execute(
            'SELECT t.session_id, COALESCE(s.title, t.session_id) AS title,'
            ' COUNT(*) AS turns, COALESCE(SUM(t.output_tokens),0) AS output_tokens,'
            ' MAX(t.completed_at) AS time_updated'
            ' FROM turn_usage t LEFT JOIN session s ON s.id = t.session_id'
            " WHERE t.session_id NOT LIKE 'sess_subagent%'"
            ' GROUP BY t.session_id ORDER BY time_updated DESC LIMIT 6')],
    }
    db.close()

    if os.path.isfile(PRICES):
        try:
            with open(PRICES, encoding='utf-8') as f:
                data['prices'] = json.load(f)   # {model_id: {input, output, cache_read}} 每 1M tok 美元
        except Exception:
            pass   # 价目表坏了不致命
    return data


def main():
    if not os.path.isfile(DB):
        sys.exit(0)   # 没库就不是错误：面板会显示「暂无数据」
    data = compute()
    tmp = OUT + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, OUT)   # 原子写：面板轮询不会读到半截文件


def make_handler():
    """构造一个把 /usage 也包进来的 HTTP handler（--serve 常驻模式用）。
    用量数据每次请求实时重算（turn_usage 聚合几十 ms，无需快照）。"""
    from http.server import BaseHTTPRequestHandler
    from urllib.parse import urlparse

    class Handler(BaseHTTPRequestHandler):
        def _send(self, obj, code=200):
            body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Access-Control-Allow-Origin', '*')   # 渲染层 file:// origin 为 null
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

        def do_GET(self):
            if urlparse(self.path).path == '/usage':
                try:
                    self._send(compute())
                except Exception as e:
                    self._send({'error': str(e)}, 500)
            else:
                self._send({'error': 'not found'}, 404)

    return Handler


def serve():
    """常驻模式：在 127.0.0.1:7391 提供 /usage 端点（实时聚合 db.sqlite）。
    由 SessionStart hook 拉起；端口被占 = 已有实例在跑，直接退出（hook 幂等）。"""
    from http.server import ThreadingHTTPServer
    host = '127.0.0.1'
    port = int(os.environ.get('ZCODE_USAGE_PORT') or '7391')
    try:
        srv = ThreadingHTTPServer((host, port), make_handler())
    except OSError:
        sys.exit(0)   # 端口被占 = 已有服务，退出（hook 幂等）
    sys.stderr.write('zcode-usage 服务已启动 http://%s:%d/usage\n' % (host, port))
    srv.serve_forever()


if __name__ == '__main__':
    try:
        if '--serve' in sys.argv:
            serve()
        else:
            main()
    except Exception as e:   # hook 语境：任何失败只留 stderr，退出码不阻塞会话启动
        print('usage-export 失败: %s' % e, file=sys.stderr)
        sys.exit(0)
