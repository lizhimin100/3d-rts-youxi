# -*- coding: utf-8 -*-
"""生成「文件索引」——给后续 agent 用的导航层。

用法（工程根目录）：
    python Tools/生成文件索引.py

产出：Documents/索引/文件索引.md（自动生成，不要手改）
口径：
  · 行数        wc -l 等价
  · 职责        文件头 40 行内第一条 `## ` 注释（截断 60 字）
  · preload 出  本文件 preload/load 的 res:// 目标数
  · 被 preload  全仓有多少文件 preload 了它（只统计 .gd）
  · 入口        自检脚本的运行方式（--script / 主场景挂载）
"""
import os
import re
import io

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIRS = ["Game", "Views", "Model", "Engine", "Tests", "addons"]
OUT = os.path.join(ROOT, "Documents", "索引", "文件索引.md")


def rel(p):
    return os.path.relpath(p, ROOT).replace("\\", "/")


def module_of(rp):
    parts = rp.split("/")
    if parts[0] == "addons":
        return "addons/map_editor"
    if len(parts) >= 2:
        return "Game/" + parts[1] if not parts[1].endswith(".gd") else "Game/(根)"
    return "Game/(根)"


files = []
for d in SRC_DIRS:
    base = os.path.join(ROOT, d)
    for cur, _, names in os.walk(base):
        for n in names:
            if n.endswith(".gd"):
                files.append(os.path.join(cur, n))
files.sort(key=lambda p: (module_of(rel(p)), rel(p)))

texts = {}
for f in files:
    try:
        with open(f, encoding="utf-8", errors="ignore") as fh:
            texts[f] = fh.read()
    except OSError:
        texts[f] = ""

# 预扫：谁被 preload
incoming = {}
for f, t in texts.items():
    for m in re.finditer(r'(?:preload|load)\(\s*"res://([^"]+\.gd)"', t):
        tgt = "Game/" + m.group(1).split("Game/", 1)[-1] if "Game/" in m.group(1) else m.group(1)
        incoming[tgt] = incoming.get(tgt, 0) + 1


def header_of(t):
    for line in t.splitlines()[:40]:
        s = line.strip()
        if s.startswith("##") and not s.startswith("###"):
            body = s.lstrip("#").strip()
            if not body or set(body) <= set("=-· "):
                continue
            return body[:60]
    return ""


def entry_of(rp, t):
    if not rp.startswith("Tests/suites/"):
        return ""
    if re.search(r"^extends\s+SceneTree", t, re.M):
        return "--script"
    if re.search(r"^extends\s+Node", t, re.M):
        return "主场景挂载"
    return ""


rows = []
for f in files:
    rp = rel(f)
    t = texts[f]
    lines = t.count("\n") + (1 if t and not t.endswith("\n") else 0)
    cls = re.search(r"^class_name\s+([A-Za-z_\u4e00-\u9fa5][\w\u4e00-\u9fa5]*)", t, re.M)
    ext = re.search(r"^extends\s+(\S+)", t, re.M)
    outs = len(re.findall(r'(?:preload|load)\(\s*"res://[^"]+\.gd"', t))
    ins = incoming.get(rp, 0)
    rows.append({
        "path": rp, "lines": lines,
        "cls": cls.group(1) if cls else "",
        "ext": ext.group(1) if ext else "",
        "duty": header_of(t),
        "out": outs, "in": ins,
        "entry": entry_of(rp, t),
    })

# 健康指标（只报数，不判罪）
PAT = {
    "读私有字段 get(\"_\")": r'\.get\(\s*"_',
    "动态 call(": r'\.call\(',
    "has_method(": r'has_method\(',
    "Game. 引用": r'\bGame\.',
    "直接写 global_position": r'global_position\s*=',
}
health = {}
for name, pat in PAT.items():
    health[name] = sum(len(re.findall(pat, t)) for t in texts.values())
no_header = [r["path"] for r in rows if not r["duty"]]
big = sorted(rows, key=lambda r: -r["lines"])[:10]


# 模块汇总
mods = {}
for r in rows:
    m = module_of(r["path"])
    d = mods.setdefault(m, {"n": 0, "lines": 0})
    d["n"] += 1
    d["lines"] += r["lines"]

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with io.open(OUT, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("# 文件索引（自动生成）\n\n")
    fh.write("> 由 `Tools/生成文件索引.py` 生成，**不要手改**。改完代码重跑即可。\n")
    fh.write("> 用途：agent 先查索引再决定读哪个文件，避免打开 7531 行的上帝类。\n\n")
    fh.write("## 模块汇总\n\n")
    fh.write("| 模块 | 文件数 | 行数 |\n|---|---:|---:|\n")
    for m in sorted(mods):
        fh.write("| `%s` | %d | %d |\n" % (m, mods[m]["n"], mods[m]["lines"]))
    total_n = sum(v["n"] for v in mods.values())
    total_l = sum(v["lines"] for v in mods.values())
    fh.write("| **合计** | **%d** | **%d** |\n\n" % (total_n, total_l))
    fh.write("## 健康指标（只报数，不判罪）\n\n")
    fh.write("| 指标 | 当前值 | 备注 |\n|---|---:|---|\n")
    fh.write("| 最大的 10 个文件 | %s | 超过 1200 行视为上帝类，新代码不要再往里塞 |\n" % "、".join(
        "`%s` %d" % (r["path"].split("/")[-1], r["lines"]) for r in big))
    fh.write("| 缺少文件头注释的文件 | %d / %d | 新文件请在头 6 行写「职责/属于/对外/禁改」 |\n" % (len(no_header), total_n))
    for name, v in health.items():
        fh.write("| %s | %d | 新增一处就要问一次「有没有绕开接口」 |\n" % (name, v))
    fh.write("\n## 明细\n\n")
    fh.write("| 文件 | 行 | class_name | extends | 职责（首条注释） | preload出 | 被preload | 自检入口 |\n")
    fh.write("|---|---:|---|---|---|---:|---:|---|\n")
    for r in rows:
        fh.write("| `%s` | %d | %s | %s | %s | %d | %d | %s |\n" % (
            r["path"], r["lines"],
            ("`%s`" % r["cls"]) if r["cls"] else "",
            r["ext"], r["duty"].replace("|", "\\|"),
            r["out"], r["in"], r["entry"]))

print("写出：", OUT)
print("文件数：", total_n, " 行数：", total_l)