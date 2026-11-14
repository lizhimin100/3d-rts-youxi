extends RefCounted
## 职责：Model 层自测（纯逻辑，不碰引擎）—— --check 会调用 run_all()
## 属于：Tests/model
## 对外：run_all() -> {pass, fail, lines}
## 铁律：断言的是**规则结果**，不是把公式抄一遍；每条都要能反着验（改坏 → 失败）。

const Rng := preload("res://Model/core/rng.gd")
const Damage := preload("res://Model/core/damage.gd")
const Economy := preload("res://Model/core/economy.gd")
const Production := preload("res://Model/core/production.gd")
const Progression := preload("res://Model/core/progression.gd")
const SaveSchema := preload("res://Model/save/save_schema.gd")
const Skirmish := preload("res://Model/battle/skirmish.gd")
const Avail := preload("res://Model/core/可用性.gd")


static func run_all() -> Dictionary:
	var out := {"pass": 0, "fail": 0, "lines": []}
	var ok := func(name: String, cond: bool, detail: String = "") -> void:
		if cond:
			out["pass"] = int(out["pass"]) + 1
			out["lines"].append("  ✓ %s %s" % [name, detail])
		else:
			out["fail"] = int(out["fail"]) + 1
			out["lines"].append("  ✗ %s %s" % [name, detail])

	# ---------- RNG ----------
	var a := Rng.new(42)
	var b := Rng.new(42)
	var c := Rng.new(43)
	var same := true
	for i in 20:
		if a.next_u32() != b.next_u32():
			same = false
	var differs := false
	for i in 20:
		if Rng.new(42).next_u32() != 0:
			pass
	var a2 := Rng.new(42)
	for i in 20:
		a2.next_u32()
	differs = Rng.new(42).next_u32() != Rng.new(43).next_u32()
	ok.call("同种子序列一致", same)
	ok.call("不同种子序列不同", differs)
	var r := Rng.new(7)
	var in_range := true
	for i in 200:
		var v := r.range_int(3, 7)
		if v < 3 or v > 7:
			in_range = false
	ok.call("range_int 落在闭区间", in_range)
	var wi := Rng.new(9).weighted_index([0.0, 1.0, 0.0])
	ok.call("weighted_index 只命中非零权重", wi == 1, "idx=%d" % wi)

	# ---------- 伤害 ----------
	var rules := {
		"damage_table": [1.0, 0.85, 0.6, 1.0, 0.92, 1.35, 0.85, 0.45, 1.2, 1.05],
		"stride": 5,
		"armor_reduction": 0.06,
		"armor_reduction_cap": 0.72,
		"crit_chance": 0.0,
		"crit_multiplier": 1.65,
	}
	ok.call("护甲减免封顶 0.72", is_equal_approx(Damage.armor_mitigation(100.0, 0.06, 0.72), 0.72))
	ok.call("护甲为负按 0 算", is_equal_approx(Damage.armor_mitigation(-5.0, 0.06, 0.72), 0.0))
	ok.call("克制表按 stride 取第二行第一列", is_equal_approx(Damage.counter_multiplier(rules["damage_table"], 1, 0, 5), 1.35))
	ok.call("克制表越界夹紧到最后一列", is_equal_approx(Damage.counter_multiplier(rules["damage_table"], 0, 9, 5), 0.92))
	var d1 := Damage.compute(10.0, 0.0, 0, 0.0, 0, rules, 0.5, 0.5)
	ok.call("无护甲无克制 = 基础伤害", is_equal_approx(float(d1["damage"]), 10.0), "%.4f" % float(d1["damage"]))
	var d2 := Damage.compute(10.0, 0.0, 0, 10.0, 0, rules, 0.5, 0.5)
	ok.call("10 点护甲 → ×(1-0.6)", is_equal_approx(float(d2["damage"]), 4.0), "%.4f" % float(d2["damage"]))
	var crit_rules := rules.duplicate(true)
	crit_rules["crit_chance"] = 0.5
	var d3 := Damage.compute(10.0, 0.0, 0, 0.0, 0, crit_rules, 0.5, 0.1)
	var d4 := Damage.compute(10.0, 0.0, 0, 0.0, 0, crit_rules, 0.5, 0.9)
	ok.call("掷值 < 暴击率时暴击", bool(d3["is_crit"]) and is_equal_approx(float(d3["damage"]), 16.5))
	ok.call("掷值 >= 暴击率时不暴击", not bool(d4["is_crit"]) and is_equal_approx(float(d4["damage"]), 10.0))
	var d5 := Damage.compute(10.0, 2.0, 0, 0.0, 0, rules, 0.0, 0.5)
	var d6 := Damage.compute(10.0, 2.0, 0, 0.0, 0, rules, 0.999999, 0.5)
	ok.call("spread 两端 = 基础±spread", float(d5["damage"]) < float(d6["damage"]) and absf(float(d5["damage"]) - 8.0) < 0.001 and absf(float(d6["damage"]) - 12.0) < 0.05)

	# ---------- 可用性（训练/研究/建造） ----------
	var train_ok := {"constructed": true, "trains": [&"footman"], "id": &"footman", "require_tier": 0,
		"current_tier": 1, "queue_size": 0, "queue_max": 10, "food_cost": 2, "food_free": 10,
		"gold": 200, "wood": 100, "gold_cost": 125, "wood_cost": 0}
	ok.call("可用性：训练条件齐 → ok", bool(Avail.check_train(train_ok)["ok"]))
	var t1 := train_ok.duplicate(true)
	t1["trains"] = [&"archer"]
	ok.call("可用性：建筑不能造这个兵 → not_in_trains", String(Avail.check_train(t1)["reason"]) == "not_in_trains")
	var t2 := train_ok.duplicate(true)
	t2["require_tier"] = 2
	var rt2 := Avail.check_train(t2)
	ok.call("可用性：二本兵在一本 → tier_locked", String(rt2["reason"]) == "tier_locked" and int(rt2["params"]["required"]) == 2)
	var t3 := train_ok.duplicate(true)
	t3["queue_size"] = 10
	ok.call("可用性：队列满 → queue_full", String(Avail.check_train(t3)["reason"]) == "queue_full")
	var t4 := train_ok.duplicate(true)
	t4["upgrading"] = true
	ok.call("可用性：升级中 → upgrading", String(Avail.check_train(t4)["reason"]) == "upgrading")
	var t5 := train_ok.duplicate(true)
	t5["gold"] = 100
	var rt5 := Avail.check_train(t5)
	ok.call("可用性：金币不足 → no_gold（差 25）", String(rt5["reason"]) == "no_gold" and int(rt5["params"]["short"]) == 25)
	var t6 := train_ok.duplicate(true)
	t6["food_free"] = 1
	ok.call("可用性：人口不足 → no_food", String(Avail.check_train(t6)["reason"]) == "no_food")
	ok.call("可用性：训练资格（trains+tier）单独可判",
		bool(Avail.check_train_permission([&"footman"], &"footman", 0, 1)["ok"])
		and String(Avail.check_train_permission([&"footman"], &"footman", 2, 1)["reason"]) == "tier_locked")

	var research_ok := {"constructed": true, "researchable": true, "upgrading": false, "busy": false,
		"level": 1, "max_level": 5, "gold": 200, "wood": 100, "gold_cost": 100, "wood_cost": 40}
	ok.call("可用性：研究条件齐 → ok", bool(Avail.check_research(research_ok)["ok"]))
	var av_r1 := research_ok.duplicate(true)
	av_r1["busy"] = true
	ok.call("可用性：已有研究 → research_busy", String(Avail.check_research(av_r1)["reason"]) == "research_busy")
	var av_r2 := research_ok.duplicate(true)
	av_r2["level"] = 5
	ok.call("可用性：满级 → max_level", String(Avail.check_research(av_r2)["reason"]) == "max_level")
	var av_r3 := research_ok.duplicate(true)
	av_r3["upgrading"] = true
	ok.call("可用性：升级中研究 → upgrading", String(Avail.check_research(av_r3)["reason"]) == "upgrading")
	var av_r4 := research_ok.duplicate(true)
	av_r4["wood"] = 0
	ok.call("可用性：木材不足 → no_wood", String(Avail.check_research(av_r4)["reason"]) == "no_wood")

	var build_ok := {"has_worker": true, "require_tier": 0, "current_tier": 1, "gold": 200, "wood": 100, "gold_cost": 80, "wood_cost": 20}
	ok.call("可用性：建造条件齐 → ok", bool(Avail.check_build(build_ok)["ok"]))
	var b1 := build_ok.duplicate(true)
	b1["has_worker"] = false
	ok.call("可用性：没农民 → no_worker", String(Avail.check_build(b1)["reason"]) == "no_worker")
	var b2 := build_ok.duplicate(true)
	b2["require_tier"] = 2
	ok.call("可用性：二本建筑在一本 → tier_locked", String(Avail.check_build(b2)["reason"]) == "tier_locked")
	var b3 := build_ok.duplicate(true)
	b3["gold"] = 0
	ok.call("可用性：建造金币不足 → no_gold", String(Avail.check_build(b3)["reason"]) == "no_gold")

	var refit_ok := {"constructed": true, "busy": false, "gold": 200, "wood": 100, "gold_cost": 40, "wood_cost": 15}
	ok.call("可用性：改造条件齐 → ok", bool(Avail.check_refit(refit_ok)["ok"]))
	var rf1 := refit_ok.duplicate(true)
	rf1["busy"] = true
	ok.call("可用性：改造中 → upgrading", String(Avail.check_refit(rf1)["reason"]) == "upgrading")
	var rf2 := refit_ok.duplicate(true)
	rf2["gold"] = 10
	ok.call("可用性：改造金币不足 → no_gold", String(Avail.check_refit(rf2)["reason"]) == "no_gold")

	# ---------- 经济 ----------
	ok.call("钱不够不能付", not Economy.can_afford(100, 50, 101, 50))
	var st := {"gold": 100, "wood": 50}
	ok.call("付不起时一分不扣", not Economy.pay(st, 150, 0) and int(st["gold"]) == 100 and int(st["wood"]) == 50)
	ok.call("付得起时精确扣", Economy.pay(st, 80, 20) and int(st["gold"]) == 20 and int(st["wood"]) == 30)
	ok.call("人口边界：已用+排队+本单 == 上限 可以", Economy.has_food(10, 2, 3, 15))
	ok.call("人口边界：超 1 不行", not Economy.has_food(10, 2, 4, 15))
	ok.call("采集收入 = 农民×携带/往返", is_equal_approx(Economy.income_per_second(5, 20, 10.0), 10.0))

	# ---------- 生产 ----------
	var q: Array = []
	Production.enqueue(q, "footman", 1.0, 2)
	var done1 := Production.tick(q, 0.5)
	var done2 := Production.tick(q, 0.5)
	ok.call("队列 1 秒：0.5s 未完成、再 0.5s 完成", done1.is_empty() and done2.size() == 1)
	Production.enqueue(q, "a", 1.0, 1)
	Production.enqueue(q, "b", 1.0, 1)
	ok.call("同一 tick 可完成多件", Production.tick(q, 2.0).size() == 2)
	ok.call("队列人口合计", Production.total_food([{"food": 2}, {"food": 3}]) == 5)

	# ---------- 成长 ----------
	ok.call("铁匠铺每级平铺 +1", is_equal_approx(Progression.flat_bonus(3, 1.0), 3.0))
	ok.call("升级门槛：钱够且未到顶", Progression.can_upgrade(1, 5, 100, 0, 100, 0))
	ok.call("升级门槛：到顶不行", not Progression.can_upgrade(5, 5, 999, 999, 1, 1))
	ok.call("二本门槛：require 2 当前 1 → 不允许", not Progression.tier_allows(2, 1))
	ok.call("二本门槛：require 2 当前 2 → 允许", Progression.tier_allows(2, 2))

	# ---------- 存档 schema ----------
	var prof := SaveSchema.new_profile(123)
	var v := SaveSchema.validate(prof)
	ok.call("新档通过校验", bool(v["ok"]), str(v["errors"]))
	var bad := prof.duplicate(true)
	bad["stats"]["wins"] = 5
	bad["stats"]["games_played"] = 1
	ok.call("wins > games 被拦下", not bool(SaveSchema.validate(bad)["ok"]))
	var old := {"seed": 7}
	var migrated := SaveSchema.migrate(old)
	ok.call("v0 迁移补 version 与 stats", int(migrated["version"]) == SaveSchema.CURRENT_VERSION and migrated.has("stats"))

	# ---------- 推演 ----------
	var stats := {
		"max_hp": 100.0, "attack_damage": 10.0, "attack_spread": 0.0,
		"attack_cooldown": 1.0, "attack_range": 1.5, "attack_type": 0,
		"armor": 0.0, "armor_type": 0, "move_speed": 5.0,
		"gold_cost": 50, "wood_cost": 0, "food_cost": 1, "train_time": 2.0,
	}
	var config := {
		"seed": 11, "dt": 0.1, "max_seconds": 60.0, "sample_seconds": 30.0,
		"rules": rules,
		"economy": {"harvest_carry_gold": 20, "harvest_time_gold": 3.2, "trip_seconds": 14.0},
		"sides": [
			{"name": "A", "base_x": -10.0, "workers": 3, "start_gold": 300, "start_wood": 0,
			 "food_cap": 10, "army_target": 4, "roster": [{"id": "u", "weight": 1.0, "stats": stats}]},
			{"name": "B", "base_x": 10.0, "workers": 3, "start_gold": 300, "start_wood": 0,
			 "food_cap": 10, "army_target": 4, "roster": [{"id": "u", "weight": 1.0, "stats": stats}]},
		],
	}
	ok.call("推演配置合法", Skirmish.validate(config).is_empty(), str(Skirmish.validate(config)))
	var r1 := Skirmish.run(config)
	var r2 := Skirmish.run(config)
	ok.call("同配置同种子 → 结果逐字节一致", JSON.stringify(r1) == JSON.stringify(r2))
	ok.call("推演有胜负且双方都出过兵", bool(r1["ok"]) and String(r1["winner"]) != "" and int(r1["sides"][0]["units_built"]) > 0)
	var broken := config.duplicate(true)
	broken["sides"][0]["roster"][0]["stats"].erase("attack_damage")
	ok.call("缺字段的配置被 validate 拦下", not Skirmish.validate(broken).is_empty())

	return out