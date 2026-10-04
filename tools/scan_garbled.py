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

# 项目自用符号白名单：这些字符在代码/注释里是**有意为之**，不是乱码。
# 起因：BKIcons.loopArrow 的注释里大量用希腊字母 π 讲弧度参数
#（"θ=0 → 右，θ=π/2 → 下"），扫描脚本把 π 报成乱码了。
# π 在几何语境下是正常记号，放行。
WHITELIST = set("π")

# ⚠️ 必须单独查 U+FFFD（REPLACEMENT CHARACTER �）。
# 起因：v1.3.3 修 bug 时 Edit 工具往注释里塞进了 `不��步`（两个 U+FFFD），
# 而扫描脚本**漏报了** —— 因为 U+FFFD 落在「替换字符」区，不在原来那几个
# 外国文字区里。后果是真乱码混进了提交。
# 这类字符**绝不可能**是有意写进代码的，一律算乱码。
REPLACEMENT = "�"

bad = 0
for f in files:
    try:
        lines = open(f, encoding="utf-8").read().splitlines()
    except Exception as e:
        print("读取失败", f, e)
        continue
    for i, line in enumerate(lines, 1):
        # U+FFFD 单独判定
        if REPLACEMENT in line:
            print("%s:%d: [U+FFFD 替换字符] :: %s" % (f, i, line.strip()[:80]))
            bad += 1
            continue
        m = [c for c in PAT.findall(line) if c not in WHITELIST]
        if m:
            # 过滤掉明显是项目自用排版符号的（· × ② ⟳ − 等不在上述范围，天然排除）
            print("%s:%d: %s :: %s" % (f, i, "".join(m), line.strip()[:80]))
            bad += 1
print("=== 真乱码行数: %d ===" % bad)
