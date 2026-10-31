class_name MapGenerator
extends RefCounted
## **地图生成器**：程序化产出一张 200m、带台地 / 峡谷 / 关口的点对称战场。
##
## 产出：
##   - 高度场（给 RtsTerrain 建网格）
##   - 可走性数组（1 米一格，给 GridPathfinder）
##   - 树 / 岩石 / 金矿的落点 + 地表草丛/碎石装饰点
##   - 台地 / 坡道 / 沟壑 / 关口 / 平地保护区 的元数据（给地形、镜头、自检用）
##
## 全部由 @@Cfg.game.map_seed@@ 决定，**同种子必定同地图**（测试可复现）。
##
## 布局（200m，中心原点，点对称）：
##   · 玩家基地西南 (-62, 58)，敌人基地东北 (62, -58)；
##   · 正中央一座 7.4m 高的台地，两条坡道分别朝向双方基地；
##   · 双方基地通往台地的路上各有一道带缺口的岩脊（choke）；
##   · 西北 / 东南各一条 6.5m 深的峡谷，中间有天然石桥，两端可绕行；
##   · 地图外圈用 26m 高山脊围死；
##   · 基地 / 金矿 / 坡道口 / 台地顶全部压平（footprint 高差 < 0.5m）。

## 地形细分之外的常量（不随配置走的世界规则）
const RAMP_HALF_ANGLE: float = 0.155      ## 坡道半角（弧度），台地边缘处约 7.5m 宽
const RAMP_LEN: float = 18.0              ## 坡道水平长度（米）
const MESA_SHOULDER: float = 4.5          ## 台地顶面到崖肩保持平的宽度
const MESA_FOOT: float = 1.0              ## 崖脚再向外多铺 1m
const GORGE_WALL: float = 4.0             ## 峡谷崖壁水平宽度
const GORGE_WIGGLE: float = 3.0           ## 峡谷中心线摆动幅度
const GORGE_BRIDGE_HALF: float = 0.055    ## 石桥沿峡谷方向的半宽（比例）
const GORGE_END_FADE: float = 0.055       ## 峡谷两端收口长度（比例）
const SLOPE_WALK_MAX: float = 1.15        ## 1.2m 跨度内高差超过它 = 不可走
## 边界内缩（不可走）。
## v3.2 从 5m 提到 16m：外圈山脊删掉以后，边缘是**平的**，如果可走区一直铺到 5m，
## 单位能走进外圈林带，A* 会在一堆"树缝只有 1 格宽"的地方反复试错（实测寻路耗时翻倍）。
## 现在林带（距边界 4~17m）整段落在地形可走区之外，既挡不住视线也不参与寻路。
const EDGE_MARGIN: float = 16.0
const EDGE_START: float = 82.0            ## 外圈山脊起点（切比雪夫距离）
const POND_RADIUS: float = 7.0            ## 峡谷水潭半径


## 生成结果
class MapData:
	var size: float = 200.0
	var resolution: int = 128
	## 生态 id：决定地形材质的 biome 换色（编辑器/游戏共用同一份，别各画一套）
	var biome: String = "temperate"
	## (resolution+1)^2 的高度场
	var heights: PackedFloat32Array = PackedFloat32Array()
	## size×size 的可走性（1=可走），索引 z * size + x
	var walkable: PackedByteArray = PackedByteArray()
	## 树的落点（世界 XZ）
	var trees: Array[Vector2] = []
	## 每棵树的外观参数（与 trees 同序、同长度；空 = 由落点反推种子）。
	## 元素：{"season": "春/夏/秋/冬"（可空）, "seed": int, "yaw": float}
	## 程序化生成的地图不填这里（省内存），编辑器存的地图才会带着种子进来。
	var trees_proc: Array = []
	## 岩石落点（世界坐标 + 缩放）
	var rocks: Array = []
	## 金矿落点（世界 XZ）
	var mines: Array[Vector2] = []
	## 水潭中心与半径
	var pond_center: Vector2 = Vector2.ZERO
	var pond_radius: float = 0.0
	var pond_level: float = -0.5

	# ------------------------------------------------------------------
	# 新增字段（RIDGE / 测试可以读；旧字段全部保留）
	# ------------------------------------------------------------------
	## 中央台地 {center: Vector2, radius: float, top: float}
	var plateau: Dictionary = {}
	## 台地顶面可站立面积（平方米）
	var plateau_area: float = 0.0
	## 坡道 [{angle, dir, mouth: Vector2, mouth_h, top_pos: Vector2, width}]
	var ramps: Array = []
	## 沟壑 [{a, b, width, depth, bridge: Vector2}]
	var gorges: Array = []
	## 关口 [{pos: Vector2, radius: float, kind: String}]
	var chokes: Array = []
	## 压平保护区 [{pos: Vector2, radius: float, height: float, kind: String}]
	var flat_zones: Array = []
	## 出生安全带 [{pos: Vector2, radius: float, height: float}]
	var spawn_safe: Array = []
	## 树簇中心（调试 / 自检）
	var clusters: Array = []
	## 地表草丛 [{pos: Vector3, scale: float, rot: float}]
	var grass: Array = []
	## 地表碎石 [{pos: Vector3, scale: float, rot: float}]
	var rubble: Array = []
	## 土路 [{pts: PackedVector2Array, width: float, kind: String}]
	## kind: main / branch / trail；纯视觉（不能改高度场，也不写寻路格）
	var roads: Array = []
	## 台地顶集结场 [{pos: Vector2, radius: float}]
	var plazas: Array = []
	## 纯视觉装饰 kind(String) -> [{pos: Vector3, scale, rot, tilt: Vector2}]
	## 全部由 MultiMesh 合批绘制，**不参与碰撞 / 不写 walkable**
	var decor: Dictionary = {}
	## 生成统计与完整性检查结果
	var stats: Dictionary = {}

	# ------------------------------------------------------------------
	# 竞技场（多队地图）专用字段
	# ------------------------------------------------------------------
	## 每个出生点的世界坐标（下标 = 阵营槽位 0..N-1）
	var base_points: Array[Vector2] = []
	## 出生平台半径（平台内**严格水平**，保证建筑占地高差 = 0）
	var base_pad: float = 24.0
	## 可走区域离地图边界的距离（米）。0 = 用 MapDef/MapLoader 的默认值。
	## 竞技场图 14m、默认图 16m —— 这是"外圈林带不参与寻路"的实现方式，
	## 不存进地图文件的话，从文件读回来的图可走区会比原图多出一整圈。
	var edge_keep_out: float = 0.0
	## 地块网格：边长 mat_cells 个 8m 格；mat_nodes 是 (mat_cells+1)² 个**格点**的 0/255
	## （魔兽 3 口径：材质存在共享格点上，一格读它四个角）
	var mat_cells: int = 0
	var mat_nodes: PackedByteArray = PackedByteArray()
	## 地块一格的边长（米）
	var mat_tile: float = 8.0
	## 是否要远景山脊（竞技场图关掉：那一圈灰锥在 224m 图上会贴在画面边上）
	var far_ridges: bool = true

	## 取某个世界点所在**格点**的材质（0=草 255=泥）。给装饰避让/自检用；
	## 渲染侧走 shader（读四角做硬边过渡），这里只取最近的格点。
	func mat_at(wx: float, wz: float) -> int:
		if mat_nodes.is_empty() or mat_cells <= 0:
			return 0
		var n: int = mat_cells + 1
		if mat_nodes.size() != n * n:
			return 0
		var half: float = size * 0.5
		var step: float = size / float(mat_cells)
		var i: int = clampi(int(round((wx + half) / step)), 0, n - 1)
		var j: int = clampi(int(round((wz + half) / step)), 0, n - 1)
		return int(mat_nodes[j * n + i])

	## 装饰点总数（自检/性能看板用）
	func decor_count() -> int:
		var n: int = 0
		for k in decor:
			n += (decor[k] as Array).size()
		return n

	## 取地形高度（双线性，和 RtsTerrain 算法一致）
	func height_at(wx: float, wz: float) -> float:
		var cell: float = size / float(resolution)
		var half: float = size * 0.5
		var fx: float = (wx + half) / cell
		var fz: float = (wz + half) / cell
		var x0: int = clampi(floori(fx), 0, resolution)
		var z0: int = clampi(floori(fz), 0, resolution)
		var x1: int = mini(x0 + 1, resolution)
		var z1: int = mini(z0 + 1, resolution)
		var tx: float = clampf(fx - float(x0), 0.0, 1.0)
		var tz: float = clampf(fz - float(z0), 0.0, 1.0)
		var row: int = resolution + 1
		var top: float = lerpf(heights[z0 * row + x0], heights[z0 * row + x1], tx)
		var bottom: float = lerpf(heights[z1 * row + x0], heights[z1 * row + x1], tx)
		return lerpf(top, bottom, tz)

	## 某世界点是否在可走格
	func is_walkable_at(wx: float, wz: float) -> bool:
		var w: int = int(size)
		var cx: int = int(floor(wx + size * 0.5))
		var cz: int = int(floor(wz + size * 0.5))
		if cx < 0 or cz < 0 or cx >= w or cz >= w:
			return false
		return walkable[cz * w + cx] != 0


## ===========================================================================
## 生成整张地图
## ===========================================================================
static func build(cfg: GameConfig) -> MapData:
	var t_start: int = Time.get_ticks_usec()
	var data := MapData.new()
	data.size = cfg.map_size
	data.edge_keep_out = EDGE_MARGIN
	data.resolution = maxi(16, cfg.terrain_resolution)
	var res: int = data.resolution
	var row: int = res + 1
	var half: float = data.size * 0.5
	var cell: float = data.size / float(res)

	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.map_seed

	# 三层噪声：低频起伏 / 细节 / 外圈山脊的碎形
	var n_low := FastNoiseLite.new()
	n_low.seed = cfg.map_seed
	n_low.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_low.frequency = 0.010
	n_low.fractal_octaves = 3
	n_low.fractal_gain = 0.45
	var n_detail := FastNoiseLite.new()
	n_detail.seed = cfg.map_seed + 7
	n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_detail.frequency = 0.045
	n_detail.fractal_octaves = 2
	var n_rim := FastNoiseLite.new()
	n_rim.seed = cfg.map_seed + 19
	n_rim.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n_rim.frequency = 0.02

	var base_a: Vector2 = cfg.player_base_pos
	var base_b: Vector2 = cfg.enemy_base_pos

	# --- 0. 先把"地形特征"摆出来（高度场、落位、自检都吃这一份） ---
	var ramps: Array = _make_ramps(cfg, base_a, base_b, n_low, n_detail)
	var gorges: Array = _make_gorges(cfg, rng)
	var ridges: Array = _make_ridges(cfg, base_a, base_b)
	var mines: Array[Vector2] = _make_mines(cfg, base_a, base_b)
	data.mines = mines
	data.ramps = ramps
	data.gorges = gorges

	# --- 1. 高度场 ---
	data.heights.resize(row * row)
	var h_min: float = INF
	var h_max: float = -INF
	for gz in range(row):
		for gx in range(row):
			var p := Vector2(-half + gx * cell, -half + gz * cell)
			var h: float = _lowland(p, n_low, n_detail, cfg)
			h += _rim_height(p, n_rim, cfg)
			h = maxf(h, _mesa_height(p, cfg, n_detail))
			h = maxf(h, _ramp_surface(p, cfg, ramps))
			for rg in ridges:
				var rh: float = _ridge_delta(p, rg)
				if rh > 0.0:
					h += rh
			for gg in gorges:
				h -= _gorge_depth(p, gg)
			data.heights[gz * row + gx] = h
			h_min = minf(h_min, h)
			h_max = maxf(h_max, h)

	# --- 2. 压平关键点（先基地，再金矿/坡道口；目标高度一律取"压平前"的地面） ---
	var zones: Array = []
	var base_zones: Array = _make_base_zones(cfg, base_a, base_b)
	for z in base_zones:
		var bt: float = data.height_at(z["pos"].x, z["pos"].y)
		z["height"] = bt
		_flatten_heights(data, z["pos"], z["full"], z["blend"], bt)
	var prop_zones: Array = _make_prop_flat_zones(mines, ramps)
	for z in prop_zones:
		var pt: float = data.height_at(z["pos"].x, z["pos"].y)
		z["height"] = pt
		_flatten_heights(data, z["pos"], z["full"], z["blend"], pt)
	zones = base_zones + prop_zones
	_apply_flat_zone_heights(data, zones)
	data.flat_zones = zones
	# 压平会吃掉坡道：压完再把坡道面盖回去（这是坡道不通的根因，别删）
	_reapply_ramps(data, cfg, ramps)
	# 压平也会把岩脊（石门）抹平 —— 坡道落脚区的 blend 正好盖在脊上。
	# 脊是"加法特征"，压完按原始地形重算一遍再取 max，石门才立得起来。
	_reapply_ridges(data, cfg, ramps, ridges, gorges, n_low, n_detail, n_rim)

	# --- 3. 峡谷底部的水潭（水在沟壑里，不占战场空间） ---
	data.pond_radius = POND_RADIUS
	data.pond_center = _gorge_point(gorges[0], 0.30)
	_carve_bowl(data, data.pond_center, POND_RADIUS + 2.0, 1.8)
	data.pond_level = data.height_at(data.pond_center.x, data.pond_center.y) + 1.0

	# --- 4. 可走性（地形层） ---
	var w: int = int(data.size)
	data.walkable.resize(w * w)
	_recompute_walkable(data, cfg, Vector2i(0, 0), Vector2i(w, w))

	# --- 5. 连通性检查 + 自动修路（真修地形，不是放宽可走性） ---
	var targets: Array = _connectivity_targets(cfg, base_a, base_b, mines, ramps, gorges)
	var conn: Dictionary = _ensure_connectivity(data, cfg, targets)
	data.stats["connect_attempts"] = conn.get("attempts", 0)
	data.stats["connect_carves"] = conn.get("carves", 0)
	data.stats["connect_bad"] = conn.get("bad_kinds", [])

	# --- 5.5 土路网（纯数据：主路 / 采矿支路 / 峡谷绕行小径；不碰高度场） ---
	data.roads = _make_roads(cfg, ramps, ridges, gorges)
	data.plazas.append({"pos": Vector2.ZERO, "radius": 6.8})

	# --- 6. 落资源（树 / 岩石），树只长在平地上 ---
	data.trees = _place_trees(data, cfg, rng, mines, ramps, gorges)
	_place_rocks(data, cfg, rng, mines)
	_place_decor(data, cfg, rng, mines, ridges)

	# --- 7. 把道具写进可走性，并做最终连通性检查 ---
	var terrain_walk: PackedByteArray = data.walkable.duplicate()
	var unreachable_trees: int = 0
	var prop_attempts: int = 0
	for attempt in range(4):
		prop_attempts = attempt + 1
		data.walkable = terrain_walk.duplicate()
		_apply_prop_blocks(data)
		var removed: Array = _drop_unreachable_trees(data, cfg)
		unreachable_trees += removed.size()
		if removed.is_empty():
			break
	data.stats["prop_attempts"] = prop_attempts
	data.stats["unreachable_trees"] = unreachable_trees

	# --- 7.5 土路按最终可走性切段（树/岩石/金矿都落位后再切，保证画出来就能走） ---
	data.roads = _sanitize_roads(data, data.roads)

	# --- 8. 统计 ---
	_finish_stats(data, cfg, t_start, h_min, h_max, base_a, base_b)

	# --- 9. 地表细节层（土路 / 草丛 / 营地杂物；纯视觉，找不到关卡会自己退出） ---
	# 挂在生成器末尾而不是关卡里：关卡脚本归 RIDGE 管，这一层只吃 MapData。
	RtsGroundDetail.install(data)
	return data


## ===========================================================================
## 地形特征
## ===========================================================================

## 外圈：**平坦**（用户口径："地图边缘要正常，不要一个大山谷把地图包起来"）。
##
## 历史：
##   v1 是从 EDGE_START 单调抬到 16~26m 的等高缓坡（"浴缸壁"）；
##   v3.1 给它乘了低频起伏 + 山肩，变成"一圈有高有低的山"——**仍然是圈**，
##   只要镜头压低看地平线，地图四周永远是一道墙，这就是用户这次又提一次的原因。
## v3.2：整圈山脊**彻底删掉**。地形在边缘保持正常起伏（低频噪声），
##   边界感交给两件不改变地貌的东西：
##     1) 可走性掩码（EDGE_MARGIN = 5m 内不可走，单位永远走不出去）；
##     2) 外圈林带（_place_edge_belt，树是实体，读作"森林边缘"而不是"围栏"）。
## 保留函数签名：`_reapply_ridges` 等调用点不用动。
static func _rim_height(_p: Vector2, _n_rim: FastNoiseLite, _cfg: GameConfig) -> float:
	return 0.0


## 低频起伏
static func _lowland(p: Vector2, n_low: FastNoiseLite, n_detail: FastNoiseLite, cfg: GameConfig) -> float:
	var h: float = n_low.get_noise_2d(p.x, p.y) * cfg.terrain_amplitude
	h += n_detail.get_noise_2d(p.x, p.y) * cfg.terrain_amplitude * 0.32
	return h


## 台地形状（带三/五个谐波，避免完美圆形）
static func _mesa_shape(theta: float, r0: float) -> float:
	var k: float = r0 / 24.0
	return r0 + (3.2 * sin(3.0 * theta + 0.7) + 1.8 * sin(5.0 * theta + 2.1)) * k


## 台地 + 坡道的高度（不成形返回 -INF，调用方 maxf 掉）
static func _mesa_height(p: Vector2, cfg: GameConfig, n_detail: FastNoiseLite) -> float:
	var rm: float = p.length()
	var ang: float = p.angle()
	var r0: float = cfg.map_mesa_radius
	var top: float = cfg.map_mesa_height
	var rad: float = _mesa_shape(ang, r0)
	var h: float = -INF
	# 台地本体
	var top_edge: float = rad - MESA_SHOULDER
	if rm <= top_edge:
		h = top + n_detail.get_noise_2d(p.x * 2.0, p.y * 2.0) * 0.22
	elif rm < rad + MESA_FOOT:
		var t: float = (rm - top_edge) / (MESA_SHOULDER + MESA_FOOT)
		h = top * (1.0 - clampf(t, 0.0, 1.0))
	return h


## 坡道表面（独立函数）：从台地顶肩起坡，水平跑满 RAMP_LEN 落到坡道口。
## 之所以单独拆出来：压平保护区会把坡道抹平，压平之后要用这个函数把坡道重新盖回去。
static func _ramp_surface(p: Vector2, cfg: GameConfig, ramps: Array) -> float:
	var rm: float = p.length()
	var ang: float = p.angle()
	var best: float = -INF
	for rp in ramps:
		var da: float = absf(_angle_delta(ang, rp["angle"]))
		if da > RAMP_HALF_ANGLE:
			continue
		var rad_at: float = _mesa_shape(rp["angle"], cfg.map_mesa_radius)
		var s: float = (rm - (rad_at - MESA_SHOULDER)) / RAMP_LEN
		if s < 0.0 or s > 1.0:
			continue
		var rh: float = lerpf(cfg.map_mesa_height, rp["mouth_h"], _sstep(0.0, 1.0, s))
		best = maxf(best, rh)
	return best


## 压平之后把坡道重新盖回高度场（坡道面永远高于被压平的落脚区）
static func _reapply_ramps(data: MapData, cfg: GameConfig, ramps: Array) -> void:
	var res: int = data.resolution
	var row: int = res + 1
	var cell: float = data.size / float(res)
	var half: float = data.size * 0.5
	for gz in range(row):
		for gx in range(row):
			var p := Vector2(-half + gx * cell, -half + gz * cell)
			var rh: float = _ramp_surface(p, cfg, ramps)
			if rh <= -INF:
				continue
			var i: int = gz * row + gx
			if rh > data.heights[i]:
				data.heights[i] = rh


## 压平之后把石门岩脊重新盖回去（和坡道同理，脊也是被压平抹掉的特征）。
## 目标高度 = 未压平的地面 + 脊增量，只在脊真正存在的格子上取 max。
static func _reapply_ridges(data: MapData, cfg: GameConfig, ramps: Array, ridges: Array,
		gorges: Array, n_low: FastNoiseLite, n_detail: FastNoiseLite,
		n_rim: FastNoiseLite) -> void:
	var res: int = data.resolution
	var row: int = res + 1
	var cell: float = data.size / float(res)
	var half: float = data.size * 0.5
	for gz in range(row):
		for gx in range(row):
			var p := Vector2(-half + gx * cell, -half + gz * cell)
			var add: float = 0.0
			for rg in ridges:
				add = maxf(add, _ridge_delta(p, rg))
			if add <= 0.02:
				continue
			var base: float = _lowland(p, n_low, n_detail, cfg)
			base += _rim_height(p, n_rim, cfg)
			base = maxf(base, _mesa_height(p, cfg, n_detail))
			base = maxf(base, _ramp_surface(p, cfg, ramps))
			for gg in gorges:
				base -= _gorge_depth(p, gg)
			var target: float = base + add
			var i: int = gz * row + gx
			if target > data.heights[i]:
				data.heights[i] = target


## 峡谷：沿 a→b 的带摆动的深槽，中间留天然石桥，两端收口
static func _gorge_depth(p: Vector2, g: Dictionary) -> float:
	var a: Vector2 = g["a"]
	var b: Vector2 = g["b"]
	var ab: Vector2 = b - a
	var length: float = ab.length()
	if length < 0.001:
		return 0.0
	var dir: Vector2 = ab / length
	var nrm := Vector2(-dir.y, dir.x)
	var ap: Vector2 = p - a
	var t: float = ap.dot(dir) / length
	if t <= 0.0 or t >= 1.0:
		return 0.0
	var perp: float = ap.dot(nrm)
	var wob: float = GORGE_WIGGLE * sin(t * 5.2 + float(g["phase"]))
	var dist: float = absf(perp - wob)
	var half_w: float = float(g["width"]) * 0.5
	if dist >= half_w:
		return 0.0
	var wall: float = clampf((half_w - dist) / GORGE_WALL, 0.0, 1.0)
	var d: float = float(g["depth"]) * wall
	# 两端收口（地形自己长回来，形成绕行）
	d *= _sstep(0.0, GORGE_END_FADE, t)
	d *= _sstep(0.0, GORGE_END_FADE, 1.0 - t)
	# 中间石桥
	var bt: float = absf(t - 0.5)
	d *= _sstep(GORGE_BRIDGE_HALF * 0.5, GORGE_BRIDGE_HALF, bt)
	return d


## 岩脊（基地→台地路上的关口）：带缺口的鼓包
##
## 注意：`gap` 是**米**，这里换算成沿脊的归一化半宽再算缺口。
## 早期版本直接把 5.2 米当归一化值传进 sstep，结果 |t-0.5| 永远小于阈值，
## 整条岩脊的高度被乘成 0 —— 地图上就只剩"元数据关口"，地面是平的。
static func _ridge_delta(p: Vector2, rg: Dictionary) -> float:
	var a: Vector2 = rg["a"]
	var b: Vector2 = rg["b"]
	var ab: Vector2 = b - a
	var length: float = ab.length()
	if length < 0.001:
		return 0.0
	var dir: Vector2 = ab / length
	var ap: Vector2 = p - a
	var proj: float = ap.dot(dir)
	var t: float = clampf(proj / length, 0.0, 1.0)
	var closest: Vector2 = a + dir * proj
	var dist: float = p.distance_to(closest)
	var prof: float = 1.0 - _sstep(float(rg["radius"]) * 0.62, float(rg["radius"]), dist)
	var gap_half: float = clampf(float(rg["gap"]) / maxf(length, 1.0), 0.02, 0.42)
	var gap: float = 1.0 - _sstep(gap_half * 0.55, gap_half, absf(t - 0.5))
	return float(rg["height"]) * prof * (1.0 - gap)


## 坡道描述（必须先于高度场建好：台地高度依赖坡道口高度）
static func _make_ramps(cfg: GameConfig, base_a: Vector2, base_b: Vector2,
		n_low: FastNoiseLite, n_detail: FastNoiseLite) -> Array:
	var out: Array = []
	for b in [base_a, base_b]:
		var dir: Vector2 = Vector2(b.x, b.y).normalized()
		var ang: float = dir.angle()
		var rad_at: float = _mesa_shape(ang, cfg.map_mesa_radius)
		# 坡道从顶肩起坡，水平跑满 RAMP_LEN；坡道口就是终点（和压平保护区对齐）
		var mouth: Vector2 = dir * (rad_at - MESA_SHOULDER + RAMP_LEN)
		var mouth_h: float = _lowland(mouth, n_low, n_detail, cfg)
		var top_pos: Vector2 = dir * (rad_at - MESA_SHOULDER * 1.5)
		out.append({
			"angle": ang,
			"dir": dir,
			"mouth": mouth,
			"mouth_h": mouth_h,
			"top_pos": top_pos,
			"width": 2.0 * tan(RAMP_HALF_ANGLE) * rad_at,
		})
	return out


## 峡谷描述（点对称：一条主峡谷 + 它的镜像）
static func _make_gorges(cfg: GameConfig, rng: RandomNumberGenerator) -> Array:
	var s: float = cfg.map_size
	var a := Vector2(-s * 0.36, -s * 0.08)
	var b := Vector2(-s * 0.08, -s * 0.36)
	var phase: float = rng.randf_range(0.0, TAU)
	var out: Array = []
	out.append({
		"a": a, "b": b, "width": cfg.map_gorge_width, "depth": cfg.map_gorge_depth,
		"phase": phase, "bridge": _seg_point(a, b, 0.5),
	})
	out.append({
		"a": -a, "b": -b, "width": cfg.map_gorge_width, "depth": cfg.map_gorge_depth,
		"phase": phase + 1.7, "bridge": _seg_point(-a, -b, 0.5),
	})
	return out


## 岩脊描述：每方基地 → 台地 的路上，垂直于行军方向一道带缺口的脊。
## gap = 缺口净宽（米）：8.8m 刚好够一队兵并排挤过去，两侧崖壁 3.2m 高，
## 视觉上就是一道"石门"，也是寻路意义上的 choke。
static func _make_ridges(cfg: GameConfig, base_a: Vector2, base_b: Vector2) -> Array:
	var out: Array = []
	for b in [base_a, base_b]:
		var to_center: Vector2 = (Vector2.ZERO - Vector2(b.x, b.y)).normalized()
		var perp := Vector2(-to_center.y, to_center.x)
		var c: Vector2 = Vector2(b.x, b.y) + to_center * 32.0
		out.append({
			"a": c + perp * 15.0,
			"b": c - perp * 15.0,
			"height": 3.2,
			"radius": 3.8,
			"gap": 4.4,
			"center": c,
			"dir": to_center,
			"perp": perp,
		})
	return out


## 金矿：双方基地各一座（点对称），两条峡谷内侧各一座富矿，中央台地顶一座
static func _make_mines(cfg: GameConfig, base_a: Vector2, base_b: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	out.append(base_a + cfg.gold_mine_offset)
	out.append(base_b - cfg.gold_mine_offset)
	out.append(Vector2(0.0, 0.0))
	var s: float = cfg.map_size
	out.append(Vector2(-s * 0.29, -s * 0.29))
	out.append(Vector2(s * 0.29, s * 0.29))
	return out


# ===========================================================================
# 土路（纯视觉）
# ===========================================================================
## 土路网：主路（双方基地 → 石门 → 坡道 → 台地中心 → 对方基地）、
## 采矿支路（基地 → 门口金矿）、峡谷绕行小径（沿谷外侧绕过深沟）。
##
## 设计原则：
##   · 全部走"已经可走"的地方（基地平地 / 石门缺口 / 坡道 / 台地顶）；
##   · 只用几何生成，不消耗 rng、不改高度场，因此不影响地形与确定性；
##   · 生成后再按 walkable 切段，画出来的每一段都踩在能走的地面上。
static func _make_roads(cfg: GameConfig, ramps: Array, ridges: Array, gorges: Array) -> Array:
	var out: Array = []
	if ramps.size() < 2 or ridges.size() < 2:
		return out
	var base_a: Vector2 = cfg.player_base_pos
	var to_center: Vector2 = (-base_a).normalized()
	# 半程路点（基地 → 出营地 → 石门 → 坡道口 → 坡顶）；全部落在同一条射线上
	var half: PackedVector2Array = PackedVector2Array()
	half.append(base_a)
	half.append(base_a + to_center * 15.0)
	half.append(ridges[0]["center"])
	half.append(ramps[0]["mouth"])
	half.append(ramps[0]["top_pos"])
	var main_pts: PackedVector2Array = PackedVector2Array()
	main_pts.append_array(half)
	main_pts.append(Vector2.ZERO)
	for i in range(half.size() - 1, -1, -1):
		main_pts.append(-half[i])
	out.append({"pts": _resample_polyline(main_pts, 2.0),
		"width": cfg.map_road_width, "kind": "main"})
	# 采矿支路
	var pairs: Array = [[base_a, base_a + cfg.gold_mine_offset],
		[cfg.enemy_base_pos, cfg.enemy_base_pos - cfg.gold_mine_offset]]
	for pr in pairs:
		var b: Vector2 = pr[0]
		var m: Vector2 = pr[1]
		out.append({"pts": _resample_polyline(PackedVector2Array([b, b.lerp(m, 0.5), m]), 2.0),
			"width": cfg.map_road_branch_width, "kind": "branch"})
	# 峡谷绕行小径：沿谷外侧 11.5m 绕过去
	for g in gorges:
		out.append({"pts": _resample_polyline(_gorge_detour(g), 2.0),
			"width": cfg.map_road_trail_width, "kind": "trail"})
	return out


## 按弧长重采样折线（每 step 米一个点，含首尾）。
## 不做平滑：主路是一条射线，本来就直；绕行小径的拐点由采样密度决定。
static func _resample_polyline(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if pts.size() < 2:
		return pts
	out.append(pts[0])
	var carry: float = 0.0
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg: float = a.distance_to(b)
		if seg < 0.001:
			continue
		var t: float = step - carry
		while t < seg:
			out.append(a.lerp(b, t / seg))
			t += step
		carry = seg - (t - step)
	if out[out.size() - 1].distance_to(pts[pts.size() - 1]) > 0.05:
		out.append(pts[pts.size() - 1])
	return out


## 绕一条峡谷外侧的小径（U 形，两端接回谷口绕行点）
static func _gorge_detour(g: Dictionary) -> PackedVector2Array:
	var a: Vector2 = g["a"]
	var b: Vector2 = g["b"]
	var dir: Vector2 = (b - a).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	var off: float = 11.5
	# 取"离地图中心更远"的那一侧当外圈
	if (a + nrm * off).length() < (a - nrm * off).length():
		nrm = -nrm
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(a - dir * 6.0)
	var n: int = 12
	for i in range(n + 1):
		var t: float = lerpf(0.04, 0.96, float(i) / float(n))
		pts.append(_gorge_point(g, t) + nrm * off)
	pts.append(b + dir * 6.0)
	return pts


## 按可走性把土路切成若干段（不可走 / 太陡的采样点断开），丢掉太短的碎片。
## 这样渲染层永远不需要自己判地形——画出来的都是能走的土。
static func _sanitize_roads(data: MapData, roads: Array) -> Array:
	var out: Array = []
	for rd in roads:
		var src: PackedVector2Array = rd["pts"]
		var run: PackedVector2Array = PackedVector2Array()
		for p in src:
			var ok: bool = data.is_walkable_at(p.x, p.y) and _terrain_slope(data, p) < 0.85
			if ok:
				run.append(p)
			else:
				if run.size() >= 2:
					out.append({"pts": run, "width": rd["width"], "kind": rd["kind"]})
				run = PackedVector2Array()
		if run.size() >= 2:
			out.append({"pts": run, "width": rd["width"], "kind": rd["kind"]})
	return out


## 点到最近土路中心线的距离（装饰避让用）
static func road_distance(data: MapData, p: Vector2) -> float:
	var best: float = 9999.0
	for rd in data.roads:
		var pts: PackedVector2Array = rd["pts"]
		for i in range(pts.size() - 1):
			var d: float = _dist_to_segment(p, pts[i], pts[i + 1])
			if d < best:
				best = d
				if best < 0.05:
					return best
	return best


## 压平保护区（第一批）：双方基地。出生点在基地压平半径内，不用单独再压一次
## （单独压会用自己的目标高度覆盖基地平地，反而压出一道台阶）。
static func _make_base_zones(cfg: GameConfig, base_a: Vector2, base_b: Vector2) -> Array:
	var out: Array = []
	for b in [base_a, base_b]:
		out.append({"pos": b, "full": cfg.map_base_flat, "blend": cfg.map_base_flat + 12.0,
			"kind": "base", "radius": cfg.map_base_flat})
	return out


## 压平保护区（第二批）：金矿 / 坡道口。基地压完后再取目标高度，避免互相踩踏。
static func _make_prop_flat_zones(mines: Array[Vector2], ramps: Array) -> Array:
	var out: Array = []
	for m in mines:
		out.append({"pos": m, "full": 5.0, "blend": 10.0, "kind": "mine", "radius": 4.5})
	for rp in ramps:
		# 落客区放在坡道脚**外** 5.5m：坡道自己的斜面不算"落脚区"，
		# 这样坡脚到平台之间是一块真正的平地（可下建筑/集结）。
		var landing: Vector2 = rp["mouth"] + rp["dir"] * 4.0
		out.append({"pos": landing, "full": 6.5, "blend": 13.0,
			"kind": "ramp", "radius": 6.0})
	return out


## 连通性目标（地形层）：双方出生点、台地顶、两条坡道口、全部金矿、峡谷两端绕行点
static func _connectivity_targets(cfg: GameConfig, base_a: Vector2, base_b: Vector2,
		mines: Array[Vector2], ramps: Array, gorges: Array) -> Array:
	var out: Array = []
	for b in [base_a, base_b]:
		out.append({"pos": b, "radius": 2.0, "kind": "base"})
	out.append({"pos": Vector2.ZERO, "radius": 3.0, "kind": "mesa"})
	for rp in ramps:
		out.append({"pos": rp["mouth"], "radius": 3.0, "kind": "ramp"})
		out.append({"pos": rp["top_pos"], "radius": 2.5, "kind": "ramp_top"})
	for m in mines:
		out.append({"pos": m, "radius": 4.0, "kind": "mine"})
	for gg in gorges:
		out.append({"pos": _gorge_bypass(gg, 0.0), "radius": 4.0, "kind": "gorge_end"})
		out.append({"pos": _gorge_bypass(gg, 1.0), "radius": 4.0, "kind": "gorge_end"})
	return out


## ===========================================================================
## 可走性
## ===========================================================================
static func _recompute_walkable(data: MapData, cfg: GameConfig, c0: Vector2i, c1: Vector2i) -> void:
	var w: int = int(data.size)
	var half: float = data.size * 0.5
	var x0: int = maxi(0, c0.x)
	var z0: int = maxi(0, c0.y)
	var x1: int = mini(w, c1.x)
	var z1: int = mini(w, c1.y)
	for cz in range(z0, z1):
		for cx in range(x0, x1):
			var wx: float = -half + (cx + 0.5)
			var wz: float = -half + (cz + 0.5)
			var ok: bool = true
			if absf(wx) > half - EDGE_MARGIN or absf(wz) > half - EDGE_MARGIN:
				ok = false
			if ok and data.pond_radius > 0.0:
				if Vector2(wx, wz).distance_to(data.pond_center) < data.pond_radius * 0.92:
					ok = false
			if ok:
				var hx: float = data.height_at(wx + 0.6, wz) - data.height_at(wx - 0.6, wz)
				var hz: float = data.height_at(wx, wz + 0.6) - data.height_at(wx, wz - 0.6)
				if Vector2(hx, hz).length() > SLOPE_WALK_MAX:
					ok = false
			data.walkable[cz * w + cx] = 1 if ok else 0


## 压平一块圆域（对高度场直接插值）
static func _flatten_heights(data: MapData, pos: Vector2, full: float, blend: float, target: float) -> void:
	var res: int = data.resolution
	var row: int = res + 1
	var cell: float = data.size / float(res)
	var half: float = data.size * 0.5
	var r: int = int(ceil(blend / cell))
	var cx: int = int(round((pos.x + half) / cell))
	var cz: int = int(round((pos.y + half) / cell))
	for gz in range(maxi(0, cz - r), mini(res, cz + r) + 1):
		for gx in range(maxi(0, cx - r), mini(res, cx + r) + 1):
			var p := Vector2(-half + gx * cell, -half + gz * cell)
			var d: float = p.distance_to(pos)
			if d > blend:
				continue
			var w: float = 1.0 - _sstep(full, blend, d)
			var i: int = gz * row + gx
			data.heights[i] = lerpf(data.heights[i], target, w)


## 压平后再把保护区的高度记成压平后的真实高度（自检和落位都用它）
static func _apply_flat_zone_heights(data: MapData, zones: Array) -> void:
	for z in zones:
		var p: Vector2 = z["pos"]
		z["height"] = data.height_at(p.x, p.y)


## 在沟谷里挖一个水潭的碗
static func _carve_bowl(data: MapData, pos: Vector2, radius: float, depth: float) -> void:
	var res: int = data.resolution
	var row: int = res + 1
	var cell: float = data.size / float(res)
	var half: float = data.size * 0.5
	var r: int = int(ceil(radius / cell))
	var cx: int = int(round((pos.x + half) / cell))
	var cz: int = int(round((pos.y + half) / cell))
	var h0: float = data.height_at(pos.x, pos.y)
	for gz in range(maxi(0, cz - r), mini(res, cz + r) + 1):
		for gx in range(maxi(0, cx - r), mini(res, cx + r) + 1):
			var p := Vector2(-half + gx * cell, -half + gz * cell)
			var d: float = p.distance_to(pos)
			if d > radius:
				continue
			var w: float = 1.0 - _sstep(0.0, radius, d)
			data.heights[gz * row + gx] = lerpf(data.heights[gz * row + gx], h0 - depth, w)


## ===========================================================================
## 连通性
## ===========================================================================

## 从某点做一次洪水填充，返回 1=可达 的掩码
static func _flood_from(data: MapData, origin: Vector3) -> PackedByteArray:
	var w: int = int(data.size)
	var out := PackedByteArray()
	out.resize(w * w)
	out.fill(0)
	var c := _world_cell(data, origin)
	if c.x < 0:
		return out
	var start: int = c.y * w + c.x
	if data.walkable[start] == 0:
		var fixed := _nearest_walkable(data, c, 12)
		if fixed.x < 0:
			return out
		start = fixed.y * w + fixed.x
	var stack := PackedInt32Array()
	stack.append(start)
	out[start] = 1
	while stack.size() > 0:
		var cur: int = stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		var cx: int = cur % w
		var cz: int = cur / w
		for k in range(4):
			var nx: int = cx + (1 if k == 0 else (-1 if k == 1 else 0))
			var nz: int = cz + (1 if k == 2 else (-1 if k == 3 else 0))
			if nx < 0 or nz < 0 or nx >= w or nz >= w:
				continue
			var ni: int = nz * w + nx
			if out[ni] != 0 or data.walkable[ni] == 0:
				continue
			out[ni] = 1
			stack.append(ni)
	return out


## 目标点附近是否有可达格
static func _reachable_near(mask: PackedByteArray, data: MapData, pos: Vector2, radius: float) -> bool:
	var w: int = int(data.size)
	var half: float = data.size * 0.5
	var r: int = int(ceil(radius))
	var cx: int = int(floor(pos.x + half))
	var cz: int = int(floor(pos.y + half))
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dz * dz > r * r:
				continue
			var x: int = cx + dx
			var z: int = cz + dz
			if x < 0 or z < 0 or x >= w or z >= w:
				continue
			if mask[z * w + x] != 0:
				return true
	return false


## 需要修的目标逐个打通道；最多重试 4 轮
##
## 修法是**真改地形**：沿两点之间压出一条缓坡走廊，然后重算这段的可走性。
## 绝不靠"把格子标成可走"糊弄——那样单位会走在崖壁上。
static func _ensure_connectivity(data: MapData, cfg: GameConfig, targets: Array) -> Dictionary:
	var carves: int = 0
	var attempts: int = 0
	var bad_kinds: Array[String] = []
	for attempt in range(4):
		attempts = attempt + 1
		var va: PackedByteArray = _flood_from(data, Vector3(cfg.player_base_pos.x, 0.0, cfg.player_base_pos.y))
		var vb: PackedByteArray = _flood_from(data, Vector3(cfg.enemy_base_pos.x, 0.0, cfg.enemy_base_pos.y))
		var bad: Array = []
		for t in targets:
			var p: Vector2 = t["pos"]
			if not _reachable_near(va, data, p, t["radius"]):
				bad.append(t)
				continue
			if not _reachable_near(vb, data, p, t["radius"]):
				bad.append(t)
		for t in bad:
			bad_kinds.append(String(t["kind"]))
		if bad.is_empty():
			break
		for t in bad:
			_carve_ramp(data, cfg, cfg.player_base_pos, t["pos"])
			carves += 1
		var w: int = int(data.size)
		_recompute_walkable(data, cfg, Vector2i(0, 0), Vector2i(w, w))
	return {"attempts": attempts, "carves": carves, "bad_kinds": bad_kinds}


## 在两点之间压出一条缓坡走廊（修连通性用；正常情况下不会触发）
static func _carve_ramp(data: MapData, cfg: GameConfig, from: Vector2, to: Vector2) -> void:
	var dist: float = from.distance_to(to)
	var steps: int = maxi(1, int(ceil(dist / 0.8)))
	var ha: float = data.height_at(from.x, from.y)
	var hb: float = data.height_at(to.x, to.y)
	var res: int = data.resolution
	var row: int = res + 1
	var cell: float = data.size / float(res)
	var half: float = data.size * 0.5
	var radius: float = 4.5
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var p: Vector2 = from.lerp(to, t)
		var target: float = lerpf(ha, hb, t)
		var cx: int = int(round((p.x + half) / cell))
		var cz: int = int(round((p.y + half) / cell))
		var r: int = int(ceil(radius / cell))
		for gz in range(maxi(0, cz - r), mini(res, cz + r) + 1):
			for gx in range(maxi(0, cx - r), mini(res, cx + r) + 1):
				var q := Vector2(-half + gx * cell, -half + gz * cell)
				var d: float = q.distance_to(p)
				if d > radius:
					continue
				var w: float = 1.0 - _sstep(radius * 0.5, radius, d)
				var idx: int = gz * row + gx
				data.heights[idx] = lerpf(data.heights[idx], target, w * 0.9)


## ===========================================================================
## 资源落位
## ===========================================================================

## 树：成对（点对称）成簇，只长在平地；树与树之间留空
static func _place_trees(data: MapData, cfg: GameConfig, rng: RandomNumberGenerator,
		mines: Array[Vector2], ramps: Array, gorges: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var half: float = data.size * 0.5
	var pair_count: int = maxi(1, cfg.tree_clusters)
	for ci in range(pair_count):
		var center := Vector2.ZERO
		var ok: bool = false
		for tries in range(80):
			var ang: float = rng.randf() * TAU + float(ci) * TAU / float(pair_count)
			var rad: float = rng.randf_range(24.0, 84.0)
			var cand := Vector2(cos(ang), sin(ang)) * rad
			if not _tree_site_ok(data, cfg, cand, mines, ramps, gorges):
				continue
			if not _tree_site_ok(data, cfg, -cand, mines, ramps, gorges):
				continue
			center = cand
			ok = true
			break
		if not ok:
			continue
		var rad: float = rng.randf_range(cfg.tree_cluster_radius_min, cfg.tree_cluster_radius_max)
		var count: int = rng.randi_range(cfg.tree_cluster_count_min, cfg.tree_cluster_count_max)
		for mirror in [1.0, -1.0]:
			var c: Vector2 = center * mirror
			data.clusters.append({"pos": c, "radius": rad})
			for ti in range(count):
				var off := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * rad
				var p: Vector2 = c + off
				if absf(p.x) > half - 8.0 or absf(p.y) > half - 8.0:
					continue
				if _terrain_slope(data, p) > 0.45:
					continue
				# 别让树长在土路正中（车辙里长树既难看又挡路）
				if road_distance(data, p) < 4.2:
					continue
				if data.pond_radius > 0.0 and p.distance_to(data.pond_center) < data.pond_radius + 2.0:
					continue
				# 金矿周围留空：树冠直径 4~6m，长在矿口边上会从矿洞里穿出来
				if _near_any(mines, p, 9.0):
					continue
				var too_close: bool = false
				# 2.3 → 2.7：树冠现在更饱满（叶片更大更多），间距不拉开会互相插进对方的冠里
				for t in out:
					if p.distance_to(t) < 2.7:
						too_close = true
						break
				if too_close:
					continue
				out.append(p)
	_place_edge_belt(data, cfg, rng, out, mines)
	return out


## 外圈林带：地图"边界感"的唯一来源。
##
## 为什么不是围墙/山脊：那两种做法都会在地平线上留下一道人造轮廓；
## 魔兽3 的战场边界是**一片长到看不见的树**，它挡住视线、挡住兵，
## 但地形本身是平的、正常的。
##
## 落点策略：
##   · 沿四边以 7m 为步长走一圈；
##   · 低频噪声决定"这一段有没有林子"（值 < 0.12 就是缺口，读作林间空地）；
##   · 林带深度 3~13m 由另一层噪声控制，深浅不一才不像刷子刷出来的；
##   · 与主路/矿/基地保持距离（避免挡路、也避免把金矿围死）。
static func _place_edge_belt(data: MapData, cfg: GameConfig,
		rng: RandomNumberGenerator, out: Array[Vector2],
		mines: Array[Vector2] = []) -> void:
	var half: float = data.size * 0.5
	var gate := FastNoiseLite.new()
	gate.seed = cfg.map_seed + 311
	gate.frequency = 0.018
	gate.fractal_octaves = 2
	var depth_n := FastNoiseLite.new()
	depth_n.seed = cfg.map_seed + 577
	depth_n.frequency = 0.035

	var step: float = 7.0
	var u_end: float = half - 10.0
	var u: float = -u_end
	while u <= u_end:
		for side in 4:
			var g: float = gate.get_noise_2d(u * 1.1, float(side) * 41.0)
			if g < 0.12:
				continue                    # 这一段是林间缺口
			var depth: float = 3.0 + (depth_n.get_noise_2d(u * 0.9, float(side) * 23.0) * 0.5 + 0.5) * 10.0
			var d: float = half - 4.0 - depth
			var p := Vector2.ZERO
			match side:
				0: p = Vector2(u, -d)
				1: p = Vector2(u, d)
				2: p = Vector2(-d, u)
				_: p = Vector2(d, u)
			# 每棵树再抖一点，别让林带像一条直线
			p += Vector2(rng.randf_range(-1.6, 1.6), rng.randf_range(-1.6, 1.6))
			if absf(p.x) > half - 3.0 or absf(p.y) > half - 3.0:
				continue
			if _terrain_slope(data, p) > 0.5:
				continue
			if road_distance(data, p) < 5.0:
				continue
			if p.distance_to(cfg.player_base_pos) < 20.0 or p.distance_to(cfg.enemy_base_pos) < 20.0:
				continue
			# 林带也要给金矿让路（以前只躲基地和主路，矿口会被树冠盖住）
			if _near_any(mines, p, 8.0):
				continue
			var too_close: bool = false
			for t in out:
				if p.distance_to(t) < 2.7:
					too_close = true
					break
			if too_close:
				continue
			out.append(p)
		u += step


## 树簇选址：平地、离基地/矿/坡道/峡谷/水潭/边界都够远
static func _tree_site_ok(data: MapData, cfg: GameConfig, p: Vector2,
		mines: Array[Vector2], ramps: Array, gorges: Array) -> bool:
	var half: float = data.size * 0.5
	if absf(p.x) > half - 14.0 or absf(p.y) > half - 14.0:
		return false
	if p.distance_to(cfg.player_base_pos) < 34.0 or p.distance_to(cfg.enemy_base_pos) < 34.0:
		return false
	for m in mines:
		if p.distance_to(m) < 12.0:
			return false
	for rp in ramps:
		if p.distance_to(rp["mouth"]) < 10.0:
			return false
	for gg in gorges:
		if _dist_to_segment(p, gg["a"], gg["b"]) < float(gg["width"]) * 0.5 + 6.0:
			return false
	if data.pond_radius > 0.0 and p.distance_to(data.pond_center) < data.pond_radius + 8.0:
		return false
	# 树簇必须落在平地：中心周围 8m 内高差 < 1.4m
	var h0: float = data.height_at(p.x, p.y)
	for i in 8:
		var a: float = TAU * float(i) / 8.0
		var q: Vector2 = p + Vector2(cos(a), sin(a)) * 8.0
		if absf(data.height_at(q.x, q.y) - h0) > 1.4:
			return false
	return _terrain_slope(data, p) < 0.35


## 岩石：散落装饰 + 小阻挡，避开基地/矿/主通道/树/别的石头。
##
## 2026-10-31：**每块石头的外观由生成期就定好**（变体 / 三轴缩放 / 倾斜 / 下沉），
## 不再让关卡那边拿 `i % 4` 和一条正弦公式凑 —— 那套凑法有两个毛病：
##   ① 变体按索引循环，一排石头必然 1-2-3-4-1-2-3-4 地重复；
##   ② 只有旋转和统一缩放，没有倾斜和下沉，看着像"摆在地上的模型"。
## 现在全部出自同一个 RandomNumberGenerator（种子 = 地图种子），所以确定性可复现。
static func _place_rocks(data: MapData, cfg: GameConfig, rng: RandomNumberGenerator,
		mines: Array[Vector2]) -> void:
	var half: float = data.size * 0.5
	var variants: int = ProcProp.ROCK_VARIANTS
	for ri in range(cfg.rock_count):
		for tries in range(30):
			var p := Vector2(rng.randf_range(-half + 12.0, half - 12.0),
				rng.randf_range(-half + 12.0, half - 12.0))
			if p.distance_to(cfg.player_base_pos) < 26.0:
				continue
			if p.distance_to(cfg.enemy_base_pos) < 26.0:
				continue
			if _near_any(mines, p, 9.0):
				continue
			# 树和石头会互相插进去（石头的顶端会从树冠里穿出来），留 2.8m
			if _near_any(data.trees, p, 2.8):
				continue
			if _near_rocks(data.rocks, p, 2.6):
				continue
			if data.pond_radius > 0.0 and p.distance_to(data.pond_center) < data.pond_radius + 3.0:
				continue
			# 别堵在"基地→台地"的主路上
			var mouth_a: Vector2 = Vector2.ZERO
			for rp in data.ramps:
				mouth_a = rp["mouth"]
				break
			if _dist_to_segment(p, cfg.player_base_pos, mouth_a) < 5.0:
				continue
			if road_distance(data, p) < 4.2:
				continue
			if _terrain_slope(data, p) > 0.9:
				continue
			var sc: float = rng.randf_range(0.46, 1.12)
			# 三轴各自抖：同一块网格能长成"压扁的台 / 竖起的刃"
			var aniso := Vector3(
				rng.randf_range(0.86, 1.20),
				rng.randf_range(0.74, 1.28),
				rng.randf_range(0.86, 1.20))
			data.rocks.append({
				"pos": p,
				"scale": sc,
				"aniso": aniso,
				"rot": rng.randf() * TAU,
				# 倾斜 ±5°：全都笔直立着是"摆件"，歪一点才像"半埋在地里"
				"tilt": Vector2(rng.randf_range(-0.088, 0.088), rng.randf_range(-0.088, 0.088)),
				# 下沉：按体积给，大石头埋得更深（不然块头一大就"浮"起来）
				"sink": sc * rng.randf_range(0.10, 0.22),
				"variant": rng.randi_range(0, maxi(0, variants - 1)),
			})
			break


## 地面装饰：草丛 / 碎石 / 路边碎石带 / 蘑菇 / 枯木 / 营地杂物 / 断墙遗迹 / 关口石墙
##
## 全部是**纯视觉**（不写 walkable、不加碰撞），所以不会让寻路变差；
## 但落点仍然避开土路中线和建筑占地，免得"草长在车辙里"。
static func _place_decor(data: MapData, cfg: GameConfig, rng: RandomNumberGenerator,
		mines: Array[Vector2], ridges: Array) -> void:
	var half: float = data.size * 0.5
	var grass_target: int = maxi(0, cfg.map_decor_grass)
	var tries: int = 0
	while data.grass.size() < grass_target and tries < grass_target * 8:
		tries += 1
		var p := Vector2(rng.randf_range(-half + 10.0, half - 10.0),
			rng.randf_range(-half + 10.0, half - 10.0))
		if terrain_is_water(data, p):
			continue
		if _terrain_slope(data, p) > 0.32:
			continue
		if _near_any(data.trees, p, 2.2) or _near_rocks(data.rocks, p, 2.0):
			continue
		# 车辙里不长草：贴着路缘才长，路面留空
		if road_distance(data, p) < 2.4:
			continue
		var h: float = data.height_at(p.x, p.y)
		# 台地顶上少一些草（岩石台地），低地多一些
		if h > cfg.map_mesa_height - 0.5 and rng.randf() < 0.55:
			continue
		data.grass.append({
			"pos": Vector3(p.x, h, p.y),
			"scale": rng.randf_range(0.34, 0.62),
			"rot": rng.randf() * TAU,
		})

	var rubble_target: int = maxi(0, cfg.map_decor_rubble)

	# --- 路边碎石带：沿路缘每隔几米一小撮（"车辙被碎石挤出来"的叙事） ---
	for rd in data.roads:
		var pts: PackedVector2Array = rd["pts"]
		var w: float = float(rd["width"])
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var seg: float = a.distance_to(b)
			if seg < 0.01:
				continue
			var dir: Vector2 = (b - a) / seg
			var nrm := Vector2(-dir.y, dir.x)
			var d: float = rng.randf_range(0.0, cfg.map_roadside_step)
			while d < seg:
				var side: float = 1.0 if rng.randf() < 0.5 else -1.0
				var q: Vector2 = a + dir * d + nrm * side * (w * 0.5 + rng.randf_range(0.25, 1.5))
				data.rubble.append({
					"pos": Vector3(q.x, data.height_at(q.x, q.y) + 0.02, q.y),
					"scale": rng.randf_range(0.10, 0.24),
					"rot": rng.randf() * TAU,
				})
				d += cfg.map_roadside_step * rng.randf_range(0.75, 1.4)

	# --- 崖脚 / 沟沿的碎石堆 ---
	tries = 0
	while data.rubble.size() < rubble_target and tries < rubble_target * 12:
		tries += 1
		var p := Vector2(rng.randf_range(-half + 8.0, half - 8.0),
			rng.randf_range(-half + 8.0, half - 8.0))
		var slope: float = _terrain_slope(data, p)
		# 碎石堆在崖脚（坡度中等的过渡带）
		if slope < 0.45 or slope > 1.3:
			continue
		if terrain_is_water(data, p):
			continue
		if _near_any(data.trees, p, 1.6):
			continue
		if road_distance(data, p) < 1.2:
			continue
		data.rubble.append({
			"pos": Vector3(p.x, data.height_at(p.x, p.y), p.y),
			"scale": rng.randf_range(0.28, 0.62),
			"rot": rng.randf() * TAU,
		})

	_place_mushrooms(data, cfg, rng, mines)
	_place_dead_trees(data, cfg, rng)
	_place_camp_props(data, cfg, rng, mines)
	_place_ruins(data, cfg)
	_place_gate_walls(data, cfg, rng, ridges)


## 蘑菇 / 小花簇：林缘阴湿处 + 沟壁半坡
static func _place_mushrooms(data: MapData, cfg: GameConfig, rng: RandomNumberGenerator,
		mines: Array[Vector2]) -> void:
	var half: float = data.size * 0.5
	var target: int = maxi(0, cfg.map_decor_mushroom)
	var tries: int = 0
	while _decor_size(data, "mushroom") < target and tries < target * 8:
		tries += 1
		var p := Vector2(rng.randf_range(-half + 9.0, half - 9.0),
			rng.randf_range(-half + 9.0, half - 9.0))
		if terrain_is_water(data, p):
			continue
		var slope: float = _terrain_slope(data, p)
		if slope > 1.05:
			continue
		var near_wood: bool = false
		for c in data.clusters:
			if p.distance_to(c["pos"]) < float(c["radius"]) * 1.7 + 2.0:
				near_wood = true
				break
		# 林缘，或者沟壁/崖脚的潮湿半坡
		if not near_wood and (slope < 0.30 or slope > 0.95):
			continue
		if _near_any(data.trees, p, 1.2) or _near_rocks(data.rocks, p, 1.2):
			continue
		if road_distance(data, p) < 1.6:
			continue
		_decor_push(data, "mushroom", Vector3(p.x, data.height_at(p.x, p.y) + 0.02, p.y),
			rng.randf_range(0.6, 1.35), rng.randf() * TAU)


## 枯木：树簇外缘，两三棵一撮，给森林边缘做"死亡过渡"
static func _place_dead_trees(data: MapData, cfg: GameConfig, rng: RandomNumberGenerator) -> void:
	var target: int = maxi(0, cfg.map_decor_deadtree)
	if data.clusters.is_empty():
		return
	var tries: int = 0
	while _decor_size(data, "dead_tree") < target and tries < target * 20:
		tries += 1
		var c: Dictionary = data.clusters[rng.randi_range(0, data.clusters.size() - 1)]
		var ang: float = rng.randf() * TAU
		var rad: float = float(c["radius"]) * rng.randf_range(1.02, 1.55)
		var p: Vector2 = c["pos"] + Vector2(cos(ang), sin(ang)) * rad
		if absf(p.x) > data.size * 0.5 - 10.0 or absf(p.y) > data.size * 0.5 - 10.0:
			continue
		if terrain_is_water(data, p) or _terrain_slope(data, p) > 0.5:
			continue
		if road_distance(data, p) < 3.0:
			continue
		if _near_any(data.trees, p, 1.0):
			continue
		_decor_push(data, "dead_tree", Vector3(p.x, data.height_at(p.x, p.y), p.y),
			rng.randf_range(0.8, 1.35), rng.randf() * TAU,
			Vector2(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12)))


## 营地杂物：帐篷 / 木箱 / 木桶 / 栅栏残段 / 篝火坑 / 柴堆 / 原木。
## 三个小聚落围着基地摆（均匀撒一圈会像垃圾场）；以玩家基地为样本，
## 敌人侧取点对称（位置取反、朝向 +180°）。
static func _place_camp_props(data: MapData, cfg: GameConfig, rng: RandomNumberGenerator,
		mines: Array[Vector2]) -> void:
	const PATTERN := ["crate", "barrel", "fence", "crate", "barrel", "fence", "crate"]
	var count: int = maxi(0, cfg.map_decor_camp)
	var base: Vector2 = cfg.player_base_pos
	var clusters: int = 3
	var per_cluster: int = maxi(1, count / clusters)
	var placed: Array[Vector2] = []
	var fire_done: bool = false
	for ci in range(clusters):
		# 三个聚落方向固定（避开主路 137° 和建筑群），再带一点抖动
		var cang: float = [0.62, 2.55, 4.55][ci % 3]
		var center := Vector2.ZERO
		var found: bool = false
		for tries in range(18):
			var a: float = cang + rng.randf_range(-0.16, 0.16)
			var rad: float = rng.randf_range(14.5, 18.0)
			var q: Vector2 = base + Vector2(cos(a), sin(a)) * rad
			if not _camp_site_ok(data, cfg, q, mines):
				continue
			center = q
			found = true
			break
		if not found:
			continue
		# 聚落中心先放帐篷
		_decor_push(data, "tent", Vector3(center.x, data.height_at(center.x, center.y), center.y),
			1.0, rng.randf() * TAU)
		_decor_push(data, "tent", Vector3(-center.x, data.height_at(-center.x, -center.y), -center.y),
			1.0, rng.randf() * TAU + PI)
		for k in range(per_cluster):
			var q := Vector2.ZERO
			var placed_ok := false
			for tries in range(6):
				var ang: float = rng.randf() * TAU
				var rr: float = rng.randf_range(2.2, 3.9)
				q = center + Vector2(cos(ang), sin(ang)) * rr
				if _terrain_slope(data, q) > 0.30 or terrain_is_water(data, q):
					continue
				if _near_any(placed, q, 1.5):
					continue
				if road_distance(data, q) < 2.8:
					continue
				placed_ok = true
				break
			if not placed_ok:
				continue
			placed.append(q)
			var kind: String = PATTERN[k % PATTERN.size()]
			if k == 2 and ci == 0 and not fire_done:
				kind = "campfire"
				fire_done = true
			var sc: float = 1.0 if kind == "campfire" else rng.randf_range(0.9, 1.25)
			var rot: float = rng.randf() * TAU
			var h: float = data.height_at(q.x, q.y)
			_decor_push(data, kind, Vector3(q.x, h, q.y), sc, rot)
			# 镜像到敌方基地（点对称）
			var q2 := -q
			var h2: float = data.height_at(q2.x, q2.y)
			_decor_push(data, kind, Vector3(q2.x, h2, q2.y), sc, rot + PI)


## 营聚落选址：基地外环、平地、避开建筑/金矿/主路
static func _camp_site_ok(data: MapData, cfg: GameConfig, q: Vector2,
		mines: Array[Vector2]) -> bool:
	var base: Vector2 = cfg.player_base_pos
	if absf(q.x) > data.size * 0.5 - 10.0 or absf(q.y) > data.size * 0.5 - 10.0:
		return false
	if q.distance_to(base) < 13.0 or q.distance_to(base) > 21.0:
		return false
	if _terrain_slope(data, q) > 0.22:
		return false
	if terrain_is_water(data, q):
		return false
	if road_distance(data, q) < 5.5:
		return false
	for off in cfg.player_buildings.values():
		if q.distance_to(base + (off as Vector2)) < 9.0:
			return false
	for m in mines:
		if q.distance_to(m) < 9.0:
			return false
	return true



## 断墙遗迹：台地崖脚两块对称的废墟。
## 摆成"L 形塌墙 + 一堆倒石"（弧线排一排会像毛毛虫，不像遗迹）。
static func _place_ruins(data: MapData, cfg: GameConfig) -> void:
	var groups: int = maxi(0, cfg.map_decor_ruin_groups)
	if groups <= 0:
		return
	# 局部布局：x 方向一排、拐角再往 z 方向延伸
	var layout: Array = [
		{"p": Vector2(-3.2, -2.6), "rot": 0.0, "sc": 1.05},
		{"p": Vector2(0.0, -2.6), "rot": 0.0, "sc": 0.95},
		{"p": Vector2(3.2, -2.6), "rot": 0.0, "sc": 1.10},
		{"p": Vector2(-3.2, 0.1), "rot": PI * 0.5, "sc": 0.90},
		{"p": Vector2(-3.2, 2.9), "rot": PI * 0.5, "sc": 1.00},
		{"p": Vector2(2.4, 0.6), "rot": 0.35, "sc": 0.55},
	]
	var base_site := Vector2(-33.0, 1.5)
	for gi in range(groups):
		var site: Vector2 = base_site + Vector2(float(gi) * 9.0, float(gi) * -7.0)
		for mirror in [1.0, -1.0]:
			var c: Vector2 = site * mirror
			if road_distance(data, c) < 8.0:
				continue
			for item in layout:
				var q: Vector2 = c + (item["p"] as Vector2) * mirror
				if _terrain_slope(data, q) > 0.32 or terrain_is_water(data, q):
					continue
				if road_distance(data, q) < 3.0:
					continue
				_decor_push(data, "wall", Vector3(q.x, data.height_at(q.x, q.y), q.y),
					float(item["sc"]), float(item["rot"]) + (0.0 if mirror > 0.0 else PI))
			# 墙根散落的碎石（复用碎石合批，小碎块）
			for k in range(7):
				var a2: float = TAU * float(k) / 7.0 + 0.4
				var q2: Vector2 = c + Vector2(cos(a2), sin(a2)) * (4.2 + 0.6 * float(k % 3))
				if _terrain_slope(data, q2) > 0.4 or terrain_is_water(data, q2):
					continue
				data.rubble.append({
					"pos": Vector3(q2.x, data.height_at(q2.x, q2.y) + 0.02, q2.y),
					"scale": 0.10 + 0.05 * float(k % 3),
					"rot": a2 * 2.3,
				})


## 关口石墙：沿岩脊脊线摆一排大块碎石（缺口留空），纯视觉强化"石门"读感
static func _place_gate_walls(data: MapData, cfg: GameConfig, rng: RandomNumberGenerator,
		ridges: Array) -> void:
	var n: int = maxi(0, cfg.map_decor_gate_rocks)
	if n <= 0:
		return
	for rg in ridges:
		var a: Vector2 = rg["a"]
		var b: Vector2 = rg["b"]
		var length: float = a.distance_to(b)
		if length < 1.0:
			continue
		var gap_half: float = clampf(float(rg["gap"]) / length, 0.02, 0.42)
		var dir: Vector2 = (b - a) / length
		var nrm := Vector2(-dir.y, dir.x)
		for k in range(n):
			var t: float = 0.035 + 0.93 * float(k) / float(maxi(1, n - 1))
			# 缺口处留空（两侧各留 1m 余量）
			if absf(t - 0.5) < gap_half * 1.04:
				continue
			var q: Vector2 = a.lerp(b, t) + nrm * rng.randf_range(-1.1, 1.1)
			var gap_edge: bool = absf(t - 0.5) < gap_half * 1.35
			var sc: float = rng.randf_range(1.15, 1.55) if gap_edge else rng.randf_range(0.80, 1.25)
			_decor_push(data, "boulder",
				Vector3(q.x, data.height_at(q.x, q.y) - 0.25, q.y), sc, rng.randf() * TAU)


## 往装饰表里塞一个点（同一种类的数组按需创建）
static func _decor_push(data: MapData, kind: String, pos: Vector3, scale_f: float,
		rot: float, tilt: Vector2 = Vector2.ZERO) -> void:
	if not data.decor.has(kind):
		data.decor[kind] = []
	(data.decor[kind] as Array).append({
		"pos": pos, "scale": scale_f, "rot": rot, "tilt": tilt,
	})


static func _decor_size(data: MapData, kind: String) -> int:
	if not data.decor.has(kind):
		return 0
	return (data.decor[kind] as Array).size()


## ===========================================================================
## 道具阻挡 + 最终连通性
## ===========================================================================
static func _apply_prop_blocks(data: MapData) -> void:
	for t in data.trees:
		_block_circle(data, t, 0.95)
	for m in data.mines:
		_block_rect_cells(data, m, 4, 4)
	for r in data.rocks:
		_block_circle(data, r["pos"], 1.05 * float(r["scale"]))


## 把没有可走邻格的树删掉（森林内部被自己封死的树，农民够不到）
static func _drop_unreachable_trees(data: MapData, cfg: GameConfig) -> Array:
	var va: PackedByteArray = _flood_from(data, Vector3(cfg.player_base_pos.x, 0.0, cfg.player_base_pos.y))
	var vb: PackedByteArray = _flood_from(data, Vector3(cfg.enemy_base_pos.x, 0.0, cfg.enemy_base_pos.y))
	var kept: Array[Vector2] = []
	var removed: Array = []
	for t in data.trees:
		if _reachable_near(va, data, t, 2.6) and _reachable_near(vb, data, t, 2.6):
			kept.append(t)
		else:
			removed.append(t)
	data.trees = kept
	return removed


## ===========================================================================
## 统计
## ===========================================================================
static func _finish_stats(data: MapData, cfg: GameConfig, t_start: int,
		h_min: float, h_max: float, base_a: Vector2, base_b: Vector2) -> void:
	var w: int = int(data.size)
	var walk_count: int = 0
	for i in range(w * w):
		if data.walkable[i] != 0:
			walk_count += 1
	# 台地顶站立面积
	var top: float = cfg.map_mesa_height
	var area_cells: int = 0
	for cz in range(0, w, 2):
		for cx in range(0, w, 2):
			var wx: float = -data.size * 0.5 + (cx + 0.5)
			var wz: float = -data.size * 0.5 + (cz + 0.5)
			if Vector2(wx, wz).length() > cfg.map_mesa_radius:
				continue
			if data.height_at(wx, wz) > top - 1.0:
				area_cells += 1
	data.plateau_area = float(area_cells) * 4.0
	data.plateau = {"center": Vector2.ZERO, "radius": cfg.map_mesa_radius, "top": top}
	# 关口 / 出生带
	for rg in _make_ridges(cfg, base_a, base_b):
		data.chokes.append({"pos": rg["center"], "radius": float(rg["radius"]),
			"kind": "gate", "gap": float(rg["gap"]),
			"a": rg["a"], "b": rg["b"]})
	for gg in data.gorges:
		data.chokes.append({"pos": gg["bridge"], "radius": 6.0, "kind": "bridge"})
	data.spawn_safe = []
	for b in [base_a, base_b]:
		data.spawn_safe.append({"pos": b, "radius": cfg.map_base_flat, "height": data.height_at(b.x, b.y)})
	data.stats["gen_ms"] = float(Time.get_ticks_usec() - t_start) / 1000.0
	data.stats["heights"] = data.heights.size()
	data.stats["walkable_pct"] = 100.0 * float(walk_count) / float(w * w)
	data.stats["min_h"] = h_min
	data.stats["max_h"] = h_max
	data.stats["trees"] = data.trees.size()
	data.stats["rocks"] = data.rocks.size()
	data.stats["mines"] = data.mines.size()
	data.stats["grass"] = data.grass.size()
	data.stats["rubble"] = data.rubble.size()
	data.stats["roads"] = data.roads.size()
	data.stats["road_pts"] = _road_point_count(data)
	data.stats["decor"] = data.decor_count()
	for k in data.decor:
		data.stats["decor_" + String(k)] = (data.decor[k] as Array).size()
	data.stats["chokes"] = data.chokes.size()
	data.stats["resolution"] = data.resolution
	data.stats["size"] = data.size


static func _road_point_count(data: MapData) -> int:
	var n: int = 0
	for rd in data.roads:
		n += (rd["pts"] as PackedVector2Array).size()
	return n


# ===========================================================================
# 几何小工具
# ===========================================================================

static func _sstep(a: float, b: float, x: float) -> float:
	if is_equal_approx(a, b):
		return 0.0 if x < a else 1.0
	var t: float = clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _angle_delta(a: float, b: float) -> float:
	return fposmod(a - b + PI, TAU) - PI


static func _seg_point(a: Vector2, b: Vector2, t: float) -> Vector2:
	return a.lerp(b, t)


## 峡谷两端外侧的绕行点（往端点外再退 6m）
static func _gorge_bypass(g: Dictionary, which: float) -> Vector2:
	var a: Vector2 = g["a"]
	var b: Vector2 = g["b"]
	var dir: Vector2 = (b - a).normalized()
	if which < 0.5:
		return a - dir * 6.0
	return b + dir * 6.0


## 峡谷上某比例处的点（带摆动）
static func _gorge_point(g: Dictionary, t: float) -> Vector2:
	var a: Vector2 = g["a"]
	var b: Vector2 = g["b"]
	var dir: Vector2 = (b - a).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	var wob: float = GORGE_WIGGLE * sin(t * 5.2 + float(g["phase"]))
	return a.lerp(b, t) + nrm * wob


static func _world_cell(data: MapData, p: Vector3) -> Vector2i:
	var w: int = int(data.size)
	var half: float = data.size * 0.5
	var c := Vector2i(int(floor(p.x + half)), int(floor(p.z + half)))
	if c.x < 0 or c.y < 0 or c.x >= w or c.y >= w:
		return Vector2i(-1, -1)
	return c


static func _nearest_walkable(data: MapData, c: Vector2i, max_r: int) -> Vector2i:
	var w: int = int(data.size)
	if c.x < 0 or c.y < 0 or c.x >= w or c.y >= w:
		return Vector2i(-1, -1)
	if data.walkable[c.y * w + c.x] != 0:
		return c
	for r in range(1, max_r):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var x: int = c.x + dx
				var z: int = c.y + dz
				if x < 0 or z < 0 or x >= w or z >= w:
					continue
				if data.walkable[z * w + x] != 0:
					return Vector2i(x, z)
	return Vector2i(-1, -1)


## 地形坡度（1.2m 跨度高差 / 1.2m）
static func _terrain_slope(data: MapData, p: Vector2) -> float:
	var hx: float = data.height_at(p.x + 0.6, p.y) - data.height_at(p.x - 0.6, p.y)
	var hz: float = data.height_at(p.x, p.y + 0.6) - data.height_at(p.x, p.y - 0.6)
	return Vector2(hx, hz).length() / 1.2


static func terrain_is_water(data: MapData, p: Vector2) -> bool:
	if data.pond_radius <= 0.0:
		return false
	return p.distance_to(data.pond_center) < data.pond_radius


static func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var length_sq: float = ab.length_squared()
	if length_sq < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / length_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _near_any(points: Array[Vector2], p: Vector2, radius: float) -> bool:
	for q in points:
		if p.distance_to(q) < radius:
			return true
	return false


static func _near_rocks(rocks: Array, p: Vector2, radius: float) -> bool:
	for r in rocks:
		if p.distance_to(r["pos"]) < radius:
			return true
	return false


static func _block_circle(data: MapData, pos: Vector2, radius: float) -> void:
	var w: int = int(data.size)
	var half: float = data.size * 0.5
	var cx0: int = int(pos.x + half)
	var cz0: int = int(pos.y + half)
	var r: int = ceili(radius)
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dz * dz > r * r:
				continue
			var cx: int = cx0 + dx
			var cz: int = cz0 + dz
			if cx < 0 or cz < 0 or cx >= w or cz >= w:
				continue
			data.walkable[cz * w + cx] = 0


static func _block_rect_cells(data: MapData, pos: Vector2, sx: int, sz: int) -> void:
	var w: int = int(data.size)
	var half: float = data.size * 0.5
	var cx0: int = int(pos.x + half) - sx / 2
	var cz0: int = int(pos.y + half) - sz / 2
	for dz in range(sz):
		for dx in range(sx):
			var cx: int = cx0 + dx
			var cz: int = cz0 + dz
			if cx < 0 or cz < 0 or cx >= w or cz >= w:
				continue
			data.walkable[cz * w + cx] = 0

# ===========================================================================
# 竞技场地图（多队 · 4 出生点 · 四重旋转对称 · 魔兽 3 式地块）
# ===========================================================================
#
# 为什么另起一套生成器，而不是给 build() 打补丁：
#   build() 是"2 队 + 中央台地 + 两条峡谷 + 两道岩脊"的图，它所有的地貌特征
#   （_mesa_height / _ramp_surface / _ridge_delta / _gorge_depth / 地形的
#   _sculpt_mesa_rim）都是**叠加在高度场上**的 —— 台地边缘、岩脊缺口、坡道压平区
#   的 blend 环都会在建筑脚下留下 0.2~1m 的起伏，那就是"莫名的凸起 + 穿模"的来源。
#
# 竞技场反过来：**高度场先做干净，再谈地貌**。
#   ① 起伏全部来自四重旋转对称的低频噪声（±2m / 波长 120m），斜率远低于建筑阈值；
#   ② 每个出生点上切一块 25m 半径的**绝对水平**平台（格点直接等于常量，
#      所以任意占地的高差 = 0，"一半悬空一半埋地"在数学上不可能出现）；
#   ③ 地块（8m 一格）走魔兽 3 的口径：材质存在共享格点上、一格读四个角、交界硬边。
#      土路 / 营地 / 矿点直接写进地块，不再叠一层路面网格（那层路面是"很杂"的一半）。
const ARENA_TILE: float = 8.0        ## 地块一格（米），必须等于地形贴图的平铺距离
const ARENA_PAD_FLAT: float = 25.0   ## 出生平台**严格水平**的半径
const ARENA_PAD_BLEND: float = 48.0  ## 平台外沿到野地的过渡半径
const ARENA_BASE_H: float = 1.40     ## 平台顶面高度（米）
const ARENA_ROAD_HALF: float = 5.0   ## 土路半宽（米）
const ARENA_EDGE_MARGIN: float = 14.0 ## 边界不可走内缩（米）


## 生成一张 N 队竞技场图。slot_count = 出生点数量（默认 4 = 四角）。
static func build_arena(cfg: GameConfig, slot_count: int = 4) -> MapData:
	var t_start: int = Time.get_ticks_usec()
	var data := MapData.new()
	data.size = cfg.map_size
	data.resolution = maxi(32, cfg.terrain_resolution)
	var res: int = data.resolution
	var row: int = res + 1
	var half: float = data.size * 0.5
	var cell: float = data.size / float(res)
	var slots: int = maxi(2, mini(slot_count, 8))

	# --- 0. 出生点：四个角（45° 起，按槽位数均分） ---
	data.base_pad = ARENA_PAD_FLAT
	data.edge_keep_out = ARENA_EDGE_MARGIN
	var bases: Array[Vector2] = []
	var base_r: float = half * 0.560
	for k in range(slots):
		var ang: float = PI * 0.25 + TAU * float(k) / float(slots)
		bases.append(Vector2(cos(ang), sin(ang)) * base_r)
	data.base_points = bases

	# --- 1. 土路网：相邻基地连成环 + 对角穿过中心 ---
	var roads: Array = _arena_roads(data, slots)

	# --- 2. 金矿：每个基地两座（一近一远），四重对称 ---
	var mines: Array[Vector2] = []
	for k in range(slots):
		var b: Vector2 = bases[k]
		var to_c: Vector2 = (-b).normalized()
		var side := Vector2(-to_c.y, to_c.x)
		mines.append(b + to_c * 19.0 + side * 13.0)
		mines.append(b + to_c * 22.0 - side * 13.0)
	data.mines = mines

	# --- 3. 高度场 ---
	var n_low := FastNoiseLite.new()
	n_low.seed = cfg.map_seed
	n_low.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_low.frequency = 0.0090
	n_low.fractal_octaves = 3
	n_low.fractal_gain = 0.42
	var n_fine := FastNoiseLite.new()
	n_fine.seed = cfg.map_seed + 31
	n_fine.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_fine.frequency = 0.026
	n_fine.fractal_octaves = 2
	var n_patch := FastNoiseLite.new()
	n_patch.seed = cfg.map_seed + 7
	n_patch.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	# 两级土斑：大斑 60m 定"这片地是干的"，小斑 22m 把边界啃碎。
	# 只用一级时地块边界是规则的椭圆，俯视像"画上去的斑点"。
	n_patch.frequency = 0.0092
	n_patch.fractal_octaves = 4
	n_patch.fractal_gain = 0.55

	data.heights.resize(row * row)
	var h_min: float = INF
	var h_max: float = -INF
	for gz in range(row):
		for gx in range(row):
			var p := Vector2(-half + float(gx) * cell, -half + float(gz) * cell)
			var h: float = _sym_noise(n_low, p) * 3.20
			h += _sym_noise(n_fine, p) * 0.38
			# 中央高台：中路是战略高点，坡度只有 1.35m / 70m ≈ 1°
			var r: float = p.length()
			h += 1.35 * (1.0 - _sstep(0.0, half * 0.62, r))
			# 出生平台：**严格水平**。d <= ARENA_PAD_FLAT 时 sstep 返回 1 → h = 常量。
			var d: float = _min_dist(bases, p)
			var w: float = 1.0 - _sstep(ARENA_PAD_FLAT, ARENA_PAD_BLEND, d)
			if w > 0.0:
				h = lerpf(h, ARENA_BASE_H, w)
			h = clampf(h, -3.5, 7.5)
			data.heights[gz * row + gx] = h
			h_min = minf(h_min, h)
			h_max = maxf(h_max, h)

	# 金矿脚下再压一小块平地（4.5m 半径），免得矿基一半埋进坡里
	for m in mines:
		_flatten_heights(data, m, 4.5, 11.0, data.height_at(m.x, m.y))

	# --- 4. 地块（魔兽 3 口径：格点表 (N+1)²） ---
	_paint_arena_tiles(data, n_patch, roads)

	# --- 5. 可走性 ---
	var w2: int = int(data.size)
	data.walkable.resize(w2 * w2)
	_arena_walkable(data)

	# --- 6. 压平保护区（关卡 / 装饰避让用） ---
	var zones: Array = []
	for b in bases:
		zones.append({"pos": b, "full": ARENA_PAD_FLAT, "blend": ARENA_PAD_BLEND,
			"kind": "base", "radius": ARENA_PAD_FLAT, "height": ARENA_BASE_H})
	for m in mines:
		zones.append({"pos": m, "full": 4.5, "blend": 11.0, "kind": "mine",
			"radius": 4.5, "height": data.height_at(m.x, m.y)})
	data.flat_zones = zones

	data.far_ridges = false

	# --- 7. 资源与装饰（全部走四重对称散点） ---
	_arena_place_trees(data, roads)
	_arena_place_rocks(data, roads)
	_arena_place_decor(data, roads)
	_apply_prop_blocks(data)

	# --- 8. 统计 ---
	var walk: int = 0
	for i in range(data.walkable.size()):
		if data.walkable[i] != 0:
			walk += 1
	data.stats = {
		"kind": "arena",
		"slots": slots,
		"size": data.size,
		"resolution": data.resolution,
		"height_min": h_min,
		"height_max": h_max,
		"trees": data.trees.size(),
		"mines": data.mines.size(),
		"rocks": data.rocks.size(),
		"decor": data.decor_count(),
		"mat_cells": data.mat_cells,
		"walkable": walk,
		"build_ms": float(Time.get_ticks_usec() - t_start) / 1000.0,
	}
	RtsGroundDetail.install(data)
	return data


## 四重旋转对称的噪声采样：同一张噪声在 0/90/180/270 四个旋转上取平均。
## 这样"看着随机"，但四个角的玩家看到的地形**逐顶点完全相同** —— 公平性不靠手调。
static func _sym_noise(n: FastNoiseLite, p: Vector2) -> float:
	return (n.get_noise_2d(p.x, p.y) + n.get_noise_2d(-p.y, p.x)
		+ n.get_noise_2d(-p.x, -p.y) + n.get_noise_2d(p.y, -p.x)) * 0.25


## 点绕原点转 k×90°
static func _rot4(p: Vector2, k: int) -> Vector2:
	var kk: int = ((k % 4) + 4) % 4
	if kk == 0:
		return p
	if kk == 1:
		return Vector2(-p.y, p.x)
	if kk == 2:
		return -p
	return Vector2(p.y, -p.x)


## 把点转到"基本扇区"（角度落在 [0, 90°)）。
## 散点只对 **canonical 坐标**做哈希，四个旋转自然得到同一个判定 → 全图四重对称。
static func _canon4(p: Vector2) -> Vector2:
	var ang: float = atan2(p.y, p.x)
	if ang < 0.0:
		ang += TAU
	var k: int = int(ang / (PI * 0.5)) % 4
	return _rot4(p, -k)


## 平面坐标的确定性哈希（0..1）
static func _hash_v2(p: Vector2) -> float:
	var v: float = sin(p.x * 12.9898 + p.y * 78.233 + 3.17) * 43758.5453
	return v - floorf(v)


## 到最近出生点的距离
static func _min_dist(points: Array[Vector2], p: Vector2) -> float:
	var best: float = 1e20
	for q in points:
		best = minf(best, p.distance_to(q))
	return best


## 到土路中心线的距离（米）
static func _arena_road_dist(roads: Array, p: Vector2) -> float:
	var best: float = 1e20
	for rd in roads:
		var pts: PackedVector2Array = rd["pts"]
		for i in range(pts.size() - 1):
			var d: float = _dist_to_segment(p, pts[i], pts[i + 1])
			if d < best:
				best = d
				if best < 0.05:
					return best
	return best


## 土路：相邻基地连成环（向外微鼓）+ 对角穿中心（4 队时是"口"字 + "X"）
static func _arena_roads(data: MapData, slots: int) -> Array:
	var out: Array = []
	var bases: Array[Vector2] = data.base_points
	if bases.size() < 2:
		return out
	for k in range(slots):
		var a: Vector2 = bases[k]
		var b: Vector2 = bases[(k + 1) % slots]
		var mid: Vector2 = (a + b) * 0.5
		var outward: Vector2 = mid.normalized() * 8.0
		out.append({
			"pts": _resample_polyline(PackedVector2Array([a, mid + outward, b]), 2.0),
			"width": ARENA_ROAD_HALF * 2.0, "kind": "main"})
	var half_slots: int = slots / 2
	for k in range(half_slots):
		var a2: Vector2 = bases[k]
		var b2: Vector2 = bases[(k + half_slots) % slots]
		out.append({
			"pts": _resample_polyline(PackedVector2Array([a2, a2 * 0.42, b2 * 0.42, b2]), 2.0),
			"width": ARENA_ROAD_HALF * 0.9, "kind": "main"})
	return out


## 地块上色：把"营地 / 土路 / 矿点 / 大尺度土斑"写进格点表。
## 阈值 0.5 就是**硬边**：这里不做抗锯齿，过渡形状交给图集的 16 个过渡格。
static func _paint_arena_tiles(data: MapData, n_patch: FastNoiseLite, roads: Array) -> void:
	var cells: int = maxi(4, int(round(data.size / ARENA_TILE)))
	data.mat_cells = cells
	data.mat_tile = data.size / float(cells)
	var n: int = cells + 1
	data.mat_nodes.resize(n * n)
	var half: float = data.size * 0.5
	var step: float = data.size / float(cells)
	var bases: Array[Vector2] = data.base_points
	for j in range(n):
		for i in range(n):
			var p := Vector2(-half + float(i) * step, -half + float(j) * step)
			# 营地：只有建筑群脚下那一片是踩实的土（不是整个平台）
			var dirt: float = 1.0 - _sstep(10.0, 19.0, _min_dist(bases, p))
			# 矿点
			for m in data.mines:
				dirt = maxf(dirt, 1.0 - _sstep(3.0, 7.5, p.distance_to(m)))
			# 土路：画出来约 8m 宽（半宽 4m）。魔兽 3 的路就是一条窄土带，
			# 之前按 ARENA_ROAD_HALF 的两倍画，结果整张图 2/3 是土 —— 那才是"很杂"。
			if not roads.is_empty():
				var rd: float = _arena_road_dist(roads, p)
				dirt = maxf(dirt, 1.0 - _sstep(4.0, 6.6, rd))
			# 大尺度土斑（对称噪声）：两级叠加，边界落在 8m 网格上自然成多边形
			var patch: float = (_sym_noise(n_patch, p) + 1.0) * 0.5
			patch = patch * 0.66 + (_sym_noise(n_patch, p * 2.7 + Vector2(31.0, -17.0)) + 1.0) * 0.5 * 0.34
			dirt = maxf(dirt, _sstep(0.70, 0.84, patch))
			data.mat_nodes[j * n + i] = 255 if dirt > 0.5 else 0


## 可走性：边界内缩 + 坡度阈值（和 build() 同一套口径，阈值来自竞技场常量）
static func _arena_walkable(data: MapData) -> void:
	var w: int = int(data.size)
	if data.walkable.size() != w * w:
		data.walkable.resize(w * w)
	var half: float = data.size * 0.5
	for cz in range(w):
		for cx in range(w):
			var wx: float = -half + (float(cx) + 0.5)
			var wz: float = -half + (float(cz) + 0.5)
			var ok: bool = true
			if absf(wx) > half - ARENA_EDGE_MARGIN or absf(wz) > half - ARENA_EDGE_MARGIN:
				ok = false
			if ok:
				var hx: float = data.height_at(wx + 0.6, wz) - data.height_at(wx - 0.6, wz)
				var hz: float = data.height_at(wx, wz + 0.6) - data.height_at(wx, wz - 0.6)
				if Vector2(hx, hz).length() > SLOPE_WALK_MAX:
					ok = false
			data.walkable[cz * w + cx] = 1 if ok else 0


## 树：对称散点。密度由"离基地距离"（中圈林带）和"离边界距离"（外圈林带）决定，
## 避开土路与营地。所有判定都用 canonical 坐标哈希，所以四份完全一致。
static func _arena_place_trees(data: MapData, roads: Array) -> void:
	var half: float = data.size * 0.5
	var step: float = 4.7
	var bases: Array[Vector2] = data.base_points
	var z: float = -half + 8.0
	while z < half - 8.0:
		var x: float = -half + 8.0
		while x < half - 8.0:
			var p := Vector2(x, z)
			x += step
			var c := _canon4(p)
			var hsh: float = _hash_v2(Vector2(c.x * 0.37, c.y * 0.37))
			var db: float = _min_dist(bases, p)
			var band: float = _sstep(26.0, 34.0, db) * (1.0 - _sstep(62.0, 76.0, db))
			var edge: float = _sstep(half * 0.66, half * 0.86, maxf(absf(p.x), absf(p.y)))
			var dense: float = maxf(band * 0.62, edge * 0.88)
			if dense <= 0.01 or hsh > dense:
				continue
			if _arena_road_dist(roads, p) < 7.5:
				continue
			if _terrain_slope(data, p) > 0.75:
				continue
			if not data.is_walkable_at(p.x, p.y):
				continue
			if _near_any(data.trees, p, 2.2):
				continue
			data.trees.append(p)
		z += step


## 岩石：对称散点，主要落在斜坡与边界（纯装饰，走 MultiMesh）
static func _arena_place_rocks(data: MapData, roads: Array) -> void:
	var half: float = data.size * 0.5
	var step: float = 9.0
	var z: float = -half + 10.0
	while z < half - 10.0:
		var x: float = -half + 10.0
		while x < half - 10.0:
			var p := Vector2(x, z)
			x += step
			var c := _canon4(p)
			var hsh: float = _hash_v2(Vector2(c.x * 0.71 + 11.0, c.y * 0.71 - 5.0))
			if hsh > 0.34:
				continue
			if _arena_road_dist(roads, p) < 7.0:
				continue
			var edge: float = _sstep(half * 0.66, half * 0.90, maxf(absf(p.x), absf(p.y)))
			var steep: float = clampf(_terrain_slope(data, p) / 0.7, 0.0, 1.0)
			if edge < 0.2 and steep < 0.40 and hsh > 0.12:
				continue
			if _near_any(data.trees, p, 2.0):
				continue
			var sc: float = 0.55 + hsh * 2.0
			data.rocks.append({
				"pos": p, "scale": sc,
				"rot": _hash_v2(p * 1.9) * TAU,
				"variant": int(_hash_v2(p * 3.1) * 97.0),
				"aniso": Vector3(1.0 + hsh * 0.5, 0.55 + hsh * 0.55, 1.0 - hsh * 0.22),
				"tilt": Vector2((hsh - 0.5) * 0.32, (_hash_v2(p * 5.3) - 0.5) * 0.32),
				"sink": sc * 0.22,
			})
		z += step


## 营地杂物（木箱/木桶/栅栏/篝火）+ 草丛散点。
## 全部按"基地本地坐标 → 四重旋转"落位，四个营地一模一样。
static func _arena_place_decor(data: MapData, roads: Array) -> void:
	var bases: Array[Vector2] = data.base_points
	var offsets: Array = [
		{"kind": "crate", "off": Vector2(-13.0, 9.0), "scale": 1.0},
		{"kind": "crate", "off": Vector2(-15.2, 7.4), "scale": 0.9},
		{"kind": "barrel", "off": Vector2(12.6, 10.5), "scale": 1.0},
		{"kind": "barrel", "off": Vector2(14.4, 8.9), "scale": 0.92},
		{"kind": "fence", "off": Vector2(-4.0, 17.0), "scale": 1.0},
		{"kind": "fence", "off": Vector2(4.0, 17.0), "scale": 1.0},
		{"kind": "campfire", "off": Vector2(0.0, 13.5), "scale": 1.0},
		{"kind": "log", "off": Vector2(-3.4, 15.4), "scale": 1.0},
		{"kind": "tent", "off": Vector2(9.5, 15.0), "scale": 1.0},
	]
	for k in range(bases.size()):
		var b: Vector2 = bases[k]
		# 基地本地坐标系：+Z 朝地图中心（营门朝内），+X 是右手边
		var to_c: Vector2 = (-b).normalized()
		var side := Vector2(-to_c.y, to_c.x)
		for e in offsets:
			var off: Vector2 = e["off"]
			var p: Vector2 = b + to_c * off.y + side * off.x
			data.decor[e["kind"]] = data.decor.get(e["kind"], [])
			_decor_push(data, String(e["kind"]),
				Vector3(p.x, data.height_at(p.x, p.y), p.y),
				float(e["scale"]), _hash_v2(p) * TAU)
	# 草丛：对称散点，只长在草地块上（营地/土路不长草）
	var half: float = data.size * 0.5
	var step: float = 3.4
	var z: float = -half + 6.0
	while z < half - 6.0:
		var x: float = -half + 6.0
		while x < half - 6.0:
			var p := Vector2(x, z)
			x += step
			var c := _canon4(p)
			var hsh: float = _hash_v2(Vector2(c.x * 0.53 + 3.0, c.y * 0.53 + 9.0))
			if hsh > 0.62:
				continue
			if _min_dist(bases, p) < ARENA_PAD_FLAT * 0.72:
				continue
			if _arena_road_dist(roads, p) < ARENA_ROAD_HALF * 1.25:
				continue
			if data.mat_at(p.x, p.y) != 0:
				continue
			data.grass.append({
				"pos": Vector3(p.x, data.height_at(p.x, p.y), p.y),
				"scale": 0.72 + hsh * 0.7,
				"rot": _hash_v2(p * 2.7) * TAU,
			})
		z += step
