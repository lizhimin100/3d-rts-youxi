# -*- coding: utf-8 -*-
"""
_v6_common.py —— v6 模型通用底座

把"贴图化 + 顶点AO烘焙 + GLB导出"三件事收口成一个入口，
让 units_v6 / props_v6 / decor_v6 都能一行复用，且材质命名、导出参数
与 buildings_v6 完全一致（引擎侧 MatKit / ArtKit 零改动）。
"""
import bpy
import os
import sys
import json

HERE = os.path.dirname(os.path.abspath(__file__))
V3 = os.path.abspath(os.path.join(HERE, "..", "v3"))
V5 = os.path.abspath(os.path.join(HERE, "..", "v5"))
sys.path.insert(0, V3)
sys.path.insert(0, V5)
sys.path.insert(0, HERE)

import kit3 as K3
import textured

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型"
QC_DIR = r"E:\自定义游戏\简易rts\工具\建模\v6\qc"


def export_glb(path, with_ao=True):
    """与 buildings_v6.export_glb 同参数：顶点色 AO 必须显式 ACTIVATE。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    kw = dict(
        filepath=path, export_format="GLB", use_selection=False,
        export_apply=False, export_yup=True,
        export_animations=True, export_animation_mode="NLA_TRACKS",
        export_bake_animation=False, export_optimize_animation_size=False,
        export_normals=True, export_tangents=True, export_materials="EXPORT",
        export_skins=True, export_def_bones=False,
    )
    vc = "ACTIVE" if with_ao else "NONE"
    try:
        bpy.ops.export_scene.gltf(export_vertex_color=vc, **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)
    return K3.glb_info(path)


def apply_and_bake(objs, palette=K3.PALETTE, do_bake=True):
    """套平铺贴图 + 烘顶点AO。返回 (materials, stat, ao_count)。"""
    mats, stat = textured.apply(objs, palette)
    ao = textured.bake_ao(objs) if do_bake else 0
    return mats, stat, ao


def run(builders, file_of, target_h=None, qc_views=None):
    """通用 main：builders={name: fn}，fn 返回 (rig_or_None, objs)。"""
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    which = args[0] if args else "all"
    do_qc = "--qc" in args
    do_export = "--export" in args
    names = list(builders) if which == "all" else [which]
    reports = []
    for nm in names:
        fn = builders[nm]
        r, objs = fn(target_h[nm]) if target_h else fn()
        if r is not None and hasattr(r, "rest_pose"):
            r.rest_pose()
        mats, stat, ao = apply_and_bake(objs)
        mn, mx = K3.bbox(objs)
        rep = {"name": nm, "size": [round(v, 2) for v in (mx - mn)],
               "ao": ao, "stat": stat}
        if do_qc and qc_views:
            center = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            radius = max(mx.x - mn.x, mx.z - mn.z) * 0.5
            K3.render_views(nm, QC_DIR, center, max(radius, 0.6), res=(900, 1170),
                            views=qc_views)
        if do_export:
            if r is not None and hasattr(r, "resume_nla"):
                r.resume_nla()
            textured.export_mode(mats, True)
            rep.update(export_glb(os.path.join(OUT_DIR, file_of[nm])))
        reports.append(rep)
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
        for act in list(bpy.data.actions):
            bpy.data.actions.remove(act)
    print("HEADLESS " + json.dumps(reports, ensure_ascii=False))
