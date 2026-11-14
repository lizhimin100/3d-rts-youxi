extends RefCounted
## 职责：把**游戏侧**的状态与动作挂到 Engine/debug 的 HTTP 接口上
## 属于：Game/core（引擎层不认识玩法，所以钩子必须住在游戏这一侧）
## 对外：install(bridge)
## 禁改：不要在引擎层写死"金币/人口"这类玩法字段；只在快照里出现，且只读。

var _bridge: Node = null


func install(bridge: Node) -> void:
	if bridge == null:
		return
	_bridge = bridge
	bridge.call("register_state", Callable(self, "snapshot"))
	bridge.call("register_action", "select_all", Callable(self, "act_select_all"))
	bridge.call("register_action", "click_ui", Callable(self, "act_click_ui"))
	bridge.call("register_action", "camera_focus", Callable(self, "act_camera_focus"))
	bridge.call("register_action", "set_speed", Callable(self, "act_set_speed"))
	bridge.call("register_action", "spawn", Callable(self, "act_spawn"))


## 当前状态快照（调试接口 /state 返回这个）
func snapshot() -> Dictionary:
	var out := {
		"boot": App.boot_report(),
		"fps": Engine.get_frames_per_second(),
		"time_scale": Engine.time_scale,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"scene": "",
		"phase": -1,
		"elapsed": 0.0,
		"difficulty": -1,
		"selection": 0,
		"factions": [],
	}
	var scene := _scene()
	if scene != null:
		out["scene"] = scene.name
	var game := _game()
	if game == null:
		return out
	out["phase"] = int(game.get("phase"))
	out["elapsed"] = float(game.get("elapsed"))
	out["difficulty"] = int(game.get("difficulty_index"))
	var factions: Array = []
	for f in game.get("factions"):
		if f == null:
			continue
		factions.append({
			"slot": int(f.get("slot")),
			"team": int(f.get("team")),
			"name": String(f.get("display_name")),
			"is_player": bool(f.get("is_player")),
			"is_ai": bool(f.get("is_ai")),
			"gold": int(f.get("gold")),
			"wood": int(f.get("wood")),
			"units": (f.get("units") as Array).size(),
			"buildings": (f.get("buildings") as Array).size(),
		})
	out["factions"] = factions
	var sel := _selection()
	if sel != null:
		out["selection"] = (sel.call("selected_units") as Array).size()
	return out


# ===========================================================================
# 动作（全部走真实代码路径；能点 UI 的就不直接改状态）
# ===========================================================================
func act_select_all(_args: Dictionary = {}) -> Dictionary:
	var game := _game()
	var sel := _selection()
	if game == null or sel == null:
		return {"ok": false, "error": "游戏还没开局（没有 Game/选择系统）"}
	var faction: Variant = game.get("player_faction")
	if faction == null:
		return {"ok": false, "error": "没有玩家阵营"}
	var list: Array = []
	for u in faction.get("units"):
		if u != null and is_instance_valid(u):
			list.append(u)
	sel.call("select_units", list)
	return {"ok": true, "selected": list.size()}


## 用**真实输入事件**点一个 Control（不是直接调它的信号）
func act_click_ui(args: Dictionary = {}) -> Dictionary:
	var name := String(args.get("name", ""))
	if name.is_empty():
		return {"ok": false, "error": "缺少 name"}
	var root := _scene()
	if root == null:
		return {"ok": false, "error": "没有当前场景"}
	var node := _find_by_name(root, name)
	if node == null:
		return {"ok": false, "error": "找不到节点：" + name}
	if not (node is Control):
		return {"ok": false, "error": "节点不是 Control：" + name}
	var control := node as Control
	var center := control.get_global_rect().get_center()
	var vp := root.get_viewport()
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
	var up: InputEventMouseButton = down.duplicate()
	up.pressed = false
	vp.push_input(up, true)
	return {"ok": true, "node": name, "at": [center.x, center.y], "visible": control.is_visible_in_tree()}


func act_camera_focus(args: Dictionary = {}) -> Dictionary:
	var scene := _scene()
	if scene == null:
		return {"ok": false, "error": "没有当前场景"}
	var cam: Variant = scene.get("camera")
	if cam == null:
		return {"ok": false, "error": "没有镜头"}
	var pos := Vector3(float(args.get("x", 0.0)), 0.0, float(args.get("z", 0.0)))
	if cam.has_method("focus_on"):
		cam.call("focus_on", pos)
	elif cam.has_method("focus_point"):
		cam.call("focus_point", pos)
	else:
		return {"ok": false, "error": "镜头没有 focus_on/focus_point"}
	return {"ok": true, "x": pos.x, "z": pos.z}


func act_set_speed(args: Dictionary = {}) -> Dictionary:
	var v := float(args.get("value", 1.0))
	if v <= 0.0 or v > 32.0:
		return {"ok": false, "error": "倍速必须在 (0, 32]"}
	Engine.time_scale = v
	return {"ok": true, "time_scale": Engine.time_scale}


func act_spawn(args: Dictionary = {}) -> Dictionary:
	var game := _game()
	if game == null:
		return {"ok": false, "error": "游戏还没开局"}
	var id := StringName(String(args.get("id", "")))
	if id == &"":
		return {"ok": false, "error": "缺少 id"}
	var faction: Variant = game.get("player_faction")
	var slot := int(args.get("slot", -1))
	if slot >= 0:
		var list: Array = game.get("factions")
		if slot >= list.size():
			return {"ok": false, "error": "槽位越界"}
		faction = list[slot]
	var count := clampi(int(args.get("count", 1)), 1, 50)
	var base := Vector3(float(args.get("x", 0.0)), 0.0, float(args.get("z", 0.0)))
	var spawned: Array = []
	for i in count:
		var pos := base + Vector3(float(i % 5) * 1.2, 0.0, float(i / 5) * 1.2)
		var u: Variant = game.call("spawn_unit", faction, id, pos)
		spawned.append(str(u))
	return {"ok": true, "spawned": spawned.size()}


# ===========================================================================
func _game() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Game")
	return null


func _scene() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).current_scene
	return null


func _selection() -> Node:
	var scene := _scene()
	if scene == null:
		return null
	return scene.get("selection_system") as Node


func _find_by_name(root: Node, name: String) -> Node:
	if root.name == name:
		return root
	for c in root.get_children():
		var hit := _find_by_name(c, name)
		if hit != null:
			return hit
	return null
