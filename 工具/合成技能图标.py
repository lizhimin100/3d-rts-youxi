# -*- coding: utf-8 -*-
"""把 工具/渲染技能图标.gd 出的透明底原图，合成成 256² 技能图标。

底版和单位/建筑图标**同一张**（从 美术/图标/单位/peasant.png 反解出来，
缓存到 _qa/图标底版.png），所以技能图标和头像摆在一起是一套画风。

用法：python 工具/合成技能图标.py [id ...]
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW_DIR = os.path.join(ROOT, "_qa", "图标原图_技能")
OUT_DIR = os.path.join(ROOT, "美术", "图标", "技能")
OUT = 256
PLATE_REF = os.path.join(ROOT, "美术", "图标", "单位", "peasant.png")
PLATE_CACHE = os.path.join(ROOT, "_qa", "图标底版.png")
IDS = ["shield_up", "triple_shot", "fireball", "chop_wood", "mine_gold"]


def plate_from_reference(size=(OUT, OUT)):
    if not os.path.exists(PLATE_REF):
        return None
    ref = Image.open(PLATE_REF).convert("RGB")
    if size != ref.size:
        ref = ref.resize(size, Image.LANCZOS)
    w, h = ref.size
    edge = 8
    top = [ref.getpixel((x, edge)) for x in range(edge, w - edge)]
    left = [ref.getpixel((edge, y)) for y in range(edge, h - edge)]
    base = ref.getpixel((edge, edge))

    def ratio(c, b):
        return [max(0.02, c[i] / max(b[i], 1)) for i in range(3)]

    fx = [ratio(c, top[0]) for c in top]
    fy = [ratio(c, left[0]) for c in left]
    fx = [fx[0]] * edge + fx + [fx[-1]] * edge
    fy = [fy[0]] * edge + fy + [fy[-1]] * edge
    fx, fy = fx[:w], fy[:h]
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        ry = fy[y]
        for x in range(w):
            rx = fx[x]
            px[x, y] = (
                max(0, min(255, int(base[0] * rx[0] * ry[0]))),
                max(0, min(255, int(base[1] * rx[1] * ry[1]))),
                max(0, min(255, int(base[2] * rx[2] * ry[2]))),
            )
    return img


def plate(size=(OUT, OUT)):
    if os.path.exists(PLATE_CACHE):
        try:
            im = Image.open(PLATE_CACHE).convert("RGB")
            if im.size == size:
                return im
        except Exception:
            pass
    im = plate_from_reference(size)
    if im is None:
        return Image.new("RGB", size, (26, 22, 18))
    os.makedirs(os.path.dirname(PLATE_CACHE), exist_ok=True)
    im.save(PLATE_CACHE)
    return im


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
    # 技能图标是"道具特写"，占画面 84%（比单位头像 90% 略小，留出边距）
    target = int(OUT * 0.84)
    scale = target / max(bw, bh, 1)
    tw, th = max(1, int(round(bw * scale))), max(1, int(round(bh * scale)))
    body = body.resize((tw, th), Image.LANCZOS)
    # 深色描边：把 alpha 撑开 2px 再挖空，垫一层近黑的底 —— 和游戏里单位的
    # 反向外壳描边同一套观感，46px 下轮廓才立得住。
    from PIL import ImageFilter as _IF
    alpha = body.split()[3]
    grown = alpha.filter(_IF.MaxFilter(5))
    rim = Image.new("RGBA", body.size, (22, 16, 12, 255))
    rim.putalpha(grown)
    canvas = plate((OUT, OUT))
    x = (OUT - tw) // 2
    y = (OUT - th) // 2
    canvas.paste(rim, (x, y), rim)
    canvas.paste(body, (x, y), body)
    d = ImageDraw.Draw(canvas)
    d.rectangle([0, 0, OUT - 1, OUT - 1], outline=(120, 104, 70))
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, key + ".png")
    canvas.save(out)
    print("合成", key, "->", out, canvas.size)
    return True


def main():
    want = sys.argv[1:]
    todo = [k for k in IDS if not want or k in want]
    ok = 0
    for k in todo:
        if compose(k):
            ok += 1
    print("完成 %d / %d" % (ok, len(todo)))


if __name__ == "__main__":
    main()
