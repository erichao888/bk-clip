# -*- coding: utf-8 -*-
"""
用 Git Data API 推 commit —— 绕过不通的 git 端点（CONNECT 502）。

做法（GitHub 官方三步）：
  1. POST /git/blobs       每个改动文件一个 blob
  2. POST /git/trees       用 base_tree + 新 blob 组一棵 tree
  3. POST /git/commits     用 tree + parent 生成 commit
  4. PATCH /git/refs/heads/main   把 main 指到新 commit
"""
import base64
import io
import json
import subprocess
import sys
import time
import urllib.request

REPO = "erichao888/bk-clip"
API = "https://api.github.com/repos/" + REPO


def token():
    url = subprocess.run(["git", "remote", "get-url", "origin"],
                         capture_output=True, text=True).stdout.strip()
    return url.split("://")[1].split("@")[0].split(":")[1]


TOK = token()
HDR = {
    "Authorization": "Bearer " + TOK,
    "Accept": "application/vnd.github+json",
    "User-Agent": "bk-clip-push",
}


def api(method, path, payload=None):
    """返回 (ok, data)。失败时打印服务端给的 message（那才是权威答案）。"""
    url = API + path
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    hdr = dict(HDR)
    if body:
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return True, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return False, json.loads(raw)
        except Exception:
            return False, {"message": raw[:300]}
    except Exception as e:
        return False, {"message": "%s: %s" % (type(e).__name__, e)}


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def main():
    commit = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    # 1) 远端当前的 main
    ok, ref = api("GET", "/git/ref/heads/main")
    if not ok:
        print("读远端 main 失败:", ref.get("message"))
        return 1
    remote_sha = ref["object"]["sha"]
    base_commit = remote_sha
    print("远端 main:", remote_sha[:7])

    local = sh("git", "rev-parse", commit)
    if local == remote_sha:
        print("✅ 远端已是最新，无需推送")
        return 0
    print("本地 HEAD:", local[:7])

    # 2) 收集这个提交相对远端 base 的所有文件改动
    files = sh("git", "diff", "--name-only", remote_sha, local).splitlines()
    files = [f for f in files if f.strip()]
    print("需上传 %d 个文件: %s" % (len(files), ", ".join(files)))
    if not files:
        print("没有文件差异？")

    base_tree = sh("git", "rev-parse", remote_sha + "^{tree}")

    # 3) 每个文件建 blob
    tree_entries = []
    for path in files:
        content = open(path, "rb").read()
        enc = base64.b64encode(content).decode("ascii")
        ok, blob = api("POST", "/git/blobs",
                       {"content": enc, "encoding": "base64"})
        if not ok:
            print("建 blob 失败 %s: %s" % (path, blob.get("message")))
            return 1
        tree_entries.append({"path": path, "mode": "100644",
                             "type": "blob", "sha": blob["sha"]})
        print("  blob %-32s %s" % (path, blob["sha"][:7]))
        time.sleep(0.15)

    # 4) 组 tree
    ok, tree = api("POST", "/git/trees",
                   {"base_tree": base_tree, "tree": tree_entries})
    if not ok:
        print("建 tree 失败:", tree.get("message"))
        return 1
    print("tree:", tree["sha"][:7])

    # 5) 建 commit（沿用本地那条提交信息）
    msg = sh("git", "log", "-1", "--pretty=%B", local).strip()
    ok, cm = api("POST", "/git/commits",
                 {"message": msg, "tree": tree["sha"], "parents": [remote_sha]})
    if not ok:
        print("建 commit 失败:", cm.get("message"))
        return 1
    print("commit:", cm["sha"][:7])

    # 6) 更新 main 引用
    ok, r = api("PATCH", "/git/refs/heads/main",
                {"sha": cm["sha"], "force": False})
    if not ok:
        print("更新 main 失败:", r.get("message"))
        return 1
    print("✅ main 已更新到", cm["sha"][:7])
    return 0


if __name__ == "__main__":
    sys.exit(main())
