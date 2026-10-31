extends RefCounted
## **战斗数学**：把"这两支部队谁强"变成一个数。
##
## 为什么不能只数人头/看血量：本项目的伤害是
##   最终 = (基础 ± 浮动) × **克制** × (1 − 护甲减免) × 暴击
## 其中"克制"是 attack_type × armor_type 的 4×4 表（Cfg.game.damage_table）。
## 数人头会得出"6 个步兵打 4 个弓箭手必胜"，而实际是 4 个弓箭手把 6 个步兵打成筛子
## （穿刺 × 重甲 = 0.85，看着不高；但弓箭手射程 11m，步兵要走 10 秒才够得着）。
##
## 这里**不复写公式**：克制/减免/升级全部问 RtsCombat（唯一实现），
## 本文件只负责"期望值 + 归一化"，避免两份公式慢慢漂开。
##
## 三个对外接口：
##   · `profile(units)`   一支队伍的"挨打画像"（护甲值 / 护甲类型分布 / 伤害类型分布）
##   · `value(def, 画像)` 一个兵在这张画像下的战力（DPS 与有效生命的几何平均）
##   · `ratio(a, b)`      两支部队的战力比（AI 的进攻/撤退判据都读它）

## 有效生命的几何平均指数：0.5 = 几何平均（DPS 与肉度同等重要）
const BALANCE_EXP: float = 0.5
## 战力的下限（防止"零攻击"的农民把整支部队的均值拉爆）
const MIN_VALUE: float = 1.0
## 估算时的护甲减免系数（护甲值 -> 减免比例）
var _cfg: GameConfig = null


func _init() -> void:
	_cfg = Cfg.game if Cfg != null else null


# ===========================================================================
# 画像
# ===========================================================================

## 一支队伍的画像：
##   armor     —— 按生命加权的平均护甲**值**（减免比例要用它）
##   armor_mix —— 护甲**类型**分布（权重和 = 1），用来算攻击方的期望克制倍率
##   dmg_mix   —— 伤害**类型**分布（权重和 = 1，按 DPS 加权），用来算挨打方的期望克制
##   hp        —— 总生命（估算"要打多久"）
func profile(units: Array) -> Dictionary:
	var armor_mix: Dictionary = {}
	var dmg_mix: Dictionary = {}
	var hp_sum: float = 0.0
	var armor_w: float = 0.0
	var dps_sum: float = 0.0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		var d: UnitDef = u.def
		if d == null:
			continue
		var hp: float = maxf(float(u.hp), 1.0)
		hp_sum += hp
		armor_w += _effective_armor(u, d) * hp
		armor_mix[d.armor_type] = float(armor_mix.get(d.armor_type, 0.0)) + hp
		var raw_dps: float = d.attack_damage / maxf(d.attack_cooldown, 0.1)
		if raw_dps > 0.0:
			dmg_mix[d.attack_type] = float(dmg_mix.get(d.attack_type, 0.0)) + raw_dps
			dps_sum += raw_dps
	_normalize(armor_mix)
	_normalize(dmg_mix)
	if armor_mix.is_empty():
		armor_mix[RtsConst.ArmorType.LIGHT] = 1.0
	if dmg_mix.is_empty():
		dmg_mix[RtsConst.DamageType.NORMAL] = 1.0
	return {
		"armor": armor_w / maxf(hp_sum, 1.0),
		"armor_mix": armor_mix,
		"dmg_mix": dmg_mix,
		"hp": hp_sum,
	}


func _normalize(mix: Dictionary) -> void:
	var total: float = 0.0
	for k in mix.keys():
		total += float(mix[k])
	if total <= 0.0:
		return
	for k in mix.keys():
		mix[k] = float(mix[k]) / total


# ===========================================================================
# 单个兵的战力
# ===========================================================================

## 这个兵对着"敌方画像"能打出多少每秒伤害（期望值，含克制、护甲减免、暴击、阵营升级）
func dps(def: UnitDef, enemy_profile: Dictionary, atk_mult: float = 1.0) -> float:
	if def == null or def.attack_damage <= 0.0 or def.attack_cooldown <= 0.0:
		return 0.0
	var counter: float = _expected_counter(def.attack_type, enemy_profile["armor_mix"])
	var mit: float = RtsCombat.armor_mitigation(float(enemy_profile["armor"]))
	var crit: float = _crit_avg()
	var total: float = def.attack_damage * counter * (1.0 - mit) * crit * atk_mult
	return total / maxf(def.attack_cooldown, 0.1)


## 这个兵面对"敌方画像"能扛多少等效伤害
func ehp(def: UnitDef, enemy_profile: Dictionary, armor_mult: float = 1.0) -> float:
	if def == null:
		return 0.0
	var incoming: float = _expected_counter_inverse(def.armor_type, enemy_profile["dmg_mix"])
	var mit: float = RtsCombat.armor_mitigation(def.armor * armor_mult)
	return def.max_hp / maxf(incoming * (1.0 - mit), 0.05)


## 战力 = DPS 与有效生命的几何平均（量纲无关，方便横向比较）
func value(def: UnitDef, enemy_profile: Dictionary,
		atk_mult: float = 1.0, armor_mult: float = 1.0) -> float:
	var a: float = dps(def, enemy_profile, atk_mult)
	var b: float = ehp(def, enemy_profile, armor_mult)
	return maxf(sqrt(a * b), MIN_VALUE)


## 每金战力：造这个兵"值不值"。
## 分母不是单纯的金币：木材、人口、建造时间都要折算进去，否则
## AI 会永远选"便宜但没用"的兵（比如 75 金的农民）。
func worth_per_cost(def: UnitDef, enemy_profile: Dictionary,
		atk_mult: float = 1.0, armor_mult: float = 1.0,
		cost_gold: float = 1.0, cost_wood: float = 1.5,
		cost_supply: float = 12.0, cost_time: float = 0.6) -> float:
	if def == null:
		return 0.0
	var cost: float = (float(def.gold_cost) * cost_gold
			+ float(def.wood_cost) * cost_wood
			+ float(def.food_cost) * cost_supply
			+ def.train_time * cost_time)
	return value(def, enemy_profile, atk_mult, armor_mult) / maxf(cost, 1.0)


# ===========================================================================
# 队伍
# ===========================================================================

## 一支队伍的总战力（对着对面那支队伍的画像估值）
func army_value(units: Array, enemy_profile: Dictionary,
		atk_mult: float = 1.0, armor_mult: float = 1.0) -> float:
	var total: float = 0.0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.def == null:
			continue
		if u.def.kind != RtsConst.Kind.UNIT:
			continue
		total += value(u.def, enemy_profile, atk_mult, armor_mult)
	return total


## 战力比 = 我方 / 敌方。双方用**同一套**画像互相估值，所以是可比数。
## 敌方为空时返回 -1（表示"没有情报"），由调用方决定怎么处理。
func ratio(mine: Array, theirs: Array) -> float:
	if theirs.is_empty():
		return -1.0
	var mine_fac: RtsFaction = _faction_of(mine)
	var their_fac: RtsFaction = _faction_of(theirs)
	var my_atk: float = RtsCombat.attack_mult(mine_fac)
	var my_arm: float = RtsCombat.armor_mult(mine_fac)
	var their_atk: float = RtsCombat.attack_mult(their_fac)
	var their_arm: float = RtsCombat.armor_mult(their_fac)
	var my_value: float = army_value(mine, profile(theirs), my_atk, my_arm)
	var their_value: float = army_value(theirs, profile(mine), their_atk, their_arm)
	if their_value <= 0.0:
		return 8.0
	return clampf(my_value / their_value, 0.02, 8.0)


## 这支队伍"最怕的伤害类型"和"最克制的护甲类型"（生产决策用）
func best_counter_damage_type(theirs: Array) -> int:
	var prof: Dictionary = profile(theirs)
	var best: int = RtsConst.DamageType.NORMAL
	var best_score: float = -1.0
	for t in [RtsConst.DamageType.NORMAL, RtsConst.DamageType.PIERCE,
			RtsConst.DamageType.MAGIC, RtsConst.DamageType.SIEGE]:
		var score: float = _expected_counter(int(t), prof["armor_mix"])
		if score > best_score:
			best_score = score
			best = int(t)
	return best


# ===========================================================================
# 内部
# ===========================================================================

## 攻击类型 vs 敌方护甲类型分布的期望克制倍率
func _expected_counter(damage_type: int, armor_mix: Dictionary) -> float:
	var s: float = 0.0
	for k in armor_mix.keys():
		s += float(armor_mix[k]) * RtsCombat.counter_multiplier(damage_type, int(k))
	return s if s > 0.0 else 1.0


## 我方护甲类型 vs 敌方伤害类型分布的期望"挨打倍率"
func _expected_counter_inverse(armor_type: int, dmg_mix: Dictionary) -> float:
	var s: float = 0.0
	for k in dmg_mix.keys():
		s += float(dmg_mix[k]) * RtsCombat.counter_multiplier(int(k), armor_type)
	return s if s > 0.0 else 1.0


func _crit_avg() -> float:
	if _cfg == null:
		return 1.0
	return 1.0 + _cfg.crit_chance * (_cfg.crit_multiplier - 1.0)


func _effective_armor(u, d: UnitDef) -> float:
	var fac: RtsFaction = u.get("faction")
	return d.armor * RtsCombat.armor_mult(fac)


func _faction_of(units: Array) -> RtsFaction:
	for u in units:
		if u != null and is_instance_valid(u):
			var f = u.get("faction")
			if f != null:
				return f
	return null
