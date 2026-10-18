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
    coll = K3.reset_scene()
    b = Builder("tree")
    m_bark = mat("bark")
    m_leaf = mat("leaf")
    m_leaf_d = mat("leaf_dark")

    # 树干：上细下粗，带一点弯
    rings = []
    for i in range(6):
        t = i / 5.0
        z = 0.05 + t * H * 0.52
        r = 0.30 * (1.0 - 0.55 * t) + 0.02
        cx = 0.10 * math.sin(t * 2.2)
        rings.append([(cx + r * math.cos(TAU * k / 9), r * 0.86 * math.sin(TAU * k / 9), z)
                      for k in range(9)])
    b.add(K3._bm_loft(rings, cap_a=True, cap_b=True), m_bark, W)
    # 根部外扩
    b.cyl(0.42, 0.30, 0.30, loc=(0, 0, 0.02), material=m_bark, sides=9, weight=W)

    # 树冠：一大两中三小（错落，避免"一根棒棒糖"）
    faceted(b, (0.0, 0.0, H * 0.62), 1.55, m_leaf, seed=11, scale=(1.15, 1.05, 0.95), subdiv=1)
    faceted(b, (0.95, 0.25, H * 0.55), 1.05, m_leaf_d, seed=12, scale=(1.0, 1.0, 0.9), subdiv=1)
    faceted(b, (-0.85, -0.15, H * 0.58), 1.12, m_leaf_d, seed=13, scale=(1.0, 1.0, 0.9), subdiv=1)
    faceted(b, (0.10, -0.75, H * 0.50), 0.92, m_leaf, seed=14, subdiv=1)
    faceted(b, (-0.15, 0.70, H * 0.72), 0.85, m_leaf, seed=15, subdiv=1)
    faceted(b, (0.0, 0.0, H * 0.80), 0.78, m_leaf_d, seed=16, subdiv=1)
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
    coll = K3.reset_scene()
    b = Builder("goldmine")
    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_ore = mat("ore")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")

    # 矿体：两团大石
    faceted(b, (0.0, 0.0, 1.15), 1.85, m_stone, seed=41, scale=(1.15, 0.95, 1.0), subdiv=2, rough=0.16)
    faceted(b, (1.35, 0.55, 0.75), 1.05, m_stone_d, seed=42, scale=(1.0, 0.9, 0.9), subdiv=1, rough=0.2)
    faceted(b, (-1.25, -0.60, 0.70), 0.95, m_stone_d, seed=43, subdiv=1, rough=0.2)
    # 金矿脉：露头的金块
    rnd = random.Random(7)
    for i in range(9):
        a = rnd.uniform(0, TAU)
        rr = rnd.uniform(0.9, 1.55)
        z = rnd.uniform(0.55, 1.85)
        faceted(b, (math.cos(a) * rr, math.sin(a) * rr * 0.8, z), rnd.uniform(0.16, 0.27),
                m_ore, seed=50 + i, subdiv=1, rough=0.25)
    # 矿洞口（木框 + 黑暗）
    b.box((1.35, 0.50, 1.25), (0.0, 1.45, 0.62), material=m_wood_d, bevel=0.03)
    b.box((1.05, 0.30, 1.00), (0.0, 1.62, 0.58), material=mat("glass"), bevel=0.02)
    for sx in (-1, 1):
        b.box((0.18, 0.55, 1.45), (sx * 0.66, 1.50, 0.72), material=m_wood, bevel=0.02)
    b.box((1.55, 0.32, 0.20), (0.0, 1.48, 1.42), material=m_wood, bevel=0.02)
    # 矿车
    b.box((0.75, 0.52, 0.34), (-1.05, 1.45, 0.17), material=m_wood, bevel=0.03)
    for sx in (-1, 1):
        b.cyl(0.16, 0.16, 0.06, loc=(-1.05 + sx * 0.30, 1.20, 0.16), rot=(D(90), 0, 0),
              material=mat("iron"), sides=8)
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
