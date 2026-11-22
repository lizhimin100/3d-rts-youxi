extends Control
## 职责：一张可打出的卡牌（**可编辑场景** `卡牌.tscn` 的根）——
##       悬停上浮放大、按住拖动、松手飞向出牌区/回弹，以及"打不出去"时的抖动。
## 属于：Screens/hud（屏幕像素层）
##
## 纪律：
##   · 所有静态布局都在 `卡牌.tscn` 里（节点名就是契约），本脚本只做三件事：
##     绑定引用 → 写文本/数值 → 播动画；
##   · 文案零写死中文（全部 I18n.t），卡名/描述来自 Content/data/*.json；
##   · 本脚本**不判断规则**：能不能打、缺什么，一律读 Model 给的 available / reason。
##
## 节点契约（改名要同步 卡牌.tscn 与 战役HUD.gd）：
##   Visual / Body / Title / Art / Desc / Foot / RoleTag / Units / CostOrb / Cost

signal card_pressed(card: Control)
signal card_dragged(card: Control, at: Vector2)
signal card_released(card: Control, at: Vector2, was_drag: bool)

const HOVER_LIFT := -18.0
const HOVER_SCALE := 1.10
const DRAG_SCALE := 0.92

var card_id := ""
## 卡牌种类：build / train / strategy（决定名字前缀与色带）
var kind := "train"
var role := ""
var cost := 0
var playable := true
var reason := "ok"

var _hovered := false
var _pressed := false
var _press_at := Vector2.ZERO
var _drag_active := false
var _base_y := 0.0
var _tween: Tween = null

@onready var _visual: PanelContainer = %Visual
@onready var _title: Label = %Title
@onready var _art: TextureRect = %Art
@onready var _desc: Label = %Desc
@onready var _role: Label = %RoleTag
@onready var _units: Label = %Units
@onready var _orb: PanelContainer = %CostOrb
@onready var _cost: Label = %Cost


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	pivot_offset = size * 0.5
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)


## 由 HUD 调用：把 Model/数据里的卡面写进节点。
## meta = { display_name, cost_cp, role, kind, units, available, reason, art, tint, tag_line }
func setup(meta: Dictionary) -> void:
	card_id = String(meta.get("card_id", ""))
	kind = String(meta.get("kind", "train"))
	role = String(meta.get("role", ""))
	cost = int(meta.get("cost_cp", 0))
	playable = bool(meta.get("available", true))
	reason = String(meta.get("reason", "ok"))
	_title.text = String(meta.get("display_name", card_id))
	_cost.text = str(cost)
	_units.text = I18n.t("battle.card.units", {"n": int(meta.get("units", 0))}) \
		if int(meta.get("units", 0)) > 0 else ""
	_desc.text = String(meta.get("desc", ""))
	_role.text = String(meta.get("tag_line", ""))
	var tex_path := String(meta.get("art", ""))
	if not tex_path.is_empty() and ResourceLoader.exists(tex_path):
		_art.texture = load(tex_path) as Texture2D
	_art.visible = _art.texture != null
	_apply_tint(meta)
	_apply_disabled()
	tooltip_text = I18n.t("battle.reason." + reason) if not playable else String(meta.get("tip", ""))


func _apply_tint(meta: Dictionary) -> void:
	var tint := Color(String(meta.get("tint", "#E9DFCB"))) if meta.has("tint") else Color("#E9DFCB")
	var sb := _visual.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		var flat := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
		flat.bg_color = Color(tint.r, tint.g, tint.b, 0.97)
		_visual.add_theme_stylebox_override("panel", flat)
	var orb := _orb.get_theme_stylebox("panel")
	if orb is StyleBoxFlat:
		var of := (orb as StyleBoxFlat).duplicate() as StyleBoxFlat
		of.bg_color = Color(tint.r * 0.55, tint.g * 0.42, tint.b * 0.36, 0.98)
		_orb.add_theme_stylebox_override("panel", of)


## 打不出去：整张卡压暗、斜纹提示（不是靠"按钮变灰"）
func _apply_disabled() -> void:
	modulate = Color(1, 1, 1, 1) if playable else Color(0.72, 0.70, 0.68, 0.85)


# ===========================================================================
# 悬停 / 按下 / 拖动
# ===========================================================================
func _on_enter() -> void:
	if _drag_active:
		return
	_hovered = true
	_anim(Vector2(HOVER_SCALE, HOVER_SCALE), HOVER_LIFT, 0.12, 3)


func _on_exit() -> void:
	if _drag_active:
		return
	_hovered = false
	_anim(Vector2.ONE, 0.0, 0.14, 2)


## 动画只碰两样东西：卡壳自身的 scale（容器不管这个）和 Visual 的 y 偏移
## （Visual 是 CardRoot 的锚定子节点，不归 HBoxContainer 排版）。
## **不要**动 `position:y` —— 容器每次重排都会把你写回去，上浮会"弹一下就没"。
func _anim(to_scale: Vector2, y_off: float, dur: float, trans: int) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(trans).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", to_scale, dur)
	_tween.tween_property(_visual, "position:y", _base_y + y_off, dur)


func begin_drag() -> void:
	_drag_active = true
	_hovered = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	scale = Vector2(DRAG_SCALE, DRAG_SCALE)
	modulate = Color(1, 1, 1, 0.96)


func end_drag() -> void:
	_drag_active = false
	scale = Vector2.ONE


## 打不出去：左右抖动 + 弹回原位（"点一下直接生效"的反面）
func shake() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var x0 := _visual.position.x
	var t := create_tween()
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	for i in 4:
		var dx := 7.0 if i % 2 == 0 else -7.0
		t.tween_property(_visual, "position:x", x0 + dx, 0.045)
	t.tween_property(_visual, "position:x", x0, 0.06)


func _gui_input(event: InputEvent) -> void:
	if not playable:
		if event is InputEventMouseButton:
			var mb0 := event as InputEventMouseButton
			if mb0.button_index == MOUSE_BUTTON_LEFT and mb0.pressed:
				shake()
				card_pressed.emit(self)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_pressed = true
			_press_at = mb.global_position
			card_pressed.emit(self)
			accept_event()
		else:
			_pressed = false
			card_released.emit(self, mb.global_position, _drag_active)
			accept_event()
	elif event is InputEventMouseMotion and _pressed:
		var mm := event as InputEventMouseMotion
		if not _drag_active and mm.global_position.distance_to(_press_at) > 7.0:
			_drag_active = true
		if _drag_active:
			card_dragged.emit(self, mm.global_position)
			accept_event()
