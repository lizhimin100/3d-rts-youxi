@tool
extends EditorPlugin
## 战争原岛开发者编辑器 · Godot 主屏插件
##
## 为什么要有它：Screens/scenes/dev_editor.tscn 是运行时场景，
## 但策划真正会打开的是 Godot 编辑器。这里把同一个场景嵌进编辑器主屏，
## 顶部页签就叫「战争原岛开发者编辑器」，不再显示旧 RTS 地图编辑器。
##
## 旧 addons/map_editor 默认禁用（project.godot 的 editor_plugins 只列本插件）；
## 需要地形地图编辑时，手动在「项目设置 → 插件」里重新启用它。

const SCENE := "res://Screens/scenes/dev_editor.tscn"
const CFG := "res://addons/war_island_editor/plugin.cfg"

var _root: Control = null
var _ms: Control = null
var _plugin_name := ""


func _enter_tree() -> void:
	_plugin_name = _read_name()
	var packed: PackedScene = load(SCENE)
	if packed == null:
		push_error("War Island editor scene missing: " + SCENE)
		return
	_root = packed.instantiate() as Control
	if _root == null:
		push_error("War Island editor scene root is not Control: " + SCENE)
		return
	# 主屏按 Control 的 name 索引；让它和插件页签名一致，set_main_screen_editor 才找得到
	_root.name = _plugin_name
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ms = get_editor_interface().get_editor_main_screen()
	_ms.add_child(_root)
	_ms.resized.connect(_sync_size)
	_root.visible = false
	_sync_size.call_deferred()

	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--dev-editor-shot="):
			_shot_to.call_deferred(a.substr(18))
			return
	if "--dev-editor-selftest" in args:
		_selftest.call_deferred()
		return
	if not ("--no-dev-editor-open" in args):
		_open_tab.call_deferred()


func _exit_tree() -> void:
	if _root != null and _root.get_parent() != null:
		_root.get_parent().remove_child(_root)
		_root.queue_free()
	_root = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	if _plugin_name.is_empty():
		_plugin_name = _read_name()
	if _plugin_name.is_empty():
		return "War Island Editor"
	return _plugin_name


func _get_plugin_icon() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(2, 14):
		for x in range(2, 14):
			img.set_pixel(x, y, Color("#1B2230"))
	for x in range(2, 14):
		img.set_pixel(x, 2, Color("#4EA1FF"))
		img.set_pixel(x, 13, Color("#2B3548"))
	for y in range(3, 13):
		img.set_pixel(2, y, Color("#4EA1FF"))
		img.set_pixel(13, y, Color("#2B3548"))
	for i in range(3):
		img.set_pixel(5 + i, 5 + i, Color("#F0B95A"))
		img.set_pixel(6 + i, 5 + i, Color("#F0B95A"))
	for i in range(3):
		img.set_pixel(10, 8 + i, Color("#45D6A2"))
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
		var n := String(cf.get_value("plugin", "name", "War Island Editor"))
		if not n.is_empty():
			return n
	return "War Island Editor"


func _open_tab() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(6):
		await get_tree().process_frame
	# 编辑器恢复上次布局时可能晚一拍把主屏切回去，稳定后再切一次。
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
	for n in ["page_units", "page_build", "page_layouts", "page_encounters", "page_assembly"]:
		if _root == null or _find(_root, n) == null:
			problems.append(n)
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(10):
		await get_tree().process_frame
	if _root != null:
		print("[DevEditor] root=", _root.get_class(), " size=", _root.size, " ms=", _ms.size if _ms != null else Vector2.ZERO,
			" pages=", _find(_root, "page_units") != null,
			_find(_root, "page_build") != null, _find(_root, "page_assembly") != null)
	print("[DevEditor] selftest=", "PASS" if problems.is_empty() else "FAIL " + str(problems))
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
		print("[DevEditor] shot ", path, " err=", err, " size=", img.get_size())
	else:
		print("[DevEditor] shot failed: no viewport image")
	await get_tree().process_frame
	get_tree().quit()
