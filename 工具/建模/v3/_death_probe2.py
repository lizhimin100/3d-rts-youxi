# -*- coding: utf-8 -*-
import bpy, os, sys, json
from mathutils import Vector
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3, units as U
r, objs = U.BUILDERS["footman"](U.TARGET_H["footman"])
r.preview_action("death", 26)
ob = bpy.data.objects.get("footman_M_steel")
dg = bpy.context.evaluated_depsgraph_get()
ev = ob.evaluated_get(dg)
me = ev.to_mesh()
mw = ev.matrix_world
# find first vertex in each group
groups = {g.name: g.index for g in ob.vertex_groups}
picks = {}
for v in ob.data.vertices:
    for g in v.groups:
        for nm, idx in groups.items():
            if g.group == idx and g.weight > 0.9 and nm in ("head","chest","hips","thigh.L"):
                picks.setdefault(nm, (v.index, [round(c,3) for c in v.co]))
out = {"picks": picks, "evaluated": {}, "bone": {}}
for nm,(vi,co) in picks.items():
    out["evaluated"][nm] = [round(c,3) for c in (mw @ me.vertices[vi].co)]
    pb = r.arm.pose.bones.get(nm)
    if pb: out["bone"][nm] = {"head":[round(c,3) for c in pb.head], "tail":[round(c,3) for c in pb.tail]}
out["arm_matrix"] = [[round(c,3) for c in row] for row in r.arm.matrix_world]
out["ob_parent_inverse"] = [[round(c,3) for c in row] for row in ob.matrix_parent_inverse]
ev.to_mesh_clear()
print("HEADLESS " + json.dumps(out, ensure_ascii=False))
