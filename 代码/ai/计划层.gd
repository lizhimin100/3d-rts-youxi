extends RefCounted
## **计划/预算层**（2C-13 §5，最小版）：不新建独立层，挂在目标层下面。
##
## 一句话：**计划是执行路径的描述，预留是资源占位** —— 两者不共生死。
##   目标确立 → 锁预留 → 按计划一步一步走 → 达成/过期/被抢占时**释放预留**。
##   计划本身不持有资源，也不引入新的仲裁层（§5 原文）。
##
## 为什么计划只有 1~3 步：这是"描述"，不是状态机。步数一多就会长出第二套
## 执行状态，和 `_exec_*` 抢职责 —— 2C-9 已经证明"两个地方都能下命令"会互相打架。
## 执行仍然由现有的 `_exec_*` 完成，计划只用来解释"这个目标打算怎么落地"。

## 9 种动作的计划模板（顺序即执行顺序；步数 ≤ 3，回归断言）。
const PLANS: Dictionary = {
	"建造": ["派农民", "建到完成"],
	"训练": ["检查兵营/队列", "排队", "训练完成"],
	"研发": ["检查科技建筑", "研究", "完成"],
	"攻击区域": ["集结空闲兵", "出击", "判定闭环"],
	"摧毁单位": ["选兵", "攻击目标", "目标死亡"],
	"防守地点": ["派兵", "驻守", "威胁解除"],
	"侦查地点": ["派兵", "到达", "返回"],
	"巡逻地点": ["派兵", "到达", "返回"],
	"建立分基地": ["选址", "建造", "完成"],
}

## 硬上限（任务书 §5："计划步数 ≤3"）
const MAX_STEPS: int = 3


## 某动作的计划步骤（副本；调用方改不到模板）。
static func plan_for(action: String) -> Array:
	var p = PLANS.get(action, null)
	if p == null or not (p is Array):
		return []
	return (p as Array).duplicate()


static func has_plan(action: String) -> bool:
	return PLANS.has(action)


## 计划是否合法：有模板、步数 1~3、每一步非空。
static func plan_valid(action: String) -> bool:
	var p: Array = plan_for(action)
	if p.is_empty() or p.size() > MAX_STEPS:
		return false
	for s in p:
		if String(s).is_empty():
			return false
	return true


## 全部动作都有模板且合法（回归一条断言扫完 9 种）。
static func all_plans_valid() -> bool:
	for a in PLANS.keys():
		if not plan_valid(String(a)):
			return false
	return PLANS.size() == 9


## 预留读的是**目标**，不是计划：任何计划都不产生自己的预算。
## 没有预留字段的目标 → 0（"空过"和不带钱的目标都走这条）。
static func reserve_of(goal: Dictionary) -> Dictionary:
	var r = goal.get("预留", null)
	if r is Dictionary and (r as Dictionary).has("金币"):
		return {
			"金币": maxi(int((r as Dictionary).get("金币", 0)), 0),
			"木材": maxi(int((r as Dictionary).get("木材", 0)), 0),
		}
	return {"金币": 0, "木材": 0}
