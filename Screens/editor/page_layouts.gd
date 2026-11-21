@tool
extends Control
## 03 · 玩家态势布局卡（player_layouts.json）
## 属于：Screens/editor（开发工具，不进发行版）
##
## 口径：选平势/劣势/优势 + 可视化勾选激活底壳上的哪几座石台 + 给激活槽位指定开局预设建筑。
## 未激活石台在局内渲染为不可建造的碎石遗迹（inactive_render = ruin）。
## 默认预设：1 主堡 + 2 农场 + 1 兵营。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const LayoutCanvas := preload("res://Screens/editor/layout_canvas.gd")
const ShellStore := preload("res://Screens/editor/shell_store.gd")

var editor: Control = null
var data: RefCounted = null

var _current := ""
var _list_box: VBoxContainer = null
var _list_count: Label = null
var _canvas: Control = null
var _kind_buttons: Dictionary = {}
var _slot_rows: VBoxContainer = null
var _gap_chip: PanelContainer = null
var _preset_chip: PanelContainer = null
var _count_chip: PanelContainer = null
var _shell_chip: PanelContainer = null
var _note_edit: LineEdit = null
var _name_edit: LineEdit = null


func setup(p_editor: Control, p_data: RefCounted) -> void:
	editor = p_editor
	data = p_data
	if get_child_count() > 0:
		return
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var head := ThemeKit.section_head(T("editor.layouts.title"), T("editor.layouts.eyebrow"), ThemeKit.ACCENT)
	_count_chip = ThemeKit.chip("", ThemeKit.ACCENT)
	head.add_child(_count_chip)
	_gap_chip = ThemeKit.chip("", ThemeKit.CYAN)
	head.add_child(_gap_chip)
	root.add_child(head)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	body.add_child(_build_list())
	body.add_child(_build_center())
	body.add_child(_build_slots())
	refresh()


func refresh() -> void:
	if _current.is_empty() or (data.call("layout_by_id", _current) as Dictionary).is_empty():
		var all: Array = data.call("layout_list")
		_current = String((all[0] as Dictionary).get("id", "")) if not all.is_empty() else ""
	_rebuild_list()
	_refresh_all()


func T(key: String, params: Dictionary = {}) -> String:
	return String(editor.call("T", key, params)) if editor != null else key


func _layout() -> Dictionary:
	return data.call("layout_by_id", _current)


# ===========================================================================
# 左：布局卡列表
# ===========================================================================
func _build_list() -> Control:
	var panel := ThemeKit.card(ThemeKit.ACCENT, 12.0, 14)
	panel.custom_minimum_size = Vector2(286.0, 0.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(ThemeKit.label(T("editor.layouts.list"), &"EditorH3"))
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
	var add := ThemeKit.small_button(T("editor.layouts.add"), ThemeKit.ACCENT)
	add.name = "layout_add"
	add.pressed.connect(_on_add)
	ops.add_child(add)
	var dup := ThemeKit.small_button(T("editor.layouts.duplicate"), ThemeKit.CYAN)
	dup.name = "layout_duplicate"
	dup.pressed.connect(_on_duplicate)
	ops.add_child(dup)
	var del := ThemeKit.small_button(T("editor.layouts.delete"), ThemeKit.RED)
	del.name = "layout_delete"
	del.pressed.connect(_on_delete)
	ops.add_child(del)
	v.add_child(ops)
	return panel


func _rebuild_list() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var all: Array = data.call("layout_list")
	_list_count.text = T("editor.layouts.list_count", {"n": all.size()})
	for l in all:
		var d: Dictionary = l
		var id := String(d.get("id", ""))
		var kind := String(d.get("kind", ""))
		var col := _kind_color(kind)
		var b := Button.new()
		b.name = "layout_row_" + id
		b.toggle_mode = true
		b.button_pressed = id == _current
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0.0, 56.0)
		b.add_theme_stylebox_override("normal", ThemeKit.box(ThemeKit.INPUT, ThemeKit.STROKE, 9, 1, 10.0, 7.0))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ThemeKit.CARD_HI, ThemeKit.STROKE_HI, 9, 1, 10.0, 7.0))
		b.add_theme_stylebox_override("pressed", ThemeKit.box(Color(col.r, col.g, col.b, 0.16), col, 9, 1, 10.0, 7.0))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(_on_pick.bind(id))
		var h := HBoxContainer.new()
		h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		h.add_theme_constant_override("separation", 8)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.offset_left = 10.0
		h.offset_right = -10.0
		h.offset_top = 7.0
		h.offset_bottom = -7.0
		b.add_child(h)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 1)
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(ThemeKit.label(String(d.get("display_name", id)), &"EditorH3"))
		var sub := T("editor.layouts.card_sub", {
			"kind": data.call("kind_display", kind),
			"n": (d.get("active_platforms", []) as Array).size(),
			"g": "%.1f" % float(data.call("min_gap_meters", String(d.get("shell", "")))),
		})
		v.add_child(ThemeKit.caption(sub, ThemeKit.TEXT_DIM))
		h.add_child(v)
		h.add_child(ThemeKit.spacer())
		h.add_child(ThemeKit.dot(col, 8.0))
		_list_box.add_child(b)


func _kind_color(kind: String) -> Color:
	match kind:
		"disadvantage":
			return ThemeKit.RED
		"advantage":
			return ThemeKit.GREEN
	return ThemeKit.CYAN


# ===========================================================================
# 中：底壳俯视图 + 态势
# ===========================================================================
func _build_center() -> Control:
	var panel := ThemeKit.card(ThemeKit.CYAN, 12.0, 14)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.layouts.map"), &"EditorH3"))
	_shell_chip = ThemeKit.chip("", ThemeKit.GOLD)
	head.add_child(_shell_chip)
	head.add_child(ThemeKit.spacer())
	_preset_chip = ThemeKit.chip("", ThemeKit.GREEN)
	head.add_child(_preset_chip)
	v.add_child(head)

	_canvas = LayoutCanvas.new()
	_canvas.name = "layout_canvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.call("setup", editor, data)
	_canvas.connect("platform_clicked", Callable(self, "_on_canvas_clicked"))
	v.add_child(_canvas)

	var kinds := HBoxContainer.new()
	kinds.add_theme_constant_override("separation", 8)
	kinds.add_child(ThemeKit.field_label(T("editor.layouts.kind")))
	for k in data.call("layout_kinds"):
		var kd: Dictionary = k
		var kid := String(kd.get("id", ""))
		var b := ThemeKit.toggle(String(kd.get("display_name", kid)), false, _kind_color(kid), 108.0)
		b.name = "layout_kind_" + kid
		b.pressed.connect(_on_kind.bind(kid))
		kinds.add_child(b)
		_kind_buttons[kid] = b
	kinds.add_child(ThemeKit.spacer())
	var preset := ThemeKit.small_button(T("editor.layouts.preset"), ThemeKit.GREEN)
	preset.name = "layout_preset"
	preset.pressed.connect(_on_preset)
	kinds.add_child(preset)
	v.add_child(kinds)

	var note_row := HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 8)
	note_row.add_child(ThemeKit.field_label(T("editor.common.note")))
	_note_edit = ThemeKit.text_field("", T("editor.layouts.note_hint"))
	_note_edit.name = "layout_note"
	_note_edit.text_changed.connect(_on_note_changed)
	note_row.add_child(_note_edit)
	v.add_child(note_row)
	return panel


# ===========================================================================
# 右：激活槽位
# ===========================================================================
func _build_slots() -> Control:
	var panel := ThemeKit.card(ThemeKit.GREEN, 12.0, 14)
	panel.custom_minimum_size = Vector2(392.0, 0.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(ThemeKit.label(T("editor.layouts.slots"), &"EditorH3"))
	head.add_child(ThemeKit.spacer())
	v.add_child(head)
	var sub := ThemeKit.caption(T("editor.layouts.slots_hint"), ThemeKit.TEXT_DIM)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_slot_rows = VBoxContainer.new()
	_slot_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot_rows.add_theme_constant_override("separation", 4)
	scroll.add_child(_slot_rows)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_row.add_child(ThemeKit.field_label(T("editor.layouts.name")))
	_name_edit = ThemeKit.text_field("")
	_name_edit.name = "layout_name"
	_name_edit.text_changed.connect(_on_name_changed)
	name_row.add_child(_name_edit)
	v.add_child(name_row)
	return panel


func _refresh_all() -> void:
	var layout := _layout()
	if layout.is_empty():
		return
	var shell_id := String(layout.get("shell", ""))
	var shell: Dictionary = data.call("shell_by_id", shell_id)
	ThemeKit.set_chip(_shell_chip, T("editor.layouts.shell_value", {"v": String(shell.get("display_name", shell_id))}), ThemeKit.GOLD)
	var counts: Dictionary = data.call("layout_counts", layout)
	ThemeKit.set_chip(_preset_chip, T("editor.layouts.preset_value", {
		"k": int(counts.get("base", 0)), "f": int(counts.get("farm", 0)), "b": int(counts.get("barracks", 0))
	}), ThemeKit.GREEN)
	ThemeKit.set_chip(_count_chip, T("editor.layouts.count_value", {"n": (layout.get("active_platforms", []) as Array).size()}), ThemeKit.ACCENT)
	ThemeKit.set_chip(_gap_chip, T("editor.layouts.gap_value", {"v": "%.2f" % float(data.call("min_gap_meters", shell_id))}), ThemeKit.CYAN)
	var kind := String(layout.get("kind", ""))
	for kid in _kind_buttons.keys():
		(_kind_buttons[kid] as Button).button_pressed = kid == kind
	_name_edit.text = String(layout.get("display_name", ""))
	_note_edit.text = String(layout.get("note", ""))
	if _canvas != null:
		_canvas.call("set_context", shell_id, "layout", String(layout.get("id", "")), "")
		_canvas.call("refresh")
	_rebuild_slots(shell, layout)
	_rebuild_list()


func _rebuild_slots(shell: Dictionary, layout: Dictionary) -> void:
	for c in _slot_rows.get_children():
		c.queue_free()
	for p in ShellStore.platforms(shell):
		var pd: Dictionary = p
		var idx := int(pd.get("index", 0))
		var side := String(pd.get("side", "player"))
		var role := String(pd.get("role", "build"))
		var active := ShellStore.is_active(layout, idx)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var col := ThemeKit.ACCENT if side == "player" else ThemeKit.RED
		var b := ThemeKit.toggle("%s%d" % ["P" if side == "player" else "E", idx], active, col, 54.0)
		b.name = "layout_toggle_%d" % idx
		b.tooltip_text = T("editor.layouts.ruin_hint")
		b.pressed.connect(_on_toggle.bind(idx))
		row.add_child(b)
		var tag := T("editor.layouts.keep") if role == "keep" else T("editor.layouts.build")
		var tag_label := ThemeKit.caption(tag, ThemeKit.GOLD if role == "keep" else ThemeKit.TEXT_DIM)
		tag_label.custom_minimum_size = Vector2(44.0, 0.0)
		row.add_child(tag_label)
		if active:
			var slot := ShellStore.slot_at(layout, idx)
			var opt := OptionButton.new()
			opt.name = "layout_slot_%d" % idx
			opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			opt.custom_minimum_size = Vector2(0.0, 30.0)
			var bi := 0
			var pick := 0
			for bd in data.call("buildings"):
				var bid := String((bd as Dictionary).get("id", ""))
				opt.add_item(String((bd as Dictionary).get("display_name", bid)))
				opt.set_item_metadata(bi, bid)
				if bid == String(slot.get("building", "")):
					pick = bi
				bi += 1
			opt.select(pick)
			opt.item_selected.connect(_on_building.bind(idx, opt))
			row.add_child(opt)
		else:
			var ruin := ThemeKit.caption(T("editor.layouts.ruin"), ThemeKit.TEXT_DIM)
			ruin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(ruin)
		_slot_rows.add_child(row)


# ===========================================================================
# 事件
# ===========================================================================
func _on_pick(id: String) -> void:
	_current = id
	_canvas.call("select_platform", -1)
	_refresh_all()


func _on_canvas_clicked(index: int) -> void:
	var layout := _layout()
	if layout.is_empty():
		return
	data.call("toggle_active_platform", String(layout.get("id", "")), index)
	editor.call("mark_dirty")
	_refresh_all()


func _on_toggle(index: int) -> void:
	_on_canvas_clicked(index)


func _on_building(item: int, index: int, opt: OptionButton) -> void:
	var layout := _layout()
	if layout.is_empty():
		return
	var bid := String(opt.get_item_metadata(item))
	data.call("set_slot_building", String(layout.get("id", "")), index, bid)
	editor.call("mark_dirty")
	_refresh_all()


func _on_kind(kind: String) -> void:
	var layout := _layout()
	if layout.is_empty():
		return
	if bool(data.call("set_layout_kind", String(layout.get("id", "")), kind)):
		editor.call("mark_dirty")
		_refresh_all()


func _on_preset() -> void:
	var layout := _layout()
	if layout.is_empty():
		return
	data.call("preset_layout", String(layout.get("id", "")))
	editor.call("mark_dirty")
	_refresh_all()


func _on_name_changed(text: String) -> void:
	var layout := _layout()
	if layout.is_empty():
		return
	layout["display_name"] = text
	editor.call("mark_dirty")


func _on_note_changed(text: String) -> void:
	var layout := _layout()
	if layout.is_empty():
		return
	layout["note"] = text
	editor.call("mark_dirty")


func _on_add() -> void:
	var l: Dictionary = data.call("new_layout")
	_current = String(l.get("id", ""))
	editor.call("mark_dirty")
	_refresh_all()


func _on_duplicate() -> void:
	if _current.is_empty():
		return
	var l: Dictionary = data.call("duplicate_layout", _current)
	if not l.is_empty():
		_current = String(l.get("id", ""))
		editor.call("mark_dirty")
		_refresh_all()


func _on_delete() -> void:
	if _current.is_empty():
		return
	data.call("remove_layout", _current)
	_current = ""
	editor.call("mark_dirty")
	refresh()
