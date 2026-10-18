class_name RtsDossierPanel
extends PanelContainer
## **BASALT（选中档案板）** —— 中下方那块"门面"。
##
## 版式（左图右料，现代 RTS 的常见做法）：
##
##   ┌───────────┬────────────────────────────────┐
##   │  3D 头像  │  名称   〔状态〕   ● 玩家      │
##   │  160×160  │  ──────────── 主色分隔线 ────  │
##   │  ×N 角标  │  生命条（数值 + 百分比 + 渐变）│
##   │           │  攻击 15   防御 5   移动 4.6   │
##   │           │  重甲 · 普通 · 射程 11        │
##   ├───────────┴────────────────────────────────┤
##   │  共 3 个   [步][步][弓][法]…（最多 12 格）  │
##   └────────────────────────────────────────────┘
##
## 三条纪律：
##   1. **颜色全部来自 Cfg.game**（hud_accent / hud_bg / 阵营色），不自己发明调色，
##      否则界面跟 文档/美术规范.md 的世界观脱节；
##   2. **数字用等宽字体**（13~15 号），中文用主题字体 —— 中文绝不吃等宽字体，
##      不然雅黑没有的字形会变方块；
##   3. 单选的布局高度与多选不同（多选多一条格子带），由 `desired_height()` 告诉 HUD。

# ===========================================================================
# 版面常量
# ===========================================================================

## 面板总宽（像素，1920×1080 逻辑分辨率下约占 26%）
const PANEL_W := 512.0
## 右侧文字列宽
const RIGHT_W := 314.0
## 生命条高度
const HP_H := 22.0
## 单选 / 多选两种高度
const H_SINGLE := 190.0
const H_MULTI := 226.0
## 多选格子（最多 12 格）
const CELL_MAX := 12
const CELL_W := 32.0
const CELL_H := 32.0


# ===========================================================================
# 内嵌控件：生命条 / 多选格子
# ===========================================================================

## 生命条：底 → 渐变填充 → 高光 → 外框，上面盖一个文字 Label
class HealthBar extends Control:
	var value: float = 1.0
	var maximum: float = 1.0
	var caption: String = ""
	var _caption_label: Label = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0.0, 22.0)
		_caption_label = Label.new()
		_caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_caption_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_caption_label.add_theme_font_size_override("font_size", 13)
		_caption_label.add_theme_color_override("font_color", Color(0.97, 0.96, 0.92))
		_caption_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.88))
		_caption_label.add_theme_constant_override("outline_size", 4)
		_caption_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_caption_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(_caption_label)

	## 喂数据（同样的数值不会触发重绘）
	func feed(v: float, m: float, cap: String) -> void:
		if is_equal_approx(v, value) and is_equal_approx(m, maximum) and cap == caption:
			return
		value = v
		maximum = m
		caption = cap
		if _caption_label != null:
			_caption_label.text = cap
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 4.0 or r.size.y < 4.0:
			return
		# 底槽
		draw_rect(r, Color(0.030, 0.035, 0.045, 0.98), true)
		var ratio: float = clampf(value / maxf(maximum, 0.001), 0.0, 1.0)
		if ratio > 0.0:
			var w: float = r.size.x * ratio
			# 渐变填充：冷→暖两段，低于 60%/30% 换警告色
			var c_lo := Color(0.14, 0.52, 0.30)
			var c_hi := Color(0.42, 0.90, 0.48)
			if ratio <= 0.30:
				c_lo = Color(0.52, 0.12, 0.10)
				c_hi = Color(0.95, 0.36, 0.30)
			elif ratio <= 0.60:
				c_lo = Color(0.58, 0.40, 0.10)
				c_hi = Color(0.96, 0.78, 0.34)
			var strips: int = 36
			for i in strips:
				var x0: float = w * float(i) / float(strips)
				var x1: float = w * float(i + 1) / float(strips)
				if x1 <= x0:
					continue
				var t: float = float(i) / float(strips - 1)
				draw_rect(Rect2(x0, 3.0, x1 - x0 + 0.6, r.size.y - 6.0), c_lo.lerp(c_hi, t), true)
			# 顶部高光（一条 2px 的亮边，塑料感全靠它）
			draw_rect(Rect2(1.0, 3.0, maxf(w - 2.0, 0.0), 2.0), Color(1.0, 1.0, 1.0, 0.20), true)
			# 右端锋线
			draw_rect(Rect2(maxf(w - 1.5, 0.0), 3.0, 1.5, r.size.y - 6.0), Color(1.0, 1.0, 1.0, 0.45), true)
		# 外框
		draw_rect(r, Color(0.0, 0.0, 0.0, 0.55), false, 1.0)
		draw_rect(r.grow(-1.0), Color(1.0, 1.0, 1.0, 0.10), false, 1.0)


## 多选小格子：底色 + 首字 + 底部血量微条
class MiniCell extends Control:
	var ch: String = ""
	var ratio: float = 1.0
	var hostile: bool = false
	var _label: Label = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(32.0, 32.0)
		_label = Label.new()
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		_label.add_theme_font_size_override("font_size", 14)
		_label.add_theme_color_override("font_color", Color(0.93, 0.93, 0.89))
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		_label.offset_top = 1.0
		_label.offset_bottom = -4.0
		add_child(_label)

	func feed(c: String, r: float, is_hostile: bool) -> void:
		var dirty: bool = c != ch or not is_equal_approx(r, ratio) or is_hostile != hostile
		ch = c
		ratio = r
		hostile = is_hostile
		if _label != null and _label.text != c:
			_label.text = c
		if dirty:
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 4.0:
			return
		draw_rect(r, Color(0.075, 0.083, 0.10, 0.96), true)
		var border := Color(1.0, 1.0, 1.0, 0.10)
		if hostile:
			border = Color(1.0, 0.34, 0.26, 0.55)
		draw_rect(r, border, false, 1.0)
		var w: float = (r.size.x - 4.0) * clampf(ratio, 0.0, 1.0)
		var col := Color(0.38, 0.82, 0.44)
		if ratio <= 0.30:
			col = Color(0.94, 0.34, 0.28)
		elif ratio <= 0.60:
			col = Color(0.92, 0.72, 0.30)
		draw_rect(Rect2(2.0, r.size.y - 4.0, w, 2.0), col, true)


# ===========================================================================
# 节点
# ===========================================================================

var _accent: Color = Color(0.85, 0.71, 0.36)
var _portrait: RtsPortraitStage = null
var _name_label: Label = null
var _state_label: Label = null
var _faction_dot: Panel = null
var _faction_label: Label = null
var _hp: HealthBar = null
var _stat_names: Array[Label] = []
var _stat_values: Array[Label] = []
var _tags: Label = null
var _trait_row: HBoxContainer = null
var _trait_chips: Array[PanelContainer] = []
var _trait_labels: Array[Label] = []
var _hint: Label = null
var _multi_row: HBoxContainer = null
var _multi_title: Label = null
var _cells: Array[MiniCell] = []
var _mono: Font = null
var _built: bool = false
var _multi_visible: bool = false


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	ensure_built()


## HUD 在 refresh 之前会先调一次，保证控件齐了（重复调用安全）
func ensure_built() -> void:
	if _built:
		return
	_built = true
	_accent = Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)
	_mono = _make_mono_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(PANEL_W, H_SINGLE)
	add_theme_stylebox_override("panel", _make_style())

	var vb := VBoxContainer.new()
	vb.name = "纵"
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vb)

	_build_top(vb)
	_build_multi_row(vb)
	_show_empty()


## 面板底色：圆角深色半透明 + 1px 亮边 + 外投影（"硬邦邦"的关键是这块投影）
func _make_style() -> StyleBoxFlat:
	var bg: Color = Cfg.game.hud_bg if Cfg.game != null else Color(0.06, 0.07, 0.09, 0.86)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg.r * 1.25 + 0.030, bg.g * 1.25 + 0.034, bg.b * 1.25 + 0.042, 0.930)
	sb.border_color = Color(_accent.r, _accent.g, _accent.b, 0.46)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(7)
	sb.corner_detail = 8
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.50)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0.0, 3.0)
	return sb


func _build_top(parent: Node) -> void:
	var top := HBoxContainer.new()
	top.name = "上"
	top.add_theme_constant_override("separation", 10)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(top)

	_portrait = RtsPortraitStage.new()
	_portrait.name = "头像"
	_portrait.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.add_child(_portrait)

	var right := VBoxContainer.new()
	right.name = "右列"
	right.custom_minimum_size = Vector2(RIGHT_W, 0.0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 5)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(right)

	# --- 标题行：名称 + 状态 + 阵营 ---
	var name_row := HBoxContainer.new()
	name_row.name = "标题行"
	name_row.add_theme_constant_override("separation", 8)
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(name_row)

	_name_label = Label.new()
	_name_label.text = "未选中"
	_name_label.add_theme_font_size_override("font_size", 21)
	_name_label.add_theme_color_override("font_color", Color(0.96, 0.95, 0.90))
	_name_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	_name_label.add_theme_constant_override("outline_size", 3)
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(_name_label)

	_state_label = Label.new()
	_state_label.text = ""
	_state_label.add_theme_font_size_override("font_size", 12)
	_state_label.add_theme_color_override("font_color", Color(0.72, 0.78, 0.72))
	_state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(_state_label)

	_faction_dot = Panel.new()
	_faction_dot.custom_minimum_size = Vector2(9.0, 9.0)
	_faction_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_faction_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(_faction_dot)

	_faction_label = Label.new()
	_faction_label.text = ""
	_faction_label.add_theme_font_size_override("font_size", 12)
	_faction_label.add_theme_color_override("font_color", Color(0.70, 0.72, 0.70))
	_faction_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_faction_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(_faction_label)

	# --- 主色分隔线（"标题栏用 hud_accent 描边"）---
	var rule := ColorRect.new()
	rule.name = "主色分隔线"
	rule.color = Color(_accent.r, _accent.g, _accent.b, 0.62)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(rule)

	# --- 生命条 ---
	_hp = HealthBar.new()
	_hp.name = "生命条"
	_hp.custom_minimum_size = Vector2(0.0, HP_H)
	_hp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_hp)

	# --- 数值行：攻击 / 防御 / 移动 ---
	var stats := HBoxContainer.new()
	stats.name = "数值行"
	stats.add_theme_constant_override("separation", 16)
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(stats)
	for i in 3:
		var grp := HBoxContainer.new()
		grp.add_theme_constant_override("separation", 4)
		grp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stats.add_child(grp)
		var nl := Label.new()
		nl.text = "-"
		nl.add_theme_font_size_override("font_size", 12)
		nl.add_theme_color_override("font_color", Color(0.62, 0.64, 0.62))
		nl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grp.add_child(nl)
		var vl := Label.new()
		vl.text = "-"
		vl.add_theme_font_size_override("font_size", 15)
		vl.add_theme_color_override("font_color", Color(0.94, 0.90, 0.76))
		vl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		vl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _mono != null:
			vl.add_theme_font_override("font", _mono)
		grp.add_child(vl)
		_stat_names.append(nl)
		_stat_values.append(vl)

	# --- 标签行：护甲 · 伤害 · 射程 ---
	_tags = Label.new()
	_tags.name = "标签行"
	_tags.text = ""
	_tags.add_theme_font_size_override("font_size", 13)
	_tags.add_theme_color_override("font_color", Color(0.78, 0.78, 0.74))
	_tags.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(_tags)

	# --- 特性小标签（补上右列中间那块空档，顺便把"状态"说清楚）---
	_build_trait_row(right)

	# --- 弹性空隙：把提示行压到底部 ---
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(spacer)

	_hint = Label.new()
	_hint.name = "提示行"
	_hint.text = "左键选择 · 拖框多选 · Shift 加选 · 右键下达指令"
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(0.56, 0.58, 0.56))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(_hint)


## 特性小标签行：把"这单位还能干什么"用胶囊牌讲清楚（也顺手填掉了右列中段空档）
func _build_trait_row(parent: Node) -> void:
	_trait_row = HBoxContainer.new()
	_trait_row.name = "特性行"
	_trait_row.add_theme_constant_override("separation", 6)
	_trait_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_trait_row)
	for i in 3:
		var chip := PanelContainer.new()
		chip.name = "牌%d" % i
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.visible = false
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.115, 0.130, 0.160, 0.94)
		sb.border_color = Color(_accent.r, _accent.g, _accent.b, 0.30)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(9)
		sb.content_margin_left = 9.0
		sb.content_margin_right = 9.0
		sb.content_margin_top = 1.0
		sb.content_margin_bottom = 1.0
		chip.add_theme_stylebox_override("panel", sb)
		var lb := Label.new()
		lb.text = ""
		lb.add_theme_font_size_override("font_size", 12)
		lb.add_theme_color_override("font_color", Color(0.80, 0.85, 0.80))
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(lb)
		_trait_row.add_child(chip)
		_trait_chips.append(chip)
		_trait_labels.append(lb)


func _build_multi_row(parent: Node) -> void:
	_multi_row = HBoxContainer.new()
	_multi_row.name = "多选带"
	_multi_row.add_theme_constant_override("separation", 8)
	_multi_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_multi_row.visible = false
	parent.add_child(_multi_row)

	_multi_title = Label.new()
	_multi_title.text = "共 1 个"
	_multi_title.custom_minimum_size = Vector2(78.0, 0.0)
	_multi_title.add_theme_font_size_override("font_size", 13)
	_multi_title.add_theme_color_override("font_color", Color(_accent.r, _accent.g, _accent.b, 0.92))
	_multi_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_multi_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_multi_row.add_child(_multi_title)

	for i in CELL_MAX:
		var c := MiniCell.new()
		c.name = "格%d" % i
		c.visible = false
		_multi_row.add_child(c)
		_cells.append(c)


# ===========================================================================
# 对外接口
# ===========================================================================

## 当前布局高度（HUD 用来摆位置）
func desired_height() -> float:
	return H_MULTI if _multi_visible else H_SINGLE


## 刷新（units 是 HUD 过滤过的有效选中数组）
func refresh(units: Array) -> void:
	ensure_built()
	var arr: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		arr.append(u)

	var multi: bool = arr.size() > 1
	if multi != _multi_visible:
		_multi_visible = multi
		_multi_row.visible = multi
	if multi:
		_feed_cells(arr)

	if arr.is_empty():
		_show_empty()
		return

	var primary := arr[0] as Node3D
	if primary == null:
		_show_empty()
		return
	var def: UnitDef = primary.get("def") as UnitDef

	_name_label.text = def.display_name if def != null else "未知目标"
	_name_label.add_theme_color_override("font_color", _name_color(def, primary))
	_hint.text = "左键选择 · 拖框多选 · Shift 加选 · 右键下达指令"
	_hint.add_theme_color_override("font_color", Color(0.56, 0.58, 0.56))

	# 状态
	var st: int = int(primary.get("state")) if primary.get("state") != null else -1
	_state_label.text = _state_text(st)
	_state_label.add_theme_color_override("font_color", _state_color(st))

	# 阵营
	_fill_faction(primary, def)

	# 生命
	var max_hp: float = 100.0
	var hp: float = 100.0
	if def != null and def.max_hp > 0.0:
		max_hp = def.max_hp
	if primary.get("hp") != null:
		hp = float(primary.get("hp"))
	hp = clampf(hp, 0.0, max_hp)
	var pct: int = int(round(hp / maxf(max_hp, 0.001) * 100.0))
	_hp.feed(hp, max_hp, "生命 %d / %d　·　%d%%" % [int(round(hp)), int(round(max_hp)), pct])

	# 数值三连
	_fill_stats(primary, def)

	# 标签行
	_tags.text = _tags_text(primary, def)
	_fill_traits(primary, def)

	# 头像
	_portrait.show_target(primary, arr.size())


# ===========================================================================
# 内容填充
# ===========================================================================

func _show_empty() -> void:
	_name_label.text = "未选中"
	_name_label.add_theme_color_override("font_color", Color(0.80, 0.80, 0.76))
	_state_label.text = ""
	_state_label.add_theme_color_override("font_color", Color(0.60, 0.62, 0.60))
	_faction_dot.visible = false
	_faction_label.text = ""
	_hp.feed(0.0, 1.0, "未选中任何目标")
	for i in 3:
		_stat_names[i].text = "-"
		_stat_values[i].text = "-"
	_tags.text = "把鼠标移到战场上看左边这块亮起来"
	_hint.text = "左键选择 · 拖框多选 · Shift 加选 · 右键下达指令"
	_hint.add_theme_color_override("font_color", Color(0.56, 0.58, 0.56))
	for chip in _trait_chips:
		chip.visible = false
	_portrait.show_target(null)
	_multi_visible = false
	_multi_row.visible = false


func _fill_faction(target: Node3D, def: UnitDef) -> void:
	var fac: RtsFaction = target.get("faction") as RtsFaction
	var col := Color(0.72, 0.72, 0.70)
	var txt: String = ""
	if fac != null:
		col = fac.color
		txt = "玩家" if fac.is_player else fac.display_name
	elif def != null and def.is_harvestable():
		col = Cfg.game.gold_color if (Cfg.game != null and def.harvest_kind == RtsConst.Harvest.GOLD) else Color(0.45, 0.72, 0.36)
		txt = "中立资源"
	else:
		txt = "中立"
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(4)
	_faction_dot.add_theme_stylebox_override("panel", sb)
	_faction_dot.visible = true
	_faction_label.text = txt
	_faction_label.add_theme_color_override("font_color", Color(col.r * 0.55 + 0.42, col.g * 0.55 + 0.42, col.b * 0.55 + 0.42))


func _fill_stats(target: Node3D, def: UnitDef) -> void:
	var a := "-"
	var b := "-"
	var c := "-"
	var la := "攻击"
	var lb := "防御"
	var lc := "移动"
	if def != null:
		a = _fmt(def.attack_damage) if def.attack_damage > 0.0 else "—"
		b = _fmt(def.armor)
		if def.is_building():
			lc = "占地"
			c = "%d×%d" % [def.footprint.x, def.footprint.y]
		elif def.is_harvestable():
			la = "剩余"
			lb = "总量"
			lc = "类型"
			var left: int = int(target.get("remaining")) if target.get("remaining") != null else def.resource_amount
			a = "%d" % left
			b = "%d" % def.resource_amount
			c = "金" if def.harvest_kind == RtsConst.Harvest.GOLD else "木"
		else:
			c = _fmt(def.move_speed)
	_stat_names[0].text = la
	_stat_names[1].text = lb
	_stat_names[2].text = lc
	_stat_values[0].text = a
	_stat_values[1].text = b
	_stat_values[2].text = c


func _tags_text(target: Node3D, def: UnitDef) -> String:
	if def == null:
		return ""
	var parts := PackedStringArray()
	var b := target as RtsBuilding
	if b != null:
		parts.append(_armor_name(def.armor_type))
		if not b.is_constructed:
			parts.append("建造中 %d%%" % int(clampf(b.progress, 0.0, 1.0) * 100.0))
		elif not b.train_queue.is_empty():
			parts.append("训练队列 %d" % b.train_queue.size())
		parts.append("占地 %d×%d" % [def.footprint.x, def.footprint.y])
	elif def.is_harvestable():
		parts.append("可采集")
		parts.append("金矿" if def.harvest_kind == RtsConst.Harvest.GOLD else "木材")
	else:
		parts.append(_armor_name(def.armor_type))
		parts.append(_dmg_name(def.attack_type))
		if def.attack_range > 0.0:
			parts.append("射程 %s" % _fmt(def.attack_range))
		if def.gather_rate > 0.0:
			parts.append("可建造")
	return "  ·  ".join(parts)


func _feed_cells(arr: Array) -> void:
	_multi_title.text = "共 %d 个" % arr.size()
	for i in CELL_MAX:
		var cell := _cells[i]
		if i >= arr.size():
			cell.visible = false
			continue
		var u := arr[i] as Node3D
		if u == null:
			cell.visible = false
			continue
		var d: UnitDef = u.get("def") as UnitDef
		var ch: String = "?"
		if d != null and not d.display_name.is_empty():
			ch = d.display_name.substr(0, 1)
		var mx: float = d.max_hp if d != null and d.max_hp > 0.0 else 100.0
		var hp: float = float(u.get("hp")) if u.get("hp") != null else mx
		var ratio: float = clampf(hp / maxf(mx, 0.001), 0.0, 1.0)
		var fac: RtsFaction = u.get("faction") as RtsFaction
		var hostile: bool = fac != null and fac != Game.player_faction
		cell.visible = true
		cell.feed(ch, ratio, hostile)


# ===========================================================================
# 状态 / 文案
# ===========================================================================

## 特性胶囊：最多 3 枚，按"最有用优先"排
func _fill_traits(target: Node3D, def: UnitDef) -> void:
	var items := PackedStringArray()
	if def != null:
		var b := target as RtsBuilding
		if def.is_building():
			if b != null and not b.train_queue.is_empty():
				items.append("训练中 %s" % _id_name(b.train_queue[0]))
			if not def.trains.is_empty():
				items.append("可训练 %d 种" % def.trains.size())
			if def.food_provided > 0:
				items.append("人口 +%d" % def.food_provided)
			if def.is_dropoff:
				items.append("资源交汇点")
		elif def.is_harvestable():
			items.append("可采集")
			items.append("金矿" if def.harvest_kind == RtsConst.Harvest.GOLD else "木材")
			var left: int = int(target.get("remaining")) if target.get("remaining") != null else def.resource_amount
			items.append("剩余 %d" % left)
		else:
			if def.gather_rate > 0.0:
				items.append("采集 %.1f/秒" % def.gather_rate)
			if def.attack_damage > 0.0:
				items.append("攻速 %.2f秒" % maxf(def.attack_cooldown, 0.05))
			for ab in def.abilities:
				items.append(_ability_name(ab))
			if def.sight_range > 0.0:
				items.append("视野 %d" % int(round(def.sight_range)))
			if def.food_cost > 0:
				items.append("人口 %d" % def.food_cost)
	for i in _trait_chips.size():
		var chip := _trait_chips[i]
		if i < items.size():
			_trait_labels[i].text = items[i]
			chip.visible = true
		else:
			chip.visible = false


func _id_name(id: StringName) -> String:
	var d: UnitDef = Cfg.unit(id) if Cfg.game != null else null
	return d.display_name if d != null else String(id)


func _ability_name(ab: StringName) -> String:
	match ab:
		&"fireball": return "火球术"
		_: return String(ab)


func _state_text(st: int) -> String:
	match st:
		RtsConst.State.IDLE: return "待机"
		RtsConst.State.MOVE: return "移动"
		RtsConst.State.ATTACK: return "交战"
		RtsConst.State.GATHER: return "采集"
		RtsConst.State.BUILD: return "建造"
		RtsConst.State.DEAD: return "阵亡"
		RtsConst.State.CAST: return "施法"
		RtsConst.State.RETURN: return "搬运"
		_: return ""


func _state_color(st: int) -> Color:
	match st:
		RtsConst.State.MOVE: return Color(0.62, 0.80, 0.98)
		RtsConst.State.ATTACK: return Color(0.96, 0.52, 0.42)
		RtsConst.State.GATHER: return Color(0.98, 0.82, 0.44)
		RtsConst.State.BUILD: return Color(0.66, 0.90, 0.60)
		RtsConst.State.CAST: return Color(0.76, 0.68, 1.0)
		RtsConst.State.RETURN: return Color(0.86, 0.78, 0.58)
		_: return Color(0.66, 0.68, 0.66)


func _name_color(def: UnitDef, target: Node3D) -> Color:
	var fac: RtsFaction = target.get("faction") as RtsFaction
	if fac != null and fac != Game.player_faction:
		return Color(1.0, 0.72, 0.66)
	if def != null and def.is_harvestable():
		return Color(0.96, 0.90, 0.66)
	return Color(0.96, 0.95, 0.90)


## 数值：整数不带小数点（等宽字体下也不会抖）
func _fmt(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


func _armor_name(t: int) -> String:
	match t:
		RtsConst.ArmorType.LIGHT: return "轻甲"
		RtsConst.ArmorType.HEAVY: return "重甲"
		RtsConst.ArmorType.FORTIFIED: return "城甲"
		_: return "无甲"


func _dmg_name(t: int) -> String:
	match t:
		RtsConst.DamageType.PIERCE: return "穿刺"
		RtsConst.DamageType.MAGIC: return "魔法"
		RtsConst.DamageType.SIEGE: return "攻城"
		_: return "普通"


## 等宽字体：**只给纯数字用**，所以不配中文兜底也不会出方块
func _make_mono_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Consolas", "Cascadia Mono", "DejaVu Sans Mono",
		"Liberation Mono", "Courier New", "monospace",
	])
	return f
