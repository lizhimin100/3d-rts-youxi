"""把建筑 GLB 渲成**魔兽争霸 3 味道**的图标（256×256，方形，带场景背景）。

用法：
  blender.exe -b -P 工具/渲染建筑图标.py            # 全部 9 座
  blender.exe -b -P 工具/渲染建筑图标.py -- townhall farm   # 只渲指定几座

为什么要"渲"而不是直接截 3D：
  · 图标是**一次性资产**，可以给专门的机位、专门的光、专门的调色；
  · 游戏内的建筑模型是正交低模 + 卡通材质，直接截屏没有"图鉴感"。

魔兽 3 图标的四个特征（本脚本就是照这四条做的）：
  1. **3/4 俯视机位**：方位 ~40°、仰角 ~26°，正门 + 一个侧墙同时入画；
  2. **戏剧性三点光**：暖主光压在左前上，冷补光在右侧，背后一盏强轮廓光把楼从背景里剥出来；
  3. **有景的背景**：不是透明底，而是一块渐变的天空 + 一块接地的土地，楼"站在地上"；
  4. **手绘调色**：高光偏暖、暗部偏冷，饱和度略高、对比略硬，四角压暗（vignette）。

渲染走 EEVEE（快），调色/暗角/锐化走 PIL（可控、可复现）。
"""

import math
import os
import sys

import bpy
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(ROOT, "美术", "模型")
RAW_DIR = os.path.join(ROOT, "_qa", "图标原图")   # Blender 只出原图，合成交给 工具/合成建筑图标.py

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

SS = 512          # 渲染边长（最后缩到 256，等于 2× 超采样）
OUT = 256
AZ_DEG = 40.0     # 方位角：正门朝镜头偏一侧
EL_DEG = 24.0     # 仰角：能看见屋顶又不至于俯视
FOCAL = 55.0
MARGIN = 1.04     # 画面留白系数（1.0 = 刚好贴边）

KEY_COL = (1.00, 0.86, 0.68)
FILL_COL = (0.58, 0.72, 1.00)
RIM_COL = (1.00, 0.94, 0.82)


def _reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _bounds(objs):
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


def _world_gradient():
    """天顶冷、地平线暖的渐变背景 —— 魔兽图标那种"傍晚打光"的底子。"""
    w = bpy.data.worlds.new("图标天空")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    bg = nt.nodes.new("ShaderNodeBackground")
    bg.inputs[1].default_value = 0.30   # 只当背景色：强度压低，光全靠三盏 sun
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    tex = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    # ★ 必须走 MapRange：Generated 的 Z 是 -1~1，直接进 ColorRamp（只吃 0~1）会夹成一片平色
    rng = nt.nodes.new("ShaderNodeMapRange")
    rng.inputs["From Min"].default_value = -1.0
    rng.inputs["From Max"].default_value = 1.0
    rng.inputs["To Min"].default_value = 0.0
    rng.inputs["To Max"].default_value = 1.0
    nt.links.new(tex.outputs["Generated"], sep.inputs["Vector"])
    nt.links.new(sep.outputs["Z"], rng.inputs["Value"])
    nt.links.new(rng.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs[0])
    nt.links.new(bg.outputs[0], out.inputs[0])
    el = ramp.color_ramp.elements
    el[0].position = 0.40
    el[0].color = (0.13, 0.11, 0.10, 1.0)     # 地平线下：暗土
    el[1].position = 0.95
    el[1].color = (0.10, 0.17, 0.38, 1.0)     # 天顶：深蓝（压住画面上缘）
    mid = ramp.color_ramp.elements.new(0.48)
    mid.color = (0.86, 0.55, 0.26, 1.0)       # 地平线：暖金（戏剧天光）
    near = ramp.color_ramp.elements.new(0.58)
    near.color = (0.55, 0.42, 0.30, 1.0)


def _ground(mn, extent):
    # ★ 只放一块**比占地稍大的圆盘**，而不是一整片大地：
    #   大地会把整个画面下半填满土色，背景就"没有天"了 —— 魔兽图标是"楼站在地上，
    #   背后有天光"，所以地面只负责接地阴影，天空交给世界渐变。
    # 圆盘半径 2.6×extent：近处地面出画、远处留一条地平线给天空 —— 这是"楼站在旷野上"的比例
    bpy.ops.mesh.primitive_circle_add(vertices=96, radius=extent * 2.6,
                                      fill_type='NGON',
                                      location=(0.0, 0.0, mn.z - 0.02))
    pl = bpy.context.object
    pl.name = "地面"
    mat = bpy.data.materials.new("图标地面")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.95
    # 以建筑为中心做径向渐变：脚下一圈暖土、越往外越暗 ——
    # 直接把"背景变暗"画进材质里，比后期暗角更自然（它跟着透视走）。
    tc = nt.nodes.new("ShaderNodeTexCoord")
    ln = nt.nodes.new("ShaderNodeVectorMath")
    ln.operation = 'LENGTH'
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = extent * 0.35
    mr.inputs["From Max"].default_value = extent * 2.4
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    nt.links.new(tc.outputs["Object"], ln.inputs[0])
    nt.links.new(ln.outputs["Value"], mr.inputs["Value"])
    nt.links.new(mr.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.42, 0.31, 0.20, 1.0)
    ramp.color_ramp.elements[1].position = 0.55
    ramp.color_ramp.elements[1].color = (0.12, 0.10, 0.09, 1.0)
    # ★ 边缘**渐隐成透明**：否则 3D 圆盘的边缘会露出来，一眼就是"渲了个盘子上"
    merge = nt.nodes.new("ShaderNodeMath")
    merge.operation = 'ADD'
    merge.inputs[1].default_value = 0.0
    nt.links.new(mr.outputs["Result"], merge.inputs[0])
    alpha_ramp = nt.nodes.new("ShaderNodeValToRGB")
    nt.links.new(mr.outputs["Result"], alpha_ramp.inputs["Fac"])
    alpha_ramp.color_ramp.elements[0].position = 0.25
    alpha_ramp.color_ramp.elements[0].color = (1.0, 1.0, 1.0, 1.0)
    alpha_ramp.color_ramp.elements[1].position = 0.62
    alpha_ramp.color_ramp.elements[1].color = (0.0, 0.0, 0.0, 1.0)
    nt.links.new(alpha_ramp.outputs["Color"], bsdf.inputs["Alpha"])
    for attr, val in (("blend_method", 'BLEND'), ("surface_render_method", 'BLENDED'),
                      ("shadow_method", 'NONE')):
        try:
            setattr(mat, attr, val)
        except Exception:
            pass
    try:
        bsdf.inputs["Specular IOR Level"].default_value = 0.18
    except Exception:
        pass
    pl.data.materials.append(mat)
    return pl


def _sun(name, energy, color, rot_euler, angle_deg=6.0):
    li = bpy.data.lights.new(name, 'SUN')
    li.energy = energy
    li.color = color
    li.angle = math.radians(angle_deg)
    ob = bpy.data.objects.new(name, li)
    bpy.context.collection.objects.link(ob)
    ob.rotation_euler = rot_euler
    return ob


def _lights():
    # 主光：左前上方、暖；角度压低一点出长影
    _sun("主光", 7.0, KEY_COL, (math.radians(52.0), 0.0, math.radians(34.0)), 5.0)
    # 补光：右侧、冷、弱（把暗部从"死黑"抬到"冷灰蓝"）
    _sun("补光", 0.55, FILL_COL, (math.radians(66.0), 0.0, math.radians(-118.0)), 22.0)
    # 轮廓光：背后、强、暖白（魔兽图标的招牌 —— 楼顶和墙沿一条亮边）
    _sun("轮廓光", 6.5, RIM_COL, (math.radians(28.0), 0.0, math.radians(196.0)), 9.0)


def _camera(mn, mx, center, extent):
    """按**投影包围盒**卡机位：宽扁的农场和细高的大本营都要刚好填满画面。

    之前用"包围球半径"算距离，宽建筑会被左右切掉、高建筑又留一圈空白。
    这里把 8 个包围盒角点投到相机空间，反复缩放距离直到水平和垂直都装得下。
    """
    cam_d = bpy.data.cameras.new("图标机位")
    cam_d.lens = FOCAL
    cam = bpy.data.objects.new("图标机位", cam_d)
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    az = math.radians(AZ_DEG)
    el = math.radians(EL_DEG)
    d = Vector((math.cos(el) * math.sin(az), -math.cos(el) * math.cos(az), math.sin(el)))

    corners = [Vector((x, y, z))
               for x in (mn.x, mx.x) for y in (mn.y, mx.y) for z in (mn.z, mx.z)]
    tan_h = 18.0 / FOCAL                     # 36mm 传感器 → 半视角正切
    tan_v = tan_h

    dist = max(extent * 2.0, 1.0)
    for _ in range(6):
        cam.location = center + d * dist
        cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
        bpy.context.view_layer.update()
        inv = cam.matrix_world.inverted()
        need = 0.0
        for c in corners:
            p = inv @ c
            depth = max(-p.z, 0.001)
            need = max(need, abs(p.x) / depth / tan_h, abs(p.y) / depth / tan_v)
        # need = 内容占画面的比例；乘 MARGIN 让它留白
        dist *= need * MARGIN if need > 0.0 else 1.0
        dist = max(dist, 0.001)
        if abs(need * MARGIN - 1.0) < 0.004:
            break
    cam.location = center + d * dist
    cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
    return cam


def _render_settings():
    sc = bpy.context.scene
    sc.render.resolution_x = SS
    sc.render.resolution_y = SS
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = True   # 背景由 工具/合成建筑图标.py 画（天空/远山/大地）
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
    try:
        sc.view_settings.view_transform = 'Standard'
        sc.view_settings.look = 'None'
        sc.view_settings.exposure = -0.15
        sc.view_settings.gamma = 1.0
    except Exception:
        pass


def render_one(key, cn):
    src = os.path.join(MODEL_DIR, cn + ".glb")
    if not os.path.exists(src):
        print("!! 缺模型：%s" % src)
        return False
    _reset()
    bpy.ops.import_scene.gltf(filepath=src)
    mn, mx = _bounds(list(bpy.context.scene.objects))
    if mn is None:
        print("!! 没有网格：%s" % cn)
        return False
    center = (mn + mx) * 0.5
    extent = max(mx.x - mn.x, mx.y - mn.y, mx.z - mn.z)

    _world_gradient()
    _ground(mn, extent)
    _lights()
    _camera(mn, mx, center, extent)
    _render_settings()

    os.makedirs(RAW_DIR, exist_ok=True)
    sc = bpy.context.scene
    sc.render.filepath = os.path.join(RAW_DIR, key + ".png")
    bpy.ops.render.render(write_still=True)
    print("OK %-12s extent=%.1fm -> %s" % (key, extent, sc.render.filepath))
    return True


def main():
    argv = sys.argv
    want = argv[argv.index("--") + 1:] if "--" in argv else []
    ok = 0
    for key, cn in BUILDINGS:
        if want and key not in want:
            continue
        try:
            if render_one(key, cn):
                ok += 1
        except Exception as exc:
            print("!! %s 渲染失败：%s" % (key, exc))
    print("完成 %d 座" % ok)


main()
