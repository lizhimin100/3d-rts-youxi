class_name SpatialHash
extends RefCounted
## **空间哈希**：把场景里的单位按格子分桶，用于"附近有谁"这类查询。
## 为什么不用物理引擎：RTS 里几十上百个单位每帧互相查询，物理引擎的 broadphase
## 反而更重且不可控；自己分桶既快又完全确定，测试也好写。
##
## 用法：
##     var hash := SpatialHash.new(4.0)
##     hash.rebuild(units)          # 每帧调一次
##     var near := hash.query(pos, 3.0)

## 单个格子边长（米）
var cell_size: float = 4.0

## 桶：Vector2i → Array
var _buckets: Dictionary = {}


func _init(p_cell_size: float = 4.0) -> void:
	cell_size = maxf(0.5, p_cell_size)


## 世界坐标 → 格子键
func key_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / cell_size), floori(pos.z / cell_size))


## 清空所有桶
func clear() -> void:
	_buckets.clear()


## 插入一个对象（按位置分桶）
func insert(pos: Vector3, obj: Variant) -> void:
	var k := key_of(pos)
	if not _buckets.has(k):
		_buckets[k] = []
	_buckets[k].append(obj)


## 用一组"带 position 属性"的对象重建整个哈希
func rebuild(items: Array) -> void:
	clear()
	for it in items:
		if it == null or not is_instance_valid(it):
			continue
		insert(it.global_position, it)


## 查询圆形范围内的对象（结果可能略多于真实半径内的，调用方自己再精确过滤）
func query(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	query_into(pos, radius, out)
	return out


## **查询并写入调用方给的数组**（不分配新数组）。
##
## 为什么要有它（2026-11-07 性能排查）：`_update_separation` 是每单位每帧都要调的，
## 老 `query()` 每次都 `var out := []` + 9 次 `append_array` —— 3000 单位就是
## 每秒十几次万次数组分配 + GC。分离查询的结果只在下一次查询前有效，
## 所以复用同一个缓冲区完全安全（调用方自己保证不跨帧持有）。
func query_into(pos: Vector3, radius: float, out: Array) -> void:
	out.clear()
	var r: int = ceili(radius / cell_size)
	var base := key_of(pos)
	for dx in range(-r, r + 1):
		var bx: int = base.x + dx
		for dz in range(-r, r + 1):
			var k := Vector2i(bx, base.y + dz)
			# ⚠ 不能写 `_buckets.get(k, [])`：默认参数 `[]` 每次都会分配一个新数组
			if _buckets.has(k):
				out.append_array(_buckets[k])


## 查询最近的若干对象（按距离排序）
func query_nearest(pos: Vector3, radius: float, max_count: int) -> Array:
	var cand := query(pos, radius)
	var scored: Array = []
	for c in cand:
		if c == null or not is_instance_valid(c):
			continue
		scored.append([pos.distance_squared_to(c.global_position), c])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for i in mini(max_count, scored.size()):
		out.append(scored[i][1])
	return out
