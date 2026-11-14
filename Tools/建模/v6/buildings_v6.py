# -*- coding: utf-8 -*-
"""
buildings_v6.py —— 建筑 v6（职责剪影版）

为什么再做一版：
    v3 的五栋建筑都是同一个套路 —— 方石盒 + 一个大四坡顶 + 角塔。
    实机截图的问题很清楚：远看五栋长得一样，都像"民房戴了顶大帽子"。
    职责（出兵 / 打铁 / 防守 / 产粮 / 主城）没有进入剪影，只靠瓦色区分。

v6 的三条硬规则（每条都对应一个可验证的观感目标）：

  1. **体量分层，不做单柱体**：石基座（外扩、粗）→ 木构/抹灰上层（内收再挑出 0.15~0.25m）
     → 陡坡屋顶（出檐 ≤ 0.35m）。
     依据：中世纪真实木构建筑就是"jettied"——上层向街面挑出，立面因此有横向阴影线，
     建筑才有"重量"和"层数"。v3 的 45° 四坡顶 + 0.55m 大出檐把重心全推到头顶，
     所以像帽子。

  2. **职责写进剪影**（一眼能认）：
       大本营 —— 最高、轮廓最碎：主楼 + 前门楼 + 不对称方塔 + 矮翼厅，山墙朝前（竖三角）
       兵营   —— 横向铺开 + 空场：主厅退到后部，前场是校场（旗杆/假人/盾墙/武器棚）
       铁匠铺 —— 竖向烟囱主导：烟囱高过屋脊 1.2m，正面外露锻炉（自发光炉口）
       箭塔   —— 高宽比 ≥ 4:1 的细高体 + 木挑台（挑台是"塔"和"烟囱"的区别）
       农场   —— 低矮横向：茅草顶（厚、圆、出檐 0.55m）+ 田垄 + 篱笆 + 稻草人
     依据：WC3 的建筑辨识不靠贴图细节，靠外轮廓包络；150px 高时贴图看不清，剪影还在。

  3. **屋顶朝向按用途定**：主城/门楼用**山墙朝前**（脊线沿 y，正立面看到三角山墙），
     兵营/铁匠铺用**檐面朝前**（脊线沿 x，正面是斜坡 + 檐口）。
     依据：同一套屋顶语言里换朝向，是最省成本的"建筑类型"信号。

保留 v3 的骨骼协议（root + flag.* 三节旗骨）与 M_<zone>[_team] 材质命名，
所以引擎侧 MatKit / ArtKit / 工地表现 一行不用改。
"""

import bpy
import math
import os
import sys
from mathutils import Vector, Matrix, Euler

HERE = os.path.dirname(os.path.abspath(__file__))
V3 = os.path.abspath(os.path.join(HERE, "..", "v3"))
V5 = os.path.abspath(os.path.join(HERE, "..", "v5"))
sys.path.insert(0, V3)
sys.path.insert(0, V5)
sys.path.insert(0, HERE)

import kit3 as K3
import textured
import buildings as B
from buildings import (
    BuildingRig, box, place, tile_slope, ridge_cap, eave_fascia, bargeboard,
    gable_wall, roof_gable_tiled, roof_hip_tiled, cone_roof_tiled,
    masonry_face, masonry_ring, quoins, string_course, corbel_row,
    arrow_loophole, door_v4, window_v4, lantern, crate, woodpile, hay_bale,
    banner_v4, barrel, crenel_ring, crenel_line, steps, wall_shell, W_ROOT,
)
from kit3 import mat, Builder, D, TAU

OUT_DIR = r"E:\自定义游戏\简易rts\美术\模型"
QC_DIR = r"E:\自定义游戏\简易rts\工具\建模\v6\qc"


# ===========================================================================
# 0. v6 专用构件
# ===========================================================================

def cylc(b, r1, r2, h, loc=(0, 0, 0), **kw):
    """中心语义的圆柱。

    v3 的 Builder.cyl 把 loc 当**底面**（内部 translate 了 h/2），而 v6 全部按
    "loc = 圆柱中心"写（读起来更接近建模软件）。这一层把语义钉死，避免每根柱子
    都整体上移半个高度 —— 塔顶、井圈、水桶全靠它。
    """
    x, y, z = loc
    Builder.cyl(b, r1, r2, h, loc=(x, y, z - h * 0.5), **kw)


def roof_gable_y(b, cx, cy, w, d, z_eave, z_ridge, m_tile, m_dark, m_wood,
                 m_trim, over=0.30, course=0.32, tile_w=0.44):
    """双坡顶，**脊线沿 Y**（正/背面是山墙三角，左右是坡面）。

    v3 的 roof_gable_tiled 是脊线沿 X，正立面只能看到一大片斜坡 —— 这是"帽子感"
    的主要来源之一。主城与门楼改用这个，正立面得到竖三角，天际线立刻锐利。
    """
    W = w * 0.5 + over
    D = d * 0.5 + over
    rise = z_ridge - z_eave
    run = math.hypot(W, rise)
    for sx in (-1, 1):
        o = Vector((cx + sx * W, cy, z_eave))
        up = Vector((-sx * W, 0.0, rise))
        tile_slope(b, o, Vector((0, 1, 0)), up, 2 * D, 2 * D, run,
                   m_tile, m_dark, course=course, tile_w=tile_w, seed=31 + sx)
        # 博风板：沿山墙斜边（y = ±D 两侧）
        bargeboard(b, (cx + sx * W, cy - D, z_eave), up, (0, 1, 0), run, m_wood, m_trim)
        bargeboard(b, (cx + sx * W, cy + D, z_eave), up, (0, -1, 0), run, m_wood, m_trim)
        # 檐口：只做左右两面（山墙侧不做出檐，交给博风板）
        box(b, (0.13, 2 * D, 0.11), (cx + sx * (W - 0.02), cy, z_eave - 0.06), m_wood,
            bevel=0.008)
        box(b, (0.06, 2 * D, 0.05), (cx + sx * (W - 0.01), cy, z_eave - 0.11), m_dark)
    ridge_cap(b, (cx, cy - D, z_ridge), (cx, cy + D, z_ridge), m_dark, m_trim)


def gable_tri_y(b, cx, cy, y, w, z0, z_ridge, m, thick=0.30):
    """山墙三角（脊线沿 Y 时挂在 y = 前后 两面）。"""
    t = thick * 0.5
    a = [(cx - w * 0.5, y - t, z0), (cx + w * 0.5, y - t, z0), (cx, y - t, z_ridge)]
    c = [(cx - w * 0.5, y + t, z0), (cx + w * 0.5, y + t, z0), (cx, y + t, z_ridge)]
    b.add(K3._bm_loft([a, c], cap_a=True, cap_b=True), m, W_ROOT)


def timber_panel(b, axis, at, c, span, z0, z1, m, depth=0.07, posts=3,
                 braces=True, sill=True):
    """贴墙的露明木构：上下槛 + 竖柱 + 交替斜撑。

    用途：让"抹灰二层"变成"木骨泥墙"，是欧洲中世纪民居/兵营最便宜的身份标记。
    axis='y' → 板面法线沿 Y（at=y 平面，span 沿 x）；axis='x' → 法线沿 X。
    """
    h = z1 - z0
    yaw = 0.0 if axis == "y" else math.pi * 0.5

    def put(sx, sz, lx, lz, mm, yaw_extra=0.0, bevel=0.0):
        # 注意：axis='x' 时**不能再绕 Z 转 90°** —— size 的第二轴本来就是沿 y 的跨度，
        # 转了之后整根横槛会被甩到 x 方向（v6 第一版因此把大本营撑到 11m 宽）。
        if axis == "y":
            px, py, rot = c + lx, at, (0, 0, yaw + yaw_extra)
            size = (sx, depth, sz)
        else:
            px, py, rot = at, c + lx, (0, 0, yaw_extra)
            size = (depth, sx, sz)
        box(b, size, (px, py, z0 + lz), mm, rot=rot, bevel=bevel)

    if sill:
        put(span, 0.13, 0, 0.065, m)
    put(span, 0.15, 0, h - 0.075, m)
    for i in range(posts + 1):
        lx = -span * 0.5 + span * i / float(posts)
        put(0.14, h, lx, h * 0.5, m, bevel=0.005)
    if braces:
        for i in range(posts):
            seg = span / float(posts)
            lx = -span * 0.5 + seg * (i + 0.5)
            s = 1.0 if i % 2 == 0 else -1.0
            dy = math.hypot(seg * 0.78, h * 0.58)
            ang = math.atan2(seg * 0.78, h * 0.58) * s
            if axis == "y":
                box(b, (0.10, depth, dy), (c + lx, at, z0 + h * 0.5), m,
                    rot=(0, ang, 0), bevel=0.004)
            else:
                box(b, (depth, 0.10, dy), (at, c + lx, z0 + h * 0.5), m,
                    rot=(-ang, 0, 0), bevel=0.004)


def shed_roof(b, cx, cy, w, d, z_hi, z_lo, m_tile, m_dark, m_wood, over=0.28,
              along="x", course=0.30):
    """单坡顶（披屋/雨棚）：along='x' 表示脊线沿 x，向 +y 方向下落。"""
    if along == "x":
        W = w * 0.5 + over
        D = d * 0.5 + over
        rise = z_hi - z_lo
        run = math.hypot(D, rise)
        o = Vector((cx, cy + D, z_lo))
        up = Vector((0, -D, rise))
        tile_slope(b, o, Vector((1, 0, 0)), up, 2 * W, 2 * W, run,
                   m_tile, m_dark, course=course, tile_w=0.42, seed=61)
        box(b, (2 * W, 0.12, 0.10), (cx, cy + D, z_lo - 0.05), m_wood, bevel=0.006)
        box(b, (2 * W, 0.05, 0.05), (cx, cy + D + 0.01, z_lo - 0.10), m_dark)
        bargeboard(b, (cx - W, cy + D, z_lo), up, (1, 0, 0), run, m_wood, m_dark)
        bargeboard(b, (cx + W, cy + D, z_lo), up, (-1, 0, 0), run, m_wood, m_dark)
    else:
        W = w * 0.5 + over
        D = d * 0.5 + over
        rise = z_hi - z_lo
        run = math.hypot(W, rise)
        o = Vector((cx + W, cy, z_lo))
        up = Vector((-W, 0, rise))
        tile_slope(b, o, Vector((0, 1, 0)), up, 2 * D, 2 * D, run,
                   m_tile, m_dark, course=course, tile_w=0.42, seed=62)
        box(b, (0.12, 2 * D, 0.10), (cx + W, cy, z_lo - 0.05), m_wood, bevel=0.006)
        bargeboard(b, (cx + W, cy - D, z_lo), up, (0, 1, 0), run, m_wood, m_dark)
        bargeboard(b, (cx + W, cy + D, z_lo), up, (0, -1, 0), run, m_wood, m_dark)


def thatch_roof_y(b, cx, cy, w, d, z_eave, z_ridge, m_hay, m_dark, m_wood,
                  over=0.55, layers=5):
    """茅草顶（脊线沿 Y）：**厚、圆、大出檐**，绝不出现瓦楞。

    做法：多层错开的厚板（每层窄一点、位置高一点）→ 从侧面看是"草捆叠起来"的
    台阶状轮廓，远看就是一团厚草；再加随机草束打碎边缘。
    依据：茅草顶的识别特征是"厚"和"圆"，不是纹理；v3 拿瓦片函数做茅草，
    近看还行，远看和兵营的瓦顶分不开。
    """
    import random as _r
    W = w * 0.5 + over
    DD = d * 0.5 + over
    rise = z_ridge - z_eave
    run = math.hypot(W, rise)
    ang = math.atan2(rise, W)
    rnd = _r.Random(4242)
    for sx in (-1, 1):
        # 每一层：沿坡向上、逐层收窄并抬高，厚度给足
        for i in range(layers):
            t0 = i / float(layers)
            t1 = (i + 1) / float(layers)
            seg = run / layers
            # 板中心
            ox = cx + sx * (W - math.cos(ang) * (t0 + 0.5) * seg)
            oz = z_eave + math.sin(ang) * (t0 + 0.5) * seg
            wide = 2 * DD * (1.0 - 0.055 * i)
            box(b, (seg * 1.02, wide, 0.20 + 0.02 * i), (ox, cy, oz), m_hay,
                rot=(0, sx * ang, 0), bevel=0.055)
            # 层底压边（草捆的暗缝）
            ox2 = cx + sx * (W - math.cos(ang) * t0 * seg)
            oz2 = z_eave + math.sin(ang) * t0 * seg - 0.06
            box(b, (0.13, wide * 1.005, 0.10), (ox2, cy, oz2), m_dark,
                rot=(0, sx * ang, 0))
        # 边缘草束：打碎直线轮廓
        for k in range(14):
            yy = cy - DD + 2 * DD * (k + 0.5) / 14.0 + rnd.uniform(-0.08, 0.08)
            zz = z_eave + rnd.uniform(-0.10, 0.02)
            b.ico(0.085 + rnd.uniform(0, 0.05),
                  loc=(cx + sx * (W - 0.02), yy, zz), material=m_hay,
                  subdiv=1, weight=W_ROOT, scale=(1.5, 1.0, 0.75))
    # 屋脊：一根压扁的粗草脊
    cylc(b, 0.22, 0.20, 2 * DD, loc=(cx, cy, z_ridge - 0.02), rot=(D(90), 0, 0),
          material=m_hay, sides=7, weight=W_ROOT, scale=(1.0, 1.0, 0.62))
    # 脊上压草的横木 + 交叉绑绳
    box(b, (0.10, 2 * DD * 0.98, 0.09), (cx, cy, z_ridge + 0.16), m_wood, bevel=0.006)
    for k in range(4):
        yy = cy - DD + 2 * DD * (k + 0.5) / 4.0
        box(b, (0.55, 0.06, 0.06), (cx, yy, z_ridge + 0.20), m_wood, bevel=0.004)


def chimney(b, x, y, w, z0, z1, m_stone, m_stone_l, m_dark, cap=True):
    """烟囱：石身 + 三道腰线 + 出檐烟帽。"""
    box(b, (w, w, z1 - z0), (x, y, (z0 + z1) * 0.5), m_stone, bevel=0.02)
    n = max(2, int((z1 - z0) / 0.8))
    for i in range(n):
        zz = z0 + (z1 - z0) * (i + 0.5) / n
        box(b, (w * 1.08, w * 1.08, 0.07), (x, y, zz), m_stone_l, bevel=0.006)
    if cap:
        box(b, (w * 1.30, w * 1.30, 0.10), (x, y, z1), m_stone_l, bevel=0.012)
        box(b, (w * 0.66, w * 0.66, 0.05), (x, y, z1 + 0.07), m_dark)


def fence_run(b, x0, y0, x1, y1, z0, m_wood, m_dark, h=1.05, step=0.62, gap=0.0):
    """一段木栅栏：立柱 + 两道横档 + 尖头。坐标按线段给。"""
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    if L < 0.05:
        return
    ux, uy = dx / L, dy / L
    ang = math.atan2(dy, dx)
    n = max(2, int(L / step))
    for i in range(n + 1):
        t = i / float(n)
        box(b, (0.10, 0.10, h), (x0 + dx * t, y0 + dy * t, z0 + h * 0.5), m_dark,
            rot=(0, 0, ang), bevel=0.004)
        box(b, (0.12, 0.12, 0.12), (x0 + dx * t, y0 + dy * t, z0 + h + 0.02), m_wood,
            rot=(0, 0, ang + math.pi * 0.25), bevel=0.004)
    for zz in (z0 + h * 0.32, z0 + h * 0.74):
        box(b, (L, 0.055, 0.09), (x0 + dx * 0.5, y0 + dy * 0.5, zz), m_wood,
            rot=(0, 0, ang), bevel=0.004)


def dirt_apron(b, cx, cy, w, d, z, m_dirt, m_dirt2, seed=7):
    """夯土场院：一层薄地皮 + 若干深色斑块（避免一整块均匀颜色）。"""
    import random as _r
    rnd = _r.Random(seed)
    box(b, (w, d, 0.07), (cx, cy, z + 0.035), m_dirt, bevel=0.02)
    for i in range(9):
        px = cx + rnd.uniform(-w * 0.42, w * 0.42)
        py = cy + rnd.uniform(-d * 0.42, d * 0.42)
        box(b, (rnd.uniform(0.4, 1.1), rnd.uniform(0.3, 0.9), 0.02),
            (px, py, z + 0.062), m_dirt2, rot=(0, 0, rnd.uniform(0, 3.1)), bevel=0.02)


# ===========================================================================
# 1. 大本营 8x8 —— 最高、轮廓最碎
# ===========================================================================

def build_townhall():
    coll = K3.reset_scene()
    r = BuildingRig("townhall")
    # 门楼两根 + 主塔一根
    r.add_flag(1.05, 3.18, 4.62, 5.40, dirx=1.0, diry=0.0)
    r.add_flag(-1.05, 3.18, 4.62, 5.40, dirx=-1.0, diry=0.0)
    r.add_flag(-2.78, -2.28, 8.10, 8.95, dirx=0.0, diry=1.0)
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
    m_plaster = mat("plaster")
    m_leaf = mat("leaf_dark")

    b = Builder("townhall")

    # ---------------- 台基：两级，粗 ----------------
    box(b, (8.0, 8.0, 0.26), (0, 0, 0.13), m_stone_d, bevel=0.05)
    box(b, (7.62, 7.62, 0.10), (0, 0, 0.31), m_mortar)
    box(b, (7.46, 7.46, 0.30), (0, 0, 0.51), m_stone_d, bevel=0.035)
    box(b, (7.16, 7.16, 0.09), (0, 0, 0.70), m_stone_l, bevel=0.02)

    # ---------------- 一层石厅 5.6 x 4.8 ----------------
    W, Dd, cy0 = 5.6, 4.8, -0.35
    z0, z1 = 0.76, 3.10
    wall_shell(b, 0, cy0, W, Dd, z0, z1, m_mortar, thick=0.36)
    front = [(-1.32, 0.80, 2.02, 2.86), (1.32, 0.80, 2.02, 2.86)]
    sides = [(-1.05, 0.78, 2.02, 2.86), (1.05, 0.78, 2.02, 2.86)]
    back = [(-1.42, 0.78, 2.02, 2.86), (1.42, 0.78, 2.02, 2.86)]
    stones = (m_stone, m_stone_l, m_stone_d)
    masonry_face(b, "+y", 0, cy0, W, Dd, z0, z1, stones, holes=front, seed=141, row_h=0.36)
    masonry_face(b, "-y", 0, cy0, W, Dd, z0, z1, stones, holes=back, seed=142, row_h=0.36)
    masonry_face(b, "+x", 0, cy0, W, Dd, z0, z1, stones, holes=sides, seed=143, row_h=0.36)
    masonry_face(b, "-x", 0, cy0, W, Dd, z0, z1, stones, holes=sides, seed=144, row_h=0.36)
    quoins(b, 0, cy0, W, Dd, z0, z1, (m_stone_l, m_stone), size=0.46, row_h=0.36)
    # 一层腰线（把石基和上层切开）
    string_course(b, 0, cy0, W, Dd, z1 - 0.10, m_stone_l, out=0.07, h=0.10)
    corbel_row(b, 0, cy0, W, Dd, z1 + 0.02, m_stone_d, step=0.52, out=0.20, h=0.18)

    # ---------------- 二层木构（挑出 0.20）----------------
    W2, D2 = W + 0.40, Dd + 0.40
    z2, z3 = 3.10, 5.34
    box(b, (W2, D2, 0.14), (0, cy0, z2 + 0.07), m_wood_d, bevel=0.01)
    # 抹灰墙芯（比木构薄，木构贴在外侧压边）
    box(b, (W2 - 0.10, D2 - 0.10, z3 - z2 - 0.10), (0, cy0, (z2 + z3) * 0.5), m_plaster,
        bevel=0.01)
    # 露明木构：前后 + 左右
    timber_panel(b, "y", cy0 + D2 * 0.5 - 0.035, 0, W2 - 0.06, z2 + 0.06, z3 - 0.04,
                 m_wood_d, posts=3)
    timber_panel(b, "y", cy0 - D2 * 0.5 + 0.035, 0, W2 - 0.06, z2 + 0.06, z3 - 0.04,
                 m_wood_d, posts=3)
    timber_panel(b, "x", W2 * 0.5 - 0.035, cy0, D2 - 0.06, z2 + 0.06, z3 - 0.04,
                 m_wood_d, posts=2)
    timber_panel(b, "x", -W2 * 0.5 + 0.035, cy0, D2 - 0.06, z2 + 0.06, z3 - 0.04,
                 m_wood_d, posts=2)
    # 二层窗（正面 4 扇，山墙感的竖窗）
    wm = (m_stone_l, m_glass, m_stone_d, m_iron, m_wood_d, m_stone_l)
    for xx in (-1.98, -0.66, 0.66, 1.98):
        window_v4(b, xx, cy0 + D2 * 0.5 + 0.02, 4.28, 0.52, 0.92, wm, shutters=True)
    for sy in (-1, 1):
        for xx in (-1.05, 1.05):
            window_v4(b, W2 * 0.5 + 0.02, cy0 + sy * 1.05, 4.28, 0.50, 0.86, wm,
                      yaw=-math.pi * 0.5, shutters=True)
            window_v4(b, -W2 * 0.5 - 0.02, cy0 + sy * 1.05, 4.28, 0.50, 0.86, wm,
                      yaw=math.pi * 0.5, shutters=True)

    # ---------------- 主屋顶：脊线沿 Y，山墙朝前 ----------------
    rise_w = W2 * 0.5 + 0.30
    z_ridge = z3 + rise_w          # 45°
    roof_gable_y(b, 0, cy0, W2, D2, z3, z_ridge, m_roof, m_roof_d, m_wood_d, m_gold,
                 over=0.30, course=0.34, tile_w=0.46)
    # 前后山墙三角（正面这块是"市政厅"脸）
    for sy in (-1, 1):
        gable_tri_y(b, 0, cy0, cy0 + sy * (D2 * 0.5 - 0.02), W2, z3 - 0.06, z_ridge,
                    m_plaster, thick=0.26)
        # 山墙木构：中柱 + 两侧斜撑 + 系梁
        yy = cy0 + sy * (D2 * 0.5 - 0.02)
        box(b, (0.15, 0.10, (z_ridge - z3) * 0.98), (0, yy + sy * 0.03,
            (z3 + z_ridge) * 0.5), m_wood_d, bevel=0.006)
        box(b, (W2 * 0.92, 0.10, 0.14), (0, yy + sy * 0.03, z3 + 0.26), m_wood_d,
            bevel=0.006)
        for sx in (-1, 1):
            L = math.hypot(W2 * 0.24, (z_ridge - z3) * 0.62)
            box(b, (0.12, 0.10, L), (sx * W2 * 0.22, yy + sy * 0.03,
                z3 + (z_ridge - z3) * 0.36), m_wood_d,
                rot=(0, sx * math.atan2(W2 * 0.24, (z_ridge - z3) * 0.62), 0),
                bevel=0.005)
        # 山墙小圆窗（金环 + 暗玻璃）
        cylc(b, 0.34, 0.34, 0.10, loc=(0, yy + sy * 0.05, z3 + 0.92),
              rot=(D(90), 0, 0), material=m_stone_l, sides=12, weight=W_ROOT)
        cylc(b, 0.27, 0.27, 0.05, loc=(0, yy + sy * 0.10, z3 + 0.92),
              rot=(D(90), 0, 0), material=m_glass, sides=12, weight=W_ROOT)
        cylc(b, 0.30, 0.30, 0.04, loc=(0, yy + sy * 0.115, z3 + 0.92),
              rot=(D(90), 0, 0), material=m_gold, sides=12, weight=W_ROOT)

    # ---------------- 前门楼（打破方盒子的关键体量）----------------
    pw, pd = 2.70, 1.55
    py = 2.35
    box(b, (pw, pd, 3.60), (0, py, 0.76 + 1.80), m_stone, bevel=0.03)
    for zz in (1.30, 2.20, 3.10, 3.96):
        box(b, (pw + 0.10, pd + 0.10, 0.09), (0, py, zz), m_stone_l, bevel=0.006)
    # 门楼正面的门 + 侧壁柱
    door_v4(b, 0.0, py + pd * 0.5, 0.76, 1.72, 2.42,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_steel), planks=6,
            arch_rise=0.34)
    for sx in (-1, 1):
        box(b, (0.24, 0.16, 2.90), (sx * 1.10, py + pd * 0.5 + 0.03, 2.20), m_stone_l,
            bevel=0.012)
        lantern(b, sx * 1.24, py + pd * 0.5 + 0.16, 2.62, m_iron, m_ember, m_steel, h=0.32)
    # 门楼顶：山墙朝前的小双坡
    roof_gable_y(b, 0, py, pw, pd, 4.36, 5.62, m_roof, m_roof_d, m_wood_d, m_gold,
                 over=0.24, course=0.30, tile_w=0.40)
    for sy in (-1, 1):
        gable_tri_y(b, 0, py, py + sy * (pd * 0.5 - 0.02), pw, 4.30, 5.62, m_plaster,
                    thick=0.22)
    # 门楼旗帜（两支，斜出）
    for sx in (-1, 1):
        banner_v4(b, sx * 1.05, py + pd * 0.5 - 0.08, 4.62, 5.40, m_wood_d, m_cloth,
                  m_gold, m_cloth, idx=0 if sx < 0 else 1, dirx=float(sx), diry=0.35,
                  fw=0.72)

    # ---------------- 左后主塔（不对称，唯一的高点）----------------
    tx, ty = -2.78, -2.28
    box(b, (2.30, 2.30, 0.70), (tx, ty, 0.35), m_stone_d, bevel=0.03)
    box(b, (2.06, 2.06, 6.90), (tx, ty, 3.35 + 0.70), m_stone, bevel=0.02)
    for zz in (1.55, 2.85, 4.15, 5.45, 6.75):
        box(b, (2.16, 2.16, 0.07), (tx, ty, zz), m_stone_l, bevel=0.005)
    # 塔身箭孔（外侧面）
    for k, zz in enumerate((3.30, 5.10, 6.40)):
        arrow_loophole(b, tx - 1.04, ty, zz, math.pi, m_stone_l, m_glass)
        arrow_loophole(b, tx, ty - 1.04, zz, -math.pi * 0.5, m_stone_l, m_glass)
    # 塔顶：出挑托石 + 雉堞 + 锥顶
    box(b, (2.36, 2.36, 0.16), (tx, ty, 7.72), m_stone_l, bevel=0.01)
    crenel_line(b, tx, ty, 2.06, 2.06, 7.80, m_stone, step=0.60, h=0.40, thick=0.26)
    cone_roof_tiled(b, tx, ty, 1.16, 8.22, 9.55, m_roof, m_roof_d, m_gold, sides=8,
                    bands=6)
    banner_v4(b, tx, ty - 0.05, 8.10, 8.95, m_wood_d, m_cloth, m_gold, m_cloth, idx=2,
              dirx=0.0, diry=1.0, fw=0.66)

    # ---------------- 右翼矮厅（低、长，形成高低错落）----------------
    ex, ey = 2.98, -0.90
    ew, ed = 1.86, 2.90
    box(b, (ew, ed, 0.10), (ex, ey, 0.76), m_stone_d)
    wall_shell(b, ex, ey, ew, ed, 0.80, 2.62, m_mortar, thick=0.30)
    masonry_face(b, "+y", ex, ey, ew, ed, 0.80, 2.62, stones, seed=151, row_h=0.34)
    masonry_face(b, "-y", ex, ey, ew, ed, 0.80, 2.62, stones, seed=152, row_h=0.34)
    masonry_face(b, "+x", ex, ey, ew, ed, 0.80, 2.62, stones, seed=153, row_h=0.34)
    masonry_face(b, "-x", ex, ey, ew, ed, 0.80, 2.62, stones, seed=154, row_h=0.34)
    quoins(b, ex, ey, ew, ed, 0.80, 2.62, (m_stone_l, m_stone), size=0.34, row_h=0.34)
    roof_gable_y(b, ex, ey, ew, ed, 2.66, 3.72, m_roof, m_roof_d, m_wood_d, m_gold,
                 over=0.26, course=0.30, tile_w=0.40)
    for sy in (-1, 1):
        gable_tri_y(b, ex, ey, ey + sy * (ed * 0.5 - 0.02), ew, 2.62, 3.72, m_plaster,
                    thick=0.22)
    window_v4(b, ex, ey + ed * 0.5 + 0.02, 1.94, 0.46, 0.76, wm, shutters=True)
    window_v4(b, ex + ew * 0.5 + 0.02, ey, 1.94, 0.46, 0.72, wm, yaw=-math.pi * 0.5)

    # ---------------- 烟囱（穿出主屋面）----------------
    chimney(b, 1.70, -1.95, 0.66, 3.20, 8.35, m_stone, m_stone_l, m_glass)

    # ---------------- 前台阶 + 门廊 ----------------
    for i, (yy, zz, hh) in enumerate(((3.16, 0.66, 0.22), (3.38, 0.50, 0.22),
                                     (3.58, 0.34, 0.22))):
        box(b, (2.90, 0.30, hh), (0, yy, zz), m_stone_l, bevel=0.012)
    box(b, (3.30, 0.16, 0.10), (0, 2.28, 0.76), m_stone, bevel=0.008)

    # ---------------- 生活道具 ----------------
    barrel(b, 3.42, 2.20, 0.76, m_wood, m_iron)
    barrel(b, 3.02, 2.62, 0.76, m_wood, m_iron)
    crate(b, -3.30, 2.38, 0.76, 0.52, m_wood, m_wood_d, m_iron)
    woodpile(b, -3.24, 3.02, 0.76, m_wood, m_wood_d)
    hay_bale(b, -3.42, -0.60, 0.76, 0.56, mat("hay"), m_wood_d)
    # 墙根草
    for i in range(14):
        a = TAU * i / 14.0
        rr = 3.90
        b.ico(0.14, loc=(rr * math.cos(a), rr * math.sin(a), 0.76), material=m_leaf,
              subdiv=1, weight=W_ROOT, scale=(1.0, 1.0, 0.5))

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 2. 兵营 6x6 —— 横向铺开 + 空场（校场）
# ===========================================================================

def build_barracks():
    coll = K3.reset_scene()
    r = BuildingRig("barracks")
    r.add_flag(-1.55, 2.55, 3.90, 4.72, dirx=1.0, diry=0.0)
    r.add_flag(1.55, 2.55, 3.90, 4.72, dirx=-1.0, diry=0.0)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
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
    m_dirt = mat("dirt")
    m_plaster = mat("plaster")

    b = Builder("barracks")
    stones = (m_stone, m_stone_l, m_stone_d)

    # ---------------- 校场：夯土 + 车辙 ----------------
    dirt_apron(b, 0, 1.55, 5.70, 2.55, 0.0, m_dirt, m_stone_d, seed=71)
    # 场地中线（演武队列线）
    box(b, (0.09, 2.30, 0.02), (0, 1.55, 0.084), m_stone_l)
    for yy in (0.75, 2.35):
        box(b, (5.40, 0.09, 0.02), (0, yy, 0.084), m_stone_l)

    # ---------------- 主厅：退到后部，石基 + 木构上层 ----------------
    W, Dd, cy0 = 4.20, 2.92, -1.28
    z0, z1 = 0.34, 2.05
    box(b, (W + 0.24, Dd + 0.24, 0.34), (0, cy0, 0.17), m_stone_d, bevel=0.03)
    wall_shell(b, 0, cy0, W, Dd, z0, z1, m_mortar, thick=0.32)
    fh = [(0.0, 1.78, 0.34, 1.92)]
    sh = [(-0.92, 0.74, 1.02, 1.72), (0.92, 0.74, 1.02, 1.72)]
    masonry_face(b, "+y", 0, cy0, W, Dd, z0, z1, stones, holes=fh, seed=171, row_h=0.32)
    masonry_face(b, "-y", 0, cy0, W, Dd, z0, z1, stones, holes=sh, seed=172, row_h=0.32)
    masonry_face(b, "+x", 0, cy0, W, Dd, z0, z1, stones, holes=[(-0.55, 0.70, 1.02, 1.72)],
                 seed=173, row_h=0.32)
    masonry_face(b, "-x", 0, cy0, W, Dd, z0, z1, stones, holes=[(-0.55, 0.70, 1.02, 1.72)],
                 seed=174, row_h=0.32)
    quoins(b, 0, cy0, W, Dd, z0, z1, (m_stone_l, m_stone), size=0.40, row_h=0.32)
    door_v4(b, 0.0, cy0 + Dd * 0.5, 0.34, 1.62, 1.62,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_steel), planks=6,
            arch_rise=0.16)

    # 上层木构（挑出 0.22）
    W2, D2 = W + 0.44, Dd + 0.44
    z2, z3 = 2.05, 3.32
    box(b, (W2, D2, 0.13), (0, cy0, z2 + 0.065), m_wood_d, bevel=0.01)
    box(b, (W2 - 0.08, D2 - 0.08, z3 - z2 - 0.08), (0, cy0, (z2 + z3) * 0.5),
        m_plaster, bevel=0.01)
    timber_panel(b, "y", cy0 + D2 * 0.5 - 0.035, 0, W2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=3)
    timber_panel(b, "y", cy0 - D2 * 0.5 + 0.035, 0, W2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=3)
    timber_panel(b, "x", W2 * 0.5 - 0.035, cy0, D2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=1)
    timber_panel(b, "x", -W2 * 0.5 + 0.035, cy0, D2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=1)
    wm = (m_stone_l, m_glass, m_stone_d, m_iron, m_wood_d, m_stone_l)
    for xx in (-1.30, 1.30):
        window_v4(b, xx, cy0 + D2 * 0.5 + 0.02, 2.72, 0.52, 0.68, wm, shutters=True)

    # 屋顶：脊线沿 X（正面是檐面）+ 陡坡
    roof_gable_tiled(b, 0, cy0, W2, D2, z3, z3 + (D2 * 0.5 + 0.26) * 0.95,
                     m_roof, m_roof_d, m_wood_d, m_gold, over=0.26, course=0.30,
                     tile_w=0.44)
    for sx in (-1, 1):
        gable_wall(b, 0, cy0, sx * W2 * 0.5, W2, D2, z3 - 0.06,
                   z3 + (D2 * 0.5 + 0.26) * 0.95, m_plaster, thick=0.24)
        # 山墙木构
        box(b, (0.11, 0.10, 0.90), (sx * (W2 * 0.5 + 0.02), cy0, z3 + 0.52), m_wood_d)
        for sgn in (-1, 1):
            box(b, (0.09, 0.09, 0.86), (sx * (W2 * 0.5 + 0.03), cy0 + sgn * 0.52,
                z3 + 0.42), m_wood_d, rot=(math.radians(26) * sgn, 0, 0), bevel=0.004)

    # ---------------- 正面：敞开的门廊（阅兵门）----------------
    for sx in (-1, 1):
        box(b, (0.20, 0.20, 2.34), (sx * 1.62, cy0 + Dd * 0.5 + 0.52, 1.51), m_wood,
            bevel=0.012)
        box(b, (0.30, 0.30, 0.12), (sx * 1.62, cy0 + Dd * 0.5 + 0.52, 0.40), m_stone_d)
    box(b, (3.54, 1.10, 0.12), (0, cy0 + Dd * 0.5 + 0.50, 2.62), m_wood_d, bevel=0.01)
    shed_roof(b, 0, cy0 + Dd * 0.5 + 0.60, 3.54, 1.25, 2.96, 2.56, m_roof, m_roof_d,
              m_wood_d, over=0.24)

    # ---------------- 左侧武器棚（单坡，柱撑）----------------
    ax, ay = -2.28, 0.62
    box(b, (0.16, 0.16, 2.30), (ax - 0.62, ay + 0.98, 1.15), m_wood_d, bevel=0.008)
    box(b, (0.16, 0.16, 2.30), (ax - 0.62, ay - 1.05, 1.15), m_wood_d, bevel=0.008)
    box(b, (0.16, 0.16, 2.62), (ax + 0.62, ay + 0.98, 1.31), m_wood_d, bevel=0.008)
    box(b, (0.16, 0.16, 2.62), (ax + 0.62, ay - 1.05, 1.31), m_wood_d, bevel=0.008)
    box(b, (1.30, 2.20, 0.10), (ax, ay, 2.62), m_wood_d, bevel=0.008)
    # 棚下的长矛架
    for zz in (1.02, 1.34):
        box(b, (0.08, 2.00, 0.08), (ax, ay, zz), m_wood_d, bevel=0.004)
    for i in range(7):
        yy = ay - 0.90 + i * 0.30
        box(b, (0.05, 0.05, 1.70), (ax, yy, 1.00), m_wood_d)
        box(b, (0.10, 0.03, 0.22), (ax, yy, 1.86), m_steel)
    # 盾牌挂在棚背板
    for i in range(3):
        yy = ay - 0.55 + i * 0.55
        cylc(b, 0.30, 0.30, 0.07, loc=(ax + 0.60, yy, 1.30), rot=(0, D(90), 0),
              material=m_cloth, sides=12, weight=W_ROOT)
        cylc(b, 0.09, 0.09, 0.03, loc=(ax + 0.56, yy, 1.30), rot=(0, D(90), 0),
              material=m_gold, sides=8, weight=W_ROOT)

    # ---------------- 右侧瞭望台 ----------------
    lx, ly = 2.32, -0.55
    for sx in (-1, 1):
        for sy in (-1, 1):
            box(b, (0.13, 0.13, 2.60), (lx + sx * 0.52, ly + sy * 0.52, 1.30),
                m_wood_d, bevel=0.006)
    box(b, (1.36, 1.36, 0.14), (lx, ly, 2.62), m_wood, bevel=0.01)
    # 栏杆
    for sx in (-1, 1):
        box(b, (0.06, 1.36, 0.06), (lx + sx * 0.65, ly, 3.28), m_wood)
        box(b, (1.36, 0.06, 0.06), (lx, ly + sx * 0.65, 3.28), m_wood)
        for k in range(3):
            box(b, (0.05, 0.05, 0.62), (lx + sx * 0.65, ly - 0.45 + k * 0.45, 2.99),
                m_wood)
    # 梯子
    for k in (-1, 1):
        box(b, (0.06, 0.06, 2.90), (lx + 0.10 + k * 0.16, ly + 0.92, 1.45), m_wood_d,
            rot=(D(14), 0, 0))
    for i in range(8):
        box(b, (0.40, 0.05, 0.05), (lx + 0.10, ly + 0.86 - i * 0.10, 0.28 + i * 0.34),
            m_wood_d)
    # 台顶的战鼓（职责符号）
    cylc(b, 0.30, 0.30, 0.42, loc=(lx, ly, 2.90), material=m_wood, sides=12, weight=W_ROOT)
    cylc(b, 0.32, 0.32, 0.05, loc=(lx, ly, 2.70), material=m_hay, sides=12, weight=W_ROOT)
    cylc(b, 0.32, 0.32, 0.05, loc=(lx, ly, 3.10), material=m_hay, sides=12, weight=W_ROOT)

    # ---------------- 中央旗杆（校场的主角）----------------
    px, py = -1.55, 2.55
    cylc(b, 0.10, 0.07, 4.40, loc=(px, py, 2.20), material=m_wood, sides=8, weight=W_ROOT)
    box(b, (0.44, 0.44, 0.18), (px, py, 0.09), m_stone_d, bevel=0.02)
    b.ico(0.10, loc=(px, py, 4.46), material=m_gold, subdiv=1, weight=W_ROOT)
    banner_v4(b, px, py, 3.90, 4.72, m_wood_d, m_cloth, m_gold, m_cloth, idx=0,
              dirx=1.0, diry=0.0, fw=0.86)

    # ---------------- 训练假人（3 个）----------------
    for i, xx in enumerate((-1.85, -0.75, 0.35)):
        yy = 1.05
        box(b, (0.15, 0.15, 1.62), (xx, yy, 0.81), m_wood, bevel=0.008)
        box(b, (0.86, 0.12, 0.10), (xx, yy, 1.36), m_wood_d, bevel=0.006)
        cylc(b, 0.24, 0.24, 0.62, loc=(xx, yy, 1.18), material=m_hay, sides=10,
              weight=W_ROOT)
        cylc(b, 0.26, 0.26, 0.08, loc=(xx, yy, 1.50), material=m_hay, sides=10,
              weight=W_ROOT)
        cylc(b, 0.15, 0.15, 0.20, loc=(xx, yy, 1.62), material=m_hay, sides=8,
              weight=W_ROOT)
        # 草人身上的环靶
        cylc(b, 0.20, 0.20, 0.05, loc=(xx, yy + 0.26, 1.20), rot=(D(90), 0, 0),
              material=m_cloth, sides=10, weight=W_ROOT)
        cylc(b, 0.11, 0.11, 0.03, loc=(xx, yy + 0.30, 1.20), rot=(D(90), 0, 0),
              material=m_gold, sides=8, weight=W_ROOT)

    # ---------------- 盾墙（沿主厅正面）----------------
    for i in range(5):
        xx = -0.90 + i * 0.45
        cylc(b, 0.24, 0.24, 0.07, loc=(xx, cy0 + Dd * 0.5 + 0.08, 0.72),
              rot=(D(90), 0, 0), material=m_cloth, sides=10, weight=W_ROOT)
        cylc(b, 0.08, 0.08, 0.04, loc=(xx, cy0 + Dd * 0.5 + 0.12, 0.72),
              rot=(D(90), 0, 0), material=m_gold, sides=8, weight=W_ROOT)

    # ---------------- 前缘栅栏（留中间入口）----------------
    fence_run(b, -2.90, 2.92, -1.10, 2.92, 0.0, m_wood, m_wood_d, h=1.02)
    fence_run(b, 1.10, 2.92, 2.90, 2.92, 0.0, m_wood, m_wood_d, h=1.02)
    fence_run(b, -2.90, 0.30, -2.90, 2.92, 0.0, m_wood, m_wood_d, h=1.02)
    fence_run(b, 2.90, 0.95, 2.90, 2.92, 0.0, m_wood, m_wood_d, h=1.02)
    # 入口两侧的旗矛
    for sx in (-1, 1):
        box(b, (0.12, 0.12, 2.20), (sx * 1.02, 2.92, 1.10), m_wood_d, bevel=0.006)
        box(b, (0.30, 0.04, 0.44), (sx * 1.02 + 0.14, 2.92, 1.86), m_cloth)

    # ---------------- 补给堆 ----------------
    barrel(b, 1.92, 2.24, 0.0, m_wood, m_iron)
    barrel(b, 2.38, 2.44, 0.0, m_wood, m_iron)
    crate(b, 2.52, 1.90, 0.0, 0.48, m_wood, m_wood_d, m_iron)
    hay_bale(b, -2.62, -2.42, 0.0, 0.58, m_hay, m_wood_d)

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 3. 铁匠铺 6x6 —— 烟囱主导 + 外露锻炉
# ===========================================================================

def build_smithy():
    coll = K3.reset_scene()
    r = BuildingRig("smithy")
    r.add_flag(-0.20, 2.30, 3.55, 4.35, dirx=1.0, diry=0.0)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_roof = mat("roof_iron", team=True)
    m_roof_d = mat("roof_dark")
    m_gold = mat("gold")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_mortar = mat("iron")
    m_steel = mat("steel")
    m_steel_l = mat("steel_light")
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)
    m_ember = mat("ember")
    m_plaster = mat("plaster")
    m_dirt = mat("dirt")
    m_ore = mat("ore")

    b = Builder("smithy")
    stones = (m_stone, m_stone_l, m_stone_d)

    # 工作场院
    dirt_apron(b, 0, 1.35, 5.40, 2.20, 0.0, m_dirt, m_stone_d, seed=91)

    # ---------------- 主体：石基 + 木构上层 ----------------
    W, Dd, cy0 = 4.30, 3.10, -0.85
    z0, z1 = 0.28, 1.62
    box(b, (W + 0.20, Dd + 0.20, 0.28), (0, cy0, 0.14), m_stone_d, bevel=0.03)
    wall_shell(b, 0, cy0, W, Dd, z0, z1, m_mortar, thick=0.34)
    fh = [(-1.20, 0.62, 0.90, 1.44), (0.0, 0.86, 0.28, 1.52), (1.20, 0.62, 0.90, 1.44)]
    masonry_face(b, "+y", 0, cy0, W, Dd, z0, z1, stones, holes=fh, seed=191, row_h=0.30)
    masonry_face(b, "-y", 0, cy0, W, Dd, z0, z1, stones, holes=[(-1.0, 0.66, 0.88, 1.42),
                 (1.0, 0.66, 0.88, 1.42)], seed=192, row_h=0.30)
    masonry_face(b, "+x", 0, cy0, W, Dd, z0, z1, stones, holes=[(-0.80, 0.62, 0.90, 1.42)],
                 seed=193, row_h=0.30)
    masonry_face(b, "-x", 0, cy0, W, Dd, z0, z1, stones, holes=[(-0.80, 0.62, 0.90, 1.42)],
                 seed=194, row_h=0.30)
    quoins(b, 0, cy0, W, Dd, z0, z1, (m_stone_l, m_stone), size=0.42, row_h=0.30)

    # 上层木构（挑出 0.26，比兵营更明显 —— 铁匠铺是"临时加建"的观感）
    W2, D2 = W + 0.52, Dd + 0.52
    z2, z3 = 1.62, 2.86
    box(b, (W2, D2, 0.15), (0, cy0, z2 + 0.075), m_wood_d, bevel=0.01)
    box(b, (W2 - 0.10, D2 - 0.10, z3 - z2 - 0.10), (0, cy0, (z2 + z3) * 0.5),
        m_wood, bevel=0.01)
    timber_panel(b, "y", cy0 + D2 * 0.5 - 0.035, 0, W2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=3)
    timber_panel(b, "y", cy0 - D2 * 0.5 + 0.035, 0, W2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=3)
    timber_panel(b, "x", W2 * 0.5 - 0.035, cy0, D2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=1)
    timber_panel(b, "x", -W2 * 0.5 + 0.035, cy0, D2 - 0.05, z2 + 0.05, z3 - 0.04,
                 m_wood_d, posts=1)
    wm = (m_stone_l, m_glass, m_stone_d, m_iron, m_wood_d, m_stone_l)
    for xx in (-1.24, 1.24):
        window_v4(b, xx, cy0 + D2 * 0.5 + 0.02, 2.22, 0.56, 0.66, wm, shutters=False)
    # 上层排气天窗（铁匠铺的特征：屋面上冒气）
    for xx in (-0.70, 0.70):
        box(b, (0.72, 0.52, 0.52), (xx, cy0 - 0.35, z3 + 0.20), m_wood_d, bevel=0.01)
        box(b, (0.56, 0.06, 0.34), (xx, cy0 - 0.10, z3 + 0.24), m_glass)
        box(b, (0.80, 0.16, 0.07), (xx, cy0 - 0.12, z3 + 0.47), m_wood, bevel=0.006)

    # 屋顶：脊线沿 X，坡度更陡（rise ≈ 1.55）
    z_ridge = z3 + 1.55
    roof_gable_tiled(b, 0, cy0, W2, D2, z3, z_ridge, m_roof, m_roof_d, m_wood_d, m_gold,
                     over=0.30, course=0.30, tile_w=0.42)
    for sx in (-1, 1):
        gable_wall(b, 0, cy0, sx * W2 * 0.5, W2, D2, z3 - 0.06, z_ridge, m_plaster,
                   thick=0.24)
        for sgn in (-1, 1):
            box(b, (0.09, 0.09, 0.92), (sx * (W2 * 0.5 + 0.03), cy0 + sgn * 0.62,
                z3 + 0.50), m_wood_d, rot=(math.radians(30) * sgn, 0, 0), bevel=0.004)

    # ---------------- 高烟囱（≥ 屋脊 1.2m：整栋的视觉锚）----------------
    chimney(b, 1.52, -1.55, 0.86, 0.20, z_ridge + 1.30, m_stone, m_stone_l, m_glass)
    # 烟囱基座的斜撑（结构可信度）
    for sy in (-1, 1):
        box(b, (0.62, 0.16, 0.16), (1.52, -1.55 + sy * 0.50, 2.10), m_stone_d,
            rot=(D(38) * sy, 0, 0), bevel=0.006)

    # ---------------- 前檐工作棚（柱撑，1.1m 深）----------------
    for sx in (-1, 1):
        box(b, (0.18, 0.18, 2.30), (sx * 1.90, cy0 + Dd * 0.5 + 1.00, 1.15), m_wood_d,
            bevel=0.008)
    box(b, (4.10, 1.30, 0.10), (0, cy0 + Dd * 0.5 + 0.62, 2.48), m_wood_d, bevel=0.008)
    shed_roof(b, 0, cy0 + Dd * 0.5 + 0.66, 4.10, 1.42, 2.88, 2.46, m_roof, m_roof_d,
              m_wood_d, over=0.22)
    # 棚下横梁
    box(b, (3.90, 0.12, 0.12), (0, cy0 + Dd * 0.5 + 0.92, 2.24), m_wood_d, bevel=0.006)

    # ---------------- 外露锻炉（正面右侧突出半圆）----------------
    fx, fy = 1.62, cy0 + Dd * 0.5 + 0.28
    cylc(b, 0.72, 0.62, 1.24, loc=(fx, fy, 0.62), material=m_stone_d, sides=10,
          weight=W_ROOT)
    for k in range(10):
        a = TAU * k / 10.0
        box(b, (0.44, 0.10, 0.20), (fx + 0.66 * math.cos(a), fy + 0.66 * math.sin(a),
            1.02), m_stone, rot=(0, 0, a + math.pi * 0.5), bevel=0.006)
    # 炉口（自发光）
    cylc(b, 0.34, 0.34, 0.10, loc=(fx, fy + 0.58, 0.66), rot=(D(90), 0, 0),
          material=m_glass, sides=10, weight=W_ROOT)
    cylc(b, 0.26, 0.26, 0.08, loc=(fx, fy + 0.63, 0.64), rot=(D(90), 0, 0),
          material=m_ember, sides=10, weight=W_ROOT)
    for k in range(4):
        box(b, (0.06, 0.06, 0.40), (fx - 0.18 + k * 0.12, fy + 0.64, 0.64), m_iron,
            rot=(0, 0, 0.3 * (k - 1.5)))
    # 炉罩（锥形排烟罩）
    cylc(b, 0.88, 0.34, 0.66, loc=(fx, fy, 1.40), material=m_iron, sides=10,
          weight=W_ROOT)
    cylc(b, 0.92, 0.92, 0.07, loc=(fx, fy, 1.30), material=m_steel, sides=10,
          weight=W_ROOT)
    # 烟道接到主体
    box(b, (0.34, 0.34, 0.62), (fx - 0.20, fy - 0.62, 1.72), m_iron, bevel=0.01)

    # ---------------- 铁砧 + 水槽 + 料场 ----------------
    # 铁砧：木墩 + 铁砧身 + 砧角
    ax, ay = -1.55, cy0 + Dd * 0.5 + 0.72
    cylc(b, 0.26, 0.24, 0.52, loc=(ax, ay, 0.26), material=m_wood, sides=10, weight=W_ROOT)
    box(b, (0.46, 0.26, 0.16), (ax, ay, 0.60), m_steel, bevel=0.02)
    box(b, (0.24, 0.20, 0.14), (ax, ay, 0.74), m_steel_l, bevel=0.02)
    box(b, (0.30, 0.12, 0.09), (ax + 0.28, ay, 0.68), m_steel, bevel=0.012)
    # 锤子
    box(b, (0.40, 0.03, 0.03), (ax - 0.32, ay, 0.66), m_wood_d, rot=(0, D(22), 0))
    box(b, (0.12, 0.10, 0.10), (ax - 0.12, ay, 0.72), m_iron, bevel=0.01)
    # 水槽（淬火桶）
    cylc(b, 0.34, 0.30, 0.54, loc=(-2.20, cy0 + Dd * 0.5 + 1.55, 0.27), material=m_wood,
          sides=10, weight=W_ROOT)
    cylc(b, 0.30, 0.30, 0.03, loc=(-2.20, cy0 + Dd * 0.5 + 1.55, 0.50),
          material=mat("water"), sides=10, weight=W_ROOT)
    cylc(b, 0.36, 0.36, 0.05, loc=(-2.20, cy0 + Dd * 0.5 + 1.55, 0.16), material=m_iron,
          sides=10, weight=W_ROOT)
    # 矿石堆 + 煤堆
    for i in range(8):
        a = TAU * i / 8.0
        b.ico(0.14, loc=(fx + 0.95 + 0.22 * math.cos(a), fy - 0.55 + 0.20 * math.sin(a),
            0.12 + (0.10 if i % 3 == 0 else 0.0)), material=m_ore, subdiv=1,
            weight=W_ROOT, scale=(1.1, 1.0, 0.8))
    for i in range(7):
        a = TAU * i / 7.0
        b.ico(0.13, loc=(fx + 0.95 + 0.18 * math.cos(a), fy - 1.00 + 0.16 * math.sin(a),
            0.10), material=m_glass, subdiv=1, weight=W_ROOT, scale=(1.1, 1.0, 0.7))
    # 料架（半成品铁条）
    for k in range(4):
        box(b, (1.10, 0.06, 0.06), (ax - 0.20, cy0 + Dd * 0.5 + 1.32, 1.28 + k * 0.12),
            m_steel)
    for sx in (-1, 1):
        box(b, (0.08, 0.08, 1.10), (ax - 0.20 + sx * 0.56, cy0 + Dd * 0.5 + 1.32, 0.95),
            m_wood_d)
    # 磨刀石
    cylc(b, 0.28, 0.28, 0.10, loc=(-2.30, 0.30, 0.72), rot=(0, D(90), 0), material=m_stone,
          sides=14, weight=W_ROOT)
    for sx in (-1, 1):
        box(b, (0.07, 0.07, 0.62), (-2.30 + sx * 0.22, 0.30, 0.32), m_wood_d)

    # 招牌：挂着的铁砧图形 + 旗帜
    box(b, (0.10, 0.60, 0.10), (0.10, cy0 + D2 * 0.5 + 0.20, 3.10), m_iron)
    banner_v4(b, -0.20, 2.30, 3.55, 4.35, m_wood_d, m_cloth, m_gold, m_cloth, idx=1,
              dirx=1.0, diry=0.0, fw=0.66)

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 4. 箭塔 4x4 —— 细高 + 木挑台
# ===========================================================================

def build_tower():
    coll = K3.reset_scene()
    r = BuildingRig("tower")
    r.add_flag(0.0, 0.0, 7.95, 8.80, dirx=1.0, diry=0.0)
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
    m_glass = mat("glass")
    m_cloth = mat("cloth", team=True)
    m_ember = mat("ember")
    m_steel = mat("steel_light")
    m_hay = mat("hay")

    b = Builder("tower")
    sides = 8          # 八边形：比 12 边更"墩实"，比 4 边更不像烟囱

    # ---------------- 基座：两级收分 ----------------
    cylc(b, 1.88, 1.72, 0.34, loc=(0, 0, 0.17), material=m_stone_d, sides=sides,
          weight=W_ROOT)
    cylc(b, 1.72, 1.48, 0.62, loc=(0, 0, 0.65), material=m_stone_d, sides=sides,
          weight=W_ROOT)
    cylc(b, 1.50, 1.46, 0.10, loc=(0, 0, 1.01), material=m_stone_l, sides=sides,
          weight=W_ROOT)

    # ---------------- 塔身：0.96 → 5.90，向上收分 ----------------
    cylc(b, 1.46, 1.16, 4.94, loc=(0, 0, 3.53), material=m_stone, sides=sides,
          weight=W_ROOT)
    # 砌石：按八边形逐块贴面（用 masonry_ring，半径随高度线性收）
    seg_h = 0.86
    for i in range(5):
        zz = 1.20 + i * seg_h
        rr = 1.46 + (1.16 - 1.46) * ((zz - 1.06) / 4.94)
        masonry_ring(b, 0, 0, rr + 0.005, zz, zz + seg_h * 0.92,
                     (m_stone, m_stone_l, m_stone_d), sides=sides, row_h=seg_h * 0.92,
                     depth=0.06, seed=210 + i)
        cylc(b, rr + 0.035, rr + 0.035, 0.07, loc=(0, 0, zz - 0.02), material=m_stone_l,
              sides=sides, weight=W_ROOT)
    # 箭孔：四向 × 两层
    for zz in (2.62, 4.34):
        for k in range(4):
            a = TAU * k / 4.0 + math.pi * 0.25
            rr = 1.46 + (1.16 - 1.46) * ((zz - 1.06) / 4.94)
            arrow_loophole(b, math.cos(a) * rr, math.sin(a) * rr, zz, a, m_stone_l,
                           m_glass)
    # 门（底部）+ 台阶
    door_v4(b, 0.0, 1.44, 0.30, 1.10, 1.84,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_steel), planks=5,
            arch_rise=0.30)
    for i, (yy, zz, hh) in enumerate(((1.52, 0.24, 0.20), (1.70, 0.10, 0.20))):
        box(b, (1.40, 0.26, hh), (0, yy, zz), m_stone_l, bevel=0.01)

    # ---------------- 木挑台（塔与烟囱的分界线）----------------
    z_deck = 6.22
    cylc(b, 1.52, 1.52, 0.10, loc=(0, 0, z_deck - 0.06), material=m_wood_d, sides=12,
          weight=W_ROOT)
    cylc(b, 1.86, 1.86, 0.16, loc=(0, 0, z_deck), material=m_wood, sides=12,
          weight=W_ROOT)
    # 斜撑：一圈短梁从塔身撑到挑台外沿
    for k in range(8):
        a = TAU * k / 8.0
        box(b, (0.90, 0.14, 0.14),
            (math.cos(a) * 1.42, math.sin(a) * 1.42, z_deck - 0.42), m_wood_d,
            rot=(0, D(-38), a + math.pi * 0.5), bevel=0.006)
    # 栏杆：立柱 + 上下横梁
    for k in range(12):
        a = TAU * k / 12.0
        box(b, (0.10, 0.10, 0.86), (math.cos(a) * 1.76, math.sin(a) * 1.76,
            z_deck + 0.51), m_wood, rot=(0, 0, a), bevel=0.004)
    cylc(b, 1.80, 1.80, 0.09, loc=(0, 0, z_deck + 0.92), material=m_wood_d, sides=12,
          weight=W_ROOT)
    cylc(b, 1.80, 1.80, 0.07, loc=(0, 0, z_deck + 0.44), material=m_wood, sides=12,
          weight=W_ROOT)
    # 挑台上的盾牌（一圈）
    for k in range(4):
        a = TAU * k / 4.0 + 0.4
        cylc(b, 0.28, 0.28, 0.07, loc=(math.cos(a) * 1.83, math.sin(a) * 1.83,
            z_deck + 0.56), rot=(D(90), 0, a + math.pi * 0.5), material=m_cloth,
              sides=10, weight=W_ROOT)
        cylc(b, 0.09, 0.09, 0.04, loc=(math.cos(a) * 1.86, math.sin(a) * 1.86,
            z_deck + 0.56), rot=(D(90), 0, a + math.pi * 0.5), material=m_gold,
              sides=8, weight=W_ROOT)
    # 顶部锥顶（青绿瓦）
    cylc(b, 1.62, 1.60, 0.14, loc=(0, 0, z_deck + 1.00), material=m_wood_d, sides=12,
          weight=W_ROOT)
    cone_roof_tiled(b, 0, 0, 1.56, z_deck + 1.06, 8.10, m_roof, m_roof_d, m_gold,
                    sides=12, bands=7)
    # 旗杆从锥顶尖出来
    cylc(b, 0.055, 0.045, 1.05, loc=(0, 0, 8.06), material=m_wood_d, sides=6,
          weight=W_ROOT)
    b.ico(0.08, loc=(0, 0, 9.10), material=m_gold, subdiv=1, weight=W_ROOT)
    banner_v4(b, 0.0, 0.0, 7.95, 8.80, m_wood_d, m_cloth, m_gold, m_cloth, idx=0,
              dirx=1.0, diry=0.0, fw=0.62)

    # ---------------- 塔下：火盆 + 柴堆 + 梯 ----------------
    cylc(b, 0.42, 0.30, 0.46, loc=(-1.48, 0.90, 0.23), material=m_iron, sides=8,
          weight=W_ROOT)
    cylc(b, 0.30, 0.30, 0.05, loc=(-1.48, 0.90, 0.46), material=m_ember, sides=8,
          weight=W_ROOT)
    for k in range(6):
        a = TAU * k / 6.0
        box(b, (0.10, 0.10, 0.46), (-1.48 + 0.30 * math.cos(a), 0.90 + 0.30 * math.sin(a),
            0.42), m_stone_d, rot=(0, 0, a), bevel=0.004)
    woodpile(b, -1.62, -0.95, 0.0, m_wood, m_wood_d)
    # 梯子（检修用，贴塔身）
    for k in (-1, 1):
        box(b, (0.06, 0.06, 2.40), (1.05 + k * 0.15, 1.16, 1.20), m_wood_d,
            rot=(0, 0, 0), bevel=0.004)
    for i in range(7):
        box(b, (0.34, 0.05, 0.05), (1.05, 1.16, 0.32 + i * 0.32), m_wood_d)

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 5. 农场 4x4 —— 低矮横向 + 茅草顶 + 田垄
# ===========================================================================

def build_farm():
    coll = K3.reset_scene()
    r = BuildingRig("farm")
    r.add_flag(0.30, 1.90, 2.62, 3.25, dirx=1.0, diry=0.0)
    r.build(coll)

    m_stone = mat("stone")
    m_stone_d = mat("stone_dark")
    m_stone_l = mat("stone_light")
    m_hay = mat("hay")
    m_wood = mat("wood")
    m_wood_d = mat("wood_dark")
    m_iron = mat("iron")
    m_gold = mat("gold")
    m_cloth = mat("cloth", team=True)
    m_dirt = mat("dirt")
    m_grass = mat("grass")
    m_leaf = mat("leaf")
    m_glass = mat("glass")

    b = Builder("farm")
    stones = (m_stone, m_stone_l, m_stone_d)

    # ---------------- 田垄：占前部 2/3 ----------------
    box(b, (3.70, 2.00, 0.10), (-0.10, 0.94, 0.05), m_dirt, bevel=0.02)
    for i in range(5):
        yy = 0.16 + i * 0.38
        box(b, (3.50, 0.24, 0.14), (-0.10, yy, 0.10), m_dirt, bevel=0.05)
        # 垄上的麦苗：一排小簇
        for k in range(9):
            xx = -1.75 + k * 0.40 + (0.06 if i % 2 else 0.0)
            b.ico(0.085, loc=(xx, yy, 0.20), material=m_leaf, subdiv=1,
                  weight=W_ROOT, scale=(1.0, 0.9, 1.35))
    # 地头的农具（锄头）
    box(b, (0.05, 0.05, 0.90), (1.55, 1.62, 0.45), m_wood_d, rot=(D(12), 0, 0))
    box(b, (0.16, 0.06, 0.14), (1.55, 1.68, 0.02), m_iron, rot=(D(12), 0, 0))

    # ---------------- 小屋：低矮，茅草顶大出檐 ----------------
    W, Dd, cy0 = 2.20, 1.80, -1.05
    z0, z1 = 0.10, 1.42
    box(b, (W + 0.22, Dd + 0.22, 0.16), (0, cy0, 0.08), m_stone_d, bevel=0.02)
    wall_shell(b, 0, cy0, W, Dd, z0, z1, m_stone_d, thick=0.28)
    # 下半石砌 / 上半木构（农舍的分层比主城弱，但仍有）
    masonry_face(b, "+y", 0, cy0, W, Dd, z0, 0.86, stones,
                 holes=[(0.0, 1.16, 0.10, 0.80)], seed=231, row_h=0.30)
    masonry_face(b, "-y", 0, cy0, W, Dd, z0, 0.86, stones, seed=232, row_h=0.30)
    masonry_face(b, "+x", 0, cy0, W, Dd, z0, 0.86, stones, seed=233, row_h=0.30)
    masonry_face(b, "-x", 0, cy0, W, Dd, z0, 0.86, stones, seed=234, row_h=0.30)
    timber_panel(b, "y", cy0 + Dd * 0.5 - 0.02, 0, W - 0.04, 0.88, z1 - 0.02, m_wood_d,
                 posts=2, braces=False)
    timber_panel(b, "y", cy0 - Dd * 0.5 + 0.02, 0, W - 0.04, 0.88, z1 - 0.02, m_wood_d,
                 posts=2, braces=False)
    timber_panel(b, "x", W * 0.5 - 0.02, cy0, Dd - 0.04, 0.88, z1 - 0.02, m_wood_d,
                 posts=1, braces=False)
    timber_panel(b, "x", -W * 0.5 + 0.02, cy0, Dd - 0.04, 0.88, z1 - 0.02, m_wood_d,
                 posts=1, braces=False)
    door_v4(b, 0.0, cy0 + Dd * 0.5, 0.16, 1.02, 1.24,
            (m_stone_l, m_wood_d, m_stone_d, m_iron, m_stone_l, m_gold), planks=4,
            arch_rise=0.10)
    window_v4(b, -0.72, cy0 + Dd * 0.5 + 0.02, 0.90, 0.40, 0.44,
              (m_stone_l, m_glass, m_stone_d, m_iron, m_wood_d, m_stone_l), shutters=True)
    # 茅草顶：厚、圆、大出檐
    thatch_roof_y(b, 0, cy0, W, Dd, z1, z1 + (W * 0.5 + 0.55) * 0.92, m_hay, m_wood_d,
                  m_wood, over=0.55, layers=5)
    for sy in (-1, 1):
        gable_tri_y(b, 0, cy0, cy0 + sy * (Dd * 0.5 - 0.02), W, z1 - 0.04,
                    z1 + (W * 0.5 + 0.55) * 0.92, m_wood_d, thick=0.20)
    # 屋檐下的草束
    for k in range(10):
        xx = -1.70 + k * 0.38
        b.ico(0.09, loc=(xx, cy0 + Dd * 0.5 + 0.52, z1 - 0.16), material=m_hay,
              subdiv=1, weight=W_ROOT, scale=(1.4, 1.0, 0.7))

    # ---------------- 水井 ----------------
    wx, wy = 1.28, -1.18
    cylc(b, 0.48, 0.46, 0.62, loc=(wx, wy, 0.31), material=m_stone_d, sides=10,
          weight=W_ROOT)
    for k in range(10):
        a = TAU * k / 10.0
        box(b, (0.28, 0.10, 0.26), (wx + 0.44 * math.cos(a), wy + 0.44 * math.sin(a),
            0.66), m_stone, rot=(0, 0, a + math.pi * 0.5), bevel=0.006)
    cylc(b, 0.36, 0.36, 0.03, loc=(wx, wy, 0.60), material=mat("water"), sides=10,
          weight=W_ROOT)
    for sx in (-1, 1):
        box(b, (0.08, 0.08, 1.40), (wx + sx * 0.42, wy, 1.30), m_wood_d, bevel=0.005)
    box(b, (1.02, 0.10, 0.10), (wx, wy, 1.98), m_wood_d, bevel=0.005)
    # 井架顶（小双坡）
    for sy in (-1, 1):
        o = Vector((wx, wy + sy * 0.34, 1.96))
        up = Vector((0, -sy * 0.34, 0.42))
        tile_slope(b, o, Vector((1, 0, 0)), up, 1.10, 1.10, math.hypot(0.34, 0.42),
                   m_hay, m_wood_d, course=0.22, tile_w=0.34, seed=240 + sy)
    # 吊桶
    cylc(b, 0.14, 0.12, 0.20, loc=(wx, wy, 1.30), material=m_wood, sides=8,
          weight=W_ROOT)
    box(b, (0.03, 0.03, 0.62), (wx, wy, 1.66), m_iron)

    # ---------------- 稻草人 ----------------
    sx0, sy0 = 0.55, 0.66
    box(b, (0.09, 0.09, 1.62), (sx0, sy0, 0.81), m_wood_d, bevel=0.005)
    box(b, (0.84, 0.08, 0.08), (sx0, sy0, 1.26), m_wood_d, bevel=0.005)
    cylc(b, 0.16, 0.20, 0.52, loc=(sx0, sy0, 1.14), material=m_hay, sides=8,
          weight=W_ROOT)
    b.ico(0.16, loc=(sx0, sy0, 1.52), material=m_hay, subdiv=1, weight=W_ROOT)
    # 破帽子
    cylc(b, 0.24, 0.24, 0.03, loc=(sx0, sy0, 1.64), material=m_wood_d, sides=10,
          weight=W_ROOT)
    cylc(b, 0.12, 0.10, 0.12, loc=(sx0, sy0, 1.71), material=m_wood_d, sides=8,
          weight=W_ROOT)
    # 袖子
    for s in (-1, 1):
        cylc(b, 0.07, 0.06, 0.34, loc=(sx0 + s * 0.38, sy0, 1.26), rot=(0, D(90) * s, 0),
              material=m_hay, sides=6, weight=W_ROOT)

    # ---------------- 篱笆 + 草垛 ----------------
    fence_run(b, -1.90, 1.90, 1.90, 1.90, 0.0, m_wood, m_wood_d, h=0.92, step=0.56)
    fence_run(b, -1.90, -0.10, -1.90, 1.90, 0.0, m_wood, m_wood_d, h=0.92, step=0.56)
    fence_run(b, 1.90, -0.10, 1.90, 1.90, 0.0, m_wood, m_wood_d, h=0.92, step=0.56)
    for i, (bx, by) in enumerate(((-1.42, 1.62), (-1.30, 1.20))):
        cylc(b, 0.30, 0.24, 0.52, loc=(bx, by, 0.26), material=m_hay, sides=9,
              weight=W_ROOT)
        cylc(b, 0.26, 0.20, 0.22, loc=(bx, by, 0.60), material=m_hay, sides=9,
              weight=W_ROOT)
        for k in range(3):
            a = TAU * k / 3.0
            box(b, (0.03, 0.03, 0.54), (bx + 0.28 * math.cos(a), by + 0.28 * math.sin(a),
                0.28), m_wood_d)
    # 鸡舍（小木箱 + 斜板）
    box(b, (0.52, 0.42, 0.38), (-1.52, -1.62, 0.19), m_wood, bevel=0.01)
    for i in range(3):
        box(b, (0.50, 0.04, 0.03), (-1.52, -1.42 + i * 0.0, 0.10 + i * 0.12), m_wood_d)
    box(b, (0.66, 0.06, 0.06), (-1.52, -1.40, 0.44), m_wood_d, rot=(D(28), 0, 0))
    # 小推车
    box(b, (0.62, 0.40, 0.06), (1.46, 0.10, 0.30), m_wood, bevel=0.008)
    for sx in (-1, 1):
        cylc(b, 0.16, 0.16, 0.05, loc=(1.46 + sx * 0.30, 0.10, 0.22), rot=(0, D(90), 0),
              material=m_wood_d, sides=10, weight=W_ROOT)
    box(b, (0.04, 0.60, 0.04), (1.46, -0.26, 0.26), m_wood_d, rot=(D(12), 0, 0))

    objs = b.build_meshes(coll)
    r.bind(objs)
    r.wave_action("idle", 61)
    return r, objs


# ===========================================================================
# 注册
# ===========================================================================

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


def export_glb(path):
    """与 v5/build_all.py 同一套导出参数（顶点色 AO 必须显式 ACTIVATE）。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    kw = dict(filepath=path, export_format="GLB", use_selection=False,
              export_apply=False, export_yup=True,
              export_animations=True, export_animation_mode="NLA_TRACKS",
              export_bake_animation=False, export_optimize_animation_size=False,
              export_normals=True, export_tangents=True, export_materials="EXPORT",
              export_skins=True, export_def_bones=False)
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)
    return K3.glb_info(path)


def setup_engine():
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    dev = "CPU"
    for t in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = t
            prefs.get_devices()
            if any(d.type == t for d in prefs.devices):
                dev = t
                break
        except Exception:
            continue
    for d in prefs.devices:
        d.use = (d.type == dev)
    sc.cycles.device = "GPU" if dev != "CPU" else "CPU"
    sc.cycles.samples = 48
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 4
    print("[v6] render device =", dev)


def main():
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    which = args[0] if args else "all"
    do_qc = "--qc" in args
    do_export = "--export" in args
    names = list(BUILDERS.keys()) if which == "all" else [which]

    import json
    reports = []
    if do_qc:
        setup_engine()
    for nm in names:
        rig, objs = BUILDERS[nm]()
        rig.rest_pose()
        mats, stat = textured.apply(objs, K3.PALETTE)
        ao_n = textured.bake_ao(objs) if (do_qc or do_export) else 0
        mn, mx = K3.bbox(objs)
        rep = {"name": nm, "size": [round(v, 2) for v in (mx - mn)],
               "zmin": round(mn.z, 2), "zmax": round(mx.z, 2), "zones": stat,
               "ao_baked": ao_n}
        if do_qc:
            c = (0.0, 0.0, (mn.z + mx.z) * 0.5)
            radius = max(mx.x - mn.x, mx.z - mn.z) * 0.5
            K3.render_views(nm, QC_DIR, c, max(radius, 0.6) * 1.32, res=(900, 1120),
                            views={"正": (0.0, 1.0, 0.10),
                                   "三四": (0.88, 1.0, 0.26),
                                   "四": (-0.88, 1.0, 0.26),
                                   "背": (0.0, -1.0, 0.14),
                                   "低": (0.72, 1.0, 0.02)})
        if do_export:
            textured.export_mode(mats, True)
            rig.resume_nla()
            path = os.path.join(OUT_DIR, FILE_OF[nm])
            export_glb(path)
            rep["glb"] = FILE_OF[nm]
        reports.append(rep)
        print("[v6] " + json.dumps(rep, ensure_ascii=False))
        for ob in list(bpy.data.objects):
            bpy.data.objects.remove(ob, do_unlink=True)
        for ac in list(bpy.data.actions):
            bpy.data.actions.remove(ac)
    print("HEADLESS_V6 " + json.dumps(reports, ensure_ascii=False))


if __name__ == "__main__":
    main()
