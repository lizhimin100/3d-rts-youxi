extends RefCounted
## 职责：确定性随机数（xorshift32）—— Model 层唯一随机源
## 属于：Model/core
## 对外：new(seed) / next_u32() / next_float() / range_int(a,b) / pick(arr) / weighted_index(weights)
## 为什么不用引擎的 RNG：Model 要能在任何宿主里复现同一局（C# 内核以后也要同种子同结果）。

var _state: int = 1


func _init(seed_value: int = 1) -> void:
	reseed(seed_value)


func reseed(seed_value: int) -> void:
	_state = (seed_value ^ 0x9E3779B9) & 0x7FFFFFFF
	if _state == 0:
		_state = 1


func next_u32() -> int:
	var x := _state
	x ^= (x << 13) & 0xFFFFFFFF
	x ^= (x >> 17)
	x ^= (x << 5) & 0xFFFFFFFF
	_state = x & 0xFFFFFFFF
	return _state


func next_float() -> float:
	return float(next_u32()) / 4294967296.0


## [a, b] 闭区间整数
func range_int(a: int, b: int) -> int:
	if b <= a:
		return a
	return a + int(next_u32() % (b - a + 1))


func pick(items: Array) -> Variant:
	if items.is_empty():
		return null
	return items[int(next_u32() % items.size())]


## 按权重取下标；权重 <= 0 的项不会命中。全 0 时返回 0。
func weighted_index(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += maxf(float(w), 0.0)
	if total <= 0.0:
		return 0
	var r := next_float() * total
	var acc := 0.0
	for i in weights.size():
		acc += maxf(float(weights[i]), 0.0)
		if r < acc:
			return i
	return weights.size() - 1
