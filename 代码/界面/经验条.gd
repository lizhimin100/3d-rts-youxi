@tool
class_name RtsExpBar
extends Control
## **竖版经验条**（2026-11-08 玩家第三轮口径）：
##   「竖版经验条太细了、做宽些，且要有符合当前美术风格的外观，位置不对 ——
##     不要放在信息面板外，是内嵌在信息面板、在显示单位近战或远程的下方，
##     仍然是竖版经验条。」
##
## 所以它是一条 **18px 宽的竖槽**，内嵌在底栏中段那张铭牌卡里，
## 紧贴三行数值的左侧（也就是"名字/定位那行"的正下方）。
##
## 视觉沿用本工程一贯的"铜牌 + 金线"语言（见 `文档/界面.md`）：
##   · 深墨凹槽 + 1px 金边 —— 和资源条、头像框、命令格同一套；
##   · 填充自下而上，暗琥珀 → 亮金渐层，顶端一道亮边（读起来像液面在涨）；
##   · 竖向玻璃高光（左侧 3px 淡白）+ 四分之一刻度，让"涨到哪了"不用数像素；
##   · 槽顶竖排三颗小菱形 = 三档星级：已得到的亮金实心、未得到的暗金空心。
##
## 它**不自带**任何文字/背景板：卡片本身就是它的底，所以只画槽和星。

var ratio: float = 0.0
var star: int = 0
var accent: Color = Color(0.86, 0.72, 0.40)

## 槽宽（像素）。9 → 18：玩家原话「太细了、做宽些」。
## 18 是"能看清渐层、又不会把三行数值挤瘦"的实测值。
const W: float = 18.0
## 星级区高度（槽顶留给三颗竖排菱形）。
## 40 = 三颗之间各留 4px 空隙；27 时三颗会连成一条，读不出"三档"。
const STAR_ZONE: float = 40.0
## 菱形半径
const STAR_R: float = 4.2


func _init() -> void:
	name = "经验条"
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(W, 64.0)


func set_state(p_ratio: float, p_star: int, p_accent: Color) -> void:
	ratio = clampf(p_ratio, 0.0, 1.0)
	star = clampi(p_star, 0, 3)
	accent = p_accent
	queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w < 8.0 or h < 24.0:
		return
	var sz: float = STAR_ZONE if h >= STAR_ZONE + 28.0 else 0.0
	var ty: float = sz
	var th: float = h - sz
	if th < 10.0:
		return

	# --- 槽体：深墨 + 内阴影（左右各 1px），像在卡面上凿出来的一道槽 ---
	draw_rect(Rect2(0.0, ty, w, th), Color(0.026, 0.030, 0.038, 0.97), true)
	draw_rect(Rect2(0.0, ty, 1.0, th), Color(0.0, 0.0, 0.0, 0.55), true)
	draw_rect(Rect2(w - 1.0, ty, 1.0, th), Color(1.0, 0.94, 0.78, 0.07), true)
	draw_rect(Rect2(0.0, ty, w, 1.0), Color(0.0, 0.0, 0.0, 0.62), true)

	# --- 填充：自下而上，12 段渐变（暗琥珀 → 亮金），顶端一道亮边 ---
	var inner_h: float = th - 3.0
	var fill_h: float = clampf(ratio, 0.0, 1.0) * inner_h
	if fill_h > 1.0:
		var bands: int = 12
		var seg: float = fill_h / float(bands)
		for i in bands:
			var t: float = float(i) / float(maxi(bands - 1, 1))
			var c: Color = Color(0.62, 0.34, 0.07, 0.96).lerp(
					Color(1.0, 0.82, 0.34, 0.98), t)
			var y: float = ty + 1.5 + fill_h - seg * float(i + 1)
			draw_rect(Rect2(1.0, y, w - 2.0, seg + 0.6), c, true)
		# 液面亮边（顶端）
		draw_rect(Rect2(1.0, ty + 1.0 + inner_h - fill_h, w - 2.0, 1.6),
				Color(1.0, 0.97, 0.86, 0.92), true)
		# 竖向玻璃高光：只落在已经填满的那段上
		draw_rect(Rect2(2.0, ty + 1.0 + inner_h - fill_h, 3.0, fill_h),
				Color(1.0, 0.96, 0.80, 0.13), true)

	# --- 四分之一刻度：让"涨到哪了"不用数像素（画在填充之上，永远看得见）---
	for i in [1, 2, 3]:
		var yt: float = ty + 1.5 + inner_h * (1.0 - float(i) / 4.0)
		draw_rect(Rect2(1.0, yt, w - 2.0, 1.0), Color(0.0, 0.0, 0.0, 0.30), true)

	# --- 金边：1px，上下两端稍暗（不做整圈高亮，免得抢名字）---
	draw_rect(Rect2(0.5, ty + 0.5, w - 1.0, th - 1.0),
			Color(accent.r, accent.g, accent.b, 0.58), false, 1.0)

	# --- 槽顶三颗竖排菱形（星级）---
	# 顺序和填充方向一致：**一星在最下、三星在最上**（读起来是"往上爬"）。
	if sz >= 12.0:
		for i in 3:
			var cy: float = sz * (1.0 - (float(i) + 0.5) / 3.0)
			var c := Vector2(w * 0.5, cy)
			var pts := PackedVector2Array([
				c + Vector2(0.0, -STAR_R), c + Vector2(STAR_R, 0.0),
				c + Vector2(0.0, STAR_R), c + Vector2(-STAR_R, 0.0)])
			if i < star:
				draw_colored_polygon(pts, Color(1.0, 0.84, 0.34, 0.98))
				draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]),
						Color(1.0, 0.97, 0.86, 0.75), 1.0)
			else:
				draw_colored_polygon(pts, Color(0.24, 0.22, 0.17, 0.90))
				draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]),
						Color(accent.r, accent.g, accent.b, 0.38), 1.0)
