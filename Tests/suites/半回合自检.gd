extends Node
## **半回合制自检**（短局专用）：--round-test
##
## 验证四件事（任何一条失败都退出码非 0）：
##   1. 开局停在 PLANNING，世界 `paused`；
##   2. 规划阶段右键移动 → 入计划（不立刻执行），并自动生成小队；
##   3. 开始执行 → 解冻、计划清空、单位真的走起来；
##   4. 结束执行 → 重新冻结；成员死亡后小队仍存在（人数减少）；
##   5. **规划阶段界面**（2026-11-15 重构）：只在规划阶段出现、副官开关收起、
##      部署三键可点、人口"下单即占"、回合结束取消未完成训练（不退 CP）；
##   6. **部署输入状态机**：进入进攻模式 → 预览跟随 → 取消归零。
##
## 常量用 preload 取（`--round-test` 里不要裸写 class_name / 猜魔法数字）。

const WAR := preload("res://Game/ai/战区指令.gd")

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
	_ok(Game.phase == RtsConst.Phase.PLANNING, "开局在规划阶段")
	_ok(get_tree().paused, "规划阶段世界已暂停")

	var sel: Node = get_parent().get("selection_system") as Node
	var cmd: Node = get_parent().get("command_system") as Node
	var rc: Node = Game.round_control
	_ok(sel != null, "选择系统存在")
	_ok(cmd != null, "指令系统存在")
	_ok(rc != null, "回合控制器存在")
	if sel == null or cmd == null or rc == null:
		_finish()
		return
	# 隔离：副官会在执行阶段自己排训练/盖房，会把"队列条数/CP 余额"这类断言搅乱。
	# 本自检验的是阶段机制，不是 AI 行为，所以先把它关掉。
	var adj0 := get_tree().get_first_node_in_group("adjutant")
	if adj0 != null and adj0.has_method("set_enabled"):
		adj0.call("set_enabled", false)

	# --- CP / 规划阶段生产冻结 ---
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
		_ok(queued, "规划阶段能排队训练")
		_ok(pf.cp < cp0 - 0.01, "训练扣的是 CP（%.1f → %.1f）" % [cp0, pf.cp])
		await get_tree().create_timer(0.35).timeout
		_ok(absf(float(barracks.train_progress)) < 0.001, "规划阶段训练计时冻结")
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

	# --- 人口口径（2026-11-15）：下单即占，不再有"预留"这层概念 ---
	var used0: int = pf.food_committed()
	var queued2: bool = bool(barracks.call("queue_train", &"footman"))
	_ok(queued2, "能再次排队训练（人口口径）")
	if queued2:
		_ok(pf.food_committed() == used0 + Cfg.unit(&"footman").food_cost,
				"下单立刻计入已用人口（%d → %d）" % [used0, pf.food_committed()])
		barracks.call("cancel_train_at", 0)
		_ok(pf.food_committed() == used0, "取消训练后已用人口回落（%d）" % pf.food_committed())

	# --- 规划阶段界面：只在规划阶段出现 ---
	var hud: Node = get_parent().get_node_or_null("界面")
	_ok(hud != null, "HUD 存在")
	if hud != null:
		await get_tree().create_timer(0.35).timeout
		var ph: Variant = hud.get("_planning_hud")
		_ok(ph != null and (ph as CanvasItem).visible, "规划阶段界面已显示")
		var stats: Variant = hud.get("_stats_panel")
		_ok(stats != null and not (stats as CanvasItem).visible, "规划阶段顶部资源条已让位")
		var adj: Variant = hud.get("_adj_btn")
		_ok(adj == null or not (adj as CanvasItem).visible, "规划阶段副官开关已隐藏")
		var hit: Variant = hud.get("_planning_hit")
		_ok(hit is Array and (hit as Array).size() >= 4, "规划界面登记了鼠标命中区域")

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
	_ok(int(cmd.call("planned_count")) == 1, "规划阶段移动已入计划")
	_ok(Game.squads != null and int(Game.squads.call("count")) >= 1, "已生成小队")
	var sq = Game.squads.call("find_by_member", foots[0])
	_ok(sq != null, "单位能找回所属小队")
	if sq != null:
		_ok(int(sq.call("alive_count")) == 2, "小队成员数为 2")
		_ok(int(sq.get("stance")) == RtsConst.Order.MOVE, "小队记录了移动意图")

	# --- 部署（进攻/防守/占据）：三条计划都入队，且小队记下对应意图 ---
	_ok(bool(cmd.call("queue_defend", base + Vector3(9.0, 0.0, 0.0), 10.0)), "防守部署入计划")
	_ok(bool(cmd.call("queue_capture", base + Vector3(-9.0, 0.0, 0.0))), "占据部署入计划")
	_ok(int(cmd.call("planned_count")) == 3, "三条计划都在（移动/防守/占据）")
	var recs: Array = cmd.call("planned_records")
	_ok(String(recs[1].get("text", "")).begins_with("防守"), "第 2 条是防守计划")
	_ok(String(recs[2].get("text", "")) == "占据", "第 3 条是占据计划")
	if sq != null:
		_ok(int(sq.get("stance")) == RtsConst.Order.CAPTURE, "小队记录了占据意图")
	# 部署按钮：选中步兵后应该出现在规划操作面板里。
	# 规划界面是 8Hz 刷新（0.12s）＋按签名重建，选完要等一拍才会换形态。
	await get_tree().create_timer(0.3).timeout
	if hud != null:
		var dep: Node = hud.find_child("部署_进攻", true, false)
		_ok(dep != null and (dep as CanvasItem).is_visible_in_tree(), "规划面板出现「进攻」部署按钮")
		var endb: Node = hud.find_child("规划结束", true, false)
		_ok(endb != null and (endb as CanvasItem).is_visible_in_tree(), "规划面板出现「规划结束」按钮")

	# --- 部署输入状态机（二段式：按钮 → 地图落点） ---
	var di: Node = get_parent().get_node_or_null("部署输入")
	_ok(di != null, "部署输入节点已挂载")
	if di != null:
		di.call("enter", WAR.ATTACK)
		await get_tree().create_timer(0.15).timeout
		_ok(int(di.call("mode")) == WAR.ATTACK, "进入「进攻」部署模式")
		var pv: Dictionary = di.call("preview")
		_ok(int(pv.get("mode", 0)) == WAR.ATTACK, "地图预览跟随部署模式")
		di.call("cancel")
		_ok(int(di.call("mode")) == 0, "取消部署后模式归零")

	# 规划阶段不应真的移动，日夜/据点计时也不应走
	var dn_t0: float = float(Game.day_night.get("t")) if Game.day_night != null else 0.0
	var sp_c0: float = float(Game.strongpoint.get("_countdown")) if Game.strongpoint != null else 0.0
	await get_tree().create_timer(0.35).timeout
	_ok(foots[0].global_position.distance_to(before) < 0.6, "规划阶段单位没有移动")
	if Game.day_night != null:
		_ok(absf(float(Game.day_night.get("t")) - dn_t0) < 0.001, "规划阶段日夜计时冻结")
	if Game.strongpoint != null:
		_ok(absf(float(Game.strongpoint.get("_countdown")) - sp_c0) < 0.001, "规划阶段据点倒计时冻结")

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

	if hud != null:
		await get_tree().create_timer(0.2).timeout
		var ph2: Variant = hud.get("_planning_hud")
		_ok(ph2 == null or not (ph2 as CanvasItem).visible, "执行阶段规划界面已收起")
		var stats2: Variant = hud.get("_stats_panel")
		_ok(stats2 != null and (stats2 as CanvasItem).visible, "执行阶段顶部资源条恢复")

	# 回合结束：未完成的训练作废（不退 CP）——规划结束按钮上那句警告就是这条规则
	var cp_before: float = pf.cp
	var q3: bool = bool(barracks.call("queue_train", &"footman"))
	_ok(q3, "执行阶段能排队训练")
	rc.call("end_execution", "test")
	_ok(Game.phase == RtsConst.Phase.PLANNING, "结束执行回到规划阶段")
	_ok(get_tree().paused, "结束执行后世界重新暂停")
	if q3:
		_ok(barracks.train_queue.is_empty(), "回合结束未完成的训练已取消")
		_ok(absf(pf.cp - (cp_before - float(Cfg.unit(&"footman").cp_cost))) < 0.01,
				"取消不退 CP（%.1f）" % pf.cp)

	# 第二次执行：回合计数递增（波次没清完时只加回合，不叠兵）
	var began2: bool = bool(rc.call("begin_execution"))
	_ok(began2 and int(rc.get("round_index")) == 2, "第二次执行回合计数为 2")
	rc.call("end_execution", "test2")
	_ok(Game.is_planning(), "第二次结束回规划阶段")

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
