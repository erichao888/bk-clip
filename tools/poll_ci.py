#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
轮询 GitHub Actions 的打包工作流，出结果就汇报；失败则把编译错误抓回来。

用法（在 bk-clip 目录下）：
    python tools/poll_ci.py                # 等最近一次 v2.0.0-b* / 最新 run
    python tools/poll_ci.py v2.0.0-b1      # 指定标签

为什么要有这个：本机没有 Swift 编译器，CI 是唯一的编译验证渠道。
以前的做法是手动去网页刷，一轮构建 6~10 分钟，刷一次看一次很浪费；
而且失败时网页只显示最后 60 行，真正的 error: 常常被刷走。
这里直接把 error 行抓全。
"""

import json
import os
import re
import subprocess
import sys
import time

REPO = "erichao888/bk-clip"


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout


def proxy():
    for k in ("https_proxy", "HTTPS_PROXY", "http_proxy"):
        v = os.environ.get(k)
        if v:
            return v
    return None


def token():
    out = sh("git remote get-url origin").strip()
    m = re.match(r"https://[^:]+:([^@]+)@", out)
    return m.group(1) if m else None


def api(path, tok, accept="application/vnd.github+json"):
    p = proxy()
    px = f"-x {p} " if p else ""
    cmd = f'curl -s {px}-H "Authorization: Bearer {tok}" -H "Accept: {accept}" ' \
          f'"https://api.github.com{path}"'
    txt = sh(cmd)
    try:
        return json.loads(txt)
    except Exception:
        return {"_raw": txt[:2000]}


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else None
    tok = token()
    if not tok:
        print("取不到 token（检查 git remote 里是否内嵌了 token）")
        return 1

    # 找目标 run
    runs = api(f"/repos/{REPO}/actions/runs?per_page=5", tok).get("workflow_runs", [])
    target = None
    for r in runs:
        if want and (r.get("head_branch") == want or r.get("display_title", "").startswith(want)):
            target = r
            break
    if target is None and runs:
        target = runs[0]
    if target is None:
        print("没找到任何 workflow run")
        return 1

    rid = target["id"]
    print(f"监视 run {rid} · {target.get('head_branch')} · {target.get('display_title','')[:50]}")

    # 轮询
    deadline = time.time() + 15 * 60
    while time.time() < deadline:
        r = api(f"/repos/{REPO}/actions/runs/{rid}", tok)
        st = r.get("status")
        if st == "completed":
            concl = r.get("conclusion")
            print(f"\n=== 结果：{concl} ===")
            print(f"耗时 {(r.get('run_started_at'), r.get('updated_at'))}")
            if concl == "success":
                print("✅ 编译通过，产物已上传（bkClip-unsigned-ipa）")
                return 0
            # 失败：抓 job 日志里的 error 行
            jobs = api(f"/repos/{REPO}/actions/runs/{rid}/jobs?per_page=10", tok).get("jobs", [])
            for j in jobs:
                if j.get("conclusion") != "success":
                    print(f"\n--- 失败步骤：{j.get('name')} ---")
                    p = proxy()
                    px = f"-x {p} " if p else ""
                    log = sh(f'curl -sL {px}-H "Authorization: Bearer {tok}" '
                             f'"https://api.github.com/repos/{REPO}/actions/jobs/{j["id"]}/logs"')
                    errs = [ln for ln in log.splitlines() if "error:" in ln or "error:" in ln.lower()]
                    if errs:
                        print("编译错误（去重后前 40 条）：")
                        seen = set()
                        n = 0
                        for ln in errs:
                            key = ln.strip()[-120:]
                            if key in seen:
                                continue
                            seen.add(key)
                            print("  " + ln.strip()[:220])
                            n += 1
                            if n >= 40:
                                break
                    else:
                        print(log[-3000:])
                    break
            return 1
        time.sleep(30)
    print("15 分钟仍未结束，去网页看："
          f"https://github.com/{REPO}/actions/runs/{rid}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
