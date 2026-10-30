# -*- coding: utf-8 -*-
"""
textured.py —— v5 贴图化管线（在 v3 几何之上加 UV + 手绘风贴图 + 法线）

它做四件事，别多做：
  1. **UV**：按面的主法线做盒式投影（world-space box projection）。
     不用 Smart UV Project 的原因：RTS 模型的 UV 密度必须**跨物体一致**
     （同一面石墙，不管几何多碎，石头大小要一样），盒式投影天然做到；
     而且不依赖操作符上下文，headless 下完全确定。
  2. **材质**：把 M_<zone> 换成 "贴图族 + 调色板颜色" 的 PBR 材质，
     法线用真正的法线贴图节点接到 Principled.BSDF —— glTF 会带着它一起导出。
  3. **QC 渲染**：调色板颜色 × 贴图（看得见配色），再切回"纯贴图"给导出，
     否则 glTF 的 baseColorFactor 会把引擎侧调色板乘两遍。
  4. 不改任何几何 / 骨骼 / 动画：v3 的形状与动作原样保留。

约定：
  * 贴图族在 美术/贴图/<family>_albedo.png / _normal.png；
  * 一个族只有一份 image datablock，glTF 导出时自动去重。
"""

import os
import bpy

TEX_DIR = r"E:\自定义游戏\简易rts\美术\贴图"

# zone -> (family, uv_scale 米/贴图)
# uv_scale 的口径：一张 512 贴图铺满多少米。
#   石墙 2.2m（一块石头约 0.3m，和真实砌块接近）；
#   瓦 1.6m（一片瓦约 18cm，远看刚好分辨）；
#   金属 0.6m（划痕/锈斑是近景细节，铺太大会糊）；
#   布 0.8m（织纹只有近景可见，不能抢戏）。
ZONES = {
    "stone":       ("ashlar", 2.2),
    "stone_dark":  ("ashlar", 2.2),
    "stone_light": ("ashlar", 2.2),
    "plaster":     ("plaster", 2.4),
    "roof":        ("shingle", 1.6),
    "roof_dark":   ("shingle", 1.6),
    "roof_red":    ("shingle", 1.5),
    "roof_iron":   ("metal", 1.1),
    "roof_tower":  ("shingle", 1.4),
    "gold":        ("metal", 0.55),
    "gold_dark":   ("metal", 0.55),
    "wood":        ("plank", 1.6),
    "wood_dark":   ("plank", 1.6),
    "steel":       ("metal", 0.62),
    "steel_dark":  ("metal", 0.62),
    "steel_light": ("metal", 0.62),
    "iron":        ("metal", 0.60),
    "leather":     ("leather", 0.62),
    "leather_dark":("leather", 0.62),
    "cloth":       ("cloth", 0.85),
    "cloth_dark":  ("cloth", 0.85),
    "skin":        ("plaster", 0.30),
    "skin_dark":   ("plaster", 0.30),
    "hair":        ("bark", 0.28),
    "crystal":     ("metal", 0.40),
    "ember":       ("metal", 0.40),
    "glass":       ("metal", 0.40),
    "bark":        ("bark", 1.15),
    "leaf":        ("leaf", 1.10),
    "leaf_dark":   ("leaf", 1.10),
    "ore":         ("ore", 1.30),
    "grass":       ("ground_grass", 1.20),
    "dirt":        ("ground_dirt", 1.60),
    "hay":         ("hay", 0.80),
    "rope":        ("cloth", 0.30),
    "bone":        ("plaster", 0.28),
}

# 法线强度（0 = 不接法线；不同材质的"凹凸自信度"不一样）
NORMAL_STRENGTH = {
    "ashlar": 1.0, "cobble": 1.0, "plaster": 0.55, "shingle": 1.15,
    "plank": 0.85, "metal": 0.65, "leather": 0.75, "cloth": 0.35,
    "bark": 1.0, "leaf": 0.7, "rock": 1.1, "hay": 0.9, "ore": 1.05,
    "ground_grass": 0.8, "ground_dirt": 0.85,
}

_img_cache = {}


def tex(family, kind):
    key = family + "|" + kind
    if key in _img_cache:
        return _img_cache[key]
    path = os.path.join(TEX_DIR, "%s_%s.png" % (family, kind))
    if not os.path.exists(path):
        return None
    img = bpy.data.images.load(path, check_existing=True)
    if kind == "normal":
        img.colorspace_settings.name = "Non-Color"
    _img_cache[key] = img
    return img


# ===========================================================================
# UV：世界坐标盒式投影
# ===========================================================================

def triangulate(obj):
    """导出前三角化。

    为什么必须做：glTF 的切线（TANGENT）只能从三角面算，Blender 导出时会报
    "Could not calculate tangents. Please try to triangulate the mesh first."
    然后**静默丢掉 TANGENT** —— 没有切线，Godot 里的法线贴图就是一张废图。
    """
    me = obj.data
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(me)
    if any(len(f.verts) > 3 for f in bm.faces):
        bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    bm.to_mesh(me)
    bm.free()
    me.update()


def box_uv(obj, scale):
    me = obj.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uvl = me.uv_layers.active
    inv = 1.0 / max(scale, 1e-4)
    for poly in me.polygons:
        n = poly.normal
        ax, ay, az = abs(n.x), abs(n.y), abs(n.z)
        if ax >= ay and ax >= az:
            axis = 0
        elif ay >= az:
            axis = 1
        else:
            axis = 2
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            if axis == 0:      # 朝 X：用 YZ
                uv = (co.y * inv, co.z * inv)
            elif axis == 1:    # 朝 Y：用 XZ
                uv = (co.x * inv, co.z * inv)
            else:              # 朝 Z：用 XY
                uv = (co.x * inv, co.y * inv)
            uvl.data[li].uv = uv
    me.update()


# ===========================================================================
# 材质
# ===========================================================================

def zone_of(mat_name):
    if not mat_name.startswith("M_"):
        return ""
    s = mat_name[2:]
    i = s.find("_team")
    if i >= 0:
        s = s[:i]
    return s


def cur_zone(mat_name):
    return zone_of(mat_name) or mat_name


def build_material(zone, base_color, rough, metallic, existing=None):
    """建/改材质。

    ★ 就地改（existing 传入时）：kit3 的 `_MAT_CACHE` 按 "M_<zone>" 缓存材质，
      跨模型复用同一份 datablock。如果这里删了重建，缓存里就是死引用
      （报 "StructRNA of type Material has been removed"），
      而且重建后名字会被加 .001，MatKit 的 M_<zone> 协议直接断掉。
      所以在原 datablock 上重搭节点树，名字、缓存、引用全部保持不变。
    """
    family, scale = ZONES.get(zone, ("plaster", 1.0))
    m = existing if existing is not None else bpy.data.materials.new("M_" + zone)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (620, 0)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (300, 0)
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metallic
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.35

    alb = tex(family, "albedo")
    nrm = tex(family, "normal")

    if alb is not None:
        ta = nt.nodes.new("ShaderNodeTexImage")
        ta.image = alb
        ta.location = (-420, 120)
        ta.interpolation = "Smart"
        # 调色板颜色 × 贴图（QC 用）；导出前会切成"贴图直连"
        mix = nt.nodes.new("ShaderNodeMixRGB")
        mix.blend_type = "MULTIPLY"
        mix.inputs["Fac"].default_value = 1.0
        mix.inputs["Color1"].default_value = tuple(base_color) + (1.0,)
        mix.location = (-60, 120)
        nt.links.new(ta.outputs["Color"], mix.inputs["Color2"])

        # 顶点 AO（Cycles 烘焙，见 bake_ao）：× 到基色上，
        # 这是"接触阴影"—— 肩甲压胸甲、瓦片压瓦片、盾缘压盾面，全靠它立起来。
        ao = nt.nodes.new("ShaderNodeVertexColor")
        ao.layer_name = "AO"
        ao.location = (-60, -60)
        aomix = nt.nodes.new("ShaderNodeMixRGB")
        aomix.blend_type = "MULTIPLY"
        aomix.inputs["Fac"].default_value = 1.0
        aomix.location = (120, 60)
        nt.links.new(mix.outputs["Color"], aomix.inputs["Color1"])
        nt.links.new(ao.outputs["Color"], aomix.inputs["Color2"])
        nt.links.new(aomix.outputs["Color"], bsdf.inputs["Base Color"])

        m["_mix_name"] = mix.name
        m["_tex_name"] = ta.name
        m["_ao_mix_name"] = aomix.name
    else:
        bsdf.inputs["Base Color"].default_value = tuple(base_color) + (1.0,)

    if nrm is not None and family in NORMAL_STRENGTH:
        tn = nt.nodes.new("ShaderNodeTexImage")
        tn.image = nrm
        tn.location = (-420, -240)
        tn.interpolation = "Linear"
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nm.location = (-60, -240)
        nm.inputs["Strength"].default_value = NORMAL_STRENGTH[family]
        nt.links.new(tn.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])

    m.diffuse_color = tuple(base_color) + (1.0,)
    return m


def export_mode(materials, on=True):
    """导出前把 base color 从 "调色板×贴图×AO" 切成 "贴图×AO"：
    glTF 的 baseColorFactor 必须留白，颜色交给引擎侧 MatKit（否则乘两遍会发黑）。
    AO 保留在材质链里 —— 这样 glTF 导出器会连 COLOR_0 一起写出去。"""
    for m in materials:
        if not m.use_nodes:
            continue
        nt = m.node_tree
        bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is None:
            continue
        mix = nt.nodes.get(m.get("_mix_name", "")) if m.get("_mix_name") else None
        ta = nt.nodes.get(m.get("_tex_name", "")) if m.get("_tex_name") else None
        aomix = nt.nodes.get(m.get("_ao_mix_name", "")) if m.get("_ao_mix_name") else None
        if not on:
            if mix is not None:
                mix.mute = False
                nt.links.new(mix.outputs["Color"], aomix.inputs["Color1"] if aomix else bsdf.inputs["Base Color"])
            continue
        # 导出：贴图直连（跳过调色板乘算），AO 继续乘
        if mix is not None:
            mix.mute = True
            if ta is not None:
                if aomix is not None:
                    nt.links.new(ta.outputs["Color"], aomix.inputs["Color1"])
                else:
                    nt.links.new(ta.outputs["Color"], bsdf.inputs["Base Color"])


# ===========================================================================
# 顶点 AO（Cycles GPU 烘焙到 COLOR_0）
# ===========================================================================

def bake_ao(objs, samples=20):
    """把所有网格的接触阴影烘进顶点色。

    为什么用顶点色而不是贴图 AO：
      1) 不需要 UV 图集 / 二次展 UV，盒式投影本来就不是为烘焙准备的；
      2) 顶点色只占 COLOR_0 一个属性，导出后引擎侧一行 shader 就能乘上；
      3) RTS 模型面数不高，顶点级 AO 正好够用（要的是大结构阴影，不是毛孔）。
    """
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        for t in ("OPTIX", "CUDA"):
            try:
                prefs.compute_device_type = t
                prefs.get_devices()
                if any(d.type == t for d in prefs.devices):
                    for d in prefs.devices:
                        d.use = (d.type == t)
                    scene.cycles.device = "GPU"
                    break
            except Exception:
                continue
    except Exception:
        pass
    scene.cycles.samples = samples
    scene.cycles.use_denoising = False
    # ★ AO 射线距离：默认 world.light_settings.distance 是 10m，
    #   对 1.8m 的角色来说周围全被算成"受光"，烘出来几乎是纯白（实测接缝全平）。
    #   0.55m 刚好覆盖肩甲/瓦片/门框这种尺度的接触阴影。
    try:
        w = bpy.context.scene.world or bpy.data.worlds.new("World")
        bpy.context.scene.world = w
        w.light_settings.distance = 0.55
    except Exception:
        pass
    scene.render.bake.use_pass_direct = False
    scene.render.bake.use_pass_indirect = False
    scene.render.bake.margin = 4

    done = 0
    for ob in objs:
        if ob.type != "MESH":
            continue
        me = ob.data
        if not me.color_attributes:
            me.color_attributes.new(name="AO", type="BYTE_COLOR", domain="CORNER")
        me.color_attributes.active_color_index = 0
        me.color_attributes.render_color_index = 0
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        try:
            bpy.ops.object.bake(type="AO", target="VERTEX_COLORS")
            done += 1
        except Exception as e:
            print("[v5] AO 烘焙跳过", ob.name, type(e).__name__, e)
    return done


# ===========================================================================
# 入口
# ===========================================================================

def apply(objs, palette, default_uv=1.6):
    """给一组对象套贴图。

    objs    : mesh 对象列表（Builder.build_meshes 的返回）
    palette : kit3.PALETTE（zone -> (hex, rough, metallic)）
    返回    : (materials, stat)
    """
    from kit3 import hex2rgb, srgb_to_linear  # 复用同一套 sRGB 口径

    mats = []
    stat = {}
    done_mats = {}       # id(材质 datablock) -> uv_scale（同一 zone 只改一次）
    for ob in objs:
        if ob.type != "MESH" or not ob.data.materials:
            continue
        mat = ob.data.materials[0]
        if mat is None:
            continue
        ptr = mat.as_pointer()
        if ptr not in done_mats:
            mat_name = mat.name           # ★ 必须在任何改名/重建之前抓下来
            zone = zone_of(mat_name)
            if not zone:
                continue
            family, scale = ZONES.get(zone, ("plaster", default_uv))
            hexv, rough, metal = palette.get(zone, ("#B8B8B8", 0.85, 0.0))
            col = hex2rgb(hexv)                          # sRGB 0..1
            lin = tuple(srgb_to_linear(c) for c in col)  # Principled 要线性
            build_material(zone, lin, rough, metal, existing=mat)
            mat["_uv_scale"] = scale
            done_mats[ptr] = scale
        triangulate(ob)
        box_uv(ob, float(done_mats[ptr]))
        stat[cur_zone(mat.name)] = stat.get(cur_zone(mat.name), 0) + 1
        if mat not in mats:
            mats.append(mat)
    return mats, stat
