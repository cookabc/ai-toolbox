/* ===== ZCode 全量用量面板（CLI 层精确 token，跨会话/跨窗口/含后台） =====
   混合架构的「显示端」：fetch search-server 的 /usage 端点（http://127.0.0.1:7391/usage），
   由 usage-export.py 的 compute() 实时聚合 db.sqlite。与徽章三兄弟（DOM 估算）的本质
   区别：数据源是落库的精确计数——跨会话、跨窗口、含后台并行会话；input 含缓存读
   （≈97%），面板分项列出。徽章：📊 + 今日 output tok；点击展开（累计/今日/by-model/成本）。
   数据通道：最初是 fetch file://usage.json，但 ZCode 渲染层 webSecurity:true 会挡
   file:// fetch——故改走 http://localhost（search-server 已设 CORS 放行，与搜索同通道）。
   好处：实时（每次请求重算，不再只是会话启动时快照）。
   成本仅当 ~/.zcode/cli/usage-prices.json 自填单价后显示（库内无价目）。
   fetch 失败退化为「无数据」徽章，不影响其它模块；ZCODE_USAGE_URL 可覆盖（demo/测试）。 */
(function () {
  if (window.__zcodeUsagePanel) return;
  window.__zcodeUsagePanel = true;

  var POLL_MS = 30000;
  var LS_EXPAND = 'zcode-usage-expanded';
  // 默认走 search-server 的 /usage 端点（http://localhost）——ZCode 渲染层 webSecurity:true
  // 会挡 file:// fetch，但 CORS 放行的 http://localhost 可通（与搜索同一通道，已实测）。
  var DATA_URL = window.ZCODE_USAGE_URL || 'http://127.0.0.1:7391/usage';

  function fmtK(n) {
    if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
    if (n >= 1e3) return Math.round(n / 1e3) + 'k';
    return '' + Math.round(n || 0);
  }

  var expanded = false;
  try { expanded = window.localStorage && localStorage.getItem(LS_EXPAND) === '1'; } catch (e) {}

  var badge = document.createElement('div');
  badge.id = 'zcode-usage-badge';
  badge.title = '全量用量（精确计数 · 会话启动时快照）· 点击展开/收起';
  badge.style.cssText =
    'position:fixed;right:18px;top:140px;z-index:2147483000;' +
    'pointer-events:auto;cursor:pointer;user-select:none;-webkit-user-select:none;' +
    'display:flex;flex-direction:column;align-items:stretch;gap:6px;padding:7px 13px;border-radius:13px;' +
    'border:1px solid transparent;' +
    'background:linear-gradient(var(--zb-bg), var(--zb-bg)) padding-box,' +
    'linear-gradient(135deg, rgb(168 120 255 / 0.5), rgb(96 165 250 / 0.5)) border-box;' +
    'box-shadow:0 0 18px var(--zb-glow);' +
    'font-family:ui-monospace,Consolas,monospace;color:var(--zb-text);white-space:nowrap;' +
    'transition:box-shadow .3s ease;max-width:320px;';
  badge.innerHTML =
    '<span style="display:flex;align-items:center;gap:8px;">' +
      '<span style="font-size:12px;filter:drop-shadow(0 0 6px rgb(168 120 255 / .9))">📊</span>' +
      '<span id="zcode-usage-head" style="font-size:12.5px;font-weight:600;font-variant-numeric:tabular-nums;">用量</span>' +
      '<span id="zcode-usage-glyph" style="font-size:11px;opacity:.55;margin-left:auto;">+</span></span>' +
    '<span id="zcode-usage-body" style="display:none;font-size:10.5px;line-height:1.65;opacity:.92;white-space:pre;"></span>';
  document.documentElement.appendChild(badge);
  var elHead = badge.querySelector('#zcode-usage-head');
  var elBody = badge.querySelector('#zcode-usage-body');
  var elGlyph = badge.querySelector('#zcode-usage-glyph');
  if (!elHead || !elBody || !elGlyph) return;   // DOM 异常时安全退出，不阻断官方启动

  function applyLayout() {
    elBody.style.display = expanded ? '' : 'none';
    elGlyph.textContent = expanded ? '−' : '+';
    try { if (window.localStorage) localStorage.setItem(LS_EXPAND, expanded ? '1' : '0'); } catch (e) {}
  }
  applyLayout();
  if (badge.addEventListener) {
    badge.addEventListener('click', function () { expanded = !expanded; applyLayout(); render(); });
  }

  var lastData = null;
  function readData(cb) {
    // 显式注入点优先（测试桩 window.__zcodeUsageFetch），否则用全局 fetch（Electron 渲染层有）
    var f = window.__zcodeUsageFetch || ((typeof fetch === 'function') ? fetch : (window.fetch || null));
    if (!f) { cb(null); return; }
    f(DATA_URL, { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) { cb(j); })
      .catch(function () { cb(null); });
  }

  function costStr(d) {
    if (!d.prices) return '';
    var total = 0, any = false;
    for (var i = 0; i < (d.by_model || []).length; i++) {
      var m = d.by_model[i], p = d.prices[m.model_id];
      if (p && p.output) { total += (m.output_tokens || 0) / 1e6 * p.output; any = true; }
    }
    return any ? '估算成本(输出)  $' + total.toFixed(2) : '';
  }

  function render() {
    var d = lastData;
    if (!d) {
      elHead.textContent = '用量 · 无数据';
      elBody.textContent = 'usage.json 尚未生成\n（SessionStart hook 跑一次后出现）';
      return;
    }
    elHead.textContent = '今日 ' + fmtK(d.today.output_tokens) + ' out';
    if (!expanded) return;
    var t = d.totals, lines = [];
    lines.push('── 累计（' + t.turns + ' 回合 / ' + fmtK(t.requests) + ' 请求）──');
    lines.push('输出 ' + fmtK(t.output_tokens) + ' · 推理 ' + fmtK(t.reasoning_tokens));
    lines.push('输入 ' + fmtK(t.input_tokens) + '（缓存读 ' + fmtK(t.cache_read_input_tokens) + '）');
    lines.push('工具调用 ' + fmtK(t.tool_calls));
    lines.push('── 今日（' + d.today.turns + ' 回合）──');
    lines.push('输出 ' + fmtK(d.today.output_tokens) + ' · 输入 ' + fmtK(d.today.input_tokens));
    var bm = (d.by_model || []).slice(0, 4);
    if (bm.length) {
      lines.push('── 按模型（输出 tok）──');
      for (var i = 0; i < bm.length; i++) lines.push(bm[i].model_id + '  ' + fmtK(bm[i].output_tokens) + ' / ' + fmtK(bm[i].requests) + ' 次');
    }
    var c = costStr(d);
    if (c) lines.push(c);
    lines.push('快照 ' + new Date(d.generated_at).toLocaleTimeString());
    elBody.textContent = lines.join('\n');
  }

  function poll() {
    readData(function (d) {
      if (d) { lastData = d; render(); }
      else if (!lastData) render();   // 初次无数据也要画占位
    });
  }

  window.__zcodeUsagePoll = poll;   // 测试钩子：换 fetch 实现后手动触发（生产无副作用）
  setInterval(poll, POLL_MS);
  poll();
})();
