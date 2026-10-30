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
out = os.path.join(HERE, "_walkqc")
for fr in (1,4,7,10,13,16,19,22,26):
    r.preview_action("walk", fr)
    K3.render_views("walk%02d" % fr, out, center, radius * 1.08, res=(420, 620), views={"侧": (1.0, 0.0, 0.10)})
print("HEADLESS " + json.dumps({"ok": True}))
