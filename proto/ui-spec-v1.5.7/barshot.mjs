/**
 * 生成上下文底栏的验证截图
 *  1 主轨（拖动自动蓝框 + 6 键）
 *  2 画中画选中（9 键 + 悬浮菜单）
 *  3 录音选中（5 键 + 悬浮菜单）
 *  4 音量工具面板
 * 用法：node barshot.mjs
 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
import path from 'path';

const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 1000 } });
const errs = [];
p.on('pageerror', e => errs.push('[pageerror] ' + e.message.split('\n')[0]));
await p.goto(FILE, { waitUntil: 'load' });
await p.waitForTimeout(400);
await p.locator('.nav button').nth(7).click({ force: true });
await p.waitForTimeout(400);

const clip = await p.evaluate(() => {
  const ph = document.getElementById('phone');
  const r = ph.getBoundingClientRect();
  return { x: r.x, y: r.y, width: r.width, height: r.height };
});
const shot = async (name) => { await p.screenshot({ path: name, clip }); console.log('📸', name); };
const select = async (k) => {
  await p.evaluate((kind) => {
    const items = kind === 'pip' ? pipItems : kind === 'rec' ? recItems : regions;
    selectBlock(kind, items[0].id);
  }, k);
  await p.waitForTimeout(320);
};

// 1 主轨：拖动 → 自动蓝框
const si = await p.evaluate(() => { const r = document.getElementById('tlScroll').getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width }; });
await p.mouse.move(si.x + si.w / 2, si.y + 8);
await p.mouse.down();
await p.mouse.move(si.x + si.w / 2 - 120, si.y + 8, { steps: 10 });
await p.mouse.up();
await p.waitForTimeout(320);
await shot('bar-1-main-autoframe.png');

// 2 画中画
await select('pip');
await shot('bar-2-pip-9keys.png');

// 3 录音
await select('rec');
await shot('bar-3-rec-5keys.png');

// 4 音量面板
await select('main');
await p.locator('#bottombar .bb[aria-label="音量"]').click({ force: true });
await p.waitForTimeout(320);
await shot('bar-4-volume-panel.png');

// 5 主轨「画面大小」面板
await p.locator('#tpCancel').click({ force: true }).catch(() => {});
await p.waitForTimeout(200);
await p.locator('#bottombar .bb[aria-label="画面大小"]').click({ force: true });
await p.waitForTimeout(320);
await shot('bar-5-main-size-panel.png');

// 6 主轨 旋转 + 左右镜像 → 预览变换 + 角标
await p.locator('#tpCancel').click({ force: true }).catch(() => {});
await p.waitForTimeout(200);
await p.locator('#bottombar .bb[aria-label="旋转"]').click({ force: true });
await p.waitForTimeout(200);
await p.locator('#bottombar .bb[aria-label="左右镜像"]').click({ force: true });
await p.waitForTimeout(200);
await p.locator('#bottombar .bb[aria-label="旋转"]').click({ force: true });
await p.waitForTimeout(320);
await shot('bar-6-main-rotate-mirror.png');

console.log(errs.length ? '❌ ' + errs.join(' | ') : '✅ 无 JS 错误');
await b.close();
