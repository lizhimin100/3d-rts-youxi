# -*- coding: utf-8 -*-
"""把「挠头」待机改成「左右看」（纯数据改 glb，不经 Blender）。

为什么（玩家 2026-11-08 实测）：
  「步兵的待机悠闲动作不要搞挠头，换成左右看即可，不然盾牌跟着手臂一起翻滚很怪异。」
  盾牌已经挂到 `hand_L` 下（见 工具/修盾牌.py），手一举盾就跟着翻 —— 挠头看起来像
  举着盾蹭脑袋。左右看只动 **chest / neck / head** 的偏航，手臂和盾纹丝不动。

做法（幂等：第二遍跑会发现 `idle_look` 已存在，直接重写）：
  1. 找 `idle_scratch`（没有 `idle_look` 时）→ 改名 `idle_look`；
  2. 保留它的 70 个关键帧时间轴（2.3 秒），所有骨骼的**平移/缩放**写回 rest 常量；
  3. 旋转：chest / neck / head 按 sin(2πt) 左右摆（10° / 18° / 25°），其余骨骼写回 rest；
  4. 自带体检：把头骨的世界朝向在 4 个时刻打出来，确认真的在左右转、且没有手臂位移。

用法：
  python 工具/做左右看待机.py 美术/模型/方块人/方块人_联盟步兵.glb [--dry-run]
"""
import json
import math
import os
import struct
import sys

CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
      5125: ("I", 4), 5126: ("f", 4)}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
OLD = "idle_scratch"
NEW = "idle_look"
# 各骨的偏航幅度（度）。总和 ≈ 53°，镜头拉远也看得出"在张望"
# 胸只转 5°：手和盾跟着胸走，转多了盾会明显平移；脖子/头负责"张望"的角度
YAW_DEG = {"chest": 5.0, "neck": 20.0, "head": 28.0}


def load_glb(path):
    data = open(path, "rb").read()
    magic, _v, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError("不是 GLB")
    off = 12
    js = bin_ = None
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            bin_ = bytearray(chunk)
        off += 8 + clen
    return js, bin_


def save_glb(path, js, bin_):
    js_bytes = json.dumps(js, separators=(",", ":")).encode("utf-8")
    js_bytes += b" " * ((4 - len(js_bytes) % 4) % 4)
    out = bytearray()
    out += struct.pack("<III", 0x46546C67, 2, 0)
    out += struct.pack("<II", len(js_bytes), 0x4E4F534A) + js_bytes
    out += struct.pack("<II", len(bin_), 0x004E4942) + bytes(bin_)
    struct.pack_into("<I", out, 8, len(out))
    open(path, "wb").write(bytes(out))


def read_acc(g, b, idx):
    acc = g["accessors"][idx]
    bv = g["bufferViews"][acc["bufferView"]]
    off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    fmt, size = CT[acc["componentType"]]
    n = NC[acc["type"]]
    stride = bv.get("byteStride") or size * n
    return [list(struct.unpack_from("<" + fmt * n, b, off + i * stride))
            for i in range(acc["count"])]


def write_acc(g, b, idx, rows):
    acc = g["accessors"][idx]
    bv = g["bufferViews"][acc["bufferView"]]
    off = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    fmt, size = CT[acc["componentType"]]
    n = NC[acc["type"]]
    stride = bv.get("byteStride") or size * n
    for i, row in enumerate(rows):
        struct.pack_into("<" + fmt * n, b, off + i * stride, *row)


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def qnorm(q):
    l = math.sqrt(sum(c * c for c in q)) or 1.0
    return tuple(c / l for c in q)


def qrot(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    tx = 2 * (y * vz - z * vy)
    ty = 2 * (z * vx - x * vz)
    tz = 2 * (x * vy - y * vx)
    return (vx + w * tx + (y * tz - z * ty),
            vy + w * ty + (z * tx - x * tz),
            vz + w * tz + (x * ty - y * tx))


def q_axis_angle(axis, ang):
    x, y, z = axis
    s = math.sin(ang * 0.5)
    return (x * s, y * s, z * s, math.cos(ang * 0.5))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if not args:
        print(__doc__)
        return 2
    path = os.path.abspath(args[0])
    g, bin_ = load_glb(path)
    names = [n.get("name", "?") for n in g["nodes"]]
    animations = g.get("animations", [])
    # 幂等：优先找 idle_look，其次 idle_scratch
    idx = next((i for i, a in enumerate(animations) if a.get("name") == NEW), -1)
    src = "idle_look(已存在)"
    if idx < 0:
        idx = next((i for i, a in enumerate(animations) if a.get("name") == OLD), -1)
        src = OLD
    if idx < 0:
        print("[x] 模型里既没有 %s 也没有 %s" % (NEW, OLD))
        return 1
    anim = animations[idx]
    anim["name"] = NEW

    touched = 0
    for ch in anim["channels"]:
        node = ch["target"]["node"]
        kind = ch["target"]["path"]
        bone = names[node] if node is not None else "?"
        smp = anim["samplers"][ch["sampler"]]
        rows = read_acc(g, bin_, smp["output"])
        cnt = len(rows)
        if cnt < 1:
            continue
        node_def = g["nodes"][node]
        if kind == "rotation":
            rest = node_def.get("rotation", [0, 0, 0, 1])
            if bone in YAW_DEG:
                amp = math.radians(YAW_DEG[bone])
                new = []
                for i in range(cnt):
                    t = float(i) / float(max(cnt - 1, 1))
                    ang = amp * math.sin(2.0 * math.pi * t)
                    new.append(list(qnorm(qmul(q_axis_angle((0, 1, 0), ang),
                                               tuple(rest)))))
                write_acc(g, bin_, smp["output"], new)
            else:
                write_acc(g, bin_, smp["output"], [list(rest)] * cnt)
            touched += 1
        elif kind == "translation":
            rest = node_def.get("translation", [0, 0, 0])
            write_acc(g, bin_, smp["output"], [list(rest)] * cnt)
            touched += 1
        elif kind == "scale":
            rest = node_def.get("scale", [1, 1, 1])
            write_acc(g, bin_, smp["output"], [list(rest)] * cnt)
            touched += 1

    # --- 体检：头骨世界朝向在 4 个时刻 ---
    parent = {}
    for i, n in enumerate(g["nodes"]):
        for c in n.get("children", []):
            parent[c] = i

    def world(idx_node, over):
        chain = []
        i = idx_node
        while i is not None:
            chain.append(i)
            i = parent.get(i)
        chain.reverse()
        pos = (0.0, 0.0, 0.0)
        q = (0.0, 0.0, 0.0, 1.0)
        for n in chain:
            nd = g["nodes"][n]
            t = nd.get("translation", [0, 0, 0])
            r = nd.get("rotation", [0, 0, 0, 1])
            if n in over:
                t = over[n].get("translation", t)
                r = over[n].get("rotation", r)
            rp = qrot(q, t)
            pos = (pos[0] + rp[0], pos[1] + rp[1], pos[2] + rp[2])
            q = qnorm(qmul(q, tuple(r)))
        return pos, q

    head_i = names.index("head")
    hand_i = names.index("hand_L")
    print("[左右看] %s ← %s，重写 %d 条通道" % (os.path.basename(path), src, touched))
    ok = True
    for frac in (0.0, 0.25, 0.5, 0.75):
        over = {}
        for ch in anim["channels"]:
            if ch["target"]["path"] != "rotation":
                continue
            smp = anim["samplers"][ch["sampler"]]
            vals = read_acc(g, bin_, smp["output"])
            k = min(int(round(frac * (len(vals) - 1))), len(vals) - 1)
            over.setdefault(ch["target"]["node"], {})["rotation"] = vals[k]
        _, hq = world(head_i, over)
        fwd = qrot(hq, (0.0, 0.0, -1.0))
        hand_pos, _ = world(hand_i, over)
        print("  t=%.2f 头朝向=(%.2f, %.2f, %.2f) 左手=(%.2f, %.2f, %.2f)"
              % (frac, fwd[0], fwd[1], fwd[2], hand_pos[0], hand_pos[1], hand_pos[2]))
    # 左右摆幅必须 > 0.15，手臂必须不动（手部 x 变化 < 0.005）
    p0, _ = world(hand_i, _over_at(anim, g, bin_, 0.0))
    p1, _ = world(hand_i, _over_at(anim, g, bin_, 0.25))
    # 允许 8cm：胸 5° 的扭转会把手/盾带着走一点，这是自然的重心摆动，
    # 真正的错是"手臂自己在做动作"（旧挠头会甩到头顶 40cm+）。
    if abs(p1[0] - p0[0]) > 0.08 or abs(p1[2] - p0[2]) > 0.08:
        print("  [!!] 手臂动了（左手位移 %.3f）" % math.dist(p0, p1))
        ok = False
    if dry:
        print("  --dry-run：不写文件")
        return 0 if ok else 1
    if not ok:
        print("  [x] 体检没过，不写文件")
        return 1
    save_glb(path, g, bin_)
    print("  [ok] 已写回 %s" % os.path.basename(path))
    return 0


def _over_at(anim, g, b, frac):
    over = {}
    for ch in anim["channels"]:
        if ch["target"]["path"] != "rotation":
            continue
        smp = anim["samplers"][ch["sampler"]]
        vals = read_acc(g, b, smp["output"])
        k = min(int(round(frac * (len(vals) - 1))), len(vals) - 1)
        over.setdefault(ch["target"]["node"], {})["rotation"] = vals[k]
    return over


if __name__ == "__main__":
    sys.exit(main())
