class_name RtsFog
extends Node3D
## **战争迷雾（War Fog）**
##
## 以「玩家阵营 + 其盟友」为观察方（is_ally_of(player) 即同队）。每个观察方单位/建筑
## 按 def.sight_range 在网格上点亮可见格；见过的格进入「已探索」（变暗但保留记忆），
## 从没见过的格全黑。
##
## 表现三层：
##   1) 地形雾面：一张贴合地形的半透网格，采样 fog 贴图 —— 未探索≈全黑、已探索半暗、可见全透；
##   2) 单位隐藏：雾中（不可见）的敌方单位/建筑被隐藏（visible=false）；
##   3) 小地图遮罩：同一张 fog 贴图喂给小地图，雾区同样压黑/压暗。
##
## 设计取舍：稳定 > 好看。迷雾网格分辨率固定 96，雾面贴合地形（非平铺），不挂自定义
## shader（复用 StandardMaterial3D 的 albedo 贴图 + 透明，和地表层同一套做法）。

const GRID: int = 96                  # 迷雾网格分辨率（每轴格子数）
const FOG_LIFT: float = 0.30          # 雾面相对地形抬升（高于地表层 0.22，避免 z-fighting）
const UNSEEN_A: float = 0.96          # 未探索：接近全黑
const EXPLORED_A: float = 0.50        # 已探索但当前不可见：半暗
const UPDATE_INTERVAL: float = 0.15   # 重算间隔（≈6.7Hz，足够顺滑又省 CPU）

var observer: RtsFaction = null
var terrain: RtsTerrain = null
var world_size: float = 116.0

var _half: float = 0.0
var _cell: float = 0.0
var _explored: PackedByteArray = PackedByteArray()
var _visible: PackedByteArray = PackedByteArray()
var _cell_alpha: PackedByteArray = PackedByteArray()
var _fog_image: Image = null
var fog_texture: ImageTexture = null
var _mesh: MeshInstance3D = null
var _acc: float = 0.0
var _built: bool = false


func setup(p_terrain: RtsTerrain, p_observer: RtsFaction, p_world_size: float) -> void:
	if p_terrain == null or p_observer == null:
		return
	terrain = p_terrain
	observer = p_observer
	world_size = p_world_size if p_world_size > 1.0 else terrain.size
	_half = world_size * 0.5
	_cell = world_size / float(GRID)
	_explored.resize(GRID * GRID)
	_visible.resize(GRID * GRID)
	_cell_alpha.resize(GRID * GRID)
	_build_image()
	_build_mesh()
	add_to_group("fog_system")
	_built = true
	# 开局先算一遍，避免「整片黑」闪一下
	_compute_visibility()
	set_process(true)


func _build_image() -> void:
	_fog_image = Image.create(GRID, GRID, false, Image.FORMAT_RGBA8)
	_fog_image.fill(Color(0.0, 0.0, 0.0, UNSEEN_A))
	fog_texture = ImageTexture.create_from_image(_fog_image)


func _build_mesh() -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for gz in range(GRID + 1):
		for gx in range(GRID + 1):
			var x: float = -_half + float(gx) * _cell
			var z: float = -_half + float(gz) * _cell
			var y: float = terrain.height_at(x, z) + FOG_LIFT
			verts.append(Vector3(x, y, z))
			normals.append(Vector3(0.0, 1.0, 0.0))
			uvs.append(Vector2(float(gx) / float(GRID), float(gz) / float(GRID)))
	for gz in range(GRID):
		for gx in range(GRID):
			var a: int = gz * (GRID + 1) + gx
			var b: int = a + 1
			var c: int = a + (GRID + 1)
			var d: int = c + 1
			indices.append(a); indices.append(c); indices.append(b)
			indices.append(b); indices.append(c); indices.append(d)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh = MeshInstance3D.new()
	_mesh.name = "战争迷雾"
	_mesh.mesh = am
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = fog_texture
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.disable_receive_shadows = true
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# 雾面挂在地形节点下，坐标与地形一致（含地形自身变换）
	terrain.add_child(_mesh)


func _process(delta: float) -> void:
	if not _built or observer == null or terrain == null:
		return
	_acc += delta
	if _acc < UPDATE_INTERVAL:
		return
	_acc = 0.0
	_compute_visibility()


func _compute_visibility() -> void:
	_visible.fill(0)
	for f in Game.factions:
		if f == null or not observer.is_ally_of(f):
			continue
		_mark_faction(f)
	_refresh()
	_hide_hidden()


func _mark_faction(f: RtsFaction) -> void:
	var ents: Array = []
	ents.append_array(f.units)
	ents.append_array(f.buildings)
	for e in ents:
		if e == null or not is_instance_valid(e):
			continue
		var n := e as Node3D
		if n == null:
			continue
		if n is RtsUnit and not (n as RtsUnit).is_alive():
			continue
		if n is RtsBuilding and not (n as RtsBuilding).is_alive():
			continue
		var d: UnitDef = n.get("def")
		var r: float = 9.0
		if d != null:
			r = d.sight_range
		var lp: Vector3 = terrain.to_local(n.global_position)
		_mark_disk(lp.x, lp.z, r)


func _mark_disk(cx: float, cz: float, r: float) -> void:
	var minx: int = maxi(0, int(floor((cx - r + _half) / _cell)))
	var maxx: int = mini(GRID - 1, int(floor((cx + r + _half) / _cell)))
	var minz: int = maxi(0, int(floor((cz - r + _half) / _cell)))
	var maxz: int = mini(GRID - 1, int(floor((cz + r + _half) / _cell)))
	var r2: float = r * r
	for gz in range(minz, maxz + 1):
		for gx in range(minx, maxx + 1):
			var wx: float = -_half + (float(gx) + 0.5) * _cell
			var wz: float = -_half + (float(gz) + 0.5) * _cell
			var dx: float = wx - cx
			var dz: float = wz - cz
			if dx * dx + dz * dz <= r2:
				_visible[gz * GRID + gx] = 1


## 由可见/已探索网格算每张格子的 alpha，再写到 fog 贴图（3D 雾面与小地图共用）。
func _refresh() -> void:
	for iz in range(GRID):
		for ix in range(GRID):
			var idx: int = iz * GRID + ix
			var a: int
			if _visible[idx] == 1:
				a = 0
				_explored[idx] = 1
			elif _explored[idx] == 1:
				a = int(EXPLORED_A * 255.0)
			else:
				a = int(UNSEEN_A * 255.0)
			_cell_alpha[idx] = a
	var data := PackedByteArray()
	data.resize(GRID * GRID * 4)
	for iz in range(GRID):
		for ix in range(GRID):
			var idx: int = iz * GRID + ix
			var p: int = idx * 4
			data[p] = 0
			data[p + 1] = 0
			data[p + 2] = 0
			data[p + 3] = _cell_alpha[idx]
	_fog_image.set_data(GRID, GRID, false, Image.FORMAT_RGBA8, data)
	if fog_texture != null:
		fog_texture.update(_fog_image)


## 敌方单位/建筑：不可见则隐藏；中立资源：未探索才隐藏（探索过就保留，雾面只压暗）。
func _hide_hidden() -> void:
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var n := u as Node3D
		if n == null:
			continue
		var f = n.get("faction")
		if f != null and observer.is_ally_of(f):
			if not n.visible:
				n.visible = true
			continue
		var vis: bool = is_world_visible_pos(n.global_position)
		if n.visible != vis:
			n.visible = vis
	for h in Game.all_harvestables():
		if h == null or not is_instance_valid(h):
			continue
		var n := h as Node3D
		if n == null:
			continue
		var expl: bool = is_world_explored_pos(n.global_position)
		if n.visible != expl:
			n.visible = expl


func is_world_visible(wx: float, wz: float) -> bool:
	return is_world_visible_pos(Vector3(wx, 0.0, wz))


func is_world_visible_pos(p_world: Vector3) -> bool:
	var lp: Vector3 = terrain.to_local(p_world)
	var gx: int = int(floor((lp.x + _half) / _cell))
	var gz: int = int(floor((lp.z + _half) / _cell))
	if gx < 0 or gx >= GRID or gz < 0 or gz >= GRID:
		return false
	return _visible[gz * GRID + gx] == 1


func is_world_explored(wx: float, wz: float) -> bool:
	return is_world_explored_pos(Vector3(wx, 0.0, wz))


func is_world_explored_pos(p_world: Vector3) -> bool:
	var lp: Vector3 = terrain.to_local(p_world)
	var gx: int = int(floor((lp.x + _half) / _cell))
	var gz: int = int(floor((lp.z + _half) / _cell))
	if gx < 0 or gx >= GRID or gz < 0 or gz >= GRID:
		return false
	return _explored[gz * GRID + gx] == 1
