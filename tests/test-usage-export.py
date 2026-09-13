#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""usage-export.py 的独立测试：建一个迷你 db.sqlite，验证聚合口径与 schema。"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
EXPORTER = os.path.join(HERE, '..', 'inject', 'usage-export.py')

passed = failed = 0
def check(name, cond, detail=''):
    global passed, failed
    if cond: passed += 1
    else: failed += 1
    print(('  ✓ ' if cond else '  ✗ ') + name + ('  [%s]' % detail if detail else ''))


def build_db(path):
    db = sqlite3.connect(path)
    db.executescript('''
      CREATE TABLE turn_usage (session_id, turn_id, trace_id, user_message_id, status,
        started_at, first_model_start_at, first_token_at, completed_at, duration_ms,
        time_to_first_token_ms, model_request_count, model_retry_count, tool_call_count,
        tool_error_count, input_tokens, output_tokens, reasoning_tokens,
        cache_creation_input_tokens, cache_read_input_tokens);
      CREATE TABLE model_usage (id, logical_request_id, attempt_index, session_id, turn_id,
        trace_id, span_id, assistant_message_id, parent_user_message_id, query_source,
        provider_id, model_id, variant, agent, mode, task_type, status, started_at,
        first_token_at, completed_at);
      CREATE TABLE part (id, message_id, session_id, time_created, time_updated, data, sequence);
      CREATE TABLE session (id, project_id, workspace_id, parent_id, slug, directory, path,
        title, version, share_url, summary_additions, summary_deletions, summary_files,
        summary_diffs, revert, permission, time_created, time_updated, time_compacting,
        time_archived);
    ''')
    now = int(time.time() * 1000)
    lt = time.localtime()
    # 今日正午 12:00（无论凌晨/深夜跑测试，正午都稳定落在"今日"内）
    noon = int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 12, 0, 0, 0, 0, -1)) * 1000)
    day0 = noon                        # 今日回合时间戳
    old = noon - 40 * 86400 * 1000     # 40 天前（不算今日）

    # 会话 A：2 回合（1 今日 + 1 旧），会话 B(subagent 前缀)：应被 recent_sessions 排除
    db.execute("INSERT INTO session (id,title,time_updated) VALUES ('sess_a','会话A',?)", (now,))
    db.execute("INSERT INTO session (id,title,time_updated) VALUES ('sess_subagent_x','子代理',?)", (now,))
    # 今日回合：10 请求、out=1000、in=5000（其中 cache_read 4000）
    db.execute("""INSERT INTO turn_usage (session_id,turn_id,status,started_at,completed_at,
        model_request_count,tool_call_count,input_tokens,output_tokens,reasoning_tokens,
        cache_creation_input_tokens,cache_read_input_tokens)
        VALUES ('sess_a','t1','completed',?,?,?,?,?,?,?,?,?)""",
        (day0, day0 + 5000, 10, 3, 5000, 1000, 200, 100, 4000))
    # 旧回合：out=500
    db.execute("""INSERT INTO turn_usage (session_id,turn_id,status,started_at,completed_at,
        model_request_count,tool_call_count,input_tokens,output_tokens,reasoning_tokens,
        cache_creation_input_tokens,cache_read_input_tokens)
        VALUES ('sess_a','t2','completed',?,?,?,?,?,?,?,?,?)""",
        (old, old + 5000, 2, 1, 2000, 500, 50, 0, 1500))
    db.execute("""INSERT INTO turn_usage (session_id,turn_id,status,started_at,completed_at,
        model_request_count,tool_call_count,input_tokens,output_tokens,reasoning_tokens,
        cache_creation_input_tokens,cache_read_input_tokens)
        VALUES ('sess_subagent_x','t3','completed',?,?,?,?,?,?,?,?,?)""",
        (day0, day0 + 1000, 1, 0, 100, 10, 0, 0, 90))

    # model_usage + step-finish part：GLM 2 请求（out 100+200）、k3 1 请求（无 part，测 77% 覆盖）
    for i, (mid, out, inp) in enumerate((('GLM-5.3', 100, 800), ('GLM-5.3', 200, 900))):
        db.execute("""INSERT INTO model_usage (id,session_id,turn_id,assistant_message_id,provider_id,model_id,status,started_at)
            VALUES (?,?,?,?,?,?,?,?)""", ('m%d' % i, 'sess_a', 't1', 'msg%d' % i, 'prov', mid, 'completed', day0))
        db.execute("INSERT INTO part (id,message_id,session_id,data,sequence) VALUES (?,?,?,?,0)",
                   ('p%d' % i, 'msg%d' % i, 'sess_a',
                    json.dumps({'type': 'step-finish', 'tokens': {'input': inp, 'output': out, 'reasoning': 0}})))
    db.execute("""INSERT INTO model_usage (id,session_id,turn_id,assistant_message_id,provider_id,model_id,status,started_at)
        VALUES ('m9','sess_a','t1','msg9','prov','k3','completed',?)""", (day0,))
    db.commit()
    db.close()


def main():
    tmp = tempfile.mkdtemp(prefix='zcode-usage-test-')
    db_path = os.path.join(tmp, 'db.sqlite')
    out_path = os.path.join(tmp, 'usage.json')
    build_db(db_path)

    env = dict(os.environ)
    # 用环境变量覆盖库/输出路径（导出器要支持，见下）
    env['ZCODE_USAGE_DB'] = db_path
    env['ZCODE_USAGE_OUT'] = out_path
    env['ZCODE_USAGE_PRICES'] = os.path.join(tmp, 'no-prices.json')
    r = subprocess.run([sys.executable, EXPORTER], env=env, capture_output=True, text=True)
    check('导出器退出码 0', r.returncode == 0, r.stderr.strip()[:120])
    check('usage.json 已生成', os.path.isfile(out_path))
    if not os.path.isfile(out_path):
        print('\n%s FAILED (%d passed)' % (failed, passed)); sys.exit(1)

    d = json.load(open(out_path, encoding='utf-8'))

    check('schema 顶层键齐全', all(k in d for k in ('generated_at', 'totals', 'today', 'by_model', 'recent_sessions')))

    t = d['totals']
    check('累计 turns=3', t['turns'] == 3, str(t['turns']))
    check('累计 output=1000+500+10=1510', t['output_tokens'] == 1510, str(t['output_tokens']))
    check('累计 input=5000+2000+100=7100', t['input_tokens'] == 7100, str(t['input_tokens']))
    check('累计 cache_read=4000+1500+90=5590', t['cache_read_input_tokens'] == 5590, str(t['cache_read_input_tokens']))
    check('累计 tool_calls=3+1+0=4', t['tool_calls'] == 4, str(t['tool_calls']))

    td = d['today']
    check('今日 turns=2（t1+t3，旧回合不计）', td['turns'] == 2, str(td['turns']))
    check('今日 output=1000+10=1010', td['output_tokens'] == 1010, str(td['output_tokens']))

    bm = {m['model_id']: m for m in d['by_model']}
    check('by_model 含 GLM-5.3', 'GLM-5.3' in bm)
    check('GLM 按 part 聚合 output=100+200=300（不重复计回合）', bm.get('GLM-5.3', {}).get('output_tokens') == 300,
          str(bm.get('GLM-5.3', {}).get('output_tokens')))
    check('GLM requests=2', bm.get('GLM-5.3', {}).get('requests') == 2)
    check('无 part 的 k3 不进 by_model（JOIN 非 LEFT）', 'k3' not in bm, str(list(bm)))

    rs = d['recent_sessions']
    check('recent_sessions 排除 subagent', all(not s['session_id'].startswith('sess_subagent') for s in rs),
          str([s['session_id'] for s in rs]))
    check('recent_sessions 含会话A 且带标题', any(s['session_id'] == 'sess_a' and s['title'] == '会话A' for s in rs))

    check('无价目表时无 prices 键', 'prices' not in d)

    print('\n' + ('ALL PASS' if failed == 0 else '%d FAILED' % failed) + ' (%d passed)' % passed)
    sys.exit(0 if failed == 0 else 1)


if __name__ == '__main__':
    main()
