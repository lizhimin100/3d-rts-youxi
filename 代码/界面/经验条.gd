@tool
class_name RtsExpBar
extends Control
## **竖版经验条**（2026-11-08 玩家第四轮口径，定稿）：
##   「将单位的经验进度条从当前位置移到信息面板的右侧。去除现有进度条上与单位名称旁
##     装饰混淆的款式，换成干净清晰的独立进度条。」
##   「将单位的星级从单位名称旁边/上方移除，改到单位下方显示。」
##
## 所以这一版改了两件事：
##   ① **位置**：从"三行数值的左侧"挪到**信息面板的右侧**（由 `选择网格.gd` 挂在
##      `HBoxContainer` 的末尾，不是这里的坐标逻辑）；
##   ② **去掉槽顶那三颗竖排菱形**：它们正好落在铭牌行下面，读起来像"名字旁的装饰"，
##      和真正的星级（现在画在世界里的单位脚下，见 `头顶界面._draw_stars_at_feet`）撞车。
##
## 现在它只是一条**干净的进度槽**：
##   · 深墨凹槽 + 1px 金边（和资源条/头像框同一套铜牌语言）；
##   · 填充自下而上，暗琥珀 → 亮金 12 段渐层，顶端一道亮边（像液面在涨）；
##   · 左缘 3px 竖向玻璃高光 + 四分之一刻度（不用数像素就知道涨到哪了）。
##
## 星级**不在这里画**：`star` 仍然接收（词条/未来样式可能要用），但不参与绘制。

var ratio: float = 0.0
## 星级只作为数据保留（不在条上画；世界里的星级见 头顶界面）
var star: int = 0
var accent: Color = Color(0.86, 0.72, 0.40)

## 槽宽（像素）。9 → 18：玩家原话「太细了、做宽些」。
## 18 是"能看清渐层、又不会把右侧留白挤没"的实测值。
const W: float = 18.0


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

	# --- 槽体：深墨 + 内阴影（左右各 1px），像在卡面上凿出来的一道槽 ---
	draw_rect(Rect2(0.0, 0.0, w, h), Color(0.026, 0.030, 0.038, 0.97), true)
	draw_rect(Rect2(0.0, 0.0, 1.0, h), Color(0.0, 0.0, 0.0, 0.55), true)
	draw_rect(Rect2(w - 1.0, 0.0, 1.0, h), Color(1.0, 0.94, 0.78, 0.07), true)
	draw_rect(Rect2(0.0, 0.0, w, 1.0), Color(0.0, 0.0, 0.0, 0.62), true)

	# --- 填充：自下而上，12 段渐变（暗琥珀 → 亮金），顶端一道亮边 ---
	var inner_h: float = h - 3.0
	var fill_h: float = clampf(ratio, 0.0, 1.0) * inner_h
	if fill_h > 1.0:
		var bands: int = 12
		var seg: float = fill_h / float(bands)
		for i in bands:
			var t: float = float(i) / float(maxi(bands - 1, 1))
			var c: Color = Color(0.62, 0.34, 0.07, 0.96).lerp(
					Color(1.0, 0.82, 0.34, 0.98), t)
			var y: float = 1.5 + fill_h - seg * float(i + 1)
			draw_rect(Rect2(1.0, y, w - 2.0, seg + 0.6), c, true)
		# 液面亮边（顶端）
		draw_rect(Rect2(1.0, 1.0 + inner_h - fill_h, w - 2.0, 1.6),
				Color(1.0, 0.97, 0.86, 0.92), true)
		# 竖向玻璃高光：只落在已经填满的那段上
		draw_rect(Rect2(2.0, 1.0 + inner_h - fill_h, 3.0, fill_h),
				Color(1.0, 0.96, 0.80, 0.13), true)

	# --- 四分之一刻度：让"涨到哪了"不用数像素（画在填充之上，永远看得见）---
	for i in [1, 2, 3]:
		var yt: float = 1.5 + inner_h * (1.0 - float(i) / 4.0)
		draw_rect(Rect2(1.0, yt, w - 2.0, 1.0), Color(0.0, 0.0, 0.0, 0.30), true)

	# --- 金边：1px，上下两端稍暗（不做整圈高亮，免得抢名字）---
	draw_rect(Rect2(0.5, 0.5, w - 1.0, h - 1.0),
			Color(accent.r, accent.g, accent.b, 0.58), false, 1.0)
