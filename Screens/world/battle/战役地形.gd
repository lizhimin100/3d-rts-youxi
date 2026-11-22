extends Node3D
## 职责：用底壳的 `terrain.heights` + `surface.palette` 生成**真实地形网格**（顶面 + 土层侧壁 + 底面），
##       再把 `decorations` 里的树/岩石实例化成既有资产（`RtsDecorLib`），并对外提供 `height_at()`。
## 属于：Screens/world/battle（表现层）
##
## 为什么不铺一张单面平板再涂个颜色：那正是"色块占位"。底壳本来就有 1.5m 的高度场与
## 地表调色板，这里把它按编辑器同一套绕序/坡度明暗画出来，局内看到的和编辑器里看到的是同一块地。
##
## 三个区靠**地表色带**区分（草地 / 泥土 / 沙地 / 岩石），不是靠三块不同颜色的板子。

const THICK := 6.0          # 土层厚度（米）；只影响观感，不参与任何判定
const SKIRT := 0.0

var _shell: Dictionary = {}
var _heights := PackedFloat32Array()
var _surface: Array = []
var _cell := 1.5
var _cols := 0
var _rows := 0
var _ox := 0.0
var _oz := 0.0
var _palette: Array = []


func build(shell: Dictionary) -> void:
	_shell = shell
	var size: Dictionary = shell.get("size", {})
	var sx := float(size.get("x", 120.0))
	var sz := float(size.get("z", 63.0))
	var terr: Dictionary = shell.get("terrain", {})
	_cell = maxf(float(terr.get("cell", 1.5)), 0.5)
	_cols = int(round(sx / _cell)) + 1
	_rows = int(round(sz / _cell)) + 1
	_ox = -sx * 0.5
	_oz = -sz * 0.5
	_palette = (shell.get("surface", {}) as Dictionary).get("palette", [])
	_surface = (shell.get("surface", {}) as Dictionary).get("index", [])

	_heights = PackedFloat32Array()
	var raw: Array = terr.get("heights", [])
	if raw.size() == _cols * _rows:
		_heights.resize(raw.size())
		for i in raw.size():
			_heights[i] = float(raw[i])
	else:
		# 数据对不上就铺平（绝不因为高度场缺一块而黑屏）
		_heights.resize(_cols * _rows)
		_heights.fill(1.0)

	_build_mesh()
	_build_decor()


# ===========================================================================
# 高度查询（双线性，与 ShellStore.height_at_shell 同一套）
# ===========================================================================
func height_at(x: float, z: float) -> float:
	if _heights.is_empty():
		return 0.0
	var fx := clampf((x - _ox) / _cell, 0.0, float(_cols - 1))
	var fz := clampf((z - _oz) / _cell, 0.0, float(_rows - 1))
	var c0 := int(floor(fx))
	var r0 := int(floor(fz))
	var c1 := mini(c0 + 1, _cols - 1)
	var r1 := mini(r0 + 1, _rows - 1)
	var tx := fx - float(c0)
	var tz := fz - float(r0)
	var a := lerpf(_heights[r0 * _cols + c0], _heights[r0 * _cols + c1], tx)
	var b := lerpf(_heights[r1 * _cols + c0], _heights[r1 * _cols + c1], tx)
	return lerpf(a, b, tz)


# ===========================================================================
# 网格
# ===========================================================================
func _build_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var verts := PackedVector3Array()
	verts.resize(_cols * _rows)
	for r in _rows:
		for c in _cols:
			var i := r * _cols + c
			verts[i] = Vector3(_ox + float(c) * _cell, _heights[i], _oz + float(r) * _cell)

	for r in _rows - 1:
		for c in _cols - 1:
			var a := r * _cols + c
			var b := a + 1
			var cc := a + _cols
			var d := cc + 1
			# 每个小四边形按自己的两格地表色取平均，形成"色带"而不是色块
			var col := _cell_color(c, r, verts)
			_tri(st, verts[a], verts[b], verts[cc], col)
			_tri(st, verts[b], verts[d], verts[cc], col)

	# 土层侧壁：沿四边把顶面接到 base 平面
	var base_y := _hmin() - THICK
	for c in _cols - 1:
		_wall(st, verts[c], verts[c + 1], base_y)
		var top := (_rows - 1) * _cols
		_wall(st, verts[top + c + 1], verts[top + c], base_y)
	for r in _rows - 1:
		_wall(st, verts[(r + 1) * _cols], verts[r * _cols], base_y)
		_wall(st, verts[r * _cols + _cols - 1], verts[(r + 1) * _cols + _cols - 1], base_y)

	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.metallic = 0.0
	# 顶点色已经带坡度明暗；再开一点细节缩放，避免大面积死平
	m.uv1_scale = Vector3(0.08, 0.08, 1.0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	add_child(mi)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	# 绕序不可靠时让引擎自己算：这里显式给一个朝上的法线，保证大地不会从下面被打亮
	var n := (b - a).cross(c - a).normalized()
	if n.y < 0.0:
		n = -n
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(a)
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(c)


func _wall(st: SurfaceTool, top_a: Vector3, top_b: Vector3, base_y: float) -> void:
	var col := Color(0.30, 0.26, 0.21).srgb_to_linear()
	var a := top_a
	var b := top_b
	var ad := Vector3(a.x, base_y, a.z)
	var bd := Vector3(b.x, base_y, b.z)
	_tri(st, a, b, bd, col)
	_tri(st, a, bd, ad, col)


func _hmin() -> float:
	var v := 1e9
	for h in _heights:
		v = minf(v, h)
	return 0.0 if v > 1e8 else v


## 一小块地的颜色：地表调色板 + 坡度压暗 + 轻微噪声（读起来像地形，不像色块）
func _cell_color(c: int, r: int, verts: PackedVector3Array) -> Color:
	var i := r * _cols + c
	var idx := 0
	if i < _surface.size():
		idx = int(_surface[i])
	var base := Color(0.42, 0.46, 0.30)
	if idx >= 0 and idx < _palette.size():
		var p: Dictionary = _palette[idx]
		# 调色板写的是 sRGB；顶点色在 Godot 里按线性解释，必须换算
		base = Color(String(p.get("color", "#5D6B3F"))).srgb_to_linear()
	# 坡度：法线近似（东西/南北高度差）
	var hl := verts[r * _cols + maxi(c - 1, 0)].y
	var hr := verts[r * _cols + mini(c + 1, _cols - 1)].y
	var hd := verts[maxi(r - 1, 0) * _cols + c].y
	var hu := verts[mini(r + 1, _rows - 1) * _cols + c].y
	var slope := clampf((absf(hr - hl) + absf(hu - hd)) / (_cell * 2.0) * 2.2, 0.0, 0.55)
	base = base.darkened(slope)
	# 极轻微的棋盘噪声，让同一色带不至于完全一致
	var noise := float((c * 73856093) ^ (r * 19349663)) / 4294967296.0
	return base.lightened(0.04 * noise)


# ===========================================================================
# 装饰
# ===========================================================================
func _build_decor() -> void:
	var holder := Node3D.new()
	holder.name = "Decor"
	add_child(holder)
	for d in _shell.get("decorations", []):
		var row: Dictionary = d
		var kind := String(row.get("kind", "tree"))
		var n := RtsDecorLib.instantiate(StringName(kind), holder)
		if n == null:
			continue
		var x := float(row.get("x", 0.0))
		var z := float(row.get("z", 0.0))
		# y 用高度场重新采样（数据里的 y 可能来自别的尺寸）
		n.position = Vector3(x, height_at(x, z), z)
		n.rotation.y = deg_to_rad(float(row.get("yaw", 0.0)))
		var s := float(row.get("scale", 1.0))
		n.scale = Vector3(s, s, s)
