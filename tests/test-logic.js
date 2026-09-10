// TPS 计数逻辑单元测试：用最小 DOM 桩跑 zcode-tps.js，验证净增量统计
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

/* ---------- DOM 桩 ---------- */
function makeEl(tag) {
  const el = {
    tagName: tag, nodeType: 1, children: [], style: {}, _attrs: {},
    isConnected: true, parentNode: null, data: undefined,
    setAttribute(k, v) { this._attrs[k] = v; },
    getAttribute(k) { return (k in this._attrs) ? this._attrs[k] : null; },
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    querySelector(sel) {
      const want = sel.replace('#', '');
      const walk = (n) => { for (const c of n.children) { if (c._attrs.id === want) return c; const r = walk(c); if (r) return r; } return null; };
      return walk(this);
    },
    querySelectorAll() { return []; },
    contains(n) {
      if (n === this) return true;
      const walk = (n2) => { for (const c of n2.children) { if (c === n || walk(c)) return true; } return false; };
      return walk(this);
    },
    getBoundingClientRect() { return { width: 500, top: 300, left: 0 }; },
    getContext() {
      const grad = { addColorStop() {} };
      return new Proxy({}, { get: (t, k) => (k === 'createLinearGradient' ? () => grad : () => {}) });
    },
  };
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html || ''; },
    set(html) {
      this._html = String(html);
      this.children = this.children.filter(c => c._keep);
      for (const m of this._html.matchAll(/id="([^"]+)"/g)) {
        const c = makeEl('span'); c._attrs.id = m[1]; this.appendChild(c);
      }
    },
  });
  Object.defineProperty(el, 'textContent', {
    get() { return this._text || (this.children || []).map(c => c.textContent).join(''); },
    set(v) { this._text = String(v); this.children = []; },
  });
  return el;
}

const html = global.document = {
  createElement: (t) => makeEl(t),
  documentElement: makeEl('html'),
  body: makeEl('body'),
  querySelectorAll: () => [],
  querySelector: () => null,
};
global.window = { innerWidth: 1920 };
global.__mo = null;
global.MutationObserver = class {
  constructor(cb) { this.cb = cb; global.__mo = this; }
  observe(target, opts) { global.__observed = { target, opts }; }
  disconnect() {}
};

/* ---------- 载入脚本（直读仓库里的原始注入块） ---------- */
const code = fs.readFileSync(path.join(__dirname, '..', 'inject', 'tps.js'), 'utf-8');
vm.runInThisContext(code, { filename: 'tps.js' });

const badge = html.documentElement.children[0];
const meta = badge.querySelector('#zcode-tps-meta');
const rate = badge.querySelector('#zcode-tps-rate');
const textNode = (data, parent) => ({ nodeType: 3, data, parentNode: parent || html.body });

function readSigma() {
  const m = /Σ ([\d.]+)(k?) tok/.exec(meta.innerHTML);
  if (!m) return NaN;
  return parseFloat(m[1]) * (m[2] === 'k' ? 1000 : 1);
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
function check(name, cond, detail) {
  cond ? pass++ : fail++;
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (detail !== undefined ? '  [' + detail + ']' : ''));
}

(async () => {
  await sleep(250);   // 等第一个 tick 建立 observer
  check('观察根=body', global.__observed && global.__observed.target === html.body);
  check('观察选项含 characterDataOldValue', global.__observed.opts.characterDataOldValue === true);

  // 1. 纯新增（真实流式）
  global.__mo.cb([{ type: 'childList', target: html.body, addedNodes: [textNode('这是一段新增的中文输出内容')], removedNodes: [] }]);
  await sleep(200);
  const s1 = readSigma();
  check('纯新增被计入', s1 === 13, 'Σ=' + s1);

  // 2. 重渲染：同内容删旧插新 → 净零
  const before = readSigma();
  const same = '终端行内容 xterm-row-text';
  global.__mo.cb([{ type: 'childList', target: html.body, addedNodes: [textNode(same)], removedNodes: [textNode(same)] }]);
  await sleep(200);
  const after = readSigma();
  check('重渲染(删旧插新同内容)净零不计', after === before, 'before=' + before + ' after=' + after);

  // 2b. 大批次（滚动挂载历史行/切换会话整段加载）被闸门忽略
  const b2b = readSigma();
  const big = '历史消息内容'.repeat(100);   // 600 CJK chars ≈ 600 tok > BATCH_MAX
  global.__mo.cb([{ type: 'childList', target: html.body, addedNodes: [textNode(big)], removedNodes: [] }]);
  await sleep(200);
  check('大批次(滚动挂载/切会话)被闸门忽略', readSigma() === b2b, 'Σ=' + readSigma());

  // 3. characterData 增长按差值计
  const b3 = readSigma();
  global.__mo.cb([{ type: 'characterData', target: textNode('已有文本'), oldValue: '已有文本' }]);
  await sleep(0);
  global.__mo.cb([{ type: 'characterData', target: textNode('已有文本续写更多内容'), oldValue: '已有文本' }]);
  await sleep(200);
  const a3 = readSigma();
  check('characterData 增量被计入', a3 > b3, 'before=' + b3 + ' after=' + a3);

  // 4. 徽章自身刷新被跳过
  const b4 = readSigma();
  const rateEl = badge.querySelector('#zcode-tps-rate');
  global.__mo.cb([{ type: 'childList', target: rateEl, addedNodes: [textNode('999.9')], removedNodes: [] }]);
  await sleep(200);
  check('徽章自身刷新不计入(防反馈)', readSigma() === b4, 'Σ=' + readSigma());

  // 5. 净减少：总量不变，样本计入负值
  const b5 = readSigma();
  const t5 = { nodeType: 3, data: '', parentNode: html.body };
  global.__mo.cb([{ type: 'childList', target: html.body, addedNodes: [], removedNodes: [textNode('被折叠收起的一大段内容')] }]);
  await sleep(200);
  check('净减少不增加总量', readSigma() === b5, 'Σ=' + readSigma());

  // 6. 等 tick 渲染出峰值/总计字段
  await sleep(300);
  check('meta 含 峰值 字段', /峰值/.test(meta.innerHTML), meta.innerHTML.replace(/<br>/, ' | '));

  console.log('\n' + (fail === 0 ? 'ALL PASS' : fail + ' FAILED') + ' (' + pass + ' passed)');
  process.exit(fail === 0 ? 0 : 1);
})();
