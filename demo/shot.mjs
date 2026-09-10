// README 配图生成：无头浏览器跑 demo/demo.html（真实注入块 + 假流式），截图 + 拼 GIF
// 用法: node demo/shot.mjs   （puppeteer 借 design-pool 的，本仓库零依赖）
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const puppeteer = require('/Users/tobyatlarge/ZCodeProject/design-pool/node_modules/puppeteer');
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import path from 'path';
import fs from 'fs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DOCS = path.join(HERE, '..', 'docs');
fs.mkdirSync(DOCS, { recursive: true });
const FRAMES = '/tmp/zcode-tps-frames';
fs.rmSync(FRAMES, { recursive: true, force: true });
fs.mkdirSync(FRAMES, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await puppeteer.launch({ args: ['--force-color-profile=srgb'] });
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });
await page.goto('file://' + path.join(HERE, 'demo.html'));

console.log('等待流式垫量…');
await sleep(41000);                       // 垫量 25s + 休息 11s + 恢复输出 5s
await page.click('#zcode-tps-badge');     // 展开面板
console.log('已展开，录制徽章区域 8s…');
const clip = { x: 980, y: 30, width: 460, height: 120 };
for (let i = 0; i < 64; i++) {            // 8fps × 8s
  await page.screenshot({ path: `${FRAMES}/f${String(i).padStart(3, '0')}.png`, clip });
  await sleep(125);
}
console.log('输出整页与特写…');
await page.screenshot({ path: path.join(DOCS, 'hero.png') });
await page.screenshot({ path: path.join(DOCS, 'badge-closeup.png'), clip });
await browser.close();

execSync(`ffmpeg -y -loglevel error -framerate 8 -i ${FRAMES}/f%03d.png ` +
  `-vf "fps=8,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer" ` +
  path.join(DOCS, 'badge.gif'), { stdio: 'inherit' });
fs.rmSync(FRAMES, { recursive: true, force: true });
for (const f of ['hero.png', 'badge-closeup.png', 'badge.gif']) {
  console.log(f, (fs.statSync(path.join(DOCS, f)).size / 1024).toFixed(0) + 'KB');
}
