class_name RtsButtonFrame
extends Control
## **石金按钮框** —— 命令卡 / 队列格的"魔兽式"外框，全部由 `_draw()` 画。
##
## 为什么不用 StyleBoxFlat：一套奇幻按钮要同时有
##   石面竖向渐变 + 双层金线 + 四角铆钉 + 顶沿受光 + 按下凹陷 + 分类色竖条，
## 而 StyleBoxFlat 只有**单色填充 + 单色边框**，怎么调都是"平平无奇的方块"
## （玩家原话："不要现在这种平平无奇、还很挤的感觉"）。
##
## 两条纪律：
##   1. `_draw` 只在 `queue_redraw()`（状态/尺寸变化）时跑，静止时零成本 ——
##      **别再自己做 `_sig` 缓存**：那层缓存会在"第一次绘制时尺寸还没灌进来"的
##      时序下把后续真实绘制全部跳过，表现为按钮永远透明（这一版踩过一次）；
##   2. 颜色只从 `界面规格.accent()` 与这里的一组常量来，调用点只传分类色 `tint`。

const Spec := preload("res://代码/界面/界面规格.gd")

enum Look { NORMAL, HOVER, PRESSED, DISABLED }

## 圆角
const RAD := 7.0

## 石面三档（上 / 中 / 下）。比底栏亮一档：按钮要"浮"在石台上。
const ST_TOP := Color(0.243, 0.251, 0.288)
const ST_MID := Color(0.152, 0.159, 0.188)
const ST_BOT := Color(0.082, 0.086, 0.104)

## 分类色（哪一类指令：移动/攻击/建造…）。只用来染左侧竖条与悬停暖光。
var tint: Color = Color(0.90, 0.88, 0.82):
	set(v):
		if v == tint:
			return
		tint = v
		queue_redraw()

var look: int = Look.NORMAL:
	set(v):
		if v == look:
			return
		look = v
		queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	# ★ 必须显式重画一次：控件的第一次 `_draw` 常常发生在"尺寸还是 0"的那一帧
	#   （`_draw` 里 size 太小会直接 return），而尺寸被容器灌进来时 `resized`
	#   可能在 `_ready` **之前**就发完了 —— 此后再没有东西触发重画，
	#   按钮就永远是"透明"的（这一版踩过：看着像框根本没生成）。
	queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w < 16.0 or h < 14.0:
		return

	var a: Color = Spec.accent()
	var dim: float = 0.47 if look == Look.DISABLED else 1.0
	var r := Rect2(Vector2.ZERO, size)

	# --- 1. 石面：8 条竖向渐变（按下时反转：上暗下亮 = 凹进去）---
	var bands: int = 8
	var bh: float = h / float(bands)
	for i in bands:
		var t: float = (float(i) + 0.5) / float(bands)
		if look == Look.PRESSED:
			t = 1.0 - t
		var col: Color
		if t < 0.55:
			col = ST_TOP.lerp(ST_MID, minf(t * 1.5, 1.0))
		else:
			col = ST_MID.lerp(ST_BOT, (t - 0.55) / 0.45)
		if look == Look.HOVER:
			col = col.lerp(tint, 0.055)
		col.a = 0.985
		col = _shade(col, dim)
		var y: float = float(i) * bh
		var ins: float = _inset(y, h, RAD)
		draw_rect(Rect2(ins, y, w - ins * 2.0, bh + 0.7), col, true)

	# --- 2. 顶沿受光 / 底沿投影（"压出来的还是凸出来的"全靠这两条）---
	draw_rect(Rect2(RAD * 0.8, 0.8, w - RAD * 1.6, 1.2),
			Color(1.0, 0.98, 0.92, 0.085 * dim), true)
	draw_rect(Rect2(RAD * 0.8, h - 2.2, w - RAD * 1.6, 1.2),
			Color(0.0, 0.0, 0.0, 0.34), true)

	# --- 3. 外框：深黑描边 → 金线 → 内金线（三层才有"镶边"的厚度）---
	_stroke(r.grow(-0.5), 1.0, Color(0.02, 0.02, 0.03, 0.85 * dim), 1.4)
	var gold_a: float = 0.66
	if look == Look.HOVER:
		gold_a = 0.98
	elif look == Look.DISABLED:
		gold_a = 0.18
	elif look == Look.PRESSED:
		gold_a = 0.30
	_stroke(r.grow(-2.2), RAD - 2.0, Color(a.r, a.g, a.b, gold_a * dim), 1.5)
	_stroke(r.grow(-5.6), maxf(RAD - 5.0, 1.5), Color(1.0, 0.95, 0.84, 0.055 * dim), 1.0)

	# --- 4. 左侧分类色条（保留"这是哪一类"的读法）---
	var bar_h: float = h - 12.0
	if bar_h > 6.0:
		var bx: float = RAD * 0.55
		draw_rect(Rect2(bx, 6.0, 2.6, bar_h), Color(tint.r, tint.g, tint.b, 0.80 * dim), true)
		draw_rect(Rect2(bx + 2.6, 6.0, 1.0, bar_h), Color(0.0, 0.0, 0.0, 0.35), true)

	# --- 5. 四角铆钉（小菱形；让四角"钉住"而不是被圆角吃掉）---
	var s: float = 2.6
	for sx in [0.0, 1.0]:
		for sy in [0.0, 1.0]:
			var cx: float = RAD + 2.0 if sx < 0.5 else w - RAD - 2.0
			var cy: float = 4.4 if sy < 0.5 else h - 4.4
			draw_colored_polygon(PackedVector2Array([
				Vector2(cx, cy - s), Vector2(cx + s * 0.85, cy),
				Vector2(cx, cy + s), Vector2(cx - s * 0.85, cy)]),
				Color(a.r, a.g, a.b, 0.55 * dim))

	# --- 6. 悬停 / 按下：一层很薄的雾（不夺图标颜色）---
	if look == Look.HOVER:
		draw_rect(Rect2(RAD * 0.8, 2.0, w - RAD * 1.6, h * 0.34),
				Color(tint.r, tint.g, tint.b, 0.07), true)
	elif look == Look.PRESSED:
		draw_rect(r.grow(-1.5), Color(0.0, 0.0, 0.0, 0.16), true)


## 圆角描边（StyleBoxFlat 只能四边同色，但这里要精确控制内缩）
func _stroke(r: Rect2, rad: float, col: Color, w: float) -> void:
	if r.size.x < 6.0 or r.size.y < 6.0:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(int(maxf(rad, 1.0)))
	sb.corner_detail = 10
	sb.border_color = col
	sb.set_border_width_all(int(maxf(w, 1.0)))
	sb.anti_aliasing = true
	draw_style_box(sb, r)


## 圆角在某一高度处要内缩多少（防止直角切出耳朵）
func _inset(y: float, h: float, rad: float) -> float:
	var d: float = minf(y, h - y)
	if d >= rad:
		return 0.0
	var k: float = rad - d
	return rad - sqrt(maxf(rad * rad - k * k, 0.0))


static func _shade(c: Color, k: float) -> Color:
	if k >= 0.999:
		return c
	return Color(c.r * k, c.g * k, c.b * k, c.a)
