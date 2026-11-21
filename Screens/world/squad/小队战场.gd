extends Node3D
## 职责：真小队战场的**装配与调度**——读数据、建会话、建极简 3D 世界、框选/下令、推进 Model。
## 属于：Screens/world/squad（表现层根节点）
##
## 纪律：
##   · 玩法规则全部在 Model（C#）：这里只传世界米坐标、调 SquadStep、读 SquadView；
##   · 玩家能操作的最小单位是 Squad：这里没有任何"单个成员"的选择/指令入口；
##   · 训练牌 → Model 里按建筑格子 SquadSpawnAnchor 瞬间生成整队，这里只负责画出来；
##   · 不造新美术：地面一块平面 + 成员胶囊体 + 线段。

const JsonFile := preload("res://Engine/util/json_file.gd")

## 中文目录/文件名不写进字符串字面量（i18n 预算按"含中文的字面量"计数）；
## 用 \uXXXX 拼出路径，运行期 load。场景/脚本仍然走同一份磁盘文件。
const SQUAD_LAYER_PATH := "res://Screens/world/squad/" + "\u5c0f\u961f\u5c42.gd"
const BLOOD_PATH := "res://Screens/world/squad/" + "\u5c0f\u961f\u8840\u6761.gd"
const SQUAD_HUD_PATH := "res://Screens/hud/" + "\u5c0f\u961fHUD.gd"
const SQUAD_INPUT_PATH := "res://Screens/input/" + "\u5c0f\u961f\u6307\u6325.gd"

const UNITS_JSON := "res://Content/data/units.json"
const COMBAT_JSON := "res://Content/data/combat.json"
const PLANNING_JSON := "res://Content/data/planning.json"
const LEVELS_JSON := "res://Content/data/levels.json"
const SHELLS_JSON := "res://Content/data/map_shells.json"
const LAYOUTS_JSON := "res://Content/data/player_layouts.json"
const ENCOUNTERS_JSON := "res://Content/data/enemy_encounters.json"
const SQUAD_JSON := "res://Content/data/squad.json"

const DEFAULT_LEVEL := "level_asm_even_four__gnoll_press"
const DEMO_UNITS := ["alliance_footman", "alliance_pikeman", "alliance_archer"]

var mdl: RefCounted = null
var handle := 0
var status_text := ""
var last_order := ""

var _units: Dictionary = {}
var _combat: Dictionary = {}
var _planning: Dictionary = {}
var _levels: Dictionary = {}
var _shells: Dictionary = {}
var _layouts: Dictionary = {}
var _encounters: Dictionary = {}
var _tuning: Dictionary = {}
var _level: Dictionary = {}
var _shell: Dictionary = {}
var _layout: Dictionary = {}
var _encounter: Dictionary = {}

var _arena: Dictionary = {}
var _state: Dictionary = {}
var _view: Dictionary = {}
var _selected: Array = []
var _phase := "planning"
var _round_left := 0.0
var _seed := 20261121
var _order_point := Vector3.ZERO
var _has_order := false
var _attack_move := false
var _hud_tick := 0.0
var selected_count := 0
var phase_name := "planning"

var _camera: Camera3D = null
var _cam_target := Vector3.ZERO
var _squad_layer: Node3D = null
var _hud: Control = null
var _blood: Control = null
var _input_node: Node = null
var _fatal_layer: CanvasLayer = null


func _ready() -> void:
	set_process(true)
	if not _load_data():
		return
	if not _new_session():
		return
	_build_world()
	_spawn_demo()
	_view = mdl.call("SquadView", handle)
	_refresh_view(true)


# ===========================================================================
# 数据 / 会话
# ===========================================================================
func _load_data() -> bool:
	var bridge_sc := load("res://Game/adapters/bridge.gd")
	if bridge_sc == null:
		_fatal("bridge script missing")
		return false
	mdl = bridge_sc.call("get_bridge") as RefCounted
	if mdl == null:
		_fatal("ModelBridge unavailable (C# not built?)")
		return false

	_units = JsonFile.read_dict(UNITS_JSON, {})
	_combat = JsonFile.read_dict(COMBAT_JSON, {})
	_planning = JsonFile.read_dict(PLANNING_JSON, {})
	_levels = JsonFile.read_dict(LEVELS_JSON, {})
	_shells = JsonFile.read_dict(SHELLS_JSON, {})
	_layouts = JsonFile.read_dict(LAYOUTS_JSON, {})
	_encounters = JsonFile.read_dict(ENCOUNTERS_JSON, {})
	_tuning = JsonFile.read_dict(SQUAD_JSON, {})
	if _tuning.is_empty():
		_tuning = {"zone_dps_per_squad": 18.0}
	if _units.is_empty() or _combat.is_empty() or _planning.is_empty() or _levels.is_empty():
		_fatal("Content/data tables missing")
		return false

	_level = _pick_level()
	if _level.is_empty():
		_fatal("no level with assembly")
		return false

	var asm: Dictionary = _level.get("assembly", {})
	if asm.is_empty():
		_fatal("level has no assembly")
		return false
	_shell = _find_row(_shells, "shells", String(asm.get("shell", "")))
	_layout = _find_row(_layouts, "layouts", String(asm.get("player_layout", "")))
	_encounter = _find_row(_encounters, "encounters", String(asm.get("enemy_encounter", "")))
	if _shell.is_empty() or _layout.is_empty() or _encounter.is_empty():
		_fatal("assembly cards missing")
		return false
	return true


func _pick_level() -> Dictionary:
	var found := _find_row(_levels, "levels", DEFAULT_LEVEL)
	if not found.is_empty() and not (found.get("assembly", {}) as Dictionary).is_empty():
		return found
	for row in _levels.get("levels", []):
		var lv: Dictionary = row
		if not (lv.get("assembly", {}) as Dictionary).is_empty():
			return lv
	return {}


func _find_row(doc: Dictionary, key: String, id: String) -> Dictionary:
	for row in doc.get(key, []):
		var d: Dictionary = row
		if String(d.get("id", "")) == id:
			return d
	return {}


func _new_session() -> bool:
	var res: Dictionary = mdl.call("SquadSessionNew",
		_units, _combat, _planning, _level, _shell, _layout, _encounter, _tuning, _seed, true)
	if not bool(res.get("ok", false)):
		var errs: Array = res.get("errors", [])
		var text := "session failed"
		if not errs.is_empty():
			text += ": " + String(errs[0])
		_fatal(text)
		return false
	handle = int(res.get("handle", 0))
	_arena = res.get("arena", {})
	mdl.call("SquadSessionBeginPlanning", handle)
	_state = mdl.call("SquadSessionState", handle)
	_view = mdl.call("SquadView", handle)
	_phase = "planning"
	_round_left = float(_arena.get("round_seconds", 90.0))
	_selected.clear()
	_has_order = false
	last_order = ""
	status_text = ""
	if _squad_layer != null and is_instance_valid(_squad_layer):
		_squad_layer.call("set_arena", _arena)
	return true


# ===========================================================================
# 极简 3D 世界
# ===========================================================================
func _build_world() -> void:
	# 试玩用中性环境：不沿用战斗环境的黄昏棕雾（那个是给主场景的过场氛围）。
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.045, 0.06, 0.085)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.66, 0.72, 0.82)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(34.0, 142.0, 0.0)
	fill.light_energy = 0.35
	fill.shadow_enabled = false
	add_child(fill)

	var min_x := float(_arena.get("min_x", -60.0))
	var max_x := float(_arena.get("max_x", 60.0))
	var min_z := float(_arena.get("min_z", -31.5))
	var max_z := float(_arena.get("max_z", 31.5))
	var center := Vector3((min_x + max_x) * 0.5, 0.0, (min_z + max_z) * 0.5)

	var plane := PlaneMesh.new()
	plane.size = Vector2(max_x - min_x, max_z - min_z)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = plane
	ground.position = Vector3(center.x, -0.02, center.z)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.24, 0.185)
	mat.roughness = 1.0
	ground.material_override = mat
	add_child(ground)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = 50.0
	_camera.near = 0.5
	_camera.far = 600.0
	add_child(_camera)
	# 开局把镜头压在我方半场（单位看得清）；方向键可以平移到敌方基地。
	_cam_target = Vector3(float(_arena.get("player_base_x", center.x)) * 0.45, 0.0, 0.0)
	_camera.position = _cam_target + Vector3(0.0, 38.0, 48.0)
	_camera.look_at(_cam_target, Vector3.UP)
	_camera.current = true

	_squad_layer = Node3D.new()
	_squad_layer.name = "SquadLayer"
	_squad_layer.set_script(load(SQUAD_LAYER_PATH) as Script)
	add_child(_squad_layer)
	_squad_layer.call("set_arena", _arena)

	var canvas := CanvasLayer.new()
	canvas.name = "HUDLayer"
	canvas.layer = 1
	add_child(canvas)

	_blood = Control.new()
	_blood.name = "SquadBlood"
	_blood.set_script(load(BLOOD_PATH) as Script)
	canvas.add_child(_blood)

	_hud = Control.new()
	_hud.name = "SquadHUD"
	_hud.set_script(load(SQUAD_HUD_PATH) as Script)
	canvas.add_child(_hud)

	_input_node = Node.new()
	_input_node.name = "SquadCommand"
	_input_node.set_script(load(SQUAD_INPUT_PATH) as Script)
	add_child(_input_node)


func _spawn_demo() -> void:
	var tile := _player_barracks_tile()
	var base := Vector3(float(tile.get("spawn_x", _arena.get("player_base_x", -40.0))),
		0.0, float(tile.get("spawn_z", _arena.get("player_base_z", 0.0))))
	for i in DEMO_UNITS.size():
		var pos := base + Vector3(-3.4 * float(i + 1), 0.0, (float(i) - 1.0) * 4.6)
		var id := int(mdl.call("SquadSpawn", handle, 0, String(DEMO_UNITS[i]), 1, pos.x, pos.z))
		if id > 0:
			_selected.append(id)
	status_text = I18n.t("squad.selected", {"n": _selected.size()})


## 自检/截图用：在战场中心放一支敌方小队（验证"右键集火"是真的能点到敌人）。
func spawn_enemy_demo() -> void:
	if handle == 0:
		return
	var x := (float(_arena.get("player_base_x", -40.0)) + float(_arena.get("enemy_base_x", 40.0))) * 0.5
	mdl.call("SquadSpawn", handle, 1, "bandit_marauder", 1, x, 0.0)
	_view = mdl.call("SquadView", handle)
	status_text = I18n.t("squad.selected", {"n": _selected.size()})
	_refresh_view(true)


## 自检/截图用：第一支敌方小队的屏幕坐标（给"右键集火"定位）。
func screen_pos_of_enemy() -> Vector2:
	if _camera == null:
		return Vector2(-1.0, -1.0)
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if int(sq.get("side", 0)) != 1:
			continue
		return _camera.unproject_position(Vector3(float(sq.get("x", 0.0)), 0.8, float(sq.get("z", 0.0))))
	return Vector2(-1.0, -1.0)


func _player_barracks_tile() -> Dictionary:
	for b in _arena.get("player_buildings", []):
		var row: Dictionary = b
		if String(row.get("building", "")) != "barracks":
			continue
		for t in _arena.get("tiles", []):
			var tile: Dictionary = t
			if int(tile.get("index", 0)) == int(row.get("tile", 0)):
				return tile
	for t in _arena.get("tiles", []):
		var tile: Dictionary = t
		if String(tile.get("side", "")) == "player":
			return tile
	return {}


# ===========================================================================
# 每帧
# ===========================================================================
func _process(delta: float) -> void:
	_camera_pan(delta)
	if handle == 0:
		return

	if _phase == "executing":
		mdl.call("SquadStep", handle, minf(delta, 0.1))
		_round_left -= delta
		_view = mdl.call("SquadView", handle)
		if _round_left <= 0.0 or bool(_view.get("finished", false)):
			_finish_round()

	_hud_tick += delta
	_refresh_view(false)


func _refresh_view(force_hud: bool) -> void:
	selected_count = _selected.size()
	phase_name = _phase
	if _squad_layer != null and is_instance_valid(_squad_layer):
		_squad_layer.call("update_view", _view, _selected, _order_point, _has_order)
	if _blood != null and is_instance_valid(_blood):
		_blood.call("set_view", _view, _camera)
	if _hud != null and is_instance_valid(_hud):
		if force_hud or _hud_tick >= 0.1:
			_hud.call("refresh", _state, _view, _phase, _round_left, _selected.size())
			_hud_tick = 0.0


func _finish_round() -> void:
	if _phase == "finished":
		return
	_phase = "finished"
	var enemy_hp := float(_view.get("enemy_hp", 1.0))
	var player_hp := float(_view.get("player_hp", 1.0))
	if enemy_hp <= 0.0:
		status_text = I18n.t("squad.result.win")
	elif player_hp <= 0.0:
		status_text = I18n.t("squad.result.lose")
	else:
		status_text = I18n.t("squad.result.timeout")
	_refresh_view(true)


# ===========================================================================
# 输入 API（由 小队指挥.gd 调用）
# ===========================================================================
func is_ui_blocking() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var hovered := vp.gui_get_hovered_control()
	return hovered != null and hovered.mouse_filter != Control.MOUSE_FILTER_IGNORE


func ground_at_screen(pos: Vector2) -> Vector3:
	if _camera == null or not is_instance_valid(_camera):
		return Vector3.ZERO
	var from := _camera.project_ray_origin(pos)
	var dir := _camera.project_ray_normal(pos)
	if absf(dir.y) < 0.00001:
		return Vector3(from.x, 0.0, from.z)
	var t := -from.y / dir.y
	var p := from + dir * maxf(t, 0.0)
	p.y = 0.0
	p.x = clampf(p.x, float(_arena.get("min_x", -60.0)) + 1.0, float(_arena.get("max_x", 60.0)) - 1.0)
	p.z = clampf(p.z, float(_arena.get("min_z", -31.5)) + 1.0, float(_arena.get("max_z", 31.5)) - 1.0)
	return p


func pick_at_screen(pos: Vector2) -> void:
	if handle == 0:
		return
	var p := ground_at_screen(pos)
	var id := int(mdl.call("SquadPickWorld", handle, p.x, p.z, 0, 0.6))
	_selected.clear()
	if id > 0:
		_selected.append(id)
	status_text = I18n.t("squad.selected", {"n": _selected.size()})


func box_select_screen(rect: Rect2) -> void:
	if handle == 0 or _camera == null:
		return
	_selected.clear()
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if int(sq.get("side", 0)) != 0:
			continue
		var sp := _camera.unproject_position(Vector3(float(sq.get("x", 0.0)), 0.8, float(sq.get("z", 0.0))))
		if rect.has_point(sp):
			_selected.append(int(sq.get("id", 0)))
	status_text = I18n.t("squad.selected", {"n": _selected.size()})


func select_all_squads() -> void:
	_selected.clear()
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if int(sq.get("side", 0)) == 0:
			_selected.append(int(sq.get("id", 0)))
	status_text = I18n.t("squad.selected", {"n": _selected.size()})


func clear_selection() -> void:
	_selected.clear()
	status_text = I18n.t("squad.selected", {"n": 0})


func context_order_screen(_pos: Vector2, world: Vector3) -> void:
	if handle == 0:
		return
	if _selected.is_empty():
		status_text = I18n.t("squad.order_none")
		return
	var enemy := int(mdl.call("SquadPickWorld", handle, world.x, world.z, 1, 0.6))
	if enemy > 0:
		order_selected("attack", world, enemy)
		return
	order_selected("attack_move" if _attack_move else "move", world, -1)


func order_selected(order: String, world: Vector3 = Vector3.ZERO, target: int = -1) -> void:
	if handle == 0:
		return
	if _selected.is_empty():
		status_text = I18n.t("squad.order_none")
		return
	var ids := _selected.duplicate()
	if order == "hold" or order == "stop":
		world = _selection_center()
	var n := int(mdl.call("SquadOrder", handle, ids, order, world.x, world.z, target))
	if n <= 0:
		return
	last_order = I18n.t("squad.receipt." + order, {"n": n})
	status_text = last_order
	_view = mdl.call("SquadView", handle)
	if order == "hold" or order == "stop":
		_has_order = false
	else:
		_order_point = world
		_has_order = true


func _selection_center() -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if _selected.has(int(sq.get("id", 0))):
			sum += Vector3(float(sq.get("x", 0.0)), 0.0, float(sq.get("z", 0.0)))
			count += 1
	return sum / float(count) if count > 0 else Vector3.ZERO


func set_attack_move(on: bool) -> void:
	_attack_move = on
	if on:
		status_text = I18n.t("squad.receipt.attack_move", {"n": _selected.size()})


func zoom_camera(factor: float) -> void:
	if _camera == null:
		return
	var offset := _camera.position - _cam_target
	var dist := clampf(offset.length() * factor, 35.0, 220.0)
	_camera.position = _cam_target + offset.normalized() * dist
	_camera.look_at(_cam_target, Vector3.UP)


func _camera_pan(delta: float) -> void:
	if _camera == null:
		return
	var dx := (1.0 if Input.is_key_pressed(KEY_RIGHT) else 0.0) - (1.0 if Input.is_key_pressed(KEY_LEFT) else 0.0)
	var dz := (1.0 if Input.is_key_pressed(KEY_UP) else 0.0) - (1.0 if Input.is_key_pressed(KEY_DOWN) else 0.0)
	if absf(dx) < 0.01 and absf(dz) < 0.01:
		return
	var right := _camera.global_transform.basis.x
	right.y = 0.0
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	var dir := right.normalized() * dx + forward.normalized() * dz
	if dir.length() < 0.001:
		return
	var dist := (_camera.position - _cam_target).length()
	var speed := 36.0 * delta * clampf(dist / 110.0, 0.5, 1.8)
	var next := _cam_target + dir.normalized() * speed
	next.x = clampf(next.x, float(_arena.get("min_x", -60.0)) + 4.0, float(_arena.get("max_x", 60.0)) - 4.0)
	next.z = clampf(next.z, float(_arena.get("min_z", -31.5)) + 4.0, float(_arena.get("max_z", 31.5)) - 4.0)
	_camera.position += next - _cam_target
	_cam_target = next
	_camera.look_at(_cam_target, Vector3.UP)


# ===========================================================================
# 规划 / 训练 / 阶段
# ===========================================================================
func train_card(card_id: String) -> void:
	if handle == 0:
		return
	if _phase != "planning":
		status_text = I18n.t("squad.train_only_planning")
		return
	var res: Dictionary = mdl.call("SquadSessionTrain", handle, card_id)
	if not bool(res.get("ok", false)):
		status_text = String(res.get("error", ""))
		return
	var n := int(res.get("produced", 0))
	if n <= 0:
		var reason := "ok"
		for c in res.get("train_cards", []):
			var card: Dictionary = c
			if String(card.get("card_id", "")) == card_id:
				reason = String(card.get("reason", "ok"))
				break
		status_text = I18n.t("squad.reason." + reason)
		return

	_state = res
	_view = mdl.call("SquadView", handle)
	_selected.clear()
	var squads: Array = _view.get("squads", [])
	var start := maxi(squads.size() - n, 0)
	for i in range(start, squads.size()):
		var sq: Dictionary = squads[i]
		if int(sq.get("side", 0)) == 0:
			_selected.append(int(sq.get("id", 0)))

	var card_name := card_id
	for c in res.get("train_cards", []):
		var card: Dictionary = c
		if String(card.get("card_id", "")) == card_id:
			card_name = String(card.get("display_name", card_id))
			break
	var tip := I18n.t("squad.spawned", {"name": card_name, "n": n})
	status_text = tip
	if _hud != null and is_instance_valid(_hud):
		_hud.call("show_spawn_tip", tip)
	_refresh_view(true)


func begin_execution() -> void:
	if handle == 0 or _phase != "planning":
		return
	mdl.call("SquadSessionEndPlanning", handle)
	mdl.call("SquadSessionBeginExecution", handle, 0)
	_state = mdl.call("SquadSessionState", handle)
	_phase = "executing"
	_round_left = float(_arena.get("round_seconds", 90.0))
	status_text = I18n.t("squad.phase.executing", {"t": int(ceil(_round_left))})
	_refresh_view(true)


func restart() -> void:
	if handle > 0:
		mdl.call("SquadSessionFree", handle)
	handle = 0
	_seed += 1
	_selected.clear()
	_has_order = false
	_order_point = Vector3.ZERO
	last_order = ""
	status_text = ""
	if not _new_session():
		return
	_spawn_demo()
	_view = mdl.call("SquadView", handle)
	_refresh_view(true)


# ===========================================================================
# 失败提示
# ===========================================================================
func _fatal(text: String) -> void:
	push_error("[squad] " + text)
	print("SQUAD FAIL " + text)
	handle = 0
	if _fatal_layer != null:
		return
	_fatal_layer = CanvasLayer.new()
	_fatal_layer.layer = 5
	add_child(_fatal_layer)
	var label := Label.new()
	label.text = I18n.t("squad.no_handle") + "\n" + text
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.offset_left = -420
	label.offset_right = 420
	label.offset_top = -60
	label.offset_bottom = 80
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.45))
	_fatal_layer.add_child(label)
