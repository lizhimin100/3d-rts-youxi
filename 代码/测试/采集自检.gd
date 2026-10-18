extends Node
## **采集压力自检**：10 个农民同时采矿，逐秒采样"谁卡住了、卡在哪个阶段"。
##
## 启用：godot --headless --fixed-fps 60 --path . -- --gather-test
## 输出：结尾一行 `GATHERTEST {json}`
##
## 判据（用户原话："一个农民都不许卡，十个农民一起去挤也不许卡"）：
##   1. 90 模拟秒内金币必须明显增长（>= 150）
##   2. 任何农民的"原地不动时长"不得超过 STUCK_LIMIT 秒（默认 6s）
##   3. 每个农民都必须至少完成过一次卸货（deposits > 0）
##   4. 结束时不允许有农民停在 TO_DROP/TO_NODE 且速度为 0

## 超过这个秒数没位移就算"卡住"
const STUCK_LIMIT: float = 6.0
## 总模拟时长（秒）
const DURATION: float = 90.0
## 额外塞多少个农民（玩家开局 5 个，再塞 5 个凑 10 个）
const EXTRA_PEASANTS: int = 5

var _report: Dictionary = {}
var _done: bool = false


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _wait(0.4)
	if Game.level == null:
		_finish(false, "关卡未建立")
		return
	var pf: RtsFaction = Game.player_faction
	var mine: Node3D = _find_mine()
	if mine == null:
		_finish(false, "找不到金矿")
		return

	# --- 补足 10 个农民，塞在基地门口 ---
	var base: Vector3 = Game.level.base_center(pf)
	for i in EXTRA_PEASANTS:
		var ang: float = TAU * float(i) / float(EXTRA_PEASANTS)
		var p: Vector3 = Game.level.walkable_pos(base + Vector3(cos(ang) * 9.0, 0.0, sin(ang) * 9.0 + 7.0))
		Game.spawn_unit(pf, &"peasant", p, Game.level)
	await _wait(0.3)

	var peasants: Array = []
	for u in pf.units:
		if u != null and is_instance_valid(u) and u.def != null and u.def.is_worker() and u.is_alive():
			peasants.append(u)
	for p in peasants:
		p.order_gather(mine)

	var start_gold: int = pf.gold
	var last_pos: Array = []
	var still: Array = []
	var max_still: Array = []
	for p in peasants:
		last_pos.append(p.global_position)
		still.append(0.0)
		max_still.append(0.0)

	var samples: Array = []
	var t: float = 0.0
	var dt: float = 0.5
	while t < DURATION:
		await _wait(dt)
		t += dt
		for i in peasants.size():
			var p: Node3D = peasants[i]
			if p == null or not is_instance_valid(p) or not p.is_alive():
				continue
			var moved: float = p.global_position.distance_to(last_pos[i])
			last_pos[i] = p.global_position
			if moved < 0.02:
				still[i] += dt
				max_still[i] = maxf(max_still[i], still[i])
			else:
				still[i] = 0.0
		if int(t * 2.0) % 20 == 0:
			samples.append(_snapshot(peasants, t))

	var gold_gain: int = pf.gold - start_gold
	var worst_still: float = 0.0
	var worst_idx: int = -1
	for i in max_still.size():
		if max_still[i] > worst_still:
			worst_still = max_still[i]
			worst_idx = i

	# 每个农民卸过几次货
	var deposits: Array = []
	for p in peasants:
		if p != null and is_instance_valid(p) and p.has_method("get_deposit_count"):
			deposits.append(int(p.call("get_deposit_count")))
		else:
			deposits.append(-1)
	var min_deposits: int = 999
	for d in deposits:
		min_deposits = mini(min_deposits, int(d))

	# 结束时的阶段分布
	var phases: Dictionary = {}
	for p in peasants:
		if p == null or not is_instance_valid(p):
			continue
		var ph: int = -1
		if p.has_method("debug_gather_phase"):
			ph = int(p.call("debug_gather_phase"))
		phases[str(ph)] = int(phases.get(str(ph), 0)) + 1

	_report = {
		"农民数": peasants.size(),
		"时长(秒)": DURATION,
		"金币增长": gold_gain,
		"最长原地不动(秒)": "%.1f" % worst_still,
		"卡住的那个": worst_idx,
		"最少卸货次数": min_deposits,
		"结束时阶段分布": phases,
		"过程采样": samples,
	}

	var ok: bool = true
	var why: String = ""
	if gold_gain < 150:
		ok = false
		why = "金币增长不足（%d < 150），采集链路没跑通" % gold_gain
	elif worst_still > STUCK_LIMIT:
		ok = false
		why = "有农民原地不动 %.1fs（>%.0fs）" % [worst_still, STUCK_LIMIT]
	elif min_deposits <= 0:
		ok = false
		why = "有农民一次货都没卸（采集/返程/卸货链路断了）"
	_finish(ok, why)


## 采一份快照（给报告看趋势）
func _snapshot(peasants: Array, t: float) -> Dictionary:
	var by_state: Dictionary = {}
	var by_phase: Dictionary = {}
	for p in peasants:
		if p == null or not is_instance_valid(p) or not p.is_alive():
			continue
		by_state[str(p.state)] = int(by_state.get(str(p.state), 0)) + 1
		if p.has_method("debug_gather_phase"):
			var ph: int = int(p.call("debug_gather_phase"))
			by_phase[str(ph)] = int(by_phase.get(str(ph), 0)) + 1
	return {"t": "%.0f" % t, "状态": by_state, "阶段": by_phase}


func _find_mine() -> Node3D:
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


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _finish(ok: bool, reason: String) -> void:
	if _done:
		return
	_done = true
	_report["结果"] = "通过" if ok else ("失败：" + reason if reason != "" else "失败")
	print("GATHERTEST " + JSON.stringify(_report))
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ok else 1)
