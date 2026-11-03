class_name RtsCommandCard
extends Control
## **命令卡（HAWKEYE）**：底栏右侧的 **4 列 × 最多 3 行** 指令格（魔兽 3 的肌肉记忆版式）。
##
## 2026-10-31 重排：
##   上一版是"一条能自动折行的横排文字按钮"，指令一多就折成 2~3 行，
##   宽度还跟着屏宽乱跑 —— 和左边的选中卡既不等高、也不成形状。
##   现在固定 **4 列网格**（魔兽的 3×4 指令格），格子等宽等高、从左上往右下填，
##   整块贴在底栏右段里；行数由指令条数决定（≤4 一条、5~8 两条、9~12 三条）。
##
## 每格仍然是「图标 + 中文名 + 快捷键角标 + 副行（造价/状态）」：
## 只放图标的话远看全是小方块（上一版就是被这么否掉的），
## 纯文字又没有"格"的秩序感 —— 两者合起来才是既有秩序又能读懂。
##
## 只负责"按下去把请求转给指令系统"，**不做任何玩法判定**（判定在 CommandSystem）。
## 文字/颜色/字号统一走 界面规格.gd，不在这里自己发明。

const Spec := preload("res://代码/界面/界面规格.gd")
const Lex := preload("res://代码/界面/词条.gd")
const Frame := preload("res://代码/界面/按钮框.gd")
## 建筑改造（哨塔→箭塔）：和 指令系统 / AI 共用同一份价格与实现
const UPGRADE := preload("res://代码/系统/建筑改造.gd")

## 网格列数。2026-11-01 第七版：**5 列 → 4 列**。
## 5 列时单格只有 112px，图标 + 中文名 + 副行挤成一坨（玩家："还很挤的感觉"）；
## 4 列后单格 142px（底座总宽不变），图标放大、行距放松，
## 才是魔兽那种"一格一件事"的操作面板。
const COLS := 4
## 最多几行（超出的指令不再显示）
const MAX_ROWS := 4
## 训练队列最多画几格
const QUEUE_PIPS := 5
## 训练队列上限（与 指令系统.TRAIN_QUEUE_MAX / 建筑面板.QUEUE_MAX 同口径）
const QUEUE_MAX := 10
## 命令条按钮高度（HUD 会按分辨率覆盖）
const BTN_H := 56.0

## 指令系统（HUD 注入）
var command_system: Node = null

## 当前选中
var _selection: Array = []
## 是否切到"建造页"
var _build_page: bool = false

# --- 控件 ---
## 网格容器（4 列；每格一行指令）
var _grid: GridContainer = null
## 网格外面那层纵向容器：只负责"行数少于 3 时把格子垂直居中"
var _wrap: VBoxContainer = null

## 当前这一页的按钮条目（含 state 回调，供就地刷新）
var _entries: Array = []
## 小屏模式（<1280 宽）：藏掉副行，把纵向空间全给名称
var _compact: bool = false
## 格子宽度（HUD 注入 = 界面规格.tile）
var _tile: float = 126.0
## 格子高度（HUD 注入 = 界面规格.card_btn_h；≤0 时退回 BTN_H）
var _btn_h_px: float = 0.0


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(240.0, BTN_H)

	# 4 列网格（魔兽版式）。外面套一层 VBox 只做一件事：
	# 指令只有 3~4 条时，让这一行格子**垂直居中**在段里，
	# 而不是贴着顶边、底下空出一大块（那正是"一边低一边高"的另一种长相）。
	_wrap = VBoxContainer.new()
	_wrap.name = "居中"
	_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	_wrap.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_wrap)

	_grid = GridContainer.new()
	_grid.name = "指令格"
	_grid.columns = COLS
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_wrap.add_child(_grid)


## 小屏：藏副行（造价/状态那行），把高度让给名称
func set_compact(on: bool) -> void:
	if _compact == on:
		return
	_compact = on
	refresh(_selection)


## 格子尺寸由 HUD 注入（宽 = 界面规格.tile，高 = card_btn_h；4 格 + 间距 = 段宽）
func set_tile(px: float, px_h: float = 0.0) -> void:
	var h: float = px_h if px_h > 0.0 else _btn_h()
	if absf(px - _tile) < 0.5 and absf(h - _btn_h_px) < 0.5:
		return
	_tile = px
	_btn_h_px = h
	for rec in _entries:
		var btn: Button = rec["btn"]
		if btn != null and is_instance_valid(btn):
			btn.custom_minimum_size = Vector2(_tile, _btn_h())


## 一行放几条：固定 4 列（魔兽），不再按宽度猜
func _per_row() -> int:
	return COLS


func _rows() -> int:
	if _entries.is_empty():
		return 1
	return clampi(int(ceil(float(_entries.size()) / float(COLS))), 1, MAX_ROWS)


## 一行/两行/三行的实际高度（外带一层 8px 内边距，与段底的 pad 对齐）
func _btn_h() -> float:
	return BTN_H if _btn_h_px <= 0.0 else _btn_h_px


func desired_height() -> float:
	var rows: int = _rows()
	return float(rows) * _btn_h() + float(rows - 1) * 10.0 + 22.0


func refresh(units: Array) -> void:
	_selection = units.duplicate()
	if _grid != null:
		for c in _grid.get_children():
			_grid.remove_child(c)
			c.queue_free()
	_entries.clear()
	for e in _build_entries():
		var btn := _make_button(e)
		_grid.add_child(btn)
		_entries.append({"entry": e, "btn": btn, "sub": e.get("sub", "")})
	sync_states()


func sync_states() -> void:
	for rec in _entries:
		var e: Dictionary = rec["entry"]
		var btn: Button = rec["btn"]
		if btn == null or not is_instance_valid(btn):
			continue
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
		var sl: Label = btn.find_child("副行", true, false) as Label
		if sl != null:
			if sl.text != sub:
				sl.text = sub
			if rec.get("sub_col") != sub_col:
				rec["sub_col"] = sub_col
				sl.add_theme_color_override("font_color", sub_col)
			# 小屏只留名字，副行整行收起（不是"字号变小"，是干脆不占高度）
			sl.visible = not _compact
		# 禁用时整格压暗（含图标/名称/角标）
		var dim: float = 0.55 if disabled else 1.0
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
## 10 条 = 5 列网格的整 2 行，正好一屏放得下，不用翻页。
## ★ 新增建筑一定要加到这里，否则农民建不了它（编辑器能摆、玩家点不出来）。
##   2026-11-01 新增 `campfire`（营火）：夜里照明用，玩家口径明确要求农民能造。
##   2026-11-03 2C-6 新增 `townhall`（大本营）：卡已有成本（320 金 / 125 木），
##     **玩家可建**；AI 不自动建（`简单AI.can_build_townhall()` 固定 false，扩张线下一轮接入）。
func build_page_ids() -> Array:
	return [&"farm", &"barracks", &"tower", &"watchtower",
		&"blacksmith", &"sanctum", &"workshop", &"lumbercamp", &"campfire",
		&"townhall"]


# ===========================================================================
# 内容
# ===========================================================================
# 说明：原先这里有一批 `_title_text / _footer_text / _update_page_chip /
# `_update_queue / _fill_hint / _add_hint_row`，它们的控件（标题行、页脚、
# 队列小格、操作引导卡）在上一版就**没有再造过**，属于"读起来像活的、其实没人调"
# 的死代码（`_fill_hint` 里还会对 null 的 `_hint_rows` 解引用）。
# 网格版不需要它们：名字/阵营/数量在左边的选中卡里，队列在建筑面板里，
# 键位提示在每格的快捷键角标 + tooltip 里。整段删除，别再长回来。


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
		# 取消：**当前**训练 / 研究（玩家 2026-11-01 口径）。
		# 想退队列里的某一条，直接点中段队列那一格（建筑面板里）。
		var researching: bool = false
		if b.has_method("is_researching"):
			researching = bool(b.is_researching())
		if not b.train_queue.is_empty() or researching:
			out.append({
				"label": "取消",
				"hint": "取消**当前**正在训练的单位（或正在研究的项目），全额退款。\n要退队列里的某一条，直接点中段那一格。",
				"color": Color(0.95, 0.62, 0.35),
				"glyph": "退",
				"icon": "cancel",
				"sub": "退当前那条",
				"action": func(): _call("request_cancel_train"),
			})
		# ★ 能攻击的建筑（箭塔）：**操作面板也要把攻/射程/视野写出来**。
		#   玩家口径："这种能攻击的建筑，操作面板和信息面板要显示对应的信息"。
		#   做成不可点的信息格（disabled），不假装成一个能按的按钮。
		if b.def.can_attack():
			out.append({
				"label": "攻击",
				"hint": "%s 自动射击：%.0f 伤害 / %.1f 秒 · 射程 %.0fm · 视野 %.0fm" % [
					b.def.display_name, b.def.attack_damage, b.def.attack_cooldown,
					b.def.attack_range, b.def.sight_range],
				"color": Color(0.98, 0.62, 0.42),
				"glyph": "攻",
				"icon": "sword",
				"sub": "%.0f伤 · %.0fm" % [b.def.attack_damage, b.def.attack_range],
				"disabled": true,
			})
		elif b.def.sight_range >= 18.0:
			# 只给"存在意义就是看"的楼（哨塔 20m）加这一格；大本营 15m 也是副产品，不算。
			# 兵营/农场也有一点视野（12m），但那是副产品，摆一格"视野"只会把
			# 真正的操作格（训练/研究/集结点）挤出第一屏。
			out.append({
				"label": "视野",
				"hint": "%s 没有攻击能力，只提供 %.0fm 视野与 %.0fm 预警" % [
					b.def.display_name, b.def.sight_range, b.def.detect_radius],
				"color": Color(0.66, 0.86, 0.92),
				"glyph": "视",
				"icon": "eye",
				"sub": "%.0fm · 无攻击" % b.def.sight_range,
				"disabled": true,
			})
		# **哨塔 → 箭塔**（玩家口径 2026-11-01："多余哨塔升级箭塔加强防御"）。
		# 做成可点按钮（不是信息格）：花不花这笔钱是玩家的决定。
		# 价格/实现都走 代码/系统/建筑改造.gd —— 和 AI 自动升级完全同一套口径。
		if b.def.id == &"watchtower":
			var uc: Vector2i = UPGRADE.upgrade_cost(&"watchtower", &"tower")
			out.append({
				"label": "升级",
				"hint": "把这座哨塔改造成箭塔（只补差价 %d 金 / %d 木）。\n改造后：%.0f 伤害 · %.0fm 射程；视野从 %.0fm 降到 12m。\n血量按当前比例继承，不能当回血手段。" % [
					uc.x, uc.y,
					float(Cfg.unit(&"tower").attack_damage if Cfg.unit(&"tower") != null else 0.0),
					float(Cfg.unit(&"tower").attack_range if Cfg.unit(&"tower") != null else 0.0),
					b.def.sight_range],
				"color": Color(0.96, 0.72, 0.42),
				"glyph": "升",
				"icon": "upgrade",
				"sub": "%d金 %d木" % [uc.x, uc.y],
				"hotkey": "",
				"action": func(): _call("request_upgrade_tower"),
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

	# --- 3. 常备指令（顺序 = 参考图：移动 驻守 攻击 路径 观察 / 停止）---
	out.append({
		"label": "移动",
		"hint": "点地面把队伍部署过去（自由移动）",
		"color": Color(0.82, 0.86, 0.66),
		"glyph": "移",
		"icon": "move",
		"sub": "点地移动",
		"action": func(): _call("request_move"),
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
		"label": "攻击",
		"hint": "攻击移动：沿途遇敌自动交战（F）",
		"color": Color(0.95, 0.72, 0.45),
		"glyph": "攻",
		"icon": "attack_move",
		"hotkey": "F",
		"sub": "沿途接敌",
		"action": func(): _call("request_attack_move"),
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
		"hint": "原地观察，不主动出击（观察 = 原地警戒，头顶会挂观察图标）",
		"color": Color(0.66, 0.84, 0.84),
		"glyph": "观",
		"icon": "eye",
		"sub": "原地观察",
		"action": func(): _call("request_observe"),
	})
	# --- 4. 第二行：停止 → 技能 → 建造 ---
	out.append(_stop_entry())

	if unit != null and unit.def != null:
		for ab in unit.def.abilities:
			out.append(_ability_entry(ab))

	if worker:
		# 农民必须有一个"看得见"的建造入口：B 键能切页，但第一级界面上没有入口时，
		# 玩家会以为农民根本不能造东西。建筑一律进"建造"展开页，一层只做一件事。
		out.append({
			"label": "修理",
			"hint": "左键点一栋**己方受损建筑**修理（按血量扣木材；伐木场研究「修缮工艺」后省一半）",
			"color": Color(0.86, 0.78, 0.56),
			"glyph": "修",
			"icon": "hammer",
			"sub": "点受损建筑",
			"action": func(): _call("request_repair"),
		})
		out.append({
			"label": "建造",
			"hint": "打开建造菜单：农场 / 兵营 / 箭塔 / 哨塔 / 铁匠铺 / 神秘圣地 / 蒸汽车坊 / 伐木场 / 营火 / 大本营（B 键）",
			"color": Color(0.82, 0.94, 0.74),
			"glyph": "建",
			"icon": "hammer",
			"hotkey": "B",
			"sub": "展开 10 种建筑",
			"action": func(): enter_build_page(),
		})
	return out


## 训练按钮
func _train_entry(b: RtsBuilding, id: StringName) -> Dictionary:
	var d: UnitDef = Cfg.unit(id)
	var label: String = d.display_name if d != null else String(id)
	var cost: String = _cost_text(d)
	var ok: bool = d != null and Game.can_afford(Game.player_faction, id)
	# ★ 队列上限只有一处口径（指令系统.TRAIN_QUEUE_MAX = 10）。
	#   这里以前写死 5，于是"面板说队列 6/10，命令卡却已经禁用了"——玩家只会觉得是 bug。
	var full: bool = b.train_queue.size() >= QUEUE_MAX
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
			var q_full: bool = b.train_queue.size() >= QUEUE_MAX
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
		"hint": "建造 %s：%d金 %d木，占地 %d×%d（朝向统一，不需要转向）" % [
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
#
# 一格的构成（魔兽式"铭牌"读法）：
#   ┌────────────────────────────┐
#   │ [图标]  名称            ⌨F │   ← 名称 14 号 + 右上角快捷键小牌
#   │         135金 15木          │   ← 副行 12 号（造价 / 状态 / 禁用原因）
#   └────────────────────────────┘
# 左上一条 3px 分类色条（button_style 的 stripe）+ 顶亮底暗的压边（bevel）。
# 图标 **不许省**：只有文字的格子远看是四块灰砖，只有图标的格子远看是四个方块，
# 两样都得有。

## 一格指令的说明文本：标题 + 快捷键 + 说明 + **当下的**状态（禁用原因/造价）
## `state` 是每 0.12s 刷新的回调，所以"资源不足"这类理由永远是此刻的。
func _tip_of(e: Dictionary) -> Dictionary:
	var sub: String = String(e.get("sub", ""))
	var sub_col: Color = e.get("sub_color", Spec.text_dim())
	var disabled: bool = false
	var st: Variant = e.get("state", null)
	if st is Callable:
		var fn: Callable = st
		if fn.is_valid():
			var d: Dictionary = fn.call()
			if d.has("sub"):
				sub = String(d.get("sub", ""))
				sub_col = d.get("sub_color", sub_col)
			disabled = bool(d.get("disabled", false))
	var body: String = String(e.get("hint", ""))
	if not sub.is_empty():
		body += "\n" + sub
	if disabled:
		body += "\n[color=#e08878]现在按不了：条件不满足。[/color]"
	var icon: String = String(e.get("icon", "gear"))
	if icon.begins_with("建筑/"):
		icon = "house"
	var hot: String = String(e.get("hotkey", ""))
	if not hot.is_empty():
		hot = "[%s]" % hot
	return {
		"icon": icon,
		"icon_color": e.get("color", Spec.text_main()),
		"title": String(e.get("label", "")),
		"tag": hot,
		"body": body,
		"foot": "点一下执行" if not disabled else "",
	}


func _make_button(e: Dictionary) -> Button:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	# 名字带上指令名：验收脚本（--qa-hover=指令_攻击）和调试都要找得到它
	btn.name = "指令_" + String(e.get("label", "?"))
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.custom_minimum_size = Vector2(_tile, _btn_h())
	# 4 列等分：EXPAND_FILL 让每格吃掉 1/4 宽度，格子边界永远对齐
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	# 说明文本走**自己的气泡层**（带标题/副标/富文本），不用引擎 tooltip：
	# 引擎那套不吃 root 的 1/zoom 反拉伸，小窗上字号会和面板打架。
	# 这里留一个空 tooltip_text，避免两套气泡同时弹。
	btn.tooltip_text = ""
	RtsTipLayer.bind(self, btn, func() -> Dictionary: return _tip_of(e))
	btn.text = ""

	var col: Color = e.get("color", Spec.text_main())
	btn.set_meta("col", col)

	# --- 石金外框（自绘）：压在 stylebox 之上、内容之下 ---
	# 顺序很重要：先加框 → 再加内容行，后者才画在前面。
	var frame := Frame.new()
	frame.name = "石金框"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.tint = col
	btn.add_child(frame)

	var row := HBoxContainer.new()
	row.name = "行"
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14.0
	row.offset_right = -8.0
	row.offset_top = 6.0
	row.offset_bottom = -6.0
	row.add_theme_constant_override("separation", 9)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(row)

	# --- 图标（建筑渲图给 36：一格 142px 宽，够放；线条图标 28）---
	var tex: Texture2D = _icon_tex(String(e.get("icon", "")))
	if tex != null:
		var is_bld: bool = String(e.get("icon", "")).begins_with("建筑/")
		var tr := TextureRect.new()
		tr.name = "图标"
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var isz: float = 38.0 if is_bld else 28.0
		tr.custom_minimum_size = Vector2(isz, isz)
		tr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		# 建筑渲图本身带颜色：保持原色（禁用时的整体压暗由 _refresh 里统一做）
		if is_bld:
			tr.modulate = Color(1, 1, 1, 1)
		else:
			tr.modulate = Color(col.r, col.g, col.b, 0.98)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(tr)

	# --- 文字列：名称 + 副行 ---
	var col_box := VBoxContainer.new()
	col_box.name = "文字列"
	col_box.add_theme_constant_override("separation", 0)
	col_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col_box)

	var lb := Spec.label(String(e.get("label", "?")), Spec.FS_SUB, Spec.text_main())
	lb.name = "名称"
	lb.clip_text = true
	lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_box.add_child(lb)

	var sub := Spec.label(String(e.get("sub", "")), Spec.FS_CAPTION, Spec.text_dim())
	sub.name = "副行"
	sub.clip_text = true
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.visible = not _compact and not String(e.get("sub", "")).is_empty()
	col_box.add_child(sub)

	# --- 快捷键角标：**绝对定位到右上角**，不占文字行的宽度 ---
	# 之前把它塞进 HBox 里，四字指令（攻击移动）直接被挤成"攻击移…"。
	var hk: String = String(e.get("hotkey", ""))
	if not hk.is_empty():
		var key := PanelContainer.new()
		key.name = "键位"
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		key.offset_left = -24.0
		key.offset_top = 4.0
		key.offset_right = -5.0
		key.offset_bottom = 21.0
		key.add_theme_stylebox_override("panel",
				Spec.inset_style(Color(0.02, 0.02, 0.025, 0.72), 3,
						Color(col.r, col.g, col.b, 0.55), 3.0, 0.0))
		var kl := Spec.label(hk, Spec.FS_CAPTION, col.lerp(Color(1, 1, 1), 0.40),
				HORIZONTAL_ALIGNMENT_CENTER)
		kl.add_theme_font_override("font", Spec.mono_font())
		key.add_child(kl)
		btn.add_child(key)
		# 给右上角让出 26px：文字列右侧再收一点，避免和角标叠字
		row.offset_right = -26.0

	# 悬停/按下由框自己回答：引擎的 stylebox 四态只用来接事件，不画东西
	btn.mouse_entered.connect(func() -> void:
		if not btn.disabled:
			frame.look = Frame.Look.HOVER)
	btn.mouse_exited.connect(func() -> void:
		if not btn.disabled:
			frame.look = Frame.Look.NORMAL)
	btn.button_down.connect(func() -> void:
		if not btn.disabled:
			frame.look = Frame.Look.PRESSED)
	btn.button_up.connect(func() -> void:
		if not btn.disabled:
			frame.look = Frame.Look.HOVER)

	_style_button(btn, e, bool(e.get("disabled", cmd_missing())))

	var act: Variant = e.get("action", null)
	if act is Callable:
		btn.pressed.connect(act as Callable)
	return btn


## 按钮四态：**石金外框自己画**（见 按钮框.gd），这里只做三件事：
##   1. 把引擎的四个 stylebox 全部换成"空"（否则会在框里再铺一层深灰方块）；
##   2. 把状态转告给框（悬停/按下/禁用）；
##   3. 按分类色给名称上色（禁用时压到 0.52 明度，但**仍然读得清为什么不能点**）。
func _style_button(btn: Button, e: Dictionary, disabled: bool) -> void:
	var col: Color = btn.get_meta("col", Spec.text_main())
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "disabled"]:
		btn.add_theme_stylebox_override(st, empty)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", Spec.text_main())
	btn.add_theme_color_override("font_disabled_color", Color(0.50, 0.50, 0.48))

	var frame := btn.find_child("石金框", false, false) as RtsButtonFrame
	if frame != null:
		frame.tint = col
		frame.look = Frame.Look.DISABLED if disabled else Frame.Look.NORMAL

	var nm := btn.find_child("名称", true, false) as Label
	if nm != null:
		nm.add_theme_color_override("font_color",
				col.lerp(Color(1, 1, 1), 0.62) if not disabled else Color(0.52, 0.52, 0.50))


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

## 图标纹理缓存：同一个图标只 load 一次
## 支持两种资源：SVG 线条图标（`美术/图标/*.svg`）与建筑渲图（`美术/图标/建筑/*.png`），
## 建筑名写成 `建筑/<id>`，例如 `建筑/barracks`。
static var _icon_cache: Dictionary = {}

const ICON_DIR := "res://美术/图标/"

static func _icon_tex(name: String) -> Texture2D:
	if name.is_empty():
		return null
	if _icon_cache.has(name):
		return _icon_cache[name] as Texture2D
	# 先找 PNG（建筑渲图 `建筑/<id>.png`），再退回 SVG 线条图标
	var tex: Texture2D = null
	if ResourceLoader.exists(ICON_DIR + name + ".png"):
		tex = load(ICON_DIR + name + ".png") as Texture2D
	elif ResourceLoader.exists(ICON_DIR + name + ".svg"):
		tex = load(ICON_DIR + name + ".svg") as Texture2D
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
		&"steam_guard":
			return "anvil"
	return ""


## 建筑 → 图标：**用美术资产里的建筑渲图**（`美术/图标/建筑/<id>.png`），
## 一座楼一张，建造栏和信息面板头像共用；渲染不出来才退回通用 SVG。
static func _icon_for_building(id: StringName) -> String:
	if Spec.building_icon(id) != null:
		return "建筑/" + String(id)
	# 兜底（新增建筑但还没渲图标时）：
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
		&"watchtower":
			return "eye"
		&"sanctum":
			return "staff"
		&"workshop":
			return "gear"
		&"lumbercamp":
			return "wood"
		&"campfire":
			return "fire"
	return "house"