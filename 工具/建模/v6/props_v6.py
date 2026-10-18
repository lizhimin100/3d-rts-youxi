# -*- coding: utf-8 -*-
"""
props_v6.py —— 地图装饰物 v6（贴图化 + 顶点 AO）

树 / 金矿：复用 v3/props 的 WAR3 风格几何（三层树冠 / 内凹矿洞 + 矿车），
           只在外层套 v6 质感管线。
岩石：fork 增强版 —— 自然岩面（rock 族贴图，不再误用砌石 ashlar）+ 迎光青苔 + 裂缝。
"""
import sys
import os
import math
import random

HERE = os.path.dirname(os.path.abspath(__file__))
V3 = os.path.abspath(os.path.join(HERE, "..", "v3"))
sys.path.insert(0, HERE)
sys.path.insert(0, V3)

import _v6_common as C
import kit3 as K3
import textured
import props as P
from kit3 import mat, Builder, D, TAU, w_rigid
from mathutils import Vector

# 注入 rock 族映射（不碰底层文件；美术/贴图/rock_* 已存在）
# uv_scale 1.9：纹理铺大一点，岩缝读作"岩层起伏"而不是满身黑裂纹
textured.ZONES["rock"] = ("rock", 1.9)
textured.ZONES["rock_dark"] = ("rock", 1.9)
K3.PALETTE["rock"] = ("#8A857C", 0.88, 0.0)
K3.PALETTE["rock_dark"] = ("#635E55", 0.90, 0.0)

W = w_rigid("root")


def _wrap(fn):
    def w():
        return (None, fn())
    return w


def _remap(objs, mapping):
    """把网格材质槽从旧 zone 换到新 zone（只换槽位引用，不改共享材质本身）。"""
    for ob in objs:
        if ob.type != "MESH":
            continue
        for slot in ob.material_slots:
            m = slot.material
            if m is None:
                continue
            zone = mapping.get(m.name)
            if zone:
                slot.material = mat(zone)


def _goldmine_v6():
    """金矿：v3 几何 + 矿体石料换自然岩面（ashlar 砖缝读作'砖堆'，实测不行）。"""
    objs = P.build_goldmine()
    _remap(objs, {"M_stone": "rock", "M_stone_dark": "rock_dark",
                  "M_stone_light": "rock"})
    return (None, objs)


def build_rock_v6(size=1.7):
    """自然岩面岩石（v3 几何 + rock 贴图 + 青苔 + 裂缝）。"""
    coll = K3.reset_scene()
    b = Builder("rock")
    m = mat("rock")
    m_d = mat("rock_dark")
    m_moss = mat("leaf_dark")
    P.faceted(b, (0.0, 0.0, size * 0.36), size * 0.5, m, seed=21,
              scale=(1.0, 0.82, 0.72), subdiv=1, rough=0.22)
    P.faceted(b, (size * 0.42, size * 0.22, size * 0.20), size * 0.28, m_d, seed=22,
              scale=(1.0, 0.9, 0.75), subdiv=1, rough=0.24)
    P.faceted(b, (-size * 0.36, -size * 0.26, size * 0.16), size * 0.24, m_d, seed=23,
              subdiv=1, rough=0.26)
    for i in range(3):
        a = TAU * i / 3.0 + 0.7
        P.faceted(b, (math.cos(a) * size * 0.62, math.sin(a) * size * 0.55, 0.10),
                  size * 0.12, m_d, seed=30 + i, subdiv=1, rough=0.3)
    # 青苔：嵌进岩体下侧（中心在岩面内、只鼓出小半），读作"石上生苔"而不是绿石头
    for i in range(4):
        a = TAU * i / 4.0 + 0.3
        P.faceted(b, (math.cos(a) * size * 0.32, math.sin(a) * size * 0.28, size * 0.13),
                  size * 0.15, m_moss, seed=80 + i, subdiv=1, rough=0.3,
                  scale=(1.0, 1.0, 0.62))
    return b.build_meshes(coll)


BUILDERS = {
    "tree": _wrap(P.build_tree),
    "rock": _wrap(build_rock_v6),
    "goldmine": _goldmine_v6,
}
FILE_OF = {"tree": "树.glb", "rock": "岩石.glb", "goldmine": "金矿.glb"}

if __name__ == "__main__":
    C.run(BUILDERS, FILE_OF, qc_views={"三四": (0.85, 1.0, 0.35)})
