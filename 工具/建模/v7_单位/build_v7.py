# -*- coding: utf-8 -*-
"""
build_v7.py —— v7 单位总装：v7 几何 + v5 贴图/顶点 AO + RTS 机位 QC + GLB 导出

用法（必须用 E:/tmp/blender_ok/blender.exe，D 盘原目录被 ACL 挡了）：
    blender.exe -b --factory-startup --python 工具/建模/v7_单位/build_v7.py -- footman --qc --export
    blender.exe -b ... --python build_v7.py -- all --qc --export

和 v6 的差别只有三处：
  1. 几何来自 units_v7（体量加料版），骨架/动画/高度不动；
  2. QC 用**接近 RTS 的机位**（高机位、长焦、单位只占画面一半），不是影棚特写；
  3. 产物落在 美术/模型/v7_单位/，QC 落在 美术/模型/v7_单位/qc/。
"""
import os
import sys
import json
import time

import bpy
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
V3 = os.path.abspath(os.path.join(HERE, "..", "v3"))
V5 = os.path.abspath(os.path.join(HERE, "..", "v5"))
sys.path.insert(0, V3)
sys.path.insert(0, V5)
sys.path.insert(0, HERE)

import kit3 as K3
import textured
import units_v7 as U7

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型\v7_单位"
QC_DIR = os.path.join(OUT_DIR, "qc")
QC_NAME = {"footman": "footman", "crossbow": "archer", "mage": "mage", "peasant": "peasant"}
# QC 用哪一段动作的哪一帧：武术/弩要抬手才看得出武器关系
QC_POSE = {"footman": ("idle", 8), "crossbow": ("shoot", 13),
           "mage": ("idle", 8), "peasant": ("idle", 8)}

# RTS 机位：高机位俯视 + 长焦，单位只占画面约一半高度（不是影棚特写）
RTS_VIEWS = {
    "正": (0.00, 1.00, 0.72),
    "三四": (0.58, 0.84, 0.76),
}


def setup_engine():
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    dev = "CPU"
    for t in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = t
            prefs.get_devices()
            if any(d.type == t for d in prefs.devices):
                dev = t
                break
        except Exception:
            continue
    try:
        for d in prefs.devices:
            d.use = (d.type == dev)
    except Exception:
        pass
    sc.cycles.device = "GPU" if dev != "CPU" else "CPU"
    sc.cycles.samples = 32
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 4
    print("[v7] render device =", dev)


def _stage(center, cam_dir, radius_h, res):
    """建一套临时 QC 布景：相机 + 双太阳 + 地面。返回 (cam, helpers)。"""
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.film_transparent = False
    sc.render.image_settings.file_format = "PNG"

    cam_data = bpy.data.cameras.new("V7Cam")
    cam_data.lens = 58.0
    cam = bpy.data.objects.new("V7Cam", cam_data)
    sc.collection.objects.link(cam)

    d = Vector(cam_dir).normalized()
    # 长焦 + 3.25 倍高度的距离：竖直覆盖约 2 倍单位高，单位占一半画面
    dist = 4.10 * radius_h
    cam.location = Vector(center) + d * dist
    cam.rotation_euler = (Vector(center) - cam.location).to_track_quat("-Z", "Y").to_euler()
    sc.camera = cam

    key = bpy.data.lights.new("Key", "SUN")
    key.energy = 4.2
    key.angle = K3.D(9)
    ko = bpy.data.objects.new("Key", key)
    ko.rotation_euler = Euler((K3.D(54), 0, K3.D(34)), "XYZ")
    sc.collection.objects.link(ko)

    fill = bpy.data.lights.new("Fill", "SUN")
    fill.energy = 1.15
    fill.color = (0.72, 0.82, 1.0)
    fo = bpy.data.objects.new("Fill", fill)
    fo.rotation_euler = Euler((K3.D(66), 0, K3.D(-128)), "XYZ")
    sc.collection.objects.link(fo)

    world = bpy.data.worlds.get("World") or bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.26, 0.29, 0.27, 1.0)
    bg.inputs[1].default_value = 0.85
    sc.world = world

    bm = K3._bm_cube((44.0, 44.0, 0.02))
    M = Matrix.Translation(Vector((center[0], center[1], -0.012)))
    import bmesh
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    me = bpy.data.meshes.new("V7Ground")
    bm.to_mesh(me)
    bm.free()
    g = bpy.data.objects.new("V7Ground", me)
    gm = bpy.data.materials.new("M_V7Ground")
    gm.use_nodes = True
    bsdf = gm.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (0.23, 0.25, 0.19, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.94
    me.materials.append(gm)
    sc.collection.objects.link(g)
    return cam, [ko, fo, g]


def render_rts(name, center, radius_h, views=None, res=(900, 1100)):
    views = views or RTS_VIEWS
    os.makedirs(QC_DIR, exist_ok=True)
    sc = bpy.context.scene
    outs = []
    for key, d in views.items():
        cam, helpers = _stage(center, d, radius_h, res)
        tag = QC_NAME.get(name, name)
        path = os.path.join(QC_DIR, tag + "_" + key + ".png")
        sc.render.filepath = path
        bpy.ops.render.render(write_still=True)
        outs.append(path)
        for o in helpers + [cam]:
            bpy.data.objects.remove(o, do_unlink=True)
    return outs


def export_glb(path):
    """与 v6 同参数：顶点色 AO 显式 ACTIVATE、切线显式打开（glTF 会静默丢切线）。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    kw = dict(filepath=path, export_format="GLB", use_selection=False,
              export_apply=False, export_yup=True,
              export_animations=True, export_animation_mode="NLA_TRACKS",
              export_bake_animation=False, export_optimize_animation_size=False,
              export_normals=True, export_tangents=True, export_materials="EXPORT",
              export_skins=True, export_def_bones=False)
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)
    return K3.glb_info(path)


def main():
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    which = args[0] if args else "footman"
    do_qc = "--qc" in args
    do_export = "--export" in args
    names = list(U7.BUILDERS.keys()) if which == "all" else [which]

    setup_engine()
    reports = []
    for nm in names:
        t0 = time.time()
        r, objs = U7.BUILDERS[nm](U7.TARGET_H[nm])
        r.rest_pose()
        mats, stat = textured.apply(objs, K3.PALETTE)
        ao_n = textured.bake_ao(objs)
        mn, mx = K3.bbox(objs)
        size = [round(v, 3) for v in (mx - mn)]
        rep = {"name": nm, "file": U7.FILE_OF[nm], "size": size,
               "zmin": round(mn.z, 3), "zmax": round(mx.z, 3),
               "zones": stat, "mats": sorted(m.name for m in mats),
               "meshes": len([o for o in objs if o.type == "MESH"]),
               "ao_baked": ao_n}

        if do_qc:
            # 用 idle 第 8 帧出图：弓手举弩、农民持锄，才是游戏里看到的样子
            act, fr = QC_POSE.get(nm, ("idle", 8))
            r.preview_action(act, fr)
            center = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            outs = render_rts(nm, center, max(mx.z - mn.z, 1.0))
            rep["qc"] = [os.path.relpath(p, OUT_DIR) for p in outs]
            r.rest_pose()

        if do_export:
            textured.export_mode(mats, True)
            r.resume_nla()
            path = os.path.join(OUT_DIR, U7.FILE_OF[nm])
            rep.update(export_glb(path))
            rep["path"] = os.path.relpath(path, OUT_DIR)

        rep["seconds"] = round(time.time() - t0, 1)
        reports.append(rep)
        print("[v7] " + json.dumps(rep, ensure_ascii=False))

        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
        for ac in list(bpy.data.actions):
            bpy.data.actions.remove(ac)
        # 材质不删：kit3._MAT_CACHE 按 zone 缓存 datablock，删了下一件会拿到死引用

    out_json = os.path.join(HERE, "report_v7.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(reports, f, ensure_ascii=False, indent=1)
    print("HEADLESS_V7 " + json.dumps(reports, ensure_ascii=False))


if __name__ == "__main__":
    main()
