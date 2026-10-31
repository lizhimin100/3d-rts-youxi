# -*- coding: utf-8 -*-
"""把 `工具/渲染单位图标.py` 出的原图（512² RGBA）合成成 256² 单位头像。

为什么分两步（和建筑图标同一套理由）：
  · Blender 只管"把人拍清楚"（三点光 + 透明底），构图/背景/暗角交给 PIL ——
    可复现、可批量调，不用为了 2px 的留白去重跑渲染。

合成做的事：
  1. 按 **alpha 通道**自动裁出人物（这就是"人物占总画面 40% 也能排版整齐"的原因）；
  2. 等比缩放到目标高度（默认占 88%），水平居中、底部对齐 96%；
  3. 垫一层暗底（上冷下暖的竖向渐变 + 中心微光），人物从背景里"浮"出来；
  4. 四角压暗（vignette）+ 1px 内描边 —— 魔兽图标的观感。

用法：python 工具/合成单位图标.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW_DIR = os.path.join(ROOT, "_qa", "图标原图_单位")
OUT_DIR = os.path.join(ROOT, "美术", "图标", "单位")

UNITS = ["peasant", "footman", "archer", "mage", "steam_guard"]
OUT = 256
BODY_RATIO = 0.88     # 人物高度占画布比例
BOTTOM_PAD = 0.06     # 底部留白


def backdrop(size):
    """竖向渐变 + 中心微光：上冷（夜空）→ 下暖（地面反光）。"""
    w, h = size
    img = Image.new("RGB", size, (0, 0, 0))
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        # 顶 (18,26,38) → 中 (26,30,34) → 底 (16,14,12)
        if t < 0.55:
            k = t / 0.55
            c = (int(18 + (26 - 18) * k), int(26 + (30 - 26) * k), int(38 + (34 - 38) * k))
        else:
            k = (t - 0.55) / 0.45
            c = (int(26 + (16 - 26) * k), int(30 + (14 - 30) * k), int(34 + (12 - 34) * k))
        for x in range(w):
            px[x, y] = c
    # 中心微光（人物背后一圈暖光，避免纯黑背景）
    glow = Image.new("L", size, 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([w * 0.05, h * 0.10, w * 0.95, h * 0.95], fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(w * 0.18))
    warm = Image.new("RGB", size, (74, 62, 44))
    img = Image.composite(warm, img, glow.point(lambda v: int(v * 0.55)))
    return img


def vignette(img):
    w, h = img.size
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([-w * 0.15, -h * 0.20, w * 1.15, h * 1.20], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(w * 0.10))
    dark = Image.new("RGB", (w, h), (4, 5, 7))
    return Image.composite(img, dark, mask)


def compose(key):
    src = os.path.join(RAW_DIR, key + ".png")
    if not os.path.exists(src):
        print("!! 缺原图：", src)
        return False
    raw = Image.open(src).convert("RGBA")
    bbox = raw.split()[3].getbbox()
    if bbox is None:
        print("!! 原图全透明：", key)
        return False
    body = raw.crop(bbox)
    bw, bh = body.size
    target_h = int(OUT * BODY_RATIO)
    scale = target_h / max(bh, 1)
    tw, th = max(1, int(round(bw * scale))), target_h
    if tw > OUT * 0.94:
        scale = (OUT * 0.94) / max(bw, 1)
        tw, th = int(OUT * 0.94), max(1, int(round(bh * scale)))
    body = body.resize((tw, th), Image.LANCZOS)

    canvas = backdrop((OUT, OUT))
    x = (OUT - tw) // 2
    y = int(OUT * (1.0 - BOTTOM_PAD)) - th
    canvas.paste(body, (x, y), body)
    canvas = vignette(canvas)

    # 1px 内描边（贴着画布边，和段底的金边呼应）
    d = ImageDraw.Draw(canvas)
    d.rectangle([0, 0, OUT - 1, OUT - 1], outline=(120, 104, 70))

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, key + ".png")
    canvas.save(out)
    print("合成", key, "→", out, canvas.size)
    return True


def main():
    ok = 0
    for k in UNITS:
        if compose(k):
            ok += 1
    print("完成 %d / %d" % (ok, len(UNITS)))


main()
