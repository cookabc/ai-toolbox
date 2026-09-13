// 消息锚点导航单元测试：最小 DOM 桩跑 inject/nav-dots.js
// 验证滚动容器探测、指纹→锚点、退化 5 点、点击按比例滚动、收起/展开
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(), nodeType: 1, children: [], style: {}, _attrs: {},
    _handlers: {}, className: '', parentNode: null, title: '',
    scrollHeight: 0, clientHeight: 0, scrollTop: 0,
    setAttribute(k, v) { this._attrs[k] = v; },
    appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; },
    removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; },
    addEventListener(ev, fn) { (this._handlers[ev] = this._handlers[ev] || []).push(fn); },
    click() { (this._handlers.click || []).forEach((fn) => fn()); },
    querySelector(sel) {
      const want = sel.replace('#', '');
      const walk = (n) => { for (const c of n.children) { if (c._attrs.id === want) return c; const r = walk(c); if (r) return r; } return null; };
      return walk(this);
    },
  };
  Object.defineProperty(el, 'firstChild', { get() { return this.children[0] || null; } });
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html || ''; },
    set(h) {
      this._html = String(h);
      for (const m of this._html.matchAll(/id="([^"]+)"/g)) {
        const c = makeEl('span'); c._attrs.id = m[1]; this.appendChild(c);
      }
    },
  });
  Object.defineProperty(el, 'innerText', {
    get() { return this._text || ''; },
    set(v) { this._text = String(v); },
  });
  return el;
}

/* 假对话容器：scrollHeight 10000 / clientHeight 1000，24 条用户消息。
   firstHeadingText 依赖 getBoundingClientRect + class*=user，这里用全局钩子模拟：
   容器 scrollTop 改变时，把「当前应可见的消息文本」挂到全局。 */
const chat = makeEl('main');
chat.className = 'chat-area';
chat.scrollHeight = 10000; chat.clientHeight = 1000;
global.__visibleText = '';

const html = global.document = {
  createElement: (t) => makeEl(t),
  documentElement: makeEl('html'),
  body: makeEl('body'),
  querySelectorAll(sel) {
    const out = [];
    // firstHeadingText 探针（选择器含 user/turn/human 且不含 scroll/chat/conversation）：
    // 返回一个伪「当前可见回合」元素，文本由 onscroll 钩子随滚动位置更新
    const isProbe = /user|turn|human/.test(sel) || (/message/.test(sel) && !/scroll|chat|conversation/.test(sel));
    if (isProbe) {
      const probe = makeEl('div');
      probe.className = 'msg-user';
      probe.getBoundingClientRect = () => ({ top: 100, height: 50 });
      probe.innerText = global.__visibleText;
      return [probe];
    }
    const walk = (n) => {
      for (const c of n.children) {
        if ((sel === 'main' && c.tagName === 'MAIN') || /chat|scroll|message|conversation/.test(sel) && /chat/.test(c.className || '')) out.push(c);
        walk(c);
      }
    };
    walk(html.body); walk(html.documentElement);
    return out;
  },
};
html.documentElement.scrollHeight = 100;   // window 本身不可滚 → 必须选中 chat
global.window = {
  innerHeight: 1000, pageYOffset: 0, scrolls: [],
  scrollTo(x, y) { this.scrolls.push(y); },
  addEventListener() {},
};
html.body.appendChild(chat);

/* 拦截 scrollTop 赋值：指纹采样滚动时同步更新「可见文本」 */
let realTop = 0;
chat.onscroll = () => {
  const idx = Math.min(23, Math.round(realTop / 9000 * 23));
  global.__visibleText = '第' + idx + '轮：请帮我实现功能' + idx;
};
Object.defineProperty(chat, 'scrollTop', {
  get() { return realTop; },
  set(v) { realTop = v; },
});

const code = fs.readFileSync(path.join(__dirname, '..', 'inject', 'nav-dots.js'), 'utf-8');
vm.runInThisContext(code, { filename: 'nav-dots.js' });

const rail = html.documentElement.children[0];
const dotsBox = rail.querySelector('#zcode-nav-dots');
const toggle = rail.querySelector('#zcode-nav-toggle');
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
function check(name, cond, detail) {
  cond ? pass++ : fail++;
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (detail !== undefined ? '  [' + detail + ']' : ''));
}

(async () => {
  check('轨道已挂载', !!rail && !!dotsBox && !!toggle);

  await sleep(1700);   // 首次 rebuild 在 1.5s
  const n1 = dotsBox.children.length;
  check('指纹采样产生多个锚点', n1 >= 5, 'dots=' + n1);
  check('锚点数不超过上限 30', n1 <= 30, 'dots=' + n1);
  const withTitle = dotsBox.children.filter(d => d.title).length;
  check('锚点带有回合标签', withTitle > 0, 'titled=' + withTitle + '/' + n1);

  // 点击中间的点 → chat.scrollTop 按比例移动
  const mid = dotsBox.children[Math.floor(n1 / 2)];
  realTop = 0;
  mid.click();
  check('点击锚点按指纹比例滚动', realTop > 1000 && realTop < 8000, 'scrollTop=' + realTop);

  // 点击第一个点 → 滚回顶部附近
  dotsBox.children[0].click();
  check('点击首点回顶部', realTop <= 1000, 'scrollTop=' + realTop);

  // 采样后必须复位：rebuild 结束时 scrollTop 应回到采样前的值（0）
  realTop = 1234;
  await sleep(2700);   // 下一轮 rebuild（2.5s 周期）
  check('采样后滚动位置复位', realTop === 1234, 'scrollTop=' + realTop);

  // 收起/展开
  toggle.click();
  check('收起后点列表隐藏', dotsBox.style.display === 'none');
  toggle.click();
  check('展开后点列表恢复', dotsBox.style.display === 'flex');

  // 退化路径：可见文本恒相同 → 指纹失败 → 均匀 5 点
  chat.onscroll = () => { global.__visibleText = '同样的文本'; };
  await sleep(2700);
  check('指纹失败退化为均匀 5 点', dotsBox.children.length === 5, 'dots=' + dotsBox.children.length);

  console.log('\n' + (fail === 0 ? 'ALL PASS' : fail + ' FAILED') + ' (' + pass + ' passed)');
  process.exit(fail === 0 ? 0 : 1);
})();
