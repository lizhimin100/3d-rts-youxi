@tool
extends Control
## 建筑小图标（列表/表单共用，纯几何绘制）。

var kind := "keep"
var accent := Color("#F0B95A")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var w := size.x
	var h := size.y
	var c := Vector2(w * 0.5, h * 0.62)
	draw_circle(Vector2(c.x, h * 0.86), w * 0.34, Color(0.0, 0.0, 0.0, 0.30))
	var base := Color("#243146")
	var edge := Color(accent.r, accent.g, accent.b, 0.85)
	var top := Color(accent.r, accent.g, accent.b, 0.24)
	match kind:
		"keep":
			draw_rect(Rect2(c.x - 16, c.y - 12, 32, 24), base)
			draw_rect(Rect2(c.x - 16, c.y - 12, 32, 4), top)
			for dx in [-16, -4, 8]:
				draw_rect(Rect2(c.x + dx, c.y - 22, 8, 12), base)
				draw_rect(Rect2(c.x + dx, c.y - 22, 8, 3), top)
			draw_line(Vector2(c.x, c.y - 22), Vector2(c.x, c.y - 34), edge, 1.5)
			draw_colored_polygon(PackedVector2Array([Vector2(c.x, c.y - 34), Vector2(c.x + 9, c.y - 31), Vector2(c.x, c.y - 28)]), edge)
		"farm":
			draw_rect(Rect2(c.x - 18, c.y - 8, 30, 18), base)
			draw_colored_polygon(PackedVector2Array([Vector2(c.x - 22, c.y - 8), Vector2(c.x - 3, c.y - 22), Vector2(c.x + 16, c.y - 8)]), top)
			for i in 3:
				draw_line(Vector2(c.x + 6 + i * 5, c.y), Vector2(c.x + 8 + i * 5, c.y + 12), edge, 1.0)
		"barracks":
			draw_rect(Rect2(c.x - 20, c.y - 8, 40, 20), base)
			draw_colored_polygon(PackedVector2Array([Vector2(c.x - 23, c.y - 8), Vector2(c.x, c.y - 22), Vector2(c.x + 23, c.y - 8)]), top)
			draw_line(Vector2(c.x + 16, c.y - 22), Vector2(c.x + 16, c.y - 35), edge, 1.4)
			draw_rect(Rect2(c.x + 16, c.y - 35, 9, 7), Color(edge.r, edge.g, edge.b, 0.55))
		"watchtower", "tower":
			draw_rect(Rect2(c.x - 9, c.y - 18, 18, 30), base)
			draw_rect(Rect2(c.x - 13, c.y - 24, 26, 8), base)
			draw_colored_polygon(PackedVector2Array([Vector2(c.x - 14, c.y - 24), Vector2(c.x, c.y - 36), Vector2(c.x + 14, c.y - 24)]), top)
			draw_line(Vector2(c.x, c.y - 36), Vector2(c.x, c.y - 44), edge, 1.4)
		_:
			draw_rect(Rect2(c.x - 14, c.y - 12, 28, 24), base)
	draw_polyline(PackedVector2Array([Vector2(c.x - 18, c.y + 14), Vector2(c.x + 18, c.y + 14)]), edge, 1.4)

