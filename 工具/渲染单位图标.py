# -*- coding: utf-8 -*-
"""把单位 GLB 渲成魔兽味的**单位头像图标**（256×256）→ 美术/图标/单位/<id>.png

和 `渲染建筑图标.py` 同一套思路，区别只在构图：
  · 建筑是"楼站在旷野上"，全身入画 + 有天地；
  · 单位是**头像位**（队伍清单/训练队列里只有 40~60px），所以
    **半身偏全身**、机位抬到腰平、背景压暗（暗底亮人，小尺寸才认得出）。

用法：
  blender.exe -b -P 工具/渲染单位图标.py            # 全部
  blender.exe -b -P 工具/渲染单位图标.py -- footman  # 只渲指定几个
"""
import math
import os
import sys

import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(ROOT, "美术", "模型")
RAW_DIR = os.path.join(ROOT, "_qa", "图标原图_单位")
OUT_DIR = os.path.join(ROOT, "美术", "图标", "单位")

UNITS = [
    ("peasant", "农民.glb"),
    ("footman", "方块人/方块人_联盟步兵.glb"),
    ("archer", "弓箭手.glb"),
    ("mage", "法师.glb"),
    ("steam_guard", "步兵.glb"),
]

SS = 512
OUT = 256
AZ_DEG = 34.0
EL_DEG = 10.0
FOCAL = 62.0
MARGIN = 1.06


def _reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _import(rel):
    path = os.path.join(MODEL_DIR, rel.replace("/", os.sep))
    if not os.path.exists(path):
        return None
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    if not objs:
        return None
    # ★ 包围盒按**真实顶点**算：glTF 导入的 bound_box 会带上 -1..1 的空壳
    #   （z 直接从 -1 起，h 算成 2.7），按它卡机位人只有画面 60% 大。
    mn = Vector((1e9, 1e9, 1e9))
    mx = Vector((-1e9, -1e9, -1e9))
    for ob in objs:
        mw = ob.matrix_world
        for v in ob.data.vertices:
            w = mw @ v.co
            mn.x, mn.y, mn.z = min(mn.x, w.x), min(mn.y, w.y), min(mn.z, w.z)
            mx.x, mx.y, mx.z = max(mx.x, w.x), max(mx.y, w.y), max(mx.z, w.z)
    return objs, mn, mx


def _sun(name, energy, color, rot, angle_deg=6.0):
    li = bpy.data.lights.new(name, 'SUN')
    li.energy = energy
    li.color = color
    li.angle = math.radians(angle_deg)
    ob = bpy.data.objects.new(name, li)
    bpy.context.collection.objects.link(ob)
    ob.rotation_euler = rot


def _lights():
    _sun("主光", 3.4, (1.00, 0.88, 0.72), (math.radians(56), 0.0, math.radians(38)), 5.0)
    _sun("补光", 0.7, (0.60, 0.74, 1.00), (math.radians(68), 0.0, math.radians(-115)), 22.0)
    _sun("轮廓光", 2.4, (1.00, 0.95, 0.86), (math.radians(26), 0.0, math.radians(198)), 9.0)


def _camera(mn, mx):
    """机位只负责"把人完整拍进来"，不负责构图。

    为什么不再算距离：这个工程的 glTF 导入包围盒里带着 -1..1 的空壳，
    任何"按包围盒卡边"的算法都会被它带偏（实测人物只占画面 40%~60%）。
    现在固定按身高 ×3.2 米取距离（一定装得下），
    真正的构图交给 工具/合成单位图标.py：按 alpha 通道自动裁剪 + 重新排版。
    """
    cam_d = bpy.data.cameras.new("机位")
    cam_d.lens = FOCAL
    cam = bpy.data.objects.new("机位", cam_d)
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    h = max(mx.z - mn.z, 0.5)
    center = Vector((0.0, 0.0, mn.z + h * 0.5))
    az = math.radians(AZ_DEG)
    el = math.radians(EL_DEG)
    d = Vector((math.cos(el) * math.sin(az), math.cos(el) * math.cos(az), math.sin(el)))
    cam.location = center + d * (h * 3.2)
    cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
    return cam


def _render():
    sc = bpy.context.scene
    sc.render.resolution_x = SS
    sc.render.resolution_y = SS
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = True     # 背景交给 工具/合成单位图标.py
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
        try:
            sc.render.engine = engine
            break
        except Exception:
            continue
    try:
        sc.eevee.taa_render_samples = 64
    except Exception:
        pass
    w = bpy.data.worlds.new("环境")
    sc.world = w
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.20, 0.23, 0.30, 1.0)
    w.node_tree.nodes["Background"].inputs[1].default_value = 0.55
    try:
        sc.view_settings.view_transform = 'Standard'
        sc.view_settings.look = 'None'
        sc.view_settings.exposure = -0.25
    except Exception:
        pass


def main():
    argv = sys.argv
    want = []
    if "--" in argv:
        want = argv[argv.index("--") + 1:]
    os.makedirs(RAW_DIR, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    for key, rel in UNITS:
        if want and key not in want:
            continue
        _reset()
        got = _import(rel)
        if got is None:
            print("!! 缺模型：", rel)
            continue
        objs, mn, mx = got
        _lights()
        _camera(mn, mx)
        _render()
        out = os.path.join(RAW_DIR, key + ".png")
        bpy.context.scene.render.filepath = out
        bpy.ops.render.render(write_still=True)
        print("渲染", key, "→", out)


main()
