@tool
extends Control
## 地图底壳俯视图（卡片化）：把 map_shells 的脊线、势力区域多边形、战术格子画成 2D 预览，
## 给「玩家态势布局卡」与「敌人遭遇卡」做可视化勾选/摆放。
## 属于：Screens/editor（开发工具，不进发行版）
##
## 口径：底壳管位置（格子坐标/尺寸/角色），布局卡管"激活哪几个格子"，遭遇卡管"敌方哪个格子放了什么"。
## 交互：点格子 = 切换激活（布局卡）/ 选中（遭遇卡）；不发任何写盘动作，写盘由页面调 dev_data。

signal tile_clicked(index: int)

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const ShellStore := preload("res://Screens/editor/shell_store.gd")

const PAD := 14.0

var editor: Control = null
var data: RefCounted = null

var shell_id := ""
var mode := "layout"
var layout_id := ""
var encounter_id := ""
var selected := -1

var _font: Font = null
var _bold: Font = null
var _mono: Font = null
var _map_rect := Rect2()
var _hover := -1


func setup(p_editor: Control, p_data: RefCounted) -> void:
	editor = p_editor
	data = p_data
	_font = ThemeKit.ui_font()
	_bold = ThemeKit.bold_font()
	_mono = ThemeKit.mono_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = Vector2(0.0, 280.0)
	if not resized.is_connected(queue_redraw):
		resized.connect(queue_redraw)


func set_context(p_shell: String, p_mode: String, p_layout: String, p_encounter: String) -> void:
	shell_id = p_shell
	mode = p_mode
	layout_id = p_layout
	encounter_id = p_encounter
	queue_redraw()


func refresh() -> void:
	queue_redraw()


func select_tile(index: int) -> void:
	selected = index
	queue_redraw()


func _shell() -> Dictionary:
	if data == null:
		return {}
	return data.call("shell_by_id", shell_id)


func _layout() -> Dictionary:
	if data == null:
		return {}
	return data.call("layout_by_id", layout_id)


func _encounter() -> Dictionary:
	if data == null:
		return {}
	return data.call("encounter_by_id", encounter_id)


func _t(key: String) -> String:
	return String(editor.call("T", key)) if editor != null else key


# ===========================================================================
# 坐标
# ===========================================================================
func _map_box() -> Rect2:
	var avail := Rect2(Vector2(PAD, PAD), size - Vector2(PAD * 2.0, PAD * 2.0))
	var shell := _shell()
	if shell.is_empty():
		return avail
	var sz := ShellStore.size_of(shell)
	if sz.x <= 0.0 or sz.y <= 0.0:
		return avail
	var aspect := sz.x / sz.y
	var w := avail.size.x
	var h := w / aspect
	if h > avail.size.y:
		h = avail.size.y
		w = h * aspect
	return Rect2(avail.position + (avail.size - Vector2(w, h)) * 0.5, Vector2(w, h))


func _to_px(x: float, z: float) -> Vector2:
	var shell := _shell()
	var sz := ShellStore.size_of(shell)
	if sz.x <= 0.0 or sz.y <= 0.0:
		return _map_rect.position
	return _map_rect.position + Vector2((x + sz.x * 0.5) / sz.x * _map_rect.size.x, (z + sz.y * 0.5) / sz.y * _map_rect.size.y)


func _m_per_px() -> float:
	var shell := _shell()
	var sz := ShellStore.size_of(shell)
	if sz.x <= 0.0 or _map_rect.size.x <= 0.0:
		return 1.0
	return sz.x / _map_rect.size.x


# ===========================================================================
# 绘制
# ===========================================================================
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeKit.CARD_DEEP)
	draw_rect(Rect2(Vector2.ZERO, size), ThemeKit.STROKE, false, 1.0)
	var shell := _shell()
	if shell.is_empty():
		draw_string(_font, Vector2(PAD, PAD + 18.0), _t("editor.shell.missing"), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ThemeKit.TEXT_DIM)
		return
	_map_rect = _map_box()
	draw_rect(_map_rect, Color("#161B26"))
	_draw_grid()
	_draw_regions(shell)
	_draw_lane(shell)
	_draw_tiles(shell)
	_draw_axis_hint(shell)


func _draw_grid() -> void:
	var step: float = 10.0
	var shell: Dictionary = _shell()
	var sz: Vector2 = ShellStore.size_of(shell)
	var x: float = -floor(sz.x * 0.5 / step) * step
	while x <= sz.x * 0.5:
		draw_line(_to_px(x, -sz.y * 0.5), _to_px(x, sz.y * 0.5), Color(0.19, 0.23, 0.31, 0.45), 1.0)
		x += step
	var z: float = -floor(sz.y * 0.5 / step) * step
	while z <= sz.y * 0.5:
		draw_line(_to_px(-sz.x * 0.5, z), _to_px(sz.x * 0.5, z), Color(0.19, 0.23, 0.31, 0.45), 1.0)
		z += step


## 三块势力区域：填充 + 贴边描边（多边形就是唯一分区口径，不再画赛道圆环）
func _draw_regions(shell: Dictionary) -> void:
	for kind in ShellStore.REGION_IDS:
		var pts := ShellStore.region_points(shell, kind)
		if pts.size() < 3:
			continue
		var poly := PackedVector2Array()
		for p in pts:
			poly.append(_to_px(p.x, p.y))
		var col: Color = ShellStore.REGION_COLORS.get(kind, Color.WHITE)
		draw_colored_polygon(poly, Color(col.r, col.g, col.b, 0.10))
		var outline := poly.duplicate()
		outline.append(poly[0])
		draw_polyline(outline, Color(col.r, col.g, col.b, 0.75), 1.4)
		var c := ShellStore.region_centroid(pts)
		var label := _t(ShellStore.REGION_KEYS.get(kind, kind))
		draw_string(_font, _to_px(c.x, c.y) + Vector2(-50.0, -4.0), label, HORIZONTAL_ALIGNMENT_CENTER, 100.0, 10,
			Color(col.r, col.g, col.b, 0.9))


func _ribbon_polygon(shell: Dictionary, t0: int, t1: int, half_w: float) -> PackedVector2Array:
	var left: Array = []
	var right: Array = []
	var steps := 24
	for i in steps + 1:
		var t := int(round(lerpf(float(t0), float(t1), float(i) / float(steps))))
		var p := ShellStore.point_at_t(shell, t)
		var d := ShellStore.direction_at_t(shell, t)
		var n := Vector2(-d.y, d.x)
		left.append(_to_px(p.x + n.x * half_w, p.y + n.y * half_w))
		right.append(_to_px(p.x - n.x * half_w, p.y - n.y * half_w))
	var poly := PackedVector2Array()
	for p2 in left:
		poly.append(p2)
	right.reverse()
	for p3 in right:
		poly.append(p3)
	return poly


func _draw_lane(shell: Dictionary) -> void:
	var width_m := float((shell.get("spine", {}) as Dictionary).get("width_logic", 420.0)) * ShellStore.R1
	var spine_poly := _ribbon_polygon(shell, 0, 999, maxf(width_m * 0.5, 0.4))
	if spine_poly.size() >= 3:
		draw_colored_polygon(spine_poly, Color(0.94, 0.78, 0.42, 0.12))
		var outline := spine_poly.duplicate()
		outline.append(spine_poly[0])
		draw_polyline(outline, Color(0.78, 0.64, 0.30, 0.75), 1.4)


## 战术格子：旋转矩形 + 左上角建筑位小方点 + 中心出兵位圆点。
func _draw_tiles(shell: Dictionary) -> void:
	var layout := _layout()
	var enc := _encounter()
	var enemy_rows := {}
	for row in (enc.get("tile_buildings", []) as Array):
		enemy_rows[int((row as Dictionary).get("tile", -1))] = row
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		var idx := int(td.get("index", 0))
		var side := String(td.get("side", "player"))
		var role := String(td.get("role", "build"))
		var corners := ShellStore.tile_corners(td)
		var poly := PackedVector2Array()
		for c in corners:
			poly.append(_to_px(c.x, c.y))
		var active := ShellStore.is_active(layout, idx) if mode == "layout" else true
		var dimmed := mode == "encounter" and side != "enemy"
		var col: Color = ShellStore.REGION_COLORS.get(side, Color.WHITE)
		if role == "keep":
			col = Color("#F0B95A")
		if dimmed:
			col = Color(0.35, 0.40, 0.50)
		var fill_a := 0.30 if active and not dimmed else 0.12
		if mode == "encounter" and enemy_rows.has(idx):
			fill_a = 0.45
		draw_colored_polygon(poly, Color(col.r, col.g, col.b, fill_a))
		var outline := poly.duplicate()
		outline.append(poly[0])
		draw_polyline(outline, Color(col.r, col.g, col.b, 0.9 if active else 0.4), 1.6)
		# 左上角 = 建筑位（与 Model 的定义一致）；中心 = 出兵位
		var bl := _to_px(corners[0].x, corners[0].y)
		draw_rect(Rect2(bl - Vector2(2.5, 2.5), Vector2(5.0, 5.0)), Color(0.94, 0.78, 0.42, 0.95), true)
		var center := _to_px(float(td.get("x", 0.0)), float(td.get("z", 0.0)))
		draw_circle(center, 2.6, Color(0.27, 0.84, 0.64, 0.95))
		# 索引
		draw_string(_mono, center + Vector2(-14.0, -6.0), str(idx), HORIZONTAL_ALIGNMENT_CENTER, 28.0, 10,
			Color(0.93, 0.96, 1.0, 1.0) if active else Color(0.55, 0.60, 0.70))
		if mode == "layout" and not active and not dimmed:
			var k := 4.0
			draw_line(center + Vector2(-k, -k), center + Vector2(k, k), Color(0.55, 0.60, 0.70, 0.8), 1.2)
			draw_line(center + Vector2(-k, k), center + Vector2(k, -k), Color(0.55, 0.60, 0.70, 0.8), 1.2)
		if mode == "encounter" and enemy_rows.has(idx):
			var row2: Dictionary = enemy_rows[idx]
			var bname := String(data.call("building_display", String(row2.get("building", ""))))
			var radius := maxf(float(td.get("w", 6.0)) * 0.5 / _m_per_px(), 8.0)
			draw_string(_font, center + Vector2(-radius * 2.0, radius + 12.0), bname, HORIZONTAL_ALIGNMENT_CENTER, radius * 4.0, 10, Color(0.95, 0.85, 0.65))
		if idx == selected or idx == _hover:
			draw_arc(center, maxf(float(td.get("w", 6.0)) * 0.55 / _m_per_px(), 10.0), 0.0, TAU, 32, Color(0.97, 0.97, 1.0, 0.9), 1.4)


func _draw_axis_hint(shell: Dictionary) -> void:
	var sz := ShellStore.size_of(shell)
	var left := _to_px(-sz.x * 0.5, sz.y * 0.5) + Vector2(6.0, 14.0)
	draw_string(_font, left, _t("editor.layouts.player_side"), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ThemeKit.ACCENT)
	var right := _to_px(sz.x * 0.5, sz.y * 0.5) + Vector2(-86.0, 14.0)
	draw_string(_font, right, _t("editor.layouts.enemy_side"), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ThemeKit.RED)


# ===========================================================================
# 交互
# ===========================================================================
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _hit((event as InputEventMouseMotion).position)
		if hit != _hover:
			_hover = hit
			queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var idx := _hit(mb.position)
			if idx >= 0:
				selected = idx
				tile_clicked.emit(idx)
				queue_redraw()
				accept_event()


func _hit(pos: Vector2) -> int:
	var shell := _shell()
	if shell.is_empty():
		return -1
	var best := -1
	var best_d := 22.0
	for t in ShellStore.tiles(shell):
		var td: Dictionary = t
		var center := _to_px(float(td.get("x", 0.0)), float(td.get("z", 0.0)))
		var d := center.distance_to(pos)
		if d < best_d:
			best_d = d
			best = int(td.get("index", -1))
	return best
