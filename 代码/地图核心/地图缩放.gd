extends RefCounted
## **地图尺寸缩放（扩大）** —— 2026-11-08 玩家要求：
##   「加'地图尺寸缩放/扩大'，同步改小地图缩放、镜头边界、寻路分块。」
##
## 做法：**以地图中心为锚点，每边各加 N 米**。
##   · 高度场 / 地表层 / 地块格点表全部按**世界坐标**重采样（不是简单拷贝数组），
##     所以旧地形的形状、土路走向、营地位置都保持原位，只是四周多出一圈；
##   · 新加出来的那圈高度**沿用最近的边缘高度**（bilinear 采样越界时夹到边缘），
##     等于"把最外沿往外延伸" —— 不会突然出现悬崖，也不会一片全 0；
##   · 对象 / 玩家出生点 / 区域 / 镜头边界 / 水面 / 地面叙事层（草、石、杂物、路）
##     全部按 +N 平移，保证"原来的东西还在原来的相对位置"；
##   · 小地图、镜头边界、寻路分块都从 `MapDef.size` 派生（运行时读 level.world_size），
##     所以这里改完 size，那三样**自动跟着变**，不需要各自再写一份缩放。
##
## ⚠ 只做"扩大"，不做"缩小"：缩小会裁掉对象/出生点，属于另一个危险操作，
##   玩家这次只要"缩放/扩大"。

## 每边允许加的最小/最大米数
const MIN_ADD: int = 8
const MAX_ADD: int = 192


## 把地图每边扩大 add_meters 米（必须是 8 的倍数：地块格点边长就是 8m）。
## 返回 true = 改成功了（in-place 修改传入的 MapDef）。
static func expand(m: MapDef, add_meters: int) -> bool:
	if m == null:
		return false
	# 必须是 8 的倍数：地块一格就是 8m，不整除会让 mat_tile 变成小数
	if add_meters % 8 != 0:
		return false
	var add: int = add_meters
	if add < MIN_ADD or add > MAX_ADD:
		return false
	var old_size: int = int(m.size)
	if old_size <= 0:
		return false
	var old_res: int = maxi(int(m.height_resolution), 4)
	var new_size: int = old_size + add * 2
	var new_res: int = clampi(int(round(float(old_res) * float(new_size) / float(old_size))), 16, 512)
	var old_cell: float = float(old_size) / float(old_res)
	var new_cell: float = float(new_size) / float(new_res)
	var old_half: float = float(old_size) * 0.5
	var new_half: float = float(new_size) * 0.5

	m.ensure_arrays()
	# --- 1) 高度场重采样（双线性，越界夹边缘）---
	var old_row: int = old_res + 1
	var old_h: PackedFloat32Array = m.heightmap
	var new_row: int = new_res + 1
	var new_h := PackedFloat32Array()
	new_h.resize(new_row * new_row)
	for gz in new_row:
		var wz: float = -new_half + float(gz) * new_cell
		for gx in new_row:
			var wx: float = -new_half + float(gx) * new_cell
			new_h[gz * new_row + gx] = _sample_bilinear(old_h, old_row, old_cell, old_half, wx, wz)

	# --- 2) 地表层（最近邻）---
	var old_splat: PackedByteArray = m.splatmap
	var new_splat := PackedByteArray()
	new_splat.resize(new_res * new_res)
	for gz in new_res:
		var wz2: float = -new_half + (float(gz) + 0.5) * new_cell
		for gx in new_res:
			var wx2: float = -new_half + (float(gx) + 0.5) * new_cell
			var ogx: int = clampi(int(floor((wx2 + old_half) / old_cell)), 0, old_res - 1)
			var ogz: int = clampi(int(floor((wz2 + old_half) / old_cell)), 0, old_res - 1)
			var idx: int = ogz * old_res + ogx
			new_splat[gz * new_res + gx] = old_splat[idx] if idx < old_splat.size() else 0

	# --- 3) 地块格点表（8m 一格，最近邻）---
	var old_cells: int = int(m.mat_cells)
	var new_cells: int = maxi(1, int(round(float(new_size) / 8.0)))
	var new_mat := PackedByteArray()
	new_mat.resize((new_cells + 1) * (new_cells + 1))
	if old_cells > 0 and m.mat_nodes.size() == (old_cells + 1) * (old_cells + 1):
		var old_tile: float = float(old_size) / float(old_cells)
		for j in new_cells + 1:
			var wz3: float = -new_half + float(j) * float(new_size) / float(new_cells)
			for i in new_cells + 1:
				var wx3: float = -new_half + float(i) * float(new_size) / float(new_cells)
				var oi: int = clampi(int(round((wx3 + old_half) / old_tile)), 0, old_cells)
				var oj: int = clampi(int(round((wz3 + old_half) / old_tile)), 0, old_cells)
				new_mat[j * (new_cells + 1) + i] = m.mat_nodes[oj * (old_cells + 1) + oi]

	# --- 4) 一切都是"整体外扩"，所以内容整体偏移 +add ---
	var d := Vector2(float(add), float(add))
	_shift_objects(m.objects, d)
	for p in m.players:
		if p == null:
			continue
		p.start_pos = p.start_pos + d
	for r in m.regions:
		if r == null:
			continue
		var pts: PackedVector2Array = r.points
		for i in pts.size():
			pts[i] = pts[i] + d
		r.points = pts
	# 水面 / 地面叙事层
	var water: Dictionary = m.water
	var spots: Variant = water.get("spots", [])
	if spots is Array:
		for s in (spots as Array):
			if s is Dictionary and (s as Dictionary).has("center"):
				var c: Variant = (s as Dictionary)["center"]
				if c is Vector2:
					(s as Dictionary)["center"] = (c as Vector2) + d
	m.ground = _shift_ground(m.ground, d)

	# --- 5) 尺寸字段最后写（前面的采样都靠旧值）---
	m.size = new_size
	m.height_resolution = new_res
	m.heightmap = new_h
	m.splatmap = new_splat
	m.mat_cells = new_cells
	m.mat_nodes = new_mat
	m.mat_tile = float(new_size) / float(new_cells)
	m.camera_bounds = Rect2(Vector2(-new_half + 2.0, -new_half + 2.0),
			Vector2(float(new_size) - 4.0, float(new_size) - 4.0))
	m.ensure_arrays()
	return true


## 双线性采样旧高度场；越界 → 夹到最近的边缘格点（"把最外沿往外延伸"）
static func _sample_bilinear(h: PackedFloat32Array, row: int, cell: float,
		half: float, wx: float, wz: float) -> float:
	if h.size() < row * row or row < 2:
		return 0.0
	var fx: float = (wx + half) / cell
	var fz: float = (wz + half) / cell
	var x0: int = clampi(int(floor(fx)), 0, row - 1)
	var z0: int = clampi(int(floor(fz)), 0, row - 1)
	var x1: int = clampi(x0 + 1, 0, row - 1)
	var z1: int = clampi(z0 + 1, 0, row - 1)
	var tx: float = clampf(fx - float(x0), 0.0, 1.0)
	var tz: float = clampf(fz - float(z0), 0.0, 1.0)
	var h00: float = h[z0 * row + x0]
	var h10: float = h[z0 * row + x1]
	var h01: float = h[z1 * row + x0]
	var h11: float = h[z1 * row + x1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## 对象整体平移
static func _shift_objects(objs: Array, d: Vector2) -> void:
	for o in objs:
		if o == null:
			continue
		# MapObject.position 是 Vector3（y 是贴地高度，扩图不动它）
		o.position = o.position + Vector3(d.x, 0.0, d.y)


## 地面叙事层（草/石/杂物/路…）整体平移。
## 形状是 [{"pos": Vector2|Vector3, "rot":…, …}] 和 {"barrel": [...]} 这种嵌套，
## 所以按 key 递归：只动名为 `pos` 的坐标，别的值一律不碰。
static func _shift_ground(g: Dictionary, d: Vector2) -> Dictionary:
	var out: Dictionary = g.duplicate(true)
	for k in out.keys():
		out[k] = _shift_value(out[k], d)
	return out


static func _shift_value(v: Variant, d: Vector2) -> Variant:
	if v is Array:
		var arr: Array = v
		for i in arr.size():
			arr[i] = _shift_value(arr[i], d)
		return arr
	if v is Dictionary:
		var dict: Dictionary = v
		for k in dict.keys():
			if String(k) == "pos":
				var p: Variant = dict[k]
				if p is Vector3:
					dict[k] = (p as Vector3) + Vector3(d.x, 0.0, d.y)
				elif p is Vector2:
					dict[k] = (p as Vector2) + d
				continue
			dict[k] = _shift_value(dict[k], d)
		return dict
	return v
