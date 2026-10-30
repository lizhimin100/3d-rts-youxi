# -*- coding: utf-8 -*-
import bpy, os, sys, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3, units as U
r, objs = U.BUILDERS["footman"](U.TARGET_H["footman"])
r.preview_action("death", 26)
out = {}
for nm in ["hips","spine","chest","neck","head","thigh.L","shin.L","foot.L"]:
    pb = r.arm.pose.bones.get(nm)
    if pb is not None:
        out[nm] = {"head": [round(v,3) for v in pb.head], "tail": [round(v,3) for v in pb.tail], "len": round(pb.length,3)}
# evaluated head-weighted vertex centroid per mesh object
for ob in objs:
    if ob.type != 'MESH': continue
    vg = ob.vertex_groups.get("head")
    if vg is None: continue
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    mw = ev.matrix_world
    pts = []
    for v in me.vertices:
        for g in v.groups:
            if g.group == vg.index and g.weight > 0.4:
                pts.append(mw @ v.co)
                break
    if pts:
        c = sum(pts, __import__("mathutils").Vector((0,0,0))) / len(pts)
        out["head_verts_" + ob.name] = {"n": len(pts), "centroid": [round(v,3) for v in c]}
    ev.to_mesh_clear()
print("HEADLESS " + json.dumps(out, ensure_ascii=False))
