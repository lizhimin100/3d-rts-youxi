# -*- coding: utf-8 -*-
import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _v7_common as C
import kit3 as K3
from kit3 import Builder

def build_smoke():
    coll = K3.reset_scene()
    b = Builder("smoke")
    b.box((0.6, 0.6, 0.6), (0, 0, 0.3), material=C.mat("wood"), bevel=0.02)
    C.clump(b, (0, 0, 0.9), 0.35, C.mat("leaf"), seed=3)
    return b.build_meshes(coll)

if __name__ == "__main__":
    C.run({"smoke": build_smoke}, {"smoke": "_smoke.glb"},
          qc_views={"正": (0.0, 1.0, 0.12)}, res_of={"smoke": (480, 560)}, samples=24)
