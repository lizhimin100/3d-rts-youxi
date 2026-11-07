@tool
extends RefCounted
## **编辑器皮肤（二次重做，2026-11-07）** —— 把「冷灰蓝 Godot 默认」整屏换成「深铁石底 + 金线」。
##
## 为什么单开这一层，而不是去改 代码/界面/界面规格.gd：
##   · build_editor_theme() 是**游戏与编辑器共用**的 token 编译入口，动它会波及 HUD；
##   · 本工程规矩：插件只准改 addons/map_editor/**。
## 所以皮肤在这里**就地改写** 编辑器主题.tres 那个 Theme 实例（加类型/换皮肤），
## .tres 的 resource_path 不变 —— 自检里「主屏与 Dock 挂的是同一个主题资源」照旧成立，
## 而且就算有人重跑 工具/生成编辑器主题.gd 把 .tres 刷回冷色，运行时也会再被这里盖回来。
##
## 三件事只在这里做，别处不许再写 StyleBox：
##   1. 调色板（IRON / STONE / GOLD / RED 四组 token）；
##   2. 控件皮肤（按钮四态 + 标签页 + 列表 + 输入框 + 滑条 + 菜单 + 滚动条）；
##   3. 控件工厂（tool_button / layer_button / section / dot）。

const Spec := preload("res://代码/界面/界面规格.gd")

# ===========================================================================
# 调色板（8px 栅格之外，唯一的"设计 token"）
# ===========================================================================
#
# 取色口径：底=深铁（比中性灰偏暖 2~3 度），描边=哑金，文字=暖白（不是纯白，
# 纯白在深底上会发蓝）；危险操作=暗红，只在不可逆动作上出现。

const BG_WINDOW := Color(0.047, 0.049, 0.055)
const BG_PANEL := Color(0.082, 0.084, 0.094)
const BG_CTRL := Color(0.118, 0.118, 0.129)
const BG_HOVER := Color(0.169, 0.161, 0.145)
const BG_PRESS := Color(0.071, 0.067, 0.055)
const STONE := Color(0.153, 0.145, 0.125)
const STONE_DEEP := Color(0.106, 0.102, 0.090)
const LINE := Color(0.255, 0.243, 0.216)
const LINE_SOFT := Color(0.180, 0.176, 0.165)
const GOLD := Color(0.784, 0.639, 0.302)
const GOLD_HI := Color(0.949, 0.831, 0.545)
const GOLD_DIM := Color(0.478, 0.388, 0.180)
const TEXT := Color(0.886, 0.863, 0.812)
const TEXT_SUB := Color(0.678, 0.655, 0.604)
const TEXT_DIM := Color(0.451, 0.443, 0.424)
const RED := Color(0.702, 0.271, 0.235)
const RED_DIM := Color(0.376, 0.157, 0.137)
const RED_HI := Color(0.910, 0.545, 0.502)

## 控件尺寸（8px 栅格）：顶部快捷条 34 / 左侧层栏 46 / Dock 内 30
##
## ★ 2026-11-07 二轮：快捷条 40 → 34。40 高的格子里塞 14px 字 + 28px 图标，
##   每一格都是"字浮在盒子里"；34 之后一条工具带读起来像**一行命令**，
##   而不是"十三个并排的盒子"，纵向还白给视口 6px。
const H_QUICK := 34.0
const H_LAYER := 46.0
const H_SMALL := 30.0
## 图标三档（不是随手填的，比例 = 按钮高 × 0.55，照 HUD 命令卡量的）：
##   快捷条 20 —— 图标只做识别锚点，视觉重量让给文字；
##   层栏 24 —— 层是大分类，图标要在扫视时先被认出来；
##   Dock 16 —— 行首类型标记，够认就行。
const ICON := 20.0
const ICON_LAYER := 24.0
const ICON_SMALL := 16.0

## 按钮静息边 = 金的 28%。纯灰线（旧的 LINE）在深底上会读成"没画完的框"；
## 一条暖线才像"石头压着金边"——这就是「深石板 + 金浮雕」里"金"的最小剂量。
const LINE_GOLD := Color(0.784, 0.639, 0.302, 0.28)
## 按下 / 选中：整块填金褐，而不是只换描边色。
## 工具条上十几个盒子长得一样时，只有"整块变色"能在余光里分辨当前工具。
const BG_CHECKED := Color(0.267, 0.224, 0.128)

static var _tex_cache: Dictionary = {}


# ===========================================================================
# 一、Theme：把皮肤就地盖到编辑器主题上
# ===========================================================================

static func apply(th: Theme) -> void:
	if th == null:
		return
	th.default_font_size = Spec.FS_BODY
	_panels(th)
	_buttons(th)
	_tabs(th)
	_lists(th)
	_inputs(th)
	_scrollbars(th)
	_menus(th)
	_misc(th)
	_variations(th)


static func _box(fill: Color, line: Color, bw: int, radius: int,
		pad_x: float, pad_y: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = line
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 8
	sb.anti_aliasing = true
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


## 一条 1px 的金线（面板分隔/分节线用；不是控件，是画出来的）
static func hairline(alpha: float = 0.22, px: float = 1.0) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(GOLD.r, GOLD.g, GOLD.b, alpha)
	r.custom_minimum_size = Vector2(0.0, px)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# --- 面板 ---
static func _panels(th: Theme) -> void:
	var panel := _box(BG_PANEL, LINE_SOFT, 1, 4, 10.0, 8.0)
	th.set_stylebox("panel", "PanelContainer", panel)
	th.set_stylebox("panel", "Panel", _box(BG_WINDOW, LINE_SOFT, 1, 4, 10.0, 8.0))
	th.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	# TabContainer 的底板：比面板再深一档，让"页签条"和"页内容"分层
	var tc := _box(BG_PANEL, LINE_SOFT, 1, 4, 10.0, 8.0)
	tc.border_width_top = 0
	th.set_stylebox("panel", "TabContainer", tc)


# --- 按钮 ---
static func _buttons(th: Theme) -> void:
	# 基础 Button：深铁底 + 哑金细边；hover 亮底金边；pressed 压暗亮金边
	var normal := _box(BG_CTRL, LINE_GOLD, 1, 3, 9.0, 5.0)
	var hover := _box(BG_HOVER, GOLD_DIM, 1, 3, 9.0, 5.0)
	var pressed := _box(BG_CHECKED, GOLD, 1, 3, 9.0, 5.0)
	var disabled := _box(Color(BG_CTRL.r, BG_CTRL.g, BG_CTRL.b, 0.55),
		Color(LINE.r, LINE.g, LINE.b, 0.35), 1, 3, 9.0, 5.0)
	th.set_stylebox("normal", "Button", normal)
	th.set_stylebox("hover", "Button", hover)
	th.set_stylebox("pressed", "Button", pressed)
	th.set_stylebox("disabled", "Button", disabled)
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", TEXT)
	th.set_color("font_hover_color", "Button", GOLD_HI)
	th.set_color("font_pressed_color", "Button", GOLD_HI)
	th.set_color("font_hover_pressed_color", "Button", GOLD_HI)
	th.set_color("font_disabled_color", "Button", Color(TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 0.85))
	th.set_color("font_focus_color", "Button", TEXT)
	th.set_font_size("font_size", "Button", Spec.FS_BODY)
	# 图标跟着字色走（单色 SVG 靠 modulate）
	th.set_color("icon_normal_color", "Button", TEXT_SUB)
	th.set_color("icon_hover_color", "Button", GOLD_HI)
	th.set_color("icon_pressed_color", "Button", GOLD_HI)
	th.set_color("icon_disabled_color", "Button", TEXT_DIM)
	th.set_constant("h_separation", "Button", 8)


# --- 标签页：像"标签页"，不像默认页签 ---
static func _tabs(th: Theme) -> void:
	var unsel := _box(BG_WINDOW, LINE_SOFT, 1, 6, 10.0, 7.0)
	unsel.border_width_bottom = 0
	unsel.corner_radius_bottom_left = 0
	unsel.corner_radius_bottom_right = 0
	var sel := _box(STONE, GOLD, 1, 6, 12.0, 7.0)
	sel.border_width_top = 2
	sel.border_width_bottom = 0
	sel.corner_radius_bottom_left = 0
	sel.corner_radius_bottom_right = 0
	var hov := _box(BG_CTRL, GOLD_DIM, 1, 6, 10.0, 7.0)
	hov.border_width_bottom = 0
	hov.corner_radius_bottom_left = 0
	hov.corner_radius_bottom_right = 0
	th.set_stylebox("tab_selected", "TabContainer", sel)
	th.set_stylebox("tab_unselected", "TabContainer", unsel)
	th.set_stylebox("tab_hovered", "TabContainer", hov)
	th.set_stylebox("tab_disabled", "TabContainer", unsel)
	th.set_stylebox("tab_focus", "TabContainer", StyleBoxEmpty.new())
	th.set_stylebox("tabbar_background", "TabContainer", StyleBoxEmpty.new())
	th.set_color("font_selected_color", "TabContainer", GOLD_HI)
	th.set_color("font_unselected_color", "TabContainer", TEXT_SUB)
	th.set_color("font_hovered_color", "TabContainer", TEXT)
	th.set_color("font_disabled_color", "TabContainer", TEXT_DIM)
	th.set_font_size("font_size", "TabContainer", Spec.FS_BODY)
	th.set_constant("side_margin", "TabContainer", 6)
	th.set_constant("h_separation", "TabContainer", 2)


# --- 列表 / 树 ---
static func _lists(th: Theme) -> void:
	# 行选中 = 金色高亮条（左 3px 亮金 + 金底 18%），不是默认蓝条
	var row_sel := StyleBoxFlat.new()
	row_sel.bg_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.18)
	row_sel.border_color = GOLD
	row_sel.set_border_width_all(0)
	row_sel.border_width_left = 3
	row_sel.set_corner_radius_all(2)
	row_sel.content_margin_left = 8.0
	row_sel.content_margin_right = 6.0
	row_sel.content_margin_top = 3.0
	row_sel.content_margin_bottom = 3.0

	var row_hover := StyleBoxFlat.new()
	row_hover.bg_color = Color(1, 1, 1, 0.055)
	row_hover.set_corner_radius_all(2)
	row_hover.content_margin_left = 8.0
	row_hover.content_margin_right = 6.0

	var panel := _box(BG_WINDOW, LINE_SOFT, 1, 4, 4.0, 4.0)
	for type in ["ItemList", "Tree"]:
		th.set_stylebox("panel", type, panel)
		th.set_stylebox("focus", type, StyleBoxEmpty.new())
		th.set_stylebox("selected", type, row_sel)
		th.set_stylebox("selected_focus", type, row_sel)
		th.set_stylebox("hovered", type, row_hover)
		th.set_stylebox("cursor", type, _box(Color(GOLD.r, GOLD.g, GOLD.b, 0.10), GOLD_DIM, 1, 2, 4.0, 2.0))
		th.set_stylebox("cursor_unfocused", type, _box(Color(GOLD.r, GOLD.g, GOLD.b, 0.06), LINE_SOFT, 1, 2, 4.0, 2.0))
		th.set_color("font_color", type, TEXT)
		th.set_color("font_selected_color", type, GOLD_HI)
		th.set_color("font_hovered_color", type, GOLD_HI)
		th.set_color("font_hovered_selected_color", type, GOLD_HI)
		th.set_color("guide_color", type, Color(LINE.r, LINE.g, LINE.b, 0.22))
		th.set_color("relationship_line_color", type, Color(LINE.r, LINE.g, LINE.b, 0.32))
		th.set_font_size("font_size", type, Spec.FS_BODY)
		th.set_constant("v_separation", type, 6)
		th.set_constant("h_separation", type, 8)
		th.set_constant("icon_margin", type, 8)
		th.set_constant("line_separation", type, 4)


# --- 输入框 / 数值框 ---
static func _inputs(th: Theme) -> void:
	var base := _box(BG_WINDOW, LINE_SOFT, 1, 4, 8.0, 5.0)
	var focus := _box(BG_WINDOW, GOLD, 1, 4, 8.0, 5.0)
	th.set_stylebox("normal", "LineEdit", base)
	th.set_stylebox("focus", "LineEdit", focus)
	th.set_stylebox("read_only", "LineEdit", base)
	th.set_color("font_color", "LineEdit", TEXT)
	th.set_color("font_placeholder_color", "LineEdit", TEXT_DIM)
	th.set_color("caret_color", "LineEdit", GOLD_HI)
	th.set_color("selection_color", "LineEdit", Color(GOLD.r, GOLD.g, GOLD.b, 0.30))
	th.set_color("clear_button_color", "LineEdit", TEXT_SUB)
	th.set_color("clear_button_color_pressed", "LineEdit", GOLD_HI)
	th.set_font_size("font_size", "LineEdit", Spec.FS_BODY)
	th.set_constant("minimum_character_width", "LineEdit", 4)

	# SpinBox：上下箭头两个小块，别让它像"贴了张默认贴纸"
	var up := _box(BG_CTRL, LINE_SOFT, 1, 3, 2.0, 0.0)
	var up_h := _box(BG_HOVER, GOLD_DIM, 1, 3, 2.0, 0.0)
	var up_p := _box(BG_PRESS, GOLD, 1, 3, 2.0, 0.0)
	for nm in ["up_background", "down_background"]:
		th.set_stylebox(nm, "SpinBox", up)
		th.set_stylebox(nm.replace("background", "hover"), "SpinBox", up_h)
		th.set_stylebox(nm.replace("background", "pressed"), "SpinBox", up_p)
		th.set_stylebox(nm.replace("background", "disabled"), "SpinBox", up)
	th.set_color("up_icon_color", "SpinBox", TEXT_SUB)
	th.set_color("down_icon_color", "SpinBox", TEXT_SUB)
	th.set_constant("field_height", "SpinBox", 30)
	th.set_constant("buttons_width", "SpinBox", 18)
	th.set_constant("buttons_vertical_separation", "SpinBox", 1)
	th.set_font_size("font_size", "SpinBox", Spec.FS_BODY)

	# 滑条：细槽 + 金把握点（grabber 由 _grabber_tex 生成，见 _misc）
	var groove := _box(Color(0, 0, 0, 0.55), LINE_SOFT, 1, 3, 0.0, 0.0)
	groove.content_margin_top = 4.0
	groove.content_margin_bottom = 4.0
	th.set_stylebox("slider", "HSlider", groove)
	var fill := _box(Color(GOLD.r, GOLD.g, GOLD.b, 0.55), Color(0, 0, 0, 0), 0, 3, 0.0, 0.0)
	fill.content_margin_top = 4.0
	fill.content_margin_bottom = 4.0
	th.set_stylebox("grabber_area", "HSlider", fill)
	var fill_hi := _box(GOLD, Color(0, 0, 0, 0), 0, 3, 0.0, 0.0)
	fill_hi.content_margin_top = 4.0
	fill_hi.content_margin_bottom = 4.0
	th.set_stylebox("grabber_area_highlight", "HSlider", fill_hi)

	# 勾选框
	th.set_stylebox("normal", "CheckBox", StyleBoxEmpty.new())
	th.set_stylebox("pressed", "CheckBox", StyleBoxEmpty.new())
	th.set_stylebox("hover", "CheckBox", StyleBoxEmpty.new())
	th.set_stylebox("hover_pressed", "CheckBox", StyleBoxEmpty.new())
	th.set_color("font_color", "CheckBox", TEXT)
	th.set_color("font_hover_color", "CheckBox", GOLD_HI)
	th.set_color("font_pressed_color", "CheckBox", GOLD_HI)
	th.set_font_size("font_size", "CheckBox", Spec.FS_BODY)
	th.set_color("font_color", "CheckButton", TEXT)
	th.set_color("font_hover_color", "CheckButton", GOLD_HI)
	th.set_color("font_pressed_color", "CheckButton", GOLD_HI)
	th.set_font_size("font_size", "CheckButton", Spec.FS_BODY)


# --- 滚动条：细金条 ---
static func _scrollbars(th: Theme) -> void:
	for type in ["VScrollBar", "HScrollBar"]:
		var scroll := StyleBoxFlat.new()
		scroll.bg_color = Color(0, 0, 0, 0.25)
		scroll.set_content_margin_all(3.0)
		th.set_stylebox("scroll", type, scroll)
		th.set_stylebox("scroll_focus", type, scroll)
		th.set_stylebox("grabber", type, _box(Color(GOLD.r, GOLD.g, GOLD.b, 0.55), Color(0, 0, 0, 0), 0, 3, 3.0, 3.0))
		th.set_stylebox("grabber_highlight", type, _box(GOLD_HI, Color(0, 0, 0, 0), 0, 3, 3.0, 3.0))
		th.set_stylebox("grabber_pressed", type, _box(GOLD, Color(0, 0, 0, 0), 0, 3, 3.0, 3.0))


# --- 菜单 / 提示气泡 ---
static func _menus(th: Theme) -> void:
	th.set_stylebox("panel", "PopupMenu", _box(BG_PANEL, LINE, 1, 4, 6.0, 6.0))
	th.set_stylebox("hover", "PopupMenu", _box(Color(GOLD.r, GOLD.g, GOLD.b, 0.16), GOLD_DIM, 1, 3, 8.0, 4.0))
	th.set_stylebox("separator", "PopupMenu", StyleBoxLine.new())
	th.set_color("font_color", "PopupMenu", TEXT)
	th.set_color("font_hover_color", "PopupMenu", GOLD_HI)
	th.set_color("font_disabled_color", "PopupMenu", TEXT_DIM)
	th.set_color("font_accelerator_color", "PopupMenu", TEXT_DIM)
	th.set_font_size("font_size", "PopupMenu", Spec.FS_BODY)
	th.set_constant("v_separation", "PopupMenu", 6)
	th.set_constant("item_start_padding", "PopupMenu", 10)
	th.set_constant("item_end_padding", "PopupMenu", 10)

	th.set_stylebox("panel", "TooltipPanel", _box(BG_PANEL, GOLD_DIM, 1, 4, 8.0, 6.0))
	th.set_color("font_color", "TooltipLabel", TEXT)
	th.set_font_size("font_size", "TooltipLabel", Spec.FS_BODY)


# --- 其它（文字/分隔线/滑条把手/下拉箭头）---
static func _misc(th: Theme) -> void:
	th.set_color("font_color", "Label", TEXT)
	th.set_font_size("font_size", "Label", Spec.FS_BODY)
	th.set_color("default_color", "RichTextLabel", TEXT)
	th.set_font_size("normal_font_size", "RichTextLabel", Spec.FS_BODY)
	th.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())

	var sep := StyleBoxLine.new()
	sep.color = Color(GOLD.r, GOLD.g, GOLD.b, 0.20)
	sep.thickness = 1
	th.set_stylebox("separator", "HSeparator", sep)
	th.set_stylebox("separator", "VSeparator", sep)
	th.set_constant("separation", "HSeparator", 10)
	th.set_constant("separation", "VSeparator", 10)

	var g: Texture2D = _grabber_tex()
	if g != null:
		th.set_icon("grabber", "HSlider", g)
		th.set_icon("grabber_highlight", "HSlider", g)
		th.set_icon("grabber_disabled", "HSlider", g)

	# OptionButton 的箭头留白别贴着字
	th.set_constant("arrow_margin", "OptionButton", 8)
	th.set_color("arrow_color", "OptionButton", TEXT_SUB)
	th.set_color("arrow_hover_color", "OptionButton", GOLD_HI)
	th.set_color("arrow_pressed_color", "OptionButton", GOLD_HI)


# --- 类型变体 ---
static func _variations(th: Theme) -> void:
	# ① 顶部快捷条 / 左侧层栏 / Dock 小按钮：三档尺寸同一套语言
	_tool_variation(th, &"EditorTool", H_QUICK, 9.0, 5.0, ICON)
	_tool_variation(th, &"EditorLayer", H_LAYER, 9.0, 6.0, ICON_LAYER)
	_tool_variation(th, &"EditorSmall", H_SMALL, 8.0, 4.0, ICON_SMALL)
	_danger_variation(th, &"EditorDanger", H_QUICK, 9.0, 5.0)
	_danger_variation(th, &"EditorSmallDanger", H_SMALL, 8.0, 4.0)
	_primary_variation(th, &"EditorPrimary", H_QUICK, 9.0, 5.0)
	_primary_variation(th, &"EditorSmallPrimary", H_SMALL, 8.0, 4.0)

	# ② 顶部菜单：扁平文字，hover 才浮出金底
	th.set_type_variation("EditorMenu", "MenuButton")
	th.set_stylebox("normal", "EditorMenu", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 10.0, 5.0))
	th.set_stylebox("hover", "EditorMenu", _box(Color(GOLD.r, GOLD.g, GOLD.b, 0.14), GOLD_DIM, 1, 4, 10.0, 5.0))
	th.set_stylebox("pressed", "EditorMenu", _box(Color(GOLD.r, GOLD.g, GOLD.b, 0.20), GOLD, 1, 4, 10.0, 5.0))
	th.set_stylebox("disabled", "EditorMenu", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 10.0, 5.0))
	th.set_stylebox("focus", "EditorMenu", StyleBoxEmpty.new())
	th.set_color("font_color", "EditorMenu", TEXT_SUB)
	th.set_color("font_hover_color", "EditorMenu", GOLD_HI)
	th.set_color("font_pressed_color", "EditorMenu", GOLD_HI)
	th.set_font_size("font_size", "EditorMenu", Spec.FS_BODY)

	# ③ 分节标题（12px 金字）
	_label_var(th, &"EditorSection", GOLD, Spec.FS_CAPTION)
	_label_var(th, &"EditorGroupCaption", Color(GOLD_DIM.r, GOLD_DIM.g, GOLD_DIM.b, 0.95), Spec.FS_CAPTION)
	_label_var(th, &"EditorTitle", GOLD_HI, Spec.FS_BODY)
	_label_var(th, &"EditorHint", TEXT_DIM, Spec.FS_CAPTION)
	_label_var(th, &"EditorAccent", GOLD_HI, Spec.FS_BODY)
	_label_var(th, &"EditorOk", Color(0.46, 0.83, 0.50), Spec.FS_BODY)
	_label_var(th, &"EditorBad", RED_HI, Spec.FS_BODY)
	_label_var(th, &"EditorWarn", Color(0.95, 0.78, 0.42), Spec.FS_BODY)
	_label_var(th, &"EditorCaption", TEXT_DIM, Spec.FS_CAPTION)
	_label_var(th, &"EditorSub", TEXT_SUB, Spec.FS_BODY)

	# ④ 顶部条 / 状态栏的整条底板
	th.set_type_variation("EditorTopBar", "PanelContainer")
	var top := _box(Color(0.063, 0.063, 0.071), Color(GOLD.r, GOLD.g, GOLD.b, 0.16), 1, 0, 10.0, 6.0)
	top.border_width_top = 0
	top.border_width_left = 0
	top.border_width_right = 0
	th.set_stylebox("panel", "EditorTopBar", top)
	# 层栏底的整块石板：比视口深一档 + 右侧一条极淡金线，
	# 让左栏和视口"分开"但不抢眼（视口才是主角）。
	th.set_type_variation("EditorRailBack", "Panel")
	var railb := _box(Color(0.058, 0.058, 0.066), Color(GOLD.r, GOLD.g, GOLD.b, 0.14), 0, 0, 0.0, 0.0)
	railb.border_width_right = 1
	th.set_stylebox("panel", "EditorRailBack", railb)

	th.set_type_variation("EditorStatusBar", "PanelContainer")
	var stat := _box(Color(0.055, 0.055, 0.063), Color(GOLD.r, GOLD.g, GOLD.b, 0.14), 1, 0, 12.0, 5.0)
	stat.border_width_bottom = 0
	stat.border_width_left = 0
	stat.border_width_right = 0
	th.set_stylebox("panel", "EditorStatusBar", stat)

	# ⑤ 视口角标 / 对话框 / 归属卡（沿用旧变体名，换皮不换名）
	th.set_type_variation("EditorBadge", "PanelContainer")
	th.set_stylebox("panel", "EditorBadge", _box(Color(0.04, 0.04, 0.045, 0.86), GOLD_DIM, 1, 3, 8.0, 4.0))
	th.set_type_variation("EditorDialog", "PanelContainer")
	var dlg := _box(Color(0.078, 0.078, 0.086, 0.98), GOLD_DIM, 1, 6, 16.0, 14.0)
	dlg.shadow_color = Color(0, 0, 0, 0.55)
	dlg.shadow_size = 12
	th.set_stylebox("panel", "EditorDialog", dlg)
	th.set_type_variation("EditorCard", "PanelContainer")
	th.set_stylebox("panel", "EditorCard", _box(BG_PANEL, LINE_SOFT, 1, 4, 10.0, 8.0))

	th.set_type_variation("EditorOwnerCard", "PanelContainer")
	var owner := _box(Color(0.09, 0.086, 0.078, 0.96), GOLD, 1, 4, 10.0, 8.0)
	owner.border_width_left = 3
	th.set_stylebox("panel", "EditorOwnerCard", owner)
	_label_var(th, &"EditorOwnerValue", TEXT, Spec.FS_VALUE)
	th.set_color("font_outline_color", "EditorOwnerValue", Color(0, 0, 0, 0.85))
	th.set_constant("outline_size", "EditorOwnerValue", 4)

	th.set_type_variation("EditorSeparator", "HSeparator")
	var sl := StyleBoxLine.new()
	sl.color = Color(GOLD.r, GOLD.g, GOLD.b, 0.22)
	sl.thickness = 1
	th.set_stylebox("separator", "EditorSeparator", sl)

	# ⑥ 归属药丸：中性深底 + 细金边（球员本色仍由控件自己的 override 覆盖）
	th.set_type_variation("EditorOwnerPill", "Button")
	# 方角（radius 3）：胶囊是全界面唯一的长圆形，放在一片方角石板里像外来件。
	var pill := _box(Color(0.09, 0.09, 0.098, 0.92), LINE_GOLD, 1, 3, 8.0, 4.0)
	var pill_h := _box(BG_HOVER, GOLD_DIM, 1, 3, 8.0, 4.0)
	var pill_p := _box(BG_CHECKED, GOLD, 1, 3, 8.0, 4.0)
	th.set_stylebox("normal", "EditorOwnerPill", pill)
	th.set_stylebox("hover", "EditorOwnerPill", pill_h)
	th.set_stylebox("pressed", "EditorOwnerPill", pill_p)
	th.set_stylebox("hover_pressed", "EditorOwnerPill", pill_p)
	th.set_stylebox("disabled", "EditorOwnerPill", pill)
	th.set_stylebox("focus", "EditorOwnerPill", StyleBoxEmpty.new())
	th.set_color("font_color", "EditorOwnerPill", TEXT)
	th.set_color("font_hover_color", "EditorOwnerPill", GOLD_HI)
	th.set_color("font_pressed_color", "EditorOwnerPill", GOLD_HI)
	th.set_font_size("font_size", "EditorOwnerPill", Spec.FS_CAPTION)
	th.set_constant("h_separation", "EditorOwnerPill", 6)
	# 地形色块按钮：保留本色，但改成"石底 + 亮边"
	_splat(th, &"EditorSplatGrass", Color(0.26, 0.48, 0.18))
	_splat(th, &"EditorSplatDirt", Color(0.44, 0.32, 0.18))
	_splat(th, &"EditorSplatRock", Color(0.42, 0.43, 0.46))
	_splat(th, &"EditorSplatSand", Color(0.72, 0.64, 0.42))


static func _tool_variation(th: Theme, name: StringName, h: float, px: float, py: float,
		icon_px: float = ICON) -> void:
	th.set_type_variation(name, "Button")
	# 四态只改"亮度和金量"，不改圆角/边框宽 —— 边框一宽一窄，按下去的瞬间
	# 文字会横跳 1px，整条工具带跟着抖，这是最廉价也最刺眼的毛病。
	var n := _box(BG_CTRL, LINE_GOLD, 1, 3, px, py)
	var hv := _box(BG_HOVER, GOLD_DIM, 1, 3, px, py)
	var pv := _box(BG_CHECKED, GOLD, 1, 3, px, py)
	var ds := _box(Color(BG_CTRL.r, BG_CTRL.g, BG_CTRL.b, 0.5), Color(LINE.r, LINE.g, LINE.b, 0.3), 1, 3, px, py)
	th.set_stylebox("normal", name, n)
	th.set_stylebox("hover", name, hv)
	th.set_stylebox("pressed", name, pv)
	th.set_stylebox("hover_pressed", name, pv)
	th.set_stylebox("disabled", name, ds)
	th.set_stylebox("focus", name, StyleBoxEmpty.new())
	th.set_color("font_color", name, TEXT)
	th.set_color("font_hover_color", name, GOLD_HI)
	th.set_color("font_pressed_color", name, GOLD_HI)
	th.set_color("font_hover_pressed_color", name, GOLD_HI)
	th.set_color("font_disabled_color", name, TEXT_DIM)
	th.set_font_size("font_size", name, Spec.FS_BODY)
	th.set_constant("h_separation", name, 7)
	th.set_constant("icon_max_width", name, int(icon_px))
	# 图标统一上暖色（旧的是纯白，13 个白图标并排 = 一片噪点）。
	# 单色 SVG 走 modulate 上色，这是 UI风格 R4 要求的唯一着色方式。
	th.set_color("icon_normal_color", name, Color(0.80, 0.76, 0.66))
	th.set_color("icon_hover_color", name, GOLD_HI)
	th.set_color("icon_pressed_color", name, GOLD_HI)
	th.set_color("icon_hover_pressed_color", name, GOLD_HI)
	th.set_color("icon_disabled_color", name, Color(TEXT_DIM.r, TEXT_DIM.g, TEXT_DIM.b, 0.7))


static func _danger_variation(th: Theme, name: StringName, h: float, px: float, py: float) -> void:
	th.set_type_variation(name, "Button")
	th.set_stylebox("normal", name, _box(Color(0.145, 0.086, 0.082), RED_DIM, 1, 3, px, py))
	th.set_stylebox("hover", name, _box(Color(0.243, 0.114, 0.102), RED, 1, 3, px, py))
	th.set_stylebox("pressed", name, _box(Color(0.26, 0.12, 0.10), RED_HI, 1, 3, px, py))
	th.set_stylebox("hover_pressed", name, _box(Color(0.26, 0.12, 0.10), RED_HI, 1, 3, px, py))
	th.set_stylebox("disabled", name, _box(Color(0.114, 0.09, 0.086, 0.6), Color(RED_DIM.r, RED_DIM.g, RED_DIM.b, 0.5), 1, 3, px, py))
	th.set_stylebox("focus", name, StyleBoxEmpty.new())
	th.set_color("font_color", name, Color(0.85, 0.72, 0.69))
	th.set_color("font_hover_color", name, RED_HI)
	th.set_color("font_pressed_color", name, RED_HI)
	th.set_color("font_hover_pressed_color", name, RED_HI)
	th.set_color("font_disabled_color", name, Color(0.55, 0.47, 0.45))
	th.set_font_size("font_size", name, Spec.FS_BODY)
	th.set_constant("h_separation", name, 8)


static func _primary_variation(th: Theme, name: StringName, h: float, px: float, py: float) -> void:
	th.set_type_variation(name, "Button")
	th.set_stylebox("normal", name, _box(Color(0.165, 0.140, 0.080), Color(GOLD.r, GOLD.g, GOLD.b, 0.55), 1, 3, px, py))
	th.set_stylebox("hover", name, _box(Color(0.216, 0.184, 0.104), GOLD, 1, 3, px, py))
	th.set_stylebox("pressed", name, _box(Color(0.106, 0.09, 0.055), GOLD_HI, 1, 3, px, py))
	th.set_stylebox("hover_pressed", name, _box(Color(0.106, 0.09, 0.055), GOLD_HI, 1, 3, px, py))
	th.set_stylebox("disabled", name, _box(Color(0.118, 0.118, 0.129, 0.6), Color(LINE.r, LINE.g, LINE.b, 0.4), 1, 3, px, py))
	th.set_stylebox("focus", name, StyleBoxEmpty.new())
	th.set_color("font_color", name, GOLD_HI)
	th.set_color("font_hover_color", name, Color(1.0, 0.94, 0.76))
	th.set_color("font_pressed_color", name, Color(1.0, 0.94, 0.76))
	th.set_color("font_disabled_color", name, TEXT_DIM)
	th.set_font_size("font_size", name, Spec.FS_BODY)
	th.set_constant("h_separation", name, 8)


static func _splat(th: Theme, name: StringName, col: Color) -> void:
	th.set_type_variation(name, "Button")
	var n := _box(Color(col.r * 0.34, col.g * 0.34, col.b * 0.34, 1.0),
		Color(col.r * 0.75, col.g * 0.75, col.b * 0.75, 0.65), 1, 4, 8.0, 4.0)
	var p := _box(Color(col.r * 0.5, col.g * 0.5, col.b * 0.5, 1.0), GOLD, 2, 4, 8.0, 4.0)
	var hv := _box(Color(col.r * 0.42, col.g * 0.42, col.b * 0.42, 1.0), GOLD_DIM, 1, 4, 8.0, 4.0)
	th.set_stylebox("normal", name, n)
	th.set_stylebox("hover", name, hv)
	th.set_stylebox("pressed", name, p)
	th.set_stylebox("hover_pressed", name, p)
	th.set_stylebox("disabled", name, n)
	th.set_stylebox("focus", name, StyleBoxEmpty.new())
	th.set_color("font_color", name, TEXT)
	th.set_color("font_hover_color", name, Color.WHITE)
	th.set_color("font_pressed_color", name, Color.WHITE)
	th.set_font_size("font_size", name, Spec.FS_BODY)


static func _label_var(th: Theme, name: StringName, col: Color, size: int) -> void:
	th.set_type_variation(name, "Label")
	th.set_color("font_color", name, col)
	th.set_font_size("font_size", name, size)


# ===========================================================================
# 二、生成的贴图（不落盘：勾选框 / 滑条把手 / 颜色点）
# ===========================================================================

## 滑条把手：14×14 的金色菱形（默认那个灰三角在深底上几乎看不见）
static func _grabber_tex() -> Texture2D:
	if _tex_cache.has("grabber"):
		return _tex_cache["grabber"] as Texture2D
	var n := 14
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(n):
		for x in range(n):
			var d: int = absi(x - 6) + absi(y - 6)
			if d <= 3:
				img.set_pixel(x, y, GOLD_HI)
			elif d <= 5:
				img.set_pixel(x, y, GOLD)
			elif d == 6:
				img.set_pixel(x, y, Color(0.15, 0.12, 0.06, 1.0))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache["grabber"] = tex
	return tex


## 玩家色小圆点（归属药丸/玩家槽位前面那颗）
static func dot(col: Color, px: int = 14) -> Texture2D:
	var key := "dot_%s_%d" % [col.to_html(false), px]
	if _tex_cache.has(key):
		return _tex_cache[key] as Texture2D
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := float(px - 1) * 0.5
	for y in range(px):
		for x in range(px):
			var d := Vector2(float(x) - c, float(y) - c).length()
			if d <= c - 1.2:
				img.set_pixel(x, y, col.lightened(0.12))
			elif d <= c - 0.2:
				img.set_pixel(x, y, col.darkened(0.45))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


# ===========================================================================
# 三、控件工厂（结构 + 尺寸；皮肤全部来自上面的 Theme）
# ===========================================================================

## 工具按钮：图标（28）+ 两个字，高度决定用哪档皮肤。
## kind: normal / primary / danger
static func tool_button(icon_name: String, text: String, tip: String,
		kind: String = "normal", h: float = H_QUICK, icon_px: float = -1.0) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0.0, h)
	b.add_theme_constant_override("h_separation", 7)
	b.add_theme_constant_override("icon_max_width", int(icon_size_for(h) if icon_px <= 0.0 else icon_px))
	var tex := icon(icon_name)
	if tex != null:
		b.icon = tex
	# 图标贴左、文字紧随其后：两个 alignment 都要设，否则会"图标钉左、文字居中"
	b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.theme_type_variation = _var_for(kind, h)
	return b


## 高度 → 皮肤变体。三档，**按真实高度判**，不要只分"大/小"两档：
## 层栏 46 和快捷条 34 的图标/内边距本来就不一样，混用会让左栏比顶栏"肥一圈"。
static func icon_size_for(h: float) -> float:
	if h >= H_LAYER - 0.5:
		return ICON_LAYER
	if h >= H_QUICK - 0.5:
		return ICON
	return ICON_SMALL


static func _var_for(kind: String, h: float) -> StringName:
	var layer: bool = h >= H_LAYER - 0.5
	var big: bool = h >= H_QUICK - 0.5
	match kind:
		"primary":
			return &"EditorPrimary" if big else &"EditorSmallPrimary"
		"danger":
			return &"EditorDanger" if big else &"EditorSmallDanger"
	if layer:
		return &"EditorLayer"
	return &"EditorTool" if big else &"EditorSmall"


## 纯图标方块（没有文字的地方）：正方形 h×h
static func icon_button(icon_name: String, tip: String,
		kind: String = "normal", h: float = H_SMALL) -> Button:
	var b := tool_button(icon_name, "", tip, kind, h)
	b.custom_minimum_size = Vector2(h, h)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	return b


## 分节标题：12px 金字 + 一条金线（可选 16px 图标）。
## 返回 VBox，直接 add_child 即可。
static func section(title: String, icon_name: String = "") -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	if not icon_name.is_empty():
		var tr := TextureRect.new()
		tr.texture = icon(icon_name)
		tr.custom_minimum_size = Vector2(16.0, 16.0)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.modulate = Color(GOLD.r, GOLD.g, GOLD.b, 0.85)
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(tr)
	var l := Label.new()
	l.text = title
	l.theme_type_variation = &"EditorSection"
	row.add_child(l)
	var line := ColorRect.new()
	line.color = Color(GOLD.r, GOLD.g, GOLD.b, 0.18)
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	box.add_child(row)
	return box


## 图标纹理（走 界面规格 的缓存；缺失会 push_warning，方便发现漏配）
static func icon(name: String) -> Texture2D:
	if name.is_empty():
		return null
	return Spec.icon_tex(name)


## 一个小色点（行首用；14px）
static func color_dot(col: Color) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = dot(col)
	tr.custom_minimum_size = Vector2(14.0, 14.0)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr
