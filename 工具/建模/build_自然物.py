"""自然物与资源点建模：树 / 岩石 / 金矿。

设计原则（对应验收要求）：
  - 平面着色（flat shading）、低多边形块面；
  - 不用"方块摞方块"：树干是**环形放样**出的连续收分 + 弯曲，底部有板根；
    树冠是**多层错位的变形二十面体簇**；岩石是**咬合的棱角碎块**；
    金矿是岩壁 + 嵌在缝里的金色晶簇 + 木支撑 + 矿车；
  - 朝向：正面朝 Blender +Y（= Godot -Z）；底面贴 z=0；枢轴在底面中心。

运行：
  blender -b --factory-startup --python 工具/建模/build_自然物.py
输出：D:\\blender\\.workbuddy\\rts_out\\自然物\\{树,岩石,金矿}.glb
"""

import bpy
import bmesh
import math
import os
import json
import random
from mathutils import Vector, Euler, noise

OUT_DIR = r"D:\blender\.workbuddy\rts_out\自然物"


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def make_material(name, color, roughness=0.85, metallic=0.0, emission=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 2.0
    return m


def new_mesh_object(name, verts, faces, material, smooth=False):
    """用裸顶点/面建对象（最稳，headless 下不依赖 bpy.ops 的 context）"""
    mesh = bpy.data.meshes.new(name + "_mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.validate()
    mesh.update()
    for p in mesh.polygons:
        p.use_smooth = smooth
    if material is not None:
        mesh.materials.append(material)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def loft(rings, close_bottom=True, close_top=True):
    """环形放样：rings = [(center(Vector), radius, n_sides), ...]，返回 (verts, faces)"""
    verts = []
    faces = []
    n = rings[0][2]
    for center, radius, sides in rings:
        n = sides
        for k in range(sides):
            a = 2.0 * math.pi * k / sides
            verts.append((center.x + math.cos(a) * radius,
                          center.y + math.sin(a) * radius,
                          center.z))
    ring_count = len(rings)
    for i in range(ring_count - 1):
        base = i * n
        nxt = (i + 1) * n
        for k in range(n):
            k2 = (k + 1) % n
            faces.append([base + k, base + k2, nxt + k2, nxt + k])
    if close_bottom:
        faces.append(list(range(n - 1, -1, -1)))
    if close_top:
        base = (ring_count - 1) * n
        faces.append([base + k for k in range(n)])
    return verts, faces


def deform_blob(verts, seed=0, amp=0.18, freq=2.2):
    """把球面顶点按噪声推一推，得到不规则块状（岩石/树冠用）"""
    rng = random.Random(seed)
    out = []
    for v in verts:
        p = Vector(v)
        d = noise.noise(p * freq + Vector((rng.random() * 0.01, 0, 0)))
        out.append(tuple(p * (1.0 + d * amp)))
    return out


def ico_verts(subdiv=1, radius=1.0):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=radius)
    verts = [tuple(v.co) for v in bm.verts]
    faces = [[v.index for v in f.verts] for f in bm.faces]
    bm.free()
    return verts, faces


def add_part(parent, name, verts, faces, material, location=(0, 0, 0), rotation=(0, 0, 0),
             scale=(1, 1, 1), smooth=False):
    obj = new_mesh_object(name, verts, faces, material, smooth)
    obj.parent = parent
    obj.location = location
    obj.rotation_euler = Euler(rotation, 'XYZ')
    obj.scale = scale
    return obj


# ---------------------------------------------------------------------------
# 树
# ---------------------------------------------------------------------------

def build_tree():
    reset_scene()
    bark = make_material("树皮", (0.235, 0.165, 0.105), 0.95)
    bark_dark = make_material("树皮深", (0.165, 0.112, 0.072), 0.97)
    leaf_a = make_material("树叶A", (0.145, 0.315, 0.115), 0.88)
    leaf_b = make_material("树叶B", (0.215, 0.400, 0.140), 0.86)
    leaf_c = make_material("树叶C", (0.098, 0.235, 0.088), 0.90)

    root = bpy.data.objects.new("Root", None)
    bpy.context.scene.collection.objects.link(root)
    trunk_grp = bpy.data.objects.new("Trunk", None)
    trunk_grp.parent = root
    bpy.context.scene.collection.objects.link(trunk_grp)
    canopy_grp = bpy.data.objects.new("Canopy", None)
    canopy_grp.parent = root
    bpy.context.scene.collection.objects.link(canopy_grp)

    # --- 树干：连续收分 + 轻微弯曲（环形放样，7 边）---
    rings = []
    H = 5.6
    steps = 7
    for i in range(steps):
        t = i / float(steps - 1)
        z = 0.10 + t * (H * 0.62)
        r = 0.36 * (1.0 - t) ** 0.75 + 0.075
        bend_x = 0.16 * math.sin(t * 2.1)
        bend_y = 0.07 * math.cos(t * 3.0)
        rings.append((Vector((bend_x, bend_y, z)), r, 7))
    v, f = loft(rings, close_bottom=True, close_top=True)
    add_part(trunk_grp, "GEO-trunk", v, f, bark)

    # --- 板根：三片楔形，从树干底部外扩 ---
    for i, ang in enumerate((0.35, 2.5, 4.4)):
        length = 0.95 + 0.18 * i
        w = 0.16
        h = 0.55
        base = [
            (0.0, -w, 0.02), (0.0, w, 0.02),
            (length * 0.55, w * 0.5, h * 0.35), (length * 0.55, -w * 0.5, h * 0.35),
            (length, 0.0, 0.02),
        ]
        faces = [[0, 1, 2, 3], [3, 2, 4], [0, 3, 4], [1, 4, 3], [0, 4, 1]]
        add_part(trunk_grp, "GEO-root_%d" % i, base, faces, bark_dark,
                 rotation=(0, 0, ang))

    # --- 枝条：几根从树干上段斜出去 ---
    for i, (ang, t_h, ln) in enumerate(((0.9, 0.46, 1.25), (2.6, 0.52, 1.05), (4.5, 0.42, 1.35))):
        rings2 = []
        for s in range(4):
            tt = s / 3.0
            r = 0.10 * (1.0 - tt) + 0.028
            rings2.append((Vector((math.cos(ang) * ln * tt, math.sin(ang) * ln * tt, t_h * H + tt * 0.42)), r, 5))
        v2, f2 = loft(rings2)
        add_part(trunk_grp, "GEO-branch_%d" % i, v2, f2, bark)

    # --- 树冠：4 层错位簇，每层 2~4 个变形二十面体 ---
    layers = [
        (H * 0.55, 1.55, 3, leaf_c),
        (H * 0.70, 1.80, 4, leaf_a),
        (H * 0.84, 1.45, 3, leaf_b),
        (H * 0.95, 0.95, 2, leaf_a),
    ]
    seed = 7
    for li, (z, spread, count, mat) in enumerate(layers):
        for i in range(count):
            seed += 1
            rng = random.Random(seed)
            ang = 2.0 * math.pi * i / count + li * 0.7
            rad = spread * (0.42 if count > 1 else 0.0)
            scl = spread * rng.uniform(0.44, 0.62)
            verts, faces = ico_verts(subdiv=1, radius=1.0)
            verts = deform_blob(verts, seed=seed * 13, amp=0.26, freq=1.7)
            add_part(canopy_grp, "GEO-leaf_%d_%d" % (li, i), verts, faces, mat,
                     location=(math.cos(ang) * rad, math.sin(ang) * rad, z),
                     rotation=(rng.uniform(-0.3, 0.3), rng.uniform(0, 3.14), rng.uniform(-0.3, 0.3)),
                     scale=(scl, scl, scl * rng.uniform(0.72, 0.92)))

    return root


# ---------------------------------------------------------------------------
# 岩石
# ---------------------------------------------------------------------------

def build_rock():
    reset_scene()
    m1 = make_material("岩石", (0.360, 0.360, 0.375), 0.94)
    m2 = make_material("岩石暗", (0.255, 0.258, 0.272), 0.96)
    m3 = make_material("岩石苔", (0.230, 0.285, 0.205), 0.95)

    root = bpy.data.objects.new("Root", None)
    bpy.context.scene.collection.objects.link(root)

    rng = random.Random(21)
    specs = [
        ((0.00, 0.00, 0.42), 0.78, m1, (0.9, 1.0, 0.75)),
        ((0.52, 0.16, 0.26), 0.52, m2, (1.0, 0.9, 0.8)),
        ((-0.40, -0.22, 0.24), 0.45, m3, (0.95, 1.0, 0.7)),
        ((0.05, 0.46, 0.18), 0.33, m2, (1.1, 0.85, 0.9)),
    ]
    for i, (loc, size, mat, scl) in enumerate(specs):
        verts, faces = ico_verts(subdiv=1, radius=size)
        verts = deform_blob(verts, seed=100 + i * 7, amp=0.42, freq=2.6)
        add_part(root, "GEO-rock_%d" % i, verts, faces, mat,
                 location=loc,
                 rotation=(rng.uniform(-0.2, 0.2), rng.uniform(0, 6.28), rng.uniform(-0.2, 0.2)),
                 scale=scl)
    return root


# ---------------------------------------------------------------------------
# 金矿
# ---------------------------------------------------------------------------

def build_goldmine():
    reset_scene()
    rock = make_material("矿岩", (0.330, 0.320, 0.300), 0.95)
    rock_d = make_material("矿岩暗", (0.215, 0.208, 0.196), 0.97)
    gold = make_material("金脉", (0.855, 0.640, 0.130), 0.28, metallic=0.85)
    wood = make_material("矿木", (0.330, 0.215, 0.115), 0.92)
    iron = make_material("矿铁", (0.230, 0.240, 0.255), 0.55, metallic=0.6)

    root = bpy.data.objects.new("Root", None)
    bpy.context.scene.collection.objects.link(root)
    rock_grp = bpy.data.objects.new("Rock", None)
    rock_grp.parent = root
    bpy.context.scene.collection.objects.link(rock_grp)
    gold_grp = bpy.data.objects.new("Veins", None)
    gold_grp.parent = root
    bpy.context.scene.collection.objects.link(gold_grp)
    prop_grp = bpy.data.objects.new("Props", None)
    prop_grp.parent = root
    bpy.context.scene.collection.objects.link(prop_grp)

    rng = random.Random(33)
    # --- 岩壁：三块大石咬合，堆成一面墙（正面朝 +Y 开口）---
    chunks = [
        ((-0.95, 0.15, 0.85), 1.15, rock, (1.05, 0.95, 1.15)),
        ((0.75, -0.10, 0.95), 1.25, rock_d, (0.95, 1.05, 1.20)),
        ((0.05, 0.55, 1.55), 1.05, rock, (1.10, 0.90, 0.95)),
        ((-0.35, -0.55, 0.45), 0.85, rock_d, (1.0, 1.0, 0.85)),
    ]
    for i, (loc, size, mat, scl) in enumerate(chunks):
        verts, faces = ico_verts(subdiv=1, radius=size)
        verts = deform_blob(verts, seed=200 + i * 11, amp=0.38, freq=2.1)
        add_part(rock_grp, "GEO-ore_rock_%d" % i, verts, faces, mat,
                 location=loc, rotation=(rng.uniform(-0.25, 0.25), rng.uniform(0, 6.28), rng.uniform(-0.25, 0.25)),
                 scale=scl)

    # --- 金色晶簇：细长八面体从岩缝里钻出来 ---
    for i in range(11):
        ang = rng.uniform(0, 6.28)
        rad = rng.uniform(0.25, 0.95)
        cx = math.cos(ang) * rad
        cy = 0.42 + math.sin(ang) * rad * 0.45
        cz = rng.uniform(0.55, 1.85)
        h = rng.uniform(0.22, 0.52)
        w = rng.uniform(0.055, 0.105)
        verts = [(0, 0, 0), (w, 0, h * 0.45), (0, w, h * 0.45), (-w, 0, h * 0.45),
                 (0, -w, h * 0.45), (0, 0, h)]
        faces = [[0, 1, 2], [0, 2, 3], [0, 3, 4], [0, 4, 1],
                 [5, 2, 1], [5, 3, 2], [5, 4, 3], [5, 1, 4]]
        add_part(gold_grp, "GEO-vein_%d" % i, verts, faces, gold,
                 location=(cx, cy, cz),
                 rotation=(rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5)))

    # --- 木支撑架：两根立柱 + 一根横梁 ---
    for sx in (-1.55, 1.55):
        v = [(-0.09, -0.09, 0), (0.09, -0.09, 0), (0.09, 0.09, 0), (-0.09, 0.09, 0),
             (-0.07, -0.07, 2.35), (0.07, -0.07, 2.35), (0.07, 0.07, 2.35), (-0.07, 0.07, 2.35)]
        f = [[0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7], [4, 5, 6, 7], [3, 2, 1, 0]]
        add_part(prop_grp, "GEO-post_%s" % ("L" if sx < 0 else "R"), v, f, wood,
                 location=(sx, 0.75, 0.0))
    beam = [(-1.62, -0.06, 2.42), (1.62, -0.06, 2.42), (1.62, 0.10, 2.42), (-1.62, 0.10, 2.42),
            (-1.62, -0.06, 2.60), (1.62, -0.06, 2.60), (1.62, 0.10, 2.60), (-1.62, 0.10, 2.60)]
    bf = [[0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7], [4, 5, 6, 7], [3, 2, 1, 0]]
    add_part(prop_grp, "GEO-beam", beam, bf, wood)

    # --- 矿车：斗 + 四个轮 ---
    cart = [(-0.42, -0.28, 0.22), (0.42, -0.28, 0.22), (0.42, 0.28, 0.22), (-0.42, 0.28, 0.22),
            (-0.52, -0.36, 0.72), (0.52, -0.36, 0.72), (0.52, 0.36, 0.72), (-0.52, 0.36, 0.72)]
    cf = [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]
    cart_obj = add_part(prop_grp, "GEO-cart", cart, cf, iron, location=(1.05, 1.35, 0.0))
    for i, (wx, wy) in enumerate(((-0.30, -0.30), (0.30, -0.30), (-0.30, 0.30), (0.30, 0.30))):
        wheel_v, wheel_f = loft([
            (Vector((0, -0.05, 0)), 0.14, 8),
            (Vector((0, 0.05, 0)), 0.14, 8),
        ])
        add_part(cart_obj, "GEO-wheel_%d" % i, wheel_v, wheel_f, iron,
                 location=(wx, wy, 0.16), rotation=(math.pi / 2, 0, 0))

    return root


# ---------------------------------------------------------------------------
# 导出
# ---------------------------------------------------------------------------

def export_glb(root, path):
    bpy.ops.object.select_all(action='DESELECT')
    for o in bpy.context.scene.objects:
        o.select_set(True)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format='GLB', use_selection=False,
        export_apply=True, export_yup=True, export_extras=True,
    )
    tris = 0
    for o in bpy.context.scene.objects:
        if o.type == 'MESH' and o.data is not None:
            tris += len(o.data.loop_triangles) if o.data.loop_triangles else len(o.data.polygons)
    return {"path": path, "bytes": os.path.getsize(path) if os.path.exists(path) else 0,
            "objects": len(bpy.context.scene.objects), "faces": tris}


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    report = {}
    for name, builder in (("树", build_tree), ("岩石", build_rock), ("金矿", build_goldmine)):
        builder()
        out = os.path.join(OUT_DIR, name + ".glb")
        report[name] = export_glb(bpy.context.scene.objects[0], out)
    print("HEADLESS " + json.dumps(report, ensure_ascii=False))


main()
