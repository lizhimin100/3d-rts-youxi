class_name RtsBuildingPanel
extends PanelContainer
## **建筑面板（中段）** —— 选中单个建筑时，占据底栏**中间那一段**。
##
## 2026-10-31 三次改版（玩家口径）：
##   "建筑的下面 UI 也要和单位统一，训练队列和训练进度条等信息放到中间
##    （没有训练单位就显示建筑护甲），技能统一放右边 UI"
##
## 于是三段的分工变成：
##   左（RtsDossierPanel）：**头像 + 血条/法力条** —— 和单位完全同一张卡；
##   中（本文件）      ：训练队列 / 训练进度 / 研究进度 / 建造进度；
##                        这栋楼不产兵时改显示 护甲 / 视野 / 人口；
##   右（RtsCommandCard）：**所有能点的东西** —— 训练、研究、集结点、停止。
##
## 三条纪律：
##   1. 进度条由本面板自己 `_process` 每帧刷（HUD 的 0.12s 节流会让秒数一跳一跳）；
##   2. 数值/颜色只从 GameConfig 与建筑自身读，界面里不发明规则；
##   3. 训练/研究只**显示**状态，不在这里放按钮（按钮全在命令卡，避免两处入口）。

const Spec := preload("res://代码/界面/界面规格.gd")

## 最小高度
const H_MIN := 120.0
## 训练队列最多显示几项（与指令系统的训练上限一致）
const QUEUE_MAX := 5
## 当前训练条高度
const BAR_H := 26.0
## 队列格高度（图标 + 自己那条进度）
const CHIP_H := 46.0


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
		mouse_filter = Control.MOUSE_FILTER_IGNORE
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
## 暖色主色（比单位面板的金色更橙、更"工地"）
var _warm: Color = Color(0.97, 0.64, 0.26)
var _warn: Color = Color(1.0, 0.36, 0.28)
var _mono: Font = null
var _built: bool = false
## 已经为哪个 def 建过内容（换建筑类型时才重建）
var _built_def: StringName = &""
var _panel_w: float = 520.0
var _compact: bool = false

var _root: VBoxContainer = null

# --- 标题（建筑名 + 状态尾巴）---
var _head_row: HBoxContainer = null
var _name_label: Label = null
var _head_hint: Label = null

# --- 训练 ---
var _train_box: VBoxContainer = null
var _train_cap: Label = null
var _queue_count: Label = null
var _rest_label: Label = null
var _train_bar: Bar = null
var _queue_row: HBoxContainer = null
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

# --- 属性（不产兵的楼）---
var _stats_box: HBoxContainer = null
var _stat_labels: Array[Label] = []
## 数字下面的中文小标（护甲 / 视野 / 人口 …）
var _stat_caps: Array[Label] = []
var _stat_icons: Array[Control] = []
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
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(_panel_w, H_MIN)
	# 和左卡/命令卡同一套段底（"一条带子的三段"）
	add_theme_stylebox_override("panel", Spec.segment_style(
			Color(0.092, 0.084, 0.070, 0.93), 8, 8.0, 0.13))

	_root = VBoxContainer.new()
	_root.name = "纵"
	_root.add_theme_constant_override("separation", 4)
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
	# 高度下限用调用方给的实测值，**不要** reset_size()（会把 HUD 摆好的 offset 覆盖）
	custom_minimum_size = Vector2(_panel_w, maxf(H_MIN, h_single))


# ---------------------------------------------------------------------------
# 标题行：**这栋楼叫什么**
#
# 单位面板的标题行写"步兵"，建筑面板以前没有这一行 ——
# 三点几秒的队列在眼前刷，玩家却不知道自己在看哪栋楼（尤其图标小的时候）。
# 右边那个小字是状态尾巴（"待训练 / 队列 2/5 / 建造中 40%"）。
# ---------------------------------------------------------------------------
func _build_head(parent: Node) -> void:
	_head_row = HBoxContainer.new()
	_head_row.name = "标题"
	_head_row.add_theme_constant_override("separation", 8)
	_head_row.custom_minimum_size = Vector2(0.0, 26.0)
	_head_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_head_row)

	_name_label = Spec.label("建筑", Spec.FS_TITLE, Spec.text_main())
	_name_label.clip_text = true
	# ★ clip_text=true 会把最小宽度压成 0 —— 必须给一个下限，
	#   否则 HBox 里的弹性留白把名字挤成 0 宽（第一版就是这样"名字看不见"）。
	_name_label.custom_minimum_size = Vector2(84.0, 0.0)
	# 同上：clip_text 会把宽度压到最小宽，"神秘圣地" 这种四字名会被截掉最后一个字。
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head_row.add_child(_name_label)

	_head_hint = Spec.label("", Spec.FS_BODY, Spec.text_dim())
	_head_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head_row.add_child(_head_hint)


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

	_build_cap = Spec.label("建造中 0%", Spec.FS_BODY, Color(0.99, 0.80, 0.44))
	_build_box.add_child(_build_cap)

	_build_bar = Bar.new()
	_build_bar.custom_minimum_size = Vector2(0.0, 16.0)
	_build_bar.fill = Color(0.96, 0.72, 0.30)
	_build_box.add_child(_build_bar)


# ---------------------------------------------------------------------------
# 训练队列（这栋楼能产兵时出现）
# ---------------------------------------------------------------------------
func _build_training(parent: Node) -> void:
	_train_box = VBoxContainer.new()
	_train_box.name = "训练区"
	_train_box.add_theme_constant_override("separation", 4)
	_train_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_train_box)

	# 标题行：训练 · 剩余时间 · 队列 n/5
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.custom_minimum_size = Vector2(0.0, 22.0)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_train_box.add_child(head)

	_train_cap = Spec.label("训练", Spec.FS_BODY, Color(_warm.r, _warm.g, _warm.b, 0.98))
	head.add_child(_train_cap)

	_rest_label = Spec.label("待训练", Spec.FS_VALUE, Color(0.90, 0.88, 0.80))
	_rest_label.add_theme_font_override("font", _mono)
	_rest_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_rest_label)

	_queue_count = Spec.label("队列 0 / %d" % QUEUE_MAX, Spec.FS_BODY, Color(0.80, 0.74, 0.62))
	head.add_child(_queue_count)

	# 当前训练的大进度条（带"步兵 40%"）
	_train_bar = Bar.new()
	_train_bar.name = "训练进度"
	_train_bar.custom_minimum_size = Vector2(0.0, BAR_H)
	_train_bar._fs = Spec.FS_VALUE
	_train_bar.fill = Color(0.44, 0.76, 0.98)
	_train_box.add_child(_train_bar)

	# 队列：每格一张小牌（图标 + 自己的进度条）
	_queue_row = HBoxContainer.new()
	_queue_row.name = "队列"
	_queue_row.add_theme_constant_override("separation", 6)
	_queue_row.custom_minimum_size = Vector2(0.0, CHIP_H)
	_queue_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_train_box.add_child(_queue_row)
	for i in QUEUE_MAX:
		var chip := PanelContainer.new()
		chip.name = "队列项%d" % (i + 1)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.visible = false
		# 定宽不拉伸：只排 1~2 个兵时，EXPAND 会把两格拉成两条长跑道；
		# 固定 68 宽 + 末尾留白，5 格时仍然是"一排小牌"的观感。
		chip.custom_minimum_size = Vector2(76.0, CHIP_H)
		chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		chip.add_theme_stylebox_override("panel",
				Spec.inset_style(Color(0.135, 0.118, 0.094, 0.96), 4,
						Color(_warm.r, _warm.g, _warm.b, 0.30), 5.0, 0.0))
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(vb)
		var ico := TextureRect.new()
		ico.name = "头像"
		ico.custom_minimum_size = Vector2(26.0, 26.0)
		ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(ico)
		var bar := Bar.new()
		bar.name = "进度"
		bar.custom_minimum_size = Vector2(0.0, 5.0)
		bar.fill = Color(0.44, 0.76, 0.98)
		vb.add_child(bar)
		_queue_row.add_child(chip)
		_queue_chips.append(chip)
		_queue_icons.append(ico)
		_queue_bars.append(bar)
	var tail := Control.new()
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_queue_row.add_child(tail)


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

	_research_cap = Spec.label("研究", Spec.FS_BODY, Color(0.72, 0.86, 1.0))
	_research_box.add_child(_research_cap)

	_research_bar = Bar.new()
	_research_bar.name = "研究进度"
	_research_bar.custom_minimum_size = Vector2(0.0, 18.0)
	_research_bar.fill = Color(0.72, 0.86, 1.0)
	_research_box.add_child(_research_bar)


# ---------------------------------------------------------------------------
# 属性（不产兵的楼：护甲 / 视野 / 人口或建造耗时）
# ---------------------------------------------------------------------------
func _build_stats(parent: Node) -> void:
	_stats_box = HBoxContainer.new()
	_stats_box.name = "属性"
	_stats_box.add_theme_constant_override("separation", 8)
	# 竖向撑满：底栏比内容高，让铭牌吃掉多余高度，别在下面留一条空带
	_stats_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_stats_box)

	for i in 3:
		var chip := PanelContainer.new()
		chip.name = "属性%d" % i
		chip.custom_minimum_size = Vector2(120.0, 52.0)
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.size_flags_vertical = Control.SIZE_EXPAND_FILL
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_theme_stylebox_override("panel",
				Spec.bevel_style(Color(0.070, 0.078, 0.096, 0.96), Color(0, 0, 0, 0), 5,
						10.0, 0.0, 0.10))
		_stats_box.add_child(chip)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(row)

		var ic := Spec.icon("shield", 26.0, Color(0.62, 0.78, 0.98))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ic)
		_stat_icons.append(ic)

		# 数字 + 中文小标（"护甲 / 视野 / 人口"）——和单位那三块同一种铭牌
		var colv := VBoxContainer.new()
		colv.add_theme_constant_override("separation", -2)
		colv.alignment = BoxContainer.ALIGNMENT_CENTER
		colv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(colv)

		var v := Spec.label("-", Spec.FS_HERO, Color(0.96, 0.92, 0.79))
		v.add_theme_font_override("font", _mono)
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		colv.add_child(v)
		_stat_labels.append(v)

		var cap := Spec.label("", Spec.FS_CAPTION, Spec.text_dim())
		cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		colv.add_child(cap)
		_stat_caps.append(cap)


# ===========================================================================
# 对外接口
# ===========================================================================

func desired_height() -> float:
	ensure_built()
	return maxf(get_combined_minimum_size().y, H_MIN)


func content_height() -> float:
	ensure_built()
	# +24 = 段底 stylebox 上下各 8 + 一点余量。
	# 以前只加 20，训练视图（标题 26 + 训练行 22 + 大条 26 + 队列牌 46 + 间距）刚好差 2px，
	# 结果队列小牌的下沿被面板裁掉一条 —— 看着像"卡在边线上"。
	var need: float = _root.get_combined_minimum_size().y + 24.0
	return clampf(need, 118.0, 200.0)


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
	_name_label.text = d.display_name if d != null else "建筑"
	# 训练区 / 属性块的显隐**每帧按队列状态**决定，见 _sync_mode()：
	#   有活干 = 队列非空或在训练 → 队列视图；
	#   闲着（或这栋楼根本不产兵）→ 三个大数值（护甲/视野/人口），
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
## 玩家口径原话："训练队列和训练进度条等信息放到中间（没有训练单位就显示建筑护甲）"。
func _sync_mode() -> void:
	var d: UnitDef = _target.def if _target != null and is_instance_valid(_target) else null
	var can_train: bool = d != null and not d.trains.is_empty()
	var busy: bool = false
	if can_train and _target != null:
		busy = not _target.train_queue.is_empty() or _target.current_training() != &""
	if _train_box.visible != (can_train and busy):
		_train_box.visible = can_train and busy
	if _stats_box.visible != (d != null and not (can_train and busy)):
		_stats_box.visible = d != null and not (can_train and busy)
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
		_train_bar.visible = false
		_rest_label.text = "待训练"
	else:
		_train_bar.visible = true
		var p: float = clampf(_target.train_progress, 0.0, 1.0)
		var ud: UnitDef = _def_of_id(cur)
		var total: float = ud.train_time if ud != null else 0.0
		var rest: float = maxf(1.0 - p, 0.0) * total
		var nm: String = ud.display_name if ud != null else String(cur)
		_train_bar.feed(p, Color(0.44, 0.76, 0.98), "%s　%d%%" % [nm, int(round(p * 100.0))])
		_rest_label.text = "剩余 %.1fs" % rest

	# 队列格：队首那格带真实进度，后排只表示"排到了"
	for i in _queue_chips.size():
		if i < queue_n:
			var id: StringName = _target.train_queue[i]
			var ud2: UnitDef = _def_of_id(id)
			_queue_icons[i].texture = Spec.unit_icon(id) if Spec.unit_icon(id) != null \
					else Spec.icon_tex(_unit_icon(id))
			_queue_icons[i].modulate = Color(1, 1, 1, 1) if i == 0 else Color(0.78, 0.78, 0.74)
			_queue_icons[i].tooltip_text = ud2.display_name if ud2 != null else String(id)
			var bar: Bar = _queue_bars[i]
			bar.feed(clampf(_target.train_progress, 0.0, 1.0) if i == 0 else 0.0,
					Color(0.44, 0.76, 0.98), "")
			_queue_chips[i].visible = true
		else:
			_queue_chips[i].visible = false
	_queue_row.visible = queue_n > 0


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
	if not _stats_box.visible or d == null:
		return
	var sig: String = String(d.id)
	if sig == _stats_sig:
		return
	_stats_sig = sig
	var stats: Array = _stats_of(d)
	for i in _stat_labels.size():
		if i >= stats.size():
			_stat_labels[i].text = "—"
			continue
		var s: Dictionary = stats[i]
		Spec.set_icon(_stat_icons[i], String(s.get("icon", "shield")),
				s.get("color", Color(0.62, 0.78, 0.98)))
		_stat_labels[i].text = String(s.get("text", "-"))
		_stat_labels[i].add_theme_color_override("font_color",
				(s.get("color", Color(0.9, 0.88, 0.8)) as Color).lerp(Color(1, 1, 1), 0.55))
		if i < _stat_caps.size():
			_stat_caps[i].text = String(s.get("name", ""))


## 建筑属性三项：护甲 / 视野 /（人口 → 攻击 → 可研究 → 可训练 → 建造耗时）
##
## 第三格以前写死"建造耗时"，一栋早就盖好的兵营还在报 "25s"，
## 等于占着最显眼的位置说废话。现在按"这栋楼到底能干什么"往下滑。
func _stats_of(d: UnitDef) -> Array:
	var out: Array = [
		{"icon": "shield", "name": "护甲", "color": Color(0.62, 0.78, 0.98),
			"text": _num(d.armor), "tip": "护甲"},
		{"icon": "eye", "name": "视野", "color": Color(0.66, 0.86, 0.92),
			"text": "%dm" % int(round(d.sight_range)), "tip": "视野"},
	]
	if d.food_provided > 0:
		out.append({"icon": "house", "name": "人口", "color": Color(0.80, 0.88, 0.66),
			"text": "+%d" % d.food_provided, "tip": "提供人口上限"})
	elif d.can_attack():
		out.append({"icon": "sword", "name": "攻击", "color": Color(0.98, 0.62, 0.42),
			"text": "%s / %.1fs" % [_num(d.attack_damage), d.attack_cooldown],
			"tip": "攻击力 / 射击间隔"})
	elif d.detect_radius > 0.0:
		# 哨塔：不能打，但敌人一进这个圈就报点
		out.append({"icon": "eye", "name": "预警", "color": Color(0.98, 0.78, 0.52),
			"text": "%dm" % int(round(d.detect_radius)), "tip": "敌人进入这个范围会报点"})
	elif not d.researches.is_empty():
		out.append({"icon": "upgrade", "name": "可研究", "color": Color(0.86, 0.78, 1.0),
			"text": "%d 项" % d.researches.size(), "tip": "这栋楼能研究 %d 项科技" % d.researches.size()})
	elif not d.trains.is_empty():
		out.append({"icon": "gear", "name": "可训练", "color": Color(0.80, 0.80, 0.76),
			"text": "%d 种" % d.trains.size(), "tip": "这栋楼能训练 %d 种单位" % d.trains.size()})
	else:
		out.append({"icon": "gear", "name": "建造", "color": Color(0.80, 0.80, 0.76),
			"text": "%ds" % int(round(d.train_time)), "tip": "建造耗时"})
	return out


func _num(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


func _show_idle() -> void:
	if not _built:
		return
	_head_row.visible = false
	_build_box.visible = false
	_train_box.visible = false
	_research_box.visible = false
	_stats_box.visible = false


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
