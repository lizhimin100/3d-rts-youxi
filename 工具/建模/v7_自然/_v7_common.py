# -*- coding: utf-8 -*-
"""
_v7_common.py —— v7 自然物 / 点缀物通用底座

与 v6 的差别（只加不改）：
  1. 导出与 QC 落到 美术/模型/v7_自然/ 与 v7_自然/qc/，不覆盖 v6 产物；
  2. QC 强制 Cycles（headless 下 EEVEE 没有 GL 上下文，会静默出黑图）；
  3. 增加 emissive()：v5 的 textured.build_material 不写自发光，
     金矿金脉微光 / 炉火 / 灯笼要在这里补；
  4. 新增 canvas / gold_glow / bark_dark / leaf_light / fire_stone 几个 zone。

几何仍走 kit3.Builder（按材质合并 mesh，一个资产 3~5 个 mesh）。
"""
import os
import sys
import json
import math
import random

import bpy
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
V3 = os.path.abspath(os.path.join(HERE, "..", "v3"))
V5 = os.path.abspath(os.path.join(HERE, "..", "v5"))
for p in (HERE, V3, V5):
    if p not in sys.path:
        sys.path.insert(0, p)

import kit3 as K3
import textured

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型\v7_自然"
QC_DIR = os.path.join(OUT_DIR, "qc")

D = K3.D
TAU = K3.TAU
W = K3.w_rigid("root")
mat = K3.mat
Builder = K3.Builder


# ---------------------------------------------------------------------------
# zone 扩展（材质名即协议：M_<zone>）
# ---------------------------------------------------------------------------
def _zone(zone, family, uv, hexv, rough, metal):
    textured.ZONES[zone] = (family, uv)
    K3.PALETTE[zone] = (hexv, rough, metal)


_zone("bark_dark", "bark", 1.15, "#42301F", 0.92, 0.0)
textured.ZONES["leaf"] = ("leaf", 0.30)
textured.ZONES["leaf_dark"] = ("leaf", 0.30)
_zone("leaf_light", "leaf", 0.30, "#6E9B44", 0.86, 0.0)
_zone("fire_stone", "rock", 0.55, "#6E6862", 0.90, 0.0)
_zone("gold_glow", "metal", 0.50, "#FFD25A", 0.26, 0.90)
_zone("canvas", "cloth", 0.90, "#CDBF9E", 0.94, 0.0)
_zone("cavity", "plaster", 1.2, "#0B0A09", 1.0, 0.0)
_zone("rope", "cloth", 0.30, "#9C8455", 0.92, 0.0)
_zone("rock", "rock", 0.45, "#5E584F", 0.88, 0.0)
_zone("rock_dark", "rock", 0.45, "#474239", 0.90, 0.0)


# ---------------------------------------------------------------------------
# 引擎 / 渲染
# ---------------------------------------------------------------------------
def setup_engine(samples=48):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    dev = "CPU"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        for t in ("OPTIX", "CUDA"):
            try:
                prefs.compute_device_type = t
                prefs.get_devices()
                if any(d.type == t for d in prefs.devices):
                    for d in prefs.devices:
                        d.use = (d.type == t)
                    dev = t
                    break
            except Exception:
                continue
    except Exception:
        pass
    sc.cycles.device = "GPU" if dev != "CPU" else "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 4
    print("[v7] render device =", dev)
    return dev


_PATCHED = [False]


def patch_render(samples=48):
    """kit3.render_views 内部会把引擎切回 EEVEE；这里包一层，切回 Cycles。"""
    if _PATCHED[0]:
        return
    orig = K3.setup_light_and_cam

    def wrapped(*a, **kw):
        out = orig(*a, **kw)
        sc = bpy.context.scene
        sc.render.engine = "CYCLES"
        sc.cycles.samples = samples
        sc.cycles.use_denoising = True
        sc.cycles.max_bounces = 3
        sc.render.film_transparent = False
        return out

    K3.setup_light_and_cam = wrapped
    _PATCHED[0] = True


def emissive(zone, color=(1.0, 1.0, 1.0), strength=1.0):
    """给 M_<zone> 的 Principled 加自发光（glTF 会导出 emissiveFactor + KHR_emissive_strength）。"""
    m = bpy.data.materials.get("M_" + zone)
    if m is None or not m.use_nodes:
        return False
    bsdf = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        return False
    if "Emission Color" in bsdf.inputs:
        bsdf.inputs["Emission Color"].default_value = (color[0], color[1], color[2], 1.0)
        bsdf.inputs["Emission Strength"].default_value = strength
        return True
    return False


# ---------------------------------------------------------------------------
# 几何小工具
# ---------------------------------------------------------------------------
def clump(b, center, r, material, seed=1, scale=(1, 1, 1), rot=(0, 0, 0),
          rough=0.22, subdiv=1, squash=None):
    """不规则分面块（树冠 / 石块）。可带旋转，才屑得开"圆球感"。"""
    rnd = random.Random(seed)
    bm = K3._bm_ico(r, subdiv)
    sc = list(scale)
    if squash is not None:
        sc[2] *= squash
    for v in bm.verts:
        k = 1.0 + rnd.uniform(-rough, rough)
        v.co = Vector((v.co.x * k * sc[0], v.co.y * k * sc[1], v.co.z * k * sc[2]))
    for f in bm.faces:
        f.smooth = False
    M = Matrix.Translation(Vector(center)) @ Euler(rot, "XYZ").to_matrix().to_4x4()
    b.add(bm, material, W, M)


def cyl_between(b, p0, p1, r0, r1, material, sides=6, weight=None):
    """从 p0 指向 p1 的锥台（枝干 / 撑杆 / 辐条）。"""
    p0 = Vector(p0)
    p1 = Vector(p1)
    d = p1 - p0
    ln = d.length
    if ln < 1e-5:
        return
    rot = d.to_track_quat("Z", "Y").to_euler()
    b.cyl(r0, r1, ln, loc=tuple(p0), rot=tuple(rot), material=material,
          sides=sides, weight=weight or W)


def blade(b, base, tip, width, material, bend=(0.0, 0.0), taper=0.18, weight=None):
    """一片草叶 / 树叶：两段收尖的薄带（6 顶点 4 面）。"""
    base = Vector(base)
    tip = Vector(tip)
    d = tip - base
    up = d.normalized()
    ref = Vector((0.0, 0.0, 1.0))
    if abs(up.dot(ref)) > 0.95:
        ref = Vector((0.0, 1.0, 0.0))
    side = up.cross(ref).normalized()

    rows = []
    for i, (t, w) in enumerate(((0.0, 1.0), (0.5, 0.72), (1.0, taper))):
        c = base + d * t + Vector(bend) * math.sin(math.pi * t)
        rows.append((c - side * (width * w * 0.5), c + side * (width * w * 0.5)))

    bm = __import__("bmesh").new()
    vs = []
    for a, bb in rows:
        vs.append(bm.verts.new(a))
        vs.append(bm.verts.new(bb))
    bm.verts.ensure_lookup_table()
    bm.faces.new((vs[0], vs[1], vs[3], vs[2]))
    bm.faces.new((vs[2], vs[3], vs[5], vs[4]))
    b.add(bm, material, weight or W)


def plank(b, center, size, material, rot=(0, 0, 0), bevel=0.01, weight=None):
    b.box(size, loc=center, rot=rot, material=material, bevel=bevel, seg=1, weight=weight or W)


def rope_line(b, p0, p1, r=0.018, material=None, sides=4, sag=0.0, segs=4):
    """带下垂的绳（帐篷拉绳 / 旗绳）。"""
    material = material or mat("rope")
    p0 = Vector(p0)
    p1 = Vector(p1)
    pts = []
    for i in range(segs + 1):
        t = i / float(segs)
        p = p0.lerp(p1, t) - Vector((0, 0, sag * math.sin(math.pi * t)))
        pts.append(tuple(p))
    b.tube(pts, r, material, weight=W, sides=sides)



def hoop(b, z, radius, r, material, segs=18, sides=4):
    """一圈细箍（木桶铁箍 / 旗杆环）：沿圆周的闭合细管。"""
    pts = [(radius * math.cos(TAU * i / segs), radius * math.sin(TAU * i / segs), z)
           for i in range(segs + 1)]
    b.tube(pts, r, material, weight=W, sides=sides)


def grid_surface(b, fn, nu, nv, material, weight=None):
    """参数曲面片（帐篷布 / 旗帜）：fn(u,v) -> (x,y,z)，u,v ∈ [0,1]。"""
    import bmesh as _bm
    bm = _bm.new()
    vs = [[bm.verts.new(fn(i / nu, j / nv)) for j in range(nv + 1)] for i in range(nu + 1)]
    for i in range(nu):
        for j in range(nv):
            bm.faces.new((vs[i][j], vs[i + 1][j], vs[i + 1][j + 1], vs[i][j + 1]))
    b.add(bm, material, weight or W)


# ---------------------------------------------------------------------------
# 导出
# ---------------------------------------------------------------------------
def export_glb(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    kw = dict(
        filepath=path, export_format="GLB", use_selection=False,
        export_apply=False, export_yup=True,
        export_animations=True, export_animation_mode="NLA_TRACKS",
        export_bake_animation=False, export_optimize_animation_size=False,
        export_normals=True, export_tangents=True, export_materials="EXPORT",
        export_skins=True, export_def_bones=False,
    )
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)
    return K3.glb_info(path)


# ---------------------------------------------------------------------------
# 总装
# ---------------------------------------------------------------------------
def run(builders, file_of, qc_views=None, res_of=None, emissive_of=None, ao_dist_of=None,
        do_qc=True, do_export=True, do_bake=True, samples=48):
    setup_engine(samples)
    patch_render(samples)
    qc_views = qc_views or {"正": (0.0, 1.0, 0.10), "三四": (0.85, 1.0, 0.30),
                            "RTS": (0.60, 1.0, 0.86)}
    reports = []
    for nm, fn in builders.items():
        coll = K3.reset_scene()
        objs = fn()
        mats, stat = textured.apply(objs, K3.PALETTE)
        for spec in (emissive_of or {}).get(nm, []):
            emissive(*spec)
        _ad = (ao_dist_of or {}).get(nm)
        if _ad and (do_qc or do_export) and do_bake:
            try:
                bpy.context.scene.world.light_settings.distance = float(_ad)
            except Exception as _e:
                print('[v7] ao dist set failed', _e)
        ao = textured.bake_ao(objs) if (do_qc or do_export) and do_bake else 0
        mn, mx = K3.bbox(objs)
        size = [round(v, 2) for v in (mx - mn)]
        rep = {"name": nm, "size": size, "zmin": round(mn.z, 2), "zmax": round(mx.z, 2),
               "ao_baked": ao, "meshes": len(objs), "zones": sorted(stat.keys()) if isinstance(stat, dict) else stat}

        if do_qc:
            c = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            radius = max((mx - mn).x, (mx - mn).y, (mx - mn).z) * 0.52
            res = (res_of or {}).get(nm, (760, 960))
            K3.render_views(nm, QC_DIR, c, max(radius, 0.18), views=qc_views, res=res)

        if do_export:
            textured.export_mode(mats, True)
            rep.update(export_glb(os.path.join(OUT_DIR, file_of[nm])))

        reports.append(rep)
        print("[v7] " + json.dumps(rep, ensure_ascii=False))
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)

    print("HEADLESS_V7 " + json.dumps(reports, ensure_ascii=False))
    return reports
