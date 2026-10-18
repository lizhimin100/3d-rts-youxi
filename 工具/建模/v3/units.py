# -*- coding: utf-8 -*-
"""
units.py —— 联盟四单位 v3（步兵 / 弩手 / 法师 / 农民）
参考：单位/三视图/联盟/单位/*.png（步兵=板甲剑盾、弩手=兜帽皮甲弩、法师=蓝袍尖帽法杖）

设计口径：
  * 人形几何全部由 HumanRig 的比例推导，四套共用一套骨架与动画库 —— 换皮不换骨，
    这样引擎侧一套 SkeletonAnim 就能吃四个单位，动作一致性也自然成立。
  * 每个部位都**显式指定骨骼与权重**（不做自动权重）：headless 下确定性最好，且便于下一个人接手。
  * 材质严格用 kit3.mat(zone, team) 命名，队伍色区（布/披风/盾面/帐篷布）带 _team。
"""

import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import kit3 as K3
from kit3 import mat, Builder, HumanRig, D, TAU, w_rigid, w_z, ring_pts, sq_ring

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型"
QC_DIR = r"E:\自定义游戏\简易rts\工具\建模\v3\qc"


# ===========================================================================
# 通用几何封装
# ===========================================================================

def seg(b, a, c, r1, r2, material, bone, sides=8, ref=(0, 1, 0), squish=1.0, rings=3):
    """两关节之间的一段肢体（锥形放样）。a/c 是世界坐标端点。"""
    a, c = Vector(a), Vector(c)
    d = (c - a).normalized()
    x = Vector(ref).cross(d)
    if x.length < 1e-5:
        x = Vector((1, 0, 0)).cross(d)
    x.normalize()
    y = d.cross(x).normalized()
    rs = []
    for i in range(rings):
        t = i / float(rings - 1)
        p = a.lerp(c, t)
        r = r1 * (1 - t) + r2 * t
        rs.append([tuple(p + x * (math.cos(TAU * k / sides) * r)
                          + y * (math.sin(TAU * k / sides) * r * squish)) for k in range(sides)])
    b.add(K3._bm_loft(rs), material, w_rigid(bone))


def plate(b, size, loc, material, bone, rot=(0, 0, 0), bevel=0.006, scale=None):
    b.box(size, loc=loc, rot=rot, material=material, bevel=bevel, weight=w_rigid(bone), scale=scale)


def band(b, cx, cy, z0, z1, rx, ry, material, weight, sides=12, p=0.6):
    """一圈裙甲/护腰（方圆混合环放样）。"""
    r0 = sq_ring(sides, rx, ry, p)
    r1 = sq_ring(sides, rx * 1.02, ry * 1.02, p)
    b.add(K3._bm_loft([[ (cx + x, cy + y, z0) for (x, y) in r0 ],
                       [ (cx + x, cy + y, z1) for (x, y) in r1 ]]), material, weight)


# ===========================================================================
# 权重
# ===========================================================================

def torso_w(r):
    """躯干按高度在 hips / spine / chest 之间平滑过渡。"""
    return w_z([(r.waist_z - 0.18, {"hips": 1.0}),
                (r.waist_z + 0.02, {"hips": 0.5, "spine": 0.5}),
                (r.chest_z, {"spine": 0.55, "chest": 0.45}),
                (r.sh_z, {"chest": 1.0})])


def cape_w(r):
    return w_z([(r.sh_z - 0.30, {"cape.01": 1.0}),
                (r.sh_z - 0.58, {"cape.02": 1.0}),
                (r.sh_z - 0.86, {"cape.03": 1.0})])


def skirt_w(r, front=True):
    b = "skirt.F" if front else "skirt.B"
    return w_z([(r.waist_z, {"hips": 0.6, b: 0.4}),
                (r.hip_z - 0.20, {b: 1.0}),
                (r.hip_z - 0.36, {b: 1.0})])


# ===========================================================================
# 共用部件
# ===========================================================================

def capesheet(b, r, mat_c, width_k=1.0, z_bottom=None, bulge=0.0):
    """披风：从上往下若干条弧线放样成一片布（双面略厚）。"""
    z1 = z_bottom if z_bottom else r.sh_z - 0.86
    levels = 7
    rings = []
    for i in range(levels):
        t = i / (levels - 1.0)
        z = r.sh_z + 0.02 - (r.sh_z + 0.02 - z1) * t
        wdt = (0.20 * width_k) * (1.0 + 0.85 * t)
        cy = -0.075 - 0.16 * t - bulge * math.sin(t * math.pi)
        pts = []
        n = 9
        for k in range(n):
            u = k / (n - 1.0)
            x = (u - 0.5) * 2.0 * wdt
            # 布面中间略微外鼓，边缘略收
            y = cy - 0.035 * math.cos((u - 0.5) * math.pi)
            pts.append((x, y, z - 0.03 * (1 - math.cos((u - 0.5) * math.pi))))
        rings.append([(p[0], p[1], p[2]) for p in pts])
    # 左右两侧封边
    mesh_rings = []
    for ring in rings:
        mesh_rings.append(ring + list(reversed([(x - 0.012, y - 0.012, z) for (x, y, z) in ring])))
    b.add(K3._bm_loft(mesh_rings, cap_a=True, cap_b=True), mat_c, cape_w(r))


def tabard(b, r, mat_c, mat_g, front=True):
    """战袍：腰前/腰后一片布 + 金色下缘。"""
    sgn = 1.0 if front else -1.0
    z0, z1 = r.waist_z + 0.03, r.hip_z - 0.30
    n = 5
    rings = []
    for i in range(6):
        t = i / 5.0
        z = z0 + (z1 - z0) * t
        wd = 0.115 + 0.045 * t
        y = sgn * (0.095 + 0.055 * t)
        pts = [( (k / (n - 1.0) - 0.5) * 2 * wd, y, z) for k in range(n)]
        rings.append(pts + list(reversed([(x, y - sgn * 0.012, zz) for (x, yy, zz) in pts])))
    b.add(K3._bm_loft(rings, cap_a=True, cap_b=True), mat_c,
          skirt_w(r, front))
    # 金边
    zt = z1
    wd = 0.16
    b.box((wd * 2, 0.014, 0.026), loc=(0, sgn * (0.15), zt),
          material=mat_g, weight=skirt_w(r, front), bevel=0.003)


def belt(b, r, mat_l, mat_g):
    band(b, 0, 0, r.waist_z - 0.035, r.waist_z + 0.012, 0.148, 0.108,
         mat_l, w_rigid("hips"), 14, 0.62)
    plate(b, (0.062, 0.030, 0.050), (0, 0.112, r.waist_z - 0.010), mat_g, "hips", bevel=0.005)


def leg(b, r, s, sx, m_thigh, m_shin, m_boot, m_knee, m_cloth=None):
    hip = (sx * r.hip_x, 0, r.hip_z)
    knee = (sx * r.hip_x * 0.98, 0, r.knee_z)
    ankle = (sx * r.hip_x * 0.96, 0, r.ankle_z)
    # 大腿
    seg(b, hip, (knee[0], 0, knee[2] + 0.02), 0.108, 0.086, m_thigh, "thigh." + s, 10, (0, 1, 0))
    # 膝甲（圆顶 + 下沿小板）
    b.ico(0.078, loc=(knee[0], 0.042, knee[2] + 0.012), material=m_knee,
          weight=w_rigid("shin." + s), scale=(1.0, 0.8, 0.85), subdiv=2)
    # 小腿（上粗下细，像板甲护胫）
    seg(b, (knee[0], 0, knee[2]), ankle, 0.086, 0.062, m_shin, "shin." + s, 10, (0, 1, 0))
    # 靴：脚跟 + 楔形鞋头
    b.box((0.128, 0.215, 0.095), loc=(ankle[0], 0.035, 0.048), material=m_boot,
          weight=w_rigid("foot." + s), bevel=0.016)
    b.add(K3._bm_loft([
        [(ankle[0] - 0.062, -0.075, 0.005), (ankle[0] + 0.062, -0.075, 0.005),
         (ankle[0] + 0.062, 0.14, 0.005), (ankle[0] - 0.062, 0.14, 0.005)],
        [(ankle[0] - 0.056, -0.075, 0.085), (ankle[0] + 0.056, -0.075, 0.085),
         (ankle[0] + 0.050, 0.155, 0.060), (ankle[0] - 0.050, 0.155, 0.060)],
    ], cap_a=True, cap_b=True), m_boot, w_rigid("toe." + s))


def arm(b, r, s, sx, m_upper, m_fore, m_hand, m_pad, m_trim):
    sh = (sx * r.sh_x, 0, r.sh_z)
    el = (sx * r.elbow_x, 0, r.elbow_z)
    wr = (sx * r.wrist_x, 0, r.wrist_z)
    seg(b, sh, el, 0.088, 0.068, m_upper, "upperarm." + s, 9)
    b.ico(0.068, loc=(el[0], 0, el[2]), material=m_upper,
          weight=w_rigid("forearm." + s), subdiv=1, scale=(1, 1, 0.9))
    seg(b, el, wr, 0.068, 0.052, m_fore, "forearm." + s, 9)
    b.box((0.082, 0.092, 0.105), loc=(wr[0], 0.005, wr[2] - 0.03), material=m_hand,
          weight=w_rigid("hand." + s), bevel=0.014)
    # 肩甲：两片叠压的圆顶板（比堆方片更像魔兽的圆护肩）
    for i in range(2):
        z = r.sh_z + 0.045 - i * 0.075
        cx = sx * (r.sh_x + 0.015 + i * 0.012)
        rr = 0.112 + i * 0.020
        b.ico(rr, loc=(cx, 0.0, z), material=m_pad,
              weight=w_rigid("shoulder." + s), subdiv=2, scale=(1.16, 1.08, 0.52))
        b.box((rr * 1.55, rr * 1.30, 0.026), loc=(cx, 0, z - 0.040),
              rot=(0, sx * D(-16), 0), material=m_trim,
              weight=w_rigid("shoulder." + s), bevel=0.006)


def face_mask(b, r, m_skin, m_dark, m_hair, beard=False):
    """给露脸的角色加眉、眼、鼻、嘴。RTS 距离看不清没关系，近景和头像框要看得出是张脸。"""
    hw, hd, hh = r.head_w * 0.5, r.head_d * 0.5, r.head_h
    y = r.head_d * 0.40 + 0.004
    z_eye = r.chin + hh * 0.52
    W = w_rigid("head")
    # 眉（一条压暗的横带，比一颗颗眼睛更像手绘）
    b.box((hw * 1.42, 0.024, 0.020), loc=(0, y, z_eye + 0.030), material=m_hair,
          weight=W, bevel=0.002)
    for sx in (-1, 1):
        b.box((hw * 0.30, 0.018, 0.024), loc=(sx * hw * 0.40, y + 0.002, z_eye - 0.004),
              material=m_dark, weight=W, bevel=0.002)
    # 鼻梁
    b.box((hw * 0.22, 0.040, hh * 0.22), loc=(0, y + 0.008, z_eye - 0.070),
          material=m_skin, weight=W, bevel=0.004)
    # 嘴
    b.box((hw * 0.42, 0.014, 0.014), loc=(0, y - 0.004, z_eye - 0.135),
          material=m_dark, weight=W, bevel=0.001)
    if beard:
        b.loft([
            [(x, yy, r.chin + hh * 0.08) for (x, yy) in sq_ring(8, hw * 0.66, hd * 0.44, 0.5)],
            [(x, yy + 0.02, r.chin - 0.10) for (x, yy) in sq_ring(8, hw * 0.44, hd * 0.34, 0.5)],
        ], m_hair, W)


def head_great_helm(b, r, m_helm, m_dark, m_gold, m_cloth=None, crest=False):
    """全罩式大盔（步兵）：方壳 + 眼缝 + 呼吸孔 + 护颊。"""
    hw, hd = r.head_w * 0.5, r.head_d * 0.5
    z0, z1 = r.chin - 0.02, r.head_top + 0.01
    n = 10
    rings = []
    for t, k in ((0.0, 0.86), (0.22, 1.03), (0.62, 1.06), (0.86, 0.98), (1.0, 0.62)):
        z = z0 + (z1 - z0) * t
        rings.append([(x, y, z) for (x, y) in sq_ring(n, hw * 1.12 * k, hd * 1.12 * k, 0.55)])
    b.add(K3._bm_loft(rings), m_helm, w_rigid("head"))
    # 眼缝
    b.box((hw * 2.0, 0.05, 0.028), loc=(0, hd * 1.0, z0 + (z1 - z0) * 0.62),
          material=m_dark, weight=w_rigid("head"), bevel=0.002)
    # 面甲中脊 + 呼吸孔
    b.box((0.03, 0.06, (z1 - z0) * 0.42), loc=(0, hd * 1.02, z0 + (z1 - z0) * 0.40),
          material=m_helm, weight=w_rigid("head"), bevel=0.004)
    for i in range(3):
        b.box((0.012, 0.02, 0.012), loc=(-0.045, hd * 1.06, z0 + (z1 - z0) * (0.30 - i * 0.06)),
              material=m_dark, weight=w_rigid("head"), bevel=0.001)
        b.box((0.012, 0.02, 0.012), loc=(0.045, hd * 1.06, z0 + (z1 - z0) * (0.30 - i * 0.06)),
              material=m_dark, weight=w_rigid("head"), bevel=0.001)
    # 眉带（金）+ 盔顶小脊
    b.loft([
        [(x, y, z0 + (z1 - z0) * 0.66) for (x, y) in sq_ring(10, hw * 1.16, hd * 1.16, 0.55)],
        [(x, y, z0 + (z1 - z0) * 0.72) for (x, y) in sq_ring(10, hw * 1.16, hd * 1.16, 0.55)],
    ], m_gold, w_rigid("head"))
    b.box((0.026, hd * 1.75, 0.030), loc=(0, 0, z1 - 0.004), material=m_gold,
          weight=w_rigid("head"), bevel=0.004)


def head_hood(b, r, m_hood, m_face, m_skin, m_hair, m_steel=None):
    """兜帽（弩手）：脸必须露出来。做法是"帽兜只包后 3/4 + 前沿做一圈内衬"。
    上一版把兜帽做成整圈封闭的壳，结果整个人头是一坨蓝 —— 这个坑记在这儿。"""
    hw, hd = r.head_w * 0.5, r.head_d * 0.5
    W = w_rigid("head")
    # 头（略往前探，确保在兜帽外面）
    b.box((r.head_w * 0.80, r.head_d * 0.76, r.head_h * 0.82),
          loc=(0, 0.020, r.chin + r.head_h * 0.40), material=m_skin, weight=W, bevel=0.018)
    face_mask(b, r, m_skin, mat("steel_dark"), m_hair)
    # 兜帽：只做后半圈（theta 从 -40° 到 220°，前面留开口）
    n = 9
    rings = []
    for t, k in ((-0.04, 1.04), (0.22, 1.18), (0.58, 1.16), (0.86, 0.98), (1.04, 0.50)):
        z = r.chin + (r.head_top - r.chin) * t
        ring = []
        # 只取后半圈的采样点（前向 +Y 留空）
        for i in range(n):
            # 角度取 120°→420°，即"背面 + 两侧"，正面（+Y = 90°）留出脸的开口
            a = D(120) + D(300) * i / (n - 1.0)
            ring.append((hw * 1.18 * k * math.cos(a), -0.012 + hd * 1.16 * k * math.sin(a), z))
        rings.append(ring)
    b.add(K3._bm_loft(rings, cap_a=False, cap_b=True), m_hood, W)
    # 帽檐（一圈压在前额上的布边，把脸框出来）
    b.box((r.head_w * 1.60, 0.075, 0.055), loc=(0, hd * 0.62, r.chin + r.head_h * 0.80),
          material=m_hood, weight=W, bevel=0.014)
    # 后颈披布
    b.box((r.head_w * 1.55, 0.12, 0.10), loc=(0, -hd * 0.95, r.chin + 0.01),
          material=m_hood, weight=w_rigid("neck"), bevel=0.02)


def head_wizard(b, r, m_hat, m_skin, m_hair, m_robe, m_gold):
    """法师：尖顶宽檐帽 + 长须。"""
    hw, hd = r.head_w * 0.5, r.head_d * 0.5
    b.box((r.head_w * 0.80, r.head_d * 0.76, r.head_h * 0.78),
          loc=(0, 0.010, r.chin + r.head_h * 0.40), material=m_skin,
          weight=w_rigid("head"), bevel=0.02)
    face_mask(b, r, m_skin, mat("steel_dark"), m_hair, beard=True)
    # 帽檐（压低到额头上，不能悬空）
    b.cyl(hw * 2.10, hw * 1.98, 0.032, loc=(0, 0, r.head_top - 0.030), material=m_hat,
          weight=w_rigid("head"), sides=14)
    b.cyl(hw * 1.02, hw * 1.00, 0.060, loc=(0, 0, r.head_top - 0.035), material=m_hat,
          weight=w_rigid("head"), sides=12)
    # 帽锥（带弯）
    rings = []
    for i in range(6):
        t = i / 5.0
        z = r.head_top - 0.010 + t * r.head_h * 1.05
        rr = (hw * 1.10) * (1.0 - t) ** 1.25 + 0.006
        bend = 0.055 * (t ** 2.2)
        rings.append([(x + bend, y - bend * 0.35, z) for (x, y) in ring_pts(10, rr, rr * 0.92)])
    b.add(K3._bm_loft(rings), m_hat, w_rigid("head"))
    # 帽带
    b.cyl(hw * 1.14, hw * 1.14, 0.034, loc=(0, 0, r.head_top + 0.020), material=m_gold,
          weight=w_rigid("head"), sides=12)


def sword(b, r, m_blade, m_gold, m_grip, tip_len=0.10):
    """长剑：**局部坐标装配**（握把在原点，剑身沿 -Z），最后一次变换摆到右手。
    为什么这么做：以前每个零件各转一个角度，稍改一处就错位；统一变换后就一个旋钮。"""
    hx = r.wrist_x + 0.03
    M = (Matrix.Translation(Vector((hx, 0.06, r.wrist_z - 0.04)))
         @ Euler((D(18), 0, D(-6)), "XYZ").to_matrix().to_4x4())
    W = w_rigid("hand.R")
    blade_l = 0.62
    # 剑身
    b.box((0.056, 0.014, blade_l), loc=(0, 0, -0.08 - blade_l * 0.5), material=m_blade,
          weight=W, bevel=0.004, xform=M)
    # 剑尖（四面收尖）
    b.loft([
        [(-0.028, -0.007, -0.08 - blade_l), (0.028, -0.007, -0.08 - blade_l),
         (0.028, 0.007, -0.08 - blade_l), (-0.028, 0.007, -0.08 - blade_l)],
        [(-0.004, -0.002, -0.08 - blade_l - tip_len), (0.004, -0.002, -0.08 - blade_l - tip_len),
         (0.004, 0.002, -0.08 - blade_l - tip_len), (-0.004, 0.002, -0.08 - blade_l - tip_len)],
    ], m_blade, W, xform=M)
    # 护手 + 柄 + 圆头
    b.box((0.19, 0.034, 0.030), loc=(0, 0, -0.065), material=m_gold, weight=W, bevel=0.005, xform=M)
    b.cyl(0.018, 0.018, 0.12, loc=(0, 0, 0.0), material=m_grip, weight=W, sides=6, xform=M)
    b.ico(0.028, loc=(0, 0, 0.075), material=m_gold, weight=W, subdiv=1, xform=M)


def shield_round(b, r, m_field, m_rim, m_boss):
    """圆盾：挂左臂（forearm.L），面朝前、略外倾。"""
    cx, cy, cz = -r.sh_x * 1.44, 0.115, r.wrist_z + 0.02
    # 盾面（十六边形圆盘，向前 + 略外倾）
    b.cyl(0.285, 0.255, 0.030, loc=(cx, cy, cz), rot=(D(84), 0, D(-10)), material=m_field,
          weight=w_rigid("forearm.L"), sides=16)
    # 盾缘（一圈厚边）
    b.add(K3._bm_loft([
        [(cx + 0.285 * math.cos(TAU * i / 16), cy - 0.015, cz + 0.285 * math.sin(TAU * i / 16)) for i in range(16)],
        [(cx + 0.310 * math.cos(TAU * i / 16), cy + 0.012, cz + 0.310 * math.sin(TAU * i / 16)) for i in range(16)],
    ], cap_a=False, cap_b=False), m_rim, w_rigid("forearm.L"))
    # 中心凸起
    b.ico(0.070, loc=(cx, cy + 0.045, cz), material=m_boss,
          weight=w_rigid("forearm.L"), subdiv=2, scale=(1, 0.6, 1))
    # 放射筋
    for i in range(8):
        a = TAU * i / 8.0
        b.box((0.255, 0.014, 0.020),
              loc=(cx + 0.135 * math.cos(a), cy + 0.032, cz + 0.135 * math.sin(a)),
              rot=(0, D(90), a), material=m_rim, weight=w_rigid("forearm.L"), bevel=0.002)


def crossbow(b, r, m_wood, m_steel, m_string):
    """弩：**握把在右手腕的局部坐标**里装配（弩身沿 +Y 向前），由 hand.R 带动。
    这样举弩/瞄准/后坐全靠手臂骨骼，模型不需要另做一套动画。"""
    M = Matrix.Translation(Vector((r.wrist_x + 0.02, 0.02, r.wrist_z - 0.03)))         @ Euler((D(-6), 0, 0), "XYZ").to_matrix().to_4x4()
    W = w_rigid("hand.R")
    # 弩身 + 弩托
    b.box((0.044, 0.48, 0.044), loc=(0, 0.10, 0), material=m_wood, weight=W, bevel=0.007, xform=M)
    b.box((0.052, 0.18, 0.070), loc=(0, -0.10, -0.010), material=m_wood, weight=W, bevel=0.007, xform=M)
    # 弩臂（横）+ 两端弓梢
    b.box((0.46, 0.028, 0.024), loc=(0, 0.24, 0.004), material=m_steel, weight=W, bevel=0.005, xform=M)
    for sx in (-1, 1):
        b.box((0.10, 0.024, 0.022), loc=(sx * 0.26, 0.29, 0.004), rot=(0, 0, sx * D(-12)),
              material=m_steel, weight=W, bevel=0.004, xform=M)
    # 弦 + 箭
    b.box((0.42, 0.005, 0.005), loc=(0, 0.19, 0.004), material=m_string, weight=W, bevel=0.0, xform=M)
    b.box((0.011, 0.40, 0.011), loc=(0, 0.22, 0.034), material=m_steel, weight=W, bevel=0.0, xform=M)
    b.ico(0.014, loc=(0, 0.42, 0.034), material=m_steel, weight=W, subdiv=1, xform=M)
    # 扳机
    b.box((0.028, 0.055, 0.085), loc=(0, -0.20, -0.055), material=m_steel, weight=W, bevel=0.006, xform=M)


def staff(b, r, m_wood, m_crystal):
    hx = r.wrist_x + 0.01
    z0 = 0.02
    b.cyl(0.024, 0.020, 1.72, loc=(hx, 0.10, z0), material=m_wood,
          weight=w_rigid("hand.R"), sides=7)
    # 顶部缠枝
    for i in range(3):
        a = TAU * i / 3.0
        b.tube([(hx + 0.02 * math.cos(a), 0.10 + 0.02 * math.sin(a), z0 + 1.62),
                (hx + 0.06 * math.cos(a), 0.10 + 0.06 * math.sin(a), z0 + 1.72),
                (hx + 0.02 * math.cos(a), 0.10 + 0.02 * math.sin(a), z0 + 1.80)],
               0.014, m_wood, w_rigid("hand.R"), sides=5)
    # 水晶
    b.ico(0.075, loc=(hx, 0.10, z0 + 1.90), material=m_crystal,
          weight=w_rigid("hand.R"), subdiv=1, scale=(0.8, 0.8, 1.45))


def quiver(b, r, m_leather, m_steel, m_wood):
    """背箭袋（弩手）。"""
    cx, cy, cz = -0.13, -0.16, r.chest_z - 0.02
    b.cyl(0.062, 0.052, 0.34, loc=(cx, cy, cz), rot=(D(-16), D(8), 0),
          material=m_leather, weight=w_rigid("chest"), sides=8)
    for i in range(5):
        a = TAU * i / 5.0
        b.cyl(0.008, 0.008, 0.30, loc=(cx + 0.035 * math.cos(a), cy - 0.03 + 0.035 * math.sin(a), cz + 0.26),
              rot=(D(-16), D(8), 0), material=m_wood, weight=w_rigid("chest"), sides=5)
        b.ico(0.014, loc=(cx + 0.035 * math.cos(a), cy - 0.06 + 0.035 * math.sin(a), cz + 0.40),
              material=m_steel, weight=w_rigid("chest"), subdiv=1)


# ===========================================================================
# 动画：共用动作库（idle / walk / attack / shoot / cast / gather / build / death / hurt）
# ===========================================================================

def _hold_crossbow(r, lift=0.0, recoil=0.0):
    """端弩姿态：右臂屈肘把弩端到胸腹前，左手前伸扶住弩身前段。"""
    r.aim("upperarm.R", (0.42, 0.35, -0.86 + lift), ref=(0, 1, 0))
    r.aim("forearm.R", (0.20, 0.92, 0.12 + lift + recoil), ref=(0, 1, 0))
    r.aim("hand.R", (0.10, 1.0, 0.05), ref=(0, 1, 0))
    r.aim("upperarm.L", (-0.26, 0.72, -0.70 - lift * 0.3), ref=(0, 1, 0))
    r.aim("forearm.L", (-0.12, 0.94, -0.12 + recoil), ref=(0, 1, 0))
    r.aim("hand.L", (-0.05, 1.0, 0.0), ref=(0, 1, 0))


def _stand(r, lean=0.0, knee=0.0, arm_out=0.0, hold=None):
    """中立站姿。lean 为躯干前倾角（度），knee 为屈膝角。"""
    r.reset()
    r.aim("spine", (0, math.sin(D(lean * 0.5)), 1.0), ref=(0, 1, 0))
    r.aim("chest", (0, math.sin(D(lean)), 1.0), ref=(0, 1, 0))
    r.aim("neck", (0, math.sin(D(lean * 1.3)), 1.0), ref=(0, 1, 0))
    r.aim("head", (0, math.sin(D(lean * 1.6)), 1.0), ref=(0, 1, 0))
    for s, sx in (("L", -1.0), ("R", 1.0)):
        r.aim("shoulder." + s, (sx, 0, 0.10), ref=(0, 0, 1))
        r.aim("upperarm." + s, (sx * (0.16 + arm_out), 0.02, -1.0), ref=(0, 1, 0))
        r.aim("forearm." + s, (sx * (0.10 + arm_out), 0.16, -1.0), ref=(0, 1, 0))
        r.aim("hand." + s, (sx * 0.05, 0.35, -1.0), ref=(0, 1, 0))
        r.aim("thigh." + s, (sx * 0.05, 0.0, -1.0), ref=(0, 1, 0))
        r.aim("shin." + s, (sx * 0.02, math.sin(D(knee)), -1.0), ref=(0, 1, 0))
        r.aim("foot." + s, (0, 1.0, -0.25), ref=(0, 0, 1))
        r.aim("toe." + s, (0, 1.0, -0.05), ref=(0, 0, 1))
    if hold == "crossbow":
        _hold_crossbow(r)


def _pose_arms_down(r, sway=0.0):
    for s, sx in (("L", -1.0), ("R", 1.0)):
        r.aim("upperarm." + s, (sx * 0.20, sway * sx, -1.0), ref=(0, 1, 0))
        r.aim("forearm." + s, (sx * 0.12, 0.18 + sway * 0.5, -1.0), ref=(0, 1, 0))


def anim_idle(r, name="idle", frames=41, hold=None):
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (frames // 2 + 1, 1.0), (frames + 1, 0.0)):
        breathe = math.sin(ph * math.pi)
        _stand(r, lean=2.0 + 1.6 * breathe, knee=6.0 + 2.0 * breathe, arm_out=0.02 * breathe,
               hold=hold)
        r.aim("chest", (0, 0.02, 1.0), ref=(0, 1, 0))
        r.aim("cape.01", (0, -0.35, -1.0), ref=(0, 1, 0))
        r.aim("cape.02", (0, -0.42, -1.0), ref=(0, 1, 0))
        r.aim("cape.03", (0, -0.48, -1.0), ref=(0, 1, 0))
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


def anim_walk(r, name="walk", frames=25, speed=1.0, hold=None):
    act = r.new_action(name)
    n = 4
    for i in range(n + 1):
        t = i / float(n)
        ph = t * TAU
        swing = math.sin(ph)
        lift = math.cos(ph)
        r.reset()
        r.aim("spine", (0, 0.015 * swing, 1.0), ref=(0, 1, 0))
        r.aim("chest", (0, 0.03, 1.0), ref=(0, 1, 0))
        r.aim("head", (0, 0.01, 1.0), ref=(0, 1, 0))
        for s, sx in (("L", -1.0), ("R", 1.0)):
            sgn = 1.0 if s == "R" else -1.0
            th = 0.42 * swing * sgn
            kn = 0.20 + 0.34 * max(0.0, -lift * sgn)
            r.aim("thigh." + s, (sx * 0.04, th, -1.0), ref=(0, 1, 0))
            r.aim("shin." + s, (sx * 0.02, -0.12 - kn, -1.0), ref=(0, 1, 0))
            r.aim("foot." + s, (0, 1.0, -0.3 - 0.35 * max(0.0, lift * sgn)), ref=(0, 0, 1))
            r.aim("shoulder." + s, (sx, 0, 0.08), ref=(0, 0, 1))
            r.aim("upperarm." + s, (sx * 0.18, -0.30 * swing * sgn, -1.0), ref=(0, 1, 0))
            r.aim("forearm." + s, (sx * 0.10, 0.10 - 0.22 * swing * sgn, -1.0), ref=(0, 1, 0))
            r.aim("cape.01", (0, -0.28 - 0.10 * swing, -1.0), ref=(0, 1, 0))
            r.aim("cape.02", (0, -0.34 - 0.14 * swing, -1.0), ref=(0, 1, 0))
            r.aim("cape.03", (0, -0.40 - 0.18 * swing, -1.0), ref=(0, 1, 0))
        if hold == "crossbow":
            _hold_crossbow(r, lift=0.05 * math.sin(ph * 2.0))
        r.key(1 + int(round(frames * t)))
    return r.finish_action(act, 1, frames + 1)


def anim_attack_sword(r, name="attack", frames=25):
    """剑击：蓄力（举剑过肩）→ 斩下 → 收势。三段共 25 帧。"""
    act = r.new_action(name)
    keys = [("蓄力", 0.30), ("斩击", 0.55), ("收势", 1.0)]
    for f, phase in ((1, 0.0), (8, 0.30), (13, 0.55), (25, 1.0)):
        if phase == 0.0:
            _stand(r, lean=3, knee=8)
            r.aim("upperarm.R", (0.35, 0.15, -1.0), ref=(0, 1, 0))
            r.aim("forearm.R", (0.20, 0.30, -1.0), ref=(0, 1, 0))
        elif phase == 0.30:
            _stand(r, lean=-4, knee=10)
            r.aim("chest", (0, -0.06, 1.0), ref=(0, 1, 0))
            r.aim("upperarm.R", (0.45, -0.55, 0.55), ref=(0, 1, 0))
            r.aim("forearm.R", (0.10, -0.35, 0.75), ref=(0, 1, 0))
            r.aim("hand.R", (0, -0.2, 1.0), ref=(0, 1, 0))
        elif phase == 0.55:
            _stand(r, lean=12, knee=12)
            r.aim("upperarm.R", (0.30, 0.55, -1.0), ref=(0, 1, 0))
            r.aim("forearm.R", (0.10, 0.65, -0.75), ref=(0, 1, 0))
            r.aim("hand.R", (0, 0.7, -1.0), ref=(0, 1, 0))
        else:
            _stand(r, lean=5, knee=8)
            r.aim("upperarm.R", (0.36, 0.20, -1.0), ref=(0, 1, 0))
            r.aim("forearm.R", (0.16, 0.32, -1.0), ref=(0, 1, 0))
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


def anim_shoot(r, name="shoot", frames=25):
    """弩：举弩 → 瞄准（微顿）→ 后坐。"""
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (7, 0.35), (12, 0.5), (16, 0.62), (25, 1.0)):
        _stand(r, lean=2, knee=7, hold="crossbow")
        if ph < 0.35:
            _hold_crossbow(r, lift=0.12 * ph / 0.35)
        elif ph < 0.62:
            _hold_crossbow(r, lift=0.12, recoil=0.0)
        else:
            _hold_crossbow(r, lift=0.10, recoil=0.18 * (1.0 - (ph - 0.62) / 0.38))
        if ph == 0.62:
            r.aim("chest", (0, -0.06, 1.0), ref=(0, 1, 0))
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


def anim_cast(r, name="cast", frames=31):
    """施法：法杖前推 + 上举（水晶亮）。"""
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (10, 0.35), (18, 0.6), (31, 1.0)):
        _stand(r, lean=2 + 6 * min(ph, 0.6), knee=7)
        if ph == 0.0:
            r.aim("upperarm.R", (0.26, 0.20, -1.0), ref=(0, 1, 0))
        elif ph < 0.6:
            r.aim("upperarm.R", (0.30, 0.45, -0.55), ref=(0, 1, 0))
            r.aim("forearm.R", (0.10, 0.85, 0.10), ref=(0, 1, 0))
        else:
            r.aim("upperarm.R", (0.26, 0.60, -0.35), ref=(0, 1, 0))
            r.aim("forearm.R", (0.06, 0.95, 0.30), ref=(0, 1, 0))
        r.aim("upperarm.L", (-0.35, 0.35, -0.75), ref=(0, 1, 0))
        r.aim("forearm.L", (-0.15, 0.70, -0.35), ref=(0, 1, 0))
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


def anim_gather(r, name="gather", frames=21):
    """采集：弯腰挥镐（两下一循环）。"""
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (6, 0.3), (11, 0.55), (16, 0.8), (21, 1.0)):
        lean = 16 + 16 * math.sin(ph * math.pi * 2.0)
        _stand(r, lean=lean, knee=16)
        sw = math.sin(ph * TAU)
        r.aim("upperarm.R", (0.28, 0.35 + 0.4 * sw, -0.9), ref=(0, 1, 0))
        r.aim("forearm.R", (0.12, 0.55 + 0.5 * sw, -0.6), ref=(0, 1, 0))
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


def anim_build(r, name="build", frames=21):
    """建造：抡锤。"""
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (6, 0.35), (10, 0.5), (16, 0.75), (21, 1.0)):
        _stand(r, lean=10, knee=12)
        a = math.sin(ph * TAU)
        r.aim("upperarm.R", (0.30, 0.30 - 0.5 * a, -0.85), ref=(0, 1, 0))
        r.aim("forearm.R", (0.10, 0.40 - 0.8 * a, -0.55), ref=(0, 1, 0))
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


def anim_hurt(r, name="hurt", frames=11):
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (3, 0.6), (11, 1.0)):
        _stand(r, lean=-8 * math.sin(ph * math.pi), knee=8)
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


def anim_death(r, name="death", frames=31):
    """死亡：后仰 → 倒地 → 下沉留最后一帧。"""
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (6, 0.25), (16, 0.6), (26, 0.9), (31, 1.0)):
        r.reset()
        fall = min(1.0, ph * 1.25)
        r.aim("hips", (0, -0.55 * fall, 1.0 - fall * 0.9), ref=(0, 1, 0))
        r.aim("spine", (0, -0.5 * fall, 1.0 - fall), ref=(0, 1, 0))
        r.aim("chest", (0, -0.45 * fall, 1.0 - fall), ref=(0, 1, 0))
        r.aim("head", (0, -0.3 * fall, 1.0 - fall * 0.8), ref=(0, 1, 0))
        for s, sx in (("L", -1.0), ("R", 1.0)):
            r.aim("thigh." + s, (sx * 0.05, 0.55 * fall, -1.0 + fall * 0.4), ref=(0, 1, 0))
            r.aim("shin." + s, (sx * 0.02, 0.85 * fall, -0.5), ref=(0, 1, 0))
            r.aim("upperarm." + s, (sx * 0.5, -0.4 * fall, -0.8), ref=(0, 1, 0))
        r.key(f)
    return r.finish_action(act, 1, frames + 1)


ANIM_LIB = [anim_idle, anim_walk, anim_attack_sword, anim_shoot, anim_cast,
            anim_gather, anim_build, anim_hurt, anim_death]


# ===========================================================================
# 单位：步兵（剑盾板甲）
# ===========================================================================

def build_footman(H=1.78):
    coll = K3.reset_scene()
    r = HumanRig("footman", H)
    r.build(coll)

    m_steel = mat("steel")
    m_steel_d = mat("steel_dark")
    m_steel_l = mat("steel_light")
    m_gold = mat("gold")
    m_cloth = mat("cloth", team=True)
    m_cloth_d = mat("cloth_dark")
    m_leather = mat("leather")
    m_dark = mat("steel_dark")

    b = Builder("footman")
    tw = torso_w(r)

    # 底衣（布）
    b.loft([
        [(x, y, r.waist_z - 0.10) for (x, y) in sq_ring(12, 0.150, 0.105, 0.62)],
        [(x, y, r.waist_z + 0.05) for (x, y) in sq_ring(12, 0.152, 0.108, 0.62)],
        [(x, y, r.chest_z) for (x, y) in sq_ring(12, 0.176, 0.124, 0.62)],
        [(x, y, r.sh_z - 0.02) for (x, y) in sq_ring(12, 0.170, 0.120, 0.62)],
        [(x, y, r.sh_z + 0.02) for (x, y) in sq_ring(12, 0.098, 0.090, 0.62)],
    ], m_cloth_d, tw)

    # 胸甲（钢）：比底衣大一圈，前沿略凸
    b.loft([
        [(x, y, r.chest_z - 0.16) for (x, y) in sq_ring(12, 0.160, 0.114, 0.60)],
        [(x, y, r.chest_z - 0.06) for (x, y) in sq_ring(12, 0.180, 0.128, 0.60)],
        [(x, y, r.chest_z + 0.06) for (x, y) in sq_ring(12, 0.192, 0.136, 0.58)],
        [(x, y, r.sh_z - 0.03) for (x, y) in sq_ring(12, 0.182, 0.130, 0.58)],
        [(x, y, r.sh_z + 0.03) for (x, y) in sq_ring(12, 0.108, 0.098, 0.58)],
    ], m_steel, tw)
    # 胸甲中脊 + 板缝
    b.box((0.030, 0.055, 0.30), loc=(0, 0.140, r.chest_z + 0.02),
          material=m_steel_l, weight=tw, bevel=0.005)
    for zz in (r.chest_z - 0.10, r.chest_z + 0.10):
        b.box((0.30, 0.022, 0.014), loc=(0, 0.146, zz), material=m_steel_d,
              weight=tw, bevel=0.002)
    # 胸甲上的蓝布饰带（队伍色）
    b.box((0.115, 0.020, 0.26), loc=(0, 0.152, r.chest_z + 0.02), material=m_cloth,
          weight=tw, bevel=0.004)
    # 领/护喉
    b.loft([
        [(x, y, r.sh_z - 0.01) for (x, y) in sq_ring(10, 0.110, 0.100, 0.6)],
        [(x, y, r.neck_z + 0.02) for (x, y) in sq_ring(10, 0.082, 0.080, 0.6)],
    ], m_steel_d, w_rigid("chest"))

    belt(b, r, m_leather, m_gold)
    tabard(b, r, m_cloth, m_gold, front=True)
    tabard(b, r, m_cloth, m_gold, front=False)
    capesheet(b, r, m_cloth, width_k=1.0, z_bottom=r.hip_z - 0.30)

    # 裙甲（三段）
    for i in range(3):
        z0 = r.waist_z - 0.02 - i * 0.055
        band(b, 0, 0, z0, z0 + 0.058, 0.168 + i * 0.008, 0.124 + i * 0.006,
             m_steel if i % 2 == 0 else m_steel_d, w_rigid("hips"), 14, 0.6)

    for s, sx in (("L", -1.0), ("R", 1.0)):
        leg(b, r, s, sx, m_steel, m_steel_d, m_steel, m_steel_l, m_cloth_d)
        arm(b, r, s, sx, m_steel, m_steel_d, m_steel_d, m_steel, m_gold)

    head_great_helm(b, r, m_steel, m_dark, m_gold)
    sword(b, r, m_steel_l, m_gold, m_leather)
    shield_round(b, r, m_cloth, m_steel_d, m_gold)

    objs = b.build_meshes(coll)
    r.bind(objs)
    for fn in (anim_idle, anim_walk, anim_attack_sword, anim_hurt, anim_death):
        act = fn(r)
        r.push_nla(act)
    return r, objs


# ===========================================================================
# 单位：弩手（兜帽 + 皮甲 + 弩）
# ===========================================================================

def build_crossbow(H=1.74):
    coll = K3.reset_scene()
    r = HumanRig("crossbow", H)
    r.build(coll)

    m_cloth = mat("cloth", team=True)
    m_cloth_d = mat("cloth_dark")
    m_leather = mat("leather")
    m_leather_d = mat("leather_dark")
    m_steel = mat("steel")
    m_steel_d = mat("steel_dark")
    m_skin = mat("skin")
    m_hair = mat("hair")
    m_wood = mat("wood")

    b = Builder("crossbow")
    tw = torso_w(r)

    # 皮甲躯干
    b.loft([
        [(x, y, r.waist_z - 0.12) for (x, y) in sq_ring(12, 0.145, 0.102, 0.62)],
        [(x, y, r.waist_z + 0.04) for (x, y) in sq_ring(12, 0.150, 0.106, 0.62)],
        [(x, y, r.chest_z) for (x, y) in sq_ring(12, 0.174, 0.120, 0.62)],
        [(x, y, r.sh_z - 0.02) for (x, y) in sq_ring(12, 0.168, 0.118, 0.62)],
        [(x, y, r.sh_z + 0.02) for (x, y) in sq_ring(12, 0.095, 0.088, 0.62)],
    ], m_leather, tw)
    # 锁甲护胸（钢，半身）
    b.loft([
        [(x, y, r.chest_z - 0.02) for (x, y) in sq_ring(12, 0.178, 0.124, 0.62)],
        [(x, y, r.sh_z - 0.04) for (x, y) in sq_ring(12, 0.176, 0.124, 0.62)],
    ], m_steel_d, tw)
    # 斜挎皮带
    b.box((0.055, 0.03, 0.55), loc=(0, 0.135, r.chest_z), rot=(0, D(-26), 0),
          material=m_leather_d, weight=tw, bevel=0.006)
    belt(b, r, m_leather_d, m_steel)
    tabard(b, r, m_cloth, m_steel, front=True)

    # 斗篷（比步兵长）
    capesheet(b, r, m_cloth, width_k=1.05, z_bottom=r.hip_z - 0.40)

    # 兜帽肩部披布
    b.loft([
        [(x, y, r.sh_z + 0.05) for (x, y) in sq_ring(12, 0.150, 0.120, 0.6)],
        [(x, y, r.sh_z - 0.10) for (x, y) in sq_ring(12, 0.175, 0.140, 0.6)],
    ], m_cloth, w_rigid("chest"))

    for s, sx in (("L", -1.0), ("R", 1.0)):
        leg(b, r, s, sx, m_leather, m_leather_d, m_leather_d, m_steel_d)
        # 手臂：锁甲上臂 + 皮护腕
        arm(b, r, s, sx, m_steel_d, m_leather, m_leather_d, m_steel, m_leather_d)
        # 肩甲只留一片
        b.box((0.16, 0.15, 0.05), loc=(sx * (r.sh_x + 0.02), 0, r.sh_z + 0.045),
              rot=(0, sx * D(-12), 0), material=m_steel, weight=w_rigid("shoulder." + s),
              bevel=0.012)

    head_hood(b, r, m_cloth, m_cloth_d, m_skin, m_hair)
    quiver(b, r, m_leather, m_steel, m_wood)
    crossbow(b, r, m_wood, m_steel, m_steel_d)

    objs = b.build_meshes(coll)
    r.bind(objs)
    for fn in (anim_idle, anim_walk, anim_shoot, anim_hurt, anim_death):
        act = fn(r, hold="crossbow") if fn in (anim_idle, anim_walk) else fn(r)
        r.push_nla(act)
    return r, objs


# ===========================================================================
# 单位：法师（长袍 + 尖帽 + 法杖）
# ===========================================================================

def build_mage(H=1.80):
    coll = K3.reset_scene()
    r = HumanRig("mage", H)
    r.build(coll)

    m_cloth = mat("cloth", team=True)
    m_cloth_d = mat("cloth_dark")
    m_gold = mat("gold")
    m_skin = mat("skin")
    m_hair = mat("hair")
    m_wood = mat("wood")
    m_crystal = mat("crystal")
    m_leather = mat("leather")
    m_boot = mat("leather_dark")

    b = Builder("mage")
    tw = torso_w(r)

    # 长袍：从肩到脚，下摆张开
    b.loft([
        [(x, y, r.ankle_z + 0.02) for (x, y) in sq_ring(14, 0.235, 0.200, 0.72)],
        [(x, y, r.knee_z) for (x, y) in sq_ring(14, 0.205, 0.175, 0.70)],
        [(x, y, r.hip_z) for (x, y) in sq_ring(14, 0.185, 0.152, 0.66)],
        [(x, y, r.waist_z + 0.02) for (x, y) in sq_ring(14, 0.160, 0.125, 0.64)],
        [(x, y, r.chest_z) for (x, y) in sq_ring(14, 0.180, 0.135, 0.62)],
        [(x, y, r.sh_z) for (x, y) in sq_ring(14, 0.175, 0.135, 0.62)],
        [(x, y, r.sh_z + 0.03) for (x, y) in sq_ring(14, 0.100, 0.092, 0.62)],
    ], m_cloth, w_z([(r.ankle_z, {"skirt.B": 0.65, "hips": 0.35}),
                     (r.knee_z, {"skirt.F": 0.4, "skirt.B": 0.4, "hips": 0.2}),
                     (r.hip_z, {"hips": 1.0}),
                     (r.waist_z, {"hips": 0.7, "spine": 0.3}),
                     (r.chest_z, {"spine": 0.5, "chest": 0.5}),
                     (r.sh_z + 0.03, {"chest": 1.0})]))
    # 袍面金边（前襟 + 下摆）
    b.box((0.045, 0.02, 0.95), loc=(0, 0.128, r.waist_z - 0.30), material=m_gold,
          weight=w_z([(r.waist_z - 0.8, {"skirt.F": 0.8, "hips": 0.2}),
                      (r.waist_z, {"hips": 1.0})]), bevel=0.004)
    b.loft([
        [(x, y, r.ankle_z + 0.02) for (x, y) in sq_ring(14, 0.238, 0.203, 0.72)],
        [(x, y, r.ankle_z + 0.06) for (x, y) in sq_ring(14, 0.234, 0.199, 0.72)],
    ], m_gold, w_z([(r.ankle_z, {"skirt.B": 0.65, "hips": 0.35})]))

    # 肩披（短斗篷）
    b.loft([
        [(x, y, r.sh_z + 0.05) for (x, y) in sq_ring(12, 0.115, 0.100, 0.6)],
        [(x, y, r.sh_z - 0.02) for (x, y) in sq_ring(12, 0.200, 0.160, 0.6)],
        [(x, y, r.sh_z - 0.12) for (x, y) in sq_ring(12, 0.215, 0.175, 0.6)],
    ], m_cloth_d, w_rigid("chest"))
    # 胸前金圆徽
    b.cyl(0.062, 0.062, 0.016, loc=(0, 0.152, r.chest_z + 0.02), rot=(D(90), 0, 0),
          material=m_gold, weight=tw, sides=12)
    b.cyl(0.040, 0.040, 0.020, loc=(0, 0.160, r.chest_z + 0.02), rot=(D(90), 0, 0),
          material=m_cloth_d, weight=tw, sides=10)

    belt(b, r, m_leather, m_gold)
    # 腰包
    b.box((0.10, 0.06, 0.10), loc=(0.13, 0.10, r.waist_z - 0.07), material=m_leather,
          weight=w_rigid("hips"), bevel=0.012)

    for s, sx in (("L", -1.0), ("R", 1.0)):
        # 袍袖：沿手臂的两段喇叭袖（上袖细、下袖口宽）
        sh_p = (sx * r.sh_x, 0, r.sh_z)
        el_p = (sx * r.elbow_x, 0, r.elbow_z)
        wr_p = (sx * r.wrist_x, 0, r.wrist_z)
        seg(b, sh_p, el_p, 0.082, 0.098, m_cloth, "upperarm." + s, 10)
        seg(b, el_p, wr_p, 0.098, 0.125, m_cloth, "forearm." + s, 10)
        # 袖口金边（一圈厚箍）
        seg(b, (wr_p[0], wr_p[1], wr_p[2] + 0.035), (wr_p[0], wr_p[1], wr_p[2] - 0.005),
            0.128, 0.130, m_gold, "forearm." + s, 10)
        b.box((0.07, 0.08, 0.09), loc=(sx * (r.wrist_x + 0.02), 0.01, r.wrist_z - 0.045),
              material=m_skin, weight=w_rigid("hand." + s), bevel=0.014)
        # 靴子（袍下露出）
        b.box((0.10, 0.19, 0.06), loc=(sx * r.hip_x * 0.96, 0.05, 0.03), material=m_boot,
              weight=w_rigid("foot." + s), bevel=0.01)

    head_wizard(b, r, m_cloth, m_skin, m_hair, m_cloth_d, m_gold)
    staff(b, r, m_wood, m_crystal)

    objs = b.build_meshes(coll)
    r.bind(objs)
    for fn in (anim_idle, anim_walk, anim_cast, anim_hurt, anim_death):
        act = fn(r)
        r.push_nla(act)
    return r, objs


# ===========================================================================
# 单位：农民（布衣 + 草帽 + 锤）
# ===========================================================================

def build_peasant(H=1.66):
    coll = K3.reset_scene()
    r = HumanRig("peasant", H)
    r.build(coll)

    m_tunic = mat("cloth", team=True)
    m_tunic_d = mat("cloth_dark")
    m_leather = mat("leather")
    m_leather_d = mat("leather_dark")
    m_skin = mat("skin")
    m_hair = mat("hair")
    m_hay = mat("hay")
    m_iron = mat("iron")
    m_wood = mat("wood")

    b = Builder("peasant")
    tw = torso_w(r)

    # 布衣
    b.loft([
        [(x, y, r.hip_z - 0.10) for (x, y) in sq_ring(12, 0.150, 0.110, 0.66)],
        [(x, y, r.waist_z) for (x, y) in sq_ring(12, 0.142, 0.104, 0.66)],
        [(x, y, r.chest_z) for (x, y) in sq_ring(12, 0.168, 0.120, 0.64)],
        [(x, y, r.sh_z - 0.01) for (x, y) in sq_ring(12, 0.162, 0.118, 0.64)],
        [(x, y, r.sh_z + 0.03) for (x, y) in sq_ring(12, 0.092, 0.086, 0.62)],
    ], m_tunic, tw)
    # 下摆
    b.loft([
        [(x, y, r.hip_z - 0.10) for (x, y) in sq_ring(12, 0.152, 0.112, 0.66)],
        [(x, y, r.hip_z - 0.26) for (x, y) in sq_ring(12, 0.165, 0.122, 0.66)],
    ], m_tunic_d, w_rigid("hips"))
    belt(b, r, m_leather_d, m_iron)
    # 围裙
    b.box((0.24, 0.02, 0.34), loc=(0, 0.108, r.hip_z - 0.16), material=m_leather,
          weight=skirt_w(r, True), bevel=0.006)

    for s, sx in (("L", -1.0), ("R", 1.0)):
        # 布裤 + 皮靴
        hip = (sx * r.hip_x, 0, r.hip_z)
        knee = (sx * r.hip_x * 0.98, 0, r.knee_z)
        ankle = (sx * r.hip_x * 0.96, 0, r.ankle_z)
        seg(b, hip, (knee[0], 0, knee[2] + 0.02), 0.082, 0.068, m_leather, "thigh." + s, 9)
        seg(b, knee, ankle, 0.066, 0.050, m_leather_d, "shin." + s, 9)
        b.box((0.11, 0.22, 0.08), loc=(ankle[0], 0.045, 0.04), material=m_leather_d,
              weight=w_rigid("foot." + s), bevel=0.012)
        b.box((0.095, 0.095, 0.07), loc=(ankle[0], 0.14, 0.036), material=m_leather_d,
              weight=w_rigid("toe." + s), bevel=0.010)
        # 手臂（裸露小臂）
        sh = (sx * r.sh_x, 0, r.sh_z)
        el = (sx * r.elbow_x, 0, r.elbow_z)
        wr = (sx * r.wrist_x, 0, r.wrist_z)
        seg(b, sh, el, 0.070, 0.058, m_tunic, "upperarm." + s, 9)
        seg(b, el, wr, 0.055, 0.045, m_skin, "forearm." + s, 9)
        b.box((0.07, 0.08, 0.09), loc=(wr[0], 0.01, wr[2] - 0.03), material=m_skin,
              weight=w_rigid("hand." + s), bevel=0.012)

    # 头：脸 + 草帽
    b.box((r.head_w * 0.80, r.head_d * 0.78, r.head_h * 0.80),
          loc=(0, 0.004, r.chin + r.head_h * 0.40), material=m_skin,
          weight=w_rigid("head"), bevel=0.018)
    face_mask(b, r, m_skin, mat("steel_dark"), m_hair)
    # 草帽：帽檐压在额头上，帽冠兜住头顶
    b.cyl(0.205, 0.190, 0.024, loc=(0, 0, r.head_top - 0.048), material=m_hay,
          weight=w_rigid("head"), sides=14)
    b.cyl(0.092, 0.078, 0.095, loc=(0, 0, r.head_top - 0.050), material=m_hay,
          weight=w_rigid("head"), sides=12)
    # 脖子
    b.cyl(0.048, 0.048, 0.07, loc=(0, 0, r.neck_z - 0.02), material=m_skin,
          weight=w_rigid("neck"), sides=8)

    # 锤子（右手）
    hx = r.wrist_x + 0.01
    b.cyl(0.022, 0.020, 0.34, loc=(hx, 0.03, r.wrist_z - 0.20), material=m_wood,
          weight=w_rigid("hand.R"), sides=7)
    b.box((0.085, 0.085, 0.135), loc=(hx, 0.03, r.wrist_z - 0.375), material=m_iron,
          weight=w_rigid("hand.R"), bevel=0.010)
    b.cyl(0.026, 0.026, 0.05, loc=(hx, 0.03, r.wrist_z - 0.035), material=m_iron,
          weight=w_rigid("hand.R"), sides=6)
    # 腰后小包
    b.box((0.09, 0.06, 0.09), loc=(-0.13, -0.09, r.waist_z - 0.06), material=m_leather,
          weight=w_rigid("hips"), bevel=0.012)

    objs = b.build_meshes(coll)
    r.bind(objs)
    for fn in (anim_idle, anim_walk, anim_attack_sword, anim_gather, anim_build, anim_hurt, anim_death):
        act = fn(r)
        r.push_nla(act)
    return r, objs


BUILDERS = {
    "footman": build_footman,
    "crossbow": build_crossbow,
    "mage": build_mage,
    "peasant": build_peasant,
}

FILE_OF = {
    "footman": "步兵.glb",
    "crossbow": "弓箭手.glb",
    "mage": "法师.glb",
    "peasant": "农民.glb",
}

TARGET_H = {"footman": 1.78, "crossbow": 1.74, "mage": 1.80, "peasant": 1.66}


def main():
    import argparse
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    which = args[0] if args else "footman"
    do_qc = "--qc" in args
    do_export = "--export" in args
    names = list(BUILDERS.keys()) if which == "all" else [which]

    reports = []
    for nm in names:
        r, objs = BUILDERS[nm](TARGET_H[nm])
        r.rest_pose()
        mn, mx = K3.bbox(objs)
        rep = {
            "name": nm, "h": round(mx.z - mn.z, 3),
            "zmin": round(mn.z, 3), "zmax": round(mx.z, 3),
            "bbox": [round(v, 3) for v in (mx - mn)],
            "objs": [{"n": o.name, "z": [round(o.bound_box[0][2], 2), round(o.bound_box[6][2], 2)]} for o in objs],
        }
        if do_export:
            path = os.path.join(OUT_DIR, FILE_OF[nm])
            r.resume_nla()
            rep.update(K3.export_glb(path))
        if do_qc:
            r.preview_action("idle", 8)
            center = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            radius = max(mx.x - mn.x, mx.z - mn.z) * 0.5
            K3.render_views(nm, QC_DIR, center, max(radius, 0.6), res=(600, 780),
                            views={"正": (0.0, 1.0, 0.06), "三四": (0.85, 1.0, 0.22)})
        reports.append(rep)
        # 清理，避免下一个资产带着上一个的材质/动作
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
        for act in list(bpy.data.actions):
            bpy.data.actions.remove(act)
    print("HEADLESS " + json.dumps(reports, ensure_ascii=False))


if __name__ == "__main__":
    main()

