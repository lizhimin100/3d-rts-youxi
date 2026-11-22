extends Node3D
## 职责：把底壳的战术格子画成**能看懂的棋盘**——玩家区 3 列 × 6 行 PvZ 双色微差格、
##       中立据点格、敌方格、主堡格，以及格子的两个标准锚点（左上角建筑位 / 正中心出兵位）。
## 属于：Screens/world/battle（表现层）
##
## 纪律：
##   · 格子位置/尺寸/贴地高度全部来自 `SquadArena`（世界米），这里不重算锚点；
##     两个锚点直接用桥给的 `building_x/z` 与 `spawn_x/z`（唯一实现在 TacticalTile.cs）；
##   · 颜色来自 `map_shells.json` 的 `board.theme`（可换皮）；这里不接受写死色值调用；
##   · 只画几何，不做任何"这格能不能建"的判断 —— 那是 Model 的 FreePlayerTiles()。

const THICK := 0.16          # 格子厚度（米）
const RIM := 0.10            # 边框宽度（米）
const LIFT := 0.02           # 抬高一点，压住地形 z-fighting

var _slab: MeshInstance3D = null
var _marks: MeshInstance3D = null
var _highlight: MeshInstance3D = null
var _arena: Dictionary = {}
var _theme: Dictionary = {}
var _free_tiles: Array = []
var _armed := false
var _hover := 0
var _dirty_marks := true


func _ready() -> void:
	_slab = _make_mesh_node("Tiles")
	_marks = _make_mesh_node("Anchors")
	_highlight = _make_mesh_node("Highlight")


func _make_mesh_node(n: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _line_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ===========================================================================
# 装配
# ===========================================================================
func set_arena(arena: Dictionary, theme: Dictionary) -> void:
	_arena = arena
	_theme = theme
	_rebuild()


## 玩家已打出建造牌、正在选格子：高亮所有空格子。
func set_armed(armed: bool, free_tiles: Array) -> void:
	_armed = armed
	_free_tiles = free_tiles
	_rebuild_highlight()


func set_hover_tile(index: int) -> void:
	if _hover == index:
		return
	_hover = index
	if _armed:
		_rebuild_highlight()


func _rebuild() -> void:
	if _slab == null:
		return
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tiles: Array = _arena.get("tiles", [])
	# 双色微差：按 X / Z 各自排序后的下标奇偶决定深浅（换皮只改 theme）
	var xs := _unique_sorted(tiles, "x")
	var zs := _unique_sorted(tiles, "z")
	for t in tiles:
		var tile: Dictionary = t
		var side := String(tile.get("side", "player"))
		var role := String(tile.get("role", "build"))
		var ci := xs.find(snappedf(float(tile.get("x", 0.0)), 0.01))
		var ri := zs.find(snappedf(float(tile.get("z", 0.0)), 0.01))
		var even := ((ci + ri) % 2) == 0
		var top := _top_color(side, role, even)
		var edge := _col("edge", Color(0.30, 0.34, 0.24))
		_slab_quad(st, tile, top, edge)
	mesh = st.commit()
	_slab.mesh = mesh
	_slab.material_override = _vertex_mat()
	_rebuild_marks()
	_rebuild_highlight()


func _unique_sorted(tiles: Array, key: String) -> Array:
	var seen := {}
	for t in tiles:
		var v := snappedf(float((t as Dictionary).get(key, 0.0)), 0.01)
		seen[v] = true
	var arr := seen.keys()
	arr.sort()
	return arr


func _col(key: String, fallback: Color) -> Color:
	var v: Variant = _theme.get(key, null)
	if v is Color:
		return (v as Color).srgb_to_linear()
	if v is String and not String(v).is_empty():
		# 顶点色在 Godot 里按**线性**解释；主题里写的是 sRGB，必须换算，否则会白成一片。
		return Color(String(v)).srgb_to_linear()
	return fallback.srgb_to_linear()


func _top_color(side: String, role: String, even: bool) -> Color:
	if role == "keep":
		return _col("keep", Color(0.62, 0.52, 0.34)) if even else _col("keep_dark", Color(0.55, 0.45, 0.29))
	match side:
		"neutral":
			return _col("neutral", Color(0.66, 0.60, 0.42))
		"enemy":
			return _col("enemy", Color(0.52, 0.34, 0.30)) if even else _col("enemy_dark", Color(0.45, 0.29, 0.26))
		_:
			var light := _col("light", Color(0.66, 0.69, 0.48))
			var dark := _col("dark", Color(0.56, 0.60, 0.38))
			return light if even else dark


## 一个格子 = 顶面 + 4 个侧面（厚度），再加一圈略亮的边框
func _slab_quad(st: SurfaceTool, tile: Dictionary, top: Color, edge: Color) -> void:
	var x := float(tile.get("x", 0.0))
	var z := float(tile.get("z", 0.0))
	var y := float(tile.get("terrain_y", 0.0)) + LIFT
	var hw := float(tile.get("w", 4.0)) * 0.5
	var hd := float(tile.get("d", 4.0)) * 0.5
	var yaw := deg_to_rad(float(tile.get("yaw", 0.0)))
	var c := cos(yaw)
	var s := sin(yaw)

	var corners: Array[Vector3] = []
	for pair in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
		var lx: float = float(pair[0]) * hw
		var lz: float = float(pair[1]) * hd
		corners.append(Vector3(x + lx * c + lz * s, y, z - lx * s + lz * c))

	# 顶面：法线显式给 UP（不靠绕序推），材质关掉背面剔除
	_tri(st, corners[0], corners[1], corners[2], top, Vector3.UP)
	_tri(st, corners[0], corners[2], corners[3], top, Vector3.UP)
	# 侧面：从顶面下沉 THICK，法线朝外
	var rim := edge.darkened(0.28)
	for i in 4:
		var a: Vector3 = corners[i]
		var b: Vector3 = corners[(i + 1) % 4]
		var ad := a - Vector3(0.0, THICK, 0.0)
		var bd := b - Vector3(0.0, THICK, 0.0)
		var nrm := Vector3(b.x - a.x, 0.0, b.z - a.z).cross(Vector3.DOWN).normalized()
		_tri(st, a, b, bd, rim, nrm)
		_tri(st, a, bd, ad, rim, nrm)
	# 边框：沿顶面外缘一圈窄条（抬 RIM 高度，读起来像"格线"）
	var inner := 1.0 - (RIM * 2.0 / maxf(hw * 2.0, 0.01))
	var icorners: Array[Vector3] = []
	for pair in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
		var lx: float = float(pair[0]) * hw * inner
		var lz: float = float(pair[1]) * hd * inner
		icorners.append(Vector3(x + lx * c + lz * s, y + 0.004, z - lx * s + lz * c))
	var rim_col := _col("rim", Color(0.78, 0.75, 0.54))
	for i in 4:
		var o0: Vector3 = corners[i]
		var o1: Vector3 = corners[(i + 1) % 4]
		var i0: Vector3 = icorners[i]
		var i1: Vector3 = icorners[(i + 1) % 4]
		_tri(st, o0, o1, i1, rim_col, Vector3.UP)
		_tri(st, o0, i1, i0, rim_col, Vector3.UP)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color,
		normal: Vector3 = Vector3.UP) -> void:
	st.set_color(col)
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_color(col)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_color(col)
	st.set_normal(normal)
	st.add_vertex(c)


## 锚点标记：左上角 = 金色小方（建筑位），正中心 = 阵营色圆环（出兵位）
func _rebuild_marks() -> void:
	if _marks == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var build_col := _col("build_anchor", Color(0.75, 0.54, 0.18))
	var spawn_col := _col("spawn_anchor", Color(0.30, 0.62, 1.0))
	for t in _arena.get("tiles", []):
		var tile: Dictionary = t
		var side := String(tile.get("side", "player"))
		if side == "neutral":
			continue
		var y := float(tile.get("terrain_y", 0.0)) + LIFT + 0.01
		# 建筑位：左上角 0.55m 方块（只有 build 格才有意义）
		if String(tile.get("role", "build")) == "build":
			var bx := float(tile.get("building_x", tile.get("x", 0.0)))
			var bz := float(tile.get("building_z", tile.get("z", 0.0)))
			_flat_rect(st, bx, bz, 0.28, 0.28, y, build_col)
		# 出兵位：正中心圆环
		var sx := float(tile.get("spawn_x", tile.get("x", 0.0)))
		var sz := float(tile.get("spawn_z", tile.get("z", 0.0)))
		_flat_ring(st, sx, sz, 0.62, 0.46, y, spawn_col)
	_marks.mesh = st.commit()
	_marks.material_override = _line_mat()


## 高亮：正在挑格子时，所有空格子亮一圈；鼠标悬停那一格最亮
func _rebuild_highlight() -> void:
	if _highlight == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if _armed:
		var base := Color(0.98, 0.86, 0.44, 0.20)
		var hot := Color(1.0, 0.95, 0.72, 0.42)
		for t in _arena.get("tiles", []):
			var tile: Dictionary = t
			var idx := int(tile.get("index", 0))
			if not _free_tiles.has(idx) and idx != _hover:
				continue
			var y := float(tile.get("terrain_y", 0.0)) + LIFT + 0.012
			var hw := float(tile.get("w", 4.0)) * 0.5
			var hd := float(tile.get("d", 4.0)) * 0.5
			var col := hot if idx == _hover else base
			_flat_rect(st, float(tile.get("x", 0.0)), float(tile.get("z", 0.0)), hw, hd, y, col)
	_highlight.mesh = st.commit()
	_highlight.material_override = _line_mat()


func _flat_rect(st: SurfaceTool, x: float, z: float, hw: float, hd: float, y: float, col: Color) -> void:
	var p0 := Vector3(x - hw, y, z - hd)
	var p1 := Vector3(x + hw, y, z - hd)
	var p2 := Vector3(x + hw, y, z + hd)
	var p3 := Vector3(x - hw, y, z + hd)
	_tri(st, p0, p1, p2, col)
	_tri(st, p0, p2, p3, col)


func _flat_ring(st: SurfaceTool, x: float, z: float, r_out: float, r_in: float, y: float, col: Color) -> void:
	var seg := 20
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var o0 := Vector3(x + cos(a0) * r_out, y, z + sin(a0) * r_out)
		var o1 := Vector3(x + cos(a1) * r_out, y, z + sin(a1) * r_out)
		var i0 := Vector3(x + cos(a0) * r_in, y, z + sin(a0) * r_in)
		var i1 := Vector3(x + cos(a1) * r_in, y, z + sin(a1) * r_in)
		_tri(st, o0, o1, i1, col)
		_tri(st, o0, i1, i0, col)


func _vertex_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.92
	m.metallic = 0.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
