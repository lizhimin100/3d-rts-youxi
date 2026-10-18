# -*- coding: utf-8 -*-
import bpy, sys, os, json, math
sys.path.insert(0, r"E:\自定义游戏\简易rts\工具\建模")
res = {"blender": bpy.app.version_string, "py": sys.version.split()[0]}
try:
    import rts_kit as K
    res["kit"] = "ok"
    res["kit_funcs"] = len([n for n in dir(K) if not n.startswith("_")])
except Exception as e:
    res["kit"] = "FAIL: " + repr(e)
res["cwd"] = os.getcwd()
print("HEADLESS " + json.dumps(res, ensure_ascii=False))
