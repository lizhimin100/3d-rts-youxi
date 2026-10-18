# -*- coding: utf-8 -*-
"""
kit3.py —— 铁血战歌 美术 v3 建模工具（Blender 5.1 / 全 headless 可跑）

为什么重写一套：v2 是「一堆独立物体 + Empty 假骨骼 + 程序动画」，导出后节点多、
动画靠引擎侧摆姿态、材质靠逐 surface 复制。v3 要的是**真骨骼 + 烘焙动画 + 参数化染色**：
  * 几何按「材质」聚合成极少量 Mesh（一个材质一个 Mesh，节点数少、draw call 少）；
  * 每个顶点直接带骨骼权重（构建时就分配，不做自动权重 —— headless 下确定性最好）；
  * 骨骼动画烘焙成多个 Action，经 NLA 轨道导出成 glTF 多段动画；
  * 材质命名 M_<zone>（含 _team 的是队伍色区），引擎侧 MatKit 按名字换成卡通着色器。

坐标约定（与 v2 一致，别改）：
  * x = 左右，y = 前后（**+Y 是正面**，导出 Godot 即 -Z 前向），z = 高；脚底 z = 0。

作者约定：
  * 所有几何函数都返回 bmesh 或直接写进 Builder；Part 的 weight 用 bone 名或 weight_fn(p)。
  * 构造顺序 = 无关；骨骼绑定在 build() 时统一做。
"""

import bpy
import bmesh
import math
import os
import json
import struct
from mathutils import Vector, Matrix, Euler, Quaternion

TAU = math.pi * 2.0
D = math.radians


# ===========================================================================
# 0. 材质（命名即协议：M_<zone>[_team]）
# ===========================================================================
# 联盟调色（sRGB）。zone 名是引擎侧调色板的键，改名要同步 代码/美术/调色板.gd。
PALETTE = {
    "stone":       ("#D9CFB2", 0.86, 0.0),
    "stone_dark":  ("#B4A98C", 0.90, 0.0),
    "stone_light": ("#E8DFC6", 0.82, 0.0),
    "plaster":     ("#E3D8BC", 0.90, 0.0),
    "roof":        ("#2A5CBF", 0.55, 0.05),
    "roof_dark":   ("#1B3E86", 0.60, 0.05),
    "gold":        ("#E2B34C", 0.34, 0.85),
    "gold_dark":   ("#A87B2A", 0.42, 0.80),
    "wood":        ("#7A5230", 0.78, 0.0),
    "wood_dark":   ("#553720", 0.82, 0.0),
    "steel":       ("#A8B0BA", 0.36, 0.82),
    "steel_dark":  ("#5E6773", 0.42, 0.75),
    "steel_light": ("#D2D8DF", 0.30, 0.85),
    "iron":        ("#6B655C", 0.60, 0.55),
    "leather":     ("#8A5B34", 0.80, 0.0),
    "leather_dark":("#573823", 0.84, 0.0),
    "cloth":       ("#2B5FB0", 0.88, 0.0),
    "cloth_dark":  ("#1C4079", 0.90, 0.0),
    "skin":        ("#D9A57C", 0.72, 0.0),
    "skin_dark":   ("#B37B55", 0.76, 0.0),
    "hair":        ("#6B4A2B", 0.88, 0.0),
    "crystal":     ("#7FD8FF", 0.10, 0.0),
    "ember":       ("#FF8A31", 0.40, 0.0),
    "glass":       ("#20304A", 0.20, 0.10),
    "bark":        ("#5B4127", 0.90, 0.0),
    "leaf":        ("#4E7C34", 0.88, 0.0),
    "leaf_dark":   ("#345828", 0.90, 0.0),
    "ore":         ("#E9C24A", 0.30, 0.70),
    "grass":       ("#6B8F3A", 0.92, 0.0),
    "water":       ("#2E6E8E", 0.10, 0.0),
    "dirt":        ("#7B6344", 0.95, 0.0),
    "hay":         ("#C9A94E", 0.92, 0.0),
    "rope":        ("#9C8455", 0.90, 0.0),
    "bone":        ("#D8D2BE", 0.70, 0.0),
}

# 队伍色区（材质名后缀 _team）
TEAM_ZONES = {"cloth", "roof", "banner"}

_MAT_CACHE = {}


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat(zone, team=False):
    """取/建材质。命名严格是 M_<zone> 或 M_<zone>_team —— 引擎按名字上色。"""
    name = "M_" + zone + ("_team" if team else "")
    if name in _MAT_CACHE:
        return _MAT_CACHE[name]
    base = PALETTE.get(zone, ("#B0B0B0", 0.8, 0.0))
    rgb = [srgb_to_linear(c) for c in hex2rgb(base[0])]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
    bsdf.inputs["Roughness"].default_value = base[1]
    bsdf.inputs["Metallic"].default_value = base[2]
    # 自发光：水晶/炉火/金色饰边给一点点，引擎侧还会调
    if zone == "crystal":
        bsdf.inputs["Emission Color"].default_value = (0.35, 0.85, 1.0, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 2.2
    elif zone == "ember":
        bsdf.inputs["Emission Color"].default_value = (1.0, 0.42, 0.10, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 2.6
    m.diffuse_color = (rgb[0], rgb[1], rgb[2], 1.0)
    _MAT_CACHE[name] = m
    return m


# ===========================================================================
# 1. 几何原语（全部返回 bmesh，世界坐标由调用方给 Matrix 变换）
# ===========================================================================

def _bm_cube(size, bevel=0.0, seg=1):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    if bevel > 0.0:
        bmesh.ops.bevel(bm, geom=list(bm.edges) + list(bm.verts), offset=bevel,
                        segments=seg, affect="EDGES", clamp_overlap=True)
    return bm


def _bm_cone(r1, r2, h, sides=8, smooth=False):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=sides,
                          radius1=r1, radius2=r2, depth=h)
    bmesh.ops.translate(bm, vec=Vector((0, 0, h * 0.5)), verts=bm.verts)
    if smooth:
        for f in bm.faces:
            f.smooth = True
    return bm


def _bm_ico(r, subdiv=1, smooth=False):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=r)
    if smooth:
        for f in bm.faces:
            f.smooth = True
    return bm


def _bm_uvsphere(r, u=12, v=8):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=u, v_segments=v, radius=r)
    return bm


def _bm_loft(rings, cap_a=True, cap_b=True):
    """rings: [[(x,y,z), ...], ...] 每环点数相同；按顺序连成管。"""
    bm = bmesh.new()
    vs = []
    for ring in rings:
        vs.append([bm.verts.new(p) for p in ring])
    bm.verts.ensure_lookup_table()
    n = len(rings[0])
    for i in range(len(rings) - 1):
        for j in range(n):
            a, b = vs[i][j], vs[i][(j + 1) % n]
            c, d = vs[i + 1][(j + 1) % n], vs[i + 1][j]
            try:
                bm.faces.new((a, b, c, d))
            except ValueError:
                pass
    if cap_a:
        try:
            bm.faces.new(list(reversed(vs[0])))
        except ValueError:
            pass
    if cap_b:
        try:
            bm.faces.new(vs[-1])
        except ValueError:
            pass
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    return bm


def _bm_extrude_poly(pts2d, depth):
    """2D 多边形沿 Z 挤出（用于盾牌/旗帜/徽记/锯齿轮廓）。pts2d 在 XY 平面。"""
    bm = bmesh.new()
    front = [bm.verts.new((x, y, depth * 0.5)) for (x, y) in pts2d]
    back = [bm.verts.new((x, y, -depth * 0.5)) for (x, y) in pts2d]
    bm.verts.ensure_lookup_table()
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    n = len(pts2d)
    for i in range(n):
        a, b = front[i], front[(i + 1) % n]
        c, d = back[(i + 1) % n], back[i]
        bm.faces.new((a, b, c, d))
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    return bm


def _bm_tube(pts, r, sides=6):
    """沿折线扫掠（法杖/绳索/铁环）。"""
    pts = [Vector(p) for p in pts]
    rings = []
    for i, p in enumerate(pts):
        if i == 0:
            d = (pts[1] - p)
        elif i == len(pts) - 1:
            d = (p - pts[i - 1])
        else:
            d = (pts[i + 1] - pts[i - 1])
        d.normalize()
        up = Vector((0, 0, 1)) if abs(d.z) < 0.95 else Vector((0, 1, 0))
        x = d.cross(up).normalized()
        y = x.cross(d).normalized()
        rr = r[i] if isinstance(r, (list, tuple)) else r
        rings.append([p + x * (math.cos(TAU * k / sides) * rr) + y * (math.sin(TAU * k / sides) * rr)
                      for k in range(sides)])
    return _bm_loft(rings, cap_a=True, cap_b=True)


def ring_pts(n, rx, ry=None, phase=0.0, cx=0.0, cy=0.0):
    ry = rx if ry is None else ry
    return [(cx + rx * math.cos(phase + TAU * i / n), cy + ry * math.sin(phase + TAU * i / n)) for i in range(n)]


def sq_ring(n, rx, ry=None, p=0.62, phase=0.0, cx=0.0, cy=0.0):
    """方圆混合环（p 越大越方）—— 盔甲/石柱的硬边轮廓。"""
    ry = rx if ry is None else ry
    out = []
    for i in range(n):
        a = phase + TAU * i / n
        c, s = math.cos(a), math.sin(a)
        k = 1.0 / (max(abs(c), abs(s)) ** p + 1e-9) ** (1.0 / p) if p > 0.001 else 1.0
        k = min(k, 1.42)
        out.append((cx + rx * c * k, cy + ry * s * k))
    return out


# ===========================================================================
# 2. 权重函数 & 网格累加器
# ===========================================================================

def w_rigid(bone):
    return lambda p: {bone: 1.0}


def w_z(stops):
    """按高度混合两根（或更多）骨：stops = [(z0, {bone:w}), (z1, {...}), ...]"""
    stops = sorted(stops, key=lambda s: s[0])

    def fn(p):
        z = p[2]
        if z <= stops[0][0]:
            return dict(stops[0][1])
        if z >= stops[-1][0]:
            return dict(stops[-1][1])
        for i in range(len(stops) - 1):
            z0, w0 = stops[i]
            z1, w1 = stops[i + 1]
            if z0 <= z <= z1:
                t = (z - z0) / max(z1 - z0, 1e-6)
                t = t * t * (3 - 2 * t)
                out = {}
                for k in set(list(w0) + list(w1)):
                    out[k] = w0.get(k, 0.0) * (1 - t) + w1.get(k, 0.0) * t
                return out
        return dict(stops[-1][1])
    return fn


class Builder(object):
    """按材质聚合几何。一次构建 -> 每材质一个 Mesh，顶点组直接带权重。"""

    def __init__(self, name):
        self.name = name
        self.parts = {}   # material_name -> [ (verts, faces, weights) ]

    def add(self, bm, material, weight=None, xform=None):
        if xform is not None:
            bmesh.ops.transform(bm, matrix=xform, verts=bm.verts)
        bm.verts.ensure_lookup_table()
        verts = [v.co.copy() for v in bm.verts]
        idx = {v: i for i, v in enumerate(bm.verts)}
        faces = [[idx[v] for v in f.verts] for f in bm.faces]
        wp = weight if weight is not None else (lambda p: {})
        ws = [wp(v) for v in verts]
        key = material.name
        self.parts.setdefault(key, []).append((verts, faces, ws))
        bm.free()

    # --- 便捷封装 -------------------------------------------------------
    def box(self, size, loc=(0, 0, 0), rot=(0, 0, 0), material=None, bevel=0.0,
            seg=1, weight=None, scale=None):
        bm = _bm_cube(size, bevel, seg)
        M = Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4()
        if scale is not None:
            M = M @ Matrix.Diagonal(Vector(scale).to_4d())
        self.add(bm, material, weight, M)

    def cyl(self, r1, r2, h, loc=(0, 0, 0), rot=(0, 0, 0), material=None, sides=8,
            weight=None, smooth=False, scale=None):
        bm = _bm_cone(r1, r2, h, sides, smooth)
        M = Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4()
        if scale is not None:
            M = M @ Matrix.Diagonal(Vector(scale).to_4d())
        self.add(bm, material, weight, M)

    def ico(self, r, loc=(0, 0, 0), material=None, subdiv=1, weight=None,
            scale=(1, 1, 1), smooth=False):
        bm = _bm_ico(r, subdiv, smooth)
        M = Matrix.Translation(Vector(loc)) @ Matrix.Diagonal(Vector(scale).to_4d())
        self.add(bm, material, weight, M)

    def loft(self, rings, material, weight=None, loc=(0, 0, 0), rot=(0, 0, 0),
             cap_a=True, cap_b=True, scale=None):
        bm = _bm_loft(rings, cap_a, cap_b)
        M = Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4()
        if scale is not None:
            M = M @ Matrix.Diagonal(Vector(scale).to_4d())
        self.add(bm, material, weight, M)

    def poly(self, pts2d, depth, material, loc=(0, 0, 0), rot=(0, 0, 0), weight=None):
        bm = _bm_extrude_poly(pts2d, depth)
        M = Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4()
        self.add(bm, material, weight, M)

    def tube(self, pts, r, material, weight=None, sides=6):
        bm = _bm_tube(pts, r, sides)
        self.add(bm, material, weight, None)

    # --- 出网格 ---------------------------------------------------------
    def build_meshes(self, collection):
        objs = []
        for mname, chunks in self.parts.items():
            verts, faces, weights = [], [], []
            off = 0
            for v, f, w in chunks:
                verts.extend(v)
                faces.extend([[i + off for i in fv] for fv in f])
                weights.extend(w)
                off += len(v)
            me = bpy.data.meshes.new(self.name + "_" + mname)
            me.from_pydata([tuple(v) for v in verts], [], faces)
            me.validate()
            me.update()
            material = bpy.data.materials.get(mname)
            if material is not None:
                me.materials.append(material)
            ob = bpy.data.objects.new(self.name + "_" + mname, me)
            collection.objects.link(ob)
            # 顶点组
            groups = {}
            for i, w in enumerate(weights):
                for bone, val in w.items():
                    if val <= 0.0005:
                        continue
                    groups.setdefault(bone, []).append((i, val))
            for bone, pairs in groups.items():
                g = ob.vertex_groups.new(name=bone)
                for i, val in pairs:
                    g.add([i], val, "REPLACE")
            objs.append(ob)
        return objs


# ===========================================================================
# 3. 人形骨架（真骨骼，名字与引擎侧约定一致）
# ===========================================================================

class HumanRig(object):
    """7.5 头身人形骨架。原点 = 脚底中心，+Y 为正前方。"""

    BONES = [
        # name,           head(比例/绝对),          tail,             parent
        ("root",          (0.0, 0.0, 0.0),          (0.0, 0.18, 0.0), None),
        ("hips",          (0.0, 0.0, 0.535),        (0.0, 0.0, 0.62), "root"),
        ("spine",         (0.0, 0.0, 0.62),         (0.0, 0.0, 0.70), "hips"),
        ("chest",         (0.0, 0.0, 0.70),         (0.0, 0.0, 0.812), "spine"),
        ("neck",          (0.0, 0.0, 0.812),        (0.0, 0.0, 0.862), "chest"),
        ("head",          (0.0, 0.0, 0.862),        (0.0, 0.0, 0.985), "neck"),
    ]

    def __init__(self, name, H=1.78, head_div=7.5, shoulder_k=2.05, splay_deg=8.0):
        self.name = name
        self.H = H
        self.head_h = H / head_div
        self.head_w = self.head_h * 0.79
        self.head_d = self.head_w * 1.04
        self.sh_w = self.head_w * shoulder_k
        self.sh_x = self.sh_w * 0.5
        self.head_top = H * 0.985
        self.chin = self.head_top - self.head_h
        self.neck_z = self.chin + self.head_h * 0.10
        self.sh_z = 0.818 * H
        self.chest_z = 0.705 * H
        self.waist_z = 0.598 * H
        self.hip_z = 0.535 * H
        self.knee_z = 0.285 * H
        self.ankle_z = 0.019 * H
        self.hip_x = 0.0505 * H
        self.ua = 0.175 * H
        self.fa = 0.145 * H
        self.splay = D(splay_deg)
        self.elbow_z = self.sh_z - self.ua * math.cos(self.splay)
        self.wrist_z = self.elbow_z - self.fa * math.cos(self.splay)
        self.elbow_x = self.sh_x + math.sin(self.splay) * self.ua
        self.wrist_x = self.elbow_x + math.sin(self.splay) * self.fa
        self.arm = None
        self.mesh_objs = []

    def bone_list(self):
        out = list(self.BONES)
        sh, el, wr = self.sh_x, self.elbow_x, self.wrist_x
        for s, sx in (("L", -1.0), ("R", 1.0)):
            out += [
                ("shoulder." + s, (sx * self.head_w * 0.16, 0, self.sh_z),
                 (sx * sh, 0, self.sh_z), "chest"),
                ("upperarm." + s, (sx * sh, 0, self.sh_z),
                 (sx * el, 0, self.elbow_z), "shoulder." + s),
                ("forearm." + s, (sx * el, 0, self.elbow_z),
                 (sx * wr, 0, self.wrist_z), "upperarm." + s),
                ("hand." + s, (sx * wr, 0, self.wrist_z),
                 (sx * (wr + 0.02), 0, self.wrist_z - 0.09), "forearm." + s),
                ("thigh." + s, (sx * self.hip_x, 0, self.hip_z),
                 (sx * self.hip_x * 0.98, 0, self.knee_z), "hips"),
                ("shin." + s, (sx * self.hip_x * 0.98, 0, self.knee_z),
                 (sx * self.hip_x * 0.96, 0, self.ankle_z), "thigh." + s),
                ("foot." + s, (sx * self.hip_x * 0.96, 0, self.ankle_z),
                 (sx * self.hip_x * 0.96, 0.13, self.ankle_z * 0.55), "shin." + s),
                ("toe." + s, (sx * self.hip_x * 0.96, 0.13, self.ankle_z * 0.55),
                 (sx * self.hip_x * 0.96, 0.21, self.ankle_z * 0.45), "foot." + s),
            ]
        # 披风（三段）与裙摆（前后）—— 布料的"活气"全靠它们
        out += [
            ("cape.01", (0, -0.10, self.sh_z), (0, -0.13, self.sh_z - 0.28), "chest"),
            ("cape.02", (0, -0.13, self.sh_z - 0.28), (0, -0.16, self.sh_z - 0.56), "cape.01"),
            ("cape.03", (0, -0.16, self.sh_z - 0.56), (0, -0.19, self.sh_z - 0.84), "cape.02"),
            ("skirt.F", (0, 0.06, self.waist_z - 0.02), (0, 0.10, self.hip_z - 0.34), "hips"),
            ("skirt.B", (0, -0.06, self.waist_z - 0.02), (0, -0.11, self.hip_z - 0.34), "hips"),
        ]
        return out

    def build(self, collection):
        arm_data = bpy.data.armatures.new(self.name + "_Armature")
        arm = bpy.data.objects.new("Armature", arm_data)
        collection.objects.link(arm)
        bpy.context.view_layer.objects.active = arm
        bpy.ops.object.mode_set(mode="EDIT")
        eb = arm_data.edit_bones
        for name, h, t, parent in self.bone_list():
            b = eb.new(name)
            b.head = Vector(h)
            b.tail = Vector(t)
            if parent:
                b.parent = eb[parent]
                b.use_connect = False
        bpy.ops.object.mode_set(mode="OBJECT")
        for pb in arm.pose.bones:
            pb.rotation_mode = "QUATERNION"
        self.arm = arm
        arm.show_in_front = True
        return arm

    def bind(self, objs):
        for ob in objs:
            ob.parent = self.arm
            ob.matrix_parent_inverse = self.arm.matrix_world.inverted()
            md = ob.modifiers.new("Armature", "ARMATURE")
            md.object = self.arm
        self.mesh_objs = objs

    # --- 姿态 ------------------------------------------------------------
    def _upd(self):
        bpy.context.view_layer.update()

    def rest_dir(self, bone):
        b = self.arm.data.bones[bone]
        return (b.tail_local - b.head_local).normalized()

    def aim(self, bone, direction, ref=(0, 0, 1)):
        """把骨头指向 direction（armature 空间的向量）。父骨已摆好时是链式生效的。"""
        pb = self.arm.pose.bones.get(bone)
        if pb is None:
            return
        d = Vector(direction).normalized()
        r = Vector(ref)
        if abs(d.dot(r)) > 0.985:
            r = Vector((0, 1, 0)) if abs(d.dot(Vector((0, 1, 0)))) < 0.985 else Vector((1, 0, 0))
        x = r.cross(d).normalized()
        z = x.cross(d).normalized()
        M = Matrix((x, d, z)).transposed().to_4x4()
        M.translation = pb.head
        pb.matrix = M
        self._upd()

    def rot(self, bone, rx=0.0, ry=0.0, rz=0.0):
        """局部欧拉叠加（在 aim 之后做细节微调）。"""
        pb = self.arm.pose.bones.get(bone)
        if pb is None:
            return
        e = Euler((D(rx), D(ry), D(rz)), "XYZ")
        pb.rotation_quaternion = pb.rotation_quaternion @ e.to_quaternion()
        self._upd()

    def reset(self):
        for pb in self.arm.pose.bones:
            pb.rotation_quaternion = Quaternion((1, 0, 0, 0))
            pb.location = Vector((0, 0, 0))
        self._upd()

    # --- 动画 ------------------------------------------------------------
    def new_action(self, name):
        if self.arm.animation_data is None:
            self.arm.animation_data_create()
        act = bpy.data.actions.new(name)
        act.use_fake_user = True
        self.arm.animation_data.action = act
        return act

    def key(self, frame, bones=None):
        bones = bones or [b[0] for b in self.bone_list()]
        for b in bones:
            pb = self.arm.pose.bones.get(b)
            if pb is None:
                continue
            pb.keyframe_insert("rotation_quaternion", frame=frame)
            pb.keyframe_insert("location", frame=frame)

    def finish_action(self, act, start=1, end=30, interp="BEZIER"):
        for fc in act.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = interp
        act.frame_range  # 触发重算
        return act

    def push_nla(self, act):
        ad = self.arm.animation_data
        ad.action = None
        t = ad.nla_tracks.new()
        t.name = act.name
        s = t.strips.new(act.name, int(act.frame_range[0]), act)
        s.name = act.name
        t.mute = False
        return t


# ===========================================================================
# 4. 场景 / 导出 / 预览
# ===========================================================================

def reset_scene():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)
    for blk in (bpy.data.meshes, bpy.data.armatures, bpy.data.actions):
        for x in list(blk):
            blk.remove(x)
    _MAT_CACHE.clear()
    sc = bpy.context.scene
    coll = bpy.data.collections.new("COL_asset")
    sc.collection.children.link(coll)
    sc.render.fps = 30
    return coll


def export_glb(path, report=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=False,
        export_apply=False, export_yup=True,
        export_animations=True, export_animation_mode="NLA_TRACKS",
        export_bake_animation=False, export_optimize_animation_size=False,
        export_normals=True, export_tangents=False, export_materials="EXPORT",
        export_skins=True, export_def_bones=False,
    )
    return glb_info(path)


def glb_info(path):
    with open(path, "rb") as f:
        data = f.read()
    off = 12
    js = None
    while off < len(data):
        ln, ty = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + ln]
        if ty == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
            break
        off += 8 + ln
    tris = 0
    for m in js.get("meshes", []):
        for p in m.get("primitives", []):
            acc = js["accessors"][p["indices"]] if "indices" in p else None
            if acc:
                tris += acc["count"] // 3
    return {
        "file": os.path.basename(path),
        "kb": round(len(data) / 1024.0, 1),
        "tris": tris,
        "animations": [a.get("name") for a in js.get("animations", [])],
        "materials": [m.get("name") for m in js.get("materials", [])],
        "nodes": len(js.get("nodes", [])),
        "skins": len(js.get("skins", [])),
        "joints": len(js["skins"][0]["joints"]) if js.get("skins") else 0,
    }


def bbox(objs):
    mn = Vector((1e9, 1e9, 1e9))
    mx = Vector((-1e9, -1e9, -1e9))
    for ob in objs:
        for v in ob.bound_box:
            p = ob.matrix_world @ Vector(v)
            mn = Vector((min(mn[i], p[i]) for i in range(3)))
            mx = Vector((max(mx[i], p[i]) for i in range(3)))
    return mn, mx


def setup_light_and_cam(target_center, radius, res=(720, 900), cam_dir=(0.62, -1.0, 0.42)):
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.film_transparent = False
    sc.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in [
        e.bl_idname for e in bpy.types.RenderEngine.__subclasses__()] else "BLENDER_EEVEE"
    try:
        sc.eevee.taa_render_samples = 32
    except Exception:
        pass
    # 相机
    cam_data = bpy.data.cameras.new("QCCam")
    cam_data.lens = 62.0
    cam = bpy.data.objects.new("QCCam", cam_data)
    sc.collection.objects.link(cam)
    d = Vector(cam_dir).normalized()
    cam.location = Vector(target_center) + d * (radius * 3.0)
    direction = Vector(target_center) - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    sc.camera = cam
    # 光
    sun = bpy.data.lights.new("Key", "SUN")
    sun.energy = 3.4
    sun.angle = D(12)
    so = bpy.data.objects.new("Key", sun)
    so.rotation_euler = Euler((D(58), 0, D(38)), "XYZ")
    sc.collection.objects.link(so)
    fill = bpy.data.lights.new("Fill", "SUN")
    fill.energy = 1.1
    fill.color = (0.72, 0.82, 1.0)
    fo = bpy.data.objects.new("Fill", fill)
    fo.rotation_euler = Euler((D(66), 0, D(-125)), "XYZ")
    sc.collection.objects.link(fo)
    world = bpy.data.worlds.get("World") or bpy.data.worlds.new("World")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.86, 0.85, 0.80, 1.0)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    sc.world = world
    # 地面
    bm = _bm_cube((radius * 8, radius * 8, 0.02))
    M = Matrix.Translation(Vector((target_center[0], target_center[1], -0.01)))
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    me = bpy.data.meshes.new("QCGround")
    bm.to_mesh(me)
    bm.free()
    g = bpy.data.objects.new("QCGround", me)
    gm = bpy.data.materials.new("M_QCGround")
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.42, 0.42, 0.38, 1)
    me.materials.append(gm)
    sc.collection.objects.link(g)
    return cam, [so, fo, g]


def render_views(name, outdir, center, radius, views=None, res=(720, 900)):
    views = views or {"正": (0.0, -1.0, 0.12), "三": (0.75, -1.0, 0.28),
                      "四": (-0.75, -1.0, 0.28), "背": (0.0, 1.0, 0.12),
                      "高": (0.55, -1.0, 0.75)}
    os.makedirs(outdir, exist_ok=True)
    sc = bpy.context.scene
    outs = []
    for key, d in views.items():
        cam, helpers = setup_light_and_cam(center, radius, res, d)
        path = os.path.join(outdir, name + "_" + key + ".png")
        sc.render.filepath = path
        bpy.ops.render.render(write_still=True)
        outs.append(path)
        for h in helpers + [cam]:
            bpy.data.objects.remove(h, do_unlink=True)
    return outs
