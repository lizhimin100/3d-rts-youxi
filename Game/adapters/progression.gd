extends RefCounted
## 职责：升级 / 主城等级（成长规则）的 **GDScript 适配层**
## 属于：Game/adapters（过渡层，调用方 API 不变）
## 真正实现：`Model/Core/Progression.cs`（含升星倍率/经验换算）

const BRIDGE := preload("res://Game/adapters/bridge.gd")


static func _bridge() -> RefCounted:
	return BRIDGE.get_bridge()

## 铁匠铺：每级平铺 +1（不是百分比）。level 从 0 起。
static func flat_bonus(level: int, per_level: float = 1.0) -> float:
	var m := _bridge()
	if m == null:
		return 0.0
	return float(m.call("ProgressionFlatBonus", level, per_level))


static func can_upgrade(level: int, max_level: int, gold: int, wood: int,
		cost_gold: int, cost_wood: int) -> bool:
	var m := _bridge()
	if m == null:
		return false
	return bool(m.call("ProgressionCanUpgrade", level, max_level, gold, wood, cost_gold, cost_wood))


## 升级成功：返回新等级；钱不够/到顶返回 -1
static func apply_level(level: int, max_level: int) -> int:
	var m := _bridge()
	if m == null:
		return -1
	return int(m.call("ProgressionApplyLevel", level, max_level))


## 主城等级门槛：建筑的 require_tier 必须 <= 当前主城等级
static func tier_allows(require_tier: int, current_tier: int) -> bool:
	var m := _bridge()
	if m == null:
		return false
	return bool(m.call("ProgressionTierAllows", require_tier, current_tier))
