@tool
class_name MapDef
extends Resource
## **地图定义（MapDef）**：编辑器与游戏共用的唯一地图数据源。
##
## 设计原则：
##   1. **只存数据，不存节点引用**。加载时由 MapLoader 重建地形/道具/单位，
##      这样保存出来的 .tres 可以跨进程、跨版本读，不会变成一堆野指针。
##   2. **高度场是唯一地形真相**。编辑器笔刷改的就是 heightmap，
##      游戏侧 RtsTerrain 直接吃这份数据，编辑器和游戏看到的是同一张网格。
##   3. **版本化**。CURRENT_VERSION 跟着字段演进递增，MapStore 负责老版本迁移，
##      老地图不会一打开就成了乱码。
##
## 坐标约定（与 RtsTerrain / GridPathfinder 完全一致）：
##   地图以原点为中心，边长 size；高度场是 (height_resolution+1)² 个格点，
##   格点 (gx,gz) 的世界坐标 = (-size/2 + gx*cell, -size/2 + gz*cell)。

## 当前数据版本。加字段就 +1，并在 MapStore._migrate 里补默认值。
const CURRENT_VERSION: int = 2
## 高度场每边格子数（固定 128，1 格 ≈ 1.25~2m，与游戏地形细分同量级）
const DEFAULT_HEIGHT_RES: int = 128
## 地表层默认值：255 = 未涂（不生成覆盖层）
const SPLAT_NONE: int = 255
## 地表层类型（编辑器笔刷 → splatmap 值）
const SPLAT_DIRT: int = 1
const SPLAT_ROCK: int = 2
const SPLAT_SAND: int = 3
const SPLAT_GRASS: int = 4
## 「按生态底色」：整片地用 biome 色带随机拼块，不是单一纯色。
## 用独立值而不是复用 SPLAT_GRASS，是为了让老地图（全 255 / 手刷 4）行为完全不变。
const SPLAT_BIOME: int = 5

# ---------------------------------------------------------------------------
# 生态（biome）：决定"草地"到底是哪种草、哪种土
# ---------------------------------------------------------------------------
## 生态 id 顺序 = 新建向导里的下拉顺序
const BIOME_ORDER: Array[String] = ["temperate", "arid", "snow", "volcanic", "swamp"]
## 每种生态的色带（深 → 浅）：随机色块就在这几档之间插值，
## 不是"一个基色 × 亮度"，所以同一片草地会同时有墨绿、草绿、枯黄。
## **五档而不是四档**：多出来那一档是"枯草/沙斑"，让色块的**色相**也变；
## 只变亮度的话远看还是一片绿，用户会以为没改。
const BIOME_PALETTE: Dictionary = {
	"temperate": [
		Color(0.112, 0.196, 0.086), Color(0.156, 0.256, 0.106),
		Color(0.208, 0.318, 0.128), Color(0.262, 0.360, 0.152),
		Color(0.334, 0.392, 0.182),
	],
	"arid": [
		Color(0.286, 0.212, 0.118), Color(0.390, 0.300, 0.164),
		Color(0.500, 0.404, 0.232), Color(0.570, 0.486, 0.290),
		Color(0.452, 0.430, 0.254),
	],
	"snow": [
		Color(0.420, 0.500, 0.600), Color(0.540, 0.618, 0.706),
		Color(0.660, 0.722, 0.790), Color(0.780, 0.826, 0.874),
		Color(0.876, 0.900, 0.930),
	],
	"volcanic": [
		Color(0.120, 0.106, 0.104), Color(0.190, 0.174, 0.168),
		Color(0.268, 0.148, 0.116), Color(0.360, 0.198, 0.132),
		Color(0.452, 0.276, 0.180),
	],
	"swamp": [
		Color(0.090, 0.150, 0.100), Color(0.150, 0.208, 0.116),
		Color(0.230, 0.272, 0.140), Color(0.294, 0.310, 0.166),
		Color(0.230, 0.196, 0.120),
	],
}


## 生态显示名（下拉框/标签用）
static func biome_name(id: String) -> String:
	match id:
		"temperate":
			return "温带草原"
		"arid":
			return "干旱荒原"
		"snow":
			return "雪原冻土"
		"volcanic":
			return "火山岩地"
		"swamp":
			return "沼泽湿地"
	return id if not id.is_empty() else "温带草原"


## 生态色带（永远返回 4 档；未知 id 退化成温带）
static func biome_palette(id: String) -> Array:
	var raw: Variant = BIOME_PALETTE.get(id, BIOME_PALETTE["temperate"])
	var out: Array = []
	if raw is Array:
		for c in raw:
			if c is Color:
				out.append(c)
	if out.is_empty():
		out = (BIOME_PALETTE["temperate"] as Array).duplicate()
	return out


## 生态基色（色带中档，给色块按钮/缩略色块用）
static func biome_key_color(id: String) -> Color:
	var pal: Array = biome_palette(id)
	return pal[mini(1, pal.size() - 1)]

# ---------------------------------------------------------------------------
# 基础信息
# ---------------------------------------------------------------------------
@export var version: int = CURRENT_VERSION
## 地图边长（米，正方形，以原点为中心）
@export var size: int = 160
@export var seed: int = 20261024
@export var biome: String = "temperate"

# ---------------------------------------------------------------------------
# 地形数据
# ---------------------------------------------------------------------------
## 高度场每边格数（格点数 = (height_resolution+1)²）
@export var height_resolution: int = DEFAULT_HEIGHT_RES
## 高度场（米），索引 gz * (res+1) + gx
@export var heightmap: PackedFloat32Array = PackedFloat32Array()
## 地表层（每格一个字节，0/255=无，1=泥土 2=岩石 3=沙地 4=草地），索引 gz*res+gx
@export var splatmap: PackedByteArray = PackedByteArray()

## 水面：{"enabled": bool, "spots": [{"center": Vector2, "radius": float, "level": float}]}
## 游戏侧 RtsTerrain 只支持一个水潭（build_water），取 spots[0]；
## 其余水潭由 MapLoader 用同样的材质补一片圆盘，视觉一致。
@export var water: Dictionary = {"enabled": false, "spots": []}

# ---------------------------------------------------------------------------
# 内容
# ---------------------------------------------------------------------------
## 摆放的对象（单位 / 建筑 / 装饰 / 资源）
@export var objects: Array[MapObject] = []
## 逻辑区域（出生 / 进攻 / 镜头 / 氛围）
@export var regions: Array[RegionDef] = []
## 玩家槽位（含出生点与初始资源）
@export var players: Array[PlayerSlot] = []
## 波次（时间 / 兵种组成 / 出生与目标区域 / 难度）
@export var waves: Array[WaveDef] = []
## 镜头可移动范围（世界 XZ，单位米）
@export var camera_bounds: Rect2 = Rect2(-80, -80, 160, 160)
## 胜利条件：{"mode": "destroy_townhall", "time_limit": 0.0}
@export var victory: Dictionary = {"mode": "destroy_townhall", "time_limit": 0.0}


# ===========================================================================
# 基础查询
# ===========================================================================

## 每格宽度（米）
func cell_size() -> float:
	return float(size) / float(maxi(4, height_resolution))


## 半边长
func half_size() -> float:
	return float(size) * 0.5


## 高度场一行的格点数
func row_points() -> int:
	return height_resolution + 1


## 高度场应有的元素数量
func expected_height_count() -> int:
	var r: int = row_points()
	return r * r


## 地表层应有的元素数量
func expected_splat_count() -> int:
	return height_resolution * height_resolution


## 数据自洽（缺数据就地重建，老地图/手改 JSON 都不会崩）
func ensure_arrays() -> void:
	if height_resolution < 4:
		height_resolution = DEFAULT_HEIGHT_RES
	var need: int = expected_height_count()
	if heightmap.size() != need:
		var old: PackedFloat32Array = heightmap
		heightmap = PackedFloat32Array()
		heightmap.resize(need)
		heightmap.fill(0.0)
		# 老数据如果只是分辨率不同，按比例采样搬过来，别让地图直接变平原
		if old.size() >= 4:
			var old_res: int = int(round(sqrt(float(old.size())))) - 1
			if old_res >= 3:
				var old_row: int = old_res + 1
				for gz in range(row_points()):
					var oz: int = clampi(int(round(float(gz) / float(height_resolution) * float(old_res))), 0, old_res)
					for gx in range(row_points()):
						var ox: int = clampi(int(round(float(gx) / float(height_resolution) * float(old_res))), 0, old_res)
						heightmap[gz * row_points() + gx] = old[oz * old_row + ox]
	var s_need: int = expected_splat_count()
	if splatmap.size() != s_need:
		splatmap = PackedByteArray()
		splatmap.resize(s_need)
		splatmap.fill(SPLAT_NONE)
	if camera_bounds.size == Vector2.ZERO:
		camera_bounds = Rect2(Vector2(-half_size(), -half_size()), Vector2(size, size))
	if not (water is Dictionary):
		water = {"enabled": false, "spots": []}


# ===========================================================================
# 高度采样（与 RtsTerrain 的对角线三角面插值保持同一套算法）
# ===========================================================================

## 格点高度（越界夹紧）
func grid_height(gx: int, gz: int) -> float:
	var r: int = row_points()
	var x: int = clampi(gx, 0, r - 1)
	var z: int = clampi(gz, 0, r - 1)
	var i: int = z * r + x
	if i < 0 or i >= heightmap.size():
		return 0.0
	return heightmap[i]


## 写格点高度（编辑器笔刷用；不做越界报错，直接忽略）
func set_grid_height(gx: int, gz: int, h: float) -> void:
	var r: int = row_points()
	if gx < 0 or gz < 0 or gx >= r or gz >= r:
		return
	var i: int = gz * r + gx
	if i >= 0 and i < heightmap.size():
		heightmap[i] = h


## 世界坐标高度（普通格沿 p00-p11 对角线拆两个三角，与地形网格一致）
func height_at(wx: float, wz: float) -> float:
	if heightmap.is_empty():
		return 0.0
	var c: float = cell_size()
	var half: float = half_size()
	var fx: float = (wx + half) / c
	var fz: float = (wz + half) / c
	var res: int = height_resolution
	var cx: int = clampi(floori(fx), 0, res - 1)
	var cz: int = clampi(floori(fz), 0, res - 1)
	var u: float = clampf(fx - float(cx), 0.0, 1.0)
	var v: float = clampf(fz - float(cz), 0.0, 1.0)
	var h00: float = grid_height(cx, cz)
	var h10: float = grid_height(cx + 1, cz)
	var h01: float = grid_height(cx, cz + 1)
	var h11: float = grid_height(cx + 1, cz + 1)
	if u >= v:
		return h00 + (h10 - h00) * u + (h11 - h10) * v
	return h00 + (h01 - h00) * v + (h11 - h01) * u


## 某点坡度（度）。可走性/校验用，中心差分与 RtsTerrain 一致。
func slope_degrees_at(wx: float, wz: float, eps: float = 0.75) -> float:
	var hx: float = height_at(wx + eps, wz) - height_at(wx - eps, wz)
	var hz: float = height_at(wx, wz + eps) - height_at(wx, wz - eps)
	return rad_to_deg(atan(sqrt(hx * hx + hz * hz) / (2.0 * eps)))


## 世界 XZ 是否在地图内（可留边距）
func in_bounds(p: Vector2, margin: float = 0.0) -> bool:
	var lim: float = half_size() - margin
	return absf(p.x) <= lim and absf(p.y) <= lim


## 世界坐标 → 高度场格点下标
func world_to_grid(wx: float, wz: float) -> Vector2i:
	var c: float = cell_size()
	var half: float = half_size()
	return Vector2i(clampi(int(round((wx + half) / c)), 0, height_resolution),
		clampi(int(round((wz + half) / c)), 0, height_resolution))


## 格点下标 → 世界坐标（格点，不是格心）
func grid_to_world(gx: int, gz: int) -> Vector2:
	var c: float = cell_size()
	var half: float = half_size()
	return Vector2(-half + float(gx) * c, -half + float(gz) * c)


# ===========================================================================
# 水面
# ===========================================================================

## 归一化后的水潭列表（永远返回数组，字段缺省补齐）
func water_spots() -> Array:
	var out: Array = []
	if not (water is Dictionary):
		return out
	var raw: Variant = (water as Dictionary).get("spots", [])
	if raw is Array:
		for s in raw:
			if s is Dictionary and (s as Dictionary).has("center"):
				var sp: Dictionary = s
				out.append({
					"center": sp.get("center", Vector2.ZERO),
					"radius": float(sp.get("radius", 6.0)),
					"level": float(sp.get("level", 0.0)),
				})
	return out


## 某世界点是否在水里（用高度与水面比较，坡上不会误判）
func is_water_at(p: Vector2) -> bool:
	for s in water_spots():
		var c: Vector2 = s["center"]
		var r: float = float(s["radius"])
		if p.distance_to(c) > r:
			continue
		if height_at(p.x, p.y) <= float(s["level"]):
			return true
	return false


## 把一处水潭写进 water（编辑器水面笔刷用）
func set_water_spot(center: Vector2, radius: float, level: float) -> void:
	water = {"enabled": true, "spots": [{"center": center, "radius": radius, "level": level}]}


func clear_water() -> void:
	water = {"enabled": false, "spots": []}


# ===========================================================================
# 地表层
# ===========================================================================

func splat_at(wx: float, wz: float) -> int:
	if splatmap.is_empty():
		return SPLAT_NONE
	var c: float = cell_size()
	var half: float = half_size()
	var gx: int = clampi(floori((wx + half) / c), 0, height_resolution - 1)
	var gz: int = clampi(floori((wz + half) / c), 0, height_resolution - 1)
	var i: int = gz * height_resolution + gx
	if i < 0 or i >= splatmap.size():
		return SPLAT_NONE
	return splatmap[i]


# ===========================================================================
# 对象
# ===========================================================================

func objects_of(category: int) -> Array:
	var out: Array = []
	for o in objects:
		if o != null and int(o.category) == category:
			out.append(o)
	return out


func add_object(obj: MapObject) -> MapObject:
	if obj == null:
		return null
	objects.append(obj)
	return obj


func remove_object(obj: MapObject) -> void:
	var idx: int = objects.find(obj)
	if idx >= 0:
		objects.remove_at(idx)


func region_by_id(rid: String) -> RegionDef:
	for r in regions:
		if r != null and r.id == rid:
			return r
	return null


func player_slot(id: int) -> PlayerSlot:
	for p in players:
		if p != null and p.id == id:
			return p
	return null


## 敌人槽位：第一个与 id=0 不同队伍、且不是 0 号槽的玩家
func enemy_slot() -> PlayerSlot:
	if players.is_empty():
		return null
	var own_team: int = players[0].team
	for p in players:
		if p != null and p.id != players[0].id and p.team != own_team:
			return p
	return null


## 最大/最小高度（编辑器状态栏与校验用）
func height_bounds() -> Vector2:
	if heightmap.is_empty():
		return Vector2.ZERO
	var lo: float = INF
	var hi: float = -INF
	for h in heightmap:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	if lo == INF:
		return Vector2.ZERO
	return Vector2(lo, hi)


# ===========================================================================
# 拷贝
# ===========================================================================

## 深拷贝（撤销/自动保存快照用；子资源逐个复制，避免共享引用）
func clone_def() -> MapDef:
	var d := MapDef.new()
	d.version = version
	d.size = size
	d.seed = seed
	d.biome = biome
	d.height_resolution = height_resolution
	d.heightmap = heightmap.duplicate()
	d.splatmap = splatmap.duplicate()
	d.water = water.duplicate(true)
	d.objects = []
	for o in objects:
		if o != null:
			d.objects.append(o.clone_obj())
	d.regions = []
	for r in regions:
		if r != null:
			d.regions.append(r.clone_region())
	d.players = []
	for p in players:
		if p != null:
			d.players.append(p.clone_slot())
	d.waves = []
	for w in waves:
		if w != null:
			d.waves.append(w.clone_wave())
	d.camera_bounds = camera_bounds
	d.victory = victory.duplicate(true)
	return d


# ===========================================================================
# 序列化（JSON 用；.tres 直接走 ResourceSaver）
# ===========================================================================

func to_dict() -> Dictionary:
	var objs: Array = []
	for o in objects:
		if o != null:
			objs.append(o.to_dict())
	var regs: Array = []
	for r in regions:
		if r != null:
			regs.append(r.to_dict())
	var pls: Array = []
	for p in players:
		if p != null:
			pls.append(p.to_dict())
	var wvs: Array = []
	for w in waves:
		if w != null:
			wvs.append(w.to_dict())
	var water_out: Dictionary = {"enabled": bool(water.get("enabled", false)), "spots": []}
	for s in water_spots():
		var c: Vector2 = s["center"]
		(water_out["spots"] as Array).append({
			"center": [c.x, c.y],
			"radius": float(s["radius"]),
			"level": float(s["level"]),
		})
	return {
		"version": version,
		"size": size,
		"seed": seed,
		"biome": biome,
		"height_resolution": height_resolution,
		"heightmap": Array(heightmap),
		"splatmap": Array(splatmap),
		"water": water_out,
		"objects": objs,
		"regions": regs,
		"players": pls,
		"waves": wvs,
		"camera_bounds": [camera_bounds.position.x, camera_bounds.position.y,
			camera_bounds.size.x, camera_bounds.size.y],
		"victory": victory.duplicate(true),
	}


## 从字典还原（缺字段一律补默认值 —— 老版本 JSON 不会炸）
static func from_dict(d: Dictionary) -> MapDef:
	var m := MapDef.new()
	m.version = int(d.get("version", CURRENT_VERSION))
	m.size = int(d.get("size", 160))
	m.seed = int(d.get("seed", 0))
	m.biome = String(d.get("biome", "temperate"))
	m.height_resolution = int(d.get("height_resolution", DEFAULT_HEIGHT_RES))
	var hm: Variant = d.get("heightmap", [])
	var arr := PackedFloat32Array()
	if hm is Array:
		arr.resize((hm as Array).size())
		for i in range((hm as Array).size()):
			arr[i] = float((hm as Array)[i])
	elif hm is PackedFloat32Array:
		arr = (hm as PackedFloat32Array).duplicate()
	m.heightmap = arr
	var sm: Variant = d.get("splatmap", [])
	var sarr := PackedByteArray()
	if sm is Array:
		sarr.resize((sm as Array).size())
		for i in range((sm as Array).size()):
			sarr[i] = int((sm as Array)[i])
	elif sm is PackedByteArray:
		sarr = (sm as PackedByteArray).duplicate()
	m.splatmap = sarr
	var wv: Variant = d.get("water", {})
	if wv is Dictionary:
		var spots_out: Array = []
		var raw: Variant = (wv as Dictionary).get("spots", [])
		if raw is Array:
			for s in raw:
				if s is Dictionary:
					var c: Variant = (s as Dictionary).get("center", [0, 0])
					var cv := Vector2.ZERO
					if c is Array and (c as Array).size() >= 2:
						cv = Vector2(float(c[0]), float(c[1]))
					elif c is Vector2:
						cv = c
					spots_out.append({
						"center": cv,
						"radius": float((s as Dictionary).get("radius", 6.0)),
						"level": float((s as Dictionary).get("level", 0.0)),
					})
		m.water = {"enabled": bool((wv as Dictionary).get("enabled", false)), "spots": spots_out}
	if d.has("objects") and d["objects"] is Array:
		for o in d["objects"]:
			if o is Dictionary:
				m.objects.append(MapObject.from_dict(o))
	if d.has("regions") and d["regions"] is Array:
		for r in d["regions"]:
			if r is Dictionary:
				m.regions.append(RegionDef.from_dict(r))
	if d.has("players") and d["players"] is Array:
		for p in d["players"]:
			if p is Dictionary:
				m.players.append(PlayerSlot.from_dict(p))
	if d.has("waves") and d["waves"] is Array:
		for w in d["waves"]:
			if w is Dictionary:
				m.waves.append(WaveDef.from_dict(w))
	var cb: Variant = d.get("camera_bounds", null)
	if cb is Array and (cb as Array).size() >= 4:
		m.camera_bounds = Rect2(float(cb[0]), float(cb[1]), float(cb[2]), float(cb[3]))
	else:
		m.camera_bounds = Rect2(Vector2(-m.half_size(), -m.half_size()), Vector2(m.size, m.size))
	var vic: Variant = d.get("victory", null)
	if vic is Dictionary:
		m.victory = (vic as Dictionary).duplicate(true)
	m.ensure_arrays()
	return m

# ===========================================================================
# 由程序化地图反推 MapDef（默认地图也能统一出口径）
# ===========================================================================

## MapGenerator.MapData → MapDef。默认 200m 程序化地图、或者以后任何生成器，
## 都能通过这一个函数变成同一套数据（"一套骨头穿两件衣裳"）。
static func from_map_data(data: MapGenerator.MapData, cfg: GameConfig = null) -> MapDef:
	var m := MapDef.new()
	if data == null:
		return m
	m.size = int(round(data.size))
	# 生成器的分辨率与 MapDef 固定分辨率可能不同，统一重采样到 128
	m.height_resolution = DEFAULT_HEIGHT_RES
	m.ensure_arrays()
	var c: float = m.cell_size()
	var half: float = m.half_size()
	for gz in range(m.row_points()):
		for gx in range(m.row_points()):
			var wx: float = -half + float(gx) * c
			var wz: float = -half + float(gz) * c
			m.heightmap[gz * m.row_points() + gx] = data.height_at(wx, wz)
	if data.pond_radius > 0.0:
		m.set_water_spot(data.pond_center, data.pond_radius, data.pond_level)
	for t in data.trees:
		m.objects.append(MapObject.make(&"tree", MapObject.Category.RESOURCE,
			Vector3(t.x, m.height_at(t.x, t.y), t.y), 0.0, 1.0, -1))
	for mn in data.mines:
		m.objects.append(MapObject.make(&"goldmine", MapObject.Category.RESOURCE,
			Vector3(mn.x, m.height_at(mn.x, mn.y), mn.y), 0.0, 1.0, -1))
	for r in data.rocks:
		var p2: Vector2 = r.get("pos", Vector2.ZERO)
		m.objects.append(MapObject.make(&"岩石", MapObject.Category.DOODAD,
			Vector3(p2.x, m.height_at(p2.x, p2.y), p2.y),
			float(r.get("rot", 0.0)), float(r.get("scale", 1.0)), -1))
	if cfg != null:
		var p0 := PlayerSlot.make(0, "player", cfg.player_color, 0, cfg.player_base_pos, cfg.start_gold, cfg.start_wood)
		var p1 := PlayerSlot.make(1, "enemy", cfg.enemy_color, 1, cfg.enemy_base_pos, cfg.start_gold, cfg.start_wood)
		var plist: Array[PlayerSlot] = []
		plist.append(p0)
		plist.append(p1)
		m.players = plist
		# 开局建筑也落成对象，编辑器一打开就能看到基地布局
		for id in cfg.player_buildings.keys():
			var off: Vector2 = cfg.player_buildings[id]
			var wp: Vector2 = cfg.player_base_pos + off
			m.objects.append(MapObject.make(StringName(id), MapObject.Category.BUILDING,
				Vector3(wp.x, m.height_at(wp.x, wp.y), wp.y), PI, 1.0, 0))
		for id in cfg.enemy_buildings.keys():
			var off2: Vector2 = cfg.enemy_buildings[id]
			var wp2: Vector2 = cfg.enemy_base_pos + off2
			m.objects.append(MapObject.make(StringName(id), MapObject.Category.BUILDING,
				Vector3(wp2.x, m.height_at(wp2.x, wp2.y), wp2.y), PI, 1.0, 1))
	m.camera_bounds = Rect2(Vector2(-m.half_size(), -m.half_size()), Vector2(m.size, m.size))
	return m
