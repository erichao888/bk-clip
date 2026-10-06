/** 录音流程验收 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;
const errors = [], out = [];
let pass = 0, fail = 0;
const say = s => out.push(s);
const ck = (l, c, d = '') => { c ? (pass++, say(`   ✓ ${l}${d ? ' — ' + d : ''}`)) : (fail++, say(`   ✗ ${l}${d ? ' — ' + d : ''}`)); };

const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 1000 } });
p.on('pageerror', e => errors.push('[JS] ' + e.message.split('\n')[0]));
p.on('console', m => { if (m.type() === 'error') errors.push('[console] ' + m.text().slice(0, 110)); });
await p.goto(FILE, { waitUntil: 'load' });
await p.waitForTimeout(400);
const labels = await p.locator('.nav button').allTextContents();
await p.locator('.nav button').nth(labels.findIndex(t => t.includes('编辑页'))).click({ force: true });
await p.waitForTimeout(600);

const S = () => p.evaluate(() => ({
  state: recState, elapsed: +recElapsed.toFixed(1), peaks: recPeaks.length,
  recN: recItems.length,
  recN2: recItems.filter(x => x.fmt).length,
  recLast: (() => { const x = [...recItems].reverse().find(v => v.fmt); return x ? {
    src: x.src, fmt: x.fmt, size: x.size,
    dur: +(x.b - x.a).toFixed(2), a: +x.a.toFixed(2) } : null; })(),
  pop: document.getElementById('recPop').classList.contains('show'),
  btn: document.getElementById('recBtn').className,
  cnt: document.getElementById('recCnt').textContent,
  live: document.getElementById('recLive').classList.contains('show'),
  scroll: Math.round(tlScrollPx),
  TOTAL: +TOTAL.toFixed(2),
  fmt: recFmtText(),
}));
const recBtn = p.locator('#recBtn');
const bb = await p.locator('#recBtn').boundingBox().catch(() => null);

say('═'.repeat(60));
say('录音流程验收 · 点按 / 长按 / 实时波形 / 轨道滚动');
say('═'.repeat(60));
say('格式配置：' + (await S()).fmt);

say('① 底栏点「录音」键 → 原地弹出大按钮');
await p.locator('#bottombar .bb[aria-label="录音"]').click({ force: true });
await p.waitForTimeout(400);
let s = await S();
ck('浮层已弹出', s.pop);
const popBox = await p.locator('#recPop').boundingBox();
const bigBox = await p.locator('#recBtn').boundingBox();
const bbSize = await p.locator('#bottombar .bb[aria-label="录音"]').boundingBox();
ck('录音按钮比底栏键大', bigBox.width > bbSize.width,
   `大按钮 ${Math.round(bigBox.width)}pt vs 底栏键 ${Math.round(bbSize.width)}pt`);
ck('浮层在底栏上方', popBox.y + popBox.height <= bbSize.y + 2,
   `浮层底 ${Math.round(popBox.y + popBox.height)} / 底栏顶 ${Math.round(bbSize.y)}`);

say('② 短按 → 红圈 2 秒倒计时');
const before = await S();
await p.mouse.move(bigBox.x + bigBox.width / 2, bigBox.y + bigBox.height / 2);
await p.mouse.down();
await p.waitForTimeout(90);
await p.mouse.up();
await p.waitForTimeout(300);
s = await S();
ck('进入倒计时态', s.state === 'counting', 'state=' + s.state);
ck('按钮有 counting 样式', s.btn.includes('counting'), s.btn);
ck('倒计时显示 2', s.cnt.trim() === '2', 'cnt=' + s.cnt);
await p.waitForTimeout(1100);
s = await S();
ck('倒计时递减到 1', s.cnt.trim() === '1', 'cnt=' + s.cnt);

say('③ 倒计时结束 → 自动开始录音');
await p.waitForTimeout(1200);
s = await S();
ck('状态=recording', s.state === 'recording', 'state=' + s.state);
ck('按钮有 recording 样式', s.btn.includes('recording'), s.btn);
ck('录音中浮条出现', s.live);
ck('已新建录音片段', s.recN === before.recN + 1, `${before.recN} → ${s.recN}`);
const ptrT = await p.evaluate(() => +recT0.toFixed(2));
ck('从指针处开始（a=指针时间）', Math.abs(s.recLast.a - ptrT) < 0.3,
   `片段 a=${s.recLast.a}s / 录音起点 ${ptrT}s`);

say('④ 录音中：轨道滚动 + 实时波形');
const sc0 = (await S()).scroll;
await p.waitForTimeout(1300);
s = await S();
ck('时长在累加', s.elapsed > 1.0, s.elapsed + 's');
ck('波形峰值在累积', s.peaks > 8, s.peaks + ' 个采样');
ck('★ 轨道同步滚动', s.scroll > sc0, `${sc0} → ${s.scroll}px`);
ck('指针仍在可视区中央', await p.evaluate(() => {
  const h = document.getElementById('tlPlay').getBoundingClientRect();
  const w = document.getElementById('tlScroll').getBoundingClientRect();
  return Math.abs((h.x + h.width / 2) - (w.x + w.width / 2)) <= 2;
}));

say('⑤ 再点一次 → 停止并落段');
const nBefore = (await S()).recN;
const bb2 = await p.locator('#recBtn').boundingBox();
await p.mouse.click(bb2.x + bb2.width / 2, bb2.y + bb2.height / 2);
await p.waitForTimeout(600);
s = await S();
ck('状态回到 idle', s.state === 'idle', 'state=' + s.state);
ck('★ 录音段已落到录音轨', s.recN2 === 1, `录音段 ${s.recN2} 条`);
ck('★ 片段有时长', s.recLast.dur > 0.2, s.recLast.dur + 's');
ck('★ 片段带格式标注', /WAV|AAC/.test(s.recLast.fmt), s.recLast.fmt);
ck('★ 片段带体积', !!s.recLast.size, s.recLast.size);
ck('新片段被自动选中', await p.evaluate(() => selTrack === 'rec' && recSelId != null),
   await p.evaluate(() => `selTrack=${selTrack}`));
ck('录音块 DOM 存在', await p.locator('#recBody .rblk').count() >= s.recN,
   `${await p.locator('#recBody .rblk').count()} 个`);

say('⑥ 长按 → 跳过倒计时直接录');
if (!(await S()).pop) { await p.locator('#bottombar .bb[aria-label="录音"]').click({ force: true }); await p.waitForTimeout(350); }
const bb3 = await p.locator('#recBtn').boundingBox();
const nB2 = (await S()).recN;
await p.mouse.move(bb3.x + bb3.width / 2, bb3.y + bb3.height / 2);
await p.mouse.down();
await p.waitForTimeout(520);                    // 超过 300ms 阈值
s = await S();
ck('长按 0.5s 已开录（短按需 2s+，此处远早于倒计时结束）', s.state === 'recording',
   `state=${s.state}, elapsed=${s.elapsed}s（按下 0.52s 即开录）`);
const el0 = s.elapsed;
await p.waitForTimeout(700);
say('⑦ 松开 → 停止');
await p.mouse.up();
await p.waitForTimeout(600);
s = await S();
ck('松开后停止', s.state === 'idle', 'state=' + s.state);
ck('★ 长按段已落轨', s.recN2 === 2, `录音段 ${s.recN2} 条`);
ck('长按段时长合理(0.5~1.5s)', s.recLast.dur > 0.4 && s.recLast.dur < 1.8, s.recLast.dur + 's');

say('⑧ 点浮层外 → 关闭浮层');
ck('录完后浮层仍保持打开（可连录）', (await S()).pop);
await p.locator('.canvas').click({ force: true });
await p.waitForTimeout(300);
ck('点空白后关闭', !(await S()).pop);

say('⑨ 全局无 JS 错误');
ck('未捕获任何错误', errors.length === 0, errors.slice(0, 3).join(' | '));

say('═'.repeat(60));
say(`结果：${pass} 项通过，${fail} 项失败`);
if (errors.length) [...new Set(errors)].forEach(e => say('  ! ' + e));
say('═'.repeat(60));
await p.screenshot({ path: 'rec-final.png' });
await b.close();
console.log(out.join('\n'));
process.exit(fail || errors.length ? 1 : 0);
