/**
 * 自动化冒烟测试：遍历点击 index.html 所有可交互元素，捕获任何 JS 错误。
 * 用法：node smoke.mjs
 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
import path from 'path';

const FILE = pathToFileURL(
  'C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html'
).href;

const errors = [];
const log = [];
const currentScreen = { name: '(未进入)' };

function step(name, detail = '') {
  log.push(`  ${name}${detail ? ' — ' + detail : ''}`);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });

page.on('pageerror', e =>
  errors.push(`[pageerror] ${currentScreen.name} :: ${e.message.split('\n')[0]}`));
page.on('console', m => {
  if (m.type() === 'error') {
    errors.push(`[console.error] ${currentScreen.name} :: ${m.text()}`);
  }
});

await page.goto(FILE, { waitUntil: 'load' });
await page.waitForTimeout(400);

const screenOf = async () => {
  const s = await page.evaluate(() => {
    const a = document.querySelector('.screen.active');
    return a ? a.id : '(none)';
  });
  currentScreen.name = s;
  return s;
};

async function click(sel, label, { optional = false, wait = 260 } = {}) {
  const before = errors.length;
  const el = page.locator(sel).first();
  if (!(await el.count())) {
    if (!optional) errors.push(`[missing] 找不到元素: ${sel} (${label})`);
    else step(`跳过 ${label}`, '元素不存在');
    return false;
  }
  try {
    if (!(await el.isVisible())) {
      if (!optional) errors.push(`[invisible] 元素不可见: ${sel} (${label})`);
      else step(`跳过 ${label}`, '不可见');
      return false;
    }
    await el.click({ timeout: 3000, force: true });
    await page.waitForTimeout(wait);
    const n = errors.length;
    if (n > before) step(`✗ ${label}`, `触发 ${n - before} 个错误`);
    else step(`✓ ${label}`);
    return true;
  } catch (e) {
    errors.push(`[click-fail] ${label} (${sel}) :: ${e.message.split('\n')[0]}`);
    return false;
  }
}

/* ---------- 1. 遍历 nav 上所有页面按钮 ---------- */
const navBtns = await page.locator('.nav button').allTextContents();
step('nav 按钮', navBtns.join(' / '));
for (let i = 0; i < navBtns.length; i++) {
  const label = navBtns[i].trim();
  await page.locator('.nav button').nth(i).click({ force: true });
  await page.waitForTimeout(320);
  const s = await screenOf();
  const active = await page.locator('.screen.active').count();
  step(`nav「${label}」`, `→ ${s} (active=${active})`);
  if (active !== 1) errors.push(`[screen] 点 nav「${label}」后 active 屏数量 = ${active}`);
  // 抽屉类：点遮罩关闭
  if (await page.locator('.sheet-mask.show').count()) {
    await page.locator('.sheet-mask.show').first().click({ position: { x: 5, y: 5 }, force: true });
    await page.waitForTimeout(200);
    if (await page.locator('.sheet-mask.show').count()) {
      await page.keyboard.press('Escape').catch(() => {});
      await page.evaluate(() => document.querySelectorAll('.sheet-mask.show')
        .forEach(m => m.classList.remove('show')));
      step(`  ↳ 关闭抽屉 ${label}`);
    }
  }
}

/* ---------- 2. 起始页交互 ---------- */
await page.locator('.nav button').nth(0).click({ force: true });
await page.waitForTimeout(300);
await click('#selToggle', '起始页·选择');
await click('#selCancel', '起始页·取消');
await click('.fab', '起始页·新建 FAB');
await page.locator('.nav button').nth(0).click({ force: true });
await page.waitForTimeout(250);
await click('.start-grid .scard', '起始页·草稿卡片', { optional: true });

/* ---------- 3. 选视频页 ---------- */
await page.locator('.nav button').nth(1).click({ force: true });
await page.waitForTimeout(300);
await click('.pick-grid .pcard .pthumb', '选视频·选中一个');
await click('.filters .chip:nth-child(2)', '选视频·筛选 chip');
await click('.pick-foot #pickAdd', '选视频·添加按钮');
step('选视频后', await screenOf());

/* ---------- 4. 视频预览页 ---------- */
await page.locator('.nav button').nth(2).click({ force: true });
await page.waitForTimeout(320);
await click('#pvPP', '预览·播放/暂停');
await click('#pvPP', '预览·暂停/播放');
await click('#pvAdd', '预览·添加');
step('预览后', await screenOf());

/* ---------- 5. 片段选择页 ---------- */
await page.locator('.nav button').nth(5).click({ force: true });
await page.waitForTimeout(320);
await click('#clpPP', '片段选择·播放');
await click('#clpBack', '片段选择·返回');
step('片段选择后', await screenOf());

/* ---------- 6. 素材库页 ---------- */
await page.locator('.nav button').nth(4).click({ force: true });
await page.waitForTimeout(320);
await click('.lib-chips .chip:nth-child(2)', '素材库·筛选');
await click('.lib-grid .lcell:nth-child(2)', '素材库·选一个素材');
step('素材库后', await screenOf());

/* ---------- 7. 截取页 ---------- */
await page.locator('.nav button').nth(3).click({ force: true });
await page.waitForTimeout(320);
await click('#trimPlay', '截取·播放', { optional: true });
// 拖动把手
const hl = page.locator('#trimHandleL');
if (await hl.count()) {
  const b = await hl.boundingBox();
  if (b) {
    await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
    await page.mouse.down();
    await page.mouse.move(b.x + b.width / 2 + 40, b.y + b.height / 2, { steps: 6 });
    await page.mouse.up();
    await page.waitForTimeout(220);
    step('✓ 截取·拖左把手');
  }
}
const okInfo = await page.evaluate(() => {
  const b = document.getElementById('trimOk');
  if (!b) return 'missing';
  const r = b.getBoundingClientRect();
  return `${Math.round(r.width)}x${Math.round(r.height)}`;
});
step('截取·确定键', okInfo);
if (okInfo === '0x0' || okInfo === 'missing') errors.push(`[trim] 确定键异常: ${okInfo}`);
else { await click('#trimOk', '截取·确定'); step('截取后', await screenOf()); }
await click('#trimCancel', '截取·取消', { optional: true });

/* ---------- 8. 波形剪辑页 ---------- */
await page.locator('.nav button').nth(6).click({ force: true });
await page.waitForTimeout(360);
await click('#wcPlay', '波剪·播放/暂停');
// 点红绿切换
const seg = page.locator('#clpStrip, #wcWave');
await page.mouse.click(300, 700).catch(() => {});
step('波剪', await screenOf());

/* ---------- 9. 编辑页：重点测 ---------- */
await page.locator('.nav button').nth(7).click({ force: true });
await page.waitForTimeout(500);
step('编辑页', await screenOf());

// 三轨各点一个区块
const blocks = await page.evaluate(() => {
  const r = [];
  document.querySelectorAll('#trackStack .rblk').forEach((e, i) =>
    r.push({ kind: 'rec', i, x: e.offsetLeft, y: e.offsetTop }));
  return r.length;
});
step('录音轨区块数', blocks);

// 用 bounding box 点击
async function clickFirst(sel, label) {
  const el = page.locator(sel).first();
  if (!(await el.count())) { errors.push(`[missing] ${label}: ${sel}`); return; }
  const b = await el.boundingBox();
  if (!b) { errors.push(`[nobox] ${label}`); return; }
  const before = errors.length;
  await page.mouse.click(b.x + b.width / 2, b.y + b.height / 2);
  await page.waitForTimeout(300);
  const fbShown = await page.locator('#floatbar.show').count();
  const menuTxt = await page.locator('#floatbar .fi .tx').allTextContents().catch(() => []);
  step(`${fbShown ? '✓' : '✗'} ${label}`,
    `菜单=${fbShown ? '弹出' : '未弹出'} [${menuTxt.join(',')}]`);
  if (!fbShown) errors.push(`[menu] 点 ${label} 后悬浮菜单未弹出`);
  return fbShown;
}

await clickFirst('#trackStack .rblk', '录音轨区块');
await clickFirst('#trackStack .pblk', '画中画轨区块');
await clickFirst('#trackStack .thit', '主轨道区块');

// 点空白关闭菜单
{
  const before = errors.length;
  const box = await page.locator('.canvas').boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await page.waitForTimeout(300);
  const still = await page.locator('#floatbar.show').count();
  if (still) errors.push('[menu] 点空白后菜单未关闭');
  else step('✓ 点空白关闭菜单');
  if (errors.length > before) step('  ↳ 触发错误', String(errors.length - before));
}

// 主轨道左端两个键
await clickFirst('#trackStack .thit', '主轨道区块(再选)');
await click('#mainMute', '主轨·喇叭(静音)');
await click('#mainMute', '主轨·喇叭(取消静音)');
await click('#mainAdd', '主轨·摄像机(插入视频)');
step('插入流程后', await screenOf());
// 若进了选视频页 → 选片 → 截取 → 确定
if ((await screenOf()) === 'screen-picker') {
  await page.locator('.pick-grid .pcard .pthumb').first().click({ force: true });
  await page.waitForTimeout(250);
  await page.locator('.pick-foot #pickAdd').click({ force: true });
  await page.waitForTimeout(350);
  step('  ↳ 截取页', await screenOf());
  await page.locator('#trimOk').click({ force: true });
  await page.waitForTimeout(400);
  step('  ↳ 插入完成', await screenOf());
}

// 悬浮菜单 5 个键逐个点（重新选中主轨）
await clickFirst('#trackStack .thit', '主轨区块(测菜单)');
const fiLabels = await page.locator('#floatbar .fi .tx').allTextContents();
step('主轨菜单项', fiLabels.join(' / '));
for (let i = 0; i < fiLabels.length; i++) {
  const before = errors.length;
  await page.locator('#floatbar .fi').nth(i).click({ force: true });
  await page.waitForTimeout(320);
  if (errors.length > before) step(`✗ 菜单「${fiLabels[i]}」`, `触发 ${errors.length - before} 个错误`);
  else step(`✓ 菜单「${fiLabels[i]}」`);
  // 若跳到别的页，回到编辑页继续
  if ((await screenOf()) !== 'screen-editor') {
    await page.locator('.nav button').nth(7).click({ force: true });
    await page.waitForTimeout(350);
    await clickFirst('#trackStack .thit', '  ↳ 重新选中');
  }
}

// 播放控制条
for (const id of ['#pbPrev', '#pbPlay', '#pbNext', '#pbTune', '#pbUndo', '#pbRedo']) {
  await click(id, '播放条 ' + id);
}
// 底部工具栏全部
const bbCount = await page.locator('#bottombar .bb').count();
step('底部工具栏', bbCount + ' 项');
for (let i = 0; i < bbCount; i++) {
  const before = errors.length;
  await page.locator('#bottombar .bb').nth(i).click({ force: true });
  await page.waitForTimeout(240);
  const t = await page.locator('#bottombar .bb').nth(i).getAttribute('aria-label');
  if (errors.length > before) step(`✗ 底栏「${t}」`, `触发 ${errors.length - before} 个错误`);
  else step(`✓ 底栏「${t}」`);
  // 若该项打开了抽屉（底栏「导出」），记录后立即关闭，否则遮罩会挡住后续所有点击
  if (await page.locator('#exportMask.show').count()) {
    await page.evaluate(() => closeExport(true));
    await page.waitForTimeout(200);
    step('  ↳ 已关闭导出抽屉');
  }
  if ((await screenOf()) !== 'screen-editor') {
    await page.locator('.nav button').nth(7).click({ force: true });
    await page.waitForTimeout(300);
  }
}

// 拖动波形条滚动（从时间刻度区起拖，那里没有区块）
{
  if (await page.locator('#exportMask.show').count()) {
    await page.evaluate(() => closeExport(true));
    await page.waitForTimeout(200);
  }
  // 先收起录音浮层：它是刻意的可交互浮层(pointer-events:auto)，悬在时间轴底部会拦掉拖动起点。
  // 本段测的是「时间轴可拖动滚动」，不是录音，故先关掉（与 bar.mjs 的 gotoEditor 同处理）。
  if (await page.locator('#recPop.show').count()) {
    await page.locator('#bottombar .bb[aria-label="录音"]').click({ force: true });
    await page.waitForTimeout(200);
  }
  if (await page.locator('#recPop.show').count()) {
    await page.evaluate(() => { const p = document.getElementById('recPop'); if (p) p.classList.remove('show'); });
    await page.waitForTimeout(150);
  }
  const info = await page.evaluate(() => {
    const sc = document.getElementById('tlScroll');
    const r = sc.getBoundingClientRect();
    const ruler = document.querySelector('.m-ruler');
    const rr = ruler ? ruler.getBoundingClientRect() : null;
    return {
      x: r.x, y: r.y, w: r.width, h: r.height,
      rulerY: rr ? rr.y + rr.height / 2 : r.y + r.height - 10,
      maxScroll: (typeof maxScrollPx === 'function') ? maxScrollPx() : -1,
      viewW: (typeof viewW === 'function') ? viewW() : -1,
      contentW: (typeof contentW === 'function') ? contentW() : -1,
    };
  });
  step('滚动区尺寸', `view=${info.viewW} content=${info.contentW} maxScroll=${info.maxScroll}`);
  if (info.maxScroll <= 0) errors.push('[scroll] maxScrollPx=0，轨道无法滚动（内容宽度未超出视窗）');
  const hit = await page.evaluate(({ x, y }) => {
    const el = document.elementFromPoint(x, y);
    return el ? `${el.tagName}.${el.className}` : 'null';
  }, { x: info.x + info.w / 2, y: info.rulerY });
  step('拖动起点命中元素', hit);
  // 对照：直接改 tlScrollPx 调 applyScroll，看 transform 是否会变
  const direct = await page.evaluate(() => {
    const t0 = document.getElementById('trackStack').style.transform;
    applyScroll.call(null);
    window.__tl = 120; applyScroll();
    return { t0, t1: document.getElementById('trackStack').style.transform };
  });
  step('直接调 applyScroll', `${direct.t0} → ${direct.t1}`);
  await page.evaluate(() => { tlScrollPx = 0; applyScroll(); });
  const t0 = await page.evaluate(() => document.getElementById('trackStack').style.transform);
  await page.mouse.move(info.x + info.w / 2, info.rulerY);
  await page.mouse.down();
  await page.mouse.move(info.x + info.w / 2 - 90, info.rulerY, { steps: 8 });
  await page.mouse.up();
  await page.waitForTimeout(260);
  const t1 = await page.evaluate(() => document.getElementById('trackStack').style.transform);
  step(t0 !== t1 ? '✓ 拖动轨道滚动' : '✗ 拖动轨道无反应', `${t0} → ${t1}`);
  if (t0 === t1) errors.push('[scroll] 拖动轨道内容未滚动');
}

// 顶栏导出 → 抽屉（先强制回到编辑页并诊断）
await page.locator('.nav button').nth(7).click({ force: true });
await page.waitForTimeout(400);
const diag = await page.evaluate(() => {
  const t = document.querySelector('#screen-editor .topbar .ticon');
  const r = t ? t.getBoundingClientRect() : null;
  return {
    active: !!document.querySelector('#screen-editor.active'),
    found: !!t,
    box: r ? `${Math.round(r.width)}x${Math.round(r.height)} @${Math.round(r.x)},${Math.round(r.y)}` : 'null',
    editorActive: document.querySelectorAll('.screen.active').length,
  };
});
step('编辑页顶栏诊断', JSON.stringify(diag));
if (!diag.active) errors.push('[state] 测顶栏时编辑页非 active 状态');
await click('#screen-editor .topbar .ticon[onclick="openExport()"]', '顶栏·导出');
const drawer = await page.locator('#exportMask.show').count();
step(drawer ? '✓ 导出抽屉弹出' : '✗ 导出抽屉未弹出');
if (!drawer) errors.push('[export] 点顶栏导出，抽屉未弹出');
else {
  // 拖分辨率/帧率滑杆 + 音频开关
  for (const [sel, label] of [['#exRes', '分辨率滑杆'], ['#exFps', '帧率滑杆']]) {
    const b = await page.locator(sel).boundingBox();
    if (b) {
      const v0 = await page.locator(sel + 'Kn').boundingBox();
      await page.mouse.move(b.x + b.width - 4, b.y + b.height / 2);
      await page.mouse.down(); await page.mouse.move(b.x + 4, b.y + b.height / 2, { steps: 6 }); await page.mouse.up();
      await page.waitForTimeout(220);
      const v1 = await page.locator(sel + 'Kn').boundingBox();
      step(`${v0.x !== v1.x ? '✓' : '✗'} ${label}`, `x ${Math.round(v0.x)}→${Math.round(v1.x)}`);
      if (v0.x === v1.x) errors.push(`[export] ${label} 拖动无效`);
    }
  }
  const sizeTxt = await page.locator('#exSize').textContent();
  step('预计大小', sizeTxt);
  await click('#exAudio', '仅导出音频开关');
  const resVal = await page.locator('#exResVal').textContent();
  step('音频模式下的分辨率显示', resVal);
  if (resVal.trim() !== '—') errors.push('[export] 仅导出音频开启后分辨率未置灰');
  await click('#exAudio', '仅导出音频关闭');
  await click('#exportBtn', '导出按钮');
  await page.waitForTimeout(600);
  step('导出进度', (await page.locator('#pstage').textContent()) || '(空)');
}

// 收尾：再全屏点一遍 nav，确认没被前面操作带坏
for (let i = 0; i < navBtns.length; i++) {
  await page.locator('.nav button').nth(i).click({ force: true });
  await page.waitForTimeout(200);
}
step('nav 二次遍历完成');

await page.screenshot({ path: 'smoke-final.png', fullPage: false });
await browser.close();

console.log('\n========== 操作轨迹 ==========');
console.log(log.join('\n'));
console.log('\n========== 结果 ==========');
if (errors.length === 0) {
  console.log('✅ 全部通过，未捕获任何 JS 错误');
} else {
  console.log(`❌ 发现 ${errors.length} 个问题：`);
  [...new Set(errors)].forEach(e => console.log('  - ' + e));
}
process.exit(errors.length ? 1 : 0);
