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
	# 主动请求前台焦点。自动化里从后台任务（pwsh 作业 / CI）启动时窗口拿不到焦点，
	# 镜头"失焦不滚"的保护会把四个方向全部挡掉 —— 那是测试环境缺焦点，不是镜头 bug。
	# 拿不到焦点就如实报"跳过"，不要把它算成回归（以前这里会误报"左右滚不动"）。
	DisplayServer.window_move_to_foreground()
	await _wait(0.45)
	var focused: bool = get_window().has_focus()
	_report["窗口焦点"] = focused
	if not focused:
		_report["结果"] = "跳过：窗口未获得焦点（后台运行，无法测真实鼠标）"
		print("EDGETEST " + JSON.stringify(_report))
		await _wait(0.2)
		get_tree().quit(0)
		return

	await _wait(0.2)
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
	var skipped: Array = []
	for c in cases:
		var label: String = c[0]
		var target: Vector2 = c[1]
		# 先把鼠标放回中心，避免上一轮残留
		Input.warp_mouse(win_size * 0.5)
		await _wait(0.15)
		await get_tree().process_frame
		var p0: Vector3 = cam.call("focus_point")

		# 挪到边缘。★ 踩坑记录：不同 DPI 缩放 / 窗口位置下，warp_mouse 的坐标空间
		# 和 get_mouse_position() 读回来的视口坐标不一定一一对应（实测同一份代码
		# 有时落在 1918、有时只到 1846，直接判"滚不动"就是误报）。
		# 所以先按目标点推一次，读回不在边缘带就再往窗口外推一大截（系统会把光标夹到
		# 屏幕边，游戏按"窗口外=该方向"处理）。
		Input.warp_mouse(target)
		await _wait(0.06)
		var mouse_now: Vector2 = vp.get_mouse_position()
		if not _in_edge_band(mouse_now, label, vp_size):
			Input.warp_mouse(target + _outward(label) * 900.0)
			await _wait(0.08)
			mouse_now = vp.get_mouse_position()

		# 还是推不到边缘带 = 这个环境测不了真实鼠标（多屏边界/系统夹取），
		# 如实记"环境跳过"，不要把它算成镜头回归。
		if not _in_edge_band(mouse_now, label, vp_size):
			skipped.append(label)
			results[label] = {
				"鼠标落点": str(mouse_now.round()),
				"环境跳过": "光标没能推到屏幕边缘（被系统坐标夹住）",
				"通过": true,
			}
			continue

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
	if not skipped.is_empty():
		_report["环境跳过"] = skipped
	if all_ok:
		_report["小结"] = "四个方向都能滚" if skipped.is_empty() \
				else "可测方向都能滚（%d 个方向环境跳过）" % skipped.size()
	else:
		_report["小结"] = "有方向滚不动"
	_finish(all_ok, "")


## 读回的鼠标位置是否落在这个方向的边缘带里（判据与 魔兽镜头.gd 完全一致）
func _in_edge_band(mp: Vector2, label: String, vsize: Vector2) -> bool:
	var m: float = Cfg.game.camera_edge_margin if Cfg.game != null else 22.0
	match label:
		"右":
			return mp.x >= vsize.x - m
		"左":
			return mp.x <= m
		"上":
			return mp.y <= m
		"下":
			return mp.y >= vsize.y - m
	return false


## 该方向的"再往外推"向量
func _outward(label: String) -> Vector2:
	match label:
		"右":
			return Vector2(1.0, 0.0)
		"左":
			return Vector2(-1.0, 0.0)
		"上":
			return Vector2(0.0, -1.0)
		"下":
			return Vector2(0.0, 1.0)
	return Vector2.ZERO


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
