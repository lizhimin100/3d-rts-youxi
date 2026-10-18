class_name RtsCombat
extends RefCounted
## **战斗数值中枢**：伤害公式、护甲减免、克制、暴击、命中反馈、群体伤害。
##
## 为什么单独一个文件：伤害公式**必须只有一份实现**。玩家步兵、AI 步兵、箭塔、火球
## 如果各写一份，"同样的兵打同样的兵伤害不一样"这种 bug 永远查不清。
## 所有伤害路径（近战/投射物/技能 AOE）都收敛到这里的 compute()。
##
## 公式（条令 + 任务书冻结，一个符号都不许改）：
##   护甲减免 = min(armor * Cfg.game.armor_reduction, Cfg.game.armor_reduction_cap)
##   克制     = Cfg.game.damage_multiplier(attack_type, target_armor_type)
##   暴击     = randf() < Cfg.game.crit_chance ? Cfg.game.crit_multiplier : 1.0
##   最终     = (基础伤害 ± spread 随机) × 克制 × (1 - 护甲减免) × 暴击
##
## 铁匠铺升级：攻击/护甲各 +15%/级，**只乘在最后一步**（=1.0 时公式与上面逐字符相同），
## 这样"没有升级"的路径永远不会和公式有偏差。

# ===========================================================================
# 常量（Cfg 里没有对应字段的"手感/机制"常量，集中在这里，不散落）
# ===========================================================================

## 铁匠铺每级加成（attack_up / armor_up 各 +15%）
const UPGRADE_PER_LEVEL: float = 0.15
## 震屏感知半径（米）：只有玩家镜头附近的战斗才震屏，远处打翻天也不晃
const SHAKE_LISTEN_RADIUS: float = 28.0
## 命中火花的高度偏移（单位胸口位置，别在脚底板冒火花）
const HIT_VFX_HEIGHT: float = 0.95

## 阵营升级等级存放在 RtsFaction 的 meta 上（不污染 Lead 的阵营类）
const META_ATK_UP: StringName = &"sled_atk_up_level"
const META_ARM_UP: StringName = &"sled_arm_up_level"

## 暴击/普通命中的特效色
const COLOR_CRIT: Color = Color(1.0, 0.45, 0.15)
const COLOR_HIT: Color = Color(1.0, 0.88, 0.45)


# ===========================================================================
# 一次伤害的结果
# ===========================================================================
class DamageInfo extends RefCounted:
	## 最终伤害（已含克制/护甲/暴击/升级）
	var damage: float = 0.0
	## 是否暴击
	var is_crit: bool = false
	## 伤害类型（RtsConst.DamageType）
	var attack_type: int = 0
	## 破甲后的实际减免比例（调试/测试用）
	var mitigation: float = 0.0
	## 克制倍率（调试/测试用）
	var multiplier: float = 1.0


# ===========================================================================
# 公式零件
# ===========================================================================

## 护甲减免比例 = min(armor * 系数, 上限)
static func armor_mitigation(armor: float) -> float:
	var cfg: GameConfig = Cfg.game
	return minf(maxf(armor, 0.0) * cfg.armor_reduction, cfg.armor_reduction_cap)


## 克制倍率（直接问 Cfg，保证和数值表同源）
static func counter_multiplier(attack_type: int, target_armor_type: int) -> float:
	return Cfg.game.damage_multiplier(attack_type, target_armor_type)


## 纯函数算一次伤害。
## roll_spread / roll_crit 传 [0,1) 用于测试注入确定性；传负数=真随机。
## attack_mult / armor_mult 是升级倍率（1.0 = 无升级，此时结果与条令公式完全一致）。
static func compute(base: float, spread: float, attack_type: int,
		target_armor: float, target_armor_type: int,
		attack_mult: float = 1.0,
		roll_spread: float = -1.0, roll_crit: float = -1.0) -> DamageInfo:
	var info := DamageInfo.new()
	info.attack_type = attack_type
	var cfg: GameConfig = Cfg.game

	# (基础伤害 ± spread 随机)：spread * [-1, 1]
	var r_spread: float = roll_spread
	if r_spread < 0.0:
		r_spread = randf()
	var base_dmg: float = base + spread * (r_spread * 2.0 - 1.0)

	var mult: float = cfg.damage_multiplier(attack_type, target_armor_type)
	var mit: float = armor_mitigation(target_armor)

	var crit: float = 1.0
	var r_crit: float = roll_crit
	if r_crit < 0.0:
		r_crit = randf()
	if r_crit < cfg.crit_chance:
		crit = cfg.crit_multiplier
		info.is_crit = true

	var dmg: float = base_dmg * mult * (1.0 - mit) * crit * attack_mult
	info.damage = maxf(dmg, 0.0)
	info.mitigation = mit
	info.multiplier = mult
	return info


# ===========================================================================
# 升级（阵营级）
# ===========================================================================

## 给阵营升一级攻击（铁匠铺 attack_up）
static func add_attack_upgrade(faction: RtsFaction) -> void:
	if faction == null:
		return
	faction.set_meta(META_ATK_UP, attack_up_level(faction) + 1)


## 给阵营升一级护甲（铁匠铺 armor_up）
static func add_armor_upgrade(faction: RtsFaction) -> void:
	if faction == null:
		return
	faction.set_meta(META_ARM_UP, armor_up_level(faction) + 1)


## 当前攻击升级级数
static func attack_up_level(faction: RtsFaction) -> int:
	if faction == null or not faction.has_meta(META_ATK_UP):
		return 0
	return int(faction.get_meta(META_ATK_UP))


## 当前护甲升级级数
static func armor_up_level(faction: RtsFaction) -> int:
	if faction == null or not faction.has_meta(META_ARM_UP):
		return 0
	return int(faction.get_meta(META_ARM_UP))


## 攻击倍率（对**已存在**与**未来**单位同时生效：读的是阵营级字段，不是改 def）
static func attack_mult(faction: RtsFaction) -> float:
	return 1.0 + UPGRADE_PER_LEVEL * float(attack_up_level(faction))


## 护甲倍率
static func armor_mult(faction: RtsFaction) -> float:
	return 1.0 + UPGRADE_PER_LEVEL * float(armor_up_level(faction))


## 目标的**有效护甲值**（基础护甲 × 阵营升级倍率）
static func effective_armor(target: Node3D) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var d: UnitDef = target.def
	if d == null:
		return 0.0
	var fac: RtsFaction = target.faction
	return d.armor * armor_mult(fac)


# ===========================================================================
# 铁匠铺研究（研究 id 由 UnitDef.researches 声明）
# ===========================================================================

## 研究 id：攻击
const RESEARCH_ATTACK: StringName = &"attack_up"
## 研究 id：护甲
const RESEARCH_ARMOR: StringName = &"armor_up"


## 这个研究 id 是否被本系统支持
static func has_research(id: StringName) -> bool:
	return id == RESEARCH_ATTACK or id == RESEARCH_ARMOR


## 研究显示名（提示消息用）
static func research_name(id: StringName) -> String:
	match id:
		RESEARCH_ATTACK:
			return "武器锻造（攻击 +%d%%）" % int(UPGRADE_PER_LEVEL * 100.0)
		RESEARCH_ARMOR:
			return "护甲锻造（护甲 +%d%%）" % int(UPGRADE_PER_LEVEL * 100.0)
		_:
			return String(id)


## 把一项研究落到阵营上（对**已存在**和**未来**单位同时生效）
static func apply_research(faction: RtsFaction, id: StringName) -> void:
	if faction == null:
		return
	match id:
		RESEARCH_ATTACK:
			add_attack_upgrade(faction)
		RESEARCH_ARMOR:
			add_armor_upgrade(faction)
		_:
			pass


# ===========================================================================
# 命中结算（唯一入口）
# ===========================================================================

## 直接结算一次命中：算伤害 → 扣血 → 播特效 → 发信号 → 震屏。
## 返回 DamageInfo（失败返回 null）。
static func resolve_hit(attacker: Node3D, target: Node3D) -> DamageInfo:
	if attacker == null or not is_instance_valid(attacker):
		return null
	if target == null or not is_instance_valid(target):
		return null
	var ad: UnitDef = attacker.def
	if ad == null or ad.attack_damage <= 0.0:
		return null
	var td: UnitDef = target.def
	if td == null:
		return null
	if target.has_method("is_alive") and not bool(target.call("is_alive")):
		return null
	var info := compute(
		ad.attack_damage, ad.attack_spread, ad.attack_type,
		effective_armor(target), td.armor_type,
		attack_mult(attacker.faction)
	)
	_apply(attacker, target, info)
	return info


## 攻击快照：投射物飞行途中射手可能已经死了，伤害按**出手瞬间**的数值结算。
static func make_snapshot(attacker: Node3D) -> Dictionary:
	var snap: Dictionary = {}
	if attacker == null or not is_instance_valid(attacker):
		return snap
	var ad: UnitDef = attacker.def
	if ad == null:
		return snap
	snap["damage"] = ad.attack_damage
	snap["spread"] = ad.attack_spread
	snap["attack_type"] = ad.attack_type
	snap["attack_mult"] = attack_mult(attacker.faction)
	snap["faction"] = attacker.faction
	snap["vfx_color"] = _vfx_color(ad.attack_type)
	return snap


## 用快照结算命中（投射物落点用）
static func resolve_from_snapshot(snap: Dictionary, target: Node3D, source: Node3D = null) -> DamageInfo:
	if snap.is_empty() or target == null or not is_instance_valid(target):
		return null
	if target.has_method("is_alive") and not bool(target.call("is_alive")):
		return null
	var td: UnitDef = target.def
	if td == null:
		return null
	var info := compute(
		float(snap.get("damage", 0.0)), float(snap.get("spread", 0.0)),
		int(snap.get("attack_type", RtsConst.DamageType.NORMAL)),
		effective_armor(target), td.armor_type,
		float(snap.get("attack_mult", 1.0))
	)
	_apply(source, target, info, Color(snap.get("vfx_color", COLOR_HIT)))
	return info


## 技能/环境伤害的通用结算（攻击者为空或已死也能打）。
static func deal_damage(source: Node3D, target: Node3D, base: float, attack_type: int,
		attack_mult: float = 1.0) -> DamageInfo:
	if target == null or not is_instance_valid(target):
		return null
	var td: UnitDef = target.def
	if td == null:
		return null
	if target.has_method("is_alive") and not bool(target.call("is_alive")):
		return null
	var info := compute(base, 0.0, attack_type, effective_armor(target), td.armor_type, attack_mult)
	_apply(source, target, info, _vfx_color(attack_type))
	return info


## 群体伤害（火球 AOE）：对半径内**所有敌方**单位/建筑结算
static func deal_aoe(source: Node3D, center: Vector3, radius: float, base: float,
		attack_type: int, faction: RtsFaction) -> int:
	var foe: RtsFaction = Game.enemy_of(faction)
	if foe == null:
		return 0
	var hit_count: int = 0
	var pool: Array = []
	pool.append_array(foe.units)
	pool.append_array(foe.buildings)
	var r2: float = radius * radius
	for u in pool:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive():
			continue
		if u.global_position.distance_squared_to(center) > r2:
			continue
		if deal_damage(source, u, base, attack_type) != null:
			hit_count += 1
	return hit_count


# ===========================================================================
# 内部
# ===========================================================================

## 真正落到目标身上：扣血 + 反馈
static func _apply(attacker: Node3D, target: Node3D, info: DamageInfo,
		color: Color = Color(0, 0, 0)) -> void:
	var c: Color = color
	if c == Color(0, 0, 0):
		c = COLOR_CRIT if info.is_crit else COLOR_HIT

	if target.has_method("take_damage"):
		target.call("take_damage", info.damage, info.attack_type, attacker)

	# 命中的"啪"一下：火花贴目标胸口
	var hit_pos: Vector3 = target.global_position + Vector3.UP * HIT_VFX_HEIGHT
	ArtKit.vfx_hit(hit_pos, c)

	Game.combat_hit.emit(attacker, target, info.damage, info.is_crit)

	# 只有玩家镜头附近的战斗才震屏（远处打架别晃玩家脑袋）
	if is_near_camera(hit_pos):
		var strength: float = Cfg.game.shake_on_hit * (1.8 if info.is_crit else 1.0)
		Game.shake(strength)


## 命中点是否在玩家镜头感知范围内（公开：投射物/技能复用同一套判定）
static func is_near_camera(pos: Vector3) -> bool:
	var cam: Camera3D = RtsWorld.camera()
	if cam == null:
		return false
	return cam.global_position.distance_to(pos) <= SHAKE_LISTEN_RADIUS


## 伤害类型 → 特效色
static func _vfx_color(attack_type: int) -> Color:
	match attack_type:
		RtsConst.DamageType.PIERCE:
			return Color(1.0, 0.92, 0.62)
		RtsConst.DamageType.MAGIC:
			return Color(0.48, 0.72, 1.0)
		RtsConst.DamageType.SIEGE:
			return Color(1.0, 0.55, 0.22)
		_:
			return COLOR_HIT
