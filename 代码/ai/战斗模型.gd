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

## 2C-5 P0-2 / 2C-7 P1：军队规模目标。
##   target = min(10 + 4×基地数 + 2×出兵建筑数, 人口上限 ÷ 2 − 1)
##   · 前 7 分钟（elapsed < 420 s）：两者取小，达到就停训（钱腾给建筑/科技）；
##   · elapsed ≥ 420 s：**不再解除**，直接取"人口上限允许的最大值"
##     （2C-7 用户拍板：2C-6 的 -1 解除让 420 s 后军队仍被钱/人口卡在 15~16，看不出目标）；
##   · 目标不低于防守下限（下限是"家里不空"的底线，钱可以再赚，家空了就没了）。
##
## `pop_cap` = 阵营 food_cap（大本营 + 农场）。传 0 = **不约束**（`--army-pop-cap=off`
## 的 2C-6 对照局走这条，返回值 -1 = 无上限）。
const ARMY_TARGET_SEC: float = 420.0
const ARMY_TARGET_BASE: int = 10
const ARMY_TARGET_PER_BASE: int = 4
const ARMY_TARGET_PER_PRODUCER: int = 2
## 每个战斗单位占的人口（步兵/弩兵 2，法师 3 —— 取 2 是"最便宜的兵"口径，用户拍板）
const ARMY_POP_PER_UNIT: int = 2
## 留 1 个人口余量，防止目标刚好等于上限时"排到一半卡住"
const ARMY_POP_RESERVE: int = 1


## 人口上限允许的最大军队规模 = floor(pop_cap / 2) − 1（不会为负）
static func army_pop_limit(pop_cap: int) -> int:
	return maxi(int(pop_cap) / ARMY_POP_PER_UNIT - ARMY_POP_RESERVE, 0)


static func army_target_of(bases: int, producers: int, elapsed: float,
		defense_floor: int = 0, pop_cap: int = 0) -> int:
	var formula: int = ARMY_TARGET_BASE \
			+ ARMY_TARGET_PER_BASE * maxi(bases, 0) \
			+ ARMY_TARGET_PER_PRODUCER * maxi(producers, 0)
	var floor_v: int = maxi(defense_floor, 0)
	if pop_cap <= 0:
		# 不约束人口：2C-6 口径（420 s 后解除）
		if elapsed >= ARMY_TARGET_SEC:
			return -1
		return maxi(formula, floor_v)
	var limit: int = army_pop_limit(pop_cap)
	var t: int = limit if elapsed >= ARMY_TARGET_SEC else mini(formula, limit)
	return maxi(t, floor_v)


## 2C-6 P1：人口预判 —— C 条件（占用率 > ratio，默认 70%）。
## cap=0（还没人口建筑）视为"必须建"，否则除零会返回 false 把 AI 卡死。
static func pop_occupied_over(used: int, cap: int, ratio: float = 0.7) -> bool:
	if cap <= 0:
		return true
	return float(maxi(used, 0)) / float(cap) > clampf(ratio, 0.0, 1.0)


## 2C-6 P1：人口预判 —— A 条件（余量 < 未来 60 s 训练量 × buffer，默认 2 倍）。
static func farm_headroom_low(headroom: int, predicted_60s: float, buffer: float = 2.0) -> bool:
	return float(headroom) < maxf(predicted_60s, 0.0) * maxf(buffer, 0.0)


## 2C-6 P1：未来 60 s 预计训练兵数 = 兵营数 × 60 ÷ 平均训练时间（训练时间下限 1 s，不除零）。
static func predicted_trainees_60s(producers: int, avg_train_time: float) -> float:
	if producers <= 0:
		return 0.0
	return float(producers) * 60.0 / maxf(avg_train_time, 1.0)


## 2C-6 P2：兵营目标座数 —— 固定 ≥2；军队 >16 加到 3；上限 3。
static func barracks_want_of(army_n: int, min_n: int = 2,
		step_army: int = 16, at_step: int = 3, max_n: int = 3) -> int:
	var want: int = maxi(min_n, 1)
	if army_n > step_army:
		want = maxi(want, at_step)
	return clampi(want, 1, maxi(max_n, 1))


## 2C-7 P0：**非工位**农民的采金人数目标（采金 8 : 采木 3 按比例，人少时同比缩）。
## 满编 11 → 8；6 → 4（2 采木）；3 → 2。工位不参与这个分配（它默认砍树）。
##
## 2C-8 起这条只服务 `--builder-slot=off/legacy` 的对照局；默认口径换成
## `peasant_gold_want_dynamic()`（采金 = min(8, N − 工位数)，余量全给采木）。
static func peasant_gold_want(non_builder: int, gold_target: int = 8,
		wood_target: int = 3) -> int:
	var n: int = maxi(non_builder, 0)
	var gold: int = maxi(gold_target, 0)
	var sum: int = maxi(gold + maxi(wood_target, 0), 1)
	var want: int = int(round(float(n) * float(gold) / float(sum)))
	return clampi(want, 0, gold)


# ---------------------------------------------------------------------------
# 2C-8 P0：农民工位**动态数量**（用户拍板：max(2, ceil(N/6))，随农民总数实时重算）
# ---------------------------------------------------------------------------

## 每多少个农民配 1 个建造/修理工位
const BUILDER_PER_PEASANT: float = 6.0
## 工位下限：2（1 个建造 + 1 个修理）。农民少于 2 时按实际人数封顶。
const BUILDER_MIN: int = 2

## 工位目标数 = max(2, ceil(农民总数 / 6))。
## N=0 → 0（没有农民就没有工位）；N=1..6 → 2；N=12 → 2；N=13..18 → 3。
## ★ 这是**目标**，不是实际能派出来的人数：实际工位 = min(目标, 存活农民数)。
static func builder_count_for(peasant_total: int) -> int:
	var n: int = maxi(peasant_total, 0)
	if n <= 0:
		return 0
	return maxi(BUILDER_MIN, ceili(float(n) / BUILDER_PER_PEASANT))


## 同时建造数上限 = 工位数 − 1（**至少留 1 个工位给修理**）。
## 用**目标工位数**而不是"当前实际指派数"：开局只有 1 个农民时仍然允许他建造
## （否则第 1 分钟永远盖不出兵营），但工位补齐后上限自然回到 N−1。
static func builder_build_limit(builder_count: int) -> int:
	return maxi(maxi(builder_count, 0) - 1, 0)


## 2C-8 P0：采金人数 = min(软上限, 农民总数 − 工位数)，其余全去采木。
## 满编 12 + 2 工位 → 采金 8 / 采木 2；15 + 3 工位 → 8 / 4；6 + 2 工位 → 4 / 0。
## 与 `peasant_gold_want()` 的差别：**先扣工位，再用软上限截断**，不做比例缩放。
static func peasant_gold_want_dynamic(peasant_total: int, builder_count: int,
		gold_cap: int = 8) -> int:
	var n: int = maxi(peasant_total, 0)
	var b: int = clampi(builder_count, 0, n)
	var cap: int = maxi(gold_cap, 0)
	return clampi(n - b, 0, cap)


# ---------------------------------------------------------------------------
# 2C-8 P1：军队目标 —— 三段时间 + 每 2 分钟全项 +1（不再与人口挂钩）
# ---------------------------------------------------------------------------

## 第一段/第二段的分界（秒）：480 s 前 12+3B+P，480~600 s 13+4B+2P
const ARMY_TARGET_2C8_SEC1: float = 480.0
## 第三段起点（秒）：≥600 s 起每 120 s 全项 +1
const ARMY_TARGET_2C8_SEC2: float = 600.0
const ARMY_TARGET_2C8_STEP: float = 120.0

## 2C-8 军队目标（**无人口约束**，由人口卡训练自然兜住）：
##   t < 480        ：12 + 3B + 1P
##   480 ≤ t < 600  ：13 + 4B + 2P
##   t ≥ 600        ：(14+n) + (5+n)B + (3+n)P，n = floor((t − 600) / 120)
## 调用方再与防守下限取 max（目标不低于防守下限）。
## 为什么时间分段而不是一口气给大数：早期给 20+ 会让 AI 把起始金币全砸进兵营，
## 农场/科技全饿死；分段让"目标随经济一起长"，600 s 后每 2 分钟才有新增胃口。
static func army_target_2c8(bases: int, producers: int, elapsed: float) -> int:
	var b: int = maxi(bases, 0)
	var p: int = maxi(producers, 0)
	if elapsed < ARMY_TARGET_2C8_SEC1:
		return 12 + 3 * b + p
	if elapsed < ARMY_TARGET_2C8_SEC2:
		return 13 + 4 * b + 2 * p
	var n: int = maxi(int(floor((elapsed - ARMY_TARGET_2C8_SEC2) / ARMY_TARGET_2C8_STEP)), 0)
	return (14 + n) + (5 + n) * b + (3 + n) * p


## 2C-7 P5：**与窗口无关**的原始承伤比 = 实际承伤 ÷ Σ(全员有效生命)。
##
## 与 `damage_ratio` 的唯一差别是**分母**：targeted 只算"曾作为 target 的成员"，
## raw 算"这一波派出去的所有人的有效生命"。于是它不受"谁被打"影响，
## 才能回答"[0.4,0.9] 这个窗口本身放对了吗"——**只给数据，不改窗口**。
static func raw_damage_ratio(dmg_in: float, hp_all: float) -> float:
	return maxf(dmg_in, 0.0) / maxf(hp_all, 1.0)


## 2C-7 P5：窗口对照矩阵的一格 —— 落在 [lo, hi] 的样本比例（0~1）。
## values 里 < 0 的样本（未记录）跳过，不进分母。
static func window_hit_ratio(values: Array, lo: float, hi: float) -> float:
	var n: int = 0
	var hit: int = 0
	for v in values:
		var x: float = float(v)
		if x < 0.0:
			continue
		n += 1
		if x >= lo and x <= hi:
			hit += 1
	return 0.0 if n <= 0 else float(hit) / float(n)


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
## **2C-6 起不用它做默认判据**（70% 线在 10~15 min 局结构性不可达，见 2C-5 §6.6）；
## 保留只为 old 对照与回归表。
static func repair_needed(hp: float, max_hp: float, threshold: float) -> bool:
	if max_hp <= 0.0 or hp <= 0.0:
		return false
	return hp < max_hp * clampf(threshold, 0.0, 1.0)


## 2C-6 P3：固定掉血口径 —— 掉的血 ≥ deficit 就修（默认 200 HP）。
## 好处：对小建筑更敏感（农场 450 掉 200 = 44%）、对大建筑不苛刻（大本营 1600 掉 200 = 12.5%）；
## 比例口径反过来：小建筑要掉 135 才到 70%，大本营要掉 480 —— 于是 10 min 局里永远是 0 次。
static func repair_deficit(hp: float, max_hp: float) -> float:
	if max_hp <= 0.0 or hp <= 0.0:
		return 0.0
	return maxf(max_hp - hp, 0.0)


static func repair_needed_deficit(hp: float, max_hp: float, deficit: float) -> bool:
	if max_hp <= 0.0 or hp <= 0.0:
		return false
	return repair_deficit(hp, max_hp) >= maxf(deficit, 0.0)


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
# 2C-9 · 三条线部门化的诉求结构 + 动作级仲裁（纯函数）
#
# 为什么放在本文件：它和判定表一样是"结构 + 纯函数"，不放场景、不读时间；
# 配置回归可以直接断言排序/扣减/驳回，不用起一局。
#
# 用户拍板的三条线（不再讨论）：
#   运营线 —— 经济/建造/修理/训练（花金币木材，训练产出兵）
#   战斗线 —— 摧毁/防守/交战（不花金币，抢兵力；"判定→攒波→换目标→出击"闭环不重写）
#   扩展线 —— 侦查/巡逻/建塔/分基地（侦查巡逻抢兵力，建塔分基地抢金币木材）
# ===========================================================================

const DEP_OPS: String = "运营线"
const DEP_COMBAT: String = "战斗线"
const DEP_EXPAND: String = "扩展线"
const DEP_SOURCES: Array[String] = [DEP_OPS, DEP_COMBAT, DEP_EXPAND]

const ACT_TRAIN: String = "训练"
const ACT_BUILD: String = "建造"
const ACT_REPAIR: String = "修理"
const ACT_PUSH: String = "出击"
const ACT_DEFEND: String = "防守"
const ACT_SCOUT: String = "侦查"
const ACT_PATROL: String = "巡逻"
const ACT_TOWER: String = "建塔"
const ACT_EXPAND: String = "建分基地"
const ACT_TYPES: Array[String] = [
	ACT_TRAIN, ACT_BUILD, ACT_REPAIR, ACT_PUSH, ACT_DEFEND,
	ACT_SCOUT, ACT_PATROL, ACT_TOWER, ACT_EXPAND,
]

## 驳回原因枚举（用户拍板：**只带枚举，不带自然语言解释**）
const RJ_NONE: String = ""
const RJ_GOLD: String = "金币不足"
const RJ_WOOD: String = "木材不足"
const RJ_TROOP: String = "兵力不足"
const RJ_OUTBID: String = "被更高分压后"
const RJ_COND: String = "条件不满足"
const RJ_DONE: String = "本周期已执行"
const RJ_REASONS: Array[String] = [
	RJ_GOLD, RJ_WOOD, RJ_TROOP, RJ_OUTBID, RJ_COND, RJ_DONE,
]

## 诉求结构的**必带字段**（第 3.1 节）。回归按这张表断言"一条都不能少"。
## `可执行` 是本轮实现里额外汇入的一个内部字段（部门自己判不动作为 false），
## 不改变用户拍板的字段表 —— 它只是让"条件不满足"这条枚举有出处。
const DEMAND_FIELDS: Array[String] = [
	"来源线", "动作类型", "目标", "金币成本", "木材成本", "兵力占用",
	"可被征用", "诉求分", "依据", "驳回原因",
]

## 仲裁周期（秒）：L2 诉求列表每 2 s 全量重建，不跨周期累积
const DEPT_CYCLE_SEC: float = 2.0
## 修理诉求分的刻度：掉血 / 200（200 是 2C-6 起冻结的修理线，**不是新阈值**）
const DEMAND_REPAIR_SCALE: float = 200.0
## 兵力比 → 出击诉求分的刻度（1.3 的兵力比 ≈ 6.5 分，落在"急建农场 10 分"之下）
const DEMAND_PUSH_SCALE: float = 5.0
## 威胁数量 → 防守诉求分的刻度（1 个压家敌人 = 20 分，最高的那一档）
const DEMAND_DEFEND_SCALE: float = 20.0
## 缺人口紧迫：急建通道（headroom<4 或占用>90%）
const DEMAND_FARM_URGENT: float = 10.0
## 缺人口紧迫：不急通道（占用>70% / 60 s 训练量×2）
const DEMAND_FARM_NORMAL: float = 1.0
## 兵营紧迫：一座产能建筑都没有（先解决"有没有兵营"）
const DEMAND_BARRACKS_URGENT: float = 3.0
## 兵营紧迫：已有产能，只是座数不够
const DEMAND_BARRACKS_NORMAL: float = 1.0


## 系数卡（`代码/配置/卡/AI诉求系数.tres`）。**懒加载、不缓存值**：
## 卡里的数改了，下一次调用立刻生效（与"卡是唯一真相源"同一口径）。
static var _demand_card: Resource = null
static var _demand_card_tried: bool = false


static func demand_card() -> Resource:
	if not _demand_card_tried:
		_demand_card_tried = true
		_demand_card = load("res://代码/配置/卡/AI诉求系数.tres")
	return _demand_card


## 读一个系数；卡缺失/字段缺失一律回落 1.0（**绝不静默变成 0**）
static func demand_coef(name: String, fallback: float = 1.0) -> float:
	var c: Resource = demand_card()
	if c == null:
		return fallback
	var v = c.get(name)
	if v == null:
		return fallback
	return float(v)


## 造一条诉求。**十个必带字段一个都不少**，另加内部 `可执行` 与执行闭包。
static func demand_make(source: String, action: String, target: String,
		gold: int, wood: int, troops: int, requisitionable: bool,
		score: float, basis: String, ready: bool = true,
		exec: Callable = Callable()) -> Dictionary:
	return {
		"来源线": source,
		"动作类型": action,
		"目标": target,
		"金币成本": maxi(gold, 0),
		"木材成本": maxi(wood, 0),
		"兵力占用": maxi(troops, 0),
		"可被征用": requisitionable,
		"诉求分": score,
		"依据": basis,
		"驳回原因": RJ_NONE,
		# --- 内部字段（不进用户字段表，只服务执行与归因）---
		"可执行": ready,
		"执行": exec,
	}


## 一条诉求是否结构合法（字段齐全 + 枚举合法 + 数值非负）
static func demand_valid(d) -> bool:
	if not (d is Dictionary):
		return false
	var dd: Dictionary = d
	for f in DEMAND_FIELDS:
		if not dd.has(f):
			return false
	if not DEP_SOURCES.has(String(dd["来源线"])):
		return false
	if not ACT_TYPES.has(String(dd["动作类型"])):
		return false
	if int(dd["金币成本"]) < 0 or int(dd["木材成本"]) < 0 or int(dd["兵力占用"]) < 0:
		return false
	if not (dd["可被征用"] is bool):
		return false
	if not is_finite(float(dd["诉求分"])):
		return false
	return true


## 动作级仲裁（P0 核心，纯函数）。
##
## 规则（用户拍板，逐条对应 §3.2/§3.3）：
##   1. 所有诉求按 `诉求分` 从高到低排序；**同分按部门提交顺序**（稳定，不掷骰）。
##   2. 依次检查资源够不够：够 → 记执行并扣减/锁定；不够 → 跳过并填 `驳回原因`。
##   3. "一起做"：金币木材兵力都够两个动作 → 同周期都执行（不限额）。
##   4. 同部门多诉求：主部门按分数重判（不额外加权），不预设部门优先级。
##   5. 驳回原因：**周期开始时就不够** → 金币/木材/兵力不足；
##      **周期开始时够、被更高分吃掉了** → 被更高分压后（这条区分是报告要看的）。
##   6. 同 (部门, 动作, 目标) 在一次周期里只执行一次 → 后来者填 `本周期已执行`。
##   7. `可执行=false`（部门自己判"条件不成立"，如没有可建位置）→ `条件不满足`。
##
## 返回 {执行:[...], 驳回:[...], 金币余, 木材余, 兵力余, 总额}
static func arbitrate(demands: Array, gold: int, wood: int, troops: int) -> Dictionary:
	var g: int = maxi(gold, 0)
	var w: int = maxi(wood, 0)
	var t: int = maxi(troops, 0)
	var g0: int = g
	var w0: int = w
	var t0: int = t
	var order: Array = []
	for i in range(demands.size()):
		var d = demands[i]
		if d is Dictionary:
			order.append({"i": i, "s": float((d as Dictionary).get("诉求分", 0.0))})
	order.sort_custom(func(a, b):
		var sa: float = float(a["s"])
		var sb: float = float(b["s"])
		if absf(sa - sb) > 0.000001:
			return sa > sb
		return int(a["i"]) < int(b["i"]))
	var done: Array = []
	var rej: Array = []
	var seen: Dictionary = {}
	for e in order:
		var d2: Dictionary = demands[int(e["i"])]
		var key: String = "%s|%s|%s" % [
			String(d2.get("来源线", "")), String(d2.get("动作类型", "")),
			String(d2.get("目标", ""))]
		d2["驳回原因"] = RJ_NONE
		if seen.has(key):
			d2["驳回原因"] = RJ_DONE
			rej.append(d2)
			continue
		if not bool(d2.get("可执行", true)):
			d2["驳回原因"] = RJ_COND
			rej.append(d2)
			continue
		var ng: int = int(d2.get("金币成本", 0))
		var nw: int = int(d2.get("木材成本", 0))
		var nt: int = int(d2.get("兵力占用", 0))
		var lack: Array = []
		if g < ng:
			lack.append("g")
		if w < nw:
			lack.append("w")
		if t < nt:
			lack.append("t")
		if not lack.is_empty():
			# 周期开始时够不够？全够 = 被更高分的诉求吃掉了
			var outbid: bool = true
			if lack.has("g") and g0 < ng:
				outbid = false
			if lack.has("w") and w0 < nw:
				outbid = false
			if lack.has("t") and t0 < nt:
				outbid = false
			if outbid:
				d2["驳回原因"] = RJ_OUTBID
			elif lack.has("g"):
				d2["驳回原因"] = RJ_GOLD
			elif lack.has("w"):
				d2["驳回原因"] = RJ_WOOD
			else:
				d2["驳回原因"] = RJ_TROOP
			rej.append(d2)
			continue
		g -= ng
		w -= nw
		t -= nt
		seen[key] = true
		done.append(d2)
	return {
		"执行": done, "驳回": rej,
		"金币余": g, "木材余": w, "兵力余": t,
		"总额": demands.size(),
	}


## 兵力预留制的**扣减顺序**（用户拍板）：防守锁定 > 临时防守可征用 > 空闲。
##
## `defense_locked` 是已经预留给"家里不空"的那部分（本次仲裁**不可动用**）；
## 剩下的先从"临时防守（可被征用）"扣，不够再扣空闲。
## 返回 {够, 临时防守, 空闲, 可用, 防守锁定}
static func troop_allocate(need: int, defense_locked: int,
		temp_defense: int, idle: int) -> Dictionary:
	var n: int = maxi(need, 0)
	var dl: int = maxi(defense_locked, 0)
	var td: int = maxi(temp_defense, 0)
	var idl: int = maxi(idle, 0)
	var avail: int = td + idl
	if n > avail:
		return {"够": false, "临时防守": 0, "空闲": 0,
			"可用": avail, "防守锁定": dl}
	var from_temp: int = mini(n, td)
	return {"够": true, "临时防守": from_temp, "空闲": n - from_temp,
		"可用": avail, "防守锁定": dl}


## 诉求分：训练 = 缺口 × (1 + 威胁 × 威胁系数) × 缺口系数
static func demand_score_train(gap: int, threat_n: int) -> float:
	var g: float = maxf(float(gap), 0.0)
	var th: float = maxf(float(threat_n), 0.0)
	return g * (1.0 + th * demand_coef("训练_威胁系数")) * demand_coef("训练_缺口系数")


## 诉求分：建造 = 农场缺口 × 缺人口紧迫 + 兵营缺口 × 兵营紧迫（各自带系数）
static func demand_score_build(farm_gap: int, farm_urgent: float,
		barracks_gap: int, barracks_urgent: float) -> float:
	return maxf(float(farm_gap), 0.0) * maxf(farm_urgent, 0.0) \
			* demand_coef("建造_农场缺口系数") * demand_coef("建造_农场紧迫系数") \
			+ maxf(float(barracks_gap), 0.0) * maxf(barracks_urgent, 0.0) \
			* demand_coef("建造_兵营缺口系数") * demand_coef("建造_兵营紧迫系数")


## 诉求分：修理 = 掉血 / 200（保持 2C-6/2C-8 的"掉血多优先"排序）
static func demand_score_repair(deficit: float) -> float:
	var scale: float = demand_coef("刻度_修理", DEMAND_REPAIR_SCALE)
	return maxf(deficit, 0.0) / maxf(scale, 1.0) * demand_coef("修理_掉血系数")


## 诉求分：出击 = 兵力比 × 5（"保持战斗线现有波次判定输出"的可量化代理）
static func demand_score_push(army_ratio: float) -> float:
	var scale: float = demand_coef("刻度_出击", DEMAND_PUSH_SCALE)
	return clampf(army_ratio, 0.0, 8.0) * scale * demand_coef("出击_兵力比系数")


## 诉求分：防守 = 压家敌人数量 × 20
static func demand_score_defend(threat_n: int) -> float:
	var scale: float = demand_coef("刻度_防守", DEMAND_DEFEND_SCALE)
	return maxf(float(threat_n), 0.0) * scale * demand_coef("防守_威胁系数")


## 紧迫刻度：急建 / 不急 / 无产能 / 扩建（全部从卡里读，缺省回落常量）
static func demand_scale(key: String) -> float:
	match key:
		"农场急建":
			return demand_coef("刻度_农场急建", DEMAND_FARM_URGENT)
		"农场不急":
			return demand_coef("刻度_农场不急", DEMAND_FARM_NORMAL)
		"兵营无产能":
			return demand_coef("刻度_兵营无产能", DEMAND_BARRACKS_URGENT)
		"兵营扩建":
			return demand_coef("刻度_兵营扩建", DEMAND_BARRACKS_NORMAL)
		_:
			return 1.0


## 诉求分：固定值（侦查 / 巡逻 / 建塔 / 分基地）
static func demand_score_fixed(kind: String) -> float:
	return maxf(demand_coef(kind + "_固定分"), 0.0)


# ===========================================================================
# 2C-10 · 人口压力 / 可用兵力 / 判定表诊断（纯函数；回归与 bench 共用同一套口径）
# ===========================================================================

## 人口占用率 = (当前人口占用 + 在训人口) / 当前人口上限。
## ★ 必须含在训（food_reserved）：刚点兵就按"还有空位"算，会让 90% 触发整整晚一轮。
static func pop_pressure(used: int, reserved: int, cap: int) -> float:
	if cap <= 0:
		return 0.0
	return float(maxi(used, 0) + maxi(reserved, 0)) / float(cap)


## 70% 人口压力动态系数（**只乘农场建造诉求分**，其余诉求一律不动）。
##   r ≤ 阈值 → 1.0；r > 阈值 → 1 + k × min(1, (r−阈值)/(1−阈值))，上限 1+k。
## 阈值/k 从第 18 张系数卡第 14、15 项读，缺卡回落 0.70 / 2.0。
static func farm_pressure_factor(rate: float) -> float:
	var thr: float = clampf(demand_coef("人口压力_阈值", 0.70), 0.0, 0.99)
	var k: float = maxf(demand_coef("人口压力_k", 2.0), 0.0)
	if not is_finite(rate) or rate <= thr:
		return 1.0
	var span: float = maxf(1.0 - thr, 0.0001)
	return clampf(1.0 + k * minf((rate - thr) / span, 1.0), 1.0, 1.0 + k)


## P0-A：可用兵力**只扣一次**防守下限（现役 − 下限 − 已锁，且不为负）。
## 仲裁池用 raw（不扣下限），本函数只做"账面可用兵力"口径与回归断言。
static func troop_available(army_n: int, defense_floor: int, locks: int) -> int:
	return maxi(maxi(army_n, 0) - maxi(defense_floor, 0) - maxi(locks, 0), 0)


## 2C-10 §6：可被征用消费（纯函数）—— 把"临时防守 / 巡逻 / 侦查"三种短租约锁
## 折成这次攒大波能征回来的兵力数。**wave 锁不可征用**（正在出击的兵不能自征）。
## 返回 {"可征用": n, "释放键": [...]}，不改传入的 locks（由调用方按键释放）。
static func requisition_quota(locks: Dictionary) -> Dictionary:
	var n: int = 0
	var keys: Array = []
	for k in locks.keys():
		var d = locks[k]
		if not (d is Dictionary):
			continue
		var kind: String = String((d as Dictionary).get("k", ""))
		if kind == "temp_defense" or kind == "patrol" or kind == "scout":
			keys.append(k)
			n += int((d as Dictionary).get("n", 0))
	return {"可征用": n, "释放键": keys}


## B 诊断：四样判据的**原始输入值 + 档位边界 + 到最近边界的距离 + 落档**。
## 只诊断，不重算判定、不改任何窗口/分母/系数。
static func judge_diag(rec: Dictionary) -> Dictionary:
	var tr: float = time_ratio(float(rec.get("combat_time", 0.0)),
			float(rec.get("theory_time", 0.0)))
	var oe: float = float(rec.get("output_eff", 0.0))
	var dr: float = float(rec.get("damage_ratio", 0.0))
	var surv: int = int(rec.get("survivors", 0))
	var cap4: int = bad_survivor_cap(int(rec.get("strength", 0)))
	var bins: Dictionary = judge_bins(rec)
	var d1: float = minf(absf(tr - VD_TIME_HALF), absf(tr - VD_TIME_GOOD))
	var d2: float = minf(absf(oe - VD_OUT_LOW), absf(oe - VD_OUT_HIGH))
	var d3: float = minf(absf(dr - VD_DMG_LOW), absf(dr - VD_DMG_HIGH))
	return {
		"判据1": {"值": snappedf(tr, 0.001), "边界": [VD_TIME_HALF, VD_TIME_GOOD],
			"边界距离": snappedf(d1, 0.001), "档": String(bins["判据1"])},
		"判据2": {"值": snappedf(oe, 0.001), "边界": [VD_OUT_LOW, VD_OUT_HIGH],
			"边界距离": snappedf(d2, 0.001), "档": String(bins["判据2"])},
		"判据3": {"值": snappedf(dr, 0.001), "边界": [VD_DMG_LOW, VD_DMG_HIGH],
			"边界距离": snappedf(d3, 0.001), "档": String(bins["判据3"])},
		"判据4": {"值": surv, "边界": [cap4],
			"边界距离": absf(float(surv) - float(cap4)), "档": String(bins["判据4"])},
	}


# ---------------------------------------------------------------------------
# 2C-9 · 判定表**分布**（P1）：把四样判据各自落到 达成/好/一般/差/未判
#
# ★ 这里**不重算判定**，只是把 `classify_verdict` 已经在用的同一批阈值
#   （0.8 / 0.5、0.7~1.3、0.4~0.9、ceil(出发/3)）分别套到每一条判据上，
#   目的是回答"哪一条判据最常给出 未判/一般" —— 不改窗口、不改权重、不改判定结果。
# ---------------------------------------------------------------------------
static func judge_bins(rec: Dictionary) -> Dictionary:
	var achieved: bool = bool(rec.get("goal_achieved", false))
	var forced: bool = bool(rec.get("forced_timeout", false))
	var tr: float = time_ratio(float(rec.get("combat_time", 0.0)),
			float(rec.get("theory_time", 0.0)))
	var oe: float = float(rec.get("output_eff", 0.0))
	var dr: float = float(rec.get("damage_ratio", 0.0))
	var surv: int = int(rec.get("survivors", 0))
	var strength: int = int(rec.get("strength", 0))
	var cap: int = bad_survivor_cap(strength)
	var b1: String = VD_UNDECIDED
	var b2: String = VD_FAIR
	var b3: String = VD_FAIR
	var b4: String = VD_GOOD if surv > cap else VD_BAD
	if achieved:
		b1 = VD_ACHIEVED
		b2 = VD_ACHIEVED
		b3 = VD_ACHIEVED
		b4 = VD_ACHIEVED
	else:
		if forced:
			b1 = VD_FAIR
		elif tr >= VD_TIME_GOOD:
			b1 = VD_GOOD
		elif tr >= VD_TIME_HALF:
			b1 = VD_FAIR
		else:
			b1 = VD_BAD if surv <= cap else VD_UNDECIDED
		b2 = VD_GOOD if (oe >= VD_OUT_LOW and oe <= VD_OUT_HIGH) else VD_FAIR
		b3 = VD_GOOD if (dr >= VD_DMG_LOW and dr <= VD_DMG_HIGH) else VD_FAIR
	return {"判据1": b1, "判据2": b2, "判据3": b3, "判据4": b4}


## 把一批波次记录按"某一判据"的五个档位计数（缺省补 0，报告不用再猜键在不在）
static func judge_bin_counts(rows: Array, key: String) -> Dictionary:
	var out: Dictionary = {
		VD_ACHIEVED: 0, VD_GOOD: 0, VD_FAIR: 0, VD_BAD: 0, VD_UNDECIDED: 0,
	}
	for r in rows:
		if not (r is Dictionary):
			continue
		var bins = (r as Dictionary).get("判据", null)
		if not (bins is Dictionary):
			continue
		var k: String = String((bins as Dictionary).get(key, VD_UNDECIDED))
		out[k] = int(out.get(k, 0)) + 1
	return out


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
