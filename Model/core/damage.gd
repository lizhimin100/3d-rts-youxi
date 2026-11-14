extends RefCounted
## 职责：伤害公式（护甲减免、克制表、暴击、升级乘数）—— **全游戏唯一实现**
## 属于：Model/core
## 对外：armor_mitigation / counter_multiplier / compute
## 公式（冻结，改动要同步 Documents/concept.md 与 --check 的对照断言）：
##   伤害 = (基础 ± spread 随机) × 克制 × (1 - 护甲减免) × 暴击 × 升级乘数
##   护甲减免 = min(armor × 每点系数, 上限)
## 纯函数：随机数由调用方传入 [0,1)，不在这里取随机。

## rules 里缺字段时的安全默认（只用于容错，不是数值真相）
const DEFAULT_STRIDE := 5


static func armor_mitigation(armor: float, reduction: float, cap: float) -> float:
	return minf(maxf(armor, 0.0) * maxf(reduction, 0.0), maxf(cap, 0.0))


## 克制表：行 = 伤害类型，列 = 护甲类型，扁平存储，stride = 每行几列
static func counter_multiplier(table: Array, attack_type: int, armor_type: int, stride: int = DEFAULT_STRIDE) -> float:
	if table.is_empty() or stride <= 0:
		return 1.0
	var row := clampi(attack_type, 0, maxi(int(table.size() / stride) - 1, 0))
	var col := clampi(armor_type, 0, stride - 1)
	var idx := row * stride + col
	if idx < 0 or idx >= table.size():
		return 1.0
	return float(table[idx])


## 算一次伤害。返回 {damage, mitigation, multiplier, is_crit, ok}
## roll_spread / roll_crit 必须是 [0,1) 的确定性输入（由调用方从 RNG 取）。
static func compute(base: float, spread: float, attack_type: int,
		target_armor: float, target_armor_type: int,
		rules: Dictionary, roll_spread: float, roll_crit: float,
		attack_mult: float = 1.0) -> Dictionary:
	var table: Variant = rules.get("damage_table", [])
	if not (table is Array):
		return {"ok": false, "damage": 0.0, "mitigation": 0.0, "multiplier": 1.0, "is_crit": false}
	var stride := int(rules.get("stride", DEFAULT_STRIDE))
	var r_spread := clampf(roll_spread, 0.0, 0.999999)
	var r_crit := clampf(roll_crit, 0.0, 0.999999)
	var base_dmg := base + spread * (r_spread * 2.0 - 1.0)
	var mult := counter_multiplier(table, attack_type, target_armor_type, stride)
	var mit := armor_mitigation(target_armor, float(rules.get("armor_reduction", 0.0)), float(rules.get("armor_reduction_cap", 0.0)))
	var is_crit := r_crit < float(rules.get("crit_chance", 0.0))
	var crit := float(rules.get("crit_multiplier", 1.0)) if is_crit else 1.0
	var dmg := base_dmg * mult * (1.0 - mit) * crit * maxf(attack_mult, 0.0)
	return {
		"ok": true,
		"damage": maxf(dmg, 0.0),
		"mitigation": mit,
		"multiplier": mult,
		"is_crit": is_crit,
	}
