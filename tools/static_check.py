#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本机没有 Swift 编译器，CI 一轮要几分钟。这个脚本在提交前先拦一遍
最常见、也最浪费一轮 CI 的低级错误：

  1. 括号不配平（{ } ( ) [ ]）—— 跳注释、跳字符串、跳字符字面量之后数
  2. 同一个名字被定义两次（复制粘贴最常见的后果，直接 invalid redeclaration）
  3. 定义了却从没被调用的私有方法（多半是改了一半留下的残骸）
  4. 调用了但全工程找不到定义的自家符号（BK 开头 / 本文件内的方法）
  5. 文件里出现 TODO / FIXME 没清
  6. #selector(...) 指向的方法没有 @objc func（会直接编译失败）
  7. iOS SDK 里标了 unavailable 的 API（不是 deprecated —— 那是硬错误）
  8. String(format:) 的实参不是 CVarArg（Substring / Character 等）

其中 6/7/8 是被 CI 真刀真枪教出来的（v1.1.0 和 v1.1.1 各红一轮），
加进来是为了不再花一轮 CI 去发现同一类错。

它不做类型检查，也替代不了真编译 —— 只是把「必然红」的那几类先挡掉。
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app")

SWIFT_FILES = []
for base, _dirs, files in os.walk(ROOT):
    for f in files:
        if f.endswith(".swift"):
            SWIFT_FILES.append(os.path.join(base, f))
SWIFT_FILES.sort()


def strip_non_code(src: str) -> str:
    """去掉注释和字符串字面量，剩下的才是参与配平的代码"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif ch == '"':
            # 多行字符串 """...""" 也一并跳过
            if src.startswith('"""', i):
                i += 3
                while i + 2 < n and not src.startswith('"""', i):
                    i += 1
                i += 3
            else:
                i += 1
                while i < n and src[i] != '"':
                    if src[i] == "\\":
                        i += 1
                    i += 1
                i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


PAIRS = {"}": "{", ")": "(", "]": "["}


def check_brackets(path, src):
    code = strip_non_code(src)
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "{([":
            stack.append((ch, line))
        elif ch in "})]":
            if not stack:
                return f"多出来的 {ch}（第 {line} 行）"
            open_ch, open_line = stack.pop()
            if open_ch != PAIRS[ch]:
                return f"{ch}（第 {line} 行）配的是 {open_ch}（第 {open_line} 行）"
    if stack:
        ch, ln = stack[-1]
        return f"{ch}（第 {ln} 行）没闭合"
    return None


# 只收「类型级」声明：class / struct / enum / protocol / extension。
# 不收 func 和局部变量 —— 局部变量同名是完全合法的（每个函数里都有个 `url`），
# 收进来会淹掉真正的重复声明
TYPE_RE = re.compile(
    r"^\s*(?:@objc\s+|public\s+|internal\s+|private\s+|fileprivate\s+|final\s+)*"
    r"(class|struct|enum|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE)


def collect_type_declarations(src):
    """返回 {名字: [(种类, 行号)]}。extension 单独记 ——
    同一个类型有多个 extension 是合法的，不该报重复"""
    names = {}
    for m in TYPE_RE.finditer(src):
        kind, name = m.group(1), m.group(2)
        line = src[:m.start()].count("\n") + 1
        names.setdefault(name, []).append((kind, line))
    return names


# ===========================================================================
# 下面三类是**被 CI 真刀真枪教出来的**（v1.1.0 / v1.1.1 各红一轮）
# ===========================================================================


def check_selectors(all_code):
    """#selector(xxx) 指向的方法必须有 @objc func，否则编译失败"""
    problems = []
    for rel, code in all_code:
        objc_funcs = set(re.findall(r"@objc\s+(?:private\s+)?func\s+(\w+)", code))
        for m in re.finditer(r"#selector\(\s*(\w+)\s*\)", code):
            name = m.group(1)
            if name not in objc_funcs:
                line = code[:m.start()].count("\n") + 1
                problems.append(
                    f"[selector] {rel}:{line}  #selector({name}) 找不到对应的 @objc func")
    return problems


# iOS SDK 里标了 **unavailable** 的属性（不是 deprecated —— 那是硬错误）。
# 记一条：Swift 4.2 起 `AVAsset.naturalSize` 被判 unavailable，因为一个 asset
# 可能挂多条视频轨，没说清是哪一条。只有 `AVAssetTrack.naturalSize` 能用。
UNAVAILABLE_RECEIVERS = [
    (re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\??\s*\.\s*naturalSize"), "naturalSize"),
]


def check_unavailable_api(all_code):
    problems = []
    for rel, code in all_code:
        for rx, api in UNAVAILABLE_RECEIVERS:
            for m in rx.finditer(code):
                recv = m.group(1)
                # 接收者里带 track 的是 AVAssetTrack，合法
                if "track" in recv.lower():
                    continue
                line = code[:m.start()].count("\n") + 1
                problems.append(
                    f"[unavailable] {rel}:{line}  `{recv}.{api}` —— "
                    f"AVAsset.{api} 在 iOS SDK 上是 unavailable（硬错误），"
                    f"只能用 AVAssetTrack.{api}，或走 BKAssetProbe")
    return problems


# String(format:) 的实参必须满足 CVarArg。
# `String.prefix(_:)` 等返回 Substring，插值 `\(x.prefix(8))` 会自动转，
# 但 format 不转 —— 报 "argument type 'String.SubSequence' does not
# conform to expected type 'CVarArg'"。CI v1.1.0 红的就是这个。
NON_CVARARG = re.compile(r"\.(?:prefix|suffix|dropFirst|dropLast|first|last)\s*\(")


def _strip_wrapped_calls(s: str, wrapper: str = "String") -> str:
    """把 `String( ... )` 整个片段挖掉（按括号配平，能处理一层嵌套）。

    用途只有一个：判断「这个 .prefix() 外面是不是已经套了 String()」。
    """
    out = []
    i = 0
    n = len(s)
    head = wrapper + "("
    while i < n:
        if s.startswith(head, i):
            depth = 0
            j = i + len(wrapper)
            while j < n:
                if s[j] == "(":
                    depth += 1
                elif s[j] == ")":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            out.append("OK")
            i = j
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def check_format_args(all_code):
    problems = []
    for rel, code in all_code:
        for m in re.finditer(r"String\(\s*format\s*:", code):
            # 从 format: 之后开始找配平的右括号，把整个实参列表切出来
            i = m.end()
            depth = 1
            while i < len(code) and depth > 0:
                if code[i] == "(":
                    depth += 1
                elif code[i] == ")":
                    depth -= 1
                i += 1
            call = code[m.end():i]
            # 去掉开头的格式串字面量（普通串和跨行串都要整段去掉）
            call = re.sub(r'"""[\s\S]*?"""\s*,', "", call, count=1)
            call = re.sub(r'"(?:[^"\\]|\\.)*"\s*,', "", call, count=1)
            # ⚠️ 必须先把「已经显式套了 String(...)」的实参挖掉再看剩下的。
            # 不挖的话 `String(format: "%@", String(name.prefix(3)))` 这种**正确**写法
            # 会被误报 —— 误报比漏报更坏：它会逼人为了躲报警而不敢用正确写法。
            # 循环到不再变化，嵌套两层的也能挖干净
            prev = None
            while prev != call:
                prev = call
                call = _strip_wrapped_calls(call)
            if NON_CVARARG.search(call):
                line = code[:m.start()].count("\n") + 1
                problems.append(
                    f"[CVarArg] {rel}:{line}  String(format:) 的实参里出现了 "
                    f"Substring/Character —— 套一层 String(...) 再传进去")
    return problems


def main():
    problems = []
    all_defs = {}

    for path in SWIFT_FILES:
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        rel = os.path.relpath(path, ROOT)

        # 1. 括号
        err = check_brackets(path, src)
        if err:
            problems.append(f"[括号] {rel}: {err}")

        # 2. 类型重复声明。extension 可以出现多次（合法），其余不行
        defs = collect_type_declarations(src)
        for name, decls in defs.items():
            # 本体（class / struct / enum / protocol）只允许有一处；extension 随便几个
            bodies = [ln for kind, ln in decls if kind != "extension"]
            if len(bodies) > 1:
                problems.append(f"[重名] {rel}: {name} 的本体声明了 {len(bodies)} 次，行 {bodies}")

        for name in defs:
            all_defs.setdefault(name, []).append(rel)

        # 5. 残留标记
        for tag in ("TODO", "FIXME", "XXX"):
            if tag in src:
                ln = src[:src.index(tag)].count("\n") + 1
                problems.append(f"[残留] {rel}: 第 {ln} 行有 {tag}")

    # 3. 定义了没被调用的私有方法
    for path in SWIFT_FILES:
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        rel = os.path.relpath(path, ROOT)
        others = ""
        for p2 in SWIFT_FILES:
            if p2 != path:
                with open(p2, encoding="utf-8") as fh2:
                    others += fh2.read()

        for m in re.finditer(r"(?:private|fileprivate)\s+func\s+([A-Za-z_][A-Za-z0-9_]*)", src):
            name = m.group(1)
            if name.startswith("init"):
                continue
            # 必须全文找，不能只找定义之后 —— viewDidLoad 里调 setupNav()
            # 而 setupNav 的定义在它下面，只往后搜会把它误判成死代码
            rest = src[:m.start()] + src[m.end():]
            used_here = re.search(r"\b" + re.escape(name) + r"\b", rest) is not None
            used_else = re.search(r"\b" + re.escape(name) + r"\b", others) is not None
            if not used_here and not used_else:
                ln = src[:m.start()].count("\n") + 1
                problems.append(f"[死代码] {rel}: 第 {ln} 行 {name}() 定义了没人调")

    # 4. 调用了找不到的自家符号
    known = set(all_defs) | {
        "BKLog", "BKTheme", "BKConfig", "BKTimeline", "BKDraftStore", "BKExporter",
        "BKAssetProbe", "BKAudioAnalyzer", "BKDetector", "BKVideoLibrary", "BKHistory",
        "BKIcons", "BKProject", "BKMark", "BKEnvelope", "BKExportRecord", "BKProbe",
        "BKDebug", "BKTrackView", "BKOverviewBar", "BKDraftCell", "BKCovers",
        "BKJointBuilder", "BKExportPanelViewController", "BKTrashViewController",
        "BKDraftBatch", "BKExportScope",
    }
    all_code = []
    for path in SWIFT_FILES:
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        rel = os.path.relpath(path, ROOT)
        # 注释里提到「BKModels.swift」这种文件名不算引用，先剥掉注释再看
        code = strip_non_code(src)
        all_code.append((rel, code))
        for m in re.finditer(r"\b(BK[A-Z][A-Za-z0-9_]*)\b", code):
            name = m.group(1)
            if name in known:
                continue
            problems.append(f"[未定义] {rel}: 用了 {name}，全工程没找到定义")

    # 6/7/8 —— 被 CI 教出来的三类硬错误
    problems += check_selectors(all_code)
    problems += check_unavailable_api(all_code)
    problems += check_format_args(all_code)

    if problems:
        print(f"发现 {len(problems)} 处问题：\n")
        for p in problems:
            print("  " + p)
        sys.exit(1)

    print(f"静态检查通过：{len(SWIFT_FILES)} 个文件，括号配平、无重名、无死代码、"
          f"无未定义符号、selector/unavailable/CVarArg 均无问题 ✓")


if __name__ == "__main__":
    main()
