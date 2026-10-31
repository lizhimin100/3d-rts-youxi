class_name RtsBuildingPanel
extends PanelContainer
## **建筑面板（RtsBuildingPanel）** —— 选中**单个建筑**时顶替单位档案板的专属版式。
##
## 为什么单开一套：单位面板讲的是"这个兵多能打"（头像 + 属性三连 + 特性牌），
## 建筑关心的是"它能干什么、正在干什么"（训练队列 / 建造进度 / 集结点 / 研究）。
## 把两者塞进一张卡只会互相挤，所以这里换一套视觉语言：
##   · 单位面板：深色底 + 金色细描边 + 3D 头像；
##   · 本面板：**暖色标题条 + 块状分区（左侧 3px 粗色条）**，无头像，版面按 8px 栅格。
##
## 版式（四段，没内容的分段整块隐藏，不留空行）：
##   ┌──────────────────────────────────────────────┐
##   │ 兵营                 〔建造中 42%〕    ●玩家 │
##   │ 生命 940/1500  ██████████████░░░░░░          │
##   │ ██ 建造中 42%                                │
##   │ ▌训练                              队列 2/5  │
##   │ [步兵 135金] [弓箭手 130金] [法师 155金]     │
##   │ ███████░░░░  剩余 8.4s   [取消训练]          │
##   │ ①步兵  ②弓箭手                               │
##   │ ▌集结点  [设置集结点]  集结点：未设置        │
##   │ ▌研究    [攻击强化 1/3] [护甲强化 0/3]       │
##   └──────────────────────────────────────────────┘
##
## 四条纪律：
##   1. 训练计时条由**本面板自己 _process 每帧刷**（HUD 的 0.12s 节流会让秒数一跳一跳）；
##   2. 数值/颜色只从 GameConfig 与建筑自身读，不在界面里发明规则；
##   3. 训练走 RtsBuilding.queue_train()、取消走 cancel_train()，和命令卡是同一条路；
##   4. 宽度由 HUD 的 set_metrics() 注入，1024 档自动收窄、按钮仍不裁字。

const Spec := preload("res://代码/界面/界面规格.gd")

# ===========================================================================
# 版面常量
# ===========================================================================

## 面板总宽（与单位面板同宽，HUD 会按分辨率覆盖）
const PANEL_W := 512.0
## 最小高度（内容更矮时也保持一块像样的面板）
## 2026-10-23：150 → 126。面板从"屏幕中央下方"搬到"左下角"后，高度必须收，
## 否则选中兵营时它还是会顶到屏幕中线。
const H_MIN := 126.0
## 建筑头像边长：底栏总高 136、面板高 ~88，52 是"看得清又不多占宽"的档位
const PIC := 52.0
## 训练队列最多显示几项（与指令系统的训练上限一致）
const QUEUE_MAX := 5
## 面板内边距（8 的倍数；压到 8 是为了把高度让给"按钮 ≥64"）
const PAD := 6.0
## 训练按钮卡高度（两行：名称 + 造价）
const TRAIN_H := 50.0
## 研究/集结点按钮高度
const ACTION_H := 38.0


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
		_label.add_theme_constant_override("outline_size", 2)
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
## HUD 注入的宽度 / 小屏标记
var _panel_w: float = PANEL_W
var _compact: bool = false
## 纵向主容器（desired_height 直接量内容，避免底部一行被挤出面板）
var _vb: VBoxContainer = null
## 右列（训练 / 研究）
var _vb2: VBoxContainer = null
## 阵营色条 / 集结点文字的签名：一样就不重写（否则每帧都广播 THEME_CHANGED）
var _faction_sig: String = ""
var _rally_sig: int = -1

# --- 控件 ---
var _title_name: Label = null
var _title_state: Label = null
var _faction_chip: Panel = null
var _hp: Bar = null

## 建筑属性小铭牌（攻击 / 射程 / 视野 / 护甲）—— **能攻击的建筑必须显示攻击信息**
var _stats_row: HBoxContainer = null
var _stat_chips: Array[PanelContainer] = []
var _stat_icons: Array[Control] = []
var _stat_labels: Array[Label] = []
var _stats_sig: String = ""

var _build_box: VBoxContainer = null
var _build_cap: Label = null
var _build_bar: Bar = null

var _train_box: VBoxContainer = null
var _train_btns: HBoxContainer = null
var _train_ids: Array[StringName] = []
var _queue_count: Label = null
var _timer_box: HBoxContainer = null
var _train_bar: Bar = null
var _train_rest: Label = null
var _cancel: Button = null
var _queue_row: HBoxContainer = null
## 队列小牌是 PanelContainer（不是 Panel）：typed array 类型必须和 push 进去的实例一致，
## 否则运行时报 "Attempted to push_back an object of type 'PanelContainer' into a TypedArray"。
var _queue_chips: Array[PanelContainer] = []
var _queue_labels: Array[Label] = []
var _queue_icons: Array[TextureRect] = []
var _queue_bars: Array = []

var _rally_box: VBoxContainer = null
var _rally_btn: Button = null
var _rally_label: Label = null
## 建筑头像（美术资产渲图，`美术/图标/建筑/<id>.png`）
var _pic: TextureRect = null

var _research_box: VBoxContainer = null
var _research_btns: HBoxContainer = null
var _research_ids: Array[StringName] = []
var _research_bar: Bar = null


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
##
## 2026-10-31：版式从"一列往下堆"改成**两列**。
## 底栏变宽以后，一列的结构会把血条拉成 660px 的跑道、把"剩余 11.2s"甩到屏幕中间去；
## 两列之后左列是"这栋楼现在什么状态"（名字/血/建造进度），
## 右列是"它正在干什么、能干什么"（训练计时/队列/集结点/研究），
## 各占一半，密度和魔兽的建筑面板一致。
func ensure_built() -> void:
	if _built:
		return
	_built = true
	_mono = Spec.mono_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(_panel_w, H_MIN)
	add_theme_stylebox_override("panel", _make_panel_style())

	var row := HBoxContainer.new()
	row.name = "两列"
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	# --- 左：**建筑头像** ---
	# 图标来自美术资产：`工具/渲染建筑图标.py` 把 美术/模型/<建筑>.glb 渲成 256² 透明底 PNG
	# （美术/图标/建筑/<id>.png）。以前建筑面板"无头像"，选一座楼只有一行字，
	# 一眼分不清是大本营还是兵营；现在和单位面板一样有门面。
	var pic_box := Panel.new()
	pic_box.name = "建筑头像框"
	pic_box.custom_minimum_size = Vector2(PIC, PIC)
	pic_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pic_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color(0.055, 0.062, 0.074, 0.98)
	psb.set_corner_radius_all(6)
	psb.border_color = Color(_warm.r, _warm.g, _warm.b, 0.55)
	psb.set_border_width_all(2)
	pic_box.add_theme_stylebox_override("panel", psb)
	row.add_child(pic_box)

	_pic = TextureRect.new()
	_pic.name = "建筑头像"
	_pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_pic.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pic.offset_left = 3.0
	_pic.offset_top = 3.0
	_pic.offset_right = -3.0
	_pic.offset_bottom = -3.0
	_pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic_box.add_child(_pic)

	var vb := VBoxContainer.new()
	vb.name = "纵"
	vb.add_theme_constant_override("separation", 2)
	# 让出头像那一列（PIC + 间距）—— 不减就会把整条底栏挤宽，把队伍网格顶出屏幕
	vb.custom_minimum_size = Vector2(maxf(200.0, 400.0 - PIC - 10.0), 0.0)
	vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(vb)
	_vb = vb

	var vb2 := VBoxContainer.new()
	vb2.name = "纵2"
	vb2.add_theme_constant_override("separation", 2)
	vb2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(vb2)
	_vb2 = vb2

	_build_title(vb)
	_build_health(vb)
	_build_stats(vb)
	_build_construction(vb)
	_build_rally(vb)

	_build_training(vb2)
	_build_research(vb2)
	_show_idle()


## HUD 注入响应式尺寸
func set_metrics(w: float, h_single: float, _h_multi: float, compact: bool) -> void:
	ensure_built()
	_panel_w = w
	_compact = compact
	# 高度下限用调用方给的实测值（HUD 传 300），**不要**再 reset_size()。
	# reset_size 会把 HUD 刚摆好的 offset 全部覆盖，面板被压回 H_MIN，
	# 训练条和集结点就会叠成一坨（这就是之前那个 bug）。
	custom_minimum_size = Vector2(_panel_w, maxf(H_MIN, h_single))
	# ★ 2026-10-31：左列原来写死 338px 最小宽（400-52-10），
	#   面板只有 344 宽时右列（训练/研究）被压成 0 —— 玩家报的"训练队列看不见"就是这个。
	#   现在左列按面板宽度取 40%，右列（训练 / 研究）永远有地方站。
	if _vb != null:
		_vb.custom_minimum_size = Vector2(clampf(_panel_w * 0.40, 150.0, 252.0), 0.0)


## 面板底：底栏**段底**的同一套皮肤（比底板深一档、小圆角、无投影）。
## 2026-10-31：以前这块是"自带外投影的独立卡片"，和右边的命令卡一高一低时
## 读起来是两个盒子；现在两块面板共用 segment_style，才是"一条带子的两段"。
func _make_panel_style() -> StyleBoxFlat:
	return Spec.segment_style(Color(0.092, 0.084, 0.070, 0.93), 8, 8.0, 0.13)


## 标题行：**名字做成一块暖色小牌**（不再是一整条橙色横贯面板）。
##
## 2026-10-31：底栏变宽之后，一条通栏的橙色标题条在 1000px 宽的面板里
## 变成一道橙色大杠，比建筑本身还抢眼。改成"小牌子 + 状态字 + 阵营色条"，
## 橙色只出现在名字后面那一小段，"这是建筑"的语义还在，视觉重量降下来了。
func _build_title(parent: Node) -> void:
	var row := HBoxContainer.new()
	row.name = "标题行"
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(0.0, 26.0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	var strip := PanelContainer.new()
	strip.name = "名字牌"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(_warm.r, _warm.g, _warm.b, 0.90)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 1.0
	sb.content_margin_bottom = 1.0
	strip.add_theme_stylebox_override("panel", sb)
	row.add_child(strip)

	_title_name = Spec.label("未选中建筑", Spec.FS_VALUE, Color(0.11, 0.080, 0.045))
	_title_name.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	strip.add_child(_title_name)

	_title_state = Spec.label("", Spec.FS_BODY, Color(0.96, 0.80, 0.52))
	_title_state.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_title_state)

	var grow := Control.new()
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(grow)

	# 阵营色条（右端一条实色块）
	_faction_chip = Panel.new()
	_faction_chip.name = "阵营色条"
	_faction_chip.custom_minimum_size = Vector2(40.0, 10.0)
	_faction_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_faction_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_faction_chip)


## 属性小铭牌：攻击力 / 射程 / 视野 / 护甲（按建筑类型自动取舍）
##
## 玩家口径："箭塔这类能攻击的建筑，操作面板和信息面板要显示对应的信息"。
## 所以**有攻击的建筑**第一格永远是攻击力（含射速），第二格射程，第三格视野；
## 哨塔没有攻击 → 不摆一个假的攻击格，改成 视野 / 护甲 /（人口或建造耗时）。
func _build_stats(parent: Node) -> void:
	_stats_row = HBoxContainer.new()
	_stats_row.name = "属性"
	_stats_row.add_theme_constant_override("separation", 4)
	_stats_row.custom_minimum_size = Vector2(0.0, 22.0)
	_stats_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_stats_row)

	for i in 3:
		var chip := PanelContainer.new()
		chip.name = "属性%d" % i
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.add_theme_stylebox_override("panel",
				Spec.inset_style(Color(0.070, 0.064, 0.052, 0.95), 4,
						Color(_warm.r, _warm.g, _warm.b, 0.20), 5.0, 0.0))
		_stats_row.add_child(chip)
		_stat_chips.append(chip)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(row)

		var ic := Spec.icon("sword", 13.0, Color(0.98, 0.62, 0.42))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ic)
		_stat_icons.append(ic)

		var lb := Spec.label("-", Spec.FS_CAPTION, Color(0.94, 0.90, 0.80))
		lb.add_theme_font_override("font", _mono)
		lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lb)
		_stat_labels.append(lb)


## 刷新属性铭牌（同一个 def 只写一次文字）
func _sync_stats_row(d: UnitDef) -> void:
	if _stats_row == null:
		return
	if d == null:
		_stats_row.visible = false
		return
	var stats: Array = _stats_of(d)
	var sig: String = "%s|%d" % [String(d.id), stats.size()]
	if sig != _stats_sig:
		_stats_sig = sig
		for i in _stat_chips.size():
			if i >= stats.size():
				_stat_chips[i].visible = false
				continue
			var s: Dictionary = stats[i]
			_stat_chips[i].visible = true
			_stat_chips[i].tooltip_text = String(s.get("tip", ""))
			var col: Color = s.get("color", Color(0.9, 0.88, 0.8))
			Spec.set_icon(_stat_icons[i], String(s.get("icon", "sword")), col)
			_stat_labels[i].text = String(s.get("text", "-"))
			_stat_labels[i].add_theme_color_override("font_color", col.lerp(Color(1, 1, 1), 0.55))
	_stats_row.visible = not stats.is_empty()


func _stats_of(d: UnitDef) -> Array:
	if d == null:
		return []
	if d.can_attack():
		return [
			{"icon": "sword", "color": Color(0.98, 0.62, 0.42),
				"text": "%s / %.1fs" % [_num(d.attack_damage), d.attack_cooldown],
				"tip": "攻击力 / 射击间隔"},
			{"icon": "bow", "color": Color(0.86, 0.80, 0.52),
				"text": "%dm" % int(round(d.attack_range)), "tip": "射程"},
			{"icon": "eye", "color": Color(0.66, 0.86, 0.92),
				"text": "%dm" % int(round(d.sight_range)), "tip": "视野"},
		]
	var out: Array = [
		{"icon": "eye", "color": Color(0.66, 0.86, 0.92),
			"text": "%dm" % int(round(d.sight_range)), "tip": "视野（哨塔只负责看，不攻击）"},
		{"icon": "shield", "color": Color(0.62, 0.78, 0.98),
			"text": _num(d.armor), "tip": "护甲"},
	]
	if d.food_provided > 0:
		out.append({"icon": "house", "color": Color(0.80, 0.88, 0.66),
			"text": "+%d" % d.food_provided, "tip": "提供人口上限"})
	else:
		out.append({"icon": "gear", "color": Color(0.80, 0.80, 0.76),
			"text": "%ds" % int(round(d.train_time)), "tip": "建造耗时"})
	return out


func _num(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


## 血量条
func _build_health(parent: Node) -> void:
	_hp = Bar.new()
	_hp.name = "生命条"
	_hp.custom_minimum_size = Vector2(0.0, 24.0)
	_hp.fill = Color(0.40, 0.84, 0.50)
	parent.add_child(_hp)


## 建造进度（未完工时出现，完工后整块隐藏）
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
	_build_bar.custom_minimum_size = Vector2(0.0, 14.0)
	_build_bar.fill = Color(0.96, 0.72, 0.30)
	_build_box.add_child(_build_bar)


## 训练区：分区标题 + 按钮卡 + 当前训练计时 + 队列序号
func _build_training(parent: Node) -> void:
	_train_box = VBoxContainer.new()
	_train_box.name = "训练区"
	_train_box.add_theme_constant_override("separation", 4)
	_train_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_train_box)

	var head := _section(_train_box, "训练")
	_queue_count = Spec.label("", Spec.FS_BODY, Color(0.80, 0.74, 0.62))
	head.add_child(_queue_count)

	_train_btns = HBoxContainer.new()
	_train_btns.name = "训练按钮"
	_train_btns.add_theme_constant_override("separation", 6)
	_train_btns.custom_minimum_size = Vector2(0.0, TRAIN_H)
	_train_btns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_train_box.add_child(_train_btns)

	_timer_box = HBoxContainer.new()
	_timer_box.name = "训练计时"
	_timer_box.add_theme_constant_override("separation", 8)
	_timer_box.custom_minimum_size = Vector2(0.0, 22.0)
	_timer_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_train_box.add_child(_timer_box)

	_train_bar = Bar.new()
	_train_bar.custom_minimum_size = Vector2(0.0, 16.0)
	_train_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_train_bar.fill = Color(0.44, 0.76, 0.98)
	_timer_box.add_child(_train_bar)

	_train_rest = Spec.label("-", Spec.FS_VALUE, Color(0.86, 0.86, 0.80), HORIZONTAL_ALIGNMENT_RIGHT)
	_train_rest.custom_minimum_size = Vector2(78.0, 0.0)
	_train_rest.add_theme_font_override("font", _mono)
	_timer_box.add_child(_train_rest)

	_cancel = _small_button("取消训练", _warn)
	_cancel.name = "取消训练"
	_cancel.custom_minimum_size = Vector2(76.0, 22.0)
	_cancel.pressed.connect(_on_cancel_pressed)
	_timer_box.add_child(_cancel)

	_queue_row = HBoxContainer.new()
	_queue_row.name = "队列"
	_queue_row.add_theme_constant_override("separation", 4)
	_queue_row.custom_minimum_size = Vector2(0.0, 26.0)
	_queue_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_train_box.add_child(_queue_row)
	for i in QUEUE_MAX:
		var chip := PanelContainer.new()
		chip.name = "队列项%d" % (i + 1)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.visible = false
		chip.add_theme_stylebox_override("panel", _chip_style())
		# 队列小牌 = **单位头像 + 序号 + 一条自己的进度条**。
		# 玩家口径："训练队列和时长进度条"——队首那格会自己往前走，
		# 后排的格子条是空的，一眼看出"排了几个、正在出第几个"。
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 1)
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(vb)
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 3)
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(hb)
		var ico := TextureRect.new()
		ico.name = "头像"
		ico.custom_minimum_size = Vector2(16.0, 16.0)
		ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(ico)
		var lb := Spec.label("", Spec.FS_CAPTION, Color(0.87, 0.83, 0.73))
		lb.add_theme_font_override("font", _mono)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(lb)
		var bar := Bar.new()
		bar.name = "进度"
		bar.custom_minimum_size = Vector2(0.0, 4.0)
		bar.fill = Color(0.44, 0.76, 0.98)
		vb.add_child(bar)
		_queue_row.add_child(chip)
		_queue_chips.append(chip)
		_queue_labels.append(lb)
		_queue_icons.append(ico)
		_queue_bars.append(bar)


## 集结点区
func _build_rally(parent: Node) -> void:
	_rally_box = VBoxContainer.new()
	_rally_box.name = "集结点区"
	_rally_box.add_theme_constant_override("separation", 4)
	_rally_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_rally_box)

	_section(_rally_box, "集结点")
	var row := HBoxContainer.new()
	row.name = "集结点行"
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(0.0, 18.0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rally_box.add_child(row)

	_rally_btn = _small_button("设置集结点", _warm)
	_rally_btn.name = "设置集结点"
	_rally_btn.custom_minimum_size = Vector2(112.0, 36.0)
	_rally_btn.add_theme_font_size_override("font_size", Spec.FS_BODY)
	_rally_btn.pressed.connect(_on_rally_pressed)
	row.add_child(_rally_btn)

	_rally_label = Spec.label("集结点：未设置", Spec.FS_BODY, Color(0.80, 0.78, 0.70))
	_rally_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rally_label.clip_text = true
	row.add_child(_rally_label)


## 研究区（只有铁匠铺这类带 researches 的建筑才显示）
func _build_research(parent: Node) -> void:
	_research_box = VBoxContainer.new()
	_research_box.name = "研究"
	_research_box.add_theme_constant_override("separation", 4)
	_research_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_research_box.visible = false
	parent.add_child(_research_box)

	_section(_research_box, "研究")
	_research_btns = HBoxContainer.new()
	_research_btns.name = "研究按钮"
	_research_btns.add_theme_constant_override("separation", 6)
	_research_btns.custom_minimum_size = Vector2(0.0, 28.0)
	_research_btns.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_research_box.add_child(_research_btns)

	# 研究进度条（有研究在跑时出现）：和训练共用同一套"时长进度"语言
	_research_bar = Bar.new()
	_research_bar.name = "研究进度"
	_research_bar.custom_minimum_size = Vector2(0.0, 10.0)
	_research_bar.fill = Color(0.72, 0.86, 1.0)
	_research_bar.visible = false
	_research_box.add_child(_research_bar)


## 块状分区标题：左侧粗色条 + 标题字 + 一条淡色横线（右侧留白给附加文字）
func _section(parent: Node, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "分区_%s" % text
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(0.0, 15.0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	var stripe := ColorRect.new()
	stripe.color = Color(_warm.r, _warm.g, _warm.b, 0.96)
	stripe.custom_minimum_size = Vector2(3.0, 12.0)
	stripe.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stripe)

	var lb := Spec.label(text, Spec.FS_CAPTION, Color(_warm.r, _warm.g, _warm.b, 0.98))
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
	var need: float = get_combined_minimum_size().y
	if _vb != null:
		need = maxf(need, _vb.get_combined_minimum_size().y + PAD * 2.0 + 8.0)
	return maxf(need, H_MIN)


## 内容需要的高度（底栏靠它决定该多高；不含 HUD 灌进来的最小高度）
func content_height() -> float:
	ensure_built()
	var a: float = _vb.get_combined_minimum_size().y if _vb != null else 0.0
	var b: float = _vb2.get_combined_minimum_size().y if _vb2 != null else 0.0
	return clampf(maxf(a, b) + PAD * 2.0 + 2.0, 118.0, 200.0)


## 刷新（HUD 每 0.12s 会调一次；换建筑类型时才重建按钮，其余只改数值）
func refresh(target: RtsBuilding) -> void:
	ensure_built()
	_target = target
	if target == null or not is_instance_valid(target):
		_show_idle()
		return
	var d: UnitDef = target.def
	var def_id: StringName = d.id if d != null else &""
	# 头像先换（不随内容重建，避免每次刷新都 load 贴图）
	if _pic != null:
		var bt: Texture2D = Spec.building_icon(def_id)
		if bt != null:
			if _pic.texture != bt:
				_pic.texture = bt
				_pic.modulate = Color(1, 1, 1, 1)
		elif _pic.texture == null:
			_pic.texture = Spec.icon_tex("house")
			_pic.modulate = Color(0.92, 0.88, 0.72, 0.92)
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
	# --- 训练区：**只留进度信息，不再放三个训练按钮** ---
	# 2026-10-23：训练入口和命令卡完全重复，白白把面板撑高 50px。
	# 现在这几块只负责"告诉你在造什么、还剩几秒"，点按统一去右下角命令卡。
	for c in _train_btns.get_children():
		_train_btns.remove_child(c)
		c.queue_free()
	_train_ids.clear()
	_train_btns.visible = false
	# 没有训练项的建筑（农场/箭塔/铁匠铺）整块训练区隐藏，不留空段
	_train_box.visible = d != null and (not d.trains.is_empty())
	_timer_box.visible = _train_box.visible
	_queue_row.visible = _train_box.visible

	# --- 研究按钮 ---
	for c in _research_btns.get_children():
		_research_btns.remove_child(c)
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

	# --- 集结点按钮也搬到命令卡（「集结点」格），面板里只留一行状态文字 ---
	if _rally_btn != null:
		_rally_btn.visible = false
	var show_rally: bool = d != null and (not d.trains.is_empty() or d.is_dropoff)
	_rally_box.visible = show_rally
	if show_rally and _rally_label != null:
		_rally_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## 训练按钮卡：两行（名称 14 / 造价 12），左缘一条分类色
func _train_card(id: StringName) -> Button:
	var d: UnitDef = _def_of_id(id)
	var nm: String = d.display_name if d != null else String(id)
	var cost: String = ""
	if d != null:
		if d.gold_cost > 0:
			cost = "%d金" % d.gold_cost
		if d.wood_cost > 0:
			cost = (cost + " ") if cost != "" else ""
			cost += "%d木" % d.wood_cost

	var btn := Button.new()
	btn.name = "训练_%s" % String(id)
	btn.text = ""
	btn.tooltip_text = "训练 %s（点击排队）　花费 %s　人口 %d　用时 %.0fs" % [
		nm, cost, d.food_cost if d != null else 0, d.train_time if d != null else 0.0]
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	# 固定宽度：一个建筑通常只训练 3 种兵，让按钮铺满整行会变成一块巨型空板
	btn.custom_minimum_size = Vector2(104.0, TRAIN_H)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.add_theme_stylebox_override("normal",
			Spec.button_style(Color(0.118, 0.102, 0.082, 0.98), Color(_warm.r, _warm.g, _warm.b, 0.42), _warm, 5, 8.0, 2.0))
	btn.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.180, 0.156, 0.120, 0.99), Color(_warm.r, _warm.g, _warm.b, 0.90), _warm, 5, 8.0, 2.0))
	btn.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.300, 0.230, 0.130, 0.99), _warm, _warm, 5, 8.0, 2.0))
	btn.add_theme_stylebox_override("disabled",
			Spec.button_style(Color(0.085, 0.080, 0.072, 0.92), Color(0.34, 0.33, 0.30, 0.30), null, 5, 8.0, 2.0))
	btn.add_theme_color_override("font_color", Color(0.93, 0.90, 0.82))
	btn.add_theme_color_override("font_disabled_color", Color(0.50, 0.48, 0.44))

	var vb := VBoxContainer.new()
	vb.name = "两行"
	vb.add_theme_constant_override("separation", 0)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 8.0
	vb.offset_right = -6.0
	vb.offset_top = 2.0
	vb.offset_bottom = -2.0
	btn.add_child(vb)

	# 名称行：[单位图标][名字]。图标就是玩家说的"恰当的图标"——
	# 步兵用剑、弓手用弓、法师用法杖、农民用锤子，一眼分得出训练的是谁。
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(head)
	head.add_child(Spec.icon(_unit_icon(id), 20.0, Color(0.92, 0.84, 0.62)))

	var l1 := Spec.label(nm, Spec.FS_BODY, Color(0.95, 0.92, 0.84))
	l1.name = "名称"
	l1.clip_text = true
	# clip_text 会把最小宽度算成 0；不给 EXPAND 的话 HBox 就把它压成一条缝（名字直接看不见）
	l1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(l1)

	# 造价行：[金币图标][数量][木材图标][数量]，字形"金/木"省掉
	var cost_row := HBoxContainer.new()
	cost_row.add_theme_constant_override("separation", 3)
	cost_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(cost_row)
	var gc: int = d.gold_cost if d != null else 0
	var wc: int = d.wood_cost if d != null else 0
	if gc > 0:
		cost_row.add_child(Spec.icon("coin", 10.0, Color(0.90, 0.78, 0.40)))
		cost_row.add_child(Spec.label(str(gc), Spec.FS_CAPTION, Color(0.86, 0.76, 0.50)))
	if wc > 0:
		cost_row.add_child(Spec.icon("wood", 10.0, Color(0.72, 0.84, 0.56)))
		cost_row.add_child(Spec.label(str(wc), Spec.FS_CAPTION, Color(0.74, 0.82, 0.58)))
	if gc == 0 and wc == 0:
		cost_row.add_child(Spec.label("—", Spec.FS_CAPTION, Color(0.60, 0.58, 0.52)))

	btn.pressed.connect(_on_train_pressed.bind(id))
	return btn


## 训练单位 → 图标名（找不到映射就退回盾牌，绝不退回文字）
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


## 研究按钮（铁匠铺）：名字 + 当前等级（能不能点的原因写在 tooltip 里）
func _research_button(rid: StringName) -> Button:
	var label: String = _research_title(rid)
	var reason: String = ""
	if _target != null and is_instance_valid(_target) and _target.has_method("research_block_reason"):
		reason = String(_target.call("research_block_reason", rid))
	var btn := _small_button(label, Color(0.74, 0.86, 1.0))
	btn.name = "研究_%s" % String(rid)
	btn.custom_minimum_size = Vector2(104.0, ACTION_H)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", Spec.FS_BODY)
	btn.tooltip_text = ("研究 " + label) if reason == "" else reason
	btn.disabled = reason != ""
	btn.pressed.connect(_on_research_pressed.bind(rid))
	return btn


## 研究 id → 中文名。**优先读配置层的 ResearchDef**（伐木场那两项是新加的，
## 界面里不再逐个 if-else 硬编码，否则新研究一上线就显示成英文 id）。
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


# ===========================================================================
# 数值同步（每次 refresh / 每帧）
# ===========================================================================

func _sync_all() -> void:
	if _target == null or not is_instance_valid(_target):
		_show_idle()
		return
	var d: UnitDef = _target.def
	var shown_name: String = d.display_name if d != null else "建筑"
	_set_text(_title_name, shown_name)

	# --- 标题状态 ---
	_set_text(_title_state, _state_text())

	# --- 阵营色条：**只在颜色真的变了**时重建 StyleBox ---
	# 本面板 _process 每帧跑 _sync_all()，无脑 add_theme_stylebox_override 会让
	# 整块面板每帧广播 THEME_CHANGED（既闪又费）—— 这里用颜色签名挡住。
	var fac: RtsFaction = _target.faction
	var col: Color = fac.color if fac != null else Color(0.62, 0.60, 0.55)
	var fsig: String = str(col)
	if fsig != _faction_sig:
		_faction_sig = fsig
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
			"%d / %d　·　%d%%" % [int(round(hp)), int(round(max_hp)), hp_pct])

	# --- 属性（攻击 / 射程 / 视野 / 护甲）---
	_sync_stats_row(d)

	# --- 建造进度 ---
	var constructing: bool = not _target.is_constructed
	_build_box.visible = constructing
	if constructing:
		var p: float = clampf(_target.progress, 0.0, 1.0)
		var total: float = _construction_time(d)
		var rest: float = maxf(1.0 - p, 0.0) * total
		_build_cap.text = "建造中 %d%%　·　剩余 %.0fs" % [int(round(p * 100.0)), rest] if total > 0.0 \
				else "建造中 %d%%" % int(round(p * 100.0))
		_build_bar.feed(p, Color(0.96, 0.72, 0.30), "")

	# --- 训练队列 ---
	_sync_training()

	# --- 集结点 ---
	var cmd := _command_system()
	var rally_txt: String = "集结点：已设置" if _target.has_rally else "集结点：未设置"
	if cmd != null and cmd.has_method("is_rally_pending") and bool(cmd.call("is_rally_pending")):
		rally_txt = "集结点：左键点地面…"
	_set_text(_rally_label, rally_txt)
	var rsig: int = 1 if _target.has_rally else 0
	if rsig != _rally_sig:
		_rally_sig = rsig
		_rally_label.add_theme_color_override("font_color",
				Color(0.86, 0.82, 0.66) if _target.has_rally else Color(0.72, 0.70, 0.63))
	_rally_btn.disabled = cmd == null or not cmd.has_method("request_set_rally")


func _sync_training() -> void:
	if not _train_box.visible:
		return
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
		_train_rest.text = "待训练"
		_cancel.disabled = true
		# 空队列时那条长条没有任何信息量 —— 收起来，只留一句"待训练"，
		# 免得玩家以为"有个进度条一直不动 = 卡住了"。
		_train_bar.visible = false
		_cancel.visible = false
	else:
		_train_bar.visible = true
		_cancel.visible = true
		var p: float = clampf(_target.train_progress, 0.0, 1.0)
		var ud: UnitDef = _def_of_id(cur)
		var total: float = ud.train_time if ud != null else 0.0
		var rest: float = maxf(1.0 - p, 0.0) * total
		var nm: String = ud.display_name if ud != null else String(cur)
		_train_bar.feed(p, Color(0.44, 0.76, 0.98), "%s　%d%%" % [nm, int(round(p * 100.0))])
		_train_rest.text = "剩余 %.1fs" % rest
		_cancel.disabled = not _target.is_constructed

	# 队列序号（最多 5 项）：队首那格带真实进度，后排只有"排到了"
	for i in _queue_chips.size():
		if i < queue_n:
			var id: StringName = _target.train_queue[i]
			_queue_labels[i].text = str(i + 1)
			if i < _queue_icons.size():
				_queue_icons[i].texture = Spec.icon_tex(_unit_icon(id))
			if i < _queue_bars.size() and _queue_bars[i] != null:
				var b: Bar = _queue_bars[i]
				b.feed(clampf(_target.train_progress, 0.0, 1.0) if i == 0 else 0.0,
						Color(0.44, 0.76, 0.98), "")
			_queue_chips[i].visible = true
			# 队首那一项最亮：那是"正在出的兵"
			_queue_chips[i].modulate = Color(1, 1, 1, 1) if i == 0 else Color(0.80, 0.79, 0.74, 1)
		else:
			_queue_chips[i].visible = false
	_queue_row.visible = queue_n > 0

	# 研究按钮：等级显示在按钮文字里，可用性按 reason 更新
	for i in _research_ids.size():
		var rb := _research_btns.get_child(i) as Button
		if rb == null:
			continue
		var reason: String = ""
		if _target.has_method("research_block_reason"):
			reason = String(_target.call("research_block_reason", _research_ids[i]))
		rb.disabled = reason != ""
		var lv: int = RtsCombat.research_level(_target.faction, _research_ids[i])
		var rd: ResearchDef = Cfg.research(_research_ids[i]) if Cfg.game != null else null
		var mx: int = maxi(rd.max_level, 1) if rd != null else 1
		rb.text = "%s %d/%d" % [_research_title(_research_ids[i]), lv, mx]
		rb.tooltip_text = ("研究 " + _research_title(_research_ids[i])) if reason == "" else reason

	# 研究进度条
	if _research_bar != null:
		var busy: bool = _target.has_method("is_researching") and bool(_target.call("is_researching"))
		_research_bar.visible = busy
		if busy:
			var cur_r: StringName = _target.call("current_research")
			var p: float = clampf(float(_target.call("research_progress")), 0.0, 1.0)
			_research_bar.feed(p, Color(0.72, 0.86, 1.0),
					"%s　%d%%" % [_research_title(cur_r), int(round(p * 100.0))])


## 建筑自己的钱够不够（不用 Game，保持面板可被单独测）
func _can_afford(d: UnitDef) -> bool:
	var fac: RtsFaction = _target.faction if _target != null else null
	if fac == null or d == null:
		return false
	return fac.gold >= d.gold_cost and fac.wood >= d.wood_cost


## 建造总时长（从 UnitDef 的 build_time 取；没有就按 0 处理，面板只显示百分比）
func _construction_time(d: UnitDef) -> float:
	if d == null:
		return 0.0
	var t: Variant = d.get("build_time")
	return float(t) if t != null else 0.0


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
	if _stats_row != null:
		_stats_row.visible = false
		_stats_sig = ""
	if _research_bar != null:
		_research_bar.visible = false


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

## 幂等写文本：内容没变就不碰 Label（本面板每帧同步一次，写了就重排）
func _set_text(lb: Label, txt: String) -> void:
	if lb != null and lb.text != txt:
		lb.text = txt


## 小按钮（取消训练 / 设置集结点 / 研究）
func _small_button(text: String, col: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.custom_minimum_size = Vector2(0.0, 24.0)
	b.add_theme_font_size_override("font_size", Spec.FS_CAPTION)
	b.add_theme_stylebox_override("normal",
			Spec.button_style(Color(0.120, 0.104, 0.084, 0.98), Color(col.r, col.g, col.b, 0.45), null, 5, 8.0, 2.0))
	b.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.190, 0.165, 0.128, 0.99), Color(col.r, col.g, col.b, 0.92), null, 5, 8.0, 2.0))
	b.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.300, 0.230, 0.130, 0.99), col, null, 5, 8.0, 2.0))
	b.add_theme_stylebox_override("disabled",
			Spec.button_style(Color(0.082, 0.078, 0.070, 0.92), Color(0.34, 0.33, 0.30, 0.28), null, 5, 8.0, 2.0))
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	b.add_theme_color_override("font_disabled_color", Color(0.48, 0.46, 0.42))
	return b


## 队列小牌的底色
func _chip_style() -> StyleBoxFlat:
	return Spec.inset_style(Color(0.135, 0.118, 0.094, 0.96), 4,
			Color(_warm.r, _warm.g, _warm.b, 0.28), 6.0, 0.0)


## 单位 id → 显示名（配置不在就退回 id 本身）
func _id_name(id: StringName) -> String:
	var d: UnitDef = _def_of_id(id)
	return d.display_name if d != null else String(id)
