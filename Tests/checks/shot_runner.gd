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
	var scene_path := String(recipe.get("scene", "res://Views/scenes/主场景.tscn"))
	var packed: PackedScene = load(scene_path)
	if packed == null:
		_fail("场景加载失败：" + scene_path)
		return
	_scene = packed.instantiate()
	add_child(_scene)
	await get_tree().create_timer(float(recipe.get("delay", 8.0))).timeout
	await get_tree().process_frame

	if recipe.has("select_unit"):
		var unit_id := String(recipe["select_unit"])
		if not _select_unit(unit_id):
			_fail("没有可选的 %s（关卡还没就绪？）" % unit_id)
			return
		await get_tree().create_timer(0.3).timeout

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
			_fail("画面配了 click 却没有 expect（点完拿什么判定？）")
			return
		var expect := _find(_scene, expect_name)
		if expect == null or not (expect is Control) or not (expect as Control).is_visible_in_tree():
			_fail("点了 %s 但 %s 没出现（点不动 / 事件没进去）" % [click_name, expect_name])
			return
		print("[shot] 交互通过：点击 %s → %s 出现" % [click_name, expect_name])

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
