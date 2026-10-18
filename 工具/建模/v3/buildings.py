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
# 1) 城镇/大本营 8x8x9
# ===========================================================================

def build_townhall():
    coll = K3.reset_scene()
    r = BuildingRig("townhall")
    r.add_flag(2.55, 3.25, 6.0, 8.3)
    r.add_flag(-2.55, 3.25, 6.0, 8.3)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_roof = mat("roof", team=True)
    m_roof_d = mat("roof_dark")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)

    b = Builder("townhall")
    # 台基
    box(b, (8.0, 8.0, 0.55), (0, 0, 0.27), m_stone_d, bevel=0.04)
    box(b, (7.4, 7.4, 0.18), (0, 0, 0.63), m_stone, bevel=0.03)
    # 主殿
    stone_wall(b, 0, 0, 6.2, 6.0, 0.7, 4.7, m_stone, m_stone_d, rows=7, thick=0.34)
    # 女儿墙 + 雉堞（四周）
    for (cx, cy, w, d, ax) in ((0, 3.0, 6.2, 0.0, "x"), (0, -3.0, 6.2, 0.0, "x")):
        box(b, (w, 0.30, 0.42), (cx, cy, 4.9), m_stone_l, bevel=0.02)
        crenel_line(b, cx, cy, w, 0.3, 5.1, m_stone, axis="x")
    for sx in (-1, 1):
        box(b, (0.30, 6.0, 0.42), (sx * 3.1, 0, 4.9), m_stone_l, bevel=0.02)
        crenel_line(b, sx * 3.1, 0, 6.0, 0.3, 5.1, m_stone, axis="y")
    # 大屋顶（主殿）
    b.add(K3._bm_loft([
        [(-3.4, -3.3, 5.1), (3.4, -3.3, 5.1), (3.4, 3.3, 5.1), (-3.4, 3.3, 5.1)],
        [(-2.1, -1.9, 7.15), (2.1, -1.9, 7.15), (2.1, 1.9, 7.15), (-2.1, 1.9, 7.15)],
        [(-0.9, -0.5, 8.25), (0.9, -0.5, 8.25), (0.9, 0.5, 8.25), (-0.9, 0.5, 8.25)],
    ], cap_a=False, cap_b=True), m_roof, W_ROOT)
    # 屋面金脊 + 檐口
    box(b, (4.4, 0.20, 0.16), (0, 0, 8.26), m_gold, bevel=0.02)
    for sy in (-1, 1):
        box(b, (7.0, 0.16, 0.16), (0, sy * 3.32, 5.06), m_gold, bevel=0.02)
    # 老虎窗（正面两个）
    for sx in (-1, 1):
        box(b, (0.85, 0.55, 0.85), (sx * 1.5, 3.05, 5.55), m_wood, bevel=0.02)
        b.add(K3._bm_loft([
            [(sx * 1.5 - 0.50, 2.75, 5.95), (sx * 1.5 + 0.50, 2.75, 5.95),
             (sx * 1.5 + 0.50, 3.30, 5.95), (sx * 1.5 - 0.50, 3.30, 5.95)],
            [(sx * 1.5, 2.75, 6.55), (sx * 1.5, 2.75, 6.55),
             (sx * 1.5, 3.30, 6.55), (sx * 1.5, 3.30, 6.55)],
        ], cap_a=True, cap_b=True), m_roof_d, W_ROOT)
        window(b, sx * 1.5, 3.34, 5.55, w=0.42, h=0.5, m_frame=m_gold, m_glass=m_glass)
    # 四角圆塔
    for sx in (-1, 1):
        for sy in (-1, 1):
            tx, ty = sx * 3.15, sy * 3.15
            b.cyl(1.02, 0.94, 6.4, loc=(tx, ty, 0.55), material=m_stone, sides=12, weight=W_ROOT)
            # 塔身砌块压条
            for zz in (1.6, 3.2, 4.8, 6.1):
                b.cyl(1.05, 1.05, 0.10, loc=(tx, ty, zz), material=m_stone_l, sides=12, weight=W_ROOT)
            crenel_ring(b, tx, ty, 0.98, 6.95, 10, m_stone_l, h=0.36)
            cone_roof(b, tx, ty, 0.98, 6.95, 1.55, m_roof, m_gold, sides=12, over=0.18)
            # 塔窗
            for i in range(2):
                a = math.atan2(sy, sx) + (i - 0.5) * 0.7
                window(b, tx + math.cos(a) * 0.94, ty + math.sin(a) * 0.94, 3.0 + i * 1.4,
                       rot=a - math.pi * 0.5, w=0.22, h=0.46, m_frame=m_stone_l, m_glass=m_glass)
    # 正面门楼 + 拱门 + 台阶（门楼只比墙面出 0.35m，别做成一块大石板）
    box(b, (3.0, 0.40, 2.9), (0, 3.22, 1.45), m_stone, bevel=0.03)
    arch_door(b, 0, 3.44, 0.15, 1.45, 2.05, m_stone_l, m_wood_d, m_gold)
    steps(b, 0, 3.75, 2.2, 0.20, 3, m_stone_l)
    # 门楣金饰 + 盾徽
    box(b, (1.9, 0.14, 0.20), (0, 3.46, 2.45), m_gold, bevel=0.02)
    b.poly([(0, 0.42), (0.34, 0.30), (0.34, -0.10), (0, -0.42), (-0.34, -0.10), (-0.34, 0.30)],
           0.09, m_cloth, loc=(0, 3.42, 3.30), rot=(D(90), 0, 0), weight=W_ROOT)
    b.poly([(0, 0.28), (0.22, 0.19), (0.22, -0.05), (0, -0.26), (-0.22, -0.05), (-0.22, 0.19)],
           0.05, m_gold, loc=(0, 3.47, 3.30), rot=(D(90), 0, 0), weight=W_ROOT)
    # 木回廊（二层正面）
    box(b, (5.2, 0.65, 0.16), (0, 2.85, 3.35), m_wood, bevel=0.02)
    for i in range(6):
        xx = -2.4 + i * 0.96
        box(b, (0.14, 0.14, 0.95), (xx, 3.05, 3.9), m_wood_d, bevel=0.01)
    box(b, (5.0, 0.12, 0.10), (0, 3.05, 4.34), m_wood_d, bevel=0.01)
    # 窗
    for sx in (-1, 1):
        for zz in (1.75, 3.05):
            window(b, sx * 2.35, 3.02, zz, w=0.30, h=0.62, m_frame=m_stone_l, m_glass=m_glass)
    # 旗
    banner(b, 2.55, 3.25, 6.0, 8.3, m_wood_d, m_cloth, m_gold, dirx=0.0, diry=1.0, idx=0)
    banner(b, -2.55, 3.25, 6.0, 8.3, m_wood_d, m_cloth, m_gold, dirx=0.0, diry=1.0, idx=1)
    # 墙基杂草点缀
    for i in range(10):
        a = TAU * i / 10.0
        b.ico(0.16, loc=(3.9 * math.cos(a), 3.9 * math.sin(a), 0.62), material=mat("leaf_dark"),
              subdiv=1, weight=W_ROOT, scale=(1.0, 1.0, 0.5))

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
    r.add_flag(2.35, 2.45, 3.9, 5.2)
    r.add_flag(-2.35, 2.45, 3.9, 5.2)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_roof = mat("roof", team=True)
    m_roof_d = mat("roof_dark")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)

    b = Builder("barracks")
    box(b, (6.0, 6.0, 0.35), (0, 0, 0.17), m_stone_d, bevel=0.03)
    stone_wall(b, 0, -0.35, 5.0, 4.4, 0.35, 3.25, m_stone, m_stone_d, rows=5, thick=0.32)
    # 双坡屋顶（沿 X 起脊）
    gable_roof(b, 0, -0.35, 5.0, 4.4, 3.25, 2.15, m_roof, m_gold, over=0.45)
    # 前廊（木柱 + 人字棚）
    box(b, (4.4, 2.0, 0.18), (0, 1.9, 0.36), m_stone_l, bevel=0.02)
    for sx in (-1, 1):
        for yy in (1.2, 2.6):
            box(b, (0.18, 0.18, 2.5), (sx * 2.0, yy, 1.6), m_wood, bevel=0.015)
    box(b, (4.6, 0.22, 0.22), (0, 1.2, 2.92), m_wood_d, bevel=0.02)
    box(b, (4.6, 0.22, 0.22), (0, 2.6, 2.92), m_wood_d, bevel=0.02)
    b.add(K3._bm_loft([
        [(-2.3, 2.85, 3.0), (2.3, 2.85, 3.0), (2.3, 2.85, 3.22), (-2.3, 2.85, 3.22)],
        [(-2.3, 1.05, 3.0), (2.3, 1.05, 3.0), (2.3, 1.05, 3.22), (-2.3, 1.05, 3.22)],
    ], cap_a=True, cap_b=True), m_wood_d, W_ROOT)
    # 大门拱
    arch_door(b, 0, 0.55, 0.36, 2.0, 2.1, m_stone_l, m_wood_d, m_gold)
    # 两座前角塔
    for sx in (-1, 1):
        tx, ty = sx * 2.35, 2.35
        b.cyl(0.72, 0.66, 3.9, loc=(tx, ty, 0.35), material=m_stone, sides=10, weight=W_ROOT)
        for zz in (1.2, 2.4, 3.5):
            b.cyl(0.75, 0.75, 0.08, loc=(tx, ty, zz), material=m_stone_l, sides=10, weight=W_ROOT)
        crenel_ring(b, tx, ty, 0.70, 4.25, 8, m_stone_l, h=0.30)
        cone_roof(b, tx, ty, 0.70, 4.25, 1.05, m_roof, m_gold, sides=10, over=0.14)
    # 侧面窗
    for sx in (-1, 1):
        for i in range(2):
            window(b, sx * 2.52, -0.9 - i * 1.6, 2.0, rot=0.0, w=0.26, h=0.5,
                   m_frame=m_stone_l, m_glass=m_glass,)
    # 正面墙垛
    crenel_line(b, 0, 2.55, 5.0, 0.3, 3.25, m_stone_l, axis="x", h=0.34)
    # 旗帜（挂在塔上）
    banner(b, 2.35, 2.45, 3.9, 5.2, m_wood_d, m_cloth, m_gold, idx=0)
    banner(b, -2.35, 2.45, 3.9, 5.2, m_wood_d, m_cloth, m_gold, idx=1)
    # 训练场道具：木桩 + 靶子 + 桶
    for i in range(3):
        box(b, (0.16, 0.16, 1.1), (-2.2 + i * 1.3, 3.6, 0.55), m_wood, bevel=0.02)
        b.cyl(0.26, 0.26, 0.10, loc=(-2.2 + i * 1.3, 3.6, 1.05), material=m_gold, sides=10)
    barrel(b, 2.6, -2.5, 0.0, m_wood, m_iron := mat("iron"))
    box(b, (0.6, 0.6, 0.55), (1.9, 3.2, 0.28), m_wood, bevel=0.03)

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
    m_roof = mat("roof", team=True)
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_ember = mat("ember")
    m_glass = mat("glass")
    m_plaster = mat("plaster")

    b = Builder("smithy")
    box(b, (5.2, 5.0, 0.30), (0, 0, 0.15), m_stone_d, bevel=0.03)
    stone_wall(b, 0, 0, 4.6, 4.0, 0.30, 2.75, m_stone, m_stone_d, rows=5, thick=0.32)
    # 陡双坡顶
    gable_roof(b, 0, 0, 4.6, 4.0, 2.75, 1.75, m_roof, m_gold, over=0.42)

    # 烟囱
    b.cyl(0.62, 0.52, 5.0, loc=(-1.55, -1.55, 0.3), material=m_stone, sides=10, weight=W_ROOT)
    for zz in (1.4, 2.8, 4.2):
        b.cyl(0.64, 0.64, 0.12, loc=(-1.55, -1.55, zz), material=m_stone_l, sides=10, weight=W_ROOT)
    b.cyl(0.72, 0.66, 0.28, loc=(-1.55, -1.55, 5.25), material=m_gold, sides=10, weight=W_ROOT)
    # 炉口（发光）
    box(b, (1.25, 0.42, 1.05), (0.9, 2.02, 1.0), m_stone_l, bevel=0.03)
    b.add(K3._bm_loft([
        [(0.45, 2.24, 0.48), (1.35, 2.24, 0.48), (1.35, 2.30, 0.48), (0.45, 2.30, 0.48)],
        [(0.58, 2.24, 1.42), (1.22, 2.24, 1.42), (1.22, 2.30, 1.42), (0.58, 2.30, 1.42)],
    ], cap_a=True, cap_b=True), m_ember, W_ROOT)
    # 门
    arch_door(b, -0.95, 2.02, 0.30, 1.25, 1.75, m_stone_l, m_wood_d, m_gold)
    # 金饰门楣
    box(b, (1.7, 0.16, 0.16), (-0.95, 2.10, 2.15), m_gold, bevel=0.02)
    # 窗
    window(b, 1.65, 2.02, 2.05, w=0.30, h=0.52, m_frame=m_gold, m_glass=m_glass)
    for sy in (-1, 1):
        window(b, 2.32, sy * 0.9, 1.75, rot=D(90), w=0.26, h=0.5,
               m_frame=m_stone_l, m_glass=m_glass)
    # 屋檐下木托架
    for i in range(5):
        xx = -1.8 + i * 0.9
        box(b, (0.14, 0.55, 0.18), (xx, 2.22, 2.62), m_wood_d, bevel=0.01)
    # 铁砧
    box(b, (0.30, 0.55, 0.18), (1.55, 3.15, 0.62), m_iron, bevel=0.02)
    b.add(K3._bm_loft([
        [(1.42, 3.42, 0.70), (1.68, 3.42, 0.70), (1.68, 3.52, 0.70), (1.42, 3.52, 0.70)],
        [(1.48, 3.46, 0.76), (1.62, 3.46, 0.76), (1.62, 3.50, 0.76), (1.48, 3.50, 0.76)],
    ], cap_a=True, cap_b=True), m_iron, W_ROOT)
    box(b, (0.26, 0.26, 0.50), (1.55, 3.15, 0.25), m_wood_d, bevel=0.02)
    # 桶 + 煤堆 + 木箱
    barrel(b, -1.9, 3.05, 0.0, m_wood, m_iron)
    barrel(b, -1.45, 3.25, 0.0, m_wood, m_iron)
    for i in range(7):
        a = TAU * i / 7.0
        b.ico(0.17, loc=(2.0 + 0.28 * math.cos(a), 2.55 + 0.28 * math.sin(a), 0.16),
              material=mat("stone_dark"), subdiv=1, weight=W_ROOT, scale=(1.0, 1.0, 0.7))
    box(b, (0.55, 0.55, 0.50), (2.05, 3.25, 0.25), m_wood, bevel=0.02)
    # 招牌（挑臂 + 木牌）
    box(b, (0.12, 1.0, 0.12), (0, 2.35, 2.45), m_wood_d, bevel=0.01)
    box(b, (0.08, 0.08, 0.42), (0, 2.75, 2.25), m_iron, bevel=0.01)
    box(b, (0.55, 0.09, 0.42), (0, 2.75, 1.95), m_wood, bevel=0.02)

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 4) 哨塔 3x3x8
# ===========================================================================

def build_tower():
    coll = K3.reset_scene()
    r = BuildingRig("tower")
    r.add_flag(0.0, 0.55, 7.2, 9.1)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_roof = mat("roof", team=True)
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)

    b = Builder("tower")
    # 塔基
    b.cyl(1.55, 1.42, 0.55, loc=(0, 0, 0.0), material=m_stone_d, sides=12, weight=W_ROOT)
    # 塔身（下粗上细）
    b.add(K3._bm_loft([
        [tuple(v) for v in ring_pts(12, 1.38, 1.38, 0, 0, 0)][:12] and
        [(1.38 * math.cos(TAU * i / 12), 1.38 * math.sin(TAU * i / 12), 0.55) for i in range(12)],
        [(1.28 * math.cos(TAU * i / 12), 1.28 * math.sin(TAU * i / 12), 2.6) for i in range(12)],
        [(1.18 * math.cos(TAU * i / 12), 1.18 * math.sin(TAU * i / 12), 4.9) for i in range(12)],
        [(1.10 * math.cos(TAU * i / 12), 1.10 * math.sin(TAU * i / 12), 6.1) for i in range(12)],
    ], cap_a=True, cap_b=False), m_stone, W_ROOT)
    # 砌石压条
    for zz in (1.2, 2.1, 3.0, 3.9, 4.8, 5.7):
        rr = 1.40 - (zz - 0.55) * 0.028
        b.cyl(rr, rr, 0.09, loc=(0, 0, zz), material=m_stone_l, sides=12, weight=W_ROOT)
    # 顶部平台 + 木挑台
    b.cyl(1.42, 1.42, 0.22, loc=(0, 0, 6.1), material=m_stone_l, sides=12, weight=W_ROOT)
    b.cyl(1.58, 1.58, 0.16, loc=(0, 0, 6.02), material=m_wood, sides=12, weight=W_ROOT)
    for i in range(10):
        a = TAU * i / 10.0
        box(b, (0.10, 0.10, 0.52), (1.32 * math.cos(a), 1.32 * math.sin(a), 6.30), m_wood_d,
            rot=(0, 0, a), bevel=0.01)
        box(b, (0.10, 0.10, 0.52), (1.52 * math.cos(a), 1.52 * math.sin(a), 6.30), m_wood_d,
            rot=(0, 0, a), bevel=0.01)
    b.cyl(1.56, 1.56, 0.08, loc=(0, 0, 6.56), material=m_wood_d, sides=12, weight=W_ROOT)
    # 雉堞
    crenel_ring(b, 0, 0, 1.16, 6.32, 10, m_stone_l, h=0.44, thick=0.30)
    # 蓝顶 + 旗
    cone_roof(b, 0, 0, 1.34, 6.62, 1.85, m_roof, m_gold, sides=12, over=0.20)
    box(b, (0.07, 0.07, 1.5), (0, 0, 8.5), m_iron, bevel=0.0)
    banner(b, 0.0, 0.0, 7.1, 9.05, m_iron, m_cloth, m_gold, dirx=0.0, diry=1.0, idx=0)
    # 箭孔
    for i in range(3):
        a = TAU * i / 3.0 + 0.4
        arrow_slit(b, 1.34 * math.cos(a), 1.34 * math.sin(a), 4.2, rot=a,
                   m=m_stone_l, m_dark=m_glass)
    # 门 + 台阶
    box(b, (1.0, 0.5, 1.85), (0, 1.15, 0.92), m_stone_l, bevel=0.02)
    arch_door(b, 0, 1.42, 0.0, 0.85, 1.45, m_stone_l, m_wood_d, m_gold)
    steps(b, 0, 1.55, 1.3, 0.10, 2, m_stone_l)
    # 塔基草
    for i in range(6):
        a = TAU * i / 6.0
        b.ico(0.18, loc=(1.5 * math.cos(a), 1.5 * math.sin(a), 0.12), material=mat("leaf_dark"),
              subdiv=1, weight=W_ROOT, scale=(1.0, 1.0, 0.5))

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 5) 农场 4x4x2.6
# ===========================================================================

def build_farm():
    coll = K3.reset_scene()
    r = BuildingRig("farm")
    r.build(coll)

    m_stone = mat("stone")
    m_plaster = mat("plaster")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_hay = mat("hay")
    m_gold = mat("gold")
    m_glass = mat("glass")
    m_dirt = mat("dirt")
    m_grass = mat("grass")
    m_leaf = mat("leaf")

    b = Builder("farm")
    # 小屋
    stone_wall(b, 0, -0.45, 3.4, 2.9, 0.0, 1.9, m_plaster, m_stone, rows=3, thick=0.26)
    gable_roof(b, 0, -0.45, 3.4, 2.9, 1.9, 1.15, m_hay, m_wood_d, over=0.38)
    arch_door(b, 0.0, 1.05, 0.0, 1.0, 1.45, m_stone, m_wood_d, m_gold)
    window(b, 1.05, 1.05, 1.2, w=0.28, h=0.42, m_frame=m_wood_d, m_glass=m_glass)
    # 围栏
    for i in range(7):
        xx = -1.9 + i * 0.63
        box(b, (0.09, 0.09, 0.85), (xx, 1.95, 0.42), m_wood, bevel=0.01)
    for zz in (0.30, 0.66):
        box(b, (3.9, 0.07, 0.09), (0, 1.95, zz), m_wood, bevel=0.01)
    for sx in (-1, 1):
        for i in range(4):
            yy = 1.4 - i * 0.55
            box(b, (0.09, 0.09, 0.85), (sx * 1.9, yy, 0.42), m_wood, bevel=0.01)
    # 田垄
    for i in range(4):
        box(b, (3.5, 0.30, 0.10), (0, 1.25 - i * 0.42, 0.06), m_dirt, bevel=0.02)
        for j in range(6):
            b.ico(0.09, loc=(-1.6 + j * 0.64, 1.25 - i * 0.42, 0.16), material=m_leaf,
                  subdiv=1, weight=W_ROOT, scale=(1, 1, 1.2))
    # 干草堆
    for i, (hx, hy) in enumerate(((-1.55, 2.35), (1.6, 2.3))):
        b.cyl(0.34, 0.42, 0.55, loc=(hx, hy, 0.0), material=m_hay, sides=10, weight=W_ROOT)
        b.cyl(0.42, 0.10, 0.30, loc=(hx, hy, 0.55), material=m_hay, sides=10, weight=W_ROOT)
    # 水桶 / 小推车
    b.cyl(0.16, 0.14, 0.34, loc=(1.55, 1.55, 0.0), material=m_wood, sides=8, weight=W_ROOT)
    box(b, (0.50, 0.34, 0.24), (0.95, 2.35, 0.20), m_wood, bevel=0.02)

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
            K3.render_views(nm, QC_DIR, center, max(radius, 1.2) * 1.32, res=(600, 780),
                            views={"正": (0.0, 1.0, 0.18), "三四": (0.85, 1.0, 0.30)})
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
