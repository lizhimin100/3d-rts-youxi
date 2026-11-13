extends RefCounted
## **人群流场** —— 2m 格、桶队列 Dijkstra、方向场平滑、双线性采样。
##
## 为什么是 2m 格而不是 1m：1m 是 65536 格，一次铺满约 25–50ms；
## 2m 是 16384 格，一次 5–10ms，而人群层的单位半径 0.25–0.5m，
## 2m 的方向误差被后面的"看路 + 推挤"吃掉了，肉眼看不出差别。
## 单个目标 ≥30 人时流场才回本（一条 A* ≈ 1ms）；这一层就是为"军团同目标"准备的。
##
## 三件必须做的事（少一件都会走成 45° 折线）：
##   1. **桶队列 Dijkstra**：代价量化成 0.1m 整数（直 10 / 斜 14），O(1) 出队；
##   2. **方向场 3×3 平滑**：原始梯度只有 8 个方向，平滑后接近连续；
##   3. **双线性采样**：单位不在格心，采样四次插值，否则会有 2m 的台阶感。

const C := preload("res://代码/人群/人群常量.gd")

## 流场格边长（米）—— 2 的幂
const FCELL: float = 2.0
const FN: int = 128
const FMASK: int = 127
const FTOTAL: int = 16384
## 桶队列：代价单位 0.1m，桶宽 16（=1.6m），256 个桶覆盖 409m
const BUCKET_W: int = 16
const NBUCKET: int = 256
const INF_I: int = 1 << 28

## 2m 格可走性（1=可走）。由 1m 的 walk 表 4 合 1 汇总。
var walk: PackedByteArray = PackedByteArray()
## 到目标的实际距离（米）；INF = 不可达
var dist: PackedFloat32Array = PackedFloat32Array()
## 平滑后的方向场（单位向量）
var fx: PackedFloat32Array = PackedFloat32Array()
var fz: PackedFloat32Array = PackedFloat32Array()

var target_cell: int = -1
var valid: bool = false
## 诊断：本次铺设的格数 / 耗时（毫秒）
var filled: int = 0
var build_ms: float = 0.0

var _di: PackedInt32Array = PackedInt32Array()
## 桶队列用 `Array[Array]`：
## · 不能用 `Array[PackedInt32Array]` —— Packed 数组写时复制，`var b = buckets[i]; b.pop_back()`
##   改的是副本，原桶不变 → 直接死循环；
## · 不能用「head + next 链表」—— 同一格会被更优代价重复入桶，`_next[c]` 被覆盖后
##   链表会串桶甚至成环 → 同样是死循环。
## 普通 Array 是引用语义，`_buckets[b].append(c)` 改的就是原对象。
var _buckets: Array = []
var _done: PackedByteArray = PackedByteArray()
var _tmp_x: PackedFloat32Array = PackedFloat32Array()
var _tmp_z: PackedFloat32Array = PackedFloat32Array()


func _init() -> void:
	walk.resize(FTOTAL)
	walk.fill(0)
	dist.resize(FTOTAL)
	dist.fill(INF)
	fx.resize(FTOTAL)
	fx.fill(0.0)
	fz.resize(FTOTAL)
	fz.fill(0.0)
	_di.resize(FTOTAL)
	_di.fill(INF_I)
	_done.resize(FTOTAL)
	_done.fill(0)
	_buckets.resize(NBUCKET)
	for i in range(NBUCKET):
		_buckets[i] = []
	_tmp_x.resize(FTOTAL)
	_tmp_z.resize(FTOTAL)


## 用 1m 的 walk 表刷新 2m 可走性。**只有 4 个子格全可走才算可走**（保守，保证不卡墙）。
## 调用频率：地图变了才调，不是每 tick。
func sync_from_walk1m(walk1m: PackedByteArray) -> void:
	walk.fill(0)
	for cz in range(FN):
		for cx in range(FN):
			# 2m 格的四个 1m 子格：((x*2), (z*2)) 起
			var x0: int = cx << 1
			var z0: int = cz << 1
			var ok: int = 1
			for dz in range(2):
				var base: int = ((z0 + dz) << 8)
				for dx in range(2):
					if walk1m[base | (x0 + dx)] == 0:
						ok = 0
						break
				if ok == 0:
					break
			walk[(cz << 7) | cx] = ok


## 重铺流场。target 是世界米。返回耗时（毫秒）。
func build(tx: float, tz: float) -> float:
	var t0: int = Time.get_ticks_usec()
	filled = 0
	valid = false
	target_cell = _cell_of(tx, tz)
	if target_cell < 0 or walk[target_cell] == 0:
		target_cell = _nearest_walkable(target_cell)
	if target_cell < 0:
		build_ms = 0.0
		return 0.0

	# 1) 重置（只重置上次填过的范围，别 fill 16384 次——那比 Dijkstra 还贵）
	dist.fill(INF)
	_di.fill(INF_I)
	_done.fill(0)
	for i in range(NBUCKET):
		(_buckets[i] as Array).clear()

	_di[target_cell] = 0
	(_buckets[0] as Array).append(target_cell)
	var cur: int = 0
	while cur < NBUCKET:
		var bucket: Array = _buckets[cur]
		if bucket.is_empty():
			cur += 1
			continue
		var c: int = bucket.pop_back()
		# 同一格可能被多次入桶；第一次出队即最优（桶号单调不减）
		if _done[c] != 0:
			continue
		_done[c] = 1
		var dc: int = _di[c]
		filled += 1
		var cx: int = c & FMASK
		var cz: int = c >> 7
		# 8 邻居，直 10、斜 14
		for k in range(8):
			var nx: int = cx + _DX[k]
			var nz: int = cz + _DZ[k]
			if nx < 0 or nx >= FN or nz < 0 or nz >= FN:
				continue
			var nc: int = (nz << 7) | nx
			if walk[nc] == 0:
				continue
			var nd: int = dc + (14 if (k >= 4) else 10)
			if nd < _di[nc]:
				_di[nc] = nd
				# BUCKET_W 必须是 2 的幂：用右移代替整数除法（线程安全 + 更快）
				var bi: int = nd >> 4
				if bi >= NBUCKET:
					bi = NBUCKET - 1
				(_buckets[bi] as Array).append(nc)
		if bucket.is_empty():
			cur += 1

	# 2) 距离场（米）
	for c in range(FTOTAL):
		var v: int = _di[c]
		dist[c] = INF if v >= INF_I else float(v) * 0.1

	# 3) 梯度 → 方向场
	for cz2 in range(FN):
		var row: int = cz2 << 7
		var rowp: int = ((cz2 + 1) & FMASK) << 7
		var rowm: int = ((cz2 - 1) & FMASK) << 7
		for cx2 in range(FN):
			var c2: int = row | cx2
			if walk[c2] == 0 or dist[c2] >= INF:
				fx[c2] = 0.0
				fz[c2] = 0.0
				continue
			var gx: float = dist[row | ((cx2 + 1) & FMASK)] - dist[row | ((cx2 - 1) & FMASK)]
			var gz: float = dist[rowp | cx2] - dist[rowm | cx2]
			if not is_finite(gx) or not is_finite(gz):
				fx[c2] = 0.0
				fz[c2] = 0.0
				continue
			var l: float = sqrt(gx * gx + gz * gz)
			if l > 1e-5:
				fx[c2] = -gx / l
				fz[c2] = -gz / l

	# 4) 3×3 平滑（中心 4、边 2、角 1 / 16）——这就是"多做一步平滑修正"
	_smooth()

	valid = true
	build_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	return build_ms


func _smooth() -> void:
	var _old_x: PackedFloat32Array = fx
	var _old_z: PackedFloat32Array = fz
	for cz in range(FN):
		var row: int = cz << 7
		var rp: int = ((cz + 1) & FMASK) << 7
		var rm: int = ((cz - 1) & FMASK) << 7
		for cx in range(FN):
			var c: int = row | cx
			if walk[c] == 0:
				_tmp_x[c] = 0.0
				_tmp_z[c] = 0.0
				continue
			var xl: int = row | ((cx - 1) & FMASK)
			var xr: int = row | ((cx + 1) & FMASK)
			var ax: float = fx[xl] + fx[xr]
			var az: float = fz[xl] + fz[xr]
			var bx: float = fx[rp | cx] + fx[rm | cx]
			var bz: float = fz[rp | cx] + fz[rm | cx]
			var dx: float = fx[rp | ((cx + 1) & FMASK)] + fx[rm | ((cx - 1) & FMASK)] \
					+ fx[rp | ((cx - 1) & FMASK)] + fx[rm | ((cx + 1) & FMASK)]
			var dz: float = fz[rp | ((cx + 1) & FMASK)] + fz[rm | ((cx - 1) & FMASK)] \
					+ fz[rp | ((cx - 1) & FMASK)] + fz[rm | ((cx + 1) & FMASK)]
			var sx: float = fx[c] * 4.0 + ax * 2.0 + bx * 2.0 + dx
			var sz: float = fz[c] * 4.0 + az * 2.0 + bz * 2.0 + dz
			_tmp_x[c] = sx
			_tmp_z[c] = sz
	fx = _tmp_x
	_tmp_x = _old_x
	fz = _tmp_z
	_tmp_z = _old_z
	# 归一化（平滑后长度不等于 1）
	for c in range(FTOTAL):
		var l: float = sqrt(fx[c] * fx[c] + fz[c] * fz[c])
		if l > 1e-5:
			fx[c] = fx[c] / l
			fz[c] = fz[c] / l
		else:
			fx[c] = 0.0
			fz[c] = 0.0


## 双线性采样方向。返回 (0,0) 表示不可达 / 就在目标上。
func sample(wx: float, wz: float) -> Vector2:
	if not valid:
		return Vector2.ZERO
	# 世界 → 连续格坐标（格心在 +1.0m，所以减 0.5）
	var u: float = (wx + 128.0) * 0.5 - 0.5
	var v: float = (wz + 128.0) * 0.5 - 0.5
	var x0: int = floori(u)
	var z0: int = floori(v)
	var tx: float = u - float(x0)
	var tz: float = v - float(z0)
	var x1: int = x0 + 1
	var z1: int = z0 + 1
	x0 = x0 & FMASK
	x1 = x1 & FMASK
	z0 = z0 & FMASK
	z1 = z1 & FMASK
	var c00: int = (z0 << 7) | x0
	var c10: int = (z0 << 7) | x1
	var c01: int = (z1 << 7) | x0
	var c11: int = (z1 << 7) | x1
	var w00: float = (1.0 - tx) * (1.0 - tz)
	var w10: float = tx * (1.0 - tz)
	var w01: float = (1.0 - tx) * tz
	var w11: float = tx * tz
	var sx: float = fx[c00] * w00 + fx[c10] * w10 + fx[c01] * w01 + fx[c11] * w11
	var sz: float = fz[c00] * w00 + fz[c10] * w10 + fz[c01] * w01 + fz[c11] * w11
	var l: float = sqrt(sx * sx + sz * sz)
	if l < 1e-4:
		return Vector2.ZERO
	return Vector2(sx / l, sz / l)


## 某个世界点是否可走（查 2m 格；用于看路探测）
func walkable_at(wx: float, wz: float) -> bool:
	if wx < -128.0 or wx >= 128.0 or wz < -128.0 or wz >= 128.0:
		return false
	var cx: int = ((floori(wx) + 128) >> 1) & FMASK
	var cz: int = ((floori(wz) + 128) >> 1) & FMASK
	return walk[(cz << 7) | cx] != 0


func dist_at(wx: float, wz: float) -> float:
	if wx < -128.0 or wx >= 128.0 or wz < -128.0 or wz >= 128.0:
		return INF
	var cx: int = ((floori(wx) + 128) >> 1) & FMASK
	var cz: int = ((floori(wz) + 128) >> 1) & FMASK
	return dist[(cz << 7) | cx]


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

func _cell_of(wx: float, wz: float) -> int:
	if wx < -128.0 or wx >= 128.0 or wz < -128.0 or wz >= 128.0:
		return -1
	var cx: int = ((floori(wx) + 128) >> 1) & FMASK
	var cz: int = ((floori(wz) + 128) >> 1) & FMASK
	return (cz << 7) | cx


## 目标落在墙里时，环形向外找最近可走格（最多找 4 圈 = 8m）
func _nearest_walkable(c: int) -> int:
	if c < 0:
		return -1
	if walk[c] != 0:
		return c
	var cx: int = c & FMASK
	var cz: int = c >> 7
	for r in range(1, 5):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var nx: int = cx + dx
				var nz: int = cz + dz
				if nx < 0 or nx >= FN or nz < 0 or nz >= FN:
					continue
				var nc: int = (nz << 7) | nx
				if walk[nc] != 0:
					return nc
	return -1


const _DX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const _DZ: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]
