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
## 三层接口：
##   · `profile(units)`   一支队伍的"挨打画像"（护甲值 / 护甲类型分布 / 伤害类型分布）
##   · `value(def, 画像)` 一个兵在这张画像下的战力（DPS 与有效生命的几何平均）
##   · `ratio(a, b)`      两支部队的战力比（AI 的进攻/撤退判据都读它）
##
## 2C-3 新增（数值可变韧性 · 效果判定）：
##   · 派生量 `unit_dps / unit_effective_hp / unit_power / unit_cost` —— **全部 static、每次调用重算**
##   · 角色/标签谓词 `is_frontline / is_backline / has_tag / role_of`
##   · 理论值 `theory_combat_time / theory_output / theory_hp`
##   · 判定表 `classify_verdict`
##   · 定义查询（按能力找 id，AI 不再硬编码兵种/建筑 id）
##
## ★ 本文件**不缓存任何派生量**：Cfg 里的数值改了，下一次调用立刻反映。
##   旧版本在 `_init` 里缓存 `_cfg`，配置重建（Cfg._rebuild）后会读到旧对象 —— 已删除。

## 有效生命的几何平均指数：0.5 = 几何平均（DPS 与肉度同等重要）
const BALANCE_EXP: float = 0.5
## 战力的下限（防止"零攻击"的农民把整支部队的均值拉爆）
const MIN_VALUE: float = 1.0

## --- 理论战斗时间（C1 口径：金 + 木）---
## 每 1000 账面成本折算多少秒战斗时间。**待实测**：2C-3 先用 40 s，
## 参数敏感性用 `--verdict-base-sec=60` 对照（报告 §12）。
const THEORY_COST_UNIT: float = 1000.0
const THEORY_BASE_SEC: float = 40.0
## 理论时间倍率（预留：以后要按难度/兵种调，先固定 1.0）
const THEORY_TIME_SCALE: float = 1.0
## 理论输出的保守系数：近战卡位、远程被切、走到射程内都要时间，
## 实际打不满"纸面 DPS × 战斗时间"。
## 2026-11-03 2C-6 用户拍板 **0.55 → 0.4**（任务书 §1 覆盖表）。
## 前两轮的历史：2C-3 0.7（分母含走路）→ 2C-4 0.55（配"有效交战时间"）→ 2C-6 0.4
## （同时把分母从"全员纸面 DPS"改成"最近 3 s 真出过手的成员"，见 theory_output_recent）。
const THEORY_OUTPUT_COEF: float = 0.4

## --- 判定枚举（严格按 2C-3 判定表）---
const VD_ACHIEVED: String = "达成"
const VD_GOOD: String = "好"
const VD_FAIR: String = "一般"
const VD_BAD: String = "差"
const VD_UNDECIDED: String = "未判"

## 单波存活上限（秒）：超过强制收尾判"一般"并撤回（独立于战斗时间）
const TIME_LIMIT: float = 180.0
## 判定表的四个阈值
const VD_TIME_GOOD: float = 0.8
const VD_TIME_HALF: float = 0.5
const VD_OUT_LOW: float = 0.7
const VD_OUT_HIGH: float = 1.3
const VD_DMG_LOW: float = 0.4
const VD_DMG_HIGH: float = 0.9


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
		var raw_dps: float = unit_dps(d)
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
	return dps_against(def, enemy_profile, atk_mult)


## `dps` 的 static 版（配置回归 / 选兵权重用，不需要实例）
static func dps_against(def: UnitDef, enemy_profile: Dictionary, atk_mult: float = 1.0) -> float:
	if def == null or def.attack_damage <= 0.0 or def.attack_cooldown <= 0.0:
		return 0.0
	var counter: float = _expected_counter(def.attack_type, enemy_profile.get("armor_mix", {}))
	var mit: float = RtsCombat.armor_mitigation(float(enemy_profile.get("armor", 0.0)))
	var crit: float = crit_avg()
	var total: float = def.attack_damage * counter * (1.0 - mit) * crit * atk_mult
	return total / maxf(def.attack_cooldown, 0.1)


## 这个兵面对"敌方画像"能扛多少等效伤害
func ehp(def: UnitDef, enemy_profile: Dictionary, armor_mult: float = 1.0) -> float:
	return ehp_against(def, enemy_profile, armor_mult)


## `ehp` 的 static 版
static func ehp_against(def: UnitDef, enemy_profile: Dictionary, armor_mult: float = 1.0) -> float:
	if def == null:
		return 0.0
	var incoming: float = _expected_counter_inverse(def.armor_type, enemy_profile.get("dmg_mix", {}))
	var mit: float = RtsCombat.armor_mitigation(def.armor * armor_mult)
	return def.max_hp / maxf(incoming * (1.0 - mit), 0.05)


## 战力 = DPS 与有效生命的几何平均（量纲无关，方便横向比较）
func value(def: UnitDef, enemy_profile: Dictionary,
		atk_mult: float = 1.0, armor_mult: float = 1.0) -> float:
	return value_of(def, enemy_profile, atk_mult, armor_mult)


## `value` 的 static 版
static func value_of(def: UnitDef, enemy_profile: Dictionary,
		atk_mult: float = 1.0, armor_mult: float = 1.0) -> float:
	var a: float = dps_against(def, enemy_profile, atk_mult)
	var b: float = ehp_against(def, enemy_profile, armor_mult)
	return maxf(sqrt(a * b), MIN_VALUE)


## 每金战力：造这个兵"值不值"。
## 分母不是单纯的金币：木材、人口、建造时间都要折算进去，否则
## AI 会永远选"便宜但没用"的兵（比如 75 金的农民）。
func worth_per_cost(def: UnitDef, enemy_profile: Dictionary,
		atk_mult: float = 1.0, armor_mult: float = 1.0,
		cost_gold: float = 1.0, cost_wood: float = 1.5,
		cost_supply: float = 12.0, cost_time: float = 0.6) -> float:
	return worth_per_cost_of(def, enemy_profile, atk_mult, armor_mult,
			cost_gold, cost_wood, cost_supply, cost_time)


## `worth_per_cost` 的 static 版（选兵权重 / 配置回调用）
static func worth_per_cost_of(def: UnitDef, enemy_profile: Dictionary,
		atk_mult: float = 1.0, armor_mult: float = 1.0,
		cost_gold: float = 1.0, cost_wood: float = 1.5,
		cost_supply: float = 12.0, cost_time: float = 0.6) -> float:
	if def == null:
		return 0.0
	var cost: float = (float(def.gold_cost) * cost_gold
			+ float(def.wood_cost) * cost_wood
			+ float(def.food_cost) * cost_supply
			+ def.train_time * cost_time)
	return value_of(def, enemy_profile, atk_mult, armor_mult) / maxf(cost, 1.0)


## **选兵权重**（2C-3）：role 权重 × 每金战力 ÷ 同兵种过载惩罚。
## 抽成 static 的理由：配置回归要断言"改数值 → 该 role 的选兵权重上升"，
## 不能把公式抄在测试里（抄一遍等于测测试自己）。
static func selection_weight(def: UnitDef, role_weight: float, have: int,
		enemy_profile: Dictionary, atk_mult: float = 1.0, armor_mult: float = 1.0) -> float:
	if def == null or role_weight <= 0.0:
		return 0.0
	var worth: float = worth_per_cost_of(def, enemy_profile, atk_mult, armor_mult)
	var overload: float = 1.0 / (1.0 + 0.55 * float(maxi(have, 0)))
	return maxf(worth * role_weight * overload, 0.0001)


# ===========================================================================
# 派生量（2C-3 · 数值可变韧性）
#
# ★ 全部 static、只读传入的 def / 当前 Cfg，**不缓存**。
#   用户改单位数值、攻防关系、增删兵种后，下一次调用立刻是新值。
# ===========================================================================

## 纸面 DPS = 攻击 ÷ 攻击间隔（不含克制/护甲/暴击 —— 那是 `dps()` 的事）
static func unit_dps(def: UnitDef) -> float:
	if def == null:
		return 0.0
	return maxf(def.attack_damage, 0.0) / maxf(def.attack_cooldown, 0.1)


## 有效生命 = HP ÷ (1 − 护甲减免)。减免公式问 RtsCombat（唯一实现，
## 当前 = min(护甲 × Cfg.armor_reduction, Cfg.armor_reduction_cap)，即 0.06 / 0.72）。
static func unit_effective_hp(def: UnitDef) -> float:
	if def == null:
		return 0.0
	var mit: float = RtsCombat.armor_mitigation(float(def.armor))
	return maxf(def.max_hp, 0.0) / maxf(1.0 - mit, 0.05)


## 战力 = 几何平均(DPS, 有效生命)。零攻击单位落 MIN_VALUE，不返回 0/NaN。
static func unit_power(def: UnitDef) -> float:
	if def == null:
		return 0.0
	return maxf(sqrt(unit_dps(def) * unit_effective_hp(def)), MIN_VALUE)


## 克制倍率：直接问 Cfg 的 4×4 表（配置改了立刻生效）。
static func counter_multiplier(attack_type: int, target_armor_type: int) -> float:
	return RtsCombat.counter_multiplier(attack_type, target_armor_type)


## 一个单位的账面成本（C1）：金 + 木。农民/人口/建造时间都不计。
static func unit_cost(def: UnitDef) -> float:
	if def == null:
		return 0.0
	return float(def.gold_cost) + float(def.wood_cost)


## 一支部队的账面成本：按实际派出编制逐兵种求和（C1）。
## 传入的元素只需要有 `def` 字段（RtsUnit / 配置回归的 FakeUnit 都可以）。
static func wave_cost(units: Array) -> float:
	var total: float = 0.0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		var d: UnitDef = u.get("def")
		if d == null:
			continue
		total += unit_cost(d)
	return total


# ===========================================================================
# 角色 / 标签（2C-3）
# ===========================================================================

## 这个单位的战略角色。**优先读 def.role**；留空时按能力回退推断，
## 这样用户新增兵种忘了填 role 也不会被 AI 完全忽略（会在报告里标"推断"）。
static func role_of(def: UnitDef) -> StringName:
	if def == null:
		return &""
	if not String(def.role).is_empty():
		return def.role
	if def.kind == RtsConst.Kind.BUILDING:
		return &"defense" if def.attack_damage > 0.0 else &""
	if def.kind != RtsConst.Kind.UNIT:
		return &""
	if def.anim_set == RtsConst.AnimSet.WORKER:
		return &"worker"
	if def.attack_range >= 3.0:
		if def.attack_type == RtsConst.DamageType.MAGIC:
			return &"caster"
		return &"ranged"
	return &"frontline"


static func is_frontline(def: UnitDef) -> bool:
	return role_of(def) == &"frontline"


## 后排 = 远程 + 法师。siege 不在这里：当前唯一带 siege 标签的蒸汽重步兵
## 是 `role=frontline`（重甲近战），把它算后排会把"前排承伤比"读歪。
static func is_backline(def: UnitDef) -> bool:
	var r: StringName = role_of(def)
	return r == &"ranged" or r == &"caster"


static func has_tag(def: UnitDef, tag: StringName) -> bool:
	return def != null and def.tags.has(tag)


## 难度档的 role 权重。新配置读 `role_weights`；旧 .tres 只有 `composition`
## （兵种 id → 权重）时，按 def.role 折算成 role 权重 —— 老配置不会失效。
static func role_weights_of(diff: DifficultyDef) -> Dictionary:
	var out: Dictionary = {}
	if diff == null:
		return out
	if not diff.role_weights.is_empty():
		for k in diff.role_weights.keys():
			out[StringName(k)] = float(diff.role_weights[k])
		return out
	var cfg: GameConfig = _cfg()
	if cfg == null:
		return out
	for id in diff.composition.keys():
		var d: UnitDef = cfg.units.get(StringName(id), null)
		if d == null:
			continue
		var r: StringName = role_of(d)
		if String(r).is_empty():
			continue
		out[r] = float(out.get(r, 0.0)) + float(diff.composition[id])
	return out


## 当前配置下"可被 AI 选中的战斗兵种"：UNIT、非农民、**职能权重 > 0**。
## 2C-4 起配比只认 **承伤 / 输出**（词表·职能）；旧 frontline/ranged/… 从选兵逻辑退役。
## **不写任何 id** —— 用户新增一个职能=输出的兵（或没填职能靠能力回退）都能进池。
static func candidate_combat_ids(function_weights: Dictionary) -> Array:
	var out: Array = []
	var cfg: GameConfig = _cfg()
	if cfg == null:
		return out
	for id in cfg.units.keys():
		var d: UnitDef = cfg.units[id]
		if d == null or d.kind != RtsConst.Kind.UNIT:
			continue
		if role_of(d) == &"worker":
			continue
		if def_function_weight(d, function_weights) <= 0.0:
			continue
		out.append(StringName(id))
	out.sort_custom(func(a, b): return String(a) < String(b))
	return out


## 这个单位的**选兵职能权重** = 它拥有的职能里权重最高的那个（max，任务书 §4.5）。
## 职能来自卡（UnitCard.roles）；无卡或 roles 为空 → 能力回退兜底
## （有攻击+远 → 输出；有攻击+近 → 承伤；无攻击 → 辅助），是否回退用 `def_roles_is_fallback` 查。
static func def_function_weight(def: UnitDef, function_weights: Dictionary) -> float:
	if def == null or function_weights.is_empty():
		return 0.0
	var best: float = 0.0
	for r in def_roles(def):
		best = maxf(best, float(function_weights.get(StringName(r), 0.0)))
	return best


## 这个单位的职能列表（卡优先；无卡/空 roles 用能力回退，并可用 _fallback_warn 标记）
static func def_roles(def: UnitDef) -> Array:
	if def == null:
		return []
	var card: EntityCard = _card_of(def)
	if card != null and card is UnitCard and not (card as UnitCard).roles.is_empty():
		return (card as UnitCard).roles
	return _fallback_roles(def)


## 是否走了"能力回退兜底"（未填职能的兵）——调用方据此打报告警告
static func def_roles_is_fallback(def: UnitDef) -> bool:
	if def == null:
		return false
	var card: EntityCard = _card_of(def)
	return card == null or not (card is UnitCard) or (card as UnitCard).roles.is_empty()


static func _fallback_roles(def: UnitDef) -> Array:
	if def.attack_damage > 0.0:
		return [&"输出"] if def.attack_range >= 3.0 else [&"承伤"]
	return [&"辅助"]


## 卡索引（懒加载，**运行时 load 而非 preload** —— 单位表 preload 了本文件，preload 会成环）
static var _unit_table_script: Variant = null
static func _card_of(def: UnitDef) -> EntityCard:
	if _unit_table_script == null:
		_unit_table_script = load("res://代码/配置/单位表.gd")
	if _unit_table_script == null:
		return null
	return _unit_table_script.get_card(def.id)


# ===========================================================================
# 定义查询（按能力找 id —— AI 代码不再出现 footman/barracks/farm 这类字面量）
# ===========================================================================

static func unit_def(id: StringName) -> UnitDef:
	var cfg: GameConfig = _cfg()
	if cfg == null:
		return null
	return cfg.units.get(id, null)


static func all_unit_defs() -> Dictionary:
	var cfg: GameConfig = _cfg()
	return cfg.units if cfg != null else {}


static func worker_unit_id() -> StringName:
	var defs: Dictionary = all_unit_defs()
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d != null and d.kind == RtsConst.Kind.UNIT and role_of(d) == &"worker":
			return StringName(id)
	return &""


## 主基地：收金木（dropoff_kinds 空 = 全收）+ 提供人口 + 能训练农民。
static func main_base_id() -> StringName:
	var defs: Dictionary = all_unit_defs()
	var fallback: StringName = &""
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d == null or d.kind != RtsConst.Kind.BUILDING or not d.is_dropoff:
			continue
		if not d.dropoff_kinds.is_empty():
			continue
		if String(fallback).is_empty():
			fallback = StringName(id)
		if d.food_provided > 0 and d.trains.has(worker_unit_id()):
			return StringName(id)
	return fallback


## 人口建筑：提供人口、自己不产兵也不研究、不是交汇点。
## （workshop 也提供人口，但它 trains 非空 → 不会被当成农场。）
static func food_building_id() -> StringName:
	var defs: Dictionary = all_unit_defs()
	var fallback: StringName = &""
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d == null or d.kind != RtsConst.Kind.BUILDING or d.food_provided <= 0:
			continue
		if d.is_dropoff:
			continue
		if String(fallback).is_empty():
			fallback = StringName(id)
		if d.trains.is_empty() and d.researches.is_empty():
			return StringName(id)
	return fallback


## 产能建筑：`trains` 里至少有一个"职能权重 > 0 的非农民单位"（2C-4 职能口径）。
static func production_building_ids(function_weights: Dictionary) -> Array:
	var out: Array = []
	var defs: Dictionary = all_unit_defs()
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d == null or d.kind != RtsConst.Kind.BUILDING or d.trains.is_empty():
			continue
		var hit: bool = false
		for uid in d.trains:
			var ud: UnitDef = defs.get(uid, null)
			if ud == null or role_of(ud) == &"worker":
				continue
			if def_function_weight(ud, function_weights) > 0.0:
				hit = true
				break
		if hit:
			out.append(StringName(id))
	out.sort_custom(func(a, b): return String(a) < String(b))
	return out


## 主产能建筑：能训练"权重和最大"的那批兵的建筑（当前 = 兵营）。
## 用途：扩产能（数量 = max_army / UNITS_PER_BARRACKS）与"没有产能时先盖它"。
static func primary_producer_id(role_weights: Dictionary) -> StringName:
	var defs: Dictionary = all_unit_defs()
	var best: StringName = &""
	var best_score: float = -1.0
	for id in production_building_ids(role_weights):
		var d: UnitDef = defs.get(id, null)
		if d == null:
			continue
		var score: float = 0.0
		for uid in d.trains:
			var ud: UnitDef = defs.get(uid, null)
			if ud != null:
				score += def_function_weight(ud, role_weights)
		if score > best_score:
			best_score = score
			best = StringName(id)
	return best


## 防御塔：`need_attack=true` → 有攻击的箭塔；`false` → 只看的哨塔。
static func defense_tower_id(need_attack: bool) -> StringName:
	var defs: Dictionary = all_unit_defs()
	var best: StringName = &""
	var best_v: float = -1.0
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d == null or d.kind != RtsConst.Kind.BUILDING or role_of(d) != &"defense":
			continue
		if need_attack and d.attack_damage <= 0.0:
			continue
		if not need_attack and d.attack_damage > 0.0:
			continue
		var v: float = d.attack_damage if need_attack else d.sight_range
		if v > best_v:
			best_v = v
			best = StringName(id)
	return best


static func tagged_building_id(tag: StringName) -> StringName:
	var defs: Dictionary = all_unit_defs()
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d != null and d.kind == RtsConst.Kind.BUILDING and d.tags.has(tag):
			return StringName(id)
	return &""


static func research_building_id() -> StringName:
	var defs: Dictionary = all_unit_defs()
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d != null and d.kind == RtsConst.Kind.BUILDING and not d.researches.is_empty():
			return StringName(id)
	return &""


## 专收木材的交汇点（伐木场）。主基地 dropoff_kinds 为空（全收），不算。
static func wood_dropoff_id() -> StringName:
	var defs: Dictionary = all_unit_defs()
	for id in defs.keys():
		var d: UnitDef = defs[id]
		if d == null or d.kind != RtsConst.Kind.BUILDING or not d.is_dropoff:
			continue
		if d.dropoff_kinds.has(RtsConst.Harvest.WOOD):
			return StringName(id)
	return &""


# ===========================================================================
# 理论值（2C-3 · 四样判据）
# ===========================================================================

## (b) 理论战斗时间 = 部队总价值(金+木) ÷ 1000 × base_sec × 1.0
static func theory_combat_time(cost: float, base_sec: float = THEORY_BASE_SEC) -> float:
	return maxf(cost, 0.0) / THEORY_COST_UNIT * maxf(base_sec, 0.0) * THEORY_TIME_SCALE


## Σ(纸面 DPS × 数量)，编制用 {def.id: 数量}
static func comp_dps(comp: Dictionary) -> float:
	var s: float = 0.0
	var cfg: GameConfig = _cfg()
	if cfg == null:
		return s
	for id in comp.keys():
		var d: UnitDef = cfg.units.get(StringName(id), null)
		if d != null:
			s += unit_dps(d) * float(comp[id])
	return s


## Σ(有效生命 × 数量)
static func comp_hp(comp: Dictionary) -> float:
	var s: float = 0.0
	var cfg: GameConfig = _cfg()
	if cfg == null:
		return s
	for id in comp.keys():
		var d: UnitDef = cfg.units.get(StringName(id), null)
		if d != null:
			s += unit_effective_hp(d) * float(comp[id])
	return s


## (c) 理论输出 = Σ(dps × 数量) × 战斗时间 × coef
## **2C-6 起这是"全员口径"（all）**，只作对照用；默认走 theory_output_recent。
static func theory_output(comp: Dictionary, combat_time: float,
		coef: float = THEORY_OUTPUT_COEF) -> float:
	return comp_dps(comp) * maxf(combat_time, 0.0) * maxf(coef, 0.0)


## (c') 理论输出 B 口径（2C-6 默认）= Σ(dps × **最近出过手的成员数**) × 战斗时间 × coef
##
## 为什么改分母：2C-5 实测"时间达标"的 48 波里只有 1 波 output_eff 落进 [0.7,1.3]。
## 旧分母假设"全员全程在打"，可拆塔 meta 下远程常在射程外、近战在绕路、
## 大半成员整波 0 伤害 —— 分母恒定高估，output_eff 必然被压到窗口下沿。
##
## `recent` = {def.id: 最近 RECENT_ATTACK_WINDOW 秒内有过 combat_hit 的成员数}
## （按**实例**计数后按 def 聚合，不是"这个兵种有没有出现过"）。
static func theory_output_recent(recent: Dictionary, combat_time: float,
		coef: float = THEORY_OUTPUT_COEF) -> float:
	return comp_dps(recent) * maxf(combat_time, 0.0) * maxf(coef, 0.0)


## (d) 理论承伤能力 = Σ(有效生命 × 数量)
static func theory_hp(comp: Dictionary) -> float:
	return comp_hp(comp)


## 战斗时间 / 理论战斗时间（分母被 0.001 兜住，不产生 INF）
static func time_ratio(combat_time: float, theory_time: float) -> float:
	return maxf(combat_time, 0.0) / maxf(theory_time, 0.001)


## (A4) 判定表 —— 严格按 2C-3 规格实现，**不是**"综合评分"。
## 参数：
##   achieved      目标是否达成（五种目标各自的达成判据在外面算）
##   forced        是否触发 180 s 存活上限（强制收尾）
##   combat_time   实际战斗时间（首次接敌 → 收尾）
##   theory_time   理论战斗时间
##   output_eff    实际输出 ÷ max(理论输出, 1)
##   damage_ratio  实际承伤 ÷ max(理论承伤, 1)
##   survivors     收尾时还活着的成员数
##   strength      出发时的成员数（"差"的放宽基数：存活 ≤ ceil(出发数/3) 算崩）
static func classify_verdict(achieved: bool, forced: bool, combat_time: float,
		theory_time: float, output_eff: float, damage_ratio: float,
		survivors: int, strength: int) -> String:
	# 目标达成的优先级最高：打掉了就是打掉了，哪怕超时/全灭
	if achieved:
		return VD_ACHIEVED
	# 存活超过 180 s：强制收尾判"一般"（独立于战斗时间）
	if forced:
		return VD_FAIR
	var tr: float = time_ratio(combat_time, theory_time)
	if tr >= VD_TIME_GOOD:
		var out_ok: bool = output_eff >= VD_OUT_LOW and output_eff <= VD_OUT_HIGH
		var dmg_ok: bool = damage_ratio >= VD_DMG_LOW and damage_ratio <= VD_DMG_HIGH
		return VD_GOOD if (out_ok and dmg_ok) else VD_FAIR
	if tr >= VD_TIME_HALF:
		return VD_FAIR
	# 战斗时间不足一半：崩了 = 差（2C-4 放宽：存活 ≤ ceil(出发数/3) 即"崩"，不要求全灭）；
	# 还站得住 = 未判（**不许当"差"**）
	return VD_BAD if survivors <= bad_survivor_cap(strength) else VD_UNDECIDED


# ===========================================================================
# 2C-4 / 2C-5 判定层 / 决策层纯函数（配置回归直接断言，不抄公式）
# ===========================================================================

## 2C-5 P0-2：前 7 分钟（elapsed < 420 s）的军队规模目标。
##   target = 10 + 4×基地数 + 2×出兵建筑数；达到就停训（钱腾给建筑/科技）。
##   elapsed ≥ 420 s → 返回 **-1 = 解除**（只受钱/人口/队列限制）。
##   目标不低于防守下限（下限是"家里不空"的底线，目标不能比它低）。
const ARMY_TARGET_SEC: float = 420.0
const ARMY_TARGET_BASE: int = 10
const ARMY_TARGET_PER_BASE: int = 4
const ARMY_TARGET_PER_PRODUCER: int = 2


static func army_target_of(bases: int, producers: int, elapsed: float,
		defense_floor: int = 0) -> int:
	if elapsed >= ARMY_TARGET_SEC:
		return -1
	var t: int = ARMY_TARGET_BASE \
			+ ARMY_TARGET_PER_BASE * maxi(bases, 0) \
			+ ARMY_TARGET_PER_PRODUCER * maxi(producers, 0)
	return maxi(t, maxi(defense_floor, 0))


## 2C-5 P0-1：承伤分母。
##   mode = "targeted"（默认）—— **只算"曾作为 target 的成员"的有效生命**；
##   mode = "all"（2C-4 旧口径）—— 全程总有效生命，对照用。
## comp     = {def.id: 派出数量}
## targeted = {def.id: 曾作为 target 的成员数}（同一个成员被反复打只算 1）
##
## why：拆塔 meta 下大部分成员从没挨过打，分母却按全员算 →
## damage_ratio 长期 <0.2，"好"的 [0.4,0.9] 窗口永远进不去（2C-4 §6.1）。
static func damage_theory(comp: Dictionary, targeted: Dictionary = {},
		mode: String = "targeted") -> float:
	if mode == "all":
		return comp_hp(comp)
	var cfg: GameConfig = _cfg()
	if cfg == null:
		return 0.0
	var s: float = 0.0
	for id in comp.keys():
		var n: int = mini(int(comp[id]), int(targeted.get(id, 0)))
		if n <= 0:
			continue
		var d: UnitDef = cfg.units.get(StringName(id), null)
		if d != null:
			s += unit_effective_hp(d) * float(n)
	return s


## 2C-5 P1-4：建筑要不要修（血量比例低于阈值）。
## 阈值放 AI判定模式（--repair-hp-threshold 可覆盖），这里只做纯判定。
static func repair_needed(hp: float, max_hp: float, threshold: float) -> bool:
	if max_hp <= 0.0 or hp <= 0.0:
		return false
	return hp < max_hp * clampf(threshold, 0.0, 1.0)


## 2C-5 P1-5：达成归属的伤害占比 = 本波对目标造成的伤害 ÷ 目标总生命（近似，含过量伤害）。
static func goal_damage_ratio_of(damage_to_target: float, target_max_hp: float) -> float:
	if target_max_hp <= 0.0:
		return -1.0
	return maxf(damage_to_target, 0.0) / target_max_hp


## "差"的存活门槛：存活 ≤ ceil(出发数/3) 算崩（2C-4 用户确认，替换"全灭"）
static func bad_survivor_cap(strength: int) -> int:
	return ceili(float(maxi(strength, 0)) / 3.0)


## 有效交战时间的单条贡献：上一刀到这一刀的间隔 ≤ gap 才累计（断档切掉走路段）。
## prev_hit < 0 = 首刀（起表，贡献 0）。
static func hit_gap_contrib(prev_hit: float, now: float, gap: float) -> float:
	if prev_hit < 0.0 or now < prev_hit:
		return 0.0
	var dt: float = now - prev_hit
	return dt if dt <= maxf(gap, 0.0) else 0.0


## "好"比例护栏（只告警）：全部收尾记录里 verdict==好 的比例 > 50%
static func good_ratio_warning(good: int, total: int) -> bool:
	return total > 0 and float(good) / float(total) > 0.5


## 防守下限 = 5 + 2×基地数 + 1×出兵建筑数（2C-4 §4.1）
static func defense_floor_of(bases: int, producers: int) -> int:
	return 5 + 2 * maxi(bases, 0) + maxi(producers, 0)


## 攒大波保底留守 = ceil(下限 × 2/3)，不低于（家里不空）
static func bank_garrison_floor(defense_floor: int) -> int:
	return ceili(float(maxi(defense_floor, 0)) * 2.0 / 3.0)


## 常态出击人数：0.75（floor，10 派 7）且不超过"军队数 − 防守下限"（保底留守不动）
static func normal_push_n(army_n: int, defense_floor: int) -> int:
	var by_ratio: int = int(floor(float(maxi(army_n, 0)) * 0.75))
	var spare: int = maxi(army_n - maxi(defense_floor, 0), 0)
	return mini(by_ratio, spare)


## 攒大波出击人数：训练出来的全部战斗单位（含临时防守），只留保底 ceil(下限×2/3)
static func bank_push_n(army_n: int, defense_floor: int) -> int:
	return maxi(army_n - bank_garrison_floor(defense_floor), 0)


## 攒大波基准：上一次**实际派出**成本；无历史时退化 = 进场时可用成本 × 0.75（任务书 §3.5）
static func bank_baseline(last_sent_cost: float, entry_available_cost: float) -> float:
	return last_sent_cost if last_sent_cost > 0.0 else maxf(entry_available_cost, 0.0) * 0.75


## 攒大波门槛：当前可派战斗单位总成本 ≥ 1.5 × 基准（**不封顶**，P5 删除）
static func bank_ready(available_cost: float, baseline: float, mult: float = 1.5) -> bool:
	return available_cost >= maxf(baseline, 0.0) * maxf(mult, 1.0)


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

## 当前配置（每次现取，不缓存）。`--script` 模式下 Cfg 也是运行时才进树，
## 所以不能写成成员变量在 _init 里拿。
static func _cfg() -> GameConfig:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var node: Node = tree.root.get_node_or_null("Cfg")
	if node == null:
		return null
	return node.get("game") as GameConfig


## 攻击类型 vs 敌方护甲类型分布的期望克制倍率
static func _expected_counter(damage_type: int, armor_mix: Dictionary) -> float:
	var s: float = 0.0
	for k in armor_mix.keys():
		s += float(armor_mix[k]) * RtsCombat.counter_multiplier(damage_type, int(k))
	return s if s > 0.0 else 1.0


## 我方护甲类型 vs 敌方伤害类型分布的期望"挨打倍率"
static func _expected_counter_inverse(armor_type: int, dmg_mix: Dictionary) -> float:
	var s: float = 0.0
	for k in dmg_mix.keys():
		s += float(dmg_mix[k]) * RtsCombat.counter_multiplier(int(k), armor_type)
	return s if s > 0.0 else 1.0


## 暴击期望倍率。**每次读 Cfg**（旧版缓存 _cfg，Cfg 重建后会读到旧对象）。
static func crit_avg() -> float:
	var cfg: GameConfig = _cfg()
	if cfg == null:
		return 1.0
	return 1.0 + cfg.crit_chance * (cfg.crit_multiplier - 1.0)


func _crit_avg() -> float:
	return crit_avg()


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
