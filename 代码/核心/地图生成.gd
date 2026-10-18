class_name MapGenerator
extends RefCounted
## **地图生成器**：程序化产出一张对称、可玩、好看的战场。
##
## 产出：
##   - 高度场（给 RtsTerrain 建网格）
##   - 可走性数组（1 米一格的 PackedByteArray，给 GridPathfinder）
##   - 树 / 岩石 / 金矿的落点
##   - 水潭参数
##
## 全部由 `Cfg.game.map_seed` 决定，**同种子必定同地图**（测试可复现）。
## 布局规律：玩家基地在左下、敌人基地在右上，各有一片平地 + 一座金矿 + 一圈树林，
## 中间是开阔交战区，偏一侧有水潭制造绕行。

## 生成结果
class MapData:
	var size: float = 116.0
	var resolution: int = 58
	## (resolution+1)^2 的高度场
	var heights: PackedFloat32Array = PackedFloat32Array()
	## size×size 的可走性（1=可走），索引 z * size + x
	var walkable: PackedByteArray = PackedByteArray()
	## 树的落点（世界 XZ）
	var trees: Array[Vector2] = []
	## 岩石落点（世界坐标 + 缩放）
	var rocks: Array = []
	## 金矿落点（世界 XZ）
	var mines: Array[Vector2] = []
	## 水潭中心与半径
	var pond_center: Vector2 = Vector2.ZERO
	var pond_radius: float = 0.0
	var pond_level: float = -0.5

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


## 生成整张地图
static func build(cfg: GameConfig) -> MapData:
	var data := MapData.new()
	data.size = cfg.map_size
	data.resolution = maxi(16, cfg.terrain_resolution)
	var res: int = data.resolution
	var row: int = res + 1
	var half: float = data.size * 0.5

	var noise := FastNoiseLite.new()
	noise.seed = cfg.map_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.018
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.45

	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.map_seed

	# --- 1. 高度场 ---
	data.heights.resize(row * row)
	var cell: float = data.size / float(res)
	var base_a := cfg.player_base_pos
	var base_b := cfg.enemy_base_pos
	# 两个基地的基准高度（取基座中心，保证"平地"落在同一水平）
	var h_base_a: float = noise.get_noise_2d(base_a.x, base_a.y) * cfg.terrain_amplitude
	var h_base_b: float = noise.get_noise_2d(base_b.x, base_b.y) * cfg.terrain_amplitude
	h_base_a = clampf(h_base_a, -0.6, 0.8)
	h_base_b = clampf(h_base_b, -0.6, 0.8)

	for gz in range(row):
		for gx in range(row):
			var wx: float = -half + gx * cell
			var wz: float = -half + gz * cell
			var h: float = noise.get_noise_2d(wx, wz) * cfg.terrain_amplitude
			# 边缘拉高一点，像盆地一样把战场围住
			var edge: float = maxf(absi(wx), absi(wz)) / half
			if edge > 0.82:
				var t: float = (edge - 0.82) / 0.18
				h += t * t * 3.2
			# 基地附近压平
			var da: float = Vector2(wx, wz).distance_to(base_a)
			var db: float = Vector2(wx, wz).distance_to(base_b)
			if da < 22.0:
				h = lerpf(h_base_a, h, smoothstep(11.0, 22.0, da))
			if db < 22.0:
				h = lerpf(h_base_b, h, smoothstep(11.0, 22.0, db))
			data.heights[gz * row + gx] = h

	# --- 2. 水潭（在中心偏向一侧，制造绕行） ---
	if cfg.has_pond:
		data.pond_center = Vector2(2.0, 12.0)
		data.pond_radius = 12.0
		for gz in range(row):
			for gx in range(row):
				var wx: float = -half + gx * cell
				var wz: float = -half + gz * cell
				var d: float = Vector2(wx, wz).distance_to(data.pond_center)
				if d < data.pond_radius:
					var k: float = pow(clampf(1.0 - d / data.pond_radius, 0.0, 1.0), 1.3)
					var i: int = gz * row + gx
					data.heights[i] = lerpf(data.heights[i], -1.6, k)
		# 水面高度取潭边地形的稍低处
		data.pond_level = -0.55

	# --- 3. 可走性 ---
	var w: int = int(data.size)
	data.walkable.resize(w * w)
	data.walkable.fill(1)
	var margin: float = 2.5
	for cz in range(w):
		for cx in range(w):
			var wx: float = -half + (cx + 0.5)
			var wz: float = -half + (cz + 0.5)
			var idx: int = cz * w + cx
			var ok: bool = true
			# 边界外圈不可走
			if absf(wx) > half - margin or absf(wz) > half - margin:
				ok = false
			# 水潭不可走
			if ok and cfg.has_pond and data.pond_radius > 0.0:
				if Vector2(wx, wz).distance_to(data.pond_center) < data.pond_radius * 0.92:
					ok = false
			# 太陡的坡不可走（避免单位挂在崖壁上）
			if ok:
				var hx: float = data.height_at(wx + 0.6, wz) - data.height_at(wx - 0.6, wz)
				var hz: float = data.height_at(wx, wz + 0.6) - data.height_at(wx, wz - 0.6)
				if Vector2(hx, hz).length() > 1.45:
					ok = false
			data.walkable[idx] = 1 if ok else 0

	# --- 4. 金矿（每个基地一座，靠近基地但不挡住出兵口） ---
	data.mines.append(base_a + cfg.gold_mine_offset)
	data.mines.append(base_b + cfg.gold_mine_offset)
	# 中间再给一座高产金矿，鼓励扩张与争夺
	data.mines.append(Vector2(-cfg.gold_mine_offset.x * 0.6, -cfg.gold_mine_offset.y * 0.6))

	# --- 5. 树林（成簇分布，避开基地与金矿） ---
	var avoid: Array[Vector2] = [base_a, base_b]
	for m in data.mines:
		avoid.append(m)
	var clusters: int = cfg.tree_clusters
	for ci in range(clusters):
		var center := Vector2.ZERO
		var tries: int = 0
		var placed: bool = false
		while tries < 60 and not placed:
			tries += 1
			# 用极角散布，避免全挤在角落
			var ang: float = rng.randf() * TAU + float(ci) * TAU / float(maxi(1, clusters))
			var rad: float = rng.randf_range(14.0, 46.0)
			center = Vector2(cos(ang), sin(ang)) * rad
			placed = true
			for a in avoid:
				if center.distance_to(a) < 17.0:
					placed = false
					break
			if placed and cfg.has_pond and center.distance_to(data.pond_center) < data.pond_radius + 5.0:
				placed = false
		if not placed:
			continue
		var count: int = rng.randi_range(cfg.tree_cluster_count_min, cfg.tree_cluster_count_max)
		var rad: float = rng.randf_range(cfg.tree_cluster_radius_min, cfg.tree_cluster_radius_max)
		for ti in range(count):
			var off := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * rad
			var p := center + off
			if absf(p.x) > half - 6.0 or absf(p.y) > half - 6.0:
				continue
			var blocked_by_base: bool = false
			for a in [base_a, base_b]:
				if p.distance_to(a) < 15.0:
					blocked_by_base = true
					break
			if blocked_by_base:
				continue
			for m in data.mines:
				if p.distance_to(m) < 7.0:
					blocked_by_base = true
					break
			if blocked_by_base:
				continue
			if cfg.has_pond and p.distance_to(data.pond_center) < data.pond_radius + 1.5:
				continue
			# 树与树之间留一点空，别糊成一球
			var too_close: bool = false
			for t in data.trees:
				if p.distance_to(t) < 2.4:
					too_close = true
					break
			if too_close:
				continue
			data.trees.append(p)

	# --- 6. 岩石（散落装饰 + 阻挡） ---
	for ri in range(cfg.rock_count):
		for tries2 in range(20):
			var p := Vector2(rng.randf_range(-half + 8.0, half - 8.0), rng.randf_range(-half + 8.0, half - 8.0))
			var skip: bool = false
			for a in [base_a, base_b]:
				if p.distance_to(a) < 15.0:
					skip = true
					break
			if skip:
				continue
			if cfg.has_pond and p.distance_to(data.pond_center) < data.pond_radius + 2.0:
				continue
			data.rocks.append({"pos": p, "scale": rng.randf_range(0.75, 1.7), "rot": rng.randf() * TAU})
			break

	# --- 7. 把树 / 岩石 / 金矿写进可走性（阻挡） ---
	for t in data.trees:
		_block_circle(data, t, 0.9)
	for m in data.mines:
		_block_rect(data, m, Vector2i(4, 4))
	for r in data.rocks:
		_block_circle(data, r["pos"], 1.1 * float(r["scale"]))

	return data


## 把某点周围半径内的格子标记为不可走
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


## 把某点为中心的一块矩形标记为不可走
static func _block_rect(data: MapData, pos: Vector2, size_cells: Vector2i) -> void:
	var w: int = int(data.size)
	var half: float = data.size * 0.5
	var cx0: int = int(pos.x + half) - size_cells.x / 2
	var cz0: int = int(pos.y + half) - size_cells.y / 2
	for dz in range(size_cells.y):
		for dx in range(size_cells.x):
			var cx: int = cx0 + dx
			var cz: int = cz0 + dz
			if cx < 0 or cz < 0 or cx >= w or cz >= w:
				continue
			data.walkable[cz * w + cx] = 0
