class_name RtsTerrain
extends Node3D
## **地形**：程序化生成的低多边形地面（平面着色 + 顶点色），并提供高度查询。
##
## 设计要点：
##   - 地面用"每个三角面独占顶点"的方式建（flat shading），天然出低多边形的硬朗块面；
##   - 顶点色按高度/坡度混合草/土/岩三色，配合卡通着色器出层次；
##   - height_at() 用双线性插值，单位贴地、鼠标拾取、植被落位都用它；
##   - 地形只负责"看得见的地面"，可走性在 RtsLevel/GridPathfinder 里。

## 地形细分（每边格子数）
var resolution: int = 58
## 地图边长（米）
var size: float = 116.0
## 高度场，(resolution+1)^2
var heights: PackedFloat32Array = PackedFloat32Array()
## 水面节点（没有水潭时为 null）
var water: MeshInstance3D = null

var _cell: float = 2.0
var _half: float = 58.0
var _mesh_instance: MeshInstance3D = null


## 用高度场建地形网格
func build(p_size: float, p_resolution: int, p_heights: PackedFloat32Array) -> void:
	size = p_size
	resolution = maxi(4, p_resolution)
	heights = p_heights
	_cell = size / float(resolution)
	_half = size * 0.5

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "地形网格"
		add_child(_mesh_instance)

	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	# 逐格生成两个三角面，每个三角面独立顶点（平面着色）
	for z in range(resolution):
		for x in range(resolution):
			var p00 := _grid_point(x, z)
			var p10 := _grid_point(x + 1, z)
			var p01 := _grid_point(x, z + 1)
			var p11 := _grid_point(x + 1, z + 1)
			# 两个三角
			_add_tri(verts, normals, colors, p00, p01, p11)
			_add_tri(verts, normals, colors, p00, p11, p10)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh

	# 材质：优先用美术侧的地形着色器，没有就退化成顶点色标准材质
	_mesh_instance.material_override = _make_material()


## 生成地形材质
func _make_material() -> Material:
	var path := "res://美术/材质/地形材质.tres"
	if ResourceLoader.exists(path):
		var m := load(path) as Material
		if m != null:
			return m
	var std := StandardMaterial3D.new()
	std.vertex_color_use_as_albedo = true
	std.vertex_color_is_srgb = true
	std.roughness = 0.95
	std.metallic = 0.0
	std.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return std


## 顶点位置（高度来自高度场）
func _grid_point(gx: int, gz: int) -> Vector3:
	var i: int = gz * (resolution + 1) + gx
	var h: float = heights[i] if i < heights.size() else 0.0
	return Vector3(-_half + gx * _cell, h, -_half + gz * _cell)


## 追加一个三角面。
## 绕序说明（踩过的坑）：Godot 的三角形**正面是顺时针**绕序（Mesh 文档口径）。
## 所以俯视能看到的面，右手法则算出的几何法线应当**朝下**（指向地面内部），
## 而"光照用的法线"另存为朝上。两者相反才对——写反了地面会被背面剔除掉，只剩天空。
func _add_tri(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		a: Vector3, b: Vector3, d: Vector3) -> void:
	var geo := (b - a).cross(d - a)
	if geo.length_squared() < 0.0000001:
		geo = Vector3.DOWN
	# 顺时针（从上方看）⇒ 几何法线朝下；朝上就交换后两个顶点
	if geo.y > 0.0:
		var tmp := b
		b = d
		d = tmp
		geo = (b - a).cross(d - a)
	# 光照法线朝上（= -几何法线）
	var light_normal := Vector3.UP
	if geo.length_squared() > 0.0000001:
		light_normal = (-geo).normalized()
	var col := _color_for((a + b + d) / 3.0, light_normal)
	v.append(a)
	v.append(b)
	v.append(d)
	for i in 3:
		n.append(light_normal)
		c.append(col)


## 按高度与坡度给顶点上色
func _color_for(pos: Vector3, normal: Vector3) -> Color:
	# 三套基调：低处草绿、中段土黄、高处岩灰
	var grass := Color(0.20, 0.34, 0.16)
	var grass_light := Color(0.31, 0.45, 0.20)
	var dirt := Color(0.40, 0.31, 0.19)
	var rock := Color(0.34, 0.34, 0.37)
	var t: float = clampf((pos.y + 0.5) / 3.2, 0.0, 1.0)
	var slope: float = 1.0 - clampf(normal.y, 0.0, 1.0)
	var col := grass.lerp(grass_light, 0.45 + 0.30 * sin(pos.x * 0.21 + pos.z * 0.17))
	col = col.lerp(dirt, clampf(t * 0.72, 0.0, 1.0))
	# 高处自动"岩化"：地图外圈抬起的山脊应当是灰岩，不是沙丘
	var high: float = clampf((pos.y - 1.3) / 2.0, 0.0, 1.0)
	col = col.lerp(rock, maxf(clampf(slope * 3.2, 0.0, 1.0), high))
	return col


## 双线性插值取地形高度
func height_at(wx: float, wz: float) -> float:
	var fx: float = (wx + _half) / _cell
	var fz: float = (wz + _half) / _cell
	var x0: int = clampi(floori(fx), 0, resolution)
	var z0: int = clampi(floori(fz), 0, resolution)
	var x1: int = mini(x0 + 1, resolution)
	var z1: int = mini(z0 + 1, resolution)
	var tx: float = clampf(fx - float(x0), 0.0, 1.0)
	var tz: float = clampf(fz - float(z0), 0.0, 1.0)
	var row: int = resolution + 1
	var h00: float = heights[z0 * row + x0]
	var h10: float = heights[z0 * row + x1]
	var h01: float = heights[z1 * row + x0]
	var h11: float = heights[z1 * row + x1]
	var top: float = lerpf(h00, h10, tx)
	var bottom: float = lerpf(h01, h11, tx)
	return lerpf(top, bottom, tz)


## 地形三角面总数（调试用）
func triangle_count() -> int:
	return resolution * resolution * 2


## 生成一片水面（水潭）
func build_water(center: Vector2, radius: float, level_y: float) -> void:
	if water != null and is_instance_valid(water):
		water.queue_free()
	water = MeshInstance3D.new()
	water.name = "水面"
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.25
	disc.radial_segments = 28
	disc.rings = 1
	water.mesh = disc
	water.position = Vector3(center.x, level_y, center.y)
	var mat: Material = null
	var path := "res://美术/材质/水材质.tres"
	if ResourceLoader.exists(path):
		mat = load(path)
	if mat == null:
		var std := StandardMaterial3D.new()
		std.albedo_color = Color(0.16, 0.36, 0.52, 0.85)
		std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		std.roughness = 0.12
		std.metallic = 0.35
		mat = std
	water.material_override = mat
	add_child(water)
