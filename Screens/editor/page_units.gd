extends Control
## 01 · 单位与 DPS 靶场对账
## 属于：Screens/editor（开发工具，不进发行版）
##
## 左：12 兵种列表（阵营色条 + 卡面 DPS）
## 中：小队人数 / 三维数 / 射程实时换算 / 13 项攻防穿透 / 模型绑定
## 右：靶子模拟器 —— 直接调 C# CombatCalculator.CombatExpect，显示命中/护甲/承伤/克制/期望/DPS

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")

const NUM_INT := ["squad_size", "attack_range", "hit", "dodge", "armor_pen_flat", "pop_cost"]

var editor: Control = null
var data: RefCounted = null

var _unit: Dictionary = {}
var _unit_id := ""
var _target_id := "alliance_footman"
var _syncing := false
var _bridge_cache: RefCounted = null

var _rows: Dictionary = {}
var _row_dps: Dictionary = {}
var _row_squad: Dictionary = {}
var _row_styles: Dictionary = {}
var _list_box: VBoxContainer = null
var _search: LineEdit = null
var _count_chip: PanelContainer = null

var _hero_name: Label = null
var _hero_id: Label = null
var _hero_chip: PanelContainer = null
var _hero_toggle: Button = null
var _stat_attack: Label = null
var _stat_attack_sub: Label = null
var _stat_speed_sub: Label = null
var _stat_armor: Label = null
var _stat_speed: Label = null
var _stat_range: Label = null
var _range_formula: Label = null
var _stat_armor_sub: Label = null

var _fields: Dictionary = {}
var _model_status: PanelContainer = null
var _placeholder_toggle: Button = null
var _projectile_toggle: Button = null
var _note_field: LineEdit = null

var _target_option: OptionButton = null
var _lock_badge: PanelContainer = null
var _attacker_name: Label = null
var _target_name: Label = null
var _dps_final: Label = null
var _dps_squad: Label = null
var _metric: Dictionary = {}
var _steps: Dictionary = {}
var _bars: Control = null
var _verdict_chip: PanelContainer = null
var _target_info: Label = null
var _formula_label: Label = null


# ===========================================================================
# 构建
# ===========================================================================
func setup(p_editor: Control, p_data: RefCounted) -> void:
	editor = p_editor
	data = p_data
	if get_child_count() > 0:
		return
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 16)
	add_child(root)

	root.add_child(_build_left())
	root.add_child(_build_center())
	root.add_child(_build_right())

	_fill_rows()
	_select_unit("alliance_footman", false)


func refresh() -> void:
	_fill_rows()
	_load_unit()
	_refresh_all_row_dps()


func T(key: String, params: Dictionary = {}) -> String:
	return editor.call("T", key, params) if editor != null else key


# ===========================================================================
# 左：兵种列表
# ===========================================================================
func _build_left() -> Control:
	var panel := ThemeKit.card(ThemeKit.ACCENT, 14.0, 14)
	panel.custom_minimum_size = Vector2(326.0, 0.0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.units.list"), &"EditorH2"))
	head.add_child(ThemeKit.spacer())
	_count_chip = ThemeKit.chip(T("editor.units.list_count", {"n": 12}), ThemeKit.ACCENT)
	head.add_child(_count_chip)
	v.add_child(head)

	_search = ThemeKit.text_field("", T("editor.units.search"))
	_search.text_changed.connect(_on_search)
	v.add_child(_search)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_list_box)

	var hint := ThemeKit.caption(T("editor.units.select_hint"), ThemeKit.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	return panel


func _row_style(selected: bool) -> StyleBoxFlat:
	if selected:
		var sb := ThemeKit.box(Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.13),
			Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.65), 10, 1, 10.0, 7.0)
		sb.border_width_left = 3
		return sb
	return ThemeKit.box(ThemeKit.CARD_DEEP, ThemeKit.STROKE, 10, 1, 10.0, 7.0)


func _fill_rows() -> void:
	if _list_box == null:
		return
	for c in _list_box.get_children():
		c.queue_free()
	_rows.clear()
	_row_dps.clear()
	_row_squad.clear()
	_row_styles.clear()

	for u in data.call("unit_list"):
		var d: Dictionary = u
		var id := String(d.get("id", ""))
		var faction := String(d.get("faction", ""))
		var color := ThemeKit.faction_color(faction)

		var b := Button.new()
		b.name = "unit_row_" + id
		b.custom_minimum_size = Vector2(0.0, 56.0)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_stylebox_override("normal", _row_style(false))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ThemeKit.CARD_HI, Color(color.r, color.g, color.b, 0.55), 10, 1, 10.0, 7.0))
		b.add_theme_stylebox_override("pressed", _row_style(true))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(_select_unit.bind(id, true))
		_list_box.add_child(b)
		_rows[id] = b
		_row_styles[id] = color

		var m := MarginContainer.new()
		m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		m.add_theme_constant_override("margin_left", 8)
		m.add_theme_constant_override("margin_right", 8)
		m.add_theme_constant_override("margin_top", 4)
		m.add_theme_constant_override("margin_bottom", 4)
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(m)

		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.add_child(h)

		var bar := ColorRect.new()
		bar.color = color
		bar.custom_minimum_size = Vector2(3.0, 32.0)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(bar)

		var name_box := VBoxContainer.new()
		name_box.add_theme_constant_override("separation", 0)
		name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		name_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_box.add_child(ThemeKit.label(String(d.get("display_name", id)), &"EditorH3"))
		name_box.add_child(ThemeKit.caption(id, ThemeKit.TEXT_DIM))
		h.add_child(name_box)

		var right := VBoxContainer.new()
		right.add_theme_constant_override("separation", 0)
		right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		right.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var squad := ThemeKit.label("", &"EditorNum")
		squad.add_theme_color_override("font_color", color)
		squad.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		right.add_child(squad)
		var dps := ThemeKit.label("", &"EditorCaps")
		dps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		right.add_child(dps)
		h.add_child(right)
		_row_squad[id] = squad
		_row_dps[id] = dps

		_mono_children_ignore(b)
	_refresh_row_labels()
	var n := (data.call("unit_list") as Array).size()
	ThemeKit.set_chip(_count_chip, T("editor.units.list_count", {"n": n}), ThemeKit.ACCENT)


func _mono_children_ignore(n: Node) -> void:
	for c in n.get_children():
		if c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mono_children_ignore(c)


func _refresh_row_labels() -> void:
	for u in data.call("unit_list"):
		var d: Dictionary = u
		var id := String(d.get("id", ""))
		if _row_squad.has(id):
			var faction := String(d.get("faction", ""))
			var color := ThemeKit.faction_color(faction)
			var sq := _row_squad[id] as Label
			sq.text = "×%d" % int(d.get("squad_size", 1))
			sq.add_theme_color_override("font_color", color)
		if _row_dps.has(id):
			var dps := _row_dps[id] as Label
			dps.text = "DPS %.1f" % _card_dps(d)


func _refresh_all_row_dps() -> void:
	_refresh_row_labels()


func _on_search(text: String) -> void:
	var q := text.strip_edges().to_lower()
	var shown := 0
	for id in _rows.keys():
		var b := _rows[id] as Button
		var d: Dictionary = data.call("unit_by_id", id)
		var hay := (String(id) + " " + String(d.get("display_name", "")) + " " + String(data.call("faction_display", String(d.get("faction", ""))))).to_lower()
		b.visible = q.is_empty() or hay.contains(q)
		if b.visible:
			shown += 1
	if _count_chip != null:
		ThemeKit.set_chip(_count_chip, T("editor.units.list_count", {"n": shown}), ThemeKit.ACCENT)


# ===========================================================================
# 中：单位表单
# ===========================================================================
func _build_center() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	v.add_child(_build_hero())
	v.add_child(_build_triad())
	v.add_child(_build_attrs())
	v.add_child(_build_model())
	return v


func _build_hero() -> Control:
	var panel := ThemeKit.card(ThemeKit.ACCENT, 16.0, 14)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	panel.add_child(h)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	h.add_child(v)
	_hero_name = ThemeKit.label("", &"EditorH1")
	v.add_child(_hero_name)
	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 8)
	_hero_id = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	sub.add_child(_hero_id)
	_hero_chip = ThemeKit.chip("", ThemeKit.ACCENT)
	sub.add_child(_hero_chip)
	v.add_child(sub)

	h.add_child(ThemeKit.spacer())
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 3)
	var squad_row := HBoxContainer.new()
	squad_row.add_theme_constant_override("separation", 6)
	var squad_cap := ThemeKit.caption(T("editor.units.squad"), ThemeKit.TEXT_DIM)
	squad_cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	squad_row.add_child(squad_cap)
	var squad_field := ThemeKit.num_field("", 64.0)
	squad_field.size_flags_horizontal = Control.SIZE_SHRINK_END
	squad_row.add_child(squad_field)
	_fields["squad_size"] = squad_field
	squad_field.text_submitted.connect(_on_num_submitted.bind("squad_size", squad_field, 1.0, 12.0, 1.0))
	squad_field.focus_exited.connect(_on_num_focus_lost.bind("squad_size", squad_field, 1.0, 12.0, 1.0))
	right.add_child(squad_row)
	var cap := ThemeKit.caption(T("editor.common.enabled"), ThemeKit.TEXT_DIM)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(cap)
	_hero_toggle = ThemeKit.toggle("ON / OFF", true, ThemeKit.GREEN, 92.0)
	_hero_toggle.toggled.connect(_on_enabled_toggled)
	right.add_child(_hero_toggle)
	h.add_child(right)
	return panel


func _build_triad() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	h.add_child(_stat_card("editor.units.attack", "_stat_attack", ThemeKit.RED))
	h.add_child(_stat_card("editor.units.armor", "_stat_armor", ThemeKit.GOLD))
	h.add_child(_stat_card("editor.units.speed", "_stat_speed", ThemeKit.GREEN))
	h.add_child(_stat_card("editor.units.range", "_stat_range", ThemeKit.ACCENT))
	return h


func _stat_card(title_key: String, store_key: String, accent: Color) -> Control:
	var p := ThemeKit.inset(ThemeKit.CARD, ThemeKit.STROKE, 12.0, 12)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	p.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var dot := ColorRect.new()
	dot.color = accent
	dot.custom_minimum_size = Vector2(3.0, 12.0)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(dot)
	top.add_child(ThemeKit.field_label(T(title_key)))
	v.add_child(top)
	var big := ThemeKit.big_value("0", accent)
	big.add_theme_font_override("font", ThemeKit.mono_bold_font())
	big.add_theme_font_size_override("font_size", 28)
	v.add_child(big)
	var sub := ThemeKit.caption("", ThemeKit.TEXT_DIM)
	v.add_child(sub)
	match store_key:
		"_stat_attack":
			_stat_attack = big
			_stat_attack_sub = sub
		"_stat_armor":
			_stat_armor = big
			_stat_armor_sub = sub
		"_stat_speed":
			_stat_speed = big
			_stat_speed_sub = sub
		"_stat_range":
			_stat_range = big
			_range_formula = sub
	return p


func _build_attrs() -> Control:
	var panel := ThemeKit.card(ThemeKit.GOLD, 16.0, 14)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	v.add_child(ThemeKit.section_head(T("editor.units.attrs"), T("editor.units.attrs_hint"), ThemeKit.GOLD))

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 7)
	v.add_child(grid)

	_add_num(grid, "hp", "editor.units.hp", 1.0, 0.0, 99999.0)
	_add_num(grid, "attack_damage", "editor.units.damage", 1.0, 0.0, 9999.0)
	_add_num(grid, "attack_cooldown", "editor.units.cooldown", 0.05, 0.05, 120.0)
	_add_num(grid, "attack_range", "editor.units.range", 1.0, 10.0, 2000.0)
	_add_option(grid, "attack_type", "editor.units.attack_type", data.call("attack_types"))
	_add_option(grid, "armor_type", "editor.units.armor_type", data.call("armor_types"))
	_add_num(grid, "armor", "editor.units.armor", 1.0, 0.0, 100.0)
	_add_num(grid, "hit", "editor.units.hit", 1.0, 0.0, 200.0)
	_add_num(grid, "dodge", "editor.units.dodge", 1.0, 0.0, 100.0)
	_add_num(grid, "crit", "editor.units.crit", 0.01, 0.0, 1.0)
	_add_num(grid, "armor_pen_flat", "editor.units.pen_flat", 1.0, 0.0, 1000.0)
	_add_num(grid, "armor_pen_pct", "editor.units.pen_pct", 0.01, 0.0, 1.0)
	_add_num(grid, "move_speed", "editor.units.move_speed", 0.1, 0.1, 10.0)
	return panel


func _field_box(parent: Control, title_key: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(ThemeKit.field_label(T(title_key)))
	parent.add_child(v)
	return v


func _add_num(parent: Control, key: String, title_key: String, step: float, minv: float, maxv: float) -> void:
	var v := _field_box(parent, title_key)
	var le := ThemeKit.num_field("")
	v.add_child(le)
	_fields[key] = le
	le.text_submitted.connect(_on_num_submitted.bind(key, le, minv, maxv, step))
	le.focus_exited.connect(_on_num_focus_lost.bind(key, le, minv, maxv, step))


func _add_option(parent: Control, key: String, title_key: String, items: Array) -> void:
	var v := _field_box(parent, title_key)
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0.0, 34.0)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for it in items:
		opt.add_item(String(it))
	v.add_child(opt)
	_fields[key] = opt
	opt.item_selected.connect(_on_option_selected.bind(key, opt))


func _build_model() -> Control:
	var panel := ThemeKit.card(ThemeKit.GREEN, 16.0, 14)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 9)
	panel.add_child(v)
	var head := ThemeKit.section_head(T("editor.units.model"), T("editor.units.model_path"), ThemeKit.GREEN)
	v.add_child(head)

	var path_row := HBoxContainer.new()
	path_row.add_theme_constant_override("separation", 10)
	path_row.add_child(ThemeKit.field_label(T("editor.units.model_path")))
	var le := ThemeKit.text_field("")
	path_row.add_child(le)
	_fields["model_path"] = le
	le.text_submitted.connect(_on_model_path_submitted)
	le.focus_exited.connect(_on_model_path_focus_lost)
	_model_status = ThemeKit.chip("", ThemeKit.GREEN)
	_model_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	path_row.add_child(_model_status)
	v.add_child(path_row)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 14)
	_placeholder_toggle = ThemeKit.toggle(T("editor.units.placeholder"), false, ThemeKit.GREEN, 142.0)
	_placeholder_toggle.toggled.connect(_on_placeholder_toggled)
	row2.add_child(_placeholder_toggle)
	_projectile_toggle = ThemeKit.toggle(T("editor.units.projectile"), false, ThemeKit.GOLD, 128.0)
	_projectile_toggle.toggled.connect(_on_projectile_toggled)
	row2.add_child(_projectile_toggle)
	row2.add_child(ThemeKit.field_label(T("editor.units.projectile_speed")))
	var pspd := ThemeKit.num_field("", 74.0)
	pspd.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_fields["projectile_speed"] = pspd
	pspd.text_submitted.connect(_on_num_submitted.bind("projectile_speed", pspd, 0.0, 200.0, 1.0))
	pspd.focus_exited.connect(_on_num_focus_lost.bind("projectile_speed", pspd, 0.0, 200.0, 1.0))
	row2.add_child(pspd)
	row2.add_child(ThemeKit.field_label(T("editor.units.pop")))
	var pop := ThemeKit.num_field("", 62.0)
	pop.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_fields["pop_cost"] = pop
	pop.text_submitted.connect(_on_num_submitted.bind("pop_cost", pop, 1.0, 12.0, 1.0))
	pop.focus_exited.connect(_on_num_focus_lost.bind("pop_cost", pop, 1.0, 12.0, 1.0))
	row2.add_child(pop)
	row2.add_child(ThemeKit.field_label(T("editor.units.body")))
	var body := ThemeKit.num_field("", 72.0)
	body.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_fields["body_radius"] = body
	body.text_submitted.connect(_on_num_submitted.bind("body_radius", body, 0.1, 2.0, 0.05))
	body.focus_exited.connect(_on_num_focus_lost.bind("body_radius", body, 0.1, 2.0, 0.05))
	row2.add_child(body)
	v.add_child(row2)

	var note_row := HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 10)
	note_row.add_child(ThemeKit.field_label(T("editor.common.note")))
	_note_field = ThemeKit.text_field("")
	note_row.add_child(_note_field)
	_note_field.text_submitted.connect(_on_note_submitted)
	_note_field.focus_exited.connect(_on_note_focus_lost)
	v.add_child(note_row)
	return panel


# ===========================================================================
# 右：靶子模拟器
# ===========================================================================
func _build_right() -> Control:
	var panel := ThemeKit.card(ThemeKit.PURPLE, 16.0, 14)
	panel.custom_minimum_size = Vector2(628.0, 0.0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override("separation", 1)
	title_box.add_child(ThemeKit.label(T("editor.dps.title"), &"EditorH1"))
	title_box.add_child(ThemeKit.caption(T("editor.dps.subtitle"), ThemeKit.TEXT_SUB))
	head.add_child(title_box)
	head.add_child(ThemeKit.spacer())
	_lock_badge = ThemeKit.chip(T("editor.dps.locked"), ThemeKit.GREEN)
	_lock_badge.name = "dps_lock_badge"
	_lock_badge.visible = false
	head.add_child(_lock_badge)
	v.add_child(head)

	var vs := HBoxContainer.new()
	vs.add_theme_constant_override("separation", 10)
	var atk_box := VBoxContainer.new()
	atk_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	atk_box.add_child(ThemeKit.caption(T("editor.dps.attacker"), ThemeKit.TEXT_DIM))
	_attacker_name = ThemeKit.label("—", &"EditorH3")
	atk_box.add_child(_attacker_name)
	vs.add_child(atk_box)
	var tgt_box := VBoxContainer.new()
	tgt_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tgt_box.add_child(ThemeKit.caption(T("editor.dps.target"), ThemeKit.TEXT_DIM))
	_target_name = ThemeKit.label("—", &"EditorH3")
	tgt_box.add_child(_target_name)
	vs.add_child(tgt_box)
	v.add_child(vs)

	_target_option = OptionButton.new()
	_target_option.custom_minimum_size = Vector2(0.0, 36.0)
	_target_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for u in data.call("unit_list"):
		var d: Dictionary = u
		_target_option.add_item(String(d.get("display_name", d.get("id", ""))))
		_target_option.set_item_metadata(_target_option.item_count - 1, String(d.get("id", "")))
	_target_option.item_selected.connect(_on_target_selected)
	v.add_child(_target_option)

	var big_box := ThemeKit.inset(Color("#111722"), Color(ThemeKit.PURPLE.r, ThemeKit.PURPLE.g, ThemeKit.PURPLE.b, 0.30), 14.0, 12)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 12)
	big_box.add_child(bh)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 0)
	left.add_child(ThemeKit.caption(T("editor.dps.final"), ThemeKit.TEXT_SUB))
	_dps_final = ThemeKit.big_value("0.00", ThemeKit.PURPLE)
	_dps_final.name = "dps_final_value"
	_dps_final.add_theme_font_size_override("font_size", 46)
	bh.add_child(left)
	bh.add_child(ThemeKit.spacer())
	left.add_child(_dps_final)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 1)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sq_cap := ThemeKit.caption(T("editor.dps.squad_dps"), ThemeKit.TEXT_DIM)
	sq_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(sq_cap)
	_dps_squad = ThemeKit.value_label("0.00", ThemeKit.GREEN)
	_dps_squad.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(_dps_squad)
	bh.add_child(right)
	v.add_child(big_box)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	v.add_child(grid)
	_metric["hit"] = _metric_tile(grid, "editor.dps.hit_chance", ThemeKit.GREEN)
	_metric["armor"] = _metric_tile(grid, "editor.dps.eff_armor", ThemeKit.CYAN)
	_metric["taken"] = _metric_tile(grid, "editor.dps.taken", ThemeKit.GOLD)
	_metric["counter"] = _metric_tile(grid, "editor.dps.counter", ThemeKit.RED)
	_metric["hit_damage"] = _metric_tile(grid, "editor.dps.expect_hit", ThemeKit.ACCENT)
	_metric["cooldown"] = _metric_tile(grid, "editor.units.cooldown", ThemeKit.TEXT_SUB)

	_bars = CompareBars.new()
	_bars.custom_minimum_size = Vector2(0.0, 78.0)
	_bars.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(_bars)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	_verdict_chip = ThemeKit.chip("—", ThemeKit.TEXT_SUB)
	bottom.add_child(_verdict_chip)
	_target_info = ThemeKit.caption("", ThemeKit.TEXT_SUB)
	bottom.add_child(_target_info)
	bottom.add_child(ThemeKit.spacer())
	var swap := ThemeKit.small_button(T("editor.dps.swap"), ThemeKit.PURPLE)
	swap.pressed.connect(_on_swap)
	bottom.add_child(swap)
	v.add_child(bottom)

	v.add_child(ThemeKit.hairline(ThemeKit.STROKE))
	var bd_head := HBoxContainer.new()
	bd_head.add_theme_constant_override("separation", 8)
	bd_head.add_child(ThemeKit.label(T("editor.dps.breakdown"), &"EditorH3"))
	bd_head.add_child(ThemeKit.spacer())
	bd_head.add_child(ThemeKit.caption(T("editor.dps.breakdown_hint"), ThemeKit.TEXT_DIM))
	v.add_child(bd_head)
	var sgrid := GridContainer.new()
	sgrid.columns = 3
	sgrid.add_theme_constant_override("h_separation", 8)
	sgrid.add_theme_constant_override("v_separation", 8)
	v.add_child(sgrid)
	var step_defs := [
		["hit", "editor.dps.step_hit", ThemeKit.GREEN],
		["crit", "editor.dps.step_crit", ThemeKit.GOLD],
		["pen", "editor.dps.step_pen", ThemeKit.CYAN],
		["armor", "editor.dps.step_armor", ThemeKit.ACCENT],
		["counter", "editor.dps.step_counter", ThemeKit.RED],
		["final", "editor.dps.step_final", ThemeKit.PURPLE],
	]
	for sd in step_defs:
		var tile := ThemeKit.inset(Color("#151B27"), ThemeKit.STROKE, 8.0, 8)
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var tv := VBoxContainer.new()
		tv.add_theme_constant_override("separation", 0)
		tile.add_child(tv)
		tv.add_child(ThemeKit.caption(T(String(sd[1])), ThemeKit.TEXT_DIM))
		var val := ThemeKit.value_label("—", sd[2] as Color)
		val.add_theme_font_size_override("font_size", 17)
		tv.add_child(val)
		sgrid.add_child(tile)
		_steps[String(sd[0])] = val

	v.add_child(ThemeKit.hairline(ThemeKit.STROKE))
	_formula_label = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	v.add_child(_formula_label)
	var source := ThemeKit.caption(T("editor.dps.source"), ThemeKit.TEXT_DIM)
	v.add_child(source)
	var vsp := Control.new()
	vsp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vsp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(vsp)
	var rules := ThemeKit.inset(Color("#151B27"), ThemeKit.STROKE, 10.0, 9)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 1)
	rules.add_child(rv)
	rv.add_child(ThemeKit.caption(T("editor.dps.rules_title"), ThemeKit.TEXT_DIM))
	rv.add_child(ThemeKit.caption(T("editor.dps.rules_chain"), ThemeKit.TEXT_SUB))
	rv.add_child(ThemeKit.caption(T("editor.dps.rules_const"), ThemeKit.TEXT_DIM))
	v.add_child(rules)
	return panel


func _metric_tile(parent: Control, title_key: String, color: Color) -> Label:
	var p := ThemeKit.inset(Color("#151B27"), ThemeKit.STROKE, 10.0, 9)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	p.add_child(v)
	v.add_child(ThemeKit.caption(T(title_key), ThemeKit.TEXT_DIM))
	var val := ThemeKit.value_label("—", color)
	val.add_theme_font_size_override("font_size", 18)
	v.add_child(val)
	parent.add_child(p)
	return val


class CompareBars extends Control:
	var a_value := 0.0
	var b_value := 0.0
	var a_label := ""
	var b_label := ""
	var a_color := Color("#B18CFF")
	var b_color := Color("#4EA1FF")

	func set_data(av: float, bv: float, al: String, bl: String, ac: Color, bc: Color) -> void:
		a_value = av
		b_value = bv
		a_label = al
		b_label = bl
		a_color = ac
		b_color = bc
		queue_redraw()

	func _draw() -> void:
		var f := get_theme_default_font()
		var w := size.x
		var maxv := maxf(maxf(a_value, b_value), 0.01)
		var rows := [
			[a_label, a_value, a_color, 34.0],
			[b_label, b_value, b_color, 66.0],
		]
		for row in rows:
			var label := String(row[0])
			var val := float(row[1])
			var c: Color = row[2]
			var y := float(row[3])
			if f != null:
				draw_string(f, Vector2(0.0, y - 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color("#96A3BA"))
				draw_string(f, Vector2(w - 58.0, y - 5.0), "%.1f" % val, HORIZONTAL_ALIGNMENT_RIGHT, 58.0, 12, c)
			draw_rect(Rect2(0.0, y, w, 7.0), Color("#111722"))
			draw_rect(Rect2(0.0, y, maxf(w * val / maxv, 2.0), 7.0), Color(c.r, c.g, c.b, 0.82))


# ===========================================================================
# 选中 / 装载
# ===========================================================================
func _select_unit(id: String, user: bool) -> void:
	if id.is_empty():
		return
	var d: Dictionary = data.call("unit_by_id", id)
	if d.is_empty():
		return
	_unit = d
	_unit_id = id
	for rid in _rows.keys():
		var b := _rows[rid] as Button
		var col: Color = _row_styles.get(rid, ThemeKit.ACCENT)
		b.add_theme_stylebox_override("normal", _row_style(rid == id))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ThemeKit.CARD_HI, Color(col.r, col.g, col.b, 0.65), 10, 1, 10.0, 7.0))
	_load_unit()
	_refresh_all_row_dps()
	if user:
		_lock_badge.visible = true


func _load_unit() -> void:
	if _unit.is_empty():
		return
	_syncing = true
	var fid := String(_unit.get("faction", ""))
	_hero_name.text = String(_unit.get("display_name", _unit_id))
	_hero_id.text = _unit_id
	ThemeKit.set_chip(_hero_chip, data.call("faction_display", fid), ThemeKit.faction_color(fid))
	_hero_toggle.button_pressed = bool(_unit.get("enabled", true))
	_hero_toggle.text = T("editor.common.enabled") if bool(_unit.get("enabled", true)) else T("editor.common.disabled")

	for key in _fields.keys():
		var c: Control = _fields[key] as Control
		if c is LineEdit:
			var le := c as LineEdit
			if key == "model_path":
				le.text = String(_unit.get("model_path", ""))
			elif key == "note":
				le.text = String(_unit.get("note", ""))
			else:
				le.text = _format_value(key, _unit.get(key, 0.0))
		elif c is OptionButton:
			var opt := c as OptionButton
			var vals: Array = data.call("attack_types") if key == "attack_type" else data.call("armor_types")
			var cur := String(_unit.get(key, ""))
			for i in vals.size():
				if String(vals[i]) == cur:
					opt.select(i)
					break
	if _note_field != null:
		_note_field.text = String(_unit.get("note", ""))
	_placeholder_toggle.button_pressed = bool(_unit.get("use_placeholder_mesh", false))
	_projectile_toggle.button_pressed = bool(_unit.get("projectile", false))
	_syncing = false
	_refresh_derived()
	_refresh_dps()


func _format_value(key: String, v: Variant) -> String:
	if key in ["squad_size", "attack_range", "hit", "dodge", "armor_pen_flat", "pop_cost", "armor", "attack_damage", "projectile_speed", "hp"]:
		return "%.0f" % float(v)
	if key in ["crit", "armor_pen_pct"]:
		return "%.2f" % float(v)
	if key == "body_radius":
		return "%.2f" % float(v)
	return "%.2f" % float(v)


func _refresh_derived() -> void:
	if _unit.is_empty():
		return
	var fid := String(_unit.get("faction", ""))
	var fc := ThemeKit.faction_color(fid)
	_stat_attack.text = "%.0f" % float(_unit.get("attack_damage", 0.0))
	_stat_armor.text = "%.0f" % float(_unit.get("armor", 0.0))
	_stat_speed.text = "%.1f" % float(_unit.get("move_speed", 0.0))
	_stat_range.text = "%.0f" % float(_unit.get("attack_range", 0.0))
	_stat_attack.modulate = Color.WHITE
	_stat_attack_sub.text = T("editor.units.per_attack", {"v": "%.2f" % float(_unit.get("attack_cooldown", 1.0))})
	_stat_armor_sub.text = String(_unit.get("armor_type", ""))
	_stat_speed_sub.text = T("editor.units.mps")
	var raw := float(_unit.get("attack_range", 0.0))
	_range_formula.text = T("editor.units.range_formula", {"raw": "%.0f" % raw, "m": "%.2f" % float(data.call("meters", raw))})
	_range_formula.add_theme_color_override("font_color", fc)
	var model_path := String(_unit.get("model_path", ""))
	var placeholder := bool(_unit.get("use_placeholder_mesh", false))
	if placeholder:
		ThemeKit.set_chip(_model_status, T("editor.units.placeholder_on"), ThemeKit.GREEN)
	elif model_path.is_empty() or not FileAccess.file_exists(model_path):
		ThemeKit.set_chip(_model_status, T("editor.common.model_missing"), ThemeKit.RED)
	else:
		ThemeKit.set_chip(_model_status, T("editor.common.model_ok"), ThemeKit.GREEN)
	if _row_squad.has(_unit_id):
		var sq := _row_squad[_unit_id] as Label
		sq.text = "×%d" % int(_unit.get("squad_size", 1))
		sq.add_theme_color_override("font_color", fc)


func _refresh_dps() -> void:
	if _unit.is_empty():
		return
	var d: Dictionary = data.call("unit_by_id", _target_id)
	if d.is_empty():
		d = data.call("unit_by_id", "alliance_footman")
	_target_name.text = String(d.get("display_name", _target_id))
	var fid := String(_unit.get("faction", ""))
	_attacker_name.text = String(_unit.get("display_name", _unit_id))
	_attacker_name.add_theme_color_override("font_color", ThemeKit.faction_color(fid))

	var a := _expect(_unit, d)
	var b := _expect(d, _unit)
	var dps := float(a.get("dps", 0.0))
	_dps_final.text = "%.2f" % dps
	_dps_squad.text = "%.1f" % (dps * float(_unit.get("squad_size", 1)))
	var hit := float(a.get("hit_chance", 0.0))
	var armor := float(a.get("effective_armor", 0.0))
	var taken := float(a.get("armor_taken", 1.0))
	var counter := float(a.get("counter", 1.0))
	var dmg := float(a.get("damage", 0.0))
	_metric["hit"].text = "%.0f%%" % (hit * 100.0)
	_metric["armor"].text = "%.2f" % armor
	_metric["taken"].text = "%.0f%%" % (taken * 100.0)
	_metric["counter"].text = "×%.2f" % counter
	_metric["hit_damage"].text = "%.2f" % dmg
	_metric["cooldown"].text = "%.2fs" % float(_unit.get("attack_cooldown", 1.0))
	_metric["counter"].add_theme_color_override("font_color", ThemeKit.GREEN if counter > 1.05 else (ThemeKit.RED if counter < 0.95 else ThemeKit.TEXT))
	var crit := float(_unit.get("crit", 0.0))
	var crit_mult := float((data.get("combat") as Dictionary).get("crit_multiplier", 2.0))
	var crit_factor := 1.0 + crit * (crit_mult - 1.0)
	if _steps.has("hit"):
		_steps["hit"].text = "%.0f%%" % (hit * 100.0)
		_steps["crit"].text = T("editor.dps.crit_factor", {"v": "%.2f" % crit_factor})
		_steps["pen"].text = "%.2f" % armor
		_steps["armor"].text = "%.0f%%" % (taken * 100.0)
		_steps["counter"].text = "×%.2f" % counter
		_steps["counter"].tooltip_text = T("editor.dps.counter_pair", {"atk": String(_unit.get("attack_type", "")), "armor": String(d.get("armor_type", ""))})
		_steps["final"].text = "%.2f" % dps
	var verdict := T("editor.dps.neutral")
	var vcol := ThemeKit.TEXT_SUB
	if counter > 1.05:
		verdict = T("editor.dps.advantage")
		vcol = ThemeKit.GREEN
	elif counter < 0.95:
		verdict = T("editor.dps.penalty")
		vcol = ThemeKit.RED
	ThemeKit.set_chip(_verdict_chip, verdict, vcol)
	_target_info.text = T("editor.dps.target_armor") + " %.0f · %s · " % [float(d.get("armor", 0.0)), String(d.get("armor_type", ""))] + T("editor.dps.target_hp") + " %.0f" % float(d.get("hp", 0.0))
	_formula_label.text = T("editor.dps.formula") + "  ·  " + T("editor.dps.armor_after_pen", {
		"base": "%.0f" % float(d.get("armor", 0.0)),
		"pen": "%.0f" % (float(_unit.get("armor_pen_pct", 0.0)) * 100.0),
		"flat": "%.0f" % float(_unit.get("armor_pen_flat", 0.0)),
	})
	_bars.call("set_data", dps, float(b.get("dps", 0.0)),
		String(_unit.get("display_name", _unit_id)), String(d.get("display_name", _target_id)),
		ThemeKit.faction_color(fid), ThemeKit.faction_color(String(d.get("faction", ""))))
	_sync_target_option()


func _sync_target_option() -> void:
	if _target_option == null:
		return
	for i in _target_option.item_count:
		if String(_target_option.get_item_metadata(i)) == _target_id:
			_target_option.select(i)
			return


func _card_dps(u: Dictionary) -> float:
	var dummy := {
		"armor": 6.0,
		"armor_type": String((data.call("armor_types") as Array)[2]),
		"dodge": 0.0,
	}
	var r := _expect(u, dummy)
	return float(r.get("dps", 0.0))


func _expect(attacker: Dictionary, defender: Dictionary) -> Dictionary:
	var b := _bridge()
	if b == null:
		return {}
	var atk := {
		"damage": float(attacker.get("attack_damage", 0.0)),
		"cooldown": float(attacker.get("attack_cooldown", 1.0)),
		"attack_type": int(data.call("attack_index", String(attacker.get("attack_type", "")))),
		"hit": float(attacker.get("hit", 100.0)),
		"crit": float(attacker.get("crit", 0.0)),
		"crit_multiplier": float((data.get("combat") as Dictionary).get("crit_multiplier", 2.0)),
		"pen_flat": float(attacker.get("armor_pen_flat", 0.0)),
		"pen_pct": float(attacker.get("armor_pen_pct", 0.0)),
		"attack_mult": 1.0,
	}
	var dfn := {
		"armor": float(defender.get("armor", 0.0)),
		"armor_type": int(data.call("armor_index", String(defender.get("armor_type", "")))),
		"dodge": float(defender.get("dodge", 0.0)),
		"armor_mult": 1.0,
		"taken_mult": 1.0,
	}
	var r: Variant = b.call("CombatExpect", atk, dfn, data.get("combat"))
	if r is Dictionary:
		return r as Dictionary
	return {}


func _bridge() -> RefCounted:
	if _bridge_cache != null and is_instance_valid(_bridge_cache):
		return _bridge_cache
	var s := load("res://Game/adapters/bridge.gd")
	if s == null:
		return null
	_bridge_cache = s.call("get_bridge") as RefCounted
	return _bridge_cache


# ===========================================================================
# 输入
# ===========================================================================
func _on_enabled_toggled(on: bool) -> void:
	if _syncing or _unit.is_empty():
		return
	_unit["enabled"] = on
	_hero_toggle.text = T("editor.common.enabled") if on else T("editor.common.disabled")
	editor.call("mark_dirty")
	_refresh_dps()


func _on_placeholder_toggled(on: bool) -> void:
	if _syncing or _unit.is_empty():
		return
	_unit["use_placeholder_mesh"] = on
	editor.call("mark_dirty")
	_refresh_derived()


func _on_projectile_toggled(on: bool) -> void:
	if _syncing or _unit.is_empty():
		return
	_unit["projectile"] = on
	editor.call("mark_dirty")


func _on_num_submitted(text: String, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_num(text, key, le, minv, maxv, step)


func _on_num_focus_lost(key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_num(le.text, key, le, minv, maxv, step)


func _commit_num(raw: String, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	if _syncing or _unit.is_empty():
		return
	var t := raw.strip_edges().replace(",", "")
	var v := float(t) if t.is_valid_float() else float(_unit.get(key, minv))
	v = clampf(v, minv, maxv)
	if step >= 1.0:
		v = round(v)
	_unit[key] = v
	le.text = _format_value(key, v)
	editor.call("mark_dirty")
	_refresh_derived()
	_refresh_dps()
	_refresh_all_row_dps()


func _on_option_selected(index: int, key: String, opt: OptionButton) -> void:
	if _syncing or _unit.is_empty():
		return
	var vals: Array = data.call("attack_types") if key == "attack_type" else data.call("armor_types")
	if index < 0 or index >= vals.size():
		return
	_unit[key] = String(vals[index])
	editor.call("mark_dirty")
	_refresh_derived()
	_refresh_dps()


func _on_model_path_submitted(text: String) -> void:
	_commit_model_path(text)


func _on_model_path_focus_lost() -> void:
	if _fields.has("model_path"):
		_commit_model_path((_fields["model_path"] as LineEdit).text)


func _commit_model_path(text: String) -> void:
	if _syncing or _unit.is_empty():
		return
	_unit["model_path"] = text.strip_edges()
	editor.call("mark_dirty")
	_refresh_derived()


func _on_note_submitted(text: String) -> void:
	if _unit.is_empty():
		return
	_unit["note"] = text.strip_edges()
	editor.call("mark_dirty")


func _on_note_focus_lost() -> void:
	if _note_field != null and not _unit.is_empty():
		_on_note_submitted(_note_field.text)


func _on_target_selected(index: int) -> void:
	if index < 0:
		return
	_target_id = String(_target_option.get_item_metadata(index))
	_refresh_dps()


func _on_swap() -> void:
	if _unit_id == _target_id:
		return
	var old_target := _target_id
	_target_id = _unit_id
	_select_unit(old_target, false)
	_refresh_dps()
