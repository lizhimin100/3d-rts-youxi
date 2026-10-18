import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Vector
import buildings_v6 as V6
name = sys.argv[sys.argv.index("--")+1] if "--" in sys.argv else "townhall"
rig, objs = V6.BUILDERS[name]()
for ob in objs:
    bb = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
    xs=[p.x for p in bb]; ys=[p.y for p in bb]; zs=[p.z for p in bb]
    print("BB %-28s x %6.2f..%6.2f  y %6.2f..%6.2f  z %6.2f..%6.2f" % (
        ob.name, min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
