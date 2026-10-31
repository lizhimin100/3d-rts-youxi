@tool
class_name MapLoader
extends RefCounted
## **地图加载器**：MapDef → 游戏世界（地形 / 寻路 / 道具 / 单位）的唯一通道。
##
## 三条硬规矩：
##   1. **地形只吃 heightmap**，直接交给 RtsTerrain 建网格 —— 编辑器里看到的和游戏里跑的是同一张网格。
##   2. **可走性由高度场 + 对象占地现算**，不额外存一份 walkable（存了必然和地形不同步）。
##   3. **对象只按数据重建**，加载完 MapDef 里的 Node 引用为零，地图文件干净。
##
## 默认程序化地图也能走这条通道（MapDef.from_map_data），所以"一套骨头穿两件衣裳"。

## 可走坡度上限（和 关卡.gd 的 40° 保持一致）
const WALK_SLOPE_LIMIT_DEG: float = 40.0
## 边界不可走内缩（米）：防止单位走出世界
const EDGE_KEEP_OUT: float = 3.0

## UnitDef 缓存（编辑器里也能安全调用 UnitTable.build_units）
static var _unit_cache: Dictionary = {}
## 装饰模型缓存
static var _scene_cache: Dictionary = {}


# ===========================================================================
# 类型表
# ===========================================================================

static func units_table() -> Dictionary:
	if _unit_cache.is_empty():
		_unit_cache = UnitTable.build_units()
	return _unit_cache


static func type_def(type_id: StringName) -> UnitDef:
	return units_table().get(type_id, null)


## 对象的占地半径（可走性阻挡用）。单位不挡路（会动），返回 0。
static func object_block_radius(o: MapObject) -> float:
	if o == null:
		return 0.0
	match int(o.category):
		MapObject.Category.RESOURCE:
			# tree / tree_春 / tree_夏 / tree_秋 / tree_冬 都是"树"，占地一个口径
			if String(o.type_id).begins_with("tree"):
				return 1.05 * maxf(0.2, o.scale)
			if o.type_id == &"goldmine":
				return 2.6 * maxf(0.2, o.scale)
			return 1.0 * maxf(0.2, o.scale)
		MapObject.Category.DOODAD:
			# 只有石头类挡路；木桶/栅栏这类小装饰不挡路（和原版一致：装饰不进 walkable）
			if String(o.type_id) == "岩石" or bool(o.properties.get("blocks", false)):
				return 1.05 * maxf(0.2, o.scale)
			return 0.0
		MapObject.Category.BUILDING:
			var d: UnitDef = type_def(o.type_id)
			if d != null and d.footprint.x > 0:
				return float(maxi(d.footprint.x, d.footprint.y)) * 0.5
			return 2.0
	return 0.0


# ===========================================================================
# 可走性
# ===========================================================================

## 由高度场 + 水面 + 对象占地现算 1m 网格可走性（size² 字节）。
## 顺序很重要：先地形/水域，再压对象占地（建筑最后压，压得最死）。
static func build_walkable_mask(m: MapDef) -> PackedByteArray:
	var out := PackedByteArray()
	if m == null:
		return out
	var w: int = maxi(8, m.size)
	out.resize(w * w)
	out.fill(1)
	var half: float = m.half_size()
	# 边界内缩：竞技场图要 16m（外圈林带不进寻路），普通图 3m。
	var keep_out: float = maxf(m.edge_keep_out, 0.0)
	for z in range(w):
		for x in range(w):
			var i: int = z * w + x
			var p := Vector2(-half + float(x) + 0.5, -half + float(z) + 0.5)
			if not m.in_bounds(p, keep_out):
				out[i] = 0
				continue
			if m.slope_degrees_at(p.x, p.y, 0.75) > WALK_SLOPE_LIMIT_DEG:
				out[i] = 0
				continue
			if m.is_water_at(p):
				out[i] = 0
	# 对象占地
	for o in m.objects:
		if o == null:
			continue
		if int(o.category) == MapObject.Category.BUILDING:
			var d: UnitDef = type_def(o.type_id)
			var fp := Vector2i(4, 4)
			if d != null and d.footprint.x > 0:
				fp = d.footprint
			_block_rect(out, w, o.position, fp.x + 2, fp.y + 2)
		else:
			var r: float = object_block_radius(o)
			if r > 0.0:
				_block_circle(out, w, Vector2(o.position.x, o.position.z), r)
	return out


static func _block_circle(mask: PackedByteArray, w: int, p: Vector2, radius: float) -> void:
	var half: float = float(w) * 0.5
	var cx: int = int(floor(p.x + half))
	var cz: int = int(floor(p.y + half))
	var rad: int = ceili(radius)
	for dz in range(-rad, rad + 1):
		for dx in range(-rad, rad + 1):
			if dx * dx + dz * dz > rad * rad:
				continue
			var gx: int = cx + dx
			var gz: int = cz + dz
			if gx < 0 or gz < 0 or gx >= w or gz >= w:
				continue
			mask[gz * w + gx] = 0


static func _block_rect(mask: PackedByteArray, w: int, center: Vector3,
		sx: int, sz: int) -> void:
	var half: float = float(w) * 0.5
	var x0: int = floori(center.x - float(sx) * 0.5 + half)
	var x1: int = ceili(center.x + float(sx) * 0.5 + half)
	var z0: int = floori(center.z - float(sz) * 0.5 + half)
	var z1: int = ceili(center.z + float(sz) * 0.5 + half)
	for gz in range(z0, z1):
		for gx in range(x0, x1):
			if gx < 0 or gz < 0 or gx >= w or gz >= w:
				continue
			mask[gz * w + gx] = 0


## 最近可走格（螺旋外扩）；找不到返回 (-1,-1)
static func nearest_walkable(mask: PackedByteArray, w: int, cell: Vector2i,
		max_r: int = 24) -> Vector2i:
	if cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < w:
		if mask[cell.y * w + cell.x] != 0:
			return cell
	for r in range(1, max_r + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var cx: int = cell.x + dx
				var cz: int = cell.y + dz
				if cx < 0 or cz < 0 or cx >= w or cz >= w:
					continue
				if mask[cz * w + cx] != 0:
					return Vector2i(cx, cz)
	return Vector2i(-1, -1)


## 8 邻域 BFS（禁止切角），返回可达掩码
static func reachable_mask(mask: PackedByteArray, w: int, start: Vector2i) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(w * w)
	seen.fill(0)
	if start.x < 0 or start.y < 0:
		return seen
	var queue := PackedInt32Array([start.y * w + start.x])
	seen[start.y * w + start.x] = 1
	var head: int = 0
	while head < queue.size():
		var idx: int = queue[head]
		head += 1
		var cx: int = idx % w
		var cz: int = idx / w
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var nx: int = cx + dx
				var nz: int = cz + dz
				if nx < 0 or nz < 0 or nx >= w or nz >= w:
					continue
				var ni: int = nz * w + nx
				if mask[ni] == 0 or seen[ni] != 0:
					continue
				if dx != 0 and dz != 0:
					if mask[cz * w + nx] == 0 or mask[nz * w + cx] == 0:
						continue
				seen[ni] = 1
				queue.append(ni)
	return seen


## 世界点 → 1m 格
static func world_cell(m: MapDef, p: Vector2) -> Vector2i:
	var half: float = m.half_size()
	return Vector2i(floori(p.x + half), floori(p.y + half))


# ===========================================================================
# MapDef → MapGenerator.MapData（喂给现成的 RtsLevel / GridPathfinder）
# ===========================================================================

static func to_map_data(m: MapDef) -> MapGenerator.MapData:
	var d := MapGenerator.MapData.new()
	if m == null:
		return d
	d.size = float(m.size)
	d.resolution = m.height_resolution
	d.heights = m.heightmap.duplicate()
	d.walkable = build_walkable_mask(m)
	d.trees = []
	d.trees_proc = []
	d.mines = []
	d.rocks = []
	# 地块（魔兽 3 口径）与远景开关：不还原它们，地图会"高度对、路没了、远处多一圈山"
	d.mat_cells = m.mat_cells
	d.mat_nodes = m.mat_nodes.duplicate()
	d.mat_tile = m.mat_tile
	d.far_ridges = m.far_ridges
	d.base_pad = m.base_pad
	# 出生点（槽位顺序）：关卡靠它决定每个阵营的基地位置
	d.base_points.clear()
	var pl_sorted: Array = []
	for p in m.players:
		if p != null:
			pl_sorted.append(p)
	pl_sorted.sort_custom(func(a: PlayerSlot, b: PlayerSlot) -> bool: return a.id < b.id)
	for p in pl_sorted:
		d.base_points.append(p.start_pos)
	# 地表叙事：土路/草丛/碎石/营地杂物/岩石批次，原样搬回 MapData
	_restore_ground(m, d)
	# 只有"资源"类别进 MapData（树/金矿/其它资源点）。
	# 建筑/单位/装饰统一由 spawn_map_objects 逐个实例化 —— 装饰不再塞进 rocks，
	# 否则关卡会用 MultiMesh 再画一遍，同一个石头出现两次。
	for o in m.objects:
		if o == null or int(o.category) != MapObject.Category.RESOURCE:
			continue
		var p := Vector2(o.position.x, o.position.z)
		if String(o.type_id).begins_with("tree"):
			d.trees.append(p)
			# ★ 每棵树的"长相"跟着对象走：品种(id 后缀) + 种子 + 朝向。
			#   关卡.spawn_props 会按这份参数建树，所以编辑器里摆成什么样，
			#   进游戏就是什么样（同一棵永远长一样）。
			var proc: Dictionary = _proc_of(o)
			proc["id"] = String(o.type_id)
			d.trees_proc.append(proc)
		elif o.type_id == &"goldmine":
			d.mines.append(p)
		else:
			d.rocks.append({"pos": p, "scale": o.scale, "rot": o.rotation})
	var spots: Array = m.water_spots()
	if not spots.is_empty() and bool(m.water.get("enabled", false)):
		var s: Dictionary = spots[0]
		d.pond_center = s["center"]
		d.pond_radius = float(s["radius"])
		d.pond_level = float(s["level"])
	d.plateau = {}
	d.ramps = []
	d.flat_zones = []
	d.spawn_safe = []
	d.stats = {"source": "MapDef", "size": m.size, "seed": m.seed}
	return d


## 把 MapDef.ground 里的地表叙事数据搬回 MapData（纯视觉，不影响可走性）。
static func _restore_ground(m: MapDef, d: MapGenerator.MapData) -> void:
	if m == null or d == null:
		return
	var g: Dictionary = m.ground
	d.roads = _copy_list(g.get("roads", []))
	d.grass = _copy_list(g.get("grass", []))
	d.rubble = _copy_list(g.get("rubble", []))
	d.rocks = _copy_list(g.get("rocks", []))
	d.plazas = _copy_list(g.get("plazas", []))
	var dec: Variant = g.get("decor", null)
	if dec is Dictionary:
		d.decor = (dec as Dictionary).duplicate(true)
	else:
		d.decor = {}


static func _copy_list(v: Variant) -> Array:
	if v is Array:
		return (v as Array).duplicate(true)
	return []


# ===========================================================================
# 建关（游戏侧）
# ===========================================================================

## 把 MapDef 应用到一个 RtsLevel 上：地形 → 寻路 → 资源 → 摆放对象 → 地表层。
## 返回是否成功。
static func apply_to_level(m: MapDef, level: RtsLevel) -> bool:
	if m == null or level == null:
		push_error("[地图加载] MapDef 或 RtsLevel 为空")
		return false
	if not level.has_method("build_from_map_def"):
		push_error("[地图加载] 关卡脚本缺少 build_from_map_def()，请检查 代码/核心/关卡.gd")
		return false
	level.build_from_map_def(m)
	level.spawn_props()
	spawn_map_objects(m, level)
	# 地表叙事层（土路 / 草丛 / 碎石 / 营地杂物 / 岩石批次）：MapData 里已经有数据，
	# 这里交给 RtsGroundDetail 用同一套合批逻辑建出来（和 MapGenerator.build_arena 的
	# 末尾是同一个入口）。它是"下一帧自己找关卡挂上去"，所以放在这里是安全的。
	RtsGroundDetail.install(level.map_data)
	# 老/简易地图（只有地形+资源、没有开局建筑）退回 cfg 的开局布阵，
	# 否则 --map= 进图会发现"没有大本营、没有兵"。
	if not _has_building_objects(m):
		level.spawn_starting_forces()
	var overlay := build_splat_overlay(m)
	if overlay != null:
		level.add_child(overlay)
		var aabb: AABB = overlay.mesh.get_aabb()
		print("[地图加载] 地表层：%d 顶点，生态 %s" % [
			overlay.mesh.surface_get_array_len(0), MapDef.biome_name(m.biome)])
	else:
		print("[地图加载] 地表层：无（splatmap 全空或未铺）")
	return true


## 地图里有没有"开局建筑"对象（没有就退回 cfg 的默认布阵）
static func _has_building_objects(m: MapDef) -> bool:
	if m == null:
		return false
	for o in m.objects:
		if o != null and int(o.category) == MapObject.Category.BUILDING:
			return true
	return false


## 摆放建筑 / 单位 / 装饰（资源已经由 level.spawn_props() 按 MapData 建好了）
static func spawn_map_objects(m: MapDef, level: RtsLevel) -> void:
	if m == null or level == null:
		return
	for o in m.objects:
		if o == null:
			continue
		match int(o.category):
			MapObject.Category.UNIT, MapObject.Category.BUILDING:
				var d: UnitDef = type_def(o.type_id)
				if d == null:
					push_warning("[地图加载] 未知类型 id：%s（已跳过）" % String(o.type_id))
					continue
				# 归属 = 槽位号。多队图里 2/3 号槽也必须对上自己的阵营
				# （旧版把 owner>=1 全塞给 Game.enemy_faction —— 4 队图的盟友基地
				#   会变成敌人的，一进图就互相拆家）。
				var faction: RtsFaction = null
				if o.owner >= 0 and o.owner < Game.factions.size():
					faction = Game.factions[o.owner]
				elif o.owner >= 0:
					faction = Game.player_faction if o.owner == 0 else Game.enemy_faction
				var gx: float = o.position.x
				var gz: float = o.position.z
				var yaw: float = o.rotation
				if int(o.category) == MapObject.Category.BUILDING:
					# 地图数据可能来自旧版本 / 手改 JSON：加载时再吸一次网格，
					# 保证游戏里的占地和寻路格、开发者眼里的"轴线"是同一套。
					var fp: Vector2i = d.footprint
					var anchor := 建筑网格.snap_point_in(Vector3(gx, 0.0, gz), fp,
						level.world_size * 0.5, GridPathfinder.CELL)
					gx = anchor.x
					gz = anchor.z
					yaw = 建筑网格.snap_yaw(o.rotation)
				var pos := Vector3(gx, level.height_at(gx, gz), gz)
				var node: Node3D = Game.spawn_unit(faction, o.type_id, pos, level)
				if node == null:
					continue
				node.rotation.y = yaw
				if int(o.category) == MapObject.Category.BUILDING:
					# 建筑占地由 def.footprint 决定；视觉缩放会让占地和寻路格错位，
					# 所以建筑统一忽略 scale（编辑器/校验也会修正旧数据）。
					if absf(o.scale - 1.0) > 0.001:
						push_warning("[地图加载] 建筑 %s 的非 1.0 缩放已忽略（占地必须对齐寻路格）"
							% String(o.type_id))
					level.mark_footprint(node)
					if node.has_method("set_constructed"):
						node.call("set_constructed", true)
					# 和 cfg 开局布阵保持同一套表现：建筑插旗（阵营色）
					if faction != null and level.has_method("add_banners"):
						level.call("add_banners", node, faction)
				elif absf(o.scale - 1.0) > 0.001:
					node.scale = Vector3.ONE * o.scale
			MapObject.Category.DOODAD:
				var dn: Node3D = build_doodad_node(o)
				if dn == null:
					continue
				var dx: float = o.position.x
				var dz: float = o.position.z
				var y_off: float = float(o.properties.get("y_offset", 0.0))
				dn.position = Vector3(dx, level.height_at(dx, dz) + y_off, dz)
				dn.rotation.y = o.rotation
				dn.scale = Vector3.ONE * maxf(0.05, o.scale)
				level.add_child(dn)
			_:
				pass


## 资源类（树）的程序化外观参数。
## 老地图没有 properties.seed（这个功能是后加的）→ 由落点反推，保证老地图也能长出多样的林子。
static func _proc_of(o: MapObject) -> Dictionary:
	var seed_val: int = int(o.properties.get("seed", -1))
	var season: String = String(o.properties.get("season", ""))
	if seed_val < 0:
		var d: Dictionary = TreeLibrary.proc_at(o.position)
		seed_val = int(d["seed"])
	return {"season": season, "seed": seed_val, "yaw": float(o.rotation)}


## 造一个装饰节点（纯视觉）。找不到模型时返回 null（不吞警告，但也不崩）。
static func build_doodad_node(o: MapObject) -> Node3D:
	if o == null:
		return null
	# ★ 岩石走程序化：和游戏里 map_data.rocks 那条路用同一份网格 + 同一个材质，
	#   编辑器摆出来什么样，进游戏就是什么样（以前编辑器里是 GLB 原样灰度）。
	if String(o.type_id) == "岩石":
		var nb: int = ProcProp.variants(ProcProp.KIND_ROCK)
		if nb > 0:
			var hv: int = absi(hash(Vector2(o.position.x, o.position.z)))
			var mi := MeshInstance3D.new()
			mi.name = "岩石"
			mi.mesh = ProcProp.mesh(ProcProp.KIND_ROCK, hv % nb)
			mi.material_override = ProcProp.rock_material()
			mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			return mi
	var path: String = String(o.properties.get("model", ""))
	if path.is_empty():
		path = "res://美术/模型/v7_自然/%s.glb" % String(o.type_id)
		if not ResourceLoader.exists(path):
			path = "res://美术/模型/%s.glb" % String(o.type_id)
	if not ResourceLoader.exists(path):
		return null
	var ps: PackedScene = _scene_cache.get(path, null)
	if ps == null:
		ps = load(path) as PackedScene
		_scene_cache[path] = ps
	if ps == null:
		return null
	var inst: Node = ps.instantiate()
	if inst is Node3D:
		(inst as Node3D).name = "装饰_" + String(o.type_id)
		return inst as Node3D
	inst.queue_free()
	return null


# ===========================================================================
# 地表层（splatmap）覆盖网格
# ===========================================================================

## 按 splatmap 生成一层贴地覆盖网格（泥土/岩石/沙地/草地/生态底色）。
## **不动现有地形材质**：这是独立的一层薄面，编辑器与游戏用同一个函数生成，
## 所以"编辑器里刷的"和"游戏里跑的"完全一致。
##
## p_block：几格合成一块（1 = 逐格）。笔刷拖动中传 2/3 换帧率，松手仍按 1 精细建。
##
## 两段式：
##   1. **格点颜色表**（(res+1)² 个顶点）先算一次 —— 三层值噪声叠出深浅斑块；
##   2. 每个格子用**四个角点插值** —— 块与块之间是渐变过渡，不是 1m 马赛克。
## 同一片草地会同时有墨绿 / 草绿 / 枯黄，看着才像地，不像塑料布。
static func build_splat_overlay(m: MapDef, p_block: int = 1) -> MeshInstance3D:
	if m == null or m.splatmap.is_empty():
		return null
	var block: int = clampi(p_block, 1, 4)
	var c: float = m.cell_size()
	var half: float = m.half_size()
	var res: int = m.height_resolution
	var salt: int = m.seed
	# 格点颜色表：算一遍，逐格查表。计算量和"一格一色"同一量级，
	# 但视觉上从马赛克变成块状水彩。
	# block > 1（笔刷拖动中）时角点表也按 block 降采样 —— 否则拖动每帧都要
	# 重算 (res+1)² 个格点，笔刷会卡成幻灯片。
	var bstep: int = maxi(1, block)
	var cells: int = floori(float(res) / float(bstep))
	var row: int = cells + 1
	var corner := PackedColorArray()
	corner.resize(row * row)
	for gz in range(row):
		for gx in range(row):
			corner[gz * row + gx] = _corner_color(m, gx * bstep, gz * bstep, salt, block)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var painted: int = 0
	for gz in range(0, res, block):
		for gx in range(0, res, block):
			var v: int = _block_value(m, gx, gz, block)
			if v == MapDef.SPLAT_NONE or v == 0:
				continue
			painted += 1
			var gx1: int = mini(gx + block, res)
			var gz1: int = mini(gz + block, res)
			var cy: int = mini(floori(float(gz) / float(bstep)), row - 1)
			var cy1: int = mini(floori(float(gz1) / float(bstep)), row - 1)
			var cx: int = mini(floori(float(gx) / float(bstep)), row - 1)
			var cx1: int = mini(floori(float(gx1) / float(bstep)), row - 1)
			var ca: Color = corner[cy * row + cx]
			var cb: Color = corner[cy * row + cx1]
			var cq: Color = corner[cy1 * row + cx1]
			var cd: Color = corner[cy1 * row + cx]
			var x0: float = -half + float(gx) * c
			var z0: float = -half + float(gz) * c
			var x1: float = -half + float(gx1) * c
			var z1: float = -half + float(gz1) * c
			var a := Vector3(x0, m.height_at(x0, z0) + 0.22, z0)
			var b := Vector3(x1, m.height_at(x1, z0) + 0.22, z0)
			var cc := Vector3(x1, m.height_at(x1, z1) + 0.22, z1)
			var dd := Vector3(x0, m.height_at(x0, z1) + 0.22, z1)
			_splat_tri(st, a, b, cc, ca, cb, cq)
			_splat_tri(st, a, cc, dd, ca, cq, cd)
	if painted == 0:
		return null
	var mi := MeshInstance3D.new()
	mi.name = "地表层"
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# **UNSHADED**：地表层是"刷上去的颜色"，不是受光表面。
	#   受光模式下 3 档太阳光会把深绿抬成中绿，色块和地形糊成一片 —— 
	#   看着就是"改了但没看出来"。这里固定不受光，颜色所见即所得。
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.disable_receive_shadows = true
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


## 一块的代表值：取块心格（1 格时就是本格）
static func _block_value(m: MapDef, gx: int, gz: int, block: int) -> int:
	if block <= 1:
		var i: int = gz * m.height_resolution + gx
		return m.splatmap[i] if i >= 0 and i < m.splatmap.size() else MapDef.SPLAT_NONE
	var cx: int = mini(gx + block / 2, m.height_resolution - 1)
	var cz: int = mini(gz + block / 2, m.height_resolution - 1)
	var j: int = cz * m.height_resolution + cx
	return m.splatmap[j] if j >= 0 and j < m.splatmap.size() else MapDef.SPLAT_NONE


## 一个**格点**的颜色：没涂的格点返回全透明（于是地表边缘自然羽化 1 格）。
## block > 1 时按块取样，避免"块心有色、四个角全透明"的漏块。
static func _corner_color(m: MapDef, gx: int, gz: int, salt: int, block: int = 1) -> Color:
	var res: int = m.height_resolution
	var v: int = _block_value(m, mini(gx, res - 1), mini(gz, res - 1), block)
	if v == MapDef.SPLAT_NONE or v == 0:
		return Color(0, 0, 0, 0)
	if v == MapDef.SPLAT_BIOME:
		return _biome_color_at(m.biome, float(gx), float(gz), salt)
	var base: Color = _splat_color(v)
	var big := _vnoise(float(gx) / 7.5, float(gz) / 7.5, salt + 31)
	var mid := _vnoise(float(gx) / 2.7, float(gz) / 2.7, salt + 57)
	var fine := _hash01(gx, gz, salt + 91)
	var k: float = clampf(0.80 + 0.34 * big + 0.13 * mid + 0.05 * fine, 0.52, 1.36)
	return Color(minf(1.0, base.r * k), minf(1.0, base.g * k), minf(1.0, base.b * k), base.a)


## 生态底色：四档色带之间连续插值 + 冷暖偏移，块状分布靠三层值噪声。
## 关键是**先把大块做成有边界的台地**（smoothstep 台阶），再叠中块与细粒；
## 否则三层噪声一平均就只剩中间那一档，看上去还是一整片"塑料布"。
static func _biome_color_at(biome: String, fx: float, fz: float, salt: int) -> Color:
	var pal: Array = MapDef.biome_palette(biome)
	if pal.is_empty():
		return Color(0.2, 0.32, 0.12, 0.93)
	# 尺度：**大块 12 格（≈15m）** 定"地貌分区"，中块 4.5 格（≈6m）做过渡，
	# 细粒只占 3%（再多就是噪点）。
	# 之前用 5.5/2.2/1.0 + 强行拉对比 2.45，出来是"迷彩布"，碎得没法看。
	var big := _vnoise(fx / 12.0, fz / 12.0, salt + 3)
	var mid := _vnoise(fx / 4.5, fz / 4.5, salt + 29)
	var fine := _vnoise(fx / 2.0, fz / 2.0, salt + 71)
	var patch: float = smoothstep(0.32, 0.68, big) * 0.70 \
		+ smoothstep(0.28, 0.72, mid) * 0.27 + fine * 0.03
	# 对比只放到 1.55：色带之间是"呼吸感"，不是"分色块"
	var t: float = clampf((patch - 0.5) * 2.0 + 0.5, 0.0, 1.0)
	var f: float = t * float(pal.size() - 1)
	var i: int = clampi(floori(f), 0, pal.size() - 2)
	var col: Color = (pal[i] as Color).lerp(pal[i + 1] as Color, f - float(i))
	# 每 6 格一带做一次冷暖偏移：大块之间有一点"气候差"，不是整张图一个味道
	var warm := _hash01(floori(fx / 6.0), floori(fz / 6.0), salt + 113)
	var w: float = (warm - 0.5) * 0.26
	if w > 0.0:
		col = col.lerp(Color(col.r * 1.14, col.g * 1.01, col.b * 0.86), w)
	else:
		col = col.lerp(Color(col.r * 0.86, col.g * 1.00, col.b * 1.18), -w)
	col.a = 0.93
	return col


## 白噪声 [0,1)：位置 + 盐，确定性（同一张图每次生成的颜色完全一样）
static func _hash01(x: int, y: int, salt: int) -> float:
	var h: int = (x * 374761393 + y * 668265263 + (salt & 0xffff) * 1442695041) & 0x7ffffffffffff
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffffff) / 16777215.0


## 值噪声（平滑插值的白噪声）：块与块之间是渐变的台地，不是马赛克
static func _vnoise(fx: float, fz: float, salt: int) -> float:
	var x0: int = floori(fx)
	var z0: int = floori(fz)
	var tx: float = fx - float(x0)
	var tz: float = fz - float(z0)
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)
	var a := _hash01(x0, z0, salt)
	var b := _hash01(x0 + 1, z0, salt)
	var c := _hash01(x0, z0 + 1, salt)
	var d := _hash01(x0 + 1, z0 + 1, salt)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


static func _splat_color(v: int) -> Color:
	match v:
		MapDef.SPLAT_DIRT:
			return Color(0.360, 0.262, 0.142, 0.76)
		MapDef.SPLAT_ROCK:
			return Color(0.360, 0.365, 0.380, 0.74)
		MapDef.SPLAT_SAND:
			return Color(0.650, 0.575, 0.375, 0.76)
		MapDef.SPLAT_GRASS:
			return Color(0.170, 0.320, 0.112, 0.72)
	return Color(0, 0, 0, 0)


static func _splat_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ca: Color, cb: Color, cc: Color) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length_squared() < 0.0000001:
		return
	n = n.normalized()
	if n.y < 0.0:
		n = -n
	var pts: Array[Vector3] = [a, b, c]
	var cols: Array[Color] = [ca, cb, cc]
	for i in range(3):
		st.set_normal(n)
		st.set_color(cols[i])
		st.add_vertex(pts[i])


# ===========================================================================
# 新建地图（程序生成底图）
# ===========================================================================

## 生成一张可以直接用的地图：起伏地形（或纯平地）+ 压平的出生营地 + 八座标配建筑
## + 固定距离金矿 + 12~17 棵树 + 波次 + 全图生态色块地表。
##
## opts（都可以不给）：
##   biome : 生态 id（temperate / arid / snow / volcanic / swamp），决定地表色带
##   flat  : true = 纯平地（"空白平地"也是能直接玩的图，建筑一个不少）
##
## 这是编辑器的"新建地图"垫底图，不依赖 200m 专用生成器。
static func new_map(p_size: int, player_count: int, p_seed: int, blank: bool = false,
		opts: Dictionary = {}) -> MapDef:
	var m := MapDef.new()
	m.size = clampi(p_size, 96, 512)
	m.seed = p_seed
	var biome: String = String(opts.get("biome", "temperate"))
	if not (biome in MapDef.BIOME_ORDER):
		biome = "temperate"
	m.biome = biome
	var flat: bool = bool(opts.get("flat", blank))
	m.height_resolution = MapDef.DEFAULT_HEIGHT_RES
	m.ensure_arrays()
	m.water = {"enabled": false, "spots": []}
	# **全图铺「生态底色」**：从这一步起，地表就是随机色块拼的，而不是一块纯色。
	# 用独立值 SPLAT_BIOME（不是 SPLAT_GRASS），老地图/手刷行为完全不受影响。
	m.splatmap.fill(MapDef.SPLAT_BIOME)

	if flat:
		m.heightmap.fill(0.0)
	else:
		var noise := FastNoiseLite.new()
		noise.seed = p_seed
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 0.010
		noise.fractal_octaves = 3
		noise.fractal_gain = 0.45
		var detail := FastNoiseLite.new()
		detail.seed = p_seed + 17
		detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		detail.frequency = 0.045
		detail.fractal_octaves = 2
		# 生态决定起伏性格：火山最凶、雪原最缓、沼泽最平
		var amp: float = 4.4
		var det_amp: float = 0.85
		var edge_lift: float = 2.6
		match biome:
			"snow":
				amp = 3.2
				det_amp = 0.55
				edge_lift = 2.0
			"volcanic":
				amp = 6.2
				det_amp = 1.35
				edge_lift = 3.4
			"swamp":
				amp = 2.3
				det_amp = 0.70
				edge_lift = 1.4
			"arid":
				amp = 3.6
				det_amp = 1.15
				edge_lift = 2.8
		var half_h: float = m.half_size()
		var c: float = m.cell_size()
		for gz in range(m.row_points()):
			for gx in range(m.row_points()):
				var p := Vector2(-half_h + float(gx) * c, -half_h + float(gz) * c)
				var h: float = noise.get_noise_2d(p.x, p.y) * amp
				h += detail.get_noise_2d(p.x, p.y) * det_amp
				# 边缘缓坡：只是抬一点，做出"盆地"边界感，不封路
				var edge: float = maxf(absf(p.x), absf(p.y))
				h += smoothstep(half_h - 15.0, half_h - 2.0, edge) * edge_lift
				m.set_grid_height(gx, gz, h)

	# --- 出生点：**所有尺寸共用一套方位规则**，2 人对角 / 3 人正三角 / 4 人四角 ---
	var n_players: int = clampi(player_count, 2, 4)
	var starts: Array[Vector2] = _spawn_points(m, n_players)
	var colors: Array[Color] = _spawn_colors()
	var teams: Array[int] = _spawn_teams(n_players)
	m.players.clear()
	m.regions.clear()
	for i in range(n_players):
		var yaw: float = atan2(starts[i].x, starts[i].y)
		var slot := PlayerSlot.make(i, "player" if i == 0 else "enemy", colors[i],
			teams[i], starts[i], 620, 380)
		slot.start_yaw = yaw
		m.players.append(slot)
		# 营地压平：半径要盖住最远的哨塔（19m）+ 边缘过渡，太小会"建筑悬在坡上"
		_flatten_area(m, starts[i], 25.0, 13.0)
		_build_base_layout(m, slot, i)
	var half: float = m.half_size()

	# --- 中央矿区（双方抢的点） ---
	var center_mines: int = 2 if n_players <= 2 else 4
	for k2 in range(center_mines):
		var ang: float = TAU * float(k2) / float(center_mines) + 0.35
		var mp: Vector2 = Vector2(cos(ang), sin(ang)) * (half * 0.22)
		_flatten_area(m, mp, 7.0, 5.0)
		m.objects.append(MapObject.make(&"goldmine", MapObject.Category.RESOURCE,
			Vector3(mp.x, m.height_at(mp.x, mp.y), mp.y), 0.0, 1.0, -1))

	# --- 区域：每个玩家的出生区（带归属颜色） + 进攻区 ---
	for i in range(m.players.size()):
		var slot: PlayerSlot = m.players[i]
		var sp := RegionDef.new()
		sp.id = "出生_%d" % (i + 1)
		sp.shape = RegionDef.Shape.CIRCLE
		sp.purpose = RegionDef.Purpose.SPAWN
		sp.owner = slot.id
		sp.points = PackedVector2Array([slot.start_pos, slot.start_pos + Vector2(21, 0)])
		m.regions.append(sp)
		var atk := RegionDef.new()
		atk.id = "进攻_%d" % (i + 1)
		atk.shape = RegionDef.Shape.CIRCLE
		atk.purpose = RegionDef.Purpose.ATTACK
		atk.owner = slot.id
		var target: Vector2 = m.players[0].start_pos if i != 0 else m.players[1].start_pos
		atk.points = PackedVector2Array([target, target + Vector2(18, 0)])
		m.regions.append(atk)

	# --- 默认波次（只有两个以上玩家才有意义） ---
	if m.players.size() >= 2:
		m.waves.append(WaveDef.make(240.0, {"footman": 4, "archer": 2},
			"出生_2", "进攻_1", 1))
		m.waves.append(WaveDef.make(420.0, {"footman": 6, "archer": 4, "mage": 1},
			"出生_2", "进攻_1", 2))

	m.camera_bounds = Rect2(Vector2(-half + 2.0, -half + 2.0), Vector2(m.size - 4.0, m.size - 4.0))
	m.victory = {"mode": "destroy_townhall", "time_limit": 0.0}
	m.ensure_arrays()
	# 生成后自净：删掉被围死的树 —— 但**树的数量是硬指标**，删完必须补回来。
	_prune_unreachable_trees(m)
	_ensure_tree_counts(m)
	return m


## 出生点方位（**按尺寸等比**，同一张图里所有玩家离中心距离一致）
static func _spawn_points(m: MapDef, n_players: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var d: float = m.half_size() * 0.52
	match n_players:
		3:
			# 正三角：三个点互相等距，不会出现"两家贴脸、一家孤悬"
			var r: float = m.half_size() * 0.56
			out.append(Vector2(0.0, r))
			out.append(Vector2(-r * 0.866, -r * 0.5))
			out.append(Vector2(r * 0.866, -r * 0.5))
		4:
			out.append(Vector2(-d, d))
			out.append(Vector2(d, -d))
			out.append(Vector2(d, d))
			out.append(Vector2(-d, -d))
		_:
			out.append(Vector2(-d, d))
			out.append(Vector2(d, -d))
	return out


## 四家四个色：蓝 / 红 / 青绿 / 金。出生区、区域填充、归属按钮全吃这一份。
static func _spawn_colors() -> Array[Color]:
	var out: Array[Color] = [
		Color(0.30, 0.62, 1.00),
		Color(1.00, 0.32, 0.26),
		Color(0.28, 0.82, 0.62),
		Color(0.92, 0.78, 0.28),
	]
	return out


static func _spawn_teams(n_players: int) -> Array[int]:
	var out: Array[int] = []
	match n_players:
		4:
			out = [0, 1, 0, 1]
		3:
			out = [0, 1, 1]
		_:
			out = [0, 1]
	return out


## 生成后自净：把被同伴围死、从玩家 0 走不到的树去掉。
## 为什么必须在生成阶段做：树是实体，密林内部会形成"看得见但走不到"的口袋，
## 这种资源留在图上就是校验错误。生成器自己擦干净，新建的地图才能一上来就过校验。
static func _prune_unreachable_trees(m: MapDef) -> void:
	if m == null or m.players.is_empty() or m.players[0] == null:
		return
	var w: int = maxi(8, m.size)
	var mask: PackedByteArray = build_walkable_mask(m)
	var start: Vector2i = nearest_walkable(mask, w, world_cell(m, m.players[0].start_pos), 12)
	if start.x < 0:
		return
	var seen: PackedByteArray = reachable_mask(mask, w, start)
	var drop: Array = []
	for o in m.objects:
		if o == null or o.type_id != &"tree":
			continue
		var p := Vector2(o.position.x, o.position.z)
		var c: Vector2i = nearest_walkable(mask, w, world_cell(m, p), 6)
		if c.x < 0 or seen[c.y * w + c.x] == 0:
			drop.append(o)
	for o in drop:
		m.objects.erase(o)


## 一个玩家的开局：**八座建筑一个不少**
##   大本营 ×1 / 兵营 ×1 / 铁匠铺 ×1 / 农场 ×2 / 哨塔 ×3
## 位置是相对基地的 fwd（朝地图中心）/ right（侧向）格位，按地图尺寸等比例缩放；
## 落点一律过建筑网格（1m 格 + 90° 朝向），所以不会"歪七扭八糊在一块"。
static func _build_base_layout(m: MapDef, slot: PlayerSlot, index: int) -> void:
	# ★ **全图统一朝向**：所有营地、所有建筑一律 yaw = PI（模型正面朝镜头 / 世界 +Z）。
	#   以前按"朝地图中心"算，2 人图对角出生会得到 -45°/135°，snap 成 -90°/180°，
	#   四家各朝一边，俯视看就是"一家斜一家正"，用户第一反应就是"朝向随机"。
	#   固定 PI 之后四块营地长得一模一样，摆出来是板正的；布局仍按相对格位，不会变形。
	var yaw: float = 建筑网格.snap_yaw(PI)
	slot.start_yaw = yaw
	var fwd := Vector2(-sin(yaw), -cos(yaw))     # 模型正面（朝镜头 / 南）
	var right := Vector2(cos(yaw), -sin(yaw))
	var base: Vector2 = slot.start_pos
	var k: float = clampf(m.half_size() / 100.0, 1.0, 1.2)
	var entries: Array = [
		[&"townhall", base],
		[&"barracks", base + right * 14.0 * k + fwd * 2.0 * k],
		[&"blacksmith", base - right * 14.0 * k + fwd * 2.0 * k],
		[&"farm", base + right * 13.0 * k - fwd * 13.0 * k],
		[&"farm", base - right * 13.0 * k - fwd * 13.0 * k],
		[&"tower", base + fwd * 19.0 * k],
		[&"tower", base + right * 18.0 * k + fwd * 12.0 * k],
		[&"tower", base - right * 18.0 * k + fwd * 12.0 * k],
	]
	for e in entries:
		_place_building(m, slot, StringName(e[0]), e[1], yaw)
	# 一队兵：摆在基地正前方扇形里，避开建筑占地（编辑器里看得见，Test Map 直接能打）
	var units: Array = [[&"peasant", 5], [&"footman", 4], [&"archer", 2]]
	var idx: int = 0
	var face: float = atan2(fwd.y, fwd.x)
	for u in units:
		var uid: StringName = u[0]
		for _n in range(int(u[1])):
			var ang: float = face + (float(idx) / 10.0 - 0.5) * 1.05
			var p2: Vector2 = base + Vector2(cos(ang), sin(ang)) * 12.5 * k
			m.objects.append(MapObject.make(uid, MapObject.Category.UNIT,
				Vector3(p2.x, m.height_at(p2.x, p2.y), p2.y), PI, 1.0, slot.id))
			idx += 1
	# 金矿：**固定距离**（同一张图里每家都一样），方向朝地图中心 ——
	# 朝中心永远不会撞边界，所以距离不会被 clamp 破坏。
	# 距离同时受地图尺寸限制（小图上 26m 会顶到边界）。
	var gold_dist: float = minf(26.0 * k, m.half_size() * 0.30)
	var to_center: Vector2 = (-base).normalized()
	if to_center == Vector2.ZERO:
		to_center = fwd
	var mp: Vector2 = base + to_center * gold_dist
	_flatten_area(m, mp, 6.5, 5.0)
	m.objects.append(MapObject.make(&"goldmine", MapObject.Category.RESOURCE,
		Vector3(mp.x, m.height_at(mp.x, mp.y), mp.y), 0.0, 1.0, -1))
	# 树林：**固定半径圆环**，12~17 棵（数量由种子定，重开同一张图不变）
	# 整体偏半格，让最近的树错开金矿正前方，不会跟矿挤成一坨。
	var tree_dist: float = minf(34.0 * k, m.half_size() * 0.36)
	var tree_count: int = tree_target_count(m, index)
	var rng := RandomNumberGenerator.new()
	rng.seed = m.seed + index * 977 + 13
	var phase: float = PI / float(tree_count)
	for i in range(tree_count):
		var ang2: float = TAU * float(i) / float(tree_count) + phase
		var p3: Vector2 = base + Vector2(cos(ang2), sin(ang2)) * tree_dist
		p3 = _clamp_in(m, p3, 6.0)
		m.objects.append(MapObject.make(&"tree", MapObject.Category.RESOURCE,
			Vector3(p3.x, m.height_at(p3.x, p3.y), p3.y), rng.randf() * TAU,
			0.85 + rng.randf() * 0.35, -1))


## 这个出生点该有几棵树：12 ~ 17（种子决定；**写死范围**，绝不给 11 也不给 18）
static func tree_target_count(m: MapDef, index: int) -> int:
	return 12 + absi(m.seed + index * 37) % 6


## 落一座建筑：夹进地图 → 建筑网格吸附 → 贴地。所有生成路径都走这一条。
static func _place_building(m: MapDef, slot: PlayerSlot, id: StringName, p: Vector2,
		yaw: float) -> void:
	var d: UnitDef = type_def(id)
	var fp: Vector2i = d.footprint if d != null else Vector2i(2, 2)
	var safe: Vector2 = _clamp_in(m, p, float(maxi(fp.x, fp.y)) * 0.5 + 2.0)
	var anchor := 建筑网格.snap_point_in(Vector3(safe.x, 0.0, safe.y), fp,
		m.half_size(), GridPathfinder.CELL)
	m.objects.append(MapObject.make(id, MapObject.Category.BUILDING,
		Vector3(anchor.x, m.height_at(anchor.x, anchor.z), anchor.z), yaw, 1.0, slot.id))


## 生成后补足树：prune 可能删掉被围死的，但「每个出生点 12~17 棵」是硬指标。
## 只补在**该基地自己那一圈**（离本基地比离别人近），免得把邻居的树算成自己的。
static func _ensure_tree_counts(m: MapDef) -> void:
	if m.players.is_empty():
		return
	var k: float = clampf(m.half_size() / 100.0, 1.0, 1.2)
	var tree_dist: float = minf(34.0 * k, m.half_size() * 0.36)
	for pi in range(m.players.size()):
		var slot: PlayerSlot = m.players[pi]
		if slot == null:
			continue
		var want: int = tree_target_count(m, pi)
		var have: int = 0
		for o in m.objects:
			if o == null or o.type_id != &"tree":
				continue
			var p := Vector2(o.position.x, o.position.z)
			if p.distance_to(slot.start_pos) > tree_dist * 1.30:
				continue
			var mine: bool = true
			for pj in range(m.players.size()):
				if pj == pi or m.players[pj] == null:
					continue
				if p.distance_to(m.players[pj].start_pos) < p.distance_to(slot.start_pos):
					mine = false
					break
			if mine:
				have += 1
		var need: int = want - have
		if need <= 0:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = m.seed + pi * 613 + 7
		var slots: int = maxi(need * 4, 8)
		for si in range(slots):
			if need <= 0:
				break
			var ang: float = TAU * float(si) / float(slots) + 0.29
			var p2: Vector2 = _clamp_in(m, slot.start_pos
				+ Vector2(cos(ang), sin(ang)) * tree_dist, 5.0)
			var ok: bool = true
			for o2 in m.objects:
				if o2 == null:
					continue
				if o2.type_id != &"tree" and o2.type_id != &"goldmine":
					continue
				if Vector2(o2.position.x, o2.position.z).distance_to(p2) < 4.0:
					ok = false
					break
			if not ok:
				continue
			m.objects.append(MapObject.make(&"tree", MapObject.Category.RESOURCE,
				Vector3(p2.x, m.height_at(p2.x, p2.y), p2.y), rng.randf() * TAU,
				0.85 + rng.randf() * 0.35, -1))
			need -= 1


## 把一个点夹进地图（留边距），保证生成出来的资源不会掉到边界外
static func _clamp_in(m: MapDef, p: Vector2, margin: float) -> Vector2:
	var lim: float = maxf(0.0, m.half_size() - margin)
	return Vector2(clampf(p.x, -lim, lim), clampf(p.y, -lim, lim))


## 把一块圆形区域压平到中心高度（编辑器新建地图用）
static func _flatten_area(m: MapDef, center: Vector2, radius: float, blend: float) -> void:
	var target: float = m.height_at(center.x, center.y)
	var c: float = m.cell_size()
	var half: float = m.half_size()
	var r1: float = radius + maxf(0.0, blend)
	for gz in range(m.row_points()):
		for gx in range(m.row_points()):
			var p := Vector2(-half + float(gx) * c, -half + float(gz) * c)
			var d: float = p.distance_to(center)
			if d > r1:
				continue
			var t: float = 1.0 - smoothstep(radius, r1, d)
			var i: int = gz * m.row_points() + gx
			m.heightmap[i] = lerpf(m.heightmap[i], target, t)


# ===========================================================================
# 默认程序化地图 → MapDef（统一出口径）
# ===========================================================================

## 把 cfg 生成出来的默认地图转成 MapDef（含开局建筑对象）。
static func capture_default(cfg: GameConfig = null) -> MapDef:
	var c: GameConfig = cfg
	if c == null:
		c = Cfg.game
	if c == null:
		return null
	var data: MapGenerator.MapData = MapGenerator.build(c)
	return MapDef.from_map_data(data, c)