extends Node3D
## 职责：只读 Model 快照，渲染每支小队的成员（统一胶囊体 + 阵营色）、脊线、战术格子、
##       选中圈、指令落点、集火连线。不持有任何玩法状态。
## 属于：Screens/world/squad（表现层）
##
## 口径：
##   · 成员位置/朝向/血量全部来自 `SquadView`（世界米），这里不做任何插值以外的事；
##   · 表现层不判断"谁能打谁"——集火线只画 Model 给的 target_squad；
##   · 不造新美术：成员 = CapsuleMesh，阵营用颜色区分（蓝=我方，红=敌方）。

const MEMBER_CAP := 4096
const PLAYER_COLOR := Color(0.24, 0.48, 0.9)
const ENEMY_COLOR := Color(0.86, 0.26, 0.2)
const RIDGE_COLOR := Color(0.86, 0.72, 0.36, 0.9)
const TILE_COLOR := Color(0.55, 0.6, 0.66, 0.5)
const ZONE_PLAYER := Color(0.36, 0.62, 0.95, 0.55)
const ZONE_ENEMY := Color(0.92, 0.42, 0.34, 0.55)
const SELECT_COLOR := Color(0.95, 0.98, 0.9, 0.95)
const ORDER_COLOR := Color(0.98, 0.82, 0.34, 0.95)
const FOCUS_COLOR := Color(0.95, 0.3, 0.25, 0.9)

## 当前正在写的 ImmediateMesh（静态地形线 / 动态选中线共用同一套画线函数）
var _pen: ImmediateMesh = null

var _mm: MultiMesh
var _multimesh: MultiMeshInstance3D
var _static_mesh: ImmediateMesh
var _dynamic_mesh: ImmediateMesh
var _arena: Dictionary = {}
var _view: Dictionary = {}
var _selected: Array = []
var _order_point := Vector3.ZERO
var _has_order := false


func _ready() -> void:
	_build_multimesh()
	_build_lines()
	if not _arena.is_empty():
		_rebuild_static()


func _build_multimesh() -> void:
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.28
	capsule.height = 1.15
	capsule.radial_segments = 6
	capsule.rings = 2
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	capsule.material = mat

	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = capsule
	_mm.instance_count = MEMBER_CAP
	_mm.visible_instance_count = 0

	_multimesh = MultiMeshInstance3D.new()
	_multimesh.name = "Members"
	_multimesh.multimesh = _mm
	add_child(_multimesh)


func _build_lines() -> void:
	_static_mesh = ImmediateMesh.new()
	var static_node := MeshInstance3D.new()
	static_node.name = "TerrainLines"
	static_node.mesh = _static_mesh
	static_node.material_override = _line_material()
	add_child(static_node)

	_dynamic_mesh = ImmediateMesh.new()
	var dynamic_node := MeshInstance3D.new()
	dynamic_node.name = "SelectionLines"
	dynamic_node.mesh = _dynamic_mesh
	dynamic_node.material_override = _line_material()
	add_child(dynamic_node)


func _line_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## 战场几何（格子 / 脊线 / 势力区 / 基地圈）——只在地图变化时重建。
func set_arena(arena: Dictionary) -> void:
	_arena = arena
	if _static_mesh != null:
		_rebuild_static()


func _rebuild_static() -> void:
	_static_mesh.clear_surfaces()
	_pen = _static_mesh
	if _arena.is_empty():
		return
	_static_mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	var ridge: Array = _arena.get("ridge", [])
	for i in range(0, maxi(ridge.size() - 1, 0)):
		var a: Dictionary = ridge[i]
		var b: Dictionary = ridge[i + 1]
		_line(Vector3(float(a.get("x", 0.0)), 0.05, float(a.get("z", 0.0))),
			Vector3(float(b.get("x", 0.0)), 0.05, float(b.get("z", 0.0))), RIDGE_COLOR)

	for t in _arena.get("tiles", []):
		var tile: Dictionary = t
		_rect(float(tile.get("x", 0.0)), float(tile.get("z", 0.0)),
			float(tile.get("w", 4.0)), float(tile.get("d", 4.0)),
			float(tile.get("yaw", 0.0)), TILE_COLOR)
		var spawn := Vector3(float(tile.get("spawn_x", 0.0)), 0.06, float(tile.get("spawn_z", 0.0)))
		_cross(spawn, 0.55, TILE_COLOR)

	var min_x := float(_arena.get("min_x", -60.0))
	var max_x := float(_arena.get("max_x", 60.0))
	var min_z := float(_arena.get("min_z", -31.5))
	var max_z := float(_arena.get("max_z", 31.5))
	_line(Vector3(float(_arena.get("player_zone_x", min_x)), 0.04, min_z),
		Vector3(float(_arena.get("player_zone_x", min_x)), 0.04, max_z), ZONE_PLAYER)
	_line(Vector3(float(_arena.get("enemy_zone_x", max_x)), 0.04, min_z),
		Vector3(float(_arena.get("enemy_zone_x", max_x)), 0.04, max_z), ZONE_ENEMY)

	_ring(Vector3(float(_arena.get("player_base_x", 0.0)), 0.05, float(_arena.get("player_base_z", 0.0))),
		2.6, PLAYER_COLOR)
	_ring(Vector3(float(_arena.get("enemy_base_x", 0.0)), 0.05, float(_arena.get("enemy_base_z", 0.0))),
		2.6, ENEMY_COLOR)

	_pen = null
	_static_mesh.surface_end()


## 每帧：成员实例 + 选中圈 + 指令标记（全部来自 Model 快照）。
func update_view(view: Dictionary, selected: Array, order_point: Vector3, has_order: bool) -> void:
	if _mm == null:
		return
	_view = view
	_selected = selected
	_order_point = order_point
	_has_order = has_order

	var idx := 0
	var squads: Array = view.get("squads", [])
	for s in squads:
		var sq: Dictionary = s
		var side := int(sq.get("side", 0))
		var base_color := PLAYER_COLOR if side == 0 else ENEMY_COLOR
		var is_selected := selected.has(int(sq.get("id", 0)))
		if is_selected:
			base_color = base_color.lightened(0.28)
		for m in sq.get("members", []):
			if idx >= MEMBER_CAP:
				break
			var mem: Dictionary = m
			if not bool(mem.get("alive", false)):
				continue
			var pos := Vector3(float(mem.get("x", 0.0)), 0.58, float(mem.get("z", 0.0)))
			_mm.set_instance_transform(idx, Transform3D(Basis(), pos))
			_mm.set_instance_color(idx, base_color)
			idx += 1
	_mm.visible_instance_count = idx

	_draw_dynamic()


func _draw_dynamic() -> void:
	_dynamic_mesh.clear_surfaces()
	_pen = _dynamic_mesh
	_dynamic_mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	var by_id := {}
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		by_id[int(sq.get("id", 0))] = sq

	for id in _selected:
		var sq: Dictionary = by_id.get(int(id), {})
		if sq.is_empty():
			continue
		var center := Vector3(float(sq.get("x", 0.0)), 0.07, float(sq.get("z", 0.0)))
		var radius := float(sq.get("radius", 1.5)) + 0.35
		_ring(center, radius, SELECT_COLOR)
		var target := int(sq.get("target_squad", -1))
		if target > 0 and by_id.has(target):
			var t: Dictionary = by_id[target]
			var tp := Vector3(float(t.get("x", 0.0)), 0.07, float(t.get("z", 0.0)))
			_line(center + Vector3(0, 0.02, 0), tp, FOCUS_COLOR)
			_ring(tp, float(t.get("radius", 1.5)) + 0.5, FOCUS_COLOR)

	if _has_order:
		_cross(_order_point + Vector3(0, 0.07, 0), 0.85, ORDER_COLOR)
		_ring(_order_point + Vector3(0, 0.07, 0), 0.7, ORDER_COLOR)

	_pen = null
	_dynamic_mesh.surface_end()


# --- 画线小工具（ImmediateMesh 的 PRIMITIVE_LINES）----------------------------
func _line(a: Vector3, b: Vector3, color: Color) -> void:
	if _pen == null:
		return
	_pen.surface_set_color(color)
	_pen.surface_add_vertex(a)
	_pen.surface_add_vertex(b)


func _rect(x: float, z: float, w: float, d: float, yaw_deg: float, color: Color) -> void:
	var hw := w * 0.5
	var hd := d * 0.5
	var yaw := deg_to_rad(yaw_deg)
	var c := cos(yaw)
	var s := sin(yaw)
	var pts: Array[Vector3] = [
		Vector3(-hw, 0.0, -hd), Vector3(hw, 0.0, -hd),
		Vector3(hw, 0.0, hd), Vector3(-hw, 0.0, hd),
	]
	for i in 4:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % 4]
		var wa := Vector3(x + a.x * c + a.z * s, 0.04, z - a.x * s + a.z * c)
		var wb := Vector3(x + b.x * c + b.z * s, 0.04, z - b.x * s + b.z * c)
		_line(wa, wb, color)


func _cross(center: Vector3, size: float, color: Color) -> void:
	_line(center + Vector3(-size, 0, 0), center + Vector3(size, 0, 0), color)
	_line(center + Vector3(0, 0, -size), center + Vector3(0, 0, size), color)


func _ring(center: Vector3, radius: float, color: Color) -> void:
	var segments := 24
	for i in segments:
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var p0 := center + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		_line(p0, p1, color)
