"""把 `_qa/图标原图/<id>.png`（Blender 透明底渲染）合成成**魔兽争霸 3 味道**的图标。

输出：`美术/图标/建筑/<id>.png`（256×256，不透明）。

为什么要这一层：
  Blender 出的是"物理正确的平光图 + 透明底"。而魔兽 3 的图标是**手绘**的：
  · 背后不是一个 3D 地面，而是画出来的天空 + 远山 + 大地（有大气透视）；
  · 光是戏剧化的：暖主光 + 冷补光 + 背后轮廓光；
  · 颜色是高饱和、高对比的，四角压暗。
  这些用 PIL 合成最便宜也最可控（改参数就能整体换味道），不用动模型材质。

流程：画背景 → 贴建筑 → 分离调色（暖高光/冷暗部）→ 暗角 → 锐化。
"""

import math
import os
import random

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW_DIR = os.path.join(ROOT, "_qa", "图标原图")
OUT_DIR = os.path.join(ROOT, "美术", "图标", "建筑")
OUT = 256
SS = 2                     # 先用 2× 画，最后缩到 256（抗锯齿）

IDS = ["townhall", "barracks", "blacksmith", "farm", "tower",
       "watchtower", "sanctum", "workshop", "lumbercamp"]

# ── 背景配色（想换天气/时段就改这里）──────────────────────────────────
SKY_TOP = (26, 38, 66)         # 天顶：冷深蓝
SKY_MID = (86, 96, 128)        # 中天：灰蓝
HORIZON = (226, 168, 96)       # 地平线：暖金
GROUND_NEAR = (60, 46, 32)     # 脚下：暖土
GROUND_FAR = (104, 80, 54)     # 远处地面（更亮，大气透视）
HILL_COL = (52, 58, 86)        # 远山

# ── 调色参数 ────────────────────────────────────────────────────────
CONTRAST = 1.20
SATURATION = 1.26
KEY_WARM = (0.050, 0.012, -0.032)
SHADOW_COOL = (-0.034, -0.004, 0.060)
VIGNETTE = 0.40


def _lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _paint_background(w: int, h: int, seed: int) -> Image.Image:
    img = Image.new("RGB", (w, h), GROUND_NEAR)
    d = ImageDraw.Draw(img)
    horizon = int(h * 0.60)

    # 1) 天空：三段渐变（天顶冷 → 地平线暖）
    for y in range(horizon):
        t = y / max(1, horizon - 1)
        if t < 0.62:
            c = _lerp(SKY_TOP, SKY_MID, t / 0.62)
        else:
            c = _lerp(SKY_MID, HORIZON, (t - 0.62) / 0.38)
        d.line([(0, y), (w, y)], fill=c)

    # 2) 远山：两层，越远越淡（大气透视）
    rnd = random.Random(seed)
    for layer, (base_y, amp, col) in enumerate([
            (horizon - int(h * 0.055), h * 0.055, _lerp(HILL_COL, SKY_MID, 0.35)),
            (horizon - int(h * 0.020), h * 0.040, _lerp(HILL_COL, SKY_MID, 0.10))]):
        pts = [(0, h)]
        for i in range(0, w + 8, 8):
            x = i / w
            y = base_y - amp * (math.sin(x * math.tau * 1.7 + layer * 2.1) * 0.45
                                + math.sin(x * math.tau * 3.3 + layer * 1.3) * 0.25
                                + rnd.uniform(-0.10, 0.10))
            pts.append((i, y))
        pts.append((w, h))
        d.polygon(pts, fill=col)

    # 3) 大地：远处亮、近处暗（同样是大气透视 + 压暗前景）
    for y in range(horizon, h):
        t = (y - horizon) / max(1, h - horizon - 1)
        d.line([(0, y), (w, y)], fill=_lerp(GROUND_FAR, GROUND_NEAR, min(1.0, t * 1.25)))

    # 4) 地平线附近加一条暖雾，把天和地"焊"在一起（手绘图标都这么处理接缝）
    haze = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    hd = ImageDraw.Draw(haze)
    band = int(h * 0.10)
    for i in range(band):
        a = int(70 * (1.0 - i / band) ** 1.6)
        hd.line([(0, horizon - band // 2 + i), (w, horizon - band // 2 + i)],
                fill=(255, 206, 150, a))
    img = Image.alpha_composite(img.convert("RGBA"), haze.filter(
        ImageFilter.GaussianBlur(w * 0.012))).convert("RGB")
    return img


def _curve_lut(gain: float):
    lut = []
    for i in range(256):
        x = i / 255.0
        y = x + gain * (x - 0.5) * (1.0 - abs(x - 0.5) * 2.0) * 1.9
        lut.append(max(0, min(255, int(round(y * 255.0)))))
    return lut


def _vignette(img: Image.Image, strength: float) -> Image.Image:
    w, h = img.size
    small = Image.new("L", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            dx = (x - 31.5) / 31.5
            dy = (y - 31.5) / 31.5
            dv = min(1.0, (dx * dx + dy * dy) ** 0.5 / 1.414)
            px[x, y] = max(0, min(255, int((1.0 - strength * dv ** 2.2) * 255)))
    mask = small.resize((w, h), Image.BICUBIC)
    black = Image.new("RGB", (w, h), (0, 0, 0))
    return Image.composite(img, black, mask)


def grade(raw_path: str, dst: str, seed: int) -> None:
    w = OUT * SS
    bg = _paint_background(w, w, seed)
    fg = Image.open(raw_path).convert("RGBA").resize((w, w), Image.LANCZOS)
    alpha = fg.split()[3]
    # 建筑整体稍微压暗一点、抬饱和，并**往暖石色推**（原模型是很冷的白石膏，
    # 不推一下放在夕阳里像贴上去的）
    fg_rgb = ImageEnhance.Color(fg.convert("RGB")).enhance(1.12)
    r, g, b = fg_rgb.split()
    fg_rgb = Image.merge("RGB", (
        r.point(lambda v: min(255, int(v * 1.055))),
        g.point(lambda v: min(255, int(v * 0.992))),
        b.point(lambda v: min(255, int(v * 0.925))),
    ))
    fg = Image.merge("RGBA", (*fg_rgb.split(), alpha))

    # **深色轮廓线**（魔兽图标是手绘的，靠一条压暗的边把楼"勾"出来，
    # 不是靠发光；发光会把细节糊掉 —— 试过 0.55 的暖光晕，整栋楼变毛）
    from PIL import ImageChops
    inner = alpha.filter(ImageFilter.GaussianBlur(w * 0.005))
    contour = ImageChops.subtract(alpha, inner)          # 只留最外圈 1~2px
    contour = contour.filter(ImageFilter.GaussianBlur(w * 0.0015))
    line_rgba = Image.new("RGBA", (w, w), (26, 18, 12, 0))
    line_rgba.putalpha(contour.point(lambda v: int(v * 0.62)))

    img = Image.alpha_composite(bg.convert("RGBA"), fg)
    img = Image.alpha_composite(img, line_rgba).convert("RGB")

    # 分离调色：高光偏暖、暗部偏冷（把"白模"往"黄昏石墙"推）
    img = img.point(_curve_lut(CONTRAST - 1.0) * 3)
    img = ImageEnhance.Color(img).enhance(SATURATION)
    px = img.load()
    for y in range(w):
        for x in range(w):
            r, g, b = px[x, y]
            lum = (r * 0.30 + g * 0.59 + b * 0.11) / 255.0
            hi = max(0.0, lum - 0.55) / 0.45
            lo = max(0.0, 0.45 - lum) / 0.45
            r += (KEY_WARM[0] * hi + SHADOW_COOL[0] * lo) * 255
            g += (KEY_WARM[1] * hi + SHADOW_COOL[1] * lo) * 255
            b += (KEY_WARM[2] * hi + SHADOW_COOL[2] * lo) * 255
            px[x, y] = (max(0, min(255, int(r))), max(0, min(255, int(g))),
                        max(0, min(255, int(b))))

    img = _vignette(img, VIGNETTE)
    img = img.filter(ImageFilter.UnsharpMask(radius=2.2, percent=62, threshold=2))
    img = img.resize((OUT, OUT), Image.LANCZOS)
    os.makedirs(OUT_DIR, exist_ok=True)
    img.save(dst)
    print("合成 OK %s" % dst)


def main():
    if not os.path.isdir(RAW_DIR):
        print("没有原图目录：%s（先跑 工具/渲染建筑图标.py）" % RAW_DIR)
        return
    n = 0
    for i, key in enumerate(IDS):
        src = os.path.join(RAW_DIR, key + ".png")
        if not os.path.exists(src):
            print("跳过（没原图）：%s" % key)
            continue
        grade(src, os.path.join(OUT_DIR, key + ".png"), 1000 + i * 37)
        n += 1
    print("完成 %d 张" % n)


main()
