extends RefCounted
## 职责：升级 / 主城等级（成长规则）—— 唯一实现
## 属于：Model/core
## 对外：flat_bonus / can_upgrade / apply_level / tier_allows


## 铁匠铺：每级平铺 +1（不是百分比）。level 从 0 起。
static func flat_bonus(level: int, per_level: float = 1.0) -> float:
	return float(maxi(level, 0)) * per_level


static func can_upgrade(level: int, max_level: int, gold: int, wood: int,
		cost_gold: int, cost_wood: int) -> bool:
	if level >= max_level:
		return false
	return gold >= cost_gold and wood >= cost_wood


## 升级成功：返回新等级；钱不够/到顶返回 -1（调用方据此扣费，避免扣了钱没升级）
static func apply_level(level: int, max_level: int) -> int:
	if level >= max_level:
		return -1
	return level + 1


## 主城等级门槛：建筑的 require_tier 必须 <= 当前主城等级
static func tier_allows(require_tier: int, current_tier: int) -> bool:
	return maxi(require_tier, 0) <= maxi(current_tier, 1)
