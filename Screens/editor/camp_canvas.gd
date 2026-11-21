extends Control
## 类自走棋营地摆放器（自定义绘制）
## 属于：Screens/editor（开发工具，不进发行版）
##
## 口径：
##   · 每座建筑站在**独立石台**上，石台之间留出宽敞行军间隙；不画棋盘格/连线格；
##   · 玩家营地是 RTS 错落布局（基地居中、农场两翼、兵营前压），不是一字排开；
##   · 拖动建筑到空石台即可换槽位；预摆按钮恢复 1 基地 + 2 农场 + 1 兵营；
##   · 右侧是敌方固定建筑（可增删，坐标写回 levels.json）。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")

var editor: Control = null
var data: RefCounted = null

var _font: Font = null
var _bold: Font = null
var _mono: Font = null
var _show_enemy := true
var _sel_plot := -1
var _sel_enemy := -1
var _hover_plot := -1
var _hover_enemy := -1
var _drag_from := -1
var _dragging := false
var _drag_pos := Vector2.ZERO
var _mouse := Vector2.ZERO
var _changed: Callable = Callable()


# ===========================================================================
func setup(p_editor: Control, p_data: RefCounted) -> void:
	editor = p_editor
	data = p_data
	_font = ThemeKit.ui_font()
	_bold = ThemeKit.bold_font()
	_mono = ThemeKit.mono_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(queue_redraw)


func connect_changed(cb: Callable) -> void:
	_changed = cb


func set_show_enemy(on: bool) -> void:
	_show_enemy = on
	queue_redraw()


func refresh() -> void:
	queue_redraw()


func add_enemy() -> void:
	data.call("add_enemy_building")
	_sel_enemy = (data.call("enemy_buildings") as Array).size() - 1
	_sel_plot = -1
	_emit_changed()
	queue_redraw()


func remove_selected_enemy() -> void:
	var arr: Array = data.call("enemy_buildings")
	if _sel_enemy >= 0 and _sel_enemy < arr.size():
		arr.remove_at(_sel_enemy)
		_sel_enemy = -1
		_emit_changed()
		queue_redraw()


func _emit_changed() -> void:
	if _changed.is_valid():
		_changed.call()


func T(key: String, params: Dictionary = {}) -> String:
	return editor.call("T", key, params) if editor != null else key


# ===========================================================================
# 坐标
# ===========================================================================
func _pad() -> Vector2:
	return Vector2(48.0, 38.0)


func _plot_center(p: Dictionary) -> Vector2:
	var pad := _pad()
	return Vector2(
		pad.x + float(p.get("x", 0.5)) * (size.x - pad.x * 2.0),
		pad.y + float(p.get("y", 0.5)) * (size.y - pad.y * 2.0)
	)


func _plot_radius(p: Dictionary) -> float:
	return float(p.get("radius", 0.045)) * maxf(size.y - _pad().y * 2.0, 1.0) * 1.55


func _enemy_center(e: Dictionary) -> Vector2:
	var pad := _pad()
	return Vector2(
		pad.x + float(e.get("x", 0.8)) * (size.x - pad.x * 2.0),
		pad.y + float(e.get("y", 0.5)) * (size.y - pad.y * 2.0)
	)


func _enemy_radius(_e: Dictionary) -> float:
	return maxf(size.y * 0.068, 19.0)


# ===========================================================================
# 绘制
# ===========================================================================
func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 10.0 or h < 10.0:
		return
	var bg := ThemeKit.box(Color("#0D121A"), Color("#263146"), 14, 1, 0.0, 0.0)
	draw_style_box(bg, Rect2(Vector2.ZERO, size))

	_draw_ground(w, h)
	_draw_regions(w, h)
	_draw_corridor(w, h)
	_draw_gap_measure()
	_draw_enemy_buildings()
	_draw_platforms()
	_draw_drag_ghost()
	_draw_headers(w, h)


func _draw_ground(w: float, h: float) -> void:
	for i in 16:
		var t := float(i) / 15.0
		var c := Color("#121926").lerp(Color("#0D121A"), t)
		draw_rect(Rect2(0.0, h * float(i) / 16.0, w, h / 16.0 + 1.0), c)
	# 岩层等高线（无网格）
	for k in 8:
		var y0 := h * (0.18 + 0.09 * float(k))
		var pts := PackedVector2Array()
		for i in 46:
			var x := w * float(i) / 45.0
			var y := y0 + sin(x * 0.0055 + float(k) * 2.1) * (5.0 + float(k) * 1.8)
			pts.append(Vector2(x, y))
		draw_polyline(pts, Color(1, 1, 1, 0.016), 1.0, true)
	draw_circle(Vector2(w * 0.30, h * 0.48), w * 0.24, Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.035))
	draw_circle(Vector2(w * 0.88, h * 0.50), w * 0.12, Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.030))


func _draw_regions(w: float, h: float) -> void:
	var player := ThemeKit.box(Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.030),
		Color(ThemeKit.ACCENT.r, ThemeKit.ACCENT.g, ThemeKit.ACCENT.b, 0.18), 18, 1, 0.0, 0.0)
	draw_style_box(player, Rect2(Vector2(18.0, 14.0), Vector2(w * 0.62, h - 28.0)))
	var enemy := ThemeKit.box(Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.028),
		Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.16), 18, 1, 0.0, 0.0)
	draw_style_box(enemy, Rect2(Vector2(w * 0.665, 14.0), Vector2(w * 0.315, h - 28.0)))
	# 虚线分隔：两营之间的行军带
	var x := w * 0.653
	var y := 30.0
	while y < h - 24.0:
		draw_line(Vector2(x, y), Vector2(x, minf(y + 9.0, h - 24.0)), Color(ThemeKit.TEXT_DIM.r, ThemeKit.TEXT_DIM.g, ThemeKit.TEXT_DIM.b, 0.40), 1.0)
		y += 18.0


func _draw_corridor(w: float, h: float) -> void:
	var y := h * 0.5
	var x0 := w * 0.632
	var x1 := w * 0.700
	var pts := PackedVector2Array()
	var p := x0
	while p < x1:
		pts.append(Vector2(p, y))
		pts.append(Vector2(minf(p + 5.0, x1), y))
		p += 11.0
	if pts.size() >= 2:
		draw_polyline(pts, Color(ThemeKit.GREEN.r, ThemeKit.GREEN.g, ThemeKit.GREEN.b, 0.55), 2.0, true)
	draw_colored_polygon(PackedVector2Array([
		Vector2(x1 + 2.0, y - 6.0), Vector2(x1 + 14.0, y), Vector2(x1 + 2.0, y + 6.0)
	]), Color(ThemeKit.GREEN.r, ThemeKit.GREEN.g, ThemeKit.GREEN.b, 0.7))


func _draw_gap_measure() -> void:
	var list: Array = data.call("platforms")
	if list.size() < 2:
		return
	var best := 99999.0
	var a: Dictionary = list[0]
	var b: Dictionary = list[1]
	for i in list.size():
		for j in range(i + 1, list.size()):
			var pa: Dictionary = list[i]
			var pb: Dictionary = list[j]
			var d := _plot_center(pa).distance_to(_plot_center(pb))
			if d < best:
				best = d
				a = pa
				b = pb
	if best > 9000.0:
		return
	var ca := _plot_center(a)
	var cb := _plot_center(b)
	var ra := _plot_radius(a)
	var rb := _plot_radius(b)
	var dir := (cb - ca).normalized()
	var p1 := ca + dir * ra
	var p2 := cb - dir * rb
	var mid := (p1 + p2) * 0.5
	var col := Color(ThemeKit.CYAN.r, ThemeKit.CYAN.g, ThemeKit.CYAN.b, 0.55)
	draw_dashed_line(p1, p2, col, 1.2, 5.0, true)
	draw_line(p1, p1 + dir.orthogonal() * 5.0, col, 1.2)
	draw_line(p1, p1 - dir.orthogonal() * 5.0, col, 1.2)
	draw_line(p2, p2 + dir.orthogonal() * 5.0, col, 1.2)
	draw_line(p2, p2 - dir.orthogonal() * 5.0, col, 1.2)
	var label := T("editor.level.gap_value", {"v": "%.2f" % float(data.call("min_gap_meters"))})
	var tw := _text_width(label, 11, _mono)
	var box := ThemeKit.box(Color("#0E141E"), Color(col.r, col.g, col.b, 0.5), 7, 1, 7.0, 2.0)
	draw_style_box(box, Rect2(mid + Vector2(-tw * 0.5 - 8.0, 8.0), Vector2(tw + 16.0, 20.0)))
	_text(label, mid + Vector2(-tw * 0.5, 22.0), 11, ThemeKit.CYAN, _mono)


func _draw_platforms() -> void:
	var list: Array = data.call("platforms")
	var starts: Array = data.call("start_buildings")
	for p in list:
		var plot := int((p as Dictionary).get("plot", -1))
		var center := _plot_center(p)
		var radius := _plot_radius(p)
		var entry := _find_start(starts, plot)
		var occupied := not entry.is_empty()
		var selected := _sel_plot == plot
		var hover := _hover_plot == plot
		var dragging_target := _dragging and _drag_from != plot and not occupied
		var accent := ThemeKit.ACCENT
		if occupied:
			var bd: Dictionary = data.call("building_by_id", String(entry.get("building", "")))
			accent = _building_color(String(entry.get("building", "")), bd)
		_draw_platform(center, radius, accent, occupied, selected, hover, dragging_target, plot)
		if occupied:
			_draw_building_token(center, radius, entry, accent)
		else:
			_draw_empty_slot(center, radius, plot, accent, hover or dragging_target)


func _draw_platform(center: Vector2, radius: float, accent: Color, occupied: bool,
		selected: bool, hover: bool, drop_target: bool, _plot: int) -> void:
	var shadow := Color(0.0, 0.0, 0.0, 0.34)
	draw_circle(center + Vector2(0.0, radius * 0.28), radius * 1.03, shadow)
	# 侧壁
	var side := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + TAU * float(i) / 10.0
		side.append(center + Vector2(cos(a), sin(a)) * radius + Vector2(0.0, radius * 0.18))
	draw_colored_polygon(side, Color("#121925"))
	# 顶面
	var top := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + TAU * float(i) / 10.0
		top.append(center + Vector2(cos(a), sin(a)) * radius)
	draw_colored_polygon(top, Color("#233047") if occupied else Color("#1B2434"))
	var inner := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + TAU * float(i) / 10.0 + 0.10
		inner.append(center + Vector2(cos(a), sin(a)) * (radius * 0.82))
	draw_colored_polygon(inner, Color("#1A2434") if occupied else Color("#161E2B"))
	draw_circle(center, radius * 0.58, Color(accent.r, accent.g, accent.b, 0.07))
	# 边缘
	var rim := top.duplicate()
	rim.append(top[0])
	var rim_col := Color(accent.r, accent.g, accent.b, 0.55 if occupied else 0.28)
	draw_polyline(rim, rim_col, 1.4, true)
	if selected or drop_target:
		var ring := Color(accent.r, accent.g, accent.b, 0.95 if selected else ThemeKit.GREEN.a)
		draw_arc(center, radius + 5.0, 0.0, TAU, 40, ring, 2.0, true)
		draw_arc(center, radius + 9.0, 0.0, TAU, 40, Color(ring.r, ring.g, ring.b, 0.20), 5.0, true)
	elif hover:
		draw_arc(center, radius + 3.5, 0.0, TAU, 40, Color(accent.r, accent.g, accent.b, 0.55), 1.4, true)
	# 槽位小刻度
	for i in 10:
		var a := -PI * 0.5 + TAU * float(i) / 10.0 + 0.10
		draw_line(center + Vector2(cos(a), sin(a)) * radius * 0.72,
			center + Vector2(cos(a), sin(a)) * radius * 0.78, Color(1, 1, 1, 0.08), 1.0)


func _draw_building_token(center: Vector2, radius: float, entry: Dictionary, accent: Color) -> void:
	var bid := String(entry.get("building", ""))
	var bd: Dictionary = data.call("building_by_id", bid)
	var nm := String(bd.get("display_name", bid))
	_draw_building_icon(bid, center, radius * 0.72, accent)
	# 名牌
	var tw := _text_width(nm, 13, _bold)
	var bw := maxf(tw + 22.0, 70.0)
	var by := center.y - radius - 27.0
	var box := ThemeKit.box(Color(accent.r, accent.g, accent.b, 0.16), Color(accent.r, accent.g, accent.b, 0.52), 8, 1, 6.0, 2.0)
	draw_style_box(box, Rect2(center.x - bw * 0.5, by, bw, 22.0))
	_text(nm, Vector2(center.x - tw * 0.5, by + 16.0), 13, ThemeKit.TEXT, _bold)
	# 星级
	var star := int(entry.get("star", 1))
	for i in 3:
		var px := center.x - 11.0 + float(i) * 11.0
		var py := by + 27.0
		var c := ThemeKit.GOLD if i < star else Color(ThemeKit.TEXT_DIM.r, ThemeKit.TEXT_DIM.g, ThemeKit.TEXT_DIM.b, 0.40)
		draw_colored_polygon(PackedVector2Array([
			Vector2(px, py - 3.6), Vector2(px + 3.4, py), Vector2(px, py + 3.6), Vector2(px - 3.4, py)
		]), c)


func _draw_empty_slot(center: Vector2, radius: float, plot: int, accent: Color, hot: bool) -> void:
	var col := Color(accent.r, accent.g, accent.b, 0.34 if not hot else 0.75)
	for k in 16:
		if k % 2 == 0:
			draw_arc(center, radius * 0.66, TAU * float(k) / 16.0, TAU * float(k + 1) / 16.0, 4, col, 1.2, true)
	var plus := 7.0
	draw_line(center + Vector2(-plus, 0.0), center + Vector2(plus, 0.0), col, 1.6)
	draw_line(center + Vector2(0.0, -plus), center + Vector2(0.0, plus), col, 1.6)
	var lab := T("editor.level.plot", {"n": "%02d" % plot})
	var tw := _text_width(lab, 10, _mono)
	_text(lab, Vector2(center.x - tw * 0.5, center.y + radius * 0.42), 10, Color(ThemeKit.TEXT_SUB.r, ThemeKit.TEXT_SUB.g, ThemeKit.TEXT_SUB.b, 0.9), _mono)
	var free_lab := T("editor.level.free")
	var fw := _text_width(free_lab, 10, _bold)
	_text(free_lab, Vector2(center.x - fw * 0.5, center.y + radius * 0.72), 10, Color(accent.r, accent.g, accent.b, 0.55), _bold)


func _draw_building_icon(kind: String, c: Vector2, s: float, accent: Color) -> void:
	var base := Color("#1B2638")
	var edge := Color(accent.r, accent.g, accent.b, 0.92)
	var top := Color(accent.r, accent.g, accent.b, 0.25)
	match kind:
		"keep":
			draw_rect(Rect2(c.x - s * 0.62, c.y - s * 0.20, s * 1.24, s * 0.62), base)
			draw_rect(Rect2(c.x - s * 0.62, c.y - s * 0.20, s * 1.24, s * 0.12), top)
			for dx in [-0.62, -0.18, 0.26]:
				draw_rect(Rect2(c.x + s * dx, c.y - s * 0.52, s * 0.30, s * 0.34), base)
				draw_rect(Rect2(c.x + s * dx, c.y - s * 0.52, s * 0.30, s * 0.09), top)
			draw_line(Vector2(c.x, c.y - s * 0.52), Vector2(c.x, c.y - s * 0.92), edge, 1.4)
			draw_colored_polygon(PackedVector2Array([
				Vector2(c.x, c.y - s * 0.92), Vector2(c.x + s * 0.26, c.y - s * 0.82), Vector2(c.x, c.y - s * 0.70)
			]), edge)
		"farm":
			draw_rect(Rect2(c.x - s * 0.62, c.y - s * 0.12, s * 1.05, s * 0.56), base)
			draw_colored_polygon(PackedVector2Array([
				Vector2(c.x - s * 0.76, c.y - s * 0.12), Vector2(c.x - s * 0.12, c.y - s * 0.58), Vector2(c.x + s * 0.52, c.y - s * 0.12)
			]), top)
			for i in 3:
				draw_line(Vector2(c.x + s * (0.22 + float(i) * 0.16), c.y + s * 0.08),
					Vector2(c.x + s * (0.28 + float(i) * 0.16), c.y + s * 0.40), edge, 1.0)
		"barracks":
			draw_rect(Rect2(c.x - s * 0.72, c.y - s * 0.14, s * 1.44, s * 0.60), base)
			draw_colored_polygon(PackedVector2Array([
				Vector2(c.x - s * 0.82, c.y - s * 0.14), Vector2(c.x, c.y - s * 0.62), Vector2(c.x + s * 0.82, c.y - s * 0.14)
			]), top)
			draw_line(Vector2(c.x + s * 0.52, c.y - s * 0.62), Vector2(c.x + s * 0.52, c.y - s * 0.96), edge, 1.2)
			draw_rect(Rect2(c.x + s * 0.52, c.y - s * 0.96, s * 0.28, s * 0.20), Color(edge.r, edge.g, edge.b, 0.6))
		"watchtower", "tower":
			draw_rect(Rect2(c.x - s * 0.28, c.y - s * 0.52, s * 0.56, s * 0.94), base)
			draw_rect(Rect2(c.x - s * 0.42, c.y - s * 0.68, s * 0.84, s * 0.22), base)
			draw_colored_polygon(PackedVector2Array([
				Vector2(c.x - s * 0.46, c.y - s * 0.68), Vector2(c.x, c.y - s * 1.00), Vector2(c.x + s * 0.46, c.y - s * 0.68)
			]), top)
			draw_line(Vector2(c.x, c.y - s * 1.00), Vector2(c.x, c.y - s * 1.22), edge, 1.2)
		_:
			draw_rect(Rect2(c.x - s * 0.5, c.y - s * 0.3, s, s * 0.7), base)
	var foot := PackedVector2Array([Vector2(c.x - s * 0.82, c.y + s * 0.46), Vector2(c.x + s * 0.82, c.y + s * 0.46)])
	draw_polyline(foot, edge, 1.4, true)


func _draw_enemy_buildings() -> void:
	if not _show_enemy:
		return
	var arr: Array = data.call("enemy_buildings")
	for i in arr.size():
		var e: Dictionary = arr[i]
		var c := _enemy_center(e)
		var r := _enemy_radius(e)
		var selected := _sel_enemy == i
		var hover := _hover_enemy == i
		# 敌方石台：六边形，红边
		var top := PackedVector2Array()
		for k in 6:
			var a := -PI * 0.5 + TAU * float(k) / 6.0
			top.append(c + Vector2(cos(a), sin(a)) * r)
		draw_circle(c + Vector2(0.0, r * 0.30), r * 1.04, Color(0, 0, 0, 0.32))
		draw_colored_polygon(top, Color("#2A1E25"))
		var inner := PackedVector2Array()
		for k in 6:
			var a := -PI * 0.5 + TAU * float(k) / 6.0
			inner.append(c + Vector2(cos(a), sin(a)) * r * 0.84)
		draw_colored_polygon(inner, Color("#201820"))
		var rim := top.duplicate()
		rim.append(top[0])
		draw_polyline(rim, Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.70 if selected else 0.42), 1.5, true)
		if selected or hover:
			draw_arc(c, r + 5.0, 0.0, TAU, 30, Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.9), 1.8, true)
		var bid := String(e.get("building", ""))
		var bd: Dictionary = data.call("building_by_id", bid)
		_draw_building_icon(bid, c, r * 0.80, ThemeKit.RED)
		var nm := String(bd.get("display_name", bid))
		var tw := _text_width(nm, 12, _bold)
		var by := c.y - r - 24.0
		var box := ThemeKit.box(Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.16), Color(ThemeKit.RED.r, ThemeKit.RED.g, ThemeKit.RED.b, 0.48), 7, 1, 6.0, 2.0)
		draw_style_box(box, Rect2(c.x - (tw + 18.0) * 0.5, by, tw + 18.0, 20.0))
		_text(nm, Vector2(c.x - tw * 0.5, by + 15.0), 12, ThemeKit.TEXT, _bold)
		var star := int(e.get("star", 1))
		for k in 3:
			var px := c.x - 10.0 + float(k) * 10.0
			var py := by + 25.0
			var col := ThemeKit.RED if k < star else Color(ThemeKit.TEXT_DIM.r, ThemeKit.TEXT_DIM.g, ThemeKit.TEXT_DIM.b, 0.35)
			draw_colored_polygon(PackedVector2Array([
				Vector2(px, py - 3.2), Vector2(px + 3.0, py), Vector2(px, py + 3.2), Vector2(px - 3.0, py)
			]), col)


func _draw_drag_ghost() -> void:
	if not _dragging or _drag_from < 0:
		return
	var entry: Dictionary = data.call("start_at_plot", _drag_from)
	if entry.is_empty():
		return
	var bid := String(entry.get("building", ""))
	var bd: Dictionary = data.call("building_by_id", bid)
	var accent := _building_color(bid, bd)
	draw_circle(_drag_pos + Vector2(0.0, 6.0), 34.0, Color(0, 0, 0, 0.35))
	_draw_building_icon(bid, _drag_pos, 28.0, accent)
	var nm := String(bd.get("display_name", bid))
	var tw := _text_width(nm, 12, _bold)
	var box := ThemeKit.box(Color(accent.r, accent.g, accent.b, 0.22), Color(accent.r, accent.g, accent.b, 0.8), 7, 1, 6.0, 2.0)
	draw_style_box(box, Rect2(_drag_pos.x - (tw + 18.0) * 0.5, _drag_pos.y + 34.0, tw + 18.0, 20.0))
	_text(nm, Vector2(_drag_pos.x - tw * 0.5, _drag_pos.y + 49.0), 12, ThemeKit.TEXT, _bold)


func _draw_headers(w: float, h: float) -> void:
	_text_chip(Vector2(34.0, 26.0), T("editor.level.player"), ThemeKit.ACCENT)
	_text_chip(Vector2(w * 0.685, 26.0), T("editor.level.enemy"), ThemeKit.RED)
	var camp: Vector2 = data.call("camp_meters")
	_text("%.1f × %.1f m" % [camp.x, camp.y], Vector2(w * 0.5 - 34.0, h - 18.0), 11, Color(ThemeKit.TEXT_DIM.r, ThemeKit.TEXT_DIM.g, ThemeKit.TEXT_DIM.b, 0.8), _mono)
	var src := String(T("editor.level.camp_source"))
	var sw := _text_width(src, 10, _font)
	_text(src, Vector2(w - sw - 26.0, h - 18.0), 10, Color(ThemeKit.TEXT_DIM.r, ThemeKit.TEXT_DIM.g, ThemeKit.TEXT_DIM.b, 0.7), _font)


func _text_chip(pos: Vector2, text: String, color: Color) -> void:
	var tw := _text_width(text, 13, _bold)
	var box := ThemeKit.box(Color(color.r, color.g, color.b, 0.14), Color(color.r, color.g, color.b, 0.42), 12, 1, 9.0, 4.0)
	draw_style_box(box, Rect2(pos, Vector2(tw + 20.0, 24.0)))
	_text(text, pos + Vector2(10.0, 17.0), 13, color, _bold)


func _text(text: String, pos: Vector2, size_px: int, color: Color, font: Font = null) -> void:
	if text.is_empty():
		return
	var f := font if font != null else _font
	if f == null:
		return
	draw_string(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px, color)


func _text_width(text: String, size_px: int, font: Font = null) -> float:
	var f := font if font != null else _font
	if f == null:
		return float(text.length() * size_px * 0.6)
	return f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px).x


func _building_color(bid: String, bd: Dictionary) -> Color:
	match String(bd.get("tag", "")):
		"base":
			return ThemeKit.GOLD
		"farm":
			return ThemeKit.GREEN
		"barracks":
			return ThemeKit.ACCENT
		"tower":
			return ThemeKit.CYAN
	return ThemeKit.ACCENT


func _find_start(starts: Array, plot: int) -> Dictionary:
	for s in starts:
		if int((s as Dictionary).get("plot", -1)) == plot:
			return s as Dictionary
	return {}


# ===========================================================================
# 输入
# ===========================================================================
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position
		if _dragging:
			_drag_pos = _mouse
		_update_hover(_mouse)
		queue_redraw()
		accept_event()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_on_press(mb.position)
			accept_event()
		else:
			_on_release(mb.position)
			accept_event()


func _update_hover(pos: Vector2) -> void:
	_hover_plot = _hit_plot(pos)
	_hover_enemy = -1
	if _show_enemy and _hover_plot < 0:
		_hover_enemy = _hit_enemy(pos)
	if _dragging:
		mouse_default_cursor_shape = Control.CURSOR_DRAG
	else:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _on_press(pos: Vector2) -> void:
	if _show_enemy:
		var ei := _hit_enemy(pos)
		if ei >= 0:
			_sel_enemy = ei
			_sel_plot = -1
			queue_redraw()
			return
	var plot := _hit_plot(pos)
	if plot < 0:
		return
	_sel_plot = plot
	_sel_enemy = -1
	var entry: Dictionary = data.call("start_at_plot", plot)
	if not entry.is_empty():
		_drag_from = plot
		_dragging = true
		_drag_pos = pos
	queue_redraw()


func _on_release(pos: Vector2) -> void:
	if not _dragging:
		return
	_dragging = false
	var target := _hit_plot(pos)
	var from := _drag_from
	_drag_from = -1
	if target >= 0 and target != from:
		if bool(data.call("move_start", from, target)):
			_sel_plot = target
			_emit_changed()
	queue_redraw()


func _hit_plot(pos: Vector2) -> int:
	var list: Array = data.call("platforms")
	for p in list:
		var d: Dictionary = p
		var c := _plot_center(d)
		var r := _plot_radius(d)
		if pos.distance_to(c) <= r * 1.08:
			return int(d.get("plot", -1))
	return -1


func _hit_enemy(pos: Vector2) -> int:
	var arr: Array = data.call("enemy_buildings")
	for i in arr.size():
		var e: Dictionary = arr[i]
		if pos.distance_to(_enemy_center(e)) <= _enemy_radius(e) * 1.15:
			return i
	return -1
