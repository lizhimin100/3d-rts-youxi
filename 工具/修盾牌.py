# -*- coding: utf-8 -*-
"""修**盾牌**（纯数据改 glb，不经 Blender）：把 `shield` 骨挂到 `hand_L` 下并重新绑定，
再把 `shield_hold` 的举盾姿势解出来（手不穿模、盾在身前、盾面朝前）。

为什么必须改绑定（2026-11-08 玩家实测反馈）：
  · `shield` 骨的父节点是 `chest`，不是手 —— 手臂一动，盾就留在原地。
    举盾时手抬到头顶、待机"挠头"时手也去头顶，盾永远贴在胸口 → 看着像"人和盾脱轨"。
  · 旧 `shield_hold` 末帧把手抬到头高（y=1.18）、甩到身后（z=+0.15），
    盾停在胸腹 y=0.88，两者相距 0.43m —— 手直接从盾面里穿过去。

本工具做三件事（可重复跑，第二遍是幂等的）：
  1) **重新绑定**：`shield` 的父节点改成 `hand_L`，局部变换让盾的几何中心落在手里
     （掌心上 6cm、前 10cm），朝向保持美术摆的原样；
  2) **重解举盾**：三骨数值求解（upperarm_L / forearm_L / hand_L 的旋转），目标是
     · 盾几何中心到"身前 0.44m、胸高 0.98m、偏左 0.26m"
     · 盾面法线尽量朝 -Z（正前方）
     · 手不过头
  3) **写回曲线**：`shield_hold` 里这三根骨的关键帧按 rest → 目标做 smoothstep；
     `shield` 自己的平移/旋转写成新绑定下的常量（盾在手里不动）。

判定（自带体检，不过就不写文件）：
  · 盾中心 z < -0.30（在身体前面）、y 在 0.85~1.10（胸口）
  · 盾面法线 · 正前方 > 0.90
  · 手 ≤ 头高，且手到盾中心的距离 0.10~0.22m（握着，不穿模）

用法：
  python 工具/修盾牌.py 美术/模型/方块人/方块人_联盟步兵.glb
  python 工具/修盾牌.py <glb> --dry-run
"""
import json
import math
import os
import struct
import sys

CT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
      5125: ("I", 4), 5126: ("f", 4)}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

CLIP = "shield_hold"
SHIELD = "shield"
HOST = "hand_L"
# 盾几何中心相对手掌的目标偏移（模型空间：+Y 上，-Z 前，-X 左）
# 盾几何中心相对手掌的目标偏移。
# 第一版用 (-0.02, 0.06, -0.10)：盾直接压在胯骨上，截图里和腿/腰糊成一片蓝块。
# 现在往**外侧**推 0.14m、略微前一点 —— 读起来是"手垂在身侧、盾挂在小臂外"，不穿模。
GRIP_OFFSET = (-0.14, 0.00, -0.07)
# 举盾末帧：盾几何中心的目标位置 + 期望法线
SHIELD_TARGET = (-0.26, 0.98, -0.44)
FACE_WANT = (0.0, 0.0, -1.0)
# 盾面法线（rest 时由徽记相对盾体的方向估出来；见 _face_normal_rest）
FACE_REST = (-0.85, 0.30, -0.53)


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


def q_axis_angle(axis, ang):
    ax, ay, az = axis
    l = math.sqrt(ax * ax + ay * ay + az * az) or 1.0
    s = math.sin(ang * 0.5)
    return (ax / l * s, ay / l * s, az / l * s, math.cos(ang * 0.5))


def vsub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vadd(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def vlen(a):
    return math.sqrt(a[0] ** 2 + a[1] ** 2 + a[2] ** 2)


def vdot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def vnorm(a):
    l = vlen(a) or 1.0
    return (a[0] / l, a[1] / l, a[2] / l)


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
# 盾的几何中心（蒙皮到 shield 的顶点均值）
# ---------------------------------------------------------------------------
def shield_centroid(g, b, rig):
    si = rig.index(SHIELD)
    joints = g["skins"][0]["joints"]
    verts = []
    for m in g["meshes"]:
        for prim in m["primitives"]:
            at = prim["attributes"]
            if "JOINTS_0" not in at:
                continue
            pos = read_acc(g, b, at["POSITION"])
            jts = read_acc(g, b, at["JOINTS_0"])
            wts = read_acc(g, b, at["WEIGHTS_0"])
            for v, j, w in zip(pos, jts, wts):
                tot = 0.0
                for k in range(4):
                    if joints[j[k]] == si:
                        tot += w[k]
                if tot > 0.5:
                    verts.append(v)
    if not verts:
        return (0.0, 0.0, 0.0)
    n = float(len(verts))
    return (sum(v[0] for v in verts) / n, sum(v[1] for v in verts) / n,
            sum(v[2] for v in verts) / n)


# ---------------------------------------------------------------------------
# 步骤 1：把盾挂到手上
# ---------------------------------------------------------------------------
def reparent_to_hand(rig, g, centroid_world):
    si = rig.index(SHIELD)
    hi = rig.index(HOST)
    parent = rig.parent.get(si)
    if parent == hi:
        return False, "已经在 %s 下（跳过重绑）" % HOST
    hand_pos, hand_q = rig.world(hi)
    sh_pos, sh_q = rig.world(si)
    # 盾几何中心相对盾骨
    c_rel = qrot(qconj(sh_q), vsub(centroid_world, sh_pos))
    # 想让几何中心落在手里（掌心上方一点、前一点）
    c_target = vadd(hand_pos, GRIP_OFFSET)
    # 盾骨世界位置 = 目标中心 − R * c_rel（朝向保持原样）
    bone_pos = vsub(c_target, qrot(sh_q, c_rel))
    # 换成 hand 空间的局部变换
    local_pos = qrot(qconj(hand_q), vsub(bone_pos, hand_pos))
    local_q = qnorm(qmul(qconj(hand_q), sh_q))
    # 改父子关系
    old = g["nodes"][parent]
    if si in old.get("children", []):
        old["children"].remove(si)
    g["nodes"][hi].setdefault("children", []).append(si)
    g["nodes"][si]["translation"] = [round(x, 6) for x in local_pos]
    g["nodes"][si]["rotation"] = [round(x, 6) for x in local_q]
    rig.parent[si] = hi
    return True, "已把 shield 挂到 %s（局部 %s）" % (HOST, [round(x, 3) for x in local_pos])


# ---------------------------------------------------------------------------
# 步骤 2：解举盾姿势（盾中心到目标 + 盾面朝前）
# ---------------------------------------------------------------------------
def solve_pose(rig, centroid_local, face_rest, base_over):
    """数值解：三根骨（upperarm / forearm / hand）的旋转。

    为什么先粗网格：只从 rest 做坐标下降会陷在"手臂几乎没动"的局部极小 ——
    肩骨本身带 77° 滚转，同样的上臂旋转在真机上指向完全不同的方向。
    所以先扫一遍 (上臂绕 Y, 上臂绕 X, 前臂绕 Z) 的粗网格，再从最好的几个点细化。
    """
    up = rig.index("upperarm_L")
    fo = rig.index("forearm_L")
    ha = rig.index("hand_L")
    si = rig.index(SHIELD)
    rest_up = list(rig.nodes[up].get("rotation", [0, 0, 0, 1]))
    rest_fo = list(rig.nodes[fo].get("rotation", [0, 0, 0, 1]))
    rest_ha = list(rig.nodes[ha].get("rotation", [0, 0, 0, 1]))
    _, sh_rest_q = rig.world(si)

    def measure(q_up, q_fo, q_ha):
        over = dict(base_over)
        over[up] = {"rotation": q_up}
        over[fo] = {"rotation": q_fo}
        over[ha] = {"rotation": q_ha}
        h_pos, _ = rig.world(ha, over)
        s_pos, s_q = rig.world(si, over)
        c = vadd(s_pos, qrot(s_q, centroid_local))
        delta = qmul(s_q, qconj(sh_rest_q))
        n = vnorm(qrot(delta, face_rest))
        return c, n, h_pos

    def cost_of(q_up, q_fo, q_ha, w_face):
        c, n, h = measure(q_up, q_fo, q_ha)
        dpos = vlen(vsub(c, SHIELD_TARGET))
        dface = 1.0 - vdot(n, FACE_WANT)
        over_head = max(0.0, h[1] - 1.15) * 3.0
        return dpos + w_face * dface + over_head

    def descend(q_up, q_fo, q_ha, w_face, step0=0.6):
        step = step0
        best = (cost_of(q_up, q_fo, q_ha, w_face), list(q_up), list(q_fo), list(q_ha))
        for _it in range(16):
            improved = False
            for which in (0, 1, 2):
                for axis in ((1, 0, 0), (0, 1, 0), (0, 0, 1)):
                    for sgn in (1.0, -1.0):
                        dq = q_axis_angle(axis, step * sgn)
                        t_up = qnorm(qmul(dq, tuple(best[1]))) if which == 0 else best[1]
                        t_fo = qnorm(qmul(dq, tuple(best[2]))) if which == 1 else best[2]
                        t_ha = qnorm(qmul(dq, tuple(best[3]))) if which == 2 else best[3]
                        cst = cost_of(t_up, t_fo, t_ha, w_face)
                        if cst < best[0] - 1e-6:
                            best = (cst, list(t_up), list(t_fo), list(t_ha))
                            improved = True
            if not improved:
                step *= 0.55
                if step < 0.01:
                    break
        return best

    # --- 粗网格：上臂 Y×5、上臂 X×5、前臂 Z×3 ---
    coarse = []
    for ay in (-1.8, -1.2, -0.6, 0.0, 0.6):
        for ax in (-0.9, -0.45, 0.0, 0.45, 0.9):
            qu = qnorm(qmul(qmul(q_axis_angle((0, 1, 0), ay), q_axis_angle((1, 0, 0), ax)),
                            tuple(rest_up)))
            for az in (-1.0, 0.0, 1.0):
                qf = qnorm(qmul(q_axis_angle((0, 0, 1), az), tuple(rest_fo)))
                cst = cost_of(list(qu), list(qf), list(rest_ha), 0.0)
                coarse.append((cst, list(qu), list(qf)))
    coarse.sort(key=lambda t: t[0])
    best1 = (1e9, list(rest_up), list(rest_fo), list(rest_ha))
    for _, qu, qf in coarse[:4]:
        r = descend(qu, qf, list(rest_ha), 0.0)
        if r[0] < best1[0]:
            best1 = r
    best2 = descend(best1[1], best1[2], best1[3], 1.8)
    cst = cost_of(best2[1], best2[2], best2[3], 1.8)
    c, n, h = measure(best2[1], best2[2], best2[3])
    return (cst, best2[1], best2[2], best2[3], c, n, h)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if not args:
        print(__doc__)
        return 2
    path = os.path.abspath(args[0])
    g, bin_ = load_glb(path)
    rig = Rig(g)
    clips = {a.get("name"): a for a in g.get("animations", [])}
    if CLIP not in clips:
        print("[x] 没有 %s 动作" % CLIP)
        return 1
    clip = clips[CLIP]

    print("[修盾牌] %s" % os.path.basename(path))
    # --- 1) 重绑 ---
    c_world = shield_centroid(g, bin_, rig)
    changed, msg = reparent_to_hand(rig, g, c_world)
    print("  " + msg)
    si = rig.index(SHIELD)
    sh_pos, sh_q = rig.world(si)
    centroid_local = qrot(qconj(sh_q), vsub(c_world, sh_pos))

    # ★ 所有动作里 shield 的平移/旋转轨道都要改成**新绑定下的常量**。
    #   旧数据是 chest 空间的（-0.366, -0.046, -0.138），换了父节点之后
    #   这些值会把盾甩到身体右侧去（实测 idle 时盾跑到了 x=+0.05）。
    t_new = rig.nodes[si].get("translation", [0, 0, 0])
    r_new = rig.nodes[si].get("rotation", [0, 0, 0, 1])
    touched = 0
    for anim in g.get("animations", []):
        for ch in anim["channels"]:
            if ch["target"]["node"] != si:
                continue
            kind_a = ch["target"]["path"]
            smp = anim["samplers"][ch["sampler"]]
            vals_a = read_acc(g, bin_, smp["output"])
            if len(vals_a) < 1:
                continue
            if kind_a == "translation":
                write_acc(g, bin_, smp["output"], [list(t_new)] * len(vals_a))
                touched += 1
            elif kind_a == "rotation":
                write_acc(g, bin_, smp["output"], [list(r_new)] * len(vals_a))
                touched += 1
    print("  盾的曲线改成新绑定常量：%d 条（跨全部动作）" % touched)

    # 取 clip 末帧的 shoulder/chest 作为求解基准（pose layer 只按住手臂，胸不管）
    base_over = {}
    for ch in clip["channels"]:
        nm = rig.names[ch["target"]["node"]]
        if nm in ("shoulder_L", "chest"):
            s = clip["samplers"][ch["sampler"]]
            vals = read_acc(g, bin_, s["output"])
            path_kind = ch["target"]["path"]
            base_over.setdefault(ch["target"]["node"], {})[path_kind] = vals[-1]

    # --- 2) 解姿势 ---
    cost, q_up, q_fo, q_ha, c, n, h = solve_pose(rig, centroid_local, FACE_REST, base_over)
    if c is None:
        print("  [x] 求解失败")
        return 1
    print("  cost=%.3f  盾心=(%.3f,%.3f,%.3f)  法线=(%.2f,%.2f,%.2f)  手=(%.3f,%.3f,%.3f)"
          % (cost, c[0], c[1], c[2], n[0], n[1], n[2], h[0], h[1], h[2]))

    # --- 3) 写回曲线 ---
    rest_q = {
        "upperarm_L": rig.nodes[rig.index("upperarm_L")].get("rotation", [0, 0, 0, 1]),
        "forearm_L": rig.nodes[rig.index("forearm_L")].get("rotation", [0, 0, 0, 1]),
        "hand_L": rig.nodes[rig.index("hand_L")].get("rotation", [0, 0, 0, 1]),
    }
    target_q = {"upperarm_L": q_up, "forearm_L": q_fo, "hand_L": q_ha}
    for ch in clip["channels"]:
        nm = rig.names[ch["target"]["node"]]
        kind = ch["target"]["path"]
        s = clip["samplers"][ch["sampler"]]
        vals = read_acc(g, bin_, s["output"])
        cnt = len(vals)
        if cnt < 2:
            continue
        if nm in target_q and kind == "rotation":
            new = []
            for i in range(cnt):
                t = float(i) / float(cnt - 1)
                t = t * t * (3.0 - 2.0 * t)
                new.append(list(qslerp(tuple(rest_q[nm]), tuple(target_q[nm]), t)))
            write_acc(g, bin_, s["output"], new)
        elif nm == SHIELD:
            # 盾现在是手的刚体子节点：曲线写成新绑定下的常量（别让动画把它拽走）
            if kind == "translation":
                t0 = rig.nodes[si].get("translation", [0, 0, 0])
                write_acc(g, bin_, s["output"], [list(t0)] * cnt)
            elif kind == "rotation":
                r0 = rig.nodes[si].get("rotation", [0, 0, 0, 1])
                write_acc(g, bin_, s["output"], [list(r0)] * cnt)

    # --- 4) 体检 ---
    over = dict(base_over)
    over[rig.index("upperarm_L")] = {"rotation": q_up}
    over[rig.index("forearm_L")] = {"rotation": q_fo}
    over[rig.index("hand_L")] = {"rotation": q_ha}
    sp, sq = rig.world(si, over)
    cc = vadd(sp, qrot(sq, centroid_local))
    hh, _ = rig.world(rig.index("hand_L"), over)
    head, _ = rig.world(rig.index("head"), over)
    _, sh_rest_q = rig.world(si)
    nn = vnorm(qrot(qmul(sq, qconj(sh_rest_q)), FACE_REST))
    d_hand_shield = vlen(vsub(hh, cc))
    ok = True
    checks = []
    checks.append(("盾在身前 (z<-0.30)", cc[2] < -0.30, "%.3f" % cc[2]))
    checks.append(("盾在胸口 (0.85<y<1.10)", 0.85 <= cc[1] <= 1.10, "%.3f" % cc[1]))
    checks.append(("盾面朝前 (n·f>0.90)", vdot(nn, FACE_WANT) > 0.90, "%.3f" % vdot(nn, FACE_WANT)))
    checks.append(("手不过头", hh[1] <= head[1] + 0.02, "手 %.2f / 头 %.2f" % (hh[1], head[1])))
    checks.append(("手握着盾 (0.10~0.24m)", 0.10 <= d_hand_shield <= 0.24,
                   "%.3f" % d_hand_shield))
    for label, passed, detail in checks:
        print("  [%s] %-22s %s" % ("ok" if passed else "!!", label, detail))
        ok = ok and passed

    if dry:
        print("  --dry-run：不写文件")
        return 0 if ok else 1
    if not ok:
        print("  [x] 体检没过，不写文件")
        return 1
    save_glb(path, g, bin_)
    print("  [ok] 已写回 %s" % os.path.basename(path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
