extends RefCounted
## 职责：资源账本的 **GDScript 适配层** —— 真正实现已迁到 `Model/Core/Economy.cs`
## 属于：Game/adapters（过渡层，调用方 API 不变）
## 铁律：不写第二份公式；扣费/人口判断只在 C# 一份。

static var _mdl: Node = null


static func _bridge() -> Node:
	if _mdl != null and is_instance_valid(_mdl):
		return _mdl
	var main := Engine.get_main_loop()
	if main is SceneTree:
		_mdl = (main as SceneTree).root.get_node_or_null("Mdl")
	if _mdl == null:
		push_error("[Model] bridge Mdl missing (C# kernel not built?)")
	return _mdl


static func can_afford(gold: int, wood: int, cost_gold: int, cost_wood: int) -> bool:
	var m := _bridge()
	if m == null:
		return false
	return bool(m.call("EconomyCanAfford", gold, wood, cost_gold, cost_wood))


## 扣费；不够就**一分不扣**并返回 false（不做部分扣款）
static func pay(state: Dictionary, cost_gold: int, cost_wood: int) -> bool:
	var m := _bridge()
	if m == null:
		return false
	return bool(m.call("EconomyPay", state, cost_gold, cost_wood))


static func add(state: Dictionary, gold: int, wood: int) -> void:
	var m := _bridge()
	if m == null:
		return
	m.call("EconomyAdd", state, gold, wood)


## 人口：已占用 + 已排队 + 这一单 <= 上限
static func has_food(used: int, reserved: int, amount: int, cap: int) -> bool:
	var m := _bridge()
	if m == null:
		return false
	return bool(m.call("EconomyHasFood", used, reserved, amount, cap))


## CP：指挥点够不够下单（短局唯一资源）
static func can_spend_cp(cp: int, cost_cp: int) -> bool:
	var m := _bridge()
	if m == null:
		return false
	return bool(m.call("EconomyCanSpendCp", cp, cost_cp))


## 每秒金币收入（抽象补给率；短局不用）
static func income_per_second(workers: int, carry: int, trip_seconds: float) -> float:
	var m := _bridge()
	if m == null:
		return 0.0
	return float(m.call("EconomyIncomePerSecond", workers, carry, trip_seconds))


static func workers_for_income(income_per_sec: float, carry: int, trip_seconds: float) -> int:
	var m := _bridge()
	if m == null:
		return 0
	return int(m.call("EconomyWorkersForIncome", income_per_sec, carry, trip_seconds))
