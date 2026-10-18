# -*- coding: utf-8 -*-
"""debug_bbox.py —— 形体诊断：重建单个建筑并列出"最长边超阈值"的对象。
用途：预览图里出现莫名的长条/悬空件时，靠它一眼定位是哪个几何体。"""
import os
import sys
import importlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import rts_kit as K

MOD = importlib.import_module("build_建筑")


def dump(fn, thresh=1.2):
    K.reset_scene()
    fn()
    rows = []
    for o in bpy.data.objects:
        if o.type != "MESH":
            continue
        lo, hi = K.bbox([o])
        sz = (hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        if max(sz) > thresh:
            rows.append((round(max(sz), 2), o.name,
                         [round(v, 2) for v in sz],
                         [round(v, 2) for v in ((lo + hi) * 0.5)]))
    rows.sort(reverse=True)
    print("=== %s : 长边 > %.1f 的对象 ===" % (fn.__name__, thresh))
    for r in rows:
        print("max=%-6s  %-18s size=%s center=%s" % (r[0], r[1], r[2], r[3]))
    print("total objects=%d" % len(bpy.data.objects))


if __name__ == "__main__":
    dump(MOD.build_farm)
