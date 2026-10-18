class_name RtsBuildingPanel
extends PanelContainer
## **建筑面板（RtsBuildingPanel）** —— 选中**单个建筑**时顶替单位档案板的专属版式。
##
## 为什么单开一套：单位面板讲的是"这个兵多能打"（头像 + 属性三连 + 特性牌），
## 建筑关心的是"它能干什么、正在干什么"（训练队列 / 建造进度 / 集结点 / 研究）。
## 把两者塞进一张卡只会互相挤，所以这里换一套视觉语言：
##   · 单位面板：深色底 + 金色细描边 + 3D 头像；
##   · 本面板：**暖色标题条 + 块状分区标题（左侧粗色条）+ 紧凑按钮卡**，无头像、无属性行。
##
## 版式：
##   ┌────────────────────────────────────────────────┐
##   │ 兵营              〔建造中 42%〕        ■ 玩家 │  ← 暖色标题条 + 阵营色块
##   │ ███████████████░░░░░  生命 940 / 1500          │
##   │ 建造中 42%                                      │
##   │ ███████░░░░░░░░░░░░░                            │
##   │ ▌训练                                队列 2 / 5 │
##   │ [步兵 135金] [弓箭手 130金] [法师 155金]        │
##   │ ███████░░░░  剩余 8.4s  [取消训练]              │
##   │ ①步兵  ②弓箭手                                  │
##   │ ▌集结点                                         │
##   │ [设置集结点]  集结点：未设置                    │
##   └────────────────────────────────────────────────┘
##
## 三条纪律：
##   1. 训练计时条由**本面板自己 _process 每帧刷**（HUD 的 0.12s 节流会让秒数一跳一跳，
##      看起来像卡住）；其它文字/按钮状态仍可随 HUD 的刷新走，重复调 refresh() 是安全的。
##   2. 数值/颜色只从 GameConfig 与建筑自身读，不在界面里发明规则。
##   3. 训练走 RtsBuilding.queue_train()、取消走 cancel_train()，和命令卡是同一条路；
##      集结点走指令系统的 request_set_rally()（接口还没落地时用 has_method 兜底）。

# ===========================================================================
# 版面常量
# ===========================================================================

## 面板总宽（与单位面板同宽，HUD 复用同一套贴底摆放）
const PANEL_W := 512.0
## 最小高度（内容更矮时也保持一块像样的面板）
const H_MIN := 150.0
## 训练队列最多显示几项（与指令系统的训练上限一致）
const QUEUE_MAX := 5
## 训练按钮卡尺寸
const TRAIN_BTN := Vector2(112.0, 30.0)


# ===========================================================================
# 内嵌控件：一条横向进度条（血条 / 建造进度 / 训练计时共用）
# ===========================================================================

## 水平进度条：底槽 + 实心填充 + 顶部高光 + 1px 外框，可带居中文字。
## 与单位面板的 HealthBar 刻意不同：这里没有渐变分段，是硬边的"工程量表"感。
class Bar extends Control:
	var ratio: float = 0.0
	var fill: Color = Color(0.86, 0.60, 0.26)
	var caption: String = ""
	var _label: Label = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label = Label.new()
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.add_theme_font_size_override("font_size", 12)
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

## 当前建筑（可能已经被拆掉，取用前一定判 is_instance_valid）
var _target: RtsBuilding = null
## 暖色主色（比单位面板的金色更橙、更"工地"）
var _warm: Color = Color(0.97, 0.64, 0.26)
## 警示色
var _warn: Color = Color(1.0, 0.36, 0.28)
## 等宽字体（只给纯数字：剩余秒数）
var _mono: Font = null
var _built: bool = false
## 已经为哪个 def 建过按钮（换建筑类型时才重建）
var _built_def: StringName = &""

# --- 控件 ---
var _title_name: Label = null
var _title_state: Label = null
var _faction_chip: Panel = null
var _hp: Bar = null

var _build_box: VBoxContainer = null
var _build_cap: Label = null
var _build_bar: Bar = null

var _train_btns: HBoxContainer = null
var _train_ids: Array[StringName] = []
var _queue_count: Label = null
var _train_bar: Bar = null
var _train_rest: Label = null
var _cancel: Button = null
var _queue_row: HBoxContainer = null
## 队列小牌是 PanelContainer（不是 Panel）：typed array 类型必须和 push 进去的实例一致，
## 否则运行时报 "Attempted to push_back an object of type 'PanelContainer' into a TypedArray"。
var _queue_chips: Array[PanelContainer] = []
var _queue_labels: Array[Label] = []

var _rally_btn: Button = null
var _rally_label: Label = null

var _research_box: VBoxContainer = null
var _research_btns: HBoxContainer = null
var _research_ids: Array[StringName] = []


# ===========================================================================
# 配置访问（兼容无头自检）
# ===========================================================================

## 取场景根（拿不到返回 null）
static func _scene_root() -> Node:
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree == null:
		return null
	return tree.root


## 取全局配置。
## 为什么走节点查找而不是直接写全局标识符 Cfg：
##   --headless --script 跑自检时自动加载单例不会注册成全局名，直接写 Cfg 会报
##   "Identifier not declared"；而游戏里它本来就是 /root/Cfg 节点，两种场合都能拿到。
static func _cfg_game() -> GameConfig:
	var r := _scene_root()
	if r == null:
		return null
	var n := r.get_node_or_null("Cfg")
	if n == null:
		return null
	return n.get("game") as GameConfig


## 取单位定义（配置不在就返回 null，界面退化成"-"，绝不崩）
func _def_of_id(id: StringName) -> UnitDef:
	if id == &"":
		return null
	var g := _cfg_game()
	if g == null:
		return null
	return g.unit_def(id)


## 顶部提示（Game 单例不在时静默）
func _toast(text: String, color: Color) -> void:
	var r := _scene_root()
	if r == null:
		return
	var g := r.get_node_or_null("Game")
	if g != null and g.has_method("toast"):
		g.call("toast", text, color)


## 指令系统（集结点接口在这边；没有就返回 null）
func _command_system() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene == null:
		return null
	return scene.get("command_system") as Node


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	ensure_built()


## 建控件（重复调用安全；HUD 在 refresh 前会先触发一次）
func ensure_built() -> void:
	if _built:
		return
	_built = true
	_mono = _make_mono_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(PANEL_W, H_MIN)
	add_theme_stylebox_override("panel", _make_panel_style())

	var vb := VBoxContainer.new()
	vb.name = "纵"
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vb)

	_build_title(vb)
	_build_health(vb)
	_build_construction(vb)
	_build_training(vb)
	_build_rally(vb)
	_build_research(vb)
	_show_idle()


## 面板底：偏暖的深色 + 暖色 1px 边 + 外投影（和单位面板同族但明显更暖）
func _make_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.088, 0.074, 0.056, 0.955)
	sb.border_color = Color(_warm.r, _warm.g, _warm.b, 0.52)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.corner_detail = 8
	sb.content_margin_left = 9.0
	sb.content_margin_right = 9.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.52)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


## 标题条：整条暖色底（这是和单位面板最"一眼区分"的地方）
func _build_title(parent: Node) -> void:
	var strip := PanelContainer.new()
	strip.name = "标题条"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(_warm.r, _warm.g, _warm.b, 0.92)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 9.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	strip.add_theme_stylebox_override("panel", sb)
	parent.add_child(strip)

	var row := HBoxContainer.new()
	row.name = "行"
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(row)

	_title_name = Label.new()
	_title_name.text = "未选中建筑"
	_title_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_name.add_theme_font_size_override("font_size", 19)
	_title_name.add_theme_color_override("font_color", Color(0.11, 0.080, 0.045))
	_title_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_title_name)

	_title_state = Label.new()
	_title_state.text = ""
	_title_state.add_theme_font_size_override("font_size", 12)
	_title_state.add_theme_color_override("font_color", Color(0.24, 0.16, 0.08))
	_title_state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_title_state)

	# 阵营色条（标题条右端一条实色块）
	_faction_chip = Panel.new()
	_faction_chip.name = "阵营色条"
	_faction_chip.custom_minimum_size = Vector2(46.0, 10.0)
	_faction_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_faction_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_faction_chip)


## 血量条
func _build_health(parent: Node) -> void:
	_hp = Bar.new()
	_hp.name = "生命条"
	_hp.custom_minimum_size = Vector2(0.0, 18.0)
	_hp.fill = Color(0.40, 0.84, 0.50)
	parent.add_child(_hp)


## 建造进度（未完工时出现，完工后整块隐藏）
func _build_construction(parent: Node) -> void:
	_build_box = VBoxContainer.new()
	_build_box.name = "建造进度"
	_build_box.add_theme_constant_override("separation", 2)
	_build_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_box.visible = false
	parent.add_child(_build_box)

	_build_cap = Label.new()
	_build_cap.text = "建造中 0%"
	_build_cap.add_theme_font_size_override("font_size", 12)
	_build_cap.add_theme_color_override("font_color", Color(0.99, 0.80, 0.44))
	_build_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_box.add_child(_build_cap)

	_build_bar = Bar.new()
	_build_bar.custom_minimum_size = Vector2(0.0, 14.0)
	_build_bar.fill = Color(0.96, 0.72, 0.30)
	_build_box.add_child(_build_bar)


## 训练区：分区标题 + 按钮卡 + 当前训练计时 + 队列序号
func _build_training(parent: Node) -> void:
	var head := _section(parent, "训练")
	_queue_count = Label.new()
	_queue_count.text = ""
	_queue_count.add_theme_font_size_override("font_size", 12)
	_queue_count.add_theme_color_override("font_color", Color(0.80, 0.74, 0.62))
	_queue_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_queue_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_queue_count)

	_train_btns = HBoxContainer.new()
	_train_btns.name = "训练按钮"
	_train_btns.add_theme_constant_override("separation", 6)
	_train_btns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_train_btns)

	var row := HBoxContainer.new()
	row.name = "训练计时"
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	_train_bar = Bar.new()
	_train_bar.custom_minimum_size = Vector2(0.0, 16.0)
	_train_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_train_bar.fill = Color(0.44, 0.76, 0.98)
	row.add_child(_train_bar)

	_train_rest = Label.new()
	_train_rest.text = "-"
	_train_rest.custom_minimum_size = Vector2(82.0, 0.0)
	_train_rest.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_train_rest.add_theme_font_size_override("font_size", 13)
	_train_rest.add_theme_color_override("font_color", Color(0.86, 0.86, 0.80))
	_train_rest.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_train_rest.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _mono != null:
		_train_rest.add_theme_font_override("font", _mono)
	row.add_child(_train_rest)

	_cancel = _small_button("取消训练", _warn)
	_cancel.name = "取消训练"
	_cancel.pressed.connect(_on_cancel_pressed)
	row.add_child(_cancel)

	_queue_row = HBoxContainer.new()
	_queue_row.name = "队列"
	_queue_row.add_theme_constant_override("separation", 4)
	_queue_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_queue_row)
	for i in QUEUE_MAX:
		var chip := PanelContainer.new()
		chip.name = "队列项%d" % (i + 1)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.visible = false
		chip.add_theme_stylebox_override("panel", _chip_style())
		var lb := Label.new()
		lb.text = ""
		lb.add_theme_font_size_override("font_size", 12)
		lb.add_theme_color_override("font_color", Color(0.87, 0.83, 0.73))
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(lb)
		_queue_row.add_child(chip)
		_queue_chips.append(chip)
		_queue_labels.append(lb)


## 集结点区
func _build_rally(parent: Node) -> void:
	_section(parent, "集结点")
	var row := HBoxContainer.new()
	row.name = "集结点行"
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	_rally_btn = _small_button("设置集结点", _warm)
	_rally_btn.name = "设置集结点"
	_rally_btn.custom_minimum_size = Vector2(104.0, 24.0)
	_rally_btn.pressed.connect(_on_rally_pressed)
	row.add_child(_rally_btn)

	_rally_label = Label.new()
	_rally_label.text = "集结点：未设置"
	_rally_label.add_theme_font_size_override("font_size", 12)
	_rally_label.add_theme_color_override("font_color", Color(0.80, 0.78, 0.70))
	_rally_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_rally_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_rally_label)


## 研究区（只有铁匠铺这类带 researches 的建筑才显示）
func _build_research(parent: Node) -> void:
	_research_box = VBoxContainer.new()
	_research_box.name = "研究"
	_research_box.add_theme_constant_override("separation", 3)
	_research_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_research_box.visible = false
	parent.add_child(_research_box)

	_section(_research_box, "研究")
	_research_btns = HBoxContainer.new()
	_research_btns.name = "研究按钮"
	_research_btns.add_theme_constant_override("separation", 6)
	_research_btns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_research_box.add_child(_research_btns)


## 块状分区标题：左侧粗色条 + 标题字 + 一条淡色横线（右侧留白给附加文字）
func _section(parent: Node, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "分区_%s" % text
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	var stripe := ColorRect.new()
	stripe.color = Color(_warm.r, _warm.g, _warm.b, 0.96)
	stripe.custom_minimum_size = Vector2(3.0, 12.0)
	stripe.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stripe)

	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 13)
	lb.add_theme_color_override("font_color", Color(_warm.r, _warm.g, _warm.b, 0.98))
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lb)

	var rule := ColorRect.new()
	rule.color = Color(_warm.r, _warm.g, _warm.b, 0.18)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(rule)
	return row


# ===========================================================================
# 对外接口
# ===========================================================================

## 面板期望高度（HUD 按它贴底摆放／贴落点提示）
func desired_height() -> float:
	ensure_built()
	return maxf(get_combined_minimum_size().y, H_MIN)


## 刷新（HUD 每 0.12s 会调一次；换建筑类型时才重建按钮，其余只改数值）
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
	# --- 训练按钮 ---
	for c in _train_btns.get_children():
		c.queue_free()
	_train_ids.clear()
	if d != null:
		for id in d.trains:
			var btn := _train_card(id)
			_train_btns.add_child(btn)
			_train_ids.append(id)

	# --- 研究按钮 ---
	for c in _research_btns.get_children():
		c.queue_free()
	_research_ids.clear()
	if d != null and not d.researches.is_empty():
		for rid in d.researches:
			var rb := _research_button(rid)
			_research_btns.add_child(rb)
			_research_ids.append(rid)
		_research_box.visible = true
	else:
		_research_box.visible = false


## 训练按钮卡：名称 + 造价（紧凑、左缘一条分类色）
func _train_card(id: StringName) -> Button:
	var d: UnitDef = _def_of_id(id)
	var nm: String = d.display_name if d != null else String(id)
	var text: String = nm
	if d != null:
		var cost: String = ""
		if d.gold_cost > 0:
			cost = "%d金" % d.gold_cost
		if d.wood_cost > 0:
			cost = (cost + " ") if cost != "" else ""
			cost += "%d木" % d.wood_cost
		if cost != "":
			text = "%s  %s" % [nm, cost]
	var btn := Button.new()
	btn.name = "训练_%s" % String(id)
	btn.text = text
	btn.tooltip_text = "训练 %s（点击排队）" % nm
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.custom_minimum_size = TRAIN_BTN
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_stylebox_override("normal",
			_btn_style(Color(0.118, 0.102, 0.082, 0.98), Color(_warm.r, _warm.g, _warm.b, 0.42), _warm))
	btn.add_theme_stylebox_override("hover",
			_btn_style(Color(0.180, 0.156, 0.120, 0.99), Color(_warm.r, _warm.g, _warm.b, 0.90), _warm))
	btn.add_theme_stylebox_override("pressed",
			_btn_style(Color(0.300, 0.230, 0.130, 0.99), _warm, _warm))
	btn.add_theme_stylebox_override("disabled",
			_btn_style(Color(0.085, 0.080, 0.072, 0.92), Color(0.34, 0.33, 0.30, 0.30), null))
	btn.add_theme_color_override("font_color", Color(0.93, 0.90, 0.82))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_disabled_color", Color(0.50, 0.48, 0.44))
	btn.pressed.connect(_on_train_pressed.bind(id))
	return btn


## 研究按钮（铁匠铺）：名字 + 当前能不能点（原因写在 tooltip 里）
func _research_button(rid: StringName) -> Button:
	var label: String = _research_title(rid)
	var reason: String = ""
	if _target != null and is_instance_valid(_target) and _target.has_method("research_block_reason"):
		reason = String(_target.call("research_block_reason", rid))
	var btn := _small_button(label, Color(0.74, 0.86, 1.0))
	btn.name = "研究_%s" % String(rid)
	btn.custom_minimum_size = Vector2(112.0, 26.0)
	btn.tooltip_text = ("研究 " + label) if reason == "" else reason
	btn.disabled = reason != ""
	btn.pressed.connect(_on_research_pressed.bind(rid))
	return btn


## 研究 id → 中文名（研究定义由配置层持有，这里只兜底显示名，不依赖 ResearchDef）
func _research_title(rid: StringName) -> String:
	match rid:
		&"attack_up":
			return "攻击强化"
		&"armor_up":
			return "护甲强化"
		_:
			return String(rid)


# ===========================================================================
# 数值同步（每次 refresh / 每帧）
# ===========================================================================

func _sync_all() -> void:
	if _target == null or not is_instance_valid(_target):
		_show_idle()
		return
	var d: UnitDef = _target.def
	var shown_name: String = d.display_name if d != null else "建筑"
	_title_name.text = shown_name
	_title_name.add_theme_color_override("font_color", Color(0.11, 0.080, 0.045))

	# --- 标题状态 ---
	_title_state.text = _state_text()

	# --- 阵营色条 ---
	var fac: RtsFaction = _target.faction
	var col: Color = fac.color if fac != null else Color(0.62, 0.60, 0.55)
	var chip := StyleBoxFlat.new()
	chip.bg_color = col
	chip.border_color = Color(0.0, 0.0, 0.0, 0.45)
	chip.set_border_width_all(1)
	chip.set_corner_radius_all(2)
	_faction_chip.add_theme_stylebox_override("panel", chip)

	# --- 生命 ---
	var max_hp: float = d.max_hp if d != null and d.max_hp > 0.0 else 1.0
	var hp: float = clampf(_target.hp, 0.0, max_hp)
	var hp_pct: int = int(round(hp / maxf(max_hp, 0.001) * 100.0))
	var hp_col: Color = Color(0.40, 0.84, 0.50)
	if hp_pct <= 30:
		hp_col = Color(0.95, 0.34, 0.28)
	elif hp_pct <= 60:
		hp_col = Color(0.96, 0.74, 0.30)
	_hp.feed(hp / maxf(max_hp, 0.001), hp_col,
			"生命 %d / %d" % [int(round(hp)), int(round(max_hp))])

	# --- 建造进度 ---
	var constructing: bool = not _target.is_constructed
	_build_box.visible = constructing
	if constructing:
		var p: float = clampf(_target.progress, 0.0, 1.0)
		_build_cap.text = "建造中 %d%%" % int(round(p * 100.0))
		_build_bar.feed(p, Color(0.96, 0.72, 0.30), "")

	# --- 训练队列 ---
	_sync_training()

	# --- 集结点 ---
	var cmd := _command_system()
	var rally_txt: String = "集结点：已设置" if _target.has_rally else "集结点：未设置"
	if cmd != null and cmd.has_method("is_rally_pending") and bool(cmd.call("is_rally_pending")):
		rally_txt = "集结点：左键点地面…"
	_rally_label.text = rally_txt
	_rally_label.add_theme_color_override("font_color",
			Color(0.86, 0.82, 0.66) if _target.has_rally else Color(0.72, 0.70, 0.63))
	_rally_btn.disabled = cmd == null or not cmd.has_method("request_set_rally")


func _sync_training() -> void:
	var can_train_now: bool = _target.is_constructed
	var queue_n: int = _target.train_queue.size()
	_queue_count.text = "队列 %d / %d" % [queue_n, QUEUE_MAX]

	# 按钮可用性：没完工 / 队列满 / 造不起 → 禁用（队列上限由界面兜住）
	var full: bool = queue_n >= QUEUE_MAX
	for i in _train_ids.size():
		var btn := _train_btns.get_child(i) as Button
		if btn == null:
			continue
		var ud: UnitDef = _def_of_id(_train_ids[i])
		var afford: bool = ud != null and _can_afford(ud)
		btn.disabled = (not can_train_now) or full or (not afford)

	# 当前训练：进度条 + 剩余秒数
	var cur: StringName = _target.current_training()
	if cur == &"":
		_train_bar.feed(0.0, Color(0.44, 0.76, 0.98), "")
		_train_rest.text = "-"
		_cancel.disabled = true
	else:
		var p: float = clampf(_target.train_progress, 0.0, 1.0)
		var ud: UnitDef = _def_of_id(cur)
		var total: float = ud.train_time if ud != null else 0.0
		var rest: float = maxf(1.0 - p, 0.0) * total
		var nm: String = ud.display_name if ud != null else String(cur)
		_train_bar.feed(p, Color(0.44, 0.76, 0.98), "%s  %d%%" % [nm, int(round(p * 100.0))])
		_train_rest.text = "剩余 %.1fs" % rest
		_cancel.disabled = not _target.is_constructed

	# 队列序号（最多 5 项）
	for i in _queue_chips.size():
		if i < queue_n:
			var id: StringName = _target.train_queue[i]
			_queue_labels[i].text = "%d %s" % [i + 1, _id_name(id)]
			_queue_chips[i].visible = true
			_queue_chips[i].modulate = Color(1, 1, 1, 1) if i == 0 else Color(0.86, 0.84, 0.78, 1)
		else:
			_queue_chips[i].visible = false

	# 研究按钮：等级不在这里显示（研究定义在配置层），只按"能不能点"更新
	for i in _research_ids.size():
		var rb := _research_btns.get_child(i) as Button
		if rb == null:
			continue
		var reason: String = ""
		if _target.has_method("research_block_reason"):
			reason = String(_target.call("research_block_reason", _research_ids[i]))
		rb.disabled = reason != ""
		rb.tooltip_text = ("研究 " + _research_title(_research_ids[i])) if reason == "" else reason


## 建筑自己的钱够不够（不用 Game，保持面板可被单独测）
func _can_afford(d: UnitDef) -> bool:
	var fac: RtsFaction = _target.faction if _target != null else null
	if fac == null or d == null:
		return false
	return fac.gold >= d.gold_cost and fac.wood >= d.wood_cost


## 标题右侧的一句话状态
func _state_text() -> String:
	if _target == null:
		return ""
	if not _target.is_constructed:
		return "建造中 %d%%" % int(round(clampf(_target.progress, 0.0, 1.0) * 100.0))
	if _target.has_method("is_researching") and bool(_target.call("is_researching")):
		return "研究中 %d%%" % int(round(clampf(float(_target.call("research_progress")), 0.0, 1.0) * 100.0))
	if not _target.train_queue.is_empty():
		return "训练中"
	return "待命"


func _show_idle() -> void:
	if not _built:
		return
	_title_name.text = "未选中建筑"
	_title_name.add_theme_color_override("font_color", Color(0.11, 0.080, 0.045))
	_title_state.text = ""
	if _faction_chip != null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.45, 0.43, 0.38, 0.85)
		sb.set_corner_radius_all(2)
		_faction_chip.add_theme_stylebox_override("panel", sb)
	_hp.feed(0.0, Color(0.40, 0.84, 0.50), "未选中建筑")
	_build_box.visible = false
	_queue_count.text = ""
	for c in _train_btns.get_children():
		var b := c as Button
		if b != null:
			b.disabled = true
	_train_bar.feed(0.0, Color(0.44, 0.76, 0.98), "")
	_train_rest.text = "-"
	_cancel.disabled = true
	for chip in _queue_chips:
		chip.visible = false
	_rally_label.text = "集结点：未设置"
	_rally_btn.disabled = true
	_research_box.visible = false


# ===========================================================================
# 交互
# ===========================================================================

func _on_train_pressed(id: StringName) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var ok: bool = bool(_target.call("queue_train", id))
	if ok:
		refresh(_target)
		return
	# queue_train 自己会 toast 资源/人口不足，这里只补它不解释的两种情况
	if _target.train_queue.size() >= QUEUE_MAX:
		_toast("训练队列已满（最多 %d 个）" % QUEUE_MAX, _warn)
	elif not _target.is_constructed:
		_toast("建筑还没完工，不能训练", _warn)


func _on_cancel_pressed() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	_target.call("cancel_train")
	refresh(_target)


func _on_rally_pressed() -> void:
	var cmd := _command_system()
	if cmd != null and cmd.has_method("request_set_rally"):
		cmd.call("request_set_rally")
		_toast("左键点地面设置集结点（右键取消）", _warm)
	else:
		_toast("集结点功能还没接上（指令系统未就绪）", _warn)
	if _target != null and is_instance_valid(_target):
		refresh(_target)


func _on_research_pressed(rid: StringName) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var reason: String = ""
	if _target.has_method("research_block_reason"):
		reason = String(_target.call("research_block_reason", rid))
	if reason != "":
		_toast(reason, _warn)
		return
	if not bool(_target.call("research", rid)):
		_toast("暂时不能研究这项", _warn)
		return
	refresh(_target)


# ===========================================================================
# 小工具
# ===========================================================================

## 小按钮（取消训练 / 设置集结点 / 研究）
func _small_button(text: String, col: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.custom_minimum_size = Vector2(0.0, 24.0)
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_stylebox_override("normal",
			_btn_style(Color(0.120, 0.104, 0.084, 0.98), Color(col.r, col.g, col.b, 0.45), null))
	b.add_theme_stylebox_override("hover",
			_btn_style(Color(0.190, 0.165, 0.128, 0.99), Color(col.r, col.g, col.b, 0.92), null))
	b.add_theme_stylebox_override("pressed",
			_btn_style(Color(0.300, 0.230, 0.130, 0.99), col, null))
	b.add_theme_stylebox_override("disabled",
			_btn_style(Color(0.082, 0.078, 0.070, 0.92), Color(0.34, 0.33, 0.30, 0.28), null))
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	b.add_theme_color_override("font_disabled_color", Color(0.48, 0.46, 0.42))
	return b


## 按钮底色盒；stripe 是 Color 时左缘加一条分类色
func _btn_style(bg: Color, border: Color, stripe) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.corner_detail = 6
	sb.content_margin_left = 7.0
	sb.content_margin_right = 7.0
	if stripe is Color:
		var c := stripe as Color
		sb.border_width_left = 3
		sb.bg_color = bg.lerp(Color(c.r, c.g, c.b, bg.a), 0.10)
	return sb


## 队列小牌的底色
func _chip_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.135, 0.118, 0.094, 0.96)
	sb.border_color = Color(_warm.r, _warm.g, _warm.b, 0.28)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 0.0
	sb.content_margin_bottom = 0.0
	return sb


## 单位 id → 显示名（配置不在就退回 id 本身）
func _id_name(id: StringName) -> String:
	var d: UnitDef = _def_of_id(id)
	return d.display_name if d != null else String(id)


## 等宽字体：只给纯数字（剩余秒数）用，不配中文兜底也不会出方块
func _make_mono_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Consolas", "Cascadia Mono", "DejaVu Sans Mono",
		"Liberation Mono", "Courier New", "monospace",
	])
	return f
