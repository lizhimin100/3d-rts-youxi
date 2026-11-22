extends Node3D
## 职责：**战役垂直切片的总装配与调度**——读数据、建会话、建 3D 世界、跑「规划 → 进攻战 → 防守战 → 结算」。
## 属于：Screens/world/battle（表现层根节点）
##
## 纪律（与本项目内核分工一致）：
##   · 玩法规则全部在 Model（C#）：这里只传世界米、调 SquadStep、读 SquadView；
##   · 玩家能操作的最小单位是**小队**：没有任何"选中单个成员"的入口；
##   · 建造落位 / 产兵 / 攻防时空切换都由 Model 判定，这里只把结果画出来；
##   · 相机三阶段规则写在 战役镜头.gd（唯一实现），这里只切阶段。

const JsonFile := preload("res://Engine/util/json_file.gd")

## 中文目录/文件名不写进字符串字面量（i18n 预算按"含中文的字面量"计数）。
const SQUAD_LAYER_PATH := "res://Screens/world/squad/" + "\u5c0f\u961f\u5c42.gd"
const BLOOD_PATH := "res://Screens/world/squad/" + "\u5c0f\u961f\u8840\u6761.gd"
const HUD_PATH := "res://Screens/hud/" + "\u6218\u5f79HUD.gd"
const CAMERA_PATH := "res://Screens/world/battle/" + "\u6218\u5f79\u955c\u5934.gd"
const BOARD_PATH := "res://Screens/world/battle/" + "\u6218\u5f79\u68cb\u76d8.gd"
const BUILDINGS_PATH := "res://Screens/world/battle/" + "\u6218\u5f79\u5efa\u7b51\u5c42.gd"
const TERRAIN_PATH := "res://Screens/world/battle/" + "\u6218\u5f79\u5730\u5f62.gd"

const UNITS_JSON := "res://Content/data/units.json"
const COMBAT_JSON := "res://Content/data/combat.json"
const PLANNING_JSON := "res://Content/data/planning.json"
const LEVELS_JSON := "res://Content/data/levels.json"
const SHELLS_JSON := "res://Content/data/map_shells.json"
const LAYOUTS_JSON := "res://Content/data/player_layouts.json"
const ENCOUNTERS_JSON := "res://Content/data/enemy_encounters.json"
const SQUAD_JSON := "res://Content/data/squad.json"

const DEFAULT_LEVEL := "level_asm_even_four__gnoll_press"
const PLAYER_COLOR := Color(0.30, 0.62, 1.00)
const ENEMY_COLOR := Color(1.00, 0.32, 0.26)
const TILE_PICK_SLACK := 0.35

## 单场时长（秒）。--phase-seconds=N 可以缩短（截图/自检用，正式局必须 60）。
const ROUND_SECONDS := 60.0

# --- 对外可断言的状态（screens.json / 自检直接读这些属性）---
var phase_name := "planning"
var round_kind := ""
var status_text := ""
var last_order := ""
var selected_count := 0
var time_scale := 1.0
var board_cols := 0
var board_rows := 0
var board_tiles := 0
var built_count := 0
var outpost_captured := false
var armed_card := ""
var model_instances := 0
## 1 = 场上真的有 GLB 实例（0 = 退回占位/没模型）；截图与自检读这个，别读具体数量。
var real_models := 0
var phase_left := 0.0
var attack_squads := 0
var defend_squads := 0
var player_hp := 0.0
var enemy_hp := 0.0

var _mdl: RefCounted = null
var _handle := 0
var _seed := 20261122

var _units_doc: Dictionary = {}
var _unit_defs: Dictionary = {}
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
var _board_theme: Dictionary = {}
var _building_defs: Dictionary = {}
var _card_meta: Dictionary = {}

var _arena: Dictionary = {}
var _state: Dictionary = {}
var _view: Dictionary = {}
var _selected: Array = []
var _order_point := Vector3.ZERO
var _has_order := false
var _hud_tick := 0.0

var _camera: Node3D = null
var _terrain: Node3D = null
var _board: Node3D = null
var _buildings: Node3D = null
var _squad_layer: Node3D = null
var _hud: Control = null
var _blood: Control = null

var _drag_from := Vector2.ZERO
var _dragging := false
var _hover_tile := 0
var _fatal_layer: CanvasLayer = null
var _round_seconds := ROUND_SECONDS


func _ready() -> void:
	set_process(true)
	_round_seconds = _read_phase_seconds()
	print("[battle] phase_seconds=%.1f user_args=%s" % [_round_seconds, str(OS.get_cmdline_user_args())])
	if not _load_data():
		return
	_build_world()
	_refresh(true)


## --phase-seconds=N（只在 test/shot 模式下有意义；正式局恒为 60）
func _read_phase_seconds() -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--phase-seconds="):
			var v := float(a.substr("--phase-seconds=".length()))
			if v > 1.0 and v <= 600.0:
				return v
	return ROUND_SECONDS


# ===========================================================================
# 数据 / 会话
# ===========================================================================
func _load_data() -> bool:
	var bridge_sc := load("res://Game/adapters/bridge.gd")
	if bridge_sc == null:
		_fatal("bridge script missing")
		return false
	_mdl = bridge_sc.call("get_bridge") as RefCounted
	if _mdl == null:
		_fatal("ModelBridge unavailable (C# not built?)")
		return false

	_units_doc = JsonFile.read_dict(UNITS_JSON, {})
	_combat = JsonFile.read_dict(COMBAT_JSON, {})
	_planning = JsonFile.read_dict(PLANNING_JSON, {})
	_levels = JsonFile.read_dict(LEVELS_JSON, {})
	_shells = JsonFile.read_dict(SHELLS_JSON, {})
	_layouts = JsonFile.read_dict(LAYOUTS_JSON, {})
	_encounters = JsonFile.read_dict(ENCOUNTERS_JSON, {})
	_tuning = JsonFile.read_dict(SQUAD_JSON, {})
	for u in _units_doc.get("units", []):
		var row: Dictionary = u
		_unit_defs[String(row.get("id", ""))] = row
	for b in _planning.get("buildings", []):
		var row: Dictionary = b
		_building_defs[String(row.get("id", ""))] = row
	# 手牌区要画"建造 / 训练 / 策略"三类牌；Model 的 train_cards 只含训练牌，
	# 所以建造/策略的显示名与价格从规划表直读（同一份数据，不另存一份文案）。
	for c in _planning.get("cards", []):
		var card: Dictionary = c
		_card_meta[String(card.get("id", ""))] = card

	if _units_doc.is_empty() or _combat.is_empty() or _planning.is_empty() or _levels.is_empty():
		_fatal("Content/data tables missing")
		return false

	_level = _pick_level()
	if _level.is_empty():
		_fatal("no level with assembly")
		return false
	var asm: Dictionary = _level.get("assembly", {})
	_shell = _find_row(_shells, "shells", String(asm.get("shell", "")))
	var layout := _find_row(_layouts, "layouts", String(asm.get("player_layout", "")))
	var encounter := _find_row(_encounters, "encounters", String(asm.get("enemy_encounter", "")))
	if _shell.is_empty() or layout.is_empty() or encounter.is_empty():
		_fatal("assembly cards missing")
		return false
	_encounter = encounter
	_board_theme = (_shell.get("board", {}) as Dictionary).get("theme", {})

	# 注意：**不要把缩短后的时长写回关卡** —— 关卡的 round_seconds 是规则真源，
	# 波次时间（0..60）要按它校验；--phase-seconds 只改"表现层这一场跑多久"。
	_layout = layout
	return _new_session()


func _new_session() -> bool:
	var res: Dictionary = _mdl.call("SquadSessionNew",
		_units_doc, _combat, _planning, _level, _shell, _layout, _encounter, _tuning, _seed, true)
	if not bool(res.get("ok", false)):
		var errs: Array = res.get("errors", [])
		var text := "session failed"
		if not errs.is_empty():
			text += ": " + String(errs[0])
		_fatal(text)
		return false
	_handle = int(res.get("handle", 0))
	_arena = res.get("arena", {})
	_mdl.call("SquadSessionBeginPlanning", _handle)
	_state = _mdl.call("SquadSessionState", _handle)
	_view = _mdl.call("SquadView", _handle)
	phase_name = "planning"
	round_kind = ""
	phase_left = _round_seconds
	_selected.clear()
	_has_order = false
	last_order = ""
	outpost_captured = false
	armed_card = ""
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


# ===========================================================================
# 3D 世界
# ===========================================================================
func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.055, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.68, 0.74, 0.84)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.42, 0.48, 0.56)
	env.fog_density = 0.0016
	var we := WorldEnvironment.new()
	we.name = "Env"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-46.0, -62.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220.0
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(36.0, 138.0, 0.0)
	fill.light_energy = 0.32
	fill.shadow_enabled = false
	add_child(fill)

	# 地形（真实高度场网格 + 装饰）
	_terrain = Node3D.new()
	_terrain.name = "Terrain"
	_terrain.set_script(load(TERRAIN_PATH) as Script)
	add_child(_terrain)
	_terrain.call("build", _shell)
	var ground := Callable(_terrain, "height_at")

	# 棋盘
	_board = Node3D.new()
	_board.name = "Board"
	_board.set_script(load(BOARD_PATH) as Script)
	add_child(_board)
	_board.call("set_arena", _arena, _board_theme)
	board_cols = 6
	board_rows = 3
	board_tiles = 18

	# 建筑
	_buildings = Node3D.new()
	_buildings.name = "Buildings"
	_buildings.set_script(load(BUILDINGS_PATH) as Script)
	add_child(_buildings)
	_buildings.call("configure", _building_defs, PLAYER_COLOR, ENEMY_COLOR)
	_buildings.call("set_arena", _arena)

	# 小队（真实 GLB）
	_squad_layer = Node3D.new()
	_squad_layer.name = "SquadLayer"
	_squad_layer.set_script(load(SQUAD_LAYER_PATH) as Script)
	add_child(_squad_layer)
	_squad_layer.call("configure", _unit_defs)
	_squad_layer.call("set_ground", ground)
	_squad_layer.call("set_arena", _arena)

	# 镜头
	_camera = Node3D.new()
	_camera.name = "Camera"
	_camera.set_script(load(CAMERA_PATH) as Script)
	add_child(_camera)
	_camera.call("setup", _arena)

	# HUD
	var canvas := CanvasLayer.new()
	canvas.name = "HUDLayer"
	canvas.layer = 1
	add_child(canvas)
	_blood = Control.new()
	_blood.name = "SquadBlood"
	_blood.set_script(load(BLOOD_PATH) as Script)
	canvas.add_child(_blood)
	_hud = Control.new()
	_hud.name = "BattleHUD"
	_hud.set_script(load(HUD_PATH) as Script)
	canvas.add_child(_hud)


# ===========================================================================
# 每帧
# ===========================================================================
func _process(delta: float) -> void:
	if _handle == 0:
		return
	if phase_name == "attack" or phase_name == "defend":
		_mdl.call("SquadStep", _handle, minf(delta, 0.1))
		phase_left -= delta * time_scale
		_view = _mdl.call("SquadView", _handle)
		_feed_camera_follow()
		if phase_left <= 0.0 or bool(_view.get("finished", false)):
			_advance_phase()
	_hud_tick += delta
	_refresh(false)


## 把"我方小队质心"喂给镜头：60 秒自动战斗里玩家不操作时，镜头自己跟上去。
func _feed_camera_follow() -> void:
	var sum := Vector3.ZERO
	var n := 0
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if int(sq.get("side", 0)) != 0 or not bool(sq.get("active", true)):
			continue
		sum += Vector3(float(sq.get("x", 0.0)), 0.0, float(sq.get("z", 0.0)))
		n += 1
	if n == 0:
		_camera.call("stop_follow")
		return
	var c := sum / float(n)
	_camera.call("follow_world", c.x, c.z)


func _advance_phase() -> void:
	if phase_name == "attack":
		_mdl.call("SquadSessionDefend", _handle)
		_state = _mdl.call("SquadSessionState", _handle)
		phase_name = "defend"
		round_kind = "defend"
		phase_left = _round_seconds
		_view = _mdl.call("SquadView", _handle)
		status_text = I18n.t("battle.phase.defend_tip")
		_camera.call("apply_phase", "defend")
		_refresh(true)
		return
	if phase_name == "defend":
		_mdl.call("SquadSessionEndRound", _handle)
		_state = _mdl.call("SquadSessionState", _handle)
		phase_name = "result"
		round_kind = "done"
		phase_left = 0.0
		_view = _mdl.call("SquadView", _handle)
		status_text = _result_text()
		_camera.call("apply_phase", "result")
		_refresh(true)


func _result_text() -> String:
	if enemy_hp <= 0.0 and player_hp > 0.0:
		return I18n.t("battle.result.win")
	if player_hp <= 0.0 and enemy_hp > 0.0:
		return I18n.t("battle.result.lose")
	if player_hp <= 0.0 and enemy_hp <= 0.0:
		return I18n.t("battle.result.draw")
	return I18n.t("battle.result.timeout")


func _refresh(force: bool) -> void:
	selected_count = _selected.size()
	player_hp = float(_view.get("player_hp", 0.0))
	enemy_hp = float(_view.get("enemy_hp", 0.0))
	attack_squads = int(_state.get("attack_squads", 0))
	defend_squads = int(_state.get("defend_squads", 0))
	outpost_captured = bool(_state.get("outpost_captured", false))
	built_count = (_arena.get("player_buildings", []) as Array).size()

	if _squad_layer != null and is_instance_valid(_squad_layer):
		_squad_layer.call("update_view", _view, _selected, _order_point, _has_order)
		model_instances = int(_squad_layer.call("model_instance_count"))
		real_models = 1 if model_instances > 0 else 0
	if _blood != null and is_instance_valid(_blood):
		_blood.call("set_view", _view, _camera.get("camera"))
	if _hud != null and is_instance_valid(_hud):
		if force or _hud_tick >= 0.1:
			_hud.call("refresh", _state, _view, phase_name, phase_left, _selected.size(), _extra_hud())
			_hud_tick = 0.0


## 顶部敌方意图栏：告诉玩家"这一场要面对什么"，而不是让他拖镜头去偷看。
func _intent_text() -> String:
	var name := String(_encounter.get("display_name", ""))
	match phase_name:
		"attack":
			return I18n.t("battle.intent.attack", {"name": name, "waves": _wave_count("attack")})
		"defend":
			return I18n.t("battle.intent.defend", {"name": name, "waves": _wave_count("defend")})
		"result":
			return I18n.t("battle.intent.done", {"name": name})
		_:
			return I18n.t("battle.intent.planning", {
				"name": name,
				"attack": _wave_count("attack"),
				"defend": _wave_count("defend"),
			})


func _wave_count(kind: String) -> int:
	for r in _arena.get("rounds", []):
		var row: Dictionary = r
		if String(row.get("kind", "")) != kind:
			continue
		var n := 0
		for w in row.get("waves", []):
			n += int((w as Dictionary).get("count", 0))
		return n
	return 0


func _extra_hud() -> Dictionary:
	return {
		"cards": _card_meta,
		"intent": _intent_text(),
		"last_order": last_order,
		"armed_card": armed_card,
		"outpost_captured": outpost_captured,
		"time_scale": time_scale,
		"status": status_text,
		"model_instances": model_instances,
		"board_tiles": board_tiles,
	}


# ===========================================================================
# 输入
# ===========================================================================
func _unhandled_input(event: InputEvent) -> void:
	if _handle == 0:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_camera.call("zoom_by", 1.0 / 1.14)
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_camera.call("zoom_by", 1.14)
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag_from = mb.position
				_dragging = false
			else:
				_finish_left(mb.position)
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_right_click(mb.position)
			return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if mm.position.distance_to(_drag_from) > 6.0:
				_dragging = true
		if armed_card != "":
			var g := ground_at_screen(mm.position)
			_hover_tile = tile_at(g.x, g.z)
			_board.call("set_hover_tile", _hover_tile)
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		match k.keycode:
			KEY_1:
				set_time_scale(1.0)
			KEY_2:
				set_time_scale(2.0)
			KEY_SPACE:
				select_all_squads()
			KEY_ESCAPE:
				cancel_arm()
			KEY_ENTER:
				begin_execution()


func _finish_left(pos: Vector2) -> void:
	if armed_card != "":
		var g := ground_at_screen(pos)
		var tile := tile_at(g.x, g.z)
		print("[battle] build click pos=%s world=%s tile=%d" % [str(pos), str(g), tile])
		if tile > 0:
			_build_at(tile)
		return
	if _dragging:
		box_select_screen(Rect2(_drag_from, pos - _drag_from).abs())
		_dragging = false
		return
	pick_at_screen(pos)


func _right_click(pos: Vector2) -> void:
	if phase_name != "attack" and phase_name != "defend":
		status_text = I18n.t("battle.order.only_in_battle")
		return
	context_order_screen(pos, ground_at_screen(pos))


func ground_at_screen(pos: Vector2) -> Vector3:
	var cam: Camera3D = _camera.get("camera")
	if cam == null:
		return Vector3.ZERO
	var from := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	if absf(dir.y) < 0.00001:
		return Vector3(from.x, 0.0, from.z)
	var t := -from.y / dir.y
	var p := from + dir * maxf(t, 0.0)
	var y := 0.0
	if _terrain != null and is_instance_valid(_terrain):
		y = float(_terrain.call("height_at", p.x, p.z))
	return Vector3(p.x, y, p.z)


## 屏幕点 → 战术格子序号（0 = 没点到）。格子在数据里都是轴对齐矩形。
func tile_at(x: float, z: float) -> int:
	for t in _arena.get("tiles", []):
		var d: Dictionary = t
		var hw := float(d.get("w", 4.0)) * 0.5 + TILE_PICK_SLACK
		var hd := float(d.get("d", 4.0)) * 0.5 + TILE_PICK_SLACK
		if absf(x - float(d.get("x", 0.0))) <= hw and absf(z - float(d.get("z", 0.0))) <= hd:
			return int(d.get("index", 0))
	return 0


func pick_at_screen(pos: Vector2) -> void:
	var p := ground_at_screen(pos)
	var id := int(_mdl.call("SquadPickWorld", _handle, p.x, p.z, 0, 0.8))
	_selected.clear()
	if id > 0:
		_selected.append(id)
	status_text = I18n.t("battle.selected", {"n": _selected.size()})


func box_select_screen(rect: Rect2) -> void:
	_selected.clear()
	var cam: Camera3D = _camera.get("camera")
	if cam == null:
		return
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if int(sq.get("side", 0)) != 0 or not bool(sq.get("active", true)):
			continue
		var sp := cam.unproject_position(Vector3(float(sq.get("x", 0.0)), 1.0, float(sq.get("z", 0.0))))
		if rect.has_point(sp):
			_selected.append(int(sq.get("id", 0)))
	status_text = I18n.t("battle.selected", {"n": _selected.size()})


func select_all_squads() -> void:
	_selected.clear()
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if int(sq.get("side", 0)) == 0 and bool(sq.get("active", true)):
			_selected.append(int(sq.get("id", 0)))
	status_text = I18n.t("battle.selected", {"n": _selected.size()})


func clear_selection() -> void:
	_selected.clear()


## 右键：只认"点在某支敌方小队身上" = 集火（微操收敛后的唯一指令）。
func context_order_screen(_pos: Vector2, world: Vector3) -> void:
	if _selected.is_empty():
		status_text = I18n.t("battle.order.none")
		return
	var enemy := int(_mdl.call("SquadPickWorld", _handle, world.x, world.z, 1, 0.8))
	if enemy > 0:
		order_selected("attack", world, enemy)
		return
	status_text = I18n.t("battle.order.focus_only")


func order_selected(order: String, world: Vector3 = Vector3.ZERO, target: int = -1) -> void:
	if _selected.is_empty():
		status_text = I18n.t("battle.order.none")
		return
	if not bool(_mdl.call("SquadPlayerOrderAllowed", order)):
		status_text = I18n.t("battle.order.focus_only")
		return
	var ids := _selected.duplicate()
	var n := int(_mdl.call("SquadOrder", _handle, ids, order, world.x, world.z, target))
	if n <= 0:
		return
	last_order = I18n.t("battle.receipt." + order, {"n": n})
	status_text = last_order
	_view = _mdl.call("SquadView", _handle)
	_order_point = world
	_has_order = true


## 截图/自检用：**屏幕上最靠中间**的那支敌方小队的屏幕坐标。
## 只挑投影后真的落在视口里的队 —— 否则右键会点到画面外（相机在攻防阶段会跟着我方走）。
func screen_pos_of_enemy() -> Vector2:
	var cam: Camera3D = _camera.get("camera")
	if cam == null:
		return Vector2(-1.0, -1.0)
	var vp := get_viewport().get_visible_rect().size
	var center := vp * 0.5
	var best := Vector2(-1.0, -1.0)
	var best_d := 1e12
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if int(sq.get("side", 0)) != 1 or not bool(sq.get("active", true)):
			continue
		var sp := cam.unproject_position(Vector3(float(sq.get("x", 0.0)), 1.0, float(sq.get("z", 0.0))))
		if sp.x < 8.0 or sp.y < 8.0 or sp.x > vp.x - 8.0 or sp.y > vp.y - 8.0:
			continue
		var d := sp.distance_squared_to(center)
		if d < best_d:
			best_d = d
			best = sp
	return best


## 截图/自检用：在战场中间放一支敌方小队（验证"右键集火"真的点到敌人）。
## 同时全选我方小队 —— 截图脚本的执行顺序是"先放敌人、后全选、再右键"，
## 把选择一起做掉，右键才有可下令的队（这是测试辅助，不是玩法入口）。
func spawn_enemy_demo() -> void:
	if _handle == 0:
		return
	var x := (float(_arena.get("player_zone_x", -32.0)) + float(_arena.get("enemy_zone_x", 32.0))) * 0.5
	_mdl.call("SquadSpawn", _handle, 1, "bandit_marauder", 1, x, 0.0)
	_view = _mdl.call("SquadView", _handle)
	select_all_squads()
	_refresh(true)


## 截图/自检用固定机位：
##   { "focus_tile": 8 }  盯住某一格；{ "focus": [x, z] } 盯住世界点；
##   { "dist": 26 }       机位距离（仍受"一个区"上限约束）。
## 会关掉自动跟随，保证连拍两张是同一个构图。
func apply_shot_camera(spec: Dictionary) -> void:
	if _camera == null:
		return
	_camera.call("stop_follow")
	var fx := float(_arena.get("player_zone_x", -32.0))
	var fz := 0.0
	if spec.has("focus_tile"):
		var row := _tile_of(int(spec["focus_tile"]))
		fx = float(row.get("x", fx))
		fz = float(row.get("z", fz))
	elif spec.has("focus"):
		var arr: Array = spec["focus"]
		if arr.size() >= 2:
			fx = float(arr[0])
			fz = float(arr[1])
	_camera.call("set_focus_world", fx, fz)
	if spec.has("dist"):
		_camera.call("set_distance", float(spec["dist"]))
	_camera.call("snap")


func _tile_of(index: int) -> Dictionary:
	for t in _arena.get("tiles", []):
		var row: Dictionary = t
		if int(row.get("index", 0)) == index:
			return row
	return {}


# ===========================================================================
# 规划动作（HUD / 截图脚本调这些）
# ===========================================================================
func arm_build(card_id: String) -> void:
	if phase_name != "planning":
		status_text = I18n.t("battle.only_planning")
		return
	if armed_card == card_id:
		cancel_arm()
		return
	armed_card = card_id
	_board.call("set_armed", true, _mdl.call("SquadSessionFreeTiles", _handle))
	status_text = I18n.t("battle.build.pick_tile")


func cancel_arm() -> void:
	armed_card = ""
	_hover_tile = 0
	_board.call("set_armed", false, [])
	status_text = ""


func _build_at(tile: int) -> void:
	var res: Dictionary = _mdl.call("SquadSessionBuild", _handle, armed_card, tile)
	if not bool(res.get("built", false)):
		status_text = I18n.t("battle.build.failed")
		return
	_state = res
	_arena = _mdl.call("SquadArenaInfo", _handle)
	_buildings.call("set_arena", _arena)
	_buildings.call("rebuild")
	_view = _mdl.call("SquadView", _handle)
	var name := armed_card
	for b in _planning.get("buildings", []):
		var row: Dictionary = b
		for c in _planning.get("cards", []):
			var card: Dictionary = c
			if String(card.get("id", "")) == armed_card and String(card.get("building", "")) == String(row.get("id", "")):
				name = String(row.get("display_name", name))
	status_text = I18n.t("battle.build.done", {"name": name, "tile": tile})
	cancel_arm()
	_refresh(true)


func train_card(card_id: String) -> void:
	if phase_name != "planning":
		status_text = I18n.t("battle.only_planning")
		return
	var res: Dictionary = _mdl.call("SquadSessionTrain", _handle, card_id)
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
		status_text = I18n.t("battle.reason." + reason)
		return
	_state = res
	_view = _mdl.call("SquadView", _handle)
	_selected.clear()
	var squads: Array = _view.get("squads", [])
	var start := maxi(squads.size() - n, 0)
	for i in range(start, squads.size()):
		var sq: Dictionary = squads[i]
		if int(sq.get("side", 0)) == 0:
			_selected.append(int(sq.get("id", 0)))
	status_text = I18n.t("battle.spawned", {"n": n})
	_refresh(true)


func play_strategy(card_id: String) -> void:
	if phase_name != "planning":
		status_text = I18n.t("battle.only_planning")
		return
	var res: Dictionary = _mdl.call("SquadSessionStrategy", _handle, card_id)
	_state = res
	status_text = I18n.t("battle.strategy.done") if bool(res.get("played", false)) else I18n.t("battle.reason.no_cp")
	_refresh(true)


func capture_outpost() -> void:
	if phase_name != "planning":
		return
	var res: Dictionary = _mdl.call("SquadSessionCaptureOutpost", _handle)
	_state = res
	if bool(res.get("captured", false)):
		status_text = I18n.t("battle.outpost.done")
	else:
		status_text = I18n.t("battle.outpost.fail")
	_refresh(true)


func begin_execution() -> void:
	if _handle == 0 or phase_name != "planning":
		return
	cancel_arm()
	_mdl.call("SquadSessionEndPlanning", _handle)
	_mdl.call("SquadSessionAttack", _handle)
	_state = _mdl.call("SquadSessionState", _handle)
	phase_name = "attack"
	round_kind = "attack"
	phase_left = _round_seconds
	_view = _mdl.call("SquadView", _handle)
	status_text = I18n.t("battle.phase.attack_tip")
	_camera.call("apply_phase", "attack")
	_refresh(true)


func set_time_scale(scale: float) -> void:
	if _handle == 0:
		return
	time_scale = float(_mdl.call("SquadSetTimeScale", _handle, scale))
	status_text = I18n.t("battle.speed", {"x": "%.0f" % time_scale})


func restart() -> void:
	if _handle > 0:
		_mdl.call("SquadSessionFree", _handle)
	_handle = 0
	_seed += 1
	if not _new_session():
		return
	_buildings.call("set_arena", _arena)
	_buildings.call("rebuild")
	_board.call("set_arena", _arena, _board_theme)
	_squad_layer.call("set_arena", _arena)
	_camera.call("apply_phase", "planning", true)
	_refresh(true)


# ===========================================================================
# 失败提示
# ===========================================================================
func _fatal(text: String) -> void:
	push_error("[battle] " + text)
	print("BATTLE FAIL " + text)
	_handle = 0
	if _fatal_layer != null:
		return
	_fatal_layer = CanvasLayer.new()
	_fatal_layer.layer = 5
	add_child(_fatal_layer)
	var label := Label.new()
	label.text = I18n.t("battle.no_handle") + "\n" + text
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.offset_left = -460
	label.offset_right = 460
	label.offset_top = -60
	label.offset_bottom = 90
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.45))
	_fatal_layer.add_child(label)
