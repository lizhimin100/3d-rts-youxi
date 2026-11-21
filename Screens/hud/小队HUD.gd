extends Control
## 职责：小队战场 HUD —— 顶栏（双方基地 / 阶段 / CP / 人口 / 选择数）、底部训练牌、
##       指令回执、操作提示、出战提示。所有文案走 I18n，源码零写死中文。
## 属于：Screens/hud

const ACCENT := Color(0.86, 0.72, 0.36)
const TEXT := Color(0.9, 0.92, 0.95)
const MUTED := Color(0.62, 0.66, 0.7)

var _root: Node = null
var _base_p: Label
var _base_e: Label
var _timer: Label
var _phase: Label
var _cp: Label
var _pop: Label
var _sel: Label
var _status: Label
var _spawn_tip: Label
var _start_btn: Button
var _restart_btn: Button
var _card_bar: HBoxContainer
var _card_sig := ""
var _spawn_token := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# CanvasLayer 下的 Control 拿不到父级尺寸，必须自己铺满视口；
	# 窗口/拉伸变化时同步一次（HUD 是屏幕像素层，不跟 3D 镜头缩放）。
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	size = get_viewport_rect().size
	get_viewport().size_changed.connect(_on_viewport_resized)
	_root = get_parent()
	while _root != null and not _root.has_method("train_card"):
		_root = _root.get_parent()
	_build()


func _on_viewport_resized() -> void:
	size = get_viewport_rect().size


func _build() -> void:
	_build_top()
	_build_bottom()
	_build_tips()


func _build_top() -> void:
	var panel := PanelContainer.new()
	panel.name = "TopBar"
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_left = 12
	panel.offset_right = -12
	panel.offset_top = 10
	panel.offset_bottom = 62
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	margin.add_child(row)

	_base_p = _label(row, 15, TEXT)
	_base_e = _label(row, 15, TEXT)
	_phase = _label(row, 15, ACCENT)
	_timer = _label(row, 22, TEXT)
	_cp = _label(row, 15, TEXT)
	_pop = _label(row, 15, TEXT)
	_sel = _label(row, 15, MUTED)


func _build_bottom() -> void:
	var panel := PanelContainer.new()
	panel.name = "CardBarPanel"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 12
	panel.offset_right = -12
	panel.offset_top = -98
	panel.offset_bottom = -10
	panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)

	_status = Label.new()
	_status.name = "StatusLabel"
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", MUTED)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_status)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)

	_card_bar = HBoxContainer.new()
	_card_bar.name = "CardBar"
	_card_bar.add_theme_constant_override("separation", 8)
	row.add_child(_card_bar)

	_start_btn = _button(row, I18n.t("squad.start"), ACCENT)
	_start_btn.name = "StartButton"
	_start_btn.pressed.connect(func() -> void: _root.call("begin_execution"))

	_restart_btn = _button(row, I18n.t("squad.restart"), MUTED)
	_restart_btn.name = "RestartButton"
	_restart_btn.visible = false
	_restart_btn.pressed.connect(func() -> void: _root.call("restart"))

	_spawn_tip = Label.new()
	_spawn_tip.name = "SpawnTip"
	_spawn_tip.visible = false
	_spawn_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spawn_tip.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_spawn_tip.offset_left = -220
	_spawn_tip.offset_right = 220
	_spawn_tip.offset_top = 78
	_spawn_tip.offset_bottom = 110
	_spawn_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spawn_tip.add_theme_font_size_override("font_size", 20)
	_spawn_tip.add_theme_color_override("font_color", ACCENT)
	add_child(_spawn_tip)


func _build_tips() -> void:
	var tips := Label.new()
	tips.name = "Tips"
	tips.text = I18n.t("squad.tips")
	tips.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	tips.offset_left = 16
	tips.offset_right = 900
	tips.offset_top = -124
	tips.offset_bottom = -104
	tips.add_theme_font_size_override("font_size", 12)
	tips.add_theme_color_override("font_color", MUTED)
	add_child(tips)


func _label(parent: Node, size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l


func _button(parent: Node, text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(116, 42)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", color)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_stylebox_override("normal", _button_style(Color(0.12, 0.15, 0.19, 0.95)))
	b.add_theme_stylebox_override("hover", _button_style(Color(0.19, 0.23, 0.28, 0.98)))
	b.add_theme_stylebox_override("pressed", _button_style(Color(0.25, 0.29, 0.34, 1.0)))
	b.add_theme_stylebox_override("disabled", _button_style(Color(0.08, 0.09, 0.11, 0.8)))
	parent.add_child(b)
	return b


func _panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.06, 0.08, 0.11, 0.9)
	s.border_color = Color(0.86, 0.72, 0.36, 0.35)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	return s


func _button_style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = Color(0.86, 0.72, 0.36, 0.4)
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s


func refresh(state: Dictionary, view: Dictionary, phase: String, seconds: float, selected_count: int) -> void:
	var php := int(float(view.get("player_hp", 0.0)))
	var phm := int(float(view.get("player_hp_max", 1.0)))
	var ehp := int(float(view.get("enemy_hp", 0.0)))
	var ehm := int(float(view.get("enemy_hp_max", 1.0)))
	_base_p.text = I18n.t("squad.base.player", {"hp": php, "max": phm})
	_base_e.text = I18n.t("squad.base.enemy", {"hp": ehp, "max": ehm})

	if phase == "executing":
		_phase.text = I18n.t("squad.phase.executing_plain")
		_timer.text = "%02d" % int(ceil(maxf(seconds, 0.0)))
	elif phase == "finished":
		_phase.text = I18n.t("squad.phase.finished")
		_timer.text = "00"
	else:
		_phase.text = I18n.t("squad.phase.planning")
		_timer.text = "--"

	_cp.text = I18n.t("squad.cp", {"cp": int(state.get("cp", 0))})
	_pop.text = I18n.t("squad.pop", {"used": int(state.get("pop_used", 0)), "cap": int(state.get("pop_cap", 0))})
	_sel.text = I18n.t("squad.selected", {"n": selected_count})

	_start_btn.visible = phase == "planning"
	_restart_btn.visible = phase == "finished"

	_sync_cards(state, phase)
	var msg := String(_root.get("status_text"))
	_status.text = msg


func _sync_cards(state: Dictionary, phase: String) -> void:
	var cards: Array = state.get("train_cards", [])
	var sig := phase + "|" + str(int(state.get("cp", 0))) + "|" + str(int(state.get("pop_used", 0)))
	for c in cards:
		var card: Dictionary = c
		sig += "|%s:%s:%s" % [String(card.get("card_id", "")), str(bool(card.get("available", false))), str(bool(card.get("in_hand", false)))]
	if sig == _card_sig:
		return
	_card_sig = sig

	for child in _card_bar.get_children():
		child.queue_free()

	for c in cards:
		var card: Dictionary = c
		var card_id := String(card.get("card_id", ""))
		var card_name := String(card.get("display_name", card_id))
		var cost := int(card.get("cost_cp", 0))
		var available := bool(card.get("available", false)) and phase == "planning"
		var b := Button.new()
		b.name = "TrainCard_" + card_id
		b.text = I18n.t("squad.card_cost", {"name": card_name, "cost": cost})
		b.custom_minimum_size = Vector2(118, 42)
		b.disabled = not available
		b.add_theme_font_size_override("font_size", 14)
		b.add_theme_stylebox_override("normal", _button_style(Color(0.12, 0.15, 0.19, 0.95)))
		b.add_theme_stylebox_override("hover", _button_style(Color(0.19, 0.23, 0.28, 0.98)))
		b.add_theme_stylebox_override("pressed", _button_style(Color(0.25, 0.29, 0.34, 1.0)))
		b.add_theme_stylebox_override("disabled", _button_style(Color(0.08, 0.09, 0.11, 0.8)))
		if not available:
			b.tooltip_text = I18n.t("squad.reason." + String(card.get("reason", "ok")))
			b.add_theme_color_override("font_disabled_color", MUTED)
		var cid := card_id
		b.pressed.connect(func() -> void: _root.call("train_card", cid))
		_card_bar.add_child(b)


func show_spawn_tip(text: String) -> void:
	_spawn_token += 1
	var token := _spawn_token
	_spawn_tip.text = text
	_spawn_tip.visible = true
	await get_tree().create_timer(2.8).timeout
	if is_instance_valid(self) and token == _spawn_token:
		_spawn_tip.visible = false
