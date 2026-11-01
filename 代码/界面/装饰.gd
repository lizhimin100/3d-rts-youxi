extends RefCounted
## **自绘小件**（分隔线 / 菱形 / 角饰 / 心与菱形）—— 界面里那些"不值当塞一张贴图"的东西。
##
## 为什么单开一个文件：分隔线要和铭牌、铭牌要和数值列、数值列要和底板**同一套金色**，
## 各写各的 draw 就会变成三种黄。这里所有颜色都从 `accent()` 推导，只此一份。
##
## 用法（跨文件引用内部类）：
##   const Deco := preload("res://代码/界面/装饰.gd")
##   var r := Deco.Rule.new()
##   r.gem = true
##   add_child(r)

const Spec := preload("res://代码/界面/界面规格.gd")


## 金色主色：**只从界面规格取一份**，别在这里再写死一个黄
static func gold() -> Color:
	return Spec.accent()


# ===========================================================================
# 分隔线：中间亮、两端淡出，中间可挂一枚菱形
# ===========================================================================
class Rule extends Control:
	var accent: Color = Color(0.85, 0.71, 0.36)
	## 线宽
	var thick: float = 1.0
	## 中间挂不挂菱形（铭牌下沿要挂，数值行之间不挂）
	var gem: bool = false
	## 整体透明度
	var alpha: float = 0.55

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0.0, 11.0 if gem else 3.0)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w < 8.0:
			return
		var cy: float = roundf(h * 0.5)
		# 三段：两端淡（0.10）→ 中间亮（1.0）。用三段就够，24 段只会多 21 个 draw call。
		var segs := [
			[0.0, 0.30, 0.10],
			[0.30, 0.70, 1.0],
			[0.70, 1.0, 0.10],
		]
		for s in segs:
			var x0: float = w * float(s[0])
			var x1: float = w * float(s[1])
			var a: float = alpha * float(s[2])
			draw_rect(Rect2(x0, cy - thick * 0.5, x1 - x0, thick),
					Color(accent.r, accent.g, accent.b, a), true)
		# 中间再压一条更亮的细线，读成"金属高光"
		draw_rect(Rect2(w * 0.34, cy - thick * 0.5, w * 0.32, maxf(thick * 0.6, 1.0)),
				Color(1.0, 0.97, 0.88, alpha * 0.55), true)
		if gem:
			_draw_gem(Vector2(w * 0.5, cy), 4.5)


	func _draw_gem(c: Vector2, r: float) -> void:
		var pts := PackedVector2Array([
			c + Vector2(0.0, -r), c + Vector2(r, 0.0),
			c + Vector2(0.0, r), c + Vector2(-r, 0.0)])
		draw_colored_polygon(pts, Color(accent.r, accent.g, accent.b, minf(alpha * 1.6, 1.0)))
		pts.append(pts[0])
		draw_polyline(pts, Color(1.0, 0.97, 0.90, alpha * 0.8), 1.0)


# ===========================================================================
# 菱形 / 三角小标（铭牌前的引子、行首的子弹）
# ===========================================================================
class Diamond extends Control:
	var accent: Color = Color(0.85, 0.71, 0.36)
	var filled: bool = true
	## 0 = 菱形，1 = 右向三角（"这条数值属于上面那行"）
	var shape: int = 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var s: float = minf(size.x, size.y)
		if s < 3.0:
			return
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		var pts: PackedVector2Array
		if shape == 1:
			pts = PackedVector2Array([
				c + Vector2(-s * 0.26, -s * 0.34),
				c + Vector2(s * 0.32, 0.0),
				c + Vector2(-s * 0.26, s * 0.34)])
		else:
			pts = PackedVector2Array([
				c + Vector2(0.0, -s * 0.42), c + Vector2(s * 0.42, 0.0),
				c + Vector2(0.0, s * 0.42), c + Vector2(-s * 0.42, 0.0)])
		if filled:
			draw_colored_polygon(pts, accent)
		pts.append(pts[0])
		draw_polyline(pts, Color(accent.r, accent.g, accent.b, 0.85), 1.2)


# ===========================================================================
# 生命的心 / 法力的菱形（选中卡里的"这一行是什么"标记）
# ===========================================================================
class Pip extends Control:
	const HEART := 0
	const DIAMOND := 1

	var kind: int = HEART
	var col: Color = Color(0.42, 0.86, 0.48)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func feed(k: int, c: Color) -> void:
		if k == kind and c == col:
			return
		kind = k
		col = c
		queue_redraw()

	func _draw() -> void:
		var s: float = minf(size.x, size.y)
		if s < 6.0:
			return
		var o := Vector2((size.x - s) * 0.5, (size.y - s) * 0.5)
		if kind == HEART:
			# 两个圆 + 一个下三角：比贝塞尔心形便宜，小尺寸下反而更"硬"更好认
			draw_circle(o + Vector2(s * 0.32, s * 0.34), s * 0.27, col)
			draw_circle(o + Vector2(s * 0.68, s * 0.34), s * 0.27, col)
			draw_colored_polygon(PackedVector2Array([
					o + Vector2(s * 0.055, s * 0.40),
					o + Vector2(s * 0.945, s * 0.40),
					o + Vector2(s * 0.50, s * 0.965)]), col)
		else:
			draw_colored_polygon(PackedVector2Array([
					o + Vector2(s * 0.50, s * 0.02),
					o + Vector2(s * 0.97, s * 0.50),
					o + Vector2(s * 0.50, s * 0.98),
					o + Vector2(s * 0.03, s * 0.50)]), col)


# ===========================================================================
# 头像外框的角饰：四角 L 形金线 + 一枚小铆钉
# ===========================================================================
class Corners extends Control:
	var accent: Color = Color(0.85, 0.71, 0.36)
	var arm: float = 13.0
	var alpha: float = 0.85

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w < arm * 2.4 or h < arm * 2.4:
			return
		var c := Color(accent.r, accent.g, accent.b, alpha)
		var c2 := Color(1.0, 0.96, 0.86, alpha * 0.45)
		for sx in [0.0, 1.0]:
			for sy in [0.0, 1.0]:
				var x: float = arm if sx < 0.5 else w - arm
				var y: float = arm if sy < 0.5 else h - arm
				var dx: float = 1.0 if sx < 0.5 else -1.0
				var dy: float = 1.0 if sy < 0.5 else -1.0
				draw_line(Vector2(x, y), Vector2(x + dx * arm * 1.5, y), c2, 1.0)
				draw_line(Vector2(x, y), Vector2(x, y + dy * arm * 1.5), c2, 1.0)
				# 小铆钉：外圈 + 深心，2px 的实心方块也能读成"钉"
				draw_circle(Vector2(x, y), 2.2, c)
				draw_circle(Vector2(x, y), 1.0, Color(0.10, 0.09, 0.07, 0.9))
