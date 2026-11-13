extends RefCounted
## **集结规划** —— 给一支出兵建筑算"多个"集结点，而不是所有兵挤一个点。
##
## 玩家原话：「不要所有集结点都设置在一起，且空地要远离出兵建筑一定距离、
## 空地要是一片区域」。
##
## 三条硬约束（每条都对应一个实际会翻车的场景）：
##   ① **离出兵建筑 ≥ 9m**：贴门集结会把出口堵死（兵营出口只有 3m），
##      新兵一出来就被自己人推回去，看起来像"卡在生产里"。
##   ② **空地要连片**：以候选点为中心、5m 半径内可走格 ≥ 75%。
##      只查中心点会选中"柱子旁边的一条缝"——兵走到那儿挤不下，原地打转。
##   ③ **两点间距 ≥ 11m**：两个点挨着等于一个点，分兵的收益全没了。
##
## 采样方式：16 个方向 × 4 个半径（12/19/26/33m）= 64 个候选，
## 全部走一次"连片率 + 朝向 + 距离"打分，取前 N 个且互相拉开。
## 成本：64 × 约 80 次可走查询 ≈ 5000 次，一次规划 < 2ms，**调用方自己缓存**。

## 离基地（出兵建筑中心）的最小/最大距离
const MIN_FROM_BASE: float = 9.0
const MAX_FROM_BASE: float = 38.0
## 理想距离（打分峰值）
const BEST_FROM_BASE: float = 20.0
## 两点之间最小间距
const MIN_BETWEEN: float = 11.0
## 连片检测半径与采样步长
const CLEAR_RADIUS: float = 5.0
const CLEAR_SAMPLE: float = 1.1
## 连片率下限
const CLEAR_MIN_RATIO: float = 0.75
## 背后的点直接丢弃（点积低于此值）
const FACING_MIN: float = -0.55


## 规划集结点。base = 出兵建筑/基地中心，foe = 敌方方向参考点。
## 返回 Array[Vector3]，按优先级从高到低；可能少于 want（地图太窄时）。
static func plan(base: Vector3, foe: Vector3, want: int = 3) -> Array:
	var out: Array = []
	var to_foe := Vector3(foe.x - base.x, 0.0, foe.z - base.z)
	if to_foe.length() < 1.0:
		to_foe = Vector3(0.0, 0.0, 1.0)
	to_foe = to_foe.normalized()
	var pf = RtsWorld.pathfinder()

	var cands: Array = []   # [score, Vector3]
	for ring in range(4):
		var r: float = 12.0 + float(ring) * 7.0
		if r > MAX_FROM_BASE:
			break
		# 16 方向；每环错开 11.25°，避免四环的点排成一条辐射线
		for k in range(16):
			var ang: float = TAU * (float(k) / 16.0 + float(ring) * 0.03125)
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			var facing: float = dir.dot(to_foe)
			if facing < FACING_MIN:
				continue      # 基地背后不设集结点
			var p: Vector3 = base + dir * r
			if not RtsWorld.is_walkable(p):
				continue
			var ratio: float = clear_ratio(p, pf)
			if ratio < CLEAR_MIN_RATIO:
				continue
			# 连片率是主项；朝敌方加分；离理想距离越远扣分
			var score: float = ratio * 2.0 + facing * 0.9 - absf(r - BEST_FROM_BASE) * 0.02
			cands.append([score, p])

	cands.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for c in cands:
		var p: Vector3 = c[1]
		var ok: bool = true
		for q in out:
			if (p as Vector3).distance_to(q as Vector3) < MIN_BETWEEN:
				ok = false
				break
		if ok:
			out.append(p)
			if out.size() >= want:
				break
	# 兜底：一个都选不出来（玩家把基地围死了）时给基地一个可行走点，
	# 宁可挤一点也不能让 "集结点 = INF" 把整支军队留在原地。
	if out.is_empty():
		out.append(RtsWorld.walkable_pos(base))
	return out


## 连片率：以 p 为中心、CLEAR_RADIUS 内可走格占比。
static func clear_ratio(p: Vector3, pf) -> float:
	var ok: int = 0
	var total: int = 0
	var steps: int = int(CLEAR_RADIUS / CLEAR_SAMPLE)
	var r2: int = steps * steps
	for dz in range(-steps, steps + 1):
		for dx in range(-steps, steps + 1):
			if dx * dx + dz * dz > r2:
				continue
			total += 1
			var q := Vector3(p.x + float(dx) * CLEAR_SAMPLE, p.y, p.z + float(dz) * CLEAR_SAMPLE)
			if pf != null and pf.is_walkable(q):
				ok += 1
	return float(ok) / float(maxi(1, total))
