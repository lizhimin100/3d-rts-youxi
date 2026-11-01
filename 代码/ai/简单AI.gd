class_name SimpleAI
extends Node
## **简单 AI**：一个"真有压力"的对手，不是站着挨揍的木头人。
##
## 一次思考（think）的流水线（顺序不是随意的，见每一步的注释）：
##   ① 命令调度器开局（本 tick 的预算/去重上下文）
##   ② 战略导演算指标 → 选计划 → 产出姿态 Posture
##   ③ 经济：补农 / 派采集 / 补人口
##   ④ 生产：按"每金战力 + 克制矩阵"选兵（不再是纯权重抽签）
##   ⑤ 科技：铁匠铺升级（旧版从来不做，金币全堆着）
##   ⑥ 军事：残血撤退 / 回防 / 巡逻 / 成波推进
##   ⑦ 反愚蠢审计**最后**跑 —— 它的救火命令要覆盖前面所有命令
##   ⑧ flush：真正把命令发出去（所有命令都受控制权过滤）
##
## 三条纪律：
##   · **不能抢玩家单位**：所有下令都经 CommandScheduler → Game.control 过滤；
##   · **不能下命令风暴**：到达判定 / 重发节流 / 卡死退避都在调度器里；
##   · **不能硬编码数值**：难度档 + 战略计划表 + 单位表，代码里只有结构。

## 日志前缀（只在关键决策打印，不刷屏）
const LOG_PREFIX: String = "[AI]"
## 大本营最多排几个农民（农民便宜，排两个不心疼）
const MAX_QUEUE_PEASANT: int = 2
## 兵营最多排几个兵。
## ⚠ 这里必须是 1：排 2 个会把两笔钱一起锁在队列里，等第二座兵营盖好时
## 已经付不出这个兵的钱，结果产能白建、军队反而更少（实测过，别改成 2）。
const MAX_QUEUE_ARMY: int = 1
## 农民允许比军队多几个。超过就先补兵（"先有枪杆子，再贪经济"）。
const VILLAGER_ARMY_GAP: int = 2
## 每座兵营"负责"的军队规模上限：军队目标越大越要多盖兵营才能跟上出兵节奏。
const UNITS_PER_BARRACKS: float = 8.0
## 兵营数量上限（再多也没资源养）
const MAX_BARRACKS: int = 3
## 回防指令重新下达的间隔（秒）
const DEFEND_REISSUE: float = 4.0
## 找空位建造：搜索的环半径范围（米）。
## 起始半径从 8 提到 11：大本营 9.4m 宽（半宽 4.7），8m 的环会让兵营直接贴到它墙根。
const BUILD_SEARCH_MIN: float = 11.0
## 新建筑与已有建筑的**最小水平间隙**（米，外接矩形之间）。
## 3.5m ≈ 一个身位 + 屋檐挑出，既不会插在一起，也不会把基地摊成一片空地。
const BUILD_GAP: float = 3.5
const BUILD_SEARCH_MAX: float = 34.0
const BUILD_SEARCH_STEP: float = 3.0
## 每个环采样多少个方向
const BUILD_SEARCH_ANGLES: int = 14
## 防守感知半径（米）：敌方战斗单位进到这个圈里就算"压家"。
## 取 18 的依据：大本营视野 15m、箭塔 14m，18 让 AI 比玩家早半步反应。
const DEFENSE_RADIUS: float = 18.0
## 残血撤退阈值（血量比例）
const RETREAT_HP: float = 0.32
## 巡逻间隔（秒）
const PATROL_INTERVAL: float = 9.0
## 派兵清野怪的最低兵力（副官会调高：它动的是玩家的兵）
var creep_clear_min_army: int = 4
## 一波里"出击"的比例（其余留守）。副官会覆盖成 0.70（更稳）。
var push_ratio: float = 0.82
## 保留资金：任何一笔开销之后，金币都必须 ≥ 这个值，避免 AI 把家底掏空到"零机动"。
## 以前 AI 有多少花多少（can_afford 一过就掏），玩家一压家它连个农民都补不出来。
## 150 是"够补 1 个农民 + 留点找零"的缓冲，不写死在每处花销点、统一走 _can_spend。
##
## ★ 这两个常量只是**默认值**：真正的数值来自 Cfg.game.ai_reserve_gold / adjutant_*，
##   由 _apply_reserve_from_cfg() 在 _ready 时灌进实例变量。副官（玩家侧 AI）走的是
##   另一套高得多的预算 —— 它花的是玩家的钱，不能把玩家掏空。
const RESERVE_GOLD: int = 150
const RESERVE_WOOD: int = 40
## 实例上的保留额（子类 / 配置可以覆盖）
var reserve_gold: int = RESERVE_GOLD
var reserve_wood: int = RESERVE_WOOD

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
## 上次打印"为什么不出击"的时刻（诊断，25 秒一条）
var _last_block_log: float = -999.0
## 本 tick 的指标 + 姿态（调试与自检读它）
var metrics: Dictionary = {}
var posture: Dictionary = {}

## --- 子系统（_ready 里建，全部是纯逻辑，不认识场景树）---
var _sched = null      # 命令调度
var _director = null   # 战略导演
var _sanity = null     # 反愚蠢审计
var _combat = null     # 战斗数学

# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	_faction = command_faction if command_faction != null else Game.enemy_faction
	if _faction == null:
		# 多队图没有"唯一的敌人"：退到"第一个不是玩家的阵营"
		for f in Game.factions:
			if f != null and not f.is_player:
				_faction = f
				break
	_make_subsystems()
	_apply_reserve_from_cfg()
	if _faction != null:
		_init_wave_clock()


## 从 Cfg 取"保留资金"（敌方 AI 一套 / 副官另一套，见 游戏配置 的注释）
func _apply_reserve_from_cfg() -> void:
	var cfg: GameConfig = Cfg.game if Cfg != null else null
	if cfg == null:
		return
	reserve_gold = maxi(0, cfg.ai_reserve_gold)
	reserve_wood = maxi(0, cfg.ai_reserve_wood)

## 建子系统。分出来一个函数是因为副官/测试可能会在 ready 之外重建。
func _make_subsystems() -> void:
	if _sched == null:
		_sched = load("res://代码/ai/命令调度.gd").new()
	if _combat == null:
		_combat = load("res://代码/ai/战斗模型.gd").new()
	if _director == null:
		_director = load("res://代码/ai/战略导演.gd").new()
		var plans: Array = load("res://代码/配置/战略计划.gd").call("build")
		_director.setup(plans, Game.difficulty_index)
	if _sanity == null:
		_sanity = load("res://代码/ai/反愚蠢.gd").new()

func _init_wave_clock() -> void:
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_next_wave_at = diff.first_wave_delay
	_wave_index = 0

## 性能计时（探针读它）
static var dbg_usec: int = 0

func _process(delta: float) -> void:
	var _t0: int = Time.get_ticks_usec()
	_process_inner(delta)
	SimpleAI.dbg_usec += Time.get_ticks_usec() - _t0


func _process_inner(delta: float) -> void:
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	if _faction == null or not is_instance_valid(_faction):
		_faction = command_faction if command_faction != null else Game.enemy_faction
		if _faction == null:
			for f in Game.factions:
				if f != null and not f.is_player:
					_faction = f
					break
		if _faction == null:
			return
		_init_wave_clock()
	if _sched == null:
		_make_subsystems()

	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_think -= delta
	_defend_cd = maxf(_defend_cd - delta, 0.0)
	_patrol_cd = maxf(_patrol_cd - delta, 0.0)
	if _think > 0.0:
		return
	var interval: float = maxf(diff.think_interval * think_scale, 0.1)
	_think = interval

	if not _announced:
		_announced = true
		_log("接管 %s（节奏 %.2fs）" % [_faction.display_name, interval])

	_think_once(diff)

## 一次完整的思考。抽成函数是为了让自检可以"手动推一帧"。
func _think_once(diff: DifficultyDef) -> void:
	var now: float = Game.elapsed
	_sched.begin(now)

	# --- ① 指标 + 姿态 ---
	var ctx: Dictionary = _build_ctx(diff, now)
	metrics = _director.build_metrics(ctx)
	posture = _director.update(ctx)
	posture["metrics"] = metrics

	# --- ② 卡死退避：先扫一遍，后面所有移动命令都会避开它们 ---
	_sched.refresh_stuck(_combat_units(true))

	# --- ③ 经济 ---
	_manage_peasants(diff)
	_assign_workers(diff)
	_manage_food(diff)

	# --- ④ 生产 / ⑤ 科技 ---
	_manage_army(diff)
	_manage_research(diff)

	# --- ⑥ 军事 ---
	# ★ 2026-11-01 昼夜分流（玩家口径）：
	#   白天 → 出门打敌对玩家 + **清野怪营地**；夜里 → 守家、营火、农民采木。
	#   分流的唯一判据是 `Game.is_night()`（别在这里自己算小时）。
	_manage_retreat()
	_manage_defense(diff)
	if Game.is_night():
		_manage_night(diff)
	else:
		_manage_patrol(diff)
		_manage_creep_clear(diff)
		_manage_waves(diff)
	_manage_upkeep(diff)

	# --- ⑦ 反愚蠢审计（最后跑，救火命令优先）---
	_sanity.update(ctx)

	# --- ⑧ 真正发出去 ---
	_sched.flush()

# ===========================================================================
# 上下文 / 查询
# ===========================================================================

## 每次思考给各子系统的一份"世界快照"。
## 为什么要做成 Dictionary 而不是让每个子系统自己扫场景：
## 一是性能（扫 7 遍全图单位），二是**口径一致** —— 导演判"军队规模"和
## 生产判"该造几个兵"必须数同一批人，否则两边永远对不上。
func _build_ctx(diff: DifficultyDef, now: float) -> Dictionary:
	var army: Array = _army_units()
	var enemy_army: Array = _enemy_army()
	var workers: Array = _workers()
	var idle: Array = []
	for w in workers:
		if w != null and is_instance_valid(w) and bool(w.call("is_idle_like")):
			idle.append(w)
	return {
		"faction": _faction,
		"now": now,
		"dt": maxf(diff.think_interval * think_scale, 0.1),
		"army": army,
		"enemy_army": enemy_army,
		"workers": workers,
		"idle_workers": idle,
		"threat_units": _threat_units(),
		"under_attack": _under_attack(),
		"defend_point": _defend_point(),
		"combat": _combat,
		"sched": _sched,
		"diff": diff,
		"posture": posture,
		"find_builder": Callable(self, "_pick_builder"),
		"build_spot": Callable(self, "_find_build_spot"),
		"build_yaw": Callable(self, "_build_yaw_at"),
		"queue_army": Callable(self, "_sanity_queue"),
		"research": Callable(self, "_sanity_research"),
	}

## 全部农民
func _workers() -> Array:
	var out: Array = []
	if _faction == null:
		return out
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null:
			continue
		if RtsWorld.is_worker_def(u.def):
			out.append(u)
	return out

## 全部战斗单位（不含农民；include_workers=true 时连农民一起给，用于卡死扫描）
func _army_units() -> Array:
	return _combat_units(false)

func _combat_units(include_workers: bool) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null:
			continue
		if u.def.kind != RtsConst.Kind.UNIT:
			continue
		if not include_workers and RtsWorld.is_worker_def(u.def):
			continue
		out.append(u)
	return out

## 对面的战斗单位（"能看见" = 全图，本项目没有战争迷雾）。
##
## ★ 两条口径（2026-11-01 修，之前 AI 整局不出门就是这两条一起造成的）：
##   ① **不含中立野怪**（见 `_war_foes()`）：8 片营地几十只豺狼人算进"敌军"，
##      兵比从 1.09 掉到 0.23，AI 永远觉得打不过；
##   ② **只比"最强的那个对手"**，不是把三家加起来：
##      四队图里每家只占全场 1/4，把其余三家求和，任何一家都不可能超过 1.0，
##      于是三家 AI 谁也不出门。RTS 里"能不能打出去"问的是"我 vs 最能打的那家"。
func _enemy_army() -> Array:
	var out: Array = []
	if _faction == null:
		return out
	for foe in [_strongest_foe()]:
		if foe == null:
			continue
		for u in foe.units:
			if u == null or not is_instance_valid(u):
				continue
			if not u.is_alive() or u.def == null:
				continue
			if u.def.kind != RtsConst.Kind.UNIT:
				continue
			if RtsWorld.is_worker_def(u.def):
				continue
			out.append(u)
	return out

## 压在我方建筑 DEFENSE_RADIUS 内的敌方战斗单位（跨全部敌对阵营）
func _threat_units() -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var foes: Array = Game.enemies_of(_faction)
	if foes.is_empty():
		return out
	var anchors: Array = []
	for b in _faction.buildings:
		if b != null and is_instance_valid(b) and b.is_alive():
			anchors.append(b.global_position)
	if anchors.is_empty():
		return out
	var r2: float = DEFENSE_RADIUS * DEFENSE_RADIUS
	for foe in foes:
		for e in foe.units:
			if e == null or not is_instance_valid(e) or not e.is_alive() or e.def == null:
				continue
			if e.def.kind != RtsConst.Kind.UNIT:
				continue
			var hit: bool = false
			for a in anchors:
				if e.global_position.distance_squared_to(a) <= r2:
					hit = true
					break
			if hit:
				out.append(e)
	return out

## 有没有自己的建筑在掉血
func _under_attack() -> bool:
	if _faction == null:
		return false
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		if b.hp < b.def.max_hp * 0.985:
			return true
	return false

## 回防落点：掉血最多的那座建筑；没有就基地中心
func _defend_point() -> Vector3:
	var best: Node3D = null
	var best_frac: float = 1.0
	if _faction != null:
		for b in _faction.buildings:
			if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
				continue
			var f: float = b.hp / maxf(b.def.max_hp, 1.0)
			if f < best_frac:
				best_frac = f
				best = b
	if best != null:
		return best.global_position
	return RtsWorld.base_center(_faction)

# ===========================================================================
# 经济
# ===========================================================================

## 补农民。目标 = 难度档 + 战略计划的 worker_bonus（经济流派多贪、防守流派少贪）
func _manage_peasants(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	var target: int = diff.target_peasants + int(posture.get("worker_bonus", 0))
	var peasants: int = _faction.count_units(&"peasant")
	if peasants >= target:
		return
	# 先有枪杆子，再贪经济：农民数量超过军队太多时就不再补农，把钱留给兵营。
	# 不加这一闸的话，起始金币会被一口气灌进农民，兵营全程饿着（实测：目标 8/10 时
	# 60 秒只出 2 个兵，比"贪经济"亏得更狠）。
	if peasants >= _army_units().size() + VILLAGER_ARMY_GAP:
		return
	# 同样要过"保留资金"闸：否则农民会把 AI（尤其副官）的钱一点点磨到零
	if not _can_spend(&"peasant"):
		return
	var townhall: RtsBuilding = _first_building(&"townhall")
	if townhall == null:
		return
	if townhall.train_count() >= MAX_QUEUE_PEASANT:
		return
	if townhall.queue_train(&"peasant"):
		_log("排农民（现有 %d / 目标 %d，军队 %d）"
				% [peasants, target, _army_units().size()])

## 给闲着的农民派采集活：按"缺口比例"分金木，别全挤一个矿
func _assign_workers(_diff: DifficultyDef) -> void:
	var workers: Array = _workers()
	if workers.is_empty():
		return
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
	# 木材的"收货点"每 tick 只算一次（伐木场优先，其次大本营）
	var wood_drop: Vector3 = _wood_dropoff()

	for w in idle:
		var kind: int = RtsConst.Harvest.GOLD
		if on_gold >= want_gold and on_wood < total - want_gold:
			kind = RtsConst.Harvest.WOOD
		elif on_gold >= want_gold:
			kind = RtsConst.Harvest.WOOD
		# 夜里：闲着的人一律去砍木头（玩家口径"夜晚……农民采集木头"）。
		# 夜里金矿不是瓶颈，木头才是（塔、营火、修理全吃木）。
		if Game.is_night() and on_wood < total:
			kind = RtsConst.Harvest.WOOD
		var node: Node3D = null
		if kind == RtsConst.Harvest.WOOD:
			node = _nearest_wood(w, wood_drop)
		else:
			node = Game.find_nearest_harvestable(w.global_position, kind, base, radius)
		if node == null and kind == RtsConst.Harvest.WOOD:
			kind = RtsConst.Harvest.GOLD
			node = Game.find_nearest_harvestable(w.global_position, kind, base, radius)
		if node == null:
			continue
		_sched.gather([w], node, "economy")
		if kind == RtsConst.Harvest.GOLD:
			on_gold += 1
		else:
			on_wood += 1


## **砍哪棵树**：优先"离伐木场/基地最近"的，其次才是"离农民最近"的。
##
## 玩家口径（2026-11-01）："要优先采集伐木场最近或基地最近的木头"。
## 判据 = 树到收货点的距离 × 1.0 + 树到农民的距离 × 0.35：
##   · 权重 1.0 —— 每一趟往返都要走的路，是真正的时间成本；
##   · 权重 0.35 —— 农民多走两步过去无所谓，多背 10m 回家才是浪费。
## 这就是"先把家门口的树砍光"的自然行为，而不是随机撒到林子里。
func _nearest_wood(w: RtsUnit, drop: Vector3) -> Node3D:
	if w == null or not is_instance_valid(w):
		return null
	var best: Node3D = null
	var best_s: float = INF
	for h in Game.all_harvestables():
		if h == null or not is_instance_valid(h):
			continue
		if not h.is_alive():
			continue
		var hd: UnitDef = h.def
		if hd == null or hd.harvest_kind != RtsConst.Harvest.WOOD:
			continue
		var s: float = h.global_position.distance_to(drop) \
				+ h.global_position.distance_to(w.global_position) * 0.35
		if s < best_s:
			best_s = s
			best = h
	return best


## 木材的收货点：最近的、收木材的己方交汇点。
## 伐木场是"专收木材"的，给 8m 的等效折扣 —— 否则大本营常常更近，
## 伐木场就白造了（它存在的意义就是把送货路程缩短）。
func _wood_dropoff() -> Vector3:
	var home: Vector3 = RtsWorld.base_center(_faction)
	var best: Vector3 = home
	var best_d: float = INF
	if _faction == null:
		return best
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		var rb := b as RtsBuilding
		if rb != null and not rb.is_constructed:
			continue
		if not b.def.accepts_harvest(RtsConst.Harvest.WOOD):
			continue
		var d: float = b.global_position.distance_to(home)
		if b.def.id == &"lumbercamp":
			d -= 8.0
		if d < best_d:
			best_d = d
			best = b.global_position
	return best

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

## 花钱闸：在 Game.can_afford（有多少花多少）之上加一道"保留资金"门槛。
## 任何一笔开销之后，金币都必须 ≥ RESERVE_GOLD，避免 AI 把家底掏空到"零机动"
## —— 玩家一压家，它连个农民/箭塔都补不出来，只能干挨打。
func _can_spend(id: StringName) -> bool:
	if _faction == null:
		return false
	if not Game.can_afford(_faction, id):
		return false
	var d: UnitDef = Cfg.unit(id)
	if d == null:
		return false
	# 金与木各留一份底：只有金币闸的话，木头会被一口气花光、下一座房子永远差 20 木
	return _faction.gold - d.gold_cost >= reserve_gold 		and _faction.wood - d.wood_cost >= reserve_wood


## 人口不够就补农场
func _manage_food(diff: DifficultyDef) -> void:
	if not _need_farm(diff):
		return
	var farm_def: UnitDef = Cfg.unit(&"farm")
	if farm_def == null:
		return
	# 已经在造农场了就别再造（**但不阻止反愚蠢审计派人去收尾停滞工地**）
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != &"farm":
			continue
		if b is RtsBuilding and not b.is_constructed:
			return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(farm_def.footprint)
	if spot == Vector3.INF:
		return
	if not _can_spend(&"farm"):
		return
	if _sched.build(builder, farm_def, spot, _build_yaw_at(spot), "economy") != null:
		_log("造农场（人口 %d/%d）" % [_faction.food_used(), _faction.food_cap()])

## 人口是否已经不够下一个兵种了（用"最贵的那个兵种"作为判据，别拍常数）
func _need_farm(diff: DifficultyDef) -> bool:
	var max_food: int = 1
	for id in diff.composition.keys():
		var d: UnitDef = Cfg.unit(id)
		if d == null:
			continue
		max_food = maxi(max_food, d.food_cost)
	var peasant: UnitDef = Cfg.unit(&"peasant")
	if peasant != null:
		max_food = maxi(max_food, peasant.food_cost)
	return not _faction.has_food(max_food)

## 找基地附近的合法空位。
## **必须先吸附再判定**：判定用吸附后的点，落地也用这个点（order_build 内部还会再吸一次，
## 幂等），否则会出现"AI 找到空位、工地却被判不能建"的断链。
##
## v2 加了一条"社交距离"：旧版只问"这几格能不能走"，不问"离别的房子多远"，
## 于是兵营/农场会紧贴着大本营盖，屋檐、台阶、地基板互相穿插，
## 远看像一堆盒子挤在一起。现在要求与任何己方建筑的外接矩形至少留 BUILD_GAP 米。
func _find_build_spot(footprint: Vector2i) -> Vector3:
	var center: Vector3 = RtsWorld.base_center(_faction)
	var r: float = BUILD_SEARCH_MIN
	while r <= BUILD_SEARCH_MAX:
		for i in range(BUILD_SEARCH_ANGLES):
			var ang: float = TAU * float(i) / float(BUILD_SEARCH_ANGLES)
			var raw := Vector3(center.x + cos(ang) * r, 0.0, center.z + sin(ang) * r)
			var p: Vector3 = 建筑网格.snap_point(raw, footprint)
			if 建筑网格.can_place(p, footprint) and _has_room(p, footprint):
				return p
		r += BUILD_SEARCH_STEP
	return Vector3.INF


## 这个落点离已有建筑够不够远（外接矩形间隙 >= BUILD_GAP）。
## 用"分离轴上的间隙"而不是圆心距离：房子是方的，圆心距离会把贴着角的判定算错。
func _has_room(spot: Vector3, footprint: Vector2i) -> bool:
	if _faction == null:
		return true
	var a0 := Vector2(spot.x - float(footprint.x) * 0.5, spot.z - float(footprint.y) * 0.5)
	var a1 := Vector2(spot.x + float(footprint.x) * 0.5, spot.z + float(footprint.y) * 0.5)
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		var bf: Vector2i = b.def.footprint
		if bf.x <= 0 or bf.y <= 0:
			continue
		var bp: Vector3 = b.global_position
		var b0 := Vector2(bp.x - float(bf.x) * 0.5, bp.z - float(bf.y) * 0.5)
		var b1 := Vector2(bp.x + float(bf.x) * 0.5, bp.z + float(bf.y) * 0.5)
		var dx: float = maxf(b0.x - a1.x, a0.x - b1.x)
		var dz: float = maxf(b0.y - a1.y, a0.y - b1.y)
		if maxf(dx, dz) < BUILD_GAP:
			return false
	return true

## 建筑朝向：**和开局摆的三座完全一致**（正门朝镜头 / 世界 +Z），再吸到 90 度档。
##
## 旧实现让每座房子"转向基地中心"：副官在基地北侧盖的兵营会整座背对玩家，
## 和开局那三座朝向对不上 —— 一眼就看得出是"两拨人摆的"。
## 而且玩家镜头永远从南往北看，朝内的房子在画面上全是后背。
func _build_yaw_at(_spot: Vector3) -> float:
	return 建筑网格.snap_yaw(建筑网格.default_yaw())

## 挑一个能去盖房子的农民（优先闲着的，其次正在采集的）
func _pick_builder() -> RtsUnit:
	if _faction == null:
		return null
	var best: RtsUnit = null
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null or not RtsWorld.is_worker_def(u.def):
			continue
		if u.order == RtsConst.Order.BUILD:
			return null
		if bool(u.call("is_idle_like")):
			return u
		if best == null:
			best = u
	return best

# ===========================================================================
# 生产 / 科技
# ===========================================================================

func _manage_army(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	var army: int = _army_units().size()
	if army >= diff.max_army:
		return
	# 先保证产能：兵营不够就先盖兵营（单兵营喂不饱 max_army）
	_maybe_build_barracks(diff)
	# 有产能了就要有"家门口的钉子"：每两座兵营配一座箭塔（上限 2）
	_maybe_build_tower()
	# 新建筑：神秘圣地（法师）/ 蒸汽车坊（重步兵）。
	# ★ 哨塔不在这里造 —— 它的"造几座 / 造在哪 / 什么时候升级成箭塔"统一由
	#   `_manage_upkeep()` → `_maybe_build_watchtower()` 管（朝敌方外圈选点、留够视野）。
	#   两处都造会互相打架：这里造一座，upkeep 又按自己的目标数再补一座。
	_maybe_build_one(&"sanctum", 1, "tech")
	_maybe_build_one(&"workshop", 1, "tech")
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if not b.has_method("queue_train"):
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not rb.is_constructed:
			continue
		if rb.train_count() >= MAX_QUEUE_ARMY:
			continue
		if _queue_one(rb, diff) != &"":
			army += 1
			if army >= diff.max_army:
				return

## 让一座建筑排一个兵。返回真的排上的 id（空串 = 排不上）
func _queue_one(b: RtsBuilding, diff: DifficultyDef) -> StringName:
	if b == null or not is_instance_valid(b) or not b.is_constructed:
		return &""
	if b.train_count() >= MAX_QUEUE_ARMY:
		return &""
	var picked: StringName = _pick_army_unit(b, diff)
	if picked == &"":
		return &""
	if b.queue_train(picked):
		return picked
	return &""

## **按"每金战力 × 克制"选兵**（旧版只按 composition 权重随机抽签）。
##
## 为什么必须换成这个：本项目有 4×4 的伤害克制表，旧 AI 完全没读过它。
## 对面全是重甲步兵时，AI 还在按固定比例抽弓箭手（穿刺 × 重甲 = 0.85，打了等于刮痧）。
## 新公式 = 每金战力（含克制、护甲、升级、人口、时间折算） × 设计权重 × 同兵种过载惩罚。
##
## 三层各管一件事：
##   · 每金战力  —— 别造废物（含"钱花了但打不动"这种）；
##   · 设计权重  —— 策划的兵种配比意图（难度档 composition）；
##   · 过载惩罚  —— 同一种兵堆太多会被单一兵种克制，也浪费产能。
func _pick_army_unit(b: RtsBuilding, diff: DifficultyDef) -> StringName:
	var prof: Dictionary = _combat.profile(_enemy_army())
	var atk_mult: float = RtsCombat.attack_mult(_faction)
	var arm_mult: float = RtsCombat.armor_mult(_faction)
	var pool: Array = []
	var weights: Array = []
	for id in diff.composition.keys():
		var w: int = int(diff.composition[id])
		if w <= 0:
			continue
		if not b.can_train(id):
			continue
		if not _can_spend(id):
			continue
		var d: UnitDef = Cfg.unit(id)
		if d == null:
			continue
		var worth: float = _combat.worth_per_cost(d, prof, atk_mult, arm_mult)
		var have: int = _faction.count_units(id)
		var overload: float = 1.0 / (1.0 + 0.55 * float(have))
		pool.append(id)
		weights.append(maxf(worth * float(w) * overload, 0.0001))
	if pool.is_empty():
		return &""
	return pool[_weighted_pick(weights)]

## 按权重随机取一个下标（加权抽签：保证多样性，又不会造出明显更差的兵）
func _weighted_pick(weights: Array) -> int:
	var total: float = 0.0
	for w in weights:
		total += float(w)
	if total <= 0.0:
		return 0
	var r: float = randf() * total
	for i in range(weights.size()):
		r -= float(weights[i])
		if r <= 0.0:
			return i
	return weights.size() - 1

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
	if _faction.gold < bd.gold_cost + reserve + reserve_gold:
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(bd.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, bd, spot, _build_yaw_at(spot), "economy") != null:
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
	if td == null or not _can_spend(&"tower"):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(td.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, td, spot, _build_yaw_at(spot), "economy") != null:
		_log("补箭塔（目标 %d 座）" % want)

## 通用"再盖一座 X"：目标座数 + 正在施工就不重复盖。
## 与 _maybe_build_barracks / _maybe_build_tower 同一套口径（留足出兵的钱、只挑闲置农民）。
func _maybe_build_one(id: StringName, want: int, tag: String) -> void:
	if _faction == null or want <= 0:
		return
	if _faction.count_buildings(id) >= want:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null or b.def.id != id:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and not rb.is_constructed:
			return
	var d: UnitDef = Cfg.unit(id)
	if d == null or not _can_spend(id):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, d, spot, _build_yaw_at(spot), tag) != null:
		_log("扩建%s（目标 %d 座）" % [d.display_name, want])


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

## 科技：铁匠铺升级。
## 旧版 AI **从来不做研究**（全项目只有指令系统里玩家那条路径），
## 于是"金币堆到 1000 花不出去"成了常态。这里按战略计划的 research 开关决定做不做。
func _manage_research(_diff: DifficultyDef) -> void:
	if not bool(posture.get("research", false)):
		return
	_sanity_research()

## 真的去点一项研究。优先补等级低的那一项（攻/防交替，避免极端）。
func _sanity_research() -> bool:
	if _faction == null:
		return false
	var bs: RtsBuilding = _first_building(&"blacksmith")
	if bs == null or bs.is_researching():
		return false
	var best: StringName = &""
	var best_level: int = 99
	for rid in bs.def.researches:
		if RtsCombat.research_maxed(_faction, rid):
			continue
		if String(bs.research_block_reason(rid)) != "":
			continue
		var lv: int = RtsCombat.research_level(_faction, rid)
		if lv < best_level:
			best_level = lv
			best = rid
	if best == &"":
		return false
	if bs.research(best):
		_log("开始研究 %s（等级 %d → %d）" % [String(best), best_level, best_level + 1])
		return true
	return false

## 给反愚蠢审计用的"排一个兵"入口
func _sanity_queue(b) -> StringName:
	var rb := b as RtsBuilding
	if rb == null or not is_instance_valid(rb) or not rb.is_constructed:
		return &""
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	return _queue_one(rb, diff)

# ===========================================================================
# 军事：撤退 / 回防 / 巡逻 / 推进
# ===========================================================================

## 残血撤退：血量低于 RETREAT_HP 的战斗单位先回家，别在前线当经验包。
## 回满血后它会因为"闲着"被巡逻/进攻重新带走，不需要额外状态机。
func _manage_retreat() -> void:
	if _faction == null:
		return
	var home: Vector3 = RtsWorld.base_center(_faction)
	var wounded: Array = []
	for u in _army_units():
		if u == null or not is_instance_valid(u) or u.def == null:
			continue
		if u.def.max_hp <= 0.0:
			continue
		if u.hp > u.def.max_hp * RETREAT_HP:
			continue
		if u.global_position.distance_to(home) < 12.0:
			continue    # 已经在家的圈子里，别再刷命令
		wounded.append(u)
	if wounded.is_empty():
		return
	_sched.move(wounded, home, "retreat")

## 回防：只在"有敌人压到建筑门口"时触发，按 defend_ratio 抽人。
## 标签用 defend —— 调度器对防守命令不做重发节流（节流会直接导致基地被拆）。
func _manage_defense(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	var threats: Array = _threat_units()
	if threats.is_empty():
		return
	if _defend_cd > 0.0:
		return
	_defend_cd = DEFEND_REISSUE
	var army: Array = _army_units()
	if army.is_empty():
		return
	var n: int = clampi(int(ceil(float(army.size()) * clampf(diff.defend_ratio, 0.0, 1.0))),
			1, army.size())
	var point: Vector3 = _defend_point()
	var before: int = int(_sched.stats().get("queued", 0))
	_sched.attack_move(army.slice(0, n), point, "defend")
	# 只在"真的登记了命令"时才打日志：否则每 4 秒一行同样的字，
	# 看起来像在疯狂下令，其实早就在路上了（到达判定已经拦掉了）。
	if int(_sched.stats().get("queued", 0)) > before:
		_log("回防：%d/%d 兵（压家敌人 %d 个）" % [n, army.size(), threats.size()])

## 巡逻：没有战事时让 1~3 个兵绕着基地转，别全挤在基地里发呆。
## 顺手还能"发现自己家门口的敌人"——AI 的反应速度肉眼可见地变快。
func _manage_patrol(_diff: DifficultyDef) -> void:
	if _patrol_cd > 0.0 or _faction == null:
		return
	if not bool(posture.get("allow_patrol", true)):
		return
	var army: Array = _army_units()
	if army.size() < 2:
		return
	_patrol_cd = PATROL_INTERVAL
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
		_sched.attack_move([u], home + Vector3(cos(ang) * r, 0.0, sin(ang) * r), "patrol")
		moved += 1

## 成波推进。
##
## 与旧版的三处不同：
##   1. **出击前先过战略导演的"出击许可"**：兵力不占优、或家里在挨打，就不送；
##   2. 推进目标是"离我最近的敌方建筑"，不是敌方基地中心（旧版会从一堆防守兵中间穿过）；
##   3. 队形不再是一个点：按黄金角螺旋散开（**目标分散到圆盘**），
##      一队人不会挤成一坨互相卡位。
func _manage_waves(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	if Game.elapsed < _next_wave_at:
		return
	if not bool(posture.get("allow_attack", false)):
		# 不是"这一波取消"，而是"10 秒后再评估" —— 兵力一到位就会打出去
		_next_wave_at = Game.elapsed + 10.0
		if Game.elapsed - _last_block_log >= 25.0:
			_last_block_log = Game.elapsed
			_log("暂不出击：%s" % _block_reason())
		return
	var army: Array = _army_units()
	if army.size() < maxi(diff.min_wave_size, 3):
		return
	var aggr: float = float(posture.get("aggression", diff.aggression))
	if randf() > clampf(aggr, 0.0, 1.0):
		return

	var push_n: int = clampi(int(ceil(float(army.size()) * clampf(push_ratio, 0.1, 1.0))), 1, army.size())
	var target: Vector3 = _push_target()
	var targets: Array = _scatter_targets(army.slice(0, push_n), target)
	var home: Vector3 = RtsWorld.base_center(_faction)
	for i in range(army.size()):
		var u: RtsUnit = army[i]
		if u == null or not is_instance_valid(u):
			continue
		if i < push_n:
			_sched.attack_move([u], targets[i], "wave")
		else:
			# 留守的人散在基地外圈，别全站在大本营里堵路
			var ang: float = randf() * TAU
			_sched.move([u], home + Vector3(cos(ang) * 16.0, 0.0, sin(ang) * 16.0), "wave")

	_wave_index += 1
	var interval: float = maxf(
		diff.wave_interval - diff.wave_interval_decay * float(_wave_index),
		diff.wave_interval_min)
	_next_wave_at = Game.elapsed + interval
	_log("第 %d 波：%d 出击 / %d 留守 → %s（下一波 +%.0fs）" % [
		_wave_index, push_n, army.size() - push_n, _foe_name(), interval])

# ===========================================================================
# 昼夜行为（2026-11-01 玩家口径）
#   白天：出门打敌对玩家 + 清野怪营地
#   夜里：守家（不主动出门）、造营火、农民采木
# ===========================================================================

## 夜间收队的间隔（秒）
const NIGHT_RECALL_INTERVAL := 6.0
## 清野怪的间隔（秒）：不要太频繁，否则部队一直在野区转圈
const CREEP_CLEAR_INTERVAL := 40.0
## 派出清野的兵力比例
const CREEP_CLEAR_RATIO := 0.4
## 野怪营地被判定为"值得打"的最大距离（米，从我的基地算）
const CREEP_CLEAR_RANGE := 95.0
## 开局多久之内不去招惹野怪（秒）：刚开局 3 个兵去打 4 只豺狼人 = 送经验
const CREEP_CLEAR_AFTER := 45.0
## 哨塔目标座数：随时间长大（1 → 3），但封顶 3
const WATCHTOWER_MAX := 3
## 箭塔（含升级来的）总上限：给"升级→补哨塔"的循环封顶
const MAX_ARROW_TOWERS := 4
## 每隔多少秒允许再想要一座哨塔
const WATCHTOWER_GROW_SEC := 95.0
## 营火上限定
const CAMPFIRE_MAX := 2

var _night_cd: float = 0.0
var _creep_cd: float = 0.0
var _upgrade_cd: float = 0.0
## 改造脚本（preload 常量，不依赖全局类缓存）
const REFIT := preload("res://代码/系统/建筑改造.gd")


## **夜里**：把散在外面的兵收回基地内圈，蹲在防御圈上等它们撞上来。
##
## 为什么不是"全体 hold"：hold 会把兵钉在原地，敌人绕后打农场它们不动。
## 这里用 `attack_move` 到基地外圈的一个点 —— 路上遇到敌人自动交战，
## 到了之后原地警戒，本质就是"在家门口巡逻"。
func _manage_night(_diff: DifficultyDef) -> void:
	if _faction == null:
		return
	if _night_cd > 0.0:
		_night_cd -= float(_diff.think_interval * think_scale)
		return
	_night_cd = NIGHT_RECALL_INTERVAL
	var home: Vector3 = RtsWorld.base_center(_faction)
	var moved: int = 0
	for u in _army_units():
		if u == null or not is_instance_valid(u):
			continue
		# 已经在家里圈内就别折腾它（不然每 6 秒重下一次命令，兵一直原地踏步）
		if u.global_position.distance_to(home) <= DEFENSE_RADIUS + 6.0:
			continue
		var ang: float = randf() * TAU
		var p: Vector3 = home + Vector3(cos(ang), 0.0, sin(ang)) * (DEFENSE_RADIUS * 0.8)
		_sched.attack_move([u], p, "night")
		moved += 1
	if moved > 0:
		_log("入夜收队：%d 兵回防（基地 %.0fm 圈）" % [moved, DEFENSE_RADIUS])


## **白天清野**：派一支小队去最近的野怪营地练手。
##
## 三条硬条件（缺一条都不派）：
##   ① 家里没被打（base_threat == 0）；
##   ② 兵力 ≥ 3（1~2 个兵去打营地等于送经验）；
##   ③ 营地离基地 ≤ CREEP_CLEAR_RANGE（太远就成了"全军远征"，正面战场就空了）。
func _manage_creep_clear(_diff: DifficultyDef) -> void:
	if _faction == null:
		return
	if _creep_cd > 0.0:
		_creep_cd -= float(_diff.think_interval * think_scale)
		return
	if float(metrics.get("base_threat", 0.0)) > 0.0:
		return
	var camp: Vector3 = _nearest_creep_camp()
	if camp == Vector3.INF:
		return
	if Game.elapsed < CREEP_CLEAR_AFTER:
		return
	var army: Array = _army_units()
	# 兵力门槛：副官会用更高的值（那是玩家的兵，不能拿去白白送死）
	if army.size() < creep_clear_min_army:
		return
	_creep_cd = CREEP_CLEAR_INTERVAL
	var n: int = clampi(int(ceil(float(army.size()) * CREEP_CLEAR_RATIO)), 3, army.size())
	var targets: Array = _scatter_targets(army.slice(0, n), camp)
	for i in range(n):
		_sched.attack_move([army[i]], targets[i], "creep")
	_log("清野：%d 兵 → 营地 (%.0f, %.0f)" % [n, camp.x, camp.z])


## 最近的野怪营地：优先营地里的建筑（如果有），没有就找最近的野怪本身。
## 返回 Vector3.INF = 附近没有值得打的野怪。
func _nearest_creep_camp() -> Vector3:
	var neutral: RtsFaction = Game.neutral_faction
	if neutral == null:
		return Vector3.INF
	var home: Vector3 = RtsWorld.base_center(_faction)
	var best: Vector3 = Vector3.INF
	var best_d: float = CREEP_CLEAR_RANGE
	for b in neutral.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive():
			continue
		var d: float = b.global_position.distance_to(home)
		if d < best_d:
			best_d = d
			best = b.global_position
	if best != Vector3.INF:
		return best
	for u in neutral.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		var d2: float = u.global_position.distance_to(home)
		if d2 < best_d:
			best_d = d2
			best = u.global_position
	return best


## **日常 upkeep**：哨塔（扩视野）→ 多余哨塔升级箭塔 → 营火（夜里照明）。
##
## 顺序是有讲究的：先有哨塔才谈得上"升级多余的那几座"；
## 营火放最后 —— 它是纯功能性的照明，不能跟"能打的塔"抢资源。
func _manage_upkeep(diff: DifficultyDef) -> void:
	_maybe_build_watchtower(diff)
	_maybe_upgrade_tower()
	_maybe_build_campfire()


## 哨塔：**朝敌方方向**推到基地外圈，目的是"提前看见有人来"。
## 目标座数随时间长大（1 → 3），这样前期不浪费钱，后期基地有预警圈。
func _maybe_build_watchtower(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	# 目标**哨塔**数（只数哨塔，不数箭塔）：升级掉一座哨塔之后这里会空出名额，
	# 于是 AI 会再补一座 —— 这正是玩家描述的"造哨塔扩视野、多出来的转成箭塔"。
	var want: int = clampi(1 + int(Game.elapsed / WATCHTOWER_GROW_SEC), 1, WATCHTOWER_MAX)
	var have: int = _faction.count_buildings(&"watchtower")
	# 总防御建筑上限：防止"升级→补哨塔→再升级"无限循环把钱烧光
	if have >= want or _faction.count_buildings(&"tower") >= MAX_ARROW_TOWERS:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != &"watchtower":
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and not rb.is_constructed:
			return
	var d: UnitDef = Cfg.unit(&"watchtower")
	if d == null or not _can_spend(&"watchtower"):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _frontier_spot(d.footprint, 24.0, 34.0)
	if spot == Vector3.INF:
		spot = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, d, spot, _build_yaw_at(spot), "defense") != null:
		_log("造哨塔扩视野（已有 %d / 目标 %d）" % [have, want])


## "朝敌方的外圈"选点：从基地沿"我方→最近敌人"方向走 24~34m，找第一个可建点。
## 找不到就退到通用的 `_find_build_spot`（环形搜索）。
func _frontier_spot(footprint: Vector2i, r_min: float, r_max: float) -> Vector3:
	if _faction == null:
		return Vector3.INF
	var home: Vector3 = RtsWorld.base_center(_faction)
	var dir := Vector3.FORWARD
	var foe: RtsFaction = _foe_faction()
	if foe != null:
		var to: Vector3 = RtsWorld.base_center(foe) - home
		to.y = 0.0
		if to.length() > 1.0:
			dir = to.normalized()
	var r: float = r_min
	while r <= r_max:
		for sgn in [0.0, 0.5, -0.5]:
			var ang: float = atan2(dir.x, dir.z) + float(sgn)
			var raw := Vector3(home.x + sin(ang) * r, 0.0, home.z + cos(ang) * r)
			var p: Vector3 = 建筑网格.snap_point(raw, footprint)
			if 建筑网格.can_place(p, footprint) and _has_room(p, footprint):
				return p
		r += 3.0
	return Vector3.INF


## **多余哨塔 → 箭塔**（玩家口径："多余哨塔升级箭塔加强防御"）。
##
## 判定"多余"：哨塔数 > 当前想要的数量（want 见 _maybe_build_watchtower）。
## 也就是"该有的预警点已经够了，剩下的全转成火力"。
## 夜里更积极：夜幕期守家靠的就是塔。
func _maybe_upgrade_tower() -> void:
	if _faction == null:
		return
	if _upgrade_cd > 0.0:
		_upgrade_cd -= 1.0
		return
	# 要**留几座哨塔**当眼睛：至少 1 座，随时间抬到 2 座。
	# 只有"超过这个数"的哨塔才算多余，才转成箭塔 —— 否则开局唯一那座一升级，
	# 基地就彻底没有 20m 视野了（玩家口径："造哨塔扩大视野"）。
	var prefer: int = clampi(1 + int(Game.elapsed / (WATCHTOWER_GROW_SEC * 2.0)), 1, 2)
	if Game.is_night():
		# 夜里守家靠火力，但仍然至少留 1 座哨塔（预警 26m 是夜里最值钱的东西）
		prefer = maxi(1, prefer - 1)
	var towers: Array = []
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != &"watchtower":
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not rb.is_constructed or not rb.is_alive():
			continue
		towers.append(rb)
	if towers.size() <= prefer:
		return
	if _faction.count_buildings(&"tower") >= MAX_ARROW_TOWERS:
		return
	var old_id: StringName = &"watchtower"
	var new_id: StringName = &"tower"
	if not REFIT.can_pay(_faction, old_id, new_id):
		return
	# 挑"最靠外"的那座升级（越靠前越先挨打，最需要火力）
	var pick: RtsBuilding = towers[0]
	var home: Vector3 = RtsWorld.base_center(_faction)
	for t in towers:
		if t.global_position.distance_to(home) > pick.global_position.distance_to(home):
			pick = t
	if not REFIT.pay(_faction, old_id, new_id):
		return
	var n: Node3D = REFIT.replace(pick, new_id, true)
	_upgrade_cd = 12.0
	if n != null:
		_log("哨塔升级箭塔 @ (%.0f, %.0f)（哨塔 %d 座，目标 %d）" % [
			pick.global_position.x, pick.global_position.z, towers.size(), prefer])


## 营火：**只在夜里考虑**，最多 CAMPFIRE_MAX 座，摆在基地朝敌方的一侧。
## 玩家口径："并会建造营火，在夜晚能看清（让火在晚上能照明）"。
func _maybe_build_campfire() -> void:
	if _faction == null or not Game.is_night():
		return
	if _faction.count_buildings(&"campfire") >= CAMPFIRE_MAX:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id == &"campfire":
			var rb: RtsBuilding = b as RtsBuilding
			if rb != null and not rb.is_constructed:
				return
	var d: UnitDef = Cfg.unit(&"campfire")
	if d == null or not _can_spend(&"campfire"):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _frontier_spot(d.footprint, 10.0, 16.0)
	if spot == Vector3.INF:
		spot = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, d, spot, _build_yaw_at(spot), "night") != null:
		_log("夜里点营火（已有 %d 座）" % _faction.count_buildings(&"campfire"))


## 把一队人散到一个圆盘上（黄金角螺旋，间距约 2m）。
## 为什么用螺旋而不是方阵：方阵要么朝向不对、要么在野外根本放不下；
## 螺旋只依赖"到目标的距离"，任何地形都能落下，而且天然不重叠。
func _scatter_targets(units: Array, center: Vector3) -> Array:
	var out: Array = []
	var pf: GridPathfinder = RtsWorld.pathfinder()
	var n: int = units.size()
	for i in range(n):
		var ang: float = float(i) * 2.39996323
		var r: float = 0.8 + 1.9 * sqrt(float(i))
		var q := Vector3(center.x + cos(ang) * r, 0.0, center.z + sin(ang) * r)
		if pf != null:
			q = pf.standable_point(q, 0.5, 0.15)
		out.append(RtsWorld.snap_y(q))
	return out

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
# 查询辅助
# ===========================================================================

## 我打的那一家：**最近的、还有大本营的敌对阵营**（同样不含野怪）。
## （多队图里"敌人"可能有 2~3 个；全量目标选择见 _all_foes()。）
func _foe_faction() -> RtsFaction:
	if _faction == null:
		return null
	var pool: Array = _war_foes()
	if pool.is_empty():
		return null
	var mine: Vector3 = RtsWorld.base_center(_faction)
	var best: RtsFaction = pool[0]
	var best_d: float = INF
	for f in pool:
		var d: float = mine.distance_squared_to(RtsWorld.base_center(f))
		if d < best_d:
			best_d = d
			best = f
	return best


## 最能打的那个敌对阵营（按"活着的战斗单位数"排）。
## 战略层的对手口径：不打野怪、也不把三家求和（理由见 `_enemy_army()`）。
func _strongest_foe() -> RtsFaction:
	var best: RtsFaction = null
	var best_n: int = -1
	for f in _war_foes():
		if f == null:
			continue
		var n: int = 0
		for u in f.units:
			if u == null or not is_instance_valid(u):
				continue
			if not u.is_alive() or u.def == null:
				continue
			if u.def.kind != RtsConst.Kind.UNIT or RtsWorld.is_worker_def(u.def):
				continue
			n += 1
		if n > best_n:
			best_n = n
			best = f
	return best


## **会"打过来"的敌对阵营** —— 战略层口径，**剔除中立野怪**。
##
## 为什么必须分开：野怪有 8 片营地、每片 5 只，数量上远超任何一家玩家。
## 把它们算进"敌方军力/最想打的那一家"，AI 就会：
##   ① 永远觉得兵力不占优（`allow_attack` 永远 false）→ 整局不出门；
##   ② 把推进目标定成最近的野怪（`_push_target` 找"敌方建筑"）→ 全军去打野。
## 但**战术层**（索敌 `_acquire`、回防 `_threat_units`）仍然把野怪当敌人 ——
## 夜里它们真的会来拆家，那时候必须开枪。
func _war_foes() -> Array:
	var out: Array = []
	for f in _all_foes():
		if f == null:
			continue
		# team 0 = 中立敌对（野怪）。1 队是盟友，压根不在 enemies_of 里。
		if int(f.team) == 0:
			continue
		out.append(f)
	return out


## 全部敌对阵营（含中立野怪；一波兵打过去时要挑目标用）
func _all_foes() -> Array:
	if _faction == null:
		return []
	var pool: Array = Game.living_enemies_of(_faction)
	if pool.is_empty():
		pool = Game.enemies_of(_faction)
	return pool

func _foe_name() -> String:
	var f: RtsFaction = _foe_faction()
	return f.display_name if f != null else "敌方"

## 按 id 找第一座活着的**已完工**建筑
func _first_building(id: StringName) -> RtsBuilding:
	if _faction == null:
		return null
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

## "为什么不出击"的短诊断（日志用）。
func _block_reason() -> String:
	var m: Dictionary = posture.get("metrics", metrics)
	return "兵比=%.2f(需%.2f) 军值=%.0f 兵口=%.0f 敌静态=%.0f 威胁=%.0f" % [
		float(m.get("army_ratio", 0.0)), float(posture.get("attack_ratio_needed", 0.0)),
		float(m.get("my_army_value", 0.0)), float(m.get("army_food", 0.0)),
		float(m.get("enemy_static_defense", 0.0)), float(m.get("base_threat", 0.0))]


## 调试/自检：一句话说清 AI 现在在想什么
func debug_string() -> String:
	var plan: String = String(posture.get("plan_id", "-"))
	var ratio: float = float(metrics.get("army_ratio", 0.0))
	var sent: int = 0
	var skipped: int = 0
	if _sched != null:
		var st: Dictionary = _sched.stats()
		sent = int(st.get("sent", 0))
		skipped = int(st.get("skipped", 0))
	var who: String = _faction.display_name if _faction != null else "?"
	return "%s 计划=%s 兵比=%.2f 军=%d 农=%d 令=%d 略=%d" % [
		who, plan, ratio,
		int(metrics.get("army_count", 0)), int(metrics.get("workers", 0)), sent, skipped]
