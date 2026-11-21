extends RefCounted
## **徽记（emblem）** —— 规划阶段所有"命令 / 势力"图标的唯一画法。
##
## 为什么不用现成的线描 SVG：`Content/art/图标/*.svg` 是 24px 的**编辑器工具图标**
## （细线、无底、无体积），放大到 32~48px 放进深色按钮里就只剩几根发虚的线 ——
## 玩家原话「图标也很一般，没有切合当前游戏美术风格」。
## 这里改成**铁誓那套"暗铁底 + 暖金线 + 冷光边"的徽记**：一块带压边的暗底，
## 上面一枚粗笔画图形，边缘一圈自发光。远看是"一枚章"，近看才认出是刀/盾/旗。
##
## 用法（Control 的 _draw 里直接画，不建子节点）：
##   const 徽记 := preload("res://Screens/hud/徽记.gd")
##   徽记.draw_icon(self, "attack", rect, Color(1,0.62,0.34), 1.0)
##
## 形状表：attack / defend / capture / play / undo / scroll / flag
## 所有函数都是静态的，不持有状态。

## 暗铁底（比面板更暗一档，让徽记"嵌"进去）
const PLATE_BG := Color(0.052, 0.060, 0.074)
## 压边高光
const PLATE_EDGE := Color(1.0, 0.96, 0.86, 0.14)
## 金色（命令类徽记的默认色）
const GOLD := Color(1.0, 0.83, 0.45)


# ===========================================================================
# 对外
# ===========================================================================

## 画一枚带底的徽记（按钮/卡片里用）
static func draw_icon(ci: CanvasItem, kind: String, box: Rect2, col: Color,
		alpha: float = 1.0) -> void:
	if ci == null or box.size.x < 4.0 or box.size.y < 4.0:
		return
	draw_plate(ci, box, col, alpha)
	var pad: float = minf(box.size.x, box.size.y) * 0.20
	var inner := Rect2(box.position + Vector2(pad, pad), box.size - Vector2(pad, pad) * 2.0)
	draw_glyph(ci, kind, inner, col, alpha)


## 画一枚"无底"的徽记（叠在别的底上：地图牌、旗帜）
static func draw_glyph(ci: CanvasItem, kind: String, box: Rect2, col: Color,
		alpha: float = 1.0) -> void:
	if ci == null or box.size.x < 3.0 or box.size.y < 3.0:
		return
	var c := box.get_center()
	var s: float = minf(box.size.x, box.size.y)
	var a: float = clampf(alpha, 0.0, 1.0)
	match kind:
		"attack":
			_attack(ci, c, s, col, a)
		"defend":
			_defend(ci, c, s, col, a)
		"capture":
			_capture(ci, c, s, col, a)
		"play":
			_play(ci, c, s, col, a)
		"undo":
			_undo(ci, c, s, col, a)
		"scroll":
			_scroll(ci, c, s, col, a)
		"build":
			_build(ci, c, s, col, a)
		"coin":
			_coin(ci, c, s, col, a)
		"pop":
			_pop(ci, c, s, col, a)
		_:
			_dot(ci, c, s, col, a)


## 暗铁底 + 压边 + 一圈微光（所有图标共用的"铁牌"）
static func draw_plate(ci: CanvasItem, box: Rect2, col: Color, alpha: float = 1.0,
		radius: int = 7) -> void:
	if ci == null:
		return
	var a: float = clampf(alpha, 0.0, 1.0)
	# 外发光：先铺一圈很淡的同色底，读作"徽记在发光"而不是"贴纸"
	var glow := StyleBoxFlat.new()
	glow.bg_color = Color(col.r, col.g, col.b, 0.10 * a)
	glow.set_corner_radius_all(radius + 4)
	glow.corner_detail = 8
	ci.draw_style_box(glow, Rect2(box.position - Vector2(4.0, 4.0), box.size + Vector2(8.0, 8.0)))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(PLATE_BG.r, PLATE_BG.g, PLATE_BG.b, 0.94 * a)
	sb.border_color = Color(col.r * 0.55 + 0.30, col.g * 0.55 + 0.30, col.b * 0.55 + 0.30,
			0.70 * a)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 8
	ci.draw_style_box(sb, box)
	# 上沿一道高光（伪造金属压边；和下沿的深色形成"嵌进去"的读感）
	ci.draw_line(Vector2(box.position.x + radius * 0.7, box.position.y + 0.5),
			Vector2(box.end.x - radius * 0.7, box.position.y + 0.5),
			Color(PLATE_EDGE, PLATE_EDGE.a * a), 1.0, true)


# ===========================================================================
# 图形（全部按"中心 + 直径"归一化，和实际像素尺寸无关）
# ===========================================================================

## 交叉双刀：两把斜置的刀身 + 护手 + 一点火星
static func _attack(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var h: float = s * 0.38
	# 背后一团暖光（读作"进攻"的热度）
	ci.draw_circle(c, s * 0.42, Color(col.r, col.g, col.b, 0.10 * a))
	for sgn in [-1.0, 1.0]:
		var p0: Vector2 = c + Vector2(h * float(sgn), h)
		var p1: Vector2 = c - Vector2(h * float(sgn), h)
		# 刀身：粗一笔（暗）+ 细一笔（亮）= 有厚度的刃
		ci.draw_line(p0, p1, Color(col.r * 0.55, col.g * 0.55, col.b * 0.55, 0.95 * a),
				maxf(s * 0.085, 2.2), true)
		ci.draw_line(p0, p1, Color(col.r, col.g, col.b, 0.98 * a),
				maxf(s * 0.050, 1.4), true)
		ci.draw_line(p0, p1, Color(1.0, 1.0, 0.96, 0.55 * a), 1.0, true)
		# 护手：靠近握把处一小段横条
		var d: Vector2 = (p1 - p0).normalized()
		var nrm := Vector2(-d.y, d.x)
		var g0: Vector2 = p0 + d * s * 0.16
		ci.draw_line(g0 - nrm * s * 0.13, g0 + nrm * s * 0.13,
				Color(1.0, 0.94, 0.80, 0.92 * a), maxf(s * 0.045, 1.6), true)
	# 中心交叉处一点火星
	ci.draw_circle(c, s * 0.10, Color(col.r, col.g, col.b, 0.34 * a))
	ci.draw_circle(c, s * 0.048, Color(1.0, 0.97, 0.88, 0.96 * a))


## 塔盾：上宽下尖的盾面 + 中脊 + 双人字纹
static func _defend(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var w: float = s * 0.36
	var top: float = c.y - s * 0.44
	var bot: float = c.y + s * 0.46
	var shield := PackedVector2Array([
		Vector2(c.x - w, top),
		Vector2(c.x + w, top),
		Vector2(c.x + w, c.y + s * 0.06),
		Vector2(c.x, bot),
		Vector2(c.x - w, c.y + s * 0.06),
	])
	ci.draw_colored_polygon(shield, Color(col.r, col.g, col.b, 0.90 * a))
	# 盾面里侧暗一档（做出厚度）
	var inner := PackedVector2Array()
	for p in shield:
		inner.append((p - c) * 0.80 + c)
	ci.draw_colored_polygon(inner, Color(0.045, 0.055, 0.070, 0.92 * a))
	# 中脊
	ci.draw_line(Vector2(c.x, top + s * 0.06), Vector2(c.x, bot - s * 0.10),
			Color(1.0, 0.96, 0.88, 0.75 * a), 1.6, true)
	# 双人字
	for i in 2:
		var y: float = c.y - s * 0.12 + float(i) * s * 0.14
		ci.draw_polyline(PackedVector2Array([
			Vector2(c.x - w * 0.56, y),
			Vector2(c.x, y - s * 0.10),
			Vector2(c.x + w * 0.56, y),
		]), Color(1.0, 0.96, 0.88, 0.70 * a), 1.8, true)


## 军旗：旗杆 + 三角旗面 + 底座
static func _capture(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var px: float = c.x - s * 0.22
	var top: float = c.y - s * 0.46
	var bot: float = c.y + s * 0.42
	# 旗杆
	ci.draw_line(Vector2(px, top), Vector2(px, bot), Color(1.0, 0.95, 0.84, 0.92 * a),
			2.2, true)
	# 旗面（指向右的三角旗）
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px, top),
		Vector2(px + s * 0.52, top + s * 0.15),
		Vector2(px, top + s * 0.30),
	]), Color(col.r, col.g, col.b, 0.95 * a))
	# 旗面上叠一道暗纹
	ci.draw_line(Vector2(px + s * 0.06, top + s * 0.14),
			Vector2(px + s * 0.34, top + s * 0.16),
			Color(0.05, 0.06, 0.08, 0.45 * a), 1.4, true)
	# 底座
	ci.draw_line(Vector2(px - s * 0.16, bot), Vector2(px + s * 0.16, bot),
			Color(col.r, col.g, col.b, 0.95 * a), 2.6, true)


## 开始（▶ + 环）
static func _play(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	ci.draw_arc(c, s * 0.40, 0.0, TAU, 32, Color(col.r, col.g, col.b, 0.55 * a),
			1.6, true)
	ci.draw_colored_polygon(PackedVector2Array([
		c + Vector2(-s * 0.13, -s * 0.20),
		c + Vector2(s * 0.22, 0.0),
		c + Vector2(-s * 0.13, s * 0.20),
	]), Color(col.r, col.g, col.b, 0.96 * a))


## 撤销（回转箭头）
static func _undo(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var r: float = s * 0.30
	ci.draw_arc(c, r, -PI * 0.55, PI * 1.15, 28, Color(col.r, col.g, col.b, 0.92 * a),
			2.2, true)
	var tip: Vector2 = c + Vector2(cos(-PI * 0.55), sin(-PI * 0.55)) * r
	var ang: float = -PI * 0.55
	var dir := Vector2(cos(ang), sin(ang))
	var nrm := Vector2(-dir.y, dir.x)
	ci.draw_colored_polygon(PackedVector2Array([
		tip + dir * s * 0.13,
		tip + nrm * s * 0.10 - dir * s * 0.02,
		tip - nrm * s * 0.10 - dir * s * 0.02,
	]), Color(col.r, col.g, col.b, 0.96 * a))


## 卷轴（法术槽 / 待放）
static func _scroll(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var w: float = s * 0.30
	var h: float = s * 0.34
	ci.draw_rect(Rect2(c.x - w, c.y - h, w * 2.0, h * 2.0),
			Color(col.r, col.g, col.b, 0.72 * a), true)
	ci.draw_rect(Rect2(c.x - w, c.y - h, w * 2.0, h * 2.0),
			Color(1.0, 0.96, 0.86, 0.55 * a), false, 1.2)
	# 两端卷起的轴
	ci.draw_circle(Vector2(c.x - w, c.y - h), w * 0.42, Color(1.0, 0.95, 0.84, 0.85 * a))
	ci.draw_circle(Vector2(c.x - w, c.y + h), w * 0.42, Color(1.0, 0.95, 0.84, 0.85 * a))
	# 三条字迹
	for i in 3:
		var y: float = c.y - h * 0.45 + float(i) * h * 0.45
		ci.draw_line(Vector2(c.x - w * 0.45, y), Vector2(c.x + w * 0.55, y),
				Color(0.08, 0.09, 0.11, 0.55 * a), 1.2, true)


## 建造（锤 + 方料）
static func _build(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var hd := Vector2(0.72, -0.70).normalized()
	var handle_a: Vector2 = c + Vector2(-s * 0.24, s * 0.26)
	var handle_b: Vector2 = c + Vector2(s * 0.18, -s * 0.18)
	ci.draw_line(handle_a, handle_b, Color(0.70, 0.55, 0.34, 0.95 * a), 3.0, true)
	var head_c: Vector2 = handle_b + hd * s * 0.05
	var hn := Vector2(-hd.y, hd.x)
	ci.draw_colored_polygon(PackedVector2Array([
		head_c + hn * s * 0.20 + hd * s * 0.06,
		head_c + hn * s * 0.20 - hd * s * 0.06,
		head_c - hn * s * 0.20 - hd * s * 0.06,
		head_c - hn * s * 0.20 + hd * s * 0.06,
	]), Color(col.r, col.g, col.b, 0.95 * a))


static func _dot(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	ci.draw_circle(c, s * 0.22, Color(col.r, col.g, col.b, 0.90 * a))


## 金币：外环 + 内盘 + 中间的菱形压印（和资源栏的"钱"读法一致）
static func _coin(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var r: float = s * 0.38
	ci.draw_circle(c, r, Color(col.r * 0.55, col.g * 0.46, col.b * 0.20, 0.95 * a))
	ci.draw_arc(c, r, 0.0, TAU, 28, Color(col.r, col.g, col.b, 0.98 * a),
			maxf(s * 0.075, 1.4), true)
	ci.draw_arc(c, r * 0.72, 0.0, TAU, 24, Color(1.0, 0.96, 0.84, 0.42 * a), 1.0, true)
	var d: float = r * 0.34
	ci.draw_colored_polygon(PackedVector2Array([
		c + Vector2(0.0, -d), c + Vector2(d * 0.62, 0.0),
		c + Vector2(0.0, d), c + Vector2(-d * 0.62, 0.0),
	]), Color(1.0, 0.94, 0.66, 0.92 * a))


## 人口：一个"人头 + 肩"的剪影（比抽象符号好认）
static func _pop(ci: CanvasItem, c: Vector2, s: float, col: Color, a: float) -> void:
	var head := Vector2(c.x, c.y - s * 0.16)
	ci.draw_circle(head, s * 0.15, Color(col.r, col.g, col.b, 0.95 * a))
	# 肩：半圆鼓包
	var rr: float = s * 0.28
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(c.x - rr, c.y + s * 0.34),
		Vector2(c.x - rr, c.y + s * 0.10),
		Vector2(c.x - rr * 0.55, c.y - s * 0.02),
		Vector2(c.x + rr * 0.55, c.y - s * 0.02),
		Vector2(c.x + rr, c.y + s * 0.10),
		Vector2(c.x + rr, c.y + s * 0.34),
	]), Color(col.r, col.g, col.b, 0.80 * a))
