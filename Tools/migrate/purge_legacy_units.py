# -*- coding: utf-8 -*-
"""物理删除旧单兵 / 旧寻路 / 旧测试图（一次性脚本，跑完即弃）。

为什么不手工一个个删：
  · 旧的单兵系统是**跨 6 个目录的一张网**（场景 → 输入 → HUD → 单位 → 系统 → 适配层），
    漏掉一个文件就会在 `--check` 的硬路径断言里留下一根断线；
  · `.gd.uid` 必须跟着 `.gd` 一起走，否则 Godot 会在导入时重建一堆孤儿 uid。

跑法：python Tools/migrate/purge_legacy_units.py --dry
      python Tools/migrate/purge_legacy_units.py
"""

from __future__ import annotations

import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# --- 整个目录一起走 ---------------------------------------------------------
DIRS = [
    "Screens/world/crowd",      # 旧寻路（流场 / 导航 / 人群模拟）——零外部引用
    "Screens/input",            # 旧单兵框选 / 右键移动 / 部署输入（新玩法输入在 战役战场.gd）
    "Game/core",                # 旧主场景 / 关卡 / 回合 / 全局状态 / 阵营
    "Game/units",               # 旧单兵实体（单位 / 建筑 / 采集 / 工地）
    "Game/systems",             # 旧战斗 / 技能 / 据点 / 日夜 / 野怪 / 升星
    "Game/map",                 # 旧地图加载 / 生成 / 占格（底壳装配已由 SquadArena 负责）
    "Game/config",              # 旧卡资源体系（数值真源已收敛到 Content/data/*.json）
    "Tests/suites",             # 旧系统的历史自检（新自检在 Tests/checks 与 Tests/model）
]

# --- 单个文件 → 只留新玩法要用的那个 ---------------------------------------
FILES = [
    "Screens/scenes/主场景.tscn",
    "Screens/scenes/小队战场.tscn",
    "Screens/scenes/人群演示.tscn",
    "Screens/scenes/四季演示.tscn",
    "Screens/world/规划沙盘.gd",
    "Screens/world/squad/小队战场.gd",
    "Screens/camera/魔兽镜头.gd",
    "Screens/hud/HUD.gd",
    "Screens/hud/选中面板.gd",
    "Screens/hud/头顶界面.gd",
    "Screens/hud/命令卡.gd",
    "Screens/hud/建筑面板.gd",
    "Screens/hud/经验条.gd",
    "Screens/hud/头像台.gd",
    "Screens/hud/规划阶段界面.gd",
    "Screens/hud/规划地图层.gd",
    "Screens/hud/阶段提示.gd",
    "Screens/hud/敌方意图条.gd",
    "Screens/hud/光标术.gd",
    "Screens/hud/触感回声.gd",
    "Screens/hud/说明气泡.gd",
    "Screens/hud/小地图.gd",
    "Screens/hud/选择网格.gd",
    "Screens/hud/徽记.gd",
    "Screens/hud/数值列.gd",
    "Screens/hud/浮雕底板.gd",
    "Screens/hud/装饰.gd",
    "Screens/hud/词条.gd",
    "Screens/hud/按钮框.gd",
    "Screens/hud/界面规格.gd",
    "Screens/hud/小队HUD.gd",
    "Screens/world/art/姿态层.gd",
    "Screens/world/art/建造表现.gd",
    "Screens/world/art/地表细节.gd",
    "Screens/world/art/选中圈贴地.gd",
    "Screens/world/art/营火外观.gd",
    "Screens/world/art/组合件.gd",
    "Screens/world/art/建筑基座.gd",
    "Screens/world/art/程序化自然物.gd",
    "Screens/world/art/程序化树.gd",
    "Screens/world/art/树库.gd",
    "Game/adapters/damage.gd",
    "Game/adapters/economy.gd",
    "Game/adapters/progression.gd",
    "Game/adapters/rng.gd",
    "Game/adapters/save_schema.gd",
    "Game/adapters/skirmish.gd",
    "Game/adapters/layout_card.gd",
    "Game/adapters/可用性.gd",
    "Game/commands/命令记录.gd",
    "Game/commands/部署类型.gd",
    "Game/audio/音效管理.gd",
    "Model/Battle/LaneBattle.cs",
    "Model/Battle/LevelRunner.cs",
    "Model/Battle/LevelSimulator.cs",
    "Model/Battle/Skirmish.cs",
    "Content/maps/_四季演示.tres",
    "Content/maps/_测试地图.tres",
    "Content/maps/_自动保存.tres",
    "Tools/生成四季演示图.gd",
]

# 删空目录后顺手清掉的空壳目录（父目录留着没意义）
EMPTY_CANDIDATES = ["Game/commands", "Game/audio", "Screens/camera", "Screens/input"]


def remove_file(path: str) -> int:
    n = 0
    for p in (path, path + ".uid"):
        if os.path.isfile(p):
            os.remove(p)
            n += 1
            print("  - " + os.path.relpath(p, ROOT))
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()
    removed = 0
    for d in DIRS:
        full = os.path.join(ROOT, d)
        if not os.path.isdir(full):
            continue
        print("[" + d + "]")
        for name in sorted(os.listdir(full)):
            p = os.path.join(full, name)
            if os.path.isfile(p):
                if args.dry:
                    print("  - " + os.path.relpath(p, ROOT))
                    removed += 1
                else:
                    removed += remove_file(p)
    print("[单文件]")
    for f in FILES:
        p = os.path.join(ROOT, f)
        if os.path.isfile(p):
            if args.dry:
                print("  - " + f)
                removed += 1
            else:
                removed += remove_file(p)
        elif os.path.isfile(p + ".uid"):
            print("  ! 只剩 uid：" + f)
    if not args.dry:
        for d in EMPTY_CANDIDATES:
            full = os.path.join(ROOT, d)
            if os.path.isdir(full) and not os.listdir(full):
                os.rmdir(full)
                print("  = 删空目录 " + d)
                removed += 1
    print(("DRY " if args.dry else "") + "共处理 %d 项" % removed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
