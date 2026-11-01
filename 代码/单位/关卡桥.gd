class_name RtsWorld
extends RefCounted
## **关卡访问桥**：全项目对 `Game.level` 的访问统一从这里走。
##
## 为什么要这一层：条令 §5 的关卡接口是"可能还没落地"的（Lead 边写边接），
## 如果每个单位、建筑、AI 里都写一遍 `if Game.level != null and Game.level.has_method(...)`，
## 总有漏判的地方，一漏就是满屏 ERROR。
## 把降级判断**只写一份**，任何模块都调这里 —— 关卡不在就返回"平地 + 空路径"，
## 游戏照样能跑、能测，绝不会因为地形缺失而崩。
##
## 约定：本文件**不持有任何状态**，全是静态查询。

## 单位/道具的贴地余量（米）
const GROUND_LIFT: float = 0.03
## 建筑底板的额外余量（米）
const BUILD_LIFT: float = 0.03

# ===========================================================================
# 基础取用
# ===========================================================================

## 取关卡节点（不在/无效返回 null）
static func level() -> Node3D:
	var n: Node3D = Game.level
	if n != null and is_instance_valid(n):
		return n
	return null


## 关卡是否就位
static func has_level() -> bool:
	return level() != null


## 物件离地的安全余量（米）。
## 地形高度现在已经是"看得见的那张三角面"（见 地形.height_at），
## 但脚/底座如果正好等于地形高度，两者就共面 —— 深度精度一抖就闪成一片
## （玩家看到的"金矿/建筑/单位被地形穿模"多半就是这种共面）。抬高 3cm 就够了。
## ★ 缓存的"地形求值器"（2026-11-01 性能优化）
##
## 原来每次 `height_at()` 都要：`level()`（读 Game.level）→ `has_method()` →
## `.call()`（Variant 装箱 + 动态派发）→ 地形里算双三次片。
## 而单位每帧要调 5 次（1 次贴地 + 4 次算坡度），95 个单位 × 60 帧 = 2.8 万次/秒 ——
## 实测 `_snap_ground` 吃掉 140ms/秒（占全部单位逻辑的 45%）。
## 现在把地形节点缓存下来、直接调它的方法，省掉前两步。
static var _terrain: Node3D = null
static var _terrain_owner: Node3D = null

static func _terrain_node() -> Node3D:
	var lv: Node3D = level()
	if lv == null:
		_terrain = null
		_terrain_owner = null
		return null
	# 关卡换了（重开局/换图）就重新取——只在 is_instance_valid 失效时才走这条路
	if _terrain == null or not is_instance_valid(_terrain) or _terrain_owner != lv:
		_terrain_owner = lv
		var t: Variant = lv.get("terrain")
		_terrain = t as Node3D if t is Node3D else null
	return _terrain


static func height_at(x: float, z: float) -> float:
	var t: Node3D = _terrain_node()
	if t != null:
		return float(t.height_at(x, z)) + GROUND_LIFT
	return GROUND_LIFT


## 把世界坐标贴到地面（优先用关卡的 snap_to_ground，保证和地形算法完全一致）。
## **建筑/道具专用**：比单位再高 BUILD_LIFT，因为建筑底面是一块大平板，
## 和地形贴得越严越容易闪；抬高 3cm 在 30m 机位下看不出来。
static func ground(pos: Vector3) -> Vector3:
	var lv: Node3D = level()
	if lv != null and lv.has_method("snap_to_ground"):
		var out: Variant = lv.call("snap_to_ground", pos)
		if out is Vector3:
			var v: Vector3 = out
			return Vector3(v.x, v.y + BUILD_LIFT, v.z)
	return Vector3(pos.x, height_at(pos.x, pos.z) + BUILD_LIFT, pos.z)


## 只贴 y（最常用；比 ground 少一次 Variant 转换）
static func snap_y(pos: Vector3) -> Vector3:
	return Vector3(pos.x, height_at(pos.x, pos.z), pos.z)


# ===========================================================================
# 寻路
# ===========================================================================

## 取寻路器（没有返回 null）
static func pathfinder() -> GridPathfinder:
	var lv: Node3D = level()
	if lv != null and lv.has_method("grid_pathfinder"):
		return lv.call("grid_pathfinder") as GridPathfinder
	return null


## 取一条路径（**已带地形高度**）。不可达返回空数组。
## 性能计数（`--perf-long` 的探针读它）：这一局一共算了几次路、花了多少微秒。
## 为什么放在这里：`find_path` 是**全项目唯一的寻路入口**，A* 的开销只有在这里量得准。
static var dbg_path_calls: int = 0
static var dbg_path_usec: int = 0

## **每帧最多算几条路** —— 帧时间平滑的关键。
##
## 为什么要有预算（2026-11-01 性能排查的实测结论）：
##   A* 单次 0.4~2.3ms（160×160 图 + 贴地加密）。十几个农民/野怪如果在**同一帧**
##   各自要一次路，这一帧就凭空多花 10~25ms —— 玩家感受到的就是
##   "平时 40fps，打着打着突然卡一下"。perf 长跑里 `path_ms_per_s` 峰值 224ms
##   而平均只有 40ms，说的就是这种突发。
##   给每帧一个预算，超出的顺延到下一帧：单位最多多等 1~2 帧（≈33ms），
##   肉眼完全看不出来，但最坏帧时间被削平了。
const PATH_BUDGET_PER_FRAME: int = 6
static var _budget_frame: int = -1
static var _budget_left: int = 0


## 本帧还能不能算一条路。返回 false 表示"预算用完，下一帧再来"。
static func take_path_budget() -> bool:
	var f: int = Engine.get_process_frames()
	if f != _budget_frame:
		_budget_frame = f
		_budget_left = PATH_BUDGET_PER_FRAME
	if _budget_left <= 0:
		return false
	_budget_left -= 1
	return true


static func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var t0: int = Time.get_ticks_usec()
	dbg_path_calls += 1
	var r: PackedVector3Array = _find_path_impl(from, to)
	dbg_path_usec += Time.get_ticks_usec() - t0
	return r


static func _find_path_impl(from: Vector3, to: Vector3) -> PackedVector3Array:
	var lv: Node3D = level()
	if lv != null and lv.has_method("find_path"):
		var out: Variant = lv.call("find_path", from, to)
		if out is PackedVector3Array:
			return out
		return PackedVector3Array()
	var pf: GridPathfinder = pathfinder()
	if pf != null:
		# 兜底：自己按地形补 y
		var raw: PackedVector3Array = pf.find_path(from, to)
		var fixed := PackedVector3Array()
		for p in raw:
			fixed.append(snap_y(p))
		return fixed
	return PackedVector3Array()


## 某世界坐标是否可走（没有寻路器时认为处处可走，保证能测）
static func is_walkable(pos: Vector3) -> bool:
	var pf: GridPathfinder = pathfinder()
	if pf == null:
		return true
	return pf.is_walkable(pos)


## 把坐标夹到最近可站立点
static func walkable_pos(pos: Vector3) -> Vector3:
	var lv: Node3D = level()
	if lv != null and lv.has_method("walkable_pos"):
		var out: Variant = lv.call("walkable_pos", pos)
		if out is Vector3:
			return out
	var pf: GridPathfinder = pathfinder()
	if pf != null:
		return snap_y(pf.clamp_to_walkable(pos))
	return snap_y(pos)


# ===========================================================================
# 阵营位置
# ===========================================================================

## 阵营基地中心（关卡优先；没有关卡就退到该阵营大本营，再退到 Cfg 配置坐标）
static func base_center(faction: RtsFaction) -> Vector3:
	var lv: Node3D = level()
	if lv != null and lv.has_method("base_center"):
		var out: Variant = lv.call("base_center", faction)
		if out is Vector3:
			return out
	# 依次退：大本营实体 → 任一建筑 → Cfg 里的基地坐标
	if faction != null:
		for b in faction.buildings:
			if b == null or not is_instance_valid(b):
				continue
			if b.def != null and b.def.is_dropoff:
				return b.global_position
		for b in faction.buildings:
			if b != null and is_instance_valid(b):
				return b.global_position
	# 多队图没有"玩家/敌人各一个固定坐标"这回事：退回玩家基地坐标即可（只影响首帧）。
	var p2: Vector2 = Cfg.game.player_base_pos
	return Vector3(p2.x, height_at(p2.x, p2.y), p2.y)


## 资源交汇点列表（大本营）
static func dropoffs(faction: RtsFaction) -> Array:
	var lv: Node3D = level()
	if lv != null and lv.has_method("dropoff_points"):
		var out: Variant = lv.call("dropoff_points", faction)
		if out is Array:
			return out
	# 兜底：自己扫该阵营建筑
	var res: Array = []
	if faction == null:
		return res
	for b in faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if b.def != null and b.def.is_dropoff and b.is_alive():
			res.append(b)
	if res.is_empty():
		for b in faction.buildings:
			if b != null and is_instance_valid(b) and b.is_alive():
				res.append(b)
	return res


# ===========================================================================
# 建筑占地
# ===========================================================================

## 该位置 + 占地是否允许建造
static func is_buildable(pos: Vector3, footprint: Vector2i) -> bool:
	var lv: Node3D = level()
	if lv != null and lv.has_method("is_buildable"):
		return bool(lv.call("is_buildable", pos, footprint))
	var pf: GridPathfinder = pathfinder()
	if pf == null:
		return true
	var center: Vector2i = pf.world_to_cell(pos)
	var half_x: int = footprint.x / 2
	var half_z: int = footprint.y / 2
	for dz in range(-half_z, half_z + footprint.y % 2):
		for dx in range(-half_x, half_x + footprint.x % 2):
			if not pf.is_cell_walkable(Vector2i(center.x + dx, center.y + dz)):
				return false
	return true


## 把建筑占地写进寻路网格
static func mark_footprint(building: Node3D) -> void:
	var lv: Node3D = level()
	if lv != null and lv.has_method("mark_footprint"):
		lv.call("mark_footprint", building)
		return
	# 兜底：直接操作寻路器
	var pf: GridPathfinder = pathfinder()
	if pf == null or building == null:
		return
	var d: UnitDef = building.def
	if d == null or d.footprint == Vector2i.ZERO:
		return
	pf.mark_blocked_rect(pf.world_to_cell(building.global_position), d.footprint, true)


## 清除建筑占地（**建筑被拆时必须调**，否则那块地永远走不进去）
static func clear_footprint(building: Node3D) -> void:
	var lv: Node3D = level()
	if lv != null and lv.has_method("clear_footprint"):
		lv.call("clear_footprint", building)
		return
	var pf: GridPathfinder = pathfinder()
	if pf == null or building == null:
		return
	var d: UnitDef = building.def
	if d == null:
		return
	pf.mark_blocked_rect(pf.world_to_cell(building.global_position), d.footprint, false)


## 最近的可采集物（走 Game 的资源注册表，不遍历场景）
static func nearest_harvestable(from: Vector3, kind: int, origin: Vector3, max_dist: float) -> Node3D:
	return Game.find_nearest_harvestable(from, kind, origin, max_dist)


# ===========================================================================
# 单位分类（全项目统一判据）
# ===========================================================================

## 是否"农民 / 工兵"（能采集、能建造的那种）。
##
## ⚠ 为什么不用 `UnitDef.is_worker()`：
##   `UnitDef.gather_rate` 的**默认值是 3.0**（不是 0），所以任何没有显式把
##   gather_rate 归零的战斗单位（步兵/弓手/法师）都会被 `is_worker()` 误判成农民。
##   后果极其难查：全兵种都会"挨打往基地跑"、AI 的军队统计永远为 0。
##
## 这里改用 `anim_set`（条令 §3.1 为工兵专门保留的枚举）作判据：
##   只有农民是 AnimSet.WORKER，战斗单位分别是 MELEE / ARCHER / MAGE。
static func is_worker_def(d: UnitDef) -> bool:
	if d == null:
		return false
	if d.kind != RtsConst.Kind.UNIT:
		return false
	return d.anim_set == RtsConst.AnimSet.WORKER


# ===========================================================================
# 玩家镜头（震屏的"感知半径"判定要用）
# ===========================================================================

## 取当前渲染相机（无头模式/无相机返回 null）
static func camera() -> Camera3D:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var vp: Viewport = tree.root.get_viewport()
	if vp == null:
		return null
	return vp.get_camera_3d()
