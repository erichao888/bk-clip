import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 1000 } });
p.on('pageerror', e => console.log('[ERR]', e.message.split('\n')[0]));
await p.goto(FILE, { waitUntil: 'load' });
await p.waitForTimeout(400);
const labels = await p.locator('.nav button').allTextContents();
await p.locator('.nav button').nth(labels.findIndex(t => t.includes('波形'))).click({ force: true });
await p.waitForTimeout(700);

console.log('初始', await p.evaluate(() => ({ wcScroll, wcView: +wcView.toFixed(2),
  red: wcSeg.reduce((a,v)=>a+v,0), segD: +WC_SEGD.toFixed(4), PPS: WC_PPS })));
const box = await p.locator('#wcWave').boundingBox();
for (const frac of [0.15, 0.30, 0.50, 0.72]) {
  const x = box.x + box.width * frac;
  const before = await p.evaluate(() => wcSeg.reduce((a,v)=>a+v,0));
  await p.mouse.click(x, box.y + box.height / 2);
  await p.waitForTimeout(260);
  const st = await p.evaluate(() => ({
    red: wcSeg.reduce((a,v)=>a+v,0), scroll: +wcScroll.toFixed(2),
    toast: document.getElementById('toast').textContent }));
  console.log(`点${(frac*100).toFixed(0)}% (x偏移${Math.round(box.width*frac)}px)  red ${before}→${st.red}  wcScroll=${st.scroll}  toast="${st.toast}"`);
}
await b.close();
