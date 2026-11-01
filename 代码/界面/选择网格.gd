class_name RtsSelectionGrid
extends PanelContainer
## **底栏中段**：单选时是"数值面板"，多选时是"队伍清单"。
##
## 2026-10-31 三次改版（玩家口径原话）：
##   · "中间的面板，单个单位就不需要显示图标（而且图标也不对，图标应该是类似
##      魔兽争霸那种单位图标），只显示攻击、防御、移动等信息，且这些信息要放大、更显眼"；
##   · 图标换成 **Blender 渲出来的单位头像 PNG**（`美术/图标/单位/<id>.png`），
##     和建筑图标同一套做法，不再是线描的刀/弓/靴。
##
## 所以这块现在有两种形态：
##   ┌────────────────────────────────────────────┐
##   │ 步兵                              1 / 1 页 │  ← 单选：名字 + 页码
##   │ ┌──────────┬──────────┬──────────┐         │
##   │ │ ⚔   15   │ 🛡   5    │ 👟  4.6  │         │  ← 大号数值（28px）
##   │ └──────────┴──────────┴──────────┘         │
##   └────────────────────────────────────────────┘
##   ┌────────────────────────────────────────────┐
##   │ 队伍 8                            1 / 1 页 │  ← 多选：队伍清单
##   │ [头像][头像][头像][头像][头像][头像] …      │  ← 魔兽式单位图标
##   └────────────────────────────────────────────┘
##
## 只读 Game 的选择集合，**不发起任何玩法行为**（点格子只是转给选择系统）。

const Spec := preload("res://代码/界面/界面规格.gd")

## 列数 × 行数 = 一页 24 个（参考图的上限）。
const COLS: int = 12
const ROWS: int = 2
const PAGE_SIZE: int = 24
## 数值铭牌高度（大号：图标 26 + 数字 28px）
## 数值铭牌高度：28px 数字 + 12px 中文小标（"攻击 / 护甲 / 移速"）。
## 光有图标 + 数字，第一次玩的人得靠猜；加一行小标就一眼读得懂，
## 数字本身仍然是 28px —— 显眼和好读不冲突。
const STAT_H: float = 72.0
## 标题行高度
const HEAD_H: float = 26.0

var _title: Label = null
var _page_label: Label = null
var _grid: GridContainer = null
var _empty: Label = null
var _root: VBoxContainer = null
## 数值（单选）
var _stats_box: HBoxContainer = null
var _stat_chips: Array[PanelContainer] = []
var _stat_icons: Array[Control] = []
var _stat_vals: Array[Label] = []
## 数字下面的中文小标（攻击 / 护甲 / 移速 …）
var _stat_caps: Array[Label] = []
var _stats_sig: String = ""

## 当前页面里的格子
var _cells: Array = []
var _units: Array = []
var _page: int = 0
var _sig: String = ""
var _built: bool = false
var selection_system: Node = null
var _accent: Color = Color(0.85, 0.71, 0.36)
var _cell_w: float = 46.0
var _cell_h: float = 54.0

## 一条 4px 的短血条/蓝条（自绘，比 Panel + ColorRect 省节点）
class SelBar extends Control:
	var ratio: float = 1.0
	var fill: Color = Color(0.85, 0.30, 0.26)
	var warn: bool = false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0.0, 4.0)

	func set_ratio(r: float, is_warn: bool = false) -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if absf(v - ratio) < 0.004 and is_warn == warn:
			return
		ratio = v
		warn = is_warn
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 2.0 or r.size.y < 2.0:
			return
		draw_rect(r, Color(0.0, 0.0, 0.0, 0.72), true)
		var col: Color = Color(1.0, 0.55, 0.30) if warn else fill
		var w: float = maxf((r.size.x - 1.0) * ratio, 0.0)
		if w > 0.3:
			draw_rect(Rect2(0.5, 0.5, w, r.size.y - 1.0), col, true)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := Spec.panel_style()
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
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
	_root.add_theme_constant_override("separation", 4)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# --- 标题行：名字（单选）/ 队伍数（多选） + 页码 ---
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.custom_minimum_size = Vector2(0.0, HEAD_H)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(head)

	_title = Spec.label("未选中", Spec.FS_TITLE, Spec.text_main())
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.custom_minimum_size = Vector2(72.0, 0.0)
	# ★ clip_text + 固定最小宽 ⇒ HBox 只给它 72px，"步兵 ×4" 会被截成"步兵"。
	#   让它自己吃满剩余宽度（弹性留白那格就多余了，删掉），页标靠右。
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)

	_page_label = Spec.label("", Spec.FS_BODY, Spec.text_dim())
	_page_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_page_label.tooltip_text = "点它 / 在网格上滚滚轮：翻页（一页 24 个）"
	_page_label.gui_input.connect(_on_page_label_input)
	head.add_child(_page_label)

	# --- 数值行（只有单选时出现，大号） ---
	_build_stats(_root)

	_grid = GridContainer.new()
	_grid.name = "网格"
	_grid.columns = COLS
	_grid.add_theme_constant_override("h_separation", 3)
	_grid.add_theme_constant_override("v_separation", 3)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_grid)

	_empty = Spec.label("框选或点选单位后，这里列出队伍", Spec.FS_BODY, Spec.text_dim())
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_empty)


## 三块大号数值铭牌（攻击 / 防御 / 移动；建筑则是 攻击 / 射程 / 视野）
func _build_stats(parent: Node) -> void:
	_stats_box = HBoxContainer.new()
	_stats_box.name = "数值"
	_stats_box.add_theme_constant_override("separation", 8)
	# 竖向撑满（底栏比内容高时，铭牌吃掉多余高度）
	_stats_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats_box.visible = false
	parent.add_child(_stats_box)

	for i in 3:
		# ★ 必须是 PanelContainer：Panel 不参与"按子节点算最小尺寸"，
		#   放进 HBox 后宽度恒为 0（第一版就是这么把数值行整行藏没的）。
		var chip := PanelContainer.new()
		chip.name = "数值%d" % i
		chip.custom_minimum_size = Vector2(120.0, STAT_H)
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.size_flags_vertical = Control.SIZE_EXPAND_FILL
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_theme_stylebox_override("panel",
				Spec.bevel_style(Color(0.070, 0.078, 0.096, 0.96), Color(0, 0, 0, 0), 5,
						10.0, 0.0, 0.10))
		_stats_box.add_child(chip)
		_stat_chips.append(chip)

		var row := HBoxContainer.new()
		row.name = "行"
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(row)

		# 图标 26px：数值 28px 时，图标比它小一点才不抢视线
		var ic := Spec.icon("sword", 26.0, Color(0.98, 0.62, 0.42))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ic)
		_stat_icons.append(ic)

		# 数字 + 小标竖排：数字照旧 28px，下面一行 "攻击 / 护甲 / 移速"
		var col := VBoxContainer.new()
		col.name = "数字列"
		col.add_theme_constant_override("separation", -2)
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(col)

		var v := Spec.label("-", Spec.FS_HERO, Color(0.96, 0.92, 0.79))
		v.add_theme_font_override("font", Spec.mono_font())
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		col.add_child(v)
		_stat_vals.append(v)

		var cap := Spec.label("", Spec.FS_CAPTION, Spec.text_dim())
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		col.add_child(cap)
		_stat_caps.append(cap)


# ===========================================================================
# 尺寸
# ===========================================================================

## 尺寸由 HUD 灌进来（宽度决定格子大小，高度只做下限）
func set_metrics(w: float, h: float, _compact: bool = false) -> void:
	if w < 60.0:
		return
	var inner: float = w - 16.0 - float(COLS - 1) * 3.0
	_cell_w = clampf(inner / float(COLS), 30.0, 62.0)
	_cell_h = clampf(_cell_w * 1.26, 38.0, 76.0)
	custom_minimum_size = Vector2(w, maxf(h, _cell_h))
	for rec in _cells:
		var btn: Button = rec["btn"]
		if btn != null and is_instance_valid(btn):
			btn.custom_minimum_size = Vector2(_cell_w, _cell_h)


## 网格是不是空的（HUD 拿它决定中段要不要出现）
func is_empty() -> bool:
	return _units.is_empty()


## 内容需要多高（HUD 用它决定底栏高度）
func content_height() -> float:
	if _units.size() == 1:
		return HEAD_H + 4.0 + STAT_H + 16.0
	var rows: int = maxi(1, mini(ROWS, ceili(float(_units.size()) / float(COLS))))
	return HEAD_H + 4.0 + float(rows) * (_cell_h + 3.0) + 14.0


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
		_sync_bars()
		_sync_stats()
		return
	_sig = sig
	_units = valid
	var pages: int = maxi(1, ceili(float(_units.size()) / float(PAGE_SIZE)))
	_page = clampi(_page, 0, pages - 1)
	_rebuild()
	_sync_bars()
	_sync_stats()


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
	_grid.visible = not _units.is_empty() and not single
	_page_label.visible = pages > 1
	_page_label.text = "%d / %d" % [_page + 1, pages]
	if _units.is_empty():
		_title.text = "未选中"
		return
	if single:
		var d: UnitDef = (_units[0] as Node3D).def
		_title.text = d.display_name if d != null else "单位"
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
	var from: int = _page * PAGE_SIZE
	var to: int = mini(_units.size(), from + PAGE_SIZE)
	for i in range(from, to):
		_grid.add_child(_make_cell(_units[i]))


func _make_cell(u: Node3D) -> Button:
	var btn := Button.new()
	btn.name = "格_%d" % u.get_instance_id()
	btn.custom_minimum_size = Vector2(_cell_w, _cell_h)
	btn.focus_mode = Control.FOCUS_NONE
	btn.flat = true
	var d: UnitDef = u.def
	btn.tooltip_text = "%s  %d/%d" % [
		d.display_name if d != null else "单位",
		int(u.get("hp")), int(d.max_hp) if d != null else 100]
	btn.add_theme_stylebox_override("normal",
			Spec.inset_style(Color(0.075, 0.084, 0.100, 0.96), 4,
				Color(_accent.r, _accent.g, _accent.b, 0.30), 0, 0))
	btn.add_theme_stylebox_override("hover",
			Spec.inset_style(Color(0.120, 0.132, 0.156, 0.98), 4,
				_accent, 0, 0))
	btn.add_theme_stylebox_override("pressed",
			Spec.inset_style(Color(0.060, 0.068, 0.084, 0.98), 4,
				_accent, 0, 0))
	var captured: Node3D = u
	btn.pressed.connect(func() -> void: _pick(captured))

	# ★ 图标：优先用 **Blender 渲的单位头像 PNG**（魔兽那种"一张脸"），
	#   没有渲图才退回线描 SVG（刀/弓/法杖）—— 后者远看只是一个符号，认不出兵种。
	var unit_png: Texture2D = Spec.unit_icon(d.id) if d != null else null
	var icon := TextureRect.new()
	icon.name = "头像"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if unit_png != null:
		icon.texture = unit_png
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 2.0
		icon.offset_top = 2.0
		icon.offset_right = -2.0
		icon.offset_bottom = -12.0
		icon.modulate = Color(1, 1, 1, 1)
	else:
		var inset: float = maxf(_cell_w * 0.20, 4.0)
		icon.texture = Spec.icon_tex(_icon_for(d))
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = inset
		icon.offset_top = maxf(inset * 0.5, 2.0)
		icon.offset_right = -inset
		icon.offset_bottom = -maxf(_cell_h * 0.26, 12.0)
		icon.modulate = _tint_of(u)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(icon)

	var hp := SelBar.new()
	hp.name = "血条"
	hp.fill = Color(0.80, 0.26, 0.22)
	hp.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hp.offset_left = 3.0
	hp.offset_right = -3.0
	hp.offset_top = -11.0
	hp.offset_bottom = -7.0
	btn.add_child(hp)

	var mp := SelBar.new()
	mp.name = "蓝条"
	mp.fill = Color(0.34, 0.62, 0.98)
	mp.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	mp.offset_left = 3.0
	mp.offset_right = -3.0
	mp.offset_top = -6.0
	mp.offset_bottom = -3.0
	mp.visible = bool(u.call("has_mana")) if u.has_method("has_mana") else false
	btn.add_child(mp)

	_cells.append({"btn": btn, "bar_hp": hp, "bar_mp": mp, "icon": icon, "unit": u})
	return btn


## 血条 / 蓝条就地刷新（不重建格子，省节点）
func _sync_bars() -> void:
	for rec in _cells:
		var u: Node3D = rec.get("unit", null)
		var hp: SelBar = rec.get("bar_hp", null)
		var mp: SelBar = rec.get("bar_mp", null)
		if u == null or not is_instance_valid(u) or hp == null:
			continue
		var d: UnitDef = u.def
		var total: float = d.max_hp if d != null else 1.0
		var cur: float = float(u.get("hp"))
		var r: float = cur / maxf(total, 1.0)
		hp.set_ratio(r, r < 0.3)
		if mp != null:
			var has_m: bool = bool(u.call("has_mana")) if u.has_method("has_mana") else false
			if mp.visible != has_m:
				mp.visible = has_m
			if has_m:
				var mmax: float = float(u.call("max_mana"))
				var mcur: float = float(u.get("mana"))
				mp.set_ratio(mcur / maxf(mmax, 1.0))


## 焦点单位的数值。**只有单选时显示**（玩家口径："多个单位就隐藏这个信息"）。
func _sync_stats() -> void:
	if _stats_box == null:
		return
	if _units.size() != 1:
		if _stats_box.visible:
			_stats_box.visible = false
			_stats_sig = ""
		return
	var u := _units[0] as Node3D
	var d: UnitDef = u.def if u != null else null
	var sig: String = String(d.id) if d != null else "?"
	if sig == _stats_sig and _stats_box.visible:
		return
	_stats_sig = sig
	var stats: Array = _stats_of(d)
	_stats_box.visible = not stats.is_empty()
	for i in _stat_chips.size():
		if i >= stats.size():
			_stat_chips[i].visible = false
			continue
		var s: Dictionary = stats[i]
		_stat_chips[i].visible = true
		_stat_chips[i].tooltip_text = String(s.get("tip", ""))
		var col: Color = s.get("color", Color(0.9, 0.88, 0.8))
		Spec.set_icon(_stat_icons[i], String(s.get("icon", "sword")), col)
		_stat_vals[i].text = String(s.get("text", "-"))
		_stat_vals[i].add_theme_color_override("font_color", col.lerp(Color(1, 1, 1), 0.55))
		if i < _stat_caps.size():
			_stat_caps[i].text = String(s.get("name", ""))


## 兵种/建筑 → 三项数值。
## 单位：攻击 / 防御 / 速度；
## **能攻击的建筑：攻击 / 射程 / 视野**；不能攻击的建筑：视野 / 护甲 /（人口或耗时）。
func _stats_of(d: UnitDef) -> Array:
	if d == null:
		return []
	if d.is_building():
		if d.can_attack():
			return [
				{"icon": "sword", "name": "攻击", "color": Color(0.98, 0.62, 0.42),
					"text": _fmt(d.attack_damage), "tip": "攻击力（每 %.1fs 一发）" % d.attack_cooldown},
				{"icon": "bow", "name": "射程", "color": Color(0.86, 0.80, 0.52),
					"text": "%dm" % int(round(d.attack_range)), "tip": "射程"},
				{"icon": "eye", "name": "视野", "color": Color(0.66, 0.86, 0.92),
					"text": "%dm" % int(round(d.sight_range)), "tip": "视野"},
			]
		var out: Array = [
			{"icon": "shield", "name": "护甲", "color": Color(0.62, 0.78, 0.98),
				"text": _fmt(d.armor), "tip": "护甲"},
			{"icon": "eye", "name": "视野", "color": Color(0.66, 0.86, 0.92),
				"text": "%dm" % int(round(d.sight_range)), "tip": "视野（无攻击，只负责看）"},
		]
		if d.food_provided > 0:
			out.append({"icon": "house", "name": "人口", "color": Color(0.80, 0.88, 0.66),
				"text": "+%d" % d.food_provided, "tip": "提供人口上限"})
		elif d.detect_radius > 0.0:
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
	return [
		{"icon": "sword", "name": "攻击", "color": Color(0.98, 0.62, 0.42),
			"text": _fmt(d.attack_damage) if d.attack_damage > 0.0 else "—",
			"tip": "攻击力" if d.attack_damage > 0.0 else "没有攻击能力"},
		{"icon": "shield", "name": "护甲", "color": Color(0.62, 0.78, 0.98),
			"text": _fmt(d.armor), "tip": "护甲"},
		{"icon": "move", "name": "移速", "color": Color(0.72, 0.88, 0.56),
			"text": _fmt(d.move_speed), "tip": "移动速度（米/秒）"},
	]


func _fmt(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


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


## 翻页（滚轮 / 点页码）
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
