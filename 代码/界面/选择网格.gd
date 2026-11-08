class_name RtsSelectionGrid
extends PanelContainer
## **底栏中段（单位）**：单选时是"大铭牌 + 竖排数值"，多选时是"队伍清单"。
##
## 2026-11-01 第五次改版（玩家口径原话）：
##   "中间的铭牌字体更大、更突出显眼些，下面的攻击、护甲和移动在铭牌后下方
##    竖着排列，把中间的位置空出来，好让两边不要被UI填满。"
##
##   ┌──────────────────────┐
##   │ ◆ 步 兵      近战     │  ← 铭牌：34px、象牙白、5px 黑边 + 左菱形引子
##   │ ═══════●═══════════  │  ← 金线（中间带菱形）
##   │  ⚔   15    攻击      │  ┐
##   │  🛡    5    护甲      │  ├ 三行**竖排**（RtsStatColumn，和建筑面板同一套）
##   │  👟  4.6    移速      │  ┘
##   └──────────────────────┘
##            ↑ 面板按内容收窄（~250px），右边大片战场留白
##
##   ┌───────────────────────────┐
##   │ ◆ 步兵 ×8         ‹ 1/2 › │  ← 多选：队伍清单 + 页码
##   │ [脸][脸][脸][脸]           │     每格 = 头像 + 血量数字（**没有进度条**）
##   └───────────────────────────┘
##
## 只读 Game 的选择集合，**不发起任何玩法行为**（点格子只是转给选择系统）。

const Spec := preload("res://代码/界面/界面规格.gd")
const Deco := preload("res://代码/界面/装饰.gd")
const Lex := preload("res://代码/界面/词条.gd")

## 多选清单：最多几列 × 几行（一页 16 个）
const MAX_COLS: int = 8
const ROWS: int = 2
const PAGE_SIZE: int = MAX_COLS * ROWS
## 格子尺寸
const CELL_W: float = 62.0
const CELL_H: float = 64.0
## 铭牌行高（34px 字 + 呼吸位）
const HEAD_H: float = 48.0

## 队伍格里那条 4px 的细进度（血 / 蓝）。自绘，比 Panel + ColorRect 省节点。
class MiniBar extends Control:
	var ratio: float = 1.0
	var fill: Color = Color(0.78, 0.26, 0.22)
	var _shown: float = -1.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_ratio(r: float) -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if absf(v - _shown) < 0.004:
			return
		_shown = v
		ratio = v
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 3.0 or r.size.y < 2.0:
			return
		draw_rect(r, Color(0.0, 0.0, 0.0, 0.62), true)
		var w: float = maxf((r.size.x - 1.0) * ratio, 0.0)
		if w > 0.3:
			draw_rect(Rect2(0.5, 0.5, w, r.size.y - 1.0), fill, true)


var _title: Label = null
var _bullet: Control = null
var _tag: Label = null
var _rule: Control = null
## 数值行左侧那条**竖版**经验条（单选一个兵时出现；2026-11-08）
var _exp: RtsExpBar = null
## 数值区的横排：左边竖版经验条 + 右边三行数值
var _body: HBoxContainer = null
var _page_box: HBoxContainer = null
var _page_prev: Button = null
var _page_next: Button = null
var _page_label: Label = null
var _grid: GridContainer = null
var _grid_wrap: HBoxContainer = null
var _empty: Label = null
var _root: VBoxContainer = null
## 竖排数值（与建筑面板共用同一个控件类）
var _stats: RtsStatColumn = null

var _cells: Array = []
var _units: Array = []
var _page: int = 0
var _sig: String = ""
var _built: bool = false
var selection_system: Node = null
var _accent: Color = Color(0.85, 0.71, 0.36)
var _box_w: float = 250.0
var _box_h: float = 190.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	# 段底由 HUD 的画框负责（一整条奇幻底板），这里只留内边距
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	add_theme_stylebox_override("panel", sb)
	ensure_built()


func ensure_built() -> void:
	if _built:
		return
	_built = true
	_accent = Spec.accent()
	_root = VBoxContainer.new()
	_root.name = "列"
	_root.add_theme_constant_override("separation", 2)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# --- 铭牌行：菱形 + 名字 + 定位小标 + 页码 ---
	var head := HBoxContainer.new()
	head.name = "铭牌"
	head.add_theme_constant_override("separation", 9)
	head.custom_minimum_size = Vector2(0.0, HEAD_H)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(head)

	_bullet = Deco.Diamond.new()
	_bullet.custom_minimum_size = Vector2(11.0, 11.0)
	_bullet.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_bullet)

	_title = Spec.label("未选中", Spec.FS_HERO_BIG, Color(1.0, 0.94, 0.76))
	_title.name = "名字"
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.custom_minimum_size = Vector2(72.0, 0.0)
	# ★ clip_text + 固定最小宽 ⇒ HBox 只给它 72px，"步兵 ×4" 会被截成"步兵"。
	#   让它自己吃满剩余宽度（页标靠右）。
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 铭牌要"更突出"：5px 黑边压在任何地表上都读得清，不必再铺深色底
	_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.90))
	_title.add_theme_constant_override("outline_size", 6)
	head.add_child(_title)

	_tag = Spec.label("", Spec.FS_BODY, Color(0.80, 0.74, 0.58))
	_tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tag.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_tag.add_theme_constant_override("outline_size", 3)
	head.add_child(_tag)

	_build_page_box(head)

	# --- 铭牌下沿那条金线（中间带菱形 = 这一版的"铭牌感"）---
	_rule = Deco.Rule.new()
	_rule.name = "金线"
	_rule.gem = true
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_rule)

	# --- 数值区：**左竖版经验条 + 右三行数值**（2026-11-08 玩家第三轮口径）---
	#   玩家原话：「不要放在信息面板外，是内嵌在信息面板、在显示单位近战或远程的
	#   下方，仍然是竖版经验条」——所以它是数值区里的一个 18px 竖槽，
	#   从金线下面一直拉到面板底部，和攻击/护甲/移速并排。
	_body = HBoxContainer.new()
	_body.name = "数值区"
	_body.add_theme_constant_override("separation", 10)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_body)

	_exp = RtsExpBar.new()
	_exp.visible = false
	_exp.custom_minimum_size = Vector2(RtsExpBar.W, 0.0)
	_exp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_exp)
	# 悬停：这一星多少经验 / 还差多少升级 / 下一星叫什么
	RtsTipLayer.bind(self, _exp, func() -> Dictionary:
		if _units.size() != 1:
			return {}
		return Lex.exp(_units[0] as Node3D))

	# --- 竖排数值（单选时出现）---
	_stats = RtsStatColumn.new()
	_stats.name = "数值"
	_stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(_stats)

	# --- 多选清单 ---
	_grid_wrap = HBoxContainer.new()
	_grid_wrap.name = "网格位"
	_grid_wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	_grid_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_grid_wrap)

	_grid = GridContainer.new()
	_grid.name = "网格"
	_grid.columns = MAX_COLS
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 4)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 网格自己**铺满**可用区域，格子再在里面均分 —— 不再靠外部算尺寸
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_wrap.add_child(_grid)

	_empty = Spec.label("框选或点选单位后，这里列出队伍", Spec.FS_BODY, Spec.text_dim())
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_empty)


## 经验条：**只对兵**显示（建筑没有星级），内嵌在数值区左侧。
##
## 玩家 2026-11-08：「内嵌在信息面板、在显示单位近战或远程的下方」「做宽些」
## 「仍然是竖版经验条」。所以它和攻击/护甲/移速排在同一行里，自己占一列。
func _sync_exp(u: Node3D, d: UnitDef) -> void:
	if _exp == null:
		return
	var is_unit: bool = d != null and d.kind == RtsConst.Kind.UNIT
	_exp.visible = is_unit
	if not is_unit:
		return
	var star: int = int(u.get("star_level")) if u.get("star_level") != null else 0
	var cur: float = float(u.get("exp_value")) if u.get("exp_value") != null else 0.0
	var need: float = float(u.call("exp_need")) if u.has_method("exp_need") else 60.0
	var r: float = 1.0 if star >= 3 else clampf((cur - float(star) * need) / maxf(need, 1.0), 0.0, 1.0)
	_exp.set_state(r, star, Spec.accent())


## 页码块："‹ 1 / 2 ›"（多于 16 个才出现；点箭头或滚轮翻页）
func _build_page_box(parent: Node) -> void:
	_page_box = HBoxContainer.new()
	_page_box.name = "页码"
	_page_box.add_theme_constant_override("separation", 2)
	_page_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_page_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_page_box)

	_page_prev = _nav_button("‹")
	_page_prev.pressed.connect(func() -> void: page_shift(-1))
	_page_box.add_child(_page_prev)

	_page_label = Spec.label("", Spec.FS_BODY, Spec.text_dim())
	_page_label.name = "页数"
	_page_label.custom_minimum_size = Vector2(46.0, 0.0)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_page_label.gui_input.connect(_on_page_label_input)
	_page_box.add_child(_page_label)

	_page_next = _nav_button("›")
	_page_next.pressed.connect(func() -> void: page_shift(1))
	_page_box.add_child(_page_next)

	RtsTipLayer.bind(self, _page_label, func() -> Dictionary:
		return {"icon": "clock", "icon_color": Spec.accent(), "title": "翻页",
				"tag": "队伍清单", "body": "一页最多 %d 个。点页码、点两侧箭头、或在清单上滚滚轮都能翻页。" % PAGE_SIZE,
				"foot": ""})


func _nav_button(txt: String) -> Button:
	var b := Button.new()
	b.text = txt
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(26.0, 26.0)
	b.add_theme_font_size_override("font_size", Spec.FS_VALUE)
	b.add_theme_color_override("font_color", Color(0.92, 0.86, 0.70))
	b.add_theme_stylebox_override("normal",
			Spec.button_style(Color(0.10, 0.11, 0.13, 0.92),
					Color(_accent.r, _accent.g, _accent.b, 0.38), null, 4, 2.0, 0.0))
	b.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.18, 0.19, 0.22, 0.96),
					_accent, null, 4, 2.0, 0.0))
	b.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.24, 0.20, 0.10, 0.96),
					_accent, null, 4, 2.0, 0.0))
	return b


# ===========================================================================
# 尺寸
# ===========================================================================

## 尺寸由 HUD 灌进来（宽度决定格子大小，高度只做下限）
func set_metrics(w: float, h: float, _compact: bool = false) -> void:
	if w < 60.0:
		return
	_box_w = w
	_box_h = h
	# 面板内高 = 传入高度 - stylebox 上下留白（6+6）
	# 再扣掉：牌头 48 + 金线 11 + 两处 2px 间隙 = 63
	var inner: float = maxf(h - 12.0, 120.0)
	var body: float = inner - HEAD_H - 11.0 - 4.0
	if _units.size() == 1:
		_stats.set_row_height(clampf(body / 3.0 - 3.0, 36.0, 60.0))
	# ★ 队伍格**不在这里算尺寸**：格子的最小尺寸固定成一个很小的值，
	#   由 GridContainer + EXPAND_FILL 把它们拉满可用区域。
	#   以前按"可用高 ÷ 行数"反推格高，格子再把最小高顶回 VBox，
	#   形成 内容→最小尺寸→面板→内容 的自激，第二排直接掉出底栏。
	custom_minimum_size = Vector2(w, h)


## 网格是不是空的（HUD 拿它决定中段要不要出现）
func is_empty() -> bool:
	return _units.is_empty()


## 内容需要多高 —— **常数**。
## 面板里的行高/格高都是由"底栏内高"反推的，再把它算回内容高就会自激
## （内容更高 → 底栏更高 → 格子更高 → 内容更高，一路上涨到上限）。
const CONTENT_H := 224.0
func content_height() -> float:
	return CONTENT_H


## 内容想要多宽（HUD 据此给中段定宽，**不再一路铺到命令卡**）
func content_width() -> float:
	if _units.size() == 1:
		# 250 是"三行数值 + 名字"的旧宽度；经验条内嵌后要给它留一列（18 + 10 间距）
		var want: float = 278.0
		if _title != null:
			want = maxf(want, _title.get_combined_minimum_size().x + 118.0)
		return clampf(want, 264.0, 360.0)
	# 多选时中段是"一路贴到命令卡"的，这里给个下限值就行
	return 250.0


func _cols() -> int:
	if _units.size() <= 1:
		return 1
	return clampi(_units.size(), 1, MAX_COLS)


# ===========================================================================
# 刷新
# ===========================================================================

## 返回 true 表示"内容结构变了、重建过"——HUD 收到 true 必须重摆一次：
## 格子尺寸是按 set_metrics 里的高度算的，重建时若还用着上一次的尺寸，
## 网格会撑到面板外面（第二排直接掉出底栏）。
func refresh(units: Array) -> bool:
	var valid: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not bool(u.call("is_alive")):
			continue
		valid.append(u)
	var sig := str(valid.size())
	for u in valid:
		sig += "|%d" % u.get_instance_id()
	if sig == _sig:
		_sync_hp()
		return false
	_sig = sig
	_units = valid
	var pages: int = maxi(1, ceili(float(_units.size()) / float(PAGE_SIZE)))
	_page = clampi(_page, 0, pages - 1)
	_rebuild()
	_sync_hp()
	return true


func _rebuild() -> void:
	ensure_built()
	for rec in _cells:
		var btn: Button = rec["btn"]
		if btn != null and is_instance_valid(btn):
			btn.queue_free()
	_cells.clear()
	var pages: int = maxi(1, ceili(float(_units.size()) / float(PAGE_SIZE)))
	var single: bool = _units.size() == 1
	_empty.visible = _units.is_empty()
	# 单选：不出清单，只出数值；多选：出清单
	_grid_wrap.visible = not _units.is_empty() and not single
	_stats.visible = single
	_rule.visible = not _units.is_empty()
	_bullet.visible = not _units.is_empty()
	_page_box.visible = pages > 1
	_page_label.text = "%d / %d" % [_page + 1, pages]
	_grid.columns = maxi(_cols(), 1)
	if _units.is_empty():
		_title.text = "未选中"
		_tag.text = ""
		_stats.clear()
		if _exp != null:
			_exp.visible = false
		return
	if single:
		var d: UnitDef = (_units[0] as Node3D).def
		_title.text = d.display_name if d != null else "单位"
		# ★ 2026-11-08 玩家口径：「做完后把近战远程这种字眼删除」。
		#   兵的定位词（近战/远程/采集/辅助）在这一版信息面板里不再出现；
		#   建筑仍留一个"建筑"当分类提示（不是被点名的字眼）。
		_tag.text = "建筑" if (d != null and d.is_building()) else ""
		_tag.visible = not _tag.text.is_empty()
		_feed_single(_units[0] as Node3D, d)
		_sync_exp(_units[0] as Node3D, d)
		return
	if _exp != null:
		_exp.visible = false
	var same_id: StringName = &""
	var same: bool = true
	for u in _units:
		var ud: UnitDef = (u as Node3D).def if u is Node3D else null
		var uid: StringName = ud.id if ud != null else &""
		if same_id == &"":
			same_id = uid
		elif uid != same_id:
			same = false
			break
	var nm2: String = ""
	if same and same_id != &"":
		var d0: UnitDef = Cfg.unit(same_id) if Cfg.game != null else null
		nm2 = d0.display_name if d0 != null else String(same_id)
	_title.text = ("%s ×%d" % [nm2, _units.size()]) if nm2 != "" else "部队 %d" % _units.size()
	# 玩家口径：**不要"混合编队"这四个字**（挤在铭牌右端，纯噪音）
	_tag.text = ""
	var from: int = _page * PAGE_SIZE
	var to: int = mini(_units.size(), from + PAGE_SIZE)
	for i in range(from, to):
		_grid.add_child(_make_cell(_units[i], i))


## 单选：三行竖排数值 + 每行一条弹窗
func _feed_single(u: Node3D, d: UnitDef) -> void:
	_stats.feed(_stats_of(d))
	_stats.set_row_height(clampf((_box_h - HEAD_H - 10.0) / 3.0 - 4.0, 40.0, 62.0))


func _make_cell(u: Node3D, idx: int) -> Button:
	var btn := Button.new()
	btn.name = "格_%d" % u.get_instance_id()
	btn.custom_minimum_size = Vector2(CELL_W, CELL_H)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE
	# ★ 不能 flat：flat 会把 normal/hover/pressed 三张 stylebox 全吃掉，
	#   格子就变成"浮在面板上的图标+数字"，完全读不出"格"。
	btn.flat = false
	var d: UnitDef = u.def
	btn.add_theme_stylebox_override("normal",
			Spec.inset_style(Color(0.075, 0.084, 0.100, 0.96), 5,
				Color(_accent.r, _accent.g, _accent.b, 0.30), 0, 0))
	btn.add_theme_stylebox_override("hover",
			Spec.inset_style(Color(0.130, 0.140, 0.164, 0.98), 5,
				_accent, 0, 0))
	btn.add_theme_stylebox_override("pressed",
			Spec.inset_style(Color(0.060, 0.068, 0.084, 0.98), 5,
				_accent, 0, 0))
	var captured: Node3D = u
	btn.pressed.connect(func() -> void: _pick(captured))
	var cell_idx: int = idx
	RtsTipLayer.bind(self, btn, func() -> Dictionary: return Lex.cell(captured, cell_idx))

	# ★ 图标：优先用 **Blender 渲的单位头像 PNG**（魔兽那种"一张脸"），
	#   没有渲图才退回线描 SVG（刀/弓/法杖）—— 后者远看只是一个符号，认不出兵种。
	#   下半截留给「x / x」+ 血条 + 蓝条（玩家口径：数字和两条进度都要）。
	const FOOT_H := 30.0
	var unit_png: Texture2D = Spec.unit_icon(d.id) if d != null else null
	var icon := TextureRect.new()
	icon.name = "头像"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	if unit_png != null:
		icon.texture = unit_png
		icon.offset_left = 2.0
		icon.offset_top = 2.0
		icon.offset_right = -2.0
		icon.offset_bottom = -FOOT_H
		icon.modulate = Color(1, 1, 1, 1)
	else:
		var inset: float = maxf(CELL_W * 0.20, 4.0)
		icon.texture = Spec.icon_tex(_icon_for(d))
		icon.offset_left = inset
		icon.offset_top = maxf(inset * 0.5, 2.0)
		icon.offset_right = -inset
		icon.offset_bottom = -FOOT_H - 2.0
		icon.modulate = _tint_of(u)
	btn.add_child(icon)

	# 血量文字：**x / x**（不是单个数），一行读完不用心算
	var hp := Label.new()
	hp.name = "血量"
	hp.text = ""
	hp.add_theme_font_size_override("font_size", Spec.FS_CAPTION)
	hp.add_theme_font_override("font", Spec.mono_font())
	hp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.92))
	hp.add_theme_constant_override("outline_size", 3)
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hp.offset_left = 1.0
	hp.offset_right = -1.0
	hp.offset_top = -FOOT_H
	hp.offset_bottom = -FOOT_H + 14.0
	btn.add_child(hp)

	# 两条细进度：血（红/黄随比例）+ 蓝（有法力才出现）
	var bar_hp := MiniBar.new()
	bar_hp.name = "血条"
	bar_hp.fill = Color(0.78, 0.26, 0.22)
	bar_hp.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar_hp.offset_left = 3.0
	bar_hp.offset_right = -3.0
	bar_hp.offset_top = -14.0
	bar_hp.offset_bottom = -10.0
	btn.add_child(bar_hp)

	var bar_mp := MiniBar.new()
	bar_mp.name = "蓝条"
	bar_mp.fill = Color(0.34, 0.62, 0.98)
	bar_mp.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar_mp.offset_left = 3.0
	bar_mp.offset_right = -3.0
	bar_mp.offset_top = -8.0
	bar_mp.offset_bottom = -4.0
	bar_mp.visible = bool(u.call("has_mana")) if u.has_method("has_mana") else false
	btn.add_child(bar_mp)

	_cells.append({"btn": btn, "hp": hp, "icon": icon, "unit": u,
			"bar_hp": bar_hp, "bar_mp": bar_mp})
	return btn


## 血量数字 + 血条/蓝条就地刷新（不重建格子，省节点）
func _sync_hp() -> void:
	for rec in _cells:
		var u: Node3D = rec.get("unit", null)
		var hp: Label = rec.get("hp", null)
		if u == null or not is_instance_valid(u) or hp == null:
			continue
		var d: UnitDef = u.def
		# 星级会抬高生命上限（老兵 +20% / 精英 +40% / 王牌 +100%）
		var total: float = float(u.call("max_hp")) if u.has_method("max_hp") else \
				(d.max_hp if d != null and d.max_hp > 0.0 else 1.0)
		var cur: float = float(u.get("hp"))
		var r: float = clampf(cur / total, 0.0, 1.0)
		var txt: String = "%d/%d" % [int(round(cur)), int(round(total))]
		# 有星级的单位在血量前加星号（底栏格子太小，画不下三颗星）
		var st: Variant = u.get("star_level")
		if st != null and int(st) > 0:
			txt = "★%d %s" % [int(st), txt]
		if hp.text != txt:
			hp.text = txt
		var col: Color = Color(0.90, 0.92, 0.86)
		if r <= 0.30:
			col = Color(1.0, 0.52, 0.44)
		elif r <= 0.60:
			col = Color(1.0, 0.84, 0.46)
		hp.add_theme_color_override("font_color", col)
		var bh: MiniBar = rec.get("bar_hp", null)
		if bh != null:
			bh.fill = Color(0.80, 0.26, 0.22) if r <= 0.3 else \
					(Color(0.92, 0.68, 0.24) if r <= 0.6 else Color(0.44, 0.80, 0.40))
			bh.set_ratio(r)
		var bm: MiniBar = rec.get("bar_mp", null)
		if bm != null:
			var has_m: bool = bool(u.call("has_mana")) if u.has_method("has_mana") else false
			if bm.visible != has_m:
				bm.visible = has_m
			if has_m:
				var mmax: float = float(u.call("max_mana"))
				var mcur: float = float(u.get("mana"))
				bm.set_ratio(mcur / maxf(mmax, 1.0))


## 兵种/建筑 → 三项数值 + 三项弹窗。
## 单位：攻击 / 护甲 / 移速；
## **能攻击的建筑：攻击 / 射程 / 视野**；不能攻击的建筑：护甲 / 视野 /（人口或耗时）。
func _stats_of(d: UnitDef) -> Array:
	if d == null:
		return []
	if d.is_building():
		if d.can_attack():
			return [
				{"icon": "sword", "name": "攻击", "color": Color(0.98, 0.62, 0.42),
					"text": _fmt(d.attack_damage), "tip": Lex.stat(d, "attack")},
				{"icon": "bow", "name": "射程", "color": Color(0.86, 0.80, 0.52),
					"text": _fmt(d.attack_range_value), "tip": Lex.stat(d, "range")},
				{"icon": "eye", "name": "视野", "color": Color(0.66, 0.86, 0.92),
					"text": "%dm" % int(round(d.sight_range)), "tip": Lex.stat(d, "sight")},
			]
		var out: Array = [
			{"icon": "shield", "name": "护甲", "color": Color(0.62, 0.78, 0.98),
				"text": _fmt(d.armor), "tip": Lex.stat(d, "armor")},
			{"icon": "eye", "name": "视野", "color": Color(0.66, 0.86, 0.92),
				"text": "%dm" % int(round(d.sight_range)), "tip": Lex.stat(d, "sight")},
		]
		if d.food_provided > 0:
			out.append({"icon": "house", "name": "人口", "color": Color(0.80, 0.88, 0.66),
				"text": "+%d" % d.food_provided, "tip": Lex.stat(d, "pop")})
		elif d.detect_radius > 0.0:
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
	return [
		{"icon": "sword", "name": "攻击", "color": Color(0.98, 0.62, 0.42),
			"text": _fmt(d.attack_damage) if d.attack_damage > 0.0 else "—",
			"tip": Lex.stat(d, "attack")},
		{"icon": "shield", "name": "护甲", "color": Color(0.62, 0.78, 0.98),
			"text": _fmt(d.armor), "tip": Lex.stat(d, "armor")},
		{"icon": "move", "name": "移速", "color": Color(0.72, 0.88, 0.56),
			"text": _fmt(d.move_speed), "tip": Lex.stat(d, "speed")},
	]


func _fmt(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


## 点铭牌也能看到说明（"这支部队是什么"）
func _pick(u: Node3D) -> void:
	if selection_system != null and selection_system.has_method("select_units"):
		selection_system.call("select_units", [u])
		return
	for x in Game.all_units():
		if x is RtsUnit:
			(x as RtsUnit).is_selected = x == u
	Game.selection_changed.emit([u])


func _icon_for(d: UnitDef) -> String:
	if d == null:
		return "shield"
	match String(d.id):
		"peasant":
			return "hammer"
		"footman":
			return "sword"
		"archer":
			return "bow"
		"mage":
			return "staff"
		"steam_guard":
			return "anvil"
		"townhall":
			return "flag"
		"farm":
			return "house"
		"barracks", "tower":
			return "tower"
		"watchtower":
			return "eye"
		"blacksmith":
			return "anvil"
		"sanctum":
			return "staff"
		"workshop":
			return "gear"
		"lumbercamp":
			return "wood"
	return "shield"


## 头像按**队伍色**染一下（只有线描图标需要；PNG 头像保持原色）
func _tint_of(u: Node3D) -> Color:
	var f: RtsFaction = u.faction
	if f == null:
		return Color(1, 1, 1, 1)
	var c: Color = f.color
	return Color(lerpf(1.0, c.r, 0.35), lerpf(1.0, c.g, 0.35), lerpf(1.0, c.b, 0.35), 1.0)


## 点页码翻页
func _on_page_label_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		page_shift(1)
		accept_event()


## 翻页（滚轮 / 点页码 / 点箭头）
func page_shift(delta: int) -> void:
	var pages: int = maxi(1, ceili(float(_units.size()) / float(PAGE_SIZE)))
	if pages <= 1:
		return
	_page = posmod(_page + delta, pages)
	_sig = ""      # 强制重建
	refresh(_units)


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		page_shift(-1)
		accept_event()
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		page_shift(1)
		accept_event()
