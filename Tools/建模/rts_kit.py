# -*- coding: utf-8 -*-
"""
rts_kit.py —— 铁血战歌「铁砧 ANVIL」程序化低模资产工具库
------------------------------------------------------------------
设计约束（来自《作战条令》）：
  * 1 世界单位 = 1 米；上方向 +Z（Blender）；模型正面朝 **Blender +Y**（= Godot -Z）。
  * 原点 = 脚底 / 建筑地面（最低点贴 z=0）。
  * 全部**平面着色**（flat shading），硬朗块面感。
  * 禁止"方块摞方块"：任何体块都要有倒角 / 收分 / 斜切 / 板缝 / 铆钉 / 褶皱中的若干项。

本库只提供"可复用的形体语法"，不含任何具体模型的设计数值（那些在各 build_*.py 里）。
所有几何一律 **烘焙到世界坐标**（对象变换保持单位矩阵），
这样父子关系只有一种正确写法：child.matrix_parent_inverse = parent.matrix_world.inverted()，
空物体（关节）旋转时网格就绕关节原点转，正是程序动画需要的枢轴语义。
"""

import bpy
import bmesh
import math
import os
import json
import random
from mathutils import Vector, Matrix, Euler

TAU = math.pi * 2.0
OUT_ROOT = r"D:\blender\.workbuddy\rts_out"

# =============================================================================
# 0. 世界观配色（暖调土黄 / 赭石  +  冷调钢蓝  +  高饱和点缀）
#    一条统一色带：美术总监口径。别在模型脚本里另造颜色，全部引用这里。
# =============================================================================
PALETTE = {
    # —— 皮肤 / 毛发 ——（暖肉色，比布料亮，靠明度分离）
    "皮肤":    ("#D8A078", 0.70, 0.00, 0.0),
    "皮肤暗":  ("#B07A54", 0.74, 0.00, 0.0),
    "须发":    ("#4A382A", 0.84, 0.00, 0.0),
    "阴影":    ("#16110D", 0.90, 0.00, 0.0),
    # —— 布料 ——（米白麻布 / 中棕 / 深棕，三档明度拉满）
    "布麻":    ("#D9CBA8", 0.88, 0.00, 0.0),
    "布麻暗":  ("#8A6B45", 0.90, 0.00, 0.0),
    "布蓝":    ("#3F5C7A", 0.86, 0.00, 0.0),
    "布红":    ("#8E3A32", 0.86, 0.00, 0.0),
    "布白":    ("#E8E2D2", 0.90, 0.00, 0.0),
    # —— 皮革 ——（明显深于任何布料，是"色块分隔带"）
    "革":      ("#5A3B22", 0.78, 0.00, 0.0),
    "革暗":    ("#3E2716", 0.80, 0.00, 0.0),
    # —— 金属 ——（冷调钢蓝，与暖色系对立）
    "甲":      ("#96A4B4", 0.34, 0.55, 0.0),
    "钢":      ("#B4BEC8", 0.30, 0.55, 0.0),
    "钢暗":    ("#626C7C", 0.42, 0.50, 0.0),
    "钢亮":    ("#DCE4EE", 0.22, 0.60, 0.0),
    "铁":      ("#4C5058", 0.52, 0.45, 0.0),
    "金":      ("#D8B254", 0.30, 0.55, 0.0),
    "金脉":    ("#F2C84C", 0.26, 0.50, 0.0),
    # —— 木 / 石 / 土 ——
    "木":      ("#8A6440", 0.84, 0.00, 0.0),
    "木暗":    ("#4E3520", 0.86, 0.00, 0.0),
    "木浅":    ("#B08A5E", 0.82, 0.00, 0.0),
    "石":      ("#9A968C", 0.90, 0.00, 0.0),
    "石暗":    ("#6C6A62", 0.92, 0.00, 0.0),
    "石浅":    ("#B8B4A8", 0.88, 0.00, 0.0),
    "瓦":      ("#7A5442", 0.88, 0.00, 0.0),
    "茅草":    ("#D8BC72", 0.92, 0.00, 0.0),
    "土":      ("#9A7A50", 0.94, 0.00, 0.0),
    # —— 植物 ——（去饱和，贴土调，避免玩具箱绿）
    "叶":      ("#5A7A44", 0.90, 0.00, 0.0),
    "叶暗":    ("#3A5230", 0.92, 0.00, 0.0),
    "叶黄":    ("#8A8C46", 0.90, 0.00, 0.0),
    "草":      ("#6E8248", 0.94, 0.00, 0.0),
    # —— 旗帜 ——
    "旗红":    ("#A2302E", 0.86, 0.00, 0.0),
    "旗蓝":    ("#2F4E70", 0.86, 0.00, 0.0),
    # —— 自发光 ——
    "火":      ("#FF8A3C", 0.50, 0.00, 6.0),
    "火暗":    ("#C24A10", 0.40, 0.00, 2.0),
    "魔法":    ("#6FD4FF", 0.40, 0.00, 7.0),
    "魔法暗":  ("#2E6E9E", 0.55, 0.00, 1.5),
}
MATS = {}


def hex2rgb(h, alpha=1.0):
    h = h.lstrip("#")
    return (int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0, int(h[4:6], 16) / 255.0, alpha)


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _lin(col):
    return tuple(srgb_to_linear(c) for c in col[:3]) + (col[3],)


# =============================================================================
# 1. 场景 / 材质
# =============================================================================
def reset_scene():
    """清空场景（不用 read_factory_settings，避免把启动器的 EEVEE-RT 配置冲掉）。"""
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for blk in (bpy.data.meshes, bpy.data.materials, bpy.data.lights, bpy.data.cameras):
        for d in list(blk):
            blk.remove(d)
    MATS.clear()
    sc = bpy.context.scene
    try:
        sc.render.engine = "BLENDER_EEVEE"
    except Exception:
        pass
    sc.unit_settings.system = "METRIC"
    sc.unit_settings.length_unit = "METERS"
    return sc


def mat(key, color=None, rough=None, metal=None, emit_strength=None):
    """取世界观材质。key 走 PALETTE；也可用 (color, rough, metal) 现造。带缓存。"""
    if key in MATS:
        return MATS[key]
    if key in PALETTE:
        hx, ro, me, em = PALETTE[key][0], PALETTE[key][1], PALETTE[key][2], PALETTE[key][3]
    else:
        hx, ro, me, em = "#8C8C8C", 0.9, 0.0, 0.0
    if color is not None:
        hx = color
    if rough is not None:
        ro = rough
    if metal is not None:
        me = metal
    if emit_strength is not None:
        em = emit_strength
    m = bpy.data.materials.new(key)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = None
    for n in nt.nodes:
        if n.type == "BSDF_PRINCIPLED":
            bsdf = n
            break
    c = _lin(hex2rgb(hx))
    bsdf.inputs["Base Color"].default_value = c
    bsdf.inputs["Roughness"].default_value = ro
    bsdf.inputs["Metallic"].default_value = me
    if em > 0.0:
        for nm in ("Emission Color", "Emission"):
            if nm in bsdf.inputs:
                bsdf.inputs[nm].default_value = c
                break
        bsdf.inputs["Emission Strength"].default_value = em
    m.diffuse_color = c
    MATS[key] = m
    return m


# =============================================================================
# 2. 几何原语（全部烘焙世界坐标 + 平面着色）
# =============================================================================
def _finish(name, bm, material, loc, rot, scale, bevel_fn=None):
    if bevel_fn:
        bevel_fn(bm)
    M = Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4() @ \
        Matrix.Diagonal(Vector(scale).to_4d())
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    for p in me.polygons:
        p.use_smooth = False
    if material is not None:
        me.materials.append(material)
    return ob


def _bevel(bm, offset, seg=1, angle=None):
    if offset <= 0:
        return
    edges = list(bm.edges)
    if angle is not None:
        edges = [e for e in edges if e.is_manifold and e.calc_face_angle(0.0) > angle]
    if not edges:
        return
    try:
        bmesh.ops.bevel(bm, geom=edges, offset=offset, offset_type="OFFSET",
                        segments=seg, profile=0.5, affect="EDGES", clamp_overlap=True,
                        miter_outer="SHARP", miter_inner="SHARP")
    except Exception:
        try:
            bmesh.ops.bevel(bm, geom=edges, offset=offset, offset_type="OFFSET",
                            segments=seg, profile=0.5, affect="EDGES", clamp_overlap=True)
        except Exception:
            pass


def box(name, size, loc=(0, 0, 0), rot=(0, 0, 0), m=None, bevel=0.0, seg=1,
        top=1.0, bottom=1.0, top_off=(0.0, 0.0), shear=(0.0, 0.0)):
    """带倒角的盒体。top/bottom 做收分（棱台），top_off 做斜切，shear 让竖轴倾斜。
    —— "倒角 + 收分 + 斜切" 是摆脱方块摞方块的最小语法。"""
    sx, sy, sz = size
    hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    bm = bmesh.new()
    quad = ((-1, -1), (1, -1), (1, 1), (-1, 1))
    lv, uv = [], []
    for (x, y) in quad:
        lv.append(bm.verts.new((x * hx * bottom, y * hy * bottom, -hz)))
    for (x, y) in quad:
        uv.append(bm.verts.new((x * hx * top + top_off[0], y * hy * top + top_off[1], hz + x * shear[0] + y * shear[1])))
    bm.faces.new(list(reversed(lv)))
    bm.faces.new(uv)
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((lv[i], lv[j], uv[j], uv[i]))
    bm.normal_update()
    ob = _finish(name, bm, m, loc, rot, (1, 1, 1), lambda b: _bevel(b, bevel, seg))
    return ob


def loft(name, rings, m=None, loc=(0, 0, 0), rot=(0, 0, 0), cap_a=True, cap_b=True,
         bevel=0.0, seg=1, smooth_caps=False, close_loop=False):
    """环形放样：rings = [(h, [(x,y), ...]), ...]，环上点数必须一致。
    这是四肢 / 躯干 / 塔身 / 树干的主力工具——沿轴逐环改半径就能做出收分与鼓包。"""
    bm = bmesh.new()
    vs = []
    for (h, pts) in rings:
        vs.append([bm.verts.new((p[0], p[1], h)) for p in pts])
    n = len(vs[0])
    for i in range(len(vs) - 1):
        a, b = vs[i], vs[i + 1]
        for k in range(n):
            k2 = (k + 1) % n
            try:
                bm.faces.new((a[k], a[k2], b[k2], b[k]))
            except ValueError:
                pass
    if close_loop:
        a, b = vs[-1], vs[0]
        for k in range(n):
            k2 = (k + 1) % n
            try:
                bm.faces.new((a[k], a[k2], b[k2], b[k]))
            except ValueError:
                pass
    if cap_a and not close_loop:
        try:
            bm.faces.new(list(reversed(vs[0])))
        except ValueError:
            pass
    if cap_b and not close_loop:
        try:
            bm.faces.new(vs[-1])
        except ValueError:
            pass
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _finish(name, bm, m, loc, rot, (1, 1, 1), lambda b: _bevel(b, bevel, seg))


def ring_pts(n, rx, ry=None, phase=0.0, cx=0.0, cy=0.0):
    ry = rx if ry is None else ry
    return [(cx + rx * math.cos(phase + TAU * i / n), cy + ry * math.sin(phase + TAU * i / n))
            for i in range(n)]


def sq_ring(n, rx, ry=None, p=0.62, phase=0.0, cx=0.0, cy=0.0):
    """超椭圆环（p<1 更方）。装甲肢体 / 塔身用这个，比圆环"硬"得多。"""
    ry = rx if ry is None else ry
    out = []
    for i in range(n):
        a = phase + TAU * i / n
        c, s = math.cos(a), math.sin(a)
        out.append((cx + rx * math.copysign(abs(c) ** p, c),
                    cy + ry * math.copysign(abs(s) ** p, s)))
    return out


def prism(name, pts, depth, m=None, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0, seg=1,
          taper=1.0, off=(0.0, 0.0)):
    """2D 多边形沿 Z 挤出（可 taper 收尖）——屋顶山墙 / 剑身 / 旗面 / 楔形构件。"""
    bm = bmesh.new()
    lo = [bm.verts.new((p[0], p[1], -depth * 0.5)) for p in pts]
    hi = [bm.verts.new((p[0] * taper + off[0], p[1] * taper + off[1], depth * 0.5)) for p in pts]
    try:
        bm.faces.new(list(reversed(lo)))
        bm.faces.new(hi)
    except ValueError:
        pass
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        try:
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
        except ValueError:
            pass
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _finish(name, bm, m, loc, rot, (1, 1, 1), lambda b: _bevel(b, bevel, seg))


def ico(name, r, subdiv=1, m=None, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1),
        jitter=0.0, seed=0):
    """二十面体细分球。程序化岩石 / 树冠 / 关节球。jitter 打乱顶点做出不规则棱角。"""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=r)
    if jitter > 0.0:
        rng = random.Random(seed)
        for v in bm.verts:
            v.co *= 1.0 + rng.uniform(-jitter, jitter)
    ob = _finish(name, bm, m, loc, rot, scale)
    return ob


def cyl(name, r1, r2, h, sides=8, m=None, loc=(0, 0, 0), rot=(0, 0, 0), phase=None,
        bevel=0.0, cap=True, squarish=0.0):
    """锥台。squarish>0 → 超椭圆截面（更"硬"）。"""
    if phase is None:
        phase = math.pi / sides
    p = 1.0 - 0.42 * squarish
    if squarish > 0.0:
        a = sq_ring(sides, r1, r1, p, phase)
        b = sq_ring(sides, r2, r2, p, phase)
    else:
        a = ring_pts(sides, r1, r1, phase)
        b = ring_pts(sides, r2, r2, phase)
    return loft(name, [(0.0, a), (h, b)], m, loc=loc, rot=rot, cap_a=cap, cap_b=cap,
                bevel=bevel)


def dome(name, poly, depth, m=None, loc=(0, 0, 0), rot=(0, 0, 0), steps=3,
         bulge=1.0):
    """把 2D 多边形做成凸面（盾面 / 穹顶 / 宝石座 / 浮雕）。
    逐环向质心收缩并抬起，最后一环收成单点 → 真正的凸壳，不是"平板 + 盖子"。"""
    cxm = sum(p[0] for p in poly) / len(poly)
    cym = sum(p[1] for p in poly) / len(poly)
    bm = bmesh.new()
    prev = [bm.verts.new((p[0], p[1], 0.0)) for p in poly]
    for i in range(1, steps + 1):
        t = i / float(steps)
        k = 1.0 - t
        z = depth * (t ** 0.72) * bulge
        if i == steps:
            apex = bm.verts.new((cxm, cym, z))
            for j in range(len(prev)):
                bm.faces.new((prev[j], prev[(j + 1) % len(prev)], apex))
            break
        cur = [bm.verts.new((cxm + (p[0] - cxm) * k, cym + (p[1] - cym) * k, z)) for p in poly]
        for j in range(len(prev)):
            j2 = (j + 1) % len(prev)
            bm.faces.new((prev[j], prev[j2], cur[j2], cur[j]))
        prev = cur
    try:
        bm.faces.new(list(reversed([v for v in bm.verts if abs(v.co.z) < 1e-9])))
    except Exception:
        pass
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _finish(name, bm, m, loc, rot, (1, 1, 1))


def stud(name, pos, r=0.018, h=0.014, m=None, sides=5, normal=(0, 0, 1)):
    """铆钉 / 钉头：小锥台。沿法线方向立在表面（板缝与铆钉带的关键小件）。"""
    rot = Vector((0, 0, 1)).rotation_difference(Vector(normal).normalized()).to_euler()
    return cyl(name, r, r * 0.62, h, sides, m=m, loc=(pos[0], pos[1], pos[2]),
               rot=(rot.x, rot.y, rot.z), phase=0.0)


def stud_band(prefix, start, end, count, r=0.018, h=0.012, m=None, normal=(0, 0, 1), sides=5):
    """沿直线排一排铆钉带（板缝两侧的那种）。"""
    a, b = Vector(start), Vector(end)
    out = []
    for i in range(count):
        t = (i + 0.5) / count
        p = a.lerp(b, t)
        out.append(stud("%s_%02d" % (prefix, i), p, r, h, m, sides, normal))
    return out


def arc_wall(name, arc_deg, r, thick, z0, z1, segs=8, m=None, taper=1.0, loc=(0, 0, 0),
             phase=0.0, cap=True):
    """弧形墙段（塔身 / 城墙 / 拱券）：内外两条弧 + 上下封口。
    比实心圆柱省面，还天然带壁厚与收分。"""
    bm = bmesh.new()
    a0 = math.radians(-arc_deg * 0.5) + phase
    a1 = math.radians(arc_deg * 0.5) + phase
    ri, ro = r - thick * 0.5, r + thick * 0.5
    rs_i_top, rs_o_top = ri * taper, ro * taper
    V = {}
    for i in range(segs + 1):
        t = i / segs
        a = a0 + (a1 - a0) * t
        c, s = math.cos(a), math.sin(a)
        V[(i, 0, 0)] = bm.verts.new((ri * c, ri * s, z0))
        V[(i, 1, 0)] = bm.verts.new((ro * c, ro * s, z0))
        V[(i, 0, 1)] = bm.verts.new((rs_i_top * c, rs_i_top * s, z1))
        V[(i, 1, 1)] = bm.verts.new((rs_o_top * c, rs_o_top * s, z1))
    for i in range(segs):
        bm.faces.new((V[(i, 1, 0)], V[(i + 1, 1, 0)], V[(i + 1, 1, 1)], V[(i, 1, 1)]))
        bm.faces.new((V[(i, 0, 0)], V[(i, 0, 1)], V[(i + 1, 0, 1)], V[(i + 1, 0, 0)]))
        bm.faces.new((V[(i, 0, 1)], V[(i, 1, 1)], V[(i + 1, 1, 1)], V[(i + 1, 0, 1)]))
        bm.faces.new((V[(i, 0, 0)], V[(i + 1, 0, 0)], V[(i + 1, 1, 0)], V[(i, 1, 0)]))
    if cap:
        bm.faces.new((V[(0, 0, 0)], V[(0, 1, 0)], V[(0, 1, 1)], V[(0, 0, 1)]))
        bm.faces.new((V[(segs, 0, 0)], V[(segs, 0, 1)], V[(segs, 1, 1)], V[(segs, 1, 0)]))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _finish(name, bm, m, loc, (0.0, 0.0, 0.0), (1, 1, 1), None)


def grid_surface(name, nx, ny, w, h, fn, m=None, loc=(0, 0, 0), rot=(0, 0, 0), thick=0.0):
    """参数化网格面（旗帜波浪 / 布料褶皱 / 田垄）。fn(u,v) -> (x,y,z)。"""
    bm = bmesh.new()
    V = []
    for j in range(ny + 1):
        row = []
        for i in range(nx + 1):
            u, v = i / nx, j / ny
            x, y, z = fn(u, v)
            row.append(bm.verts.new((x, y, z)))
        V.append(row)
    for j in range(ny):
        for i in range(nx):
            bm.faces.new((V[j][i], V[j][i + 1], V[j + 1][i + 1], V[j + 1][i]))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = _finish(name, bm, m, loc, rot, (1, 1, 1))
    return ob


# =============================================================================
# 3. 层级 / 变换
# =============================================================================
def empty(name, loc=(0, 0, 0), rot=(0, 0, 0), size=0.12):
    ob = bpy.data.objects.new(name, None)
    ob.empty_display_type = "PLAIN_AXES"
    ob.empty_display_size = size
    ob.location = loc
    ob.rotation_euler = rot
    bpy.context.scene.collection.objects.link(ob)
    return ob


def parent_to(child, parent):
    """保持世界变换的父子绑定。几何已烘焙世界坐标 ⇒ 局部变换 = 父世界逆。"""
    bpy.context.view_layer.update()
    mw = child.matrix_world.copy()
    child.parent = parent
    child.matrix_parent_inverse = Matrix.Identity(4)
    child.matrix_basis = parent.matrix_world.inverted() @ mw
    bpy.context.view_layer.update()


def parent_all(children, parent):
    for c in children:
        parent_to(c, parent)


def mirror_x(ob, name=None):
    """沿 X 镜像复制（右手件→左手件）。翻转面绕向以保持法线朝外。"""
    me = ob.data.copy()
    nme = bpy.data.meshes.new(name or (ob.name + "_M"))
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.transform(bm, matrix=Matrix.Diagonal(Vector((-1, 1, 1, 1))), verts=bm.verts)
    bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.to_mesh(nme)
    bm.free()
    nme.materials.clear()
    for m in me.materials:
        nme.materials.append(m)
    for p in nme.polygons:
        p.use_smooth = False
    bpy.data.meshes.remove(me)
    nob = bpy.data.objects.new(name or (ob.name + "_M"), nme)
    bpy.context.scene.collection.objects.link(nob)
    return nob


def join(objs, name):
    """把多个网格合成一个对象（导出后节点更清爽，也省 draw call）。"""
    objs = [o for o in objs if o is not None]
    if not objs:
        return None
    if len(objs) == 1:
        objs[0].name = name
        return objs[0]
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    return ob


def tri_count(obs=None):
    obs = obs if obs is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    n = 0
    for o in obs:
        for p in o.data.polygons:
            n += max(0, len(p.vertices) - 2)
    return n


def bbox(obs=None):
    obs = obs if obs is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in obs:
        for v in o.data.vertices:
            p = o.matrix_world @ v.co
            for i in range(3):
                lo[i] = min(lo[i], p[i])
                hi[i] = max(hi[i], p[i])
    return lo, hi


def size_of(obs=None):
    lo, hi = bbox(obs)
    return (hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)


def drop_to_ground(obs=None, keep_xy=True):
    """把最低点压到 z=0（条令：原点 = 脚底 / 地面）。"""
    obs = obs if obs is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    lo, hi = bbox(obs)
    for o in obs:
        o.location.z -= lo.z
    bpy.context.view_layer.update()


def fit_height(target, obs=None):
    """整体等比缩放到目标高度（脚底仍贴 z=0）。
    用于把形体做对之后**精确对齐**条令给的身高/建筑尺寸——不靠反复凑数字。"""
    obs = obs if obs is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    lo, hi = bbox(obs)
    cur = hi.z - lo.z
    if cur <= 1e-6:
        return 1.0
    s = target / cur
    if abs(s - 1.0) < 1e-4:
        return s
    for o in bpy.data.objects:
        if o.type == "MESH" and o.parent is None:
            o.data.transform(Matrix.Scale(s, 4))
        elif o.type == "EMPTY":
            o.location = Vector(o.location) * s
    bpy.context.view_layer.update()
    return s


def fit_box(sx, sy, sz, obs=None):
    """按**三轴分别**缩放到指定包围盒尺寸，再把 XY 居中、最低点压回 z=0。
    建筑用：条令 §1 给的是 8×8×9 这种硬尺寸（X/Y 是占地格数，差一格就穿模），
    而形体的自然比例常常差 3%~8%，非等比缩那点量肉眼看不出来，但格子对得上。
    返回实际三轴缩放系数 —— 报告里要看，超过 1.12 说明形体该重做而不是硬拉。
    """
    obs = obs if obs is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    lo, hi = bbox(obs)
    cur = Vector((hi.x - lo.x, hi.y - lo.y, hi.z - lo.z))
    s = Vector((sx / cur.x if cur.x > 1e-6 else 1.0,
               sy / cur.y if cur.y > 1e-6 else 1.0,
               sz / cur.z if cur.z > 1e-6 else 1.0))
    M = Matrix.Diagonal(s.to_4d())
    for o in bpy.data.objects:
        if o.type == "MESH" and o.parent is None:
            o.data.transform(M)
        elif o.type == "EMPTY":
            o.location = Vector((o.location.x * s.x, o.location.y * s.y, o.location.z * s.z))
    bpy.context.view_layer.update()
    lo2, hi2 = bbox(obs)
    dx, dy, dz = -(lo2.x + hi2.x) * 0.5, -(lo2.y + hi2.y) * 0.5, -lo2.z
    T = Matrix.Translation(Vector((dx, dy, dz)))
    for o in bpy.data.objects:
        if o.type == "MESH" and o.parent is None:
            o.data.transform(T)
        elif o.type == "EMPTY":
            o.location = Vector((o.location.x + dx, o.location.y + dy, o.location.z + dz))
    bpy.context.view_layer.update()
    return [round(v, 4) for v in s]


def recenter_bottom(obs=None):
    obs = obs if obs is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    lo, hi = bbox(obs)
    cx, cy = (lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5
    for o in obs:
        o.location.x -= cx
        o.location.y -= cy
        o.location.z -= lo.z
    bpy.context.view_layer.update()


# =============================================================================
# 4. 预览渲染（三点光 + 投影取景；渲染装置渲染完即删，不污染导出）
# =============================================================================
def _look_at(cam, target):
    d = (Vector(cam.location) - Vector(target))
    cam.rotation_euler = d.to_track_quat("Z", "Y").to_euler()


def fit_camera(cam, target, direction, radius, lens=52.0, sensor=36.0, res=(960, 960), margin=1.16):
    """按包围球解相机距离（比 AABB 估距可靠：任何视角都不会切边）。"""
    d = Vector(direction).normalized()
    tan_h = (sensor * 0.5) / lens
    tan_v = tan_h * (res[1] / float(res[0]))
    half = min(tan_h, tan_v)
    dist = radius / math.sin(math.atan(half)) * margin
    cam.location = Vector(target) + d * dist
    _look_at(cam, target)
    return dist


def setup_render_rig(target, radius, res=(960, 960), samples=48, amb=0.10):
    """三點光 + 冷色环境。返回 (cam, lights, ground)，用完必须 delete_rig()。"""
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = "PNG"
    try:
        sc.eevee.taa_render_samples = samples
    except Exception:
        pass
    try:
        sc.view_settings.view_transform = "AgX"
        sc.view_settings.look = "AgX - Punchy"
    except Exception:
        try:
            sc.view_settings.view_transform = "Filmic"
        except Exception:
            pass

    # 世界：冷灰蓝，不抢主体的明度
    w = bpy.data.worlds.get("预览世界") or bpy.data.worlds.new("预览世界")
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.10, 0.115, 0.145, 1.0)
    bg.inputs[1].default_value = 1.0
    sc.world = w

    cam_data = bpy.data.cameras.new("预览相机")
    cam_data.lens = 52.0
    cam_data.sensor_width = 36.0
    cam = bpy.data.objects.new("预览相机", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam

    def sun(nm, travel, energy, color, angle=0.16):
        ld = bpy.data.lights.new(nm, "SUN")
        ld.energy = energy
        ld.color = color
        ld.angle = angle
        ob = bpy.data.objects.new(nm, ld)
        ob.rotation_euler = Vector(travel).normalized().to_track_quat("-Z", "Y").to_euler()
        sc.collection.objects.link(ob)
        return ob

    lights = [
        sun("主光", (-0.52, -0.62, -0.72), 3.4, (1.0, 0.93, 0.82), 0.13),
        sun("补光", (0.72, -0.30, -0.55), 1.15, (0.60, 0.72, 1.0), 0.5),
        sun("轮廓光", (0.10, 0.95, -0.30), 2.6, (0.85, 0.92, 1.0), 0.3),
        sun("底部反光", (0.0, -0.1, 1.0), 0.45, (0.62, 0.66, 0.78), 0.9),
    ]

    # 地面：让脚/地基是否贴地一眼可见
    gm = mat("__ground", "#2A2E36", 0.95, 0.0)
    bpy.ops.mesh.primitive_plane_add(size=max(6.0, radius * 6.0), location=(0, 0, -0.001))
    ground = bpy.context.object
    ground.name = "预览地面"
    ground.data.materials.append(gm)
    return cam, lights, ground


def delete_rig(cam, lights, ground):
    for ob in [cam, ground] + list(lights):
        if ob is not None:
            bpy.data.objects.remove(ob, do_unlink=True)
    bpy.context.scene.camera = None


VIEWS = {
    "正":  (0.0, 1.0, 0.055),                 # 角色正面（Blender +Y = Godot -Z）
    "三四": (0.80, 0.72, 0.34),               # 3/4 前右
    "侧":  (1.0, 0.04, 0.10),
    "背":  (0.0, -1.0, 0.16),
    "俯":  (0.10, 0.55, 1.0),
}


def render_views(name, outdir, views=("正", "三四"), res=(960, 960), samples=48,
                 target=None, radius=None, lens=52.0, margin=1.16, extra=None):
    """出图到 staging。views 见 VIEWS；extra = [(tag, dir, lens)] 自定义机位。"""
    os.makedirs(outdir, exist_ok=True)
    obs = [o for o in bpy.data.objects if o.type == "MESH"]
    lo, hi = bbox(obs)
    if target is None:
        target = ((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, (lo.z + hi.z) * 0.5)
    if radius is None:
        d = hi - lo
        radius = max(d.length * 0.5, 0.001)
    cam, lights, ground = setup_render_rig(target, radius, res=res, samples=samples)
    cam.data.lens = lens
    outs = []
    todo = [(v, VIEWS[v], lens) for v in views] + list(extra or [])
    for item in todo:
        tag, direction, ln = item[0], item[1], item[2]
        cam.data.lens = ln
        fit_camera(cam, target, direction, radius, lens=ln, res=res, margin=margin)
        p = os.path.join(outdir, "%s_%s.png" % (name, tag))
        bpy.context.scene.render.filepath = p
        bpy.context.scene.render.film_transparent = False
        bpy.ops.render.render(write_still=True)
        outs.append(p)
    delete_rig(cam, lights, ground)
    return outs, target, radius


# =============================================================================
# 5. 导出
# =============================================================================
def cut_faces(ob, pred):
    """按面心谓词删面（做兜帽开口、挖窗洞、破壳）。pred(Vector) -> True 则删。"""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    doomed = [f for f in bm.faces if pred(f.calc_center_median())]
    if doomed:
        bmesh.ops.delete(bm, geom=doomed, context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    for p in ob.data.polygons:
        p.use_smooth = False
    return ob


def sweep(name, secs, m=None, pivot=(0, 0, 0), direction=(0, 0, -1), prof=None,
          sides=8, cap_a=True, cap_b=True, roll=0.0):
    """沿任意轴扫掠**自定义截面**（剑身血槽 / 弓臂 / 异形梁）。
    secs = [(距离, 半宽, 半厚)]；prof(w, t) -> [(x, y), ...] 截面轮廓。"""
    rings = []
    for s in secs:
        d, w, t = s[0], s[1], s[2]
        pts = prof(w, t) if prof else ring_pts(sides, w, t)
        if abs(roll) > 1e-9:
            cr, sr = math.cos(roll), math.sin(roll)
            pts = [(px * cr - py * sr, px * sr + py * cr) for (px, py) in pts]
        rings.append((-d, pts))
    ob = loft(name, rings, m, cap_a=cap_a, cap_b=cap_b)
    M = Matrix.Translation(Vector(pivot)) @ Vector((0, 0, -1)).rotation_difference(
        Vector(direction).normalized()).to_matrix().to_4x4()
    ob.data.transform(M)
    return ob


def tube_along(name, pts, r, m=None, sides=6, closed=False):
    """沿折线扫圆管（绳 / 缠带 / 弓弦 / 铁链）。截面永远垂直于路径，
    不会像扁带那样在拐弯处翻面、也不会在锥面上突然断成一截截。"""
    P = [Vector(p) for p in pts]
    if closed:
        P.append(P[0])
    bm = bmesh.new()
    rings = []
    up = Vector((0, 0, 1))
    prev_side = None
    for i in range(len(P)):
        if i == 0:
            t = P[1] - P[0]
        elif i == len(P) - 1:
            t = P[-1] - P[-2]
        else:
            t = P[i + 1] - P[i - 1]
        t.normalize()
        ref = up if abs(t.dot(up)) < 0.94 else Vector((1, 0, 0))
        side = t.cross(ref)
        if side.length < 1e-6:
            side = Vector((1, 0, 0))
        side.normalize()
        if prev_side is not None and side.dot(prev_side) < 0:
            side = -side
        prev_side = side
        nrm = side.cross(t).normalized()
        rings.append([bm.verts.new(P[i] + side * (r * math.cos(TAU * k / sides))
                                   + nrm * (r * math.sin(TAU * k / sides)))
                      for k in range(sides)])
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(sides):
            k2 = (k + 1) % sides
            try:
                bm.faces.new((a[k], a[k2], b[k2], b[k]))
            except ValueError:
                pass
    if not closed:
        try:
            bm.faces.new(list(reversed(rings[0])))
            bm.faces.new(rings[-1])
        except ValueError:
            pass
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _finish(name, bm, m, (0, 0, 0), (0, 0, 0), (1, 1, 1))


def solidify(ob, thickness, bevel=0.0, offset=0.0):
    """给开放曲面加厚度（旗面 / 斗篷 / 穹顶板）——单面片在游戏里会漏光。"""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.solidify(bm, geom=list(bm.faces), thickness=-abs(thickness))
    if bevel > 0:
        _bevel(bm, bevel, 1)
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(ob.data)
    bm.free()
    for p in ob.data.polygons:
        p.use_smooth = False
    return ob


def fold_ring(n, rx, ry, amp=0.03, phase=0.0, p=0.62, ridges=6):
    """带竖向褶皱的截面环（布裙 / 长袍）。靠轮廓起伏出布料感，不是贴图假褶。"""
    pts = sq_ring(n, rx, ry, p, phase)
    out = []
    for i, (x, y) in enumerate(pts):
        f = 1.0 + amp * math.cos(ridges * TAU * i / n)
        out.append((x * f, y * f))
    return out


def limb(name, secs, m=None, pivot=(0, 0, 0), direction=(0, 0, -1), sides=8, squarish=0.55,
         cap_a=True, cap_b=True, bevel=0.0, seg=1, phase=None, roll=0.0):
    """关节肢体：沿 direction 从 pivot 向外逐环放样。
    secs = [(距离, 半径rx, 半径ry), ...]（给两元素则 rx=ry）。
    —— 枢轴就在关节上，这是程序动画"不骨折"的前提。"""
    if phase is None:
        phase = math.pi / sides
    d = Vector(direction).normalized()
    q = Vector((0, 0, -1)).rotation_difference(d)
    rings = []
    for s in secs:
        dist, rx = s[0], s[1]
        ry = s[2] if len(s) > 2 else s[1]
        if squarish > 0.0:
            pts = sq_ring(sides, rx, ry, 1.0 - 0.42 * squarish, phase)
        else:
            pts = ring_pts(sides, rx, ry, phase)
        rings.append((-dist, pts))
    ob = loft(name, rings, m, cap_a=cap_a, cap_b=cap_b, bevel=bevel, seg=seg)
    M = Matrix.Translation(Vector(pivot)) @ q.to_matrix().to_4x4() @ \
        Euler((0, 0, roll), "XYZ").to_matrix().to_4x4()
    ob.data.transform(M)
    return ob


def strap(name, pts, width, thick, m, closed=False, bevel=0.006, up=(0, 0, 1)):
    """皮带 / 包边 / 绑腿：沿折线扫出扁截面（自带厚度与倒角，不是贴片）。"""
    bm = bmesh.new()
    P = [Vector(p) for p in pts]
    if closed:
        P.append(P[0])
    rings = []
    n = len(P)
    for i in range(n):
        if i == 0:
            t = (P[1] - P[0])
        elif i == n - 1:
            t = (P[-1] - P[-2])
        else:
            t = (P[i + 1] - P[i - 1])
        t.normalize()
        side = t.cross(Vector(up))
        if side.length < 1e-6:
            side = Vector((1, 0, 0))
        side.normalize()
        nrm = side.cross(t).normalized()
        c = P[i]
        quad = [c + side * (width * 0.5) + nrm * (thick * 0.5),
                c - side * (width * 0.5) + nrm * (thick * 0.5),
                c - side * (width * 0.5) - nrm * (thick * 0.5),
                c + side * (width * 0.5) - nrm * (thick * 0.5)]
        rings.append([bm.verts.new(p) for p in quad])
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(4):
            k2 = (k + 1) % 4
            try:
                bm.faces.new((a[k], a[k2], b[k2], b[k]))
            except ValueError:
                pass
    if not closed:
        try:
            bm.faces.new(list(reversed(rings[0])))
            bm.faces.new(rings[-1])
        except ValueError:
            pass
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _finish(name, bm, m, (0, 0, 0), (0, 0, 0), (1, 1, 1),
                   (lambda b: _bevel(b, bevel, 1)) if bevel > 0 else None)


# =============================================================================
# 4.5 批量小块合并（石墙 / 瓦片 / 铆钉阵列）
# =============================================================================
def _bh(hx, hy, hz, bottom=1.0, top=1.0, top_off=(0.0, 0.0), shear=(0.0, 0.0)):
    """立一个棱台盒的 bmesh（不做 bevel，交给调用方）。"""
    bm = bmesh.new()
    quad = ((-1, -1), (1, -1), (1, 1), (-1, 1))
    lv = [bm.verts.new((x * hx * bottom, y * hy * bottom, -hz)) for (x, y) in quad]
    uv = [bm.verts.new((x * hx * top + top_off[0], y * hy * top + top_off[1],
                        hz + x * shear[0] + y * shear[1])) for (x, y) in quad]
    bm.faces.new(list(reversed(lv)))
    bm.faces.new(uv)
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((lv[i], lv[j], uv[j], uv[i]))
    bm.normal_update()
    return bm


class Batch(object):
    """把几百个小块合进**一个**网格（石砌墙面 / 瓦垄 / 铆钉阵列）。
    每块单独建 bmesh 再合并：既保住每块的倒角，又只产生一个对象 / 一个 draw call。"""

    def __init__(self, name, m=None):
        self.bm = bmesh.new()
        self.name = name
        self.m = m
        self.count = 0

    def _merge(self, bm):
        me = bpy.data.meshes.new("_b")
        bm.to_mesh(me)
        bm.free()
        self.bm.from_mesh(me)
        bpy.data.meshes.remove(me)
        self.count += 1

    def _xform(self, bm, loc, rot):
        M = Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4()
        bmesh.ops.transform(bm, matrix=M, verts=bm.verts)

    def box(self, size, loc=(0, 0, 0), rot=(0, 0, 0), bevel=0.0,
            top=1.0, bottom=1.0, top_off=(0.0, 0.0), shear=(0.0, 0.0)):
        b = _bh(size[0] * 0.5, size[1] * 0.5, size[2] * 0.5, bottom, top, top_off, shear)
        if bevel > 0:
            _bevel(b, bevel, 1)
        self._xform(b, loc, rot)
        self._merge(b)

    def cyl(self, r1, r2, h, sides=8, loc=(0, 0, 0), rot=(0, 0, 0), squarish=0.0,
            bevel=0.0):
        ph = math.pi / sides
        if squarish > 0.0:
            a = sq_ring(sides, r1, r1, 1.0 - 0.42 * squarish, ph)
            b = sq_ring(sides, r2, r2, 1.0 - 0.42 * squarish, ph)
        else:
            a = ring_pts(sides, r1, r1, ph)
            b = ring_pts(sides, r2, r2, ph)
        bm = bmesh.new()
        lo = [bm.verts.new((p[0], p[1], 0.0)) for p in a]
        hi = [bm.verts.new((p[0], p[1], h)) for p in b]
        n = sides
        for k in range(n):
            k2 = (k + 1) % n
            bm.faces.new((lo[k], lo[k2], hi[k2], hi[k]))
        bm.faces.new(list(reversed(lo)))
        bm.faces.new(hi)
        bm.normal_update()
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        if bevel > 0:
            _bevel(bm, bevel, 1)
        self._xform(bm, loc, rot)
        self._merge(bm)

    def prism(self, pts, depth, loc=(0, 0, 0), rot=(0, 0, 0), taper=1.0):
        bm = bmesh.new()
        lo = [bm.verts.new((p[0], p[1], -depth * 0.5)) for p in pts]
        hi = [bm.verts.new((p[0] * taper, p[1] * taper, depth * 0.5)) for p in pts]
        bm.faces.new(list(reversed(lo)))
        bm.faces.new(hi)
        n = len(pts)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
        bm.normal_update()
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        self._xform(bm, loc, rot)
        self._merge(bm)

    def ico(self, r, loc=(0, 0, 0), scale=(1, 1, 1), subdiv=0, jitter=0.0, seed=0):
        bm = bmesh.new()
        bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=r)
        if jitter > 0.0:
            rng = random.Random(seed)
            for v in bm.verts:
                v.co *= 1.0 + rng.uniform(-jitter, jitter)
        bmesh.ops.transform(bm, matrix=Matrix.Diagonal(Vector(scale).to_4d()),
                            verts=bm.verts)
        self._xform(bm, loc, (0, 0, 0))
        self._merge(bm)

    def obj(self):
        ob = _finish(self.name, self.bm, self.m, (0, 0, 0), (0, 0, 0), (1, 1, 1))
        return ob


# ---------------------------------------------------------------------------
# 面数预算收敛系数（《美术规范》§4：建筑 4000~20000 三角面）
# 只动"装饰密度"，不动形体：石砌行数、瓦垄行数与列距。
# 实测基线（未收敛）：大本营 34648 tris（其中砌石墙 24024）、兵营 26924（其中屋瓦 16456）。
# ---------------------------------------------------------------------------
LOD_STONE_ROWS = 0.52    # 砌石行数系数（三角数 ≈ 平方倍下降）
LOD_TILE_ROWS = 0.50     # 瓦垄行数系数（步高按 1/该值补偿，屋面总升程不变）
LOD_TILE_COL = 0.55      # 瓦片列距（米）：越大瓦越宽、列数越少


def stone_courses(batch, x0, x1, z0, z1, y, rows=6, m=None, thick=0.10, jitter=0.0,
                  bevel=0.012, rng_seed=1):
    """砌石墙面：逐行错缝的块石（自带深度起伏与倒角）。
    这是"石基/塔身/城墙"摆脱一张平板贴图的关键语法。

    面数收敛（《美术规范》§4）：三角数 ∝ rows²（cols = span/(dz·1.35) 随 dz 自适应），
    把 rows 收到 LOD_STONE_ROWS 倍 ⇒ 三角数约降到平方倍。块面随之变大：
    这既是省面数，也是 §1.1 要的"大块面、雕塑感"。
    """
    rng = random.Random(rng_seed)
    rows = max(2, int(round(rows * LOD_STONE_ROWS)))
    dz = (z1 - z0) / rows
    span = x1 - x0
    for r in range(rows):
        cols = max(2, int(span / (dz * 1.35)))
        w = span / cols
        off = (0.5 * w) if (r % 2) else 0.0
        for c in range(cols + 1):
            cx = x0 + off + c * w
            if cx > x1 - w * 0.15:
                continue
            ww = w * (0.94 if c % 2 else 0.99)
            cx2 = min(cx, x1 - ww * 0.5)
            if cx2 < x0 + ww * 0.5:
                continue
            depth = thick * (1.0 + rng.uniform(-jitter, jitter))
            batch.box((ww * 0.96, depth, dz * 0.88),
                      loc=(cx2, y, z0 + dz * (r + 0.5)),
                      bevel=bevel, top=1.0 - rng.uniform(0.0, 0.04))


def tile_rows(batch, w, run, z0, x_center, y_center, rows=6, m=None, rng_seed=3,
              slope=0.34):
    """屋面瓦垄：一行行错位的瓦片（每片轻微凸起），比一整块斜板真实。

    面数收敛（《美术规范》§4）：瓦片数 ∝ rows × cols。rows 减半、列距放大（LOD_TILE_COL），
    同时把每级步高 step 按 1/rows 反向补偿 —— 屋面**总升程不变**
    （不补偿的话屋顶会变矮，那是改形体，不是省面数）。瓦片本身随之变厚，读作"粗瓦"，
    在 RTS 距离下比密排小瓦更清楚。
    """
    rng = random.Random(rng_seed)
    rows = max(2, int(round(rows * LOD_TILE_ROWS)))
    step = slope / max(1e-6, LOD_TILE_ROWS)
    for r in range(rows):
        z = z0 + r * step
        off = 0.5 if r % 2 else 0.0
        n = max(3, int(w / LOD_TILE_COL))
        for c in range(n + 1):
            x = x_center + (-w * 0.5 + (c + off) * (w / max(1, n)))
            if abs(x - x_center) > w * 0.52:
                continue
            batch.box((w / n * 0.92, run, step * 1.25),
                      loc=(x, y_center + rng.uniform(-0.01, 0.01), z),
                      rot=(math.radians(-24), 0, 0),
                      bevel=0.006, top=0.94)


def export_glb(path, report_extra=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # 清掉预览/临时对象留下的孤儿材质
    props = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    kwargs = dict(
        filepath=path,
        export_format="GLB",
        export_apply=True,
        export_yup=True,
        use_selection=False,
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        export_normals=True,
        export_tangents=False,
        export_materials="EXPORT",
        export_texcoords=True,
        export_animations=False,
        export_skins=False,
        export_morph=False,
        export_attributes=False,
        export_image_format="NONE",
        export_vertex_color="NONE",
    )
    kwargs = {k: v for k, v in kwargs.items() if k in props or k == "filepath"}
    bpy.ops.export_scene.gltf(**kwargs)
    obs = [o for o in bpy.data.objects if o.type == "MESH"]
    lo, hi = bbox(obs)
    rep = {
        "glb": path,
        "bytes": os.path.getsize(path) if os.path.exists(path) else -1,
        "tris": tri_count(obs),
        "meshes": len(obs),
        "nodes": len([o for o in bpy.data.objects]),
        "size": [round(hi.x - lo.x, 3), round(hi.y - lo.y, 3), round(hi.z - lo.z, 3)],
        "min": [round(lo.x, 3), round(lo.y, 3), round(lo.z, 3)],
        "max": [round(hi.x, 3), round(hi.y, 3), round(hi.z, 3)],
    }
    if report_extra:
        rep.update(report_extra)
    with open(os.path.join(os.path.dirname(path), "report_%s.json" % os.path.splitext(os.path.basename(path))[0]),
              "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    return rep


def headless_report(rep):
    print("HEADLESS " + json.dumps(rep, ensure_ascii=False))
