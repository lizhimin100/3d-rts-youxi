# -*- coding: utf-8 -*-
"""
build_v2_自然.py —— 树 / 岩石 / 金矿（《美术规范》§3.3 / §4 / §6.2 的实现）
================================================================================
为什么重写（不是"顺手美化"）：
  · 旧版 树=460 tris、岩石=80 tris，规范 §4 给的是 树 3000~7000、岩石 800~2600，
    "下限也是门：低于下限视为没做细节，退回"。80 tris 的岩石是 4 个方块的集合，
    在大地图上会被读成一坨塑料。
  · 旧版没有 Root→Body 两层空节点（规范 §6.2 / 程序动画以 Body 判绑定）。
  · 旧版用 read_factory_settings 重置场景，没有清 rts_kit.MATS 缓存，
    导致下一次预览渲染拿到已销毁的材质引用（ReferenceError，实测崩溃）。

形体语言（每条都对着 §1）：
  树干 = 环形放样 + 连续收分 + 微弯；板根 5 片楔形；树皮竖棱 6 道；
  树冠 = 11 团**变形二十面体**（分面感来自顶点沿法向随机位移，不是缩放球）；
  岩石 = 大中小三块咬合的分面巨石 + 扁石碎片（"雕塑感"= 斜切面，不是圆球）；
  金矿 = 轴对齐基座 + 分面岩体 + 木支撑 + 矿车 + 嵌在岩缝里的金脉。

朝向：正面 +Y（矿洞口朝 +Y = Godot −Z）；底面 z=0；枢轴在底面中心。
"""
import bpy
import math
import os
import sys
import json
import random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rts_kit as K

OUT = os.path.join(K.OUT_ROOT, "自然物")
TAU = math.pi * 2.0
RNG = random.Random(20261017)


# ---------------------------------------------------------------------------
# 分面：沿顶点相对"团块中心"的方向做随机位移 —— 这是二十面体变"石头/树冠"的手法
# ---------------------------------------------------------------------------
def facet(ob, amp=0.18, seed=1, squash=None):
    rng = random.Random(seed)
    me = ob.data
    n = len(me.vertices)
    if n == 0:
        return ob
    cx = sum(v.co.x for v in me.vertices) / n
    cy = sum(v.co.y for v in me.vertices) / n
    cz = sum(v.co.z for v in me.vertices) / n
    for v in me.vertices:
        d = v.co - __import__("mathutils").Vector((cx, cy, cz))
        L = d.length
        if L < 1e-9:
            continue
        v.co = v.co + d.normalized() * (rng.uniform(-amp, amp) * L)
        if squash:
            base = __import__("mathutils").Vector((cx, cy, cz))
            rel = v.co - base
            v.co = base + __import__("mathutils").Vector((rel.x * squash[0], rel.y * squash[1], rel.z * squash[2]))
    for p in me.polygons:
        p.use_smooth = False
    me.update()
    return ob


def blob(name, r, loc, m, subdiv=2, amp=0.20, seed=1, squash=None):
    ob = K.ico(name, r, subdiv, m=m, loc=loc)
    return facet(ob, amp=amp, seed=seed, squash=squash)


def root_body():
    """规范 §6.2：建筑/自然物必须有 Root → Body（ProcAnim 以 Body 判绑定）。"""
    root = K.empty("Root", (0, 0, 0))
    body = K.empty("Body", (0, 0, 0))
    K.parent_to(body, root)
    return root, body


def adopt(body, objs):
    for o in objs:
        K.parent_to(o, body)


# ===========================================================================
# 1) 树 —— 4.5~6.5m（目标 5.5）
# ===========================================================================
def build_tree():
    K.reset_scene()
    m_bark, m_bark2, m_bark3 = K.mat("木"), K.mat("木暗"), K.mat("木浅")
    m_leaf, m_leaf2, m_leaf3 = K.mat("叶"), K.mat("叶暗"), K.mat("叶黄")
    m_dark = K.mat("阴影")
    root, body = root_body()
    objs = []
    H = 5.5

    # —— 树干：8 边放样，连续收分 + 轻微前倾弯曲（禁止直筒）——
    prof = [(0.000, 0.215, 0.000), (0.300, 0.196, 0.012), (0.900, 0.163, 0.030),
            (1.700, 0.136, 0.052), (2.500, 0.112, 0.066), (3.200, 0.090, 0.060),
            (3.600, 0.070, 0.040)]
    rings = []
    for (z, r, bend) in prof:
        rings.append((z, K.sq_ring(8, r, r * 0.94, 0.30, phase=math.pi / 8, cx=bend)))
    objs.append(K.loft("树干", rings, m_bark))

    # —— 板根：5 片楔形，沿周向分布（打破"一根柱子插在地上"）——
    for i in range(5):
        a = TAU * i / 5 + 0.4
        rr = 0.235
        px, py = math.cos(a) * rr, math.sin(a) * rr
        objs.append(K.prism("板根%d" % i,
                            [(-0.10, 0.0), (0.10, 0.0), (0.0, 0.42)],
                            0.30, m=m_bark2,
                            loc=(px, py, 0.02), rot=(0, 0, a - math.pi / 2), bevel=0.012))

    # —— 树皮竖棱：6 道，只在下半段（上半段靠树冠遮）——
    for i in range(6):
        a = TAU * i / 6 + 0.9
        for j, (z0, z1) in enumerate(((0.30, 1.30), (1.45, 2.35))):
            r0 = 0.205 - 0.045 * (z0 / 2.5)
            px, py = math.cos(a) * r0, math.sin(a) * r0
            objs.append(K.box("树皮棱%d_%d" % (i, j), (0.055, 0.055, z1 - z0),
                              m=m_bark3, loc=(px, py, (z0 + z1) * 0.5),
                              rot=(0, 0, a), bevel=0.010, top=0.6))

    # —— 枝：4 根，向外斜上（给树冠以"长出来的"结构）——
    for i in range(4):
        a = TAU * i / 4 + 0.55
        z0 = 2.35 + 0.22 * i
        dx, dy = math.cos(a), math.sin(a)
        L = 1.15 - 0.10 * i
        secs = [(0.0, 0.072), (0.45, 0.056), (1.0, 0.034)]
        objs.append(K.limb("枝%d" % i, secs, m_bark2,
                           pivot=(dx * 0.05, dy * 0.05, z0),
                           direction=(dx * 0.86, dy * 0.86, 0.52), sides=6, squarish=0.2))

    # —— 树冠：11 团变形二十面体（3 大 5 中 3 小），叶暗压底、叶黄点顶 ——
    clusters = [
        (0.00, 0.00, 4.62, 1.28, m_leaf, 0),
        (0.00, 0.00, 3.72, 1.05, m_leaf2, 1),
        (0.72, 0.34, 4.20, 0.86, m_leaf, 2),
        (-0.70, 0.30, 4.28, 0.82, m_leaf, 3),
        (0.30, -0.72, 4.16, 0.80, m_leaf2, 4),
        (-0.34, -0.66, 4.34, 0.78, m_leaf, 5),
        (0.62, 0.58, 5.06, 0.62, m_leaf3, 6),
        (-0.58, 0.52, 5.00, 0.58, m_leaf3, 7),
        (0.00, 0.00, 5.42, 0.52, m_leaf3, 8),
        (0.86, -0.30, 3.72, 0.54, m_leaf2, 9),
        (-0.84, -0.24, 3.80, 0.50, m_leaf2, 10),
    ]
    for (x, y, z, r, m, sd) in clusters:
        objs.append(blob("树冠%d" % sd, r, (x, y, z), m,
                         subdiv=3, amp=0.17, seed=100 + sd, squash=(1.0, 0.94, 0.80)))

    adopt(body, objs)
    K.fit_height(H)
    K.drop_to_ground()
    return K.export_glb(os.path.join(OUT, "树.glb"))


# ===========================================================================
# 2) 岩石 —— 最大边 1.2~2.6m
# ===========================================================================
def build_rock():
    K.reset_scene()
    m_s, m_s2, m_s3 = K.mat("石"), K.mat("石暗"), K.mat("石浅")
    root, body = root_body()
    objs = []

    # 主石：分面（斜切面而非圆球）+ 压扁，坐下时贴地
    objs.append(blob("主石", 0.92, (0.00, 0.00, 0.62), m_s,
                     subdiv=3, amp=0.235, seed=11, squash=(1.06, 0.86, 0.74)))
    # 次石两块：咬合在主石两侧，高度不同（避免"排排坐"）
    objs.append(blob("次石A", 0.52, (0.74, 0.30, 0.34), m_s2,
                     subdiv=3, amp=0.235, seed=12, squash=(1.0, 0.94, 0.78)))
    objs.append(blob("次石B", 0.40, (-0.62, -0.38, 0.26), m_s3,
                     subdiv=3, amp=0.235, seed=13, squash=(1.0, 0.90, 0.82)))
    # 扁石碎片：3 片（读作"崩落的石屑"，给轮廓以节奏）
    for i, (x, y, z, w) in enumerate(((0.52, -0.62, 0.07, 0.34),
                                      (-0.30, 0.68, 0.06, 0.28),
                                      (0.96, -0.10, 0.05, 0.22))):
        objs.append(K.prism("石屑%d" % i,
                            [(-w, -w * 0.7), (w, -w * 0.5), (w * 0.6, w * 0.8), (-w * 0.8, w * 0.6)],
                            0.10 + 0.04 * i, m=m_s3, loc=(x, y, z),
                            rot=(0, 0, 0.6 * i), bevel=0.008))

    adopt(body, objs)
    K.drop_to_ground()
    return K.export_glb(os.path.join(OUT, "岩石.glb"))


# ===========================================================================
# 3) 金矿 —— 4 × 3.5 × 3.2（基座必须是轴对齐矩形）
# ===========================================================================
def build_goldmine():
    K.reset_scene()
    m_s, m_s2, m_s3 = K.mat("石"), K.mat("石暗"), K.mat("石浅")
    m_soil, m_soil2 = K.mat("土"), K.mat("土暗")
    m_w, m_w2, m_w3 = K.mat("木"), K.mat("木暗"), K.mat("木浅")
    m_g, m_g2 = K.mat("金"), K.mat("金亮")
    m_iron, m_dark = K.mat("铁"), K.mat("阴影")
    m_cold = K.mat("冷影")
    root, body = root_body()
    objs = []

    # —— 轴对齐基座（4×3.5）：保证 footprint 是矩形，玩法能按 1m 网格摆 ——
    objs.append(K.box("基座", (4.00, 3.50, 0.26), m=m_soil, loc=(0, 0, 0.13),
                      bevel=0.030, top=0.97))
    objs.append(K.box("基座压边", (3.86, 3.36, 0.09), m=m_soil2, loc=(0, 0, 0.30),
                      bevel=0.020, top=0.98))

    # —— 岩体：三块分面巨石堆成矿丘，主峰在后（−Y），洞口朝 +Y ——
    objs.append(blob("岩体主", 1.42, (-0.15, -0.72, 1.62), m_s,
                     subdiv=4, amp=0.20, seed=21, squash=(1.10, 0.92, 0.94)))
    objs.append(blob("岩体左", 0.96, (-1.28, -0.30, 1.10), m_s2,
                     subdiv=3, amp=0.20, seed=22, squash=(0.92, 1.00, 0.92)))
    objs.append(blob("岩体右", 0.90, (1.22, -0.44, 1.02), m_s3,
                     subdiv=3, amp=0.20, seed=23, squash=(0.94, 1.00, 0.90)))
    objs.append(blob("岩体前顶", 0.72, (0.10, -1.05, 2.72), m_s2,
                     subdiv=3, amp=0.22, seed=24, squash=(1.0, 0.9, 0.8)))

    # —— 岩块：6 块小石咬在矿丘边缘（让"山"有碎石轮廓，而不是 3 个球）——
    chunks = [(-1.62, 0.42, 0.46, 0.34, 31), (1.58, 0.52, 0.40, 0.30, 32),
              (-0.86, -1.28, 0.72, 0.42, 33), (0.92, -1.22, 0.66, 0.38, 34),
              (-1.74, -0.46, 1.24, 0.30, 35), (1.70, -0.60, 0.94, 0.28, 36)]
    for (x, y, z, r, sd) in chunks:
        objs.append(blob("岩块%d" % sd, r, (x, y, z), (m_s if sd % 2 else m_s2),
                         subdiv=2, amp=0.26, seed=sd, squash=(1.0, 0.92, 0.86)))

    # —— 矿里必须有的东西：梯子（斜靠洞口内侧）——
    for sx in (-1, 1):
        objs.append(K.box("梯梁%d" % sx, (0.055, 0.055, 1.30), m=m_w2,
                          loc=(sx * 0.20, 0.72, 0.86),
                          rot=(math.radians(12), 0, 0), bevel=0.006))
    for i in range(7):
        objs.append(K.box("梯撑%d" % i, (0.42, 0.045, 0.042), m=m_w3,
                          loc=(0, 0.70 + 0.028 * i, 0.32 + 0.175 * i), bevel=0.005))

    # —— 矿洞口：朝 +Y 的深色内腔 + 券石（洞是"挖"出来的，不是贴一张黑图）——
    objs.append(K.box("洞腔", (1.30, 0.62, 1.42), m=m_dark, loc=(0, 0.92, 0.86),
                      bevel=0.02))
    objs.append(K.box("洞腔底", (1.34, 0.66, 0.10), m=m_cold, loc=(0, 0.94, 0.20),
                      bevel=0.01))
    for i in range(5):
        a = math.pi * i / 4
        objs.append(K.box("券石%d" % i, (0.34, 0.46, 0.26), m=m_s3,
                          loc=(0.86 * math.cos(a), 1.06, 1.52 + 0.72 * math.sin(a)),
                          rot=(0, -a + math.pi / 2, 0), bevel=0.020, top=0.9))

    # —— 木支撑：两柱 + 横梁 + 两根斜撑（矿洞口的真实结构）——
    for sx in (-1, 1):
        objs.append(K.box("支撑柱%d" % sx, (0.20, 0.22, 1.62), m=m_w,
                          loc=(sx * 0.80, 1.10, 1.05), bevel=0.024, top=0.9))
        objs.append(K.box("斜撑%d" % sx, (0.13, 0.15, 0.78), m=m_w2,
                          loc=(sx * 0.94, 0.86, 1.34),
                          rot=(0, math.radians(-24 * sx), 0), bevel=0.012))
    objs.append(K.box("横梁", (2.02, 0.26, 0.24), m=m_w, loc=(0, 1.10, 1.92),
                      bevel=0.020, top=0.94))
    objs.append(K.box("梁压条", (2.10, 0.16, 0.07), m=m_w3, loc=(0, 1.10, 2.06),
                      bevel=0.010))
    objs.append(K.box("梁托", (0.52, 0.18, 0.12), m=m_w2, loc=(0, 1.06, 1.76),
                      bevel=0.010))

    # —— 金脉：嵌在岩缝里的金色晶簇（金 + 金亮高光块，规范 §5.1 "每个金属件要有亮块"）——
    veins = [(0.62, -0.30, 1.42, 0.20), (-0.78, -0.22, 1.62, 0.17),
             (0.16, -0.62, 2.16, 0.22), (-0.34, -0.44, 2.62, 0.15),
             (0.94, -0.66, 1.92, 0.14), (-1.16, -0.52, 0.96, 0.13),
             (0.30, 0.42, 1.34, 0.16), (-0.26, 0.52, 1.72, 0.12)]
    for i, (x, y, z, r) in enumerate(veins):
        m = m_g2 if i % 3 == 0 else m_g
        objs.append(K.ico("金脉%d" % i, r, 0, m=m, loc=(x, y, z),
                          rot=(0.4 * i, 0.3 * i, 0.7 * i), scale=(1.0, 0.8, 1.25)))

    # —— 矿车：车斗 + 四轮 + 轴（在洞口右侧，读作"正在出货"）——
    cx, cy, cz = 1.42, 0.86, 0.42
    objs.append(K.box("车斗", (0.62, 0.44, 0.36), m=m_iron, loc=(cx, cy, cz + 0.18),
                      bevel=0.020, top=1.10))
    objs.append(K.box("车斗箍", (0.66, 0.48, 0.06), m=m_g, loc=(cx, cy, cz + 0.34),
                      bevel=0.008))
    objs.append(K.box("车斗矿", (0.50, 0.34, 0.10), m=m_g2, loc=(cx, cy, cz + 0.38),
                      bevel=0.010, top=0.8))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(K.cyl("车轮%d%d" % (sx, sy), 0.115, 0.115, 0.06, sides=8,
                              m=m_iron, loc=(cx + sx * 0.22, cy + sy * 0.19, cz - 0.02),
                              rot=(math.pi / 2, 0, 0)))

    # —— 轨道：两段短轨（把矿车"接"到洞口，避免它浮在地上）——
    for sx in (-1, 1):
        objs.append(K.box("轨道%d" % sx, (0.86, 0.05, 0.05), m=m_iron,
                          loc=(cx - 0.30, cy + sx * 0.19, 0.30), bevel=0.006))

    # —— 地上的矿石堆（洞口前的产出物）——
    for i, (x, y, z, r) in enumerate(((0.72, 1.34, 0.34, 0.16),
                                      (0.44, 1.46, 0.30, 0.12),
                                      (-0.56, 1.40, 0.32, 0.13))):
        objs.append(K.ico("矿石%d" % i, r, 1, m=(m_g2 if i == 0 else m_g),
                          loc=(x, y, z), rot=(0.3 * i, 0.5 * i, 0.2 * i),
                          scale=(1.0, 1.0, 0.85)))

    adopt(body, objs)
    K.fit_box(4.0, 3.5, 3.2)
    K.drop_to_ground()
    return K.export_glb(os.path.join(OUT, "金矿.glb"))


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    want = set(a for a in sys.argv if a in ("树", "岩石", "金矿"))
    reps = []
    for name, fn in (("树", build_tree), ("岩石", build_rock), ("金矿", build_goldmine)):
        if want and name not in want:
            continue
        reps.append(fn())
    K.headless_report({"models": reps})
