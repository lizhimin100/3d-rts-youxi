extends PanelContainer
## **准备/执行面板（短局）**：阶段标题 + 计划命令列表 + 开始/结束执行。
##
## 唯一数据源：
##   · `Game.phase` / `Game.round_control` —— 阶段与倒计时；
##   · `CommandSystem.planned` —— 计划命令；
##   · `Game.squads` —— 小队数量。
##
## 交互纪律：本面板只调用 CommandSystem 的公开方法，不自己拼 order_*；
## 面板本身 `mouse_filter = STOP`，HUD.covers_point 必须登记它，否则点击会穿透到世界。

const Spec := preload("res://Views/hud/界面规格.gd")

var _title: Label = null
var _info: Label = null
var _list: VBoxContainer = null
var _start_btn: Button = null
var _end_btn: Button = null
var _clear_btn: Button = null
var _sig: String = ""
var _cmd: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(380.0, 0.0)
	add_theme_stylebox_override("panel",
			Spec.panel_style(6, 0.95, 0.55, 12.0))

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)

	_title = Spec.label("准备阶段", Spec.FS_SUB, Spec.accent())
	vb.add_child(_title)
	_info = Spec.label("", Spec.FS_CAPTION, Spec.text_dim())
	vb.add_child(_info)

	_list = VBoxContainer.new()
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override("separation", 2)
	vb.add_child(_list)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 6)
	vb.add_child(hb)
	_start_btn = _mk_button("开始执行", true)
	_end_btn = _mk_button("结束执行", false)
	_clear_btn = _mk_button("清空计划", false)
	hb.add_child(_start_btn)
	hb.add_child(_end_btn)
	hb.add_child(_clear_btn)
	_start_btn.pressed.connect(_on_start)
	_end_btn.pressed.connect(_on_end)
	_clear_btn.pressed.connect(_on_clear)
	visible = false


func _mk_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", Spec.FS_BODY)
	b.add_theme_color_override("font_color", Color(1.0, 0.95, 0.82) if primary else Spec.text_main())
	var fill: Color = Color(0.26, 0.20, 0.09, 0.98) if primary else Color(0.10, 0.11, 0.13, 0.96)
	var border: Color = Color(1.0, 0.84, 0.42, 0.95) if primary else Color(0.85, 0.72, 0.40, 0.55)
	b.add_theme_stylebox_override("normal", Spec.button_style(fill, border, null, 5, 10.0, 4.0))
	b.add_theme_stylebox_override("hover", Spec.button_style(
			fill.lightened(0.12), border.lightened(0.1), null, 5, 10.0, 4.0))
	b.add_theme_stylebox_override("pressed", Spec.button_style(
			fill.darkened(0.12), border, border, 5, 10.0, 4.0))
	return b


## HUD 每 0.12s 调一次；内部按签名决定是否重建列表，避免每帧 new 控件。
func refresh() -> void:
	visible = Game.short_match
	if not visible:
		return
	_cmd = _command_system()
	var rc: Node = Game.round_control
	var phase_text: String = "准备阶段"
	if rc != null and rc.has_method("phase_text"):
		phase_text = String(rc.call("phase_text"))
	_title.text = phase_text

	var n: int = 0
	if _cmd != null and _cmd.has_method("planned_count"):
		n = int(_cmd.call("planned_count"))
	var sq_n: int = 0
	if Game.squads != null:
		sq_n = int(Game.squads.call("count"))
	var extra: String = ""
	if Game.squads != null:
		var sel: Node = null
		var scene := _scene_root()
		if scene != null:
			sel = scene.get("selection_system") as Node
		if sel != null and sel.has_method("selected_units"):
			var arr: Array = sel.call("selected_units")
			if not arr.is_empty():
				var sq = Game.squads.call("find_by_member", arr[0])
				if sq != null:
					extra = " · %s %d 人" % [String(sq.get("name")), int(sq.call("alive_count"))]
	_info.text = "计划 %d 条 · 小队 %d 支%s" % [n, sq_n, extra]

	_start_btn.visible = Game.is_prepare()
	_end_btn.visible = Game.is_executing()
	_clear_btn.visible = Game.is_prepare() and n > 0

	# 列表签名：条数 + 每条 kind/squad/point。变了才重建。
	var parts := PackedStringArray()
	parts.append(str(n))
	if _cmd != null and _cmd.has_method("planned_records"):
		var recs: Array = _cmd.call("planned_records")
		for r in recs:
			var p: Variant = r.get("point", Vector3.ZERO)
			var px: float = 0.0
			var pz: float = 0.0
			if p is Vector3:
				px = (p as Vector3).x
				pz = (p as Vector3).z
			parts.append("%d:%d:%.0f:%.0f" % [
				int(r.get("kind")), int(r.get("squad_id")), px, pz])
	var sig: String = "|".join(parts)
	if sig == _sig:
		return
	_sig = sig
	for c in _list.get_children():
		c.queue_free()
	if n == 0:
		var empty := Spec.label("暂无计划：右键地面/敌人，或按 F 再点地面。", Spec.FS_CAPTION,
				Spec.text_dim())
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(empty)
		return
	if _cmd == null or not _cmd.has_method("planned_records"):
		return
	var recs2: Array = _cmd.call("planned_records")
	for i in mini(recs2.size(), 6):
		var r: Dictionary = recs2[i]
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 4)
		var lb := Spec.label("%d. %s" % [i + 1, String(r.get("text", "指令"))],
				Spec.FS_CAPTION, Spec.text_main())
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lb.clip_text = true
		row.add_child(lb)
		var del := Button.new()
		del.text = "×"
		del.focus_mode = Control.FOCUS_NONE
		del.custom_minimum_size = Vector2(24.0, 22.0)
		del.add_theme_font_size_override("font_size", Spec.FS_CAPTION)
		del.add_theme_stylebox_override("normal", Spec.button_style(
				Color(0.10, 0.10, 0.11, 0.9), Color(0.55, 0.40, 0.32, 0.5), null, 4, 2.0, 1.0))
		del.pressed.connect(_on_remove.bind(i))
		row.add_child(del)
		_list.add_child(row)


## 主场景根：正常开局 = current_scene；shot_runner 里主场景是子节点，
## 所以优先用回合控制器的父节点（主场景），拿不到再退回 current_scene。
func _scene_root() -> Node:
	if Game.round_control != null and is_instance_valid(Game.round_control):
		return Game.round_control.get_parent()
	return get_tree().current_scene


func _command_system() -> Node:
	if _cmd != null and is_instance_valid(_cmd):
		return _cmd
	var scene := _scene_root()
	if scene == null:
		return null
	var n := scene.get("command_system") as Node
	if n == null:
		n = scene.get_node_or_null("指令系统")
	return n


func _on_start() -> void:
	var rc: Node = Game.round_control
	if rc != null and rc.has_method("begin_execution"):
		rc.call("begin_execution")


func _on_end() -> void:
	var rc: Node = Game.round_control
	if rc != null and rc.has_method("end_execution"):
		rc.call("end_execution", "手动")


func _on_clear() -> void:
	var cs := _command_system()
	if cs != null and cs.has_method("clear_planned"):
		cs.call("clear_planned")


func _on_remove(i: int) -> void:
	var cs := _command_system()
	if cs != null and cs.has_method("remove_planned"):
		cs.call("remove_planned", i)
