class_name RtsOrnatePlate
extends Control
## **奇幻石金底板** —— 底栏那一整条、以及段底的凹槽，全部由它画。
##
## 为什么不用 StyleBoxFlat：StyleBoxFlat 只有**一个纯色**，画不出
## "上亮下暗的石面 + 金色内嵌线 + 四角铆钉 + 顶端徽记"这一整套；
## 铺一张 PNG 又会在拉伸后糊掉（而且改一次尺寸就得重新切图）。
## 这里全部 `_draw()`：只在**尺寸变化**时重画一次，静止时零成本。
##
## 两种形态：
##   BAND    —— 整条底栏：深板岩底 + 顶沿 2px 金线 + 四角 L 形角饰 + 顶心徽记
##   SEGMENT —— 段底（凹槽）：更暗一档、无角饰、只留一圈内嵌金线
##
## 三条纪律：
##   1. **不许每帧 queue_redraw**：尺寸变了才画（`_sig` 比对），否则 60fps 白烧。
##   2. 颜色只从 `Spec.accent()` 与这里的一组常量来，不在调用点传色进去。
##   3. 圆角区里的填充必须按圆弧内缩（见 `_bands`），否则直角会把圆角切出四个"耳朵"。

const Spec := preload("res://代码/界面/界面规格.gd")

enum Kind { BAND, SEGMENT }

## 石底色（2026-11-01 第五版第二稿：**必须能看出"这是一块石台"**。
## 太黑 = 读起来像"UI 没画完"；太亮 = 抢战场。取深板岩 + 顶沿受光）
const STONE_TOP := Color(0.176, 0.184, 0.216)
const STONE_MID := Color(0.098, 0.105, 0.132)
const STONE_BOT := Color(0.048, 0.052, 0.066)

var kind: int = Kind.BAND:
	set(v):
		kind = v
		queue_redraw()

## 顶上那条徽记要不要（段底不画）
var crest: bool = true:
	set(v):
		crest = v
		queue_redraw()

## 中央纹章的横坐标（HUD 会把它挪到"中段与命令卡之间的空白区"正中）。
## <= 0 表示不指定，用自己的中点。
var medallion_x: float = -1.0:
	set(v):
		medallion_x = v
		queue_redraw()

var _sig: Vector2 = Vector2(-1.0, -1.0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_on_resized)


func _on_resized() -> void:
	queue_redraw()


func _radius() -> float:
	return 14.0 if kind == Kind.BAND else 9.0


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w < 24.0 or h < 16.0:
		return
	_sig = size
	var a: Color = Spec.accent()
	var rad: float = _radius()
	var r := Rect2(Vector2.ZERO, size)

	# --- 1. 外投影（只有整条底栏有：它要"压在战场上面"）---
	if kind == Kind.BAND:
		var sh := StyleBoxFlat.new()
		sh.bg_color = Color(0, 0, 0, 0.0)
		sh.set_corner_radius_all(int(rad))
		sh.corner_detail = 12
		sh.shadow_color = Color(0.0, 0.0, 0.0, 0.46)
		sh.shadow_size = 12
		sh.shadow_offset = Vector2(0.0, 4.0)
		draw_style_box(sh, r.grow(-1.0))

	# --- 2. 石面：圆角矩形 + 上亮下暗的自绘条带 ---
	var body := StyleBoxFlat.new()
	body.bg_color = STONE_BOT
	body.set_corner_radius_all(int(rad))
	body.corner_detail = 16
	body.anti_aliasing = true
	draw_style_box(body, r)
	_draw_gradient(r, rad)

	# --- 3. 石纹（细颗粒）：确定性伪随机，只在重画时算一次 ---
	_draw_grain(r, rad)

	# --- 3.5 石砌缝（错缝排列的砌块）+ 中央纹章 ---
	if kind == Kind.BAND:
		_draw_masonry(r, rad)
		_draw_medallion(Vector2(medallion_x if medallion_x > 0.0 else w * 0.5, h * 0.5),
				minf(h * 0.40, 58.0), a)

	# --- 4. 内嵌金线（两层：外圈亮、内圈淡）---
	var in1 := r.grow(-3.5)
	_round_stroke(in1, rad - 3.0, Color(a.r, a.g, a.b, 0.34 if kind == Kind.BAND else 0.18), 1.0)
	var in2 := r.grow(-7.5)
	_round_stroke(in2, maxf(rad - 6.5, 2.0), Color(1.0, 0.96, 0.88, 0.055), 1.0)

	# --- 5. 顶沿：翻出来的石檐 + 亮金细线 + 中央徽记 ---
	if kind == Kind.BAND:
		_draw_cornice(r, rad, a)
		if crest and w > 220.0:
			_draw_crest(Vector2(w * 0.5, 1.0), a)
		_draw_studs(r, rad, a)
		_draw_pilasters(r, rad, a)
		_draw_corners(r, rad, a)


## 顶檐：0~1px 金线 / 2~9px 受光石沿 / 9~10px 投影。
## 这一条是整个底栏"最像建筑"的地方 —— 没有它，再亮的填充也只是一块色块。
func _draw_cornice(r: Rect2, rad: float, a: Color) -> void:
	var w: float = r.size.x
	draw_rect(Rect2(rad + 1.0, 0.0, w - (rad + 1.0) * 2.0, 1.6),
			Color(a.r, a.g, a.b, 0.62), true)
	draw_rect(Rect2(rad + 1.0, 1.6, w - (rad + 1.0) * 2.0, 1.0),
			Color(a.r, a.g, a.b, 0.24), true)
	for i in 6:
		var t: float = float(i) / 6.0
		draw_rect(Rect2(rad + 1.0, 2.6 + float(i), w - (rad + 1.0) * 2.0, 1.05),
				Color(1.0, 0.98, 0.92, 0.135 * (1.0 - t)), true)
	draw_rect(Rect2(rad + 1.0, 8.6, w - (rad + 1.0) * 2.0, 1.6),
			Color(0.0, 0.0, 0.0, 0.34), true)


## 两端壁柱：一条 14px 的竖向石柱 + 内侧金线。
## 有了它，底栏的左右两端才有"建筑感"（和场景里的石墙同一个语汇）。
func _draw_pilasters(r: Rect2, rad: float, a: Color) -> void:
	var w: float = r.size.x
	var h: float = r.size.y
	if w < 320.0 or h < 60.0:
		return
	var pw: float = 15.0
	for side in [0.0, 1.0]:
		var x0: float = rad * 0.55 if side < 0.5 else w - rad * 0.55 - pw
		draw_rect(Rect2(x0, rad * 0.4, pw, h - rad * 0.8), Color(1.0, 0.98, 0.94, 0.030), true)
		var lx: float = x0 + pw if side < 0.5 else x0
		draw_line(Vector2(lx, rad * 0.5), Vector2(lx, h - rad * 0.5),
				Color(a.r, a.g, a.b, 0.26), 1.0, true)
		draw_line(Vector2(lx + (1.0 if side < 0.5 else -1.0), rad * 0.5),
				Vector2(lx + (1.0 if side < 0.5 else -1.0), h - rad * 0.5),
				Color(0.0, 0.0, 0.0, 0.35), 1.0, true)


## 顶沿的菱形铆钉，每 ~190px 一枚：把"一条空带子"变成"一条镶钉的带子"
func _draw_studs(r: Rect2, rad: float, a: Color) -> void:
	var w: float = r.size.x
	var step: float = 190.0
	var n: int = int(maxf(floor((w - rad * 2.0) / step), 1.0))
	if n <= 1:
		return
	var y: float = 4.0
	for i in range(1, n):
		var x: float = rad + (w - rad * 2.0) * float(i) / float(n)
		if absf(x - w * 0.5) < 26.0:
			continue
		var s: float = 3.2
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, y - s), Vector2(x + s * 0.8, y),
			Vector2(x, y + s), Vector2(x - s * 0.8, y)]),
			Color(a.r, a.g, a.b, 0.42))


## 石缝：**只留两条横缝 + 中段几道竖缝**。
## 第一稿画满网格，结果像表格/窗户格 —— 砌块的读法靠"稀疏"，不靠"规整"。
func _draw_masonry(r: Rect2, rad: float) -> void:
	var w: float = r.size.x
	var h: float = r.size.y
	if w < 80.0 or h < 40.0:
		return
	var dark := Color(0.0, 0.0, 0.0, 0.12)
	var light := Color(1.0, 0.98, 0.92, 0.030)
	for i in [1, 2]:
		var y: float = h * float(i) / 3.0
		draw_line(Vector2(rad * 0.6, y), Vector2(w - rad * 0.6, y), dark, 1.0)
		draw_line(Vector2(rad * 0.6, y + 1.0), Vector2(w - rad * 0.6, y + 1.0), light, 1.0)
	var block: float = 208.0
	var x: float = rad * 0.6 + block * 0.5
	var k: int = 0
	while x < w - rad * 0.6:
		draw_line(Vector2(x, h / 3.0 + 2.0), Vector2(x, h * 2.0 / 3.0 - 2.0), dark, 1.0)
		draw_line(Vector2(x + 1.0, h / 3.0 + 2.0), Vector2(x + 1.0, h * 2.0 / 3.0 - 2.0), light, 1.0)
		x += block
		k += 1
		if k > 32:
			break


## 中央纹章：一枚大菱形 + 四向内收的细线 + 外圈弧线。
## 它坐在**底栏正中的空白区**里 —— 玩家要求"中间别被 UI 填满"，
## 于是那块地方必须有东西可看，否则就是"面板没加载出来"。
func _draw_medallion(c: Vector2, r: float, a: Color) -> void:
	if r < 14.0:
		return
	var gold := Color(a.r, a.g, a.b, 0.24)
	var faint := Color(a.r, a.g, a.b, 0.13)
	# 外圈：一个大菱形框
	var outer := r
	var pts := PackedVector2Array([
		c + Vector2(0.0, -outer), c + Vector2(outer * 1.55, 0.0),
		c + Vector2(0.0, outer), c + Vector2(-outer * 1.55, 0.0)])
	pts.append(pts[0])
	draw_polyline(pts, gold, 1.0, true)
	# 内菱形
	var inner: float = r * 0.46
	var ip := PackedVector2Array([
		c + Vector2(0.0, -inner), c + Vector2(inner * 1.55, 0.0),
		c + Vector2(0.0, inner), c + Vector2(-inner * 1.55, 0.0)])
	draw_colored_polygon(ip, Color(a.r, a.g, a.b, 0.09))
	ip.append(ip[0])
	draw_polyline(ip, Color(a.r, a.g, a.b, 0.30), 1.0, true)
	# 十字细线（四条射线，越往外越淡）
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		var from: Vector2 = c + d * inner * 1.25
		var to: Vector2 = c + d * outer * 1.42
		draw_line(from, to, faint, 1.0, true)
	# 左右两侧的长横线：把纹章"焊"在带子上
	for sx in [-1.0, 1.0]:
		var x0: float = c.x + sx * outer * 1.9
		var x1: float = c.x + sx * (outer * 1.9 + 150.0)
		draw_line(Vector2(x0, c.y), Vector2(x1, c.y), faint, 1.0, true)


## 上亮下暗的石面：横向 1px 条带，按圆角内缩
func _draw_gradient(r: Rect2, rad: float) -> void:
	var h: int = int(r.size.y)
	if h < 8:
		return
	var bands: int = 28
	var bh: float = r.size.y / float(bands)
	for i in bands:
		var t: float = (float(i) + 0.5) / float(bands)
		var col: Color = STONE_TOP.lerp(STONE_MID, minf(t * 1.7, 1.0)) \
				if t < 0.59 else STONE_MID.lerp(STONE_BOT, (t - 0.59) / 0.41)
		# 顶部 18% 再提一档光（"台面受光"），底部 20% 压暗（"落在战场上的影子"）
		if t < 0.18:
			col = col.lerp(Color(1.0, 0.98, 0.92), (0.18 - t) * 0.55)
		elif t > 0.80:
			col = col.lerp(Color(0.0, 0.0, 0.0), (t - 0.80) * 1.4)
		col.a = 0.985
		var y: float = r.position.y + float(i) * bh
		var inset: float = _corner_inset(y - r.position.y, r.size.y, rad)
		draw_rect(Rect2(r.position.x + inset, y, r.size.x - inset * 2.0, bh + 0.6), col, true)


## 某一高度处（相对顶边）因为圆角要内缩多少
func _corner_inset(y: float, h: float, rad: float) -> float:
	var d: float = minf(y, h - y)
	if d >= rad:
		return 0.0
	var k: float = rad - d
	return rad - sqrt(maxf(rad * rad - k * k, 0.0))


## 石纹：220 个 1~2px 的亮点/暗点（hash 决定位置，和尺寸绑定 → 同一尺寸永远同一张纹理）
func _draw_grain(r: Rect2, rad: float) -> void:
	var n: int = 240
	var area: Rect2 = r.grow(-rad * 0.7)
	for i in n:
		var fx: float = _hash01(i * 7 + 1)
		var fy: float = _hash01(i * 13 + 5)
		var p := Vector2(area.position.x + fx * area.size.x, area.position.y + fy * area.size.y)
		var light: bool = _hash01(i * 31 + 3) > 0.45
		var s: float = 1.0 if _hash01(i * 17 + 9) > 0.35 else 2.0
		var col: Color = Color(1.0, 1.0, 0.96, 0.055) if light \
				else Color(0.0, 0.0, 0.0, 0.11)
		draw_rect(Rect2(p, Vector2(s, s)), col, true)


## 圆角描边（StyleBoxFlat 的 border 只能四边同色、且这里要精确控制内缩）
func _round_stroke(r: Rect2, rad: float, col: Color, w: float) -> void:
	if r.size.x < rad * 2.0 + 2.0 or r.size.y < 4.0:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(int(maxf(rad, 1.0)))
	sb.corner_detail = 12
	sb.border_color = col
	sb.set_border_width_all(int(maxf(w, 1.0)))
	sb.anti_aliasing = true
	draw_style_box(sb, r)


## 四角 L 形角饰：两条 16px 金线 + 一枚铆钉
func _draw_corners(r: Rect2, rad: float, a: Color) -> void:
	var arm: float = 18.0
	var w: float = r.size.x
	var h: float = r.size.y
	if w < arm * 4.0 or h < arm * 2.6:
		return
	var gold := Color(a.r, a.g, a.b, 0.72)
	var soft := Color(1.0, 0.96, 0.88, 0.20)
	for sx in [0.0, 1.0]:
		for sy in [0.0, 1.0]:
			var x: float = rad + 4.0 if sx < 0.5 else w - rad - 4.0
			var y: float = 4.0 if sy < 0.5 else h - 4.0
			var dx: float = 1.0 if sx < 0.5 else -1.0
			var dy: float = 1.0 if sy < 0.5 else -1.0
			draw_line(Vector2(x, y), Vector2(x + dx * arm, y), gold, 1.4, true)
			draw_line(Vector2(x, y), Vector2(x, y + dy * arm * 0.75), gold, 1.4, true)
			draw_line(Vector2(x + dx * 3.0, y + dy * 3.0),
					Vector2(x + dx * (arm - 4.0), y + dy * 3.0), soft, 1.0, true)
			draw_circle(Vector2(x, y), 2.4, gold)
			draw_circle(Vector2(x, y), 1.0, Color(0.08, 0.07, 0.06, 0.95))


## 顶心徽记：一枚菱形 + 两侧渐隐短线（"这是一条有身份的带子"）
func _draw_crest(c: Vector2, a: Color) -> void:
	var r: float = 6.0
	var pts := PackedVector2Array([
		c + Vector2(0.0, -r * 0.9), c + Vector2(r, 0.0),
		c + Vector2(0.0, r * 0.9), c + Vector2(-r, 0.0)])
	draw_colored_polygon(pts, Color(a.r, a.g, a.b, 0.92))
	pts.append(pts[0])
	draw_polyline(pts, Color(1.0, 0.97, 0.90, 0.65), 1.0)
	for i in 3:
		var len_: float = 26.0 - float(i) * 7.0
		var aa: float = 0.34 - float(i) * 0.10
		draw_line(c + Vector2(-r - 3.0 - float(i) * 3.0, 0.0),
				c + Vector2(-r - 3.0 - len_, 0.0), Color(a.r, a.g, a.b, aa), 1.0, true)
		draw_line(c + Vector2(r + 3.0 + float(i) * 3.0, 0.0),
				c + Vector2(r + 3.0 + len_, 0.0), Color(a.r, a.g, a.b, aa), 1.0, true)


## 确定性伪随机 [0,1)
static func _hash01(i: int) -> float:
	var x: int = (i * 1103515245 + 12345) & 0x7FFFFFFF
	x = (x ^ (x >> 13)) * 2654435761
	x = x & 0x7FFFFFFF
	return float(x % 100003) / 100003.0
