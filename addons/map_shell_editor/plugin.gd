@tool
extends EditorPlugin
## 3D 地图底壳编辑器（MapShellEditor）· Godot 编辑器插件
## 属于：addons/map_shell_editor（开发工具，不进发行版）
##
## 只把 Screens/editor/map_shell/map_shell_editor.tscn 挂成编辑器主屏 + 一个「地图底壳」Dock。
## 业务逻辑全在场景脚本里；这里只做入口、Dock 快捷工具、自检与截图。
##
## 许可命令：
##   godot --path . --editor -- --map-shell-open
##   godot --headless --editor -- --map-shell-selftest
##   godot --path . --editor -- --map-shell-shot=E:/tmp/shell.png

const SCENE := "res://Screens/editor/map_shell/map_shell_editor.tscn"
const CFG := "res://addons/map_shell_editor/plugin.cfg"
const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const ShellTheme := preload("res://Screens/editor/map_shell/shell_theme.gd")
const ShellText := preload("res://Screens/editor/map_shell/shell_text.gd")

const TOOLS := ["terrain", "decor", "spine", "platform"]

var _root: Control = null
var _ms: Control = null
var _dock: VBoxContainer = null
var _plugin_name := ""


func _enter_tree() -> void:
	ShellText.load_table()
	_plugin_name = _read_name()
	var packed: PackedScene = load(SCENE)
	if packed == null:
		push_error("Map shell editor scene missing: " + SCENE)
		return
	_root = packed.instantiate() as Control
	if _root == null:
		push_error("Map shell editor scene root is not Control: " + SCENE)
		return
	_root.name = _plugin_name
	_ms = get_editor_interface().get_editor_main_screen()
	if _ms == null:
		push_error("Map shell editor: no editor main screen")
		_root.queue_free()
		_root = null
		return
	_ms.add_child(_root)
	_ms.resized.connect(_sync_size)
	_root.visible = false
	_sync_size.call_deferred()
	_build_dock()

	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--map-shell-shot="):
			_shot_to.call_deferred(a.substr(18))
			return
	if "--map-shell-selftest" in args:
		_selftest.call_deferred()
		return
	if not ("--no-map-shell-open" in args):
		_open_tab.call_deferred()


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _root != null and _root.get_parent() != null:
		_root.get_parent().remove_child(_root)
		_root.queue_free()
	_root = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	if _plugin_name.is_empty():
		_plugin_name = _read_name()
	return _plugin_name if not _plugin_name.is_empty() else "Map Shell Editor"


func _get_plugin_icon() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(2, 14):
		for x in range(2, 14):
			img.set_pixel(x, y, Color("#12161F"))
	for x in range(2, 14):
		img.set_pixel(x, 3, Color("#C8A34D"))
	img.set_pixel(5, 8, Color("#45D6A2"))
	img.set_pixel(6, 9, Color("#45D6A2"))
	img.set_pixel(9, 7, Color("#4EA1FF"))
	img.set_pixel(10, 8, Color("#4EA1FF"))
	return ImageTexture.create_from_image(img)


func _make_visible(visible: bool) -> void:
	if _root != null:
		_root.visible = visible
		if visible:
			_sync_size()


func _sync_size() -> void:
	if _root == null or _ms == null:
		return
	_root.position = Vector2.ZERO
	_root.size = _ms.size


func _read_name() -> String:
	var cf := ConfigFile.new()
	if cf.load(CFG) == OK:
		return String(cf.get_value("plugin", "name", "Map Shell Editor"))
	return "Map Shell Editor"


func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "MapShellTools"
	_dock.add_theme_constant_override("separation", 4)
	var title := Label.new()
	title.text = ShellText.t("shell.dock.title")
	title.add_theme_font_override("font", ThemeKit.bold_font())
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", ShellTheme.LEGACY_GOLD_HI)
	_dock.add_child(title)
	for id in TOOLS:
		var b := Button.new()
		b.text = ShellText.t("shell.tool." + id)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_dock_tool.bind(id))
		_dock.add_child(b)
	var save := Button.new()
	save.text = ShellText.t("shell.dock.save")
	save.alignment = HORIZONTAL_ALIGNMENT_LEFT
	save.add_theme_font_size_override("font_size", 12)
	save.pressed.connect(_dock_save)
	_dock.add_child(save)
	var hint := Label.new()
	hint.text = ShellText.t("shell.dock.hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", ShellTheme.TEXT_DIM)
	_dock.add_child(hint)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _dock_tool(id: String) -> void:
	_open_tab()
	if _root != null:
		_root.call("_show_tool", id)


func _dock_save() -> void:
	if _root != null:
		_root.call("_save")


func _open_tab() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(6):
		await get_tree().process_frame
	for _i in range(18):
		await get_tree().process_frame
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	if _root != null:
		_root.visible = true
		_sync_size()


func _find(n: Node, target: String) -> Node:
	if n.name == target:
		return n
	for c in n.get_children():
		var h := _find(c, target)
		if h != null:
			return h
	return null


func _selftest() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var problems: Array[String] = []
	if _root == null:
		problems.append("root")
	for n in ["shell_tool_terrain", "shell_tool_decor", "shell_tool_spine", "shell_tool_platform",
			"shell_viewport", "shell_picker", "shell_layout_preview"]:
		if _root == null or _find(_root, n) == null:
			problems.append(n)
	# 四个工具面板各自的关键控件（切一次工具就重建一次检查器）
	var probes := {
		"terrain": ["shell_brush_raise", "shell_layer_0", "shell_brush_surface"],
		"decor": ["shell_decor_tree", "shell_decor_fence"],
		"spine": ["shell_spine_width", "shell_divider_player_zone_end"],
		"platform": ["shell_add_platform", "shell_platform_1", "shell_role_keep"],
	}
	for tool_id in probes.keys():
		if _root == null:
			break
		_root.call("_show_tool", String(tool_id))
		await get_tree().process_frame
		for n in (probes[tool_id] as Array):
			if _find(_root, String(n)) == null:
				problems.append(String(tool_id) + ":" + String(n))
	print("[MapShell] selftest=", "PASS" if problems.is_empty() else "FAIL " + str(problems))
	get_tree().quit(0 if problems.is_empty() else 1)


func _shot_to(path: String) -> void:
	await get_tree().process_frame
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(40):
		await get_tree().process_frame
	_sync_size()
	var vp: Viewport = get_viewport()
	var img: Image = vp.get_texture().get_image() if vp != null else null
	if img != null:
		var err := img.save_png(path)
		print("[MapShell] shot ", path, " err=", err, " size=", img.get_size())
	else:
		print("[MapShell] shot failed: no viewport image")
	await get_tree().process_frame
	get_tree().quit()
