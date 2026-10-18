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

## 单格边长（米）。1 米 = 1 个角色身位，兼顾精度与速度。
const CELL: float = 1.0
## 单次寻路最多扩展多少个节点（防止极端情况卡死）
const MAX_EXPAND: int = 24000
## 启发权重：>1 会得到"更直但不最优"的路径，换来快得多的搜索。
## RTS 里这点次优完全看不出来，但卡顿一眼就能看出来，所以取 1.25。
const HEURISTIC_WEIGHT: float = 1.25
## 路径平滑时的前向观察窗口（格点数）。无界回溯会退化成 O(n²) 的视线检测。
const SMOOTH_WINDOW: int = 26

# --- 网格尺寸 ---
var _w: int = 0
var _h: int = 0
var _half: float = 0.0
## 1 = 可走，0 = 阻挡。索引 = z * _w + x
var _walk: PackedByteArray = PackedByteArray()
## 已被永久占用的格子（建筑），用于重建时复用
var _static_blocked: PackedByteArray = PackedByteArray()

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


## 把网格恢复成"只有静态阻挡"的状态（重建建筑会用到）
func reset_to_static() -> void:
	_walk = _static_blocked.duplicate()


## 标记某格是否阻挡（建筑占地 / 树木砍掉）
func mark_blocked(cell: Vector2i, blocked: bool) -> void:
	if cell.x < 0 or cell.y < 0 or cell.x >= _w or cell.y >= _h:
		return
	_walk[cell.y * _w + cell.x] = 0 if blocked else 1


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
# 视线（用于路径平滑与"能否直线过去"判定）
# ===========================================================================

## 两点之间是否畅通（按格子采样，采样步长 0.4 格，不会漏掉薄墙）
func line_of_sight(a: Vector3, b: Vector3) -> bool:
	var d := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var dist := d.length()
	if dist < 0.0001:
		return is_walkable(a)
	var dir := d / dist
	var step: float = CELL * 0.4
	var t: float = 0.0
	while t < dist:
		var p := Vector3(a.x + dir.x * t, 0.0, a.z + dir.z * t)
		if not is_walkable(p):
			return false
		t += step
	return is_walkable(b)


# ===========================================================================
# 寻路主函数
# ===========================================================================

## 返回从 from 到 to 的平滑路径点（不含起点，含终点；y 恒为 0）。
## 不可达返回空数组。终点不可走时会自动落到最近可走格。
func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var empty := PackedVector3Array()
	last_expanded = 0
	last_path_cost = 0.0
	if _w <= 0 or _h <= 0:
		return empty

	var start_c := world_to_cell(from)
	var goal_c := world_to_cell(to)

	# 起点不可走：从最近可走格出发（防止单位被挤进墙里后彻底卡死）
	if not is_cell_walkable(start_c):
		var fixed_start := nearest_walkable_cell(start_c)
		if fixed_start.x < 0:
			return empty
		start_c = fixed_start
	# 终点不可走：落到最近可走格
	if not is_cell_walkable(goal_c):
		var fixed_goal := nearest_walkable_cell(goal_c)
		if fixed_goal.x < 0:
			return empty
		goal_c = fixed_goal

	if start_c == goal_c:
		var only := cell_to_world(goal_c)
		return PackedVector3Array([only])

	var start_i: int = start_c.y * _w + start_c.x
	var goal_i: int = goal_c.y * _w + goal_c.x

	# 直线可达就直接走（最常见的移动，省掉 A*）
	if line_of_sight(from, cell_to_world(goal_c)):
		# 目标点本身可走就直接给目标点，手感更准（单位走到玩家点的地方）
		if is_walkable(to):
			return PackedVector3Array([Vector3(to.x, 0.0, to.z)])
		return PackedVector3Array([cell_to_world(goal_c)])

	# 重置工作区
	_g.fill(INF)
	_f.fill(INF)
	_from.fill(-1)
	_closed.fill(0)
	_open_mark.fill(0)
	_heap_size = 0

	_g[start_i] = 0.0
	_f[start_i] = _heuristic(start_c, goal_c) * HEURISTIC_WEIGHT
	_heap_push(start_i)

	var found: bool = false
	var expanded: int = 0
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
		for k in range(8):
			var dx: int = _DIRS[k][0]
			var dz: int = _DIRS[k][1]
			var nx: int = cx + dx
			var nz: int = cz + dz
			if nx < 0 or nz < 0 or nx >= _w or nz >= _h:
				continue
			var ni: int = nz * _w + nx
			if _closed[ni] != 0 or _walk[ni] == 0:
				continue
			# 禁止切角：斜向走时两个正交邻格都必须可走
			if dx != 0 and dz != 0:
				if _walk[cz * _w + (cx + dx)] == 0 or _walk[(cz + dz) * _w + cx] == 0:
					continue
			var step_cost: float = 1.41421356 if (dx != 0 and dz != 0) else 1.0
			var ng: float = _g[cur] + step_cost
			if ng < _g[ni]:
				_g[ni] = ng
				_from[ni] = cur
				_f[ni] = ng + _heuristic(Vector2i(nx, nz), goal_c) * HEURISTIC_WEIGHT
				_heap_push(ni)
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
		# 先在窗口内从远往近找
		var j: int = window_end
		while j > i:
			if line_of_sight(anchor, pts[j]):
				far = j
				break
			j -= 1
		anchor = pts[far]
		smoothed.append(anchor)
		i = far + 1
	if smoothed.is_empty():
		smoothed.append(pts[pts.size() - 1])
	else:
		# 终点用玩家点的真实坐标（如果那块可走），落点更符合预期
		if is_walkable(to):
			var last := smoothed[smoothed.size() - 1]
			if line_of_sight(last, Vector3(to.x, 0.0, to.z)):
				smoothed[smoothed.size() - 1] = Vector3(to.x, 0.0, to.z)
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
