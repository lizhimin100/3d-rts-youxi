@tool
extends Control
## 3D 地图底壳编辑器（MapShellEditor）
## 属于：Screens/editor/map_shell（开发工具，不进发行版）
##
## 三分离架构里的「地图底壳」：只保留 4 个纯视觉与空间划分工具
##   1 地形与地表笔刷（起伏雕刻 / 地表材质涂抹 / 环境光 / 水面高度）
##   2 3D 装饰品笔刷（通道两侧与营地周围的树/岩石/栅栏/旗帜，纯视觉，无战斗碰撞）
##   3 弯曲行军脊线 Path3D + 区域分割尺（4 个可拖动分割环 + 通道宽度，按 R1=0.015 换算写盘）
##   4 候选独立石台锚点摆放器（射线吸附地形 + 石柱底座防悬空，主堡/普通锚点分开标记）
##
## 砍掉的：地图上直接摆兵种、写触发器、涂 A* 寻路网格、配经济。
## 保存：直接写回 Content/data/map_shells.json（不写 user://，不写别的表）。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const ShellTheme := preload("res://Screens/editor/map_shell/shell_theme.gd")
const ShellText := preload("res://Screens/editor/map_shell/shell_text.gd")
const ShellStore := preload("res://Screens/editor/shell_store.gd")
const DataScript := preload("res://Screens/editor/dev_data.gd")
const ShellView := preload("res://Screens/editor/map_shell/shell_view.gd")

## 组合 key 的前缀（别在 T() 里直接拼字符串：体检会把它当成一个缺 key）。
const DECOR_KEY := "shell.decor."
const SIDE_KEY := "shell.platform.side_"
const ROLE_KEY := "shell.platform.role_"
const TOOL_KEY := "shell.tool."

var data: RefCounted = null
var view: Node3D = null
var shell_id := ""

var _shell_opt: OptionButton = null
var _layout_opt: OptionButton = null
var _sv: SubViewport = null
var _svc: SubViewportContainer = null
var _inspector: VBoxContainer = null
var _tool_buttons: Dictionary = {}
var _state_label: Label = null
var _counts: Label = null
var _gap_chip: PanelContainer = null
var _hover_label: Label = null
var _save_timer: Timer = null
var _dirty := false

var _radius_slider: HSlider = null
var _strength_slider: HSlider = null
var _water_slider: HSlider = null
var _ambient_slider: HSlider = null
var _fog_slider: HSlider = null
var _brush_buttons: Dictionary = {}
var _layer_buttons: Dictionary = {}
var _decor_buttons: Dictionary = {}
var _decor_info: Label = null
var _decor_scale: HSlider = null
var _width_edit: LineEdit = null
var _divider_edits: Dictionary = {}
var _points_label: Label = null
var _platform_list: VBoxContainer = null
var _platform_info: Label = null
var _role_buttons: Dictionary = {}
var _radius_pl: HSlider = null
var _base_pl: HSlider = null


func _ready() -> void:
	ShellText.load_table()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = ThemeKit.build_theme()
	data = DataScript.new()
	data.call("load_all")
	_build_ui()
	_bind_view()
	_select_first_shell()
	_show_tool("terrain")
	_refresh_status()
	_set_state(T("shell.state.saved"), ThemeKit.GREEN)


func T(key: String, params: Dictionary = {}) -> String:
	return ShellText.t(key, params)


# ===========================================================================
# 盘子
# ===========================================================================
func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	root.add_child(_build_topbar())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)
	body.add_child(_build_rail())
	body.add_child(_build_viewport())
	body.add_child(_build_inspector())
	root.add_child(_build_status())

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 1.2
	_save_timer.timeout.connect(_save)
	add_child(_save_timer)


func _build_topbar() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size = Vector2(0.0, 68.0)
	var sb := ThemeKit.box(ShellTheme.BG_DEEP, ShellTheme.STROKE, 0, 0, 18.0, 0.0)
	sb.border_width_bottom = 1
	bar.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	bar.add_child(h)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	v.add_child(ThemeKit.label(T("shell.title"), &"EditorH2", ShellTheme.LEGACY_GOLD_HI))
	v.add_child(ThemeKit.caption(T("shell.subtitle"), ShellTheme.TEXT_DIM))
	h.add_child(v)
	h.add_child(ThemeKit.spacer())

	_shell_opt = OptionButton.new()
	_shell_opt.name = "shell_picker"
	_shell_opt.custom_minimum_size = Vector2(196.0, 34.0)
	_shell_opt.item_selected.connect(_on_shell_picked)
	h.add_child(_shell_opt)

	_layout_opt = OptionButton.new()
	_layout_opt.name = "shell_layout_preview"
	_layout_opt.tooltip_text = T("shell.preview_layout")
	_layout_opt.custom_minimum_size = Vector2(158.0, 34.0)
	_layout_opt.item_selected.connect(_on_layout_preview)
	h.add_child(_layout_opt)

	h.add_child(ThemeKit.chip(T("shell.r1"), ThemeKit.CYAN))
	h.add_child(ThemeKit.spacer())
	return bar


func _build_rail() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(104.0, 0.0)
	var sb := ThemeKit.box(ShellTheme.PANEL, ShellTheme.STROKE, 0, 0, 8.0, 12.0)
	sb.border_width_right = 1
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var defs := [
		["terrain", "shell.tool.terrain"],
		["decor", "shell.tool.decor"],
		["spine", "shell.tool.spine"],
		["platform", "shell.tool.platform"],
	]
	var group := ButtonGroup.new()
	for d in defs:
		var id := String(d[0])
		var b := Button.new()
		b.name = "shell_tool_" + id
		b.text = T(String(d[1]))
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(88.0, 62.0)
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", ShellTheme.TEXT_SUB)
		b.add_theme_color_override("font_pressed_color", ShellTheme.LEGACY_GOLD_HI)
		b.add_theme_stylebox_override("normal", ThemeKit.box(ShellTheme.PANEL, ShellTheme.STROKE, 9, 1, 6.0, 6.0))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ShellTheme.PANEL_HI, ShellTheme.STROKE, 9, 1, 6.0, 6.0))
		b.add_theme_stylebox_override("pressed", ThemeKit.box(Color(ShellTheme.LEGACY_GOLD.r, ShellTheme.LEGACY_GOLD.g, ShellTheme.LEGACY_GOLD.b, 0.18), ShellTheme.LEGACY_GOLD, 9, 1, 6.0, 6.0))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(_show_tool.bind(id))
		v.add_child(b)
		_tool_buttons[id] = b
	v.add_child(ThemeKit.spacer())
	return panel


func _build_viewport() -> Control:
	var wrap := VBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_theme_constant_override("separation", 0)
	_svc = SubViewportContainer.new()
	_svc.name = "shell_viewport"
	_svc.stretch = false
	_svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_svc.custom_minimum_size = Vector2(520.0, 360.0)
	_svc.mouse_filter = Control.MOUSE_FILTER_STOP
	_svc.focus_mode = Control.FOCUS_CLICK
	_sv = SubViewport.new()
	_sv.name = "ShellViewport"
	_sv.own_world_3d = true
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sv.msaa_3d = Viewport.MSAA_2X
	_sv.size = Vector2i(960, 640)
	_svc.add_child(_sv)
	wrap.add_child(_svc)
	var info := PanelContainer.new()
	info.custom_minimum_size = Vector2(0.0, 30.0)
	info.add_theme_stylebox_override("panel", ThemeKit.box(ShellTheme.BG_DEEP, ShellTheme.STROKE, 0, 0, 12.0, 4.0))
	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 10)
	info.add_child(info_row)
	_hover_label = ThemeKit.caption(T("shell.hover.idle"), ShellTheme.TEXT_DIM)
	info_row.add_child(_hover_label)
	info_row.add_child(ThemeKit.spacer())
	# 操作提示：这套键位是从旧地图编辑器继承下来的，别让人靠猜
	var controls := ThemeKit.caption(T("shell.view.controls"), ShellTheme.TEXT_DIM)
	controls.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info_row.add_child(controls)
	wrap.add_child(info)
	_svc.gui_input.connect(_on_view_input)
	_svc.resized.connect(_sync_viewport)
	return wrap


func _build_inspector() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(392.0, 0.0)
	var sb := ThemeKit.box(ShellTheme.BG, ShellTheme.STROKE, 0, 0, 0.0, 0.0)
	sb.border_width_left = 1
	panel.add_theme_stylebox_override("panel", sb)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector.add_theme_constant_override("separation", 10)
	_inspector.custom_minimum_size = Vector2(376.0, 0.0)
	scroll.add_child(_inspector)
	return panel


func _build_status() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size = Vector2(0.0, 34.0)
	var sb := ThemeKit.box(ShellTheme.BG_DEEP, ShellTheme.STROKE, 0, 0, 18.0, 0.0)
	sb.border_width_top = 1
	bar.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	bar.add_child(h)
	_counts = ThemeKit.caption("", ShellTheme.TEXT_SUB)
	h.add_child(_counts)
	_gap_chip = ThemeKit.chip("", ThemeKit.CYAN)
	h.add_child(_gap_chip)
	_state_label = ThemeKit.caption(T("shell.state.saved"), ThemeKit.GREEN)
	_state_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(_state_label)
	var reload := ThemeKit.small_button(T("shell.reload"), ShellTheme.TEXT_SUB)
	reload.name = "shell_reload"
	reload.custom_minimum_size = Vector2(58.0, 26.0)
	reload.pressed.connect(_on_reload)
	h.add_child(reload)
	var save := ThemeKit.small_button(T("shell.save"), ShellTheme.LEGACY_GOLD_HI)
	save.name = "shell_save"
	save.custom_minimum_size = Vector2(76.0, 26.0)
	save.pressed.connect(_save)
	h.add_child(save)
	h.add_child(ThemeKit.spacer())
	h.add_child(ThemeKit.caption(T("shell.save_path"), ShellTheme.TEXT_DIM))
	return bar


func _sync_viewport() -> void:
	if _sv == null or _svc == null:
		return
	_sv.size = Vector2i(maxi(1, int(_svc.size.x)), maxi(1, int(_svc.size.y)))


# ===========================================================================
# 3D
# ===========================================================================
func _bind_view() -> void:
	view = ShellView.new()
	view.name = "ShellView"
	_sv.add_child(view)
	view.call("build_world")
	view.connect("changed", Callable(self, "_on_view_changed"))
	view.connect("brushed", Callable(self, "_on_view_brushed"))
	view.connect("picked", Callable(self, "_on_view_picked"))


func _select_first_shell() -> void:
	var list: Array = data.call("shell_list")
	_shell_opt.clear()
	for i in list.size():
		var d: Dictionary = list[i]
		_shell_opt.add_item(String(d.get("display_name", d.get("id", ""))))
		_shell_opt.set_item_metadata(i, String(d.get("id", "")))
	if list.is_empty():
		_shell_opt.add_item(T("shell.none"))
		_shell_opt.set_item_metadata(0, "")
		shell_id = ""
		return
	_shell_opt.select(0)
	shell_id = String(_shell_opt.get_item_metadata(0))
	_load_shell()
	_rebuild_layout_options()


func _load_shell() -> void:
	var shell: Dictionary = data.call("shell_by_id", shell_id)
	if shell.is_empty():
		return
	view.call("load_shell", shell)
	_refresh_status()


func _rebuild_layout_options() -> void:
	_layout_opt.clear()
	_layout_opt.add_item(T("shell.preview_none"))
	_layout_opt.set_item_metadata(0, "")
	var idx := 1
	for l in (data.call("layouts_of_shell", shell_id) as Array):
		var d: Dictionary = l
		_layout_opt.add_item(String(d.get("display_name", d.get("id", ""))))
		_layout_opt.set_item_metadata(idx, String(d.get("id", "")))
		idx += 1
	_layout_opt.select(0)


func _on_shell_picked(index: int) -> void:
	shell_id = String(_shell_opt.get_item_metadata(index))
	_load_shell()
	_rebuild_layout_options()
	_show_tool(_active_tool())


func _on_layout_preview(index: int) -> void:
	var lid := String(_layout_opt.get_item_metadata(index))
	view.set("preview_layout", data.call("layout_by_id", lid))
	view.call("_build_platforms")
	_refresh_status()


func _on_view_input(event: InputEvent) -> void:
	if view == null:
		return
	# 点进视口就拿键盘焦点：WASD / QE / 1-2 / F 这一套和旧编辑器一致
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_svc.grab_focus()
	var pos := Vector2.ZERO
	if event is InputEventMouse:
		pos = (event as InputEventMouse).position
	var handled: bool = bool(view.call("handle_input", event, pos))
	if handled:
		_svc.accept_event()
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Alt+左键是转视角，不能顺手把选中的石台/装饰拖走
		if bool(view.call("is_dragging")) and not bool(view.call("is_orbiting")):
			view.call("drag_to", view.call("ground_at", pos))
			_svc.accept_event()


func _process(_delta: float) -> void:
	if view == null or _hover_label == null:
		return
	# 视口有没有键盘焦点：等价于旧编辑器的 has_focus()
	view.set("keys_focus", _svc != null and _svc.has_focus())
	var info: Dictionary = view.call("hover_info")
	if bool(info.get("valid", false)):
		_hover_label.text = T("shell.hover.value", {
			"x": "%.1f" % float(info.get("x", 0.0)),
			"z": "%.1f" % float(info.get("z", 0.0)),
			"y": "%.2f" % float(info.get("y", 0.0)),
			"raw": "%.0f" % (absf(float(info.get("x", 0.0))) / ShellStore.R1),
		})


# ===========================================================================
# 四个工具面板
# ===========================================================================
func _active_tool() -> String:
	for id in _tool_buttons.keys():
		if (_tool_buttons[id] as Button).button_pressed:
			return String(id)
	return "terrain"


func _show_tool(id: String) -> void:
	for k in _tool_buttons.keys():
		(_tool_buttons[k] as Button).button_pressed = String(k) == id
	view.set("tool", id)
	for c in _inspector.get_children():
		c.queue_free()
	match id:
		"terrain":
			_build_terrain_panel()
		"decor":
			_build_decor_panel()
		"spine":
			_build_spine_panel()
		"platform":
			_build_platform_panel()
	_refresh_status()


func _dirty_now() -> void:
	_dirty = true
	_set_state(T("shell.state.dirty"), ShellTheme.GOLD)
	if _save_timer != null:
		_save_timer.start()


func _set_state(text: String, color: Color) -> void:
	if _state_label != null:
		_state_label.text = text
		_state_label.add_theme_color_override("font_color", color)


func _save() -> void:
	if _save_timer != null:
		_save_timer.stop()
	if data == null:
		return
	view.call("snap_platforms")
	var ok: bool = bool(data.call("save_shells"))
	_dirty = not ok
	_set_state(T("shell.state.saved") if ok else T("shell.state.failed"), ThemeKit.GREEN if ok else ThemeKit.RED)


func _on_reload() -> void:
	if data.call("load_all"):
		_select_first_shell()
		_show_tool(_active_tool())
		_set_state(T("shell.state.reloaded"), ThemeKit.CYAN)


func _on_view_changed() -> void:
	_dirty_now()
	_refresh_status()
	if _active_tool() == "platform":
		_rebuild_platform_list()


func _on_view_brushed() -> void:
	_dirty_now()


func _on_view_picked(kind: String, _index: int) -> void:
	if kind == "platform":
		_refresh_platform_detail()
	elif kind == "decor":
		_refresh_decor_info()
	elif kind == "divider":
		_refresh_divider_fields()


# --- 地形 -----------------------------------------------------------------
func _build_terrain_panel() -> void:
	_inspector.add_child(ThemeKit.section_head(T("shell.terrain.title"), T("shell.terrain.eyebrow"), ShellTheme.LEGACY_GOLD))
	var body := ThemeKit.inset()
	_inspector.add_child(body)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	body.add_child(v)

	v.add_child(ThemeKit.field_label(T("shell.terrain.mode")))
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 5)
	var defs := [
		["raise", "shell.terrain.raise"],
		["lower", "shell.terrain.lower"],
		["smooth", "shell.terrain.smooth"],
		["flatten", "shell.terrain.flatten"],
		["surface", "shell.terrain.surface"],
	]
	var group := ButtonGroup.new()
	for d in defs:
		var mode := String(d[0])
		var b := ThemeKit.toggle(T(String(d[1])), mode == "raise", ShellTheme.LEGACY_GOLD, 0.0)
		b.name = "shell_brush_" + mode
		b.button_group = group
		b.pressed.connect(_on_brush_mode.bind(mode))
		modes.add_child(b)
		_brush_buttons[mode] = b
	v.add_child(modes)

	_radius_slider = _slider(v, T("shell.terrain.radius"), 1.0, 30.0, 6.0, func(val): view.set("brush_radius", val))
	_strength_slider = _slider(v, T("shell.terrain.strength"), 0.1, 2.0, 0.6, func(val): view.set("brush_strength", val))

	v.add_child(ThemeKit.hairline())
	v.add_child(ThemeKit.field_label(T("shell.terrain.layer")))
	var layers := HBoxContainer.new()
	layers.add_theme_constant_override("separation", 6)
	var pal: Array = ShellStore.palette(view.get("shell"))
	for i in pal.size():
		var row: Dictionary = pal[i]
		var b := Button.new()
		b.name = "shell_layer_%d" % i
		b.text = String(row.get("display_name", row.get("id", str(i))))
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0.0, 34.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var col := Color(String(row.get("color", "#5D6B3F")))
		b.add_theme_stylebox_override("normal", ThemeKit.box(ShellTheme.PANEL, ShellTheme.STROKE, 8, 1, 6.0, 5.0))
		b.add_theme_stylebox_override("pressed", ThemeKit.box(Color(col.r, col.g, col.b, 0.45), col, 8, 1, 6.0, 5.0))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ShellTheme.PANEL_HI, col, 8, 1, 6.0, 5.0))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.add_theme_color_override("font_color", ShellTheme.LEGACY_TEXT)
		b.pressed.connect(_on_layer.bind(i))
		layers.add_child(b)
		_layer_buttons[i] = b
	v.add_child(layers)

	v.add_child(ThemeKit.hairline())
	var water := float((view.get("shell").get("terrain", {}) as Dictionary).get("water_level", 0.2))
	_water_slider = _slider(v, T("shell.terrain.water"), -3.0, 6.0, water, _on_water)
	var amb: Dictionary = (view.get("shell").get("terrain", {}) as Dictionary).get("ambient", {})
	_ambient_slider = _slider(v, T("shell.terrain.ambient"), 0.2, 2.0, float(amb.get("energy", 0.55)), _on_ambient)
	_fog_slider = _slider(v, T("shell.terrain.fog"), 0.0, 0.05, float(amb.get("fog_density", 0.0032)), _on_fog)

	var hint := ThemeKit.caption(T("shell.terrain.hint"), ShellTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)


func _slider(parent: VBoxContainer, title: String, lo: float, hi: float, value: float, cb: Callable) -> HSlider:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var l := ThemeKit.field_label(title)
	l.custom_minimum_size = Vector2(118.0, 0.0)
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = (hi - lo) / 200.0
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(0.0, 22.0)
	h.add_child(s)
	var out := ThemeKit.value_label("%.2f" % value, ShellTheme.LEGACY_GOLD_HI)
	out.custom_minimum_size = Vector2(48.0, 0.0)
	out.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(out)
	parent.add_child(h)
	s.value_changed.connect(func(val):
		out.text = "%.2f" % val
		if cb.is_valid():
			cb.call(val)
	)
	return s


func _on_brush_mode(mode: String) -> void:
	view.set("brush_mode", mode)


func _on_layer(index: int) -> void:
	view.set("surface_layer", index)
	view.set("brush_mode", "surface")
	for k in _brush_buttons.keys():
		(_brush_buttons[k] as Button).button_pressed = String(k) == "surface"


func _on_water(value: float) -> void:
	var shell: Dictionary = view.get("shell")
	if shell.is_empty():
		return
	var terrain: Dictionary = shell.get("terrain", {})
	terrain["water_level"] = snappedf(value, 0.01)
	shell["terrain"] = terrain
	view.call("_build_water")
	_dirty_now()


func _on_ambient(value: float) -> void:
	var shell: Dictionary = view.get("shell")
	if shell.is_empty():
		return
	var terrain: Dictionary = shell.get("terrain", {})
	var amb: Dictionary = terrain.get("ambient", {})
	amb["energy"] = snappedf(value, 0.01)
	terrain["ambient"] = amb
	shell["terrain"] = terrain
	view.call("update_ambient")
	_dirty_now()


func _on_fog(value: float) -> void:
	var shell: Dictionary = view.get("shell")
	if shell.is_empty():
		return
	var terrain: Dictionary = shell.get("terrain", {})
	var amb: Dictionary = terrain.get("ambient", {})
	amb["fog_density"] = snappedf(value, 0.001)
	terrain["ambient"] = amb
	shell["terrain"] = terrain
	view.call("update_ambient")
	_dirty_now()


# --- 装饰 -----------------------------------------------------------------
func _build_decor_panel() -> void:
	_inspector.add_child(ThemeKit.section_head(T("shell.decor.title"), T("shell.decor.eyebrow"), ShellTheme.GREEN))
	var body := ThemeKit.inset()
	_inspector.add_child(body)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	body.add_child(v)
	v.add_child(ThemeKit.field_label(T("shell.decor.kind")))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	for kind in ShellStore.DECOR_KINDS:
		var b := ThemeKit.toggle(T(DECOR_KEY + String(kind)), String(kind) == "tree", ShellTheme.GREEN, 0.0)
		b.name = "shell_decor_" + String(kind)
		b.custom_minimum_size = Vector2(0.0, 34.0)
		b.pressed.connect(_on_decor_kind.bind(String(kind)))
		grid.add_child(b)
		_decor_buttons[kind] = b
	v.add_child(grid)
	_decor_info = ThemeKit.caption(T("shell.decor.none"), ShellTheme.TEXT_DIM)
	_decor_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_decor_info)
	_decor_scale = _slider(v, T("shell.decor.scale"), 0.4, 3.0, 1.0, _on_decor_scale)
	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 6)
	var rot := ThemeKit.small_button(T("shell.decor.rotate"), ShellTheme.GREEN)
	rot.pressed.connect(_on_decor_rotate)
	ops.add_child(rot)
	var del := ThemeKit.small_button(T("shell.decor.delete"), ShellTheme.LEGACY_RED)
	del.pressed.connect(_on_decor_delete)
	ops.add_child(del)
	v.add_child(ops)
	var hint := ThemeKit.caption(T("shell.decor.hint"), ShellTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	_refresh_decor_info()


func _on_decor_kind(kind: String) -> void:
	view.set("decor_kind", kind)
	for k in _decor_buttons.keys():
		(_decor_buttons[k] as Button).button_pressed = String(k) == kind


func _on_decor_scale(value: float) -> void:
	var idx := int(view.get("selected_decor"))
	if idx >= 0:
		view.call("set_decor_scale", idx, value)


func _on_decor_rotate() -> void:
	var idx := int(view.get("selected_decor"))
	if idx >= 0:
		view.call("rotate_decor", idx, 45.0)


func _on_decor_delete() -> void:
	var idx := int(view.get("selected_decor"))
	if idx >= 0:
		view.call("remove_decor", idx)
		_refresh_decor_info()


func _refresh_decor_info() -> void:
	if _decor_info == null:
		return
	var idx := int(view.get("selected_decor"))
	var list: Array = (view.get("shell").get("decorations", []) as Array)
	if idx < 0 or idx >= list.size():
		_decor_info.text = T("shell.decor.none")
		return
	var d: Dictionary = list[idx]
	_decor_info.text = T("shell.decor.selected", {
		"n": idx + 1,
		"k": T(DECOR_KEY + String(d.get("kind", ""))),
		"x": "%.1f" % float(d.get("x", 0.0)),
		"z": "%.1f" % float(d.get("z", 0.0)),
		"s": "%.2f" % float(d.get("scale", 1.0)),
	})


# --- 脊线 -----------------------------------------------------------------
func _build_spine_panel() -> void:
	_inspector.add_child(ThemeKit.section_head(T("shell.spine.title"), T("shell.spine.eyebrow"), ThemeKit.CYAN))
	var body := ThemeKit.inset()
	_inspector.add_child(body)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	body.add_child(v)
	var shell: Dictionary = view.get("shell")
	v.add_child(ThemeKit.caption(T("shell.spine.hint"), ShellTheme.TEXT_DIM))
	var wh := HBoxContainer.new()
	wh.add_theme_constant_override("separation", 8)
	wh.add_child(ThemeKit.field_label(T("shell.spine.width")))
	_width_edit = ThemeKit.num_field("%.0f" % float((shell.get("spine", {}) as Dictionary).get("width_logic", 420.0)), 90.0)
	_width_edit.name = "shell_spine_width"
	_width_edit.text_submitted.connect(_on_width)
	_width_edit.focus_exited.connect(_commit_width)
	wh.add_child(_width_edit)
	var wm := ThemeKit.caption(T("shell.spine.width_value", {
		"v": "%.0f" % float((shell.get("spine", {}) as Dictionary).get("width_logic", 420.0)),
		"m": "%.2f" % (float((shell.get("spine", {}) as Dictionary).get("width_logic", 420.0)) * ShellStore.R1),
	}), ShellTheme.LEGACY_GOLD_HI)
	wm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wh.add_child(wm)
	v.add_child(wh)
	v.add_child(ThemeKit.hairline())
	v.add_child(ThemeKit.field_label(T("shell.spine.dividers")))
	for id in ShellStore.DIVIDER_IDS:
		v.add_child(_divider_row(shell, id))
	v.add_child(ThemeKit.hairline())
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 6)
	_points_label = ThemeKit.caption("", ShellTheme.TEXT_SUB)
	ph.add_child(_points_label)
	ph.add_child(ThemeKit.spacer())
	var add := ThemeKit.small_button(T("shell.spine.add_point"), ThemeKit.CYAN)
	add.pressed.connect(func():
		view.call("add_spine_point")
		_refresh_spine_fields()
	)
	ph.add_child(add)
	var rem := ThemeKit.small_button(T("shell.spine.remove_point"), ShellTheme.TEXT_DIM)
	rem.pressed.connect(func():
		view.call("remove_spine_point")
		_refresh_spine_fields()
	)
	ph.add_child(rem)
	v.add_child(ph)
	var focus := ThemeKit.small_button(T("shell.spine.top_view"), ThemeKit.CYAN)
	# 和旧编辑器的「俯视」同一个角度（俯角 88° / yaw 0），不是随手一个新机位
	focus.pressed.connect(func(): view.call("set_view_top"))
	v.add_child(focus)
	_refresh_spine_fields()


func _divider_row(shell: Dictionary, id: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var d: Dictionary = ShellStore.divider(shell, id)
	var label_text := T(ShellStore.DIVIDER_KEYS.get(id, id))
	var l := ThemeKit.label(label_text, &"EditorBody", Color(0.94, 0.78, 0.42))
	l.custom_minimum_size = Vector2(132.0, 0.0)
	row.add_child(l)
	var le := ThemeKit.num_field("%d" % int(d.get("t", 0)), 64.0)
	le.name = "shell_divider_" + id
	le.text_submitted.connect(_on_divider.bind(id, le))
	le.focus_exited.connect(_commit_divider.bind(id, le))
	row.add_child(le)
	var out := ThemeKit.caption(T("shell.spine.divider_value", {
		"v": "%.0f" % float(d.get("length_logic", 0.0)),
		"m": "%.1f" % float(d.get("meters", 0.0)),
	}), ShellTheme.TEXT_SUB)
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(out)
	_divider_edits[id] = {"edit": le, "label": out}
	return row


func _on_width(text: String) -> void:
	_commit_width(text)


func _commit_width(text: String) -> void:
	if not text.strip_edges().is_valid_float():
		return
	var v := clampf(round(float(text)), 100.0, 999.0)
	view.call("set_spine_width", v)
	_width_edit.text = "%.0f" % v
	_dirty_now()
	_refresh_spine_fields()


func _on_divider(_text: String, id: String, le: LineEdit) -> void:
	_commit_divider(id, le)


func _commit_divider(id: String, le: LineEdit) -> void:
	if not le.text.strip_edges().is_valid_float():
		return
	var t := clampi(int(round(float(le.text))), 0, 999)
	view.call("set_divider_t", id, t)
	le.text = str(t)
	_dirty_now()
	_refresh_spine_fields()


func _refresh_spine_fields() -> void:
	var shell: Dictionary = view.get("shell")
	if shell.is_empty():
		return
	for id in _divider_edits.keys():
		var row: Dictionary = _divider_edits[id]
		var d: Dictionary = ShellStore.divider(shell, id)
		(row["edit"] as LineEdit).text = "%d" % int(d.get("t", 0))
		(row["label"] as Label).text = T("shell.spine.divider_value", {
			"v": "%.0f" % float(d.get("length_logic", 0.0)),
			"m": "%.1f" % float(d.get("meters", 0.0)),
		})
	if _points_label != null:
		_points_label.text = T("shell.spine.points", {
			"n": (ShellStore.spine_points(shell) as Array).size()
		})


func _refresh_divider_fields() -> void:
	_refresh_spine_fields()


# --- 石台 -----------------------------------------------------------------
func _build_platform_panel() -> void:
	_inspector.add_child(ThemeKit.section_head(T("shell.platform.title"), T("shell.platform.eyebrow"), ThemeKit.ACCENT))
	var body := ThemeKit.inset()
	_inspector.add_child(body)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	body.add_child(v)
	v.add_child(ThemeKit.caption(T("shell.platform.hint"), ShellTheme.TEXT_DIM))
	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 6)
	var add := ThemeKit.small_button(T("shell.platform.add"), ThemeKit.ACCENT)
	add.name = "shell_add_platform"
	add.pressed.connect(_on_add_platform)
	ops.add_child(add)
	var snap := ThemeKit.small_button(T("shell.platform.snap"), ThemeKit.CYAN)
	snap.pressed.connect(func():
		view.call("snap_platforms")
		_dirty_now()
	)
	ops.add_child(snap)
	var renum := ThemeKit.small_button(T("shell.platform.renumber"), ShellTheme.TEXT_DIM)
	renum.pressed.connect(func():
		view.call("renumber_platforms")
		_dirty_now()
		_rebuild_platform_list()
	)
	ops.add_child(renum)
	v.add_child(ops)
	_platform_list = VBoxContainer.new()
	_platform_list.add_theme_constant_override("separation", 3)
	v.add_child(_platform_list)
	v.add_child(ThemeKit.hairline())
	_platform_info = ThemeKit.caption("", ShellTheme.TEXT_SUB)
	_platform_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_platform_info)
	var roles := HBoxContainer.new()
	roles.add_theme_constant_override("separation", 6)
	for role in ShellStore.PLATFORM_ROLES:
		var b := ThemeKit.toggle(T(ROLE_KEY + role), false, ShellTheme.LEGACY_GOLD, 0.0)
		b.name = "shell_role_" + role
		b.pressed.connect(_on_role.bind(role))
		roles.add_child(b)
		_role_buttons[role] = b
	v.add_child(roles)
	_radius_pl = _slider(v, T("shell.platform.radius"), 1.0, 6.0, 2.0, _on_platform_radius)
	_base_pl = _slider(v, T("shell.platform.base"), 0.4, 4.0, 0.9, _on_platform_base)
	var del := ThemeKit.small_button(T("shell.platform.delete"), ShellTheme.LEGACY_RED)
	del.name = "shell_delete_platform"
	del.pressed.connect(_on_delete_platform)
	v.add_child(del)
	_rebuild_platform_list()
	_refresh_platform_detail()


func _rebuild_platform_list() -> void:
	if _platform_list == null:
		return
	for c in _platform_list.get_children():
		c.queue_free()
	var shell: Dictionary = view.get("shell")
	var sel := int(view.get("selected_platform"))
	for p in ShellStore.platforms(shell):
		var d: Dictionary = p
		var idx := int(d.get("index", 0))
		var side := String(d.get("side", "player"))
		var role := String(d.get("role", "build"))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var b := Button.new()
		b.name = "shell_platform_%d" % idx
		b.toggle_mode = true
		b.button_pressed = idx == sel
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0.0, 30.0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var col := ThemeKit.ACCENT if side == "player" else ShellTheme.RED
		b.add_theme_stylebox_override("normal", ThemeKit.box(ShellTheme.PANEL, ShellTheme.STROKE, 7, 1, 8.0, 4.0))
		b.add_theme_stylebox_override("hover", ThemeKit.box(ShellTheme.PANEL_HI, col, 7, 1, 8.0, 4.0))
		b.add_theme_stylebox_override("pressed", ThemeKit.box(Color(col.r, col.g, col.b, 0.2), col, 7, 1, 8.0, 4.0))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.text = "%s  P%d  %s" % [T(SIDE_KEY + side), idx, T(ROLE_KEY + role)]
		b.pressed.connect(_on_pick_platform.bind(idx))
		row.add_child(b)
		_platform_list.add_child(row)


func _on_pick_platform(index: int) -> void:
	view.call("select_platform", index)
	_rebuild_platform_list()
	_refresh_platform_detail()


func _on_add_platform() -> void:
	view.call("add_platform", Vector3(-16.0, 0.0, 0.0))
	_dirty_now()
	_rebuild_platform_list()
	_refresh_platform_detail()


func _on_delete_platform() -> void:
	var idx := int(view.get("selected_platform"))
	if idx >= 0:
		view.call("remove_platform", idx)
		_dirty_now()
		_rebuild_platform_list()
		_refresh_platform_detail()


func _on_role(role: String) -> void:
	var idx := int(view.get("selected_platform"))
	if idx >= 0:
		view.call("set_platform_role", idx, role)
		_dirty_now()
		_rebuild_platform_list()
		_refresh_platform_detail()


func _on_platform_radius(value: float) -> void:
	var idx := int(view.get("selected_platform"))
	if idx >= 0:
		view.call("set_platform_radius", idx, value)
		_dirty_now()


func _on_platform_base(value: float) -> void:
	var idx := int(view.get("selected_platform"))
	if idx >= 0:
		view.call("set_platform_base", idx, value)
		_dirty_now()


func _refresh_platform_detail() -> void:
	if _platform_info == null:
		return
	var idx := int(view.get("selected_platform"))
	var pd := ShellStore.platform_by_index(view.get("shell"), idx)
	if pd.is_empty():
		_platform_info.text = T("shell.platform.none")
		return
	var role := String(pd.get("role", "build"))
	for r in _role_buttons.keys():
		(_role_buttons[r] as Button).button_pressed = String(r) == role
	if _radius_pl != null:
		_radius_pl.value = float(pd.get("radius", 2.0))
	if _base_pl != null:
		_base_pl.value = float(pd.get("base_h", 0.9))
	_platform_info.text = T("shell.platform.selected", {
		"i": idx,
		"side": T(SIDE_KEY + String(pd.get("side", "player"))),
		"role": T(ROLE_KEY + role),
		"y": "%.2f" % float(pd.get("terrain_y", 0.0)),
		"h": "%.2f" % float(pd.get("base_h", 0.0)),
		"r": "%.2f" % float(pd.get("radius", 0.0)),
	})


# ===========================================================================
# 状态
# ===========================================================================
func _refresh_status() -> void:
	if _counts == null:
		return
	var shell: Dictionary = view.get("shell")
	if shell.is_empty():
		return
	_counts.text = T("shell.status.counts", {
		"p": ShellStore.platforms(shell).size(),
		"d": (shell.get("decorations", []) as Array).size(),
		"k": _keep_count(shell, "player"),
		"w": "%.0f" % float((shell.get("spine", {}) as Dictionary).get("width_logic", 420.0)),
	})
	ThemeKit.set_chip(_gap_chip, T("shell.status.gap", {
		"v": "%.2f" % ShellStore.min_gap_meters(shell)
	}), ThemeKit.CYAN if ShellStore.min_gap_meters(shell) >= ShellStore.MIN_GAP_M else ShellTheme.RED)


func _keep_count(shell: Dictionary, side: String) -> int:
	var n := 0
	for p in ShellStore.platforms(shell):
		var d: Dictionary = p
		if String(d.get("role", "")) == "keep" and String(d.get("side", "")) == side:
			n += 1
	return n