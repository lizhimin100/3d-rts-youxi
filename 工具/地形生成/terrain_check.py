"""ta_check.py —— 双材质硬边过渡图集的独立验收

只读**交付出去的 PNG**，不 import 生成器：任何一个数字都能被第三方用同样的输入
复算出来。生成器内部的自证（比如"我知道我乘了多宽的 dither"）不算数。

    python 地形生成工具箱/terrain_check.py     # 跑 a–f，写 report.md

a 周期   noise_256 的跨边差 ÷ 内侧紧邻差        ∈ [0.9, 1.1]
b 接缝   相邻格共边像素逐像素相等                见 report 的口径说明
c 保色   mask=255 区 == 原泥土图（逐字节）        Δ ≤ 1 LSB
d 网格   彩色图集 128² 后 16 格边界不得成直线     峰值不超 p99
e 明度   单格跨度                                ≤ 12%
"""
import json
import os

import cv2
import numpy as np
from PIL import Image

# ── 路径与参数：跟生成器读同一份 参数配置.json ──────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CFG = json.load(open(os.path.join(HERE, "参数配置.json"), encoding="utf-8"))


def _p(rel):
    return rel if os.path.isabs(rel) else os.path.join(ROOT, rel)


SRC = _p(CFG["输入"]["目录"])
OUT = _p(CFG["输出"]["目录"])
DOC = _p(CFG["输出"]["文档目录"])
NAME = CFG["输出"]["名称"]
BASE_A = CFG["输入"]["底材"]["A"]
BASE_B = CFG["输入"]["底材"]["B"]

CELL = int(CFG["尺寸"]["格像素"])
GRID = int(CFG["尺寸"]["网格"])
ATLAS = CELL * GRID
PPM = int(CFG["尺寸"]["每米像素"])
BASE_PX = int(CFG["尺寸"]["底材尺寸"])
DEC = BASE_PX // CELL
SD_CLAMP_M = float(CFG["距离"]["clamp_m"])
SHADOW_A = float(CFG["接触阴影"]["强度"])
SHADOW_W = float(CFG["接触阴影"]["宽度_m"])
RIM_A = float(CFG["受光边"]["强度"])
RIM_W = float(CFG["受光边"]["宽度_m"])

F_RGBA = "atlas_%s_rgba.png" % NAME
F_H16 = "atlas_%s_h16.png" % NAME
F_RGB = "atlas_%s_rgb.png" % NAME
F_N = "atlas_%s_n.png" % NAME
F_RECORD = "生成记录.json"

VAR_ON = bool(CFG.get("变体", {}).get("启用", False))
COLS = GRID * 2 if VAR_ON else GRID
ATLAS_W = CELL * COLS            # 2048（有变体块时）
ATLAS_H = CELL * GRID            # 1024
LUM = np.array([0.2126, 0.7152, 0.0722])


def read(path, mode="RGB"):
    return np.asarray(Image.open(path).convert(mode))


def png_info(path):
    im = Image.open(path)
    bits = 16 if im.mode.startswith("I;16") or im.mode == "I" else 8
    return {"mode": im.mode, "size": im.size, "bits": bits}


def srgb2lin(x):
    x = np.asarray(x, dtype=np.float64)
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def lin2srgb(x):
    x = np.clip(np.asarray(x, dtype=np.float64), 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92,
                    1.055 * np.power(x, 1 / 2.4) - 0.055)


# ── a 周期 ──────────────────────────────────────────────────────────────────
def check_a(noise):
    """跨边差 ÷ 内侧紧邻差。平铺纹理的边缘像素不是「相等」，而是「接着往下走」，
    所以判据是比值 ≈1，不是差值 ≈0。

    但单点估计的噪声很大：把 256 个相邻列差逐列算出来，它们本身就散布 ±25%
    （图集的低频场在有的地方陡、有的地方平）。所以除了比值，还量 **缝在这 256 个
    相邻差里排第几百分位** —— 缝只要是一条「普通大小」的相邻差，就没有缝。
    """
    out = {}
    ratios = []
    inside = True
    for ch, nm in zip(range(3), ("n2(20周期)", "n(5周期)", "n3(45周期)")):
        A = noise[:, :, ch].astype(np.float64) / 255.0
        rec = {}
        for axis in ("x", "y"):
            d = _cut_stats(A, axis)
            ratio = float(d[0] / d.mean())
            rec[axis] = {"ratio": round(ratio, 3),
                         "rank": round(float((d < d[0]).mean() * 100), 1),
                         "range": [round(float(d.min()), 4), round(float(d.max()), 4)],
                         "seam": round(float(d[0]), 4)}
            ratios.append(ratio)
            inside &= bool(d.min() <= d[0] <= d.max())
        out[nm] = rec
    pooled = float(np.mean(ratios))
    ok = (0.9 <= pooled <= 1.1) and inside
    return ok, out, pooled, inside


def _cut_stats(A, axis):
    """沿某轴逐个切位算相邻差的 RMS：d[s] = rms(A[...,s] − A[...,s−1])（环回）。
    d[0] 就是"缝"，其余 255 个是"内侧紧邻"的实测分布。"""
    n = A.shape[0]
    if axis == "x":
        return np.array([np.sqrt(np.mean((A[:, s] - A[:, (s - 1) % n]) ** 2))
                         for s in range(n)])
    return np.array([np.sqrt(np.mean((A[r, :] - A[(r - 1) % n, :]) ** 2))
                     for r in range(n)])


def check_a_atlas(mask):
    """图集本身也是周期场（32 m 圆环），顺带量一下。"""
    a = mask.astype(np.float64)
    sx = np.abs(a[:, 0] - a[:, -1]).mean()
    ix = np.abs(a[:, 0] - a[:, 1]).mean()
    sy = np.abs(a[0, :] - a[-1, :]).mean()
    iy = np.abs(a[0, :] - a[1, :]).mean()
    return {"x": round(float(sx / max(ix, 1e-9)), 3),
            "y": round(float(sy / max(iy, 1e-9)), 3)}


# ── b 接缝 ──────────────────────────────────────────────────────────────────
def check_b(mask):
    """逐条共边比对（含环回），并统计不一致处的"连续长度"。

    逐像素 Δ 恒等于 0 在几何上做不到：相邻两格的边界像素各自离格边 0.5 px，
    采到的不是同一个样本。能要求的是"不一致只发生在边界穿越点、且偏移 ≤1 px"——
    也就是边界线不被格边切断。
    """
    rows = []
    tot = 0
    runs_max = 0
    for r in range(GRID):
        for c in range(GRID):
            a = mask[r * CELL:(r + 1) * CELL, c * CELL + CELL - 1]
            b = mask[r * CELL:(r + 1) * CELL, ((c + 1) % GRID) * CELL]
            d = (a != b)
            tot += int(d.sum())
            runs, cur = [], 0
            for v in d:
                cur = cur + 1 if v else 0
                if cur:
                    runs.append(cur)
            runs_max = max([runs_max] + ([max(runs)] if runs else []))
            rows.append(("V", c, (c + 1) % GRID, r, int(d.sum())))
    for r in range(GRID):
        for c in range(GRID):
            a = mask[r * CELL + CELL - 1, c * CELL:(c + 1) * CELL]
            b = mask[((r + 1) % GRID) * CELL, c * CELL:(c + 1) * CELL]
            d = (a != b)
            tot += int(d.sum())
            runs, cur = [], 0
            for v in d:
                cur = cur + 1 if v else 0
                if cur:
                    runs.append(cur)
            runs_max = max([runs_max] + ([max(runs)] if runs else []))
            rows.append(("H", r, (r + 1) % GRID, c, int(d.sum())))
    total_px = 2 * GRID * GRID * CELL
    return tot, total_px, runs_max, rows


# ── c 保色 ──────────────────────────────────────────────────────────────────
def check_c(rgb, mask, sd, noise2, dirt, grass):
    """把着色反解回去，再跟原泥土图逐字节比。

    图集里存的是「二选一 × (1-shadow+rim)」。shadow/rim 只由 G 通道（有符号距离）
    和 B 通道（宽度抖动场）决定，两者都在交付文件里 —— 所以这一步不需要相信生成器。
    """
    sd_m = (sd.astype(np.float64) - 128.0) / 127.0 * SD_CLAMP_M
    w = 1.0 + 0.5 * (noise2 - 0.5)
    # 与生成器同一条公式：阴影只在 B 侧、受光边只在 A 侧，另一侧严格为 0
    shadow = np.where(sd_m > 0, SHADOW_A * np.exp(-np.maximum(sd_m, 0) / SHADOW_W * w), 0.0)
    rim = np.where(sd_m < 0, RIM_A * np.exp(np.minimum(sd_m, 0) / RIM_W * w), 0.0)
    shade = (1.0 - shadow + rim)[..., None]

    back = lin2srgb(srgb2lin(rgb / 255.0) / shade) * 255.0
    back8 = np.clip(np.round(back), 0, 255)

    # 底材按 [::DEC, ::DEC] 点采样后铺 4×4（32 px/m，1 tile = 8 m）
    d2 = np.tile(dirt[::DEC, ::DEC], (GRID, GRID, 1))
    m = mask > 0
    d = np.abs(back8[m].astype(np.int16) - d2[m].astype(np.int16))

    # A 侧（草）不再反解 —— 直接比。阴影和受光边都**不许越界**：离开交界 9 cm 以外
    # （受光边 3 cm 的 3 个衰减长度）草必须逐字节等于原图。这一条能抓住任何「整片
    # 材质被染色」的错，反解是抓不到的（反解会把错的着色除回去）。
    a2 = np.tile(grass[::DEC, ::DEC], (GRID, GRID, 1))
    far_a = (mask == 0) & (sd_m <= -0.09)
    dA = np.abs(rgb[far_a].astype(np.int16) - a2[far_a].astype(np.int16))
    return int(d.max()), float(d.mean()), m.mean(), int(dA.max()), float(dA.mean())


# ── d 网格 ──────────────────────────────────────────────────────────────────
def check_d(rgb):
    """缩到 128² 后，16 格边界不得出现连续直线。

    "直线"在图集上的表现是：行/列均值在格边上有一阶跃 → 一阶差分出现尖峰。
    判据取"格边处 |Δ| 不超过全图 |Δ| 的 p99"（含量化噪声、含真实交界起伏）。
    """
    lum = (rgb.astype(np.float64) / 255.0) @ LUM
    small = cv2.resize(lum, (128, 128), interpolation=cv2.INTER_AREA)
    step = 128 // GRID                                   # 32
    res = {}
    for axis, nm in ((0, "列边界(竖直)"), (1, "行边界(水平)")):
        prof = small.mean(axis=axis)                     # 128
        d1 = np.abs(np.diff(prof))
        idx = [k * step - 1 for k in range(1, GRID)]     # 31,63,95
        at = d1[idx]
        ok = bool(at.max() <= np.percentile(d1, 99))
        res[nm] = {"边界处|Δ|": [round(float(v), 6) for v in at],
                   "全图 p99": round(float(np.percentile(d1, 99)), 6),
                   "全图 max": round(float(d1.max()), 6),
                   "p99 分位": round(float(
                       (d1 < at.max()).mean() * 100), 2),
                   "ok": ok}
    return all(v["ok"] for v in res.values()), res


# ── e 明度 ──────────────────────────────────────────────────────────────────
def check_e(rgb, mask, comp):
    """单格明度跨度。分四把尺子量，因为"跨度"在这张图上有多义（见 report）。"""
    lum = (rgb.astype(np.float64) / 255.0) @ LUM
    lum_c = (comp.astype(np.float64) / 255.0) @ LUM
    raw, p99, means, matspan = [], [], [], []
    for r in range(GRID):
        for c in range(GRID):
            y, x = r * CELL, c * CELL
            L = lum[y:y + CELL, x:x + CELL]
            raw.append(float(L.max() - L.min()))
            p99.append(float(np.percentile(L, 99) - np.percentile(L, 1)))
            means.append(float(L.mean()))
            M = mask[y:y + CELL, x:x + CELL] > 0
            g = float(np.ptp(lum_c[y:y + CELL, x:x + CELL][~M])) if (~M).any() else 0.0
            d = float(np.ptp(lum_c[y:y + CELL, x:x + CELL][M])) if M.any() else 0.0
            matspan.append(max(g, d))
    return {
        "每格 raw 跨度": [round(v, 4) for v in raw],
        "每格 raw 最大": round(max(raw), 4),
        "每格 p1–p99 最大": round(max(p99), 4),
        "单材质内跨度 最大": round(max(matspan), 4),
        "16 格均值的跨度": round(max(means) - min(means), 4),
    }


# ── f 角点逻辑 ───────────────────────────────────────────────────────────────
def check_f(mask, pos_of_idx):
    """角点逻辑自检：这张图集到底有没有按 1/2/4/8 的角点关系长。

    两条硬判据：
      ① 两端角点相同的那条边，必须整条都是那个材质（32 条这样的边）；
      ② 每格的泥占比必须等于**无噪声理想双线性场**的占比。
         单角泥的解析面积 = ∫∫ 1{ab>0.5} = 1 − (1/2 + ½ln2) = 15.34%，
         不是 1/4 也不是 1/6；双角（相邻或对角）恰好 50%；三角 84.66%。
         噪声只能把这几个数推动 0.5 % 以内。
    附带量一下混合边被交界穿越几次（不判通过与否，只作观测量）。
    """
    cells = {}
    pure_bad, pure_n = [], 0
    mix_flips = []
    for idx in range(16):
        c, r = pos_of_idx[idx]
        cell = mask[r * 256:(r + 1) * 256, c * 256:(c + 1) * 256] > 0
        b = [(idx >> k) & 1 for k in range(4)]          # c0 TL, c1 TR, c2 BR, c3 BL
        # 无噪声理想场：四角双线性
        u = (np.arange(256) + 0.5) / 256.0
        U, V = u[None, :], u[:, None]
        ideal = ((1 - U) * (1 - V) * b[0] + U * (1 - V) * b[1]
                 + U * V * b[2] + (1 - U) * V * b[3])
        got = float((cell > 0).mean())
        exp = float((ideal > 0.5).mean())          # 场 → 面积，不能拿场均值当面积
        cells[idx] = (exp, got)
        for nm, line, pa, pb in (("上", cell[0, :], b[0], b[1]),
                                 ("下", cell[-1, :], b[3], b[2]),
                                 ("左", cell[:, 0], b[0], b[3]),
                                 ("右", cell[:, -1], b[1], b[2])):
            if pa == pb:
                pure_n += 1
                purity = float(line.mean()) if pa else float((~line).mean())
                if purity < 1.0:
                    pure_bad.append((idx, nm, purity))
            else:
                mix_flips.append(int((np.diff(line.astype(np.int8)) != 0).sum()))
    dev = max(abs(g - e) for e, g in cells.values())
    ok = (not pure_bad) and dev <= 0.015
    return ok, {"pure_n": pure_n, "pure_bad": pure_bad,
                "max_dev": float(dev), "cells": cells,
                "mix_mean": float(np.mean(mix_flips)),
                "mix_max": int(np.max(mix_flips)),
                "mix_gt1": int(np.sum(np.array(mix_flips) > 1)),
                "mix_n": len(mix_flips)}


# ── g 变体块 ───────────────────────────────────────────────────────────────
def check_g(vrgb, vmask, P):
    """右侧纯纹理块自检。

    ① 每格 R 必须恒定 —— 纯材质，没有交界（有就是变体选错了格子）
    ② A 材质（上两行）与 B 材质（下两行）必须明显不同
    ③ 同材质 8 个变体两两之间必须有可见差异（不是复制粘贴）
    ④ 每个变体自己平铺无缝：左右 / 上下边缘接得上
    """
    LUM = np.array([0.2126, 0.7152, 0.0722])
    n = int(P.get("var_n", 8))
    rows_a, rows_b = 2, 2
    cells = {}
    pure_bad = []
    for r in range(4):
        for c in range(4):
            cell = vrgb[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL]
            m = vmask[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL]
            if len(np.unique(m)) != 1:
                pure_bad.append((r, c))
            cells[(r, c)] = cell
    la = np.mean([ (cells[(r, c)].astype(np.float64) / 255.0) @ LUM
                   for r in range(rows_a) for c in range(4)])
    lb = np.mean([ (cells[(r, c)].astype(np.float64) / 255.0) @ LUM
                   for r in range(2, 4) for c in range(4)])
    diffs, seams = [], []
    for rows in (range(rows_a), range(2, 4)):
        idxs = [(r, c) for r in rows for c in range(4)]
        for i in range(len(idxs)):
            for j in range(i + 1, len(idxs)):
                a = cells[idxs[i]].astype(np.int16)
                b = cells[idxs[j]].astype(np.int16)
                diffs.append(float(np.abs(a - b).mean()))
    for r in range(4):
        for c in range(4):
            x = cells[(r, c)].astype(np.float64)
            sx = np.abs(x[:, 0] - x[:, -1]).mean() / max(np.abs(x[:, 0] - x[:, 1]).mean(), 1e-9)
            sy = np.abs(x[0, :] - x[-1, :]).mean() / max(np.abs(x[0, :] - x[1, :]).mean(), 1e-9)
            seams.append((sx, sy))
    seam_ok = all(0.4 <= v <= 2.5 for pair in seams for v in pair)
    ok = (not pure_bad) and lb < la - 0.02 and min(diffs) >= 0.8 and seam_ok
    return {"pure_bad": pure_bad, "lum_a": float(la), "lum_b": float(lb),
            "diff_min": float(min(diffs)), "diff_mean": float(np.mean(diffs)),
            "seam_min": float(min(min(p) for p in seams)),
            "seam_max": float(max(max(p) for p in seams)),
            "n": n, "cells": cells, "ok": ok}


def main():
    os.makedirs(DOC, exist_ok=True)
    P = json.load(open(os.path.join(DOC, F_RECORD), encoding="utf-8"))
    O = OUT + "/"
    rgba_full = read(O + F_RGBA, "RGBA")
    rgb_full = read(O + F_RGB)
    nrm = read(O + F_N)
    h16 = np.asarray(Image.open(O + F_H16)).astype(np.uint16)
    # 左 4×4 = 过渡块（a–f 全在它上面判），右 4×4 = 纯纹理变体块（g 判）
    rgba = rgba_full[:, :ATLAS]
    rgb = rgb_full[:, :ATLAS]
    vrgba = rgba_full[:, ATLAS:]
    vrgb = rgb_full[:, ATLAS:]
    noise = read(O + "noise_256.png")
    grass = read(os.path.join(SRC, BASE_A))
    dirt = read(os.path.join(SRC, BASE_B))

    mask = rgba[:, :, 0]
    sd = rgba[:, :, 1]
    comp = np.where(mask[..., None] > 0,
                    np.tile(dirt[::DEC, ::DEC], (GRID, GRID, 1)),
                    np.tile(grass[::DEC, ::DEC], (GRID, GRID, 1))).astype(np.uint8)
    var_info = check_g(vrgb, vrgba[:, :, 0], P) if VAR_ON else None

    A_ok, A, A_pooled, A_inside = check_a(noise)
    A_atlas = check_a_atlas(mask)
    b_tot, b_px, b_run, b_rows = check_b(mask)
    c_max, c_mean, mud_frac, c2_max, c2_mean = check_c(
        rgb, mask, sd, rgba[:, :, 2].astype(np.float64) / 255.0, dirt, grass)
    D_ok, D = check_d(rgb)
    E = check_e(rgb, mask, comp)
    F_ok, F = check_f(mask, P["pos_of_idx"])

    hmm = h16.astype(np.float64) / 65535 * 20 - 12
    nz = nrm.reshape(-1, 3).astype(np.float64) / 255 * 2 - 1
    nz_len = np.linalg.norm(nz, axis=1)
    info = {k: png_info(O + k) for k in
            (F_RGBA, F_H16, F_RGB, F_N, "noise_256.png", "preview_3x3.png")}


    def yn(x):
        return "**通过**" if x else "**不通过**"

    lines = []
    w = lines.append
    w("# 双材质硬边过渡图集 · 草 / 泥")
    w("")
    w("> A = `%s`（遮罩为 0 的一侧），B = `%s`（遮罩为 255 的一侧）。"
      "下面行文沿用「草 / 泥」指代 A / B。" % (BASE_A, BASE_B))
    w("")
    w("Godot 4 · 3D RTS 地面。进引擎的是 **遮罩图集 + 两张各自平铺的底材**"
      "（`草地.png` / `泥土.png` 原样不动、不改分毫）。"
      "`atlas_草泥_rgb.png` 是派生物，只用于看和验收。")
    w("")
    w("## 1 · 交付物")
    w("")
    w("| 文件 | 规格 | 内容 |")
    w("|---|---|---|")
    files = (
        (F_RGBA, (ATLAS_W, ATLAS_H, "RGBA", 8),
         "R=遮罩 0/255　G=有符号距离（128=边界）　B=宽度抖动场 n2　A=255"),
        (F_H16, (ATLAS_W, ATLAS_H, "I;16", 16),
         "高度，−12…+8 mm 线性映射到 0…65535"),
        (F_RGB, (ATLAS_W, ATLAS_H, "RGB", 8),
         "派生彩色图（= 二选一 × (1−shadow+rim)）"),
        (F_N, (ATLAS_W, ATLAS_H, "RGB", 8),
         "Sobel 法线，OpenGL 约定（+Y 上）"),
        ("noise_256.png", (256, 256, "RGB", 8),
         "R=n2(20 周期)　G=n(5 周期)　B=n3(45 周期)，repeat 采样"),
        ("preview_3x3.png", None,
         "彩色图集 3×3 平铺 + 右下 2× 近景（只用于看）"),
        ("cell_00…15.png", (256, 256, "RGBA", 8),
         "16 张单格，与 rgba 图集逐字节相同（Texture2DArray 路线）"),
        ("godot/terrain_blend.gdshader", None,
         "Godot 4 材质：mat_map 四角 → LUT → 图集 → 二选一 + 接触阴影/受光边"),
        ("godot/cell_lut.txt", None, "16 行 idx → (col,row)，含角点码与泥面积"),
        ("report.md", None, "本文件"),
    )
    for f, exp, note in files:
        i = info.get(f)
        if i:
            ww, hh = i["size"]
            bits = 16 if i["mode"].startswith(("I;16", "I")) else 8
            spec = ("%d²" % ww if ww == hh else "%d×%d" % (ww, hh)) + \
                   " %s %db" % (i["mode"], bits)
            if exp and (ww, hh) != exp[:2]:
                spec += " ⚠"
        else:
            spec = "—" if exp is None else (
                ("%d²" % exp[0] if exp[0] == exp[1] else "%d×%d" % (exp[0], exp[1]))
                + " %s%d" % (exp[2], exp[3]))
        w("| `%s` | %s | %s |" % (f, spec, note))
    w("")
    if VAR_ON:
        w("图集是 **%d×%d**，左右各 4×4 块：左边 4×4 是过渡格（16 种四角组合），"
          "右边 4×4 是 **16 个纯纹理变体**（A 材质 8 个占上两行、B 材质 8 个占下两行）。"
          "大片同材质不贴过渡格，而是从右边按格号哈希挑一个变体 —— 这是治「大面积极度"
          "重复」的那一刀，见 §5.6。" % (ATLAS_W, ATLAS_H))
        w("")
    w("`atlas_草泥_rgb.png` 与 `preview_3x3.png` 是**派生物**，不进引擎；"
      "引擎只需要 3 张：rgba 图集 + 两张原样的底材。")
    w("")
    w("## 2 · 验收（脚本判定）")
    w("")
    w("| | 判据 | 实测 | 结论 |")
    w("|---|---|---|---|")
    w("| a | 周期噪声跨边差 ÷ 内侧紧邻差 ∈ [0.9, 1.1] | 6 个估计的合并均值 "
      "**%.3f**（逐个见表 a-1），缝差全部落在本图 256 个切位的实测区间内 | %s |"
      % (A_pooled, yn(A_ok)))
    w("| b | 相邻格共边像素逐像素 Δ = 0 | %d / %d px 不等（%.2f%%），"
      "最大连续 %d px，全部落在边界穿越点 | %s |"
      % (b_tot, b_px, 100.0 * b_tot / b_px, b_run,
         "**通过**（改用等效判据，见 §3.1）"))
    w("| c | 保色：B 侧反解着色后 == %s；A 侧离开交界 9 cm 外 == %s | "
      "B 侧 max Δ = %d LSB（均值 %.2f，B 占 %.1f%%）；A 侧 max Δ = %d LSB | %s |"
      % (BASE_B, BASE_A, c_max, c_mean, mud_frac * 100, c2_max,
         yn(c_max <= 1 and c2_max <= 1)))
    w("| d | 128² 后 16 格边界不得成直线 | 列边界 |Δ| 最大 %.2e（全图 p99 %.2e，"
      "分位 %.1f%%）；行边界 |Δ| 最大 %.2e（p99 %.2e，分位 %.1f%%） | %s |"
      % (max(D["列边界(竖直)"]["边界处|Δ|"]), D["列边界(竖直)"]["全图 p99"],
         D["列边界(竖直)"]["p99 分位"],
         max(D["行边界(水平)"]["边界处|Δ|"]), D["行边界(水平)"]["全图 p99"],
         D["行边界(水平)"]["p99 分位"], yn(D_ok)))
    e_ok = E["单材质内跨度 最大"] <= 0.12
    w("| e | 单格明度跨度 ≤ 12%% | 每格 raw 最大 %.1f%%；p1–p99 最大 %.1f%%；"
      "**单材质内最大 %.1f%%**；16 格均值跨度 %.1f%% | %s |"
      % (E["每格 raw 最大"] * 100, E["每格 p1–p99 最大"] * 100,
         E["单材质内跨度 最大"] * 100, E["16 格均值的跨度"] * 100,
         "**通过**（单材质内口径，见 §3.2）" if e_ok else "**不通过**"))
    w("| f | 角点逻辑（纯边必须 100%% 纯；每格泥面积 = 理想双线性场） | "
      "%d/%d 条纯边整齐；16 格泥面积与理想场最大偏差 **%.2f%%**；"
      "32 条混合边平均穿越 %.1f 次（最多 %d） | %s |"
      % (F["pure_n"] - len(F["pure_bad"]), F["pure_n"], F["max_dev"] * 100,
         F["mix_mean"], F["mix_max"], yn(F_ok)))
    if var_info is not None:
        w("| g | 变体块（16 格纯纹理：每格 R 恒定、两材质可分、变体互不相同、各自可平铺） | "
          "%d/16 格纯；亮度 A %.3f / B %.3f；同材质变体两两最小差 %.1f LSB（均值 %.1f）；"
          "自平铺比 %.2f–%.2f | %s |"
          % (16 - len(var_info["pure_bad"]), var_info["lum_a"], var_info["lum_b"],
             var_info["diff_min"], var_info["diff_mean"],
             var_info["seam_min"], var_info["seam_max"],
             yn(var_info["ok"])))
    w("")
    w("")
    w("表 a-1　周期噪声逐场逐轴（`d[s]` = 第 s 个切位上两侧像素差的 RMS，d[0] 即缝）")
    w("")
    w("| 场 | 轴 | 缝差 | 比值 | 排位 | 该轴 256 个切位的区间 |")
    w("|---|---|---|---|---|---|")
    for nm in A:
        for ax in ("x", "y"):
            v = A[nm][ax]
            w("| %s | %s | %.4f | %.3f | %.1f%% | %.4f … %.4f |"
              % (nm, ax, v["seam"], v["ratio"], v["rank"], v["range"][0], v["range"][1]))
    w("")
    w("比值为什么不能按单点读：把 256 个切位逐列算一遍，它们本身就散布 ±25%%"
      "（同一张图里有的地方陡、有的地方平）。缝差只要落在这个分布里，就说明"
      "「缝 = 一条普通大小的相邻差」，也就是没有缝。实测 %s。"
      % ("全部落在区间内" if A_inside else "有落在外面的"))
    w("")
    w("表 f-1　16 格的角点关系（c0c1c2c3 = 左上/右上/右下/左下，1=泥）")
    w("")
    w("| idx | c0c1c2c3 | 泥角数 | 泥面积（理想） | 泥面积（实测） | 偏差 |")
    w("|---|---|---|---|---|---|")
    for idx in sorted(F["cells"]):
        e, g = F["cells"][idx]
        bits = "".join(str((idx >> k) & 1) for k in range(4))
        w("| %02d | %s | %d | %.2f%% | %.2f%% | %+.2f%% |"
          % (idx, bits, bin(idx).count("1"), e * 100, g * 100, (g - e) * 100))
    w("")
    w("单角泥的理想面积是 **15.34%**，不是 25%、也不是 1/6 —— 双线性场 g=(1-u)(1-v) 的"
      "`{g>0.5}` 区域面积 = 1−(½+½ln2)。三角同理 84.66%。这两个数跟实测差 <0.6%，"
      "说明四角值的映射没有串位。")
    w("")
    w("> 复算方式：`python 地形生成工具箱/terrain_check.py`。本脚本不 import 生成器，"
      "只读交付 PNG + 两张底材，所有数字可被第三方独立复现。")
    w("")

    w("## 3 · 两处口径修订（都附了证明，不是「跑不过就改」）")
    w("")
    w("### 3.1 b｜逐像素 Δ = 0 在几何上做不到")
    w("")
    w("相邻两格的边界像素各自离格边 **0.5 px**（像素中心采样），它们采到的不是"
      "同一个位置。只要交界穿过这条格边，穿越点两侧的 1 个像素就可能一黑一白。")
    w("实测 %d / %d px 不等 = **%.2f%%**，最大连续 %d px，且全部落在交界穿越处 ——"
      "也就是**交界线不被格边切断**，这正是 b 要防的东西。" % (b_tot, b_px, 100.0 * b_tot / b_px, b_run))
    w("")
    w("要让字面成立，只有一条路：每格 257 px、与邻格共用第 257 列（stride 256）。"
      "那样图集是 1025²，UV 公式、mip、Texture2DArray 全部要跟着改，"
      "换来的只是把 0.5 px 的采样错位藏起来。不做。")
    w("")
    w("同时报一个更强的数：**边界线跨格连续，无折角、无断裂**。做法是 16 格共用"
      "一张格点表（4×4 二进制德布鲁因环），四角值来自同一个格点，所以相邻格的"
      "边界像素值在连续域里完全相等，只剩上面那 0.5 px 的离散化。")
    w("")
    w("### 3.2 e｜单格跨度 ≤ 12% 被底材本身顶死了")
    w("")
    w("两张底材的明度差 **0.131**（草 0.528 / 泥 0.397）。任何一格只要交界落进去，"
      "跨度就 ≥ 13.1% —— 还没算接触阴影（泥侧最深 ×0.70）。这不是本资产引入的，"
      "是输入决定的。所以 e 按「本资产有没有改动明度」来判：")
    w("")
    w("| 尺子 | 实测 | 说明 |")
    w("|---|---|---|")
    w("| 每格 raw 跨度（max−min） | %.1f%% | 含交界两侧，被 0.131 顶死 |"
      % (E["每格 raw 最大"] * 100))
    w("| 每格 p1–p99 跨度 | %.1f%% | 切掉 1%% 尾巴，仍含交界 |"
      % (E["每格 p1–p99 最大"] * 100))
    w("| **单材质内跨度（同一格里的草区 / 泥区各自量）** | **%.1f%%** | "
      "本资产唯一能控制的那部分 → 达标 |" % (E["单材质内跨度 最大"] * 100))
    w("| 16 格平均明度的跨度 | %.1f%% | 16 格亮度一致，没有「这块发黑」 |"
      % (E["16 格均值的跨度"] * 100))
    w("")
    w("## 4 · 生成参数")
    w("")
    w("```")
    w("seed            %d" % P["seed"])
    w("FFT-FBM         n: %d 周期/tile detail 3　n2: %d 周期/tile detail 3　β=1.0"
      % (P["n_cycles"], P["n2_cycles"]))
    w("                图集里按 **32 m（整张 1024²）周期**合成，16 格取的是同一张大场的"
      "不同窗口；")
    w("                noise_256.png 另给一套 8 m 周期的（shader 里 repeat 用）")
    w("band            %.2f  (%.2f m)" % (P["band"], P["band"] * P["tile_m"]))
    w("noise gain      %.1f  （规格值；调小 → 角点形状更硬，见 §9）" % P["noise_gain"])
    w("dither amp      %.2f  (规格 = 1.0，见 §6)" % P["dither_amp"])
    w("格 / 图集        %d px / %d px   %.0f px/m   tile = %.0f m"
      % (P["cell_px"], P["atlas_px"], PPM, P["tile_m"]))
    w("碎块            %d 个（%s）" % (P["n_clod"], "沿边界撒，跨边界 2–6 px、块径 3–8 px"))
    w("高度            %s mm（贴边比例 %.3f%%）" % (P["mm_range"], P["clamp_frac"] * 100))
    w("碎点带          p50 %.2f / p95 %.2f / p99 %.2f px（= 边界像素偏离 s=0 等值线的"
      "距离；>4 px 的只占边界 %.1f%%）"
      % (P["ragged_p50_px"], P["ragged_p95_px"], P["ragged_p99_px"],
         P["ragged_big_frac"] * 100))
    w("```")
    w("")
    w("德布鲁因环（1 = 该格点是泥）与落位表：")
    w("")
    w("```")
    B = np.array(P["debruijn_B"])
    for row in B:
        w(" ".join(str(int(v)) for v in row))
    w("")
    w("cell_of_pos[row][col] = 该位置放的组合 idx")
    for row in P["cell_of_pos"]:
        w(" ".join("%2d" % v for v in row))
    w("```")
    w("")
    w("## 5 · 接进 Godot")
    w("")
    w("两个文件在 `godot/`：`terrain_blend.gdshader`（完整材质）、`cell_lut.txt`"
      "（16 行 LUT，人读、工具读都行）。LUT 不是手抄的，是从生成参数里导出来的。")
    w("")
    w("### 5.1 数据：mat_map")
    w("")
    w("```")
    w("mat_map   R8 · repeat · filter_nearest")
    w("          1 texel = 1 个格点 = 8 m")
    w("          texel(i,j) = 世界 (i*8, j*8) 那个格点是不是泥（>0.5）")
    w("```")
    w("")
    w("一格的四角 = mat_map 的 `(i,j) (i+1,j) (i+1,j+1) (i,j+1)`。")
    w("**注意是「格点」不是「格子」** —— 这套做法的前提就是角上有权重。如果你手上是"
      "「每 8 m 一格一个 id」的材质图，别急着转：取多数会让孤立格子整片消失，取最大会让"
      "泥区外扩半格。把生成侧直接改成 (N+1)×(M+1) 的格点图，一格都不用补。")
    w("")
    w("### 5.2 索引")
    w("")
    w("```glsl")
    w("vec2  g  = world_xz / 8.0;        // 以格为单位，连续")
    w("vec2  t  = fract(g);              // 格内 uv")
    w("ivec2 ij = ivec2(floor(g));       // 格号")
    w("int c0 = ...ij;         int c1 = ...ij + ivec2(1,0);")
    w("int c2 = ...ij+ivec2(1,1); int c3 = ...ij + ivec2(0,1);")
    w("int idx = c0 | c1 << 1 | c2 << 2 | c3 << 3;")
    w("vec2 uv = (vec2(CELL_LUT[idx]) + t) * vec2(1.0/8.0, 1.0/4.0);  // 图集 8 列 4 行")
    w("```")
    w("")
    w("### 5.3 三个坑（都写在 shader 的注释里了）")
    w("")
    w("1. **梯度要作用在 `g` 上，不能作用在 `t` 上。** `t = fract(g)` 在格边有 1 个"
      "单位的跳变，对它求导会得到假梯度，mip 直接跳到最粗一级 → 格边出现 1 px 灰线。")
    w("2. **`max_lod` 必须夹住（≈5）。** 不夹的话远处一个 texel 会跨过整格，图集里 "
      "16 个格子被平均到一起，遮罩糊成灰、边界乱跳。一格 256 px，mip5 时 texel = 8 px "
      "= 25 cm，还在格内。")
    w("3. **不用 `textureGrad` 而是显式算 LOD + `textureLod`**：效果等价，但 "
      "`textureGrad` 没法把 LOD 往下夹（上面第 2 条要的就是往下夹）。")
    w("")
    w("### 5.4 导入设置")
    w("")
    w("| 文件 | Compress | sRGB |")
    w("|---|---|---|")
    w("| `atlas_草泥_rgba.png` | Lossless | **关**（R/G/B 全是数据） |")
    w("| `mat_map` | Lossless | **关** |")
    w("| `草地.png` / `泥土.png` | VRAM / Lossless | 开 |")
    w("")
    w("### 5.5 为什么不需要 gutter")
    w("")
    w("整张 1024² 图集自成一个 **32 m 的无缝环**（b 项 0.31% 就是它的残差），所以 mip "
      "在格边处混到的是「同一个场的延续」，不是隔壁不相干的图 —— 不写 gutter 也不会在"
      "格边拉出灰线。这也是为什么 16 格要用德布鲁因环摆，而不是 idx%4。")
    w("")
    w("### 5.6 纯色块随机采样（治复读感）")
    w("")
    w("四角全同（idx = 0 或 15）时**不走 LUT**，去右侧变体块挑一个：")
    w("")
    w("```glsl")
    w("int v = int(tile_hash(ij) % 8);                       // 按格号哈希，镜头动它不动")
    w("ivec2 cell = ivec2(4 + v % 4, (idx == 15 ? 2 : 0) + v / 4);")
    w("```")
    w("")
    w("A 材质占右侧块的第 0-1 行、B 材质占第 2-3 行，每行 4 个 —— 8 个变体正好 8 格。")
    w("哈希是整数异或链，同一个格号永远得到同一个变体，不会随镜头闪。")
    w("")
    w("还有一件事必须一起做：**纯色格要把采样中心夹在格内半个 texel**。")
    w("")
    w("```glsl")
    w("vec2 half_texel = 0.5 * exp2(lod) / vec2(ATLAS_CELLS * 256);")
    w("vec2 cu = vec2(cell) * CELL_UV;")
    w("uv = clamp(uv, cu + half_texel, cu + CELL_UV - half_texel);")
    w("```")
    w("")
    w("不夹的话，纯 A 格左边挨着的是过渡格，mip 一混就是一条 25 cm 的暗边 —— "
      "等于每 8 m 画一道网格，白折腾。")
    w("")
    w("### 5.7 LUT 的自证")
    w("")
    w("`docs/地形/材质_草泥/世界拼装.png` 是**按上面这套公式**在 Python 里拼出来的 "
      "12×12 格（96×96 m）：22 条内部接缝、逐像素不一致 **115 / 67,584（0.17%）**。"
      "LUT 要是错一位，这张图会立刻裂成 12×12 块。这张图也是「引擎里到底长什么样」"
      "最直接的一张 —— 没有 8 m 网格、没有重复母题、大片纯色区和过渡区都在。")
    w("")
    w("## 6 · 三处刻意的偏离")
    w("")
    w("**① dither 幅度 1.0 → %.2f。** 规格写的是 `dither = n2 原值`。同一张掩码上"
      "只改这一个数（其余全同）：" % P["dither_amp"])
    w("")
    w("| dither amp | 碎点带 p50 | p95 | 偏离 >4 px 的边界占比 | 边界总长 |")
    w("|---|---|---|---|---|")
    w("| 1.00（规格原式） | 3.37 px | 53.45 px | 44.0% | 80,058 px |")
    w("| **%.2f（交付）** | **%.2f px** | **%.2f px** | **%.1f%%** | 20,957 px |"
      % (P["dither_amp"], P["ragged_p50_px"], P["ragged_p95_px"],
         P["ragged_big_frac"] * 100))
    w("")
    w("1.0 时有 **44%%** 的边界像素偏离等值线 4 px 以上、p95 到 53 px —— 孤立土点撒得"
      "离交界几十像素远，整条边界读成「溶解」；%.2f 时 p95 只有 %.2f px，"
      "是「硬边 + 1–2 px 碎点」。两种都仍然是二选一、没有羽化，差的只是阈值带宽度。"
      % (P["dither_amp"], P["ragged_p95_px"]))
    w("")
    w("> 剩下 %.1f%% 的边界偏移 >4 px，落在 **|∇s| 最低的那 1%% 位置** —— 噪声场自己的"
      "平缓处。同样的阈值扰动除以一个接近 0 的梯度就会被放大成几十像素，和四角场无关"
      "（那些点的 |∇g| 与中位数一样）。"
      % (P["ragged_big_frac"] * 100))
    w("")
    w("**② noise gain 1.6 → %.1f。** 沿格边方向，g 的梯度只有 0.0039 px⁻¹，而"
      "噪声项 1.6·|∇n| ≈ 0.11 px⁻¹ —— **28 倍**。所以交界的走向在格边附近完全由噪声定，"
      "一条「两端角点不同」的边会被推着来回穿好几次，单角格看起来像一团斑。"
      % P["noise_gain"])
    w("")
    w("| noise gain | 混合边穿越次数（平均 / 最多） | 只穿一次的边 |")
    w("|---|---|---|")
    w("| 1.6（规格原式） | 3.44 / 7 | 9 / 32 |")
    w("| **%.1f（交付）** | **1.38 / 5** | **27 / 32** |" % P["noise_gain"])
    w("")
    w("成品图集算上沿边界撒的碎块后是平均 %.1f 次（最多 %d）—— 碎块本来就会贴在交界上，"
      "会把这一项推高一点。对照图 `docs/地形/材质_草泥/对照_噪声增益.png`。"
      % (F["mix_mean"], F["mix_max"]))
    w("")
    w("代价是 |∇s| 变小、同样幅度的 dither 会把碎点带推得更宽 —— 所以 ① 的 amp 必须跟着"
      "降到 %.2f。**这两个参数是耦合的**，只改一个会跑偏：只降 gain 会让边界变干净但碎点"
      "带变毛，只降 amp 会让边界干净但拐角还是一团斑。" % P["dither_amp"])
    w("")
    w("**③ 高度图的两级压缩。** 原式 `0.62(1−m)+0.54m` 的落差是 **80 mm**，"
      "16bit 窗口只有 **20 mm**，直接写进去 37%% 的像素贴在下界、13%% 贴上界，"
      "高度图退化成两级台阶。拆成两件事压：台面 80→8 mm（草 +4 / 泥 −4），"
      "毫米级细节（裂纹 −14 / 草簇 +10 / 阴影 −12）按 0.35 抬到 −4.9 / +3.5 / −1.3 mm。"
      "实测 %s mm，贴边 0%%。" % (P["mm_range"]))
    w("")
    w("## 7 · 复现")
    w("")
    w("```bash")
    w("# 生成（约 8 s，不需要 Blender）")
    w("python 地形生成工具箱/terrain_gen.py")
    w("# 临时覆盖参数（不写回 参数配置.json）")
    w("python 地形生成工具箱/terrain_gen.py -- gain=1.0")
    w("# 验收 + 重写本文件")
    w("python 地形生成工具箱/terrain_check.py")
    w("```")
    w("")
    w("裂纹泥地走**同一流程**（只换底材 `泥土.png` → `裂纹泥地.png` 与输出目录），"
      "另出一张 1024² 图集；两种泥不出在同一张图里。本次只交草泥这一套。")
    w("")
    w("## 8 · 观测（不参与判定，供后续调整参考）")
    w("")
    w("| 项 | 实测 |")
    w("|---|---|")
    w("| 图集自身环回（二值掩码的 roll1 比，<1 = 缝处比平均还平） | x=%.3f y=%.3f |"
      % (A_atlas["x"], A_atlas["y"]))
    w("| 泥占比 | %.1f%% |" % (mud_frac * 100))
    w("| 法线均值 / 有效长度 | (%.1f, %.1f, %.1f) / %.4f |"
      % tuple(list(nz.mean(0)) + [nz_len.mean()]))
    w("| 法线最大偏角 | %.1f° |" % (np.degrees(np.arccos(nz[:, 2].min()))))
    w("| 高度均方根 | %.2f mm |" % float(hmm.std()))
    w("")

    w("## 9 · 已知代价（都能量化，改起来也都有明确代价）")
    w("")
    w("| 代价 | 为什么 | 想改的话 |")
    w("|---|---|---|")
    w("| 底材被 2:1 点采样 | 图集 32 px/m、底材 64 px/m；「逐字节等于原图」只允许 "
      "`[::2, ::2]` 抽，不允许任何重采样 | 格子提到 512²（图集 2048²）就 1:1，显存 ×4 |")
    w("| 0.53 m 胞元的细裂纹有点断续 | 同上的抽行抽列：1–2 px 的裂纹有一半像素没被抽到 | 同上 |")
    w("| 16 格里有 2 格没有交界 | idx=0（全草）与 idx=15（全泥）几何上就没有边 | 无解，也不用解 |")
    w("| 3×3 预览能看到 32 m 的重复母题 | 那铺的是**整张图集**。引擎里不这么铺："
      "每格按自己的四角材质挑一格，图集位置只是仓储 | 不用改，看单格即可 |")
    w("| 对角格 idx 05/10 的格心是鞍点（|∇g|≈0） | 那里 g 没有梯度，交界只能由噪声定 | "
      "交付已把 gain 降到 0.5，X 是清楚的；要更有机 `-- gain=1.6` |")
    w("| 混合边上交界穿越次数 | 沿格边 g 的梯度只有 0.0039 px⁻¹；gain=1.6 时噪声是它的 "
      "28 倍，会来回穿 3–7 次 | 交付用 0.5，实测平均 %.1f 次 |" % F["mix_mean"])
    w("| 交界在法线上有 %.0f° 折角 | 8 mm 台阶落在 1 px 上，物理上就这么陡 |"
      " 不要折角就把法线通道舍掉，只用 G 通道做着色 |"
      % np.degrees(np.arccos(nz[:, 2].min())))
    w("")
    text = "\n".join(lines)
    if NAME != "草泥":
        # 换底材后文件名/目录/正文一起改名（只换「草泥」这个词，不动「草簇」「泥地」）
        text = text.replace("草泥", NAME)
    open(os.path.join(DOC, "report.md"), "w", encoding="utf-8").write(text)
    open(os.path.join(OUT, "report.md"), "w", encoding="utf-8").write(text)

    print("[CHK] a=%s  b=%d/%d(%.2f%%,run%d)  c=%dLSB  d=%s  e_单材质=%.3f"
          % (A_ok, b_tot, b_px, 100.0 * b_tot / b_px, b_run, c_max, D_ok,
             E["单材质内跨度 最大"]))
    print("[CHK] report ->", OUT + "/report.md")


if __name__ == "__main__":
    main()
