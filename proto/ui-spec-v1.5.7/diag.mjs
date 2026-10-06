import { chromium } from 'playwright';
import { pathToFileURL } from 'url';

const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 1100 } });
page.on('pageerror', e => console.log('[ERR]', e.message.split('\n')[0]));
await page.goto(FILE, { waitUntil: 'load' });
await page.waitForTimeout(400);
await page.locator('.nav button').nth(7).click({ force: true });
await page.waitForTimeout(500);

const dump = await page.evaluate(() => {
  const r = el => {
    if (!el) return 'null';
    const b = el.getBoundingClientRect();
    return `${Math.round(b.x)},${Math.round(b.y)} ${Math.round(b.width)}x${Math.round(b.height)}`;
  };
  const phone = document.getElementById('phone').getBoundingClientRect();
  const out = { phone: r(document.getElementById('phone')) };
  ['.statusbar', '.editor', '.topbar', '.preview-zone', '.timeline', '.tl-body',
   '.tl-labels', '#tlScroll', '#trackStack', '.trow.rec', '.trow.pip', '.trow.main',
   '.m-thumb', '.m-wave', '.m-ruler', '.mini-row', '.bottombar', '.safe'].forEach(sel => {
    out[sel] = r(document.querySelector(sel));
  });
  out.__phoneBottom = Math.round(phone.bottom);
  out.__winH = window.innerHeight;
  // 各层实际高度
  const stack = document.getElementById('trackStack');
  out.__stackChildren = [...stack.children].map(c => `${c.className}:${Math.round(c.getBoundingClientRect().height)}`);
  return out;
});
console.log('===== 编辑页布局 =====');
Object.entries(dump).forEach(([k, v]) => console.log('  ' + k.padEnd(16), v));

// 打开导出抽屉再 dump
await page.evaluate(() => openExport());
await page.waitForTimeout(400);
const dump2 = await page.evaluate(() => {
  const r = el => {
    if (!el) return 'null';
    const b = el.getBoundingClientRect();
    return `${Math.round(b.x)},${Math.round(b.y)} ${Math.round(b.width)}x${Math.round(b.height)}`;
  };
  const out = {};
  ['#exportMask', '#exportMask .sheet', '.ex-first', '.ex-row', '#exAudio',
   '#exResWrap', '#exFpsWrap', '.ex-size', '#exportBtn'].forEach(s => {
    out[s] = r(document.querySelector(s));
  });
  const sh = document.querySelector('#exportMask .sheet');
  out.__sheetScrollH = sh ? sh.scrollHeight : -1;
  out.__sheetClientH = sh ? sh.clientHeight : -1;
  return out;
});
console.log('\n===== 导出抽屉布局 =====');
Object.entries(dump2).forEach(([k, v]) => console.log('  ' + k.padEnd(24), v));

await page.screenshot({ path: 'diag-editor.png' });
await browser.close();
