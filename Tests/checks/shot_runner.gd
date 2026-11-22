extends Node
## 职责：run-game --shot 的执行器（离屏/窗口外开一个画面、截图、必要时真点一次按钮）
## 属于：Tests/checks
## 用法：godot --path . --resolution 1600x900 res://Tests/checks/shot_runner.tscn -- \
##          --screen=hud --shot-out=D:/x.png --offscreen
## 纪律：
##   · 截图只证明画出来了，不证明点得动 —— 配了 click 就必须用真实输入事件点，并用 expect 验状态；
##   · 点不动 / 找不到 / 状态没变 → 打印 SHOT FAIL 并退出码 1。

const JsonFile := preload("res://Engine/util/json_file.gd")
const Screenshot := preload("res://Engine/debug/screenshot.gd")
const SCREENS := "res://Content/data/screens.json"

var _screen := "main"
var _out := ""
var _scene: Node = null


func _ready() -> void:
	call_deferred("_run")


func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix + "="):
			return a.substr(prefix.length() + 1)
	return ""


func _fail(reason: String) -> void:
	print("SHOT FAIL %s" % reason)
	get_tree().quit(1)


func _run() -> void:
	_screen = _arg("--screen")
	if _screen.is_empty():
		_screen = "main"
	_out = _arg("--shot-out")
	if _out.is_empty():
		_fail("缺 --shot-out")
		return
	var data := JsonFile.read_dict(SCREENS, {})
	var recipes: Dictionary = data.get("screens", {})
	if not recipes.has(_screen):
		_fail("没有这个画面：%s（现有：%s）" % [_screen, ", ".join(recipes.keys())])
		return
	var recipe: Dictionary = recipes[_screen]
	# --- 可选：把客户区钉成精确像素（1920x1080 会被任务栏裁成 1061，验收要的是原尺寸）---
	var size_arg := _arg("--shot-size")
	if not size_arg.is_empty():
		var parts := size_arg.split("x")
		if parts.size() == 2:
			var want := Vector2i(int(parts[0]), int(parts[1]))
			get_window().size = want
			await get_tree().process_frame
			await get_tree().process_frame
			print("[shot] 客户区 %s（请求 %s）" % [str(get_window().size), size_arg])
	var scene_path := String(recipe.get("scene", "res://Screens/scenes/主场景.tscn"))
	var packed: PackedScene = load(scene_path)
	if packed == null:
		_fail("场景加载失败：" + scene_path)
		return
	_scene = packed.instantiate()
	add_child(_scene)
	await get_tree().create_timer(float(recipe.get("delay", 8.0))).timeout
	await get_tree().process_frame

	# --- 可选：拍"干净 3D 实景"（主题陈列室背景用）---
	# hide_ui：收掉所有 CanvasLayer（HUD/气泡/光标），只留 3D；hide_nodes：按名字再收几个 3D 层。
	if bool(recipe.get("hide_ui", false)):
		var hid := 0
		for c in _scene.get_children():
			if c is CanvasLayer:
				(c as CanvasLayer).visible = false
				hid += 1
		print("[shot] hide_ui 收起 %d 个 CanvasLayer" % hid)
	for n in (recipe.get("hide_nodes", []) as Array):
		var hn := _find(_scene, String(n))
		if hn is Node3D:
			(hn as Node3D).visible = false
		elif hn is CanvasItem:
			(hn as CanvasItem).visible = false
		else:
			_fail("hide_nodes 找不到可隐藏的节点：" + String(n))
			return
	if recipe.has("hide_ui") or recipe.has("hide_nodes"):
		await get_tree().create_timer(0.3).timeout
		await get_tree().process_frame

	if recipe.has("select_unit"):
		var unit_id := String(recipe["select_unit"])
		if not _select_unit(unit_id):
			_fail("没有可选的 %s（关卡还没就绪？）" % unit_id)
			return
		await get_tree().create_timer(0.3).timeout

	# --- 可选：把鼠标悬停在某个控件上（验收 tooltip：气泡层在规划阶段必须还能弹） ---
	if recipe.has("hover_control"):
		var hname := String(recipe["hover_control"])
		var hn := _find(_scene, hname)
		if hn == null or not (hn is Control):
			_fail("找不到要悬停的控件：" + hname)
			return
		var hc := hn as Control
		var hc_pos := hc.get_global_rect().get_center()
		var hm := InputEventMouseMotion.new()
		hm.position = hc_pos
		hm.global_position = hc_pos
		get_viewport().push_input(hm, true)
		await get_tree().create_timer(float(recipe.get("hover_wait", 1.0))).timeout
		# 只有悬停、没有点击的配方也要验 expect（否则 tooltip 这类"悬停才出现"的断言是假的）
		if not recipe.has("click") and recipe.has("expect"):
			var en := String(recipe["expect"])
			var ec := _find(_scene, en)
			if ec == null or not (ec is Control) or not (ec as Control).is_visible_in_tree():
				_fail("悬停 %s 但 %s 没出现" % [hname, en])
				return
			print("[shot] 交互通过：悬停 %s → %s 出现" % [hname, en])

	if recipe.has("click"):
		var click_name := String(recipe["click"])
		var node := _find(_scene, click_name)
		if node == null:
			_fail("找不到要点的控件：" + click_name)
			return
		if not (node is Control):
			_fail("节点不是 Control：" + click_name)
			return
		var ctrl := node as Control
		if not ctrl.is_visible_in_tree():
			_fail("控件不可见：" + click_name)
			return
		var center := ctrl.get_global_rect().get_center()
		var vp := get_viewport()
		var motion := InputEventMouseMotion.new()
		motion.position = center
		motion.global_position = center
		vp.push_input(motion, true)
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		down.position = center
		down.global_position = center
		vp.push_input(down, true)
		await get_tree().process_frame
		var up: InputEventMouseButton = down.duplicate()
		up.pressed = false
		vp.push_input(up, true)
		await get_tree().create_timer(0.35).timeout
		var expect_name := String(recipe.get("expect", ""))
		if expect_name.is_empty():
			if not recipe.has("expect_scene_state"):
				_fail("画面配了 click 却没有 expect（点完拿什么判定？）")
				return
		else:
			var expect := _find(_scene, expect_name)
			if expect == null or not (expect is Control) or not (expect as Control).is_visible_in_tree():
				_fail("点了 %s 但 %s 没出现（点不动 / 事件没进去）" % [click_name, expect_name])
				return
			print("[shot] 交互通过：点击 %s → %s 出现" % [click_name, expect_name])

	# --- 可选：一次点多个控件（主题陈列室这类"多按钮各点一下"的验收）---
	# 每项：{click, expect?, expect_state?[属性, 子串], wait?}
	# 纪律：每一项都要有自己的断言（expect 或 expect_state），不许"只点不验"。
	if recipe.has("clicks"):
		var jobs: Array = recipe["clicks"]
		if jobs.is_empty():
			_fail("clicks 是空数组（配了就要点）")
			return
		for job in jobs:
			var jd: Dictionary = job
			var click_name := String(jd.get("click", ""))
			if click_name.is_empty():
				_fail("clicks 里有一项没写 click")
				return
			if not await _click_control(click_name):
				return
			var expect_name := String(jd.get("expect", ""))
			if not expect_name.is_empty():
				if not _shown(expect_name):
					_fail("点了 %s 但 %s 没出现（点不动 / 事件没进去）" % [click_name, expect_name])
					return
				print("[shot] 交互通过：点击 %s → %s 出现" % [click_name, expect_name])
			if jd.has("expect_state"):
				if not _assert_state(jd["expect_state"] as Array):
					return
			if expect_name.is_empty() and not jd.has("expect_state"):
				_fail("clicks 里的 %s 没有 expect / expect_state（点了拿什么判定？）" % click_name)
				return
			await get_tree().create_timer(float(jd.get("wait", 0.25))).timeout

	# --- 可选：摆一个固定机位（证明"地块有厚度"这类需要低机位的验收） ---
	if recipe.has("shot_camera"):
		if not _scene.has_method("apply_shot_camera"):
			_fail("scene has no apply_shot_camera")
			return
		_scene.call("apply_shot_camera", recipe["shot_camera"])
		await get_tree().create_timer(0.4).timeout
		print("[shot] camera applied")

	# --- 可选：只把鼠标移到地图上（不点）—— 验收"部署预览跟着鼠标画" ---
	if recipe.has("hover_map"):
		var hf: Array = recipe["hover_map"]
		var vp3 := get_viewport()
		var vs3: Vector2 = vp3.get_visible_rect().size
		var hp3 := Vector2(vs3.x * float(hf[0]), vs3.y * float(hf[1]))
		var m3 := InputEventMouseMotion.new()
		m3.position = hp3
		m3.global_position = hp3
		vp3.push_input(m3, true)
		await get_tree().create_timer(0.25).timeout
		print("[shot] 地图悬停 (%.0f, %.0f)" % [hp3.x, hp3.y])

	# --- 可选：在地图上再点一次（验收"二段式部署"这类交互的第二步） ---
	if recipe.has("map_click"):
		var frac: Array = recipe["map_click"]
		var vp2 := get_viewport()
		var vs: Vector2 = vp2.get_visible_rect().size
		var pos := Vector2(vs.x * float(frac[0]), vs.y * float(frac[1]))
		var m2 := InputEventMouseMotion.new()
		m2.position = pos
		m2.global_position = pos
		vp2.push_input(m2, true)
		await get_tree().process_frame
		var d2 := InputEventMouseButton.new()
		d2.button_index = MOUSE_BUTTON_LEFT
		d2.pressed = true
		d2.position = pos
		d2.global_position = pos
		vp2.push_input(d2, true)
		await get_tree().process_frame
		var u2: InputEventMouseButton = d2.duplicate()
		u2.pressed = false
		vp2.push_input(u2, true)
		await get_tree().create_timer(0.35).timeout
		print("[shot] 地图点击 (%.0f, %.0f)" % [pos.x, pos.y])


	# --- 可选：小队战场放一支敌方演示队（验证右键集火能点到敌人） ---
	if recipe.has("squad_spawn_enemy"):
		if not _scene.has_method("spawn_enemy_demo"):
			_fail("scene has no spawn_enemy_demo")
			return
		_scene.call("spawn_enemy_demo")
		await get_tree().process_frame
		print("[shot] squad enemy spawned")

	# --- 可选：真实左键拖框（框选整队） ---
	if recipe.has("map_drag"):
		var da: Array = recipe["map_drag"]
		if da.size() < 4:
			_fail("map_drag needs [x0,y0,x1,y1]")
			return
		var vpd := get_viewport()
		var vsd: Vector2 = vpd.get_visible_rect().size
		var p0 := Vector2(vsd.x * float(da[0]), vsd.y * float(da[1]))
		var p1 := Vector2(vsd.x * float(da[2]), vsd.y * float(da[3]))
		var mv0 := InputEventMouseMotion.new()
		mv0.position = p0
		mv0.global_position = p0
		vpd.push_input(mv0, true)
		var dn := InputEventMouseButton.new()
		dn.button_index = MOUSE_BUTTON_LEFT
		dn.pressed = true
		dn.position = p0
		dn.global_position = p0
		vpd.push_input(dn, true)
		await get_tree().process_frame
		var mv1 := InputEventMouseMotion.new()
		mv1.position = p1
		mv1.global_position = p1
		vpd.push_input(mv1, true)
		await get_tree().process_frame
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.pressed = false
		up.position = p1
		up.global_position = p1
		vpd.push_input(up, true)
		await get_tree().create_timer(0.35).timeout
		print("[shot] map drag")

	# --- 可选：真实按键（倍速 1/2 / 全选 SPACE；H/S/A 旧微操已随 2026-11-21 收敛下线） ---
	if recipe.has("press_key"):
		var kn := String(recipe["press_key"]).to_upper()
		var code := KEY_NONE
		match kn:
			"H": code = KEY_H
			"S": code = KEY_S
			"A": code = KEY_A
			"1": code = KEY_1
			"2": code = KEY_2
			"SPACE": code = KEY_SPACE
		if code == KEY_NONE:
			_fail("unsupported key: " + kn)
			return
		var kd := InputEventKey.new()
		kd.keycode = code
		kd.physical_keycode = code
		kd.pressed = true
		get_viewport().push_input(kd, true)
		await get_tree().process_frame
		var ku: InputEventKey = kd.duplicate()
		ku.pressed = false
		get_viewport().push_input(ku, true)
		await get_tree().create_timer(0.2).timeout
		print("[shot] key " + kn)

	# --- 可选：右键点"敌方小队"（真实输入事件；焦点集火） ---
	if recipe.has("map_right_click_enemy"):
		if not _scene.has_method("screen_pos_of_enemy"):
			_fail("scene has no screen_pos_of_enemy")
			return
		var ep: Vector2 = _scene.call("screen_pos_of_enemy")
		if ep.x < 0.0:
			_fail("no enemy squad to right-click")
			return
		var vpe := get_viewport()
		var me := InputEventMouseMotion.new()
		me.position = ep
		me.global_position = ep
		vpe.push_input(me, true)
		await get_tree().process_frame
		var de := InputEventMouseButton.new()
		de.button_index = MOUSE_BUTTON_RIGHT
		de.pressed = true
		de.position = ep
		de.global_position = ep
		vpe.push_input(de, true)
		await get_tree().process_frame
		var ue: InputEventMouseButton = de.duplicate()
		ue.pressed = false
		vpe.push_input(ue, true)
		await get_tree().create_timer(0.35).timeout
		print("[shot] map right click enemy")

	# --- 可选：小队战场全选（真实交互链：先全选，再右键地图下令） ---
	if recipe.has("squad_select_all"):
		if not _scene.has_method("select_all_squads"):
			_fail("scene has no select_all_squads")
			return
		_scene.call("select_all_squads")
		await get_tree().process_frame
		print("[shot] squad select all")

	# --- 可选：在地图上右键一次（小队移动/集火；真实输入事件） ---
	if recipe.has("map_right_click"):
		var rf: Array = recipe["map_right_click"]
		var vpr := get_viewport()
		var vsr: Vector2 = vpr.get_visible_rect().size
		var rpos := Vector2(vsr.x * float(rf[0]), vsr.y * float(rf[1]))
		var rm := InputEventMouseMotion.new()
		rm.position = rpos
		rm.global_position = rpos
		vpr.push_input(rm, true)
		await get_tree().process_frame
		var rd := InputEventMouseButton.new()
		rd.button_index = MOUSE_BUTTON_RIGHT
		rd.pressed = true
		rd.position = rpos
		rd.global_position = rpos
		vpr.push_input(rd, true)
		await get_tree().process_frame
		var ru: InputEventMouseButton = rd.duplicate()
		ru.pressed = false
		vpr.push_input(ru, true)
		await get_tree().create_timer(0.35).timeout
		print("[shot] map right click (%.0f, %.0f)" % [rpos.x, rpos.y])

	# --- 可选：读取场景属性做状态断言（例如 last_order 必须包含某个词） ---
	if recipe.has("expect_scene_state"):
		var pair: Array = recipe["expect_scene_state"]
		if pair.size() < 2:
			_fail("expect_scene_state needs [property, substring]")
			return
		var prop := String(pair[0])
		var needle := String(pair[1])
		var got := str(_scene.get(prop))
		if not got.contains(needle):
			_fail("scene.%s = '%s' (want '%s')" % [prop, got, needle])
			return
		print("[shot] state ok: %s = %s" % [prop, got])

	# --- 可选：点规划阶段的兵牌（真实输入事件；2026-11-15 玩家要求"点兵牌有反应"） ---
	if recipe.has("token_click"):
		var tid := String(recipe["token_click"])
		var hud_n := _find(_scene, "界面")
		if hud_n == null:
			_fail("找不到界面，无法点兵牌")
			return
		var pmap: Variant = hud_n.get("_planning_map")
		if pmap == null:
			_fail("规划地图层没建好")
			return
		var tr: Rect2 = pmap.call("token_rect_of_id", tid, true)
		if tr.size.x <= 1.0:
			_fail("找不到可点的兵牌：" + tid)
			return
		var tp: Vector2 = tr.get_center()
		var mm := InputEventMouseMotion.new()
		mm.position = tp
		mm.global_position = tp
		get_viewport().push_input(mm, true)
		await get_tree().process_frame
		var dm := InputEventMouseButton.new()
		dm.button_index = MOUSE_BUTTON_LEFT
		dm.pressed = true
		dm.position = tp
		dm.global_position = tp
		get_viewport().push_input(dm, true)
		await get_tree().process_frame
		var um: InputEventMouseButton = dm.duplicate()
		um.pressed = false
		get_viewport().push_input(um, true)
		await get_tree().create_timer(float(recipe.get("wait_after", 0.35))).timeout
		var want := String(recipe.get("expect", ""))
		if want.is_empty():
			_fail("token_click 必须配 expect（点了兵牌要验面板出现）")
			return
		var want_n := _find(_scene, want)
		if want_n == null or not (want_n is Control) or not (want_n as Control).is_visible_in_tree():
			_fail("点了兵牌 %s 但 %s 没出现" % [tid, want])
			return
		print("[shot] 交互通过：点击兵牌 %s → %s 出现" % [tid, want])
	# --- 可选：点了以后必须真的产生计划命令（部署/移动这类"点地图"的验收） ---
	if recipe.has("expect_planned"):
		var want_n := int(recipe["expect_planned"])
		var cmd: Variant = null
		for c in _scene.get_children():
			if String(c.name) == "指令系统":
				cmd = c
				break
		if cmd == null or not cmd.has_method("planned_count"):
			_fail("找不到指令系统，无法验证计划条数")
			return
		var got_n := int(cmd.call("planned_count"))
		if got_n < want_n:
			_fail("点了地图但计划条数没涨（期望 ≥%d，实际 %d）" % [want_n, got_n])
			return
		print("[shot] 交互通过：计划条数 = %d" % got_n)

	# --- 可选：所有交互跑完后**额外等一会**（过场/动画类画面：镜头拉近、网格淡出）---
	# 只在配方写了 wait_after 时才生效；不写就等于原来的"立刻截"。
	if recipe.has("wait_after"):
		var extra := maxf(float(recipe["wait_after"]), 0.0)
		await get_tree().create_timer(extra).timeout
		print("[shot] 额外等待 %.2fs" % extra)
		var cam_node := _find(_scene, "镜头")
		if cam_node != null and cam_node.has_method("distance"):
			print("[shot] 镜头 距离=%.1f 焦点=%s 锁定=%s" % [
				float(cam_node.call("distance")),
				str(cam_node.call("focus_point")),
				str(cam_node.call("is_locked"))])

	await RenderingServer.frame_post_draw
	var saved := Screenshot.capture(_out, get_viewport())
	if saved.is_empty():
		_fail("截图失败：" + _out)
		return
	var size := FileAccess.get_file_as_bytes(_out).size()
	if size <= 0:
		_fail("截图是空文件：" + _out)
		return
	print("SHOT PASS %s（%s，%d 字节）" % [saved, _screen, size])
	get_tree().quit(0)


## 用**真实鼠标事件**点一个控件（motion → down → up），并等按钮把状态改完。
func _click_control(click_name: String) -> bool:
	var node := _find(_scene, click_name)
	if node == null:
		_fail("找不到要点的控件：" + click_name)
		return false
	if not (node is Control):
		_fail("节点不是 Control：" + click_name)
		return false
	var ctrl := node as Control
	if not ctrl.is_visible_in_tree():
		_fail("控件不可见：" + click_name)
		return false
	var center := ctrl.get_global_rect().get_center()
	var vp := get_viewport()
	var motion := InputEventMouseMotion.new()
	motion.position = center
	motion.global_position = center
	vp.push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = center
	down.global_position = center
	vp.push_input(down, true)
	await get_tree().process_frame
	var up: InputEventMouseButton = down.duplicate()
	up.pressed = false
	vp.push_input(up, true)
	await get_tree().create_timer(0.35).timeout
	return true


## 控件存在且真的在树里可见。
func _shown(node_name: String) -> bool:
	var n := _find(_scene, node_name)
	return n != null and n is Control and (n as Control).is_visible_in_tree()


## 读场景属性做状态断言：[属性名, 必须包含的子串]。
func _assert_state(pair: Array) -> bool:
	if pair.size() < 2:
		_fail("expect_state needs [property, substring]")
		return false
	var got := str(_scene.get(String(pair[0])))
	if not got.contains(String(pair[1])):
		_fail("scene.%s = '%s' (want '%s')" % [pair[0], got, pair[1]])
		return false
	print("[shot] state ok: %s = %s" % [pair[0], got])
	return true


func _select_unit(unit_id: String) -> bool:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return false
	var game := (loop as SceneTree).root.get_node_or_null("Game")
	if game == null:
		return false
	var faction: Variant = game.get("player_faction")
	if faction == null:
		return false
	var picked: Array = []
	for u in faction.get("units"):
		if u == null or not is_instance_valid(u):
			continue
		var d: Variant = u.get("def")
		if d != null and String(d.get("id")) == unit_id:
			picked.append(u)
	if picked.is_empty():
		return false
	var sel: Variant = _scene.get("selection_system")
	if sel == null or not sel.has_method("select_units"):
		return false
	sel.call("select_units", picked)
	return true


func _find(root: Node, target: String) -> Node:
	if root.name == target:
		return root
	for c in root.get_children():
		var hit := _find(c, target)
		if hit != null:
			return hit
	return null
