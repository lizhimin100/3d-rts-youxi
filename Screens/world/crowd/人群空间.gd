extends RefCounted
## **人群空间分区** —— 计数排序的平坦网格（不是 Dictionary，不是 Array of Array）。
##
## 传统做法（`Game/pathing/空间哈希.gd`）是 `Dictionary[Vector2i] -> Array`：
##   · 每次 insert 都要 boxed Variant + 数组扩容；
##   · 每次 query 都要分配一个新数组；
##   · 1000 单位 × 每帧 1 次重建 = 每秒 6 万次分配。
## 这里换成**两遍计数排序**：先数每桶几个，前缀和，再把索引填进连续的 `PackedInt32Array`。
## 全程零分配（数组在 `setup()` 里一次分配到位）、零 Dictionary、零 Variant。
##
## 用法（热循环里直接内联，不要调函数）：
##     var b := (cz >> 2) << 6 | (cx >> 2)
##     for k in range(cell_start[b], cell_start[b + 1]):
##         var j := cell_items[k]
## 见 `人群模拟._steer_chunk()`。

const C := preload("res://Screens/world/crowd/人群常量.gd")

## 每桶在 items 里的起始下标，长度 BUCKET_TOTAL + 1（最后一个是总数）
var cell_start: PackedInt32Array = PackedInt32Array()
## 桶内成员（单位索引），长度 MAX_UNITS
var cell_items: PackedInt32Array = PackedInt32Array()
## 统计：本 tick 有多少单位入桶（诊断用）
var count: int = 0
## 统计：最挤的桶有多少人（诊断 / 调桶边长的依据）
var max_bucket_load: int = 0

var _cursor: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	cell_start.resize(C.BUCKET_TOTAL + 1)
	cell_start.fill(0)
	cell_items.resize(C.MAX_UNITS)
	cell_items.fill(0)
	_cursor.resize(C.BUCKET_TOTAL)
	_cursor.fill(0)


## 重建整张表。O(n + 4096)，纯位运算，**可以在工作线程里调**。
func build(px: PackedFloat32Array, pz: PackedFloat32Array, n: int) -> void:
	count = n
	# --- 1) 清零计数（只清 4096 个，不是清 16384 个）---
	_cursor.fill(0)
	# --- 2) 计数 ---
	for i in range(n):
		var bx: int = ((floori(px[i]) + 128) >> 2) & 63
		var bz: int = ((floori(pz[i]) + 128) >> 2) & 63
		_cursor[(bz << 6) | bx] += 1
	# --- 3) 前缀和 → cell_start；同时把 _cursor 复位成写游标 ---
	var acc: int = 0
	var busiest: int = 0
	for b in range(C.BUCKET_TOTAL):
		cell_start[b] = acc
		var c: int = _cursor[b]
		acc += c
		_cursor[b] = acc - c
		if c > busiest:
			busiest = c
	cell_start[C.BUCKET_TOTAL] = acc
	max_bucket_load = busiest
	# --- 4) 填充（稳定：同桶内保持索引升序，便于复现）---
	for i in range(n):
		var bx2: int = ((floori(px[i]) + 128) >> 2) & 63
		var bz2: int = ((floori(pz[i]) + 128) >> 2) & 63
		var b: int = (bz2 << 6) | bx2
		var k: int = _cursor[b]
		cell_items[k] = i
		_cursor[b] = k + 1


## 单点查询：把 3×3 桶的成员下标写进 out（复用调用方数组）。
## ⚠ 只用于冷路径（选目标、找最近单位）。热循环请内联。
func query_around(wx: float, wz: float, out: PackedInt32Array) -> int:
	var cx: int = ((floori(wx) + 128) >> 2) & 63
	var cz: int = ((floori(wz) + 128) >> 2) & 63
	var n: int = 0
	for dz in range(-1, 2):
		var bz: int = (cz + dz) & 63
		for dx in range(-1, 2):
			var bx: int = (cx + dx) & 63
			var b: int = (bz << 6) | bx
			for k in range(cell_start[b], cell_start[b + 1]):
				out[n] = cell_items[k]
				n += 1
	return n


## 诊断：桶负载分布（0,1,2,3-4,5-8,9+）
func load_histogram() -> PackedInt32Array:
	var h: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0])
	for b in range(C.BUCKET_TOTAL):
		var c: int = cell_start[b + 1] - cell_start[b]
		if c == 0:
			h[0] += 1
		elif c == 1:
			h[1] += 1
		elif c == 2:
			h[2] += 1
		elif c <= 4:
			h[3] += 1
		elif c <= 8:
			h[4] += 1
		else:
			h[5] += 1
	return h
