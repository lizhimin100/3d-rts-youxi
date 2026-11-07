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
	_test_spacing()
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

	# 2026-11-03 2C-2：出击许可不再读军力比（设计文档 §3.6），
	# 所以"兵力落后 → 不许打"这条断言反过来：落后也放行，交给波次记录表去评估。
	var weak: bool = d._compute_allow_attack(_m({"army_ratio": 0.5, "my_army_value": 300.0}), 0.5)
	_ok("导演：兵力落后也给出击许可（已移除军力比依赖）", weak)
	var strong: bool = d._compute_allow_attack(_m({"army_ratio": 1.7, "army_food": 12.0}), 0.5)
	_ok("导演：占优时给出击许可", strong)
	var threatened: bool = d._compute_allow_attack(
		_m({"army_ratio": 1.7, "army_food": 12.0, "base_threat": 1.0}), 0.5)
	_ok("导演：家在挨打时收回出击许可", not threatened)
	# ★ 2026-11-07 玩家口径：「附近的野怪，副官能派兵打，为什么打敌人玩家却不能？」
	#   根因是 base_threat 把中立野怪也算进来了 → 一只豺狼人溜达到基地圈，这局就不出兵。
	#   现在战略层只看 war_threat（玩家对手）。
	var creep_only: bool = d._compute_allow_attack(
		_m({"base_threat": 3.0, "war_threat": 0.0}), 0.5)
	_ok("导演：只有野怪压家时**仍然出击**（野怪不该冻结进攻）", creep_only)
	var player_home: bool = d._compute_allow_attack(
		_m({"base_threat": 3.0, "war_threat": 2.0}), 0.5)
	_ok("导演：玩家压家时才收回出击许可", not player_home)


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

	# 2C-11 §5.1 实测记录：曾把观察窗 5 s -> 12 s 想容纳 dept=on 的仲裁时序，
	# 结果仍 owner=002（不是时序抖动，是 claim_ai 没落到队尾单位），已回退 5 s。
	# 也试过在自检开局补兵到 下限+6，反而让 dept=off 从 28/28 退化到 27/28，已回退。
	# 结论：C 组这条红与 normal_push_n 无关，2C-10 的归因漏了一层；本轮不美化。
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
	# 2C-2：保留金闸删除后，副官会把玩家的钱花到接近 0。
	# 这一步测的是"工地能不能落成"（审计的前置），不是财政 —— 所以测试自己补足建造费。
	# 不补的话会因"80 金不够一座农场"假失败，把运营线的正常行为当成 bug。
	Game.player_faction.gold = maxi(Game.player_faction.gold, 400)
	Game.player_faction.wood = maxi(Game.player_faction.wood, 200)
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
	# 2C-11 §5.1（用户拍 C：改测试，不改产品）：
	# 2C-10 里这组负对照走旧路径 _manage_waves → _wave_plan → normal_push_n，
	# 玩家现役 6 ≤ 防守下限 8 → normal_push_n(6,8)=0 → 一条命令都下不出去，
	# 于是「宽限到期交还副官」「副官给空闲部队下命令」两条恒红（dept=on 26/28）。
	# normal_push_n 是 2C-4 冻结的产品逻辑，一个字不动；这里只把**测试场景**
	# 的兵力补到 >= 下限+2，让常态出击规模真的 >0。只 print、不新增断言，
	# 保持 28 条口径不变。
	var floor_v: int = int(_adj._defense_floor())
	var need_army: int = floor_v + 2
	var army_before: int = int(_adj._army_units().size())
	var made: int = 0
	if army_before < need_army:
		var base_pos: Vector3 = RtsWorld.base_center(Game.player_faction)
		for i in range(need_army - army_before):
			var spawn_pos: Vector3 = base_pos + Vector3(20.0 + float(i) * 2.0, 0.0, 8.0)
			if Game.spawn_unit(Game.player_faction, &"footman", spawn_pos) != null:
				made += 1
	print("[2C-11] 负对照测试场景：下限=%d 现役 %d→%d（目标>=%d，造 %d 兵）；normal_push_n 源码未改" % [
		floor_v, army_before, int(_adj._army_units().size()), need_army, made])
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
	# 2C-2：这一步只测"副官会不会给自由单位下令"，不测状态机/骰子 ——
	# 把状态钉回试探、把侵略性骰子钉死，否则 45% 概率被随机数挡住（假失败）。
	_adj.posture["aggression"] = 1.0
	_adj.strat_state = "probe"
	_adj._waves_active.clear()
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
# F. 站位：驻防/留守必须散开（玩家口径：不要挤在一起、更不要挤在基地门口）
# ===========================================================================
func _test_spacing() -> void:
	var army: Array = _pick_units(20)
	if not _ok("站位：场上有 >= 8 个战斗单位可测", army.size() >= 8, "%d 个" % army.size()):
		return
	var center: Vector3 = RtsWorld.base_center(Game.player_faction)
	var pts: Array = _adj.call("_spread_targets", army, center, 7.0, 61)
	_ok("站位：散点数量与人数一致", pts.size() == army.size(),
		"%d / %d" % [pts.size(), army.size()])
	# 两两最近距离：按 gap=2.4m 算弧长，允许 standable_point 吸附吃掉 0.35m
	var min_d: float = 999.0
	var dup: int = 0
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			var d: float = (pts[i] as Vector3).distance_to(pts[j] as Vector3)
			min_d = minf(min_d, d)
			if d < 0.05:
				dup += 1
	_ok("站位：20 人散点最近间距 >= 2.0m（不叠在一起）", min_d >= 2.0,
		"最近 %.2fm" % min_d)
	_ok("站位：没有两个落点完全重合", dup == 0, "重合对 %d" % dup)
	# 落点必须在基地圈上（不是全压在基地中心）
	var near_center: int = 0
	for p in pts:
		if (p as Vector3).distance_to(center) < 3.0:
			near_center += 1
	_ok("站位：没有落点压在基地中心 3m 内（不堵门口）", near_center == 0,
		"压中心 %d 个" % near_center)


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
