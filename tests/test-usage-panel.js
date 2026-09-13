// 全量用量面板单元测试：最小 DOM 桩 + fetch 桩跑 inject/usage-panel.js
// fetch 桩挂 globalThis.fetch（脚本走全局 fetch），localStorage 遮蔽 Node 内建。
// 验证：挂载、无数据占位、有数据渲染（今日/累计/by-model/成本）、展开收起、失败降级。
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(), nodeType: 1, children: [], style: {}, _attrs: {},
    _handlers: {}, className: '', parentNode: null, title: '',
    setAttribute(k, v) { this._attrs[k] = v; },
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    addEventListener(ev, fn) { (this._handlers[ev] = this._handlers[ev] || []).push(fn); },
    click() { (this._handlers.click || []).forEach((fn) => fn()); },
    querySelector(sel) {
      const want = sel.replace('#', '');
      const walk = (n) => { for (const c of n.children) { if (c._attrs.id === want) return c; const r = walk(c); if (r) return r; } return null; };
      return walk(this);
    },
  };
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html || ''; },
    set(h) {
      this._html = String(h);
      this.children = this.children.filter(c => c._keep);
      for (const m of this._html.matchAll(/id="([^"]+)"/g)) {
        const c = makeEl('span'); c._attrs.id = m[1]; this.appendChild(c);
      }
    },
  });
  Object.defineProperty(el, 'textContent', {
    get() { return this._text !== undefined ? this._text : (this.children || []).map(c => c.textContent).join(''); },
    set(v) { this._text = String(v); this.children = []; },
  });
  return el;
}

const html = global.document = {
  createElement: (t) => makeEl(t),
  documentElement: makeEl('html'),
  body: makeEl('body'),
};

const SAMPLE = {
  generated_at: 1789142325377,
  totals: { turns: 1165, requests: 19816, input_tokens: 4292151939, output_tokens: 13373974,
            reasoning_tokens: 3698228, cache_read_input_tokens: 4156618490,
            cache_creation_input_tokens: 1144591, tool_calls: 27154 },
  today: { turns: 97, requests: 3631, input_tokens: 1441075269, output_tokens: 2579543,
           reasoning_tokens: 565052, cache_read_input_tokens: 1434734066,
           cache_creation_input_tokens: 0, tool_calls: 3986 },
  by_model: [
    { model_id: 'GLM-5.3', provider_id: 'p1', requests: 3618, output_tokens: 2179014, input_tokens: 655580635 },
    { model_id: 'k3', provider_id: 'p2', requests: 2275, output_tokens: 628454, input_tokens: 391066230 },
  ],
  recent_sessions: [],
};
const WITH_PRICES = Object.assign({}, SAMPLE, { prices: { 'GLM-5.3': { output: 2.0 } } });

let fetchImpl = () => Promise.reject(new Error('not set'));
// 遮蔽 Node 22+ 内建 localStorage
global.localStorage = { _s: {}, getItem(k) { return k in this._s ? this._s[k] : null; }, setItem(k, v) { this._s[k] = String(v); } };
global.window = {
  location: { pathname: '/Users/someone/Library/x' },
  ZCODE_USAGE_URL: 'file:///mock/usage.json',
  __zcodeUsageFetch: (...a) => fetchImpl(...a),   // 显式注入点（覆盖 Node 原生 fetch）
};

const code = fs.readFileSync(path.join(__dirname, '..', 'inject', 'usage-panel.js'), 'utf-8');
vm.runInThisContext(code, { filename: 'usage-panel.js' });

// 换 fetch 实现后主动触发一次 poll（脚本闭包内的 setInterval 周期 30s 不可等）
function triggerPoll() {
  // 脚本 load 时调用过一次 poll；之后只能靠 30s 间隔。
  // 测试等不了 30s，所以这里通过「再点一次展开/收起」触发 render 不够（render 用旧 lastData）。
  // 真正做法：脚本暴露了 poll 吗？没有。因此测试改用「重新加载脚本」来换 fetch 实现。
}

const badge = html.documentElement.children[0];
const elHead = badge.querySelector('#zcode-usage-head');
const elBody = badge.querySelector('#zcode-usage-body');
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
function check(name, cond, detail) {
  cond ? pass++ : fail++;
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (detail !== undefined ? '  [' + detail + ']' : ''));
}

(async () => {
  check('徽章已挂载', !!badge && !!elHead && !!elBody);

  // 1. fetch 失败 → 无数据占位（降级不崩）
  fetchImpl = () => Promise.reject(new Error('CSP blocked'));
  await sleep(100);
  check('fetch 失败显示无数据占位', /无数据/.test(elHead.textContent), elHead.textContent);

  // 2. fetch 成功（无价目）→ 头部今日 output
  fetchImpl = () => Promise.resolve({ ok: true, json: () => Promise.resolve(SAMPLE) });
  window.__zcodeUsagePoll();
  await sleep(100);
  check('成功后头部显示今日 output', /今日 2\.6M out/.test(elHead.textContent), elHead.textContent);

  // 3. 展开 → 面板含累计/今日/by-model
  badge.click();   // 展开
  await sleep(50);
  const body = elBody.textContent;
  check('面板含累计回合数', /1165 回合/.test(body), body.split('\n')[0]);
  check('面板含累计 output 13.4M', /输出 13\.4M/.test(body));
  check('面板含缓存读分项', /缓存读 4\.16B/.test(body), (body.match(/缓存读[^\n]*/) || ['none'])[0]);
  check('面板含 by_model GLM', /GLM-5\.3/.test(body));
  check('无价目时不显示成本', !/估算成本/.test(body));

  // 4. 有价目 → 显示成本（GLM out 2179014/1M×$2 ≈ $4.36）
  fetchImpl = () => Promise.resolve({ ok: true, json: () => Promise.resolve(WITH_PRICES) });
  window.__zcodeUsagePoll();
  await sleep(100);
  if (elBody.style.display === 'none') badge.click();   // 确保展开后 render
  await sleep(30);
  check('有价目时显示成本', /估算成本\(输出\)\s+\$4\.36/.test(elBody.textContent),
        (elBody.textContent.match(/估算成本[^\n]*/) || ['none'])[0]);

  // 5. 收起后 body 隐藏
  check('展开状态可见', elBody.style.display !== 'none');
  badge.click();
  check('收起后隐藏', elBody.style.display === 'none');

  console.log('\n' + (fail === 0 ? 'ALL PASS' : fail + ' FAILED') + ' (' + pass + ' passed)');
  process.exit(fail === 0 ? 0 : 1);
})();
