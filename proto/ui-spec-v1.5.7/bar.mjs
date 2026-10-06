/**
 * 验证：上下文底部工具栏 + 自动蓝框 + 工具面板
 *  - 默认主轨 = 6 键（切割/波剪/音量/删除/变速/录音）
 *  - 拖动时间轴 → 自动蓝框框选中央指针下的主轨区块
 *  - 选中画中画 → 9 键；选中录音 → 5 键
 *  - 音量工具面板可打开/调节/应用（静音落标）
 *  - 画中画「替换」进入素材库流程
 * 用法：node bar.mjs
 */
import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
import path from 'path';

const FILE = pathToFileURL(
  'C:/Users/Administrator/WorkBuddy/2026-10-04-23-40-52/bk-clip-v15-ui/index.html'
).href;

const errors = [];
const log = [];
const assert = (cond, name, detail = '') => {
  if (cond) log.push(`  ✓ ${name}${detail ? ' — ' + detail : ''}`);
  else { errors.push(`[fail] ${name}${detail ? ' — ' + detail : ''}`); log.push(`  ✗ ${name}${detail ? ' — ' + detail : ''}`); }
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
page.on('pageerror', e => errors.push(`[pageerror] ${e.message.split('\n')[0]}`));
page.on('console', m => { if (m.type() === 'error') errors.push(`[console.error] ${m.text()}`); });

await page.goto(FILE, { waitUntil: 'load' });
await page.waitForTimeout(400);

const labels = async () => page.locator('#bottombar .bb').evaluateAll(els => els.map(e => e.getAttribute('aria-label')));
// 程序化选中某轨某块（绕过浮层遮挡坐标点击，直接走真实 selectBlock）
const selectTrack = async (kind) => {
  const ok = await page.evaluate((k) => {
    if (typeof selectBlock !== 'function') return false;
    const items = k === 'pip' ? pipItems : k === 'rec' ? recItems : regions;
    if (!items.length) return false;
    selectBlock(k, items[0].id);
    return true;
  }, kind);
  await page.waitForTimeout(300);
  return ok;
};
const gotoEditor = async () => {
  await page.locator('.nav button').nth(7).click({ force: true });
  await page.waitForTimeout(400);
  if (await page.locator('#recPop.show').count()) {
    await page.locator('#bottombar .bb[aria-label="录音"]').click({ force: true });
    await page.waitForTimeout(200);
  }
  if (await page.locator('#recPop.show').count()) {
    await page.evaluate(() => { const p = document.getElementById('recPop'); if (p) p.classList.remove('show'); });
    await page.waitForTimeout(150);
  }
};

/* 1. 默认主轨底部栏 = 10 键 */
await gotoEditor();
let bl = await labels();
assert(bl.length === 10, '默认主轨底栏键数', bl.length + ' → ' + bl.join('/'));
assert(JSON.stringify(bl) === JSON.stringify(
  ['切割', '波剪', '音量', '画面大小', '旋转', '左右镜像', '变速', '复制', '删除', '录音']),
  '默认主轨底栏顺序', bl.join('/'));

/* 2. 拖动时间轴 → 自动蓝框（确保 recPop 已关） */
const scrollInfo = await page.evaluate(() => {
  const sc = document.getElementById('tlScroll');
  const r = sc.getBoundingClientRect();
  return { x: r.x, y: r.y, w: r.width, h: r.height };
});
await page.mouse.move(scrollInfo.x + scrollInfo.w / 2, scrollInfo.y + 8);
await page.mouse.down();
await page.mouse.move(scrollInfo.x + scrollInfo.w / 2 - 120, scrollInfo.y + 8, { steps: 10 });
await page.mouse.up();
await page.waitForTimeout(300);
const afterDrag = await page.evaluate(() => {
  const t = document.getElementById('trackStack').style.transform;
  const f = document.querySelector('#thumbBody .tframe');
  return { t, frame: f ? getComputedStyle(f).display : 'none', count: document.querySelectorAll('#thumbBody .tframe').length };
});
assert(afterDrag.t && afterDrag.t !== 'translateX(0px)' && afterDrag.t !== '', '拖动时间轴后内容滚动', afterDrag.t);
assert(afterDrag.frame === 'block' && afterDrag.count === 1, '拖动后主轨自动蓝框出现',
  `display=${afterDrag.frame}, count=${afterDrag.count}`);

/* 3. 选中画中画 → 9 键 */
const pipOk = await selectTrack('pip');
assert(pipOk, '选中画中画');
if (pipOk) {
  bl = await labels();
  assert(bl.length === 9, '选中画中画后底栏键数', bl.length + ' → ' + bl.join('/'));
  assert(bl.includes('替换') && bl.includes('画面大小') && bl.includes('左右镜像'),
    '画中画底栏含替换/大小/镜像', bl.join('/'));
  const fb = await page.locator('#floatbar.show').count();
  assert(fb === 1, '画中画选中后悬浮菜单弹出');
}

/* 4. 选中录音 → 5 键 */
const recOk = await selectTrack('rec');
assert(recOk, '选中录音');
if (recOk) {
  bl = await labels();
  assert(bl.length === 5, '选中录音后底栏键数', bl.length + ' → ' + bl.join('/'));
  assert(bl.includes('复制') && bl.includes('录音') && !bl.includes('替换'),
    '录音底栏含复制/录音、无替换', bl.join('/'));
}

/* 5. 回到主轨，音量工具面板 */
assert(await selectTrack('main'), '回到主轨选中');
bl = await labels();
assert(bl.length === 10, '回到主轨后底栏恢复 10 键');
await page.locator('#bottombar .bb[aria-label="音量"]').click({ force: true });
await page.waitForTimeout(250);
let volOpen = await page.locator('#toolPanel.show').count();
let volLabel = await page.locator('#toolPanel .tp-label').textContent().catch(() => '');
assert(volOpen === 1, '点「音量」弹出工具面板');
assert(volLabel.includes('音量'), '工具面板标题为音量', volLabel);
{
  const tb = await page.locator('#tpTrack').boundingBox();
  if (tb) {
    await page.mouse.move(tb.x + tb.width - 4, tb.y + tb.height / 2);
    await page.mouse.down();
    await page.mouse.move(tb.x + 4, tb.y + tb.height / 2, { steps: 6 });
    await page.mouse.up();
    await page.waitForTimeout(150);
  }
  await page.locator('#tpOk').click({ force: true });
  await page.waitForTimeout(250);
  const badge = await page.locator('#thumbBody .tmutebadge').count();
  assert(badge >= 1, '音量调至 0 后主轨出现静音标', 'badge=' + badge);
}

/* 6. 变速面板（v1.5.6 起为专用离散档位面板，详见 spd.mjs） */
await page.locator('#bottombar .bb[aria-label="变速"]').click({ force: true });
await page.waitForTimeout(200);
let spd = await page.locator('#spdPanel.show').count();
assert(spd === 1, '点「变速」弹出离散档位面板');
await page.locator('#spdCancel').click({ force: true }).catch(() => {});
await page.waitForTimeout(150);

/* 6.5 主轨画面类：画面大小 / 旋转 / 左右镜像（v1.5.5 新增到主轨） */
await page.locator('#bottombar .bb[aria-label="画面大小"]').click({ force: true });
await page.waitForTimeout(250);
let szLabel = await page.locator('#toolPanel .tp-label').textContent().catch(() => '');
assert((await page.locator('#toolPanel.show').count()) === 1 && szLabel.includes('画面大小'),
  '主轨点「画面大小」弹出面板', szLabel);
await page.locator('#tpCancel').click({ force: true }).catch(() => {});
await page.waitForTimeout(150);
await page.locator('#bottombar .bb[aria-label="旋转"]').click({ force: true });
await page.waitForTimeout(250);
let tf = await page.evaluate(() => document.querySelector('.canvas .frame-img').style.transform);
assert(tf.includes('rotate(90deg)'), '主轨「旋转」→ 预览旋转 90°', tf || '(空)');
await page.locator('#bottombar .bb[aria-label="左右镜像"]').click({ force: true });
await page.waitForTimeout(250);
tf = await page.evaluate(() => document.querySelector('.canvas .frame-img').style.transform);
assert(tf.includes('scaleX(-1)'), '主轨「左右镜像」→ 预览左右镜像', tf || '(空)');

/* 7. 画中画「替换」→ 进素材库 */
assert(await selectTrack('pip'), '重新选中画中画');
await page.locator('#bottombar .bb[aria-label="替换"]').click({ force: true });
await page.waitForTimeout(300);
const inLib = await page.evaluate(() => !!document.querySelector('#screen-lib.active'));
assert(inLib, '画中画点「替换」进入素材库');
if (inLib) {
  await page.locator('#libClose').click({ force: true }).catch(() => {});
  await page.waitForTimeout(200);
}

await page.screenshot({ path: 'bar-final.png', fullPage: false });
await browser.close();

console.log('\n========== 验证轨迹 ==========');
console.log(log.join('\n'));
console.log('\n========== 结果 ==========');
if (errors.length === 0) console.log('✅ 全部通过');
else { console.log(`❌ ${errors.length} 项失败：`); [...new Set(errors)].forEach(e => console.log('  - ' + e)); }
process.exit(errors.length ? 1 : 0);
