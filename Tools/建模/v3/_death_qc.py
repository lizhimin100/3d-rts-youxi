# -*- coding: utf-8 -*-
import bpy, os, sys, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3, units as U
r, objs = U.BUILDERS["footman"](U.TARGET_H["footman"])
r.rest_pose()
mn, mx = K3.bbox(objs)
center = (0.0, 0.0, (mn.z + mx.z) * 0.5)
radius = max(mx.x - mn.x, mx.z - mn.z) * 0.5
out = os.path.join(HERE, "_deathqc")
for fr in (1,6,11,16,21,26,31):
    r.preview_action("death", fr)
    K3.render_views("death%02d" % fr, out, center, radius * 1.15, res=(520, 520), views={"侧": (1.0, 0.0, 0.15), "三四": (0.9, 1.0, 0.25)})
print("HEADLESS " + json.dumps({"ok": True}))
