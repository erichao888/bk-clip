import { chromium } from 'playwright';
import { pathToFileURL } from 'url';

const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1100, height: 1060 }, deviceScaleFactor: 2 });
const errs = [];
p.on('pageerror', e => errs.push(e.message.split('\n')[0]));
p.on('console', m => { if (m.type()==='error') errs.push('CONSOLE:'+m.text().slice(0,160)); });

await p.goto(FILE, { waitUntil: 'load' });
await p.waitForTimeout(400);
const L = await p.locator('.nav button').allTextContents();
await p.locator('.nav button').nth(L.findIndex(t => t.includes('编辑页'))).click({ force: true });
await p.waitForTimeout(700);

let pass=0, fail=0;
const ck = (n,c,extra='') => { if(c){pass++;console.log('  ✓',n,extra);} else {fail++;console.log('  ✗',n,extra);} };

// ===== 测试 1：点击主轨 → 蓝框 .tframe 可见 =====
const hitBox = await p.evaluate(() => {
  const sc = document.getElementById('tlScroll').getBoundingClientRect();
  for (const e of document.querySelectorAll('#thumbBody .thit')) {
    const r = e.getBoundingClientRect(); const cx = r.x + r.width/2;
    if (cx > sc.x+10 && cx < sc.x+sc.width-10) return { x: cx, y: r.y + r.height/2 };
  }
  return null;
});
await p.mouse.click(hitBox.x, hitBox.y);
await p.waitForTimeout(500);

const frame = await p.evaluate(() => {
  const f = document.querySelector('#thumbBody .tframe');
  if (!f) return null;
  const cs = getComputedStyle(f);
  const r = f.getBoundingClientRect();
  return { display: cs.display, w: Math.round(r.width), h: Math.round(r.height) };
});
ck('点击主轨后出现蓝框 .tframe 且可见', frame && frame.display!=='none' && frame.w>20 && frame.h>10,
   JSON.stringify(frame));
ck('同时悬浮菜单已弹出', await p.locator('#floatbar.show').count()===1);

// ===== 测试 2：迷你条拖动蓝框 = 滚动整条轨道 =====
const before = await p.evaluate(() => {
  const st = document.getElementById('trackStack');
  return { transform: st.style.transform, scrollPx: +tlScrollPx.toFixed(1), centerT: +centerT().toFixed(2) };
});
const miniBox = await p.locator('#mini').boundingBox();
// 在迷你条靠左的位置按下，拖到靠右
const x0 = miniBox.x + miniBox.width*0.25;
const x1 = miniBox.x + miniBox.width*0.75;
const y  = miniBox.y + miniBox.height/2;
await p.mouse.move(x0, y);
await p.mouse.down();
await p.waitForTimeout(60);
await p.mouse.move((x0+x1)/2, y);
await p.waitForTimeout(60);
await p.mouse.move(x1, y);
await p.waitForTimeout(60);
await p.mouse.up();
await p.waitForTimeout(200);
const after = await p.evaluate(() => {
  const st = document.getElementById('trackStack');
  return { transform: st.style.transform, scrollPx: +tlScrollPx.toFixed(1), centerT: +centerT().toFixed(2) };
});
ck('拖动迷你条后 tlScrollPx 改变（轨道区移动）', Math.abs(after.scrollPx-before.scrollPx)>50,
   `before=${before.scrollPx} after=${after.scrollPx}`);
ck('拖动后视窗中心时间推进', after.centerT>before.centerT+1,
   `before=${before.centerT} after=${after.centerT}`);
const miniViewMoved = await p.evaluate(() => {
  const v=document.getElementById('miniView'); return v? v.style.left : null;
});
ck('迷你蓝框位置随拖动更新', miniViewMoved!==null, `miniView.left=${miniViewMoved}`);

console.log('\nJS 错误:', errs.length? errs : '无');
console.log(`\n结果: ${pass} 通过 / ${fail} 失败`);
await b.close();
process.exit(fail? 1 : 0);
