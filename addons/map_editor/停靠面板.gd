@tool
extends TabContainer
## **地图工具面板（Dock）** —— 仿魔兽「工具面板」的八页：
##
##   地形   ：应用纹理（草/土/岩/沙）＋ 应用高度（抬升/降低/平滑/压平）＋ 水面 ＋ 刷子
##   对象   ：单位 / 建筑 / 装饰 / 资源 四个分类，装饰只收自然物并按子类筛选
##   区域   ：画圆/矩形/多边形 ＋ 用途 ＋ 玩家槽位 ＋ 波次
##   玩家   ：玩家槽位（阵营/颜色/队伍/出生点/初始资源）＋ 队伍预设
##   属性   ：选中对象的数据
##   营地   ：野怪营地卡（刷什么怪、几只、半径、补满时间），存回 代码/配置/卡/野怪营地/
##   校验   ：五关硬检查结果
##   历史   ：Tree 实现的撤销/重做面板（点一条直接跳步）
##
## 这里**不碰 3D**：改的是 编辑会话 的状态，视口去重建；数值回填统一用 _syncing 挡环路。

var session = null
var _syncing: bool = false
## 全套设计令牌（配色/字号/样式工厂）——这里只用 editor_ 那一档冷色
const Spec := preload("res://代码/界面/界面规格.gd")
## token 编译出来的正经 Theme 资源（主屏同源）
const EDITOR_THEME := preload("res://addons/map_editor/编辑器主题.tres")

# --- 地形页 ---
var _biome_opt: OptionButton
var _height_group: ButtonGroup
var _splat_group: ButtonGroup
var _height_buttons: Array[Button] = []
var _splat_buttons: Array[Button] = []
var _water_btn: Button
var _size_slider: HSlider
var _size_label: Label
var _shape_opt: OptionButton
var _strength: HSlider
var _strength_label: Label
var _snap: CheckBox

# --- 对象页 ---
var _cat_buttons: Dictionary = {}
var _asset_list: ItemList
var _group_row: HBoxContainer
var _group_opt: OptionButton
var _asset_search: LineEdit
var _empty_hint: Label
var _obj_count: Label
var _replace_opt: OptionButton
var _sel_buttons: Array[Button] = []
## 归属卡（对象页 + 属性页各一张）：[{value:Label, flow:HFlowContainer, pills:Array}]
var _owner_cards: Array = []

# --- 区域页 ---
var _shape_row: HBoxContainer
var _region_list: ItemList
var _region_id: LineEdit
var _region_purpose: OptionButton
var _player_opt: OptionButton
var _player_faction: OptionButton
## 阵营下拉的值（顺序 = _player_faction 的项序）
const FACTION_KEYS: Array[String] = ["player", "enemy", "neutral", "neutral_hostile"]
const FACTION_NAMES: Array[String] = ["己方（player）", "敌方（enemy）", "中立（neutral）", "中立敌对（neutral_hostile）"]
var _player_color: ColorPickerButton
var _player_team: SpinBox
var _player_x: SpinBox
var _player_z: SpinBox
var _player_yaw: SpinBox
var _player_gold: SpinBox
var _player_wood: SpinBox

# --- 玩家页 ---
## 队伍一览（"队伍 1：玩家1、玩家2 ｜ 队伍 2：玩家3"）
var _team_summary: Label
## 摆放归属药丸（对象页顶部：先选玩家，再选摆什么）
var _place_owner_row: HFlowContainer
var _place_pills: Array[Button] = []

var _wave_list: ItemList
var _wave_time: SpinBox
var _wave_diff: OptionButton
var _wave_comp: LineEdit
var _wave_spawn: OptionButton
var _wave_target: OptionButton

# --- 属性页 ---
var _prop_hint: Label
var _prop_box: VBoxContainer
var _pos_x: SpinBox
var _pos_z: SpinBox
var _rot_spin: SpinBox
var _scale_spin: SpinBox

# --- 校验页 ---
var _val_text: RichTextLabel
var _val_summary: Label

# --- 营地页 ---
## 营地卡目录 + 静态表（本工程惯例：不写 class_name，用 preload 常量调静态方法）
const CAMP_TABLE := preload("res://代码/配置/野怪营地表.gd")
## 营地定义脚本（新建时 .new() 一份空的 Resource）
const CAMP_DEF := preload("res://代码/配置/野怪营地定义.gd")
var _camp_list: ItemList
var _camp_name: LineEdit
var _camp_id: LineEdit
var _camp_den: OptionButton
var _camp_creep_list: ItemList
var _camp_count_box: VBoxContainer
var _camp_radius: SpinBox
var _camp_respawn: SpinBox
var _camp_icon: LineEdit
## 2026-11-07：归属 + 时间点
var _camp_owner: OptionButton
var _camp_first: SpinBox
var _camp_interval: SpinBox
var _camp_status: Label
## 当前正在编辑的营地 Resource（null = 还没选 / 刚删掉）
var _camp_cur: Resource = null
## 编辑中的野怪 id 与只数（界面上的"真相"，保存时才写回 Resource）
var _camp_creeps: Array = []
var _camp_counts: Array = []
## 刷新列表时要保住的那一行（按 .tres 路径比对，id 和文件名可能不一致）
var _camp_sel_path: String = ""

# --- 历史页（Tree：编辑器自带 UndoRedo 的可视化）---
var _history_tree: Tree
var _history_hint: Label


func setup(p_session) -> void:
	session = p_session
	_build()
	_wire()
	_sync_all()


func show_tab(title: String) -> void:
	for i in range(get_tab_count()):
		if get_tab_title(i) == title:
			current_tab = i
			return


## 营地弹窗保存后让「营地」页跟上（两处编辑同一份数据，不能一边新一边旧）。
## 列表按 .tres 路径保住当前行，所以玩家不会因为保存一次就被踢回第一行。
func refresh_camp_page() -> void:
	_refresh_camps()


## 单位卡 / 建筑卡改完之后让「对象」页跟上：
## 显示名、模型、成本都可能变了，不重扫的话列表还是旧名字。
func refresh_after_card_edit() -> void:
	_populate_assets()
	_refresh_camps()


# ===========================================================================
# 布局
# ===========================================================================

func _build() -> void:
	name = "地图工具"
	# 一次挂主题；按钮/页签/Tree/ItemList/输入框全部继承，控件上不再写样式
	theme = EDITOR_THEME
	custom_minimum_size = Vector2(330, 260)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_add_tab(_build_terrain_tab(), "地形")
	_add_tab(_build_object_tab(), "对象")
	_add_tab(_build_region_tab(), "区域")
	_add_tab(_build_player_tab(), "玩家")
	_add_tab(_build_prop_tab(), "属性")
	_add_tab(_build_camp_tab(), "营地")
	_add_tab(_build_validate_tab(), "校验")
	_add_tab(_build_history_tab(), "历史")
	tab_changed.connect(_on_tab_changed)


func _add_tab(content: Control, title: String) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	set_tab_title(get_tab_count() - 1, title)


func _vbox() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	return v


func _label(t: String, wrap: bool = false, variation: StringName = &"") -> Label:
	var l := Spec.editor_label(t, variation)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(276, 0)
	return l


func _title(t: String) -> Label:
	return Spec.editor_label(t, &"EditorTitle")


## 说明文本不再占版面：只挂 tooltip，鼠标停上去才出现。
## 用户明确要求"不要直接的说明文本，要弹出式"。
func _hint(node: Control, text: String) -> void:
	if node == null:
		return
	node.tooltip_text = text


func _hbox() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	return h


# ---------------------------------------------------------------- 地形页
func _build_terrain_tab() -> Control:
	var v := _vbox()

	# 地形类型 = 整张图的"草/土色带"。这一层是随机色块铺出来的底子，
	# 换它不需要重刷任何东西，整张图立刻换季。
	v.add_child(_title("地形类型（整张图的地表色带）"))
	_biome_opt = OptionButton.new()
	_biome_opt.tooltip_text = "草原偏黄绿 / 荒原偏赭黄 / 雪原偏冷蓝 / 火山偏焦黑赤红 / 沼泽偏墨绿"
	for bid in MapDef.BIOME_ORDER:
		_biome_opt.add_item(MapDef.biome_name(bid))
		_biome_opt.set_item_metadata(_biome_opt.item_count - 1, bid)
	_biome_opt.item_selected.connect(func(i: int) -> void:
		if not _syncing and session != null:
			session.set_biome(String(_biome_opt.get_item_metadata(i))))
	v.add_child(_biome_opt)
	v.add_child(HSeparator.new())

	v.add_child(_title("应用纹理（只改地表颜色，不改高度）"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	v.add_child(grid)
	_splat_group = ButtonGroup.new()
	_splat_buttons.clear()
	grid.add_child(_mk_color_tool("草地", MapDef.SPLAT_GRASS, Color(0.26, 0.48, 0.18), 4))
	grid.add_child(_mk_color_tool("泥土", MapDef.SPLAT_DIRT, Color(0.44, 0.32, 0.18), 5))
	grid.add_child(_mk_color_tool("岩石", MapDef.SPLAT_ROCK, Color(0.42, 0.43, 0.46), 6))
	grid.add_child(_mk_color_tool("沙地", MapDef.SPLAT_SAND, Color(0.72, 0.64, 0.42), 7))
	grid.add_child(_mk_plain_tool("擦除地表", 9))
	grid.add_child(_mk_plain_tool("水面", 8))

	v.add_child(HSeparator.new())
	v.add_child(_title("应用高度（只改起伏，不改地表）"))
	var hg := GridContainer.new()
	hg.columns = 2
	hg.add_theme_constant_override("h_separation", 4)
	hg.add_theme_constant_override("v_separation", 4)
	v.add_child(hg)
	_height_group = ButtonGroup.new()
	_height_buttons.clear()
	for entry in [["↑ 抬升", 0], ["↓ 降低", 1], ["≈ 平滑", 2], ["▭ 压平", 3]]:
		hg.add_child(_mk_height_tool(String(entry[0]), int(entry[1])))

	# 说明不占版面：挂 tooltip，鼠标停上去才出现
	_hint(_size_slider, "抬升/降低按住左键不放会持续改；纹理刷一遍就上色。")

	v.add_child(HSeparator.new())
	v.add_child(_title("刷子"))
	var srow := _hbox()
	_size_slider = HSlider.new()
	_size_slider.min_value = 1
	_size_slider.max_value = 60
	_size_slider.step = 1
	_size_slider.value = 10
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srow.add_child(_size_slider)
	_size_label = _label("10 m")
	_size_label.custom_minimum_size = Vector2(52, 0)
	srow.add_child(_size_label)
	v.add_child(srow)

	_shape_opt = OptionButton.new()
	_shape_opt.add_item("圆形刷子")
	_shape_opt.add_item("方形刷子")
	v.add_child(_shape_opt)

	var trow := _hbox()
	_strength = HSlider.new()
	_strength.min_value = 0.1
	_strength.max_value = 3.0
	_strength.step = 0.05
	_strength.value = 0.9
	_strength.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trow.add_child(_strength)
	_strength_label = _label("0.90")
	_strength_label.custom_minimum_size = Vector2(52, 0)
	trow.add_child(_strength_label)
	v.add_child(trow)

	_snap = CheckBox.new()
	_snap.text = "网格吸附（1m）"
	_snap.button_pressed = true
	v.add_child(_snap)

	v.add_child(HSeparator.new())
	v.add_child(_title("镜头"))
	var crow := _hbox()
	_add_small_button(crow, "俯视", func() -> void: _vp_call("set_view_top"))
	_add_small_button(crow, "斜视", func() -> void: _vp_call("set_view_iso"))
	_add_small_button(crow, "复位", func() -> void: _vp_call("reset_camera"))
	v.add_child(crow)
	return v


## 纹理按钮：左边一个色块，一眼知道刷出来什么颜色
func _mk_color_tool(text: String, _value: int, _color: Color, tool_id: int) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = _splat_group
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 30)
	# 色块皮肤由 Theme 的 EditorSplat* 类型变体提供（颜色也是 token，不在控件里手写）
	match text:
		"草地":
			b.theme_type_variation = &"EditorSplatGrass"
		"泥土":
			b.theme_type_variation = &"EditorSplatDirt"
		"岩石":
			b.theme_type_variation = &"EditorSplatRock"
		"沙地":
			b.theme_type_variation = &"EditorSplatSand"
	b.toggled.connect(func(on: bool) -> void:
		if on and not _syncing:
			session.set_tool(tool_id)
			session.set_mode(0))
	_splat_buttons.append(b)
	return b


func _mk_plain_tool(text: String, tool_id: int) -> Button:
	var b := Spec.editor_button(text)
	b.toggle_mode = true
	b.button_group = _splat_group
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 30)
	b.toggled.connect(func(on: bool) -> void:
		if on and not _syncing:
			session.set_tool(tool_id)
			session.set_mode(0))
	_splat_buttons.append(b)
	return b


func _mk_height_tool(text: String, tool_id: int) -> Button:
	var b := Spec.editor_button(text)
	b.toggle_mode = true
	b.button_group = _height_group
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 30)
	b.toggled.connect(func(on: bool) -> void:
		if on and not _syncing:
			session.set_tool(tool_id)
			session.set_mode(0))
	_height_buttons.append(b)
	return b


# ---------------------------------------------------------------- 对象页
func _build_object_tab() -> Control:
	var v := _vbox()
	# ---------------------------------------------------------------
	# ① 先选玩家（魔兽式）：先点"玩家 2"，再去下面挑要摆的兵/楼。
	#    以前顺序是反的（挑完兵再选中改归属），摆一排兵要点 2N 次。
	# ---------------------------------------------------------------
	v.add_child(_title("摆放归属（先选玩家）"))
	# 用 HFlowContainer 而不是 HBox：4 人图 = 中立 + 4 家 = 5 颗药丸，
	# HBox 不会换行，第 4 颗起会被裁在面板外面（等于"选不到玩家 4"）。
	_place_owner_row = HFlowContainer.new()
	_place_owner_row.name = "摆放归属"
	_place_owner_row.add_theme_constant_override("h_separation", 4)
	_place_owner_row.add_theme_constant_override("v_separation", 4)
	v.add_child(_place_owner_row)
	_hint(_place_owner_row, "选中哪一家，之后在视口里放的**单位和建筑**就归它。装饰/资源永远中立。")

	v.add_child(_title("放置分类"))
	var cat_row := _hbox()
	for c in [MapObject.Category.UNIT, MapObject.Category.BUILDING,
			MapObject.Category.DOODAD, MapObject.Category.RESOURCE]:
		# 按钮上带数量：玩家一眼知道"单位 7 / 建筑 11"，
		# 不会因为列表只露出 6 行就以为"野怪不在里面"（2026-11-01 反馈）。
		var b := Spec.editor_button("%s %d" % [
			MapAssets.category_name(c), MapAssets.category_count(c)])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			session.set_category(c)
			session.set_mode(1))
		cat_row.add_child(b)
		_cat_buttons[c] = b
	v.add_child(cat_row)

	# 魔兽 Doodad 面板也是按类别分页/过滤的：植被 / 岩石 / 营地 / 残迹 / 杂物。
	# 这里只在「装饰」层显示；单位/建筑/资源各自有自己的层，不混进来。
	_group_row = _hbox()
	_group_row.add_child(_label("子类", false, &"EditorHint"))
	_group_opt = OptionButton.new()
	_group_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_opt.add_item("全部")
	for g in MapAssets.DOODAD_GROUP_ORDER:
		_group_opt.add_item(g)
	_group_opt.item_selected.connect(func(_i: int) -> void: _populate_assets())
	_group_row.add_child(_group_opt)
	v.add_child(_group_row)

	_asset_search = LineEdit.new()
	_asset_search.placeholder_text = "搜索单位 / 建筑 / 装饰 / 资源（名字或 id）…"
	_asset_search.clear_button_enabled = true
	_asset_search.text_changed.connect(func(_t: String) -> void: _populate_assets())
	v.add_child(_asset_search)

	_asset_list = ItemList.new()
	# 列表别吃掉半屏：底下「选中对象 / 归属」必须留在第一屏里，不然又得滚
	# 150 → 210：足够露出 8~9 行（单位 7 项能一屏看完，建筑 11 项只差两行）
	_asset_list.custom_minimum_size = Vector2(0, 210)
	_asset_list.auto_height = false
	_asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_asset_list)

	_obj_count = _label("")
	v.add_child(_obj_count)
	_empty_hint = _label("装饰只收自然物（树/草/岩石/营地道具/残迹），单位和建筑请切自己的层。",
		true, &"EditorHint")
	v.add_child(_empty_hint)
	_hint(_asset_list, "选类型 → 回视口空地左键放置；点已有对象 = 选中；拖动 = 移动；Shift 加选。\n建筑自动吸 1m 寻路格 + 90° 朝向，放置时按 R 转向。")

	v.add_child(HSeparator.new())
	v.add_child(_title("选中对象"))

	# ★ 2026-11-07 去掉对象页这张归属卡：它和上面「摆放归属」那一排长得一模一样，
	#   玩家反馈"按钮重复、繁琐"。归属是对象的属性 → 只留在「属性」页。
	#   对象页这里只留一句提示，选中后去属性页改。
	_hint(_obj_count, "选中对象后可在「属性」页改归属；上面那一排是**之后摆放**的归属。")

	var r1 := _hbox()
	_sel_buttons.append(_add_small_button(r1, "复制", func() -> void: session.copy_selection(),
		"copy", "复制选中对象（Ctrl+C）"))
	# 粘贴不需要选中，单独一个，别跟着"无选中"一起灰掉
	_add_small_button(r1, "粘贴", func() -> void: session.paste_clipboard(),
		"paste", "粘贴到当前鼠标位置（Ctrl+V）")
	_sel_buttons.append(_add_small_button(r1, "删除", func() -> void: session.delete_selection(),
		"delete", "删除选中对象（Delete，可撤销）", "danger"))
	v.add_child(r1)

	# 旋转 / 缩放：3 列网格，两行放完 6 个动作（以前两行各占一整行 hbox，面板拉得老长）
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	_sel_buttons.append(_add_grid_button(grid, "−15°", func() -> void: session.rotate_selection(-15.0),
		"rotate_l", "逆时针转 15°（Q）"))
	_sel_buttons.append(_add_grid_button(grid, "+15°", func() -> void: session.rotate_selection(15.0),
		"rotate_r", "顺时针转 15°（E）"))
	_sel_buttons.append(_add_grid_button(grid, "随机", func() -> void: session.randomize_rotation(),
		"rotate_rand", "随机朝向"))
	_sel_buttons.append(_add_grid_button(grid, "缩小", func() -> void: session.scale_selection(0.9),
		"scale_down", "缩到 90%"))
	_sel_buttons.append(_add_grid_button(grid, "放大", func() -> void: session.scale_selection(1.1),
		"scale_up", "放大到 110%"))
	_sel_buttons.append(_add_grid_button(grid, "还原", func() -> void: _reset_scale(),
		"scale_reset", "缩放还原为 1.0"))
	v.add_child(grid)

	v.add_child(HSeparator.new())
	v.add_child(_title("按类型替换"))
	# 下拉 + 按钮同一行：少一行、少一次滚动
	var rr := _hbox()
	_replace_opt = OptionButton.new()
	_replace_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rr.add_child(_replace_opt)
	var br := Spec.editor_button("替换")
	br.custom_minimum_size = Vector2(64, 0)
	br.pressed.connect(_on_replace_pressed)
	rr.add_child(br)
	v.add_child(rr)
	_sel_buttons.append(br)
	return v


## 网格里的小按钮（和 _add_small_button 一样，只是给 GridContainer 用）
## `icon` 为空 → 纯文字（老调用点不用改）。
func _add_grid_button(parent: GridContainer, text: String, cb: Callable,
		icon: String = "", tip: String = "", kind: String = "normal") -> Button:
	var b := Spec.icon_button(icon, text, tip, kind, 30.0)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 拉伸按钮：图标和文字都从左开始排（CENTER 会让文字脱离图标单独居中）
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _add_small_button(parent: HBoxContainer, text: String, cb: Callable,
		icon: String = "", tip: String = "", kind: String = "normal") -> Button:
	var b := Spec.icon_button(icon, text, tip, kind, 30.0)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# ---------------------------------------------------------------- 区域页
func _build_region_tab() -> Control:
	var v := _vbox()
	v.add_child(_title("画区域"))
	_shape_row = _hbox()
	_add_small_button(_shape_row, "圆", func() -> void: _begin_region(RegionDef.Shape.CIRCLE))
	_add_small_button(_shape_row, "矩形", func() -> void: _begin_region(RegionDef.Shape.RECT))
	_add_small_button(_shape_row, "多边形", func() -> void: _begin_region(RegionDef.Shape.POLYGON))
	v.add_child(_shape_row)
	var prow := _hbox()
	prow.add_child(_label("用途"))
	_region_purpose = OptionButton.new()
	for t in ["出生", "进攻", "镜头", "氛围"]:
		_region_purpose.add_item(t)
	_region_purpose.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_region_purpose.item_selected.connect(func(i: int) -> void:
		if not _syncing:
			session.region_purpose = i)
	prow.add_child(_region_purpose)
	v.add_child(prow)
	_hint(_shape_row, "圆/矩形：在视口拖；多边形：连点，回车或右键结束。")

	_region_list = ItemList.new()
	_region_list.custom_minimum_size = Vector2(0, 96)
	v.add_child(_region_list)
	var rid := _hbox()
	rid.add_child(_label("id"))
	_region_id = LineEdit.new()
	_region_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rid.add_child(_region_id)
	v.add_child(rid)
	var rrow := _hbox()
	_add_small_button(rrow, "应用修改", _apply_region)
	_add_small_button(rrow, "删除区域", _delete_region)
	v.add_child(rrow)

	v.add_child(HSeparator.new())
	v.add_child(_title("波次（只做数值，不做行为树）"))
	_wave_list = ItemList.new()
	_wave_list.custom_minimum_size = Vector2(0, 96)
	v.add_child(_wave_list)
	var wrow := _hbox()
	_add_small_button(wrow, "新增波次", func() -> void: _add_wave())
	_add_small_button(wrow, "删除波次", func() -> void: _delete_wave())
	v.add_child(wrow)
	var wg := GridContainer.new()
	wg.columns = 2
	wg.add_theme_constant_override("h_separation", 8)
	v.add_child(wg)
	wg.add_child(_label("时间（秒）"))
	_wave_time = _spin(0, 9999, 5)
	wg.add_child(_wave_time)
	wg.add_child(_label("难度"))
	_wave_diff = OptionButton.new()
	for t in ["简单", "普通", "困难"]:
		_wave_diff.add_item(t)
	wg.add_child(_wave_diff)
	wg.add_child(_label("兵种组成"))
	_wave_comp = LineEdit.new()
	_wave_comp.placeholder_text = "footman:4, archer:2"
	wg.add_child(_wave_comp)
	wg.add_child(_label("出生区域"))
	_wave_spawn = OptionButton.new()
	wg.add_child(_wave_spawn)
	wg.add_child(_label("目标区域"))
	_wave_target = OptionButton.new()
	wg.add_child(_wave_target)
	var bw := Spec.editor_button("应用波次修改")
	bw.pressed.connect(_apply_wave)
	v.add_child(bw)
	return v


# ---------------------------------------------------------------- 玩家页
#
# 为什么单开一页（玩家原话："队伍系统没有看到，不能在编辑器调整队伍吗？"）：
# 以前"队伍"这个字段藏在**区域**页的最下面，跟画圈/波次混在一起 ——
# 找得到的人不用找，找不到的人永远不知道有它。队伍是**玩家**的属性，就该在玩家页。
func _build_player_tab() -> Control:
	var v := _vbox()
	v.add_child(_title("玩家槽位"))
	_player_opt = OptionButton.new()
	v.add_child(_player_opt)
	# ★ 2026-11-07：槽位可增删（魔兽式 2~12 家）。以前只能改字段，
	#   想加一家必须去别的工具重生成整张图。
	var prow := _hbox()
	_add_small_button(prow, "＋ 添加玩家", func() -> void: _edit_player_count(true))
	prow.add_child(Control.new())
	_add_small_button(prow, "－ 删除最后一位", func() -> void: _edit_player_count(false))
	v.add_child(prow)
	_hint(prow, "最多 12 家；删除只允许删最后一位，至少保留 2 家。都能 Ctrl+Z 撤。")

	var pg := GridContainer.new()
	pg.columns = 2
	pg.add_theme_constant_override("h_separation", 8)
	v.add_child(pg)
	pg.add_child(_label("阵营"))
	_player_faction = OptionButton.new()
	for i in range(FACTION_NAMES.size()):
		_player_faction.add_item(FACTION_NAMES[i])
		_player_faction.set_item_metadata(i, FACTION_KEYS[i])
	_player_faction.tooltip_text = "己方 = 玩家操控；敌方 = 敌方 AI；中立 = 不参战"
	pg.add_child(_player_faction)

	pg.add_child(_label("颜色"))
	_player_color = ColorPickerButton.new()
	_player_color.custom_minimum_size = Vector2(0, 24)
	pg.add_child(_player_color)

	pg.add_child(_label("队伍"))
	_player_team = _spin(1, 12, 1)
	# 队伍 = 盟友分组：同队互为盟友，异队互相敌对（阵营决定 AI 行为，队伍决定敌我）
	_player_team.tooltip_text = "队伍相同的玩家互为盟友；不同队伍互相敌对。\n队伍号从 1 起，改完立刻生效于胜负判定。"
	pg.add_child(_player_team)

	pg.add_child(_label("出生 X"))
	_player_x = _spin(-256, 256, 1)
	pg.add_child(_player_x)
	pg.add_child(_label("出生 Z"))
	_player_z = _spin(-256, 256, 1)
	pg.add_child(_player_z)
	pg.add_child(_label("基地朝向°"))
	_player_yaw = _spin(-360, 360, 5)
	pg.add_child(_player_yaw)
	pg.add_child(_label("初始金币"))
	_player_gold = _spin(0, 99999, 10)
	pg.add_child(_player_gold)
	pg.add_child(_label("初始木材"))
	_player_wood = _spin(0, 99999, 10)
	pg.add_child(_player_wood)

	var frow := _hbox()
	_add_small_button(frow, "镜头对准该出生点", _focus_player)
	v.add_child(frow)

	v.add_child(HSeparator.new())
	v.add_child(_title("队伍（盟友分组）"))
	_team_summary = _label("", true)
	v.add_child(_team_summary)
	_hint(_team_summary, "同队伍的玩家互为盟友（不互相攻击、视野共享）；不同队伍互相敌对。")

	var t1 := _hbox()
	_add_small_button(t1, "各自为战", func() -> void: _team_preset("solo"))
	t1.add_child(Control.new())
	_add_small_button(t1, "两队对抗", func() -> void: _team_preset("two"))
	v.add_child(t1)
	var t2 := _hbox()
	_add_small_button(t2, "全部同盟", func() -> void: _team_preset("all"))
	v.add_child(t2)
	_hint(t2, "预设只是批量改队伍号，改完仍可逐个槽位微调；都能 Ctrl+Z 撤。")
	return v


## 排队伍预设 → 交回会话（会话负责进撤销栈 + 刷状态栏）
func _team_preset(kind: String) -> void:
	if session == null:
		return
	session.set_team_layout(kind)
	_refresh_players()
	_sync_team_summary()


func _sync_team_summary() -> void:
	if _team_summary == null or session == null:
		return
	_team_summary.text = session.team_summary()


# ---------------------------------------------------------------- 属性页
func _build_prop_tab() -> Control:
	var v := _vbox()
	v.add_child(_title("对象属性"))
	_prop_hint = _label("没有选中对象。在视口里点一下对象，或用「对象」页放置。", true)
	v.add_child(_prop_hint)
	# 属性页也放一张归属卡：归属是"对象的属性"，不是对象页的私货。
	# 放在 _prop_box 外面 —— 没选中时也留在原位，不跳。
	_build_owner_card(v)
	_prop_box = _vbox()
	v.add_child(_prop_box)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	_prop_box.add_child(grid)
	grid.add_child(_label("位置 X"))
	_pos_x = _spin(-256, 256, 0.5)
	grid.add_child(_pos_x)
	grid.add_child(_label("位置 Z"))
	_pos_z = _spin(-256, 256, 0.5)
	grid.add_child(_pos_z)
	grid.add_child(_label("朝向（度）"))
	_rot_spin = _spin(-360, 360, 5)
	grid.add_child(_rot_spin)
	grid.add_child(_label("缩放"))
	_scale_spin = _spin(0.05, 10.0, 0.05)
	grid.add_child(_scale_spin)
	v.add_child(HSeparator.new())
	_hint(_scale_spin, "连续改同一个数值会自动合成一条撤销记录。")
	return v


func _spin(min_v: float, max_v: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


# ---------------------------------------------------------------- 营地页
#
# 为什么单开一页（玩家原话："地图编辑器里我没有找到野怪营地，同时我要的野怪营地，
# 里面我自己可自定义配置弄什么野怪"）：
#   营地是"地图内容"，刷什么怪写在一张 .tres 里，散落在 代码/配置/卡/野怪营地/。
#   以前只能手改文本文件 —— 编辑器里没有任何入口，等于"找不到"。
#   这里把那张表原样搬成界面：左列表选一份，右边勾野怪、填只数、存盘。
#   保存后必须 CAMP_TABLE.reload()：否则玩家刚写的配置要重启 Godot 才生效。
func _build_camp_tab() -> Control:
	var v := _vbox()
	v.add_child(_title("野怪营地"))

	var split := _hbox()
	v.add_child(split)

	# --- 左：营地清单 ---
	var left := _vbox()
	left.custom_minimum_size = Vector2(104, 0)
	split.add_child(left)
	_camp_list = ItemList.new()
	_camp_list.custom_minimum_size = Vector2(104, 220)
	_camp_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_camp_list.item_selected.connect(_on_camp_selected)
	left.add_child(_camp_list)
	_hint(_camp_list, "选中一份营地配置 → 右边改刷什么怪、几只。\n每份配置对应一种锚点建筑（巢穴/入口/折壳营地），\n锚点建筑必须摆成「中立」才会被系统认出来。\n★ 视口里手型状态下单击锚点建筑，也能直接弹出配置窗。")

	# --- 右：表单 ---
	var right := _vbox()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	right.add_child(_title("营地配置"))
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 4)
	right.add_child(g)

	g.add_child(_label("显示名"))
	_camp_name = LineEdit.new()
	_camp_name.placeholder_text = "豺狼人营地"
	g.add_child(_camp_name)

	g.add_child(_label("营地 id"))
	_camp_id = LineEdit.new()
	_camp_id.placeholder_text = "camp_den"
	_hint(_camp_id, "新建时用它拼文件名（代码/配置/卡/野怪营地/<id>.tres）。\n已存在的营地按原本的文件路径写回，id 只作标识。")
	g.add_child(_camp_id)

	g.add_child(_label("锚点建筑"))
	_camp_den = OptionButton.new()
	_camp_den.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint(_camp_den, "地图里摆下这座建筑（归属=中立）时，这里配的怪才会刷出来。")
	for a in MapAssets.of_category(MapObject.Category.BUILDING):
		_camp_den.add_item(MapAssets.list_label(a))
		_camp_den.set_item_metadata(_camp_den.item_count - 1, String(a["id"]))
	g.add_child(_camp_den)

	g.add_child(_label("半径 m"))
	_camp_radius = _spin(1.0, 40.0, 0.5)
	_hint(_camp_radius, "野怪在锚点建筑周围这个半径内出生。")
	g.add_child(_camp_radius)

	g.add_child(_label("补满秒"))
	_camp_respawn = _spin(0.0, 600.0, 5.0)
	_hint(_camp_respawn, "全灭后多久补满。0 = 永不补（打完就没了）。")
	g.add_child(_camp_respawn)

	g.add_child(_label("小地图图标"))
	_camp_icon = LineEdit.new()
	_camp_icon.placeholder_text = "camp"
	g.add_child(_camp_icon)

	# --- 归属 + 时间点（玩家口径：这是哪个玩家的、几分钟刷）---
	g.add_child(_label("归属"))
	_camp_owner = OptionButton.new()
	_camp_owner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_camp_owner.add_item("中立敌对（野怪）")
	_camp_owner.set_item_metadata(0, -2)
	_camp_owner.add_item("中立（和平）")
	_camp_owner.set_item_metadata(1, -1)
	for i in range(12):
		_camp_owner.add_item("玩家 %d" % (i + 1))
		_camp_owner.set_item_metadata(_camp_owner.item_count - 1, i)
	_hint(_camp_owner, "「应用到选中锚点」时连归属一起改；进图后以锚点建筑的归属为准。")
	g.add_child(_camp_owner)

	g.add_child(_label("首刷（分钟）"))
	_camp_first = _spin(0.0, 120.0, 0.5)
	_hint(_camp_first, "开局后第几分钟第一次刷。0 = 开局立刻刷。")
	g.add_child(_camp_first)

	g.add_child(_label("间隔（分钟）"))
	_camp_interval = _spin(0.0, 60.0, 0.5)
	_hint(_camp_interval, "每隔几分钟再刷一整波。0 = 只刷一次（之后只靠补满秒）。")
	g.add_child(_camp_interval)
	right.add_child(_label("补满秒填 0 = 永不补", false, &"EditorHint"))

	right.add_child(HSeparator.new())
	right.add_child(_title("野怪清单"))
	var csplit := _hbox()
	right.add_child(csplit)
	_camp_creep_list = ItemList.new()
	_camp_creep_list.select_mode = ItemList.SELECT_MULTI
	_camp_creep_list.custom_minimum_size = Vector2(96, 168)
	_camp_creep_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_camp_creep_list.multi_selected.connect(_on_camp_creeps_multi)
	# ItemList(multi) 的默认单击 = "只留这一个"（多选要 Ctrl），
	# 玩家勾野怪的心智是"点一下勾上、再点取消"。所以自己接一手点击：
	# gui_input 信号比 C++ 的默认处理先跑，accept_event() 之后默认行为不再执行。
	_camp_creep_list.gui_input.connect(_on_camp_creep_list_input)
	csplit.add_child(_camp_creep_list)
	_hint(_camp_creep_list, "点一下=勾上（再点=取消），可以勾多只野怪。")
	for a in MapAssets.of_category(MapObject.Category.UNIT):
		_camp_creep_list.add_item(MapAssets.list_label(a))
		_camp_creep_list.set_item_metadata(_camp_creep_list.item_count - 1, String(a["id"]))
		# 列窄，名字会被省略号截断 —— 悬停看全名
		_camp_creep_list.set_item_tooltip(_camp_creep_list.item_count - 1,
			MapAssets.list_label(a))

	_camp_count_box = _vbox()
	_camp_count_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	csplit.add_child(_camp_count_box)
	_hint(_camp_count_box, "每个已选野怪一行，填刷几只（1~12）。")

	right.add_child(HSeparator.new())
	var brow := _hbox()
	_add_small_button(brow, "新建", _camp_new)
	_add_small_button(brow, "复制", _camp_copy)
	_add_small_button(brow, "删除", _camp_delete)
	_add_small_button(brow, "保存", _camp_save)
	right.add_child(brow)
	var arow := _hbox()
	_add_small_button(arow, "应用到选中锚点（可多选）", _camp_apply_to_selection)
	right.add_child(arow)

	_camp_status = _label("", true, &"EditorHint")
	v.add_child(_camp_status)
	return v


## 重新扫一遍营地卡目录，并把当前选中的那一行保住
func _refresh_camps() -> void:
	if _camp_list == null:
		return
	_syncing = true
	_camp_list.clear()
	var sel: int = -1
	for res in CAMP_TABLE.all():
		if res == null:
			continue
		_camp_list.add_item("%s · %s" % [String(res.get("display_name")),
			String(res.get("den_building"))])
		_camp_list.set_item_metadata(_camp_list.item_count - 1, res)
		_camp_list.set_item_tooltip(_camp_list.item_count - 1,
			"%s（锚点 %s）" % [String(res.get("display_name")),
				String(res.get("den_building"))])
		if not _camp_sel_path.is_empty() and String(res.resource_path) == _camp_sel_path:
			sel = _camp_list.item_count - 1
	if sel < 0 and _camp_cur == null and _camp_list.item_count > 0:
		sel = 0
	if sel >= 0:
		_camp_list.select(sel)
		_syncing = false
		_load_camp(_camp_list.get_item_metadata(sel) as Resource)
		return
	_syncing = false
	# ⚠ 这里**不能**"没找到就退回第一份"：
	#   刚建的草稿还没落盘、或者存了个表里不收的卡，选中一换，
	#   下一次点「删除」删的就是别人那份文件（QA 里真踩到过）。
	if _camp_list.item_count == 0:
		_camp_cur = null
		_camp_status.text = "还没有营地配置，点「新建」做一份"


func _on_camp_selected(index: int) -> void:
	if _syncing:
		return
	var res: Resource = _camp_list.get_item_metadata(index) as Resource
	if res == null:
		return
	_camp_sel_path = String(res.resource_path)
	_load_camp(res)


## 把一份营地配置灌进右侧表单（creeps/counts 是界面的编辑副本）
func _load_camp(res: Resource) -> void:
	if res == null:
		return
	_camp_cur = res
	_camp_creeps.clear()
	_camp_counts.clear()
	# 卡片是磁盘上的数据，可能被人手改坏 —— 取不到就当空
	var raw: Variant = res.get("creeps")
	if raw is Array:
		for c in raw:
			_camp_creeps.append(StringName(String(c)))
	var counts: Variant = res.get("counts")
	var cl: Array = counts if counts is Array else []
	for i in range(_camp_creeps.size()):
		_camp_counts.append(int(cl[i]) if i < cl.size() else 1)
	_syncing = true
	_camp_name.text = String(res.get("display_name"))
	_camp_id.text = String(res.get("id"))
	_camp_radius.value = float(res.get("radius"))
	_camp_respawn.value = float(res.get("respawn"))
	_camp_icon.text = String(res.get("minimap_icon"))
	_camp_first.value = float(res.get("first_spawn_min"))
	_camp_interval.value = float(res.get("spawn_interval_min"))
	_select_option_by_meta(_camp_owner, str(int(res.get("owner_slot"))))
	_select_option_by_meta(_camp_den, String(res.get("den_building")))
	_sync_camp_creep_list()
	_rebuild_camp_counts()
	_syncing = false
	_camp_status.text = "正在编辑：%s" % (
		res.resource_path.get_file() if not String(res.resource_path).is_empty() else "（未保存）")


## 当前"归属"下拉的槽位号（-2 中立敌对 / -1 中立 / 0..11 玩家）
func _camp_owner_id() -> int:
	if _camp_owner == null or _camp_owner.selected < 0:
		return -2
	return int(_camp_owner.get_item_metadata(_camp_owner.selected))


## 把当前配置（id + 归属）指派给视口里选中的锚点建筑（逐实例生效）
func _camp_apply_to_selection() -> void:
	if session == null or _camp_cur == null:
		_camp_status.text = "先选一份营地配置"
		return
	if session.selection.is_empty():
		_camp_status.text = "先在视口里选中锚点建筑（可 Shift 多选）"
		return
	var cid: String = String(_camp_cur.get("id"))
	var n: int = session.assign_camp_to_selection(cid, _camp_owner_id())
	if n <= 0:
		_camp_status.text = "选中的不是建筑（只有建筑能当锚点）"
		return
	_camp_status.text = "已指派给 %d 座锚点：%s（归属 %s）" % [
		n, cid, session.owner_display_name(_camp_owner_id())]


## 让多选列表的勾选状态跟 _camp_creeps 一致
func _sync_camp_creep_list() -> void:
	if _camp_creep_list == null:
		return
	for i in range(_camp_creep_list.item_count):
		var uid: StringName = StringName(String(_camp_creep_list.get_item_metadata(i)))
		if _camp_creeps.has(uid):
			_camp_creep_list.select(i, false)
		else:
			_camp_creep_list.deselect(i)


## 按 _camp_creeps 重建右侧"每个野怪一行只数"
func _rebuild_camp_counts() -> void:
	if _camp_count_box == null:
		return
	for c in _camp_count_box.get_children():
		_camp_count_box.remove_child(c)
		c.free()
	if _camp_creeps.is_empty():
		_camp_count_box.add_child(_label("勾左边的野怪 → 这里出现只数", true, &"EditorHint"))
		return
	for i in range(_camp_creeps.size()):
		var row := _hbox()
		var nm: Label = _label(MapAssets.display_name(_camp_creeps[i]))
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.clip_text = true
		row.add_child(nm)
		var sb: SpinBox = _spin(1, 12, 1)
		sb.custom_minimum_size = Vector2(62, 0)
		sb.size_flags_horizontal = Control.SIZE_SHRINK_END
		sb.value = clampi(int(_camp_counts[i]) if i < _camp_counts.size() else 1, 1, 12)
		# 循环变量在这里落成局部量：GDScript 的 lambda 按值捕获，
		# 不落的话回调里拿到的是循环结束后的同一个 i（改哪一行都写到同一格）。
		var idx: int = i
		sb.value_changed.connect(func(v: float) -> void:
			if idx < _camp_counts.size():
				_camp_counts[idx] = int(v))
		row.add_child(sb)
		_camp_count_box.add_child(row)


## 点击列表里的野怪 → 勾上 / 取消（自己接管，见 _build_camp_tab 里的说明）
func _on_camp_creep_list_input(event: InputEvent) -> void:
	if _syncing or _camp_creep_list == null:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var idx: int = _camp_creep_list.get_item_at_position(mb.position, true)
	if idx < 0:
		return
	_camp_creep_list.accept_event()
	var on: bool = not _camp_creep_list.is_selected(idx)
	_syncing = true
	if on:
		_camp_creep_list.select(idx, false)
	else:
		_camp_creep_list.deselect(idx)
	_syncing = false
	_apply_camp_creep_toggle(idx, on)


## 兜底：键盘 / 其它途径改了选中状态时也同步数据
func _on_camp_creeps_multi(index: int, selected: bool) -> void:
	if _syncing:
		return
	_apply_camp_creep_toggle(index, selected)


## 勾/取消一只野怪：同步 _camp_creeps/_camp_counts 两个数组
func _apply_camp_creep_toggle(index: int, selected: bool) -> void:
	if _camp_creep_list == null or index < 0 or index >= _camp_creep_list.item_count:
		return
	var uid: StringName = StringName(String(_camp_creep_list.get_item_metadata(index)))
	if selected:
		if not _camp_creeps.has(uid):
			_camp_creeps.append(uid)
			_camp_counts.append(1)
	else:
		var at: int = _camp_creeps.find(uid)
		if at >= 0:
			_camp_creeps.remove_at(at)
			if at < _camp_counts.size():
				_camp_counts.remove_at(at)
	_rebuild_camp_counts()


func _camp_new() -> void:
	var base: String = "camp_new"
	var nid: String = base
	var n: int = 0
	while FileAccess.file_exists(CAMP_TABLE.CARD_DIR + nid + ".tres"):
		n += 1
		nid = "%s%d" % [base, n]
	var res: Resource = CAMP_DEF.new()
	_camp_sel_path = ""
	_load_camp(res)
	_syncing = true
	_camp_id.text = nid
	_camp_status.text = "新建「%s」：填好后点「保存」才会写盘" % nid
	_syncing = false
	if _camp_list != null:
		# 新配置还没落盘，列表里不该有它 —— 清掉选中，避免误以为已经存在
		_syncing = true
		_camp_list.deselect_all()
		_syncing = false


func _camp_copy() -> void:
	if _camp_cur == null:
		_camp_status.text = "先选一份营地再复制"
		return
	var base: String = String(_camp_cur.get("id")) + "_copy"
	if base.is_empty():
		base = "camp_copy"
	var nid: String = base
	var n: int = 0
	while FileAccess.file_exists(CAMP_TABLE.CARD_DIR + nid + ".tres"):
		n += 1
		nid = "%s%d" % [base, n]
	var res: Resource = CAMP_DEF.new()
	res.set("id", StringName(nid))
	res.set("display_name", String(_camp_cur.get("display_name")) + "（副本）")
	res.set("den_building", StringName(String(_camp_cur.get("den_building"))))
	var creeps: Array[StringName] = []
	var counts: Array[int] = []
	for i in range(_camp_creeps.size()):
		creeps.append(StringName(String(_camp_creeps[i])))
		counts.append(int(_camp_counts[i]) if i < _camp_counts.size() else 1)
	res.set("creeps", creeps)
	res.set("counts", counts)
	res.set("radius", float(_camp_cur.get("radius")))
	res.set("respawn", float(_camp_cur.get("respawn")))
	res.set("minimap_icon", String(_camp_cur.get("minimap_icon")))
	_camp_sel_path = ""
	_load_camp(res)
	_syncing = true
	_camp_id.text = nid
	_camp_status.text = "已复制为「%s」：点「保存」写盘" % nid
	_syncing = false
	if _camp_list != null:
		_syncing = true
		_camp_list.deselect_all()
		_syncing = false


func _camp_delete() -> void:
	if _camp_cur == null:
		_camp_status.text = "先选一份营地再删除"
		return
	var path: String = String(_camp_cur.resource_path)
	if path.is_empty():
		_camp_status.text = "这份营地还没保存过，没有文件可删"
		return
	var err: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		_camp_status.text = "删除失败（错误码 %d）：%s" % [err, path.get_file()]
		return
	CAMP_TABLE.reload()
	_camp_cur = null
	_camp_sel_path = ""
	_refresh_camps()
	_camp_status.text = "已删除 %s" % path.get_file()


func _camp_save() -> void:
	if _camp_cur == null:
		_camp_status.text = "先「新建」或从左列表选一份营地"
		return
	var nm: String = _camp_name.text.strip_edges()
	if nm.is_empty():
		_camp_status.text = "显示名不能为空"
		return
	var nid: String = _camp_id.text.strip_edges().validate_filename()
	if nid.is_empty():
		_camp_status.text = "营地 id 不能为空（只允许文件名用的字符）"
		return
	var den: String = ""
	if _camp_den.selected >= 0:
		den = String(_camp_den.get_item_metadata(_camp_den.selected))
	if den.is_empty():
		_camp_status.text = "先选一个锚点建筑"
		return
	# 草稿（还没落盘）才按 id 拼路径；已有的配置一律写回它原本的文件，
	# 因为 id 和文件名允许不一致，按 id 重拼会把老文件复制成第二份、锚点重复。
	var path: String = String(_camp_cur.resource_path)
	if path.is_empty():
		path = CAMP_TABLE.CARD_DIR + nid + ".tres"
		if FileAccess.file_exists(path):
			_camp_status.text = "已有 id 为「%s」的营地，换个 id 再存" % nid
			return
	# 2026-11-07：同一种锚点**允许多份配置**（逐实例用 camp_id 指定）。
	# 只是提醒：不指定 camp_id 的锚点会落到"默认那份"（文件名排序第一）。
	for other in CAMP_TABLE.all():
		if other == null or other == _camp_cur:
			continue
		var opath: String = String(other.resource_path)
		if opath == path or opath == String(_camp_cur.resource_path):
			continue
		if String(other.get("den_building")) != den:
			continue
		push_warning("[营地] 锚点 %s 已有一份默认配置 %s；这一份需要在锚点上指定 camp_id 才会生效"
			% [den, opath.get_file()])
	var creeps: Array[StringName] = []
	var counts: Array[int] = []
	for i in range(_camp_creeps.size()):
		creeps.append(StringName(String(_camp_creeps[i])))
		counts.append(int(_camp_counts[i]) if i < _camp_counts.size() else 1)
	_camp_cur.set("id", StringName(nid))
	_camp_cur.set("display_name", nm)
	_camp_cur.set("den_building", StringName(den))
	_camp_cur.set("creeps", creeps)
	_camp_cur.set("counts", counts)
	_camp_cur.set("radius", _camp_radius.value)
	_camp_cur.set("respawn", _camp_respawn.value)
	_camp_cur.set("minimap_icon", _camp_icon.text.strip_edges())
	_camp_cur.set("owner_slot", _camp_owner_id())
	_camp_cur.set("first_spawn_min", _camp_first.value)
	_camp_cur.set("spawn_interval_min", _camp_interval.value)
	var err: int = ResourceSaver.save(_camp_cur, path)
	if err != OK:
		_camp_status.text = "保存失败（错误码 %d）：%s" % [err, path]
		return
	# 必须清缓存：营地表是静态缓存，不然刚存的配置要重启 Godot 才看得到
	CAMP_TABLE.reload()
	_camp_sel_path = path
	_refresh_camps()
	# 弹窗如果正开着同一份配置，把它的表单也刷成刚存的值（两边编辑同一份数据）
	if session != null and session.camp_dialog != null \
			and is_instance_valid(session.camp_dialog) \
			and session.camp_dialog.has_method("reload_if"):
		session.camp_dialog.call("reload_if", path)
	_camp_status.text = "已保存 %s（野怪：%s）" % [path.get_file(),
		"、".join(_camp_creep_summary())]


func _camp_creep_summary() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i in range(_camp_creeps.size()):
		out.append("%s×%d" % [MapAssets.display_name(_camp_creeps[i]),
			int(_camp_counts[i]) if i < _camp_counts.size() else 1])
	return out


# ---------------------------------------------------------------- 历史页
## 撤销/重做面板：**用编辑器自带的 Tree 实现**，数据来自 EditorUndoRedoManager。
## 和魔兽编辑器一样：历史是"可见的"，点某一步就跳回那一步，而不是只能按 Ctrl+Z。
func _build_history_tab() -> Control:
	var v := _vbox()
	v.add_child(_title("编辑历史"))
	_hint(_history_tree, "所有地形笔刷、对象摆放/拖动、区域与属性修改都在这里。点一条记录可直接跳到那一步；灰字 = 已撤销（还能重做）。")
	_history_tree = Tree.new()
	_history_tree.custom_minimum_size = Vector2(0, 320)
	_history_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_tree.hide_root = true
	_history_tree.columns = 2
	_history_tree.column_titles_visible = true
	_history_tree.set_column_title(0, "步")
	_history_tree.set_column_title(1, "操作")
	_history_tree.set_column_expand(0, false)
	_history_tree.set_column_custom_minimum_width(0, 38)
	_history_tree.set_column_expand(1, true)
	_history_tree.item_selected.connect(_on_history_selected)
	v.add_child(_history_tree)
	var row := _hbox()
	_add_small_button(row, "撤销一步", func() -> void: session.undo())
	_add_small_button(row, "重做一步", func() -> void: session.redo())
	_add_small_button(row, "回到初始", func() -> void: session.jump_history(-1))
	v.add_child(row)
	_history_hint = _label("", true, &"EditorHint")
	v.add_child(_history_hint)
	return v


func _refresh_history() -> void:
	if _history_tree == null or session == null:
		return
	_syncing = true
	_history_tree.clear()
	var root: TreeItem = _history_tree.create_item()
	var info: Dictionary = session.history_info() if session.has_method("history_info") else {}
	var names: PackedStringArray = info.get("names", PackedStringArray())
	var count: int = int(info.get("count", 0))
	var cur: int = int(info.get("current", -1))
	var current_item: TreeItem = null
	var initial: TreeItem = _history_tree.create_item(root)
	initial.set_text(0, "●" if cur < 0 else "0")
	initial.set_text(1, "（初始状态）")
	initial.set_metadata(0, -1)
	initial.set_tooltip_text(0, "撤销到打开/新建这张图时的状态")
	if cur < 0:
		current_item = initial
	var items: Array = [initial]
	for i in range(count):
		var it: TreeItem = _history_tree.create_item(root)
		items.append(it)
		var nm: String = String(names[i]) if i < names.size() else "操作 %d" % (i + 1)
		it.set_text(0, "●" if i == cur else str(i + 1))
		it.set_text(1, nm)
		it.set_metadata(0, i)
		it.set_tooltip_text(1, nm)
		if i == cur:
			it.set_custom_color(1, Spec.editor_accent_soft())
			current_item = it
		elif i > cur:
			it.set_custom_color(1, Spec.editor_text_dim(0.72))
	if current_item != null:
		current_item.select(0)
	if count == 0:
		_history_hint.text = "还没有可撤销的操作。刷一笔地形或摆一个对象就会出现。"
	elif cur < 0:
		_history_hint.text = "共 %d 步 · 当前在初始状态（所有操作已撤销）" % count
	else:
		_history_hint.text = "共 %d 步 · 当前第 %d 步「%s」" % [count, cur + 1,
			String(names[cur]) if cur < names.size() else ""]
	_syncing = false


func _on_history_selected() -> void:
	if _syncing or session == null or _history_tree == null:
		return
	var it: TreeItem = _history_tree.get_selected()
	if it == null:
		return
	var target: int = int(it.get_metadata(0))
	session.jump_history(target)


# ---------------------------------------------------------------- 校验页
func _build_validate_tab() -> Control:
	var v := _vbox()
	v.add_child(_title("地图校验"))
	var b := Spec.editor_button("立即校验（保存前也会自动跑）")
	b.pressed.connect(func() -> void: session.validate())
	v.add_child(b)
	_val_summary = _label("")
	v.add_child(_val_summary)
	_val_text = RichTextLabel.new()
	_val_text.bbcode_enabled = true
	_val_text.custom_minimum_size = Vector2(0, 380)
	_val_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_val_text)
	_hint(_val_text, "硬关：出生点可走 / 金矿·树可达 / 玩家不重叠 / 边界合法 / 至少一个敌方出生点。")
	return v


# ===========================================================================
# 接线
# ===========================================================================

func _wire() -> void:
	if session == null:
		return
	_size_slider.value_changed.connect(func(v: float) -> void:
		session.brush_radius = v
		_size_label.text = "%d m" % int(v))
	_strength.value_changed.connect(func(v: float) -> void:
		session.brush_strength = v
		_strength_label.text = "%.2f" % v)
	_shape_opt.item_selected.connect(func(i: int) -> void: session.brush_square = i == 1)
	_snap.toggled.connect(func(on: bool) -> void: session.snap_grid = on)

	_asset_list.item_selected.connect(_on_asset_selected)
	_replace_opt.item_selected.connect(func(_i: int) -> void: pass)

	_pos_x.value_changed.connect(_on_pos_changed)
	_pos_z.value_changed.connect(_on_pos_changed)
	_rot_spin.value_changed.connect(_on_rot_changed)
	_scale_spin.value_changed.connect(_on_scale_changed)

	_player_opt.item_selected.connect(_on_player_selected)
	_player_faction.item_selected.connect(func(i: int) -> void:
		if not _syncing:
			_set_player("faction", String(_player_faction.get_item_metadata(i))))
	_player_color.color_changed.connect(func(c: Color) -> void:
		if not _syncing:
			_set_player("color", c))
	_player_team.value_changed.connect(func(v: float) -> void: _set_player("team", int(v)))
	_player_x.value_changed.connect(func(v: float) -> void: _set_player("start_pos",
		Vector2(v, _player_z.value)))
	_player_z.value_changed.connect(func(v: float) -> void: _set_player("start_pos",
		Vector2(_player_x.value, v)))
	_player_yaw.value_changed.connect(func(v: float) -> void: _set_player("yaw", deg_to_rad(v)))
	_player_gold.value_changed.connect(func(v: float) -> void: _set_player("gold", int(v)))
	_player_wood.value_changed.connect(func(v: float) -> void: _set_player("wood", int(v)))

	_region_list.item_selected.connect(_on_region_selected)
	_wave_list.item_selected.connect(_on_wave_selected)

	session.def_changed.connect(_on_def_changed)
	session.selection_changed.connect(_on_selection_changed)
	session.validation_changed.connect(_on_validation)
	session.map_loaded.connect(_sync_all)
	if session.has_signal("history_changed"):
		session.history_changed.connect(_refresh_history)
	session.mode_changed.connect(func(_m: int) -> void: _sync_tool_buttons())
	session.category_changed.connect(_on_category_changed)
	if session.has_signal("tool_changed"):
		session.tool_changed.connect(_sync_tool_buttons)


func _sync_all() -> void:
	if session == null:
		return
	_syncing = true
	_size_slider.value = session.brush_radius
	_size_label.text = "%d m" % int(session.brush_radius)
	_strength.value = session.brush_strength
	_strength_label.text = "%.2f" % session.brush_strength
	_shape_opt.select(1 if session.brush_square else 0)
	_snap.button_pressed = session.snap_grid
	_region_purpose.select(clampi(session.region_purpose, 0, 3))
	_sync_biome_option()
	_syncing = false
	_sync_tool_buttons()
	_sync_object_filters()
	_populate_assets()
	_refresh_players()
	_refresh_regions()
	_refresh_waves()
	_rebuild_owner_pills()
	_rebuild_place_pills()
	_sync_team_summary()
	_refresh_camps()
	_on_selection_changed()
	_on_validation(session.validation)
	_refresh_history()


## 地形类型下拉对齐（打开/新建/撤销换生态后都要对）
func _sync_biome_option() -> void:
	if _biome_opt == null or session == null or session.def == null:
		return
	var idx: int = MapDef.BIOME_ORDER.find(session.def.biome)
	_biome_opt.select(idx if idx >= 0 else 0)


## 工具按钮的点亮状态跟会话对齐（左侧层切换、快捷键、撤销后都要对）
## 手型状态下所有工具按钮都不点亮 —— 界面必须和"左键到底干什么"一致。
func _sync_tool_buttons() -> void:
	_syncing = true
	var live: bool = session != null and bool(session.armed)
	var t: int = int(session.tool) if live else -1
	for i in range(_height_buttons.size()):
		var b: Button = _height_buttons[i]
		b.button_pressed = (t == i)
	for b in _splat_buttons:
		b.button_pressed = false
	# 纹理按钮按顺序对应 4..9
	var order: Array[int] = [4, 5, 6, 7, 9, 8]
	for i in range(mini(order.size(), _splat_buttons.size())):
		if t == order[i]:
			_splat_buttons[i].button_pressed = true
	for c in _cat_buttons:
		var btn: Button = _cat_buttons[c]
		btn.button_pressed = (live and int(session.asset_category) == c and int(session.mode) == 1)
	_syncing = false


func _on_category_changed(cat: int) -> void:
	if _group_opt != null:
		_group_opt.select(0)
	_sync_object_filters()
	_populate_assets()
	_sync_tool_buttons()


## 子类过滤只对装饰有意义：切到单位/建筑/资源时藏起来（不制造"能筛单位"的假象）
func _sync_object_filters() -> void:
	if _group_row == null or session == null:
		return
	_group_row.visible = int(session.asset_category) == MapObject.Category.DOODAD
	_asset_search.placeholder_text = "搜索单位 / 建筑 / 装饰 / 资源（名字或 id）…" \
		if int(session.asset_category) == MapObject.Category.DOODAD else "搜索类型…"


func _populate_assets() -> void:
	if session == null:
		return
	_syncing = true
	_asset_list.clear()
	_replace_opt.clear()
	var cat: int = int(session.asset_category)
	var items: Array = MapAssets.of_category(cat)
	var group: String = ""
	if cat == MapObject.Category.DOODAD and _group_opt != null and _group_opt.selected > 0:
		group = _group_opt.get_item_text(_group_opt.selected)
	var needle: String = _asset_search.text.strip_edges().to_lower() if _asset_search != null else ""
	var shown: int = 0
	for a in items:
		var id: String = String(a["id"])
		var nm: String = String(a.get("name", id))
		if cat == MapObject.Category.DOODAD and not group.is_empty() \
				and String(a.get("group", "杂物")) != group:
			continue
		if not needle.is_empty() and not (nm.to_lower().contains(needle)
				or id.to_lower().contains(needle)):
			continue
		_asset_list.add_item(MapAssets.list_label(a))
		_asset_list.set_item_metadata(_asset_list.item_count - 1, id)
		_replace_opt.add_item(MapAssets.list_label(a))
		_replace_opt.set_item_metadata(_replace_opt.item_count - 1, id)
		shown += 1
	# 只有当前 asset_id 还在过滤结果里才保留选中；否则选第一条，避免"列表里没有却在放"
	var keep: int = -1
	for i in range(_asset_list.item_count):
		if String(_asset_list.get_item_metadata(i)) == String(session.asset_id):
			keep = i
			break
	if keep < 0 and _asset_list.item_count > 0:
		keep = 0
		session.asset_id = StringName(String(_asset_list.get_item_metadata(0)))
	elif keep < 0:
		# 过滤后一项都没有：清掉手持类型，避免在空列表状态下还能把旧类型摆出去
		session.asset_id = &""
	if keep >= 0:
		_asset_list.select(keep)
	_syncing = false
	_refresh_obj_count()
	if _empty_hint != null:
		_empty_hint.visible = shown == 0
		if cat == MapObject.Category.DOODAD:
			_empty_hint.text = "装饰只收自然物（树/草/岩石/营地道具/残迹），单位和建筑请切自己的层。"
		else:
			_empty_hint.text = "这个分类没有匹配项（试试清空搜索框，或换一个分类）。"


func _on_asset_selected(index: int) -> void:
	var id: StringName = StringName(String(_asset_list.get_item_metadata(index)))
	session.asset_id = id
	session.set_mode(1)
	_refresh_obj_count()


func _on_replace_pressed() -> void:
	if session.selection.is_empty():
		session.status_changed.emit("先选中对象再替换")
		return
	var idx: int = _replace_opt.selected
	if idx < 0:
		return
	session.replace_selection(StringName(String(_replace_opt.get_item_metadata(idx))),
		int(session.asset_category))


func _refresh_obj_count() -> void:
	if session == null or session.def == null:
		_obj_count.text = ""
		return
	# 左边是"图里已经摆了几个"，右边是"这一类能摆几种" —— 两个数字都有人要查
	_obj_count.text = "全图 %d 个 ｜ 本类已摆 %d ｜ 可选 %d 种" % [
		session.def.objects.size(),
		session.def.objects_of(int(session.asset_category)).size(),
		MapAssets.category_count(int(session.asset_category))]


# --- 归属卡 ---

## 建一张归属卡（对象页 / 属性页各一张：不管停在哪一页，归属都在眼前）
func _build_owner_card(parent: Control) -> void:
	var card := PanelContainer.new()
	card.theme_type_variation = &"EditorOwnerCard"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 6)
	card.add_child(cv)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	cv.add_child(row)
	var cap := Spec.editor_label("归属", &"EditorHint")
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(cap)
	var value := Spec.editor_label("未选中", &"EditorOwnerValue")
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.clip_text = true
	row.add_child(value)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	cv.add_child(flow)
	parent.add_child(card)
	_owner_cards.append({"value": value, "flow": flow, "pills": []})


## 重建归属药丸：**中立 + 每一个玩家槽位**，一家一个色。
## 2 人图 3 个、3 人图 4 个、4 人图 5 个 —— 选项永远跟地图上的槽位一样多。
func _rebuild_owner_pills() -> void:
	if session == null or _owner_cards.is_empty():
		return
	var choices: Array = session.owner_choices()
	for card in _owner_cards:
		var flow: HFlowContainer = card["flow"]
		for c in flow.get_children():
			flow.remove_child(c)
			c.free()
		var pills: Array = []
		for ch in choices:
			var col: Color = ch["color"]
			var b := Button.new()
			b.theme_type_variation = &"EditorOwnerPill"
			b.toggle_mode = true
			b.focus_mode = Control.FOCUS_NONE
			b.text = "● " + String(ch["name"])
			b.tooltip_text = "把选中对象改成「%s」" % String(ch["name"])
			b.custom_minimum_size = Vector2(0, 34)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.add_theme_color_override("font_color",
				Color.from_hsv(col.h, clampf(col.s * 1.12, 0.0, 1.0), 1.0))
			b.add_theme_color_override("font_pressed_color", Color.WHITE)
			b.add_theme_color_override("font_disabled_color", Color(0.62, 0.66, 0.72, 0.85))
			# 每个归属有**自己的**选中皮肤：底色是它本色压暗、描边是它本色
			b.add_theme_stylebox_override("pressed", _owner_pill_style(col, true))
			b.add_theme_stylebox_override("hover", _owner_pill_style(col, false))
			var id: int = int(ch["id"])
			b.pressed.connect(func() -> void:
				if _syncing or session == null:
					return
				session.set_selection_owner(id))
			flow.add_child(b)
			pills.append({"id": id, "button": b, "color": col})
		card["pills"] = pills
	_sync_owner_pills()


## 重建"摆放归属"药丸（对象页顶部）：中立 + 每个玩家槽位，一家一个颜色。
## 只在换图 / 加删槽位时重建，平时只同步高亮。
func _rebuild_place_pills() -> void:
	if session == null or _place_owner_row == null:
		return
	for c in _place_owner_row.get_children():
		_place_owner_row.remove_child(c)
		c.free()
	_place_pills.clear()
	for ch in session.owner_choices():
		var col: Color = ch["color"]
		var b := Button.new()
		b.theme_type_variation = &"EditorOwnerPill"
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.text = String(ch["name"])
		# 定宽 + 不拉伸：4 人图 5 颗药丸要能折成两行，不能一颗吃掉整行
		b.custom_minimum_size = Vector2(70, 26)
		b.add_theme_font_size_override("font_size", 12)
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.add_theme_color_override("font_color",
			Color.from_hsv(col.h, clampf(col.s * 1.12, 0.0, 1.0), 1.0))
		b.add_theme_color_override("font_pressed_color", Color.WHITE)
		b.add_theme_stylebox_override("pressed", _owner_pill_style(col, true))
		b.add_theme_stylebox_override("hover", _owner_pill_style(col, false))
		var id: int = int(ch["id"])
		b.tooltip_text = "之后摆放的单位 / 建筑归「%s」" % String(ch["name"])
		b.pressed.connect(func() -> void:
			if _syncing or session == null:
				return
			session.set_place_owner(id)
			_sync_place_pills())
		_place_owner_row.add_child(b)
		_place_pills.append(b)
		b.set_meta("owner_id", id)
	_sync_place_pills()


## 点亮当前摆放归属（和归属卡一样：选中的那颗按下去）
func _sync_place_pills() -> void:
	if session == null:
		return
	for b in _place_pills:
		if b == null or not is_instance_valid(b):
			continue
		b.set_pressed_no_signal(int(b.get_meta("owner_id", -99)) == int(session.place_owner))


func _owner_pill_style(col: Color, solid: bool) -> StyleBoxFlat:
	var k: float = 0.44 if solid else 0.26
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r * k, col.g * k, col.b * k, 1.0)
	sb.border_color = Color(col.r, col.g, col.b, 1.0 if solid else 0.70)
	sb.set_border_width_all(2 if solid else 1)
	sb.set_corner_radius_all(12)
	sb.corner_detail = 8
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


## 把当前选中对象的归属点亮（无选中时整排灰掉，但卡片留在原位，不跳）
func _sync_owner_pills() -> void:
	if session == null or _owner_cards.is_empty():
		return
	var has: bool = not session.selection.is_empty()
	var cur: int = int(session.selection[0].owner) if has else -1
	var col: Color = session.owner_color(cur)
	var txt: String = session.owner_display_name(cur) if has else "未选中"
	_syncing = true
	for card in _owner_cards:
		var value: Label = card["value"]
		value.text = txt
		value.add_theme_color_override("font_color", col.lightened(0.12))
		value.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.90))
		for p in card["pills"]:
			var b: Button = p["button"]
			b.button_pressed = has and int(p["id"]) == cur
			b.disabled = not has
			b.modulate = Color(1, 1, 1, 1.0) if has else Color(1, 1, 1, 0.55)
	_syncing = false


func _reset_scale() -> void:
	if session.selection.is_empty():
		return
	var s: float = session.selection[0].scale
	session.scale_selection(1.0 / maxf(0.05, s))


# --- 属性 ---

func _on_selection_changed() -> void:
	_syncing = true
	var n: int = session.selection.size()
	var has: bool = n > 0
	for b in _sel_buttons:
		b.disabled = not has
	if not has:
		_prop_hint.text = "没有选中对象。在视口里点一下对象，或用「对象」页放置。"
		for c in _prop_box.get_children():
			c.visible = false
		_syncing = false
		_sync_owner_pills()
		return
	_prop_hint.text = "已选中 %d 个（第一个：%s · %s）" % [n,
		String(session.selection[0].type_id),
		MapAssets.category_name(int(session.selection[0].category))]
	for c in _prop_box.get_children():
		c.visible = true
	var o: MapObject = session.selection[0]
	_pos_x.value = o.position.x
	_pos_z.value = o.position.z
	_rot_spin.value = rad_to_deg(o.rotation)
	_scale_spin.value = o.scale
	_syncing = false
	_sync_owner_pills()


func _selected_obj() -> MapObject:
	return null if session.selection.is_empty() else session.selection[0]


func _on_pos_changed(_v: float) -> void:
	if _syncing:
		return
	var o: MapObject = _selected_obj()
	if o == null:
		return
	session.set_selection_position(Vector3(_pos_x.value, o.position.y, _pos_z.value))


func _on_rot_changed(v: float) -> void:
	if _syncing:
		return
	session.set_selection_rotation(deg_to_rad(v))


func _on_scale_changed(v: float) -> void:
	if _syncing:
		return
	session.set_selection_scale(v)


# --- 区域 / 玩家 / 波次 ---

func _begin_region(shape: int) -> void:
	session.region_shape = shape
	session.region_purpose = _region_purpose.selected
	session.set_mode(2)
	session.status_changed.emit("在视口里画%s区域（多边形：连点，回车/右键结束）"
		% RegionDef.shape_name_of(shape))


func _refresh_regions() -> void:
	if session == null or session.def == null:
		return
	_syncing = true
	_region_list.clear()
	for r in session.def.regions:
		if r == null:
			continue
		_region_list.add_item("%s ｜ %s · %s" % [r.id, r.shape_name(), r.purpose_name()])
		_region_list.set_item_metadata(_region_list.item_count - 1, r.id)
	_refresh_region_options()
	if session.selected_region != null:
		for i in range(_region_list.item_count):
			if String(_region_list.get_item_metadata(i)) == session.selected_region.id:
				_region_list.select(i)
				_region_id.text = session.selected_region.id
				_region_purpose.select(session.selected_region.purpose)
				break
	_syncing = false


func _refresh_region_options() -> void:
	_wave_spawn.clear()
	_wave_target.clear()
	_wave_spawn.add_item("（无）")
	_wave_spawn.set_item_metadata(0, "")
	_wave_target.add_item("（无）")
	_wave_target.set_item_metadata(0, "")
	for r in session.def.regions:
		if r == null:
			continue
		_wave_spawn.add_item(r.id)
		_wave_spawn.set_item_metadata(_wave_spawn.item_count - 1, r.id)
		_wave_target.add_item(r.id)
		_wave_target.set_item_metadata(_wave_target.item_count - 1, r.id)


func _on_region_selected(index: int) -> void:
	var rid: String = String(_region_list.get_item_metadata(index))
	var r: RegionDef = session.def.region_by_id(rid)
	session.selected_region = r
	_syncing = true
	if r != null:
		_region_id.text = r.id
		_region_purpose.select(r.purpose)
	_syncing = false
	session.selection_changed.emit()


func _delete_region() -> void:
	if session.selected_region == null:
		session.status_changed.emit("先在列表里选一个区域")
		return
	session.delete_region(session.selected_region)
	_refresh_regions()


func _apply_region() -> void:
	if session.selected_region == null:
		session.status_changed.emit("先在列表里选一个区域")
		return
	session.update_region_props(session.selected_region, _region_id.text, _region_purpose.selected)
	_refresh_regions()


func _refresh_players() -> void:
	if session == null or session.def == null:
		return
	# 记住当前在看哪个槽位：每次属性刷新都跳回玩家 1 是最烦人的小毛病
	var keep_id: int = -9999
	if _player_opt.item_count > 0 and _player_opt.selected >= 0:
		keep_id = int(_player_opt.get_item_metadata(_player_opt.selected))
	_syncing = true
	_player_opt.clear()
	for p in session.def.players:
		if p == null:
			continue
		# 队伍号统一按 1 起显示（老地图里可能存着 0，直接显示"队伍 0"会让人以为坏了）
		_player_opt.add_item("玩家 %d · %s ｜ 队伍 %d" % [p.id + 1,
			session.faction_tag(p.faction), maxi(p.team, 1)])
		_player_opt.set_item_metadata(_player_opt.item_count - 1, p.id)
	var sel_idx: int = 0
	for i in range(_player_opt.item_count):
		if int(_player_opt.get_item_metadata(i)) == keep_id:
			sel_idx = i
			break
	if _player_opt.item_count > 0:
		_player_opt.select(sel_idx)
	_syncing = false
	_sync_player_fields()
	_sync_team_summary()


## 玩家页：加/删槽位 → 会话（带撤销）→ 三处归属药丸/列表一起刷
func _edit_player_count(add: bool) -> void:
	if _syncing or session == null or session.def == null:
		return
	if add:
		session.add_player()
	else:
		session.remove_player()
	_refresh_players()
	_rebuild_place_pills()
	_rebuild_owner_pills()
	_sync_team_summary()


func _sync_player_fields() -> void:
	var idx: int = _player_opt.selected
	if idx < 0 or session.def == null:
		return
	var p: PlayerSlot = session.def.player_slot(int(_player_opt.get_item_metadata(idx)))
	if p == null:
		return
	_syncing = true
	var fi: int = FACTION_KEYS.find(p.faction)
	_player_faction.select(fi if fi >= 0 else 0)
	_player_color.color = p.color
	_player_team.value = maxi(p.team, 1)
	_player_x.value = p.start_pos.x
	_player_z.value = p.start_pos.y
	_player_yaw.value = rad_to_deg(p.start_yaw)
	_player_gold.value = p.gold()
	_player_wood.value = p.wood()
	_syncing = false


func _on_player_selected(_i: int) -> void:
	_sync_player_fields()


func _set_player(key: String, value: Variant) -> void:
	if _syncing or session == null or session.def == null:
		return
	var idx: int = _player_opt.selected
	if idx < 0:
		return
	var p: PlayerSlot = session.def.player_slot(int(_player_opt.get_item_metadata(idx)))
	if p == null:
		return
	session.update_player(session.def.players.find(p), key, value)


func _focus_player() -> void:
	var idx: int = _player_opt.selected
	if idx < 0 or session.def == null:
		return
	var p: PlayerSlot = session.def.player_slot(int(_player_opt.get_item_metadata(idx)))
	if p == null:
		return
	_vp_call("focus_on", [Vector3(p.start_pos.x,
		session.def.height_at(p.start_pos.x, p.start_pos.y), p.start_pos.y)])


func _refresh_waves() -> void:
	if session == null or session.def == null:
		return
	_syncing = true
	_wave_list.clear()
	for i in range(session.def.waves.size()):
		var w: WaveDef = session.def.waves[i]
		if w == null:
			continue
		_wave_list.add_item("%.0fs ｜ %s ｜ %s" % [w.time, w.composition_text(),
			_difficulty_name(w.difficulty)])
		_wave_list.set_item_metadata(_wave_list.item_count - 1, i)
	_syncing = false


func _difficulty_name(d: int) -> String:
	match d:
		0:
			return "简单"
		1:
			return "普通"
		2:
			return "困难"
	return "?"


func _on_wave_selected(index: int) -> void:
	var i: int = int(_wave_list.get_item_metadata(index))
	session.selected_wave_index = i
	if i < 0 or i >= session.def.waves.size():
		return
	var w: WaveDef = session.def.waves[i]
	_syncing = true
	_wave_time.value = w.time
	_wave_diff.select(clampi(w.difficulty, 0, 2))
	_wave_comp.text = w.composition_text().replace("（空）", "")
	_select_option_by_meta(_wave_spawn, w.spawn_region)
	_select_option_by_meta(_wave_target, w.target_region)
	_syncing = false


func _select_option_by_meta(opt: OptionButton, value: String) -> void:
	for i in range(opt.item_count):
		var md: Variant = opt.get_item_metadata(i)
		if md == null:
			continue
		# str() 而不是 String()：String(null) 会直接抛 "Nonexistent 'String' constructor"
		if str(md) == value:
			opt.select(i)
			return
	if opt.item_count > 0:
		opt.select(0)


func _add_wave() -> void:
	var spawn: String = ""
	if _wave_spawn.item_count > 1:
		spawn = String(_wave_spawn.get_item_metadata(1))
	session.add_wave(spawn)
	_refresh_waves()


func _delete_wave() -> void:
	session.delete_wave(session.selected_wave_index)
	_refresh_waves()


func _apply_wave() -> void:
	var i: int = session.selected_wave_index
	if session.def == null or i < 0 or i >= session.def.waves.size():
		return
	session.update_wave(i, "time", _wave_time.value)
	session.update_wave(i, "difficulty", _wave_diff.selected)
	session.update_wave(i, "composition", _parse_composition(_wave_comp.text))
	session.update_wave(i, "spawn", String(_wave_spawn.get_item_metadata(_wave_spawn.selected)))
	session.update_wave(i, "target", String(_wave_target.get_item_metadata(_wave_target.selected)))
	_refresh_waves()
	session.status_changed.emit("波次已更新")


func _parse_composition(text: String) -> Dictionary:
	var out: Dictionary = {}
	for part in text.replace("，", ",").split(","):
		var p: String = part.strip_edges()
		if p.is_empty():
			continue
		var kv: PackedStringArray = p.split(":")
		if kv.size() == 2:
			var id: String = kv[0].strip_edges()
			var n: int = int(kv[1].strip_edges())
			if not id.is_empty() and n > 0:
				out[StringName(id)] = n
	return out


# --- 校验 ---

func _on_validation(result: Dictionary) -> void:
	if _val_text == null:
		return
	var errs: PackedStringArray = result.get("errors", PackedStringArray())
	var warns: PackedStringArray = result.get("warnings", PackedStringArray())
	var stats: Dictionary = result.get("stats", {})
	# BBCode 里也得吃 token：从语义色生成十六进制，别再手写 #7fe08a
	var c_ok: String = "#" + Spec.editor_ok().to_html(false)
	var c_bad: String = "#" + Spec.editor_bad().to_html(false)
	var c_warn: String = "#" + Spec.editor_warn().to_html(false)
	var c_dim: String = "#" + Spec.editor_text_sub().to_html(false)
	var txt: String = ""
	if errs.is_empty():
		txt += "[color=%s]✔ 五关全过（可以保存 / 测试）[/color]\n" % c_ok
	else:
		txt += "[color=%s]✘ %d 条错误（这张图还不能玩）[/color]\n" % [c_bad, errs.size()]
	for e in errs:
		txt += "  [color=%s]• %s[/color]\n" % [c_bad, e]
	if not warns.is_empty():
		txt += "\n[color=%s]⚠ %d 条提醒[/color]\n" % [c_warn, warns.size()]
		for w in warns:
			txt += "  [color=%s]• %s[/color]\n" % [c_warn, w]
	if not stats.is_empty():
		txt += "\n[color=%s]尺寸 %s ｜ 对象 %s ｜ 可走格 %s ｜ 金矿 %s ｜ 树 %s ｜ 高差 %.1f~%.1fm[/color]" % [
			c_dim, stats.get("size", "?"), stats.get("objects", "?"),
			stats.get("walkable_cells", "?"), stats.get("mines", "?"),
			stats.get("trees", "?"),
			float(stats.get("height_min", 0.0)), float(stats.get("height_max", 0.0)),
		]
	_val_text.text = txt
	_val_summary.text = "错误 %d ｜ 提醒 %d" % [errs.size(), warns.size()]
	_val_summary.theme_type_variation = &"EditorOk" if errs.is_empty() else &"EditorBad"


# ===========================================================================
# 工具
# ===========================================================================

func _on_def_changed(reason: String) -> void:
	if reason == "terrain_live" or reason == "terrain" or reason == "objects_move" \
			or reason == "objects_owner":
		return
	_refresh_players()
	_refresh_regions()
	_refresh_waves()
	_refresh_obj_count()
	_rebuild_owner_pills()
	_sync_biome_option()


## 调视口的方法（Dock 和主屏是兄弟节点，靠会话里的直接引用，不靠名字找）
func _vp_call(method: String, args: Array = []) -> void:
	if session == null or session.viewport == null:
		return
	if session.viewport.has_method(method):
		session.viewport.callv(method, args)


## 切页动效：内容淡入（统一 Tween，不写逐帧动画）
func _on_tab_changed(tab: int) -> void:
	var c: Control = get_tab_control(tab)
	if c == null:
		return
	c.modulate.a = 0.72
	var tw := create_tween()
	tw.tween_property(c, "modulate:a", 1.0, 0.12).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)