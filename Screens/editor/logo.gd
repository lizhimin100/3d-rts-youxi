@tool
extends Control
## 开发者编辑器品牌标：六边岛 + 三向海流 + 金色灯塔点。

func _ready() -> void:
	custom_minimum_size = Vector2(42.0, 42.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var c := Vector2(size.x * 0.5, size.y * 0.5)
	var pts := PackedVector2Array()
	for i in 6:
		var a := -PI * 0.5 + TAU * float(i) / 6.0
		pts.append(c + Vector2(cos(a), sin(a)) * 19.0)
	draw_colored_polygon(pts, Color("#1B2230"))
	var rim := pts.duplicate()
	rim.append(pts[0])
	draw_polyline(rim, Color("#4EA1FF"), 2.0, true)
	var inner := PackedVector2Array()
	for i in 3:
		var a := -PI * 0.5 + TAU * float(i) / 3.0
		inner.append(c + Vector2(cos(a), sin(a)) * 10.0)
	inner.append(inner[0])
	draw_polyline(inner, Color("#45D6A2"), 1.6, true)
	draw_circle(c, 3.2, Color("#F0B95A"))
