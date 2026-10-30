@tool
extends TabContainer
## **地图工具面板（Dock）** —— 仿魔兽「工具面板」的六页：
##
##   地形   ：应用纹理（草/土/岩/沙）＋ 应用高度（抬升/降低/平滑/压平）＋ 水面 ＋ 刷子
##   对象   ：单位 / 建筑 / 装饰 / 资源 四个分类，装饰只收自然物并按子类筛选
##   区域   ：画圆/矩形/多边形 ＋ 用途 ＋ 玩家槽位 ＋ 波次
##   属性   ：选中对象的数据
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
const FACTION_KEYS: Array[String] = ["player", "enemy", "neutral"]
const FACTION_NAMES: Array[String] = ["己方（player）", "敌方（enemy）", "中立（neutral）"]
var _player_color: ColorPickerButton
var _player_team: SpinBox
var _player_x: SpinBox
var _player_z: SpinBox
var _player_yaw: SpinBox
var _player_gold: SpinBox
var _player_wood: SpinBox
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
	_add_tab(_build_prop_tab(), "属性")
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
	v.add_child(_title("放置分类"))
	var cat_row := _hbox()
	for c in [MapObject.Category.UNIT, MapObject.Category.BUILDING,
			MapObject.Category.DOODAD, MapObject.Category.RESOURCE]:
		var b := Spec.editor_button(MapAssets.category_name(c))
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
	_asset_search.placeholder_text = "搜索装饰（名字 / id）…"
	_asset_search.clear_button_enabled = true
	_asset_search.text_changed.connect(func(_t: String) -> void: _populate_assets())
	v.add_child(_asset_search)

	_asset_list = ItemList.new()
	# 列表别吃掉半屏：底下「选中对象 / 归属」必须留在第一屏里，不然又得滚
	_asset_list.custom_minimum_size = Vector2(0, 150)
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

	# ---------------------------------------------------------------
	# 归属卡：**位置钉死在「选中对象」正下方，字号最大、色条最亮**
	# ---------------------------------------------------------------
	_build_owner_card(v)

	var r1 := _hbox()
	_sel_buttons.append(_add_small_button(r1, "复制", func() -> void: session.copy_selection()))
	# 粘贴不需要选中，单独一个，别跟着"无选中"一起灰掉
	_add_small_button(r1, "粘贴", func() -> void: session.paste_clipboard())
	_sel_buttons.append(_add_small_button(r1, "删除", func() -> void: session.delete_selection()))
	v.add_child(r1)

	var r2 := _hbox()
	_sel_buttons.append(_add_small_button(r2, "旋转 -15°", func() -> void: session.rotate_selection(-15.0)))
	_sel_buttons.append(_add_small_button(r2, "旋转 +15°", func() -> void: session.rotate_selection(15.0)))
	_sel_buttons.append(_add_small_button(r2, "随机朝向", func() -> void: session.randomize_rotation()))
	v.add_child(r2)

	var r3 := _hbox()
	_sel_buttons.append(_add_small_button(r3, "缩小", func() -> void: session.scale_selection(0.9)))
	_sel_buttons.append(_add_small_button(r3, "放大", func() -> void: session.scale_selection(1.1)))
	_sel_buttons.append(_add_small_button(r3, "还原 1.0", func() -> void: _reset_scale()))
	v.add_child(r3)

	v.add_child(HSeparator.new())
	v.add_child(_title("按类型替换"))
	_replace_opt = OptionButton.new()
	v.add_child(_replace_opt)
	var br := Spec.editor_button("把选中对象换成上面的类型")
	br.pressed.connect(_on_replace_pressed)
	v.add_child(br)
	_sel_buttons.append(br)
	return v


func _add_small_button(parent: HBoxContainer, text: String, cb: Callable) -> Button:
	var b := Spec.editor_button(text)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	v.add_child(_title("玩家槽位"))
	_player_opt = OptionButton.new()
	v.add_child(_player_opt)
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
	_player_team = _spin(0, 3, 1)
	# 队伍 = 盟友分组：同队互为盟友，异队互相敌对（阵营决定 AI 行为，队伍决定敌我）
	_player_team.tooltip_text = "队伍相同的玩家互为盟友；不同队伍互相敌对。"
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
	_asset_search.placeholder_text = "搜索装饰（名字 / id）…" \
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
			_empty_hint.text = "这个分类没有匹配项。"


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
	_obj_count.text = "全图 %d 个对象 ｜ 本类 %d 个" % [
		session.def.objects.size(),
		session.def.objects_of(int(session.asset_category)).size()]


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
		_player_opt.add_item("玩家 %d · %s ｜ 队伍 %d" % [p.id + 1,
			session.faction_tag(p.faction), p.team])
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
	_player_team.value = p.team
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
		if String(opt.get_item_metadata(i)) == value:
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