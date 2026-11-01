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
## 空路径重问间隔（秒）：被建筑/人群挤到无路时，按这个节奏重算，绝不"放弃即站死"
const PATH_RETRY_INTERVAL: float = 0.3
## 建造开工的有效判定余量（米）：站位阈值 + 这个余量内，且已经站在解析后的落点上，
## 就直接开工。建筑占地外扩 1 格时，"最近合法站位"常比阈值多出几厘米，
## 老逻辑会卡在 threshold 外侧反复起步 → 农民永远差一步、进度 0.00。
const BUILD_REACH_SLACK: float = 0.75
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
## walk 动画在 1x 播放时的"地面速度"（米/秒）。
## 实测：步兵 walk 一个周期的支撑相脚掌相对根节点后退 0.57m / 0.27s ≈ 2.0m/s。
## 单位实际移动 4.6m/s 时如果动画仍 1x，脚会明显在地上打滑（看起来像倒退跑）。
## 所以播放速度 = 实际速度 / 这个值，让脚掌线速度尽量贴着地面。
const WALK_STRIDE_SPEED: float = 2.0
## 尸体下沉时长（秒）与深度（米）
## 表现层脚本（死亡尘土 / 节流）走 preload，理由同 建筑.gd
const BUILD_FX := preload("res://代码/美术/建造表现.gd")
const SINK_TIME: float = 0.6
const SINK_DEPTH: float = 1.3
## 寻路目标变化多少米才值得重算
const GOAL_CHANGE_EPS: float = 0.6

# ---------------- 碰撞 / 贴墙（2026-10-18 HOUND 重写）----------------
## 身体净空安全系数：站立/扫掠判定用 radius × 这个值。
## 为什么是 0.98：格子宽 1m，紧贴不可走格的那一格**格心**净空恰好 = 0.5m；
## 用 1.0 会把整条“贴墙可行走带”判死（1 米窄道全废），用 0.9 又会真的穿墙 5cm。
const CLEAR_SAFETY: float = 0.98
## 扫掠采样步长（米）：0.15 约 1/3 身体半径，薄墙/墙角不会漏检
const SWEEP_STEP: float = 0.15
## 前方探测距离下限（米）：太短“到墙才反应”，太长会在窄口提前拐弯
const PROBE_MIN: float = 0.45
## 贴墙滑动的候选偏角（弧度）：±20/±40/±60/±80°，从小到大试（先尽量贴原方向）
const SLIDE_ANGLES: Array[float] = [0.35, 0.70, 1.05, 1.40]
## 分离位移的每秒上限（米/秒）：分离是软纠偏，不是推土机
const SEP_MAX_SPEED: float = 2.2
## 分离死区（米）：重叠小于这个值不推，避免站桩时的微抖
const SEP_DEADZONE: float = 0.02
## 被挤进不可走格后的“逐帧推出”速度（米/秒）—— 绝不瞬移
const PUSHOUT_SPEED: float = 3.2
## 连续多久推不出去才允许**一次**兜底吸附（秒）。自检会断言该计数为 0
const PUSHOUT_TIMEOUT: float = 1.2
## 推出目标的刷新间隔（秒）：nearest_standable 是环形搜索，不能每帧做
const PUSHOUT_RETARGET: float = 0.25
## 推出死区（米）：净空只差这么一点（1mm 级）时**不启动**逐帧推出。
## 为什么必须有：净空 0.489 vs 判据 0.49 的 1mm 落差，让“逐帧推出”每帧
## 都判定“已经最优、无法改善”，累计 1.2s 后触发兜底吸附 —— 这就是
## 某些运行里突然冒出几十次 snap 的来源。2cm 的死区让这种情况根本进不来。
const PUSHOUT_DEADBAND: float = 0.02
## 贴墙分离：净空小于（判据 + 这个值）时，分离位移先剪掉“往墙里”的分量，只留切向。
const SEP_WALL_ZONE: float = 0.30
## 到点后重新起步的滞回（米）：被挤开超过“落定距离 + 这个值”才重新走。
## 老实现是固定 ARRIVE_TOLERANCE+radius（0.85m），在人群里正好卡在分离推挤的
## 幅度上 → 推出去→走回来→再推出去，60Hz 进进出出。
const ARRIVE_RESTART_HYST: float = 0.9
## 拥挤让位：距目标多近算“已经在目标区”
const CROWD_RADIUS: float = 4.5
## 拥挤让位：目标区内被同伴堵住、连续这么久没有更靠近 → 就地停（不再挤）
const CROWD_PATIENCE: float = 0.9
## 拥挤判定：与同伴中心距小于（半径和 × 这个值）才算“被人堵着”
const CROWD_NEIGHBOR: float = 1.08

## 采集内部阶段
enum GatherPhase { SEEK = 0, TO_NODE = 1, HARVEST = 2, TO_DROP = 3 }

# ===========================================================================
# 共享空间哈希（全单位共用一份，见 Game.unit_hash()）
# ===========================================================================


# ===========================================================================
# 公开状态（条令 §6 冻结）
# ===========================================================================
var def: UnitDef = null
var faction: RtsFaction = null
var hp: float = 1.0
## 法力（只有定义里 max_mana > 0 的单位才有；UI 的"蓝条"读它）
var mana: float = 0.0
var state: int = RtsConst.State.IDLE
var is_selected: bool = false
var target: Node3D = null
var move_target: Vector3 = Vector3.ZERO

## 当前指令（RtsConst.Order）
var order: int = RtsConst.Order.NONE

# --- 控制权归属（由 代码/ai/控制权.gd 维护；取值见那里的 OWNER_* 常量）---
## 最后一条指令是谁下的：0=AI（人机/副官） 1=玩家命令执行中 2=宽限 3=停止/驻守 4=锁定
##
## 为什么状态放在单位身上而不是登记表里：单位死了这几个字段跟着消失，
## 不需要任何清理；登记表只是额外保存"命令组"（一批一起下令的人）。
var order_owner: int = 0
## 归属到期时刻（Game.elapsed 口径；0 = 无期限）。宽限/停止/驻守用它计时。
var order_until: float = 0.0
## 所属玩家命令组 id（0 = 不在任何组里）
var order_group: int = 0
## 这条指令下达的时刻（诊断 / 自检用）
var order_since: float = 0.0

## **警戒姿态**（只用于"头顶图标"和界面读法，不改变战斗逻辑）：
##   NONE / HOLD（驻守）/ OBSERVE（观察）/ PATROL（路径巡逻）
## 为什么单独记一个字段：驻守和观察在逻辑上是同一套（原地警戒），
## 但玩家要能一眼看出"这队兵是被我按了驻守还是点了观察"。
enum Guard { NONE = 0, HOLD = 1, OBSERVE = 2, PATROL = 3 }
var guard_mode: int = Guard.NONE

## 外观（模型/动画/闪白）
var visual: UnitVisual = null

# ===========================================================================
# 内部状态
# ===========================================================================
var _moving: bool = false
## 移动指令被"还手/追击"打断过：敌人清完后要继续走完原目的地
var _move_interrupted: bool = false
## **指令目的地**：下达移动/攻击移动那一刻记下的终点。
## 为什么要单独存一份：_goal 在追击时会被改成敌人坐标，打完了拿它"续行"就会跑偏
## （实测：攻击移动半路打一架，收场后跑到世界原点，离终点 46m）。
## 这个字段才是"玩家的原始命令"，任何战斗都不许覆盖它。
var _order_goal: Vector3 = Vector3.ZERO
## 被打断前的原目的地（追击时 _goal 会被改写成敌人坐标，所以必须单独存）
var _saved_goal: Vector3 = Vector3.ZERO
var _goal: Vector3 = Vector3.ZERO
var _path: PackedVector3Array = PackedVector3Array()
var _path_i: int = 0
var _repath_cd: float = 0.0
var _need_repath: bool = false
var _direct_t: float = 0.0
## 空路径重问计时（见 PATH_RETRY_INTERVAL）
var _retry_t: float = 0.0
## 空路径直行阶段的"无进展"计时与基准点（真的没挪才收工）
var _noprog_t: float = 0.0
var _noprog_pos := Vector3.ZERO
var _speed: float = 0.0
## 坡度对速度的倍率（上坡 <1，下坡 >1）
var _slope_mult: float = 1.0
## 身体贴合坡面的倾斜（x=俯仰, y=翻滚）
var _tilt: Vector2 = Vector2.ZERO
var _yaw: float = 0.0

## 贴墙滑动的方向记忆（-1 左 / +1 右 / 0 没在滑）：对称障碍前不会左右横跳
var _slide_side: int = 0
## 四面被堵住的累计时间（秒）
var _blocked_t: float = 0.0
## 被挤进不可走格的累计时间 / 推出目标 / 重取计时
var _pushout_t: float = 0.0
var _pushout_goal: Vector3 = Vector3.ZERO
var _pushout_has: bool = false
var _pushout_retarget: float = 0.0
## 目标点稳定化：本次请求点 / 解析出的可站立落点 / 是否有效 / 是否已到
var _goal_req: Vector3 = Vector3.ZERO
var _goal_valid: bool = false
var _arrived_goal: bool = false
## 落定时距目标的距离（重新起步的滞回基准）与拥挤让位计时
var _settle_dist: float = 0.0
var _crowd_t: float = 0.0
var _crowd_best: float = INF
## 寻路器缓存（RefCounted，关卡重建时 is_instance_valid 会失效，自动重取）
var _pf: GridPathfinder = null
## 调试计数（只累加，正式路径不打印；自检/日志读 debug_move_stats）
var dbg_slide_frames: int = 0
var dbg_blocked_frames: int = 0
var dbg_push_frames: int = 0
var dbg_repath_count: int = 0
## 拥挤让位次数（目标区被同伴占满 → 就地停）。**不是**卡死兜底，是正常的让位行为
var dbg_crowd_settles: int = 0
## 全局兜底吸附次数（**必须为 0**；非 0 就是“多帧无解”了，日志会指名道姓）
static var dbg_snap_fallbacks: int = 0

var _attack_cd: float = 0.0
var _windup_t: float = 0.0
var _swinging: bool = false
var _think_t: float = 0.0
## 新指令下达后的"免索敌"宽限期（秒）。见 order_move 的注释。
var _acquire_grace: float = 0.0

var _slow_mult: float = 1.0
var _slow_t: float = 0.0

# 技能
var _ability_cd: float = 0.0
var _cast_id: StringName = &""
var _cast_pos: Vector3 = Vector3.ZERO
var _cast_target: Node3D = null
var _cast_t: float = 0.0
## 施法结束后要恢复的指令（自动施法不能把部队的攻击/移动指令吃掉）
var _cast_return_order: int = RtsConst.Order.NONE

# 采集
var _gather_node: Node3D = null
var _gather_phase: int = GatherPhase.SEEK
var _gather_t: float = 0.0
## 交汇点缓存（见 _nearest_dropoff）：选中谁 + 那次查的是什么资源 + 还剩多久重查
var _dropoff_cache: Node3D = null
var _dropoff_cache_kind: int = -1
var _dropoff_scan_cd: float = 0.0
var _carry: int = 0
## 累计卸货次数（自检用）
var _deposit_count: int = 0
## 当前阶段已停留时间（秒）与阶段起点位置（卡死兜底用）
var _phase_t: float = 0.0
## 巡逻状态：A/B 两个端点 + 当前该去哪一端
var _patrol_active: bool = false
## 卡死检测：计时 / 上次采样位置 / 连续卡住次数
## 当前这一步要不要做"同伴避让"（收尾 2.2m 内关掉，见 _update_move）
var _avoid_ok: bool = true
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
## 正在修理的己方建筑（Order.REPAIR 用）
var _repair_target: Node3D = null
## 送资源要去的交汇点
var _return_drop: Node3D = null
## 上一次送达的数量（提示文案用）
var _carry_last_gold: int = 0
var _carry_last_wood: int = 0

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
	mana = def.max_mana
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
## 法力上限（没有法力返回 0）
func max_mana() -> float:
	return def.max_mana if def != null else 0.0


## 有没有法力条（UI 判据：没有就不画蓝条）
func has_mana() -> bool:
	return max_mana() > 0.001


## 补法力（神秘圣地的光环 / 自然回复都走这里，夹在上限内）
func add_mana(amount: float) -> void:
	if not has_mana() or amount <= 0.0:
		return
	mana = clampf(mana + amount, 0.0, max_mana())


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


## 这条命令的**原始目的地**（攻击移动 / 移动 / 巡逻那一头的点）。
## AI 的"到达判定 / 重复下令过滤"要用它：只看 order 的话，
## 单位已经在目标点旁边了还会被判成"没在执行"，于是每个思考周期重发一条。
func command_point() -> Vector3:
	return _order_goal


## 这条命令还在跑吗（不是 NONE / STOP）。命令组的"结束"判定用它。
func is_command_live() -> bool:
	return order != RtsConst.Order.NONE and order != RtsConst.Order.STOP


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
		var src: Vector3 = Vector3.ZERO
		if from != null and is_instance_valid(from):
			src = from.global_position
		visual.flash(src)
	if hp <= 0.0:
		hp = 0.0
		_die()
		return
	# ★ 挨打立刻还手（2026-11-01）：清掉"刚下过移动令"的免索敌宽限，
	#   并把攻击者锁成目标 —— 但只在**够得着**的时候锁，
	#   否则撤退中的兵会被一次流弹拽回去追人（手感比"不还手"更差）。
	if from != null and is_instance_valid(from):
		var tf: RtsFaction = from.get("faction") as RtsFaction
		if tf != null and faction != null and faction.is_enemy_of(tf):
			_acquire_grace = 0.0
			var reach: float = _attack_reach(from) * 1.5
			if _flat_dist(from.global_position) <= reach:
				if target == null or not is_instance_valid(target) or not target.is_alive():
					target = from
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
	# 死亡表现（SLEDGE）：小尘土每次都放（廉价、读感明确）；
	# 血雾/碎裂这种大特效走 BuildFx 的全局预算 —— 同屏一次死七八个也不会每个都炸一次。
	BUILD_FX.death_puff(global_position, col)
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
			# 下沉起手的一小股土（不刷屏：每个尸体只有这一下）
			BUILD_FX.dust(global_position, 4, 0.55, Color(0.54, 0.50, 0.44))
		return
	_sink_t -= dt
	var k: float = 1.0 - clampf(_sink_t / SINK_TIME, 0.0, 1.0)
	global_position.y = _sink_base_y - SINK_DEPTH * k
	# 一边沉一边略微压扁，读感更像"陷进地里/淡出"，而不是整体平移
	scale = Vector3(1.0, maxf(1.0 - 0.30 * k, 0.70), 1.0)
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
	_move_interrupted = false
	_cancel_swing()
	_patrol_active = false
	guard_mode = Guard.NONE
	_order_goal = Vector3(pos.x, 0.0, pos.z)
	_go_to(pos, true)


## 新指令打断当前挥砍：**必须同步清 `_swinging` / `_windup_t` / 攻击状态**。
##
## 玩家原话（2026-11-01）："单位在攻击时，如果下达新的指令，如移动，
## 单位会刚移动一下就被之前的攻击命令牵扯回去、继续攻击。"
##
## 三个原因叠在一起：
##   ① `order_move` 只把 target 置空，**没清 `_swinging`** ——
##      `_settle_state()` 看到"还在前摇"就继续把 state 顶成 ATTACK，
##      下一帧 `_release_attack()` 照旧结算旧目标；
##   ② 移动分支里的 `_acquire(dt)` 用满额索敌半径（步兵 11m）——
##      刚转身走两步就重新锁回同一个敌人，然后 `_stop_moving()` 站住继续打；
##   ③ 没有任何"刚下过令"的记忆，玩家点得再快也压不过索敌。
##
## 现在的口径：清挥砍 + 0.9 秒免索敌；移动途中索敌半径收到 45%；
## 挨打时仍然立刻还手（take_damage 里会清掉宽限并锁定攻击者）。
const ORDER_GRACE := 0.9


func _cancel_swing() -> void:
	_swinging = false
	_windup_t = 0.0
	_acquire_grace = ORDER_GRACE
	if state == RtsConst.State.ATTACK:
		state = RtsConst.State.IDLE


## 攻击指定目标
##
## ★ 右键点到**同队（盟友/自己人）**时，不是"开火"，而是退化成"走到那儿"。
##   以前这里不做敌我判定：光标在盟友身上显示红剑（已修），右键还会真的打友军 ——
##   队友 AI 的兵被玩家亲手打死，玩家只会觉得"这游戏在坑我"。
func order_attack(t: Node3D) -> void:
	if _dying or t == null:
		return
	var tf: RtsFaction = t.get("faction") as RtsFaction
	if tf != null and (faction == null or not faction.is_enemy_of(tf)):
		order_move(t.global_position)
		return
	order = RtsConst.Order.ATTACK
	target = t
	_flee_t = 0.0
	_move_interrupted = false
	_go_to(t.global_position, true)


## 攻击移动：路上遇敌就打，打完继续推进
func order_attack_move(pos: Vector3) -> void:
	if _dying:
		return
	order = RtsConst.Order.ATTACK_MOVE
	target = null
	_flee_t = 0.0
	_move_interrupted = false
	_patrol_active = false
	guard_mode = Guard.NONE
	_order_goal = Vector3(pos.x, 0.0, pos.z)
	_cancel_swing()
	_go_to(pos, true)


## 停止（清一切指令，原地待机）
func order_stop() -> void:
	if _dying:
		return
	order = RtsConst.Order.NONE
	target = null
	_gather_node = null
	_build_site = null
	_return_drop = null
	_flee_t = 0.0
	_swinging = false
	_patrol_active = false
	guard_mode = Guard.NONE
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
	guard_mode = Guard.HOLD


## 原地**观察**：战斗逻辑与驻守完全一致，只是头顶图标不同。
func order_observe() -> void:
	order_hold()
	guard_mode = Guard.OBSERVE


## 是否正在巡逻（路径）
func is_patrolling() -> bool:
	return _patrol_active and order == RtsConst.Order.ATTACK_MOVE


## 巡逻：在"当前位置 ↔ 目标点"之间往返，路上遇敌就打（ATTACK_MOVE 的往返版）
func order_patrol(pos: Vector3) -> void:
	if _dying:
		return
	_patrol_a = global_position
	_patrol_b = Vector3(pos.x, 0.0, pos.z)
	_patrol_active = true
	guard_mode = Guard.PATROL
	_patrol_at_b = true
	order = RtsConst.Order.ATTACK_MOVE
	target = null
	_swinging = false
	state = RtsConst.State.MOVE
	_move_interrupted = false
	_order_goal = _patrol_b
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


## 建造：**幂等** —— 同一个点上已经有人开工，就只是"加入"，不再扣钱、不再新建。
##
## 为什么必须幂等（两个实测 bug 都出在这）：
##   · 指令系统"放置建筑"时已经扣过一次钱，每个农民又各调一次 order_build，
##     老代码按人头重复扣 —— 1 个农民造 80 金的农场，实测扣了 160。
##   · 工地一旦落地 `is_buildable` 立刻变 false，第 2/3 个农民被拦下后**静默不动**。
## 所以顺序改成：先吸格（建筑网格）→ 找附近（水平 0.8m）同阵营/同类型/没完工的工地
##   → 有就加入；没有才走 钱够不够 → 地形能不能放 → 扣钱 → 落工地。整支队伍只扣一次钱。
##
## desired_yaw = 玩家/AI 期望朝向，落工地前一律过 `建筑网格.snap_yaw`（90° 档）。
## 朝向写在 `setup_construction` **之前**：RtsUnit.setup 会把 rotation.y 记进 _yaw，
## 建筑不可移动、之后没人再改它，所以工地和完工后的朝向必然一致。
func order_build(building_def: UnitDef, pos: Vector3, desired_yaw: float = 0.0) -> Node3D:
	if _dying or building_def == null:
		return null
	if def == null or not RtsWorld.is_worker_def(def) or faction == null:
		return null

	# ⓪ 先把落点吸到建筑网格（和寻路共用同一套格）：占地、寻路标记、工地坐标
	#    从此是同一个数，不会"看着在格子里、实际骑了半格"。
	var fp: Vector2i = building_def.footprint
	if fp == Vector2i.ZERO:
		fp = Vector2i(1, 1)
	pos = 建筑网格.snap_point(pos, fp)

	# ① 已经有人在同一个点开工：直接加入，绝不再扣一次钱
	var existing: Node3D = _find_open_site(building_def, pos)
	if existing != null and order_build_site(existing):
		return existing

	# ② 钱不够 / 位置不合法 → 给玩家提示，别默默失败
	if not Game.can_afford(faction, building_def.id):
		if faction.is_player:
			Game.toast("资源不足：%s" % building_def.display_name, Color(1, 0.5, 0.4))
		return null
	if not 建筑网格.can_place(pos, fp):
		if faction.is_player:
			Game.toast("这里不能建造", Color(1, 0.6, 0.35))
		return null
	# 真扣钱：同一块工地整支队伍只扣这一次
	if not Game.pay(faction, building_def.id):
		if faction.is_player:
			Game.toast("资源不足：%s" % building_def.display_name, Color(1, 0.5, 0.4))
		return null

	var site: RtsBuilding = RtsBuilding.new()
	site.name = "建造中_%s" % String(building_def.id)
	var parent: Node3D = RtsWorld.level()
	if parent == null:
		parent = get_parent() as Node3D
	if parent == null:
		return null
	parent.add_child(site)
	site.global_position = RtsWorld.ground(pos)
	site.rotation.y = 建筑网格.snap_yaw(desired_yaw)
	site.setup_construction(faction, building_def)
	RtsWorld.mark_footprint(site)
	Game.register(site)
	Game.unit_spawned.emit(site)

	_build_site = site
	order = RtsConst.Order.BUILD
	_flee_t = 0.0
	_swinging = false
	_go_to(site.global_position, true)
	return site


## 找 pos 附近（水平 0.8m 内）同阵营、同类型、还没完工的工地。
## 走 Game 的注册表而不是扫场景：工地本来就在 _units 里。
func _find_open_site(building_def: UnitDef, pos: Vector3) -> Node3D:
	if building_def == null or faction == null:
		return null
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var b := u as RtsBuilding
		if b == null or b.def == null:
			continue
		if b.faction != faction or b.def.id != building_def.id:
			continue
		if b.is_constructed or not b.is_alive():
			continue
		var dx: float = b.global_position.x - pos.x
		var dz: float = b.global_position.z - pos.z
		if dx * dx + dz * dz <= 0.8 * 0.8:
			return b
	return null


## 加入一块**已经在施工**的工地（第 2/3 个农民走这条）：
## 不新建、不扣费、也不再查地形 —— 活儿直接接着干，进度按人头叠加。
## 返回是否真的接上了（地块已完成 / 已被拆就返回 false）。
func order_build_site(site: Node3D) -> bool:
	if _dying or site == null or not is_instance_valid(site):
		return false
	if def == null or not RtsWorld.is_worker_def(def):
		return false
	var b := site as RtsBuilding
	if b == null or b.is_constructed or not b.is_alive():
		return false
	_build_site = site
	order = RtsConst.Order.BUILD
	_flee_t = 0.0
	_swinging = false
	_go_to(site.global_position, true)
	return true


## 修理一栋己方受损建筑（右键建筑 / 命令卡「修理」都走这里）。
## 规则见 RtsBuilding.repair_step：吃木材、按秒推进、多农民叠加。
func order_repair(building: Node3D) -> bool:
	if _dying or building == null or not is_instance_valid(building):
		return false
	if def == null or not RtsWorld.is_worker_def(def) or faction == null:
		return false
	var b := building as RtsBuilding
	if b == null or b.faction != faction or not b.can_repair():
		return false
	_repair_target = b
	_build_site = null
	order = RtsConst.Order.REPAIR
	target = null
	_swinging = false
	_flee_t = 0.0
	_go_to(b.global_position, true)
	return true


## 送资源回基地：走到最近的交汇点（大本营），把身上的东西**真的入账**。
## 以前这个接口是空的 —— 右键自家建筑，农民走过去站着，钱照旧挂在身上。
## 现在：到点 _deposit_carry()；送完如果还有采集点，自己回去接着采。
func order_return_res(drop: Node3D = null) -> void:
	if _dying or faction == null:
		return
	if def == null or not RtsWorld.is_worker_def(def):
		return
	var target_drop: Node3D = drop
	if not _alive_node(target_drop):
		target_drop = _nearest_dropoff()
	if target_drop == null:
		if faction.is_player:
			Game.toast("附近没有交汇点（大本营）", Color(1.0, 0.6, 0.35))
		return
	_return_drop = target_drop
	order = RtsConst.Order.RETURN_RES
	target = null
	_swinging = false
	_flee_t = 0.0
	_go_to(target_drop.global_position, true)


## 节点是否还活着（建筑/资源点都实现 is_alive；没有这个接口就别拦）
func _alive_node(n: Node3D) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if n.has_method("is_alive"):
		return bool(n.call("is_alive"))
	return true


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
	_cast_return_order = RtsConst.Order.NONE  # 玩家主动点的技能：放完就待机
	_stop_moving()
	if not RtsSkills.begin_cast(self, ability, pos, t):
		order = RtsConst.Order.NONE


## 由 RtsSkills 调用：进入技能冷却
func _start_ability_cooldown(t: float) -> void:
	_ability_cd = maxf(t, 0.0)


# ===========================================================================
# 每帧主循环
# ===========================================================================

## 性能计时（`--perf-long` 的探针读它）：所有单位的 `_process` 总共花了多少微秒。
## 为什么按"类静态"累计而不是每个单位打日志：100 个单位各打一行会把日志刷爆，
## 而"单位逻辑一共占了多少 CPU"才是要回答的问题。
static var dbg_usec: int = 0
static var dbg_order: int = 0
static var dbg_move: int = 0
static var dbg_sep: int = 0
static var dbg_ground: int = 0
## `_update_order` 的子项（用来回答"这 500ms/秒到底花在哪"）：
##   acquire = 自动索敌（Game.find_nearest_enemy）
##   gather  = 采集状态机
##   combat  = 攻击/攻击移动指令
##   patrol  = 巡逻往返检查
static var dbg_acquire: int = 0
static var dbg_gather: int = 0
static var dbg_combat: int = 0
static var dbg_atk: int = 0
static var dbg_amove: int = 0
static var dbg_goto: int = 0
static var dbg_sgoal: int = 0
static var dbg_goto_n: int = 0
## 指令分布普查（每次采样清零重算）：key = order 枚举值，value = 单位数
static var dbg_order_hist: Dictionary = {}


## 带计时的索敌（`_update_order` 里的调用点统一走它）
func _acquire_timed(dt: float, radius_scale: float = 1.0) -> void:
	var t0: int = Time.get_ticks_usec()
	_acquire(dt, radius_scale)
	RtsUnit.dbg_acquire += Time.get_ticks_usec() - t0

func _process(delta: float) -> void:
	if def == null:
		return
	var _t0: int = Time.get_ticks_usec()
	_process_inner(delta)
	RtsUnit.dbg_usec += Time.get_ticks_usec() - _t0


func _process_inner(delta: float) -> void:

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

	# ---- 分项计时（只给 性能探针 读；每帧多 6 次 ticks_usec，可忽略）----
	var _q0: int = Time.get_ticks_usec()
	_update_order(dt)
	RtsUnit.dbg_order += Time.get_ticks_usec() - _q0
	_q0 = Time.get_ticks_usec()
	_update_move(dt)
	_update_attack(dt)
	_update_auto_cast(dt)
	_settle_state()
	RtsUnit.dbg_move += Time.get_ticks_usec() - _q0
	_q0 = Time.get_ticks_usec()
	_update_separation(dt)
	_update_wall_pushout(dt)
	RtsUnit.dbg_sep += Time.get_ticks_usec() - _q0
	_q0 = Time.get_ticks_usec()
	_snap_ground(dt)
	_update_anim()
	RtsUnit.dbg_ground += Time.get_ticks_usec() - _q0


## 各种计时器
func _tick_timers(dt: float) -> void:
	_attack_cd = maxf(_attack_cd - dt, 0.0)
	if _acquire_grace > 0.0:
		_acquire_grace = maxf(_acquire_grace - dt, 0.0)
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
	# 法力自然回复（只有 max_mana > 0 的单位会走进来）
	if has_mana() and mana < max_mana():
		mana = minf(max_mana(), mana + def.mana_regen * dt)
	if _dropoff_scan_cd > 0.0:
		_dropoff_scan_cd -= dt
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
			# ★ 半径只给 45%：满额 11m 会让"撤退"变成"走两步又折回去打"，
			#   玩家感受就是"指令不跟手、被旧攻击牵扯"。
			_acquire_timed(dt, 0.45)
			if _moving:
				state = RtsConst.State.MOVE
			elif _move_interrupted:
				if _target_in_reach():
					state = RtsConst.State.ATTACK
				else:
					_move_interrupted = false
					# 续行只认原始命令的目的地（_saved_goal 可能被追击覆盖过）
					_go_to(_order_goal, true)
			else:
				order = RtsConst.Order.NONE
				state = RtsConst.State.IDLE
		RtsConst.Order.ATTACK_MOVE:
			var _a0: int = Time.get_ticks_usec()
			_order_attack_move(dt)
			RtsUnit.dbg_amove += Time.get_ticks_usec() - _a0
		RtsConst.Order.ATTACK:
			var _k0: int = Time.get_ticks_usec()
			_order_attack(dt)
			RtsUnit.dbg_atk += Time.get_ticks_usec() - _k0
		RtsConst.Order.GATHER:
			var _g0: int = Time.get_ticks_usec()
			_order_gather(dt)
			RtsUnit.dbg_gather += Time.get_ticks_usec() - _g0
		RtsConst.Order.BUILD:
			_order_build_tick(dt)
		RtsConst.Order.REPAIR:
			_order_repair_tick(dt)
		RtsConst.Order.RETURN_RES:
			_order_return_res_tick(dt)
		RtsConst.Order.HOLD:
			state = RtsConst.State.IDLE
			_acquire_timed(dt)
		_:
			# 待机：挨打时自己还手（不主动跑出去找架打）
			if target == null or not is_instance_valid(target) or not target.is_alive():
				target = null
			_acquire_timed(dt)


## **状态归约（每帧唯一出口）**：把前面各分支零散写的 `state` 收一次口。
##
## 为什么需要：`_begin_swing()` 会把 state 设成 ATTACK，但"待机单位自动还击"走的是
## `_update_order` 的 default 分支 —— 那里没人负责把 state 改回来。目标一死，
## 单位就永远举着刀站着（动画停在 attack），HUD 也会以为它还在打。
## 这里只做"没有事实支撑就必须退出"，绝不凭空造状态：
##   · 还在前摇 / 目标仍在射程内 → 保留 ATTACK
##   · 没在移动却挂着 MOVE   → 回 IDLE
func _settle_state() -> void:
	if _dying or state == RtsConst.State.DEAD or state == RtsConst.State.CAST:
		return
	if state == RtsConst.State.ATTACK:
		if _swinging or _target_in_reach():
			return
		state = RtsConst.State.IDLE
		return
	if state == RtsConst.State.MOVE and not _moving:
		state = RtsConst.State.IDLE


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
	if _moving:
		state = RtsConst.State.MOVE
		return
	# 打完了：接着走完**原始命令的目的地**。
	# 没有这段的话，半路打一架就 order = NONE 原地解散 —— 玩家下达的攻击移动
	# 会被一次遭遇战吃掉（_update_attack 停下还手时 _moving 已经是 false）。
	# 注意用 _order_goal 而不是 _saved_goal：_goal 在追击时已被改成敌人坐标。
	if _order_goal.length_squared() > 0.0001 and _flat_dist(_order_goal) > 1.2:
		_move_interrupted = false
		_go_to(_order_goal, true)
		state = RtsConst.State.MOVE
		return
	order = RtsConst.Order.NONE
	state = RtsConst.State.IDLE


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
	var d: float = _flat_dist(site.global_position)
	var stand: float = _stand_off(site)
	# ★ 开工判定不能只看"到工地中心的距离 > 站位阈值"。
	#   关卡把建筑占地外扩 1 格写进寻路网格，最近的合法站位天然就在
	#   `半宽 + 1 格 + 身体半径` 处，往往比 _stand_off 多出几厘米到几十厘米。
	#   老逻辑于是每帧：太远 → _go_to(工地中心) → 目标闩锁（它已经站在落点上）
	#   → 一步都不挪 → 下一帧还是"太远"。玩家看到：农民站在工地旁边发呆，进度 0.00。
	#   现在多给一条"已经站在解析后的落点上"的放行条件。
	var dg: float = _flat_dist(_goal) if _goal_valid else d
	var at_stand: bool = dg <= ARRIVE_TOLERANCE + 0.45
	if d > stand + BUILD_REACH_SLACK and not at_stand:
		state = RtsConst.State.MOVE
		_go_to(site.global_position)
		return
	_stop_moving()
	state = RtsConst.State.BUILD
	_face_pos(site.global_position, dt)
	site.advance_construction(dt, self)


## 修理：走到建筑旁 → 播 build 动画 → 让建筑按秒回血（木材由建筑侧扣）
func _order_repair_tick(dt: float) -> void:
	if _repair_target == null or not is_instance_valid(_repair_target):
		order = RtsConst.Order.NONE
		state = RtsConst.State.IDLE
		return
	var b := _repair_target as RtsBuilding
	if b == null or not b.is_alive() or not b.can_repair():
		order = RtsConst.Order.NONE
		_repair_target = null
		state = RtsConst.State.IDLE
		return
	var d: float = _flat_dist(b.global_position)
	var stand: float = _stand_off(b)
	var dg: float = _flat_dist(_goal) if _goal_valid else d
	var at_stand: bool = dg <= ARRIVE_TOLERANCE + 0.45
	if d > stand + BUILD_REACH_SLACK and not at_stand:
		state = RtsConst.State.MOVE
		_go_to(b.global_position)
		return
	_stop_moving()
	state = RtsConst.State.BUILD
	_face_pos(b.global_position, dt)
	b.repair_step(dt, self)


## 送资源：走到交汇点 → 入账 → 手上有活就回去接着干
func _order_return_res_tick(dt: float) -> void:
	if faction == null:
		order = RtsConst.Order.NONE
		state = RtsConst.State.IDLE
		return
	var drop: Node3D = _return_drop
	if not _alive_node(drop):
		drop = _nearest_dropoff()
		_return_drop = drop
		if drop == null:
			order = RtsConst.Order.NONE
			state = RtsConst.State.IDLE
			return
		_go_to(drop.global_position, true)
	if _flat_dist(drop.global_position) > _stand_off(drop) + ARRIVE_SLACK:
		state = RtsConst.State.MOVE
		_go_to(drop.global_position)
		return
	_stop_moving()
	state = RtsConst.State.RETURN
	_face_pos(drop.global_position, dt)
	var got: bool = _deposit_carry()
	_return_drop = null
	order = RtsConst.Order.NONE
	state = RtsConst.State.IDLE
	if got and faction != null and faction.is_player:
		Game.toast("资源已送达 → 金 +%d 木 +%d" % [_carry_last_gold, _carry_last_wood], Color(0.85, 0.92, 0.65))
	# 采集中被叫回来送钱的：送完自己回去接着采
	if _gather_node != null and is_instance_valid(_gather_node):
		_gather_phase = GatherPhase.TO_NODE
		_gather_t = 0.0
		order = RtsConst.Order.GATHER
		_go_to(_gather_node.global_position, true)


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

## 设定移动目标（force=false 时目标没怎么变就不重算，省 A*）。
##
## ★ 三段处理，缺一段就是“原地抽搐”：
##   ① 目标稳定化：目标压在建筑/墙里时解析成唯一、可站立的落点，
##      且只解析这一次（请求点没变就复用）—— 每帧重选落点是抖动的第一根因。
##   ② 到点闩锁：已经站在目标上就不许再 _moving = true。
##      老代码走到点 → stop → 下一帧调用方（采集/建造/追击）又 _go_to → start，
##      60Hz 反复起停：速度曲线锯齿、动画 walk/idle 闪、每 0.25s 白算一次全量 A*。
##   ③ 被挤开才重启：分离/推挤把单位挤离目标超过半个身位才重新走。
func _go_to(pos: Vector3, force: bool = false) -> void:
	RtsUnit.dbg_goto_n += 1
	var _t_go: int = Time.get_ticks_usec()
	_go_to_impl(pos, force)
	RtsUnit.dbg_goto += Time.get_ticks_usec() - _t_go


func _go_to_impl(pos: Vector3, force: bool = false) -> void:
	var want := Vector3(pos.x, 0.0, pos.z)
	move_target = pos
	var need_new: bool = force or not _goal_valid or want.distance_to(_goal_req) > GOAL_CHANGE_EPS
	if need_new:
		_goal_req = want
		_goal = _standable_goal(want)
		_goal_valid = true
		_arrived_goal = false
		_moving = true
		_direct_t = 0.0
		_request_path()
		return
	# 同一个目标：到点闩锁（被挤开一段距离才重新走）
	if _arrived_goal:
		# ★ 滞回基准取“落定时离目标多远 + ARRIVE_RESTART_HYST”，而不是固定 0.85m：
		#   人群让位落定的单位本来就在目标区 2~4m 处，固定阈值会让它每帧重新起步。
		var keep: float = maxf(ARRIVE_TOLERANCE + get_radius(), _settle_dist + ARRIVE_RESTART_HYST)
		if _flat_dist(_goal) <= keep:
			return
		_arrived_goal = false
	if _moving:
		return
	_moving = true
	_direct_t = 0.0
	_request_path()


## 把“调用方要去的点”解析成唯一、稳定、可站立的落点。
##
## · 目标本身能站 → 原样返回（点哪走哪，不偷换位置）；
## · 目标压在建筑/墙里 → 在目标周围搜可站立点，评分 = 到目标距离 + 0.6×到本单位距离：
##   0.6 这一项让“从不同方向来的单位自然分散到建筑的不同侧”（多单位共点不抢同一格），
##   同时整个函数是纯函数（目标 + 本单位位置固定 → 结果固定），所以不会逐帧变化。
func _standable_goal(want: Vector3) -> Vector3:
	var pf := _pathfinder()
	if pf == null:
		return want
	var _t_sg: int = Time.get_ticks_usec()
	var r: float = get_radius() * CLEAR_SAFETY
	# 落点必须留出 GOAL_MARGIN 的余量：站定后还要被同伴推、被分离挤，
	# 净空刚好 0.5 的落点一推就掉进阻挡判据，然后和 wall_pushout 对拉。
	if pf.is_standable(want, r + GridPathfinder.GOAL_MARGIN):
		return want
	RtsUnit.dbg_sgoal += Time.get_ticks_usec() - _t_sg
	return pf.standable_near(want, global_position, r, GridPathfinder.GOAL_MARGIN)


## 算路（带 0.25s 节流，绝不拿 A* 当饭吃）
func _request_path() -> void:
	if _repath_cd > 0.0:
		_need_repath = true
		return
	# ★ 每帧算路的配额（见 RtsWorld.take_path_budget）。
	#   预算用完就不消耗冷却、把请求挂起，下一帧 _tick_timers 自然重试 ——
	#   这样"十几个单位同一帧各自算路"不会把某一帧撑爆。
	if not RtsWorld.take_path_budget():
		_need_repath = true
		return
	_need_repath = false
	_repath_cd = REPATH_INTERVAL
	dbg_repath_count += 1
	if not is_inside_tree():
		return
	# ★ 被同伴反复堵住时，目标点做一次**侧向让位**。
	#
	# 为什么需要：寻路网格是静态的（单位不是障碍），十个人走同一个门洞时，
	# 每个人算出来的路完全一样 → 谁也不让谁 → 每 0.8s 重算一次同样的路。
	# 让位不是"随机乱走"：垂直于目标方向平移 1.2~3.7m，且按卡住次数左右交替，
	# 这样第一个人先拐、后面的人跟着拐，队伍自然散开成两列。
	var goal: Vector3 = _goal
	if _stuck_count >= 2:
		var to: Vector3 = _goal - global_position
		to.y = 0.0
		if to.length() > 0.3:
			var side := Vector3(-to.z, 0.0, to.x).normalized()
			if _stuck_count % 2 == 0:
				side = -side
			goal = _goal + side * (1.2 + 0.5 * float(mini(_stuck_count, 5)))
	# 走 RtsWorld：它负责把 y 贴到地形高度；净空半径由 GridPathfinder.agent_radius（0.5m）兜住
	_path = RtsWorld.find_path(global_position, goal)
	_path_i = 0
	# 注意：这里**不重置** _direct_t。空路径时会被每 0.3s 重问一次，
	# 若每次都清零，"1.5s 无解收工"的计时永远不会到，单位会一直朝墙直行。
	_retry_t = 0.0


## 停止移动
func _stop_moving() -> void:
	_moving = false
	_path = PackedVector3Array()
	_path_i = 0
	_need_repath = false
	_direct_t = 0.0
	_retry_t = 0.0
	_noprog_t = 0.0
	_noprog_pos = global_position
	_blocked_t = 0.0
	_slide_side = 0


## 当前要走向的路径点
func _current_goal() -> Vector3:
	if _path_i >= 0 and _path_i < _path.size():
		return _path[_path_i]
	return _goal


## 移动执行：**先算“这一帧真的能走的方向”，再沿它走**。
##
## 老实现的致命处：位移沿 _forward()（朝向）走，而朝向有 turn_speed 延迟。
## 路径拐弯后身体还要 0.2~0.4s 才转过去，这段时间它一直在**往墙里怼**
## （4.6m/s × 0.4s ≈ 1.8m），然后 _rescue_if_inside_wall 把它 snap 回可走格 ——
## 这就是“进进出出”的机械根因。
## 现在：先做扫掠（身体圆沿方向前进的采样），前方受阻就沿切线滑动（带方向记忆），
## 位移永远沿**校验过的方向**；朝向只负责“看起来朝哪”，不再决定往哪走。
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

	# 路径不可达 → 直行兜底 + **持续重问**，绝不"1.5s 没路就永久站死"
	# 老实现：空路径只直行 1.5s，然后 order=NONE / state=IDLE。
	# 玩家看到的就是"被建筑挡一下，从此不动了"—— 因为空路径没有任何重试入口
	# （_blocked_t 只在 _steer 四面被堵时才涨；能被推开的情况它永远是 0）。
	# 现在：每 0.3s 无条件重问一次寻路；收工条件改成"**真的** 1s 没挪动"，
	# 而不是一个固定计时器 —— 目标不可达时也要先走到最近的可站位置。
	if _path.is_empty():
		_direct_t += dt
		_retry_t += dt
		if _retry_t >= PATH_RETRY_INTERVAL:
			_retry_t = 0.0
			_request_path()
		_noprog_t += dt
		if global_position.distance_to(_noprog_pos) >= 0.2:
			_noprog_pos = global_position
			_noprog_t = 0.0
		if _noprog_t >= 1.0:
			_stop_moving()
			_speed = 0.0
			if order == RtsConst.Order.MOVE:
				order = RtsConst.Order.NONE
			state = RtsConst.State.IDLE
			return

	# 到点：推进下一个路径点；走完就停
	if dist <= ARRIVE_TOLERANCE:
		if _path.is_empty() or _path_i >= _path.size() - 1:
			_settle()
			return
		_path_i += 1
		goal = _current_goal()
		dx = goal.x - global_position.x
		dz = goal.z - global_position.z
		dist = sqrt(dx * dx + dz * dz)
		if dist < 0.0001:
			return

	# --- 0. 拥挤让位：目标区被人占满 + 0.9s 没能更靠近 → 就地停 ---
	# 这一条替代“到了→被挤开→再走→再被挤开”的 60Hz 往复。
	# 判据全是确定性的（距离 + 计时），没有随机、没有瞬移。
	if _tick_crowd(dt):
		return

	var dir := Vector3(dx / dist, 0.0, dz / dist)
	# 收尾 2.2m 内**关掉同伴避让**：最后一步必须直着走到落点，
	# 否则绕人的一点点侧移会让它停在离目标 1.6m 的地方（寻路自检 ③ 抓到过）。
	_avoid_ok = dist > 2.2

	# --- 1. 扫掠 + 贴墙滑动：拿到这一帧真正能走的方向 ---
	var step: float = _speed * dt
	var probe: float = maxf(step, PROBE_MIN)
	var mv: Vector3 = _steer(dir, probe)
	if mv == Vector3.ZERO:
		# 四面被堵：绝不硬顶（硬顶就是用身体撞墙）。停下 + 重算路径，等下一帧。
		dbg_blocked_frames += 1
		_speed = move_toward(_speed, 0.0, _accel() * dt)
		_blocked_t += dt
		if _blocked_t >= 0.15:
			_request_path()
		_yaw = _turn_toward(_yaw, atan2(-dir.x, -dir.z), def.turn_speed * dt)
		rotation.y = _yaw
		# 离路点只剩不到一个身位就当到了（否则会在墙角“看不见的 5cm”上永久卡住）
		if dist <= 0.6 and (_path.is_empty() or _path_i >= _path.size() - 1):
			_settle()
		return
	_blocked_t = 0.0
	if mv != dir:
		dbg_slide_frames += 1

	# --- 2. 朝向追 mv（贴墙时朝切线，身体不会正对着墙）---
	var want_yaw: float = atan2(-mv.x, -mv.z)
	_yaw = _turn_toward(_yaw, want_yaw, def.turn_speed * dt)
	rotation.y = _yaw

	# --- 3. 速度：朝向对齐程度决定能跑多快（背身=先转身）---
	var fwd := _forward()
	var align: float = clampf(fwd.dot(mv), -1.0, 1.0)
	var target_speed: float = _max_speed() * clampf(align + TURN_SPEED_FLOOR, 0.0, 1.0) * _slope_mult
	# 收尾要柔：刹车只用 55% 的加速度，起步用满加速度（起步有冲劲、停下有惯性）
	var acc: float = _accel() if target_speed >= _speed else _accel() * 0.55
	_speed = move_toward(_speed, target_speed, acc * dt)

	# --- 4. 位移：沿**校验过的方向**走（不是沿朝向）---
	global_position += mv * (_speed * dt)

	# --- 5. 卡死检测：只用来“重算路径”，**绝不再 snap**（snap 只在多帧无解时兜底一次）---
	_stuck_t += dt
	if _stuck_t >= 0.8:
		if global_position.distance_to(_stuck_pos) < 0.28:
			_stuck_count += 1
			_request_path()
		else:
			_stuck_count = 0
		_stuck_t = 0.0
		_stuck_pos = global_position


## 就地落定：记住落定距离（重新起步的滞回基准），清掉移动状态。
func _settle() -> void:
	_settle_dist = _flat_dist(_goal)
	_crowd_t = 0.0
	_crowd_best = INF
	_stop_moving()
	_speed = 0.0
	_arrived_goal = true
	if order == RtsConst.Order.MOVE:
		order = RtsConst.Order.NONE
	if state == RtsConst.State.MOVE:
		state = RtsConst.State.IDLE


## 拥挤让位：在目标区被同伴堵住、连续 CROWD_PATIENCE 秒没有更靠近 → 就地落定。
##
## 为什么必须放在移动层：12 个人同一个落点，物理上只有一个能站上去；
## 老实现让剩下的 11 个永远“走 → 被挤开 → 再走”，这就是玩家看到的进进出出。
## 现在它们会像真人一样在目标区找位置站住（分离负责把它们分开到 ≥1.15m）。
## 只在**真的有人贴着自己**时才启用，路过人群、绕建筑都不会被误判成“到了”。
func _tick_crowd(dt: float) -> bool:
	if def == null or _arrived_goal:
		return false
	var dg: float = _flat_dist(_goal)
	if dg > CROWD_RADIUS or not _crowded():
		_crowd_t = 0.0
		_crowd_best = INF
		return false
	if dg < _crowd_best - 0.12:
		_crowd_best = dg
		_crowd_t = 0.0
		return false
	_crowd_t += dt
	if _crowd_t < CROWD_PATIENCE:
		return false
	dbg_crowd_settles += 1
	_settle()
	return true


## 身边 1.08 个“半径和”内有没有同伴（= 正在被挤）
func _crowded() -> bool:
	var hash: SpatialHash = _shared_hash()
	var my_r: float = def.body_radius
	for o in hash.query(global_position, (my_r + 1.2) * CROWD_NEIGHBOR + 0.5):
		if o == self or o == null or not is_instance_valid(o) or not o is RtsUnit:
			continue
		var other: RtsUnit = o
		if other.def == null or not other.is_mobile():
			continue
		var dx: float = global_position.x - other.global_position.x
		var dz: float = global_position.z - other.global_position.z
		var need: float = (my_r + other.def.body_radius) * CROWD_NEIGHBOR
		if dx * dx + dz * dz < need * need:
			return true
	return false


# ===========================================================================
# 碰撞几何（扫掠 / 贴墙滑动 / 逐帧推出）
# ===========================================================================

## 取寻路器（缓存；关卡重建时 RefCounted 失效会自动重取）
func _pathfinder() -> GridPathfinder:
	if _pf == null or not is_instance_valid(_pf):
		_pf = RtsWorld.pathfinder()
	return _pf






## 面向某点转向（原地不动）
##
## ★ **建筑一律不转身**（2026-11-01 玩家报的"箭塔攻击时会移动朝向"）：
##   建筑的朝向是"盖的时候定的"（`建筑网格.DEFAULT_YAW`，占地是 1m 网格上的矩形），
##   开火时转一下身体，占地和视觉立刻错位 —— 看起来就是"塔在原地扭"。
##   塔的"朝向表现"交给投射物 / 箭塔模型自带的瞄准件，不靠整栋楼转。
##   所以这里第一句就挡掉非移动单位（is_mobile() = kind == UNIT）。
func _face_pos(pos: Vector3, dt: float) -> void:
	if not is_mobile():
		return
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


## 当前朝向的单位向量（模型朝 -Z）
func _forward() -> Vector3:
	return Vector3(-sin(_yaw), 0.0, -cos(_yaw))


## 平面距离


## 平面距离
func _flat_dist(pos: Vector3) -> float:
	var dx: float = pos.x - global_position.x
	var dz: float = pos.z - global_position.z
	return sqrt(dx * dx + dz * dz)


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

	# ★ 站着不动时**跳过坡面采样**（2026-11-01 性能优化）。
	#
	# 坡面这一趟要 4 次 `RtsWorld.height_at()`，而 RTS 里绝大多数单位大半时间都在
	# 站着（采集/待命/守家）。人没动、朝向也没变，坡面解析结果就是同一组数 ——
	# 重算纯属白烧。实测 `_snap_ground` 原本吃 137ms/秒（`u.ground`），
	# 其中 4/5 是这四次采样。
	#
	# 判据：既没在走（`_moving`）也没有残留速度（`_speed`）。停下来那一刻
	# `_tilt` 已经收敛到坡面角度，冻结它正好等于"停在坡上就保持那个倾角"。
	if not _moving and _speed < 0.02:
		rotation = Vector3(_tilt.x, _yaw, _tilt.y)
		return

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


## 攻击能打到的距离（含目标半径）
func _attack_reach(t: Node3D) -> float:
	var r: float = def.attack_range if def != null else 0.0
	if t != null and t.has_method("get_radius"):
		r += float(t.call("get_radius"))
	return maxf(r, 0.3)


## 站位间隙（采集/建造用）：attack_range/2 + 双方半径 + 一点空隙


## 站位间隙（采集/建造用）：attack_range/2 + 双方半径 + 一点空隙
func _stand_off(t: Node3D) -> float:
	var r: float = def.body_radius + GATHER_GAP
	if def != null:
		r += def.attack_range * 0.5
	if t != null and t.has_method("get_radius"):
		r += float(t.call("get_radius"))
	return maxf(r, 0.6)


## 当前指令会不会"追出去"（决定索敌半径，也决定够不着时追不追）


## 当前指令会不会"追出去"（决定索敌半径，也决定够不着时追不追）
func _may_pursue() -> bool:
	if not is_mobile():
		return false
	return order == RtsConst.Order.ATTACK \
			or order == RtsConst.Order.ATTACK_MOVE \
			or order == RtsConst.Order.MOVE


## 自动索敌：走 Game 的注册表（不遍历场景），带分片。
##
## ⚠ 待机/警戒**只认射程内的敌人**：老代码对任何指令都用 acquire_range（步兵 11m、
##   攻击距离 1.35m），待机会锁一个够不着的目标；而 `_acquire` 开头"已有目标就返回"
##   又让它再也不索敌 —— 结果就是站在那儿对着 9m 外的敌人发呆。


## 自动索敌：走 Game 的注册表（不遍历场景），带分片。
##
## ⚠ 待机/警戒**只认射程内的敌人**：老代码对任何指令都用 acquire_range（步兵 11m、
##   攻击距离 1.35m），待机会锁一个够不着的目标；而 `_acquire` 开头"已有目标就返回"
##   又让它再也不索敌 —— 结果就是站在那儿对着 9m 外的敌人发呆。
func _acquire(dt: float, radius_scale: float = 1.0) -> void:
	if def == null or def.acquire_range <= 0.0:
		return
	# 刚下过移动令：这段时间内不主动索敌（挨打会还手，见 take_damage）
	if _acquire_grace > 0.0:
		return
	if target != null and is_instance_valid(target) and target.is_alive():
		return
	_think_t -= dt
	if _think_t > 0.0:
		return
	_think_t = THINK_SLICE
	var pursue: bool = _may_pursue()
	var radius: float = (def.acquire_range if pursue else def.attack_range) * radius_scale
	if radius <= 0.0:
		return
	var cand: Node3D = Game.find_nearest_enemy(global_position, faction, radius)
	if cand != null and not pursue and _flat_dist(cand.global_position) > _attack_reach(cand):
		cand = null
	target = cand


## 攻击循环：冷却 → 前摇（攻击动画）→ 出手 → 后摇


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
		# 不在射程：会追的指令扑上去；待机/警戒/建筑直接**放掉锁定**。
		# 不放掉的话，`_acquire` 的"已有目标就返回"会让它永远盯着一个够不着的敌人，
		# 既不打也不走 —— 这就是"待机单位看到 9m 外敌人却一动不动"的根因。
		if not _may_pursue():
			target = null
			return
		# 行军 / 攻击移动：原目的地先记下来，打完还要接着走
		if order == RtsConst.Order.MOVE or order == RtsConst.Order.ATTACK_MOVE:
			_interrupt_move_for_combat()
		_go_to(target.global_position)
		state = RtsConst.State.MOVE
		return

	# 到射程：停下、转向、开打
	if order == RtsConst.Order.MOVE or order == RtsConst.Order.ATTACK_MOVE:
		# 收到移动/攻击移动的部队只"停下还手"，打完要继续走（不能把指令吃掉）
		_interrupt_move_for_combat()
	_stop_moving()
	_face_pos(target.global_position, dt)
	if _attack_cd <= 0.0:
		_begin_swing()


## 移动指令被战斗打断：记住原目的地（只记第一次，追击途中别覆盖成敌人坐标）


## 移动指令被战斗打断：记住原目的地（只记第一次，追击途中别覆盖成敌人坐标）
func _interrupt_move_for_combat() -> void:
	if _move_interrupted:
		return
	_saved_goal = _goal
	_move_interrupted = true


## 当前目标是否还在射程内（移动指令中途还手用）


## 当前目标是否还在射程内（移动指令中途还手用）
func _target_in_reach() -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not target.is_alive():
		return false
	return _flat_dist(target.global_position) <= _attack_reach(target)


## 起手：前摇 = 冷却 × attack_windup，这段放攻击动画


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
	# 记住当前指令：`_update_cast` 收尾时会还回来。
	# 不记的话，法师自动放完一个火球就把 ATTACK/ATTACK_MOVE 清成 NONE ——
	# 表现是"打一半突然站住不动了"。
	var keep: int = order
	if RtsSkills.begin_cast(self, ab, target.global_position, target):
		_cast_return_order = keep


## 施法前摇


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
	_cast_id = &""
	_cast_target = null
	state = RtsConst.State.IDLE
	# 恢复施法前的指令：主动施法记的是 NONE，自动施法记的是原来的 ATTACK/ATTACK_MOVE…
	order = _cast_return_order
	# 扣法力（在真正出手这一拍扣，冷却期间不会重复扣）
	if def != null and def.mana_cost > 0.0:
		mana = maxf(0.0, mana - def.mana_cost)
	RtsSkills.release(self, id, pos, tgt)


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


## 采集一次要多久（金 / 木 不同的 Cfg 值）
func _harvest_time() -> float:
	var cfg: GameConfig = Cfg.game
	match _carry_kind:
		RtsConst.Harvest.WOOD:
			return maxf(cfg.harvest_time_wood, 0.1)
		_:
			return maxf(cfg.harvest_time_gold, 0.1)


## 采满一次 → 资源进背包，进入返回阶段


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


## 采集产出倍率（只对 AI 生效）
func _gather_multiplier() -> float:
	if faction == null or faction.is_player:
		return 1.0
	return Cfg.difficulty(Game.difficulty_index).gather_multiplier


## 最近的回程点（**纯比距离**）
##
## 2026-10-31 二次定调（玩家原话："伐木场是可以运木头，不是优先，是和基地比较距离，
## 谁更近就运哪里"）：只在"收这种资源"的交汇点里挑**最近的那个**，不做任何建筑优先级。
##   · 判据走数据（UnitDef.dropoff_kinds），不在单位代码里写死建筑 id；
##   · 背木头时候选 = 大本营 + 活着的伐木场，谁近去谁；
##   · 背金子时伐木场根本不在候选里（它 dropoff_kinds 只有 WOOD）。
func _nearest_dropoff(kind: int = -1) -> Node3D:
	var want: int = kind if kind >= 0 else _carry_kind
	# ★ 缓存 0.5s（2026-11-01 性能优化）。
	#
	# 老实现每次都是：RtsWorld.dropoffs()（**新建一张候选表**）→ 逐个
	# `has_method()` + `call("accepts_harvest")`（两次动态派发）→ 比距离。
	# 而 TO_DROP 阶段是**每帧**调一次 —— 几十个农民同时背东西回家时，
	# 每秒上千次动态派发 + 上千次数组分配。
	# 交汇点不会在半秒内搬家，缓存完全安全；只在"缓存失效/换了资源种类"时重算。
	if _dropoff_cache != null and is_instance_valid(_dropoff_cache) \
			and _dropoff_cache.is_alive() and _dropoff_cache_kind == want \
			and _dropoff_scan_cd > 0.0:
		return _dropoff_cache
	var list: Array = RtsWorld.dropoffs(faction)
	var best: Node3D = null
	var best_d: float = INF
	for d in list:
		if d == null or not is_instance_valid(d):
			continue
		if not d.is_alive():
			continue
		# 不收这种资源的交汇点直接跳过（背金子时伐木场不在候选里）
		if d.has_method("accepts_harvest") and not bool(d.call("accepts_harvest", want)):
			continue
		var dist: float = global_position.distance_squared_to(d.global_position)
		if dist < best_d:
			best_d = dist
			best = d
	_dropoff_cache = best
	_dropoff_cache_kind = want
	_dropoff_scan_cd = 0.5
	return best


## 只记账：把身上的东西入账（不碰采集状态机；采集与送资源共用）
func _deposit_carry() -> bool:
	if _carry <= 0 or faction == null:
		return false
	var gold: int = _carry if _carry_kind == RtsConst.Harvest.GOLD else 0
	var wood: int = _carry if _carry_kind == RtsConst.Harvest.WOOD else 0
	# 伐木场「高效搬运」：运回的木材 +50%（只加木材，金子不受影响）
	if wood > 0:
		var bonus: float = RtsCombat.wood_haul_bonus(faction)
		if bonus > 0.0:
			wood += int(round(float(wood) * bonus))
	Game.add_resource(faction, gold, wood)
	_carry_last_gold = gold
	_carry_last_wood = wood
	_carry = 0
	_deposit_count += 1
	return true


## 卸货（采集状态机的一环）


## 卸货（采集状态机的一环）
func _deposit() -> void:
	_deposit_carry()
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


func _update_anim() -> void:
	if visual == null or def == null:
		return
	var ratio: float = 1.0
	var ms: float = _max_speed()
	if ms > 0.01:
		ratio = clampf(_speed / ms, 0.15, 1.6)
	match state:
		RtsConst.State.MOVE, RtsConst.State.RETURN:
			# 背着资源走路时用「搬运」动作（方块人_农民有 carry_gold / carry_wood 两段）；
			# 没有这两段动画的单位会自动落到 walk（见 SkeletonAnim 的降级链）。
			if _carry > 0:
				visual.play("carry_wood" if _carry_kind == RtsConst.Harvest.WOOD else "carry_gold", ratio)
			else:
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


## 共享空间哈希：**直接复用 Game.unit_hash()**（每帧只重建一次，全工程一份）。
##
## 2026-11-01：以前这里自己又建了一份（同样从 Game.all_units() 桶化一遍），
## 和索敌用的那份完全重复 —— 每帧白桶化 130+ 个单位。现在只认 Game 那一份。
static func _shared_hash() -> SpatialHash:
	return Game.unit_hash()


## 单位分离：一重叠就互相推开，别挤成一坨


# ===========================================================================
# 移动辅助（HOUND 重写：扫掠 / 贴墙滑动 / 逐帧推出）
# ===========================================================================

## 站立判定用的有效半径（米）
func _clear_radius() -> float:
	return get_radius() * CLEAR_SAFETY


## 这一帧"真正能走的方向"：前方向能站就走；不能就沿墙切线滑动（带方向记忆）。
## 只做局部几何查询，不重算 A*；与寻路网格共用同一套 is_standable。
##
## ★ 2026-11-01 追加**同伴避让**（玩家口径"单位相互卡位"）：
##   寻路网格里单位不是障碍，十个人走同一个门洞时算出来的路一模一样，谁也不让谁，
##   结果就是挤成一坨、外圈的人被顶住不动。现在"前方有停着/慢吞吞的同伴"也算受阻，
##   同样走切线滑动 —— 队伍会自然分成两列绕过去，而不是互相顶。
func _steer(dir: Vector3, probe: float) -> Vector3:
	var pf: GridPathfinder = _pathfinder()
	if pf == null:
		return dir
	var r: float = _clear_radius()
	var p: float = maxf(probe, PROBE_MIN)
	var ahead: Vector3 = global_position + dir * p
	var wall_ok: bool = pf.is_standable(ahead, r)
	var unit_ok: bool = not _unit_ahead(dir, p)
	if wall_ok and unit_ok:
		return dir
	# 先试上次滑动的方向（对称障碍前不会左右横跳），再试另一边。
	# 注意两条判据都要过：网格能站 **且** 前方没有同伴挡着。
	#
	# ★ 退路很重要：如果"墙能过、只是有人"，就走第一条能过墙的方向（人挤一挤让开），
	#   **不能**因为同伴挡着就返回 ZERO —— 那会让单位在人群里彻底停摆（寻路自检 ③ 抓到过）。
	var first: int = 1 if _slide_side >= 0 else -1
	var wall_only: Vector3 = Vector3.ZERO
	for sgn in [first, -first]:
		for angle in SLIDE_ANGLES:
			var cand: Vector3 = dir.rotated(Vector3.UP, float(angle) * float(sgn))
			var cp: Vector3 = global_position + cand * p
			if not (pf.is_standable(cp, r) and pf.line_of_sight(global_position, cp, r)):
				continue
			if not _unit_ahead(cand, p):
				_slide_side = sgn
				return cand
			if wall_only == Vector3.ZERO:
				wall_only = cand
	if wall_only != Vector3.ZERO:
		return wall_only
	# 绕不开：只是"人挡着"就照直走（分离/推挤会把让开），真的被墙围住才停。
	if wall_ok and not unit_ok:
		return dir
	return Vector3.ZERO


## 前方一个身位内有没有**同伴挡路**（软避让，只回答"要不要绕"，不负责推人）。
##
## 三点克制，避免"整队人互相横跳"：
##   ① 只认**会动的同类**：建筑/金矿本来就是障碍，由寻路网格管；
##   ② 只看**前方**（点在前进方向上的投影 > 0），身后的人不算；
##   ③ **同向同速的人不算挡路** —— 否则一列行军会左右乱扭。
func _unit_ahead(dir: Vector3, probe: float) -> bool:
	if def == null or not is_mobile() or not _avoid_ok:
		return false
	var hash: SpatialHash = _shared_hash()
	if hash == null:
		return false
	var my_r: float = get_radius()
	var look: float = maxf(probe, PROBE_MIN) + my_r
	var probe_p: Vector3 = global_position + dir * look
	for o in hash.query(probe_p, look + 1.4):
		if o == self or o == null or not is_instance_valid(o):
			continue
		var other := o as RtsUnit
		if other == null or other.def == null or not other.is_alive():
			continue
		if not other.is_mobile():
			continue
		var to: Vector3 = other.global_position - global_position
		to.y = 0.0
		if to.dot(dir) <= 0.05:
			continue
		# ★ 只避让**停着的**同伴。
		#   两个都在走的人不要互相绕：那会变成"你让我我让你"的左右横跳，
		#   而且会把队形带歪（寻路自检 ③ 里 W1 就因为这点侧移停在离目标 1.5m 处）。
		#   真正需要绕的场景是"撞上一堆正在干活/待命的人"——那才是玩家说的卡位。
		if other._moving:
			continue
		var need: float = my_r + other.def.body_radius + 0.20
		if to.length_squared() <= need * need:
			return true
	return false


## 被建筑/分离推挤塞进不可走格时：**逐帧**往最近可站立点推，绝不瞬移。
## 只有连续 PUSHOUT_TIMEOUT 秒推不出去，才允许一次兜底吸附（计数必须为 0）。
func _update_wall_pushout(dt: float) -> void:
	if def == null or not is_mobile():
		return
	var pf: GridPathfinder = _pathfinder()
	if pf == null:
		return
	var r: float = _clear_radius()
	if pf.is_standable(global_position, r):
		_pushout_t = 0.0
		_pushout_has = false
		return
	_pushout_t += dt
	_pushout_retarget -= dt
	if not _pushout_has or _pushout_retarget <= 0.0:
		_pushout_goal = pf.nearest_standable(global_position, r + GridPathfinder.GOAL_MARGIN)
		_pushout_has = true
		_pushout_retarget = PUSHOUT_RETARGET
	var d: Vector3 = _pushout_goal - global_position
	d.y = 0.0
	if d.length() > 0.0001:
		global_position += d.normalized() * minf(PUSHOUT_SPEED * dt, d.length())
	dbg_push_frames += 1
	if _pushout_t >= PUSHOUT_TIMEOUT:
		# 连续多帧无解：允许一次兜底（日志可查；正式路径应为 0）
		dbg_snap_fallbacks += 1
		global_position = RtsWorld.snap_y(pf.nearest_standable(global_position,
			r + GridPathfinder.GOAL_MARGIN))
		_pushout_t = 0.0
		_pushout_has = false
		_need_repath = true


## 自检/日志用：移动层计数（只读）
func debug_move_stats() -> Dictionary:
	return {
		"slide_frames": dbg_slide_frames,
		"blocked_frames": dbg_blocked_frames,
		"push_frames": dbg_push_frames,
		"repath_count": dbg_repath_count,
		"crowd_settles": dbg_crowd_settles,
		"snap_fallbacks": dbg_snap_fallbacks,
	}
