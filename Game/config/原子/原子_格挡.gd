@tool
class_name AtomBlock
extends SkillAtom
## **原子：格挡**（三层积木的第 1 层）
##
## 受击时按概率把这一次伤害打个折。**只描述效果**，触发方式由卡决定：
##   · 卡 kind = 受击 → 一直挂着（盾牌被动）；
##   · 以后想做"开技能后 3 秒内必挡" → 换一张开关卡，原子不用改。
##
## 判定在 `RtsCombat._apply()` 之前：`目标.skills_rt.block_mult(type)`。

@export_group("格挡")
## 触发概率（0~1）
@export var chance: float = 0.25
## 挡住之后伤害还剩多少（0.5 = 减半）
@export var mul: float = 0.5


func to_block() -> Dictionary:
	if chance <= 0.0 or mul >= 1.0:
		return {}
	return {"chance": clampf(chance, 0.0, 1.0), "mul": clampf(mul, 0.0, 1.0)}


func describe() -> String:
	return "%.0f%% 概率格挡（伤害 ×%.2f）" % [chance * 100.0, mul]
