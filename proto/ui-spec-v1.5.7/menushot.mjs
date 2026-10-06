/**
 * 悬浮菜单截图 + 三轨选中验证：确认主/画中画/录音三轨点击后
 * 均弹出「水平胶囊」菜单（蓝底白线条图标），且落在 #phone 边界内、无 JS 错误。
 * 用法：node menushot.mjs
 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
import path from 'path';

const FILE = pathToFileURL(
  'C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html'
).href;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 1000 } });
const errors = [];
page.on('pageerror', e => errors.push('[pageerror] ' + e.message.split('\n')[0]));
page.on('console', m => { if (m.type() === 'error') errors.push('[console.error] ' + m.text()); });

await page.goto(FILE, { waitUntil: 'load' });
await page.waitForTimeout(400);
await page.locator('.nav button').nth(7).click({ force: true }); // 编辑页
await page.waitForTimeout(500);

const tracks = [
  { sel: '#trackStack .thit', name: 'main', shot: 'menu-main.png' },
  { sel: '#trackStack .pblk', name: 'pip', shot: 'menu-pip.png' },
  { sel: '#trackStack .rblk', name: 'rec', shot: 'menu-rec.png' },
];

const results = [];
for (const t of tracks) {
  const el = page.locator(t.sel).first();
  if (!(await el.count())) { errors.push(`[missing] ${t.name} 区块: ${t.sel}`); continue; }
  const b = await el.boundingBox();
  if (!b) { errors.push(`[nobox] ${t.name}`); continue; }
  await page.mouse.click(b.x + b.width / 2, b.y + b.height / 2);
  await page.waitForTimeout(300);
  const info = await page.evaluate(() => {
    const f = document.getElementById('floatbar');
    const phone = document.getElementById('phone');
    const shown = f && f.classList.contains('show');
    const r = f ? f.getBoundingClientRect() : null;
    const pr = phone ? phone.getBoundingClientRect() : null;
    const inPhone = r && pr ? (r.x >= pr.x - 2 && r.right <= pr.right + 2 &&
      r.y >= pr.y - 2 && r.bottom <= pr.bottom + 2) : false;
    const items = f ? [...f.querySelectorAll('.fi .tx')].map(e => e.textContent) : [];
    return {
      shown, w: r ? Math.round(r.width) : 0, h: r ? Math.round(r.height) : 0,
      x: r ? Math.round(r.x) : 0, y: r ? Math.round(r.y) : 0, inPhone, items,
    };
  });
  const ok = info.shown && info.w > 60 && info.h > 0 && info.h < 120 && info.inPhone && info.items.length >= 3;
  results.push(`  ${ok ? '✓' : '✗'} ${t.name}: shown=${info.shown} fb=${JSON.stringify({ x: info.x, y: info.y, w: info.w, h: info.h })} inPhone=${info.inPhone} [${info.items.join(',')}]`);
  if (!ok) errors.push(`[menu] ${t.name} 菜单异常 shown=${info.shown} h=${info.h} inPhone=${info.inPhone}`);
  await page.screenshot({ path: t.shot });
  // 点空白关闭，准备下一次
  const canvas = await page.locator('.canvas').boundingBox().catch(() => null);
  if (canvas) { await page.mouse.click(canvas.x + canvas.width / 2, canvas.y + canvas.height / 2); await page.waitForTimeout(200); }
}

console.log('\n[三轨悬浮菜单验证]');
console.log(results.join('\n'));
console.log('JS 错误: ' + (errors.length ? errors.join('; ') : '无'));
const fail = results.filter(r => r.startsWith('  ✗')).length;
console.log(`结果: ${results.length - fail}/${results.length} 通过`);
await browser.close();
process.exit(fail || errors.length ? 1 : 0);
