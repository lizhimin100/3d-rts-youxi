# -*- coding: utf-8 -*-
"""
build_all.py —— v5 总装：几何（v3）+ 贴图/法线（v5）→ GLB

用法（必须用 E:\\tmp\\blender_ok\\blender.exe，D 盘原目录被 ACL 挡了，跑不起来）：
    blender.exe -b --factory-startup --python build_all.py -- all --qc --export
    blender.exe -b ... --python build_all.py -- footman --qc
分组：
    buildings / units / props / all

为什么单独一份 main 而不改 v3 的 main：
   v3 的 main 里"渲染 QC → 导出"是一次性串起来的，而 v5 必须在**导出前**
   把材质从"调色板×贴图"切成"纯贴图"（否则 glTF 的 baseColorFactor 会把
   引擎侧调色板乘第二遍，全场发黑）。所以这里接管主流程，v3 的构建函数原样调用。
"""

import os
import sys
import json
import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
V3 = os.path.abspath(os.path.join(HERE, "..", "v3"))
sys.path.insert(0, V3)
sys.path.insert(0, HERE)

import kit3 as K3
import textured
import buildings as B
import units as U
import props as P

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型"
QC_DIR = r"E:\自定义游戏\简易rts\工具\建模\v5\qc"


def setup_engine():
    """QC 用 Cycles + GPU（用户明确要求）；EEVEE 在纯 headless 下没有 GL 上下文，
    会静默出一张黑图 —— 所以这里直接走 Cycles，OptiX 优先。"""
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
    for d in prefs.devices:
        d.use = (d.type == dev)
    sc.cycles.device = "GPU" if dev != "CPU" else "CPU"
    sc.cycles.samples = 64
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 4
    print("[v5] render device =", dev)


def do_group(kind, name):
    if kind == "buildings":
        rig, objs = B.BUILDERS[name]()
        rig.rest_pose()
        return rig, objs, B.FILE_OF[name], "building"
    if kind == "units":
        rig, objs = U.BUILDERS[name](U.TARGET_H[name])
        rig.rest_pose()
        return rig, objs, U.FILE_OF[name], "unit"
    objs = P.BUILDERS[name]()
    return None, objs, P.FILE_OF[name], "prop"


def export_glb(path):
    """导出：带切线、带顶点色（AO）、带贴图。

    export_vertex_color="ACTIVE" 是关键 —— 默认 "MATERIAL" 只在材质里
    真接了 Color Attribute 时才写 COLOR_0，换个版本就可能丢；
    这里直接锁死"导出当前激活色层"。
    """
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
    which = args[0] if args else "all"
    do_qc = "--qc" in args
    do_export = "--export" in args

    groups = {
        "buildings": list(B.BUILDERS.keys()),
        "units": list(U.BUILDERS.keys()),
        "props": list(P.BUILDERS.keys()),
    }
    if which == "all":
        todo = [(g, n) for g in ("units", "props", "buildings") for n in groups[g]]
    elif which in groups:
        todo = [(which, n) for n in groups[which]]
    else:
        todo = [(g, which) for g in groups if which in groups[g]]

    setup_engine()
    reports = []
    for kind, name in todo:
        rig, objs, fname, fkind = do_group(kind, name)
        mats, stat = textured.apply(objs, K3.PALETTE)
        ao_n = textured.bake_ao(objs) if (do_qc or do_export) else 0
        mn, mx = K3.bbox(objs)
        size = [round(v, 2) for v in (mx - mn)]
        rep = {"name": name, "kind": fkind, "size": size,
               "zmin": round(mn.z, 2), "zmax": round(mx.z, 2),
               "zones": stat, "textured_mats": len(mats), "ao_baked": ao_n}

        if do_qc:
            c = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            radius = max(mx.x - mn.x, mx.z - mn.z) * 0.5
            res = (900, 1170) if fkind != "prop" else (700, 860)
            # 多角度：正 / 三四 / 四（另一侧）/ 背。玩家要求"别只给一张正视图"。
            K3.render_views(name, QC_DIR, c, max(radius, 0.6) * 1.3, res=res,
                            views={"正": (0.0, 1.0, 0.12),
                                   "三四": (0.85, 1.0, 0.30),
                                   "四": (-0.85, 1.0, 0.30),
                                   "背": (0.0, -1.0, 0.16)})
            # 近景：贴图/法线就是这个视角能看出来的
            if fkind == "building":
                near_c = (0.0, 0.0, mn.z + (mx.z - mn.z) * 0.34)
                near_r = max(radius, 1.2) * 0.55
            elif fkind == "unit":
                near_c = (0.0, 0.0, mx.z * 0.76)
                near_r = 0.38
            else:
                near_c = c
                near_r = max(radius, 0.6) * 0.75
            K3.render_views(name, QC_DIR, near_c, near_r, res=(1000, 1000),
                            views={"近": (0.80, 1.0, 0.18)})

        if do_export:
            textured.export_mode(mats, True)
            if rig is not None:
                rig.resume_nla()
            rep.update(export_glb(os.path.join(OUT_DIR, fname)))
            rep["mats"] = rep.pop("materials", None)
        reports.append(rep)
        print("[v5] " + json.dumps(rep, ensure_ascii=False))

        # 清理（下一个资产不带上一个的材质/动作）
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
        for ac in list(bpy.data.actions):
            bpy.data.actions.remove(ac)
        # ★ 材质**不能删**：kit3._MAT_CACHE 按 zone 缓存 datablock，
        #   删了下一件资产就会拿到死引用（Material has been removed）。

    print("HEADLESS_V5 " + json.dumps(reports, ensure_ascii=False))


if __name__ == "__main__":
    main()
