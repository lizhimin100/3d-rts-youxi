# -*- coding: utf-8 -*-
"""生成 Engine/pin.json：共享引擎层每个文件的 sha256。

用法：python Tools/gen/gen_engine_pin.py
规矩：改了 Engine/ 而不重新生成 → run-game --check 报「引擎层被就地修改」。
      这是刻意让共享库可独立发版、可被别的项目整目录拷走。
"""
import hashlib, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Engine"
OUT = ENGINE / "pin.json"
SKIP = {"pin.json"}


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    files = {}
    for p in sorted(ENGINE.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(ENGINE).as_posix()
        if rel in SKIP or "__pycache__" in rel:
            continue
        files[rel] = {"sha256": sha256(p), "size": p.stat().st_size}
    version = (ENGINE / "VERSION").read_text(encoding="utf-8").strip() if (ENGINE / "VERSION").exists() else ""
    OUT.write_text(json.dumps({"version": version, "files": files}, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
    print("Engine/pin.json：%d 个文件，版本 %s" % (len(files), version))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
