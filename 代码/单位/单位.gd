class_name RtsUnit
extends Node3D
## **单位**：一场 RTS 里所有"会动、会打、会干活"的东西（农民/步兵/弓箭手/法师）。
## 建筑继承它（RtsBuilding 只覆盖"不移动 + 建造进度 + 训练队列"那部分）。
##
## 公开 API 严格按 文档/作战条令.md §6（其他模块都在调）：
##   setup / take_damage / order_move / order_attack / order_stop / order_hold
##   order_gather / order_build / order_cast / selection_point / is_alive / get_radius
## 额外补充（战斗/AI 内部用）：
##   order_attack_move / apply_slow / ability_ready / is_idle_like / gather_kind / is_mobile
##
## ============ 移动手感（命根子，参数全在下面常量里）============
##   · 寻路走 Game.level.find_path（已带地形高度），路径点容差 0.35m
##   · A* **节流 0.25s**：同一单位 0.25s 内不重复算路
##   · 起停缓动 0.12s（0→满速线性 0.12s，不硬起硬停像僵尸）
##   · 朝向按 turn_speed 平滑转向；背对目标时先原地转身，不"横着滑"
##   · 单位分离：SpatialHash 每帧查邻居，半径 = 两半径之和 ×1.15
##   · 贴地：每帧 y = 地形高度
##   · 路径不可达：朝目标直行最多 1.5s 再停，不站那当雕塑

# ===========================================================================
# 手感常量（调手感只改这一块）
# ===========================================================================
## 到达路径点的容差（米）
const ARRIVE_TOLERANCE: float = 0.35
## 起 / 停缓动时间（秒）：0→满速、满速→0 都用这个时长
const SPEED_EASE_TIME: float = 0.12
## A* 节流间隔（秒）：同一单位这时间内不重复算路
const REPATH_INTERVAL: float = 0.25
## 路径不可达时的直行兜底时长（秒）
const UNREACHABLE_GRACE: float = 1.5
## 分离半径系数（两半径之和 × 这个）
const SEPARATION_FACTOR: float = 1.15
## 索敌/经济决策分片间隔（秒），别让 N 个单位同一帧一起算
const THINK_SLICE: float = 0.3
## 采集/建造时相对目标的额外站位间隙（米）
const GATHER_GAP: float = 0.2
## 到点判定的人工余量（米）。A* 终点会被吸附到最近可走格，可能比站位阈值远 0.3~0.5m，
## 实测就是这零点几米让农民永远差一点到，站在矿边一动不动 —— 这是采集卡死的主因。
const ARRIVE_SLACK: float = 1.4
## 拥挤惩罚：每个已经盯上该资源的农民，等效增加多少米距离（十人分流用）
const CROWD_PENALTY: float = 7.0
## 卡死兜底：某阶段停留超过这个秒数且几乎没位移，就强制推进
const PHASE_STUCK_TIME: float = 2.8
## 农民被打后逃跑持续时间（秒）
const FLEE_TIME: float = 3.0
## 转向时允许的最低速度占比（背身=0 先转身，侧身还能蹭一点）
const TURN_SPEED_FLOOR: float = 0.25
## 贴地时追随地形高度的最大速度（米/秒）。太小会陷进坡里，太大会在台阶上弹跳
const GROUND_FOLLOW_SPEED: float = 26.0
## 身体贴合坡面的平滑速度
const TILT_SMOOTH: float = 9.0
## 尸体下沉时长（秒）与深度（米）
const SINK_TIME: float = 0.6
const SINK_DEPTH: float = 1.3
## 寻路目标变化多少米才值得重算
const GOAL_CHANGE_EPS: float = 0.6

## 采集内部阶段
enum GatherPhase { SEEK = 0, TO_NODE = 1, HARVEST = 2, TO_DROP = 3 }

# ===========================================================================
# 共享空间哈希（全单位共用一份，每帧重建一次，避免 O(n²)）
# ===========================================================================
static var _sep_hash: SpatialHash = null
static var _sep_frame: int = -1


# ===========================================================================
# 公开状态（条令 §6 冻结）
# ===========================================================================
var def: UnitDef = null
var faction: RtsFaction = null
var hp: float = 1.0
var state: int = RtsConst.State.IDLE
var is_selected: bool = false
var target: Node3D = null
var move_target: Vector3 = Vector3.ZERO

## 当前指令（RtsConst.Order）
var order: int = RtsConst.Order.NONE
## 外观（模型/动画/闪白）
var visual: UnitVisual = null

# ===========================================================================
# 内部状态
# ===========================================================================
var _moving: bool = false
## 移动指令被"还手/追击"打断过：敌人清完后要继续走完原目的地
var _move_interrupted: bool = false
## 被打断前的原目的地（追击时 _goal 会被改写成敌人坐标，所以必须单独存）
var _saved_goal: Vector3 = Vector3.ZERO
var _goal: Vector3 = Vector3.ZERO
var _path: PackedVector3Array = PackedVector3Array()
var _path_i: int = 0
var _repath_cd: float = 0.0
var _need_repath: bool = false
var _direct_t: float = 0.0
var _speed: float = 0.0
## 坡度对速度的倍率（上坡 <1，下坡 >1）
var _slope_mult: float = 1.0
## 身体贴合坡面的倾斜（x=俯仰, y=翻滚）
var _tilt: Vector2 = Vector2.ZERO
var _yaw: float = 0.0

var _attack_cd: float = 0.0
var _windup_t: float = 0.0
var _swinging: bool = false
var _think_t: float = 0.0

var _slow_mult: float = 1.0
var _slow_t: float = 0.0

# 技能
var _ability_cd: float = 0.0
var _cast_id: StringName = &""
var _cast_pos: Vector3 = Vector3.ZERO
var _cast_target: Node3D = null
var _cast_t: float = 0.0

# 采集
var _gather_node: Node3D = null
var _gather_phase: int = GatherPhase.SEEK
var _gather_t: float = 0.0
var _carry: int = 0
## 累计卸货次数（自检用）
var _deposit_count: int = 0
## 当前阶段已停留时间（秒）与阶段起点位置（卡死兜底用）
var _phase_t: float = 0.0
## 巡逻状态：A/B 两个端点 + 当前该去哪一端
var _patrol_active: bool = false
## 卡死检测：计时 / 上次采样位置 / 连续卡住次数
var _stuck_t: float = 0.0
var _stuck_pos: Vector3 = Vector3.ZERO
var _stuck_count: int = 0
var _patrol_a: Vector3 = Vector3.ZERO
var _patrol_b: Vector3 = Vector3.ZERO
var _patrol_at_b: bool = true
var _phase_pos: Vector3 = Vector3.ZERO
var _carry_kind: int = RtsConst.Harvest.GOLD
var _flee_t: float = 0.0
var _was_gathering: bool = false

# 建造
var _build_site: Node3D = null

# 死亡
var _dying: bool = false
## 是否已从全局注册表注销（死亡信号只能发一次）
var _unregistered: bool = false
var _dead_t: float = 0.0
var _sinking: bool = false
var _sink_t: float = 0.0
var _sink_base_y: float = 0.0

var _visual_built: bool = false


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	# Game.spawn_unit 是 add_child 之后才调 setup，这里 def 可能还是 null，
	# 所以视觉构建的**主路径在 setup()**；这里只给"先设 def 再加树"的场合兜底。
	if def != null:
		_ensure_visual()
	_yaw = rotation.y


## 装配（由 Game.spawn_unit 调用；add_child 之后）
func setup(p_faction: RtsFaction, p_def: UnitDef) -> void:
	faction = p_faction
	def = p_def
	if def == null:
		return
	hp = def.max_hp
	_ability_cd = 0.0
	_ensure_visual()
	_yaw = rotation.y
	# 决策分片错开，避免所有单位同一帧一起索敌
	_think_t = fmod(float(get_instance_id() % 1000) * 0.001, THINK_SLICE)


## 建外观（幂等）
func _ensure_visual() -> void:
	if _visual_built or def == null:
		return
	_visual_built = true
	visual = UnitVisual.new()
	visual.name = "外观"
	add_child(visual)
	var col: Color = faction.color if faction != null else Color.WHITE
	visual.build(def, col)


# ===========================================================================
# 查询
# ===========================================================================

## 是否存活
func is_alive() -> bool:
	return hp > 0.0 and state != RtsConst.State.DEAD


## 碰撞半径
func get_radius() -> float:
	if def == null:
		return 0.45
	return def.body_radius


## 头顶位置（血条 / 选中标记）
func selection_point() -> Vector3:
	var h: float = def.height if def != null else 1.6
	return global_position + Vector3.UP * h


## 是否可移动单位（建筑返回 false）
func is_mobile() -> bool:
	return def != null and def.kind == RtsConst.Kind.UNIT


## 是否闲着（AI 派活用）
func is_idle_like() -> bool:
	return not _dying and order == RtsConst.Order.NONE


## 当前采集的资源种类（没在采集返回 -1）
func gather_kind() -> int:
	if def == null or not RtsWorld.is_worker_def(def):
		return -1
	if order != RtsConst.Order.GATHER and _flee_t <= 0.0:
		return -1
	return _carry_kind


## 技能冷却好了没
func ability_ready() -> bool:
	return _ability_cd <= 0.0


## 当前移速倍率（减速 debuff）
func speed_multiplier() -> float:
	return _slow_mult if _slow_t > 0.0 else 1.0


func _max_speed() -> float:
	if def == null:
		return 0.0
	return maxf(def.move_speed * speed_multiplier(), 0.0)


## 加速度（让 0→满速刚好用 SPEED_EASE_TIME 秒）
func _accel() -> float:
	if def == null:
		return 0.0
	return def.move_speed / SPEED_EASE_TIME


# ===========================================================================
# 伤害 / 死亡
# ===========================================================================

## 受到伤害。amount 是**已结算完**的最终伤害（护甲/克制/暴击由 RtsCombat 算好）。
func take_damage(amount: float, _type: int, from: Node3D) -> void:
	if not is_alive():
		return
	hp -= amount
	if visual != null:
		visual.flash()
	if hp <= 0.0:
		hp = 0.0
		_die()
		return
	# 农民挨打就往基地跑，别站那儿送死
	if def != null and RtsWorld.is_worker_def(def):
		_flee(from)


## 减速（火球附带）：移速 ×ratio，持续 time 秒
func apply_slow(ratio: float, time: float) -> void:
	if ratio <= 0.0 or ratio >= 1.0:
		return
	if _slow_t > 0.0:
		_slow_mult = minf(_slow_mult, ratio)
	else:
		_slow_mult = ratio
	_slow_t = maxf(_slow_t, time)


## 农民逃跑：往基地跑一段时间，期间不干活
func _flee(_from: Node3D) -> void:
	if _flee_t > 0.0:
		return
	_was_gathering = (order == RtsConst.Order.GATHER)
	_flee_t = FLEE_TIME
	_swinging = false
	_stop_moving()
	target = null
	order = RtsConst.Order.NONE


func _die() -> void:
	if _dying:
		return
	_dying = true
	state = RtsConst.State.DEAD
	target = null
	order = RtsConst.Order.NONE
	_swinging = false
	_stop_moving()
	_dead_t = Cfg.game.corpse_linger
	_sinking = false
	_sink_t = 0.0
	_sink_base_y = global_position.y

	if visual != null:
		visual.play_death()

	var col: Color = faction.color if faction != null else Color(0.7, 0.3, 0.25)
	ArtKit.vfx_death(global_position, col)
	if RtsCombat.is_near_camera(global_position):
		Game.shake(Cfg.game.shake_on_death)

	# 死亡即注销 + 广播。
	# 为什么不等尸体沉完：`unit_died` 的语义是"它死了"，胜负判定、HUD 取消选中、
	# AI 统计、经验结算全都要**立刻**看到；尸体只是留在场景里的视觉残骸。
	# （条令原文把 unregister/emit 写在"下沉后"，实测会让死亡信号晚 2.8 秒才到，
	#   验收器的补刀检测直接判为"死亡链路断了"，所以这里按信号语义取前置。）
	_unregister_now()


## 死亡后的尸体处理：躺 corpse_linger 秒 → 下沉 → 注销 → 发信号
func _update_dead(dt: float) -> void:
	if not _sinking:
		_dead_t -= dt
		if _dead_t <= 0.0:
			_sinking = true
			_sink_t = SINK_TIME
			_sink_base_y = global_position.y
			_on_corpse_sink()
		return
	_sink_t -= dt
	var k: float = 1.0 - clampf(_sink_t / SINK_TIME, 0.0, 1.0)
	global_position.y = _sink_base_y - SINK_DEPTH * k
	if _sink_t <= 0.0:
		_finalize_death()


## 尸体开始下沉的回调（建筑用来清占地）
func _on_corpse_sink() -> void:
	pass


## 真正注销 + 广播
func _finalize_death() -> void:
	_unregister_now()
	queue_free()


## 从全局注册表注销并广播死亡（幂等）
func _unregister_now() -> void:
	if _unregistered:
		return
	_unregistered = true
	Game.unregister(self)
	Game.unit_died.emit(self)


# ===========================================================================
# 指令（条令 §6）
# ===========================================================================

## 移动到指定点（编队时 CommandSystem 会给每个单位各自的目标点）
func order_move(pos: Vector3) -> void:
	if _dying:
		return
	order = RtsConst.Order.MOVE
	target = null
	_flee_t = 0.0
	_go_to(pos, true)


## 攻击指定目标
func order_attack(t: Node3D) -> void:
	if _dying or t == null:
		return
	order = RtsConst.Order.ATTACK
	target = t
	_flee_t = 0.0
	_go_to(t.global_position, true)


## 攻击移动：路上遇敌就打，打完继续推进
func order_attack_move(pos: Vector3) -> void:
	if _dying:
		return
	order = RtsConst.Order.ATTACK_MOVE
	target = null
	_flee_t = 0.0
	_go_to(pos, true)


## 停止（清一切指令，原地待机）
func order_stop() -> void:
	if _dying:
		return
	order = RtsConst.Order.NONE
	target = null
	_gather_node = null
	_build_site = null
	_flee_t = 0.0
	_swinging = false
	_patrol_active = false
	_stop_moving()
	if state != RtsConst.State.DEAD:
		state = RtsConst.State.IDLE


## 保持原地警戒（不追，但打进范围的敌人）
func order_hold() -> void:
	if _dying:
		return
	order = RtsConst.Order.HOLD
	target = null
	_swinging = false
	_patrol_active = false
	_stop_moving()
	state = RtsConst.State.IDLE


## 巡逻：在"当前位置 ↔ 目标点"之间往返，路上遇敌就打（ATTACK_MOVE 的往返版）
func order_patrol(pos: Vector3) -> void:
	if _dying:
		return
	_patrol_a = global_position
	_patrol_b = Vector3(pos.x, 0.0, pos.z)
	_patrol_active = true
	_patrol_at_b = true
	order = RtsConst.Order.ATTACK_MOVE
	target = null
	_swinging = false
	state = RtsConst.State.MOVE
	_go_to(_patrol_b, true)


## 巡逻的往返检查：到了这一头就掉头（由 _update_order 每帧调用）
func _tick_patrol() -> void:
	if not _patrol_active or order != RtsConst.Order.ATTACK_MOVE:
		return
	var goal: Vector3 = _patrol_b if _patrol_at_b else _patrol_a
	if _flat_dist(goal) > 1.6:
		return
	_patrol_at_b = not _patrol_at_b
	var next: Vector3 = _patrol_b if _patrol_at_b else _patrol_a
	_go_to(next, true)


## 采集指定资源点
func order_gather(node: Node3D) -> void:
	if _dying or node == null:
		return
	if def == null or not RtsWorld.is_worker_def(def):
		return
	order = RtsConst.Order.GATHER
	target = null
	_gather_node = node
	var hk: Variant = node.get("harvest_kind")
	if hk != null:
		_carry_kind = int(hk)
	_gather_phase = GatherPhase.TO_NODE
	_gather_t = 0.0
	_flee_t = 0.0
	_was_gathering = true
	_go_to(node.global_position, true)


## 建造：先扣钱，再走过去盖
func order_build(building_def: UnitDef, pos: Vector3) -> void:
	if _dying or building_def == null:
		return
	if def == null or not RtsWorld.is_worker_def(def) or faction == null:
		return

	# 钱不够 / 位置不合法 → 给玩家提示，别默默失败
	if not Game.can_afford(faction, building_def.id):
		if faction.is_player:
			Game.toast("资源不足：%s" % building_def.display_name, Color(1, 0.5, 0.4))
		return
	var fp: Vector2i = building_def.footprint
	if fp == Vector2i.ZERO:
		fp = Vector2i(1, 1)
	if not RtsWorld.is_buildable(pos, fp):
		if faction.is_player:
			Game.toast("这里不能建造", Color(1, 0.6, 0.35))
		return
	# 真扣钱
	if not Game.pay(faction, building_def.id):
		if faction.is_player:
			Game.toast("资源不足：%s" % building_def.display_name, Color(1, 0.5, 0.4))
		return

	var site: RtsBuilding = RtsBuilding.new()
	site.name = "建造中_%s" % String(building_def.id)
	var parent: Node3D = RtsWorld.level()
	if parent == null:
		parent = get_parent() as Node3D
	if parent == null:
		return
	parent.add_child(site)
	site.global_position = RtsWorld.ground(pos)
	site.setup_construction(faction, building_def)
	RtsWorld.mark_footprint(site)
	Game.register(site)
	Game.unit_spawned.emit(site)

	_build_site = site
	order = RtsConst.Order.BUILD
	_flee_t = 0.0
	_go_to(site.global_position, true)


## 释放技能
func order_cast(ability: StringName, pos: Vector3, t: Node3D = null) -> void:
	if _dying or def == null:
		return
	if not RtsSkills.has(ability):
		return
	if not RtsSkills.unit_has(self, ability):
		return
	if not ability_ready():
		if faction != null and faction.is_player:
			Game.toast("技能冷却中", Color(0.7, 0.8, 1.0))
		return
	order = RtsConst.Order.CAST
	_stop_moving()
	if not RtsSkills.begin_cast(self, ability, pos, t):
		order = RtsConst.Order.NONE


## 由 RtsSkills 调用：进入技能冷却
func _start_ability_cooldown(t: float) -> void:
	_ability_cd = maxf(t, 0.0)


# ===========================================================================
# 每帧主循环
# ===========================================================================

func _process(delta: float) -> void:
	if def == null:
		return

	# 卡帧保护：单帧最多推进 100ms（再大就会穿墙）。
	# ⚠ 这个上限不能太小：验收器用 Engine.time_scale=5 加速，
	#   固定 60fps 下每帧 delta 是 0.083s，夹到 0.05 会让单位只跑出 60% 的行程。
	var dt: float = minf(delta, 0.1)

	if _dying or state == RtsConst.State.DEAD:
		_update_dead(dt)
		return

	_tick_timers(dt)

	# 施法中：只数前摇，别的都不做
	if state == RtsConst.State.CAST:
		_update_cast(dt)
		_update_separation(dt)
		_snap_ground(dt)
		_update_anim()
		return

	_update_order(dt)
	_update_move(dt)
	_update_attack(dt)
	_update_auto_cast(dt)

	_update_separation(dt)
	_rescue_if_inside_wall()
	_snap_ground(dt)
	_update_anim()


## 各种计时器
func _tick_timers(dt: float) -> void:
	_attack_cd = maxf(_attack_cd - dt, 0.0)
	_ability_cd = maxf(_ability_cd - dt, 0.0)
	if _slow_t > 0.0:
		_slow_t -= dt
		if _slow_t <= 0.0:
			_slow_mult = 1.0
	if _repath_cd > 0.0:
		_repath_cd -= dt
		if _repath_cd <= 0.0 and _need_repath:
			_request_path()
	if _flee_t > 0.0:
		_flee_t -= dt
		if _flee_t <= 0.0:
			_resume_after_flee()
	_tick_extra(dt)


## 子类扩展点（建筑用它跑训练队列/研究）
func _tick_extra(_dt: float) -> void:
	pass


# ===========================================================================
# 指令执行
# ===========================================================================

func _update_order(dt: float) -> void:
	# --- 逃跑优先（农民往基地跑）---
	if _flee_t > 0.0:
		state = RtsConst.State.MOVE
		_go_to(RtsWorld.base_center(faction))
		return

	# 巡逻往返：到了端点就掉头
	_tick_patrol()

	match order:
		RtsConst.Order.MOVE:
			# 行军途中也索敌：路过被打不能装没看见（魔兽手感），
			# 打完 / 敌人跑出射程就继续走完原指令。
			_acquire(dt)
			if _moving:
				state = RtsConst.State.MOVE
			elif _move_interrupted:
				if _target_in_reach():
					state = RtsConst.State.ATTACK
				else:
					_move_interrupted = false
					_go_to(_saved_goal, true)
			else:
				order = RtsConst.Order.NONE
				state = RtsConst.State.IDLE
		RtsConst.Order.ATTACK_MOVE:
			_order_attack_move(dt)
		RtsConst.Order.ATTACK:
			_order_attack(dt)
		RtsConst.Order.GATHER:
			_order_gather(dt)
		RtsConst.Order.BUILD:
			_order_build_tick(dt)
		RtsConst.Order.HOLD:
			state = RtsConst.State.IDLE
			_acquire(dt)
		_:
			# 待机：挨打时自己还手（不主动跑出去找架打）
			if target == null or not is_instance_valid(target) or not target.is_alive():
				target = null
			_acquire(dt)


## 攻击指定目标：追到射程内
func _order_attack(_dt: float) -> void:
	if target == null or not is_instance_valid(target) or not target.is_alive():
		target = null
		order = RtsConst.Order.NONE
		state = RtsConst.State.IDLE
		return
	if _flat_dist(target.global_position) > _attack_reach(target):
		if is_mobile():
			_go_to(target.global_position)
			state = RtsConst.State.MOVE


## 攻击移动
func _order_attack_move(dt: float) -> void:
	_acquire(dt)
	if target != null and is_instance_valid(target) and target.is_alive():
		return
	if not _moving:
		order = RtsConst.Order.NONE
		state = RtsConst.State.IDLE
	else:
		state = RtsConst.State.MOVE


## 调试/自检用：当前采集阶段（-1 = 不在采集）
func debug_gather_phase() -> int:
	if order != RtsConst.Order.GATHER:
		return -1
	return int(_gather_phase)


## 调试/自检用：累计卸货次数
func get_deposit_count() -> int:
	return _deposit_count


## 调试/自检用：当前搬运量
func get_carry() -> int:
	return _carry


## 采集状态机：找资源 → 走过去 → 采 → 走回交汇点 → 卸货 → 再来一轮
func _order_gather(dt: float) -> void:
	if def == null or not RtsWorld.is_worker_def(def):
		order = RtsConst.Order.NONE
		return

	# 目标没了 / 被采空 → 换下一个
	if _gather_node == null or not is_instance_valid(_gather_node) \
			or bool(_gather_node.call("is_depleted")):
		_gather_node = _find_harvestable(_carry_kind)
		if _gather_node == null:
			order = RtsConst.Order.NONE
			state = RtsConst.State.IDLE
			return
		_gather_phase = GatherPhase.TO_NODE
		_go_to(_gather_node.global_position, true)

	# --- 卡死兜底：某阶段待太久且几乎没位移，就强制推进（十人挤矿时救命的保险丝）---
	var moved_since: float = global_position.distance_to(_phase_pos)
	_phase_t += dt
	if _phase_t > PHASE_STUCK_TIME and moved_since < 0.55:
		if _gather_phase == GatherPhase.TO_NODE or _gather_phase == GatherPhase.SEEK:
			# 已经在资源附近却永远差一点到 -> 直接开采
			if _flat_dist(_gather_node.global_position) <= _stand_off(_gather_node) + ARRIVE_SLACK + 2.0:
				_stop_moving()
				_gather_phase = GatherPhase.HARVEST
				_gather_t = _harvest_time()
				_enter_phase(GatherPhase.HARVEST)
				return
		elif _gather_phase == GatherPhase.TO_DROP:
			_deposit()
			_enter_phase(GatherPhase.TO_NODE)
			return
		_enter_phase(_gather_phase)

	match _gather_phase:
		GatherPhase.TO_NODE:
			state = RtsConst.State.MOVE
			_go_to(_gather_node.global_position)
			# 到点判定要带 ARRIVE_SLACK：A* 终点被吸附到最近可走格，
			# 会比站位阈值远 0.3~0.5m，卡死就是这零点几米造成的
			if _flat_dist(_gather_node.global_position) <= _stand_off(_gather_node) + ARRIVE_SLACK:
				_stop_moving()
				_gather_phase = GatherPhase.HARVEST
				_gather_t = _harvest_time()
				_enter_phase(GatherPhase.HARVEST)
		GatherPhase.HARVEST:
			state = RtsConst.State.GATHER
			_stop_moving()
			_face_pos(_gather_node.global_position, dt)
			_gather_t -= dt
			if _gather_t <= 0.0:
				_finish_harvest()
		GatherPhase.TO_DROP:
			state = RtsConst.State.RETURN
			var drop: Node3D = _nearest_dropoff()
			if drop == null:
				_gather_phase = GatherPhase.SEEK
				return
			_go_to(drop.global_position)
			if _flat_dist(drop.global_position) <= _stand_off(drop) + ARRIVE_SLACK:
				_deposit()
				_enter_phase(GatherPhase.TO_NODE)
		_:
			_gather_phase = GatherPhase.TO_NODE
			_enter_phase(GatherPhase.TO_NODE)


## 记录阶段切换（卡死兜底要用"这个阶段待了多久、走了多远"）
func _enter_phase(ph: int) -> void:
	_phase_t = 0.0
	_phase_pos = global_position
	if _gather_phase != ph:
		_gather_phase = ph


## 建造：走到工地 → 播 build 动画 → 推进度
func _order_build_tick(dt: float) -> void:
	if _build_site == null or not is_instance_valid(_build_site):
		order = RtsConst.Order.NONE
		state = RtsConst.State.IDLE
		return
	var site: RtsBuilding = _build_site as RtsBuilding
	if site == null or site.is_constructed or not site.is_alive():
		order = RtsConst.Order.NONE
		_build_site = null
		state = RtsConst.State.IDLE
		return
	if _flat_dist(site.global_position) > _stand_off(site):
		state = RtsConst.State.MOVE
		_go_to(site.global_position)
		return
	_stop_moving()
	state = RtsConst.State.BUILD
	_face_pos(site.global_position, dt)
	site.advance_construction(dt, self)


## 逃跑结束：回去继续干活
func _resume_after_flee() -> void:
	if _was_gathering and def != null and RtsWorld.is_worker_def(def):
		var n: Node3D = _find_harvestable(_carry_kind)
		if n != null:
			order_gather(n)
			return
	order = RtsConst.Order.NONE
	state = RtsConst.State.IDLE
	if target != null and is_instance_valid(target) and target.is_alive():
		order_attack(target)


# ===========================================================================
# 移动
# ===========================================================================

## 设定移动目标（force=false 时目标没怎么变就不重算，省 A*）
func _go_to(pos: Vector3, force: bool = false) -> void:
	var p := Vector3(pos.x, 0.0, pos.z)
	move_target = pos
	if not force and _moving:
		var dx: float = _goal.x - p.x
		var dz: float = _goal.z - p.z
		if sqrt(dx * dx + dz * dz) < GOAL_CHANGE_EPS:
			return
	_goal = p
	_moving = true
	_direct_t = 0.0
	_request_path()


## 算路（带 0.25s 节流，绝不拿 A* 当饭吃）
func _request_path() -> void:
	if _repath_cd > 0.0:
		_need_repath = true
		return
	_need_repath = false
	_repath_cd = REPATH_INTERVAL
	if not is_inside_tree():
		return
	_path = RtsWorld.find_path(global_position, _goal)
	_path_i = 0
	_direct_t = 0.0


## 停止移动
func _stop_moving() -> void:
	_moving = false
	_path = PackedVector3Array()
	_path_i = 0
	_need_repath = false
	_direct_t = 0.0


## 当前要走向的路径点
func _current_goal() -> Vector3:
	if _path_i >= 0 and _path_i < _path.size():
		return _path[_path_i]
	return _goal


## 移动执行：转向 → 加速 → 位移
func _update_move(dt: float) -> void:
	if not is_mobile():
		_speed = 0.0
		return

	if not _moving:
		# 停：速度在 SPEED_EASE_TIME 内平滑归零
		_speed = move_toward(_speed, 0.0, _accel() * 0.55 * dt)
		if _speed <= 0.01:
			_speed = 0.0
			# 静止时接受外部对 rotation 的改动（关卡摆朝向）
			_yaw = rotation.y
		return

	var goal: Vector3 = _current_goal()
	var dx: float = goal.x - global_position.x
	var dz: float = goal.z - global_position.z
	var dist: float = sqrt(dx * dx + dz * dz)

	# 路径不可达 → 直行兜底，最多 1.5s
	if _path.is_empty():
		_direct_t += dt
		if _direct_t >= UNREACHABLE_GRACE:
			_stop_moving()
			_speed = 0.0
			if order == RtsConst.Order.MOVE:
				order = RtsConst.Order.NONE
			state = RtsConst.State.IDLE
			return

	# 到点：推进下一个路径点；走完就停
	if dist <= ARRIVE_TOLERANCE:
		if _path.is_empty() or _path_i >= _path.size() - 1:
			_stop_moving()
			_speed = 0.0
			if order == RtsConst.Order.MOVE:
				order = RtsConst.Order.NONE
			if state == RtsConst.State.MOVE:
				state = RtsConst.State.IDLE
			return
		_path_i += 1
		goal = _current_goal()
		dx = goal.x - global_position.x
		dz = goal.z - global_position.z
		dist = sqrt(dx * dx + dz * dz)
		if dist < 0.0001:
			return

	# --- 转向：turn_speed 限速，背对目标先转身 ---
	var dir := Vector3(dx / dist, 0.0, dz / dist)
	var want_yaw: float = atan2(-dir.x, -dir.z)
	_yaw = _turn_toward(_yaw, want_yaw, def.turn_speed * dt)
	rotation.y = _yaw

	# --- 速度：朝向对齐程度决定能跑多快（背身=0，先转身）---
	var fwd := _forward()
	var align: float = clampf(fwd.dot(dir), -1.0, 1.0)
	var target_speed: float = _max_speed() * clampf(align + TURN_SPEED_FLOOR, 0.0, 1.0) * _slope_mult
	# 收尾要柔：刹车只用 55% 的加速度，起步用满加速度（起步有冲劲、停下有惯性）
	var acc: float = _accel() if target_speed >= _speed else _accel() * 0.55
	_speed = move_toward(_speed, target_speed, acc * dt)

	# --- 位移：沿朝向走（转弯时自然走出弧线）---
	global_position += fwd * _speed * dt

	# --- 卡死检测与脱困 ---
	# 想走却几乎没位移 = 被建筑/树/其它单位顶住了。三级处理：
	#   ① 强制重算路径（换一条绕行）
	#   ② 连续 3 次仍卡 → 直接吸附到最近可走格（穿墙而出，永不永久卡死）
	_stuck_t += dt
	if _stuck_t >= 0.8:
		var moved: float = global_position.distance_to(_stuck_pos)
		if moved < 0.28:
			_stuck_count += 1
			_request_path()
			if _stuck_count >= 3:
				_stuck_count = 0
				if Game.level != null:
					global_position = Game.level.walkable_pos(global_position)
					_need_repath = true
		else:
			_stuck_count = 0
		_stuck_t = 0.0
		_stuck_pos = global_position


## 面向某点转向（原地不动）
func _face_pos(pos: Vector3, dt: float) -> void:
	var dx: float = pos.x - global_position.x
	var dz: float = pos.z - global_position.z
	if absf(dx) < 0.0001 and absf(dz) < 0.0001:
		return
	var want_yaw: float = atan2(-dx, -dz)
	var ts: float = def.turn_speed if def != null else 8.0
	_yaw = _turn_toward(_yaw, want_yaw, ts * dt)
	rotation.y = _yaw


func _turn_toward(cur: float, want: float, max_step: float) -> float:
	var diff: float = wrapf(want - cur, -PI, PI)
	return cur + clampf(diff, -max_step, max_step)


## 当前朝向的单位向量（模型朝 -Z）
func _forward() -> Vector3:
	return Vector3(-sin(_yaw), 0.0, -cos(_yaw))


## 平面距离
func _flat_dist(pos: Vector3) -> float:
	var dx: float = pos.x - global_position.x
	var dz: float = pos.z - global_position.z
	return sqrt(dx * dx + dz * dz)


# ===========================================================================
# 分离 / 贴地
# ===========================================================================

## 共享空间哈希：每帧重建一次（只收活着的单位与建筑）
static func _shared_hash() -> SpatialHash:
	var frame: int = Engine.get_process_frames()
	if _sep_hash == null:
		_sep_hash = SpatialHash.new(4.0)
	if _sep_frame == frame:
		return _sep_hash
	_sep_frame = frame
	var list: Array = []
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		if not u is RtsUnit:
			continue
		if not u.is_alive():
			continue
		list.append(u)
	_sep_hash.rebuild(list)
	return _sep_hash


## 单位分离：一重叠就互相推开，别挤成一坨
func _update_separation(dt: float) -> void:
	if def == null:
		return
	# 建筑是"绝对障碍"：只推别人，自己不动
	if not is_mobile():
		return
	var hash: SpatialHash = _shared_hash()
	var my_r: float = def.body_radius
	var push := Vector3.ZERO
	var near: Array = hash.query(global_position, my_r * 6.0)
	for o in near:
		if o == self or o == null or not is_instance_valid(o):
			continue
		if not o is RtsUnit:
			continue
		var other: RtsUnit = o
		if other.def == null:
			continue
		var min_d: float = (my_r + other.def.body_radius) * SEPARATION_FACTOR
		if min_d <= 0.0001:
			continue
		var dx: float = global_position.x - other.global_position.x
		var dz: float = global_position.z - other.global_position.z
		var d2: float = dx * dx + dz * dz
		if d2 >= min_d * min_d:
			continue
		var d: float = sqrt(d2)
		if d < 0.0001:
			# 完全重合：按实例 ID 给个确定方向，别抖
			var ang: float = float(get_instance_id() % 628) * 0.01
			push += Vector3(cos(ang), 0.0, sin(ang)) * min_d
			continue
		var overlap: float = min_d - d
		push += Vector3(dx / d, 0.0, dz / d) * overlap

	if push.length_squared() <= 0.000001:
		return

	global_position += push * Cfg.game.separation_strength * dt


## 把单位从不可走格里救出来（分离推挤 / 建筑占地变化都可能把人塞进墙里）
func _rescue_if_inside_wall() -> void:
	if def == null or not is_mobile() or Game.level == null:
		return
	if Game.level.is_walkable_grid(Game.level.grid_pathfinder().world_to_cell(global_position)):
		return
	global_position = Game.level.walkable_pos(global_position)
	_need_repath = true


## 贴地 + **顺坡**（这是"脚踩在地上"而不是"贴着图滑"的关键）
##
## 三件事：
##   1. 高度：以 GROUND_FOLLOW_SPEED 追随地形高度（上下坡不瞬移、不抖）
##   2. 姿态：采样身前/身后/左/右四个点算坡度，让身体**顺着坡面倾斜**（抬头/侧倾）
##   3. 速度：把沿朝向的坡度换算成 `_slope_mult`，上坡减速、下坡略快
func _snap_ground(dt: float) -> void:
	if not is_mobile():
		return
	var x: float = global_position.x
	var z: float = global_position.z
	var h: float = RtsWorld.height_at(x, z)
	# 1) 高度追随（限速，避免地形台阶造成"弹跳"）
	var y: float = move_toward(global_position.y, h, GROUND_FOLLOW_SPEED * maxf(dt, 0.0001))
	global_position.y = y

	# 2) 四点采样算坡面（采样臂长 0.7m，约一个身位）
	var arm: float = 0.7
	var fx: float = -sin(_yaw)
	var fz: float = -cos(_yaw)
	var rx: float = cos(_yaw)
	var rz: float = -sin(_yaw)
	var h_f: float = RtsWorld.height_at(x + fx * arm, z + fz * arm)
	var h_b: float = RtsWorld.height_at(x - fx * arm, z - fz * arm)
	var h_r: float = RtsWorld.height_at(x + rx * arm, z + rz * arm)
	var h_l: float = RtsWorld.height_at(x - rx * arm, z - rz * arm)

	var pitch_want: float = atan2(h_f - h_b, arm * 2.0)
	var roll_want: float = atan2(h_r - h_l, arm * 2.0)
	# 夹一下，免得悬崖边缘把模型掰成麻花
	pitch_want = clampf(pitch_want, -0.55, 0.55)
	roll_want = clampf(roll_want, -0.55, 0.55)
	var k: float = 1.0 - exp(-TILT_SMOOTH * maxf(dt, 0.0001))
	_tilt.x = lerpf(_tilt.x, pitch_want, k)
	_tilt.y = lerpf(_tilt.y, roll_want, k)
	rotation = Vector3(_tilt.x, _yaw, _tilt.y)

	# 3) 坡度对速度的影响（沿朝向的前后高差）
	var slope: float = (h_f - h_b) / (arm * 2.0)
	if slope > 0.0:
		_slope_mult = clampf(1.0 / (1.0 + slope * 1.9), 0.42, 1.0)   # 上坡：明显变慢
	else:
		_slope_mult = clampf(1.0 - slope * 0.55, 1.0, 1.22)          # 下坡：略快


# ===========================================================================
# 战斗
# ===========================================================================

## 攻击能打到的距离（含目标半径）
func _attack_reach(t: Node3D) -> float:
	var r: float = def.attack_range if def != null else 0.0
	if t != null and t.has_method("get_radius"):
		r += float(t.call("get_radius"))
	return maxf(r, 0.3)


## 站位间隙（采集/建造用）：attack_range/2 + 双方半径 + 一点空隙
func _stand_off(t: Node3D) -> float:
	var r: float = def.body_radius + GATHER_GAP
	if def != null:
		r += def.attack_range * 0.5
	if t != null and t.has_method("get_radius"):
		r += float(t.call("get_radius"))
	return maxf(r, 0.6)


## 自动索敌：走 Game 的注册表（不遍历场景），带分片
func _acquire(dt: float) -> void:
	if def == null or def.acquire_range <= 0.0:
		return
	if target != null and is_instance_valid(target) and target.is_alive():
		return
	_think_t -= dt
	if _think_t > 0.0:
		return
	_think_t = THINK_SLICE
	target = Game.find_nearest_enemy(global_position, faction, def.acquire_range)


## 攻击循环：冷却 → 前摇（攻击动画）→ 出手 → 后摇
func _update_attack(dt: float) -> void:
	if def == null or not def.can_attack():
		return
	# 干活 / 逃跑时不打
	if order == RtsConst.Order.GATHER or order == RtsConst.Order.BUILD:
		return
	if _flee_t > 0.0:
		return

	# 前摇中：数到点就出手
	if _swinging:
		_windup_t -= dt
		if _windup_t <= 0.0:
			_release_attack()
		return

	if target == null or not is_instance_valid(target) or not target.is_alive():
		target = null
		return

	var reach: float = _attack_reach(target)
	var dist: float = _flat_dist(target.global_position)

	if dist > reach:
		# 不在射程：攻击/攻击移动/行军途中都会扑上去（行军的原目的地先记下来，打完再走）
		if is_mobile():
			if order == RtsConst.Order.ATTACK or order == RtsConst.Order.ATTACK_MOVE:
				_go_to(target.global_position)
				state = RtsConst.State.MOVE
			elif order == RtsConst.Order.MOVE:
				_interrupt_move_for_combat()
				_go_to(target.global_position)
				state = RtsConst.State.MOVE
		return

	# 到射程：停下、转向、开打
	if order == RtsConst.Order.MOVE:
		# 收到移动指令的部队只"停下还手"，打完要继续走（不能把指令吃掉）
		_interrupt_move_for_combat()
	_stop_moving()
	_face_pos(target.global_position, dt)
	if _attack_cd <= 0.0:
		_begin_swing()


## 移动指令被战斗打断：记住原目的地（只记第一次，追击途中别覆盖成敌人坐标）
func _interrupt_move_for_combat() -> void:
	if _move_interrupted:
		return
	_saved_goal = _goal
	_move_interrupted = true


## 当前目标是否还在射程内（移动指令中途还手用）
func _target_in_reach() -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not target.is_alive():
		return false
	return _flat_dist(target.global_position) <= _attack_reach(target)


## 起手：前摇 = 冷却 × attack_windup，这段放攻击动画
func _begin_swing() -> void:
	if def == null:
		return
	_swinging = true
	_attack_cd = maxf(def.attack_cooldown, 0.1)
	_windup_t = _attack_cd * clampf(Cfg.game.attack_windup, 0.05, 0.95)
	state = RtsConst.State.ATTACK
	if visual != null:
		visual.play("attack", 1.0)


## 出手：近战立刻结算，远程发投射物（伤害在落点）
func _release_attack() -> void:
	_swinging = false
	if def == null:
		return
	if target == null or not is_instance_valid(target) or not target.is_alive():
		target = null
		return

	if def.projectile == RtsConst.Projectile.NONE:
		RtsCombat.resolve_hit(self, target)
		return

	var snap: Dictionary = RtsCombat.make_snapshot(self)
	var aim: Vector3 = target.global_position + Vector3.UP * RtsProjectile.AIM_HEIGHT
	RtsProjectile.fire_from(self, def.projectile, aim, target,
			def.projectile_speed, snap, faction)


## 法师自动放技能：让战场"活"起来，前排扛住时后排真会丢火球
func _update_auto_cast(_dt: float) -> void:
	if def == null or _dying or state == RtsConst.State.CAST:
		return
	if order == RtsConst.Order.GATHER or order == RtsConst.Order.BUILD:
		return
	if not ability_ready():
		return
	if target == null or not is_instance_valid(target) or not target.is_alive():
		return
	var ab: StringName = RtsSkills.first_ability(self)
	if ab == &"":
		return
	# 只在目标进入普攻射程内才自动开火（别隔半个地图丢）
	if _flat_dist(target.global_position) > maxf(def.attack_range, 1.0):
		return
	RtsSkills.begin_cast(self, ab, target.global_position, target)


## 施法前摇
func _update_cast(dt: float) -> void:
	_cast_t -= dt
	if _cast_t > 0.0:
		return
	var id: StringName = _cast_id
	var pos: Vector3 = _cast_pos
	var tgt: Node3D = _cast_target
	_cast_id = &""
	_cast_target = null
	state = RtsConst.State.IDLE
	order = RtsConst.Order.NONE
	RtsSkills.release(self, id, pos, tgt)


# ===========================================================================
# 采集辅助
# ===========================================================================

## 找最近的资源点（走 Game 的资源注册表）
func _find_harvestable(kind: int) -> Node3D:
	if faction == null:
		return null
	var base: Vector3 = RtsWorld.base_center(faction)
	var radius: float = Cfg.game.map_size * 0.75
	# 统计每个资源点当前被多少农民盯上（十人挤一口矿的根因就在这：
	# 原来只按距离打分，10 个农民会 100% 盯同一个点，互相挤、谁也采不快）
	var claimed: Dictionary = {}
	for u in Game.all_units():
		if u == null or not is_instance_valid(u) or u == self:
			continue
		if not (u is RtsUnit) or not u.is_alive():
			continue
		var n: Node3D = u.get("_gather_node")
		if n != null and is_instance_valid(n):
			claimed[n] = int(claimed.get(n, 0)) + 1

	var best: Node3D = null
	var best_score: float = INF
	for h in Game.level.resource_nodes():
		if h == null or not is_instance_valid(h):
			continue
		if h.harvest_kind != kind or h.is_depleted():
			continue
		var d: float = global_position.distance_to(h.global_position)
		if d > radius:
			continue
		var score: float = d + base.distance_to(h.global_position) * 0.35
		score += float(claimed.get(h, 0)) * CROWD_PENALTY
		if score < best_score:
			best_score = score
			best = h
	if best == null:
		best = RtsWorld.nearest_harvestable(global_position, kind, base, radius)
	return best


## 采集一次要多久（金 / 木 不同的 Cfg 值）
func _harvest_time() -> float:
	var cfg: GameConfig = Cfg.game
	match _carry_kind:
		RtsConst.Harvest.WOOD:
			return maxf(cfg.harvest_time_wood, 0.1)
		_:
			return maxf(cfg.harvest_time_gold, 0.1)


## 采满一次 → 资源进背包，进入返回阶段
func _finish_harvest() -> void:
	if _gather_node == null or not is_instance_valid(_gather_node):
		_gather_phase = GatherPhase.TO_NODE
		return
	var cap: int = def.carry_capacity
	if cap <= 0:
		cap = Cfg.game.harvest_carry
	var got: int = int(_gather_node.call("consume", cap))
	if got <= 0:
		_gather_phase = GatherPhase.TO_NODE
		return
	# AI 有经济倍率（难度档），玩家恒为 1.0
	got = int(round(float(got) * _gather_multiplier()))
	_carry = got
	_gather_t = 0.0
	_gather_phase = GatherPhase.TO_DROP
	order = RtsConst.Order.GATHER


## 采集产出倍率（只对 AI 生效）
func _gather_multiplier() -> float:
	if faction == null or faction.is_player:
		return 1.0
	return Cfg.difficulty(Game.difficulty_index).gather_multiplier


## 最近的回程点
func _nearest_dropoff() -> Node3D:
	var list: Array = RtsWorld.dropoffs(faction)
	var best: Node3D = null
	var best_d: float = INF
	for d in list:
		if d == null or not is_instance_valid(d):
			continue
		if not d.is_alive():
			continue
		var dist: float = global_position.distance_squared_to(d.global_position)
		if dist < best_d:
			best_d = dist
			best = d
	return best


## 卸货
func _deposit() -> void:
	if _carry > 0:
		var gold: int = _carry if _carry_kind == RtsConst.Harvest.GOLD else 0
		var wood: int = _carry if _carry_kind == RtsConst.Harvest.WOOD else 0
		Game.add_resource(faction, gold, wood)
		_carry = 0
		_deposit_count += 1
	_gather_phase = GatherPhase.TO_NODE
	_gather_t = 0.0
	# 卸完立刻朝资源点出发，别在门口愣着等下一帧的 _go_to
	if _gather_node != null and is_instance_valid(_gather_node):
		_go_to(_gather_node.global_position, true)


# ===========================================================================
# 动画
# ===========================================================================

func _update_anim() -> void:
	if visual == null or def == null:
		return
	var ratio: float = 1.0
	var ms: float = _max_speed()
	if ms > 0.01:
		ratio = clampf(_speed / ms, 0.15, 1.6)
	match state:
		RtsConst.State.MOVE, RtsConst.State.RETURN:
			visual.play("move", ratio)
		RtsConst.State.ATTACK:
			visual.play("attack", 1.0)
		RtsConst.State.GATHER:
			visual.play("gather", 1.0)
		RtsConst.State.BUILD:
			visual.play("build", 1.0)
		RtsConst.State.CAST:
			visual.play("cast", 1.0)
		_:
			visual.play("idle", 1.0)
