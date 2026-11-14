# -*- coding: utf-8 -*-
"""
decor_v7.py —— 点缀物 v7（草丛 / 营火 / 木桩 / 旗帜 / 路标 / 尸骨 / 帐篷 / 木箱 / 木桶 / 栅栏 / 断墙）

v6 原件不动，这是副本 + 重写：
  草丛  —— 真草叶簇（交叉细长叶片），20–40cm，不再用压扁球；
  营火  —— 石圈 + 交叉原木 + 炭火 + 火苗（自发光）；
  木桩  —— 板根 + 年轮顶面 + 嵌着的斧头；
  旗帜  —— 杆 + 飘旗（队伍色，网格带波动）；
  路标  —— 柱 + 两块歪木牌 + 铁钉；
  尸骨  —— 颅骨 + 肋骨弧 + 长骨；
  帐篷  —— A 字架 + 双坡布面（带下垂）+ 拉绳 + 地钉；
  木箱 / 木桶 / 栅栏 / 断墙 —— 新的营地与废墟件。
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
# 草丛 —— 20–40cm，纯草叶
# ===========================================================================
def build_bush():
    coll = K3.reset_scene()
    b = Builder("bush")
    mats = (mat("leaf"), mat("leaf_dark"), mat("grass"))
    rnd = random.Random(7)

    clusters = ((-0.13, -0.09), (0.12, -0.11), (0.0, 0.14), (0.14, 0.10))
    for ci, (cx, cy) in enumerate(clusters):
        n = 19 if ci % 2 == 0 else 16
        for i in range(n):
            a = TAU * i / n + rnd.uniform(-0.35, 0.35)
            rad = rnd.uniform(0.01, 0.10)
            bx = cx + math.cos(a) * rad
            by = cy + math.sin(a) * rad
            h = rnd.uniform(0.18, 0.40)
            lean = rnd.uniform(0.05, 0.22)
            tip = (bx + math.cos(a) * lean, by + math.sin(a) * lean, h)
            C.blade(b, (bx, by, 0.01), tip, rnd.uniform(0.010, 0.020),
                    mats[(i + ci) % 3 if (i % 4) else 2],
                    bend=(math.cos(a) * 0.03, math.sin(a) * 0.03, 0))
    # 中心短叶，补满底部
    for i in range(8):
        a = TAU * i / 8.0 + 0.4
        C.blade(b, (0.0, 0.0, 0.01),
                (math.cos(a) * 0.09, math.sin(a) * 0.09, rnd.uniform(0.10, 0.18)),
                0.022, mats[i % 2], bend=(0, 0, 0))
    return b.build_meshes(coll)


# ===========================================================================
# 营火
# ===========================================================================
def build_campfire():
    coll = K3.reset_scene()
    b = Builder("campfire")
    m_stone = mat("fire_stone")
    m_log = mat("wood")
    m_log_d = mat("wood_dark")
    m_ember = mat("ember")
    m_ash = mat("dirt")

    b.cyl(0.30, 0.30, 0.035, loc=(0, 0, 0.0), material=m_ash, sides=14)
    for i in range(9):
        a = TAU * i / 9.0 + 0.2
        C.clump(b, (math.cos(a) * 0.42, math.sin(a) * 0.42, 0.055), 0.105, m_stone,
                seed=10 + i, scale=(1.0, 1.0, 0.62), rough=0.30, subdiv=1)
    for i, a_deg in enumerate((18.0, 108.0, 198.0, 288.0)):
        a = math.radians(a_deg)
        b.cyl(0.048, 0.058, 0.72,
              loc=(math.cos(a) * 0.26, math.sin(a) * 0.26, 0.03),
              rot=(D(70), 0, D(a_deg + 270.0)),
              material=m_log if i % 2 == 0 else m_log_d, sides=6)
    C.clump(b, (0, 0, 0.09), 0.15, m_ember, seed=97, scale=(1.0, 1.0, 0.45), rough=0.35, subdiv=1)
    for i, (dx, dy, h, r) in enumerate(((0.0, 0.0, 0.46, 0.062), (0.10, 0.05, 0.30, 0.040),
                                        (-0.09, -0.04, 0.34, 0.046))):
        b.cyl(r, 0.003, h, loc=(dx, dy, 0.10), material=m_ember, sides=6,
              rot=(D(5 * (i - 1)), 0, D(8 * i)))
    return b.build_meshes(coll)


# ===========================================================================
# 木桩（带斧头）
# ===========================================================================
def build_stump():
    coll = K3.reset_scene()
    b = Builder("stump")
    m_bark = mat("bark")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_steel = mat("iron")

    b.cyl(0.37, 0.40, 0.56, loc=(0, 0, 0.0), material=m_bark, sides=12)
    for i, r in enumerate((0.36, 0.27, 0.18, 0.09)):
        b.cyl(r, r, 0.012, loc=(0, 0, 0.555), material=m_wood if i % 2 == 0 else m_wood_d, sides=12)
    for i in range(5):
        a = TAU * i / 5.0 + 0.3
        C.cyl_between(b, (math.cos(a) * 0.10, math.sin(a) * 0.10, 0.30),
                      (math.cos(a) * 0.56, math.sin(a) * 0.50, 0.02), 0.10, 0.035, m_bark, sides=5)
    # 斧头：柄斜插在桩顶，刃口朝外
    C.cyl_between(b, (0.10, 0.02, 0.56), (0.34, 0.26, 1.12), 0.028, 0.024, m_wood, sides=5)
    C.plank(b, (0.40, 0.31, 1.10), (0.16, 0.05, 0.20), m_steel, rot=(0, D(-18), D(38)))
    C.plank(b, (0.10, 0.02, 0.58), (0.10, 0.24, 0.05), m_wood_d, rot=(0, D(30), 0))
    return b.build_meshes(coll)


# ===========================================================================
# 旗帜（队伍色）
# ===========================================================================
def build_flag():
    coll = K3.reset_scene()
    b = Builder("flag")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_cloth = mat("cloth", team=True)
    m_gold = mat("gold")
    m_rope = mat("rope")

    for i in range(3):
        a = TAU * i / 3.0 + 0.6
        C.clump(b, (math.cos(a) * 0.20, math.sin(a) * 0.20, 0.06), 0.16, mat("fire_stone"),
                seed=5 + i, scale=(1.0, 1.0, 0.6), rough=0.3, subdiv=1)
    b.cyl(0.055, 0.045, 2.24, loc=(0, 0, 0.0), material=m_wood, sides=8)
    b.cyl(0.065, 0.065, 0.06, loc=(0, 0, 1.20), material=m_wood_d, sides=8)
    b.ico(0.062, loc=(0, 0, 2.30), material=m_gold, subdiv=2, scale=(1, 1, 1.15))
    b.cyl(0.018, 0.002, 0.12, loc=(0, 0, 2.34), material=m_gold, sides=6)

    # 旗面：上沿贴杆垂挂，向外收窄 18%，带行波
    W_, H_ = 1.02, 0.70
    def cloth(u, v):
        x = 0.05 + u * W_ * (1.0 - 0.18 * v)
        z = 2.14 - v * H_
        y = 0.050 * math.sin(u * 5.0 + 0.4) * (0.30 + 0.70 * u) - 0.02 * v
        return (x, y, z + 0.04 * math.sin(u * 3.1) * v)
    C.grid_surface(b, cloth, 7, 4, m_cloth)
    # 系旗环
    for i in range(3):
        z = 2.10 - i * 0.22
        C.hoop(b, z, 0.075, 0.010, m_rope, segs=8, sides=3)
    return b.build_meshes(coll)


# ===========================================================================
# 路标
# ===========================================================================
def build_sign():
    coll = K3.reset_scene()
    b = Builder("sign")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")

    b.box((0.11, 0.11, 1.46), (0, 0, 0.73), material=m_wood, bevel=0.012)
    b.box((0.16, 0.16, 0.05), (0, 0, 1.46), material=m_wood_d, bevel=0.01)
    b.box((0.80, 0.065, 0.30), (0.05, 0.02, 1.14), material=m_wood_d, bevel=0.012,
          rot=(0, 0, D(7)))
    b.box((0.64, 0.06, 0.26), (0.02, 0.03, 0.82), material=m_wood, bevel=0.012,
          rot=(0, 0, D(-12)))
    b.box((0.72, 0.035, 0.07), (0.02, -0.02, 0.96), material=m_wood_d, rot=(0, 0, D(-12)))
    for i, (x, z) in enumerate(((-0.26, 1.16), (0.30, 1.12), (-0.20, 0.84), (0.22, 0.80))):
        b.cyl(0.013, 0.013, 0.02, loc=(x, 0.055, z), rot=(D(90), 0, 0), material=m_iron, sides=6)
    return b.build_meshes(coll)


# ===========================================================================
# 尸骨
# ===========================================================================
def build_bones():
    coll = K3.reset_scene()
    b = Builder("bones")
    m_bone = mat("bone")
    m_bone_d = mat("plaster")

    # 颅骨 + 下颌 + 眼窝
    C.clump(b, (0, 0, 0.20), 0.21, m_bone, seed=1, scale=(1.0, 1.15, 0.92), rough=0.12, subdiv=2)
    b.box((0.20, 0.16, 0.11), (0, 0.20, 0.13), material=m_bone, bevel=0.02)
    b.box((0.17, 0.08, 0.06), (0, 0.22, 0.06), material=m_bone_d, bevel=0.01)
    for sx in (-1, 1):
        C.clump(b, (sx * 0.075, 0.17, 0.235), 0.052, mat("cavity"), seed=3 + sx,
                scale=(1.0, 0.6, 1.0), rough=0.1, subdiv=1)
    # 肋（三根弧）
    for i, y in enumerate((-0.10, 0.06, 0.20)):
        pts = [(-0.30, y, 0.05), (-0.22, y - 0.02, 0.22), (0.0, y - 0.03, 0.28),
               (0.22, y - 0.02, 0.22), (0.30, y, 0.05)]
        b.tube(pts, 0.028, m_bone, weight=W, sides=5)
    # 长骨
    for i, (x, y, ang) in enumerate(((-0.48, 0.28, 24), (0.45, -0.10, -18), (0.10, 0.42, 66))):
        a = math.radians(ang)
        p0 = (x - math.cos(a) * 0.22, y - math.sin(a) * 0.22, 0.05)
        p1 = (x + math.cos(a) * 0.22, y + math.sin(a) * 0.22, 0.05)
        C.cyl_between(b, p0, p1, 0.030, 0.030, m_bone, sides=6)
        for p in (p0, p1):
            C.clump(b, (p[0], p[1], 0.06), 0.045, m_bone, seed=20 + i, scale=(1, 1, 0.8),
                    rough=0.2, subdiv=1)
    for i in range(4):
        a = TAU * i / 4.0 + 0.8
        C.clump(b, (math.cos(a) * 0.65, math.sin(a) * 0.45, 0.03), 0.04, m_bone_d,
                seed=30 + i, scale=(1.6, 1.0, 0.6), rough=0.3, subdiv=1)
    return b.build_meshes(coll)


# ===========================================================================
# 帐篷
# ===========================================================================
def build_tent():
    coll = K3.reset_scene()
    b = Builder("tent")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_canvas = mat("canvas")
    m_rope = mat("rope")

    ridge_z, half_y, pole_x, cloth_x = 1.50, 1.00, 0.76, 0.94
    # A 字架（在布里面）+ 脊杆
    for sy in (-1, 1):
        y = sy * (half_y - 0.08)
        for sx in (-1, 1):
            C.cyl_between(b, (sx * pole_x, y, 0.0), (0.0, y, ridge_z - 0.02), 0.048, 0.040, m_wood, sides=6)
        b.box((0.14, 0.12, 0.10), (0, y, ridge_z - 0.06), material=m_wood_d, bevel=0.012)
    C.cyl_between(b, (0, -half_y - 0.06, ridge_z), (0, half_y + 0.06, ridge_z), 0.042, 0.042, m_wood, sides=6)

    # 双坡布面：从脊到地，带下垂；布在柱外侧
    def slope(side):
        def fn(u, v):
            y = -half_y + u * 2 * half_y
            x = side * cloth_x * (1.0 - v)
            z = ridge_z * v
            sag = 0.045 * math.sin(math.pi * v) * (0.55 + 0.45 * math.sin(math.pi * u))
            return (x, y, z - sag)
        return fn
    C.grid_surface(b, slope(-1), 6, 3, m_canvas)
    C.grid_surface(b, slope(1), 6, 3, m_canvas)

    # 后片：三角形封口
    def back(u, v):
        x = (u * 2.0 - 1.0) * cloth_x * (1.0 - v)
        z = ridge_z * v
        return (x, -half_y, z)
    C.grid_surface(b, back, 6, 3, m_canvas)

    # 前片：同样三角形，中间留 6cm 门缝（两片各一半）
    for sx in (-1, 1):
        def front(u, v, sx=sx):
            x_in = sx * 0.022
            x_out = sx * cloth_x * (1.0 - v)
            x = x_in + (x_out - x_in) * u
            z = ridge_z * v
            return (x, half_y, z)
        C.grid_surface(b, front, 3, 3, m_canvas)

    # 拉绳：只留后侧两根，避免绳子从布面中间穿过去
    for sx in (-1, 1):
        top = (0.0, -half_y - 0.04, ridge_z - 0.02)
        peg = (sx * 1.12, -1.36, 0.0)
        C.rope_line(b, top, peg, r=0.012, material=m_rope, segs=4, sag=0.05)
        b.cyl(0.028, 0.020, 0.16, loc=(peg[0], peg[1], -0.02), rot=(D(70), 0, D(20)),
              material=m_wood_d, sides=5)
    return b.build_meshes(coll)


# ===========================================================================
# 木箱
# ===========================================================================
def build_crate():
    coll = K3.reset_scene()
    b = Builder("crate")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")

    b.box((0.78, 0.62, 0.62), (0, 0, 0.31), material=m_wood, bevel=0.012)
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.box((0.075, 0.075, 0.66), (sx * 0.355, sy * 0.275, 0.33), material=m_wood_d, bevel=0.008)
    for z in (0.15, 0.47):
        for sy in (-1, 1):
            b.box((0.80, 0.03, 0.09), (0, sy * 0.315, z), material=m_wood_d, bevel=0.006)
    # 盖板
    for i in range(4):
        b.box((0.19, 0.66, 0.045), (-0.30 + i * 0.20, 0, 0.645), material=m_wood if i % 2 else m_wood_d, bevel=0.006)
    for i, (x, y, z) in enumerate(((-0.30, 0.32, 0.16), (0.30, 0.32, 0.16), (-0.30, 0.32, 0.47),
                                   (0.30, 0.32, 0.47), (0.0, 0.32, 0.31))):
        b.cyl(0.014, 0.014, 0.02, loc=(x, y, z), rot=(D(90), 0, 0), material=m_iron, sides=6)
    return b.build_meshes(coll)


# ===========================================================================
# 木桶
# ===========================================================================
def build_barrel():
    coll = K3.reset_scene()
    b = Builder("barrel")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")

    prof = ((0.00, 0.235), (0.16, 0.272), (0.37, 0.288), (0.58, 0.272), (0.74, 0.235))
    rings = []
    for z, r in prof:
        rings.append([(r * math.cos(TAU * k / 14), r * math.sin(TAU * k / 14), z) for k in range(14)])
    b.add(K3._bm_loft(rings, cap_a=True, cap_b=True), m_wood, W)
    for z, r in ((0.005, 0.232), (0.735, 0.232)):
        b.cyl(r, r, 0.02, loc=(0, 0, z), material=m_wood_d, sides=14)
    for z, r in ((0.10, 0.252), (0.37, 0.292), (0.64, 0.252)):
        C.hoop(b, z, r, 0.014, m_iron, segs=16)
    b.cyl(0.045, 0.045, 0.03, loc=(0.12, 0.0, 0.745), material=m_wood_d, sides=8)
    return b.build_meshes(coll)


# ===========================================================================
# 栅栏
# ===========================================================================
def build_fence():
    coll = K3.reset_scene()
    b = Builder("fence")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    rnd = random.Random(31)

    xs = (-1.20, -0.40, 0.40, 1.20)
    for i, x in enumerate(xs):
        h = 1.02 + rnd.uniform(-0.04, 0.05)
        b.box((0.115, 0.115, h), (x, 0, h * 0.5), material=m_wood_d, bevel=0.01,
              rot=(0, 0, rnd.uniform(-0.04, 0.04)))
        b.box((0.145, 0.145, 0.05), (x, 0, h - 0.02), material=m_wood, bevel=0.008)
    # 两道横杆（最后一段断了一根）
    for si in range(3):
        x0, x1 = xs[si], xs[si + 1]
        for z in (0.44, 0.80):
            if si == 2 and z == 0.80:
                continue
            b.box((abs(x1 - x0) - 0.10, 0.055, 0.105), ((x0 + x1) * 0.5, 0, z + 0.01),
                  material=m_wood, bevel=0.008)
    # 断掉的那根斜垂下来
    b.box((0.74, 0.05, 0.10), (0.86, 0.06, 0.66), material=m_wood, bevel=0.006,
          rot=(0, D(-17), 0))
    # 斜撑
    C.cyl_between(b, (-1.28, -0.09, 0.10), (-0.40, -0.09, 0.86), 0.035, 0.030, m_wood_d, sides=4)
    return b.build_meshes(coll)


# ===========================================================================
# 断墙
# ===========================================================================
def build_wall():
    coll = K3.reset_scene()
    b = Builder("wall")
    m = (mat("stone"), mat("stone_dark"), mat("stone_light"))

    rnd = random.Random(77)
    # 5 层石砌，右侧塌成 1~2 层
    courses = ((0.11, 5), (0.33, 5), (0.55, 4), (0.77, 3), (0.99, 2))
    for ci, (z, n) in enumerate(courses):
        span = 2.6 - 0.30 * ci
        for k in range(n):
            x = -1.30 + span * (k + 0.5) / n + rnd.uniform(-0.03, 0.03)
            w = span / n - 0.035
            if ci >= 2 and x > 0.55:
                continue
            if ci == 1 and 0.05 < x < 0.35:
                continue              # 缺一块，露出洞
            h = 0.20 + rnd.uniform(-0.015, 0.02)
            b.box((w, 0.46 + rnd.uniform(-0.03, 0.03), h), (x, rnd.uniform(-0.02, 0.02), z),
                  material=m[(ci + k) % 3], bevel=0.012)
    # 顶面残石
    for i in range(4):
        x = -1.15 + i * 0.42 + rnd.uniform(-0.06, 0.06)
        b.box((0.30, 0.40, 0.16), (x, rnd.uniform(-0.04, 0.04), 1.10 + rnd.uniform(-0.05, 0.05)),
              material=m[i % 3], bevel=0.014, rot=(0, 0, rnd.uniform(-0.12, 0.12)))
    # 右侧塌落的碎块
    for i in range(9):
        a = rnd.uniform(-0.4, 1.2)
        rx = 0.85 + rnd.uniform(0, 0.75)
        ry = rnd.uniform(-0.65, 0.65)
        C.clump(b, (rx, ry, 0.09), 0.12 + rnd.uniform(0, 0.09), m[i % 3], seed=90 + i,
                scale=(1.2, 1.0, 0.7), rot=(0, 0, a), rough=0.30, subdiv=1)
    return b.build_meshes(coll)


BUILDERS = {
    "bush": build_bush, "campfire": build_campfire, "stump": build_stump,
    "flag": build_flag, "sign": build_sign, "bones": build_bones,
    "tent": build_tent, "crate": build_crate, "barrel": build_barrel,
    "fence": build_fence, "wall": build_wall,
}
FILE_OF = {
    "bush": "草丛.glb", "campfire": "营火.glb", "stump": "木桩.glb",
    "flag": "旗帜.glb", "sign": "路标.glb", "bones": "尸骨.glb",
    "tent": "帐篷.glb", "crate": "木箱.glb", "barrel": "木桶.glb",
    "fence": "栅栏.glb", "wall": "断墙.glb",
}
RES_OF = {
    "bush": (720, 720), "campfire": (760, 760), "stump": (760, 800),
    "flag": (760, 980), "sign": (700, 900), "bones": (760, 700),
    "tent": (900, 860), "crate": (720, 720), "barrel": (700, 760),
    "fence": (960, 720), "wall": (960, 720),
}
AO_DIST = {"bush": 0.45, "campfire": 0.5, "stump": 0.55, "flag": 0.9, "sign": 0.7,
           "bones": 0.45, "tent": 0.9, "crate": 0.5, "barrel": 0.5, "fence": 0.7, "wall": 0.7}
EMISSIVE = {"campfire": [("ember", (1.0, 0.42, 0.10), 3.0)]}

if __name__ == "__main__":
    C.run(BUILDERS, FILE_OF, res_of=RES_OF, emissive_of=EMISSIVE, ao_dist_of=AO_DIST, samples=40)
