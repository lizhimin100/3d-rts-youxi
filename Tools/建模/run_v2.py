# -*- coding: utf-8 -*-
"""
run_v2.py —— 铁血战歌 12 件资产重制驱动器（《美术规范.md》§7 的实现）
=====================================================================
做的事情，按顺序：
  1. 把 v2 调色板写进 rts_kit（style_v2.apply_palette）—— 基色 key 名字不变，build 脚本零改动；
  2. **在渲染与导出之前**注入 style_pass（明度分档 + 平面着色）——
     顺序很重要：先出图后分档的话，预览图里看不到分档，等于没验（规范 §1.3 / §9-6）；
  3. 每件导出后立刻跑 §9 的验收门（比例/面数/层级/枢轴/明度差/足迹/贴地），
     结果按件收集进 HEADLESS 回执；
  4. 预览图强制 900×900 + 固定两机位（正 / 三四），与 §8 逐字一致。

用法：
  & 'D:\blender\blender.exe' -b --factory-startup --python 'E:\\...\\run_v2.py' -- 农民
  （不带参数 = 12 件全跑）
"""
import bpy
import sys
import os
import json
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import rts_kit as K
import style_v2 as S

OUT_ROOT = r"D:\blender\.workbuddy\rts_out\雕骨"
K.OUT_ROOT = OUT_ROOT
S.apply_palette(K)

# ---------------------------------------------------------------------------
# 规格表（与《美术规范.md》§3 / §4 逐字一致）
# ---------------------------------------------------------------------------
SPEC = {
    # 角色：身高 / 面数
    "农民":   dict(kind="char", H=1.62, tris=(3000, 9000)),
    "步兵":   dict(kind="char", H=1.78, tris=(3000, 9000)),
    "法师":   dict(kind="char", H=1.80, tris=(3000, 9000)),
    "弓箭手": dict(kind="char", H=1.72, tris=(3000, 9000)),
    # 建筑：宽×深×高 / 面数 / 底面填充率
    "大本营": dict(kind="building", box=(8.0, 8.0, 9.0), tris=(4000, 20000)),
    "兵营":   dict(kind="building", box=(6.0, 5.5, 4.6), tris=(4000, 20000)),
    "树":     dict(kind="prop", maxdim=(4.5, 6.5), tris=(3000, 7000)),
    "金矿":   dict(kind="building", box=(4.0, 3.5, 3.2), tris=(4000, 20000), base_rect_min=0.90),
    "铁匠铺": dict(kind="building", box=(5.5, 5.0, 4.2), tris=(4000, 20000)),
    "箭塔":   dict(kind="building", box=(3.0, 3.0, 8.0), tris=(4000, 20000)),
    "农场":   dict(kind="building", box=(4.0, 4.0, 2.6), tris=(4000, 20000)),
    "岩石":   dict(kind="prop", maxdim=(1.2, 2.6), tris=(800, 2600)),
}

# 规范里的优先级（用户指定的开工顺序）
PRIORITY = ["农民", "步兵", "法师", "弓箭手", "大本营", "兵营", "树",
            "金矿", "铁匠铺", "箭塔", "农场", "岩石"]

REPORTS = {}
_argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
WANTED = [a for a in _argv if a in SPEC] or list(PRIORITY)
WSET = set(WANTED)


def log(msg):
    print("[run_v2] " + msg, flush=True)


# ---------------------------------------------------------------------------
# 0) 归一化补丁：见 norm_v2.py（修 fit_height / fit_box / drop_to_ground 的"骨架-网格脱钩"）
import norm_v2

norm_v2.apply(K)


# ---------------------------------------------------------------------------
# 注入点
# ---------------------------------------------------------------------------
def ensure_styled():
    """分档只跑一次（对象上打 style_v2 标记，避免二次分档把 #亮 再派生一层）。"""
    todo = [o for o in bpy.data.objects if o.type == "MESH" and not o.get("style_v2")]
    if todo:
        st = S.style_pass(todo)
        for o in todo:
            o["style_v2"] = 1
        return st
    return None


def ensure_root_body():
    """建筑/自然物至少要有 Root → Body 两层（规范 §6.2；ProcAnim 以 Body 判绑定）。"""
    root = bpy.data.objects.get("Root")
    if root is None or root.type != "EMPTY":
        root = K.empty("Root", (0, 0, 0))
    body = bpy.data.objects.get("Body")
    if body is None or body.type != "EMPTY":
        body = K.empty("Body", (0, 0, 0))
        K.parent_to(body, root)
    for ob in list(bpy.data.objects):
        if ob is root or ob is body:
            continue
        if ob.parent is None and ob.type in ("MESH", "EMPTY"):
            K.parent_to(ob, body)


def name_of(path):
    return os.path.splitext(os.path.basename(path))[0]


def do_verify(name):
    ensure_root_body() if SPEC[name]["kind"] != "char" else None
    st = ensure_styled()
    objs = [o for o in bpy.data.objects if o.type == "MESH"]
    v = S.verify(name, SPEC[name], objs)
    if st:
        v["style"] = st
    return v


_orig_export = K.export_glb


def export_glb(path, report_extra=None):
    name = name_of(path)
    v = do_verify(name)
    rep = _orig_export(path, report_extra)
    v["glb"] = rep["glb"]
    v["bytes"] = rep["bytes"]
    v["nodes"] = rep["nodes"]
    REPORTS[name] = v
    log("%s  tris=%d  %s  pass=%s %s" % (
        name, v["tris"], "×".join("%.2f" % x for x in v["size"]),
        v["pass"], ("FAILS=" + str(v["fails"])) if v["fails"] else ""))
    # 规范 §8：每件必出 正 / 三四 两张 900px。
    # 放在导出**之后**统一出图 —— 因为多数 builder（建筑/自然物）自己不渲染，
    # 只有角色会自己调 render_views；统一在这里做才不会漏图（实测漏过 6 件）。
    try:
        K.render_views(name, os.path.dirname(rep["glb"]))
    except Exception as exc:
        log("RENDER FAIL %s: %s" % (name, exc))
    return rep


K.export_glb = export_glb

_orig_rv = K.render_views

# 面部补光（"eye light"）：从**前下方**打上来，穿到帽檐/兜帽下沿，把脸救回来。
# 依据：§8 三点光的主光来自前上方，草帽帽檐的物理遮挡会把整张脸压成黑影
# （实测第一版预览：帽檐下面是一团黑，正视图看不出有脸）。这不是"外挂照明"，
# 而是补上真实场景里地面反光打到下巴的那一份 —— 工业上叫 eye light。
_orig_rig = K.setup_render_rig


def setup_render_rig(target, radius, **kw):
    cam, lights, ground = _orig_rig(target, radius, **kw)
    from mathutils import Vector as _V
    ld = bpy.data.lights.new("面部补光", "SUN")
    ld.energy = 1.45
    ld.color = (0.88, 0.90, 1.0)
    ld.angle = 0.75
    ob = bpy.data.objects.new("面部补光", ld)
    ob.rotation_euler = _V((0.0, -1.0, 0.30)).normalized().to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.collection.objects.link(ob)
    lights.append(ob)
    return cam, lights, ground


K.setup_render_rig = setup_render_rig


def render_views(name, outdir, *a, **kw):
    ensur = ensure_styled()
    if ensur:
        log("%s  style: tiers=%s  multi=%d  single=%d" % (
            name, ensur["tiers_used"], ensur["objs_multi_tier"], ensur["objs_single_tier"]))
    kw["res"] = (900, 900)
    kw["views"] = ("正", "三四")        # 规范 §8：每件只要这两张
    return _orig_rv(name, outdir, *a, **kw)


K.render_views = render_views


# ---------------------------------------------------------------------------
# 执行器
# ---------------------------------------------------------------------------
def run_script(script_name):
    path = os.path.join(HERE, script_name)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    t0 = time.time()
    log("exec %s" % script_name)
    g = {"__name__": "__main__", "__file__": path}
    exec(compile(src, path, "exec"), g)
    log("%s done in %.1fs" % (script_name, time.time() - t0))
    return g


def run_nature():
    """自然物：新版 build_v2_自然.py 自带 __main__ 保护，直接跑即可
    （旧版 build_自然物.py 用 read_factory_settings 重置场景却不清理 rts_kit.MATS，
    预览时会拿到已销毁材质 → ReferenceError，实测崩过一次，已弃用）。"""
    keep = [a for a in sys.argv[sys.argv.index("--") + 1:] if a in ("树", "岩石", "金矿")]
    g = run_script("build_v2_自然.py")
    # build_v2_自然 自己会 export_glb + render_views（走的是本文件的补丁），这里不重复
    return g


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    os.makedirs(OUT_ROOT, exist_ok=True)
    t0 = time.time()

    # 1) 角色
    chars_a = {"农民"}
    chars_b = {"步兵", "弓箭手", "法师"}
    if WSET & chars_a:
        run_script("build_农民.py")
    if WSET & chars_b:
        run_script("build_角色.py")
    # 2) 建筑
    if WSET & {"大本营", "兵营", "铁匠铺", "农场", "箭塔"}:
        run_script("build_建筑.py")
    # 3) 自然物
    if WSET & {"树", "岩石", "金矿"}:
        run_nature()

    summary = {
        "out_root": OUT_ROOT,
        "models": {k: REPORTS[k] for k in PRIORITY if k in REPORTS},
        "requested": WANTED,
        "elapsed_s": round(time.time() - t0, 1),
        "fail_count": len([k for k in REPORTS if not REPORTS[k]["pass"]]),
    }
    print("HEADLESS " + json.dumps(summary, ensure_ascii=False))


main()
