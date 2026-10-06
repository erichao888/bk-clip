import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 1000 } });
const errs = [];
p.on('pageerror', e => errs.push('pageerror: ' + e.message.split('\n')[0]));
p.on('console', m => { if (m.type() === 'error') errs.push('console: ' + m.text().slice(0, 100)); });
await p.goto(FILE, { waitUntil: 'load' });
await p.waitForTimeout(500);

const state = () => p.evaluate(() => {
  const m = document.getElementById('exportMask');
  const sh = document.querySelector('#exportMask .sheet');
  const r = sh ? sh.getBoundingClientRect() : null;
  return { mask: m ? m.classList.contains('show') : false,
           sheet: sh ? sh.classList.contains('show') : false,
           w: r ? Math.round(r.width) : 0, h: r ? Math.round(r.height) : 0 };
});
const close = async () => { await p.evaluate(() => closeExport(true)); await p.waitForTimeout(300); };
const nav = async i => { await p.locator('.nav button').nth(i).click({ force: true }); await p.waitForTimeout(420); };

console.log('构建号:', await p.evaluate(() => window.BUILD));
console.log('起始页版本行:', (await p.locator('#buildFoot').textContent()).trim());

const labels = await p.locator('.nav button').allTextContents();
// ★ 底栏已按需求重组为「按轨道上下文」的 6/5/9 键，导出键已移出底栏，
//   故此处只保留 nav 与顶栏两个入口（底栏入口由 bar.mjs 覆盖）。
const paths = [
  ['nav「导出面板」', async () => nav(labels.findIndex(t => t.includes('导出')))],
  ['编辑页顶栏 ⬆',   async () => { await nav(7); await p.locator('#screen-editor .topbar .ticon[onclick="openExport()"]').click({ force: true }); await p.waitForTimeout(400); }],
];
let bad = 0;
for (const [name, act] of paths) {
  await close();
  await act();
  const s = await state();
  const ok = s.mask && s.sheet && s.w > 100 && s.h > 100;
  if (!ok) bad++;
  console.log(`${ok ? '✓' : '✗'} ${name}  mask=${s.mask} sheet=${s.sheet} ${s.w}x${s.h}`);
}
// 附加校验：底栏已按新规划重组，默认主轨 6 键且不含「导出」
await close();
await nav(7);
const bbLabels = await p.locator('#bottombar .bb').evaluateAll(els => els.map(e => e.getAttribute('aria-label')));
const noExport = bbLabels.length === 10 && !bbLabels.includes('导出');
if (!noExport) bad++;
console.log(`${noExport ? '✓' : '✗'} 底栏已重组为 10 键且不含「导出」 — ${bbLabels.join('/')}`);

console.log(errs.length ? '错误: ' + [...new Set(errs)].join(' | ') : '错误: 无');
await b.close();
process.exit(bad ? 1 : 0);
