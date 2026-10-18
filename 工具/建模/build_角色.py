# -*- coding: utf-8 -*-
"""
build_角色.py —— 步兵 / 弓箭手 / 法师 三件一次出（共用 rig_human 骨架）
------------------------------------------------------------------
共同守则（条令 §1 / §9.2 + 用户红线）：
  * 身高分别 1.78 / 1.72 / 1.80；脚底 z=0；正面 Blender +Y → Godot -Z。
  * 平面着色；每件都有倒角 / 收分 / 板缝 / 铆钉 / 褶皱中的多项。
  * 材质分区靠明度分离：布料（亮）+ 皮革（深）+ 金属（冷）+ 点缀色。
  * 武器握点 = 掌心，Weapon 节点原点就是握点。
"""
import os
import sys
import math
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Matrix, Vector
import rts_kit as K
import rig_human as R

TAU = math.pi * 2.0
OUTROOT = os.path.join(K.OUT_ROOT, "角色")


# ------------------------------------------------------------------ 通用零件
def blade_prof(w, t):
    """剑身截面：菱形 + 两侧血槽（fuller）。"""
    return [(0.0, w * 0.50), (t * 0.44, w * 0.30), (t * 0.20, 0.0), (t * 0.44, -w * 0.30),
            (0.0, -w * 0.50), (-t * 0.44, -w * 0.30), (-t * 0.20, 0.0), (-t * 0.44, w * 0.30)]


def make_sword(hm, m_blade, m_hilt, m_gold, blade_len=0.72, tilt_fwd=38.0, tilt_out=8.0,
               name="长剑"):
    """长剑：剑身（血槽 + 收锋）+ 护手 + 握柄 + 配重球。握点在掌心。"""
    g = hm.grip_pt("R")
    a = math.radians(tilt_fwd)
    o = math.radians(tilt_out)
    axis = Vector((math.sin(o), math.sin(a) * math.cos(o), -math.cos(a) * math.cos(o))).normalized()
    # 柄（向上的短段 + 向下穿过拳心）
    K.parent_to(K.limb("剑柄", [(0.0, 0.016), (0.055, 0.018), (0.105, 0.016)],
                       m_hilt, tuple(g - axis * 0.055), tuple(-axis), sides=8, squarish=0.3),
                hm.E["Weapon"])
    K.parent_to(K.ico("配重球", 0.026, 1, m=m_gold, loc=tuple(g - axis * 0.082),
                      scale=(1, 1, 1.15)), hm.E["Weapon"])
    # 护手：横向长条 + 两端上翘
    guard_c = g + axis * 0.030
    K.parent_to(K.box("护手", (0.210, 0.032, 0.026), m=m_gold,
                      loc=(guard_c.x, guard_c.y, guard_c.z),
                      rot=(math.radians(-tilt_fwd), 0, 0), bevel=0.006), hm.E["Weapon"])
    for sx in (-1, 1):
        K.parent_to(K.box("护手端%d" % sx, (0.030, 0.026, 0.030), m=m_gold,
                          loc=(guard_c.x + sx * 0.082, guard_c.y - 0.018,
                               guard_c.z + 0.006),
                          rot=(math.radians(-tilt_fwd + 22), 0, 0), bevel=0.005),
                    hm.E["Weapon"])
    # 剑身
    secs = [(0.02, 0.054, 0.013), (0.10, 0.052, 0.013), (blade_len * 0.55, 0.046, 0.012),
            (blade_len * 0.82, 0.034, 0.009), (blade_len * 0.95, 0.017, 0.006),
            (blade_len, 0.003, 0.002)]
    K.parent_to(K.sweep("剑身", secs, m_blade, tuple(guard_c + axis * 0.012), tuple(axis),
                        prof=blade_prof, roll=math.radians(74)), hm.E["Weapon"])


def make_kite_shield(hm, m_face, m_rim, m_boss, w=0.46, h=0.80):
    """鸢盾：凸面 + 包边 + 中心盾脐 + 四枚铆钉。挂在 Shield 节点（Torso 下）。"""
    cx, cy, cz = -0.300, 0.158, 0.980
    poly = [(0.0, h * 0.50), (w * 0.33, h * 0.36), (w * 0.50, h * 0.04),
            (w * 0.34, -h * 0.26), (0.0, -h * 0.50), (-w * 0.34, -h * 0.26),
            (-w * 0.50, h * 0.04), (-w * 0.33, h * 0.36)]
    flat = [(p[0], -p[1]) for p in poly]
    face = K.dome("盾面", flat, 0.085, m_face, steps=3)
    M = Matrix.Translation(Vector((cx, cy, cz))) @ Matrix.Rotation(math.radians(-90), 4, "X")
    face.data.transform(M)
    K.parent_to(face, hm.E["Shield"])
    rim = K.dome("盾包边", [(p[0] * 1.06, p[1] * 1.06) for p in flat], 0.012, m_rim, steps=2)
    rim.data.transform(M)
    K.parent_to(rim, hm.E["Shield"])
    boss = K.ico("盾脐", 0.072, 1, m=m_boss, loc=(cx, cy + 0.082, cz), scale=(1, 0.55, 1))
    K.parent_to(boss, hm.E["Shield"])
    for i, (dx, dz) in enumerate(((0.16, 0.16), (-0.16, 0.16), (0.13, -0.20), (-0.13, -0.20))):
        K.parent_to(K.stud("盾铆%d" % i, (cx + dx * 0.86, cy + 0.026, cz + dz * 0.86), 0.015, 0.011,
                           m_rim, 5, (0, 1, 0)), hm.E["Shield"])
    # 背面握带 + 与左小臂的连杆（避免"盾浮在身前"）
    K.parent_to(K.box("盾带", (0.30, 0.024, 0.035), m=m_rim,
                      loc=(cx, cy - 0.035, cz + 0.06), bevel=0.005), hm.E["Shield"])
    K.parent_to(K.box("盾臂杆", (0.030, 0.150, 0.030), m=m_rim,
                      loc=(cx + 0.03, cy - 0.095, cz + 0.02),
                      rot=(math.radians(-8), 0, 0), bevel=0.004), hm.E["Shield"])


def hood(hm, m, flare=1.55, thick=0.016, m_in=None, cut_y=0.42, cut_z=0.66, peak=0.0):
    """兜帽：环状放样出帽壳 → 按谓词切出脸的开口 → 加厚。
    比"球体扣脑袋"多一件真实的东西：帽檐有厚度、开口有边。"""
    hh, hw, hd = hm.head_h, hm.head_w * 0.5, hm.head_d * 0.5
    z0 = hm.chin - hh * 0.30
    z1 = hm.head_top + hh * 0.06 + peak
    prof = [(0.00, flare), (0.20, flare * 0.82), (0.45, 1.16), (0.70, 1.08),
            (0.86, 0.96), (0.95, 0.62), (1.00, 0.22)]
    rr = [(z0 + (z1 - z0) * f, K.sq_ring(10, hw * s, hd * s, 0.60)) for (f, s) in prof]
    ob = K.loft("兜帽", rr, m)
    K.cut_faces(ob, lambda c: (c.y > hd * cut_y) and (c.z < hm.chin + hh * cut_z))
    K.solidify(ob, thick, bevel=0.004)
    K.parent_to(ob, hm.E["Head"])
    return ob


def pauldron(hm, side, m_plate, m_rim, layers=3, r0=0.082, growth=0.020, drop=0.052):
    """三层护肩：每一层是一个外扩的短裙环 + 深色包边，层层叠压。"""
    out = []
    for i in range(layers):
        d0 = -0.050 + i * drop
        r1 = r0 + growth * (i + 1)
        ob = hm.arm_band("护肩%d%s" % (i, side), side,
                         [(d0, r0 + growth * i * 0.55), (d0 + drop * 0.55, r1),
                          (d0 + drop * 0.92, r1 * 0.985)],
                         m_plate, ridges=0, squarish=0.25, sides=10)
        out.append(ob)
        rim = hm.arm_band("护肩边%d%s" % (i, side), side,
                          [(d0 + drop * 0.88, r1 * 0.99), (d0 + drop * 1.02, r1 * 0.93)],
                          m_rim, ridges=0, squarish=0.25, sides=10)
        out.append(rim)
    return out


def crest(hm, m, z_base, y0, y1, height, thick=0.020, teeth=5, m_tip=None):
    """盔缨：一条带锯齿顶边的薄鳍（网格面 + 加厚），从盔前扫到盔后。"""
    def fn(u, v):
        y = y0 + (y1 - y0) * u
        base = z_base - 0.035 * (2 * u - 1) ** 2
        h = height * (0.55 + 0.45 * math.sin(math.pi * u))
        saw = (0.62 + 0.38 * abs(((u * teeth) % 1.0) * 2.0 - 1.0))
        return (0.0, y, base + h * saw * v)
    ob = K.grid_surface("盔缨", 12, 3, 0.0, 0.0, fn, m)
    K.solidify(ob, thick, bevel=0.003)
    K.parent_to(ob, hm.E["Head"])
    return ob


# =============================================================================
# 1) 步兵 —— 剑盾兵 1.78
# =============================================================================
def build_footman():
    H = 1.78
    hm = R.Human("步兵", H)
    hm.build_rig()
    m_skin, m_dark, m_hair = K.mat("皮肤"), K.mat("阴影"), K.mat("须发")
    m_cloth, m_cloth2 = K.mat("布麻暗"), K.mat("革暗")
    m_plate, m_plate2 = K.mat("甲"), K.mat("钢暗")
    m_steel, m_rim = K.mat("钢"), K.mat("革")
    m_gold = K.mat("金")

    hm.neck_col(m_dark)
    # 躯干底层：厚棉甲（暗棕），外面再套板甲
    hm.torso(m_cloth2, rings=[(0.000, 0.120, 0.086), (0.055, 0.128, 0.092),
                              (0.140, 0.152, 0.101), (0.235, 0.170, 0.108),
                              (0.300, 0.160, 0.100), (0.345, 0.126, 0.088),
                              (0.382, 0.074, 0.064)])
    # 胸甲：凸面板 + 中央龙骨脊 + 上下两条板缝
    for sy, yy in ((1, 0.100), (-1, -0.100)):
        pl = R.plate("胸甲%d" % sy, 0.344, 0.400, 0.032, m_plate,
                     loc=(0, yy, hm.chest_z + 0.030), dome_k=0.062, segs=3)
        if sy < 0:
            pl.data.transform(Matrix.Rotation(math.pi, 4, "Z"))
        K.parent_to(pl, hm.E["Torso"])
    K.parent_to(K.box("龙骨", (0.030, 0.050, 0.300), m=m_plate2,
                      loc=(0, 0.128, hm.chest_z + 0.018),
                      rot=(math.radians(-4), 0, 0), bevel=0.006), hm.E["Torso"])
    for i, zoff in enumerate((-0.055, 0.075)):
        K.parent_to(K.box("板缝%d" % i, (0.286, 0.026, 0.014), m=m_plate2,
                          loc=(0, 0.126, hm.chest_z + zoff), bevel=0.003), hm.E["Torso"])
    for i in range(9):
        a = TAU * i / 9.0
        K.parent_to(K.stud("胸铆%d" % i,
                           (0.118 * math.cos(a), 0.126 + 0.010 * math.sin(a),
                            hm.chest_z + 0.150),
                           0.013, 0.010, m_plate2, 5, (math.cos(a), 0.4, 0)), hm.E["Torso"])
    # 腹甲 / 背甲
    K.parent_to(K.loft("腹甲", [(hm.waist_z + 0.012, K.sq_ring(12, 0.128, 0.094, 0.5)),
                               (hm.waist_z + 0.065, K.sq_ring(12, 0.140, 0.100, 0.5))],
                       m_plate), hm.E["Torso"])
    # 裙甲：三段叠压的札甲（半径一跳一收 = 甲片层次）
    for i in range(3):
        z0 = hm.waist_z - 0.030 - i * 0.062
        r = 0.146 + i * 0.012
        K.parent_to(K.loft("裙甲%d" % i, [(z0, K.sq_ring(12, r, r * 0.74, 0.5)),
                                        (z0 - 0.050, K.sq_ring(12, r * 1.03, r * 0.76, 0.5))],
                          m_plate), hm.E["Torso"])
        K.parent_to(K.loft("裙甲边%d" % i, [(z0 - 0.048, K.sq_ring(12, r * 1.04, r * 0.77, 0.5)),
                                          (z0 - 0.060, K.sq_ring(12, r * 0.99, r * 0.73, 0.5))],
                          m_plate2), hm.E["Torso"])
    # 腰带 + 扣
    K.parent_to(K.loft("腰带", [(hm.waist_z - 0.030, K.sq_ring(12, 0.132, 0.096, 0.55)),
                               (hm.waist_z + 0.020, K.sq_ring(12, 0.136, 0.099, 0.55))],
                       m_rim), hm.E["Torso"])
    K.parent_to(K.box("腰扣", (0.070, 0.024, 0.056), m=m_gold,
                      loc=(0, 0.104, hm.waist_z - 0.006), bevel=0.006), hm.E["Torso"])

    hm.pelvis(m_cloth2, rings=[(0.000, 0.120, 0.090), (0.060, 0.130, 0.097),
                               (0.130, 0.126, 0.094), (0.190, 0.110, 0.084)])
    for s in ("L", "R"):
        hm.leg(s, m_cloth2, thigh_r=0.098, shin_r=0.070, knee_pad=m_plate)
        hm.boot(s, m_plate, m_plate2, toe=0.205, height=0.105)
        # 胫甲：半圈护板（不是整筒，留出膝后弯曲）
        for i, (z0, z1, r) in enumerate(((hm.knee_z - 0.020, hm.knee_z - 0.150, 0.078),
                                         (hm.knee_z - 0.150, hm.knee_z - 0.290, 0.068))):
            ob = K.arc_wall("胫甲%d%s" % (i, s), 190, r, 0.022, z0, z1, 8,
                            m=m_plate, taper=0.94,
                            loc=(-0.090 if s == "L" else 0.090, 0, 0),
                            phase=math.radians(90))
            K.parent_to(ob, hm.E["Shin" + s])
    for s in ("L", "R"):
        hm.arm(s, m_cloth2, m_cuff=m_plate2, upper_r=0.070, fore_r=0.058,
               upper_scale=1.02, fore_scale=1.02, cuff=True)
        hm.hand(s, m_plate2, knuckle=m_plate)
        pauldron(hm, s, m_plate, m_plate2, layers=3)
        # 前臂板甲护臂
        hm.arm_band("护臂" + s, s, [(hm.ua + 0.030, 0.062), (hm.ua + 0.120, 0.060),
                                   (hm.ua + 0.200, 0.056), (hm.ua + 0.240, 0.052)],
                    m_plate, squarish=0.3, sides=10)
        hm.arm_band("护臂边" + s, s, [(hm.ua + 0.236, 0.054), (hm.ua + 0.250, 0.049)],
                    m_plate2, squarish=0.3, sides=10)

    # 头盔：盔壳 + 面甲（留呼吸缝）+ 护颊 + 鼻梁 + 盔缨
    hm.head(m_skin, m_dark, m_hair=m_hair, hair=False, eye_band=False)
    hh, hw, hd = hm.head_h, hm.head_w * 0.5, hm.head_d * 0.5
    z0 = hm.chin
    helm = [(z0 + hh * 0.33, K.sq_ring(10, hw * 1.10, hd * 1.08, 0.55)),
            (z0 + hh * 0.56, K.sq_ring(10, hw * 1.13, hd * 1.10, 0.55)),
            (z0 + hh * 0.78, K.sq_ring(10, hw * 1.08, hd * 1.02, 0.55)),
            (z0 + hh * 0.94, K.sq_ring(10, hw * 0.86, hd * 0.80, 0.55)),
            (z0 + hh * 1.04, K.sq_ring(10, hw * 0.44, hd * 0.40, 0.55))]
    hm.add(K.loft("盔", helm, m_plate, bevel=0.005), "Head")
    # 面甲（只盖下半张脸，留出眼缝）
    K.parent_to(K.box("面甲", (hw * 1.86, hd * 0.30, hh * 0.30), m=m_plate,
                      loc=(0, hd * 0.86, z0 + hh * 0.205),
                      rot=(math.radians(6), 0, 0), bevel=0.006), hm.E["Head"])
    for sx in (-1, 1):
        K.parent_to(K.box("护颊%d" % sx, (hw * 0.28, hd * 0.62, hh * 0.34), m=m_plate,
                          loc=(sx * hw * 0.86, hd * 0.36, z0 + hh * 0.20),
                          rot=(0, 0, math.radians(-10 * sx)), bevel=0.006), hm.E["Head"])
    K.parent_to(K.box("鼻梁", (hw * 0.18, hd * 0.42, hh * 0.34), m=m_plate,
                      loc=(0, hd * 0.90, z0 + hh * 0.40), bevel=0.005), hm.E["Head"])
    K.parent_to(K.box("眼缝", (hw * 1.30, 0.020, hh * 0.055), m=m_dark,
                      loc=(0, hd * 0.92, z0 + hh * 0.455), bevel=0.003), hm.E["Head"])
    crest(hm, m_plate2, z0 + hh * 1.00, -hd * 1.05, hd * 1.00, 0.100, 0.020, 5)
    K.parent_to(K.loft("盔箍", [(z0 + hh * 0.52, K.sq_ring(10, hw * 1.15, hd * 1.12, 0.55)),
                               (z0 + hh * 0.58, K.sq_ring(10, hw * 1.15, hd * 1.12, 0.55))],
                       m_gold), hm.E["Head"])

    make_sword(hm, m_steel, m_rim, m_gold, 0.66, 36.0, 8.0)
    make_kite_shield(hm, m_plate, m_plate2, m_gold)
    # 归零口径：先贴地 → 按身高归一 → 再贴地（归一缩放会把最低点带离 0，必须补一次）
    K.drop_to_ground()
    K.fit_height(1.78)
    K.drop_to_ground()
    outs, _, _ = K.render_views("步兵", os.path.join(OUTROOT), views=("正", "三四"),
                                res=(900, 900), samples=48)
    rep = K.export_glb(os.path.join(OUTROOT, "步兵.glb"))
    rep["views"] = outs
    return rep


# =============================================================================
# 2) 弓箭手 —— 1.72
# =============================================================================
def build_archer():
    H = 1.72
    hm = R.Human("弓箭手", H)
    hm.build_rig()
    m_skin, m_dark, m_hair = K.mat("皮肤"), K.mat("阴影"), K.mat("须发")
    m_leather, m_leather2 = K.mat("革"), K.mat("革暗")
    m_cloth, m_cloth2 = K.mat("布麻"), K.mat("布麻暗")
    m_pants = K.mat("布麻暗")
    m_wood, m_wood2 = K.mat("木"), K.mat("木暗")
    m_steel = K.mat("钢")
    m_brown = K.mat("木浅")

    hm.neck_col(m_skin)
    hm.torso(m_cloth, rings=[(0.000, 0.114, 0.082), (0.050, 0.120, 0.086),
                             (0.130, 0.142, 0.096), (0.225, 0.160, 0.103),
                             (0.290, 0.150, 0.096), (0.335, 0.120, 0.086),
                             (0.372, 0.072, 0.062)])
    # 皮甲：前胸三条横向甲片（每条独立凸起），背甲同一套
    for i, (zoff, w) in enumerate(((0.045, 0.300), (0.120, 0.312), (0.195, 0.318))):
        for sy in (1, -1):
            yy = 0.094 * sy
            pl = K.box("皮甲%d%d" % (i, sy), (w, 0.034, 0.062), m=m_leather,
                       loc=(0, yy, hm.waist_z + 0.055 + zoff),
                       rot=(math.radians(-3 * sy), 0, 0), bevel=0.010)
            K.parent_to(pl, hm.E["Torso"])
    # 肩带（从右肩斜到左腰，箭袋的承力带）
    hm.add(K.strap("斜肩带", [(0.086, 0.052, hm.sh_z - 0.010),
                              (0.020, 0.108, hm.chest_z + 0.010),
                              (-0.070, 0.098, hm.waist_z + 0.030)],
                   0.046, 0.014, m_leather2, bevel=0.004), "Torso")
    K.parent_to(K.box("肩带扣", (0.050, 0.024, 0.040), m=m_steel,
                      loc=(0.030, 0.112, hm.chest_z + 0.020), bevel=0.005),
                hm.E["Torso"])
    # 腰带 + 箭袋挂点
    hm.add(K.loft("腰带", [(hm.waist_z - 0.028, K.sq_ring(12, 0.124, 0.090, 0.55)),
                          (hm.waist_z + 0.018, K.sq_ring(12, 0.128, 0.093, 0.55))],
                 m_leather), "Torso")
    for i, (dx, dz) in enumerate(((-0.070, -0.075), (0.060, -0.080))):
        K.parent_to(K.box("腰包%d" % i, (0.062, 0.044, 0.070), m=m_leather2,
                          loc=(dx, 0.086, hm.waist_z + dz), bevel=0.008,
                          rot=(0, 0, math.radians(dx * 90))), hm.E["Torso"])

    hm.pelvis(m_pants, rings=[(0.000, 0.112, 0.084), (0.060, 0.120, 0.090),
                              (0.130, 0.116, 0.088), (0.190, 0.100, 0.078)])
    for s in ("L", "R"):
        hm.leg(s, m_pants, thigh_r=0.090, shin_r=0.066, knee_pad=m_leather)
        hm.leg_spiral(s, m_leather2, turns=2.4, width=0.030)
        hm.boot(s, m_leather, m_leather2, toe=0.200, height=0.100)
    for s in ("L", "R"):
        hm.arm(s, m_cloth, m_cuff=m_leather, upper_r=0.062, fore_r=0.052,
               cuff=True)
        hm.hand(s, m_skin, knuckle=m_leather)
        # 护臂（弓手左前臂最关键）：皮质宽护腕 + 两道绑绳
        hm.arm_band("护臂" + s, s, [(hm.ua + 0.075, 0.058), (hm.ua + 0.150, 0.060),
                                   (hm.ua + 0.225, 0.054)],
                    m_leather, squarish=0.2, sides=10)
        for i in range(2):
            d = hm.ua + 0.095 + i * 0.075
            hm.arm_band("臂绳%d%s" % (i, s), s, [(d, 0.062), (d + 0.012, 0.062)],
                        m_brown, squarish=0.2, sides=10)
        hm.arm_band("肩护" + s, s, [(-0.030, 0.070), (0.020, 0.082), (0.060, 0.078)],
                    m_leather, squarish=0.2, sides=10)

    hm.head(m_skin, m_dark, m_hair=m_hair, hair=True, eye_band=False)
    hood(hm, m_leather, flare=1.62, thick=0.018, cut_y=0.40, cut_z=0.64)
    # 兜帽垂肩的披幅
    hz = hm.sh_z
    K.parent_to(K.loft("帽披", [(hz + 0.020, K.fold_ring(12, 0.118, 0.090, 0.020, ridges=6)),
                               (hz - 0.055, K.fold_ring(12, 0.176, 0.126, 0.030, ridges=6)),
                               (hz - 0.105, K.fold_ring(12, 0.196, 0.140, 0.036, ridges=6))],
                       m_leather), hm.E["Torso"])

    # 箭袋（背后右侧，倾斜）+ 六支箭
    qx, qy, qz = 0.115, -0.145, hm.waist_z + 0.150
    K.parent_to(K.cyl("箭袋", 0.058, 0.050, 0.330, 10, m=m_leather, loc=(qx, qy, qz),
                      rot=(math.radians(12), 0, math.radians(-14))), hm.E["Torso"])
    for i in range(6):
        a = TAU * i / 6.0
        ax = qx + 0.030 * math.cos(a)
        ay = qy + 0.030 * math.sin(a)
        K.parent_to(K.cyl("箭杆%d" % i, 0.006, 0.006, 0.170, 5, m=m_wood,
                          loc=(ax, ay, qz + 0.300),
                          rot=(math.radians(12), 0, math.radians(-14))), hm.E["Torso"])
        K.parent_to(K.box("箭羽%d" % i, (0.004, 0.030, 0.048), m=m_cloth2,
                          loc=(ax + 0.030 * math.cos(a) * 0.2, ay, qz + 0.448),
                          rot=(0, 0, a), bevel=0.001), hm.E["Torso"])

    # 长弓（左手）：弯臂 + 弓弦 + 缠绳握把
    g = hm.grip_pt("L")
    bow_h = 0.660
    pts = []
    for i in range(11):
        t = i / 10.0
        z = bow_h - 2 * bow_h * t
        # 反曲：中间向前鼓，两端回勾
        y = 0.080 * math.sin(math.pi * t) - 0.052 * (abs(t - 0.5) * 2) ** 3
        pts.append((g.x - 0.010 * (1 - math.sin(math.pi * t)), g.y + y, g.z + z))
    K.parent_to(K.tube_along("长弓", pts, 0.022, m_wood, sides=6), hm.E["HandL"])
    K.parent_to(K.tube_along("弓弦", [(pts[0][0], pts[0][1] - 0.012, pts[0][2]),
                                     (g.x, g.y + 0.012, g.z),
                                     (pts[-1][0], pts[-1][1] - 0.012, pts[-1][2])],
                               0.0045, m_cloth2, sides=4), hm.E["HandL"])
    K.parent_to(K.loft("握把", [(g.z - 0.055, K.sq_ring(8, 0.021, 0.021, 0.2)),
                                (g.z + 0.055, K.sq_ring(8, 0.021, 0.021, 0.2))],
                       m_leather), hm.E["HandL"])
    for sy in (1, -1):
        K.parent_to(K.box("弓梢%d" % sy, (0.026, 0.040, 0.026), m=m_brown,
                          loc=(pts[0][0] if sy > 0 else pts[-1][0],
                               pts[0][1] if sy > 0 else pts[-1][1],
                               pts[0][2] if sy > 0 else pts[-1][2]),
                          rot=(math.radians(-18 * sy), 0, 0), bevel=0.004), hm.E["HandL"])

    K.drop_to_ground()
    K.fit_height(1.72)
    K.drop_to_ground()
    outs, _, _ = K.render_views("弓箭手", os.path.join(OUTROOT), views=("正", "三四"),
                                res=(900, 900), samples=48)
    rep = K.export_glb(os.path.join(OUTROOT, "弓箭手.glb"))
    rep["views"] = outs
    return rep


# =============================================================================
# 3) 法师 —— 1.80
# =============================================================================
def build_mage():
    H = 1.80
    hm = R.Human("法师", H)
    hm.build_rig()
    m_skin, m_dark, m_hair = K.mat("皮肤"), K.mat("阴影"), K.mat("须发")
    m_robe, m_robe2 = K.mat("布蓝"), K.mat("旗蓝")
    m_trim = K.mat("金")
    m_leather = K.mat("革")
    m_wood, m_wood2 = K.mat("木"), K.mat("木暗")
    m_gem = K.mat("魔法")
    m_glow = K.mat("魔法暗")
    m_paper = K.mat("布麻")

    hm.neck_col(m_skin)
    # 长袍主体：从肩到脚踝，八道竖向褶皱 + 下摆外扩
    robe = [(hm.ankle_z + 0.020, K.fold_ring(14, 0.226, 0.176, 0.040, ridges=8)),
            (hm.knee_z + 0.060, K.fold_ring(14, 0.210, 0.164, 0.038, ridges=8)),
            (hm.knee_z + 0.240, K.fold_ring(14, 0.208, 0.160, 0.038, ridges=8)),
            (hm.hip_z, K.fold_ring(14, 0.186, 0.140, 0.034, ridges=8)),
            (hm.waist_z + 0.010, K.fold_ring(14, 0.150, 0.110, 0.026, ridges=8)),
            (hm.chest_z, K.fold_ring(14, 0.166, 0.118, 0.028, ridges=8)),
            (hm.sh_z - 0.030, K.fold_ring(14, 0.150, 0.108, 0.024, ridges=8)),
            (hm.sh_z + 0.006, K.fold_ring(14, 0.104, 0.078, 0.014, ridges=8))]
    K.parent_to(K.loft("长袍", robe, m_robe), hm.E["Torso"])
    # 下摆金边
    K.parent_to(K.loft("袍摆边", [(hm.ankle_z + 0.006, K.fold_ring(14, 0.228, 0.178, 0.040, ridges=8)),
                                 (hm.ankle_z + 0.042, K.fold_ring(14, 0.230, 0.180, 0.040, ridges=8))],
                       m_trim), hm.E["Torso"])
    # 腰带（金扣 + 垂下的绦带）
    K.parent_to(K.loft("束带", [(hm.waist_z - 0.030, K.sq_ring(14, 0.152, 0.112, 0.55)),
                               (hm.waist_z + 0.022, K.sq_ring(14, 0.154, 0.114, 0.55))],
                       m_trim), hm.E["Torso"])
    K.parent_to(K.box("腰扣", (0.086, 0.028, 0.070), m=m_trim,
                      loc=(0, 0.118, hm.waist_z - 0.004),
                      rot=(0, 0, math.radians(45)), bevel=0.008), hm.E["Torso"])
    K.parent_to(K.ico("腰带宝石", 0.020, 1, m=m_gem, loc=(0, 0.134, hm.waist_z - 0.004)),
                hm.E["Torso"])
    # 胸前披幅（一层斜挂的短披，破掉"一整块袍"）
    K.parent_to(K.grid_surface("披幅", 5, 4, 0.0, 0.0, lambda u, v: (
        (-0.16 + 0.34 * u) * (1.0 - 0.18 * v),
        0.104 + 0.030 * v + 0.012 * math.sin(u * 6.0),
        hm.sh_z - 0.010 - 0.30 * v + 0.02 * math.sin(u * 5.0)), m_robe2), hm.E["Torso"])
    # 卷轴挂在腰侧
    K.parent_to(K.cyl("卷轴", 0.026, 0.026, 0.150, 8, m=m_paper,
                      loc=(-0.150, 0.070, hm.waist_z - 0.050),
                      rot=(math.radians(8), 0, math.radians(76))), hm.E["Torso"])
    for sx in (-1, 1):
        K.parent_to(K.cyl("卷轴头%d" % sx, 0.030, 0.030, 0.020, 8, m=m_wood2,
                          loc=(-0.150 + sx * 0.078, 0.070, hm.waist_z - 0.050),
                          rot=(math.radians(8), 0, math.radians(76))), hm.E["Torso"])

    hm.pelvis(m_robe2, rings=[(0.000, 0.116, 0.088), (0.060, 0.124, 0.094),
                              (0.130, 0.120, 0.090), (0.190, 0.104, 0.080)])
    for s in ("L", "R"):
        hm.leg(s, m_robe2, thigh_r=0.086, shin_r=0.062)
        hm.boot(s, m_leather, m_wood2, toe=0.195, height=0.096)
    for s in ("L", "R"):
        hm.arm(s, m_robe, m_cuff=m_trim, upper_r=0.064, fore_r=0.052, cuff=True,
               fore_scale=1.12)
        hm.hand(s, m_skin, knuckle=m_skin)
        # 宽大垂袖：袖口一圈大喇叭（法师身份的形）
        hm.arm_band("垂袖" + s, s, [(hm.ua + 0.060, 0.062), (hm.ua + 0.150, 0.080),
                                   (hm.ua + 0.230, 0.094), (hm.ua + 0.246, 0.090)],
                    m_robe, ridges=6, amp=0.10, sides=12)
        hm.arm_band("袖边" + s, s, [(hm.ua + 0.242, 0.092), (hm.ua + 0.252, 0.086)],
                    m_trim, squarish=0.15, sides=12)

    hm.head(m_skin, m_dark, m_hair=m_hair, hair=True, beard=1.0, eye_band=False)
    hood(hm, m_robe, flare=1.55, thick=0.018, cut_y=0.44, cut_z=0.70, peak=0.010)
    # 兜帽尖（后脑勺一个上扬的尖，法师的标志剪影）
    K.parent_to(K.prism("帽尖", [(-0.055, 0.0), (0.055, 0.0), (0.0, 0.170)], 0.075,
                        m=m_robe, loc=(0, -0.075, hm.head_top - 0.020),
                        rot=(math.radians(-118), 0, 0), bevel=0.008), hm.E["Head"])
    # 长须
    hh, hw_, hd_ = hm.head_h, hm.head_w * 0.5, hm.head_d * 0.5
    K.parent_to(K.prism("长须", [(-0.062, 0.0), (0.062, 0.0), (0.010, 0.200)], 0.048,
                        m=m_hair, loc=(0, hd_ * 0.92, hm.chin + hh * 0.15),
                        rot=(math.radians(96), 0, math.radians(90)), bevel=0.006),
                hm.E["Head"])

    # 法杖（握点在掌心，杖身外倾 12° 让上端从臂外通过）
    g = hm.grip_pt("R")
    ax = Vector((math.sin(math.radians(12)), math.sin(math.radians(5)),
                 math.cos(math.radians(12)))).normalized()
    bot = g - ax * 0.700
    top = g + ax * 0.720
    Lst = (top - bot).length
    K.parent_to(K.limb("法杖", [(0.0, 0.023), (Lst * 0.35, 0.020),
                               (Lst * 0.72, 0.021), (Lst, 0.023)],
                       m_wood, tuple(bot), tuple(ax), sides=8, squarish=0.3),
                hm.E["Weapon"])
    for i in range(3):
        c = g + ax * (0.055 + i * 0.048)
        K.parent_to(K.loft("杖缠%d" % i, [(c.z - 0.010, K.sq_ring(8, 0.025, 0.025, 0.1)),
                                        (c.z + 0.010, K.sq_ring(8, 0.025, 0.025, 0.1))],
                          m_leather), hm.E["HandL"])
    K.parent_to(K.loft("杖头座", [(top.z - 0.055, K.sq_ring(8, 0.030, 0.030, 0.1)),
                                 (top.z + 0.010, K.sq_ring(8, 0.048, 0.048, 0.1)),
                                 (top.z + 0.040, K.sq_ring(8, 0.036, 0.036, 0.1))],
                       m_trim), hm.E["Weapon"])
    # 爪形护宝石（三片外张的金属抓）
    for i in range(3):
        a = TAU * i / 3.0 + 0.4
        K.parent_to(K.box("杖爪%d" % i, (0.014, 0.014, 0.070), m=m_trim,
                          loc=(top.x + 0.042 * math.cos(a), top.y + 0.042 * math.sin(a),
                               top.z + 0.078),
                          rot=(math.radians(16) * math.sin(a), math.radians(-16) * math.cos(a), 0),
                          bevel=0.003), hm.E["Weapon"])
    K.parent_to(K.ico("杖宝石", 0.045, 1, m=m_gem, loc=(top.x, top.y, top.z + 0.088),
                      scale=(1, 1, 1.30)), hm.E["Weapon"])


    K.drop_to_ground()
    K.fit_height(1.80)
    K.drop_to_ground()
    outs, _, _ = K.render_views("法师", os.path.join(OUTROOT), views=("正", "三四"),
                                res=(900, 900), samples=48)
    rep = K.export_glb(os.path.join(OUTROOT, "法师.glb"))
    rep["views"] = outs
    return rep


# =============================================================================
if __name__ == "__main__":
    reps = []
    for fn in (build_footman, build_archer, build_mage):
        K.reset_scene()
        reps.append(fn())
    K.headless_report({"models": reps})
