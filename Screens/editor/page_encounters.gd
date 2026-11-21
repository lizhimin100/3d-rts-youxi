@tool
extends Control
## 04 · 敌人遭遇卡（enemy_encounters.json）
## 属于：Screens/editor（开发工具，不进发行版）
##
## 口径：阵营（豺狼人/鱼人）、敌方基地血量、敌方石台上的固定建筑外观、
##       按轮次权重的敌方攻防意图池表（attack / defend 各自归一化到 100）。
## 点底壳俯视图里的敌方石台 = 选中；右侧可给该石台挂固定建筑。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const LayoutCanvas := preload("res://Screens/editor/layout_canvas.gd")
const ShellStore := preload("res://Screens/editor/shell_store.gd")

var editor: Control = null
var data: RefCounted = null

var _current := ""
var _selected_platform := -1
var _list_box: VBoxContainer = null
var _list_count: Label = null
var _canvas: Control = null
var _faction_opt: OptionButton = null
var _hp_edit: LineEdit = null
var _name_edit: LineEdit = null
var _build_rows: VBoxContainer = null
var _intent_rows: VBoxContainer = null
var _faction_chip: PanelContainer = null
var _hp_chip: PanelContainer = null
var _sum_chip: PanelContainer = null
var _waves_label: Label = null


func setup(p_editor: Control, p_data: RefCounted) -> void:
	editor = p_editor
	data = p_data
	if get_child_count() > 0:
		return
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var head := ThemeKit.section_head(T("editor.encounters.title"), T("editor.encounters.eyebrow"), ThemeKit.RED)
	_faction_chip = ThemeKit.chip("", ThemeKit.RED)
	head.add_child(_faction_chip)
	_hp_chip = ThemeKit.chip("", ThemeKit.GOLD)
	head.add_child(_hp_chip)
	_sum_chip = ThemeKit.chip("", ThemeKit.CYAN)
	head.add_child(_sum_chip)
	root.add_child(head)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	body.add_child(_build_list())
	body.add_child(_build_center())
	body.add_child(_build_side())
	refresh()


func refresh() -> void:
	if _current.is_empty() or (data.call("encounter_by_id", _current) as Dictionary).is_empty():
		var all: Array = data.call("encounter_list")
		_current = String((all[0] as Dictionary).get("id", "")) if not all.is_empty() else ""
	_rebuild_list()
	_refresh_all()


func T(key: String, params: Dictionary = {}) -> String:
	return String(editor.call("T", key, params)) if editor != null else key


func _enc() -> Dictionary:
	return data.call("encounter_by_id", _current)


# ===========================================================================
# 左：遭遇卡列表
# ===========================================================================
func _build_list() -> Control:
	var panel := ThemeKit.card(ThemeKit.RED, 12.0, 14)
	panel.custom_minimum_size = Vector2(286.0, 0.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(ThemeKit.label(T("editor.encounters.list"), &"EditorH3"))
	head.add_child(ThemeKit.spacer())
	_list_count = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	head.add_child(_list_count)
	v.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_list_box)
	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 6)
	var add := ThemeKit.small_button(T("editor.encounters.add"), ThemeKit.RED)
	add.name = "encounter_add"
	add.pressed.connect(_on_add)
	ops.add_child(add)
	var dup := ThemeKit.small_button(T("editor.common.duplicate"), ThemeKit.CYAN)
	dup.name = "encounter_duplicate"
	dup.pressed.connect(_on_duplicate)
	ops.add_child(dup)
	var del := ThemeKit.small_button(T("editor.common.delete"), ThemeKit.RED)
	del.name = "encounter_delete"
	del.pressed.connect(_on_delete)
	ops.add_child(del)
	v.add_child(ops)
	return panel


func _rebuild_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var all: Array = data.call("encounter_list")
	_list_count.text = T("editor.layouts.list_count", {"n": all.size()})
	for e in all:
		var d: Dictionary = e
		var id := String(d.get("id", ""))
		var fac := String(d.get("faction", ""))
		var col := ThemeKit.faction_color(fac)
		var b := Button.new()
		b.name = "encounter_row_" + id
		b.toggle_mode = true
		b.button_pressed = id == _current
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0.0, 56.0)
		b.add_theme_stylebox_override("normal", ThemeKit.box(ThemeKit.INPUT, ThemeKit.STROKE, 9, 1, 10.0, 7.0))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ThemeKit.CARD_HI, ThemeKit.STROKE_HI, 9, 1, 10.0, 7.0))
		b.add_theme_stylebox_override("pressed", ThemeKit.box(Color(col.r, col.g, col.b, 0.16), col, 9, 1, 10.0, 7.0))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(_on_pick.bind(id))
		var v := VBoxContainer.new()
		v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		v.add_theme_constant_override("separation", 1)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.offset_left = 10.0
		v.offset_right = -10.0
		v.offset_top = 7.0
		v.offset_bottom = -7.0
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		v.add_child(ThemeKit.label(String(d.get("display_name", id)), &"EditorH3"))
		v.add_child(ThemeKit.caption(T("editor.encounters.card_sub", {
			"f": String(d.get("faction_display", fac)),
			"hp": "%.0f" % float(d.get("base_hp", 0.0)),
			"n": (d.get("platform_buildings", []) as Array).size(),
		}), ThemeKit.TEXT_DIM))
		b.add_child(v)
		_list_box.add_child(b)


# ===========================================================================
# 中：底壳俯视图 + 阵营 / 血量
# ===========================================================================
func _build_center() -> Control:
	var panel := ThemeKit.card(ThemeKit.GOLD, 12.0, 14)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.encounters.map"), &"EditorH3"))
	head.add_child(ThemeKit.spacer())
	head.add_child(ThemeKit.caption(T("editor.encounters.select_hint"), ThemeKit.TEXT_DIM))
	v.add_child(head)

	_canvas = LayoutCanvas.new()
	_canvas.name = "encounter_canvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.call("setup", editor, data)
	_canvas.connect("platform_clicked", Callable(self, "_on_canvas_clicked"))
	v.add_child(_canvas)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(ThemeKit.field_label(T("editor.encounters.faction")))
	_faction_opt = OptionButton.new()
	_faction_opt.name = "encounter_faction"
	_faction_opt.custom_minimum_size = Vector2(132.0, 32.0)
	for f in data.call("encounter_factions"):
		var fd: Dictionary = f
		_faction_opt.add_item(String(fd.get("display_name", fd.get("id", ""))))
		_faction_opt.set_item_metadata(_faction_opt.item_count - 1, String(fd.get("id", "")))
	_faction_opt.item_selected.connect(_on_faction)
	row.add_child(_faction_opt)
	row.add_child(ThemeKit.field_label(T("editor.encounters.base_hp")))
	_hp_edit = ThemeKit.num_field("", 110.0)
	_hp_edit.name = "encounter_base_hp"
	_hp_edit.text_submitted.connect(_on_hp)
	_hp_edit.focus_exited.connect(_commit_hp.bind(_hp_edit))
	row.add_child(_hp_edit)
	row.add_child(ThemeKit.spacer())
	var add := ThemeKit.small_button(T("editor.encounters.add_platform"), ThemeKit.RED)
	add.name = "encounter_attach"
	add.pressed.connect(_on_attach)
	row.add_child(add)
	var detach := ThemeKit.small_button(T("editor.encounters.remove_platform"), ThemeKit.TEXT_DIM)
	detach.name = "encounter_detach"
	detach.pressed.connect(_on_detach)
	row.add_child(detach)
	v.add_child(row)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_row.add_child(ThemeKit.field_label(T("editor.layouts.name")))
	_name_edit = ThemeKit.text_field("")
	_name_edit.name = "encounter_name"
	_name_edit.text_changed.connect(_on_name_changed)
	name_row.add_child(_name_edit)
	v.add_child(name_row)
	return panel


# ===========================================================================
# 右：固定建筑 + 攻防意图池
# ===========================================================================
func _build_side() -> Control:
	var panel := ThemeKit.card(ThemeKit.PURPLE, 12.0, 14)
	panel.custom_minimum_size = Vector2(430.0, 0.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	v.add_child(ThemeKit.label(T("editor.encounters.buildings"), &"EditorH3"))
	var sub := ThemeKit.caption(T("editor.encounters.buildings_hint"), ThemeKit.TEXT_DIM)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)
	_build_rows = VBoxContainer.new()
	_build_rows.add_theme_constant_override("separation", 4)
	v.add_child(_build_rows)
	v.add_child(ThemeKit.hairline())
	var ih := HBoxContainer.new()
	ih.add_theme_constant_override("separation", 6)
	ih.add_child(ThemeKit.label(T("editor.encounters.intents"), &"EditorH3"))
	ih.add_child(ThemeKit.spacer())
	var add_intent := ThemeKit.small_button(T("editor.encounters.add_intent"), ThemeKit.CYAN)
	add_intent.name = "encounter_add_intent"
	add_intent.pressed.connect(_on_add_intent)
	ih.add_child(add_intent)
	v.add_child(ih)
	var isub := ThemeKit.caption(T("editor.encounters.intents_hint"), ThemeKit.TEXT_DIM)
	isub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(isub)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0.0, 150.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_intent_rows = VBoxContainer.new()
	_intent_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_intent_rows.add_theme_constant_override("separation", 3)
	scroll.add_child(_intent_rows)
	_waves_label = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	_waves_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_waves_label.name = "encounter_waves"
	v.add_child(_waves_label)
	return panel


func _refresh_all() -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	var fac := String(enc.get("faction", ""))
	ThemeKit.set_chip(_faction_chip, String(enc.get("faction_display", fac)), ThemeKit.faction_color(fac))
	ThemeKit.set_chip(_hp_chip, T("editor.encounters.hp_value", {"v": "%.0f" % float(enc.get("base_hp", 0.0))}), ThemeKit.GOLD)
	var sums: Vector2 = data.call("intent_sums", enc)
	ThemeKit.set_chip(_sum_chip, T("editor.encounters.sum_value", {"a": "%.0f" % sums.x, "d": "%.0f" % sums.y}), ThemeKit.CYAN)
	_name_edit.text = String(enc.get("display_name", ""))
	_hp_edit.text = "%.0f" % float(enc.get("base_hp", 0.0))
	var bi := 0
	for i in _faction_opt.item_count:
		if String(_faction_opt.get_item_metadata(i)) == fac:
			bi = i
	_faction_opt.select(bi)
	if _canvas != null:
		_canvas.call("set_context", String(enc.get("shell", "")), "encounter", "", String(enc.get("id", "")))
		_canvas.call("select_platform", _selected_platform)
		_canvas.call("refresh")
	_rebuild_buildings(enc)
	_rebuild_intents(enc)
	_rebuild_list()


func _rebuild_buildings(enc: Dictionary) -> void:
	for c in _build_rows.get_children():
		c.queue_free()
	var rows: Array = enc.get("platform_buildings", [])
	for row in rows:
		var d: Dictionary = row
		var idx := int(d.get("platform", 0))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		var chip := ThemeKit.chip("E%d" % idx, ThemeKit.RED)
		h.add_child(chip)
		var opt := OptionButton.new()
		opt.name = "encounter_building_%d" % idx
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.custom_minimum_size = Vector2(0.0, 30.0)
		var pick := 0
		var bi := 0
		for bd in data.call("buildings"):
			var bid := String((bd as Dictionary).get("id", ""))
			opt.add_item(String((bd as Dictionary).get("display_name", bid)))
			opt.set_item_metadata(bi, bid)
			if bid == String(d.get("building", "")):
				pick = bi
			bi += 1
		opt.select(pick)
		opt.item_selected.connect(_on_building.bind(idx, opt))
		h.add_child(opt)
		var star := ThemeKit.num_field("%.0f" % float(d.get("star", 1.0)), 42.0)
		star.name = "encounter_star_%d" % idx
		star.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		star.text_submitted.connect(_on_star.bind(idx, star))
		star.focus_exited.connect(_commit_star.bind(idx, star))
		h.add_child(star)
		var del := ThemeKit.small_button("x", ThemeKit.RED)
		del.custom_minimum_size = Vector2(30.0, 30.0)
		del.pressed.connect(_on_remove_row.bind(idx))
		h.add_child(del)
		_build_rows.add_child(h)
	if rows.is_empty():
		_build_rows.add_child(ThemeKit.caption(T("editor.encounters.no_building"), ThemeKit.TEXT_DIM))


func _rebuild_intents(enc: Dictionary) -> void:
	for c in _intent_rows.get_children():
		c.queue_free()
	var pool: Array = enc.get("intent_pool", [])
	for i in pool.size():
		var it: Dictionary = pool[i]
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 5)
		var name := ThemeKit.label(String(it.get("display_name", "")), &"EditorBody")
		name.custom_minimum_size = Vector2(112.0, 0.0)
		name.tooltip_text = String(it.get("note", ""))
		h.add_child(name)
		var attack := ThemeKit.num_field("%.0f" % float(it.get("weight_attack", 0.0)), 44.0)
		attack.name = "encounter_intent_attack_%d" % i
		attack.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		attack.text_submitted.connect(_on_weight.bind(i, "weight_attack", attack))
		attack.focus_exited.connect(_commit_weight.bind(i, "weight_attack", attack))
		h.add_child(attack)
		var defend := ThemeKit.num_field("%.0f" % float(it.get("weight_defend", 0.0)), 44.0)
		defend.name = "encounter_intent_defend_%d" % i
		defend.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		defend.text_submitted.connect(_on_weight.bind(i, "weight_defend", defend))
		defend.focus_exited.connect(_commit_weight.bind(i, "weight_defend", defend))
		h.add_child(defend)
		var del := ThemeKit.small_button("x", ThemeKit.TEXT_DIM)
		del.custom_minimum_size = Vector2(28.0, 30.0)
		del.pressed.connect(_on_remove_intent.bind(i))
		h.add_child(del)
		_intent_rows.add_child(h)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	head.add_child(ThemeKit.spacer())
	var ah := ThemeKit.caption(T("editor.encounters.attack"), ThemeKit.RED)
	ah.custom_minimum_size = Vector2(44.0, 0.0)
	ah.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(ah)
	var dh := ThemeKit.caption(T("editor.encounters.defend"), ThemeKit.ACCENT)
	dh.custom_minimum_size = Vector2(44.0, 0.0)
	dh.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(dh)
	_intent_rows.add_child(head)
	var roles: Dictionary = enc.get("unit_roles", {})
	var parts: Array[String] = []
	for role in ["light", "line", "elite"]:
		var uid := String(roles.get(role, ""))
		parts.append("%s=%s" % [T("editor.encounters.role_" + role), String(data.call("unit_by_id", uid).get("display_name", uid))])
	_waves_label.text = T("editor.encounters.waves") + ": " + ", ".join(parts)


# ===========================================================================
# 事件
# ===========================================================================
func _on_pick(id: String) -> void:
	_current = id
	_selected_platform = -1
	_refresh_all()


func _on_canvas_clicked(index: int) -> void:
	_selected_platform = index
	if _canvas != null:
		_canvas.call("select_platform", index)


func _on_attach() -> void:
	var enc := _enc()
	if enc.is_empty() or _selected_platform < 0:
		return
	var shell: Dictionary = data.call("shell_by_id", String(enc.get("shell", "")))
	var p := ShellStore.platform_by_index(shell, _selected_platform)
	if p.is_empty() or String(p.get("side", "")) != "enemy":
		return
	data.call("add_encounter_building", enc, _selected_platform, "watchtower")
	editor.call("mark_dirty")
	_refresh_all()


func _on_detach() -> void:
	var enc := _enc()
	if enc.is_empty() or _selected_platform < 0:
		return
	data.call("remove_encounter_building", enc, _selected_platform)
	editor.call("mark_dirty")
	_refresh_all()


func _on_remove_row(index: int) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	data.call("remove_encounter_building", enc, index)
	editor.call("mark_dirty")
	_refresh_all()


func _on_building(item: int, index: int, opt: OptionButton) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	data.call("add_encounter_building", enc, index, String(opt.get_item_metadata(item)))
	editor.call("mark_dirty")
	_refresh_all()


func _on_star(text: String, index: int, le: LineEdit) -> void:
	_commit_star(index, le)


func _commit_star(index: int, le: LineEdit) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	var v := clampf(round(float(le.text) if le.text.is_valid_float() else 1.0), 1.0, 3.0)
	for row in (enc.get("platform_buildings", []) as Array):
		if int((row as Dictionary).get("platform", -1)) == index:
			(row as Dictionary)["star"] = v
	le.text = "%.0f" % v
	editor.call("mark_dirty")


func _on_faction(item: int) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	var fid := String(_faction_opt.get_item_metadata(item))
	if bool(data.call("set_encounter_faction", String(enc.get("id", "")), fid)):
		editor.call("mark_dirty")
		_refresh_all()


func _on_hp(_text: String) -> void:
	_commit_hp(_hp_edit)


func _commit_hp(le: LineEdit) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	var v := clampf(round(float(le.text) if le.text.is_valid_float() else float(enc.get("base_hp", 3000.0))), 100.0, 99999.0)
	enc["base_hp"] = v
	le.text = "%.0f" % v
	editor.call("mark_dirty")
	_refresh_all()


func _on_name_changed(text: String) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	enc["display_name"] = text
	editor.call("mark_dirty")


func _on_weight(text: String, index: int, key: String, le: LineEdit) -> void:
	_commit_weight(index, key, le)


func _commit_weight(index: int, key: String, le: LineEdit) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	var pool: Array = enc.get("intent_pool", [])
	if index < 0 or index >= pool.size():
		return
	var v := clampf(float(le.text) if le.text.is_valid_float() else 0.0, 0.0, 100.0)
	(pool[index] as Dictionary)[key] = v
	le.text = "%.0f" % v
	editor.call("mark_dirty")
	_refresh_all()


func _on_add_intent() -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	var pool: Array = enc.get("intent_pool", [])
	pool.append({
		"id": "custom_%d" % (pool.size() + 1),
		"display_name": T("editor.encounters.intent_custom"),
		"weight_attack": 10.0,
		"weight_defend": 10.0,
		"note": "",
	})
	editor.call("mark_dirty")
	_refresh_all()


func _on_remove_intent(index: int) -> void:
	var enc := _enc()
	if enc.is_empty():
		return
	var pool: Array = enc.get("intent_pool", [])
	if index >= 0 and index < pool.size():
		pool.remove_at(index)
	editor.call("mark_dirty")
	_refresh_all()


func _on_add() -> void:
	var e: Dictionary = data.call("new_encounter")
	_current = String(e.get("id", ""))
	editor.call("mark_dirty")
	_refresh_all()


func _on_duplicate() -> void:
	if _current.is_empty():
		return
	var e: Dictionary = data.call("duplicate_encounter", _current)
	if not e.is_empty():
		_current = String(e.get("id", ""))
		editor.call("mark_dirty")
		_refresh_all()


func _on_delete() -> void:
	if _current.is_empty():
		return
	data.call("remove_encounter", _current)
	_current = ""
	editor.call("mark_dirty")
	refresh()
