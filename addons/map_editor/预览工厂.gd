@tool
class_name MapPreviewFactory
extends RefCounted
## **预览工厂**：把一个 MapObject 变成编辑器里看得见的节点。
##
## 只有"造节点"这一件事，**不写回数据**：
##   · 单位/建筑 → UnitDef.model_path + model_scale；
##   · 装饰 → 资产目录里的 model；
##   · 模型缺了 → 一个按类别上色的方块（绝不返回 null）。
##
## 缓存 PackedScene，来回刷对象不会重复 load GLB。

static var _scene_cache: Dictionary = {}


static func build(o: MapObject) -> Node3D:
	if o == null:
		return null
	var info: Dictionary = MapAssets.find(o.type_id)
	var path: String = ""
	var model_scale: float = 1.0
	if not info.is_empty():
		path = String(info.get("model", ""))
		model_scale = float(info.get("scale", 1.0))
	if path.is_empty():
		path = String(o.properties.get("model", ""))
	var root := Node3D.new()
	root.name = "预览_" + String(o.type_id)
	var inst: Node3D = null
	if not path.is_empty():
		inst = _instance(path)
	if inst != null:
		root.add_child(inst)
		# 自然物统一材质：GLB 的 albedo 是灰度噪声，不上这一层树/草/岩石在编辑器里
		# 全是同一个灰白（跟游戏内也要一致）。@tool 下不走 class_name 直呼，
		# 用 load() 取脚本再调静态方法 —— class_name 在编辑器首次加载时可能还没注册。
		_套自然材质(inst)
	else:
		root.add_child(_placeholder(o))
	root.scale = Vector3.ONE * maxf(0.02, model_scale * maxf(0.05, o.scale))
	return root


static var _自然脚本: Script = null


## 给预览件套材质。
##   · 自然物（树/草/岩石…）：自然材质库，灰度 albedo 换成调色板色；
##   · 角色（带骨骼/动画的单位）：走 MatKit 卡通材质 + 默认阵营色 ——
##     否则编辑器里单位是 GLB 原样的灰白人偶，跟游戏里的蓝披风银甲完全是两个东西。
## 全失败也不抛：编辑器预览不能因为材质层挂掉而整个不显示。
static func _套自然材质(inst: Node3D) -> void:
	if _自然脚本 == null:
		_自然脚本 = load("res://代码/美术/自然材质.gd") as Script
	if _自然脚本 != null and bool(_自然脚本.call("_是角色", inst)):
		_套角色材质(inst)
		return
	if _自然脚本 != null:
		_自然脚本.call("apply", inst)


static var _材质库脚本: Script = null
## 编辑器预览用的默认阵营色（和玩家槽位 0 的蓝对齐，只为了让单位"有皮"）
const PREVIEW_TEAM := Color(0.19, 0.40, 0.74)


static func _套角色材质(inst: Node3D) -> void:
	if _材质库脚本 == null:
		_材质库脚本 = load("res://代码/美术/材质库.gd") as Script
	if _材质库脚本 == null:
		return
	# is_char = true：走角色那一档曝光（提亮 + 减 AO + 暗部补光）
	_材质库脚本.call("apply", inst, PREVIEW_TEAM, false, true)


static func _instance(path: String) -> Node3D:
	# 负缓存：坏路径只尝试一次，别每帧都去撞一次 load
	if _scene_cache.has(path):
		var cached: Variant = _scene_cache[path]
		if cached == null:
			return null
		return _instantiate(cached as PackedScene)
	if not ResourceLoader.exists(path):
		_scene_cache[path] = null
		push_warning("[预览工厂] 模型不存在，改用占位方块：%s" % path)
		return null
	var ps := load(path) as PackedScene
	_scene_cache[path] = ps
	if ps == null:
		push_warning("[预览工厂] 模型加载失败（不是 PackedScene），改用占位方块：%s" % path)
		return null
	return _instantiate(ps)


static func _instantiate(ps: PackedScene) -> Node3D:
	if ps == null:
		return null
	var n: Node = ps.instantiate()
	if n is Node3D:
		return n as Node3D
	n.queue_free()
	return null


## 占位方块：按类别给颜色 + 按 id 抖一点色相，一眼能看出"这个模型没加载上"
static func _placeholder(o: MapObject) -> Node3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var size := Vector3(0.8, 1.8, 0.8)
	match int(o.category):
		MapObject.Category.BUILDING:
			size = Vector3(5.0, 6.0, 5.0)
		MapObject.Category.RESOURCE:
			size = Vector3(2.5, 3.0, 2.5)
		MapObject.Category.DOODAD:
			size = Vector3(1.2, 1.2, 1.2)
	bm.size = size
	mi.mesh = bm
	mi.position.y = size.y * 0.5
	var mat := StandardMaterial3D.new()
	var h: float = float(abs(String(o.type_id).hash()) % 100) / 100.0
	match int(o.category):
		MapObject.Category.BUILDING:
			mat.albedo_color = Color(0.55, 0.45 + h * 0.2, 0.30)
		MapObject.Category.RESOURCE:
			mat.albedo_color = Color(0.30 + h * 0.2, 0.55, 0.35)
		_:
			mat.albedo_color = Color(0.70, 0.35 + h * 0.2, 0.75)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func clear_cache() -> void:
	_scene_cache.clear()
