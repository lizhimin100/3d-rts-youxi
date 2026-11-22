extends Control
## 职责：把场上**每一名单兵**的血条画在 3D 之上（只画"挨过打的"和"被选中的"）。
## 属于：Screens/world/units（表现层）
##
## 口径：
##   · 单兵制：一条血条 = 一个人（不再有"小队聚合血条"）；
##   · 满血的人不画 —— 60 个人同时挂血条会把战场糊住；挨过打才出现，
##     选中的人永远显示（信息优先）；
##   · 只读 SquadView 的 hp / max_hp；不写任何规则。

const BAR_W := 24.0
const BAR_H := 3.5
const PLAYER_EDGE := Color(0.36, 0.62, 0.95)
const ENEMY_EDGE := Color(0.92, 0.42, 0.34)
const BG := Color(0.04, 0.05, 0.07, 0.78)

var _view: Dictionary = {}
var _camera: Camera3D = null
var _selected: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = get_viewport_rect().size
	get_viewport().size_changed.connect(func() -> void: size = get_viewport_rect().size)


func set_view(view: Dictionary, camera: Camera3D, selected: Array = []) -> void:
	_view = view
	_camera = camera
	_selected = selected
	queue_redraw()


func _draw() -> void:
	if _camera == null or _view.is_empty() or not is_instance_valid(_camera):
		return
	var vp := get_viewport_rect().size
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if not bool(sq.get("active", true)):
			continue
		var hp := float(sq.get("hp", 0.0))
		var max_hp := float(sq.get("max_hp", 1.0))
		if hp <= 0.0 or max_hp <= 0.0:
			continue
		var sel := _selected.has(int(sq.get("id", 0)))
		if not sel and hp >= max_hp - 0.01:
			continue
		var sp := _camera.unproject_position(Vector3(float(sq.get("x", 0.0)), 2.12, float(sq.get("z", 0.0))))
		if sp.x < -40.0 or sp.x > vp.x + 40.0 or sp.y < -20.0 or sp.y > vp.y + 40.0:
			continue
		var frac := clampf(hp / max_hp, 0.0, 1.0)
		var x := sp.x - BAR_W * 0.5
		var y := sp.y
		draw_rect(Rect2(x - 1.0, y - 1.0, BAR_W + 2.0, BAR_H + 2.0), BG)
		draw_rect(Rect2(x, y, BAR_W, BAR_H), Color(0.16, 0.18, 0.2, 0.9))
		draw_rect(Rect2(x, y, BAR_W * frac, BAR_H), _hp_color(frac))
		var edge := PLAYER_EDGE if int(sq.get("side", 0)) == 0 else ENEMY_EDGE
		draw_rect(Rect2(x - 1.0, y - 1.0, BAR_W + 2.0, BAR_H + 2.0), edge, false, 1.0)


func _hp_color(frac: float) -> Color:
	if frac > 0.55:
		return Color(0.42, 0.78, 0.38)
	if frac > 0.28:
		return Color(0.9, 0.76, 0.3)
	return Color(0.88, 0.3, 0.28)
