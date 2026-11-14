# -*- coding: utf-8 -*-
import bpy, json, math, os, struct

OUT = r"E:\自定义游戏\简易rts\工具\建模\v3\_anim_test.glb"

# 清场
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink=True)
for m in list(bpy.data.meshes):
    bpy.data.meshes.remove(m)
for a in list(bpy.data.actions):
    bpy.data.actions.remove(a)

# --- 骨架 ---
arm_data = bpy.data.armatures.new("Armature")
arm = bpy.data.objects.new("Armature", arm_data)
bpy.context.scene.collection.objects.link(arm)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='EDIT')
b_hips = arm_data.edit_bones.new("hips"); b_hips.head = (0,0,0.9); b_hips.tail = (0,0,1.2)
b_arm = arm_data.edit_bones.new("upperarm.L"); b_arm.head = (-0.2,0,1.4); b_arm.tail = (-0.5,0,1.4); b_arm.parent = b_hips
bpy.ops.object.mode_set(mode='OBJECT')

# --- 网格 ---
me = bpy.data.meshes.new("body")
verts = [(-0.2,-0.1,0.8),(0.2,-0.1,0.8),(0.2,0.1,1.5),(-0.2,0.1,1.5),(0.6,-0.1,1.4),(0.6,0.1,1.4)]
faces = [(0,1,2,3),(3,2,5,4)]
me.from_pydata(verts, [], faces); me.update()
ob = bpy.data.objects.new("body", me)
bpy.context.scene.collection.objects.link(ob)
vg = ob.vertex_groups.new(name="hips")
vg.add([0,1,2,3], 1.0, 'REPLACE')
vg2 = ob.vertex_groups.new(name="upperarm.L")
vg2.add([4,5], 1.0, 'REPLACE')
mod = ob.modifiers.new("Armature", 'ARMATURE'); mod.object = arm
ob.parent = arm

mat = bpy.data.materials.new("M_cloth_team")
mat.use_nodes = True
mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.1,0.3,0.7,1)
me.materials.append(mat)

# --- 动作 ---
def make_action(name, ang):
    arm.animation_data_create()
    act = bpy.data.actions.new(name)
    arm.animation_data.action = act
    bpy.context.scene.frame_set(1)
    pb = arm.pose.bones["upperarm.L"]
    pb.rotation_mode = 'XYZ'
    pb.rotation_euler = (0,0,0)
    pb.keyframe_insert("rotation_euler", frame=1)
    pb.rotation_euler = (0, ang, 0)
    pb.keyframe_insert("rotation_euler", frame=12)
    return act

a1 = make_action("idle", 0.3)
a2 = make_action("walk", -0.6)

# NLA 轨道
arm.animation_data.action = None
for act, trk in ((a1,"idle"),(a2,"walk")):
    t = arm.animation_data.nla_tracks.new()
    t.name = trk
    st = t.strips.new(trk, 1, act)
    t.mute = False

bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', export_apply=False,
                          export_animations=True, export_animation_mode='NLA_TRACKS',
                          export_yup=True, use_selection=False)

# --- 读回 GLB ---
with open(OUT, 'rb') as f:
    data = f.read()
assert data[:4] == b'glTF'
off = 12
js = None
while off < len(data):
    ln, ty = struct.unpack_from('<II', data, off)
    chunk = data[off+8: off+8+ln]
    if ty == 0x4E4F534A:
        js = json.loads(chunk.decode('utf-8'))
        break
    off += 8 + ln
res = {
    "animations": [a.get("name") for a in js.get("animations", [])],
    "materials": [(m.get("name"), m.get("pbrMetallicRoughness", {}).get("baseColorFactor")) for m in js.get("materials", [])],
    "nodes": [n.get("name") for n in js.get("nodes", [])],
    "skins": len(js.get("skins", [])),
    "meshes": [m.get("name") for m in js.get("meshes", [])],
}
print("HEADLESS " + json.dumps(res, ensure_ascii=False))
