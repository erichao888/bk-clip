/**
 * 剪辑师工作流验收测试
 * 角色：从导入素材 → 剪辑 → 导出，跑 3 条真实业务流，每步断言业务结果。
 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';

const FILE = pathToFileURL('C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html').href;

const errors = [];
const out = [];
let pass = 0, fail = 0;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
page.on('pageerror', e => errors.push(`[JS] ${e.message.split('\n')[0]}`));
page.on('console', m => { if (m.type() === 'error') errors.push(`[console] ${m.text().slice(0, 110)}`); });

await page.goto(FILE, { waitUntil: 'load' });
await page.waitForTimeout(400);

const say = s => out.push(s);
/** 读业务状态 */
const S = () => page.evaluate(() => ({
  screen: document.querySelector('.screen.active')?.id,
  regions: regions.length,
  TOTAL: +TOTAL.toFixed(2),
  selId: selectedId,
  selTrack,
  muted: regions.filter(r => r.muted).length,
  locked: regions.filter(r => r.locked).length,
  firstSrc: regions[0] ? regions[0].src : '',
  firstLen: regions[0] ? +(regions[0].b - regions[0].a).toFixed(2) : 0,
  pip: pipItems.length,
  rec: recItems.length,
  wcRed: wcSeg.reduce((a, v) => a + v, 0),
  scroll: Math.round(tlScrollPx),
  expSize: document.getElementById('exSize')?.textContent || '',
  drawer: !!document.querySelector('#exportMask.show .sheet'),
  menu: [...document.querySelectorAll('#floatbar.show .fi .tx')].map(e => e.textContent),
}));

/** 断言 */
function ck(label, cond, detail = '') {
  if (cond) { pass++; say(`   ✓ ${label}${detail ? ' — ' + detail : ''}`); }
  else { fail++; say(`   ✗ ${label}${detail ? ' — ' + detail : ''}`); }
}
const click = async (sel, label, opt = {}) => {
  const el = page.locator(sel).first();
  if (!(await el.count())) { say(`   ✗ ${label} — 找不到 ${sel}`); fail++; return false; }
  if (!(await el.isVisible())) { if (!opt.optional) { say(`   ✗ ${label} — 不可见`); fail++; } return false; }
  await el.click({ force: true, timeout: 3000 });
  await page.waitForTimeout(opt.wait ?? 340);
  return true;
};
async function menuPick(label) {
  const items = page.locator('#floatbar.show .fi');
  const n = await items.count();
  for (let i = 0; i < n; i++) {
    const t = (await items.nth(i).locator('.tx').textContent()).trim();
    if (t === label) { await items.nth(i).click({ force: true }); await page.waitForTimeout(400); return true; }
  }
  say(`   ✗ 菜单里找不到「${label}」（现有：${await page.locator('#floatbar.show .fi .tx').allTextContents()}）`);
  fail++; return false;
}
const nav = async i => { await page.locator('.nav button').nth(i).click({ force: true }); await page.waitForTimeout(430); };

/** 网格项安全点击：滚入视口 + 强制点（网格在折叠滚动容器里，直点可能判定不可见） */
async function gridClick(sel, idx) {
  const el = page.locator(sel).nth(idx);
  if (!(await el.count())) return false;
  await el.scrollIntoViewIfNeeded().catch(() => {});
  await page.waitForTimeout(120);
  await el.click({ force: true, timeout: 3000 });
  await page.waitForTimeout(260);
  return true;
}


/** 像真人一样：只点「当前视口内看得见」的区块（轨道会横向滚动，屏外的块点不到） */
async function pickBlock(kind, nth = 0) {
  const info = await page.evaluate(({ k, n }) => {
    const sc = document.getElementById('tlScroll').getBoundingClientRect();
    const els = [...document.querySelectorAll('#trackStack .' + k)];
    let seen = 0;
    for (const e of els) {
      const r = e.getBoundingClientRect();
      const cx = r.x + r.width / 2;
      if (cx > sc.x + 10 && cx < sc.x + sc.width - 10) {
        if (seen === n) return { x: cx, y: r.y + r.height / 2, w: Math.round(r.width) };
        seen++;
      }
    }
    return null;
  }, { k: kind, n: nth });
  if (!info) { say(`   ✗ 视口内找不到第 ${nth} 个可见 ${kind}`); fail++; return null; }
  await page.mouse.click(info.x, info.y);
  await page.waitForTimeout(430);
  return info;
}

const navLabels = await page.locator('.nav button').allTextContents();
const navGo = async kw => nav(navLabels.findIndex(t => t.includes(kw)));
const closeDrawer = async () => { if (await page.locator('#exportMask.show').count()) { await page.evaluate(() => closeExport(true)); await page.waitForTimeout(220); } };

/* ══════════════════════════════════════════════
   流程 1：口播剪辑主流程（导入 → 上锁 → 复制 → 删除 → 静音 → 波剪 → 导出）
   ══════════════════════════════════════════════ */
say('═'.repeat(66));
say('流程 1 · 口播剪辑主流程');
say('═'.repeat(66));
await navGo('起始页');
say('① 起始页');
let s = await S();
ck('起始页加载', s.screen === 'screen-start', s.screen);
ck('草稿网格有内容', await page.locator('.start-grid > *').count() > 0);

say('② 新建 → 选视频页');
await click('#fabNew', '点 ＋ 新建');
s = await S();
ck('进入选视频页', s.screen === 'screen-picker', s.screen);
const nCards = await page.locator('.pick-grid .pcard').count();
ck('素材列表有卡片', nCards > 0, nCards + ' 张');

say('③ 勾选 3 段口播素材');
for (const i of [0, 1, 2]) await gridClick('.pick-grid .pcard .pthumb', i);
const cnt = await page.locator('#pickCount').textContent();
ck('已选计数 = 3', cnt.trim() === '3', '计数=' + cnt);
ck('底部按钮文案', (await page.locator('#pickAdd').textContent()).includes('3'), await page.locator('#pickAdd').textContent());

say('④ 添加 → 进编辑页');
await click('.pick-foot #pickAdd', '点「添加 3 条」');
s = await S();
ck('进入编辑页', s.screen === 'screen-editor', s.screen);
const nThumbs = await page.locator('#trackStack .thit').count();
ck('主轨有区块', nThumbs > 0, nThumbs + ' 段');
ck('录音/画中画演示数据在', s.rec === 3 && s.pip === 3, `录音${s.rec}/画中画${s.pip}`);

say('⑤ 点第 1 段 → 悬浮菜单弹出');
await pickBlock('thit', 0);
s = await S();
ck('菜单已弹出', s.menu.length === 5, s.menu.join('/'));
ck('主轨菜单内容正确', s.menu.join('/') === '替换/波剪/上锁/复制/删除', s.menu.join('/'));
const selBox = await page.evaluate(() => {
  const f = document.querySelector('.tframe');
  if (!f || f.style.display === 'none') return null;
  return f.getBoundingClientRect();
});
ck('选中区块有蓝框', !!selBox, selBox ? `${Math.round(selBox.width)}x${Math.round(selBox.height)}` : '无');

say('⑥ 上锁该段');
const before = await S();
await menuPick('上锁');
s = await S();
ck('锁定数 +1', s.locked === before.locked + 1, `${before.locked} → ${s.locked}`);
ck('上锁后菜单仍在', s.menu.length === 5);

say('⑦ 复制第 2 段');
await menuPick('上锁').catch(() => {});
await pickBlock('thit', 0);
const beforeDup = await S();
await menuPick('复制');
s = await S();
ck('段数 +1', s.regions === beforeDup.regions + 1, `${beforeDup.regions} → ${s.regions}`);
ck('总时长增加', s.TOTAL > beforeDup.TOTAL, `${beforeDup.TOTAL}s → ${s.TOTAL}s`);
ck('复制体被自动选中', s.selId !== beforeDup.selId, `sel ${beforeDup.selId} → ${s.selId}`);

say('⑧ 删除复制体');
await menuPick('删除');
s = await S();
ck('段数回退', s.regions === beforeDup.regions, `${s.regions} 段`);
ck('总时长回退', Math.abs(s.TOTAL - beforeDup.TOTAL) < 0.01, `${s.TOTAL}s`);

say('⑨ 静音第 3 段（主轨左端喇叭）');
await pickBlock('thit', 0);
const beforeMute = await S();
await click('#mainMute', '点喇叭（静音指针处）');
s = await S();
ck('静音数变化', s.muted !== beforeMute.muted, `${beforeMute.muted} → ${s.muted}`);
await click('#mainMute', '再点喇叭（取消静音）', { wait: 300 });
s = await S();
ck('取消静音恢复', s.muted === beforeMute.muted, `${s.muted}`);

say('⑩ 波剪：标记 2 处气口');
await menuPick('波剪');
await page.waitForTimeout(700);
s = await S();
ck('进入波剪页', s.screen === 'screen-wcut', s.screen);
const beforeRed = (await S()).wcRed;
const wave = await page.locator('#wcWave').boundingBox();
let flips = 0;
for (const frac of [0.30, 0.50, 0.72]) {
  const b0 = (await S()).wcRed;
  await page.mouse.click(wave.x + wave.width * frac, wave.y + wave.height / 2);
  await page.waitForTimeout(300);
  const a0 = (await S()).wcRed;
  if (Math.abs(a0 - b0) === 1) flips++;
  say(`     · 点 ${(frac*100).toFixed(0)}% → 红区 ${b0}→${a0}（${a0>b0?'标红':'标绿'}）`);
}
ck('三次点击每次都精确翻转 1 段', flips === 3, `${flips}/3`);
ck('指针固定中央（波剪页）', await page.evaluate(() => {
  const h = document.getElementById('wcHead').getBoundingClientRect();
  const w = document.getElementById('wcWave').getBoundingClientRect();
  return Math.abs((h.x + h.width/2) - (w.x + w.width/2)) <= 2;
}));

say('⑪ 回编辑页 → 导出');
await navGo('编辑页');
await closeDrawer();
await click('#screen-editor .topbar .ticon[onclick="openExport()"]', '顶栏 ⬆ 导出');
s = await S();
ck('导出抽屉已弹出', s.drawer);
ck('预计大小非空', /\d/.test(s.expSize), s.expSize);
const meta = await page.locator('#exportNote, .ex-size .v').first().textContent().catch(() => '');
ck('面板含「仅导出音频」', await page.locator('#exAudio').isVisible());
ck('面板含分辨率滑杆', await page.locator('#exRes').isVisible());
ck('面板含帧率滑杆', await page.locator('#exFps').isVisible());
await closeDrawer();

/* ══════════════════════════════════════════════
   流程 2：换镜头（替换素材，时长必须不变）
   ══════════════════════════════════════════════ */
say('');
say('═'.repeat(66));
say('流程 2 · 换镜头（替换素材 · 时长锁定）');
say('═'.repeat(66));
await navGo('编辑页');
await page.locator('#trackStack .thit').nth(1).click({ force: true });
await page.waitForTimeout(420);
const b4 = await S();
const srcBefore = await page.evaluate(() => regions.map(r => r.src));
const lenBefore = await page.evaluate(() => regions.map(r => +(r.b - r.a).toFixed(2)));
say(`   替换前素材：${srcBefore.join(' / ')}`);
await menuPick('替换');
s = await S();
ck('进入素材库页', s.screen === 'screen-lib', s.screen);
ck('素材库有网格', await page.locator('.lib-grid .lcell').count() > 0);
await gridClick('.lib-grid .lcell', 4);
s = await S();
ck('选素材后进入预览页', s.screen === 'screen-preview', s.screen);
await click('#pvAdd', '预览页点「添加」');
s = await S();
ck('进入片段选择页', s.screen === 'screen-clip', s.screen);
const lockTip = (await page.locator('#clpTip').textContent()).trim();
ck('★ 提示时长已锁定', lockTip.includes('锁定'), lockTip);
await click('#clpOk', '点「完成」');
await page.waitForTimeout(520);
s = await S();
ck('回到编辑页', s.screen === 'screen-editor', s.screen);
const srcAfter = await page.evaluate(() => regions.map(r => r.src));
const lenAfter = await page.evaluate(() => regions.map(r => +(r.b - r.a).toFixed(2)));
const changed = srcAfter.filter((v, i) => v !== srcBefore[i]).length;
ck('★ 恰好一个片段的素材名被换掉', changed === 1, `变化 ${changed} 个：${srcBefore[srcAfter.findIndex((v,i)=>v!==srcBefore[i])]} → ${srcAfter[srcAfter.findIndex((v,i)=>v!==srcBefore[i])]}`);
ck('★ 目标片段已换成新素材', srcAfter.some(v => v.startsWith('VID_')), srcAfter.join(' / '));
ck('★ 每个片段时长都没变', JSON.stringify(lenBefore) === JSON.stringify(lenAfter), lenAfter.join('/') + 's');
ck('段数未变', s.regions === b4.regions, `${b4.regions} → ${s.regions}`);

/* ══════════════════════════════════════════════
   流程 3：插入素材 + 画中画/录音轨操作
   ══════════════════════════════════════════════ */
say('');
say('═'.repeat(66));
say('流程 3 · 插入素材 + 侧轨操作');
say('═'.repeat(66));
await navGo('编辑页');
const b5 = await S();
say('⑰ 摄像机插入视频');
await click('#mainAdd', '主轨左端摄像机');
s = await S();
ck('进入选视频页', s.screen === 'screen-picker', s.screen);
ck('标题变「插入视频」', (await page.locator('#pickTitle').textContent()).trim() === '插入视频');
await gridClick('.pick-grid .pcard .pthumb', 5);
await click('.pick-foot #pickAdd', '点「截取并插入」');
s = await S();
ck('进入截取页', s.screen === 'screen-trim', s.screen);
await click('#trimOk', '点 ✓ 插入');
await page.waitForTimeout(520);
s = await S();
ck('回到编辑页', s.screen === 'screen-editor', s.screen);
ck('★ 段数 +1', s.regions === b5.regions + 1, `${b5.regions} → ${s.regions}`);
ck('★ 总时长增加', s.TOTAL > b5.TOTAL, `${b5.TOTAL}s → ${s.TOTAL}s`);

say('⑱ 画中画轨：选中 → 菜单应换成画中画内容');
await page.locator('.canvas').click({ force: true });   // 真人会先点空白关掉主轨菜单
await page.waitForTimeout(300);
await pickBlock('pblk', 0);
s = await S();
ck('选中轨 = pip', s.selTrack === 'pip', s.selTrack);
ck('画中画菜单内容', s.menu.join('/') === '替换/切开/上锁/复制/删除', s.menu.join('/'));

say('⑲ 录音轨：选中 → 菜单应换成录音内容');
await page.locator('.canvas').click({ force: true });
await page.waitForTimeout(300);
await pickBlock('rblk', 0);
s = await S();
ck('选中轨 = rec', s.selTrack === 'rec', s.selTrack);
ck('录音菜单内容', s.menu.join('/') === '切开/音量/上锁/复制/删除', s.menu.join('/'));

say('⑳ 点空白 → 菜单关闭');
await page.locator('.canvas').click({ force: true });
await page.waitForTimeout(340);
s = await S();
ck('菜单已关闭', s.menu.length === 0, '菜单项=' + s.menu.length);

say('㉑ 指针固定中央：点不同区块，滚动位置应不同但指针不动');
const ptr = await page.evaluate(() => {
  const p = document.getElementById('tlPlay').getBoundingClientRect();
  const sc = document.getElementById('tlScroll').getBoundingClientRect();
  return { ptrMid: Math.round(p.x + p.width / 2), scrollMid: Math.round(sc.x + sc.width / 2) };
});
ck('指针在可视区正中', Math.abs(ptr.ptrMid - ptr.scrollMid) <= 2, `指针${ptr.ptrMid} / 视窗中${ptr.scrollMid}`);

await page.locator('.canvas').click({ force: true });
await page.waitForTimeout(300);
await pickBlock('pblk', 0);
const s2 = await S();
const alignInfo = await page.evaluate(() => {
  const sc = document.getElementById('tlScroll').getBoundingClientRect();
  const mid = sc.x + sc.width / 2;
  const f = document.querySelector('#trackStack .psel');
  if (!f || getComputedStyle(f).display === 'none') return null;
  const r = f.getBoundingClientRect();
  return { off: Math.round(r.x + r.width / 2 - mid), scroll: Math.round(tlScrollPx), max: Math.round(maxScrollPx()) };
});
// 滚动到边界时无法真正居中（夹紧），此时只要区块仍在视口内即可
const atEdge = alignInfo && (alignInfo.scroll <= 0 || alignInfo.scroll >= alignInfo.max - 1);
ck('★ 选中区块对齐指针（边界处允许夹紧）',
   alignInfo !== null && (Math.abs(alignInfo.off) <= 3 || atEdge),
   alignInfo === null ? '无选框' : `偏差 ${alignInfo.off}px, scroll=${alignInfo.scroll}/${alignInfo.max}${atEdge ? ' (已到边界)' : ''}`);
const ptr2 = await page.evaluate(() => {
  const p = document.getElementById('tlPlay').getBoundingClientRect();
  return Math.round(p.x + p.width / 2);
});
ck('★ 滚动后指针仍在正中', ptr2 === ptr.ptrMid, `${ptr.ptrMid} → ${ptr2}`);

say('㉒ 导出：开启「仅导出音频」后分辨率应置灰');
await pickBlock('thit', 0);
await click('#screen-editor .topbar .ticon[onclick="openExport()"]', '顶栏 ⬆ 导出', { wait: 500 });
s = await S();
ck('抽屉弹出', s.drawer);
await click('#exAudio', '仅导出音频开关');
const resVal = (await page.locator('#exResVal').textContent()).trim();
const resOff = await page.locator('#exResWrap').evaluate(e => e.classList.contains('off'));
ck('分辨率值显示「—」', resVal === '—', resVal);
ck('分辨率行已置灰', resOff);
await click('#exAudio', '再关一次');
ck('恢复后分辨率有值', (await page.locator('#exResVal').textContent()).trim() !== '—');
await closeDrawer();

/* ══════════════════════════════════════════════ */
say('');
say('═'.repeat(66));
say(`结果：${pass} 项通过，${fail} 项失败`);
if (errors.length) {
  say('');
  say('捕获的 JS 错误：');
  [...new Set(errors)].forEach(e => say('  - ' + e));
} else say('JS 错误：无');
say('═'.repeat(66));

await page.screenshot({ path: 'wf-final.png' });
await browser.close();
console.log(out.join('\n'));
process.exit(fail || errors.length ? 1 : 0);
