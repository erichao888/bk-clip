# -*- coding: utf-8 -*-
"""
用 Git Data API 推 commit —— 绕过不通的 git 端点（CONNECT 502 / HTTP 000）。

## 为什么需要这个
沙箱代理对 `github.com` 的 **git 端点**反复 502，但
`api.github.com` / `uploads.github.com` / `codeload` **全通**。
所以走 GitHub Git Data API 推。

## 两种模式
- **增量**（默认）：`git diff <base> HEAD` 只传改动的文件。
  base 取「远端 main 对应的那个本地提交」——因为远端可能是 API 造出来的提交，
  不在本地历史里，不能直接 `git diff <远端sha>`（会算出 0 个文件，19:56 踩过）。
- **全量**（`--all`）：传 HEAD 的完整快照。慢但绝对可靠。

用法：
    python tools/push_via_api.py --base <commit> [--tag vX.Y.Z]
    python tools/push_via_api.py --all --tag vX.Y.Z

## 网络注意
`/git/blobs` 偶发返回 "malformed request from your client"（代理抖动）。
所以所有请求都带重试，且 4xx 里只有 429/408 才重试。
"""
import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = "erichao888/bk-clip"
API = "https://api.github.com/repos/" + REPO


def token():
    url = subprocess.run(["git", "remote", "get-url", "origin"],
                         capture_output=True, text=True).stdout.strip()
    return url.split("://")[1].split("@")[0].split(":")[1]


TOK = token()
HDR = {"Authorization": "Bearer " + TOK,
       "Accept": "application/vnd.github+json",
       "User-Agent": "bk-clip-push"}

RETRY_STATUS = {408, 429, 500, 502, 503, 504}


def api(method, path, payload=None, tries=6):
    url = API + path
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    hdr = dict(HDR)
    if body:
        hdr["Content-Type"] = "application/json"
    last = {}
    for attempt in range(tries):
        req = urllib.request.Request(url, data=body, headers=hdr, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return True, json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                last = json.loads(raw)
            except Exception:
                last = {"message": raw[:300]}
            # "malformed request" 是代理抖动伪装成的 4xx → 也重试
            msg = str(last.get("message", ""))
            soft = e.code in RETRY_STATUS or "malformed" in msg.lower() or "abuse" in msg.lower()
            if not soft:
                return False, last
            print("    [重试 %d/%d] %s: %s" % (attempt + 1, tries, e.code, msg[:60]))
            time.sleep(2.0 * (attempt + 1))
        except Exception as e:
            last = {"message": "%s: %s" % (type(e).__name__, e)}
            print("    [重试 %d/%d] %s" % (attempt + 1, tries, str(last["message"])[:60]))
            time.sleep(2.0 * (attempt + 1))
    return False, last


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def tree_of(commit):
    return sh("git", "rev-parse", commit + "^{tree}")


def main():
    argv = sys.argv[1:]
    tag = None
    if "--tag" in argv:
        i = argv.index("--tag")
        tag = argv[i + 1]
        del argv[i:i + 2]
    full = "--all" in argv
    argv = [a for a in argv if not a.startswith("--")]

    ok, r = api("GET", "/git/ref/heads/main")
    if not ok:
        print("读远端 main 失败:", r.get("message"))
        return 1
    remote_sha = r["object"]["sha"]
    ok, c = api("GET", "/git/commits/" + remote_sha)
    if not ok:
        print("读远端 commit 失败:", c.get("message"))
        return 1
    base_tree = c["tree"]["sha"]
    print("远端 main:", remote_sha[:12], " base tree:", base_tree[:12])

    # 找「远端 tree 对应的本地提交」——用它当 diff 的 base
    if full:
        base = None
    else:
        if argv:
            base = argv[0]
        else:
            base = None
            for cand in sh("git", "rev-list", "--max-count=30", "HEAD").splitlines():
                if tree_of(cand) == base_tree:
                    base = cand
                    break
        if base is None:
            print("找不到与远端 tree 对应的本地提交 → 改用全量模式")
            full = True
        else:
            print("远端对应本地提交:", base[:12])

    if full:
        out = sh("git", "-c", "core.quotePath=false", "ls-tree", "-r", "HEAD")
        files = []
        for line in out.splitlines():
            head, _, path = line.partition("\t")
            parts = head.split()
            if len(parts) >= 3 and path:
                files.append((path, parts[0]))
    else:
        files = []
        for path in sh("git", "diff", "--name-only", base, "HEAD").splitlines():
            path = path.strip()
            if not path:
                continue
            mode = sh("git", "ls-files", "-s", "--", path).split()[0] if sh("git", "ls-files", "-s", "--", path) else "100644"
            files.append((path, mode))

    print("需上传 %d 个文件（%s）" % (len(files), "全量" if full else "增量"))
    if not files:
        print("没有文件要传")
        return 1

    entries = []
    for i, (path, mode) in enumerate(files):
        content = open(path, "rb").read()
        enc = base64.b64encode(content).decode("ascii")
        ok, blob = api("POST", "/git/blobs", {"content": enc, "encoding": "base64"})
        if not ok:
            print("建 blob 失败 %s: %s" % (path, blob.get("message")))
            return 1
        entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
        print("  %d/%d %s" % (i + 1, len(files), path))
        time.sleep(0.1)

    ok, tree = api("POST", "/git/trees", {"base_tree": base_tree, "tree": entries})
    if not ok:
        print("建 tree 失败:", tree.get("message"))
        return 1
    print("tree:", tree["sha"][:12])

    msg = sh("git", "log", "-1", "--pretty=%B", "HEAD").strip()
    ok, cm = api("POST", "/git/commits",
                 {"message": msg, "tree": tree["sha"], "parents": [remote_sha]})
    if not ok:
        print("建 commit 失败:", cm.get("message"))
        return 1
    print("commit:", cm["sha"][:12])

    ok, r = api("PATCH", "/git/refs/heads/main", {"sha": cm["sha"], "force": False})
    if not ok:
        print("更新 main 失败:", r.get("message"))
        return 1
    print("OK main ->", cm["sha"][:12])

    if tag:
        ok, t = api("POST", "/git/tags",
                    {"tag": tag, "message": tag, "object": cm["sha"], "type": "commit"})
        if not ok:
            print("建 tag 失败:", t.get("message"))
            return 1
        ok, r = api("POST", "/git/refs", {"ref": "refs/tags/" + tag, "sha": t["sha"]})
        if not ok:
            print("建 tag ref 失败:", r.get("message"))
            return 1
        print("OK tag %s（CI 已触发）" % tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
