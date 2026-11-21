@tool
extends Control
## 框选矩形（2D 屏幕覆盖层）
## 属于：Screens/editor/map_shell（开发工具，不进发行版）
##
## 只画一个矩形：编辑器把鼠标拖拽的屏幕坐标换算成"相对本控件"的矩形丢进来，
## 这里不参与任何拾取逻辑（拾取在 shell_view.gd，用的是同一份屏幕坐标）。

var box := Rect2()
var active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func show_box(rect: Rect2) -> void:
	box = rect
	active = true
	queue_redraw()


func clear_box() -> void:
	active = false
	queue_redraw()


func _draw() -> void:
	if not active:
		return
	draw_rect(box, Color(0.31, 0.68, 1.0, 0.12), true)
	draw_rect(box, Color(0.42, 0.78, 1.0, 0.92), false, 1.5)
	# 四角短角标：小图上也能看清框在哪
	var c := box.position
	var e := box.position + box.size
	var arm := minf(14.0, minf(box.size.x, box.size.y) * 0.25)
	var col := Color(0.62, 0.88, 1.0, 0.95)
	draw_line(c, c + Vector2(arm, 0), col, 2.0)
	draw_line(c, c + Vector2(0, arm), col, 2.0)
	draw_line(Vector2(e.x, c.y), Vector2(e.x - arm, c.y), col, 2.0)
	draw_line(Vector2(e.x, c.y), Vector2(e.x, c.y + arm), col, 2.0)
	draw_line(Vector2(c.x, e.y), Vector2(c.x + arm, e.y), col, 2.0)
	draw_line(Vector2(c.x, e.y), Vector2(c.x, e.y - arm), col, 2.0)
	draw_line(e, e - Vector2(arm, 0), col, 2.0)
	draw_line(e, e - Vector2(0, arm), col, 2.0)
