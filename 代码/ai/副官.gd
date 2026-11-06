class_name Adjutant
extends SimpleAI
## **副官（玩家侧指挥官）** —— 只在游戏里跑，**不进地图编辑器**。
##
## 和敌方 SimpleAI **是同一套大脑**（同一个脚本继承下来的），所以不会出现
## "人机会配合、副官只会挖矿"这种两套逻辑打架的情况。副官只覆盖三件事：
##   1. 指挥**玩家**阵营（command_faction = Game.player_faction）；
##   2. 反应比一般中等 AI 更快（think_scale = 0.8）、农民上限更高（18）；
##   3. 只从**闲着的**农民里抽人盖房 —— 玩家正在指挥的农民一个都不动。
##
## 因此副官也会做：补农 / 采金伐木 / 造农场·兵营·铁匠铺·箭塔 /
## 按波次出兵 / 分兵出击 / 残血撤退 / 家门口巡逻 / 建筑被打回防。
##
## ★ **玩家意图归属**（这一版的核心）
##
## 旧版这里写的是"副官看到 order != NONE 就不会再碰它"，但那句话只在
## `_pick_builder` 里成立：`_manage_waves` / `_manage_defense` / `_manage_retreat`
## 都是对着 `_army_units()` 全员下令的，玩家正在微操的部队会被整队抓走。
## 现在所有命令都走 CommandScheduler → Game.control，玩家管着的单位在
## "命令组生命周期 + 5 秒宽限"内一律剔除（见 代码/ai/控制权.gd）。
##
## ★ **只建议，不越权**
##
## 副官会把玩家的指令**读成意图**（`_on_player_order`）：
##   · 玩家对一支军队下了攻击 / 攻击移动 → 记一条"进攻指令"（30 秒有效），
##     副官把**没被玩家点名的**部队协同调过去（不是抢，是增援）；
##   · 玩家把一支军队拉到某处 → 记一条"驻守点"（30 秒有效），
##     期间副官不主动推进，把闲兵往那个点收；
##   · 玩家按停止 → 指令立刻清空。
## 冲突时只发"建议"（Game.suggest → 顶部提示），绝不擅自夺权。

## 副官的反应倍率（比一般中等 AI 快 20%）
const ADJ_THINK_SCALE: float = 0.8
## 农民上限：比敌方 AI 高（农民不占人口，多造不吃亏）
const PEASANT_MAX: int = 18
## 玩家意图的有效期（秒）：过期就退回"副官自己判断"
const DIRECTIVE_TTL: float = 30.0
## 副官带队的出击比例（比人机保守：留 30% 守家）
const ADJ_PUSH_RATIO: float = 0.70
## 建议的最小间隔（秒）—— 副官不能变成骚扰机
const HINT_COOLDOWN: float = 30.0
## 进攻指令生效后，隔多久补一次增援命令（秒）
const DIRECTIVE_REISSUE: float = 8.0
## 空闲单位派活的间隔（秒）
const IDLE_DISPATCH_GAP: float = 4.0
## 部队集合点离基地多少米
const ASSEMBLY_RADIUS: float = 12.0

## 是否启用（HUD 小地图下方的「副官 · 开/关」按钮控制；--no-adjutant 启动即关）
var enabled: bool = true

## 玩家进攻指令：[目标点, 到期时刻]；null = 没有
var _attack_point: Vector3 = Vector3.INF
var _attack_until: float = -1.0
## 玩家驻守点（"把这队人拉到这里"）：副官不再主动推进
var _hold_point: Vector3 = Vector3.INF
var _hold_until: float = -1.0
var _last_hint: float = -999.0
var _directive_issued_at: float = -999.0
## 指令解析统计（自检断言用）
var intake_stats: Dictionary = {"attack": 0, "hold": 0, "stop": 0, "ignored": 0}


func _ready() -> void:
	log_prefix = "[副官]"
	think_scale = ADJ_THINK_SCALE
	push_ratio = ADJ_PUSH_RATIO
	command_faction = Game.player_faction
	# 注册进组：HUD 靠组名找人，不依赖"HUD 是不是主场景的直接子节点"
	add_to_group("adjutant")
	super._ready()
	# ★ 副官花的是**玩家的金币**：保留额必须比敌方 AI 高得多，
	#   否则开局几秒钟副官就把 620 花到 150 上下，玩家连兵营都点不出来。
	_apply_adjutant_reserve()
	# 清野怪的门槛比人机更高：它动的是**玩家的兵**，4 个兵去打营地会打空家底。
	# （父类默认 4；副官要 5，且调度器还会剔除玩家正在微操的那批，见 控制权.gd）
	creep_clear_min_army = 5
	if Game.order_issued.is_connected(_on_player_order) == false:
		Game.order_issued.connect(_on_player_order)
	if "--no-adjutant" in OS.get_cmdline_user_args():
		enabled = false
		set_process(false)
		print("%s 已关闭（--no-adjutant）" % log_prefix)


## 副官的保留资金：从 Cfg.game.adjutant_reserve_gold / _wood 取。
## 480 金 / 140 木 = 玩家随时能自己起"兵营 180+60 + 农场 80+20"。
func _apply_adjutant_reserve() -> void:
	var cfg: GameConfig = Cfg.game if Cfg != null else null
	if cfg == null:
		return
	reserve_gold = maxi(reserve_gold, cfg.adjutant_reserve_gold)
	reserve_wood = maxi(reserve_wood, cfg.adjutant_reserve_wood)
	_log("保留资金 %d 金 / %d 木（玩家随时能自己造一座兵营 + 农场）"
		% [reserve_gold, reserve_wood])


## 开关（HUD 按钮调用）：关掉就彻底不动手，玩家的每个单位都归自己
func set_enabled(on: bool) -> void:
	enabled = on
	set_process(on)
	if not on:
		_clear_directives()
	_log("已开启" if on else "已关闭")


# ===========================================================================
# 玩家意图解析
# ===========================================================================

## 把玩家的一条指令读成"意图"。**只读不抢**：这里不碰任何单位，
## 只更新副官自己的"进攻点 / 驻守点"，具体下令仍走控制权过滤后的调度器。
func _on_player_order(units: Array, order: int, target_pos: Vector3, _target: Node3D) -> void:
	if not enabled:
		return
	var now: float = Game.elapsed
	match order:
		RtsConst.Order.ATTACK, RtsConst.Order.ATTACK_MOVE:
			if not _is_army_scale(units):
				intake_stats["ignored"] = int(intake_stats["ignored"]) + 1
				return
			_attack_point = Vector3(target_pos.x, 0.0, target_pos.z)
			_attack_until = now + DIRECTIVE_TTL
			_hold_point = Vector3.INF
			intake_stats["attack"] = int(intake_stats["attack"]) + 1
			_log("收到进攻指令 → (%.0f, %.0f)，%.0fs 内协同推进"
				% [_attack_point.x, _attack_point.z, DIRECTIVE_TTL])
		RtsConst.Order.MOVE:
			if not _is_army_scale(units):
				intake_stats["ignored"] = int(intake_stats["ignored"]) + 1
				return
			_hold_point = Vector3(target_pos.x, 0.0, target_pos.z)
			_hold_until = now + DIRECTIVE_TTL
			_attack_point = Vector3.INF
			intake_stats["hold"] = int(intake_stats["hold"]) + 1
		RtsConst.Order.STOP, RtsConst.Order.HOLD:
			_clear_directives()
			intake_stats["stop"] = int(intake_stats["stop"]) + 1
		_:
			pass
	# 玩家要打之前，先提醒一句"打得过吗"
	if order == RtsConst.Order.ATTACK or order == RtsConst.Order.ATTACK_MOVE:
		_maybe_hint_low_odds(now)


## 玩家动的这一批人算不算"一支军队"（不是单个农民/侦察兵）
func _is_army_scale(units: Array) -> bool:
	if units.is_empty():
		return false
	var combat: int = 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		var d: UnitDef = u.get("def")
		if d == null or RtsWorld.is_worker_def(d):
			continue
		combat += 1
	if combat == 0:
		return false
	var total: int = maxi(_army_units().size(), 1)
	return combat >= maxi(2, int(0.4 * float(total)))


## 当前有效的进攻点（过期返回 INF）
func attack_point() -> Vector3:
	if _attack_point == Vector3.INF:
		return Vector3.INF
	if Game.elapsed > _attack_until:
		_attack_point = Vector3.INF
		return Vector3.INF
	return _attack_point


## 当前有效的驻守点（过期返回 INF）
func hold_point() -> Vector3:
	if _hold_point == Vector3.INF:
		return Vector3.INF
	if Game.elapsed > _hold_until:
		_hold_point = Vector3.INF
		return Vector3.INF
	return _hold_point


func _clear_directives() -> void:
	_attack_point = Vector3.INF
	_attack_until = -1.0
	_hold_point = Vector3.INF
	_hold_until = -1.0


# ===========================================================================
# 建议（只投递，不产生游戏行为）
# ===========================================================================

func _maybe_hint_low_odds(now: float) -> void:
	if now - _last_hint < HINT_COOLDOWN:
		return
	var ratio: float = float(metrics.get("army_ratio", 1.0))
	if ratio >= 0.9:
		return
	_last_hint = now
	Game.suggest({
		"code": "low_odds",
		"severity": "warn",
		"message": "兵力对比 %.2f，建议先补充再推进" % ratio,
		"army_ratio": ratio,
	})
	Game.toast("副官：兵力对比 %.2f，建议先补充再推进" % ratio, Cfg.game.hud_accent)


## 基地遇袭但玩家把兵锁在旁边不动 → 只建议，不抢
func _maybe_hint_request_control() -> void:
	var now: float = Game.elapsed
	if now - _last_hint < HINT_COOLDOWN:
		return
	if float(metrics.get("base_threat", 0.0)) <= 0.0:
		return
	var idle: Array = []
	for u in _army_units():
		if u == null or not is_instance_valid(u) or not u.is_idle_like():
			continue
		if Game.control != null and Game.control.is_protected(u):
			idle.append(u)
	if idle.is_empty():
		return
	_last_hint = now
	Game.suggest({
		"code": "request_control",
		"severity": "info",
		"message": "基地遇袭，%d 个单位待命" % idle.size(),
		"units": idle.slice(0, 8),
	})


# ===========================================================================
# 覆盖：经济口径
# ===========================================================================

## 覆盖：农民上限按副官口径，而且钱少时只保底到 8 个（其余留给军队）
func _manage_peasants(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	var wid: StringName = _worker_id()
	if wid == &"":
		return
	var peasants: int = _faction.count_units(wid)
	if peasants >= PEASANT_MAX:
		return
	var townhall: RtsBuilding = _first_building(_main_base_id())
	if townhall == null:
		return
	if townhall.train_count() >= MAX_QUEUE_PEASANT:
		return
	# 农民不占人口，但**占金币**：军队快凑齐时先别把最后一点钱砸进农民。
	# 保留额走 reserve_gold（副官口径 480）—— 钱少于它就先保玩家的建造预算。
	var army: int = _army_units().size()
	if peasants >= 8 and _faction.gold < reserve_gold and army < diff.max_army:
		return
	# 副官自己的补农也要过同一道闸，否则它会把"留给玩家的钱"一点点磨掉
	if not _can_spend(wid):
		return
	if townhall.queue_train(wid):
		_log("补农民（现有 %d / 上限 %d）" % [peasants, PEASANT_MAX])


## 覆盖：**只挑闲着的农民**盖房。父类会从采集队里抽人，
## 那在"玩家自己管经济"的场景下就是抢人，必须改。
func _pick_builder() -> RtsUnit:
	if _faction == null:
		return null
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null or not RtsWorld.is_worker_def(u.def):
			continue
		if u.order == RtsConst.Order.BUILD:
			return null    # 已经在盖了
		if bool(u.call("is_idle_like")):
			return u
	return null


# ===========================================================================
# 覆盖：出兵的"意图协同"
# ===========================================================================

## 玩家指了进攻点 → 副官把"没被点名的"部队协同调过去。
## 注意这不是抢控制权：玩家点名的那批在控制权登记表里是受保护的，
## 调度器会直接剔除；副官只是把**其他人**也叫过来，凑成一次像样的推进。
func _manage_waves(diff: DifficultyDef) -> void:
	var point: Vector3 = attack_point()
	if point != Vector3.INF:
		# 家里在挨打就先回防 —— 玩家指了目标也不代表可以不管家
		if float(metrics.get("base_threat", 0.0)) > 0.0:
			super._manage_waves(diff)
			return
		if Game.elapsed - _directive_issued_at >= DIRECTIVE_REISSUE:
			_directive_issued_at = Game.elapsed
			var army: Array = _army_units()
			if army.size() >= 2:
				var move_n: int = clampi(int(ceil(float(army.size()) * 0.7)), 1, army.size())
				var targets: Array = _scatter_targets(army.slice(0, move_n), point)
				for i in range(move_n):
					_sched.attack_move([army[i]], targets[i], "wave")
				_log("协同推进：%d 兵 → 玩家指定的 (%.0f, %.0f)"
					% [move_n, point.x, point.z])
		return
	# 玩家在"驻军"：不主动推，把闲兵往那个点收（这是听从，不是抢）
	var hold: Vector3 = hold_point()
	if hold != Vector3.INF:
		var idle: Array = []
		for u in _army_units():
			if u != null and is_instance_valid(u) and u.is_idle_like():
				idle.append(u)
		if not idle.is_empty():
			_sched.move(idle, hold, "wave")
		return
	super._manage_waves(diff)


## 玩家指了进攻点时，推进目标就是那个点（覆盖"最近敌方建筑"的默认选择）
func _push_target() -> Vector3:
	var point: Vector3 = attack_point()
	if point != Vector3.INF:
		return point
	return super._push_target()


## 玩家在"驻军"时不要巡逻（巡逻会把部队带走，看起来像不听话）
func _manage_patrol(diff: DifficultyDef) -> void:
	if hold_point() != Vector3.INF:
		return
	super._manage_patrol(diff)


# ===========================================================================
# 每帧：建议通道
# ===========================================================================

func _think_once(diff: DifficultyDef) -> void:
	super._think_once(diff)
	if not enabled:
		return
	_manage_idle_dispatch()
	_maybe_hint_request_control()


# ===========================================================================
# 空闲单位派活（2026-11-06 玩家口径）
# ===========================================================================
#
# 玩家原话：「训练出的农民/部队待门口，没有集结点、不主动、也不会去执行
# 智能决策目标层的目标」。
#
# 根因链（查过一遍，是结构性的，不是某一处写错）：
#   · 目标层（代码/ai/目标层.gd）是**纯静态仲裁**，只产出"目标 + 诉求分"，
#     全文件不接收也不返回任何单位 —— 根本没有"空闲单位领取目标"的入口；
#   · 真正下令的是 `_issue_wave_plan()`，它被 `_next_wave_at` / `allow_attack` /
#     `army >= min_wave_size` 三重门控挡着，凑不够人就不发；
#   · 副官唯一"收拢闲兵"的重写 `_manage_waves()` 在默认 `dept=ON` 下是**死代码**
#     （`简单AI._think_once` 走 `_dept_tick`，不再调 `_manage_waves`）。
# 结果：新兵 `order == NONE` 之后就是终态，只有被动还手，永远不会自己找事做。
#
# 这里补上最后一块：**给闲着的单位派一件低风险、有产出的事**。
#   · 农民 → 最近的金矿（没有金矿就砍树）：这是"有产出"的默认行为；
#   · 战斗单位 → **集合点**（基地朝敌方 12m 处，或玩家指定的驻守点）。
#     不直接推出去送死，但也绝不站在兵营门口。
# 玩家正在微操的单位由 `Game.control.is_protected()` 剔除，不会被抢走。
var _idle_next_at: float = 0.0
var idle_dispatch_stats: Dictionary = {"worker": 0, "army": 0}


func _manage_idle_dispatch() -> void:
	if _faction == null:
		return
	var now: float = Game.elapsed
	if now < _idle_next_at:
		return
	_idle_next_at = now + IDLE_DISPATCH_GAP

	var base: Vector3 = RtsWorld.base_center(_faction)
	var radius: float = Cfg.game.map_size * 0.75
	var workers: Array = []
	var army: Array = []
	for u in _faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		if u.def == null or not u.is_idle_like():
			continue
		# 玩家刚点过的人（命令组生命周期 + 5s 宽限）一律不动
		if Game.control != null and Game.control.is_protected(u):
			continue
		if RtsWorld.is_worker_def(u.def):
			workers.append(u)
		else:
			army.append(u)

	# --- 农民：闲着就去采 ---
	if not workers.is_empty():
		var drop: Vector3 = _wood_dropoff()
		var kind: int = RtsConst.Harvest.WOOD if Game.is_night() else RtsConst.Harvest.GOLD
		var pool: Node3D = null
		for w in workers:
			pool = null
			if kind == RtsConst.Harvest.WOOD:
				pool = _nearest_wood(w, drop)
			if pool == null:
				pool = Game.find_nearest_harvestable(w.global_position, kind, base, radius)
			if pool == null:
				pool = Game.find_nearest_harvestable(w.global_position,
						RtsConst.Harvest.GOLD, base, radius)
			if pool == null:
				continue
			_sched.gather([w], pool, "idle")
			idle_dispatch_stats["worker"] = int(idle_dispatch_stats["worker"]) + 1

	# --- 部队：往集合点收拢（家里挨打时不动，交给回防逻辑）---
	if army.is_empty():
		return
	if float(metrics.get("base_threat", 0.0)) > 0.0:
		return
	var anchor: Vector3 = hold_point()
	if anchor == Vector3.INF:
		anchor = assembly_point()
	if anchor == Vector3.INF:
		return
	_sched.move(army, anchor, "idle")
	idle_dispatch_stats["army"] = int(idle_dispatch_stats["army"]) + 1


## 部队集合点：基地朝敌方（或玩家指定进攻点）12m 处。
## 放这么近是有意的 —— 玩家一眼能看到"我的兵在门口集结"，而不是散在地图中间。
func assembly_point() -> Vector3:
	if _faction == null:
		return Vector3.INF
	var base: Vector3 = RtsWorld.base_center(_faction)
	var foe: Vector3 = _push_target()
	if foe == Vector3.INF or foe == Vector3.ZERO:
		return base
	var d: Vector3 = foe - base
	d.y = 0.0
	if d.length() < 1.0:
		return base
	return RtsWorld.walkable_pos(base + d.normalized() * ASSEMBLY_RADIUS)


## 调试/自检：副官现在手里的指令
func directive_debug() -> String:
	return "[副官] 进攻点=%s 驻守点=%s 意图=%s" % [
		str(attack_point()), str(hold_point()), str(intake_stats)]
