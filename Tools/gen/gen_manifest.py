# -*- coding: utf-8 -*-
"""生成 Content/manifest.json：源码/内容文件清单（**增删文件才需要重跑**）。

用法：python Tools/gen/gen_manifest.py
规矩：新增/删除源文件后 --check 会失败，提示你重跑这个脚本（不手改清单）。
      清单只记路径与大小，改内容不会让检查失效（内容由各自的校验负责）。
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Content" / "manifest.json"
DIRS = ["Game", "Screens", "Model", "Engine", "Tests", "Tools", "Content/data",
        "Content/i18n", "Content/keys", "addons"]
SKIP_DIRS = {"__pycache__", ".godot", "qc", "jobs", "bin", "obj"}
SKIP_EXT = {".import", ".tmp", ".log"}


def main() -> int:
    entries = []
    for d in DIRS:
        base = ROOT / d
        if not base.exists():
            continue
        for p in sorted(base.rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(ROOT).as_posix()
            if any(part in SKIP_DIRS for part in p.parts):
                continue
            if p.suffix.lower() in SKIP_EXT:
                continue
            entries.append({"path": rel, "size": p.stat().st_size})
    OUT.write_text(json.dumps({"version": 1, "files": entries}, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
    print("Content/manifest.json：%d 个文件" % len(entries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())