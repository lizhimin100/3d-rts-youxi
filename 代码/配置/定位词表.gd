extends RefCounted
## **定位词表**（2C-4 · C1）—— 所有卡字段取词的**唯一来源**。
##
## 规则（任务书 §2.3）：
##   · 卡字段只能从对应表取词；加词**只改本文件一处**；
##   · 攻击/防御类型**参与伤害结算**，改词要同步伤害公式（映射表 + RtsCombat 4×4 表）；
##   · 克制词表**不参与伤害结算**（纯标注），不放"克制前排/后排"；
##   · 职能当前只认 **承伤 / 输出**（选兵用），辅助/机动/控制先填着等兵种丰富。
##
## 与 UnitDef 枚举的映射也集中在这里（词 → RtsConst.DamageType / ArmorType），
## 单位表.gd 用它把卡上的词翻译成引擎枚举；**这里不写数值**，阈值是唯一的例外
## （攻击范围档位阈值，占位值，TODO 实测后调）。

# ---------------------------------------------------------------------------
# 词表本体（加词只改这里）
# ---------------------------------------------------------------------------

## 词表·兵种（单选）
const KINDS: Array[StringName] = [&"陆军", &"空军", &"海军"]

## 词表·攻击范围（档位名，由 range + 阈值**派生**，卡上不存）
const RANGE_TIERS: Array[StringName] = [&"近战", &"中程", &"远程", &"超远程"]
## 阈值（米）：range ≤ 上限 → 该档。
## ★ 2026-11-08：近战上限从 1.5 抬到 **2.5** —— 射程基准改了（R1 = 0.015 米/单位，
##   步兵卡上 125 = **1.875 米**），旧阈值 1.5 会把步兵判成"中程"，AI 的按档选兵就错位了。
##   现在：近战 ≤2.5m（农民 0.975 / 战士 1.2 / 重步兵 1.5 / 步兵 1.875），中程 ≤4m，远程 ≤8m，其余超远程。
const TIER_MELEE_MAX: float = 2.5
const TIER_MID_MAX: float = 4.0
const TIER_FAR_MAX: float = 8.0

## 词表·职能（多选）。**当前选兵只认 承伤/输出**（2C-4 用户口径）。
const FUNCTION_ROLES: Array[StringName] = [&"承伤", &"输出", &"辅助", &"机动", &"控制"]

## 词表·克制（多选，**不参与伤害结算**）
const COUNTERS: Array[StringName] = [&"轻甲", &"中甲", &"重甲", &"高血量", &"高护甲", &"建筑"]

## 词表·建筑功能（多选）
const BUILDING_FUNCTIONS: Array[StringName] = [&"产兵", &"防御", &"资源", &"科技", &"人口", &"治疗", &"侦察"]

## 词表·攻击类型（**参与结算**，改词要同步伤害公式）。
## 2026-11-03 加词「攻城」：引擎 RtsConst.DamageType.SIEGE(3) 一直存在（蒸汽重步兵在用），
## 2C-3 词表漏了它；卡要抄原表就必须补上，否则校验会拒绝合法数据。
const ATTACK_TYPES: Array[StringName] = [&"普通", &"穿刺", &"魔法", &"攻城"]

## 词表·防御类型（**参与结算**，改词要同步伤害公式）。
## 2026-11-03 加词「堡垒」「无」：引擎 ArmorType.FORTIFIED(2)/NONE(3)（全部建筑在用）。
## 「中甲」按任务书保留在词表里，但**引擎暂无对应 RtsConst.ArmorType**（LIGHT/HEAVY/FORTIFIED/NONE），
## 映射表里没有它 —— 当前卡不使用；引擎加了 MEDIUM 之后再接映射，不加词前填中甲会在校验报错。
const DEFENSE_TYPES: Array[StringName] = [&"轻甲", &"中甲", &"重甲", &"堡垒", &"无"]

## 农民特例：worker 不是战斗职能（任务书 §4.5），卡上的 roles 不填它；
## 引擎元数据 UnitDef.role = &"worker" 照抄在卡上（那是 2C-3 的引擎侧字段，不是职能词表）。

# ---------------------------------------------------------------------------
# 词 ↔ 引擎枚举映射（参与结算 —— 改这里 = 改伤害口径，必须同步 RtsCombat 表）
# ---------------------------------------------------------------------------

## 攻击类型词 → RtsConst.DamageType
const ATTACK_TYPE_MAP: Dictionary = {
	&"普通": 0,    # DamageType.NORMAL
	&"穿刺": 1,    # DamageType.PIERCE
	&"魔法": 2,    # DamageType.MAGIC
	&"攻城": 3,    # DamageType.SIEGE
}

## 防御类型词 → RtsConst.ArmorType（中甲暂无映射，见 DEFENSE_TYPES 注释）
const DEFENSE_TYPE_MAP: Dictionary = {
	&"轻甲": 0,    # ArmorType.LIGHT
	&"重甲": 1,    # ArmorType.HEAVY
	&"堡垒": 2,    # ArmorType.FORTIFIED
	&"无": 3,      # ArmorType.NONE
}


# ---------------------------------------------------------------------------
# 派生与校验（static 纯函数，卡与索引层都用）
# ---------------------------------------------------------------------------

## 攻击范围档位：由 range + 阈值只读派生（卡不存，索引层预计算一份）。
static func range_tier(rng: float) -> StringName:
	if rng <= TIER_MELEE_MAX:
		return &"近战"
	if rng <= TIER_MID_MAX:
		return &"中程"
	if rng <= TIER_FAR_MAX:
		return &"远程"
	return &"超远程"


## 攻击类型词 → 引擎枚举（未收录的词回落普通，校验会另报）
static func attack_type_of(word: StringName) -> int:
	return int(ATTACK_TYPE_MAP.get(word, 0))


## 防御类型词 → 引擎枚举（未收录的词回落轻甲，校验会另报）
static func defense_type_of(word: StringName) -> int:
	return int(DEFENSE_TYPE_MAP.get(word, 0))


## 校验：卡字段取词是否都在词表内（校验脚本用，不做编辑器工具）
static func validate_words(unit_class: StringName, roles: Array, counters: Array,
		attack_type_w: StringName, defense_type_w: StringName) -> PackedStringArray:
	var errs: PackedStringArray = []
	if not KINDS.has(unit_class):
		errs.append("兵种「%s」不在词表" % String(unit_class))
	for r in roles:
		if not FUNCTION_ROLES.has(r):
			errs.append("职能「%s」不在词表" % String(r))
	for c in counters:
		if not COUNTERS.has(c):
			errs.append("克制「%s」不在词表" % String(c))
	if not ATTACK_TYPES.has(attack_type_w):
		errs.append("攻击类型「%s」不在词表" % String(attack_type_w))
	if not DEFENSE_TYPES.has(defense_type_w):
		errs.append("防御类型「%s」不在词表" % String(defense_type_w))
	return errs


## 校验：建筑功能词
static func validate_functions(functions: Array) -> PackedStringArray:
	var errs: PackedStringArray = []
	for f in functions:
		if not BUILDING_FUNCTIONS.has(f):
			errs.append("建筑功能「%s」不在词表" % String(f))
	return errs


static func describe() -> String:
	return "词表：兵种%d / 范围%d档(%.1f/%.1f/%.1f) / 职能%d / 克制%d / 建筑功能%d / 攻击类型%d / 防御类型%d" % [
		KINDS.size(), RANGE_TIERS.size(), TIER_MELEE_MAX, TIER_MID_MAX, TIER_FAR_MAX,
		FUNCTION_ROLES.size(), COUNTERS.size(), BUILDING_FUNCTIONS.size(),
		ATTACK_TYPES.size(), DEFENSE_TYPES.size()]
