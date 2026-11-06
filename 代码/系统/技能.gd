class_name RtsSkills
extends RefCounted
## **技能系统（雏形）**：数值住 `代码/配置/技能表.gd`，这里只做执行。
##
## 设计要点：施法**不做成 await 协程**，而是拆成"起手（begin_cast）→ 单位自己数前摇 →
## 出手（release）"。这样技能和单位是同一个时间步驱动的，无头测试里可以按固定 delta
## 逐步推进，行为完全确定（用 await 的话测试要靠真实时间等，没法精确验证）。
##
## 数值来源：
##   - 冷却 / 技能 id  → `UnitDef.ability_cooldown` / `UnitDef.abilities`（Cfg 数据）
##   - 前摇 / 目标类型 / 载位数 → `代码/配置/技能表.gd`（唯一表）
##   - AOE 半径/伤害/减速 → 任务书冻结的规格，仍是本文件常量（火球专属）
##
## 2026-11-07 扩成"表驱动"：新增技能 = 技能表加一条 + release 里加一个 case，
## 不再需要改 `has/cast_time/unit_has` 三个函数。
## 采集类（伐木/采矿）不进 `UnitDef.abilities`：它们是右键点资源触发的，
## 由 `单位.gd` 的 GatherPhase 驱动，但前摇/载位仍然从这张表读 —— 这就是雏形的意义：
## 以后要加"主动技能/被动技能/光环"，都往同一张表里塞。

## 火球技能 id
const ID_FIREBALL: StringName = &"fireball"

## 技能表（数值唯一真相源）
const TABLE := preload("res://代码/配置/技能表.gd")

## 火球规格（任务书冻结）
const FIREBALL_RADIUS: float = 3.5      ## AOE 半径（米）
const FIREBALL_DAMAGE: float = 55.0     ## AOE 伤害
const FIREBALL_SLOW_TIME: float = 2.5   ## 减速持续（秒）
const FIREBALL_SLOW_RATIO: float = 0.6  ## 减速后移速倍率
## 施法前摇（秒）——"有施法动作"的节奏来源
const FIREBALL_CAST_TIME: float = 0.5
## 火球飞行速度（米/秒）
const FIREBALL_SPEED: float = 22.0
## 火球落点震屏强度
const FIREBALL_SHAKE: float = 0.30


## 该技能是否已实现（表里有就算）
static func has(id: StringName) -> bool:
	return TABLE.has(id)


## 施法前摇时长（秒）；未知技能返回 0
static func cast_time(id: StringName) -> float:
	var d: Dictionary = TABLE.get_def(id)
	if d.is_empty():
		return 0.0
	return maxf(float(d.get("cast", 0.0)), 0.0)


## 是不是"采集类"技能（伐木/采矿，不走 CAST 状态）
static func is_gather(id: StringName) -> bool:
	return TABLE.is_gather(id)


## 技能定义（给界面/自检读）
static func def_of(id: StringName) -> Dictionary:
	return TABLE.get_def(id)


## 冷却时长（读单位的 UnitDef.ability_cooldown，不硬编码）
static func cooldown_of(unit: Node3D) -> float:
	if unit == null or not is_instance_valid(unit):
		return 0.0
	var d: UnitDef = unit.def
	if d == null:
		return 0.0
	return maxf(d.ability_cooldown, 0.1)


## 单位是否有这个技能。
##   · 主动技能：读 `UnitDef.abilities`（卡上的 skills）；
##   · 采集技能：**所有 worker 天生会**（`RtsWorld.is_worker_def`），不写进卡 ——
##     写进去的话命令卡会把"伐木/采矿"当成火球术渲染成一排 Q 键按钮。
static func unit_has(unit: Node3D, id: StringName) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var d: UnitDef = unit.def
	if d == null:
		return false
	if d.abilities.has(id):
		return true
	if is_gather(id):
		return RtsWorld.is_worker_def(d)
	return false


## 单位第一个已实现的技能 id（没有返回空）
static func first_ability(unit: Node3D) -> StringName:
	if unit == null or not is_instance_valid(unit):
		return &""
	var d: UnitDef = unit.def
	if d == null:
		return &""
	for a in d.abilities:
		# 只返回"主动"技能：采集技能不是按键释放的
		if has(a) and not is_gather(a):
			return a
	return &""


# ===========================================================================
# 施法流程（由 RtsUnit 驱动）
# ===========================================================================

## 起手：校验 → 设状态 → 播 cast 动画 → 进冷却。返回是否成功起手。
## 真正的伤害在前摇结束后由 release() 打出。
static func begin_cast(unit: Node3D, id: StringName, pos: Vector3, target: Node3D) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not unit_has(unit, id):
		return false
	# 采集类技能不进 CAST 状态机（它们由 GatherPhase 驱动，见 单位.gd）
	if is_gather(id):
		return false
	if not unit.is_alive():
		return false
	# 冷却检查交给单位（它自己持有计时器）
	if unit.has_method("ability_ready") and not bool(unit.call("ability_ready")):
		return false
	unit.set("_cast_id", id)
	unit.set("_cast_pos", pos)
	unit.set("_cast_target", target)
	unit.set("_cast_t", cast_time(id))
	unit.set("state", RtsConst.State.CAST)
	unit.call("_start_ability_cooldown", cooldown_of(unit))
	return true


## 出手：前摇走完，真正把火球扔出去（此时才扣血）。
static func release(unit: Node3D, id: StringName, pos: Vector3, target: Node3D) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if not unit.is_alive():
		return
	match id:
		ID_FIREBALL:
			_release_fireball(unit, pos, target)
		_:
			pass


## 火球：从法杖位置抛出，带 AOE + 减速
static func _release_fireball(unit: Node3D, pos: Vector3, target: Node3D) -> void:
	var d: UnitDef = unit.def
	var faction: RtsFaction = unit.faction
	if d == null or faction == null:
		return

	# 落点：有目标就砸目标脚下，没目标就用指令坐标
	var aim: Vector3 = pos
	if target != null and is_instance_valid(target):
		aim = target.global_position
	aim = RtsWorld.snap_y(aim)

	var from_pos: Vector3 = unit.global_position + Vector3.UP * 1.35
	var snap: Dictionary = RtsCombat.make_snapshot(unit)

	RtsProjectile.fire_from(unit, RtsConst.Projectile.FIREBOLT, aim, null,
		FIREBALL_SPEED, snap, faction,
		FIREBALL_RADIUS, FIREBALL_DAMAGE,
		FIREBALL_SLOW_RATIO, FIREBALL_SLOW_TIME)

	# 施法反馈：法阵 + 震屏（玩家镜头附近才震）
	ArtKit.vfx_magic(from_pos, 1.1, Color(0.55, 0.78, 1.0))
	if RtsCombat.is_near_camera(from_pos):
		Game.shake(FIREBALL_SHAKE)
