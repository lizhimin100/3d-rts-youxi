extends Node
## **采集压力自检**：多个农民同时抢**一座**金矿，验证"排队进矿"。
##
## 启用：godot --headless --fixed-fps 60 --path . -- --gather-test
## 输出：结尾一行 `GATHERTEST {json}`
##
## ★ 2026-11-14 判据改写（玩家口径「每个金矿限制一名农民使用采集，其他农民要等待」）：
##   以前金矿 3 个载位、抢不到也照采，这个用例考的是"十个人挤一个矿不许卡死"。
##   现在载位 = **1**，挤的人本来就要排队 —— "站着不动"不再等于卡住。新判据：
##     1. 累计入库金币 >= 150（采集链路整体通）；
##     2. **同一时刻进矿的农民不超过 1 个**（载位 1 的硬约束，最重要的一条）；
##     3. 每个农民都至少完成过一次卸货（排队没有把人饿死）；
##     4. 排队的农民必须待在矿 10m 内（不能一边等一边跑丢）。

## 超过这个秒数没位移就算"卡住"。
##
## ★ 2026-11-07 从 6.0 调到 8.0：这个用例是 **8 个农民抢 1 座金矿（3 个载位）**，
##   多出来的 5 个人必然要排队 —— 实测最长等待 7.5s（排队时人是不动的，不是卡住）。
##   上限留给「真的卡死」（以前矿心落点算错时是 28~85s，一测就红）。
const STUCK_LIMIT: float = 8.0   # 仅用于日志（排队会站很久，不再作为判据）
## 总模拟时长（秒）
## 总模拟时长（秒）。默认 75s：6 个农民抢 1 个载位，每人至少能轮上一趟。
## 命令行可覆盖：`-- --gather-test=120`（想要长跑时用）。
var DURATION: float = 75.0
## 额外塞多少个农民（玩家开局 5 个，再塞 5 个凑 10 个）
## 额外塞多少个农民（玩家开局 5 个，再塞 1 个凑 6 个 —— 一座矿 1 个载位，
## 6 个人排队已经能压出"轮流进矿"的完整链路，再多人只会让用例跑很久）
const EXTRA_PEASANTS: int = 1

var _report: Dictionary = {}
var _done: bool = false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--gather-test="):
			DURATION = clampf(float(a.substr(String("--gather-test=").length())), 20.0, 600.0)
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
	var max_in_mine: int = 0
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
		var in_mine: int = _count_in_mine(peasants)
		max_in_mine = maxi(max_in_mine, in_mine)
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

	# 排队纪律：**停在矿边等**的人必须待在矿 10m 内。
	#   · 只统计"站着排队"的：TO_NODE(1) + 没抢到载位 + state == IDLE；
	#   · 从交汇点走回来的、正在起手/采集的、去卸货的都不算 ——
	#     第一版没区分，把"刚卸完货往回走"的农民也算成跑丢，误判过一次。
	var far_waiters: int = 0
	for p in peasants:
		if p == null or not is_instance_valid(p) or not p.is_alive():
			continue
		if int(p.call("debug_gather_phase")) != 1:
			continue
		if int(p.get("_gather_slot")) >= 0:
			continue
		if int(p.state) != RtsConst.State.IDLE:
			continue
		if p.global_position.distance_to(mine.global_position) > 10.0:
			far_waiters += 1

	_report = {
		"农民数": peasants.size(),
		"同时进矿峰值": max_in_mine,
		"矿外跑丢人数": far_waiters,
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
	# ★ 2026-11-07：口径从"阵营金币净增长"改成"农民累计入库"。
	#   旧口径会被副官/AI 同时花钱污染（DEPT 默认 on 以后净增长经常是负的，
	#   采集明明在跑也会判失败 —— 这是测试口径错，不是采集错）。
	var deposited: int = 0
	for p in peasants:
		if p != null and is_instance_valid(p):
			deposited += int(p.get("deposit_gold_total"))
	_report["累计入库金币"] = deposited
	if deposited < 150:
		ok = false
		why = "累计入库不足（%d < 150），采集链路没跑通" % deposited
	elif max_in_mine > 1:
		ok = false
		why = "同一时刻有 %d 个农民在金矿里（载位上限 1）" % max_in_mine
	elif min_deposits <= 0:
		ok = false
		why = "有农民一次货都没卸（采集/返程/卸货链路断了）"
	elif far_waiters > 0:
		ok = false
		why = "有 %d 个农民在排队时跑到矿 10m 外" % far_waiters
	_finish(ok, why)


## 此刻有几个农民真的在矿里（ENTER=4 起手 / HARVEST=2 采集）
func _count_in_mine(peasants: Array) -> int:
	var n: int = 0
	for p in peasants:
		if p == null or not is_instance_valid(p) or not p.is_alive():
			continue
		if not p.has_method("debug_gather_phase"):
			continue
		var ph: int = int(p.call("debug_gather_phase"))
		if ph == 4 or ph == 2:
			n += 1
	return n


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
	var line := "GATHERTEST " + JSON.stringify(_report)
	print(line)
	# 同时落盘一份：stdout 重定向到文件时会被块缓冲，进程退出可能把最后一行丢掉
	# （2026-11-14 实测：日志里没有 GATHERTEST，但退出码是 1）。
	var f := FileAccess.open("res://_qa/gather_report.json", FileAccess.WRITE)
	if f != null:
		f.store_string(line)
		f.flush()
		f.close()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ok else 1)
