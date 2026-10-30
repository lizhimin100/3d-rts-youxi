# -*- coding: utf-8 -*-
"""
texgen.py —— 铁血战歌 材质贴图库（纯 numpy，无 bpy / 无外部依赖）

为什么要有这一层：
  v3/v4 的模型只有"顶点色 + 卡通着色"，近看是一块块纯色塑料。
  魔兽争霸3 的质感其实**不在多边形数**上，而在三件事：
    1) 手绘贴图里的明暗关系（砖缝压暗、瓦片压边、金属划痕、布纹）；
    2) 法线贴图给平面补出凹凸（石块边缘、木纹、皮革颗粒）；
    3) 大色块 + 强烈边缘暗部（"硬邦邦"的块面感）。

  所以这里生成的是**中性细节贴图**：albedo 均值归一到 0.90（乘到调色板基色上，
  不改变 MatKit 的配色语义），法线由同一张高度场 Sobel 求出（真正切开光照，
  不是"看起来像凸起"）。

输出：
  美术/贴图/<family>_albedo.png    （sRGB，RGB，细节乘算层，均值 0.90）
  美术/贴图/<family>_normal.png    （切线空间法线，RGB，OpenGL 约定 +Y）

每个 family 都**可平铺**（所有噪声都用周期格点，砖瓦按整数行列回绕），
UV 立方投影后任意接缝都不会露馅。
"""
import os
import zlib
import struct
import math
import numpy as np

OUT = r"E:\自定义游戏\简易rts\美术\贴图"
S = 512


# ===========================================================================
# 基础：可平铺噪声（支持各向异性频率 —— 木纹/刷痕必须有方向）
# ===========================================================================

def _bilerp(fx, fy, seed, size=S):
    rng = np.random.default_rng(seed)
    g = rng.random((fy, fx)).astype(np.float32)
    ys = np.linspace(0, fy, size, endpoint=False, dtype=np.float32)
    xs = np.linspace(0, fx, size, endpoint=False, dtype=np.float32)
    y0 = np.floor(ys).astype(np.int32)
    x0 = np.floor(xs).astype(np.int32)
    ty = (ys - y0)[:, None]
    tx = (xs - x0)[None, :]
    ty = ty * ty * (3 - 2 * ty)
    tx = tx * tx * (3 - 2 * tx)
    y1 = (y0 + 1) % fy
    x1 = (x0 + 1) % fx
    a = g[np.ix_(y0, x0)]
    b = g[np.ix_(y0, x1)]
    c = g[np.ix_(y1, x0)]
    d = g[np.ix_(y1, x1)]
    return (a * (1 - tx) * (1 - ty) + b * tx * (1 - ty) + c * (1 - tx) * ty + d * tx * ty).astype(np.float32)


def noise2(fx, fy, seed, size=S):
    return _bilerp(max(1, int(fx)), max(1, int(fy)), seed, size)


def fbm2(fx, fy, octaves, seed, gain=0.5, size=S):
    out = np.zeros((size, size), np.float32)
    amp, total = 1.0, 0.0
    for i in range(octaves):
        k = 2 ** i
        if fx * k > size // 2 or fy * k > size // 2:
            break
        out += noise2(fx * k, fy * k, seed + i * 977, size) * amp
        total += amp
        amp *= gain
    return out / max(total, 1e-5)


def fbm(freq, octaves, seed, gain=0.5, size=S):
    return fbm2(freq, freq, octaves, seed, gain, size)


def smoothstep(a, b, x):
    t = np.clip((x - a) / max(b - a, 1e-6), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def grid_uv(size=S):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    return yy, xx


# ===========================================================================
# 法线 / AO
# ===========================================================================

def normal_from_height(h, strength=2.4):
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    nx = -gx * strength
    ny = -gy * strength
    nz = np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    # glTF / Godot 用 OpenGL 约定：+Y 朝上（贴图 v 向上）
    return np.stack([nx / ln * 0.5 + 0.5, -ny / ln * 0.5 + 0.5, nz / ln * 0.5 + 0.5], -1)


def height_to_ao(h, strength=1.0):
    acc, w = np.zeros_like(h), 0.0
    for r in (1, 2, 3, 5, 8):
        k = np.roll(np.roll(h, r, 0), r, 1) + np.roll(np.roll(h, -r, 0), -r, 1)
        acc += k * (1.0 / r)
        w += 2.0 / r
    blur = acc / w
    d = np.clip((blur - h) * 4.0, 0.0, 1.0)
    return 1.0 - d * strength * 0.6


# ===========================================================================
# 材质族：返回 (height, albedo, normal_strength)
# albedo 是**乘算细节层**（后面统一归一到均值 0.90）
# ===========================================================================

def tex_ashlar(seed=11):
    """错缝砌石：块面大、灰缝深、每块明度不同、转角磕掉 —— 建筑主材"""
    yy, xx = grid_uv()
    rows, cols = 7, 5
    jit = fbm(6, 3, seed) * 0.035
    ry = yy * rows + jit
    row_i = np.floor(ry)
    off = (row_i % 2) * 0.5
    rx = xx * cols + off + (fbm(9, 2, seed + 3) - 0.5) * 0.055
    col_i = np.floor(rx)
    fy = ry - row_i
    fx = rx - col_i

    rng = np.random.default_rng(seed + 7)
    bv = rng.random((rows, cols + 1)).astype(np.float32)
    val = bv[np.mod(row_i.astype(np.int32), rows), np.mod(col_i.astype(np.int32), cols + 1)]

    edge = np.minimum(np.minimum(fx, 1 - fx), np.minimum(fy, 1 - fy))
    edge = edge + (fbm(24, 2, seed + 11) - 0.5) * 0.05
    mortar = 1.0 - smoothstep(0.028, 0.052, edge)

    bevel = smoothstep(0.0, 0.10, edge)
    chip = smoothstep(0.66, 0.99, fbm(30, 2, seed + 21)) * smoothstep(0.0, 0.20, edge)

    surf = fbm(64, 3, seed + 31) * 0.12 + fbm(180, 2, seed + 41) * 0.05
    h = bevel * (0.74 + val * 0.26) - chip * 0.20 - mortar * 0.62 + surf * 0.85

    # 明度：块面 0.86~1.06，灰缝压到 0.30，磕角压一档
    alb = 0.86 + (val - 0.5) * 0.20
    alb *= 0.90 + bevel * 0.12 + surf * 0.28
    alb *= 1.0 - mortar * 0.68
    alb *= 1.0 - chip * 0.26
    # 灰缝里积的脏
    alb *= 1.0 - mortar * fbm(60, 2, seed + 51) * 0.20
    alb *= height_to_ao(h, 1.0)
    return h, alb, 2.8


def tex_cobble(seed=12):
    """圆石地面：小块、圆顶、缝里发黑"""
    yy, xx = grid_uv()
    warp = (fbm(8, 3, seed) - 0.5) * 0.10
    rows, cols = 11, 9
    ry = yy * rows + warp
    rx = xx * cols + (np.floor(ry) % 2) * 0.5 + warp * 1.3
    fy = ry - np.floor(ry)
    fx = rx - np.floor(rx)
    d = np.sqrt((np.minimum(fx, 1 - fx) - 0.5) ** 2 + (np.minimum(fy, 1 - fy) - 0.5) ** 2)
    dome = 1.0 - smoothstep(0.28, 0.66, d)
    gap = 1.0 - smoothstep(0.0, 0.12, dome)
    rng = np.random.default_rng(seed + 5)
    val = rng.random((rows + 1, cols + 1)).astype(np.float32)[
        np.mod(np.floor(ry).astype(np.int32), rows + 1),
        np.mod(np.floor(rx).astype(np.int32), cols + 1)]
    surf = fbm(48, 3, seed + 9) * 0.14 + fbm(150, 2, seed + 13) * 0.05
    h = dome * (0.62 + val * 0.38) + surf * 0.55 - gap * 0.35
    alb = (0.84 + (val - 0.5) * 0.22) * (0.55 + dome * 0.52)
    alb *= 1.0 - gap * 0.45
    alb *= 0.92 + surf * 0.5
    alb *= height_to_ao(h, 1.1)
    return h, alb, 3.0


def tex_plaster(seed=13):
    """灰泥墙：大面平整、细砂粒 + 裂纹 + 水渍（与砌石混搭出半木结构）"""
    base = fbm(5, 3, seed)
    grit = fbm2(120, 120, 2, seed + 5) * 0.5 + fbm(40, 2, seed + 8) * 0.5
    cr = 1.0 - np.abs(fbm(16, 3, seed + 12) * 2 - 1)
    crack = smoothstep(0.972, 1.0, cr)
    stain = smoothstep(0.58, 0.86, fbm(3, 3, seed + 21))
    h = grit * 0.30 + base * 0.16 - crack * 0.45
    alb = 0.95 + (grit - 0.5) * 0.10 + (base - 0.5) * 0.07
    alb *= 1.0 - crack * 0.55
    alb *= 1.0 - stain * 0.14
    alb *= height_to_ao(h, 0.9)
    return h, alb, 1.9


def tex_shingle(seed=14):
    """鱼鳞瓦：半圆瓦片叠压、行间错缝、瓦心鼓起、下缘压边

    为什么用"鱼鳞"而不是长条瓦：魔兽3 的屋顶远看是一组半圆重复，
    靠明暗节奏读作"瓦"；长条瓦在 30m 俯视下会糊成一片横向条纹。
    """
    yy, xx = grid_uv()
    rows, cols = 9, 9
    warp = (fbm(7, 2, seed) - 0.5) * 0.02
    ry = yy * rows + warp
    row = np.floor(ry)
    fy = ry - row
    rx = xx * cols + (row % 2) * 0.5 + (fbm(11, 2, seed + 4) - 0.5) * 0.02
    cx = rx - np.floor(rx)

    ex = (cx - 0.5) * 1.90
    ey = np.maximum(0.0, 0.52 - fy) * 1.70
    r = np.sqrt(ex * ex + ey * ey)
    # 半圆瓦：上缘被上一排压平（h≈0），下缘是圆弧瓦唇
    dome = (1.0 - smoothstep(0.52, 0.94, r)) * smoothstep(0.0, 0.14, fy)
    seam = 1.0 - smoothstep(0.0, 0.09, np.minimum(np.minimum(cx, 1 - cx),
                                                 np.minimum(fy, 1 - fy) * 0.8))
    lip = smoothstep(0.10, 0.95, fy)
    h = dome * 0.85 - seam * 0.38 + fbm(90, 2, seed + 9) * 0.05

    # 上缘藏在上一排下面 → 0.58；瓦唇外露 → 1.04
    alb = 0.58 + lip * 0.40 + dome * 0.08
    alb *= 1.0 - seam * 0.42
    alb *= 0.92 + fbm(80, 2, seed + 9) * 0.16
    alb *= height_to_ao(h, 1.0)
    return h, alb, 3.2


def tex_plank(seed=15):
    """竖木板：顺纹拉长的木纹、板缝压暗、钉眼"""
    yy, xx = grid_uv()
    cols = 6
    rx = xx * cols
    ci = np.floor(rx)
    fx = rx - ci
    gap = 1.0 - smoothstep(0.010, 0.038, np.minimum(fx, 1 - fx))
    # 顺纹：x 高频、y 极低频 → 竖直条纹
    grain = fbm2(22, 2, 4, seed, 0.55)
    ring = np.abs(fbm2(10, 1, 3, seed + 17, 0.5) * 2 - 1)
    fine = fbm2(70, 8, 2, seed + 6)
    wood = grain * 0.55 + (1.0 - ring) * 0.25 + fine * 0.20
    rng = np.random.default_rng(seed + 2)
    val = rng.random((1, cols + 1)).astype(np.float32)[0, np.mod(ci.astype(np.int32), cols)]

    nails = np.zeros_like(wood)
    rr = np.random.default_rng(seed + 3)
    for _ in range(14):
        nx0, ny0 = rr.random(2)
        nx0 = (math.floor(nx0 * cols) + 0.5) / cols
        d = np.sqrt((xx - nx0) ** 2 + (yy - ny0) ** 2)
        nails += 1.0 - smoothstep(0.004, 0.009, d)
    nails = np.clip(nails, 0, 1)

    h = 0.58 + wood * 0.22 - gap * 0.55 - nails * 0.30
    alb = 0.78 + wood * 0.28 + (val - 0.5) * 0.12
    alb *= 1.0 - gap * 0.72
    alb *= 1.0 - nails * 0.35
    alb *= height_to_ao(h, 0.95)
    return h, alb, 2.2


def tex_metal(seed=16):
    """金属：细拉丝（近各向同性）+ 划痕 + 凹坑 + 少量锈斑

    踩过的坑：第一版 brush 用 (140, 6) 的强各向异性噪声，法线把钢板拉成了
    "竖条波浪板"，远看像塑料瓦。钢材的表面应该**宏观平整、微观有划痕**，
    所以拉丝只在 512 里做极细的横向频率差（24:20），主体交给凹坑与划痕。
    """
    brush = fbm2(24, 20, 3, seed, 0.55) * 0.55 + fbm2(120, 120, 2, seed + 31) * 0.45
    dent = smoothstep(0.70, 0.97, fbm(11, 3, seed + 7))
    rust = smoothstep(0.78, 0.96, fbm(8, 3, seed + 21))

    scr = np.zeros((S, S), np.float32)
    rng = np.random.default_rng(seed + 9)
    for _ in range(34):
        y0, x0 = rng.random(2) * S
        ang = rng.random() * math.pi
        ln = rng.random() * 80 + 20
        for t in np.linspace(0, 1, int(ln)):
            px = int((x0 + math.cos(ang) * t) % S)
            py = int((y0 + math.sin(ang) * t) % S)
            scr[py, px] = 1.0
    scr = np.clip(scr * 0.75 + np.roll(scr, 1, 0) * 0.30, 0, 1)

    h = 0.62 + (brush - 0.5) * 0.14 - dent * 0.62 - scr * 0.34 + rust * 0.14
    alb = 0.90 + (brush - 0.5) * 0.16
    alb *= 1.0 - dent * 0.46
    alb *= 1.0 - scr * 0.34
    alb *= 1.0 - rust * 0.34
    # 大尺度明度起伏：手绘贴图没有一块是"均一灰"的，
    # 这一层给钢板分出被锤打/磨亮/积灰的区域（±12%）
    alb *= 0.90 + fbm(7, 2, seed + 77) * 0.18
    alb *= height_to_ao(h, 0.9)
    return h, alb, 2.6


def tex_leather(seed=17):
    """皮革：不规则颗粒 + 磨白边"""
    n = fbm(40, 3, seed)
    cell = smoothstep(0.40, 0.74, n)
    yy, xx = grid_uv()
    seam = np.zeros((S, S), np.float32)
    for t in np.linspace(0, 1, 30):
        px = (0.06 + t * 0.88) % 1.0
        py = (0.10 + t * 0.08) % 1.0
        d = np.sqrt((xx - px) ** 2 + (yy - py) ** 2)
        seam += 1.0 - smoothstep(0.003, 0.009, d)
    seam = np.clip(seam, 0, 1)
    h = 0.55 + cell * 0.20 - seam * 0.28
    alb = 0.78 + cell * 0.26
    alb *= 1.0 - seam * 0.42
    alb *= height_to_ao(h, 1.0)
    return h, alb, 2.0


def tex_cloth(seed=18):
    """布料：经纬 + 绒面 + 磨旧区"""
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    weave = (np.sin(xx * 2.1) * np.sin(yy * 2.1)) * 0.5 + 0.5
    fuzz = fbm2(90, 90, 2, seed)
    wear = smoothstep(0.58, 0.9, fbm(5, 3, seed + 5))
    h = 0.60 + weave * 0.12 + fuzz * 0.10 - wear * 0.06
    alb = 0.90 + (weave - 0.5) * 0.16 + (fuzz - 0.5) * 0.10
    alb *= 1.0 - wear * 0.12
    alb *= 0.88 + fbm(5, 2, seed + 61) * 0.24
    alb *= height_to_ao(h, 0.8)
    return h, alb, 1.5


def tex_bark(seed=19):
    yy, xx = grid_uv()
    ridge = 1.0 - np.abs(fbm2(14, 4, 3, seed) * 2 - 1)
    ridge = ridge ** 1.5
    crack = smoothstep(0.82, 1.0, 1.0 - np.abs(fbm2(20, 6, 3, seed + 5) * 2 - 1))
    h = ridge * 0.85 - crack * 0.40
    alb = 0.62 + ridge * 0.40
    alb *= 1.0 - crack * 0.40
    alb *= height_to_ao(h, 1.1)
    return h, alb, 2.8


def tex_leaf(seed=20):
    """树叶：**成簇**而不是迷彩。

    第一版是两层 fbm 直接 smoothstep，出来像军装迷彩；魔兽3 的树叶读的是
    "一簇簇叶子 + 簇间阴影"，所以这里把 clump 的过渡收窄（硬边），
    再叠一层更细的叶团，簇间用暗缝压下去。
    """
    big = fbm(11, 4, seed)
    clump = smoothstep(0.46, 0.60, big)          # 硬边：簇与簇之间有明确分界
    fine = fbm(34, 3, seed + 4)
    leaves = smoothstep(0.52, 0.72, fine)
    gap = 1.0 - smoothstep(0.30, 0.46, big)      # 簇间的暗缝
    h = clump * 0.6 + leaves * 0.25 + gap * 0.15
    alb = 0.52 + clump * 0.38 + leaves * 0.16 - gap * 0.18
    alb *= 0.92 + fine * 0.14
    alb *= height_to_ao(h, 1.0)
    return h, alb, 2.6


def tex_rock(seed=21):
    n = fbm(7, 4, seed)
    crack = smoothstep(0.90, 1.0, 1.0 - np.abs(fbm(10, 3, seed + 3) * 2 - 1))
    grit = fbm(90, 2, seed + 8)
    h = n * 0.9 + grit * 0.10 - crack * 0.45
    alb = 0.68 + n * 0.38 - crack * 0.35 + (grit - 0.5) * 0.10
    alb *= height_to_ao(h, 1.15)
    return h, alb, 3.0


def tex_hay(seed=22):
    yy, xx = grid_uv()
    warp = fbm(6, 2, seed)
    straw = np.sin((xx * 26 + warp * 6) * math.tau) * 0.5 + 0.5
    straw = straw ** 2
    h = straw * 0.72 + fbm(60, 2, seed + 3) * 0.18
    alb = 0.80 + straw * 0.30
    alb *= height_to_ao(h, 1.0)
    return h, alb, 2.2


def tex_ore(seed=23):
    n = fbm(8, 4, seed)
    vein = smoothstep(0.70, 0.90, fbm(13, 3, seed + 6))
    nug = smoothstep(0.80, 0.96, fbm(40, 2, seed + 9))
    h = n * 0.8 + vein * 0.30 + nug * 0.30
    alb = 0.70 + n * 0.30 + vein * 0.32 + nug * 0.34
    alb *= height_to_ao(h, 1.0)
    return h, alb, 2.9


def tex_water(seed=26):
    """水面波纹法线：两组交错正弦 + 噪声扰动。

    纯几何波浪（着色器里的 vertex 正弦）在俯视角下几乎看不出，
    真正让水面"动"的是高频法线起伏产生的碎光。
    """
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S
    warp = fbm(6, 3, seed)
    h = np.zeros((S, S), np.float32)
    for i, (fx, fy, ph) in enumerate(((7.0, 5.0, 0.0), (3.0, 9.0, 1.7), (11.0, 13.0, 3.1))):
        h += np.sin((xx * fx + yy * fy + warp * 1.6 + ph) * math.tau) / (i + 1.5)
    h += (fbm(28, 3, seed + 5) - 0.5) * 0.8
    alb = 0.92 + h * 0.04
    return h, alb, 1.4


def tex_ground_grass(seed=24):
    """地表草皮：草簇 + 土斑 + 小石子（地形按 1.6m 一铺）"""
    blade = fbm2(80, 40, 3, seed)
    clump = smoothstep(0.38, 0.76, fbm(9, 3, seed + 3))
    dirt = smoothstep(0.66, 0.86, fbm(5, 3, seed + 7))
    pebble = smoothstep(0.87, 0.96, fbm(120, 2, seed + 9))
    h = blade * 0.40 + clump * 0.30 - pebble * 0.18
    alb = 0.70 + blade * 0.30 + clump * 0.16 - dirt * 0.14 + pebble * 0.26
    alb *= height_to_ao(h, 1.1)
    return h, alb, 2.1


def tex_ground_dirt(seed=25):
    grit = fbm(110, 2, seed)
    stone = smoothstep(0.82, 0.94, fbm(55, 2, seed + 4))
    rut = 1.0 - np.abs(fbm(4, 3, seed + 8) * 2 - 1)
    h = grit * 0.28 + stone * 0.34 + rut * 0.22
    alb = 0.74 + (grit - 0.5) * 0.22 + stone * 0.26 + rut * 0.12
    alb *= height_to_ao(h, 1.15)
    return h, alb, 2.3


# 归一之后按族再拉开对比（乘在偏离 0.9 的幅度上）。
# 为什么必须分开：金属的细节是"划痕/凹坑"，本身就是低频小幅度的；
# 而归一化会把它压成 ±5%，渲出来就是一块灰塑料。布/皮革/石也一样。
CONTRAST = {
    # 皮革/布的第二版：2.0/1.9 太猛——皮革的颗粒被拉成"锈斑"，布看着像塑料。
    # 现在 metal 2.2 / leather 1.25 / cloth 1.45：近看有细节，远看还是固有色。
    "metal": 2.2, "plaster": 1.4, "cloth": 1.45, "leather": 1.25,
    "ashlar": 1.15, "shingle": 1.1, "plank": 1.35, "bark": 1.15,
    "leaf": 1.2, "rock": 1.1, "hay": 1.15, "ore": 1.4,
    "ground_grass": 1.25, "ground_dirt": 1.3, "water": 1.0, "cobble": 1.1,
}

FAMILIES = {
    "ashlar": tex_ashlar,
    "cobble": tex_cobble,
    "plaster": tex_plaster,
    "shingle": tex_shingle,
    "plank": tex_plank,
    "metal": tex_metal,
    "leather": tex_leather,
    "cloth": tex_cloth,
    "bark": tex_bark,
    "leaf": tex_leaf,
    "rock": tex_rock,
    "hay": tex_hay,
    "ore": tex_ore,
    "ground_grass": tex_ground_grass,
    "ground_dirt": tex_ground_dirt,
    "water": tex_water,
}


# ===========================================================================
# PNG 写出（无第三方库）
# ===========================================================================

def write_png(path, rgb):
    h, w, _ = rgb.shape
    data = np.clip(rgb * 255.0 + 0.5, 0, 255).astype(np.uint8)
    raw = b"".join(b"\x00" + data[y].tobytes() for y in range(h))

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(OUT, exist_ok=True)
    print("[texgen] ->", OUT)
    for name, fn in FAMILIES.items():
        h, alb, nstr = fn()
        alb = np.clip(alb, 0.0, 1.35)
        m = float(alb.mean())
        if m > 1e-4:
            alb = alb * (0.90 / m)
        g = float(CONTRAST.get(name, 1.0))
        alb = 0.90 + (alb - 0.90) * g
        alb = np.clip(alb, 0.22, 1.30)
        rgb = np.stack([alb, alb, alb], -1)
        # 轻微色偏：亮部偏暖、暗部偏冷（手绘贴图的"脏"感，幅度很小，
        # 保证乘到任意调色板基色上都不会把色相带歪）
        shade = np.clip(alb, 0, 1).astype(np.float32)
        rgb[..., 0] *= 0.985 + 0.05 * (1 - shade)
        rgb[..., 2] *= 1.015 - 0.06 * (1 - shade)
        write_png(os.path.join(OUT, name + "_albedo.png"), rgb)
        write_png(os.path.join(OUT, name + "_normal.png"),
                  normal_from_height(h.astype(np.float32), nstr))
        print("  %-14s h[%.2f..%.2f] albedo %.3f±%.3f  normal %.1f"
              % (name, h.min(), h.max(), alb.mean(), alb.std(), nstr))


if __name__ == "__main__":
    main()
