# -*- coding: utf-8 -*-
"""
build_农民.py —— 工兵「农民」低模资产（身高 1.62m）
------------------------------------------------------------------
要素：布衣束腰 + 背篓 + 镐 + 草帽。
形体语法（每条都是为了不像"方块摞方块"）：
  收腰断面 / 六道竖向褶的裙摆 / 胸前交领 V 字包边 / 肩披风盖住肩臂接缝 /
  袖口翻边 / 小腿缠布贴锥度 / 草帽下垂檐 + 帽箍 + 帽顶锥收 / 背篓三道箍 + 八立筋 /
  镐柄八角收锋 + 铁箍 + 双尖镐头带中脊。
姿态：A-pose 8°；镐外倾 12°/前倾 7°，让柄从肘外穿过（不然一定捅进小臂）。
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

H = 1.62
U = H / 1.78
OUT = os.path.join(K.OUT_ROOT, "农民")

K.reset_scene()
hm = R.Human("农民", H)
hm.build_rig()

m_skin = K.mat("皮肤")
m_dark = K.mat("阴影")
m_hair = K.mat("须发")
m_cloth = K.mat("布麻")
m_cloth2 = K.mat("布麻暗")
m_leather = K.mat("革")
m_leather2 = K.mat("革暗")
m_wood = K.mat("木")
m_wood2 = K.mat("木暗")
m_wood3 = K.mat("木浅")
m_steel = K.mat("钢")
m_steel2 = K.mat("钢暗")
m_straw = K.mat("茅草")
m_rope = K.mat("布白")
m_wood3b = K.mat("木浅")

hm.neck_col(m_skin)

# ================================================================ 躯干：布衣
hm.torso(m_cloth, rings=[(0.000, 0.118, 0.084),
                         (0.050, 0.124, 0.088),
                         (0.130, 0.146, 0.098),
                         (0.225, 0.162, 0.104),
                         (0.290, 0.155, 0.099),
                         (0.340, 0.126, 0.089),
                         (0.378, 0.076, 0.066)], sides=12)

# 肩部：不用整块"坎肩"（那会变成方领盒子），改成两条带褶的袖山环，
# 刚好盖住肩关节与躯干的接缝，同时保留肩线坡度
for s in ("L", "R"):
    hm.arm_band("袖山" + s, s, [(-0.045, 0.062 * U), (-0.012, 0.082 * U),
                               (0.030, 0.090 * U), (0.068, 0.080 * U),
                               (0.082, 0.070 * U)],
                m_cloth2, ridges=6, amp=0.055)
    hm.arm_band("袖山边" + s, s, [(0.076, 0.072 * U), (0.088, 0.074 * U)],
                m_leather, ridges=0, squarish=0.02)

# 裙摆：向下外扩 + 六道竖向褶
skirt = [(hm.waist_z - 0.012, K.fold_ring(12, 0.136, 0.096, 0.018, ridges=6)),
         (hm.hip_z - 0.010, K.fold_ring(12, 0.152, 0.108, 0.026, ridges=6)),
         (hm.hip_z - 0.075, K.fold_ring(12, 0.160, 0.113, 0.032, ridges=6)),
         (hm.hip_z - 0.135, K.fold_ring(12, 0.165, 0.117, 0.037, ridges=6))]
hm.add(K.loft("裙摆", skirt, m_cloth), "Torso")
hem_z = hm.hip_z - 0.135
hm.add(K.loft("裙摆包边", [(hem_z - 0.024, K.fold_ring(12, 0.163, 0.116, 0.034, ridges=6)),
                          (hem_z + 0.004, K.fold_ring(12, 0.169, 0.120, 0.038, ridges=6))],
              m_cloth2), "Torso")

# 束腰：宽皮带 + 钢扣 + 窄副带
hm.add(K.loft("腰带", [(hm.waist_z - 0.030, K.sq_ring(12, 0.126, 0.090, 0.55)),
                      (hm.waist_z - 0.010, K.sq_ring(12, 0.132, 0.094, 0.55)),
                      (hm.waist_z + 0.026, K.sq_ring(12, 0.132, 0.094, 0.55)),
                      (hm.waist_z + 0.042, K.sq_ring(12, 0.124, 0.089, 0.55))],
              m_leather), "Torso")
hm.add(K.box("带扣", (0.058, 0.020, 0.048), m=m_steel,
             loc=(0, 0.098, hm.waist_z + 0.006), bevel=0.005), "Torso")
hm.add(K.box("扣舌", (0.018, 0.012, 0.028), m=m_steel2,
             loc=(0, 0.110, hm.waist_z + 0.006), bevel=0.003), "Torso")
hm.add(K.loft("副带", [(hm.waist_z - 0.058, K.sq_ring(12, 0.136, 0.097, 0.55)),
                      (hm.waist_z - 0.042, K.sq_ring(12, 0.138, 0.099, 0.55))],
              m_leather2), "Torso")

# 交领 V 字：两条布边从双肩收到胸口一点（中国式右衽的简化）
for sx in (-1, 1):
    hm.add(K.strap("交领%d" % sx,
                   [(sx * 0.088, 0.074, hm.sh_z - 0.020),
                    (sx * 0.058, 0.096, hm.chest_z + 0.020),
                    (sx * 0.010, 0.098, hm.chest_z - 0.040)],
                   0.038, 0.012, m_cloth2, bevel=0.003), "Torso")
hm.add(K.box("领口", (0.086, 0.030, 0.024), m=m_cloth2,
             loc=(0, 0.094, hm.chest_z - 0.044), bevel=0.005), "Torso")

# 腰侧垂布 + 腰袋
def rag(u, v):
    x = 0.098 + 0.050 * u + 0.010 * math.sin(v * 5.0)
    z = hm.waist_z - 0.030 - v * 0.170
    y = 0.062 + 0.020 * math.sin(u * 3.0 + v * 2.2) + 0.012 * v
    return (x, y, z)
rag_ob = K.grid_surface("腰巾", 3, 5, 0.10, 0.17, rag, m_cloth2)
K.solidify(rag_ob, 0.008, bevel=0.003)
hm.add(rag_ob, "Torso")
hm.add(K.box("腰袋", (0.070, 0.048, 0.082), m=m_leather,
             loc=(-0.125, -0.024, hm.waist_z - 0.070), rot=(0, 0, math.radians(14)),
             bevel=0.009, top=1.06), "Torso")
hm.add(K.box("腰袋盖", (0.075, 0.054, 0.022), m=m_leather2,
             loc=(-0.125, -0.024, hm.waist_z - 0.030), rot=(0, 0, math.radians(14)),
             bevel=0.005), "Torso")

# ================================================================ 腿 / 靴
hm.pelvis(m_cloth2, rings=[(0.000, 0.120, 0.090),
                           (0.060, 0.130, 0.097),
                           (0.130, 0.128, 0.095),
                           (0.190, 0.112, 0.085)])
for s in ("L", "R"):
    hm.leg(s, m_cloth2, thigh_r=0.094 * U, shin_r=0.068 * U, knee_pad=m_leather)
    hm.leg_spiral(s, m_leather2, turns=2.6, width=0.034)
    hm.boot(s, m_leather, m_leather2, toe=0.215 * U, height=0.098 * U)

# ================================================================ 手臂
for s in ("L", "R"):
    hm.arm(s, m_cloth, m_cuff=m_cloth2, upper_r=0.064 * U, fore_r=0.055 * U,
           upper_scale=1.04, fore_scale=1.04, cuff=True)
    hm.hand(s, m_skin, knuckle=m_skin)
# 小臂皮护腕（单条，替掉原来的三圈白布）
for s in ("L", "R"):
    d, _ = hm.arm_dir(s)
    ep = hm.shoulder_pt(s) + d * hm.ua
    c = ep + d * (hm.fa * 0.42)
    rr = [(c.z - 0.030, K.sq_ring(8, 0.063 * U, 0.063 * U, 0.25)),
          (c.z + 0.020, K.sq_ring(8, 0.064 * U, 0.064 * U, 0.25)),
          (c.z + 0.032, K.sq_ring(8, 0.060 * U, 0.060 * U, 0.25))]
    ob = K.loft("护腕" + s, rr, m_leather)
    ob.data.transform(Matrix.Translation(Vector((c.x, c.y, 0))))
    K.parent_to(ob, hm.E["Arm" + s])

# ================================================================ 头 / 草帽
hm.head(m_skin, m_dark, m_hair=m_hair, hair=True, beard=0.75)
hat_z = hm.chin + hm.head_h * 0.62
brim_r = hm.head_w * 0.95
hat_objs = []
brim = [(hat_z + 0.012, K.ring_pts(14, brim_r * 0.42, brim_r * 0.43, 0.0)),
        (hat_z + 0.002, K.ring_pts(14, brim_r * 0.74, brim_r * 0.76, 0.0)),
        (hat_z - 0.018, K.ring_pts(14, brim_r * 1.00, brim_r * 1.02, 0.0))]
brim_ob = K.loft("帽檐", list(reversed(brim)), m_straw)
K.solidify(brim_ob, 0.010, bevel=0.004)
hat_objs.append(brim_ob)
crown = [(hat_z + 0.006, K.ring_pts(12, brim_r * 0.50, brim_r * 0.51, math.pi / 12)),
         (hat_z + 0.046, K.ring_pts(12, brim_r * 0.45, brim_r * 0.46, math.pi / 12)),
         (hat_z + 0.086, K.ring_pts(12, brim_r * 0.32, brim_r * 0.33, math.pi / 12)),
         (hat_z + 0.112, K.ring_pts(12, brim_r * 0.13, brim_r * 0.14, math.pi / 12))]
hat_objs.append(K.loft("帽冠", crown, m_straw, bevel=0.004))
hat_objs.append(K.loft("帽箍", [(hat_z + 0.008, K.ring_pts(12, brim_r * 0.515, brim_r * 0.525, math.pi / 12)),
                               (hat_z + 0.030, K.ring_pts(12, brim_r * 0.505, brim_r * 0.515, math.pi / 12))],
                        m_wood2))
# 帽子整体绕帽心后仰 9° —— 让主光照进帽檐，脸不至于全黑
Mhat = Matrix.Translation(Vector((0, 0, hat_z))) @ Matrix.Rotation(math.radians(9), 4, "X") @ \
    Matrix.Translation(Vector((0, 0, -hat_z)))
for o in hat_objs:
    o.data.transform(Mhat)
    hm.add(o, "Head")

# ================================================================ 背篓
basket_y = -0.205
bz0, bz1 = hm.waist_z - 0.030, hm.waist_z + 0.292
bk = [(bz0, K.sq_ring(8, 0.100, 0.086, 0.7)),
      (bz0 + 0.070, K.sq_ring(8, 0.120, 0.102, 0.7)),
      (bz0 + 0.180, K.sq_ring(8, 0.132, 0.112, 0.7)),
      (bz1, K.sq_ring(8, 0.134, 0.114, 0.7))]
bk_ob = K.loft("篓身", bk, m_wood3)
bk_ob.data.transform(Matrix.Translation(Vector((0.0, basket_y, 0.0))))
hm.add(bk_ob, "Torso")
for i, t in enumerate((0.16, 0.48, 0.80)):
    z = bz0 + (bz1 - bz0) * t
    rr = (0.100 + 0.034 * t) * 1.05
    ry = (0.086 + 0.028 * t) * 1.05
    hoop = K.loft("篓箍%d" % i, [(z - 0.013, K.sq_ring(8, rr, ry, 0.7)),
                                 (z + 0.013, K.sq_ring(8, rr, ry, 0.7))], m_wood)
    hoop.data.transform(Matrix.Translation(Vector((0.0, basket_y, 0.0))))
    hm.add(hoop, "Torso")
for i in range(8):
    a = K.TAU * i / 8.0 + math.pi / 8
    x = 0.121 * math.cos(a)
    y = basket_y + 0.102 * math.sin(a)
    hm.add(K.box("篓筋%d" % i, (0.012, 0.012, bz1 - bz0), m=m_wood,
                 loc=(x, y, (bz0 + bz1) * 0.5), rot=(0, 0, a), bevel=0.002), "Torso")
for i in range(5):
    a = K.TAU * i / 5.0 + 0.6
    x = 0.072 * math.cos(a)
    y = basket_y + 0.062 * math.sin(a)
    hm.add(K.prism("篓草%d" % i, [(-0.024, 0.0), (0.024, 0.0), (0.004, 0.098)], 0.010,
                   m=m_straw, loc=(x, y, bz1 - 0.006),
                   rot=(math.radians(-18 + i * 8), 0, a), bevel=0.002), "Torso")
# 背带只走肩后到篓口，不横穿胸前（横穿会和交领打成一团）
for sx in (-1, 1):
    hm.add(K.strap("背带%d" % sx,
                   [(sx * 0.076, basket_y + 0.028, bz1 - 0.014),
                    (sx * 0.100, -0.048, hm.sh_z + 0.004),
                    (sx * 0.104, 0.020, hm.sh_z + 0.014),
                    (sx * 0.086, 0.070, hm.chest_z + 0.046)],
                   0.030, 0.010, m_leather2, bevel=0.003), "Torso")

# ================================================================ 镐（右手）
# 握点 = 掌心（Weapon 节点原点就在这里），柄**穿过**手掌，不外挂
grip = hm.grip_pt("R")
tilt_out = math.radians(14.0)     # 外倾：柄从肘外通过，绝不穿小臂
tilt_fwd = math.radians(8.0)
axis = Vector((math.sin(tilt_out), math.sin(tilt_fwd), math.cos(tilt_out))).normalized()
butt = grip - axis * 0.300 * U
top = grip + axis * 0.500 * U
len_tot = (top - butt).length
K.parent_to(K.limb("镐柄", [(0.0, 0.020 * U), (0.34 * U, 0.017 * U), (0.80 * U, 0.020 * U)],
                  m_wood, tuple(butt), tuple(axis), sides=8, squarish=0.3), hm.E["Weapon"])
K.parent_to(K.cyl("镐尾", 0.026 * U, 0.018 * U, 0.030 * U, 8, m=m_steel2,
                  loc=(butt.x, butt.y, butt.z - 0.026 * U)), hm.E["Weapon"])
for i in range(2):
    c = butt + axis * (len_tot * (0.58 + 0.11 * i))
    K.parent_to(K.loft("镐箍%d" % i, [(c.z - 0.012 * U, K.sq_ring(8, 0.024 * U, 0.024 * U, 0.12)),
                                    (c.z + 0.012 * U, K.sq_ring(8, 0.024 * U, 0.024 * U, 0.12))],
                     m=m_steel2), hm.E["Weapon"])
# 镐头：沿 ±Y 双向收锋 + 中脊 + 铁座（朝外上方）
for sy in (1, -1):
    secs = [(0.000, 0.042 * U, 0.054 * U), (0.078 * U, 0.030 * U, 0.040 * U),
            (0.160 * U, 0.018 * U, 0.025 * U), (0.225 * U, 0.003 * U, 0.007 * U)]
    head = K.limb("镐尖%d" % sy, secs, m_steel, (top.x, top.y, top.z + 0.010 * U),
                  (0, sy, -0.12 * sy), sides=6, squarish=0.7)
    K.parent_to(head, hm.E["Weapon"])
K.parent_to(K.box("镐座", (0.060 * U, 0.076 * U, 0.062 * U), m=m_steel2,
                  loc=(top.x, top.y, top.z + 0.004 * U), bevel=0.007), hm.E["Weapon"])
K.parent_to(K.box("镐脊", (0.020 * U, 0.190 * U, 0.022 * U), m=m_steel2,
                  loc=(top.x, top.y, top.z + 0.028 * U), bevel=0.003), hm.E["Weapon"])
# ================================================================ 收尾
K.fit_height(1.62)
K.drop_to_ground()
outs, tgt, rad = K.render_views("农民", OUT, views=("正", "三四", "背"), res=(900, 900), samples=48)
rep = K.export_glb(os.path.join(OUT, "农民.glb"))
rep["views"] = outs
K.headless_report(rep)
