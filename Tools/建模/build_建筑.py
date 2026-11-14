# -*- coding: utf-8 -*-
"""
build_建筑.py —— 大本营 / 兵营 / 铁匠铺 / 农场 / 箭塔（五件一次出）
------------------------------------------------------------------
形体语法（每件都靠这些摆脱"方块摞方块"）：
  砌石错缝 + 逐块深度起伏（Batch 合进单网格）/ 角石 / 砖拱券 / 窗套 + 窗台 /
  瓦垄逐片 / 硬山与歇山出檐 / 木构架（立柱 + 斜撑）/ 城垛与突堞 / 腰檐收分 /
  旗帜（网格面 + 正弦波）/ 门扇铁箍铆钉 / 台阶
朝向：正门朝 **Blender +Y**（导出 = Godot -Z）；地面 z=0；尺寸按条令 §1。
"""
import os
import sys
import math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Matrix, Vector, Euler
import rts_kit as K

TAU = math.pi * 2.0
OUT = os.path.join(K.OUT_ROOT, "建筑")


# ------------------------------------------------------------------ 小工具
def place(ob, loc=(0, 0, 0), rot=(0, 0, 0)):
    ob.data.transform(Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4())
    return ob


def stone_panel(name, w, h, thick, rows, m, seed=1, jitter=0.07):
    b = K.Batch(name, m)
    K.stone_courses(b, -w * 0.5, w * 0.5, 0.0, h, 0.0, rows=rows, thick=thick,
                    jitter=jitter, rng_seed=seed)
    return b.obj()


def wrap_stone(prefix, cx, cy, w, d, z0, z1, rows, m, thick=0.09, jitter=0.07, seed=1):
    """四面砌石皮（front/back/left/right），返回四个对象。"""
    out = []
    h = z1 - z0
    p = stone_panel(prefix + "前", w, h, thick, rows, m, seed)
    out.append(place(p, (cx, cy + d * 0.5, z0)))
    p = stone_panel(prefix + "后", w, h, thick, rows, m, seed + 1)
    out.append(place(p, (cx, cy - d * 0.5, z0), (0, 0, math.pi)))
    p = stone_panel(prefix + "左", d, h, thick, rows, m, seed + 2)
    out.append(place(p, (cx - w * 0.5, cy, z0), (0, 0, -math.pi * 0.5)))
    p = stone_panel(prefix + "右", d, h, thick, rows, m, seed + 3)
    out.append(place(p, (cx + w * 0.5, cy, z0), (0, 0, math.pi * 0.5)))
    return out


def arch(prefix, cx, cy, w, z0, z1, m, depth=0.12, seg=5, thick=0.16):
    """砖拱券：半圆砌块 + 两侧券脚（门/窗/炉口的顶）。"""
    r = w * 0.5
    objs = []
    for i in range(seg + 1):
        a = math.pi * i / seg
        x = cx + r * math.cos(a)
        z = z1 + r * 0.55 * math.sin(a)
        objs.append(place(K.box("%s券%d" % (prefix, i), (w * 0.30, depth, thick),
                                m=m, bevel=0.008), (x, cy, z), (0, a - math.pi * 0.5, 0)))
    return objs


def crenellation(prefix, p0, p1, m, step=0.86, mw=0.42, mh=0.55, thick=0.34, axis="x"):
    """城垛：沿直线等距的垛口块（比一整条矮墙有节奏）。"""
    a = Vector(p0)
    b = Vector(p1)
    d = (b - a)
    L = d.length
    n = max(1, int(L / step))
    out = []
    for i in range(n):
        t = (i + 0.5) / n
        p = a.lerp(b, t)
        size = (mw, thick, mh) if axis == "x" else (thick, mw, mh)
        out.append(K.box("%s%d" % (prefix, i), size, m=m,
                         loc=(p.x, p.y, p.z + mh * 0.5), bevel=0.010,
                         top=0.88, top_off=(0, 0)))
    return out


def banner(prefix, base, height, m_pole, m_cloth, width=0.55, length=1.10,
           face_y=0.0, wave=0.055, flip=1):
    """旗：杆 + 杆头 + 带正弦波的旗面（网格面 + 加厚）。"""
    x, y, z = base
    out = [K.limb(prefix + "杆", [(0.0, 0.030), (height * 0.55, 0.024), (height, 0.018)],
                  m_pole, (x, y, z), (0, 0, 1), sides=8, squarish=0.25),
           K.ico(prefix + "杆头", 0.055, 1, m=m_pole, loc=(x, y, z + height + 0.030),
                 scale=(1, 1, 1.3))]
    zt = z + height - 0.06
    zb = zt - length

    def fn(u, v):
        xx = x + flip * width * (1.0 - u)
        zz = zt - length * v
        yy = y + face_y + wave * math.sin(u * 5.4 + 0.4) * (0.35 + 0.65 * u)
        return (xx, yy, zz)
    cl = K.grid_surface(prefix + "面", 5, 6, 0.0, 0.0, fn, m_cloth)
    K.solidify(cl, 0.016, bevel=0.003)
    out.append(cl)
    return out


def ladder(prefix, x, y, z0, z1, m):
    out = []
    n = max(3, int((z1 - z0) / 0.30))
    for i in range(n + 1):
        z = z0 + (z1 - z0) * i / n
        out.append(K.box("%s踏%d" % (prefix, i), (0.34, 0.05, 0.035), m=m,
                         loc=(x, y, z), bevel=0.004))
    for sx in (-1, 1):
        out.append(K.box("%s梁%d" % (prefix, sx), (0.045, 0.05, z1 - z0), m=m,
                         loc=(x + sx * 0.155, y, (z0 + z1) * 0.5), bevel=0.004))
    return out


def roof_pitched(prefix, cx, cy, w, d, z0, rise, m_roof, m_ridge, over=0.34,
                 tiles=True):
    """双坡屋盖：两片斜板 + 屋脊 + 出檐 + 瓦垄。

    瓦片尺度：《美术规范》§4 的面数预算。原密度（行距 0.26m / 列距 0.32m）
    让兵营屋瓦一项就吃掉 16456 tris（占整栋 61%），实测证据在 _diag4。
    放大到 0.46 / 0.52 之后瓦片数降到约 0.35 倍，同时瓦变大 ——
    这正是 §1.1 要的"大块面"，RTS 距离下比密排小瓦更清楚。
    """
    run = d * 0.5 + over
    ang = math.atan2(rise, run)
    slope_len = math.hypot(rise, run)
    objs = []
    for sy in (1, -1):
        # 屋面底板（先铺一层实心斜板，再压瓦垄）：
        # 没有它，瓦垄之间的缝会直接漏出内墙 —— 实测兵营屋顶被读成"悬空的木条架"。
        # 底板用脊色（深），缝隙因此读成瓦垄之间的阴影线，而不是洞。
        objs.append(K.box(prefix + "板%d" % sy,
                          (w + 0.06, slope_len * 1.02, 0.06), m=m_ridge,
                          loc=(cx, cy + sy * run * 0.5, z0 + rise * 0.5),
                          rot=(-sy * ang, 0, 0), bevel=0.010))
        b = K.Batch(prefix + "瓦%d" % sy, m_roof)
        # 行距必须 ≤ 瓦片沿坡向的覆盖长度，否则瓦垄之间会漏出屋顶底板
        # （实测把行距放到 0.46 时，兵营屋顶被读成"一根根悬空的木条" —— 已回退）。
        # 省面数改从**列距**下手：瓦片加宽 → 列数减半，行数保持密排不出缝。
        nrow = max(3, int(slope_len / 0.32))
        ncol = max(4, int(w / 0.66))
        for r in range(nrow):
            t = (r + 0.5) / nrow
            yy = cy + sy * (run - run * t)
            zz = z0 + rise * t
            for c in range(ncol + (r % 2)):
                xx = cx - w * 0.5 + (c + 0.5) * (w / ncol)
                if abs(xx - cx) > w * 0.52:
                    continue
                b.box((w / ncol * 0.90, slope_len / nrow * 1.35, 0.055),
                      loc=(xx, yy, zz), rot=(-sy * ang, 0, 0), bevel=0.007, top=0.95)
        objs.append(b.obj())
    objs.append(K.box(prefix + "脊", (w + 0.10, 0.16, 0.14), m=m_ridge,
                      loc=(cx, cy, z0 + rise + 0.04), bevel=0.012))
    for sy in (1, -1):
        objs.append(K.box(prefix + "檐%d" % sy, (w + 0.16, 0.10, 0.10), m=m_ridge,
                          loc=(cx, cy + sy * (run + 0.02), z0 - 0.02), bevel=0.008))
    return objs


# =============================================================================
# 1) 大本营 8×8×9
# =============================================================================
def build_keep():
    m_stone, m_stone2, m_stone3 = K.mat("石"), K.mat("石暗"), K.mat("石浅")
    m_wood, m_wood2 = K.mat("木"), K.mat("木暗")
    m_roof, m_tile = K.mat("瓦"), K.mat("木暗")
    m_iron, m_gold = K.mat("铁"), K.mat("金")
    m_flag, m_dark = K.mat("旗红"), K.mat("阴影")
    objs = []
    # 台基 8×8×0.9
    objs.append(K.box("台基", (8.0, 8.0, 0.90), m=m_stone2, loc=(0, 0, 0.45),
                      bevel=0.03, top=0.985))
    objs += wrap_stone("台基", 0, 0, 7.94, 7.94, 0.06, 0.86, 3, m_stone, thick=0.10)
    objs.append(K.box("台面", (7.7, 7.7, 0.10), m=m_stone3, loc=(0, 0, 0.90), bevel=0.02))
    # 主楼 5.4×5.2×4.6
    objs.append(K.box("主楼", (5.4, 5.2, 4.6), m=m_stone, loc=(0, -0.2, 3.20),
                      bevel=0.02, top=0.985))
    objs += wrap_stone("主楼", 0, -0.2, 5.34, 5.14, 0.95, 5.45, 6, m_stone,
                       thick=0.10, seed=11)
    # 角石（四角竖排大块，砌体转角的标识）
    for sx in (-1, 1):
        for sy in (-1, 1):
            for i in range(8):
                objs.append(K.box("角石%d%d%d" % (sx, sy, i),
                                  (0.44, 0.44, 0.52), m=m_stone3,
                                  loc=(sx * 2.66, -0.2 + sy * 2.56, 1.24 + i * 0.56),
                                  bevel=0.014,
                                  rot=(0, 0, math.radians(1.5 * ((i % 2) * 2 - 1)))))
    # 主楼窗（正面两组 + 侧面）
    def win(cx, cy, w, h, z, rotz=0.0, m_frame=None):
        out = [K.box("窗洞", (w, 0.16, h), m=m_dark, loc=(cx, cy, z), rot=(0, 0, rotz)),
               K.box("窗台", (w + 0.20, 0.24, 0.10), m=m_stone3,
                     loc=(cx, cy + 0.03, z - h * 0.5 - 0.05), rot=(0, 0, rotz), bevel=0.008)]
        for sx in (-1, 1):
            out.append(K.box("窗框%d" % sx, (0.10, 0.20, h + 0.16), m=m_stone3,
                             loc=(cx + sx * (w * 0.5 + 0.05) * math.cos(rotz),
                                  cy + 0.03, z), rot=(0, 0, rotz), bevel=0.006))
        out.append(K.box("窗楣", (w + 0.24, 0.20, 0.10), m=m_stone3,
                         loc=(cx, cy + 0.03, z + h * 0.5 + 0.06), rot=(0, 0, rotz), bevel=0.006))
        out.append(K.box("窗棂", (0.05, 0.10, h), m=m_iron,
                         loc=(cx, cy + 0.10, z), rot=(0, 0, rotz)))
        return out
    for sx in (-1, 1):
        objs += win(sx * 1.30, 2.42, 0.52, 0.82, 3.55)
        objs += win(sx * 1.30, 2.42, 0.52, 0.82, 2.10)
    for sx in (-1, 1):
        objs += win(sx * 2.72, -0.2, 0.52, 0.86, 3.40, math.radians(90))
    # 二层：木构架回廊层 4.4×4.2×2.6
    objs.append(K.box("二层", (4.4, 4.2, 2.6), m=m_stone, loc=(0, -0.2, 6.80),
                      bevel=0.02, top=0.99))
    objs += wrap_stone("二层", 0, -0.2, 4.34, 4.14, 5.50, 8.10, 4, m_stone,
                       thick=0.09, seed=21)
    # 木构架：立柱 + 斜撑 + 腰梁（每面）
    for sy in (1, -1):
        yy = -0.2 + sy * 2.10
        objs.append(K.box("腰梁%d" % sy, (4.6, 0.14, 0.16), m=m_wood2,
                          loc=(0, yy, 5.62), bevel=0.010))
        objs.append(K.box("顶梁%d" % sy, (4.6, 0.14, 0.16), m=m_wood2,
                          loc=(0, yy, 7.96), bevel=0.010))
        for i in range(4):
            xx = -1.65 + i * 1.10
            objs.append(K.box("立柱%d%d" % (sy, i), (0.16, 0.14, 2.36), m=m_wood2,
                              loc=(xx, yy, 6.78), bevel=0.008))
        for i in range(3):
            xx = -1.10 + i * 1.10
            objs.append(K.box("斜撑%d%d" % (sy, i), (0.11, 0.12, 0.86), m=m_wood2,
                              loc=(xx, yy + sy * 0.02, 6.20),
                              rot=(0, math.radians(38), 0), bevel=0.006))
    for sx in (-1, 1):
        objs.append(K.box("侧梁%d" % sx, (0.14, 4.4, 0.16), m=m_wood2,
                          loc=(sx * 2.20, -0.2, 5.62), bevel=0.010))
        objs.append(K.box("侧顶梁%d" % sx, (0.14, 4.4, 0.16), m=m_wood2,
                          loc=(sx * 2.20, -0.2, 7.96), bevel=0.010))
    # 屋顶（四坡）+ 脊 + 风向标
    objs.append(K.box("屋顶", (5.0, 4.8, 0.95), m=m_roof, loc=(0, -0.2, 8.58),
                      bevel=0.02, top=0.42))
    objs.append(K.box("顶脊", (5.2, 0.18, 0.14), m=m_tile, loc=(0, -0.2, 9.02), bevel=0.010))
    objs.append(K.limb("旗杆顶", [(0.0, 0.030), (1.0, 0.018)], m_iron,
                       (0, -0.2, 9.02), (0, 0, 1), sides=6))
    objs += banner("台旗", (0, -0.2, 9.30), 0.0, m_iron, m_flag, 0.0, 0.0)
    # 双塔楼（正面两角，8 边，带突堞与锥顶）
    for sx in (-1, 1):
        tx, ty = sx * 2.95, 2.95
        objs.append(K.cyl("塔身%d" % sx, 1.08, 0.96, 5.6, 8, m=m_stone,
                          loc=(tx, ty, 0.90), squarish=0.25, bevel=0.02))
        b = K.Batch("塔石%d" % sx, m_stone2)
        for i in range(7):
            K.stone_courses(b, -1.02, 1.02, i * 0.80, (i + 1) * 0.80, 0.0, rows=1,
                            thick=0.07, jitter=0.10, rng_seed=31 + i)
        tob = b.obj()
        place(tob, (tx, ty - 1.00, 0.95))
        objs.append(tob)
        # 突堞（托石 + 挑出的木廊）
        for i in range(8):
            a = TAU * i / 8.0
            objs.append(K.box("托石%d%d" % (sx, i), (0.24, 0.40, 0.24), m=m_stone3,
                              loc=(tx + 0.86 * math.cos(a), ty + 0.86 * math.sin(a), 6.68),
                              rot=(0, 0, a), bevel=0.010))
        objs.append(K.cyl("木廊%d" % sx, 1.22, 1.22, 0.62, 8, m=m_wood,
                          loc=(tx, ty, 6.86), squarish=0.1))
        for i in range(8):
            a = TAU * i / 8.0 + 0.4
            objs.append(K.box("垛%d%d" % (sx, i), (0.38, 0.34, 0.46), m=m_wood,
                              loc=(tx + 1.10 * math.cos(a), ty + 1.10 * math.sin(a), 7.60),
                              rot=(0, 0, a), bevel=0.008))
        objs.append(K.cyl("塔顶%d" % sx, 1.34, 0.05, 1.30, 8, m=m_roof,
                          loc=(tx, ty, 7.48), squarish=0.1, bevel=0.01))
        objs.append(K.limb("塔尖%d" % sx, [(0.0, 0.045), (0.30, 0.02)], m_iron,
                           (tx, ty, 8.78), (0, 0, 1), sides=6))
    # 正门（+Y）：门洞 + 拱券 + 铁栅 + 双门扇 + 台阶
    gy = 2.42
    objs.append(K.box("门洞", (1.90, 0.30, 2.60), m=m_dark, loc=(0, gy, 2.20)))
    objs += arch("门", 0, gy - 0.06, 2.10, 3.50, 3.20, m_stone3, depth=0.30, seg=6)
    for i in range(5):
        objs.append(K.box("铁栅%d" % i, (0.06, 0.08, 2.40), m=m_iron,
                          loc=(-0.70 + i * 0.35, gy + 0.12, 2.20)))
    for i in range(4):
        objs.append(K.box("铁栅横%d" % i, (1.90, 0.06, 0.05), m=m_iron,
                          loc=(0, gy + 0.12, 1.20 + i * 0.62)))
    for sx in (-1, 1):
        objs.append(K.box("门扇%d" % sx, (0.86, 0.14, 2.36), m=m_wood,
                          loc=(sx * 0.46, gy - 0.18, 2.14), bevel=0.012, top=0.99))
        for i in range(4):
            objs.append(K.box("门箍%d%d" % (sx, i), (0.90, 0.05, 0.10), m=m_iron,
                              loc=(sx * 0.46, gy - 0.26, 1.20 + i * 0.56), bevel=0.004))
        for i in range(5):
            objs.append(K.stud("门钉%d%d" % (sx, i), (sx * 0.46 + (0.28 if i % 2 else -0.28),
                                                      gy - 0.30, 1.30 + i * 0.45),
                               0.026, 0.020, m_iron, 5, (0, -1, 0)))
    for i in range(4):
        objs.append(K.box("台阶%d" % i, (2.4 - i * 0.0, 0.34, 0.22), m=m_stone2,
                          loc=(0, gy + 0.30 + i * 0.34, 0.90 - i * 0.22),
                          bevel=0.010, top=0.97))
    # 台基城垛（前沿 + 两侧）
    objs += crenellation("台垛前", (-3.6, 3.72, 0.90), (3.6, 3.72, 0.90), m_stone, step=0.92)
    for sx in (-1, 1):
        objs += crenellation("台垛侧%d" % sx, (sx * 3.72, -3.6, 0.90),
                             (sx * 3.72, 3.6, 0.90), m_stone, step=0.92, axis="y")
    # 两面旗
    objs += banner("旗A", (3.30, 3.30, 1.45), 4.60, m_wood2, m_flag, 0.62, 1.35, 0.02, 0.07, -1)
    objs += banner("旗B", (-3.30, 3.30, 1.45), 4.20, m_wood2, K.mat("旗蓝"), 0.55, 1.20, 0.02, 0.07, 1)
    # 挂点（后续特效/英雄挂位）
    for nm, p in (("Banner", (0, 3.2, 6.0)), ("Smoke", (2.2, -0.2, 9.3)),
                  ("Door", (0, 2.6, 0.9)), ("Spawn", (0, 3.9, 0.9))):
        K.parent_to(K.empty(nm, p), bpy.data.objects["Root"] if "Root" in bpy.data.objects else
                    objs[0])
    K.fit_box(8.0, 8.0, 9.0)   # 规范 §3.2：8×8×9，底面轴对齐矩形
    return K.export_glb(os.path.join(OUT, "大本营.glb"))


# =============================================================================
# 2) 兵营 6×5.5×4.6
# =============================================================================
def build_barracks():
    m_stone, m_stone2 = K.mat("石"), K.mat("石暗")
    m_wood, m_wood2, m_wood3 = K.mat("木"), K.mat("木暗"), K.mat("木浅")
    m_cloth, m_bale = K.mat("布麻"), K.mat("茅草")
    m_roof, m_flag, m_iron = K.mat("瓦"), K.mat("旗红"), K.mat("钢暗")
    objs = []
    # 石基 6×5.5×0.6
    objs.append(K.box("地基", (6.0, 5.5, 0.60), m=m_stone2, loc=(0, 0, 0.30),
                      bevel=0.03, top=0.98))
    objs += wrap_stone("地基", 0, 0, 5.94, 5.44, 0.05, 0.56, 2, m_stone, thick=0.09)
    # 大厅 5.0×4.2×2.9（后半），木构架 + 抹灰墙板
    hx, hy, hz = 0.0, -0.55, 2.55
    objs.append(K.box("大厅", (5.0, 4.2, 2.62), m=m_bale, loc=(hx, hy, 0.60 + 1.31),
                      bevel=0.02))
    # 木构架：四角立柱 + 中柱 + 上下横梁 + 斜撑（X 形）
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(K.box("角柱%d%d" % (sx, sy), (0.24, 0.24, 2.72), m=m_wood2,
                              loc=(hx + sx * 2.42, hy + sy * 2.02, 1.98), bevel=0.010))
        objs.append(K.box("侧中柱%d" % sx, (0.20, 0.20, 2.62), m=m_wood2,
                          loc=(hx + sx * 2.42, hy, 1.91), bevel=0.008))
    for sy in (-1, 1):
        objs.append(K.box("横梁下%d" % sy, (5.1, 0.22, 0.22), m=m_wood2,
                          loc=(hx, hy + sy * 2.02, 0.92), bevel=0.010))
        objs.append(K.box("横梁上%d" % sy, (5.1, 0.22, 0.24), m=m_wood2,
                          loc=(hx, hy + sy * 2.02, 3.06), bevel=0.010))
        for sx in (-1, 1):
            objs.append(K.box("斜撑%d%d" % (sy, sx), (0.14, 0.14, 1.05), m=m_wood2,
                              loc=(hx + sx * 1.25, hy + sy * 2.02, 2.00),
                              rot=(0, math.radians(30 * sx), 0), bevel=0.006))
    # 正门（+Y 面）+ 门框
    objs.append(K.box("门框洞", (1.30, 0.20, 2.10), m=K.mat("阴影"),
                      loc=(hx, hy + 2.12, 1.65)))
    for sx in (-1, 1):
        objs.append(K.box("门框柱%d" % sx, (0.14, 0.24, 2.24), m=m_wood2,
                          loc=(hx + sx * 0.72, hy + 2.10, 1.72), bevel=0.008))
    objs.append(K.box("门楣", (1.68, 0.26, 0.20), m=m_wood2,
                      loc=(hx, hy + 2.10, 2.90), bevel=0.008))
    # 双坡屋顶
    objs += roof_pitched("大厅屋", hx, hy, 5.6, 4.6, 3.14, 1.28, m_roof, m_wood2, 0.40)
    # 演武棚（front）：四柱 + 单坡棚顶
    py0 = 2.42
    for sx in (-1, 1):
        for dy in (0.0, 1.30):
            objs.append(K.box("棚柱%d%d" % (sx, int(dy * 10)), (0.20, 0.20, 2.30), m=m_wood,
                              loc=(sx * 1.85, py0 + dy, 0.60 + 1.15), bevel=0.008))
    objs.append(K.box("棚梁", (4.3, 0.18, 0.18), m=m_wood2,
                      loc=(0, py0 + 1.30, 2.76), bevel=0.008))
    b = K.Batch("棚顶", m_roof)
    for r in range(5):
        for c in range(12):
            b.box((0.36, 0.34, 0.06), loc=(-2.05 + c * 0.37, py0 + 0.14 + r * 0.30,
                                           2.86 + r * 0.10),
                  rot=(math.radians(-18), 0, 0), bevel=0.005, top=0.94)
    objs.append(b.obj())
    # 武器架（右侧）：横梁 + 枪 + 剑
    wx = 2.05
    for i in range(2):
        objs.append(K.box("枪架柱%d" % i, (0.14, 0.14, 1.55), m=m_wood,
                          loc=(wx, -0.9 + i * 1.8, 1.38), bevel=0.006))
    objs.append(K.box("枪架梁", (0.12, 2.1, 0.12), m=m_wood2,
                      loc=(wx, 0.0, 2.02), bevel=0.006))
    for i in range(4):
        objs.append(K.cyl("长枪%d" % i, 0.020, 0.014, 2.05, 6, m=m_wood,
                          loc=(wx + 0.06, -0.72 + i * 0.48, 0.72)))
        objs.append(K.limb("枪头%d" % i, [(0.0, 0.032), (0.16, 0.004)], m_iron,
                          (wx + 0.06, -0.72 + i * 0.48, 2.77), (0, 0, 1), sides=5))
    for i in range(2):
        objs.append(K.box("备用盾%d" % i, (0.06, 0.46, 0.62), m=m_iron,
                          loc=(wx + 0.10, -0.30 + i * 0.60, 1.34),
                          rot=(0, math.radians(6), math.radians(6)), bevel=0.010))
    # 训练木桩
    objs.append(K.cyl("木桩", 0.13, 0.11, 1.45, 8, m=m_wood, loc=(-2.10, 3.10, 0.60)))
    objs.append(K.box("木桩横臂", (0.92, 0.12, 0.12), m=m_wood2,
                      loc=(-2.10, 3.10, 1.72), bevel=0.006))
    objs.append(K.ico("草靶", 0.26, 1, m=m_bale, loc=(-2.10, 3.10, 1.35),
                      scale=(0.62, 0.62, 0.92)))
    # 旗
    objs += banner("营旗", (2.60, 2.30, 0.60), 3.70, m_wood2, m_flag, 0.58, 1.28, 0.02, 0.06, -1)
    for nm, p in (("Banner", (2.6, 2.3, 4.3)), ("Spawn", (0, 3.4, 0.6)),
                  ("Smoke", (1.2, -2.6, 4.4))):
        K.parent_to(K.empty(nm, p), objs[0])
    K.fit_box(6.0, 5.5, 4.6)   # 规范 §3.2：6×5.5×4.6
    return K.export_glb(os.path.join(OUT, "兵营.glb"))


# =============================================================================
# 3) 铁匠铺 5.5×5×4.2
# =============================================================================
def build_smithy():
    m_stone, m_stone2, m_stone3 = K.mat("石"), K.mat("石暗"), K.mat("石浅")
    m_wood, m_wood2 = K.mat("木"), K.mat("木暗")
    m_roof, m_iron, m_fire = K.mat("瓦"), K.mat("铁"), K.mat("火")
    m_dark, m_steel = K.mat("阴影"), K.mat("钢")
    objs = []
    # 石砌工坊 5.0×4.4×2.8
    objs.append(K.box("坊身", (5.0, 4.4, 2.80), m=m_stone, loc=(0, -0.15, 1.40),
                      bevel=0.025))
    objs += wrap_stone("坊身", 0, -0.15, 4.94, 4.34, 0.05, 2.76, 7, m_stone2,
                       thick=0.10, jitter=0.09, seed=41)
    # 炉口（+Y 面）：拱形 + 内发光 + 铁栅 + 炭火
    fy = 2.02
    objs.append(K.box("炉口", (1.10, 0.26, 1.20), m=m_dark, loc=(-0.95, fy, 1.05),
                      bevel=0.02))
    objs += arch("炉", -0.95, fy - 0.06, 1.26, 1.62, 1.98, m_stone3, depth=0.26, seg=5)
    objs.append(K.box("炉火", (0.86, 0.12, 0.60), m=m_fire, loc=(-0.95, fy + 0.10, 0.78)))
    for i in range(4):
        objs.append(K.ico("炭%d" % i, 0.10, 0, m=m_fire,
                          loc=(-1.20 + i * 0.16, fy + 0.14, 0.62),
                          scale=(1.2, 0.8, 0.7), jitter=0.25, seed=50 + i))
    # 烟囱（后上方，收分 + 顶帽）
    objs.append(K.box("烟囱", (0.86, 0.86, 2.10), m=m_stone2, loc=(1.50, -1.55, 2.60),
                      bevel=0.02, top=0.82))
    objs.append(K.box("囱帽", (1.06, 1.06, 0.16), m=m_stone3, loc=(1.50, -1.55, 3.72),
                      bevel=0.012))
    objs.append(K.box("囱口", (0.38, 0.38, 0.14), m=m_dark, loc=(1.50, -1.55, 3.84)))
    # 屋顶：单坡（前高后低）+ 瓦
    objs.append(K.box("屋顶", (5.5, 4.9, 0.34), m=m_roof, loc=(0, -0.15, 2.94),
                      rot=(math.radians(-7), 0, 0), bevel=0.02, top=0.99))
    b = K.Batch("屋面", m_roof)
    for r in range(6):
        for c in range(15):
            b.box((0.35, 0.44, 0.055), loc=(-2.55 + c * 0.355, -2.30 + r * 0.62,
                                           3.04 + r * 0.075),
                  rot=(math.radians(-7), 0, 0), bevel=0.005, top=0.94)
    objs.append(b.obj())
    for i in range(5):
        objs.append(K.box("椽%d" % i, (0.09, 5.1, 0.09), m=m_wood2,
                          loc=(-2.2 + i * 1.1, -0.15, 2.80), bevel=0.004))
    # 门（+Y 右侧）
    objs.append(K.box("门洞", (1.10, 0.24, 2.00), m=m_dark, loc=(1.55, fy, 1.20)))
    objs.append(K.box("门扇", (1.02, 0.12, 1.86), m=m_wood, loc=(1.55, fy - 0.14, 1.14),
                      bevel=0.010))
    for i in range(3):
        objs.append(K.box("门箍%d" % i, (1.04, 0.05, 0.09), m=m_iron,
                          loc=(1.55, fy - 0.22, 0.55 + i * 0.60), bevel=0.003))
    # 铁砧（坊前，独立件）
    objs.append(K.cyl("砧座", 0.30, 0.26, 0.46, 8, m=m_wood2, loc=(-2.30, 2.90, 0.0),
                      squarish=0.3))
    objs.append(K.box("砧身", (0.62, 0.30, 0.22), m=m_iron, loc=(-2.30, 2.90, 0.60),
                      bevel=0.02, top=0.86))
    objs.append(K.box("砧角", (0.30, 0.16, 0.14), m=m_iron, loc=(-2.30, 3.14, 0.66),
                      bevel=0.012, top=0.6, top_off=(0, 0.05)))
    objs.append(K.box("砧面", (0.56, 0.26, 0.05), m=m_steel, loc=(-2.30, 2.90, 0.73),
                      bevel=0.006))
    # 水桶（竖板 + 铁箍）
    objs.append(K.cyl("水桶", 0.28, 0.24, 0.52, 10, m=m_wood, loc=(1.55, 3.00, 0.0),
                      squarish=0.0))
    for i in range(2):
        objs.append(K.cyl("桶箍%d" % i, 0.292, 0.286, 0.06, 10, m=m_iron,
                          loc=(1.55, 3.00, 0.10 + i * 0.30)))
    objs.append(K.cyl("桶水", 0.24, 0.24, 0.02, 10, m=K.mat("魔法暗"),
                      loc=(1.55, 3.00, 0.46)))
    # 墙上挂的铁器（钩 + 三件）
    for i in range(3):
        gx = -1.9 + i * 0.42
        objs.append(K.box("挂钩%d" % i, (0.04, 0.16, 0.04), m=m_iron,
                          loc=(gx, fy + 0.10, 1.92), bevel=0.004))
        objs.append(K.box("挂件%d" % i, (0.14, 0.06, 0.40), m=m_iron,
                          loc=(gx, fy + 0.16, 1.64), rot=(0, 0, math.radians(6 * i)),
                          bevel=0.006, top=0.5))
    for nm, p in (("Smoke", (1.50, -1.55, 4.00)), ("Fire", (-0.95, 2.15, 0.80))):
        K.parent_to(K.empty(nm, p), objs[0])
    K.fit_box(5.5, 5.0, 4.2)   # 规范 §3.2：5.5×5×4.2
    return K.export_glb(os.path.join(OUT, "铁匠铺.glb"))


# =============================================================================
# 4) 农场 4×4×2.6
# =============================================================================
def build_farm():
    m_wood, m_wood2, m_wood3 = K.mat("木"), K.mat("木暗"), K.mat("木浅")
    m_bale, m_dirt = K.mat("茅草"), K.mat("土")
    m_stone, m_stone2 = K.mat("石"), K.mat("石暗")
    m_crop, m_crop2 = K.mat("草"), K.mat("叶黄")
    objs = []
    # 田垄：一排排低矮土垄（起伏断面），带作物
    fx0, fx1 = -1.95, 0.25
    fy0, fy1 = -1.95, 1.95
    rows = 6
    for r in range(rows):
        y = fy0 + (fy1 - fy0) * (r + 0.5) / rows
        objs.append(K.loft("田垄%d" % r,
                           [(-0.02, K.sq_ring(10, abs(fx1 - fx0) * 0.5, 0.16, 0.5)),
                            (0.10, K.sq_ring(10, abs(fx1 - fx0) * 0.5, 0.13, 0.4)),
                            (0.16, K.sq_ring(10, abs(fx1 - fx0) * 0.5 * 0.92, 0.07, 0.4))],
                           m_dirt))
        objs[-1].data.transform(Matrix.Translation(Vector(((fx0 + fx1) * 0.5, y, 0.0))))
        for c in range(5):
            cx = fx0 + (fx1 - fx0) * (c + 0.5) / 5
            objs.append(K.prism("作物%d%d" % (r, c), [(-0.05, 0.0), (0.05, 0.0), (0.0, 0.20)],
                                0.05, m=m_crop if (r + c) % 2 else m_crop2,
                                loc=(cx, y + ((c % 2) - 0.5) * 0.04, 0.15),
                                bevel=0.002))
    # 小屋 2.2×1.9×1.85（右侧）
    hx, hy = 1.15, -0.95
    objs.append(K.box("屋身", (2.2, 1.9, 1.70), m=m_bale, loc=(hx, hy, 0.85), bevel=0.02))
    objs.append(K.box("屋基", (2.3, 2.0, 0.20), m=m_stone2, loc=(hx, hy, 0.10), bevel=0.012))
    for sx in (-1, 1):
        for sy in (-1, 1):
            objs.append(K.box("屋角柱%d%d" % (sx, sy), (0.14, 0.14, 1.72), m=m_wood2,
                              loc=(hx + sx * 1.06, hy + sy * 0.92, 0.90), bevel=0.006))
    objs.append(K.box("屋门", (0.62, 0.10, 1.10), m=m_wood2, loc=(hx, hy + 0.97, 0.65),
                      bevel=0.008))
    objs.append(K.box("屋窗", (0.42, 0.08, 0.40), m=K.mat("阴影"),
                      loc=(hx - 0.62, hy + 0.96, 1.10)))
    objs += roof_pitched("草屋", hx, hy, 2.6, 2.3, 1.72, 0.72, m_bale, m_wood2, 0.26)
    # 干草堆（圆锥 + 箍）
    objs.append(K.cyl("草堆", 0.62, 0.30, 1.30, 10, m=m_bale, loc=(-1.30, 2.55, 0.0),
                      squarish=0.05))
    for i in range(2):
        objs.append(K.cyl("草堆箍%d" % i, 0.52 - i * 0.12, 0.48 - i * 0.12, 0.05, 10,
                          m=m_wood3, loc=(-1.30, 2.55, 0.30 + i * 0.42)))
    objs.append(K.limb("草堆尖", [(0.0, 0.30), (0.24, 0.02)], m_bale,
                       (-1.30, 2.55, 1.30), (0, 0, 1), sides=8))
    # 围栏（四周，留门）
    def fence_run(prefix, p0, p1, gap=None):
        out = []
        a, b = Vector(p0), Vector(p1)
        L = (b - a).length
        n = max(2, int(L / 0.62))
        for i in range(n + 1):
            t = i / n
            p = a.lerp(b, t)
            if gap is not None and gap[0] <= t <= gap[1]:
                continue
            out.append(K.box("%s柱%d" % (prefix, i), (0.11, 0.11, 0.86), m=m_wood,
                             loc=(p.x, p.y, 0.43), bevel=0.005, top=0.7))
        for k in range(2):
            for i in range(n):
                t0, t1 = i / n, (i + 1) / n
                if gap is not None and gap[0] <= (t0 + t1) * 0.5 <= gap[1]:
                    continue
                p0, p1 = a.lerp(b, t0), a.lerp(b, t1)
                mid = (p0 + p1) * 0.5
                seg = (p1 - p0).length
                ang = math.atan2(p1.y - p0.y, p1.x - p0.x)
                out.append(K.box("%s横%d%d" % (prefix, k, i), (seg * 1.02, 0.055, 0.09),
                                 m=m_wood3, loc=(mid.x, mid.y, 0.32 + k * 0.36),
                                 rot=(0, 0, ang), bevel=0.004))
        return out
    objs += fence_run("栏前", (-1.95, 3.55), (1.95, 3.55), gap=(0.40, 0.62))
    objs += fence_run("栏后", (-1.95, -1.95), (1.95, -1.95))
    objs += fence_run("栏左", (-1.95, -1.95), (-1.95, 3.55))
    objs += fence_run("栏右", (1.95, -1.95), (1.95, 3.55))
    # 门柱 + 小水槽
    for sx in (-1, 1):
        objs.append(K.box("门柱%d" % sx, (0.16, 0.16, 1.10), m=m_wood2,
                          loc=(sx * 0.85, 3.55, 0.55), bevel=0.006, top=0.8))
    objs.append(K.box("水槽", (0.60, 0.36, 0.22), m=m_wood3, loc=(1.55, 2.90, 0.11),
                      bevel=0.010))
    K.parent_to(K.empty("Banner", (-1.95, 3.55, 1.30)), objs[0])
    K.fit_box(4.0, 4.0, 2.6)   # 规范 §3.2：4×4×2.6
    return K.export_glb(os.path.join(OUT, "农场.glb"))


# =============================================================================
# 5) 箭塔 3×3×8
# =============================================================================
def build_tower():
    m_stone, m_stone2, m_stone3 = K.mat("石"), K.mat("石暗"), K.mat("石浅")
    m_wood, m_wood2 = K.mat("木"), K.mat("木暗")
    m_roof, m_iron, m_flag, m_dark = K.mat("瓦"), K.mat("钢暗"), K.mat("旗红"), K.mat("阴影")
    objs = []
    # 塔身：方形收分（下宽上窄），逐层砌石
    z = 0.0
    seg_h = 1.15
    n = 7
    for i in range(n):
        t0 = i / n
        t1 = (i + 1) / n
        w0 = 2.30 - 0.46 * t0
        w1 = 2.30 - 0.46 * t1
        objs.append(K.box("塔身%d" % i, (w0, w0, seg_h), m=m_stone,
                          loc=(0, 0, z + seg_h * 0.5), bevel=0.02,
                          top=w1 / w0))
        b = K.Batch("塔石%d" % i, m_stone2)
        for k in range(4):
            ang = k * math.pi * 0.5 + math.pi * 0.5
            K.stone_courses(b, -w0 * 0.46, w0 * 0.46, 0.0, seg_h, 0.0, rows=3,
                            thick=0.075, jitter=0.11, rng_seed=60 + i * 4 + k)
            ob = b.obj()
            place(ob, (math.cos(ang) * w0 * 0.5, math.sin(ang) * w0 * 0.5, z),
                  (0, 0, ang - math.pi * 0.5))
            objs.append(ob)
            b = K.Batch("塔石%d_%d" % (i, k), m_stone2)
        z += seg_h
    top_w = 2.30 - 0.46
    # 箭孔（四个方向各 2 个，凹入 + 石套）
    for k in range(4):
        ang = k * math.pi * 0.5
        for j in range(2):
            zz = 2.4 + j * 2.3
            ww = 2.30 - 0.46 * (zz / (seg_h * n))
            px = math.cos(ang - math.pi * 0.5) * (ww * 0.5 + 0.02)
            py = math.sin(ang - math.pi * 0.5) * (ww * 0.5 + 0.02)
            objs.append(K.box("箭孔%d%d" % (k, j), (0.16, 0.16, 0.56), m=m_dark,
                              loc=(px, py, zz), rot=(0, 0, ang - math.pi * 0.5)))
            objs.append(K.box("孔台%d%d" % (k, j), (0.30, 0.30, 0.10), m=m_stone3,
                              loc=(px * 1.05, py * 1.05, zz - 0.34),
                              rot=(0, 0, ang - math.pi * 0.5), bevel=0.006))
    # 托石 + 木构挑廊 + 垛口
    for k in range(4):
        for j in range(3):
            ang = k * math.pi * 0.5
            off = (j - 1) * 0.55
            px = math.cos(ang - math.pi * 0.5) * (top_w * 0.5 + 0.06) - math.sin(ang - math.pi * 0.5) * off
            py = math.sin(ang - math.pi * 0.5) * (top_w * 0.5 + 0.06) + math.cos(ang - math.pi * 0.5) * off
            objs.append(K.box("托石%d%d" % (k, j), (0.22, 0.34, 0.26), m=m_stone3,
                              loc=(px, py, z - 0.14), rot=(0, 0, ang - math.pi * 0.5),
                              bevel=0.008))
    objs.append(K.box("挑廊", (2.72, 2.72, 0.66), m=m_wood, loc=(0, 0, z + 0.33), bevel=0.02))
    objs.append(K.box("廊底", (2.60, 2.60, 0.10), m=m_wood2, loc=(0, 0, z + 0.02), bevel=0.01))
    for k in range(4):
        for j in range(3):
            ang = k * math.pi * 0.5 + math.pi * 0.5
            off = (j - 1) * 0.80
            px = math.cos(ang) * 1.28 - math.sin(ang) * off
            py = math.sin(ang) * 1.28 + math.cos(ang) * off
            objs.append(K.box("垛%d%d" % (k, j), (0.34, 0.30, 0.54), m=m_wood,
                              loc=(px, py, z + 0.90), rot=(0, 0, ang), bevel=0.008))
    # 木顶（四坡锥）
    objs.append(K.cyl("塔顶", 1.72, 0.05, 1.62, 4, m=m_roof, loc=(0, 0, z + 0.66),
                      squarish=0.0, bevel=0.01))
    objs.append(K.limb("塔尖", [(0.0, 0.05), (0.42, 0.015)], m_iron,
                       (0, 0, z + 2.28), (0, 0, 1), sides=6))
    # 旗 + 爬梯
    objs += banner("塔旗", (0.95, 0.95, z + 0.66), 2.60, m_wood2, m_flag, 0.46, 0.98,
                   0.02, 0.05, -1)
    objs += ladder("梯", 0.0, -1.28, 0.0, z - 0.10, m_wood2)
    for nm, p in (("Banner", (0.95, 0.95, z + 3.3)), ("Arrow", (0, 0, z + 0.6))):
        K.parent_to(K.empty(nm, p), objs[0])
    K.fit_box(3.0, 3.0, 8.0)   # 规范 §3.2：3×3×8
    return K.export_glb(os.path.join(OUT, "箭塔.glb"))


if __name__ == "__main__":
    reps = []
    for fn in (build_keep, build_barracks, build_smithy, build_farm, build_tower):
        K.reset_scene()
        reps.append(fn())
    K.headless_report({"models": reps})
