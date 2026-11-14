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

# ---------------------------------------------------------------------------
# 剪影体量系数（默认全 1.0 = 原样；v6/units_v6.py 在导入时覆盖）。
# 依据（2026-10-18 实证）：RTS 默认镜头下单位约 40px 高，玩家读出的是
# "体量 + 色块"，不是贴图细节——所以"单位变样"必须放大剪影关键件。
# ---------------------------------------------------------------------------
SIL = {
    "pauldron": 1.0,   # 护肩（横向外扩最显眼）
    "plume": 1.0,      # 盔顶羽饰（头顶轮廓 + 纯队伍色）
    "helm": 1.0,       # 大盔宽度
    "cape": 1.0,       # 披风宽度
    "shield": 1.0,     # 圆盾半径
    "sword": 1.0,      # 剑身长度/护手宽
    "bow": 1.0,        # 弩臂跨度（横向伸出的弩臂是弩手剪影签名）
    "crystal": 1.0,    # 法杖顶水晶（顶端发光点是法师辨识关键）
    "hat": 1.0,        # 法师宽檐帽
}


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
    width_k *= SIL["cape"]   # 剪影系数：披风加宽，背后队伍色块更大
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


def leg(b, r, s, sx, m_thigh, m_shin, m_boot, m_knee, m_cloth=None, m_sabaton=None, m_hi=None):
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
    if m_sabaton is not None:
        sabaton(b, r, s, sx, m_sabaton, m_hi or m_sabaton)
        # 靴口窄带（贴在小腿下端）
        band(b, ankle[0], 0, r.ankle_z + 0.095, r.ankle_z + 0.125, 0.070, 0.066,
             m_hi or m_sabaton, w_rigid("shin." + s), 10, 0.6)


def arm(b, r, s, sx, m_upper, m_fore, m_hand, m_pad, m_trim, m_hi=None):
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
    # SIL["pauldron"]：横向外扩 + 半径放大，40px 高度下肩线是第一辨识特征
    SP = SIL["pauldron"]
    for i in range(2):
        z = r.sh_z + 0.045 - i * 0.075
        cx = sx * (r.sh_x + (0.015 + i * 0.012) * SP)
        rr = (0.120 + i * 0.022) * SP
        b.ico(rr, loc=(cx, 0.0, z), material=m_pad,
              weight=w_rigid("shoulder." + s), subdiv=2, scale=(1.18, 1.10, 0.54))
        b.box((rr * 1.55, rr * 1.30, 0.026), loc=(cx, 0, z - 0.040 * min(SP, 1.3)),
              rot=(0, sx * D(-16), 0), material=m_trim,
              weight=w_rigid("shoulder." + s), bevel=0.006)
    # 第三层小肩盖 + 肩甲铆钉（护肩分层：大→中→小）
    b.box((0.115, 0.145, 0.030), loc=(sx * (r.sh_x + 0.004), 0.0, r.sh_z + 0.088),
          rot=(0, sx * D(-8), 0), material=m_hi or m_trim,
          weight=w_rigid("shoulder." + s), bevel=0.008)
    for i in range(2):
        rivet(b, (sx * (r.sh_x + 0.030 + i * 0.018), 0.088, r.sh_z + 0.052 - i * 0.070),
              m_hi or m_trim, "shoulder." + s, 0.010)
    # 护腕 + 手背甲
    vambrace(b, r, s, sx, m_fore, m_hi or m_trim, m_upper)
    b.box((0.068, 0.028, 0.066), loc=(wr[0], 0.052, wr[2] - 0.018),
          material=m_hi or m_trim, weight=w_rigid("hand." + s), bevel=0.008)


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
        b.box((hw * 0.22, 0.016, 0.020), loc=(sx * hw * 0.38, y + 0.002, z_eye - 0.004),
              material=m_dark, weight=W, bevel=0.002)
    # 下颌影（把方块脸读出体积）
    b.box((hw * 0.52, 0.020, 0.012), loc=(0, y - 0.008, z_eye - 0.185),
          material=m_dark, weight=W, bevel=0.001)
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


def plume(b, r, m_cloth, m_gold):
    """盔顶羽饰（队伍色）。

    为什么加这一条：魔兽3 的兵在 30m 镜头下只有 40px 高，靠"脸"认不出来，
    靠的是**剪影**（肩线 + 盔形 + 羽饰）和**颜色块**（队伍色）。
    羽饰同时给这两样：它把头顶轮廓抬高 0.22m，又是纯队伍色。
    """
    W = w_rigid("head")
    z0 = r.head_top + 0.005
    rings = []
    n = 6
    for i in range(n):
        t = float(i) / float(n - 1)
        z = z0 + math.sin(min(t * 1.30, math.pi * 0.60)) * 0.105 * SIL["plume"]
        y = -0.015 - 0.15 * t * SIL["plume"]
        rad = (0.038 * (1.0 - 0.55 * t) + 0.008) * SIL["plume"]
        rings.append([(math.cos(TAU * k / 8) * rad * 0.55, y,
                       z + math.sin(TAU * k / 8) * rad) for k in range(8)])
    b.loft(rings, m_cloth, W, cap_a=True, cap_b=True)
    # 羽饰底座（金）
    b.box((0.055, 0.075, 0.030), loc=(0, -0.01, z0 + 0.008), material=m_gold,
          weight=W, bevel=0.006)


def head_great_helm(b, r, m_helm, m_dark, m_gold, m_cloth=None, crest=False):
    """全罩式大盔（步兵）：方壳 + 眼缝 + 呼吸孔 + 护颊。"""
    hw, hd = r.head_w * 0.5 * SIL["helm"], r.head_d * 0.5 * SIL["helm"]
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
    # 帽檐（压低到额头上，不能悬空）—— 宽檐是法师的剪影签名
    b.cyl(hw * 2.10 * SIL["hat"], hw * 1.98 * SIL["hat"], 0.032, loc=(0, 0, r.head_top - 0.030), material=m_hat,
          weight=w_rigid("head"), sides=14)
    b.cyl(hw * 1.02, hw * 1.00, 0.060, loc=(0, 0, r.head_top - 0.035), material=m_hat,
          weight=w_rigid("head"), sides=12)
    # 帽锥（带弯）
    rings = []
    for i in range(6):
        t = i / 5.0
        z = r.head_top - 0.010 + t * r.head_h * 1.05 * SIL["hat"]
        rr = (hw * 1.10) * (1.0 - t) ** 1.25 + 0.006
        bend = 0.055 * (t ** 2.2)
        rings.append([(x + bend, y - bend * 0.35, z) for (x, y) in ring_pts(10, rr, rr * 0.92)])
    b.add(K3._bm_loft(rings), m_hat, w_rigid("head"))
    # 帽带
    b.cyl(hw * 1.14, hw * 1.14, 0.034, loc=(0, 0, r.head_top + 0.020), material=m_gold,
          weight=w_rigid("head"), sides=12)


def sword(b, r, m_blade, m_gold, m_grip, tip_len=0.10, m_hi=None, m_dark=None):
    """长剑：**局部坐标装配**（握把在原点，剑身沿 -Z），最后一次变换摆到右手。
    为什么这么做：以前每个零件各转一个角度，稍改一处就错位；统一变换后就一个旋钮。"""
    hx = r.wrist_x + 0.03
    M = (Matrix.Translation(Vector((hx, 0.06, r.wrist_z - 0.04)))
         @ Euler((D(18), 0, D(-6)), "XYZ").to_matrix().to_4x4())
    W = w_rigid("hand.R")
    blade_l = 0.62 * SIL["sword"]
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
    # 血槽 + 刃口高光
    blade_detail(b, M, W, m_dark or m_blade, m_hi or m_blade, blade_l)
    # 护手（中间 + 两侧翘起的护指）+ 柄 + 圆头
    b.box((0.19 * SIL["sword"], 0.034, 0.030), loc=(0, 0, -0.065), material=m_gold, weight=W, bevel=0.005, xform=M)
    for sx in (-1, 1):
        b.box((0.040, 0.030, 0.075), loc=(sx * 0.105, 0, -0.050),
              rot=(0, sx * D(28), 0), material=m_gold, weight=W, bevel=0.004, xform=M)
    b.cyl(0.018, 0.018, 0.12, loc=(0, 0, 0.0), material=m_grip, weight=W, sides=6, xform=M)
    for zz in (-0.030, 0.010, 0.048):
        b.cyl(0.021, 0.021, 0.010, loc=(0, 0, zz), material=m_dark or m_grip, weight=W,
              sides=6, xform=M)
    b.ico(0.028, loc=(0, 0, 0.075), material=m_gold, weight=W, subdiv=1, xform=M)


def shield_round(b, r, m_field, m_rim, m_boss):
    """圆盾：挂左臂（forearm.L），面朝前、略外倾。"""
    SS = SIL["shield"]
    cx, cy, cz = -r.sh_x * 1.44, 0.115, r.wrist_z + 0.02
    # 盾面（十六边形圆盘，向前 + 略外倾）
    b.cyl(0.285 * SS, 0.255 * SS, 0.030, loc=(cx, cy, cz), rot=(D(84), 0, D(-10)), material=m_field,
          weight=w_rigid("forearm.L"), sides=16)
    # 盾缘（一圈厚边）
    b.add(K3._bm_loft([
        [(cx + 0.285 * SS * math.cos(TAU * i / 16), cy - 0.015, cz + 0.285 * SS * math.sin(TAU * i / 16)) for i in range(16)],
        [(cx + 0.310 * SS * math.cos(TAU * i / 16), cy + 0.012, cz + 0.310 * SS * math.sin(TAU * i / 16)) for i in range(16)],
    ], cap_a=False, cap_b=False), m_rim, w_rigid("forearm.L"))
    # 中心凸起
    b.ico(0.070, loc=(cx, cy + 0.045, cz), material=m_boss,
          weight=w_rigid("forearm.L"), subdiv=2, scale=(1, 0.6, 1))
    shield_studs(b, r, m_boss, m_rim)
    # 放射筋
    for i in range(8):
        a = TAU * i / 8.0
        b.box((0.255 * SS, 0.014, 0.020),
              loc=(cx + 0.135 * SS * math.cos(a), cy + 0.032, cz + 0.135 * SS * math.sin(a)),
              rot=(0, D(90), a), material=m_rim, weight=w_rigid("forearm.L"), bevel=0.002)


def crossbow(b, r, m_wood, m_steel, m_string):
    """弩：**握把在右手腕的局部坐标**里装配（弩身沿 +Y 向前），由 hand.R 带动。
    这样举弩/瞄准/后坐全靠手臂骨骼，模型不需要另做一套动画。"""
    M = Matrix.Translation(Vector((r.wrist_x + 0.02, 0.02, r.wrist_z - 0.03)))         @ Euler((D(-6), 0, 0), "XYZ").to_matrix().to_4x4()
    W = w_rigid("hand.R")
    # 弩身 + 弩托
    b.box((0.044, 0.48, 0.044), loc=(0, 0.10, 0), material=m_wood, weight=W, bevel=0.007, xform=M)
    b.box((0.052, 0.18, 0.070), loc=(0, -0.10, -0.010), material=m_wood, weight=W, bevel=0.007, xform=M)
    # 弩臂（横）+ 两端弓梢 —— 横向跨度是弩手的剪影签名
    b.box((0.46 * SIL["bow"], 0.028, 0.024), loc=(0, 0.24, 0.004), material=m_steel, weight=W, bevel=0.005, xform=M)
    for sx in (-1, 1):
        b.box((0.10, 0.024, 0.022), loc=(sx * 0.26 * SIL["bow"], 0.29, 0.004), rot=(0, 0, sx * D(-12)),
              material=m_steel, weight=W, bevel=0.004, xform=M)
    # 弦 + 箭
    b.box((0.42 * SIL["bow"], 0.005, 0.005), loc=(0, 0.19, 0.004), material=m_string, weight=W, bevel=0.0, xform=M)
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
    # 水晶（顶端发光点，法师的辨识关键）
    b.ico(0.075 * SIL["crystal"], loc=(hx, 0.10, z0 + 1.90), material=m_crystal,
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
# 细节层（v4）：铆钉 / 护喉 / 护腕 / 靴甲 / 编纹 / 补丁 / 刃口
# ===========================================================================

def rivet(b, p, material, bone, s=0.012):
    """一颗铆钉。用极小的倒角保证它在近景里有高光断口。"""
    b.box((s, s * 0.7, s), loc=p, material=material, weight=w_rigid(bone), bevel=0.0015)


def gorget(b, r, m_a, m_hi, m_dark):
    """三层护喉：下大上小，最上一圈压暗，正面加喉板 + 铆钉。"""
    W = w_rigid("chest")
    band(b, 0, 0, r.sh_z - 0.010, r.sh_z + 0.036, 0.120, 0.102, m_a, W, 12, 0.58)
    band(b, 0, 0, r.sh_z + 0.036, r.sh_z + 0.072, 0.104, 0.090, m_a, W, 12, 0.58)
    band(b, 0, 0, r.sh_z + 0.072, r.neck_z + 0.038, 0.090, 0.079, m_hi, W, 12, 0.58)
    plate(b, (0.062, 0.016, 0.070), (0, 0.094, r.sh_z + 0.030), m_a, "chest", bevel=0.004)
    for sx in (-1, 1):
        rivet(b, (sx * 0.036, 0.102, r.sh_z + 0.030), m_hi, "chest", 0.009)


def vambrace(b, r, s, sx, m_steel, m_hi, m_dark):
    """护腕：前臂末端一圈铁箍 + 高光压边 + 铆钉。"""
    wr = (sx * r.wrist_x, 0, r.wrist_z)
    bone = "forearm." + s
    band(b, wr[0], 0, wr[2] + 0.000, wr[2] + 0.058, 0.071, 0.063, m_steel, w_rigid(bone), 10, 0.62)
    band(b, wr[0], 0, wr[2] + 0.058, wr[2] + 0.076, 0.075, 0.067, m_hi, w_rigid(bone), 10, 0.62)
    for zz in (0.020, 0.046):
        rivet(b, (wr[0] + sx * 0.048, 0.040, wr[2] + zz), m_dark, bone, 0.009)


def sabaton(b, r, s, sx, m_steel, m_hi):
    """靴甲：踝箍 + 脚背脊 + 趾甲板。"""
    ankle = (sx * r.hip_x * 0.96, 0, r.ankle_z)
    bone = "foot." + s
    band(b, ankle[0], 0, r.ankle_z + 0.040, r.ankle_z + 0.088, 0.072, 0.070, m_steel,
         w_rigid(bone), 10, 0.60)
    plate(b, (0.096, 0.080, 0.026), (ankle[0], 0.140, 0.046), m_hi, "toe." + s, bevel=0.006)
    plate(b, (0.022, 0.115, 0.018), (ankle[0], 0.072, 0.100), m_steel, bone,
          rot=(D(-12), 0, 0), bevel=0.004)


def chest_rivets(b, r, m_hi, m_dark):
    """胸甲下缘 + 两侧的铆钉列。"""
    for x in (-0.115, -0.058, 0.058, 0.115):
        rivet(b, (x, 0.126, r.chest_z - 0.135), m_hi, "chest", 0.011)
    for z in (r.chest_z - 0.08, r.chest_z + 0.00):
        for sx in (-1, 1):
            rivet(b, (sx * 0.150, 0.084, z), m_dark, "chest", 0.010)


def waist_lames(b, r, m_a, m_b, m_hi, count=4):
    """腰甲：多片叠压 + 每片前方一颗铆钉，片与片之间留暗缝。"""
    W = w_rigid("hips")
    for i in range(count):
        z0 = r.waist_z - 0.020 - i * 0.050
        band(b, 0, 0, z0, z0 + 0.044, 0.168 + i * 0.007, 0.124 + i * 0.006,
             m_a if i % 2 == 0 else m_b, W, 14, 0.60)
        rivet(b, (0, 0.128 + i * 0.006, z0 + 0.022), m_hi, "hips", 0.010)


def blade_detail(b, M, W, m_steel_d, m_hi, blade_l=0.62):
    """剑身细节：血槽（双侧暗线）+ 两侧刃口高光。M 是手的局部变换。"""
    b.box((0.011, 0.006, blade_l * 0.84), loc=(0, 0.0085, -0.08 - blade_l * 0.5),
          material=m_steel_d, weight=W, bevel=0.0, xform=M)
    b.box((0.011, 0.006, blade_l * 0.84), loc=(0, -0.0085, -0.08 - blade_l * 0.5),
          material=m_steel_d, weight=W, bevel=0.0, xform=M)
    for sx in (-1, 1):
        b.box((0.007, 0.016, blade_l * 0.92), loc=(sx * 0.025, 0, -0.08 - blade_l * 0.5),
              material=m_hi, weight=W, bevel=0.0, xform=M)


def shield_studs(b, r, m_hi, m_dark):
    """盾面：内圈暗环 + 四颗金铆 + 盾缘高光。"""
    cx, cy, cz = -r.sh_x * 1.44, 0.115, r.wrist_z + 0.02
    W = w_rigid("forearm.L")
    b.add(K3._bm_loft([
        [(cx + 0.225 * math.cos(TAU * i / 16), cy + 0.020, cz + 0.225 * math.sin(TAU * i / 16)) for i in range(16)],
        [(cx + 0.238 * math.cos(TAU * i / 16), cy + 0.022, cz + 0.238 * math.sin(TAU * i / 16)) for i in range(16)],
    ], cap_a=False, cap_b=False), m_dark, W)
    for i in range(4):
        a = TAU * i / 4.0 + math.pi * 0.25
        b.ico(0.020, loc=(cx + 0.195 * math.cos(a), cy + 0.035, cz + 0.195 * math.sin(a)),
              material=m_hi, weight=W, subdiv=1, scale=(1, 0.5, 1))


def straw_hat(b, r, m_hay, m_hay_d, m_cloth):
    """草帽：双层帽檐 + 同心/放射编纹 + 帽冠编纹 + 一块补丁。"""
    W = w_rigid("head")
    zt = r.head_top - 0.048
    b.cyl(0.205, 0.190, 0.022, loc=(0, 0, zt), material=m_hay, sides=14, weight=W)
    b.cyl(0.196, 0.188, 0.010, loc=(0, 0, zt + 0.020), material=m_hay_d, sides=14, weight=W)
    for i in range(12):
        a = TAU * i / 12.0
        b.box((0.115, 0.010, 0.007), loc=(0.100 * math.cos(a), 0.100 * math.sin(a), zt + 0.026),
              rot=(0, 0, a), material=m_hay_d, weight=W)
    for rr in (0.145, 0.174):
        b.cyl(rr, rr, 0.006, loc=(0, 0, zt + 0.026), material=m_hay_d, sides=14, weight=W)
    b.cyl(0.092, 0.078, 0.082, loc=(0, 0, zt - 0.004), material=m_hay, sides=12, weight=W)
    for zz in (0.030, 0.062):
        b.cyl(0.090 - zz * 0.16, 0.090 - zz * 0.16, 0.006, loc=(0, 0, zt + zz),
              material=m_hay_d, sides=12, weight=W)
    plate(b, (0.058, 0.006, 0.046), (0.118, 0.092, zt + 0.030), m_cloth, "head",
          rot=(0, 0, 0.55), bevel=0.002)
    # 帽檐破损：两处缺口用暗色小块压出来
    for (px, py) in ((-0.17, 0.06), (0.04, -0.18)):
        b.box((0.035, 0.012, 0.010), loc=(px, py, zt + 0.028), material=m_hay_d,
              weight=W, bevel=0.001)


def cloth_patch(b, p, sx, sz, rot, m_patch, m_stitch, bone):
    """补丁：一块深色布 + 四边缝线。"""
    plate(b, (sx, 0.006, sz), p, m_patch, bone, rot=rot, bevel=0.002)
    ca, sa = math.cos(rot[2]), math.sin(rot[2])
    for (ox, oz, w, h) in ((0, sz * 0.5, sx, 0.006), (0, -sz * 0.5, sx, 0.006),
                           (sx * 0.5, 0, 0.006, sz), (-sx * 0.5, 0, 0.006, sz)):
        px = p[0] + ox * ca - oz * sa
        pz = p[2] + ox * sa + oz * ca
        plate(b, (w, 0.008, h), (px, p[1] + 0.002, pz), m_stitch, bone, rot=rot, bevel=0.0)


def rope_belt(b, r, m_rope, m_rope_d):
    """麻绳腰带：两圈绳 + 绳结 + 垂绳。"""
    W = w_rigid("hips")
    for zz in (0.0, 0.018):
        band(b, 0, 0, r.waist_z - 0.040 + zz, r.waist_z - 0.020 + zz, 0.158, 0.116,
             m_rope, W, 12, 0.62)
    b.ico(0.034, loc=(0.0, 0.120, r.waist_z - 0.030), material=m_rope, weight=W,
          subdiv=1, scale=(1.0, 0.8, 0.8))
    b.tube([(0.018, 0.122, r.waist_z - 0.040), (0.030, 0.126, r.waist_z - 0.120),
            (0.024, 0.120, r.waist_z - 0.190)], 0.011, m_rope_d, weight=W, sides=5)


def boot_straps(b, r, s, sx, m_dark, m_iron):
    """皮靴绑带 + 小铁扣。"""
    ankle = (sx * r.hip_x * 0.96, 0, r.ankle_z)
    bone = "foot." + s
    for zz in (0.060, 0.105):
        band(b, ankle[0], 0, zz - 0.010, zz + 0.012, 0.060, 0.078, m_dark,
             w_rigid(bone), 8, 0.62)
        b.box((0.020, 0.014, 0.016), loc=(ankle[0] + sx * 0.050, 0.055, zz),
              material=m_iron, weight=w_rigid(bone), bevel=0.002)


def hammer_detail(b, r, m_wood_d, m_steel, m_hi):
    """农民锤：木柄缠绳 + 铁头高光面。"""
    hx = r.wrist_x + 0.01
    W = w_rigid("hand.R")
    for zz in (0.10, 0.16):
        b.cyl(0.024, 0.024, 0.018, loc=(hx, 0.03, r.wrist_z - 0.20 + zz), material=m_wood_d,
              sides=7, weight=W)
    b.box((0.070, 0.070, 0.030), loc=(hx, 0.03, r.wrist_z - 0.375 + 0.052),
          material=m_hi, weight=W, bevel=0.004)


def staff_detail(b, r, m_gold, m_steel, m_hi):
    """法杖：两道金属箍 + 三爪水晶座 + 箍上铆钉。"""
    hx = r.wrist_x + 0.01
    W = w_rigid("hand.R")
    for zz in (0.55, 1.15):
        b.cyl(0.030, 0.030, 0.055, loc=(hx, 0.10, 0.02 + zz), material=m_gold,
              sides=8, weight=W)
        b.cyl(0.033, 0.033, 0.012, loc=(hx, 0.10, 0.02 + zz + 0.030), material=m_hi,
              sides=8, weight=W)
        rivet(b, (hx + 0.030, 0.10, 0.02 + zz + 0.015), m_steel, "hand.R", 0.008)
    for i in range(3):
        a = TAU * i / 3.0
        b.tube([(hx + 0.020 * math.cos(a), 0.10 + 0.020 * math.sin(a), 1.760),
                (hx + 0.062 * math.cos(a), 0.10 + 0.062 * math.sin(a), 1.845),
                (hx + 0.030 * math.cos(a), 0.10 + 0.030 * math.sin(a), 1.930)],
               0.011, m_gold, weight=W, sides=4)


def feather(b, p, rot, m_white, m_dark, bone):
    """箭羽：一片薄羽 + 一根羽轴。"""
    b.box((0.052, 0.006, 0.075), loc=p, rot=rot, material=m_white,
          weight=w_rigid(bone), bevel=0.001)
    b.box((0.006, 0.008, 0.090), loc=(p[0], p[1], p[2]), rot=rot, material=m_dark,
          weight=w_rigid(bone), bevel=0.0)




def back_basket(b, r, m_wood, m_rope, m_cloth):
    """农民背篓：上宽下窄的柳条筐 + 三道绳箍 + 两根肩带。"""
    bone = "chest"
    zc = r.chest_z - 0.04
    b.loft([
        [(x, y - 0.20, zc - 0.22) for (x, y) in sq_ring(10, 0.105, 0.070, 0.62)],
        [(x, y - 0.22, zc + 0.02) for (x, y) in sq_ring(10, 0.140, 0.095, 0.62)],
        [(x, y - 0.22, zc + 0.16) for (x, y) in sq_ring(10, 0.150, 0.100, 0.62)],
    ], m_wood, w_rigid(bone))
    for zz in (-0.16, -0.02, 0.12):
        band(b, 0, -0.215, zc + zz - 0.012, zc + zz + 0.012, 0.140, 0.095, m_rope,
             w_rigid(bone), 10, 0.62)
    # 竖条柳编
    for i in range(10):
        a = TAU * i / 10.0
        b.box((0.020, 0.016, 0.36), loc=(0.128 * math.cos(a), -0.215 + 0.090 * math.sin(a),
                                       zc - 0.02), rot=(0, 0, a), material=m_rope,
              weight=w_rigid(bone), bevel=0.002)
    # 篓口沿
    band(b, 0, -0.215, zc + 0.150, zc + 0.172, 0.152, 0.102, m_wood,
         w_rigid(bone), 10, 0.62)
    # 肩带
    for sx in (-1, 1):
        b.tube([(sx * 0.09, -0.16, zc + 0.14), (sx * 0.11, -0.02, r.sh_z + 0.02),
                (sx * 0.10, 0.10, r.chest_z - 0.02)], 0.016, m_rope,
               weight=w_rigid(bone), sides=4)


def sleeve_cuff(b, r, s, sx, m_cloth_d, m_rope):
    """卷起的袖口：布箍 + 一道绳结，给农民的手臂加层次。"""
    el = (sx * r.elbow_x, 0, r.elbow_z)
    band(b, el[0], 0, el[2] + 0.010, el[2] + 0.060, 0.062, 0.058, m_cloth_d,
         w_rigid("upperarm." + s), 9, 0.62)
    band(b, el[0], 0, el[2] + 0.060, el[2] + 0.072, 0.066, 0.062, m_rope,
         w_rigid("upperarm." + s), 9, 0.62)


def hat_buckle(b, r, m_gold, m_hi):
    """法师帽带上的金扣。"""
    hd = r.head_d * 0.5
    W = w_rigid("head")
    b.box((0.060, 0.030, 0.048), loc=(0, hd * 0.92, r.head_top + 0.020), material=m_gold,
          weight=W, bevel=0.006)
    b.box((0.028, 0.020, 0.020), loc=(0, hd * 0.96, r.head_top + 0.020), material=m_hi,
          weight=W, bevel=0.003)


def robe_runes(b, r, m_gold, m_hi):
    """法师袍前襟的三枚金符 + 肩扣。"""
    W = w_rigid("chest")
    for i, zz in enumerate((r.chest_z - 0.10, r.chest_z - 0.22, r.chest_z - 0.34)):
        b.box((0.045, 0.012, 0.045), loc=(0, 0.138, zz), material=m_gold,
              weight=w_z([(zz - 0.2, {"skirt.F": 0.7, "hips": 0.3}), (r.chest_z, {"chest": 1.0})]),
              rot=(0, 0, math.radians(45)), bevel=0.003)
    for sx in (-1, 1):
        b.ico(0.030, loc=(sx * 0.085, 0.10, r.sh_z + 0.03), material=m_hi,
              weight=W, subdiv=1, scale=(1.0, 0.7, 1.0))


def crossbow_detail(b, r, m_steel, m_hi, m_wood_d):
    """弩：加脚蹬 + 箭镞高光 + 弩身暗箍。"""
    M = (Matrix.Translation(Vector((r.wrist_x + 0.02, 0.02, r.wrist_z - 0.03)))
         @ Euler((D(-6), 0, 0), "XYZ").to_matrix().to_4x4())
    W = w_rigid("hand.R")
    # 脚蹬
    for sx in (-1, 1):
        b.box((0.018, 0.16, 0.018), loc=(sx * 0.055, 0.40, -0.030), material=m_steel,
              weight=W, bevel=0.002, xform=M)
    b.box((0.130, 0.018, 0.018), loc=(0, 0.46, -0.030), material=m_steel,
          weight=W, bevel=0.002, xform=M)
    # 箭镞
    b.box((0.022, 0.055, 0.022), loc=(0, 0.43, 0.034), material=m_hi, weight=W, xform=M)
    # 弩身暗箍
    for yy in (-0.05, 0.06):
        b.box((0.048, 0.012, 0.048), loc=(0, yy, 0.0), material=m_wood_d,
              weight=W, bevel=0.002, xform=M)


def quiver_feathers(b, r, m_bone, m_dark):
    """箭袋口的箭羽。"""
    cx, cy, cz = -0.13, -0.16, r.chest_z - 0.02
    W = w_rigid("chest")
    for i in range(5):
        a = TAU * i / 5.0
        px = cx + 0.035 * math.cos(a)
        py = cy - 0.055 + 0.035 * math.sin(a)
        for k in (-1, 1):
            b.box((0.026, 0.004, 0.070), loc=(px + k * 0.010, py, cz + 0.40),
                  rot=(D(-16), D(8), a), material=m_bone if i % 2 == 0 else m_dark,
                  weight=W, bevel=0.0)


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
    """行走：**腿用关节链局部旋转**（不是绝对 aim），这是"走得像人"的关键。

    ★ 2026-10-18 重写（与 kit3.aim 的 roll 修复配套）：
      旧版对大腿/小腿/脚各打一个 armature 空间的绝对 aim，膝踝夹角不受控：
      小腿永远向后倒 17°+，脚被拽在身体后面，看起来像"人被脚拖着倒着跑"；
      叠加 aim 的 180° roll 之后，脚掌还会整片翻面。
      现在：大腿绕髋摆、小腿相对大腿屈、脚相对小腿俯仰，三者是链式关节；
      脚在原地不打滑（支撑相脚掌压平），摆腿相抬脚、屈膝、前送。
    """
    act = r.new_action(name)
    n = 8
    for i in range(n + 1):
        t = i / float(n)
        ph = t * TAU
        r.reset()
        # 躯干：轻微前倾 + 每步一次上下起伏 + 反相肩摆
        bob = -0.020 * math.cos(ph * 2.0)
        hips = r.arm.pose.bones.get("hips")
        if hips is not None:
            hips.location = Vector((0.0, bob, 0.0))
        r.aim("spine", (0, 0.055 + 0.012 * math.sin(ph * 2.0), 1.0), ref=(0, 1, 0))
        r.aim("chest", (0, 0.075, 1.0), ref=(0, 1, 0))
        r.aim("neck", (0, 0.06, 1.0), ref=(0, 1, 0))
        r.aim("head", (0, 0.045, 1.0), ref=(0, 1, 0))
        for s, sx, off in (("L", -1.0, 0.0), ("R", 1.0, math.pi)):
            a = ph + off
            swing = math.sin(a)
            lift = math.cos(a)
            # 大腿：+X 局部旋转 = 向前摆；幅度 23°
            r.pose_rot("thigh." + s, x=0.40 * swing, z=sx * 0.035)
            # 膝盖：**摆动相才屈膝**（大腿由后向前扫过时抬脚），支撑相伸直踩地。
            # 旧公式把屈膝峰值放在"大腿在最后面"的时候，等于把脚往后上方踢，看起来像倒跑。
            knee = 0.08 + 0.60 * max(0.0, math.cos(a - 0.25))
            r.pose_rot("shin." + s, x=-knee)
            # 脚：后蹬时压脚背、前伸时抬脚尖，支撑相保持贴地
            r.pose_rot("foot." + s, x=0.16 * swing - 0.04)
            r.pose_rot("toe." + s, x=0.10 * max(0.0, -swing))
            # 手臂反相摆（绝对 aim 对肩肘够用；roll 已由 aim 修复保住）
            r.aim("shoulder." + s, (sx, 0, 0.10), ref=(0, 0, 1))
            r.aim("upperarm." + s, (sx * 0.18, -0.30 * swing * (1.0 if s == "R" else -1.0), -1.0), ref=(0, 1, 0))
            r.aim("forearm." + s, (sx * 0.10, 0.10 - 0.22 * swing * (1.0 if s == "R" else -1.0), -1.0), ref=(0, 1, 0))
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
    """死亡：膝盖一软 → 后仰倒地 → 落地回弹 → 留最后一帧。

    ★ 2026-10-18 补：旧版只转骨头、不降髋，结果人像"悬在半空摆姿势"。
      这里给 hips 加局部 Y 平移（骨骼局部 Y = 世界向上），整个人真的落到地面上；
      同时把"倒地"的旋转放到 hips 上，spine/chest/head 只做跟随的小角度，
      避免各段绝对 aim 互相打架（头骨已按 H 修正，不会再被甩飞）。
    """
    act = r.new_action(name)
    for f, ph in ((1, 0.0), (6, 0.25), (16, 0.60), (24, 0.86), (31, 1.0)):
        r.reset()
        fall = min(1.0, ph * 1.18)
        # 落地缓动：前半段是失重倒下，后半段是砸地后的回弹
        drop = -0.80 * (fall * fall * (3.0 - 2.0 * fall))
        hips = r.arm.pose.bones.get("hips")
        if hips is not None:
            hips.location = Vector((0.0, drop, 0.0))
        # 整个躯干放平：hips/spine/chest/head 的绝对指向一起从"竖"转到"横"。
        # 只转 hips、让上面几节保持竖直 = 坐在地上，不是躺倒。
        r.aim("hips", (0.10 * fall, -0.95 * fall, 1.0 - fall), ref=(0, 1, 0))
        r.aim("spine", (0, -0.96 * fall, 1.0 - fall), ref=(0, 1, 0))
        r.aim("chest", (0, -0.97 * fall, 1.0 - fall), ref=(0, 1, 0))
        r.aim("head", (0, -0.98 * fall, 1.0 - fall), ref=(0, 1, 0))
        for s, sx in (("L", -1.0), ("R", 1.0)):
            # 腿：先跪，再向前摊平；脚背贴地
            r.aim("thigh." + s, (sx * (0.10 + 0.12 * fall), 0.62 * fall, -1.0 + fall * 0.95), ref=(0, 1, 0))
            r.aim("shin." + s, (sx * (0.02 + 0.10 * fall), 0.92 * fall, -0.35 + fall * 0.30), ref=(0, 1, 0))
            r.aim("foot." + s, (sx * 0.10 * fall, 1.0, -0.20 + 0.45 * fall), ref=(0, 0, 1))
            r.aim("upperarm." + s, (sx * (0.50 + 0.35 * fall), -0.42 * fall, -0.78 + 0.60 * fall), ref=(0, 1, 0))
            r.aim("forearm." + s, (sx * 0.45, -0.10 - 0.40 * fall, -0.70 + 0.55 * fall), ref=(0, 1, 0))
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
        b.box((0.27, 0.010, 0.008), loc=(0, 0.142, zz), material=m_steel_d,
              weight=tw, bevel=0.001)
    chest_rivets(b, r, m_steel_l, m_steel_d)
    # 胸甲上的蓝布饰带（队伍色）
    b.box((0.115, 0.020, 0.26), loc=(0, 0.152, r.chest_z + 0.02), material=m_cloth,
          weight=tw, bevel=0.004)
    # 护喉（三层）
    gorget(b, r, m_steel_d, m_steel_l, m_steel)

    belt(b, r, m_leather, m_gold)
    tabard(b, r, m_cloth, m_gold, front=True)
    tabard(b, r, m_cloth, m_gold, front=False)
    capesheet(b, r, m_cloth, width_k=1.0, z_bottom=r.hip_z - 0.30)

    # 腰甲（四片叠压 + 铆钉）
    waist_lames(b, r, m_steel, m_steel_d, m_steel_l, count=4)

    for s, sx in (("L", -1.0), ("R", 1.0)):
        leg(b, r, s, sx, m_steel, m_steel_d, m_steel, m_steel_l, m_cloth_d,
            m_sabaton=m_steel, m_hi=m_steel_l)
        arm(b, r, s, sx, m_steel, m_steel_d, m_steel_d, m_steel, m_gold, m_hi=m_steel_l)

    head_great_helm(b, r, m_steel, m_dark, m_gold)
    plume(b, r, m_cloth, m_gold)
    sword(b, r, m_steel_l, m_gold, m_leather, m_hi=m_steel_l, m_dark=m_steel_d)
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
        arm(b, r, s, sx, m_steel_d, m_leather, m_leather_d, m_steel, m_leather_d,
            m_hi=mat("steel_light"))
        # 肩甲只留一片
        b.box((0.16, 0.15, 0.05), loc=(sx * (r.sh_x + 0.02), 0, r.sh_z + 0.045),
              rot=(0, sx * D(-12), 0), material=m_steel, weight=w_rigid("shoulder." + s),
              bevel=0.012)

    head_hood(b, r, m_cloth, m_cloth_d, m_skin, m_hair)
    quiver(b, r, m_leather, m_steel, m_wood)
    quiver_feathers(b, r, mat("bone"), m_cloth_d)
    crossbow(b, r, m_wood, m_steel, m_steel_d)
    crossbow_detail(b, r, m_steel, mat("steel_light"), m_leather_d)

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

    # 外袍（腰到膝的第二层，深色 + 金边）
    b.loft([
        [(x, y, r.waist_z + 0.02) for (x, y) in sq_ring(14, 0.166, 0.132, 0.64)],
        [(x, y, r.hip_z - 0.06) for (x, y) in sq_ring(14, 0.198, 0.166, 0.66)],
        [(x, y, r.knee_z + 0.02) for (x, y) in sq_ring(14, 0.218, 0.186, 0.68)],
    ], m_cloth_d, w_z([(r.knee_z, {"skirt.F": 0.35, "skirt.B": 0.35, "hips": 0.3}),
                       (r.waist_z, {"hips": 1.0})]))
    band(b, 0, 0, r.knee_z + 0.015, r.knee_z + 0.050, 0.222, 0.190, m_gold,
         w_z([(r.knee_z, {"skirt.F": 0.35, "skirt.B": 0.35, "hips": 0.3})]), 14, 0.68)
    # 立领 + 金扣
    band(b, 0, 0, r.sh_z - 0.010, r.neck_z + 0.010, 0.108, 0.100, m_cloth_d,
         w_rigid("chest"), 12, 0.58)
    b.ico(0.028, loc=(0, 0.098, r.sh_z + 0.035), material=m_gold,
          weight=w_rigid("chest"), subdiv=1, scale=(1.0, 0.6, 1.0))
    # 袍摆褶（六道深色竖褶）
    for i in range(9):
        a = TAU * i / 9.0 + 0.3
        b.box((0.036, 0.022, 0.62), loc=(0.212 * math.cos(a), 0.180 * math.sin(a), r.knee_z - 0.24),
              rot=(0, math.radians(4.0), a), material=m_cloth_d,
              weight=w_z([(r.knee_z, {"skirt.F": 0.4, "skirt.B": 0.4, "hips": 0.2})]), bevel=0.003)
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

    # 腰带上的书匣 + 药囊
    b.box((0.10, 0.045, 0.14), loc=(0.135, -0.075, r.waist_z - 0.10), material=m_boot,
          weight=w_rigid("hips"), rot=(0, 0, 0.2), bevel=0.008)
    b.box((0.085, 0.012, 0.115), loc=(0.135, -0.050, r.waist_z - 0.10), material=m_gold,
          weight=w_rigid("hips"), rot=(0, 0, 0.2), bevel=0.003)
    b.ico(0.045, loc=(-0.125, 0.085, r.waist_z - 0.10), material=m_leather,
          weight=w_rigid("hips"), subdiv=1, scale=(1.0, 0.8, 1.1))
    head_wizard(b, r, m_cloth, m_skin, m_hair, m_cloth_d, m_gold)
    # 帽檐下层（压暗一圈）
    b.cyl(r.head_w * 0.5 * 2.02, r.head_w * 0.5 * 1.96, 0.014,
          loc=(0, 0, r.head_top - 0.044), material=m_cloth_d,
          weight=w_rigid("head"), sides=14)
    hat_buckle(b, r, m_gold, mat("gold_dark"))
    robe_runes(b, r, m_gold, mat("gold_dark"))
    staff(b, r, m_wood, m_crystal)
    staff_detail(b, r, m_gold, mat("gold_dark"), mat("gold_dark"))
    # 杖头金箍 + 帽尖金珠
    b.cyl(0.040, 0.040, 0.020, loc=(r.wrist_x + 0.01, 0.10, 1.735), material=m_gold,
          weight=w_rigid("hand.R"), sides=8)
    b.ico(0.028, loc=(0.055, -0.019, r.head_top + r.head_h * 1.05 + 0.005), material=m_gold,
          weight=w_rigid("head"), subdiv=1)

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
    m_rope = mat("rope")
    m_rope_d = mat("leather_dark")

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
    rope_belt(b, r, m_rope, m_rope_d)
    # 补丁（两处，带缝线）
    cloth_patch(b, (0.118, 0.104, r.chest_z - 0.075), 0.045, 0.038, (0, 0, 0.30),
                m_tunic_d, m_rope, "chest")
    cloth_patch(b, (-0.105, 0.118, r.hip_z - 0.020), 0.048, 0.052, (0, 0, -0.15),
                m_tunic_d, m_rope, "hips")
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
        boot_straps(b, r, s, sx, m_leather_d, m_iron)
        sleeve_cuff(b, r, s, sx, m_tunic_d, m_rope)
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
    # 草帽：编织纹 + 补丁
    straw_hat(b, r, m_hay, m_rope, m_tunic_d)
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
    hammer_detail(b, r, m_wood, m_iron, mat("steel_light"))
    # 腰后小包
    b.box((0.09, 0.06, 0.09), loc=(-0.13, -0.09, r.waist_z - 0.06), material=m_leather,
          weight=w_rigid("hips"), bevel=0.012)
    back_basket(b, r, m_wood, m_rope, m_tunic_d)
    # 领巾（三角布 + 结）
    b.add(K3._bm_loft([
        [(-0.085, 0.075, r.neck_z - 0.045), (0.085, 0.075, r.neck_z - 0.045),
         (0.085, 0.055, r.neck_z - 0.045), (-0.085, 0.055, r.neck_z - 0.045)],
        [(0.0, 0.070, r.chest_z - 0.055), (0.0, 0.070, r.chest_z - 0.055),
         (0.0, 0.055, r.chest_z - 0.055), (0.0, 0.055, r.chest_z - 0.055)],
    ], cap_a=True, cap_b=True), m_tunic_d, w_rigid("chest"))
    b.ico(0.025, loc=(0, 0.079, r.neck_z - 0.05), material=m_rope,
          weight=w_rigid("chest"), subdiv=1)
    # 围裙口袋
    b.box((0.13, 0.012, 0.10), loc=(0, 0.119, r.hip_z - 0.13), material=m_rope_d,
          weight=w_rigid("hips"), bevel=0.004)

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

TARGET_H = {"footman": 1.78, "crossbow": 1.72, "mage": 1.80, "peasant": 1.62}


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
            K3.render_views(nm, QC_DIR, center, max(radius, 0.6), res=(900, 1170),
                            views={"正": (0.0, 1.0, 0.06), "三四": (0.85, 1.0, 0.22)})
            # 近景细节（头肩/胸甲/盾面）
            K3.render_views(nm, QC_DIR, (0.0, 0.0, TARGET_H[nm] * 0.76), 0.40,
                            res=(1200, 1200), views={"近": (0.80, 1.0, 0.24)})
        reports.append(rep)
        # 清理，避免下一个资产带着上一个的材质/动作
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
        for act in list(bpy.data.actions):
            bpy.data.actions.remove(act)
    print("HEADLESS " + json.dumps(reports, ensure_ascii=False))


if __name__ == "__main__":
    main()

