# -*- coding: utf-8 -*-
"""
非汉字字符扫描（项目铁律：重写大文件后必跑）。
只把「真乱码」算作问题：西里尔 / 希腊 / 假名 / 谚文 / 全角字母。
中文标点（，：（）「」等）必须放行 —— 中文注释里它们是正常字符。
"""
import re
import sys

# 分开写：全角标点区 \u3000-\u303F 和全角形式 \uFF00-\uFFEF 是中文正常用法，排除
PAT = re.compile(
    "[\u0400-\u04FF"   # 西里尔
    "\u0370-\u03FF"   # 希腊
    "\u3040-\u30FF"   # 假名
    "\uAC00-\uD7AF"   # 谚文
    "\uFF10-\uFF19"   # 全角数字
    "\uFF21-\uFF3A"   # 全角大写字母
    "\uFF41-\uFF5A"   # 全角小写字母
    "]"                 # ⚠️ 别加 \u00A0-\u00BF 之类的「可疑拉丁区」——
                        #   实测会误报 Swift 的空数组字面量 []（代码里满地都是）
)

files = sys.argv[1:]
bad = 0
for f in files:
    try:
        lines = open(f, encoding="utf-8").read().splitlines()
    except Exception as e:
        print("读取失败", f, e)
        continue
    for i, line in enumerate(lines, 1):
        m = PAT.findall(line)
        if m:
            # 过滤掉明显是项目自用排版符号的（· × ② ⟳ − 等不在上述范围，天然排除）
            print("%s:%d: %s :: %s" % (f, i, "".join(m), line.strip()[:80]))
            bad += 1
print("=== 真乱码行数: %d ===" % bad)
