@tool
extends Control
## 靶场两条 DPS 对比条（自定义绘制，字体随主题）。

var a_value := 0.0
var b_value := 0.0
var a_label := ""
var b_label := ""
var a_color := Color("#B18CFF")
var b_color := Color("#4EA1FF")

func set_data(av: float, bv: float, al: String, bl: String, ac: Color, bc: Color) -> void:
	a_value = av
	b_value = bv
	a_label = al
	b_label = bl
	a_color = ac
	b_color = bc
	queue_redraw()

func _draw() -> void:
	var f := get_theme_default_font()
	var w := size.x
	var maxv := maxf(maxf(a_value, b_value), 0.01)
	var rows := [
		[a_label, a_value, a_color, 34.0],
		[b_label, b_value, b_color, 66.0],
	]
	for row in rows:
		var label := String(row[0])
		var val := float(row[1])
		var c: Color = row[2]
		var y := float(row[3])
		if f != null:
			draw_string(f, Vector2(0.0, y - 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color("#96A3BA"))
			draw_string(f, Vector2(w - 58.0, y - 5.0), "%.1f" % val, HORIZONTAL_ALIGNMENT_RIGHT, 58.0, 12, c)
		draw_rect(Rect2(0.0, y, w, 7.0), Color("#111722"))
		draw_rect(Rect2(0.0, y, maxf(w * val / maxv, 2.0), 7.0), Color(c.r, c.g, c.b, 0.82))

