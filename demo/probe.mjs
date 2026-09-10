// 探针：观测 demo 页里徽章状态随时间的变化，定位流式在哪一环断了
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const puppeteer = require('/Users/tobyatlarge/ZCodeProject/design-pool/node_modules/puppeteer');
import { fileURLToPath } from 'url';
import path from 'path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const browser = await puppeteer.launch();
const page = await browser.newPage();
page.on('console', (m) => console.log('[page]', m.text()));
page.on('pageerror', (e) => console.log('[pageerror]', e.message));
await page.setViewport({ width: 1440, height: 900 });
await page.goto('file://' + path.join(HERE, 'demo.html'));

for (let i = 0; i <= 12; i++) {
  await new Promise((r) => setTimeout(r, 5000));
  const s = await page.evaluate(() => {
    const q = (sel) => document.querySelector(sel);
    const rate = q('#zcode-tps-rate'), bolt = q('#zcode-tps-bolt'), badge = q('#zcode-tps-badge');
    const pre = q('#stream');
    return {
      hasBadge: !!badge,
      rate: rate ? rate.textContent : null,
      bolt: bolt ? bolt.textContent : null,
      opacity: badge ? badge.style.opacity : null,
      streamLen: pre ? pre.textContent.length : -1,
    };
  });
  console.log(`t=${((i + 1) * 5).toString().padStart(2)}s`, JSON.stringify(s));
}
await browser.close();
