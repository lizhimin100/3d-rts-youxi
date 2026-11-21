extends SceneTree
## 职责：--simulate 的入口（**只用 Model 跑若干局**，不渲染、不建场景）
## 用法：godot --headless --path . --script Tests/sim/run_simulate.gd -- --games=5 --seed=1
## 数据：Content/data/sim.json（场景）+ units.json / game.json（数值，走真实 Cfg 装载）
## 输出：人读表格 + 一行机器可读 `SIM {json}`；有错退出码 1。

const Skirmish := preload("res://Game/adapters/skirmish.gd")
const JsonFile := preload("res://Engine/util/json_file.gd")

const SIM_JSON := "res://Content/data/sim.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========== 数值报告（只用 Model 推演，无窗口/无渲染） ==========")
	var cfg_node := root.get_node_or_null("Cfg")
	if cfg_node == null:
		_fail("Cfg 自动加载没就绪（autoload 失败？）")
		return
	var cfg: GameConfig = cfg_node.get("game")
	if cfg == null:
		_fail("Cfg.game 为空（Content/data/game.json 没装载？）")
		return
	var scenario: Dictionary = JsonFile.read_dict(SIM_JSON, {})
	if scenario.is_empty():
		_fail("读不到 " + SIM_JSON)
		return
	var games := int(scenario.get("games", 3))
	var seed_base := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--games="):
			games = int(a.substr(8))
		if a.begins_with("--seed="):
			seed_base = int(a.substr(7))
	games = clampi(games, 1, 200)
	var config := _build_config(scenario, cfg, seed_base)
	var errors := Skirmish.validate(config)
	if not errors.is_empty():
		for e in errors:
			print("  ✗ " + e)
		_fail("场景配置不合法")
		return

	print("注意：推演不含地形/建筑/技能，只做数值回归；胜负不能直接当平衡结论。")
	print("场景：%s vs %s ｜ 每局上限 %.0fs ｜ 每 %.0fs 采样 ｜ 共 %d 局" % [
		config["sides"][0]["name"], config["sides"][1]["name"],
		float(config["max_seconds"]), float(config["sample_seconds"]), games])
	print("---------------------------------------------------------------")
	print("%-4s %-6s %-8s %-8s %-26s %-26s" % ["局", "种子", "时长", "胜方", "玩家 击杀/损失/出兵/补给", "AI 击杀/损失/出兵/补给"])
	var wins := {}
	var total_seconds := 0.0
	var results: Array = []
	for g in games:
		var one: Dictionary = config.duplicate(true)
		one["seed"] = seed_base + g
		var r := Skirmish.run(one)
		if not bool(r.get("ok", false)):
			_fail("第 %d 局失败：%s" % [g + 1, str(r.get("errors", []))])
			return
		results.append(r)
		var a: Dictionary = r["sides"][0]
		var b: Dictionary = r["sides"][1]
		print("%-4d %-6d %-8.1f %-8s %-26s %-26s" % [
			g + 1, int(r["seed"]), float(r["seconds"]), String(r["winner"]),
			"%d/%d/%d/%d" % [int(a["kills"]), int(a["losses"]), int(a["units_built"]), int(a["gold_mined"])],
			"%d/%d/%d/%d" % [int(b["kills"]), int(b["losses"]), int(b["units_built"]), int(b["gold_mined"])],
		])
		var w := String(r["winner"])
		wins[w] = int(wins.get(w, 0)) + 1
		total_seconds += float(r["seconds"])

	var name_a := String(config["sides"][0]["name"])
	var name_b := String(config["sides"][1]["name"])
	print("---------------------------------------------------------------")
	print("汇总：%s 胜 %d ｜ %s 胜 %d ｜ 平局 %d ｜ 平均时长 %.1fs" % [
		name_a, int(wins.get(name_a, 0)), name_b, int(wins.get(name_b, 0)),
		int(wins.get("draw", 0)), total_seconds / float(games)])

	var summary := {
		"ok": true,
		"games": games,
		"seed_base": seed_base,
		"wins": wins,
		"avg_seconds": roundf(total_seconds / float(games) * 10.0) / 10.0,
		"results": results,
	}
	print("SIM " + JSON.stringify(summary))
	quit(0)


func _build_config(scenario: Dictionary, cfg: GameConfig, seed_base: int) -> Dictionary:
	var game_script: GDScript = load("res://Game/config/游戏配置.gd")
	var sides: Array = []
	for sc in scenario.get("sides", []):
		var roster: Array = []
		for entry in sc.get("roster", []):
			var id := StringName(String(entry.get("id", "")))
			var d: UnitDef = cfg.unit_def(id)
			if d == null:
				push_error("[simulate] units.json 里没有这个 id：" + String(id))
				continue
			roster.append({
				"id": String(id),
				"weight": float(entry.get("weight", 1.0)),
				"stats": _def_to_stats(d),
			})
		sides.append({
			"name": String(sc.get("name", "side")),
			"base_x": float(sc.get("base_x", 0.0)),
			"workers": int(sc.get("workers", 0)),
			"start_gold": int(sc.get("start_gold", 0)),
			"start_wood": int(sc.get("start_wood", 0)),
			"food_cap": int(sc.get("food_cap", 0)),
			"army_target": int(sc.get("army_target", 12)),
			"roster": roster,
		})
	return {
		"seed": seed_base,
		"dt": float(scenario.get("dt", 0.1)),
		"max_seconds": float(scenario.get("max_seconds", 300.0)),
		"sample_seconds": float(scenario.get("sample_seconds", 30.0)),
		"rules": {
			"damage_table": cfg.damage_table,
			"stride": int(game_script.ARMOR_STRIDE),
			"armor_reduction": cfg.armor_reduction,
			"armor_reduction_cap": cfg.armor_reduction_cap,
			"crit_chance": cfg.crit_chance,
			"crit_multiplier": cfg.crit_multiplier,
		},
		"economy": {
			"harvest_carry_gold": cfg.harvest_carry_gold,
			"harvest_time_gold": cfg.harvest_time_gold,
			"trip_seconds": float(scenario.get("trip_seconds", 14.0)),
		},
		"sides": sides,
	}


## UnitDef → Model 需要的纯字典（Model 不认识 Resource）
func _def_to_stats(d: UnitDef) -> Dictionary:
	return {
		"max_hp": d.max_hp,
		"attack_damage": d.attack_damage,
		"attack_spread": d.attack_spread,
		"attack_cooldown": d.attack_cooldown,
		"attack_range": d.attack_range,
		"attack_type": d.attack_type,
		"armor": d.armor,
		"armor_type": d.armor_type,
		"move_speed": d.move_speed,
		"gold_cost": d.gold_cost,
		"wood_cost": d.wood_cost,
		"food_cost": d.food_cost,
		"train_time": d.train_time,
	}


func _fail(msg: String) -> void:
	print("SIM FAIL " + msg)
	quit(1)