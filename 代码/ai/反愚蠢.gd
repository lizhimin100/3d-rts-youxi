extends RefCounted
## **反愚蠢审计**：把"新手 AI 常犯的错"定义成**可检测的状态**，发现就当场修。
##
## 2C-3：建筑 id 一律走 战斗模型 的"按能力找 id"，不在这里写 farm。
const MODEL := preload("res://代码/ai/战斗模型.gd")
## 为什么需要它：经济和军事模块都是"按目标推进"的正面逻辑，它们只会在
## "该做什么"上出错，却不会发现"我明明有钱有兵营，却有 90 秒没出一个兵"。
## 这类**停滞**不会有任何报错，只会让 AI 看起来突然变傻。
## 审计做的是反面检查：不问你该做什么，只问"有没有明显不该发生的事正在发生"。
##
## 八项检查（每一项都对应一个真实会发生的死法）：
##   1. idle_workers        有闲农民、矿还没枯 → 一定是派活断了
##   2. supply_block        人口差 1 且没在建农场 → 后面所有生产都会卡死
##   3. production_idle     有钱、有兵营、有闲人口，队列却是空的
##   4. gold_float          金币堆到 900 还没花出去（产能/研究都满了才会这样）
##   5. idle_army_under_attack  家被拆，军队却在发呆（这是最丢人的一种）
##   6. stuck_units         被判定卡死的单位（卡住的人会一直白吃人口的）
##   7. construction_stalled  **工地停在 10% 再也不动**
##   8. trickle             1~2 个兵单独跑到敌人面前送（添油战术）
##
## 第 7 条是这一版重点：本项目的建造进度只在**农民站在旁边**时才推进
## （RtsBuilding.advance_construction 由农民调用），而旧 AI 的判断是
## "只要有一座农场没完工就直接 return"。于是农民一死、工地永久停在 10%，
## AI 既不再建新农场、也从不派人回来收尾 —— 人口上限永久卡死，
## 后面所有生产全部饿死。这是"AI 打着打着就不出兵了"最可能的根因。

## 每一项修复的最小间隔（秒），防止救火本身变成命令风暴
const FIX_COOLDOWN: float = 6.0
## 工地"多久没进展"算停滞（秒）
const STALL_SECONDS: float = 8.0
## 囤金判据（超过这个数还没花出去）
const GOLD_FLOAT_LIMIT: float = 900.0
## 添油判据：前出这么多米、身边同伴不超过这么多个，就算添油
const TRICKLE_FAR: float = 26.0
const TRICKLE_MIN_GROUP: int = 2

## 各项当前是否"正在发生"（诊断）
var active: Dictionary = {}
## 累计触发次数（每项每次"从无到有"记一次）
var counts: Dictionary = {}
## 累计修复次数
var fixes: Dictionary = {}
var _last_fix: Dictionary = {}
var _seen_progress: Dictionary = {}
var _last_check: float = -999.0
## "连续几次思考都没响应"这类计数（回防反应延迟用）
var _strikes: Dictionary = {}


## 每次思考调用一次。ctx：
##   faction / now / army / workers / enemy_army / threat_units / buildings
##   sched        —— 命令调度器（修复动作走它，自动受控制权过滤）
##   find_builder —— Callable() -> RtsUnit  找一个能去的农民
##   build_spot   —— Callable(footprint: Vector2i) -> Vector3（INF = 没地方）
##   queue_army   —— Callable(building) -> StringName  排一个兵
##   research     —— Callable() -> bool  开始一项铁匠铺研究
##   diff         —— DifficultyDef
func update(ctx: Dictionary) -> void:
	var now: float = float(ctx.get("now", 0.0))
	if now - _last_check < 0.5:
		return
	_last_check = now
	_check_idle_workers(ctx)
	# 空过期间**不许花钱**（2026-11-07 玩家口径）：
	# 这三项会开新工地 / 训练 / 研究，属于"新开销"。空过时整块跳过，
	# 但派工/接续/救火这些不花钱的仍然照跑。
	if not bool(ctx.get("goal_noop", false)):
		_check_supply(ctx)
		_check_production(ctx)
		_check_gold_float(ctx)
	_check_army_response(ctx)
	_check_stuck(ctx)
	_check_construction(ctx)
	_check_trickle(ctx)


# ===========================================================================
# 八项检查
# ===========================================================================

func _check_idle_workers(ctx: Dictionary) -> void:
	var workers: Array = ctx.get("workers", [])
	var idle: Array = []
	for w in workers:
		if w != null and is_instance_valid(w) and bool(w.call("is_idle_like")):
			idle.append(w)
	var on = idle.size() >= 2
	_episode("idle_workers", on, ctx)
	# 派活是 _assign_workers 的活；这里只立案，不重复下令（重复下令会互相抢人）


func _check_supply(ctx: Dictionary) -> void:
	var faction: RtsFaction = ctx.get("faction")
	if faction == null:
		return
	var headroom: int = faction.food_cap() - faction.food_used() - faction.food_reserved()
	var building: bool = false
	for b in faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.food_provided > 0 and not bool(b.get("is_constructed")):
			building = true
			break
	var on: bool = headroom <= 1 and not building
	_episode("supply_block", on, ctx)
	if not on:
		return
	if not _can_fix("supply_block", ctx):
		return
	var fid: StringName = MODEL.food_building_id()
	if fid == &"":
		return
	var farm: UnitDef = Cfg.unit(fid)
	var spot: Vector3 = _call_spot(ctx, farm)
	if farm == null or spot == Vector3.INF:
		return
	var builder = _call_builder(ctx)
	if builder == null:
		return
	var sched = ctx.get("sched")
	if sched != null:
		sched.build(builder, farm, spot, _yaw_at(ctx, spot))
		_fix("supply_block", ctx)


func _check_production(ctx: Dictionary) -> void:
	var faction: RtsFaction = ctx.get("faction")
	if faction == null:
		return
	var prod: Array = []
	var idle: bool = true
	for b in faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if not b.has_method("queue_train"):
			continue
		if not bool(b.get("is_constructed")) or not b.is_alive():
			continue
		prod.append(b)
		if int(b.call("train_count")) > 0:
			idle = false
	if prod.is_empty():
		_episode("production_idle", false, ctx)
		return
	var headroom: int = faction.food_cap() - faction.food_used() - faction.food_reserved()
	var on: bool = idle and faction.gold > 260 and headroom >= 2
	_episode("production_idle", on, ctx)
	if not on or not _can_fix("production_idle", ctx):
		return
	var queue := Callable()
	if ctx.has("queue_army"):
		queue = ctx["queue_army"]
	if not queue.is_valid():
		return
	for b in prod:
		var id: StringName = queue.call(b)
		if id != &"":
			_fix("production_idle", ctx)
			return


func _check_gold_float(ctx: Dictionary) -> void:
	var faction: RtsFaction = ctx.get("faction")
	if faction == null:
		return
	var headroom: int = faction.food_cap() - faction.food_used() - faction.food_reserved()
	var on: bool = faction.gold > GOLD_FLOAT_LIMIT and headroom >= 2
	_episode("gold_float", on, ctx)
	if not on or not _can_fix("gold_float", ctx):
		return
	# 钱的出路按"长期收益"排：先研究（永久加成），再补产能建筑，最后才出兵
	var res := Callable()
	if ctx.has("research"):
		res = ctx["research"]
	if res.is_valid() and bool(res.call()):
		_fix("gold_float", ctx)
		return
	var queue := Callable()
	if ctx.has("queue_army"):
		queue = ctx["queue_army"]
	if queue.is_valid():
		for b in faction.buildings:
			if b == null or not is_instance_valid(b):
				continue
			if not b.has_method("queue_train") or not bool(b.get("is_constructed")):
				continue
			if queue.call(b) != &"":
				_fix("gold_float", ctx)
				return


func _check_army_response(ctx: Dictionary) -> void:
	var threat: Array = ctx.get("threat_units", [])
	var army: Array = ctx.get("army", [])
	if threat.is_empty() or army.size() < 2:
		_episode("idle_army_under_attack", false, ctx)
		_strikes.erase("army_response")
		return
	var responding: bool = false
	for u in army:
		if u == null or not is_instance_valid(u):
			continue
		var o: int = int(u.order)
		if o == RtsConst.Order.ATTACK or o == RtsConst.Order.ATTACK_MOVE:
			responding = true
			break
	# 给 1 秒反应时间（思考周期 1~1.4 秒），不把"刚发生"算成发呆
	var n: int = int(_strikes.get("army_response", 0))
	if responding:
		n = 0
	else:
		n += 1
	_strikes["army_response"] = n
	var on: bool = n >= 2
	_episode("idle_army_under_attack", on, ctx)
	if not on or not _can_fix("army_response", ctx):
		return
	var sched = ctx.get("sched")
	var base: Vector3 = RtsWorld.base_center(ctx.get("faction"))
	if sched != null:
		sched.attack_move(army, base, "sanity:recall")
		_fix("army_response", ctx)


func _check_stuck(ctx: Dictionary) -> void:
	var stuck: Array = []
	for u in ctx.get("army", []):
		if u != null and is_instance_valid(u) and int(u.get("_stuck_count")) >= 2:
			stuck.append(u)
	var on = stuck.size() > 0
	_episode("stuck_units", on, ctx)
	if not on or not _can_fix("stuck_units", ctx):
		return
	var sched = ctx.get("sched")
	if sched != null:
		sched.stop(stuck, "sanity:unstuck")
		_fix("stuck_units", ctx)


## 工地停滞：进度在 STALL_SECONDS 内没变过、且附近没有农民在盖 → 派人去收尾
func _check_construction(ctx: Dictionary) -> void:
	var faction: RtsFaction = ctx.get("faction")
	if faction == null:
		return
	var now: float = float(ctx.get("now", 0.0))
	var stalled: Array = []
	var alive: Dictionary = {}
	for b in faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if bool(b.get("is_constructed")) or not b.is_alive():
			continue
		var bid: int = b.get_instance_id()
		alive[bid] = true
		var prog: float = float(b.get("progress"))
		var rec: Array = _seen_progress.get(bid, [prog, now])
		if prog > float(rec[0]) + 0.0005:
			_seen_progress[bid] = [prog, now]
			continue
		if now - float(rec[1]) >= STALL_SECONDS:
			stalled.append(b)
	# 清掉已完工 / 已拆掉的记录，避免字典无限长
	for k in _seen_progress.keys():
		if not alive.has(k):
			_seen_progress.erase(k)
	var on = stalled.size() > 0
	_episode("construction_stalled", on, ctx)
	if not on or not _can_fix("construction_stalled", ctx):
		return
	var sched = ctx.get("sched")
	if sched == null:
		return
	var builder = _call_builder(ctx)
	if builder == null:
		return
	var site: Node3D = stalled[0]
	if builder.has_method("order_build_site"):
		# 只接活、不扣钱、也不新建 —— 这正是"收尾"该做的事
		if bool(builder.call("order_build_site", site)):
			_fix("construction_stalled", ctx)
			_seen_progress.erase(site.get_instance_id())


func _check_trickle(ctx: Dictionary) -> void:
	var army: Array = ctx.get("army", [])
	var enemy: Array = ctx.get("enemy_army", [])
	if army.size() < 4 or enemy.is_empty():
		_episode("trickle", false, ctx)
		return
	var home: Vector3 = RtsWorld.base_center(ctx.get("faction"))
	var forward: Array = []
	for u in army:
		if u == null or not is_instance_valid(u):
			continue
		if u.global_position.distance_to(home) <= TRICKLE_FAR:
			continue
		var near_enemy: bool = false
		for e in enemy:
			if e == null or not is_instance_valid(e):
				continue
			if u.global_position.distance_to(e.global_position) <= 20.0:
				near_enemy = true
				break
		if not near_enemy:
			continue
		# ★ 2026-11-07 玩家口径「既然在战斗中，那就应该一直战斗」：
		#   正在贴脸交战的单位不许被「收拢」命令拽回家。老实现在这里无条件 append，
		#   小股部队每次接敌都会被 regroup 拉走 → 撤一半又冲回来 → 反复拉锯。
		#   判据沿用 简单AI._engaged_in_combat 的口径（有活目标 + 在 1.6 倍射程内）。
		if _is_fighting(u):
			continue
		forward.append(u)
	var on: bool = forward.size() > 0 and forward.size() <= TRICKLE_MIN_GROUP
	_episode("trickle", on, ctx)
	if not on or not _can_fix("trickle", ctx):
		return
	var sched = ctx.get("sched")
	if sched != null:
		sched.attack_move(forward, home, "sanity:regroup")
		_fix("trickle", ctx)


## 这个单位是不是正在贴脸交战（有活目标 + 在 1.6 倍射程内）。
## 用于豁免「收拢 / 别送」类命令：正在打的兵拉走只会来回拉锯。
func _is_fighting(u) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	var t = u.get("target")
	if t == null or not is_instance_valid(t):
		return false
	if t.has_method("is_alive") and not bool(t.call("is_alive")):
		return false
	var reach: float = 8.0
	if u.has_method("_attack_reach"):
		reach = float(u.call("_attack_reach", t))
	return (u as Node3D).global_position.distance_to((t as Node3D).global_position) <= reach * 1.6 + 1.0


# ===========================================================================
# 记账 / 工具
# ===========================================================================

func _episode(name: String, on: bool, _ctx: Dictionary) -> void:
	if on:
		if not active.has(name):
			active[name] = true
			counts[name] = int(counts.get(name, 0)) + 1
	else:
		active.erase(name)


func _can_fix(name: String, ctx: Dictionary) -> bool:
	var now: float = float(ctx.get("now", 0.0))
	var last: float = float(_last_fix.get(name, -999.0))
	return now - last >= FIX_COOLDOWN


func _fix(name: String, ctx: Dictionary) -> void:
	_last_fix[name] = float(ctx.get("now", 0.0))
	fixes[name] = int(fixes.get(name, 0)) + 1


func _call_builder(ctx: Dictionary):
	if not ctx.has("find_builder"):
		return null
	var c = ctx["find_builder"]
	if not (c is Callable) or not c.is_valid():
		return null
	return c.call()


func _call_spot(ctx: Dictionary, def: UnitDef) -> Vector3:
	if def == null or not ctx.has("build_spot"):
		return Vector3.INF
	var c = ctx["build_spot"]
	if not (c is Callable) or not c.is_valid():
		return Vector3.INF
	var out = c.call(def.footprint)
	return out if out is Vector3 else Vector3.INF


func _yaw_at(ctx: Dictionary, spot: Vector3) -> float:
	if not ctx.has("build_yaw"):
		return 0.0
	var c = ctx["build_yaw"]
	if not (c is Callable) or not c.is_valid():
		return 0.0
	return float(c.call(spot))


func stats() -> Dictionary:
	var issues: Dictionary = {}
	for k in counts.keys():
		if int(counts[k]) > 0:
			issues[k] = int(counts[k])
	return {"issues": issues, "fixes": fixes, "active": active.keys()}

