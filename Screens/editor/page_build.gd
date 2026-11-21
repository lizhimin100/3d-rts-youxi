extends Control
## 02 · 建筑与卡牌
## 属于：Screens/editor（开发工具，不进发行版）
##
## 左：4 种建筑；中：人口 / produce_tag / 1~3 星产出 / 3D 模型；
## 右：卡池增删改 + 12 张初始卡组（点卡池行选中，点「加入卡组」）。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")

var editor: Control = null
var data: RefCounted = null

var _building: Dictionary = {}
var _building_id := ""
var _card: Dictionary = {}
var _card_id := ""
var _syncing := false

var _building_rows: Dictionary = {}
var _building_list: VBoxContainer = null
var _building_count: PanelContainer = null

var _hero_name: Label = null
var _hero_id: Label = null
var _hero_chip: PanelContainer = null
var _buildable_toggle: Button = null
var _glyph: Control = null

var _b_fields: Dictionary = {}
var _star_fields: Dictionary = {}
var _b_model_status: PanelContainer = null
var _star_note: Label = null
var _sum_pop: Label = null
var _sum_build: Label = null
var _sum_model: Label = null
var _sum_start: Label = null

var _card_list: VBoxContainer = null
var _card_rows: Dictionary = {}
var _card_count_chip: PanelContainer = null
var _deck_grid: GridContainer = null
var _deck_count: PanelContainer = null
var _deck_add: Button = null
var _card_fields: Dictionary = {}
var _target_option: OptionButton = null
var _kind_option: OptionButton = null
var _exhaust_toggle: Button = null

var _status: Label = null


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
	root.add_child(_build_building_list())
	root.add_child(_build_building_form())
	root.add_child(_build_cards())
	_fill_building_rows()
	_select_building("keep")
	_fill_card_rows()
	if (data.call("cards") as Array).size() > 0:
		_select_card(String((data.call("cards") as Array)[0].get("id", "")))
	_rebuild_deck()


func refresh() -> void:
	_fill_building_rows()
	_fill_card_rows()
	_rebuild_deck()


func T(key: String, params: Dictionary = {}) -> String:
	return editor.call("T", key, params) if editor != null else key


# ===========================================================================
# 左 · 建筑
# ===========================================================================
func _build_building_list() -> Control:
	var panel := ThemeKit.card(ThemeKit.GOLD, 14.0, 14)
	panel.custom_minimum_size = Vector2(304.0, 0.0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.build.list"), &"EditorH2"))
	head.add_child(ThemeKit.spacer())
	_building_count = ThemeKit.chip("", ThemeKit.GOLD)
	head.add_child(_building_count)
	v.add_child(head)

	var sum := ThemeKit.inset(Color("#151B27"), ThemeKit.STROKE, 10.0, 9)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 2)
	sum.add_child(sv)
	sv.add_child(ThemeKit.caption(T("editor.build.summary"), ThemeKit.TEXT_DIM))
	_sum_pop = ThemeKit.value_label("", ThemeKit.GREEN)
	_sum_build = ThemeKit.caption("", ThemeKit.TEXT_SUB)
	_sum_model = ThemeKit.caption("", ThemeKit.TEXT_SUB)
	_sum_start = ThemeKit.caption("", ThemeKit.TEXT_SUB)
	sv.add_child(_sum_pop)
	sv.add_child(_sum_build)
	sv.add_child(_sum_model)
	sv.add_child(_sum_start)
	v.add_child(sum)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_building_list = VBoxContainer.new()
	_building_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_building_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_building_list)

	var hint := ThemeKit.caption(T("editor.build.pick_hint"), ThemeKit.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	return panel


func _fill_building_rows() -> void:
	if _building_list == null:
		return
	for c in _building_list.get_children():
		c.queue_free()
	_building_rows.clear()
	var arr: Array = data.call("buildings")
	for i in arr.size():
		var b: Dictionary = arr[i]
		var id := String(b.get("id", ""))
		var row := Button.new()
		row.name = "building_row_" + id
		row.custom_minimum_size = Vector2(0.0, 84.0)
		row.focus_mode = Control.FOCUS_NONE
		row.add_theme_stylebox_override("normal", _brow_style(false))
		row.add_theme_stylebox_override("hover", ThemeKit.box(ThemeKit.CARD_HI, Color(ThemeKit.GOLD.r, ThemeKit.GOLD.g, ThemeKit.GOLD.b, 0.5), 10, 1, 10.0, 7.0))
		row.add_theme_stylebox_override("pressed", _brow_style(true))
		row.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		row.pressed.connect(_select_building.bind(id))
		_building_list.add_child(row)
		_building_rows[id] = row

		var m := MarginContainer.new()
		m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		m.add_theme_constant_override("margin_left", 10)
		m.add_theme_constant_override("margin_right", 10)
		m.add_theme_constant_override("margin_top", 8)
		m.add_theme_constant_override("margin_bottom", 8)
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(m)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.add_child(h)

		var glyph := BuildingGlyph.new()
		glyph.kind = id
		glyph.custom_minimum_size = Vector2(54.0, 54.0)
		glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(glyph)

		var vv := VBoxContainer.new()
		vv.add_theme_constant_override("separation", 1)
		vv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		vv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vv.add_child(ThemeKit.label(String(b.get("display_name", id)), &"EditorH3"))
		vv.add_child(ThemeKit.caption("%s · %s" % [String(b.get("tag", "")), String(b.get("produce_tag", ""))], ThemeKit.TEXT_DIM))
		h.add_child(vv)

		var right := VBoxContainer.new()
		right.add_theme_constant_override("separation", 1)
		right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		right.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var pop := ThemeKit.value_label("", ThemeKit.GREEN)
		pop.text = "+%d" % int(b.get("pop", 0))
		pop.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		right.add_child(pop)
		var stars := ThemeKit.caption("★☆☆", ThemeKit.TEXT_DIM)
		stars.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		right.add_child(stars)
		h.add_child(right)
		_mono_ignore(row)
	ThemeKit.set_chip(_building_count, T("editor.build.list_count", {"n": arr.size()}), ThemeKit.GOLD)
	_refresh_building_summary()


func _refresh_building_summary() -> void:
	if _sum_pop == null:
		return
	var arr: Array = data.call("buildings")
	var pop := 0
	var buildable := 0
	var models := 0
	for b in arr:
		var d: Dictionary = b
		pop += int(d.get("pop", 0))
		if bool(d.get("buildable", false)):
			buildable += 1
		var mp := String(d.get("model_path", ""))
		if not mp.is_empty() and FileAccess.file_exists(mp):
			models += 1
	_sum_pop.text = T("editor.build.sum_pop", {"v": pop})
	_sum_build.text = T("editor.build.sum_buildable", {"v": buildable, "n": arr.size()})
	_sum_model.text = T("editor.build.sum_models", {"v": models, "n": arr.size()})
	_sum_start.text = T("editor.build.sum_start", {"n": (data.call("start_buildings") as Array).size()})


func _brow_style(selected: bool) -> StyleBoxFlat:
	if selected:
		var sb := ThemeKit.box(Color(ThemeKit.GOLD.r, ThemeKit.GOLD.g, ThemeKit.GOLD.b, 0.12),
			Color(ThemeKit.GOLD.r, ThemeKit.GOLD.g, ThemeKit.GOLD.b, 0.65), 10, 1, 10.0, 7.0)
		sb.border_width_left = 3
		return sb
	return ThemeKit.box(ThemeKit.CARD_DEEP, ThemeKit.STROKE, 10, 1, 10.0, 7.0)


func _mono_ignore(n: Node) -> void:
	for c in n.get_children():
		if c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mono_ignore(c)


class BuildingGlyph extends Control:
	var kind := "keep"
	var accent := Color("#F0B95A")

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var c := Vector2(w * 0.5, h * 0.62)
		draw_circle(Vector2(c.x, h * 0.86), w * 0.34, Color(0.0, 0.0, 0.0, 0.30))
		var base := Color("#243146")
		var edge := Color(accent.r, accent.g, accent.b, 0.85)
		var top := Color(accent.r, accent.g, accent.b, 0.24)
		match kind:
			"keep":
				draw_rect(Rect2(c.x - 16, c.y - 12, 32, 24), base)
				draw_rect(Rect2(c.x - 16, c.y - 12, 32, 4), top)
				for dx in [-16, -4, 8]:
					draw_rect(Rect2(c.x + dx, c.y - 22, 8, 12), base)
					draw_rect(Rect2(c.x + dx, c.y - 22, 8, 3), top)
				draw_line(Vector2(c.x, c.y - 22), Vector2(c.x, c.y - 34), edge, 1.5)
				draw_colored_polygon(PackedVector2Array([Vector2(c.x, c.y - 34), Vector2(c.x + 9, c.y - 31), Vector2(c.x, c.y - 28)]), edge)
			"farm":
				draw_rect(Rect2(c.x - 18, c.y - 8, 30, 18), base)
				draw_colored_polygon(PackedVector2Array([Vector2(c.x - 22, c.y - 8), Vector2(c.x - 3, c.y - 22), Vector2(c.x + 16, c.y - 8)]), top)
				for i in 3:
					draw_line(Vector2(c.x + 6 + i * 5, c.y), Vector2(c.x + 8 + i * 5, c.y + 12), edge, 1.0)
			"barracks":
				draw_rect(Rect2(c.x - 20, c.y - 8, 40, 20), base)
				draw_colored_polygon(PackedVector2Array([Vector2(c.x - 23, c.y - 8), Vector2(c.x, c.y - 22), Vector2(c.x + 23, c.y - 8)]), top)
				draw_line(Vector2(c.x + 16, c.y - 22), Vector2(c.x + 16, c.y - 35), edge, 1.4)
				draw_rect(Rect2(c.x + 16, c.y - 35, 9, 7), Color(edge.r, edge.g, edge.b, 0.55))
			"watchtower", "tower":
				draw_rect(Rect2(c.x - 9, c.y - 18, 18, 30), base)
				draw_rect(Rect2(c.x - 13, c.y - 24, 26, 8), base)
				draw_colored_polygon(PackedVector2Array([Vector2(c.x - 14, c.y - 24), Vector2(c.x, c.y - 36), Vector2(c.x + 14, c.y - 24)]), top)
				draw_line(Vector2(c.x, c.y - 36), Vector2(c.x, c.y - 44), edge, 1.4)
			_:
				draw_rect(Rect2(c.x - 14, c.y - 12, 28, 24), base)
		draw_polyline(PackedVector2Array([Vector2(c.x - 18, c.y + 14), Vector2(c.x + 18, c.y + 14)]), edge, 1.4)


# ===========================================================================
# 中 · 建筑表单
# ===========================================================================
func _build_building_form() -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(568.0, 0.0)
	v.add_theme_constant_override("separation", 12)
	v.add_child(_build_building_hero())
	v.add_child(_build_building_fields())
	v.add_child(_build_star_table())
	v.add_child(_build_start_card())
	return v


func _build_building_hero() -> Control:
	var panel := ThemeKit.card(ThemeKit.GOLD, 16.0, 14)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	panel.add_child(h)
	_glyph = BuildingGlyph.new()
	_glyph.custom_minimum_size = Vector2(96.0, 96.0)
	h.add_child(_glyph)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	h.add_child(v)
	_hero_name = ThemeKit.label("", &"EditorH1")
	v.add_child(_hero_name)
	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 8)
	_hero_id = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	sub.add_child(_hero_id)
	_hero_chip = ThemeKit.chip("", ThemeKit.GOLD)
	sub.add_child(_hero_chip)
	v.add_child(sub)
	h.add_child(ThemeKit.spacer())
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 3)
	var cap := ThemeKit.caption(T("editor.build.buildable"), ThemeKit.TEXT_DIM)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.add_child(cap)
	_buildable_toggle = ThemeKit.toggle("YES / NO", true, ThemeKit.GOLD, 100.0)
	_buildable_toggle.toggled.connect(_on_buildable_toggled)
	right.add_child(_buildable_toggle)
	h.add_child(right)
	return panel


func _build_building_fields() -> Control:
	var panel := ThemeKit.card(ThemeKit.ACCENT, 16.0, 14)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	v.add_child(ThemeKit.section_head(T("editor.build.title"), T("editor.build.form_hint"), ThemeKit.ACCENT))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 7)
	v.add_child(grid)
	_grid_num(grid, "pop", "editor.build.pop", 1.0, 0.0, 999.0)
	_grid_text(grid, "produce_tag", "editor.build.produce_tag")
	_grid_num(grid, "hp", "editor.build.hp", 10.0, 1.0, 99999.0)
	_grid_num(grid, "armor", "editor.build.armor", 1.0, 0.0, 100.0)
	_grid_num(grid, "base_drain_reduction", "editor.build.drain", 0.01, 0.0, 0.9)
	_grid_option(grid, "armor_type", "editor.build.armor_type", data.call("armor_types"))

	var model_row := HBoxContainer.new()
	model_row.add_theme_constant_override("separation", 10)
	model_row.add_child(ThemeKit.field_label(T("editor.common.model")))
	var path := ThemeKit.text_field("")
	model_row.add_child(path)
	_b_fields["model_path"] = path
	path.text_submitted.connect(_on_model_path_submitted)
	path.focus_exited.connect(_on_model_path_focus_lost)
	_b_model_status = ThemeKit.chip("", ThemeKit.GREEN)
	_b_model_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	model_row.add_child(_b_model_status)
	v.add_child(model_row)
	return panel


func _grid_num(parent: Control, key: String, title_key: String, step: float, minv: float, maxv: float) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.custom_minimum_size = Vector2(236.0, 0.0)
	v.add_child(ThemeKit.field_label(T(title_key)))
	var le := ThemeKit.num_field("")
	v.add_child(le)
	parent.add_child(v)
	_b_fields[key] = le
	le.text_submitted.connect(_on_b_num_submitted.bind(key, le, minv, maxv, step))
	le.focus_exited.connect(_on_b_num_focus_lost.bind(key, le, minv, maxv, step))


func _grid_text(parent: Control, key: String, title_key: String) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.custom_minimum_size = Vector2(236.0, 0.0)
	v.add_child(ThemeKit.field_label(T(title_key)))
	var le := ThemeKit.text_field("")
	v.add_child(le)
	parent.add_child(v)
	_b_fields[key] = le
	le.text_submitted.connect(_on_b_text_submitted.bind(key, le))
	le.focus_exited.connect(_on_b_text_focus_lost.bind(key, le))


func _grid_option(parent: Control, key: String, title_key: String, items: Array) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.custom_minimum_size = Vector2(236.0, 0.0)
	v.add_child(ThemeKit.field_label(T(title_key)))
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0.0, 34.0)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for it in items:
		opt.add_item(String(it))
	v.add_child(opt)
	parent.add_child(v)
	_b_fields[key] = opt
	opt.item_selected.connect(_on_b_armor_selected.bind(opt))


func _build_start_card() -> Control:
	var panel := ThemeKit.card(ThemeKit.CYAN, 14.0, 14)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.build.start_title"), &"EditorH3"))
	head.add_child(ThemeKit.caption(T("editor.build.start_hint"), ThemeKit.TEXT_DIM))
	head.add_child(ThemeKit.spacer())
	v.add_child(head)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 6)
	chips.name = "start_chips"
	v.add_child(chips)
	var trains := ThemeKit.caption("", ThemeKit.TEXT_SUB)
	trains.name = "start_trains"
	v.add_child(trains)
	return panel


func _refresh_start_card() -> void:
	# 直接在整页里找：卡牌列表可能正在滚动，不能依赖索引
	var host := _find_child(self, "start_chips")
	var trains := _find_child(self, "start_trains")
	if host == null:
		return
	for c in host.get_children():
		c.queue_free()
	var arr: Array = data.call("start_buildings")
	var colors := [ThemeKit.GOLD, ThemeKit.GREEN, ThemeKit.GREEN, ThemeKit.ACCENT]
	for i in arr.size():
		var it: Dictionary = arr[i]
		var bid := String(it.get("building", ""))
		var bd: Dictionary = data.call("building_by_id", bid)
		var col: Color = colors[i % colors.size()]
		var chip := ThemeKit.chip(T("editor.build.start_item", {
			"name": String(bd.get("display_name", bid)),
			"n": "%02d" % int(it.get("plot", 0)),
		}), col)
		host.add_child(chip)
	if trains != null:
		var trains_arr: Array = _building.get("trains", []) as Array
		var names: Array[String] = []
		for uid in trains_arr:
			var ud: Dictionary = data.call("unit_by_id", String(uid))
			names.append(String(ud.get("display_name", uid)))
		trains.text = T("editor.build.trains_none") if names.is_empty() else T("editor.build.trains_list", {"v": ", ".join(names)})


func _find_child(n: Node, target: String) -> Node:
	for c in n.get_children():
		if String(c.name) == target:
			return c
		var h := _find_child(c, target)
		if h != null:
			return h
	return null


func _build_star_table() -> Control:
	var panel := ThemeKit.card(ThemeKit.GREEN, 16.0, 14)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(ThemeKit.section_head(T("editor.build.star"), T("editor.build.star_note"), ThemeKit.GREEN))

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var star_w := ThemeKit.caption("STAR", ThemeKit.TEXT_DIM)
	star_w.custom_minimum_size = Vector2(64.0, 0.0)
	header.add_child(star_w)
	for key in ["editor.build.star_pop", "editor.build.star_train", "editor.build.star_drain"]:
		var l := ThemeKit.caption(T(key), ThemeKit.TEXT_DIM)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(l)
	v.add_child(header)

	for star in [1, 2, 3]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var chip := ThemeKit.chip(T("editor.build.star_n", {"n": star}), [ThemeKit.ACCENT, ThemeKit.GOLD, ThemeKit.GREEN][star - 1])
		chip.custom_minimum_size = Vector2(64.0, 0.0)
		row.add_child(chip)
		for key in ["pop", "train_slots", "drain_reduction"]:
			var le := ThemeKit.num_field("", 88.0)
			row.add_child(le)
			_star_fields["%d_%s" % [star, key]] = le
			var step := 1.0 if key != "drain_reduction" else 0.01
			var maxv := 999.0 if key != "drain_reduction" else 0.9
			le.text_submitted.connect(_on_star_submitted.bind(star, key, le, 0.0, maxv, step))
			le.focus_exited.connect(_on_star_focus_lost.bind(star, key, le, 0.0, maxv, step))
		v.add_child(row)
	_star_note = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	v.add_child(_star_note)
	return panel


func _select_building(id: String) -> void:
	var b: Dictionary = data.call("building_by_id", id)
	if b.is_empty():
		return
	_building = b
	_building_id = id
	for rid in _building_rows.keys():
		var row := _building_rows[rid] as Button
		row.add_theme_stylebox_override("normal", _brow_style(rid == id))
	_load_building()


func _load_building() -> void:
	if _building.is_empty():
		return
	_syncing = true
	var name := String(_building.get("display_name", _building_id))
	_hero_name.text = name
	_hero_id.text = _building_id
	ThemeKit.set_chip(_hero_chip, String(_building.get("tag", "")), ThemeKit.GOLD)
	_buildable_toggle.button_pressed = bool(_building.get("buildable", false))
	_buildable_toggle.text = T("editor.build.buildable_on") if bool(_building.get("buildable", false)) else T("editor.build.buildable_off")
	if _glyph != null:
		_glyph.kind = _building_id
		_glyph.queue_redraw()

	for key in _b_fields.keys():
		var c: Control = _b_fields[key] as Control
		if c is LineEdit:
			var le := c as LineEdit
			if key == "model_path" or key == "produce_tag":
				le.text = String(_building.get(key, ""))
			else:
				le.text = _fmt_b(key, _building.get(key, 0.0))
		elif c is OptionButton:
			var opt := c as OptionButton
			var cur := String(_building.get("armor_type", ""))
			for i in opt.item_count:
				if opt.get_item_text(i) == cur:
					opt.select(i)
					break

	var stars: Array = _building.get("star_output", []) as Array
	for star in [1, 2, 3]:
		var sd: Dictionary = stars[star - 1] if star - 1 < stars.size() else {}
		for key in ["pop", "train_slots", "drain_reduction"]:
			var le := _star_fields.get("%d_%s" % [star, key]) as LineEdit
			if le != null:
				le.text = _fmt_b(key, sd.get(key, 0.0))
	_syncing = false
	_refresh_building_status()
	_star_note.text = "%s · %s" % [T("editor.build.star_note"), String(_building.get("model_path", ""))]
	_refresh_start_card()


func _fmt_b(key: String, v: Variant) -> String:
	if key == "drain_reduction" or key == "base_drain_reduction":
		return "%.2f" % float(v)
	if key == "armor" or key == "pop" or key == "train_slots" or key == "hp":
		return "%.0f" % float(v)
	return "%.1f" % float(v)


func _refresh_building_status() -> void:
	var path := String(_building.get("model_path", ""))
	if path.is_empty() or not FileAccess.file_exists(path):
		ThemeKit.set_chip(_b_model_status, T("editor.common.model_missing"), ThemeKit.RED)
	else:
		ThemeKit.set_chip(_b_model_status, T("editor.common.model_ok"), ThemeKit.GREEN)


func _on_buildable_toggled(on: bool) -> void:
	if _syncing or _building.is_empty():
		return
	_building["buildable"] = on
	_buildable_toggle.text = T("editor.build.buildable_on") if on else T("editor.build.buildable_off")
	editor.call("mark_dirty")


func _on_b_num_submitted(text: String, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_b_num(text, key, le, minv, maxv, step)


func _on_b_num_focus_lost(key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_b_num(le.text, key, le, minv, maxv, step)


func _commit_b_num(raw: String, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	if _syncing or _building.is_empty():
		return
	var t := raw.strip_edges().replace(",", "")
	var v := float(t) if t.is_valid_float() else float(_building.get(key, minv))
	v = clampf(v, minv, maxv)
	if step >= 1.0:
		v = round(v)
	_building[key] = v
	le.text = _fmt_b(key, v)
	editor.call("mark_dirty")
	_fill_building_rows()
	_select_building(_building_id)


func _on_b_text_submitted(text: String, key: String, le: LineEdit) -> void:
	_commit_b_text(text, key, le)


func _on_b_text_focus_lost(key: String, le: LineEdit) -> void:
	_commit_b_text(le.text, key, le)


func _commit_b_text(text: String, key: String, le: LineEdit) -> void:
	if _syncing or _building.is_empty():
		return
	_building[key] = text.strip_edges()
	editor.call("mark_dirty")
	if key == "model_path":
		_refresh_building_status()
		_star_note.text = "%s · %s" % [T("editor.build.star_note"), text.strip_edges()]


func _on_b_armor_selected(index: int, opt: OptionButton) -> void:
	if _syncing or _building.is_empty() or index < 0:
		return
	_building["armor_type"] = opt.get_item_text(index)
	editor.call("mark_dirty")


func _on_model_path_submitted(text: String) -> void:
	_commit_b_text(text, "model_path", _b_fields["model_path"] as LineEdit)


func _on_model_path_focus_lost() -> void:
	var le := _b_fields.get("model_path") as LineEdit
	if le != null:
		_commit_b_text(le.text, "model_path", le)


func _on_star_submitted(text: String, star: int, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_star(text, star, key, le, minv, maxv, step)


func _on_star_focus_lost(star: int, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_star(le.text, star, key, le, minv, maxv, step)


func _commit_star(raw: String, star: int, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	if _syncing or _building.is_empty():
		return
	var stars: Array = _building.get("star_output", []) as Array
	if star - 1 >= stars.size():
		return
	var sd: Dictionary = stars[star - 1]
	var t := raw.strip_edges().replace(",", "")
	var v := float(t) if t.is_valid_float() else float(sd.get(key, minv))
	v = clampf(v, minv, maxv)
	if step >= 1.0:
		v = round(v)
	sd[key] = v
	le.text = _fmt_b(key, v)
	editor.call("mark_dirty")
	_fill_building_rows()


# ===========================================================================
# 右 · 卡牌 + 卡组
# ===========================================================================
func _build_cards() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	v.add_child(_build_card_pool())
	v.add_child(_build_card_detail())
	v.add_child(_build_deck())
	return v


func _build_card_pool() -> Control:
	var panel := ThemeKit.card(ThemeKit.PURPLE, 14.0, 14)
	panel.custom_minimum_size = Vector2(0.0, 356.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.cards.title"), &"EditorH2"))
	_card_count_chip = ThemeKit.chip("", ThemeKit.PURPLE)
	head.add_child(_card_count_chip)
	head.add_child(ThemeKit.spacer())
	var add := ThemeKit.small_button(T("editor.common.add"), ThemeKit.GREEN)
	add.pressed.connect(_on_add_card)
	head.add_child(add)
	var dup := ThemeKit.small_button(T("editor.common.duplicate"), ThemeKit.CYAN)
	dup.pressed.connect(_on_duplicate_card)
	head.add_child(dup)
	var del := ThemeKit.small_button(T("editor.common.delete"), ThemeKit.RED)
	del.pressed.connect(_on_delete_card)
	head.add_child(del)
	v.add_child(head)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var kw := ThemeKit.caption(T("editor.cards.kind"), ThemeKit.TEXT_DIM)
	kw.custom_minimum_size = Vector2(62.0, 0.0)
	header.add_child(kw)
	var nw := ThemeKit.caption(T("editor.cards.name"), ThemeKit.TEXT_DIM)
	nw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(nw)
	var cw := ThemeKit.caption("CP", ThemeKit.TEXT_DIM)
	cw.custom_minimum_size = Vector2(42.0, 0.0)
	header.add_child(cw)
	var tw := ThemeKit.caption("×", ThemeKit.TEXT_DIM)
	tw.custom_minimum_size = Vector2(34.0, 0.0)
	header.add_child(tw)
	v.add_child(header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_card_list = VBoxContainer.new()
	_card_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_card_list)
	return panel


func _fill_card_rows() -> void:
	if _card_list == null:
		return
	for c in _card_list.get_children():
		c.queue_free()
	_card_rows.clear()
	var arr: Array = data.call("cards")
	for i in arr.size():
		var c: Dictionary = arr[i]
		var id := String(c.get("id", ""))
		var b := Button.new()
		b.name = "card_row_" + id
		b.custom_minimum_size = Vector2(0.0, 36.0)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_stylebox_override("normal", _crow_style(false))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ThemeKit.CARD_HI, Color(ThemeKit.PURPLE.r, ThemeKit.PURPLE.g, ThemeKit.PURPLE.b, 0.5), 8, 1, 8.0, 5.0))
		b.add_theme_stylebox_override("pressed", _crow_style(true))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(_select_card.bind(id))
		_card_list.add_child(b)
		_card_rows[id] = b

		var m := MarginContainer.new()
		m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		m.add_theme_constant_override("margin_left", 8)
		m.add_theme_constant_override("margin_right", 8)
		m.add_theme_constant_override("margin_top", 3)
		m.add_theme_constant_override("margin_bottom", 3)
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(m)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.add_child(h)

		var kind := String(c.get("kind", ""))
		var chip := ThemeKit.chip(T("editor.cards.kind_" + kind), _kind_color(kind))
		chip.custom_minimum_size = Vector2(58.0, 0.0)
		h.add_child(chip)
		var name := ThemeKit.label(String(c.get("display_name", id)), &"EditorBody")
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		h.add_child(name)
		var cost := ThemeKit.value_label("%d" % int(c.get("cost_cp", 0)), ThemeKit.GOLD)
		cost.custom_minimum_size = Vector2(42.0, 0.0)
		h.add_child(cost)
		var count := ThemeKit.caption("×%d" % int(c.get("count", 1)), ThemeKit.TEXT_SUB)
		count.custom_minimum_size = Vector2(34.0, 0.0)
		h.add_child(count)
		var ex := ThemeKit.label("E" if bool(c.get("exhaust", false)) else "↻", &"EditorCaps",
			ThemeKit.GOLD if bool(c.get("exhaust", false)) else ThemeKit.GREEN)
		ex.custom_minimum_size = Vector2(20.0, 0.0)
		h.add_child(ex)
		_mono_ignore(b)
	ThemeKit.set_chip(_card_count_chip, "%d" % arr.size(), ThemeKit.PURPLE)


func _kind_color(kind: String) -> Color:
	match kind:
		"build":
			return ThemeKit.GOLD
		"train":
			return ThemeKit.ACCENT
		"strategy":
			return ThemeKit.PURPLE
	return ThemeKit.TEXT_SUB


func _crow_style(selected: bool) -> StyleBoxFlat:
	if selected:
		var sb := ThemeKit.box(Color(ThemeKit.PURPLE.r, ThemeKit.PURPLE.g, ThemeKit.PURPLE.b, 0.12),
			Color(ThemeKit.PURPLE.r, ThemeKit.PURPLE.g, ThemeKit.PURPLE.b, 0.6), 8, 1, 8.0, 5.0)
		sb.border_width_left = 3
		return sb
	return ThemeKit.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 8, 0, 8.0, 5.0)


func _build_card_detail() -> Control:
	var panel := ThemeKit.card(ThemeKit.CYAN, 14.0, 14)
	panel.custom_minimum_size = Vector2(0.0, 222.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	v.add_child(ThemeKit.section_head(T("editor.cards.edit"), T("editor.cards.title_hint"), ThemeKit.CYAN))

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 8)
	_card_text(row1, "id", "editor.cards.id")
	_card_text(row1, "display_name", "editor.cards.name")
	v.add_child(row1)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	_kind_option = _card_option(row2, "editor.cards.kind", ["build", "train", "strategy"],
		["editor.cards.kind_build", "editor.cards.kind_train", "editor.cards.kind_strategy"])
	_target_option = _card_option(row2, "editor.cards.target", [], [])
	_card_num(row2, "cost_cp", "editor.cards.cost", 1.0, 0.0, 99.0)
	_card_num(row2, "count", "editor.cards.count", 1.0, 1.0, 99.0)
	v.add_child(row2)

	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 8)
	_card_text(row3, "tag", "editor.build.produce_tag")
	_exhaust_toggle = ThemeKit.toggle(T("editor.cards.exhaust"), false, ThemeKit.GOLD, 150.0)
	_exhaust_toggle.toggled.connect(_on_exhaust_toggled)
	row3.add_child(_exhaust_toggle)
	row3.add_child(ThemeKit.spacer())
	_status = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row3.add_child(_status)
	v.add_child(row3)
	return panel


func _card_text(parent: Control, key: String, title_key: String) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(ThemeKit.field_label(T(title_key)))
	var le := ThemeKit.text_field("")
	v.add_child(le)
	parent.add_child(v)
	_card_fields[key] = le
	le.text_submitted.connect(_on_card_text_submitted.bind(key, le))
	le.focus_exited.connect(_on_card_text_focus_lost.bind(key, le))


func _card_num(parent: Control, key: String, title_key: String, step: float, minv: float, maxv: float) -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.custom_minimum_size = Vector2(80.0, 0.0)
	v.add_child(ThemeKit.field_label(T(title_key)))
	var le := ThemeKit.num_field("", 80.0)
	v.add_child(le)
	parent.add_child(v)
	_card_fields[key] = le
	le.text_submitted.connect(_on_card_num_submitted.bind(key, le, minv, maxv, step))
	le.focus_exited.connect(_on_card_num_focus_lost.bind(key, le, minv, maxv, step))


func _card_option(parent: Control, title_key: String, values: Array, label_keys: Array) -> OptionButton:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(ThemeKit.field_label(T(title_key)))
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0.0, 34.0)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in values.size():
		opt.add_item(T(String(label_keys[i])) if i < label_keys.size() else String(values[i]))
		opt.set_item_metadata(opt.item_count - 1, String(values[i]))
	v.add_child(opt)
	parent.add_child(v)
	if title_key == "editor.cards.kind":
		_kind_option = opt
		opt.item_selected.connect(_on_kind_selected)
	else:
		_target_option = opt
		opt.item_selected.connect(_on_card_target_selected)
	return opt


func _select_card(id: String) -> void:
	var c: Dictionary = data.call("card_by_id", id)
	if c.is_empty():
		return
	_card = c
	_card_id = id
	for rid in _card_rows.keys():
		var row := _card_rows[rid] as Button
		row.add_theme_stylebox_override("normal", _crow_style(rid == id))
	_load_card()


func _load_card() -> void:
	if _card.is_empty():
		return
	_syncing = true
	(_card_fields["id"] as LineEdit).text = _card_id
	(_card_fields["display_name"] as LineEdit).text = String(_card.get("display_name", ""))
	(_card_fields["cost_cp"] as LineEdit).text = "%d" % int(_card.get("cost_cp", 0))
	(_card_fields["count"] as LineEdit).text = "%d" % int(_card.get("count", 1))
	(_card_fields["tag"] as LineEdit).text = String(_card.get("tag", ""))
	_exhaust_toggle.button_pressed = bool(_card.get("exhaust", false))
	var kind := String(_card.get("kind", "build"))
	var kinds := ["build", "train", "strategy"]
	_kind_option.select(maxi(kinds.find(kind), 0))
	var tag_box := (_card_fields["tag"] as LineEdit).get_parent() as Control
	if tag_box != null:
		tag_box.visible = kind == "train"
	_rebuild_target_choices(kind)
	_syncing = false
	_status.text = String(_card.get("id", ""))


func _rebuild_target_choices(kind: String) -> void:
	if _target_option == null:
		return
	_target_option.clear()
	var values: Array = []
	var labels: Array = []
	if kind == "build":
		for b in data.call("buildings"):
			values.append(String(b.get("id", "")))
			labels.append(String(b.get("display_name", "")))
	elif kind == "train":
		for u in data.call("unit_list"):
			values.append(String(u.get("id", "")))
			labels.append(String(u.get("display_name", "")))
	else:
		var strs: Dictionary = data.call("strategies")
		for key in strs.keys():
			values.append(String(key))
			labels.append(String((strs[key] as Dictionary).get("display_name", key)))
	for i in values.size():
		_target_option.add_item(String(labels[i]))
		_target_option.set_item_metadata(i, String(values[i]))
	var cur := ""
	if kind == "build":
		cur = String(_card.get("building", ""))
	elif kind == "train":
		cur = String(_card.get("unit", ""))
	else:
		cur = String(_card.get("effect", ""))
	for i in _target_option.item_count:
		if String(_target_option.get_item_metadata(i)) == cur:
			_target_option.select(i)
			break
	if _target_option.item_count > 0 and _target_option.selected < 0:
		_target_option.select(0)


func _on_kind_selected(index: int) -> void:
	if _syncing or _card.is_empty() or index < 0:
		return
	var kind := String(_kind_option.get_item_metadata(index))
	_card["kind"] = kind
	_card.erase("building")
	_card.erase("unit")
	_card.erase("effect")
	if kind == "build":
		_card["building"] = "farm"
		_card["exhaust"] = true
	elif kind == "train":
		_card["unit"] = "alliance_footman"
		_card["tag"] = "barracks"
		_card["exhaust"] = false
	else:
		_card["effect"] = "focus"
		_card["exhaust"] = false
	_exhaust_toggle.button_pressed = bool(_card.get("exhaust", false))
	editor.call("mark_dirty")
	_rebuild_target_choices(kind)
	_fill_card_rows()
	_select_card(_card_id)


func _on_card_target_selected(index: int) -> void:
	if _syncing or _card.is_empty() or index < 0:
		return
	var val := String(_target_option.get_item_metadata(index))
	var kind := String(_card.get("kind", "build"))
	if kind == "build":
		_card["building"] = val
	elif kind == "train":
		_card["unit"] = val
	else:
		_card["effect"] = val
	editor.call("mark_dirty")


func _on_exhaust_toggled(on: bool) -> void:
	if _syncing or _card.is_empty():
		return
	_card["exhaust"] = on
	editor.call("mark_dirty")
	_fill_card_rows()
	_select_card(_card_id)


func _on_card_text_submitted(text: String, key: String, le: LineEdit) -> void:
	_commit_card_text(text, key, le)


func _on_card_text_focus_lost(key: String, le: LineEdit) -> void:
	_commit_card_text(le.text, key, le)


func _commit_card_text(text: String, key: String, le: LineEdit) -> void:
	if _syncing or _card.is_empty():
		return
	var v := text.strip_edges()
	if key == "id":
		var old := _card_id
		if v == old:
			return
		if not bool(data.call("rename_card_id", old, v)):
			le.text = old
			_status.text = "id exists / empty"
			return
		_card_id = v
		le.text = v
		_status.text = v
	else:
		_card[key] = v
		if key == "display_name":
			data.call("set_display_name", "card", _card_id, v)
	editor.call("mark_dirty")
	_fill_card_rows()
	_select_card(_card_id)
	_rebuild_deck()


func _on_card_num_submitted(text: String, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_card_num(text, key, le, minv, maxv, step)


func _on_card_num_focus_lost(key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	_commit_card_num(le.text, key, le, minv, maxv, step)


func _commit_card_num(raw: String, key: String, le: LineEdit, minv: float, maxv: float, step: float) -> void:
	if _syncing or _card.is_empty():
		return
	var t := raw.strip_edges()
	var v := float(t) if t.is_valid_float() else float(_card.get(key, minv))
	v = clampf(v, minv, maxv)
	if step >= 1.0:
		v = round(v)
	_card[key] = int(v) if step >= 1.0 else v
	le.text = "%d" % int(v) if step >= 1.0 else "%.2f" % v
	editor.call("mark_dirty")
	_fill_card_rows()
	_select_card(_card_id)


func _on_add_card() -> void:
	var n := (data.call("cards") as Array).size() + 1
	var id := "card_%02d" % n
	while not (data.call("card_by_id", id) as Dictionary).is_empty():
		n += 1
		id = "card_%02d" % n
	var c: Dictionary = data.call("add_card", id, T("editor.cards.new_name"), "build")
	editor.call("mark_dirty")
	_fill_card_rows()
	_select_card(String(c.get("id", id)))
	_rebuild_deck()


func _on_duplicate_card() -> void:
	if _card.is_empty():
		return
	var base := _card_id + "_copy"
	var id := base
	var n := 2
	while not (data.call("card_by_id", id) as Dictionary).is_empty():
		id = base + str(n)
		n += 1
	var c: Dictionary = data.call("add_card", id, String(_card.get("display_name", id)) + " " + T("editor.cards.copy_suffix"), String(_card.get("kind", "build")))
	for key in _card.keys():
		if key in ["id", "display_name", "kind"]:
			continue
		c[key] = _card[key]
	editor.call("mark_dirty")
	_fill_card_rows()
	_select_card(id)


func _on_delete_card() -> void:
	if _card_id.is_empty():
		return
	data.call("remove_card", _card_id)
	editor.call("mark_dirty")
	_card = {}
	_card_id = ""
	_fill_card_rows()
	_rebuild_deck()
	var arr: Array = data.call("cards")
	if not arr.is_empty():
		_select_card(String((arr[0] as Dictionary).get("id", "")))


func _build_deck() -> Control:
	var panel := ThemeKit.card(ThemeKit.GREEN, 14.0, 14)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.cards.deck"), &"EditorH2"))
	_deck_count = ThemeKit.chip("", ThemeKit.GREEN)
	head.add_child(_deck_count)
	head.add_child(ThemeKit.spacer())
	_deck_add = ThemeKit.small_button(T("editor.cards.add_deck"), ThemeKit.GREEN)
	_deck_add.pressed.connect(_on_add_to_deck)
	head.add_child(_deck_add)
	v.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_deck_grid = GridContainer.new()
	_deck_grid.columns = 6
	_deck_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_grid.add_theme_constant_override("h_separation", 6)
	_deck_grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(_deck_grid)

	var hint := ThemeKit.caption(T("editor.cards.deck_help"), ThemeKit.TEXT_DIM)
	v.add_child(hint)
	return panel


func _rebuild_deck() -> void:
	if _deck_grid == null:
		return
	for c in _deck_grid.get_children():
		c.queue_free()
	var deck: Array = data.call("deck_start")
	for i in deck.size():
		var cid := String(deck[i])
		var c: Dictionary = data.call("card_by_id", cid)
		var kind := String(c.get("kind", "build"))
		var mini := ThemeKit.inset(ThemeKit.CARD_DEEP, ThemeKit.STROKE, 8.0, 9)
		mini.custom_minimum_size = Vector2(0.0, 76.0)
		mini.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mv := VBoxContainer.new()
		mv.add_theme_constant_override("separation", 1)
		mini.add_child(mv)
		var top := HBoxContainer.new()
		top.add_theme_constant_override("separation", 4)
		top.add_child(ThemeKit.caption("%02d" % (i + 1), ThemeKit.TEXT_DIM))
		top.add_child(ThemeKit.spacer())
		var chip := ThemeKit.chip(T("editor.cards.kind_" + kind), _kind_color(kind))
		top.add_child(chip)
		mv.add_child(top)
		var name := ThemeKit.label(String(c.get("display_name", cid)), &"EditorBody")
		name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		mv.add_child(name)
		var bottom := HBoxContainer.new()
		bottom.add_child(ThemeKit.caption("CP %d" % int(c.get("cost_cp", 0)), ThemeKit.GOLD))
		bottom.add_child(ThemeKit.spacer())
		var rm := Button.new()
		rm.text = "×"
		rm.focus_mode = Control.FOCUS_NONE
		rm.custom_minimum_size = Vector2(20.0, 18.0)
		rm.add_theme_font_size_override("font_size", 13)
		rm.add_theme_color_override("font_color", ThemeKit.TEXT_DIM)
		rm.add_theme_color_override("font_hover_color", ThemeKit.RED)
		rm.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		rm.add_theme_stylebox_override("hover", ThemeKit.box(Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.15), Color(0, 0, 0, 0), 4, 0, 0.0, 0.0))
		rm.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
		rm.pressed.connect(_on_remove_deck.bind(i))
		bottom.add_child(rm)
		mv.add_child(bottom)
		_deck_grid.add_child(mini)

	var n := deck.size()
	ThemeKit.set_chip(_deck_count, T("editor.cards.deck_count", {"n": n}), ThemeKit.GREEN if n == 12 else ThemeKit.GOLD)
	if _deck_add != null:
		_deck_add.disabled = n >= 12
		_deck_add.tooltip_text = T("editor.cards.deck_full") if n >= 12 else T("editor.cards.deck_help")


func _on_add_to_deck() -> void:
	if _card_id.is_empty():
		return
	if not bool(data.call("add_deck_card", _card_id)):
		return
	editor.call("mark_dirty")
	_rebuild_deck()


func _on_remove_deck(index: int) -> void:
	data.call("remove_deck_at", index)
	editor.call("mark_dirty")
	_rebuild_deck()


func _on_card_target_selected_dummy(_i: int) -> void:
	pass
