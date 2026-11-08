@tool
class_name AtomStat
extends SkillAtom
## **原子：属性倍率**（三层积木的第 1 层）
##
## 一条 修正 = "把某个 stat 乘以 mul（再加 add）"，可以限定伤害类型。
## 支持哪些 stat 见 `代码/系统/技能运行时.gd` 顶部（damage_taken / damage_dealt /
## move_speed / attack_cooldown / attack_range / armor）。
##
## ★ 它**不知道自己是举盾还是光环**：
##   卡上 kind = 开关 → 打开时生效（举盾）；
##   卡上 kind = 被动 → 一直生效（铁甲光环）。

@export_group("修正")
## 改哪个属性（词表见 技能运行时）
@export var stat: StringName = &"damage_taken"
## 倍率（0.85 = -15%；2.0 = 间隔翻倍 = 攻速 -50%）
@export var mul: float = 1.0
## 加法（armor 这类用加法；留 0 = 纯倍率）
@export var add: float = 0.0
## 只在某种伤害类型下生效（空 = 全部；"穿刺" / "魔法" / "普通" / "攻城"）
@export var when: StringName = &""


func to_mods() -> Array:
	var m: Dictionary = {"stat": String(stat), "mul": mul}
	if absf(add) > 0.0001:
		m["add"] = add
	if when != &"":
		m["when"] = String(when)
	return [m]


func describe() -> String:
	var pct: String = "%+.0f%%" % ((mul - 1.0) * 100.0)
	if absf(add) > 0.0001:
		pct += " %+.1f" % add
	var w: String = "" if when == &"" else "（仅 %s）" % String(when)
	return "%s %s%s" % [String(stat), pct, w]
