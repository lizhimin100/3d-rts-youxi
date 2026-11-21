@tool
extends Control
## 开发者编辑器背景：深岩渐变 + 两团冷光 + 等高线（不是网格）。

var accent: Color = Color("#4EA1FF")


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var w := size.x
	var h := size.y
	var top := Color("#151B27")
	var bot := Color("#0F131C")
	var bands := 28
	for i in bands:
		var t := float(i) / float(bands - 1)
		var c := top.lerp(bot, t)
		draw_rect(Rect2(0.0, h * float(i) / float(bands), w, h / float(bands) + 1.0), c)
	draw_circle(Vector2(w * 0.18, h * 0.02), w * 0.30, Color(accent.r, accent.g, accent.b, 0.055))
	draw_circle(Vector2(w * 0.92, h * 0.12), w * 0.18, Color(0.18, 0.45, 0.55, 0.035))
	for k in 7:
		var y0 := h * (0.30 + 0.09 * float(k))
		var pts := PackedVector2Array()
		for i in 40:
			var x := w * float(i) / 39.0
			var y := y0 + sin(x * 0.006 + float(k) * 1.7) * (8.0 + float(k) * 2.5)
			pts.append(Vector2(x, y))
		draw_polyline(pts, Color(1, 1, 1, 0.018), 1.0, true)
