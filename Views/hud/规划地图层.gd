extends Control
## **规划地图层**（2026-11-15）—— 规划阶段盖在 3D 战场上的那一层"作战图"。
##
## 画三样东西（全部在 `_draw` 里画，不建子节点）：
##   ① **部署预览**（随鼠标实时变）：
##        进攻 = 从队心指向鼠标的虚线箭头；
##        防守 = 蓝色防区块（10m 圆）+ 虚线环；
##        占据 = 据点金圈高亮（靠近自动吸附）。
##   ② **已下达的部署标记**：向下的箭头 / 防区环 / 旗子 / 采集点…
##   ③ **敌方明牌意图**：挂在敌方大本营头顶（"第 N 波 · 4 步兵 2 弓手"）。
##
## 为什么挂在 CanvasLayer 上、不进 HUD 的 root：
##   它要用**屏幕像素**对齐 3D 投影（`Camera3D.unproject_position` 返回的是屏幕坐标），
##   而 root 被 `_zoom` 反拉伸过，混在一起每个坐标都要除一次缩放，容易错。
##   和「头顶界面」同一个口径：铺满视口、自己同步尺寸、键鼠穿透（MOUSE_FILTER_IGNORE）。

const Spec := preload("res://Views/hud/界面规格.gd")
const WAR := preload("res://Game/ai/战区指令.gd")

const COL_ATTACK := Color(1.0, 0.60, 0.30)
const COL_DEFEND := Color(0.44, 0.72, 1.0)
const COL_CAPTURE := Color(1.0, 0.84, 0.36)
const COL_MOVE := Color(0.62, 0.94, 0.56)
const COL_ENEMY := Color(1.0, 0.40, 0.34)

## 重绘节流（秒）：预览要跟手，20Hz 足够，别每帧重画整张图
const REDRAW := 0.05

var zoom: float = 1.0
var _t: float = 0.0
var _pending: float = 0.0
var _font: Font = null
var _mono: Font = null
var _hud: Node = null
## "明牌意图"允许摆放的安全区（屏幕像素；HUD 每次摆位时注入）
var _safe: Rect2 = Rect2(250.0, 210.0, 900.0, 400.0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "规划地图层"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = Spec.cjk_font()
	_mono = Spec.mono_font()
	visible = false


func setup(hud: Node) -> void:
	_hud = hud


func set_zoom(z: float) -> void:
	zoom = clampf(z, 0.5, 2.5)


## HUD 注入"明牌意图"的安全区（避开左上小地图列、顶部播报、底部操作面板）
func set_safe_rect(r: Rect2) -> void:
	if r.size.x > 120.0 and r.size.y > 80.0:
		_safe = r


func _process(delta: float) -> void:
	if not visible:
		return
	var vp := get_viewport()
	if vp != null:
		var vp_size: Vector2 = vp.get_visible_rect().size
		if absf(size.x - vp_size.x) > 0.5 or absf(size.y - vp_size.y) > 0.5:
			size = vp_size
			position = Vector2.ZERO
	_t += delta
	_pending -= delta
	if _pending <= 0.0:
		_pending = REDRAW
		queue_redraw()


func _draw() -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	_draw_preview(cam)
	_draw_planned(cam)
	_draw_enemy_intent(cam)


# ===========================================================================
# ① 部署预览
# ===========================================================================

func _draw_preview(cam: Camera3D) -> void:
	var di := _deploy_node()
	if di == null or not di.has_method("preview"):
		return
	var pv: Dictionary = di.call("preview")
	if pv.is_empty():
		return
	var mode: int = int(pv.get("mode", 0))
	var to: Vector3 = pv.get("to", Vector3.INF)
	if to == Vector3.INF:
		return
	var ok: bool = bool(pv.get("ok", false))
	match mode:
		WAR.ATTACK:
			var from: Vector3 = pv.get("from", Vector3.ZERO)
			var a: Vector2 = _project(cam, _lift(from, 0.7))
			var b: Vector2 = _project(cam, _lift(to, 0.3))
			if a == Vector2.INF or b == Vector2.INF:
				return
			_dashed_line(a, b, Color(COL_ATTACK, 0.92 if ok else 0.45), 3.0 * zoom, 9.0 * zoom)
			_arrow_head(b, (b - a).normalized(), 15.0 * zoom,
					Color(COL_ATTACK, 0.98 if ok else 0.5))
			_ring_world(cam, to, 1.1, Color(COL_ATTACK, 0.9), 2.0 * zoom)
		WAR.DEFEND:
			var r: float = float(pv.get("radius", 10.0))
			_zone_world(cam, to, r, COL_DEFEND, ok)
		WAR.CAPTURE:
			var snap: Variant = pv.get("snap", null)
			var radius: float = 8.0 if snap != null else 6.0
			var col: Color = COL_CAPTURE
			_zone_world(cam, to, radius, col, ok)
			if snap != null:
				var sp: Vector2 = _project(cam, _lift(to, 1.2))
				if sp != Vector2.INF:
					_label(sp + Vector2(0.0, -18.0 * zoom), "据点 · 驻留 15s", col, 15)


# ===========================================================================
# ② 已下达的部署标记
# ===========================================================================

func _draw_planned(cam: Camera3D) -> void:
	var cs := _command_node()
	if cs == null or not cs.has_method("planned_records"):
		return
	var recs: Array = cs.call("planned_records")
	var n: int = mini(recs.size(), 8)
	for i in n:
		var r: Dictionary = recs[i]
		var kind: int = int(r.get("kind", 0))
		var p: Vector3 = r.get("point", Vector3.ZERO)
		# 停止/驻守没有落点（point = 0），不在地图上画
		if kind == RtsConst.Order.STOP:
			continue
		match kind:
			RtsConst.Order.DEFEND:
				_zone_world(cam, p, 10.0, COL_DEFEND, true, 0.55)
				_mark(cam, p, "守", COL_DEFEND, String(r.get("text", "")))
			RtsConst.Order.CAPTURE:
				_mark(cam, p, "旗", COL_CAPTURE, String(r.get("text", "")))
			RtsConst.Order.ATTACK_MOVE, RtsConst.Order.ATTACK:
				_mark(cam, p, "攻", COL_ATTACK, String(r.get("text", "")))
			RtsConst.Order.MOVE:
				_mark(cam, p, "移", COL_MOVE, String(r.get("text", "")))
			RtsConst.Order.GATHER:
				_mark(cam, p, "采", Color(0.98, 0.86, 0.42), String(r.get("text", "")))
			RtsConst.Order.BUILD:
				_mark(cam, p, "建", Color(0.82, 0.94, 0.72), String(r.get("text", "")))
			RtsConst.Order.HOLD:
				_mark(cam, p, "驻", COL_DEFEND, String(r.get("text", "")))
			_:
				_mark(cam, p, "令", Color(0.9, 0.9, 0.86), String(r.get("text", "")))


## 一个"圆牌 + 单字 + 右侧文案"的部署标记
func _mark(cam: Camera3D, world: Vector3, glyph: String, col: Color, text: String) -> void:
	var sp: Vector2 = _project(cam, _lift(world, 0.6))
	if sp == Vector2.INF:
		return
	var r: float = 11.0 * zoom
	var pulse: float = 1.0 + 0.06 * sin(_t * 3.4)
	draw_circle(sp, r * pulse + 2.0, Color(0.0, 0.0, 0.0, 0.42))
	draw_circle(sp, r * pulse, Color(col.r * 0.20, col.g * 0.20, col.b * 0.20, 0.94))
	draw_arc(sp, r * pulse, 0.0, TAU, 24, Color(col, 0.95), 1.8 * zoom, true)
	_text_center(sp + Vector2(0.0, 1.0), glyph, col, maxi(int(round(14.0 * zoom)), 10))
	if not text.is_empty():
		_label(sp + Vector2(r + 6.0 * zoom, 0.0), text, col, 14)


# ===========================================================================
# ③ 敌方明牌意图
# ===========================================================================

func _draw_enemy_intent(cam: Camera3D) -> void:
	if not Game.short_match:
		return
	var pl := Game.player_faction
	if pl == null:
		return
	var rc: Node = Game.round_control
	var wave_txt: String = ""
	if rc != null and rc.has_method("next_wave_text"):
		wave_txt = String(rc.call("next_wave_text"))
	# --- 先收集，再统一排版 ---
	# 为什么要先收集：多队图有 2~3 个敌人，它们的基地很可能**同时**在屏幕外、
	# 各自被夹到同一条边上。逐个体画会互相盖住（实测：两块牌子叠在左上角）。
	var items: Array = []
	for f in Game.factions:
		if f == null or not is_instance_valid(f):
			continue
		if not pl.is_enemy_of(f):
			continue
		var base: Node3D = _base_of(f)
		if base == null:
			continue
		var anchor: Vector3 = base.global_position + Vector3(0.0, _base_h(base) + 2.6, 0.0)
		var sp: Vector2 = _project(cam, anchor)
		if sp != Vector2.INF:
			_ring_world(cam, base.global_position, maxf(_base_foot(base) * 0.62, 3.0),
					Color(COL_ENEMY, 0.42), 1.6 * zoom)
		items.append({
			"name": f.display_name,
			"want": (sp if sp != Vector2.INF else size * 0.5),
			"behind": sp == Vector2.INF,
		})
	if items.is_empty():
		return
	items.sort_custom(func(a, b): return float(a["want"].y) < float(b["want"].y))
	var sub: String = wave_txt if not wave_txt.is_empty() else "意图：集结兵力"
	var h: float = 44.0 * zoom
	var stack_bottom: float = _safe.position.y - h
	for it in items:
		var title: String = "明牌 · %s：进攻" % String(it["name"])
		var w: float = maxf(_text_w(title, 15), _text_w(sub, 13)) + 26.0 * zoom
		var want: Vector2 = it["want"]
		# 先算"理想位置"，再夹进安全区；最后按上一块牌子的底边往下推，保证不重叠。
		var bx: float = clampf(want.x - w * 0.5,
				_safe.position.x, _safe.position.x + _safe.size.x - w)
		var by: float = clampf(want.y - h,
				maxf(_safe.position.y, stack_bottom + 6.0),
				_safe.position.y + _safe.size.y - h)
		var box := Rect2(Vector2(bx, by), Vector2(w, h))
		stack_bottom = maxf(stack_bottom, box.end.y)
		draw_rect(box, Color(0.10, 0.045, 0.045, 0.92), true)
		draw_rect(box, Color(COL_ENEMY, 0.88), false, 1.6 * zoom)
		# 小尖角（指向基地）：只在牌子大致压在基地上方时才画，夹到边缘时改成方向三角
		if not bool(it["behind"]) and absf(box.get_center().x - want.x) < 3.0:
			var tip := PackedVector2Array([
				Vector2(box.position.x + w * 0.5 - 7.0 * zoom, box.end.y),
				Vector2(box.position.x + w * 0.5 + 7.0 * zoom, box.end.y),
				Vector2(box.position.x + w * 0.5, box.end.y + 8.0 * zoom),
			])
			draw_colored_polygon(tip, Color(COL_ENEMY, 0.85))
		draw_string(_font, box.position + Vector2(10.0 * zoom, 18.0 * zoom), title,
				HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(int(round(15.0 * zoom)), 10),
				Color(1.0, 0.80, 0.72))
		draw_string(_font, box.position + Vector2(10.0 * zoom, 35.0 * zoom), sub,
				HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(int(round(13.0 * zoom)), 9),
				Color(0.98, 0.88, 0.80))
		# 指向敌人真实方位的三角（牌子被夹开时才画）
		var c0: Vector2 = box.get_center()
		if c0.distance_to(want) > 24.0:
			var dir: Vector2 = (want - c0).normalized()
			var nrm := Vector2(-dir.y, dir.x)
			var base_pt: Vector2 = c0 + dir * (maxf(w, h) * 0.5 + 4.0)
			var tri := PackedVector2Array([
				base_pt + dir * 11.0 * zoom,
				base_pt - dir * 2.0 * zoom + nrm * 7.0 * zoom,
				base_pt - dir * 2.0 * zoom - nrm * 7.0 * zoom,
			])
			draw_colored_polygon(tri, Color(COL_ENEMY, 0.92))


func _base_of(f: RtsFaction) -> Node3D:
	for b in f.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		if not b.def.is_dropoff or not b.def.dropoff_kinds.is_empty():
			continue
		return b
	return null


func _base_h(b: Node3D) -> float:
	var d: UnitDef = b.get("def") as UnitDef
	return d.height if d != null else 4.0


func _base_foot(b: Node3D) -> float:
	var d: UnitDef = b.get("def") as UnitDef
	if d == null:
		return 4.0
	return maxf(float(maxi(d.footprint.x, d.footprint.y)), 3.0)


# ===========================================================================
# 绘图工具
# ===========================================================================

func _project(cam: Camera3D, world: Vector3) -> Vector2:
	if cam.is_position_behind(world):
		return Vector2.INF
	return cam.unproject_position(world)


## 抬到离地 1 米左右（贴地画线会被地形吃掉一半）
func _lift(p: Vector3, up: float) -> Vector3:
	return Vector3(p.x, RtsWorld.height_at(p.x, p.z) + up, p.z)


func _dashed_line(a: Vector2, b: Vector2, col: Color, width: float, dash: float) -> void:
	var d: Vector2 = b - a
	var total: float = d.length()
	if total < 0.5:
		return
	var dir: Vector2 = d / total
	var t: float = 0.0
	while t < total:
		var t2: float = minf(t + dash * 0.55, total)
		draw_line(a + dir * t, a + dir * t2, col, width, true)
		t += dash


func _arrow_head(tip: Vector2, dir: Vector2, size: float, col: Color) -> void:
	if dir.length_squared() < 0.0001:
		return
	var n := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([
		tip,
		tip - dir * size + n * size * 0.55,
		tip - dir * size - n * size * 0.55,
	])
	draw_colored_polygon(pts, col)


## 世界空间的一个圆环（贴地形采样，投到屏幕上画闭合折线）
func _ring_world(cam: Camera3D, center: Vector3, radius: float, col: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for i in 41:
		var a: float = TAU * float(i) / 40.0
		var w := Vector3(center.x + cos(a) * radius, 0.0, center.z + sin(a) * radius)
		var sp: Vector2 = _project(cam, _lift(w, 0.16))
		if sp == Vector2.INF:
			return
		pts.append(sp)
	draw_polyline(pts, col, width, true)


## 防区：半透明色块 + 虚线外圈 + 中心十字
func _zone_world(cam: Camera3D, center: Vector3, radius: float, col: Color,
		ok: bool, alpha: float = 1.0) -> void:
	var fill := PackedVector2Array()
	var edge := PackedVector2Array()
	for i in 49:
		var a: float = TAU * float(i) / 48.0
		var w := Vector3(center.x + cos(a) * radius, 0.0, center.z + sin(a) * radius)
		var sp: Vector2 = _project(cam, _lift(w, 0.18))
		if sp == Vector2.INF:
			return
		if i < 48:
			fill.append(sp)
		edge.append(sp)
	var a_fill: float = (0.20 if ok else 0.09) * alpha
	draw_colored_polygon(fill, Color(col.r, col.g, col.b, a_fill))
	# 虚线外圈
	for i in 48:
		if i % 2 == 0:
			draw_line(edge[i], edge[i + 1], Color(col, 0.92 * alpha), 2.2 * zoom, true)
	var c: Vector2 = _project(cam, _lift(center, 0.4))
	if c != Vector2.INF:
		draw_line(c - Vector2(7, 0) * zoom, c + Vector2(7, 0) * zoom,
				Color(col, 0.9 * alpha), 1.6 * zoom, true)
		draw_line(c - Vector2(0, 7) * zoom, c + Vector2(0, 7) * zoom,
				Color(col, 0.9 * alpha), 1.6 * zoom, true)
		_label(c + Vector2(0.0, 16.0 * zoom), "%.0fm" % radius, col, 14)


func _label(pos: Vector2, text: String, col: Color, fs: int) -> void:
	var size_px: int = maxi(int(round(float(fs) * zoom)), 9)
	draw_string_outline(_font, pos + Vector2(0.0, size_px), text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, size_px, 3, Color(0.0, 0.0, 0.0, 0.72))
	draw_string(_font, pos + Vector2(0.0, size_px), text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, size_px, col)


func _text_center(pos: Vector2, text: String, col: Color, fs: int) -> void:
	var w: float = _text_w(text, fs)
	draw_string(_font, pos + Vector2(-w * 0.5, float(fs) * 0.36), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _text_w(text: String, fs: int) -> float:
	var size_px: int = maxi(int(round(float(fs) * zoom)), 9)
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x


# ===========================================================================
# 外部节点
# ===========================================================================

func _command_node() -> Node:
	var host := _hud.get_parent() if _hud != null and is_instance_valid(_hud) else null
	if host == null:
		return null
	return host.get_node_or_null("指令系统")


func _deploy_node() -> Node:
	var host := _hud.get_parent() if _hud != null and is_instance_valid(_hud) else null
	if host == null:
		return null
	return host.get_node_or_null("部署输入")
