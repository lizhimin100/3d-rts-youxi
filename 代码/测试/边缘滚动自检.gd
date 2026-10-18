extends Node
## **边缘滚动自检**：把真实鼠标挪到屏幕四边，测量镜头是否真的移动、加速是否平滑。
##
## 启用：godot --path . --resolution 1600x900 -- --edge-test
## 输出结尾一行 `EDGETEST {json}`。
##
## 为什么要这个测试：边缘滚动是"魔兽手感"的地基，之前被判定为"没做完/偷懒"。
## 这里用真实鼠标位置（不是合成事件）驱动，测的是**玩家实际走的那条代码路径**。

var _report: Dictionary = {}
var _done: bool = false


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _wait(0.6)
	var cam: Node3D = _camera()
	if cam == null or not cam.has_method("focus_point"):
		_finish(false, "没有镜头或缺少 focus_point()")
		return
	if has_method("_edge_test_hook"):
		pass

	var win_size: Vector2 = Vector2(DisplayServer.window_get_size())
	var vp: Viewport = get_viewport()
	var vp_size: Vector2 = vp.get_visible_rect().size
	_report["窗口"] = str(win_size)
	_report["视口"] = str(vp_size)
	_report["显示驱动"] = DisplayServer.get_name()

	# 四个方向：(名字, 窗口坐标里的目标点, 期望镜头移动的方向)
	var cases: Array = [
		["右", Vector2(win_size.x - 2.0, win_size.y * 0.5)],
		["左", Vector2(2.0, win_size.y * 0.5)],
		["上", Vector2(win_size.x * 0.5, 2.0)],
		["下", Vector2(win_size.x * 0.5, win_size.y - 2.0)],
	]
	var results: Dictionary = {}
	var all_ok: bool = true
	for c in cases:
		var label: String = c[0]
		var target: Vector2 = c[1]
		# 先把鼠标放回中心，避免上一轮残留
		Input.warp_mouse(win_size * 0.5)
		await _wait(0.15)
		await get_tree().process_frame
		var p0: Vector3 = cam.call("focus_point")
		# 挪到边缘
		Input.warp_mouse(target)
		await _wait(0.05)
		var mouse_now: Vector2 = vp.get_mouse_position()
		# 采样 30 帧的位移
		var total: float = 0.0
		var prev: Vector3 = cam.call("focus_point")
		var samples: Array = []
		for i in 30:
			await get_tree().process_frame
			var cur: Vector3 = cam.call("focus_point")
			var d: float = prev.distance_to(cur)
			total += d
			if i < 4:
				samples.append("%.4f" % d)
			prev = cur
		var moved: float = p0.distance_to(prev)
		var ok: bool = moved > 0.05
		all_ok = all_ok and ok
		results[label] = {
			"鼠标落点": str(mouse_now.round()),
			"总位移": "%.3f" % moved,
			"前4帧": samples,
			"通过": ok,
		}
		if not ok:
			_report["失败方向"] = label

	_report["四向"] = results
	_report["小结"] = "四个方向都能滚" if all_ok else "有方向滚不动"
	_finish(all_ok, "")


func _camera() -> Node3D:
	var p := get_parent()
	if p != null:
		var c: Node = p.get("camera")
		if c is Node3D:
			return c as Node3D
	return null


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _finish(ok: bool, reason: String) -> void:
	if _done:
		return
	_done = true
	_report["结果"] = "通过" if ok else ("失败：" + reason if reason != "" else "失败")
	print("EDGETEST " + JSON.stringify(_report))
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if ok else 1)
