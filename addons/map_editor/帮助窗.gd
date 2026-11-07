@tool
extends Window
## **功能索引 / 帮助窗**：把编辑器里「哪个按钮在哪一页、改它该动哪个文件」列成一张可搜索的表。
##
## 为什么要有它（玩家 2026-11-07 口径：「页面太过朴素、按钮重复和繁琐，要适合人类方便调试、
## 查找功能，方便 agent 进行修改和查看功能」）：
##   · 人类：记不住 8 个页签里哪个按钮做什么，也不想翻文档；
##   · agent：改之前要先知道「这个按钮的实现在哪个文件」，否则只能全仓 grep。
## 所以这张表同时是**向导**和**代码地图**：一行 = 一个功能 = 入口 + 实现位置。
##
## ⚠ 本文件不写 class_name（AGENTS.md §二）；主屏用 preload 常量 + .call() 打开。

const Spec := preload("res://代码/界面/界面规格.gd")
const EDITOR_THEME := preload("res://addons/map_editor/编辑器主题.tres")

## 功能表：[分类, 功能, 怎么用, 代码位置]
## ⚠ 新增按钮/页面时**顺手加一行**，否则这张表会变成谎言。
const ROWS: Array = [
	["地图", "新建 / 打开 / 保存", "菜单栏 文件；Ctrl+S 保存", "主屏.gd -> _on_menu / 编辑会话.gd"],
	["地图", "测试地图", "快捷条「测试地图」：先存临时图再启动游戏", "编辑会话.gd -> test_map"],
	["地图", "校验", "快捷条「校验」：出生点 / 可达性 / 占位体检", "代码/地图核心/地图校验.gd"],
	["对象", "摆放归属（先选玩家）", "对象页顶部药丸：先点玩家，再摆单位 / 建筑", "停靠面板.gd -> _build_object_tab"],
	["对象", "放置分类 / 搜索", "对象页：单位 / 建筑 / 装饰 / 资源 + 搜索框", "停靠面板.gd -> _populate_assets"],
	["对象", "拖动 / 框选 / 复制粘贴", "手型（H / Esc 收工具）：左键框选、拖已选、Ctrl+C/V", "视口.gd + 编辑会话.gd"],
	["对象", "按类型替换", "对象页底部：选中一批 -> 下拉选类型 -> 替换", "停靠面板.gd -> _on_replace_pressed"],
	["玩家", "玩家槽位（最多 12）", "玩家页：＋添加玩家 / －删除最后一位", "停靠面板.gd -> _build_player_tab"],
	["玩家", "阵营（己方 / 敌方 / 中立 / 中立敌对）", "玩家页下拉：中立 = 和平（灰），中立敌对 = 野怪（灰红）", "编辑会话.gd -> owner_display_name"],
	["玩家", "队伍（盟友分组）", "玩家页「队伍」数字 + 队伍预设按钮", "停靠面板.gd -> _team_summary"],
	["单位卡", "改单位数值", "快捷条「单位卡」-> 左选卡 -> 右改 -> 保存", "addons/map_editor/卡片弹窗.gd"],
	["单位卡", "血量 / 蓝量 / 攻击 / 防御 / 移速 / 花费 / 训练时间 / 由谁训练", "卡片窗「单位卡」：分节表单", "卡片弹窗.gd -> _build_unit_form"],
	["建筑卡", "改建筑数值", "快捷条「建筑卡」-> 左选卡 -> 右改 -> 保存", "卡片弹窗.gd -> _build_building_form"],
	["建筑卡", "可训练 / 可研究清单", "建筑卡窗底部两排勾选框", "卡片弹窗.gd -> _save / _sync_unit_trains"],
	["野怪营地", "点锚点直接配置", "手型状态下**单击**已放置的巢穴 / 入口 / 折壳营地", "视口.gd -> _open_camp_dialog；营地弹窗.gd"],
	["野怪营地", "营地页批量配置", "右侧「营地」页：左选配置 -> 右改 -> 保存 -> 应用到选中锚点", "停靠面板.gd -> _build_camp_tab"],
	["野怪营地", "归属 / 时间点 / 补满", "营地页：所属玩家、首次刷新分钟、间隔分钟、补满秒", "代码/配置/卡/野怪营地/*.tres"],
	["地形", "抬高 / 压低 / 平滑 / 抹平", "右侧「地形」页的工具按钮", "停靠面板.gd -> _build_terrain_tab"],
	["地形", "地块涂刷（草 / 泥）", "地形页「地块」：笔刷半径 + 左键涂", "代码/地图核心/地图定义.gd -> mat_cells"],
	["区域", "画圆 / 矩形 / 多边形", "区域页工具 + 左键绘制", "停靠面板.gd -> _build_region_tab"],
	["属性", "改选中对象的归属 / 坐标 / 缩放", "「属性」页（选中对象后）", "停靠面板.gd -> _refresh_props"],
	["主题", "改编辑器配色 / 字号", "改 界面规格.gd 后跑 工具/生成编辑器主题.gd", "工具/生成编辑器主题.gd"],
	["自检", "编辑器链路自检（21 项）", "godot --headless --editor --path . -- --map-editor-selftest", "主屏.gd -> _selftest"],
	["自检", "地图数据自检（167 项）", "godot --headless --path . --quit-after 200 -- --map-editor-test", "代码/测试/地图编辑器自检.gd"],
]

var session = null
var _built: bool = false
var _filter: LineEdit
var _tree: Tree
var _count: Label


func setup(p_session) -> void:
	session = p_session
	if _built:
		return
	_built = true
	title = "功能索引 · 编辑器帮助"
	exclusive = false
	transient = true
	min_size = Vector2i(720, 520)
	close_requested.connect(func() -> void: hide())
	theme = EDITOR_THEME
	var panel := PanelContainer.new()
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	v.add_child(head)
	head.add_child(Spec.editor_label("功能索引", &"EditorTitle"))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	head.add_child(Spec.editor_label("点一行看路径；上框输入关键字过滤", &"EditorHint"))

	_filter = LineEdit.new()
	_filter.placeholder_text = "搜索功能 / 文件 / 关键词（例如：营地、卡片、出生点）…"
	_filter.clear_button_enabled = true
	_filter.text_changed.connect(func(_t: String) -> void: _fill())
	v.add_child(_filter)

	_tree = Tree.new()
	_tree.columns = 4
	_tree.set_column_title(0, "分类")
	_tree.set_column_title(1, "功能")
	_tree.set_column_title(2, "怎么用")
	_tree.set_column_title(3, "代码位置")
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 86)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 168)
	_tree.set_column_expand(2, true)
	_tree.set_column_expand(3, true)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_tree)

	_count = Spec.editor_label("", &"EditorHint")
	v.add_child(_count)


func open() -> void:
	if not _built:
		return
	_filter.text = ""
	_fill()
	popup_centered()
	size = Vector2i(maxi(size.x, 920), maxi(size.y, 560))
	if get_parent() != null:
		var pr: Rect2 = get_parent().get_viewport_rect()
		position = Vector2i(pr.position + (pr.size - Vector2(size)) * 0.5)


func _fill() -> void:
	if _tree == null:
		return
	_tree.clear()
	var root := _tree.create_item()
	var needle: String = _filter.text.strip_edges().to_lower() if _filter != null else ""
	var shown: int = 0
	for r in ROWS:
		var row: Array = r
		if row.size() < 4:
			continue
		var hay: String = ("%s %s %s" % [row[0], row[1], row[2]]).to_lower()
		if not needle.is_empty() and not hay.contains(needle) \
				and not String(row[3]).to_lower().contains(needle):
			continue
		var it := _tree.create_item(root)
		for c in 4:
			it.set_text(c, String(row[c]))
		it.set_tooltip_text(3, String(row[3]))
		shown += 1
	if _count != null:
		_count.text = "%d / %d 条功能（新增按钮时请顺手在 帮助窗.gd 的 ROWS 里加一行）" % [shown, ROWS.size()]
