/**
 * 变速面板验证截图
 *  1 默认 1x
 *  2 选中 2x（时长减半 + 档位高亮 + 游标右移）
 *  3 拖动刻度尺到连续值（~0.5x，档位不吸附）
 *  4 应用到全部
 * 用法：node spdshot.mjs
 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';

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
  const r = document.getElementById('phone').getBoundingClientRect();
  return { x: r.x, y: r.y, width: r.width, height: r.height };
});
const shot = async n => { await p.screenshot({ path: n, clip }); console.log('📸', n); };

// 选中主轨第一段（7s）
await p.evaluate(() => selectBlock('main', regions[0].id));
await p.waitForTimeout(300);

// 1 默认 1x
await p.locator('#bottombar .bb[aria-label="变速"]').click({ force: true });
await p.waitForTimeout(320);
await shot('spd-1-default-1x.png');

// 2 选 2x
await p.locator('#spdPanel .spd-step[data-v="2"]').click({ force: true });
await p.waitForTimeout(250);
await shot('spd-2-2x.png');

// 3 拖刻度尺到连续值
{
  const sb = await p.locator('#spdScale').boundingBox();
  await p.mouse.move(sb.x + sb.width * 0.42, sb.y + sb.height / 2);
  await p.mouse.down();
  await p.mouse.move(sb.x + sb.width * 0.45, sb.y + sb.height / 2, { steps: 6 });
  await p.mouse.up();
  await p.waitForTimeout(250);
  const v = await p.evaluate(() => spdCtx ? spdCtx.v : null);
  const on = await p.locator('#spdPanel .spd-step.on').count();
  console.log('   连续值 =', v, '| 高亮档位数 =', on, '(期望 0 = 未吸附)');
  await shot('spd-3-continuous.png');
}

// 4 确定 → 应用到全部
await p.locator('#spdPanel .spd-step[data-v="0.5"]').click({ force: true });
await p.waitForTimeout(200);
await p.locator('#spdAll').click({ force: true });
await p.waitForTimeout(450);
const all = await p.evaluate(() => regions.map(r => r.speed));
console.log('   应用到全部后各段 speed =', all.join(','));
await shot('spd-4-apply-all.png');

console.log(errs.length ? '❌ ' + errs.join(' | ') : '✅ 无 JS 错误');
await b.close();
