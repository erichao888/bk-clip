#!/usr/bin/env bash
# 推送 v1.4.5：先试 git push（正确处理中文路径），连续失败则切 API 兜底。
# 用法：bash tools/push_main.sh <tag名>
set -u
cd "$(dirname "$0")/.."
TAG="${1:-}"
PROXY=$(env | grep -oP '(?<=^https_proxy=http://127.0.0.1:)\d+' | head -1)
PY="C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"

echo "=== 代理端口 $PROXY，目标 tag: ${TAG:-（不建 tag）} ==="

for i in $(seq 1 8); do
  out=$(timeout 45 git -c http.proxy=http://127.0.0.1:$PROXY \
                   -c https.proxy=http://127.0.0.1:$PROXY \
                   push origin main 2>&1)
  if echo "$out" | grep -q "main -> main"; then
    echo "[git] 第 $i 次推送成功"
    # tag 也用 git 试一次（成功最好，不成走 API）
    if [ -n "$TAG" ]; then
      git tag -f "$TAG" >/dev/null 2>&1
      for j in 1 2 3; do
        tout=$(timeout 45 git -c http.proxy=http://127.0.0.1:$PROXY \
                        -c https.proxy=http://127.0.0.1:$PROXY \
                        push origin "$TAG" 2>&1)
        if echo "$tout" | grep -q "$TAG -> $TAG"; then
          echo "[git] tag $TAG 推送成功"
          exit 0
        fi
        sleep 4
      done
      echo "[git] tag 推不动 → 走 API 建 tag"
      "$PY" tools/push_via_api.py --base HEAD --tag "$TAG"
    fi
    exit 0
  fi
  echo "[git] 第 $i 次失败：$(echo "$out" | head -1 | cut -c1-70)"
  sleep 6
done

echo "=== git 端点全失败，切 API 兜底（全量快照） ==="
if [ -n "$TAG" ]; then
  "$PY" tools/push_via_api.py --all --tag "$TAG"
else
  "$PY" tools/push_via_api.py --all
fi
