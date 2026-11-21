extends Control
## 03 · 长横道关卡 / 类自走棋营地
## 属于：Screens/editor（开发工具，不进发行版）
##
## 上：三段横道（长度/宽度 × R1 实时换米）、平势/劣势/优势模板、敌方意图池权重；
## 下：RTS 错落营地 + 独立石台摆放器（拖动建筑换槽位、预摆开局、敌方固定建筑）。
## 明确没有：自由障碍涂抹、五子棋连线格。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const CampCanvas := preload("res://Screens/editor/camp_canvas.gd")

var editor: Control = null
var data: RefCounted = null

var _seg_lengths: Array = []
var _seg_widths: Array = []
var _seg_meters: Array = []
var _seg_bars: Array = []
var _template_total: Label = null
var _template_buttons: Dictionary = {}
var _template_note: Label = null
var _intent_rows: Array = []
var _intent_total: PanelContainer = null
var _camp: Control = null
var _gap_chip: PanelContainer = null
var _enemy_toggle: Button = null


func setup(p_editor: Control, p_data: RefCounted) -> void:
	editor = p_editor
	data = p_data
	if get_child_count() > 0:
		return
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	top.custom_minimum_size = Vector2(0.0, 252.0)
	for i in 3:
		top.add_child(_build_segment_card(i))
	top.add_child(_build_template_card())
	top.add_child(_build_intent_card())
	root.add_child(top)

	root.add_child(_build_camp_card())
	_refresh_segments()
	_refresh_intents()
	_refresh_template_buttons()
	_refresh_camp_header()


func refresh() -> void:
	_refresh_segments()
	_refresh_intents()
	_refresh_template_buttons()
	_refresh_camp_header()
	if _camp != null:
		_camp.call("refresh")


func T(key: String, params: Dictionary = {}) -> String:
	return editor.call("T", key, params) if editor != null else key


# ===========================================================================
# 三段横道
# ===========================================================================
func _segment_role_color(role: String) -> Color:
	match role:
		"player":
			return ThemeKit.ACCENT
		"enemy":
			return ThemeKit.RED
	return ThemeKit.CYAN


func _build_segment_card(index: int) -> Control:
	var segs: Array = data.call("segments")
	var s: Dictionary = segs[index] if index < segs.size() else {}
	var role := String(s.get("role", "neutral"))
	var col := _segment_role_color(role)
	var panel := ThemeKit.card(col, 14.0, 14)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var roman := ThemeKit.label(["I", "II", "III"][index], &"EditorH1", col)
	head.add_child(roman)
	var title := ThemeKit.label(T(String(s.get("name_key", ""))), &"EditorH3")
	head.add_child(title)
	head.add_child(ThemeKit.spacer())
	var r1tag := ThemeKit.caption("R1", Color(col.r, col.g, col.b, 0.9))
	r1tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(r1tag)
	v.add_child(head)

	var fields := HBoxContainer.new()
	fields.add_theme_constant_override("separation", 8)
	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv.add_theme_constant_override("separation", 2)
	lv.add_child(ThemeKit.field_label(T("editor.level.length")))
	var lf := ThemeKit.num_field("", 0.0)
	lv.add_child(lf)
	fields.add_child(lv)
	_seg_lengths.append(lf)
	var wv := VBoxContainer.new()
	wv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wv.add_theme_constant_override("separation", 2)
	wv.add_child(ThemeKit.field_label(T("editor.level.width")))
	var wf := ThemeKit.num_field("", 0.0)
	wv.add_child(wf)
	fields.add_child(wv)
	_seg_widths.append(wf)
	v.add_child(fields)

	var meters := ThemeKit.caption("", ThemeKit.TEXT_SUB)
	v.add_child(meters)
	_seg_meters.append(meters)

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0.0, 8.0)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.max_value = 4000.0
	bar.add_theme_stylebox_override("background", ThemeKit.box(Color("#111722"), ThemeKit.STROKE, 4, 0, 0.0, 0.0))
	bar.add_theme_stylebox_override("fill", ThemeKit.box(col, Color(0, 0, 0, 0), 4, 0, 0.0, 0.0))
	v.add_child(bar)
	_seg_bars.append(bar)

	lf.text_submitted.connect(_on_seg_submitted.bind(index, "length", lf))
	lf.focus_exited.connect(_on_seg_focus_lost.bind(index, "length", lf))
	wf.text_submitted.connect(_on_seg_submitted.bind(index, "width", wf))
	wf.focus_exited.connect(_on_seg_focus_lost.bind(index, "width", wf))
	return panel


func _on_seg_submitted(text: String, index: int, key: String, le: LineEdit) -> void:
	_commit_seg(text, index, key, le)


func _on_seg_focus_lost(index: int, key: String, le: LineEdit) -> void:
	_commit_seg(le.text, index, key, le)


func _commit_seg(raw: String, index: int, key: String, le: LineEdit) -> void:
	var segs: Array = data.call("segments")
	if index < 0 or index >= segs.size():
		return
	var s: Dictionary = segs[index]
	var t := raw.strip_edges()
	var v := float(t) if t.is_valid_float() else float(s.get(key, 0.0))
	var maxv := 999.0 if key == "width" else 9999.0
	v = clampf(round(v), 100.0, maxv)
	s[key] = v
	if key == "length":
		data.call("sync_lane_total")
	le.text = "%.0f" % v
	editor.call("mark_dirty")
	_refresh_segments()


func _refresh_segments() -> void:
	var segs: Array = data.call("segments")
	var total := 0.0
	for s in segs:
		total += float(s.get("length", 0.0))
	for i in segs.size():
		if i >= _seg_lengths.size():
			break
		var s: Dictionary = segs[i]
		var length := float(s.get("length", 0.0))
		var width := float(s.get("width", 0.0))
		(_seg_lengths[i] as LineEdit).text = "%.0f" % length
		(_seg_widths[i] as LineEdit).text = "%.0f" % width
		(_seg_meters[i] as Label).text = T("editor.level.length") + " " + T("editor.units.range_formula", {
			"raw": "%.0f" % length,
			"m": "%.2f" % float(data.call("meters", length)),
		}) + "\n" + T("editor.level.width") + " " + T("editor.units.range_formula", {
			"raw": "%.0f" % width,
			"m": "%.2f" % float(data.call("meters", width)),
		})
		(_seg_bars[i] as ProgressBar).max_value = maxf(total, 1.0)
		(_seg_bars[i] as ProgressBar).value = length
	if _template_total != null:
		_template_total.text = T("editor.level.total", {
			"v": "%.0f" % total,
			"m": "%.2f" % float(data.call("meters", total)),
		})


func _build_template_card() -> Control:
	var panel := ThemeKit.card(ThemeKit.GOLD, 14.0, 14)
	panel.custom_minimum_size = Vector2(286.0, 0.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)
	v.add_child(ThemeKit.section_head(T("editor.level.template"), T("editor.level.template_hint"), ThemeKit.GOLD))

	var tpl_names: Array = (data.call("lane_templates") as Dictionary).keys()
	var label_keys := ["editor.level.template_even", "editor.level.template_bad", "editor.level.template_good"]
	var colors := [ThemeKit.CYAN, ThemeKit.RED, ThemeKit.GREEN]
	for i in mini(tpl_names.size(), 3):
		var tname := String(tpl_names[i])
		var col: Color = colors[i]
		var b := ThemeKit.toggle(T(String(label_keys[i])), false, col, 0.0)
		b.custom_minimum_size = Vector2(0.0, 38.0)
		b.pressed.connect(_on_template_pressed.bind(tname))
		v.add_child(b)
		_template_buttons[tname] = b
	_template_total = ThemeKit.caption("", ThemeKit.TEXT_SUB)
	v.add_child(_template_total)
	_template_note = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	_template_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_template_note)
	return panel


func _refresh_template_buttons() -> void:
	var cur := String(data.call("lane_template"))
	for name in _template_buttons.keys():
		(_template_buttons[name] as Button).button_pressed = name == cur
	var templates: Dictionary = data.call("lane_templates")
	if templates.has(cur) and _template_note != null:
		_template_note.text = String((templates[cur] as Dictionary).get("note", ""))


func _on_template_pressed(name: String) -> void:
	if String(data.call("lane_template")) == name:
		_refresh_template_buttons()
		return
	if bool(data.call("set_lane_template", name)):
		editor.call("mark_dirty")
		_refresh_segments()
		_refresh_template_buttons()
		_refresh_intents()


# ===========================================================================
# 意图池
# ===========================================================================
func _build_intent_card() -> Control:
	var panel := ThemeKit.card(ThemeKit.RED, 14.0, 14)
	panel.custom_minimum_size = Vector2(548.0, 0.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var head := ThemeKit.section_head(T("editor.level.intent"), T("editor.level.intent_hint"), ThemeKit.RED)
	_intent_total = ThemeKit.chip("", ThemeKit.RED)
	head.add_child(_intent_total)
	v.add_child(head)

	var items: Array = data.call("intents")
	for i in items.size():
		var it: Dictionary = items[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		var name := ThemeKit.label(String(it.get("display_name", "")), &"EditorBody")
		name.custom_minimum_size = Vector2(96.0, 0.0)
		name.tooltip_text = String(it.get("note", ""))
		row.add_child(name)
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0.0, 8.0)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.max_value = 100.0
		bar.add_theme_stylebox_override("background", ThemeKit.box(Color("#111722"), ThemeKit.STROKE, 4, 0, 0.0, 0.0))
		bar.add_theme_stylebox_override("fill", ThemeKit.box(ThemeKit.RED, Color(0, 0, 0, 0), 4, 0, 0.0, 0.0))
		row.add_child(bar)
		var le := ThemeKit.num_field("", 56.0)
		le.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		row.add_child(le)
		var share := ThemeKit.caption("0%", ThemeKit.TEXT_SUB)
		share.custom_minimum_size = Vector2(44.0, 0.0)
		share.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(share)
		v.add_child(row)
		le.text_submitted.connect(_on_intent_submitted.bind(i, le))
		le.focus_exited.connect(_on_intent_focus_lost.bind(i, le))
		_intent_rows.append({"bar": bar, "field": le, "share": share})
	var hint := ThemeKit.caption(T("editor.level.intent_note"), ThemeKit.TEXT_DIM)
	v.add_child(hint)
	return panel


func _on_intent_submitted(text: String, index: int, le: LineEdit) -> void:
	_commit_intent(text, index, le)


func _on_intent_focus_lost(index: int, le: LineEdit) -> void:
	_commit_intent(le.text, index, le)


func _commit_intent(raw: String, index: int, le: LineEdit) -> void:
	var items: Array = data.call("intents")
	if index < 0 or index >= items.size():
		return
	var it: Dictionary = items[index]
	var t := raw.strip_edges()
	var v := float(t) if t.is_valid_float() else float(it.get("weight", 0.0))
	it["weight"] = clampf(v, 0.0, 100.0)
	data.call("store_intent_weights")
	editor.call("mark_dirty")
	_refresh_intents()


func _refresh_intents() -> void:
	var items: Array = data.call("intents")
	var total := 0.0
	for it in items:
		total += maxf(float(it.get("weight", 0.0)), 0.0)
	for i in items.size():
		if i >= _intent_rows.size():
			break
		var row: Dictionary = _intent_rows[i]
		var w := maxf(float((items[i] as Dictionary).get("weight", 0.0)), 0.0)
		var share := (w / total * 100.0) if total > 0.0 else 0.0
		(row["bar"] as ProgressBar).value = w
		(row["field"] as LineEdit).text = "%.0f" % w
		(row["share"] as Label).text = "%.0f%%" % share
	if _intent_total != null:
		ThemeKit.set_chip(_intent_total, T("editor.level.intent_total", {"v": "%.0f" % total}), ThemeKit.RED)


# ===========================================================================
# 营地
# ===========================================================================
func _build_camp_card() -> Control:
	var panel := ThemeKit.card(ThemeKit.GREEN, 16.0, 14)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.level.camp"), &"EditorH2"))
	head.add_child(ThemeKit.chip(T("editor.level.old_removed"), ThemeKit.TEXT_DIM))
	head.add_child(ThemeKit.spacer())
	_gap_chip = ThemeKit.chip("", ThemeKit.CYAN)
	head.add_child(_gap_chip)
	_enemy_toggle = ThemeKit.toggle(T("editor.level.enemy_toggle"), true, ThemeKit.RED, 180.0)
	_enemy_toggle.toggled.connect(_on_enemy_toggled)
	head.add_child(_enemy_toggle)
	var pre := ThemeKit.small_button(T("editor.level.preplace"), ThemeKit.GREEN)
	pre.pressed.connect(_on_preplace)
	head.add_child(pre)
	v.add_child(head)

	_camp = CampCanvas.new()
	_camp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_camp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_camp.custom_minimum_size = Vector2(0.0, 420.0)
	_camp.call("setup", editor, data)
	_camp.call("connect_changed", Callable(self, "_on_camp_changed"))
	v.add_child(_camp)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 14)
	foot.add_child(ThemeKit.dot(ThemeKit.ACCENT, 6.0))
	foot.add_child(ThemeKit.caption(T("editor.level.player"), ThemeKit.TEXT_SUB))
	foot.add_child(ThemeKit.dot(ThemeKit.RED, 6.0))
	foot.add_child(ThemeKit.caption(T("editor.level.enemy"), ThemeKit.TEXT_SUB))
	foot.add_child(ThemeKit.dot(ThemeKit.GREEN, 6.0))
	foot.add_child(ThemeKit.caption(T("editor.level.stone"), ThemeKit.TEXT_SUB))
	foot.add_child(ThemeKit.spacer())
	foot.add_child(ThemeKit.caption(T("editor.level.move_hint"), ThemeKit.TEXT_DIM))
	var add_enemy := ThemeKit.small_button(T("editor.level.enemy_add"), ThemeKit.RED)
	add_enemy.pressed.connect(_on_add_enemy)
	foot.add_child(add_enemy)
	var del_enemy := ThemeKit.small_button(T("editor.level.enemy_remove"), ThemeKit.RED)
	del_enemy.pressed.connect(_on_remove_enemy)
	foot.add_child(del_enemy)
	v.add_child(foot)
	return panel


func _refresh_camp_header() -> void:
	if _gap_chip != null:
		ThemeKit.set_chip(_gap_chip, T("editor.level.gap") + " · " + T("editor.level.gap_value", {
			"v": "%.2f" % float(data.call("min_gap_meters"))
		}), ThemeKit.CYAN)
	if _camp != null:
		_camp.call("queue_redraw")


func _on_enemy_toggled(on: bool) -> void:
	if _camp != null:
		_camp.call("set_show_enemy", on)


func _on_add_enemy() -> void:
	if _camp != null:
		_camp.call("add_enemy")


func _on_remove_enemy() -> void:
	if _camp != null:
		_camp.call("remove_selected_enemy")


func _on_preplace() -> void:
	data.call("preset_start")
	editor.call("mark_dirty")
	if _camp != null:
		_camp.call("refresh")
	_refresh_camp_header()


func _on_camp_changed() -> void:
	editor.call("mark_dirty")
	_refresh_camp_header()
