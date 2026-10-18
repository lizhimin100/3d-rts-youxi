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
static var _batch_material_cache: StandardMaterial3D = null


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
	mm.instance_count = transforms.size()
	var use_color: bool = not colors.is_empty()
	mm.use_colors = use_color
	for i in transforms.size():
		var xf: Transform3D = transforms[i]
		mm.set_instance_transform(i, xf)
		if use_color:
			mm.set_instance_color(i, colors[i % colors.size()])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "装饰_%s" % String(k)
	mmi.multimesh = mm
	mmi.material_override = _batch_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dist: float = float(VIEW_DISTANCE.get(k, 0.0))
	if dist > 0.0:
		mmi.visibility_range_end = dist
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mmi


## 合批材质：顶点色（= 逐实例颜色）乘进 albedo。装饰物不反光、不透明、双面剔除。
static func _batch_material() -> StandardMaterial3D:
	if _batch_material_cache != null:
		return _batch_material_cache
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	m.vertex_color_use_as_albedo = true
	m.roughness = BATCH_ROUGHNESS
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_batch_material_cache = m
	return m


## 递归把"可见网格"烘进 SurfaceTool，返回写进去的 surface 数。
## 变换逐级相乘：场景根上的缩放（草丛 0.55 / 碎石 1.35）也会被烘进去。
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
			st.append_from(mi.mesh, s, xf)
			count += 1
	for c in node.get_children():
		count += _append_surfaces(st, c, xf)
	return count


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
	_batch_material_cache = null


## 已登记的种类（调试/自检用）
static func kinds() -> Array:
	return SCENE_FILE.keys()
