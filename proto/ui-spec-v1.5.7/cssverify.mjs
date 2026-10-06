/**
 * CSS 恢复校验：确认浮窗菜单修复后 CSS 结构完整、无遗留损坏。
 * 用法：node cssverify.mjs
 * 关注点（来自本轮抓到的真 bug）：
 *   - 上一版 .mini / .mini .selb 多出孤立的 `}`，导致后续 .floatbar{display:none} 失效，
 *     菜单在未选中时就以全宽块显示、且点 pip/rec 选不中。
 *   - 修复后：`.mini` 合并 border/overflow/cursor/touch-action；`.mini .selb` 合并
 *     background/border-radius/pointer-events/display；`.floatbar` 默认 display:none 必须生效。
 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
import path from 'path';

const FILE = pathToFileURL(
  'C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html'
).href;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
const errors = [];
page.on('pageerror', e => errors.push('[pageerror] ' + e.message.split('\n')[0]));
page.on('console', m => { if (m.type() === 'error') errors.push('[console.error] ' + m.text()); });

await page.goto(FILE, { waitUntil: 'load' });
await page.waitForTimeout(400);
await page.locator('.nav button').nth(7).click({ force: true }); // 编辑页
await page.waitForTimeout(500);

// 确保未选中任何轨道
await page.evaluate(() => { if (typeof clearSel === 'function') clearSel(); });
await page.waitForTimeout(150);

const checks = [];
function check(name, ok, detail = '') {
  checks.push((ok ? '  ✓ ' : '  ✗ ') + name + (detail ? ' — ' + detail : ''));
  if (!ok) errors.push('[css] ' + name);
}

const mini = await page.evaluate(() => {
  const m = document.getElementById('mini');
  if (!m) return null;
  const cs = getComputedStyle(m);
  return { border: cs.borderTopWidth, overflow: cs.overflowX, cursor: cs.cursor };
});
check('#mini 恢复边框 border=1px', mini && mini.border === '1px', mini && `border=${mini.border}`);
check('#mini 恢复 overflow:hidden', mini && mini.overflow === 'hidden', mini && `overflow=${mini.overflow}`);
check('#mini 可拖光标 cursor=grab', mini && mini.cursor === 'grab', mini && `cursor=${mini.cursor}`);

const mv = await page.evaluate(() => {
  const s = document.getElementById('miniView');
  if (!s) return null;
  const cs = getComputedStyle(s);
  return { display: cs.display, pe: cs.pointerEvents };
});
check('#miniView 恢复 display:none 默认', mv && mv.display === 'none', mv && `display=${mv.display}`);
check('#miniView 恢复 pointer-events:none', mv && mv.pe === 'none', mv && `pe=${mv.pe}`);

const fb = await page.evaluate(() => {
  const f = document.getElementById('floatbar');
  if (!f) return null;
  const cs = getComputedStyle(f);
  const r = f.getBoundingClientRect();
  return { display: cs.display, h: Math.round(r.height), hasShow: f.classList.contains('show') };
});
check('.floatbar 未选中时 display:none', fb && fb.display === 'none', fb && `display=${fb.display} hasShow=${fb.hasShow}`);
check('.floatbar 未选中时高度为 0', fb && fb.h === 0, fb && `h=${fb.h}`);

console.log('\n[CSS 恢复校验]');
console.log(checks.join('\n'));
console.log('JS 错误: ' + (errors.length ? errors.join('; ') : '无'));
const pass = checks.filter(c => c.startsWith('  ✓')).length;
const fail = checks.filter(c => c.startsWith('  ✗')).length;
console.log(`结果: ${pass} 通过 / ${fail} 失败`);
await browser.close();
process.exit(fail ? 1 : 0);
