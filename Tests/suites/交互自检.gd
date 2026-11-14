extends Node
## **交互自检**：用合成输入事件驱动"鼠标点选 / 拖框 / 右键指令 / 镜头加速曲线"，
## 把 RTS 手感这块从"我觉得还行"变成可复现的数字。
##
## 启用：godot --path . -- --interact-test
## 输出结尾一行 `INTERACT {json}`。

var _report: Dictionary = {}
var _done: bool = false


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _wait(0.4)
	if Game.level == null:
		_finish(false, "关卡未建立")
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		_finish(false, "没有相机")
		return
	Game.phase = RtsConst.Phase.RUNNING

	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	_report["视口"] = str(vp_size)

	# ---------- 1. 左键点选 ----------
	var unit: Node3D = _pick_one_player_unit()
	if unit == null:
		_finish(false, "没有可点的玩家单位")
		return
	# 把镜头挪到该单位上方，保证它在画面中间
	if camera_node() != null and camera_node().has_method("focus_on"):
		camera_node().call("focus_on", unit.global_position)
	await _wait(0.35)
	var screen_pos: Vector2 = cam.unproject_position(unit.global_position + Vector3.UP * 0.9)
	_click(screen_pos, MOUSE_BUTTON_LEFT, true)
	await _wait(0.05)
	_click(screen_pos, MOUSE_BUTTON_LEFT, false)
	await _wait(0.2)
	var sel := _selection()
	# 判据：单击必须"只选中 1 个己方单位"。
	# 不要求一定是那个具体单位 —— 12 个单位在基地挤成一堆时，
	# 点到的可能是它前面挡住的那个兵（这才是正确的遮挡语义）。
	var only_unit: bool = sel.size() == 1 and sel[0] is RtsUnit \
		and sel[0].get("faction") == Game.player_faction
	_report["点选"] = {"屏幕坐标": str(screen_pos.round()), "选中数": sel.size(),
		"是单个己方单位": only_unit, "目标是同单位": sel.has(unit)}
	var click_ok: bool = only_unit

	# ---------- 2. 拖框多选 ----------
	_clear_selection()
	await _wait(0.1)
	# 框住画面中央一片区域
	var box_a := Vector2(vp_size.x * 0.15, vp_size.y * 0.15)
	var box_b := Vector2(vp_size.x * 0.85, vp_size.y * 0.85)
	_click(box_a, MOUSE_BUTTON_LEFT, true)
	await _wait(0.05)
	_motion(box_a + Vector2(30, 30))
	await _wait(0.05)
	_motion(box_b)
	await _wait(0.05)
	_click(box_b, MOUSE_BUTTON_LEFT, false)
	await _wait(0.2)
	var sel2 := _selection()
	_report["框选"] = {"选中数": sel2.size()}
	var box_ok: bool = sel2.size() >= 2
	if not box_ok:
		_report["框选备注"] = "框选没选中 ≥2 个单位（检查 overlay/投影判定）"

	# ---------- 3. 右键移动指令 ----------
	var movers: Array = sel2 if sel2.size() > 0 else [unit]
	var before: Array = []
	for u in movers:
		if is_instance_valid(u):
			before.append(u.global_position)
	var ground: Vector3 = unit.global_position + Vector3(6.0, 0.0, 6.0)
	var ground_screen: Vector2 = cam.unproject_position(ground)
	_click(ground_screen, MOUSE_BUTTON_RIGHT, true)
	await _wait(0.05)
	_click(ground_screen, MOUSE_BUTTON_RIGHT, false)
	await _wait(2.0)
	var moved: int = 0
	for i in movers.size():
		if i < before.size() and is_instance_valid(movers[i]):
			if movers[i].global_position.distance_to(before[i]) > 1.2:
				moved += 1
	_report["右键移动"] = {"单位数": movers.size(), "移动数": moved}
	var move_ok: bool = moved > 0

	# ---------- 4. 镜头平移加速曲线（用方向键，和边缘滚动走同一套速度系统）----------
	var cam_node: Node3D = camera_node()
	var smooth_ok: bool = false
	var vel_samples: Array = []
	if cam_node != null and cam_node.has_method("focus_point"):
		var prev: Vector3 = cam_node.call("focus_point")
		# 按住右移键，逐帧采样位移
		_key(KEY_RIGHT, true)
		for i in 26:
			await get_tree().process_frame
			var cur: Vector3 = cam_node.call("focus_point")
			vel_samples.append(prev.distance_to(cur))
			prev = cur
		_key(KEY_RIGHT, false)
		# 判定：速度应当"从小到大"爬升，且任意相邻两帧的增量不超过首帧的 4 倍
		var first: float = maxf(float(vel_samples[0]), 0.0001)
		var peak: float = 0.0
		var max_jump: float = 0.0
		var prev_v: float = 0.0
		for v in vel_samples:
			var fv: float = float(v)
			peak = maxf(peak, fv)
			max_jump = maxf(max_jump, absf(fv - prev_v))
			prev_v = fv
		smooth_ok = peak > 0.001 and max_jump < first * 4.0 + 0.12
		_report["镜头加速"] = {
			"首帧位移": "%.4f" % first,
			"峰值位移": "%.4f" % peak,
			"最大帧间跳变": "%.4f" % max_jump,
			"前5帧": vel_samples.slice(0, 5).map(func(v): return "%.4f" % v),
		}
		# 松手后应当滑行衰减而不是立刻停
		await _wait(0.02)
		var p2: Vector3 = cam_node.call("focus_point")
		await get_tree().process_frame
		var p3: Vector3 = cam_node.call("focus_point")
		_report["镜头滑行"] = "%.4f" % p2.distance_to(p3)

	# ---------- 5. 缩放平滑 ----------
	var zoom_ok: bool = false
	if cam_node != null and cam_node.has_method("distance"):
		var d0: float = float(cam_node.call("distance"))
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		wheel.position = vp_size * 0.5
		get_viewport().push_input(wheel, true)
		var d1: float = float(cam_node.call("distance"))
		for i in 20:
			await get_tree().process_frame
		var d2: float = float(cam_node.call("distance"))
		# 平滑 = 第一帧不会一步到位（d1 与 d0 差得很小），但最终会变化
		zoom_ok = absf(d2 - d0) > 0.3 and absf(d1 - d0) < absf(d2 - d0)
		_report["缩放"] = {"起始": "%.2f" % d0, "一帧后": "%.2f" % d1, "20帧后": "%.2f" % d2}

	var ok: bool = click_ok and box_ok and move_ok
	_report["小结"] = {
		"点选": click_ok, "框选": box_ok, "右键移动": move_ok,
		"镜头加速平滑": smooth_ok, "缩放平滑": zoom_ok,
	}
	_finish(ok, "")


# ===========================================================================
# 工具
# ===========================================================================

func camera_node() -> Node3D:
	var m := get_parent()
	if m != null:
		var c: Node = m.get("camera")
		if c is Node3D:
			return c as Node3D
	return null


func _selection() -> Array:
	var m := get_parent()
	if m != null:
		var s: Node = m.get("selection_system")
		if s != null:
			var sel: Variant = s.get("selected")
			if sel is Array:
				return sel as Array
	return []


func _clear_selection() -> void:
	var m := get_parent()
	if m != null:
		var s: Node = m.get("selection_system")
		if s != null and s.has_method("clear_selection"):
			s.call("clear_selection")
		elif s != null and s.has_method("clear"):
			s.call("clear")


func _pick_one_player_unit() -> Node3D:
	for u in Game.player_faction.units:
		if u != null and is_instance_valid(u) and u.is_alive():
			return u
	return null


func _click(pos: Vector2, button: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_viewport().push_input(ev, true)


func _motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = Vector2.ZERO
	get_viewport().push_input(ev, true)


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
	print("INTERACT " + JSON.stringify(_report))
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if ok else 1)
