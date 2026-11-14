# -*- coding: utf-8 -*-
"""
buildings.py —— 联盟五建筑 v3（城镇/兵营/铁匠铺/哨塔/农场）
参考：单位/三视图/联盟/建筑/*.png

设计口径（和 units.py 一致）：
  * 真骨骼（root + 旗帜骨链），静态部分全部权重到 root，旗帜权重到 flag.* —— 这样
    引擎侧用同一个 AnimationPlayer 就能让旗子飘，不需要额外特效节点。
  * 屋面/旗帜/塔顶篷用 team 材质（M_roof_team / M_banner_team），敌方基地会自动换色。
  * 石砌细节用"错缝砌块"几何，而不是贴图：远景一眼能看出是石墙。
"""

import bpy, math, os, sys
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3
from kit3 import mat, Builder, D, TAU, w_rigid, ring_pts, sq_ring

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型"
QC_DIR = r"E:\自定义游戏\简易rts\工具\建模\v3\qc"


# ===========================================================================
# 建筑骨架：root + 旗骨链
# ===========================================================================

class BuildingRig(object):
    def __init__(self, name, flags=1):
        self.name = name
        self.flag_specs = []      # [(x, y, z_base, z_top, side)]
        self.arm = None
        self.flags = flags

    def add_flag(self, x, y, z0, z1, dirx=0.0, diry=1.0):
        self.flag_specs.append((x, y, z0, z1, dirx, diry))

    def build(self, coll):
        arm_data = bpy.data.armatures.new(self.name + "_Armature")
        arm = bpy.data.objects.new("Armature", arm_data)
        coll.objects.link(arm)
        bpy.context.view_layer.objects.active = arm
        bpy.ops.object.mode_set(mode="EDIT")
        eb = arm_data.edit_bones
        root = eb.new("root")
        root.head = (0, 0, 0)
        root.tail = (0, 0, 1.0)
        for i, (x, y, z0, z1, dx, dy) in enumerate(self.flag_specs):
            # 3 节旗骨，从旗杆顶往旗面外伸
            n = Vector((dx, dy, 0.0))
            if n.length < 1e-4:
                n = Vector((1, 0, 0))
            n.normalize()
            seg = (z1 - z0) * 0.0 + 0.42
            prev = root
            for k in range(3):
                b = eb.new("flag.%d.%d" % (i + 1, k + 1))
                p0 = Vector((x, y, z1)) + n * (seg * k)
                b.head = p0
                b.tail = p0 + n * seg
                b.parent = prev
                prev = b
        bpy.ops.object.mode_set(mode="OBJECT")
        for pb in arm.pose.bones:
            pb.rotation_mode = "QUATERNION"
        self.arm = arm
        return arm

    def bind(self, objs):
        for ob in objs:
            ob.parent = self.arm
            ob.matrix_parent_inverse = self.arm.matrix_world.inverted()
            md = ob.modifiers.new("Armature", "ARMATURE")
            md.object = self.arm

    def _upd(self):
        bpy.context.view_layer.update()

    def rest_pose(self):
        ad = self.arm.animation_data
        if ad is not None:
            ad.action = None
            for t in ad.nla_tracks:
                t.mute = True
        for pb in self.arm.pose.bones:
            from mathutils import Quaternion
            pb.rotation_quaternion = Quaternion((1, 0, 0, 0))
        bpy.context.scene.frame_set(1)
        self._upd()

    def preview_action(self, name, frame=1):
        act = bpy.data.actions.get(name)
        if act is None:
            self.rest_pose()
            return
        ad = self.arm.animation_data or self.arm.animation_data_create()
        for t in ad.nla_tracks:
            t.mute = True
        ad.action = act
        try:
            for layer in act.layers:
                for strip in layer.strips:
                    for slot in act.slots:
                        if strip.channelbag(slot) is not None:
                            ad.action_slot = slot
                            break
        except Exception:
            pass
        bpy.context.scene.frame_set(frame)
        self._upd()

    def wave_action(self, name="idle", frames=61):
        """旗帜飘动：三节旗骨绕 Z 轴错相位摆动。"""
        if self.arm.animation_data is None:
            self.arm.animation_data_create()
        act = bpy.data.actions.new(name)
        act.use_fake_user = True
        self.arm.animation_data.action = act
        bones = [b.name for b in self.arm.pose.bones if b.name.startswith("flag.")]
        for f in range(1, frames + 1, 10):
            ph = (f - 1) / float(frames) * TAU
            for b in bones:
                pb = self.arm.pose.bones.get(b)
                if pb is None:
                    continue
                k = int(b.split(".")[-1])
                amp = D(7.0 + 4.0 * k)
                pb.rotation_quaternion = Euler((0, 0, amp * math.sin(ph - 0.9 * k)), "XYZ").to_quaternion()
                pb.keyframe_insert("rotation_quaternion", frame=f)
        self.arm.animation_data.action = None
        t = self.arm.animation_data.nla_tracks.new()
        t.name = name
        t.strips.new(name, 1, act)
        return act

    def resume_nla(self):
        ad = self.arm.animation_data
        if ad is not None:
            for t in ad.nla_tracks:
                t.mute = False


# ===========================================================================
# 构件
# ===========================================================================

W_ROOT = w_rigid("root")


def box(b, size, loc, material, rot=(0, 0, 0), bevel=0.0, weight=None):
    b.box(size, loc=loc, rot=rot, material=material, bevel=bevel,
          weight=weight or W_ROOT)


def stone_wall(b, cx, cy, w, d, z0, z1, m, m_dark=None, rows=None, thick=0.35):
    """四面石墙外壳（中空，留出内部空间）。"""
    h = z1 - z0
    box(b, (w, thick, h), (cx, cy - d * 0.5 + thick * 0.5, (z0 + z1) * 0.5), m)
    box(b, (w, thick, h), (cx, cy + d * 0.5 - thick * 0.5, (z0 + z1) * 0.5), m)
    box(b, (thick, d - thick * 2, h), (cx - w * 0.5 + thick * 0.5, cy, (z0 + z1) * 0.5), m)
    box(b, (thick, d - thick * 2, h), (cx + w * 0.5 - thick * 0.5, cy, (z0 + z1) * 0.5), m)
    # 错缝砌块（只贴外侧，做"石"的读感）
    if m_dark is not None and rows:
        rh = h / rows
        for r in range(rows):
            zz = z0 + rh * (r + 0.5)
            off = 0.0 if r % 2 == 0 else 0.28
            n = max(2, int(w / 0.62))
            for i in range(n):
                xx = -w * 0.5 + off + (i + 0.5) * (w / n)
                if abs(xx) > w * 0.5 - 0.12:
                    continue
                box(b, (w / n * 0.86, 0.045, rh * 0.68),
                    (cx + xx, cy + d * 0.5 - 0.012, zz), m, bevel=0.012)
                box(b, (w / n * 0.86, 0.045, rh * 0.68),
                    (cx + xx, cy - d * 0.5 + 0.012, zz), m, bevel=0.012)
            for sy in (-1, 1):
                n2 = max(2, int(d / 0.62))
                for i in range(n2):
                    yy = -d * 0.5 + off + (i + 0.5) * (d / n2)
                    if abs(yy) > d * 0.5 - 0.12:
                        continue
                    box(b, (0.045, d / n2 * 0.86, rh * 0.68),
                        (cx + sy * (w * 0.5 - 0.012), cy + yy, zz), m, bevel=0.012)


def crenel_ring(b, cx, cy, r, z, count, m, h=0.42, thick=0.30):
    """圆形雉堞（塔顶）。"""
    for i in range(count):
        a = TAU * i / count
        box(b, (thick, 0.34, h), (cx + r * math.cos(a), cy + r * math.sin(a), z + h * 0.5),
            m, rot=(0, 0, a), bevel=0.02)


def crenel_line(b, cx, cy, w, d, z, m, step=0.62, h=0.40, thick=0.30, axis="x"):
    n = max(2, int((w if axis == "x" else d) / step))
    for i in range(n):
        if axis == "x":
            xx = cx - w * 0.5 + (i + 0.5) * (w / n)
            box(b, (w / n * 0.55, thick, h), (xx, cy, z + h * 0.5), m, bevel=0.015)
        else:
            yy = cy - d * 0.5 + (i + 0.5) * (d / n)
            box(b, (thick, d / n * 0.55, h), (cx, yy, z + h * 0.5), m, bevel=0.015)


def gable_roof(b, cx, cy, w, d, z0, rise, m_roof, m_trim, over=0.42, ridge=True):
    """双坡屋顶：沿 X 方向起脊，两个斜面 + 山墙 + 屋脊金线。"""
    W, Dd = w * 0.5 + over, d * 0.5 + over
    zr = z0 + rise
    # 两个斜面（各一条放样带，带厚度）
    for sy in (-1, 1):
        b.add(K3._bm_loft([
            [(cx - W, cy + sy * Dd, z0), (cx - W, cy + sy * Dd - sy * 0.16, z0 - 0.02),
             (cx - W, cy + sy * Dd - sy * 0.16, z0 + 0.16), (cx - W, cy + sy * Dd, z0 + 0.18)],
            [(cx + W, cy + sy * Dd, z0), (cx + W, cy + sy * Dd - sy * 0.16, z0 - 0.02),
             (cx + W, cy + sy * Dd - sy * 0.16, z0 + 0.16), (cx + W, cy + sy * Dd, z0 + 0.18)],
        ], cap_a=True, cap_b=True), m_roof, W_ROOT)
        # 斜面主体
        b.add(K3._bm_loft([
            [(cx - W, cy + sy * Dd, z0 + 0.14), (cx - W, cy, zr),
             (cx - W, cy, zr - 0.18), (cx - W, cy + sy * Dd, z0 - 0.02)],
            [(cx + W, cy + sy * Dd, z0 + 0.14), (cx + W, cy, zr),
             (cx + W, cy, zr - 0.18), (cx + W, cy + sy * Dd, z0 - 0.02)],
        ], cap_a=True, cap_b=True), m_roof, W_ROOT)
        # 瓦垄：只留一条**沿檐口的压边**。
        # 早期版本沿坡向铺一排竖条，远景看像板条箱、非常廉价（截图里一眼就能看到），已删。
        box(b, (W * 2, 0.12, 0.10), (cx, cy + sy * Dd, z0 + 0.10), mat("roof_dark"), bevel=0.015)
    if ridge:
        box(b, (W * 2 + 0.1, 0.16, 0.12), (cx, cy, zr + 0.02), m_trim, bevel=0.02)
    # 山墙（三角面）
    for sx in (-1, 1):
        b.add(K3._bm_loft([
            [(cx + sx * w * 0.5, cy - d * 0.5, z0), (cx + sx * w * 0.5, cy + d * 0.5, z0),
             (cx + sx * w * 0.5, cy + d * 0.5, z0), (cx + sx * w * 0.5, cy - d * 0.5, z0)],
            [(cx + sx * w * 0.5, cy - 0.01, zr - 0.1), (cx + sx * w * 0.5, cy + 0.01, zr - 0.1),
             (cx + sx * w * 0.5, cy + 0.01, zr - 0.1), (cx + sx * w * 0.5, cy - 0.01, zr - 0.1)],
        ], cap_a=True, cap_b=True), mat("plaster"), W_ROOT)


def cone_roof(b, cx, cy, r, z0, h, m_roof, m_trim, sides=12, over=0.16):
    b.cyl(r + over, 0.02, h, loc=(cx, cy, z0), material=m_roof, sides=sides, weight=W_ROOT)
    b.cyl(r + over + 0.02, r + over, 0.07, loc=(cx, cy, z0 - 0.04), material=m_trim,
          sides=sides, weight=W_ROOT)
    b.ico(0.075, loc=(cx, cy, z0 + h + 0.02), material=m_trim, subdiv=1, weight=W_ROOT)


def arrow_slit(b, cx, cy, cz, rot=0.0, m=None, m_dark=None):
    box(b, (0.16, 0.05, 0.52), (cx, cy, cz), m, rot=(0, 0, rot), bevel=0.01)
    box(b, (0.08, 0.06, 0.44), (cx, cy, cz), m_dark, rot=(0, 0, rot), bevel=0.005)


def banner(b, x, y, z0, z1, m_pole, m_cloth, m_trim, dirx=0.0, diry=1.0, rig=None, idx=0):
    """旗杆 + 旗面（旗面权重给 flag 骨链，跟随 wave 动画）。"""
    b.cyl(0.035, 0.028, z1 - z0, loc=(x, y, z0), material=m_pole, sides=6, weight=W_ROOT)
    b.ico(0.055, loc=(x, y, z1 + 0.03), material=m_trim, subdiv=1, weight=W_ROOT)
    n = Vector((dirx, diry, 0.0))
    if n.length < 1e-4:
        n = Vector((1, 0, 0))
    n.normalize()
    t = Vector((-n.y, n.x, 0.0))
    fw, fh = 1.05, 0.62
    zt = z1 - 0.06
    rings = []
    for i in range(5):
        u = i / 4.0
        p0 = Vector((x, y, zt)) + n * (fw * u)
        wgt = {"flag.%d.%d" % (idx + 1, min(3, 1 + int(u * 3))): 1.0}
        rings.append([(p0.x - t.x * 0.004, p0.y - t.y * 0.004, p0.z),
                      (p0.x + t.x * fh * 0.5, p0.y + t.y * fh * 0.5, p0.z),
                      (p0.x - t.x * fh * 0.5, p0.y - t.y * fh * 0.5, p0.z)])
    # 旗面用三角形带（两条边到旗杆）
    for i in range(4):
        u0, u1 = i / 4.0, (i + 1) / 4.0
        p0 = Vector((x, y, zt)) + n * (fw * u0)
        p1 = Vector((x, y, zt)) + n * (fw * u1)
        hh = fh * (1.0 - 0.18 * u1)
        b.add(K3._bm_loft([
            [(p0.x, p0.y, p0.z), (p0.x - t.x * hh, p0.y - t.y * hh, p0.z)],
            [(p1.x, p1.y, p1.z - 0.02), (p1.x - t.x * (hh * 0.94), p1.y - t.y * (hh * 0.94), p1.z - 0.02)],
        ], cap_a=False, cap_b=False), m_cloth,
            {"flag.%d.%d" % (idx + 1, min(3, 1 + int(u0 * 3))): 1.0})
    # 旗杆横臂
    box(b, (0.05, 0.05, 0.05), (x, y, zt), m_trim)


def window(b, cx, cy, cz, rot=0.0, w=0.30, h=0.56, m_frame=None, m_glass=None):
    box(b, (w + 0.12, 0.06, h + 0.12), (cx, cy, cz), m_frame, rot=(0, 0, rot), bevel=0.01)
    box(b, (w, 0.05, h), (cx, cy, cz), m_glass, rot=(0, 0, rot), bevel=0.005)


def arch_door(b, cx, cy, cz0, w, h, m_stone, m_door, m_trim):
    """拱门：石拱 + 木门（用多段小方块拼拱，避免布尔）。"""
    box(b, (w, 0.22, h), (cx, cy, cz0 + h * 0.5), m_door, bevel=0.01)
    segs = 7
    for i in range(segs):
        a = math.pi * (i + 0.5) / segs
        px = cx - math.cos(a) * (w * 0.5 + 0.10)
        pz = cz0 + h + math.sin(a) * (w * 0.42)
        box(b, (w / segs * 1.28, 0.26, 0.20), (px, cy, pz), m_stone,
            rot=(0, 0, math.pi * 0.5 - a), bevel=0.012)
    for sx in (-1, 1):
        box(b, (0.20, 0.26, h + 0.06), (cx + sx * (w * 0.5 + 0.10), cy, cz0 + h * 0.5),
            m_stone, bevel=0.012)
    # 金色门环
    b.cyl(0.04, 0.04, 0.02, loc=(cx, cy + 0.12, cz0 + h * 0.45), rot=(D(90), 0, 0),
          material=m_trim, sides=8, weight=W_ROOT)


def steps(b, cx, cy, w, z_top, n, m):
    """台阶：从门口 z_top 往下走 n 级，最底层贴地（不许穿到地面以下）。"""
    for i in range(n):
        z = z_top - 0.09 - 0.18 * i
        if z < 0.09:
            z = 0.09
        box(b, (w, 0.30, 0.18), (cx, cy + 0.34 * (n - i), z), m, bevel=0.01)


def barrel(b, x, y, z=0.0, m=None, m_band=None):
    b.cyl(0.20, 0.17, 0.46, loc=(x, y, z), material=m, sides=10, weight=W_ROOT)
    for zz in (0.12, 0.34):
        b.cyl(0.205, 0.205, 0.045, loc=(x, y, z + zz), material=m_band, sides=10, weight=W_ROOT)



# ===========================================================================
# v4 细节构件：叠瓦屋面 / 分层砌石 / 门窗五金 / 木构 / 生活道具
# ===========================================================================

import random as _rnd


def _l(a, b, t):
    return a + (b - a) * t


def _f4(o, u, v):
    """由 (原点, 面内 u, 面内 v) 造 4x4 变换；法线 n = v × u（右手系，n 朝外）。"""
    o = Vector(o)
    u = Vector(u).normalized()
    v = Vector(v).normalized()
    n = v.cross(u).normalized()
    v = u.cross(n).normalized()
    return Matrix(((u.x, v.x, n.x, o.x),
                   (u.y, v.y, n.y, o.y),
                   (u.z, v.z, n.z, o.z),
                   (0.0, 0.0, 0.0, 1.0)))


def place(b, size, o, u, v, m, bevel=0.0, tilt_x=0.0, weight=None):
    """在 (o,u,v) 平面里放一个盒子；tilt_x 让瓦片下缘翘起，形成"上压下"的锯口。"""
    M = _f4(o, u, v)
    if abs(tilt_x) > 1e-6:
        M = M @ Matrix.Rotation(math.radians(tilt_x), 4, "X")
    b.box(size, material=m, bevel=bevel, xform=M, weight=weight or W_ROOT)


def wall_shell(b, cx, cy, w, d, z0, z1, m, thick=0.35):
    h = z1 - z0
    zc = (z0 + z1) * 0.5
    box(b, (w, thick, h), (cx, cy + d * 0.5 - thick * 0.5, zc), m)
    box(b, (w, thick, h), (cx, cy - d * 0.5 + thick * 0.5, zc), m)
    box(b, (thick, d - thick * 2, h), (cx - w * 0.5 + thick * 0.5, cy, zc), m)
    box(b, (thick, d - thick * 2, h), (cx + w * 0.5 - thick * 0.5, cy, zc), m)


def _hit(u0, u1, z0, z1, holes):
    for (hc, hw, hz0, hz1) in holes:
        if u0 < hc + hw * 0.5 + 0.05 and u1 > hc - hw * 0.5 - 0.05 \
                and z0 < hz1 + 0.05 and z1 > hz0 - 0.05:
            return True
    return False


def masonry_face(b, face, cx, cy, w, d, z0, z1, mats, holes=(), seed=0,
                 row_h=0.34, depth=0.045):
    """在四面外墙外侧铺错缝砌石（颜色三档交错），门窗洞处自动跳过。"""
    rnd = _rnd.Random(seed)
    m_base, m_hi, m_lo = mats
    length = w if face in ("+y", "-y") else d
    if face == "+y":
        plane = cy + d * 0.5
    elif face == "-y":
        plane = cy - d * 0.5
    elif face == "+x":
        plane = cx + w * 0.5
    else:
        plane = cx - w * 0.5
    rows = max(1, int((z1 - z0) / row_h))
    rh = (z1 - z0) / rows
    for r in range(rows):
        zz = z0 + rh * (r + 0.5)
        u = -length * 0.5 - (rnd.uniform(0.12, 0.42) if r % 2 else 0.0)
        while u < length * 0.5 - 0.08:
            bl = rnd.uniform(0.40, 0.74)
            u0 = u
            u1 = min(u + bl, length * 0.5)
            # 用"洞把石块切成残余矩形"代替"整块跳过"——门窗边不会留下大片光墙
            rects = [(u0, u1, zz - rh * 0.42, zz + rh * 0.42)]
            for (hc, hw, hz0, hz1) in holes:
                hu0, hu1 = hc - hw * 0.5 - 0.02, hc + hw * 0.5 + 0.02
                out = []
                for (a, bb, c, dd) in rects:
                    if bb <= hu0 or a >= hu1 or dd <= hz0 or c >= hz1:
                        out.append((a, bb, c, dd))
                        continue
                    if a < hu0:
                        out.append((a, hu0, c, dd))
                    if bb > hu1:
                        out.append((hu1, bb, c, dd))
                    m0, m1 = max(a, hu0), min(bb, hu1)
                    if m1 - m0 > 0.001:
                        if c < hz0:
                            out.append((m0, m1, c, min(dd, hz0)))
                        if dd > hz1:
                            out.append((m0, m1, max(c, hz1), dd))
                rects = out
            q = rnd.random()
            mm = m_hi if q < 0.15 else (m_lo if q < 0.31 else m_base)
            for (a, bb, c, dd) in rects:
                if bb - a < 0.09 or dd - c < 0.09:
                    continue
                uc = (a + bb) * 0.5
                zc = (c + dd) * 0.5
                if face in ("+y", "-y"):
                    yy = plane + (depth * 0.5) * (1 if face == "+y" else -1)
                    box(b, ((bb - a) * 0.94, depth, (dd - c) * 0.86), (cx + uc, yy, zc), mm)
                else:
                    xx = plane + (depth * 0.5) * (1 if face == "+x" else -1)
                    box(b, (depth, (bb - a) * 0.94, (dd - c) * 0.86), (xx, cy + uc, zc), mm)
            u = u1 + rnd.uniform(0.02, 0.05)


def quoins(b, cx, cy, w, d, z0, z1, mats, size=0.48, row_h=0.40):
    """转角石：交替大小/颜色的方石，把四个角"咬"住。"""
    m_a, m_b = mats
    rows = max(2, int((z1 - z0) / row_h))
    rh = (z1 - z0) / rows
    for sx in (-1, 1):
        for sy in (-1, 1):
            for r in range(0, rows, 2):
                zz = z0 + rh * (r + 0.5)
                xx = cx + sx * (w * 0.5 - size * 0.5 + 0.035)
                yy = cy + sy * (d * 0.5 - size * 0.5 + 0.035)
                box(b, (size, size, rh * 1.04), (xx, yy, zz),
                    m_a if (r // 2) % 2 == 0 else m_b, bevel=0.008)


def string_course(b, cx, cy, w, d, z, m, out=0.08, h=0.10):
    """腰线：沿四面墙一圈的窄压顶。"""
    box(b, (w + out * 2, d + out * 2, h), (cx, cy, z), m, bevel=0.012)


def corbel_row(b, cx, cy, w, d, z, m, step=0.60, out=0.14, h=0.16):
    """檐下托石（斗拱感）：一圈小方块，出挑。"""
    for face in ("+y", "-y"):
        n = max(2, int(w / step))
        for i in range(n):
            xx = cx - w * 0.5 + (i + 0.5) * (w / n)
            yy = cy + (d * 0.5 + out * 0.5 if face == "+y" else -d * 0.5 - out * 0.5)
            box(b, (w / n * 0.55, out + 0.03, h), (xx, yy, z), m, bevel=0.008)
    for face in ("+x", "-x"):
        n = max(2, int(d / step))
        for i in range(n):
            yy = cy - d * 0.5 + (i + 0.5) * (d / n)
            xx = cx + (w * 0.5 + out * 0.5 if face == "+x" else -w * 0.5 - out * 0.5)
            box(b, (out + 0.03, d / n * 0.55, h), (xx, yy, z), m, bevel=0.008)


def tile_slope(b, o, u, up, w0, w1, run, m_tile, m_dark, course=0.34,
               tile_w=0.46, thick=0.055, seed=0):
    """一段坡屋面：逐层叠瓦 + 每层底口的暗色压边 + 瓦缝露出暗底。"""
    u = Vector(u).normalized()
    up = Vector(up).normalized()
    n = up.cross(u).normalized()
    if n.z < 0.0:                       # 保证法线朝上（朝外）
        u = -u
        n = up.cross(u).normalized()
    rows = max(2, int(round(run / course)))
    step = run / rows
    rnd = _rnd.Random(seed)
    for i in range(rows):
        t = i * step
        wt = _l(w0, w1, (t + step * 0.5) / run)
        nt = max(2, int(wt / tile_w))
        tw = wt / nt
        # 暗底（瓦缝/檐口从这里透出来）
        place(b, (wt * 1.005, step * 1.02, 0.035), o + up * (t + step * 0.5) + n * 0.012,
              u, up, m_dark)
        # 本层瓦
        for j in range(nt):
            cu = (j + 0.5) * tw - wt * 0.5
            jitter = rnd.uniform(-0.012, 0.012)
            place(b, (tw * 0.93, step * 1.22, thick),
                  o + u * cu + up * (t + step * 0.56) + n * (0.030 + jitter),
                  u, up, m_tile, tilt_x=-7.0)
        # 层底压边（"上压下"的阴影线）
        place(b, (wt * 0.995, 0.045, 0.05), o + up * (t + 0.016) + n * 0.075,
              u, up, m_dark)


def ridge_cap(b, p0, p1, m, m_trim, step=0.46, w=0.42, h=0.22):
    """屋脊瓦：沿脊线一串小盒 + 两端金饰。"""
    p0 = Vector(p0)
    p1 = Vector(p1)
    d = p1 - p0
    L = d.length
    if L < 0.05:
        return
    u = d / L
    v = Vector((0, 0, 1))
    n = u.cross(v).normalized()
    cnt = max(2, int(L / step))
    for i in range(cnt):
        c = p0 + u * ((i + 0.5) * L / cnt)
        b.box((L / cnt * 1.04, w, h), material=m, loc=(c.x, c.y, c.z + h * 0.35))
    for p in (p0, p1):
        b.ico(0.10, loc=(p.x, p.y, p.z + 0.08), material=m_trim, subdiv=1)


def eave_fascia(b, cx, cy, w, d, z, m_wood, m_dark, over=0.42, rafters=True, step=0.66):
    """檐口：封檐板 + 椽头 + 滴水线。"""
    for face in ("+y", "-y"):
        yy = cy + (d * 0.5 + over * 0.5 if face == "+y" else -d * 0.5 - over * 0.5)
        box(b, (w + over * 2, over, 0.10), (cx, yy, z - 0.06), m_wood, bevel=0.01)
        box(b, (w + over * 2, 0.06, 0.05), (cx, yy + (0.02 if face == "+y" else -0.02), z - 0.11), m_dark)
        if rafters:
            n = max(2, int(w / step))
            for i in range(n):
                xx = cx - w * 0.5 + (i + 0.5) * (w / n)
                box(b, (0.09, over * 0.95, 0.09), (xx, yy, z - 0.16), m_dark)
    for face in ("+x", "-x"):
        xx = cx + (w * 0.5 + over * 0.5 if face == "+x" else -w * 0.5 - over * 0.5)
        box(b, (over, d + over * 2, 0.10), (xx, cy, z - 0.06), m_wood, bevel=0.01)
        box(b, (0.06, d + over * 2, 0.05), (xx + (0.02 if face == "+x" else -0.02), cy, z - 0.11), m_dark)


def bargeboard(b, o, up, across, L, m_wood, m_trim, w=0.11, h=0.17):
    """博风板：沿山墙斜边的一条厚板，端头挂金坠。"""
    up = Vector(up).normalized()
    across = Vector(across).normalized()
    n = up.cross(across).normalized()
    if n.z < 0:
        across = -across
        n = up.cross(across).normalized()
    cnt = max(2, int(L / 0.9))
    for i in range(cnt):
        c = Vector(o) + up * ((i + 0.5) * L / cnt)
        b.box((L / cnt * 1.03, w, h), material=m_wood, xform=_f4(c, up, across), bevel=0.01)
    b.box((w * 1.6, w * 1.6, 0.20), material=m_trim, xform=_f4(Vector(o) + up * L, up, across))


def gable_wall(b, cx, cy, x, w, d, z0, z_ridge, m, thick=0.30):
    """山墙三角（沿 X 起脊时挂在 x=± 两头）：三棱柱，不是退化放样。"""
    t = thick * 0.5
    a = [(x - t, cy - d * 0.5, z0), (x - t, cy + d * 0.5, z0), (x - t, cy, z_ridge)]
    c = [(x + t, cy - d * 0.5, z0), (x + t, cy + d * 0.5, z0), (x + t, cy, z_ridge)]
    b.add(K3._bm_loft([a, c], cap_a=True, cap_b=True), m, W_ROOT)


def roof_gable_tiled(b, cx, cy, w, d, z_eave, z_ridge, m_tile, m_dark, m_wood,
                     m_trim, over=0.42, course=0.34, tile_w=0.46):
    """双坡叠瓦屋顶：两坡 + 屋脊 + 博风板 + 檐口。"""
    W = w * 0.5 + over
    D = d * 0.5 + over
    rise = z_ridge - z_eave
    run = math.sqrt(D * D + rise * rise)
    for sy in (-1, 1):
        o = Vector((cx, cy + sy * D, z_eave))
        up = Vector((0, -sy * D, rise))
        tile_slope(b, o, Vector((1, 0, 0)), up, 2 * W, 2 * W, run,
                   m_tile, m_dark, course=course, tile_w=tile_w, seed=sy + 3)
        bargeboard(b, (cx - W, cy + sy * D, z_eave), up, (1, 0, 0), run, m_wood, m_trim)
        bargeboard(b, (cx + W, cy + sy * D, z_eave), up, (-1, 0, 0), run, m_wood, m_trim)
    eave_fascia(b, cx, cy, w, d, z_eave, m_wood, m_dark, over=over)
    ridge_cap(b, (cx - W, cy, z_ridge), (cx + W, cy, z_ridge), m_dark, m_trim)


def roof_hip_tiled(b, cx, cy, w, d, z_eave, z_ridge, ridge_len, m_tile, m_dark,
                   m_wood, m_trim, over=0.45, course=0.36, tile_w=0.46):
    """四坡叠瓦屋顶（大本营主殿）：前后梯形坡 + 左右三角坡 + 四条戗脊。"""
    W = w * 0.5 + over
    D = d * 0.5 + over
    rise = z_ridge - z_eave
    # 前后梯形
    run_f = math.sqrt(D * D + rise * rise)
    for sy in (-1, 1):
        o = Vector((cx, cy + sy * D, z_eave))
        up = Vector((0, -sy * D, rise))
        tile_slope(b, o, Vector((1, 0, 0)), up, 2 * W, ridge_len, run_f,
                   m_tile, m_dark, course=course, tile_w=tile_w, seed=11 + sy)
    # 左右三角
    run_s = math.sqrt(W * W + rise * rise)
    for sx in (-1, 1):
        o = Vector((cx + sx * W, cy, z_eave))
        up = Vector((-sx * W, 0, rise))
        u = Vector((0, -sx, 0))
        tile_slope(b, o, u, up, 2 * D, 0.30, run_s,
                   m_tile, m_dark, course=course, tile_w=tile_w, seed=21 + sx)
    # 戗脊（四条斜脊），把四个坡的交线盖住
    for sx in (-1, 1):
        for sy in (-1, 1):
            p0 = Vector((cx + sx * W, cy + sy * D, z_eave))
            p1 = Vector((cx + sx * ridge_len * 0.5, cy, z_ridge))
            dvec = p1 - p0
            L = dvec.length
            up = dvec / L
            across = Vector((0, 0, 1))
            n = up.cross(across).normalized()
            if n.z < 0:
                across = -across
            cnt = max(2, int(L / 0.5))
            for i in range(cnt):
                c = p0 + up * ((i + 0.5) * L / cnt)
                b.box((L / cnt * 1.05, 0.20, 0.14), material=m_dark,
                      xform=_f4(c, up, across), bevel=0.008)
    eave_fascia(b, cx, cy, w, d, z_eave, m_wood, m_dark, over=over)
    ridge_cap(b, (cx - ridge_len * 0.5, cy, z_ridge),
              (cx + ridge_len * 0.5, cy, z_ridge), m_dark, m_trim)


def cone_roof_tiled(b, cx, cy, r, z0, z1, m_tile, m_dark, m_trim, sides=12, bands=7):
    """锥顶叠瓦（塔顶）：分带收分 + 每带底口一圈暗压边。"""
    for i in range(bands):
        t0 = i / float(bands)
        t1 = (i + 1) / float(bands)
        rr0 = r * (1.0 - t0)
        rr1 = r * (1.0 - t1)
        hh = (z1 - z0) / bands
        b.cyl(rr0 * 1.015, rr1, hh * 1.06, loc=(cx, cy, z0 + (z1 - z0) * t0),
              material=m_tile, sides=sides, weight=W_ROOT)
        b.cyl(rr0 * 1.045, rr0 * 1.045, 0.045, loc=(cx, cy, z0 + (z1 - z0) * t0 - 0.015),
              material=m_dark, sides=sides, weight=W_ROOT)
    b.ico(0.09, loc=(cx, cy, z1 + 0.03), material=m_trim, subdiv=1, weight=W_ROOT)



def masonry_ring(b, cx, cy, r, z0, z1, mats, sides=12, row_h=0.42, depth=0.05, seed=0):
    """圆塔的砌石：按 12 边形逐块贴面，错缝 + 三档颜色。"""
    rnd = _rnd.Random(seed)
    m_base, m_hi, m_lo = mats
    rows = max(1, int((z1 - z0) / row_h))
    rh = (z1 - z0) / rows
    arc = TAU * r / sides
    for i in range(rows):
        zz = z0 + rh * (i + 0.5)
        off = 0.5 if i % 2 else 0.0
        for j in range(sides):
            a = TAU * (j + 0.5 + off) / sides
            q = rnd.random()
            mm = m_hi if q < 0.15 else (m_lo if q < 0.31 else m_base)
            box(b, (arc * 0.88, depth, rh * 0.84),
                (cx + r * math.cos(a), cy + r * math.sin(a), zz),
                mm, rot=(0, 0, a + math.pi * 0.5))


def arrow_loophole(b, x, y, z, ang, m_frame, m_dark, w=0.34, h=0.78):
    """箭孔：浅色石框 + 更靠外的暗缝（实体墙不做布尔，靠"贴脸"读成洞）。"""
    ca = math.cos(ang)
    sa = math.sin(ang)
    box(b, (w, 0.07, h), (x - ca * 0.02, y - sa * 0.02, z), m_frame,
        rot=(0, 0, ang + math.pi * 0.5), bevel=0.008)
    box(b, (w * 0.36, 0.07, h * 0.68), (x + ca * 0.025, y + sa * 0.025, z), m_dark,
        rot=(0, 0, ang + math.pi * 0.5))
    for sz in (-1, 1):
        box(b, (w * 0.9, 0.09, 0.07), (x + ca * 0.01, y + sa * 0.01, z + sz * h * 0.52),
            m_frame, rot=(0, 0, ang + math.pi * 0.5), bevel=0.006)


def door_v4(b, cx, face_y, z0, w, h, mats, planks=5, arch_rise=0.78):
    """门：暗色门洞 + 石框 + 竖板 + 铁箍 + 门钉 + 门环 + 券石。

    注意：墙体是实心壳（不做布尔开洞），所以门做"贴脸式"——先在墙面盖一块
    深色门洞，再把门板/铁活/石框层层压上去，近看仍有凹入的读感。
    """
    m_frame, m_door, m_dark, m_iron, m_hi, m_gold = mats
    cy = face_y
    box(b, (w + 0.14, 0.018, h + 0.10), (cx, cy + 0.006, z0 + h * 0.5), m_dark)
    pw = (w - 0.05) / planks
    for i in range(planks):
        px = cx - (w - 0.05) * 0.5 + pw * (i + 0.5)
        box(b, (pw * 0.94, 0.06, h * 0.985), (px, cy + 0.028, z0 + h * 0.5),
            m_door, bevel=0.005)
    for sx in (-1, 1):
        box(b, (0.17, 0.24, h + 0.16), (cx + sx * (w * 0.5 + 0.075), cy + 0.03,
                                       z0 + h * 0.5), m_frame, bevel=0.012)
    box(b, (w + 0.46, 0.24, 0.19), (cx, cy + 0.03, z0 + h + 0.09), m_frame, bevel=0.012)
    box(b, (w + 0.30, 0.36, 0.09), (cx, cy + 0.07, z0 + 0.045), m_hi, bevel=0.01)
    for zz in (0.28, 0.60, 0.86):
        box(b, (w * 0.93, 0.030, 0.075), (cx, cy + 0.070, z0 + h * zz), m_iron)
        for k in (-1, 1):
            box(b, (0.055, 0.042, 0.08), (cx + k * w * 0.44, cy + 0.058, z0 + h * zz), m_hi)
    for i in range(3):
        for j in range(4):
            box(b, (0.030, 0.028, 0.030),
                (cx - w * 0.30 + i * w * 0.30, cy + 0.068, z0 + h * (0.16 + j * 0.21)), m_hi)
    ring = [(cx + w * 0.28 + 0.055 * math.cos(TAU * k / 10),
             cy + 0.082,
             z0 + h * 0.46 + 0.055 * math.sin(TAU * k / 10)) for k in range(11)]
    b.tube(ring, 0.011, m_iron, weight=W_ROOT, sides=5)
    # 券石
    segs = 7
    rr = w * 0.5 + 0.10
    for i in range(segs):
        a = math.pi * (i + 0.5) / segs
        px = cx - math.cos(a) * rr
        pz = z0 + h + math.sin(a) * arch_rise
        box(b, (w / segs * 1.22, 0.24, 0.22), (px, cy + 0.03, pz), m_frame,
            rot=(0, 0, math.pi * 0.5 - a), bevel=0.01)
    box(b, (0.24, 0.26, 0.26), (cx, cy + 0.04, z0 + h + arch_rise + 0.05), m_gold, bevel=0.012)


def window_v4(b, cx, face_y, z, w, h, mats, yaw=0.0, shutters=False, bars=0,
              frame_w=0.075):
    """窗：凹入窗洞 + 石框 + 窗台 + 中梃 + 可选百叶/铁栅。"""
    m_frame, m_glass, m_dark, m_iron, m_wood, m_hi = mats
    ca = math.cos(yaw)
    sa = math.sin(yaw)

    def P(lx, ly):
        return (cx + lx * ca - ly * sa, face_y + lx * sa + ly * ca)

    def B(sx, sy, sz, lx, ly, m, rr=0.0, bevel=0.0):
        px, py = P(lx, ly)
        box(b, (sx, sy, sz), (px, py, z), m, rot=(0, 0, yaw + rr), bevel=bevel)

    # 暗色窗洞（墙体实心，靠这块盖住白墙，形成凹入的读感）
    B(w + 0.12, 0.016, h + 0.10, 0, 0.006, m_dark)
    # 玻璃
    B(w + 0.02, 0.05, h + 0.02, 0, 0.020, m_glass)
    # 上下框
    for sz in (-1, 1):
        px, py = P(0, 0.035)
        box(b, (w + 0.18, 0.12, 0.095), (px, py, z + sz * (h * 0.5 + 0.045)), m_frame,
            rot=(0, 0, yaw), bevel=0.008)
    # 左右框
    for sx in (-1, 1):
        px, py = P(sx * (w * 0.5 + 0.05), 0.035)
        box(b, (0.11, 0.12, h + 0.02), (px, py, z), m_frame, rot=(0, 0, yaw), bevel=0.008)
    # 窗台
    B(w + 0.30, 0.22, 0.085, 0, 0.075, m_frame, bevel=0.012)
    # 中梃
    B(0.035, 0.05, h * 0.96, 0, 0.048, m_wood)
    B(w * 0.94, 0.05, 0.035, 0, 0.048, m_wood)
    if bars:
        for i in range(bars):
            B(0.028, 0.045, h, -w * 0.5 + (i + 1) * w / (bars + 1), 0.055, m_iron)
    if shutters:
        for sx in (-1, 1):
            B(w * 0.52, 0.055, h * 0.98, sx * (w * 0.5 + w * 0.30), 0.045, m_wood, rr=0.0, bevel=0.006)
            B(0.05, 0.05, h * 0.9, sx * (w * 0.5 + 0.04), 0.070, m_iron)


def lantern(b, x, y, z, m_iron, m_ember, m_hi, h=0.34):
    """挂灯：铁框 + 发光芯 + 顶盖。"""
    box(b, (0.085, 0.085, 0.035), (x, y, z + h * 0.5), m_hi, bevel=0.006)
    box(b, (0.085, 0.085, 0.045), (x, y, z - h * 0.5), m_iron, bevel=0.006)
    for sx in (-1, 1):
        for sy in (-1, 1):
            box(b, (0.022, 0.022, h), (x + sx * 0.048, y + sy * 0.048, z), m_iron)
    box(b, (0.062, 0.062, h * 0.72), (x, y, z), m_ember)
    b.cyl(0.075, 0.03, 0.10, loc=(x, y, z + h * 0.55), material=m_iron, sides=6, weight=W_ROOT)
    box(b, (0.02, 0.02, 0.16), (x, y, z + h * 0.62), m_iron)


def crate(b, x, y, z, s, m_wood, m_dark, m_iron):
    """木箱：箱体 + 四角包边 + 铁角。"""
    box(b, (s, s, s * 0.82), (x, y, z + s * 0.41), m_wood, bevel=0.012)
    for sx in (-1, 1):
        for sy in (-1, 1):
            box(b, (0.05, 0.05, s * 0.82), (x + sx * s * 0.47, y + sy * s * 0.47, z + s * 0.41), m_dark)
            box(b, (0.09, 0.09, 0.06), (x + sx * s * 0.45, y + sy * s * 0.45, z + s * 0.06), m_iron)
    box(b, (s * 0.96, s * 0.96, 0.05), (x, y, z + s * 0.84), m_dark, bevel=0.008)


def woodpile(b, x, y, z, m_wood, m_dark):
    """柴堆：三层交错圆木。"""
    for row in range(3):
        n = 4 - row
        for i in range(n):
            b.cyl(0.085, 0.085, 0.62, loc=(x + (i - (n - 1) * 0.5) * 0.19 + (0.09 if row % 2 else 0),
                                          y, z + 0.09 + row * 0.17),
                  rot=(D(90), 0, 0), material=m_wood if i % 2 == 0 else m_dark,
                  sides=6, weight=W_ROOT)


def hay_bale(b, x, y, z, s, m_hay, m_dark):
    b.cyl(s * 0.5, s * 0.5, s * 0.75, loc=(x, y, z), material=m_hay, sides=10, weight=W_ROOT)
    for zz in (0.18, 0.56):
        b.cyl(s * 0.52, s * 0.52, 0.04, loc=(x, y, z + s * 0.75 * zz), material=m_dark,
              sides=10, weight=W_ROOT)
    b.ico(s * 0.5, loc=(x, y, z + s * 0.78), material=m_hay, subdiv=1, weight=W_ROOT,
          scale=(1.0, 1.0, 0.45))


def banner_v4(b, x, y, z0, z1, m_pole, m_cloth, m_trim, m_dark, idx=0, dirx=0.0, diry=1.0, fw=0.94):
    """旗：杆 + 顶饰 + 燕尾旗面（分段权重到 flag 骨）+ 金色下缘。"""
    b.cyl(0.030, 0.024, z1 - z0, loc=(x, y, z0), material=m_pole, sides=6, weight=W_ROOT)
    b.cyl(0.055, 0.045, 0.06, loc=(x, y, z0 - 0.02), material=m_trim, sides=6, weight=W_ROOT)
    b.ico(0.055, loc=(x, y, z1 + 0.03), material=m_trim, subdiv=1, weight=W_ROOT)
    n = Vector((dirx, diry, 0.0))
    if n.length < 1e-4:
        n = Vector((1, 0, 0))
    n.normalize()
    fh = 0.64
    zt = z1 - 0.05
    segs = 6
    for i in range(segs):
        u0, u1 = i / float(segs), (i + 1) / float(segs)
        p0 = Vector((x, y, zt)) + n * (fw * u0)
        p1 = Vector((x, y, zt)) + n * (fw * u1)
        # 燕尾：越靠外越短，末端再收一个尖
        h0 = fh * (1.0 - 0.16 * u0)
        h1 = fh * (1.0 - 0.16 * u1)
        wgt = {"flag.%d.%d" % (idx + 1, min(3, 1 + int(u0 * 3))): 1.0}
        b.add(K3._bm_loft([
            [(p0.x, p0.y, p0.z), (p0.x, p0.y, p0.z - h0)],
            [(p1.x, p1.y, p1.z - 0.012), (p1.x, p1.y, p1.z - 0.012 - h1)],
        ], cap_a=False, cap_b=False), m_cloth, wgt)
        # 金色下缘
        b.add(K3._bm_loft([
            [(p0.x, p0.y, p0.z - h0), (p0.x, p0.y, p0.z - h0 - 0.05)],
            [(p1.x, p1.y, p1.z - 0.012 - h1), (p1.x, p1.y, p1.z - 0.012 - h1 - 0.05)],
        ], cap_a=False, cap_b=False), m_trim, wgt)
    # 旗顶横杆（挂布用）
    box(b, (0.045, 0.045, 0.045), (x + n.x * (fw * 0.5), y + n.y * (fw * 0.5), zt), m_trim)
    b.tube([(x + n.x * 0.02, y + n.y * 0.02, zt), (x + n.x * fw, y + n.y * fw, zt)],
           0.016, m_trim, weight=W_ROOT, sides=4)


# ===========================================================================
# 1) 城镇/大本营 8x8x9
# ===========================================================================

def build_townhall():
    coll = K3.reset_scene()
    r = BuildingRig("townhall")
    r.add_flag(1.95, 3.18, 3.42, 4.16, dirx=1.0, diry=0.0)
    r.add_flag(-1.95, 3.18, 3.42, 4.16, dirx=-1.0, diry=0.0)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_roof = mat("roof", team=True)
    m_roof_d = mat("roof_dark")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_mortar = mat("iron")
    m_steel = mat("steel_light")
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)
    m_ember = mat("ember")
    m_leaf = mat("leaf_dark")

    b = Builder("townhall")

    # ---- 台基 8x8：三级退台 ----
    box(b, (8.0, 8.0, 0.30), (0, 0, 0.15), m_stone_d, bevel=0.05)
    box(b, (7.70, 7.70, 0.06), (0, 0, 0.33), m_iron)
    box(b, (7.66, 7.66, 0.26), (0, 0, 0.49), m_stone_d, bevel=0.035)
    box(b, (7.34, 7.34, 0.12), (0, 0, 0.68), m_stone, bevel=0.02)

    # ---- 主殿墙 6.4 x 6.2（z 0.72 -> 5.05）----
    W, Dd, z0, z1 = 6.4, 6.2, 0.72, 5.05
    wall_shell(b, 0, 0, W, Dd, z0, z1, m_mortar, thick=0.36)
    hole_door = (0.0, 2.02, 0.72, 3.26)
    hole_rose = (0.0, 1.34, 3.50, 4.70)
    hole_fw = [(-2.25, 0.92, 2.58, 3.78), (2.25, 0.92, 2.58, 3.78)]
    hole_sw = [(-1.35, 0.92, 2.58, 3.78), (1.35, 0.92, 2.58, 3.78)]
    holes_front = [hole_door, hole_rose] + hole_fw
    holes_side = hole_sw
    holes_back = [(-2.05, 0.92, 2.58, 3.78), (2.05, 0.92, 2.58, 3.78)]
    stones = (m_stone, m_stone_l, m_stone_d)
    masonry_face(b, "+y", 0, 0, W, Dd, z0, z1, stones, holes=holes_front, seed=41, row_h=0.38)
    masonry_face(b, "-y", 0, 0, W, Dd, z0, z1, stones, holes=holes_back, seed=42, row_h=0.38)
    masonry_face(b, "+x", 0, 0, W, Dd, z0, z1, stones, holes=holes_side, seed=43, row_h=0.38)
    masonry_face(b, "-x", 0, 0, W, Dd, z0, z1, stones, holes=holes_side, seed=44, row_h=0.38)

    # 腰线 + 檐下托石
    string_course(b, 0, 0, W, Dd, 4.72, m_stone_l, out=0.06, h=0.09)
    corbel_row(b, 0, 0, W, Dd, 4.90, m_stone_d, step=0.58, out=0.16, h=0.17)

    # ---- 四角圆塔 ----
    for sx in (-1, 1):
        for sy in (-1, 1):
            tx, ty = sx * 2.72, sy * 2.72
            b.cyl(1.14, 1.06, 0.62, loc=(tx, ty, 0.70), material=m_stone_d, sides=12, weight=W_ROOT)
            b.cyl(1.04, 0.96, 5.40, loc=(tx, ty, 1.02), material=m_stone, sides=12, weight=W_ROOT)
            masonry_ring(b, tx, ty, 1.005, 1.10, 5.30, (m_stone, m_stone_l, m_stone_d),
                         sides=12, row_h=0.42, seed=60 + int(tx * 7 + ty * 3))
            for zz in (1.62, 3.02, 4.42):
                b.cyl(1.055, 1.055, 0.07, loc=(tx, ty, zz), material=m_stone_l, sides=12, weight=W_ROOT)
            # 塔身箭孔（朝外 3 个方向）
            ang = math.atan2(sy, sx)
            for k, zz in enumerate((2.35, 4.05)):
                a2 = ang + (k - 0.5) * 0.55
                arrow_loophole(b, tx + math.cos(a2) * 1.00, ty + math.sin(a2) * 1.00, zz,
                               a2, m_stone_l, m_glass)
            # 出挑 + 雉堞 + 锥顶
            b.cyl(1.17, 1.17, 0.16, loc=(tx, ty, 6.42), material=m_stone_l, sides=12, weight=W_ROOT)
            b.cyl(1.10, 1.10, 0.055, loc=(tx, ty, 6.54), material=m_mortar, sides=12, weight=W_ROOT)
            crenel_ring(b, tx, ty, 1.02, 6.58, 10, m_stone, h=0.34, thick=0.28)
            cone_roof_tiled(b, tx, ty, 0.94, 6.74, 8.30, m_roof, m_roof_d, m_gold,
                            sides=12, bands=6)

    # ---- 主屋顶：四坡叠瓦，脊顶 9.0 ----
    roof_hip_tiled(b, 0, 0, W, Dd, 5.05, 8.86, 2.10, m_roof, m_roof_d,
                   m_wood_d, m_gold, over=0.55, course=0.36, tile_w=0.46)

    # ---- 烟囱（后右，出屋面但低于主脊）----
    box(b, (0.74, 0.74, 3.10), (2.16, -2.34, 5.80), m_stone, bevel=0.02)
    for zz in (5.10, 6.10, 7.05):
        box(b, (0.82, 0.82, 0.09), (2.16, -2.34, zz), m_stone_l, bevel=0.008)
    box(b, (0.96, 0.96, 0.16), (2.16, -2.34, 7.42), m_stone_l, bevel=0.015)
    box(b, (0.52, 0.52, 0.10), (2.16, -2.34, 7.54), m_stone_d)

    # ---- 门 / 台阶 / 玫瑰窗 ----
    door_v4(b, 0.0, 3.10, 0.72, 1.76, 2.34,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_steel), planks=6)
    for i, (yy, zz, hh) in enumerate(((3.30, 0.57, 0.26), (3.52, 0.39, 0.24), (3.74, 0.21, 0.20))):
        box(b, (2.70, 0.30, hh), (0, yy, zz), m_stone_l, bevel=0.012)
    # 玫瑰窗：石圈 + 玻璃 + 金环 + 八根铁辐 + 金心
    b.cyl(0.66, 0.66, 0.12, loc=(0, 3.12, 4.10), rot=(D(90), 0, 0), material=m_stone_l,
          sides=12, weight=W_ROOT)
    b.cyl(0.56, 0.56, 0.03, loc=(0, 3.20, 4.10), rot=(D(90), 0, 0), material=m_glass,
          sides=12, weight=W_ROOT)
    b.cyl(0.59, 0.59, 0.045, loc=(0, 3.19, 4.10), rot=(D(90), 0, 0), material=m_gold,
          sides=12, weight=W_ROOT)
    for k in range(8):
        a = TAU * k / 8.0
        box(b, (0.045, 0.04, 0.50), (math.sin(a) * 0.25, 3.23, 4.10 + math.cos(a) * 0.25),
            m_iron, rot=(0, a, 0))
    b.ico(0.09, loc=(0, 3.24, 4.10), material=m_gold, subdiv=1, weight=W_ROOT)

    # ---- 窗 ----
    wmats = (m_stone_l, m_glass, m_stone_d, m_iron, m_wood_d, m_stone_l)
    window_v4(b, -2.25, 3.10, 3.18, 0.64, 0.96, wmats, shutters=True)
    window_v4(b, 2.25, 3.10, 3.18, 0.64, 0.96, wmats, shutters=True)
    window_v4(b, 3.20, 1.35, 3.18, 0.64, 0.96, wmats, yaw=-math.pi * 0.5, shutters=True)
    window_v4(b, 3.20, -1.35, 3.18, 0.64, 0.96, wmats, yaw=-math.pi * 0.5, shutters=True)
    window_v4(b, -3.20, 1.35, 3.18, 0.64, 0.96, wmats, yaw=math.pi * 0.5, shutters=True)
    window_v4(b, -3.20, -1.35, 3.18, 0.64, 0.96, wmats, yaw=math.pi * 0.5, shutters=True)
    window_v4(b, -2.05, -3.10, 3.18, 0.64, 0.96, wmats, yaw=math.pi, shutters=False)
    window_v4(b, 2.05, -3.10, 3.18, 0.64, 0.96, wmats, yaw=math.pi, shutters=False)

    # ---- 前墙两面旗 ----
    banner_v4(b, 1.95, 3.18, 3.42, 4.16, m_wood_d, m_cloth, m_gold, m_cloth, idx=0,
               dirx=1.0, diry=0.0, fw=0.82)
    banner_v4(b, -1.95, 3.18, 3.42, 4.16, m_wood_d, m_cloth, m_gold, m_cloth, idx=1,
               dirx=-1.0, diry=0.0, fw=0.82)
    for sx in (-1, 1):
        for zz in (3.52, 3.98):
            box(b, (0.10, 0.16, 0.07), (sx * 1.95, 3.22, zz), m_iron)

    # ---- 门侧壁柱（给正立面竖向节奏）----
    for sx in (-1, 1):
        box(b, (0.26, 0.16, 3.52), (sx * 1.22, 3.17, 2.50), m_stone_l, bevel=0.012)
        box(b, (0.36, 0.20, 0.14), (sx * 1.22, 3.18, 0.80), m_stone_d, bevel=0.01)
        box(b, (0.36, 0.20, 0.14), (sx * 1.22, 3.18, 4.28), m_stone_d, bevel=0.01)

    # ---- 门口挂灯 ----
    for sx in (-1, 1):
        box(b, (0.16, 0.26, 0.07), (sx * 1.28, 3.16, 2.62), m_iron)
        lantern(b, sx * 1.28, 3.30, 2.48, m_iron, m_ember, m_steel, h=0.34)

    # ---- 生活道具 ----
    barrel(b, 3.10, 2.28, 0.72, m_wood, m_iron)
    barrel(b, 2.66, 2.70, 0.72, m_wood, m_iron)
    crate(b, -3.05, 2.42, 0.72, 0.52, m_wood, m_wood_d, m_iron)
    woodpile(b, -3.02, 2.98, 0.72, m_wood, m_wood_d)
    b.cyl(0.20, 0.20, 0.10, loc=(3.02, 2.72, 0.72), material=m_stone_d, sides=10, weight=W_ROOT)

    # ---- 墙根草 ----
    for i in range(12):
        a = TAU * i / 12.0
        rr = 3.86
        b.ico(0.15, loc=(rr * math.cos(a), rr * math.sin(a), 0.72), material=m_leaf,
              subdiv=1, weight=W_ROOT, scale=(1.0, 1.0, 0.55))

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 2) 兵营 6x6x4.6
# ===========================================================================

def build_barracks():
    coll = K3.reset_scene()
    r = BuildingRig("barracks")
    r.add_flag(2.30, 1.65, 3.55, 4.22, dirx=1.0, diry=0.0)
    r.add_flag(-2.30, 1.65, 3.55, 4.22, dirx=-1.0, diry=0.0)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_plaster = mat("plaster")
    m_roof = mat("roof_red", team=True)
    m_roof_d = mat("roof_dark")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_mortar = mat("iron")
    m_steel = mat("steel_light")
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)
    m_hay = mat("hay")
    m_ember = mat("ember")

    b = Builder("barracks")
    # ---- 台基 6 x 5.5 ----
    box(b, (6.0, 5.5, 0.28), (0, 0, 0.14), m_stone_d, bevel=0.04)
    box(b, (5.80, 5.30, 0.07), (0, 0, 0.31), m_iron)
    box(b, (5.74, 5.24, 0.16), (0, 0, 0.42), m_stone_d, bevel=0.02)

    # ---- 主殿 5.0 x 4.0，z 0.50 -> 3.05 ----
    W, Dd, cy0 = 5.0, 3.8, -0.45
    z0, z1 = 0.50, 3.05
    wall_shell(b, 0, cy0, W, Dd, z0, z1, m_mortar, thick=0.34)
    door_hole = (0.0, 1.86, 0.50, 2.95)
    front_holes = [door_hole]
    side_holes = [(-1.02, 0.84, 1.55, 2.55), (1.02, 0.84, 1.55, 2.55)]
    back_holes = [(-1.10, 0.84, 1.55, 2.55), (1.10, 0.84, 1.55, 2.55)]
    stones = (m_stone, m_stone_l, m_stone_d)
    masonry_face(b, "+y", 0, cy0, W, Dd, z0, z1, stones, holes=front_holes, seed=71, row_h=0.33)
    masonry_face(b, "-y", 0, cy0, W, Dd, z0, z1, stones, holes=back_holes, seed=72, row_h=0.33)
    masonry_face(b, "+x", 0, cy0, W, Dd, z0, z1, stones, holes=side_holes, seed=73, row_h=0.33)
    masonry_face(b, "-x", 0, cy0, W, Dd, z0, z1, stones, holes=side_holes, seed=74, row_h=0.33)
    quoins(b, 0, cy0, W, Dd, z0, z1, (m_stone_l, m_stone), size=0.44, row_h=0.33)

    # ---- 双坡叠瓦 + 山墙木构 ----
    roof_gable_tiled(b, 0, cy0, W, Dd, z1, 4.42, m_roof, m_roof_d, m_wood_d, m_gold,
                     over=0.40, course=0.32, tile_w=0.42)
    for sx in (-1, 1):
        gable_wall(b, 0, cy0, sx * W * 0.5, W, Dd, z1 - 0.10, 4.40, m_plaster, thick=0.26)
        # 山墙露明木构：中柱 + 斜撑 + 系梁
        box(b, (0.12, 0.10, 1.40), (sx * (W * 0.5 + 0.02), cy0, 3.72), m_wood_d, bevel=0.008)
        box(b, (0.10, 0.10, 2.20), (sx * (W * 0.5 + 0.02), cy0, 3.12), m_wood_d, bevel=0.008)
        for sgn in (-1, 1):
            b.box((0.09, 0.09, 1.32), loc=(sx * (W * 0.5 + 0.03), cy0 + sgn * 0.62, 3.86),
                  rot=(math.radians(26) * sgn, 0, 0), material=m_wood_d, bevel=0.006)
        box(b, (0.10, Dd * 0.9, 0.12), (sx * (W * 0.5 + 0.02), cy0, 3.06), m_wood_d, bevel=0.008)

    # ---- 前廊：窄檐 + 双柱 + 石阶（不做满宽围栏，别把门挡死）----
    box(b, (4.40, 0.96, 0.14), (0, 2.00, 0.50), m_stone_l, bevel=0.02)
    for sx in (-1, 1):
        box(b, (0.17, 0.17, 2.30), (sx * 2.00, 2.26, 1.62), m_wood, bevel=0.012)
        box(b, (0.24, 0.24, 0.10), (sx * 2.00, 2.26, 0.54), m_stone_d, bevel=0.008)
        b.box((0.10, 0.10, 0.90), loc=(sx * 1.96, 1.62, 2.44),
              rot=(math.radians(34) * sx, 0, 0), material=m_wood_d, bevel=0.006)
    # 廊顶（从墙面 3.00 落到外沿 2.66）
    o = Vector((0.0, 2.38, 2.64))
    up = Vector((0.0, -0.92, 0.36)).normalized()
    run = math.sqrt(0.92 ** 2 + 0.36 ** 2)
    tile_slope(b, o, Vector((1, 0, 0)), up, 4.52, 4.52, run, m_roof, m_roof_d,
               course=0.28, tile_w=0.42, seed=8)
    box(b, (4.62, 0.13, 0.11), (0, 2.40, 2.60), m_wood_d, bevel=0.01)
    box(b, (4.62, 0.09, 0.05), (0, 2.42, 2.54), m_iron)
    for sx in (-1, 1):
        box(b, (0.10, 0.10, 0.55), (sx * 2.20, 2.10, 1.00), m_wood, bevel=0.005)
    box(b, (4.40, 0.08, 0.08), (0, 2.12, 1.24), m_wood_d, bevel=0.005)

    # ---- 大门 + 台阶 ----
    door_v4(b, 0.0, cy0 + Dd * 0.5, 0.50, 1.62, 2.18,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_steel), planks=6,
            arch_rise=0.22)
    for i, (yy, zz, hh) in enumerate(((2.46, 0.38, 0.22), (2.62, 0.21, 0.18))):
        box(b, (2.20, 0.24, hh), (0, yy, zz), m_stone_l, bevel=0.01)

    # ---- 前角塔（方形 + 雉堞 + 小锥顶）----
    for sx in (-1, 1):
        tx, ty = sx * 2.30, 1.95
        box(b, (1.00, 1.00, 3.40), (tx, ty, 1.70), m_stone, bevel=0.02)
        for zz in (0.82, 1.52, 2.22, 2.92):
            box(b, (1.07, 1.07, 0.07), (tx, ty, zz), m_stone_l, bevel=0.006)
        # 塔身箭孔
        arrow_loophole(b, tx, ty + 0.51, 2.36, math.pi * 0.5, m_stone_l, m_glass)
        crenel_ring(b, tx, ty, 0.62, 3.42, 8, m_stone_l, h=0.26, thick=0.20)
        b.cyl(0.56, 0.03, 0.64, loc=(tx, ty, 3.66), material=m_roof, sides=8, weight=W_ROOT)
        b.cyl(0.58, 0.58, 0.05, loc=(tx, ty, 3.64), material=m_roof_d, sides=8, weight=W_ROOT)
        b.ico(0.055, loc=(tx, ty, 4.32), material=m_gold, subdiv=1, weight=W_ROOT)
        banner_v4(b, tx, ty - 0.30, 3.55, 4.22, m_wood_d, m_cloth, m_gold, m_cloth,
                   idx=0 if sx < 0 else 1, dirx=float(sx), diry=0.0, fw=0.60)

    # ---- 侧窗 + 后窗 + 门楣上的小窗 ----
    wm = (m_stone_l, m_glass, m_stone_d, m_iron, m_wood_d, m_stone_l)
    for sy in (-1, 1):
        window_v4(b, 2.50, cy0 + sy * 0.92, 1.98, 0.62, 0.86, wm, yaw=-math.pi * 0.5, shutters=True)
        window_v4(b, -2.50, cy0 + sy * 0.92, 1.98, 0.62, 0.86, wm, yaw=math.pi * 0.5, shutters=True)
    for sx in (-1, 1):
        window_v4(b, sx * 1.10, cy0 - Dd * 0.5, 1.98, 0.62, 0.86, wm, yaw=math.pi, shutters=False)
    # 山墙小窗（三角里的圆窗感）
    window_v4(b, 2.63, cy0, 3.62, 0.40, 0.50, wm, yaw=-math.pi * 0.5, shutters=False)
    window_v4(b, -2.63, cy0, 3.62, 0.40, 0.50, wm, yaw=math.pi * 0.5, shutters=False)

    # ---- 檐下斜撑（木构外露）----
    for sx in (-1, 1):
        b.box((0.11, 0.11, 1.10), loc=(sx * 2.30, cy0 + Dd * 0.5 + 0.10, 2.46),
              rot=(math.radians(38) * sx, 0, 0), material=m_wood_d, bevel=0.006)

    # ---- 演武道具：武器架 / 训练靶 / 桶 / 箱 ----
    # 武器架
    for sx in (-1, 1):
        box(b, (0.10, 0.10, 1.20), (1.62 + sx * 0.55, 1.30, 0.60), m_wood_d, bevel=0.006)
    for zz in (0.95, 1.14):
        box(b, (1.30, 0.09, 0.09), (1.62, 1.30, zz), m_wood_d, bevel=0.005)
    for i in range(3):
        xx = 1.15 + i * 0.47
        box(b, (0.05, 0.02, 0.92), (xx, 1.24, 0.62), m_steel)
        box(b, (0.20, 0.04, 0.05), (xx, 1.24, 1.06), m_gold)
        box(b, (0.045, 0.04, 0.20), (xx, 1.24, 1.18), m_wood_d)
    # 圆盾
    b.cyl(0.34, 0.34, 0.07, loc=(2.30, 1.24, 0.95), rot=(D(90), 0, 0), material=m_cloth,
          sides=12, weight=W_ROOT)
    b.cyl(0.10, 0.10, 0.03, loc=(2.30, 1.18, 0.95), rot=(D(90), 0, 0), material=m_gold,
          sides=8, weight=W_ROOT)
    # 训练靶
    for i, xx in enumerate((-1.85, -1.25, -0.65)):
        box(b, (0.13, 0.13, 1.55), (xx, 0.55, 0.78), m_wood, bevel=0.008)
        box(b, (0.55, 0.10, 0.55), (xx, 0.55, 1.28), m_hay, bevel=0.01)
        b.cyl(0.19, 0.19, 0.09, loc=(xx, 0.52, 1.30), rot=(D(90), 0, 0), material=m_hay,
              sides=10, weight=W_ROOT)
        box(b, (0.50, 0.03, 0.06), (xx, 0.61, 1.12), m_wood_d)
        box(b, (0.06, 0.03, 0.50), (xx, 0.61, 1.30), m_wood_d)
    # 桶 / 箱 / 干草
    barrel(b, -2.35, 2.32, 0.50, m_wood, m_iron)
    crate(b, 2.30, 2.46, 0.50, 0.46, m_wood, m_wood_d, m_iron)
    hay_bale(b, -2.30, -2.10, 0.50, 0.60, m_hay, m_wood_d)

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 3) 铁匠铺 6x6x4.2
# ===========================================================================

def build_smithy():
    coll = K3.reset_scene()
    r = BuildingRig("smithy")
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_plaster = mat("plaster")
    m_roof = mat("roof_iron", team=True)
    m_roof_d = mat("roof_dark")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_mortar = mat("iron")
    m_steel = mat("steel_light")
    m_glass = mat("glass")
    m_ember = mat("ember")
    m_cloth = mat("cloth", team=True)

    b = Builder("smithy")
    # 台基 5.5 x 5.0
    box(b, (5.5, 5.0, 0.30), (0, 0, 0.15), m_stone_d, bevel=0.04)
    box(b, (5.28, 4.78, 0.07), (0, 0, 0.335), m_iron)

    # 墙体 4.6 x 4.2，z 0.37 -> 2.75
    W, Dd, cy0 = 4.6, 4.2, -0.15
    z0, z1 = 0.37, 2.75
    wall_shell(b, 0, cy0, W, Dd, z0, z1, m_mortar, thick=0.32)
    door_hole = (-0.90, 1.40, 0.37, 2.60)
    forge_hole = (0.95, 1.30, 0.37, 1.75)
    front_holes = [door_hole, forge_hole]
    side_holes = [(-0.85, 0.80, 1.35, 2.15), (0.95, 0.80, 1.35, 2.15)]
    stones = (m_stone, m_stone_l, m_stone_d)
    masonry_face(b, "+y", 0, cy0, W, Dd, z0, z1, stones, holes=front_holes, seed=81, row_h=0.31)
    masonry_face(b, "-y", 0, cy0, W, Dd, z0, z1, stones, holes=[], seed=82, row_h=0.31)
    masonry_face(b, "+x", 0, cy0, W, Dd, z0, z1, stones, holes=side_holes, seed=83, row_h=0.31)
    masonry_face(b, "-x", 0, cy0, W, Dd, z0, z1, stones, holes=side_holes, seed=84, row_h=0.31)
    quoins(b, 0, cy0, W, Dd, z0, z1, (m_stone_l, m_stone), size=0.42, row_h=0.31)

    # 陡坡叠瓦 + 山墙木构
    roof_gable_tiled(b, 0, cy0, W, Dd, z1, 3.99, m_roof, m_roof_d, m_wood_d, m_gold,
                     over=0.26, course=0.30, tile_w=0.40)
    for sx in (-1, 1):
        gable_wall(b, 0, cy0, sx * W * 0.5, W, Dd, z1 - 0.08, 3.97, m_plaster, thick=0.24)
        box(b, (0.11, 0.09, 1.20), (sx * (W * 0.5 + 0.02), cy0, 3.40), m_wood_d, bevel=0.006)
        box(b, (0.09, 0.09, 0.95), (sx * (W * 0.5 + 0.03), cy0 + 0.42, 3.62),
            rot=(0, math.radians(30), 0), material=m_wood_d, bevel=0.005)
        box(b, (0.09, 0.09, 0.95), (sx * (W * 0.5 + 0.03), cy0 - 0.42, 3.62),
            rot=(0, math.radians(30), 0), material=m_wood_d, bevel=0.005)

    # 烟囱：外挂石砌竖井（贴着右山墙，从地面起到 4.17，低于 4.2）
    box(b, (0.62, 0.86, 0.36), (2.36, -0.70, 0.48), m_stone_d, bevel=0.02)
    box(b, (0.52, 0.72, 3.46), (2.36, -0.70, 2.28), m_stone, bevel=0.02)
    for zz in (1.18, 2.10, 3.02):
        box(b, (0.58, 0.78, 0.07), (2.36, -0.70, zz), m_stone_l, bevel=0.006)
    box(b, (0.70, 0.90, 0.14), (2.36, -0.70, 4.03), m_stone_l, bevel=0.012)
    box(b, (0.32, 0.44, 0.08), (2.36, -0.70, 4.13), m_iron)

    # 门（浅券）+ 台阶
    door_v4(b, -0.90, cy0 + Dd * 0.5, 0.37, 1.34, 2.04,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_steel), planks=5,
            arch_rise=0.22)
    for i, (yy, zz, hh) in enumerate(((2.10, 0.32, 0.18), (2.26, 0.17, 0.14))):
        box(b, (1.80, 0.24, hh), (-0.90, yy, zz), m_stone_l, bevel=0.01)

    # 炉口：石拱 + 火光 + 灰口
    fy = cy0 + Dd * 0.5
    box(b, (1.16, 0.05, 1.20), (0.95, fy + 0.006, 0.98), m_stone_d)
    box(b, (0.82, 0.05, 0.56), (0.95, fy + 0.020, 0.92), m_ember)
    for i in range(3):
        box(b, (0.05, 0.07, 0.58), (0.70 + i * 0.25, fy + 0.050, 0.92), m_iron)
    box(b, (1.24, 0.12, 0.12), (0.95, fy + 0.05, 1.30), m_stone_l, bevel=0.008)
    for sx in (-1, 1):
        box(b, (0.14, 0.12, 0.98), (0.95 + sx * 0.62, fy + 0.05, 0.88), m_stone_l, bevel=0.008)
    box(b, (1.06, 0.10, 0.10), (0.95, fy + 0.06, 0.46), m_stone_l, bevel=0.006)
    # 烟罩（下宽上收，压住火口上方）
    b.add(K3._bm_loft([
        [(0.28, fy + 0.34, 1.40), (1.62, fy + 0.34, 1.40),
         (1.62, fy - 0.02, 1.40), (0.28, fy - 0.02, 1.40)],
        [(0.58, fy + 0.18, 2.28), (1.32, fy + 0.18, 2.28),
         (1.32, fy - 0.02, 2.28), (0.58, fy - 0.02, 2.28)],
    ], cap_a=False, cap_b=True), m_stone_d, W_ROOT)

    # 窗
    wm = (m_stone_l, m_glass, m_stone_d, m_iron, m_wood_d, m_stone_l)
    window_v4(b, 2.30, cy0 + 0.95, 1.78, 0.52, 0.66, wm, yaw=-math.pi * 0.5, shutters=False)
    window_v4(b, -2.30, cy0 + 0.95, 1.78, 0.52, 0.66, wm, yaw=math.pi * 0.5, shutters=False)
    window_v4(b, 0.0, cy0 - Dd * 0.5, 1.78, 0.56, 0.66, wm, yaw=math.pi, shutters=False)

    # 生活道具：铁砧 + 树桩 + 淬火桶 + 煤堆 + 工具架 + 风箱 + 招牌 + 挂灯
    ax, ay = 1.80, 1.82
    b.cyl(0.30, 0.26, 0.34, loc=(ax, ay, 0.30), material=m_wood_d, sides=8, weight=W_ROOT)
    box(b, (0.34, 0.62, 0.20), (ax, ay + 0.05, 0.57), m_iron, bevel=0.012)
    b.add(K3._bm_loft([
        [(ax - 0.16, ay + 0.33, 0.60), (ax + 0.16, ay + 0.33, 0.60),
         (ax + 0.16, ay + 0.33, 0.72), (ax - 0.16, ay + 0.33, 0.72)],
        [(ax - 0.10, ay + 0.62, 0.64), (ax + 0.10, ay + 0.62, 0.64),
         (ax + 0.10, ay + 0.62, 0.70), (ax - 0.10, ay + 0.62, 0.70)],
    ], cap_a=True, cap_b=True), m_iron, W_ROOT)
    box(b, (0.05, 0.05, 0.22), (ax, ay - 0.28, 0.68), m_iron)
    barrel(b, 2.28, 0.85, 0.30, m_wood, m_iron)
    # 煤堆
    for i in range(9):
        a = TAU * i / 9.0
        b.ico(0.13, loc=(1.20 + 0.26 * math.cos(a), 1.42 + 0.20 * math.sin(a), 0.36),
              material=m_iron, subdiv=1, weight=W_ROOT, scale=(1.0, 1.0, 0.7))
    # 工具架（墙上挂锤/钳）
    for i, xx in enumerate((-1.95, -1.70, -1.45)):
        box(b, (0.04, 0.16, 0.04), (xx, fy + 0.04, 1.95), m_iron)
        box(b, (0.035, 0.035, 0.46), (xx, fy + 0.06, 1.66), m_wood)
        box(b, (0.16, 0.05, 0.10), (xx, fy + 0.06, 1.42), m_iron, bevel=0.008)
    # 风箱（靠墙）
    box(b, (0.50, 0.30, 0.26), (1.85, fy - 0.30, 1.05), m_wood, bevel=0.02)
    box(b, (0.34, 0.16, 0.16), (1.85, fy - 0.10, 1.05), m_wood_d, bevel=0.01)
    # 招牌：挑臂 + 木牌 + 金马蹄
    box(b, (0.10, 0.10, 0.90), (-2.10, fy + 0.05, 2.55), m_wood_d, bevel=0.006)
    box(b, (0.60, 0.06, 0.42), (-2.10, fy + 0.30, 2.28), m_wood, bevel=0.01)
    ring = [(-2.10 + 0.16 * math.cos(TAU * k / 10), fy + 0.34,
             2.28 + 0.16 * math.sin(TAU * k / 10)) for k in range(11)]
    b.tube(ring, 0.018, m_gold, weight=W_ROOT, sides=4)
    lantern(b, -0.90 + 1.10, fy + 0.18, 2.30, m_iron, m_ember, m_steel, h=0.30)
    crate(b, 1.95, -1.90, 0.30, 0.44, m_wood, m_wood_d, m_iron)
    hay_bale(b, -2.15, -1.80, 0.30, 0.48, mat("hay"), m_wood_d)

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ---------------------------------------------------------------------------
# v4 箭塔：方塔石砌 + 木廊 + 锥顶叠瓦 + 箭孔
# ---------------------------------------------------------------------------
def build_tower():
    coll = K3.reset_scene()
    r = BuildingRig("tower")
    r.add_flag(0.0, 1.30, 6.15, 7.15, dirx=0.0, diry=1.0)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_roof = mat("roof_tower", team=True)
    m_roof_d = mat("roof_dark")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_mortar = mat("iron")
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)
    m_ember = mat("ember")

    b = Builder("tower")
    # 三级基座 3x3
    box(b, (3.0, 3.0, 0.36), (0, 0, 0.18), m_stone_d, bevel=0.04)
    box(b, (2.84, 2.84, 0.16), (0, 0, 0.44), m_stone, bevel=0.025)
    # 塔身 2.4 x 2.4，z 0.52 -> 6.05
    W, Dd, z0, z1 = 2.40, 2.40, 0.52, 6.05
    wall_shell(b, 0, 0, W, Dd, z0, z1, m_mortar, thick=0.30)
    holes = [(0.0, 0.94, 0.52, 2.25)]
    stones = (m_stone, m_stone_l, m_stone_d)
    masonry_face(b, "+y", 0, 0, W, Dd, z0, z1, stones, holes=holes, seed=91, row_h=0.30)
    masonry_face(b, "-y", 0, 0, W, Dd, z0, z1, stones, holes=[], seed=92, row_h=0.30)
    masonry_face(b, "+x", 0, 0, W, Dd, z0, z1, stones, holes=[], seed=93, row_h=0.30)
    masonry_face(b, "-x", 0, 0, W, Dd, z0, z1, stones, holes=[], seed=94, row_h=0.30)
    quoins(b, 0, 0, W, Dd, z0, z1, (m_stone_l, m_stone), size=0.34, row_h=0.30)

    # 箭孔
    for zz in (2.55, 3.55, 4.55):
        for a in (0.0, math.pi * 0.5, math.pi, -math.pi * 0.5):
            rr = 0.5 * (W if abs(math.sin(a)) < 0.5 else Dd) + 0.012
            px = math.cos(a) * rr
            py = math.sin(a) * rr
            arrow_loophole(b, px, py, zz, a, m_stone_l, m_glass, w=0.30, h=0.72)

    # 出挑 + 木廊 + 栏板
    box(b, (2.78, 2.78, 0.16), (0, 0, 6.05), m_stone_l, bevel=0.02)
    # 出挑石托（8 个）
    for i in range(8):
        a = TAU * (i + 0.5) / 8.0
        box(b, (0.30, 0.22, 0.20), (1.34 * math.cos(a), 1.34 * math.sin(a), 5.96),
            m_stone_d, rot=(0, 0, a), bevel=0.008)
    box(b, (2.72, 2.72, 0.10), (0, 0, 6.16), m_wood_d, bevel=0.01)
    # 实心木栏板 + 压顶
    for (sx, sy) in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        if sx != 0:
            box(b, (0.07, 2.60, 0.38), (sx * 1.30, 0, 6.40), m_wood)
            box(b, (0.10, 2.66, 0.07), (sx * 1.30, 0, 6.60), m_wood_d, bevel=0.006)
            for k in range(7):
                box(b, (0.035, 0.04, 0.38), (sx * 1.34, -1.14 + k * 0.38, 6.40), m_wood_d)
        else:
            box(b, (2.60, 0.07, 0.38), (0, sy * 1.30, 6.40), m_wood)
            box(b, (2.66, 0.10, 0.07), (0, sy * 1.30, 6.60), m_wood_d, bevel=0.006)
            for k in range(7):
                box(b, (0.04, 0.035, 0.38), (-1.14 + k * 0.38, sy * 1.34, 6.40), m_wood_d)

    # 锥顶叠瓦（顶尖 7.90）
    cone_roof_tiled(b, 0, 0, 1.30, 6.62, 7.89, m_roof, m_roof_d, m_gold, sides=12, bands=6)
    b.ico(0.08, loc=(0, 0, 7.98), material=m_gold, subdiv=1, weight=W_ROOT)

    # 门 + 台阶 + 火把
    door_v4(b, 0.0, Dd * 0.5, 0.52, 0.92, 1.62,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_stone_l), planks=4,
            arch_rise=0.18)
    for i, (yy, zz, hh) in enumerate(((1.28, 0.30, 0.16), (1.42, 0.16, 0.12))):
        box(b, (1.30, 0.22, hh), (0, yy, zz), m_stone_l, bevel=0.01)
    for sx in (-1, 1):
        box(b, (0.10, 0.10, 0.24), (sx * 0.62, Dd * 0.5 + 0.10, 1.62), m_iron)
        lantern(b, sx * 0.62, Dd * 0.5 + 0.24, 1.44, m_iron, m_ember, m_stone_l, h=0.28)

    # 平台旗（挂在木廊上，不超出 8m）
    banner_v4(b, 0.0, 1.30, 6.15, 7.05, m_wood_d, m_cloth, m_gold, m_cloth, idx=0,
              dirx=0.0, diry=1.0, fw=0.72)
    # 塔基草
    for i in range(8):
        a = TAU * i / 8.0
        b.ico(0.14, loc=(1.48 * math.cos(a), 1.48 * math.sin(a), 0.34),
              material=mat("leaf_dark"), subdiv=1, weight=W_ROOT, scale=(1.0, 1.0, 0.5))

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 4) 哨塔 3x3x8
# ===========================================================================

def build_farm():
    coll = K3.reset_scene()
    r = BuildingRig("farm")
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_plaster = mat("plaster")
    m_hay = mat("hay")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_mortar = mat("iron")
    m_glass = mat("glass")
    m_dirt = mat("dirt")
    m_leaf = mat("leaf")
    m_leaf_d = mat("leaf_dark")
    m_cloth = mat("cloth", team=True)

    b = Builder("farm")
    # 地块底板 4 x 4
    box(b, (4.0, 4.0, 0.16), (0, 0, 0.08), m_dirt, bevel=0.01)
    for i in range(9):
        xx = -1.85 + i * 0.46
        b.ico(0.10, loc=(xx, -1.86, 0.17), material=m_leaf_d if i % 2 else mat("grass"),
              subdiv=1, weight=W_ROOT, scale=(1.0, 0.8, 0.5))

    # 小屋 2.2 x 1.8（z 0.16 -> 1.72），墙裙石 + 上白灰
    cx0, cy0, W, Dd = -0.66, -0.78, 2.20, 1.80
    z0, z1 = 0.16, 1.72
    box(b, (W + 0.16, Dd + 0.16, 0.22), (cx0, cy0, 0.27), m_stone_d, bevel=0.02)
    wall_shell(b, cx0, cy0, W, Dd, z0, z1, m_mortar, thick=0.22)
    door_hole = (0.0, 0.94, 0.16, 1.62)
    masonry_face(b, "+y", cx0, cy0, W, Dd, 0.34, 0.86, (m_stone, m_stone_l, m_stone_d),
                 holes=[], seed=101, row_h=0.26)
    # 上部白灰墙（覆盖石壳）
    box(b, (W + 0.02, 0.06, 0.86), (cx0, cy0 + Dd * 0.5 + 0.01, 1.30), m_plaster)
    box(b, (W + 0.02, 0.06, 0.86), (cx0, cy0 - Dd * 0.5 - 0.01, 1.30), m_plaster)
    box(b, (0.06, Dd + 0.02, 0.86), (cx0 + W * 0.5 + 0.01, cy0, 1.30), m_plaster)
    box(b, (0.06, Dd + 0.02, 0.86), (cx0 - W * 0.5 - 0.01, cy0, 1.30), m_plaster)
    # 露明木框
    for sx in (-1, 1):
        box(b, (0.09, 0.09, 0.92), (cx0 + sx * W * 0.5, cy0 + Dd * 0.5 + 0.03, 1.30), m_wood_d)
        box(b, (0.09, 0.09, 0.92), (cx0 + sx * W * 0.5, cy0 - Dd * 0.5 - 0.03, 1.30), m_wood_d)
    box(b, (W + 0.04, 0.08, 0.09), (cx0, cy0 + Dd * 0.5 + 0.03, 1.34), m_wood_d)
    box(b, (0.09, 0.09, 0.88), (cx0, cy0 + Dd * 0.5 + 0.03, 1.30), m_wood_d)

    # 茅草顶（叠层 + 屋脊草捆）
    roof_gable_tiled(b, cx0, cy0, W, Dd, z1, 2.42, m_hay, m_dirt, m_wood_d, m_gold,
                     over=0.21, course=0.17, tile_w=0.68)
    # 屋脊草捆（细）+ 三道捆绳
    b.cyl(0.11, 0.11, W + 0.26, loc=(cx0 - (W + 0.26) * 0.5, cy0, 2.44),
          rot=(0, D(90), 0), material=m_hay, sides=8, weight=W_ROOT)
    for i in range(4):
        b.cyl(0.125, 0.125, 0.05, loc=(cx0 - 0.78 + i * 0.52, cy0, 2.44),
              rot=(0, D(90), 0), material=m_wood_d, sides=8, weight=W_ROOT)
    for sx in (-1, 1):
        box(b, (0.09, 0.16, 0.26), (cx0 + sx * (W * 0.5 + 0.22), cy0, 2.26), m_wood_d, bevel=0.006)
        # 山墙三角（补上，否则屋顶两头是敞开的）
        gable_wall(b, cx0, cy0, cx0 + sx * W * 0.5, W, Dd, z1 - 0.04, 2.38, m_plaster, thick=0.18)

    # 门 + 窗
    door_v4(b, cx0, cy0 + Dd * 0.5, 0.16, 0.88, 1.48,
            (m_wood_d, m_wood, m_stone_d, m_iron, m_wood, m_gold), planks=4, arch_rise=0.12)
    wm = (m_wood_d, m_glass, m_stone_d, m_iron, m_wood_d, m_gold)
    window_v4(b, cx0 + 0.78, cy0 + Dd * 0.5, 1.24, 0.42, 0.46, wm, shutters=False)
    window_v4(b, cx0 + W * 0.5, cy0, 1.24, 0.42, 0.46, wm, yaw=-math.pi * 0.5, shutters=False)

    # 田垄（右侧三垄 + 苗）
    for i in range(3):
        yy = -1.30 + i * 0.62
        box(b, (1.16, 0.34, 0.10), (1.18, yy, 0.24), m_dirt, bevel=0.02)
        for j in range(6):
            b.ico(0.075, loc=(0.66 + j * 0.22, yy, 0.34), material=m_leaf, subdiv=1,
                  weight=W_ROOT, scale=(1.0, 1.0, 1.35))
    # 田边矮篱
    for i in range(4):
        xx = 0.56
        box(b, (0.06, 0.06, 0.48), (xx, -1.55 + i * 0.62, 0.24), m_wood, bevel=0.004)

    # 围栏（4 边 + 前门缺口）
    def fence_run(x0, y0, x1, y1, n):
        for i in range(n + 1):
            t = i / float(n)
            px = x0 + (x1 - x0) * t
            py = y0 + (y1 - y0) * t
            box(b, (0.08, 0.08, 0.80), (px, py, 0.40), m_wood, bevel=0.006)
        for zz in (0.34, 0.64):
            box(b, (abs(x1 - x0) + 0.06 if abs(x1 - x0) > abs(y1 - y0) else 0.06, 0.06, 0.07),
                ((x0 + x1) * 0.5, (y0 + y1) * 0.5, zz), m_wood, bevel=0.004)
    fence_run(-1.92, -1.92, 1.92, -1.92, 8)
    fence_run(-1.92, 1.92, -0.46, 1.92, 4)
    fence_run(0.46, 1.92, 1.92, 1.92, 4)
    fence_run(-1.92, -1.92, -1.92, 1.92, 6)
    fence_run(1.92, -1.92, 1.92, 1.92, 6)


    # 手推车（生活道具）
    box(b, (0.62, 0.36, 0.16), (0.90, -1.52, 0.34), m_wood, bevel=0.012)
    for sx in (-1, 1):
        b.cyl(0.17, 0.17, 0.06, loc=(0.90 + sx * 0.32, -1.52, 0.24), rot=(0, D(90), 0),
              material=m_wood_d, sides=10, weight=W_ROOT)
        b.cyl(0.05, 0.05, 0.07, loc=(0.90 + sx * 0.32, -1.52, 0.24), rot=(0, D(90), 0),
              material=m_iron, sides=6, weight=W_ROOT)
    for sx in (-1, 1):
        box(b, (0.03, 0.46, 0.03), (0.90 + sx * 0.16, -1.22, 0.38), m_wood_d, bevel=0.004)
    # 车斗里的草
    b.ico(0.16, loc=(0.90, -1.52, 0.44), material=m_hay, subdiv=1, weight=W_ROOT,
          scale=(1.4, 0.8, 0.5))
    # 干草堆 / 水桶 / 麻袋
    hay_bale(b, -1.55, 1.30, 0.16, 0.55, m_hay, m_wood_d)
    hay_bale(b, 1.52, -1.55, 0.16, 0.45, m_hay, m_wood_d)
    barrel(b, -1.55, 0.42, 0.16, m_wood, m_iron)
    b.ico(0.20, loc=(1.62, 1.55, 0.36), material=m_cloth, subdiv=1, weight=W_ROOT,
          scale=(1.0, 0.8, 1.2))
    box(b, (0.06, 0.06, 0.05), (1.62, 1.55, 0.52), m_iron)


    # 菜畦边界石 + 靠墙木梯 + 水桶（补足细节密度）
    for i in range(10):
        box(b, (0.14, 0.14, 0.12), (0.52, -1.62 + i * 0.34, 0.22),
            m_stone_d if i % 3 else m_stone_l, bevel=0.012)
    for i in range(4):
        box(b, (0.55, 0.05, 0.05), (cx0 + W * 0.5 + 0.12, cy0 - 0.40 + i * 0.28, 0.30 + i * 0.28),
            m_wood, rot=(0, D(-58), 0), bevel=0.004)
    for sx in (-1, 1):
        box(b, (0.05, 0.05, 1.35), (cx0 + W * 0.5 + 0.10 + sx * 0.14, cy0 - 0.55, 0.85),
            m_wood_d, rot=(D(-12), 0, 0), bevel=0.004)
    b.cyl(0.11, 0.09, 0.20, loc=(0.62, 1.55, 0.16), material=m_wood, sides=8, weight=W_ROOT)
    b.cyl(0.115, 0.115, 0.03, loc=(0.62, 1.55, 0.35), material=m_iron, sides=8, weight=W_ROOT)
    hay_bale(b, 0.10, -1.55, 0.16, 0.42, m_hay, m_wood_d)

    # 稻草人（一眼认得出的生活道具）
    sx0, sy0 = 1.15, 0.35
    box(b, (0.07, 0.07, 1.55), (sx0, sy0, 0.94), m_wood_d, bevel=0.004)
    box(b, (0.86, 0.06, 0.06), (sx0, sy0, 1.28), m_wood_d, bevel=0.004)
    box(b, (0.42, 0.16, 0.46), (sx0, sy0, 1.10), m_cloth, bevel=0.01)
    for sxx in (-1, 1):
        box(b, (0.24, 0.10, 0.10), (sx0 + sxx * 0.32, sy0, 1.28), m_cloth, bevel=0.006)
    b.ico(0.17, loc=(sx0, sy0, 1.48), material=m_hay, subdiv=1, weight=W_ROOT,
          scale=(1.0, 1.0, 1.05))
    b.cyl(0.24, 0.03, 0.20, loc=(sx0, sy0, 1.60), material=m_hay, sides=8, weight=W_ROOT)
    box(b, (0.30, 0.02, 0.02), (sx0, sy0 + 0.15, 1.48), m_wood_d)

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


BUILDERS = {
    "townhall": build_townhall,
    "barracks": build_barracks,
    "smithy": build_smithy,
    "tower": build_tower,
    "farm": build_farm,
}

FILE_OF = {
    "townhall": "大本营.glb",
    "barracks": "兵营.glb",
    "smithy": "铁匠铺.glb",
    "tower": "箭塔.glb",
    "farm": "农场.glb",
}


def main():
    import argparse
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    which = args[0] if args else "townhall"
    do_qc = "--qc" in args
    do_export = "--export" in args
    names = list(BUILDERS.keys()) if which == "all" else [which]

    reports = []
    for nm in names:
        r, objs = BUILDERS[nm]()
        r.rest_pose()
        mn, mx = K3.bbox(objs)
        rep = {"name": nm, "size": [round(v, 2) for v in (mx - mn)],
               "zmin": round(mn.z, 2), "zmax": round(mx.z, 2)}
        if do_qc:
            r.preview_action("idle", 14)
            center = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            radius = max(mx.x - mn.x, mx.z - mn.z) * 0.5
            K3.render_views(nm, QC_DIR, center, max(radius, 1.2) * 1.32, res=(900, 1170),
                            views={"正": (0.0, 1.0, 0.18), "三四": (0.85, 1.0, 0.30)})
            # 近景细节（门/窗/屋面/砌石）
            K3.render_views(nm, QC_DIR, (0.0, 0.0, mn.z + (mx.z - mn.z) * 0.34),
                            max(radius, 1.2) * 0.62, res=(1200, 1200),
                            views={"近": (0.88, 1.0, 0.16)})
        if do_export:
            r.resume_nla()
            rep.update(K3.export_glb(os.path.join(OUT_DIR, FILE_OF[nm])))
        reports.append(rep)
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
        for act in list(bpy.data.actions):
            bpy.data.actions.remove(act)
    print("HEADLESS " + json.dumps(reports, ensure_ascii=False))


if __name__ == "__main__":
    main()
