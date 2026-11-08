@tool
class_name RtsExpBar
extends Control
## **竖版经验条**（2026-11-08 玩家要求）：
##   「选中单个单位后，在下面左侧的信息面板的左边做竖版的经验条 UI，
##     鼠标悬停会显示当前单位有多少经验值、还需多少经验值升级。」
##
## 为什么单独一个控件：底栏有**两种形态**（紧凑 = 只贴右的铭牌卡；展开 = 最左的头像卡），
## 经验条必须永远贴在"当前那条底栏的左边缘"，所以由 HUD 统一摆放，
## 而不是塞进某一张卡里（塞进去就只在那一种形态下出现）。
##
## 视觉口径对齐 `文档/界面说明.md`：深墨底 + 1px 金边（和头像框/资源条同一套铜牌语言），
## 填充自下而上的金橙渐变 + 顶部亮线；星级用竖排小菱形（和法力行的菱形同形语言）。

var ratio: float = 0.0
var star: int = 0
var accent: Color = Color(0.86, 0.72, 0.40)

## 条宽（像素）。9px：窄到不抢戏，又能看清"涨了没有"
const W: float = 9.0


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
	if w < 3.0 or h < 8.0:
		return
	draw_rect(Rect2(0.0, 0.0, w, h), Color(0.045, 0.050, 0.062, 0.94), true)
	var fill_h: float = ratio * (h - 4.0)
	if fill_h > 0.5:
		var r: Rect2 = Rect2(1.5, h - 2.0 - fill_h, w - 3.0, fill_h)
		draw_rect(r, Color(0.92, 0.66, 0.22, 0.92), true)
		draw_rect(Rect2(r.position.x, r.position.y, r.size.x, 1.5),
				Color(1.0, 0.94, 0.72, 0.95), true)
	draw_rect(Rect2(0.5, 0.5, w - 1.0, h - 1.0),
			Color(accent.r, accent.g, accent.b, 0.60), false, 1.0)
	for i in star:
		var cy: float = -5.0 - float(i) * 8.0
		var pts := PackedVector2Array([
			Vector2(w * 0.5, cy - 3.0), Vector2(w * 0.5 + 3.0, cy),
			Vector2(w * 0.5, cy + 3.0), Vector2(w * 0.5 - 3.0, cy)])
		draw_colored_polygon(pts, Color(1.0, 0.84, 0.34, 0.95))
