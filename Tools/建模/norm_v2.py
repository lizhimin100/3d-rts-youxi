# -*- coding: utf-8 -*-
"""
norm_v2.py —— 归一化补丁（骑在 rts_kit 上，把"整体等比缩放"修成真的等比）
=====================================================================
为什么需要这个模块（每一条都是实测出来的，不是理论洁癖）：

rts_kit 原版 `fit_height` / `fit_box` 只对 `o.parent is None` 的网格做 `data.transform`。
但人形角色的**每一个网格都挂在关节空节点下**（这是《美术规范》§6.1 的层级要求）。
后果实测（步兵 1.78m）：
    · 空节点被缩 0.9602，网格尺寸没变 ⇒ 头 62mm / 肩 59mm / 髋 38mm 的骨架-网格错位；
    · 一转动就是"骨折"，因为网格不跟着关节的位置缩放。
而 `drop_to_ground` 只移网格不移空节点 ⇒ 同样的脱钩。

本模块的写法（把这套库的既有约定讲清楚，照着它做就只有一个正确答案）：
    · 网格：world = 单位矩阵，顶点就是世界坐标；basis = 父世界⁻¹，pinv = I
    · 空节点：.location = **父级相对**偏移（实测 Body 下 Torso 的 loc.z = waist−hip = 0.1021）
因此：
    1) 缩放 → 网格数据 × S；每个空节点的相对偏移 × S；然后**重新钉网格**（basis = 父世界⁻¹）。
       相对偏移同比缩放 ⇒ 每个关节的世界坐标整体同比缩放，Root 始终在原点。
    2) 平移 → 网格数据 + T；只动 Root 的 location（其余节点都是相对量）；再钉一次网格。
"""

from mathutils import Matrix, Vector


def _all_mesh():
    return [o for o in __import__("bpy").data.objects if o.type == "MESH"]


def sync_mesh_to_parents(bpy):
    """把每个网格重新钉成 world = I（顶点即世界坐标），父节点动完必须调一次。"""
    bpy.context.view_layer.update()
    for o in bpy.data.objects:
        if o.type != "MESH":
            continue
        o.matrix_parent_inverse = Matrix.Identity(4)
        o.matrix_basis = o.parent.matrix_world.inverted() if o.parent else Matrix.Identity(4)
    bpy.context.view_layer.update()


def scale_all(bpy, sx, sy, sz):
    M = Matrix.Diagonal(Vector((sx, sy, sz, 1.0)))
    for o in bpy.data.objects:
        if o.type == "MESH":
            o.data.transform(M)
    bpy.context.view_layer.update()
    for o in bpy.data.objects:
        if o.type == "EMPTY":
            o.location = Vector((o.location.x * sx, o.location.y * sy, o.location.z * sz))
    sync_mesh_to_parents(bpy)


def translate_all(bpy, dx, dy, dz):
    T = Matrix.Translation(Vector((dx, dy, dz)))
    for o in bpy.data.objects:
        if o.type == "MESH":
            o.data.transform(T)
    bpy.context.view_layer.update()
    root = bpy.data.objects.get("Root")
    if root is not None:
        root.location = Vector((root.location.x + dx, root.location.y + dy,
                               root.location.z + dz))
    sync_mesh_to_parents(bpy)


def apply(K):
    """把修好的三个函数装进 rts_kit（build 脚本里那几行调用一个字都不用改）。"""
    import bpy

    def fit_height(target, obs=None):
        objs = obs if obs is not None else _all_mesh()
        lo, hi = K.bbox(objs)
        cur = hi.z - lo.z
        if cur <= 1e-6:
            return 1.0
        s = target / cur
        if abs(s - 1.0) < 1e-4:
            return s
        scale_all(bpy, s, s, s)
        return s

    def fit_box(sx, sy, sz, obs=None):
        objs = obs if obs is not None else _all_mesh()
        lo, hi = K.bbox(objs)
        cur = Vector((hi.x - lo.x, hi.y - lo.y, hi.z - lo.z))
        s = Vector((sx / cur.x if cur.x > 1e-6 else 1.0,
                    sy / cur.y if cur.y > 1e-6 else 1.0,
                    sz / cur.z if cur.z > 1e-6 else 1.0))
        scale_all(bpy, s.x, s.y, s.z)
        lo2, hi2 = K.bbox(objs)
        translate_all(bpy, -(lo2.x + hi2.x) * 0.5, -(lo2.y + hi2.y) * 0.5, -lo2.z)
        return [round(v, 4) for v in s]

    def drop_to_ground(obs=None, keep_xy=True):
        objs = obs if obs is not None else _all_mesh()
        lo, hi = K.bbox(objs)
        if abs(lo.z) < 1e-6:
            return
        translate_all(bpy, 0, 0, -lo.z)

    K.fit_height = fit_height
    K.fit_box = fit_box
    K.drop_to_ground = drop_to_ground
    return True
