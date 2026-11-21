extends RefCounted
## 《战争原岛》开发者编辑器 · 深色工具主题
## 属于：Screens/editor（开发工具，不进发行版）
##
## 设计口径（2026-11-21 玩家指定）：
##   · 深岩底 #12161F，分区卡片 #1B2230，圆角描边，不用 Godot 默认灰框；
##   · 阵营色只做标签/强调，不铺满面板；
##   · 数字用等宽字体，正文用系统中文字体，一眼能分清"值"和"说明"。
##
## 这里只做"皮肤 + 控件工厂"，不碰业务数据。页面通过 preload 拿静态函数。

const BG := Color("#12161F")
const BG_TOP := Color("#151B27")
const CARD := Color("#1B2230")
const CARD_HI := Color("#212A3A")
const CARD_DEEP := Color("#161C28")
const INPUT := Color("#141A24")
const STROKE := Color("#2B3548")
const STROKE_HI := Color("#3A4862")
const TEXT := Color("#E8EDF7")
const TEXT_SUB := Color("#96A3BA")
const TEXT_DIM := Color("#617089")
const ACCENT := Color("#4EA1FF")
const ACCENT_DIM := Color("#2C6FB8")
const GOLD := Color("#F0B95A")
const GREEN := Color("#45D6A2")
const RED := Color("#FF6E6E")
const PURPLE := Color("#B18CFF")
const CYAN := Color("#4ED8D8")

const FACTION := {
	"alliance": Color("#4EA1FF"),
	"bandit": Color("#F0B95A"),
	"murloc": Color("#45D6A2"),
	"enemy": Color("#FF6E6E"),
	"neutral": Color("#96A3BA"),
}

static var _font_ui: SystemFont = null
static var _font_bold: SystemFont = null
static var _font_mono: SystemFont = null
static var _font_mono_bold: SystemFont = null


# ===========================================================================
# 字体
# ===========================================================================
static func _make_font(weight: int, mono: bool) -> SystemFont:
	var f := SystemFont.new()
	if mono:
		f.font_names = PackedStringArray([
			"Cascadia Mono", "JetBrains Mono", "Consolas", "Menlo", "monospace",
		])
	else:
		f.font_names = PackedStringArray([
			"Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans SC",
			"PingFang SC", "Segoe UI", "sans-serif",
		])
	f.font_weight = weight
	f.allow_system_fallback = true
	return f


static func ui_font() -> Font:
	if _font_ui == null:
		_font_ui = _make_font(400, false)
	return _font_ui


static func bold_font() -> Font:
	if _font_bold == null:
		_font_bold = _make_font(700, false)
	return _font_bold


static func mono_font() -> Font:
	if _font_mono == null:
		_font_mono = _make_font(400, true)
	return _font_mono


static func mono_bold_font() -> Font:
	if _font_mono_bold == null:
		_font_mono_bold = _make_font(700, true)
	return _font_mono_bold


static func faction_color(id: String) -> Color:
	return FACTION.get(id, FACTION["neutral"])


# ===========================================================================
# StyleBox
# ===========================================================================
static func box(fill: Color, border: Color, radius: int = 10, border_width: int = 1,
		pad_x: float = 12.0, pad_y: float = 8.0, shadow: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(border_width)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 8
	sb.anti_aliasing = true
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	if shadow > 0:
		sb.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
		sb.shadow_size = shadow
		sb.shadow_offset = Vector2(0.0, 2.0)
	return sb


static func card(accent: Color = Color(0, 0, 0, 0), pad: float = 18.0, radius: int = 14) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := box(CARD, STROKE, radius, 1, pad, pad, 10)
	if accent.a > 0.0:
		sb.border_color = Color(accent.r, accent.g, accent.b, 0.34)
	p.add_theme_stylebox_override("panel", sb)
	return p


static func inset(fill: Color = INPUT, border: Color = STROKE, pad: float = 12.0, radius: int = 10) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(fill, border, radius, 1, pad, pad))
	return p


# ===========================================================================
# 控件工厂
# ===========================================================================
static func label(text: String, variation: StringName = &"EditorBody",
		color: Color = Color(0, 0, 0, 0)) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if color.a > 0.0:
		l.add_theme_color_override("font_color", color)
	return l


static func caption(text: String, color: Color = TEXT_DIM) -> Label:
	return label(text, &"EditorCaps", color)


static func field_label(text: String) -> Label:
	return label(text, &"EditorFieldLabel")


static func value_label(text: String, color: Color = TEXT) -> Label:
	var l := label(text, &"EditorNum")
	l.add_theme_color_override("font_color", color)
	return l


static func big_value(text: String, color: Color = TEXT) -> Label:
	var l := label(text, &"EditorNumBig")
	l.add_theme_color_override("font_color", color)
	return l


static func chip(text: String, color: Color = ACCENT) -> PanelContainer:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := box(Color(color.r, color.g, color.b, 0.14),
		Color(color.r, color.g, color.b, 0.46), 20, 1, 9.0, 3.0)
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", ui_font())
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", color)
	p.add_child(l)
	return p


static func set_chip(p: PanelContainer, text: String, color: Color = ACCENT) -> void:
	if p == null:
		return
	var sb := box(Color(color.r, color.g, color.b, 0.14),
		Color(color.r, color.g, color.b, 0.46), 20, 1, 9.0, 3.0)
	p.add_theme_stylebox_override("panel", sb)
	if p.get_child_count() > 0 and p.get_child(0) is Label:
		var l := p.get_child(0) as Label
		l.text = text
		l.add_theme_color_override("font_color", color)


static func dot(color: Color, size: float = 7.0) -> Control:
	var c := ColorRect.new()
	c.color = color
	c.custom_minimum_size = Vector2(size, size)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func hairline(color: Color = STROKE, height: float = 1.0) -> Control:
	var c := ColorRect.new()
	c.color = color
	c.custom_minimum_size = Vector2(0.0, height)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func num_field(text: String = "", width: float = 0.0) -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	le.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	le.add_theme_font_override("font", mono_font())
	le.add_theme_font_size_override("font_size", 15)
	le.custom_minimum_size = Vector2(width, 34.0) if width > 0.0 else Vector2(0.0, 34.0)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return le


static func text_field(text: String = "", placeholder: String = "") -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	le.placeholder_text = placeholder
	le.custom_minimum_size = Vector2(0.0, 34.0)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return le


static func toggle(text: String, on: bool, accent: Color = ACCENT, width: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = on
	b.focus_mode = Control.FOCUS_NONE
	if width > 0.0:
		b.custom_minimum_size = Vector2(width, 32.0)
	b.add_theme_stylebox_override("normal", box(INPUT, STROKE, 8, 1, 10.0, 5.0))
	b.add_theme_stylebox_override("hover", box(CARD_HI, STROKE_HI, 8, 1, 10.0, 5.0))
	b.add_theme_stylebox_override("pressed", box(Color(accent.r, accent.g, accent.b, 0.20),
		accent, 8, 1, 10.0, 5.0))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", TEXT_SUB)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", accent)
	b.add_theme_color_override("font_hover_pressed_color", accent)
	b.add_theme_font_size_override("font_size", 13)
	return b


static func small_button(text: String, accent: Color = ACCENT) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0.0, 32.0)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", TEXT_SUB)
	b.add_theme_color_override("font_hover_color", accent)
	b.add_theme_stylebox_override("normal", box(INPUT, STROKE, 8, 1, 11.0, 5.0))
	b.add_theme_stylebox_override("hover", box(CARD_HI, Color(accent.r, accent.g, accent.b, 0.65), 8, 1, 11.0, 5.0))
	b.add_theme_stylebox_override("pressed", box(Color(accent.r, accent.g, accent.b, 0.20), accent, 8, 1, 11.0, 5.0))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


static func section_head(title: String, eyebrow: String = "", accent: Color = ACCENT,
		trailing: Control = null) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var bar := ColorRect.new()
	bar.color = accent
	bar.custom_minimum_size = Vector2(3.0, 18.0)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(bar)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	if not eyebrow.is_empty():
		v.add_child(caption(eyebrow, Color(accent.r, accent.g, accent.b, 0.9)))
	v.add_child(label(title, &"EditorH2"))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(v)
	h.add_child(spacer())
	if trailing != null:
		h.add_child(trailing)
	return h


# ===========================================================================
# Theme
# ===========================================================================
static func build_theme() -> Theme:
	var th := Theme.new()
	th.default_font = ui_font()
	th.default_font_size = 15

	# 文字变体
	_variation(th, &"EditorH1", bold_font(), 30, TEXT)
	_variation(th, &"EditorH2", bold_font(), 19, TEXT)
	_variation(th, &"EditorH3", bold_font(), 15, TEXT)
	_variation(th, &"EditorBody", ui_font(), 14, Color("#CBD5E6"))
	_variation(th, &"EditorSub", ui_font(), 13, TEXT_SUB)
	_variation(th, &"EditorCaps", bold_font(), 11, TEXT_DIM)
	_variation(th, &"EditorFieldLabel", ui_font(), 12, TEXT_SUB)
	_variation(th, &"EditorNum", mono_font(), 14, TEXT)
	_variation(th, &"EditorNumBig", mono_bold_font(), 30, TEXT)
	_variation(th, &"EditorNumHuge", mono_bold_font(), 44, TEXT)

	# Label 默认
	th.set_color("font_color", "Label", Color("#CBD5E6"))
	th.set_font("font", "Label", ui_font())
	th.set_font_size("font_size", "Label", 14)

	# 面板
	th.set_stylebox("panel", "PanelContainer", box(CARD, STROKE, 14, 1, 18.0, 18.0, 8))
	th.set_stylebox("panel", "Panel", box(CARD, STROKE, 12, 1, 12.0, 12.0))
	th.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# 按钮
	var bn := box(CARD_HI, STROKE, 9, 1, 14.0, 8.0)
	var bh := box(Color("#26324A"), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.75), 9, 1, 14.0, 8.0)
	var bp := box(Color(ACCENT.r * 0.32, ACCENT.g * 0.32, ACCENT.b * 0.32, 0.95), ACCENT, 9, 1, 14.0, 8.0)
	var bd := box(Color("#181F2C"), Color("#252D3D"), 9, 1, 14.0, 8.0)
	th.set_stylebox("normal", "Button", bn)
	th.set_stylebox("hover", "Button", bh)
	th.set_stylebox("pressed", "Button", bp)
	th.set_stylebox("disabled", "Button", bd)
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", TEXT)
	th.set_color("font_hover_color", "Button", Color("#FFFFFF"))
	th.set_color("font_pressed_color", "Button", Color("#FFFFFF"))
	th.set_color("font_hover_pressed_color", "Button", Color("#FFFFFF"))
	th.set_color("font_disabled_color", "Button", TEXT_DIM)
	th.set_font("font", "Button", ui_font())
	th.set_font_size("font_size", "Button", 14)
	th.set_constant("h_separation", "Button", 8)

	# 输入框
	var ln := box(INPUT, STROKE, 8, 1, 10.0, 6.0)
	var lf := box(INPUT, ACCENT, 8, 1, 10.0, 6.0)
	th.set_stylebox("normal", "LineEdit", ln)
	th.set_stylebox("focus", "LineEdit", lf)
	th.set_stylebox("read_only", "LineEdit", box(CARD_DEEP, STROKE, 8, 1, 10.0, 6.0))
	th.set_color("font_color", "LineEdit", TEXT)
	th.set_color("font_placeholder_color", "LineEdit", TEXT_DIM)
	th.set_color("caret_color", "LineEdit", ACCENT)
	th.set_color("selection_color", "LineEdit", Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.30))
	th.set_font("font", "LineEdit", ui_font())
	th.set_font_size("font_size", "LineEdit", 14)

	# OptionButton
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb: StyleBox = bn
		if state == "hover" or state == "pressed":
			sb = bh
		elif state == "disabled":
			sb = bd
		elif state == "focus":
			sb = StyleBoxEmpty.new()
		th.set_stylebox(state, "OptionButton", sb)
	th.set_color("font_color", "OptionButton", TEXT)
	th.set_color("font_hover_color", "OptionButton", Color("#FFFFFF"))
	th.set_color("font_pressed_color", "OptionButton", Color("#FFFFFF"))
	th.set_color("font_disabled_color", "OptionButton", TEXT_DIM)
	th.set_font("font", "OptionButton", ui_font())
	th.set_font_size("font_size", "OptionButton", 14)

	# Popup
	th.set_stylebox("panel", "PopupMenu", box(Color("#161C28"), STROKE_HI, 10, 1, 6.0, 6.0, 12))
	th.set_stylebox("hover", "PopupMenu", box(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.16), Color(0, 0, 0, 0), 6, 0, 8.0, 5.0))
	th.set_color("font_color", "PopupMenu", TEXT)
	th.set_color("font_hover_color", "PopupMenu", Color("#FFFFFF"))
	th.set_font("font", "PopupMenu", ui_font())
	th.set_font_size("font_size", "PopupMenu", 13)
	th.set_constant("v_separation", "PopupMenu", 5)

	# 滚动条
	th.set_stylebox("scroll", "VScrollBar", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 0, 3.0, 0.0))
	th.set_stylebox("grabber", "VScrollBar", box(Color("#2A3345"), Color(0, 0, 0, 0), 4, 0, 3.0, 0.0))
	th.set_stylebox("grabber_highlight", "VScrollBar", box(Color("#3C4A63"), Color(0, 0, 0, 0), 4, 0, 3.0, 0.0))
	th.set_stylebox("grabber_pressed", "VScrollBar", box(ACCENT_DIM, Color(0, 0, 0, 0), 4, 0, 3.0, 0.0))
	th.set_stylebox("scroll", "HScrollBar", box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 0, 0.0, 3.0))
	th.set_stylebox("grabber", "HScrollBar", box(Color("#2A3345"), Color(0, 0, 0, 0), 4, 0, 0.0, 3.0))

	# 进度条（意图池权重条）
	th.set_stylebox("background", "ProgressBar", box(Color("#111722"), STROKE, 4, 0, 0.0, 0.0))
	th.set_stylebox("fill", "ProgressBar", box(ACCENT, Color(0, 0, 0, 0), 4, 0, 0.0, 0.0))
	th.set_font("font", "ProgressBar", mono_font())
	th.set_font_size("font_size", "ProgressBar", 11)

	# 分隔线
	var line := StyleBoxLine.new()
	line.color = STROKE
	line.thickness = 1
	th.set_stylebox("separator", "HSeparator", line)
	th.set_constant("separation", "HSeparator", 1)

	# 弹窗
	th.set_stylebox("panel", "AcceptDialog", box(Color("#161C28"), STROKE_HI, 14, 1, 18.0, 18.0, 18))
	th.set_color("font_color", "AcceptDialog", TEXT)
	th.set_font("font", "AcceptDialog", ui_font())
	th.set_font_size("font_size", "AcceptDialog", 14)

	return th


static func _variation(th: Theme, name: StringName, font: Font, size: int, color: Color) -> void:
	th.set_type_variation(name, &"Label")
	th.set_font("font", name, font)
	th.set_font_size("font_size", name, size)
	th.set_color("font_color", name, color)
