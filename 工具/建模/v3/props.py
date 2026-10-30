# -*- coding: utf-8 -*-
"""
props.py —— 地图装饰物 v3（树 / 岩石 / 金矿）

为什么要重做：旧 GLB 一棵树 33 个 Mesh（33 次 draw call），54 棵树就是 1782 次 ——
这是 draw call 13000+ 的主要来源之一。v3 按材质合并，一棵树只剩 2~3 个 Mesh，
同时把形体做得更"手绘"：树干分叉 + 多团树冠 + 分面石块。
"""

import bpy, math, os, sys, random
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3
from kit3 import mat, Builder, D, TAU, w_rigid, ring_pts

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型"
QC_DIR = r"E:\自定义游戏\简易rts\工具\建模\v3\qc"
W = w_rigid("root")


class RootRig(object):
    """装饰物只需要一根 root 骨（保持和单位/建筑同一套"带骨架"资产口径，
    引擎侧 ArtKit.attach_anim 看到 AnimationPlayer 才走骨骼；这里没有动画，
    所以直接不用骨架 —— 但保留 root 权重让权重函数统一。"""

    def __init__(self):
        self.arm = None


def faceted(b, center, radius, material, seed=1, scale=(1, 1, 1), subdiv=1, rough=0.18,
            weight=None):
    """分面球：二十面体 + 顶点随机位移（石头/树冠的手绘感来源）。"""
    rnd = random.Random(seed)
    bm = K3._bm_ico(radius, subdiv)
    for v in bm.verts:
        k = 1.0 + rnd.uniform(-rough, rough)
        v.co = Vector((v.co.x * k * scale[0], v.co.y * k * scale[1], v.co.z * k * scale[2]))
    # 平直着色（低多边形块面）
    for f in bm.faces:
        f.smooth = False
    b.add(bm, material, weight or W, Matrix.Translation(Vector(center)))


def build_tree(H=5.6):
    """阔叶树 v2：**三层树冠 + 露出的枝杈**。

    旧版是一根杆 + 6 个等大小球，远看就是棒棒糖。
    魔兽3 的树靠三件事读出来：① 下宽上窄的锥形轮廓；② 层与层之间的缝（能看到枝杈）；
    ③ 树冠不是球而是"一簇簇压扁的多面体"。
    """
    coll = K3.reset_scene()
    b = Builder("tree")
    m_bark = mat("bark")
    m_leaf = mat("leaf")
    m_leaf_d = mat("leaf_dark")

    # 树干：上细下粗、带弯
    rings = []
    for i in range(7):
        t = i / 6.0
        z = 0.05 + t * H * 0.60
        r = 0.32 * (1.0 - 0.62 * t) + 0.02
        cx = 0.12 * math.sin(t * 2.1)
        rings.append([(cx + r * math.cos(TAU * k / 9), r * 0.86 * math.sin(TAU * k / 9), z)
                      for k in range(9)])
    b.add(K3._bm_loft(rings, cap_a=True, cap_b=True), m_bark, W)
    b.cyl(0.46, 0.32, 0.34, loc=(0, 0, 0.02), material=m_bark, sides=9, weight=W)

    # 主枝杈：三根斜向上的枝，末端顶进树冠里（缝里能看见）
    for i, (ang, tilt, ln) in enumerate(((0.4, 0.55, 1.35), (2.5, 0.62, 1.15), (4.4, 0.50, 1.25))):
        x0, y0, z0 = 0.0, 0.0, H * 0.44 + i * 0.06
        tip = (math.cos(ang) * ln, math.sin(ang) * ln, z0 + ln * tilt)
        b.tube([(x0, y0, z0), (tip[0] * 0.55, tip[1] * 0.55, (z0 + tip[2]) * 0.5), tip],
               0.085, m_bark, weight=W, sides=6)

    # 树冠：三层，越往上越小；每层 4~5 团压扁多面体，团之间留缝
    layers = (
        (H * 0.55, 1.42, 6, 0.62, m_leaf_d),   # 底层：最宽、最暗
        (H * 0.68, 1.15, 5, 0.58, m_leaf),     # 中层
        (H * 0.80, 0.86, 4, 0.55, m_leaf),     # 顶层
    )
    seed = 10
    for li, (z, rad, count, squash, m) in enumerate(layers):
        for k in range(count):
            a = TAU * k / count + li * 0.55
            rr = rad * (0.52 if count > 1 else 0.0)
            faceted(b, (math.cos(a) * rr, math.sin(a) * rr, z + math.sin(a * 2.0) * 0.10),
                    rad * (0.62 if k % 2 else 0.72), m, seed=seed,
                    scale=(1.12, 1.08, squash), subdiv=2, rough=0.20)
            seed += 1
    # 顶芽
    faceted(b, (0.0, 0.0, H * 0.90), 0.44, m_leaf, seed=99, scale=(1.0, 1.0, 0.9),
            subdiv=1, rough=0.22)
    return b.build_meshes(coll)


def build_rock(size=1.7):
    coll = K3.reset_scene()
    b = Builder("rock")
    m = mat("stone")
    m_d = mat("stone_dark")
    faceted(b, (0.0, 0.0, size * 0.36), size * 0.5, m, seed=21,
            scale=(1.0, 0.82, 0.72), subdiv=1, rough=0.22)
    faceted(b, (size * 0.42, size * 0.22, size * 0.20), size * 0.28, m_d, seed=22,
            scale=(1.0, 0.9, 0.75), subdiv=1, rough=0.24)
    faceted(b, (-size * 0.36, -size * 0.26, size * 0.16), size * 0.24, m_d, seed=23,
            subdiv=1, rough=0.26)
    # 几块碎石（跟着岩石一起，省一个节点）
    for i in range(3):
        a = TAU * i / 3.0 + 0.7
        faceted(b, (math.cos(a) * size * 0.62, math.sin(a) * size * 0.55, 0.10),
                size * 0.12, m_d, seed=30 + i, subdiv=1, rough=0.3)
    return b.build_meshes(coll)


def build_goldmine():
    """金矿 v2：**内凹的矿洞** + 木框斜撑 + 密集露头矿脉。

    旧版洞口是一块贴在石头外的木板，侧面一看就穿帮；这版把洞做成
    向内凹的方盒（深处一块近黑的玻璃材质），矿工"走进去"才像回事。
    """
    coll = K3.reset_scene()
    b = Builder("goldmine")
    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_ore = mat("ore")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")

    # 矿体：主石 + 两侧肩石 + 顶部岩檐（把洞口压出来）
    faceted(b, (0.0, -0.15, 1.25), 1.95, m_stone, seed=41, scale=(1.20, 1.00, 1.05),
            subdiv=2, rough=0.15)
    faceted(b, (1.45, 0.45, 0.72), 1.02, m_stone_d, seed=42, scale=(1.0, 0.9, 0.9),
            subdiv=2, rough=0.20)
    faceted(b, (-1.35, -0.50, 0.70), 0.98, m_stone_d, seed=43, subdiv=2, rough=0.20)
    faceted(b, (0.0, 0.35, 2.55), 1.05, m_stone_l, seed=44, scale=(1.45, 0.85, 0.55),
            subdiv=2, rough=0.18)

    # 洞口：向内凹的暗腔（三层递减亮度，做出纵深）
    b.box((1.25, 1.05, 1.30), (0.0, 1.05, 0.66), material=mat("glass"), bevel=0.02)
    b.box((0.95, 0.30, 1.00), (0.0, 0.72, 0.62), material=m_wood_d, bevel=0.02)

    # 门框：立枋 + 横梁 + 斜撑
    for sx in (-1, 1):
        b.box((0.19, 0.62, 1.62), (sx * 0.70, 1.42, 0.80), material=m_wood, bevel=0.02)
        b.box((0.12, 0.14, 0.95), (sx * 0.98, 1.60, 1.34),
              rot=(0, 0, sx * D(34)), material=m_wood_d, bevel=0.01)
    b.box((1.72, 0.36, 0.22), (0.0, 1.42, 1.62), material=m_wood, bevel=0.02)
    b.box((1.90, 0.30, 0.10), (0.0, 1.38, 1.76), material=m_wood_d, bevel=0.01)
    # 门口吊灯
    b.cyl(0.10, 0.10, 0.16, loc=(0.62, 1.30, 1.48), material=m_iron, sides=8)
    faceted(b, (0.62, 1.30, 1.42), 0.075, mat("ember"), seed=71, subdiv=1)

    # 矿脉：沿洞口两侧与顶部成簇（不是均匀撒点）
    rnd = random.Random(7)
    veins = ((0.72, 0.35, 1.75), (-0.70, 0.40, 1.70), (0.35, 0.55, 2.20),
             (-0.40, 0.30, 1.95), (1.05, 0.20, 1.15), (-1.02, 0.10, 1.20),
             (0.0, 0.62, 2.35), (0.90, 0.45, 0.72), (-0.88, 0.52, 0.80))
    for i, (x, y, z) in enumerate(veins):
        for k in range(3):
            faceted(b, (x + rnd.uniform(-0.16, 0.16), y + rnd.uniform(-0.08, 0.12),
                        z + rnd.uniform(-0.16, 0.16)),
                    rnd.uniform(0.10, 0.19), m_ore, seed=50 + i * 5 + k, subdiv=1, rough=0.25)

    # 矿车 + 一段窄轨
    b.box((0.80, 0.54, 0.36), (-1.15, 1.50, 0.20), material=m_wood, bevel=0.03)
    for sx in (-1, 1):
        b.cyl(0.17, 0.17, 0.06, loc=(-1.15 + sx * 0.32, 1.24, 0.17), rot=(D(90), 0, 0),
              material=m_iron, sides=8)
    for sx in (-1, 1):
        b.box((0.06, 1.90, 0.05), (-1.15 + sx * 0.22, 2.55, 0.03), material=m_iron, bevel=0.005)
    return b.build_meshes(coll)


BUILDERS = {"tree": build_tree, "rock": build_rock, "goldmine": build_goldmine}
FILE_OF = {"tree": "树.glb", "rock": "岩石.glb", "goldmine": "金矿.glb"}
HEIGHT = {"tree": 5.6, "rock": 2.1, "goldmine": 3.3}


def main():
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    which = args[0] if args else "tree"
    do_qc = "--qc" in args
    do_export = "--export" in args
    names = list(BUILDERS.keys()) if which == "all" else [which]
    reports = []
    for nm in names:
        objs = BUILDERS[nm]()
        mn, mx = K3.bbox(objs)
        rep = {"name": nm, "size": [round(v, 2) for v in (mx - mn)], "meshes": len(objs)}
        if do_qc:
            c = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            rad = max(mx.x - mn.x, mx.z - mn.z) * 0.5
            K3.render_views(nm, QC_DIR, c, max(rad, 1.0) * 1.3, res=(560, 700),
                            views={"三四": (0.85, 1.0, 0.35)})
        if do_export:
            rep.update(K3.export_glb(os.path.join(OUT_DIR, FILE_OF[nm])))
        reports.append(rep)
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
    print("HEADLESS " + json.dumps(reports, ensure_ascii=False))


if __name__ == "__main__":
    main()
