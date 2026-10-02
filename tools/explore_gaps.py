# -*- coding: utf-8 -*-
"""
气口候选池普查（Windows / Python）
==================================

preview_cut.py 是「跟 Swift 端逐项对齐」的实现，不能随便往里塞调试代码。
分析、找规律、改参数的事全部在这个脚本里做。

它回答的问题是：这四个样片里，到底藏了多少「低幅段」，它们各自多长、多深、
紧贴的人声有多响 —— 也就是搞清楚候选池长什么样，再回头改算法。

用法：
    python tools/explore_gaps.py                 全部样片
    python tools/explore_gaps.py IMG_4580        只跑一条
    python tools/explore_gaps.py --html          额外出一张候选标记的波形图
"""
import os
import re
import sys
import json
import subprocess

import numpy as np

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLES = os.path.join(ROOT, "samples")

SR = 16000
FRAME_MS = 20.0
HOP_MS = 10.0

# 候选普查用的阈值阶梯：从松到紧
THRS = [-45.0, -40.0, -35.0, -32.0, -30.0, -28.0, -25.0]
SIDE = 0.30          # 看邻域人声取多长
PAD_NOW = 0.10       # 现有算法的气口两端留白
MIN_CUT_NOW = 0.10
MIN_GAP_NOW = 0.20
MIN_SEG_NOW = 0.60


def ffmpeg_exe():
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"


FF = ffmpeg_exe()


def read_pcm(path):
    cmd = [FF, "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        print("[错误] ffmpeg 读取失败：", r.stderr.decode("utf-8", "ignore")[:600])
        sys.exit(1)
    return np.frombuffer(r.stdout, dtype="<i2").astype(np.float32) / 32768.0


def envelope_db(x):
    frame = max(1, int(SR * FRAME_MS / 1000.0))
    hop = max(1, int(SR * HOP_MS / 1000.0))
    n = len(x)
    c = np.concatenate(([0.0], np.cumsum(x.astype(np.float64) ** 2)))
    starts = np.arange(0, n - frame + 1, hop)
    rms = np.sqrt((c[starts + frame] - c[starts]) / frame + 1e-12)
    return 20.0 * np.log10(np.maximum(rms, 1e-7)), hop / float(SR)


def find_runs(mask):
    if mask.size == 0:
        return []
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    return list(zip(np.where(d == 1)[0].tolist(), np.where(d == -1)[0].tolist()))


def peak(db, hop, a, b):
    i, j = max(0, int(a / hop)), min(len(db), int(b / hop))
    return float(np.max(db[i:j])) if j > i else -120.0


def analyze_run(db, hop, a, b, total):
    t0, t1 = a * hop, b * hop
    inside = peak(db, hop, t0, t1)
    pre = peak(db, hop, max(0.0, t0 - SIDE), t0)
    post = peak(db, hop, t1, min(total, t1 + SIDE))
    speech = max(pre, post)
    return dict(
        t0=round(t0, 3), t1=round(t1, 3), dur=round(t1 - t0, 3),
        peak_in=round(inside, 1), speech=round(speech, 1),
        depth=round(speech - inside, 1),
        at_head=(t0 <= 0.03), at_tail=(t1 >= total - 0.03),
        survives_pad=round((t1 - t0) - 2 * PAD_NOW, 3) >= MIN_CUT_NOW,
    )


def work(name):
    path = os.path.join(SAMPLES, name + ".MOV")
    x = read_pcm(path)
    total = len(x) / float(SR)
    db, hop = envelope_db(x)
    print()
    print("=" * 74)
    print(f"  {name}   时长 {total:.2f}s   包络 {db.min():.1f} ~ {db.max():.1f} dB")
    print("=" * 74)

    # 阈值阶梯：每档能捞到多少候选、删掉多少比例
    print(f"  {'阈值':>7} {'候选段数':>8} {'≥0.2s':>7} {'≥0.3s':>7} {'≥0.4s':>7} "
          f"{'理论删时':>9} {'占比':>7}")
    print("  " + "-" * 62)
    for thr in THRS:
        runs = find_runs(db < thr)
        durs = [b * hop - a * hop for a, b in runs]
        durs.sort()
        n2 = sum(1 for d in durs if d >= MIN_GAP_NOW)
        n3 = sum(1 for d in durs if d >= 0.30)
        n4 = sum(1 for d in durs if d >= 0.40)
        tot = sum(d for d in durs if d >= MIN_GAP_NOW)
        print(f"  {thr:>7.1f} {len(runs):>8} {n2:>7} {n3:>7} {n4:>7} "
              f"{tot:>8.2f}s {tot / total * 100:>6.1f}%")

    # 中档阈值下的逐段明细
    probe = -32.0
    runs = find_runs(db < probe)
    rows = [analyze_run(db, hop, a, b, total) for a, b in runs]
    rows = [r for r in rows if r["dur"] >= 0.10]
    print(f"\n  阈值 {probe} dB 下的明细（<0.1s 的省略）：")
    print(f"  {'#':>3} {'区间':>16} {'时长':>6} {'段内峰值':>8} {'邻域人声':>8} "
          f"{'深度':>6} {'位于':>8} {'躲得过现有双PAD':>8}")
    print("  " + "-" * 74)
    for i, r in enumerate(rows):
        where = "片头" if r["at_head"] else ("片尾" if r["at_tail"] else "中间")
        print(f"  {i + 1:>3} {r['t0']:>7.2f}→{r['t1']:<7.2f} {r['dur']:>5.2f}s "
              f"{r['peak_in']:>7.1f} {r['speech']:>7.1f} {r['depth']:>5.1f} "
              f"{where:>8} {'是' if r['survives_pad'] else '✗ 被吃掉':>8}")

    n_ok = sum(1 for r in rows if r["survives_pad"])
    print(f"\n  → 现有双 PAD({PAD_NOW}s) + 最小刀({MIN_CUT_NOW}s) 会吃掉 "
          f"{len(rows) - n_ok}/{len(rows)} 段候选")
    kept = sum(r["dur"] for r in rows if r["survives_pad"])
    print(f"  → 就算这些全切，也只删 {kept:.2f}s（占全长 {kept / total * 100:.1f}%）")

    return dict(name=name, total=round(total, 2), db=[round(float(v), 2) for v in db],
                hop=hop, rows=rows)


def draw(name, info, thr=-32.0):
    db = np.array(info["db"])
    hop = info["hop"]
    total = info["total"]
    W, H = 1200, 300
    xr = lambda t: 44 + (t / max(total, 1e-6)) * (W - 88)
    dyn, hi = max(-70.0, float(db.min())), -5.0
    TOP, HH = 30, H - 86
    mid, amp = TOP + HH / 2, HH / 2 - 4
    conv = lambda v: min(max((v - dyn) / (hi - dyn), 0.0), 1.0)
    step = max(1, len(db) // 1700)
    idxs = list(range(0, len(db), step))
    top = [f"{xr(i * hop):.1f},{mid - conv(float(db[i])) * amp:.1f}" for i in idxs]
    bot = [f"{xr(i * hop):.1f},{mid + conv(float(db[i])) * amp:.1f}" for i in idxs[::-1]]

    boxes = []
    for r in info["rows"]:
        a, b = xr(r["t0"]), xr(r["t1"])
        op = 0.30 if r["survives_pad"] else 0.16
        boxes.append(f'<rect x="{a:.1f}" y="30" width="{max(1.0, b - a):.1f}" '
                     f'height="{HH}" fill="#D6707A" opacity="{op}"/>')
        boxes.append(f'<rect x="{a:.1f}" y="30" width="{max(1.0, b - a):.1f}" '
                     f'height="{HH}" fill="none" stroke="#C0392B" stroke-width="0.6" '
                     f'stroke-dasharray="3 2" opacity="0.8"/>')
    thrline = f'<line x1="44" y1="{mid - conv(thr) * amp:.1f}" x2="{W - 44}" ' \
              f'y2="{mid - conv(thr) * amp:.1f}" stroke="#BA7517" stroke-dasharray="4 3"/>'

    html = f"""<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<title>{name} · 候选池</title><style>
body{{font:14px/1.6 -apple-system,"Microsoft YaHei",sans-serif;margin:22px;color:#2C2C2A;background:#fff}}
.p{{display:inline-block;padding:2px 10px;border-radius:99px;font-size:12px;margin-right:8px}}
.g{{background:#EAF3DE;color:#3B6D11}}.r{{background:#FCEBEB;color:#A32D2D}}
.am{{background:#FAEEDA;color:#854F0B}}
table{{border-collapse:collapse;font-size:12px;margin-top:14px}}
th,td{{border-bottom:1px solid #EDEDE9;padding:3px 9px;text-align:right}}
th{{color:#5F5E5A;font-weight:400}}
</style></head><body>
<h2 style="font-weight:500">{name} · 低幅候选池（阈值 {thr} dB）</h2>
<p><span class="p am">实线深红 = 现有算法容得下的</span>
<span class="p r">虚线浅红 = 会被双 PAD 吃掉的短气口</span></p>
<svg viewBox="0 0 {W} {H}" width="100%" style="border:1px solid #D3D1C7;border-radius:8px">
<rect x="44" y="30" width="{W - 88}" height="{HH}" fill="#F7F7F5"/>
{''.join(boxes)}
<line x1="44" y1="{mid:.1f}" x2="{W - 44}" y2="{mid:.1f}" stroke="#B4B2A9" stroke-width="0.5"/>
<polyline points="{' '.join(top + bot)}" fill="#185FA5" stroke="none"/>
{thrline}
</svg>
<table><tr><th>#</th><th>起</th><th>止</th><th>时长</th><th>段内峰值</th>
<th>邻域人声</th><th>深度dB</th><th>位置</th><th>现有算法留得住</th></tr>
{"".join(f"<tr><td>{i+1}</td><td>{r['t0']}</td><td>{r['t1']}</td><td>{r['dur']}s</td>"
         f"<td>{r['peak_in']}</td><td>{r['speech']}</td><td>{r['depth']}</td>"
         f"<td>{'片头' if r['at_head'] else ('片尾' if r['at_tail'] else '中间')}</td>"
         f"<td>{'是' if r['survives_pad'] else '✗'}</td></tr>"
         for i, r in enumerate(info["rows"]))}
</table>
</body></html>"""
    p = os.path.join(SAMPLES, name + "_候选池.html")
    with open(p, "w", encoding="utf-8") as f:
        f.write(html)
    return p


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_html = "--html" in sys.argv
    files = []
    for f in sorted(os.listdir(SAMPLES)):
        if f.upper().endswith(".MOV"):
            b = os.path.splitext(f)[0]
            if not args or b in args:
                files.append(b)
    if not files:
        print("samples/ 里没有找到 .MOV")
        return
    infos = []
    for b in files:
        info = work(b)
        if want_html:
            print("  候选图：", draw(b, info))
        infos.append(info)
    out = os.path.join(SAMPLES, "gaps.json")
    # 只跑一条时要按名字合并回总表，别把其它三条的结果冲掉
    old = {}
    if os.path.exists(out):
        try:
            old = {d["name"]: d for d in json.load(open(out, encoding="utf-8"))}
        except Exception:
            old = {}
    for d in infos:
        old[d["name"]] = d
    with open(out, "w", encoding="utf-8") as f:
        json.dump([old[k] for k in sorted(old)], f, ensure_ascii=False, indent=1)
    print(f"\n  数据已存 {out}（共 {len(old)} 条素材）")


if __name__ == "__main__":
    main()
