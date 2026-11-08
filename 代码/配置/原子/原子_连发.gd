@tool
class_name AtomBurst
extends SkillAtom
## **原子：连发**（三层积木的第 1 层）
##
## 一次攻击连打 shots 发，每发间隔 interval 秒，打完进 reload 秒装填。
## ★ 它**不知道自己是三连发还是散射**：卡上 kind = 被动 → 一直生效；
##   卡上 kind = 开关 → 打开时生效（未来做"连射模式"只要换张卡）。

@export_group("连发")
## 一轮打几发（>= 2 才有意义）
@export var shots: int = 3
## 两发之间的间隔（秒）
@export var interval: float = 0.12
## 一轮打完后装填多久（秒）。
## ★ 2026-11-08 玩家口径「装填时间绑定单位的攻击速度字段（攻速=装填）」：
##   这里的值**不再决定装填时长**（保留只为旧 .tres 兼容/编辑器可读），
##   运行时按单位的 attack_cooldown 算（见 技能运行时.burst_reload_seconds()）。
@export var reload: float = 2.0
## **每发伤害修正**（乘在单位攻击力上）。
## 2026-11-08 玩家拍板：三连发每发 = 攻击力的 **75%**（3 发 × 0.75 = 2.25 倍单发伤害）。
@export var damage_mult: float = 0.75


func to_burst() -> Dictionary:
	if shots <= 1:
		return {}
	return {"shots": shots, "interval": maxf(interval, 0.02),
		"reload": maxf(reload, 0.0), "damage_mult": maxf(damage_mult, 0.0)}


func describe() -> String:
	return "%d 连发（间隔 %.2fs，装填 %.1fs）" % [shots, interval, reload]
