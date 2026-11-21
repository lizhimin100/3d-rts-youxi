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
var _dock_panel: Control = null
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
	if _dock_panel != null:
		remove_control_from_docks(_dock_panel)
		_dock_panel.queue_free()
		_dock_panel = null
	if _dock != null:
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


## 底部专用 Dock：**原生停靠面板**，不悬浮、不压场景树/属性栏。
## 内容由主屏脚本 build_control_dock 生成（三分组：地块与格子 / 多边形三区 / 地图尺寸），
## 这里只负责把它挂进 Dock —— 插件不做第二份 UI。
func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "MapShellTools"
	_dock.add_theme_constant_override("separation", 4)
	_dock_panel = PanelContainer.new()
	_dock_panel.name = "MapShellDock"
	_dock_panel.custom_minimum_size = Vector2(0.0, 300.0)
	_dock_panel.add_child(_dock)
	add_control_to_dock(DOCK_SLOT_BOTTOM, _dock_panel)
	if _root != null and _root.has_method("attach_control_dock"):
		_root.call("attach_control_dock", _dock)


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


## 控件既可能在主屏（视口/顶栏），也可能在底部 Dock（三分组操作面板）。
func _find_any(target: String) -> Node:
	var hit := _find(_root, target) if _root != null else null
	if hit != null:
		return hit
	if _dock != null:
		return _find(_dock, target)
	return null


func _selftest() -> void:
	# ★ 先把主屏切成 Map Shell：headless 编辑器里它默认不是当前主屏，
	#   底部 Dock 与主屏控件全是 hidden —— 不切的话"可见性"断言全部假红（2026-11-21 实测）。
	await _open_tab()
	await get_tree().process_frame
	var problems: Array[String] = []
	if _root == null:
		problems.append("root")
	for n in ["shell_tool_terrain", "shell_tool_decor", "shell_tool_spine", "shell_tool_tile",
			"shell_viewport", "shell_picker", "shell_layout_preview",
			"shell_region_player", "shell_region_neutral", "shell_region_enemy", "shell_undo",
			"shell_map_w", "shell_map_d", "shell_map_apply", "shell_map_grow"]:
		if _find_any(n) == null:
			problems.append(n)
	# 面板必须是**可见且没被裁掉**的（1080p 下三组都完整可见）
	#
	# ★ headless 编辑器里底部 Dock 没有真实布局（父容器整体 hidden），
	#   `is_visible_in_tree()` 恒为 false —— 那不是 UI 做错，是没窗口。
	#   所以"可见性"只在有窗口时断言；headless 下改断言"在树里 + 有尺寸 + 在 Dock 里"。
	var has_display: bool = DisplayServer.get_name() != "headless"
	if _dock == null or not _dock.is_inside_tree():
		problems.append("dock-missing")
	elif has_display and not _dock.is_visible_in_tree():
		problems.append("dock-hidden")
	else:
		var dock_rect := _dock.get_global_rect()
		for n in ["shell_tool_scroll", "shell_region_player", "shell_map_apply"]:
			var c := _find_any(n) as Control
			if c == null or not c.is_inside_tree() or c.size.x < 8.0 or c.size.y < 8.0:
				problems.append("dock-size:" + n)
			elif has_display and not dock_rect.encloses(c.get_global_rect()):
				problems.append("dock-clip:" + n)
	# 四个工具面板各自的关键控件（切一次工具就重建一次检查器）
	var probes := {
		"terrain": ["shell_brush_raise", "shell_layer_0", "shell_brush_surface"],
		"decor": ["shell_decor_tree", "shell_decor_fence"],
		"spine": ["shell_spine_width"],
		"tile": ["shell_add_tile", "shell_tile_1", "shell_role_keep", "shell_tile_snap_toggle",
			"shell_tile_snap_step", "shell_map_grow"],
	}
	for tool_id in probes.keys():
		if _root == null:
			break
		_root.call("_show_tool", String(tool_id))
		await get_tree().process_frame
		for n in (probes[tool_id] as Array):
			if _find_any(String(n)) == null:
				problems.append(String(tool_id) + ":" + String(n))
	# ── 水体：底壳里不许再有水面节点（水层字段等 view 取到以后再查）──
	if _find(_root, "Water") != null:
		problems.append("water-node")
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
		var shell_now: Dictionary = view.get("shell")
		if (shell_now.get("terrain", {}) as Dictionary).has("water_level"):
			problems.append("water-level-field")
		# 立体地块：顶面 + 侧壁 + 底面 = 3 个 surface；侧面材质必须存在
		var mesh_i = view.get("terrain_mesh")
		var tmesh: ArrayMesh = mesh_i.mesh if mesh_i != null else null
		if tmesh == null or tmesh.get_surface_count() < 3:
			problems.append("block-surfaces=%d" % (0 if tmesh == null else tmesh.get_surface_count()))
		else:
			var top_mat: Material = tmesh.surface_get_material(0)
			var side_mat: Material = tmesh.surface_get_material(1)
			if not (top_mat is ShaderMaterial):
				problems.append("terrain-material")
			elif (top_mat as ShaderMaterial).shader == null \
					or (top_mat as ShaderMaterial).get_shader_parameter("mat_map") == null \
					or (top_mat as ShaderMaterial).get_shader_parameter("tile_m") == null:
				# mat_map / tile_m 是 地形.gdshader 独有的 uniform：有它们就是游戏那份材质
				problems.append("terrain-shader")
			elif (top_mat as ShaderMaterial).get_shader_parameter("atlas_rgba") == null:
				problems.append("terrain-atlas")
			if side_mat == null:
				problems.append("block-side-material")
			elif String(side_mat.resource_path).is_empty():
				problems.append("block-side-not-tres")
		# 棋盘：A/B 两份独立 .tres，相邻格子必须取到不同的一份
		# 路径来自 Content/data/shell_board.json（源码保持 ASCII），所以这里也读表，不写死。
		var want_a := ShellStore.board_material_path("tile_a")
		var want_b := ShellStore.board_material_path("tile_b")
		var plate_paths := {}
		for c in (view.get("tiles_root") as Node).get_children():
			var pm := _find(c, "Plate") as MeshInstance3D
			if pm != null and pm.material_override != null:
				plate_paths[String(pm.material_override.resource_path)] = true
		if want_a.is_empty() or want_b.is_empty() or not plate_paths.has(want_a) \
				or not plate_paths.has(want_b) or want_a == want_b:
			problems.append("checker-materials=%s" % str(plate_paths.keys()))
		# 皮肤表：5 个槽位都得指向真实存在的 .tres
		var skin_errs: Array = ShellStore.board_table_errors()
		if not skin_errs.is_empty():
			problems.append("board-skin:%s" % str(skin_errs))
		# 画布冗余：必须严格大于地图（至少 40%）
		var canvas: Vector2 = ShellStore.canvas_size_of(shell_now)
		var map_size := ShellStore.size_of(shell_now)
		if canvas.x < map_size.x * 1.79 or canvas.y < map_size.y * 1.79:
			problems.append("canvas-margin=%.2fx%.2f" % [canvas.x / map_size.x, canvas.y / map_size.y])
		# 相机上限必须跟着画布长（扩容后还看得见冗余区）
		var dmax := float(view.call("dist_max"))
		if dmax < 199.0:
			problems.append("dist-max=%.0f" % dmax)
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
		if not is_equal_approx(float(view.get("cam_dist")), clampf(d0 * 0.88, 12.0, dmax)):
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

		# ── 真点底部 Dock 的「新增格子」：必须真的 +1（不是只看按钮存在）──
		var add_btn := _find_any("shell_add_tile") as Control
		if add_btn == null or not add_btn.is_inside_tree():
			problems.append("add-tile-button")
		elif not has_display:
			# headless：没有窗口就发不出真鼠标事件 → 退化成"发 pressed 信号"，
			# 仍然走同一个按钮回调（不是直接调 view.add_tile），加法与撤销都要验。
			var n0h: int = (view.get("shell").get("tiles", []) as Array).size()
			add_btn.emit_signal("pressed")
			await get_tree().process_frame
			var n1h: int = (view.get("shell").get("tiles", []) as Array).size()
			if n1h != n0h + 1:
				problems.append("add-tile-signal %d/%d" % [n0h, n1h])
			view.call("undo")
			if (view.get("shell").get("tiles", []) as Array).size() != n0h:
				problems.append("add-tile-undo-signal")
		else:
			var n0: int = (view.get("shell").get("tiles", []) as Array).size()
			var center := add_btn.get_global_rect().get_center()
			var mv := InputEventMouseMotion.new()
			mv.position = center
			mv.global_position = center
			get_viewport().push_input(mv, true)
			var dn := InputEventMouseButton.new()
			dn.button_index = MOUSE_BUTTON_LEFT
			dn.pressed = true
			dn.position = center
			dn.global_position = center
			get_viewport().push_input(dn, true)
			await get_tree().process_frame
			var up2: InputEventMouseButton = dn.duplicate()
			up2.pressed = false
			get_viewport().push_input(up2, true)
			await get_tree().process_frame
			await get_tree().process_frame
			var n1: int = (view.get("shell").get("tiles", []) as Array).size()
			if n1 != n0 + 1:
				problems.append("add-tile-click %d/%d" % [n0, n1])
			view.call("undo")
			var n2: int = (view.get("shell").get("tiles", []) as Array).size()
			if n2 != n0:
				problems.append("add-tile-undo %d/%d" % [n0, n2])

		# ── 地图扩容：尺寸 / 高度场 / 格子都按规则联动，撤销后原样回来 ──
		var before_size := ShellStore.size_of(view.get("shell"))
		var before_rows := int(ShellStore.grid_of(view.get("shell"))["rows"])
		var grow_errs: Array = view.call("resize_map", before_size.x + 30.0, before_size.y + 15.0, true)
		if not (grow_errs as Array).is_empty():
			problems.append("resize-map:" + str(grow_errs))
		else:
			var after_size := ShellStore.size_of(view.get("shell"))
			var after_rows := int(ShellStore.grid_of(view.get("shell"))["rows"])
			var hs: PackedFloat32Array = view.get("heights")
			if not is_equal_approx(after_size.x, before_size.x + 30.0) or after_rows <= before_rows:
				problems.append("resize-map-size")
			elif hs.size() != int(ShellStore.grid_of(view.get("shell"))["cols"]) * after_rows:
				problems.append("resize-map-heights=%d" % hs.size())
			view.call("undo")
			var back := ShellStore.size_of(view.get("shell"))
			if not is_equal_approx(back.x, before_size.x):
				problems.append("resize-map-undo")

		# ── 反向验错：冗余 < 40% 必须被 Model 拒绝 ──
		var bad_board: Array = view.call("set_board_value", "margin", 0.2)
		if (bad_board as Array).is_empty():
			problems.append("margin-guard")
		var good_board: Array = view.call("set_board_value", "margin", 0.45)
		if not (good_board as Array).is_empty():
			problems.append("margin-ok:" + str(good_board))

		# ── 对齐网格开关：关 → board.snap = 0；开 → 回到步长 ──
		view.call("set_snap_enabled", false)
		if float(ShellStore.board_of(view.get("shell"))["snap"]) > 0.0:
			problems.append("snap-off")
		view.call("set_snap_enabled", true, 1.0)
		if float(ShellStore.board_of(view.get("shell"))["snap"]) <= 0.0:
			problems.append("snap-on")
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
