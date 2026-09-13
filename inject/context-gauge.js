/* ===== ZCode 上下文水位计（可见对话 token 估算，点击切换容量预设） =====
   纯渲染层注入：每 1.5s 对对话区做一次全量文本快照（innerText），按 CJK≈1 tok/字、
   英文≈4 字符/tok 折算当前对话规模，对照容量预设显示水位百分比与余量。
   与 TPS 计相反的方法论：TPS 看「流多快」（增量/速率），本模块看「缸多满」（存量/水位），
   因此不做增量去重、不做批次闸门——快照覆盖即真相，切会话、滚动卸载天然归零重计。
   数据边界：只能看到当前窗口渲染出的对话。虚拟滚动下读到的是「可见子集」，长会话读数
   偏乐观（标签注明 可见/EST）；system prompt、工具结果等未渲染内容本就不在 DOM 里。
   交互：常驻右上角（TPS 徽章左侧）；绿<60% / 黄 60~85% / 红≥85%（系统通知，
   每会话只提醒一次）；点击在 200k / 500k / 1M 容量预设间循环（localStorage 记忆）。 */
(function () {
  if (window.__zcodeCtxGauge) return;
  window.__zcodeCtxGauge = true;

  var SNAP_MS  = 1500;    // 快照周期（innerText 全量遍历非廉价，1.5s 足够灵敏）
  var NOTIFY_AT = 0.85;   // 红色档阈值，越过即弹一次系统通知
  var LS_KEY   = 'zcode-ctx-cap';
  var CAPS = [200000, 500000, 1000000];   // 点击循环的容量预设
  var CJK = /[\u2e80-\u9fff\uf900-\ufaff\u3000-\u303f\uff01-\uff60]/;

  function estTokens(s) {
    if (!s) return 0;
    var c = 0, n = 0;
    for (var j = 0; j < s.length; j++) { if (CJK.test(s.charAt(j))) c++; else n++; }
    return c + n / 4;
  }
  function fmtK(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(n % 1000000 ? 1 : 0) + 'M';
    if (n >= 1000) return Math.round(n / 1000) + 'k';
    return '' + Math.round(n);
  }

  /* ---------- 徽章 UI ---------- */
  var cap = CAPS[0];
  try {
    var saved = parseInt(window.localStorage && localStorage.getItem(LS_KEY), 10);
    if (CAPS.indexOf(saved) >= 0) cap = saved;
  } catch (e) {}

  var badge = document.createElement('div');
  badge.id = 'zcode-ctx-badge';
  badge.title = '上下文水位估算 (EST) · 当前窗口可见对话 / 容量 · 点击切换容量';
  badge.style.cssText =
    'position:fixed;right:18px;top:100px;z-index:2147483000;' +
    'pointer-events:auto;cursor:pointer;user-select:none;-webkit-user-select:none;' +
    'display:flex;align-items:center;gap:9px;padding:7px 13px;border-radius:13px;' +
    'border:1px solid transparent;' +
    'background:linear-gradient(var(--zb-bg), var(--zb-bg)) padding-box,' +
    'linear-gradient(135deg, rgb(52 211 153 / 0.55), rgb(64 153 255 / 0.55)) border-box;' +
    'box-shadow:0 0 18px rgb(52 211 153 / 0.18);' +
    'font-family:ui-monospace,Consolas,monospace;color:var(--zb-text);' +
    'transition:box-shadow .3s ease;white-space:nowrap;';
  badge.innerHTML =
    '<span id="zcode-ctx-dot" style="font-size:12px;filter:drop-shadow(0 0 6px rgb(52 211 153 / .9))">◍</span>' +
    '<span id="zcode-ctx-pct" style="font-size:17px;font-weight:700;line-height:1;min-width:44px;text-align:right;' +
      'font-variant-numeric:tabular-nums;color:#6ee7b7;">0%</span>' +
    '<span style="position:relative;width:52px;height:7px;border-radius:99px;background:rgb(255 255 255 / 0.08);overflow:hidden;">' +
      '<span id="zcode-ctx-bar" style="position:absolute;left:0;top:0;bottom:0;width:0%;border-radius:99px;' +
        'background:linear-gradient(90deg,#34d399,#60a5fa);transition:width .6s ease;"></span></span>' +
    '<span id="zcode-ctx-meta" style="font-size:10px;opacity:.78;line-height:1.45;text-align:left;">0 / 200k<br>可见 · EST</span>';
  document.documentElement.appendChild(badge);   // 同 TPS：挂根节点，游离于观察/统计范围之外
  var elPct = badge.querySelector('#zcode-ctx-pct');
  var elBar = badge.querySelector('#zcode-ctx-bar');
  var elDot = badge.querySelector('#zcode-ctx-dot');
  var elMeta = badge.querySelector('#zcode-ctx-meta');
  if (!elPct || !elBar || !elDot || !elMeta) return;   // DOM 异常时安全退出，绝不在启动路径上抛错

  /* 三档配色：绿（充足）→ 黄（过半）→ 红（该开新会话了） */
  var TIERS = {
    green:  { text: '#6ee7b7', bar: 'linear-gradient(90deg,#34d399,#60a5fa)', glow: 'rgb(52 211 153 / 0.18)',  dot: 'rgb(52 211 153 / .9)' },
    yellow: { text: '#fcd34d', bar: 'linear-gradient(90deg,#fbbf24,#fb923c)', glow: 'rgb(251 191 36 / 0.25)',  dot: 'rgb(251 191 36 / .9)' },
    red:    { text: '#fca5a5', bar: 'linear-gradient(90deg,#f87171,#ef4444)', glow: 'rgb(248 113 113 / 0.38)', dot: 'rgb(248 113 113 / .95)' },
  };
  function tier(pct) { return pct >= NOTIFY_AT ? TIERS.red : pct >= 0.6 ? TIERS.yellow : TIERS.green; }

  function cycleCap() {
    cap = CAPS[(CAPS.indexOf(cap) + 1) % CAPS.length];
    try { if (window.localStorage) localStorage.setItem(LS_KEY, '' + cap); } catch (e) {}
    snapshot();   // 立即按新容量重画，不等下个 tick
  }
  if (badge.addEventListener) {
    badge.addEventListener('click', cycleCap);
  }

  /* 快照排除自身与 TPS 徽章：双保险（挂根节点本就互不在子树内，防未来改挂载点） */
  function textOf(root) {
    return root.innerText || root.textContent || '';
  }

  var notified = false;   // 红色档系统通知每次会话只弹一次
  function maybeNotify(pct, tok) {
    if (notified || pct < NOTIFY_AT) return;
    notified = true;
    try {
      new Notification('上下文水位偏高', {
        body: '可见对话约 ' + fmtK(tok) + ' tok（' + Math.round(pct * 100) + '% of ' + fmtK(cap) + '），建议开新会话或压缩上下文',
      });
    } catch (e) {}
  }

  function snapshot() {
    if (!document.body) return;
    var raw = textOf(document.body);
    var tok = Math.round(estTokens(raw));
    var pct = tok / cap;
    var c = tier(pct);
    elPct.textContent = Math.round(pct * 100) + '%';
    elPct.style.color = c.text;
    elBar.style.width = Math.min(100, pct * 100) + '%';
    elBar.style.background = c.bar;
    elDot.style.filter = 'drop-shadow(0 0 6px ' + c.dot + ')';
    badge.style.boxShadow = '0 0 18px ' + c.glow;
    elMeta.innerHTML = fmtK(tok) + ' / ' + fmtK(cap) + '<br>可见 · EST';
    maybeNotify(pct, tok);
    if (window.__zcodeCtxDebug) window.__zcodeCtxDebug.last = { raw: raw.length, tok: tok, pct: pct };
  }

  setInterval(snapshot, SNAP_MS);
  snapshot();
})();
