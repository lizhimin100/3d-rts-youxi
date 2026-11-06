extends RefCounted
## **技能表（雏形）**：id → 定义。数值只住这里，执行逻辑在 `代码/系统/技能.gd`。
##
## 为什么要这张表（2026-11-07）：
##   以前技能数值是 `技能.gd` 里的一堆 const，采集/伐木/采矿更是直接写死在
##   单位状态机里 —— 加第三个技能就要再复制一段 if。现在统一成：
##
##   定义（本文件） → 执行（技能.gd 的 begin_cast/release） → 表现（单位视觉）
##
## 字段（一个都不许省，配置回归会按这个列表校验）：
##   id        StringName  唯一 id
##   name      String      中文名（提示条/命令卡用）
##   kind      StringName  主动 / 采集 / 被动
##   target    StringName  无 / 点 / 单位 / 资源
##   cast      float       前摇秒数（0 = 瞬发）
##   cooldown  float       冷却秒数（0 = 无冷却；采集类不看这个）
##   range     float       施放距离（米，按"身位边缘"口径，见 文档/战斗射程口径.md）
##   icon      String      图标 id（界面规格.icon 的键）
##   note      String      一句话说明
##
## ★ 采集类技能（chop_wood / mine_gold）不是"点一下放一次"的主动技能：
##   它们由右键点资源触发，`cast` 是"到点后钻进矿洞/举斧起手"的时间，
##   `slots` 是这个资源点能同时容纳几个农民（魔兽的"载位"）。
##   执行仍走 `单位.gd` 的 GatherPhase（见 GatherPhase.ENTER）。

const K_ACTIVE: StringName = &"主动"
const K_GATHER: StringName = &"采集"
const K_PASSIVE: StringName = &"被动"

const T_NONE: StringName = &"无"
const T_POINT: StringName = &"点"
const T_UNIT: StringName = &"单位"
const T_RESOURCE: StringName = &"资源"

## 全部技能定义。改数值只改这里。
const DEFS: Dictionary = {
	&"fireball": {
		"id": &"fireball", "name": "火球术", "kind": K_ACTIVE, "target": T_UNIT,
		"cast": 0.5, "cooldown": 8.0, "range": 9.0, "icon": "fire",
		"note": "丢出一颗火球，落点 3.5m 内 55 伤害并减速 40%（2.5s）。",
	},
	&"chop_wood": {
		"id": &"chop_wood", "name": "伐木", "kind": K_GATHER, "target": T_RESOURCE,
		"cast": 0.20, "cooldown": 0.0, "range": 1.4, "icon": "axe",
		"slots": 2,
		"note": "对树木使用：贴身挥斧，每一下都让树晃；4 挥装满一背。",
	},
	&"mine_gold": {
		"id": &"mine_gold", "name": "采矿", "kind": K_GATHER, "target": T_RESOURCE,
		"cast": 0.35, "cooldown": 0.0, "range": 1.4, "icon": "pick",
		"slots": 3,
		"note": "对金矿使用：走进矿洞（占一个载位），装满一背再出来。",
	},
}


static func has(id: StringName) -> bool:
	return DEFS.has(id)


static func get_def(id: StringName) -> Dictionary:
	return DEFS.get(id, {})


static func ids() -> Array:
	return DEFS.keys()


static func is_gather(id: StringName) -> bool:
	var d: Dictionary = get_def(id)
	return not d.is_empty() and StringName(d.get("kind", &"")) == K_GATHER


## 采集技能同时能容纳几个农民（载位）。没有这个字段 = 1。
static func slots_of(id: StringName) -> int:
	var d: Dictionary = get_def(id)
	if d.is_empty():
		return 1
	return maxi(1, int(d.get("slots", 1)))


## 按资源种类挑采集技能（金矿 → 采矿，树 → 伐木）
static func gather_skill_for(kind: int) -> StringName:
	return &"chop_wood" if kind == 1 else &"mine_gold"
