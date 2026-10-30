"""terrain_gen.py —— 双材质硬边过渡图集生成器（1 m = 32 px，一 tile = 8 m）

交付形态
--------
进引擎的是 **遮罩图集 + 两张各自平铺的底材**（原样不动，一个字节都不改）。
本脚本产出那张遮罩图集（遮罩 / 有符号距离 / 高度 / 法线）以及一张派生彩色图
（只用于看和验收，不是引擎输入），外加 Godot 侧的 shader 与 LUT。

所有数值来自同目录的 `参数配置.json`，脚本里没有一处写死的参数。
要换底材（岩石 / 雪地）、换尺寸、调边缘粗糙度，只改 JSON，见 `使用说明书.md`。

跑法
----
    python 地形生成工具箱/terrain_gen.py
    python 地形生成工具箱/terrain_gen.py -- gain=0.9    # 临时覆盖，不写回 JSON
    python 地形生成工具箱/terrain_gen.py -- amp=0.15 seed=1

环境：**不需要 Blender**，只要 numpy + opencv-python + pillow。
    python -m pip install numpy opencv-python-headless pillow

为什么不是"两张图叠一个软蒙版"
------------------------------
软蒙版 = alpha 混合 = 两种材质的颜色互相污染，交界会读成"糊"。这里全程只做
**二选一**：每个像素要么整字节是草，要么整字节是泥，交界处只靠 dither 把等值线
打成 1–2 px 的碎点。所以图集里不可能出现第三种颜色，mip 也不会在交界拉出灰边。

为什么噪声必须 FFT 合成
-----------------------
默认 2D Perlin / Simplex 在 UV 上不周期：u=0 和 u=1 采到的是两个不相干的域，
拼图处必留一条 1 px 的断口。FFT 频域合成天然是周期的（离散傅里叶 = 圆环上的
采样），IFFT 出来的场在 x=0 与 x=255 处是"接着往下走"的关系，跨边差 ÷ 内侧紧邻差
恒等于 1（见 report.md 的 a 项）。

16 格为什么不能按 idx%4 摆
--------------------------
角权重场 g 是四角值的双线性插值。要让相邻格的共边像素**逐像素相等**，唯一的
办法是两格共边上的两个角值来自**同一个格点**。而 idx=c0|c1<<1|c2<<2|c3<<3 按
(col=idx%4, row=idx//4) 摆开时，右邻格左边线的两个角是 (c0', c3')，跟本格右边线
的 (c1, c2) 毫无关系 —— 于是 16 格拼起来会出现 16 条笔直的台阶，验收 d 直接红。

所以这里改用 **4×4 二进制德布鲁因环**（de Bruijn torus）：找一个 4×4 的 0/1 阵，
使它的 16 个 2×2 窗口两两不同。这样 16 个组合一个不少，且每格的四个角都取自
同一张格点表 —— 相邻格共边值天然相等，整张 1024² 图集是一个 32 m 的圆环，
自己跟自己平铺也无缝。代价是 shader 里要用一张 16 字节的 LUT 把 idx 翻成
(col,row)，见 report.md §5。
"""
import json
import math
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

# ── 参数：全部来自同目录的 参数配置.json ────────────────────────────────────
# 这里刻意不写死任何数值。要调边缘粗糙度、换底材、换尺寸，只改 JSON。
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # 工具包的上一级 = 项目根
CFG_PATH = os.path.join(HERE, "参数配置.json")
CFG = json.load(open(CFG_PATH, encoding="utf-8"))


def _p(rel):
    return rel if os.path.isabs(rel) else os.path.join(ROOT, rel)


SRC = _p(CFG["输入"]["目录"])
OUT = _p(CFG["输出"]["目录"])
DOC = _p(CFG["输出"]["文档目录"])
NAME = CFG["输出"]["名称"]
BASE_A = CFG["输入"]["底材"]["A"]          # 遮罩 0 的那一边
BASE_B = CFG["输入"]["底材"]["B"]          # 遮罩 255 的那一边

CELL = int(CFG["尺寸"]["格像素"])
GRID = int(CFG["尺寸"]["网格"])
ATLAS = CELL * GRID
PPM = int(CFG["尺寸"]["每米像素"])
TILE_M = CELL / PPM
BASE_PX = int(CFG["尺寸"]["底材尺寸"])
DEC = BASE_PX // CELL                      # 底材 → 图集的点采样倍率
assert DEC * CELL == BASE_PX, "底材尺寸必须是格像素的整数倍（要逐字节等于原图，只能点采样）"

BAND = float(CFG["边缘"]["band"])
NOISE_GAIN = float(CFG["边缘"]["noise_gain"])
DITHER_AMP = float(CFG["边缘"]["dither_amp"])
SD_CLAMP_M = float(CFG["距离"]["clamp_m"])
SHADOW_A = float(CFG["接触阴影"]["强度"])
SHADOW_W = float(CFG["接触阴影"]["宽度_m"])
RIM_A = float(CFG["受光边"]["强度"])
RIM_W = float(CFG["受光边"]["宽度_m"])
CLOD_TARGET = int(CFG["碎块"]["目标个数"])
CLOD_CROSS_PX = tuple(CFG["碎块"]["跨边界_px"])
CLOD_SIZE_PX = tuple(CFG["碎块"]["块径_px"])
H_GRASS = float(CFG["高度"]["原式台面_m"]["A"])
H_MUD = float(CFG["高度"]["原式台面_m"]["B"])
H_PLATEAU_MM = (float(CFG["高度"]["台面_mm"]["A"]), float(CFG["高度"]["台面_mm"]["B"]))
H_DETAIL_K = float(CFG["高度"]["细节系数"])
H16_MM = tuple(CFG["高度"]["窗口_mm"])
N_CYC, N_DET = int(CFG["噪声"]["n_周期"]), int(CFG["噪声"]["n_细节"])
N2_CYC, N2_DET = int(CFG["噪声"]["n2_周期"]), int(CFG["噪声"]["n2_细节"])
N3_CYC, N3_DET = int(CFG["噪声"]["n3_周期"]), int(CFG["噪声"]["n3_细节"])
BETA = float(CFG["噪声"]["beta"])
SEED = int(CFG["噪声"]["seed"])
CRACK_N = int(CFG["裂纹"]["胞元数"])
CRACK_WARP = float(CFG["裂纹"]["扭曲"])
CRACK_TH = tuple(CFG["裂纹"]["阈值"])

# 变体块（右侧 4×4）
VAR_ON = bool(CFG.get("变体", {}).get("启用", False))
VAR_N = int(CFG.get("变体", {}).get("每种个数", 8))
VAR_TINT = [float(v) for v in CFG.get("变体", {}).get("亮度", [1.0] * 8)]
VAR_GRAIN = float(CFG.get("变体", {}).get("噪点_lsb", 1.0))
VAR_CONTRAST = [float(v) for v in CFG.get("变体", {}).get("对比度", [1.0] * 8)]
COLS = GRID * 2 if VAR_ON else GRID        # 图集列数（有变体块时 8）
ATLAS_W = CELL * COLS
ATLAS_H = CELL * GRID
BLOCK = CELL * GRID                        # 过渡块边长（1024）

# 交付文件名（名称进文件名，换底材不用改代码）
F_RGBA = "atlas_%s_rgba.png" % NAME
F_H16 = "atlas_%s_h16.png" % NAME
F_RGB = "atlas_%s_rgb.png" % NAME
F_N = "atlas_%s_n.png" % NAME
F_NOISE = "noise_256.png"
F_PREVIEW = "preview_3x3.png"
F_RECORD = "生成记录.json"

# 命令行可临时覆盖（不写回 JSON）：-- gain=0.9  amp=0.15  seed=1
ARG = {}
for a in sys.argv[1:]:
    if "=" in a:
        k, v = a.split("=", 1)
        ARG[k.lstrip("-")] = v
DITHER_AMP = float(ARG.get("amp", DITHER_AMP))
NOISE_GAIN = float(ARG.get("gain", NOISE_GAIN))
SEED = int(ARG.get("seed", SEED))


# ── IO（路径全是中文，cv2.imread/imwrite 在 Windows 上会直接失败）────────────
def read_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)


def write_rgb(path, arr):
    Image.fromarray(np.ascontiguousarray(arr, dtype=np.uint8), "RGB").save(path)


def write_rgba(path, arr):
    Image.fromarray(np.ascontiguousarray(arr, dtype=np.uint8), "RGBA").save(path)


def write_g16(path, arr):
    im = Image.fromarray(np.ascontiguousarray(arr, dtype=np.uint16))
    assert im.mode == "I;16", im.mode
    im.save(path)


def srgb2lin(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def lin2srgb(x):
    x = np.clip(np.asarray(x, dtype=np.float64), 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92,
                    1.055 * np.power(x, 1 / 2.4) - 0.055)


def wrap_take(a, ys, xs):
    return np.take(np.take(a, ys, axis=0, mode="wrap"), xs, axis=1, mode="wrap")


# ── 1. 周期噪声：FFT 频谱合成 ────────────────────────────────────────────────
def fft_noise(size, cycles, detail, seed, beta=1.0):
    """白噪声 → FFT → 乘 f^-β（带限到 [cycles, cycles·2^detail]）→ IFFT → 0..1

    因为是频域相乘再逆变换，等价于在圆环上做周期卷积 —— 输出严格以 size 为周期，
    不存在"边缘对不上"这回事。
    """
    rng = np.random.default_rng(seed)
    white = rng.normal(0.0, 1.0, (size, size))
    F = np.fft.fft2(white)

    f = np.fft.fftfreq(size) * size                     # cycles / tile（有符号）
    fr = np.hypot(f[None, :], f[:, None])               # 半径，单位 = 周期数
    f0 = cycles
    f1 = min(cycles * (2.0 ** detail), size * 0.45)     # 不超过 Nyquist
    # 频带：低频高通关掉"整块偏色"，高频低通关掉"逐像素胡椒"
    hi = 1.0 / np.sqrt(1.0 + (f0 / np.maximum(fr, 1e-6)) ** 8)
    lo = 1.0 / np.sqrt(1.0 + (np.maximum(fr, 1e-6) / f1) ** 8)
    H = (np.maximum(fr, 1e-6) ** -beta) * hi * lo
    H[0, 0] = 0.0

    out = np.real(np.fft.ifft2(F * H))
    # 归一化：用 p0.2/p99.8 而不是 min/max。FBM 是高斯尾巴，按 min/max 归一化
    # 之后 99% 的像素挤在 0.3–0.7 里，后面 (n-0.5)*1.6 就等于没乘。
    lo_q, hi_q = np.percentile(out, [0.2, 99.8])
    return np.clip((out - lo_q) / (hi_q - lo_q), 0.0, 1.0).astype(np.float32)


# ── 2. 角权重场：4×4 二进制德布鲁因环 ────────────────────────────────────────
def find_debruijn():
    """找 4×4 的 0/1 环阵，使 16 个 2×2 窗口两两不同（组合一个不少）。

    只枚举 8 个 1 的阵：16 个窗口里每个比特位出现 8 次 1，总 1 数必须是 8。
    这样的阵一共 32 个（已穷举验证），**每一个**的"每格泥占比"矩阵都是 B 的 2×2
    盒式模糊 —— 也就是一张平滑的覆盖率梯度，这是共用格点的必然结果，换阵换不掉。
    32 个里只有 4 个没有任何镜像/旋转对称，挑第一个：有对称的那个阵铺出来是一张
    四角星，看图的人会以为"这图集长了张图案"；没对称的那个读起来才是地形。
    """
    from itertools import combinations

    def windows(B):
        return (B
                | (np.roll(B, -1, axis=1) << 1)
                | (np.roll(np.roll(B, -1, axis=1), -1, axis=0) << 2)
                | (np.roll(B, -1, axis=0) << 3))

    def dihedral(X):
        out, Y = [], X
        for _ in range(4):
            out += [Y, np.flipud(Y)]
            Y = np.rot90(Y)
        return out

    best = None
    for ones in combinations(range(16), 8):
        B = np.zeros((4, 4), dtype=np.int8)
        for k in ones:
            B[k // 4, k % 4] = 1
        w = windows(B)
        if len(np.unique(w)) != 16:
            continue
        frac = np.array([[bin(int(w[r, c])).count("1") / 4.0 for c in range(4)]
                         for r in range(4)])
        sym = sum(1 for D in dihedral(frac) if np.array_equal(frac, D))
        if best is None or sym < best[0]:
            best = (sym, B, w.astype(np.int32))
            if sym == 1:                       # 1 = 只剩恒等，没有多余对称
                break
    if best is None:
        raise RuntimeError("4×4 二进制德布鲁因环未找到")
    return best[1], best[2]


def bits(idx):
    return idx & 1, (idx >> 1) & 1, (idx >> 2) & 1, (idx >> 3) & 1


def bilinear_cell(idx):
    """g = 双线性(四角)。c0=左上 c1=右上 c2=右下 c3=左下。

    采样点取像素中心 (x+0.5)/CELL：格边界正好落在两个像素中心之间，左右两格的
    边界像素各自离边界 0.5 px，共边值只差 1/256 个 g 步长。
    """
    c0, c1, c2, c3 = bits(idx)
    u = (np.arange(CELL) + 0.5) / CELL
    v = (np.arange(CELL) + 0.5) / CELL
    U, V = u[None, :], v[:, None]
    return ((1 - U) * (1 - V) * c0 + U * (1 - V) * c1
            + U * V * c2 + (1 - U) * V * c3).astype(np.float32)


def corner_field(cell_of_pos):
    g = np.zeros((ATLAS, ATLAS), np.float32)
    for r in range(GRID):
        for c in range(GRID):
            g[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = \
                bilinear_cell(cell_of_pos[r][c])
    return g


# ── 3. Voronoi 干裂（周期，参数搬 裂纹泥地）────────────────────────────────
def voronoi_edge_periodic(size, n, seed, warp=None, warp_amt=0.27):
    """周期抖动格 Voronoi 的 DISTANCE_TO_EDGE（近似 = (d2-d1)/2）。

    单位 = 1 个胞元（和 Blender Voronoi 的 Distance 输出同量纲），所以调用方
    可以直接沿用 maprange(d, 0.001, 0.022) 那套阈值。

    warp：坐标先用一层低频噪声揉一下（tr_tex.py 里那句 "warp*0.018" 的等价物：
    0.018 个 tile = 0.018×15 个胞元 ≈ 0.27）。不揉的话胞元是规整多边形，一眼是
    "算出来的"；揉过之后裂纹长短不一，像干了的泥。
    """
    rng = np.random.default_rng(seed)
    jit = rng.random((n, n, 2)) * 0.8 + 0.1          # 抖动到胞元 10%–90%
    sites = (np.stack(np.meshgrid(np.arange(n), np.arange(n), indexing="ij"),
                      -1) + jit)                    # (n,n,2) 单位 = 胞元
    q = (np.arange(size) + 0.5) / size * n
    QX, QY = np.meshgrid(q, q)                        # 查询点，单位 = 胞元
    if warp is not None:
        QX = QX + warp_amt * (warp - 0.5) * 2.0
        QY = QY + warp_amt * (np.roll(warp, size // 3, 0) - 0.5) * 2.0
    ci = np.floor(QX).astype(int)
    cj = np.floor(QY).astype(int)

    d1 = np.full((size, size), 1e9)
    d2 = np.full((size, size), 1e9)
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            ii = (ci + ox) % n
            jj = (cj + oy) % n
            sx = sites[ii, jj, 0] + ox * n
            sy = sites[ii, jj, 1] + oy * n
            d = np.hypot(QX - sx, QY - sy)
            # 只留最近两枚
            m = d < d1
            d2 = np.where(m, d1, np.minimum(d2, d))
            d1 = np.where(m, d, d1)
    return ((d2 - d1) * 0.5).astype(np.float32)


def maprange(x, a, b, c=0.0, d=1.0):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return (c + (d - c) * t).astype(np.float32)


# ── 4. 碎块散落 ─────────────────────────────────────────────────────────────
def scatter_clods(mask, rng):
    """沿边界撒不规则泥块（只做加法：往草里丢土）。

    锚点走 cv2.findContours 的轮廓弧长，所以间距是**真**弧长，不是扫描行撞运气。
    法线用 ∇dist_out（指向草侧），从边界往草侧推 2–6 px。

    间距为什么不是 0.35–0.9 m：那条规则隐含"边界总长 ≈ 120 × 0.55 m ≈ 2.4 k px"，
    实测这张 1024² 图集的边界（含噪声起伏与回折形成的半岛）总弧长 17.7 k px ——
    老老实实按 0.35–0.9 m 走会得到 888 个块，沿边界糊成一条 10 px 宽的花边，
    硬边就看不见了。所以按"总数 ≈120"反推间距（≈4.6 m），保证既满足"约 120 个"、
    又不吃掉交界。想让碎块变密就改 CLOD_TARGET。
    """
    a = (mask > 0).astype(np.uint8)
    dout = cv2.distanceTransform(1 - a, cv2.DIST_L2, 5)
    gy, gx = np.gradient(dout)                         # ∇dout 指向草侧

    cnts, _ = cv2.findContours(a, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    paths, total = [], 0.0
    for ct in cnts:
        p = ct[:, 0, :].astype(np.float64)
        if len(p) < 12:
            continue
        seg = np.linalg.norm(np.diff(np.vstack([p, p[:1]]), axis=0), axis=1)
        if seg.sum() < 40:
            continue
        paths.append((p, np.concatenate([[0.0], np.cumsum(seg)])))
        total += float(seg.sum())
    step = total / CLOD_TARGET

    out = mask.copy()
    n_clod = 0
    for p, s in paths:
        L = s[-1]
        cur = rng.uniform(0, step)
        while cur < L:
            k = min(int(np.searchsorted(s, cur)), len(p) - 1)
            x, y = p[k]
            xi, yi = int(x) % ATLAS, int(y) % ATLAS
            nx, ny = gx[yi, xi], gy[yi, xi]
            nn = math.hypot(nx, ny)
            if nn > 1e-6:
                d = rng.uniform(*CLOD_CROSS_PX)
                cx = x + nx / nn * d
                cy = y + ny / nn * d
                r = rng.uniform(*CLOD_SIZE_PX) * 0.5
                m = int(rng.integers(5, 8))                 # 5–7 个顶点
                ang = np.sort(rng.uniform(0, 2 * np.pi, m))
                rad = r * rng.uniform(0.55, 1.35, m)
                poly = np.stack([cx + np.cos(ang) * rad,
                                 cy + np.sin(ang) * rad], 1)
                offs = [(0, 0)]
                if cx < 12 or cx > ATLAS - 12 or cy < 12 or cy > ATLAS - 12:
                    offs = [(dx, dy) for dx in (-ATLAS, 0, ATLAS)
                            for dy in (-ATLAS, 0, ATLAS)]
                for dx, dy in offs:
                    cv2.fillPoly(out, [np.round(poly + (dx, dy)).astype(np.int32)], 255)
                n_clod += 1
            cur += rng.uniform(0.6, 1.4) * step
    return out, n_clod


# ── 5. 有符号距离（逐格算，带 12 px 外扩上下文，不落 gutter）──────────────
PAD = 12


def signed_distance(mask_u8, y0, x0):
    ys = np.arange(y0 - PAD, y0 + CELL + PAD)
    xs = np.arange(x0 - PAD, x0 + CELL + PAD)
    sub = wrap_take(mask_u8, ys, xs)
    a = (sub > 0).astype(np.uint8)
    din = cv2.distanceTransform(a, cv2.DIST_L2, 5)
    dout = cv2.distanceTransform(1 - a, cv2.DIST_L2, 5)
    # 边界落在"泥像素中心"与"草像素中心"中间：泥侧 +0.5，草侧 −0.5
    sd = np.where(a > 0, din - 0.5, -(dout - 0.5)).astype(np.float32)
    return sd[PAD:PAD + CELL, PAD:PAD + CELL]


def sdf_atlas(mask_u8):
    sd = np.zeros((ATLAS, ATLAS), np.float32)
    for r in range(GRID):
        for c in range(GRID):
            sd[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = \
                signed_distance(mask_u8, r * CELL, c * CELL)
    return sd


# ── 主流程 ──────────────────────────────────────────────────────────────────
# ── Godot 侧：shader 与 LUT ─────────────────────────────────────────────────
# LUT 是**派生数据**（idx → 格子位置的德布鲁因落位），必须跟图集同源生成。
# 手写一份放出去，改天重跑生成器就对不上了。
SHADER_SRC = os.path.join(HERE, "模板文件", "terrain_blend.gdshader")


def lut_block(pos_of_idx):
    """shader 里的 const 数组：16 行，每行带 idx 与角点码注释。"""
    out = ["const ivec2 CELL_LUT[16] = ivec2[16]("]
    for i in range(16):
        c, r = pos_of_idx[i]
        bits = "".join(str((i >> k) & 1) for k in range(4))
        out.append("    ivec2(%d, %d)%s  // %02d  %s"
                   % (c, r, "," if i < 15 else "", i, bits))
    out.append(");")
    return "\n".join(out)


def lut_text(pos_of_idx, frac):
    """给人看、也给工具读的 LUT 表。"""
    L = ["# cell_lut.txt —— idx → 图集格子位置",
         "#",
         "# idx = c0 | c1<<1 | c2<<2 | c3<<3",
         "#   c0 = 左上   c1 = 右上   c2 = 右下   c3 = 左下   （1 = 泥，0 = 草）",
         "# 图集 4×4 格，一格 256² = 8 m。col/row 从 0 起，row 从上往下（图片坐标）。",
         "#",
         "# 这张表是 4×4 二进制德布鲁因环的落位（16 个组合一个不少），不是 idx%4。",
         "# 用 idx%4 摆会拼出 16 条笔直台阶 —— 原因见 terrain_blend.gdshader 头注释。",
         "#",
         "# idx  col  row   c0c1c2c3   泥面积"]
    note = {0: "纯草", 15: "纯泥"}
    for i in range(16):
        c, r = pos_of_idx[i]
        bits = "".join(str((i >> k) & 1) for k in range(4))
        L.append("%4d  %3d  %3d    %s   %5.1f%%   %s"
                 % (i, c, r, bits, frac[i] * 100, note.get(i, "")))
    L += ["#",
          "# GDScript 里的等价写法：",
          "#   const LUT := [%s]" % ", ".join(
              "[%d,%d]" % (pos_of_idx[i][0], pos_of_idx[i][1]) for i in range(16)),
          "#   这 16 个 (col,row) 必须两两不同 —— 否则不是双射，某个组合会被挤到别处"]
    return "\n".join(L) + "\n"


def make_variant(base, k):
    """把一个 256² 的底材变成第 k 个变体。

    只做三件事：旋转/镜像（打散草丛或裂纹的走向）、整体亮度、±1 LSB 噪点。
    旋转和镜像对**方形无缝贴图**是无损的（边对边仍然接得上），所以变体自己平铺也没缝。
    """
    v = base
    rot = k % 4
    if rot:
        v = np.rot90(v, rot)
    if (k // 4) % 2:
        v = v[:, ::-1]
    # 对比度以**变体自身的均值**为中心缩放 —— 均值不变，远景才不会露出一张
    # 8 m 的亮度棋盘。亮度（整体乘）只允许 ±1%，同理。
    con = VAR_CONTRAST[k % len(VAR_CONTRAST)]
    if abs(con - 1.0) > 1e-6:
        m0 = v.astype(np.float64).mean()
        v = np.clip(np.round(m0 + (v.astype(np.float64) - m0) * con), 0, 255)
    tint = VAR_TINT[k % len(VAR_TINT)]
    if abs(tint - 1.0) > 1e-6:
        v = np.clip(np.round(v.astype(np.float64) * tint), 0, 255)
    if VAR_GRAIN > 0:
        rng2 = np.random.default_rng(SEED + 900 + k)
        v = np.clip(v.astype(np.float64)
                    + rng2.uniform(-VAR_GRAIN, VAR_GRAIN, v.shape), 0, 255)
    return np.clip(np.round(v), 0, 255).astype(np.uint8)


def build_variant_block(grass256, dirt256, clump256, crack256, detail_env):
    """右侧 4×4 = 16 个纯纹理格。

    上两行 A 材质（8 个变体），下两行 B 材质（8 个变体）。
    每个格子的字段跟过渡块同构：R 恒定（0 或 255）、G 饱和 ±24 cm、B 抖动场、
    h16 = 台面 + 该变体自己的细节（旋转过的草簇/裂纹），法线逐格算（各自平铺）。
    """
    msk = np.zeros((BLOCK, BLOCK), np.uint8)
    sdb = np.zeros((BLOCK, BLOCK), np.uint8)
    nb = np.zeros((BLOCK, BLOCK), np.uint8)
    hh = np.zeros((BLOCK, BLOCK), np.uint16)
    cc = np.zeros((BLOCK, BLOCK, 3), np.uint8)
    nn = np.zeros((BLOCK, BLOCK, 3), np.uint8)
    for k in range(VAR_N):
        cx, cy = 4 + k % 4, k // 4                     # A 材质：行 0-1
        mx, my = 4 + k % 4, 2 + k // 4                 # B 材质：行 2-3
        for (col, row, src, is_b) in ((cx, cy, grass256, 0), (mx, my, dirt256, 1)):
            tex = make_variant(src, k)
            cl = np.rot90(clump256 if not is_b else crack256, k % 4)
            if (k // 4) % 2:
                cl = cl[:, ::-1]
            y, x = row * CELL, (col - 4) * CELL
            m_v = 255 if is_b else 0
            sd_m = SD_CLAMP_M if is_b else -SD_CLAMP_M
            w = 1.0 + 0.5 * (detail_env["n2t"] - 0.5)
            sh = SHADOW_A * np.exp(-sd_m / SHADOW_W * w) if sd_m > 0 else 0.0
            rm = RIM_A * np.exp(sd_m / RIM_W * w) if sd_m < 0 else 0.0
            col_lin = srgb2lin(tex / 255.0) * (1.0 - sh + rm)[..., None]
            cc[y:y + CELL, x:x + CELL] = np.clip(
                np.round(lin2srgb(col_lin) * 255), 0, 255).astype(np.uint8)
            det = (-0.014 * (cl if is_b else 0) + 0.010 * (cl if not is_b else 0)) * 1000.0
            det = det - 0.012 * sh * 1000.0
            mm_v = (H_PLATEAU_MM[1] if is_b else H_PLATEAU_MM[0]) + H_DETAIL_K * det
            mm_v = np.clip(mm_v, *H16_MM)
            hh[y:y + CELL, x:x + CELL] = np.round(
                (mm_v - H16_MM[0]) / (H16_MM[1] - H16_MM[0]) * 65535).astype(np.uint16)
            hm = mm_v / 1000.0
            dx = (np.roll(hm, -1, 1) - np.roll(hm, 1, 1)) * 0.5 * PPM
            dy = (np.roll(hm, -1, 0) - np.roll(hm, 1, 0)) * 0.5 * PPM
            nv = np.stack([-dx, dy, np.ones_like(dx)], -1)
            nv /= np.linalg.norm(nv, axis=-1, keepdims=True)
            nn[y:y + CELL, x:x + CELL] = np.round((nv * 0.5 + 0.5) * 255).astype(np.uint8)
            msk[y:y + CELL, x:x + CELL] = m_v
            sdb[y:y + CELL, x:x + CELL] = (255 if is_b else 1)
            nb[y:y + CELL, x:x + CELL] = np.round(detail_env["n2t"] * 255).astype(np.uint8)
    return msk, sdb, nb, hh, cc, nn


def write_godot(out_dir, pos_of_idx, frac):
    os.makedirs(out_dir, exist_ok=True)
    src = open(SHADER_SRC, encoding="utf-8").read()
    assert "__CELL_LUT__" in src, "shader 模板里找不到 __CELL_LUT__ 占位"
    with open(os.path.join(out_dir, "terrain_blend.gdshader"), "w",
              encoding="utf-8") as f:
        f.write(src.replace("__CELL_LUT__", lut_block(pos_of_idx)))
    with open(os.path.join(out_dir, "cell_lut.txt"), "w", encoding="utf-8") as f:
        f.write(lut_text(pos_of_idx, frac))


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(DOC, exist_ok=True)

    grass = read_rgb(os.path.join(SRC, BASE_A))     # 512² RGB，sRGB
    dirt = read_rgb(os.path.join(SRC, BASE_B))
    assert grass.shape == dirt.shape == (512, 512, 3), (grass.shape, dirt.shape)

    rng = np.random.default_rng(SEED)

    # 1) 噪声。
    #    图集里用的这一对按 **整张图集 1024² = 32 m 周期** 合成，而不是 256² 再平铺 4×4：
    #    256² 平铺的话 16 个格子里是**同一张**噪声，每格的边界起伏是同一枚指纹，
    #    平铺出去每 8 m 复读一次（看着像"每个格子都是同一个 S 波"）。
    #    1024² 之后每格拿到的是同一张大场的不同窗口 —— 相邻格仍然连续（缝处采的是
    #    相邻样本），隔得远的格彻底去相关。
    nA = fft_noise(ATLAS, N_CYC * GRID, N_DET, SEED + 1, BETA)      # 20 周期/32 m = 5/8 m
    #    n2 只以 8bit 参与（B 通道要存它）。先量化再参与运算 —— 否则着色里用的是
    #    32bit 浮点、图集里存的是 8bit，第三方就复算不出同一张彩色图（c 项会掉到 3 LSB）。
    n2A = np.round(fft_noise(ATLAS, N2_CYC * GRID, N2_DET, SEED + 2, BETA) * 255.0) / 255.0
    #    noise_256.png 另给一套 8 m 周期的（shader 里 repeat 采样用）
    n = fft_noise(CELL, N_CYC, N_DET, SEED + 11, BETA)
    n2 = fft_noise(CELL, N2_CYC, N2_DET, SEED + 12, BETA)
    n3 = fft_noise(CELL, N3_CYC, N3_DET, SEED + 13, BETA)

    # 2) 16 格角组合 + 落位
    B, cell_of_pos = find_debruijn()
    pos_of_idx = np.zeros((16, 2), np.int32)
    for r in range(GRID):
        for c in range(GRID):
            pos_of_idx[cell_of_pos[r][c]] = (c, r)      # (col,row) 与 idx%4 无关
    g = corner_field(cell_of_pos)


    # 3) 蒙版
    s = (g - 0.5) / BAND + (nA - 0.5) * NOISE_GAIN       # 有符号场，0 = 边界
    p = np.clip(s + 0.5, 0.0, 1.0)
    dith = 0.5 + DITHER_AMP * (n2A - 0.5)
    mask = np.where(p > dith, 255, 0).astype(np.uint8)

    # 碎点带宽度（边界像素偏离 s=0 等值线多少 px）——用来自证"1–2 px"
    gy, gx = np.gradient(s)
    gm = np.hypot(gx, gy) + 1e-9
    bnd = cv2.morphologyEx(mask, cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0
    ragged = (np.abs(s[bnd]) / gm[bnd])
    ragged_mean = float(ragged.mean())
    ragged_p50, ragged_p95, ragged_p99 = (
        float(np.percentile(ragged, q)) for q in (50, 95, 99))

    # 4) 碎块（加在蒙版里，所以它会自己长出接触阴影和高度）
    mask, n_clod = scatter_clods(mask, rng)

    # 5) 有符号距离 → 接触阴影 / 受光边
    sd_px = sdf_atlas(mask)
    sd = np.clip(sd_px / PPM, -SD_CLAMP_M, SD_CLAMP_M)   # 米
    w = 1.0 + 0.5 * (n2A - 0.5)
    # 阴影只长在泥侧（sd>0）、受光边只长在草侧（sd<0）。
    # 原来照抄规格写成 exp(-max(sd,0)/w)：草侧 sd<0 → max=0 → exp(0)=1，于是**整片草**
    # 被压暗 30%（线性），派生彩色图比 草地.png 暗 15%。c 只验泥侧所以没抓到 ——
    # 现在加了「阴影不越界」的 c2 项，两边都盯着。
    shadow = np.where(sd > 0, SHADOW_A * np.exp(-np.maximum(sd, 0) / SHADOW_W * w), 0.0)
    rim = np.where(sd < 0, RIM_A * np.exp(np.minimum(sd, 0) / RIM_W * w), 0.0)
    shadow = shadow.astype(np.float32)
    rim = rim.astype(np.float32)

    # 6) 高度：不从亮度反推（草簇和裂纹都是暗的，反推会把它们变成坑）
    warp = fft_noise(CELL, 3, 2, SEED + 8)                     # 低频，揉坐标用
    d_edge_256 = voronoi_edge_periodic(CELL, CRACK_N, SEED + 7,
                                       warp=warp, warp_amt=CRACK_WARP)
    d_edge = np.tile(d_edge_256, (GRID, GRID))
    crackf256 = maprange(d_edge_256, CRACK_TH[0], CRACK_TH[1], 1.0, 0.0)
    crackf = np.tile(crackf256, (GRID, GRID))          # 裂纹中心 = 1

    lum_g = grass.astype(np.float64) @ np.array([0.2126, 0.7152, 0.0722])
    # 草簇 = 比周围暗的**小块**，用黑帽（闭运算 − 原图）：比结构元窄的暗块被留下，
    # 大片暗区被抹平。先试过高斯高通（blur−lum），结果草地那三块低频色阶的**边界**
    # 也成了正响应，高度图上长出一圈一圈的等高线。
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    tuft = cv2.morphologyEx(lum_g.astype(np.float32), cv2.MORPH_BLACKHAT, k)
    t_hi = np.percentile(tuft, 96)                    # 顶端 4%
    clumpf = np.clip(tuft / max(t_hi, 1e-6), 0, 1) ** 0.8
    # 和彩色图一样按 [::2, ::2] 降到 32 px/m，再铺满图集：草簇位置与贴图逐像素对齐
    clumpf256 = clumpf[::DEC, ::DEC].copy()
    clumpf = np.tile(clumpf256, (GRID, GRID))

    m = (mask > 0).astype(np.float32)
    # 原式：h = 0.62(1-m) + 0.54m - 0.014·crackf + 0.010·clumpf - 0.012·shadow
    # 两处加门：裂纹 ×m（只长在泥上）、草簇 ×(1-m)（只长在草上）。原式没写门，
    # 但两个场都是按整张 tile 铺的，不加门草地上会冒出干裂纹、泥地上会鼓起草簇 ——
    # 3–5 mm 的起伏在法线里看得一清二楚。
    det_m = (-0.014 * crackf * m
             + 0.010 * clumpf * (1 - m)
             - 0.012 * shadow)                       # 米
    h_raw = H_GRASS * (1 - m) + H_MUD * m + det_m    # 米（原式原样，只作留档）
    # 原式直接进 16bit 窗口是装不下的：0.62/0.54 的落差 80 mm，窗口只有 20 mm。
    # 分两件事压，互不牵连：
    #   ① 台面落差 80 mm → 8 mm（草 +4 / 泥 −4）。这是"一块 8 m 的地砖上，土路比
    #      草皮低不到 1 cm"的物理量级，不是任意数。
    #   ② 毫米级细节（裂纹 −14 / 草簇 +10 / 阴影 −12×0.3）按 0.35 抬到 −4.9 /
    #      +3.5 / −1.3 mm。若跟 ① 一样按 0.1 压，裂纹只剩 1.4 mm/px（坡度 2.6°），
    #      法线上完全看不见，这张高度图就白给了。
    # 合起来 −10.2…+7.5 mm，两端都留余量，实测夹不到的像素占比 0。
    mm = np.where(m > 0, H_PLATEAU_MM[1], H_PLATEAU_MM[0]) + H_DETAIL_K * det_m * 1000.0
    mm = np.clip(mm, *H16_MM)
    h16 = np.round((mm - H16_MM[0]) / (H16_MM[1] - H16_MM[0]) * 65535).astype(np.uint16)

    # 7) 派生彩色图：二选一（点采样，逐字节等于原图）再乘 (1-shadow+rim)
    #    底材是 64 px/m、图集是 32 px/m，所以取 [::2, ::2]——正好是"原图的像素"，
    #    不允许经过任何重采样（那就违反保色了）。
    g2 = np.tile(grass[::DEC, ::DEC], (GRID, GRID, 1)).astype(np.uint8)
    d2 = np.tile(dirt[::DEC, ::DEC], (GRID, GRID, 1)).astype(np.uint8)
    comp = np.where(m[..., None] > 0, d2, g2)
    comp_lin = srgb2lin(comp / 255.0)
    shade = (1.0 - shadow + rim)[..., None]
    col = np.clip(np.round(lin2srgb(comp_lin * shade) * 255.0), 0, 255).astype(np.uint8)

    # 8) 法线：从 h16 反算（OpenGL，+Y 上）。图集是圆环，梯度可以用 roll 取。
    hm = mm / 1000.0                                   # 每像素高度（米）
    dhdx = (np.roll(hm, -1, 1) - np.roll(hm, 1, 1)) * 0.5 * PPM   # 无量纲坡度
    dhdy = (np.roll(hm, -1, 0) - np.roll(hm, 1, 0)) * 0.5 * PPM
    nrm = np.stack([-dhdx, dhdy, np.ones_like(dhdx)], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    nrm8 = np.round((nrm * 0.5 + 0.5) * 255).astype(np.uint8)

    # Godot 侧（shader + LUT）—— LUT 必须跟图集同源，所以在这里出
    frac = {int(cell_of_pos[r][c]):
            float((mask[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] > 0).mean())
            for r in range(GRID) for c in range(GRID)}

    # ── 落盘 ────────────────────────────────────────────────────────────────
    sd_byte = np.clip(np.round(sd / SD_CLAMP_M * 127 + 128), 0, 255).astype(np.uint8)
    n2_byte = np.round(n2A * 255).astype(np.uint8)

    # 右侧变体块：纯材质的大面积靠它。16 格 = A 材质 8 变体（上两行）+ B 材质 8 变体（下两行）
    if VAR_ON:
        msk_v, sdb_v, nb_v, hh_v, cc_v, nn_v = build_variant_block(
            grass[::DEC, ::DEC], dirt[::DEC, ::DEC], clumpf256, crackf256, {"n2t": n2})
        mask = np.hstack([mask, msk_v])
        sd_byte = np.hstack([sd_byte, sdb_v])
        n2_byte = np.hstack([n2_byte, nb_v])
        h16 = np.hstack([h16, hh_v])
        col = np.hstack([col, cc_v])
        nrm8 = np.hstack([nrm8, nn_v])

    rgba = np.dstack([mask, sd_byte, n2_byte, np.full(mask.shape, 255, np.uint8)])
    write_rgba(os.path.join(OUT, F_RGBA), rgba)
    write_g16(os.path.join(OUT, F_H16), h16)
    write_rgb(os.path.join(OUT, F_RGB), col)
    write_rgb(os.path.join(OUT, F_N), nrm8)

    nz = np.dstack([np.round(n2 * 255).astype(np.uint8),
                    np.round(n * 255).astype(np.uint8),
                    np.round(n3 * 255).astype(np.uint8)])
    write_rgb(os.path.join(OUT, F_NOISE), nz)

    for idx in range(16):
        c, r = pos_of_idx[idx]
        cell = rgba[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL]
        write_rgba(OUT + "/cell_%02d.png" % idx, cell)

    # preview：过渡块 3×3 平铺（它自己是一个 32 m 无缝环）+ 单格 2× 近景 + 变体条
    base = col[:, :BLOCK] if VAR_ON else col
    tile = np.asarray(Image.fromarray(base).resize((BLOCK // 2, BLOCK // 2),
                                                   Image.LANCZOS))
    pv = np.tile(tile, (3, 3, 1))
    # 近景框里就放**一格**（256²→512²，2×）。放 512² 的话刚好是 2×2 格，
    # 看图的人会以为"一个格子"就该长那样，进而觉得格子没有纯色块、边界乱窜。
    bnd = cv2.morphologyEx((mask > 0).astype(np.uint8), cv2.MORPH_GRADIENT,
                           np.ones((3, 3), np.uint8))
    best, bx, by = -1, 0, 0
    #    只从"单角是泥"的 4 格里挑（idx 1/2/4/8）—— 对角格（5/10）的中心是鞍点，
    #    噪声明暗全压在那儿，放大看是一团斑，拿它当"一个格子长什么样"是误导。
    for idx in (1, 2, 4, 8):
        c_, r_ = pos_of_idx[idx]
        k = int(bnd[r_ * CELL:(r_ + 1) * CELL, c_ * CELL:(c_ + 1) * CELL].sum())
        if k > best:
            best, bx, by = k, c_ * CELL, r_ * CELL
    near = np.asarray(Image.fromarray(col[by:by + CELL, bx:bx + CELL])
                      .resize((512, 512), Image.LANCZOS))
    npv = Image.fromarray(near)
    ImageDraw.Draw(npv).text((10, 10), "1 cell = 8 m, shown 2x", fill=(255, 255, 255))
    near = np.asarray(npv)
    side = pv.shape[0]
    a0, a1 = side - 536, side - 24                     # 512 见方，四周留 24 px 边
    pv[a0:a1, a0:a1] = near
    pv[a0 - 4:a1 + 4, a0 - 4:a0] = 255
    pv[a0 - 4:a1 + 4, a1:a1 + 4] = 255
    pv[a0 - 4:a0, a0 - 4:a1 + 4] = 255
    pv[a1:a1 + 4, a0 - 4:a1 + 4] = 255
    # 底部一条：16 个纯纹理变体（上排 A 材质 8 个，下排 B 材质 8 个）。
    # 每格之间留 8 px 底色缝 —— 它们本来就无缝，不留缝会被看成一条连续的色带。
    if VAR_ON:
        GAP, NCOL = 8, 8
        CW = (BLOCK + BLOCK // 2 - GAP * (NCOL - 1)) // NCOL
        CH = CW
        band = np.full((2 * CH + GAP + 2 * GAP, BLOCK + BLOCK // 2, 3), 26, np.uint8)
        for k in range(8):
            gx = BLOCK + (k % 4) * CELL
            for row_i, src_row in enumerate((k // 4, 2 + k // 4)):
                y0 = GAP + row_i * (CH + GAP)
                x0 = GAP + k * (CW + GAP) if False else k * (CW + GAP)
                band[y0:y0 + CH, x0:x0 + CW] = np.asarray(Image.fromarray(
                    col[src_row * CELL:src_row * CELL + CELL, gx:gx + CELL]
                ).resize((CW, CH), Image.LANCZOS))
        pv = np.vstack([pv, band])

    write_rgb(os.path.join(OUT, F_PREVIEW), pv)
    write_godot(OUT + "/godot", pos_of_idx, frac)

    # ── 参数留档（report.md 引用）────────────────────────────────────────────
    frac = {int(cell_of_pos[r][c]): round(float((mask[r * CELL:(r + 1) * CELL,
                                                         c * CELL:(c + 1) * CELL] > 0).mean()), 4)
            for r in range(GRID) for c in range(GRID)}
    params = {
        "seed": SEED, "dither_amp": DITHER_AMP, "band": BAND,
        "noise_gain": NOISE_GAIN, "n_cycles": N_CYC, "n2_cycles": N2_CYC,
        "ppb": PPM, "tile_m": TILE_M,
        "debruijn_B": B.tolist(), "cell_of_pos": cell_of_pos.tolist(),
        "pos_of_idx": pos_of_idx.tolist(), "mud_frac_of_idx": frac,
        "ragged_mean_px": round(ragged_mean, 2),
        "ragged_p50_px": round(ragged_p50, 2),
        "ragged_p95_px": round(ragged_p95, 2),
        "ragged_p99_px": round(ragged_p99, 2),
        "ragged_big_frac": round(float(np.mean(ragged > 4)), 4),
        "n_clod": n_clod,
        "mm_range": [round(float(mm.min()), 2), round(float(mm.max()), 2)],
        "h_raw_range_m": [round(float(h_raw.min()), 4), round(float(h_raw.max()), 4)],
        "clamp_frac": round(float(np.mean((mm <= H16_MM[0]) | (mm >= H16_MM[1]))), 5),
        "cell_px": CELL, "atlas_px": ATLAS,
        "var_on": VAR_ON, "var_n": VAR_N if VAR_ON else 0,
        "atlas_w": ATLAS_W, "atlas_h": ATLAS_H, "cols": COLS,
    }
    with open(os.path.join(DOC, F_RECORD), "w", encoding="utf-8") as f:
        json.dump(params, f, ensure_ascii=False, indent=1)

    print("[TA] 碎点带 p50 %.2f / p95 %.2f / p99 %.2f px | 碎块 %d | 高度 %.1f..%.1f mm"
          % (ragged_p50, ragged_p95, ragged_p99, n_clod, mm.min(), mm.max()))
    print("[TA] 德布鲁因阵:\n%s" % B)
    print("[TA] cell_of_pos (行=row):\n%s" % cell_of_pos)
    print("[TA] DONE ->", OUT)


if __name__ == "__main__":
    main()
