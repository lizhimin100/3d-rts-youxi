extends Node3D
## 职责：底壳高度场 → **真实地形网格**（草地/泥土贴图 + 顶点色染色 + 陡面岩壁）、
##       地块的立体厚度（土层侧壁 + 倒角 + 底面）、以及装饰（树/岩石）的实例化与合批。
## 属于：Screens/world/battle（表现层）
##
## 纪律（2026-11-22 重写，起因见下）：
##   · **地表材质只有一份**：`RtsTerrainAssets` 的 `地形材质.tres`（→ `地形.gdshader`）。
##     上一版这里现 new 了一个 `StandardMaterial3D` 只吃顶点色，等于把美术画的草地/泥土贴图
##     全丢了 —— 局内地面变成纯色塑料布，而编辑器里是好的。现在两边都走同一份材质与同一套参数。
##   · 顶点色只做"乘法染色 + 干度"（口径在 `RtsTerrainAssets.vertex_tint`），配色交给贴图。
##   · 三块战术区是 **Y = 0 的绝对平面**（生成规则在 `ShellStore.terrain_height`，这里只画数据）。
##   · 地块是**有厚度的立体块**：侧壁落到 `min(h) - depth`，顶面沿内法线收 `bevel` 做倒角，
##     再补一张底面封口 —— 从任何角度都不是"薄皮悬浮"。
##   · 装饰只实例化既有资产（`RtsDecorLib`），远景带（auto 行）走 MultiMesh 合批，一手不动模型。

## 侧壁/底面的最终高度兜底（数据里 board.depth 缺失时用）
## 允许合批的装饰种类（合批材质带贴图的那几种；见 装饰库._batch_material）
const BATCHABLE := ["grass", "rubble"]
const DEPTH_FALLBACK := 6.0
const BEVEL_FALLBACK := 0.35

var _shell: Dictionary = {}
var _heights := PackedFloat32Array()
var _surface: Array = []
var _cell := 1.5
var _cols := 0
var _rows := 0
var _ox := 0.0
var _oz := 0.0
var _size := Vector2(120.0, 63.0)
var _hmin := 0.0
var _hmax := 0.0
var _camps: Array[Vector2] = []
var _terrain_mat: ShaderMaterial = null
## 观感旋钮（`map_shells.json` 的 `look.terrain`）：地形自己也只读数据，不写死观感常数。
var _look: Dictionary = {}
## 顶点色低频起伏倍率（`look.terrain.variation`）
var _variation := 1.0


func build(shell: Dictionary, look: Dictionary = {}) -> void:
	_shell = shell
	_look = look.get("terrain", {}) if look.has("terrain") else {}
	_variation = float(_look.get("variation", 1.0))
	var size: Dictionary = shell.get("size", {})
	_size = Vector2(float(size.get("x", 120.0)), float(size.get("z", 63.0)))
	var terr: Dictionary = shell.get("terrain", {})
	_cell = maxf(float(terr.get("cell", 1.5)), 0.5)
	_cols = int(round(_size.x / _cell)) + 1
	_rows = int(round(_size.y / _cell)) + 1
	_ox = -_size.x * 0.5
	_oz = -_size.y * 0.5
	var surf: Dictionary = shell.get("surface", {})
	_surface = surf.get("index", [])

	_heights = PackedFloat32Array()
	var raw: Array = terr.get("heights", [])
	if raw.size() == _cols * _rows:
		_heights.resize(raw.size())
		for i in raw.size():
			_heights[i] = float(raw[i])
	else:
		# 数据对不上就铺平（绝不因为高度场缺一块而黑屏）
		_heights.resize(_cols * _rows)
		_heights.fill(0.0)
	_hmin = 1e9
	_hmax = -1e9
	for h in _heights:
		_hmin = minf(_hmin, h)
		_hmax = maxf(_hmax, h)
	if _hmax < _hmin:
		_hmin = 0.0
		_hmax = 0.0
	# 营地压暗的落点只取一次（每顶点再去翻 tiles 字典会很贵）
	_camps.clear()
	for t in shell.get("tiles", []):
		var td: Dictionary = t
		if String(td.get("role", "build")) == "keep":
			_camps.append(Vector2(float(td.get("x", 0.0)), float(td.get("z", 0.0))))

	_build_terrain()
	_build_decor()


# ===========================================================================
# 高度查询（双线性，与 ShellStore.height_at 同一套）
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


## 一小块地是不是平的（棋盘/建筑贴地用：平面上不反复采样）
func is_flat(x: float, z: float) -> bool:
	return absf(height_at(x, z)) < 0.001


# ===========================================================================
# 网格：顶面（贴图）+ 侧壁倒角 + 底面，同一个 ArrayMesh 的三条 surface
# ===========================================================================
func _build_terrain() -> void:
	var mesh := ArrayMesh.new()
	_add_top_surface(mesh)
	_add_block_surfaces(mesh)
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	# 地块投阴影太重（整片地形自己压自己），只接收阴影
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _add_top_surface(mesh: ArrayMesh) -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(_cols * _rows)
	normals.resize(_cols * _rows)
	colors.resize(_cols * _rows)
	for row in _rows:
		for col in _cols:
			var i := row * _cols + col
			verts[i] = Vector3(_ox + float(col) * _cell, _heights[i], _oz + float(row) * _cell)
			var hl := _heights[row * _cols + maxi(col - 1, 0)]
			var hr := _heights[row * _cols + mini(col + 1, _cols - 1)]
			var hd := _heights[maxi(row - 1, 0) * _cols + col]
			var hu := _heights[mini(row + 1, _rows - 1) * _cols + col]
			var dx := (hr - hl) / (_cell * 2.0)
			var dz := (hu - hd) / (_cell * 2.0)
			normals[i] = Vector3(-dx, 1.0, -dz).normalized()
			colors[i] = RtsTerrainAssets.vertex_tint(verts[i], normals[i], _hmin, _hmax,
				_camps, _variation)

	var indices := PackedInt32Array()
	indices.resize((_cols - 1) * (_rows - 1) * 6)
	var k := 0
	for row in _rows - 1:
		for col in _cols - 1:
			var a := row * _cols + col
			var b := a + 1
			var c := a + _cols
			var d := c + 1
			# 顺时针正面：a→b→c / b→d→c
			indices[k] = a
			indices[k + 1] = b
			indices[k + 2] = c
			indices[k + 3] = b
			indices[k + 4] = d
			indices[k + 5] = c
			k += 6
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _terrain_material())


## 地形材质 = **工程里那一份** `Content/art/材质/地形材质.tres`（→ 地形.gdshader）。
## 参数（map_half / mat_cells / mat_map / 图集 / 草地泥土贴图）全部由 RtsTerrainAssets 绑定，
## 这里不再写第二套配色 —— 编辑器看到的地表就是这里画出来的地表。
func _terrain_material() -> Material:
	_terrain_mat = RtsTerrainAssets.make_terrain_material()
	if _terrain_mat != null:
		RtsTerrainAssets.bind_terrain_material(_terrain_mat, _size.x, _size.y, _surface,
			_cols, _rows, _ox, _oz, _cell, String(_shell.get("biome", "temperate")))
		# 观感旋钮最后写：它要覆盖材质里的默认值（数据 > 资源里的手调值）
		var n := RtsTerrainAssets.apply_look(_terrain_mat, _look)
		print("[terrain] material=terrain.tres look_applied=%d %s" % [n, material_report()])
		return _terrain_mat
	# 兜底：材质资源被删了也别让地面变成纯色 —— 至少把草地贴图铺上
	# （提示语用 ASCII：i18n 预算按"含中文的字符串字面量"计数，新代码不许增长）
	push_warning("[terrain] terrain material missing -> fallback to single grass texture")
	var std := StandardMaterial3D.new()
	if ResourceLoader.exists(RtsTerrainAssets.TEX_GRASS_PATH):
		std.albedo_texture = load(RtsTerrainAssets.TEX_GRASS_PATH) as Texture2D
		std.uv1_scale = Vector3(1.0 / RtsTerrainAssets.TILE_M, 1.0 / RtsTerrainAssets.TILE_M, 1.0)
		std.uv1_triplanar = true
	std.vertex_color_use_as_albedo = true
	std.vertex_color_is_srgb = true
	std.roughness = 0.96
	std.metallic = 0.0
	std.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return std


## 自检 / 截图断言用：**真的绑上了什么**（不是读源码里有没有写）。
## 形如 "shader=1 tex=4 atlas=2 matmap=52 contrast=2.20 detail=6.00"
func material_report() -> String:
	if _terrain_mat == null:
		return "shader=0 tex=0 atlas=0 matmap=0 contrast=0.00 detail=0.00"
	var p := RtsTerrainAssets.probe(_terrain_mat)
	return "shader=%d tex=%d atlas=%d matmap=%d contrast=%.2f detail=%.2f" % [
		1 if bool(p.get("shader", false)) else 0,
		int(p.get("tex", 0)), int(p.get("atlas", 0)), int(p.get("mat_map_px", 0)),
		float(p.get("contrast", 0.0)), float(p.get("detail", 0.0))]


## 侧壁 + 倒角 + 底面（几何口径与底壳编辑器完全一致，直接搬过来）。
func _add_block_surfaces(mesh: ArrayMesh) -> void:
	var board: Dictionary = _shell.get("board", {})
	var depth := clampf(float(board.get("depth", DEPTH_FALLBACK)), 1.0, 24.0)
	var bevel := clampf(float(board.get("bevel", BEVEL_FALLBACK)), 0.0, 1.2)
	var base_y := _hmin - depth

	# 周长（CCW：南 → 东 → 北 → 西，与顶面绕序同一套）
	var ring: Array = []
	for col in _cols:
		ring.append([col, 0])
	for row in range(1, _rows):
		ring.append([_cols - 1, row])
	for col in range(_cols - 2, -1, -1):
		ring.append([col, _rows - 1])
	for row in range(_rows - 2, 0, -1):
		ring.append([0, row])
	var n := ring.size()
	if n < 4:
		return
	# 每个周长点的内法线（相邻两条边的内法线取平均，转角才不会有缝）
	var inward: Array[Vector2] = []
	inward.resize(n)
	for i in n:
		var prev: Array = ring[(i - 1 + n) % n]
		var cur: Array = ring[i]
		var next: Array = ring[(i + 1) % n]
		var p := Vector2(_ox + float(cur[0]) * _cell, _oz + float(cur[1]) * _cell)
		var pp := Vector2(_ox + float(prev[0]) * _cell, _oz + float(prev[1]) * _cell)
		var pn := Vector2(_ox + float(next[0]) * _cell, _oz + float(next[1]) * _cell)
		var d0 := (p - pp).normalized()
		var d1 := (pn - p).normalized()
		# 周长是 CCW（南→东→北→西），左法线 = 指向地图内部
		inward[i] = (Vector2(-d0.y, d0.x) + Vector2(-d1.y, d1.x)).normalized()
		if inward[i].length_squared() < 0.001:
			inward[i] = Vector2.ZERO

	var sv := PackedVector3Array()
	var sn := PackedVector3Array()
	var sc := PackedColorArray()
	var si := PackedInt32Array()
	var run := 0.0
	for i in n:
		var j := (i + 1) % n
		var a: Array = ring[i]
		var b: Array = ring[j]
		var ax := _ox + float(a[0]) * _cell
		var az := _oz + float(a[1]) * _cell
		var bx := _ox + float(b[0]) * _cell
		var bz := _oz + float(b[1]) * _cell
		var ay := _h(ax, az)
		var by := _h(bx, bz)
		var seg := maxf(Vector2(bx - ax, bz - az).length(), 0.001)
		var dir := Vector3(bx - ax, 0.0, bz - az).normalized()
		var out := Vector3.UP.cross(dir).normalized()
		if out.length_squared() < 0.001:
			out = Vector3.FORWARD
		var ca := Vector2(ax + inward[i].x * bevel, az + inward[i].y * bevel)
		var cb := Vector2(bx + inward[j].x * bevel, bz + inward[j].y * bevel)
		var base := sv.size()
		# 0 顶A / 1 顶B / 2 倒角A / 3 倒角B / 4 底A / 5 底B
		sv.append(Vector3(ax, ay, az))
		sv.append(Vector3(bx, by, bz))
		sv.append(Vector3(ca.x, ay - bevel * 0.75, ca.y))
		sv.append(Vector3(cb.x, by - bevel * 0.75, cb.y))
		sv.append(Vector3(ax, base_y, az))
		sv.append(Vector3(bx, base_y, bz))
		for q in 6:
			sn.append(out)
		# 倒角越靠下越暗一点（土层）
		sc.append(Color(1.06, 1.02, 0.96))
		sc.append(Color(1.06, 1.02, 0.96))
		sc.append(Color(0.92, 0.88, 0.82))
		sc.append(Color(0.92, 0.88, 0.82))
		sc.append(Color(0.62, 0.58, 0.54))
		sc.append(Color(0.62, 0.58, 0.54))
		# 侧面 UV 按"沿周长走的米数 × 从顶往下的米数"，三平面材质不读它，但留着给换皮用
		si.append_array([base + 0, base + 1, base + 3, base + 0, base + 3, base + 2])
		si.append_array([base + 2, base + 3, base + 5, base + 2, base + 5, base + 4])
		run += seg
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = sv
	arrays[Mesh.ARRAY_NORMAL] = sn
	arrays[Mesh.ARRAY_COLOR] = sc
	arrays[Mesh.ARRAY_INDEX] = si
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _load_mat("block_side",
		Color(0.34, 0.27, 0.20)))

	# 底面：两块三角，法线朝下；从下方也看不到破洞
	var bv := PackedVector3Array([
		Vector3(_ox, base_y, _oz),
		Vector3(_ox, base_y, _oz + float(_rows - 1) * _cell),
		Vector3(_ox + float(_cols - 1) * _cell, base_y, _oz + float(_rows - 1) * _cell),
		Vector3(_ox + float(_cols - 1) * _cell, base_y, _oz),
	])
	var bn := PackedVector3Array([Vector3.DOWN, Vector3.DOWN, Vector3.DOWN, Vector3.DOWN])
	var bi := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var b_arrays: Array = []
	b_arrays.resize(Mesh.ARRAY_MAX)
	b_arrays[Mesh.ARRAY_VERTEX] = bv
	b_arrays[Mesh.ARRAY_NORMAL] = bn
	b_arrays[Mesh.ARRAY_INDEX] = bi
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b_arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _load_mat("block_bottom",
		Color(0.11, 0.09, 0.075)))


func _load_mat(kind: String, fallback: Color) -> Material:
	var m := RtsTerrainAssets.skin_material(kind)
	if m != null:
		return m
	var std := StandardMaterial3D.new()
	std.albedo_color = fallback
	std.roughness = 0.97
	std.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	std.cull_mode = BaseMaterial3D.CULL_DISABLED
	return std


func _h(x: float, z: float) -> float:
	return height_at(x, z)


# ===========================================================================
# 装饰：手摆行走单件实例，远景带（auto + batch）走 MultiMesh 合批
# ===========================================================================
func _build_decor() -> void:
	var holder := Node3D.new()
	holder.name = "Decor"
	add_child(holder)
	var batches := {}      # kind -> Array[Transform3D]
	for d in _shell.get("decorations", []):
		var row: Dictionary = d
		var kind := String(row.get("kind", "tree"))
		var x := float(row.get("x", 0.0))
		var z := float(row.get("z", 0.0))
		var y := height_at(x, z)
		var s := float(row.get("scale", 1.0))
		var yaw := deg_to_rad(float(row.get("yaw", 0.0)))
		# 只对"合批材质有贴图"的种类合批（草丛 / 碎石）。树与岩石的合批材质是**纯白**的，
		# 一旦走 MultiMesh 就变成一片白疙瘩 —— 这类必须走单件实例，让 自然材质库 上真材质。
		if bool(row.get("batch", false)) and BATCHABLE.has(kind):
			if not batches.has(kind):
				batches[kind] = []
			var basis := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
			(batches[kind] as Array).append(Transform3D(basis, Vector3(x, y, z)))
			continue
		var n := RtsDecorLib.instantiate(StringName(kind), holder)
		if n == null:
			continue
		n.position = Vector3(x, y, z)
		n.rotation.y = yaw
		n.scale = Vector3(s, s, s)
	# 合批：同一种类一次 draw call（远景带几百棵树也不掉帧）
	for kind in batches.keys():
		var xfs: Array = batches[kind]
		var mmi := RtsDecorLib.make_multimesh(StringName(String(kind)), xfs, [])
		if mmi != null:
			mmi.name = "Batch_%s" % String(kind)
			holder.add_child(mmi)


## 自检用：画出来的装饰件数（单件 + 合批实例）
func decor_count() -> int:
	var n := 0
	for c in get_children():
		if String(c.name) != "Decor":
			continue
		for d in c.get_children():
			if d is MultiMeshInstance3D and (d as MultiMeshInstance3D).multimesh != null:
				n += (d as MultiMeshInstance3D).multimesh.instance_count
			else:
				n += 1
	return n
