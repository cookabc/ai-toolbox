/* ===== ZCode 输出速率计（tokens/s 实时徽章） =====
   纯渲染层注入：MutationObserver 监听聊天区文本增量 → CJK/EN 混合启发式折算 token
   → 4s 滑动窗口速率 + 迷你曲线 + 本回合总量/峰值。流式时点亮，空闲淡出。 */
(function () {
  if (window.__zcodeTps) return;
  window.__zcodeTps = true;

  var RATE_WINDOW = 4000;   // 瞬时速率滑动窗口 ms
  var IDLE_END    = 4000;   // 多久无增长判定回合结束 ms
  var TICK        = 150;    // 采样/渲染周期 ms
  var HISTORY     = 200;    // 曲线历史点数 (30s)
  var FADE_AFTER  = 6000;   // 回合结束后保留 ms 再淡出
  var BATCH_MAX   = 100;    // 单批次净增量上限：超过视为加载历史（滚动挂载/切会话），忽略
  var CJK = /[\u2e80-\u9fff\uf900-\ufaff\u3000-\u303f\uff01-\uff60]/;

  function estTokens(s) {
    if (!s) return 0;
    var c = 0, n = 0;
    for (var j = 0; j < s.length; j++) { if (CJK.test(s.charAt(j))) c++; else n++; }
    return c + n / 4;
  }
  function fmtN(n) { return n >= 1000 ? (n / 1000).toFixed(1) + 'k' : '' + Math.round(n); }
  function now() { return performance.now(); }

  /* ---------- 徽章 UI ---------- */
  var badge = document.createElement('div');
  badge.id = 'zcode-tps-badge';
  badge.title = '输出速率估算 (EST)：MutationObserver 监听流式文本，CJK≈1 tok/字、EN≈4 chars/tok';
  badge.style.cssText =
    'position:fixed;right:18px;top:60px;z-index:2147483000;pointer-events:none;' +
    'display:flex;align-items:center;gap:9px;padding:7px 13px;border-radius:13px;' +
    'border:1px solid transparent;' +
    'background:linear-gradient(rgb(10 8 20 / 0.78), rgb(10 8 20 / 0.78)) padding-box,' +
    'linear-gradient(135deg, rgb(64 153 255 / 0.55), rgb(123 92 229 / 0.55)) border-box;' +
    'box-shadow:0 0 22px rgb(96 132 255 / 0.28);' +
    'font-family:ui-monospace,Consolas,monospace;color:#dbe4ff;' +
    'opacity:0;transition:opacity .8s ease, box-shadow .3s ease;white-space:nowrap;';
  badge.innerHTML =
    '<span style="font-size:13px;filter:drop-shadow(0 0 6px rgb(96 165 250 / .9))">⚡</span>' +
    '<span id="zcode-tps-rate" style="font-size:19px;font-weight:700;line-height:1;' +
      'background:linear-gradient(90deg,#60a5fa,#a878ff);-webkit-background-clip:text;background-clip:text;color:transparent;">0.0</span>' +
    '<span style="font-size:10px;opacity:.65;margin-left:-3px;">tok/s</span>' +
    '<canvas id="zcode-tps-spark" width="160" height="44" style="width:80px;height:22px;"></canvas>' +
    '<span id="zcode-tps-meta" style="font-size:10px;opacity:.78;line-height:1.45;text-align:left;">Σ 0 tok<br>EST · 0.0s</span>';
  document.documentElement.appendChild(badge);   // 挂在根节点，彻底游离于聊天区观察范围之外
  var elRate = badge.querySelector('#zcode-tps-rate');
  var elMeta = badge.querySelector('#zcode-tps-meta');
  var spark = badge.querySelector('#zcode-tps-spark');
  var sctx = spark.getContext('2d');

  /* ---------- 计量状态 ---------- */
  var samples = [];                       // {t, tok} 增量样本
  var hist = [];                          // 速率历史（画曲线）
  var turn = { active: false, start: 0, tokens: 0, peak: 0 };
  var lastGrowth = -1e9;

  function feed(netTok, t) {
    if (!netTok) return;
    samples.push({ t: t, tok: netTok });
    if (netTok > 0) {                    // 只有净增长才推进回合/总量；净减少只拉低瞬时速率
      if (!turn.active) { turn.active = true; turn.start = t; turn.tokens = 0; turn.peak = 0; }
      turn.tokens += netTok;
      lastGrowth = t;
    }
  }

  function rate(t) {
    var cutoff = t - RATE_WINDOW, sum = 0;
    for (var i = samples.length - 1; i >= 0; i--) {
      if (samples[i].t < cutoff) break;
      sum += samples[i].tok;
    }
    while (samples.length && samples[0].t < cutoff - 2000) samples.shift();
    // 分母 = 实际窗口覆盖时长：回合初期线性爬升，稳态封顶为 RATE_WINDOW
    var span = Math.min(RATE_WINDOW, Math.max(800, turn.active ? t - turn.start : RATE_WINDOW));
    return sum / (span / 1000);
  }

  /* ---------- 观察根与定位 ----------
     直接观察整个 body：不依赖聊天区 DOM 结构（版本鲁棒）。
     流式期间聊天区是最大的文本增量来源；侧栏计时器等噪声 <1 tok/s 可忽略。
     徽章挂在 documentElement 上，天然在观察范围外 + onMuts 里再跳过自身，双保险防反馈。
     composer 只用于把徽章吸附到输入框上缘；找不到就钉在右上角。 */
  var composerEl = null, mo = null;
  function findComposer() {
    var els = document.querySelectorAll('textarea, input[type="text"], input:not([type]), [contenteditable="true"], [contenteditable=""]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var sig = (el.getAttribute('placeholder') || '') + '|' + (el.getAttribute('aria-label') || '') + '|' +
        (el.getAttribute('data-placeholder') || '');
      if (/继续输入|排队|queue|follow/i.test(sig)) return el;
    }
    return els.length ? els[els.length - 1] : null;
  }
  function anchor() {
    if (!mo) {
      mo = new MutationObserver(onMuts);
      mo.observe(document.body, { subtree: true, childList: true, characterData: true, characterDataOldValue: true });
    }
    if (!composerEl || !composerEl.isConnected) composerEl = findComposer();
  }
  function onMuts(muts) {
    var t = now();
    var net = 0;
    for (var i = 0; i < muts.length; i++) {
      var m = muts[i];
      if (badge.contains(m.target)) continue;   // 不吃自己的刷新（防反馈回路）
      if (m.type === 'characterData') {
        var nv = m.target.data || '', ov = m.oldValue || '';
        net += estTokens(nv) - estTokens(ov);
      } else if (m.type === 'childList') {
        // 净增量：插入减删除。同位置"删旧插新"的重渲染（xterm 行刷新、React 重挂载）净零，不再误计
        var j, n;
        for (j = 0; j < m.addedNodes.length; j++) {
          n = m.addedNodes[j];
          if (n.nodeType === 8) continue;                    // React 注释标记不算
          net += estTokens(n.nodeType === 3 ? n.data : (n.textContent || ''));
        }
        for (j = 0; j < m.removedNodes.length; j++) {
          n = m.removedNodes[j];
          if (n.nodeType === 8) continue;
          net -= estTokens(n.nodeType === 3 ? n.data : (n.textContent || ''));
        }
      }
    }
    // 批次闸门：滚轮滚动挂载历史行 / 切换会话整段加载 = 巨量净增，不是流式输出，忽略
    if (net > BATCH_MAX) return;
    feed(net, t);
  }

  /* ---------- 曲线 ---------- */
  function drawSpark() {
    var w = spark.width, h = spark.height;
    sctx.clearRect(0, 0, w, h);
    if (hist.length < 2) return;
    var max = 5;
    for (var i = 0; i < hist.length; i++) if (hist[i] > max) max = hist[i];
    var grad = sctx.createLinearGradient(0, 0, w, 0);
    grad.addColorStop(0, 'rgba(96,165,250,.95)');
    grad.addColorStop(1, 'rgba(168,120,255,.95)');
    sctx.beginPath();
    for (var j = 0; j < hist.length; j++) {
      var x = j / (HISTORY - 1) * w;
      var y = h - 4 - (hist[j] / max) * (h - 8);
      j ? sctx.lineTo(x, y) : sctx.moveTo(x, y);
    }
    sctx.strokeStyle = grad; sctx.lineWidth = 2.5;
    sctx.shadowColor = 'rgba(96,165,250,.8)'; sctx.shadowBlur = 4;
    sctx.stroke();
    sctx.shadowBlur = 0;
    sctx.lineTo((hist.length - 1) / (HISTORY - 1) * w, h); sctx.lineTo(0, h); sctx.closePath();
    sctx.fillStyle = 'rgba(96,132,255,.14)'; sctx.fill();
  }

  /* ---------- 主循环 ---------- */
  var lastPos = 0;
  setInterval(function () {
    anchor();
    var t = now();
    var live = turn.active && (t - lastGrowth) < IDLE_END;
    var r = Math.max(0, live ? rate(t) : 0);
    hist.push(r);
    if (hist.length > HISTORY) hist.shift();
    if (live) turn.peak = Math.max(turn.peak, r);

    // 徽章跟随输入框上缘
    if (composerEl && composerEl.isConnected) {
      var rect = composerEl.getBoundingClientRect();
      if (rect.width) badge.style.top = Math.max(52, rect.top - 58) + 'px';
    }

    if (live) {
      badge.style.opacity = '1';
      badge.style.boxShadow = '0 0 26px rgb(96 132 255 / 0.45)';
      elRate.textContent = r.toFixed(1);
      elMeta.innerHTML = 'Σ ' + fmtN(turn.tokens) + ' tok · ' + ((t - turn.start) / 1000).toFixed(1) + 's<br>峰值 ' +
        turn.peak.toFixed(1) + ' · EST';
    } else if (turn.active) {
      // 回合结束：保留总结，FADE_AFTER 后淡出
      var avg = turn.tokens / Math.max(1, (lastGrowth - turn.start) / 1000);
      badge.style.opacity = (t - lastGrowth < FADE_AFTER) ? '0.85' : '0';
      badge.style.boxShadow = '0 0 22px rgb(96 132 255 / 0.28)';
      elRate.textContent = avg.toFixed(1);
      elMeta.innerHTML = '✓ Σ ' + fmtN(turn.tokens) + ' tok · ' +
        ((lastGrowth - turn.start) / 1000).toFixed(1) + 's<br>均值 ' + avg.toFixed(1) + ' tok/s · 峰值 ' +
        turn.peak.toFixed(1) + ' · EST';
      if (t - lastGrowth > FADE_AFTER) { turn.active = false; hist = []; }
    }
    drawSpark();
  }, TICK);
})();