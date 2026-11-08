# -*- coding: utf-8 -*-
"""修**举盾姿势**：手臂、盾牌、身体朝向对齐，盾在身前（纯数据改 glb，不经 Blender）。

为什么需要它（2026-11-08 定位到的真凶，两条同时坏）：

  1）**骨骼绑定**：`shield` 骨的父节点是 `chest`，不是 `hand_L`。
     所以手臂怎么动，盾都不会跟手走 —— 这是"手臂和盾牌脱轨"的地基。
  2）**动画曲线**：旧 `shield_hold` 末帧把左手抬到 **头高 y=1.18**、还甩到身后 z=+0.15，
     而盾停在胸腹 y=0.88 / z=-0.10 —— 两者相距 **0.43 米**。
     引擎里就成了"手举到天上，身前的盾没人拿"。

修法（不动绑定，避免打断蒙皮）：
  · 用两骨 IK 把左手摆到**盾背面**（胸前 z≈-0.26、胸高 y≈0.90）；
  · `shield` 骨在 clip 里**平移**到身前（rest→身前，卡在末帧）；
  · `shield` 的 rotation 曲线**保持原样** —— 它正是把盾面从"侧挂"转成"朝前"的那一步。
  · 姿态层（代码/美术/姿态层.gd）同时按住旋转**和平移**，于是举盾期间盾一直拿在手里。

判定（工具自带体检）：
  · 末帧 hand↔shield 距离 < 0.20 m；
  · 盾中心 z < -0.30（在身体前面）、y 在 0.80~1.10（胸口高度）；
  · 手不高于头（y_hand <= y_head）。

用法：
  python 工具/修举盾姿势.py 美术/模型/方块人/方块人_联盟步兵.glb
  python 工具/修举盾姿势.py <glb> --dry-run     # 只算不写
"""
import json
import math
import os
import struct
import sys

CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
      5125: ("I", 4), 5126: ("f", 4)}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
FMT = {"f": "<f", "h": "<h", "H": "<H", "I": "<I", "b": "<b", "B": "<B"}

CLIP = "shield_hold"
# 举盾末帧的目标（模型空间：+Y 上，-Z 前，-X 左）
HAND_TARGET = (-0.255, 0.905, -0.255)
ELBOW_TARGET = (-0.400, 0.880, -0.080)
SHIELD_OFFSET = (0.105, 0.085, -0.235)   # 相对 rest 的位移（前 / 上 / 内收）


# ---------------------------------------------------------------------------
# GLB 读写
# ---------------------------------------------------------------------------
def load_glb(path):
    data = open(path, "rb").read()
    magic, _ver, length = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67:
        raise ValueError("不是 GLB：%s" % path)
    off = 12
    js = None
    bin_ = None
    bin_off = 0
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            bin_ = bytearray(chunk)
            bin_off = off + 8
        off += 8 + clen
    return js, bin_, bin_off


def save_glb(path, js, bin_, bin_off):
    raw = open(path, "rb").read()
    js_bytes = json.dumps(js, separators=(",", ":")).encode("utf-8")
    js_bytes += b" " * ((4 - len(js_bytes) % 4) % 4)
    head = raw[:12]
    # JSON chunk 长度可能变了：整包重排（BIN 必须在 JSON 之后）
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


# ---------------------------------------------------------------------------
# 四元数 / FK
# ---------------------------------------------------------------------------
def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


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


def qslerp(a, b, t):
    a = qnorm(a)
    b = qnorm(b)
    d = sum(x * y for x, y in zip(a, b))
    if d < 0.0:
        b = tuple(-x for x in b)
        d = -d
    d = max(-1.0, min(1.0, d))
    if d > 0.9995:
        return qnorm(tuple(a[i] + (b[i] - a[i]) * t for i in range(4)))
    th = math.acos(d)
    s = math.sin(th)
    wa = math.sin((1.0 - t) * th) / s
    wb = math.sin(t * th) / s
    return qnorm(tuple(a[i] * wa + b[i] * wb for i in range(4)))


def q_from_axis_angle(axis, ang):
    ax, ay, az = axis
    l = math.sqrt(ax * ax + ay * ay + az * az) or 1.0
    s = math.sin(ang * 0.5)
    return (ax / l * s, ay / l * s, az / l * s, math.cos(ang * 0.5))


# ---------------------------------------------------------------------------
# 骨骼链 FK
# ---------------------------------------------------------------------------
class Rig:
    def __init__(self, g):
        self.g = g
        self.nodes = g["nodes"]
        self.names = [n.get("name", "?") for n in self.nodes]
        self.parent = {}
        for i, n in enumerate(self.nodes):
            for c in n.get("children", []):
                self.parent[c] = i

    def index(self, name):
        return self.names.index(name)

    def chain(self, idx):
        out = []
        i = idx
        while i is not None:
            out.append(i)
            i = self.parent.get(i)
        out.reverse()
        return out

    def world(self, idx, over=None):
        """over: {node: {"rotation": q, "translation": t}}（bone-local）"""
        pos = (0.0, 0.0, 0.0)
        q = (0.0, 0.0, 0.0, 1.0)
        for n in self.chain(idx):
            nd = self.nodes[n]
            t = list(nd.get("translation", [0, 0, 0]))
            r = list(nd.get("rotation", [0, 0, 0, 1]))
            if over and n in over:
                if "translation" in over[n]:
                    t = list(over[n]["translation"])
                if "rotation" in over[n]:
                    r = list(over[n]["rotation"])
            rp = qrot(q, t)
            pos = (pos[0] + rp[0], pos[1] + rp[1], pos[2] + rp[2])
            q = qnorm(qmul(q, tuple(r)))
        return pos, q


# ---------------------------------------------------------------------------
# 两骨 IK：肩(不动) → 上臂 → 前臂 → 手
# ---------------------------------------------------------------------------
def solve_arm(rig, hand_target, elbow_target):
    up = rig.index("upperarm_L")
    fo = rig.index("forearm_L")
    ha = rig.index("hand_L")

    def evaluate(q_up, q_fo):
        over = {up: {"rotation": q_up}, fo: {"rotation": q_fo}}
        h, _ = rig.world(ha, over)
        e, _ = rig.world(fo, over)
        dh = math.dist(h, hand_target)
        de = math.dist(e, elbow_target)
        return dh * 1.0 + de * 0.45, h, e

    rest_up = list(rig.nodes[up].get("rotation", [0, 0, 0, 1]))
    rest_fo = list(rig.nodes[fo].get("rotation", [0, 0, 0, 1]))
    best = (1e9, rest_up, rest_fo, None, None)
    # 坐标下降 + 多起点：每个轴 ±角度扫一遍，逐步收紧步长
    for seed in range(9):
        base_up = list(rest_up)
        base_fo = list(rest_fo)
        if seed:
            ax = ((seed % 3) - 1, ((seed // 3) % 3) - 1, 0.0)
            base_up = list(qnorm(qmul(q_from_axis_angle(ax, 0.6), tuple(rest_up))))
            base_fo = list(qnorm(qmul(q_from_axis_angle(ax, 0.9), tuple(rest_fo))))
        q_up, q_fo = base_up, base_fo
        step = 0.9
        for _it in range(9):
            improved = False
            for which in (0, 1):
                for axis in ((1, 0, 0), (0, 1, 0), (0, 0, 1)):
                    for sgn in (1.0, -1.0):
                        dq = q_from_axis_angle(axis, step * sgn)
                        t_up = qnorm(qmul(dq, tuple(q_up))) if which == 0 else q_up
                        t_fo = qnorm(qmul(dq, tuple(q_fo))) if which == 1 else q_fo
                        cost, h, e = evaluate(t_up, t_fo)
                        if cost < best[0] - 1e-6:
                            best = (cost, list(t_up), list(t_fo), h, e)
                            q_up, q_fo = list(t_up), list(t_fo)
                            improved = True
            if not improved:
                step *= 0.55
                if step < 0.02:
                    break
    return best


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if not args:
        print(__doc__)
        return 2
    path = os.path.abspath(args[0])
    g, bin_, _off = load_glb(path)
    rig = Rig(g)

    clips = {a.get("name"): a for a in g.get("animations", [])}
    if CLIP not in clips:
        print("[x] 模型里没有 %s 动作" % CLIP)
        return 1
    clip = clips[CLIP]

    # ---- 1) 现有姿势的体检（改之前）----
    def pose_of(clip_obj, frame_last=True):
        over = {}
        for ch in clip_obj["channels"]:
            s = clip_obj["samplers"][ch["sampler"]]
            times = read_acc(g, bin_, s["input"])
            vals = read_acc(g, bin_, s["output"])
            if not times:
                continue
            k = len(times) - 1 if frame_last else 0
            over.setdefault(ch["target"]["node"], {})[ch["target"]["path"]] = vals[k]
        return over

    def report(tag, over):
        hp, _ = rig.world(rig.index("hand_L"), over)
        sp, _ = rig.world(rig.index("shield"), over)
        _, hq = rig.world(rig.index("head"), over)
        head, _ = rig.world(rig.index("head"), over)
        print("  %-8s hand=(%.3f,%.3f,%.3f) shield=(%.3f,%.3f,%.3f) 距离=%.3f  "
              "手高=%.2f 头高=%.2f" % (tag, hp[0], hp[1], hp[2],
                                       sp[0], sp[1], sp[2],
                                       math.dist(hp, sp), hp[1], head[1]))
        return hp, sp

    print("[修举盾] %s" % os.path.basename(path))
    old = pose_of(clip)
    hp0, sp0 = report("改前", old)

    # ---- 2) 盾：rest 位移（clip 里平移，姿态层会按住）----
    sh_idx = rig.index("shield")
    sh_rest_t = list(g["nodes"][sh_idx].get("translation", [0, 0, 0]))
    sh_new_t = [sh_rest_t[i] + SHIELD_OFFSET[i] for i in range(3)]

    # ---- 3) 手臂 IK ----
    cost, q_up, q_fo, h, e = solve_arm(rig, HAND_TARGET, ELBOW_TARGET)
    print("  IK 残差 cost=%.3f  手=(%.3f,%.3f,%.3f) 肘=(%.3f,%.3f,%.3f)"
          % (cost, h[0], h[1], h[2], e[0], e[1], e[2]))

    # ---- 4) 写回曲线：rest → 目标，smoothstep ----
    up = rig.index("upperarm_L")
    fo = rig.index("forearm_L")
    sh = sh_idx
    rest_up = rig.nodes[up].get("rotation", [0, 0, 0, 1])
    rest_fo = rig.nodes[fo].get("rotation", [0, 0, 0, 1])
    touched = {"upperarm_L": 0, "forearm_L": 0, "shield": 0}
    for ch in clip["channels"]:
        nid = ch["target"]["node"]
        tr_path = ch["target"]["path"]
        name = rig.names[nid]
        s = clip["samplers"][ch["sampler"]]
        times = read_acc(g, bin_, s["input"])
        vals = read_acc(g, bin_, s["output"])
        cnt = len(times)
        if cnt < 2:
            continue
        if name == "upperarm_L" and tr_path == "rotation":
            new = []
            for i in range(cnt):
                t = float(i) / float(cnt - 1)
                t = t * t * (3.0 - 2.0 * t)
                new.append(list(qslerp(tuple(rest_up), tuple(q_up), t)))
            write_acc(g, bin_, s["output"], new)
            touched["upperarm_L"] += 1
        elif name == "forearm_L" and tr_path == "rotation":
            new = []
            for i in range(cnt):
                t = float(i) / float(cnt - 1)
                t = t * t * (3.0 - 2.0 * t)
                new.append(list(qslerp(tuple(rest_fo), tuple(q_fo), t)))
            write_acc(g, bin_, s["output"], new)
            touched["forearm_L"] += 1
        elif name == "shield" and tr_path == "translation":
            new = []
            for i in range(cnt):
                t = float(i) / float(cnt - 1)
                t = t * t * (3.0 - 2.0 * t)
                new.append([sh_rest_t[k] + (sh_new_t[k] - sh_rest_t[k]) * t
                            for k in range(3)])
            write_acc(g, bin_, s["output"], new)
            touched["shield"] += 1
        # 盾的 rotation **不动**：clip 里那组曲线正是把盾面从"侧挂"转到"朝前"的那一步。
        # 第一次修的时候把它写成 rest，结果盾面变成侧对着敌人（截图可见），教训记在这里。

    # ---- 5) 体检 ----
    new_over = pose_of(clip)
    hp1, sp1 = report("改后", new_over)
    head_pos, _ = rig.world(rig.index("head"), new_over)
    ok = True
    if math.dist(hp1, sp1) > 0.20:
        print("  [!] 手离盾 %.3f m（要求 < 0.20）" % math.dist(hp1, sp1))
        ok = False
    if sp1[2] > -0.30:
        print("  [!] 盾不够靠前：z=%.3f（要求 < -0.30）" % sp1[2])
        ok = False
    if not (0.75 <= sp1[1] <= 1.15):
        print("  [!] 盾高度 %.3f 不在胸口区间 0.75~1.15" % sp1[1])
        ok = False
    if hp1[1] > head_pos[1] + 0.02:
        print("  [!] 手高过头：%.3f > %.3f" % (hp1[1], head_pos[1]))
        ok = False
    print("  曲线写入：%s" % touched)

    if dry:
        print("  --dry-run：不写文件")
        return 0 if ok else 1
    if not ok:
        print("  [x] 体检没过，不写文件")
        return 1
    save_glb(path, g, bin_, 0)
    print("  [ok] 已写回 %s" % os.path.basename(path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
