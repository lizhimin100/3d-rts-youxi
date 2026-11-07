"""把一个 glb 的某个动作渲染成一条横向帧序列（评估攻击动作是"一刀"还是"连砍"）。

用法：
  blender.exe -b -P 工具/渲染动作帧.py -- <glb> <输出目录> <动作名> [帧数] [朝向角度]

输出：<输出目录>/<动作名>_<序号>.png（正交侧视，自动取景）
"""
import bpy
import sys
import os
import math
from mathutils import Vector

argv = sys.argv
if "--" not in argv:
    sys.exit(1)
args = argv[argv.index("--") + 1:]
glb = args[0]
outdir = args[1]
clip = args[2]
n_frames = int(args[3]) if len(args) > 3 else 12
yaw_deg = float(args[4]) if len(args) > 4 else 90.0

os.makedirs(outdir, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)

arm = None
for o in bpy.data.objects:
    if o.type == 'ARMATURE':
        arm = o
        break
if arm is None:
    print("NO_ARMATURE")
    sys.exit(2)

# 把动作挂到 armature 上
act = None
for a in bpy.data.actions:
    if a.name == clip or a.name.startswith(clip):
        act = a
        break
if act is None:
    print("ACTIONS:" + ",".join(a.name for a in bpy.data.actions))
    sys.exit(3)
if arm.animation_data is None:
    arm.animation_data_create()
arm.animation_data.action = act
try:
    slot = arm.animation_data.action_suitable_slots[0]
    arm.animation_data.action_slot = slot
except Exception:
    pass

fs, fe = act.frame_range
length = max(fe - fs, 1.0)
scene = bpy.context.scene
scene.frame_start = int(fs)
scene.frame_end = int(fe)

# 取包围盒（用 mesh 顶点估算高度与中心）
lo = Vector((1e9, 1e9, 1e9))
hi = Vector((-1e9, -1e9, -1e9))
for o in bpy.data.objects:
    if o.type != 'MESH':
        continue
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c)
        for i in range(3):
            lo[i] = min(lo[i], w[i])
            hi[i] = max(hi[i], w[i])
center = (lo + hi) * 0.5
height = max(hi.z - lo.z, 0.5)

cam_data = bpy.data.cameras.new("Cam")
cam_data.type = 'ORTHO'
cam_data.ortho_scale = height * 1.55
cam = bpy.data.objects.new("Cam", cam_data)
bpy.context.collection.objects.link(cam)
scene.camera = cam

ang = math.radians(yaw_deg)
dist = max(height * 3.0, 4.0)
cam.location = center + Vector((math.cos(ang) * dist, math.sin(ang) * dist, 0.0))
# 看向中心
direction = center - cam.location
cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()

# 灯光
sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
sun.data.energy = 3.0
sun.rotation_euler = (math.radians(55), 0, math.radians(35))
bpy.context.collection.objects.link(sun)
world = bpy.data.worlds.new("W")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.35, 0.38, 0.42, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.8
scene.world = world

scene.render.engine = 'BLENDER_WORKBENCH'
scene.render.resolution_x = 240
scene.render.resolution_y = 300
scene.render.film_transparent = False
scene.render.image_settings.file_format = 'PNG'

for i in range(n_frames):
    t = float(i) / max(n_frames - 1, 1)
    f = int(round(fs + length * t))
    scene.frame_set(f)
    scene.render.filepath = os.path.join(outdir, "%s_%02d.png" % (clip, i))
    bpy.ops.render.render(write_still=True)
print("DONE %s frames=%d range=%.1f-%.1f" % (clip, n_frames, fs, fe))
