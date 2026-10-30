class_name RtsCommandCard
extends Control
## **命令卡（HAWKEYE）**：右下角固定的 4 列 × 3 行指令格（魔兽 3 的肌肉记忆版式）。
##
## 这一版重做的重点（任务书 §3.2）：
##   1. **格子在，不留大片空白**：永远铺满 12 格，没内容的位置是"暗格"而不是黑洞；
##      未选中时整块换成"怎么玩"的引导卡（三条操作提示 + 快捷键图例）。
##   2. **按钮像按钮**：每格 = 分类色 glyph 方块 + 名称 + 快捷键角标 + 一行花费/状态，
##      禁用态整格压暗并写明原因（缺钱 / 队列满 / 未完工），tooltip 给完整说明。
##   3. **8px 栅格**：标题 24、分隔线 1、正文行高 8 的倍数、格间距 6~8。
##   4. **状态实时**：建造/训练/研究按钮的可用性由 sync_states() 每 0.12s 就地刷新，
##      不重建控件（重建会打断悬停与 tooltip）。
##
## 只负责"按下去把请求转给指令系统"，**不做任何玩法判定**（判定在 CommandSystem）。
## 文字/颜色/字号统一走 界面规格.gd，不在这里自己发明。

const Spec := preload("res://代码/界面/界面规格.gd")

## 网格 4 列 × 3 行
const COLS := 4
const ROWS := 3
const SLOTS := COLS * ROWS
## 训练队列最多画几格
const QUEUE_PIPS := 5
## 格子边长（触屏 ≥76；HUD 按分辨率注入 76/80/84）
## 2026-10-23：格子从 80 收到 58（触屏拇指区仍够点），配合"贴右下角 + 行数自适应"，
## 让命令卡再也不吃屏幕中央。
## 命令条按钮高度（手游拇指区）
const BTN_H := 54.0
const TILE_DEFAULT := 58.0
const TILE_MIN := 46.0
## 命令卡标题行 / 页脚高度（原 34/16 太厚）
const HEAD_H := 28.0
const FOOT_H := 14.0

## 指令系统（HUD 注入）
var command_system: Node = null

## 当前选中
var _selection: Array = []
## 是否切到"建造页"
var _build_page: bool = false

# --- 控件 ---
var _title: Label = null
## 命令条容器（自动换行）
var _flow: HFlowContainer = null
var _page_chip: PanelContainer = null
var _page_label: Label = null
var _queue_row: HBoxContainer = null
var _queue_pips: Array[Panel] = []
var _rule: ColorRect = null
var _body: Control = null
var _grid: GridContainer = null
var _hint: PanelContainer = null
var _hint_title: Label = null
var _hint_rows: VBoxContainer = null
var _hint_keys: Label = null
var _footer: Label = null

## 当前这一页的按钮条目（含 state 回调，供就地刷新）
var _entries: Array = []
## 小屏模式（<1280 宽）：藏掉副行，把纵向空间全给名称
var _compact: bool = false
## 格子边长（HUD 注入）
var _tile: float = TILE_DEFAULT


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(240.0, BTN_H)

	# 2026-10-23：命令卡从"4×3 图标网格"改成**一排文字按钮**（手游思路）。
	# 参照图里就是面板正下方一条"攻击移动、驻守、观察、停止"的横条 ——
	# 图标格子远看只剩方块，文字反而一眼读懂；HFlowContainer 自动换行，
	# 指令多的时候才折第二行，不再永远占着 3 行 12 格。
	_flow = HFlowContainer.new()
	_flow.name = "命令条"
	_flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flow.add_theme_constant_override("h_separation", 6)
	_flow.add_theme_constant_override("v_separation", 6)
	_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flow.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flow.offset_left = 4.0
	_flow.offset_right = -4.0
	_flow.offset_top = 2.0
	_flow.offset_bottom = -2.0
	add_child(_flow)


## 小屏：藏副行（文字按钮上本来只写名字，这里只影响字号）
func set_compact(on: bool) -> void:
	if _compact == on:
		return
	_compact = on
	refresh(_selection)


## 卡片宽度由 HUD 注入（与选中面板同宽）
func set_tile(_px: float) -> void:
	pass


func _rows() -> int:
	if _entries.is_empty():
		return 1
	# 按可用宽度估行数：每个按钮约 104px + 6 间距
	# 96px 一格：宽度 280~300 时 3 个一行，6 条指令正好两行；
	# 文字按钮实际最小宽 ~88，96 不会挤。
	var avail_w: float = maxf(size.x, custom_minimum_size.x)
	avail_w = maxf(avail_w, 240.0)
	var per_row: int = maxi(1, int(floor((avail_w + 6.0) / 96.0)))
	return clampi(int(ceil(float(_entries.size()) / float(per_row))), 1, 3)


## 命令条期望高度：按钮行数 × 行高 + 间距 + 内边距
func desired_height() -> float:
	var rows: int = _rows()
	return float(rows) * BTN_H + float(rows - 1) * 6.0 + 16.0


func refresh(units: Array) -> void:
	_selection = units.duplicate()
	for c in _flow.get_children():
		_flow.remove_child(c)
		c.queue_free()
	_entries.clear()
	for e in _build_entries():
		var btn := _make_button(e)
		_flow.add_child(btn)
		_entries.append({"entry": e, "btn": btn, "sub": e.get("sub", "")})
	if _title != null:
		_title.text = _title_text()
	sync_states()


func sync_states() -> void:
	for rec in _entries:
		var e: Dictionary = rec["entry"]
		var btn: Button = rec["btn"]
		var disabled: bool = bool(e.get("disabled", cmd_missing()))
		var sub: String = String(e.get("sub", ""))
		var sub_col: Color = Spec.text_dim()
		var fn: Variant = e.get("state", null)
		if fn is Callable:
			var st: Dictionary = (fn as Callable).call()
			if st.has("disabled"):
				disabled = bool(st["disabled"])
			if st.has("sub"):
				sub = String(st["sub"])
			if st.has("sub_color"):
				sub_col = st["sub_color"]
		if btn.disabled != disabled:
			btn.disabled = disabled
			_style_button(btn, e, disabled)
		var sl: Label = btn.get_node_or_null("副行") as Label
		if sl != null:
			if sl.text != sub:
				sl.text = sub
			if rec.get("sub_col") != sub_col:
				rec["sub_col"] = sub_col
				sl.add_theme_color_override("font_color", sub_col)
		# 禁用时整格压暗（含 glyph/名称/角标）
		var dim: float = 0.52 if disabled else 1.0
		if not is_equal_approx(float(rec.get("dim", -1.0)), dim):
			rec["dim"] = dim
			for c in btn.get_children():
				if c is CanvasItem:
					(c as CanvasItem).modulate = Color(dim, dim, dim, 1.0)


## B 键：在"常用页"和"建造页"之间切换
func toggle_build_page() -> void:
	_build_page = not _build_page
	refresh(_selection)


## 当前是否在建造页
func is_build_page() -> bool:
	return _build_page


## 进入建造页（命令卡第一格「建造」和 B 键都走这里；重复调用安全）
func enter_build_page() -> void:
	if not _build_page:
		_build_page = true
	refresh(_selection)


## 当前选择能不能进建造页（自检的唯一判据：选中里有农民）
func can_enter_build_page() -> bool:
	return _has_worker()


## 建造页里列出的建筑 id（顺序即按钮顺序；界面与自检共用这一份）
func build_page_ids() -> Array:
	return [&"farm", &"barracks", &"tower", &"blacksmith"]


# ===========================================================================
# 内容
# ===========================================================================

func _title_text() -> String:
	if _selection.is_empty():
		return "指挥面板"
	var b := _first_building()
	if b != null and b.def != null:
		var extra: String = "" if b.train_queue.is_empty() else " · 队列 %d" % b.train_queue.size()
		if b.is_researching():
			extra += " · 研究中 %d%%" % int(clampf(b.research_progress(), 0.0, 1.0) * 100.0)
		return "%s%s" % [b.def.display_name, extra]
	var u := _first_unit()
	if u != null and u.def != null:
		var n: String = "" if _selection.size() <= 1 else " ×%d" % _selection.size()
		return "%s%s" % [u.def.display_name, n]
	return "未选中"


func _footer_text() -> String:
	if _build_page:
		return "左键点地面放置 · R 转 90° · 右键取消 · 再按 B 返回"
	return "F 攻击移动 · X 停止 · H 驻守 · B 建造菜单"


func _update_page_chip() -> void:
	if _page_chip != null:
		_page_chip.visible = _build_page


## 训练队列小格（有几格亮几格）
func _update_queue() -> void:
	var b := _first_building()
	var n: int = b.train_queue.size() if b != null else 0
	for i in _queue_pips.size():
		_queue_pips[i].visible = i < n


## 根据选中内容拼出按钮条目
func _build_entries() -> Array:
	var out: Array = []
	if _selection.is_empty():
		return out

	# --- 1. 建筑：训练 / 研究 / 取消 ---
	var b := _first_building()
	if b != null and b.def != null:
		for id in b.def.trains:
			out.append(_train_entry(b, id))
		for rid in b.def.researches:
			out.append(_research_entry(b, rid))
		# 集结点：建筑面板已瘦成信息条，入口收在这里（魔兽式的右键语义也保留）
		if not b.def.trains.is_empty() or b.def.is_dropoff:
			out.append({
				"label": "集结点",
				"hint": "左键点地面设置集结点（右键取消）",
				"color": Color(0.92, 0.80, 0.52),
				"glyph": "集",
				"icon": "flag",
				"hotkey": "",
				"sub": "点地面",
				"action": func(): _call("request_set_rally"),
			})
		if not b.train_queue.is_empty():
			out.append({
				"label": "取消训练",
				"hint": "退掉队列里的最后一个并退款",
				"color": Color(0.95, 0.62, 0.35),
				"glyph": "退",
				"icon": "cancel",
				"sub": "退最后一格",
				"action": func(): _call("request_cancel_train"),
			})
		out.append(_stop_entry())
		return out

	var worker := _has_worker()
	var unit := _first_unit()

	# --- 2. 建造页（或农民选中时顺便给建造快捷键）---
	if _build_page and worker:
		for bid in build_page_ids():
			out.append(_build_entry(bid))
		out.append({
			"label": "返回",
			"hint": "回到常用指令（或再按 B）",
			"color": Color(0.75, 0.75, 0.72),
			"glyph": "返",
			"icon": "return",
			"sub": "常用指令",
			"hotkey": "B",
			"action": func(): toggle_build_page(),
		})
		return out

	# --- 3. 技能 ---
	if unit != null and unit.def != null:
		for ab in unit.def.abilities:
			out.append(_ability_entry(ab))

	# --- 4. 常备指令 ---
	if worker:
		# 农民必须有一个"看得见"的建造入口：B 键能切页，但第一级界面上没有入口时，
		# 玩家会以为农民根本不能造东西。
		# **第一级只留「建造」这一格**：以前这里还直出「农场」「兵营」两格，
		# 结果是农民的常用指令条被建筑按钮挤掉，界面层级混乱。
		# 建筑一律进"建造"展开页（enter_build_page），一层只做一件事。
		out.append({
			"label": "建造",
			"hint": "打开建造菜单：农场 / 兵营 / 箭塔 / 铁匠铺（B 键）",
			"color": Color(0.82, 0.94, 0.74),
			"glyph": "建",
			"icon": "hammer",
			"hotkey": "B",
			"sub": "展开 4 种建筑",
			"action": func(): enter_build_page(),
		})

	out.append({
		"label": "攻击移动",
		"hint": "沿途遇敌自动交战（F）",
		"color": Color(0.95, 0.72, 0.45),
		"glyph": "攻",
		"icon": "attack_move",
		"hotkey": "F",
		"sub": "沿途接敌",
		"action": func(): _call("request_attack_move"),
	})
	out.append({
		"label": "驻守",
		"hint": "原地警戒，不追击（H）",
		"color": Color(0.72, 0.82, 0.95),
		"glyph": "驻",
		"icon": "shield",
		"hotkey": "H",
		"sub": "原地警戒",
		"action": func(): _call("request_hold"),
	})
	out.append({
		"label": "路径",
		"hint": "在当前位置与点击点之间往返（路径巡逻）",
		"color": Color(0.95, 0.85, 0.55),
		"glyph": "路",
		"icon": "flag",
		"sub": "两点往返",
		"action": func(): _call("request_patrol"),
	})
	out.append({
		"label": "观察",
		"hint": "原地观察，不主动出击（观察 = 原地警戒）",
		"color": Color(0.66, 0.84, 0.84),
		"glyph": "观",
		"icon": "shield",
		"sub": "原地观察",
		"action": func(): _call("request_hold"),
	})
	out.append(_stop_entry())
	out.append({
		"label": "自由部署",
		"hint": "点地面把队伍部署过去（自由移动）",
		"color": Color(0.82, 0.86, 0.66),
		"glyph": "自",
		"icon": "move",
		"sub": "点地移动",
		"action": func(): _call("request_move"),
	})
	return out


## 训练按钮
func _train_entry(b: RtsBuilding, id: StringName) -> Dictionary:
	var d: UnitDef = Cfg.unit(id)
	var label: String = d.display_name if d != null else String(id)
	var cost: String = _cost_text(d)
	var ok: bool = d != null and Game.can_afford(Game.player_faction, id)
	var full: bool = b.train_queue.size() >= 5
	return {
		"label": label,
		"hint": "%s  花费 %s  人口 %d  训练 %.0fs" % [
			label, cost, d.food_cost if d != null else 0, d.train_time if d != null else 0.0
		],
		"color": Color(0.90, 0.90, 0.86) if ok else Color(0.55, 0.55, 0.52),
		"glyph": label.substr(0, 1),
		"icon": _icon_for_unit(id),
		"sub": cost,
		"disabled": (not ok) or full or (not b.is_constructed),
		"state": func() -> Dictionary:
			var afford: bool = d != null and Game.can_afford(Game.player_faction, id)
			var q_full: bool = b.train_queue.size() >= 5
			var built: bool = b.is_constructed
			var sub: String = cost
			var col: Color = Spec.text_dim()
			if not built:
				sub = "未完工"
				col = Color(0.95, 0.70, 0.45)
			elif q_full:
				sub = "队列已满"
				col = Color(0.95, 0.70, 0.45)
			elif not afford:
				sub = _shortage(d)
				col = Color(0.95, 0.52, 0.42)
			return {"disabled": (not afford) or q_full or (not built), "sub": sub, "sub_color": col},
		"action": func(): _call("request_train", id),
	}


## 研究按钮（铁匠铺）：显示当前等级 / 满级，研究进行中或资源不够就禁用
func _research_entry(b: RtsBuilding, rid: StringName) -> Dictionary:
	var rd: ResearchDef = Cfg.research(rid)
	var lv: int = RtsCombat.research_level(Game.player_faction, rid)
	var max_lv: int = maxi(rd.max_level, 1) if rd != null else 0
	var name: String = rd.display_name if rd != null else String(rid)
	var label: String = name
	var busy: bool = b.is_researching()
	var maxed: bool = lv >= max_lv
	var built: bool = b.is_constructed
	var afford: bool = rd != null and Game.player_faction != null \
			and Game.player_faction.gold >= rd.gold_cost \
			and Game.player_faction.wood >= rd.wood_cost
	var hint: String = ""
	if rd != null:
		hint = "%s  升级 %d→%d  花费 %d金 %d木  研究 %.0fs" % [
			rd.description, lv, mini(lv + 1, max_lv), rd.gold_cost, rd.wood_cost, rd.research_time
		]
	if not built:
		hint += "（建筑还没完工）"
	elif busy:
		hint += "（研究进行中）"
	elif maxed:
		hint += "（已满级）"
	return {
		"label": label,
		"hint": hint,
		"color": Color(0.72, 0.86, 1.0) if afford and not maxed and built else Color(0.55, 0.55, 0.52),
		"glyph": "研",
		"icon": "upgrade",
		"sub": "lv %d/%d" % [lv, max_lv],
		"disabled": not built or busy or maxed or not afford,
		"state": func() -> Dictionary:
			var busy2: bool = b.is_researching()
			var maxed2: bool = RtsCombat.research_level(Game.player_faction, rid) >= max_lv
			var afford2: bool = rd != null and Game.player_faction != null \
					and Game.player_faction.gold >= rd.gold_cost \
					and Game.player_faction.wood >= rd.wood_cost
			var lv2: int = RtsCombat.research_level(Game.player_faction, rid)
			var sub: String = "lv %d/%d" % [lv2, max_lv]
			var col: Color = Spec.text_dim()
			if not b.is_constructed:
				sub = "未完工"
				col = Color(0.95, 0.70, 0.45)
			elif maxed2:
				sub = "已满级"
				col = Color(0.62, 0.86, 0.62)
			elif busy2:
				sub = "研究中"
				col = Color(0.72, 0.86, 1.0)
			elif not afford2:
				sub = "资源不足"
				col = Color(0.95, 0.52, 0.42)
			return {"disabled": (not b.is_constructed) or busy2 or maxed2 or (not afford2),
					"sub": sub, "sub_color": col},
		"action": func(): _call("request_research", rid),
	}


## 建造按钮
func _build_entry(bid: StringName) -> Dictionary:
	var d: UnitDef = Cfg.unit(bid)
	var ok: bool = d != null and Game.can_afford(Game.player_faction, bid)
	return {
		"label": d.display_name if d != null else String(bid),
		"hint": "建造 %s：%d金 %d木，占地 %d×%d（放置时 R 转向）" % [
			d.display_name if d != null else "建筑",
			d.gold_cost if d != null else 0,
			d.wood_cost if d != null else 0,
			d.footprint.x if d != null else 0,
			d.footprint.y if d != null else 0,
		],
		"color": Color(0.78, 0.92, 0.72) if ok else Color(0.55, 0.55, 0.52),
		"glyph": (d.display_name if d != null else "建").substr(0, 1),
		"icon": _icon_for_building(bid),
		"sub": _cost_text(d),
		"disabled": cmd_missing() or (not ok),
		"state": func() -> Dictionary:
			var afford: bool = d != null and Game.can_afford(Game.player_faction, bid)
			return {"disabled": cmd_missing() or (not afford),
					"sub": _cost_text(d) if afford else _shortage(d),
					"sub_color": Spec.text_dim() if afford else Color(0.95, 0.52, 0.42)},
		"action": func(): _call("request_build", bid),
	}


## 技能按钮
func _ability_entry(ab: StringName) -> Dictionary:
	var label: String = "火球术" if ab == &"fireball" else String(ab)
	return {
		"label": label,
		"hint": "%s（Q / 1）" % label,
		"color": Color(0.72, 0.80, 1.0),
		"glyph": label.substr(0, 1),
		"icon": "fire" if ab == &"fireball" else "staff",
		"hotkey": "Q",
		"sub": "范围伤害",
		"action": func(): _call("request_ability", ab),
	}


## 停止按钮
func _stop_entry() -> Dictionary:
	return {
		"label": "停止",
		"hint": "取消当前指令（X）",
		"color": Color(0.95, 0.70, 0.60),
		"glyph": "停",
		"icon": "stop",
		"hotkey": "X",
		"sub": "取消指令",
		"action": func(): _call("request_stop"),
	}


# ===========================================================================
# 格子
# ===========================================================================

## 造一个指令格：Button（吃输入/悬停/tooltip）+ 四个只读子控件（图标/角标/名称/副行）
## 一个文字按钮：图标 + 名称（横向），高度 44，宽度按文字自适应
func _make_button(e: Dictionary) -> Button:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	# 118 宽 = 【图标 24 + 6 间距 + 4 个中文字 64】+ 左右内边距 20。
	# 以前 96 宽装不下「攻击移动」四个字，字直接顶出按钮边缘。
	btn.custom_minimum_size = Vector2(118.0, BTN_H)
	# 不要 EXPAND：HFlow 里一 EXPAND 就变成"一条一个按钮"，6 条指令竖着排出屏幕。
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.tooltip_text = String(e.get("hint", ""))
	btn.text = ""

	var col: Color = e.get("color", Spec.text_main())
	btn.set_meta("col", col)

	var row := HBoxContainer.new()
	row.name = "行"
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10.0
	row.offset_right = -10.0
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(row)

	var tex: Texture2D = _icon_tex(String(e.get("icon", "")))
	if tex != null:
		var tr := TextureRect.new()
		tr.name = "图标"
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(24.0, 24.0)
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.modulate = Color(col.r, col.g, col.b, 0.96)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(tr)

	# 字号统一 FS_BODY：之前紧凑版用 FS_SUB、宽版用 FS_BODY，
	# 同一排按钮字号不一致，看着像"大小不一"。
	var lb := Spec.label(String(e.get("label", "?")), Spec.FS_BODY, Spec.text_main())
	lb.name = "名称"
	lb.clip_text = false
	lb.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lb)

	_style_button(btn, e, bool(e.get("disabled", cmd_missing())))

	var act: Variant = e.get("action", null)
	if act is Callable:
		btn.pressed.connect(act as Callable)
	return btn


## 按钮底色：深墨 + 分类色描边（和原来的格子同一套语言，只是变横条）
func _style_button(btn: Button, e: Dictionary, disabled: bool) -> void:
	var col: Color = btn.get_meta("col", Spec.text_main())
	btn.add_theme_stylebox_override("normal",
			Spec.button_style(Color(0.115, 0.125, 0.152, 0.96),
					Color(col.r, col.g, col.b, 0.38), col, 7, 10.0, 4.0))
	btn.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.185, 0.200, 0.240, 0.98),
					Color(col.r, col.g, col.b, 0.92), col, 7, 10.0, 4.0))
	btn.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.300, 0.250, 0.150, 0.99), col, col, 7, 10.0, 4.0))
	btn.add_theme_stylebox_override("disabled",
			Spec.button_style(Color(0.082, 0.086, 0.096, 0.92),
					Color(0.34, 0.34, 0.34, 0.26), null, 7, 10.0, 4.0))
	btn.add_theme_color_override("font_color", Spec.text_main())
	btn.add_theme_color_override("font_disabled_color", Color(0.50, 0.50, 0.48))
	var nm := btn.get_node_or_null("行/名称") as Label
	if nm != null:
		nm.add_theme_color_override("font_color", col.lerp(Color(1, 1, 1), 0.55) if not disabled
				else Color(0.52, 0.52, 0.50))


func _fill_hint() -> void:
	for c in _hint_rows.get_children():
		_hint_rows.remove_child(c)
		c.queue_free()

	if _selection.is_empty():
		_hint_title.text = "操作"
		# 图标 + 四字以内：原来四行"左键点选，拖框群选己方部队"这种整句，
		# 玩家原话是"文字太多"——图标能表达的一律不写字。
		_add_hint_row("move", "左键选择", Spec.accent())
		_add_hint_row("attack_move", "右键下令", Color(0.95, 0.72, 0.45))
		_add_hint_row("hammer", "B 建造", Color(0.82, 0.94, 0.74))
		_add_hint_row("return", "空格回中", Color(0.62, 0.78, 0.96))
		_hint_keys.text = "选中部队后显示技能"
	else:
		_hint_title.text = "无可用指令"
		_add_hint_row("attack_move", "右键下令", Color(0.95, 0.72, 0.45))
		_add_hint_row("move", "左键换选", Spec.accent())
		_hint_keys.text = "资源点只能采集"


func _add_hint_row(icon_name: String, text: String, col: Color) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_rows.add_child(row)

	var key := PanelContainer.new()
	key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	key.custom_minimum_size = Vector2(22.0, 22.0)
	key.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(col.r, col.g, col.b, 0.14), 3, Color(col.r, col.g, col.b, 0.45), 0.0, 0.0))
	row.add_child(key)
	var holder := Spec.icon(icon_name, 22.0, col)
	key.add_child(holder)

	var lb := Spec.label(text, Spec.FS_BODY, Spec.text_sub())
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lb.clip_text = true
	row.add_child(lb)


# ===========================================================================
# 工具
# ===========================================================================

## 花费文案："135金" / "130金 15木"
func _cost_text(d: UnitDef) -> String:
	if d == null:
		return ""
	var cost: String = ""
	if d.gold_cost > 0:
		cost = "%d金" % d.gold_cost
	if d.wood_cost > 0:
		cost = (cost + " ") if cost != "" else ""
		cost += "%d木" % d.wood_cost
	return cost


## 差多少资源（禁用原因，比"资源不足"更有用）
func _shortage(d: UnitDef) -> String:
	var fac := Game.player_faction
	if d == null or fac == null:
		return "资源不足"
	var miss_g: int = maxi(d.gold_cost - fac.gold, 0)
	var miss_w: int = maxi(d.wood_cost - fac.wood, 0)
	return "缺 %d金 %d木" % [miss_g, miss_w]


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


# ===========================================================================
# 图标（美术/图标/*.svg，64px 矢量，按按钮主色着色）
# ===========================================================================

## 图标纹理缓存：同一个 SVG 只 load 一次
static var _icon_cache: Dictionary = {}

const ICON_DIR := "res://美术/图标/"

static func _icon_tex(name: String) -> Texture2D:
	if name.is_empty():
		return null
	if _icon_cache.has(name):
		return _icon_cache[name] as Texture2D
	var path := ICON_DIR + name + ".svg"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_icon_cache[name] = tex
	return tex


## 单位 → 图标
static func _icon_for_unit(id: StringName) -> String:
	match id:
		&"peasant":
			return "hammer"
		&"footman":
			return "sword"
		&"archer":
			return "bow"
		&"mage":
			return "staff"
	return ""


## 建筑 → 图标
static func _icon_for_building(id: StringName) -> String:
	match id:
		&"farm":
			return "house"
		&"barracks":
			return "tower"
		&"tower":
			return "tower"
		&"blacksmith":
			return "anvil"
		&"townhall":
			return "flag"
	return "house"