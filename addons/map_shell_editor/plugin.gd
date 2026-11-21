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
const ShellStore := preload("res://Screens/editor/shell_store.gd")

const TOOLS := ["terrain", "decor", "spine", "tile"]

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
			_shot_to.call_deferred(a.substr("--map-shell-shot=".length()))
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
	for n in ["shell_tool_terrain", "shell_tool_decor", "shell_tool_spine", "shell_tool_tile",
			"shell_viewport", "shell_picker", "shell_layout_preview",
			"shell_region_player", "shell_region_neutral", "shell_region_enemy", "shell_undo"]:
		if _root == null or _find(_root, n) == null:
			problems.append(n)
	# 四个工具面板各自的关键控件（切一次工具就重建一次检查器）
	var probes := {
		"terrain": ["shell_brush_raise", "shell_layer_0", "shell_brush_surface"],
		"decor": ["shell_decor_tree", "shell_decor_fence"],
		"spine": ["shell_spine_width"],
		"tile": ["shell_add_tile", "shell_tile_1", "shell_role_keep"],
	}
	for tool_id in probes.keys():
		if _root == null:
			break
		_root.call("_show_tool", String(tool_id))
		await get_tree().process_frame
		for n in (probes[tool_id] as Array):
			if _find(_root, String(n)) == null:
				problems.append(String(tool_id) + ":" + String(n))
	# ── 镜头口径 + 地形材质：直接喂事件给真实的 handle_input，不是看源码猜 ──
	var view = null
	if _root != null:
		view = _find(_root, "ShellView")
	if view == null:
		problems.append("ShellView")
	else:
		view.call("reset_camera")
		if not is_equal_approx(float(view.get("cam_pitch")), -50.0):
			problems.append("cam-pitch")
		if not is_equal_approx(float(view.get("cam_dist")), 90.0):
			problems.append("cam-dist")
		# 地形必须挂游戏里那一份 地形.gdshader（不是自绘顶点色）
		var mesh = view.get("terrain_mesh")
		var mat = mesh.material_override if mesh != null else null
		if not (mat is ShaderMaterial):
			problems.append("terrain-material")
		elif (mat as ShaderMaterial).shader == null \
				or (mat as ShaderMaterial).get_shader_parameter("mat_map") == null \
				or (mat as ShaderMaterial).get_shader_parameter("tile_m") == null:
			# mat_map / tile_m 是 地形.gdshader 独有的 uniform：有它们就是游戏那份材质
			problems.append("terrain-shader")
		elif (mat as ShaderMaterial).get_shader_parameter("atlas_rgba") == null:
			problems.append("terrain-atlas")
		# 右键拖动 = 平移（方向与旧编辑器一致）
		var t0: Vector3 = view.get("cam_target")
		var rmb := InputEventMouseButton.new()
		rmb.button_index = MOUSE_BUTTON_RIGHT
		rmb.pressed = true
		rmb.position = Vector2(240, 180)
		view.call("handle_input", rmb, rmb.position)
		var pan := InputEventMouseMotion.new()
		pan.relative = Vector2(48.0, 30.0)
		pan.position = Vector2(288, 210)
		view.call("handle_input", pan, pan.position)
		var rmb_up := InputEventMouseButton.new()
		rmb_up.button_index = MOUSE_BUTTON_RIGHT
		rmb_up.pressed = false
		rmb_up.position = pan.position
		view.call("handle_input", rmb_up, rmb_up.position)
		var t_after: Vector3 = view.get("cam_target")
		if t_after.distance_to(t0) < 0.01:
			problems.append("rmb-pan")
		# 滚轮 = 乘性缩放（旧编辑器 ×0.88）
		var d0 := float(view.get("cam_dist"))
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		view.call("handle_input", wheel, Vector2(240, 180))
		if not is_equal_approx(float(view.get("cam_dist")), clampf(d0 * 0.88, 12.0, 200.0)):
			problems.append("wheel-zoom")
		# 中键拖动 = 旋转
		var yaw0 := float(view.get("cam_yaw"))
		var mmb := InputEventMouseButton.new()
		mmb.button_index = MOUSE_BUTTON_MIDDLE
		mmb.pressed = true
		view.call("handle_input", mmb, Vector2(240, 180))
		var orbit := InputEventMouseMotion.new()
		orbit.relative = Vector2(40.0, 0.0)
		view.call("handle_input", orbit, Vector2(280, 180))
		mmb = InputEventMouseButton.new()
		mmb.button_index = MOUSE_BUTTON_MIDDLE
		mmb.pressed = false
		view.call("handle_input", mmb, Vector2(280, 180))
		if absf(float(view.get("cam_yaw")) - yaw0) < 0.5:
			problems.append("mmb-orbit")
		view.call("reset_camera")
		# ── 战术格子 / 区域 / 选中圈 / 装饰资产：直接问运行时对象，不看源码猜 ──
		var tiles_root = view.get("tiles_root")
		if tiles_root == null or tiles_root.get_child_count() == 0:
			problems.append("tiles-empty")
		var regions_root = view.get("regions_root")
		if regions_root == null or regions_root.get_child_count() < 3:
			problems.append("regions<3")
		# 装饰必须是真实资产场景（子树里有 MeshInstance3D），不是占位盒子
		var decor_root = view.get("decor_root")
		if decor_root != null and decor_root.get_child_count() > 0:
			var dn = decor_root.get_child(0)
			if _count_meshes(dn) == 0:
				problems.append("decor-no-mesh")
		# 选中第一个格子 → 脚下必须出现选中圈
		view.call("select_tile", 1)
		await get_tree().process_frame
		var sel_root = view.get("selection_root")
		if sel_root == null or sel_root.get_child_count() == 0:
			problems.append("selection-ring")
		# 框选：在视口里从左上方拖到右下方，必须选中 >= 2 个格子（合成鼠标事件，真走 handle_input）
		view.call("reset_camera")
		view.call("clear_selection")
		var box_a := Vector2(30.0, 30.0)
		var box_b := Vector2(880.0, 620.0)
		var bd := InputEventMouseButton.new()
		bd.button_index = MOUSE_BUTTON_LEFT
		bd.pressed = true
		bd.position = box_a
		view.call("handle_input", bd, box_a)
		var bm := InputEventMouseMotion.new()
		bm.position = box_b
		bm.relative = box_b - box_a
		view.call("handle_input", bm, box_b)
		var bu := InputEventMouseButton.new()
		bu.button_index = MOUSE_BUTTON_LEFT
		bu.pressed = false
		bu.position = box_b
		view.call("handle_input", bu, box_b)
		var box_sel: Array = view.get("selected_tiles")
		if box_sel.size() < 2:
			problems.append("box-select=%d" % box_sel.size())
		# 拖动：选中 1 号格子，从它的屏幕位置往右下拖 40px，数据必须变且贴合地形
		view.call("select_tile", 1)
		var sh1: Dictionary = view.get("shell")
		var td1 := ShellStore.tile_by_index(sh1, 1)
		var drag_px: Vector2 = view.call("_screen_of", Vector3(float(td1.get("x", 0.0)), float(td1.get("terrain_y", 0.0)) + 0.3, float(td1.get("z", 0.0))))
		var drag_from := Vector2(float(td1.get("x", 0.0)), float(td1.get("z", 0.0)))
		var dd := InputEventMouseButton.new()
		dd.button_index = MOUSE_BUTTON_LEFT
		dd.pressed = true
		dd.position = drag_px
		view.call("handle_input", dd, drag_px)
		var dm := InputEventMouseMotion.new()
		dm.position = drag_px + Vector2(40.0, 30.0)
		dm.relative = Vector2(40.0, 30.0)
		view.call("handle_input", dm, dm.position)
		var du := InputEventMouseButton.new()
		du.button_index = MOUSE_BUTTON_LEFT
		du.pressed = false
		du.position = dm.position
		view.call("handle_input", du, dm.position)
		var td1b := ShellStore.tile_by_index(view.get("shell"), 1)
		var drag_to := Vector2(float(td1b.get("x", 0.0)), float(td1b.get("z", 0.0)))
		if drag_to.distance_to(drag_from) < 0.1:
			problems.append("tile-drag")
		elif absf(float(td1b.get("terrain_y", 0.0)) - float(view.call("_h", drag_to.x, drag_to.y))) > 0.02:
			problems.append("tile-drag-snap")

		# Delete + Ctrl+Z：删一个格子，撤销要能原样回来
		var before_n: int = (view.get("shell").get("tiles", []) as Array).size()
		var del := InputEventKey.new()
		del.keycode = KEY_DELETE
		del.pressed = true
		view.call("handle_input", del, Vector2.ZERO)
		var after_n: int = (view.get("shell").get("tiles", []) as Array).size()
		var undo := InputEventKey.new()
		undo.keycode = KEY_Z
		undo.ctrl_pressed = true
		undo.pressed = true
		view.call("handle_input", undo, Vector2.ZERO)
		var undo_n: int = (view.get("shell").get("tiles", []) as Array).size()
		if after_n != before_n - 1 or undo_n != before_n:
			problems.append("delete-undo %d/%d/%d" % [before_n, after_n, undo_n])

		# 区域绘制状态机：进 → 两个顶点 → 取消（不够 3 个不能闭合）
		view.call("begin_region", "neutral")
		view.call("add_region_vertex", Vector3.ZERO, Vector2(100, 100))
		view.call("add_region_vertex", Vector3(1, 0, 0), Vector2(120, 100))
		var errs: Array = view.call("finish_region")
		if (errs as Array).is_empty():
			problems.append("region-need3")
		view.call("cancel_region")
	print("[MapShell] selftest=", "PASS" if problems.is_empty() else "FAIL " + str(problems))
	get_tree().quit(0 if problems.is_empty() else 1)


func _count_meshes(n: Node) -> int:
	var count := 1 if n is MeshInstance3D else 0
	for c in n.get_children():
		count += _count_meshes(c)
	return count


func _shot_to(path: String) -> void:
	await get_tree().process_frame
	# 编辑器主屏列表在插件 _enter_tree 时还没建好，单次 set_main_screen_editor 会静默失败。
	# 走和 _open_tab 同一条「切两次 + 留帧」的路，切过去了再截。
	await _open_tab()
	for _i in range(20):
		await get_tree().process_frame
	# 验收用：--map-shell-select=N 选中一个格子（看脚下选中圈与两个锚点标记）
	var sel := -1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-shell-select="):
			sel = int(a.substr("--map-shell-select=".length()))
	if sel >= 0:
		var view := _find(_root, "ShellView") if _root != null else null
		if view != null:
			view.call("select_tile", sel)
			view.call("focus_selected")
			for _j in range(8):
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
