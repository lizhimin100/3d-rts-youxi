extends RefCounted
## 职责：资源账本（金币 / 木材 / 人口）—— 付款与人口判断的唯一实现
## 属于：Model/core
## 对外：can_afford / pay / has_food / add / income_per_second / workers_for_income
## 状态用一个普通 Dictionary：{"gold": int, "wood": int}（由调用方持有，这里只改字段）。


static func can_afford(gold: int, wood: int, cost_gold: int, cost_wood: int) -> bool:
	return gold >= maxi(cost_gold, 0) and wood >= maxi(cost_wood, 0)


## 扣费；不够就**一分不扣**并返回 false（不做部分扣款）
static func pay(state: Dictionary, cost_gold: int, cost_wood: int) -> bool:
	var g := int(state.get("gold", 0))
	var w := int(state.get("wood", 0))
	if not can_afford(g, w, cost_gold, cost_wood):
		return false
	state["gold"] = g - maxi(cost_gold, 0)
	state["wood"] = w - maxi(cost_wood, 0)
	return true


static func add(state: Dictionary, gold: int, wood: int) -> void:
	state["gold"] = maxi(0, int(state.get("gold", 0)) + gold)
	state["wood"] = maxi(0, int(state.get("wood", 0)) + wood)


## 人口：已占用 + 已排队 + 这一单 <= 上限
static func has_food(used: int, reserved: int, amount: int, cap: int) -> bool:
	return maxi(used, 0) + maxi(reserved, 0) + maxi(amount, 0) <= maxi(cap, 0)


## 每秒金币收入：农民数 × 每趟携带 ÷ 每趟往返秒数
static func income_per_second(workers: int, carry: int, trip_seconds: float) -> float:
	if workers <= 0 or carry <= 0 or trip_seconds <= 0.0:
		return 0.0
	return float(workers) * float(carry) / trip_seconds


## 达到某个收入需要多少农民（报告/规划用）
static func workers_for_income(income_per_sec: float, carry: int, trip_seconds: float) -> int:
	var per := income_per_second(1, carry, trip_seconds)
	if per <= 0.0:
		return 0
	return int(ceil(maxf(income_per_sec, 0.0) / per))
