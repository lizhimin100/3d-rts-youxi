class_name RtsTipLayer
extends Control
## **可弹出式说明文本**（tooltip）—— 底栏所有图标/数值/队列格的"省略掉的文字"都从这里补。
##
## 玩家的口径："放在攻击图标上要显示这是什么类型的攻击。本意是把一些省略掉、
## 为了美观而不显示出来的文本，用弹窗说明文本弥补。"
##
## 为什么不用引擎自带的 `tooltip_text`：
##   1. 引擎的 tooltip 画在独立层，**不吃 root 的 1/zoom 反拉伸** ——
##      1280 宽的小窗上会变成"界面里 18px、气泡里 25px"的两种字号；
##   2. 引擎只支持一行纯文本，而这里要说的是"穿刺 · 每 1.4s 一发 · 对轻甲 ×1.25"，
##      需要**标题 + 副标 + 富文本正文**三层；
##   3. 自带 tooltip 的位置算法在缩放层里会偏，跟着鼠标走反而更稳。
##
## 用法：
##   RtsTipLayer.bind(控件, func() -> Dictionary: return RtsLexicon.stat(...))
## 回调在**真正弹出时**才调用 → 血量/进度这类数值永远是当下的，不用手动刷新。
##
## 三条纪律：
##   1. 被绑定控件的 `mouse_filter` **不能是 IGNORE**（IGNORE 收不到 mouse_entered，
##      这正是以前"图标上有 tooltip_text 却永远不弹"的原因）。
##   2. 气泡自己不接收鼠标（MOUSE_FILTER_IGNORE），绝不许挡住底下的按钮。
##   3. 悬停 0.22s 才弹：滑过一排格子时不该刷出一串气泡。

const Spec := preload("res://代码/界面/界面规格.gd")

## 悬停多久弹出（秒）
const DELAY := 0.22
## 气泡最大宽度（设计像素）
const MAX_W := 342.0
## 鼠标与气泡的距离
const GAP := Vector2(20.0, 16.0)

var _panel: PanelContainer = null
var _icon_box: Control = null
var _title: Label = null
var _tag: Label = null
var _body: RichTextLabel = null
var _foot: Label = null
var _head: HBoxContainer = null
var _rule: ColorRect = null

var _target: Control = null
var _maker: Callable = Callable()
var _delay: float = -1.0
var _showing: bool = false


# ===========================================================================
# 静态入口：任何界面拿来就能用（找不到气泡层就退回引擎 tooltip，绝不崩）
# ===========================================================================

## 给控件挂一条说明。`maker` 必须在弹出时才调用，返回：
##   {title, tag, icon, icon_color, body(BBCode), foot}
static func bind(host: Node, c: Control, maker: Callable) -> void:
	if host == null or c == null:
		return
	# 收不到鼠标的控件永远弹不出来 —— 当场改掉，比事后排查半天便宜
	if c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		c.mouse_filter = Control.MOUSE_FILTER_PASS
	var layer := find_layer(host)
	if layer == null:
		# 兜底：没有气泡层（例如单独跑某个面板的自检）就退到引擎 tooltip
		if c.tooltip_text.is_empty():
			var d: Dictionary = maker.call() if maker.is_valid() else {}
			c.tooltip_text = String(d.get("title", ""))
		return
	c.set_meta("tip_maker", maker)
	c.mouse_entered.connect(func() -> void: layer._enter(c))
	c.mouse_exited.connect(func() -> void: layer._exit(c))
	# 控件被重建（列表刷新）时把气泡一起收掉，否则会留一张"孤儿说明"挂在屏幕上
	c.tree_exiting.connect(func() -> void:
		if layer._target == c:
			layer._hide())


static func find_layer(host: Node) -> RtsTipLayer:
	if host == null or not host.is_inside_tree():
		return null
	var n := host.get_tree().get_first_node_in_group("tip_layer")
	return n as RtsTipLayer


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	add_to_group("tip_layer")
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = 200
	_build()
	# ★ 只藏气泡，**不藏整个层**：层藏了以后 `_panel.visible = true` 也画不出来，
	#   而且悬停事件照旧进来、只是永远看不见 —— 那种 bug 最难查。
	_panel.visible = false


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "气泡"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", _tip_style())
	_panel.custom_minimum_size = Vector2(MAX_W, 0.0)
	add_child(_panel)
	_panel.visible = false

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(vb)

	# --- 标题行：图标 + 名字 + 右侧小标签 ---
	_head = HBoxContainer.new()
	_head.add_theme_constant_override("separation", 7)
	_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_head)

	_icon_box = Spec.icon("sword", 26.0, Spec.accent())
	_head.add_child(_icon_box)

	_title = Spec.label("", Spec.FS_VALUE, Color(1.0, 0.93, 0.74))
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head.add_child(_title)

	_tag = Spec.label("", Spec.FS_BODY, Spec.text_dim())
	_tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head.add_child(_tag)

	# --- 金线 ---
	_rule = ColorRect.new()
	_rule.color = Color(Spec.accent().r, Spec.accent().g, Spec.accent().b, 0.34)
	_rule.custom_minimum_size = Vector2(0.0, 1.0)
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_rule)

	# --- 正文：BBcode（关键词上色，长句自动折行）---
	_body = RichTextLabel.new()
	_body.name = "正文"
	_body.bbcode_enabled = true
	_body.fit_content = true
	_body.scroll_active = false
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(MAX_W - 26.0, 0.0)
	_body.add_theme_font_size_override("normal_font_size", Spec.FS_SUB)
	_body.add_theme_font_size_override("bold_font_size", Spec.FS_SUB)
	_body.add_theme_color_override("default_color", Color(0.90, 0.89, 0.84))
	_body.add_theme_constant_override("line_separation", 2)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_body)

	# --- 脚注：一句"这东西怎么用"（没有就不占位）---
	_foot = Spec.label("", Spec.FS_BODY, Color(0.74, 0.72, 0.64))
	_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_foot.custom_minimum_size = Vector2(MAX_W - 26.0, 0.0)
	_foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_foot)


## 气泡皮：比底栏更亮的羊皮深色 + 2px 金边 + 外投影（和段底是同一族，但更"近"）
func _tip_style() -> StyleBoxFlat:
	var a: Color = Spec.accent()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.062, 0.066, 0.082, 0.985)
	sb.border_color = Color(a.r, a.g, a.b, 0.62)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.set_corner_radius_all(7)
	sb.corner_detail = 10
	sb.content_margin_left = 13.0
	sb.content_margin_right = 13.0
	sb.content_margin_top = 9.0
	sb.content_margin_bottom = 9.0
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


# ===========================================================================
# 悬停
# ===========================================================================

func _enter(c: Control) -> void:
	if c == null or not is_instance_valid(c):
		return
	_target = c
	# ★ 不能用 `as Callable`：Callable 是内建值类型，`as` 转不出来会变成空 Callable，
	#   于是气泡永远"点得亮、弹不出来"。只能 get_meta + is 判断。
	var m: Variant = c.get_meta("tip_maker", null)
	_maker = m if m is Callable else Callable()
	_delay = DELAY
	if _showing:
		# 已经在显示：直接换内容，不重新计时（一排格子之间滑动更顺）
		_delay = 0.0


func _exit(c: Control) -> void:
	if c != _target:
		return
	_target = null
	_delay = -1.0
	_hide()


func _hide() -> void:
	_showing = false
	_delay = -1.0
	if _panel != null:
		_panel.visible = false


func _process(dt: float) -> void:
	if _target == null:
		return
	if not is_instance_valid(_target) or not _target.is_visible_in_tree():
		_target = null
		_hide()
		return
	if _delay >= 0.0:
		_delay -= dt
		if _delay <= 0.0:
			if not _maker.is_valid():
				# 没有内容可显示：退回到 1/6 秒后再试（别每帧空转）
				_delay = 0.16
				return
			var d: Dictionary = _maker.call()
			if d.is_empty():
				_delay = 0.16
				return
			_fill(d)
			_panel.visible = true
			_panel.reset_size()
			_showing = true
	if _showing:
		_follow()


## 跟着鼠标走，越界就翻到另一侧（永远不出屏）
func _follow() -> void:
	if _panel == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var local: Vector2 = get_global_transform_with_canvas().affine_inverse() \
			* vp.get_mouse_position()
	var box: Vector2 = _panel.get_combined_minimum_size()
	var bounds: Vector2 = size
	var pos: Vector2 = local + GAP
	if pos.x + box.x > bounds.x - 8.0:
		pos.x = local.x - box.x - GAP.x * 0.6
	if pos.y + box.y > bounds.y - 8.0:
		pos.y = local.y - box.y - GAP.y
	pos.x = clampf(pos.x, 8.0, maxf(bounds.x - box.x - 8.0, 8.0))
	pos.y = clampf(pos.y, 8.0, maxf(bounds.y - box.y - 8.0, 8.0))
	_panel.position = pos.round()


func _fill(d: Dictionary) -> void:
	var col: Color = d.get("icon_color", Spec.accent())
	# 有真头像就贴头像（单位/建筑渲图），没有才退回线描图标
	var tex: Variant = d.get("tex", null)
	if tex is Texture2D:
		_set_tex(tex as Texture2D)
	else:
		_set_tex(null)
		Spec.set_icon(_icon_box, String(d.get("icon", "shield")), col)
	_title.text = String(d.get("title", ""))
	var tag: String = String(d.get("tag", ""))
	_tag.text = tag
	_tag.visible = not tag.is_empty()
	var body: String = String(d.get("body", ""))
	_body.text = body
	_body.visible = not body.strip_edges().is_empty()
	var foot: String = String(d.get("foot", ""))
	_foot.text = foot
	_foot.visible = not foot.strip_edges().is_empty()
	_rule.visible = _body.visible or _foot.visible


## 把标题左边那格换成一张贴图（单位头像）；传 null 就恢复成线描图标
func _set_tex(t: Texture2D) -> void:
	var cur: Texture2D = _icon_box.get_meta("tex", null)
	if cur == t:
		return
	_icon_box.set_meta("tex", t)
	_icon_box.set_meta("iname", "")     # 让 Spec.set_icon 下一帧必定重画
	for c in _icon_box.get_children():
		_icon_box.remove_child(c)
		c.queue_free()
	if t == null:
		return
	var tr := TextureRect.new()
	tr.texture = t
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon_box.add_child(tr)


## 关掉界面（F9）/ 切选择时，气泡必须立刻收 —— 否则会挂着一句"上一支部队"的说明
func dismiss() -> void:
	_target = null
	_hide()
