// 代码块工具单元测试：最小 DOM 桩跑 inject/code-actions.js
// 验证 pre 包裹幂等、扩展名映射、点击保存走 a[download]、计数器推进
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

/* ---------- DOM 桩（支持 classList/insertBefore/removeChild/closest/createElement(a|style)） ---------- */
let idSeq = 0;
function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(), nodeType: 1, children: [], style: {}, _attrs: {},
    _handlers: {}, _id: ++idSeq,
    className: '', parentNode: null, data: undefined, href: '', download: '',
    classList: {
      _s: new Set(),
      add(c) { this._s.add(c); el.className = [...this._s].join(' '); },
      remove(c) { this._s.delete(c); el.className = [...this._s].join(' '); },
      contains(c) { return this._s.has(c); },
    },
    setAttribute(k, v) { this._attrs[k] = v; },
    getAttribute(k) { return (k in this._attrs) ? this._attrs[k] : null; },
    appendChild(c) { if (c.parentNode) c.parentNode.removeChild(c); this.children.push(c); c.parentNode = this; return c; },
    insertBefore(c, ref) {
      if (c.parentNode) c.parentNode.removeChild(c);
      const i = this.children.indexOf(ref);
      if (i < 0) this.children.push(c); else this.children.splice(i, 0, c);
      c.parentNode = this; return c;
    },
    removeChild(c) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; },
    addEventListener(ev, fn) { (this._handlers[ev] = this._handlers[ev] || []).push(fn); },
    click() { global.__clicks.push(this); (this._handlers.click || []).forEach((fn) => fn({ preventDefault() {}, stopPropagation() {} })); },
    closest(sel) {   // 仅支持 '[data-zcode-ca]'
      let n = this;
      while (n) { if (n._attrs && 'data-zcode-ca' in n._attrs) return n; n = n.parentNode; }
      return null;
    },
    querySelector(sel) {
      const want = sel.replace('#', '');
      const walk = (n) => { for (const c of n.children) { if (c._attrs.id === want || c.tagName === sel.toUpperCase()) return c; const r = walk(c); if (r) return r; } return null; };
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
  el.innerText = '';
  return el;
}

const allEls = [];
const origCreate = (t) => { const el = makeEl(t); allEls.push(el); return el; };
const html = global.document = {
  createElement: origCreate,
  documentElement: makeEl('html'),
  body: makeEl('body'),
  querySelectorAll(sel) {   // 仅支持 'pre'
    if (sel !== 'pre') return [];
    const out = [];
    const walk = (n) => { for (const c of n.children) { if (c.tagName === 'PRE') out.push(c); walk(c); } };
    walk(html.body); walk(html.documentElement);
    return out;
  },
};
global.window = {};
global.__clicks = [];
global.__blobs = [];
global.Blob = class { constructor(parts, opts) { this.parts = parts; this.opts = opts; global.__blobs.push(this); } };
global.__urls = [];
global.URL = { createObjectURL(b) { const u = 'blob:mock-' + global.__urls.length; global.__urls.push({ url: u, blob: b }); return u; }, revokeObjectURL() {} };

/* ---------- 载入脚本 ---------- */
const code = fs.readFileSync(path.join(__dirname, '..', 'inject', 'code-actions.js'), 'utf-8');
vm.runInThisContext(code, { filename: 'code-actions.js' });

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
let pass = 0, fail = 0;
function check(name, cond, detail) {
  cond ? pass++ : fail++;
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (detail !== undefined ? '  [' + detail + ']' : ''));
}

(async () => {
  // 页面里放两个 pre：一个 python（带 code.language-python）、一个裸 pre
  const chat = makeEl('main'); html.body.appendChild(chat);
  const pre1 = makeEl('pre');
  const code1 = makeEl('code'); code1.classList.add('language-python'); code1.textContent = 'print("hello")';
  pre1.appendChild(code1); pre1.innerText = 'print("hello")';
  chat.appendChild(pre1);
  const pre2 = makeEl('pre'); pre2.innerText = 'npm install -g something';
  chat.appendChild(pre2);

  await sleep(2100);

  // 1. 两个 pre 都被包裹（parent 变成 .zcode-ca-wrap 容器）
  check('pre1 被包裹', pre1.parentNode && pre1.parentNode._attrs['data-zcode-ca'] === '1');
  check('pre2 被包裹', pre2.parentNode && pre2.parentNode._attrs['data-zcode-ca'] === '1');
  const wrap1 = pre1.parentNode;
  const btn1 = wrap1.children.find(c => c.tagName === 'BUTTON');
  check('包裹容器里有按钮', !!btn1 && btn1.textContent === '⬇ 存为文件', btn1 && btn1.textContent);

  // 2. 幂等：再过一轮不重复包裹
  const wrapsBefore = document.querySelectorAll('pre').length;
  await sleep(2100);
  check('重扫不重复包裹', pre1.parentNode === wrap1 && document.querySelectorAll('pre').length === wrapsBefore);

  // 3. 点击 pre1 按钮 → 存 zcode-snippet-1.py，Blob 内容正确
  btn1.click();
  const a1 = global.__clicks[global.__clicks.length - 1];
  check('点击生成 python 文件名', a1 && a1.download === 'zcode-snippet-1.py', a1 && a1.download);
  check('Blob 内容是 pre 文本', global.__blobs.length === 1 && global.__blobs[0].parts[0] === 'print("hello")');

  // 4. 点击 pre2 按钮 → 裸 pre 猜不到语言用 .txt，计数器推进到 2
  const btn2 = pre2.parentNode.children.find(c => c.tagName === 'BUTTON');
  btn2.click();
  const a2 = global.__clicks[global.__clicks.length - 1];
  check('裸 pre 用 .txt', a2 && a2.download === 'zcode-snippet-2.txt', a2 && a2.download);

  // 5. 反馈态：按钮短暂变成 ✓ 文件名
  check('按钮给出完成反馈', /✓ zcode-snippet-2\.txt/.test(btn2.textContent), btn2.textContent);
  await sleep(2300);
  check('反馈后按钮还原', btn2.textContent === '⬇ 存为文件', btn2.textContent);

  // 6. 新插入的 pre 被下一轮扫描发现
  const pre3 = makeEl('pre');
  const code3 = makeEl('code'); code3.classList.add('language-typescript'); code3.textContent = 'const x: number = 1;';
  pre3.appendChild(code3); pre3.innerText = 'const x: number = 1;';
  chat.appendChild(pre3);
  await sleep(2100);
  check('新 pre 被自动包裹', pre3.parentNode && pre3.parentNode._attrs['data-zcode-ca'] === '1');
  const btn3 = pre3.parentNode.children.find(c => c.tagName === 'BUTTON');
  btn3.click();
  const a3 = global.__clicks[global.__clicks.length - 1];
  check('ts 映射到 .ts 且序号=3', a3 && a3.download === 'zcode-snippet-3.ts', a3 && a3.download);

  console.log('\n' + (fail === 0 ? 'ALL PASS' : fail + ' FAILED') + ' (' + pass + ' passed)');
  process.exit(fail === 0 ? 0 : 1);
})();
