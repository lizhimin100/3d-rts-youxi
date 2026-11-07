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
## 找不到资源后每隔多久重搜一次（秒）。见 _order_gather 的 SEEK 分支。
const GATHER_RETRY_SEC: float = 3.0
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
## **锚定权重**：正在干活（建造/采集/修理）或正在挥砍的单位几乎推不动。
##
## 玩家口径（2026-11-06）：「部队跑到正在建筑的农民身边，把农民挤开、建造失败，
## 手动拉开又挤回来」。根因不在避让，而在**分离是对称的** —— 一个站着的农民
## 和一个走过来的兵被同等推开，农民就被顶出工地，于是建造进度归零、人再走回来，
## 形成"拉开又挤回来"的往复。
## 现在：干活的人 share 只占 13%，路过的人吃 87% 的推力 —— 人是被农民弹开的。
const ANCHOR_WEIGHT: float = 0.15
## 站位被同伴占用的判定：半径和 × 这个系数内算"这格有人了"
const SLOT_OCCUPIED: float = 1.25
## 找空位时向外扩的基准距离（米）
const SLOT_PROBE: float = 1.15

const CROWD_RADIUS: float = 4.5
## 拥挤让位：目标区内被同伴堵住、连续这么久没有更靠近 → 就地停（不再挤）
const CROWD_PATIENCE: float = 0.9
## 拥挤判定：与同伴中心距小于（半径和 × 这个值）才算“被人堵着”
const CROWD_NEIGHBOR: float = 1.08

## 采集内部阶段
## ★ 2026-11-07 新增 ENTER：到点后先放"采集技能"的起手（伐木举斧 / 采矿钻进矿洞），
##   时长读 `代码/配置/技能表.gd`。以前 TO_NODE 一到位就直接开始计时采集，
##   玩家看到的是"人刚到就原地飘着挥"。
enum GatherPhase { SEEK = 0, TO_NODE = 1, ENTER = 4, HARVEST = 2, TO_DROP = 3 }

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
## 起手次数（每 `_begin_swing` +1）。战斗自检用它验证"多个近战能同时攻击"，
## 比看动画/看血量更直接：只有真的在射程内起手才会加。
var dbg_swings: int = 0
## 全局兜底吸附次数（**必须为 0**；非 0 就是“多帧无解”了，日志会指名道姓）
static var dbg_snap_fallbacks: int = 0

var _attack_cd: float = 0.0
var _windup_t: float = 0.0
var _swinging: bool = false
var _think_t: float = 0.0
## 空闲单位的隔帧开关（见 _process_inner 的空闲降频）
var _idle_skip: int = 0
## 分离查询的复用缓冲（见 _update_separation；不要跨帧持有）
var _near_buf: Array = []
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
## 找不到资源时的重找节流（秒）。见 _order_gather 的 SEEK 分支。
var _gather_retry_t: float = 0.0
var _carry_kind: int = RtsConst.Harvest.GOLD
var _flee_t: float = 0.0
var _was_gathering: bool = false

# 建造
var _build_site: Node3D = null
## 本农民在工地外圈的**专属站位**（按实例 id 确定，进工地时算一次）。
## 为什么要有它：以前所有农民都 `_go_to(工地中心)`，解析出的最近可站点是同一个 →
## 两个农民抢同一格 → 互相推 → 谁都不在建造距离内。现在一人一格，天然不打架。
var _work_spot: Vector3 = Vector3.ZERO
var _work_spot_valid: bool = false
## **已经钻进工地内部的建筑**（魔兽兽族苦工口径，2026-11-07）。
##
## 玩家口径：「农民建造改成兽族那样直接进建筑里面建造，以防无法建造」。
## 老实现要求农民精确站到占地外圈那一格，人多/地形窄/被兵顶一下就永远差 30cm，
## 进度一辈子 0.00 —— 玩家看到的是「农民站在工地旁边不动，房子不长」。
## 现在：走到墙面够得着（_work_reach）就直接进去，模型隐藏、不参与分离/贴地，
## 建筑完工 / 被拆 / 玩家改令时再放出来（见 `建筑.release_builders()`）。
var _inside_site: Node3D = null

# 撤退（AI 残血收队）
## 正在撤退：撤退途中**不索敌、不还手**，一路跑回家。
## 为什么单独一个状态：MOVE 分支默认有 45% 索敌半径，撤退中的兵会被路过的敌人
## 反复拽回去还手（玩家看到的就是「一被打就撤退，撤一半又冲回来」）。
var _retreat: bool = false
## 正在修理的己方建筑（Order.REPAIR 用）
var _repair_target: Node3D = null
## 送资源要去的交汇点
var _return_drop: Node3D = null
## 上一次送达的数量（提示文案用）
var _carry_last_gold: int = 0
var _carry_last_wood: int = 0
## 累计入库（只增不减，采集自检/统计用；不参与玩法）
var deposit_gold_total: int = 0
var deposit_wood_total: int = 0
## 采矿"钻进矿洞"的视觉推进量 0~1（1 = 完全在洞里，模型隐藏）
var _mine_k: float = 0.0
## 砍树/采矿的碎屑特效节流（秒）
var _chop_fx_t: float = 0.0
## 当前采集技能 id（chop_wood / mine_gold），数值全部读 技能表
var _gather_skill: StringName = &""
## 占用的载位号（-1 = 没占；换目标/采满/死亡必须让出来）
var _gather_slot: int = -1
## 采集技能起手剩余时间（ENTER 阶段）
var _gather_enter_t: float = 0.0
## 上一帧的采集动画进度（0~1），用来抓"挥到最低点"那一下
var _chop_phase_prev: float = -1.0
## 挥砍相位是否已经越过"落点"（每循环只触发一次震树）
var _chop_armed: bool = false

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


## 是否钻在工地内部（兽族苦工口径）。里面的人**没有体积、不可被索敌**。
func is_inside_build() -> bool:
	return _inside_site != null


## 能不能被敌人锁定：钻进工地的农民不算（房子才是目标）。
func can_be_targeted() -> bool:
	return _inside_site == null and is_alive()


## 是否正在撤退（AI 残血收队）。撤退途中不索敌、不还手，免得"撤一半又冲回去"。
func is_retreating() -> bool:
	return _retreat


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
	# ★ 钻在工地里的农民**无敌**（玩家 2026-11-07 口径）：
	#   房子里的人既不能被索敌（can_be_targeted=false），也不吃任何漏网伤害
	#   （范围技/脚本直伤/旧存档里的残留目标）。要打他，先把房子拆了。
	if _inside_site != null:
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
	# ★ 撤退中不还手（见 `order_retreat`）：残血兵被流弹擦一下就把整条撤退命令丢掉，
	#   玩家看到的就是"一被打就撤、撤两步又冲回去"。
	if from != null and is_instance_valid(from) and not _retreat:
		var tf: RtsFaction = from.get("faction") as RtsFaction
		if tf != null and faction != null and faction.is_enemy_of(tf) \
				and Game.is_node_visible_to(faction, from):
			_acquire_grace = 0.0
			# 距离口径与开火一致（边缘间隙），别再用中心距 ×1.5 的野路子
			if _target_gap(from) <= _attack_reach(from):
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


# ===========================================================================
# 撤退（AI 残血收队）
# ===========================================================================

## 到家判定（米）：进这个圈就算收队完成，可被 AI 重新编入进攻队列
const RETREAT_ARRIVE: float = 6.0
## 回血后重新参战的门槛（最大血比例）。低于它就继续待在家。
const RETREAT_RECOVER: float = 0.62
## 基地圈内的回血速度（每秒最大血比例）。没有这层，"残血→撤退→又残血"会无限循环：
## AI 每次把 32% 血的兵拉去进攻，打两下又撤，玩家看到的是整支部队在原地打转。
const HOME_REGEN: float = 0.06

## AI 叫这个单位撤退回家。
##
## 为什么不是简单一条 `order_move(home)`：MOVE 分支默认还有 45% 索敌，
## 撤退中的兵会被路过敌人反复拽回去还手。这里把 `_retreat` 立起来，
## `_update_order` 的 MOVE 分支会完全跳过索敌（见那里的注释）。
func order_retreat(home: Vector3) -> void:
	if _dying:
		return
	order_move(home)          # order_move 会清 _retreat，所以下面再立一次
	_retreat = true
	_acquire_grace = maxf(_acquire_grace, 3.0)
	_swinging = false
	target = null


## 撤退中的每帧维护：到家 / 血回来了 → 解除。基地圈内缓慢回血。
func _tick_retreat(dt: float) -> void:
	if def == null or faction == null:
		_retreat = false
		return
	var home: Vector3 = RtsWorld.base_center(faction)
	if _flat_dist(home) <= RETREAT_ARRIVE:
		# 在自家圈里：回血（只回到门槛，不白送满血）
		var cap: float = def.max_hp * RETREAT_RECOVER
		if hp < cap:
			hp = minf(cap, hp + def.max_hp * HOME_REGEN * dt)
		if hp >= cap * 0.999:
			_retreat = false
			_acquire_grace = 0.0
			if order == RtsConst.Order.MOVE:
				order = RtsConst.Order.NONE
				state = RtsConst.State.IDLE


func _die() -> void:
	if _dying:
		return
	_dying = true
	# 死在工地里（模型是隐藏的）：先把自己从工地名单里摘掉并恢复可见，
	# 否则建筑完工时会对着一个已 free 的引用 release。
	_leave_inside_site()
	state = RtsConst.State.DEAD
	target = null
	order = RtsConst.Order.NONE
	_release_gather_slot()
	_swinging = false
	_stop_moving()
	_dead_t = Cfg.game.corpse_linger
	_sinking = false
	_sink_t = 0.0
	_sink_base_y = global_position.y

	if visual != null:
		# 死在矿里（采集金矿时模型是沉下去且隐藏的）→ 先把模型升回来，
		# 否则尸体会"隐形"躺在矿里，玩家看不到死亡反馈。
		_mine_k = 0.0
		visual.position = Vector3.ZERO
		visual.scale = Vector3.ONE
		visual.visible = true
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
	_retreat = false
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
	_retreat = false
	_flee_t = 0.0
	_move_interrupted = false
	_go_to(_attack_spot(t), true)


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


## 采集指定资源点（**技能驱动**：伐木 / 采矿，见 代码/配置/技能表.gd）
func order_gather(node: Node3D) -> void:
	if _dying or node == null:
		return
	if def == null or not RtsWorld.is_worker_def(def):
		return
	if _gather_node != node:
		_release_gather_slot()
	_gather_node = node
	var hk: Variant = node.get("harvest_kind")
	if hk != null:
		_carry_kind = int(hk)
	# 技能 id 由资源种类决定；载位上限也来自资源点
	_gather_skill = RtsSkills.TABLE.gather_skill_for(_carry_kind)
	_gather_slot = -1
	_chop_phase_prev = -1.0
	_chop_armed = false
	order = RtsConst.Order.GATHER
	target = null
	_gather_phase = GatherPhase.TO_NODE
	_gather_t = 0.0
	_gather_enter_t = 0.0
	_flee_t = 0.0
	_was_gathering = true
	_gather_spot_valid = false
	_go_to(_gather_spot(), true)


## 采集站位（**缓存**）：TO_NODE 阶段以前每帧都调 `_gather_spot()` ——
## 里面一次 `claim_slot` 字典遍历 + 一次 `slot_point` 三角 + 一次 `walkable_pos` 网格查询。
## 几十个农民同时采木时，这一项比 A* 还贵。载位在进入/离开阶段时变，缓存到下次阶段切换即可。
var _gather_spot_cache: Vector3 = Vector3.ZERO
var _gather_spot_valid: bool = false


## 采集站位：优先占一个载位（围着矿/树散开），没有就退回通用站位。
func _gather_spot() -> Vector3:
	if _gather_node == null or not is_instance_valid(_gather_node):
		return global_position
	if _gather_node.has_method("claim_slot"):
		if _gather_slot < 0:
			_gather_slot = int(_gather_node.call("claim_slot", self))
		if _gather_slot >= 0 and _gather_node.has_method("slot_point"):
			var p: Vector3 = _gather_node.call("slot_point", _gather_slot, global_position) as Vector3
			return RtsWorld.walkable_pos(p)
	# ★ 载位满了（8 个人抢 3 个坑）：**按实例 id 绕资源站一圈**，不能全挤矿心。
	#   直接返回矿心有两个问题：① 矿心在岩石里，`_go_to` 会吸到墙外、到点判定却拿矿心距离
	#   （永远差 2.9m > 2.0 → 一直「没到」，顶着矿壁推）；② 5 个人抢同一个格互相顶。
	#   现在每人一个稳定角度、半径 = 身位 + 采集间距，既是可站格又天然散开。
	var ang: float = float(get_instance_id() % 628) * 0.01
	var rr: float = maxf(_stand_off(_gather_node) + get_radius() * 0.5, 1.2)
	var p2: Vector3 = _gather_node.global_position + Vector3(cos(ang), 0.0, sin(ang)) * rr
	return RtsWorld.walkable_pos(p2)


func _release_gather_slot() -> void:
	if _gather_node != null and is_instance_valid(_gather_node) and _gather_slot >= 0 \
			and _gather_node.has_method("release_slot"):
		_gather_node.call("release_slot", self)
	_gather_slot = -1


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
	# ★ 直接去**自己那一格**（墙面外 0.55m），不要去工地中心：
	#   中心在占格里，A* 的终点会被顶到墙外，路径还会绕建筑转一圈。
	_work_spot = site.work_spot_for(self)
	_work_spot_valid = true
	_go_to(_work_spot, true)
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
	# 同 order_build：直接去墙外的自己那一格
	_work_spot = b.work_spot_for(self)
	_work_spot_valid = true
	_go_to(_work_spot, true)
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
	_work_spot_valid = false
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
## 性能探针计时总开关（2026-11-07）。**默认关**：
##
## 为什么必须关：`Time.get_ticks_usec()` 一次 ~40ns，而单位每帧要打 10~16 个点
## （process/order/move/sep/ground/goto/sgoal/acquire…）。8090 单位 60fps 下
## 就是 500 万次/秒 —— 光「量自己有多慢」就能吃掉一格 CPU。
## 只有 `--perf` / `--perf-long` 才打开（见 性能探针.gd）。
static var dbg_perf: bool = false
## 指令分布普查（每次采样清零重算）：key = order 枚举值，value = 单位数
static var dbg_order_hist: Dictionary = {}


## 带计时的索敌（`_update_order` 里的调用点统一走它）
func _acquire_timed(dt: float, radius_scale: float = 1.0) -> void:
	if not RtsUnit.dbg_perf:
		_acquire(dt, radius_scale)
		return
	var t0: int = Time.get_ticks_usec()
	_acquire(dt, radius_scale)
	RtsUnit.dbg_acquire += Time.get_ticks_usec() - t0

func _process(delta: float) -> void:
	if def == null:
		return
	if not RtsUnit.dbg_perf:
		_process_inner(delta)
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

	# ★ 钻在工地内部：只推进建造进度，移动/分离/贴地/动画全部跳过
	#   （模型已经隐藏，还让它参与分离力会把旁边的兵顶开 —— 人在房子里不该有体积）。
	if _inside_site != null and order == RtsConst.Order.BUILD:
		_tick_inside_build(dt)
		return

	# ★ 空闲单位逻辑降频（2026-11-07 性能排查）。
	#   判据很严：可移动 + 没指令 + 没目标 + 没在动 + 不在施法/撤退/逃跑/工地里。
	#   这种单位每帧唯一要做的事就是「别和同伴重叠」（分离），隔一帧做一次在
	#   玩家眼里完全看不出来；而 8000 待命兵的场景里这一条能砍掉近一半的单位逻辑。
	#   ⚠ 建筑不能跳：训练队列 / 塔的索敌都在 `_update_order`/`_tick_extra` 里。
	if _is_fully_idle():
		_idle_skip += 1
		if _idle_skip % 3 != 0:
			return

	# 施法中：只数前摇，别的都不做
	if state == RtsConst.State.CAST:
		_update_cast(dt)
		_update_separation(dt)
		_snap_ground(dt)
		_update_anim()
		return

	# ---- 分项计时（只给 性能探针 读；`dbg_perf` 关着时零开销）----
	var perf: bool = RtsUnit.dbg_perf
	var _q0: int = 0
	if perf:
		_q0 = Time.get_ticks_usec()
	_update_order(dt)
	if perf:
		RtsUnit.dbg_order += Time.get_ticks_usec() - _q0
	# ★ 刚刚在这一帧钻进工地：后面的移动/分离/贴地全部跳过。
	#   不跳的话，`_update_anim` 里"离开矿洞就把模型显示回来"的兜底会立刻
	#   把刚隐藏的模型顶回可见（建造自检抓到的 `隐藏 0/4`）。
	if _inside_site != null and order == RtsConst.Order.BUILD:
		_update_anim()
		return
	if perf:
		_q0 = Time.get_ticks_usec()
	_update_move(dt)
	_update_attack(dt)
	_update_auto_cast(dt)
	_settle_state()
	if perf:
		RtsUnit.dbg_move += Time.get_ticks_usec() - _q0
	if perf:
		_q0 = Time.get_ticks_usec()
	_update_separation(dt)
	_update_wall_pushout(dt)
	if perf:
		RtsUnit.dbg_sep += Time.get_ticks_usec() - _q0
	if perf:
		_q0 = Time.get_ticks_usec()
	_snap_ground(dt)
	_update_anim()
	if perf:
		RtsUnit.dbg_ground += Time.get_ticks_usec() - _q0


## 是否「彻底闲着」：可移动、没指令、没目标、没在动、不在施法/撤退/逃跑/工地里。
## 只有这种单位允许隔帧跑一次逻辑（见 _process_inner 的空闲降频）。
func _is_fully_idle() -> bool:
	return is_mobile() and order == RtsConst.Order.NONE and target == null \
			and not _moving and _speed < 0.02 and _flee_t <= 0.0 \
			and _inside_site == null and _cast_id == &"" and not _retreat and _dying == false


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
	# 指令已经不是 BUILD 了 → 先从工地里出来（玩家中途点了移动/攻击）
	if _inside_site != null and order != RtsConst.Order.BUILD:
		_leave_inside_site()

	# --- 逃跑优先（农民往基地跑）---
	if _flee_t > 0.0:
		state = RtsConst.State.MOVE
		_go_to(RtsWorld.base_center(faction))
		return

	# --- 撤退（AI 残血收队）：一路跑，不索敌、不还手 ---
	if _retreat:
		_tick_retreat(dt)

	# 巡逻往返：到了端点就掉头
	_tick_patrol()

	match order:
		RtsConst.Order.MOVE:
			# 行军途中也索敌：路过被打不能装没看见（魔兽手感），
			# 打完 / 敌人跑出射程就继续走完原指令。
			# ★ 半径只给 45%：满额 11m 会让"撤退"变成"走两步又折回去打"，
			#   玩家感受就是"指令不跟手、被旧攻击牵扯"。
			# ★ 撤退中完全不索敌（2026-11-07）：否则残血兵一路被路过的敌人
			#   反复拽回去还手，玩家看到的就是"一被打就撤退、撤一半又冲回来"。
			if not _retreat:
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
			if not _retreat:
				_acquire_timed(dt)
		_:
			# 待机：挨打时自己还手（不主动跑出去找架打）
			if target == null or not is_instance_valid(target) or not target.is_alive():
				target = null
			# 撤退中（已经到家、血还没回满）不主动索敌：
			# 否则它会在自家门口又盯上一个路过的敌人，转头冲出去 —— 又是一次"撤了又回来"。
			if not _retreat:
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
	if _target_gap(target) > _attack_reach(target):
		if is_mobile():
			# 同 _update_attack：落定在射程外一点点时必须强制重走最后半步
			var reach: float = _attack_reach(target)
			var dist: float = _target_gap(target)
			_go_to(_attack_spot(target), _arrived_goal and dist <= reach + 1.2)
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
	#
	# ★ 2026-11-07 玩家口径「部分农民采完木头就停在伐木场/基地附近，甚至停在刚倒下的树旁边」：
	#   老实现在这里直接 `order = NONE; state = IDLE` —— 找不到下一棵树就地罚站，
	#   玩家看到的就是「农民不动了」。现在改成：
	#     ① 换目标立刻搜一次（不节流）；
	#     ② 真的一棵都没有 → 进 SEEK，走回最近的交汇点，每 GATHER_RETRY_SEC 再搜；
	#        （全图树砍光之前一定会重新找到，AI 补种的树/新开的分矿也能自动接上）
	if _gather_node == null or not is_instance_valid(_gather_node) \
			or bool(_gather_node.call("is_depleted")):
		_release_gather_slot()
		_gather_node = null
		_gather_retry_t -= dt
		if _gather_retry_t <= 0.0:
			_gather_retry_t = GATHER_RETRY_SEC
			_gather_node = _find_harvestable(_carry_kind)
		if _gather_node == null:
			_enter_phase(GatherPhase.SEEK)
			return
		_gather_retry_t = 0.0
		_gather_phase = GatherPhase.TO_NODE
		_gather_slot = -1
		_go_to(_gather_spot(), true)

	# --- 卡死兜底：某阶段待太久且几乎没位移，就强制推进（十人挤矿时救命的保险丝）---
	var moved_since: float = global_position.distance_to(_phase_pos)
	_phase_t += dt
	if _phase_t > PHASE_STUCK_TIME and moved_since < 0.55:
		if _gather_phase == GatherPhase.TO_NODE or _gather_phase == GatherPhase.SEEK:
			# 已经在资源附近却永远差一点到 -> 直接进"起手"（起手完就开始采）
			# SEEK 时 _gather_node 是 null（附近没资源）—— 这里要挡住，别解引用空引用
			if _gather_node != null and is_instance_valid(_gather_node) \
					and _flat_dist(_gather_node.global_position) <= _stand_off(_gather_node) + ARRIVE_SLACK + 2.0:
				_stop_moving()
				_gather_enter_t = RtsSkills.cast_time(_gather_skill)
				_enter_phase(GatherPhase.ENTER if _gather_enter_t > 0.0 else GatherPhase.HARVEST)
				_gather_t = _harvest_time()
				return
		elif _gather_phase == GatherPhase.TO_DROP:
			_deposit()
			_enter_phase(GatherPhase.TO_NODE)
			return
		_enter_phase(_gather_phase)

	match _gather_phase:
		GatherPhase.SEEK:
			# 附近真的没有可采资源：走回最近的交汇点等着（每 GATHER_RETRY_SEC 重搜一次）。
			# 玩家看到的必须是「农民回家了」，不是「农民站在刚倒下的树旁边不动」。
			state = RtsConst.State.MOVE
			var home: Node3D = _nearest_dropoff()
			var dest: Vector3 = home.global_position if home != null \
					else RtsWorld.base_center(faction)
			_go_to(dest)
			if _flat_dist(dest) <= 3.0:
				_stop_moving()
				state = RtsConst.State.IDLE
		GatherPhase.TO_NODE:
			state = RtsConst.State.MOVE
			# 走"自己那个载位"，不是矿心：三个人围着矿站，不叠在一个点上
			# ★ 载位算一次就缓存（见 _gather_spot_cache 的注释），不每帧重算
			if not _gather_spot_valid:
				_gather_spot_cache = _gather_spot()
				_gather_spot_valid = true
			var spot: Vector3 = _gather_spot_cache
			_go_to(spot)
			# 到点判定要带 ARRIVE_SLACK：A* 终点被吸附到最近可走格，
			# 会比站位阈值远 0.3~0.5m，卡死就是这零点几米造成的
			# ★ 「站住 2 秒就算到了」兜底（2026-11-07）：
			#   载位/落点被占位吸附过后可能永远差 0.2m，`_go_to` 的到点闩锁又会让它
			#   一直停在原地 —— 于是农民在矿边站一整局（采集自检「原地不动 21s」）。
			#   人已经不再移动 + 这个阶段待了 2s，就直接开工：采集不依赖精确站位。
			if _flat_dist(spot) <= ARRIVE_SLACK + 0.6 \
					or (not _moving and _phase_t > 2.0):
				_stop_moving()
				_gather_enter_t = RtsSkills.cast_time(_gather_skill)
				if _gather_enter_t > 0.0:
					_enter_phase(GatherPhase.ENTER)
				else:
					_gather_t = _harvest_time()
					_enter_phase(GatherPhase.HARVEST)
		GatherPhase.ENTER:
			# 技能起手：伐木举斧、采矿钻进矿洞。逻辑不推进产出，只是"进入状态"。
			state = RtsConst.State.GATHER
			_stop_moving()
			_face_pos(_gather_node.global_position, dt)
			_gather_enter_t -= dt
			if _gather_enter_t <= 0.0:
				_gather_t = _harvest_time()
				_chop_phase_prev = -1.0
				_chop_armed = false
				_enter_phase(GatherPhase.HARVEST)
		GatherPhase.HARVEST:
			state = RtsConst.State.GATHER
			_stop_moving()
			_face_pos(_gather_node.global_position, dt)
			_tick_chop_fx(dt)
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
		# 换阶段 = 站位可能要重算（载位是围着资源点按来访方向分的）
		_gather_spot_valid = false


## 采集动画的"落点"相位（0~1）：挥到最低点 / 镐头砸到矿壁那一下。
## 农民用的是 attack 动作（1.57s），实测斧头在 40% 左右到位。
const CHOP_IMPACT_PHASE: float = 0.42
## 一次采集（一趟）里挥几下 —— 决定动画播放速度：越多越快、越利落。
## 4 挥 / 4.0s = 1.57x（原来 1.0x 慢悠悠）；3 挖 / 3.2s = 1.47x。
const CHOPS_WOOD: int = 4
const CHOPS_GOLD: int = 3


## 采集动画该放多快：一趟正好挥 N 下。
## clip = 动作原长（农民 attack 1.57s），N = 本资源的下数，T = 一趟采集秒数。
func _gather_anim_speed() -> float:
	var clips: int = CHOPS_WOOD if _carry_kind == RtsConst.Harvest.WOOD else CHOPS_GOLD
	var clip: float = 0.0
	if visual != null and visual.has_method("anim_length"):
		clip = float(visual.call("anim_length", "gather"))
	if clip <= 0.01:
		return 1.0
	var t: float = maxf(_harvest_time(), 0.1)
	# 0.55~2.6：再快就看不清是在砍树，再慢就回到"飘着挥"
	return clampf(clip * float(clips) / t, 0.55, 2.6)


## 砍树 / 挖矿的落点反馈。
##
## ★ 2026-11-07 玩家口径「木头的摇晃要和农民采集的动作对应上」：
##   以前按 0.55s 定时晃树，和挥斧动作完全对不上（有时举着斧头树就抖了）。
##   现在读采集动画的播放进度，**每次循环只在 42% 那一下**触发 shake：
##   斧头落下 → 树抖，一下一下对得上。动画不可用时才退回定时器。
func _tick_chop_fx(dt: float) -> void:
	if _gather_node == null or not is_instance_valid(_gather_node):
		return
	if _carry_kind != RtsConst.Harvest.WOOD:
		# 金矿：人已经钻进矿洞（模型隐藏），只在矿口按节奏冒石粉
		_chop_fx_t -= dt
		if _chop_fx_t > 0.0:
			return
		_chop_fx_t = 0.85
		var pm: Vector3 = _gather_node.global_position + Vector3(0.0, 0.55, 0.0)
		BUILD_FX.dust(pm, 3, 0.25, Color(0.86, 0.78, 0.48))
		return

	var ph: float = -1.0
	if visual != null and visual.has_method("anim_phase"):
		ph = float(visual.call("anim_phase"))
	if ph < 0.0:
		# 没有骨骼动画（静态模型）→ 退回定时晃树
		_chop_fx_t -= dt
		if _chop_fx_t > 0.0:
			return
		_chop_fx_t = 0.55
		if _gather_node.has_method("shake"):
			_gather_node.call("shake", 1.0)
		return
	# 动画回绕 = 新的一挥开始
	if _chop_phase_prev >= 0.0 and ph < _chop_phase_prev:
		_chop_armed = false
	if not _chop_armed and ph >= CHOP_IMPACT_PHASE:
		_chop_armed = true
		if _gather_node.has_method("shake"):
			_gather_node.call("shake", 1.0)
	_chop_phase_prev = ph


## 建造：走到**自己那一格** → 播 build 动画 → 推进度
##
## ★ 2026-11-06 重写（玩家口径"部队把农民挤开、建造失败，手动拉开又挤回来"）：
##   ① 每个农民有自己的外圈站位（`RtsBuilding.work_spot_for`），不再全队抢工地中心；
##   ② 开工判据改成"到**墙面**的距离"，不再拿中心距（大本营 9m 宽，站墙根离中心 4.5m）；
##   ③ 已经在建造距离内就**直接干活、不重算路径** —— 被路过的人推一下不会清零进度，
##      只有真的被挤出墙外 1.3m 才走回来（配合分离锚定，实际几乎不会发生）。
## 施工/修理的"够得着"判据（到墙面的距离，米）。
##
## ★ 2026-11-06 玩家口径「农民只能拍下一个地基，然后就没有然后」的根因：
##   这里是**固定 1.35m**，而 `work_spot_for()` 给的站位被 `walkable_pos()` 吸附到
##   **格子中心**，建筑占地外扩后最近的格心在墙面外 **1.50m** —— 永远差 15cm。
##   于是每帧都判"太远"→ 再走一步 → 被墙顶住 → 下帧还是太远，进度一辈子是 0。
##   现在按"本单位半径 + 余量"算，并且保证不小于 1.5（格子吸附的下限）。
func _work_reach() -> float:
	# ★ 2026-11-07 再放宽 0.7m（实测仍进不去）：
	#   `work_spot_for()` 给的站位贴着墙（外扩 0.55m），但 `walkable_pos()` 会把它
	#   吸附到最近可走格心 —— 建筑占地按 1 格膨胀，最近格心在墙面外 **1.50m**。
	#   旧阈值恰好 1.5，浮点比较等于「永远差一点点」→ 农民站在墙边一动不动、进度 4%。
	#   现在 2.2 起步：宁可站远一点就进去（人一进去模型就隐藏，看不出来），
	#   也不要再出现「拍下地基然后就没有然后」。
	return maxf(2.2, get_radius() + 1.5)


## 建造：走到工地旁 → **钻进工地内部** → 播 build 动画 → 推进进度（多农民叠加）
##
## ★ 2026-11-07 玩家口径：改成魔兽兽族苦工那样"直接进建筑里面建"。
##   老实现（站在占地外圈抡锤）在两个地方必然失败：
##     ① 人多：两个农民互相顶，谁都站不到判定圈里，进度永远 0.00；
##     ② 地形窄/贴墙：`work_spot_for` 解析出的落点根本站不上去。
##   现在只要走到「墙面够得着」就直接进去：模型隐藏、没有体积、不参与分离，
##   里面的人稳稳推进度。完工/被拆/改令时由 `建筑.release_builders()` 放出来。
func _order_build_tick(dt: float) -> void:
	if _build_site == null or not is_instance_valid(_build_site):
		_leave_inside_site()
		order = RtsConst.Order.NONE
		state = RtsConst.State.IDLE
		_work_spot_valid = false
		return
	var site: RtsBuilding = _build_site as RtsBuilding
	if site == null or site.is_constructed or not site.is_alive():
		_leave_inside_site()
		order = RtsConst.Order.NONE
		_build_site = null
		state = RtsConst.State.IDLE
		_work_spot_valid = false
		return
	# 够得着墙面就直接钻进去（阈值随体型走，见 _work_reach 的注释）
	var reach: float = _work_reach()
	var d: float = site.distance_to_footprint(global_position)
	if d <= reach:
		if _inside_site != site:
			_enter_build_site(site)
		_tick_inside_build(dt)
		return
	# 太远：走自己那一格（第一次进来算一次，之后不再变）
	if not _work_spot_valid:
		_work_spot = site.work_spot_for(self)
		_work_spot_valid = true
		_go_to(_work_spot, true)
		state = RtsConst.State.MOVE
		return
	state = RtsConst.State.MOVE
	_go_to(_work_spot)
	# 站位本身够不着墙面（地形/别的建筑卡住）→ 退而求其次，直接朝工地中心走
	if not _moving and site.distance_to_footprint(global_position) > reach:
		_go_to(site.global_position)


# ===========================================================================
# 工地内部（兽族苦工口径）
# ===========================================================================

## 钻进工地：登记 + 隐藏模型 + 停掉一切移动表现。
func _enter_build_site(site: RtsBuilding) -> void:
	if site == null or not is_instance_valid(site):
		return
	_leave_inside_site()
	_inside_site = site
	_stop_moving()
	_swinging = false
	_windup_t = 0.0
	state = RtsConst.State.BUILD
	if site.has_method("admit_builder"):
		site.call("admit_builder", self)
	# 用 visible 而不是 scale=0：缩放到 0 会让部分模型法线退化，恢复时闪一下。
	if visual != null:
		visual.visible = false


## 从工地里出来（本单位主动离开：改令 / 工地没了）。
##
## ★ 必须**落到墙外**（2026-11-07）：住进去的时候人是站在占地里的，直接原地现身
##   会卡在建筑的挡格里（A* 认为他在墙里，走出不来）。落点走 work_spot_for（占格外圈一格）。
func _leave_inside_site() -> void:
	if _inside_site == null:
		return
	var site: Node3D = _inside_site
	_inside_site = null
	if site != null and is_instance_valid(site) and site.has_method("release_builder"):
		site.call("release_builder", self)
	if site != null and is_instance_valid(site):
		var at: Vector3 = global_position
		if site.has_method("work_spot_for"):
			at = site.call("work_spot_for", self)
		global_position = RtsWorld.ground(RtsWorld.walkable_pos(at))
	_restore_after_inside()


## **被建筑反向叫出来**（完工 / 被拆）：建筑那边已经把名单清了，这里只做本单位收尾。
## `at` = 放出来的落点（建筑给的占格外圈一格）；零向量 = 就地找可站点。
func exit_build_site(at: Vector3) -> void:
	var was_inside: bool = _inside_site != null
	_inside_site = null
	_restore_after_inside()
	var p: Vector3 = at if at != Vector3.ZERO else global_position
	global_position = RtsWorld.ground(RtsWorld.walkable_pos(p))
	if was_inside:
		# 工地已经完工/没了：手上的 BUILD 指令到此为止，别下一帧又去钻一栋没了的房子
		if _build_site == null or not is_instance_valid(_build_site):
			order = RtsConst.Order.NONE
			state = RtsConst.State.IDLE


func _restore_after_inside() -> void:
	if visual != null:
		visual.visible = true
	_stop_moving()
	_work_spot_valid = false
	_speed = 0.0


## 在工地内部：每帧只推进进度。移动/分离/贴地/动画全部跳过（模型已隐藏）。
func _tick_inside_build(dt: float) -> void:
	# 同样不能用 `as RtsBuilding`：工地在拆掉的那一帧会被 free（见 _update_anim 的注释）
	var site = _inside_site
	if site == null or not is_instance_valid(site) or site.is_constructed or not site.is_alive():
		_leave_inside_site()
		order = RtsConst.Order.NONE
		_build_site = null
		state = RtsConst.State.IDLE
		return
	_stop_moving()
	state = RtsConst.State.BUILD
	site.advance_construction(dt, self)


## 修理：走到建筑旁 → 播 build 动画 → 让建筑按秒回血（木材由建筑侧扣）
func _order_repair_tick(dt: float) -> void:
	if _repair_target == null or not is_instance_valid(_repair_target):
		order = RtsConst.Order.NONE
		state = RtsConst.State.IDLE
		_work_spot_valid = false
		return
	var b := _repair_target as RtsBuilding
	if b == null or not b.is_alive() or not b.can_repair():
		order = RtsConst.Order.NONE
		_repair_target = null
		state = RtsConst.State.IDLE
		_work_spot_valid = false
		return
	if b.distance_to_footprint(global_position) <= _work_reach():
		_stop_moving()
		state = RtsConst.State.BUILD
		_face_pos(b.global_position, dt)
		b.repair_step(dt, self)
		return
	if not _work_spot_valid:
		_work_spot = b.work_spot_for(self)
		_work_spot_valid = true
		_go_to(_work_spot, true)
		state = RtsConst.State.MOVE
		return
	state = RtsConst.State.MOVE
	_go_to(_work_spot)
	if not _moving and b.distance_to_footprint(global_position) > _work_reach():
		_go_to(b.global_position)


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
	if not RtsUnit.dbg_perf:
		_go_to_impl(pos, force)
		return
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
		# ★ force = 目标换了（玩家新指令 / 工地站位 / 追击目标移动）：**必须立刻重算**。
		#   以前会被 `_repath_cd`（0.8s 节流）挡住，于是单位沿着**上一条旧路径**继续走：
		#   建造时旧路径的终点是「工地中心」（在占地里），农民绕建筑跑一大圈、
		#   看着像「农民站在工地旁边不动/乱走，进度不涨」。
		if force:
			_repath_cd = 0.0
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
	var perf: bool = RtsUnit.dbg_perf
	var _t_sg: int = Time.get_ticks_usec() if perf else 0
	var r: float = get_radius() * CLEAR_SAFETY
	# 落点必须留出 GOAL_MARGIN 的余量：站定后还要被同伴推、被分离挤，
	# 净空刚好 0.5 的落点一推就掉进阻挡判据，然后和 wall_pushout 对拉。
	if pf.is_standable(want, r + GridPathfinder.GOAL_MARGIN):
		if perf:
			RtsUnit.dbg_sgoal += Time.get_ticks_usec() - _t_sg
		return _spread_goal(want, r) if _spread_allowed() else want
	var near: Vector3 = pf.standable_near(want, global_position, r, GridPathfinder.GOAL_MARGIN)
	if perf:
		RtsUnit.dbg_sgoal += Time.get_ticks_usec() - _t_sg
	return _spread_goal(near, r) if _spread_allowed() else near


## 只有"走位类"指令才做占位分散。
##
## 采集/送资源/建造/修理**不能**分散：它们各有自己的站位判据
## （`_stand_off` 到资源点的间隙、`建筑.work_spot_for` 分好的格子），
## 再被 `_spread_goal` 往外推一把，反而会推到判定边界外 → 多走一趟。
## 2026-11-06 实测：采集压力测试的金币增量波动变大就是这个副作用。
func _spread_allowed() -> bool:
	match order:
		RtsConst.Order.GATHER, RtsConst.Order.RETURN_RES, \
		RtsConst.Order.BUILD, RtsConst.Order.REPAIR:
			return false
	return true


## **目标点已经被同伴占了 → 往旁边挪一格**（2026-11-06 玩家口径"挤开"的根治）。
##
## 老行为：一支队伍右键同一个点，所有人的落点解析结果**完全相同**（纯几何、无占位判断），
## 于是 12 个人抢一格，全靠分离互相顶 —— 顶出去的人再走回来，就是"进进出出"。
## 更糟的一种：部队右键在工地/建筑旁边，解析出的最近可站点恰好是**农民站的那一格**，
## 兵一脚把农民顶出工地，建造进度归零。
##
## 现在：落点周围先看有没有人（含正在干活的农民），有人就沿环上找一个空位。
## 候选顺序按本单位实例 id 固定，所以**同一个兵每次算出来的空位是同一个**，
## 不会每帧换位置（那是抖动的来源）。
func _spread_goal(center: Vector3, r: float) -> Vector3:
	if not is_mobile():
		return center
	if not _spot_taken(center, r):
		return center
	var pf := _pathfinder()
	if pf == null:
		return center
	var ring: float = maxf(SLOT_PROBE, r * 2.0 + 0.25)
	var base: float = fposmod(float(get_instance_id() % 997) * 0.0137, TAU)
	var best: Vector3 = center
	var best_score: float = INF
	var steps: int = 10
	for i in range(steps):
		var a: float = base + TAU * float(i) / float(steps)
		var cand: Vector3 = center + Vector3(cos(a), 0.0, sin(a)) * ring
		if not pf.is_standable(cand, r + GridPathfinder.GOAL_MARGIN):
			continue
		if _spot_taken(cand, r):
			continue
		var score: float = _flat_dist(cand) + 0.6 * Vector2(cand.x - center.x, cand.z - center.z).length()
		if score < best_score:
			best_score = score
			best = cand
	return best


## 这一格有没有**会动的友军/任何单位**站着（建筑由寻路网格管，不算）
func _spot_taken(pos: Vector3, r: float) -> bool:
	var hash: SpatialHash = _shared_hash()
	if hash == null:
		return false
	var need: float = r + 0.45
	for o in hash.query(pos, need + 1.6):
		if o == self or o == null or not is_instance_valid(o):
			continue
		var u := o as RtsUnit
		if u == null or u.def == null or not u.is_alive():
			continue
		if not u.is_mobile():
			continue
		# ★ 敌人不算"占位"（2026-11-07）：这条判据的语义是"友军已经站了这格，我换一格"，
		#   而攻击站位本来就该贴到敌人身上。把敌人算进来会让包围点被推到 1.15m 外，
		#   近战于是又落在射程外 —— 这是"多个近战只有一个能打"的第三个根因。
		if faction != null and u.faction != null and faction.is_enemy_of(u.faction):
			continue
		var dx: float = pos.x - u.global_position.x
		var dz: float = pos.z - u.global_position.z
		var lim: float = (need + u.def.body_radius) * SLOT_OCCUPIED * 0.5
		if dx * dx + dz * dz < lim * lim:
			return true
	return false


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
	# 走 RtsWorld：它负责把 y 贴到地形高度。
	# ★ 2026-11-07：**大身位要自己报净空**。默认 agent_radius=0.5 是步兵身位；
	#   0.58 的蒸汽重步兵拿 0.5 的净空去规划，A* 会给出「1 格宽的缝」，
	#   到了缝口被 `_steer` 的清空判据顶死 = 玩家看到的「卡在树/墙边不动」。
	#   但门槛抬太高会让 A* 展开数爆炸（118² 实测 272 → 2226），
	#   所以只给**真的超过默认身位**的兵种传参，普通兵继续吃默认值（零性能代价）。
	var pr: float = -1.0
	if def != null and def.body_radius > 0.52:
		pr = def.body_radius * 0.98
	_path = RtsWorld.find_path(global_position, goal, pr)
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


## 本帧的"推挤体重"：1.0 = 普通；ANCHOR_WEIGHT = 正在干活，几乎推不动。
##
## 玩家口径（2026-11-06）「部队把正在建筑的农民挤开」的直接解法。
## 为什么不用"把农民锁死"：锁死会让人堆在工地里出不来，也会挡住别人走路。
## 用权重，人和人还是能错开，只是**站着干活的那个基本不动**。
func _anchor_weight() -> float:
	if _dying:
		return 1.0
	# 正在抡锤 / 抡镐 / 挥刀：脚下生根
	if state == RtsConst.State.BUILD or state == RtsConst.State.GATHER \
			or state == RtsConst.State.ATTACK:
		return ANCHOR_WEIGHT
	if order == RtsConst.Order.BUILD or order == RtsConst.Order.REPAIR \
			or order == RtsConst.Order.GATHER:
		return ANCHOR_WEIGHT
	return 1.0


## 单位分离：一重叠就互相推开，别挤成一坨
func _update_separation(dt: float) -> void:
	if def == null:
		return
	# 建筑是"绝对障碍"：只推别人，自己不动
	if not is_mobile():
		return
	var hash: SpatialHash = _shared_hash()
	var my_r: float = def.body_radius
	var my_w: float = _anchor_weight()
	var push := Vector3.ZERO
	# ★ 复用查询缓冲（2026-11-07）：分离是每单位每帧的最大单点，
	#   老 `hash.query()` 每次新建数组 + append_array，3000 单位 ≈ 每秒十几万次分配。
	#   缓冲区只在这个函数里用、用完即弃，不存在跨帧引用。
	hash.query_into(global_position, my_r * 6.0, _near_buf)
	var near: Array = _near_buf
	if near.is_empty():
		return
	# 预乘 SEPARATION_FACTOR：min_d = (a + b) * f ≡ a*f + b*f，内层少一次乘法
	var my_rf: float = my_r * SEPARATION_FACTOR
	for o in near:
		if o == self:
			continue
		# 顺序很重要：先 is_instance_valid 再 `is` 再带类型赋值 ——
		# 对已 free 的对象做 `var x: RtsUnit = o` 会抛 "Trying to cast a freed object"。
		if not is_instance_valid(o):
			continue
		if not o is RtsUnit:
			continue
		var other: RtsUnit = o
		var odef: UnitDef = other.def
		if odef == null:
			continue
		# 钻进工地里的农民没有体积：别让旁边的兵被一个"看不见的人"顶开。
		# 直接读字段（等价 is_inside_build()）——这是内层循环，少一次函数调用就够喝一壶。
		if other._inside_site != null:
			continue
		var min_d: float = my_rf + odef.body_radius * SEPARATION_FACTOR
		if min_d <= 0.0001:
			continue
		var dx: float = global_position.x - other.global_position.x
		var dz: float = global_position.z - other.global_position.z
		var d2: float = dx * dx + dz * dz
		if d2 >= min_d * min_d:
			continue
		var d: float = sqrt(d2)
		# 双方各让一半；干活的一方只让 13%，走过来的一方吃剩下的推力。
		var share: float = 1.0
		if odef.kind == RtsConst.Kind.UNIT:
			var ow: float = other._anchor_weight()
			# ★ 自己承担的位移比例 = 自己的权重 / 双方权重之和。
			#   老实现写的是 `2.0 * my_w / (my_w + ow)` —— 两个普通兵会各推 100%，
			#   合计 200%，一重叠就超调弹开，形成"顶出射程 → 走回来 → 再顶出去"的往复。
			#   这是"多个近战只有一个能打到人"的第二个根因（第一个是全员冲向目标中心）。
			share = clampf(my_w / maxf(my_w + ow, 0.0001), 0.0, 1.0)
		if d < 0.0001:
			# 完全重合：按实例 ID 给个确定方向，别抖
			var ang: float = float(get_instance_id() % 628) * 0.01
			push += Vector3(cos(ang), 0.0, sin(ang)) * min_d * share
			continue
		var overlap: float = min_d - d
		push += Vector3(dx / d, 0.0, dz / d) * overlap * share

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


## 攻击能打到的距离。
##
## ★ 2026-11-07 统一口径（玩家反馈"弩兵实际射程比圈大、还能打雾里的敌人"）：
##   `UnitDef.attack_range` = **本单位碰撞圆边缘 → 目标碰撞体边缘的水平间隙（米）**。
##   旧实现 `_attack_reach` 又加了一次目标半径、`_target_gap` 又减了一次，
##   结果真实够得着 = attack_range + 2×目标半径（步兵 1.35 → 实际 2.35），
##   而范围圈按 attack_range 画 → 圈永远比实际小一大截。
##
##   现在：`_attack_reach` 只返回 attack_range，`_target_gap` 把**双方**半径都扣掉。
##   于是"贴身必中"= attack_range ≥ 0.2 就一定成立（0 = 两具身体正好贴住）。
##
##   建筑目标例外：寻路把占地外扩 1 格，最近的合法站位离墙 1.50m（见 AGENTS/memory），
##   扣掉自身半径 0.5 后边缘间隙仍有 1.0m —— 近战给 `BUILDING_REACH` 的墙面余量，
##   否则"贴到墙边也砍不到楼"。
const BUILDING_REACH: float = 1.15
func _attack_reach(t: Node3D) -> float:
	var r: float = def.attack_range if def != null else 0.0
	if t is RtsBuilding:
		r = maxf(r, BUILDING_REACH)
	return maxf(r, 0.05)


## 到目标的**有效间隙**：建筑量到墙面，单位量到身位边缘（双方半径都扣掉）。
##
## 近战打建筑必须用这个，不能用中心距（见 建筑.distance_to_footprint 的注释）。
func _target_gap(t: Node3D) -> float:
	if t == null:
		return INF
	var b := t as RtsBuilding
	if b != null:
		var d: float = b.distance_to_footprint(global_position)
		# 自己也扣掉半径：口径统一成"边缘到墙面"，否则大本营 9m 宽会把近战挡在 4.5m 外
		d -= get_radius()
		return maxf(d, 0.0)
	var d: float = _flat_dist(t.global_position)
	if t.has_method("get_radius"):
		d -= float(t.call("get_radius"))
	d -= get_radius()
	return maxf(d, 0.0)


## 交战站位：**不要所有人都冲向敌人中心**，而是沿目标外圈各站一边。
##
## 建筑：墙面外扩一圈，按实例 id 在朝向上散开 ±26°（一队近战不会全挤在同一面墙）。
##
## 单位（2026-11-07 新增）：玩家口径「多个近战靠近同一个敌人，只有一个能正常攻击」。
##   根因是所有兵都 `_go_to(敌人中心)`，解析出的落点完全重叠 → 分离力把外圈的人
##   顶出射程 → 它再往中心挤 → 又被顶出去。只有最里面那个能稳定贴着。
##   现在每个人站到自己**来向**那一侧的外圈（中心距 = 目标半径 + 自身半径 + 射程×0.85），
##   天然围成一圈；同一方向来的两个兵再按 id 错开一点角度。
func _attack_spot(t: Node3D) -> Vector3:
	if t == null or not is_instance_valid(t):
		return global_position
	var b := t as RtsBuilding
	if b == null:
		return _surround_spot(t)
	if b.def == null:
		return t.global_position
	var fp: Vector2i = b.def.footprint
	var hx: float = float(maxi(fp.x, 1)) * 0.5
	var hz: float = float(maxi(fp.y, 1)) * 0.5
	var to: Vector3 = global_position - t.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		to = Vector3(0.0, 0.0, 1.0)
	to = to.normalized()
	var jitter: float = (fposmod(float(get_instance_id() % 89) * 0.01, 1.0) - 0.5) * 0.9
	var a: float = atan2(to.z, to.x) + jitter
	var dir := Vector3(cos(a), 0.0, sin(a))
	# 沿该方向射出，落到矩形边界外 0.55m
	var tx: float = hx / maxf(absf(dir.x), 0.0001)
	var tz: float = hz / maxf(absf(dir.z), 0.0001)
	var out: float = minf(tx, tz) + 0.55
	return t.global_position + dir * out


## 单位目标的外圈站位（包围点）。
##
## ★ 半径必须把 `_update_move` 的到点容差算进去（这是"近战站在敌人旁边不动手"的真凶）：
##   单位在离落点 ARRIVE_TOLERANCE(0.35m) 时就 `_settle()` 落定，落定后闩锁不允许重启。
##   如果站位点正好压在射程边缘，落定位置就必然落在射程**外** 0.35m，
##   于是每帧算出来"还差 5cm 够不着"，但既不攻击也不移动 —— 玩家看到的是集体罚站。
##   所以要把落点往目标怀里收 `ARRIVE_TOLERANCE + 0.08`，让"最远的落定位置"仍在射程内。
func _surround_spot(t: Node3D) -> Vector3:
	if t == null or not is_instance_valid(t):
		return global_position
	var tr: float = 0.0
	if t.has_method("get_radius"):
		tr = float(t.call("get_radius"))
	var reach: float = _attack_reach(t)
	# 想要的"边缘间隙"：扣掉到点容差后仍有余量；近战会收到 ≈0.02，靠分离力自然分开
	var gap_want: float = clampf(reach - ARRIVE_TOLERANCE - 0.08, 0.02, maxf(reach * 0.9, 0.02))
	var want: float = tr + get_radius() + gap_want
	var to_self: Vector3 = global_position - t.global_position
	to_self.y = 0.0
	if to_self.length_squared() < 0.0001:
		# 完全重合：按 id 给一个确定方向（同一帧不会全挤在 0°）
		var a0: float = float(get_instance_id() % 628) * 0.01
		to_self = Vector3(cos(a0), 0.0, sin(a0))
	var side: float = (fposmod(float(get_instance_id() % 97) * 0.01, 1.0) - 0.5) * 0.55
	var dir: Vector3 = to_self.normalized().rotated(Vector3.UP, side)
	return t.global_position + dir * want


## 站位间隙（采集/建造用）：attack_range/2 + 双方半径 + 一点空隙


## 站位间隙（采集/建造用）：attack_range/2 + 双方半径 + 一点空隙
func _stand_off(t: Node3D) -> float:
	var r: float = def.body_radius + GATHER_GAP
	if def != null:
		r += def.attack_range * 0.5
	if t != null and t.has_method("get_radius"):
		r += float(t.call("get_radius"))
	return maxf(r, 0.6)


## 警戒圈半径：待机/警戒时**看得见、愿意走过去打**的距离。
##
## 为什么要单独一个半径（2026-11-07）：
##   以前待机索敌直接用 `attack_range`（近战 1.35m），改成"贴身 0.3m"以后，
##   一个敌人站在 1.2m 外、步兵却一辈子不理他 —— 玩家看到的是"兵在旁边装死"。
##   现在近战给 `attack_range + 3`（约 3.3m，一个身位多一点），远程按视野封顶。
##   走过去的距离仍然受 acquire_range / sight_range 约束，不会隔半张图冲锋。
func _guard_radius() -> float:
	var base: float = def.attack_range if def != null else 0.0
	var want: float = maxf(base + 3.0, 3.5)
	if def != null and def.acquire_range > 0.0:
		want = minf(want, def.acquire_range)
	if def != null and def.sight_range > 0.0:
		want = minf(want, def.sight_range)
	return maxf(want, base + 0.1)


## 当前指令会不会"追出去"（决定索敌半径，也决定够不着时追不追）
##
## ★ 待机/警戒也要能"走过去打"：只要当前锁定的目标还在警戒圈里就允许追。
##   不然 `_update_attack` 会因为 `not _may_pursue()` 直接 target=null，
##   近战永远够不着 1m 外的敌人。
func _may_pursue() -> bool:
	if not is_mobile():
		return false
	if order == RtsConst.Order.ATTACK \
			or order == RtsConst.Order.ATTACK_MOVE \
			or order == RtsConst.Order.MOVE:
		return true
	if target != null and is_instance_valid(target) and target.is_alive():
		return _flat_dist(target.global_position) <= _guard_radius()
	return false


## 自动索敌：走 Game 的注册表（不遍历场景），带分片。
##
## 待机/警戒：在**警戒圈**内找，找到就允许走过去（见 _guard_radius / _may_pursue）。
## 行军：只在前方 45% 索敌半径内反应，不改变原路线。
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
	var scan_r: float = def.acquire_range if pursue else _guard_radius()
	var radius: float = scan_r * radius_scale
	if radius <= 0.0:
		return
	var cand: Node3D = Game.find_nearest_enemy(global_position, faction, radius)
	# ★ 看不见的敌人不许锁（迷雾口径，唯一出口 Game.is_node_visible_to）：
	#   以前弩兵能隔着黑雾锁定 12m 外的野怪并一路射死，玩家完全看不到目标。
	if cand != null and not Game.is_node_visible_to(faction, cand):
		cand = null
	if cand != null and not pursue and _target_gap(cand) > _attack_reach(cand):
		cand = null
	target = cand


## 攻击循环：冷却 → 前摇（攻击动画）→ 出手 → 后摇


## 攻击循环：冷却 → 前摇（攻击动画）→ 出手 → 后摇
func _update_attack(dt: float) -> void:
	if def == null or not def.can_attack():
		return
	# 干活 / 逃跑 / 撤退时不打
	if order == RtsConst.Order.GATHER or order == RtsConst.Order.BUILD:
		return
	if _flee_t > 0.0 or _retreat:
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

	# ★ 目标跑进黑雾/树林阴影里 → 立刻放掉锁定。看不见就打不了，
	#   否则会出现"对着空气挥砍/放箭"（玩家 2026-11-06 反馈）。
	if not Game.is_node_visible_to(faction, target):
		target = null
		return

	var reach: float = _attack_reach(target)
	var dist: float = _target_gap(target)

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
		# ★ 打建筑走"墙外一圈的站位"，打单位走"包围点"，都不走中心。
		#   走中心 → 全队抢同一格 → 互相顶开 → 只有最里面那个能持续攻击
		#   （2026-11-06 打建筑的玩家口径 / 2026-11-07 打单位的玩家口径）。
		#
		# ★★ **最后一小步必须强制重走**（2026-11-07，这是"近战站在敌人旁边不动手"的真凶）：
		#   `_update_move` 的到点容差是 0.35m，而到点闩锁又会把"离目标 0.9m 内"的
		#   重新起步全部拦掉。于是单位在离敌人 0.3m（射程外一点点）处落定，
		#   之后每帧算出来"还差 0.05m 够不着"，但 `_go_to` 被闩锁挡住 → 永远挥空。
		#   这里对"已经落定、但只差一点点"的情况给一次强制：真的迈完最后半步。
		var spot: Vector3 = _attack_spot(target)
		var last_step: bool = _arrived_goal and dist <= reach + 1.2
		_go_to(spot, last_step)
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
	return _target_gap(target) <= _attack_reach(target)


## 起手：前摇 = 冷却 × attack_windup，这段放攻击动画


## 起手：前摇 = 冷却 × attack_windup，这段放攻击动画
func _begin_swing() -> void:
	if def == null:
		return
	_swinging = true
	_attack_cd = maxf(def.attack_cooldown, 0.1)
	dbg_swings += 1
	_windup_t = _attack_cd * clampf(Cfg.game.attack_windup, 0.05, 0.95)
	state = RtsConst.State.ATTACK
	if visual != null:
		# ★ 必须 force：连着砍同一栋楼时 state 一直是 ATTACK，
		#   不去重的话第二刀起就没有挥砍动作了（2026-11-06 玩家报的"不播攻击动画"）。
		visual.play("attack", 1.0, true)


## 出手：近战立刻结算，远程发投射物（伤害在落点）


## 出手：近战立刻结算，远程发投射物（伤害在落点）
##
## ★ 出手前**再验一次**距离与可见性（2026-11-07）：
##   前摇有 0.2~0.5s，目标在这段时间里跑出射程/钻进黑雾时，老代码照样结算伤害，
##   玩家看到的是"弩兵隔着半张地图把人射死"。现在超出「射程 + 0.5m 容差」就收手。
func _release_attack() -> void:
	_swinging = false
	if def == null:
		return
	if target == null or not is_instance_valid(target) or not target.is_alive():
		target = null
		return
	if not Game.is_node_visible_to(faction, target):
		target = null
		return
	if _target_gap(target) > _attack_reach(target) + 0.5:
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
		# ★ 不标注 Node3D：这一格存的是**别人的** `_gather_node`，资源点被采空后会 free，
		#   悬空引用一旦被"带类型的赋值"接住，引擎会每帧抛
		#   "Trying to assign invalid previously freed instance" 并**中断整个函数**
		#   （= 这个农民这一帧找不到矿，等于采集逻辑随机失效，同时日志被刷爆）。
		#   用无类型 var 接住 + is_instance_valid 过滤，行为不变、错误消失。
		var n = u.get("_gather_node")
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
	# ★ 树按「次数」扣（玩家口径 2026-11-07）：这一趟采完 = 扣 1 次，拿满 cap 木头。
	#   金矿仍然按吨位扣（3200 金一次搬 10）。两种口径分开见 可采集物.consume_charge。
	var got: int = 0
	if _gather_node.has_method("is_charge_based") \
			and bool(_gather_node.call("is_charge_based")):
		got = int(_gather_node.call("consume_charge", cap))
	else:
		got = int(_gather_node.call("consume", cap))
	if got <= 0:
		_gather_phase = GatherPhase.TO_NODE
		return
	# AI 有经济倍率（难度档），玩家恒为 1.0
	got = int(round(float(got) * _gather_multiplier()))
	_carry = got
	_gather_t = 0.0
	_gather_phase = GatherPhase.TO_DROP
	# 背着就走：载位立刻让出（去卸货的路上，别人可以占这个位置）
	_release_gather_slot()
	_chop_phase_prev = -1.0
	_chop_armed = false
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
	deposit_gold_total += gold
	deposit_wood_total += wood
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
	# ★ 钻在工地里：模型必须一直是隐藏的。
	#   下面"离开矿洞 → visual.visible = true"的兜底判据是 `not visual.visible`，
	#   它会把人从房子里"显示"出来（建造自检的 `隐藏 0/4` 就是它）。
	if _inside_site != null:
		visual.visible = false
		return
	var ratio: float = 1.0
	var ms: float = _max_speed()
	if ms > 0.01:
		ratio = clampf(_speed / ms, 0.15, 1.6)
	# ★ 采金矿：人"钻进矿洞"（2026-11-06 玩家口径「农民采集金矿换为要进入金矿」）。
	#   只动**视觉**，逻辑点不动 —— 单位仍然站在矿边的可走格上，
	#   所以寻路/碰撞/被攻击都还是老行为，不会有人卡在矿里出不来。
	#   做法：采金那段把模型往下沉 0.95m 并缩 12%，沉到底就隐藏；
	#   离开 HARVEST 自动升回来（move_toward 兜住一切异常中断）。
	# ★ 只对**可移动单位**做（建筑不能进矿洞；而且建筑的 `visual.position.y`
	#   被 建筑._install_pad 设成 PAD_LIFT=0.09 用来治 z-fighting，这里一重置就又闪了）。
	if is_mobile():
		# ⚠ **不能写 `var mine: Node3D = _gather_node as Node3D`**（2026-11-07 抓到）：
		#   树被砍倒后节点会 free，而 `as` 对已释放对象会抛
		#   "Trying to cast a freed object" 并**中断整个 _update_anim** ——
		#   表现是伐木工每帧刷一条 ERROR、动画/shake 全停（日志里几万条）。
		#   无类型 var 接住 + is_instance_valid 判据（和 _find_harvestable 的注释同一条规矩）。
		var mine = _gather_node
		var can_enter: bool = state == RtsConst.State.GATHER \
				and _carry_kind == RtsConst.Harvest.GOLD \
				and mine != null and is_instance_valid(mine) \
				and mine.has_method("mouth_point")
		# ★ 2026-11-06 玩家口径「农民采矿直接没入地下，太奇怪了，要走进金矿」：
		#   旧版是**纯竖直**沉 0.95m 再隐藏 —— 人往土里钻，而且站位离矿心 3.3m，
		#   是在矿外的空地上入土。现在改成**朝矿口水平走进去**：
		#   洞底本来就在 y≈0.04，人只要走平（只压 0.18m 做"进深"），
		#   最后 0.55m 被矿口那块不透明暗板挡住，到 0.995 再隐藏兜底。
		_mine_k = move_toward(_mine_k, 1.0 if can_enter else 0.0,
				get_process_delta_time() * 2.0)
		if can_enter and _mine_k > 0.001:
			var mp: Vector3 = to_local(mine.call("mouth_point", global_position) as Vector3)
			var flat := Vector2(mp.x, mp.z)
			# 兜底：从矿背面/侧面来的人不许横穿 2.2m 石头
			if flat.length() > 2.2:
				flat = flat.normalized() * 2.2
			# ★ 2026-11-07：**只走平**，不再往下压 0.18m。
			#   旧版"水平走 + 下沉 + 缩 5%" 叠在一起，走到一半看起来像半截人钻进土里。
			#   现在完全水平推进到矿口，0.72 就隐藏（岩石本身是遮挡物，看不出"凭空消失"）。
			visual.position = Vector3(flat.x * _mine_k, 0.0, flat.y * _mine_k)
			visual.visible = _mine_k < 0.72
		elif visual.position != Vector3.ZERO or not visual.visible:
			# 回来时恢复原样（不能只靠"小于阈值"分支，否则会留一个 -0.0001 的偏差）
			visual.position = Vector3.ZERO
			visual.scale = Vector3.ONE
			visual.visible = true
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
			# 速度 = 一趟正好挥 N 下（见 _gather_anim_speed）；不是 1.0 的死板循环
			visual.play("gather", _gather_anim_speed())
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
