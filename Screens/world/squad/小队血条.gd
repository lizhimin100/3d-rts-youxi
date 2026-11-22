extends Control
## 职责：每支小队**一条聚合血条**（成员血量之和），画在 3D 场景之上。
## 属于：Screens/world/squad（表现层）
##
## 口径：
##   · 只读 SquadView 的 hp / max_hp / alive_count / member_count；
##   · 绝不画单个成员的血条 —— 小队是原子单位；
##   · 血条宽度固定 54px，不做距离缩放（远看更整齐）。

const BAR_W := 54.0
const BAR_H := 5.0
const PLAYER_EDGE := Color(0.36, 0.62, 0.95)
const ENEMY_EDGE := Color(0.92, 0.42, 0.34)
const BG := Color(0.04, 0.05, 0.07, 0.78)
const TEXT := Color(0.92, 0.94, 0.96, 0.9)

var _view: Dictionary = {}
var _camera: Camera3D = null
var _font: Font = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	size = get_viewport_rect().size
	get_viewport().size_changed.connect(func() -> void: size = get_viewport_rect().size)
	_font = ThemeDB.fallback_font


func set_view(view: Dictionary, camera: Camera3D) -> void:
	_view = view
	_camera = camera
	queue_redraw()


func _draw() -> void:
	if _camera == null or _view.is_empty():
		return
	if not is_instance_valid(_camera):
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
		var world := Vector3(float(sq.get("x", 0.0)), 2.15, float(sq.get("z", 0.0)))
		var sp := _camera.unproject_position(world)
		if sp.x < -80.0 or sp.x > vp.x + 80.0 or sp.y < -40.0 or sp.y > vp.y + 80.0:
			continue
		var frac := clampf(hp / max_hp, 0.0, 1.0)
		var x := sp.x - BAR_W * 0.5
		var y := sp.y
		draw_rect(Rect2(x - 1.0, y - 1.0, BAR_W + 2.0, BAR_H + 2.0), BG)
		var edge := PLAYER_EDGE if int(sq.get("side", 0)) == 0 else ENEMY_EDGE
		draw_rect(Rect2(x, y, BAR_W, BAR_H), Color(0.16, 0.18, 0.2, 0.9))
		draw_rect(Rect2(x, y, BAR_W * frac, BAR_H), _hp_color(frac))
		draw_rect(Rect2(x - 1.0, y - 1.0, BAR_W + 2.0, BAR_H + 2.0), edge, false, 1.0)
		if _font != null:
			var text := "%d/%d" % [int(sq.get("alive_count", 0)), int(sq.get("member_count", 0))]
			draw_string(_font, Vector2(sp.x - 26.0, y - 5.0), text,
				HORIZONTAL_ALIGNMENT_CENTER, 52.0, 10, TEXT)


func _hp_color(frac: float) -> Color:
	if frac > 0.55:
		return Color(0.42, 0.78, 0.38)
	if frac > 0.28:
		return Color(0.9, 0.76, 0.3)
	return Color(0.88, 0.3, 0.28)
