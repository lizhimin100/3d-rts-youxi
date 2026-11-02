extends RefCounted
## **战略导演**：把世界状态压成一个姿态（Posture），让经济/军事/巡逻朝同一个方向用力。
##
## 为什么需要"姿态"这一层：现在的 AI 是七个 _manage_xxx 各凭本事下令 ——
## 经济说"再多造两个农民"，军事说"全部推上去"，两条同时成立时单位被来回撕。
## 姿态是一份**共同的输入**：经济看 worker_bonus、军事看 aggression 与
## allow_attack、巡逻看 allow_patrol，谁也不会跟别人拧着来。
##
## 三个设计要点：
##   1. **计划是数据**（代码/配置/战略计划.gd），导演只做"算指标 + 选计划"；
##   2. **带滞回**：优先级 >= 90 立刻切，其余至少停留 PLAN_MIN_SECONDS，
##      否则 army_ratio 在阈值附近抖一下，AI 的战术就会每秒变一次；
##   3. **"能不能打"不写在计划里**，而是由战力比 + 敌方静态防御 + 是否被压家
##      算出来（_compute_allow_attack）。写进计划表会变成"某个流派永远不打"。

## 计划最短停留时间（秒）；优先级 >= 90 的除外
const PLAN_MIN_SECONDS: float = 8.0
## 战略权重开关（A/B/C，见 代码/配置/AI战略权重.gd）。默认 A = 现状。
const AIW := preload("res://代码/配置/AI战略权重.gd")
## 出击需要的战力比基准（越难的 AI 越敢打）
const ATTACK_RATIO_BASE: float = 1.35
## "家底够了就敢打"的阈值：总战力到这个数就不再看兵力比（只要求不落后）。
## 450 ≈ 6~7 个兵（步兵战力约 72、弓箭手约 59），正好是"第一波该出门"的家底；
## 定 700 的话简单难度要攒到 10 个兵才动，玩家前 3 分钟见不到敌人（实测过）。
const EAGER_ARMY_VALUE: float = 450.0
## 敌方每 1 点静态防御价值，需要多攒多少战力
const EAGER_STATIC_DEF_WEIGHT: float = 1.2
## 没有情报（看不到敌人）时假设的兵力比
const UNKNOWN_RATIO: float = 1.0
## 敌方军队被打光时的兵力比（该压上去了）
const CLEARED_RATIO: float = 4.0

var _plans: Array = []
var _plan_id: String = ""
var _plan_since: float = -999.0
var _changes: int = 0
## 难度带来的"胆量"：0.85（简单）/ 1.0（普通）/ 1.15（困难）
var skill: float = 1.0
## 最近一次算出的指标（调试 / 自检读它）
var metrics: Dictionary = {}
## C 模式用的"距上次成功出击过了多久"（由 简单AI 每 tick 灌进来）
var _locked_sec: float = 0.0
## 本次算出的门槛（报告/日志读它；A/B 下等于 _attack_ratio_needed 的原始值）
var _ratio_need: float = 0.0


func setup(plans: Array, difficulty_index: int) -> void:
	_plans = plans.duplicate()
	_plans.sort_custom(func(a, b): return int(a["priority"]) > int(b["priority"]))
	skill = 0.85 + 0.15 * float(difficulty_index)
	_plan_id = ""
	_plan_since = -999.0
	_changes = 0


## 每次思考调用一次。ctx 需要：
##   faction / army / enemy_army / workers / idle_workers / threat_units /
##   under_attack / now / combat
func update(ctx: Dictionary) -> Dictionary:
	_locked_sec = float(ctx.get("attack_locked_sec", 0.0))
	var m: Dictionary = build_metrics(ctx)
	metrics = m
	var chosen: Dictionary = _select(m, float(ctx.get("now", 0.0)))
	var params: Dictionary = chosen.get("params", {})

	var threat: float = float(m["base_threat"])
	var aggr: float = float(params.get("aggression", 0.5))
	# 家里在挨打时，任何计划都不许"冲动"（先回防，别送）
	if threat > 0.0:
		aggr = minf(aggr, 0.15)

	return {
		"plan_id": String(chosen.get("id", "default")),
		"stance": String(chosen.get("stance", "balanced")),
		"since": _plan_since,
		"aggression": aggr,
		"worker_bonus": int(params.get("worker_bonus", 0)),
		"allow_patrol": bool(params.get("allow_patrol", true)),
		"research": bool(params.get("research", false)),
		"allow_attack": _compute_allow_attack(m, aggr),
		"attack_ratio_needed": _attack_ratio_needed(),
		# 归因用：这一 tick 用的是哪个分母口径 / 已经多久没打出去
		"ratio_mode": AIW.mode(),
		"attack_locked_sec": _locked_sec,
		"base_threat": threat,
		"army_ratio": float(m["army_ratio"]),
		"metrics": m,
	}


# ===========================================================================
# 指标
# ===========================================================================

func build_metrics(ctx: Dictionary) -> Dictionary:
	var faction: RtsFaction = ctx.get("faction")
	var army: Array = ctx.get("army", [])
	var enemy_army: Array = ctx.get("enemy_army", [])
	var workers: Array = ctx.get("workers", [])
	var idle_workers: Array = ctx.get("idle_workers", [])
	var threat_units: Array = ctx.get("threat_units", [])
	var combat = ctx.get("combat")
	var now: float = float(ctx.get("now", 0.0))

	var ratio: float = UNKNOWN_RATIO
	var atk_ratio: float = UNKNOWN_RATIO
	var my_value: float = 0.0
	if combat != null:
		# ★ 两个比值，两个用途（2026-11-02 拆开）：
		#   plan_ratio   —— 战略计划选择用（all_in / press_advantage 的 when 条件）；
		#   attack_ratio —— 出击许可用（_compute_allow_attack 的 1.35/skill 门槛）。
		# 现在两者读同一个源（enemy_army），所以默认行为一字不变；
		# --ratio-mode=B 只换 attack_ratio 的分母（命中"门槛"而不动计划选择）。
		# 目的：2C 要"移除出击许可对军力比的依赖"时，只动 attack 这一侧即可。
		var plan_army: Array = enemy_army
		var atk_army: Array = ctx.get("ratio_enemy_army", enemy_army)
		if atk_army == null:
			atk_army = enemy_army
		ratio = combat.ratio(army, plan_army)
		if ratio < 0.0:
			ratio = CLEARED_RATIO if army.size() >= 3 else UNKNOWN_RATIO
		atk_ratio = ratio if atk_army == plan_army else combat.ratio(army, atk_army)
		if atk_ratio < 0.0:
			atk_ratio = CLEARED_RATIO if army.size() >= 3 else UNKNOWN_RATIO
		my_value = combat.army_value(army, combat.profile(plan_army))

	var army_food: float = 0.0
	for u in army:
		if u != null and is_instance_valid(u) and u.def != null:
			army_food += float(u.def.food_cost)

	var static_def: float = 0.0
	if faction != null:
		var foe: RtsFaction = Game.enemy_of(faction)
		if foe != null:
			for b in foe.buildings:
				if b == null or not is_instance_valid(b) or not b.is_alive():
					continue
				if b.def != null and b.def.attack_damage > 0.0:
					static_def += b.def.max_hp * 0.2 + b.def.attack_damage * 12.0

	var cap: float = 0.0
	var used: float = 0.0
	if faction != null:
		cap = float(faction.food_cap())
		used = float(faction.food_used())

	return {
		"time": now,
		"gold": float(faction.gold) if faction != null else 0.0,
		"wood": float(faction.wood) if faction != null else 0.0,
		"workers": float(workers.size()),
		"idle_workers": float(idle_workers.size()),
		"army_count": float(army.size()),
		"army_food": army_food,
		# army_ratio 是旧键（计划表 when 条件、日志、自检、bench 都在读它）——语义固定为
		# "计划选择用的那个比值"，永不随 --ratio-mode 变化。
		"army_ratio": ratio,
		"plan_ratio": ratio,
		"attack_ratio": atk_ratio,
		"my_army_value": my_value,
		"food_used": used,
		"food_cap": cap,
		"food_headroom": cap - used,
		"base_threat": float(threat_units.size()),
		"under_attack": 1.0 if bool(ctx.get("under_attack", false)) else 0.0,
		"buildings": float(faction.count_buildings()) if faction != null else 0.0,
		"enemy_static_defense": static_def,
		"gold_float": maxf(float(faction.gold) - 500.0, 0.0) if faction != null else 0.0,
	}


# ===========================================================================
# 计划选择（带滞回）
# ===========================================================================

func _select(m: Dictionary, now: float) -> Dictionary:
	var top: Dictionary = {}
	for p in _plans:
		if _matches(p.get("when", {}), m):
			top = p
			break
	if top.is_empty():
		top = {"id": "default", "priority": 0, "stance": "balanced", "params": {}}
	var cur: Dictionary = _find(_plan_id)
	if cur.is_empty():
		_plan_since = now
		_plan_id = String(top.get("id", "default"))
		return top
	if String(top.get("id", "")) == String(cur.get("id", "")):
		return top
	# 紧急计划（>=90）立即切；其余要等最短停留时间，避免阈值抖动导致战术每秒变
	if int(top.get("priority", 0)) >= 90 or now - _plan_since >= PLAN_MIN_SECONDS:
		_plan_since = now
		_plan_id = String(top.get("id", "default"))
		_changes += 1
		return top
	return cur


func _find(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	for p in _plans:
		if String(p.get("id", "")) == id:
			return p
	return {}


func _matches(when: Dictionary, m: Dictionary) -> bool:
	if when == null or when.is_empty():
		return true
	if when.has("all"):
		for c in when["all"]:
			if not _test(c, m):
				return false
		return true
	if when.has("any"):
		for c in when["any"]:
			if _test(c, m):
				return true
		return false
	# 扁平的单个条件（{"metric":…, "op":…, "value":…}）
	if when.has("metric"):
		return _test(when, m)
	return true


func _test(c: Dictionary, m: Dictionary) -> bool:
	var key: String = String(c.get("metric", ""))
	if not m.has(key):
		return false
	var lhs: float = float(m[key])
	var rhs: float = float(c.get("value", 0.0))
	match String(c.get("op", ">=")):
		">=":
			return lhs >= rhs
		">":
			return lhs > rhs
		"<=":
			return lhs <= rhs
		"<":
			return lhs < rhs
		"==":
			return absf(lhs - rhs) < 0.0001
		"!=":
			return absf(lhs - rhs) >= 0.0001
		_:
			return false


# ===========================================================================
# 出击许可
# ===========================================================================

func _attack_ratio_needed() -> float:
	var base: float = clampf(ATTACK_RATIO_BASE / maxf(skill, 0.1), 1.05, 1.9)
	_ratio_need = AIW.apply_decay(base, _locked_sec)
	return _ratio_need


## 能不能主动出击。两个"可以打"的理由，任一成立即可：
##   · 家底够厚（总战力 >= EAGER_ARMY_VALUE + 敌方静态防御的溢价），且不落后；
##   · 明显占优（战力比达标）且人口兵力够。
## 两个都要求"家里没在挨打" —— 被拆家还出去打是最蠢的死法。
func _compute_allow_attack(m: Dictionary, aggression: float) -> bool:
	if float(m["base_threat"]) > 0.0:
		return false
	if aggression < 0.30:
		return false
	# 出击许可只看 attack_ratio（分母可被 --ratio-mode 换掉）；
	# 计划选择看 army_ratio/plan_ratio。两者默认同源，拆开后互不牵连。
	var ratio: float = float(m.get("attack_ratio", m.get("army_ratio", 0.0)))
	var value: float = float(m["my_army_value"])
	var static_def: float = float(m["enemy_static_defense"])
	var need_value: float = EAGER_ARMY_VALUE + EAGER_STATIC_DEF_WEIGHT * static_def
	var eager: bool = value >= need_value and ratio >= 0.95
	var normal: bool = float(m["army_food"]) >= 10.0 and ratio >= _attack_ratio_needed()
	return eager or normal


func debug_string() -> String:
	if metrics.is_empty():
		return "[导演] 尚未出指标"
	return "[导演] 计划=%s 比=%.2f 军=%d 威胁=%d 金=%d" % [
		_plan_id, float(metrics.get("army_ratio", 0.0)), int(metrics.get("army_count", 0)),
		int(metrics.get("base_threat", 0)), int(metrics.get("gold", 0.0))]

