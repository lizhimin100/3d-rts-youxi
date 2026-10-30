class_name GridPathfinder
extends RefCounted
## **网格 A\* 寻路**（RTS 寻路的骨架，由 Lead 实现，其他模块只调用）。
##
## 为什么不用 NavigationServer3D：
##   - 我们的地图是程序化生成的，导航网格要么在编辑器里烘焙（不可行），要么运行时烘焙（卡顿且不可控）；
##   - 网格 A\* 完全确定、可单测、能精确控制"不切角""绕建筑"等 RTS 手感细节；
##   - 12k 格子的 A\* 单次耗时 <1ms，几十个单位也不会掉帧。
##
## 坐标约定：世界 XZ 平面，地图以原点为中心、边长 size 的正方形。
##   cell(x, z) = floor((world + size/2) / CELL)
##   cell 中心世界坐标 = (cell + 0.5) * CELL - size/2
##
## 返回的路径 y 恒为 0，由调用方按地形高度补 y（见 RtsLevel.height_at）。
##
## ============ v2（2026-10-18，HOUND）：净空（clearance）============
## 老实现只保证"格心可走"，于是路径平滑可以在离墙角 0.05m 的地方切过去 ——
## 单位身体半径 0.5m，中心线能过、身体穿墙。现在新增：
##   · clearance_at(pos)     点到最近不可走格“矩形”的精确距离（米）
##   · is_standable(pos,r)   这个点能不能放下半径 r 的身体
##   · nearest_standable / standable_near  最近的可站立落点（连续坐标，不吸格心）
## find_path 的平滑与终点自动带上 agent_radius（默认 0.5m = 任务书要求的净空）。
## 旧接口（line_of_sight(a,b) / is_walkable / clamp_to_walkable）行为不变。

## 单格边长（米）。1 米 = 1 个角色身位，兼顾精度与速度。
const CELL: float = 1.0
## 单次寻路最多扩展多少个节点（防止极端情况卡死）
const MAX_EXPAND: int = 24000
## 启发权重：>1 会得到"更直但不最优"的路径，换来快得多的搜索。
## RTS 里这点次优完全看不出来，但卡顿一眼就能看出来，所以取 1.25。
const HEURISTIC_WEIGHT: float = 1.25
## 路径平滑时的前向观察窗口（格点数）。无界回溯会退化成 O(n²) 的视线检测。
const SMOOTH_WINDOW: int = 26
## 净空比较容差：贴着不可走格的那一格，格心净空恰好 = 0.5m，
## 不能因为浮点误差把它判死（判死的话 1 米窄道整条不可用）。
const CLEAR_EPS: float = 0.001
## “可站立”落点的采样精度：格子内 7×7 采样 = 0.167m 网格。
## v3 由 5×5 改来：旧精度会跳过“净空刚好够”的窄带，选出的落点实际净空
## 0.49~0.55m —— 身体半径 0.5，站上去就等于贴死在墙上。
const STAND_SAMPLES: int = 7
## **落点余量**（米）：给“目标点”解析用的落点必须比身体半径再富余这么多。
## 为什么必须是正余量而不是 CLEAR_EPS：
##   · 单位站定后会被同伴分离推挤（每帧最多 0.027m），净空 0.5 的落点
##     只要被推 1mm 就掉出 is_standable，然后 wall_pushout 把它推回来，
##     两边每帧对拉 —— 这就是“贴墙原地抽搐”的结构性来源；
##   · 0.15m ≈ 3 个身位的分离死区 + 采样误差，足够吸收推挤而不碰墙。
const GOAL_MARGIN: float = 0.15
## A* 规划时要求的“3×3 机动空间”：邻域内可走格 ≥ 这个数才允许经过。
## 6 = 3×3 里只允许 3 格被挡（贴墙走道正好 6，2m 窄缝正好 6，1 格宽的缝只有 3~5）。
## 为什么是 6 而不是 8：8 会把“贴着建筑外墙走”的整条可行走带判死。
const PATH_ROOM_MIN: int = 6

## 单位身体半径（米）：find_path 的路径平滑/终点按这个净空判定。
## 0.5 = 步兵 body_radius，也是任务书 §3.1 要求的“至少 0.5m 净空”。
## 传 0 可退回旧行为（只查格心），供老测试/老调用方使用。
var agent_radius: float = 0.5

# --- 网格尺寸 ---
var _w: int = 0
var _h: int = 0
var _half: float = 0.0
## 1 = 可走，0 = 阻挡。索引 = z * _w + x
var _walk: PackedByteArray = PackedByteArray()
## 已被永久占用的格子（建筑），用于重建时复用
var _static_blocked: PackedByteArray = PackedByteArray()
## 3×3 邻域全可走的快速标记（1=周围一格内没有任何阻挡）。
## 净空查询在热点路径上（每次视线检测要采样几十个点），给它一条 O(1) 的快车道：
## 只要 3×3 全空，净空必然 ≥1.0m，直接返回下界，省掉 9 次邻格检查。
var _open3: PackedByteArray = PackedByteArray()
## 3×3 邻域里可走格的数量（0~9，含自己）。A* 用它判断“这格有没有机动空间”。
## 为什么需要：1m 格子 + 0.5m 身体，**1 格宽**的缝（崖脚石缝、台阶夹缝）
## 格心净空恰好 0.5m —— 身体刚好填满，任何 1cm 的推挤都会让它掉出净空判据，
## 于是“站得住却走不动”，卡死窗口一路刷到几百个。A* 必须优先走有空间的格子。
var _room3: PackedByteArray = PackedByteArray()
## 可站立点缓存：key = 量化坐标 + 半径 → 落点。建筑增删时清空。
## 为什么需要：目标压在建筑里时“找最近可站立点”是环形搜索，
## 追击/采集每 0.25s 都要算一次，不缓存会白烧 CPU。
var _stand_cache: Dictionary = {}

# --- A* 工作区（复用以减少分配）---
var _g: PackedFloat32Array = PackedFloat32Array()
var _f: PackedFloat32Array = PackedFloat32Array()
var _from: PackedInt32Array = PackedInt32Array()
var _closed: PackedByteArray = PackedByteArray()
var _open_mark: PackedByteArray = PackedByteArray()
var _heap: PackedInt32Array = PackedInt32Array()
var _heap_size: int = 0

# 统计（测试与调试用）
var last_expanded: int = 0
var last_path_cost: float = 0.0


# ===========================================================================
# 构建
# ===========================================================================

## 用"可走性数组"构建网格。
## walkable: 长度必须是 (size/CELL)^2，索引 z * w + x，1=可走。
func build(size: float, walkable: PackedByteArray) -> void:
	var n: int = int(round(size / CELL))
	n = maxi(n, 8)
	_w = n
	_h = n
	_half = size * 0.5
	_static_blocked = walkable.duplicate()
	_walk = walkable.duplicate()
	if _walk.size() != n * n:
		push_error("[寻路] 可走性数组长度 %d 与网格 %dx%d 不匹配" % [_walk.size(), n, n])
		_walk.resize(n * n)
		_walk.fill(1)
		_static_blocked = _walk.duplicate()
	# 预分配工作区
	_g.resize(n * n)
	_f.resize(n * n)
	_from.resize(n * n)
	_closed.resize(n * n)
	_open_mark.resize(n * n)
	_heap.resize(n * n)
	_heap_size = 0
	_stand_cache.clear()
	_rebuild_open3()


## 把网格恢复成"只有静态阻挡"的状态（重建建筑会用到）
func reset_to_static() -> void:
	_walk = _static_blocked.duplicate()
	_stand_cache.clear()
	_rebuild_open3()


## 标记某格是否阻挡（建筑占地 / 树木砍掉）
func mark_blocked(cell: Vector2i, blocked: bool) -> void:
	if cell.x < 0 or cell.y < 0 or cell.x >= _w or cell.y >= _h:
		return
	if _walk[cell.y * _w + cell.x] == (0 if blocked else 1):
		return
	_walk[cell.y * _w + cell.x] = 0 if blocked else 1
	_stand_cache.clear()
	_refresh_open3(cell.x, cell.y)
	_refresh_room3(cell.x, cell.y)


## 标记一个矩形区域（建筑占地，按格）
func mark_blocked_rect(center_cell: Vector2i, size_cells: Vector2i, blocked: bool) -> void:
	var x0: int = center_cell.x - size_cells.x / 2
	var z0: int = center_cell.y - size_cells.y / 2
	for z in range(z0, z0 + size_cells.y):
		for x in range(x0, x0 + size_cells.x):
			mark_blocked(Vector2i(x, z), blocked)


# ===========================================================================
# 坐标换算
# ===========================================================================

## 世界坐标 → 格子（可能是界外，调用方需自己判断）
func world_to_cell(pos: Vector3) -> Vector2i:
	return Vector2i(
		floori((pos.x + _half) / CELL),
		floori((pos.z + _half) / CELL)
	)


## 格子 → 世界坐标（格子中心，y = 0）
func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(
		(float(cell.x) + 0.5) * CELL - _half,
		0.0,
		(float(cell.y) + 0.5) * CELL - _half
	)


## 网格长宽（格数）
func grid_size() -> Vector2i:
	return Vector2i(_w, _h)


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < _w and cell.y < _h


## 某格是否可走
func is_cell_walkable(cell: Vector2i) -> bool:
	if not in_bounds(cell):
		return false
	return _walk[cell.y * _w + cell.x] != 0


## 世界坐标是否可走
func is_walkable(pos: Vector3) -> bool:
	return is_cell_walkable(world_to_cell(pos))


## 找离该格最近的可走格（螺旋外扩）。找不到返回 (-1,-1)
func nearest_walkable_cell(cell: Vector2i) -> Vector2i:
	if is_cell_walkable(cell):
		return cell
	for r in range(1, 24):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				# 只查外圈
				if absi(dx) != r and absi(dz) != r:
					continue
				var c := Vector2i(cell.x + dx, cell.y + dz)
				if is_cell_walkable(c):
					return c
	return Vector2i(-1, -1)


## 把世界坐标夹到最近可走位置（不改变高度）
func clamp_to_walkable(pos: Vector3) -> Vector3:
	var c := nearest_walkable_cell(world_to_cell(pos))
	if c.x < 0:
		return pos
	var w := cell_to_world(c)
	return Vector3(w.x, pos.y, w.z)


# ===========================================================================
# 净空（身体半径）—— 2026-10-18 HOUND 新增
# ===========================================================================

## 点到「最近不可走格矩形」的距离（米）。0 = 已经踩在阻挡格里；≥0.5 才能放下半径 0.5 的身体。
##
## 为什么不是"到格心的距离"：格子是 1m 方块，格心到格心的距离会把墙角算远
## （格心 1.0m，实际离墙角只有 0.707m，贴着墙角切过去时身体早就穿进去了）。
## 这里按**矩形**算（点到 AABB 的欧氏距离），墙角/贴边都精确。
## 只扫 3×3 邻域：1m 格子下，再远的格子距离必然 ≥1m，对"贴不贴墙"没有意义。
func clearance_at(pos: Vector3) -> float:
	return clearance_at_xy(pos.x, pos.z)


## 重建 3×3 全空标记（build / 大改网格时一次）
func _rebuild_open3() -> void:
	_open3.resize(_w * _h)
	_room3.resize(_w * _h)
	for z in range(_h):
		for x in range(_w):
			_open3[z * _w + x] = 1 if _neighborhood_open(x, z) else 0
			_room3[z * _w + x] = _room_at(x, z)


## 3×3 邻域内可走格数量（界外算阻挡）
func _room_at(x: int, z: int) -> int:
	var n: int = 0
	for dz in range(-1, 2):
		var gz: int = z + dz
		if gz < 0 or gz >= _h:
			continue
		for dx in range(-1, 2):
			var gx: int = x + dx
			if gx < 0 or gx >= _w:
				continue
			if _walk[gz * _w + gx] != 0:
				n += 1
	return n


## 某个格子(含自己+8邻)是否全可走
func _neighborhood_open(x: int, z: int) -> bool:
	for dz in range(-1, 2):
		var gz: int = z + dz
		if gz < 0 or gz >= _h:
			return false
		for dx in range(-1, 2):
			var gx: int = x + dx
			if gx < 0 or gx >= _w:
				return false
			if _walk[gz * _w + gx] == 0:
				return false
	return true


## 只刷新 (cx,cz) 周围 3×3 个格子的标记（其中每个的 3×3 邻域都包含被改的格子）
func _refresh_open3(cx: int, cz: int) -> void:
	for z in range(cz - 1, cz + 2):
		if z < 0 or z >= _h:
			continue
		for x in range(cx - 1, cx + 2):
			if x < 0 or x >= _w:
				continue
			_open3[z * _w + x] = 1 if _neighborhood_open(x, z) else 0


## 同上，刷新机动空间计数
func _refresh_room3(cx: int, cz: int) -> void:
	for z in range(cz - 1, cz + 2):
		if z < 0 or z >= _h:
			continue
		for x in range(cx - 1, cx + 2):
			if x < 0 or x >= _w:
				continue
			_room3[z * _w + x] = _room_at(x, z)


## 同 clearance_at，但直接吃 xz（避免每帧构造 Vector3）
func clearance_at_xy(x: float, z: float) -> float:
	if _w <= 0:
		return 99.0
	var cx: int = floori((x + _half) / CELL)
	var cz: int = floori((z + _half) / CELL)
	# 快车道：3×3 全空 → 到最近阻挡格的距离必然 ≥1.0（格心距 2.0 - 半格 1.0）
	if cx >= 0 and cz >= 0 and cx < _w and cz < _h and _open3[cz * _w + cx] != 0:
		return 1.0
	var best: float = 99.0
	for dz in range(-1, 2):
		var gz: int = cz + dz
		var row_ok: bool = gz >= 0 and gz < _h
		for dx in range(-1, 2):
			var gx: int = cx + dx
			if row_ok and gx >= 0 and gx < _w and _walk[gz * _w + gx] != 0:
				continue
			# 这一格是阻挡（界外也算阻挡：地图边缘不许走出去）
			var ccx: float = (float(gx) + 0.5) * CELL - _half
			var ccz: float = (float(gz) + 0.5) * CELL - _half
			var ex: float = maxf(absf(x - ccx) - CELL * 0.5, 0.0)
			var ez: float = maxf(absf(z - ccz) - CELL * 0.5, 0.0)
			var d: float = sqrt(ex * ex + ez * ez)
			if d < best:
				best = d
				if best <= 0.0:
					return 0.0
	return best


## 这个点能不能放下半径 radius 的身体（默认用 agent_radius）。
## 判据 = 净空 ≥ 半径 - CLEAR_EPS，且不在阻挡格里（净空 0 自然不满足）。
func is_standable(pos: Vector3, radius: float = -1.0) -> bool:
	return _los_ok(pos, agent_radius if radius < 0.0 else radius)


## 离 pos 最近的“可站立点”。返回**连续坐标**（0.167m 采样网格），不是格心 ——
## 单位不会再为了对齐格心先横移半格，落点也更贴近玩家点的位置。
## margin > 0 时要求净空 ≥ radius + margin（落点必须留出被同伴推挤的余量）。
func nearest_standable(pos: Vector3, radius: float = -1.0, margin: float = 0.0) -> Vector3:
	return standable_near(pos, pos, radius, margin)


## 在 target 周围找可站立点，评分 = |p-target| + 0.3 × |p-origin|。
##
## · nearest_standable(t) = standable_near(t, t)：离目标最近（唯一、稳定）；
## · 单位解析“点到建筑上”的目标时 origin = 单位当前位置 →
##   不同来向的单位会落到建筑的不同侧（确定性分散，不会全抢同一格）；
## · 纯函数：同样的输入永远同样的输出（目标点固定后不会逐帧跳）。
##
## ★ v3 的“找不到就降标准”兜底：老实现 best_score == INF 时直接返回 target 本身，
##   而 target 往往就压在建筑里 —— 调用方（逐帧推出）会拿这个点当推出目标，
##   推出距离恒为 0 → 1.2s 后触发兜底吸附（瞬移）。现在逐级放宽到
##   “最近可走格心”，保证返回值永远真的能站人。
func standable_near(target: Vector3, origin: Vector3, radius: float = -1.0, margin: float = 0.0) -> Vector3:
	var r: float = (agent_radius if radius < 0.0 else radius) + maxf(margin, 0.0)
	var tp := Vector3(target.x, 0.0, target.z)
	var op := Vector3(origin.x, 0.0, origin.z)
	if _los_ok(tp, r):
		return tp
	var best: Vector3 = _search_standable(tp, op, r)
	if best.x != INF:
		return best
	# 降级 1：放宽余量（先放弃 margin，再放弃到 90% 身体半径）
	for k in range(3):
		var rr: float = r * (0.85 if k == 0 else (0.75 if k == 1 else 0.62))
		best = _search_standable(tp, op, rr)
		if best.x != INF:
			return best
	# 降级 2：最近可走格心（可走格心到阻挡格必然 ≥0.5m，一定站得住）
	var c: Vector2i = nearest_walkable_cell(world_to_cell(tp))
	if c.x >= 0:
		var w := cell_to_world(c)
		return Vector3(w.x, 0.0, w.z)
	return tp


## standable_near 的实际环形搜索。找不到返回 (INF,0,INF)。
func _search_standable(tp: Vector3, op: Vector3, r: float) -> Vector3:
	var c0: Vector2i = world_to_cell(tp)
	var best := Vector3(INF, 0.0, INF)
	var best_score: float = INF
	var step: float = CELL / float(STAND_SAMPLES - 1)
	# 环数上限 20 → 周围 20m；建筑最大 8m，够绕到任意一侧
	for ring in range(0, 21):
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if absi(dx) != ring and absi(dz) != ring:
					continue
				var c := Vector2i(c0.x + dx, c0.y + dz)
				if not in_bounds(c):
					continue
				# 快速剪枝：格子中心的净空已经比 r-半对角线 还差 → 这格里不可能有可站立点
				var cc: Vector3 = cell_to_world(c)
				if clearance_at(cc) + 0.7072 < r:
					continue
				for sz in range(STAND_SAMPLES):
					var z2: float = cc.z - CELL * 0.5 + step * (float(sz) + 0.5)
					for sx in range(STAND_SAMPLES):
						var x2: float = cc.x - CELL * 0.5 + step * (float(sx) + 0.5)
						var cl: float = clearance_at_xy(x2, z2)
						if cl + CLEAR_EPS < r:
							continue
						var px: float = x2 - tp.x
						var pz: float = z2 - tp.z
						var qx: float = x2 - op.x
						var qz: float = z2 - op.z
						var sc: float = sqrt(px * px + pz * pz) + 0.3 * sqrt(qx * qx + qz * qz)
						if sc < best_score:
							best_score = sc
							best = Vector3(x2, 0.0, z2)
		# 找到了就再多扫一圈（同环内不同格子可能更优），然后收工
		if best_score < INF and ring >= 1:
			return best
	return best


## 把任意点解析成唯一、稳定的可站立点（带缓存）。
## find_path 的终点吸附走它：目标压在建筑/水里时，同一个目标永远得到同一个落点。
func standable_point(to: Vector3, radius: float = -1.0, margin: float = 0.0) -> Vector3:
	var r: float = agent_radius if radius < 0.0 else radius
	if _los_ok(to, r + margin):
		return Vector3(to.x, 0.0, to.z)
	var key := "%d,%d,%.2f,%.2f" % [floori(to.x * 4.0), floori(to.z * 4.0), r, margin]
	if _stand_cache.has(key):
		return _stand_cache[key]
	var out: Vector3 = nearest_standable(to, r, margin)
	if _stand_cache.size() > 512:
		_stand_cache.clear()
	_stand_cache[key] = out
	return out


# ===========================================================================
# 视线（用于路径平滑与"能否直线过去"判定）
# ===========================================================================

## 两点之间是否畅通（按格子采样，采样步长 0.35 格，不会漏掉薄墙）。
## radius > 0 时按“身体圆”判：每个采样点都要有 ≥radius 的净空 ——
## 这才是“不切墙角、不贴着崖边过去”的真判据（旧版只查格心，0.05m 就能过）。
func line_of_sight(a: Vector3, b: Vector3, radius: float = 0.0) -> bool:
	var d := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var dist := d.length()
	if dist < 0.0001:
		return _los_ok(a, radius)
	var dir := d / dist
	var step: float = CELL * 0.45
	var t: float = 0.0
	while t < dist:
		var p := Vector3(a.x + dir.x * t, 0.0, a.z + dir.z * t)
		if not _los_ok(p, radius):
			return false
		t += step
	return _los_ok(b, radius)


## 单点净空判定：radius ≤ 0 走旧的“格心可走”，radius > 0 走“身体圆”
func _los_ok(p: Vector3, radius: float) -> bool:
	if radius > 0.0:
		return clearance_at(p) + CLEAR_EPS >= radius
	return is_walkable(p)


# ===========================================================================
# 寻路主函数
# ===========================================================================

## 返回从 from 到 to 的平滑路径点（不含起点，含终点；y 恒为 0）。
## 不可达返回空数组。终点不可走时会自动落到最近可走格。
## 返回从 from 到 to 的平滑路径点（不含起点，含终点；y 恒为 0）。不可达返回空数组。
##
## radius < 0（默认）= 用 agent_radius（0.5m）。传 0 = 旧行为（只查格心）。
## 终点若压在建筑/墙里：吸附到**唯一、稳定**的可站立点（同一目标永远同一落点，
## 不再是“最近可走格中心” —— 那会让一队单位全抢同一格，然后靠 separation 互推）。
func find_path(from: Vector3, to: Vector3, radius: float = -1.0) -> PackedVector3Array:
	var empty := PackedVector3Array()
	last_expanded = 0
	last_path_cost = 0.0
	if _w <= 0 or _h <= 0:
		return empty
	var r: float = agent_radius if radius < 0.0 else radius

	# --- 终点：站不住就解析成唯一可站立点（落点带 GOAL_MARGIN 余量）---
	var goal_pos := Vector3(to.x, 0.0, to.z)
	if not _los_ok(goal_pos, r + GOAL_MARGIN):
		goal_pos = standable_point(goal_pos, r, GOAL_MARGIN)

	var start_c := world_to_cell(from)
	var goal_c := world_to_cell(goal_pos)

	# 起点不可走：从最近可走格出发（防止单位被挤进墙里后彻底卡死）
	if not is_cell_walkable(start_c):
		var fixed_start := nearest_walkable_cell(start_c)
		if fixed_start.x < 0:
			return empty
		start_c = fixed_start
	# 终点格不可走（standable_point 已保证可走，这里是防御性兜底）
	if not is_cell_walkable(goal_c):
		var fixed_goal := nearest_walkable_cell(goal_c)
		if fixed_goal.x < 0:
			return empty
		goal_c = fixed_goal
		goal_pos = cell_to_world(goal_c)

	if start_c == goal_c:
		return PackedVector3Array([goal_pos])

	var start_i: int = start_c.y * _w + start_c.x
	var goal_i: int = goal_c.y * _w + goal_c.x

	# 直线可达就直接走（最常见的移动，省掉 A*）。
	# 这里带半径判：格心连线通、但身体会蹭墙角 → 不算通，交给 A* 绕。
	if line_of_sight(from, goal_pos, r):
		return PackedVector3Array([goal_pos])

	# A*：两遍。
	#   第一遍要求每个经过的格子有 ≥PATH_ROOM_MIN 的 3×3 机动空间 ——
	#   这样不会把身体塞进 1 格宽的崖脚石缝（净空 0.47~0.5m，能“站住”但走不动）；
	#   第二遍放开这个限制，只在第一遍确实无路时兜底（保证连通性不比老版本差）。
	var found: bool = false
	var expanded: int = 0
	for attempt in range(2):
		var min_room: int = PATH_ROOM_MIN if attempt == 0 else 0
		_g.fill(INF)
		_f.fill(INF)
		_from.fill(-1)
		_closed.fill(0)
		_open_mark.fill(0)
		_heap_size = 0
		expanded = 0
		found = false

		_g[start_i] = 0.0
		_f[start_i] = _heuristic(start_c, goal_c) * HEURISTIC_WEIGHT
		_heap_push(start_i)

		while _heap_size > 0:
			var cur: int = _heap_pop()
			if _closed[cur] != 0:
				continue
			_closed[cur] = 1
			expanded += 1
			if cur == goal_i:
				found = true
				break
			if expanded > MAX_EXPAND:
				break
			var cx: int = cur % _w
			var cz: int = cur / _w
			# 热循环微优化（不改算法、不改结果）：
			#   1) 方向表拆成两个 PackedInt32Array —— 嵌套 Array 的 _DIRS[k][0]
			#      每次要两次索引 + 装箱，8 邻居 × 上万次展开很可观；
			#   2) 启发式**内联**：原来每次松弛都构造 Vector2i 再调函数，
			#      GDScript 里这一项占 A* 总时间的 25%~30%；
			#   3) for k in 8 代替 range(8)。
			var gx: int = goal_c.x
			var gz: int = goal_c.y
			for k in 8:
				var dx: int = _DX[k]
				var dz: int = _DZ[k]
				var nx: int = cx + dx
				var nz: int = cz + dz
				if nx < 0 or nz < 0 or nx >= _w or nz >= _h:
					continue
				var ni: int = nz * _w + nx
				if _closed[ni] != 0 or _walk[ni] == 0:
					continue
				if _room3[ni] < min_room:
					continue
				# 禁止切角：斜向走时两个正交邻格都必须可走
				var diag: bool = dx != 0 and dz != 0
				if diag:
					if _walk[cz * _w + (cx + dx)] == 0 or _walk[(cz + dz) * _w + cx] == 0:
						continue
				var ng: float = _g[cur] + (1.41421356 if diag else 1.0)
				if ng < _g[ni]:
					_g[ni] = ng
					_from[ni] = cur
					var hx: int = absi(nx - gx)
					var hz: int = absi(nz - gz)
					var hmin: int = mini(hx, hz)
					var h: float = float(hx + hz) + (1.41421356 - 2.0) * float(hmin)
					_f[ni] = ng + h * HEURISTIC_WEIGHT
					_heap_push(ni)
		if found or attempt == 1:
			break
	last_expanded = expanded
	if not found:
		return empty

	# 回溯
	var raw: Array[Vector2i] = []
	var walk_i: int = goal_i
	var guard: int = 0
	while walk_i != -1 and guard < 100000:
		raw.append(Vector2i(walk_i % _w, walk_i / _w))
		if walk_i == start_i:
			break
		walk_i = _from[walk_i]
		guard += 1
	raw.reverse()
	last_path_cost = _g[goal_i]

	# 字符串拉伸：能直线看到的中间点全丢掉。
	# ⚠ 曾经写成"从终点往前回扫"，在障碍密集地图上退化成 O(n²) 次视线检测，
	#   单次寻路 16ms（实测），RTS 里几十个单位一起寻路就是明显卡顿。
	#   现在改成**前向窗口**（SMOOTH_WINDOW）限界的贪心，仍保留"能跳多远跳多远"，
	#   视觉上路径一样干净，复杂度降到 O(n·W)。
	# v2：每次视线检测都带 agent_radius，所以平滑后的线段**整段都能放下身体**。
	var pts: Array[Vector3] = []
	for c in raw:
		pts.append(cell_to_world(c))
	# 用真实起点替换第一个点，避免"先横移半格"
	if not raw.is_empty():
		pts[0] = Vector3(from.x, 0.0, from.z)
	var smoothed: PackedVector3Array = PackedVector3Array()
	var anchor: Vector3 = pts[0]
	var i: int = 1
	var total: int = pts.size()
	while i < total:
		var far: int = i
		var window_end: int = mini(total - 1, i + SMOOTH_WINDOW - 1)
		if line_of_sight(anchor, pts[window_end], r):
			far = window_end
		else:
			# 二分找“最远的可见点”。线性从远往近回扫在障碍密集处要 26 次视线检测，
			# 单次寻路实测 8.85ms（40 次 354ms）；二分只要 ~5 次，
			# 路径质量几乎一样（同样是“能跳多远跳多远”）。视线不严格单调，
			# 但 A* 原始路径上相邻点本来就高度相关，二分找不到“最远”也不会给出非法跳。
			var lo: int = i
			var hi: int = window_end - 1
			var good: int = -1
			while lo <= hi:
				var mid: int = (lo + hi) / 2
				if line_of_sight(anchor, pts[mid], r):
					good = mid
					lo = mid + 1
				else:
					hi = mid - 1
			if good >= i:
				far = good
		anchor = pts[far]
		smoothed.append(anchor)
		i = far + 1
	if smoothed.is_empty():
		smoothed.append(goal_pos)
	elif line_of_sight(smoothed[smoothed.size() - 1], goal_pos, r):
		# 终点用解析后的可站立落点（比格心更贴近玩家点的位置）
		smoothed[smoothed.size() - 1] = goal_pos
	return smoothed


# ===========================================================================
# 堆（最小 f 优先）
# ===========================================================================

func _heap_push(idx: int) -> void:
	if _heap_size >= _heap.size():
		_heap.resize(_heap.size() * 2 + 16)
	var i: int = _heap_size
	_heap[i] = idx
	_heap_size += 1
	while i > 0:
		var parent: int = (i - 1) / 2
		if _f[_heap[parent]] <= _f[_heap[i]]:
			break
		var tmp: int = _heap[parent]
		_heap[parent] = _heap[i]
		_heap[i] = tmp
		i = parent


func _heap_pop() -> int:
	var top: int = _heap[0]
	_heap_size -= 1
	if _heap_size > 0:
		_heap[0] = _heap[_heap_size]
		var i: int = 0
		while true:
			var l: int = i * 2 + 1
			var r: int = l + 1
			var smallest: int = i
			if l < _heap_size and _f[_heap[l]] < _f[_heap[smallest]]:
				smallest = l
			if r < _heap_size and _f[_heap[r]] < _f[_heap[smallest]]:
				smallest = r
			if smallest == i:
				break
			var tmp: int = _heap[smallest]
			_heap[smallest] = _heap[i]
			_heap[i] = tmp
			i = smallest
	return top


## 八方向启发（octile），比欧氏更贴合 8 邻域代价，展开更少
func _heuristic(a: Vector2i, b: Vector2i) -> float:
	var dx: int = absi(a.x - b.x)
	var dz: int = absi(a.y - b.y)
	var mn: int = mini(dx, dz)
	return float(dx + dz) + (1.41421356 - 2.0) * float(mn)


const _DIRS: Array = [
	[1, 0], [-1, 0], [0, 1], [0, -1],
	[1, 1], [1, -1], [-1, 1], [-1, -1],
]

## 热循环用的扁平方向表（顺序与 _DIRS 逐项一致；改一个必须改另一个）
const _DX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const _DZ: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]