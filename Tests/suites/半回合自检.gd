extends Node
## **半回合制自检**（短局专用）：--round-test
##
## 验证四件事（任何一条失败都退出码非 0）：
##   1. 开局停在 PREPARE，世界 `paused`；
##   2. 准备阶段右键移动 → 入计划（不立刻执行），并自动生成小队；
##   3. 开始执行 → 解冻、计划清空、单位真的走起来；
##   4. 结束执行 → 重新冻结；成员死亡后小队仍存在（人数减少）。

var _fails: int = 0
var _passes: int = 0


func _ready() -> void:
	call_deferred("_run")


func _ok(cond: bool, msg: String) -> void:
	if cond:
		_passes += 1
		print("[ROUND] PASS ", msg)
	else:
		_fails += 1
		push_error("[ROUND] FAIL " + msg)
		print("[ROUND] FAIL ", msg)


func _run() -> void:
	await get_tree().process_frame
	_ok(Game.short_match, "短局模式已开启")
	_ok(Game.phase == RtsConst.Phase.PREPARE, "开局在 PREPARE")
	_ok(get_tree().paused, "准备阶段世界已暂停")

	var sel: Node = get_parent().get("selection_system") as Node
	var cmd: Node = get_parent().get("command_system") as Node
	var rc: Node = Game.round_control
	_ok(sel != null, "选择系统存在")
	_ok(cmd != null, "指令系统存在")
	_ok(rc != null, "回合控制器存在")
	if sel == null or cmd == null or rc == null:
		_finish()
		return

	# --- CP / 准备阶段生产冻结 ---
	var pf: RtsFaction = Game.player_faction
	_ok(pf.cp_cap >= 1.0, "CP 上限已装配")
	_ok(Cfg.unit(&"footman").cp_cost > 0, "步兵有 CP 成本（%d）" % Cfg.unit(&"footman").cp_cost)
	var barracks: RtsBuilding = null
	for b in pf.buildings:
		if b != null and is_instance_valid(b) and b.is_alive() and b.def != null \
				and b.def.id == &"barracks" and b.is_constructed:
			barracks = b
			break
	_ok(barracks != null, "找到已完工兵营")
	if barracks != null:
		var cp0: float = pf.cp
		var queued: bool = bool(barracks.call("queue_train", &"footman"))
		_ok(queued, "准备阶段能排队训练")
		_ok(pf.cp < cp0 - 0.01, "训练扣的是 CP（%.1f → %.1f）" % [cp0, pf.cp])
		await get_tree().create_timer(0.35).timeout
		_ok(absf(float(barracks.train_progress)) < 0.001, "准备阶段训练计时冻结")
		barracks.call("cancel_train_at", 0)
		_ok(absf(pf.cp - cp0) < 0.01, "取消训练退还 CP（%.1f）" % pf.cp)

	# 建造也走同一套 CP 支付/退款
	var farm_def: UnitDef = Cfg.unit(&"farm")
	_ok(farm_def != null and farm_def.cp_cost > 0, "农场有 CP 成本（%d）" % (farm_def.cp_cost if farm_def != null else -1))
	if farm_def != null:
		var cp1: float = pf.cp
		var paid_build: bool = bool(Game.pay(pf, &"farm"))
		_ok(paid_build and pf.cp < cp1 - 0.01, "建造扣的是 CP（%.1f → %.1f）" % [cp1, pf.cp])
		Game.refund(pf, &"farm")
		_ok(absf(pf.cp - cp1) < 0.01, "取消建造退还 CP（%.1f）" % pf.cp)

	# 找两个玩家步兵
	var foots: Array = []
	for u in Game.player_faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		if u.def != null and u.def.id == &"footman":
			foots.append(u)
	_ok(foots.size() >= 2, "至少有两个步兵（实际 %d）" % foots.size())
	if foots.size() < 2:
		_finish()
		return

	sel.call("select_units", [foots[0], foots[1]])
	_ok(sel.call("selected_units").size() == 2, "选中两个步兵")
	# M2：控制组编组 / 召回
	sel.call("_assign_group", 1)
	sel.call("clear")
	_ok(sel.call("selected_units").is_empty(), "清空选择")
	sel.call("_recall_group", 1)
	_ok(sel.call("selected_units").size() == 2, "控制组 1 召回两个步兵")

	var base: Vector3 = RtsWorld.base_center(Game.player_faction)
	var before: Vector3 = foots[0].global_position
	cmd.call("queue_move", base + Vector3(7.0, 0.0, 0.0))
	_ok(int(cmd.call("planned_count")) == 1, "准备阶段移动已入计划")
	_ok(Game.squads != null and int(Game.squads.call("count")) >= 1, "已生成小队")
	var sq = Game.squads.call("find_by_member", foots[0])
	_ok(sq != null, "单位能找回所属小队")
	if sq != null:
		_ok(int(sq.call("alive_count")) == 2, "小队成员数为 2")
		_ok(int(sq.get("stance")) == RtsConst.Order.MOVE, "小队记录了移动意图")

	# 准备阶段不应真的移动，日夜/据点计时也不应走
	var dn_t0: float = float(Game.day_night.get("t")) if Game.day_night != null else 0.0
	var sp_c0: float = float(Game.strongpoint.get("_countdown")) if Game.strongpoint != null else 0.0
	await get_tree().create_timer(0.35).timeout
	_ok(foots[0].global_position.distance_to(before) < 0.6, "准备阶段单位没有移动")
	if Game.day_night != null:
		_ok(absf(float(Game.day_night.get("t")) - dn_t0) < 0.001, "准备阶段日夜计时冻结")
	if Game.strongpoint != null:
		_ok(absf(float(Game.strongpoint.get("_countdown")) - sp_c0) < 0.001, "准备阶段据点倒计时冻结")

	var began: bool = bool(rc.call("begin_execution"))
	_ok(began, "开始执行成功")
	_ok(Game.phase == RtsConst.Phase.RUNNING, "阶段切到 RUNNING")
	_ok(not get_tree().paused, "执行阶段世界已解冻")
	_ok(int(cmd.call("planned_count")) == 0, "计划已清空")
	_ok(int(rc.get("round_index")) == 1, "回合计数为 1")
	var wave_arr: Variant = rc.get("_wave_units")
	_ok(wave_arr is Array and (wave_arr as Array).size() > 0, "执行阶段生成了脚本波次")

	await get_tree().create_timer(1.2).timeout
	var moved: float = foots[0].global_position.distance_to(before)
	_ok(moved > 0.5, "执行阶段单位真的移动了（%.2f m）" % moved)

	rc.call("end_execution", "test")
	_ok(Game.phase == RtsConst.Phase.PREPARE, "结束执行回到 PREPARE")
	_ok(get_tree().paused, "结束执行后世界重新暂停")

	# 第二次执行：回合计数递增（波次没清完时只加回合，不叠兵）
	var began2: bool = bool(rc.call("begin_execution"))
	_ok(began2 and int(rc.get("round_index")) == 2, "第二次执行回合计数为 2")
	rc.call("end_execution", "test2")
	_ok(Game.is_prepare(), "第二次结束回准备")

	# 成员死亡，小队继续存在（不做士气）
	foots[1].take_damage(99999.0, 0, null)
	await get_tree().create_timer(0.15).timeout
	var sq2 = Game.squads.call("find_by_member", foots[0])
	_ok(sq2 != null, "减员后小队仍存在")
	if sq2 != null:
		_ok(int(sq2.call("alive_count")) == 1, "减员后小队人数为 1")

	_finish()


func _finish() -> void:
	print("ROUNDTEST 通过 %d / 失败 %d" % [_passes, _fails])
	print("ROUNDTEST PASS" if _fails == 0 else "ROUNDTEST FAIL")
	get_tree().quit(1 if _fails > 0 else 0)
