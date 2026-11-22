extends Control
## 职责：战役 HUD —— 顶部**敌方意图栏** + 阶段/倒计时/倍速 + CP/人口 + 双方基地，
##       底部手牌区（建造牌先选格子、攻/防训练牌、策略牌）+ 开战按钮 + 结算面板。
## 属于：Screens/hud（屏幕像素层，不跟 3D 镜头缩放）
##
## 纪律：
##   · 文案全部走 I18n（源码零写死中文）；
##   · 卡片可用性只看 Model 给的 `available / reason`，界面不自己推规则；
##   · 节点名是"可点击契约"（screens.json 的 click 指它），改名要同步 screens.json。

const ACCENT := Color(0.85, 0.71, 0.36)
const TEXT := Color(0.91, 0.93, 0.96)
const MUTED := Color(0.60, 0.65, 0.70)
const PLAYER := Color(0.30, 0.62, 1.00)
const ENEMY := Color(1.00, 0.32, 0.26)
const ATTACK_TINT := Color(0.72, 0.24, 0.20)
const DEFEND_TINT := Color(0.20, 0.42, 0.72)

var _root: Node = null
var _base_p: Label
var _base_e: Label
var _phase: Label
var _timer: Label
var _cp: Label
var _pop: Label
var _sel: Label
var _intent: Label
var _status: Label
var _start_btn: Button
var _speed_btn: Button
var _outpost_btn: Button
var _restart_btn: Button
var _card_grid: GridContainer
var _result_panel: PanelContainer
var _result_label: Label
var _sig := ""
var _bar: PanelContainer = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# CanvasLayer 下的 Control 拿不到父级尺寸，必须自己铺满视口
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
	_build_intent()
	_build_bottom()
	_build_result()


# ===========================================================================
# 顶部
# ===========================================================================
func _build_top() -> void:
	var panel := PanelContainer.new()
	panel.name = "TopBar"
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_left = 14
	panel.offset_right = -14
	panel.offset_top = 10
	panel.offset_bottom = 62
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _panel_style(0.92))
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	margin.add_child(row)

	_base_p = _label(row, 15, PLAYER)
	_base_e = _label(row, 15, ENEMY)
	_phase = _label(row, 15, ACCENT)
	_timer = _label(row, 24, TEXT)
	_cp = _label(row, 16, ACCENT)
	_pop = _label(row, 15, TEXT)
	_sel = _label(row, 15, MUTED)


func _build_intent() -> void:
	var panel := PanelContainer.new()
	panel.name = "IntentPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.offset_left = -330
	panel.offset_right = 330
	panel.offset_top = 68
	panel.offset_bottom = 100
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _panel_style(0.80))
	add_child(panel)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	panel.add_child(m)
	_intent = Label.new()
	_intent.name = "IntentLabel"
	_intent.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_intent.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_intent.add_theme_font_size_override("font_size", 14)
	_intent.add_theme_color_override("font_color", Color(0.93, 0.80, 0.52))
	m.add_child(_intent)


# ===========================================================================
# 底部手牌
# ===========================================================================
func _build_bottom() -> void:
	var panel := PanelContainer.new()
	panel.name = "CardBar"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 14
	panel.offset_right = -14
	panel.offset_top = -140
	panel.offset_bottom = -12
	panel.add_theme_stylebox_override("panel", _panel_style(0.93))
	add_child(panel)
	_bar = panel

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
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
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)

	_card_grid = GridContainer.new()
	_card_grid.name = "CardGrid"
	_card_grid.columns = 9
	_card_grid.add_theme_constant_override("h_separation", 8)
	_card_grid.add_theme_constant_override("v_separation", 6)
	row.add_child(_card_grid)

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	row.add_child(side)

	_outpost_btn = _button(side, I18n.t("battle.outpost.button"), ACCENT, 132)
	_outpost_btn.name = "OutpostButton"
	_outpost_btn.pressed.connect(func() -> void: _root.call("capture_outpost"))

	_start_btn = _button(side, I18n.t("battle.start"), ACCENT, 132)
	_start_btn.name = "StartButton"
	_start_btn.pressed.connect(func() -> void: _root.call("begin_execution"))

	_speed_btn = _button(side, I18n.t("battle.speed_button", {"x": "1"}), TEXT, 132)
	_speed_btn.name = "SpeedButton"
	_speed_btn.pressed.connect(func() -> void: _toggle_speed())


func _build_result() -> void:
	_result_panel = PanelContainer.new()
	_result_panel.name = "ResultPanel"
	_result_panel.set_anchors_preset(Control.PRESET_CENTER)
	_result_panel.offset_left = -260
	_result_panel.offset_right = 260
	_result_panel.offset_top = -110
	_result_panel.offset_bottom = 110
	_result_panel.visible = false
	_result_panel.add_theme_stylebox_override("panel", _panel_style(0.96))
	add_child(_result_panel)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	_result_panel.add_child(col)

	var title := Label.new()
	title.text = I18n.t("battle.result.title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", ACCENT)
	col.add_child(title)

	_result_label = Label.new()
	_result_label.name = "ResultLabel"
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 16)
	_result_label.add_theme_color_override("font_color", TEXT)
	col.add_child(_result_label)

	_restart_btn = _button(col, I18n.t("battle.restart"), ACCENT, 200)
	_restart_btn.name = "RestartButton"
	_restart_btn.pressed.connect(func() -> void: _root.call("restart"))


func _toggle_speed() -> void:
	var cur := float(_root.get("time_scale"))
	_root.call("set_time_scale", 2.0 if cur < 1.5 else 1.0)


# ===========================================================================
# 刷新
# ===========================================================================
func refresh(state: Dictionary, view: Dictionary, phase: String, seconds: float,
		selected_count: int, extra: Dictionary) -> void:
	var php := int(float(view.get("player_hp", 0.0)))
	var phm := int(float(view.get("player_hp_max", 1.0)))
	var ehp := int(float(view.get("enemy_hp", 0.0)))
	var ehm := int(float(view.get("enemy_hp_max", 1.0)))
	_base_p.text = I18n.t("battle.base.player", {"hp": php, "max": phm})
	_base_e.text = I18n.t("battle.base.enemy", {"hp": ehp, "max": ehm})

	match phase:
		"attack":
			_phase.text = I18n.t("battle.phase.attack")
			_timer.text = "%02d" % int(ceil(maxf(seconds, 0.0)))
		"defend":
			_phase.text = I18n.t("battle.phase.defend")
			_timer.text = "%02d" % int(ceil(maxf(seconds, 0.0)))
		"result":
			_phase.text = I18n.t("battle.phase.result")
			_timer.text = "--"
		_:
			_phase.text = I18n.t("battle.phase.planning")
			_timer.text = "--"

	_cp.text = I18n.t("battle.cp", {"cp": int(state.get("cp", 0))})
	_pop.text = I18n.t("battle.pop", {"used": int(state.get("pop_used", 0)), "cap": int(state.get("pop_cap", 0))})
	_sel.text = I18n.t("battle.selected", {"n": selected_count})
	_intent.text = String(extra.get("intent", ""))
	_status.text = String(extra.get("status", ""))

	# 战斗期手牌区没有牌可打，收窄成一条只放过/倍速信息的窄条（少挡战场）
	if _bar != null:
		_bar.offset_top = -140.0 if phase == "planning" else -66.0
	_start_btn.visible = phase == "planning"
	_outpost_btn.visible = phase == "planning" and bool(state.get("outpost_available", false))
	_outpost_btn.disabled = bool(state.get("outpost_captured", false))
	_speed_btn.visible = phase == "attack" or phase == "defend"
	_speed_btn.text = I18n.t("battle.speed_button", {"x": "%.0f" % float(extra.get("time_scale", 1.0))})

	_result_panel.visible = phase == "result"
	if phase == "result":
		_result_label.text = String(extra.get("status", ""))

	var meta: Dictionary = extra.get("cards", {})
	_sync_cards(state, phase, String(extra.get("armed_card", "")), meta)


func _sync_cards(state: Dictionary, phase: String, armed: String, meta: Dictionary) -> void:
	var cards: Array = state.get("train_cards", [])
	var hand: Array = state.get("hand", [])
	var sig := phase + "|" + armed + "|" + str(int(state.get("cp", 0))) + "|" + str(int(state.get("pop_used", 0)))
	sig += "|" + ",".join(hand)
	sig += "|" + str(bool(state.get("outpost_captured", false)))
	for c in cards:
		var card: Dictionary = c
		sig += "|%s:%s:%s" % [String(card.get("card_id", "")), str(bool(card.get("available", false))), str(bool(card.get("in_hand", false)))]
	if sig == _sig:
		return
	_sig = sig

	# 先 remove_child 再 queue_free：只 queue_free 的话老节点在本帧仍占着同名，
	# 新建的按钮会被引擎自动改名（TrainCard_x@2），截图脚本按名字就点不到了。
	for child in _card_grid.get_children():
		_card_grid.remove_child(child)
		child.queue_free()

	# 手牌顺序：建造牌 → 训练牌（攻/防）→ 策略牌。只画"在手里"的牌，没抽到的不占位置。
	var by_id := {}
	for c in cards:
		var card: Dictionary = c
		by_id[String(card.get("card_id", ""))] = card

	for card_id in hand:
		var cid := String(card_id)
		if cid.begins_with("build_"):
			_add_card(cid, by_id, meta, phase, armed, "build")
		elif cid.begins_with("train_"):
			_add_card(cid, by_id, meta, phase, armed, "train")
		elif cid.begins_with("strategy_"):
			_add_card(cid, by_id, meta, phase, armed, "strategy")


func _add_card(card_id: String, by_id: Dictionary, meta: Dictionary, phase: String,
		armed: String, kind: String) -> void:
	var card: Dictionary = by_id.get(card_id, meta.get(card_id, {}))
	var display := String(card.get("display_name", card_id))
	var cost := int(card.get("cost_cp", 0))
	var role := String(card.get("role", ""))
	var available := true
	if kind == "train":
		available = bool(card.get("available", false))
	var enabled := phase == "planning"
	if kind == "train":
		enabled = enabled and available
	var b := Button.new()
	var prefix := "BuildCard_" if kind == "build" else ("TrainCard_" if kind == "train" else "StrategyCard_")
	b.name = prefix + card_id
	b.text = I18n.t("battle.card_cost", {"name": display, "cost": cost})
	b.custom_minimum_size = Vector2(112, 38)
	b.clip_text = true
	b.disabled = not enabled
	b.add_theme_font_size_override("font_size", 13)

	var bg := Color(0.12, 0.15, 0.19, 0.96)
	if kind == "train" and role == "attack":
		bg = ATTACK_TINT.darkened(0.45)
	elif kind == "train" and role == "defend":
		bg = DEFEND_TINT.darkened(0.35)
	elif kind == "build":
		bg = Color(0.15, 0.18, 0.15, 0.96)
	b.add_theme_stylebox_override("normal", _card_style(bg, Color(0.85, 0.71, 0.36, 0.30)))
	if armed == card_id:
		b.add_theme_stylebox_override("normal", _card_style(bg.lightened(0.18), Color(0.98, 0.86, 0.44, 0.95)))
	b.add_theme_stylebox_override("hover", _card_style(bg.lightened(0.12), Color(0.95, 0.82, 0.45, 0.75)))
	b.add_theme_stylebox_override("pressed", _card_style(bg.lightened(0.22), Color(0.98, 0.90, 0.55, 1.0)))
	b.add_theme_stylebox_override("disabled", _card_style(bg.darkened(0.35), Color(0.35, 0.36, 0.34, 0.5)))
	if not available and kind == "train":
		b.tooltip_text = I18n.t("battle.reason." + String(card.get("reason", "ok")))
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_disabled_color", MUTED)
	var cid := card_id
	match kind:
		"build":
			b.pressed.connect(func() -> void: _root.call("arm_build", cid))
		"train":
			b.pressed.connect(func() -> void: _root.call("train_card", cid))
		_:
			b.pressed.connect(func() -> void: _root.call("play_strategy", cid))
	_card_grid.add_child(b)


# ===========================================================================
# 小工具
# ===========================================================================
func _label(parent: Node, size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l


func _button(parent: Node, text: String, color: Color, w: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, 36)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", color)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_stylebox_override("normal", _card_style(Color(0.13, 0.16, 0.20, 0.96), Color(0.85, 0.71, 0.36, 0.42)))
	b.add_theme_stylebox_override("hover", _card_style(Color(0.20, 0.24, 0.29, 0.98), Color(0.95, 0.82, 0.45, 0.8)))
	b.add_theme_stylebox_override("pressed", _card_style(Color(0.26, 0.30, 0.35, 1.0), Color(0.98, 0.90, 0.55, 1.0)))
	b.add_theme_stylebox_override("disabled", _card_style(Color(0.09, 0.10, 0.12, 0.85), Color(0.35, 0.36, 0.34, 0.55)))
	parent.add_child(b)
	return b


func _panel_style(alpha: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.055, 0.07, 0.095, alpha)
	s.border_color = Color(0.85, 0.71, 0.36, 0.32)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	return s


func _card_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 3
	s.content_margin_bottom = 3
	return s
