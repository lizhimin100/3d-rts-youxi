class_name SimpleAI
extends Node
## **简单 AI**：一个"真有压力"的对手，不是站着挨揍的木头人。
##
## 每 `think_interval` 秒思考一次（间隔来自难度档，绝不硬编码），按优先级：
##   1. 农民不足 → 大本营排农民；有闲农民 → 按缺口比例派去采金/采木
##   2. 人口快满 → 找基地附近空位造农场
##   3. 军队不足 max_army → 兵营按 composition 权重出兵
##   4. 自己建筑掉血 → 按 defend_ratio 派兵回防
##   5. 到点 且 军队 ≥ min_wave_size → 集结全部军队 ATTACK_MOVE 扑玩家基地
##
## 所有数值来自 `Cfg.difficulty(Game.difficulty_index)`，一个都不写死。
## 出兵/建造走 `Game.pay`（经 queue_train / order_build），**绝无虚空刷兵**。

## 日志前缀（只在关键决策打印，不刷屏）
const LOG_PREFIX: String = "[AI]"
## 大本营最多排几个农民（农民便宜，排两个不心疼）
const MAX_QUEUE_PEASANT: int = 2
## 兵营最多排几个兵。
## ⚠ 这里必须是 1：排 2 个会把两笔钱一起锁在队列里，等第二座兵营盖好时
## 已经付不出这个兵的钱，结果产能白建、军队反而更少（实测过，别改成 2）。
const MAX_QUEUE_ARMY: int = 1
## 农民允许比军队多几个。超过就先补兵（"先有枪杆子，再贪经济"）。
## 这个值决定 AI 的贪心程度：越大越偏经济，越小越偏军事。
const VILLAGER_ARMY_GAP: int = 2
## 每座兵营"负责"的军队规模上限：军队目标越大越要多盖兵营才能跟上出兵节奏。
## （单兵营 18~28s 才出一个兵，一波间隔只有 22~52s，不扩建根本喂不饱 max_army）
const UNITS_PER_BARRACKS: float = 8.0
## 兵营数量上限（再多也没资源养）
const MAX_BARRACKS: int = 3
## 回防指令重新下达的间隔（秒）
const DEFEND_REISSUE: float = 4.0
## 找空位建造：搜索的环半径范围（米）
const BUILD_SEARCH_MIN: float = 8.0
const BUILD_SEARCH_MAX: float = 34.0
const BUILD_SEARCH_STEP: float = 3.0
## 每个环采样多少个方向
const BUILD_SEARCH_ANGLES: int = 14

## **外部注入的指挥阵营**：副官用它指挥玩家阵营；敌方 AI 不传，走 Game.enemy_faction。
## 这样"一套大脑"能同时驱动人机和副官，行为不会分叉成两套怪东西。
var command_faction: RtsFaction = null
## 思考节奏倍率（副官用 0.8：比"一般中等 AI"反应更快）
var think_scale: float = 1.0
## 日志前缀（子类可换成 [副官]）
var log_prefix: String = LOG_PREFIX

var _faction: RtsFaction = null
var _think: float = 0.0
## 巡逻/撤退节流
var _patrol_cd: float = 0.0
## 下一波的时间点（秒，Game.elapsed 口径）
var _next_wave_at: float = 0.0
## 已发起波数
var _wave_index: int = 0
## 回防冷却
var _defend_cd: float = 0.0
## 是否已初始化（打印过一次开局日志）
var _announced: bool = false


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	_faction = command_faction if command_faction != null else Game.enemy_faction
	if _faction != null:
		_init_wave_clock()
	# 阵营可能比 AI 晚建立（主场景先 add_child 后 setup_factions）——在 _process 里兜底
	# 验收脚本改走 `--autotest`（主场景挂 代码/测试/自动试玩.gd），不再挂在 AI 上：
	# 旧的自检会污染真实对局（刷 2 座农场、动玩家农民），并且在 t=60s 时 get_tree().quit()。

	# （旧的 TEMP-SLEDGE-SELFTEST 钩子已删除：它指向的 代码/单位/_自检.gd 早就不存在，
	#   留着只会让后来的人以为还有一条自检通路。验收统一走 代码/测试/ 下的脚本。）


func _init_wave_clock() -> void:
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_next_wave_at = diff.first_wave_delay
	_wave_index = 0


func _process(delta: float) -> void:
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	if _faction == null or not is_instance_valid(_faction):
		_faction = command_faction if command_faction != null else Game.enemy_faction
		if _faction == null:
			return
		_init_wave_clock()

	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_think -= delta
	_defend_cd = maxf(_defend_cd - delta, 0.0)
	_patrol_cd = maxf(_patrol_cd - delta, 0.0)
	if _think > 0.0:
		return
	_think = maxf(diff.think_interval * think_scale, 0.1)

	if not _announced:
		_announced = true
		_log("接管 %s（节奏 %.2fs）" % [
			_faction.display_name, maxf(diff.think_interval * think_scale, 0.1)])

	# --- 1. 经济：农民 ---
	_manage_peasants(diff)
	# --- 2. 经济：派活 / 造农场 ---
	_assign_workers(diff)
	_manage_food(diff)
	# --- 3. 军事：兵营出兵 ---
	_manage_army(diff)
	# --- 3.5 残血先撤，别在前面白给 ---
	_manage_retreat()
	# --- 4. 防守 ---
	_manage_defense(diff)
	# --- 4.5 没战事就出去巡逻，别全挤在基地里发呆 ---
	_manage_patrol()
	# --- 5. 进攻（分兵：主力出击 + 留人守家）---
	_manage_waves(diff)


# ===========================================================================
# 1. 农民
# ===========================================================================

func _manage_peasants(diff: DifficultyDef) -> void:
	var peasants: int = _faction.count_units(&"peasant")
	if peasants >= diff.target_peasants:
		return
	# 先有枪杆子，再贪经济：农民数量超过军队太多时就不再补农，把钱留给兵营。
	# 不加这一闸的话，起始金币会被一口气灌进农民，兵营全程饿着（实测：目标 8/10 时
	# 60 秒只出 2 个兵，比"贪经济"亏得更狠）。
	if peasants >= _army_units().size() + VILLAGER_ARMY_GAP:
		return
	var townhall: RtsBuilding = _first_building(&"townhall")
	if townhall == null:
		return
	if townhall.train_count() >= MAX_QUEUE_PEASANT:
		return
	if townhall.queue_train(&"peasant"):
		_log("排农民（现有 %d / 目标 %d，军队 %d）"
				% [peasants, diff.target_peasants, _army_units().size()])


# ===========================================================================
# 2. 派活 / 农场
# ===========================================================================

## 给闲着的农民派采集活：按"缺口比例"分金木，别全挤一个矿
func _assign_workers(_diff: DifficultyDef) -> void:
	var workers: Array = _workers()
	if workers.is_empty():
		return
	# 统计已在采集的分配情况
	var on_gold: int = 0
	var on_wood: int = 0
	var idle: Array = []
	for w in workers:
		var k: int = int(w.call("gather_kind"))
		if k == RtsConst.Harvest.GOLD:
			on_gold += 1
		elif k == RtsConst.Harvest.WOOD:
			on_wood += 1
		elif bool(w.call("is_idle_like")):
			idle.append(w)
	if idle.is_empty():
		return

	var share: float = _gold_share(_diff)
	var total: int = workers.size()
	var want_gold: int = int(round(float(total) * share))
	var base: Vector3 = RtsWorld.base_center(_faction)
	var radius: float = Cfg.game.map_size * 0.75

	for w in idle:
		# 谁少补谁
		var kind: int = RtsConst.Harvest.GOLD
		if on_gold >= want_gold and on_wood < total - want_gold:
			kind = RtsConst.Harvest.WOOD
		elif on_gold >= want_gold:
			kind = RtsConst.Harvest.WOOD
		var node: Node3D = Game.find_nearest_harvestable(
				w.global_position, kind, base, radius)
		if node == null and kind == RtsConst.Harvest.WOOD:
			# 木头没了就回去采金，别让农民站着
			kind = RtsConst.Harvest.GOLD
			node = Game.find_nearest_harvestable(w.global_position, kind, base, radius)
		if node == null:
			continue
		w.call("order_gather", node)
		if kind == RtsConst.Harvest.GOLD:
			on_gold += 1
		else:
			on_wood += 1


## 金木人力分配比例：**从兵种与建筑成本推导**，不用拍脑袋常数
func _gold_share(diff: DifficultyDef) -> float:
	var gold: float = 0.0
	var wood: float = 0.0
	for id in diff.composition.keys():
		var d: UnitDef = Cfg.unit(id)
		if d == null:
			continue
		var w: float = float(diff.composition[id])
		gold += float(d.gold_cost) * w
		wood += float(d.wood_cost) * w
	# 把"盖房子要的木头"也算进去（农场/兵营/箭塔，各按 2 座估）
	for bid in [&"farm", &"barracks", &"tower"]:
		var bd: UnitDef = Cfg.unit(bid)
		if bd == null:
			continue
		gold += float(bd.gold_cost) * 2.0
		wood += float(bd.wood_cost) * 2.0
	var total: float = gold + wood
	if total <= 0.0:
		return 0.5
	return clampf(gold / total, 0.25, 0.85)


## 人口不够就补农场
func _manage_food(diff: DifficultyDef) -> void:
	if not _need_farm(diff):
		return
	var farm_def: UnitDef = Cfg.unit(&"farm")
	if farm_def == null:
		return
	# 已经在造农场了就别再造
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if b.def == null or b.def.id != &"farm":
			continue
		if b is RtsBuilding and not b.is_constructed:
			return

	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(farm_def.footprint)
	if spot == Vector3.INF:
		return
	builder.order_build(farm_def, spot, _build_yaw_at(spot))
	_log("造农场（人口 %d/%d）" % [_faction.food_used(), _faction.food_cap()])


## 人口是否已经不够下一个兵种了（用"最贵的那个兵种"作为判据，别拍常数）
func _need_farm(diff: DifficultyDef) -> bool:
	var max_food: int = 1
	for id in diff.composition.keys():
		var d: UnitDef = Cfg.unit(id)
		if d == null:
			continue
		max_food = maxi(max_food, d.food_cost)
	# 还要留出农民的份
	var peasant: UnitDef = Cfg.unit(&"peasant")
	if peasant != null:
		max_food = maxi(max_food, peasant.food_cost)
	return not _faction.has_food(max_food)


## 找基地附近的合法空位。
##
## **必须先吸附再判定**：判定用的是吸附后的点，落地用的也是这个点（order_build
## 内部还会再吸一次，幂等），否则会出现"AI 找到空位、工地却被判不能建"的断链。
func _find_build_spot(footprint: Vector2i) -> Vector3:
	var center: Vector3 = RtsWorld.base_center(_faction)
	var r: float = BUILD_SEARCH_MIN
	while r <= BUILD_SEARCH_MAX:
		for i in range(BUILD_SEARCH_ANGLES):
			var ang: float = TAU * float(i) / float(BUILD_SEARCH_ANGLES)
			var raw := Vector3(center.x + cos(ang) * r, 0.0, center.z + sin(ang) * r)
			var p: Vector3 = 建筑网格.snap_point(raw, footprint)
			if 建筑网格.can_place(p, footprint):
				return p
		r += BUILD_SEARCH_STEP
	return Vector3.INF


## 建筑朝向：正面（出兵口在 -Z）朝着己方基地，再吸到 90° 档。
## 这样 AI 的房子不会各朝各的，出兵点也总是落在基地内侧（可走率更高）。
func _build_yaw_at(spot: Vector3) -> float:
	var c: Vector3 = RtsWorld.base_center(_faction)
	var dx: float = c.x - spot.x
	var dz: float = c.z - spot.z
	if absf(dx) < 0.001 and absf(dz) < 0.001:
		return 0.0
	return 建筑网格.snap_yaw(atan2(-dx, -dz))


## 挑一个能去盖房子的农民（优先闲着的，其次正在采集的）
func _pick_builder() -> RtsUnit:
	var best: RtsUnit = null
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null or not RtsWorld.is_worker_def(u.def):
			continue
		if u.order == RtsConst.Order.BUILD:
			return null  # 已经有人去盖了
		if bool(u.call("is_idle_like")):
			return u
		if best == null:
			best = u
	return best


# ===========================================================================
# 3. 出兵
# ===========================================================================

func _manage_army(diff: DifficultyDef) -> void:
	var army: int = _army_units().size()
	if army >= diff.max_army:
		return
	# 先保证产能：兵营不够就先盖兵营（单兵营喂不饱 max_army）
	_maybe_build_barracks(diff)
	# 有产能了就要有"家门口的钉子"：每两座兵营配一座箭塔（上限 2）
	_maybe_build_tower()
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if b.def == null:
			continue
		if not b.has_method("queue_train"):
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not rb.is_constructed:
			continue
		if rb.train_count() >= MAX_QUEUE_ARMY:
			continue
		# 只让"能出战斗单位"的建筑出兵
		var picked: StringName = _pick_army_unit(rb, diff)
		if picked == &"":
			continue
		if rb.queue_train(picked):
			army += 1
			if army >= diff.max_army:
				return


## 按 composition 权重抽一个**当前造得起**的单位
func _pick_army_unit(b: RtsBuilding, diff: DifficultyDef) -> StringName:
	var pool: Array = []
	for id in diff.composition.keys():
		var w: int = int(diff.composition[id])
		if w <= 0:
			continue
		if not b.can_train(id):
			continue
		if not Game.can_afford(_faction, id):
			continue
		for i in range(mini(w, 8)):
			pool.append(id)
	if pool.is_empty():
		return &""
	return pool[randi() % pool.size()]


## 产能规划：兵营不足就再盖一座。
## 目标座数 = ceil(max_army / UNITS_PER_BARRACKS)，全部来自难度档，不写死。
func _maybe_build_barracks(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	var want: int = clampi(ceili(float(diff.max_army) / UNITS_PER_BARRACKS), 1, MAX_BARRACKS)
	var have: int = 0
	var building_now: bool = false
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != &"barracks":
			continue
		if not b.is_alive():
			continue
		have += 1
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and not rb.is_constructed:
			building_now = true
	if have >= want or building_now:
		return
	var bd: UnitDef = Cfg.unit(&"barracks")
	if bd == null or not Game.can_afford(_faction, &"barracks"):
		return
	# 必须留足"新兵营一完工就能立刻出一个兵"的钱。
	# 不然产能是建出来了，但没钱排队 → 空转的兵营反而拖慢军队成型（实测踩过）。
	var reserve: int = _cheapest_army_gold(diff) * MAX_QUEUE_ARMY
	if _faction.gold < bd.gold_cost + reserve:
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(bd.footprint)
	if spot == Vector3.INF:
		return
	builder.order_build(bd, spot, _build_yaw_at(spot))
	_log("扩建兵营（已有 %d / 目标 %d，军队上限 %d）" % [have, want, diff.max_army])


## 箭塔：基地需要"不动的那种兵"。目标 = 每 2 座兵营 1 座塔，最多 2 座。
func _maybe_build_tower() -> void:
	if _faction == null:
		return
	var want: int = clampi(_faction.count_buildings(&"barracks") / 2, 1, 2)
	if _faction.count_buildings(&"tower") >= want:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id == &"tower" and b is RtsBuilding and not b.is_constructed:
			return
	var td: UnitDef = Cfg.unit(&"tower")
	if td == null or not Game.can_afford(_faction, &"tower"):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(td.footprint)
	if spot == Vector3.INF:
		return
	builder.order_build(td, spot, _build_yaw_at(spot))
	_log("补箭塔（目标 %d 座）" % want)


## composition 里最便宜兵种的金币价（用来预留"部队口粮"，全来自 Cfg 数据）
func _cheapest_army_gold(diff: DifficultyDef) -> int:
	var cheapest: int = 0
	for id in diff.composition.keys():
		var d: UnitDef = Cfg.unit(id)
		if d == null or d.gold_cost <= 0:
			continue
		if cheapest == 0 or d.gold_cost < cheapest:
			cheapest = d.gold_cost
	if cheapest == 0:
		var fb: UnitDef = Cfg.unit(&"footman")
		if fb != null:
			cheapest = fb.gold_cost
	return cheapest


# ===========================================================================
# 4. 防守
# ===========================================================================

func _manage_defense(diff: DifficultyDef) -> void:
	var threatened: RtsBuilding = null
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not rb.is_constructed or not rb.is_alive():
			continue
		if rb.def == null:
			continue
		if rb.hp < rb.def.max_hp * 0.98:
			threatened = rb
			break
	if threatened == null:
		return
	if _defend_cd > 0.0:
		return
	_defend_cd = DEFEND_REISSUE

	var army: Array = _army_units()
	if army.is_empty():
		return
	var n: int = int(ceil(float(army.size()) * clampf(diff.defend_ratio, 0.0, 1.0)))
	n = clampi(n, 1, army.size())
	for i in range(n):
		var u: RtsUnit = army[i]
		if u == null or not is_instance_valid(u):
			continue
		u.order_attack_move(threatened.global_position)
	_log("回防：%d/%d 兵 → %s（血量 %.0f%%）" % [
		n, army.size(), threatened.def.display_name,
		100.0 * threatened.hp / maxf(threatened.def.max_hp, 1.0)])


# ===========================================================================
# 5. 进攻
# ===========================================================================

func _manage_waves(diff: DifficultyDef) -> void:
	if Game.elapsed < _next_wave_at:
		return
	var army: Array = _army_units()
	if army.size() < diff.min_wave_size:
		return
	# aggression 决定"是现在扑上去还是再攒攒"
	if randf() > clampf(diff.aggression, 0.0, 1.0):
		return

	# **分兵**：主力出击 + 留人守家。
	# 以前是全员扑基地 —— 玩家绕后一拆家就白给，AI 看起来"憨"。
	var push_n: int = clampi(int(ceil(float(army.size()) * 0.82)), 1, army.size())
	var target_pos: Vector3 = _push_target()
	var home: Vector3 = RtsWorld.base_center(_faction)
	for i in range(army.size()):
		var u: RtsUnit = army[i]
		if u == null or not is_instance_valid(u):
			continue
		if i < push_n:
			u.order_attack_move(target_pos)
		else:
			var ang: float = randf() * TAU
			u.order_move(home + Vector3(cos(ang) * 16.0, 0.0, sin(ang) * 16.0))

	_wave_index += 1
	var interval: float = maxf(
		diff.wave_interval - diff.wave_interval_decay * float(_wave_index),
		diff.wave_interval_min)
	_next_wave_at = Game.elapsed + interval
	_log("第 %d 波：%d 出击 / %d 留守 → %s（下一波 +%.0fs）" % [
		_wave_index, push_n, army.size() - push_n, _foe_name(), interval])


## 我打的那一家（敌方 AI → 玩家；副官 → 敌方）
func _foe_faction() -> RtsFaction:
	if Game.player_faction == null or Game.enemy_faction == null:
		return null
	if _faction == Game.player_faction:
		return Game.enemy_faction
	return Game.player_faction


func _foe_name() -> String:
	var f: RtsFaction = _foe_faction()
	return f.display_name if f != null else "敌方"


## 进攻落点：**优先离我方最近的那座敌方建筑**，没有就扑敌方基地中心。
## 以前只会打基地中心 —— 部队从一堆防守兵中间穿过，等于白送。
func _push_target() -> Vector3:
	var foe: RtsFaction = _foe_faction()
	if foe == null:
		return Vector3.ZERO
	var origin: Vector3 = RtsWorld.base_center(_faction)
	var best: Vector3 = RtsWorld.base_center(foe)
	var best_d: float = INF
	for b in foe.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if not b.is_alive():
			continue
		var d: float = b.global_position.distance_to(origin)
		if d < best_d:
			best_d = d
			best = b.global_position
	return best


# ===========================================================================
# 3.6 撤退 / 巡逻（"别白给、别发呆"）
# ===========================================================================

## 残血撤退：血量低于 32% 的战斗单位先回家，别在前线当经验包。
## 回满血后它会因为"闲着"被巡逻/进攻重新带走，不需要额外状态机。
func _manage_retreat() -> void:
	if _faction == null:
		return
	var home: Vector3 = RtsWorld.base_center(_faction)
	for u in _army_units():
		if u == null or not is_instance_valid(u) or u.def == null:
			continue
		if u.def.max_hp <= 0.0:
			continue
		if u.hp > u.def.max_hp * 0.32:
			continue
		if u.order == RtsConst.Order.MOVE:
			continue
		u.order_move(home)


## 巡逻：没有战事时让 1~3 个兵绕着基地转，别全挤在基地里发呆。
## 顺手还能"发现自己家门口的敌人"——AI 的反应速度肉眼可见地变快。
func _manage_patrol() -> void:
	if _patrol_cd > 0.0 or _faction == null:
		return
	var army: Array = _army_units()
	if army.size() < 2:
		return
	_patrol_cd = 9.0
	var n: int = clampi(int(ceil(float(army.size()) * 0.25)), 1, 3)
	var home: Vector3 = RtsWorld.base_center(_faction)
	var moved: int = 0
	for u in army:
		if moved >= n:
			break
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_idle_like():
			continue
		var ang: float = randf() * TAU
		var r: float = randf_range(16.0, 26.0)
		u.order_move(home + Vector3(cos(ang) * r, 0.0, sin(ang) * r))
		moved += 1


# ===========================================================================
# 查询辅助
# ===========================================================================

## 全部农民
func _workers() -> Array:
	var out: Array = []
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null:
			continue
		if RtsWorld.is_worker_def(u.def):
			out.append(u)
	return out


## 全部战斗单位（非农民，且是活着的移动单位）
func _army_units() -> Array:
	var out: Array = []
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null:
			continue
		if RtsWorld.is_worker_def(u.def):
			continue
		if u.def.kind != RtsConst.Kind.UNIT:
			continue
		out.append(u)
	return out


## 按 id 找第一座活着的建筑
func _first_building(id: StringName) -> RtsBuilding:
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if not b.is_alive() or b.def == null:
			continue
		if b.def.id != id:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and rb.is_constructed:
			return rb
	return null


## 关键决策日志（带统一前缀）
func _log(msg: String) -> void:
	print("%s %s" % [log_prefix, msg])
