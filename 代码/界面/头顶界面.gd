class_name RtsOverheadUi
extends Control
## **头顶界面**：世界里的单位头顶那一层（不在底栏里）。
##
## 玩家要求的两件事：
##   ① **选中单位头顶要有一条血条**（有法力的再加一条蓝条）；
##   ② **处于驻守 / 观察 / 路径的单位头顶要有状态图标**。
##
## 实现口径：
##   · 不建任何子节点 —— 全部在 _draw() 里画。单位上千个，一单位一个 Node 会拖垮 UI；
##   · 世界点 → 屏幕点走 Camera3D.unproject_position，和 3D 视口同一套投影；
##   · 这个控件挂在 HUD 的 CanvasLayer 下、且排在 HUD 面板之前，
##     所以它画在 3D 之上、HUD 面板之下（不会盖住底栏和小地图）；
##   · 尺寸不跟 zoom 缩放（它要对齐屏幕像素），但笔画宽度乘 zoom 保持物理大小一致。

## HUD 的反拉伸系数（1.0 = 设计像素）
var zoom: float = 1.0

## 缓存刷新间隔：别在 _draw 里遍历世界
const REFRESH: float = 0.1
## 超过这个距离就不画（远处一堆血条会糊成马路）
const MAX_DIST: float = 110.0
## 最多画多少条血条（防守时几十个建筑同时选中）
const MAX_BARS: int = 64
## 最多画多少个状态图标
const MAX_ICONS: int = 96
## 最多画多少个"工地倒计时"（玩家 2026-11-07：世界里的工地头顶要有秒数）
const MAX_SITES: int = 24
## 最多画多少个"星级"（老兵/精英/王牌）。和血条一样是屏幕像素尺寸，拉远也认得出
const MAX_STARS: int = 96
## 星级图标直径（屏幕像素，**所有单位统一**、不随镜头缩放）
const STAR_PX: float = 13.0
## 星级图标底色（暖金）+ 描边
const COL_STAR := Color(1.0, 0.82, 0.28)
const COL_STAR_EDGE := Color(0.28, 0.19, 0.05, 0.92)
## 工地倒计时的刷新间隔（秒）：秒数只到整秒，0.25s 足够，别每帧扫阵营
const SITE_REFRESH: float = 0.25

var _t: float = 0.0
var _sel: Array = []
var _guards: Array = []
var _sites: Array = []
## 有星级的单位（含敌方：野怪/敌兵升星也是情报）
var _stars: Array = []
var _site_t: float = 0.0

const COL_HOLD := Color(0.55, 0.76, 1.0)
const COL_OBSERVE := Color(0.42, 0.92, 0.86)
const COL_PATROL := Color(1.0, 0.80, 0.34)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## HUD 每次刷新选择时灌进来（节点引用，不复制）
func set_selection(units: Array) -> void:
	_sel = units


func _process(delta: float) -> void:
	_t -= delta
	_site_t -= delta
	if _site_t <= 0.0:
		_site_t = SITE_REFRESH
		_scan_sites()
	if _t > 0.0:
		queue_redraw()
		return
	_t = REFRESH
	_scan_guards()
	_scan_stars()
	queue_redraw()


## 扫一遍"自己/盟友的未完工工地"——世界头顶要显示还剩多少秒。
##
## 玩家 2026-11-07 手绘图：「这个是农民正在建造的建筑工地，上面有显示多少多少秒」。
## 只扫己方（含盟友）：敌方工地的进度属于侦察信息，不该白送。
func _scan_sites() -> void:
	_sites.clear()
	if Game.player_faction == null:
		return
	for f in Game.factions:
		if f == null or not Game.is_ally_of_player(f):
			continue
		for b in f.buildings:
			if b == null or not is_instance_valid(b):
				continue
			if bool(b.get("is_constructed")):
				continue
			_sites.append(b)
			if _sites.size() >= MAX_SITES:
				return


## 扫一遍"有警戒姿态的己方/友军单位"（敌人不画：玩家管不着，只会挡视线）
func _scan_guards() -> void:
	_guards.clear()
	if Game.player_faction == null:
		return
	# ★ 只遍历自己 + 盟友的阵营表，不再对全图单位做一次 O(n) 扫描
	#   （3000 兵压测时这一步是 10 次/秒 × 全表）
	for f in Game.factions:
		if f == null or not Game.is_ally_of_player(f):
			continue
		for u in f.units:
			if u == null or not is_instance_valid(u):
				continue
			if not u.has_method("is_alive") or not bool(u.call("is_alive")):
				continue
			var g: Variant = u.get("guard_mode")
			if g == null or int(g) == 0:
				continue
			_guards.append(u)
			if _guards.size() >= MAX_ICONS:
				return


## 扫一遍"身上有星级的单位"。
##
## 口径（玩家 2026-11-08「单位身上显示星级图标，仿红警」）：
##   · 0 星不显示；1/2/3 星显示对应颗数；
##   · 图标**屏幕像素固定大小**（镜头拉远也认得出），位置/朝向对所有单位一致；
##   · 只收集 `visible` 的节点 —— 迷雾里被隐藏的敌人不会白送星级情报。
func _scan_stars() -> void:
	_stars.clear()
	for f in Game.factions:
		if f == null:
			continue
		for u in f.units:
			if u == null or not is_instance_valid(u):
				continue
			if not (u is Node3D) or not (u as Node3D).visible:
				continue
			if not u.has_method("is_alive") or not bool(u.call("is_alive")):
				continue
			var st: Variant = u.get("star_level")
			if st == null or int(st) <= 0:
				continue
			_stars.append(u)
			if _stars.size() >= MAX_STARS:
				return


func _draw() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var cam_pos: Vector3 = cam.global_position

	# --- ⓪ 在建工地：头顶那行"还剩多少秒"（玩家手绘图的要求）---
	for b in _sites:
		if b == null or not is_instance_valid(b):
			continue
		if bool(b.get("is_constructed")):
			continue
		var bp: Vector3 = _site_anchor(b)
		if cam_pos.distance_to(bp) > MAX_DIST:
			continue
		if cam.is_position_behind(bp):
			continue
		var bsp: Vector2 = cam.unproject_position(bp)
		if bsp.x < -80.0 or bsp.y < -80.0 or bsp.x > vp.x + 80.0 or bsp.y > vp.y + 80.0:
			continue
		_draw_site_timer(b, bsp)

	# --- ① 选中单位的血条 / 蓝条 ---
	var drawn: int = 0
	for u in _sel:
		if drawn >= MAX_BARS:
			break
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_method("is_alive") or not bool(u.call("is_alive")):
			continue
		var p: Vector3 = _anchor_of(u)
		if cam_pos.distance_to(p) > MAX_DIST:
			continue
		if cam.is_position_behind(p):
			continue
		var sp: Vector2 = cam.unproject_position(p)
		if sp.x < -60.0 or sp.y < -60.0 or sp.x > vp.x + 60.0 or sp.y > vp.y + 60.0:
			continue
		_draw_bars(u, sp)
		drawn += 1

	# --- ② 驻守 / 观察 / 路径 的头顶图标 ---
	var icons: int = 0
	for u2 in _guards:
		if icons >= MAX_ICONS:
			break
		if u2 == null or not is_instance_valid(u2):
			continue
		var p2: Vector3 = _anchor_of(u2)
		if cam_pos.distance_to(p2) > MAX_DIST:
			continue
		if cam.is_position_behind(p2):
			continue
		var sp2: Vector2 = cam.unproject_position(p2)
		if sp2.x < -40.0 or sp2.y < -40.0 or sp2.x > vp.x + 40.0 or sp2.y > vp.y + 40.0:
			continue
		_draw_guard(u2, sp2 + Vector2(0.0, -16.0 * zoom))
		icons += 1

	# --- ③ 星级图标（老兵 / 精英 / 王牌）---
	var drawn_star: int = 0
	for u3 in _stars:
		if drawn_star >= MAX_STARS:
			break
		if u3 == null or not is_instance_valid(u3):
			continue
		if not (u3 as Node3D).visible:
			continue
		var p3: Vector3 = _anchor_of(u3)
		if cam_pos.distance_to(p3) > MAX_DIST:
			continue
		if cam.is_position_behind(p3):
			continue
		var sp3: Vector2 = cam.unproject_position(p3)
		if sp3.x < -40.0 or sp3.y < -40.0 or sp3.x > vp.x + 40.0 or sp3.y > vp.y + 40.0:
			continue
		_draw_stars(int(u3.get("star_level")), sp3 + Vector2(0.0, 9.0 * zoom))
		drawn_star += 1


## 在建工地头顶的「剩余 N 秒」小牌。
##
## 版式口径：**秒数压在进度条上**是底栏的写法；世界里的工地没有底栏，
## 所以做成一块小铭牌（深底 + 金边 + 底部一条真实进度线），
## 字够大、读得清，但不会盖住建筑本身（贴在头顶锚点上方）。
func _draw_site_timer(b: Node3D, sp: Vector2) -> void:
	var d: UnitDef = b.def
	var total: float = maxf(d.train_time, 0.5) if d != null else 1.0
	var p: float = clampf(float(b.get("progress")), 0.0, 1.0)
	var rest: int = int(ceil(maxf(1.0 - p, 0.0) * total))
	var txt: String = "%d秒" % rest
	var fs: int = maxi(int(round(17.0 * zoom)), 10)
	var font: Font = ThemeDB.fallback_font
	var ts: Vector2 = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pad_x: float = 7.0 * zoom
	var pad_y: float = 3.0 * zoom
	var w: float = ts.x + pad_x * 2.0
	var h: float = ts.y + pad_y * 2.0
	var box := Rect2(sp.x - w * 0.5, sp.y - h, w, h)
	# 外投影（贴在亮天空上也能读）
	draw_rect(Rect2(box.position - Vector2(1.0, 1.5) * zoom,
		box.size + Vector2(2.0, 3.0) * zoom), Color(0.0, 0.0, 0.0, 0.45), true)
	draw_rect(box, Color(0.052, 0.048, 0.040, 0.90), true)
	draw_rect(box, Color(1.0, 0.82, 0.44, 0.62), false, 1.0 * zoom)
	# 底部真实进度线：一眼看出"还剩多少"，不用读数字
	if p > 0.001:
		draw_rect(Rect2(box.position.x, box.end.y - 2.0 * zoom, box.size.x * p, 2.0 * zoom),
			Color(0.96, 0.72, 0.30, 0.95), true)
	var base := Vector2(box.position.x + pad_x, box.position.y + pad_y + ts.y * 0.82)
	draw_string(font, base, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.94, 0.76))


## 工地锚点：按**完工高度**再抬高一点，让秒数牌浮在楼顶上方而不是压在屋顶上
## （工地是"从下往上长"的，用当前模型包围盒会一路往下跳）。
func _site_anchor(b: Node3D) -> Vector3:
	var h: float = 4.0
	if b.def != null:
		h = maxf(b.def.height, 1.0)
	return b.global_position + Vector3(0.0, h * 1.02 + 0.85, 0.0)


## 头顶锚点：单位高度之上再留一点（血条不压脸）
func _anchor_of(u: Node3D) -> Vector3:
	var h: float = 1.8
	if u.def != null:
		h = u.def.height
		if u.def.is_building():
			h *= 0.92
	return u.global_position + Vector3(0.0, h + 0.45, 0.0)


## **星级图标**（仿红警）：一排 n 颗金星，中心在 center。
##
## 三条硬口径（玩家 2026-11-08）：
##   ① 0 星不画；② 大小/间距/朝向**对所有单位统一**（屏幕像素，不随模型/镜头缩放）；
##   ③ 不挡单位主体 —— 画在头顶锚点**下方 9px**（血条在上方，两者不打架）。
func _draw_stars(n: int, center: Vector2) -> void:
	if n <= 0:
		return
	var r: float = STAR_PX * 0.5 * zoom
	var gap: float = STAR_PX * 1.12 * zoom
	var total: float = gap * float(maxi(n - 1, 0))
	var x0: float = center.x - total * 0.5
	for i in n:
		var c := Vector2(x0 + gap * float(i), center.y)
		_star(c, r + 1.1 * zoom, COL_STAR_EDGE)
		_star(c, r, COL_STAR)


## 一颗五角星（三角扇拼；draw_colored_polygon 对凹多边形不稳，别用）
func _star(c: Vector2, r: float, col: Color) -> void:
	var pts: Array[Vector2] = []
	for i in 10:
		var a: float = -PI * 0.5 + PI * 0.2 * float(i)
		var rr: float = r if i % 2 == 0 else r * 0.44
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	for i in 10:
		draw_colored_polygon(PackedVector2Array([
			pts[i], pts[(i + 1) % 10], c]), col)


## 血条（+ 蓝条）。宽度按单位体量走：兵 44，建筑 108
func _draw_bars(u: Node3D, sp: Vector2) -> void:
	var d: UnitDef = u.def
	# 星级会抬高生命上限：血条必须按**有效上限**算，否则升星后条永远不满
	var total: float = float(u.call("max_hp")) if u.has_method("max_hp") else (d.max_hp if d != null else 100.0)
	var cur: float = float(u.get("hp"))
	var r: float = clampf(cur / maxf(total, 1.0), 0.0, 1.0)
	var big: bool = d != null and d.is_building()
	var w: float = (108.0 if big else 44.0) * zoom
	var hh: float = 6.0 * zoom
	var x: float = sp.x - w * 0.5
	var y: float = sp.y - hh
	draw_rect(Rect2(x - 1.0 * zoom, y - 1.0 * zoom, w + 2.0 * zoom, hh + 2.0 * zoom),
		Color(0.0, 0.0, 0.0, 0.62), true)
	draw_rect(Rect2(x, y, w, hh), Color(0.10, 0.09, 0.09, 0.86), true)
	if r > 0.001:
		var col: Color = _hp_color(r)
		draw_rect(Rect2(x, y, w * r, hh), col, true)
		draw_rect(Rect2(x, y, w * r, maxf(1.0 * zoom, hh * 0.28)),
			Color(minf(col.r + 0.16, 1.0), minf(col.g + 0.16, 1.0), minf(col.b + 0.16, 1.0), 0.9), true)
	# 队伍色描边：多队图里"这条血是谁的"一眼分清
	var f: RtsFaction = u.faction
	if f != null:
		draw_rect(Rect2(x - 1.0 * zoom, y - 1.0 * zoom, w + 2.0 * zoom, hh + 2.0 * zoom),
			Color(f.color.r, f.color.g, f.color.b, 0.55), false, 1.0 * zoom)

	# 蓝条（没法力就不画）
	var has_m: bool = bool(u.call("has_mana")) if u.has_method("has_mana") else false
	if not has_m:
		return
	var mw: float = w * 0.78
	var mh: float = 3.0 * zoom
	var mx: float = sp.x - mw * 0.5
	var my: float = y + hh + 2.0 * zoom
	draw_rect(Rect2(mx, my, mw, mh), Color(0.04, 0.06, 0.12, 0.82), true)
	var mmax: float = float(u.call("max_mana"))
	var mcur: float = float(u.get("mana"))
	var mr: float = clampf(mcur / maxf(mmax, 1.0), 0.0, 1.0)
	if mr > 0.001:
		draw_rect(Rect2(mx, my, mw * mr, mh), Color(0.36, 0.64, 1.0, 0.95), true)


## 血量色：满血绿 → 半血黄 → 残血红（和底栏血条同一套阈值）
func _hp_color(r: float) -> Color:
	if r > 0.6:
		return Color(0.36, 0.80, 0.34)
	if r > 0.3:
		return Color(0.92, 0.78, 0.26)
	return Color(0.90, 0.26, 0.22)


## 姿态图标：驻守 = 盾 / 观察 = 眼 / 路径 = 双旗
func _draw_guard(u: Node3D, c: Vector2) -> void:
	var g: int = int(u.get("guard_mode"))
	var col: Color = COL_HOLD
	var s: float = 9.0 * zoom
	if g == 2:
		col = COL_OBSERVE
	elif g == 3:
		col = COL_PATROL
	draw_circle(c, s + 2.0 * zoom, Color(0.03, 0.04, 0.06, 0.72))
	draw_arc(c, s + 2.0 * zoom, 0.0, TAU, 20, Color(col.r, col.g, col.b, 0.55), 1.2 * zoom)
	if g == 1:
		_draw_shield(c, s, col)
	elif g == 2:
		_draw_eye(c, s, col)
	else:
		_draw_path_flags(c, s, col)


## 盾牌（驻守）
func _draw_shield(c: Vector2, s: float, col: Color) -> void:
	var pts := PackedVector2Array([
		c + Vector2(-s * 0.62, -s * 0.72),
		c + Vector2(s * 0.62, -s * 0.72),
		c + Vector2(s * 0.62, s * 0.12),
		c + Vector2(0.0, s * 0.86),
		c + Vector2(-s * 0.62, s * 0.12),
	])
	draw_colored_polygon(pts, col)
	draw_line(c + Vector2(0.0, -s * 0.55), c + Vector2(0.0, s * 0.55),
		Color(0.06, 0.08, 0.12, 0.55), 1.2 * zoom)


## 眼睛（观察）
func _draw_eye(c: Vector2, s: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 13:
		var t: float = float(i) / 12.0
		var x: float = lerpf(-s * 0.92, s * 0.92, t)
		pts.append(c + Vector2(x, -sin(t * PI) * s * 0.62))
	for j in range(12, -1, -1):
		var t2: float = float(j) / 12.0
		var x2: float = lerpf(-s * 0.92, s * 0.92, t2)
		pts.append(c + Vector2(x2, sin(t2 * PI) * s * 0.62))
	draw_colored_polygon(pts, Color(0.05, 0.09, 0.10, 0.9))
	draw_circle(c, s * 0.42, col)
	draw_circle(c, s * 0.18, Color(0.04, 0.06, 0.08, 0.95))


## 双旗（路径巡逻）
func _draw_path_flags(c: Vector2, s: float, col: Color) -> void:
	draw_line(c + Vector2(-s * 0.9, s * 0.55), c + Vector2(s * 0.9, s * 0.55),
		Color(col.r, col.g, col.b, 0.75), 1.6 * zoom)
	for k in 3:
		var t: float = -0.6 + 0.6 * float(k)
		draw_circle(c + Vector2(t * s, s * 0.55), 1.5 * zoom, col)
	for sx in [-1.0, 1.0]:
		var base: Vector2 = c + Vector2(sx * s * 0.62, s * 0.45)
		draw_line(base, base + Vector2(0.0, -s * 1.15),
			Color(col.r * 0.9, col.g * 0.9, col.b * 0.9, 0.95), 1.6 * zoom)
		var tri := PackedVector2Array([
			base + Vector2(0.0, -s * 1.15),
			base + Vector2(sx * s * 0.55, -s * 0.92),
			base + Vector2(0.0, -s * 0.70),
		])
		draw_colored_polygon(tri, col)
