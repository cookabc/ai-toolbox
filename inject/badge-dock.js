/* ===== ZCode 徽章边栏（右缘竖排图标列 · 数据源来自三个隐藏徽章） =====
   设计：tps/context-gauge/usage-panel 三个脚本照常运行它们的计量逻辑并更新各自 DOM，
   但不直接展示——本边栏把它们的原始徽章隐藏（display:none），从 DOM 里读出关键数字，
   渲染成贴右缘的一条竖向 dock：每项一个小图标 + 大号数字 + 小标签。
   交互：
     - hover 某项 → 左侧弹出该项详情（TPS 累计/峰值、水位进度、用量明细）；
     - 顶部把手 ⋮⋮：点击收起成单圆钮、按住拖动整条边栏（localStorage 记忆位置）；
     - 底部 🌙/☀️：切换 light/dark（同 badge-theme）。
   比「三徽章堆叠/融合面板」更省地、不挡正文：默认只占右缘 ~64px 宽。 */
(function () {
  if (window.__zcodeBadgeDock) return;
  window.__zcodeBadgeDock = true;

  var LS_COLLAPSE = 'zcode-dock-collapsed';
  var LS_POS = 'zcode-dock-pos';

  /* ---------- 三个徽章的数据适配：从隐藏 DOM 读数 ---------- */
  var SOURCES = [
    {
      id: 'zcode-tps-badge', icon: '⚡', label: 'tok/s',
      value: function (el) { return txt(el, '#zcode-tps-rate'); },
      detail: function (el) {
        return '输出速率 ' + txt(el, '#zcode-tps-rate') + ' tok/s\n' +
               txt(el, '#zcode-tps-meta').replace(/<br\s*\/?>/gi, '\n');
      },
    },
    {
      id: 'zcode-ctx-badge', icon: '◍', label: '上下文',
      value: function (el) { return txt(el, '#zcode-ctx-pct'); },
      detail: function (el) {
        return '上下文水位 ' + txt(el, '#zcode-ctx-pct') + '\n' +
               txt(el, '#zcode-ctx-meta').replace(/<br\s*\/?>/gi, '\n');
      },
    },
    {
      id: 'zcode-usage-badge', icon: '📊', label: '今日',
      value: function (el) { return txt(el, '#zcode-usage-head').replace(/^今日\s*/, '').replace(/\s*out\s*$/, ''); },
      detail: function (el) { return txt(el, '#zcode-usage-body'); },
    },
  ];
  function txt(root, sel) {
    var n = root && root.querySelector ? root.querySelector(sel) : null;
    return n ? (n.textContent || '').trim() : '';
  }

  /* ---------- 边栏容器 ---------- */
  var dock = document.createElement('div');
  dock.id = 'zcode-badge-dock';
  dock.style.cssText =
    'position:fixed;right:10px;top:50%;transform:translateY(-50%);z-index:2147483000;' +
    'display:flex;flex-direction:column;align-items:center;gap:2px;' +
    'pointer-events:none;font-family:ui-monospace,Consolas,monospace;';
  document.documentElement.appendChild(dock);

  var rail = document.createElement('div');   // 图标列主体
  rail.id = 'zcode-dock-rail';
  rail.style.cssText =
    'display:flex;flex-direction:column;align-items:stretch;gap:2px;' +
    'border-radius:16px;padding:8px 6px;pointer-events:auto;' +
    'border:1px solid transparent;' +
    'background:linear-gradient(var(--zb-bg), var(--zb-bg)) padding-box,' +
    'linear-gradient(180deg, var(--zb-border-a), var(--zb-border-b)) border-box;' +
    'box-shadow:0 0 20px var(--zb-glow);';

  /* ---------- 每项（图标 + 数字 + 标签） ---------- */
  var items = [];
  SOURCES.forEach(function (src, i) {
    var cell = document.createElement('div');
    cell.className = 'zcode-dock-cell';
    cell.style.cssText =
      'position:relative;display:flex;flex-direction:column;align-items:center;gap:1px;' +
      'padding:7px 6px;border-radius:11px;cursor:default;pointer-events:auto;' +
      'transition:background .15s ease;min-width:52px;';
    cell.innerHTML =
      '<span class="zb-icon" style="font-size:15px;line-height:1;filter:drop-shadow(0 0 5px var(--zb-glow))">' + src.icon + '</span>' +
      '<span class="zb-val" style="font-size:13px;font-weight:700;font-variant-numeric:tabular-nums;color:var(--zb-text);line-height:1.2;">·</span>' +
      '<span class="zb-label" style="font-size:8.5px;color:var(--zb-text-dim);line-height:1;">' + src.label + '</span>';
    cell.addEventListener('mouseenter', function () { cell.style.background = 'var(--zb-row-hover)'; showDetail(i, cell); });
    cell.addEventListener('mouseleave', function () { cell.style.background = 'transparent'; hideDetail(); });
    rail.appendChild(cell);
    items.push({ src: src, cell: cell, valEl: cell.querySelector('.zb-val') });
  });

  /* ---------- 详情弹出（左侧 tooltip） ---------- */
  var tip = document.createElement('div');
  tip.id = 'zcode-dock-tip';
  tip.style.cssText =
    'position:fixed;z-index:2147483200;display:none;pointer-events:none;' +
    'max-width:300px;padding:11px 13px;border-radius:12px;white-space:pre-wrap;' +
    'font-size:11px;line-height:1.6;color:var(--zb-text);' +
    'background:linear-gradient(var(--zb-bg), var(--zb-bg)) padding-box,' +
    'linear-gradient(135deg, var(--zb-border-a), var(--zb-border-b)) border-box;' +
    'border:1px solid transparent;box-shadow:0 8px 30px rgb(0 0 0 / 0.35), 0 0 18px var(--zb-glow);';
  document.documentElement.appendChild(tip);
  var tipFor = -1;
  function showDetail(i, cell) {
    var src = items[i].src;
    var hidden = document.getElementById(src.id);
    if (!hidden) return;
    tipFor = i;
    tip.textContent = src.detail(hidden) || src.label;
    tip.style.display = 'block';
    var r = cell.getBoundingClientRect();
    var x = r.left - tip.offsetWidth - 12;
    var y = r.top + r.height / 2 - tip.offsetHeight / 2;
    y = Math.max(8, Math.min((window.innerHeight || 800) - tip.offsetHeight - 8, y));
    tip.style.left = Math.max(8, x) + 'px';
    tip.style.top = y + 'px';
  }
  function hideDetail() { tipFor = -1; tip.style.display = 'none'; }

  /* ---------- 收养并隐藏原始徽章，从 DOM 读数刷新边栏 ---------- */
  var adopted = {};
  function sweep() {
    SOURCES.forEach(function (src) {
      var el = document.getElementById(src.id);
      if (el && !adopted[src.id]) {
        adopted[src.id] = true;
        el.style.display = 'none';   // 逻辑照跑，视觉隐藏
      }
    });
    // 刷新数字
    items.forEach(function (it) {
      var el = adopted[it.src.id] ? document.getElementById(it.src.id) : null;
      var v = el ? it.src.value(el) : '';
      if (v) it.valEl.textContent = v;
    });
    // 若 tooltip 正开着，跟着刷新
    if (tipFor >= 0) showDetail(tipFor, items[tipFor].cell);
  }

  /* ---------- 把手（收起/拖动） ---------- */
  var handle = document.createElement('div');
  handle.id = 'zcode-dock-handle';
  handle.title = '点击收起 · 按住拖动';
  handle.style.cssText =
    'cursor:grab;pointer-events:auto;user-select:none;-webkit-user-select:none;' +
    'width:30px;height:15px;display:flex;align-items:center;justify-content:center;' +
    'font-size:10px;color:var(--zb-text-dim);opacity:0.4;transition:opacity .2s ease;touch-action:none;';
  handle.textContent = '⋮⋮';
  handle.addEventListener('mouseenter', function () { handle.style.opacity = '0.9'; });
  handle.addEventListener('mouseleave', function () { handle.style.opacity = '0.4'; });

  /* ---------- 收起/展开 ---------- */
  var collapsed = false;
  try { collapsed = window.localStorage && localStorage.getItem(LS_COLLAPSE) === '1'; } catch (e) {}
  var fab = document.createElement('div');
  fab.id = 'zcode-dock-fab';
  fab.title = '展开边栏';
  fab.style.cssText =
    'display:none;cursor:pointer;pointer-events:auto;user-select:none;-webkit-user-select:none;' +
    'width:32px;height:32px;border-radius:99px;align-items:center;justify-content:center;' +
    'font-size:13px;color:var(--zb-text);' +
    'background:linear-gradient(var(--zb-bg), var(--zb-bg)) padding-box,' +
    'linear-gradient(135deg, var(--zb-border-a), var(--zb-border-b)) border-box;' +
    'border:1px solid transparent;box-shadow:0 0 14px var(--zb-glow);';
  fab.textContent = '◧';
  function applyCollapsed() {
    rail.style.display = collapsed ? 'none' : 'flex';
    handle.style.display = collapsed ? 'none' : 'flex';
    themeBtn.style.display = collapsed ? 'none' : 'flex';
    fab.style.display = collapsed ? 'flex' : 'none';
    try { if (window.localStorage) localStorage.setItem(LS_COLLAPSE, collapsed ? '1' : '0'); } catch (e) {}
  }

  /* ---------- 主题钮 ---------- */
  var themeBtn = document.createElement('div');
  themeBtn.id = 'zcode-theme-toggle';
  themeBtn.title = '切换浅色/深色';
  themeBtn.style.cssText =
    'cursor:pointer;pointer-events:auto;user-select:none;-webkit-user-select:none;' +
    'width:30px;height:30px;border-radius:99px;display:flex;align-items:center;justify-content:center;' +
    'font-size:13px;color:var(--zb-text);opacity:0.55;transition:opacity .2s ease;margin-top:2px;';
  themeBtn.addEventListener('mouseenter', function () { themeBtn.style.opacity = '0.95'; });
  themeBtn.addEventListener('mouseleave', function () { themeBtn.style.opacity = '0.55'; });
  /* 主题读取/切换：优先用 badge-theme 的 __zcodeTheme/__zcodeSetTheme；
     若 badge-theme 没跑成功（undefined），这里兜底实现一份等价的，保证主题钮永远可用。 */
  function getThemeMode() {
    if (typeof window.__zcodeTheme === 'function') return window.__zcodeTheme();
    var de = document.documentElement;
    return (de.classList && de.classList.contains('light-mode')) ? 'light' : 'dark';
  }
  function setThemeMode(mode) {
    if (typeof window.__zcodeSetTheme === 'function') { window.__zcodeSetTheme(mode); return; }
    var de = document.documentElement;
    try { if (window.localStorage) localStorage.setItem('theme', mode); } catch (e) {}
    if (de.classList) { de.classList.remove('dark-mode', 'light-mode'); de.classList.add(mode + '-mode'); }
  }
  function renderThemeBtn() {
    themeBtn.textContent = getThemeMode() === 'dark' ? '🌙' : '☀️';
  }
  function flipTheme() {
    setThemeMode(getThemeMode() === 'dark' ? 'light' : 'dark');
    setTimeout(renderThemeBtn, 30);
  }
  renderThemeBtn();
  if (themeBtn.addEventListener) themeBtn.addEventListener('click', flipTheme);

  /* ---------- 通用拖拽助手（供自身 + nav-dots 复用） ----------
     总是用本文件的版本（最完整：4px 阈值/位置记忆/视口截断/清 transform），
     不被先加载的旧版或 nav-dots 抢先定义。 */
  window.__zcodeMakeDraggable = function (el, opts) {
    if (!el || el.__zcodeDraggable) return;
    el.__zcodeDraggable = true;
    var key = opts.storageKey, grip = opts.handleEl || el, drag = null;
    function save(l, t) { try { if (window.localStorage) localStorage.setItem(key, JSON.stringify({ left: l, top: t })); } catch (e) {} }
    (function restore() {
      try {
        var raw = window.localStorage && localStorage.getItem(key); if (!raw) return;
        var p = JSON.parse(raw);
        if (p && p.left && p.top) {
          el.style.right = 'auto'; el.style.bottom = 'auto'; el.style.transform = 'none';
          el.style.left = p.left; el.style.top = p.top;
        }
      } catch (e) {}
    })();
    function down(e) {
      var pt = e.touches ? e.touches[0] : e;
      var r = el.getBoundingClientRect();
      drag = { dx: pt.clientX - r.left, dy: pt.clientY - r.top, moved: false, sx: pt.clientX, sy: pt.clientY };
      if (e.preventDefault && e.type === 'touchstart') e.preventDefault();
    }
    function move(e) {
      if (!drag) return;
      var pt = e.touches ? e.touches[0] : e;
      if (!drag.moved && Math.abs(pt.clientX - drag.sx) < 4 && Math.abs(pt.clientY - drag.sy) < 4) return;
      drag.moved = true;
      var x = pt.clientX - drag.dx, y = pt.clientY - drag.dy;
      var mx = (window.innerWidth || 1200) - (el.offsetWidth || 40), my = (window.innerHeight || 800) - (el.offsetHeight || 40);
      el.style.right = 'auto'; el.style.bottom = 'auto'; el.style.transform = 'none';
      el.style.left = Math.max(0, Math.min(mx, x)) + 'px';
      el.style.top = Math.max(0, Math.min(my, y)) + 'px';
    }
    function up() {
      if (!drag) return;
      if (drag.moved) save(el.style.left, el.style.top);
      else if (opts.onClick) opts.onClick();
      drag = null;
    }
    if (grip.addEventListener) { grip.addEventListener('mousedown', down); grip.addEventListener('touchstart', down, { passive: false }); }
    if (typeof document !== 'undefined' && document.addEventListener) {
      document.addEventListener('mousemove', move); document.addEventListener('mouseup', up);
      document.addEventListener('touchmove', move, { passive: false }); document.addEventListener('touchend', up);
    }
  };
  window.__zcodeMakeDraggable(dock, {
    storageKey: LS_POS, handleEl: handle,
    onClick: function () { collapsed = !collapsed; applyCollapsed(); },
  });
  if (fab.addEventListener) fab.addEventListener('click', function () { collapsed = false; applyCollapsed(); });

  /* ---------- 组装 ---------- */
  dock.appendChild(handle);
  dock.appendChild(rail);
  dock.appendChild(themeBtn);
  dock.appendChild(fab);
  applyCollapsed();

  sweep();
  if (typeof MutationObserver === 'function' && document.documentElement) {
    var mo = new MutationObserver(function () { sweep(); });
    mo.observe(document.documentElement, { childList: true, subtree: true });
  }
  var iv = setInterval(sweep, 500);   // 数字刷新（从隐藏 DOM 读）

  window.__zcodeDockTest = { dock: dock, rail: rail, handle: handle, fab: fab, items: items, tip: tip,
    setCollapsed: function (v) { collapsed = v; applyCollapsed(); },
    isCollapsed: function () { return collapsed; }, sweep: sweep, adopted: adopted };
})();
