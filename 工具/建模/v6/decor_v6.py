# -*- coding: utf-8 -*-
"""
decor_v6.py —— 点缀装饰物 v6（纯新增资产）

营火 / 木桩 / 旗帜 / 路标 / 尸骨 / 草丛。全部走 v6 质感管线
（平铺贴图 + 顶点 AO），作为地图叙事点缀，强化"这是战场 / 营地"的氛围。
这些是新资产，引擎侧可自由放置在地图装饰层。
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
from kit3 import mat, Builder, D, TAU, w_rigid
from props import faceted
from mathutils import Vector

W = w_rigid("root")

# 营火专用小 zone：石圈要柔和岩面（ashlar 砖缝在小石头上是噪点），原木要树皮
textured.ZONES["fire_stone"] = ("rock", 2.4)
K3.PALETTE["fire_stone"] = ("#98908A", 0.90, 0.0)
textured.ZONES["log"] = ("bark", 0.55)
K3.PALETTE["log"] = ("#6E4E2E", 0.86, 0.0)


def _wrap(fn):
    def w():
        return (None, fn())
    return w


def build_campfire():
    """营火：半埋石圈 + 低矮交叉原木 + 自发光炭火/火苗（整体高约 0.45m）。"""
    coll = K3.reset_scene()
    b = Builder("campfire")
    m_stone = mat("fire_stone")
    m_log = mat("log")
    m_log_d = mat("wood_dark")
    m_ember = mat("ember")
    # 石圈：8 块小石头，半埋（压扁），围着火心
    for i in range(8):
        a = TAU * i / 8.0 + 0.2
        faceted(b, (math.cos(a) * 0.40, math.sin(a) * 0.40, 0.055), 0.095, m_stone,
                seed=10 + i, subdiv=1, rough=0.32, scale=(1.0, 1.0, 0.60))
    # 原木：3 根，底端架在石圈内侧、顶端向火心交叠（低矮帐篷式）
    # 旋转学：kit3 rot=XYZ 欧拉，+Z 轴经 Rx(tilt)、Rz(yaw) 后水平指向 (sinφ,-cosφ)，
    # 要"顶端倒向圆心"需 yaw = a + 270°
    for i, a_deg in enumerate((20.0, 140.0, 260.0)):
        a = math.radians(a_deg)
        b.cyl(0.040, 0.050, 0.62,
              loc=(math.cos(a) * 0.30, math.sin(a) * 0.30, 0.02),
              rot=(D(64), 0, D(a_deg + 270.0)),
              material=m_log if i % 2 == 0 else m_log_d, sides=6)
    # 炭火芯（贴地）+ 火苗（收细），都吃自发光
    faceted(b, (0, 0, 0.09), 0.16, m_ember, seed=97, subdiv=1, rough=0.45,
            scale=(1.0, 1.0, 0.55))
    faceted(b, (0, 0, 0.28), 0.09, m_ember, seed=98, subdiv=1, rough=0.35,
            scale=(0.8, 0.8, 1.5))
    return b.build_meshes(coll)


def build_stump():
    """木桩：带年轮顶面 + 斧痕。"""
    coll = K3.reset_scene()
    b = Builder("stump")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    b.cyl(0.38, 0.42, 0.5, loc=(0, 0, 0.0), material=m_wood, sides=10)
    b.cyl(0.30, 0.30, 0.02, loc=(0, 0, 0.49), material=m_wood_d, sides=10)
    for i in range(3):
        a = TAU * i / 3.0 + 0.5
        b.box((0.06, 0.18, 0.30), (math.cos(a) * 0.40, math.sin(a) * 0.40, 0.28),
              material=m_wood_d, rot=(0, 0, a), bevel=0.01)
    return b.build_meshes(coll)


def build_flag(team=True):
    """旗帜：木杆 + 飘旗（队伍色）。"""
    coll = K3.reset_scene()
    b = Builder("flag")
    m_wood = mat("wood")
    m_cloth = mat("cloth", team=team)
    m_gold = mat("gold")
    b.cyl(0.05, 0.06, 2.0, loc=(0, 0, 0.0), material=m_wood, sides=8)
    b.box((0.9, 0.02, 0.6), (0.45, 0, 1.7), material=m_cloth, rot=(0, 0, 0), bevel=0.01)
    b.box((0.10, 0.04, 0.10), (0.02, 0, 1.7), material=m_gold, bevel=0.005)
    return b.build_meshes(coll)


def build_sign():
    """路标：木柱 + 木牌。"""
    coll = K3.reset_scene()
    b = Builder("sign")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    b.box((0.10, 0.10, 1.4), (0, 0, 0.7), material=m_wood, bevel=0.01)
    b.box((0.7, 0.06, 0.4), (0, 0, 1.1), material=m_wood_d, bevel=0.01)
    return b.build_meshes(coll)


def build_bones():
    """尸骨：颅骨 + 散落肢骨。"""
    coll = K3.reset_scene()
    b = Builder("bones")
    m_bone = mat("bone")
    faceted(b, (0, 0, 0.3), 0.22, m_bone, seed=1, scale=(0.9, 1.0, 1.0), subdiv=1, rough=0.15)
    for i in range(4):
        a = TAU * i / 4.0
        b.cyl(0.04, 0.04, 0.7, loc=(math.cos(a) * 0.3, math.sin(a) * 0.3, 0.12),
              rot=(D(80), 0, a), material=m_bone, sides=6)
    return b.build_meshes(coll)


def build_bush():
    """草丛：几团压扁叶状分面（WAR3 灌木）。"""
    coll = K3.reset_scene()
    b = Builder("bush")
    m_leaf = mat("leaf")
    m_leaf_d = mat("leaf_dark")
    for i in range(5):
        a = TAU * i / 5.0
        faceted(b, (math.cos(a) * 0.3, math.sin(a) * 0.3, 0.35), 0.28, m_leaf_d,
                seed=20 + i, scale=(1.0, 1.0, 0.9), subdiv=1, rough=0.25)
    faceted(b, (0, 0, 0.5), 0.30, m_leaf, seed=30, scale=(1.0, 1.0, 0.95), subdiv=1, rough=0.25)
    return b.build_meshes(coll)


BUILDERS = {
    "campfire": _wrap(build_campfire),
    "stump": _wrap(build_stump),
    "flag": _wrap(build_flag),
    "sign": _wrap(build_sign),
    "bones": _wrap(build_bones),
    "bush": _wrap(build_bush),
}
FILE_OF = {
    "campfire": "营火.glb",
    "stump": "木桩.glb",
    "flag": "旗帜.glb",
    "sign": "路标.glb",
    "bones": "尸骨.glb",
    "bush": "草丛.glb",
}

if __name__ == "__main__":
    C.run(BUILDERS, FILE_OF, qc_views={"三四": (0.85, 1.0, 0.4)})
