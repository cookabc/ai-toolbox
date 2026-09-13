/* ===== ZCode 代码块工具（hover 显示「存为文件」按钮，保存进下载目录） =====
   纯渲染层注入：每 2s 扫一遍 pre 元素，未加工的套上相对定位容器 + 悬浮按钮。
   点击把代码文本打成 Blob，经 a[download] 落进 Electron 默认下载目录（~/Downloads），
   文件名 zcode-snippet-N.扩展名（按 pre code 的 language- 或 hljs 类名猜，猜不到用 .txt）。
   与官方「复制」互补：复制进剪贴板，这里直接成文件，批量收代码片段不用逐个开编辑器。
   防重复：按钮挂在自建的包裹容器里（data-zcode-ca 标记），轮询幂等；
   React 重渲染把 pre 挪走/重建时，未加工的 pre 会被重新发现、重新包裹。 */
(function () {
  if (window.__zcodeCodeActions) return;
  window.__zcodeCodeActions = true;

  var SCAN_MS = 2000;
  var counter = 0;
  try { counter = parseInt(window.localStorage && localStorage.getItem('zcode-ca-seq'), 10) || 0; } catch (e) {}

  var EXT = {
    javascript: 'js', typescript: 'ts', jsx: 'jsx', tsx: 'tsx',
    python: 'py', py: 'py', bash: 'sh', shell: 'sh', sh: 'sh', zsh: 'sh',
    json: 'json', yaml: 'yaml', yml: 'yml', toml: 'toml', xml: 'xml', html: 'html',
    css: 'css', scss: 'scss', less: 'less', sql: 'sql', graphql: 'graphql',
    go: 'go', rust: 'rs', rs: 'rs', c: 'c', cpp: 'cpp', 'c++': 'cpp', h: 'h',
    java: 'java', kotlin: 'kt', swift: 'swift', ruby: 'rb', rb: 'rb', php: 'php',
    lua: 'lua', perl: 'pl', r: 'r', scala: 'scala', clojure: 'clj',
    dockerfile: 'Dockerfile', makefile: 'Makefile', markdown: 'md', md: 'md',
    diff: 'diff', ini: 'ini', csv: 'csv', vue: 'vue', svelte: 'svelte',
  };
  function extOf(pre) {
    var cls = '';
    var code = pre.querySelector('code');
    if (code) cls += ' ' + (code.className || '');
    cls += ' ' + (pre.className || '');
    var m = /(?:language-|lang-|hljs language-)([a-z0-9+#-]+)/i.exec(cls);
    if (!m) return 'txt';
    var lang = m[1].toLowerCase();
    return EXT[lang] || (lang.length <= 8 && /^[a-z0-9]+$/.test(lang) ? lang : 'txt');
  }

  var css = document.createElement('style');
  css.textContent =
    '.zcode-ca-wrap{position:relative;}' +
    '.zcode-ca-btn{position:absolute;top:8px;right:8px;z-index:5;' +
      'padding:4px 10px;border-radius:8px;border:1px solid rgb(96 165 250 / 0.35);' +
      'background:rgb(10 8 20 / 0.82);color:var(--zb-text-dim);font:11px/1.5 ui-monospace,Consolas,monospace;' +
      'cursor:pointer;opacity:0;transition:opacity .15s ease,background .15s ease;}' +
    '.zcode-ca-wrap:hover .zcode-ca-btn{opacity:1;}' +
    '.zcode-ca-btn:hover{background:rgb(30 40 70 / 0.92);color:#cfe2ff;}' +
    '.zcode-ca-btn.zcode-ca-done{border-color:rgb(52 211 153 / 0.5);color:#6ee7b7;}';
  document.documentElement.appendChild(css);

  function save(pre, btn) {
    var text = pre.innerText || pre.textContent || '';
    if (!text.trim()) return;
    var ext = extOf(pre);
    counter += 1;
    try { if (window.localStorage) localStorage.setItem('zcode-ca-seq', '' + counter); } catch (e) {}
    var name = ext === 'Dockerfile' || ext === 'Makefile'
      ? ext + '.' + counter
      : 'zcode-snippet-' + counter + '.' + ext;
    var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.documentElement.appendChild(a);
    a.click();
    if (a.parentNode) a.parentNode.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 5000);
    btn.textContent = '✓ ' + name;
    btn.classList.add('zcode-ca-done');
    setTimeout(function () { btn.textContent = '⬇ 存为文件'; btn.classList.remove('zcode-ca-done'); }, 2200);
  }

  function decorate(pre) {
    if (pre.classList && pre.classList.contains('zcode-ca-done-pre')) return;
    var wrap = document.createElement('div');
    wrap.className = 'zcode-ca-wrap';
    wrap.setAttribute('data-zcode-ca', '1');
    var parent = pre.parentNode;
    if (!parent) return;
    parent.insertBefore(wrap, pre);
    wrap.appendChild(pre);
    pre.classList.add('zcode-ca-done-pre');   // 已加工标记走 classList：重扫跳过，不靠 JS 属性（防克隆丢失）
    var btn = document.createElement('button');
    btn.className = 'zcode-ca-btn';
    btn.type = 'button';
    btn.textContent = '⬇ 存为文件';
    btn.addEventListener('click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      save(pre, btn);
    });
    wrap.appendChild(btn);
  }

  function scan() {
    if (!document.body) return;
    var pres = document.querySelectorAll('pre');
    for (var i = 0; i < pres.length; i++) {
      if (pres[i].closest && pres[i].closest('[data-zcode-ca]')) continue;   // 已在包裹容器内
      decorate(pres[i]);
    }
  }

  setInterval(scan, SCAN_MS);
  scan();
})();
