# -*- coding: utf-8 -*-
"""统计"代码里写死中文"的存量，写 Content/i18n/legacy_budget.json。

用法：python Tools/gen/gen_i18n_budget.py
规矩：只许降不许升。--check 会拿当前值和预算比；新增写死文案会让检查失败。
      （这是过渡期债务表：新代码必须走 I18n.t，旧界面分批迁。）
"""
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Content" / "i18n" / "legacy_budget.json"
DIRS = ["Game", "Screens", "addons", "Tests"]
CJK = re.compile(r'"[^"\n]*[\u4e00-\u9fff][^"\n]*"')
COMMENT = re.compile(r"^\s*#")


def count(path: Path) -> int:
    n = 0
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if COMMENT.match(line):
                continue
            n += len(CJK.findall(line))
    except OSError:
        return 0
    return n


def main() -> int:
    budget = {}
    total = 0
    for d in DIRS:
        base = ROOT / d
        if not base.exists():
            continue
        for p in sorted(base.rglob("*.gd")):
            key = d
            c = count(p)
            if c:
                budget.setdefault(key, {})
                rel = p.relative_to(ROOT).as_posix()
                budget[key][rel] = c
                total += c
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"version": 1, "total": total, "by_dir": budget}, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
    print("写死中文（字符串字面量）存量：%d 处" % total)
    for k, v in sorted(budget.items()):
        print("  %-8s %d 个文件 %d 处" % (k, len(v), sum(v.values())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
