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

var _title: Label = null
var _bullet: Control = null
var _tag: Label = null
var _rule: Control = null
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
var _cell_w: float = CELL_W
var _cell_h: float = CELL_H
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

	# --- 竖排数值（单选时出现）---
	_stats = RtsStatColumn.new()
	_stats.name = "数值"
	_stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_stats)

	# --- 多选清单 ---
	_grid_wrap = HBoxContainer.new()
	_grid_wrap.name = "网格位"
	_grid_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_grid_wrap)

	_grid = GridContainer.new()
	_grid.name = "网格"
	_grid.columns = MAX_COLS
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 4)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_grid_wrap.add_child(_grid)

	_empty = Spec.label("框选或点选单位后，这里列出队伍", Spec.FS_BODY, Spec.text_dim())
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_empty)


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
	var cs: Vector2 = _cell_size()
	_cell_h = cs.y
	# 面板给的宽度可能比"理想格宽"还窄（多列 / 小屏）：这时才把格子压下去。
	# ★ 反过来（先按窄面板算格宽、再拿格宽去算面板宽）会形成"越算越窄"的循环，
	#   1920 下就变成 53×72 的瘦条 —— 这是上一版的坑。
	var per: float = (w - 20.0 - float(maxi(_cols(), 1) - 1) * 6.0) / float(maxi(_cols(), 1))
	_cell_w = minf(cs.x, maxf(per, 40.0))
	_stats.set_row_height(clampf((h - HEAD_H - 10.0) / 3.0 - 4.0, 40.0, 62.0))
	custom_minimum_size = Vector2(w, maxf(h, _cell_h))
	for rec in _cells:
		var btn: Button = rec["btn"]
		if btn != null and is_instance_valid(btn):
			btn.custom_minimum_size = Vector2(_cell_w, _cell_h)


## 队伍格尺寸：**跟着底栏高度长**（1920 下底栏 246，格子写死 62×64 会显得又小又瘦），
## 再按可用宽度收一收（多列 / 小屏）。
func _cell_size() -> Vector2:
	var avail_h: float = maxf(_box_h - HEAD_H - 6.0 - 24.0, 80.0)
	var ch: float = clampf(avail_h * 0.5, 52.0, CELL_H + 16.0)
	var cw: float = clampf(ch * 0.94, 46.0, CELL_W + 14.0)
	return Vector2(cw, ch)


## 网格是不是空的（HUD 拿它决定中段要不要出现）
func is_empty() -> bool:
	return _units.is_empty()


## 内容需要多高（HUD 用它决定底栏高度）
func content_height() -> float:
	var head: float = HEAD_H + 10.0
	if _units.size() == 1:
		return head + 3.0 * 52.0 + 14.0
	var rows: int = maxi(1, mini(ROWS, ceili(float(_units.size()) / float(_cols()))))
	return head + float(rows) * (_cell_h + 4.0) + 12.0


## 内容想要多宽（HUD 据此给中段定宽，**不再一路铺到命令卡**）
func content_width() -> float:
	if _units.size() == 1:
		var want: float = 250.0
		if _title != null:
			want = maxf(want, _title.get_combined_minimum_size().x + 90.0)
		return clampf(want, 236.0, 340.0)
	if _units.is_empty():
		return 250.0
	var cs: Vector2 = _cell_size()
	return clampf(float(_cols()) * (cs.x + 6.0) + 22.0, 236.0, 660.0)


func _cols() -> int:
	if _units.size() <= 1:
		return 1
	return clampi(_units.size(), 1, MAX_COLS)


# ===========================================================================
# 刷新
# ===========================================================================

func refresh(units: Array) -> void:
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
		return
	_sig = sig
	_units = valid
	var pages: int = maxi(1, ceili(float(_units.size()) / float(PAGE_SIZE)))
	_page = clampi(_page, 0, pages - 1)
	_rebuild()
	_sync_hp()


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
		return
	if single:
		var d: UnitDef = (_units[0] as Node3D).def
		_title.text = d.display_name if d != null else "单位"
		_tag.text = Lex.kind_name(d)
		_feed_single(_units[0] as Node3D, d)
		return
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
	_tag.text = "混合编队" if nm2 == "" else ""
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
	btn.custom_minimum_size = Vector2(_cell_w, _cell_h)
	btn.focus_mode = Control.FOCUS_NONE
	btn.flat = true
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
	var unit_png: Texture2D = Spec.unit_icon(d.id) if d != null else null
	var icon := TextureRect.new()
	icon.name = "头像"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if unit_png != null:
		icon.texture = unit_png
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 2.0
		icon.offset_top = 2.0
		icon.offset_right = -2.0
		icon.offset_bottom = -18.0
		icon.modulate = Color(1, 1, 1, 1)
	else:
		var inset: float = maxf(_cell_w * 0.20, 4.0)
		icon.texture = Spec.icon_tex(_icon_for(d))
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = inset
		icon.offset_top = maxf(inset * 0.5, 2.0)
		icon.offset_right = -inset
		icon.offset_bottom = -maxf(_cell_h * 0.30, 16.0)
		icon.modulate = _tint_of(u)
	btn.add_child(icon)

	# 血量：**数字，不是进度条**（玩家口径："单位上面有进度条"）
	var hp := Label.new()
	hp.name = "血量"
	hp.text = ""
	hp.add_theme_font_size_override("font_size", Spec.FS_BODY)
	hp.add_theme_font_override("font", Spec.mono_font())
	hp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.92))
	hp.add_theme_constant_override("outline_size", 3)
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hp.offset_left = 1.0
	hp.offset_right = -1.0
	hp.offset_top = -17.0
	hp.offset_bottom = -1.0
	btn.add_child(hp)

	_cells.append({"btn": btn, "hp": hp, "icon": icon, "unit": u})
	return btn


## 血数字就地刷新（不重建格子，省节点）
func _sync_hp() -> void:
	for rec in _cells:
		var u: Node3D = rec.get("unit", null)
		var hp: Label = rec.get("hp", null)
		if u == null or not is_instance_valid(u) or hp == null:
			continue
		var d: UnitDef = u.def
		var total: float = d.max_hp if d != null and d.max_hp > 0.0 else 1.0
		var cur: float = float(u.get("hp"))
		var r: float = clampf(cur / total, 0.0, 1.0)
		var txt: String = "%d" % int(round(cur))
		if hp.text != txt:
			hp.text = txt
		var col: Color = Color(0.86, 0.90, 0.84)
		if r <= 0.30:
			col = Color(1.0, 0.48, 0.40)
		elif r <= 0.60:
			col = Color(1.0, 0.82, 0.44)
		hp.add_theme_color_override("font_color", col)


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
					"text": "%dm" % int(round(d.attack_range)), "tip": Lex.stat(d, "range")},
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
