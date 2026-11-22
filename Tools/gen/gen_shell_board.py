#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把底壳重建成「三区各一屏 + 玩家区 3 列 × 6 格 PvZ 棋盘」的规范形状。

为什么不手改 map_shells.json：
  · 18 个格子的坐标 × 高度采样 × 地表索引，手敲必错，而且扩容后高度场要全量重算
    （cols × rows = 140 × 30 = 4200 个点），人眼根本核不了；
  · 这张形状是**规格**（3 列 × 每列 6 格 / 格间 ≥1m / 左上角建筑位 + 中心出兵位），
    写成脚本才能在下一次改尺寸时一比一复现。

用法：
    python Tools/gen/gen_shell_board.py            # 重刷 shell_ridge_01 的几何
    python Tools/gen/gen_shell_board.py --dry      # 只打印，不写盘

几何口径（唯一来源就是本文件的常量，改这里就够）：
    地图 208 × 44 m；玩家 / 中立 / 敌方 = 72 / 64 / 72 m 宽，三区都 40 m 深。
    玩家区：主堡格 9×9 + 3 lanes × 6 columns，格子 7×7，格间 1.3 m（≥ TacticalTile.MinGapM）。
    中立区：1 个 12×12 据点格（角色仍然是 build，但 side=neutral —— 谁买下它就从这前压）。
    敌方区：主堡格 9×9 + 3 columns × 2 lanes。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHELLS = os.path.join(ROOT, "Content", "data", "map_shells.json")

R1 = 0.015

# --- 地图与三区 -------------------------------------------------------------
MAP_SX = 208.0
MAP_SZ = 44.0
REGION_Z = 20.0          # 三区共同的深度半高
REGION_W = 72.0          # 玩家 / 敌方区宽
NEUTRAL_W = 64.0         # 中立区宽

# --- 棋盘 -------------------------------------------------------------------
CELL = 7.0
GAP = 1.3
LANES = 3
COLS = 6
OUTPOST = 12.0
KEEP = 9.0
ENEMY_COLS = 3
ENEMY_LANES = 2


def board_axes() -> dict:
    """玩家区 3×6 棋盘的格子中心坐标（X 沿战场，Z 横向）。"""
    pitch = CELL + GAP
    # 最前一列的中心：离玩家区右边界 13.5m（格子半宽 3.5 → 前沿 10m 留白给"前缘推进"）
    x0 = -MAP_SX * 0.5 + REGION_W - 13.5
    xs = [x0 - pitch * i for i in range(COLS)]     # 从前往后
    xs.reverse()                                   # → 从后往前（X 递增）
    zs = [(i - (LANES - 1) * 0.5) * pitch for i in range(LANES)]
    return {"xs": xs, "zs": zs, "pitch": pitch}


def build_tiles() -> list:
    tiles = []
    idx = 1
    axes = board_axes()
    px_left = -MAP_SX * 0.5
    # 1 主堡格：贴着玩家区后墙
    tiles.append({
        "index": float(idx), "side": "player", "role": "keep",
        "x": round(px_left + KEEP * 0.5 + 1.0, 2), "z": 0.0,
        "w": KEEP, "d": KEEP, "yaw": 0.0,
        "base_w": KEEP, "base_d": KEEP,
    })
    idx += 1
    # 2..19 玩家 3 lanes × 6 columns
    for zi, z in enumerate(axes["zs"]):
        for xi, x in enumerate(axes["xs"]):
            tiles.append({
                "index": float(idx), "side": "player", "role": "build",
                "x": round(x, 2), "z": round(z, 2),
                "w": CELL, "d": CELL, "yaw": 0.0,
                "base_w": CELL, "base_d": CELL,
            })
            idx += 1
    # 20 中立据点
    tiles.append({
        "index": float(idx), "side": "neutral", "role": "build",
        "x": 0.0, "z": 0.0, "w": OUTPOST, "d": OUTPOST, "yaw": 0.0,
        "base_w": OUTPOST, "base_d": OUTPOST,
    })
    idx += 1
    # 21 敌方主堡
    ex_right = MAP_SX * 0.5
    tiles.append({
        "index": float(idx), "side": "enemy", "role": "keep",
        "x": round(ex_right - KEEP * 0.5 - 1.0, 2), "z": 0.0,
        "w": KEEP, "d": KEEP, "yaw": 180.0,
        "base_w": KEEP, "base_d": KEEP,
    })
    idx += 1
    # 22..27 敌方 3 columns × 2 lanes
    pitch = axes["pitch"]
    ex0 = MAP_SX * 0.5 - REGION_W + 14.0
    exs = [ex0 + pitch * i for i in range(ENEMY_COLS)]
    ezs = [(i - (ENEMY_LANES - 1) * 0.5) * pitch for i in range(ENEMY_LANES)]
    for z in ezs:
        for x in exs:
            tiles.append({
                "index": float(idx), "side": "enemy", "role": "build",
                "x": round(x, 2), "z": round(z, 2),
                "w": CELL, "d": CELL, "yaw": 180.0,
                "base_w": CELL, "base_d": CELL,
            })
            idx += 1
    return tiles


def build_spine() -> dict:
    """11 点弯曲脊线：从玩家区后墙到敌方区前墙，X 单调递增（Validate 会查回折）。"""
    n = 11
    x_start, x_end = -MAP_SX * 0.5 + 12.0, MAP_SX * 0.5 - 12.0
    wave = [0.0, -2.2, -3.4, -2.0, 1.4, 2.6, 1.2, -1.6, -2.8, -1.2, 0.0]
    pts = []
    for i in range(n):
        t = i / (n - 1)
        x = x_start + (x_end - x_start) * t
        pts.append({"x": round(x, 2), "z": round(wave[i % len(wave)], 2)})
    length_m = 0.0
    for i in range(1, n):
        dx = pts[i]["x"] - pts[i - 1]["x"]
        dz = pts[i]["z"] - pts[i - 1]["z"]
        length_m += math.hypot(dx, dz)
    return {
        "length_logic": round(length_m / R1, 1),
        "length_m": round(length_m, 2),
        "width_logic": 420.0,
        "width_m": round(420.0 * R1, 2),
        "points": pts,
        "note": "弯曲行军脊线：11 点折线，X 单调递增；小队 A* 沿这些点推进。",
    }


def build_regions() -> dict:
    p_right = -MAP_SX * 0.5 + REGION_W
    n_left, n_right = p_right, p_right + NEUTRAL_W
    return {
        "player": [[-MAP_SX * 0.5, -REGION_Z], [p_right, -REGION_Z], [p_right, REGION_Z], [-MAP_SX * 0.5, REGION_Z]],
        "neutral": [[n_left, -REGION_Z], [n_right, -REGION_Z], [n_right, REGION_Z], [n_left, REGION_Z]],
        "enemy": [[n_right, -REGION_Z], [MAP_SX * 0.5, -REGION_Z], [MAP_SX * 0.5, REGION_Z], [n_right, REGION_Z]],
    }


def terrain_grid() -> tuple:
    cell = 1.5
    cols = int(round(MAP_SX / cell)) + 1
    rows = int(round(MAP_SZ / cell)) + 1
    return cell, cols, rows


def build_terrain() -> dict:
    """高度场 + 地表索引。

    高度口径：三区各自是一条平缓台地（基准 1.0 / 1.25 / 0.85 米），区与区之间用一条
    宽 6m 的缓坡过渡；四周再抬一圈 1.2m 的土坡把边界藏起来。整幅最大起伏 < 0.45m，
    保证 7×7 的格子不会被地形切穿（格子按中心采样贴地）。
    """
    cell, cols, rows = terrain_grid()
    ox, oz = -MAP_SX * 0.5, -MAP_SZ * 0.5
    p_right = -MAP_SX * 0.5 + REGION_W
    n_right = p_right + NEUTRAL_W

    def base_of(x: float) -> float:
        if x < p_right:
            return 1.00
        if x < p_right + 6.0:
            t = (x - p_right) / 6.0
            return 1.00 + 0.25 * t
        if x < n_right - 6.0:
            return 1.25
        if x < n_right:
            t = (n_right - x) / 6.0
            return 0.85 + 0.40 * t
        return 0.85

    heights = []
    for r in range(rows):
        z = oz + r * cell
        for c in range(cols):
            x = ox + c * cell
            h = base_of(x)
            # 玩家区（棋盘所在）**完全压平**：7×7 的格子上如果地形还在起伏，
            # 土坡会从格子中间斜切上来，看起来像"格子被劈成两半"。
            amp = 1.0
            h += amp * 0.10 * math.sin(x * 0.21) * math.cos(z * 0.17)
            h += amp * 0.05 * math.sin(x * 0.47 + 1.1)
            # 四周土坡（把地图边缘藏起来，也让镜头拉到边界时不像纸片）
            edge = min(MAP_SX * 0.5 - abs(x), MAP_SZ * 0.5 - abs(z))
            if edge < 7.0:
                h += 1.15 * (1.0 - max(edge, 0.0) / 7.0) ** 2
            heights.append(round(h, 3))

    # 地表索引：草地为底，脊线走廊铺泥土，据点周围沙地，四周岩石
    palette = [
        {"id": "grass", "display_name": "草地", "color": "#5D6B3F"},
        {"id": "dirt", "display_name": "泥土", "color": "#6B5A43"},
        {"id": "rock", "display_name": "岩石", "color": "#5A5F68"},
        {"id": "sand", "display_name": "沙地", "color": "#8A7A56"},
    ]
    surf = []
    for r in range(rows):
        z = oz + r * cell
        for c in range(cols):
            x = ox + c * cell
            edge = min(MAP_SX * 0.5 - abs(x), MAP_SZ * 0.5 - abs(z))
            if edge < 5.0:
                surf.append(2.0)
            elif abs(z) < 5.0 and abs(x) > 8.0:
                surf.append(1.0)
            elif abs(x) < 14.0 and abs(z) < 14.0:
                surf.append(3.0)
            else:
                surf.append(0.0)
    assert len(heights) == cols * rows and len(surf) == cols * rows
    return {
        "cell": cell,
        "ambient": {"energy": 0.62, "tint": "#7C8DA6", "fog_density": 0.0018,
                    "sun_yaw": -62.0, "sun_pitch": -46.0},
        "heights": heights,
        "note": "三区台地高度场（1.5m 格）：玩家 1.00 / 中立 1.25 / 敌方 0.85，区界 6m 缓坡，四周 1.2m 土坡。",
    }, {"palette": palette, "index": surf}


def _height_at(terrain: dict, x: float, z: float) -> float:
    """与 ShellStore.height_at_shell 同一套双线性采样（脚本侧只用来给装饰贴地）。"""
    cell = float(terrain["cell"])
    hs = terrain["heights"]
    cols = int(round(MAP_SX / cell)) + 1
    rows = int(round(MAP_SZ / cell)) + 1
    ox, oz = -MAP_SX * 0.5, -MAP_SZ * 0.5
    fx = min(max((x - ox) / cell, 0.0), cols - 1.0)
    fz = min(max((z - oz) / cell, 0.0), rows - 1.0)
    c0, r0 = int(math.floor(fx)), int(math.floor(fz))
    c1, r1 = min(c0 + 1, cols - 1), min(r0 + 1, rows - 1)
    tx, tz = fx - c0, fz - r0
    a = hs[r0 * cols + c0] * (1 - tx) + hs[r0 * cols + c1] * tx
    b = hs[r1 * cols + c0] * (1 - tx) + hs[r1 * cols + c1] * tx
    return a * (1 - tz) + b * tz


def _flatten_under_tiles(terrain: dict, tiles: list) -> None:
    cell = float(terrain["cell"])
    hs = terrain["heights"]
    cols = int(round(MAP_SX / cell)) + 1
    rows = int(round(MAP_SZ / cell)) + 1
    ox, oz = -MAP_SX * 0.5, -MAP_SZ * 0.5
    for t in tiles:
        hw = float(t["w"]) * 0.5 + 1.0
        hd = float(t["d"]) * 0.5 + 1.0
        y = float(t["terrain_y"])
        c0 = max(int(math.floor((t["x"] - hw - ox) / cell)), 0)
        c1 = min(int(math.ceil((t["x"] + hw - ox) / cell)), cols - 1)
        r0 = max(int(math.floor((t["z"] - hd - oz) / cell)), 0)
        r1 = min(int(math.ceil((t["z"] + hd - oz) / cell)), rows - 1)
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                hs[r * cols + c] = y


def build_decor(terrain: dict) -> list:
    """纯视觉装饰：只实例化 asset_manifest 里登记过的既有资产（树 / 岩石）。"""
    import random
    rnd = random.Random(20261122)
    out = []

    def add(kind: str, asset: str, x: float, z: float, s: float) -> None:
        out.append({
            "kind": kind, "asset": asset,
            "x": round(x, 2), "z": round(z, 2),
            "y": round(_height_at(terrain, x, z), 3),
            "yaw": round(rnd.uniform(0.0, 360.0), 1),
            "scale": round(s, 2),
        })

    # 上下两条边缘林带（树把地图边界藏住）
    for i in range(30):
        x = -MAP_SX * 0.5 + 6.0 + i * (MAP_SX - 12.0) / 29.0 + rnd.uniform(-1.4, 1.4)
        for sign in (-1.0, 1.0):
            z = sign * (REGION_Z + rnd.uniform(-0.6, 1.6))
            add("tree", ("pine", "wood", "oak")[i % 3], x, z, rnd.uniform(0.85, 1.2))
    # 区界石块（提示"这里是分界"，不是墙；避开脊线走廊）
    for i in range(20):
        x = -MAP_SX * 0.5 + 12.0 + i * (MAP_SX - 24.0) / 19.0
        z = rnd.choice([-1.0, 1.0]) * rnd.uniform(13.5, 18.5)
        add("rock", "boulder", x, z, rnd.uniform(0.7, 1.3))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()

    doc = json.load(open(SHELLS, encoding="utf-8"))
    shells = doc["shells"]
    if not shells:
        print("没有底壳", file=sys.stderr)
        return 1
    shell = shells[0]
    shell["size"] = {"x": MAP_SX, "z": MAP_SZ}
    shell["regions"] = build_regions()
    shell["spine"] = build_spine()
    shell["tiles"] = build_tiles()
    shell["terrain"], shell["surface"] = build_terrain()
    # 格子贴地：先按中心采样高度场（与编辑器 ShellStore.height_at_shell 同一套双线性），
    # 再把**格子footprint 内的所有高度点压平到该高度**（外扩 1m）——
    # 7×7 的板子上如果地形还在起伏，土坡会从格子中间斜切上来，看起来像"格子被劈成两半"。
    for t in shell["tiles"]:
        t["terrain_y"] = round(_height_at(shell["terrain"], t["x"], t["z"]), 3)
    _flatten_under_tiles(shell["terrain"], shell["tiles"])
    shell["decorations"] = build_decor(shell["terrain"])
    shell["board"] = {
        "depth": 6.0, "bevel": 0.35, "margin": 0.45, "tile_scale": 1.0, "snap": 1.0,
        "theme": {
            "light": "#8FA05F", "dark": "#7A8C50", "rim": "#B9B183", "edge": "#3E4630",
            "keep": "#6E5B3A", "keep_dark": "#5F4E32",
            "neutral": "#8A7E5C", "enemy": "#7A4A3E", "enemy_dark": "#6A4034",
            "build_anchor": "#C08A2E", "spawn_anchor": "#4C9EFF",
        },
    }
    shell["note"] = (
        "三区各一屏：玩家 72m / 中立 64m / 敌方 72m（深 40m），任意两区之和 128~136m > 单屏。"
        "玩家区 = 3 lanes × 6 columns 的 PvZ 棋盘（7×7 格、格间 1.3m），"
        "左上角建筑位、正中心出兵位；中立区中央 12×12 据点格。"
    )

    cols = int(round(MAP_SX / 1.5)) + 1
    rows = int(round(MAP_SZ / 1.5)) + 1
    print(f"地图 {MAP_SX}×{MAP_SZ} m，格数 {len(shell['tiles'])}，"
          f"高度场 {cols}×{rows} = {len(shell['terrain']['heights'])} 点，"
          f"装饰 {len(shell['decorations'])}，脊线 {len(shell['spine']['points'])} 点 / "
          f"{shell['spine']['length_m']} m")
    if args.dry:
        print("[dry] 不写盘")
        return 0
    with open(SHELLS, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent="\t")
        f.write("\n")
    print("写回 " + SHELLS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
