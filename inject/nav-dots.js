/* ===== ZCode 消息锚点导航（右缘圆点条：点击按比例跳转，指纹校准锚点） =====
   纯渲染层注入：每 2.5s 重建一次。先找「对话滚动容器」，空闲时（用户 3s 未滚动）
   把滚动范围切成 24 份逐份瞬时滚动到位、读首条可见回合文本做指纹，去重后映射回
   纵向坐标画点；指纹失败（结构变化/文本雷同）退化为均匀 5 点。点击=按比例滚动。
   采样滚动会瞬时挪页面，因此只在空闲时做且立即复位——阅读中绝不打断。
   与徽章三兄弟相反的取向：交互只读文本、不动业务 DOM，指纹质量随版本变化时
   安静退化而不是误跳。它是「快速回到大概位置」的导航条，不是逐条精确定位。 */
(function () {
  if (window.__zcodeNavDots) return;
  window.__zcodeNavDots = true;

  var SCAN_MS = 2500;
  var MAX_DOTS = 30;        // 点的上限，超过抽样
  var SAMPLES = 24;         // 采样等份数
  var LS_COLLAPSE = 'zcode-nav-hidden';

  /* ---------- 轨道 UI ---------- */
  var hidden = false;
  try { hidden = window.localStorage && localStorage.getItem(LS_COLLAPSE) === '1'; } catch (e) {}

  var rail = document.createElement('div');
  rail.id = 'zcode-nav-rail';
  rail.style.cssText =
    'position:fixed;right:4px;top:50%;transform:translateY(-50%);z-index:2147482900;' +
    'display:flex;flex-direction:column;align-items:center;gap:0;' +
    'pointer-events:auto;user-select:none;-webkit-user-select:none;';
  rail.innerHTML =
    '<span id="zcode-nav-toggle" title="消息锚点导航 · 点击收起/展开" style="' +
      'cursor:pointer;font-size:10px;color:var(--zb-text-dim);padding:4px 3px;opacity:.7;">⋮⋮</span>' +
    '<span id="zcode-nav-dots" style="display:flex;flex-direction:column;align-items:center;gap:7px;padding:6px 3px;"></span>';
  document.documentElement.appendChild(rail);
  var dotsBox = rail.querySelector('#zcode-nav-dots');
  var toggle = rail.querySelector('#zcode-nav-toggle');
  if (!dotsBox || !toggle) return;   // DOM 异常时安全退出，不阻断官方启动

  function applyHidden() {
    dotsBox.style.display = hidden ? 'none' : 'flex';
    toggle.style.opacity = hidden ? '0.35' : '0.7';
    try { if (window.localStorage) localStorage.setItem(LS_COLLAPSE, hidden ? '1' : '0'); } catch (e) {}
  }
  applyHidden();
  function toggleHidden() { hidden = !hidden; applyHidden(); }
  // 拖动换位 + 点击收起：有拖拽助手（badge-dock 先加载）时 toggle 作把手，onClick=收起；
  // 无助手退回普通 click（仅收起，不可拖）。
  if (typeof window.__zcodeMakeDraggable === 'function') {
    window.__zcodeMakeDraggable(rail, {
      storageKey: 'zcode-nav-rail-pos',
      handleEl: toggle,
      onClick: toggleHidden,
    });
    toggle.style.cursor = 'grab';
  } else if (toggle.addEventListener) {
    toggle.addEventListener('click', toggleHidden);
  }

  /* ---------- 滚动容器探测 ----------
     找「内容明显比视口高」的最外层可滚动元素；都不满足时退回 window。 */
  function findScroller() {
    var els = document.querySelectorAll('main, [class*=chat], [class*=message], [class*=scroll], [class*=conversation]');
    var best = null, bestOver = 0;
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var over = el.scrollHeight - el.clientHeight;
      if (over > 200 && over > bestOver) { best = el; bestOver = over; }
    }
    return best;   // null = 页面无内层滚动容器，用 window 滚
  }
  function scrollMax(sc) { return sc ? sc.scrollHeight - sc.clientHeight : document.documentElement.scrollHeight - (window.innerHeight || 0); }
  function scrollTo(sc, y) {
    if (sc) { sc.scrollTop = y; if (sc.onscroll) sc.onscroll(); } else window.scrollTo(0, y);
  }

  /* ---------- 指纹采样 ----------
     把滚动范围切成 SAMPLES 份，每份滚动到位后读一次首条可见回合标题的文本前缀。
     太 invasive？不——这只是读操作，但为了不打扰用户，只在「构建」时做一次，
     且立刻滚回原位。指纹质量随版本变化，失败时退化为「均匀分布的点」。 */
  function fingerprint(sc) {
    var max = scrollMax(sc);
    if (max <= 0) return null;
    var orig = sc ? sc.scrollTop : (window.pageYOffset || 0);
    var picks = [];
    for (var i = 0; i < SAMPLES; i++) {
      scrollTo(sc, max * i / (SAMPLES - 1));
      // 同步读：scrollTop 赋值后浏览器立即重排可见内容（同帧 innerText 可读）
      var t = firstHeadingText();
      picks.push(t);
    }
    scrollTo(sc, orig);
    // 若采到的文本全相同（结构变了），视为失败
    var distinct = {};
    for (var j = 0; j < picks.length; j++) distinct[picks[j]] = 1;
    var n = 0; for (var k in distinct) n++;
    return n >= Math.min(3, SAMPLES / 4) ? picks : null;
  }
  function firstHeadingText() {
    var els = document.querySelectorAll('[class*=user], [class*=User], [class*=human], [class*=turn], [class*=message]');
    for (var i = 0; i < els.length; i++) {
      var r = els[i].getBoundingClientRect ? els[i].getBoundingClientRect() : null;
      if (r && r.top >= 0 && r.top < (window.innerHeight || 800) * 0.6 && r.height > 10) {
        var t = (els[i].innerText || '').replace(/\s+/g, ' ').slice(0, 40);
        if (t) return t;
      }
    }
    return '';
  }

  /* ---------- 点画布 ---------- */
  var anchors = [];   // [{frac, label}]
  function rebuild() {
    if (hidden) return;
    var sc = findScroller();
    var max = scrollMax(sc);
    anchors = [];
    if (max > 300) {
      var picks = null;
      // 采样会瞬时滚动页面，只在用户 3s 内没碰过滚动条时才做（防打断阅读）
      if (Date.now() - lastUserScroll > 3000) picks = fingerprint(sc);
      if (picks) {
        var seen = {};
        for (var i = 0; i < picks.length; i++) {
          var key = picks[i];
          if (!key || seen[key]) continue;
          seen[key] = 1;
          anchors.push({ frac: i / (picks.length - 1), label: key });
        }
      }
      if (anchors.length < 2) {
        // 退化：均匀 5 点（顶部/1/4/中/3/4/底部）
        anchors = [];
        for (var q = 0; q < 5; q++) anchors.push({ frac: q / 4, label: '' });
      }
      if (anchors.length > MAX_DOTS) {
        var step = anchors.length / MAX_DOTS, sampled = [];
        for (var s = 0; s < MAX_DOTS; s++) sampled.push(anchors[Math.floor(s * step)]);
        anchors = sampled;
      }
    }
    render(sc);
  }

  function render(sc) {
    while (dotsBox.firstChild) dotsBox.removeChild(dotsBox.firstChild);
    if (!anchors.length) return;
    var max = scrollMax(sc);
    for (var i = 0; i < anchors.length; i++) {
      (function (a) {
        var d = document.createElement('span');
        d.style.cssText =
          'width:7px;height:7px;border-radius:99px;cursor:pointer;' +
          'background:rgb(96 165 250 / 0.45);box-shadow:0 0 6px rgb(96 132 255 / 0.3);' +
          'transition:transform .15s ease,background .15s ease;';
        if (a.label) d.title = a.label;
        d.addEventListener('mouseenter', function () { d.style.background = 'rgb(96 165 250 / 0.95)'; d.style.transform = 'scale(1.5)'; });
        d.addEventListener('mouseleave', function () { d.style.background = 'rgb(96 165 250 / 0.45)'; d.style.transform = 'scale(1)'; });
        d.addEventListener('click', function () {
          scrollTo(sc, max * a.frac);
        });
        dotsBox.appendChild(d);
      })(anchors[i]);
    }
  }

  var lastUserScroll = 0;
  if (window.addEventListener) {
    window.addEventListener('scroll', function () { lastUserScroll = Date.now(); }, true);
  }

  setInterval(rebuild, SCAN_MS);
  setTimeout(rebuild, 1500);   // 首屏等内容渲染一会儿再建
})();
