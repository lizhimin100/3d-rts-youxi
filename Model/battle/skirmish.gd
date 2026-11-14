extends RefCounted
## 职责：确定性小规模推演（--simulate 的引擎）—— **只用 Model**，不加载场景/不渲染
## 属于：Model/battle
## 对外：run(config) / validate(config)
## config（由调用方从 Content/data 读出来再传进来）：
##   {
##     "seed": 1, "dt": 0.1, "max_seconds": 300, "sample_seconds": 10,
##     "rules":  {damage_table, stride, armor_reduction, armor_reduction_cap, crit_chance, crit_multiplier},
##     "economy": {harvest_carry_gold, harvest_time_gold, trip_seconds},
##     "sides": [ {name, base_x, workers, start_gold, start_wood, food_cap, army_target,
##                 roster: [{id, weight, stats:{…}}]} , {...} ]
##   }
## stats 需要的字段：max_hp / attack_damage / attack_spread / attack_cooldown / attack_range /
##   attack_type / armor / armor_type / move_speed / gold_cost / wood_cost / food_cost / train_time
## 这个推演**不是**游戏本体：没有地形/寻路/建筑/技能，只验证"数值规则放在一起跑会怎样"。
## 结果必须可复现：同 seed + 同配置 → 逐字节相同的 JSON。

const Rng := preload("res://Model/core/rng.gd")
const Damage := preload("res://Model/core/damage.gd")
const Economy := preload("res://Model/core/economy.gd")
const Production := preload("res://Model/core/production.gd")

const EPS := 0.000001
const REQUIRED_STATS := [
	"max_hp", "attack_damage", "attack_spread", "attack_cooldown", "attack_range",
	"attack_type", "armor", "armor_type", "move_speed", "gold_cost", "wood_cost",
	"food_cost", "train_time",
]


static func validate(config: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	var sides: Variant = config.get("sides", null)
	if not (sides is Array) or (sides as Array).size() != 2:
		errors.append("sides 必须是恰好 2 个阵营")
		return errors
	for si in (sides as Array).size():
		var side: Variant = sides[si]
		if not (side is Dictionary):
			errors.append("sides[%d] 不是对象" % si)
			continue
		var roster: Variant = side.get("roster", [])
		if not (roster is Array) or (roster as Array).is_empty():
			errors.append("sides[%d].roster 不能为空" % si)
			continue
		for ri in (roster as Array).size():
			var entry: Variant = roster[ri]
			if not (entry is Dictionary):
				errors.append("sides[%d].roster[%d] 不是对象" % [si, ri])
				continue
			var stats: Variant = entry.get("stats", {})
			if not (stats is Dictionary):
				errors.append("sides[%d].roster[%d].stats 不是对象" % [si, ri])
				continue
			for key in REQUIRED_STATS:
				if not (stats as Dictionary).has(key):
					errors.append("sides[%d].roster[%d].stats 缺 %s" % [si, ri, key])
	if not (config.get("rules", {}) is Dictionary) or not (config.get("economy", {}) is Dictionary):
		errors.append("rules / economy 必须是对象")
	return errors


static func run(config: Dictionary) -> Dictionary:
	var errors := validate(config)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	var rng := Rng.new(int(config.get("seed", 1)))
	var dt := maxf(float(config.get("dt", 0.1)), 0.001)
	var max_seconds := maxf(float(config.get("max_seconds", 300.0)), dt)
	var sample_seconds := maxf(float(config.get("sample_seconds", 10.0)), dt)
	var rules: Dictionary = config.get("rules", {})
	var economy: Dictionary = config.get("economy", {})
	var sides: Array = []
	var side_index := 0
	for sc in config.get("sides", []):
		sides.append(_make_side(sc, int(config.get("seed", 1)), side_index))
		side_index += 1
	var timeline: Array = []
	var t := 0.0
	var tick := 0
	var next_sample := 0.0
	while t < max_seconds - EPS:
		t += dt
		tick += 1
		for side in sides:
			_tick_economy(side, economy, dt)
		for side in sides:
			_tick_production(side, dt)
		_tick_combat(sides, rules, dt, tick)
		if t + EPS >= next_sample:
			next_sample += sample_seconds
			timeline.append({
				"t": roundf(t * 10.0) / 10.0,
				"units": [sides[0]["units"].size(), sides[1]["units"].size()],
				"gold": [int(sides[0]["gold"]), int(sides[1]["gold"])],
				"hp": [roundf(_total_hp(sides[0])), roundf(_total_hp(sides[1]))],
			})
	var result := {
		"ok": true,
		"seed": int(config.get("seed", 1)),
		"seconds": roundf(t * 10.0) / 10.0,
		"winner": _winner(sides),
		"sides": [],
		"timeline": timeline,
	}
	for side in sides:
		var units: Array = side["units"]
		var by_type: Dictionary = {}
		for u in units:
			var uid := String(u["id"])
			by_type[uid] = int(by_type.get(uid, 0)) + 1
		result["sides"].append({
			"name": String(side["name"]),
			"alive": units.size(),
			"alive_by_type": by_type,
			"hp_left": roundf(_total_hp(side)),
			"kills": int(side["kills"]),
			"losses": int(side["losses"]),
			"units_built": int(side["units_built"]),
			"built_by_type": side["built_by_type"],
			"gold_mined": int(side["gold_mined"]),
			"gold_left": int(side["gold"]),
			"damage_dealt": roundf(float(side["damage_dealt"])),
		})
	return result


# ===========================================================================
# 内部
# ===========================================================================
static func _make_side(sc: Dictionary, seed_value: int, side_index: int) -> Dictionary:
	return {
		"name": String(sc.get("name", "side")),
		"base_x": float(sc.get("base_x", 0.0)),
		"workers": maxi(int(sc.get("workers", 0)), 0),
		"gold": maxi(int(sc.get("start_gold", 0)), 0),
		"wood": maxi(int(sc.get("start_wood", 0)), 0),
		"food_cap": maxi(int(sc.get("food_cap", 0)), 0),
		"army_target": maxi(int(sc.get("army_target", 12)), 1),
		"roster": sc.get("roster", []),
		"units": [],
		"queue": [],
		"kills": 0,
		"losses": 0,
		"units_built": 0,
		"built_by_type": {},
		"gold_mined": 0,
		"damage_dealt": 0.0,
		# 每个阵营一条**独立**随机流：生产互不串号，战斗掷值也不受对方下单顺序影响
		"prod_rng": Rng.new(seed_value),
		"combat_rng": Rng.new(seed_value + 104729 * (side_index + 1)),
	}


static func _tick_economy(side: Dictionary, economy: Dictionary, dt: float) -> void:
	var carry := maxi(int(economy.get("harvest_carry_gold", 20)), 1)
	var trip := maxf(float(economy.get("trip_seconds", 14.0)), 0.1)
	var rate := Economy.income_per_second(int(side["workers"]), carry, trip)
	var gain := rate * dt
	var whole := int(floor(gain))
	if whole <= 0:
		# 不足 1 金的零头不丢：攒到下个 tick（用小数金币会让报告难读，这里先取整累加）
		side["_gold_frac"] = float(side.get("_gold_frac", 0.0)) + gain
		whole = int(floor(float(side["_gold_frac"])))
		if whole > 0:
			side["_gold_frac"] = float(side["_gold_frac"]) - float(whole)
	if whole > 0:
		side["gold"] = int(side["gold"]) + whole
		side["gold_mined"] = int(side["gold_mined"]) + whole


static func _tick_production(side: Dictionary, dt: float) -> void:
	var rng: Rng = side["prod_rng"]
	# 先进队列：队列空 → 选一个买得起、人口够的兵
	var queue: Array = side["queue"]
	var units: Array = side["units"]
	if queue.is_empty() and units.size() < int(side["army_target"]):
		var roster: Array = side["roster"]
		var weights: Array = []
		for e in roster:
			weights.append(float(e.get("weight", 1.0)))
		var start := rng.weighted_index(weights) if not weights.is_empty() else 0
		for k in roster.size():
			var entry: Dictionary = roster[(start + k) % roster.size()]
			var stats: Dictionary = entry["stats"]
			var food_cost := int(stats["food_cost"])
			var used := _food_used(side)
			if not Economy.has_food(used, Production.total_food(queue), food_cost, int(side["food_cap"])):
				continue
			var state := {"gold": int(side["gold"]), "wood": int(side["wood"])}
			if not Economy.pay(state, int(stats["gold_cost"]), int(stats["wood_cost"])):
				continue
			side["gold"] = int(state["gold"])
			side["wood"] = int(state["wood"])
			Production.enqueue(queue, String(entry["id"]), float(stats["train_time"]), food_cost)
			break
	# 推进队列
	var done := Production.tick(queue, dt)
	for item in done:
		var uid := String(item["id"])
		var entry := _roster_entry(side, uid)
		if entry.is_empty():
			continue
		_spawn(side, entry)
		side["units_built"] = int(side["units_built"]) + 1
		var btt: Dictionary = side["built_by_type"]
		btt[uid] = int(btt.get(uid, 0)) + 1


static func _roster_entry(side: Dictionary, uid: String) -> Dictionary:
	for e in side["roster"]:
		if String(e["id"]) == uid:
			return e
	return {}


static func _spawn(side: Dictionary, entry: Dictionary) -> void:
	var stats: Dictionary = entry["stats"]
	side["units"].append({
		"id": String(entry["id"]),
		"hp": float(stats["max_hp"]),
		"max_hp": float(stats["max_hp"]),
		"x": float(side["base_x"]),
		"cd": 0.0,
		"stats": stats,
	})


static func _food_used(side: Dictionary) -> int:
	var used := 0
	for u in side["units"]:
		used += int((u["stats"] as Dictionary).get("food_cost", 0))
	return used


static func _tick_combat(sides: Array, rules: Dictionary, dt: float, tick: int) -> void:
	# 先手每 tick 交替，避免"编号小的阵营永远先打"这种假优势
	for k in sides.size():
		var si := (tick + k) % sides.size()
		var me: Dictionary = sides[si]
		var foe: Dictionary = sides[(si + 1) % sides.size()]
		for u in me["units"]:
			u["cd"] = maxf(float(u["cd"]) - dt, 0.0)
			var target := _nearest_enemy(u, foe)
			if target.is_empty():
				# 没有敌人：朝对方基地推进（报告里能看到"打崩了在推线"）
				u["x"] = _move_toward(u, float(foe["base_x"]), dt)
				continue
			var stats: Dictionary = u["stats"]
			var reach := maxf(float(stats["attack_range"]), 0.1)
			var dist := absf(float(u["x"]) - float(target["x"]))
			if dist > reach:
				u["x"] = _move_toward(u, float(target["x"]), dt)
			elif float(u["cd"]) <= EPS:
				var crng: Rng = me["combat_rng"]
				var out := Damage.compute(
					float(stats["attack_damage"]), float(stats["attack_spread"]),
					int(stats["attack_type"]), float((target["stats"] as Dictionary)["armor"]),
					int((target["stats"] as Dictionary)["armor_type"]),
					rules, crng.next_float(), crng.next_float(), 1.0)
				var dmg := float(out.get("damage", 0.0))
				target["hp"] = float(target["hp"]) - dmg
				me["damage_dealt"] = float(me["damage_dealt"]) + dmg
				u["cd"] = maxf(float(stats["attack_cooldown"]), 0.05)
		# 清理阵亡
		var alive: Array = []
		for u in me["units"]:
			if float(u["hp"]) > 0.0:
				alive.append(u)
			else:
				me["losses"] = int(me["losses"]) + 1
				foe["kills"] = int(foe["kills"]) + 1
		me["units"] = alive


static func _nearest_enemy(u: Dictionary, foe: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for e in foe["units"]:
		var d := absf(float(u["x"]) - float(e["x"]))
		if d < best_d:
			best_d = d
			best = e
	return best


static func _move_toward(u: Dictionary, goal_x: float, dt: float) -> float:
	var stats: Dictionary = u["stats"]
	var speed := maxf(float(stats["move_speed"]), 0.5)
	var x := float(u["x"])
	var step := speed * dt
	if absf(goal_x - x) <= step:
		return goal_x
	return x + signf(goal_x - x) * step


static func _total_hp(side: Dictionary) -> float:
	var total := 0.0
	for u in side["units"]:
		total += maxf(float(u["hp"]), 0.0)
	return total


static func _winner(sides: Array) -> String:
	var a: Dictionary = sides[0]
	var b: Dictionary = sides[1]
	var a_score := float(a["kills"]) * 3.0 + float(a["units"].size()) * 2.0 + _total_hp(a) * 0.01
	var b_score := float(b["kills"]) * 3.0 + float(b["units"].size()) * 2.0 + _total_hp(b) * 0.01
	if absf(a_score - b_score) <= 0.0001:
		return "draw"
	return String(a["name"]) if a_score > b_score else String(b["name"])