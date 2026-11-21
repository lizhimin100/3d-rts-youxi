# -*- coding: utf-8 -*-
"""反向验证：故意改坏 → 看 --check 报错 → 改回 → 再通过。

用法：python Tools/checks/negative_demo.py
规矩（AGENTS.md）：每条检查都要反着验一次。这个脚本是"证据生成器"，
      它只改**副本**再恢复；不要手改产品文件来试。
"""
import csv, io, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BACKUP = ROOT / ".test_profile" / "neg_backup"
GODOT_CANDIDATES = [
    os.environ.get("GODOT_BIN", ""),
    r"E:/编辑器/tools/godot/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe",
    r"E:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe",
]


def find_godot() -> str:
    for c in GODOT_CANDIDATES:
        if c and Path(c).exists():
            return c
    raise SystemExit("找不到 Godot：设置 GODOT_BIN")


def run_check(godot: str) -> tuple[int, str]:
    p = subprocess.run([godot, "--headless", "--path", str(ROOT),
                        "--script", "Tests/checks/check_all.gd"],
                       cwd=str(ROOT), capture_output=True)
    out = (p.stdout or b"").decode("utf-8", "replace") + (p.stderr or b"").decode("utf-8", "replace")
    return p.returncode, out


def mutate_json(rel: str, fn) -> None:
    p = ROOT / rel
    data = json.loads(p.read_text(encoding="utf-8"))
    fn(data)
    p.write_text(json.dumps(data, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")


def set_card(path: str, key: str, value) -> None:
    mutate_json(path, lambda d: d["props"].__setitem__(key, value))


def find_unit(data: dict, uid: str) -> dict:
    for u in data.get("units", []):
        if u.get("id") == uid:
            return u
    raise KeyError(uid)


def find_card(data: dict, cid: str) -> dict:
    for c in data.get("cards", []):
        if c.get("id") == cid:
            return c
    raise KeyError(cid)


def loose_csv(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    rows = list(csv.reader(io.StringIO(text)))
    for r in rows[1:]:
        if r and r[0] == "debug.panel.shot":
            r[1] = ""
            break
    buf = io.StringIO()
    csv.writer(buf, lineterminator="\n").writerows(rows)
    path.write_text(buf.getvalue(), encoding="utf-8")


CASES = []


def case(name: str, mutate, restore):
    CASES.append((name, mutate, restore))


def main() -> int:
    godot = find_godot()
    BACKUP.mkdir(parents=True, exist_ok=True)

    def backup(rel: str) -> Path:
        src = ROOT / rel
        dst = BACKUP / rel.replace("/", "__")
        shutil.copy2(src, dst)
        return dst

    def restore(rel: str, bak: Path) -> None:
        shutil.copy2(bak, ROOT / rel)

    # 1. 卡数值非法
    def m1():
        bak = backup("Content/data/cards/units/footman.json")
        set_card("Content/data/cards/units/footman.json", "max_hp", -1)
        return lambda: restore("Content/data/cards/units/footman.json", bak)

    # 2. 引用断链
    def m2():
        bak = backup("Content/data/cards/buildings/barracks.json")
        set_card("Content/data/cards/buildings/barracks.json", "trains", ["no_such_unit"])
        return lambda: restore("Content/data/cards/buildings/barracks.json", bak)

    # 3. 文案缺列
    def m3():
        bak = backup("Content/i18n/ui.csv")
        loose_csv(ROOT / "Content/i18n/ui.csv")
        return lambda: restore("Content/i18n/ui.csv", bak)

    # 4. Model 破坏纯度（2026-11-21：Model 已是纯 C#，用 using Godot 触发）
    def m4():
        bak = backup("Model/Core/Rng.cs")
        p = ROOT / "Model/Core/Rng.cs"
        p.write_text(p.read_text(encoding="utf-8") + "\nusing Godot;\n", encoding="utf-8")
        return lambda: restore("Model/Core/Rng.cs", bak)

    # 5. 引擎层被就地修改
    def m5():
        bak = backup("Engine/util/json_file.gd")
        p = ROOT / "Engine/util/json_file.gd"
        p.write_text(p.read_text(encoding="utf-8") + "\n# neg probe\n", encoding="utf-8")
        return lambda: restore("Engine/util/json_file.gd", bak)

    # 6. 新增文件未登记 manifest
    def m6():
        p = ROOT / "Game/_neg_extra.gd"
        p.write_text("extends RefCounted\n", encoding="utf-8")
        return lambda: p.unlink(missing_ok=True)

    # 7. R1 被改（新内核）
    def m7():
        bak = backup("Content/data/combat.json")
        mutate_json("Content/data/combat.json", lambda d: d.__setitem__("r1", 0.02))
        return lambda: restore("Content/data/combat.json", bak)

    # 8. 长枪射程被改（隔排几何）
    def m8():
        bak = backup("Content/data/units.json")
        mutate_json("Content/data/units.json",
                    lambda d: find_unit(d, "alliance_pikeman").__setitem__("attack_range", 150))
        return lambda: restore("Content/data/units.json", bak)

    # 9. 训练牌 Tag 断链
    def m9():
        bak = backup("Content/data/planning.json")
        mutate_json("Content/data/planning.json",
                    lambda d: find_card(d, "train_footman").__setitem__("tag", "archery"))
        return lambda: restore("Content/data/planning.json", bak)

    # 10. 开局少一座农场
    def m10():
        bak = backup("Content/data/planning.json")

        def drop_farm(d):
            start = d["board"]["start"]
            for i, s in enumerate(start):
                if s.get("building") == "farm":
                    start.pop(i)
                    return
            raise KeyError("farm")

        mutate_json("Content/data/planning.json", drop_farm)
        return lambda: restore("Content/data/planning.json", bak)

    # 11. 波次刷出禁用单位
    def m11():
        bak = backup("Content/data/levels.json")

        def add_lord(d):
            wave = d["levels"][0]["rounds"][0]["enemy_waves"][0]
            wave["squads"].append({"unit": "bandit_lord", "count": 1})

        mutate_json("Content/data/levels.json", add_lord)
        return lambda: restore("Content/data/levels.json", bak)

    cases = [
        ("卡数值非法（max_hp=-1）", m1),
        ("数据引用断链（trains 指向不存在的兵）", m2),
        ("文案缺 zh 列", m3),
        ("Model 出现 using Godot", m4),
        ("Engine 被就地修改", m5),
        ("新增源文件未登记", m6),
        ("combat.r1 被改成 0.02", m7),
        ("长枪射程 155→150", m8),
        ("训练牌 tag 断链", m9),
        ("开局少一座农场", m10),
        ("波次刷 enabled=false 的领主", m11),
    ]
    print("========== 反向验证（故意改坏 → 必须报错 → 改回 → 通过） ==========")
    bad = 0
    for name, mutate in cases:
        undo = mutate()
        try:
            code, out = run_check(godot)
        finally:
            undo()
        ok = code != 0 and "✗" in out
        if ok:
            print("  ✓ %s  → 检查失败（退出码 %d）" % (name, code))
        else:
            bad += 1
            print("  ✗ %s  → 检查居然通过（退出码 %d）" % [name, code])
    code, out = run_check(godot)
    tail = [l for l in out.splitlines() if "CHECK" in l]
    print("---------------------------------------------------------------")
    print("恢复后：退出码 %d ｜ %s" % (code, tail[-1] if tail else "(无 CHECK 行)"))
    if bad or code != 0:
        print("NEGATIVE 失败 %d 项 ✗" % bad if bad else "NEGATIVE 恢复后仍未通过 ✗")
        return 1
    print("NEGATIVE 全部通过（%d 个改坏场景都被抓到）✓" % len(cases))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
