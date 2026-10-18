class_name RtsCommandCard
extends Control
## **命令卡（HAWKEYE）**：右下角 4列×3行 按钮网格（文档 §8）
##
## 内容随选中目标变化（魔兽3 的惯例）：
##   - 选中建筑：训练该建筑能出的单位（`UnitDef.trains`）+ 取消训练
##   - 选中农民：建造 农场/兵营/箭塔/铁匠铺
##   - 选中法师：火球术
##   - 常备：攻击移动 / 停止 / 保持
##
## 只负责"按下去把请求转给指令系统"，**不做任何玩法判定**（判定在 CommandSystem）。
## 按钮用完就重建，但 HUD 只在"签名"变化时才调用 refresh，避免鼠标悬停时闪烁。

## 4 列 × 3 行
const COLS := 4
const ROWS := 3
## 单个按钮尺寸
const BTN_SIZE := Vector2(76.0, 52.0)

## 指令系统（HUD 注入）
var command_system: Node = null

## 标题（"兵营" / "农民" / "未选中"）
var _title: Label = null
## 训练队列指示条（建筑在造东西时亮小格）
var _queue_row: HBoxContainer = null
var _queue_pips: Array[Panel] = []
## 按钮容器
var _grid: GridContainer = null

## 当前选中
var _selection: Array = []

## 是否切到"建造页"（B 键 / HUD.toggle_build_menu 切换）
var _build_page: bool = false

## 训练队列最多画几格
const QUEUE_PIPS := 5


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var accent: Color = _accent()
	var vb := VBoxContainer.new()
	vb.name = "列"
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(vb)

	# --- 标题行：标题 + 队列小格 ---
	var head := HBoxContainer.new()
	head.name = "标题行"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)

	_title = Label.new()
	_title.text = "未选中"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title.add_theme_font_size_override("font_size", 16)
	_title.add_theme_color_override("font_color", Color(accent.r, accent.g, accent.b, 0.98))
	_title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	_title.add_theme_constant_override("outline_size", 3)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_title)

	_queue_row = HBoxContainer.new()
	_queue_row.name = "队列"
	_queue_row.add_theme_constant_override("separation", 3)
	_queue_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_queue_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_queue_row)
	for i in QUEUE_PIPS:
		var p := Panel.new()
		p.custom_minimum_size = Vector2(9.0, 9.0)
		p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.16, 0.18, 0.21, 0.9)
		sb.border_color = Color(accent.r, accent.g, accent.b, 0.35)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(2)
		p.add_theme_stylebox_override("panel", sb)
		p.visible = false
		_queue_row.add_child(p)
		_queue_pips.append(p)

	# --- 主色分隔线（把标题和按钮分开，信息层级的第一刀）---
	var rule := ColorRect.new()
	rule.name = "主色分隔线"
	rule.color = Color(accent.r, accent.g, accent.b, 0.55)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(rule)

	_grid = GridContainer.new()
	_grid.name = "网格"
	_grid.columns = COLS
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	vb.add_child(_grid)


# ===========================================================================
# 对外
# ===========================================================================

## 刷新内容（HUD 在选中/队列/建造页变化时调用）
func refresh(units: Array) -> void:
	_selection = units.duplicate()
	for c in _grid.get_children():
		c.queue_free()

	var entries := _build_entries()
	_title.text = _title_text()
	_update_queue()
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "没有可用指令"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.56, 0.57, 0.55))
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_grid.add_child(empty)
		return
	for e in entries:
		_grid.add_child(_make_button(e))


## 训练队列小格（有几格亮几格）
func _update_queue() -> void:
	var b := _first_building()
	var n: int = b.train_queue.size() if b != null else 0
	var accent: Color = _accent()
	for i in _queue_pips.size():
		var p := _queue_pips[i]
		var on: bool = i < n
		p.visible = on
		if on:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(accent.r, accent.g, accent.b, 0.92)
			sb.border_color = Color(accent.r, accent.g, accent.b, 1.0)
			sb.set_border_width_all(1)
			sb.set_corner_radius_all(2)
			p.add_theme_stylebox_override("panel", sb)


## B 键：在"常用页"和"建造页"之间切换
func toggle_build_page() -> void:
	_build_page = not _build_page
	refresh(_selection)


## 当前是否在建造页
func is_build_page() -> bool:
	return _build_page


# ===========================================================================
# 内容
# ===========================================================================

## 标题文案
func _title_text() -> String:
	if _selection.is_empty():
		return "未选中"
	var b := _first_building()
	if b != null and b.def != null:
		var extra: String = "" if b.train_queue.is_empty() else "（队列 %d）" % b.train_queue.size()
		return "%s%s" % [b.def.display_name, extra]
	var u := _first_unit()
	if u != null and u.def != null:
		var n: String = "" if _selection.size() <= 1 else " ×%d" % _selection.size()
		return "%s%s" % [u.def.display_name, n]
	return "未选中"


## 根据选中内容拼出按钮条目
func _build_entries() -> Array:
	var out: Array = []
	if _selection.is_empty():
		return out

	# --- 1. 建筑：训练队列 ---
	var b := _first_building()
	if b != null and b.def != null:
		for id in b.def.trains:
			out.append(_train_entry(b, id))
		if not b.train_queue.is_empty():
			out.append({
				"label": "取消训练",
				"hint": "退掉队列里的最后一个并退款",
				"color": Color(0.95, 0.62, 0.35),
				"action": func(): _call("request_cancel_train"),
			})
		out.append(_stop_entry())
		return out

	var worker := _has_worker()
	var unit := _first_unit()

	# --- 2. 建造页（或农民选中时顺便给建造快捷键）---
	if _build_page and worker:
		for bid in [&"farm", &"barracks", &"tower", &"blacksmith"]:
			out.append(_build_entry(bid))
		out.append({
			"label": "返回",
			"hint": "回到常用指令",
			"color": Color(0.75, 0.75, 0.72),
			"action": func(): toggle_build_page(),
		})
		return out

	# --- 3. 技能 ---
	if unit != null and unit.def != null:
		for ab in unit.def.abilities:
			out.append(_ability_entry(ab))

	# --- 4. 常备指令 ---
	if worker:
		out.append(_build_entry(&"farm"))
		out.append(_build_entry(&"barracks"))
		out.append({
			"label": "更多建造",
			"hint": "箭塔 / 铁匠铺（B 键）",
			"color": Color(0.80, 0.76, 0.62),
			"action": func(): toggle_build_page(),
		})

	out.append({
		"label": "攻击移动",
		"hint": "沿途遇敌自动交战（F）",
		"color": Color(0.95, 0.72, 0.45),
		"action": func(): _call("request_attack_move"),
	})
	out.append(_stop_entry())
	if out.size() < COLS * ROWS:
		out.append({
			"label": "驻守",
			"hint": "原地警戒，不追击（H）",
			"color": Color(0.72, 0.82, 0.95),
			"action": func(): _call("request_hold"),
		})
	if out.size() < COLS * ROWS:
		out.append({
			"label": "巡逻",
			"hint": "在当前位置与点击点之间往返（点地面）",
			"color": Color(0.95, 0.85, 0.55),
			"action": func(): _call("request_patrol"),
		})
	return out


## 训练按钮
func _train_entry(b: RtsBuilding, id: StringName) -> Dictionary:
	var d: UnitDef = Cfg.unit(id)
	var label: String = d.display_name if d != null else String(id)
	var cost: String = "%d金" % d.gold_cost if d != null else ""
	if d != null and d.wood_cost > 0:
		cost += " %d木" % d.wood_cost
	var ok: bool = d != null and Game.can_afford(Game.player_faction, id)
	return {
		"label": label,
		"hint": "%s  花费 %s  人口 %d  训练 %.0fs" % [
			label, cost, d.food_cost if d != null else 0, d.train_time if d != null else 0.0
		],
		"color": Color(0.90, 0.90, 0.86) if ok else Color(0.55, 0.55, 0.52),
		"disabled": not ok or b.train_queue.size() >= 5,
		"action": func(): _call("request_train", id),
	}


## 建造按钮
func _build_entry(bid: StringName) -> Dictionary:
	var d: UnitDef = Cfg.unit(bid)
	var ok: bool = d != null and Game.can_afford(Game.player_faction, bid)
	return {
		"label": d.display_name if d != null else String(bid),
		"hint": "建造 %s：%d金 %d木，占地 %d×%d" % [
			d.display_name if d != null else "建筑",
			d.gold_cost if d != null else 0,
			d.wood_cost if d != null else 0,
			d.footprint.x if d != null else 0,
			d.footprint.y if d != null else 0,
		],
		"color": Color(0.78, 0.92, 0.72) if ok else Color(0.55, 0.55, 0.52),
		"disabled": cmd_missing(),
		"action": func(): _call("request_build", bid),
	}


## 技能按钮
func _ability_entry(ab: StringName) -> Dictionary:
	var label: String = "火球术 1" if ab == &"fireball" else String(ab)
	return {
		"label": label,
		"hint": "%s（数字键）" % label,
		"color": Color(0.72, 0.80, 1.0),
		"action": func(): _call("request_ability", ab),
	}


## 停止按钮
func _stop_entry() -> Dictionary:
	return {
		"label": "停止",
		"hint": "取消当前指令（X）",
		"color": Color(0.95, 0.70, 0.60),
		"action": func(): _call("request_stop"),
	}


## 造一个按钮：深底 + 1px 边 + **左侧一条 3px 的分类色**（训练/建造/攻击一眼分得开）
func _make_button(e: Dictionary) -> Button:
	var btn := Button.new()
	btn.text = String(e.get("label", "?"))
	btn.tooltip_text = String(e.get("hint", ""))
	btn.custom_minimum_size = BTN_SIZE
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.add_theme_font_size_override("font_size", 15)
	var col: Color = e.get("color", Color(0.9, 0.9, 0.86))
	var disabled: bool = bool(e.get("disabled", cmd_missing()))
	btn.disabled = disabled

	if disabled:
		btn.add_theme_stylebox_override("normal", _btn_style(
				Color(0.062, 0.068, 0.078, 0.90), Color(0.34, 0.34, 0.34, 0.32), 0.0))
	else:
		btn.add_theme_stylebox_override("normal", _btn_style(
				Color(0.098, 0.110, 0.136, 0.96), Color(col.r, col.g, col.b, 0.50), col))
		btn.add_theme_stylebox_override("hover", _btn_style(
				Color(0.170, 0.192, 0.232, 0.99), Color(col.r, col.g, col.b, 0.95), col))
		btn.add_theme_stylebox_override("pressed", _btn_style(
				Color(0.290, 0.245, 0.150, 0.99), _accent(), _accent()))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", col)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	btn.add_theme_color_override("font_pressed_color", _accent())
	btn.add_theme_color_override("font_disabled_color", Color(0.50, 0.50, 0.48))
	var act: Variant = e.get("action", null)
	if act is Callable and not btn.disabled:
		btn.pressed.connect(act as Callable)
	return btn


## 统一造一个按钮底色盒；stripe 不是 null 时左边加一条分类色
func _btn_style(bg: Color, border: Color, stripe) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.corner_detail = 6
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	if stripe is Color:
		var c := stripe as Color
		sb.border_width_left = 3
		sb.border_color = border
		# 左侧分类色：用 bg 的左边框色表达（StyleBoxFlat 只有一个 border_color，
		# 所以分类色靠"左边加宽 + 颜色整体偏该色"来实现）
		sb.bg_color = bg.lerp(Color(c.r, c.g, c.b, bg.a), 0.10)
	return sb


# ===========================================================================
# 工具
# ===========================================================================

## 主色（配置没起来时也有兜底色）
func _accent() -> Color:
	return Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)


## 指令系统不在（主场景没装起来）就整卡禁用
func cmd_missing() -> bool:
	return command_system == null or not is_instance_valid(command_system)


## 调用指令系统的方法（参数可选）
func _call(method: String, arg: Variant = null) -> void:
	if cmd_missing():
		return
	if arg == null:
		command_system.call(method)
	else:
		command_system.call(method, arg)


## 第一个有效建筑
func _first_building() -> RtsBuilding:
	for u in _selection:
		var b := u as RtsBuilding
		if b != null and b.is_alive():
			return b
	return null


## 第一个有效单位（非建筑）
func _first_unit() -> RtsUnit:
	for u in _selection:
		var r := u as RtsUnit
		if r != null and not (r is RtsBuilding) and r.is_alive():
			return r
	return null


## 选中的有没有农民
func _has_worker() -> bool:
	for u in _selection:
		var r := u as RtsUnit
		# 同 指令系统：用 RtsWorld.is_worker_def，避免战斗单位被当成农民
		if r != null and RtsWorld.is_worker_def(r.def):
			return true
	return false
