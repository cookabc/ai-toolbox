// 徽章主题单元测试：DOM 桩跑 inject/badge-theme.js
// 验证按 dark-mode/light-mode 写 --zb-* 变量、主题类切换触发重应用、__zcodeSetTheme 覆盖
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

function makeClassList(el) {
  const set = new Set();
  return {
    add(...cs) { cs.forEach(c => set.add(c)); el.__classes = [...set]; },
    remove(...cs) { cs.forEach(c => set.delete(c)); el.__classes = [...set]; },
    contains(c) { return set.has(c); },
  };
}
const docEl = {
  style: { _props: {}, setProperty(k, v) { this._props[k] = v; } },
  _attrs: {},
  setAttribute(k, v) { this._attrs[k] = v; },
  classList: null,
  children: [],
};
docEl.classList = makeClassList(docEl);

let moCb = null;
global.MutationObserver = class { constructor(cb) { moCb = cb; } observe() {} };
global.document = { documentElement: docEl, createElement: () => ({ style: {} }) };
const store = {};
global.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
global.window = { localStorage: global.localStorage };

const code = fs.readFileSync(path.join(__dirname, '..', 'inject', 'badge-theme.js'), 'utf-8');
vm.runInThisContext(code, { filename: 'badge-theme.js' });

let pass = 0, fail = 0;
function check(name, cond, detail) {
  cond ? pass++ : fail++;
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (detail !== undefined ? '  [' + detail + ']' : ''));
}

const T = window.__zcodeBadgeThemeTest;

(async () => {
  // 1. 默认（无主题类）按深色
  check('默认按深色', T.currentMode() === 'dark', T.currentMode());
  check('深色变量已写入 --zb-bg', /10 8 20/.test(docEl.style._props['--zb-bg'] || ''), docEl.style._props['--zb-bg']);
  check('深色文字 --zb-text', docEl.style._props['--zb-text'] === '#dbe4ff', docEl.style._props['--zb-text']);
  check('data-zb-theme=dark', docEl._attrs['data-zb-theme'] === 'dark');

  // 2. 切到 light-mode 类 → 变量变浅
  docEl.classList.add('light-mode');
  if (moCb) moCb([{ attributeName: 'class' }]);
  check('light-mode 类切到浅色', T.currentMode() === 'light');
  check('浅色变量 --zb-bg 变白', /255 255 255/.test(docEl.style._props['--zb-bg'] || ''), docEl.style._props['--zb-bg']);
  check('浅色文字 --zb-text 变深', docEl.style._props['--zb-text'] === '#1e2a4a', docEl.style._props['--zb-text']);
  check('data-zb-theme=light', docEl._attrs['data-zb-theme'] === 'light');

  // 3. 切回 dark-mode → 变量回深
  docEl.classList.remove('light-mode');
  docEl.classList.add('dark-mode');
  if (moCb) moCb([{ attributeName: 'class' }]);
  check('切回深色', T.currentMode() === 'dark' && /10 8 20/.test(docEl.style._props['--zb-bg']));

  // 4. __zcodeSetTheme('light')：写 localStorage + 切类 + 应用
  window.__zcodeSetTheme('light');
  check('__zcodeSetTheme 写 localStorage theme=light', store['theme'] === 'light', store['theme']);
  check('__zcodeSetTheme 切类到 light-mode', docEl.classList.contains('light-mode') && !docEl.classList.contains('dark-mode'));
  check('__zcodeSetTheme 应用浅色变量', /255 255 255/.test(docEl.style._props['--zb-bg']));

  // 5. __zcodeSetTheme('dark') 切回
  window.__zcodeSetTheme('dark');
  check('切回 dark', store['theme'] === 'dark' && docEl.classList.contains('dark-mode') && /10 8 20/.test(docEl.style._props['--zb-bg']));

  // 6. 非法值回退 dark
  window.__zcodeSetTheme('banana');
  check('非法主题值回退 dark', store['theme'] === 'dark' && docEl.classList.contains('dark-mode'));

  // 7. 变量完整性：深浅两套都覆盖徽章用到的关键变量
  const need = ['--zb-bg', '--zb-text', '--zb-text-dim', '--zb-border-a', '--zb-border-b', '--zb-glow', '--zb-overlay', '--zb-row-hover', '--zb-mark'];
  check('深浅两套变量键齐全', need.every(k => k in T.THEMES.dark && k in T.THEMES.light));

  console.log('\n' + (fail === 0 ? 'ALL PASS' : fail + ' FAILED') + ' (' + pass + ' passed)');
  process.exit(fail === 0 ? 0 : 1);
})();
