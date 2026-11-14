# -*- coding: utf-8 -*-
"""
preview.py —— 验收出图工具（ANVIL）
------------------------------------------------------------------
把 staging 目录里已经导出的 GLB **重新导入**再出图，这样预览看到的就是
游戏里真正会拿到的那个文件（而不是构建脚本内存里的中间状态）。

用法：
    blender -b --factory-startup --python preview.py -- <目录> [视角...]

为什么单独一个脚本：几何迭代时不想每改一行就付一遍渲染钱；
形体定稿了再统一出图看。也方便对**已交付**的 GLB 做复核。
"""
import os
import sys
import json
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import rts_kit as K


def preview_one(path, views=("正", "三四"), res=(900, 900), samples=48, outdir=None):
    K.reset_scene()
    bpy.ops.import_scene.gltf(filepath=path)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        return {"glb": path, "error": "no mesh"}
    lo, hi = K.bbox(meshes)
    name = os.path.splitext(os.path.basename(path))[0]
    outdir = outdir or os.path.dirname(path)
    outs, tgt, rad = K.render_views(name, outdir, views=views, res=res, samples=samples)
    return {
        "glb": path,
        "views": outs,
        "tris": K.tri_count(meshes),
        "meshes": len(meshes),
        "size": [round(hi.x - lo.x, 3), round(hi.y - lo.y, 3), round(hi.z - lo.z, 3)],
        "min": [round(lo.x, 3), round(lo.y, 3), round(lo.z, 3)],
        "max": [round(hi.x, 3), round(hi.y, 3), round(hi.z, 3)],
    }


def main():
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    if not args:
        print("需要目录参数", file=sys.stderr)
        return
    folder = args[0]
    views = tuple(args[1:]) or ("正", "三四")
    files = sorted(glob.glob(os.path.join(folder, "*.glb")))
    reps = []
    for f in files:
        reps.append(preview_one(f, views=views))
    K.headless_report({"previews": reps})


if __name__ == "__main__":
    main()
