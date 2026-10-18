class_name RtsLevel
extends Node3D
## **关卡**：把地图数据变成真正的场景——地形网格、寻路网格、树/岩石/金矿、开局双方基地与部队。
##
## 对外提供"世界查询"接口（其他模块都从 `Game.level` 拿）：
##   height_at(x,z)            地形高度
##   grid_pathfinder()         寻路器
##   find_path(a, b)           带地形高度的平滑路径
##   world_size                地图边长
##   base_center(faction)      己方基地中心
##   dropoff_points(faction)   资源交汇点（大本营）
##   resource_nodes()          全部可采集物
##   is_buildable(pos, fp)     能否在此建造
##   mark_footprint(building)  把建筑占地写进寻路网格

## 地图边长（米）
var world_size: float = 116.0
## 地形
var terrain: RtsTerrain = null
## 寻路器
var pathfinder: GridPathfinder = null
## 地图数据
var map_data: MapGenerator.MapData = null
## 玩家基地中心 / 敌人基地中心
var _base_pos: Dictionary = {}
## 建筑列表（占格用）
var _buildings: Array = []
## 场景容器
var _props_root: Node3D = null
## 本关生成的可采集物（树 / 金矿）
var _harvestables: Array = []


## 建关（主场景调用；不要用 _ready 自动建，方便测试按需构建）
func build() -> void:
	var cfg: GameConfig = Cfg.game
	world_size = cfg.map_size
	_base_pos[RtsConst.Faction.PLAYER] = cfg.player_base_pos
	_base_pos[RtsConst.Faction.ENEMY] = cfg.enemy_base_pos

	# --- 1. 地图数据 ---
	map_data = MapGenerator.build(cfg)

	# --- 2. 地形 ---
	terrain = RtsTerrain.new()
	terrain.name = "地形"
	add_child(terrain)
	terrain.build(world_size, map_data.resolution, map_data.heights)
	if cfg.has_pond and map_data.pond_radius > 0.0:
		terrain.build_water(map_data.pond_center, map_data.pond_radius, map_data.pond_level)

	# --- 3. 寻路网格 ---
	pathfinder = GridPathfinder.new()
	pathfinder.build(world_size, map_data.walkable)

	# --- 4. 远景底板 ---
	# 为什么需要它：地图只有 116m，镜头看向地图角落时，屏幕四角的射线会打到地图外面，
	# 哪里什么都没有 → 直接看到天空，像世界破了个洞。铺一张更大的暗色底板盖住，
	# 视觉上就变成"远处的荒原"，配合雾效果很自然。
	_build_backdrop()

	# --- 5. 道具容器 ---
	_props_root = Node3D.new()
	_props_root.name = "场景道具"
	add_child(_props_root)


## 高度查询（地形没建好时返回 0）
func height_at(x: float, z: float) -> float:
	if terrain == null:
		return 0.0
	return terrain.height_at(x, z)


## 世界坐标贴地
func snap_to_ground(pos: Vector3) -> Vector3:
	return Vector3(pos.x, height_at(pos.x, pos.z), pos.z)


## 取寻路器
func grid_pathfinder() -> GridPathfinder:
	return pathfinder


## 带地形高度的路径
func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if pathfinder == null:
		return PackedVector3Array()
	var raw: PackedVector3Array = pathfinder.find_path(from, to)
	var out := PackedVector3Array()
	for p in raw:
		out.append(snap_to_ground(p))
	return out


## 某格是否可走
func is_walkable_grid(cell: Vector2i) -> bool:
	if pathfinder == null:
		return false
	return pathfinder.is_cell_walkable(cell)


## 最近可站立点
func walkable_pos(p: Vector3) -> Vector3:
	if pathfinder == null:
		return p
	return snap_to_ground(pathfinder.clamp_to_walkable(p))


## 阵营基地中心（世界坐标，已贴地）
func base_center(faction: RtsFaction) -> Vector3:
	var idx: int = faction.index if faction != null else RtsConst.Faction.PLAYER
	var p: Vector2 = _base_pos.get(idx, Vector2.ZERO)
	return snap_to_ground(Vector3(p.x, 0.0, p.y))


## 资源交汇点（大本营）
func dropoff_points(faction: RtsFaction) -> Array:
	var out: Array = []
	if faction == null:
		return out
	for b in faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if b.def != null and b.def.is_dropoff and b.is_alive():
			out.append(b)
	# 没有大本营时退而求其次：任何建筑都能回收（避免农民彻底卡死）
	if out.is_empty():
		for b in faction.buildings:
			if b != null and is_instance_valid(b) and b.is_alive():
				out.append(b)
	return out


## 全部可采集物（树 / 金矿）
func resource_nodes() -> Array:
	var out: Array = []
	for h in _harvestables:
		if h != null and is_instance_valid(h) and not h.is_depleted():
			out.append(h)
	return out


## 某个位置 + 占地是否允许建造
func is_buildable(pos: Vector3, footprint: Vector2i) -> bool:
	if pathfinder == null:
		return false
	var center_cell: Vector2i = pathfinder.world_to_cell(pos)
	var half_x: int = footprint.x / 2
	var half_z: int = footprint.y / 2
	for dz in range(-half_z, half_z + footprint.y % 2):
		for dx in range(-half_x, half_x + footprint.x % 2):
			if not pathfinder.is_cell_walkable(Vector2i(center_cell.x + dx, center_cell.y + dz)):
				return false
	return true


## 把建筑占地写进寻路网格（建成/放下时调用）
func mark_footprint(building: Node3D) -> void:
	if building == null or pathfinder == null:
		return
	var def: UnitDef = building.def
	if def == null or def.footprint == Vector2i.ZERO:
		return
	var cell: Vector2i = pathfinder.world_to_cell(building.global_position)
	# ★ 净空外扩 1 格：单位有半径（0.42~0.5m），贴着 1m 网格的墙走会被卡住或半穿模。
	#   外扩一格后 A* 自然绕开墙边，这就是"绕障、贴边"的实现方式。
	var fp: Vector2i = Vector2i(def.footprint.x + 2, def.footprint.y + 2)
	pathfinder.mark_blocked_rect(cell, fp, true)
	if not _buildings.has(building):
		_buildings.append(building)


## 清除建筑占地（建筑被拆时调用）
func clear_footprint(building: Node3D) -> void:
	if building == null or pathfinder == null:
		return
	var def: UnitDef = building.def
	if def == null:
		return
	var cell: Vector2i = pathfinder.world_to_cell(building.global_position)
	var fp: Vector2i = Vector2i(def.footprint.x + 2, def.footprint.y + 2)
	pathfinder.mark_blocked_rect(cell, fp, false)
	_buildings.erase(building)


# ===========================================================================
# 摆放道具
# ===========================================================================

## 生成树 / 金矿 / 岩石（在开局单位之前调用，好让寻路网格先固定下来）
func spawn_props() -> void:
	if map_data == null:
		return
	# 金矿
	for m in map_data.mines:
		var p := snap_to_ground(Vector3(m.x, 0.0, m.y))
		_spawn_harvestable(&"goldmine", p)
	# 树
	for t in map_data.trees:
		var p := snap_to_ground(Vector3(t.x, 0.0, t.y))
		_spawn_harvestable(&"tree", p)
	# 岩石（纯装饰）：用 MultiMesh 合批。
	# 原来 26 块 × 4 个子网格 = 104 个 MeshInstance（104 次 draw call），
	# 现在每种子网格一份 MultiMesh，总共只要 4 次。
	_build_rock_multimesh(map_data.rocks)


## 生成一个可采集物
func _spawn_harvestable(id: StringName, pos: Vector3) -> Node3D:
	var n: Node3D = Game.spawn_unit(null, id, pos, _props_root)
	if n == null:
		return null
	_no_shadow(n)
	n.add_to_group("可采集物")
	_harvestables.append(n)
	return n


# ===========================================================================
# 开局布阵
# ===========================================================================

## 生成双方开局建筑与部队
func spawn_starting_forces() -> void:
	var cfg: GameConfig = Cfg.game
	_spawn_faction_start(cfg, Game.player_faction, cfg.player_buildings, cfg.player_units)
	_spawn_faction_start(cfg, Game.enemy_faction, cfg.enemy_buildings, cfg.enemy_units)


## 生成一个阵营的开局
func _spawn_faction_start(cfg: GameConfig, faction: RtsFaction,
		buildings: Dictionary, units: Dictionary) -> void:
	if faction == null:
		return
	var center2: Vector2 = _base_pos.get(faction.index, Vector2.ZERO)
	var center3 := snap_to_ground(Vector3(center2.x, 0.0, center2.y))

	# --- 建筑 ---
	for id in buildings.keys():
		var off: Vector2 = buildings[id]
		var pos := snap_to_ground(Vector3(center2.x + off.x, 0.0, center2.y + off.y))
		# ★ 建筑必须按 1m 网格对齐（魔兽就是这样）：
		#   把坐标吸附到"格子边界"上（世界坐标 + 半幅 = 整数），
		#   这样 8×8/6×6 的建筑正好压住整数个格子，和寻路网格的阻挡区完全重合。
		pos = snap_grid(pos)
		var b: Node3D = Game.spawn_unit(faction, id, pos, self)
		if b != null:
			# 朝向固定为 0：建筑一律轴对齐，**不许有任何偏航角**（歪七扭八就是被人骂的那个）
			b.rotation = Vector3(0.0, 0.0, 0.0)
			mark_footprint(b)
			_add_banners(b, faction)
			if b.has_method("set_constructed"):
				b.call("set_constructed", true)

	# --- 单位（在基地正前方扇形散开） ---
	var forward := Vector3(0.0, 0.0, 1.0)
	if faction.index == RtsConst.Faction.ENEMY:
		forward = Vector3(0.0, 0.0, -1.0)
	var spawn_center := center3 + forward * 8.0
	var idx: int = 0
	var total: int = 0
	for id in units.keys():
		total += int(units[id])
	for id in units.keys():
		var count: int = int(units[id])
		for i in range(count):
			var ang: float = TAU * float(idx) / float(maxi(1, total))
			var rad: float = cfg.rally_spread * (1.0 + 0.35 * float(idx % 2))
			var p := Vector3(
				spawn_center.x + cos(ang) * rad,
				0.0,
				spawn_center.z + sin(ang) * rad
			)
			p = walkable_pos(p)
			var u: Node3D = Game.spawn_unit(faction, id, p, self)
			if u != null:
				# 面向敌方
				var to_enemy := base_center(Game.enemy_faction if faction.index == RtsConst.Faction.PLAYER else Game.player_faction) - p
				if to_enemy.length_squared() > 0.01:
					u.rotation.y = atan2(-to_enemy.x, -to_enemy.z)
			idx += 1


## 把世界坐标吸附到 1m 网格的**格子边界**上（建筑占地用）。
## 约定：格子 i 覆盖世界区间 [i - half, i+1 - half)，格子中心 = i+0.5-half。
## 偶数足迹的建筑，中心落在边界上才能正好压住整数个格子。
func snap_grid(p: Vector3) -> Vector3:
	var half: float = world_size * 0.5
	var out := p
	out.x = roundf(p.x + half) - half
	out.z = roundf(p.z + half) - half
	out.y = height_at(out.x, out.z)
	return out


## 关掉一棵/一块场景道具的所有网格的阴影投射（阴影 pass 的 draw call 是主要开销）
func _no_shadow(root: Node) -> void:
	if root == null:
		return
	var mi := root as MeshInstance3D
	if mi != null:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in root.get_children():
		_no_shadow(c)




## 给建筑加旗杆 + 旗面（阵营色）。
## 为什么在 Godot 里补而不是回 Blender：旗面是纯平面 + 单色，代码生成 3 个网格，
## 比重新跑一遍整栋大本营的构建脚本便宜得多，而且能直接吃阵营色。
func _add_banners(b: Node3D, faction: RtsFaction) -> void:
	if b == null or b.def == null:
		return
	var d: UnitDef = b.def
	# 只给主要建筑挂旗（小房子挂旗反而怪）
	if d.id != &"townhall" and d.id != &"barracks" and d.id != &"tower":
		return
	var color: Color = Color(0.30, 0.55, 0.95)
	if faction != null:
		color = faction.color
	var half_x: float = float(d.footprint.x) * 0.5
	var top: float = maxf(d.height * 0.92, 3.0)
	var pole_h: float = 2.6 if d.id == &"townhall" else 1.9
	# 左右各一面（大本营两面，兵营/箭塔一面）
	var offsets: Array = [half_x * 0.62]
	if d.id == &"townhall":
		offsets = [-half_x * 0.62, half_x * 0.62]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.85
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.18
	for ox in offsets:
		var root := Node3D.new()
		root.name = "旗杆"
		root.position = Vector3(float(ox), top, half_x * 0.55)
		b.add_child(root)
		var pole := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.055
		cm.bottom_radius = 0.075
		cm.height = pole_h
		cm.radial_segments = 6
		pole.mesh = cm
		pole.position.y = pole_h * 0.5
		pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(pole)
		var cloth := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(1.25, 0.72)
		pm.orientation = PlaneMesh.FACE_Z
		cloth.mesh = pm
		cloth.material_override = mat
		cloth.position = Vector3(0.66, pole_h - 0.55, 0.0)
		cloth.rotation.z = -0.06
		cloth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(cloth)

## 把岩石模型按"子网格"拆成若干 MultiMesh 批量绘制

func _build_rock_multimesh(rocks: Array) -> void:
	if rocks.is_empty():
		return
	var base: Node3D = ArtKit.build_model("res://美术/模型/岩石.glb", 1.0, Vector3(1.4, 1.1, 1.4))
	if base == null:
		return
	var parts: Array = []
	_collect_parts(base, Transform3D.IDENTITY, parts)
	base.queue_free()
	if parts.is_empty():
		return
	for part in parts:
		var src: MeshInstance3D = part["mi"]
		if src.mesh == null:
			continue
		var local_xf: Transform3D = part["xf"]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = src.mesh
		mm.instance_count = rocks.size()
		for i in rocks.size():
			var r: Dictionary = rocks[i]
			var pos2: Vector2 = r["pos"]
			var p: Vector3 = snap_to_ground(Vector3(pos2.x, 0.0, pos2.y))
			var sc: float = float(r["scale"])
			var basis := Basis(Vector3.UP, float(r["rot"])).scaled(Vector3.ONE * sc)
			mm.set_instance_transform(i, Transform3D(basis, p) * local_xf)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "岩石批次"
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_props_root.add_child(mmi)


## 递归收集网格实例及其相对根的局部变换
func _collect_parts(n: Node, parent_xf: Transform3D, out: Array) -> void:
	var mi := n as MeshInstance3D
	var xf := parent_xf
	if n is Node3D:
		xf = parent_xf * (n as Node3D).transform
	if mi != null and mi.mesh != null:
		out.append({"mi": mi, "xf": xf})
	for c in n.get_children():
		_collect_parts(c, xf, out)

## 建筑数量（调试）
func building_count() -> int:
	return _buildings.size()


## 远景底板：一张铺到视野外的暗色地面，堵住"地图外看见天空"的破绽
func _build_backdrop() -> void:
	var plane := MeshInstance3D.new()
	plane.name = "远景底板"
	var pm := PlaneMesh.new()
	pm.size = Vector2(world_size * 5.0, world_size * 5.0)
	plane.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.17, 0.20, 0.16)
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.disable_receive_shadows = true
	plane.material_override = mat
	plane.position = Vector3(0.0, -2.2, 0.0)
	add_child(plane)
