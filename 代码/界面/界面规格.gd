extends RefCounted
## **界面规格（HAWKEYE）** —— 全 UI 共用的一套设计令牌。
##
## 为什么单开一个文件：HUD / 命令卡 / 选中面板 / 建筑面板 / 小地图 五块界面如果各写各的
## 边距和字号，就一定会出现"这块 14、那块 13、这块 5、那块 6"的脏活。这里把三件事钉死：
##
##   1. **8px 栅格**：所有外边距、栏间距、控件内边距都是 8 的倍数（个别 4 用于行内微调）；
##   2. **字号有限阶**：12 / 14 / 16 / 18 / 24 / 28 —— 只有这六级，禁止 13/15/17/19/21；
##   3. **响应式尺寸**：同一套版面在 1024×768 ~ 1920×1080 之间按三档缩放，保证不互相压住。
##
## 用法（各界面脚本 preload 本文件，不依赖全局 class_name 缓存）：
##   const Spec := preload("res://代码/界面/界面规格.gd")
##   var m := Spec.metrics(get_viewport().get_visible_rect().size)
##   var sb := Spec.panel_style()

# ===========================================================================
# 栅格 / 字号 / 时长
# ===========================================================================

## 8px 基准栅格
const GRID := 8.0

## 字号有限阶（任务书 §3.2）
const FS_CAPTION := 12
const FS_BODY := 14
const FS_SUB := 16
const FS_VALUE := 18
const FS_TITLE := 24
const FS_HERO := 28

## 提示消息淡出（秒）
const TOAST_FADE := 0.55


# ===========================================================================
# 响应式尺寸
# ===========================================================================

## 一整套版面尺寸（按视口算出来，HUD 每次窗口变化重算一次）
class Metrics extends RefCounted:
	var vw: float = 1600.0
	var vh: float = 900.0
	## 屏幕四角与控件之间的外边距
	var margin: float = 16.0
	## 栏间距（8 的倍数）
	var gap: float = 8.0
	## 顶部资源条（顶部居中；字号 24 / 高 72）
	var stats_w: float = 620.0
	var stats_h: float = 72.0
	## 小地图边长（圆形；240~280）
	var minimap: float = 264.0
	## 小地图底部图例条高度
	var legend_h: float = 34.0
	## 命令卡格子边长（触屏 ≥76）
	var tile: float = 80.0
	## 命令卡底座（由格子数反算，见 metrics()）
	var card_w: float = 358.0
	var card_h: float = 323.0
	## 选中卡宽 / 高（紧凑横卡，坐在命令卡上方）
	var panel_w: float = 432.0
	var panel_h_single: float = 152.0
	var panel_h_multi: float = 152.0
	## 小屏标记（<1280 宽）：字号不变，靠缩尺寸/换行扛
	var compact: bool = false

	## 屏幕底部"可摆放区"的宽度：小地图右缘 → 命令卡左缘
	func bottom_free_left() -> float:
		return margin + minimap + gap

	func bottom_free_right() -> float:
		return vw - margin - card_w - gap

	func bottom_free_center() -> float:
		return (bottom_free_left() + bottom_free_right()) * 0.5


## 按视口尺寸算版面。三档：≥1760（大屏）/ ≥1440 / ≥1280 / 其余（1024 档）
static func metrics(vp: Vector2) -> Metrics:
	var m := Metrics.new()
	m.vw = maxf(vp.x, 800.0)
	m.vh = maxf(vp.y, 600.0)
	# 2026-10-23 版面重修（玩家："中间 UI 太大，挡住视野"）：
	#   旧版命令卡 4×3 大格（84px）钉在**底部居中**、选中面板叠在它上方，
	#   两块加起来从屏幕中线一路堆到底 —— 战场中间 40% 垂直空间被吃掉。
	#   新版：**命令卡贴右下角、选中面板贴左下角（小地图右侧）**，两块并排坐在
	#   屏幕最下方的同一条带上；屏幕中上部完全让给战场。
	#   同时把格子从 84 收到 58、面板从 448 收到 368，行数按内容自适应（见 命令卡.gd）。
	if m.vw >= 1760.0:
		m.margin = 14.0
		m.gap = 8.0
		m.stats_w = 596.0
		m.stats_h = 64.0
		m.minimap = 208.0
		m.tile = 58.0
		m.panel_w = 368.0
		m.panel_h_single = 176.0
	elif m.vw >= 1440.0:
		m.margin = 14.0
		m.gap = 8.0
		m.stats_w = 560.0
		m.stats_h = 62.0
		m.minimap = 196.0
		m.tile = 56.0
		m.panel_w = 356.0
		m.panel_h_single = 172.0
	elif m.vw >= 1280.0:
		m.margin = 12.0
		m.gap = 8.0
		m.stats_w = 520.0
		m.stats_h = 60.0
		m.minimap = 184.0
		m.tile = 54.0
		m.panel_w = 344.0
		m.panel_h_single = 166.0
	else:
		m.margin = 10.0
		m.gap = 6.0
		m.stats_w = 456.0
		m.stats_h = 56.0
		m.minimap = 168.0
		m.tile = 50.0
		m.panel_w = 330.0
		m.panel_h_single = 158.0
		m.compact = true
	m.panel_h_multi = m.panel_h_single

	# 命令卡底座由格子数反算：4 列 × 3 行 + 间距 + 标题/页脚 + 内边距
	var inner: float = 14.0
	var sep: float = 5.0
	m.card_w = m.tile * 4.0 + sep * 3.0 + inner
	m.card_h = m.tile * 3.0 + sep * 2.0 + 30.0 + 1.0 + 16.0 + 4.0 + inner

	# 矮屏保护：小地图/命令卡/选中卡各自不超过屏高的一定比例
	m.minimap = minf(m.minimap, maxf(m.vh * 0.24, 150.0))
	m.card_h = minf(m.card_h, m.vh * 0.40)
	m.panel_h_single = minf(m.panel_h_single, m.vh * 0.22)
	m.panel_h_multi = m.panel_h_single
	return m


# ===========================================================================
# 取色（全部来自 Cfg.game，缺省时给同族兜底色）
# ===========================================================================

## 取全局配置（Cfg 节点）。--script 自检时也能拿到；拿不到返回 null。
static func cfg_game() -> GameConfig:
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree == null or tree.root == null:
		return null
	var n := tree.root.get_node_or_null("Cfg")
	if n == null:
		return null
	return n.get("game") as GameConfig


## 主色（暗金）
static func accent() -> Color:
	var c := cfg_game()
	return c.hud_accent if c != null else Color(0.85, 0.71, 0.36)


## 面板底色
static func bg() -> Color:
	var c := cfg_game()
	return c.hud_bg if c != null else Color(0.06, 0.07, 0.09, 0.86)


## 金币色 / 木材色 / 人口色
static func gold() -> Color:
	var c := cfg_game()
	return c.gold_color if c != null else Color(1.0, 0.82, 0.24)


static func wood() -> Color:
	return Color(0.64, 0.46, 0.27)


static func food() -> Color:
	return Color(0.72, 0.86, 0.95)


## 我方 / 敌方颜色
static func player_color() -> Color:
	var c := cfg_game()
	return c.player_color if c != null else Color(0.30, 0.62, 1.0)


static func enemy_color() -> Color:
	var c := cfg_game()
	return c.enemy_color if c != null else Color(1.0, 0.32, 0.26)


## 主文字 / 副文字 / 弱文字（60~70% 明度，任务书 §3.2 的层级要求）
static func text_main() -> Color:
	return Color(0.95, 0.94, 0.89)


static func text_sub() -> Color:
	return Color(0.76, 0.77, 0.74)


static func text_dim() -> Color:
	return Color(0.58, 0.59, 0.57)


# ===========================================================================
# 编辑器配色（editor_ 前缀）
# ===========================================================================
#
# 为什么单独分一档：游戏 HUD 是**暖色暗金**（木头/金币/羊皮纸），编辑器是
# **冷色深灰**（Godot 自带的专业工具感），两边对比度需求完全不同 ——
# 把 HUD 的 0.06 底色或金色描边硬套进编辑器，面板会和编辑器背景糊成一片、
# 金色文字在深灰上也会显脏。所以颜色**分档**，但走的还是这同一份 token 文件：
# 编辑器只取 editor_*，游戏界面只取上面那组，样式工厂（panel_style 等）两边共用。
#
# 取值来源：原先散落在 主屏.gd / 停靠面板.gd 里的硬编码色，原样收编，不改观感。

## 编辑器窗口底（比面板更深一档，用于"嵌在面板里的槽位"）
static func editor_bg() -> Color:
	return Color(0.09, 0.10, 0.12)


## 编辑器面板底 / 悬浮窗底
static func editor_panel() -> Color:
	return Color(0.12, 0.13, 0.16)


## 视口角标那种"更深的半透明底"
static func editor_panel_deep(a: float = 1.0) -> Color:
	return Color(0.05, 0.06, 0.08, a)


## 控件 hover / 选中时的提亮底
static func editor_panel_light() -> Color:
	return Color(0.20, 0.22, 0.27)


## 面板描边（冷灰蓝）
static func editor_line(a: float = 1.0) -> Color:
	return Color(0.35, 0.42, 0.52, a)


## 正文 / 副文 / 弱文
static func editor_text(a: float = 1.0) -> Color:
	return Color(0.88, 0.92, 0.96, a)


static func editor_text_sub(a: float = 1.0) -> Color:
	return Color(0.66, 0.72, 0.78, a)


static func editor_text_dim(a: float = 1.0) -> Color:
	return Color(0.62, 0.68, 0.74, a)


## 编辑器强调色（冷蓝，代替 HUD 的暗金）
static func editor_accent(a: float = 1.0) -> Color:
	return Color(0.55, 0.82, 1.0, a)


## 更深的强调蓝（角标描边用，别抢正文）
static func editor_accent_deep(a: float = 1.0) -> Color:
	return Color(0.45, 0.72, 1.0, a)


## 强调蓝上的高亮文字
static func editor_accent_soft(a: float = 1.0) -> Color:
	return Color(0.85, 0.93, 1.0, a)


## 分节标题（编辑器里的"金"：比纯强调蓝更稳，用来分段）
static func editor_gold(a: float = 1.0) -> Color:
	return Color(0.88, 0.76, 0.45, a)


## 通过 / 失败 / 提醒
static func editor_ok(a: float = 1.0) -> Color:
	return Color(0.50, 0.92, 0.56, a)


static func editor_bad(a: float = 1.0) -> Color:
	return Color(1.0, 0.50, 0.42, a)


static func editor_warn(a: float = 1.0) -> Color:
	return Color(1.0, 0.81, 0.42, a)


## 视口上的文字描边（压在 3D 场景上，必须有黑边才读得清）
static func editor_outline(a: float = 0.90) -> Color:
	return Color(0.0, 0.0, 0.0, a)


# ===========================================================================
# 样式工厂
# ===========================================================================

## 面板底：圆角深色 + 1px 亮边 + 外投影（"硬质面板"的标配）
static func panel_style(radius: int = 8, alpha: float = 0.94, border_alpha: float = 0.42,
		pad: float = 12.0) -> StyleBoxFlat:
	var b := bg()
	var a := accent()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(b.r * 1.15 + 0.012, b.g * 1.15 + 0.014, b.b * 1.15 + 0.018, alpha)
	sb.border_color = Color(a.r, a.g, a.b, border_alpha)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 8
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.48)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


## 内嵌小块的底（胶囊牌 / 队列格 / 图例块）：无投影，边更淡
static func inset_style(fill: Color, radius: int = 4, border: Color = Color(1, 1, 1, 0.10),
		pad_x: float = 8.0, pad_y: float = 2.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 6
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


## 按钮底：可带左侧 3px 分类色条
static func button_style(fill: Color, border: Color, stripe = null, radius: int = 5,
		pad_x: float = 8.0, pad_y: float = 4.0, border_w: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 6
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	if stripe is Color:
		var c: Color = stripe as Color
		sb.border_width_left = maxi(3, border_w)
		sb.bg_color = fill.lerp(Color(c.r, c.g, c.b, fill.a), 0.10)
	return sb


## 编辑器面板底：和 panel_style 是同一套构造，只把配色换到 editor_ 档，并去掉外投影
## （Godot 自带的 Dock/窗口都是平的，投影会让面板看起来"飘"在编辑器上面）
static func editor_panel_style(radius: int = 4, alpha: float = 0.97,
		border_alpha: float = 1.0, pad: float = 12.0) -> StyleBoxFlat:
	var sb := panel_style(radius, alpha, border_alpha, pad)
	var p := editor_panel()
	var l := editor_line()
	sb.bg_color = Color(p.r, p.g, p.b, alpha)
	sb.border_color = Color(l.r, l.g, l.b, border_alpha)
	sb.shadow_size = 0
	return sb


# ===========================================================================
# Theme（HUD 根节点用：一次配齐所有默认控件，子控件不用再各写一遍）
# ===========================================================================

## 中文字体兜底（美术主题里没配也得能显示）
static func _cjk_font() -> SystemFont:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray([
		"Microsoft YaHei", "SimHei", "Noto Sans CJK SC",
		"WenQuanYi Zen Hei", "PingFang SC", "sans-serif",
	])
	return sf


## 字号缩放：HUD 是"设计像素排版 + root.scale 反拉伸"，tooltip 由引擎在独立层画、
## 不吃 root.scale，所以必须按 zoom 预先乘一遍，物理字号才和面板正文一致。
static func _scaled_font(base: int, floor_px: int, zoom: float) -> int:
	return maxi(floor_px, int(round(float(base) * zoom)))


## 按钮文字色（只给主题用，和 0.95 的正文白拉开一点层次）
static func _btn_text() -> Color:
	return Color(0.92, 0.91, 0.87)


## 按钮四态（主题专用；编辑器按钮走下面的 _skin_editor_btn，配色分档）
static func _btn_normal_style() -> StyleBoxFlat:
	var a := accent()
	return button_style(Color(0.12, 0.13, 0.16, 0.96),
		Color(a.r, a.g, a.b, 0.45), a, 5, 10.0, 5.0)


static func _btn_hover_style() -> StyleBoxFlat:
	var a := accent()
	return button_style(Color(0.20, 0.22, 0.27, 0.98),
		Color(a.r, a.g, a.b, 0.95), a, 5, 10.0, 5.0)


static func _btn_pressed_style() -> StyleBoxFlat:
	var a := accent()
	return button_style(Color(0.30, 0.26, 0.16, 0.98), a, a, 5, 10.0, 5.0)


static func _btn_disabled_style() -> StyleBoxFlat:
	return button_style(Color(0.10, 0.10, 0.11, 0.85),
		Color(0.35, 0.35, 0.35, 0.5), null, 5, 10.0, 5.0)


## **全套默认主题**。HUD 根节点挂一次，其余界面想跟同一套观感就直接复用。
## zoom：UI 反拉伸系数（1.0 = 设计尺寸）。只影响按钮/提示/默认字号三处，
##       因为只有这几个字号会被引擎按物理像素画在独立层上。
static func build_theme(zoom: float = 1.0) -> Theme:
	var th: Theme = ArtKit.load_theme()
	if th == null:
		th = Theme.new()
	if th.default_font == null:
		th.default_font = _cjk_font()

	var fs_value: int = _scaled_font(FS_VALUE, 18, zoom)
	var fs_body: int = _scaled_font(FS_SUB, 16, zoom)
	var a := accent()

	th.default_font_size = fs_value

	# --- 面板 ---
	th.set_stylebox("panel", "PanelContainer", panel_style(7, 0.94, 0.52, 12.0))
	th.set_stylebox("panel", "Panel", inset_style(Color(0.07, 0.08, 0.10, 0.94), 6,
		Color(a.r, a.g, a.b, 0.30), 10.0, 8.0))

	# --- 按钮 ---
	th.set_stylebox("normal", "Button", _btn_normal_style())
	th.set_stylebox("hover", "Button", _btn_hover_style())
	th.set_stylebox("pressed", "Button", _btn_pressed_style())
	th.set_stylebox("disabled", "Button", _btn_disabled_style())
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", _btn_text())
	th.set_color("font_hover_color", "Button", Color(1.0, 1.0, 1.0))
	th.set_color("font_pressed_color", "Button", a)
	th.set_color("font_disabled_color", "Button", Color(0.52, 0.52, 0.50))
	th.set_font_size("font_size", "Button", fs_value)

	# --- 提示气泡（tooltip 是命令卡"禁用原因"的唯一补充说明，必须清楚）---
	th.set_stylebox("panel", "TooltipPanel", panel_style(6, 0.98, 0.60, 10.0))
	th.set_color("font_color", "TooltipLabel", Color(0.93, 0.92, 0.86))
	th.set_font_size("font_size", "TooltipLabel", fs_body)

	# --- 血条 ---
	var bar_bg := inset_style(Color(0.08, 0.08, 0.09, 0.95), 2,
		Color(0.3, 0.3, 0.32, 0.9), 0.0, 0.0)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.36, 0.78, 0.40)
	bar_fill.set_corner_radius_all(2)
	th.set_stylebox("background", "ProgressBar", bar_bg)
	th.set_stylebox("fill", "ProgressBar", bar_fill)

	# --- 文字 ---
	th.set_color("font_color", "Label", text_main())
	th.set_font_size("font_size", "Label", FS_VALUE)
	# 输入框只有字号（HUD 目前没有输入框，先备着，免得以后又手写 16）
	th.set_font_size("font_size", "LineEdit", fs_body)
	return th


# ===========================================================================
# 控件工厂（把"十行颜色"压成一行）
# ===========================================================================

## 通用按钮。kind:
##   normal  —— 编辑器冷灰底 + 细描边（工具栏默认；走 editor_ 分档，别把 HUD 暖金铺满编辑器）
##   primary —— 实心 accent 底，深色字（主操作）
##   danger  —— 红色语义（删除 / 不可逆）
##   ghost   —— 无底无框，只有 hover 描边（工具栏、菜单旁）
static func btn(text: String, kind: String = "normal") -> Button:
	var b := Button.new()
	b.text = text
	var a := accent()
	match kind:
		"primary":
			var face := Color(a.r, a.g, a.b, 0.92)
			b.add_theme_stylebox_override("normal", button_style(face, a, null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("hover",
				button_style(a.lerp(Color.WHITE, 0.15), Color.WHITE, null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("pressed",
				button_style(a.darkened(0.15), a.darkened(0.2), null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("disabled",
				button_style(Color(a.r, a.g, a.b, 0.35), Color(a.r, a.g, a.b, 0.30),
					null, 5, 10.0, 5.0))
			b.add_theme_color_override("font_color", Color(0.10, 0.09, 0.06))
			b.add_theme_color_override("font_hover_color", Color(0.06, 0.05, 0.03))
			b.add_theme_color_override("font_pressed_color", Color(0.06, 0.05, 0.03))
			b.add_theme_color_override("font_disabled_color", Color(0.30, 0.28, 0.24))
		"danger":
			var red := enemy_color()
			b.add_theme_stylebox_override("normal",
				button_style(Color(red.r, red.g, red.b, 0.88), red, null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("hover",
				button_style(red.lerp(Color.WHITE, 0.18), Color.WHITE, null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("pressed",
				button_style(red.darkened(0.18), red.darkened(0.25), null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("disabled",
				button_style(Color(red.r, red.g, red.b, 0.32), Color(red.r, red.g, red.b, 0.28),
					null, 5, 10.0, 5.0))
			b.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
			b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
			b.add_theme_color_override("font_pressed_color", Color(1.0, 0.92, 0.90))
			b.add_theme_color_override("font_disabled_color", Color(0.55, 0.45, 0.44))
		"ghost":
			b.add_theme_stylebox_override("normal",
				button_style(Color(0, 0, 0, 0), Color(0, 0, 0, 0), null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("hover",
				button_style(Color(a.r, a.g, a.b, 0.10), Color(a.r, a.g, a.b, 0.75),
					null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("pressed",
				button_style(Color(a.r, a.g, a.b, 0.18), a, null, 5, 10.0, 5.0))
			b.add_theme_stylebox_override("disabled",
				button_style(Color(0, 0, 0, 0), Color(0, 0, 0, 0), null, 5, 10.0, 5.0))
			b.add_theme_color_override("font_color", text_main())
			b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
			b.add_theme_color_override("font_pressed_color", a)
			b.add_theme_color_override("font_disabled_color", Color(0.52, 0.52, 0.50))
		_:
			_skin_editor_btn(b, 5, 10.0, 5.0, false)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


## 编辑器按钮的共同皮肤（normal / btn / tool_button 共用一份，别各写各的）
static func _skin_editor_btn(b: Button, radius: int, pad_x: float, pad_y: float,
		stripe_on_press: bool) -> void:
	var fill := editor_panel()
	var line := editor_line()
	var hot := editor_accent()
	b.add_theme_stylebox_override("normal",
		button_style(Color(fill.r, fill.g, fill.b, 0.96), Color(line.r, line.g, line.b, 0.55),
			null, radius, pad_x, pad_y))
	b.add_theme_stylebox_override("hover",
		button_style(editor_panel_light(), Color(hot.r, hot.g, hot.b, 0.85),
			null, radius, pad_x, pad_y))
	b.add_theme_stylebox_override("pressed",
		button_style(editor_panel_light(), hot, hot if stripe_on_press else null,
			radius, pad_x, pad_y))
	b.add_theme_stylebox_override("disabled",
		button_style(Color(fill.r, fill.g, fill.b, 0.55), Color(line.r, line.g, line.b, 0.25),
			null, radius, pad_x, pad_y))
	b.add_theme_color_override("font_color", editor_text())
	b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	b.add_theme_color_override("font_pressed_color", editor_accent_soft())
	b.add_theme_color_override("font_disabled_color", editor_text_dim(0.55))
	b.add_theme_font_size_override("font_size", FS_BODY)


## 一个带面板底的空盒子（往里塞 VBox 即可）；默认观感同主题的 PanelContainer
static func panel_box(radius: int = 8, alpha: float = 0.94) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_style(radius, alpha))
	return p


## 一行说明文字（弱色，12 号）
static func caption(text: String, size: int = FS_CAPTION) -> Label:
	return label(text, size, text_sub())


## 编辑器左侧栏那种"方块工具按钮"：深底、细冷边，按下时左侧亮条
static func tool_button(text: String, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	_skin_editor_btn(b, 4, 6.0, 6.0, true)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


## 一条 1px 的分隔线（主色，alpha 控制强弱）
static func rule(alpha: float = 0.45) -> ColorRect:
	var r := ColorRect.new()
	var a := accent()
	r.color = Color(a.r, a.g, a.b, alpha)
	r.custom_minimum_size = Vector2(0.0, 1.0)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# ===========================================================================
# 图标（美术/图标/*.svg，全部是白色单色路径 —— 用 modulate 上色）
# ===========================================================================
#
# 为什么统一走这一层：以前"图标"是拿首字/字母当图（左、右、B、空），
# 远看像标签、近看像占位符，玩家一眼就说"太简陋"。
# 这里规定：**能上图标就不写字**，图标只允许 美术/图标/ 下的资源，
# 找不到时才退回文字（并且会打一条日志，方便发现漏配）。

const ICON_DIR := "res://美术/图标/"
static var _icon_cache: Dictionary = {}
static var _icon_miss: Array[String] = []


static func icon_tex(name: String) -> Texture2D:
	if name.is_empty():
		return null
	if _icon_cache.has(name):
		return _icon_cache[name] as Texture2D
	var path := ICON_DIR + name + ".svg"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	if tex == null and not _icon_miss.has(name):
		_icon_miss.append(name)
		push_warning("[界面规格] 缺图标：" + path)
	_icon_cache[name] = tex
	return tex


## 一个图标控件（正方形，centered，按 px 定尺寸）
static func icon(name: String, px: float, col: Color = Color(1, 1, 1, 1)) -> Control:
	var holder := Control.new()
	# **严格 px×px 且不参与拉伸**：以前只设 custom_minimum_size，
	# HBox 一拉长 holder 就变宽，图标按 KEEP_ASPECT_CENTERED 缩到一侧，
	# 看起来就是"图标跑出胶囊、贴到角落"。
	holder.custom_minimum_size = Vector2(px, px)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.set_meta("iname", "")
	set_icon(holder, name, col)
	return holder


## 就地换图标（同一控件反复调不会重建 —— 避免 8Hz 刷新把贴图节点抖成闪烁）
static func set_icon(holder: Control, name: String, col: Color = Color(1, 1, 1, 1)) -> void:
	if holder == null:
		return
	if String(holder.get_meta("iname", "")) == name:
		return
	holder.set_meta("iname", name)
	for c in holder.get_children():
		holder.remove_child(c)
		c.queue_free()
	var tex := icon_tex(name)
	if tex == null:
		return
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.modulate = col
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(tr)


## 图标 + 文字的小胶囊（资源条 / 数值格共用）
static func icon_label_row(icon_name: String, text: String, px: float, col: Color,
		size: int = FS_CAPTION, gap: float = 4.0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(gap))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon(icon_name, px, col))
	var lb := label(text, size, col)
	row.add_child(lb)
	return row


## 统一做一个 Label（字号只允许上面六级）
static func label(text: String, size: int, col: Color,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", clamp_size(size))
	lb.add_theme_color_override("font_color", col)
	lb.horizontal_alignment = align
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lb


## 把字号夹到有限阶上（防止手滑写 15 又把层级搞平）
static func clamp_size(size: int) -> int:
	var allowed := [FS_CAPTION, FS_BODY, FS_SUB, FS_VALUE, FS_TITLE, FS_HERO]
	var best: int = FS_CAPTION
	var best_d: int = 999
	for s in allowed:
		var d: int = absi(size - int(s))
		if d < best_d:
			best_d = d
			best = int(s)
	return best


## 等宽字体（只给纯数字用；中文绝不吃等宽，避免雅黑缺字变方块）
static func mono_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Consolas", "Cascadia Mono", "DejaVu Sans Mono",
		"Liberation Mono", "Courier New", "monospace",
	])
	return f

# ===========================================================================
# 编辑器 Theme 资源（token → 正经 Theme，而不是一堆散落 add_theme_*_override）
# ===========================================================================
#
# 为什么要有这一节：编辑器 UI 以前每个按钮/面板都在运行时调 Spec.btn() 塞 StyleBoxOverride，
# 本质上是"把主题写死在控件上"——换个面板/加个控件就漏一套。这里把同一份 token
# 一次编译成 Theme 资源（addons/map_editor/编辑器主题.tres），编辑器根节点挂一次，
# 所有 Button / TabContainer / Tree / ItemList / LineEdit / PopupMenu 自动继承。
#
# 生成命令：
#   godot --headless --path . --script 工具/生成编辑器主题.gd
# 改 token 后重跑即可；.tres 是提交进项目的正经资源，不是自制 cfg。

## 编辑器按钮的 normal / hover / pressed / disabled 四态
static func _editor_btn_styles() -> Array:
	var fill := editor_panel()
	var line := editor_line()
	var hot := editor_accent()
	var normal := button_style(Color(fill.r, fill.g, fill.b, 0.96),
		Color(line.r, line.g, line.b, 0.55), null, 4, 8.0, 5.0)
	var hover := button_style(editor_panel_light(), Color(hot.r, hot.g, hot.b, 0.85),
		null, 4, 8.0, 5.0)
	var pressed := button_style(editor_panel_light(), hot, hot, 4, 8.0, 5.0)
	var disabled := button_style(Color(fill.r, fill.g, fill.b, 0.55),
		Color(line.r, line.g, line.b, 0.25), null, 4, 8.0, 5.0)
	return [normal, hover, pressed, disabled]


## 一套 tab 皮肤（选中页压亮 + 顶部强调线）
static func _editor_tab_style(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var p := editor_panel() if selected else editor_bg()
	var l := editor_line()
	var a := editor_accent()
	sb.bg_color = p
	sb.border_color = Color(a.r, a.g, a.b, 0.95) if selected else Color(l.r, l.g, l.b, 0.45)
	sb.set_border_width_all(1)
	sb.border_width_top = 2 if selected else 1
	sb.border_width_bottom = 0
	sb.set_corner_radius_all(4)
	sb.corner_detail = 6
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 5.0
	return sb


## **编辑器全量 Theme**。用 ResourceSaver 存成 .tres，主屏/Dock 直接 preload 挂上。
static func build_editor_theme() -> Theme:
	var th := Theme.new()
	th.default_font = _cjk_font()
	th.default_font_size = FS_BODY

	var line := editor_line()
	var accent := editor_accent()
	var accent_soft := editor_accent_soft()
	var panel := editor_panel()
	var text := editor_text()
	var sub := editor_text_sub()
	var dim := editor_text_dim()

	# --- 容器 / 面板 ---
	th.set_stylebox("panel", "PanelContainer", editor_panel_style(4, 0.97, 0.85, 12.0))
	th.set_stylebox("panel", "Panel", inset_style(editor_panel_deep(0.94), 4,
		Color(line.r, line.g, line.b, 0.55), 10.0, 8.0))
	th.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	th.set_stylebox("panel", "TabContainer", editor_panel_style(4, 1.0, 0.65, 8.0))

	# --- 按钮 ---
	var btn := _editor_btn_styles()
	th.set_stylebox("normal", "Button", btn[0])
	th.set_stylebox("hover", "Button", btn[1])
	th.set_stylebox("pressed", "Button", btn[2])
	th.set_stylebox("disabled", "Button", btn[3])
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", text)
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_pressed_color", "Button", accent_soft)
	th.set_color("font_disabled_color", "Button", editor_text_dim(0.55))
	th.set_font_size("font_size", "Button", FS_BODY)

	# --- 页签 ---
	th.set_stylebox("tab_selected", "TabContainer", _editor_tab_style(true))
	th.set_stylebox("tab_unselected", "TabContainer", _editor_tab_style(false))
	th.set_stylebox("tab_hovered", "TabContainer", _editor_tab_style(false))
	th.set_stylebox("tab_disabled", "TabContainer", _editor_tab_style(false))
	th.set_color("font_selected_color", "TabContainer", accent_soft)
	th.set_color("font_unselected_color", "TabContainer", sub)
	th.set_color("font_hovered_color", "TabContainer", Color.WHITE)
	th.set_color("font_disabled_color", "TabContainer", dim)
	th.set_font_size("font_size", "TabContainer", FS_BODY)
	th.set_constant("side_margin", "TabContainer", 4)

	# --- 列表 / 历史树（Tree 是撤销历史面板的底座）---
	th.set_stylebox("panel", "Tree", inset_style(editor_panel_deep(0.62), 3,
		Color(line.r, line.g, line.b, 0.45), 4.0, 4.0))
	th.set_stylebox("focus", "Tree", StyleBoxEmpty.new())
	var sel := button_style(editor_panel_light(), accent, null, 3, 4.0, 2.0)
	th.set_stylebox("selected", "Tree", sel)
	th.set_stylebox("selected_focus", "Tree", sel)
	var cursor := StyleBoxFlat.new()
	cursor.bg_color = Color(accent.r, accent.g, accent.b, 0.08)
	cursor.border_color = Color(accent.r, accent.g, accent.b, 0.55)
	cursor.set_border_width_all(1)
	cursor.set_corner_radius_all(2)
	th.set_stylebox("cursor", "Tree", cursor)
	th.set_stylebox("cursor_unfocused", "Tree", cursor)
	th.set_color("font_color", "Tree", text)
	th.set_color("font_selected_color", "Tree", accent_soft)
	th.set_color("font_disabled_color", "Tree", dim)
	th.set_color("guide_color", "Tree", Color(line.r, line.g, line.b, 0.22))
	th.set_color("relationship_line_color", "Tree", Color(line.r, line.g, line.b, 0.35))
	th.set_font_size("font_size", "Tree", FS_BODY)
	th.set_constant("v_separation", "Tree", 4)
	th.set_constant("h_separation", "Tree", 6)

	th.set_stylebox("panel", "ItemList", inset_style(editor_panel_deep(0.62), 3,
		Color(line.r, line.g, line.b, 0.45), 4.0, 4.0))
	th.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	th.set_stylebox("selected", "ItemList", sel)
	th.set_stylebox("selected_focus", "ItemList", sel)
	var il_cursor := StyleBoxFlat.new()
	il_cursor.bg_color = Color(accent.r, accent.g, accent.b, 0.08)
	il_cursor.border_color = Color(accent.r, accent.g, accent.b, 0.55)
	il_cursor.set_border_width_all(1)
	il_cursor.set_corner_radius_all(2)
	th.set_stylebox("cursor", "ItemList", il_cursor)
	th.set_stylebox("cursor_unfocused", "ItemList", il_cursor)
	th.set_color("font_color", "ItemList", text)
	th.set_color("font_selected_color", "ItemList", accent_soft)
	th.set_color("font_hovered_color", "ItemList", Color.WHITE)
	th.set_font_size("font_size", "ItemList", FS_BODY)
	th.set_constant("v_separation", "ItemList", 4)
	th.set_constant("h_separation", "ItemList", 6)

	# --- 输入框 ---
	var input := inset_style(editor_panel_deep(0.92), 3,
		Color(line.r, line.g, line.b, 0.55), 1.0, 1.0)
	var input_focus := input.duplicate() as StyleBoxFlat
	input_focus.border_color = accent
	th.set_stylebox("normal", "LineEdit", input)
	th.set_stylebox("focus", "LineEdit", input_focus)
	th.set_stylebox("read_only", "LineEdit", input)
	th.set_color("font_color", "LineEdit", text)
	th.set_color("font_placeholder_color", "LineEdit", dim)
	th.set_color("caret_color", "LineEdit", accent)
	th.set_color("selection_color", "LineEdit", Color(accent.r, accent.g, accent.b, 0.30))
	th.set_font_size("font_size", "LineEdit", FS_BODY)
	th.set_font_size("font_size", "SpinBox", FS_BODY)

	# --- 下拉 / 右键菜单 ---
	th.set_stylebox("panel", "PopupMenu", editor_panel_style(4, 0.99, 0.95, 6.0))
	th.set_stylebox("hover", "PopupMenu", button_style(editor_panel_light(), accent,
		null, 3, 6.0, 3.0))
	th.set_stylebox("separator", "PopupMenu", StyleBoxLine.new())
	th.set_color("font_color", "PopupMenu", text)
	th.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	th.set_color("font_accelerator_color", "PopupMenu", dim)
	th.set_font_size("font_size", "PopupMenu", FS_BODY)

	# --- 提示气泡 ---
	th.set_stylebox("panel", "TooltipPanel", editor_panel_style(4, 0.99, 0.95, 8.0))
	th.set_color("font_color", "TooltipLabel", text)
	th.set_font_size("font_size", "TooltipLabel", FS_BODY)

	# --- 文本 ---
	th.set_color("font_color", "Label", text)
	th.set_font_size("font_size", "Label", FS_BODY)
	th.set_color("default_color", "RichTextLabel", text)
	th.set_font_size("normal_font_size", "RichTextLabel", FS_BODY)
	th.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	th.set_color("font_color", "CheckBox", text)
	th.set_font_size("font_size", "CheckBox", FS_BODY)
	th.set_color("font_color", "CheckButton", text)
	th.set_font_size("font_size", "CheckButton", FS_BODY)

	# --- 分隔线 / 滑条 ---
	var sep := StyleBoxLine.new()
	sep.color = Color(line.r, line.g, line.b, 0.35)
	sep.thickness = 1
	th.set_stylebox("separator", "HSeparator", sep)
	th.set_stylebox("separator", "VSeparator", sep)
	th.set_stylebox("slider", "HSlider", inset_style(editor_panel_deep(0.85), 3,
		Color(line.r, line.g, line.b, 0.45), 0.0, 0.0))
	th.set_stylebox("grabber_area", "HSlider", inset_style(accent, 3,
		Color(accent.r, accent.g, accent.b, 0.0), 0.0, 0.0))
	th.set_stylebox("grabber_area_highlight", "HSlider", inset_style(accent_soft, 3,
		Color(accent.r, accent.g, accent.b, 0.0), 0.0, 0.0))

	# --- 语义 Label 变体（代码只设 theme_type_variation，不写颜色）---
	_label_variation(th, "EditorTitle", editor_gold(), FS_BODY)
	_label_variation(th, "EditorHint", dim, FS_BODY)
	_label_variation(th, "EditorAccent", accent_soft, FS_BODY)
	_label_variation(th, "EditorOk", editor_ok(), FS_BODY)
	_label_variation(th, "EditorBad", editor_bad(), FS_BODY)
	_label_variation(th, "EditorWarn", editor_warn(), FS_BODY)
	_label_variation(th, "EditorCaption", dim, FS_CAPTION)

	# --- 面板 / 工具按钮变体（角标、对话框、地形色块）---
	th.set_type_variation("EditorBadge", "PanelContainer")
	th.set_stylebox("panel", "EditorBadge",
		inset_style(editor_panel_deep(0.88), 3, Color(editor_accent_deep().r,
			editor_accent_deep().g, editor_accent_deep().b, 0.75), 6.0, 6.0))
	th.set_type_variation("EditorDialog", "PanelContainer")
	th.set_stylebox("panel", "EditorDialog", editor_panel_style(4, 0.97, 1.0, 16.0))

	# --- 归属卡（对象页里唯一"必须一眼锁死"的块）---
	# 左侧 4px 亮条 + 深底：位置再靠上也压得住，不会被下面一排小按钮吃掉。
	th.set_type_variation("EditorOwnerCard", "PanelContainer")
	var owner_sb := editor_panel_style(4, 0.96, 1.0, 10.0)
	owner_sb.bg_color = editor_panel_deep(0.90)
	owner_sb.border_color = Color(accent.r, accent.g, accent.b, 0.85)
	owner_sb.border_width_left = 4
	th.set_stylebox("panel", "EditorOwnerCard", owner_sb)
	# 归属值：18px 亮字 + 深描边（比正文大两档，物理上就"立"起来了）
	_label_variation(th, "EditorOwnerValue", text, FS_VALUE)
	th.set_color("font_outline_color", "EditorOwnerValue", Color(0, 0, 0, 0.88))
	th.set_constant("outline_size", "EditorOwnerValue", 5)
	# 归属药丸按钮：中性底；选中态靠按钮自己刷玩家色，这里只给形状与焦点
	th.set_type_variation("EditorOwnerPill", "Button")
	var pill_n := button_style(editor_panel_deep(0.55),
		Color(line.r, line.g, line.b, 0.55), null, 12, 12.0, 6.0)
	var pill_h := button_style(editor_panel_light(), Color(1, 1, 1, 0.85), null, 12, 12.0, 6.0)
	var pill_p := button_style(editor_panel_light(), accent_soft,
		accent_soft, 12, 12.0, 6.0, 2)
	th.set_stylebox("normal", "EditorOwnerPill", pill_n)
	th.set_stylebox("hover", "EditorOwnerPill", pill_h)
	th.set_stylebox("pressed", "EditorOwnerPill", pill_p)
	th.set_stylebox("disabled", "EditorOwnerPill", pill_n)
	th.set_color("font_color", "EditorOwnerPill", text)
	th.set_color("font_hover_color", "EditorOwnerPill", Color.WHITE)
	th.set_color("font_pressed_color", "EditorOwnerPill", Color.WHITE)
	th.set_font_size("font_size", "EditorOwnerPill", FS_BODY)
	th.set_type_variation("EditorSplatGrass", "Button")
	th.set_type_variation("EditorSplatDirt", "Button")
	th.set_type_variation("EditorSplatRock", "Button")
	th.set_type_variation("EditorSplatSand", "Button")
	_splat_variation(th, "EditorSplatGrass", Color(0.26, 0.48, 0.18))
	_splat_variation(th, "EditorSplatDirt", Color(0.44, 0.32, 0.18))
	_splat_variation(th, "EditorSplatRock", Color(0.42, 0.43, 0.46))
	_splat_variation(th, "EditorSplatSand", Color(0.72, 0.64, 0.42))
	return th


static func _label_variation(th: Theme, name: String, col: Color, size: int) -> void:
	th.set_type_variation(name, "Label")
	th.set_color("font_color", name, col)
	th.set_font_size("font_size", name, size)


## 地形色块按钮：正常 = 本色深底，按下 = 亮边（选中在按钮组里另有 pressed 态）
static func _splat_variation(th: Theme, name: String, col: Color) -> void:
	var normal := button_style(col, Color(0, 0, 0, 0), null, 4, 6.0, 5.0)
	var pressed := button_style(col, editor_gold(), null, 4, 6.0, 5.0, 2)
	th.set_stylebox("normal", name, normal)
	th.set_stylebox("hover", name, pressed)
	th.set_stylebox("pressed", name, pressed)
	th.set_stylebox("disabled", name, normal)
	th.set_color("font_color", name, editor_text())
	th.set_color("font_hover_color", name, Color.WHITE)
	th.set_color("font_pressed_color", name, Color.WHITE)
	th.set_font_size("font_size", name, FS_BODY)


# --- 控件工厂：只做结构，皮肤全部来自上面的 Theme ---

static func editor_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	return b


static func editor_tool_button(text: String, tip: String = "") -> Button:
	var b := editor_button(text)
	b.tooltip_text = tip
	return b


static func editor_label(text: String, variation: StringName = &"") -> Label:
	var l := Label.new()
	l.text = text
	if variation != &"":
		l.theme_type_variation = variation
	return l