extends Control
## 职责：战役 HUD —— **规划期可编辑 UI**（StS 风格）。
##       顶部：玩家名 + 本体血量 / 金币 / 3 个卷轴槽 · 中间回合与阶段 · 右侧路线图按钮；
##       底部左：CP 能量球（当前/上限）+ 人口 + 抽牌堆；底部右：开战/据点/倍速 + 弃牌堆；
##       中间：手牌区（卡牌悬停上浮、拖过出牌区打出、打不出去抖动回弹）。
## 属于：Screens/hud（屏幕像素层，不跟 3D 镜头缩放）
##
## 纪律：
##   · **静态布局一律在 `战役HUD.tscn` 里**（节点名就是契约）：本脚本只做三件事 ——
##     绑定引用、写文本/数值、播 Tween 动画。要挪位置请在 Godot 编辑器改场景，
##     不要在代码里 new Control 或写像素坐标（制作人要在编辑器里直接微调）；
##   · 文案全部走 I18n；卡名/描述来自 Content/data/*.json；
##   · 卡牌能不能打只看 Model 给的 available / reason，界面不自己推规则；
##   · 节点名是"可点击契约"（screens.json 的 click 指它），改名要同步 screens.json。

const CARD_SCENE_PATH := "res://Screens/hud/" + "\u5361\u724c.tscn"
const CARD_W := 104.0
const CARD_GAP := 5.0
const PHASE_PLANNING := "planning"

var _root: Node = null

var _cards: Array[Control] = []
var _hand_sig := ""
var _press_card: Control = null
var _drag_card: Control = null
var _drag_grab := Vector2.ZERO
var _drag_hot := false
var _toast_left := 0.0
var _flash: Tween = null

@onready var _hp_value: Label = %HpValue
@onready var _gold_value: Label = %GoldValue
@onready var _scroll_slots: HBoxContainer = %ScrollSlots
@onready var _round_label: Label = %RoundLabel
@onready var _phase_label: Label = %PhaseLabel
@onready var _timer_label: Label = %TimerLabel
@onready var _map_button: Button = %MapButton
@onready var _intent_label: Label = %IntentLabel
@onready var _cp_value: Label = %CpValue
@onready var _cp_cap: Label = %CpCap
@onready var _boost_badge: Label = %BoostBadge
@onready var _pop_value: Label = %PopValue
@onready var _draw_value: Label = %DrawValue
@onready var _draw_caption: Label = %DrawCaption
@onready var _draw_icon: TextureRect = %DrawIcon
@onready var _discard_value: Label = %DiscardValue
@onready var _discard_caption: Label = %DiscardCaption
@onready var _discard_icon: TextureRect = %DiscardIcon
@onready var _start_btn: Button = %StartButton
@onready var _outpost_btn: Button = %OutpostButton
@onready var _speed_btn: Button = %SpeedButton
@onready var _restart_btn: Button = %RestartButton
@onready var _play_zone: PanelContainer = %PlayZone
@onready var _play_zone_label: Label = %PlayZoneLabel
@onready var _hand_row: HBoxContainer = %HandRow
@onready var _hand_area: Control = %HandArea
@onready var _toast: PanelContainer = %Toast
@onready var _toast_label: Label = %ToastLabel
@onready var _result_panel: PanelContainer = %ResultPanel
@onready var _result_label: Label = %ResultLabel
@onready var _info: PanelContainer = %UnitInfo
@onready var _info_title: Label = %InfoTitle
@onready var _info_hp: Label = %InfoHp
@onready var _info_stats: Label = %InfoStats
@onready var _info_state: Label = %InfoState
@onready var _fx: Control = %FxLayer
@onready var _drag_layer: Control = %DragLayer

var _card_scene: PackedScene = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# CanvasLayer 下的 Control 拿不到父级尺寸，必须自己铺满视口
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = get_viewport_rect().size
	get_viewport().size_changed.connect(_on_viewport_resized)
	_root = get_parent()
	while _root != null and not _root.has_method("train_card"):
		_root = _root.get_parent()
	_card_scene = load(CARD_SCENE_PATH) as PackedScene
	_localize_static()
	_wire_buttons()
	_result_panel.visible = false
	_toast.visible = false
	_play_zone.visible = false


func _on_viewport_resized() -> void:
	size = get_viewport_rect().size
	_fit_hand()


## 静态文案（场景里写的是中文占位，运行时统一换成 I18n；改语言只改 ui.csv）
func _localize_static() -> void:
	_hp_value.text = I18n.t("battle.hud.hp", {"hp": 0, "max": 0})
	_gold_value.text = "0"
	_map_button.tooltip_text = I18n.t("battle.hud.map_tip")
	_boost_badge.text = I18n.t("battle.boost.badge")
	_play_zone_label.text = I18n.t("battle.play_zone")
	_toast_label.text = ""
	_result_label.text = ""
	_intent_label.text = ""
	# 卷轴栏：3 个空槽（暂不接功能），只给提示
	var idx := 0
	for child in _scroll_slots.get_children():
		idx += 1
		if child is Control:
			(child as Control).tooltip_text = I18n.t("battle.hud.scroll_tip")
	_draw_caption.text = I18n.t("battle.hud.draw")
	_discard_caption.text = I18n.t("battle.hud.discard")
	_start_btn.text = I18n.t("battle.start")
	_restart_btn.text = I18n.t("battle.restart")
	_outpost_btn.text = I18n.t("battle.outpost.button")
	_speed_btn.text = I18n.t("battle.speed_button", {"x": "1"})


func _wire_buttons() -> void:
	_start_btn.pressed.connect(func() -> void: _call_root("begin_execution"))
	_outpost_btn.pressed.connect(func() -> void: _call_root("capture_outpost"))
	_speed_btn.pressed.connect(_toggle_speed)
	_restart_btn.pressed.connect(func() -> void: _call_root("restart"))
	_map_button.pressed.connect(_on_map_pressed)


func _call_root(method: String) -> void:
	if _root != null and _root.has_method(method):
		_root.call(method)


func _toggle_speed() -> void:
	if _root == null:
		return
	var cur := float(_root.get("time_scale"))
	_root.call("set_time_scale", 2.0 if cur < 1.5 else 1.0)


## 顶部右侧的"杀戮尖塔式路线图"按钮：本版只做外壳与点击反馈
## （弹一下 + 提示），展开路线图等后续版本。
func _on_map_pressed() -> void:
	_pulse(_map_button)
	_show_toast(I18n.t("battle.hud.map_tip"), 1.6)


func _pulse(c: Control) -> void:
	if _flash != null and _flash.is_valid():
		_flash.kill()
	c.pivot_offset = c.size * 0.5
	_flash = create_tween()
	_flash.tween_property(c, "scale", Vector2(1.12, 1.12), 0.08)
	_flash.tween_property(c, "scale", Vector2.ONE, 0.12)


# ===========================================================================
# 每帧刷新（由 战役战场._refresh 以 10Hz 调用）
# ===========================================================================
func refresh(state: Dictionary, view: Dictionary, phase: String, seconds: float,
		selected_count: int, extra: Dictionary) -> void:
	_last_state = state
	_last_phase = phase
	_last_extra = extra
	_refresh_top(state, view, phase, seconds, extra)
	_refresh_bottom(state, phase, extra)
	_refresh_actions(state, phase, extra)
	_refresh_toast(extra)
	_refresh_info(extra)
	_result_panel.visible = phase == "result"
	if phase == "result":
		_result_label.text = String(extra.get("status", ""))
	_sync_hand(state, phase, extra)


func _refresh_top(state: Dictionary, view: Dictionary, phase: String, seconds: float,
		extra: Dictionary) -> void:
	var hp := int(round(float(view.get("player_hp", 0.0))))
	var hp_max := int(round(float(view.get("player_hp_max", 0.0))))
	_hp_value.text = I18n.t("battle.hud.hp", {"hp": hp, "max": hp_max})
	_hp_value.add_theme_color_override("font_color",
		Color(0.663, 0.231, 0.18) if hp_max <= 0 or hp > hp_max * 0.35 else Color(0.55, 0.28, 0.16))
	_gold_value.text = str(int(extra.get("gold", 0)))
	_round_label.text = I18n.t("battle.hud.round", {"n": int(state.get("planning_index", 1))})
	match phase:
		"attack":
			_phase_label.text = I18n.t("battle.phase.attack")
			_timer_label.text = "%02d" % int(ceil(maxf(seconds, 0.0)))
		"defend":
			_phase_label.text = I18n.t("battle.phase.defend")
			_timer_label.text = "%02d" % int(ceil(maxf(seconds, 0.0)))
		"result":
			_phase_label.text = I18n.t("battle.phase.result")
			_timer_label.text = "--"
		_:
			_phase_label.text = I18n.t("battle.phase.planning")
			_timer_label.text = "--"
	_intent_label.text = String(extra.get("intent", ""))


## 选中信息（只读）：这是"选中己方/敌方单位"唯一会发生的事
func _refresh_info(extra: Dictionary) -> void:
	var info: Dictionary = extra.get("selected_info", {})
	_info.visible = not info.is_empty() and _drag_card == null
	if info.is_empty():
		return
	var side := int(info.get("side", 0))
	var tag := I18n.t("battle.info.side.friend") if side == 0 else I18n.t("battle.info.side.enemy")
	_info_title.text = String(info.get("name", I18n.t("battle.info.title")))
	_info_hp.text = I18n.t("battle.hud.hp", {
		"hp": int(round(float(info.get("hp", 0.0)))),
		"max": int(round(float(info.get("max_hp", 1.0))))})
	_info_stats.text = I18n.t("battle.info.stats", {
		"dmg": int(round(float(info.get("damage", 0.0)))),
		"armor": int(round(float(info.get("armor", 0.0)))),
		"cd": "%.1f" % float(info.get("cooldown", 1.0))})
	var state_key := "battle.info.state.idle"
	if bool(info.get("engaged", false)):
		state_key = "battle.info.state.engaged"
	elif int(info.get("side", 0)) == 0:
		state_key = "battle.info.state.moving"
	_info_state.text = "%s · %s" % [tag, I18n.t(state_key)]


func _refresh_bottom(state: Dictionary, phase: String, extra: Dictionary) -> void:
	var cp := int(state.get("cp", 0))
	var cap := int(state.get("cp_cap", 0))
	if cap <= 0:
		cap = int(extra.get("cp_cap", cp))
	_cp_value.text = str(cp)
	_cp_cap.text = "/" + str(cap)
	var mult := float(state.get("train_count_mult", 1.0))
	_boost_badge.visible = mult > 1.001
	if _boost_badge.visible:
		_boost_badge.text = I18n.t("battle.boost.badge")
	_pop_value.text = I18n.t("battle.pop", {"used": int(state.get("pop_used", 0)), "cap": int(state.get("pop_cap", 0))})
	_draw_value.text = str(int(state.get("draw_pile", 0)))
	_discard_value.text = str(int(state.get("discard_pile", 0)))
	_draw_icon.tooltip_text = I18n.t("battle.hud.deck_tip", {"n": int(state.get("draw_pile", 0))})
	_discard_icon.tooltip_text = I18n.t("battle.hud.discard_tip", {"n": int(state.get("discard_pile", 0))})
	# 战斗期手牌区收成一条窄带（少挡战场），规划期还原
	var target_top := -212.0 if phase == PHASE_PLANNING else -96.0
	if not is_equal_approx(_hand_area.offset_top, target_top):
		_hand_area.offset_top = target_top


func _refresh_actions(state: Dictionary, phase: String, extra: Dictionary) -> void:
	_start_btn.visible = phase == PHASE_PLANNING
	_start_btn.disabled = phase != PHASE_PLANNING
	_outpost_btn.visible = phase == PHASE_PLANNING and bool(state.get("outpost_available", false))
	_outpost_btn.disabled = bool(state.get("outpost_captured", false))
	_speed_btn.visible = phase == "attack" or phase == "defend"
	_speed_btn.text = I18n.t("battle.speed_button", {"x": "%.0f" % float(extra.get("time_scale", 1.0))})
	_discard_icon.visible = true


func _refresh_toast(extra: Dictionary) -> void:
	var status := String(extra.get("status", ""))
	if status.is_empty():
		_last_status = ""
		return
	if status == _last_status:
		return
	_last_status = status
	_show_toast(status, 1.6)


func _show_toast(text: String, hold: float) -> void:
	if text.is_empty():
		return
	_toast_label.text = text
	_toast.visible = true
	_toast_left = hold
	_toast.modulate.a = 0.0
	var t := create_tween()
	t.tween_property(_toast, "modulate:a", 1.0, 0.12)
	# 状态文字的自动淡出靠 _process 计时（下面）
	set_process(true)


func _process(delta: float) -> void:
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			var t := create_tween()
			t.tween_property(_toast, "modulate:a", 0.0, 0.25)
			t.tween_callback(func() -> void: _toast.visible = false)


# ===========================================================================
# 手牌：差量同步（新增从抽牌堆飞入 / 消失飞向弃牌堆）
# ===========================================================================
func _sync_hand(state: Dictionary, phase: String, extra: Dictionary) -> void:
	if _drag_card != null:
		return
	var hand: Array = state.get("hand", [])
	var sig := ",".join(hand)
	if sig == _hand_sig and not _cards.is_empty():
		for c in _cards:
			_apply_card(c, state, phase, extra)
		return
	_hand_sig = sig
	_trim_hand(hand)
	_fill_hand(hand, state, phase, extra)
	_fit_hand()


func _trim_hand(hand: Array) -> void:
	var want := {}
	for id in hand:
		want[String(id)] = int(want.get(String(id), 0)) + 1
	var kept := {}
	for i in range(_cards.size() - 1, -1, -1):
		var c: Control = _cards[i]
		var id := String(c.get("card_id"))
		var n := int(kept.get(id, 0))
		if n >= int(want.get(id, 0)):
			_cards.remove_at(i)
			_fly_to_discard(c)
		else:
			kept[id] = n + 1


func _fill_hand(hand: Array, state: Dictionary, phase: String, extra: Dictionary) -> void:
	var have := {}
	for c in _cards:
		var id := String(c.get("card_id"))
		have[id] = int(have.get(id, 0)) + 1
	for id in hand:
		var cid := String(id)
		if int(have.get(cid, 0)) > 0:
			have[cid] = int(have.get(cid, 0)) - 1
			continue
		var card := _card_scene.instantiate() as Control
		if card == null:
			continue
		card.name = _card_node_name(cid)
		# 先入树再 setup：@onready 的节点引用在 _ready 里才解析，提前 setup 全是 null。
		# force_readable_name：同名副本（两张「征召进攻」）会叫 TrainCard_x2，
		# 而不是 `@Control@119` —— 节点的名字是"可点击契约"，必须人能读。
		_hand_row.add_child(card, true)
		card.set("card_id", cid)
		_wire_card(card)
		_apply_card(card, state, phase, extra)
		_cards.append(card)
		_fly_from_draw(card)


func _wire_card(card: Control) -> void:
	if not card.card_pressed.is_connected(_on_card_pressed):
		card.card_pressed.connect(_on_card_pressed)
		card.card_dragged.connect(_on_card_dragged)
		card.card_released.connect(_on_card_released)


## 节点名 = 可点击契约（screens.json / 自检按名字点）
func _card_node_name(card_id: String) -> String:
	if card_id.begins_with("build_"):
		return "BuildCard_" + card_id
	if card_id.begins_with("strategy_"):
		return "StrategyCard_" + card_id
	return "TrainCard_" + card_id


func _apply_card(card: Control, state: Dictionary, phase: String, extra: Dictionary) -> void:
	var meta := _card_meta(String(card.get("card_id")), state, phase, extra)
	var sig := str(meta)
	if String(card.get_meta("sig", "")) == sig:
		return
	card.set_meta("sig", sig)
	card.call("setup", meta)


func _card_meta(card_id: String, state: Dictionary, phase: String, extra: Dictionary) -> Dictionary:
	var defs: Dictionary = extra.get("cards", {})
	var d: Dictionary = defs.get(card_id, {})
	var kind := String(d.get("kind", "train"))
	var role := String(d.get("role", ""))
	var cost := int(d.get("cost_cp", 0))
	var units := 0
	var available := phase == PHASE_PLANNING and int(state.get("cp", 0)) >= cost
	var reason := "no_cp"
	if kind == "train":
		for e in state.get("train_cards", []):
			var row: Dictionary = e
			if String(row.get("card_id", "")) != card_id:
				continue
			units = int(row.get("units", 0))
			available = phase == PHASE_PLANNING and bool(row.get("available", false))
			reason = String(row.get("reason", "ok"))
			break
	elif available:
		reason = "ok"
	if kind == "strategy":
		units = 0
	var tint := _card_tint(kind, role)
	var role_name := _role_label(kind, role)
	return {
		"card_id": card_id,
		"kind": kind,
		"role": role,
		"cost_cp": cost,
		"units": units,
		"available": available,
		"reason": reason,
		"display_name": String(d.get("display_name", card_id)),
		"tag_line": role_name,
		"desc": _card_desc(kind, role, units, d, extra),
		"art": _card_icon(kind, d, extra),
		"tint": tint,
	}


func _card_tint(kind: String, role: String) -> String:
	if kind == "build":
		return "#D5DCC4"
	if kind == "strategy":
		return "#EFDFB8"
	if role == "defend":
		return "#C6D5E6"
	return "#E9C9BA"


func _role_label(kind: String, role: String) -> String:
	if kind == "build":
		return I18n.t("battle.card.build")
	if kind == "strategy":
		return I18n.t("battle.card.strategy")
	if role == "defend":
		return I18n.t("battle.card.defend")
	return I18n.t("battle.card.attack")


func _card_desc(kind: String, role: String, units: int, d: Dictionary, extra: Dictionary) -> String:
	if kind == "train":
		return I18n.t("battle.card.desc_train", {"units": units, "role": _role_label(kind, role)})
	if kind == "build":
		var bid := String(d.get("building", ""))
		var b: Dictionary = (extra.get("buildings", {}) as Dictionary).get(bid, {})
		return I18n.t("battle.card.desc_build", {"pop": int(b.get("pop", 1))})
	# 卡面写的是这张策略牌自己的倍率（不是"当前是否已生效"）——
	# 打出去之前就要写 +50%，否则玩家读到的是 +0%，等于把牌的价值藏起来。
	var eff := String(d.get("effect", ""))
	var sdef: Dictionary = (extra.get("strategies", {}) as Dictionary).get(eff, {})
	var mult := float(sdef.get("train_count_mult", 1.5))
	var pct := int(round((mult - 1.0) * 100.0))
	return I18n.t("battle.card.desc_strategy", {"pct": pct})


func _card_icon(kind: String, d: Dictionary, extra: Dictionary) -> String:
	if kind == "build":
		var b: Dictionary = (extra.get("buildings", {}) as Dictionary).get(String(d.get("building", "")), {})
		return String(b.get("icon_path", ""))
	if kind == "strategy":
		var s: Dictionary = (extra.get("strategies", {}) as Dictionary).get(String(d.get("effect", "")), {})
		return String(s.get("icon_path", ""))
	var u: Dictionary = (extra.get("units", {}) as Dictionary).get(String(d.get("unit", "")), {})
	return String(u.get("icon_path", ""))


# ===========================================================================
# 抽牌 / 弃牌飞行
# ===========================================================================
func _fly_from_draw(card: Control) -> void:
	var from := _draw_icon.get_global_rect().get_center()
	await get_tree().process_frame
	if not is_instance_valid(card):
		return
	var to := card.global_position + card.size * 0.5
	var off := from - to
	var vis: Control = card.get("_visual")
	if vis == null:
		return
	vis.position = off
	card.scale = Vector2(0.28, 0.28)
	card.modulate.a = 0.0
	var t := create_tween().set_parallel(true)
	t.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(vis, "position", Vector2.ZERO, 0.26)
	t.tween_property(card, "scale", Vector2.ONE, 0.26)
	t.tween_property(card, "modulate:a", 1.0, 0.16)


func _fly_to_discard(card: Control) -> void:
	if not is_instance_valid(card):
		return
	var from := card.global_position
	card.reparent(_fx)
	card.global_position = from
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var to := _discard_icon.get_global_rect().get_center() - card.size * 0.5
	card.pivot_offset = card.size * 0.5
	var t := create_tween().set_parallel(true)
	t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	t.tween_property(card, "global_position", to, 0.26)
	t.tween_property(card, "scale", Vector2(0.22, 0.22), 0.26)
	t.tween_property(card, "modulate:a", 0.15, 0.26)
	t.chain().tween_callback(card.queue_free)


## 手牌太多时整排等比缩小（1600x720 下 9 张也不溢出、不挡左右面板）
func _fit_hand() -> void:
	if _hand_row == null:
		return
	var avail := _hand_area.size.x
	if avail <= 1.0:
		return
	var need := float(_cards.size()) * CARD_W + float(maxi(_cards.size() - 1, 0)) * CARD_GAP
	var k := clampf(avail / maxf(need, 1.0), 0.62, 1.0)
	_hand_row.pivot_offset = _hand_row.size * 0.5
	_hand_row.scale = Vector2(k, k)
	_hand_row.position.y = (1.0 - k) * _hand_row.size.y * 0.5



# ===========================================================================
# 卡牌交互：悬停上浮 / 拖动 / 松手打出
# ===========================================================================
func _on_card_pressed(card: Control) -> void:
	if _drag_card != null:
		return
	if not bool(card.get("playable")):
		card.call("shake")
		_show_toast(I18n.t("battle.reason." + String(card.get("reason"))), 1.4)
		return
	# 按下就记下"这张牌正被按住"：单击（没有拖动）也要能在松手时打出，
	# 否则只能拖出去 —— 那就退化成"必须拖"的操作，和参考手感不符。
	_press_card = card


func _on_card_dragged(card: Control, at: Vector2) -> void:
	if _press_card == null:
		_press_card = card
	if _drag_card == null:
		_drag_card = card
		_drag_home = card.global_position
		card.call("begin_drag")
		_play_zone.visible = true
	card.global_position = at - card.size * 0.5
	var hot := _is_over_play_zone(at)
	if hot != _drag_hot:
		_drag_hot = hot
		_set_play_zone_hot(hot)


func _on_card_released(card: Control, at: Vector2, was_drag: bool) -> void:
	if _press_card != card and _drag_card != card:
		return
	_press_card = null
	_drag_card = null
	card.call("end_drag")
	var play := (was_drag and _is_over_play_zone(at)) or not was_drag
	_drag_hot = false
	_set_play_zone_hot(false)
	_play_zone.visible = false
	if not play:
		_return_card(card, false)
		return
	# 规则校验在**飞行之前**：没有兵营就地抖动回弹，不做"飞出去再飞回来"的假动作
	if not bool(card.get("playable")):
		card.call("shake")
		_show_toast(I18n.t("battle.reason." + String(card.get("reason"))), 1.5)
		_return_card(card, true)
		return
	_play_card(card)


func _is_over_play_zone(at: Vector2) -> bool:
	var line := _hand_area.get_global_rect().position.y - 8.0
	return at.y <= line


func _set_play_zone_hot(hot: bool) -> void:
	_play_zone_label.text = I18n.t("battle.play_zone_release") if hot else I18n.t("battle.play_zone")
	var sb := _play_zone.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		var flat := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
		flat.bg_color = Color(0.898, 0.749, 0.416, 0.34) if hot else Color(0.749, 0.588, 0.271, 0.18)
		flat.border_color = Color(0.955, 0.847, 0.478, 0.95) if hot else Color(0.749, 0.588, 0.271, 0.75)
		_play_zone.add_theme_stylebox_override("panel", flat)


## 回弹：把牌送回它原来的手牌位（不销毁重建 —— 重建会变成"又抽了一张牌"）
func _return_card(card: Control, delay: float) -> void:
	if not is_instance_valid(card):
		return
	var t := create_tween()
	if delay > 0.0:
		t.tween_interval(delay)
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	t.tween_property(card, "global_position", _drag_home, 0.18)


## 真正打出：先飞向场地中央，落定后再让 Model 结算（不是"点一下直接生效"）
func _play_card(card: Control) -> void:
	var card_id := String(card.get("card_id"))
	var kind := String(card.get("kind"))
	var to := Vector2(size.x * 0.5 - card.size.x * 0.5, size.y * 0.42)
	var t := create_tween().set_parallel(true)
	t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(card, "global_position", to, 0.2)
	t.tween_property(card, "scale", Vector2(1.05, 1.05), 0.2)
	t.chain().tween_callback(func() -> void: _commit_card(card, card_id, kind))


func _commit_card(card: Control, card_id: String, kind: String) -> void:
	if _root == null:
		return
	if kind == "build":
		_root.call("arm_build", card_id)
	elif kind == "strategy":
		_root.call("play_strategy", card_id)
	else:
		_root.call("train_card", card_id)
	_fly_to_discard(card)
	_cards.erase(card)
	_hand_sig = ""
	# 立刻按 Model 的新状态重排手牌（不等下一次 10Hz 刷新）
	var st: Variant = _root.get("_state")
	if st is Dictionary:
		_sync_hand(st, String(_root.get("phase_name")), _last_extra)


var _last_state: Dictionary = {}
var _last_phase := "planning"
var _last_extra: Dictionary = {}
var _last_status := ""
var _drag_home := Vector2.ZERO
