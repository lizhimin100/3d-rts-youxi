# -*- coding: utf-8 -*-
"""检查 GLB 里的动作有没有"真的在动"（纯数据分析，不经 Blender、不改文件）。

为什么需要它：2026-11-07 踩过一个大坑 —— 「工具/加举盾动作.py」走 Blender ACTIONS
导出时，把除 shield_hold 以外的所有动作的骨骼旋转曲线写成了**常量**。
引擎里 AnimationPlayer 在播、轨道在推进，肉眼却是"所有动画都没了"。
只数"channels 有几条"是看不出来的（轨道一条不少），必须看**数值有没有变化**。

判定口径：
  · 对每条 rotation 轨道，算它与首帧的最大四元数夹角（度）；
  · 夹角 > 1 度记为"这条骨骼在动"；
  · 一个动作里在动的骨骼数为 0 → 这个动作是死的（引擎里就是"动画没了"）。

用法：
  python 工具/检查glb动作.py 美术/模型/方块人/方块人_联盟步兵.glb [更多.glb ...]
  python 工具/检查glb动作.py --all            # 扫 美术/模型 下全部 glb
"""
import json
import math
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.path.join(ROOT, "美术", "模型")

CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
      5125: ("I", 4), 5126: ("f", 4)}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, _ver, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError("不是 GLB")
    off = 12
    js = None
    bin_ = None
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            bin_ = chunk
        off += 8 + clen
    return js, bin_


def read_acc(g, bin_, idx):
    acc = g["accessors"][idx]
    bv = g["bufferViews"][acc["bufferView"]]
    off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    fmt, size = CT[acc["componentType"]]
    n = NC[acc["type"]]
    stride = bv.get("byteStride") or size * n
    out = []
    for i in range(acc["count"]):
        out.append(struct.unpack_from("<" + fmt * n, bin_, off + i * stride))
    return out


def q_angle(a, b):
    d = abs(sum(x * y for x, y in zip(a, b)))
    d = max(-1.0, min(1.0, d))
    return math.degrees(2 * math.acos(d))


def report(path):
    g, bin_ = load_glb(path)
    names = [n.get("name", "?") for n in g.get("nodes", [])]
    anims = g.get("animations", [])
    print("=" * 78)
    print("%s  %.1f KB  动作 %d 个" % (os.path.relpath(path, ROOT),
                                       os.path.getsize(path) / 1024.0, len(anims)))
    dead = []
    for a in anims:
        dur = 0.0
        moving = []
        for ch in a.get("channels", []):
            s = a["samplers"][ch["sampler"]]
            times = read_acc(g, bin_, s["input"])
            vals = read_acc(g, bin_, s["output"])
            if times:
                dur = max(dur, times[-1][0])
            if ch["target"]["path"] != "rotation" or len(vals) < 2:
                continue
            mx = max(q_angle(vals[0], v) for v in vals[1:])
            if mx > 1.0:
                node = ch["target"].get("node")
                moving.append((names[node] if node is not None else "?",
                               round(mx, 1)))
        moving.sort(key=lambda x: -x[1])
        flag = "死" if not moving else "活"
        print("  [%s] %-14s %5.2fs  在动骨骼 %2d   %s" % (
            flag, a.get("name", "?"), dur, len(moving),
            " ".join("%s:%.0fdeg" % (n, d) for n, d in moving[:5])))
        if not moving:
            dead.append(a.get("name", "?"))
    if dead:
        print("  [!] 这些动作在引擎里等于没有动画：%s" % ", ".join(dead))
    return dead


def main():
    args = sys.argv[1:]
    if not args or args == ["--all"]:
        targets = []
        for dirpath, _dirs, files in os.walk(MODEL_DIR):
            for f in files:
                if f.lower().endswith(".glb"):
                    targets.append(os.path.join(dirpath, f))
    else:
        targets = [a if os.path.isabs(a) else os.path.join(ROOT, a) for a in args]
    bad = 0
    for t in targets:
        try:
            if report(t):
                bad += 1
        except Exception as e:  # noqa: BLE001
            print("ERR %s: %s" % (t, e))
    print("\n合计 %d 个文件，其中 %d 个含死动作" % (len(targets), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
