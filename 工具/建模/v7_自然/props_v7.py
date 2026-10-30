# -*- coding: utf-8 -*-
"""
props_v7.py —— 地图自然物 v7（树 / 金矿 / 岩石）

v6 原件不动，这是副本 + 重写。坐标口径沿用 kit3：原点 = 占地中心，z=0 地面，+Y 正面。

  树   —— 5 层树冠，每层 = 2 个核心团 + 10 个边缘小叶簇（块状，不是压扁盘子），
          层间留有缺口、主枝/侧枝外露、暗-中-亮三层绿，6.5m；
  金矿 —— 岩体 + 石拱门 + 洞内木支护 + 金脉/金块（金属 + 微自发光）+ 矿车 / 镐 / 挂灯，~3.1m；
  岩石 —— 三块咬合的体量 + 青苔 + 碎石，~1.6m。
"""
import os
import sys
import math
import random

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "v3")))

import _v7_common as C
import kit3 as K3
from kit3 import Builder, mat, D, TAU, w_rigid
from mathutils import Vector

W = w_rigid("root")


# ===========================================================================
# 树 —— 6.5m
# ===========================================================================
def build_tree(H=6.5):
    coll = K3.reset_scene()
    b = Builder("tree")
    m_bark = mat("bark")
    m_bark_d = mat("bark_dark")
    m_leaf = mat("leaf")
    m_leaf_d = mat("leaf_dark")
    m_leaf_l = mat("leaf_light")

    trunk_top = 3.0
    # --- 树干
    rings = []
    for i in range(8):
        t = i / 7.0
        z = 0.03 + t * trunk_top
        r = 0.40 * (1.0 - 0.64 * t) + 0.02
        cx = 0.11 * math.sin(t * 2.4)
        cy = 0.07 * math.sin(t * 1.7 + 0.6)
        rings.append([(cx + r * math.cos(TAU * k / 10),
                       cy + r * 0.9 * math.sin(TAU * k / 10), z) for k in range(10)])
    b.add(K3._bm_loft(rings, cap_a=True, cap_b=True), m_bark, W)

    # --- 板根
    for i in range(6):
        a = TAU * i / 6.0 + 0.35
        p0 = (math.cos(a) * 0.12, math.sin(a) * 0.10, 0.44)
        p1 = (math.cos(a) * 0.72, math.sin(a) * 0.64, 0.02)
        C.cyl_between(b, p0, p1, 0.15, 0.045, m_bark_d, sides=5)

    # --- 三根主枝：斜出 + 分叉，分叉点落在树冠下沿的缺口里
    limbs = ((0.30, 1.70, 1.05), (2.30, 1.55, 1.00), (4.30, 1.45, 0.90))
    for i, (ang, reach, rise) in enumerate(limbs):
        z0 = 1.90 + i * 0.24
        base = (0.06, 0.05, z0)
        mid = (math.cos(ang) * reach * 0.52, math.sin(ang) * reach * 0.52, z0 + rise * 0.52)
        tip = (math.cos(ang) * reach, math.sin(ang) * reach, z0 + rise)
        C.cyl_between(b, base, mid, 0.15, 0.10, m_bark, sides=7)
        C.cyl_between(b, mid, tip, 0.10, 0.048, m_bark, sides=6)
        for s in (-1, 1):
            a2 = ang + s * 0.55
            t2 = (tip[0] + math.cos(a2) * 0.46, tip[1] + math.sin(a2) * 0.46, tip[2] + 0.40)
            C.cyl_between(b, mid, t2, 0.052, 0.030, m_bark_d, sides=5)

    # --- 树冠：5 层，核心团 + 边缘小叶簇
    tiers = (
        (3.30, 1.74, m_leaf_d, 0.00),
        (4.02, 1.54, m_leaf_d, 0.42),
        (4.70, 1.30, m_leaf, 0.86),
        (5.32, 1.02, m_leaf, 1.24),
        (5.88, 0.74, m_leaf_l, 1.62),
    )
    rnd = random.Random(2026)
    seed = 11
    for ti, (z0, rad, m_core, phase) in enumerate(tiers):
        ox = 0.10 * math.sin(ti * 1.7)
        oy = 0.08 * math.cos(ti * 1.3)
        # 2 个核心团（撑体量，subdiv2 才圆中带棱）
        for k in range(2):
            a = phase + k * math.pi + 0.3
            C.clump(b, (ox + math.cos(a) * rad * 0.30, oy + math.sin(a) * rad * 0.30,
                        z0 + 0.06 * k), rad * 0.60, m_core, seed=seed,
                    scale=(1.05, 1.0, 0.86), rot=(0, 0, a), rough=0.26, subdiv=2)
            seed += 1
        # 10 个边缘小叶簇：位置/大小/朝向都抖，读成"一簇簇叶子"
        for k in range(10):
            a = TAU * k / 10.0 + phase + rnd.uniform(-0.12, 0.12)
            rr = rad * (0.66 + rnd.uniform(-0.10, 0.12))
            r = rad * (0.26 + rnd.uniform(-0.05, 0.07))
            z = z0 + rnd.uniform(-0.16, 0.18)
            mm = m_core
            if k % 3 == 0:
                mm = m_leaf_l if ti >= 3 else m_leaf
            elif k % 5 == 0:
                mm = m_leaf_d
            C.clump(b, (ox + math.cos(a) * rr, oy + math.sin(a) * rr, z), r, mm, seed=seed,
                    scale=(1.0, 0.95, 0.88),
                    rot=(rnd.uniform(-0.5, 0.5), rnd.uniform(-0.5, 0.5), a + rnd.uniform(-0.5, 0.5)),
                    rough=0.34, subdiv=1)
            seed += 1

    # 顶芽
    C.clump(b, (0.02, 0.0, H * 0.955), 0.44, m_leaf_l, seed=97,
            scale=(1.0, 1.0, 0.95), rough=0.32, subdiv=2)
    # 树冠下沿的"裙摆"：压住生硬切边，同时给枝杈让出缺口
    for i in range(7):
        a = TAU * i / 7.0 + 0.20
        if i in (1, 4):          # 两个缺口对着主枝
            continue
        C.clump(b, (math.cos(a) * 1.10, math.sin(a) * 1.10, 2.98 + 0.05 * (i % 2)),
                0.44, m_leaf_d, seed=110 + i, scale=(1.0, 1.0, 0.78),
                rot=(0, 0, a), rough=0.32, subdiv=1)

    return b.build_meshes(coll)


# ===========================================================================
# 金矿 —— ~3.1m
# ===========================================================================
def build_goldmine():
    coll = K3.reset_scene()
    b = Builder("goldmine")
    m_rock = mat("rock")
    m_rock_d = mat("rock_dark")
    m_gold = mat("gold")
    m_glow = mat("gold_glow")
    m_ore = mat("ore")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_dark = mat("cavity")

    # --- 岩体
    C.clump(b, (0.0, 0.05, 1.12), 1.38, m_rock, seed=11,
            scale=(1.06, 0.92, 1.00), rough=0.15, subdiv=2)
    C.clump(b, (1.18, 0.16, 0.60), 0.84, m_rock_d, seed=12,
            scale=(1.0, 0.92, 0.86), rough=0.20, subdiv=1)
    C.clump(b, (-1.16, 0.06, 0.54), 0.76, m_rock_d, seed=13,
            scale=(1.0, 0.90, 0.88), rough=0.22, subdiv=1)
    C.clump(b, (0.06, -0.22, 2.46), 0.66, m_rock, seed=14,
            scale=(1.10, 0.95, 0.82), rough=0.20, subdiv=1)

    # 岩面求解（椭球近似）：金脉/金块必须贴着面，不能飘在空气里
    def surf(x, z, off=0.015):
        k = 1.0 - (x / 1.46) ** 2 - ((z - 1.12) / 1.38) ** 2
        return 0.05 + 1.27 * math.sqrt(max(k, 0.02)) + off

    # --- 洞口：矩形暗腔 + 石框（石框压住腔体边缘，读作"凿进去的门"）
    b.box((1.00, 0.06, 1.56), (0.0, 1.30, 0.82), material=m_dark, bevel=0.0)
    b.box((0.22, 0.30, 1.74), (-0.61, 1.33, 0.87), material=m_rock_d, bevel=0.03)
    b.box((0.22, 0.30, 1.74), (0.61, 1.33, 0.87), material=m_rock_d, bevel=0.03)
    b.box((1.46, 0.30, 0.22), (0.0, 1.33, 1.83), material=m_rock_d, bevel=0.03)
    b.box((0.40, 0.32, 0.18), (0.0, 1.30, 1.95), material=m_rock, bevel=0.035)

    # --- 洞内木支护（在石框里侧，暗一档）
    for sx in (-1, 1):
        px = sx * 0.42
        C.plank(b, (px, 1.26, 0.78), (0.13, 0.13, 1.56), m_wood_d)
        C.cyl_between(b, (px, 1.25, 1.30), (sx * 0.14, 1.25, 1.54), 0.042, 0.038, m_wood, sides=4)
    C.plank(b, (0.0, 1.26, 1.56), (1.02, 0.14, 0.14), m_wood)
    # 洞口挂灯（暖光，洞里唯一的亮点）
    C.rope_line(b, (0.0, 1.30, 1.54), (0.0, 1.38, 1.34), r=0.010, segs=2)
    C.clump(b, (0.0, 1.42, 1.26), 0.075, m_glow, seed=99, scale=(0.85, 0.85, 1.05), rough=0.12, subdiv=2)
    C.plank(b, (0.0, 1.42, 1.34), (0.13, 0.13, 0.035), m_iron, bevel=0.006)
    C.plank(b, (0.0, 1.42, 1.18), (0.11, 0.11, 0.030), m_iron, bevel=0.006)
    

    # --- 金脉：长在石框上（贴在石头表面，不会飘）
    C.cyl_between(b, (-0.70, 1.49, 1.62), (-0.52, 1.49, 1.18), 0.038, 0.022, m_gold, sides=5)
    C.cyl_between(b, (-0.66, 1.49, 1.28), (-0.72, 1.49, 0.86), 0.028, 0.016, m_glow, sides=5)
    C.cyl_between(b, (0.10, 1.49, 1.90), (0.44, 1.49, 1.86), 0.030, 0.018, m_glow, sides=5)
    C.cyl_between(b, (0.66, 1.49, 1.50), (0.74, 1.49, 1.12), 0.026, 0.015, m_gold, sides=5)
    # 洞口两侧堆着的矿石（半埋在地面里）
    for i, (nx, ny, nz, r) in enumerate(((-0.78, 1.05, 0.16, 0.115), (-0.58, 1.16, 0.10, 0.085),
                                        (0.80, 1.12, 0.13, 0.10), (0.96, 0.96, 0.09, 0.075))):
        C.clump(b, (nx, ny, nz), r, m_gold if i % 2 else m_glow, seed=70 + i,
                scale=(1.25, 0.95, 0.72), rough=0.32, subdiv=1)
    # --- 矿车（右前）
    cx, cy = 1.24, 1.06
    C.plank(b, (cx, cy, 0.46), (0.84, 0.60, 0.42), m_wood_d, bevel=0.02)
    C.plank(b, (cx, cy, 0.67), (0.90, 0.66, 0.05), m_wood)
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.cyl(0.145, 0.145, 0.06, loc=(cx + sx * 0.28, cy + sy * 0.31, 0.145),
                  rot=(D(90), 0, 0), material=m_iron, sides=10)
    C.clump(b, (cx, cy, 0.72), 0.25, m_ore, seed=88, scale=(1.3, 1.0, 0.5), rough=0.32, subdiv=1)
    C.clump(b, (cx + 0.10, cy - 0.08, 0.76), 0.095, m_gold, seed=89,
            scale=(1.3, 1.0, 0.8), rough=0.35, subdiv=1)
    C.clump(b, (cx - 0.10, cy + 0.08, 0.75), 0.085, m_gold, seed=90,
            scale=(1.2, 1.1, 0.8), rough=0.35, subdiv=1)

    # --- 镐（插在左侧地上）
    C.cyl_between(b, (-0.98, 1.20, 0.03), (-0.74, 1.06, 0.94), 0.030, 0.026, m_wood, sides=5)
    C.plank(b, (-0.78, 1.06, 0.98), (0.09, 0.33, 0.07), m_iron, rot=(0, D(16), 0))
    C.plank(b, (-0.62, 1.06, 1.08), (0.08, 0.29, 0.06), m_iron, rot=(0, D(-22), 0))

    # --- 地面碎石
    for i in range(7):
        a = TAU * i / 7.0 + 0.9
        rr = 1.18 + 0.30 * ((i % 3) / 2.0)
        C.clump(b, (math.cos(a) * rr, math.sin(a) * rr * 0.85, 0.08),
                0.10 + 0.05 * (i % 3), m_rock_d, seed=140 + i,
                scale=(1.1, 1.0, 0.65), rough=0.30, subdiv=1)

    return b.build_meshes(coll)


# ===========================================================================
# 岩石 —— ~1.6m
# ===========================================================================
def build_rock(size=1.6):
    coll = K3.reset_scene()
    b = Builder("rock")
    m = mat("rock")
    m_d = mat("rock_dark")
    m_moss = mat("leaf_dark")

    C.clump(b, (0.0, 0.0, size * 0.42), size * 0.62, m, seed=21,
            scale=(1.18, 0.95, 0.80), rough=0.17, subdiv=2)
    C.clump(b, (size * 0.58, size * 0.18, size * 0.26), size * 0.40, m_d, seed=22,
            scale=(1.05, 0.95, 0.86), rough=0.22, subdiv=1)
    C.clump(b, (-size * 0.50, -size * 0.20, size * 0.20), size * 0.34, m_d, seed=23,
            scale=(1.0, 0.95, 0.88), rough=0.24, subdiv=1)

    for i in range(4):
        a = TAU * i / 4.0 + 0.7
        C.clump(b, (math.cos(a) * size * 0.30, math.sin(a) * size * 0.26, size * 0.66),
                size * 0.15, m_moss, seed=60 + i, scale=(1.4, 1.1, 0.30),
                rough=0.36, subdiv=1)
    for i in range(4):
        a = TAU * i / 4.0 + 1.2
        C.clump(b, (math.cos(a) * size * 0.82, math.sin(a) * size * 0.70, 0.06),
                size * 0.11, m_d, seed=80 + i, scale=(1.1, 1.0, 0.7), rough=0.32, subdiv=1)

    return b.build_meshes(coll)


BUILDERS = {"tree": build_tree, "goldmine": build_goldmine, "rock": build_rock}
FILE_OF = {"tree": "树.glb", "goldmine": "金矿.glb", "rock": "岩石.glb"}
RES_OF = {"tree": (820, 1040), "goldmine": (940, 1000), "rock": (760, 760)}
AO_DIST = {"tree": 1.30, "goldmine": 0.85, "rock": 0.60}
EMISSIVE = {
    "goldmine": [("gold_glow", (1.0, 0.80, 0.32), 1.4), ("ember", (1.0, 0.45, 0.12), 2.0)],
}

if __name__ == "__main__":
    C.run(BUILDERS, FILE_OF, res_of=RES_OF, emissive_of=EMISSIVE, ao_dist_of=AO_DIST, samples=48)
