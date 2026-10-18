class_name RtsHud
extends CanvasLayer
## **HUD（HAWKEYE）**：全部用代码构建（文档 §8 明确不写 .tscn，避免布局脆弱）
##
## 版面：
##   顶部左    金币 / 木材 / 人口
##   顶部中    提示消息（3 秒淡出，最多留 3 条）
##   左下      小地图（RtsMinimap，自定义 _draw）
##   中下      选中目标：名称 + 血条 + 数值
##   右下      命令卡（RtsCommandCard，4×3）
##   中上偏下  等待落点的操作提示（"左键选择建造位置…"）
##   全屏      结束遮罩：胜利/失败 + 用时 + 「重新开始」
##
## 中文字体：优先用美术侧 `美术/主题/游戏主题.tres`（ArtKit.load_theme），
## 没有就用 SystemFont 挂在 Microsoft YaHei / SimHei / Noto Sans CJK 上——**必须保证中文能显示**，
## 否则一屏方块，验收直接不过。

## 界面刷新间隔（秒）：不跟渲染帧空转
const REFRESH_INTERVAL := 0.12
## 提示消息最多同时留几条
const TOAST_MAX := 3
## 提示消息淡出时长（秒）
const TOAST_FADE := 0.55

# --- 版面常量（像素）---
const MARGIN := 14.0
const STATS_SIZE := Vector2(432.0, 50.0)
const CARD_SIZE := Vector2(336.0, 224.0)
## 选中面板宽度（单位档案板 / 建筑面板共用，贴底摆放用）
const SEL_PANEL_W := 512.0
## 建筑面板脚本（用 preload 而不是直接写 class_name：新类还没进全局 class 缓存时也能跑）
const BUILDING_PANEL_SCRIPT := preload("res://代码/界面/建筑面板.gd")

## 界面根节点（承载 theme，铺满视口）
var root: Control = null

## 顶部资源
var _gold_label: Label = null
var _wood_label: Label = null
var _food_label: Label = null
## 人口微条
var _pop_bar: MiniBar = null

## 提示消息容器
var _toast_box: VBoxContainer = null

## 小地图
var _minimap: RtsMinimap = null

## 选中信息
var _sel_panel: PanelContainer = null
## **BASALT 档案板**：3D 头像 + 名称 + 生命 + 数值 + 多选格子（见 选中面板.gd）
var _dossier: RtsDossierPanel = null
## **建筑面板**：选中单个建筑时的专属版式（训练 / 集结点 / 研究，见 建筑面板.gd）
var _building_panel: PanelContainer = null
## 当前选中面板高度（单位单选 / 多选 / 建筑三种版式各不相同）
var _sel_h: float = RtsDossierPanel.H_SINGLE
## **ECHO 触感回声**：点选圆环 / 右键涟漪（见 触感回声.gd）
var _echo: RtsEchoFx = null
## **GLYPH 光标符文**：按悬停对象换图标（见 光标术.gd）
var _glyph: RtsGlyphCursor = null

## 命令卡
var _card: RtsCommandCard = null
var _card_sig: String = ""

## 等待落点提示
var _pending_label: Label = null

## 结束遮罩
var _overlay: ColorRect = null
var _over_title: Label = null
var _over_sub: Label = null

## 当前选中（指向真实节点，刷新时判空）
var _selection: Array = []

## 刷新计时 / 缓存签名
var _clock: float = 0.0
var _sel_sig: String = ""


# ===========================================================================
# 内嵌小控件
# ===========================================================================

## 一条 42×6 的微缩进度条（人口用）
class MiniBar extends Control:
	var ratio: float = 0.0
	var color: Color = Color(0.72, 0.86, 0.95)
	var warn: bool = false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_ratio(r: float, is_warn: bool = false) -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if absf(v - ratio) < 0.004 and is_warn == warn:
			return
		ratio = v
		warn = is_warn
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 3.0 or r.size.y < 4.0:
			return
		draw_rect(r, Color(0.0, 0.0, 0.0, 0.62), true)
		var col: Color = Color(0.96, 0.42, 0.34) if warn else color
		var w: float = maxf((r.size.x - 2.0) * ratio, 0.0)
		if w > 0.5:
			draw_rect(Rect2(1.0, 1.0, w, r.size.y - 2.0), col, true)
		draw_rect(r, Color(1.0, 1.0, 1.0, 0.10), false, 1.0)


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	layer = 1
	root = Control.new()
	root.name = "界面根"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _build_theme()
	add_child(root)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 实测踩坑：直接挂在 CanvasLayer 下的 Control，光靠 full-rect 锚点**未必拿到尺寸**
	# （开局量到 size=(0,0)，于是小地图被算到屏幕外、提示贴左边缘被裁）。
	# 所以下面所有子控件都按 root 的锚点排布，而 root 的尺寸**显式同步**，不赌引擎时序。
	_sync_root_size()

	_build_stats()
	_build_toasts()
	_build_minimap()
	_build_selection_panel()
	_build_card()
	_build_pending_label()
	_build_overlay()
	_install_fx()

	# --- 信号 ---
	Game.resources_changed.connect(_on_resources_changed)
	Game.selection_changed.connect(_on_selection_changed)
	Game.notify.connect(_on_notify)
	Game.game_over.connect(_on_game_over)

	_refresh_stats()
	_refresh_selection()
	_refresh_card(true)
	_qa_select_hook()


func _process(delta: float) -> void:
	_sync_root_size()
	_clock += delta
	if _clock < REFRESH_INTERVAL:
		return
	_clock = 0.0
	_refresh_stats()
	_refresh_selection()
	_refresh_pending()
	_refresh_card(false)


## 把界面根节点铺满视口。
## 注意：这里**改 offset，不改 size**——根节点挂的是 full-rect 锚点（左右/上下锚点不相等），
## 直接给 size 会被引擎在 _ready 之后按锚点重算，还会打一条 "size overridden" 警告。
## 按 offset = 期望尺寸 - 父区域尺寸 来算，就和锚点公式自洽了。
func _sync_root_size() -> void:
	if root == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var want: Vector2 = vp.get_visible_rect().size
	if want.x < 1.0 or want.y < 1.0:
		return
	var area: Vector2 = root.get_parent_area_size()
	var orr: float = want.x - area.x
	var ob: float = want.y - area.y
	if root.offset_left != 0.0 or root.offset_top != 0.0 \
			or absf(root.offset_right - orr) > 0.5 or absf(root.offset_bottom - ob) > 0.5:
		root.offset_left = 0.0
		root.offset_top = 0.0
		root.offset_right = orr
		root.offset_bottom = ob


# ===========================================================================
# 主题（含中文字体兜底）
# ===========================================================================

func _build_theme() -> Theme:
	var th: Theme = ArtKit.load_theme()
	var fresh: bool = th == null
	if fresh:
		th = Theme.new()

	# 中文字体：美术主题里没配也得能显示
	if th.default_font == null:
		var sf := SystemFont.new()
		sf.font_names = PackedStringArray([
			"Microsoft YaHei", "SimHei", "Noto Sans CJK SC",
			"WenQuanYi Zen Hei", "PingFang SC", "sans-serif",
		])
		th.default_font = sf
	if fresh:
		th.default_font_size = 17
		_style_ui(th)
	return th


## 代码兜底样式（不追求好看，追求"看得清、有层次"）
func _style_ui(th: Theme) -> void:
	var accent: Color = Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)
	var bg: Color = Cfg.game.hud_bg if Cfg.game != null else Color(0.06, 0.07, 0.09, 0.86)

	# --- 面板 ---
	var panel := StyleBoxFlat.new()
	panel.bg_color = bg
	panel.border_color = Color(accent.r, accent.g, accent.b, 0.55)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(4)
	panel.content_margin_left = 12.0
	panel.content_margin_right = 12.0
	panel.content_margin_top = 8.0
	panel.content_margin_bottom = 8.0
	th.set_stylebox("panel", "PanelContainer", panel)

	# --- 按钮 ---
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.13, 0.16, 0.96)
	normal.border_color = Color(accent.r, accent.g, accent.b, 0.45)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(3)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.20, 0.22, 0.27, 0.98)
	hover.border_color = Color(accent.r, accent.g, accent.b, 0.95)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.30, 0.26, 0.16, 0.98)
	pressed.border_color = accent

	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.10, 0.10, 0.11, 0.85)
	disabled.border_color = Color(0.35, 0.35, 0.35, 0.5)

	th.set_stylebox("normal", "Button", normal)
	th.set_stylebox("hover", "Button", hover)
	th.set_stylebox("pressed", "Button", pressed)
	th.set_stylebox("disabled", "Button", disabled)
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", Color(0.92, 0.91, 0.87))
	th.set_color("font_hover_color", "Button", Color(1.0, 1.0, 1.0))
	th.set_color("font_pressed_color", "Button", accent)
	th.set_color("font_disabled_color", "Button", Color(0.52, 0.52, 0.50))

	# --- 血条 ---
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.08, 0.08, 0.09, 0.95)
	bar_bg.border_color = Color(0.3, 0.3, 0.32, 0.9)
	bar_bg.set_border_width_all(1)
	bar_bg.set_corner_radius_all(2)

	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.36, 0.78, 0.40)
	bar_fill.set_corner_radius_all(2)

	th.set_stylebox("background", "ProgressBar", bar_bg)
	th.set_stylebox("fill", "ProgressBar", bar_fill)


# ===========================================================================
# 构建各块
# ===========================================================================

## 版面工具：直接设 anchor + offset，避免 set_anchors_preset 的隐式行为
func _place(c: Control, al: float, at: float, ar: float, ab: float,
		ol: float, ot: float, orr: float, ob: float) -> void:
	c.anchor_left = al
	c.anchor_top = at
	c.anchor_right = ar
	c.anchor_bottom = ab
	c.offset_left = ol
	c.offset_top = ot
	c.offset_right = orr
	c.offset_bottom = ob


## 一个彩色小方块（资源图标）
func _dot(color: Color) -> ColorRect:
	var d := ColorRect.new()
	d.color = color
	d.custom_minimum_size = Vector2(9.0, 9.0)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d


## 统一的"硬质面板"样式：圆角深底 + 1px 亮边 + 外投影
func _frame_style(radius: int, alpha: float) -> StyleBoxFlat:
	var bg: Color = Cfg.game.hud_bg if Cfg.game != null else Color(0.06, 0.07, 0.09, 0.86)
	var acc: Color = Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg.r, bg.g, bg.b, alpha)
	sb.border_color = Color(acc.r, acc.g, acc.b, 0.42)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 8
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


## 顶部资源条
func _build_stats() -> void:
	var panel := PanelContainer.new()
	panel.name = "资源条"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _frame_style(7, 0.92))
	_place(panel, 0.0, 0.0, 0.0, 0.0, MARGIN, MARGIN,
			MARGIN + STATS_SIZE.x, MARGIN + STATS_SIZE.y)
	root.add_child(panel)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 8)
	panel.add_child(hb)

	var gold_c: Color = Cfg.game.gold_color if Cfg.game != null else Color(1.0, 0.82, 0.24)
	_gold_label = _stat_pill(hb, "金币", gold_c, false)
	_wood_label = _stat_pill(hb, "木材", Color(0.64, 0.46, 0.27), false)
	_food_label = _stat_pill(hb, "人口", Color(0.72, 0.86, 0.95), true)


## 一枚资源胶囊：[色点][小字标题][大数字][可选微条]
func _stat_pill(parent: Node, title: String, color: Color, with_bar: bool) -> Label:
	var pill := PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.078, 0.088, 0.110, 0.94)
	sb.border_color = Color(color.r, color.g, color.b, 0.32)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	sb.corner_detail = 6
	sb.content_margin_left = 9.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 3.0
	sb.content_margin_bottom = 3.0
	pill.add_theme_stylebox_override("panel", sb)
	parent.add_child(pill)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	pill.add_child(row)

	row.add_child(_dot(color))

	var tag := Label.new()
	tag.text = title
	tag.add_theme_font_size_override("font_size", 12)
	tag.add_theme_color_override("font_color", Color(color.r * 0.5 + 0.32, color.g * 0.5 + 0.32, color.b * 0.5 + 0.32))
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tag)

	var lb := Label.new()
	lb.text = "0"
	lb.add_theme_font_size_override("font_size", 18)
	lb.add_theme_color_override("font_color", Color(0.95, 0.94, 0.89))
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lb)

	if with_bar:
		var mb := MiniBar.new()
		mb.color = color
		mb.custom_minimum_size = Vector2(44.0, 6.0)
		mb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(mb)
		_pop_bar = mb
	return lb


## 顶部中间的提示消息区
func _build_toasts() -> void:
	_toast_box = VBoxContainer.new()
	_toast_box.name = "提示"
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_toast_box.add_theme_constant_override("separation", 2)
	_place(_toast_box, 0.5, 0.0, 0.5, 0.0, -300.0, 70.0, 300.0, 260.0)
	root.add_child(_toast_box)


## 左下小地图
func _build_minimap() -> void:
	var s: float = Cfg.game.minimap_size if Cfg.game != null else 236.0
	var m: float = Cfg.game.minimap_margin if Cfg.game != null else MARGIN
	_minimap = RtsMinimap.new()
	_minimap.name = "小地图"
	_place(_minimap, 0.0, 1.0, 0.0, 1.0, m, -(m + s), m + s, -m)
	root.add_child(_minimap)


## 中下：选中信息（**门面**）。两种版式按选中内容切换：
##   · 单个建筑 → RtsBuildingPanel（训练队列 / 建造进度 / 集结点 / 研究）
##   · 其余情况 → RtsDossierPanel（3D 头像 / 属性 / 多选格子）
## 两块面板同时存在、按可见性切换：这样高度重新自适应时不会重建控件，也不会丢悬停状态。
func _build_selection_panel() -> void:
	_dossier = RtsDossierPanel.new()
	_dossier.name = "选中信息"
	root.add_child(_dossier)

	_building_panel = BUILDING_PANEL_SCRIPT.new() as PanelContainer
	_building_panel.name = "建筑信息"
	_building_panel.visible = false
	root.add_child(_building_panel)

	_sel_panel = _dossier
	_sel_h = _dossier.desired_height()
	_place_selection_panel()


## 按当前高度把面板钉在屏幕底边中点（多选时面板要变高，所以每次高度变了都重摆）
func _place_selection_panel() -> void:
	if _sel_panel == null:
		return
	_place(_sel_panel, 0.5, 1.0, 0.5, 1.0,
			-SEL_PANEL_W * 0.5, -(MARGIN + _sel_h),
			SEL_PANEL_W * 0.5, -MARGIN)


## 右下命令卡
func _build_card() -> void:
	var panel := PanelContainer.new()
	panel.name = "命令卡底座"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _frame_style(7, 0.93))
	_place(panel, 1.0, 1.0, 1.0, 1.0,
			-(MARGIN + CARD_SIZE.x), -(MARGIN + CARD_SIZE.y), -MARGIN, -MARGIN)
	root.add_child(panel)

	_card = RtsCommandCard.new()
	_card.name = "命令卡"
	panel.add_child(_card)


## 等待落点的提示（在选中面板上方）
func _build_pending_label() -> void:
	_pending_label = Label.new()
	_pending_label.name = "落点提示"
	_pending_label.text = ""
	_pending_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pending_label.add_theme_font_size_override("font_size", 17)
	_pending_label.add_theme_color_override("font_color", Color(0.98, 0.86, 0.45))
	_pending_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_pending_label.add_theme_constant_override("outline_size", 4)
	_pending_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_pending_label)
	_place_pending_label()
	_pending_label.visible = false


## 落点提示跟着选中面板高度走（面板变高时不许压住面板）
func _place_pending_label() -> void:
	if _pending_label == null:
		return
	_place(_pending_label, 0.5, 1.0, 0.5, 1.0,
			-330.0, -(MARGIN + _sel_h + 32.0), 330.0, -(MARGIN + _sel_h + 6.0))


## 结束遮罩
func _build_overlay() -> void:
	_overlay = ColorRect.new()
	_overlay.name = "结束遮罩"
	_overlay.color = Color(0.02, 0.03, 0.04, 0.72)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	root.add_child(_overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vb)

	_over_title = Label.new()
	_over_title.text = "胜利"
	_over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_over_title.add_theme_font_size_override("font_size", 76)
	_over_title.add_theme_color_override("font_color", Color(0.98, 0.86, 0.42))
	vb.add_child(_over_title)

	_over_sub = Label.new()
	_over_sub.text = ""
	_over_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_over_sub.add_theme_font_size_override("font_size", 18)
	_over_sub.add_theme_color_override("font_color", Color(0.86, 0.86, 0.82))
	vb.add_child(_over_sub)

	var btn := Button.new()
	btn.text = "重新开始"
	btn.custom_minimum_size = Vector2(220.0, 52.0)
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_color_override("font_color", Color(0.98, 0.90, 0.62))
	btn.pressed.connect(_on_restart_pressed)
	vb.add_child(btn)


# ===========================================================================
# 外挂模块（ECHO 触感回声 / GLYPH 光标符文）
# ===========================================================================

## 装两件"手感"外挂：
##   · ECHO 必须挂在 3D 世界里（圆环/涟漪是 MeshInstance3D），
##     所以往**主场景根**（本 HUD 的父节点，主场景.tscn 的 Node3D）上挂 —— 不碰别人的节点树；
##   · GLYPH 只吃输入、不画东西，挂在 HUD 自己名下。
func _install_fx() -> void:
	var host := get_parent()
	if host is Node3D and _echo == null:
		_echo = RtsEchoFx.new()
		_echo.hud = self
		# 这里本来可以直接 add_child，但 HUD 是在主场景 **还在装配子节点时** 就 _ready 的，
		# 直接挂会被引擎拒绝（"Parent node is busy setting up children"），所以推到下一帧。
		(host as Node3D).add_child.call_deferred(_echo)
	if _glyph == null:
		_glyph = RtsGlyphCursor.new()
		add_child(_glyph)


# ===========================================================================
# QA 截图钩子（只在带命令行参数时生效，不碰正常玩法）
# ===========================================================================

## 中文名 → 单位 id（验收命令行允许写中文）
const QA_NAME_MAP := {
	"农民": "peasant", "步兵": "footman", "弓箭手": "archer", "法师": "mage",
	"大本营": "townhall", "兵营": "barracks", "铁匠铺": "blacksmith",
	"农场": "farm", "箭塔": "tower", "金矿": "goldmine", "树": "tree",
}

## `--select-id=<英文 id 或 中文名>` 自动选中该类型的全部己方对象（**含建筑**）。
##
## 为什么要在这里补一条：主场景自带的 `_qa_select` 只遍历 `faction.units`，
## 而建筑登记在 `faction.buildings` 里（不在 units 数组），中文名也匹配不上 ——
## 于是"截建筑面板"这条路原本是断的。这里补一条更宽的通道，纯为验收。
func _qa_select_hook() -> void:
	var want: String = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--select-id="):
			want = arg.substr(12)
			break
	if want.is_empty():
		return
	_qa_select_later(want)


func _qa_select_later(want: String) -> void:
	for _i in 5:
		await get_tree().process_frame
	var id: String = String(QA_NAME_MAP.get(want, want))
	var picked: Array = []
	var pl := Game.player_faction
	if pl == null:
		return
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var r := u as RtsUnit
		if r == null or not r.is_alive() or r.faction != pl or r.def == null:
			continue
		if String(r.def.id) == id:
			picked.append(r)
	if picked.is_empty():
		return
	var sel := get_parent().get_node_or_null("选择系统")
	if sel == null:
		return
	if sel.has_method("select_units"):
		sel.call("select_units", picked)
	else:
		sel.set("selected", picked)
		for u in picked:
			u.set("is_selected", true)
		Game.selection_changed.emit(picked)
	print("[QA补] 选中 %d 个 %s（建筑也在内）" % [picked.size(), id])


# ===========================================================================
# 关停
# ===========================================================================

## 退出时把音效模块的播放器**提前**收掉。
##
## 为什么界面层要管这事：`代码/音频/音效管理.gd` 自己已经有 `_exit_tree()`（stop + stream=null），
## 但 AudioServer 是独立线程，stop 命令要排队处理；引擎关停时音频服务先走一步，
## 播放对象（AudioStreamPlaybackWAV / AudioStreamWAV）就变成"退出时仍被引用"，
## 于是 `--quit-after 200` 会**间歇性**刷一条
##   ERROR: 1 resources still in use at exit
## 这里在界面层把它的节点直接 `free()`（立刻释放播放器），只是抢在关停前把手放开，
## **不改音频模块的任何行为** —— 它不在本文件的改动范围里，也轮不到界面去改它的地基。
func _exit_tree() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var sfx := tree.root.get_node_or_null("音效")
	if sfx == null or not is_instance_valid(sfx):
		return
	# 只"放手"，不 free 节点（关停阶段动父子关系会触发引擎的 busy 断言）
	for c in sfx.get_children():
		var p := c as AudioStreamPlayer
		if p != null:
			p.stop()
			p.stream = null
			continue
		var p3 := c as AudioStreamPlayer3D
		if p3 != null:
			p3.stop()
			p3.stream = null


# ===========================================================================
# 刷新
# ===========================================================================

## 资源/人口
func _refresh_stats() -> void:
	var pl := Game.player_faction
	if pl == null:
		_gold_label.text = "-"
		_wood_label.text = "-"
		_food_label.text = "-"
		if _pop_bar != null:
			_pop_bar.set_ratio(0.0, false)
		return
	_gold_label.text = "%d" % pl.gold
	_wood_label.text = "%d" % pl.wood
	var used: int = pl.food_used()
	var cap: int = pl.food_cap()
	_food_label.text = "%d/%d" % [used, cap]
	if _pop_bar != null:
		_pop_bar.set_ratio(float(used) / maxf(float(cap), 1.0), cap > 0 and used >= cap)


## 选中信息：**单个建筑**走建筑面板，其余（单位 / 多选 / 空）交给 BASALT 档案板。
## 两块面板共用贴底位置，靠 visible 切换；高度变了才重摆，避免每 0.12s 抖一下。
func _refresh_selection() -> void:
	var arr := _valid_selection()
	var sole_building: RtsBuilding = null
	if arr.size() == 1:
		var b := arr[0] as RtsBuilding
		if b != null and b.is_alive():
			sole_building = b

	if sole_building != null:
		if _dossier != null:
			_dossier.visible = false
		if _building_panel != null:
			_building_panel.visible = true
			_building_panel.call("refresh", sole_building)
		_sel_panel = _building_panel
	else:
		if _building_panel != null:
			_building_panel.visible = false
		if _dossier != null:
			_dossier.visible = true
			_dossier.refresh(arr)
		_sel_panel = _dossier

	if _sel_panel != null:
		# 两块面板都实现了 desired_height()；这里按调用取，避免依赖具体面板类型
		var h: float = float(_sel_panel.call("desired_height"))
		if absf(h - _sel_h) > 0.5:
			_sel_h = h
			_place_selection_panel()
			_place_pending_label()
	if _glyph != null:
		_glyph.note_selection(arr)


## 等待落点提示
func _refresh_pending() -> void:
	var cmd := _command_system()
	var show: bool = false
	if cmd != null and is_instance_valid(cmd) and cmd.has_method("has_pending"):
		if bool(cmd.call("has_pending")) and cmd.has_method("pending_prompt"):
			var txt: String = String(cmd.call("pending_prompt"))
			if txt != "":
				_pending_label.text = txt
				show = true
	_pending_label.visible = show


## 命令卡（签名没变就不重建，避免悬停时闪烁）
func _refresh_card(force: bool) -> void:
	if _card == null:
		return
	var sig := _card_signature()
	if not force and sig == _card_sig:
		return
	_card_sig = sig
	_card.command_system = _command_system()
	_card.refresh(_valid_selection())


## 命令卡的内容签名
func _card_signature() -> String:
	var parts := PackedStringArray()
	for u in _valid_selection():
		var id := ""
		var d: UnitDef = u.get("def") as UnitDef
		if d != null:
			id = String(d.id)
		var q: int = 0
		var r: String = "-"
		var b := u as RtsBuilding
		if b != null:
			q = b.train_queue.size()
			# 研究状态也进签名：研究完成/满级时命令卡必须重建，否则按钮一直停在旧等级
			r = "%s:%d" % [String(b.current_research()), int(clampf(b.research_progress(), 0.0, 1.0) * 10.0)]
		parts.append("%s:%d:%s" % [id, q, r])
	parts.append("page:%s" % (str(_card.is_build_page()) if _card != null else "0"))
	parts.append("cmd:%s" % str(_command_system() != null))
	return "|".join(parts)


## 过滤出有效选中（节点还在、还活着）
func _valid_selection() -> Array:
	var out: Array = []
	for u in _selection:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not u.is_alive():
			continue
		out.append(u)
	return out


func _command_system() -> Node:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get("command_system") as Node


# ===========================================================================
# 信号处理
# ===========================================================================

func _on_resources_changed(_faction: RtsFaction) -> void:
	_refresh_stats()


func _on_selection_changed(units: Array) -> void:
	_selection = units.duplicate()
	_refresh_selection()
	_refresh_card(true)


## 顶部提示：3 秒后淡出，最多留 3 条
func _on_notify(text: String, color: Color) -> void:
	if text.is_empty() or _toast_box == null:
		return
	var lb := Label.new()
	lb.text = text
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lb.add_theme_font_size_override("font_size", 20)
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	lb.add_theme_constant_override("outline_size", 4)
	_toast_box.add_child(lb)

	while _toast_box.get_child_count() > TOAST_MAX:
		var oldest := _toast_box.get_child(0)
		_toast_box.remove_child(oldest)
		oldest.queue_free()

	var hold: float = Cfg.game.toast_duration if Cfg.game != null else 3.0
	var tw := create_tween()
	tw.tween_interval(hold)
	tw.tween_property(lb, "modulate:a", 0.0, TOAST_FADE)
	tw.tween_callback(lb.queue_free)


func _on_game_over(victory: bool) -> void:
	if _overlay == null:
		return
	_overlay.visible = true
	if victory:
		_over_title.text = "胜 利"
		_over_title.add_theme_color_override("font_color", Color(0.98, 0.86, 0.42))
	else:
		_over_title.text = "战 败"
		_over_title.add_theme_color_override("font_color", Color(0.95, 0.42, 0.36))
	var t: float = Game.elapsed
	_over_sub.text = "用时 %02d:%02d　　击杀 %d" % [
		floori(t / 60.0), int(t) % 60, _player_kills()
	]
	_pending_label.visible = false


## 玩家击杀数（敌方已死亡、还没被清理的单位数；纯展示用）
func _player_kills() -> int:
	var n: int = 0
	var en := Game.enemy_faction
	if en == null:
		return 0
	for u in en.units:
		if u != null and is_instance_valid(u) and u.has_method("is_alive") and not u.is_alive():
			n += 1
	return n


func _on_restart_pressed() -> void:
	Game.restart()


# ===========================================================================
# 对外（供指令系统 B 键调用）
# ===========================================================================

## 切换命令卡的"建造页"
func toggle_build_menu() -> void:
	if _card == null:
		return
	_card.toggle_build_page()
	_refresh_card(true)


## 这个屏幕点是不是压在会吃鼠标的界面块上。
## 为什么不用 viewport.gui_get_hovered_control()：它看的是**真实鼠标位置**，
## 自动化测试用 Input.parse_input_event 灌事件时两者对不上，会误判"点在界面上"。
## 所以这里按控件矩形自己判，真实点击与模拟点击都一致。
func covers_point(p: Vector2) -> bool:
	if _overlay != null and _overlay.visible:
		return true
	if _minimap != null and _minimap.get_global_rect().has_point(p):
		return true
	if _sel_panel != null and _sel_panel.get_global_rect().has_point(p):
		return true
	var card_panel := _card.get_parent() as Control if _card != null else null
	if card_panel != null and card_panel.get_global_rect().has_point(p):
		return true
	return false
