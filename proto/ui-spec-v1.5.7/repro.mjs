import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;
const b = await chromium.launch();

for (const [label, url] of [['file://', FILE], ['http://', 'http://127.0.0.1:10789/static-html/cb5896873ef9b355/index.html']]) {
  const p = await b.newPage({ viewport: { width: 1280, height: 1000 } });
  const errs = [];
  p.on('pageerror', e => errs.push('pageerror: ' + e.message.split('\n')[0]));
  p.on('console', m => { if (m.type() === 'error') errs.push('console: ' + m.text().slice(0, 120)); });
  try {
    await p.goto(url, { waitUntil: 'load', timeout: 15000 });
    await p.waitForTimeout(500);

    // 完全模拟用户：点 nav 最右「导出面板」
    const navLabels = await p.locator('.nav button').allTextContents();
    const idx = navLabels.findIndex(t => t.includes('导出'));
    await p.locator('.nav button').nth(idx).click({ force: true });
    await p.waitForTimeout(700);

    const st = await p.evaluate(() => {
      const mask = document.getElementById('exportMask');
      const sh = document.querySelector('#exportMask .sheet');
      const cs = sh ? getComputedStyle(sh) : null;
      const r = sh ? sh.getBoundingClientRect() : null;
      const mr = mask ? mask.getBoundingClientRect() : null;
      // 命中测试：面板中心点最上层是什么
      const hit = r && r.width ? (() => {
        const e = document.elementFromPoint(r.x + r.width / 2, r.y + 40);
        return e ? `${e.tagName}.${e.className}` : 'null';
      })() : 'n/a';
      return {
        maskClass: mask ? mask.className : 'no-mask',
        maskDisplay: mask ? getComputedStyle(mask).display : '-',
        maskRect: mr ? `${Math.round(mr.width)}x${Math.round(mr.height)}` : '-',
        sheetClass: sh ? sh.className : 'no-sheet',
        sheetDisplay: cs ? cs.display : '-',
        sheetRect: r ? `${Math.round(r.width)}x${Math.round(r.height)} @${Math.round(r.x)},${Math.round(r.y)}` : '-',
        hitTest: hit,
        activeScreen: document.querySelector('.screen.active')?.id,
      };
    });
    console.log(`\n===== ${label} =====`);
    Object.entries(st).forEach(([k, v]) => console.log('  ' + k.padEnd(14), v));
    if (errs.length) { console.log('  错误:'); [...new Set(errs)].forEach(e => console.log('    - ' + e)); }
    else console.log('  错误: 无');
  } catch (e) {
    console.log(`\n===== ${label} ===== 加载失败: ${e.message.split('\n')[0]}`);
  }
  await p.close();
}
await b.close();
