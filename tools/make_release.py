# -*- coding: utf-8 -*-
"""建 Release + 上传附件（payload 走文件，避开 shell 的反引号/中文问题）。"""
import base64
import json
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "erichao888/bk-clip"
API = "https://api.github.com/repos/" + REPO
UPLOADS = "https://uploads.github.com/repos/" + REPO

TAG = sys.argv[1]
IPA = sys.argv[2]
NAME = sys.argv[3]
NOTES = sys.argv[4]

url = subprocess.run(["git", "remote", "get-url", "origin"],
                     capture_output=True, text=True).stdout.strip()
TOK = url.split("://")[1].split("@")[0].split(":")[1]
HDR = {"Authorization": "Bearer " + TOK,
       "Accept": "application/vnd.github+json",
       "User-Agent": "bk-clip-release"}


def api(method, path, payload=None):
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    hdr = dict(HDR)
    if body:
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return True, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return False, json.loads(raw)
        except Exception:
            return False, {"message": raw[:300]}


ok, rel = api("POST", "/releases", {"tag_name": TAG, "name": NAME,
                                   "body": NOTES, "draft": False, "prerelease": False})
if not ok:
    print("建 Release 失败:", rel.get("message"))
    sys.exit(1)
rid = rel["id"]
print("Release id:", rid)

data = open(IPA, "rb").read()
hdr = {"Authorization": "Bearer " + TOK,
       "Content-Type": "application/octet-stream",
       "User-Agent": "bk-clip-release"}
req = urllib.request.Request(
    "%s/releases/%d/assets?name=%s" % (UPLOADS, rid, IPA.split("/")[-1]),
    data=data, headers=hdr, method="POST")
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.loads(r.read().decode("utf-8"))
        print("附件已传: %s (%.1f KB)" % (d["name"], d["size"] / 1024))
        print(d["browser_download_url"])
except urllib.error.HTTPError as e:
    print("上传失败:", e.read().decode("utf-8", "replace")[:200])
    sys.exit(1)
