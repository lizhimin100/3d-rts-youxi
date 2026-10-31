"""把建筑 GLB 渲染成 256×256 透明底图标（RTS 建筑栏 / 信息面板头像共用）。

用法：
  blender.exe -b -P 工具/渲染建筑图标.py

为什么离线渲：游戏里的建筑头像是实时 3D（头像台），一进建筑面板就开一个
SubViewport 渲全模型，既耗性能又看不清"这是哪座楼"。图标是一次性资产：
固定的 3/4 机位 + 正交相机，9 座建筑尺寸统一，放在建造栏里一眼能认。
"""
import math
import os
import sys

import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(ROOT, "美术", "模型")
OUT_DIR = os.path.join(ROOT, "美术", "图标", "建筑")

# 9 座建筑（和 UnitDef 的建筑 id 一一对应）
BUILDINGS = [
    ("townhall", "大本营"),
    ("barracks", "兵营"),
    ("blacksmith", "铁匠铺"),
    ("farm", "农场"),
    ("tower", "箭塔"),
    ("watchtower", "哨塔"),
    ("sanctum", "神秘圣地"),
    ("workshop", "蒸汽车坊"),
    ("lumbercamp", "伐木场"),
]

SIZE = 256
# 3/4 机位：方位 38°、仰角 26° —— 能同时看到正门和一个侧墙，最像"图鉴图标"
AZ_DEG = 38.0
EL_DEG = 26.0


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def collect_bounds(objs):
    mn = Vector((1e9, 1e9, 1e9))
    mx = Vector((-1e9, -1e9, -1e9))
    for ob in objs:
        if ob.type != 'MESH':
            continue
        for c in ob.bound_box:
            w = ob.matrix_world @ Vector(c)
            mn.x, mn.y, mn.z = min(mn.x, w.x), min(mn.y, w.y), min(mn.z, w.z)
            mx.x, mx.y, mx.z = max(mx.x, w.x), max(mx.y, w.y), max(mx.z, w.z)
    if mn.x > mx.x:
        return None, None
    return mn, mx


def setup_world():
    world = bpy.data.worlds.new("图标世界")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    # 冷灰环境光：比纯白更能保住金属高光，又不会把暗部提成灰泥
    bg.inputs[0].default_value = (0.42, 0.46, 0.54, 1.0)
    bg.inputs[1].default_value = 1.15


def add_lights(center, radius):
    sun = bpy.data.lights.new("主光", 'SUN')
    sun.energy = 3.6
    sun.angle = math.radians(9.0)
    so = bpy.data.objects.new("主光", sun)
    bpy.context.collection.objects.link(so)
    so.rotation_euler = (math.radians(52.0), 0.0, math.radians(38.0))

    fill = bpy.data.lights.new("补光", 'SUN')
    fill.energy = 1.3
    fill.angle = math.radians(30.0)
    fo = bpy.data.objects.new("补光", fill)
    bpy.context.collection.objects.link(fo)
    fo.rotation_euler = (math.radians(64.0), 0.0, math.radians(-134.0))


def render_one(key, cn_name):
    src = os.path.join(MODEL_DIR, cn_name + ".glb")
    if not os.path.exists(src):
        print("!! 缺模型：%s" % src)
        return False
    clear_scene()
    bpy.ops.import_scene.gltf(filepath=src)
    objs = list(bpy.context.scene.objects)
    mn, mx = collect_bounds(objs)
    if mn is None:
        print("!! 没有网格：%s" % cn_name)
        return False
    center = (mn + mx) * 0.5
    size = mx - mn
    extent = max(size.x, size.y, size.z)

    setup_world()
    add_lights(center, extent)

    cam_data = bpy.data.cameras.new("图标机位")
    cam_data.type = 'ORTHO'
    # 正交尺度按"最大水平投影"给：3/4 机位下对角线最宽，留 18% 边距
    cam_data.ortho_scale = extent * 1.18
    cam = bpy.data.objects.new("图标机位", cam_data)
    bpy.context.collection.objects.link(cam)
    az = math.radians(AZ_DEG)
    el = math.radians(EL_DEG)
    d = Vector((math.cos(el) * math.sin(az), -math.cos(el) * math.cos(az), math.sin(el)))
    cam.location = center + d * (extent * 3.0 + 5.0)
    cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam

    scene = bpy.context.scene
    scene.render.resolution_x = SIZE
    scene.render.resolution_y = SIZE
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    # Standard（不是 Filmic/AgX）：图标要的是"所见即资产本色"，不要电影感曲线
    try:
        scene.view_settings.view_transform = 'Standard'
    except Exception:
        pass
    for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE', 'CYCLES'):
        try:
            scene.render.engine = engine
            break
        except Exception:
            continue
    if scene.render.engine == 'CYCLES':
        scene.cycles.samples = 64
    else:
        try:
            scene.eevee.taa_render_samples = 32
        except Exception:
            pass

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, key + ".png")
    scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("OK %-12s -> %s (extent %.1fm)" % (key, out, extent))
    return True


def main():
    ok = 0
    for key, cn in BUILDINGS:
        try:
            if render_one(key, cn):
                ok += 1
        except Exception as exc:  # 单座失败不影响其余
            print("!! %s 渲染失败：%s" % (key, exc))
    print("完成 %d/%d" % (ok, len(BUILDINGS)))


main()
