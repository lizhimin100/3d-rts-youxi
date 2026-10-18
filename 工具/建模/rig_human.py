# -*- coding: utf-8 -*-
"""
rig_human.py —— 人形骨架式装配（铁血战歌 ANVIL）
------------------------------------------------------------------
坐标与枢轴约定（条令 §1 / §9.2）：
  * 轴序恒为 (x=左右, y=前后, z=高)；模型正面朝 **Blender +Y**（导出 = Godot -Z）；脚底 z=0。
  * 空物体层级 Root→Body→Torso→{Head, ArmL/R→Forearm→Hand}, Body→LegL/R→Shin→Foot。
  * 每个空物体原点 **就是关节**（肩/肘/髋/膝）；网格烘焙在世界坐标里，
    关节旋转必然绕关节转 —— 程序动画靠这个才不会"骨折"。
  * Weapon 挂 HandR 下，Shield 挂 Torso 下（条令 §9.2 逐字）。

比例（7.5 头身，全部由 H 推导，改 H 即整体缩放）：
  踝 1.9% · 膝 28.5% · 髋 53.5% · 腰 59.8% · 肩 81.8% · 颅顶 98.5%
  头高 = H/7.5，头宽 = 0.79 头高，肩关节距 = 2.05 头宽（护肩外扩到 ~2.7 头宽）
  上臂 17.5%H，前臂 14.5%H → 腕落在髋线略下（"手臂长度到髋部"）
  手臂外张 8°（A-pose）：手与髋不穿模，也给程序动画留摆动余量
"""

import math
import rts_kit as K
from mathutils import Vector, Matrix, Euler

TAU = math.pi * 2.0


class Human(object):
    def __init__(self, name, H, head_div=7.5, shoulder_k=2.20):
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
        self.splay = math.radians(8.0)

        self.elbow_z = self.sh_z - self.ua * math.cos(self.splay)
        self.wrist_z = self.elbow_z - self.fa * math.cos(self.splay)
        self.elbow_x = self.sh_x + math.sin(self.splay) * self.ua
        self.wrist_x = self.elbow_x + math.sin(self.splay) * self.fa

        self.E = {}
        self.parts = {}

    # ------------------------------------------------------------------ 骨架
    def build_rig(self):
        E = self.E
        E["Root"] = K.empty("Root", (0, 0, 0))
        E["Body"] = K.empty("Body", (0, 0, self.hip_z))
        K.parent_to(E["Body"], E["Root"])
        E["Torso"] = K.empty("Torso", (0, 0, self.waist_z))
        K.parent_to(E["Torso"], E["Body"])
        E["Head"] = K.empty("Head", (0, 0, self.neck_z))
        K.parent_to(E["Head"], E["Torso"])
        for s, sx in (("L", -1.0), ("R", 1.0)):
            a = K.empty("Arm" + s, (sx * self.sh_x, 0, self.sh_z))
            K.parent_to(a, E["Torso"])
            f = K.empty("Forearm" + s, (sx * self.elbow_x, 0, self.elbow_z))
            K.parent_to(f, a)
            h = K.empty("Hand" + s, (sx * self.wrist_x, 0, self.wrist_z))
            K.parent_to(h, f)
            E["Arm" + s], E["Forearm" + s], E["Hand" + s] = a, f, h

            lg = K.empty("Leg" + s, (sx * self.hip_x, 0, self.hip_z))
            K.parent_to(lg, E["Body"])
            sn = K.empty("Shin" + s, (sx * self.hip_x * 0.98, 0, self.knee_z))
            K.parent_to(sn, lg)
            ft = K.empty("Foot" + s, (sx * self.hip_x * 0.96, 0, self.ankle_z))
            K.parent_to(ft, sn)
            E["Leg" + s], E["Shin" + s], E["Foot" + s] = lg, sn, ft
        E["Weapon"] = K.empty("Weapon", tuple(self.grip_pt("R")))
        K.parent_to(E["Weapon"], E["HandR"])
        E["Shield"] = K.empty("Shield", (0, 0, self.chest_z))
        K.parent_to(E["Shield"], E["Torso"])
        return E

    def add(self, obj, bone):
        K.parent_to(obj, self.E[bone])
        return obj

    def arm_dir(self, side):
        sx = -1.0 if side == "L" else 1.0
        return Vector((sx * math.sin(self.splay), 0.0, -math.cos(self.splay))), sx

    def shoulder_pt(self, side):
        sx = -1.0 if side == "L" else 1.0
        return Vector((sx * self.sh_x, 0.0, self.sh_z))

    def wrist_pt(self, side):
        sx = -1.0 if side == "L" else 1.0
        return Vector((sx * self.wrist_x, 0.0, self.wrist_z))

    def hand_len(self):
        return self.head_h * 0.42

    def grip_pt(self, side="R"):
        """握点 = 掌心中心。Weapon 节点的原点必须落在这里，
        否则挥击动画会绕着腕关节外侧一个虚点转，看着像武器飘。"""
        sx = -1.0 if side == "L" else 1.0
        return Vector((sx * self.wrist_x, self.head_w * 0.30 * 0.12,
                       self.wrist_z - self.hand_len() * 0.34))

    # ------------------------------------------------------------------ 躯干
    def pelvis(self, m, rings=None):
        rings = rings or [(0.000, 0.148, 0.104),
                          (0.070, 0.156, 0.110),
                          (0.150, 0.152, 0.107),
                          (0.215, 0.132, 0.096)]
        rr = [(self.waist_z + z, K.sq_ring(12, rx, ry, 0.55)) for (z, rx, ry) in rings]
        return self.add(K.loft("骨盆", rr, m), "Body")

    def torso(self, m, rings=None, sides=12, name="躯干"):
        z0 = self.waist_z
        rings = rings or [(0.000, 0.126, 0.090),
                          (0.070, 0.138, 0.096),
                          (0.170, 0.164, 0.108),
                          (0.270, 0.182, 0.112),
                          (0.345, 0.176, 0.104),
                          (0.390, 0.150, 0.092)]
        rr = [(z0 + z, K.sq_ring(sides, rx, ry, 0.55)) for (z, rx, ry) in rings]
        return self.add(K.loft(name, rr, m), "Torso")

    def neck_col(self, m):
        z0, z1 = self.sh_z - 0.012, self.chin + 0.014
        rr = [(z0, K.ring_pts(8, 0.053, 0.051, math.pi / 8)),
              (z0 + (z1 - z0) * 0.5, K.ring_pts(8, 0.047, 0.046, math.pi / 8)),
              (z1, K.ring_pts(8, 0.043, 0.043, math.pi / 8))]
        return self.add(K.loft("脖颈", rr, m), "Torso")

    # ------------------------------------------------------------------ 头
    def head(self, m_skin, m_dark, m_hair=None, hair=True, beard=0.0, eye_band=True):
        """分面头颅：下颌收 → 颧骨 → 眉弓 → 颅顶收圆，全部沿环状放样。
        五官刻意做**大**：RTS 里脸只有几像素，"有没有五官"决定它像不像生物。
        眉弓一条横棱 + 鼻梁楔 + 两个内凹深色眼窝 + 眼罩式暗带（保证远看也有脸）。"""
        hh, hw, hd = self.head_h, self.head_w * 0.5, self.head_d * 0.5
        z0 = self.chin
        prof = [(0.020, 0.46, 0.48),
                (0.100, 0.70, 0.72),
                (0.240, 0.87, 0.86),
                (0.400, 0.95, 0.92),
                (0.580, 1.00, 0.95),
                (0.740, 0.97, 0.91),
                (0.870, 0.80, 0.75),
                (0.955, 0.50, 0.47),
                (1.000, 0.19, 0.18)]
        rr = [(z0 + f * hh, K.sq_ring(10, hw * sx, hd * sy, 0.62)) for (f, sx, sy) in prof]
        objs = [K.loft("头", rr, m_skin)]
        # 下颌（前下方一块斜切楔形）
        objs.append(K.box("下巴", (hw * 1.06, hd * 0.74, hh * 0.16), m=m_skin,
                          loc=(0, hd * 0.36, z0 + hh * 0.080),
                          rot=(math.radians(11), 0, 0), bevel=hw * 0.16))
        # 鼻：楔形，从眉间压到鼻底
        objs.append(K.prism("鼻", [(-0.020, 0.0), (0.020, 0.0), (0.0, 0.076)], 0.040,
                            m=m_skin, loc=(0, hd * 0.80, z0 + hh * 0.395),
                            rot=(math.radians(84), 0, math.radians(90)), bevel=0.005))
        objs.append(K.box("鼻翼", (hw * 0.34, hd * 0.16, hh * 0.048), m=m_skin,
                          loc=(0, hd * 0.86, z0 + hh * 0.335), bevel=0.006))
        # 眉弓：一条横贯的斜切条，给眼睛落影（最关键的一条人味）
        objs.append(K.box("眉弓", (hw * 1.62, hd * 0.30, hh * 0.070), m=m_skin,
                          loc=(0, hd * 0.76, z0 + hh * 0.560),
                          rot=(math.radians(-10), 0, 0), bevel=0.007))
        # 眼窝：内凹深色块（近黑），比五官其它件都大
        for sx in (-1, 1):
            objs.append(K.box("眼窝%d" % sx, (hw * 0.52, 0.030, hh * 0.088), m=m_dark,
                              loc=(sx * hw * 0.46, hd * 0.775, z0 + hh * 0.470),
                              rot=(math.radians(-4), 0, math.radians(-8 * sx)),
                              bevel=0.005))
        # 眼罩式暗带：把两只眼连成一条横带，远看轮廓就是"有脸"
        if eye_band:
            objs.append(K.box("眼带", (hw * 1.34, 0.014, hh * 0.052), m=m_dark,
                              loc=(0, hd * 0.860, z0 + hh * 0.470),
                              rot=(math.radians(-4), 0, 0), bevel=0.004))
        # 颧骨
        for sx in (-1, 1):
            objs.append(K.box("颧%d" % sx, (hw * 0.24, hd * 0.20, hh * 0.10), m=m_skin,
                              loc=(sx * hw * 0.74, hd * 0.60, z0 + hh * 0.340),
                              rot=(0, 0, math.radians(-14 * sx)), bevel=0.005))
        for sx in (-1, 1):
            objs.append(K.box("耳%d" % sx, (0.016, hd * 0.30, hh * 0.21), m=m_skin,
                              loc=(sx * hw * 0.945, -hd * 0.05, z0 + hh * 0.465),
                              bevel=0.005))
        objs.append(K.box("口", (hw * 0.56, 0.016, hh * 0.030), m=m_dark,
                          loc=(0, hd * 0.80, z0 + hh * 0.185), bevel=0.003))
        # 胡须（可选）：覆盖下颌与上唇，给角色立"身份"
        if beard > 0.0 and m_hair is not None:
            bm = None
            br = [(z0 + hh * 0.020, K.sq_ring(10, hw * 0.58, hd * 0.60, 0.62, cy=hd * 0.30)),
                  (z0 + hh * 0.130, K.sq_ring(10, hw * 0.86, hd * 0.86, 0.62, cy=hd * 0.08)),
                  (z0 + hh * 0.250, K.sq_ring(10, hw * 0.96, hd * 0.94, 0.62, cy=hd * 0.03)),
                  (z0 + hh * 0.300, K.sq_ring(10, hw * 0.92, hd * 0.90, 0.62, cy=hd * 0.02))]
            ob = K.loft("须", br, m_hair)
            K.cut_faces(ob, lambda c: c.y < -hd * 0.10)
            K.solidify(ob, 0.016 * beard)
            objs.append(ob)
        if hair and m_hair is not None:
            hr = [(z0 + hh * 0.60, K.sq_ring(10, hw * 1.03, hd * 0.99, 0.62)),
                  (z0 + hh * 0.78, K.sq_ring(10, hw * 1.02, hd * 0.96, 0.62)),
                  (z0 + hh * 0.91, K.sq_ring(10, hw * 0.84, hd * 0.79, 0.62)),
                  (z0 + hh * 1.01, K.sq_ring(10, hw * 0.46, hd * 0.44, 0.62))]
            objs.append(K.loft("头发", hr, m_hair))
        for o in objs:
            K.parent_to(o, self.E["Head"])
        self.parts["head"] = objs
        return objs

    # ------------------------------------------------------------------ 四肢
    def arm(self, side, m, m_cuff=None, upper_r=0.060, fore_r=0.050,
            upper_scale=1.0, fore_scale=1.0, cuff=True, smooth_k=0.6):
        d, sx = self.arm_dir(side)
        pivot = self.shoulder_pt(side)
        secs = [(0.010, upper_r * 1.04 * upper_scale),
                (0.070, upper_r * 1.08 * upper_scale),
                (0.180, upper_r * 0.97 * upper_scale),
                (self.ua - 0.010, upper_r * 0.80 * upper_scale)]
        up = K.limb("上臂" + side, secs, m, tuple(pivot), tuple(d), sides=8, squarish=smooth_k)
        ep = pivot + d * self.ua
        secs2 = [(0.008, fore_r * 1.00 * fore_scale),
                 (0.060, fore_r * 1.02 * fore_scale),
                 (self.fa * 0.62, fore_r * 0.86 * fore_scale),
                 (self.fa - 0.008, fore_r * 0.74 * fore_scale)]
        fo = K.limb("前臂" + side, secs2, m, tuple(ep), tuple(d), sides=8, squarish=smooth_k)
        objs = [up, fo]
        if cuff:
            wp = ep + d * (self.fa - 0.030)
            cr = [(0.000, K.sq_ring(8, fore_r * 0.94 * fore_scale, fore_r * 0.94 * fore_scale, 0.2)),
                  (0.026, K.sq_ring(8, fore_r * 1.06 * fore_scale, fore_r * 1.06 * fore_scale, 0.2)),
                  (0.040, K.sq_ring(8, fore_r * 0.88 * fore_scale, fore_r * 0.88 * fore_scale, 0.2))]
            co = K.loft("袖口" + side, cr, m_cuff or m)
            M = Matrix.Translation(wp) @ Vector((0, 0, -1)).rotation_difference(d).to_matrix().to_4x4()
            co.data.transform(M)
            objs.append(co)
        for o in objs:
            K.parent_to(o, self.E["Arm" + side])
        return objs, ep

    def hand(self, side, m, knuckle=None, wrap=True):
        """握拳：掌块 + 四道**横向**指节从掌前包过来（这样柄才像被握住，
        而不是"立在手边") + 拇指压条。武器沿 Z 轴穿过掌心 grip_pt。"""
        sx = -1.0 if side == "L" else 1.0
        p = self.wrist_pt(side)
        hl = self.hand_len()
        hwd = self.head_w * 0.30
        palm_y = hwd * 0.10
        objs = [K.box("掌" + side, (hwd * 1.00, hwd * 1.30, hl * 0.62), m=m,
                      loc=(p.x, palm_y, p.z - hl * 0.34),
                      rot=(math.radians(-5), 0, 0), bevel=0.007)]
        # 四指：同一 y 平面、沿 z 依次下移，从掌心前方包住竖直的柄
        for i in range(4):
            objs.append(K.box("指%d%s" % (i, side),
                              (hwd * 0.98, hwd * 0.46, hl * 0.145),
                              m=knuckle or m,
                              loc=(p.x, palm_y + hwd * 0.52,
                                   p.z - hl * (0.13 + 0.155 * i)),
                              rot=(math.radians(6), 0, 0), bevel=0.004))
        # 指背关节（四颗小方块，给"握"一个硬边）
        for i in range(4):
            objs.append(K.box("指节%d%s" % (i, side),
                              (hwd * 0.30, hwd * 0.20, hl * 0.11),
                              m=knuckle or m,
                              loc=(p.x + sx * hwd * 0.42,
                                   palm_y + hwd * 0.60,
                                   p.z - hl * (0.13 + 0.155 * i)),
                              bevel=0.002))
        objs.append(K.box("拇指" + side, (hwd * 0.42, hwd * 0.86, hl * 0.24),
                          m=knuckle or m,
                          loc=(p.x - sx * hwd * 0.46, palm_y + hwd * 0.24,
                               p.z - hl * 0.36),
                          rot=(math.radians(58), 0, math.radians(-sx * 14)), bevel=0.004))
        for o in objs:
            K.parent_to(o, self.E["Hand" + side])
        self.parts["hand" + side] = objs
        return p, objs

    def leg(self, side, m, thigh_r=0.086, shin_r=0.064, sides=10, squash=0.32,
            knee_pad=None):
        """大腿 / 小腿各自连续收分（膝、踝各只有一道折线），并在膝上补一块膝盖
        ——"每段一个台阶"是用户明令禁止的方块感来源。"""
        sx = -1.0 if side == "L" else 1.0
        pivot = (sx * self.hip_x, 0, self.hip_z)
        th = [(0.004, thigh_r * 0.98), (0.055, thigh_r * 1.05),
              (0.160, thigh_r * 0.96), (0.300, thigh_r * 0.84),
              (self.hip_z - self.knee_z - 0.020, thigh_r * 0.76),
              (self.hip_z - self.knee_z - 0.002, thigh_r * 0.72)]
        a = K.limb("大腿" + side, th, m, pivot, (0, 0, -1), sides=sides, squarish=squash)
        kp = (sx * self.hip_x * 0.98, 0, self.knee_z)
        sn = [(0.002, shin_r * 0.74), (0.030, shin_r * 0.94), (0.090, shin_r * 0.96),
              (0.190, shin_r * 0.78), (0.290, shin_r * 0.64),
              (self.knee_z - self.ankle_z - 0.010, shin_r * 0.56)]
        b = K.limb("小腿" + side, sn, m, kp, (0, 0, -1), sides=sides, squarish=squash)
        K.parent_to(a, self.E["Leg" + side])
        K.parent_to(b, self.E["Shin" + side])
        out = [a, b]
        if knee_pad is not None:
            kc = K.ico("膝垫" + side, shin_r * 0.86, 0, m=knee_pad,
                       loc=(kp[0], shin_r * 0.40, self.knee_z),
                       scale=(1.0, 0.72, 0.92))
            K.parent_to(kc, self.E["Shin" + side])
            out.append(kc)
        return out

    def leg_spiral(self, side, m, turns=2.6, z0=None, z1=None, width=0.030, thick=0.012):
        """小腿布带：一条**螺旋**斜缠的带子（扫掠扁截面）。
        比"一圈圈横棱"自然得多——横棱会读成一摞盒子。"""
        sx = -1.0 if side == "L" else 1.0
        z0 = self.ankle_z + 0.020 if z0 is None else z0
        z1 = self.knee_z - 0.060 if z1 is None else z1
        n = max(10, int(turns * 9))
        pts = []
        for i in range(n + 1):
            t = i / float(n)
            a = TAU * turns * t + (0.6 if sx < 0 else 0.0)
            r = (0.062 * (1.0 - t) + 0.040 * t) * (self.H / 1.78) * 1.10
            pts.append((sx * self.hip_x * 0.98 + r * math.cos(a), r * math.sin(a),
                        z0 + (z1 - z0) * t))
        ob = K.tube_along("绑腿" + side, pts, width * 0.55, m, sides=5)
        K.parent_to(ob, self.E["Shin" + side])
        return ob

    def boot(self, side, m, m_sole=None, toe=0.180, height=0.100):
        """靴：脚背收斜 + 鞋头楔 + 鞋跟。脚宽按解剖取 0.55 头宽，别做"两根筷子插小木块"。"""
        sx = -1.0 if side == "L" else 1.0
        fx = sx * self.hip_x * 0.96
        w = self.head_w * 0.55
        objs = [K.box("靴" + side, (w, toe * 0.78, height), m=m,
                      loc=(fx, toe * 0.26, height * 0.52), bevel=0.012,
                      top=0.84, top_off=(0, -toe * 0.05)),
                K.box("鞋头" + side, (w * 0.92, toe * 0.46, height * 0.58), m=m,
                      loc=(fx, toe * 0.66, height * 0.30), bevel=0.016,
                      top=0.76, top_off=(0, toe * 0.05)),
                K.box("鞋底" + side, (w * 1.05, toe * 1.02, 0.022), m=m_sole or m,
                      loc=(fx, toe * 0.30, 0.011), bevel=0.005),
                K.box("鞋跟" + side, (w * 0.84, toe * 0.26, 0.032), m=m_sole or m,
                      loc=(fx, -toe * 0.15, 0.016), bevel=0.005)]
        for o in objs:
            K.parent_to(o, self.E["Foot" + side])
        return objs

    def arm_band(self, name, side, secs, m, ridges=0, bone=None, amp=0.05,
                 sides=10, squarish=0.05):
        """沿手臂轴套一段环带（护肩 / 袖口 / 护腕）。secs=[(距肩距离, 半径), ...]，
        距离可负（伸到肩线以上）。ridges>0 → 布褶；0 → 光滑金属箍。"""
        d, _ = self.arm_dir(side)
        c = self.shoulder_pt(side)
        rings = []
        for (o, r) in secs:
            if ridges:
                pts = K.fold_ring(sides, r, r, amp, ridges=ridges)
            else:
                pts = K.sq_ring(sides, r, r, squarish)
            rings.append((-o, pts))
        ob = K.loft(name, rings, m)
        M = Matrix.Translation(c) @ Vector((0, 0, -1)).rotation_difference(d).to_matrix().to_4x4()
        ob.data.transform(M)
        K.parent_to(ob, self.E[bone or ("Arm" + side)])
        return ob

    def shin_wrap(self, side, m, count=4, z0=None, z1=None, pad=0.010):
        """绑腿：一条连续起伏的缠布（半径按 wrap 数做波纹）。
        分成一圈圈独立环会读成"方块套小腿"——必须连续曲面。"""
        sx = -1.0 if side == "L" else 1.0
        z0 = self.ankle_z + 0.028 if z0 is None else z0
        z1 = self.knee_z - 0.055 if z1 is None else z1

        def shin_r(z):
            t = (self.knee_z - z) / max(1e-6, self.knee_z - self.ankle_z)
            return (0.064 * (1.0 - t) + 0.041 * t) * (self.H / 1.78) * 1.06

        n = count * 6
        rings = []
        for i in range(n + 1):
            t = i / float(n)
            z = z0 + (z1 - z0) * t
            bulge = 0.30 + 0.70 * (0.5 + 0.5 * math.cos(count * TAU * t))
            r = shin_r(z) + pad * bulge
            rings.append((z, K.sq_ring(10, r, r, 0.06)))
        ob = K.loft("绑腿" + side, rings, m)
        ob.data.transform(Matrix.Translation(Vector((sx * self.hip_x * 0.98, 0, 0))))
        K.parent_to(ob, self.E["Shin" + side])
        return [ob]


# ---------------------------------------------------------------- 通用小件语法
def plate(name, w, h, t, m, loc, rot=(0, 0, 0), bevel=0.008, segs=2, dome_k=0.0):
    """装甲板：正面微凸（dome_k>0 时鼓起）+ 边缘倒角。纯平板一眼假，凸面是板甲的骨。"""
    if dome_k <= 0.0:
        return K.box(name, (w, t, h), m=m, loc=loc, rot=rot, bevel=bevel)
    bm = K.bmesh.new()
    n = max(2, segs)
    V = []
    for j in range(n + 1):
        row = []
        for i in range(n + 1):
            u = i / n * 2.0 - 1.0
            v = j / n * 2.0 - 1.0
            bulge = (1.0 - u * u) * (1.0 - v * v) * dome_k
            row.append(bm.verts.new((u * w * 0.5, bulge, v * h * 0.5)))
        V.append(row)
    for j in range(n):
        for i in range(n):
            bm.faces.new((V[j][i], V[j][i + 1], V[j + 1][i + 1], V[j + 1][i]))
    bm.normal_update()
    ob = K._finish(name, bm, m, loc, rot, (1, 1, 1))
    K.solidify(ob, t, bevel=bevel)
    return ob


def band(name, cx, cy, z, r, m, count=8, w=0.02, h=0.014, phase=0.0):
    """铆钉/包边环绕带（板缝两侧那种小钉），绕 Z 轴一圈。"""
    objs = []
    for i in range(count):
        a = phase + TAU * i / count
        p = (cx + r * math.cos(a), cy + r * math.sin(a), z)
        objs.append(K.stud("%s_%d" % (name, i), p, w, h, m, 5,
                           (math.cos(a), math.sin(a), 0)))
    return objs
