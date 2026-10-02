#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BK 去气口 · 算法预演（Windows / Python）
=========================================

这个脚本是 Swift 端要实现的检测算法的 Python 等价版本，用来**在花钱之前**
先验证三件事：

  1. 默认阈值区间 -50 ~ -25 dB 在你的真实口播素材上合不合理
  2. 防碎三参数（最短气口 0.2s / 最短片段 0.6s / 头尾留白 0.1s）够不够
  3. 检出来的气口，肉眼/kai眼看一遍到底准不准

依赖：numpy + ffmpeg（已在本机就绪）

用法：
    python preview_cut.py 你的口播.mp4
    python preview_cut.py 你的口播.mp4 --threshold -40      手动指定阈值，跳过 Otsu
    python preview_cut.py 你的口播.mp4 --preview out.mp4    直接导出剪好的视频试听
    python preview_cut.py 你的口播.mp4 --html               生成波形图，直观检查红绿区
    python preview_cut.py 你的口播.mp4 --all                报告 + 视频 + 波形图，一次出齐
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

import numpy as np

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

# ============ 防碎三参数（与 App 定稿一致，改这里就等于改 App） ============
MIN_GAP = 0.20      # 最短气口：比这还短的一律不删，否则句子会碎
MIN_SEG = 0.60      # 最短片段：删完之后剩下的片段不能短于这个
MIN_CUT = 0.10      # 最短一刀：切出来连 0.1 秒都不到的，不值得冒一次接缝爆音的风险
PAD     = 0.10      # 头尾留白：气口两端各保留这么多，防止吞掉字头和字尾

CLAMP_LOW  = -50.0  # 阈值经验区间下界
CLAMP_HIGH = -25.0  # 阈值经验区间上界

CONTRAST_DB = 6.0   # 局部对比度余量：气口必须比相邻语音低 6dB 以上才算数
PAD_SAMPLE  = 0.20  # 局部对比度取样窗口（秒）

FRAME_MS = 20.0     # RMS 窗长
HOP_MS   = 10.0     # RMS 步进
SR       = 16000    # 分析采样率（不用原始 48k，省算力，对气口检测足够）


# ---------------------------------------------------------------- 基础工具

def ffmpeg_exe() -> str:
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"


FF = ffmpeg_exe()


def read_pcm(path: str, sr: int = SR) -> np.ndarray:
    """用 ffmpeg 抽出单声道 16bit PCM，返回 [-1,1] 浮点。"""
    cmd = [FF, "-v", "error", "-i", path,
           "-vn", "-ac", "1", "-ar", str(sr), "-f", "s16le", "-"]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        print("[错误] ffmpeg 读取失败：")
        print(r.stderr.decode("utf-8", "ignore")[:1200])
        sys.exit(1)
    return np.frombuffer(r.stdout, dtype="<i2").astype(np.float32) / 32768.0


def rms_envelope(x: np.ndarray, sr: int = SR):
    """短时 RMS 包络。返回 (rms, hop_sec)"""
    frame = max(1, int(sr * FRAME_MS / 1000.0))
    hop = max(1, int(sr * HOP_MS / 1000.0))
    n = len(x)
    if n < frame:
        return np.array([float(np.sqrt(np.mean(x ** 2)))]), hop / float(sr)
    c = np.concatenate(([0.0], np.cumsum(x.astype(np.float64) ** 2)))
    starts = np.arange(0, n - frame + 1, hop)
    sums = c[starts + frame] - c[starts]
    return np.sqrt(sums / frame + 1e-12), hop / float(sr)


def to_db(rms: np.ndarray) -> np.ndarray:
    return 20.0 * np.log10(np.maximum(rms, 1e-7))


# ---------------------------------------------------------------- 阈值

def otsu_threshold(db: np.ndarray) -> float:
    """Otsu 双峰取谷：把 dB 分布分成「有声」和「静音」两类，取类间方差最大的分割点。"""
    v = db[np.isfinite(db)]
    if v.size < 32:
        return (CLAMP_LOW + CLAMP_HIGH) / 2.0
    hist, edges = np.histogram(v, bins=256)
    centers = (edges[:-1] + edges[1:]) / 2.0
    w = hist.astype(np.float64)
    s = w.sum()
    if s == 0:
        return (CLAMP_LOW + CLAMP_HIGH) / 2.0
    w /= s
    w0 = np.cumsum(w)
    m0 = np.cumsum(w * centers)
    mt = m0[-1]
    denom = w0 * (1.0 - w0)
    with np.errstate(divide="ignore", invalid="ignore"):
        sigma = np.where(denom > 1e-9, ((mt * w0 - m0) ** 2) / np.where(denom > 1e-9, denom, 1.0), np.nan)
    if np.all(np.isnan(sigma)):
        return (CLAMP_LOW + CLAMP_HIGH) / 2.0
    return float(centers[int(np.nanargmax(sigma))])


def clamp_db(v: float) -> float:
    return float(min(max(v, CLAMP_LOW), CLAMP_HIGH))


# ---------------------------------------------------------------- 找气口

def find_runs(mask: np.ndarray):
    """把布尔数组转成连续区间 [(start, end), ...]，索引为左闭右开。"""
    out = []
    if mask.size == 0:
        return out
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    starts = np.where(d == 1)[0]
    ends = np.where(d == -1)[0]
    for a, b in zip(starts, ends):
        out.append((int(a), int(b)))
    return out


def detect_gaps(db: np.ndarray, hop_sec: float, thr: float, total_sec: float):
    """低于阈值 → 候选气口，再过滤。返回 [(start_sec, end_sec, dur_sec), ...]"""
    raw = find_runs(db < thr)
    gaps = []
    for a, b in raw:
        t0, t1 = a * hop_sec, b * hop_sec
        # 去掉首尾（视频开头/结尾的静音不算气口）
        if t0 <= 0.02 or t1 >= total_sec - 0.02:
            continue
        if (t1 - t0) < MIN_GAP:
            continue
        gaps.append((t0, t1, t1 - t0))
    return gaps


def apply_pad(gaps):
    """删除区间 = 气口去掉两端留白。留白吃光了、或者剩下来不够 MIN_CUT，就不切。"""
    cuts = []
    for t0, t1, _ in gaps:
        s, e = t0 + PAD, t1 - PAD
        if (e - s) >= MIN_CUT:
            cuts.append([s, e])
    return cuts


def kept_segments(cuts, total_sec):
    segs, cur = [], 0.0
    for s, e in cuts:
        segs.append((cur, s))
        cur = e
    segs.append((cur, total_sec))
    return [(a, b) for a, b in segs if b > a + 1e-6]


def enforce_min_segment(cuts, total_sec):
    """任何保留片段短于 MIN_SEG，就把造成它的那两刀撤掉，反复合并直到没有碎片。"""
    dels = [list(c) for c in cuts]
    for _ in range(200):
        segs = kept_segments(dels, total_sec)
        if len(segs) <= 1:
            break
        bad = -1
        for i, (a, b) in enumerate(segs):
            if (b - a) < MIN_SEG:
                bad = i
                break
        if bad < 0:
            break
        if bad == 0:
            dels.pop(0)
        elif bad == len(segs) - 1:
            dels.pop()
        else:
            for k in sorted({bad - 1, bad}, reverse=True):
                if 0 <= k < len(dels):
                    dels.pop(k)
    return [tuple(c) for c in dels]


def local_contrast_pass(cuts, db, hop_sec, total_sec):
    """
    6dB 余量：气口必须比它两边 200ms 的语音低 6dB 以上，否则判为「其实在说话」，撤销这一刀。
    这一步专门治「在音量起伏大的素材上被误杀整句」。
    """
    def level(t0, t1):
        a, b = int(t0 / hop_sec), int(t1 / hop_sec)
        a, b = max(0, a), min(len(db), b)
        return float(np.max(db[a:b])) if b > a else -120.0

    keep = []
    for s, e in cuts:
        pre = level(max(0.0, s - PAD - PAD_SAMPLE), max(0.0, s - PAD))
        post = level(e + PAD, min(total_sec, e + PAD + PAD_SAMPLE))
        speech = max(pre, post)
        gap = level(s, e)
        if (speech - gap) >= CONTRAST_DB:
            keep.append((s, e))
    return keep


# ---------------------------------------------------------------- 输出

def print_report(name, total, db, thr_auto, thr_used, gaps, cuts, extra_dropped):
    print()
    print("=" * 62)
    print(f"  素材：{name}")
    print(f"  时长：{total:.2f} 秒   分析采样率：{SR} Hz")
    print(f"  包络范围：{db.min():.1f} dB ~ {db.max():.1f} dB")
    print("-" * 62)
    print(f"  Otsu 算出的原始阈值：{thr_auto:6.2f} dB")
    print(f"  夹逼后实际使用：    {thr_used:6.2f} dB")
    if abs(thr_auto - thr_used) > 0.51:
        print(f"  ⚠ 两者相差 {abs(thr_auto - thr_used):.1f} dB —— 这段素材的音量分布"
              f"不在 -50~-25dB 经验区间内，属于正常，已被夹逼兜住")
    else:
        print("  ✓ 落在经验区间内，素材音量分布正常")
    print("-" * 62)
    print(f"  检出候选气口：{len(gaps)} 处")
    print(f"  6dB 余量否决：{extra_dropped} 处（对比度不够，判定为仍在说话）")
    print(f"  最终下刀：    {len(cuts)} 处")
    removed = sum(e - s for s, e in cuts)
    print(f"  删掉总时长：  {removed:.2f} 秒（原片 {total:.2f} 秒 → 剩 {total - removed:.2f} 秒，"
          f"缩短 {removed / total * 100:.1f}%）")
    if total and removed / total > 0.5:
        print("  ⚠ 删掉了超过一半 —— 阈值可能过于激进，建议手动指定更大的阈值再试（如 -35）")
    print("=" * 62)

    print("\n  气口明细（前 20 条）：")
    print(f"  {'#':>3}  {'检测到的气口区间':^22}  {'实删区间':^22}  {'时长':>6}")
    print("  " + "-" * 58)
    for i, (s, e) in enumerate(cuts[:20]):
        g0, g1 = s - PAD, e + PAD
        print(f"  {i + 1:>3}  {g0:>9.2f} → {g1:<9.2f}  {s:>9.2f} → {e:<9.2f}  {e - s:>5.2f}s")
    if len(cuts) > 20:
        print(f"      …… 其余 {len(cuts) - 20} 条省略")

    segs = kept_segments(cuts, total)
    if segs:
        durs = np.array([b - a for a, b in segs])
        print(f"\n  保留片段：{len(segs)} 段，最长 {durs.max():.2f}s，"
              f"最短 {durs.min():.2f}s，平均 {durs.mean():.2f}s")
    print()


def export_json(path, src, total, thr_auto, thr_used, cuts):
    segs = kept_segments(cuts, total)
    data = {
        "source": os.path.basename(src),
        "durationSec": round(total, 4),
        "thresholdOtsu": round(thr_auto, 2),
        "thresholdUsed": round(thr_used, 2),
        "params": {"minGap": MIN_GAP, "minSeg": MIN_SEG, "pad": PAD,
                   "contrastDb": CONTRAST_DB},
        "segments": [{"startSec": round(a, 4), "endSec": round(b, 4),
                      "kept": True} for a, b in segs],
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"  切点表已存：{path}")


def probe_meta(path):
    """
    读视频的旋转角度与帧率（从 ffmpeg 的 stderr 解析，不依赖 ffprobe）。

    iPhone 拍的视频永远是「存储 1920x1080 横 + rotation 标记 -90」，
    真正显示出来是 1080x1920 竖版。这个标记必须处理，否则导出就横了。
    """
    r = subprocess.run([FF, "-hide_banner", "-i", path],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    s = r.stderr.decode("utf-8", "ignore")
    rot = 0.0
    m = re.search(r"rotation of (-?[\d.]+) degrees", s)
    if m:
        rot = abs(float(m.group(1)))
    fps = 0.0
    mv = re.search(r"Video:.*?,\s*([\d.]+)\s*fps", s)
    if mv:
        fps = float(mv.group(1))
    return {"rotate": rot, "fps": fps}


def export_preview(src, cuts, total, out_path):
    """把保留片段接起来，顺带在接缝处做 15ms 淡入淡出（这就是 App 里要做的防爆音处理）。"""
    segs = kept_segments(cuts, total)
    if not segs:
        print("  [跳过] 没有需要保留的片段")
        return

    fade = 0.015
    lines, vparts, aparts = [], [], []
    for i, (a, b) in enumerate(segs):
        dur = b - a
        lines.append(
            f"[0:v]trim=start={a:.6f}:end={b:.6f},setpts=PTS-STARTPTS[v{i}];"
        )
        af = f"[0:a]atrim=start={a:.6f}:end={b:.6f},asetpts=PTS-STARTPTS"
        af += f",afade=t=in:st=0:d={fade}"
        if dur > 0.1:
            af += f",afade=t=out:st={dur - fade:.6f}:d={fade}"
        af += f"[a{i}];"
        lines.append(af)
        vparts.append(f"[v{i}]")
        aparts.append(f"[a{i}]")
    # concat 要求输入严格交错：[v0][a0][v1][a1]...，不能先排完视频再排音频
    ins = []
    for i in range(len(segs)):
        ins.append(f"[v{i}]")
        ins.append(f"[a{i}]")
    lines.append(f"{''.join(ins)}concat=n={len(segs)}:v=1:a=1[ov][oa]")

    fd, script = tempfile.mkstemp(suffix=".txt", prefix="bkfilter_")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    meta = probe_meta(src)
    out_fps = meta["fps"] if meta["fps"] > 0 else 30.0

    cmd = [FF, "-v", "error", "-y"]
    # iPhone 视频是「存 1920x1080 横 + rotation -90 标记」，真实显示是 1080x1920 竖版。
    # 一旦走滤镜重编码，ffmpeg 会「自动把像素转正」成 1080x1920，但那个 rotation 标记
    # 却跟着带到了输出里 → 播放器再转一次 90°，成品就横了。
    # 解法：-noautorotate 让 ffmpeg 别动像素，原样把旋转标记继承下去。
    # 附带好处：不重新旋转像素 = 不损失画质、编码也更快。
    if meta["rotate"]:
        cmd += ["-noautorotate"]
    cmd += ["-i", src,
            "-filter_complex_script", script,
            "-map", "[ov]", "-map", "[oa]",
            "-c:v", "libx264", "-crf", "20", "-preset", "veryfast",
            "-pix_fmt", "yuv420p", "-r", "%.3f" % out_fps,
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", out_path]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        os.remove(script)
    except OSError:
        pass
    if r.returncode != 0:
        print("[错误] 导出失败：")
        print(r.stderr.decode("utf-8", "ignore")[-1500:])
        return
    size = os.path.getsize(out_path) / 1024 / 1024
    print(f"  试听片段已导出：{out_path}  ({size:.1f} MB)")
    print("  拿去听：气口去干净了吗？接缝有没有爆音？")


def export_html(src, total, db, hop_sec, thr_used, cuts, out_path):
    """波形图 + 红绿区，直观检查切得对不对。"""
    W, H = 1200, 260
    xr = lambda t: 40 + (t / max(total, 1e-6)) * (W - 80)

    lo, hi = max(-70.0, db.min()), -5.0
    dyn = lo
    W_, TOP = H - 80, 30
    mid = TOP + W_ / 2
    amp = W_ / 2 - 4
    # 镜像波形：安静的地方收窄成一条细线，有声的地方撑成粗带
    conv = lambda v: min(max((v - dyn) / (hi - dyn), 0.0), 1.0)

    step = max(1, len(db) // 1600)
    idxs = list(range(0, len(db), step))
    top = [f"{xr(i * hop_sec):.1f},{mid - conv(float(db[i])) * amp:.1f}" for i in idxs]
    bot = [f"{xr(i * hop_sec):.1f},{mid + conv(float(db[i])) * amp:.1f}" for i in idxs[::-1]]
    pts = " ".join(top + bot)

    reds = "".join(
        f'<rect x="{xr(s):.1f}" y="30" width="{max(1.0, xr(e) - xr(s)):.1f}" '
        f'height="{H - 80}" fill="#E24B4A" opacity="0.45"/>'
        for s, e in cuts)

    bars = "".join(
        f'<line x1="{xr(i * 5):.1f}" y1="{H - 46}" x2="{xr(i * 5):.1f}" '
        f'y2="{H - 40}" stroke="#888780" stroke-width="0.5"/>'
        for i in range(int(total // 5) + 1))

    removed = sum(e - s for s, e in cuts)
    html = f"""<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<title>{os.path.basename(src)} · 气口检测预演</title>
<style>
body{{font:14px/1.6 -apple-system,"Microsoft YaHei",sans-serif;margin:24px;color:#2C2C2A;background:#fff}}
.pill{{display:inline-block;padding:2px 10px;border-radius:99px;font-size:12px;margin-right:8px}}
.g{{background:#EAF3DE;color:#3B6D11}} .r{{background:#FCEBEB;color:#A32D2D}}
</style></head><body>
<h2 style="font-weight:500">{os.path.basename(src)}</h2>
<p><span class="pill g">保留 {len(kept_segments(cuts, total))} 段</span>
<span class="pill r">删除 {len(cuts)} 处 / {removed:.2f}s</span>
阈值 {thr_used:.1f} dB</p>
<svg viewBox="0 0 {W} {H}" width="100%" style="border:1px solid #D3D1C7;border-radius:8px">
<rect x="40" y="30" width="{W - 80}" height="{H - 80}" fill="#F7F7F5"/>
{reds}
<line x1="40" y1="{mid:.1f}" x2="{W - 40}" y2="{mid:.1f}" stroke="#B4B2A9" stroke-width="0.5"/>
<polyline points="{pts}" fill="#185FA5" stroke="none"/>
<line x1="40" y1="{mid - conv(thr_used) * amp:.1f}" x2="{W - 40}" y2="{mid - conv(thr_used) * amp:.1f}"
 stroke="#BA7517" stroke-width="1" stroke-dasharray="4 3"/>
<text x="44" y="{mid - conv(thr_used) * amp - 5:.1f}" font-size="11" fill="#854F0B">阈值 {thr_used:.1f} dB</text>
{bars}
</svg>
<p style="color:#5F5E5A;font-size:13px">镜像波形：<b>撑成粗带 = 有声，收窄成细线 = 安静</b>。
红色是判定为气口的区间，虚线是本次阈值。</p>
</body></html>"""
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"  波形图已生成：{out_path}  （浏览器打开看）")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="BK 去气口 · 算法预演")
    ap.add_argument("input")
    ap.add_argument("--threshold", type=float, default=None,
                    help="手动指定阈值(dB)，跳过 Otsu 自动计算")
    ap.add_argument("--preview", nargs="?", const="auto", default=None,
                    help="导出剪好的试听视频")
    ap.add_argument("--html", nargs="?", const="auto", default=None,
                    help="生成波形图 HTML")
    ap.add_argument("--json", nargs="?", const="auto", default=None,
                    help="导出切点表 JSON")
    ap.add_argument("--all", action="store_true", help="报告 + 视频 + 波形图 + JSON 一次出齐")
    args = ap.parse_args()

    src = args.input
    if not os.path.exists(src):
        print(f"[错误] 找不到文件：{src}")
        sys.exit(1)

    base = os.path.splitext(os.path.basename(src))[0]
    outdir = os.path.dirname(os.path.abspath(src))

    print(f"\n正在提取音频…")
    x = read_pcm(src)
    total = len(x) / float(SR)
    rms, hop_sec = rms_envelope(x)
    db = to_db(rms)

    thr_auto = otsu_threshold(db)
    thr_used = clamp_db(args.threshold if args.threshold is not None else thr_auto)

    gaps = detect_gaps(db, hop_sec, thr_used, total)
    cuts = enforce_min_segment(apply_pad(gaps), total)
    before = len(cuts)
    cuts = local_contrast_pass(cuts, db, hop_sec, total)
    dropped = before - len(cuts)

    print_report(base, total, db, thr_auto, thr_used, gaps, cuts, dropped)

    do_all = args.all
    if do_all or args.json:
        p = args.json if (args.json and args.json != "auto") else os.path.join(outdir, base + "_cut.json")
        export_json(p, src, total, thr_auto, thr_used, cuts)
    if do_all or args.preview:
        p = args.preview if (args.preview and args.preview != "auto") else os.path.join(outdir, base + "_去气口.mp4")
        print("\n正在导出试听片段…")
        export_preview(src, cuts, total, p)
    if do_all or args.html:
        p = args.html if (args.html and args.html != "auto") else os.path.join(outdir, base + "_波形.html")
        export_html(src, total, db, hop_sec, thr_used, cuts, p)
    print()


if __name__ == "__main__":
    main()
