# -*- coding: utf-8 -*-
"""v1 目录重排：按「七块砖」把 代码/场景/美术/音频/地图/工具/文档 迁到新地基。

用法：
  python _migrate_v1.py --dry-run   # 只打印计划
  python _migrate_v1.py --apply     # 执行（移动 + 改引用）
保留在 Tools/migrate/ 里作为这次迁移的可审计记录。
"""
import os, sys, json, io

ROOT = os.path.dirname(os.path.abspath(__file__))
DRY = "--apply" not in sys.argv

# 目录级迁移（源 → 目标）
DIR_MOVES = [
    ("代码/核心",   "Game/core"),
    ("代码/系统",   "Game/systems"),
    ("代码/单位",   "Game/units"),
    ("代码/ai",     "Game/ai"),
    ("代码/寻路",   "Game/pathing"),
    ("代码/地图核心", "Game/map"),
    ("代码/配置",   "Game/config"),
    ("代码/操作",   "Views/input"),
    ("代码/镜头",   "Views/camera"),
    ("代码/界面",   "Views/hud"),
    ("代码/美术",   "Views/world/art"),
    ("代码/人群",   "Views/world/crowd"),
    ("代码/音频",   "Game/audio"),
    ("代码/测试",   "Tests/suites"),
    ("代码/数据",   "Game/core"),
    ("场景",        "Views/scenes"),
    ("美术",        "Content/art"),
    ("音频",        "Content/audio"),
    ("地图",        "Content/maps"),
    ("文档",        "Documents"),
    ("工具",        "Tools"),
]
# 文件级迁移（目录迁移之后再挪）
FILE_MOVES = [
    ("代码/战争迷雾.gd",        "Game/systems/战争迷雾.gd"),
    ("Game/core/地图生成.gd",   "Game/map/地图生成.gd"),
    ("Game/core/地图生成.gd.uid", "Game/map/地图生成.gd.uid"),
    ("Game/core/地形.gd",       "Game/map/地形.gd"),
    ("Game/core/地形.gd.uid",   "Game/map/地形.gd.uid"),
]

# 文本引用替换（长的在前）
REPLACES = [
    ("代码/测试/",   "Tests/suites/"),
    ("代码/配置/",   "Game/config/"),
    ("代码/核心/",   "Game/core/"),
    ("代码/系统/",   "Game/systems/"),
    ("代码/单位/",   "Game/units/"),
    ("代码/ai/",     "Game/ai/"),
    ("代码/寻路/",   "Game/pathing/"),
    ("代码/地图核心/", "Game/map/"),
    ("代码/操作/",   "Views/input/"),
    ("代码/镜头/",   "Views/camera/"),
    ("代码/界面/",   "Views/hud/"),
    ("代码/美术/",   "Views/world/art/"),
    ("代码/人群/",   "Views/world/crowd/"),
    ("代码/音频/",   "Game/audio/"),
    ("代码/数据/",   "Game/core/"),
    ("代码/战争迷雾.gd", "Game/systems/战争迷雾.gd"),
    ("代码/",        "Game/"),
    ("场景/",        "Views/scenes/"),
    ("美术/",        "Content/art/"),
    ("音频/",        "Content/audio/"),
    ("地图/",        "Content/maps/"),
    ("文档/",        "Documents/"),
    ("工具/",        "Tools/"),
]

TEXT_EXT = {".gd", ".tscn", ".tres", ".cfg", ".godot", ".import", ".ps1", ".py",
            ".md", ".json", ".csv", ".gdshader", ".shader", ".theme", ".txt",
            ".gitignore", ".gitattributes", ".editorconfig", ".sh", ".yml", ".yaml"}
SKIP_DIRS = {".git", ".godot", "_qa", ".workbuddy", "__pycache__", "dist"}

def walk_text_files():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            p = os.path.join(base, f)
            if f in ("_migrate_v1.py", "_migrate_report.json"):
                continue
            ext = os.path.splitext(f)[1].lower()
            if ext in TEXT_EXT or f in (".gitignore", ".gitattributes", ".editorconfig"):
                yield p

def main():
    report = {"dry_run": DRY, "moves": [], "rewrites": [], "missing": []}
    for src, dst in DIR_MOVES:
        s, d = os.path.join(ROOT, src), os.path.join(ROOT, dst)
        if not os.path.exists(s):
            report["missing"].append(src); continue
        report["moves"].append([src, dst])
        if not DRY:
            os.makedirs(os.path.dirname(d), exist_ok=True)
            if os.path.exists(d):
                # 合并：把 s 下内容逐个挪进 d
                for name in os.listdir(s):
                    os.replace(os.path.join(s, name), os.path.join(d, name))
                os.rmdir(s)
            else:
                os.replace(s, d)
    for src, dst in FILE_MOVES:
        s, d = os.path.join(ROOT, src), os.path.join(ROOT, dst)
        if not DRY and not os.path.exists(s):
            raise SystemExit("FILE_MOVE 源不存在（目录迁移后仍找不到）：" + src)
        report["moves"].append([src, dst])
        if not DRY:
            os.makedirs(os.path.dirname(d), exist_ok=True)
            os.replace(s, d)

    total_hits = 0
    for p in walk_text_files():
        try:
            raw = open(p, "r", encoding="utf-8", newline="").read()
        except UnicodeDecodeError:
            continue
        new = raw
        hits = {}
        for old, nw in REPLACES:
            c = new.count(old)
            if c:
                hits[old] = c
                new = new.replace(old, nw)
        if new != raw:
            total_hits += sum(hits.values())
            report["rewrites"].append([os.path.relpath(p, ROOT), sum(hits.values()), hits])
            if not DRY:
                open(p, "w", encoding="utf-8", newline="").write(new)
    report["total_hits"] = total_hits
    with open(os.path.join(ROOT, "_migrate_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    print("moves:", len(report["moves"]), "rewritten files:", len(report["rewrites"]), "hits:", total_hits)
    if report["missing"]:
        print("MISSING:", report["missing"])
    top = sorted(report["rewrites"], key=lambda r: -r[1])[:15]
    for r in top:
        print("  %5d  %s" % (r[1], r[0]))
    print("dry_run:", DRY)

main()