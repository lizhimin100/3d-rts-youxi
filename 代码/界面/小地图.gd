class_name RtsMinimap
extends Control
## **小地图（HAWKEYE）**
##
## 全自定义 `_draw`（文档 §8）：地形底色 + 金矿/树木点 + 双方单位点 + 当前视野框。
## 左键点击/拖动 → 镜头平滑飞过去（走 RtsCamera.focus_on）。
##
## 性能纪律：地形底图**只烘一次**成 ImageTexture；每帧只重画几十个点，
## 重绘频率压到 10Hz（0.1 秒），不跟着渲染帧空转。

## 重绘间隔（秒）
const REFRESH_INTERVAL := 0.1

## 世界边长（没关卡时从 Cfg 取）
var world_size: float = 116.0

## 地形底图（第一次绘制时烘出来）
var _terrain_tex: ImageTexture = null
var _terrain_built: bool = false

## 重绘计时
var _clock: float = 0.0

## 左键拖动中
var _dragging: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func _process(delta: float) -> void:
	_clock += delta
	if _clock < REFRESH_INTERVAL:
		return
	_clock = 0.0
	_sync_world_size()
	queue_redraw()


## 世界尺寸跟着关卡（关卡没建好就用配置）
func _sync_world_size() -> void:
	var lv := Game.level as RtsLevel
	if lv != null:
		world_size = lv.world_size
	elif Cfg.game != null:
		world_size = Cfg.game.map_size


# ===========================================================================
# 绘制
# ===========================================================================

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if r.size.x <= 1.0 or r.size.y <= 1.0:
		return

	# --- 底 ---
	draw_rect(r, Color(0.05, 0.06, 0.08, 0.95), true)
	_build_terrain_once()
	if _terrain_tex != null:
		draw_texture_rect(_terrain_tex, r, false)
	else:
		draw_rect(r.grow(-1.0), Color(0.16, 0.22, 0.15, 1.0), true)

	# --- 水面（圆形池塘，画在底图上更准，但这里叠加更省事）---
	var lv := Game.level as RtsLevel
	if lv != null and lv.map_data != null and lv.map_data.pond_radius > 0.0:
		var pc: Vector2 = _world_to_map(Vector3(lv.map_data.pond_center.x, 0.0, lv.map_data.pond_center.y))
		var pr: float = lv.map_data.pond_radius / world_size * r.size.x
		draw_circle(pc, pr, Color(0.18, 0.34, 0.48, 0.85))

	# --- 战术网格：三分线，读起来才像一张"战图"而不是一坨绿 ---
	_draw_grid(r)

	# --- 资源点 ---
	if lv != null and lv.map_data != null:
		var gold := Cfg.game.gold_color if Cfg.game != null else Color(1.0, 0.82, 0.24)
		for m in lv.map_data.mines:
			var mp: Vector2 = _world_to_map(Vector3(m.x, 0.0, m.y))
			draw_rect(Rect2(mp - Vector2(3.2, 3.2), Vector2(6.4, 6.4)), Color(0.0, 0.0, 0.0, 0.62), true)
			draw_rect(Rect2(mp - Vector2(2.2, 2.2), Vector2(4.4, 4.4)), gold, true)
		for t in lv.map_data.trees:
			var tp: Vector2 = _world_to_map(Vector3(t.x, 0.0, t.y))
			draw_rect(Rect2(tp - Vector2(1.5, 1.5), Vector2(3.0, 3.0)), Color(0.10, 0.24, 0.11, 0.9), true)

	# --- 单位/建筑 ---
	var pl := Game.player_faction
	var pl_color: Color = Cfg.game.player_color if Cfg.game != null else Color(0.3, 0.62, 1.0)
	var en_color: Color = Cfg.game.enemy_color if Cfg.game != null else Color(1.0, 0.32, 0.26)
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var n := u as Node3D
		if n == null:
			continue
		if n is RtsUnit and not (n as RtsUnit).is_alive():
			continue
		var col := pl_color
		if n is RtsUnit:
			var f: RtsFaction = (n as RtsUnit).faction
			if f != null and f != pl:
				col = en_color
		var p: Vector2 = _world_to_map(n.global_position)
		var half: float = 2.6 if n is RtsBuilding else 1.7
		# 每个点先铺一圈 1px 黑影：亮底/暗底上都咬得住
		draw_rect(Rect2(p - Vector2(half + 0.9, half + 0.9), Vector2((half + 0.9) * 2.0, (half + 0.9) * 2.0)),
				Color(0.0, 0.0, 0.0, 0.55), true)
		draw_rect(Rect2(p - Vector2(half, half), Vector2(half * 2.0, half * 2.0)), col, true)
		# 选中：外面再套一圈白框（一眼看出"我选的是哪几个点"）
		if n is RtsUnit and (n as RtsUnit).is_selected:
			draw_rect(Rect2(p - Vector2(half + 1.8, half + 1.8),
					Vector2((half + 1.8) * 2.0, (half + 1.8) * 2.0)),
					Color(1.0, 1.0, 1.0, 0.92), false, 1.0)

	# --- 当前视野框 ---
	var view_poly := _view_polygon()
	if view_poly.size() >= 3:
		draw_colored_polygon(view_poly, Color(1.0, 1.0, 1.0, 0.05))
		var closed := view_poly.duplicate()
		closed.append(view_poly[0])
		draw_polyline(closed, Color(1.0, 1.0, 1.0, 0.55), 1.2)

	# --- 内暗角 / 外框 / 取景角 ---
	draw_rect(r, Color(0.0, 0.0, 0.0, 0.30), false, 3.0)
	var acc := _accent()
	draw_rect(r.grow(-0.5), Color(acc.r, acc.g, acc.b, 0.26), false, 1.0)
	_draw_brackets(r, acc)


## 三分网格（只在内部画，别压到边）
func _draw_grid(r: Rect2) -> void:
	var line := Color(1.0, 1.0, 1.0, 0.07)
	for i in [1, 2, 3]:
		var t: float = float(i) / 4.0
		draw_line(Vector2(r.size.x * t, 1.0), Vector2(r.size.x * t, r.size.y - 1.0), line, 1.0)
		draw_line(Vector2(1.0, r.size.y * t), Vector2(r.size.x - 1.0, r.size.y * t), line, 1.0)


## 四角取景角（比一圈死边框有设计感）
func _draw_brackets(r: Rect2, col: Color) -> void:
	var c := Color(col.r, col.g, col.b, 0.9)
	var arm: float = 14.0
	var t: float = 2.0
	# 左上
	draw_rect(Rect2(0.0, 0.0, arm, t), c, true)
	draw_rect(Rect2(0.0, 0.0, t, arm), c, true)
	# 右上
	draw_rect(Rect2(r.size.x - arm, 0.0, arm, t), c, true)
	draw_rect(Rect2(r.size.x - t, 0.0, t, arm), c, true)
	# 左下
	draw_rect(Rect2(0.0, r.size.y - t, arm, t), c, true)
	draw_rect(Rect2(0.0, r.size.y - arm, t, arm), c, true)
	# 右下
	draw_rect(Rect2(r.size.x - arm, r.size.y - t, arm, t), c, true)
	draw_rect(Rect2(r.size.x - t, r.size.y - arm, t, arm), c, true)


## 主色
func _accent() -> Color:
	return Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)


## 地形底图：把 MapData 的高度场烘成一张 (res+1)² 的贴图
func _build_terrain_once() -> void:
	if _terrain_built:
		return
	var lv := Game.level as RtsLevel
	if lv == null or lv.map_data == null:
		return  # 关卡还没建好，下一帧再试
	var md := lv.map_data
	var res: int = maxi(md.resolution, 2)
	var row: int = res + 1
	if md.heights.size() < row * row:
		return

	var bytes := PackedByteArray()
	bytes.resize(row * row * 4)
	for z in range(row):
		for x in range(row):
			var h: float = md.heights[z * row + x]
			var c := _height_color(h)
			var i: int = (z * row + x) * 4
			bytes[i] = int(clampf(c.r, 0.0, 1.0) * 255.0)
			bytes[i + 1] = int(clampf(c.g, 0.0, 1.0) * 255.0)
			bytes[i + 2] = int(clampf(c.b, 0.0, 1.0) * 255.0)
			bytes[i + 3] = 255
	var img := Image.create_from_data(row, row, false, Image.FORMAT_RGBA8, bytes)
	_terrain_tex = ImageTexture.create_from_image(img)
	_terrain_built = true


## 高度 → 小地图片色（低=深绿，高=土黄/灰白）
func _height_color(h: float) -> Color:
	var low := Color(0.13, 0.22, 0.12)
	var mid := Color(0.24, 0.36, 0.17)
	var high := Color(0.42, 0.38, 0.24)
	var peak := Color(0.55, 0.54, 0.50)
	var t: float = clampf((h + 0.6) / 3.0, 0.0, 1.0)
	if t < 0.5:
		return low.lerp(mid, t * 2.0)
	if t < 0.85:
		return mid.lerp(high, (t - 0.5) / 0.35)
	return high.lerp(peak, (t - 0.85) / 0.15)


## 视野框：把屏幕四角打到地面，再映射到小地图（四点组成的梯形）
func _view_polygon() -> PackedVector2Array:
	var out := PackedVector2Array()
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return out
	var vsize: Vector2 = get_viewport().get_visible_rect().size
	var corners: Array = [
		Vector2(0.0, 0.0), Vector2(vsize.x, 0.0),
		Vector2(vsize.x, vsize.y), Vector2(0.0, vsize.y),
	]
	var cam_node := cam.get_parent()
	for c in corners:
		var w: Vector3
		if cam_node != null and cam_node.has_method("ray_ground"):
			w = cam_node.call("ray_ground", cam.project_ray_origin(c), cam.project_ray_normal(c))
		else:
			var ro: Vector3 = cam.project_ray_origin(c)
			var rd: Vector3 = cam.project_ray_normal(c)
			if absf(rd.y) < 0.0001:
				return PackedVector2Array()
			var t: float = (0.0 - ro.y) / rd.y
			if t < 0.0:
				return PackedVector2Array()
			w = ro + rd * t
		out.append(_world_to_map(w))
	return out


# ===========================================================================
# 坐标 / 交互
# ===========================================================================

## 世界坐标 → 小地图局部坐标
func _world_to_map(p: Vector3) -> Vector2:
	var half: float = world_size * 0.5
	var u: float = (p.x + half) / world_size
	var v: float = (p.z + half) / world_size
	return Vector2(u * size.x, v * size.y)


## 小地图局部坐标 → 世界坐标（地面 y=0 附近，镜头自己会贴地）
func _map_to_world(p: Vector2) -> Vector3:
	if size.x <= 0.0 or size.y <= 0.0:
		return Vector3.ZERO
	var half: float = world_size * 0.5
	var x: float = (p.x / size.x) * world_size - half
	var z: float = (p.y / size.y) * world_size - half
	return Vector3(x, 0.0, z)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				_focus_at(mb.position)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_focus_at(mm.position)
		accept_event()


## 点小地图 → 镜头飞过去
func _focus_at(local_pos: Vector2) -> void:
	var target := _map_to_world(local_pos)
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	var cam_node := cam.get_parent()
	if cam_node != null and cam_node.has_method("focus_on"):
		cam_node.call("focus_on", target)
