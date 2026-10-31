@tool
class_name TreeLibrary
extends RefCounted
## **树库**：程序化树的池化缓存 + LOD 装配 + 材质。
##
## 为什么要有这一层（而不是每棵树现长）：
##   · 一棵树 = 一颗 ArrayMesh，现长一次约 8~20ms，单局 150~250 棵 → 开局会硬卡；
##   · 池化后：同 (品种, 档, 变体) 全场景**共享同一个 ArrayMesh**，
##     顶点数据只占一份，生成次数 = 品种 × 档 × 变体，跟树的数量无关。
##
## 随机感从哪来：每棵树存一个种子（种子里含变体号 + 朝向 + 缩放），
##   变体号 = 种子 % POOL；朝向/缩放走节点的 transform。
##   所以"每一棵都不一样"但不增加任何一份顶点数据。
##
## LOD：三档 MeshInstance3D 叠在同一位置，靠 GeometryInstance3D.visibility_range 切档。
##   · 引擎自己按相机距离判定，**零脚本、零逐帧计算**（比每帧算距离的脚本省得多）；
##   · 每棵树同时只有 1 档参与渲染，另外两档只是"藏起来的节点"。

## 每个 (品种, 档) 的变体数量。变体越多林子越不重复，生成时间线性增长。
## 10 是实测的性价比拐点：1 品种 × 1 档（关 LOD）× 10 = 10 份网格，全量预热约 110ms。
##
## 2026-10-31：8 → 10。八棵树里必有一对"撞脸"，林子里一眼能数出来；
## 十棵之后同一屏（约 15~20 棵）已经找不到两块一样的冠形了。
const POOL := 10

## ★ 是否启用距离 LOD。
## 为什么默认关（2026-10-30 实测反馈）：三档的层级/叶片数不同，切档时树的**轮廓会变**，
## 玩家镜头一推一拉就以为"品种在刷新"。而单档一棵树只有 ~2.3k 面，
## 114 棵 = 26 万面，和换掉的那套 GLB 同量级，根本不值得为它换一个"会变形的树"。
## 要做 LOD 的话，三档必须**同层级、同叶片尺寸**，只减叶量/边数，否则还是会跳。
const USE_LOD := false

## 不启用 LOD 时，超过这个距离直接剔除（RTS 打不到那么远，远景只留剪影也没意义）
const VIEW_CULL := 175.0

## LOD 距离（米）。和建筑 LOD 的 46/96 对齐，便于统一调。
const LOD_NEAR_END := 52.0
const LOD_MID_END := 100.0

## 模型根节点名（和 ArtKit.build_model 的命名保持一致，选中/调试都认它）
const ROOT_PREFIX := "模型_"

static var _mesh_cache: Dictionary = {}
static var _mat: StandardMaterial3D = null
static var _gen_ms: float = 0.0
static var _gen_count: int = 0


# ===========================================================================
# 材质（全库共用一份）
# ===========================================================================

## 一棵树只有这一个材质 → 1 次 draw call。
##   · alpha scissor 而不是 blend：叶片是镂空卡片，blend 会带来排序与 overdraw 双份开销；
##   · cull_disabled：叶片双面可见；
##   · **不翻转背面法线**：球形法线是一个"全局一致的场"，只要 Godot 在背面自动翻转，
##     一半叶子就会黑掉。StandardMaterial3D 不做翻转，正合适；
##   · 顶点色当 albedo：品种/季节的颜色全在顶点里，材质可以全场景共用。
static func material() -> StandardMaterial3D:
	if _mat != null:
		return _mat
	var m := StandardMaterial3D.new()
	m.resource_name = "程序化树_叶干"
	m.albedo_texture = ProcTree.atlas()
	m.albedo_color = Color(1, 1, 1, 1)
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.35
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.roughness = 0.94
	m.metallic = 0.0
	m.metallic_specular = 0.18
	m.backlight_enabled = false
	m.disable_ambient_light = false
	_mat = m
	return m


# ===========================================================================
# 品种 / 变体
# ===========================================================================

## 无后缀的"野树"（程序化地图、基地树环用的都是这一个 id）默认长成哪一季。
## 主场景现在只要**夏季林** —— 一片林子里春秋冬混着会显乱；季节留给"编辑器手摆"。
## 想恢复混生，把它改成空串即可（season_of 里就走按种子加权那条路）。
const WILD_SEASON := "夏"


## 从 type_id 的后缀判品种："tree_春" → "春"；"tree" 之类没后缀的看 WILD_SEASON。
static func season_of(type_id: String, seed_val: int) -> String:
	var id := String(type_id)
	for s in ProcTree.SEASON_ORDER:
		if id.ends_with(s):
			return s
	if not WILD_SEASON.is_empty():
		return WILD_SEASON
	# 混生模式：按种子决定（同一棵树永远同一个品种），权重偏"夏"。
	# RTS 机位下深绿最耐看，春花和秋黄当点缀。
	var r: float = float(abs(seed_val) % 1000) / 1000.0
	if r < 0.30:
		return "春"
	if r < 0.74:
		return "夏"
	if r < 0.95:
		return "秋"
	return "冬"


static func variant_of(seed_val: int) -> int:
	return abs(seed_val) % POOL


## 是不是程序化树（tree / tree_春 / tree_夏 / tree_秋 / tree_冬）。
## 判据只看 id 前缀：程序化树不吃 glb，同时也就意味着"可以在编辑器里随便摆"。
static func is_tree(id: StringName) -> bool:
	return String(id).begins_with("tree")


## 程序化地图（没存种子）→ 由落点反推一组稳定的外观参数。
## 同一棵树每次进游戏长一样；相邻两棵完全不同（坐标哈希，不是顺序计数）。
##
## 2026-10-31：除了 yaw，再补三样"每棵树都该不一样"的东西 ——
##   · scale  0.84~1.18：一片林子高低错落，才不像用一把刷子刷出来的；
##   · tilt   两轴各 ±2.4°：整齐划一的竖直树冠是"复制粘贴"最明显的破绽；
##   · sink   6~14cm 压进地里：树根不悬空，坡地上也不会露出底盘。
## 这三样都从同一个坐标哈希派生，所以**确定性**（同一棵树永远同一个样子）。
static func proc_at(pos: Vector3) -> Dictionary:
	var hx: int = int(round(absf(pos.x) * 31.0))
	var hz: int = int(round(absf(pos.z) * 31.0))
	var h: int = ((hx * 73856093) ^ (hz * 19349663)) & 0x7fffffff
	var h2: int = ((h * 1103515245 + 12345) & 0x7fffffff)
	var h3: int = ((h2 * 1103515245 + 12345) & 0x7fffffff)
	return {
		"seed": h,
		"yaw": float(h % 6283) / 1000.0,
		"scale": 0.84 + float(h2 % 1000) / 1000.0 * 0.34,
		"tilt": Vector2(
			(float(h2 / 1000 % 1000) / 1000.0 - 0.5) * 0.084,
			(float(h3 % 1000) / 1000.0 - 0.5) * 0.084),
		"sink": 0.06 + float(h3 / 1000 % 1000) / 1000.0 * 0.08,
	}


## 取（并缓存）一份网格。tier: 0 近 / 1 中 / 2 远
static func mesh(season: String, tier: int, variant: int, height: float) -> ArrayMesh:
	var key := "%s|%d|%d|%.2f" % [season, tier, variant, height]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var t0: int = Time.get_ticks_usec()
	var m: ArrayMesh = ProcTree.build(season, tier, variant * 7919 + 13, height)
	_gen_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	_gen_count += 1
	_mesh_cache[key] = m
	return m


# ===========================================================================
# 装配
# ===========================================================================

## 造一棵树的视觉根节点。
## 默认单档（USE_LOD=false）：一个 MeshInstance3D，永不换网格 —— "地图定格后树就不变"。
## 打开 LOD 时：三档 MeshInstance3D 叠在同一位置，靠 visibility_range 切档。
## proc 里可含：season（品种）、seed（变体种子）、yaw（朝向）、
##              scale（整体缩放 0.84~1.18）、tilt（两轴倾斜，弧度）、sink（压进地里几米）。
static func build_visual(def: UnitDef, proc: Dictionary) -> Node3D:
	var root := Node3D.new()
	var id: String = String(def.id) if def != null else "tree"
	var seed_val: int = int(proc.get("seed", 0))
	var season: String = String(proc.get("season", ""))
	if season.is_empty():
		season = season_of(id, seed_val)
	var variant: int = variant_of(seed_val)
	var height: float = def.height if def != null else 5.5
	root.name = ROOT_PREFIX + "程序化树"

	# 每棵树的"体型"：缩放 / 倾斜 / 下沉。三者都只动**这个视觉根**，
	# 单位本体的占地、选中半径、寻路都不受影响。
	var sc: float = clampf(float(proc.get("scale", 1.0)), 0.6, 1.6)
	if absf(sc - 1.0) > 0.001:
		root.scale = Vector3(sc, sc, sc)
	var tilt: Variant = proc.get("tilt", Vector2.ZERO)
	if tilt is Vector2 and (tilt as Vector2) != Vector2.ZERO:
		root.rotation = Vector3((tilt as Vector2).x, 0.0, (tilt as Vector2).y)
	root.position.y = -clampf(float(proc.get("sink", 0.0)), 0.0, 0.5)

	if not USE_LOD:
		var mi := _make_mesh_node(season, 0, variant, height, "LOD0")
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.visibility_range_end = VIEW_CULL
		root.add_child(mi)
		return root

	var ranges := [
		Vector2(0.0, LOD_NEAR_END),
		Vector2(LOD_NEAR_END, LOD_MID_END),
		Vector2(LOD_MID_END, 0.0),
	]
	for tier in 3:
		var mi := _make_mesh_node(season, tier, variant, height, "LOD%d" % tier)
		# 只有近档投影：远档一片小树影，收益不大，阴影 pass 却要多渲染一遍
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if bool(ProcTree.TIERS[tier]["shadow"]) \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var r: Vector2 = ranges[tier]
		mi.visibility_range_begin = r.x
		mi.visibility_range_end = r.y
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		root.add_child(mi)
	return root


static func _make_mesh_node(season: String, tier: int, variant: int, height: float,
		node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh(season, tier, variant, height)
	mi.material_override = material()
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


## 编辑器预览用：只要一档（近），不挂 visibility_range
static func build_preview(season: String, seed_val: int, height: float) -> MeshInstance3D:
	var mi := _make_mesh_node(season, 0, variant_of(seed_val), height, "程序化树预览")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## 实际会用到哪些档（关 LOD 时只有 0），预热按这个来，少生成两倍网格
static func tiers_used() -> Array:
	return [0, 1, 2] if USE_LOD else [0]


## 预热：开局/编辑器启动时把要用到的 (品种 × 档 × 变体) 一次性生成好，
## 避免玩家砍树、镜头推进时突然卡一下。
static func prewarm(seasons: Array, height: float) -> void:
	for s in seasons:
		for tier in tiers_used():
			for v in POOL:
				mesh(String(s), tier, v, height)


static func stats() -> Dictionary:
	return {
		"网格份数": _mesh_cache.size(),
		"生成次数": _gen_count,
		"生成总耗时ms": snappedf(_gen_ms, 0.01),
		"变体数": POOL,
		"LOD": ("开 %s" % str([LOD_NEAR_END, LOD_MID_END])) if USE_LOD \
			else ("关（单档，%.0fm 外剔除）" % VIEW_CULL),
	}


static func clear_cache() -> void:
	_mesh_cache.clear()
	_gen_ms = 0.0
	_gen_count = 0
