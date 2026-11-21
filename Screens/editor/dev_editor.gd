@tool
extends Control
## 《战争原岛》开发者编辑器 · 主壳
## 属于：Screens/editor（开发工具，不进发行版）
##
## 五个页签（2026-11-21 三分离改造）：
##   01 单位与 DPS 靶场对账
##   02 建筑与卡牌
##   03 玩家态势布局卡（player_layouts.json）
##   04 敌人遭遇卡（enemy_encounters.json）
##   05 战斗节点组装（levels.json：底壳 × 布局卡 × 遭遇卡）
##
## 地图底壳（地形/装饰/脊线/战术格子）不在这里：见 addons/map_shell_editor（3D 底壳编辑器）。
##
## 盘子：顶栏（品牌 / R1 / 保存状态 / 校验）、页签条、页面容器、状态栏。
## 页面各自 preload，主壳只负责切页、脏标记与统一写回。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const DataScript := preload("res://Screens/editor/dev_data.gd")
const PageUnits := preload("res://Screens/editor/page_units.gd")
const PageBuild := preload("res://Screens/editor/page_build.gd")
const PageLayouts := preload("res://Screens/editor/page_layouts.gd")
const PageEncounters := preload("res://Screens/editor/page_encounters.gd")
const PageAssembly := preload("res://Screens/editor/page_assembly.gd")
const Backdrop := preload("res://Screens/editor/backdrop.gd")
const Logo := preload("res://Screens/editor/logo.gd")

var data: RefCounted = null

var _pages: Array = []
var _tabs: Array = []
var _save_timer: Timer = null
var _save_dot: ColorRect = null
var _save_label: Label = null
var _status_counts: Label = null
var _status_saved: Label = null
var _dialog: AcceptDialog = null
var _dirty := false
var _active := 0


# ===========================================================================
# 背景：深岩渐变 + 两团冷光 + 等高线（不是网格）
# ===========================================================================
# ===========================================================================
# 生命周期
# ===========================================================================
func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = ThemeKit.build_theme()
	data = DataScript.new()
	data.call("load_all")

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)

	var backdrop := _build_backdrop()
	add_child(backdrop)
	add_child(root)
	root.add_child(_build_topbar())
	root.add_child(_build_tabs())
	root.add_child(_build_pages())
	root.add_child(_build_status())

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.7
	_save_timer.timeout.connect(_on_save_timeout)
	add_child(_save_timer)

	_build_dialog()
	_show_page(0)
	_update_counts()
	_set_save_state(T("editor.app.saved"), ThemeKit.GREEN)


func _build_backdrop() -> Control:
	var bg := Backdrop.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return bg


# ===========================================================================
# 顶栏
# ===========================================================================
func _build_topbar() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size = Vector2(0.0, 78.0)
	var sb := ThemeKit.box(ThemeKit.BG_TOP, ThemeKit.STROKE, 0, 0, 24.0, 0.0)
	sb.border_width_bottom = 1
	bar.add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	bar.add_child(h)

	var logo := Logo.new()
	h.add_child(logo)

	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override("separation", 1)
	title_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_box.add_child(ThemeKit.label(T("editor.app.title"), &"EditorH2"))
	title_box.add_child(ThemeKit.caption(T("editor.app.subtitle"), ThemeKit.TEXT_SUB))
	h.add_child(title_box)

	h.add_child(ThemeKit.spacer())

	var r1 := ThemeKit.chip(T("editor.app.r1"), ThemeKit.CYAN)
	r1.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(r1)

	var state_box := HBoxContainer.new()
	state_box.add_theme_constant_override("separation", 7)
	state_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_save_dot = ColorRect.new()
	_save_dot.color = ThemeKit.GREEN
	_save_dot.custom_minimum_size = Vector2(7.0, 7.0)
	_save_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	state_box.add_child(_save_dot)
	_save_label = ThemeKit.caption(T("editor.app.saved"), ThemeKit.TEXT_SUB)
	state_box.add_child(_save_label)
	h.add_child(state_box)

	var reload_btn := ThemeKit.small_button(T("editor.app.reload"), ThemeKit.TEXT_SUB)
	reload_btn.custom_minimum_size = Vector2(84.0, 36.0)
	reload_btn.pressed.connect(_on_reload)
	h.add_child(reload_btn)

	var check_btn := ThemeKit.small_button(T("editor.app.validate"), ThemeKit.CYAN)
	check_btn.custom_minimum_size = Vector2(108.0, 36.0)
	check_btn.pressed.connect(_on_validate)
	h.add_child(check_btn)

	var save_btn := Button.new()
	save_btn.text = T("editor.app.save_all")
	save_btn.custom_minimum_size = Vector2(116.0, 36.0)
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.add_theme_stylebox_override("normal", ThemeKit.box(Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.16), ThemeKit.ACCENT, 9, 1, 16.0, 8.0))
	save_btn.add_theme_stylebox_override("hover", ThemeKit.box(Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.28), ThemeKit.ACCENT, 9, 1, 16.0, 8.0))
	save_btn.add_theme_stylebox_override("pressed", ThemeKit.box(Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.38), ThemeKit.ACCENT, 9, 1, 16.0, 8.0))
	save_btn.add_theme_color_override("font_color", ThemeKit.ACCENT)
	save_btn.add_theme_color_override("font_hover_color", Color("#FFFFFF"))
	save_btn.pressed.connect(_on_save_now)
	h.add_child(save_btn)
	return bar


# ===========================================================================
# 页签
# ===========================================================================
func _build_tabs() -> Control:
	var holder := MarginContainer.new()
	holder.custom_minimum_size = Vector2(0.0, 70.0)
	holder.add_theme_constant_override("margin_left", 24)
	holder.add_theme_constant_override("margin_right", 24)
	holder.add_theme_constant_override("margin_top", 10)
	holder.add_theme_constant_override("margin_bottom", 4)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	holder.add_child(h)

	var group := ButtonGroup.new()
	group.allow_unpress = false
	var defs := [
		["01", "editor.tab.units", "editor.tab.units_sub", ThemeKit.ACCENT],
		["02", "editor.tab.build", "editor.tab.build_sub", ThemeKit.GOLD],
		["03", "editor.tab.layouts", "editor.tab.layouts_sub", ThemeKit.CYAN],
		["04", "editor.tab.encounters", "editor.tab.encounters_sub", ThemeKit.RED],
		["05", "editor.tab.assembly", "editor.tab.assembly_sub", ThemeKit.GREEN],
	]
	for i in defs.size():
		var d: Array = defs[i]
		var b := _make_tab(String(d[0]), T(String(d[1])), T(String(d[2])), d[3] as Color)
		b.name = ["tab_units", "tab_build", "tab_layouts", "tab_encounters", "tab_assembly"][i]
		b.button_group = group
		b.button_pressed = i == 0
		b.pressed.connect(_show_page.bind(i))
		h.add_child(b)
		_tabs.append(b)
	h.add_child(ThemeKit.spacer())
	return holder


func _make_tab(index_text: String, title: String, subtitle: String, accent: Color) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(276.0, 54.0)
	b.add_theme_stylebox_override("normal", ThemeKit.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 12, 0, 16.0, 7.0))
	b.add_theme_stylebox_override("hover", ThemeKit.box(ThemeKit.CARD_DEEP, ThemeKit.STROKE, 12, 1, 16.0, 7.0))
	var sel := ThemeKit.box(ThemeKit.CARD, Color(accent.r, accent.g, accent.b, 0.55), 12, 1, 16.0, 7.0)
	sel.border_width_bottom = 2
	sel.border_color = accent
	b.add_theme_stylebox_override("pressed", sel)
	b.add_theme_stylebox_override("hover_pressed", sel)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 12)
	b.add_child(h)
	var num := ThemeKit.label(index_text, &"EditorCaps", accent)
	num.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(num)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(ThemeKit.label(title, &"EditorH3"))
	v.add_child(ThemeKit.caption(subtitle, ThemeKit.TEXT_DIM))
	h.add_child(v)
	return b


# ===========================================================================
# 页面容器
# ===========================================================================
func _build_pages() -> Control:
	var margin := MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	var host := Control.new()
	host.name = "page_host"
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.clip_contents = false
	if Engine.is_editor_hint():
		# 编辑器里主屏被侧栏/底部面板压缩，按设计尺寸给页面一个画布，再整体滚动；
		# 运行时（--shot / 游戏内）仍是满屏自适应，不出滚动条。
		var scroll := ScrollContainer.new()
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		margin.add_child(scroll)
		host.custom_minimum_size = Vector2(1600.0, 940.0)
		scroll.add_child(host)
	else:
		margin.add_child(host)

	var classes := [PageUnits, PageBuild, PageLayouts, PageEncounters, PageAssembly]
	for i in classes.size():
		var page: Control = classes[i].new()
		page.name = ["page_units", "page_build", "page_layouts", "page_encounters", "page_assembly"][i]
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		page.call("setup", self, data)
		page.visible = false
		host.add_child(page)
		_pages.append(page)
	return margin


# ===========================================================================
# 状态栏
# ===========================================================================
func _build_status() -> Control:
	var bar := PanelContainer.new()
	bar.custom_minimum_size = Vector2(0.0, 34.0)
	var sb := ThemeKit.box(Color("#0E1219"), ThemeKit.STROKE, 0, 0, 24.0, 0.0)
	sb.border_width_top = 1
	bar.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	bar.add_child(h)
	h.add_child(ThemeKit.dot(ThemeKit.GREEN, 6.0))
	h.add_child(ThemeKit.caption(T("editor.status.paths"), ThemeKit.TEXT_DIM))
	h.add_child(ThemeKit.spacer())
	_status_counts = ThemeKit.caption("", ThemeKit.TEXT_SUB)
	h.add_child(_status_counts)
	var sep := ColorRect.new()
	sep.color = ThemeKit.STROKE
	sep.custom_minimum_size = Vector2(1.0, 14.0)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(sep)
	_status_saved = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	h.add_child(_status_saved)
	return bar


# ===========================================================================
# 切页 / 保存 / 校验
# ===========================================================================
func _show_page(index: int) -> void:
	if index < 0 or index >= _pages.size():
		return
	_active = index
	for i in _pages.size():
		var p: Control = _pages[i]
		p.visible = i == index
		if i < _tabs.size():
			(_tabs[i] as Button).button_pressed = i == index
	var page: Control = _pages[index]
	page.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(page, "modulate:a", 1.0, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func T(key: String, params: Dictionary = {}) -> String:
	var i18n := get_node_or_null("/root/I18n")
	if i18n != null:
		return String(i18n.call("t", key, params))
	var text := key
	if data != null:
		var zh := String(data.call("i18n_zh", key, ""))
		if not zh.is_empty():
			text = zh
	for k in params.keys():
		text = text.replace("{%s}" % String(k), str(params[k]))
	return text


func mark_dirty() -> void:
	_dirty = true
	_set_save_state(T("editor.app.dirty"), ThemeKit.GOLD)
	if _save_timer != null:
		_save_timer.start()
	_update_counts()


func _on_save_timeout() -> void:
	_on_save_now()


## 组装页/外部调用：立刻写回（跑 --simulate 前必须先落盘）。
func save_now() -> void:
	_on_save_now()


func _on_reload() -> void:
	if _save_timer != null:
		_save_timer.stop()
	if bool(data.call("load_all")):
		_set_save_state(T("editor.app.reloaded"), ThemeKit.CYAN)
		_refresh_pages()
		_update_counts()
	else:
		_set_save_state(T("editor.app.reload_failed"), ThemeKit.RED)


func _on_save_now() -> void:
	if _save_timer != null:
		_save_timer.stop()
	_set_save_state(T("editor.app.saving"), ThemeKit.CYAN)
	var ok: bool = bool(data.call("save_all"))
	_dirty = not ok
	if ok:
		_set_save_state(T("editor.app.saved"), ThemeKit.GREEN)
		var now := Time.get_time_dict_from_system()
		_status_saved.text = T("editor.status.saved_at", {
			"t": "%02d:%02d:%02d" % [int(now.get("hour", 0)), int(now.get("minute", 0)), int(now.get("second", 0))]
		})
	else:
		_set_save_state(T("editor.app.dirty"), ThemeKit.RED)
	_update_counts()


func _set_save_state(text: String, color: Color) -> void:
	if _save_dot != null:
		_save_dot.color = color
	if _save_label != null:
		_save_label.text = text
		_save_label.add_theme_color_override("font_color", ThemeKit.TEXT_SUB if color == ThemeKit.GREEN else color)


func _update_counts() -> void:
	if _status_counts == null or data == null:
		return
	_status_counts.text = T("editor.status.counts", {
		"u": (data.call("unit_list") as Array).size(),
		"b": (data.call("buildings") as Array).size(),
		"c": (data.call("cards") as Array).size(),
		"d": (data.call("deck_start") as Array).size(),
		"s": (data.call("shell_list") as Array).size(),
		"l": (data.call("layout_list") as Array).size(),
		"e": (data.call("encounter_list") as Array).size(),
		"a": (data.call("assemblies") as Array).size(),
	})


func _refresh_pages() -> void:
	for p in _pages:
		if p != null and p.has_method("refresh"):
			p.call("refresh")


func _build_dialog() -> void:
	_dialog = AcceptDialog.new()
	_dialog.name = "validate_dialog"
	_dialog.title = T("editor.check.title")
	_dialog.ok_button_text = T("editor.check.close")
	_dialog.min_size = Vector2i(620, 520)
	add_child(_dialog)


func _on_validate() -> void:
	if _dialog == null:
		return
	var rows: Array = data.call("validate")
	var lines: Array[String] = []
	var fails := 0
	for r in rows:
		var d: Dictionary = r
		var ok := bool(d.get("ok", false))
		if not ok:
			fails += 1
		lines.append("%s  %s   %s" % ["✓" if ok else "✗", T(String(d.get("key", ""))), String(d.get("detail", ""))])
	_dialog.dialog_text = "\n".join(lines)
	_dialog.title = T("editor.app.valid", {"d": rows.size()}) if fails == 0 else T("editor.app.invalid", {"d": fails})
	_dialog.popup_centered(Vector2i(720, 560))
