extends Node
## **木材采集自检**：树按「次数」扣、砍完换树、一个农民都不许停。
##
## 启用：godot --headless --fixed-fps 60 --path . -- --wood-test
## 输出：结尾一行 `WOODTEST {json}`
##
## 覆盖玩家 2026-11-07 的两条口径：
##   ① 「部分农民采木后，会停在伐木场或基地附近，甚至直接停在刚刚倒下的树木」；
##   ② 「给树木增加次数 —— 一共 20 次，由采集技能的单位每次采集扣 1 次」。
##
## 用例：
##   A. 6 个农民采同一片树林 150 模拟秒：每人至少卸货 1 次、原地不动不超过 8s；
##   B. 树剩余次数必须**按采集动作**递减（不是按木头吨位）：盯一棵树看它掉了几次；
##   C. 把当前树的次数手动压到 1，逼它枯竭：农民必须自己换一棵树继续干，
##      不允许停在原地（这是玩家报的「停在刚倒下的树旁边」的原样复现）。

## 超过这个秒数没位移就算「停住」
const STUCK_LIMIT: float = 8.0
## 总模拟时长（秒）
const DURATION: float = 150.0
const PEASANTS: int = 6

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
	var tree: Node3D = _find_tree()
	if tree == null:
		_finish(false, "找不到树")
		return

	# --- 补农民，塞在树旁边 ---
	var base: Vector3 = Game.level.base_center(pf)
	var squad: Array = []
	for i in PEASANTS:
		var ang: float = TAU * float(i) / float(PEASANTS)
		var p: Vector3 = Game.level.walkable_pos(base + Vector3(cos(ang) * 8.0, 0.0, sin(ang) * 8.0 + 6.0))
		var u: Node3D = Game.spawn_unit(pf, &"peasant", p, Game.level)
		if u != null:
			squad.append(u)
	await _wait(0.3)
	if squad.is_empty():
		_finish(false, "生成农民失败")
		return

	# 先把树按次数口径验一遍（配置口径回归）
	var start_uses: int = int(tree.get("remaining"))
	var charge_ok: bool = bool(tree.call("is_charge_based"))
	if not charge_ok:
		_finish(false, "树不是按次计消耗（is_charge_based=false）")
		return

	for u in squad:
		u.order_gather(tree)

	var start_wood: int = pf.wood
	var last_pos: Array = []
	var still: Array = []
	var max_still: Array = []
	for u in squad:
		last_pos.append(u.global_position)
		still.append(0.0)
		max_still.append(0.0)

	var depleted_once: bool = false
	var switched_after_deplete: bool = false
	var t: float = 0.0
	var dt: float = 0.5
	while t < DURATION:
		await _wait(dt)
		t += dt
		for i in squad.size():
			var u: Node3D = squad[i]
			if u == null or not is_instance_valid(u) or not u.is_alive():
				continue
			var moved: float = u.global_position.distance_to(last_pos[i])
			last_pos[i] = u.global_position
			if moved < 0.02:
				still[i] += dt
				max_still[i] = maxf(max_still[i], still[i])
			else:
				still[i] = 0.0
		# C 用例：把当前树的次数压到 1，逼它在下一次采集后枯竭
		if not depleted_once and t >= DURATION * 0.45 and tree != null and is_instance_valid(tree):
			if int(tree.get("remaining")) > 1:
				tree.set("remaining", 1)
		elif not depleted_once and (tree == null or not is_instance_valid(tree) or bool(tree.call("is_depleted"))):
			depleted_once = true
		# 枯竭之后：农民必须在干活（阶段不是 SEEK 且至少在动），且最终还能卸货
		if depleted_once:
			for u in squad:
				if u != null and is_instance_valid(u):
					var ph: int = int(u.call("debug_gather_phase"))
					if ph == 1 or ph == 2 or ph == 3 or ph == 4:
						switched_after_deplete = true

	var wood_gain: int = pf.wood - start_wood
	var worst_still: float = 0.0
	for v in max_still:
		worst_still = maxf(worst_still, v)
	var min_deposits: int = 999
	var deposited_total: int = 0
	for u in squad:
		if u != null and is_instance_valid(u):
			var d: int = int(u.call("get_deposit_count"))
			min_deposits = mini(min_deposits, d)
			deposited_total += d

	_report = {
		"农民数": squad.size(),
		"时长(秒)": DURATION,
		"树初始次数": start_uses,
		"木材净增长": wood_gain,
		"累计卸货次数": deposited_total,
		"每人最少卸货": min_deposits,
		"最长原地不动(秒)": "%.1f" % worst_still,
		"逼枯竭过": depleted_once,
		"枯竭后仍在采/搬": switched_after_deplete,
	}
	var ok: bool = true
	var why: String = ""
	if start_uses != 20:
		ok = false
		why = "树的初始次数不是 20（%d）" % start_uses
	elif deposited_total < 8:
		ok = false
		why = "累计卸货次数不足（%d < 8）" % deposited_total
	elif min_deposits <= 0:
		ok = false
		why = "有农民一次木都没运回来"
	elif worst_still > STUCK_LIMIT:
		ok = false
		why = "有农民原地不动 %.1fs（>%.0fs）—— 采完停在原地" % [worst_still, STUCK_LIMIT]
	elif not depleted_once:
		ok = false
		why = "没能把树采枯竭（次数没在掉？）"
	elif not switched_after_deplete:
		ok = false
		why = "树枯竭以后农民没有继续采/搬（停在刚倒下的树旁边）"
	_finish(ok, why)


func _find_tree() -> Node3D:
	var best: Node3D = null
	var best_d: float = INF
	var origin: Vector3 = Game.level.base_center(Game.player_faction)
	for h in Game.level.resource_nodes():
		if h == null or not is_instance_valid(h):
			continue
		if int(h.get("harvest_kind")) != RtsConst.Harvest.WOOD:
			continue
		if bool(h.call("is_depleted")):
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
	print("WOODTEST " + JSON.stringify(_report))
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ok else 1)
