# -*- coding: utf-8 -*-
"""生成 Content/keys/assets.json（资源 key 唯一登记表）。

用法：python Tools/gen/gen_asset_keys.py
规则：
  · key = 文件名去掉扩展名；同目录重名时加父目录前缀；
  · 只登记资源文件（排除 .import / .uid / .md / .tres）；
  · 输出相对路径 res://…，游戏侧用 Keys.path(kind, key) 取。
"""
import json, os, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Content" / "keys" / "assets.json"

CATEGORIES = [
    ("audio",   ROOT / "Content" / "audio",   {".ogg", ".wav", ".mp3"}),
    ("models",  ROOT / "Content" / "art" / "模型",   {".glb", ".gltf"}),
    ("icons",   ROOT / "Content" / "art" / "图标",   {".svg", ".png", ".jpg", ".webp"}),
    ("shaders", ROOT / "Content" / "art" / "着色器", {".gdshader", ".shader"}),
    ("fx",      ROOT / "Content" / "art" / "特效",   {".tscn"}),
]
SKIP_DIRS = {"__pycache__", ".godot", "qc"}


def rel_res(path: Path) -> str:
    return "res://" + path.relative_to(ROOT).as_posix()


def build_bucket(base: Path, exts: set) -> dict:
    items = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix.lower() not in exts:
                continue
            items.append(p)
    items.sort()
    counts = {}
    for p in items:
        counts[p.stem] = counts.get(p.stem, 0) + 1
    bucket = {}
    for p in items:
        key = p.stem
        if counts[key] > 1:
            key = "_".join(p.relative_to(base).with_suffix("").parts)
        if key in bucket:
            print("WARN 重名 key，已跳过：%s" % key, file=sys.stderr)
            continue
        bucket[key] = rel_res(p)
    return bucket


def main() -> int:
    data = {"version": 1, "note": "由 Tools/gen/gen_asset_keys.py 自动生成；不要手改"}
    total = 0
    for kind, base, exts in CATEGORIES:
        if not base.exists():
            data[kind] = {}
            continue
        bucket = build_bucket(base, exts)
        data[kind] = bucket
        total += len(bucket)
        print("%-8s %4d 项" % (kind, len(bucket)))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
    print("写入 %s（共 %d 项）" % (OUT.relative_to(ROOT), total))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
