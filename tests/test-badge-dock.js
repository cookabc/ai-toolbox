// 徽章边栏单元测试：DOM 桩跑 inject/badge-dock.js（右缘竖排边栏版）
// 验证：三项渲染、从隐藏 DOM 读数刷新、原徽章被隐藏、hover 弹详情、收起/拖动、主题钮
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(), nodeType: 1, children: [], style: {}, _attrs: {},
    _handlers: {}, className: '', parentNode: null, textContent: '', title: '',
    offsetWidth: 60, offsetHeight: 200,
    setAttribute(k, v) { this._attrs[k] = v; },
    getAttribute(k) { return (k in this._attrs) ? this._attrs[k] : null; },
    appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; },
    removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; },
    addEventListener(ev, fn) { (this._handlers[ev] = this._handlers[ev] || []).push(fn); },
    getBoundingClientRect() { return { left: 940, top: 200, width: 60, height: 40 }; },
    querySelector(sel) {
      const want = sel.replace('#', '').replace('.', '');
      const walk = (n) => {
        for (const c of n.children) {
          if (c._attrs.id === want || (c.className || '').split(' ').indexOf(want) >= 0) return c;
          const r = walk(c); if (r) return r;
        }
        return null;
      };
      return walk(this);
    },
  };
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html || ''; },
    set(h) {
      this._html = String(h);
      this.children = this.children.filter(c => c._keep);
      // 解析 class="zb-xxx" 建子元素（边栏 cell 用 class 标记）
      for (const m of this._html.matchAll(/class="(zb-[a-z]+)"/g)) {
        const c = makeEl('span'); c.className = m[1]; this.appendChild(c);
      }
    },
  });
  return el;
}

const docEl = makeEl('html');
const byId = {};
const docHandlers = {};
const html = global.document = {
  createElement: (t) => makeEl(t),
  documentElement: docEl,
  body: makeEl('body'),
  getElementById: (id) => byId[id] || null,
  addEventListener(ev, fn) { (docHandlers[ev] = docHandlers[ev] || []).push(fn); },
};
let moCb = null;
global.MutationObserver = class { constructor(cb) { moCb = cb; } observe() {} };
const store = {};
global.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }, removeItem: k => { delete store[k]; } };
global.window = { innerWidth: 1000, innerHeight: 650, localStorage: global.localStorage };

const code = fs.readFileSync(path.join(__dirname, '..', 'inject', 'badge-dock.js'), 'utf-8');

// 造三个「真实徽章」DOM（模拟 tps/ctx/usage 脚本挂载的），含关键数据元素
function makeBadge(id, inner) {
  const b = makeEl('div'); b._attrs.id = id; byId[id] = b;
  docEl.appendChild(b);
  Object.keys(inner).forEach(sel => {
    const c = makeEl('span'); c._attrs.id = sel; c.textContent = inner[sel]; b.appendChild(c);
  });
  return b;
}
makeBadge('zcode-tps-badge', { 'zcode-tps-rate': '31.2', 'zcode-tps-meta': 'Σ 244 tok · 累计<br>峰值 205.3 · EST' });
makeBadge('zcode-ctx-badge', { 'zcode-ctx-pct': '0%', 'zcode-ctx-meta': '369 / 1M<br>可见 · EST' });
makeBadge('zcode-usage-badge', { 'zcode-usage-head': '今日 185k out', 'zcode-usage-body': '输出 13.6M · 推理 3.7M\n输入 4.45B' });

vm.runInThisContext(code, { filename: 'badge-dock.js' });

let pass = 0, fail = 0;
function check(name, cond, detail) {
  cond ? pass++ : fail++;
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (detail !== undefined ? '  [' + detail + ']' : ''));
}
const T = window.__zcodeDockTest;
function fireDoc(ev, arg) { (docHandlers[ev] || []).forEach(fn => fn(arg)); }
function fireEl(el, ev, arg) { (el._handlers[ev] || []).forEach(fn => fn(arg || {})); }

(async () => {
  check('边栏 dock 已挂载', !!T.dock && !!T.rail);
  check('三项 cell 已渲染（⚡◍📊）', T.items.length === 3, 'items=' + T.items.length);

  // 1. 原徽章被隐藏（逻辑照跑、视觉隐藏）
  check('tps 原徽章被隐藏', byId['zcode-tps-badge'].style.display === 'none', byId['zcode-tps-badge'].style.display);
  check('ctx 原徽章被隐藏', byId['zcode-ctx-badge'].style.display === 'none');
  check('usage 原徽章被隐藏', byId['zcode-usage-badge'].style.display === 'none');

  // 2. 从隐藏 DOM 读数刷新到边栏
  T.sweep();
  check('速率行显示 31.2', T.items[0].valEl.textContent === '31.2', T.items[0].valEl.textContent);
  check('水位行显示 0%', T.items[1].valEl.textContent === '0%', T.items[1].valEl.textContent);
  check('用量行显示 185k（去前缀/后缀）', T.items[2].valEl.textContent === '185k', T.items[2].valEl.textContent);

  // 3. hover 弹详情
  fireEl(T.items[0].cell, 'mouseenter');
  check('hover 速率弹出详情', T.tip.style.display === 'block' && /244 tok/.test(T.tip.textContent),
        T.tip.textContent.slice(0, 30));
  fireEl(T.items[0].cell, 'mouseleave');
  check('移开收起详情', T.tip.style.display === 'none');

  // 4. 用量详情含明细
  fireEl(T.items[2].cell, 'mouseenter');
  check('用量详情含明细', /13\.6M/.test(T.tip.textContent), T.tip.textContent.slice(0, 30));
  fireEl(T.items[2].cell, 'mouseleave');

  // 5. 点击把手收起（未拖动）
  T.handle._handlers.mousedown[0]({ clientX: 950, clientY: 100, preventDefault() {} });
  fireDoc('mouseup', {});
  check('点击把手收起', T.rail.style.display === 'none' && T.fab.style.display === 'flex');
  check('收起写入记忆', store['zcode-dock-collapsed'] === '1');
  fireEl(T.fab, 'click');
  check('点 fab 展开', T.rail.style.display === 'flex');

  // 6. 拖动换位
  T.handle._handlers.mousedown[0]({ clientX: 950, clientY: 100, preventDefault() {} });
  fireDoc('mousemove', { clientX: 500, clientY: 300 });
  fireDoc('mouseup', {});
  check('拖动后 dock 换位置', T.dock.style.left !== '' && T.dock.style.right === 'auto', T.dock.style.left);
  check('拖动位置记忆', !!store['zcode-dock-pos'], store['zcode-dock-pos']);

  // 7. 主题钮：兜底切换（本测试环境 window.__zcodeTheme/__zcodeSetTheme 未定义 → 走兜底）
  const themeBtn = T.dock.children.find(c => (c._attrs.id === 'zcode-theme-toggle') || /切换浅色/.test(c.title || ''));
  check('主题钮存在（兜底模式）', !!themeBtn, themeBtn && themeBtn.title);
  if (themeBtn) {
    const before = themeBtn.textContent;
    fireEl(themeBtn, 'click');
    check('点击主题钮切换图标', themeBtn.textContent !== before || store['theme'] !== undefined,
          'before=' + before + ' after=' + themeBtn.textContent + ' store.theme=' + store['theme']);
    check('兜底写 localStorage theme', store['theme'] === 'light' || store['theme'] === 'dark', store['theme']);
  }

  console.log('\n' + (fail === 0 ? 'ALL PASS' : fail + ' FAILED') + ' (' + pass + ' passed)');
  process.exit(fail === 0 ? 0 : 1);
})();
