# -*- coding: utf-8 -*-
"""
从 proto/draft-board.html 的 defaults() 里读布局，渲染出静态预览
proto/layout-preview.html

草稿板是唯一真源 —— 皓哥在上面拖完、导出 JSON 更新 defaults()，
跑一次这个脚本就出新图，不用手画 SVG。

这次把它升级成「对照图」：左边横版素材、右边竖版素材，
用来确认预览区自适应.Height 的规则对不对。

用法：
    python tools/render_layout_preview.py
"""
import io
import os
import re
import sys
import math
import copy

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOARD = os.path.join(ROOT, 'proto', 'draft-board.html')
OUT = os.path.join(ROOT, 'proto', 'layout-preview.html')

W, H = 430, 932
NAVY = '#1A1A1A'
BASE_PREVIEW_H = 310      # 草稿板里画面区的基准高度（对应 1:1 附近）
PREVIEW_MIN, PREVIEW_MAX = 200, 350
TRACK_MIN, TRACK_MAX = 130, 300

C = dict(
    page='#F7F7F4', nav='#F1F1EE', preview='#141414', track='#C7D8BD',
    wave='#24430F', cut='#D6707A', gold='#F09A28', ovBg='#8F9389',
    ovWave='#4C5049', text='#1A1A1A', text2='#5F5E5A', line='#D1D1D6',
    btn='#FFFFFF', status='#EFEFEB', edited='#C0392B', curRow='#FDF6E9',
)


# ---------------------------------------------------------------- 读布局
def read_items():
    src = io.open(BOARD, encoding='utf-8').read()
    m = re.search(r'function defaults\(\)\{[\s\S]*?\n  \}', src)
    if not m:
        sys.exit('找不到 defaults()，draft-board.html 结构变了？')
    rows = re.findall(
        r"\{id:'(\w+)',\s*name:'([^']*)',\s*kind:'(\w+)',\s*x:(-?\d+),\s*y:(-?\d+),"
        r"\s*w:(-?\d+),\s*h:(-?\d+)(?:,\s*icon:'(\w+)')?", m.group(0))
    out = []
    for i, nm, k, x, y, w, h, ic in rows:
        out.append(dict(id=i, name=nm, kind=k, x=int(x), y=int(y),
                        w=int(w), h=int(h), icon=ic or ''))
    return out


def preview_height(aw, ah):
    """按素材真实显示比例算预览区高度，再夹到 [下限, 上限]"""
    ar = float(aw) / float(ah)
    raw = 398.0 / ar
    return int(max(PREVIEW_MIN, min(PREVIEW_MAX, round(raw))))


def layout_for(items, aw, ah):
    """
    画面变矮省出来的空间全部补给主轨道，反过来也一样。
    结果：画面与轨道之间（数字行）跟着平移，轨道之后的东西一律不动，
    工具栏永远贴底。屏幕总高度守恒，不会挤出 ｉｌｌｅｇａｌ 空白。
    """
    out = copy.deepcopy(items)
    h = preview_height(aw, ah)
    delta = h - BASE_PREVIEW_H
    seen_preview = seen_track = False
    for it in out:
        if it['id'] == 'preview':
            it['h'] = h
            seen_preview = True
            continue
        if not seen_preview:
            continue
        if it['id'] in ('track', 'pointer'):
            it['y'] += delta
            it['h'] = int(max(TRACK_MIN, min(TRACK_MAX, it['h'] - delta)))
            seen_track = True
            continue
        if not seen_track:
            it['y'] += delta
    return out


# ---------------------------------------------------------------- 文案
TEXT = {
    'navTitle': 'IMG_3027.MOV',
    'tTime':    '00:18 / 00:42',
    'tStat':    '6 刀 · 删 5.4s → 剩 36.6s',
    'thTitle':  '检测阈值',
    'status':   '就绪 · 已切 6 刀',
}

ICONS = {
    'undo':     '<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
    'redo':     '<path d="M15 14l5-5-5-5"/><path d="M20 9H10a6 6 0 0 0 0 12h3"/>',
    'stop':     '<rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor" stroke="none"/>',
    'play':     '<path d="M7 4l13 8-13 8z" fill="currentColor" stroke="none"/>',
    # 联播（跳过红区只播绿区，拼起来播）：E 方案，三角夹在两条竖线中间
    'skip':     '<line x1="5.5" y1="6" x2="5.5" y2="18"/>'
                '<path d="M9 6l7 6-7 6z" fill="currentColor" stroke="none"/>'
                '<line x1="18.5" y1="6" x2="18.5" y2="18"/>',
    'loop':     '<path d="M5 12a7 7 0 0 1 14 0"/><path d="M19 12a7 7 0 0 1-14 0"/>'
                '<path d="M16 9l3 3 3-3"/><path d="M8 15l-3-3-3 3"/>',
    'scissors': '<circle cx="6.5" cy="6.5" r="3"/><circle cx="6.5" cy="17.5" r="3"/>'
                '<line x1="8.6" y1="8.6" x2="17" y2="16"/><line x1="17" y1="8" x2="8.6" y2="16"/>',
    'dropper':  '<path d="M18 3l3 3-9 9-4 1 1-4z"/><path d="M15 6l3 3"/>',
    'list':     '<line x1="3" y1="6.5" x2="21" y2="6.5"/><line x1="3" y1="12" x2="21" y2="12"/>'
                '<line x1="3" y1="17.5" x2="21" y2="17.5"/>',
    'export':   '<path d="M12 3v12"/><path d="M8 7l4-4 4 4"/><path d="M4 15v4h16v-4"/>',
    'minus':    '<line x1="5" y1="12" x2="19" y2="12"/>',
    'plus':     '<line x1="5" y1="12" x2="19" y2="12"/><line x1="12" y1="5" x2="12" y2="19"/>',
}


def icon(cx, cy, size, key, stroke=1.9, color=NAVY):
    s = size / 24.0
    return ('<g transform="translate(%.1f,%.1f) scale(%.4f)" fill="none" stroke="%s" '
            'stroke-width="%.2f" stroke-linecap="round" stroke-linejoin="round">%s</g>'
            % (cx - size / 2.0, cy - size / 2.0, s, color, stroke / s, ICONS[key]))


# ---------------------------------------------------------------- 波形
DUR = 42.0
SCREENS = 2.0
GAPS = [(3.2, 4.1), (9.5, 10.6), (17.2, 18.0), (25.8, 26.9), (33.1, 34.2), (39.5, 40.3)]
TC = 18.0


def in_gap(t, pad=0.35):
    return any(a - pad <= t <= b + pad for a, b in GAPS)


def build_wave_track(it):
    pps = it['w'] / (DUR / SCREENS)
    cx = it['x'] + it['w'] / 2.0
    cy = it['y'] + it['h'] / 2.0
    half = it['h'] / 2.0 - 12

    def amp(px):
        t = (px - cx) / pps + TC
        if t < 0 or t > DUR:
            return 0.05
        if in_gap(t):
            return 0.09 + 0.05 * abs(math.sin(px * 1.7))
        return max(0.14, min(1.0, (0.55 + 0.45 * math.sin(px * 0.42) * math.sin(px * 0.13 + 1.1))
                              * abs(math.sin(px * 0.77))))

    out = []
    x = it['x'] + 3
    step, bw = 5, 3
    while x + bw <= it['x'] + it['w'] - 3:
        bh = max(2.0, amp(x + bw / 2.0) * half * 2)
        out.append('<rect x="%.1f" y="%.1f" width="%d" height="%.1f" rx="1.5"/>'
                   % (x, cy - bh / 2, bw, bh))
        x += step
    return ''.join(out), pps, cx


def build_wave_overview(it):
    cy = it['y'] + it['h'] / 2.0
    half = it['h'] / 2.0 - 4

    def amp(px):
        t = (px - it['x']) / it['w'] * DUR
        if in_gap(t):
            return 0.18
        return max(0.25, min(1.0, 0.45 + 0.5 * abs(math.sin(px * 0.9)) * abs(math.sin(px * 0.31 + 2.0))))

    out = []
    x = it['x'] + 2
    while x + 2 <= it['x'] + it['w'] - 2:
        bh = max(2.0, amp(x) * half * 2)
        out.append('<rect x="%.1f" y="%.1f" width="2" height="%.1f" rx="1"/>' % (x, cy - bh / 2, bh))
        x += 4
    return ''.join(out)


SHEET_ROWS = [('IMG_3027.MOV', 1, 1), ('IMG_3028.MOV', 0, 0), ('IMG_3029.MOV', 1, 0),
              ('IMG_3030.MOV', 0, 0), ('IMG_3031.MOV', 1, 0)]


# ---------------------------------------------------------------- 画
def render(items, aw, ah, show_sheet=False):
    g = {i['id']: i for i in items}
    s = []
    A = s.append

    A('<svg viewBox="0 0 %d %d" width="%d" height="%d" xmlns="http://www.w3.org/2000/svg" '
      'font-family="-apple-system,\'PingFang SC\',\'Microsoft YaHei\',sans-serif">'
      % (W, H, W, H))
    A('<rect width="%d" height="%d" rx="22" fill="%s"/>' % (W, H, C['page']))

    for x in (16, 414):
        A('<line x1="%d" y1="100" x2="%d" y2="890" stroke="#C9A227" stroke-width="0.6" '
          'stroke-dasharray="4 5" opacity="0.6"/>' % (x, x))

    # 状态栏
    sb = 47
    A('<rect width="%d" height="%d" rx="22" fill="%s"/>' % (W, sb + 22, C['status']))
    A('<rect y="%d" width="%d" height="24" fill="%s"/>' % (sb - 2, W, C['status']))
    A('<text x="26" y="30" font-size="13" font-weight="500" fill="%s">9:41</text>' % C['text'])
    A('<text x="%d" y="30" font-size="13" fill="%s" text-anchor="middle">bk剪辑</text>' % (W / 2, C['text2']))

    # 导航栏
    nav = g.get('nav')
    if nav:
        A('<rect y="%d" width="%d" height="%d" fill="%s"/>'
          % (nav['y'], W, nav['h'], C['nav']))
        A('<line x1="0" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="0.8"/>'
          % (nav['y'] + nav['h'], W, nav['y'] + nav['h'], C['line']))
    nl = g.get('navList')
    if nl:
        A(icon(nl['x'] + nl['w'] / 2, nl['y'] + nl['h'] / 2, 18, 'list', stroke=1.7))
    nt = g.get('navTitle')
    if nt:
        A('<text x="%d" y="%d" font-size="16" font-weight="500" fill="%s" text-anchor="middle">%s</text>'
          % (nt['x'] + nt['w'] / 2, nt['y'] + 13, C['text'], TEXT['navTitle']))
    ne = g.get('navExp')
    if ne:
        A(icon(ne['x'] + 8, ne['y'] + ne['h'] / 2, 17, 'export', stroke=1.7))
        A('<text x="%d" y="%d" font-size="15" fill="%s">%s</text>' % (ne['x'] + 22, ne['y'] + 13, C['text'], '导出'))

    # 画面（按素材比例 letterbox）
    pv = g.get('preview')
    if pv:
        box_w, box_h = float(pv['w']), float(pv['h'])
        ar = float(aw) / float(ah)
        if box_w / box_h > ar:
            vh, vw = box_h, box_h * ar
        else:
            vw, vh = box_w, box_w / ar
        vx = pv['x'] + (box_w - vw) / 2.0
        vy = pv['y'] + (box_h - vh) / 2.0
        A('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="%s"/>'
          % (pv['x'], pv['y'], pv['w'], pv['h'], C['preview']))
        A('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="4" fill="#1F1F1F" '
          'stroke="#333333" stroke-width="0.8"/>' % (vx, vy, vw, vh))
        cx, cy = vx + vw / 2, vy + vh / 2
        rr = min(vw, vh)
        A('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#FFFFFF" opacity="0.14"/>' % (cx, cy, min(30.0, rr * 0.22)))
        A(icon(cx + 1, cy, min(26.0, rr * 0.2), 'play', stroke=0.1, color='#FFFFFF'))
        A('<text x="%.1f" y="%.1f" font-size="12" fill="#FFFFFF" opacity="0.5" text-anchor="end">'
          '%d:%d 原片</text>' % (vx + vw - 10, vy + vh - 10, aw, ah))

    # 数字行
    tt = g.get('tTime')
    if tt:
        A('<text x="%d" y="%d" font-size="20" font-weight="500" fill="%s" '
          'font-family="ui-monospace,Menlo,Consolas,monospace">%s</text>'
          % (tt['x'], tt['y'] + 15, C['text'], TEXT['tTime']))
    ts = g.get('tStat')
    if ts:
        A('<text x="%d" y="%d" font-size="13" fill="%s" text-anchor="end">%s</text>'
          % (ts['x'] + ts['w'], ts['y'] + 14, C['text2'], TEXT['tStat']))

    # 主轨道
    tr = g.get('track')
    if tr:
        A('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="%s"/>'
          % (tr['x'], tr['y'], tr['w'], tr['h'], C['track']))
        A('<clipPath id="ct%d"><rect x="%d" y="%d" width="%d" height="%d" rx="10"/></clipPath>'
          % (aw, tr['x'], tr['y'], tr['w'], tr['h']))
        wave, pps, cx = build_wave_track(tr)
        A('<g clip-path="url(#ct%d)" fill="%s">%s</g>' % (aw, C['wave'], wave))
        A('<g clip-path="url(#ct%d)">' % aw)
        for a, b in GAPS:
            x0, x1 = (a - TC) * pps + cx, (b - TC) * pps + cx
            if x1 < tr['x'] or x0 > tr['x'] + tr['w']:
                continue
            A('<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="%s" opacity="0.55"/>'
              % (x0, tr['y'], x1 - x0, tr['h'], C['cut']))
            for hx in (x0, x1):
                A('<rect x="%.1f" y="%.1f" width="4" height="8" rx="1.5" fill="#FFFFFF" '
                  'stroke="#B06068" stroke-width="0.8"/>' % (hx - 2, tr['y'] + tr['h'] / 2.0 - 4))
        A('</g>')

    pt = g.get('pointer')
    if pt:
        A('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>'
          % (pt['x'], pt['y'], pt['w'], pt['h'], C['gold']))
        A('<path d="M%d %d l-6 -7 l12 0 z" fill="%s"/>' % (pt['x'] + 1, pt['y'], C['gold']))

    # 概览条
    ov = g.get('overview')
    if ov:
        A('<rect x="%d" y="%d" width="%d" height="%d" rx="6" fill="%s"/>'
          % (ov['x'], ov['y'], ov['w'], ov['h'], C['ovBg']))
        A('<clipPath id="co%d"><rect x="%d" y="%d" width="%d" height="%d" rx="6"/></clipPath>'
          % (aw, ov['x'], ov['y'], ov['w'], ov['h']))
        A('<g clip-path="url(#co%d)" fill="%s">%s</g>' % (aw, C['ovWave'], build_wave_overview(ov)))
        A('<g clip-path="url(#co%d)">' % aw)
        for a, b in GAPS:
            A('<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="%s" opacity="0.75"/>'
              % (ov['x'] + a / DUR * ov['w'], ov['y'], (b - a) / DUR * ov['w'], ov['h'], C['cut']))
        A('</g>')
        win = ov['w'] / SCREENS
        wx = ov['x'] + (TC - DUR / SCREENS / 2) / DUR * ov['w']
        A('<rect x="%.1f" y="%d" width="%.1f" height="%d" rx="4" fill="none" stroke="%s" '
          'stroke-width="2"/>' % (wx, ov['y'], win, ov['h'], C['gold']))

    # 阈值 / 状态
    th = g.get('thTitle')
    if th:
        A('<text x="%d" y="%d" font-size="13" fill="%s">%s</text>'
          % (th['x'], th['y'] + 18, C['text2'], TEXT['thTitle']))
    sl = g.get('thSlider')
    if sl:
        A('<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="%s"/>'
          % (sl['x'], sl['y'], sl['w'], sl['h'], C['line']))
        A('<circle cx="%d" cy="%d" r="11" fill="#FFFFFF" stroke="%s" stroke-width="1"/>'
          % (sl['x'] + int(sl['w'] * 0.62), sl['y'] + sl['h'] / 2, C['line']))
    st = g.get('status')
    if st:
        A('<text x="%d" y="%d" font-size="13" fill="%s">%s</text>'
          % (st['x'], st['y'] + 13, C['text2'], TEXT['status']))

    # 工具栏
    tb = g.get('toolbar')
    if tb:
        A('<rect x="%d" y="%d" width="%d" height="%d" rx="12" fill="%s"/>'
          % (tb['x'], tb['y'], tb['w'], tb['h'], C['nav']))
    for i in items:
        if i['kind'] != 'btn' or i['id'] == 'navList' or i['icon'] not in ICONS:
            continue
        A('<circle cx="%d" cy="%d" r="%d" fill="%s" stroke="%s" stroke-width="1"/>'
          % (i['x'] + i['w'] / 2, i['y'] + i['h'] / 2, i['w'] / 2, C['btn'], C['line']))
        A(icon(i['x'] + i['w'] / 2, i['y'] + i['h'] / 2, i['w'] * 0.48, i['icon']))

    # ☰ 素材列表面板
    if show_sheet:
        sh = g.get('sheet')
        if sh:
            A('<rect x="%d" y="%d" width="%d" height="%d" rx="12" fill="#FFFFFF" '
              'stroke="%s" stroke-width="1"/>' % (sh['x'], sh['y'], sh['w'], sh['h'], C['line']))
            for n, (nm, edited, cur) in enumerate(SHEET_ROWS):
                ry = sh['y'] + 4 + n * 44
                if cur:
                    A('<rect x="%d" y="%d" width="%d" height="44" fill="%s"/>'
                      % (sh['x'] + 1, ry, sh['w'] - 2, C['curRow']))
                    A('<rect x="%d" y="%d" width="3" height="44" fill="%s"/>' % (sh['x'] + 1, ry, C['gold']))
                col = C['edited'] if edited else C['text']
                A('<text x="%d" y="%d" font-size="15" fill="%s">%s</text>' % (sh['x'] + 20, ry + 28, col, nm))
                if cur:
                    A('<g transform="translate(%d,%d) scale(0.62)" fill="none" stroke="%s" '
                      'stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round">'
                      '<path d="M4 13l6 6L21 5"/></g>' % (sh['x'] + sh['w'] - 40, ry + 12, C['gold']))
            A('<text x="%d" y="%d" font-size="11" fill="#9A9A96" text-anchor="middle">'
              '上下滑看第 6 条往后</text>' % (sh['x'] + sh['w'] / 2, sh['y'] + sh['h'] - 8))

    A('<rect x="%d" y="%d" width="140" height="5" rx="2.5" fill="#000000" opacity="0.22"/>'
      % ((W - 140) / 2, H - 8))
    A('</svg>')
    return ''.join(s)


def overflow_check(items):
    bad = []
    for i in items:
        if i['x'] < 0 or i['y'] < 0 or i['x'] + i['w'] > W or i['y'] + i['h'] > H:
            bad.append(i['id'])
    return bad


PAGE = u"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>bk剪辑 · 界面预览（拍板版）</title>
<style>
 body{margin:0;background:#EEEEEC;color:#1A1A1A;
      font:13px/1.6 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
 h1{font-size:15px;font-weight:500;margin:0}
 .sub{font-size:12px;color:#5F5E5A;margin-top:2px}
 header{padding:12px 18px;background:#fff;border-bottom:1px solid #D8D8D4}
 main{display:flex;gap:16px;padding:16px;align-items:flex-start;flex-wrap:wrap}
 .sh{flex:0 0 auto;background:#fff;border:1px solid #D8D8D4;border-radius:14px;padding:8px}
 .shbox{width:281px;height:610px}
 .sh svg{display:block;width:430px;height:932px;transform:scale(.655);transform-origin:top left}
 .cap{text-align:center;font-size:12px;color:#5F5E5A;margin-top:6px}
 .cap b{display:block;font-size:13px;color:#1A1A1A;font-weight:500}
 aside{flex:1 1 300px;min-width:290px;display:flex;flex-direction:column;gap:12px}
 .card{background:#fff;border:1px solid #D8D8D4;border-radius:12px;padding:13px 15px}
 .card h2{font-size:13px;font-weight:500;margin:0 0 9px}
 ul{margin:0;padding-left:17px}li{margin-bottom:6px}li:last-child{margin-bottom:0}
 table{border-collapse:collapse;width:100%;font-size:12px}
 th,td{text-align:right;padding:3px 6px;border-bottom:1px solid #EDEDE9}
 th{color:#5F5E5A;font-weight:400}td.k,td.n{text-align:left;color:#5F5E5A}
 td.k{font:11px ui-monospace,Consolas,monospace}
 .sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
 .red{color:#C0392B}
</style></head><body>
<header>
  <h1>bk剪辑 · 界面预览（拍板版）</h1>
  <div class="sub">左边横版素材 16:9，右边竖版素材 9:16 —— 同一份布局草稿，只有画面区和主轨道的高度在变</div>
</header>
<main>
  <div class="sh"><div class="shbox">__LEFT__</div>
    <div class="cap"><b>横版 16:9</b>画面 224 · 轨道 256</div></div>
  <div class="sh"><div class="shbox">__RIGHT__</div>
    <div class="cap"><b>竖版 9:16</b>画面封顶 350 · 轨道 130</div></div>
  <aside>
    <div class="card">
      <h2>这轮拍板的四条</h2>
      <ul>
        <li><b>预览区</b>按素材比例自动变高，夹在 <b>200 ~ 350</b>。省出来的空间全给主轨道</li>
        <li><b>列表里的红</b>用 <code>#C0392B</code>（气口那个粉当正文太浅）</li>
        <li><b>拖轨道松手就停在那</b>；<b>播放中一拖就暂停</b>，不续播</li>
        <li><b>− + 排进第二排</b>，28pt 小圆，右边缘跟第一排对齐</li>
      </ul>
    </div>
    <div class="card">
      <h2>动 / 静的规则</h2>
      <ul>
        <li>拖轨道、捏合缩放、点概览条 → <b>画面动，不出声</b></li>
        <li>点 ▶ → 从橙指针处<b>有声</b>起播</li>
        <li>播放中手一碰轨道 → <b>立即暂停</b>，画面停在手指松开那帧</li>
      </ul>
    </div>
    <div class="card">
      <h2>列表颜色</h2>
      <div><span class="sw" style="background:#C0392B"></span><span class="red">IMG_3027</span> 切过了</div>
      <div><span class="sw" style="background:#F09A28"></span>当前这条（左边金竖条 + ✓）</div>
      <div><span class="sw" style="background:#1A1A1A"></span>IMG_3028 没动过，默认色</div>
    </div>
    <div class="card">
      <h2>坐标（横版 16:9 那一版）</h2>
      <table>
        <tr><th style="text-align:left">id</th><th style="text-align:left">元素</th><th>x</th><th>y</th><th>w</th><th>h</th></tr>
        __ROWS__
      </table>
    </div>
  </aside>
</main>
</body></html>"""


def main():
    items = read_items()
    left = layout_for(items, 16, 9)
    right = layout_for(items, 9, 16)

    for tag, itt in (('横版', left), ('竖版', right)):
        bad = overflow_check(itt)
        print('%s：%d 个元素%s' % (tag, len(itt), ('，越界：' + ','.join(bad)) if bad else '，无越界'))

    rows = ''.join(
        '<tr><td class="k">%s</td><td class="n">%s</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td></tr>'
        % (i['id'], i['name'], i['x'], i['y'], i['w'], i['h']) for i in left)

    html = (PAGE.replace('__LEFT__', render(left, 16, 9))
                .replace('__RIGHT__', render(right, 9, 16, show_sheet=True))
                .replace('__ROWS__', rows))
    io.open(OUT, 'w', encoding='utf-8').write(html)
    print('->', OUT)


if __name__ == '__main__':
    main()
