# -*- coding: utf-8 -*-
import bpy, os, sys, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3, units as U
r, objs = U.BUILDERS["footman"](U.TARGET_H["footman"])
out = {}
out["bones"] = {b.name: {"deform": b.use_deform, "parent": b.parent.name if b.parent else None} for b in r.arm.data.bones}
for ob in objs:
    if ob.type != 'MESH': continue
    vg = ob.vertex_groups.get("head")
    if vg is None: continue
    n = 0; tot = 0.0; samples = []
    for v in ob.data.vertices:
        for g in v.groups:
            if g.group == vg.index:
                n += 1; tot += g.weight
                if len(samples) < 8: samples.append([round(v.co.x,2), round(v.co.y,2), round(v.co.z,2), round(g.weight,2)])
                break
    out[ob.name] = {"head_verts": n, "avg_w": round(tot/max(n,1),3), "samples": samples, "mods": [(m.type, getattr(m, "object", None).name if getattr(m, "object", None) else None) for m in ob.modifiers]}
print("HEADLESS " + json.dumps(out, ensure_ascii=False))
