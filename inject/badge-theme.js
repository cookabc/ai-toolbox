/* ===== ZCode 徽章主题（跟随 ZCode 的 dark-mode/light-mode，写 --zb-* 变量） =====
   背景：各徽章样式原本写死深色（rgb(10 8 20/…)、#dbe4ff 等），浅色模式下看不清。
   本模块监听 documentElement 的主题类（ZCode 用 dark-mode/light-mode 标记，
   存储在 localStorage["theme"] = system/dark/light，system 跟 prefers-color-scheme），
   把当前主题的配色写进 :root 的 --zb-* CSS 变量；徽章样式改用 var(--zb-*) 即自动跟随。
   跟随 ZCode 原生主题切换（设置里改 theme 或系统深浅变化都会触发类切换），
   同时暴露 window.__zcodeSetTheme(mode) 供一个手动 toggle 强制覆盖（写 localStorage["theme"]）。
   变量表（深/浅两套值）：
     --zb-bg        徽章底（渐变 padding-box 用的实色）
     --zb-text      主文字     --zb-text-dim   次要文字
     --zb-border-a/b 描边渐变两色   --zb-glow   辉光色
   须在 badge-dock 之前加载（徽章读变量时变量已就位）。 */
(function () {
  if (window.__zcodeBadgeTheme) return;
  window.__zcodeBadgeTheme = true;

  var THEMES = {
    dark: {
      '--zb-bg': 'rgb(10 8 20 / 0.82)',
      '--zb-text': '#dbe4ff',
      '--zb-text-dim': 'rgb(219 228 255 / 0.65)',
      '--zb-border-a': 'rgb(96 165 250 / 0.55)',
      '--zb-border-b': 'rgb(168 120 255 / 0.55)',
      '--zb-glow': 'rgb(96 132 255 / 0.28)',
      '--zb-input-bg': 'rgb(255 255 255 / 0.05)',
      '--zb-overlay': 'rgb(5 4 10 / 0.6)',
      '--zb-row-hover': 'rgb(96 165 250 / 0.07)',
      '--zb-mark': 'rgb(251 191 36 / 0.35)',
    },
    light: {
      '--zb-bg': 'rgb(255 255 255 / 0.88)',
      '--zb-text': '#1e2a4a',
      '--zb-text-dim': 'rgb(30 42 74 / 0.6)',
      '--zb-border-a': 'rgb(59 130 246 / 0.5)',
      '--zb-border-b': 'rgb(139 92 246 / 0.5)',
      '--zb-glow': 'rgb(59 130 246 / 0.2)',
      '--zb-input-bg': 'rgb(0 0 0 / 0.04)',
      '--zb-overlay': 'rgb(255 255 255 / 0.55)',
      '--zb-row-hover': 'rgb(59 130 246 / 0.08)',
      '--zb-mark': 'rgb(217 119 6 / 0.3)',
    },
  };

  function currentMode() {
    var de = document.documentElement;
    if (de.classList && de.classList.contains('light-mode')) return 'light';
    return 'dark';   // dark-mode 或未标记都按深色（ZCode 默认深）
  }

  function apply() {
    var mode = currentMode();
    var vars = THEMES[mode];
    var root = document.documentElement.style;
    for (var k in vars) root.setProperty(k, vars[k]);
    document.documentElement.setAttribute('data-zb-theme', mode);
  }

  // 监听主题类变化（ZCode 原生切换 theme 时改 dark-mode/light-mode 类）
  if (typeof MutationObserver === 'function' && document.documentElement) {
    var mo = new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        if (muts[i].attributeName === 'class') { apply(); return; }
      }
    });
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
  }
  apply();

  /* 手动覆盖：写 localStorage["theme"] 并直接切类（ZCode 原生逻辑也会响应它的存储，
     但立即切类让徽章/霓虹即时生效，不等 ZCode 的设置回写）。 */
  window.__zcodeSetTheme = function (mode) {
    var de = document.documentElement;
    if (mode !== 'dark' && mode !== 'light') mode = 'dark';
    try { if (window.localStorage) localStorage.setItem('theme', mode); } catch (e) {}
    if (de.classList) {
      de.classList.remove('dark-mode', 'light-mode');
      de.classList.add(mode + '-mode');
    }
    apply();
  };
  window.__zcodeTheme = currentMode;

  window.__zcodeBadgeThemeTest = { apply: apply, currentMode: currentMode, THEMES: THEMES };
})();
