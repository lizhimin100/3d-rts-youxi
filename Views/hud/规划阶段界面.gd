extends Control
## **规划阶段界面（Planning HUD，2026-11-15）**
##
## 玩家口径：原来的「准备阶段」正式改名「规划阶段」，并按新草图重排：
##
##   ┌──────────────────────────────────────────────────────────────────┐
##   │ [指挥官卡]        [局外资源·金币/木材]      [人口] [☀/☾]          │
##   │ 头像+基地血量                                                 │
##   │                                                              │
##   │ [CP ◇ 12/24]                        （地图：部署标记 / 明牌意图）│
##   │                                                              │
##   │            ┌───────────────────────────────┐  ┌────────┐      │
##   │            │ 底部操作面板（随选中切换）      │  │规划结束│      │
##   │            │ 部署三键 / 训练卡 / 建造卡      │  ├────────┤      │
##   │            └───────────────────────────────┘  │  取消  │      │
##   └──────────────────────────────────────────────────────────────────┘
##
## 三条纪律：
##   ① **只在规划阶段显示**：执行阶段的一切 UI 与逻辑保持原样（HUD 负责显隐切换）；
##   ② 颜色/字号/按钮四态全部走 `界面规格.gd`，不在这里发明新样式；
##   ③ 所有"能不能点"的判定走 `可用性查询`（和命令卡/指令系统同一套），
##      这里只负责翻译成"灰掉 + 原因"。
##
## 对外（HUD / 自检）：
##   setup(hud, map_layer)   注入宿主与地图层
##   apply_rects(dict)       由 HUD._apply_layout 统一摆位（唯一摆放出口）
##   refresh()               每 0.12s 调一次（内部按签名重建，不每帧 new 控件）
##   is_active() / set_active(on)

const Spec := preload("res://Views/hud/界面规格.gd")
const Lex := preload("res://Views/hud/词条.gd")
const WAR := preload("res://Game/ai/战区指令.gd")
const 可用性查询 := preload("res://Game/config/可用性查询.gd")
const 可用性文案 := preload("res://Game/config/可用性文案.gd")

## 规划结束（HUD 接住：调回合控制 begin_execution）
signal plan_end_pressed
## 取消（HUD 接住：先撤部署/落点，再撤最后一条计划）
signal cancel_pressed

## 底部面板的四种形态
enum Act {
	NONE = 0,     ## 什么都没选
	DEPLOY = 1,   ## 选中部队 → 进攻/防守/占据
	TRAIN = 2,    ## 选中建筑 → 训练卡 + 队列 + 人口 + 时间
	BUILD = 3,    ## 选中农民 → 建造卡
}

## 部署按钮宽度 / 高度（设计像素）
const DEPLOY_W := 116.0
const DEPLOY_H := 64.0
## 训练/建造卡尺寸
const CARD_W := 92.0
const CARD_H := 92.0
## 队列小格（训练队列最多画几个）
const QUEUE_PIPS := 5

var _hud: Node = null
var _map_layer: Control = null
var _deploy_input: Node = null
var _cmd: Node = null

# --- 左上：指挥官卡 ---
var _cmdr: PanelContainer = null
var _cmdr_portrait: Control = null
var _cmdr_name: Label = null
var _cmdr_hp: Label = null
var _cmdr_bar: HpBar = null
var _cmdr_note: Label = null

# --- 左中：CP 菱形 ---
var _cp: CpDiamond = null

# --- 中上：局外资源 ---
var _external: PanelContainer = null
var _ext_gold: Label = null
var _ext_wood: Label = null
var _ext_tag: Label = null
var _ext_row: HBoxContainer = null

# --- 右上：人口 + 日夜 ---
var _right: PanelContainer = null
var _pop_label: Label = null
var _pop_bar: HpBar = null
var _dial: DayDial = null

# --- 底部：操作面板 ---
var _action: PanelContainer = null
var _act_title: Label = null
var _act_sub: Label = null
var _act_body: HBoxContainer = null
var _act_foot: Label = null
## 右下两枚按钮：规划结束（上）/ 取消（下）
var _end_btn: Button = null
var _cancel_btn: Button = null
## 当前形态（Act）
var _act_mode: int = Act.NONE
## 部署三键 [{kind, btn}]
var _deploy_btns: Array = []
## 重建签名
var _sig: String = ""


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


## 底部操作面板的屏幕矩形（真实屏幕像素；给规划地图层算"明牌意图"的安全区）
func action_global_rect() -> Rect2:
	if _action == null or not is_instance_valid(_action):
		return Rect2()
	return _action.get_global_rect()


func set_active(on: bool) -> void:
	if visible == on:
		return
	visible = on
	if _map_layer != null and is_instance_valid(_map_layer):
		_map_layer.visible = on
		if on:
			_map_layer.call("set_zoom", _zoom())
	if not on:
		# 离开规划阶段：把部署状态一并收掉（否则执行阶段还挂着一个"点哪都不生效"的模式）
		var di := _deploy_node()
		if di != null and di.has_method("cancel"):
			di.call("cancel")


## HUD 统一摆位：{commander, cp, external, right, action, right_col}
func apply_rects(r: Dictionary) -> void:
	_put(_cmdr, r.get("commander", Rect2()))
	_put(_cp, r.get("cp", Rect2()))
	_put(_external, r.get("external", Rect2()))
	_put(_right, r.get("right", Rect2()))
	_put(_action, r.get("action", Rect2()))
	var col: Rect2 = r.get("right_col", Rect2())
	var bw: float = col.size.x
	var bh: float = 56.0
	var gap: float = 8.0
	if _end_btn != null:
		_end_btn.position = col.position
		_end_btn.size = Vector2(bw, bh)
	if _cancel_btn != null:
		_cancel_btn.position = col.position + Vector2(0.0, bh + gap)
		_cancel_btn.size = Vector2(bw, col.size.y - bh - gap)


func _put(c: Control, r: Rect2) -> void:
	if c == null or not is_instance_valid(c):
		return
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
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
	_build_commander()
	_build_cp()
	_build_external()
	_build_right()
	_build_action()
	_build_right_column()


## 左上：玩家头像 + 基地血量（醒目标注"基地不可修理"）
func _build_commander() -> void:
	_cmdr = PanelContainer.new()
	_cmdr.name = "指挥官卡"
	_cmdr.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := Spec.panel_style(8, 0.94, 0.55, 10.0)
	sb.border_width_top = 2
	sb.border_color = Color(0.92, 0.76, 0.40, 0.92)
	_cmdr.add_theme_stylebox_override("panel", sb)
	add_child(_cmdr)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 8)
	_cmdr.add_child(hb)

	# 头像：大本营渲图（玩家阵营的"我"就是这座城）
	var frame := Panel.new()
	frame.custom_minimum_size = Vector2(54.0, 54.0)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.05, 0.06, 0.08, 0.95), 6,
					Color(0.86, 0.72, 0.40, 0.55), 4.0, 3.0))
	hb.add_child(frame)
	_cmdr_portrait = Control.new()
	_cmdr_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cmdr_portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_child(_cmdr_portrait)
	var tex := Spec.building_icon(&"townhall")
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		_cmdr_portrait.add_child(tr)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 1)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(vb)

	_cmdr_name = Spec.label("指挥官", Spec.FS_CAPTION, Spec.text_dim())
	vb.add_child(_cmdr_name)
	_cmdr_hp = Spec.label("600/1000", Spec.FS_VALUE, Spec.text_main())
	_cmdr_hp.add_theme_font_override("font", Spec.mono_font())
	vb.add_child(_cmdr_hp)
	_cmdr_bar = HpBar.new()
	_cmdr_bar.custom_minimum_size = Vector2(118.0, 7.0)
	_cmdr_bar.color = Color(0.52, 0.82, 0.46)
	vb.add_child(_cmdr_bar)
	_cmdr_note = Spec.label("基地不可修理", Spec.FS_CAPTION, Color(0.95, 0.56, 0.44))
	vb.add_child(_cmdr_note)

	RtsTipLayer.bind(self, _cmdr, func() -> Dictionary: return _commander_tip())


## 左中：CP 菱形（可点：展开建造/训练菜单；CP 不足时置灰）
func _build_cp() -> void:
	_cp = CpDiamond.new()
	_cp.name = "CP点"
	_cp.mouse_filter = Control.MOUSE_FILTER_STOP
	_cp.tooltip_text = ""
	add_child(_cp)
	_cp.gui_input.connect(_on_cp_input)
	RtsTipLayer.bind(self, _cp, func() -> Dictionary: return _cp_tip())


## 中上：局外资源（短局灰显，标注"局外资源"）
func _build_external() -> void:
	_external = PanelContainer.new()
	_external.name = "局外资源"
	_external.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := Spec.panel_style(7, 0.62, 0.34, 12.0)
	sb.content_margin_top = 3.0
	sb.content_margin_bottom = 3.0
	_external.add_theme_stylebox_override("panel", sb)
	add_child(_external)

	_ext_row = HBoxContainer.new()
	_ext_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ext_row.add_theme_constant_override("separation", 10)
	_ext_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_external.add_child(_ext_row)

	_ext_tag = Spec.label("局外资源", Spec.FS_CAPTION, Spec.text_dim())
	_ext_row.add_child(_ext_tag)
	_ext_gold = _ext_pill("coin", Spec.gold())
	_ext_wood = _ext_pill("wood", Spec.wood())
	RtsTipLayer.bind(self, _external, func() -> Dictionary: return _external_tip())


func _ext_pill(icon_name: String, col: Color) -> Label:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 4)
	_ext_row.add_child(row)
	row.add_child(Spec.icon(icon_name, 18.0, col))
	var lb := Spec.label("0", Spec.FS_BODY, Spec.text_main())
	lb.add_theme_font_override("font", Spec.mono_font())
	row.add_child(lb)
	return lb


## 右上：人口 + 日夜圆盘
func _build_right() -> void:
	_right = PanelContainer.new()
	_right.name = "规划右上"
	_right.mouse_filter = Control.MOUSE_FILTER_PASS
	_right.add_theme_stylebox_override("panel", Spec.panel_style(7, 0.90, 0.42, 10.0))
	add_child(_right)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 10)
	_right.add_child(hb)

	hb.add_child(Spec.icon("pop", 22.0, Spec.food()))
	var pv := VBoxContainer.new()
	pv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pv.add_theme_constant_override("separation", 1)
	hb.add_child(pv)
	_pop_label = Spec.label("0/0", Spec.FS_VALUE, Spec.text_main())
	_pop_label.add_theme_font_override("font", Spec.mono_font())
	pv.add_child(_pop_label)
	_pop_bar = HpBar.new()
	_pop_bar.custom_minimum_size = Vector2(52.0, 5.0)
	_pop_bar.color = Spec.food()
	pv.add_child(_pop_bar)

	_dial = DayDial.new()
	_dial.name = "日夜"
	_dial.custom_minimum_size = Vector2(46.0, 46.0)
	_dial.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dial.mouse_filter = Control.MOUSE_FILTER_PASS
	hb.add_child(_dial)
	RtsTipLayer.bind(self, _dial, func() -> Dictionary: return _dial_tip())
	RtsTipLayer.bind(self, _right, func() -> Dictionary: return _pop_tip())


## 底部操作面板：标题 / 副标题 / 内容 / 脚注
func _build_action() -> void:
	_action = PanelContainer.new()
	_action.name = "规划操作面板"
	_action.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := Spec.panel_style(9, 0.95, 0.60, 14.0)
	sb.border_width_top = 2
	sb.border_color = Color(0.90, 0.74, 0.38, 0.86)
	_action.add_theme_stylebox_override("panel", sb)
	add_child(_action)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 4)
	_action.add_child(vb)

	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	_act_title = Spec.label("", Spec.FS_SUB, Spec.text_main())
	_act_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_act_title)
	_act_sub = Spec.label("", Spec.FS_CAPTION, Spec.text_dim(), HORIZONTAL_ALIGNMENT_RIGHT)
	head.add_child(_act_sub)

	_act_body = HBoxContainer.new()
	_act_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_act_body.add_theme_constant_override("separation", 8)
	_act_body.alignment = BoxContainer.ALIGNMENT_CENTER
	_act_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_act_body)

	_act_foot = Spec.label("", Spec.FS_CAPTION, Spec.text_dim())
	_act_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_act_foot)


## 右下：规划结束（高权重高亮）+ 取消
func _build_right_column() -> void:
	_end_btn = Button.new()
	_end_btn.name = "规划结束"
	_end_btn.text = "规划结束"
	_end_btn.focus_mode = Control.FOCUS_NONE
	# **高权重**：字号比普通按钮大一档、2px 金边、左侧一道金条（`stripe`）、外加 play 图标。
	# 它是规划阶段唯一"推进游戏"的按钮，必须一眼看见，且不容易误点（放在最上面、比取消大）。
	_end_btn.add_theme_font_size_override("font_size", Spec.FS_VALUE)
	_end_btn.add_theme_color_override("font_color", Color(1.0, 0.97, 0.84))
	_end_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 0.96))
	_end_btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.92, 0.62))
	var play_tex := Spec.icon_tex("play")
	if play_tex != null:
		_end_btn.icon = play_tex
		_end_btn.add_theme_constant_override("icon_max_width", 22)
		_end_btn.add_theme_color_override("icon_normal_color", Color(1.0, 0.93, 0.66))
		_end_btn.add_theme_color_override("icon_hover_color", Color(1.0, 1.0, 0.92))
	var face := Color(0.42, 0.31, 0.12, 0.99)
	var edge := Color(1.0, 0.86, 0.44, 1.0)
	_end_btn.add_theme_stylebox_override("normal",
			Spec.button_style(face, edge, edge, 7, 12.0, 8.0, 2))
	_end_btn.add_theme_stylebox_override("hover",
			Spec.button_style(face.lightened(0.16), Color(1.0, 0.92, 0.58, 1.0), edge, 7, 12.0, 8.0, 2))
	_end_btn.add_theme_stylebox_override("pressed",
			Spec.button_style(face.darkened(0.10), edge, edge, 7, 12.0, 8.0, 2))
	_end_btn.tooltip_text = ""
	RtsTipLayer.bind(self, _end_btn, func() -> Dictionary: return _end_tip())
	_end_btn.pressed.connect(func() -> void: plan_end_pressed.emit())
	add_child(_end_btn)

	_cancel_btn = Button.new()
	_cancel_btn.name = "取消"
	_cancel_btn.text = "取消"
	_cancel_btn.focus_mode = Control.FOCUS_NONE
	_cancel_btn.add_theme_font_size_override("font_size", Spec.FS_BODY)
	_cancel_btn.add_theme_color_override("font_color", Spec.text_main())
	_cancel_btn.add_theme_stylebox_override("normal",
			Spec.button_style(Color(0.11, 0.12, 0.14, 0.96), Color(0.80, 0.68, 0.42, 0.55),
				null, 7, 10.0, 6.0))
	_cancel_btn.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.18, 0.19, 0.22, 0.98), Color(0.90, 0.76, 0.45, 0.95),
				null, 7, 10.0, 6.0))
	_cancel_btn.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.16, 0.14, 0.10, 0.98), Color(0.90, 0.76, 0.45, 1.0),
				Color(0.90, 0.76, 0.45, 1.0), 7, 10.0, 6.0))
	_cancel_btn.tooltip_text = ""
	RtsTipLayer.bind(self, _cancel_btn, func() -> Dictionary: return _cancel_tip())
	_cancel_btn.pressed.connect(func() -> void: cancel_pressed.emit())
	add_child(_cancel_btn)


# ===========================================================================
# 每 0.12s 刷新
# ===========================================================================

func refresh() -> void:
	if not visible:
		return
	var pl := Game.player_faction
	_sync_commander(pl)
	_sync_cp(pl)
	_sync_external(pl)
	_sync_right(pl)
	_sync_action(pl)
	_sync_buttons()


func _sync_commander(pl: RtsFaction) -> void:
	if _cmdr == null:
		return
	var base: RtsBuilding = _main_base(pl)
	_cmdr_name.text = ("%s · 指挥官" % pl.display_name) if pl != null else "指挥官"
	if base != null and base.def != null:
		var hp: float = maxf(base.hp, 0.0)
		var mx: float = maxf(base.def.max_hp, 1.0)
		_cmdr_hp.text = "%d/%d" % [int(ceil(hp)), int(ceil(mx))]
		_cmdr_bar.set_value(hp / mx)
		_cmdr_hp.add_theme_color_override("font_color",
				Color(0.98, 0.56, 0.46) if hp / mx < 0.34 else Spec.text_main())
	else:
		_cmdr_hp.text = "基地已失"
		_cmdr_hp.add_theme_color_override("font_color", Color(0.98, 0.46, 0.40))
		_cmdr_bar.set_value(0.0)


func _sync_cp(pl: RtsFaction) -> void:
	if _cp == null:
		return
	var cp: float = pl.cp if pl != null else 0.0
	var cap: float = pl.cp_cap if pl != null else 0.0
	_cp.set_values(cp, cap)
	# CP 见底 → 整枚菱形压暗（"点它也没东西可买"）
	_cp.modulate = Color(0.62, 0.60, 0.56, 1.0) if cp < 1.0 else Color(1, 1, 1, 1)


func _sync_external(pl: RtsFaction) -> void:
	if _external == null or pl == null:
		return
	_ext_gold.text = "%d" % pl.gold
	_ext_wood.text = "%d" % pl.wood
	# 短局：金币/木材不参与支付 → 整块灰显（半透明 + 冷灰），并标注"局外"
	var short: bool = Game.short_match
	_external.modulate = Color(0.62, 0.63, 0.66, 1.0) if short else Color(1, 1, 1, 1)
	_ext_tag.text = "局外资源 · 短局不用" if short else "局外资源"


func _sync_right(pl: RtsFaction) -> void:
	if _pop_label == null or pl == null:
		return
	var used: int = pl.food_committed()
	var cap: int = pl.food_cap()
	_pop_label.text = "%d/%d" % [used, cap]
	_pop_bar.set_value(float(used) / maxf(float(cap), 1.0))
	_pop_bar.color = Color(0.98, 0.52, 0.42) if cap > 0 and used >= cap else Spec.food()
	# 日夜：规划阶段图标**静止**（世界冻结），只按当前时刻画太阳/月亮
	var dn := _day_night()
	var night: bool = false
	var hour: float = 12.0
	if dn != null:
		night = bool(dn.call("is_night"))
		hour = float(dn.call("hour")) if dn.has_method("hour") else 12.0
	_dial.set_state(night, hour, false)


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
		# 建筑（含工地和无训练项的功能楼）统一走 TRAIN 形态：
		# 工地显示进度/取消建造，农场之类显示属性，有训练项的出单位卡。
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
	_rebuild_action(mode, sel, sole_b, units, pl)


func _rebuild_action(mode: int, _sel: Array, b: RtsBuilding, units: Array,
		pl: RtsFaction) -> void:
	for c in _act_body.get_children():
		_act_body.remove_child(c)
		c.queue_free()
	_deploy_btns.clear()
	match mode:
		Act.DEPLOY:
			_build_deploy(units, pl)
		Act.TRAIN:
			_build_train(b, pl)
		Act.BUILD:
			_build_build(pl)
		_:
			_build_none()


func _build_none() -> void:
	_act_title.text = "规划阶段"
	_act_sub.text = "世界已冻结"
	_act_foot.text = "选中部队 → 进攻 / 防守 / 占据；选中农民 → 建造；选中建筑 → 训练。"
	var hint := Spec.label("未选中任何东西", Spec.FS_BODY, Spec.text_dim())
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_act_body.add_child(hint)


## 选中部队：三个部署按钮（按下态 = 正在等落点）
func _build_deploy(units: Array, _pl: RtsFaction) -> void:
	var name: String = "部队"
	var first: UnitDef = (units[0] as Node).get("def") as UnitDef if not units.is_empty() else null
	if first != null:
		name = first.display_name if units.size() == 1 else "%s ×%d" % [first.display_name, units.size()]
	_act_title.text = "部署 · %s" % name
	_act_sub.text = "人口 %d · %d 个单位" % [_units_pop(units), units.size()]
	_act_foot.text = "点按钮 → 在地图上点目标（右键取消）。部署只在执行阶段生效。"
	var specs: Array = [
		[WAR.ATTACK, "sword", "进攻", "把选中的部队派去进攻该方向 / 目标。地图上显示虚线箭头。"],
		[WAR.DEFEND, "shield", "防守", "把选中的部队部署到防区（10m），路上遇敌就交战。"],
		[WAR.CAPTURE, "flag", "占据", "把选中的部队派去占据据点或一片区域；据点驻留 15 秒归你。"],
	]
	for sp in specs:
		var kind: int = int(sp[0])
		var btn := Button.new()
		btn.name = "部署_" + String(sp[2])
		btn.text = String(sp[2])
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(DEPLOY_W, DEPLOY_H)
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.add_theme_font_size_override("font_size", Spec.FS_SUB)
		btn.add_theme_color_override("font_color", Spec.text_main())
		btn.add_theme_color_override("font_hover_color", Color(1.0, 0.98, 0.90))
		btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.94, 0.72))
		var icon := Spec.icon_tex(String(sp[1]))
		if icon != null:
			btn.icon = icon
			btn.add_theme_constant_override("icon_max_width", 24)
			btn.add_theme_color_override("icon_normal_color", Spec.text_main())
			btn.add_theme_color_override("icon_pressed_color", Color(1.0, 0.94, 0.72))
		btn.add_theme_stylebox_override("normal",
				Spec.button_style(Color(0.10, 0.11, 0.13, 0.96), Color(0.84, 0.70, 0.40, 0.55),
					null, 6, 8.0, 5.0))
		btn.add_theme_stylebox_override("hover",
				Spec.button_style(Color(0.17, 0.18, 0.21, 0.98), Color(0.94, 0.80, 0.46, 0.95),
					null, 6, 8.0, 5.0))
		btn.add_theme_stylebox_override("pressed",
				Spec.button_style(_deploy_fill(kind), _deploy_edge(kind), _deploy_edge(kind),
					6, 8.0, 5.0))
		btn.add_theme_stylebox_override("hover_pressed",
				Spec.button_style(_deploy_fill(kind).lightened(0.10), _deploy_edge(kind),
					_deploy_edge(kind), 6, 8.0, 5.0))
		btn.tooltip_text = ""
		RtsTipLayer.bind(self, btn, func() -> Dictionary: return _deploy_tip(kind, String(sp[3])))
		btn.pressed.connect(_on_deploy.bind(kind))
		_act_body.add_child(btn)
		_deploy_btns.append({"kind": kind, "btn": btn})


func _deploy_fill(kind: int) -> Color:
	match kind:
		WAR.ATTACK:
			return Color(0.30, 0.16, 0.08, 0.98)
		WAR.DEFEND:
			return Color(0.10, 0.18, 0.30, 0.98)
		WAR.CAPTURE:
			return Color(0.28, 0.22, 0.08, 0.98)
	return Color(0.20, 0.18, 0.12, 0.98)


func _deploy_edge(kind: int) -> Color:
	match kind:
		WAR.ATTACK:
			return Color(1.0, 0.62, 0.34, 1.0)
		WAR.DEFEND:
			return Color(0.52, 0.78, 1.0, 1.0)
		WAR.CAPTURE:
			return Color(1.0, 0.84, 0.40, 1.0)
	return Color(0.9, 0.8, 0.5, 1.0)


## 选中建筑：单位卡（训练）+ 队列 + 人口 + 时间
func _build_train(b: RtsBuilding, pl: RtsFaction) -> void:
	if b == null or b.def == null:
		_build_none()
		return
	_act_title.text = b.def.display_name
	if not b.is_constructed:
		# 工地：进度 + 剩余时间 + 取消建造（不退款口径由 cancel_construction 决定）
		_act_sub.text = "建造中 %d%%" % int(round(float(b.progress) * 100.0))
		var left: float = maxf(float(b.def.train_time) * (1.0 - float(b.progress)), 0.0)
		var lb := Spec.label("还需 %.0f 秒 · 农民在工地里施工" % left, Spec.FS_BODY, Spec.text_main())
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_act_body.add_child(lb)
		var cancel := Button.new()
		cancel.text = "取消建造"
		cancel.focus_mode = Control.FOCUS_NONE
		cancel.custom_minimum_size = Vector2(118.0, 40.0)
		cancel.add_theme_font_size_override("font_size", Spec.FS_BODY)
		cancel.add_theme_stylebox_override("normal",
				Spec.button_style(Color(0.14, 0.10, 0.09, 0.96), Color(0.80, 0.46, 0.36, 0.7),
					null, 6, 10.0, 4.0))
		cancel.pressed.connect(func() -> void:
			if b != null and is_instance_valid(b) and b.has_method("cancel_construction"):
				b.call("cancel_construction"))
		_act_body.add_child(cancel)
		_act_foot.text = "工地取消后不退 CP（已投的工时作废）。"
		return

	var qn: int = b.train_queue.size()
	var remain: String = ""
	if qn > 0:
		var d0: UnitDef = Cfg.unit(b.train_queue[0])
		var total: float = maxf(float(d0.train_time), 0.2) if d0 != null else 1.0
		var left2: float = total * (1.0 - float(b.train_progress))
		remain = " · 下一个 %s %.1fs" % [
			d0.display_name if d0 != null else "?", maxf(left2, 0.0)]
	_act_sub.text = "队列 %d/%d · 人口 %d/%d%s" % [
		qn, 可用性查询.QUEUE_MAX, pl.food_committed() if pl != null else 0,
		pl.food_cap() if pl != null else 0, remain]

	if b.def.trains.is_empty():
		var info := Spec.label(
			"%s：人口 +%d · 血量 %d · 视野 %.0fm" % [
				b.def.display_name, b.def.food_provided, int(b.def.max_hp), b.def.sight_range],
			Spec.FS_BODY, Spec.text_dim())
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_act_body.add_child(info)
		_act_foot.text = "这栋建筑没有训练项。"
		return

	# 训练卡：点一下立刻扣 CP + 占人口（玩家口径），所以脚注必须把"会亏什么"讲清楚。
	_act_foot.text = "点卡片即扣 CP + 占人口；本回合结束仍未完成将取消（不退 CP）。"
	for id in b.def.trains:
		_act_body.add_child(_train_card(b, id))


func _train_card(b: RtsBuilding, id: StringName) -> Button:
	var d: UnitDef = Cfg.unit(id)
	var res := 可用性查询.train(b, id, Game.player_faction)
	var ok: bool = bool(res.get("ok", false))
	var btn := Button.new()
	btn.name = "训练_" + (d.display_name if d != null else String(id))
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(CARD_W, _card_height_fit(1))
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.tooltip_text = ""
	_skin_card(btn, ok)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 4.0
	vb.offset_right = -4.0
	vb.offset_top = 4.0
	vb.offset_bottom = -4.0
	vb.add_theme_constant_override("separation", 1)
	btn.add_child(vb)
	var icon := Spec.unit_icon(id)
	if icon != null:
		var tr := TextureRect.new()
		tr.texture = icon
		tr.custom_minimum_size = Vector2(0.0, 40.0)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(tr)
	var nm := Spec.label(d.display_name if d != null else String(id), Spec.FS_CAPTION,
			Spec.text_main() if ok else Spec.text_dim(), HORIZONTAL_ALIGNMENT_CENTER)
	nm.clip_text = true
	vb.add_child(nm)
	if d != null:
		var sub := Spec.label("CP %d · 人口 %d" % [d.cp_cost, d.food_cost], Spec.FS_CAPTION,
				Color(0.62, 0.86, 1.0) if ok else Color(0.95, 0.60, 0.48),
				HORIZONTAL_ALIGNMENT_CENTER)
		sub.clip_text = true
		vb.add_child(sub)
	btn.disabled = not ok or _cmd_missing()
	if not ok:
		btn.modulate = Color(0.62, 0.62, 0.60, 1.0)
	btn.pressed.connect(func() -> void:
		var cs := _command_node()
		if cs != null and cs.has_method("request_train"):
			cs.call("request_train", id))
	RtsTipLayer.bind(self, btn, func() -> Dictionary: return _train_tip(b, id, ok))
	return btn


## 选中农民：建造卡（和命令卡建造页同一份 id 表）
func _build_build(_pl: RtsFaction) -> void:
	_act_title.text = "建造 · 选中 %d 个农民" % _worker_count()
	_act_sub.text = "CP %d/%d" % [
		int(Game.player_faction.cp) if Game.player_faction != null else 0,
		int(Game.player_faction.cp_cap) if Game.player_faction != null else 0]
	var grid := GridContainer.new()
	grid.columns = 5
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_act_body.add_child(grid)
	# 两行卡片要装进面板：高度按"面板实高 - 标题 - 脚注 - 内边距"反算，别让第二行掉出屏幕。
	var card_h: float = _card_height_fit(2)
	var ids: Array = _build_ids()
	for bid in ids:
		var c := _build_card(bid)
		c.custom_minimum_size = Vector2(CARD_W, card_h)
		c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(c)
	_act_foot.text = "点卡片 → 在地图上选位置。建筑不占人口；农场/大本营提供人口上限。"


func _build_card(bid: StringName) -> Button:
	var d: UnitDef = Cfg.unit(bid)
	var res := 可用性查询.build(bid, Game.player_faction, true)
	var ok: bool = bool(res.get("ok", false))
	var btn := Button.new()
	btn.name = "建造_" + (d.display_name if d != null else String(bid))
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.tooltip_text = ""
	_skin_card(btn, ok)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 4.0
	vb.offset_right = -4.0
	vb.offset_top = 4.0
	vb.offset_bottom = -4.0
	vb.add_theme_constant_override("separation", 1)
	btn.add_child(vb)
	var icon := Spec.building_icon(bid)
	if icon != null:
		var tr := TextureRect.new()
		tr.texture = icon
		tr.custom_minimum_size = Vector2(0.0, 40.0)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(tr)
	var nm := Spec.label(d.display_name if d != null else String(bid), Spec.FS_CAPTION,
			Spec.text_main() if ok else Spec.text_dim(), HORIZONTAL_ALIGNMENT_CENTER)
	nm.clip_text = true
	vb.add_child(nm)
	if d != null:
		var sub := Spec.label("CP %d" % d.cp_cost, Spec.FS_CAPTION,
				Color(0.62, 0.86, 1.0) if ok else Color(0.95, 0.60, 0.48),
				HORIZONTAL_ALIGNMENT_CENTER)
		sub.clip_text = true
		vb.add_child(sub)
	btn.disabled = not ok or _cmd_missing()
	if not ok:
		btn.modulate = Color(0.62, 0.62, 0.60, 1.0)
	btn.pressed.connect(func() -> void:
		var cs := _command_node()
		if cs != null and cs.has_method("request_build"):
			cs.call("request_build", bid))
	RtsTipLayer.bind(self, btn, func() -> Dictionary: return _build_tip(bid, ok))
	return btn


## 卡片高度：把"面板实高"扣掉标题/脚注/内边距后平均分给 rows 行，夹在 [58, CARD_H]。
## 为什么不是固定 CARD_H：1024×600 这种矮屏上，两行 92 的卡片会把面板顶出屏幕下沿。
func _card_height_fit(rows: int) -> float:
	var panel_h: float = _action.size.y if _action != null else 200.0
	# 标题 22 + 脚注 18 + 面板内边距 28 + 行间距 6
	var avail: float = panel_h - 68.0 - 6.0 * float(maxi(rows - 1, 0))
	var each: float = avail / float(maxi(rows, 1))
	return clampf(each, 58.0, CARD_H)


func _skin_card(btn: Button, ok: bool) -> void:
	var fill := Color(0.10, 0.11, 0.13, 0.96) if ok else Color(0.09, 0.09, 0.10, 0.92)
	var edge := Color(0.84, 0.70, 0.40, 0.55) if ok else Color(0.45, 0.42, 0.36, 0.40)
	btn.add_theme_stylebox_override("normal", Spec.button_style(fill, edge, null, 6, 4.0, 4.0))
	btn.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.17, 0.18, 0.21, 0.98), Color(0.94, 0.80, 0.46, 0.95),
				null, 6, 4.0, 4.0))
	btn.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.24, 0.20, 0.10, 0.98), Color(1.0, 0.86, 0.46, 1.0),
				Color(1.0, 0.86, 0.46, 1.0), 6, 4.0, 4.0))


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
	# 规划结束：没有任何计划/队列时也允许点（玩家就是想开打）
	if _end_btn != null:
		_end_btn.disabled = not _can_end()


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


## CP 菱形点击：展开建造 / 训练菜单
##   · 选中农民 → 直接给建造卡（面板形态本来就是 BUILD，这里只负责"确保有选中"）；
##   · 否则自动选中大本营 → 训练菜单（农民）；
##   · 都没有 → 提示。
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
		_sig = ""      # 强制重建（把建造卡展开）
		refresh()
		Game.toast("建造菜单：点卡片后在地图上选位置", Color(0.86, 0.94, 0.72))
		return
	# 自动选大本营
	var pl := Game.player_faction
	var base: RtsBuilding = _main_base(pl)
	if base != null:
		var ss := _selection_node()
		if ss != null and ss.has_method("select_units"):
			ss.call("select_units", [base])
		_sig = ""
		refresh()
		Game.toast("训练菜单：%s" % base.def.display_name, Color(0.86, 0.94, 0.72))
	else:
		Game.toast("先选中农民（建造）或自己的建筑（训练）", Color(0.95, 0.62, 0.45))


# ===========================================================================
# 数据 / 工具
# ===========================================================================

func _main_base(pl: RtsFaction) -> RtsBuilding:
	if pl == null:
		return null
	for b in pl.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		# 口径同 RtsFaction.has_townhall：资源交汇点 + 金木全收 + 提供人口
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


func _worker_count() -> int:
	var n: int = 0
	for u in _selection():
		var d: UnitDef = (u as Node).get("def") as UnitDef
		if d != null and RtsWorld.is_worker_def(d):
			n += 1
	return n


func _units_pop(units: Array) -> int:
	var n: int = 0
	for u in units:
		var d: UnitDef = (u as Node).get("def") as UnitDef
		if d != null:
			n += d.food_cost
	return n


func _build_ids() -> Array:
	var card := _command_card()
	if card != null and card.has_method("build_page_ids"):
		return card.call("build_page_ids")
	# 兜底：命令卡还没建好时用同一份顺序（两边必须一致，否则玩家看到的建筑数量会变）
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
	# 面板实高也要进签名：建造页的卡片高度是按实高反算的，
	# 首帧（还没摆位）建成 58 高之后，若签名不变就永远不会长回 92。
	if _action != null:
		parts.append("h%d" % int(_action.size.y))
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
# 气泡文案（统一走 词条/说明气泡 的观感）
# ===========================================================================

func _commander_tip() -> Dictionary:
	var pl := Game.player_faction
	var base := _main_base(pl)
	var hp: String = "—"
	if base != null and base.def != null:
		hp = "%d / %d" % [int(ceil(base.hp)), int(ceil(base.def.max_hp))]
	return {
		"icon": "house", "icon_color": Color(0.90, 0.78, 0.46),
		"title": "指挥官 · %s" % (pl.display_name if pl != null else "—"),
		"tag": "基地状态",
		"body": "这里是你的大本营：%s。\n[color=#ff9a7a][b]基地不可修理[/b][/color] —— 血量只会掉，不会回来；丢了基地就输。\n\n规划阶段世界冻结，基地血量按上一回合结束时的状态显示。" % hp,
		"foot": "选中大本营可以训练农民",
	}


func _cp_tip() -> Dictionary:
	var pl := Game.player_faction
	var cp: int = int(pl.cp) if pl != null else 0
	var cap: int = int(pl.cp_cap) if pl != null else 0
	return {
		"icon": "flag", "icon_color": Color(0.72, 0.86, 1.0),
		"title": "指挥点 %d / %d" % [cp, cap],
		"tag": "规划资源",
		"body": "短局唯一的运营资源：训练、建造都花 CP。\n规划阶段[color=#ffd27a]不回复[/color]，执行阶段按秒回复。\n\n点一下这枚菱形：\n  · 选中农民时展开建造菜单；\n  · 否则自动选中大本营，展开训练菜单。",
		"foot": "回复 %.1f / 秒（执行阶段）" % (pl.cp_regen if pl != null else 0.0),
	}


func _external_tip() -> Dictionary:
	var g: int = Game.player_faction.gold if Game.player_faction != null else 0
	var w: int = Game.player_faction.wood if Game.player_faction != null else 0
	return {
		"icon": "coin", "icon_color": Spec.gold(),
		"title": "金币 %d · 木材 %d" % [g, w],
		"tag": "局外资源",
		"body": "金币与木材是[color=#ffd27a]长局[/color]的主资源（采集、建造、研究都花它）。\n短局里它们不参与支付 —— 只花 CP，所以这里整块灰显。",
		"foot": "短局请只看 CP 与人口",
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


func _dial_tip() -> Dictionary:
	var rc: Node = Game.round_control
	var round_txt: String = ""
	if rc != null and rc.has_method("phase_text"):
		round_txt = String(rc.call("phase_text"))
	var dn := _day_night()
	var clock: String = String(dn.call("clock_text")) if dn != null else "—"
	var night: bool = bool(dn.call("is_night")) if dn != null else false
	var left: float = float(dn.call("seconds_to_turn")) if dn != null else 0.0
	return {
		"icon": "clock",
		"icon_color": Color(0.66, 0.76, 1.0) if night else Color(1.0, 0.86, 0.50),
		"title": "游戏时间 %s" % clock,
		"tag": "夜晚" if night else "白天",
		"body": "规划阶段[color=#ffd27a]世界冻结[/color]：日夜、据点、波次计时都不走。\n%s\n\n%s" % [
			round_txt, ("距离天亮还有 %.0f 秒。" % left) if night else ("距离天黑还有 %.0f 秒。" % left)],
		"foot": "执行阶段才会继续走时间",
	}


func _deploy_tip(kind: int, body: String) -> Dictionary:
	var col := _deploy_edge(kind)
	return {
		"icon": "sword" if kind == WAR.ATTACK else ("shield" if kind == WAR.DEFEND else "flag"),
		"icon_color": col,
		"title": "部署 · %s" % String(WAR.NAMES[kind]),
		"tag": "二段操作",
		"body": body + "\n\n点按钮后指针会变成对应图标，地图上实时预览；右键 / ESC 取消。",
		"foot": "点地图落点后生效",
	}


func _train_tip(b: RtsBuilding, id: StringName, ok: bool) -> Dictionary:
	var d: UnitDef = Cfg.unit(id)
	var res := 可用性查询.train(b, id, Game.player_faction)
	var why: String = "" if ok else 可用性文案.text(res)
	return {
		"icon": _unit_icon_name(id), "icon_color": Color(0.90, 0.90, 0.86),
		"title": d.display_name if d != null else String(id),
		"tag": "训练",
		"body": "%s\n\n占据人口 %d · 训练 %.0f 秒 · 花费 CP %d" % [
			d.description if d != null and not d.description.is_empty() else "—",
			d.food_cost if d != null else 0, d.train_time if d != null else 0.0,
			d.cp_cost if d != null else 0],
		"foot": why if why != "" else "点一下立刻扣 CP，并立刻占用人口",
	}


func _build_tip(bid: StringName, ok: bool) -> Dictionary:
	var d: UnitDef = Cfg.unit(bid)
	var res := 可用性查询.build(bid, Game.player_faction, true)
	var why: String = "" if ok else 可用性文案.text(res)
	return {
		"icon": "建筑/" + String(bid), "icon_color": Color(0.90, 0.90, 0.86),
		"title": d.display_name if d != null else String(bid),
		"tag": "建造",
		"body": "%s\n\n花费 CP %d · 工期 %.0f 秒%s" % [
			d.description if d != null and not d.description.is_empty() else "—",
			d.cp_cost if d != null else 0, d.train_time if d != null else 0.0,
			("\n提供人口 +%d" % d.food_provided) if d != null and d.food_provided > 0 else ""],
		"foot": why if why != "" else "点一下 → 在地图上选位置",
	}


func _end_tip() -> Dictionary:
	return {
		"icon": "play", "icon_color": Color(1.0, 0.86, 0.44),
		"title": "规划结束",
		"tag": "进入执行阶段",
		"body": "[color=#ffd27a][b]结束规划进入执行阶段。未完成训练将取消，不退 CP。[/b][/color]\n\n· 执行阶段：世界解冻，部队按计划行动，CP 按秒回复；\n· 队列在执行阶段继续推进；本回合结束时仍未完成的训练作废（不退 CP）。",
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


func _unit_icon_name(id: StringName) -> String:
	return "单位/" + String(id)


# ===========================================================================
# 内嵌小控件
# ===========================================================================

## 一条极简数值条（基地血量 / 人口占用）。
## 不引 ProgressBar：它有自己的主题与最小尺寸，在这套"设计像素"版面里会顶高行高。
class HpBar extends Control:
	var ratio: float = 1.0
	var color: Color = Color(0.6, 0.82, 0.5)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_value(r: float) -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if absf(v - ratio) < 0.004:
			return
		ratio = v
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 3.0 or r.size.y < 3.0:
			return
		draw_rect(r, Color(0.0, 0.0, 0.0, 0.62), true)
		var w: float = maxf((r.size.x - 2.0) * ratio, 0.0)
		if w > 0.4:
			draw_rect(Rect2(1.0, 1.0, w, r.size.y - 2.0), color, true)
		draw_rect(r, Color(1.0, 1.0, 1.0, 0.12), false, 1.0)


## CP 菱形：外圈金线 + 内填深色 + 数值
class CpDiamond extends Control:
	var cp: float = 0.0
	var cap: float = 0.0
	var _font: Font = null
	var _fs: int = 18

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		process_mode = Node.PROCESS_MODE_ALWAYS

	func set_values(v: float, c: float) -> void:
		if absf(v - cp) < 0.01 and absf(c - cap) < 0.01:
			return
		cp = v
		cap = c
		queue_redraw()

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w < 20.0 or h < 20.0:
			return
		var c := Vector2(w * 0.5, h * 0.5)
		var rx: float = minf(w, h) * 0.46
		var ry: float = rx * 1.02
		var pts := PackedVector2Array([
			c + Vector2(0.0, -ry), c + Vector2(rx, 0.0),
			c + Vector2(0.0, ry), c + Vector2(-rx, 0.0),
		])
		draw_colored_polygon(pts, Color(0.05, 0.06, 0.08, 0.96))
		draw_polyline(_close(pts), Color(0.92, 0.78, 0.42, 0.95), 2.0)
		var inner := PackedVector2Array()
		for p in pts:
			inner.append((p - c) * 0.86 + c)
		draw_polyline(_close(inner), Color(0.72, 0.86, 1.0, 0.55), 1.0)
		var f: Font = _font if _font != null else ThemeDB.fallback_font
		var txt: String = "%d/%d" % [int(cp), int(cap)]
		var fs: int = _fs
		var tw: float = f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(c.x - tw * 0.5, c.y + float(fs) * 0.34), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.96, 0.96, 0.92))

	func _close(pts: PackedVector2Array) -> PackedVector2Array:
		var out := pts.duplicate()
		out.append(pts[0])
		return out


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
		var r: float = minf(w, h) * 0.5
		# 底盘
		draw_circle(c, r - 1.0, Color(0.06, 0.07, 0.10, 0.92))
		draw_arc(c, r - 1.5, 0.0, TAU, 36, Color(0.86, 0.74, 0.42, 0.85), 1.6, true)
		if not night:
			var sun := Color(1.0, 0.86, 0.42)
			draw_circle(c, r * 0.36, sun)
			draw_circle(c, r * 0.36, Color(1.0, 0.96, 0.76))
			var spin: float = _t * 0.6 if animated else 0.0
			for i in 8:
				var a: float = TAU * float(i) / 8.0 + spin
				var p0 := c + Vector2(cos(a), sin(a)) * (r * 0.50)
				var p1 := c + Vector2(cos(a), sin(a)) * (r * 0.76)
				draw_line(p0, p1, Color(1.0, 0.84, 0.40, 0.92), 2.0, true)
		else:
			# 月亮：亮圆 + 一个偏移的暗圆挖出月牙
			var moon := Color(0.78, 0.86, 1.0)
			draw_circle(c + Vector2(-r * 0.06, 0.0), r * 0.40, moon)
			draw_circle(c + Vector2(r * 0.18, -r * 0.12), r * 0.34, Color(0.06, 0.07, 0.10, 0.98))
			# 星
			for i in 3:
				var a2: float = TAU * float(i) / 3.0 + 0.8 + (_t * 0.4 if animated else 0.0)
				var sp := c + Vector2(cos(a2), sin(a2)) * (r * 0.62)
				draw_circle(sp, 1.4, Color(0.90, 0.94, 1.0, 0.9))
