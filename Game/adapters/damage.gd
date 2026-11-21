extends RefCounted
## 职责：伤害公式的 **GDScript 适配层** —— 真正实现已迁到 `Model/Core/Damage.cs`
## 属于：Game/adapters（过渡层，调用方 API 不变）
## 为什么留着这层：全项目 20+ 处 `ModelDamage.compute(...)` 的调用签名不变，
##   规则却只剩 C# 一份；哪天调用方全换成 Mdl，这层可以整块删掉。
## 铁律：这里**不许**再写一份公式，只做"转参数 → 调 Mdl → 拆字典"。

const DEFAULT_STRIDE := 5

const BRIDGE := preload("res://Game/adapters/bridge.gd")


static func _bridge() -> RefCounted:
	return BRIDGE.get_bridge()

static func armor_mitigation(armor: float, reduction: float, cap: float) -> float:
	var m := _bridge()
	if m == null:
		return 0.0
	return float(m.call("DamageArmorMitigation", armor, reduction, cap))


## 克制表：行 = 伤害类型，列 = 护甲类型，扁平存储，stride = 每行几列
static func counter_multiplier(table: Array, attack_type: int, armor_type: int, stride: int = DEFAULT_STRIDE) -> float:
	var m := _bridge()
	if m == null:
		return 1.0
	return float(m.call("DamageCounterMultiplier", table, attack_type, armor_type, stride))


## 算一次伤害。返回 {damage, mitigation, multiplier, is_crit, ok}
## roll_spread / roll_crit 必须是 [0,1) 的确定性输入（由调用方从 RNG 取）。
static func compute(base: float, spread: float, attack_type: int,
		target_armor: float, target_armor_type: int,
		rules: Dictionary, roll_spread: float, roll_crit: float,
		attack_mult: float = 1.0) -> Dictionary:
	var m := _bridge()
	if m == null:
		return {"ok": false, "damage": 0.0, "mitigation": 0.0, "multiplier": 1.0, "is_crit": false}
	return m.call("DamageCompute", base, spread, attack_type, target_armor, target_armor_type,
		rules, roll_spread, roll_crit, attack_mult)
