      /* ===== ZCode 彗星尾加强版（贴路径光痕，密/长/亮） ===== */
      (function () {
        if (window.__zcodeTrail) return;
        window.__zcodeTrail = true;
        var canvas = document.createElement('canvas');
        canvas.style.cssText = 'position:fixed;inset:0;z-index:-1;pointer-events:none;';
        document.body.appendChild(canvas);
        var ctx = canvas.getContext('2d');
        var W = 0, H = 0, DPR = Math.min(window.devicePixelRatio || 1, 2);
        function resize() {
          W = window.innerWidth; H = window.innerHeight;
          canvas.width = W * DPR; canvas.height = H * DPR;
          canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
          ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
        }
        resize();
        window.addEventListener('resize', resize);
        var ps = [];
        var MAX = 160;
        var lastX = null, lastY = null;
        window.addEventListener('mousemove', function (e) {
          var x = e.clientX, y = e.clientY;
          if (lastX === null) { lastX = x; lastY = y; return; }
          var dx = x - lastX, dy = y - lastY;
          var dist = Math.sqrt(dx * dx + dy * dy);
          var steps = Math.max(1, Math.floor(dist / 3));
          for (var i = 1; i <= steps && ps.length < MAX; i++) {
            var t = i / steps;
            ps.push({
              x: lastX + dx * t,
              y: lastY + dy * t,
              vx: dx * 0.07,
              vy: dy * 0.07,
              r: 1.0 + Math.random() * 1.2,
              life: 1,
              decay: 0.055 + Math.random() * 0.045,
              hue: Math.random() < 0.7 ? 212 : 262
            });
          }
          lastX = x; lastY = y;
        });
        var last = 0;
        function tick(t) {
          if (t - last >= 32) {
            last = t;
            ctx.clearRect(0, 0, W, H);
            for (var i = ps.length - 1; i >= 0; i--) {
              var p = ps[i];
              p.x += p.vx;
              p.y += p.vy;
              p.vx *= 0.92;
              p.vy *= 0.92;
              p.life -= p.decay;
              if (p.life <= 0) { ps.splice(i, 1); continue; }
              var alpha = Math.pow(p.life, 1.3) * 0.95;
              var g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, p.r * 3);
              g.addColorStop(0, 'hsla(' + p.hue + ', 95%, 85%, ' + alpha + ')');
              g.addColorStop(0.5, 'hsla(' + p.hue + ', 95%, 70%, ' + (alpha * 0.5) + ')');
              g.addColorStop(1, 'hsla(' + p.hue + ', 95%, 70%, 0)');
              ctx.fillStyle = g;
              ctx.beginPath();
              ctx.arc(p.x, p.y, p.r * 3, 0, 6.2832);
              ctx.fill();
            }
          }
          requestAnimationFrame(tick);
        }
        requestAnimationFrame(tick);
      })();
    