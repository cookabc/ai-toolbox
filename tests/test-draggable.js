// 通用拖拽助手 + FAB/导航轨道拖动 单元测试
// 验证 __zcodeMakeDraggable：拖动换位、位置记忆、点击回调、transform 清除、视口截断
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(), nodeType: 1, children: [], style: {}, _attrs: {},
    _handlers: {}, className: '', parentNode: null, textContent: '', offsetWidth: 40, offsetHeight: 40,
    setAttribute(k, v) { this._attrs[k] = v; },
    appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; },
    removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; },
    addEventListener(ev, fn) { (this._handlers[ev] = this._handlers[ev] || []).push(fn); },
    getBoundingClientRect() { return { left: 100, top: 100, width: 40, height: 40 }; },
    querySelector() { return makeEl('span'); },
  };
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html || ''; },
    set(h) { this._html = String(h); this.children = []; for (const m of this._html.matchAll(/id="([^"]+)"/g)) { const c = makeEl('span'); c._attrs.id = m[1]; this.appendChild(c); } },
  });
  return el;
}

const docHandlers = {};
const html = global.document = {
  createElement: (t) => makeEl(t),
  documentElement: makeEl('html'),
  body: makeEl('body'),
  getElementById: () => null,
  addEventListener(ev, fn) { (docHandlers[ev] = docHandlers[ev] || []).push(fn); },
};
global.MutationObserver = class { constructor() {} observe() {} };
const store = {};
global.localStorage = { getItem: (k) => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }, removeItem: (k) => { delete store[k]; } };
global.window = { innerWidth: 1500, innerHeight: 950, localStorage: global.localStorage };

// 只加载 badge-dock（它导出 __zcodeMakeDraggable）
const code = fs.readFileSync(path.join(__dirname, '..', 'inject', 'badge-dock.js'), 'utf-8');
vm.runInThisContext(code, { filename: 'badge-dock.js' });

let pass = 0, fail = 0;
function check(name, cond, detail) {
  cond ? pass++ : fail++;
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (detail !== undefined ? '  [' + detail + ']' : ''));
}
function fireDoc(ev, arg) { (docHandlers[ev] || []).forEach(fn => fn(arg)); }

(async () => {
  check('拖拽助手已导出', typeof window.__zcodeMakeDraggable === 'function');

  // 造一个模拟 FAB
  const fab = makeEl('div');
  fab.style.position = 'fixed'; fab.style.right = '18px'; fab.style.bottom = '24px';
  html.documentElement.appendChild(fab);

  let clicked = 0;
  window.__zcodeMakeDraggable(fab, { storageKey: 'fab-pos', onClick: () => { clicked++; } });

  // 1. 拖动换位：move >4px
  fab._handlers.mousedown[0]({ clientX: 120, clientY: 120, preventDefault() {} });
  fireDoc('mousemove', { clientX: 500, clientY: 300 });
  fireDoc('mouseup', {});
  check('拖动后位置改变', fab.style.left !== '' && fab.style.right === 'auto', 'left=' + fab.style.left);
  check('拖动位置写入记忆', !!store['fab-pos'], store['fab-pos']);
  check('拖动不触发点击回调', clicked === 0, 'clicked=' + clicked);

  // 2. 点击（小位移）触发 onClick
  fab._handlers.mousedown[0]({ clientX: 505, clientY: 305, preventDefault() {} });
  fireDoc('mousemove', { clientX: 506, clientY: 306 });
  fireDoc('mouseup', {});
  check('点击触发 onClick', clicked === 1, 'clicked=' + clicked);

  // 3. 视口截断
  fab._handlers.mousedown[0]({ clientX: 505, clientY: 305, preventDefault() {} });
  fireDoc('mousemove', { clientX: -999, clientY: 99999 });
  fireDoc('mouseup', {});
  check('拖出视口被截断', parseInt(fab.style.left) >= 0 && parseInt(fab.style.top) <= 950, fab.style.left + ',' + fab.style.top);

  // 4. transform 清除（模拟 nav-rail 的 translateY(-50%)）
  const rail = makeEl('div');
  rail.style.position = 'fixed'; rail.style.right = '4px'; rail.style.top = '50%'; rail.style.transform = 'translateY(-50%)';
  html.documentElement.appendChild(rail);
  store['rail-pos'] = JSON.stringify({ left: '50px', top: '80px' });
  window.__zcodeMakeDraggable(rail, { storageKey: 'rail-pos', onClick: () => {} });
  check('恢复位置时清除 transform', rail.style.transform === 'none', rail.style.transform);
  check('恢复位置应用 left/top', rail.style.left === '50px' && rail.style.top === '80px', rail.style.left + ',' + rail.style.top);

  // 5. 幂等：重复注册不重复绑定
  const before = (fab._handlers.mousedown || []).length;
  window.__zcodeMakeDraggable(fab, { storageKey: 'fab-pos', onClick: () => {} });
  check('重复注册幂等', (fab._handlers.mousedown || []).length === before);

  console.log('\n' + (fail === 0 ? 'ALL PASS' : fail + ' FAILED') + ' (' + pass + ' passed)');
  process.exit(fail === 0 ? 0 : 1);
})();
