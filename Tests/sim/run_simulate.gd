extends SceneTree
## 职责：--simulate 的入口（只用 Model 跑第 1 关，不渲染、不建场景）
## 用法：godot --headless --path . --script Tests/sim/run_simulate.gd -- --games=100 --seed=1
## 数据：Content/data/{combat,units,planning,levels}.json（全部交给 C# 内核）
## 输出：人读表格 + 3 个定性复盘样本 + 一行机器可读 `SIM {json}`；有错退出码 1。

const JsonFile := preload("res://Engine/util/json_file.gd")

const COMBAT_JSON := "res://Content/data/combat.json"
const UNITS_JSON := "res://Content/data/units.json"
const PLANNING_JSON := "res://Content/data/planning.json"
const LEVELS_JSON := "res://Content/data/levels.json"
const LEVEL_ID := "level_1"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========== 第 1 关推演（联盟 vs 豺狼人 · 双 90 秒） ==========")
	var bridge_sc := load("res://Game/adapters/bridge.gd")
	if bridge_sc == null:
		_fail("桥脚本加载失败")
		return
	var mdl: RefCounted = bridge_sc.call("get_bridge") as RefCounted
	if mdl == null:
		_fail("C# 内核没编译（ModelBridge 实例化失败）")
		return

	var games := 100
	var seed_base := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--games="):
			games = int(a.substr(8))
		if a.begins_with("--seed="):
			seed_base = int(a.substr(7))
	games = clampi(games, 1, 500)

	var units := JsonFile.read_dict(UNITS_JSON, {})
	var combat := JsonFile.read_dict(COMBAT_JSON, {})
	var planning := JsonFile.read_dict(PLANNING_JSON, {})
	var levels := JsonFile.read_dict(LEVELS_JSON, {})
	if units.is_empty() or combat.is_empty() or planning.is_empty() or levels.is_empty():
		_fail("Content/data 四张表读不全")
		return

	var res: Dictionary = mdl.call("LevelSimulate", units, combat, planning, levels, LEVEL_ID, games, seed_base)
	if not bool(res.get("ok", false)):
		print("  ✗ 数据/推演错误：")
		for e in res.get("errors", []):
			print("    - " + str(e))
		_fail("场景配置不合法")
		return

	print("关卡：%s ｜ %d 局 ｜ 种子 %d..%d ｜ 每局两轮各 90s（轮末清场）" % [
		String(res.get("level_name", LEVEL_ID)), int(res.get("games", 0)),
		seed_base, seed_base + games - 1])
	print("说明：规划由脚本化规划器执行（可复现）；战斗是纯数学 + 确定性 RNG。")
	print("---------------------------------------------------------------")
	print("%-4s %-6s %-5s %-13s %-10s %-9s %-9s %-7s %-5s %-5s %-4s %-4s %s" % [
		"idx", "seed", "res", "player_hp", "enemy_hp", "squads", "loss/kill", "base", "zone", "pike", "cp", "pop", "reason"])

	var rows: Array = res.get("rows", [])
	for row in rows:
		var r: Dictionary = row
		print("%-4d %-6d %-5s %-13s %-10s %-9s %-9s %-7d %-5d %-5s %-4d %-4d %s" % [
			int(r.get("index", 0)), int(r.get("seed", 0)), _outcome_en(String(r.get("outcome", ""))),
			"%d (%d%%)" % [int(r.get("player_hp", 0)), int(r.get("player_hp_pct", 0))],
			str(int(r.get("enemy_hp", 0))),
			"%d/%d" % [int(r.get("player_squads", 0)), int(r.get("enemy_squads", 0))],
			"%d/%d" % [int(r.get("player_losses", 0)), int(r.get("enemy_losses", 0))],
			int(r.get("base_damage", 0)), int(r.get("zone_max", 0)),
			"%d%%" % int(r.get("pike_formation_rate", 0)),
			int(r.get("cp_left", 0)), int(r.get("pop_blocked", 0)),
			String(r.get("top_reason", "")),
		])

	print("---------------------------------------------------------------")
	print("汇总：胜 %d ｜ 负 %d ｜ 平 %d ｜ 胜率 %.1f%% ｜ 平均 %.1fs" % [
		int(res.get("wins", 0)), int(res.get("losses", 0)), int(res.get("draws", 0)),
		float(res.get("win_rate", 0.0)) * 100.0, float(res.get("avg_seconds", 0.0))])
	print("均值：我方基地剩 %.0f%% ｜ 敌基地剩 %.0f ｜ 出兵 %.1f 队 vs 敌方 %.1f 队" % [
		float(res.get("avg_player_hp_pct", 0.0)), float(res.get("avg_enemy_hp", 0.0)),
		float(res.get("avg_player_squads", 0.0)), float(res.get("avg_enemy_squads", 0.0))])
	print("队形：长枪在步兵身后的时间占比 %.1f%% ｜ 平均间距 %.1f cm（理想 90）" % [
		float(res.get("avg_pike_behind_rate", 0.0)) * 100.0, float(res.get("avg_pike_gap_cm", 0.0))])

	var counts: Dictionary = res.get("review_counts", {})
	var keys: Array = counts.keys()
	keys.sort_custom(func(a, b): return int(counts[a]) > int(counts[b]))
	var parts: Array[String] = []
	for k in keys:
		parts.append("%s %d" % [String(k), int(counts[k])])
	print("定性复盘分布：" + " ｜ ".join(parts))

	var samples: Array = res.get("samples", [])
	if not samples.is_empty():
		print("---------------------------------------------------------------")
		print("定性复盘样本：")
		for s in samples:
			var d: Dictionary = s
			print("  seed=%d ｜ %s ｜ 我方 %d / 敌方 %d ｜ 进攻 %d 队 / 防守 %d 队" % [
				int(d.get("seed", 0)), String(d.get("outcome_text", "")),
				int(d.get("player_hp", 0)), int(d.get("enemy_hp", 0)),
				int(d.get("attack_squads", 0)), int(d.get("defend_squads", 0))])
			for line in d.get("reviews", []):
				print("    - " + String(line))

	var sample_brief: Array = []
	for s in samples:
		var d: Dictionary = s
		sample_brief.append({
			"seed": int(d.get("seed", 0)),
			"outcome": String(d.get("outcome", "")),
			"outcome_text": String(d.get("outcome_text", "")),
			"player_hp": int(d.get("player_hp", 0)),
			"enemy_hp": int(d.get("enemy_hp", 0)),
			"reviews": d.get("reviews", []),
			"review_codes": d.get("review_codes", []),
		})

	var summary := {
		"ok": true,
		"level": String(res.get("level", LEVEL_ID)),
		"level_name": String(res.get("level_name", "")),
		"games": int(res.get("games", 0)),
		"seed_base": seed_base,
		"wins": int(res.get("wins", 0)),
		"losses": int(res.get("losses", 0)),
		"draws": int(res.get("draws", 0)),
		"win_rate": float(res.get("win_rate", 0.0)),
		"avg_seconds": float(res.get("avg_seconds", 0.0)),
		"avg_player_hp_pct": float(res.get("avg_player_hp_pct", 0.0)),
		"avg_enemy_hp": float(res.get("avg_enemy_hp", 0.0)),
		"avg_player_squads": float(res.get("avg_player_squads", 0.0)),
		"avg_enemy_squads": float(res.get("avg_enemy_squads", 0.0)),
		"avg_pike_behind_rate": float(res.get("avg_pike_behind_rate", 0.0)),
		"avg_pike_gap_cm": float(res.get("avg_pike_gap_cm", 0.0)),
		"review_counts": counts,
		"samples": sample_brief,
	}
	print("SIM " + JSON.stringify(summary))
	quit(0)


func _outcome_en(s: String) -> String:
	if s == "win":
		return "WIN"
	if s == "lose":
		return "LOSE"
	if s == "draw":
		return "DRAW"
	return s


func _fail(msg: String) -> void:
	print("SIM FAIL " + msg)
	quit(1)
