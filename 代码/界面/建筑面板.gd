class_name RtsBuildingPanel
extends PanelContainer
## **建筑面板（中段）** —— 选中单个建筑时，占据底栏**中间那一段**。
##
## 2026-11-01 第五次改版（玩家口径）：
##   "建筑中段修改：队列视图和图标的排列要类似魔兽争霸那种 **L 型**，
##    最多可显示七个，再多就在下面显示页码，可翻页。"
##
## 于是中段有两种脸，共用一条**大铭牌**（和单位面板同一套字号）：
##
##   ① 空闲 / 不产兵 → 竖排数值（和单位面板完全同构，RtsStatColumn）
##      ┌──────────────────────┐
##      │ ◆ 兵营        闲置    │
##      │ ══════●════════════  │
##      │  🛡   4    护甲       │
##      │  👁  12m   视野       │
##      │  ⚔  15/1.4s 攻击      │
##      └──────────────────────┘
##
##   ② 有活干 → **上面一条当前训练，下面 L 型队列**（玩家给的骨架）
##      ┌──────────────────────────────────────────────┐
##      │ ◆ 兵营                训练中                 │
##      │ ══════●════════════════════════════════════  │
##      │ [脸] 训练·步兵 ▓▓▓▓▓▓░░░ 45%    剩余 8.4s    │
##      │ [x][x][x][x]                                 │
##      │ [x][x][x]              队列 9/10   ◀ 1/2 ▶   │
##      └──────────────────────────────────────────────┘
##
## 三条纪律：
##   1. 进度条由本面板自己 `_process` 每帧刷（HUD 的 0.12s 节流会让秒数一跳一跳）；
##   2. 数值/颜色只从 GameConfig 与建筑自身读，界面里不发明规则；
##   3. 训练/研究只**显示**状态，不在这里放按钮（按钮全在命令卡，避免两处入口）。

const Spec := preload("res://代码/界面/界面规格.gd")
const Deco := preload("res://代码/界面/装饰.gd")
const Lex := preload("res://代码/界面/词条.gd")

## 最小高度
const H_MIN := 130.0
## 队列上限（与 指令系统.TRAIN_QUEUE_MAX 同口径：10）
const QUEUE_MAX := 10
## L 型队列：**上排 4 格、下排 3 格**（右下角故意空一格才是 L），一页 7 个
const L_COLS := 4
const L_SLOTS := 7
## 队列格尺寸（L 型：上排 4 格 + 下排 3 格）
const CHIP_W := 64.0
const CHIP_H := 56.0
const CHIP_GAP := 6.0
## 当前训练那条的高度（图标 + 名字 + 大条 + 剩余秒）
const TRAIN_ROW_H := 30.0
const TRAIN_ICON := 28.0
## 当前训练条高度
const BAR_H := 16.0
## 铭牌行高（34px 字）
const HEAD_H := 42.0


# ===========================================================================
# 内嵌控件：一条横向进度条（训练 / 研究 / 建造共用）
# ===========================================================================

## 水平进度条：底槽 + 实心填充 + 顶部高光 + 1px 外框，可带居中文字。
class Bar extends Control:
	var ratio: float = 0.0
	var fill: Color = Color(0.86, 0.60, 0.26)
	var caption: String = ""
	var _label: Label = null
	var _fs: int = 14

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		_label = Label.new()
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.add_theme_font_size_override("font_size", _fs)
		_label.add_theme_color_override("font_color", Color(0.97, 0.95, 0.90))
		_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.90))
		_label.add_theme_constant_override("outline_size", 3)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(_label)

	## 喂数据（相同数值不重绘，避免每帧刷 draw call）
	func feed(r: float, f: Color, cap: String = "") -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if is_equal_approx(v, ratio) and f == fill and cap == caption:
			return
		ratio = v
		fill = f
		caption = cap
		if _label != null:
			_label.text = cap
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 4.0 or r.size.y < 4.0:
			return
		draw_rect(r, Color(0.042, 0.038, 0.032, 0.98), true)
		var w: float = maxf((r.size.x - 2.0) * ratio, 0.0)
		if w > 0.5:
			draw_rect(Rect2(1.0, 1.0, w, r.size.y - 2.0), fill, true)
			draw_rect(Rect2(1.0, 1.0, w, maxf((r.size.y - 2.0) * 0.42, 1.0)),
					Color(1.0, 1.0, 1.0, 0.14), true)
			draw_rect(Rect2(1.0 + w - 1.0, 1.0, 1.0, r.size.y - 2.0),
					Color(1.0, 1.0, 1.0, 0.55), true)
		draw_rect(r, Color(1.0, 0.94, 0.80, 0.16), false, 1.0)


# ===========================================================================
# 状态
# ===========================================================================

var _target: RtsBuilding = null
var _warm: Color = Color(0.97, 0.64, 0.26)
var _warn: Color = Color(1.0, 0.36, 0.28)
var _mono: Font = null
var _built: bool = false
var _built_def: StringName = &""
var _panel_w: float = 520.0
var _compact: bool = false

var _root: VBoxContainer = null

# --- 铭牌 ---
var _head_row: HBoxContainer = null
var _bullet: Control = null
var _name_label: Label = null
var _head_hint: Label = null
var _rule: Control = null

# --- 训练 ---
var _train_box: VBoxContainer = null
## 当前训练单位的头像（"正在造谁"一眼可见）
var _cur_icon: TextureRect = null
var _train_cap: Label = null
var _queue_count: Label = null
var _rest_label: Label = null
var _train_bar: Bar = null
var _queue_top: HBoxContainer = null
var _queue_bot: HBoxContainer = null
var _queue_page: Label = null
var _queue_page_index: int = 0
var _queue_chips: Array[PanelContainer] = []
var _queue_icons: Array[TextureRect] = []
var _queue_bars: Array = []

# --- 研究 ---
var _research_box: VBoxContainer = null
var _research_cap: Label = null
var _research_bar: Bar = null

# --- 建造 ---
var _build_box: VBoxContainer = null
var _build_cap: Label = null
var _build_bar: Bar = null

# --- 属性（不产兵 / 空闲时）---
var _stats: RtsStatColumn = null
var _stats_sig: String = ""


# ===========================================================================
# 配置访问（兼容无头自检）
# ===========================================================================

static func _scene_root() -> Node:
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree == null:
		return null
	return tree.root


static func _cfg_game() -> GameConfig:
	var r := _scene_root()
	if r == null:
		return null
	var n := r.get_node_or_null("Cfg")
	if n == null:
		return null
	return n.get("game") as GameConfig


func _def_of_id(id: StringName) -> UnitDef:
	if id == &"":
		return null
	var g := _cfg_game()
	if g == null:
		return null
	return g.unit_def(id)


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	ensure_built()


func ensure_built() -> void:
	if _built:
		return
	_built = true
	_mono = Spec.mono_font()
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(_panel_w, H_MIN)
	# 段底由 HUD 的奇幻底板承担 —— 这里只留内边距，不再自己铺一块深灰
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	add_theme_stylebox_override("panel", sb)

	_root = VBoxContainer.new()
	_root.name = "纵"
	_root.add_theme_constant_override("separation", 2)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_head(_root)
	_build_construction(_root)
	_build_training(_root)
	_build_research(_root)
	_build_stats(_root)
	_show_idle()


func set_metrics(w: float, h_single: float, _h_multi: float, compact: bool) -> void:
	ensure_built()
	_panel_w = w
	_compact = compact
	custom_minimum_size = Vector2(_panel_w, maxf(H_MIN, h_single))
	if _stats != null:
		# 面板内高 = 传入高度 - stylebox 上下留白（8+8）
		# 再扣掉 牌头 44 + 金线 11 + 三处 2px 间隙，剩下的三行平分
		var inner: float = maxf(h_single - 16.0, 120.0)
		_stats.set_row_height(clampf((inner - HEAD_H - 11.0 - 6.0) / 3.0 - 3.0, 34.0, 58.0))


# ---------------------------------------------------------------------------
# 铭牌行：**这栋楼叫什么** + 状态尾巴
# ---------------------------------------------------------------------------
func _build_head(parent: Node) -> void:
	_head_row = HBoxContainer.new()
	_head_row.name = "铭牌"
	_head_row.add_theme_constant_override("separation", 9)
	_head_row.custom_minimum_size = Vector2(0.0, HEAD_H)
	_head_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_head_row)

	_bullet = Deco.Diamond.new()
	_bullet.custom_minimum_size = Vector2(11.0, 11.0)
	_bullet.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head_row.add_child(_bullet)

	_name_label = Spec.label("建筑", Spec.FS_HERO_BIG, Color(1.0, 0.94, 0.76))
	_name_label.clip_text = true
	# ★ clip_text=true 会把最小宽度压成 0 —— 必须给一个下限，
	#   否则 HBox 里的弹性留白把名字挤成 0 宽（第一版就是这样"名字看不见"）。
	_name_label.custom_minimum_size = Vector2(84.0, 0.0)
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.90))
	_name_label.add_theme_constant_override("outline_size", 6)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head_row.add_child(_name_label)

	_head_hint = Spec.label("", Spec.FS_BODY, Color(0.86, 0.80, 0.62))
	_head_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_head_hint.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_head_hint.add_theme_constant_override("outline_size", 3)
	_head_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head_row.add_child(_head_hint)

	# 铭牌下沿：带菱形的金线（和单位面板一模一样）
	_rule = Deco.Rule.new()
	_rule.name = "金线"
	_rule.gem = true
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_rule)

	# ★ 弹窗**只绑一次**：气泡层在鼠标悬停时才回调 maker，
	#   所以内容永远是最新的；如果在 _process 里反复 bind，
	#   信号会被重复连接（引擎直接报 "already connected"）。
	RtsTipLayer.bind(self, _name_label, func() -> Dictionary: return _building_tip())
	RtsTipLayer.bind(self, _bullet, func() -> Dictionary: return _building_tip())
	RtsTipLayer.bind(self, _head_hint, func() -> Dictionary: return _building_tip())


func _building_tip() -> Dictionary:
	if _target == null or not is_instance_valid(_target):
		return {}
	return Lex.portrait(_target)


# ---------------------------------------------------------------------------
# 建造进度（未完工时出现）
# ---------------------------------------------------------------------------
func _build_construction(parent: Node) -> void:
	_build_box = VBoxContainer.new()
	_build_box.name = "建造进度"
	_build_box.add_theme_constant_override("separation", 3)
	_build_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_box.visible = false
	parent.add_child(_build_box)

	_build_cap = Spec.label("建造中 0%", Spec.FS_VALUE, Color(0.99, 0.80, 0.44))
	_build_box.add_child(_build_cap)

	_build_bar = Bar.new()
	_build_bar.custom_minimum_size = Vector2(0.0, 18.0)
	_build_bar.fill = Color(0.96, 0.72, 0.30)
	_build_box.add_child(_build_bar)


# ---------------------------------------------------------------------------
# 训练区：左进度 + 右 L 型队列
# ---------------------------------------------------------------------------
## L：上排 4 格、下排 3 格（右下角空一格才是"L"），一页 7 个，多了在**下面**出页码。
func _build_training(parent: Node) -> void:
	_train_box = VBoxContainer.new()
	_train_box.name = "训练区"
	_train_box.add_theme_constant_override("separation", 2)
	# 让训练区吃掉底栏多出来的高度：真正固定的是队列格，富裕的空间给"当前训练"那一行
	_train_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_train_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_train_box)

	# --- 第一行：当前训练（图标 + 名字 + 大进度条 + 剩余秒数）---
	#    玩家给的骨架：「[图标] ▓▓▓▓▓▓ 多少秒」，队列在它**下面**。
	var row := HBoxContainer.new()
	row.name = "当前训练"
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0.0, TRAIN_ROW_H)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_train_box.add_child(row)

	_cur_icon = TextureRect.new()
	_cur_icon.name = "当前单位"
	_cur_icon.custom_minimum_size = Vector2(TRAIN_ICON, TRAIN_ICON)
	_cur_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cur_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cur_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_cur_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_cur_icon)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)

	_train_cap = Spec.label("训练", Spec.FS_CAPTION, Color(_warm.r, _warm.g, _warm.b, 0.98))
	_train_cap.name = "训练标题"
	col.add_child(_train_cap)

	_train_bar = Bar.new()
	_train_bar.name = "训练进度"
	_train_bar.custom_minimum_size = Vector2(0.0, BAR_H)
	_train_bar._fs = Spec.FS_BODY
	_train_bar.fill = Color(0.44, 0.76, 0.98)
	col.add_child(_train_bar)

	_rest_label = Spec.label("待训练", Spec.FS_VALUE, Color(0.90, 0.88, 0.80))
	_rest_label.name = "剩余"
	_rest_label.add_theme_font_override("font", _mono)
	_rest_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rest_label.custom_minimum_size = Vector2(96.0, 0.0)
	_rest_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_rest_label)

	# 进度条的说明（悬停时才生成，所以"剩余几秒"永远是当下的）
	RtsTipLayer.bind(self, _train_bar, func() -> Dictionary: return _train_bar_tip())
	RtsTipLayer.bind(self, _train_cap, func() -> Dictionary: return _train_bar_tip())

	# --- 第二/三行：L 型队列（上 4 + 下 3），一页 7 个 ---
	_queue_top = HBoxContainer.new()
	_queue_top.name = "上排"
	_queue_top.add_theme_constant_override("separation", CHIP_GAP)
	_queue_top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_queue_top.mouse_filter = Control.MOUSE_FILTER_PASS
	_queue_top.gui_input.connect(_on_queue_input)
	_train_box.add_child(_queue_top)

	_queue_bot = HBoxContainer.new()
	_queue_bot.name = "下排"
	_queue_bot.add_theme_constant_override("separation", CHIP_GAP)
	_queue_bot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_queue_bot.mouse_filter = Control.MOUSE_FILTER_PASS
	_queue_bot.gui_input.connect(_on_queue_input)
	_train_box.add_child(_queue_bot)

	for i in L_SLOTS:
		var chip := PanelContainer.new()
		chip.name = "队列项%d" % (i + 1)
		chip.mouse_filter = Control.MOUSE_FILTER_PASS
		chip.custom_minimum_size = Vector2(CHIP_W, CHIP_H)
		chip.add_theme_stylebox_override("panel", _chip_style(false))
		chip.mouse_entered.connect(func() -> void:
			chip.add_theme_stylebox_override("panel", _chip_style(true)))
		chip.mouse_exited.connect(func() -> void:
			chip.add_theme_stylebox_override("panel", _chip_style(false)))
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(vb)
		var ico := TextureRect.new()
		ico.name = "头像"
		ico.custom_minimum_size = Vector2(CHIP_W - 8.0, CHIP_H - 12.0)
		ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(ico)
		var bar := Bar.new()
		bar.name = "进度"
		bar.custom_minimum_size = Vector2(0.0, 4.0)
		bar.fill = Color(0.44, 0.76, 0.98)
		vb.add_child(bar)
		# 上排 4 格 / 下排 3 格 —— 这就是"L"
		if i < L_COLS:
			_queue_top.add_child(chip)
		else:
			_queue_bot.add_child(chip)
		_queue_chips.append(chip)
		_queue_icons.append(ico)
		_queue_bars.append(bar)
		var idx: int = i
		RtsTipLayer.bind(self, chip, func() -> Dictionary: return _chip_tip(idx))

	# 下排右端：队列计数 + 页码（超过 7 个才出现），正好补上 L 缺的那一角
	var tail := HBoxContainer.new()
	tail.name = "队列尾巴"
	tail.add_theme_constant_override("separation", 10)
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tail.alignment = BoxContainer.ALIGNMENT_END
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_queue_bot.add_child(tail)

	_queue_count = Spec.label("0 / %d" % QUEUE_MAX, Spec.FS_BODY, Color(0.80, 0.74, 0.62))
	_queue_count.name = "队列计数"
	_queue_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tail.add_child(_queue_count)

	_queue_page = Spec.label("", Spec.FS_VALUE, Color(0.92, 0.86, 0.70))
	_queue_page.name = "队列页码"
	_queue_page.custom_minimum_size = Vector2(CHIP_W * 1.4, 28.0)
	_queue_page.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_queue_page.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_queue_page.mouse_filter = Control.MOUSE_FILTER_STOP
	_queue_page.gui_input.connect(_on_queue_input)
	_queue_page.visible = false
	tail.add_child(_queue_page)

	# 底部留 8px 呼吸位：训练行是 EXPAND 的，会把余量全部吃光，
	# 没有这个占位的话第二排队列格会**正好压在面板内沿**上（看着像被裁了）。
	var bottom_air := Control.new()
	bottom_air.name = "底部留白"
	bottom_air.custom_minimum_size = Vector2(0.0, 4.0)
	bottom_air.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_train_box.add_child(bottom_air)
	RtsTipLayer.bind(self, _queue_page, func() -> Dictionary:
		return {"icon": "clock", "icon_color": _warm, "title": "队列翻页",
				"tag": "一页 7 个",
				"body": "队列最多 %d 个，一页只摆 7 个（4 + 3 的 L 形）。\n点这里或在下排滚滚轮翻页。" % QUEUE_MAX,
				"foot": ""})


## 面板是不是"展开"形态（训练 / 研究 / 建造进度占着中段）。
## HUD 用它决定头像贴哪边：展开时头像回最左边，紧凑时头像贴命令卡。
func is_expanded() -> bool:
	return _train_box.visible or _research_box.visible or _build_box.visible


func _chip_style(hover: bool) -> StyleBoxFlat:
	if not hover:
		return Spec.inset_style(Color(0.135, 0.118, 0.094, 0.96), 5,
				Color(_warm.r, _warm.g, _warm.b, 0.30), 4.0, 0.0)
	return Spec.inset_style(Color(0.190, 0.168, 0.132, 0.98), 5,
			Color(_warm.r, _warm.g, _warm.b, 0.85), 4.0, 0.0)


func _chip_tip(i: int) -> Dictionary:
	if _target == null or not is_instance_valid(_target):
		return {}
	var from: int = _queue_page_index * L_SLOTS
	var idx: int = from + i
	if idx >= _target.train_queue.size():
		return {"icon": "clock", "icon_color": Color(0.6, 0.6, 0.58),
				"title": "空队列位", "tag": "",
				"body": "这个位置还没有排训练。在右下命令卡点兵种就能排进来。", "foot": ""}
	return Lex.queue_item(_target.train_queue[idx], idx,
			_target.train_progress, idx == 0)


## 队列翻页（点页码 / 滚轮）
func _on_queue_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_queue_page_index += 1
		_sync_queue_page()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		_queue_page_index = maxi(_queue_page_index - 1, 0)
		_sync_queue_page()
	elif mb.button_index == MOUSE_BUTTON_LEFT:
		_queue_page_index += 1
		_sync_queue_page()
	accept_event()


# ---------------------------------------------------------------------------
# 研究进度（铁匠铺 / 伐木场）
# ---------------------------------------------------------------------------
func _build_research(parent: Node) -> void:
	_research_box = VBoxContainer.new()
	_research_box.name = "研究区"
	_research_box.add_theme_constant_override("separation", 4)
	_research_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_research_box.visible = false
	parent.add_child(_research_box)

	_research_cap = Spec.label("研究", Spec.FS_VALUE, Color(0.72, 0.86, 1.0))
	_research_box.add_child(_research_cap)

	_research_bar = Bar.new()
	_research_bar.name = "研究进度"
	_research_bar.custom_minimum_size = Vector2(0.0, 20.0)
	_research_bar.fill = Color(0.72, 0.86, 1.0)
	_research_box.add_child(_research_bar)
	RtsTipLayer.bind(self, _research_bar, func() -> Dictionary: return _research_bar_tip())


func _research_bar_tip() -> Dictionary:
	if _target == null or not is_instance_valid(_target):
		return {}
	var rid: StringName = _target.call("current_research") if _target.has_method("current_research") else &""
	if rid == &"":
		return {}
	var lv: int = RtsCombat.research_level(_target.faction, rid)
	var rd: ResearchDef = Cfg.research(rid) if Cfg.game != null else null
	var mx: int = maxi(rd.max_level, 1) if rd != null else 1
	var p: float = float(_target.call("research_progress"))
	return Lex.research(rid, lv, mx, p)


# ---------------------------------------------------------------------------
# 属性（不产兵 / 空闲：护甲 / 视野 / 人口或攻击…）
# ---------------------------------------------------------------------------
## 和单位面板**完全同构**：同一个 RtsStatColumn（竖排、无斑马底、可悬停）。
func _build_stats(parent: Node) -> void:
	_stats = RtsStatColumn.new()
	_stats.name = "属性"
	_stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(_stats)


# ===========================================================================
# 对外接口
# ===========================================================================

func desired_height() -> float:
	ensure_built()
	return maxf(get_combined_minimum_size().y, H_MIN)


## 中段想要多宽。**只有"属性视图"用得上**：训练视图下 HUD 会把中段一路铺到命令卡左缘
## （玩家口径："中间展开的面板要贴合，不要露出这部分背景"）。
func content_width() -> float:
	ensure_built()
	return 268.0


## 内容需要多高 —— **常数**（和 选择网格 同一个 224）。
## 行高/格高都是按底栏内高反推的，把它算回内容高就会自激，越涨越高。
func content_height() -> float:
	return 224.0


## 刷新（HUD 每 0.12s 会调一次；换建筑类型时才重建内容）
func refresh(target: RtsBuilding) -> void:
	ensure_built()
	_target = target
	if target == null or not is_instance_valid(target):
		_show_idle()
		return
	var d: UnitDef = target.def
	var def_id: StringName = d.id if d != null else &""
	if def_id != _built_def:
		_built_def = def_id
		_rebuild_entries(d)
	_sync_all()


## 当前训练条比例（自检用）
func train_fraction() -> float:
	if _target == null or not is_instance_valid(_target):
		return 0.0
	if _target.train_queue.is_empty():
		return 0.0
	return clampf(_target.train_progress, 0.0, 1.0)


## 训练状态快照（自检用；也方便调试时 print 一眼）
func debug_train_state() -> Dictionary:
	var out: Dictionary = {
		"queue": 0, "current": &"", "progress": 0.0, "remaining": 0.0, "total": 0.0,
	}
	if _target == null or not is_instance_valid(_target):
		return out
	out["queue"] = _target.train_queue.size()
	var cur: StringName = _target.current_training()
	out["current"] = cur
	out["progress"] = _target.train_progress
	var d: UnitDef = _def_of_id(cur)
	var total: float = d.train_time if d != null else 0.0
	out["total"] = total
	out["remaining"] = maxf(1.0 - clampf(_target.train_progress, 0.0, 1.0), 0.0) * total
	return out


func _process(_delta: float) -> void:
	# 计时条每帧刷：HUD 的 0.12s 节流会让"剩余秒数"一格一格跳，像卡住
	if not is_visible_in_tree():
		return
	if _target == null or not is_instance_valid(_target):
		return
	_sync_all()


# ===========================================================================
# 内容重建（换建筑类型时）
# ===========================================================================

func _rebuild_entries(d: UnitDef) -> void:
	var can_research: bool = d != null and not d.researches.is_empty()
	_research_box.visible = can_research
	_head_row.visible = true
	_rule.visible = true
	_name_label.text = d.display_name if d != null else "建筑"
	# 训练区 / 属性块的显隐**每帧按队列状态**决定，见 _sync_mode()：
	#   有活干 = 队列非空或在训练 → 队列视图；
	#   闲着（或这栋楼根本不产兵）→ 三行竖排数值，
	#   照玩家口径："没有训练单位就显示建筑护甲"。
	_sync_mode()
	_stats_sig = ""


# ===========================================================================
# 数值同步（每次 refresh / 每帧）
# ===========================================================================

func _sync_all() -> void:
	if _target == null or not is_instance_valid(_target):
		_show_idle()
		return
	var d: UnitDef = _target.def
	_sync_head()
	_sync_mode()
	_sync_construction(d)
	_sync_training()
	_sync_research()
	_sync_stats(d)


## 标题右上角的状态尾巴：一句"现在在干什么"
func _sync_head() -> void:
	if _head_row == null:
		return
	var researching: bool = false
	if _target.has_method("is_researching"):
		researching = bool(_target.call("is_researching"))
	var txt: String = "闲置"
	if not _target.is_constructed:
		txt = "建造中 %d%%" % int(round(clampf(_target.progress, 0.0, 1.0) * 100.0))
	elif researching:
		txt = "研究中"
	else:
		if not _target.train_queue.is_empty():
			txt = "训练中"
	if _head_hint.text != txt:
		_head_hint.text = txt


## 中段到底摆什么：队列视图 / 数值视图。
func _sync_mode() -> void:
	var d: UnitDef = _target.def if _target != null and is_instance_valid(_target) else null
	var can_train: bool = d != null and not d.trains.is_empty()
	var busy: bool = false
	if can_train and _target != null:
		busy = not _target.train_queue.is_empty() or _target.current_training() != &""
	if _train_box.visible != (can_train and busy):
		_train_box.visible = can_train and busy
	if _stats.visible != (d != null and not (can_train and busy)):
		_stats.visible = d != null and not (can_train and busy)
	# 研究区只在**真的在研究中**出现（带进度条）。
	# 空闲时那一行"武器锻造 0/5"和右边命令卡上的按钮完全重复，
	# 摆在中间只会把"名字 + 数值"挤下去 —— 中段是信息栏，不是第二张命令卡。
	var researching: bool = false
	if _target != null and _target.has_method("is_researching"):
		researching = bool(_target.call("is_researching"))
	if _research_box.visible != researching:
		_research_box.visible = researching


func _sync_construction(d: UnitDef) -> void:
	var constructing: bool = not _target.is_constructed
	_build_box.visible = constructing
	if not constructing:
		return
	var p: float = clampf(_target.progress, 0.0, 1.0)
	# ★ 建造时长就是 def.train_time（RtsBuilding 里同口径），UnitDef 没有 build_time 字段
	var total: float = maxf(d.train_time, 0.5) if d != null else 0.0
	var rest: float = maxf(1.0 - p, 0.0) * total
	_build_cap.text = "建造中 %d%%　·　剩余 %.0fs" % [int(round(p * 100.0)), rest] if total > 0.0 \
			else "建造中 %d%%" % int(round(p * 100.0))
	_build_bar.feed(p, Color(0.96, 0.72, 0.30), "")


func _sync_training() -> void:
	if not _train_box.visible:
		return
	var queue_n: int = _target.train_queue.size()
	_queue_count.text = "队列 %d / %d" % [queue_n, QUEUE_MAX]
	var cur: StringName = _target.current_training()
	if cur == &"":
		_train_bar.feed(0.0, Color(0.30, 0.42, 0.52), "")
		_rest_label.text = "待训练"
		_train_cap.text = "训练"
		if _cur_icon != null:
			_cur_icon.texture = null
	else:
		var p: float = clampf(_target.train_progress, 0.0, 1.0)
		var ud: UnitDef = _def_of_id(cur)
		var total: float = ud.train_time if ud != null else 0.0
		var rest: float = maxf(1.0 - p, 0.0) * total
		var nm: String = ud.display_name if ud != null else String(cur)
		_train_cap.text = "训练 · %s" % nm
		_train_bar.feed(p, Color(0.44, 0.76, 0.98), "%d%%" % int(round(p * 100.0)))
		_rest_label.text = "剩余 %.1fs" % rest
		if _cur_icon != null:
			_cur_icon.texture = Spec.unit_icon(cur) if Spec.unit_icon(cur) != null \
					else Spec.icon_tex(_unit_icon(cur))

	# 队列格：L 型，一页 7 格；队首那格带真实进度
	var pages: int = maxi(1, ceili(float(queue_n) / float(L_SLOTS)))
	_queue_page_index = clampi(_queue_page_index, 0, pages - 1)
	_sync_queue_page(queue_n)
	_queue_top.visible = queue_n > 0
	_queue_bot.visible = queue_n > 0


func _train_bar_tip() -> Dictionary:
	if _target == null or not is_instance_valid(_target):
		return {}
	var cur: StringName = _target.current_training()
	if cur == &"":
		return {"icon": "clock", "icon_color": _warm, "title": "当前没有在训练",
				"tag": "", "body": "队列是空的。在右下命令卡点一个兵种，这里就会出现进度条。",
				"foot": ""}
	var ud: UnitDef = _def_of_id(cur)
	var nm: String = ud.display_name if ud != null else String(cur)
	var p: float = clampf(_target.train_progress, 0.0, 1.0)
	var total: float = ud.train_time if ud != null else 0.0
	return {"icon": "gear", "icon_color": Color(0.62, 0.84, 1.0),
			"title": "正在训练 %s" % nm,
			"tag": "%d%%" % int(round(p * 100.0)),
			"body": "剩余 [b]%.1f 秒[/b]，训练完成会自动出现在集结点附近。\n队列共 %d 个，最多 %d 个。"
					% [maxf(1.0 - p, 0.0) * total, _target.train_queue.size(), QUEUE_MAX],
			"foot": ""}


## 画一页队列（页码也一起刷）
func _sync_queue_page(queue_n: int = -1) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var n: int = _target.train_queue.size() if queue_n < 0 else queue_n
	var pages: int = maxi(1, ceili(float(n) / float(L_SLOTS)))
	_queue_page_index = clampi(_queue_page_index, 0, pages - 1)
	var from: int = _queue_page_index * L_SLOTS
	for i in _queue_chips.size():
		var idx: int = from + i
		if idx >= n:
			_queue_chips[i].visible = false
			continue
		var id: StringName = _target.train_queue[idx]
		var ud2: UnitDef = _def_of_id(id)
		_queue_icons[i].texture = Spec.unit_icon(id) if Spec.unit_icon(id) != null \
				else Spec.icon_tex(_unit_icon(id))
		_queue_icons[i].modulate = Color(1, 1, 1, 1) if idx == 0 else Color(0.78, 0.78, 0.74)
		var bar: Bar = _queue_bars[i]
		bar.feed(clampf(_target.train_progress, 0.0, 1.0) if idx == 0 else 0.0,
				Color(0.44, 0.76, 0.98), "")
		_queue_chips[i].visible = true
	_queue_page.visible = pages > 1
	if pages > 1:
		_queue_page.text = "◀ %d/%d ▶" % [_queue_page_index + 1, pages]


func _sync_research() -> void:
	if not _research_box.visible:
		return
	var busy: bool = _target.has_method("is_researching") and bool(_target.call("is_researching"))
	if busy:
		var cur: StringName = _target.call("current_research")
		var p: float = clampf(float(_target.call("research_progress")), 0.0, 1.0)
		_research_cap.text = "研究 · %s" % _research_title(cur)
		_research_bar.visible = true
		_research_bar.feed(p, Color(0.72, 0.86, 1.0), "%d%%" % int(round(p * 100.0)))
	else:
		_research_bar.visible = false
		# 空闲时把两项研究的级数写在标题上：不用去命令卡逐个看
		var parts: Array[String] = []
		var d: UnitDef = _target.def
		if d != null:
			for rid in d.researches:
				var lv: int = RtsCombat.research_level(_target.faction, rid)
				var rd: ResearchDef = Cfg.research(rid) if Cfg.game != null else null
				var mx: int = maxi(rd.max_level, 1) if rd != null else 1
				parts.append("%s %d/%d" % [_research_title(rid), lv, mx])
		_research_cap.text = "研究 · " + ("　".join(parts) if not parts.is_empty() else "空闲")


func _sync_stats(d: UnitDef) -> void:
	if not _stats.visible or d == null:
		return
	var sig: String = String(d.id)
	if sig == _stats_sig:
		return
	_stats_sig = sig
	_stats.feed(_stats_of(d))


## 建筑属性三项：护甲 / 视野 /（人口 → 攻击 → 预警 → 可研究 → 可训练 → 建造耗时）
##
## 第三格以前写死"建造耗时"，一栋早就盖好的兵营还在报 "25s"，
## 等于占着最显眼的位置说废话。现在按"这栋楼到底能干什么"往下滑。
func _stats_of(d: UnitDef) -> Array:
	var out: Array = [
		{"icon": "shield", "name": "护甲", "color": Color(0.62, 0.78, 0.98),
			"text": _num(d.armor), "tip": Lex.stat(d, "armor")},
		{"icon": "eye", "name": "视野", "color": Color(0.66, 0.86, 0.92),
			"text": "%dm" % int(round(d.sight_range)), "tip": Lex.stat(d, "sight")},
	]
	if d.food_provided > 0:
		out.append({"icon": "house", "name": "人口", "color": Color(0.80, 0.88, 0.66),
			"text": "+%d" % d.food_provided, "tip": Lex.stat(d, "pop")})
	elif d.can_attack():
		# 数字列只有 74px 宽（34px 等宽字体约放 4 个字），
		# 所以这里**只放伤害**，间隔写在弹窗里 —— 塞成 "22/1.2s" 会顶穿下一列
		out.append({"icon": "sword", "name": "攻击", "color": Color(0.98, 0.62, 0.42),
			"text": _num(d.attack_damage),
			"tip": Lex.stat(d, "attack")})
	elif d.detect_radius > 0.0:
		# 哨塔：不能打，但敌人一进这个圈就报点
		out.append({"icon": "eye", "name": "预警", "color": Color(0.98, 0.78, 0.52),
			"text": "%dm" % int(round(d.detect_radius)), "tip": Lex.stat(d, "detect")})
	elif not d.researches.is_empty():
		out.append({"icon": "upgrade", "name": "可研究", "color": Color(0.86, 0.78, 1.0),
			"text": "%d 项" % d.researches.size(), "tip": Lex.stat(d, "researchable")})
	elif not d.trains.is_empty():
		out.append({"icon": "gear", "name": "可训练", "color": Color(0.80, 0.80, 0.76),
			"text": "%d 种" % d.trains.size(), "tip": Lex.stat(d, "trainable")})
	else:
		out.append({"icon": "gear", "name": "建造", "color": Color(0.80, 0.80, 0.76),
			"text": "%ds" % int(round(d.train_time)), "tip": Lex.stat(d, "train_time")})
	return out


func _num(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


func _show_idle() -> void:
	if not _built:
		return
	_head_row.visible = false
	_rule.visible = false
	_build_box.visible = false
	_train_box.visible = false
	_research_box.visible = false
	_stats.visible = false


# ===========================================================================
# 小工具
# ===========================================================================

## 研究 id → 中文名（优先读配置层的 ResearchDef）
func _research_title(rid: StringName) -> String:
	var rd: ResearchDef = Cfg.research(rid) if Cfg.game != null else null
	if rd != null and not rd.display_name.is_empty():
		return rd.display_name
	match rid:
		&"attack_up":
			return "武器锻造"
		&"armor_up":
			return "护甲锻造"
		&"wood_haul":
			return "高效搬运"
		&"repair_tech":
			return "修缮工艺"
		_:
			return String(rid)


## 单位 id → 线描图标名（PNG 头像缺失时的兜底）
func _unit_icon(id: StringName) -> String:
	match String(id):
		"footman", "soldier", "swordsman":
			return "sword"
		"crossbow", "archer", "rifleman":
			return "bow"
		"mage", "priest":
			return "staff"
		"peasant", "worker":
			return "hammer"
		"steam_guard":
			return "anvil"
		_:
			return "shield"
