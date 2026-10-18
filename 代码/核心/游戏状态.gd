extends Node
## **全局游戏状态（自动加载单例 `游戏`）**
## 职责：
##   - 持有两个阵营（玩家 / 敌人）与游戏阶段
##   - 维护全局单位注册表（谁活着、谁死了）
##   - 提供生成单位、找敌人、扣资源等公共服务
##   - 广播全局信号（战斗命中、选择变化、游戏结束……）供 UI / 镜头 / AI 订阅
##
## 约定：**这个类只管"全局"**，不写单位的具体行为（那是 RtsUnit），
## 也不写 UI（那是 RtsHud）。这样循环依赖最少。

# ===========================================================================
# 信号（名字与签名冻结，见 文档/作战条令.md §4.2）
# ===========================================================================
## 单位被生成
signal unit_spawned(unit: Node3D)
## 单位死亡（还没被移除）
signal unit_died(unit: Node3D)
## 建筑建造完成
signal building_completed(building: Node3D)
## 阵营资源/人口变化
signal resources_changed(faction: RtsFaction)
## 选择集合变化
signal selection_changed(units: Array)
## 战斗命中（伤害数字、火花、震屏都靠它）
signal combat_hit(attacker: Node3D, target: Node3D, damage: float, is_crit: bool)
## 投射物命中
signal projectile_impact(pos: Vector3, kind: int)
## 下达指令
signal order_issued(units: Array, order: int, target_pos: Vector3, target: Node3D)
## 顶部提示消息
signal notify(text: String, color: Color)
## 游戏结束
signal game_over(victory: bool)
## 请求镜头抖动
signal camera_shake(strength: float)


# ===========================================================================
# 状态
# ===========================================================================
## 游戏阶段（RtsConst.Phase）
var phase: int = RtsConst.Phase.PREPARE
## 已经进行的秒数（只在 RUNNING 阶段累加）
var elapsed: float = 0.0
## 难度下标
var difficulty_index: int = 0

## 玩家阵营
var player_faction: RtsFaction = null
## 敌人阵营
var enemy_faction: RtsFaction = null
## 关卡（由 主场景 挂上）
var level: Node3D = null

## 全部存活单位（含建筑）。由 register/unregister 维护
var _units: Array = []
## 全部存活建筑
var _buildings: Array = []
## 全部可采集物（金矿/树），用于 AI 与小地图
var _harvestables: Array = []


func _process(delta: float) -> void:
	if phase == RtsConst.Phase.RUNNING:
		elapsed += delta


# ===========================================================================
# 初始化
# ===========================================================================

## 建立本局的两个阵营（关卡初始化时调用一次）
func setup_factions() -> void:
	var cfg: GameConfig = Cfg.game
	player_faction = RtsFaction.new()
	player_faction.setup(
		RtsConst.Faction.PLAYER, true, "玩家", cfg.player_color,
		cfg.start_gold, cfg.start_wood
	)
	enemy_faction = RtsFaction.new()
	enemy_faction.setup(
		RtsConst.Faction.ENEMY, false, "兽人军团", cfg.enemy_color,
		cfg.start_gold + Cfg.difficulty(difficulty_index).bonus_gold, cfg.start_wood
	)
	_units.clear()
	_buildings.clear()
	_harvestables.clear()
	phase = RtsConst.Phase.PREPARE
	elapsed = 0.0


## 清空（重开时用）
func reset() -> void:
	_units.clear()
	_buildings.clear()
	_harvestables.clear()
	player_faction = null
	enemy_faction = null
	level = null
	phase = RtsConst.Phase.PREPARE
	elapsed = 0.0


# ===========================================================================
# 注册表
# ===========================================================================

## 登记一个单位/建筑
func register(unit: Node) -> void:
	if unit == null:
		return
	if unit is RtsBuilding:
		if not _buildings.has(unit):
			_buildings.append(unit)
		if unit.def != null and Cfg.game != null:
			pass
	elif unit is RtsHarvestable:
		if not _harvestables.has(unit):
			_harvestables.append(unit)
		return
	if not _units.has(unit):
		_units.append(unit)
	if unit.faction != null:
		var bucket: Array = unit.faction.buildings if unit is RtsBuilding else unit.faction.units
		if not bucket.has(unit):
			bucket.append(unit)


## 注销（死亡或移除后调用）
func unregister(unit: Node) -> void:
	if unit == null:
		return
	_units.erase(unit)
	_buildings.erase(unit)
	if unit is RtsHarvestable:
		_harvestables.erase(unit)
		return
	var fac: RtsFaction = unit.faction
	if fac != null:
		fac.units.erase(unit)
		fac.buildings.erase(unit)


## 全部存活单位（返回副本，避免外部误改）
func all_units() -> Array:
	return _units.duplicate()


## 全部可采集物
func all_harvestables() -> Array:
	return _harvestables.duplicate()


## 某阵营的全部单位
func faction_units(faction: RtsFaction) -> Array:
	if faction == null:
		return []
	return faction.units.duplicate()


## 敌对阵营
func enemy_of(faction: RtsFaction) -> RtsFaction:
	if faction == null:
		return null
	return enemy_faction if faction == player_faction else player_faction


## 从某点找最近的敌人（半径限制；没有返回 null）
func find_nearest_enemy(from: Vector3, faction: RtsFaction, radius: float) -> Node3D:
	if faction == null:
		return null
	var foe: RtsFaction = enemy_of(faction)
	if foe == null:
		return null
	var best: Node3D = null
	var best_d: float = radius * radius
	var pool: Array = []
	pool.append_array(foe.units)
	pool.append_array(foe.buildings)
	for u in pool:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive():
			continue
		var d: float = from.distance_squared_to(u.global_position)
		if d < best_d:
			best_d = d
			best = u
	return best


## 找最近的资源点（指定采集类型）
func find_nearest_harvestable(from: Vector3, kind: int, origin: Vector3, max_dist: float) -> Node3D:
	var best: Node3D = null
	var best_score: float = INF
	for h in _harvestables:
		if h == null or not is_instance_valid(h):
			continue
		if h.is_depleted():
			continue
		if h.harvest_kind != kind:
			continue
		var d: float = from.distance_to(h.global_position)
		if d > max_dist:
			continue
		# 优先近的，其次离基地近的（避免农民全跑远）
		var score: float = d + origin.distance_to(h.global_position) * 0.35
		if score < best_score:
			best_score = score
			best = h
	return best


# ===========================================================================
# 资源
# ===========================================================================

## 增加资源并广播
func add_resource(faction: RtsFaction, gold: int, wood: int) -> void:
	if faction == null:
		return
	faction.add_res(gold, wood)
	resources_changed.emit(faction)


## 能不能造
func can_afford(faction: RtsFaction, unit_id: StringName) -> bool:
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null or faction == null:
		return false
	return faction.can_afford(d) and faction.has_food(d.food_cost)


## 扣费（含人口检查）；失败返回 false
func pay(faction: RtsFaction, unit_id: StringName) -> bool:
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null or faction == null:
		return false
	if not faction.has_food(d.food_cost):
		return false
	if not faction.pay(d):
		return false
	resources_changed.emit(faction)
	return true


# ===========================================================================
# 生成
# ===========================================================================

## 生成一个单位/建筑。parent 为空时挂到关卡节点。
## 返回生成出来的节点（失败返回 null）。
func spawn_unit(faction: RtsFaction, unit_id: StringName, pos: Vector3, parent: Node3D = null) -> Node3D:
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null:
		push_warning("[游戏] 未知单位 id: %s" % unit_id)
		return null
	if parent == null:
		parent = level if level != null else get_tree().current_scene
	if parent == null:
		return null

	var node: Node3D = null
	if d.kind == RtsConst.Kind.BUILDING:
		node = RtsBuilding.new()
	elif d.kind == RtsConst.Kind.HARVESTABLE:
		node = RtsHarvestable.new()
	else:
		node = RtsUnit.new()

	node.name = "%s_%d" % [String(unit_id), Time.get_ticks_usec() % 100000]
	node.position = pos
	parent.add_child(node)
	node.setup(faction, d)
	register(node)
	unit_spawned.emit(node)
	return node


# ===========================================================================
# 结束 / 提示
# ===========================================================================

## 玩家胜利
func trigger_victory() -> void:
	if phase == RtsConst.Phase.RUNNING or phase == RtsConst.Phase.PREPARE:
		phase = RtsConst.Phase.VICTORY
		game_over.emit(true)


## 玩家失败
func trigger_defeat() -> void:
	if phase == RtsConst.Phase.RUNNING or phase == RtsConst.Phase.PREPARE:
		phase = RtsConst.Phase.DEFEAT
		game_over.emit(false)


## 顶部提示（信号 notify 的便捷入口；信号与函数不能同名，所以函数叫 toast）
func toast(text: String, color: Color = Color.WHITE) -> void:
	notify.emit(text, color)


## 请求镜头抖动
func shake(strength: float) -> void:
	camera_shake.emit(strength)


## 重开一局
func restart() -> void:
	reset()
	get_tree().paused = false
	get_tree().reload_current_scene()
