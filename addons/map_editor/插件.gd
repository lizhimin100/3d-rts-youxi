@tool
extends EditorPlugin
## **地图编辑器插件入口**。
##
## 只做三件事：
##   1. 造一个 编辑会话（数据 + 撤销栈 + 笔刷状态）；
##   2. 往编辑器主屏塞一个「地图」页签（3D 视口在那儿，不在 Dock 里憋着）；
##   3. 往右侧 Dock 塞工具面板（笔刷 / 对象 / 属性 / 关卡 / 校验）。
##
## 明确不做：触发器编辑器、副官编辑器、UI 编辑器、模型导入 UI、运行时编辑器。

const SESSION_SCRIPT := "res://addons/map_editor/编辑会话.gd"
const MAIN_SCRIPT := "res://addons/map_editor/主屏.gd"
const DOCK_SCRIPT := "res://addons/map_editor/停靠面板.gd"

var _session = null
var _main: Control = null
var _dock: Control = null


func _enter_tree() -> void:
	_session = load(SESSION_SCRIPT).new()
	_session.setup(self)
	# 不再自动垫图：主屏会先弹「新建地图」向导（和魔兽一样，先问尺寸/人数/种子）

	_main = load(MAIN_SCRIPT).new()
	_main.setup(_session)
	_main.visible = false
	get_editor_interface().get_editor_main_screen().add_child(_main)

	_dock = load(DOCK_SCRIPT).new()
	_dock.setup(_session)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
	_session.dock = _dock

	# 开发自检：godot --headless --editor --quit -- --map-editor-selftest
	# 走一遍"刷地形 → 撤销 → 重做 → 放对象 → 撤销 → 存盘 → 读回 → 校验"，
	# 验证 EditorUndoRedoManager 那条链是真的通（编辑器里点按钮才会走到这里）。
	if "--map-editor-selftest" in OS.get_cmdline_user_args():
		_run_selftest.call_deferred()
	# 涂抹自检：专门验"地表笔刷/高度笔刷点下去到底改了没有"
	# godot --editor --path . -- --map-editor-paint-qa
	if "--map-editor-paint-qa" in OS.get_cmdline_user_args():
		_run_paint_qa.call_deferred()
	var args_now: PackedStringArray = OS.get_cmdline_user_args()
	var want_open: bool = "--map-editor-open" in args_now
	var want_shot: bool = false
	for a in args_now:
		if a.begins_with("--map-editor-shot="):
			want_shot = true
	if want_open:
		_open_tab.call_deferred()
	if want_shot:
		for a in args_now:
			if a.begins_with("--map-editor-shot="):
				_shot_to.call_deferred(a.substr(18))
	if not want_open and not want_shot:
		_first_dock_hint.call_deferred()


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _main != null and _main.get_parent() != null:
		_main.get_parent().remove_child(_main)
		_main.queue_free()
		_main = null
	_session = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "地图编辑器"


## 页签图标：自己画一个 16×16 的小地图格子，别让编辑器塞默认大 Logo
func _get_plugin_icon() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(1, 15):
		for x in range(1, 15):
			img.set_pixel(x, y, Color(0.16, 0.18, 0.22))
	for i in range(3, 14, 4):
		for y in range(2, 14):
			img.set_pixel(i, y, Color(0.42, 0.48, 0.56))
	for j in range(3, 14, 4):
		for x in range(2, 14):
			img.set_pixel(x, j, Color(0.42, 0.48, 0.56))
	for y in range(8, 13):
		for x in range(4, 8):
			img.set_pixel(x, y, Color(0.34, 0.66, 0.32))
	for i in range(3):
		img.set_pixel(9 + i, 7 - i, Color(0.88, 0.74, 0.34))
		img.set_pixel(10 + i, 7 - i, Color(0.88, 0.74, 0.34))
		img.set_pixel(10 + i, 8 - i, Color(0.70, 0.56, 0.24))
	return ImageTexture.create_from_image(img)



func _make_visible(visible: bool) -> void:
	if _main != null:
		_main.visible = visible


## 编辑器顶部主屏按钮点进来时，如果还没有地图就自动生成一张
func _handles(object: Object) -> bool:
	return false


## 开发用：等界面稳定后把编辑器窗口截一张图（不依赖窗口是否在最前）
func _shot_to(path: String) -> void:
	# 窗口被别的程序挡住时，Godot 会降频甚至不渲染，截到的是旧帧；
	# 先等两帧让窗口真的建好，再临时置顶 + 拉前台，截完就退出（只在开发参数下走）。
	await get_tree().process_frame
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
		DisplayServer.window_move_to_foreground()
	# 切到「地图编辑器」主屏再截 —— 否则截到的是打开着的脚本编辑器（切屏要留几帧才生效）
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(5):
		await get_tree().process_frame
	_open_dock()
	if "--map-editor-shot-demo" in OS.get_cmdline_user_args():
		_session.new_map(160, 2, 20261024)
		await get_tree().process_frame
		if _session.dock != null:
			_session.dock.show_tab("地形")
	# QA：--map-editor-shot-map=<tres> 直接开一张真实地图
	# （用来验收"主场景地图放进编辑器能不能看见泥路"）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-map="):
			var mp: String = a.get_slice("=", 1)
			var ok_open: bool = _session.open_path(mp)
			print("[地图编辑器] QA 打开 %s → %s" % [mp, "成功" if ok_open else "失败"])
			await get_tree().process_frame
			await get_tree().process_frame
	# QA：--map-editor-shot-zoo 新建一张图，把"新加的单位/建筑"各摆一个
	# （验收口径：编辑器里能不能看见它们、长得对不对 —— 野怪/营火都在这一排里）
	if "--map-editor-shot-zoo" in OS.get_cmdline_user_args():
		_session.new_map(160, 2, 20261024)
		if _session.dock != null:
			_session.dock.show_tab("对象")
		await get_tree().process_frame
		_session.place_owner = -1
		var zoo: Array = [
			[&"gnoll_warrior", 0, Vector2(-13.0, -2.0)],
			[&"gnoll_scout", 0, Vector2(-8.0, -2.0)],
			[&"footman", 0, Vector2(-13.0, 4.0)],
			[&"archer", 0, Vector2(-8.0, 4.0)],
			[&"campfire", 1, Vector2(-1.0, 0.0)],
			[&"watchtower", 1, Vector2(7.0, 6.0)],
		]
		for z in zoo:
			var zid: StringName = z[0]
			var zcat: int = int(z[1])
			var zp: Vector2 = z[2]
			var zy: float = _session.def.height_at(zp.x, zp.y) if _session.def != null else 0.0
			_session.add_object(zid, zcat, Vector3(zp.x, zy, zp.y))
			# ⚠ 这里**不能**调 Cfg.unit()：编辑器里 Cfg 是占位实例（配置入口.gd 不是 @tool），
			#   一调就 "Attempt to call a method on a placeholder instance"，整个截图流程卡死。
			#   要模型路径就问 MapAssets（@tool，静态）。
			var zinfo: Dictionary = MapAssets.find(zid)
			print("[地图编辑器] QA zoo：%s（模型 %s）" % [String(zid),
				String(zinfo.get("model", "?"))])
		await get_tree().process_frame
		await get_tree().process_frame
	# QA：--map-editor-shot-paint=dirt|raise 在镜头中心刷一笔
	# 用来肉眼验收"刷地形到底有没有反应"（数据 + 视口两边都要看）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-paint=") and _session.def != null:
			var kind: String = a.get_slice("=", 1)
			var d1: MapDef = _session.def
			var pp := Vector3(0.0, d1.height_at(0.0, 0.0), 0.0)
			if kind == "dirt":
				_session.set_tool(5)          # Tool.PAINT_DIRT
				_session.brush_radius = 10.0  # 用**默认半径**测：这一档最容易被 8m 格点漏掉
			elif kind == "grass":
				_session.set_tool(4)          # Tool.PAINT_GRASS
				_session.brush_radius = 10.0
			else:
				_session.set_tool(0)          # Tool.RAISE
				_session.brush_radius = 16.0
				_session.brush_strength = 2.4
			_session.begin_stroke(pp)
			for _i in range(14):
				_session.stroke_to(pp, 0.08)
				await get_tree().process_frame
			_session.end_stroke()
			var dirt_n: int = 0
			for v in d1.mat_nodes:
				if int(v) > 127:
					dirt_n += 1
			print("[地图编辑器] QA 刷 %s：泥格 %d / %d ｜ 高度 %.2f" % [
				kind, dirt_n, d1.mat_nodes.size(), d1.height_at(0.0, 0.0)])
			for _i in range(30):
				await get_tree().process_frame
	# QA：--map-editor-shot-cat=unit|build|doodad|res 切放置分类
	# （ASCII 参数：中文参数在 Windows 命令行里会被代码页搞坏，验收时不可靠）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-cat="):
			match a.get_slice("=", 1):
				"unit":
					_session.set_category(MapObject.Category.UNIT)
				"build":
					_session.set_category(MapObject.Category.BUILDING)
				"doodad":
					_session.set_category(MapObject.Category.DOODAD)
				"res":
					_session.set_category(MapObject.Category.RESOURCE)
	# QA：--map-editor-shot-tab=对象 / 装饰 / 历史 ...
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-tab=") and _session.dock != null:
			_session.dock.show_tab(a.substr(22))
	# QA：历史面板 demo：先刷一笔地形 + 摆一棵树，让 Tree 有内容
	if "--map-editor-shot-history-demo" in OS.get_cmdline_user_args() and _session.def != null:
		var d0: MapDef = _session.def
		var probe := Vector3(10.0, d0.height_at(10.0, 10.0), 10.0)
		_session.set_tool(0)
		_session.brush_radius = 12.0
		_session.begin_stroke(probe)
		for i in range(6):
			_session.stroke_to(probe, 0.08)
		_session.end_stroke()
		_session.add_object(&"tree", MapObject.Category.RESOURCE, probe)
		await get_tree().process_frame

	# QA：--map-editor-shot-save=<tres 路径> 把 demo 建的图存下来（接着能直接跑游戏验收）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-save=") and _session.def != null:
			var dst: String = a.get_slice("=", 1)
			var serr: int = MapStore.save_tres(_session.def, dst)
			print("[地图编辑器] 已保存 QA 地图 %s err=%d" % [dst, serr])
	# QA：--map-editor-shot-select=1 选中第 1 座建筑（用来看归属卡长什么样）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-select=") and _session.def != null:
			var want: int = int(a.get_slice("=", 1))
			var seen: int = 0
			for o in _session.def.objects:
				if o == null or int(o.category) != MapObject.Category.BUILDING:
					continue
				seen += 1
				if seen >= want:
					_session.select_only(o)
					break
	# QA：--map-editor-shot-wizard 让新建向导留在画面上（看属性面板长什么样）
	if "--map-editor-shot-wizard" in OS.get_cmdline_user_args() and _main != null:
		if _main.has_method("_show_wizard"):
			_main.call("_show_wizard")
	# QA：--map-editor-shot-cat=装饰 / 单位 / 建筑 / 资源
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-cat="):
			var cat_name: String = a.substr(22)
			match cat_name:
				"单位":
					_session.set_category(MapObject.Category.UNIT)
				"建筑":
					_session.set_category(MapObject.Category.BUILDING)
				"装饰":
					_session.set_category(MapObject.Category.DOODAD)
				"资源":
					_session.set_category(MapObject.Category.RESOURCE)
		if _session.viewport != null:
			_session.viewport.reset_camera()
	await get_tree().process_frame
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(10):
		await get_tree().process_frame
	# QA：--map-editor-shot-cam=<x>,<z>,<距离> 把编辑器镜头压到指定位置
	# （必须在 reset_camera() 之后执行，否则会被复位覆盖 —— 这就是第一次拍特写失败的原因）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-cam=") and _session.def != null \
				and _session.viewport != null:
			var parts: PackedStringArray = a.get_slice("=", 1).split(",")
			var cx: float = float(parts[0]) if parts.size() > 0 else 0.0
			var cz: float = float(parts[1]) if parts.size() > 1 else 0.0
			var cd: float = float(parts[2]) if parts.size() > 2 else 30.0
			_session.viewport.focus_on(Vector3(cx, _session.def.height_at(cx, cz), cz))
			# zoom_by 是"相对倍率"，先复位再算：dist 目标 / 当前
			var cur: float = float(_session.def.size) * 0.95
			_session.viewport.zoom_by(clampf(cd / maxf(cur, 1.0), 0.02, 4.0))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map-editor-shot-focus-player=") and _session.def != null:
			var pi: int = int(a.get_slice("=", 1)) - 1
			if pi >= 0 and pi < _session.def.players.size() and _session.viewport != null:
				var pp: PlayerSlot = _session.def.players[pi]
				_session.viewport.focus_on(Vector3(pp.start_pos.x,
					_session.def.height_at(pp.start_pos.x, pp.start_pos.y), pp.start_pos.y))
	_open_dock()
	await get_tree().process_frame
	# 编辑器恢复上次布局时会晚一拍把主屏切回脚本编辑器，所以**截图前再切一次**
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(30):
		await get_tree().process_frame
	var vp: Viewport = get_viewport()
	var img: Image = vp.get_texture().get_image() if vp != null else null
	if img != null:
		var err: int = img.save_png(path)
		print("[地图编辑器] 截图 %s err=%d size=%s" % [path, err, str(img.get_size())])
	else:
		print("[地图编辑器] 截图失败：拿不到视口图像")
	await get_tree().process_frame
	get_tree().quit()


## 第一次装插件时把 Dock 亮出来一次（只做一次，记在编辑器项目元数据里）
func _first_dock_hint() -> void:
	await get_tree().process_frame
	var es: EditorSettings = get_editor_interface().get_editor_settings()
	if es == null:
		return
	if bool(es.get_project_metadata("map_editor", "dock_hinted", false)):
		return
	es.set_project_metadata("map_editor", "dock_hinted", true)
	_open_dock()


## 把「地图工具」Dock 页签切到前台（首次进插件时也调用一次，免得用户找不到工具在哪）
func _open_dock() -> void:
	if _dock == null:
		return
	var ed: Node = _dock.get_parent()
	if ed == null:
		return
	# 编辑器里每个 Dock 页签是一个 EditorDock，挂在 SideDockTabContainer 上；
	# 想让它显示，得把槽位容器的当前页切过去（不是简单 show()）。
	var slot: Node = ed.get_parent()
	if slot is TabContainer:
		var tc := slot as TabContainer
		var idx: int = tc.get_tab_idx_from_control(ed)
		if idx >= 0:
			tc.current_tab = idx
			return
	if ed.has_method("open"):
		ed.call("open")


## 启动后直接切到「地图编辑器」页签（--map-editor-open）
func _open_tab() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	for _i in range(4):
		await get_tree().process_frame
	_open_dock()


# ===========================================================================
# 开发自检（只在显式传参时跑）
# ===========================================================================

func _run_selftest() -> void:
	await get_tree().process_frame
	var fails: PackedStringArray = PackedStringArray()
	var passes: int = 0
	print("========== 编辑器链路自检 ==========")

	# Dock 布局断言：页签 7 页（地形/对象/区域/玩家/属性/校验/历史）、真的撑开了
	# （不是被挤成一条 47px 的缝）
	_open_dock()
	for _i in range(4):
		await get_tree().process_frame
	var first: Control = _dock.get_current_tab_control()
	var dock_size: Vector2 = _dock.size
	var slot: Node = _dock.get_parent().get_parent()
	var slot_ok: bool = false
	if slot is TabContainer:
		var tc := slot as TabContainer
		slot_ok = tc.current_tab == tc.get_tab_idx_from_control(_dock.get_parent())
		print("  · Dock 是否在前台：%s（current_tab=%d）" % [str(slot_ok), tc.current_tab])
	if not slot_ok:
		fails.append("Dock 页签没切到前台")
	print("  · Dock：%s ｜ %d 页 ｜ 当前页尺寸 %s" % [str(dock_size), _dock.get_tab_count(),
		str(first.size if first != null else Vector2.ZERO)])
	if _dock.get_tab_count() == 7 and dock_size.y > 200.0 and dock_size.x > 200.0:
		passes += 1
	else:
		fails.append("Dock 尺寸/页数不对（%s，%d 页，应为 7）" % [str(dock_size), _dock.get_tab_count()])

	# token → Theme 资源：主屏与 Dock 必须真的挂上同一个 .tres（不是空 Theme）
	var main_theme: Theme = _main.theme
	var dock_theme: Theme = _dock.theme
	if main_theme != null and dock_theme != null and main_theme.resource_path.ends_with("编辑器主题.tres"):
		passes += 1
		print("  · 编辑器主题：%s（Tree/ItemList/Button 已入主题）" % main_theme.resource_path)
	else:
		fails.append("编辑器 Theme 资源没挂上（main=%s dock=%s）" % [str(main_theme), str(dock_theme)])

	# 撤销历史面板：必须是编辑器自带的 Tree，而不是自制列表控件
	var hist: Tree = _dock.get("_history_tree") as Tree
	if hist != null and _dock.has_method("_refresh_history"):
		passes += 1
		print("  · 撤销历史面板：Tree（%d 列）" % hist.columns)
	else:
		fails.append("撤销历史面板不是 Tree / 没建出来")

	# 装饰目录：只能有自然物，绝不能混进单位/建筑
	var doodads: Array = MapAssets.of_category(MapObject.Category.DOODAD)
	var banned: PackedStringArray = PackedStringArray()
	var units: Dictionary = UnitTable.build_units()
	for a in doodads:
		var aid := String(a.get("id", ""))
		var d: UnitDef = units.get(StringName(aid), null)
		if d != null:
			banned.append(aid)
		if not MapAssets.is_natural_id(aid):
			banned.append(aid + "(不在自然白名单/目录)")
	if not banned.is_empty():
		fails.append("装饰目录混入非自然物：%s" % ", ".join(banned))
	else:
		passes += 1
		print("  · 装饰目录：%d 项，全部来自自然白名单/目录，无单位/建筑" % doodads.size())

	_session.new_map(160, 2, 20261024)
	if _session.def == null:
		fails.append("new_map 没产出数据")
		_finish_selftest(passes, fails)
		return
	var d: MapDef = _session.def
	passes += 1

	# --- 笔刷 → 撤销 → 重做 ---
	var probe := Vector3(10.0, d.height_at(10.0, 10.0), 10.0)
	var h0: float = d.height_at(probe.x, probe.z)
	_session.tool = 0
	_session.brush_radius = 12.0
	_session.brush_strength = 2.0
	_session.begin_stroke(probe)
	for i in range(10):
		_session.stroke_to(probe, 0.08)
	_session.end_stroke()
	var h1: float = d.height_at(probe.x, probe.z)
	if h1 - h0 > 0.5:
		passes += 1
		print("  · 抬升笔刷：%.2f → %.2f m" % [h0, h1])
	else:
		fails.append("抬升笔刷没生效（%.2f → %.2f）" % [h0, h1])

	_session.undo()
	var h2: float = d.height_at(probe.x, probe.z)
	if absf(h2 - h0) < 0.01:
		passes += 1
		print("  · 撤销回到笔刷前：%.2f m" % h2)
	else:
		fails.append("撤销没把地形恢复（期望 %.2f，实际 %.2f）" % [h0, h2])

	_session.redo()
	var h3: float = d.height_at(probe.x, probe.z)
	if absf(h3 - h1) < 0.01:
		passes += 1
		print("  · 重做回到笔刷后：%.2f m" % h3)
	else:
		fails.append("重做没把地形改回去（期望 %.2f，实际 %.2f）" % [h1, h3])

	# --- 历史面板：Tree 数据源 = 编辑器自带 UndoRedo；点一条能跳到那一步 ---
	var hi: Dictionary = _session.history_info()
	if int(hi.get("count", 0)) >= 1 and int(hi.get("current", -99)) >= 0:
		passes += 1
		print("  · 历史栈：%d 步 · 当前 %d · 名称「%s」" % [int(hi.count), int(hi.current),
			String((hi.names as PackedStringArray)[0]) if (hi.names as PackedStringArray).size() > 0 else ""])
	else:
		fails.append("历史栈没记录地形笔刷（%s）" % str(hi))
	_session.jump_history(-1)
	var hj0: float = d.height_at(probe.x, probe.z)
	_session.jump_history(int(hi.get("current", 0)))
	var hj1: float = d.height_at(probe.x, probe.z)
	if absf(hj0 - h0) < 0.01 and absf(hj1 - h1) < 0.01:
		passes += 1
		print("  · 历史跳转：跳初始 %.2f / 跳回 %.2f" % [hj0, hj1])
	else:
		fails.append("历史跳转不对（初始 %.2f，跳回 %.2f；期望 %.2f / %.2f）"
			% [hj0, hj1, h0, h1])
	if _dock != null:
		_dock.call("_refresh_history")
		passes += 1

	# --- 建筑网格：编辑器侧吸附幂等 + 90° 朝向 ---
	var bfp := Vector2i(6, 6)
	var rawp := Vector3(3.37, 0.0, -7.81)
	var sp: Vector3 = _session.snap_building_pos(rawp, bfp)
	var sp2: Vector3 = _session.snap_building_pos(sp, bfp)
	var aligned: bool = 建筑网格.is_snapped(sp, bfp, d.half_size(), 建筑网格.CELL) \
		and absf(sp.x - sp2.x) < 0.0001 and absf(sp.z - sp2.z) < 0.0001
	if aligned:
		passes += 1
		print("  · 建筑网格：任意点 → (%.1f, %.1f) 整格锚点，幂等" % [sp.x, sp.z])
	else:
		fails.append("建筑网格吸附不对/不幂等（%.2f, %.2f）" % [sp.x, sp.z])
	var oyaw: float = 建筑网格.snap_yaw(0.77)
	if 建筑网格.yaw_is_snapped(oyaw):
		passes += 1
		print("  · 建筑朝向：0.77 rad → %.0f°（90° 档）" % rad_to_deg(oyaw))
	else:
		fails.append("建筑朝向没吸到 90° 档（%f）" % oyaw)

	# --- 放对象 → 撤销 ---
	var n0: int = d.objects.size()
	var near_spawn: Vector2 = d.players[0].start_pos + Vector2(0.0, -26.0)
	_session.add_object(&"tree", MapObject.Category.RESOURCE,
		Vector3(near_spawn.x, 0.0, near_spawn.y))
	var n1: int = d.objects.size()
	if n1 == n0 + 1:
		passes += 1
	else:
		fails.append("放对象没进数组（%d → %d）" % [n0, n1])
	_session.undo()
	var n2: int = d.objects.size()
	if n2 == n0:
		passes += 1
		print("  · 放对象 + 撤销：%d → %d → %d" % [n0, n1, n2])
	else:
		fails.append("撤销没删掉刚放的对象（%d → %d）" % [n0, n2])

	# --- 摆放归属（先选玩家再摆）：place_owner 必须真的写进 MapObject.owner ---
	# 这条以前一直是坏的：add_object 把 owner 写死成 1，摆谁都是"玩家 2 的兵"。
	var want_owner: int = 1 if d.players.size() > 1 else 0
	_session.set_place_owner(want_owner)
	var unit_obj: MapObject = _session.add_object(&"footman",
		MapObject.Category.UNIT, Vector3(near_spawn.x + 3.0, 0.0, near_spawn.y + 3.0))
	if unit_obj != null and unit_obj.owner == want_owner:
		passes += 1
		print("  · 摆放归属：选中玩家 %d → 放下的兵 owner=%d" % [want_owner + 1, unit_obj.owner])
	else:
		fails.append("摆放归属没生效（owner=%s，应为 %d）" % [
			str(unit_obj.owner) if unit_obj != null else "null", want_owner])
	# 装饰/资源永远中立
	var doodad_obj: MapObject = _session.add_object(&"tree",
		MapObject.Category.RESOURCE, Vector3(near_spawn.x - 3.0, 0.0, near_spawn.y - 3.0))
	if doodad_obj != null and doodad_obj.owner == -1:
		passes += 1
		print("  · 摆放归属：资源保持中立（owner=-1）")
	else:
		fails.append("资源被染上归属了（owner=%s）" % (str(doodad_obj.owner) if doodad_obj != null else "null"))
	# 中立白名单（MapAssets.allows_neutral）：**野怪必须能中立放下**，
	# 普通兵/建筑必须不能（否则中立步兵那种没有阵营的坏数据会进地图文件）。
	# 2026-11-01 玩家口径："野怪我自己在编辑器里摆" —— 摆下来必须还是野怪，
	# 不能被染成"玩家 1 的免费军队"。
	_session.set_place_owner(-1)
	if MapAssets.allows_neutral(&"gnoll_warrior") and not MapAssets.allows_neutral(&"footman"):
		passes += 1
		print("  · 摆放归属：野怪可中立 / 普通兵不可中立")
	else:
		fails.append("中立白名单不对（野怪应放行、普通兵应拦下）")
	# 真的摆一只，确认 owner 保持 -1（add_object 的夹取逻辑别把它改回 0）
	var creep_obj: MapObject = _session.add_object(&"gnoll_warrior",
		MapObject.Category.UNIT, Vector3(near_spawn.x + 6.0, 0.0, near_spawn.y + 6.0))
	if creep_obj != null and creep_obj.owner == -1:
		passes += 1
		print("  · 摆放归属：摆下来的野怪 owner=-1（进图归中立阵营）")
	else:
		fails.append("野怪被染上归属了（owner=%s，应为 -1）" % (
			str(creep_obj.owner) if creep_obj != null else "null"))
	_session.delete_selection()
	_session.set_place_owner(0)

	# --- 队伍：一键排队伍（各自为战）必须真的改到 PlayerSlot.team ---
	var solo_ok: bool = true
	_session.set_team_layout("solo")
	for i in d.players.size():
		if int(d.players[i].team) != i + 1:
			solo_ok = false
	if solo_ok:
		passes += 1
		print("  · 队伍预设（各自为战）：%s" % _session.team_summary())
	else:
		fails.append("队伍预设没生效：%s" % _session.team_summary())
	_session.set_team_layout("all")
	if d.players.size() > 0 and int(d.players[0].team) == 1:
		passes += 1
		print("  · 队伍预设（全同盟）：%s" % _session.team_summary())
	else:
		fails.append("队伍全同盟没生效")
	_session.undo()
	_session.undo()

	# --- 存盘 → 读回 ---
	# 存到项目内的「地图」文件夹（不再写 C 盘 user://），顺便验证 res:// 可写可读
	var tmp := "res://地图/_编辑器链路自检.tres"
	if _session.save_as(tmp):
		var back: MapDef = MapStore.load_tres(tmp)
		if back != null and back.objects.size() == d.objects.size() \
				and back.heightmap.size() == d.heightmap.size():
			passes += 1
			print("  · 存盘 → 读回：%d 对象 / %d 格高度" % [back.objects.size(), back.heightmap.size()])
		else:
			fails.append("存盘读回数据不一致")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	else:
		fails.append("save_as 失败")

	# --- 校验 ---
	var v: Dictionary = _session.validate()
	if bool(v.get("ok", false)):
		passes += 1
		print("  · 校验：0 错误")
	else:
		fails.append("干净地图校验有错误：" + str(v.get("errors", PackedStringArray())))

	_finish_selftest(passes, fails)


func _finish_selftest(passes: int, fails: PackedStringArray) -> void:
	if fails.is_empty():
		print("编辑器链路自检：全部通过（%d 项）" % passes)
	else:
		print("编辑器链路自检：%d 项失败" % fails.size())
		for f in fails:
			print("  ✘ ", f)
	await get_tree().process_frame
	get_tree().quit(0 if fails.is_empty() else 1)


## 涂抹自检：地表笔刷（泥土/草丛）与高度笔刷到底改没改数据、视口跟没跟上。
## 用户报"编辑器无法刷地形"时先跑这个，它会把每一步的数值打出来。
func _run_paint_qa() -> void:
	await get_tree().process_frame
	get_editor_interface().set_main_screen_editor(_get_plugin_name())
	# 等主屏真的切过去（切屏是异步的，不等就会拍到/测到"视口不可见 → 不重建"）
	for _i in range(120):
		await get_tree().process_frame
		if _main != null and _main.visible:
			break
	print("  · 主屏可见：%s ｜ 视口可见：%s" % [
		str(_main != null and _main.visible),
		str(_session.viewport != null and _session.viewport.is_visible_in_tree())])
	_open_dock()
	_session.new_map(160, 2, 20261024)
	for _i in range(6):
		await get_tree().process_frame
	var d: MapDef = _session.def
	if d == null:
		print("[涂抹QA] 没有地图，退出")
		get_tree().quit(1)
		return
	print("========== 涂抹自检 ==========")
	print("  · 地图：%d m ｜ mat_cells=%d ｜ nodes=%d ｜ splat=%d ｜ biome=%s" % [
		d.size, d.mat_cells, d.mat_nodes.size(), d.splatmap.size(), d.biome])
	var terrain: RtsTerrain = _session.viewport.terrain if _session.viewport != null else null
	print("  · 视口地形：%s ｜ mat_cells=%d ｜ biome=%s ｜ mat_map=%s" % [
		"有" if terrain != null else "无",
		terrain.mat_cells if terrain != null else -1,
		terrain.biome if terrain != null else "?",
		"有" if terrain != null and terrain.mat_map != null else "无"])

	var probe := Vector3(0.0, d.height_at(0.0, 0.0), 0.0)

	# --- 1) 高度笔刷 ---
	var h0: float = d.height_at(probe.x, probe.z)
	_session.tool = 0
	_session.brush_radius = 12.0
	_session.brush_strength = 2.0
	_session.begin_stroke(probe)
	for i in range(10):
		_session.stroke_to(probe, 0.08)
	_session.end_stroke()
	for _i in range(24):
		await get_tree().process_frame
	var vp_h: float = terrain.height_at(probe.x, probe.z) if terrain != null else -999.0
	print("  · 抬升：%.3f → %.3f m ｜ 视口地形高度 %.3f" % [h0, d.height_at(probe.x, probe.z), vp_h])
	if terrain != null and absf(vp_h - d.height_at(probe.x, probe.z)) > 0.05:
		var v = _session.viewport
		print("    ! 视口没跟上：visible=%s process=%s dirty_terrain=%s painting=%s built=%s" % [
			str(v.is_visible_in_tree()), str(v.is_processing()), str(v._dirty_terrain),
			str(v._painting), str(v._built_once)])
		v.rebuild_terrain()
		for _i in range(3):
			await get_tree().process_frame
		print("    ! 直接调 rebuild_terrain() 后视口高度 %.3f" % terrain.height_at(probe.x, probe.z))

	# --- 2) 泥土笔刷（写 mat_nodes）---
	# 探针落在一个**当前是草**的格点上：这样"泥格数变化"就是笔刷真干活的证据
	var grass_pt: Vector3 = _first_grass_point(d)
	var dirt0: int = _count_dirt(d)
	_session.tool = 5          # Tool.PAINT_DIRT
	_session.brush_radius = 10.0   # 默认半径（8m 格点最容易在这里落空）
	_session.begin_stroke(grass_pt)
	for i in range(4):
		_session.stroke_to(grass_pt, 0.08)
	_session.end_stroke()
	for _i in range(24):
		await get_tree().process_frame
	var dirt1: int = _count_dirt(d)
	print("  · 泥土笔刷：泥格 %d → %d（共 %d 格，占 %.1f%%）" % [
		dirt0, dirt1, d.mat_nodes.size(),
		100.0 * float(dirt1) / maxf(1.0, float(d.mat_nodes.size()))])

	# --- 3) 草丛笔刷（擦回草）---
	_session.tool = 4          # Tool.PAINT_GRASS
	_session.begin_stroke(grass_pt)
	for i in range(4):
		_session.stroke_to(grass_pt, 0.08)
	_session.end_stroke()
	for _i in range(24):
		await get_tree().process_frame
	var dirt2: int = _count_dirt(d)
	print("  · 草丛笔刷：泥格 %d → %d" % [dirt1, dirt2])

	var ok: bool = dirt1 > dirt0 and dirt2 < dirt1
	print("  · 结论：%s" % ("地表笔刷正常" if ok else "★地表笔刷没生效"))
	print("========== 涂抹自检结束 ==========")
	await get_tree().process_frame
	get_tree().quit(0 if ok else 1)


## 找一个"当前是草"的地块格点，返回它的世界坐标（当笔刷落点用）
func _first_grass_point(d: MapDef) -> Vector3:
	var n: int = d.mat_cells + 1
	if n < 2:
		return Vector3(0.0, d.height_at(0.0, 0.0), 0.0)
	var step: float = float(d.size) / float(d.mat_cells)
	var half: float = d.half_size()
	# 从中心往外螺旋找，命中草地就返回
	for j in range(n / 2, n):
		for i in range(n / 2, n):
			if int(d.mat_nodes[j * n + i]) <= 127:
				var x: float = -half + float(i) * step
				var z: float = -half + float(j) * step
				return Vector3(x, d.height_at(x, z), z)
	return Vector3(0.0, d.height_at(0.0, 0.0), 0.0)


func _count_dirt(d: MapDef) -> int:
	var n: int = 0
	for v in d.mat_nodes:
		if int(v) > 127:
			n += 1
	return n