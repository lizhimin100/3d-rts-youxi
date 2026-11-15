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
	# --- 规划沙盘第三版（2026-11-15）：锚点=实际大本营 / 只画有建筑的阵营 / 藏模型 ---
	var sandbox: Node = get_tree().get_first_node_in_group("planning_sandbox")
	_ok(sandbox != null, "规划沙盘节点存在")
	var town: RtsBuilding = null
	for b in pf.buildings:
		if b != null and is_instance_valid(b) and b is RtsBuilding and b.def != null \
				and b.def.is_dropoff and b.def.dropoff_kinds.is_empty() and b.def.food_provided > 0:
			town = b
			break
	_ok(town != null, "找到玩家大本营")
	if town != null:
		_ok(RtsWorld.base_center(pf).distance_to(town.global_position) < 3.0,
				"基地锚点 = 实际大本营（不是地图槽位出生点）")
		_ok(not town.visible, "规划阶段隐藏 3D 建筑模型")
	if sandbox != null:
		var fis: Array = sandbox.call("faction_items")
		var expected: int = 0
		for f in Game.factions:
			var has_b: bool = false
			for b in f.buildings:
				if b != null and is_instance_valid(b) and b.is_alive():
					has_b = true
					break
			if has_b:
				expected += 1
		_ok(fis.size() == expected, "势力范围只画有建筑的阵营（%d/%d）" % [fis.size(), Game.factions.size()])
		var anchored: bool = false
		for it in fis:
			if it.get("faction", null) == pf:
				var a: Vector3 = it.get("anchor", Vector3.ZERO)
				anchored = town != null and a.distance_to(town.global_position) < 3.0
		_ok(anchored, "玩家领地锚点 = 实际大本营")
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
		# 2026-11-15：一次下单 = 一支小队，占的人口是卡上的 pop_cost（不是人头）。
		_ok(pf.food_committed() == used0 + Cfg.unit(&"footman").pop_cost,
				"下单立刻计入已用人口（%d → %d）" % [used0, pf.food_committed()])
		barracks.call("cancel_train_at", 0)
		_ok(pf.food_committed() == used0, "取消训练后已用人口回落（%d）" % pf.food_committed())

	# --- 小队生产：一次训练 = 一小队（人数/人口来自卡，2026-11-15） ---
	var fd: UnitDef = Cfg.unit(&"footman")
	_ok(fd != null and int(fd.squad_size) == 5 and int(fd.pop_cost) == 8,
			"步兵卡：5 人一队 / 占 8 人口")
	_ok(Cfg.unit(&"peasant").squad_size == 4 and Cfg.unit(&"archer").squad_size == 4,
			"农民/弩兵卡：4 人一队")
	if fd != null and barracks != null:
		var before_units: int = pf.count_units(&"footman")
		var before_pop: int = pf.food_used()
		barracks.set("train_queue", [&"footman"])
		barracks.set("train_progress", 1.0)
		barracks.call("_tick_train", 0.0)
		await get_tree().create_timer(0.1).timeout
		var after_units: int = pf.count_units(&"footman")
		_ok(after_units == before_units + int(fd.squad_size),
				"训练一次真的出 %d 人（%d → %d）" % [int(fd.squad_size), before_units, after_units])
		var grown: int = pf.food_used() - before_pop
		_ok(grown == int(fd.pop_cost), "小队人口按队算（+%d，不是按人头）" % grown)
		var squad_ok: bool = false
		for sq in Game.squads.call("all"):
			if sq != null and int(sq.call("alive_count")) >= int(fd.squad_size):
				squad_ok = true
		_ok(squad_ok, "新出的兵编成一支小队")
	_ok(absf(float(rc.call("execution_total")) - 180.0) < 0.1,
			"执行阶段时长 = 3 分钟（%.0f 秒）" % float(rc.call("execution_total")))
	# 人口超限时，0 人口的建筑（农场/大本营）仍然能下 —— 否则会被永久卡死
	var keep_commits: Array = pf.squad_commits.duplicate()
	pf.squad_commits.append({"pop": 9999, "members": [pf.units[0]], "squad_id": 0})
	_ok(bool(pf.has_food(0)), "人口超限：0 人口建筑仍可下单")
	_ok(not bool(pf.has_food(1)), "人口超限：1 人口单位被拦下")
	pf.squad_commits = keep_commits

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
		# --- 兵牌可点击（2026-11-15 玩家报"点兵牌/建筑牌没反应"） ---
		var pmap: Variant = hud.get("_planning_map")
		_ok(pmap != null and int(pmap.call("token_count")) > 0, "规划地图层登记了可点击兵牌")
		if pmap != null:
			var brect: Rect2 = pmap.call("token_rect", "building", true)
			_ok(brect.size.x > 1.0, "有可点击的己方建筑牌")
			if brect.size.x > 1.0:
				var picked: bool = bool(hud.call("select_planning_token", brect.get_center()))
				_ok(picked, "点建筑牌能选中建筑")
				await get_tree().create_timer(0.2).timeout
				var ph3: Variant = hud.get("_planning_hud")
				var mode_b: int = int(ph3.get("_act_mode")) if ph3 != null else -1
				_ok(mode_b == 2, "选中建筑后底部出现训练面板（mode=%d）" % mode_b)
			var urect: Rect2 = pmap.call("token_rect", "unit", true)
			_ok(urect.size.x > 1.0, "有可点击的己方兵牌")
			if urect.size.x > 1.0:
				var picked2: bool = bool(hud.call("select_planning_token", urect.get_center()))
				_ok(picked2, "点兵牌能选中部队")
				await get_tree().create_timer(0.2).timeout
				var ph4: Variant = hud.get("_planning_hud")
				var mode_u: int = int(ph4.get("_act_mode")) if ph4 != null else -1
				var all_worker: bool = true
				for u in sel.call("selected_units"):
					var ud: UnitDef = (u as Node).get("def")
					if ud == null or not RtsWorld.is_worker_def(ud):
						all_worker = false
				_ok(mode_u == (3 if all_worker else 1),
						"点兵牌后面板与兵种匹配（mode=%d）" % mode_u)
			var wrect: Rect2 = pmap.call("token_rect_of_id", "peasant", true)
			_ok(wrect.size.x > 1.0, "有可点击的农民兵牌")
			if wrect.size.x > 1.0:
				hud.call("select_planning_token", wrect.get_center())
				await get_tree().create_timer(0.2).timeout
				var ph5: Variant = hud.get("_planning_hud")
				var mode_w: int = int(ph5.get("_act_mode")) if ph5 != null else -1
				_ok(mode_w == 3, "点农民兵牌出现建造面板（mode=%d）" % mode_w)

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

	# --- 工地兵牌（数据面）：真的放一座农场工地，规划沙盘要把它收进来（constructed=false） ---
	if sandbox != null:
		var peasant: RtsUnit = null
		for u in pf.units:
			if u != null and is_instance_valid(u) and u is RtsUnit and u.is_alive() \
					and u.def != null and u.def.id == &"peasant":
				peasant = u
				break
		var site: Node3D = null
		if peasant != null:
			var c0: Vector3 = RtsWorld.base_center(pf)
			var offs: Array = [Vector3(-20, 0, 0), Vector3(20, 0, 0), Vector3(0, 0, 22),
				Vector3(0, 0, -22), Vector3(-24, 0, -14), Vector3(-24, 0, 14),
				Vector3(24, 0, -14), Vector3(24, 0, 14), Vector3(-34, 0, 0),
				Vector3(34, 0, 0), Vector3(0, 0, 34), Vector3(0, 0, -34),
				Vector3(-30, 0, -24), Vector3(30, 0, -24)]
			for off in offs:
				if site != null:
					break
				var p: Vector3 = RtsWorld.walkable_pos(c0 + off)
				site = cmd.call("place_building", &"farm", p, [peasant], 0.0) as Node3D
		_ok(site != null, "能放下农场工地（用于验证虚线兵牌）")
		if site != null:
			await get_tree().create_timer(0.55).timeout
			var found: bool = false
			for rec in sandbox.call("building_items"):
				if rec.get("node", null) == site and not bool(rec.get("constructed", true)):
					found = true
			_ok(found, "工地进入规划沙盘数据（半透明虚线兵牌）")
			site.call("cancel_construction")
			await get_tree().create_timer(0.4).timeout

	var began: bool = bool(rc.call("begin_execution"))
	_ok(began, "开始执行成功")
	_ok(Game.phase == RtsConst.Phase.RUNNING, "阶段切到 RUNNING")
	_ok(not get_tree().paused, "执行阶段世界已解冻")
	if town != null:
		_ok(town.visible, "执行阶段恢复 3D 建筑模型")
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

	# 2026-11-15：执行阶段不能改队列、不能花 CP（训练只能在规划阶段下单）
	var cp_before: float = pf.cp
	var q3: bool = bool(barracks.call("queue_train", &"footman"))
	_ok(not q3, "执行阶段不能排队训练（队列锁定）")
	_ok(absf(pf.cp - cp_before) < 0.01, "执行阶段点训练不扣 CP（%.1f）" % pf.cp)
	if hud != null:
		var cp_lb: Variant = hud.get("_cp_label")
		var cp_hidden: bool = cp_lb == null
		if cp_lb is Label:
			var row := (cp_lb as Label).get_parent()
			var pill := row.get_parent() if row != null else null
			cp_hidden = pill is CanvasItem and not (pill as CanvasItem).visible
		_ok(cp_hidden, "执行阶段不显示 CP")
	# 执行阶段不能凭空建：只有规划阶段下过单的建筑才能施工
	var w0: Node3D = null
	for u in pf.units:
		if u != null and is_instance_valid(u) and u.is_alive() and u.def != null \
				and RtsWorld.is_worker_def(u.def):
			w0 = u
			break
	if w0 != null:
		var ghost: Node3D = cmd.call("place_building", &"farm", base + Vector3(24.0, 0.0, 0.0), [w0], 0.0)
		_ok(ghost == null, "执行阶段不能建没下单的建筑")
	rc.call("end_execution", "test")
	_ok(Game.phase == RtsConst.Phase.PLANNING, "结束执行回到规划阶段")
	_ok(get_tree().paused, "结束执行后世界重新暂停")
	if town != null:
		_ok(not town.visible, "回规划阶段重新隐藏 3D 模型")
	if sandbox != null:
		_ok(bool(sandbox.call("is_built")), "回规划阶段重建沙盘")
	# CP 每回合规划阶段由基地补满（上回合剩余清零）
	_ok(absf(pf.cp - pf.cp_cap) < 0.01, "回规划阶段 CP 由基地补满（%.1f）" % pf.cp)

	# 第二次执行：回合计数递增（波次没清完时只加回合，不叠兵）
	var began2: bool = bool(rc.call("begin_execution"))
	_ok(began2 and int(rc.get("round_index")) == 2, "第二次执行回合计数为 2")
	rc.call("end_execution", "test2")
	_ok(Game.is_planning(), "第二次结束回规划阶段")

	# --- 布局卡：槽位绑定 / 存档 / 损毁态 / ReviveSlot（2026-11-15） ---
	_ok(Game.layout != null and bool(Game.layout.call("is_active")), "布局卡运行时已启用")
	var slot_ids: Array = Game.slot_ids()
	_ok(slot_ids.size() >= 10, "布局卡槽位已绑定（%d 个）" % slot_ids.size())
	var state_path: String = SaveSvc.root() + "skirmish_layout.json"
	_ok(FileAccess.file_exists(state_path), "短局结束已写布局存档")
	var state_data: Dictionary = {}
	if FileAccess.file_exists(state_path):
		var jv: Variant = JSON.parse_string(FileAccess.get_file_as_string(state_path))
		if jv is Dictionary:
			state_data = jv
	var saved_slots: Dictionary = state_data.get("slots", {})
	_ok(saved_slots.size() == slot_ids.size(), "存档记录了全部槽位（%d）" % saved_slots.size())
	var farm_slot: String = ""
	for sid in slot_ids:
		var st: Dictionary = Game.slot_state(String(sid))
		if String(st.get("id", "")) == "farm":
			farm_slot = String(sid)
			break
	_ok(farm_slot != "", "布局卡里有农场槽位")
	if farm_slot != "":
		var farm_node: Node3D = Game.slot_entity(farm_slot)
		_ok(farm_node != null and farm_node.get_meta("slot_id", "") == farm_slot,
				"槽位能按 id 找回实体（内存绑定）")
		if farm_node != null:
			var init_hp: float = float(Game.slot_state(farm_slot).get("initial_hp", 1.0))
			farm_node.take_damage(999999.0, 0, null)
			await get_tree().create_timer(0.3).timeout
			var st2: Dictionary = Game.slot_state(farm_slot)
			_ok(bool(st2.get("destroyed", false)) and Game.slot_entity(farm_slot) == null,
					"建筑归零 → 槽位锁定为损毁态（不可用）")
			Game.layout.call("capture_and_save")
			var jv2: Variant = JSON.parse_string(FileAccess.get_file_as_string(state_path))
			var ds: Dictionary = (jv2 as Dictionary).get("slots", {}) if jv2 is Dictionary else {}
			var rec2: Dictionary = ds.get(farm_slot, {})
			_ok(bool(rec2.get("destroyed", false)), "损毁标记写进存档（不是只存在内存）")
			var revived: Node3D = Game.revive_slot(farm_slot)
			_ok(revived != null, "ReviveSlot 能把损毁槽位复活")
			if revived != null:
				_ok(absf(float(revived.get("hp")) - init_hp) < 0.5,
						"复活后血量 = initial_hp（%.0f）" % float(revived.get("hp")))
				_ok(not bool(Game.slot_state(farm_slot).get("destroyed", false)), "复活后槽位恢复可用")
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
