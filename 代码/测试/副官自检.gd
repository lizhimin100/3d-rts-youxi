extends Node
## **副官 / 控制权自检**（验收用，不是玩法代码）。
##
## 启用：godot --headless --fixed-fps 60 --path . -- --adjutant-test
##       （主场景检测到这个参数时把本节点挂到场上，跑完打印 ADJUTANT {json} 并退出）
##
## 五组断言，逐条对应这一轮的改造目标：
##   A. 战略导演：计划条件求值 / 8 秒滞回 / 紧急计划立即切换 / 出击许可
##   B. 玩家下令 → 单位进入"玩家命令组"，副官**一条命令都不能发**；
##   C. 命令结束 → 进 5 秒宽限 → 到期才交还副官；
##   D. STOP 保护 30 秒、HOLD 无期限；
##   E. 反愚蠢审计：工地停在 10% 时，真的会派人回去收尾。
##
## 另加一条**反向对照**：没被玩家点名的部队，副官必须照常指挥 ——
## 否则"不抢控制权"可以靠"AI 干脆不干活"骗过测试，那是最糟的绿色。

var _checks: Array = []
var _cmd: Node = null
var _adj: Node = null
var _selected: Array = []


func _ready() -> void:
	Engine.time_scale = 2.0
	_run.call_deferred()


func _run() -> void:
	await _wait(0.6)
	_cmd = get_parent().get_node_or_null("指令系统")
	_adj = get_parent().get_node_or_null("副官")
	if not _ok("场景就位（指令系统 + 副官）", _cmd != null and _adj != null,
			"指令系统=%s 副官=%s" % [str(_cmd != null), str(_adj != null)]):
		_finish()
		return

	_test_director()
	await _test_ownership_move()
	await _test_grace()
	await _test_stop_hold()
	await _test_sanity_stalled_site()
	await _test_negative_control()
	_finish()


# ===========================================================================
# A. 战略导演
# ===========================================================================

func _test_director() -> void:
	var d = load("res://代码/ai/战略导演.gd").new()
	var plans: Array = load("res://代码/配置/战略计划.gd").call("build")
	d.setup(plans, 0)

	var first: String = String(d._select(_m(), 0.0).get("id", ""))
	_ok("导演：开局选 open_economy", first == "open_economy", first)

	var stuck: String = String(d._select(_m({"time": 200.0}), 1.0).get("id", ""))
	_ok("导演：8 秒内不换计划（滞回）", stuck == "open_economy", stuck)
	# 注意造数据：time>150 + workers>=8 命中 tech_up，但金币必须 <320
	# 否则 expand_econ（优先级 40）会先命中，测的就不是 tech_up 了
	var later: String = String(d._select(_m({"time": 200.0, "workers": 9.0, "gold": 100.0}), 20.0).get("id", ""))
	_ok("导演：超过 8 秒才切到 tech_up", later == "tech_up", later)

	var emg: String = String(d._select(_m({"time": 200.0, "base_threat": 2.0}), 21.0).get("id", ""))
	_ok("导演：基地被压立即切 emergency_defense", emg == "emergency_defense", emg)

	var weak: bool = d._compute_allow_attack(_m({"army_ratio": 0.5, "my_army_value": 300.0}), 0.5)
	_ok("导演：兵力落后时不给出击许可", not weak)
	var strong: bool = d._compute_allow_attack(_m({"army_ratio": 1.7, "army_food": 12.0}), 0.5)
	_ok("导演：占优时给出击许可", strong)
	var threatened: bool = d._compute_allow_attack(
		_m({"army_ratio": 1.7, "army_food": 12.0, "base_threat": 1.0}), 0.5)
	_ok("导演：家在挨打时收回出击许可", not threatened)


func _m(over: Dictionary = {}) -> Dictionary:
	var m := {
		"time": 10.0, "gold": 100.0, "wood": 50.0, "workers": 5.0, "idle_workers": 0.0,
		"army_count": 5.0, "army_food": 10.0, "army_ratio": 1.0, "my_army_value": 400.0,
		"food_used": 10.0, "food_cap": 20.0, "food_headroom": 10.0, "base_threat": 0.0,
		"under_attack": 0.0, "buildings": 4.0, "enemy_static_defense": 0.0, "gold_float": 0.0,
	}
	for k in over.keys():
		m[k] = over[k]
	return m


# ===========================================================================
# B. 玩家下令 → 副官不许碰
# ===========================================================================

func _test_ownership_move() -> void:
	_selected = _pick_units(3)
	if not _ok("B 组：场上至少有 3 个玩家战斗单位", _selected.size() >= 3,
			"%d 个" % _selected.size()):
		return
	var base: Vector3 = RtsWorld.base_center(Game.player_faction)
	var far: Vector3 = base + Vector3(40.0, 0.0, 12.0)
	_cmd.call("_issue_move", _selected, far)
	await _wait(0.3)

	var all_active: bool = true
	var all_protected: bool = true
	for u in _selected:
		if int(u.order_owner) != 1:
			all_active = false
		if Game.control == null or not Game.control.is_protected(u):
			all_protected = false
	_ok("B 组：玩家下令后单位归属 = PLAYER_ACTIVE(1)", all_active)
	_ok("B 组：玩家下令后单位受保护", all_protected)

	var before_order: Array = []
	for u in _selected:
		before_order.append(int(u.order))
	_adj.posture["allow_attack"] = true
	_adj._next_wave_at = -1.0
	_adj._sched.begin(Game.elapsed)
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_adj._manage_waves(diff)
	_adj._sched.flush()
	await _wait(0.1)

	var untouched: bool = true
	var detail: String = ""
	for i in range(_selected.size()):
		var u = _selected[i]
		if int(u.order_owner) != 1 or int(u.order) != int(before_order[i]):
			untouched = false
			detail += "单位%d owner=%d order=%d；" % [i, int(u.order_owner), int(u.order)]
	_ok("B 组：副官试图推进时没有改玩家单位的命令", untouched, detail)


# ===========================================================================
# C. 命令结束 → 宽限 → 交还
# ===========================================================================

func _test_grace() -> void:
	var t: float = 0.0
	var all_idle: bool = false
	while t < 25.0:
		await _wait(0.5)
		t += 0.5
		all_idle = true
		for u in _selected:
			if not is_instance_valid(u) or not u.is_alive():
				continue
			if int(u.order) != RtsConst.Order.NONE:
				all_idle = false
				break
		if all_idle:
			break
	if not _ok("C 组：这队人最终回到 idle（命令结束）", all_idle, "用了 %.1fs" % t):
		return

	var grace_ok: bool = true
	for u in _selected:
		if not is_instance_valid(u) or not u.is_alive():
			continue
		if int(u.order_owner) != 2:
			grace_ok = false
	_ok("C 组：命令结束后进入 PLAYER_GRACE(2)", grace_ok, "owner=%s" % _owners(_selected))

	await _wait(2.0)
	var still: bool = true
	for u in _selected:
		if not is_instance_valid(u) or not u.is_alive():
			continue
		if Game.control == null or not Game.control.is_protected(u):
			still = false
	_ok("C 组：宽限 2 秒时仍在保护中", still, "owner=%s" % _owners(_selected))

	await _wait(5.0)
	var handed: bool = true
	for u in _selected:
		if not is_instance_valid(u) or not u.is_alive():
			continue
		if int(u.order_owner) != 0:
			handed = false
	_ok("C 组：宽限到期后交还副官（owner=0）", handed, "owner=%s" % _owners(_selected))


# ===========================================================================
# D. STOP 30 秒 / HOLD 无期限
# ===========================================================================

func _test_stop_hold() -> void:
	var units: Array = _pick_units(2)
	if not _ok("D 组：有 2 个玩家战斗单位", units.size() >= 2):
		return
	_select_units(units)
	_cmd.call("_issue_simple", RtsConst.Order.STOP, "停止")
	await _wait(0.3)
	var hold_owner: bool = true
	for u in units:
		if int(u.order_owner) != 3:
			hold_owner = false
	_ok("D 组：STOP 后归属 = PLAYER_HOLDING(3)", hold_owner, "owner=%s" % _owners(units))

	await _wait(8.0)
	var still: bool = true
	for u in units:
		if Game.control == null or not Game.control.is_protected(u):
			still = false
	_ok("D 组：STOP 后 8 秒仍在保护（旧 TTL 这时已经放行了）", still)

	_select_units(units)
	_cmd.call("_issue_simple", RtsConst.Order.HOLD, "保持")
	await _wait(0.3)
	var hold_forever: bool = true
	for u in units:
		if int(u.order_owner) != 3 or float(u.order_until) > 0.0:
			hold_forever = false
	_ok("D 组：HOLD 后归属 = HOLDING 且无到期时间", hold_forever, "until=%s" % _untils(units))


# ===========================================================================
# E. 反愚蠢：工地停滞
# ===========================================================================

func _test_sanity_stalled_site() -> void:
	var farm: UnitDef = Cfg.unit(&"farm")
	var builder: RtsUnit = _pick_idle_worker()
	if not _ok("E 组：有一个能用的农民", builder != null and farm != null):
		return
	var spot: Vector3 = _adj._find_build_spot(farm.footprint)
	if not _ok("E 组：基地附近有合法空位", spot != Vector3.INF):
		return
	var site: Node3D = builder.order_build(farm, spot, _adj._build_yaw_at(spot))
	if not _ok("E 组：工地落成", site != null and site is RtsBuilding):
		return
	builder.order_stop()
	await _wait(0.4)
	var prog0: float = float(site.get("progress"))
	_adj._sanity._seen_progress[site.get_instance_id()] = [prog0, Game.elapsed - 10.0]
	var before: int = int(_adj._sanity.fixes.get("construction_stalled", 0))
	var ctx: Dictionary = _adj._build_ctx(Cfg.difficulty(Game.difficulty_index), Game.elapsed)
	_adj._sanity.update(ctx)
	await _wait(0.2)
	var after: int = int(_adj._sanity.fixes.get("construction_stalled", 0))
	_ok("E 组：审计立案 construction_stalled",
		int(_adj._sanity.counts.get("construction_stalled", 0)) > 0,
		"episodes=%d" % int(_adj._sanity.counts.get("construction_stalled", 0)))
	_ok("E 组：真的派人回去收尾", after > before, "fixes %d → %d" % [before, after])
	var joined: bool = false
	for u in Game.player_faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		if int(u.order) == RtsConst.Order.BUILD and u.get("_build_site") == site:
			joined = true
			break
	_ok("E 组：有农民接手了这块工地（order=BUILD）", joined)


# ===========================================================================
# 反向对照：副官对**没被点名**的单位必须照常下令
# ===========================================================================

func _test_negative_control() -> void:
	var free_units: Array = []
	for u in Game.player_faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive() or u.def == null:
			continue
		if RtsWorld.is_worker_def(u.def):
			continue
		if Game.control != null and Game.control.is_protected(u):
			continue
		free_units.append(u)
	if not _ok("对照：场上有未被玩家接管的战斗单位", not free_units.is_empty(),
			"%d 个" % free_units.size()):
		return
	var target = free_units[0]
	target.order_stop()
	_adj.posture["allow_attack"] = true
	_adj._next_wave_at = -1.0
	_adj._sched.begin(Game.elapsed)
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_adj._manage_waves(diff)
	_adj._sched.flush()
	await _wait(0.2)
	_ok("对照：副官确实给空闲部队下了命令",
		int(target.order) == RtsConst.Order.ATTACK_MOVE or int(target.order) == RtsConst.Order.MOVE,
		"order=%d owner=%d" % [int(target.order), int(target.order_owner)])


# ===========================================================================
# 工具
# ===========================================================================

func _ok(name: String, cond: bool, detail: String = "") -> bool:
	_checks.append({"name": name, "ok": cond, "detail": detail})
	var tail: String = ("  —— " + detail) if detail != "" else ""
	print("%s %s%s" % ["[PASS]" if cond else "[FAIL]", name, tail])
	return cond


func _pick_units(n: int) -> Array:
	var out: Array = []
	if Game.player_faction == null:
		return out
	for u in Game.player_faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive() or u.def == null:
			continue
		if RtsWorld.is_worker_def(u.def):
			continue
		if u.def.kind != RtsConst.Kind.UNIT:
			continue
		out.append(u)
		if out.size() >= n:
			break
	return out


func _pick_idle_worker() -> RtsUnit:
	if Game.player_faction == null:
		return null
	for u in Game.player_faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive() or u.def == null:
			continue
		if not RtsWorld.is_worker_def(u.def):
			continue
		if Game.control != null and Game.control.is_protected(u):
			continue
		return u
	return null


func _select_units(units: Array) -> void:
	var sel: Node = get_parent().get_node_or_null("选择系统")
	if sel == null:
		return
	if sel.has_method("select_units"):
		sel.call("select_units", units)


func _owners(units: Array) -> String:
	var s: String = ""
	for u in units:
		if is_instance_valid(u):
			s += str(int(u.order_owner))
		else:
			s += "x"
	return s


func _untils(units: Array) -> String:
	var s: String = ""
	for u in units:
		if is_instance_valid(u):
			s += "%.1f " % float(u.order_until)
	return s


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _finish() -> void:
	var passed: int = 0
	var failed: int = 0
	for c in _checks:
		if bool(c["ok"]):
			passed += 1
		else:
			failed += 1
	var ok: bool = failed == 0
	print("ADJUTANT " + JSON.stringify({
		"通过": passed, "失败": failed, "结果": "通过" if ok else "失败",
		"检查": _checks,
	}))
	await _wait(0.2)
	get_tree().quit(0 if ok else 1)
