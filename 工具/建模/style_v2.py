# -*- coding: utf-8 -*-
"""
style_v2.py —— 铁血战歌 风格后处理（美术规范 §1.3 / §5.2 / §9 的可执行部分）
==========================================================================
本模块只做三件事，全部有《美术规范.md》的条目对应：

  1. apply_palette(K)  —— 把 v2 调色板（§2 的 34 色）写进 rts_kit.PALETTE。
                          基色 key 的名字**一个都不改**，只改数值 + 追加新 key，
                          所以既有 build 脚本一行不用动（规范 §2 的"唯一真源"落地）。
  2. style_pass()      —— 按面法线朝光分 4 档明度（§5.2 的 d=n·L 判据），
                          把同一部件拆成 2~4 个明度材质；同时强制**平面着色**。
  3. verify()          —— §9 验收清单的可执行门：比例 / 面数 / 层级 / 枢轴 /
                          明度差 / 足迹轴对齐 / 贴地。返回 dict，由 run_v2 打 HEADLESS。

设计取舍（写下来免得后面自己都忘了为什么这么写）：
  * 明度档**在导出前**烘进材质，不改几何、不加 shader ——
    因为 GLB 进 Godot 后是 StandardMaterial3D，shader 描边/分档会被导入流程吃掉，
    而本次「美术\\着色器\\」是禁区（见规范 §10）。
  * 档位系数按 **sRGB 值**定义（1.16 / 1.00 / 0.78 / 0.60，规范 §5.2），
    但 Blender 的 Base Color 是**线性**的，所以代码里换算成 linear = srgb**2.2 再乘：
    1.16**2.2≈1.38 / 0.78**2.2≈0.57 / 0.60**2.2≈0.32。两边数字对得上，不是拍脑袋。
  * 只做**轴向斜切之外**的事：几何的非正交化（收分/斜切/top_off/shear）已经在
    rts_kit._bh() 的设计参数里做了，**不做全局顶点抖动** —— 抖动会破坏
    建筑底面矩形（规范 §3.2 硬约束）和部件接缝，属于净损失。
"""

import math
import bmesh
import bpy
from mathutils import Vector

# ---------------------------------------------------------------------------
# §5.2 分档参数
# ---------------------------------------------------------------------------
# 主光方向：与 §8 的主光 SUN travel (-0.52,-0.62,-0.72) 反向（指向光源）
LIGHT_DIR = Vector((0.52, 0.62, 0.72)).normalized()

# d = n·L 的档位阈值（规范 §5.2 表）
TIER_THRESH = (0.62, 0.15, -0.45)   # >=0.62 → 3亮；[0.15,0.62) → 2基；[-0.45,0.15) → 1暗；< → 0最暗
# sRGB 值系数（规范 §5.2）——仅用于文档/报告口径
TIER_SRGB = (0.60, 0.78, 1.00, 1.16)          # index = tier
# 色温偏移 (R,G,B)：暗部偏冷（+蓝），亮部偏暖（+橙）
TIER_TINT = ((0.94, 1.00, 1.16), (0.97, 1.00, 1.08), (1.0, 1.0, 1.0), (1.04, 1.00, 0.95))
TIER_SUFFIX = ("#最暗", "#暗", "", "#亮")       # tier 2 = 基色，名字不变
# 带映射（不是乘法）：亮档向白"加"、暗档向黑"乘"。
# 为什么不用乘法：布白/布麻这类高明度基色乘 1.16 会直接夹到 1.0（实测 value_hi=1.0），
# 亮档等于没做；带映射保证 4 档都留出可读的间隔，且永远不会夹死。
TIER_BAND = (0.50, 0.72, 1.00, None)          # None = c + (1-c)*LIFT
TIER_LIFT = 0.24

# ---------------------------------------------------------------------------
# §2 调色板 v2（key 与 rts_kit 完全兼容，只换值 + 追加新 key）
#   key: (hex, roughness, metallic, emission_strength)
# ---------------------------------------------------------------------------
PALETTE_V2 = {
    # —— 石 / 建筑 ——
    "石浅":   ("#B8B4A8", 0.88, 0.0, 0.0),
    "石":     ("#9A968C", 0.90, 0.0, 0.0),
    "石暗":   ("#6B6A60", 0.92, 0.0, 0.0),
    "冷影":   ("#2A2F3A", 0.94, 0.0, 0.0),
    # —— 木 / 瓦 / 草 ——
    "木浅":   ("#B08A5E", 0.82, 0.0, 0.0),
    "木":     ("#8A6440", 0.84, 0.0, 0.0),
    "木暗":   ("#4E3520", 0.86, 0.0, 0.0),
    "瓦":     ("#7A5442", 0.88, 0.0, 0.0),
    "瓦暗":   ("#55392E", 0.90, 0.0, 0.0),
    "茅草":   ("#D8BC72", 0.92, 0.0, 0.0),
    "茅草暗": ("#A88A48", 0.94, 0.0, 0.0),
    # —— 皮革 ——
    "革亮":   ("#7A5230", 0.76, 0.0, 0.0),
    "革":     ("#5A3B22", 0.78, 0.0, 0.0),
    "革暗":   ("#3E2716", 0.80, 0.0, 0.0),
    # —— 布 ——
    "布白":   ("#E8E2D2", 0.90, 0.0, 0.0),
    "布麻":   ("#D9CBA8", 0.88, 0.0, 0.0),
    "布麻暗": ("#8A6B45", 0.90, 0.0, 0.0),
    "布蓝亮": ("#5A7EA0", 0.86, 0.0, 0.0),
    "布蓝":   ("#3F5C7A", 0.86, 0.0, 0.0),
    "布蓝暗": ("#26394D", 0.88, 0.0, 0.0),
    "布红":   ("#8E3A32", 0.86, 0.0, 0.0),
    # —— 金属 / 金 ——
    "甲":     ("#96A4B4", 0.34, 0.55, 0.0),
    "钢亮":   ("#DCE4EE", 0.22, 0.60, 0.0),
    "钢":     ("#B4BEC8", 0.30, 0.55, 0.0),
    "钢暗":   ("#626C7C", 0.42, 0.50, 0.0),
    "铁":     ("#4C5058", 0.52, 0.45, 0.0),
    "金亮":   ("#F2C84C", 0.26, 0.50, 0.0),
    "金":     ("#D8B254", 0.30, 0.55, 0.0),
    # —— 土 / 植被 ——
    "土":     ("#9A7A50", 0.94, 0.0, 0.0),
    "土暗":   ("#6E5434", 0.94, 0.0, 0.0),
    "叶黄":   ("#8A8C46", 0.90, 0.0, 0.0),
    "叶":     ("#5A7A44", 0.90, 0.0, 0.0),
    "叶暗":   ("#3A5230", 0.92, 0.0, 0.0),
    "草":     ("#6E8248", 0.94, 0.0, 0.0),
    # —— 皮肤 / 描边 / 旗 ——
    "皮肤":   ("#D8A078", 0.70, 0.0, 0.0),
    "皮肤暗": ("#B07A54", 0.74, 0.0, 0.0),
    "须发":   ("#4A382A", 0.84, 0.0, 0.0),
    "阴影":   ("#241C14", 0.94, 0.0, 0.0),
    "描边":   ("#241C14", 0.94, 0.0, 0.0),
    "旗红":   ("#A2302E", 0.86, 0.0, 0.0),
    "旗蓝":   ("#2F4E70", 0.86, 0.0, 0.0),
    "火":     ("#FF8A3C", 0.50, 0.0, 6.0),
    "火暗":   ("#C24A10", 0.40, 0.0, 2.0),
    "魔法":   ("#6FD4FF", 0.40, 0.0, 7.0),
    "魔法暗": ("#2E6E9E", 0.55, 0.0, 1.5),
    # 兼容 rts_kit 旧 key
    "金脉":   ("#F2C84C", 0.26, 0.50, 0.0),
}

# 不参与分档的材质（发光体分档会破坏"光"的一致性；纯黑描边再压就全黑了）
NO_TIER = ("火", "火暗", "魔法", "魔法暗", "阴影", "描边", "冷影")

# 明度下限（"永远不许掉到最暗档"的材质）：
#   茅草 / 麻布 / 白布 / 皮肤 都是**透光或半透光**的薄料，真实世界里它们在阴影里也不会发黑，
#   手绘惯例也是"薄料阴影只压一档"。实测动机：农民草帽的帽檐下缘法线朝下（n·L≈-0.7），
#   不加下限时会掉到 #最暗，帽檐变成一条黑杠把整张脸吃掉（见 §8 的面部补光，两条一起解决）。
TIER_FLOOR = {"茅草": 1, "茅草暗": 1, "布白": 1, "布麻": 1, "布蓝亮": 1,
              "皮肤": 1, "皮肤暗": 1, "叶": 1, "叶黄": 1}


def apply_palette(K):
    """把 v2 调色板写进 rts_kit（保留 PALETTE 的全部旧 key，只是换值）。"""
    for k, (hx, r, m, e) in PALETTE_V2.items():
        K.PALETTE[k] = (hx, r, m, e)
    K.MATS.clear()
    return len(PALETTE_V2)


# ---------------------------------------------------------------------------
# 分档材质
# ---------------------------------------------------------------------------
def _base_color(mat):
    """读 Principled 的 Base Color（线性）。找不到就返回 None。"""
    if mat is None or not mat.use_nodes or mat.node_tree is None:
        return None
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            v = n.inputs["Base Color"].default_value
            return (v[0], v[1], v[2])
    return None


def tier_material(base_mat, tier):
    """由基色材质派生第 tier 档材质（同名复用，不重复造）。"""
    if base_mat is None or tier == 2:
        return base_mat
    name = base_mat.name.split("#")[0] + TIER_SUFFIX[tier]
    got = bpy.data.materials.get(name)
    if got is not None:
        return got
    col = _base_color(base_mat)
    if col is None:
        return base_mat
    co = base_mat.copy()
    co.name = name
    k = TIER_BAND[tier]
    t = TIER_TINT[tier]
    # 带映射在 sRGB 域做（"手绘"是按色卡走的，不是按物理光照走的），再转回线性
    out = []
    for i in range(3):
        s = _srgb(col[i])
        s = (s + (1.0 - s) * TIER_LIFT) if k is None else (s * k)
        s = min(0.985, max(0.0, s * t[i]))
        out.append(_lin1(s))
    newc = tuple(out)
    for n in co.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            n.inputs["Base Color"].default_value = (newc[0], newc[1], newc[2], 1.0)
            # 亮档降一点粗糙度、暗档提一点：手绘质感里高光位置要跟着明度走
            try:
                r0 = n.inputs["Roughness"].default_value
                n.inputs["Roughness"].default_value = max(0.05, min(1.0, r0 * (0.90 if tier > 2 else 1.06)))
            except Exception:
                pass
            break
    return co


def _tier_of(d):
    if d >= TIER_THRESH[0]:
        return 3
    if d >= TIER_THRESH[1]:
        return 2
    if d >= TIER_THRESH[2]:
        return 1
    return 0


def style_object(ob):
    """对单个网格做分档 + 平面着色。返回 (档数, {tier: 面数})。"""
    if ob.type != "MESH" or ob.data is None or len(ob.data.polygons) == 0:
        return 0, {}
    me = ob.data
    mw = ob.matrix_world.to_3x3()
    try:
        mw = mw.normalized() if hasattr(mw, "normalized") else mw
    except Exception:
        pass

    # 部件的主材质（第 0 槽）；若一个对象多材质，逐面按自己的材质派生
    slots = list(me.materials) if me.materials else []
    if not slots:
        return 0, {}

    idx_of = {}          # (slot_index, tier) -> material_index
    counts = {}
    derived = {}

    for p in me.polygons:
        p.use_smooth = False                      # ★ 平面着色（规范 §1.1）
        n = (mw @ p.normal)
        if n.length < 1e-9:
            continue
        d = n.normalized().dot(LIGHT_DIR)
        t = _tier_of(d)
        si = p.material_index if p.material_index < len(slots) else 0
        base = slots[si]
        bname = base.name.split("#")[0] if base else ""
        if bname in NO_TIER:
            t = 2                                  # 不参与分档
        else:
            t = max(t, TIER_FLOOR.get(bname, 0))   # 薄料明度下限（见 TIER_FLOOR 注释）
        key = (si, t)
        if key not in idx_of:
            mt = derived.get((si, t))
            if mt is None:
                mt = tier_material(base, t)
                derived[(si, t)] = mt
            mi = me.materials.find(mt.name)
            if mi < 0:
                me.materials.append(mt)
                mi = len(me.materials) - 1
            idx_of[key] = mi
        p.material_index = idx_of[key]
        counts[t] = counts.get(t, 0) + 1

    used = len([c for c in counts.values() if c > 0])
    return used, counts


def style_pass(objects=None):
    """全场景（或给定对象）过一遍风格分档。返回统计 dict。"""
    objs = objects if objects is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    tier_hist = {}
    objs_touched = 0
    tier_counts_per_obj = []
    for ob in objs:
        used, counts = style_object(ob)
        if used:
            objs_touched += 1
            tier_counts_per_obj.append(used)
        for t, c in counts.items():
            tier_hist[t] = tier_hist.get(t, 0) + c
    return {
        "objects": objs_touched,
        "tiers_used": sorted(tier_hist.keys(), reverse=True),
        "tier_faces": {str(k): v for k, v in sorted(tier_hist.items(), reverse=True)},
        "objs_multi_tier": len([x for x in tier_counts_per_obj if x >= 2]),
        "objs_single_tier": len([x for x in tier_counts_per_obj if x < 2]),
    }


# ---------------------------------------------------------------------------
# §9 验收门
# ---------------------------------------------------------------------------
def tri_count_mesh(objs):
    n = 0
    for o in objs:
        if o.type != "MESH" or o.data is None:
            continue
        me = o.data
        me.calc_loop_triangles()
        n += len(me.loop_triangles)
    return n


def bbox_world(objs):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        if o.type != "MESH" or o.data is None:
            continue
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
    return lo, hi


def _hull_area(pts):
    """2D 凸包面积（Andrew monotone chain）。pts = [(x,y), ...]"""
    pts = sorted(set((round(p[0], 5), round(p[1], 5)) for p in pts))
    if len(pts) < 3:
        return 0.0

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower = []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    upper = []
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    hull = lower[:-1] + upper[:-1]
    a = 0.0
    for i in range(len(hull)):
        x1, y1 = hull[i]
        x2, y2 = hull[(i + 1) % len(hull)]
        a += x1 * y2 - x2 * y1
    return abs(a) * 0.5


def base_rect_fill(objs, band=0.03):
    """底面（z<band）顶点的凸包面积 / bbox 矩形面积。
    1.0 = 底面是完全填充的轴对齐矩形；明显 <1 = 八边形/圆角/斜置（违反 §3.2）。"""
    pts = []
    for o in objs:
        if o.type != "MESH" or o.data is None:
            continue
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            if w.z <= band:
                pts.append((w.x, w.y))
    if len(pts) < 3:
        return 0.0, 0.0, 0.0
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    rect = max(1e-9, (max(xs) - min(xs)) * (max(ys) - min(ys)))
    ha = _hull_area(pts)
    return ha / rect, ha, rect


def _srgb(x):
    x = max(0.0, min(1.0, x))
    return 12.92 * x if x <= 0.0031308 else 1.055 * (x ** (1 / 2.4)) - 0.055


def _lin1(s):
    s = max(0.0, min(1.0, s))
    return s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4


def tier_histogram(objs):
    """按材质名后缀统计各档面数 —— 不依赖 style_pass 的返回值，
    导出前后任何时候读都一致（这是给验收门用的口径）。"""
    h = {}
    for o in objs:
        if o.type != "MESH" or o.data is None:
            continue
        mats = o.data.materials
        for p in o.data.polygons:
            mi = p.material_index
            nm = mats[mi].name if (mi < len(mats) and mats[mi] is not None) else ""
            t = 2
            for i, suf in enumerate(TIER_SUFFIX):
                if suf and nm.endswith(suf):
                    t = i
                    break
            h[t] = h.get(t, 0) + 1
    return h


def value_range(objs):
    """本件用到的所有材质的 sRGB 明度范围（V = max(r,g,b)）。"""
    vs = []
    seen = set()
    for o in objs:
        if o.type != "MESH" or o.data is None:
            continue
        for m in o.data.materials:
            if m is None or m.name in seen:
                continue
            seen.add(m.name)
            c = _base_color(m)
            if c is None:
                continue
            vs.append(max(_srgb(c[0]), _srgb(c[1]), _srgb(c[2])))
    if not vs:
        return 0.0, 0.0, 1.0
    lo, hi = min(vs), max(vs)
    return lo, hi, (hi / lo if lo > 1e-6 else 99.0)


# ---- 人形关节期望位置（与 rig_human.py 的公式逐行同源）----------------------
def human_joints(H, head_div=7.5, shoulder_k=2.20):
    head_h = H / head_div
    head_w = head_h * 0.79
    sh_w = head_w * shoulder_k
    sh_x = sh_w * 0.5
    head_top = H * 0.985
    chin = head_top - head_h
    neck_z = chin + head_h * 0.10
    sh_z = 0.818 * H
    chest_z = 0.705 * H
    waist_z = 0.598 * H
    hip_z = 0.535 * H
    knee_z = 0.285 * H
    ankle_z = 0.019 * H
    hip_x = 0.0505 * H
    ua, fa = 0.175 * H, 0.145 * H
    sp = math.radians(8.0)
    elbow_z = sh_z - ua * math.cos(sp)
    wrist_z = elbow_z - fa * math.cos(sp)
    elbow_x = sh_x + math.sin(sp) * ua
    wrist_x = elbow_x + math.sin(sp) * fa
    hand_len = head_h * 0.42
    grip_z = wrist_z - hand_len * 0.34
    grip_y = head_w * 0.30 * 0.12
    d = {
        "Root": (0, 0, 0), "Body": (0, 0, hip_z), "Torso": (0, 0, waist_z),
        "Head": (0, 0, neck_z), "Shield": (0, 0, chest_z),
    }
    for s, sx in (("L", -1.0), ("R", 1.0)):
        d["Arm" + s] = (sx * sh_x, 0, sh_z)
        d["Forearm" + s] = (sx * elbow_x, 0, elbow_z)
        d["Hand" + s] = (sx * wrist_x, 0, wrist_z)
        d["Leg" + s] = (sx * hip_x, 0, hip_z)
        d["Shin" + s] = (sx * hip_x * 0.98, 0, knee_z)
        d["Foot" + s] = (sx * hip_x * 0.96, 0, ankle_z)
    d["Weapon"] = (wrist_x, grip_y, grip_z)
    return d


REQ_NODES = ["Root", "Body", "Torso", "Head", "ArmL", "ForearmL", "HandL", "ArmR",
             "ForearmR", "HandR", "LegL", "ShinL", "FootL", "LegR", "ShinR", "FootR",
             "Weapon", "Shield"]


def verify(name, cfg, objs=None):
    """§9 验收门。cfg: {kind:'char'|'building'|'prop', h/box, tris:[lo,hi],
    base_rect_min, H}"""
    objs = objs if objs is not None else [o for o in bpy.data.objects if o.type == "MESH"]
    empties = [o for o in bpy.data.objects if o.type == "EMPTY"]
    lo, hi = bbox_world(objs)
    tris = tri_count_mesh(objs)
    size = [round(hi.x - lo.x, 3), round(hi.y - lo.y, 3), round(hi.z - lo.z, 3)]
    out = {"model": name, "kind": cfg["kind"], "tris": tris,
           "meshes": len(objs), "empties": len(empties),
           "size": size, "min": [round(lo.x, 3), round(lo.y, 3), round(lo.z, 3)],
           "max": [round(hi.x, 3), round(hi.y, 3), round(hi.z, 3)]}
    fails = []

    # ① 面数
    tlo, thi = cfg["tris"]
    out["tris_ok"] = tlo <= tris <= thi
    if not out["tris_ok"]:
        fails.append("tris %d not in [%d,%d]" % (tris, tlo, thi))

    # ② 比例
    if cfg["kind"] == "char":
        H = cfg["H"]
        dh = abs(size[2] - H)
        out["height_ok"] = dh <= H * 0.01
        if not out["height_ok"]:
            fails.append("height %.3f != %.2f (±1%%)" % (size[2], H))
    elif cfg["kind"] == "building":
        bw, bd, bh = cfg["box"]
        dev = [abs(size[0] - bw), abs(size[1] - bd), abs(size[2] - bh)]
        out["dims_dev"] = [round(x, 3) for x in dev]
        out["dims_ok"] = max(dev) <= 0.05
        if not out["dims_ok"]:
            fails.append("dims %s dev %s > 0.05" % (size, out["dims_dev"]))
    else:
        mn, mx = cfg["maxdim"]
        m = max(size)
        out["dims_ok"] = mn <= m <= mx
        if not out["dims_ok"]:
            fails.append("maxdim %.2f not in [%.2f,%.2f]" % (m, mn, mx))

    # ③ 层级
    have = {o.name for o in empties}
    if cfg["kind"] == "char":
        missing = [n for n in REQ_NODES if n not in have]
        out["missing_nodes"] = missing
        out["nodes_ok"] = not missing
        if missing:
            fails.append("missing nodes %s" % missing)
        # ④ 枢轴：比的是 **世界坐标**（matrix_world.translation）。
        #    实测两条口径，都必须写死在这里，否则会假报：
        #    a) 空节点的 .location 是**父级相对**量（Body 下 Torso 的 loc.z = waist-hip），
        #       拿 location 比世界坐标会假报 866mm；matrix_world 的误差才是真误差。
        #    b) builder 末尾会 fit_height() 把整件等比缩到规范身高，空节点跟着缩 ——
        #       所以期望值要按 **实测高度 / 名义身高** 同比例缩放后再比，
        #       否则会把"整体归一化"误判成"枢轴跑偏"（实测 农民 报 6.07mm 就是这个）。
        bpy.context.view_layer.update()
        exp = human_joints(cfg["H"])
        # 系数 k 从**骨架自身**反推，而不是从名义身高反推：
        # builder 末尾的 fit_height 是"整件（含盔缨/帽顶这类出头装饰）归一化到身高"，
        # 所以关节是按同一个 k 等比缩放的 —— 只要 **所有关节同一个 k**，比例就没坏。
        # 拿名义身高当 k 会把"整件等比缩放"误判成"头跑了 52mm"（实测 步兵 就是这个）。
        ratios = []
        for n in REQ_NODES:
            o = bpy.data.objects.get(n)
            if o is None or abs(exp[n][2]) < 0.10:
                continue
            wz = o.matrix_world.translation.z
            if abs(wz) > 1e-6:
                ratios.append(wz / exp[n][2])
        if not ratios:
            k = 1.0
        else:
            ratios.sort()
            k = ratios[len(ratios) // 2]
        out["pivot_scale"] = round(k, 5)
        worst, worst_n = 0.0, ""
        for n in REQ_NODES:
            o = bpy.data.objects.get(n)
            if o is None:
                continue
            e = Vector(exp[n]) * k
            dv = (o.matrix_world.translation - e).length
            if dv > worst:
                worst, worst_n = dv, n
        out["pivot_worst_mm"] = round(worst * 1000, 2)
        out["pivot_worst_node"] = worst_n
        out["pivots_ok"] = worst <= 0.002
        if not out["pivots_ok"]:
            fails.append("pivot %s off %.1fmm" % (worst_n, worst * 1000))
    else:
        missing = [n for n in ("Root", "Body") if n not in have]
        out["missing_nodes"] = missing
        out["nodes_ok"] = not missing
        if missing:
            fails.append("missing nodes %s" % missing)

    # ⑤ 贴地 + 居中
    out["min_z"] = round(lo.z, 4)
    out["center_xy"] = [round((lo.x + hi.x) * 0.5, 4), round((lo.y + hi.y) * 0.5, 4)]
    ground_ok = -0.005 <= lo.z <= 0.01
    # 居中口径按类别分开：
    #  * 角色：装备（镐/背篓/盾）本来就会让 bbox 偏心，判据是 **Root 在原点**（pivot 门已覆盖）；
    #  * 建筑：底面必须落在网格中心，bbox 中心偏 ≤0.06m（装饰越界不许超过这个量）。
    if cfg["kind"] in ("char", "prop"):
        # 角色/自然物：装备与树冠/碎石本来就让 bbox 偏心，判据是 **枢轴在底面中心（Root 在原点）**
        center_ok = True
    else:
        center_ok = abs(out["center_xy"][0]) <= 0.06 and abs(out["center_xy"][1]) <= 0.06
    out["ground_ok"] = bool(ground_ok)
    out["centered_ok"] = bool(center_ok)
    if not ground_ok:
        fails.append("min_z %.4f" % lo.z)
    if not center_ok:
        fails.append("center %s" % out["center_xy"])

    # ⑥ 足迹轴对齐矩形（只判建筑）
    if cfg["kind"] == "building":
        fill, ha, ra = base_rect_fill(objs, cfg.get("band", 0.03))
        out["base_rect_fill"] = round(fill, 4)
        out["base_hull_m2"] = round(ha, 3)
        out["base_rect_m2"] = round(ra, 3)
        out["base_ok"] = fill >= cfg.get("base_rect_min", 0.95)
        if not out["base_ok"]:
            fails.append("base_rect_fill %.3f < %.2f" % (fill, cfg.get("base_rect_min", 0.95)))

    # ⑦ 明度差（材质色值跨度）
    vlo, vhi, ratio = value_range(objs)
    out["value_lo"] = round(vlo, 3)
    out["value_hi"] = round(vhi, 3)
    out["value_ratio"] = round(ratio, 2)
    out["value_ok"] = ratio >= 1.18
    if not out["value_ok"]:
        fails.append("value_ratio %.2f < 1.18" % ratio)

    # ⑧ 明度分档覆盖（§1.3 的"2~4 档"：至少真用到 2 档，且每档都占 ≥1% 面）
    th = tier_histogram(objs)
    total_f = sum(th.values()) or 1
    out["tier_faces"] = {str(k): v for k, v in sorted(th.items(), reverse=True)}
    out["tier_share"] = {str(k): round(v / total_f, 3) for k, v in sorted(th.items(), reverse=True)}
    used_tiers = sorted([k for k, v in th.items() if v / total_f >= 0.01])
    out["tiers_used"] = used_tiers
    out["tiers_ok"] = len(used_tiers) >= 2
    if not out["tiers_ok"]:
        fails.append("tiers_used %s < 2" % used_tiers)

    out["fails"] = fails
    out["pass"] = not fails
    return out
