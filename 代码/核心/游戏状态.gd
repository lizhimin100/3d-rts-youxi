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
## 副官给玩家的**建议**（只投递，不产生任何游戏行为）
## payload 形如 {"code": "low_odds" / "request_control" / "under_attack",
##               "severity": "info" / "warn", "message": "…", ...}
signal adjutant_hint(payload: Dictionary)


# ===========================================================================
# 状态
# ===========================================================================
## 游戏阶段（RtsConst.Phase）
var phase: int = RtsConst.Phase.PREPARE
## 已经进行的秒数（只在 RUNNING 阶段累加）
var elapsed: float = 0.0
## 生成序号（节点名用）。必须是确定性的：同 seed 复跑要得到同一串名字。
var _spawn_seq: int = 0
## 难度下标
var difficulty_index: int = 0

## 玩家阵营（人类操作的那个；槽位 0）
var player_faction: RtsFaction = null
## "主要的"敌人阵营 —— 只为兼容旧代码/旧提示语保留，**不要再拿它当敌我判据**。
## 真正的判据是 team（见 is_enemy_of / enemies_of）。
var enemy_faction: RtsFaction = null
## **本局全部阵营**（多队图：每个出生点一个）。下标 = 槽位号。
var factions: Array[RtsFaction] = []
## **中立敌对阵营**（野怪，team 0）。故意**不放进 `factions`**：
##   · 它没有大本营，放进 factions 会让"胜负判定 / 开局布阵 / AI 接管"全部误伤；
##   · 但它必须能被 `enemies_of()` 看到，否则单位永远索不到野怪（见下面的 append）。
var neutral_faction: RtsFaction = null
## 关卡（由 主场景 挂上）
var level: Node3D = null

## **战争迷雾节点**（由 主场景 在 _setup_fog 里挂上；没有 = 无迷雾，全部可见）。
## ★ 单位索敌 / 开火都要问"我这一刻看不看得见他"，唯一出口是本文件的 `is_visible_to()`。
##   以前索敌只按半径找人（`find_nearest_enemy`），结果弩兵能隔着整片黑雾
##   锁定并射杀自己根本没看见的敌人（玩家 2026-11-06 反馈）。
##   迷雾只统计**玩家阵营（含盟友）**的视野：AI 阵营保持全知，否则 AI 会因为
##   玩家视角的迷雾表变瞎（这是刻意的非对称，写在 `is_visible_to` 里）。
var fog_node: Node = null

## **日夜系统**（由 主场景 在 4.98 挂上；没有它就是白天）。
## ★ 这是"现在是不是夜里"的**唯一全局出口**：AI / 副官 / 界面 / 营火都读这里，
##   不要再各自去 `get_parent().get("day_night")` 或者 get_node("../日夜") —— 那是
##   "谁挂谁知道"的写法，换层级就静默失效（踩过：营火白天不灭、AI 夜里出门）。
var day_night: Node = null


## 现在是不是夜里（没有日夜系统 = 永远白天）
func is_night() -> bool:
	if day_night == null or not is_instance_valid(day_night):
		return false
	if not day_night.has_method("is_night"):
		return false
	return bool(day_night.call("is_night"))


# ===========================================================================
# 可见性（索敌 / 开火 / 小地图共用的唯一口径）
# ===========================================================================
## 阵营 `f` 此刻能不能看见世界坐标 `pos`。
##
## 规则（2026-11-07 统一）：
##   · 没有迷雾节点 / 迷雾被 `--qa-reveal` 关掉 → 全部可见；
##   · **只有玩家阵营和它的盟友受迷雾约束**。AI 阵营、中立野怪一律返回 true：
##     迷雾表是按"玩家视角"算的，拿它去限制 AI 会让 AI 变瞎（不是变难）。
##     想要 AI 也受迷雾约束，得给每个 AI 单独算一张视野表，那是另一个工程。
##   · `explored_only = true` 用于建筑/资源：只要探索过就永远看得到（魔兽口径）。
func is_visible_to(f: RtsFaction, pos: Vector3, explored_only: bool = false) -> bool:
	if f == null or fog_node == null or not is_instance_valid(fog_node):
		return true
	if f.slot < 0:
		return true
	if player_faction == null or f != player_faction:
		# 盟友也吃玩家视角的迷雾（共用一张表）；非玩家阵营直接放行
		if player_faction == null or not player_faction.is_ally_of(f):
			return true
	if explored_only:
		if fog_node.has_method("is_world_explored_pos"):
			return bool(fog_node.call("is_world_explored_pos", pos))
		return true
	if fog_node.has_method("is_world_visible_pos"):
		return bool(fog_node.call("is_world_visible_pos", pos))
	return true


## `is_visible_to` 的节点版：建筑用"探索过"，其它用"此刻可见"。
func is_node_visible_to(f: RtsFaction, n: Node3D) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if n is RtsBuilding:
		return is_visible_to(f, n.global_position, true)
	return is_visible_to(f, n.global_position, false)

## **控制权登记表**（谁有权给单位下令）。由 _ready 建好，全项目共用一份：
## 玩家下过令的单位在"命令组"生命周期内不许副官/人机碰（见 代码/ai/控制权.gd）。
var control = null

## 全部存活单位（含建筑）。由 register/unregister 维护
var _units: Array = []
## 全部存活建筑
var _buildings: Array = []
## 全部可采集物（金矿/树），用于 AI 与小地图
var _harvestables: Array = []


## 控制权登记表必须在**任何 AI 之前**建好：副官的 _ready 可能比本单例晚，
## 但 _process 里的 tick 一定早于 AI 的思考（同一帧里自动加载先跑）。
func _ready() -> void:
	var s := load("res://代码/ai/控制权.gd")
	if s != null:
		control = s.new()
		control.attach()


func _process(delta: float) -> void:
	if phase == RtsConst.Phase.RUNNING:
		elapsed += delta
	# 命令组状态机：组内全部 idle 才算"命令结束"，然后进宽限期。
	if control != null:
		control.tick(elapsed)


# ===========================================================================
# 初始化
# ===========================================================================

## 建立本局的**全部阵营**（关卡初始化时调用一次）。
##
## 多队规则（用户口径）：
##   · 出生点数量 = Cfg.game.match_slots（默认 4）；
##   · 每个槽位属于哪个队 = Cfg.game.match_team_of_slot（默认 [1,1,2,3]）；
##     **同队 = 盟友**，互相不能打，共用一个队色；
##   · 队色不再是"蓝/红"两色写死，而是 match_team_colors 里的一套（蓝/红/绿/紫…）；
##   · **显示色**（faction.color）≠ 队色：你 = 队色（蓝）、盟友 = 青、
##     敌人 = 各自队色。判据仍是 team（is_ally_of），颜色只影响"长什么样"。
##     （用户口径：同队同色分不出"我的 / 盟友的"，盟友必须能一眼认出来是青色。）
##   · 显示色落到模型上走的是资产自带的染色区（建筑的 team / team_trim、
##     单位的 M_<zone>_team），所以"按模型染色区变队色"是天然成立的。
func setup_factions() -> void:
	var cfg: GameConfig = Cfg.game
	factions.clear()
	var slots: int = maxi(2, cfg.match_slots)
	var human_slot: int = clampi(cfg.match_human_slot, 0, slots - 1)
	var diff: DifficultyDef = Cfg.difficulty(difficulty_index)
	for i in range(slots):
		var f := RtsFaction.new()
		var team: int = cfg.team_of_slot(i)
		var human: bool = i == human_slot
		var wealth: int = cfg.start_gold + (0 if human else diff.bonus_gold)
		f.setup(i, human, cfg.slot_name(i, team), cfg.display_color_for_slot(i),
			wealth, cfg.start_wood)
		f.team = team
		f.slot = i
		f.is_ai = not human
		factions.append(f)
	player_faction = factions[human_slot]
	enemy_faction = null
	for f in factions:
		if f != player_faction and player_faction.is_enemy_of(f):
			enemy_faction = f
			break
	_units.clear()
	_buildings.clear()
	_harvestables.clear()
	phase = RtsConst.Phase.PREPARE
	elapsed = 0.0


# ===========================================================================
# 队伍 / 敌我（**唯一判据**：team 相同即盟友）
# ===========================================================================

## 本局全部阵营
func all_factions() -> Array:
	return factions.duplicate()


## 某个阵营的盟友（含自己；中立队为空）
func allies_of(f: RtsFaction) -> Array:
	var out: Array = []
	if f == null:
		return out
	for o in factions:
		if o != null and o.is_ally_of(f):
			out.append(o)
	return out


## 某个阵营的敌人（所有不同队且还活着的）
func enemies_of(f: RtsFaction) -> Array:
	var out: Array = []
	if f == null:
		return out
	for o in factions:
		if o != null and f.is_enemy_of(o):
			out.append(o)
	# 野怪（中立敌对）：只要还活着就算敌人 —— 玩家的兵/箭塔才会自动还手
	if neutral_faction != null and neutral_faction != f and neutral_faction.has_forces():
		out.append(neutral_faction)
	return out


## 敌方阵营里还有大本营的（胜负判定 / AI 目标选择用）
func living_enemies_of(f: RtsFaction) -> Array:
	var out: Array = []
	for o in enemies_of(f):
		if o.has_townhall():
			out.append(o)
	return out


## 该阵营是否玩家的盟友（含自己）
func is_ally_of_player(f: RtsFaction) -> bool:
	if player_faction == null or f == null:
		return true
	return player_faction.is_ally_of(f)


## 玩家的敌人是否已经全部出局（= 玩家赢了）
func all_enemies_defeated() -> bool:
	if player_faction == null:
		return false
	for o in factions:
		if o == null:
			continue
		if not player_faction.is_enemy_of(o):
			continue
		if o.has_townhall():
			return false
	return true


## 清空（重开时用）
func reset() -> void:
	_units.clear()
	_buildings.clear()
	_harvestables.clear()
	factions.clear()
	player_faction = null
	enemy_faction = null
	neutral_faction = null
	level = null
	day_night = null
	phase = RtsConst.Phase.PREPARE
	elapsed = 0.0
	if control != null:
		control.reset()


## 副官的"建议"通道：**只投递，不产生行为**。
## 与直接下令的区别是这条纪律：AI 与玩家意图冲突时只能建议（见 代码/ai/副官.gd）。
func suggest(payload: Dictionary) -> void:
	if payload == null or payload.is_empty():
		return
	adjutant_hint.emit(payload)


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


## 全部存活单位。
##
## ⚠ **返回的是内部数组本身，不是副本 —— 调用方只许遍历，不许增删改。**
##
## 为什么去掉 `.duplicate()`（2026-11-01 性能排查）：
##   这个函数被 战争迷雾 / 头顶血条 / 小地图 / HUD / 选择 / 分离 / 索敌 等
##   十几处**每帧**调用，每次都要复制 130+ 个元素并加一遍引用计数。
##   全工程 30 个调用点没有一个会改返回值，为它们每人复制一份纯属白烧 CPU + GC。
func all_units() -> Array:
	return _units


## 全部可采集物（同上：只读，别改返回值）
func all_harvestables() -> Array:
	return _harvestables


## **全单位空间哈希**（每帧最多重建一次，全工程共用一份）。
##
## 谁在用：
##   · `RtsUnit._shared_hash()` —— 单位分离（互相推开）
##   · `find_nearest_enemy()`   —— 索敌
## 以前这两条路各建一份，等于每帧把 130 个单位桶化两遍。
## 现在只留这里一份：`Engine.get_process_frames()` 当版本号，同帧直接复用。
var _unit_hash: SpatialHash = null
var _unit_hash_frame: int = -1


func unit_hash() -> SpatialHash:
	var f: int = Engine.get_process_frames()
	if _unit_hash == null:
		_unit_hash = SpatialHash.new(4.0)
	elif _unit_hash_frame == f:
		return _unit_hash
	_unit_hash_frame = f
	_unit_hash.clear()
	for u in _units:
		if u == null or not is_instance_valid(u):
			continue
		# 死掉的先不收（墓碑/正在播死亡动画的还在 _units 里）
		if u is RtsUnit and not u.is_alive():
			continue
		_unit_hash.insert(u.global_position, u)
	return _unit_hash


## 某阵营的全部单位
func faction_units(faction: RtsFaction) -> Array:
	if faction == null:
		return []
	return faction.units.duplicate()


## **最近的**敌对阵营（兼容旧接口；多队图下"敌人"可能有 2~3 个）。
## 新代码请用 enemies_of() / living_enemies_of()，它们返回全部敌人。
func enemy_of(faction: RtsFaction) -> RtsFaction:
	if faction == null:
		return null
	var best: RtsFaction = null
	var best_d: float = INF
	for o in factions:
		if o == null or not faction.is_enemy_of(o):
			continue
		var d: float = 0.0
		if level != null and level.has_method("base_center"):
			var a: Variant = level.call("base_center", faction)
			var b: Variant = level.call("base_center", o)
			if a is Vector3 and b is Vector3:
				d = (a as Vector3).distance_squared_to(b as Vector3)
		if d < best_d:
			best_d = d
			best = o
	return best


## 从某点找最近的敌人（**扫全部敌对阵营**；半径限制；没有返回 null）
##
## ★ 2026-11-01 性能重写 —— 这是"20~40fps"的头号主犯。
##   老实现：对每个敌对阵营 `append_array` 造一个 pool 数组，再把**全部敌人**
##   逐个 `is_instance_valid() / is_alive() / global_position` 看一遍。
##   137 个单位、每人每 0.3s 索敌一次 → 每秒 6 万次三元访问 + 上千次数组分配，
##   实测单这一项 ≈120ms/秒。
##   现在：先用**空间哈希**圈出半径内的候选（4m 一格，11m 半径 ≈ 49 格，
##   候选取 10~30 个，而不是 137 个），敌我判定放到内层 —— 同阵营的候选
##   一眼就跳过，连距离都不算。
##   语义完全不变：返回半径内最近的敌人（含中立野怪，口径同 enemies_of）。
func find_nearest_enemy(from: Vector3, faction: RtsFaction, radius: float) -> Node3D:
	if faction == null or radius <= 0.0:
		return null
	var best: Node3D = null
	var best_d: float = radius * radius
	for u in unit_hash().query(from, radius):
		if u == null or not is_instance_valid(u):
			continue
		if not (u is RtsUnit):
			continue
		var other: RtsUnit = u
		var of: RtsFaction = other.faction
		if of == null or of == faction:
			continue
		# 敌我判定：不同队伍就是敌人。中立野怪（team 0）单独放行 ——
		# 它**已经出现在哈希里**就说明还活着，所以不必再问 has_forces()
		# （那个函数要遍历整个阵营，放进这个每秒几百次的循环里会白烧 CPU）。
		if not faction.is_enemy_of(of) and of != neutral_faction:
			continue
		if not other.is_alive():
			continue
		var d: float = from.distance_squared_to(other.global_position)
		if d < best_d:
			best_d = d
			best = other
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
## proc：程序化外观参数（树用，{"season","seed","yaw"}），其它单位传空字典即可。
## 返回生成出来的节点（失败返回 null）。
func spawn_unit(faction: RtsFaction, unit_id: StringName, pos: Vector3,
		parent: Node3D = null, proc: Dictionary = {}) -> Node3D:
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

	# 名字里的序号用**自增计数器**，不用 Time.get_ticks_usec()：后者是墙钟，
	# 同 seed 复跑会得到不同的节点名，任何"按名字排序/查重"的地方都会跟着漂。
	_spawn_seq += 1
	node.name = "%s_%d" % [String(unit_id), _spawn_seq]
	node.position = pos
	parent.add_child(node)
	# 只有可采集物认 proc（树的品种/种子）；建筑/单位走原来的两参数 setup
	if node is RtsHarvestable:
		(node as RtsHarvestable).setup(faction, d, proc)
	else:
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
