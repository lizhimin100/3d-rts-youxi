extends Control
## **阶段提示（PLANNING ⇄ EXECUTING）** —— 玩家点名要的"杀戮尖塔换手"那种提示。
##
## 口径（2026-11-15）：
##   · 全屏一圈**虚线**（蚂蚁线）短暂出现，中间一条横带写"规划阶段 / 执行阶段"；
##   · **不突兀**：只淡入淡出 + 横带从中间"展开"，没有闪白、没有震屏、不挡操作；
##   · 唯一目的：让玩家知道"世界状态换了"（规划→执行 / 执行→规划）。
##
## 为什么不做成弹窗：RTS 里任何需要点一下才能消失的东西都会打断节奏。
## 这里全程 `MOUSE_FILTER_IGNORE`，玩家可以同时点地图。
##
## 驱动：`Game.phase_changed`。开局若已经在规划阶段，延迟 0.6s 补播一次
##      （让玩家先看清战场，再看到"规划阶段"这四个字）。

const Spec := preload("res://Screens/hud/界面规格.gd")

const FADE_IN := 0.16
const HOLD := 0.80
const FADE_OUT := 0.38
## 蚂蚁线：虚线段长 / 间隔 / 流动速度（像素/秒）
const DASH := 16.0
const GAP := 11.0
const ANT_SPEED := 54.0
## 横带尺寸
const BAND_W := 560.0
const BAND_H := 86.0

var _t: float = -1.0
var _txt: String = ""
var _sub: String = ""
var _accent: Color = Color(1.0, 0.86, 0.44)
var _font: Font = null
## 进执行阶段那一下的"暖光扩散"（= 世界活过来了），0..1，随出场衰减
var _bloom: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "阶段提示"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = Spec.cjk_font()
	visible = false
	if Game != null:
		Game.phase_changed.connect(_on_phase_changed)
		if Game.short_match and Game.is_planning():
			_show_later.call_deferred()


func _show_later() -> void:
	await get_tree().create_timer(0.75).timeout
	if Game != null and Game.is_planning():
		play("规划阶段", _round_text(), Color(0.62, 0.82, 1.0))


func _on_phase_changed(_old: int, new_phase: int) -> void:
	if not Game.short_match:
		return
	match new_phase:
		RtsConst.Phase.PLANNING:
			play("规划阶段", _round_text(), Color(0.62, 0.82, 1.0))
		RtsConst.Phase.RUNNING:
			play("执行阶段", _round_text(), Color(1.0, 0.72, 0.42), true)
		_:
			pass


func play(text: String, sub: String, accent: Color, bloom: bool = false) -> void:
	_txt = text
	_sub = sub
	_accent = accent
	_t = 0.0
	_bloom = 1.0 if bloom else 0.0
	visible = true
	queue_redraw()



func _round_text() -> String:
	var rc: Node = Game.round_control
	if rc != null and rc.has_method("round_index_text"):
		return String(rc.call("round_index_text"))
	if rc != null:
		var r: int = int(rc.get("round_index"))
		var n: int = int(rc.call("rounds")) if rc.has_method("rounds") else 3
		return "第 %d / %d 回合" % [clampi(r + 1, 1, n), n]
	return ""


func _total() -> float:
	return FADE_IN + HOLD + FADE_OUT


func _process(delta: float) -> void:
	# ★ 尺寸自己同步（不要赌 full-rect 锚点）：本工程的 HUD root 是用 offset 撑开的，
	#   挂在它下面的控件实测拿不到父尺寸（size 一直 (0,0)，横幅就画不出来）。
	var host := get_parent() as Control
	if host != null and (absf(size.x - host.size.x) > 0.5 or absf(size.y - host.size.y) > 0.5):
		size = host.size
		position = Vector2.ZERO
	if _t < 0.0:
		return
	_t += delta
	_bloom = maxf(_bloom - delta / 0.75, 0.0)
	if _t >= _total():
		_t = -1.0
		visible = false
		return
	queue_redraw()


## 0..1 的"出场包络"：淡入 → 保持 → 淡出
func _alpha() -> float:
	if _t < FADE_IN:
		return clampf(_t / FADE_IN, 0.0, 1.0)
	if _t < FADE_IN + HOLD:
		return 1.0
	return clampf(1.0 - (_t - FADE_IN - HOLD) / FADE_OUT, 0.0, 1.0)


## 横带宽度系数：0.35 → 1（带一点回弹的缓出），读作"唰地展开"
func _reveal() -> float:
	var k: float = clampf(_t / FADE_IN, 0.0, 1.0)
	var e: float = 1.0 - pow(1.0 - k, 3.0)
	return 0.35 + 0.65 * e


func _draw() -> void:
	var a: float = _alpha()
	if a <= 0.001:
		return

	var w: float = size.x
	var h: float = size.y
	if w < 40.0 or h < 40.0:
		return

	# --- ① 全屏一圈蚂蚁线（内缩 10px）：只做出场那一下，退场时一起淡掉 ---
	var inset: float = 10.0
	var ring := Rect2(inset, inset, w - inset * 2.0, h - inset * 2.0)
	var ant_a: float = a * 0.55
	var offset: float = _t * ANT_SPEED
	_dash_line(Vector2(ring.position.x, ring.position.y),
			Vector2(ring.end.x, ring.position.y), offset)
	_dash_line(Vector2(ring.end.x, ring.position.y),
			Vector2(ring.end.x, ring.end.y), offset)
	_dash_line(Vector2(ring.end.x, ring.end.y),
			Vector2(ring.position.x, ring.end.y), offset)
	_dash_line(Vector2(ring.position.x, ring.end.y),
			Vector2(ring.position.x, ring.position.y), offset)

	# --- ② 中央横带 ---
	var bw: float = BAND_W * _reveal()
	var band := Rect2((w - bw) * 0.5, (h - BAND_H) * 0.5, bw, BAND_H)
	# 暖光扩散（只在"进入执行"那一下）：三层同心光晕由小到大铺开，
	# 读作"战场被点亮 / 世界解冻"，比闪白温和得多。
	if _bloom > 0.01:
		var prog: float = 1.0 - _bloom
		var rr: float = lerpf(0.16, 0.95, 1.0 - pow(1.0 - prog, 2.0)) * minf(w, h)
		for i in 3:
			var rad: float = rr * (1.0 - float(i) * 0.22)
			draw_circle(Vector2(w * 0.5, h * 0.5), rad,
					Color(_accent.r, _accent.g, _accent.b, 0.030 * _bloom))
	# 背后一层很淡的同色光晕：让横带"浮"在战场上，而不是贴一张黑纸
	draw_rect(Rect2(band.position - Vector2(0.0, 18.0), band.size + Vector2(0.0, 36.0)),
			Color(_accent.r, _accent.g, _accent.b, 0.055 * a), true)
	draw_rect(band, Color(0.030, 0.036, 0.048, 0.88 * a), true)
	# 上下两条主线 + 中间一道很细的内线（"刻度"读感）
	draw_line(Vector2(band.position.x, band.position.y),
			Vector2(band.end.x, band.position.y), Color(_accent, 0.90 * a), 2.0, true)
	draw_line(Vector2(band.position.x, band.end.y),
			Vector2(band.end.x, band.end.y), Color(_accent, 0.90 * a), 2.0, true)
	draw_line(Vector2(band.position.x + 18.0, band.position.y + 5.0),
			Vector2(band.end.x - 18.0, band.position.y + 5.0),
			Color(_accent, 0.22 * a), 1.0, true)
	draw_line(Vector2(band.position.x + 18.0, band.end.y - 5.0),
			Vector2(band.end.x - 18.0, band.end.y - 5.0),
			Color(_accent, 0.22 * a), 1.0, true)
	# 四角小括号（横带两端）
	_bracket(Vector2(band.position.x, band.position.y), 1.0, 1.0, a)
	_bracket(Vector2(band.end.x, band.position.y), -1.0, 1.0, a)
	_bracket(Vector2(band.position.x, band.end.y), 1.0, -1.0, a)
	_bracket(Vector2(band.end.x, band.end.y), -1.0, -1.0, a)

	# --- ③ 文字：主标题 + 一行小字（回合数），别的什么都不写 ---
	var fs_main: int = Spec.FS_HERO
	var main_y: float = band.position.y + BAND_H * 0.5 + 2.0
	if not _sub.is_empty():
		main_y -= 9.0
	var tw: float = _font.get_string_size(_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_main).x
	# 描边 + 本体：战场上底色复杂，没有描边会糊
	draw_string_outline(_font, Vector2((w - tw) * 0.5, main_y), _txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs_main, 4, Color(0.0, 0.0, 0.0, 0.62 * a))
	draw_string(_font, Vector2((w - tw) * 0.5, main_y), _txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs_main, Color(1.0, 0.98, 0.92, a))
	if not _sub.is_empty():
		var fs_sub: int = Spec.FS_CAPTION
		var sw: float = _font.get_string_size(_sub, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_sub).x
		draw_string(_font, Vector2((w - sw) * 0.5, main_y + 22.0), _sub,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs_sub, Color(_accent, 0.92 * a))


func _bracket(p: Vector2, sx: float, sy: float, a: float) -> void:
	var L: float = 12.0
	draw_line(p, p + Vector2(L * sx, 0.0), Color(_accent, 0.95 * a), 2.0, true)
	draw_line(p, p + Vector2(0.0, L * sy), Color(_accent, 0.95 * a), 2.0, true)


## 一条水平/垂直的蚂蚁线（offset 一直往前推 = 虚线在流动）
func _dash_line(a: Vector2, b: Vector2, offset: float) -> void:
	var d: Vector2 = b - a
	var total: float = d.length()
	if total < 1.0:
		return
	var dir: Vector2 = d / total
	var al: float = _alpha() * 0.60
	var t: float = -fmod(offset, DASH + GAP)
	while t < total:
		var t0: float = maxf(t, 0.0)
		var t1: float = minf(t + DASH, total)
		if t1 > t0:
			draw_line(a + dir * t0, a + dir * t1, Color(_accent, al), 1.6, true)
		t += DASH + GAP
