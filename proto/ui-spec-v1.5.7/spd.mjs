import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
import fs from 'fs';

const DIR = 'C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/';
const html = fs.readFileSync(DIR + 'index.html', 'utf8');

/* ---------- 静态检查 ---------- */
const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
try { new Function(scripts.sort((a, b) => b.length - a.length)[0]); console.log('JS syntax: OK'); }
catch (e) { console.log('JS ERROR:', e.message); process.exit(1); }
const st = html.match(/<style[^>]*>([\s\S]*?)<\/style>/)[1];
const o = (st.match(/{/g) || []).length, c = (st.match(/}/g) || []).length;
console.log('CSS braces:', o, '/', c, o === c ? 'OK' : 'MISMATCH');
const d1 = (html.match(/<div\b/g) || []).length, d2 = (html.match(/<\/div>/g) || []).length;
console.log('div:', d1, '/', d2, d1 === d2 ? 'OK' : 'MISMATCH');
const syms = new Set([...html.matchAll(/<symbol id="([^"]+)"/g)].map(m => m[1]));
const refs = new Set([...html.matchAll(/<use href="#([^"]+)"/g)].map(m => m[1]));
const miss = [...refs].filter(r => !syms.has(r));
console.log('icon refs:', refs.size, '| missing:', miss.length ? miss : 'none');

/* ---------- 变速面板功能验证 ---------- */
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 1000 } });
const errs = [];
p.on('pageerror', e => errs.push('[pageerror] ' + e.message.split('\n')[0]));
p.on('console', m => { if (m.type() === 'error') errs.push('[console.error] ' + m.text()); });
await p.goto(pathToFileURL(DIR + 'index.html').href, { waitUntil: 'load' });
await p.waitForTimeout(400);
await p.locator('.nav button').nth(7).click({ force: true });
await p.waitForTimeout(400);

const errors = [], log = [];
const assert = (c, n, d = '') => { if (c) log.push(`  ✓ ${n}${d ? ' — ' + d : ''}`); else { errors.push(n); log.push(`  ✗ ${n}${d ? ' — ' + d : ''}`); } };

// 选中主轨第一段
await p.evaluate(() => selectBlock('main', regions[0].id));
await p.waitForTimeout(300);
const before = await p.evaluate(() => ({ b: regions[0].b, a: regions[0].a, TOTAL, n: regions.length, second_a: regions[1].a }));
console.log('before:', JSON.stringify(before));

await p.locator('#bottombar .bb[aria-label="变速"]').click({ force: true });
await p.waitForTimeout(320);

assert((await p.locator('#spdPanel.show').count()) === 1, '点「变速」弹出变速面板');
const tabCnt = await p.locator('#spdPanel .spd-tab').count();
assert(tabCnt === 0, '已移除曲线/常规 Tab 栏', 'spd-tab 数量=' + tabCnt);
const steps = await p.locator('#spdPanel .spd-step').allTextContents();
assert(steps.join(' ') === '0.1x 0.5x 1x 1.5x 2x 3x 4x', '离散档位', steps.join(' '));
const dur0 = await p.locator('#spdDur').textContent();
assert(dur0 === (before.b - before.a).toFixed(2) + 's', '时长=原始时长(1x)', dur0);
assert((await p.locator('#spdPanel .spd-tick').count()) > 30, '对数刻度尺已渲染',
  (await p.locator('#spdPanel .spd-tick').count()) + ' 刻度');
assert((await p.locator('#spdPanel .spd-cur').count()) === 1, '游标存在');

// 点 2x 档位 → 时长应减半
await p.locator('#spdPanel .spd-step[data-v="2"]').click({ force: true });
await p.waitForTimeout(200);
const dur2 = await p.locator('#spdDur').textContent();
const expDur = ((before.b - before.a) / 2).toFixed(2) + 's';
assert(dur2 === expDur, '2x 时长联动减半', dur2 + ' (期望 ' + expDur + ')');
const on2 = await p.locator('#spdPanel .spd-step.on').textContent();
assert(on2 === '2x', '2x 档位高亮', on2);
const curPct = await p.evaluate(() => document.getElementById('spdCur').style.left);
assert(curPct && curPct !== '0%', '游标随档位移动', curPct);

// 确定 → 落库，后续片段平移
await p.locator('#spdOk').click({ force: true });
await p.waitForTimeout(400);
const after = await p.evaluate(() => ({
  b: regions[0].b, a: regions[0].a, speed: regions[0].speed, bBase: regions[0].bBase,
  TOTAL, second_a: regions[1].a, third_a: regions[2].a,
}));
console.log('after:', JSON.stringify(after));
const oldLen = before.b - before.a, newLen = +(after.b - after.a).toFixed(2);
assert(Math.abs(newLen - oldLen / 2) < 0.02, '片段时长减半已落库', oldLen + 's → ' + newLen + 's');
assert(Math.abs(after.speed - 2) < 0.001, 'speed 字段=2', String(after.speed));
assert(after.second_a < before.second_a, '后续片段随之前移', before.second_a + ' → ' + after.second_a);
assert(Math.abs(after.TOTAL - (before.TOTAL - oldLen / 2)) < 0.05, 'TOTAL 同步减少',
  before.TOTAL + ' → ' + after.TOTAL);
assert(Math.abs((after.second_a - after.b)) < 0.02, '相邻片段仍首尾相接',
  'seg0.b=' + after.b + ' seg1.a=' + after.second_a);

// 再开面板 → 时长应基于原始时长(bBase)而非累积
await p.locator('#bottombar .bb[aria-label="变速"]').click({ force: true });
await p.waitForTimeout(300);
const durReopen = await p.locator('#spdDur').textContent();
assert(durReopen === expDur, '重开面板时长不累积(仍按原始时长)', durReopen);
const onReopen = await p.locator('#spdPanel .spd-step.on').textContent();
assert(onReopen === '2x', '重开面板回显当前档位 2x', onReopen);

// 取消不生效
await p.locator('#spdPanel .spd-step[data-v="4"]').click({ force: true });
await p.waitForTimeout(150);
await p.locator('#spdCancel').click({ force: true });
await p.waitForTimeout(300);
const afterCancel = await p.evaluate(() => regions[0].speed);
assert(afterCancel === 2, '「✕」取消不写库', 'speed=' + afterCancel);

// 应用到全部
await p.locator('#bottombar .bb[aria-label="变速"]').click({ force: true });
await p.waitForTimeout(300);
await p.locator('#spdPanel .spd-step[data-v="0.5"]').click({ force: true });
await p.waitForTimeout(150);
await p.locator('#spdAll').click({ force: true });
await p.waitForTimeout(400);
const allSpd = await p.evaluate(() => regions.map(r => r.speed));
assert(allSpd.every(s => s === 0.5), '「应用到全部」全部段落生效', allSpd.join(','));

// 录音轨变速应被拦
await p.evaluate(() => selectBlock('rec', recItems[0].id));
await p.waitForTimeout(250);
const recHasSpeed = await p.locator('#bottombar .bb[aria-label="变速"]').count();
assert(recHasSpeed === 0, '录音轨底栏无「变速」键');

console.log('\n========== 轨迹 ==========');
console.log(log.join('\n'));
console.log('\n========== 结果 ==========');
console.log(errs.length ? '❌ JS 错误: ' + [...new Set(errs)].join(' | ') : 'JS 错误: 无');
if (errors.length) { console.log(`❌ ${errors.length} 项失败：`); errors.forEach(e => console.log('  - ' + e)); }
else console.log('✅ 全部通过');
await b.close();
process.exit(errors.length || errs.length ? 1 : 0);
