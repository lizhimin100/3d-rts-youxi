@tool
extends VBoxContainer
## **地图编辑器主屏**（仿魔兽世界编辑器的「地形编辑器」窗口）
##
##   ┌ 菜单栏：文件 / 编辑 / 视图 / 地图 ────────────────────────┐
##   ├ 快捷条：新建 打开 保存 ｜ 撤销 重做 历史 ｜ 校验 测试地图 ┤
##   │ ┌─┬───────────────────────────────────────────────┐ │
##   │ │工│                                               │ │
##   │ │具│              3D 地图编辑区                     │ │
##   │ │栏│   （左上角显示当前工具，底部常驻操作提示）        │ │
##   │ └─┴───────────────────────────────────────────────┘ │
##   └ 状态栏：地图 · 坐标 · 当前工具 · 校验 ──────────────────┘
##
## 主题：设计 token 编译成 addons/map_editor/编辑器主题.tres，整屏只挂一次；
## 动效（向导/状态提示切换）统一走 Tween，不写逐帧动画。
##
## 工具面板（地形/单位/建筑/装饰/资源/区域）在右侧 Dock 里，左边这条是"层"切换，
## 和魔兽一样：点哪个层，右边就是哪个面板，鼠标左键就干哪个层的事。

const VIEWPORT_SCRIPT := "res://addons/map_editor/视口.gd"
## 全套设计令牌（配色/字号/样式工厂）——编辑器只用 editor_ 那一档冷色
const Spec := preload("res://代码/界面/界面规格.gd")
## token 编译出来的正经 Theme 资源（生成命令见 工具/生成编辑器主题.gd）
const EDITOR_THEME := preload("res://addons/map_editor/编辑器主题.tres")

const MODE_TERRAIN := 0
const MODE_OBJECT := 1
const MODE_REGION := 2

var session = null
var viewport = null

var _menu_file: MenuButton
var _menu_edit: MenuButton
var _menu_view: MenuButton
var _menu_map: MenuButton
var _tool_badge: Label
var _rail: VBoxContainer
var _rail_buttons: Dictionary = {}
var _hand_button: Button = null
var _map_label: Label
var _coord_label: Label
var _tool_label: Label
var _val_label: Label
var _overlay_tool: Label
var _overlay_hint: Label
var _overlay_map: Label
var _wizard: PanelContainer
var _w_size: OptionButton
var _w_players: OptionButton
var _w_biome: OptionButton
var _w_relief: OptionButton
var _w_swatch: PanelContainer
var _w_seed: SpinBox
var _open_dialog: EditorFileDialog
var _save_dialog: EditorFileDialog
var _grid_on: bool = true
var _regions_on: bool = true
var _tick: float = 0.0
## 向导是否"被用户点名要开"（新建地图…）。只有它为 true 时，
## 已有地图也允许向导留在屏幕上。
var _wizard_wanted: bool = false
var _wizard_dirty: bool = true
## 向导/状态栏的 Tween（全编辑器统一走 Tween，不自造动画框架）
var _wizard_tween: Tween = null
var _status_tween: Tween = null


func setup(p_session) -> void:
	session = p_session
	_build()
	_wire()
	if session != null:
		# 视口必须拿到会话（漏了这句 = 永远不建地形）
		viewport.setup(session)
		session.viewport = viewport
	_refresh_rail()
	_refresh_status()
	if session != null and session.def != null:
		_hide_wizard()
	else:
		_show_wizard()


# ===========================================================================
# 布局
# ===========================================================================

func _build() -> void:
	name = "地图编辑器主屏"
	# 一次挂主题，所有子控件继承；不再每个按钮塞 StyleBoxOverride
	theme = EDITOR_THEME
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)

	_build_menu_and_quickbar()

	# --- 主体：左侧工具层 + 3D 视口 ---
	var body := Control.new()
	body.name = "主体"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.custom_minimum_size = Vector2(0, 240)
	add_child(body)

	_rail = VBoxContainer.new()
	_rail.name = "工具层"
	_rail.custom_minimum_size = Vector2(88, 0)
	_rail.add_theme_constant_override("separation", 4)
	body.add_child(_rail)
	_rail.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_rail.offset_right = 88

	viewport = load(VIEWPORT_SCRIPT).new()
	viewport.name = "编辑视口"
	body.add_child(viewport)
	viewport.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.offset_left = 88
	viewport.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_build_rail()

	# 视口里的常驻提示（不吃鼠标事件）
	var overlay := Control.new()
	overlay.name = "提示层"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.offset_left = 88

	_overlay_tool = _mk_badge(overlay, Vector2(10, 10))
	_overlay_tool.text = "地形 · 抬升"
	_overlay_map = _mk_overlay_label(overlay, Vector2(10, 42), false)
	_overlay_map.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_overlay_map.position = Vector2(-190, -34)
	_overlay_hint = _mk_overlay_label(overlay, Vector2(10, 0), false)
	_overlay_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_overlay_hint.position = Vector2(10, -32)
	_overlay_hint.text = "手型：左键拖动转视角、点对象选中　｜　中键拖：转视角　右键拖：平移　滚轮：缩放　H/Esc：收工具　｜　建筑放置：R 转 90°"

	_build_wizard(body)
	_build_statusbar()
	_build_dialogs()


func _build_menu_and_quickbar() -> void:
	var bar := HBoxContainer.new()
	bar.name = "菜单栏"
	bar.add_theme_constant_override("separation", 4)
	add_child(bar)

	_menu_file = _mk_menu(bar, "文件", [
		["新建地图…", 1], ["打开地图…", 2], ["保存", 3], ["另存为…", 4],
		["-", 0], ["测试地图（Test Map）", 5],
	])
	_menu_file.get_popup().about_to_popup.connect(_refresh_file_menu)
	_menu_edit = _mk_menu(bar, "编辑", [
		["撤销", 11], ["重做", 12], ["-", 0], ["编辑历史…", 17], ["-", 0],
		["复制", 13], ["粘贴", 14], ["删除选中", 15], ["随机朝向", 16],
	])
	_menu_view = _mk_menu(bar, "视图", [
		["俯视", 21], ["斜视", 22], ["复位镜头", 23], ["-", 0],
		["拉近", 24], ["拉远", 25], ["-", 0], ["显示网格", 26], ["显示区域", 27],
	])
	_menu_map = _mk_menu(bar, "地图", [
		["校验地图", 31], ["玩家 / 波次…", 32], ["区域面板…", 33],
	])

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.custom_minimum_size = Vector2(8, 0)
	bar.add_child(spacer)

	_tool_badge = Spec.editor_label("未打开地图", &"EditorAccent")
	bar.add_child(_tool_badge)

	var quick := HBoxContainer.new()
	quick.name = "快捷条"
	quick.add_theme_constant_override("separation", 4)
	add_child(quick)
	_qbtn(quick, "新建", "新建地图（先选尺寸/人数/种子）", 1)
	_qbtn(quick, "打开", "打开 .tres / .json", 2)
	_qbtn(quick, "保存", "保存", 3)
	_qbtn(quick, "另存为", "另存为", 4)
	quick.add_child(VSeparator.new())
	_qbtn(quick, "撤销", "撤销", 11)
	_qbtn(quick, "重做", "重做", 12)
	_qbtn(quick, "历史", "打开编辑历史（点一条跳回那一步）", 17)
	quick.add_child(VSeparator.new())
	_qbtn(quick, "校验", "跑 MapValidator", 31)
	_qbtn(quick, "测试地图", "保存临时地图并启动游戏（不阻塞编辑器）", 5)
	quick.add_child(VSeparator.new())
	_qbtn(quick, "俯视", "俯视", 21)
	_qbtn(quick, "斜视", "斜视", 22)
	_qbtn(quick, "复位", "复位镜头", 23)
	var hint := Spec.editor_label("　手型/工具二选一　・　拿工具前左键只转视角　・　右侧面板切工具",
		&"EditorHint")
	quick.add_child(hint)


func _mk_menu(parent: Node, title: String, items: Array) -> MenuButton:
	var m := MenuButton.new()
	m.text = title
	m.flat = true
	m.focus_mode = Control.FOCUS_NONE
	parent.add_child(m)
	var popup: PopupMenu = m.get_popup()
	for it in items:
		var text: String = String(it[0])
		var id: int = int(it[1])
		if text == "-":
			popup.add_separator()
		else:
			popup.add_item(text, id)
	popup.id_pressed.connect(_on_menu)
	return m


func _qbtn(parent: Node, text: String, tip: String, id: int) -> Button:
	var b := Spec.editor_button(text)
	b.tooltip_text = tip
	b.pressed.connect(func() -> void: _on_menu(id))
	parent.add_child(b)
	return b


## 左侧「层」工具栏：点哪个层，右边 Dock 就切到哪个面板
func _build_rail() -> void:
	# 手型放最上面：不拿工具时左键拖动 = 转视角，点对象能选中
	_hand_button = Spec.editor_tool_button("手型\n浏览",
		"不拿工具：左键按住拖动转视角，点对象选中（H / Esc）")
	_hand_button.custom_minimum_size = Vector2(80, 46)
	_hand_button.toggle_mode = true
	_hand_button.toggled.connect(func(on: bool) -> void:
		if on and session != null:
			session.disarm())
	_rail.add_child(_hand_button)
	_rail.add_child(HSeparator.new())
	_rail.add_child(_mk_layer_button("地形", MODE_TERRAIN, "地形", -1))
	_rail.add_child(_mk_layer_button("单位", MODE_OBJECT, "对象", MapObject.Category.UNIT))
	_rail.add_child(_mk_layer_button("建筑", MODE_OBJECT, "对象", MapObject.Category.BUILDING))
	_rail.add_child(_mk_layer_button("装饰", MODE_OBJECT, "对象", MapObject.Category.DOODAD))
	_rail.add_child(_mk_layer_button("资源", MODE_OBJECT, "对象", MapObject.Category.RESOURCE))
	_rail.add_child(_mk_layer_button("区域", MODE_REGION, "区域", -1))
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rail.add_child(sp)
	var vb := Spec.editor_tool_button("视角\n复位", "镜头回到地图中心（F 对准选中对象）")
	vb.custom_minimum_size = Vector2(80, 46)
	vb.pressed.connect(func() -> void: _on_menu(23))
	_rail.add_child(vb)


func _mk_layer_button(text: String, mode: int, dock_tab: String, cat: int) -> Button:
	var b := Spec.editor_tool_button(text)
	b.custom_minimum_size = Vector2(80, 46)
	b.toggle_mode = true
	b.pressed.connect(func() -> void: _on_layer(mode, dock_tab, cat))
	_rail_buttons[text] = b
	return b


func _build_wizard(parent: Control) -> void:
	_wizard = PanelContainer.new()
	_wizard.name = "新建向导"
	parent.add_child(_wizard)
	_wizard.set_anchors_preset(Control.PRESET_CENTER)
	_wizard.position = Vector2(-250, -200)
	_wizard.custom_minimum_size = Vector2(500, 0)

	_wizard.theme_type_variation = &"EditorDialog"

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_wizard.add_child(v)

	var title := Spec.editor_label("新建地图", &"EditorTitle")
	v.add_child(title)

	var sub := Spec.editor_label("尺寸 / 地形类型 / 地形高度 / 人数先定死，再开始画（和魔兽一样）。",
		&"EditorHint")
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(460, 0)
	v.add_child(sub)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 10)
	v.add_child(grid)

	# --- 地图大小：**九档**，从能打一场小规模遭遇战到四人大图 ---
	grid.add_child(_mk_label("地图大小"))
	_w_size = OptionButton.new()
	_w_size.tooltip_text = "边长（米）。越小越紧凑、开局接触越快；越大越适合多人拉锯。"
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 6)
	_w_size.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in [128, 144, 160, 192, 224, 256, 288, 320, 384]:
		_w_size.add_item("%d × %d 米" % [s, s])
		_w_size.set_item_metadata(_w_size.item_count - 1, s)
	_w_size.select(2)
	size_row.add_child(_w_size)
	grid.add_child(size_row)

	# --- 地形类型（生态）：决定地表色带，也就是"这个世界的草/土长什么样" ---
	grid.add_child(_mk_label("地形类型"))
	var biome_row := HBoxContainer.new()
	biome_row.add_theme_constant_override("separation", 6)
	_w_biome = OptionButton.new()
	_w_biome.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_w_biome.tooltip_text = "决定地表色带：草原偏黄绿、荒原偏赭黄、雪原偏冷蓝、火山偏焦黑赤红、沼泽偏墨绿。"
	for bid in MapDef.BIOME_ORDER:
		_w_biome.add_item(MapDef.biome_name(bid))
		_w_biome.set_item_metadata(_w_biome.item_count - 1, bid)
	_w_biome.item_selected.connect(func(_i: int) -> void: _sync_biome_swatch())
	biome_row.add_child(_w_biome)
	# 色带预览：三个色块横排，选什么一眼看到（不用点进去猜）
	_w_swatch = PanelContainer.new()
	_w_swatch.custom_minimum_size = Vector2(64, 18)
	_w_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_w_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	biome_row.add_child(_w_swatch)
	grid.add_child(biome_row)

	# --- 地形高度：随机起伏 / 纯平地，两个路子都给 ---
	grid.add_child(_mk_label("地形高度"))
	_w_relief = OptionButton.new()
	_w_relief.tooltip_text = "随机起伏 = 自然地形（带压平的出生营地）；纯平地 = 一键铺平，方便先摆建筑。"
	_w_relief.add_item("随机起伏（自然地形）")
	_w_relief.set_item_metadata(0, false)
	_w_relief.add_item("纯平地（空白底图）")
	_w_relief.set_item_metadata(1, true)
	_w_relief.select(0)
	grid.add_child(_w_relief)

	grid.add_child(_mk_label("玩家数"))
	_w_players = OptionButton.new()
	for n in [2, 3, 4, 6, 8, 12]:
		var layout_name: String = "对角" if n == 2 else ("正三角" if n == 3 else ("四角" if n == 4 else "圆周均布"))
		_w_players.add_item("%d 人（%s）" % [n, layout_name])
		_w_players.set_item_metadata(_w_players.item_count - 1, n)
	grid.add_child(_w_players)

	grid.add_child(_mk_label("随机种子"))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 6)
	_w_seed = SpinBox.new()
	_w_seed.min_value = 0
	_w_seed.max_value = 999999999
	_w_seed.step = 1
	_w_seed.value = 20261024
	_w_seed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srow.add_child(_w_seed)
	var rnd := Spec.editor_button("随机")
	rnd.focus_mode = Control.FOCUS_NONE
	rnd.pressed.connect(func() -> void: _w_seed.value = randi() % 100000000)
	srow.add_child(rnd)
	grid.add_child(srow)

	var note := Spec.editor_label("每个出生点标配：大本营 ×1 ｜ 兵营 ×1 ｜ 铁匠铺 ×1 ｜ 农场 ×2 ｜ 哨塔 ×3 ｜ 金矿 ×1（固定距离）｜ 树木 12~17 棵（固定半径）。",
		&"EditorHint")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(460, 0)
	v.add_child(note)

	var btn := Spec.editor_button("创建地图")
	btn.custom_minimum_size = Vector2(0, 40)
	btn.pressed.connect(func() -> void: _create_map())
	v.add_child(btn)

	_sync_biome_swatch()


## 地形类型色带预览：三块本色横向排开
func _sync_biome_swatch() -> void:
	if _w_swatch == null or _w_biome == null:
		return
	for c in _w_swatch.get_children():
		_w_swatch.remove_child(c)
		c.free()
	var bid: String = String(_w_biome.get_item_metadata(_w_biome.selected))
	var pal: Array = MapDef.biome_palette(bid)
	if pal.is_empty():
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	_w_swatch.add_child(row)
	for i in range(mini(3, pal.size())):
		var sw := ColorRect.new()
		sw.color = pal[i]
		sw.custom_minimum_size = Vector2(18, 18)
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(sw)


## 视口左上角的"当前工具"徽标（PanelContainer 才有背景）
func _mk_badge(parent: Control, pos: Vector2) -> Label:
	var pc := PanelContainer.new()
	pc.position = pos
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.theme_type_variation = &"EditorBadge"
	parent.add_child(pc)
	var l := Spec.editor_label("", &"EditorAccent")
	pc.add_child(l)
	return l


func _mk_overlay_label(parent: Control, pos: Vector2, badge: bool) -> Label:
	var l := Spec.editor_label("")
	l.position = pos
	l.add_theme_color_override("font_outline_color", Spec.editor_outline())
	l.add_theme_constant_override("outline_size", 4)
	parent.add_child(l)
	return l


func _build_statusbar() -> void:
	var bar := HBoxContainer.new()
	bar.name = "状态栏"
	bar.add_theme_constant_override("separation", 16)
	add_child(bar)
	_map_label = Spec.editor_label("未打开地图")
	bar.add_child(_map_label)
	_coord_label = Spec.editor_label("X —　Z —　高度 —", &"EditorHint")
	bar.add_child(_coord_label)
	_tool_label = Spec.editor_label("", &"EditorHint")
	bar.add_child(_tool_label)
	_val_label = Spec.editor_label("")
	_val_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(_val_label)


func _build_dialogs() -> void:
	_open_dialog = EditorFileDialog.new()
	_open_dialog.title = "打开地图"
	_open_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_open_dialog.current_dir = MapStore.default_dir()
	_open_dialog.add_filter("*.tres", "地图资源")
	_open_dialog.add_filter("*.json", "地图 JSON")
	_open_dialog.file_selected.connect(_on_open_selected)
	add_child(_open_dialog)

	_save_dialog = EditorFileDialog.new()
	_save_dialog.title = "另存地图"
	_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_save_dialog.current_dir = MapStore.default_dir()
	_save_dialog.add_filter("*.tres", "地图资源")
	_save_dialog.add_filter("*.json", "地图 JSON")
	_save_dialog.file_selected.connect(_on_save_selected)
	add_child(_save_dialog)


func _mk_label(t: String) -> Label:
	return Spec.editor_label(t)


# ===========================================================================
# 接线
# ===========================================================================

func _wire() -> void:
	if session == null:
		return
	session.status_changed.connect(_on_status)
	session.dirty_changed.connect(_refresh_status)
	session.map_loaded.connect(_on_map_loaded)
	session.validation_changed.connect(_on_validation)
	session.mode_changed.connect(func(_m: int) -> void: _refresh_rail())
	session.category_changed.connect(func(_c: int) -> void: _refresh_rail())
	if session.has_signal("tool_changed"):
		session.tool_changed.connect(_refresh_rail)
	session.selection_changed.connect(_refresh_status)
	if viewport != null:
		viewport.ground_changed.connect(_on_ground)


func _on_menu(id: int) -> void:
	if session == null:
		return
	if id >= 100:
		var list: PackedStringArray = MapStore.recent_list()
		var idx: int = id - 100
		if idx >= 0 and idx < list.size():
			if session.open_path(list[idx]):
				_hide_wizard()
				viewport.reset_camera()
		return
	match id:
		1:
			_show_wizard()
		2:
			_open_dialog.current_dir = MapStore.default_dir()
			_open_dialog.popup_centered_ratio(0.62)
		3:
			_do_save()
		4:
			_do_save_as()
		5:
			session.test_map()
		11:
			session.undo()
		12:
			session.redo()
		13:
			session.copy_selection()
		14:
			session.paste_clipboard()
		15:
			session.delete_selection()
		16:
			session.randomize_rotation()
		17:
			_focus_dock("历史")
		21:
			viewport.set_view_top()
		22:
			viewport.set_view_iso()
		23:
			viewport.reset_camera()
		24:
			viewport.zoom_by(0.8)
		25:
			viewport.zoom_by(1.25)
		26:
			_grid_on = not _grid_on
			viewport.set_grid_visible(_grid_on)
		27:
			_regions_on = not _regions_on
			viewport.set_regions_visible(_regions_on)
		31:
			var v: Dictionary = session.validate()
			var errs: PackedStringArray = v.get("errors", PackedStringArray())
			_on_status("校验：%d 错误 / %d 提醒（看右侧校验页）"
				% [errs.size(), (v.get("warnings", PackedStringArray()) as PackedStringArray).size()])
		32:
			_focus_dock("区域")
		33:
			_focus_dock("区域")


func _on_layer(mode: int, dock_tab: String, cat: int) -> void:
	if session == null:
		return
	if session.def == null:
		_show_wizard()
		return
	session.set_mode(mode)
	if mode == MODE_OBJECT and cat >= 0:
		session.set_category(cat)
	_focus_dock(dock_tab)
	_refresh_rail()


func _focus_dock(tab: String) -> void:
	if session != null and session.dock != null and session.dock.has_method("show_tab"):
		session.dock.call("show_tab", tab)


func _refresh_rail() -> void:
	if session == null:
		return
	var active: String = ""
	if not session.armed:
		# 手型状态：任何一个层都不高亮（一眼看出"现在没拿工具"）
		active = ""
	elif session.mode == MODE_TERRAIN:
		active = "地形"
	elif session.mode == MODE_REGION:
		active = "区域"
	elif session.mode == MODE_OBJECT:
		match int(session.asset_category):
			MapObject.Category.UNIT:
				active = "单位"
			MapObject.Category.BUILDING:
				active = "建筑"
			MapObject.Category.DOODAD:
				active = "装饰"
			MapObject.Category.RESOURCE:
				active = "资源"
	for key in _rail_buttons:
		var b: Button = _rail_buttons[key]
		b.button_pressed = (String(key) == active)
	if _hand_button != null:
		_hand_button.button_pressed = not session.armed
	_refresh_status()


# ===========================================================================
# 新建 / 打开 / 保存
# ===========================================================================

func _show_wizard() -> void:
	if _wizard == null:
		return
	_wizard_wanted = true
	if _wizard.visible and _wizard.modulate.a >= 0.99:
		return
	_wizard.visible = true
	_wizard.pivot_offset = _wizard.size * 0.5
	if _wizard_tween != null and _wizard_tween.is_valid():
		_wizard_tween.kill()
	_wizard.modulate.a = 0.0
	_wizard.scale = Vector2(0.96, 0.96)
	_wizard_tween = create_tween().set_parallel(true)
	_wizard_tween.tween_property(_wizard, "modulate:a", 1.0, 0.16) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_wizard_tween.tween_property(_wizard, "scale", Vector2.ONE, 0.20) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _hide_wizard() -> void:
	_wizard_wanted = false
	if _wizard == null or not _wizard.visible:
		return
	if _wizard_tween != null and _wizard_tween.is_valid():
		_wizard_tween.kill()
	_wizard_tween = create_tween().set_parallel(true)
	_wizard_tween.tween_property(_wizard, "modulate:a", 0.0, 0.12) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_wizard_tween.tween_property(_wizard, "scale", Vector2(0.98, 0.98), 0.12)
	_wizard_tween.chain().tween_callback(func() -> void: _wizard.visible = false)


func _create_map() -> void:
	if session == null:
		return
	var size: int = int(_w_size.get_item_metadata(_w_size.selected))
	var players: int = int(_w_players.get_item_metadata(_w_players.selected))
	var seed_value: int = int(_w_seed.value)
	var biome: String = String(_w_biome.get_item_metadata(_w_biome.selected)) \
		if _w_biome.selected >= 0 else "temperate"
	var flat: bool = bool(_w_relief.get_item_metadata(_w_relief.selected)) \
		if _w_relief.selected >= 0 else false
	# 再点一次新建 = 确认重开：先把旧图的交互残留清干净，再让会话换 def
	if viewport != null and viewport.has_method("reset_interaction_state"):
		viewport.reset_interaction_state()
	session.new_map(size, players, seed_value, flat,
		{"biome": biome, "flat": flat})
	_hide_wizard()
	if viewport != null:
		viewport.reset_camera()
	_refresh_rail()
	_on_status("已创建 %d×%d 地图（%s · %s）" % [size, size,
		MapDef.biome_name(biome), "平地" if flat else "随机地形"])


func _do_save() -> void:
	if session == null or session.def == null:
		_on_status("还没有地图，先新建一张")
		return
	if session.path.is_empty():
		_do_save_as()
		return
	session.save()


func _do_save_as() -> void:
	if session == null or session.def == null:
		return
	_save_dialog.current_dir = MapStore.default_dir()
	var suggested: String = session.path if not session.path.is_empty() else MapStore.suggest_path("新地图")
	_save_dialog.current_file = suggested.get_file()
	_save_dialog.popup_centered_ratio(0.62)


func _on_open_selected(path: String) -> void:
	if session.open_path(path):
		_hide_wizard()
		if viewport != null:
			viewport.reset_camera()


func _on_save_selected(path: String) -> void:
	if session.save_as(path):
		_hide_wizard()
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.scan()


## 「文件」菜单每次展开时刷新"最近地图"（id 100+）
func _refresh_file_menu() -> void:
	var popup: PopupMenu = _menu_file.get_popup()
	for i in range(popup.item_count - 1, -1, -1):
		if popup.get_item_id(i) >= 100:
			popup.remove_item(i)
	var list: PackedStringArray = MapStore.recent_list()
	popup.add_separator("最近地图")
	if list.is_empty():
		popup.add_item("（暂无）", 100)
		popup.set_item_disabled(popup.item_count - 1, true)
	else:
		for i in range(list.size()):
			popup.add_item(list[i].get_file(), 100 + i)
			popup.set_item_tooltip(popup.item_count - 1, list[i])


# ===========================================================================
# 状态刷新
# ===========================================================================

func _on_map_loaded() -> void:
	_hide_wizard()
	_refresh_status()


func _on_status(text: String) -> void:
	if _tool_label == null:
		return
	_tool_label.text = text
	# 状态一句话用 Tween 淡入：这是编辑器里唯一的"提示动效"。
	if _status_tween != null and _status_tween.is_valid():
		_status_tween.kill()
	_tool_label.modulate.a = 0.45
	_status_tween = create_tween()
	_status_tween.tween_property(_tool_label, "modulate:a", 1.0, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _on_ground(pos: Vector3, valid: bool) -> void:
	if _coord_label == null:
		return
	if not valid:
		_coord_label.text = "X —　Z —　高度 —"
		return
	_coord_label.text = "X %.1f　Z %.1f　高 %.2fm" % [pos.x, pos.z, pos.y]


func _on_validation(result: Dictionary) -> void:
	if _val_label == null:
		return
	var errs: PackedStringArray = result.get("errors", PackedStringArray())
	var warns: PackedStringArray = result.get("warnings", PackedStringArray())
	_val_label.text = "校验：%d 错误 / %d 提醒" % [errs.size(), warns.size()]
	_val_label.theme_type_variation = &"EditorOk" if errs.is_empty() else &"EditorBad"


func _refresh_status() -> void:
	if session == null:
		return
	var nm: String = session.path.get_file() if not session.path.is_empty() else "未命名地图"
	if _map_label != null:
		if session.def == null:
			_map_label.text = "未打开地图"
		else:
			_map_label.text = "%s ｜ %d×%d%s" % [nm, session.def.size, session.def.size,
				"  ●未保存" if session.dirty else ""]
	_tool_badge.text = _tool_text()
	if _overlay_tool != null:
		_overlay_tool.text = _tool_text()
	if _overlay_map != null:
		if session.def != null:
			_overlay_map.text = "%s ｜ %d×%d ｜ 对象 %d" % [nm, session.def.size, session.def.size,
				session.def.objects.size()]
		else:
			_overlay_map.text = ""


## 当前工具的一句话说明（状态栏 + 视口左上角徽标共用）
func _tool_text() -> String:
	if session == null or session.def == null:
		return "未打开地图"
	if session.has_method("tool_hint"):
		return String(session.tool_hint())
	var head: String = ""
	match int(session.mode):
		MODE_TERRAIN:
			head = "地形 · %s" % session.tool_name()
		MODE_OBJECT:
			head = "放置 · %s · %s" % [MapAssets.category_name(int(session.asset_category)),
				String(session.asset_id)]
		MODE_REGION:
			head = "区域 · %s" % RegionDef.shape_name_of(int(session.region_shape))
		_:
			head = "选择"
	if session.mode == MODE_TERRAIN:
		head += " ｜ 笔刷 %.0fm %s" % [session.brush_radius, "方形" if session.brush_square else "圆形"]
	return head


func _process(delta: float) -> void:
	if session == null:
		return
	# ★ 必须 has_method 探一下：编辑会话.gd 一旦编译失败（例如存盘写到一半被编辑器读到），
	#   脚本对象还在但方法全没了，直接调就会**每帧**刷一条
	#   "Invalid call. Nonexistent function 'autosave_tick'"，而且会一直循环。
	#   这里退化成"跳过自动保存"，至少不会把输出面板刷爆。
	if session.has_method("autosave_tick"):
		session.autosave_tick(delta)
	_tick += delta
	if _tick > 0.4:
		_tick = 0.0
		_refresh_status()
	if _wizard_dirty:
		_wizard_dirty = false
		_sync_wizard()


## 向导显隐：只认"用户点了新建 / 地图真的建好了 / 没地图"这三种事实，
## 绝不每帧强推 visible —— 之前就是每 0.4s 覆写 `visible = (def == null)`，
## 把刚弹出来的「新建地图」窗口在已有地图时立刻藏掉（蹦一下就没）。
func _sync_wizard() -> void:
	if _wizard == null:
		return
	if session.def == null:
		# 没地图 → 必须给入口
		if not _wizard.visible:
			_show_wizard()
		_wizard_wanted = false
	elif not _wizard_wanted and _wizard.visible:
		_hide_wizard()
