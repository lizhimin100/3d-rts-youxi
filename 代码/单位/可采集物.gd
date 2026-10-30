class_name RtsHarvestable
extends Node3D
## **可采集物**：金矿 / 树木。
##
## 枯竭表现（任务书要求）：
##   · 金矿：变暗（留在原地当场景残骸），从资源注册表里注销
##   · 树木：倒下 → 沉没 → 消失，并把它占的寻路格子放出来（别留隐形墙）
##
## 注意：可采集物的 faction 是 **null**（Game.spawn_unit(null, ...)），
## 所以这里任何地方都不能假设 faction 非空。

## 树倒下 / 沉没耗时（秒）
const FALL_TIME: float = 0.75
const SINK_TIME: float = 0.5
## 金矿枯竭后的明度系数
const DEPLETED_DARKEN: float = 0.32

var def: UnitDef = null
var remaining: int = 0
var harvest_kind: int = RtsConst.Harvest.GOLD
var faction: RtsFaction = null

## 外观（复用 UnitVisual：建模型 + 挂动画）
var visual: UnitVisual = null
## 程序化外观参数（树用）：{"season", "seed", "yaw"}。
## 存在节点上而不是塞回 UnitDef —— UnitDef 是全局共享的一整份表，见不得"每棵树不一样"。
var proc: Dictionary = {}
var _depleting: bool = false
var _visual_built: bool = false


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	if def != null:
		_ensure_visual()


## 装配（Game.spawn_unit 在 add_child 之后调）
## p_proc：程序化外观参数（树）。留空 = 由落点反推种子（程序化地图走这条）。
func setup(p_faction: RtsFaction, p_def: UnitDef, p_proc: Dictionary = {}) -> void:
	faction = p_faction
	def = p_def
	if def == null:
		return
	remaining = maxi(def.resource_amount, 1)
	harvest_kind = def.harvest_kind
	proc = p_proc.duplicate(true)
	if proc.is_empty() and TreeLibrary.is_tree(def.id):
		proc = TreeLibrary.proc_at(position)
	_ensure_visual()


func _ensure_visual() -> void:
	if _visual_built or def == null:
		return
	_visual_built = true
	visual = UnitVisual.new()
	visual.name = "外观"
	add_child(visual)
	var cfg: GameConfig = Cfg.game
	var col: Color = cfg.gold_color if harvest_kind == RtsConst.Harvest.GOLD \
			else Color(0.45, 0.72, 0.36)
	visual.build(def, col, proc)


# ===========================================================================
# 查询
# ===========================================================================

## 是否采空
func is_depleted() -> bool:
	return remaining <= 0


## 还有没有（统一 is_alive 接口，农民/关卡都会问）
func is_alive() -> bool:
	return remaining > 0


## 碰撞/站位半径
func get_radius() -> float:
	return def.body_radius if def != null else 1.0


## 头顶位置
func selection_point() -> Vector3:
	var h: float = def.height if def != null else 3.0
	return global_position + Vector3.UP * h


# ===========================================================================
# 采集
# ===========================================================================

## 采走 amount，返回**实际采到的数量**（不足就采完为止）
func consume(amount: int) -> int:
	if amount <= 0 or remaining <= 0:
		return 0
	var take: int = mini(amount, remaining)
	remaining -= take
	if remaining <= 0:
		remaining = 0
		_deplete()
	return take


## 枯竭
func _deplete() -> void:
	if _depleting:
		return
	_depleting = true

	# 立刻从资源注册表注销：农民和 AI 马上就能看到"这没货了"
	Game.unregister(self)

	if harvest_kind == RtsConst.Harvest.GOLD:
		_deplete_gold()
	else:
		_deplete_tree()


## 金矿：变暗，留在原地当场景残骸
func _deplete_gold() -> void:
	_darken(self, DEPLETED_DARKEN)
	ArtKit.vfx_death(global_position, Cfg.game.gold_color)


## 树木：倒下 → 沉没 → 消失，并把占格放出来
func _deplete_tree() -> void:
	_free_footprint()
	ArtKit.vfx_death(global_position + Vector3.UP * 1.0, Color(0.42, 0.62, 0.30))

	var tw: Tween = create_tween()
	# 朝随机一侧倒下去
	var dir: float = 1.0 if randf() > 0.5 else -1.0
	tw.tween_property(self, "rotation:z", deg_to_rad(84.0) * dir, FALL_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_interval(0.15)
	tw.tween_property(self, "position:y", position.y - 2.2, SINK_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(queue_free)


## 递归压暗所有网格材质（金矿枯竭）
func _darken(n: Node, factor: float) -> void:
	var mi := n as MeshInstance3D
	if mi != null:
		var mat := mi.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = Color(
				mat.albedo_color.r * factor,
				mat.albedo_color.g * factor,
				mat.albedo_color.b * factor,
				mat.albedo_color.a)
			mat.emission_energy_multiplier = 0.0
	for c in n.get_children():
		_darken(c, factor)


## 把树占的寻路格子放出来（只放"没有被别的活物占着"的格子，避免打通出隐形通道）
func _free_footprint() -> void:
	var pf: GridPathfinder = RtsWorld.pathfinder()
	if pf == null or def == null:
		return
	var fp: Vector2i = def.footprint
	if fp == Vector2i.ZERO:
		fp = Vector2i(1, 1)
	var center: Vector2i = pf.world_to_cell(global_position)
	var half_x: int = fp.x / 2
	var half_z: int = fp.y / 2
	var span_x: int = maxi(fp.x % 2, 1)
	var span_z: int = maxi(fp.y % 2, 1)

	# 先收集"别人还占着"的格子
	var occupied: Dictionary = {}
	for h in Game.all_harvestables():
		if h == null or not is_instance_valid(h) or h == self:
			continue
		var hd: UnitDef = h.def
		if hd == null:
			continue
		if h.has_method("is_depleted") and bool(h.call("is_depleted")):
			continue
		var hc: Vector2i = pf.world_to_cell(h.global_position)
		var hx: int = hd.footprint.x / 2
		var hz: int = hd.footprint.y / 2
		for dz in range(-hz, hz + maxi(hd.footprint.y % 2, 1)):
			for dx in range(-hx, hx + maxi(hd.footprint.x % 2, 1)):
				occupied[Vector2i(hc.x + dx, hc.y + dz)] = true

	for dz in range(-half_z, half_z + span_z):
		for dx in range(-half_x, half_x + span_x):
			var cell := Vector2i(center.x + dx, center.y + dz)
			if occupied.has(cell):
				continue
			pf.mark_blocked(cell, false)
