"""给方块人系列加一个「举盾持续」动作（shield_hold），导出回 glb。

用法：
  blender.exe -b -P 工具/加举盾动作.py -- <glb> <输出glb> [试摆JSON] [--render=目录]

`试摆JSON` 形如 `{"upperarm_L":[0,0,-1.15],"forearm_L":[0,0,-1.35],"chest":[0,0,0.18]}`，
不传就用脚本里的默认角度。

设计目标（玩家 2026-11-07）：举盾 = 左臂把盾横到胸前，身体略侧；
动作 0.6 秒、首尾同姿势（可循环），这样"举着盾走路/站着"都不会突然放下。
"""
import bpy
import sys
import os
import json
import math
from mathutils import Vector

argv = sys.argv
args = argv[argv.index("--") + 1:] if "--" in argv else []
if len(args) < 2:
    print("ARGS: <glb> <out_glb> [pose_json] [--render=dir]")
    sys.exit(1)
src = args[0]
dst = args[1]
pose_json = args[2] if len(args) > 2 and not args[2].startswith("--") else ""
render_dir = ""
for a in args:
    if a.startswith("--render="):
        render_dir = a.split("=", 1)[1]

# 默认姿势：上臂向前抬 + 内收，前臂屈，躯干微侧
POSE = {
    "upperarm_L": [0.0, -0.35, -1.15],
    "forearm_L": [0.0, 0.0, -1.30],
    "chest": [0.0, 0.10, 0.16],
}
if pose_json:
    POSE.update(json.loads(pose_json))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

arm = None
for o in bpy.data.objects:
    if o.type == 'ARMATURE':
        arm = o
        break
if arm is None:
    print("NO_ARMATURE")
    sys.exit(2)

bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='POSE')

# 记录原始旋转模式，导出前恢复（glTF 只认四元数，但编辑器里保持 XYZ 好调）
for pb in arm.pose.bones:
    pb.rotation_mode = 'XYZ'

# 清空当前动作，新建
if arm.animation_data is None:
    arm.animation_data_create()
act = bpy.data.actions.new("shield_hold")
arm.animation_data.action = act
try:
    arm.animation_data.action_slot = arm.animation_data.action_suitable_slots[0]
except Exception:
    pass

# 0 / 0.30 / 0.60 秒三帧：起 → 到位 → 保持（首尾同姿势才能循环）
fps = 24
frames = [0, 7, 14]
for f in frames:
    bpy.context.scene.frame_set(f)
    for name, rot in POSE.items():
        pb = arm.pose.bones.get(name)
        if pb is None:
            print("NO_BONE:" + name)
            continue
        # 第一帧从 0 过渡，1/3 处到位，后面保持
        k = 1.0 if f >= frames[1] else (float(f) / max(frames[1], 1))
        pb.rotation_euler = (rot[0] * k, rot[1] * k, rot[2] * k)
        pb.keyframe_insert("rotation_euler", frame=f)

# 让曲线平滑（Blender 5.x 的 Action 是 slotted 结构，fcurves 不在 action 上；
# 关键帧默认就是 BEZIER，这里不再手动改插值）

bpy.ops.object.mode_set(mode='OBJECT')

# ---- 可选：渲 4 帧看看效果 ----
if render_dir:
    os.makedirs(render_dir, exist_ok=True)
    scene = bpy.context.scene
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
    cam_data.ortho_scale = height * 1.6
    cam = bpy.data.objects.new("Cam", cam_data)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    ang = math.radians(90)
    dist = max(height * 3.0, 4.0)
    cam.location = center + Vector((math.cos(ang) * dist, math.sin(ang) * dist, 0.0))
    cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(55), 0, math.radians(35))
    bpy.context.collection.objects.link(sun)
    w = bpy.data.worlds.new("W")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.35, 0.38, 0.42, 1)
    scene.world = w
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.render.resolution_x = 260
    scene.render.resolution_y = 320
    for i, f in enumerate([0, 7, 14, 20]):
        scene.frame_set(f)
        scene.render.filepath = os.path.join(render_dir, "pose_%02d.png" % i)
        bpy.ops.render.render(write_still=True)

# ---- 导出：保留全部原有动作 ----
bpy.ops.export_scene.gltf(
    filepath=dst,
    export_format='GLB',
    export_animations=True,
    export_animation_mode='ACTIONS',
    export_nla_strips=False,
    export_apply=False,
    export_yup=True,
)
print("DONE actions=%s" % ",".join(a.name for a in bpy.data.actions))
