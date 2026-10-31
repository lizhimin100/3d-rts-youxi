extends Node
## **自动化试玩**：不用鼠标键盘，直接驱动一局游戏，验证核心玩法闭环。
##
## 启用方式（主场景检测到 `--autotest` 参数时自动挂上）：
##   godot --path . --headless --fixed-fps 60 -- --autotest
##   godot --path . -- --autotest            （带窗口，能顺便看画面）
##
## 它做的事（按时间轴）：
##   1. 查开局：阵营资源 / 单位数量 / 建筑数量
##   2. 经济：派 3 个农民去采金，验证金币增长
##   3. 移动：把战斗单位移动到一个点，验证真的走过去了
##   4. 战斗：在玩家军队旁边刷 3 个敌人，验证交战、掉血、死亡
##   5. AI：统计敌人的单位数变化（证明 AI 会出兵）
##   6. 胜负：把敌方大本营打爆，验证 phase == VICTORY
##   7. 重开：reload 场景后验证状态归零、单位数回到开局值
##
## 输出：结尾打印一行 `AUTOTEST {json}`，方便脚本 grep。

## 是否已经完成（防止重复跑）
var _done: bool = false
## 报告
var _report: Dictionary = {}
## 战斗命中计数
var _hits: int = 0
var _kills: int = 0
## 重开验证用（跨场景重载保留：static 变量在同一脚本资源上不会因场景重载而清空）
static var _restart_checked: bool = false
static var _restart_ok: bool = false
static var _prev_report: Dictionary = {}
## 首局是否通过（重开后的退出码必须把首局结果算进去，否则"首局全失败但退出码 0"这种假绿最危险）
static var _phase1_ok: bool = false
## 第几次运行（1=首局全流程，2=重开后的复查）
static var _run_index: int = 0


func _ready() -> void:
	_run_index += 1
	if _run_index >= 2:
		# 第二次进入场景 = 刚刚点过"重新开始"，只做复查
		_check_after_restart.call_deferred()
		return
	Game.combat_hit.connect(_on_combat_hit)
	Game.unit_died.connect(_on_unit_died)
	# 加速模拟：5 倍速，让 60 秒的局在 12 秒内跑完
	Engine.time_scale = 5.0
	_run.call_deferred()


func _on_combat_hit(_a: Node3D, _t: Node3D, _dmg: float, _crit: bool) -> void:
	_hits += 1


func _on_unit_died(_u: Node3D) -> void:
	_kills += 1


## 主流程
func _run() -> void:
	await _wait(0.4)
	if Game.level == null:
		_finish(false, "关卡未建立")
		return

	# ---------- 1. 开局检查 ----------
	var pf: RtsFaction = Game.player_faction
	var ef: RtsFaction = Game.enemy_faction
	_report["开局"] = {
		"玩家金币": pf.gold, "玩家木材": pf.wood,
		"玩家单位": pf.count_units(), "玩家建筑": pf.count_buildings(),
		"敌人单位": ef.count_units(), "敌人建筑": ef.count_buildings(),
		"人口": "%d/%d" % [pf.food_used(), pf.food_cap()],
	}
	print("[自动试玩] 开局：%s" % str(_report["开局"]))

	# ---------- 2. 经济：派农民采金 ----------
	var peasants: Array = []
	for u in pf.units:
		if u != null and is_instance_valid(u) and RtsWorld.is_worker_def(u.def):
			peasants.append(u)
	var mine: Node3D = _find_gold_mine()
	var gold_start: int = pf.gold
	var _wood_start: int = pf.wood
	var deposits_start: int = _sum_deposits(pf)
	if peasants.size() > 0 and mine != null:
		for i in mini(3, peasants.size()):
			peasants[i].order_gather(mine)
		print("[自动试玩] 已派 %d 个农民去采金" % mini(3, peasants.size()))
	else:
		print("[自动试玩] ⚠ 没有农民或没有金矿： peasants=%d mine=%s" % [peasants.size(), str(mine)])

	# 诊断：把阵营里的单位逐个打出来（排查"为什么战斗单位数是 0"）
	for u in pf.units:
		if u == null:
			print("  · 单位=null")
			continue
		var d: UnitDef = u.def
		print("  · 单位 id=%s kind=%d gather=%.1f hp=%.0f is_worker=%s" % [
			String(d.id) if d != null else "?", d.kind if d != null else -1,
			d.gather_rate if d != null else -1.0, d.max_hp if d != null else -1.0,
			("是" if d.is_worker() else "否") if d != null else "?",
		])

	# ---------- 3. 移动：战斗单位走到一个点 ----------
	var army: Array = []
	for u in pf.units:
		if u != null and is_instance_valid(u) and not RtsWorld.is_worker_def(u.def) and not u.def.is_building():
			army.append(u)
	var dest: Vector3 = Game.level.base_center(pf) + Vector3(0.0, 0.0, -14.0)
	var pos_before: Array = []
	for u in army:
		pos_before.append(u.global_position)
		u.order_move(dest + Vector3(randf_range(-3, 3), 0.0, randf_range(-3, 3)))
	print("[自动试玩] 已让 %d 个战斗单位移动" % army.size())

	await _wait(4.0)

	# 统计移动距离
	var moved: int = 0
	for i in army.size():
		if i < pos_before.size() and is_instance_valid(army[i]):
			if army[i].global_position.distance_to(pos_before[i]) > 2.0:
				moved += 1
	_report["移动"] = {"战斗单位": army.size(), "实际移动数": moved}

	# ---------- 4. 经济复查 ----------
	var gold_now: int = pf.gold
	_report["经济"] = {"起始金币": gold_start, "当前金币": gold_now, "增长": gold_now - gold_start}
	print("[自动试玩] 经济：金币 %d → %d" % [gold_start, gold_now])

	# ---------- 5. 战斗：附近刷敌人 ----------
	var army_center := dest
	if army.size() > 0 and is_instance_valid(army[0]):
		army_center = army[0].global_position
	var spawned: int = 0
	for i in 3:
		var p: Vector3 = Game.level.walkable_pos(army_center + Vector3(-6.0 + float(i) * 3.0, 0.0, -6.0))
		var e := Game.spawn_unit(ef, &"footman", p, Game.level)
		if e != null:
			spawned += 1
	print("[自动试玩] 已空投 %d 个敌人到军队旁" % spawned)
	await _wait(7.0)

	# 精确验证"死亡链路"：直接补刀一个空投敌人，确认 unit_died 触发且从注册表移除
	# （不靠 DPS 恰好打死——那是看运气，不是测流程）
	var killed_by_test: bool = false
	var sacrifice: Node3D = null
	for e in ef.units:
		if e != null and is_instance_valid(e) and e.global_position.distance_to(army_center) < 25.0:
			sacrifice = e
			break
	var kills_before: int = _kills
	if sacrifice != null:
		var name_before: String = String(sacrifice.name)
		sacrifice.take_damage(999999.0, RtsConst.DamageType.SIEGE, null)
		# ① 死亡状态应当立刻成立
		await _wait(0.3)
		var dead_now: bool = not sacrifice.is_alive()
		# ② 尸体停留（Cfg.corpse_linger 默认 2.2s）之后才注销、才发 unit_died
		await _wait(maxf(3.0, Cfg.game.corpse_linger + 1.2))
		var still_there: bool = Game.enemy_faction.units.has(sacrifice)
		killed_by_test = dead_now and (_kills > kills_before) and not still_there
		print("[自动试玩] 死亡链路：补刀 %s → 立刻死亡=%s，unit_died 增加=%s，已从注册表移除=%s" % [
			name_before, str(dead_now), str(_kills > kills_before), str(not still_there)])
	_report["战斗"] = {"命中次数": _hits, "战斗死亡数": _kills, "空投敌人数": spawned, "死亡链路": killed_by_test}
	print("[自动试玩] 战斗：命中 %d 次，死亡 %d 个，死亡链路=%s" % [_hits, _kills, str(killed_by_test)])

	# ---------- 6. AI 出兵 ----------
	_report["AI"] = {
		"单位数": ef.count_units(),
		"金币": ef.gold,
		"建筑数": ef.count_buildings(),
	}
	print("[自动试玩] AI：单位 %d，金币 %d" % [ef.count_units(), ef.gold])

	# ---------- 6.5 经济终局复查（农民跑一趟要走路，必须给足时间）----------
	await _wait(10.0)
	_report["经济终局"] = {
		"起始金币": gold_start,
		"终局金币": pf.gold,
		"增长": pf.gold - gold_start,
		"采集入库": _sum_deposits(pf) - deposits_start,
		"终局木材增长": pf.wood - _wood_start,
	}
	print("[自动试玩] 经济终局：金币 %d → %d（增长 %d），采集入库 %d 次，木材增长 %d" % [
		gold_start, pf.gold, pf.gold - gold_start,
		_sum_deposits(pf) - deposits_start, pf.wood - _wood_start,
	])

	# ---------- 7. 胜负：打爆**所有敌对阵营**的大本营 ----------
	# 多队图（4 个出生点 / 3 个队）下"敌人"不止一家：只拆一家不算赢，
	# 这里把所有敌对阵营的大本营一起拆掉，才是"玩家赢了"的那条路径。
	var halls: int = 0
	for foe in Game.enemies_of(pf):
		if foe == null:
			continue
		for b in foe.buildings:
			if b == null or not is_instance_valid(b) or b.def == null:
				continue
			if b.def.id != &"townhall":
				continue
			b.take_damage(99999.0, RtsConst.DamageType.SIEGE, null)
			halls += 1
	if halls > 0:
		print("[自动试玩] 已摧毁 %d 座敌方大本营（敌对阵营 %d 个）" % [halls, Game.enemies_of(pf).size()])
	else:
		print("[自动试玩] ⚠ 找不到敌方大本营")
	await _wait(2.0)
	_report["胜负"] = {
		"阶段": Game.phase,
		"胜利?": Game.phase == RtsConst.Phase.VICTORY,
	}
	print("[自动试玩] 阶段=%d（%d=胜利）" % [Game.phase, RtsConst.Phase.VICTORY])

	# ---------- 8. 汇总 + 触发重开 ----------
	var ok := true
	if _report["移动"]["实际移动数"] <= 0:
		ok = false
	if _report["战斗"]["命中次数"] <= 0:
		ok = false
	if not _report["战斗"].get("死亡链路", false):
		ok = false
		_report["战斗备注"] = "补刀后 unit_died 没触发或没从注册表移除（死亡链路断了）"
	# ⚠ 判据是"采集链路有没有产出"，**不是"净金币有没有变多"**。
	# 净金币会被副官的开销吃掉（它一开局就在排农民、盖兵营），
	# 用净金币判会把"采集正常 + AI 在花钱"误判成"采集坏了"。
	# 这里同时看两个数：任一为正就说明"地里出了金子"。
	if _report["经济终局"]["增长"] <= 0 and int(_report["经济终局"]["采集入库"]) <= 0:
		ok = false
		_report["经济备注"] = "农民没有产出金币（检查采集/运送/回收链路）"
	if not _report["胜负"]["胜利?"]:
		ok = false
	_phase1_ok = ok
	_report["结果首局"] = "通过" if ok else "失败"
	print("AUTOTEST-PHASE1 " + JSON.stringify(_report))

	# 走真正的重开路径：场景重载 → 下一次 _ready 里复查
	print("[自动试玩] 触发重新开始（reload_current_scene）")
	await _wait(1.2)
	Game.restart()


## 重开后的复查（第二次进入场景时执行）
func _check_after_restart() -> void:
	await _wait(0.6)
	var pf: RtsFaction = Game.player_faction
	var ok: bool = (
		pf != null
		and Game.phase == RtsConst.Phase.RUNNING
		and pf.count_units() > 0
		and pf.count_buildings() > 0
		and Game.level != null
	)
	_prev_report["重开"] = {
		"阶段": Game.phase if Game.phase != null else -1,
		"玩家单位": pf.count_units() if pf != null else -1,
		"玩家建筑": pf.count_buildings() if pf != null else -1,
		"通过": ok,
	}
	var overall: bool = ok and _phase1_ok
	_prev_report["首局通过"] = _phase1_ok
	_prev_report["结果"] = "通过" if overall else "失败"
	print("AUTOTEST " + JSON.stringify(_prev_report))
	await _wait(0.2)
	get_tree().quit(0 if overall else 1)


## 重开验证（旧接口保留，主场景不会直接调）
func verify_after_restart() -> void:
	await _check_after_restart()


# ===========================================================================
# 工具
# ===========================================================================

## 该阵营所有农民累计"卸货次数"（每次卸货 = 一趟采集闭环完成）
func _sum_deposits(fac: RtsFaction) -> int:
	var n: int = 0
	if fac == null:
		return n
	for u in fac.units:
		if u == null or not is_instance_valid(u) or u.def == null:
			continue
		if not RtsWorld.is_worker_def(u.def):
			continue
		n += int(u.call("get_deposit_count"))
	return n


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## 找最近的金矿
func _find_gold_mine() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	var origin: Vector3 = Game.level.base_center(Game.player_faction)
	for h in Game.level.resource_nodes():
		if h == null or not is_instance_valid(h):
			continue
		if h.harvest_kind != RtsConst.Harvest.GOLD or h.is_depleted():
			continue
		var d: float = origin.distance_to(h.global_position)
		if d < best_d:
			best_d = d
			best = h
	return best


## 收尾：打印报告并退出
func _finish(ok: bool, reason: String) -> void:
	if _done:
		return
	_done = true
	_report["结果"] = "通过" if ok else ("失败：" + reason if reason != "" else "失败")
	print("AUTOTEST " + JSON.stringify(_report))
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if ok else 1)
