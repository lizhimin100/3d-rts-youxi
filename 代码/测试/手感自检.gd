extends Node
## **手感自检**：在**固定 60fps**下逐帧采样，把"跟手 / 不飘 / 不黏"量化成数字。
##
## 启用（必须带 --fixed-fps 60，否则时间轴不可信）：
##   godot --path . --fixed-fps 60 --headless -- --feel-test
##
## 测四件事：
##   1. 镜头平移：起速爬到 90% 峰值用多少秒？松手到 10% 用多少秒？
##      ——太慢=飘/黏，太快=一按就飞；判据 0.06~0.35s（起）/ 0.02~0.35s（停）
##   2. 镜头缩放：滚轮一下，距离从 30 收敛到 95% 用多少秒？（判据 0.05~0.45s）
##   3. 单位移动：位移曲线是否"起步有加速、到点有减速"，最高速是否接近配置值
##   4. 镜头旋转：Q 转 45° 用多少秒（判据 0.10~0.45s）

var _report: Dictionary = {}
var _done: bool = false


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _wait(0.5)
	var cam: Node3D = _camera()
	if cam == null or not cam.has_method("focus_point"):
		_finish(false, "镜头不可用")
		return
	var ok_all: bool = true

	# ---------------- 1. 镜头平移：起速 + 刹停 ----------------
	# 逐帧记录"注视点位移"（米/帧），乘 60 就是米/秒
	var series: Array = []
	var prevp: Vector3 = cam.call("focus_point")
	_key(KEY_RIGHT, true)
	for i in 30:
		await get_tree().process_frame
		var cur: Vector3 = cam.call("focus_point")
		series.append(prevp.distance_to(cur))
		prevp = cur
	_key(KEY_RIGHT, false)
	for i in 30:
		await get_tree().process_frame
		var cur2: Vector3 = cam.call("focus_point")
		series.append(prevp.distance_to(cur2))
		prevp = cur2

	var peak: float = 0.0001
	for v in series:
		peak = maxf(peak, float(v))
	# 起速：第一次达到 90% 峰值出现在第几帧
	var rise_frame: int = -1
	for i in series.size():
		if float(series[i]) >= peak * 0.9:
			rise_frame = i
			break
	var rise_sec: float = float(rise_frame) / 60.0 if rise_frame >= 0 else -1.0
	# 刹停：松手（第 30 帧）之后降到 10% 峰值用几帧
	var stop_frame: int = -1
	for i in range(30, series.size()):
		if float(series[i]) <= peak * 0.1:
			stop_frame = i - 30
			break
	var stop_sec: float = float(stop_frame) / 60.0 if stop_frame >= 0 else 9.99
	var rise_ok: bool = rise_sec >= 0.04 and rise_sec <= 0.35
	var stop_ok: bool = stop_sec <= 0.35
	ok_all = ok_all and rise_ok and stop_ok
	_report["镜头平移"] = {
		"峰值速度(米/帧)": "%.4f" % peak,
		"峰值速度(米/秒)": "%.2f" % (peak * 60.0),
		"起速到90%(秒)": "%.3f" % rise_sec,
		"刹停到10%(秒)": "%.3f" % stop_sec,
		"前6帧": series.slice(0, 6).map(func(v): return "%.4f" % v),
		"松手后6帧": series.slice(30, 36).map(func(v): return "%.4f" % v),
		"起速合格": rise_ok, "刹停合格": stop_ok,
	}

	# ---------------- 2. 镜头缩放 ----------------
	if cam.has_method("distance"):
		var d0: float = float(cam.call("distance"))
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP
		ev.pressed = true
		ev.position = Vector2(960, 540)
		get_viewport().push_input(ev, true)
		var d_final: float = d0
		var converge_frame: int = -1
		for i in 45:
			await get_tree().process_frame
			d_final = float(cam.call("distance"))
			if converge_frame < 0 and absf(d_final - d0) >= absf(f64_target_delta(d0)) * 0.95:
				converge_frame = i
		var delta_total: float = absf(d_final - d0)
		var converge_sec: float = float(converge_frame) / 60.0 if converge_frame >= 0 else 9.99
		var zoom_ok: bool = delta_total > 0.4 and converge_sec <= 0.45
		ok_all = ok_all and zoom_ok
		_report["镜头缩放"] = {
			"起始距离": "%.2f" % d0, "最终距离": "%.2f" % d_final,
			"收敛(秒)": "%.3f" % converge_sec, "合格": zoom_ok,
		}

	# ---------------- 3. 单位移动曲线 ----------------
	var unit: Node3D = _pick_unit()
	if unit != null:
		var start: Vector3 = unit.global_position
		var goal: Vector3 = start + Vector3(0.0, 0.0, -8.0)
		unit.order_move(goal)
		var prev: Vector3 = start
		var speeds: Array = []
		var accel_ok: bool = false
		var decel_ok: bool = false
		for i in 260:
			await get_tree().process_frame
			var cur: Vector3 = unit.global_position
			speeds.append(prev.distance_to(cur) * 60.0)
			prev = cur
			if cur.distance_to(goal) < 0.9 and i > 30:
				# 到点后继续采 12 帧看减速
				for j in 12:
					await get_tree().process_frame
					var c2: Vector3 = unit.global_position
					speeds.append(prev.distance_to(c2) * 60.0)
					prev = c2
				break
		var peak_speed: float = 0.0
		for v in speeds:
			peak_speed = maxf(peak_speed, float(v))
		# 起步：第一帧速度应该明显小于峰值（说明有加速过程，不是瞬间满速）
		accel_ok = speeds.size() > 3 and float(speeds[0]) < peak_speed * 0.75
		# 收尾：最后 3 帧速度应该远小于峰值（说明有减速）
		var tail_avg: float = 0.0
		for i in range(maxi(0, speeds.size() - 3), speeds.size()):
			tail_avg += float(speeds[i])
		tail_avg /= 3.0
		decel_ok = tail_avg < peak_speed * 0.35
		ok_all = ok_all and accel_ok and decel_ok
		_report["单位移动"] = {
			"配置最高速": "%.2f" % (unit.def.move_speed if unit.def != null else -1.0),
			"实测最高速": "%.2f" % peak_speed,
			"起步有加速": accel_ok, "到点有减速": decel_ok,
			"起步3帧": speeds.slice(0, 3).map(func(v): return "%.2f" % v),
			"收尾3帧": speeds.slice(maxi(0, speeds.size() - 3)).map(func(v): return "%.2f" % v),
		}

	# ---------------- 4. 镜头旋转 ----------------
	if cam.has_method("yaw_degrees"):
		var y0: float = float(cam.call("yaw_degrees"))
		_key(KEY_Q, true)
		await get_tree().process_frame
		await get_tree().process_frame
		_key(KEY_Q, false)
		var frame90: int = -1
		for i in 40:
			await get_tree().process_frame
			var y: float = float(cam.call("yaw_degrees"))
			if frame90 < 0 and absf(y - y0) >= 42.0:
				frame90 = i
		var rot_ok: bool = frame90 >= 0 and float(frame90) / 60.0 <= 0.45
		ok_all = ok_all and rot_ok
		_report["镜头旋转"] = {"转45度(秒)": "%.3f" % (float(frame90) / 60.0 if frame90 >= 0 else 9.99), "合格": rot_ok}

	_finish(ok_all, "" if ok_all else "有一项手感判据未达标")


## 滚轮一格的目标变化量（用于判断"收敛到 95%"）——这里用保守估计
func f64_target_delta(d0: float) -> float:
	return maxf(Cfg.game.camera_zoom_step, 0.5)


func _pick_unit() -> Node3D:
	for u in Game.player_faction.units:
		if u != null and is_instance_valid(u) and u.is_alive() and u.def != null and not u.def.is_worker():
			return u
	return null


func _camera() -> Node3D:
	var p := get_parent()
	if p != null:
		var c: Node = p.get("camera")
		if c is Node3D:
			return c as Node3D
	return null


func _key(code: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _finish(ok: bool, reason: String) -> void:
	if _done:
		return
	_done = true
	_report["结果"] = "通过" if ok else ("失败：" + reason if reason != "" else "失败")
	print("FEELTEST " + JSON.stringify(_report))
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if ok else 1)
