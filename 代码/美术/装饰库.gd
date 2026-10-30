class_name RtsDecorLib
extends RefCounted
## **装饰库（DECOR）**：地图装饰物的唯一入口。
##
## 为什么要有这一层：
##   · 以前地图上的树/金矿/岩石都是"代码现场拼网格"（ArtKit → GLB → 逐个 MeshInstance），
##     阴影、可见距离、材质这些**资产属性散落在代码里**，美术想调一个参数得改脚本；
##   · 现在它们收敛成 `美术/场景/*.tscn`：场景里实例化现有 GLB（不改 GLB），
##     阴影/可见距离写在场景里；代码只认"种类名"。
##
## 两种用法：
##   1. **独立节点**（参与玩法、需要单独销毁/被采集的）：`instantiate(kind, parent)`
##   2. **合批**（纯装饰、永不单独交互的）：`make_multimesh(kind, transforms, colors)`
##      一次 draw call 画几百个，颜色逐实例变化。
##
## 约定：
##   · 种类名与 `UnitDef.id` 对齐（tree / goldmine），也接受中文（树 / 金矿）；
##   · 所有缓存都是静态的，退出前调 `clear_cache()`（和 ArtKit 一样，避免关停时报资源未释放）；
##   · 场景缺文件时返回 null 并 **只警告一次**，绝不崩。

## 场景目录
const SCENE_DIR := "res://美术/场景/"

## 种类 → 场景文件名
const SCENE_FILE := {
	&"tree": "树_场景.tscn",
	&"rock": "岩石_场景.tscn",
	&"goldmine": "金矿_场景.tscn",
	&"grass": "草丛_场景.tscn",
	&"rubble": "碎石_场景.tscn",
	&"water": "水面_场景.tscn",
}

## 中文别名（场景文件名可以直接当种类名用）
const ALIAS := {
	&"树": &"tree",
	&"岩石": &"rock",
	&"金矿": &"goldmine",
	&"草丛": &"grass",
	&"碎石": &"rubble",
	&"水面": &"water",
}

## 可见距离（米）。合批实例上要再设一遍：MultiMeshInstance3D 的可见距离是**整批**的，
## 不跟着场景里单件的设置走。数值与场景文件里的保持一致。
const VIEW_DISTANCE := {
	&"tree": 160.0,
	&"rock": 130.0,
	&"goldmine": 150.0,
	&"grass": 80.0,
	&"rubble": 60.0,
	&"water": 200.0,
}

## 合批材质的粗糙度（装饰物不反光，省一次高光计算）
const BATCH_ROUGHNESS := 0.94

# --- 缓存（静态，跨地图复用；同一份 PackedScene 只 load 一次）---
static var _scenes: Dictionary = {}
static var _batch_meshes: Dictionary = {}
static var _batch_material_cache: Dictionary = {}


# ===========================================================================
# 场景
# ===========================================================================

## 这个种类有没有场景（不存在就 false，不报错）
static func has_scene(kind: StringName) -> bool:
	return scene(kind) != null


## 取场景（带缓存；缺文件返回 null，只警告一次）
static func scene(kind: StringName) -> PackedScene:
	var k := _normalize(kind)
	if _scenes.has(k):
		return _scenes[k]
	var ps: PackedScene = null
	if SCENE_FILE.has(k):
		var path: String = SCENE_DIR + String(SCENE_FILE[k])
		if ResourceLoader.exists(path):
			ps = load(path) as PackedScene
		if ps == null:
			push_warning("[装饰库] 场景缺失或不是 PackedScene：%s" % path)
	else:
		push_warning("[装饰库] 未登记的装饰种类：%s" % String(kind))
	_scenes[k] = ps
	return ps


## 实例化一个装饰。parent 不为空时顺手挂进去（不设位置，调用方自己摆）。
static func instantiate(kind: StringName, parent: Node3D = null) -> Node3D:
	var ps := scene(kind)
	if ps == null:
		return null
	var n := ps.instantiate() as Node3D
	if n == null:
		return null
	# 单件也要吃自然材质：GLB 自带的 albedo 是灰度噪声，不套就是一块灰白。
	自然材质库.apply(n)
	if parent != null:
		parent.add_child(n)
	return n


# ===========================================================================
# 合批
# ===========================================================================

## 把一个种类的场景**烘成一份网格**（烘焙实例变换、丢掉隐藏件），给 MultiMesh 用。
## 缓存：同一批装饰共用一份网格，省内存也省合并时间。
static func batch_mesh(kind: StringName) -> ArrayMesh:
	var k := _normalize(kind)
	if _batch_meshes.has(k):
		return _batch_meshes[k]
	var ps := scene(k)
	if ps == null:
		_batch_meshes[k] = null
		return null
	var root := ps.instantiate() as Node3D
	if root == null:
		_batch_meshes[k] = null
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var surfaces: int = _append_surfaces(st, root, Transform3D.IDENTITY)
	var mesh: ArrayMesh = null
	if surfaces > 0:
		mesh = st.commit() as ArrayMesh
	# 只是拿来烘网格，没进过场景树：直接 free，别留到下一帧
	root.free()
	_batch_meshes[k] = mesh
	return mesh


## 造一批装饰。transforms 是每个实例的世界变换，colors 是逐实例颜色（空 = 不染色）。
## 返回 MultiMeshInstance3D（调用方负责 add_child）；网格/材质都走缓存，只有节点是新的。
static func make_multimesh(kind: StringName, transforms: Array,
		colors: Array = []) -> MultiMeshInstance3D:
	var k := _normalize(kind)
	if transforms.is_empty():
		return null
	var mesh := batch_mesh(k)
	if mesh == null:
		return null

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	# use_colors 必须在 instance_count 之前打开：先分配实例缓冲、再改格式，
	# 颜色通道不会跟着重建（运行时会刷 "Multimesh isn't using colors"）。
	var use_color: bool = not colors.is_empty()
	mm.use_colors = use_color
	mm.instance_count = transforms.size()
	for i in transforms.size():
		var xf: Transform3D = transforms[i]
		mm.set_instance_transform(i, xf)
		if use_color:
			mm.set_instance_color(i, colors[i % colors.size()])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "装饰_%s" % String(k)
	mmi.multimesh = mm
	mmi.material_override = _batch_material(k)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dist: float = float(VIEW_DISTANCE.get(k, 0.0))
	if dist > 0.0:
		# 可见距离是**整批**的，且按合并包围盒的中心算距离。一簇装饰铺满 200m 地图时，
		# 直接写 dist 会让整批在镜头离地图中心远一点时突然消失 —— 必须加上批的半径。
		mmi.visibility_range_end = dist + _batch_radius(transforms)
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mmi


## 一批实例的包围半径（相对原点；用于修正整批可见距离）
static func _batch_radius(transforms: Array) -> float:
	var r: float = 0.0
	for xf in transforms:
		r = maxf(r, (xf as Transform3D).origin.length())
	return r


## 合批材质：顶点色（= 逐实例颜色）乘进 albedo。装饰物不反光、不透明、单面剔除。
##
## 按**种类**分开缓存：草丛 / 碎石各带一张灰度细节贴图（叶脉 / 石面颗粒），
## 只乘细节不改色 —— 绿/灰仍旧由逐实例色决定，所以"每实例一色"不会丢。
static func _batch_material(kind: StringName) -> StandardMaterial3D:
	var k := _normalize(kind)
	if _batch_material_cache.has(k):
		return _batch_material_cache[k]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	m.vertex_color_use_as_albedo = true
	m.roughness = BATCH_ROUGHNESS
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_BACK
	var tex_path := ""
	# 基色必须从**调色板**取，和 自然材质库 / MatKit 是同一套色。
	# 以前这里把 albedo_color 抬到 1.25 白，等于绕开调色板：
	# 碎石/草丛算出来是 ~0.9 的近白，跟关卡里那批"自然_rock 冷灰"完全是两种皮，
	# 草地上一块块白斑就是它们（老板说的"杂牌军"）。
	var base: Color = Color(1, 1, 1, 1)
	match k:
		&"grass":
			tex_path = "res://美术/模型/草丛_leaf_albedo.png"
			base = MatKit.palette().colors.get("grass", Color(0.42, 0.52, 0.30))
		&"rubble":
			tex_path = "res://美术/模型/岩石_rock_albedo.png"
			base = MatKit.palette().colors.get("rock", Color(0.47, 0.50, 0.51))
	if not tex_path.is_empty() and ResourceLoader.exists(tex_path):
		m.albedo_texture = load(tex_path)
		# 最终 albedo = albedo_color × 灰度贴图(≈0.88) × 逐实例顶点色。
		# 顶点色均值：草丛 ~0.97、碎石 ~0.72（见 地表细节.gd 的 cols 生成）。
		# 反解 albedo_color，让**最终色**落回调色板原色，而不是靠拍脑袋抬到 1.25。
		var vc_avg: float = 0.97 if k == &"grass" else 0.72
		var k_gain: float = 1.0 / maxf(0.05, 0.88 * vc_avg)
		m.albedo_color = Color(base.r * k_gain, base.g * k_gain, base.b * k_gain, 1.0)
	_batch_material_cache[k] = m
	return m


## 递归把"可见网格"烘进 SurfaceTool，返回写进去的 surface 数。
## 变换逐级相乘：场景根上的缩放（草丛 0.55 / 碎石 1.35）也会被烘进去。
##
## 为什么不用 `st.append_from`：它会原样拷贝源网格，树/岩石 GLB 多半**没有 COLOR 通道**，
## 而合批材质开了 `vertex_color_use_as_albedo` → 这些网格会整块变黑（草丛就是这样消失的）。
## 这里逐顶点补一个白色顶点色，实例色才有地方乘。
static func _append_surfaces(st: SurfaceTool, node: Node, parent_xf: Transform3D) -> int:
	if node == null:
		return 0
	# 隐藏的件连同子树一起跳过（草丛就是靠这个只留一个树冠簇）
	if not node.visible:
		return 0
	var xf: Transform3D = parent_xf
	var n3 := node as Node3D
	if n3 != null:
		xf = parent_xf * n3.transform
	var count: int = 0
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s in mi.mesh.get_surface_count():
			_append_surface(st, mi.mesh, s, xf)
			count += 1
	for c in node.get_children():
		count += _append_surfaces(st, c, xf)
	return count


## 逐顶点写入（位置 × 变换，法线 × 基，顶点色 = 白）
static func _append_surface(st: SurfaceTool, mesh: Mesh, surf: int, xf: Transform3D) -> void:
	var arr: Array = mesh.surface_get_arrays(surf)
	if arr.size() < Mesh.ARRAY_MAX:
		return
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var has_n: bool = norms.size() == verts.size()
	# UV 一起搬：合批材质要乘细节贴图（叶脉/石面），没 UV 就退化成平色
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var has_uv: bool = uvs.size() == verts.size()
	var nb: Basis = xf.basis.inverse().transposed()
	var idx: Variant = arr[Mesh.ARRAY_INDEX]
	var white := Color(1, 1, 1, 1)
	if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
		for k in (idx as PackedInt32Array):
			st.set_color(white)
			st.set_uv(uvs[k] if has_uv else Vector2.ZERO)
			if has_n:
				st.set_normal((nb * norms[k]).normalized())
			st.add_vertex(xf * verts[k])
	else:
		for k in range(verts.size()):
			st.set_color(white)
			st.set_uv(uvs[k] if has_uv else Vector2.ZERO)
			if has_n:
				st.set_normal((nb * norms[k]).normalized())
			st.add_vertex(xf * verts[k])


# ===========================================================================
# 工具
# ===========================================================================

## 中文名 / 英文 id 统一成规范种类名
static func _normalize(kind: StringName) -> StringName:
	if SCENE_FILE.has(kind):
		return kind
	if ALIAS.has(kind):
		return ALIAS[kind]
	return kind


## 清空缓存（退出前调用，避免关停时"资源仍在使用"）
static func clear_cache() -> void:
	_scenes.clear()
	_batch_meshes.clear()
	_batch_material_cache.clear()


## 已登记的种类（调试/自检用）
static func kinds() -> Array:
	return SCENE_FILE.keys()
