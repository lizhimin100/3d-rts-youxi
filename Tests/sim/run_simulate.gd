extends SceneTree
## 职责：--simulate 的入口（纯 Model，无窗口）。
##
## 默认：**真小队攻防**（100 局）——
##   规划（ScriptedPlanner）→ 训练牌按建筑格子中心出整队 → 质心沿脊线 A* 推进 →
##   成员弹性槽位 → 6 步伤害结算 → 双 90 秒 → 胜率 / DPS / 寻路 / 阵型报告。
##
## 用法：godot --headless --path . --script Tests/sim/run_simulate.gd -- \
##          [--games=100] [--seed=1] [--level=<id>] [--out=<path>]
## 数据：Content/data/{units,combat,planning,levels,map_shells,player_layouts,enemy_encounters,squad}.json
## 输出：人读表格 + 3 个定性复盘样本 + 一行机器可读 `SIM {json}`；有错退出码 1。

const JsonFile := preload("res://Engine/util/json_file.gd")

const COMBAT_JSON := "res://Content/data/combat.json"
const UNITS_JSON := "res://Content/data/units.json"
const PLANNING_JSON := "res://Content/data/planning.json"
const LEVELS_JSON := "res://Content/data/levels.json"
const SHELLS_JSON := "res://Content/data/map_shells.json"
const LAYOUTS_JSON := "res://Content/data/player_layouts.json"
const ENCOUNTERS_JSON := "res://Content/data/enemy_encounters.json"
const SQUAD_JSON := "res://Content/data/squad.json"

## 有 assembly（底壳 + 布局卡 + 遭遇卡）的默认关卡
const DEFAULT_SQUAD_LEVEL := "level_asm_even_four__gnoll_press"

var _level_id := ""
var _out_path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for a0 in OS.get_cmdline_user_args():
		if a0.begins_with("--level="):
			_level_id = a0.substr(8)
		if a0.begins_with("--out="):
			_out_path = a0.substr(6)

	var games := 100
	var seed_base := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--games="):
			games = int(a.substr(8))
		if a.begins_with("--seed="):
			seed_base = int(a.substr(7))
	games = clampi(games, 1, 500)

	var bridge_sc := load("res://Game/adapters/bridge.gd")
	if bridge_sc == null:
		_fail("桥脚本加载失败")
		return
	var mdl: RefCounted = bridge_sc.call("get_bridge") as RefCounted
	if mdl == null:
		_fail("C# 内核没编译（ModelBridge 实例化失败）")
		return

	var units := JsonFile.read_dict(UNITS_JSON, {})
	var combat := JsonFile.read_dict(COMBAT_JSON, {})
	var planning := JsonFile.read_dict(PLANNING_JSON, {})
	var levels := JsonFile.read_dict(LEVELS_JSON, {})
	if units.is_empty() or combat.is_empty() or planning.is_empty() or levels.is_empty():
		_fail("Content/data 四张表读不全")
		return

	if _level_id.is_empty():
		_level_id = DEFAULT_SQUAD_LEVEL
	var shells := JsonFile.read_dict(SHELLS_JSON, {})
	var layouts := JsonFile.read_dict(LAYOUTS_JSON, {})
	var encounters := JsonFile.read_dict(ENCOUNTERS_JSON, {})
	var tuning := JsonFile.read_dict(SQUAD_JSON, {})
	if tuning.is_empty():
		tuning = {"zone_dps_per_squad": 18.0}

	var res: Dictionary = mdl.call("SquadSimulate",
		units, combat, planning, levels, shells, layouts, encounters, tuning,
		_level_id, games, seed_base)
	if not bool(res.get("ok", false)):
		var errs: Array = res.get("errors", [])
		print("  ✗ 小队推演错误：")
		for e in errs:
			print("    - " + str(e))
		_fail("；".join(errs) if not errs.is_empty() else "小队推演失败")
		return

	_print_squad_report(res, games, seed_base)
	var summary := _squad_summary(res, games, seed_base)
	print("SIM " + JSON.stringify(summary))
	_write_out(summary)
	quit(0)


# ===========================================================================
# 小队报告
# ===========================================================================
func _print_squad_report(res: Dictionary, games: int, seed_base: int) -> void:
	print("========== 真小队推演 · %s ==========" % String(res.get("level", _level_id)))
	print("战场：%s ｜ %d 局 ｜ 种子 %d..%d ｜ 每局两轮各 90s（轮末清场）" % [
		String(res.get("arena_name", res.get("arena", ""))), int(res.get("games", games)),
		seed_base, seed_base + games - 1])
	print("说明：训练牌 → 建筑格子 SquadSpawnAnchor 瞬间整队；质心沿脊线 A* 推进；成员弹性槽位；6 步结算。")
	print("------------------------------------------------------------------------------------------")
	print("%-4s %-6s %-5s %-13s %-10s %-9s %-8s %-7s %-6s %-4s %-5s %s" % [
		"idx", "seed", "res", "player_hp", "enemy_hp", "squads", "dmg", "dps/人", "zone", "卡住", "槽位", "reason"])

	var rows: Array = res.get("rows", [])
	for row in rows:
		var r: Dictionary = row
		print("%-4d %-6d %-5s %-13s %-10s %-9s %-8d %-7.2f %-6d %-4d %-5.2f %s" % [
			int(r.get("index", 0)), int(r.get("seed", 0)), _outcome_en(String(r.get("outcome", ""))),
			"%d (%d%%)" % [int(r.get("player_hp", 0)), int(r.get("player_hp_pct", 0))],
			str(int(r.get("enemy_hp", 0))),
			"%d/%d 亡%d" % [int(r.get("player_squads", 0)), int(r.get("enemy_squads", 0)),
				int(r.get("player_squads_lost", 0))],
			int(r.get("player_damage", 0)),
			float(r.get("dps_member", 0.0)),
			int(r.get("zone_max", 0)), int(r.get("stuck_events", 0)),
			float(r.get("slot_error", 0.0)),
			String(r.get("top_reason", "")),
		])

	print("------------------------------------------------------------------------------------------")
	print("汇总：胜 %d ｜ 负 %d ｜ 平 %d ｜ 胜率 %.1f%% ｜ 平均 %.1fs" % [
		int(res.get("wins", 0)), int(res.get("losses", 0)), int(res.get("draws", 0)),
		float(res.get("win_rate", 0.0)) * 100.0, float(res.get("avg_seconds", 0.0))])
	print("均值：我方基地剩 %.0f%% ｜ 敌基地剩 %.0f ｜ 出兵 %.1f vs %.1f 队 ｜ 整队阵亡 %.1f 队" % [
		float(res.get("avg_player_hp_pct", 0.0)), float(res.get("avg_enemy_hp", 0.0)),
		float(res.get("avg_player_squads", 0.0)), float(res.get("avg_enemy_squads", 0.0)),
		float(res.get("avg_player_squads_lost", 0.0))])
	print("输出：我方总伤害 %.0f ｜ 战斗 DPS %.1f ｜ 人均 DPS %.2f" % [
		float(res.get("avg_player_damage", 0.0)), float(res.get("avg_player_dps", 0.0)),
		float(res.get("avg_player_dps_per_member", 0.0))])
	print("寻路：平均路径 %.0f 游戏数值（直线比 %.2f）｜ 卡住脱困 %.1f 次/局 ｜ 槽位偏离 %.2f m" % [
		float(res.get("avg_path_length", 0.0)), float(res.get("avg_path_ratio", 0.0)),
		float(res.get("avg_stuck_events", 0.0)), float(res.get("avg_slot_error", 0.0))])

	print("------------------------------------------------------------------------------------------")
	print("DPS 明细（我方）：")
	print("%-24s %-6s %-7s %-10s %-10s %-10s %s" % ["兵种", "队数", "人数", "总伤害", "DPS/人", "DPS/队", "击杀/阵亡"])
	for row in res.get("player_dps_rows", []):
		var d: Dictionary = row
		print("%-24s %-6d %-7d %-10.0f %-10.2f %-10.2f %d/%d" % [
			String(d.get("unit_id", "")), int(d.get("squads", 0)), int(d.get("models", 0)),
			float(d.get("damage", 0.0)), float(d.get("dps_member", 0.0)), float(d.get("dps_squad", 0.0)),
			int(d.get("kills", 0)), int(d.get("losses", 0))])

	var counts: Dictionary = res.get("review_counts", {})
	var keys: Array = counts.keys()
	keys.sort_custom(func(a, b): return int(counts[a]) > int(counts[b]))
	var parts: Array[String] = []
	for k in keys:
		parts.append("%s %d" % [String(k), int(counts[k])])
	print("定性复盘分布：" + " ｜ ".join(parts))

	var samples: Array = res.get("samples", [])
	if not samples.is_empty():
		print("------------------------------------------------------------------------------------------")
		print("定性复盘样本：")
		for s in samples:
			var d: Dictionary = s
			print("  seed=%d ｜ %s ｜ 我方 %d / 敌方 %d ｜ 伤害 %.0f ｜ 进攻 %d 队 / 防守 %d 队" % [
				int(d.get("seed", 0)), String(d.get("outcome_text", "")),
				int(d.get("player_hp", 0)), int(d.get("enemy_hp", 0)),
				float(d.get("player_damage", 0.0)),
				int(d.get("attack_squads", 0)), int(d.get("defend_squads", 0))])
			for line in d.get("reviews", []):
				print("    - " + String(line))


func _squad_summary(res: Dictionary, games: int, seed_base: int) -> Dictionary:
	var samples_brief: Array = []
	for s in res.get("samples", []):
		var d: Dictionary = s
		samples_brief.append({
			"seed": int(d.get("seed", 0)),
			"outcome": String(d.get("outcome", "")),
			"outcome_text": String(d.get("outcome_text", "")),
			"player_hp": int(d.get("player_hp", 0)),
			"enemy_hp": int(d.get("enemy_hp", 0)),
			"player_damage": float(d.get("player_damage", 0.0)),
			"reviews": d.get("reviews", []),
			"review_codes": d.get("review_codes", []),
		})
	return {
		"ok": true,
		"mode": "squad",
		"level": String(res.get("level", _level_id)),
		"arena": String(res.get("arena", "")),
		"arena_name": String(res.get("arena_name", "")),
		"games": int(res.get("games", games)),
		"seed_base": int(res.get("seed_base", seed_base)),
		"wins": int(res.get("wins", 0)),
		"losses": int(res.get("losses", 0)),
		"draws": int(res.get("draws", 0)),
		"win_rate": float(res.get("win_rate", 0.0)),
		"avg_seconds": float(res.get("avg_seconds", 0.0)),
		"avg_player_hp_pct": float(res.get("avg_player_hp_pct", 0.0)),
		"avg_enemy_hp": float(res.get("avg_enemy_hp", 0.0)),
		"avg_player_squads": float(res.get("avg_player_squads", 0.0)),
		"avg_enemy_squads": float(res.get("avg_enemy_squads", 0.0)),
		"avg_player_squads_lost": float(res.get("avg_player_squads_lost", 0.0)),
		"avg_player_damage": float(res.get("avg_player_damage", 0.0)),
		"avg_player_dps": float(res.get("avg_player_dps", 0.0)),
		"avg_player_dps_per_member": float(res.get("avg_player_dps_per_member", 0.0)),
		"avg_path_length": float(res.get("avg_path_length", 0.0)),
		"avg_path_ratio": float(res.get("avg_path_ratio", 0.0)),
		"avg_stuck_events": float(res.get("avg_stuck_events", 0.0)),
		"avg_slot_error": float(res.get("avg_slot_error", 0.0)),
		"player_dps_rows": res.get("player_dps_rows", []),
		"review_counts": res.get("review_counts", {}),
		"samples": samples_brief,
	}


## 编辑器靠这个文件拿胜率：与 stdout 的 SIM 行同一份 summary。
func _write_out(summary: Dictionary) -> void:
	if _out_path.is_empty():
		return
	var abs_path := _out_path
	if abs_path.begins_with("res://") or abs_path.begins_with("user://"):
		abs_path = ProjectSettings.globalize_path(abs_path)
	var dir := abs_path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		print("SIM WARN cannot write " + abs_path)
		return
	f.store_string(JSON.stringify(summary) + "\n")
	f.close()


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
	_write_out({"ok": false, "error": msg, "level": _level_id})
	quit(1)
