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
## 可走坡度上限（度）。先按 40° 过滤，若会切断关键目标再逐级放宽；
## 崖壁（60°~90°）在任何一级都过不去，坡道（20°~35°）始终可走。
const WALK_SLOPE_LIMIT_DEG: float = 40.0
const WALK_SLOPE_RELAX_DEG := [46.0, 52.0, 58.0]
## 建筑占地内允许的最大高度极差（米）。超过就不是"平地盖房"，会一半悬空一半埋地。
const BUILD_MAX_HEIGHT_RANGE: float = 0.8
## 本轮可走性校验的回执（阈值/被坡度砍掉的格数/是否放宽）
var _walk_info: Dictionary = {}
## 地形
var terrain: RtsTerrain = null
## 寻路器
var pathfinder: GridPathfinder = null
## 地图数据
var map_data: MapGenerator.MapData = null
## 地图定义（只有走 MapDef 建关时才有；默认程序化地图为 null）
var map_def: MapDef = null
## 是否由自建地图建关（true 时**不生成远景山脊**：那层是给 200m 默认图配的）
var from_map_def: bool = false
## 玩家基地中心 / 敌人基地中心
var _base_pos: Dictionary = {}
## 建筑列表（占格用）
var _buildings: Array = []
## 建筑实例 id → 实际写入寻路网格的格子矩形（含 1 格净空）。
## 为什么单独存：偶数/奇数足迹在 1m 网格上的"中心格"不是对称的，
## 旧实现用 world_to_cell(中心) + footprint+2 会在一边多挖/少挖一格，
## 单位贴墙寻路时就会在"能走/不能走"之间反复横跳。现在按世界包围盒算，
## 左右上下各扩 1 格，清除时用同一份矩形，保证绝对对称。
var _footprint_cells: Dictionary = {}
## 场景容器
var _props_root: Node3D = null
## 本关生成的可采集物（树 / 金矿）
var _harvestables: Array = []


## 建关（主场景调用；不要用 _ready 自动建，方便测试按需构建）
##
## 2026-10-31：主场景换成**竞技场图**（4 个出生点 / 多队 / 四重旋转对称 / 魔兽 3 式地块）。
## 旧的双人对称图（中央台地 + 双峡谷 + 双岩脊）保留为 MapGenerator.build()，供自检用，
## 但它那些"叠加在高度场上的地貌特征"正是"莫名的凸起 + 建筑穿模"的来源，不再做主线。
func build() -> void:
	var cfg: GameConfig = Cfg.game
	var data: MapGenerator.MapData = MapGenerator.build_arena(cfg, cfg.match_slots)
	build_from_data(data, cfg)


## 用现成的 MapData 建关（自检/换图用；不改变 build() 的签名）
## data 走 §2 的稳定字段：size / resolution / heights / walkable / trees / rocks / mines …
func build_from_data(data: MapGenerator.MapData, cfg_override: GameConfig = null) -> void:
	var cfg: GameConfig = cfg_override
	if cfg == null:
		cfg = Cfg.game
	if data == null:
		push_error("[关卡] build_from_data 收到空 MapData")
		return
	map_data = data
	world_size = data.size
	# 出生点：地图给了"每个槽位一个基地"就用它（竞技场图 / 4 队），
	# 否则退回旧的双人配置（点对称）。
	_base_pos.clear()
	if data.base_points.size() > 0:
		for i in range(data.base_points.size()):
			_base_pos[i] = data.base_points[i]
	else:
		_base_pos[RtsConst.Faction.PLAYER] = cfg.player_base_pos
		_base_pos[RtsConst.Faction.ENEMY] = cfg.enemy_base_pos
	_build_world(cfg)


## **用 MapDef 建关**（编辑器 Test Map / `--map=` 流程）。
##
## 这是给地图编辑器长的一层肉，不改动上面的 build()：
##   · 出生点、尺寸、地形全部来自 MapDef；
##   · 可走性由 MapLoader 按高度场 + 对象占地现算，再交给 _prepare_walkability 做坡度兜底；
##   · 地形网格 / 材质 / 寻路完全复用现成实现，所以编辑器里啥样游戏里就啥样。
func build_from_map_def(def: MapDef) -> void:
	if def == null:
		push_error("[关卡] build_from_map_def 收到空 MapDef")
		return
	map_def = def
	# ★ 自建地图 = 完整世界，**绝不能再套一层远景山脊**。
	#   远景山脊的半径是给 200m 默认图写死的（142/184/252m），
	#   套到 256m 自建图上会直接长在地图里面 —— 表现为"地图上冒出高高突出的尖刺和山"。
	from_map_def = true
	var cfg: GameConfig = Cfg.game
	var data: MapGenerator.MapData = MapLoader.to_map_data(def)
	if data == null:
		push_error("[关卡] MapLoader.to_map_data 返回空")
		return
	# ★ 出生点只有一个来源：MapDef 的玩家槽位 → MapData.base_points。
	#   build_from_data 会按槽位顺序把它们灌进 _base_pos（多队图 = 4 个角）。
	#   旧版只取 players[0] 和 enemy_slot() 两个点，4 队图的后两家会掉回 cfg 坐标。
	build_from_data(data, cfg)


## 把 MapData 变成场景内容：地形 → 可走性校验 → 寻路 → 远景 → 道具容器
func _build_world(cfg: GameConfig) -> void:
	# --- 1. 地形 ---
	terrain = RtsTerrain.new()
	terrain.name = "地形"
	add_child(terrain)
	# 地标先喂给地形：着色要把"台地顶"画成草皮而不是岩盘，崖壁雕刻要避开坡道。
	if map_data.plateau is Dictionary and not (map_data.plateau as Dictionary).is_empty():
		var plateau: Dictionary = map_data.plateau
		terrain.plateau_center = plateau.get("center", Vector2.ZERO)
		terrain.plateau_radius = float(plateau.get("radius", 0.0))
		terrain.plateau_top = float(plateau.get("top", 0.0))
	var ramp_angles := PackedFloat32Array()
	if map_data.ramps is Array:
		for rp in map_data.ramps:
			if rp is Dictionary and rp.has("angle"):
				ramp_angles.append(float(rp["angle"]))
	terrain.ramp_angles = ramp_angles
	# 营地地标：着色时把基地半径内的地面压暗一点、干裂纹减半（"踩实的营地"）。
	# 有多少个出生点就喂多少个 —— 多队图不能再写死"玩家 / 敌人"两个。
	var bases := PackedVector2Array()
	for k in _base_pos.keys():
		var bp: Vector2 = _base_pos[k]
		if bp != Vector2.ZERO:
			bases.append(bp)
	terrain.base_points = bases
	# 地块格点表：魔兽 3 口径（材质存在共享格点上，一格读四个角）
	terrain.mat_cells = map_data.mat_cells
	terrain.mat_nodes = map_data.mat_nodes
	# 生态：和编辑器共用同一份换色参数，改生态不用重出贴图
	terrain.biome = map_data.biome
	# 远景山脊：自建地图一律不要（半径是给 200m 默认图写死的），
	# 竞技场图自己也会把 map_data.far_ridges 置 false。
	var want_ridges: bool = (not from_map_def) and bool(map_data.get("far_ridges"))
	terrain.build(world_size, map_data.resolution, map_data.heights, want_ridges)
	if cfg != null and cfg.has_pond and map_data.pond_radius > 0.0:
		terrain.build_water(map_data.pond_center, map_data.pond_radius, map_data.pond_level)

	# --- 1.5 地表碎石的落位校准 ---
	# 地图生成器的 rubble 是按"压平前"的高度落位的；地形层刚刚雕刻过崖壁/山脊，
	# 不重新贴地会有一部分石头悬空/埋进崖壁。顺便把粒径收小：台地顶的碎石应该是
	# "草间砾石"，不是一层白色巨石；台地顶圆盘内再稀疏一半。
	_tune_surface_debris()

	# --- 1.6 台地顶可建区清障 ---
	# 地图生成器会在台地顶撒装饰岩石，并把它们写进寻路网格。结果就是
	# "台地顶看着平，却因为一块 1m 的石头放不下 4×4 建筑"。
	# 这里只清台地顶圆盘内的石头占格（金矿/树占格一律不动），
	# 并把石头挪到崖脚当碎石——视觉不退步，可建区是真正的平地。
	_free_plateau_build_pad()

	# --- 2. 可走性：以 MapData.walkable 为底，补上坡度阈值校验 ---
	# 为什么还要二次校验：地图生成器只保证它自己那套阈值；崖壁/台地边缘一旦漏标，
	# 单位就会挂在 60° 的岩壁上。这里用**建好的地形三角面**重算坡度，坡道留、崖壁砍。
	_prepare_walkability()

	# --- 3. 寻路网格 ---
	pathfinder = GridPathfinder.new()
	pathfinder.build(world_size, map_data.walkable)

	# --- 3.5 崖脚碎石（纯装饰，追加在寻路网格建好之后，不影响可走性） ---
	_append_cliff_scree()

	# --- 4. 远景底板 ---
	# 为什么需要它：镜头看向地图角落时，屏幕四角的射线会打到地图外面，
	# 哪里什么都没有 → 直接看到天空，像世界破了个洞。铺一张更大的暗色底板盖住，
	# 视觉上就变成"远处的荒原"，配合雾效果很自然。
	# 高度要压到**地形最低点以下**：新图有 -3~-8m 的沟壑，还按 -2.2 会盖住沟底。
	_build_backdrop()

	# --- 5. 道具容器 ---
	_props_root = Node3D.new()
	_props_root.name = "场景道具"
	add_child(_props_root)

	# --- 6. 基地石板庭院（纯视觉，不进寻路） ---
	# 新建筑是"石砌 + 瓦面"的体量，直接落在草地上会像模型摆件。
	# 一圈边缘磨损的石板场把三座建筑绑成一个"营地"，也给接触阴影一个落点。
	# _build_base_courtyard(Vector2(_base_pos.get(RtsConst.Faction.PLAYER, Vector2.ZERO)))
	# _build_base_courtyard(Vector2(_base_pos.get(RtsConst.Faction.ENEMY, Vector2.ZERO)))


# ===========================================================================
# 可走性：坡度阈值校验 + 连通性兜底
# ===========================================================================

## 地表碎石校准：重新贴地 + 收小粒径 + 台地顶稀疏化。
## 只动 map_data.rubble（纯装饰，不进 walkable），不碰 装饰库.gd。
func _tune_surface_debris() -> void:
	if map_data == null or terrain == null:
		return
	var center: Vector2 = terrain.plateau_center
	var top_r: float = maxf(0.0, terrain.plateau_radius - 4.5)
	var kept: Array = []
	var top_i: int = 0
	var all_i: int = 0
	for r in map_data.rubble:
		all_i += 1
		# 全局保留 1/3：620 颗全铺出来像下了场白色冰雹，读不出"崖脚碎石"
		if all_i % 3 != 0:
			continue
		var p: Vector3 = r["pos"]
		var p2 := Vector2(p.x, p.z)
		if top_r > 0.0 and p2.distance_to(center) < top_r:
			top_i += 1
			if top_i % 2 != 0:
				continue
		r["scale"] = maxf(0.26, float(r.get("scale", 1.0)) * 0.45)
		r["pos"] = Vector3(p.x, terrain.height_at(p.x, p.z) + 0.04, p.z)
		kept.append(r)
	map_data.rubble = kept


## 台地顶可建区清障。
##
## 地图生成器把装饰岩石也写进了 walkable（1.05×scale 半径）。台地顶本来是最该能
## 放建筑的地方，却常被一块 1m 的石头卡掉整片 4×4 —— 这不是"地形不允许"，是道具问题。
## 处理：只清台地顶圆盘内（半径 - 4.5m）的石头占格；金矿 4×4、树心占格不动
## （_cell_protected 兜底），并把这些石头挪到崖脚当落石，视觉不丢。
func _free_plateau_build_pad() -> void:
	if map_data == null or terrain == null or terrain.plateau_radius <= 0.0:
		return
	var center: Vector2 = terrain.plateau_center
	var top_r: float = maxf(6.0, terrain.plateau_radius - 4.5)
	for r in map_data.rocks:
		var p: Vector2 = r["pos"]
		if p.distance_to(center) >= top_r:
			continue
		_unblock_rock_cells(p, float(r["scale"]))
		# 挪到崖脚：角度沿用原方位，半径推到台地肩外 3~7m；坡道扇区里再让开一点
		var ang: float = (p - center).angle()
		if _near_ramp_angle(ang, 0.42):
			ang += 0.55
		var rr: float = terrain.plateau_radius + 3.0 + _hash01(int(p.x * 7.0), int(p.y * 7.0)) * 4.5
		r["pos"] = center + Vector2(cos(ang), sin(ang)) * rr


## 清掉一块装饰岩石写进 walkable 的圆形占格（只用于台地顶；不碰矿/树）
func _unblock_rock_cells(pos: Vector2, rock_scale: float) -> void:
	if map_data == null:
		return
	var w: int = int(round(world_size))
	var half: float = world_size * 0.5
	if map_data.walkable.size() != w * w:
		return
	var cx0: int = int(pos.x + half)
	var cz0: int = int(pos.y + half)
	var rad: int = ceili(1.05 * rock_scale)
	for dz in range(-rad, rad + 1):
		for dx in range(-rad, rad + 1):
			if dx * dx + dz * dz > rad * rad:
				continue
			var cx: int = cx0 + dx
			var cz: int = cz0 + dz
			if cx < 0 or cz < 0 or cx >= w or cz >= w:
				continue
			var wx: float = -half + float(cx) + 0.5
			var wz: float = -half + float(cz) + 0.5
			if _cell_holds_prop(wx, wz):
				continue
			# 坡上不开口子：只清台地顶真正平的地方
			if terrain != null and terrain.slope_degrees_at(wx, wz, 0.6) > 22.0:
				continue
			map_data.walkable[cz * w + cx] = 1


## 这一格是否被金矿/树占着（清石占格时的保护名单）
func _cell_holds_prop(wx: float, wz: float) -> bool:
	if map_data == null:
		return false
	for m in map_data.mines:
		if absf(wx - m.x) <= 2.6 and absf(wz - m.y) <= 2.6:
			return true
	for t in map_data.trees:
		if Vector2(wx, wz).distance_to(t) < 1.35:
			return true
	return false


## 崖脚碎石/落石：纯装饰，追加在寻路网格建好之后（不写 walkable，也不改高度）。
##
## 判定：格子本身是 26°~64° 的坡，沿下坡方向 2.4m 处变缓（<20°）→ 那里就是崖脚。
## 用确定性哈希稀疏取样，避免糊成一条石头项链。
func _append_cliff_scree() -> void:
	if terrain == null or map_data == null:
		return
	var half: float = world_size * 0.5
	var step: float = 3.0
	var added: int = 0
	var z: float = -half + 7.0
	while z < half - 7.0 and added < 120:
		var x: float = -half + 7.0
		while x < half - 7.0 and added < 120:
			var s: float = terrain.slope_degrees_at(x, z, 0.9)
			if s >= 26.0 and s <= 64.0:
				var h0: float = terrain.height_at(x, z)
				var gx: float = terrain.height_at(x + 1.0, z) - terrain.height_at(x - 1.0, z)
				var gz: float = terrain.height_at(x, z + 1.0) - terrain.height_at(x, z - 1.0)
				var gl: float = sqrt(gx * gx + gz * gz)
				if gl > 0.01:
					var px: float = x - gx / gl * 2.4
					var pz: float = z - gz / gl * 2.4
					var ps: float = terrain.slope_degrees_at(px, pz, 0.8)
					var ph: float = terrain.height_at(px, pz)
					if ps < 20.0 and ph < h0 + 0.15 and ph > -7.0:
						var key: float = _hash01(int(px * 3.0), int(pz * 3.0))
						if key < 0.62 and not _near_prop_flat(Vector2(px, pz), 2.5) \
								and not _scree_already_there(Vector2(px, pz)):
							map_data.rocks.append({
								"pos": Vector2(px, pz),
								"scale": 0.14 + key * 0.26,
								"rot": key * TAU,
							})
							added += 1
			x += step
		z += step


## 碎石避让压平区（基地/矿/坡道落客区），免得在集结场上撒一地石头
func _near_prop_flat(p: Vector2, extra: float) -> bool:
	if map_data == null:
		return false
	for z in map_data.flat_zones:
		if p.distance_to(z["pos"]) < float(z["radius"]) + extra:
			return true
	return false


## 这个位置是否已经有岩石（防止重建关时把崖脚碎石又生成一遍）
## 为什么需要：从地图文件读回来的图，ground.rocks 里已经带着上次生成的碎石，
## 再跑一遍 _append_cliff_scree 就是双份 —— 同位置两块石头会 z-fighting。
func _scree_already_there(p: Vector2) -> bool:
	if map_data == null:
		return false
	for r in map_data.rocks:
		var rp: Vector2 = r.get("pos", Vector2.ZERO)
		if rp.distance_to(p) < 1.2:
			return true
	return false


## 角度是否落在坡道扇区
func _near_ramp_angle(ang: float, half_width: float) -> bool:
	if map_data == null or not (map_data.ramps is Array):
		return false
	for rp in map_data.ramps:
		if rp is Dictionary and rp.has("angle"):
			var d: float = fposmod(ang - float(rp["angle"]) + PI, TAU) - PI
			if absf(d) <= half_width:
				return true
	return false


## 确定性 0..1 哈希（关卡侧只用它做碎石/挪石头）
func _hash01(x: int, z: int) -> float:
	var v: float = sin(float(x) * 12.9898 + float(z) * 78.233) * 43758.5453
	return v - floorf(v)


## 以 MapData.walkable 为底，按地形坡度砍掉崖壁；若会切断基地/中央/资源，
## 逐级放宽阈值（40→46→52→58°），保证不会因为"校验太严"把地图切成孤岛。
## 58° 仍不连通才退回原始 walkable（并打标记，让自检/Lead 看见）。
func _prepare_walkability() -> void:
	var w: int = maxi(8, int(round(world_size)))
	var src := map_data.walkable
	if src.size() != w * w:
		push_warning("[关卡] walkable 长度 %d 与 %d² 不匹配，按全可走重建" % [src.size(), w])
		src = PackedByteArray()
		src.resize(w * w)
		src.fill(1)

	var thresholds: Array = [WALK_SLOPE_LIMIT_DEG]
	thresholds.append_array(WALK_SLOPE_RELAX_DEG)
	var chosen: PackedByteArray = src
	var chosen_deg: float = 0.0
	var chosen_blocked: int = 0
	var fallback: bool = false
	var relaxed: bool = false

	var attempts: Array = []
	var last_report: Dictionary = {}
	for idx in range(thresholds.size()):
		var deg: float = float(thresholds[idx])
		var cand: PackedByteArray = _filter_walkable_by_slope(src, w, deg)
		var blocked: int = _count_changed(src, cand)
		var rep: Dictionary = _connectivity_report(cand, w)
		attempts.append({"deg": deg, "blocked": blocked, "ok": bool(rep.get("ok", false)),
			"failed": rep.get("failed", [])})
		last_report = rep
		if bool(rep.get("ok", false)):
			chosen = cand
			chosen_deg = deg
			chosen_blocked = blocked
			relaxed = idx > 0
			break
		# 记下最后一个候选，万一全都不连通也有个可解释的结果
		chosen = cand
		chosen_deg = deg
		chosen_blocked = blocked

	if not bool(last_report.get("ok", false)) or not _connectivity_report(chosen, w).get("ok", false):
		# 真兜底：生成器自己的 walkable 至少保证能玩；宁可崖壁漏标，也不能把基地封死。
		chosen = src.duplicate()
		chosen_deg = 0.0
		chosen_blocked = 0
		fallback = true
		push_warning("[关卡] 坡度校验在所有阈值下都不连通，退回 MapData.walkable（坡度过滤未生效）不连通目标=%s"
			% str(last_report.get("failed", [])))
	elif not (last_report.get("soft_failed", []) as Array).is_empty():
		print("[关卡] 连通性抽查：%d 个软目标（树）不可达，不影响坡度校验"
			% (last_report.get("soft_failed", []) as Array).size())

	map_data.walkable = chosen
	_walk_info = {
		"size": w,
		"limit_deg": chosen_deg,
		"blocked_by_slope": chosen_blocked,
		"relaxed": relaxed,
		"fallback": fallback,
		"walkable": _count_walkable(chosen),
		"attempts": attempts,
		"failed_targets": last_report.get("failed", []),
		"soft_failed_targets": last_report.get("soft_failed", []),
	}


## 按坡度阈值过滤：只把原本可走、但地形太陡的格改成不可走
func _filter_walkable_by_slope(src: PackedByteArray, w: int, deg: float) -> PackedByteArray:
	var out: PackedByteArray = src.duplicate()
	if terrain == null:
		return out
	var limit: float = tan(deg_to_rad(deg))
	var half: float = world_size * 0.5
	var eps: float = 0.75
	for z in range(w):
		for x in range(w):
			var i: int = z * w + x
			if out[i] == 0:
				continue
			var wx: float = -half + float(x) + 0.5
			var wz: float = -half + float(z) + 0.5
			var hx: float = (terrain.height_at(wx + eps, wz) - terrain.height_at(wx - eps, wz)) / (2.0 * eps)
			var hz: float = (terrain.height_at(wx, wz + eps) - terrain.height_at(wx, wz - eps)) / (2.0 * eps)
			if sqrt(hx * hx + hz * hz) > limit:
				out[i] = 0
	return out


func _count_changed(a: PackedByteArray, b: PackedByteArray) -> int:
	var n: int = mini(a.size(), b.size())
	var c: int = 0
	for i in range(n):
		if a[i] != 0 and b[i] == 0:
			c += 1
	return c


func _count_walkable(a: PackedByteArray) -> int:
	var c: int = 0
	for i in range(a.size()):
		if a[i] != 0:
			c += 1
	return c


## 关键目标连通性回执（带"谁不可达"，方便定位是校验太严还是生成器本身断路）
##
## 目标集合（按 Lead 2026-10-18 的口径收窄，避免把"森林内部树心/外圈山脊"当必须可达）：
##   · 双方基地
##   · 全部金矿
##   · 中央台地（优先读 MapData.plateau.center；没有新字段才在中心区域找最高点）
##   · 每条坡道的坡口 / 坡顶（新字段 ramps）
##   · 双方基地各最近的 2 棵树（树心本身占格，检查的是树旁可走格）
func _connectivity_report(cand: PackedByteArray, w: int) -> Dictionary:
	if cand.size() != w * w:
		return {"ok": false, "failed": ["walkable 尺寸不匹配"], "checked": 0}
	var start: Vector2i = _nearest_walkable_in(cand, w, _base_cell(RtsConst.Faction.PLAYER, w))
	if start.x < 0:
		return {"ok": false, "failed": ["玩家基地附近没有可走格"], "checked": 0}
	var seen: PackedByteArray = _bfs_reachable(cand, w, start)
	if seen.size() != cand.size():
		return {"ok": false, "failed": ["BFS 尺寸异常"], "checked": 0}

	var targets: Array = []
	var pb: Vector2 = _base_pos.get(RtsConst.Faction.PLAYER, Vector2.ZERO)
	var eb: Vector2 = _base_pos.get(RtsConst.Faction.ENEMY, Vector2.ZERO)
	targets.append({"pos": pb, "kind": "base_player"})
	targets.append({"pos": eb, "kind": "base_enemy"})
	if map_data != null:
		for m in map_data.mines:
			targets.append({"pos": m, "kind": "mine"})
		var ramps: Variant = map_data.get("ramps")
		if ramps is Array:
			for rp in ramps:
				if rp is Dictionary:
					if rp.has("mouth"):
						targets.append({"pos": rp["mouth"], "kind": "ramp_mouth"})
					if rp.has("top_pos"):
						targets.append({"pos": rp["top_pos"], "kind": "ramp_top"})
		# 只取每个基地最近的 2 棵树；不再要求每一棵树心都可达
		var tree_targets: Array = _nearest_trees_to_base(map_data.trees, pb, 2)
		tree_targets.append_array(_nearest_trees_to_base(map_data.trees, eb, 2))
		for t in tree_targets:
			targets.append({"pos": t, "kind": "tree_near_base"})
	# 中央台地目标：优先用 MapData 新字段，其次才用中心区域最高点
	var cp: Vector3 = central_plateau_point()
	targets.append({"pos": Vector2(cp.x, cp.z), "kind": "mesa"})

	var failed: Array = []
	var soft_failed: Array = []
	for td in targets:
		var tp: Vector2 = td["pos"]
		var cell: Vector2i = _world_cell(tp, w)
		var c: Vector2i = _nearest_walkable_in(cand, w, cell)
		# "基地附近的树"只是资源可达性抽查：树心本身占格，密林里抽到一棵被同伴
		# 围死的树很常见，它不该判"整张图不连通"（否则 40/46/52/58° 全被否掉，
		# 坡度校验直接失效）。硬目标（基地/金矿/坡道/中央）才算连通性错误。
		var soft: bool = String(td["kind"]) == "tree_near_base"
		var why: String = ""
		if c.x < 0:
			why = "%s@(%.1f,%.1f):附近无可走格" % [td["kind"], tp.x, tp.y]
		elif seen[c.y * w + c.x] == 0:
			why = "%s@(%.1f,%.1f):不可达" % [td["kind"], tp.x, tp.y]
		if why.is_empty():
			continue
		if soft:
			soft_failed.append(why)
		else:
			failed.append(why)
	return {"ok": failed.is_empty(), "failed": failed, "soft_failed": soft_failed,
		"checked": targets.size()}


## 取离基地最近的 n 棵树（只用于连通性抽查，不是"每棵树都必须可达"）
func _nearest_trees_to_base(trees: Array[Vector2], base: Vector2, n: int) -> Array:
	var picked: Array = []
	for t in trees:
		var d: float = t.distance_to(base)
		var inserted: bool = false
		for i in range(picked.size()):
			if d < float(picked[i]["d"]):
				picked.insert(i, {"p": t, "d": d})
				inserted = true
				break
		if not inserted:
			picked.append({"p": t, "d": d})
		if picked.size() > n:
			picked.pop_back()
	var out: Array = []
	for e in picked:
		out.append(e["p"])
	return out


func _base_cell(faction_idx: int, w: int) -> Vector2i:
	var p: Vector2 = _base_pos.get(faction_idx, Vector2.ZERO)
	return _world_cell(p, w)


func _world_cell(p: Vector2, w: int) -> Vector2i:
	var half: float = world_size * 0.5
	return Vector2i(floori(p.x + half), floori(p.y + half))


## 在候选 walkable 里找最近可走格（螺旋外扩，最多 24 格）
func _nearest_walkable_in(cand: PackedByteArray, w: int, cell: Vector2i, max_r: int = 24) -> Vector2i:
	if cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < w:
		if cand[cell.y * w + cell.x] != 0:
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
				if cand[cz * w + cx] != 0:
					return Vector2i(cx, cz)
	return Vector2i(-1, -1)


## 8 邻域 BFS（斜向不许穿墙角，和 A* 的"禁止切角"一致）
func _bfs_reachable(cand: PackedByteArray, w: int, start: Vector2i) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(w * w)
	seen.fill(0)
	if start.x < 0:
		return seen
	var queue := PackedInt32Array()
	var s: int = start.y * w + start.x
	queue.append(s)
	seen[s] = 1
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
				if cand[ni] == 0 or seen[ni] != 0:
					continue
				if dx != 0 and dz != 0:
					if cand[cz * w + nx] == 0 or cand[nz * w + cx] == 0:
						continue
				seen[ni] = 1
				queue.append(ni)
	return seen


## 地形网格统计 + 可走性回执（自检/汇报用）
func terrain_stats() -> Dictionary:
	var d: Dictionary = {
		"world_size": world_size,
		"resolution": map_data.resolution if map_data != null else 0,
		"walkability": _walk_info.duplicate(true),
	}
	if terrain != null:
		d["height_min"] = terrain.height_min()
		d["height_max"] = terrain.height_max()
		d["height_range"] = terrain.height_range()
		d["max_slope_deg"] = terrain.max_slope_degrees()
		d["triangle_count"] = terrain.triangle_count()
		d["subdivided_cells"] = terrain.subdivided_cell_count()
		d["steep_face_ratio"] = terrain.steep_face_ratio()
	if pathfinder != null:
		var w: int = int(round(world_size))
		d["walkable_cells"] = _count_walkable(map_data.walkable)
		d["walkable_ratio"] = float(d["walkable_cells"]) / float(maxi(1, w * w))
	return d


## 中央台地代表点（世界坐标，已贴地）。
## 关键修正：不能用"全图最高点"当中央台地——200m 新图外圈有 26m 山脊，
## 那样每个坡度阈值都会被判不连通。优先读 MapData.plateau.center，旧图才回退到中心区域最高点。
func central_plateau_point() -> Vector3:
	if map_data != null:
		var p: Variant = map_data.get("plateau")
		if p is Dictionary and (p as Dictionary).has("center"):
			var c: Vector2 = (p as Dictionary)["center"]
			return snap_to_ground(Vector3(c.x, 0.0, c.y))
	if map_data == null or map_data.heights.is_empty():
		return Vector3.ZERO
	var row: int = map_data.resolution + 1
	var cell: float = world_size / float(maxi(1, map_data.resolution))
	var half: float = world_size * 0.5
	var r_lim: float = world_size * 0.30
	var best := Vector3.ZERO
	var best_h: float = -1e20
	for i in range(map_data.heights.size()):
		var gx: int = i % row
		var gz: int = i / row
		var wx: float = -half + float(gx) * cell
		var wz: float = -half + float(gz) * cell
		if absf(wx) > r_lim or absf(wz) > r_lim:
			continue
		if map_data.heights[i] > best_h:
			best_h = map_data.heights[i]
			best = Vector3(wx, best_h, wz)
	if best_h < -1e19:
		return snap_to_ground(Vector3.ZERO)
	return snap_to_ground(best)


## 兼容旧名：连通性目标要的是中央台地，不是外圈山脊
func highest_point() -> Vector3:
	return central_plateau_point()


## 真正的地图最高点（只给统计/报告用，不参与连通性）
func absolute_highest_point() -> Vector3:
	if map_data == null or map_data.heights.is_empty():
		return Vector3.ZERO
	var row: int = map_data.resolution + 1
	var cell: float = world_size / float(maxi(1, map_data.resolution))
	var half: float = world_size * 0.5
	var best_i: int = 0
	var best_h: float = -1e20
	for i in range(map_data.heights.size()):
		if map_data.heights[i] > best_h:
			best_h = map_data.heights[i]
			best_i = i
	var gx: int = best_i % row
	var gz: int = best_i / row
	return Vector3(-half + float(gx) * cell, best_h, -half + float(gz) * cell)


## 本轮坡度校验回执
func walkability_info() -> Dictionary:
	return _walk_info.duplicate(true)


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


## 带地形高度的路径（签名不变；内部做"贴地加密"）
##
## 为什么还要加密：A* 只保证**途经格可走**，路径平滑后相邻两个路点可能隔十几米；
## 一条直线段跨过圆润的坡顶/坡脚时，中段会离地 1~3m（单位脚下贴地，但转向轨迹会飘）。
## 这里按 0.75m 采样，凡中段与线性插值高差 >0.35m 就插入一个贴地中点（最多递归 3 层），
## 让路点真的贴着坡面走。坡道/台地边缘的"贴地"就是这么补出来的。
func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if pathfinder == null:
		return PackedVector3Array()
	var raw: PackedVector3Array = pathfinder.find_path(from, to)
	if raw.is_empty():
		return PackedVector3Array()
	var start: Vector3 = snap_to_ground(from)
	var out := PackedVector3Array()
	var prev: Vector3 = start
	for p in raw:
		var pt: Vector3 = snap_to_ground(p)
		_append_ground_segment(out, prev, pt, 0)
		prev = pt
	return out


## 递归补点：中段离地超过阈值就插一个贴地中点
func _append_ground_segment(out: PackedVector3Array, a: Vector3, b: Vector3, depth: int) -> void:
	var seg: float = Vector2(b.x - a.x, b.z - a.z).length()
	if seg < 0.8 or depth >= 3:
		out.append(b)
		return
	var steps: int = maxi(2, int(ceil(seg / 0.75)))
	var max_dev: float = 0.0
	for i in range(1, steps):
		var t: float = float(i) / float(steps)
		var p: Vector3 = a.lerp(b, t)
		var h: float = height_at(p.x, p.z)
		var lin: float = lerpf(a.y, b.y, t)
		max_dev = maxf(max_dev, absf(h - lin))
	if max_dev <= 0.35:
		out.append(b)
		return
	var mid: Vector3 = a.lerp(b, 0.5)
	mid.y = height_at(mid.x, mid.z)
	# 中点必须仍然"走得过去"——不能为了贴地把路径插进墙/崖里
	if pathfinder.line_of_sight(a, mid) and pathfinder.line_of_sight(mid, b):
		_append_ground_segment(out, a, mid, depth + 1)
		_append_ground_segment(out, mid, b, depth + 1)
	else:
		out.append(b)


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


## 某个位置 + 占地是否允许建造。
##
## 原有判定（越界/压建筑/水面）全部保留：水面和建筑在 walkable 里就是 0。
## 新增一条**坡度约束**：占地覆盖范围内地形高度极差 > BUILD_MAX_HEIGHT_RANGE 就拒绝。
## 为什么：新图有台地/沟壑，斜坡上盖 8×8 大本营会一半悬空一半埋地；
## 台地顶/低地平地的高度极差通常 <0.3m，照样能建。
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
	if footprint.x > 0 and footprint.y > 0:
		if footprint_height_range(pos, footprint) > BUILD_MAX_HEIGHT_RANGE:
			return false
	return true


## 建筑占地覆盖范围内的地形高度极差（米）。按 1m 级采样，避免只量四角漏掉中间鼓包。
func footprint_height_range(pos: Vector3, footprint: Vector2i) -> float:
	if terrain == null or footprint.x <= 0 or footprint.y <= 0:
		return 0.0
	var x0: float = pos.x - float(footprint.x) * 0.5
	var x1: float = pos.x + float(footprint.x) * 0.5
	var z0: float = pos.z - float(footprint.y) * 0.5
	var z1: float = pos.z + float(footprint.y) * 0.5
	var nx: int = clampi(int(ceil(float(footprint.x))), 2, 32)
	var nz: int = clampi(int(ceil(float(footprint.y))), 2, 32)
	var lo: float = 1e20
	var hi: float = -1e20
	for iz in range(nz + 1):
		var tz: float = float(iz) / float(nz)
		var wz: float = lerpf(z0, z1, tz)
		for ix in range(nx + 1):
			var tx: float = float(ix) / float(nx)
			var wx: float = lerpf(x0, x1, tx)
			var h: float = terrain.height_at(wx, wz)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return maxf(0.0, hi - lo)


## 把建筑占地写进寻路网格（建成/放下时调用）
func mark_footprint(building: Node3D) -> void:
	if building == null or pathfinder == null:
		return
	var def: UnitDef = building.def
	if def == null or def.footprint == Vector2i.ZERO:
		return
	var rect: Rect2i = _footprint_cell_rect(building, def, 1)
	_apply_footprint_rect(rect, true)
	_footprint_cells[building.get_instance_id()] = rect
	if not _buildings.has(building):
		_buildings.append(building)


## 清除建筑占地（建筑被拆时调用）
func clear_footprint(building: Node3D) -> void:
	if building == null or pathfinder == null:
		return
	var def: UnitDef = building.def
	if def == null:
		return
	var key: int = building.get_instance_id()
	var rect: Rect2i = _footprint_cells.get(key, Rect2i())
	if rect.size.x <= 0 or rect.size.y <= 0:
		rect = _footprint_cell_rect(building, def, 1)
	_apply_footprint_rect(rect, false)
	_footprint_cells.erase(key)
	_buildings.erase(building)


## 建筑占地在 **1m 寻路网格** 上的格子矩形（含净空）。
## 世界→格：格子 i 覆盖 [i - half, i+1 - half)。
## 用包围盒的 min/max 取 floor/ceil，再向四周各扩 clearance 格；
## 这样 8×8 / 6×6 / 3×3 在偶数/奇数足迹下都是**对称**的。
func _footprint_cell_rect(building: Node3D, def: UnitDef, clearance: int) -> Rect2i:
	var half: float = world_size * 0.5
	var fp: Vector2i = def.footprint
	var center: Vector3 = building.global_position
	var min_x: float = center.x - float(fp.x) * 0.5
	var max_x: float = center.x + float(fp.x) * 0.5
	var min_z: float = center.z - float(fp.y) * 0.5
	var max_z: float = center.z + float(fp.y) * 0.5
	var x0: int = floori(min_x + half) - clearance
	var x1: int = ceili(max_x + half) + clearance
	var z0: int = floori(min_z + half) - clearance
	var z1: int = ceili(max_z + half) + clearance
	return Rect2i(x0, z0, maxi(1, x1 - x0), maxi(1, z1 - z0))


## 把矩形逐格写进/清出寻路网格（带边界裁剪）
func _apply_footprint_rect(rect: Rect2i, blocked: bool) -> void:
	if pathfinder == null or rect.size.x <= 0 or rect.size.y <= 0:
		return
	for z in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			pathfinder.mark_blocked(Vector2i(x, z), blocked)


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
	# 树：位置 + 程序化外观参数（品种 / 种子 / 朝向）。
	# 程序化地图没存种子时留空 —— 由 树库.proc_at(落点) 反推，同一棵每次进游戏都长一样。
	#
	# ★ 先只预热"本图真的会用到的品种"：程序化地图只要夏季（树库.WILD_SEASON），
	#   编辑器手摆的地图可能带着 tree_秋 这类显式品种，那就把它们都收进来。
	#   一份网格 ~1ms，全量预热也就几十毫秒 —— 但能省就省，别为用不到的三季付费。
	var 用到的品种: Array = []
	for proc0 in map_data.trees_proc:
		var s0: String = String((proc0 as Dictionary).get("season", ""))
		if s0.is_empty():
			s0 = String((proc0 as Dictionary).get("id", "tree"))
		s0 = TreeLibrary.season_of(s0, 0)
		if not 用到的品种.has(s0):
			用到的品种.append(s0)
	if 用到的品种.is_empty():
		用到的品种 = [TreeLibrary.WILD_SEASON]
	TreeLibrary.prewarm(用到的品种, float(Cfg.unit(&"tree").height))
	for i in map_data.trees.size():
		var t: Vector2 = map_data.trees[i]
		var p := snap_to_ground(Vector3(t.x, 0.0, t.y))
		var proc: Dictionary = {}
		if i < map_data.trees_proc.size():
			proc = map_data.trees_proc[i]
		# 品种由 id 决定：编辑器摆的是 tree_秋 就长秋树；程序化地图统一 tree（混生）。
		var id := StringName(String(proc.get("id", "tree")))
		_spawn_harvestable(id, p, proc)
	# 每棵树 1 个 surface / 1 个材质（旧管线是 5 个材质 = 5 次 draw call）。
	# 一行日志方便以后回归时看数量级：树 150 棵 ≈ 150 draw call，面数走三档 LOD。
	var 池: Dictionary = TreeLibrary.stats()
	print("[关卡] 树：%d 棵（程序化生成，网格池 %d 份，%s）" % [
		map_data.trees.size(), int(池["网格份数"]), String(池["LOD"])])
	# 岩石（纯装饰）：用 MultiMesh 合批。
	# 原来 26 块 × 4 个子网格 = 104 个 MeshInstance（104 次 draw call），
	# 现在每种子网格一份 MultiMesh，总共只要 4 次。
	_build_rock_multimesh(map_data.rocks)


## 生成一个可采集物
func _spawn_harvestable(id: StringName, pos: Vector3, proc: Dictionary = {}) -> Node3D:
	var n: Node3D = Game.spawn_unit(null, id, pos, _props_root, proc)
	if n == null:
		return null
	if id == &"goldmine":
		# 资产约定：模型正面朝 -Z；而镜头从南往北看，矿洞门/矿车在背面。
		# 金矿转 180°，让"值钱的一面"（金脉/木门/矿车）朝向玩家。
		n.rotation.y = PI
		var glow := OmniLight3D.new()
		glow.name = "矿灯"
		glow.light_color = Color(1.0, 0.72, 0.34)
		glow.light_energy = 2.1
		glow.omni_range = 6.4
		glow.omni_attenuation = 1.6
		glow.position = Vector3(0.0, 1.55, 1.6)
		glow.shadow_enabled = false
		glow.add_to_group("矿灯")
		n.add_child(glow)
	elif proc.has("yaw"):
		# 树：每棵转一个角度，一片林子才不会像复制粘贴
		n.rotation.y = float(proc["yaw"])
	# 树/矿不再关阴影：整片林子"没有落地影"是场景显得像贴纸的最大元凶。
	# 140 棵树只在 95m 阴影范围内进 shadow pass，实测代价可接受（见性能自检）。
	_cast_shadow(n, true)
	n.add_to_group("可采集物")
	_harvestables.append(n)
	return n


# ===========================================================================
# 开局布阵
# ===========================================================================

## 生成**全部阵营**的开局建筑与部队（多队图：每个阵营一个基地）
func spawn_starting_forces() -> void:
	var cfg: GameConfig = Cfg.game
	var list: Array = Game.factions
	if list.is_empty():
		list = [Game.player_faction, Game.enemy_faction]
	for f in list:
		_spawn_faction_start(cfg, f)


## 阵营开局建筑表：玩家/盟友用玩家布局，敌人用敌方布局（数值在 Cfg 里）。
func _start_layout(faction: RtsFaction) -> Dictionary:
	var cfg: GameConfig = Cfg.game
	var own: bool = faction != null and Game.is_ally_of_player(faction)
	return {
		"buildings": cfg.player_buildings if own else cfg.enemy_buildings,
		"units": cfg.player_units if own else cfg.enemy_units,
	}


## 该基地的"正面"朝向（单位/建筑统一朝地图中心，且**只取 90° 整数倍**）：
## 占地是 1m 网格上的矩形，斜着摆会让 mark_footprint 的格子矩形和视觉对不上。
func _base_forward(center2: Vector2) -> Vector2:
	var d: Vector2 = (-center2).normalized()
	if d == Vector2.ZERO:
		return Vector2(0.0, 1.0)
	if absf(d.x) >= absf(d.y):
		return Vector2(signf(d.x), 0.0)
	return Vector2(0.0, signf(d.y))


## 生成一个阵营的开局
func _spawn_faction_start(cfg: GameConfig, faction: RtsFaction) -> void:
	if faction == null:
		return
	var center2: Vector2 = _base_pos.get(faction.index, Vector2.ZERO)
	var center3 := snap_to_ground(Vector3(center2.x, 0.0, center2.y))
	var layout: Dictionary = _start_layout(faction)
	var buildings: Dictionary = layout["buildings"]
	var units: Dictionary = layout["units"]
	var forward2: Vector2 = _base_forward(center2)
	# ★ 建筑朝向**全图统一**：不再按"朝中心"算。
	#   以前按 forward2 求出 yaw，四家基地各朝一个方向（±90°/±135°），俯视就是"歪的"。
	#   现在统一读 建筑网格.DEFAULT_YAW，和农民建造、地图生成、编辑器放置完全一致。
	#   注意：**位置布局**仍按 forward2 展开（营地还是朝中心摆），只有朝向被钉死。
	var yaw: float = 建筑网格.snap_yaw(建筑网格.default_yaw())
	# 局部坐标基：X = 右（forward 右手边），Z = 前
	var right2 := Vector2(-forward2.y, forward2.x)

	# --- 建筑 ---
	for id in buildings.keys():
		var off: Vector2 = buildings[id]
		# 偏移按"营地本地坐标系"解释：x 是右手边，y 是朝中心的方向
		var world_off: Vector2 = right2 * off.x + forward2 * off.y
		var pos := snap_to_ground(Vector3(center2.x + world_off.x, 0.0, center2.y + world_off.y))
		# ★ 建筑落点唯一入口：建筑网格（和寻路共用 1m 格）。
		#   偶数足迹吸格线、奇数足迹吸格心，保证占地 = 整数个寻路格。
		var bd: UnitDef = Cfg.unit(id)
		var fp: Vector2i = bd.footprint if bd != null else Vector2i(4, 4)
		pos = 建筑网格.snap_point(pos, fp)
		var b: Node3D = Game.spawn_unit(faction, id, pos, self)
		if b != null:
			b.rotation = Vector3(0.0, 建筑网格.snap_yaw(yaw), 0.0)
			mark_footprint(b)
			_add_banners(b, faction)
			if b.has_method("set_constructed"):
				b.call("set_constructed", true)

	# --- 单位（围基地一圈站，左右都进画面） ---
	var spawn_center := center3 + Vector3(forward2.x, 0.0, forward2.y) * 1.0
	var idx: int = 0
	var total: int = 0
	for id in units.keys():
		total += int(units[id])
	for id in units.keys():
		var count: int = int(units[id])
		for i in range(count):
			var ang: float = TAU * float(idx) / float(maxi(1, total)) + 0.15
			var rad: float = maxf(cfg.rally_spread, 10.0) + 1.6 * float(idx % 2)
			var p := Vector3(
				spawn_center.x + cos(ang) * rad,
				0.0,
				spawn_center.z + sin(ang) * rad
			)
			p = walkable_pos(p)
			var u: Node3D = Game.spawn_unit(faction, id, p, self)
			if u != null:
				var to_c := center3 - p
				if to_c.length_squared() > 1.0:
					# 面朝地图中心（出生点都在角上，中心就是主战场方向）
					to_c = -Vector3(p.x, 0.0, p.z)
					if to_c.length_squared() > 0.01:
						u.rotation.y = atan2(-to_c.x, -to_c.z)
			idx += 1


## 兼容旧调用：建筑落点现在统一走 建筑网格.snap_point（见 代码/单位/建筑网格.gd）。
## 保留这个薄壳只为外部脚本/旧测试还能调；逻辑不在这里复制第二份。
func snap_grid(p: Vector3, footprint: Vector2i = Vector2i(2, 2)) -> Vector3:
	return 建筑网格.snap_point(p, footprint)


## 递归开关阴影投射（树/矿默认开；需要降负载时再关）
func _cast_shadow(root: Node, on: bool) -> void:
	if root == null:
		return
	var mi := root as MeshInstance3D
	if mi != null:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in root.get_children():
		_cast_shadow(c, on)




## 对外：给建筑加旗杆 + 旗面（阵营色）。
## MapLoader 摆开局建筑时也走这里，保证"cfg 布阵"和"地图文件布阵"看起来一样。
func add_banners(b: Node3D, faction: RtsFaction) -> void:
	_add_banners(b, faction)


## 给建筑加旗杆 + 旗面（阵营色）。
##
## ★ 2026-10-31 停用（只留函数壳，MapLoader 还在调）：
##   这里以前是给**旧版箭塔**补旗子的补丁（判 `d.id == &"tower"`），
##   而现在的箭塔是铁誓军团资产 —— 模型本身**没有旗**，顶上只有一根旗尖。
##   补丁按 `height*0.92 + half_x*0.62` 定位，那面旗实际落在屋顶斜面之外，
##   玩家看到的就是"箭塔旁边飘着一块布"（悬空/穿模）。
##   旗子现在由资产包自己负责（team / team_trim 材质），代码不再补第二面。
func _add_banners(b: Node3D, faction: RtsFaction) -> void:
	return

## 岩石：默认走**程序化岩石**（8 个变体共享网格，每块一个 MeshInstance3D）。
## 把 PROC_ROCK 关掉就回到"拆 岩石.glb 的子网格做 MultiMesh"的老路。
##
## 为什么这里**不用 MultiMesh**（虽然岩石是纯装饰、天生适合合批）：
##   MultiMesh 的实例色会覆盖/乘进顶点色，实测程序化岩石在合批下整块变黑（只剩影子）。
##   岩石只有 ~40 块，40 次 draw call 换"顶点色正常、颜色正确"是划算的；
##   真要合批，得改成用实例色承担颜色（放弃顶点 AO），那是另一套取舍，先不做。
##
## 2026-10-31：外观参数（变体 / 三轴缩放 / 倾斜 / 下沉）**全部来自生成期**
## （见 地图生成._place_rocks）。老地图/老存档里没有这些字段时，这里按索引
## 兜底推一个稳定值，保证"换个地图也不会突然全是同一块石头"。
const PROC_ROCK := true

func _build_rock_multimesh(rocks: Array) -> void:
	if rocks.is_empty():
		return
	if PROC_ROCK and _build_rocks_proc(rocks):
		return
	_build_rock_multimesh_glb(rocks)


func _build_rocks_proc(rocks: Array) -> bool:
	var nb: int = ProcProp.variants(ProcProp.KIND_ROCK)
	if nb <= 0:
		return false
	var mat: Material = ProcProp.rock_material()
	var meshes: Array[ArrayMesh] = []
	for i in nb:
		var pm: ArrayMesh = ProcProp.mesh(ProcProp.KIND_ROCK, i)
		if pm == null or pm.get_surface_count() == 0:
			return false
		meshes.append(pm)
	for i in rocks.size():
		var r: Dictionary = rocks[i]
		var p2: Vector2 = r["pos"]
		var pos := snap_to_ground(Vector3(p2.x, 0.0, p2.y))
		var sc: float = float(r.get("scale", 1.0))
		var aniso: Vector3 = r.get("aniso", Vector3.ONE)
		var tilt: Vector2 = r.get("tilt", Vector2.ZERO)
		var sink: float = float(r.get("sink", sc * 0.14))
		var variant: int = int(r.get("variant", i % nb))
		var mi := MeshInstance3D.new()
		mi.name = "岩石%d" % i
		mi.mesh = meshes[((variant % nb) + nb) % nb]
		mi.material_override = mat
		# 先倾斜再转朝向，最后按三轴缩放（顺序错了会变成"整体歪掉"）
		var basis := Basis(Vector3.UP, float(r.get("rot", 0.0)))
		if tilt != Vector2.ZERO:
			basis = basis * Basis(Vector3.RIGHT, tilt.x) * Basis(Vector3.FORWARD, tilt.y)
		basis = basis.scaled(Vector3(sc * aniso.x, sc * aniso.y, sc * aniso.z))
		mi.transform = Transform3D(basis, pos + Vector3(0.0, -sink, 0.0))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_props_root.add_child(mi)
	return true


## 老路：把 岩石.glb 按子网格拆成若干 MultiMesh
func _build_rock_multimesh_glb(rocks: Array) -> void:
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
		# 合批不读 MeshInstance 的 surface override：材质得显式搬过去，
		# 否则树已经绿了、石头还灰着（两块皮，一眼出戏）。
		自然材质库.套合批(mmi, src)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
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


## 基地石板庭院：不透明感由顶点色 + cobble 细节贴图给出，外缘 alpha 渐隐进草地。
## 半径 17m，正好压住 18m 的 base flat zone；不写 walkable，不影响寻路。
func _build_base_courtyard(center2: Vector2) -> void:
	if terrain == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg: int = 72
	var r_out: float = 17.0
	var r_mid: float = 13.8
	for i in range(seg):
		var a0: float = TAU * float(i) / float(seg)
		var a1: float = TAU * float(i + 1) / float(seg)
		var p0: Vector2 = center2 + Vector2(cos(a0), sin(a0)) * r_mid
		var p1: Vector2 = center2 + Vector2(cos(a1), sin(a1)) * r_mid
		# 外缘做 3/7 次谐波的轻微起伏，避免"圆规画的聚光灯"
		var ro0: float = r_out * (0.965 + 0.028 * sin(a0 * 3.0 + center2.y * 0.07) + 0.012 * sin(a0 * 7.0))
		var ro1: float = r_out * (0.965 + 0.028 * sin(a1 * 3.0 + center2.y * 0.07) + 0.012 * sin(a1 * 7.0))
		var q0: Vector2 = center2 + Vector2(cos(a0), sin(a0)) * ro0
		var q1: Vector2 = center2 + Vector2(cos(a1), sin(a1)) * ro1
		var v0 := Vector3(p0.x, height_at(p0.x, p0.y) + 0.05, p0.y)
		var v1 := Vector3(p1.x, height_at(p1.x, p1.y) + 0.05, p1.y)
		var w0 := Vector3(q0.x, height_at(q0.x, q0.y) + 0.04, q0.y)
		var w1 := Vector3(q1.x, height_at(q1.x, q1.y) + 0.04, q1.y)
		_tri_ground(st, v0, v1, w1, Color(0.285, 0.265, 0.225, 0.97), Color(0.285, 0.265, 0.225, 0.97), Color(0.15, 0.14, 0.115, 0.0))
		_tri_ground(st, v0, w1, w0, Color(0.285, 0.265, 0.225, 0.97), Color(0.15, 0.14, 0.115, 0.0), Color(0.15, 0.14, 0.115, 0.0))
	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "基地石板场"
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.92
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.albedo_texture = load("res://美术/贴图/cobble_albedo.png") if ResourceLoader.exists("res://美术/贴图/cobble_albedo.png") else null
	if ResourceLoader.exists("res://美术/贴图/cobble_normal.png"):
		mat.normal_enabled = true
		mat.normal_texture = load("res://美术/贴图/cobble_normal.png")
		mat.normal_scale = 0.8
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)
	_build_courtyard_curb(center2, 16.55)


## 庭院外圈石缘：一圈 0.14m 高的深色压边石，把"亮圆盘"读成"砌出来的场"。
## 不透明、投影关闭；只做顶面 + 内外侧面，72 段。
func _build_courtyard_curb(center2: Vector2, radius: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg: int = 72
	var w: float = 0.34
	for i in range(seg):
		var a0: float = TAU * float(i) / float(seg)
		var a1: float = TAU * float(i + 1) / float(seg)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		var r0i := radius + 0.20 * sin(a0 * 5.0)
		var r1i := radius + 0.20 * sin(a1 * 5.0)
		var ri0: Vector2 = center2 + d0 * (r0i - w)
		var ri1: Vector2 = center2 + d1 * (r1i - w)
		var ro0: Vector2 = center2 + d0 * r0i
		var ro1: Vector2 = center2 + d1 * r1i
		var hi0: float = height_at(ri0.x, ri0.y) + 0.16
		var hi1: float = height_at(ri1.x, ri1.y) + 0.16
		var ho0: float = height_at(ro0.x, ro0.y) + 0.14
		var ho1: float = height_at(ro1.x, ro1.y) + 0.14
		var g0: float = 0.34 + 0.06 * sin(a0 * 9.0 + center2.x)
		var g1: float = 0.34 + 0.06 * sin(a1 * 9.0 + center2.x)
		var c0 := Color(g0, g0 * 0.96, g0 * 0.90, 1.0)
		var c1 := Color(g1, g1 * 0.96, g1 * 0.90, 1.0)
		# 顶面
		_tri_ground(st, Vector3(ri0.x, hi0, ri0.y), Vector3(ri1.x, hi1, ri1.y), Vector3(ro1.x, ho1, ro1.y), c0, c1, c1)
		_tri_ground(st, Vector3(ri0.x, hi0, ri0.y), Vector3(ro1.x, ho1, ro1.y), Vector3(ro0.x, ho0, ro0.y), c0, c1, c0)
		# 外侧面
		var db0: float = height_at(ro0.x, ro0.y) + 0.01
		var db1: float = height_at(ro1.x, ro1.y) + 0.01
		_tri_ground(st, Vector3(ro0.x, ho0, ro0.y), Vector3(ro1.x, ho1, ro1.y), Vector3(ro1.x, db1, ro1.y), c0.darkened(0.35), c1.darkened(0.35), c1.darkened(0.5))
		_tri_ground(st, Vector3(ro0.x, ho0, ro0.y), Vector3(ro1.x, db1, ro1.y), Vector3(ro0.x, db0, ro0.y), c0.darkened(0.35), c1.darkened(0.5), c0.darkened(0.5))
	var mi := MeshInstance3D.new()
	mi.name = "庭院石缘"
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.88
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if ResourceLoader.exists("res://美术/贴图/cobble_albedo.png"):
		mat.albedo_texture = load("res://美术/贴图/cobble_albedo.png")
	if ResourceLoader.exists("res://美术/贴图/cobble_normal.png"):
		mat.normal_enabled = true
		mat.normal_texture = load("res://美术/贴图/cobble_normal.png")
		mat.normal_scale = 0.7
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)


## 庭院三角：写 UV / 顶点色 / 法线（外缘 alpha=0）
func _tri_ground(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ca: Color, cb: Color, cc: Color) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length_squared() < 0.000001:
		return
	n = n.normalized()
	if n.y < 0.0:
		n = -n
	for i in 3:
		var v: Vector3 = [a, b, c][i]
		var col: Color = [ca, cb, cc][i]
		st.set_color(col)
		st.set_normal(n)
		st.set_uv(Vector2(v.x, v.z) * 0.44)
		st.add_vertex(v)


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
	# 压到地形最低点以下：沟壑/峡谷的谷底比旧图低得多，用固定 -2.2 会把沟底盖住
	var low: float = 0.0
	if terrain != null:
		low = terrain.height_min()
	plane.position = Vector3(0.0, low - 3.0, 0.0)
	add_child(plane)