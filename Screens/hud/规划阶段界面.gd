extends Control
## **规划阶段界面（Planning HUD，2026-11-15 第二版：按玩家草图重排）**
##
## 草图（玩家给的两张图）里只有六块东西，别的一律不许有：
##
##   ┌───────────────────────────────────────────────────────────────────┐
##   │ ┌──┐  ┌──────────────────────────────────────────┐      ┌───────┐ │
##   │ │头│  │ [金币] 145   [卷轴][卷轴][卷轴]   (☀/☾)  │      │ 16/30 │ │
##   │ │像│  └──────────────────────────────────────────┘      └───────┘ │
##   │ └──┘                                                            │
##   │ 600/1000                                                        │
##   │                                                                 │
##   │ ◇ 3/3                                     ┌────────────┐ ┌────┐ │
##   │                                           │ 操作面板    │ │结束│ │
##   │                                           └────────────┘ └────┘ │
##   │                                                          ┌────┐ │
##   │                                                          │取消│ │
##   └───────────────────────────────────────────────────────────────────┘
##
## 硬口径（玩家逐条点过名）：
##   ① **不许把小地图 / 小地图下面的指令条 / 金币木头那条资源栏搬进来** ——
##      规划阶段是一张"作战台"，不是执行阶段的 HUD；
##   ② 位置按图：头像+血量在左上、金币/卷轴/日月在顶部一条**带底的横条**里、
##      人口在右上、CP 菱形在左下、操作面板在底部居中、规划结束/取消在右下（方形按钮 + 左侧文字）；
##   ③ **不写图里没有的文字**：没有标题、没有副标题、没有脚注、没有"局外资源/短局不用/
##      基地不可修理/世界已冻结"这类说明。要解释的放**悬停气泡**（`RtsTipLayer`）；
##   ④ 图标不许用 24px 线描 SVG 放大：单位/建筑用渲染图，命令类用 `徽记.gd` 的暗铁徽记。
##
## 对外（HUD / 自检）：
##   setup(hud, map_layer)   注入宿主与地图层
##   apply_rects(dict)       唯一摆放出口（HUD._place_planning_hud 调）
##   desired_h()             当前形态下操作面板想要的高度（窗口变化时 HUD 用它算 CP/右列）
##   refresh()               每 0.12s 调一次（内部按签名重建，不每帧 new 控件）
##   is_active() / set_active(on)

const Spec := preload("res://Screens/hud/界面规格.gd")
const 徽记 := preload("res://Screens/hud/徽记.gd")
const DT := preload("res://Game/commands/部署类型.gd")
const 可用性查询 := preload("res://Game/config/可用性查询.gd")
const 可用性文案 := preload("res://Game/config/可用性文案.gd")

## 规划结束（HUD 接住：调回合控制 begin_execution）
signal plan_end_pressed
## 取消（HUD 接住：先撤部署/落点，再撤最后一条计划）
signal cancel_pressed
## 操作面板换了形态 / 高度变了（HUD 接住后重摆一次）
signal layout_dirty

## 底部面板的四种形态
enum Act {
	NONE = 0,     ## 什么都没选（面板收起，屏幕干净）
	DEPLOY = 1,   ## 选中部队 → 进攻/防守/占据
	TRAIN = 2,    ## 选中建筑 → 训练卡
	BUILD = 3,    ## 选中农民 → 建造卡
}

## 头像方框边长
const PORTRAIT := 92.0
## 顶部横条高度
const TOPBAR_H := 62.0
## 右下两个方形按钮边长 / 间距
const BTN := 88.0
const BTN_GAP := 10.0
## 三种形态下操作面板的高度
const H_NONE := 0.0
const H_DEPLOY := 132.0
const H_TRAIN := 152.0
const H_BUILD := 178.0
## 部署按钮 / 训练卡 / 建造卡尺寸
const DEPLOY_W := 116.0
const DEPLOY_H := 96.0
const CARD_W := 92.0
const CARD_H := 112.0
## 建造卡宽：图标(34) + 名字/成本两行；104 会把"人口 0"截掉（2026-11-15 截图实测）。
const BCARD_W := 122.0
const BCARD_H := 68.0
## 法术卷轴槽位
const SLOT := 42.0
const SLOT_GAP := 6.0

var _hud: Node = null
var _map_layer: Control = null
var _deploy_input: Node = null
var _cmd: Node = null

# --- 左上：头像 + 基地血量 ---
var _portrait: Panel = null
var _portrait_tex: TextureRect = null
var _hp: Label = null

# --- 顶部：金币 / 卷轴 / 日月（一条带底的横条包住它们）---
var _topbar: PanelContainer = null
var _gold: Label = null
var _slots: Control = null
var _dial: DayDial = null

# --- 右上：人口 ---
var _pop: PanelContainer = null
var _pop_label: Label = null

# --- 左下：CP 菱形 ---
var _cp: CpDiamond = null

# --- 底部：操作面板（只放卡片/按钮，没有标题和脚注）---
var _action: PanelContainer = null
var _act_body: HBoxContainer = null

# --- 右下：规划结束 / 取消（方块按钮 + 左侧文字）---
var _end_btn: Button = null
var _end_label: Label = null
var _cancel_btn: Button = null
var _cancel_label: Label = null

var _act_mode: int = Act.NONE
var _deploy_btns: Array = []
var _sig: String = ""
## 上一次上报的高度（变化时才 layout_dirty，避免刷新把 HUD 拖进每帧重摆）
var _h_reported: float = -1.0


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "规划阶段界面"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()


func setup(hud: Node, map_layer: Control) -> void:
	_hud = hud
	_map_layer = map_layer


func is_active() -> bool:
	return visible


## 操作面板的屏幕矩形（规划地图层算"明牌意图"安全区 / HUD 摆落点提示用）
func action_global_rect() -> Rect2:
	if _action == null or not is_instance_valid(_action):
		return Rect2()
	return _action.get_global_rect()


## 当前形态下面板想要的高度（HUD 先用它算 CP 与右列的位置，再 apply_rects）
## ★ 面板被主动收起时（没选中 / 建筑没有训练项）返回 0：不然 CP 与右列会被
##   一块**不存在**的面板顶到半空去。
func desired_h() -> float:
	if _action != null and not _action.visible:
		return 0.0
	match _act_mode:
		Act.DEPLOY:
			return H_DEPLOY
		Act.TRAIN:
			return H_TRAIN
		Act.BUILD:
			return H_BUILD
	return 0.0


## 部署输入当前模式（0 = 空闲）。HUD 点兵牌前先问它：部署模式吃左键，别抢。
func deploy_mode() -> int:
	var di := _deploy_node()
	return int(di.call("mode")) if di != null and di.has_method("mode") else 0


## 选中一组实体（走选择系统的唯一入口；HUD 点兵牌也调这里）。
func select_units(list: Array) -> bool:
	var ss := _selection_node()
	if ss == null or not ss.has_method("select_units"):
		return false
	ss.call("select_units", list)
	return true


## 当前形态下面板想要的**最小宽度**。
## 建造页是 5 列 × 104 + 间距 + 内边距；面板被压窄时 GridContainer 会把卡片
## 挤成 90 出头（图标糊、字贴边），所以这里把"内容真实需要的宽"报给 HUD。
func desired_w() -> float:
	match _act_mode:
		Act.BUILD:
			return BCARD_W * 5.0 + 8.0 * 4.0 + 32.0
		Act.DEPLOY:
			return DEPLOY_W * 3.0 + 8.0 * 2.0 + 32.0
		Act.TRAIN:
			return CARD_W * 3.0 + 8.0 * 2.0 + 32.0
	return 0.0


func set_active(on: bool) -> void:
	if visible == on:
		return
	visible = on
	if on:
		_sig = ""
	if _map_layer != null and is_instance_valid(_map_layer):
		# ★ 地图层**不跟着一起硬切**：进规划淡入、出规划淡出（玩家要求过渡不突兀）
		if on:
			_map_layer.call("appear")
			_map_layer.call("set_zoom", _zoom())
		else:
			_map_layer.call("dismiss")
	if not on:
		# 离开规划阶段：把部署状态一并收掉（否则执行阶段还挂着一个"点哪都不生效"的模式）
		var di := _deploy_node()
		if di != null and di.has_method("cancel"):
			di.call("cancel")


## HUD 统一摆位：{portrait, topbar, pop, cp, action, right_col}
func apply_rects(r: Dictionary) -> void:
	_put(_portrait, r.get("portrait", Rect2()))
	var pr: Rect2 = r.get("portrait", Rect2())
	if _hp != null and pr.size.x > 1.0:
		# 血量数字挂在头像正下方（草图：方框下面一行 600/1000）
		_hp.position = Vector2(pr.position.x - 14.0, pr.end.y + 1.0)
		_hp.size = Vector2(pr.size.x + 28.0, 22.0)
	_put(_topbar, r.get("topbar", Rect2()))
	_put(_pop, r.get("pop", Rect2()))
	_put(_cp, r.get("cp", Rect2()))
	_put(_action, r.get("action", Rect2()))
	var col: Rect2 = r.get("right_col", Rect2())
	if _end_btn != null:
		_end_btn.position = col.position
		_end_btn.size = Vector2(col.size.x, BTN)
	if _cancel_btn != null:
		_cancel_btn.position = col.position + Vector2(0.0, BTN + BTN_GAP)
		_cancel_btn.size = Vector2(col.size.x, BTN)
	# 文字在按钮左侧、右对齐（草图：规划结束 → 方块 / 取消 → 方块）
	if _end_label != null:
		_end_label.position = col.position + Vector2(-148.0, 0.0)
		_end_label.size = Vector2(136.0, BTN)
	if _cancel_label != null:
		_cancel_label.position = col.position + Vector2(-148.0, BTN + BTN_GAP)
		_cancel_label.size = Vector2(136.0, BTN)


func _put(c: Control, r: Rect2) -> void:
	if c == null or not is_instance_valid(c):
		return
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		if c is CanvasItem:
			c.visible = false
		return
	c.visible = true
	c.position = r.position
	c.size = r.size


func _zoom() -> float:
	if _hud != null and is_instance_valid(_hud):
		return float(_hud.get("_zoom"))
	return 1.0


# ===========================================================================
# 构建
# ===========================================================================

func _build() -> void:
	_build_portrait()
	_build_topbar()
	_build_pop()
	_build_cp()
	_build_action()
	_build_right_column()


## 左上：玩家头像（大本营渲图）+ 基地血量数字
func _build_portrait() -> void:
	_portrait = Panel.new()
	_portrait.name = "玩家头像"
	_portrait.mouse_filter = Control.MOUSE_FILTER_PASS
	_portrait.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.045, 0.052, 0.066, 0.96), 10,
					Color(0.92, 0.76, 0.40, 0.72), 3.0, 3.0))
	add_child(_portrait)

	_portrait_tex = TextureRect.new()
	_portrait_tex.texture = Spec.building_icon(&"townhall")
	_portrait_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait_tex.offset_left = 4.0
	_portrait_tex.offset_top = 4.0
	_portrait_tex.offset_right = -4.0
	_portrait_tex.offset_bottom = -4.0
	_portrait.add_child(_portrait_tex)

	_hp = Spec.label("0/0", Spec.FS_VALUE, Spec.text_main(), HORIZONTAL_ALIGNMENT_CENTER)
	_hp.add_theme_font_override("font", Spec.mono_font())
	add_child(_hp)

	RtsTipLayer.bind(self, _portrait, func() -> Dictionary: return _portrait_tip())
	RtsTipLayer.bind(self, _hp, func() -> Dictionary: return _portrait_tip())


## 顶部：一条暗底横条包住 [金币 数量] [法术卷轴 ×3] [日月]
func _build_topbar() -> void:
	_topbar = PanelContainer.new()
	_topbar.name = "顶部条"
	_topbar.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := Spec.inset_style(Color(0.045, 0.052, 0.066, 0.94), 12,
			Color(0.92, 0.76, 0.40, 0.55), 14.0, 6.0)
	_topbar.add_theme_stylebox_override("panel", sb)
	add_child(_topbar)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 10)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	_topbar.add_child(hb)

	# 金币：图标 + 数值（草图里没有"金币"两个字，也没有木头）
	var coin := _emblem("coin", 30.0, Spec.gold())
	hb.add_child(coin)
	_gold = Spec.label("0", Spec.FS_VALUE, Spec.text_main())
	_gold.add_theme_font_override("font", Spec.mono_font())
	_gold.custom_minimum_size = Vector2(56.0, 0.0)
	hb.add_child(_gold)
	RtsTipLayer.bind(self, _gold, func() -> Dictionary: return _gold_tip())
	RtsTipLayer.bind(self, coin, func() -> Dictionary: return _gold_tip())

	# 三格法术卷轴（当前没有卷轴系统 → 空格子，只作版面占位，不写任何字）
	_slots = SpellSlots.new()
	_slots.name = "法术卷轴"
	_slots.custom_minimum_size = Vector2(SLOT * 3.0 + SLOT_GAP * 2.0, SLOT)
	_slots.mouse_filter = Control.MOUSE_FILTER_PASS
	hb.add_child(_slots)
	RtsTipLayer.bind(self, _slots, func() -> Dictionary: return _slot_tip())

	# 日月圆盘（规划阶段静止；悬停显示时间与执行阶段时长）
	_dial = DayDial.new()
	_dial.name = "日夜"
	_dial.custom_minimum_size = Vector2(52.0, 52.0)
	_dial.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dial.mouse_filter = Control.MOUSE_FILTER_PASS
	hb.add_child(_dial)
	RtsTipLayer.bind(self, _dial, func() -> Dictionary: return _dial_tip())


## 右上：人口图标 + 已用/上限
func _build_pop() -> void:
	_pop = PanelContainer.new()
	_pop.name = "人口"
	_pop.mouse_filter = Control.MOUSE_FILTER_PASS
	_pop.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.045, 0.052, 0.066, 0.94), 12,
					Color(0.92, 0.76, 0.40, 0.55), 12.0, 6.0))
	add_child(_pop)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 8)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	_pop.add_child(hb)
	var icon := _emblem("pop", 26.0, Spec.food())
	hb.add_child(icon)
	_pop_label = Spec.label("0/0", Spec.FS_VALUE, Spec.text_main())
	_pop_label.add_theme_font_override("font", Spec.mono_font())
	hb.add_child(_pop_label)
	RtsTipLayer.bind(self, _pop, func() -> Dictionary: return _pop_tip())


## 左下：CP 菱形
func _build_cp() -> void:
	_cp = CpDiamond.new()
	_cp.name = "CP点"
	_cp.mouse_filter = Control.MOUSE_FILTER_STOP
	_cp.tooltip_text = ""
	add_child(_cp)
	_cp.gui_input.connect(_on_cp_input)
	RtsTipLayer.bind(self, _cp, func() -> Dictionary: return _cp_tip())


## 底部：操作面板（只有一个内容行；形态由选中对象决定）
func _build_action() -> void:
	_action = PanelContainer.new()
	_action.name = "规划操作面板"
	_action.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := Spec.inset_style(Color(0.040, 0.047, 0.060, 0.95), 14,
			Color(0.92, 0.76, 0.40, 0.62), 16.0, 12.0)
	sb.border_width_top = 2
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0.0, 3.0)
	_action.add_theme_stylebox_override("panel", sb)
	add_child(_action)

	_act_body = HBoxContainer.new()
	_act_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_act_body.add_theme_constant_override("separation", 8)
	_act_body.alignment = BoxContainer.ALIGNMENT_CENTER
	_act_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_action.add_child(_act_body)


## 右下：规划结束（上）/ 取消（下）——方形按钮 + 左侧右对齐文字
func _build_right_column() -> void:
	_end_btn = Button.new()
	_end_btn.name = "规划结束"
	_end_btn.focus_mode = Control.FOCUS_NONE
	_end_btn.tooltip_text = ""
	_skin_square(_end_btn, true)
	_draw_emblem_child(_end_btn, "play", Color(1.0, 0.86, 0.44), 44.0)
	RtsTipLayer.bind(self, _end_btn, func() -> Dictionary: return _end_tip())
	_end_btn.pressed.connect(func() -> void: plan_end_pressed.emit())
	add_child(_end_btn)

	_end_label = Spec.label("规划结束", Spec.FS_VALUE, Color(1.0, 0.96, 0.86),
			HORIZONTAL_ALIGNMENT_RIGHT)
	_end_label.name = "规划结束字"
	_end_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_end_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_end_label.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
				and (ev as InputEventMouseButton).pressed:
			plan_end_pressed.emit())
	add_child(_end_label)

	_cancel_btn = Button.new()
	_cancel_btn.name = "取消"
	_cancel_btn.focus_mode = Control.FOCUS_NONE
	_cancel_btn.tooltip_text = ""
	_skin_square(_cancel_btn, false)
	_draw_emblem_child(_cancel_btn, "undo", Color(0.86, 0.90, 0.98), 38.0)
	RtsTipLayer.bind(self, _cancel_btn, func() -> Dictionary: return _cancel_tip())
	_cancel_btn.pressed.connect(func() -> void: cancel_pressed.emit())
	add_child(_cancel_btn)

	_cancel_label = Spec.label("取消", Spec.FS_VALUE, Spec.text_sub(),
			HORIZONTAL_ALIGNMENT_RIGHT)
	_cancel_label.name = "取消字"
	_cancel_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_cancel_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_cancel_label.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
				and (ev as InputEventMouseButton).pressed:
			cancel_pressed.emit())
	add_child(_cancel_label)


## 方按钮的底：结束=暖金（高权重），取消=冷铁（低权重）
func _skin_square(btn: Button, primary: bool) -> void:
	var face := Color(0.30, 0.22, 0.08, 0.98) if primary else Color(0.085, 0.095, 0.115, 0.96)
	var edge := Color(1.0, 0.86, 0.44, 0.95) if primary else Color(0.62, 0.68, 0.78, 0.42)
	btn.add_theme_stylebox_override("normal",
			Spec.button_style(face, edge, null, 12, 4.0, 4.0, 2 if primary else 1))
	btn.add_theme_stylebox_override("hover",
			Spec.button_style(face.lightened(0.16), edge.lightened(0.10), null, 12,
				4.0, 4.0, 2 if primary else 1))
	btn.add_theme_stylebox_override("pressed",
			Spec.button_style(face.darkened(0.12), Color(1.0, 0.94, 0.66, 1.0), null, 12,
				4.0, 4.0, 2))
	btn.add_theme_stylebox_override("disabled",
			Spec.button_style(Color(0.08, 0.08, 0.09, 0.9), Color(0.35, 0.34, 0.32, 0.4),
				null, 12, 4.0, 4.0))


## 在 Button 里居中放一枚自绘徽记（Button 自己没法 _draw，就挂一个穿透的 Control）
func _draw_emblem_child(btn: Button, kind: String, col: Color, px: float) -> void:
	var holder := EmblemHolder.new()
	holder.kind = kind
	holder.col = col
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.position = Vector2((BTN - px) * 0.5, (BTN - px) * 0.5)
	holder.size = Vector2(px, px)
	btn.add_child(holder)


# ===========================================================================
# 每 0.12s 刷新
# ===========================================================================

func refresh() -> void:
	if not visible:
		return
	var pl := Game.player_faction
	_sync_portrait(pl)
	_sync_topbar(pl)
	_sync_pop(pl)
	_sync_cp(pl)
	_sync_action(pl)
	_sync_buttons()
	var h: float = desired_h()
	if not is_equal_approx(h, _h_reported):
		_h_reported = h
		layout_dirty.emit()


func _sync_portrait(pl: RtsFaction) -> void:
	if _hp == null:
		return
	var base: RtsBuilding = _main_base(pl)
	if base != null and base.def != null:
		var hp: float = maxf(base.hp, 0.0)
		var mx: float = maxf(base.def.max_hp, 1.0)
		_hp.text = "%d/%d" % [int(ceil(hp)), int(ceil(mx))]
		_hp.add_theme_color_override("font_color",
				Color(0.98, 0.50, 0.42) if hp / mx < 0.34 else Spec.text_main())
	else:
		_hp.text = "0/0"
		_hp.add_theme_color_override("font_color", Color(0.98, 0.46, 0.40))


func _sync_topbar(pl: RtsFaction) -> void:
	if pl == null:
		return
	if _gold != null:
		_gold.text = "%d" % pl.gold
	if _dial != null:
		var dn := _day_night()
		var night: bool = false
		var hour: float = 12.0
		if dn != null:
			night = bool(dn.call("is_night"))
			hour = float(dn.call("hour")) if dn.has_method("hour") else 12.0
		_dial.set_state(night, hour, false)


func _sync_pop(pl: RtsFaction) -> void:
	if _pop_label == null or pl == null:
		return
	var used: int = pl.food_committed()
	var cap: int = pl.food_cap()
	_pop_label.text = "%d/%d" % [used, cap]
	_pop_label.add_theme_color_override("font_color",
			Color(0.98, 0.56, 0.46) if cap > 0 and used >= cap else Spec.text_main())


func _sync_cp(pl: RtsFaction) -> void:
	if _cp == null:
		return
	var cp: float = pl.cp if pl != null else 0.0
	var cap: float = pl.cp_cap if pl != null else 0.0
	_cp.set_values(cp, cap)
	_cp.modulate = Color(0.62, 0.60, 0.56, 1.0) if cp < 1.0 else Color(1, 1, 1, 1)


func _sync_action(pl: RtsFaction) -> void:
	if _action == null:
		return
	var sel := _selection()
	var mode: int = Act.NONE
	var sole_b: RtsBuilding = null
	var units: Array = []
	for n in sel:
		if n is RtsBuilding:
			if sole_b == null:
				sole_b = n as RtsBuilding
		elif n is RtsUnit and (n as RtsUnit).is_alive():
			units.append(n)
	if sole_b != null and units.is_empty():
		mode = Act.TRAIN
	elif not units.is_empty():
		var all_workers: bool = true
		for u in units:
			var d: UnitDef = (u as Node).get("def") as UnitDef
			if d == null or not RtsWorld.is_worker_def(d):
				all_workers = false
				break
		mode = Act.BUILD if all_workers else Act.DEPLOY
	_act_mode = mode
	var sig := _signature(mode, sel, sole_b, pl)
	if sig == _sig:
		return
	_sig = sig
	_rebuild_action(mode, sole_b, units, pl)


func _rebuild_action(mode: int, b: RtsBuilding, units: Array, pl: RtsFaction) -> void:
	for c in _act_body.get_children():
		_act_body.remove_child(c)
		c.queue_free()
	_deploy_btns.clear()
	_action.visible = mode != Act.NONE
	match mode:
		Act.DEPLOY:
			_build_deploy(units, pl)
		Act.TRAIN:
			_build_train(b, pl)
		Act.BUILD:
			_build_build(pl)


## 选中部队：三枚部署徽记按钮（按下态 = 正在等落点）
func _build_deploy(_units: Array, _pl: RtsFaction) -> void:
	var specs: Array = [
		[DT.ATTACK, "attack", "进攻", Color(1.0, 0.62, 0.34),
			"把选中的部队派去进攻这个方向/目标。点完在地图上点落点。"],
		[DT.DEFEND, "defend", "防守", Color(0.52, 0.80, 1.0),
			"把选中的部队部署到防区（10m），路上遇敌就交战。"],
		[DT.CAPTURE, "capture", "占据", Color(1.0, 0.84, 0.42),
			"把选中的部队派去占据据点或一片区域；据点驻留 15 秒归你。"],
	]
	for sp in specs:
		var kind: int = int(sp[0])
		var col: Color = sp[3]
		var btn := Button.new()
		btn.name = "部署_" + String(sp[2])
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(DEPLOY_W, DEPLOY_H)
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.tooltip_text = ""
		_skin_deploy(btn, col)
		var icon := EmblemHolder.new()
		icon.kind = String(sp[1])
		icon.col = col
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.position = Vector2((DEPLOY_W - 46.0) * 0.5, 8.0)
		icon.size = Vector2(46.0, 46.0)
		btn.add_child(icon)
		var lb := Spec.label(String(sp[2]), Spec.FS_SUB, Color(0.97, 0.96, 0.92),
				HORIZONTAL_ALIGNMENT_CENTER)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lb.position = Vector2(0.0, DEPLOY_H - 32.0)
		lb.size = Vector2(DEPLOY_W, 24.0)
		btn.add_child(lb)
		RtsTipLayer.bind(self, btn, func() -> Dictionary: return _deploy_tip(kind, String(sp[4])))
		btn.pressed.connect(_on_deploy.bind(kind))
		_act_body.add_child(btn)
		_deploy_btns.append({"kind": kind, "btn": btn})


func _skin_deploy(btn: Button, col: Color) -> void:
	var face := Color(0.075, 0.085, 0.105, 0.97)
	btn.add_theme_stylebox_override("normal",
			Spec.button_style(face, Color(col.r, col.g, col.b, 0.38), null, 10, 4.0, 4.0))
	btn.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.13, 0.15, 0.19, 0.98), Color(col.r, col.g, col.b, 0.85),
				null, 10, 4.0, 4.0))
	btn.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(col.r * 0.28, col.g * 0.28, col.b * 0.28, 0.98),
				Color(col.r, col.g, col.b, 1.0), null, 10, 4.0, 4.0, 2))
	btn.add_theme_stylebox_override("hover_pressed",
			Spec.button_style(Color(col.r * 0.34, col.g * 0.34, col.b * 0.34, 0.98),
				Color(col.r, col.g, col.b, 1.0), null, 10, 4.0, 4.0, 2))


## 选中建筑：训练卡（图标 + 单位名 + CP；人口/时间/介绍走悬停）
func _build_train(b: RtsBuilding, pl: RtsFaction) -> void:
	if b == null or b.def == null:
		_action.visible = false
		return
	if not b.is_constructed:
		# 工地：一枚"取消建造"按钮（进度与剩余时间走悬停，不写屏上文字）
		var cancel := Button.new()
		cancel.name = "取消建造"
		cancel.text = "取消建造"
		cancel.focus_mode = Control.FOCUS_NONE
		cancel.custom_minimum_size = Vector2(148.0, 56.0)
		cancel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		cancel.add_theme_font_size_override("font_size", Spec.FS_BODY)
		cancel.add_theme_color_override("font_color", Color(0.98, 0.82, 0.74))
		cancel.add_theme_stylebox_override("normal",
				Spec.button_style(Color(0.14, 0.10, 0.09, 0.96), Color(0.80, 0.46, 0.36, 0.7),
					null, 8, 10.0, 6.0))
		cancel.add_theme_stylebox_override("hover",
				Spec.button_style(Color(0.22, 0.14, 0.12, 0.98), Color(0.94, 0.58, 0.44, 0.95),
					null, 8, 10.0, 6.0))
		cancel.tooltip_text = ""
		RtsTipLayer.bind(self, cancel, func() -> Dictionary: return _site_tip(b))
		cancel.pressed.connect(func() -> void:
			if b != null and is_instance_valid(b) and b.has_method("cancel_construction"):
				b.call("cancel_construction"))
		_act_body.add_child(cancel)
		return

	if b.def.trains.is_empty():
		# 没有训练项的建筑（农场/塔）：给一句明确反馈，不要静默收起面板
		# （玩家 2026-11-15 报"点建筑没反应"，静默收起就是原因之一。）
		var lb := Spec.label(I18n.t("plan.no_trains"), Spec.FS_BODY, Spec.text_dim(),
				HORIZONTAL_ALIGNMENT_CENTER)
		lb.custom_minimum_size = Vector2(240.0, 0.0)
		_act_body.add_child(lb)
		return

	for id in b.def.trains:
		_act_body.add_child(_train_card(b, id))


func _train_card(b: RtsBuilding, id: StringName) -> Button:
	var d: UnitDef = Cfg.unit(id)
	var res := 可用性查询.train(b, id, Game.player_faction)
	var ok: bool = bool(res.get("ok", false))
	var btn := Button.new()
	btn.name = "训练_" + (d.display_name if d != null else String(id))
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.tooltip_text = ""
	_skin_card(btn, ok)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 5.0
	vb.offset_right = -5.0
	vb.offset_top = 5.0
	vb.offset_bottom = -5.0
	vb.add_theme_constant_override("separation", 2)
	btn.add_child(vb)

	var icon_holder := Control.new()
	icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_holder.custom_minimum_size = Vector2(0.0, 52.0)
	icon_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(icon_holder)
	var tex := Spec.unit_icon(id)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon_holder.add_child(tr)
	else:
		var g := EmblemHolder.new()
		g.kind = "attack"
		g.col = Color(0.92, 0.90, 0.82)
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		g.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon_holder.add_child(g)

	var nm := Spec.label(d.display_name if d != null else String(id), Spec.FS_CAPTION,
			Spec.text_main() if ok else Spec.text_dim(), HORIZONTAL_ALIGNMENT_CENTER)
	nm.clip_text = true
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(nm)
	# 成本只写"CP + 人口"（不写句子）：2026-11-15 玩家要求卡上看 CP 与占人口。
	var cp := Spec.label(I18n.t("plan.card_cost_compact", {
			"cp": d.cp_cost if d != null else 0,
			"pop": d.pop_cost if d != null else 0}), Spec.FS_CAPTION,
			Spec.gold() if ok else Color(0.95, 0.60, 0.48), HORIZONTAL_ALIGNMENT_CENTER)
	cp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(cp)

	btn.disabled = not ok or _cmd_missing()
	if not ok:
		btn.modulate = Color(0.62, 0.62, 0.60, 1.0)
	btn.pressed.connect(func() -> void:
		var cs := _command_node()
		if cs != null and cs.has_method("request_train"):
			cs.call("request_train", id))
	RtsTipLayer.bind(self, btn, func() -> Dictionary: return _train_tip(b, id, ok))
	return btn


## 选中农民：建造卡（5 列 × 2 行）
func _build_build(_pl: RtsFaction) -> void:
	var grid := GridContainer.new()
	grid.columns = 5
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_act_body.add_child(grid)
	for bid in _build_ids():
		grid.add_child(_build_card(bid))


func _build_card(bid: StringName) -> Button:
	var d: UnitDef = Cfg.unit(bid)
	var res := 可用性查询.build(bid, Game.player_faction, true)
	var ok: bool = bool(res.get("ok", false))
	var btn := Button.new()
	btn.name = "建造_" + (d.display_name if d != null else String(bid))
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(BCARD_W, BCARD_H)
	btn.tooltip_text = ""
	_skin_card(btn, ok)
	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 6.0
	hb.offset_right = -6.0
	hb.offset_top = 6.0
	hb.offset_bottom = -6.0
	hb.add_theme_constant_override("separation", 5)
	btn.add_child(hb)

	var icon_holder := Control.new()
	icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_holder.custom_minimum_size = Vector2(34.0, 0.0)
	hb.add_child(icon_holder)
	var tex := Spec.building_icon(bid)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon_holder.add_child(tr)
	else:
		var g := EmblemHolder.new()
		g.kind = "build"
		g.col = Color(0.92, 0.90, 0.82)
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		g.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon_holder.add_child(g)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.add_theme_constant_override("separation", 0)
	hb.add_child(vb)
	var nm := Spec.label(d.display_name if d != null else String(bid), Spec.FS_CAPTION,
			Spec.text_main() if ok else Spec.text_dim(), HORIZONTAL_ALIGNMENT_LEFT)
	nm.clip_text = true
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(nm)
	var cp := Spec.label(I18n.t("plan.card_cost_compact", {
			"cp": d.cp_cost if d != null else 0,
			"pop": d.pop_cost if d != null else 0}), Spec.FS_CAPTION,
			Spec.gold() if ok else Color(0.95, 0.60, 0.48), HORIZONTAL_ALIGNMENT_LEFT)
	cp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(cp)

	btn.disabled = not ok or _cmd_missing()
	if not ok:
		btn.modulate = Color(0.62, 0.62, 0.60, 1.0)
	btn.pressed.connect(func() -> void:
		var cs := _command_node()
		if cs != null and cs.has_method("request_build"):
			cs.call("request_build", bid))
	RtsTipLayer.bind(self, btn, func() -> Dictionary: return _build_tip(bid, ok))
	return btn


func _skin_card(btn: Button, ok: bool) -> void:
	var fill := Color(0.075, 0.085, 0.105, 0.96) if ok else Color(0.065, 0.068, 0.075, 0.92)
	var edge := Color(0.86, 0.72, 0.42, 0.45) if ok else Color(0.42, 0.40, 0.35, 0.35)
	btn.add_theme_stylebox_override("normal", Spec.button_style(fill, edge, null, 8, 4.0, 4.0))
	btn.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.15, 0.17, 0.21, 0.98), Color(0.96, 0.82, 0.48, 0.95),
				null, 8, 4.0, 4.0))
	btn.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.24, 0.20, 0.10, 0.98), Color(1.0, 0.86, 0.46, 1.0),
				null, 8, 4.0, 4.0))


# ===========================================================================
# 按钮 / 交互
# ===========================================================================

func _sync_buttons() -> void:
	var di := _deploy_node()
	var cur: int = int(di.call("mode")) if di != null and di.has_method("mode") else 0
	for e in _deploy_btns:
		var b: Button = e["btn"]
		if b == null or not is_instance_valid(b):
			continue
		var want: bool = int(e["kind"]) == cur
		if b.button_pressed != want:
			b.set_pressed_no_signal(want)
	if _end_btn != null:
		var can: bool = _can_end()
		_end_btn.disabled = not can
		if _end_label != null:
			_end_label.modulate = Color(1, 1, 1, 1) if can else Color(1, 1, 1, 0.42)


func _can_end() -> bool:
	if Game == null or Game.player_faction == null:
		return false
	if Game.has_method("is_over") and bool(Game.call("is_over")):
		return false
	return Game.is_planning()


func _on_deploy(kind: int) -> void:
	var di := _deploy_node()
	if di == null or not di.has_method("enter"):
		return
	di.call("enter", kind)
	_sync_buttons()


## CP 菱形点击：展开建造 / 训练（和旧版同一套口径，玩家已经养成的肌肉记忆）
func _on_cp_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var sel := _selection()
	var has_worker: bool = false
	for n in sel:
		var d: UnitDef = (n as Node).get("def") as UnitDef
		if d != null and RtsWorld.is_worker_def(d):
			has_worker = true
			break
	if has_worker:
		_sig = ""
		refresh()
		return
	var base: RtsBuilding = _main_base(Game.player_faction)
	if base != null:
		var ss := _selection_node()
		if ss != null and ss.has_method("select_units"):
			ss.call("select_units", [base])
		_sig = ""
		refresh()


# ===========================================================================
# 数据 / 工具
# ===========================================================================

func _main_base(pl: RtsFaction) -> RtsBuilding:
	if pl == null:
		return null
	for b in pl.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		if not b.def.is_dropoff or not b.def.dropoff_kinds.is_empty():
			continue
		if b.def.food_provided <= 0:
			continue
		return b
	return null


func _selection() -> Array:
	var ss := _selection_node()
	if ss == null or not ss.has_method("selected_units"):
		return []
	var out: Array = []
	for n in ss.call("selected_units"):
		if n != null and is_instance_valid(n):
			out.append(n)
	return out


func _build_ids() -> Array:
	var card := _command_card()
	if card != null and card.has_method("build_page_ids"):
		return card.call("build_page_ids")
	return [&"farm", &"barracks", &"tower", &"watchtower",
		&"blacksmith", &"sanctum", &"workshop", &"lumbercamp", &"campfire",
		&"townhall"]


func _signature(mode: int, sel: Array, b: RtsBuilding, pl: RtsFaction) -> String:
	var parts := PackedStringArray()
	parts.append(str(mode))
	for n in sel:
		parts.append(str((n as Node).get_instance_id()))
	if b != null:
		parts.append("%d:%d:%d:%d" % [
			int(b.train_queue.size()), int(round(float(b.progress) * 100.0)),
			int(round(float(b.train_progress) * 100.0)), 1 if b.is_constructed else 0])
		for id in b.train_queue:
			parts.append(String(id))
	if pl != null:
		parts.append("%d:%d:%d" % [int(pl.cp), pl.food_committed(), pl.food_cap()])
	var di := _deploy_node()
	parts.append(str(int(di.call("mode")) if di != null and di.has_method("mode") else 0))
	return "|".join(parts)


func _cmd_missing() -> bool:
	var cs := _command_node()
	if cs == null:
		return true
	if cs.has_method("cmd_missing"):
		return bool(cs.call("cmd_missing"))
	return false


func _command_node() -> Node:
	if _cmd != null and is_instance_valid(_cmd):
		return _cmd
	var host := _hud.get_parent() if _hud != null and is_instance_valid(_hud) else null
	if host == null:
		return null
	_cmd = host.get_node_or_null("指令系统")
	return _cmd


func _command_card() -> Node:
	if _hud != null and is_instance_valid(_hud):
		return _hud.get("_card")
	return null


func _selection_node() -> Node:
	var host := _hud.get_parent() if _hud != null and is_instance_valid(_hud) else null
	if host == null:
		return null
	return host.get_node_or_null("选择系统")


func _deploy_node() -> Node:
	if _deploy_input != null and is_instance_valid(_deploy_input):
		return _deploy_input
	var host := _hud.get_parent() if _hud != null and is_instance_valid(_hud) else null
	if host == null:
		return null
	_deploy_input = host.get_node_or_null("部署输入")
	return _deploy_input


func _day_night() -> Node:
	if Game != null and Game.day_night != null and is_instance_valid(Game.day_night):
		return Game.day_night
	return null


# ===========================================================================
# 气泡文案（屏上不写字，解释全放悬停）
# ===========================================================================

func _portrait_tip() -> Dictionary:
	var pl := Game.player_faction
	var base := _main_base(pl)
	var hp: String = "—"
	if base != null and base.def != null:
		hp = "%d / %d" % [int(ceil(base.hp)), int(ceil(base.def.max_hp))]
	return {
		"icon": "house", "icon_color": Color(0.90, 0.78, 0.46),
		"title": "基地 · %s" % (pl.display_name if pl != null else "—"),
		"tag": "基地血量",
		"body": "这里是你的大本营：%s。\n[color=#ff9a7a][b]基地不可修理[/b][/color] —— 血量只会掉，不会回来；丢了基地就输。\n\n规划阶段世界是冻结的，血量按上一回合结束时的状态显示。" % hp,
		"foot": "选中大本营可以训练农民",
	}


func _gold_tip() -> Dictionary:
	var g: int = Game.player_faction.gold if Game.player_faction != null else 0
	return {
		"icon": "coin", "icon_color": Spec.gold(),
		"title": "金币 %d" % g,
		"tag": "局外资源",
		"body": "金币是[color=#ffd27a]长局[/color]的主资源（采集、建造、研究都花它）。\n短局只花 CP —— 这里的数字是局外库存，不参与短局支付。",
		"foot": "短局请只看 CP 与人口",
	}


func _slot_tip() -> Dictionary:
	return {
		"icon": "card", "icon_color": Color(0.86, 0.80, 0.66),
		"title": "法术卷轴",
		"tag": "三个槽位",
		"body": "规划阶段预置法术卷轴的槽位。\n卷轴系统尚未接入，现在是空的。",
		"foot": "接入后：把卷轴拖进格子 → 执行阶段按顺序释放",
	}


func _pop_tip() -> Dictionary:
	var pl := Game.player_faction
	var used: int = pl.food_committed() if pl != null else 0
	var cap: int = pl.food_cap() if pl != null else 0
	return {
		"icon": "pop", "icon_color": Spec.food(),
		"title": "人口 %d / %d" % [used, cap],
		"tag": "已用 / 上限",
		"body": "[b]点下训练就立刻算进「已用」[/b]，不等单位出队。\n上限只由[color=#ffd27a]已完工[/color]的农场/大本营提供，工地不算。",
		"foot": "空闲 %d" % maxi(cap - used, 0),
	}


func _cp_tip() -> Dictionary:
	var pl := Game.player_faction
	var cp: int = int(pl.cp) if pl != null else 0
	var cap: int = int(pl.cp_cap) if pl != null else 0
	return {
		"icon": "flag", "icon_color": Color(0.72, 0.86, 1.0),
		"title": "指挥点 %d / %d" % [cp, cap],
		"tag": "规划资源",
		"body": "短局唯一的运营资源：训练、建造都花 CP。\n[color=#ffd27a]每回合规划阶段由基地补满，上回合剩余清零[/color]；执行阶段隐藏且不回复。\n\n点一下这枚菱形：\n  · 选中农民时展开建造菜单；\n  · 否则自动选中大本营，展开训练菜单。",
		"foot": "执行阶段不可花 CP",
	}


func _dial_tip() -> Dictionary:
	var rc: Node = Game.round_control
	var round_txt: String = ""
	if rc != null and rc.has_method("phase_text"):
		round_txt = String(rc.call("phase_text"))
	var dn := _day_night()
	var clock: String = String(dn.call("clock_text")) if dn != null else "—"
	var night: bool = bool(dn.call("is_night")) if dn != null else false
	var left: float = float(dn.call("seconds_to_turn")) if dn != null else 0.0
	var exec_total: float = float(rc.call("execution_total")) if rc != null and rc.has_method("execution_total") else 0.0
	return {
		"icon": "clock",
		"icon_color": Color(0.66, 0.76, 1.0) if night else Color(1.0, 0.86, 0.50),
		"title": "游戏时间 %s" % clock,
		"tag": "夜晚" if night else "白天",
		"body": "规划阶段[color=#ffd27a]世界冻结[/color]：日夜、据点、波次计时都不走。\n%s\n\n执行阶段每回合 %.0f 秒；%s" % [
			round_txt, exec_total,
			("距离天亮还有 %.0f 秒。" % left) if night else ("距离天黑还有 %.0f 秒。" % left)],
		"foot": "执行阶段才会继续走时间",
	}


func _deploy_tip(kind: int, body: String) -> Dictionary:
	return {
		"icon": "sword" if kind == DT.ATTACK else ("shield" if kind == DT.DEFEND else "flag"),
		"icon_color": Color(0.96, 0.90, 0.78),
		"title": I18n.t("deploy." + String(DT.NAMES[kind])),
		"tag": "部署",
		"body": body + "\n\n点按钮后指针会变成对应图标，地图上实时预览；右键 / ESC 取消。",
		"foot": "点地图落点后生效",
	}


func _site_tip(b: RtsBuilding) -> Dictionary:
	var left: float = 0.0
	if b != null and b.def != null:
		left = maxf(float(b.def.train_time) * (1.0 - float(b.progress)), 0.0)
	return {
		"icon": "建筑/" + String(b.def.id) if b != null and b.def != null else "house",
		"icon_color": Color(0.92, 0.88, 0.78),
		"title": (b.def.display_name if b != null and b.def != null else "工地") + " · 建造中",
		"tag": "%d%%" % int(round(float(b.progress) * 100.0)) if b != null else "0%",
		"body": "还需 %.0f 秒 · 农民在工地里施工。\n规划阶段撤销会退 CP；执行阶段取消不退 CP，但订单保留、可以重新选址再建。" % left,
		"foot": "点「取消建造」撤掉这处工地",
	}


func _train_tip(b: RtsBuilding, id: StringName, ok: bool) -> Dictionary:
	var d: UnitDef = Cfg.unit(id)
	var res := 可用性查询.train(b, id, Game.player_faction)
	var why: String = "" if ok else 可用性文案.text(res)
	# ★ 不要读 `d.description`：那是**卡**（单位卡.gd）的字段，UnitDef 里没有
	var stats: String = "—"
	if d != null:
		stats = "生命 %d · 攻击 %.0f · 护甲 %.0f%s" % [int(d.max_hp), d.attack_damage, d.armor,
			I18n.t("hint.squad", {"n": int(d.squad_size)})]
	var qn: int = b.train_queue.size() if b != null else 0
	var remain: String = ""
	if b != null and qn > 0:
		var d0: UnitDef = Cfg.unit(b.train_queue[0])
		var total: float = maxf(float(d0.train_time), 0.2) if d0 != null else 1.0
		remain = "\n当前队列 %d 项 · 下一个 %s 还需 %.1f 秒" % [
			qn, d0.display_name if d0 != null else "?", maxf(total * (1.0 - float(b.train_progress)), 0.0)]
	return {
		"icon": "单位/" + String(id), "icon_color": Color(0.92, 0.90, 0.86),
		"title": d.display_name if d != null else String(id),
		"tag": "训练",
		"body": "%s\n\n占据人口 %d · 训练 %.0f 秒 · 花费 CP %d%s" % [
			stats, d.pop_cost if d != null else 0, d.train_time if d != null else 0.0,
			d.cp_cost if d != null else 0, remain],
		"foot": why if why != "" else "点一下立刻扣 CP，并立刻占用人口",
	}


func _build_tip(bid: StringName, ok: bool) -> Dictionary:
	var d: UnitDef = Cfg.unit(bid)
	var res := 可用性查询.build(bid, Game.player_faction, true)
	var why: String = "" if ok else 可用性文案.text(res)
	var bstats: String = "—"
	if d != null:
		bstats = "生命 %d · 护甲 %.0f · 视野 %.0fm" % [int(d.max_hp), d.armor, d.sight_range]
	return {
		"icon": "建筑/" + String(bid), "icon_color": Color(0.92, 0.90, 0.86),
		"title": d.display_name if d != null else String(bid),
		"tag": "建造",
		"body": "%s\n\n花费 CP %d · 占人口 %d · 工期 %.0f 秒%s" % [
			bstats, d.cp_cost if d != null else 0, d.pop_cost if d != null else 0,
			d.train_time if d != null else 0.0,
			("\n提供人口 +%d" % d.food_provided) if d != null and d.food_provided > 0 else ""],
		"foot": why if why != "" else "点一下 → 在地图上选位置",
	}


func _end_tip() -> Dictionary:
	return {
		"icon": "play", "icon_color": Color(1.0, 0.86, 0.44),
		"title": "规划结束",
		"tag": "进入执行阶段",
		"body": "[color=#ffd27a][b]结束规划进入执行阶段。未完成训练将在回合结束时取消，不退 CP。[/b][/color]\n\n· 执行阶段：世界解冻，部队按计划行动；\n· 队列在执行阶段推进，玩家不能改队列、不能取消；\n· 执行阶段不显示 CP，也不能再花 CP。",
		"foot": "想稳一手：等训练读条走完再结束规划",
	}


func _cancel_tip() -> Dictionary:
	return {
		"icon": "cancel", "icon_color": Color(0.95, 0.66, 0.42),
		"title": "取消",
		"tag": "撤销当前操作",
		"body": "按顺序撤销：\n  ① 正在等待落点的部署（进攻/防守/占据）；\n  ② 正在等待落点的建造；\n  ③ 都没有时，撤掉[color=#ffd27a]最后一条[/color]已下达的计划。",
		"foot": "右键 / ESC 同效",
	}


## 顶部/人口里那枚"自绘徽记"（金币 / 人口）
func _emblem(kind: String, px: float, col: Color) -> Control:
	var c := EmblemHolder.new()
	c.kind = kind
	c.col = col
	c.fill = true
	c.custom_minimum_size = Vector2(px, px)
	c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ===========================================================================
# 内嵌小控件
# ===========================================================================

## 一枚自绘徽记（可选带暗铁底）。`fill=true` 时把整块区域都画满。
class EmblemHolder extends Control:
	## 内部类里再 preload 一次，别去链文件级 `徽记` 常量：
	## 内部类对文件级 const 的解析要绕一层，历史上出过"编译期拿不到"的假错。
	const Spec2 := preload("res://Screens/hud/徽记.gd")

	var kind: String = "attack"
	var col: Color = Color(1, 1, 1, 1)
	var fill: bool = false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 3.0 or r.size.y < 3.0:
			return
		if fill:
			Spec2.draw_icon(self, kind, r, col, 1.0)
		else:
			Spec2.draw_glyph(self, kind, r, col, 1.0)


## CP 菱形：外圈金线 + 内填深色 + 数值（比旧版更"铁牌"，加了内环和微光）
class CpDiamond extends Control:
	var cp: float = 0.0
	var cap: float = 0.0
	var _font: Font = null
	var _fs: int = 20
	var _t: float = 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		process_mode = Node.PROCESS_MODE_ALWAYS

	func set_values(v: float, c: float) -> void:
		if absf(v - cp) < 0.01 and absf(c - cap) < 0.01:
			return
		cp = v
		cap = c
		queue_redraw()

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w < 20.0 or h < 20.0:
			return
		var c := Vector2(w * 0.5, h * 0.5)
		var rx: float = minf(w, h) * 0.44
		var ry: float = rx * 1.04
		var pts := PackedVector2Array([
			c + Vector2(0.0, -ry), c + Vector2(rx, 0.0),
			c + Vector2(0.0, ry), c + Vector2(-rx, 0.0),
		])
		# 外微光（呼吸很慢，像一枚在发光的令符）
		var glow: float = 0.10 + 0.04 * sin(_t * 1.4)
		var gp := PackedVector2Array()
		for p in pts:
			gp.append((p - c) * 1.10 + c)
		draw_colored_polygon(gp, Color(0.98, 0.84, 0.44, glow))
		draw_colored_polygon(pts, Color(0.038, 0.045, 0.058, 0.96))
		draw_polyline(_close(pts), Color(0.94, 0.80, 0.44, 0.96), 2.0)
		var inner := PackedVector2Array()
		for p in pts:
			inner.append((p - c) * 0.84 + c)
		draw_polyline(_close(inner), Color(0.66, 0.80, 1.0, 0.42), 1.0)
		var f: Font = _font if _font != null else ThemeDB.fallback_font
		var txt: String = "%d/%d" % [int(cp), int(cap)]
		var fs: int = _fs
		var tw: float = f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(c.x - tw * 0.5, c.y + float(fs) * 0.34), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.97, 0.96, 0.90))

	func _close(pts: PackedVector2Array) -> PackedVector2Array:
		var out := pts.duplicate()
		out.append(pts[0])
		return out


## 三格法术卷轴：空格子 = 暗底 + 很淡的卷轴线描（有卷轴才点亮）
class SpellSlots extends Control:
	const Spec3 := preload("res://Screens/hud/徽记.gd")

	var _t: float = 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var gap := 6.0
		var n := 3
		var slot: float = (size.x - gap * float(n - 1)) / float(n)
		if slot < 8.0:
			return
		for i in n:
			var r := Rect2(float(i) * (slot + gap), (size.y - slot) * 0.5, slot, slot)
			Spec3.draw_plate(self, r, Color(0.86, 0.80, 0.62), 1.0, 8)
			# 空格子：一枚很淡的"+"，读作"这里可以放东西"，不写一个字
			var c := r.get_center()
			var arm: float = slot * 0.16
			var col := Color(0.62, 0.58, 0.50, 0.55 + 0.10 * sin(_t * 1.6))
			draw_line(c - Vector2(arm, 0.0), c + Vector2(arm, 0.0), col, 1.6, true)
			draw_line(c - Vector2(0.0, arm), c + Vector2(0.0, arm), col, 1.6, true)
			# 四角刻线（沙盘仪表盘的观感，和顶部条的金属底配套）
			var k: float = slot * 0.18
			for sx in [-1.0, 1.0]:
				for sy in [-1.0, 1.0]:
					var p := Vector2(c.x + sx * (slot * 0.5 - 4.0), c.y + sy * (slot * 0.5 - 4.0))
					draw_line(p, p + Vector2(-sx * k * 0.5, 0.0), Color(0.86, 0.80, 0.62, 0.35), 1.0)
					draw_line(p, p + Vector2(0.0, -sy * k * 0.5), Color(0.86, 0.80, 0.62, 0.35), 1.0)


## 日夜圆盘：白天画太阳（圆 + 八道光线），夜里画月亮（缺口圆 + 星）。
## 规划阶段传 `animated = false`：**图标静止**（世界冻结，指针不走）。
class DayDial extends Control:
	var night: bool = false
	var hour: float = 12.0
	var animated: bool = false
	var _t: float = 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		process_mode = Node.PROCESS_MODE_ALWAYS

	func set_state(is_night: bool, h: float, anim: bool) -> void:
		var dirty: bool = is_night != night or absf(h - hour) > 0.01 or anim != animated
		night = is_night
		hour = h
		animated = anim
		if dirty:
			queue_redraw()

	func _process(dt: float) -> void:
		if not animated:
			return
		_t += dt
		queue_redraw()

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w < 20.0 or h < 20.0:
			return
		var c := Vector2(w * 0.5, h * 0.5)
		var r: float = minf(w, h) * 0.46
		draw_circle(c, r, Color(0.030, 0.036, 0.048, 0.92))
		draw_arc(c, r, 0.0, TAU, 40, Color(0.92, 0.78, 0.42, 0.86), 1.8, true)
		if not night:
			var sun := Color(1.0, 0.86, 0.42)
			draw_circle(c, r * 0.40, sun)
			draw_circle(c, r * 0.40, Color(1.0, 0.96, 0.76))
			var spin: float = _t * 0.6 if animated else 0.0
			for i in 8:
				var a: float = TAU * float(i) / 8.0 + spin
				var p0 := c + Vector2(cos(a), sin(a)) * (r * 0.56)
				var p1 := c + Vector2(cos(a), sin(a)) * (r * 0.82)
				draw_line(p0, p1, Color(1.0, 0.84, 0.40, 0.92), 2.0, true)
		else:
			var moon := Color(0.78, 0.86, 1.0)
			draw_circle(c + Vector2(-r * 0.06, 0.0), r * 0.42, moon)
			draw_circle(c + Vector2(r * 0.20, -r * 0.12), r * 0.36, Color(0.030, 0.036, 0.048, 0.98))
			for i in 3:
				var a2: float = TAU * float(i) / 3.0 + 0.8 + (_t * 0.4 if animated else 0.0)
				var sp := c + Vector2(cos(a2), sin(a2)) * (r * 0.66)
				draw_circle(sp, 1.4, Color(0.90, 0.94, 1.0, 0.9))
