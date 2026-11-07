extends RefCounted
## **道具占格规则（唯一出口）**：树 / 金矿 / 岩石在 1 米寻路网格上到底挡哪些格。
##
## 为什么单独一份：
##   以前"挡格"有 4 份实现 —— 程序化地图 `地图生成._apply_prop_blocks`、
##   读图 `地图加载器.build_walkable_mask`、砍树释放 `可采集物._free_footprint`
##   （它用的是 `def.footprint` = 2×2，和 0.95m 圆根本不是一回事）。
##   四份实现口径不一致的直接后果：
##     · 砍完树留下 2 个**隐形阻挡格**（圆的 5 格只放了其中 2~4 格）；
##     · 放出来的格子还可能是**邻树 / 岩石 / 建筑**的占格 —— 于是 A* 认为能过，
##       单位真的走进旁边那棵活树的树冠里，然后撞在净空判据上不动 = "被树卡住"。
##
## 现在规则只有这一份，**挡**和**放**调用同一函数，严格互为逆运算。
##
## 口径（2026-11-07 定）：
##   · 圆：格**心**落在圆内（`dist(格心, 道具心) <= radius`）才算挡。
##     不用旧的 `ceili(radius)` 整圈：0.95 → ceil 1 → 恒挡 5 格，等于半径 1.5m；
##     再叠加 `clearance_at` 给单位身体留的 0.5m，实际要离树心 2.0m 才敢过 ——
##     2.8m 间距的林间通道被整条吃掉，A* 只能返回空路径，单位退回"直行兜底"
##     然后顶在树冠边上停住。这就是玩家看到的"撤退被树卡住"。
##   · 矩形（金矿 4×4）：保持"原版逐格矩形"口径不变（落点是整数格，改它只会让旧图漂移）。
##   · 树半径 0.95 = UnitDef.body_radius 0.9 再留 5cm；岩石 1.05×scale。

## 树的占格半径（米）——全项目唯一数值。改这里，编辑器校验 / 游戏内 / 砍树释放同时生效。
const TREE_RADIUS: float = 0.95
## 岩石占格半径系数（米 / 单位缩放）
const ROCK_RADIUS: float = 1.05
## 矿的占格（格）
const MINE_CELLS: Vector2i = Vector2i(4, 4)
## 道具缩放的下限（和旧的 maxf(0.2, o.scale) 一致）
const MIN_SCALE: float = 0.2


## 格心落在圆内的格子索引（`z * w + x`）。
## 与 `mask` 同一套索引约定：格 (x,z) 的世界中心 = (x + 0.5) - w/2。
static func circle_cells(w: int, center: Vector2, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	if w <= 0 or radius <= 0.0:
		return out
	var half: float = float(w) * 0.5
	var r2: float = radius * radius
	# 包围盒：格心一定落在 [center - r, center + r] 内
	var x0: int = clampi(floori(center.x + half - radius - 0.5), 0, w - 1)
	var x1: int = clampi(ceili(center.x + half + radius + 0.5) - 1, 0, w - 1)
	var z0: int = clampi(floori(center.y + half - radius - 0.5), 0, w - 1)
	var z1: int = clampi(ceili(center.y + half + radius + 0.5) - 1, 0, w - 1)
	for z in range(z0, z1 + 1):
		var cz: float = -half + float(z) + 0.5
		var dz: float = cz - center.y
		for x in range(x0, x1 + 1):
			var cx: float = -half + float(x) + 0.5
			var dx: float = cx - center.x
			if dx * dx + dz * dz <= r2:
				out.append(z * w + x)
	return out


## 逐格矩形（原版口径，一字不差搬自 地图生成._block_rect_cells）。
## 中心格 = int(pos + half)，再向左上各退 sx/2、sz/2 格。
static func rect_cells(w: int, center: Vector2, sx: int, sz: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if w <= 0 or sx <= 0 or sz <= 0:
		return out
	var half: float = float(w) * 0.5
	var cx0: int = int(center.x + half) - sx / 2
	var cz0: int = int(center.y + half) - sz / 2
	for dz in range(sz):
		var cz: int = cz0 + dz
		if cz < 0 or cz >= w:
			continue
		for dx in range(sx):
			var cx: int = cx0 + dx
			if cx < 0 or cx >= w:
				continue
			out.append(cz * w + cx)
	return out


## 建筑占地矩形（**对称**取格：包围盒 min/max 各取 floor/ceil）。
## 搬自 地图加载器._block_rect，保持 8×8 / 6×6 在偶数/奇数足迹下都对称。
static func rect_cells_symmetric(w: int, center: Vector2, sx: int, sz: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if w <= 0 or sx <= 0 or sz <= 0:
		return out
	var half: float = float(w) * 0.5
	var x0: int = floori(center.x - float(sx) * 0.5 + half)
	var x1: int = ceili(center.x + float(sx) * 0.5 + half)
	var z0: int = floori(center.y - float(sz) * 0.5 + half)
	var z1: int = ceili(center.y + float(sz) * 0.5 + half)
	for z in range(z0, z1):
		if z < 0 or z >= w:
			continue
		for x in range(x0, x1):
			if x < 0 or x >= w:
				continue
			out.append(z * w + x)
	return out


## 树的占格（唯一口径）
static func tree_cells(w: int, center: Vector2) -> PackedInt32Array:
	return circle_cells(w, center, TREE_RADIUS)


## 岩石的占格（唯一口径）
static func rock_cells(w: int, center: Vector2, scale: float) -> PackedInt32Array:
	return circle_cells(w, center, ROCK_RADIUS * maxf(MIN_SCALE, scale))


## 把格子写进掩码（0 = 不可走）
static func apply_to_mask(mask: PackedByteArray, cells: PackedInt32Array) -> void:
	for i in cells:
		if i >= 0 and i < mask.size():
			mask[i] = 0


## 把格子恢复成可走（**只用于自检/重建**；运行时释放必须走关卡的引用计数，
## 否则会把邻树/岩石/建筑的格子一起放开）
static func clear_in_mask(mask: PackedByteArray, cells: PackedInt32Array) -> void:
	for i in cells:
		if i >= 0 and i < mask.size():
			mask[i] = 1
