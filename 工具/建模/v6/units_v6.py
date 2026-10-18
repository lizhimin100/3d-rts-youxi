# -*- coding: utf-8 -*-
"""
units_v6.py —— 单位 v6（贴图化 + 顶点 AO）

复用 v3/units.py 的全部 WAR3 风格骨架 / 部件 / 动画（步兵 / 弓箭手 / 法师 / 农民），
只在外层套 v6 质感管线：
    textured.apply  -> 给 M_<zone> 材质绑平铺贴图（盒式投影 UV，跨物体密度一致）
    textured.bake_ao -> Cycles 把接触阴影烘进 COLOR_0
    export_glb(vertex_color="ACTIVE") -> 顶点色 AO 随 GLB 导出
几何一行不动，引擎侧 MatKit / ArtKit 零改动。升级点全在"材质呈现"。
"""
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
V3 = os.path.abspath(os.path.join(HERE, "..", "v3"))
sys.path.insert(0, HERE)
sys.path.insert(0, V3)
import _v6_common as C
import units as U

BUILDERS = {
    "footman": U.build_footman,
    "archer":  U.build_crossbow,
    "mage":    U.build_mage,
    "peasant": U.build_peasant,
}
FILE_OF = {
    "footman": "步兵.glb",
    "archer":  "弓箭手.glb",
    "mage":    "法师.glb",
    "peasant": "农民.glb",
}
# 键对齐 BUILDERS（archer 复用 crossbow 几何），避免 C.run 取 target_h[nm] 时 KeyError
TARGET_H = {"footman": 1.78, "archer": 1.72, "mage": 1.80, "peasant": 1.62}

if __name__ == "__main__":
    C.run(
        BUILDERS, FILE_OF, target_h=TARGET_H,
        qc_views={"正": (0.0, 1.0, 0.06), "三四": (0.85, 1.0, 0.22)},
    )
