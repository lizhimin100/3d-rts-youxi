class_name SimpleAI
extends Node
## **简单 AI**：一个"真有压力"的对手，不是站着挨揍的木头人。
##
## 一次思考（think）的流水线（顺序不是随意的，见每一步的注释）：
##   ① 命令调度器开局（本 tick 的预算/去重上下文）
##   ② 战略导演算指标 → 选计划 → 产出姿态 Posture
##   ③ 经济：补农 / 派采集 / 补人口
##   ④ 生产：按"每金战力 + 克制矩阵"选兵（不再是纯权重抽签）
##   ⑤ 科技：铁匠铺升级（旧版从来不做，金币全堆着）
##   ⑥ 军事：残血撤退 / 回防 / 巡逻 / 成波推进
##   ⑦ 反愚蠢审计**最后**跑 —— 它的救火命令要覆盖前面所有命令
##   ⑧ flush：真正把命令发出去（所有命令都受控制权过滤）
##
## 三条纪律：
##   · **不能抢玩家单位**：所有下令都经 CommandScheduler → Game.control 过滤；
##   · **不能下命令风暴**：到达判定 / 重发节流 / 卡死退避都在调度器里；
##   · **不能硬编码数值**：难度档 + 战略计划表 + 单位表，代码里只有结构。

## 日志前缀（只在关键决策打印，不刷屏）
const LOG_PREFIX: String = "[AI]"
## 战略权重开关（分母取法 A/B/C）。默认 A = 现状；bench 用 --ratio-mode 覆盖。
const AIW := preload("res://代码/配置/AI战略权重.gd")
## 判定口径开关（old/new）+ 理论值参数。默认 new；bench 用 --verdict-mode 覆盖。
const AIV := preload("res://代码/配置/AI判定模式.gd")
## 2C-12：直接引战斗模型拿**承诺表的常量与状态枚举**（TTL / 人口门槛 / 状态名）。
## ★ 只读常量，不 new 实例 —— 场景侧真正的调用仍走 `_model_call`（统一入口）。
const BM := preload("res://代码/ai/战斗模型.gd")
## 2C-13：三层新增的纯逻辑模块（世界状态 / 目标层 / 计划层）。
## ★ 与 BM 同一套写法：只读常量与 static 函数，不 new 实例。
##   三者都不 include 引擎/场景依赖，所以 `--script` 的配置回归能直接 load 断言。
const WS := preload("res://代码/ai/世界状态.gd")
const GL := preload("res://代码/ai/目标层.gd")
const PL := preload("res://代码/ai/计划层.gd")
## 大本营最多排几个农民（农民便宜，排两个不心疼）
const MAX_QUEUE_PEASANT: int = 2
## 兵营最多排几个兵。
## ⚠ 这里必须是 1：排 2 个会把两笔钱一起锁在队列里，等第二座兵营盖好时
## 已经付不出这个兵的钱，结果产能白建、军队反而更少（实测过，别改成 2）。
const MAX_QUEUE_ARMY: int = 1
## 农民允许比军队多几个。超过就先补兵（"先有枪杆子，再贪经济"）。
## ★ 2C-2：这条只在"没有支出压力"时生效 —— 打不起兵的时候，补农民才是出路。
const VILLAGER_ARMY_GAP: int = 2
## 补经济时农民目标的临时增量（2C-2）：支出需求 > 收入时 +2，压力消失自动回落。
const PEASANT_EMERGENCY_BONUS: int = 2
## 2C-4 农民软上限（**直接覆盖旧上限 10**，任务书 §4.4）：采金人数到这个数 → 转采木。
## TODO 初始值待农民测试（§4.4）产出后取下沿标定
## ★ 2026-11-06 玩家口径「决策系统里采矿的农民数量改为 5 个」：
##   5 金 + 5 木 + 2 工位 = 12（总数不变，只是把 3 个采金的挪去采木）。
##   只改这一行会让 PEASANT_TOTAL_CAP 从 12 掉到 9 —— 农民总量跟着缩水，
##   所以 PEASANT_WOOD_TARGET 一起从 2 提到 5。
const PEASANT_GOLD_SOFT_CAP: int = 5
## 2C-7 P0 农民工位（用户拍板）：**采金 8 + 采木 3 + 建造/修理 1 = 12**。
## 旧口径是"软上限 8 + 4 个机动农民"—— 那 4 个既伐木又建造，于是每次"该修"时
## 都有人在盖房/砍树，repair_stats 里 10 min 局 **76 次 candidates / 0 次 issued**
## （2C-6 §7-1）。现在把 4 拆成 3 + 1：3 个专职伐木，1 个专职建造/修理（闲置时也砍树）。
## ★ **总数仍是 12**，不是加人；改的是"这 12 个人各自负责什么"。
##
## ★ 2C-8 P0（用户拍板，覆盖上面的 8:3:1）：**工位数动态化**
##   builder_count = max(2, ceil(农民总数 / 6))；
##   采金 = min(8, N − 工位)，采木 = N − 工位 − 采金。
##   满编 12 → 采金 8 + 采木 2 + 工位 2；15 → 8 + 4 + 3。
##   同时建造数 = 工位数 − 1（**至少留 1 个工位给修理**）；
##   无建造任务时全部工位可修；无修理任务时全部工位采木（不待命）。
##   ★ 总数仍是 12（PEASANT_TOTAL_CAP 不变），改的是"工位几个人、怎么分工"。
const PEASANT_WOOD_TARGET: int = 5
const PEASANT_BUILDER_SLOT: int = 2
## 总农民上限 = 采金 + 采木 + 工位 = 12（与 2C-6/2C-7 同数值，只是重新切分）
const PEASANT_TOTAL_CAP: int = PEASANT_GOLD_SOFT_CAP + PEASANT_WOOD_TARGET + PEASANT_BUILDER_SLOT
## 2C-8 P0：每 6 个农民配 1 个工位；工位下限 2（公式在 战斗模型.builder_count_for 里）
const PEASANT_PER_BUILDER: float = 6.0
## 2C-7 P0：农民角色（**报告/归因用枚举**，不参与判定表任何阈值）。
## 只在"为什么这个人没去修"这类归因里用；行为判据仍是 order/gather_kind。
enum PeasantRole { GATHER_GOLD, GATHER_WOOD, BUILDER }
## 2C-7 P1：人口占用 >90% = "顶到嗓子眼" → 农场走急建通道（排在兵营/军队之前）
const POP_CRITICAL_RATIO: float = 0.9
## 2C-7 P2：投资占比采样间隔（游戏秒）
const INVEST_SAMPLE_SEC: float = 60.0
## 采集配比再平衡的最小间隔（秒）。
## 不每 tick 重排：来回换采集点会让农民一直在走路，比不换更亏。
const GATHER_REBALANCE_CD: float = 8.0
## 2C-5 P1-4 修理：同一栋楼两次下令的最小间隔（秒）。
## 不节流会每 tick 重置 order_repair 的寻路目标 —— 农民在墙根反复起步，一秒也修不上。
const REPAIR_REISSUE: float = 1.5
## 每座兵营"负责"的军队规模上限：军队目标越大越要多盖兵营才能跟上出兵节奏。
const UNITS_PER_BARRACKS: float = 8.0
## 兵营数量上限（再多也没资源养）
const MAX_BARRACKS: int = 3
## 回防指令重新下达的间隔（秒）
const DEFEND_REISSUE: float = 4.0
## 找空位建造：搜索的环半径范围（米）。
## 起始半径从 8 提到 11：大本营 9.4m 宽（半宽 4.7），8m 的环会让兵营直接贴到它墙根。
const BUILD_SEARCH_MIN: float = 11.0
## 新建筑与已有建筑的**最小水平间隙**（米，外接矩形之间）。
## 3.5m ≈ 一个身位 + 屋檐挑出，既不会插在一起，也不会把基地摊成一片空地。
const BUILD_GAP: float = 3.5
const BUILD_SEARCH_MAX: float = 34.0
const BUILD_SEARCH_STEP: float = 3.0
## 每个环采样多少个方向
const BUILD_SEARCH_ANGLES: int = 14
## 防守感知半径（米）：敌方战斗单位进到这个圈里就算"压家"。
## 取 18 的依据：大本营视野 15m、箭塔 14m，18 让 AI 比玩家早半步反应。
const DEFENSE_RADIUS: float = 18.0
## 残血撤退阈值（血量比例）
const RETREAT_HP: float = 0.32
## 巡逻间隔（秒）
const PATROL_INTERVAL: float = 9.0
## 派兵清野怪的最低兵力（副官会调高：它动的是玩家的兵）
var creep_clear_min_army: int = 4
## 一波里"出击"的比例（其余留守）。副官会覆盖成 0.70（更稳）。
var push_ratio: float = 0.82
## 【已废弃 · 2026-11-03 2C-2】保留金闸已从简单AI 的**全部**花销点删除，
## 建筑 / 农民 / 哨塔 / 兵营 / 农场 / 营火统一走"钱够就花"（见 _can_spend）。
## 保留这两个常量与实例变量**只为副官**（`副官.gd` 用它自己的 480/140 口径和一条
## 独立的补农闸），简单AI 的任何决策都不再读它们 —— 不要再往这里加回"必须留 X 金"。
const RESERVE_GOLD: int = 150
const RESERVE_WOOD: int = 40
## @deprecated 仅副官/日志使用；简单AI 决策不读（保留金闸已删除，见 _can_spend）
var reserve_gold: int = RESERVE_GOLD
var reserve_wood: int = RESERVE_WOOD

## **外部注入的指挥阵营**：副官用它指挥玩家阵营；敌方 AI 不传，走 Game.enemy_faction。
## 这样"一套大脑"能同时驱动人机和副官，行为不会分叉成两套怪东西。
var command_faction: RtsFaction = null
## 思考节奏倍率（副官用 0.8：比"一般中等 AI"反应更快）
var think_scale: float = 1.0
## 日志前缀（子类可换成 [副官]）
var log_prefix: String = LOG_PREFIX

var _faction: RtsFaction = null
var _think: float = 0.0
## 巡逻/撤退节流
var _patrol_cd: float = 0.0
## 巡逻轮次（确定性伪随机的"序号"输入，见 _dhash01）
var _patrol_seq: int = 0
## 采集配比再平衡冷却（秒，2C-2）
var _gather_cd: float = 0.0
## 2C-7 P0 / 2C-8 P0：建造/修理工位（农民 instance_id 数组；空 = 未指派）。
## ★ 这是**持久状态**，不是每 tick 现算的：靠 order 判"谁是建造工"分不清
##   "工位在砍树（待命）"和"普通伐木工"，两者 order 都是 GATHER/WOOD。
## 2C-8：从单值 `_builder_uid` 扩成数组，数量 = max(2, ceil(N/6))，随农民总数重算。
var _builder_uids: Array[int] = []
## 2C-7 P0：工位任期（秒）+ 换人次数（诊断：频繁换人说明农民在死/被打断）
var _builder_tenure: float = 0.0
var _builder_swaps: int = 0
## 2C-7 P1：本 tick 算出的军队目标（bench 曲线逐帧读它；-1 = 无上限）
var army_target_now: int = -1
## 2C-7 P2：投资占比监控（**只记录，不自动调整**）。
##   farm_* = 农场建造支出，army_* = 训练战斗单位支出；样本按 INVEST_SAMPLE_SEC 采。
var invest_stats: Dictionary = {
	"farm_gold": 0, "farm_wood": 0, "army_gold": 0, "army_wood": 0,
	"samples": [], "over_invest_60s": 0,
}
var _invest_cd: float = 0.0
var _invest_prev: Dictionary = {"farm": 0, "army": 0}
## 2C-8 P2：用工诊断（**只读不改**）—— 工位数 / 同时建造 / 同时修理。
##   max_concurrent_build   同一 tick 最多几个人在 order=BUILD（自带口径）
##   build_over_limit_ticks 同时建造数 > 工位数−1 的 tick 数（必须 0）
##   concurrent_repairs     "≥2 个工位同时修**不同**建筑"的 tick 数（验收 ≥1）
var labor_stats: Dictionary = {
	"builder_slots": 0, "max_concurrent_build": 0, "build_over_limit_ticks": 0,
	"concurrent_repairs": 0, "max_concurrent_repairs": 0, "samples": 0,
}
## 2C-8 P2：农场建不成的归因（每次"想建但没建成"记一个原因）
##   no_builder 工位全忙 / no_wood 木不够 / no_gold 金不够 / no_spot 选址失败 /
##   lost 建到一半被拆（在 _tick_build_diag 里对工地快照结算）
var farm_fail_stats: Dictionary = {
	"no_builder": 0, "no_wood": 0, "no_gold": 0, "no_spot": 0, "lost": 0,
}
## 农场工地快照：instance_id → true（建完/被拆时结算并移除）
var _farm_sites: Dictionary = {}
## 2C-8 P2：训练队列排不满的归因（每 60 s 采一次，**只记录**）
##   no_gold / no_wood / no_pop / queue_full / no_producer / ok
var train_stats: Dictionary = {
	"no_gold": 0, "no_wood": 0, "no_pop": 0, "queue_full": 0, "no_producer": 0,
	"ok": 0, "samples": 0,
}
var _train_diag_cd: float = 0.0
## 2C-8 P2：训练阻塞采样间隔（游戏秒）
const TRAIN_DIAG_SEC: float = 60.0
## 入夜收队轮次（同上）
var _night_seq: int = 0
## 下一波的时间点（秒，Game.elapsed 口径）
var _next_wave_at: float = 0.0
## 已发起波数
var _wave_index: int = 0
## 上次成功出击的时刻（秒，Game.elapsed 口径）。C 模式的衰减时钟用它，
## 也是"上一次真的打出去是什么时候"的唯一依据（不另存一份状态）。
var _last_attack_t: float = 0.0
## 回防冷却
var _defend_cd: float = 0.0
## 是否已初始化（打印过一次开局日志）
var _announced: bool = false
## 上次打印"为什么不出击"的时刻（诊断，25 秒一条）
var _last_block_log: float = -999.0
## 本 tick 的指标 + 姿态（调试与自检读它）
var metrics: Dictionary = {}
var posture: Dictionary = {}

## ===========================================================================
## 2C-9 · 三条线部门化（dept=on）的状态
##
## 四层上下文（用户拍板 §3.5）：
##   ctx0  L0 当前快照      —— 每 tick 覆盖写
##   ctx1  L1 短窗口聚合    —— 固定长度环形槽，槽位覆盖（内存 O(1)，不存事件列表）
##   demands_l2 L2 部门诉求 —— 每 2 s 全量重建，不跨周期累积
##   dept_stats L3 决策日志 —— 每 2 s 一行落盘，**不进决策**
## ===========================================================================
## 仲裁周期（秒）；与 `战斗模型.DEPT_CYCLE_SEC` 同值
const DEPT_CYCLE: float = 2.0
## 侦查节流（秒）：固定分诉求不节流会每 2 s 派一个人出去
const SCOUT_INTERVAL: float = 20.0
## L1 窗口：受伤 30 s（1 s 一个槽）/ 收支 60 s / 最近 3 波判定
const L1_DMG_SEC: int = 30
const L1_INCOME_SEC: int = 60
const L1_VERDICT_N: int = 3
## 出击锁的租约（秒）：攒大波最长 90 s + 一波最长 180 s，取 300 兜住
const DEPT_WAVE_LOCK_TTL: float = 300.0

var ctx0: Dictionary = {}
var ctx1: Dictionary = {}
var demands_l2: Array = []
var dept_stats: Dictionary = {
	"cycles": 0, "demands": 0, "executed": 0, "rejected": 0,
	"reject_by_reason": {},
	"win_train": 0, "win_train_peasant": 0, "win_build": 0,
	"win_push": 0, "win_defend": 0, "win_patrol": 0, "win_scout": 0, "win_tower": 0,
	"compete_train_build": 0, "compete_push_patrol": 0,
	"lock_wave_held": 0, "lock_wave_released": 0, "lock_wave_timeout": 0,
	"lock_patrol_held": 0, "lock_scout_held": 0,
	"lock_held_max": 0, "lock_held_last": 0,
	"requisitionable_written": 0,
	# 2C-10：可被征用消费 / 70% 系数触发 / 农场开工计数
	"requisition_times": 0, "requisitioned_units": 0,
	"farm_factor_triggers": 0, "farm_factor_last": 1.0,
	"farm_site_starts": 0,
	# 2C-11：储蓄 / 同时做事数 / 紧急 / POP90 修正口径（P2 监控，只落盘不进决策）
	"saving_reserve_last": 0.0, "saving_unit_cost_last": 80.0,
	"saving_urgent_last": false, "saving_urgent_hits": {},
	"saving_urgent_reasons_last": [],
	"caps_last": {}, "exec_per_cycle": {},
	"pop90_site_already": 0,
	# 2C-11 §4：建造停滞恢复（停滞工地数 / 成功接续数 -> P2 恢复率）
	"site_stall_detected": 0, "site_recovery_issued": 0,
	# 2C-12 §2.3：科技建筑诉求因"买不起"被生成侧跳过（只观测，回答"还常驻吗"）
	"tech_demand_skipped": 0,
	# 2C-12 §3：承诺表四个生命周期计数 + 局末残留 + 可自由资源（只观测，不进决策）
	"promise_made": 0, "promise_consumed": 0,
	"promise_expired": 0, "promise_preempted": 0,
	"promise_dropped_target_done": 0,
	"promise_left_at_end": 0,
	"promise_committed_last": 0, "promise_free_gold_last": 0.0,
	"promise_claim_skips": 0,
	# 2C-12 D 组哨兵：0 成本诉求被判「储备不足」（必须恒 0）
	"zero_cost_saving_rej": 0,
	# 2C-13 §2：世界状态适配器（每 tick 覆盖写；只观测，不进决策）
	"ws_writes": 0, "ws_fields_last": 0, "ws_regions_last": 0,
	# 2C-13 §4：目标层（主目标分布 / 空过 / 切换 / 预留 / 生命周期）
	"goal_cycles": 0, "goal_noop_cycles": 0,
	"goal_proposals_last": 0, "goal_main_dist": {}, "goal_switch_seq": [],
	"goal_sub_promotions": 0, "goal_release": {},
	"goal_reserve_last": 0, "goal_reserve_left_at_end": 0,
	"goal_urgency_last": 0.0, "goal_threshold_last": 0.6,
	"goal_preempt_events": 0, "goal_expire_events": 0,
	"goal_done_events": 0, "goal_created": 0,
	"goal_truncated_cycles": 0,
	# 2C-14 纯观测：次目标为空/非空周期数（2C-13 §4.2 只能从 L3 日志重算）
	"goal_sub_empty_cycles": 0, "goal_sub_present_cycles": 0,
	# 2C-15 纯观测：AI-only 达成率（修正口径：按期望值判、排除"开目标就已成立"）
	#   · 副官（玩家阵营）不计入 —— 分母只算 AI 阵营的目标
	#   · 只写计数，不进任何决策
	"goal_metric_total": 0, "goal_metric_done": 0,
	"goal_metric_strict_done": 0, "goal_ai_created": 0,
	"goal_sub_refilled": 0, "goal_cd_skips": 0,
	# 2C-13 §4.3：空过期间被挡下的花钱诉求（按动作分类）+ 1.5×G 退出次数
	"noop_blocked": {}, "noop_aggressive_exits": 0,
	"noop_aggressive_cycles": 0, "noop_gold_ge_1p5g_cycles": 0,
	# 2C-13 §5：计划层（每局最后一次主目标的计划步数，只落盘）
	"plan_steps_last": 0, "plan_action_last": "",
}
var _dept_cd: float = 0.0
var _scout_cd: float = 0.0
var _scout_seq: int = 0
## 兵力锁：key → {"n": 占用兵力, "t": 到期时刻, "k": 种类（wave/patrol/scout/temp_defense）}
var _troop_locks: Dictionary = {}
## 2C-10 §7.2：90% 人口压力响应测试（**只观测，不进任何决策**）
## 触发：占用率=(占用+在训)/上限 首次 >90%；响应：20 s 内任意一座农场工地开工；
## 一次触发结算后冷却 15 s 再评估下一次，避免同一次卡人口被反复计数。
var pop90: Dictionary = {"触发": 0, "成功": 0, "失败": 0, "失败明细": [],
	"峰值": 0.0, "农场开工": 0, "触发时刻": [],
	# 2C-12 §5：双口径拆分 —— 成功 = 已有工地 + 20 s 内新开工，两个数分开记。
	"已有工地": 0, "新开工成功": 0}
var _pop90_waiting: bool = false
var _pop90_trigger_t: float = -1.0
var _pop90_cooldown_until: float = -1.0
var _pop90_seen_sites: Dictionary = {}
var _pop90_last_site_t: float = -1.0
## 2C-10 §6：攒大波出击征用的兵力数（在 _exec_wave 里兑成 push_n）
var _pending_requisition: int = 0
## 2C-11：单件典型成本记忆（本周期无待办时取最近一次的值，早期农场 80）
var _saving_last_unit_cost: float = 80.0
## 2C-12 §2.1：**假待办账本**（目标 → 连续"在报但没执行"的仲裁周期数）。
## 执行一次即从字典里删掉（"曾经执行过"的目标不再算假待办）；
## 金币成本 0 的诉求不记账（不构成"单件成本"统计）。
var _saving_stall: Dictionary = {}
## 2C-12 §3：**承诺表**（承诺键 "动作|目标" → 承诺字典，7 字段见 战斗模型.promise_make）。
## 只对金币做承诺：可自由资源 = 金币 − 已承诺 − G(t)。
## 生命周期：有效 → 执行中 → 已执行（删除）；或 已过期 / 被抢占（释放）。
var _promise: Dictionary = {}
## 2C-13 §2：世界状态快照（每 tick 由 `_world_tick` 整份覆盖写，不在旧表上增量改）。
var world_state: Dictionary = {}
## 区域注册表（前缀 → 下一个序号；key=前缀+格坐标 → id）。跨 tick 保留，
## 所以同一块 64 m 区域永远拿到同一个 Dr###/Zy###/My### 编号。
var _ws_reg: Dictionary = {}
var _ws_writes: int = 0
## 资源点的区域位置缓存（每 `WS_RESOURCE_REFRESH` 秒刷一次）：扫全图树木
## 每帧做不起，但区域编号不需要每帧更新 —— 树被采光时编号也不会回收（规范要求）。
var _ws_res_cells: Array = []
var _ws_res_next_t: float = -1.0
const WS_RESOURCE_REFRESH: float = 10.0
## 2C-13 §4：目标层状态
##   goals_active = {id: 活动目标}（主 + 次，最多 2 条）
##   goal_main / goal_sub = 活动目标的引用（与 goals_active 同源，换指针不换内容）
var goals_active: Dictionary = {}
var goal_main: Dictionary = {}
var goal_sub: Dictionary = {}
var goal_noop: bool = false
var goal_reserved: Dictionary = {"金币": 0, "木材": 0}
var _goal_best: Dictionary = {}
var _noop_aggressive: bool = true
var _goal_thr: float = 0.6
## 2026-11-07：目标结束后按 "动作|对象" 冷却，减少"3 秒内反复进出同一目标"。
## 只影响**选目标**，不动 0.6 阈值，也不给空过开口子（冷却完还是空过就空过）。
const GOAL_COOLDOWN_SEC: float = 4.0
var _goal_cd: Dictionary = {}
## 2C-11 §3：最近 60 s 被拆建筑账本。只存时刻、不存对象引用，避免悬空。
## `_known_buildings` = 上一次思考时存活的建筑 instance_id 集合；
## 完工不会让 id 消失，所以「上次有、这次没了」只可能是被拆/被移除。
var _known_buildings: Dictionary = {}
var _lost_building_t: Array = []
const URG_LOST_WINDOW_SEC: float = 60.0
## 2C-11 §4：工地施工时间戳（instance_id -> 最后一次有农民施工的时刻）
var _site_last_work: Dictionary = {}
var _site_scan_next_t: float = -1.0
const SITE_SCAN_SEC_2C11: float = 5.0
var _l1_dmg: Array[float] = []
var _l1_gold: Array[float] = []
var _l1_wood: Array[float] = []
var _l1_verdicts: Array[String] = []
var _l1_sec: int = -1
var _prev_gold_dept: int = -1
var _prev_wood_dept: int = -1
## L3 决策日志落盘路径（`--dept-log=`；空 = 不落盘）
var dept_log_path: String = ""

## --- 子系统（_ready 里建，全部是纯逻辑，不认识场景树）---
var _sched = null      # 命令调度
var _director = null   # 战略导演
var _sanity = null     # 反愚蠢审计
var _combat = null     # 战斗数学

# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	AIV.setup_from_cmdline()
	# 2C-9 L3：决策日志落盘路径（**只落盘，不进决策**）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dept-log="):
			dept_log_path = a.substr(String("--dept-log=").length())
			if dept_log_path.begins_with("res://"):
				dept_log_path = ProjectSettings.globalize_path(dept_log_path)
	if dept_log_path.is_empty() and AIV.dept_on():
		dept_log_path = ProjectSettings.globalize_path("res://_qa/dept_log.jsonl")
	if not dept_log_path.is_empty():
		DirAccess.make_dir_recursive_absolute(dept_log_path.get_base_dir())
		if not FileAccess.file_exists(dept_log_path):
			var fc := FileAccess.open(dept_log_path, FileAccess.WRITE)
			if fc != null:
				fc.close()
	_faction = command_faction if command_faction != null else Game.enemy_faction
	if _faction == null:
		# 多队图没有"唯一的敌人"：退到"第一个不是玩家的阵营"
		for f in Game.factions:
			if f != null and not f.is_player:
				_faction = f
				break
	_make_subsystems()
	_apply_reserve_from_cfg()
	_connect_battle_signals()
	if _faction != null:
		_init_wave_clock()


## 订阅战斗事件（波次记录表的唯一数据源：§3.4 明确要求用 combat_hit + unit_died）。
## 同一个脑只连一次；副官与敌方 AI 各自连各自的实例，互不影响。
func _connect_battle_signals() -> void:
	if not Game.combat_hit.is_connected(_on_combat_hit):
		Game.combat_hit.connect(_on_combat_hit)
	if not Game.unit_died.is_connected(_on_unit_died):
		Game.unit_died.connect(_on_unit_died)


## 从 Cfg 取"保留资金"。
##
## @deprecated 2026-11-03 2C-2：保留金闸已从简单AI 的全部花销点删除，
## 这里只剩下"给副官垫一个默认值"的作用（副官随后用自己的 480/140 覆盖）。
## 简单AI 不再因为这两个数改变任何一个决策。
func _apply_reserve_from_cfg() -> void:
	var cfg: GameConfig = Cfg.game if Cfg != null else null
	if cfg == null:
		return
	reserve_gold = maxi(0, cfg.ai_reserve_gold)
	reserve_wood = maxi(0, cfg.ai_reserve_wood)

## 建子系统。分出来一个函数是因为副官/测试可能会在 ready 之外重建。
func _make_subsystems() -> void:
	if _sched == null:
		_sched = load("res://代码/ai/命令调度.gd").new()
	if _combat == null:
		_combat = load("res://代码/ai/战斗模型.gd").new()
	if _director == null:
		_director = load("res://代码/ai/战略导演.gd").new()
		var plans: Array = load("res://代码/配置/战略计划.gd").call("build")
		_director.setup(plans, Game.difficulty_index)
	if _sanity == null:
		_sanity = load("res://代码/ai/反愚蠢.gd").new()

func _init_wave_clock() -> void:
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_next_wave_at = diff.first_wave_delay
	_wave_index = 0
	_last_attack_t = 0.0   # C 模式时钟：从开局算"已经多久没打出去"

## 性能计时（探针读它）
static var dbg_usec: int = 0

func _process(delta: float) -> void:
	var _t0: int = Time.get_ticks_usec()
	_process_inner(delta)
	SimpleAI.dbg_usec += Time.get_ticks_usec() - _t0


func _process_inner(delta: float) -> void:
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	if _faction == null or not is_instance_valid(_faction):
		_faction = command_faction if command_faction != null else Game.enemy_faction
		if _faction == null:
			for f in Game.factions:
				if f != null and not f.is_player:
					_faction = f
					break
		if _faction == null:
			return
		_init_wave_clock()
	if _sched == null:
		_make_subsystems()

	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	_think -= delta
	_defend_cd = maxf(_defend_cd - delta, 0.0)
	_patrol_cd = maxf(_patrol_cd - delta, 0.0)
	_gather_cd = maxf(_gather_cd - delta, 0.0)
	_research_cd = maxf(_research_cd - delta, 0.0)
	_repair_cd = maxf(_repair_cd - delta, 0.0)
	_invest_cd = maxf(_invest_cd - delta, 0.0)
	_train_diag_cd = maxf(_train_diag_cd - delta, 0.0)
	_dept_cd = maxf(_dept_cd - delta, 0.0)
	_scout_cd = maxf(_scout_cd - delta, 0.0)
	if not _builder_uids.is_empty():
		_builder_tenure += delta
	if _think > 0.0:
		return
	var interval: float = maxf(diff.think_interval * think_scale, 0.1)
	_think = interval

	if not _announced:
		_announced = true
		_log("接管 %s（节奏 %.2fs）" % [_faction.display_name, interval])

	_think_once(diff)

## 一次完整的思考。抽成函数是为了让自检可以"手动推一帧"。
func _think_once(diff: DifficultyDef) -> void:
	var now: float = Game.elapsed
	# 2C-11 §3：建筑被拆账本（dept on/off 都跑，纯观测，不进决策）
	_track_building_losses(now)
	# 2C-11 §4：建造停滞恢复（每 5 s 扫一次，不是每帧）。
	# ★ 跑在 _dept_tick / 仲裁之前 = 优先级高于新工地，且不占仲裁额度、
	#   不受储备线约束（已投入成本的止损，不是新开销）。
	if now >= _site_scan_next_t:
		_site_scan_next_t = now + SITE_SCAN_SEC_2C11
		_site_recovery_tick(now)
	# 2C-10 §7.2：90% 压力响应纯观测（dept on/off 都跑，不进任何决策）
	_pop90_tick(now)
	_sched.begin(now)

	# --- ① 指标 + 姿态 ---
	var ctx: Dictionary = _build_ctx(diff, now)
	metrics = _director.build_metrics(ctx)
	posture = _director.update(ctx)
	posture["metrics"] = metrics

	# --- ② 卡死退避：先扫一遍，后面所有移动命令都会避开它们 ---
	_sched.refresh_stuck(_combat_units(true))

	# --- ②.5 反馈线：收入采样 + 在途波次结算 ---
	# 必须跑在 ⑥ 军事之前：状态机要读"这一波刚算出来的判定"，
	# 晚一 tick 就会拿旧状态去决定要不要攒大波。
	_track_income(now)
	# 2C-7 P2：投资占比采样（60 s 一次；只记录，不参与任何决策）
	_track_invest(now)
	_tick_wave(now)

	# --- ③ 经济 ---
	if AIV.dept_on():
		# 2C-9：三条线部门化。L2 诉求每 2 s 全量重建 → 主部门动作级仲裁 → 按分数顺序执行。
		# 旧顺序（农场急建 → 农场 → 军队 → 科技 → 军事 → upkeep）整段被替换，
		# 但**每一块的判定条件原样复用**（部门只负责"报诉求"，主部门只负责"排序 + 扣减"）。
		_dept_tick(diff, now)
		# 仲裁外的两件收尾（**都不在用户拍板的九个动作类型里**，见 §3.19）：
		#   · 哨塔升级箭塔 = 改造（花钱但不新建），2C-9 不纳入仲裁；
		#   · 科技研究 = 阵营级升级，动作类型表里没有"研究"。
		# 2C-13 §4.3：空过期间"没有目标就不花钱" —— 这两件都是新开销，必须一起停
		# （`_maybe_expand()` 是 `can_build_townhall()` 恒 false 的桩，一并门控）。
		if not (AIV.goal_on() and goal_noop):
			_maybe_upgrade_tower()
			_manage_research(diff)
			_maybe_expand()            # 扩展线"最小可用"桩，2C-9 未纳入仲裁
	else:
		_manage_peasants(diff)
		# 2C-8 P2：先结算"农场工地被拆"（在建→消失），再跑本 tick 的建农场决策
		_tick_build_diag()
		_assign_workers(diff)
		_manage_food(diff, true)    # 人口余量 <4 → 农场急建（建造农民优先级 #1）
		# 2C-6 P1：不急的农场也提到兵营**之前** —— 人口预判（占用>70% / 60 s 训练量×2）
		# 一满足就建，否则"兵营先扩、人口后补"会让新兵营一完工就卡人口。
		# 它仍然排在"急建"之后（上面那行先跑），所以不会抢紧急通道的钱。
		_manage_food(diff, false)

		# --- ④ 生产 / ⑤ 科技 ---
		_manage_army(diff)
		# 2C-8 P2：训练队列排不满的归因（60 s 一次，只记录）
		_sample_train_block(diff)
		_manage_research(diff)

		# --- ⑥ 军事 ---
		# ★ 2026-11-01 昼夜分流（玩家口径）：
		#   白天 → 出门打敌对玩家 + **清野怪营地**；夜里 → 守家、营火、农民采木。
		#   分流的唯一判据是 `Game.is_night()`（别在这里自己算小时）。
		_manage_retreat()
		_manage_defense(diff)
		if Game.is_night():
			_manage_night(diff)
		else:
			_manage_patrol(diff)
			_manage_creep_clear(diff)
			_manage_waves(diff)
		_manage_upkeep(diff)
		_maybe_expand()

	# --- ⑦ 反愚蠢审计（最后跑，救火命令优先）---
	# ★ 2026-11-07 玩家口径「空过期间不许花钱」：把 noop 传进审计，
	#   让 _check_supply/_check_production/_check_gold_float 这三项花钱动作停手。
	#   审计本身照跑：派工/接续/救火（不花钱的那部分）不受影响。
	ctx["goal_noop"] = goal_noop
	_sanity.update(ctx)

	# --- ⑧ 真正发出去 ---
	_sched.flush()

# ===========================================================================
# 上下文 / 查询
# ===========================================================================

## 每次思考给各子系统的一份"世界快照"。
## 为什么要做成 Dictionary 而不是让每个子系统自己扫场景：
## 一是性能（扫 7 遍全图单位），二是**口径一致** —— 导演判"军队规模"和
## 生产判"该造几个兵"必须数同一批人，否则两边永远对不上。
func _build_ctx(diff: DifficultyDef, now: float) -> Dictionary:
	var army: Array = _army_units()
	var enemy_army: Array = _enemy_army()
	var workers: Array = _workers()
	var idle: Array = []
	for w in workers:
		if w != null and is_instance_valid(w) and bool(w.call("is_idle_like")):
			idle.append(w)
	return {
		"faction": _faction,
		"now": now,
		"dt": maxf(diff.think_interval * think_scale, 0.1),
		"army": army,
		"enemy_army": enemy_army,
		# 出击门槛的**分母专用**敌军队列（A/B/C 开关只改这一条，不改选兵/战术）。
		# 单独一个键是为了让 B 模式换分母时，兵种克制画像仍看"最强的那家"——
		# 否则 A/B 两组的生产决策会一起变，数字没法归因到"门槛"上。
		"ratio_enemy_army": _ratio_foe_army(),
		# 距上次成功出击过了多久（C 模式的衰减时钟）
		"attack_locked_sec": maxf(0.0, now - _last_attack_t),
		"workers": workers,
		"idle_workers": idle,
		"threat_units": _threat_units(),
		"under_attack": _under_attack(),
		"defend_point": _defend_point(),
		"combat": _combat,
		"sched": _sched,
		"diff": diff,
		"posture": posture,
		"find_builder": Callable(self, "_pick_sanity_builder"),
		"build_spot": Callable(self, "_find_build_spot"),
		"build_yaw": Callable(self, "_build_yaw_at"),
		"queue_army": Callable(self, "_sanity_queue"),
		"research": Callable(self, "_sanity_research"),
	}

## 全部农民
func _workers() -> Array:
	var out: Array = []
	if _faction == null:
		return out
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null:
			continue
		if RtsWorld.is_worker_def(u.def):
			out.append(u)
	return out

## 全部战斗单位（不含农民；include_workers=true 时连农民一起给，用于卡死扫描）
func _army_units() -> Array:
	return _combat_units(false)

func _combat_units(include_workers: bool) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null:
			continue
		if u.def.kind != RtsConst.Kind.UNIT:
			continue
		if not include_workers and RtsWorld.is_worker_def(u.def):
			continue
		out.append(u)
	return out

## 对面的战斗单位（"能看见" = 全图，本项目没有战争迷雾）。
##
## ★ 两条口径（2026-11-01 修，之前 AI 整局不出门就是这两条一起造成的）：
##   ① **不含中立野怪**（见 `_war_foes()`）：8 片营地几十只豺狼人算进"敌军"，
##      兵比从 1.09 掉到 0.23，AI 永远觉得打不过；
##   ② **只比"最强的那个对手"**，不是把三家加起来：
##      四队图里每家只占全场 1/4，把其余三家求和，任何一家都不可能超过 1.0，
##      于是三家 AI 谁也不出门。RTS 里"能不能打出去"问的是"我 vs 最能打的那家"。
func _enemy_army() -> Array:
	return _combat_units_of(_strongest_foe())


## 某阵营的"能打的人"（不含农民、不含建筑）。
## 抽出来是因为 _enemy_army / _strongest_foe / _ratio_foe_army 三处**必须同一把尺**，
## 否则"最强的那家"和"门槛的分母"会指向不同的队伍，A/B 对照就不可信了。
func _combat_units_of(f: RtsFaction) -> Array:
	var out: Array = []
	if f == null:
		return out
	for u in f.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null:
			continue
		if u.def.kind != RtsConst.Kind.UNIT:
			continue
		if RtsWorld.is_worker_def(u.def):
			continue
		out.append(u)
	return out


# ===========================================================================
# 定义查询（2C-3 · 按 role / 能力取，**不再认兵种/建筑 id**）
#
# 用户改单位数值、攻防关系、增删兵种/建筑时，AI 一行代码都不用改：
#   · 兵种 → `role_weights`（frontline/ranged/caster/siege）× 每金战力
#   · 农民/主基地/农场/兵营/箭塔/哨塔/铁匠铺/伐木场/营火 → 按 def 的能力字段找
# 全部走 战斗模型 的 static 查询；查不到返回 &""，调用方跳过（不崩、不瞎造）。
# ===========================================================================

func _model_call(fn: String, args: Array = []):
	if _combat == null:
		return null
	# ★ 不走 callv：Godot 4 里对 **static** 函数用 callv 时参数会整体塞进第 1 个形参
	#   （实测 selection_weight 报 "Expected 4 arguments"、is_frontline 收到 Array）。
	#   静态函数用 call 逐个展开是验证过的写法。
	match args.size():
		0:
			return _combat.call(fn)
		1:
			return _combat.call(fn, args[0])
		2:
			return _combat.call(fn, args[0], args[1])
		3:
			return _combat.call(fn, args[0], args[1], args[2])
		4:
			return _combat.call(fn, args[0], args[1], args[2], args[3])
		5:
			return _combat.call(fn, args[0], args[1], args[2], args[3], args[4])
		6:
			return _combat.call(fn, args[0], args[1], args[2], args[3], args[4], args[5])
		_:
			return _combat.callv(fn, args)


func _role_weights(diff: DifficultyDef) -> Dictionary:
	# 2C-4：选兵配比只认 **承伤 / 输出**（function_weights）；旧 role_weights（frontline/
	# ranged/caster/siege）从选兵逻辑退役（字段保留只为旧 .tres 兼容）。
	# 空配置兜底 5:5（与难度档默认一致）。
	var fw: Dictionary = diff.function_weights if diff != null else {}
	if fw.is_empty():
		fw = {&"承伤": 5.0, &"输出": 5.0}
	var out: Dictionary = {}
	for k in fw.keys():
		out[StringName(k)] = float(fw[k])
	return out


func _candidate_ids(diff: DifficultyDef) -> Array:
	var a = _model_call("candidate_combat_ids", [_role_weights(diff)])
	return a if a is Array else []


func _worker_id() -> StringName:
	return StringName(_model_call("worker_unit_id"))


func _main_base_id() -> StringName:
	return StringName(_model_call("main_base_id"))


func _food_building_id() -> StringName:
	return StringName(_model_call("food_building_id"))


func _primary_producer_id(diff: DifficultyDef) -> StringName:
	return StringName(_model_call("primary_producer_id", [_role_weights(diff)]))


func _production_building_ids(diff: DifficultyDef) -> Array:
	var a = _model_call("production_building_ids", [_role_weights(diff)])
	return a if a is Array else []


func _tower_id() -> StringName:
	return StringName(_model_call("defense_tower_id", [true]))


func _watchtower_id() -> StringName:
	return StringName(_model_call("defense_tower_id", [false]))


func _campfire_id() -> StringName:
	return StringName(_model_call("tagged_building_id", [&"light"]))


func _research_building_id() -> StringName:
	return StringName(_model_call("research_building_id"))


func _wood_dropoff_building_id() -> StringName:
	return StringName(_model_call("wood_dropoff_id"))


## 经济/军事的"核心建筑"（采集配比与木材盈余线用）：人口 + 主产能 + 防御塔。
## 不写 id：用户换了农场/兵营的名字，这里自动跟着换。
func _core_building_ids(diff: DifficultyDef) -> Array:
	var out: Array = []
	for id in [_food_building_id(), _primary_producer_id(diff), _tower_id()]:
		if id != &"" and not out.has(id):
			out.append(id)
	return out


## **出击门槛的分母**（A/B/C 开关的唯一落点）。
##   A 最强 —— 现状；C 也用最强，区别只在阈值（见 战略导演._attack_ratio_needed）
##   B 次强 —— 次强的人数 ≥ 最强 × SECOND_GATE 才换分母，否则退回最强
##
## ★ 只改"跟谁比"，不改兵种/战术。B 换分母时 `_enemy_army()` 仍然给最强的那家，
##   所以选兵用的克制画像不受影响（A/B 的差异才能干净地归因到"出击门槛"）。
func _ratio_foe_army() -> Array:
	if _faction == null:
		return []
	var ranked: Array = _ranked_war_foes()
	if ranked.is_empty():
		return []
	if AIW.mode() == AIW.MODE_SECOND and ranked.size() >= 2:
		var top_n: int = int(ranked[0]["n"])
		var second_n: int = int(ranked[1]["n"])
		if top_n > 0 and float(second_n) >= float(top_n) * AIW.SECOND_GATE:
			return _combat_units_of(ranked[1]["faction"])
	return _combat_units_of(ranked[0]["faction"])


## 敌对阵营按"活着的战斗单位数"降序（口径与 _strongest_foe 完全一致）
func _ranked_war_foes() -> Array:
	var out: Array = []
	for f in _war_foes():
		if f == null:
			continue
		out.append({"faction": f, "n": _combat_units_of(f).size()})
	out.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))
	return out

## 压在我方建筑 DEFENSE_RADIUS 内的敌方战斗单位（跨全部敌对阵营）
func _threat_units() -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var foes: Array = Game.enemies_of(_faction)
	if foes.is_empty():
		return out
	var anchors: Array = []
	for b in _faction.buildings:
		if b != null and is_instance_valid(b) and b.is_alive():
			anchors.append(b.global_position)
	if anchors.is_empty():
		return out
	var r2: float = DEFENSE_RADIUS * DEFENSE_RADIUS
	for foe in foes:
		for e in foe.units:
			if e == null or not is_instance_valid(e) or not e.is_alive() or e.def == null:
				continue
			if e.def.kind != RtsConst.Kind.UNIT:
				continue
			var hit: bool = false
			for a in anchors:
				if e.global_position.distance_squared_to(a) <= r2:
					hit = true
					break
			if hit:
				out.append(e)
	return out

## 有没有自己的建筑在掉血
func _under_attack() -> bool:
	if _faction == null:
		return false
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		if b.hp < b.def.max_hp * 0.985:
			return true
	return false

## 回防落点：掉血最多的那座建筑；没有就基地中心
func _defend_point() -> Vector3:
	var best: Node3D = null
	var best_frac: float = 1.0
	if _faction != null:
		for b in _faction.buildings:
			if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
				continue
			var f: float = b.hp / maxf(b.def.max_hp, 1.0)
			if f < best_frac:
				best_frac = f
				best = b
	if best != null:
		return best.global_position
	return RtsWorld.base_center(_faction)

# ===========================================================================
# 经济
# ===========================================================================

## 补农民。目标 = 难度档 + 战略计划的 worker_bonus（经济流派多贪、防守流派少贪）
##          + **补经济压力**（2C-2：支出需求 > 收入时 +2，最多到 PEASANT_EMERGENCY_MAX）
func _manage_peasants(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	# 2C-4：总农民目标 = 软上限 + 4（PEASANT_TOTAL_CAP 直接覆盖旧上限口径；
	# diff.target_peasants 退役不再读）。worker_bonus 仍作为计划加成叠加。
	var target: int = PEASANT_TOTAL_CAP + int(posture.get("worker_bonus", 0))
	# 2C-2 运营反馈：想造兵但连最便宜的兵都买不起 → 收入是瓶颈，先补人再谈兵。
	# 只加人，不动任何"必须留 X 金"的闸（那是被明令禁止的）。
	var starving: bool = _demand_pressure(diff)
	if starving:
		target = mini(target + PEASANT_EMERGENCY_BONUS, PEASANT_TOTAL_CAP)
	var peasants: int = _faction.count_units(_worker_id())
	if peasants >= target:
		return
	# 先有枪杆子，再贪经济：农民数量超过军队太多时就不再补农，把钱留给兵营。
	# 不加这一闸的话，起始金币会被一口气灌进农民，兵营全程饿着（实测：目标 8/10 时
	# 60 秒只出 2 个兵，比"贪经济"亏得更狠）。
	# ★ 2C-2：有支出压力时**豁免**——反正兵也买不起，钱留在账上不会变成兵。
	if not starving and peasants >= _army_units().size() + VILLAGER_ARMY_GAP:
		return
	# 花销闸：钱够就花（2C-2 起不再有保留金；农民会把钱花光属于预期，
	# 运营反馈会在"支出需求 > 收入"时提高经济优先级，而不是靠留钱兜底）
	var wid: StringName = _worker_id()
	if wid == &"" or not _can_spend(wid):
		return
	var townhall: RtsBuilding = _first_building(_main_base_id())
	if townhall == null:
		return
	if townhall.train_count() >= MAX_QUEUE_PEASANT:
		return
	if townhall.queue_train(wid):
		_log("排农民（现有 %d / 目标 %d，军队 %d）"
				% [peasants, target, _army_units().size()])

## 给闲着的农民派采集活：**采金 / 采木按"先扣工位、再截 8"分**，工位单独走"闲了就砍树"。
##
## 2C-7 P0 改动（相对 2C-6）：
##   · 工位农民**不参与金木配比** —— 它没活时的默认工作是伐木（优先级最低）；
##   · 非工位农民按 `peasant_gold_want()` 分 8:3（满编 11 人 = 8 采金 + 3 采木）；
##   · 人数不足时按同一比例缩（例如 6 个非工位 → 4 金 2 木），不是"全塞去采金"。
##
## 2C-8 P0：工位可能不止 1 个 —— 用 uid 集合一次性排除；配比改成
##   `peasant_gold_want_dynamic(农民总数, 工位数)` = min(8, N − 工位)，
##   满编 12 + 2 工位 → 8 金 / 2 木。`off/legacy` 对照局仍走 2C-7 的比例口径。
func _assign_workers(_diff: DifficultyDef) -> void:
	var workers: Array = _workers()
	if workers.is_empty():
		return
	var builders: Array = _builder_units()
	var slot_uids: Dictionary = {}
	for b in builders:
		slot_uids[b.get_instance_id()] = true
	var on_gold: int = 0
	var on_wood: int = 0
	var idle: Array = []
	for w in workers:
		# 工位不占金木名额（它的默认活是砍树，但仍然不算进"采木 N 人"的配比）
		if slot_uids.has(w.get_instance_id()):
			if bool(w.call("is_idle_like")):
				idle.append(w)
			continue
		var k: int = int(w.call("gather_kind"))
		if k == RtsConst.Harvest.GOLD:
			on_gold += 1
		elif k == RtsConst.Harvest.WOOD:
			on_wood += 1
		elif bool(w.call("is_idle_like")):
			idle.append(w)
	if idle.is_empty():
		return

	var total: int = workers.size() - builders.size()
	var want_gold: int = 0
	if AIV.builder_mode() == "on":
		want_gold = int(_model_call("peasant_gold_want_dynamic",
				[workers.size(), _builder_count_target(), PEASANT_GOLD_SOFT_CAP]))
	else:
		want_gold = int(_model_call("peasant_gold_want",
				[total, PEASANT_GOLD_SOFT_CAP, PEASANT_WOOD_TARGET]))
	var base: Vector3 = RtsWorld.base_center(_faction)
	var radius: float = Cfg.game.map_size * 0.75
	# 木材的"收货点"每 tick 只算一次（伐木场优先，其次大本营）
	var wood_drop: Vector3 = _wood_dropoff()

	for w in idle:
		var is_slot: bool = slot_uids.has(w.get_instance_id())
		var kind: int = RtsConst.Harvest.GOLD
		if is_slot:
			# 2C-7 P0：工位没活就砍树（优先级最低）；不再被配比拉去采金
			kind = RtsConst.Harvest.WOOD
		elif on_gold >= want_gold:
			kind = RtsConst.Harvest.WOOD
		# 夜里：闲着的人一律去砍木头（玩家口径"夜晚……农民采集木头"）。
		# 夜里金矿不是瓶颈，木头才是（塔、营火、修理全吃木）。
		if Game.is_night() and on_wood < total:
			kind = RtsConst.Harvest.WOOD
		var node: Node3D = null
		if kind == RtsConst.Harvest.WOOD:
			node = _nearest_wood(w, wood_drop)
		else:
			node = Game.find_nearest_harvestable(w.global_position, kind, base, radius)
		if node == null and kind == RtsConst.Harvest.WOOD:
			kind = RtsConst.Harvest.GOLD
			node = Game.find_nearest_harvestable(w.global_position, kind, base, radius)
		if node == null:
			continue
		_sched.gather([w], node, "economy")
		if is_slot:
			continue    # 工位不计入金木配比
		if kind == RtsConst.Harvest.GOLD:
			on_gold += 1
		else:
			on_wood += 1

	# 已经在采的人也要能转向（2C-2）。只处理 idle 的话，金木配比一旦定下就整局不动，
	# "支出需求 > 收入时优先采金"根本落不了地。
	_rebalance_gatherers(total)


## 采集配比再平衡：把已经在采的农民挪 1 个人到目标资源上（有冷却，不每 tick 重排）。
##
## 触发条件只有"实际配比与目标配比差 ≥1 人"：
##   · 目标 share 上涨（有等待中的支出需求 + 木材盈余）→ 伐木的转去采金；
##   · 目标 share 回落（木材低于软盈余线）→ 采金的转去伐木。
## 每次只挪 1 个人、间隔 GATHER_REBALANCE_CD 秒 —— 换采集点要走过去，
## 一次挪一批等于让一半农民在路上白跑。
##
## ★ 2C-7 P0：**工位永远不在候选池里**（既不被拉去采金，也不被从木头挪走），
##   否则"固定 1 个建造工"在配比再平衡面前只成立一个 CD 周期。
## ★ 2C-8 P0：工位是数组，用 uid 集合排除；目标配比同步换成"先扣工位"口径。
func _rebalance_gatherers(total: int) -> void:
	if _gather_cd > 0.0 or _faction == null or total <= 0:
		return
	var slot_uids: Dictionary = {}
	for b in _builder_units():
		slot_uids[b.get_instance_id()] = true
	var on_gold: int = 0
	var gold_workers: Array = []
	var wood_workers: Array = []
	for w in _workers():
		if w == null or not is_instance_valid(w):
			continue
		if slot_uids.has(w.get_instance_id()):
			continue
		var k: int = int(w.call("gather_kind"))
		var gathering: bool = int(w.order) == RtsConst.Order.GATHER
		if k == RtsConst.Harvest.GOLD:
			on_gold += 1
			if gathering:
				gold_workers.append(w)
		elif k == RtsConst.Harvest.WOOD and gathering:
			wood_workers.append(w)
	var want_gold: int = 0
	if AIV.builder_mode() == "on":
		var bc: int = _builder_count_target()
		want_gold = int(_model_call("peasant_gold_want_dynamic",
				[total + bc, bc, PEASANT_GOLD_SOFT_CAP]))
	else:
		want_gold = int(_model_call("peasant_gold_want",
				[total, PEASANT_GOLD_SOFT_CAP, PEASANT_WOOD_TARGET]))
	var kind: int = -1
	var pool: Array = []
	if on_gold < want_gold and not wood_workers.is_empty():
		kind = RtsConst.Harvest.GOLD
		pool = wood_workers
	elif on_gold > want_gold and not gold_workers.is_empty():
		kind = RtsConst.Harvest.WOOD
		pool = gold_workers
	if kind < 0:
		return
	var w: RtsUnit = pool[0]
	var base: Vector3 = RtsWorld.base_center(_faction)
	var radius: float = Cfg.game.map_size * 0.75
	var node: Node3D = null
	if kind == RtsConst.Harvest.WOOD:
		node = _nearest_wood(w, _wood_dropoff())
	else:
		node = Game.find_nearest_harvestable(w.global_position, kind, base, radius)
	if node == null:
		return
	_sched.gather([w], node, "economy")
	_gather_cd = GATHER_REBALANCE_CD


## **砍哪棵树**：优先"离伐木场/基地最近"的，其次才是"离农民最近"的。
##
## 玩家口径（2026-11-01）："要优先采集伐木场最近或基地最近的木头"。
## 判据 = 树到收货点的距离 × 1.0 + 树到农民的距离 × 0.35：
##   · 权重 1.0 —— 每一趟往返都要走的路，是真正的时间成本；
##   · 权重 0.35 —— 农民多走两步过去无所谓，多背 10m 回家才是浪费。
## 这就是"先把家门口的树砍光"的自然行为，而不是随机撒到林子里。
func _nearest_wood(w: RtsUnit, drop: Vector3) -> Node3D:
	if w == null or not is_instance_valid(w):
		return null
	var best: Node3D = null
	var best_s: float = INF
	for h in Game.all_harvestables():
		if h == null or not is_instance_valid(h):
			continue
		if not h.is_alive():
			continue
		var hd: UnitDef = h.def
		if hd == null or hd.harvest_kind != RtsConst.Harvest.WOOD:
			continue
		var s: float = h.global_position.distance_to(drop) \
				+ h.global_position.distance_to(w.global_position) * 0.35
		if s < best_s:
			best_s = s
			best = h
	return best


## 木材的收货点：最近的、收木材的己方交汇点。
## 伐木场是"专收木材"的，给 8m 的等效折扣 —— 否则大本营常常更近，
## 伐木场就白造了（它存在的意义就是把送货路程缩短）。
func _wood_dropoff() -> Vector3:
	var home: Vector3 = RtsWorld.base_center(_faction)
	var best: Vector3 = home
	var best_d: float = INF
	if _faction == null:
		return best
	var special_id: StringName = _wood_dropoff_building_id()
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		var rb := b as RtsBuilding
		if rb != null and not rb.is_constructed:
			continue
		if not b.def.accepts_harvest(RtsConst.Harvest.WOOD):
			continue
		var d: float = b.global_position.distance_to(home)
		if special_id != &"" and b.def.id == special_id:
			d -= 8.0
		if d < best_d:
			best_d = d
			best = b.global_position
	return best

## 金木人力分配比例：**从兵种与建筑成本推导**，再叠加 2C-2 的动态修正。
##
## 静态部分（别拍脑袋常数）：按难度档 composition + farm/barracks/tower 的成本占比。
## 动态部分（每 tick 重算、纯软判据）：
##   · 有等待中的支出需求（军队没满编且买不起最便宜的兵）+ 木材有盈余 → 全员采金；
##   · 木材低于软盈余线 → 绝不把最后几个伐木工抽走（否则下一座房子永远差木头）。
func _gold_share(diff: DifficultyDef) -> float:
	var gold: float = 0.0
	var wood: float = 0.0
	# 兵种部分：**按 role 权重的平均成本**（不认具体 id）。
	# 同一 role 下有几个兵就取平均 —— 选兵是按每金战力竞争的，成本口径也应该用该 role 的代表值。
	var rw: Dictionary = _role_weights(diff)
	for role in rw.keys():
		var w: float = float(rw[role])
		if w <= 0.0:
			continue
		var one: Dictionary = {}
		one[role] = 1.0
		var ids = _model_call("candidate_combat_ids", [one])
		if not (ids is Array) or ids.is_empty():
			continue
		var g: float = 0.0
		var wd: float = 0.0
		var n: int = 0
		for id in ids:
			var d: UnitDef = Cfg.unit(StringName(id))
			if d == null:
				continue
			g += float(d.gold_cost)
			wd += float(d.wood_cost)
			n += 1
		if n <= 0:
			continue
		gold += (g / float(n)) * w
		wood += (wd / float(n)) * w
	# 建筑部分：人口 / 主产能 / 防御塔（按能力找，不写 id）
	for bid in _core_building_ids(diff):
		var bd: UnitDef = Cfg.unit(bid)
		if bd == null:
			continue
		gold += float(bd.gold_cost) * 2.0
		wood += float(bd.wood_cost) * 2.0
	var total: float = gold + wood
	var base: float = clampf(gold / total, 0.25, 0.85) if total > 0.0 else 0.5
	if _faction == null:
		return base
	if _faction.wood >= _wood_soft_floor() and _demand_pressure(diff):
		return 1.0
	return base


## **支出需求 > 收入**的判据（2C-2 运营反馈的总开关）。
##
## 定义：军队还没满编（还有该造没造的兵），且账上的钱连**最便宜的兵**都买不起。
## 这就是"想做的事钱不够"的机器形态 —— 此时不硬等，而是：
##   ① 农民目标 +2（补经济）；② 采集配比转向金（如果木材有盈余）。
## 注意：这是一个**读数**，不是一个闸。它只用来调优先级，不阻止任何花销。
func _demand_pressure(diff: DifficultyDef) -> bool:
	if _faction == null or diff == null:
		return false
	if _army_units().size() >= diff.max_army:
		return false
	return _faction.gold < _cheapest_army_gold(diff)


## 木材的"软盈余线" = 最贵的那座建筑的木材成本 × 2（全部来自 Cfg，不写死 id）。
## 高于它：抽人去采金不会让下一座建筑缺木；低于它：先保住伐木工。
func _wood_soft_floor() -> int:
	var worst: int = 0
	for id in Cfg.units().keys():
		var d: UnitDef = Cfg.unit(StringName(id))
		if d != null and d.kind == RtsConst.Kind.BUILDING:
			worst = maxi(worst, int(d.wood_cost))
	return worst * 2

## 花钱闸：**钱够就花**（2026-11-03 2C-2 重构）。
##
## 历史（必须保留，防止后续 agent 又把它加回来）：
##   旧实现要求"花完还剩 reserve_gold(150) + reserve_wood(40)"。于是最便宜的兵
##   130 金的**真实门槛是 280 金**，而 AI·1队 4 分钟里兵营口只见到 142~278 金 ——
##   兵营队列空转 411 s / 480 s（86%），兵力从 t=30 s 起卡在 8 不动。
##   证词：`footman:保留金闸(gold 242 < 135+150)`（2C-1 诊断，`_qa/prod1.jsonl`）。
##
## 现在：建筑 / 农民 / 哨塔 / 兵营 / 农场 / 营火 / 军队**统一**只看"付不付得起"
## （金 + 木 + 人口，走 Game.can_afford 这唯一实现）。钱不够怎么办不在闸里解决，
## 交给运营反馈：按当前钱能造几个造几个（降规模）+ 提高经济优先级（补经济）。
## **禁止**在这里恢复任何"必须保留 X 金/木"的分档判断。
func _can_spend(id: StringName) -> bool:
	if _faction == null:
		return false
	if Cfg.unit(id) == null:
		return false
	return Game.can_afford(_faction, id)


## 军队专用花钱闸 —— 与 `_can_spend` **完全同一实现**。
##
## 保留这个名字只为兼容旧调用点（`_pick_army_unit` / 反愚蠢审计），语义已经合并：
## "军队 / 建筑 / 农民 / 哨塔统一走'钱够就花'，不再有保留金闸"。
## 2C-1 曾把军队单独摘出来（不套金币保留额），2C-2 把其余花销也一起摘掉了。
func _can_spend_army(id: StringName) -> bool:
	return _can_spend(id)


## 修理建筑（2C-5 P1-4 接命令口；2C-6 P3 改判据；2C-7 P0 改派人；2C-8 P0 改多工位）
## 建造/修理的优先级 **第 3 位**（沿用）：农场(急) > 补兵营 > **修理** > 哨塔 > 农场(不急)。
##
## 判据（2C-6，本轮不动）：**固定掉血值** `max_hp − hp ≥ AI判定模式.repair_hp_deficit()`（默认 200）。
##   **大本营不加修理优先**（用户口径）：排在所有其它建筑之后 —— 不是"不修"，是"最后修"。
##
## ★ 2C-7 P0：**派人改成固定工位**（`_builder_unit()`）。
## ★ 2C-8 P0（用户拍板）：工位是数组。修理不再"只修一栋"：
##     · 收集**所有**该修且没人修的建筑，按优先级排序（非大本营优先、掉血多优先）；
##     · 每个空闲工位领一栋（**每栋一个工位，不抢同一栋**），一次思考可以同时开修多栋；
##     · 正在修理的工位不打断（修理是长动作，换来换去等于一直走路）；
##     · 无建造任务时**全部工位**都可去修；都不需要修时由 `_assign_workers` 派去采木。
##   归因三类保留：`blocked_no_builder` / `blocked_builder_busy` / `blocked_wood`。
func _manage_repair() -> void:
	if _faction == null:
		return
	var mode: String = AIV.builder_mode()
	# 工位诊断（每 tick 都刷，不受修理节流影响）：报告要看"这一局工位到底在干什么"
	if mode != "legacy":
		_tick_labor_stats()
		repair_stats["builder_role"] = _builder_roles_desc()
		repair_stats["builder_swaps"] = _builder_swaps
		repair_stats["builder_slots"] = _builder_uids.size()
		repair_stats["builder_count"] = _builder_count_target()
	if _repair_cd > 0.0:
		return
	var pack: Dictionary = _repair_candidates()
	var cands: Array = pack["cands"]
	if cands.is_empty():
		if bool(pack["wood_blocked"]):
			repair_stats["blocked_wood"] = int(repair_stats.get("blocked_wood", 0)) + 1
		return
	# candidates 保持 2C-7 口径（"有该修的 tick 数"），另加 candidate_buildings（栋数），
	# 否则"一轮修 3 栋"会让 issued/candidates > 1，看起来像把阈值调松了。
	repair_stats["candidates"] = int(repair_stats.get("candidates", 0)) + 1
	repair_stats["candidate_buildings"] = \
			int(repair_stats.get("candidate_buildings", 0)) + cands.size()
	if mode == "on":
		_issue_repairs_multi(cands)
	else:
		_issue_repairs_single(cands)


## 收集"该修且当前没人修"的建筑，附带优先级排序所需的字段。
## 返回 {cands: [{b, deficit, is_base}], wood_blocked: bool}
func _repair_candidates() -> Dictionary:
	var cands: Array = []
	var wood_blocked: bool = false
	if _faction == null:
		return {"cands": cands, "wood_blocked": wood_blocked}
	var deficit_min: float = AIV.repair_hp_deficit()
	var base_id: StringName = _main_base_id()
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not rb.can_repair():
			continue
		# 2C-6：固定掉血判据（200 HP），不再按比例
		if not bool(_model_call("repair_needed_deficit",
				[float(rb.hp), float(rb.def.max_hp), deficit_min])):
			continue
		var busy: bool = false
		for w in _workers():
			if w != null and is_instance_valid(w) and w.get("_repair_target") == rb:
				busy = true
				break
		if busy:
			continue
		# 木材连"修满"都不够 → 派过去也只会站着（repair_step 里木材不足就停工）
		if int(rb.call("repair_wood_for_full")) > _faction.wood:
			wood_blocked = true
			continue
		var deficit: float = float(_model_call("repair_deficit",
				[float(rb.hp), float(rb.def.max_hp)]))
		cands.append({
			"b": rb, "deficit": deficit,
			"is_base": base_id != &"" and rb.def.id == base_id,
		})
	# 优先非大本营；同类按掉血绝对值降序（sort_custom 稳定：并列保持遍历顺序）
	cands.sort_custom(func(a, b):
		if bool(a["is_base"]) != bool(b["is_base"]):
			return not bool(a["is_base"])
		return float(a["deficit"]) > float(b["deficit"]))
	return {"cands": cands, "wood_blocked": wood_blocked}


## 2C-8：多工位并行修理 —— 每个空闲工位领一栋，最多领到 cands 用完。
func _issue_repairs_multi(cands: Array) -> void:
	var slots: Array = _builder_units()
	if slots.is_empty():
		repair_stats["blocked_no_builder"] = int(repair_stats.get("blocked_no_builder", 0)) + 1
		return
	var free: Array = []
	for s in slots:
		var o: int = int(s.order)
		if o == RtsConst.Order.BUILD or o == RtsConst.Order.REPAIR:
			continue
		free.append(s)
	if free.is_empty():
		# 工位都在建造/修理 —— 这是"工位被占满"，不是"没工位"
		repair_stats["blocked_builder_busy"] = \
				int(repair_stats.get("blocked_builder_busy", 0)) + 1
		return
	var issued_n: int = 0
	for c in cands:
		if free.is_empty():
			break
		var rb: RtsBuilding = c["b"]
		# 前面的楼可能刚花掉木材：派之前再判一次（只读）
		if int(rb.call("repair_wood_for_full")) > _faction.wood:
			repair_stats["blocked_wood"] = int(repair_stats.get("blocked_wood", 0)) + 1
			continue
		var s: RtsUnit = free.pop_front()
		if _do_repair(s, rb, float(c["deficit"])):
			issued_n += 1
	if issued_n > 0:
		_repair_cd = REPAIR_REISSUE


## 2C-7 单工位 / 2C-6 任意农民：只派一个人、只修一栋（长局"改前"对照走这条）。
func _issue_repairs_single(cands: Array) -> void:
	var builder: RtsUnit = null
	if AIV.builder_mode() == "off":
		var slot: RtsUnit = _builder_unit()
		if slot == null:
			repair_stats["blocked_no_builder"] = int(repair_stats.get("blocked_no_builder", 0)) + 1
			return
		if int(slot.order) == RtsConst.Order.BUILD:
			repair_stats["blocked_builder_busy"] = \
					int(repair_stats.get("blocked_builder_busy", 0)) + 1
			return
		builder = slot
	else:
		builder = _pick_builder_legacy()
		if builder == null:
			repair_stats["blocked_no_builder"] = int(repair_stats.get("blocked_no_builder", 0)) + 1
			return
	var c: Dictionary = cands[0]
	if _do_repair(builder, c["b"], float(c["deficit"])):
		_repair_cd = REPAIR_REISSUE


## 真正下达一条修理命令 + 记账（issued / buildings / 日志）。
func _do_repair(builder: RtsUnit, rb: RtsBuilding, deficit: float) -> bool:
	if builder == null or rb == null or rb.def == null:
		return false
	if not bool(_sched.repair(builder, rb, "repair")):
		return false
	var bn: String = String(rb.def.display_name)
	var frac: float = float(rb.hp) / maxf(float(rb.def.max_hp), 1.0)
	repair_stats["issued"] = int(repair_stats.get("issued", 0)) + 1
	var bd: Dictionary = repair_stats.get("buildings", {})
	bd[bn] = int(bd.get(bn, 0)) + 1
	repair_stats["buildings"] = bd
	_log("修 %s（掉血 %.0f / 血量 %.0f%%，修满约 %d 木）"
			% [bn, deficit, frac * 100.0, int(rb.call("repair_wood_for_full"))])
	return true


## 补农场（2C-4 建造农民优先级；2C-7 P1 改触发条件）：
##   urgent=true  —— 人口余量 <4 **或 人口占用 >90%** → 农场**急建**，排经济段最前；
##   urgent=false —— 不急的农场（C 占用>70% / A 60 s 训练量×2 / 连一个兵都排不下）。
## **农场上限：不设**（用户 2C-7 拍板）—— 只要 C/A 或 >90% 成立就建，没有"最多 N 座"。
## 修理建筑：2C-5 起已接命令口（见 `_manage_repair`），优先级第 3 位。
func _manage_food(diff: DifficultyDef, urgent: bool) -> void:
	if _faction == null:
		return
	var headroom: int = _faction.food_cap() - _faction.food_used()
	if urgent:
		# 2C-7 P1（用户拍板）：人口占用 >90% 也走**急建**通道 —— 不等 headroom<4。
		# 语义是"人口顶到嗓子眼时，农场排在兵营/军队之前"；>70% 的 C 条件仍留在不急通道。
		if headroom >= 4 and not _pop_critical():
			return
	else:
		if headroom < 4:
			return    # 急的已经由 urgent 通道处理
		# 2C-6 P1：老判据（连下一个兵都排不下）与人口预判（占用>70% / 60 s 训练量×2）任一成立就建
		if not (_need_farm(diff) or _need_more_farm(diff)):
			return
	var fid: StringName = _food_building_id()
	if fid == &"":
		return
	var farm_def: UnitDef = Cfg.unit(fid)
	if farm_def == null:
		return
	# 已经在造农场了就别再造（**但不阻止反愚蠢审计派人去收尾停滞工地**）
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != fid:
			continue
		if b is RtsBuilding and not b.is_constructed:
			return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		# 2C-8 P2：归因 —— 想建农场但工位都在建造/修理（或没有工位）
		_note_farm_fail("no_builder")
		return
	var spot: Vector3 = _find_build_spot(farm_def.footprint)
	if spot == Vector3.INF:
		_note_farm_fail("no_spot")
		return
	if not _can_spend(fid):
		# 2C-8 P2：木材不够是农场的头号断供原因；金不够单独记（报告里区分）
		if _faction.wood < int(farm_def.wood_cost):
			_note_farm_fail("no_wood")
		else:
			_note_farm_fail("no_gold")
		return
	var site: Node3D = _sched.build(builder, farm_def, spot, _build_yaw_at(spot), "economy")
	if site != null:
		_note_build(fid)
		# 2C-8 P2：登记工地快照，"建到一半被拆"在这一局结束时结算成 lost
		_farm_sites[site.get_instance_id()] = true
		_log("造农场（人口 %d/%d）" % [_faction.food_used(), _faction.food_cap()])


## 2C-8 P2：农场失败归因计数（只读诊断，不参与任何决策）
func _note_farm_fail(reason: String) -> void:
	farm_fail_stats[reason] = int(farm_fail_stats.get(reason, 0)) + 1


## 2C-8 P2：农场工地快照结算 —— 完工出列；被拆/消失计 `lost`。
## 每 tick 一次（在 `_manage_food` 之前），只扫自己下过单的几座农场。
func _tick_build_diag() -> void:
	if _farm_sites.is_empty():
		return
	for k in _farm_sites.keys():
		var b: RtsBuilding = instance_from_id(int(k)) as RtsBuilding
		if b == null or not is_instance_valid(b) or not b.is_alive():
			farm_fail_stats["lost"] = int(farm_fail_stats.get("lost", 0)) + 1
			_farm_sites.erase(k)
		elif bool(b.is_constructed):
			_farm_sites.erase(k)

## 2C-7 P1：人口占用 >90%（"顶到嗓子眼"）。cap=0 视为不紧急（没有人口建筑时
## `_need_more_farm` 已经会强制建，别在这里重复触发）。
func _pop_critical() -> bool:
	if _faction == null:
		return false
	var cap: int = _faction.food_cap()
	if cap <= 0:
		return false
	return float(_faction.food_used()) / float(cap) > POP_CRITICAL_RATIO


## 人口是否已经不够下一个兵种了（用"权重最高的兵种"的 food_cost 作判据，别拍常数）
func _need_farm(diff: DifficultyDef) -> bool:
	var max_food: int = 1
	for id in _candidate_ids(diff):
		var d: UnitDef = Cfg.unit(StringName(id))
		if d != null:
			max_food = maxi(max_food, d.food_cost)
	var wid: StringName = _worker_id()
	var peasant: UnitDef = Cfg.unit(wid) if wid != &"" else null
	if peasant != null:
		max_food = maxi(max_food, peasant.food_cost)
	return not _faction.has_food(max_food)


## **人口预判（2C-6 P1）**：两个条件任一满足就提前建农场。
##   C  占用率 > 70%（used_pop / max_pop）—— "还剩三成空位"时就开始铺，不等贴顶；
##   A  余量 < 未来 60 s 预计训练的兵数 × 2 —— 一座农场 8 人口，留 2 倍缓冲才不会"兵排到一半卡人口"。
##
## 为什么不用"余量 < 4"：那个阈值只在**已经快满**时响应，而农场要 28 s 才盖好、期间兵营还在出人，
## 于是"卡人口 → 停工 28 s → 继续"的锯齿在 2C-5 长局里一直存在（人口占用率 100% 从 480 s 起）。
## 预计训练兵数 = 当前兵营数 × 60 s ÷ 平均训练时间（用**候选兵种**的平均值，不写常数）。
func _need_more_farm(diff: DifficultyDef) -> bool:
	if _faction == null:
		return false
	var cap: int = _faction.food_cap()
	var used: int = _faction.food_used()
	if cap <= 0:
		return true
	# C：占用率 > 70%
	if bool(_model_call("pop_occupied_over", [used, cap])):
		return true
	# A：余量 < 未来 60 s 预计训练兵数 × 2
	var headroom: int = cap - used
	return bool(_model_call("farm_headroom_low", [headroom, _predicted_trainees_60s(diff)]))


## 未来 60 s 大概能训练出几个兵（= 兵营数 × 60 ÷ 平均训练时间）。
## 兵营数只数**已完工**的出兵建筑（在建的那座还没产能，不该算进人口预判）。
func _predicted_trainees_60s(diff: DifficultyDef) -> float:
	var producers: int = int(_base_producer_counts()["producers"])
	if producers <= 0:
		return 0.0
	var sum: float = 0.0
	var n: int = 0
	for id in _candidate_ids(diff):
		var d: UnitDef = Cfg.unit(StringName(id))
		if d != null and d.train_time > 0.0:
			sum += d.train_time
			n += 1
	if n == 0:
		return 0.0
	var avg: float = sum / float(n)
	return float(_model_call("predicted_trainees_60s", [producers, avg]))

## 找基地附近的合法空位。
## **必须先吸附再判定**：判定用吸附后的点，落地也用这个点（order_build 内部还会再吸一次，
## 幂等），否则会出现"AI 找到空位、工地却被判不能建"的断链。
##
## v2 加了一条"社交距离"：旧版只问"这几格能不能走"，不问"离别的房子多远"，
## 于是兵营/农场会紧贴着大本营盖，屋檐、台阶、地基板互相穿插，
## 远看像一堆盒子挤在一起。现在要求与任何己方建筑的外接矩形至少留 BUILD_GAP 米。
func _find_build_spot(footprint: Vector2i) -> Vector3:
	var center: Vector3 = RtsWorld.base_center(_faction)
	var r: float = BUILD_SEARCH_MIN
	while r <= BUILD_SEARCH_MAX:
		for i in range(BUILD_SEARCH_ANGLES):
			var ang: float = TAU * float(i) / float(BUILD_SEARCH_ANGLES)
			var raw := Vector3(center.x + cos(ang) * r, 0.0, center.z + sin(ang) * r)
			var p: Vector3 = 建筑网格.snap_point(raw, footprint)
			if 建筑网格.can_place(p, footprint) and _has_room(p, footprint):
				return p
		r += BUILD_SEARCH_STEP
	return Vector3.INF


## 这个落点离已有建筑够不够远（外接矩形间隙 >= BUILD_GAP）。
## 用"分离轴上的间隙"而不是圆心距离：房子是方的，圆心距离会把贴着角的判定算错。
func _has_room(spot: Vector3, footprint: Vector2i) -> bool:
	if _faction == null:
		return true
	var a0 := Vector2(spot.x - float(footprint.x) * 0.5, spot.z - float(footprint.y) * 0.5)
	var a1 := Vector2(spot.x + float(footprint.x) * 0.5, spot.z + float(footprint.y) * 0.5)
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		var bf: Vector2i = b.def.footprint
		if bf.x <= 0 or bf.y <= 0:
			continue
		var bp: Vector3 = b.global_position
		var b0 := Vector2(bp.x - float(bf.x) * 0.5, bp.z - float(bf.y) * 0.5)
		var b1 := Vector2(bp.x + float(bf.x) * 0.5, bp.z + float(bf.y) * 0.5)
		var dx: float = maxf(b0.x - a1.x, a0.x - b1.x)
		var dz: float = maxf(b0.y - a1.y, a0.y - b1.y)
		if maxf(dx, dz) < BUILD_GAP:
			return false
	return true

## 建筑朝向：**和开局摆的三座完全一致**（正门朝镜头 / 世界 +Z），再吸到 90 度档。
##
## 旧实现让每座房子"转向基地中心"：副官在基地北侧盖的兵营会整座背对玩家，
## 和开局那三座朝向对不上 —— 一眼就看得出是"两拨人摆的"。
## 而且玩家镜头永远从南往北看，朝内的房子在画面上全是后背。
func _build_yaw_at(_spot: Vector3) -> float:
	return 建筑网格.snap_yaw(建筑网格.default_yaw())

## **2C-7 P0 / 2C-8 P0：建造/修理工位**（持久数组；返回**所有**存活工位）。
##
## 为什么要一个**持久工位**，而不是每 tick 从"空闲农民"里挑：
##   2C-6 长局 `repair_stats` 是 76 candidates / **0 issued** / 76 blocked_no_builder ——
##   每次判定"该修"的时候，12 个农民全在采集/建造。判据（掉血 ≥200）没问题，
##   是**没有人被允许放下手上的活**去修。
##
## 2C-8：工位数 = max(2, ceil(N/6))，随农民总数实时重算（`_builder_count_target()`）。
##   · 农民阵亡/消失 → 当 tick 补位（优先正在建造的 → 伐木工 → 任意农民）；
##   · 农民变多 → 追加；变少 → 优先退回"没在建造/修理"的（正在干活的先留着收尾）。
##   · 工位是 `_builder_uids`（instance_id 数组），不做"每 tick 重新挑人"。
##
## 模式：on（默认）动态数组 / off 单工位（2C-7）/ legacy 无工位（2C-6，只为对照）。
func _builder_units() -> Array:
	var out: Array = []
	if _faction == null or AIV.builder_legacy():
		_builder_uids.clear()
		return out
	var target: int = _builder_count_target() if AIV.builder_mode() == "on" else 1
	if target <= 0:
		_builder_uids.clear()
		return out
	# ① 校验存活（阵亡/消失 → 计数，下面补位）
	var seen: Dictionary = {}
	for uid in _builder_uids:
		var cur: RtsUnit = instance_from_id(uid) as RtsUnit
		if cur == null or not is_instance_valid(cur) or not cur.is_alive() \
				or cur.def == null or not RtsWorld.is_worker_def(cur.def) \
				or cur.faction != _faction:
			_builder_swaps += 1
			_builder_tenure = 0.0
			continue
		out.append(cur)
		seen[cur.get_instance_id()] = true
	# ② 超出目标：优先退回"没在建造/修理"的（从后往前，保留老工位 = 稳定）
	if out.size() > target:
		var i: int = out.size() - 1
		while out.size() > target and i >= 0:
			var o: int = int(out[i].order)
			if o != RtsConst.Order.BUILD and o != RtsConst.Order.REPAIR:
				out.remove_at(i)
				_builder_tenure = 0.0
			i -= 1
	# ③ 不足目标：按"正在建造 → 采木 → 任意"补位（同一 tick 内不重复挑同一个人）
	if out.size() < target:
		var building_now: Array = []
		var wood_pick: Array = []
		var any_pick: Array = []
		for u in _faction.units:
			if u == null or not is_instance_valid(u):
				continue
			if not u.is_alive() or u.def == null or not RtsWorld.is_worker_def(u.def):
				continue
			var uid2: int = u.get_instance_id()
			if seen.has(uid2):
				continue
			if int(u.order) == RtsConst.Order.BUILD:
				building_now.append(u)
			elif int(u.call("gather_kind")) == RtsConst.Harvest.WOOD:
				wood_pick.append(u)
			else:
				any_pick.append(u)
		for pool in [building_now, wood_pick, any_pick]:
			for u in pool:
				if out.size() >= target:
					break
				var uid3: int = u.get_instance_id()
				if seen.has(uid3):
					continue
				out.append(u)
				seen[uid3] = true
				_builder_tenure = 0.0
	# ④ 回写（数组是唯一真相源）
	_builder_uids.clear()
	for u in out:
		_builder_uids.append(u.get_instance_id())
	return out


## 2C-8：工位**目标数**（不是实际人数）：max(2, ceil(存活农民数 / 6))。
## off 模式固定 1（= 2C-7 的单工位）；legacy 模式 0（没有持久工位）。
func _builder_count_target() -> int:
	if _faction == null or AIV.builder_legacy():
		return 0
	if AIV.builder_mode() == "off":
		return 1
	return int(_model_call("builder_count_for", [_workers().size()]))


## 兼容入口（2C-7 的调用点/回归用它）：返回**第一个**工位；没有就 null。
func _builder_unit() -> RtsUnit:
	var slots: Array = _builder_units()
	return slots[0] if not slots.is_empty() else null


## 2C-6 旧口径（任意空闲农民，其次任意农民；有人正在建造就整轮不派）。
## 只在 `--builder-slot=legacy` 对照局里走这条路 —— 保留它是为了"同构建改前/改后"。
func _pick_builder_legacy() -> RtsUnit:
	if _faction == null:
		return null
	var best: RtsUnit = null
	for u in _faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive() or u.def == null or not RtsWorld.is_worker_def(u.def):
			continue
		if u.order == RtsConst.Order.BUILD:
			return null
		if bool(u.call("is_idle_like")):
			return u
		if best == null:
			best = u
	return best


## 挑一个能去盖房子的农民。**同时建造数 = 工位数 − 1**（至少留 1 个工位给修理）。
##   · on（2C-8）：工位数组里挑一个"没在建造/修理"的；已在建造的人数到上限就返回 null；
##   · off（2C-7）：单工位，正在建造就返回 null；
##   · legacy（2C-6）：任意空闲农民。
## 为什么用"目标工位数"算上限而不是"当前实际指派数"：开局只有 1 个农民时也要能盖第一座兵营，
## 否则前 1 分钟永远没有产能。人补齐后目标 ≥2，上限自然回到 N−1。
func _pick_builder() -> RtsUnit:
	if AIV.builder_legacy():
		return _pick_builder_legacy()
	if AIV.builder_mode() == "off":
		var s: RtsUnit = _builder_unit()
		if s == null:
			return null
		if int(s.order) == RtsConst.Order.BUILD:
			return null
		return s
	var slots: Array = _builder_units()
	if slots.is_empty():
		return null
	var limit: int = int(_model_call("builder_build_limit", [_builder_count_target()]))
	var n_build: int = 0
	for s in slots:
		if int(s.order) == RtsConst.Order.BUILD:
			n_build += 1
	if n_build >= limit:
		return null
	for s in slots:
		var o: int = int(s.order)
		if o == RtsConst.Order.BUILD or o == RtsConst.Order.REPAIR:
			continue
		return s
	return null


## **反愚蠢审计专用选人**（2C-7）：与 `_pick_builder()` 的语义差别只有一个 ——
## **允许工位正在建造**。
##
## 为什么必须分开：审计的语义是"救火"（工地停滞 / 农民闲置），它最后跑、命令要覆盖前面所有命令；
## 若沿用 `_pick_builder()`（工位在建造就返回 null），就会出现
## "停滞工地正好是工位自己盖的 → 审计拿不到人 → 立案失败"（副官自检 E 组实测 3 条连续红）。
## 2C-8：优先给"空闲/采木"的工位，其次才是正在建造的（避免救火把修理工从墙上拽走）。
func _pick_sanity_builder() -> RtsUnit:
	if AIV.builder_legacy():
		return _pick_builder_legacy()
	var slots: Array = _builder_units()
	if slots.is_empty():
		return null
	# 2C-8：救火也不能破"同时建造 ≤ 工位数−1"。已经到上限时**复用正在建造的工位**
	# （换工地不增加并发数），而不是再拉一个空闲工位去盖第二栋。
	var limit: int = int(_model_call("builder_build_limit", [_builder_count_target()]))
	var n_build: int = 0
	for s in slots:
		if int(s.order) == RtsConst.Order.BUILD:
			n_build += 1
	if n_build >= limit:
		for s in slots:
			if int(s.order) == RtsConst.Order.BUILD:
				return s
	for s in slots:
		var o: int = int(s.order)
		if o != RtsConst.Order.BUILD and o != RtsConst.Order.REPAIR:
			return s
	for s in slots:
		if int(s.order) == RtsConst.Order.BUILD:
			return s
	return slots[0]


## 工位角色（报告用）：第一个工位在建造/修理 → BUILDER；否则它当前在采什么就是什么。
func _builder_role_name() -> String:
	var b: RtsUnit = _builder_unit()
	if b == null:
		return "无工位"
	if int(b.order) == RtsConst.Order.BUILD or int(b.order) == RtsConst.Order.REPAIR:
		return "BUILDER"
	if int(b.call("gather_kind")) == RtsConst.Harvest.WOOD:
		return "GATHER_WOOD"
	if int(b.call("gather_kind")) == RtsConst.Harvest.GOLD:
		return "GATHER_GOLD"
	return "待命"


## 2C-8：全部工位的一句话状态（报告/bench 的"工位角色"字段）
func _builder_roles_desc() -> String:
	var slots: Array = _builder_units()
	if slots.is_empty():
		return "无工位"
	var n_build: int = 0
	var n_repair: int = 0
	var n_wood: int = 0
	var n_other: int = 0
	for s in slots:
		var o: int = int(s.order)
		if o == RtsConst.Order.BUILD:
			n_build += 1
		elif o == RtsConst.Order.REPAIR:
			n_repair += 1
		elif int(s.call("gather_kind")) == RtsConst.Harvest.WOOD:
			n_wood += 1
		else:
			n_other += 1
	return "%d建造/%d修理/%d采木/%d其它" % [n_build, n_repair, n_wood, n_other]


## 2C-8 P2：用工统计（只读）—— 同时建造数 / 同时修理数 / 超限 tick。
## 每 tick 调一次（`_manage_repair` 顶部），成本 = 遍历 2~3 个工位。
func _tick_labor_stats() -> void:
	var slots: Array = _builder_units()
	var target: int = _builder_count_target()
	labor_stats["samples"] = int(labor_stats["samples"]) + 1
	labor_stats["builder_slots"] = slots.size()
	labor_stats["builder_target"] = target
	var n_build: int = 0
	var repair_targets: Dictionary = {}
	for s in slots:
		var o: int = int(s.order)
		if o == RtsConst.Order.BUILD:
			n_build += 1
		elif o == RtsConst.Order.REPAIR:
			var t = s.get("_repair_target")
			if t != null and is_instance_valid(t):
				repair_targets[t.get_instance_id()] = true
	labor_stats["max_concurrent_build"] = \
			maxi(int(labor_stats["max_concurrent_build"]), n_build)
	# 下限取 1：off 模式的目标工位数是 1，`builder_build_limit(1)=0` 会把"单工位在建造"
	# 误记成超限（2C-8 第一版踩过：改前局自报 369 次超限，而引擎侧采样是 0）。
	var build_limit: int = maxi(int(_model_call("builder_build_limit", [target])), 1)
	if n_build > build_limit:
		labor_stats["build_over_limit_ticks"] = \
				int(labor_stats["build_over_limit_ticks"]) + 1
	var n_rep: int = repair_targets.size()
	labor_stats["max_concurrent_repairs"] = \
			maxi(int(labor_stats["max_concurrent_repairs"]), n_rep)
	if n_rep >= 2:
		# 两个工位同时修**不同**建筑（repair_targets 按 instance_id 去重）
		labor_stats["concurrent_repairs"] = int(labor_stats["concurrent_repairs"]) + 1

# ===========================================================================
# 生产 / 科技
# ===========================================================================

## 生产：**军队 > 建筑（防御受威胁）> 经济扩张 > 科技**（2C-2 显式化的优先级）。
##
## 顺序不是随意的：没有保留金闸之后，"谁先动钱"就等于"谁优先"。
## 旧顺序是建筑在前（兵营/箭塔/圣地/车坊），于是每次攒到一笔钱都先被建筑吃掉，
## 军队永远排不上（2C-2 阶段 A 实测：AI·2/3 金币中位 49/65，兵力却卡在 5/6）。
##
## 现在的记账顺序：
##   ① 没有产能 → 先盖兵营（否则"军队优先"无从谈起）；
##   ② 军队优先 → 按当前的钱"能造几个造几个"（每座兵营 1 个；钱只够 1 个就造 1 个）；
##   ③ 队列排满（钱已经记在训练上）/ 已满编 → 富余的钱才轮到产能与防御；
##   ④ 圣地/车坊（科技建筑）只在满编后考虑 —— 科技是最后一项。
## 基地被压时箭塔例外（防御是刚需）。
func _manage_army(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	var army: int = _army_units().size()
	var producers: Array = _army_producers(diff)
	# 2C-4 §4.1：低于防守下限 → 补战斗单位（只从训练队列补；不挪用农民——
	# 本作没有"农民转兵"，天然满足）。
	# 2C-5 P0-2：目标 = `10 + 4×基地 + 2×出兵建筑`。
	# 2C-7 P1（用户拍板）：目标再与"人口上限÷2−1"取小；**420 s 后不解除**，
	#   改为取人口允许的最大值 —— 想多出兵就得先建农场（见 _manage_food 的 >90% 急建）。
	var target_army: int = _army_target()
	var capped: bool = target_army >= 0
	strat_stats["army_target"] = target_army
	if not strat_stats.has("army_target_first"):
		strat_stats["army_target_first"] = target_army
	# ① 产能为 0：先解决"有没有兵营"，本 tick 不再谈别的
	if producers.is_empty():
		_maybe_build_barracks(diff)
		return
	# ② 军队优先：能造几个造几个（不因为"造不满 N 个"就整个 tick 跳过）
	if not capped or army < target_army:
		for b in producers:
			var rb: RtsBuilding = b as RtsBuilding
			if rb == null or rb.train_count() >= MAX_QUEUE_ARMY:
				continue
			if _queue_one(rb, diff) != &"":
				army += 1
			if capped and army >= target_army:
				break
	# ③ 队列都排满了 = 这一 tick 军队该占的钱已经占住，富余的钱才能给建筑。
	#    队列没排满却没排上，只有一个原因：钱不够 —— 此时建筑一律延后到下一 tick，
	#    并让 _demand_pressure() 去加经济，而不是把最后那点钱花在房子上。
	#    ★ 解除目标后（capped=false）"饱和"只剩"队列排满"一种 —— 这正是
	#      "只受钱/人口/队列限制"的机器形态。
	# ★ 2C-8：目标不再受人口约束（会远超人口），所以"军队 >= 目标"可能永远不成立。
	#   必须补一条"人口已经排不下下一个兵"也算饱和 —— 否则农场/兵营/科技会被永久饿死
	#   （2C-7 靠 target=人口÷2−1 天然满足，删掉人口约束后这个副作用必须显式补回）。
	var saturated: bool = (capped and army >= target_army) \
			or _all_queues_full(producers) or _need_farm(diff)
	if saturated:
		_maybe_build_barracks(diff)
		_maybe_build_tower()
	# 基地被压：塔是刚需，不受"军队优先"限制（一座塔只花一次钱）
	if float(metrics.get("base_threat", 0.0)) > 0.0:
		_maybe_build_tower()
	# ④ 其余产能建筑：最后。满编/队列排满之前一律不盖（钱给兵）。
	#    不写 sanctum/workshop：由"谁能训练职能权重 > 0 的兵"自动找出来。
	if saturated:
		_maybe_build_extra_producers(diff)


## 能训练"任一 role 权重 > 0 的兵"的**已完工**建筑（兵营 / 圣地 / 车坊）。
## 用 can_train + 角色权重判，不写死 id：用户加兵种/建筑不用回来改这里。
func _army_producers(diff: DifficultyDef) -> Array:
	var out: Array = []
	if _faction == null or diff == null:
		return out
	var ids: Array = _candidate_ids(diff)
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not rb.is_constructed:
			continue
		for id in ids:
			if rb.can_train(StringName(id)):
				out.append(rb)
				break
	return out


## 每座产能建筑的队列都排满了吗（空数组 = false）
func _all_queues_full(producers: Array) -> bool:
	if producers.is_empty():
		return false
	for b in producers:
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and rb.train_count() < MAX_QUEUE_ARMY:
			return false
	return true


## 让一座建筑排一个兵。返回真的排上的 id（空串 = 排不上）
func _queue_one(b: RtsBuilding, diff: DifficultyDef) -> StringName:
	if b == null or not is_instance_valid(b) or not b.is_constructed:
		return &""
	if b.train_count() >= MAX_QUEUE_ARMY:
		return &""
	var picked: StringName = _pick_army_unit(b, diff)
	if picked == &"":
		return &""
	if b.queue_train(picked):
		# 2C-7 P2：军队投资记账（只统计**真的排上队**的那笔钱，失败不记）
		var ud: UnitDef = Cfg.unit(picked)
		if ud != null:
			invest_stats["army_gold"] = int(invest_stats["army_gold"]) + int(ud.gold_cost)
			invest_stats["army_wood"] = int(invest_stats["army_wood"]) + int(ud.wood_cost)
		return picked
	return &""


## 2C-8 P2：训练队列排不满的归因（**每 60 s 采一次，只记录不改判定**）。
## 判据顺序：产能 → 队列 → 人口 → 金币 → 木材。
## 为什么人口排在钱前面：卡人口时再多的钱也出不了兵，"no_gold"会把真正的瓶颈盖掉。
func _sample_train_block(diff: DifficultyDef) -> void:
	if _train_diag_cd > 0.0:
		return
	_train_diag_cd = TRAIN_DIAG_SEC
	var reason: String = _classify_train_block(diff)
	train_stats["samples"] = int(train_stats["samples"]) + 1
	train_stats[reason] = int(train_stats.get(reason, 0)) + 1


func _classify_train_block(diff: DifficultyDef) -> String:
	var producers: Array = _army_producers(diff)
	if producers.is_empty():
		return "no_producer"
	var has_space: bool = false
	for b in producers:
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and rb.train_count() < MAX_QUEUE_ARMY:
			has_space = true
			break
	if not has_space:
		return "queue_full"
	# 候选池与 _pick_army_unit 同一把尺（职能权重 > 0），否则会拿"根本不会造的兵"当分母
	var rw: Dictionary = _role_weights(diff)
	var best_gold: int = 1 << 30
	var best_wood: int = 1 << 30
	var best_food: int = 1 << 30
	for id in _candidate_ids(diff):
		var d: UnitDef = Cfg.unit(StringName(id))
		if d == null:
			continue
		if float(_model_call("def_function_weight", [d, rw])) <= 0.0:
			continue
		best_gold = mini(best_gold, int(d.gold_cost))
		best_wood = mini(best_wood, int(d.wood_cost))
		best_food = mini(best_food, int(d.food_cost))
	if best_gold > (1 << 29):
		return "ok"    # 没有可选兵种：不是"被卡住"，是没事可做
	if best_food < (1 << 29) and not _faction.has_food(best_food):
		return "no_pop"
	if _faction.gold < best_gold:
		return "no_gold"
	if _faction.wood < best_wood:
		return "no_wood"
	return "ok"

## **按"role 权重 × 每金战力 × 克制"选兵**（2C-3：不再认具体兵种 id）。
##
## 为什么必须换成这个：本项目有 4×4 的伤害克制表，旧 AI 完全没读过它。
## 对面全是重甲步兵时，AI 还在按固定比例抽弓箭手（穿刺 × 重甲 = 0.85，打了等于刮痧）。
## 新公式 = 每金战力（含克制、护甲、升级、人口、时间折算） × **role 权重** × 同兵种过载惩罚。
##
## 三层各管一件事：
##   · 每金战力  —— 别造废物（含"钱花了但打不动"这种）；
##   · role 权重 —— 策划的配比意图（难度档 role_weights，frontline/ranged/caster/siege）；
##   · 过载惩罚  —— 同一种兵堆太多会被单一兵种克制，也浪费产能。
##
## ★ 候选池来自 `Cfg.units` 的 role 扫描（战斗模型.candidate_combat_ids），
##   不是难度档里的 id 列表 —— 用户新增一个 role=ranged 的兵，下一 tick 就能被选到；
##   删掉 archer，配比自动重排，不崩。
func _pick_army_unit(b: RtsBuilding, diff: DifficultyDef) -> StringName:
	var prof: Dictionary = _combat.profile(_enemy_army())
	var atk_mult: float = RtsCombat.attack_mult(_faction)
	var arm_mult: float = RtsCombat.armor_mult(_faction)
	var rw: Dictionary = _role_weights(diff)
	var pool: Array = []
	var weights: Array = []
	for id in _candidate_ids(diff):
		var d: UnitDef = Cfg.unit(StringName(id))
		if d == null:
			continue
		# 2C-4 选兵（§4.5）：单位权重 = 该单位拥有的职能里权重最高的那个（max）；
		# 候选池 = 职能含 承伤/输出 的战斗单位；辅助/机动/控制本轮不参与。
		var role_w: float = float(_model_call("def_function_weight", [d, rw]))
		if role_w <= 0.0:
			continue
		if bool(_model_call("def_roles_is_fallback", [d])) and not _fallback_warned.has(d.id):
			_fallback_warned[d.id] = true
			_log("⚠ 兵种 %s 未填职能（卡 roles 空），按能力回退参与选兵" % String(d.id))
		if not b.can_train(StringName(id)):
			continue
		if not _can_spend_army(StringName(id)):
			continue
		var have: int = _faction.count_units(StringName(id))
		var w = _model_call("selection_weight", [d, role_w, have, prof, atk_mult, arm_mult])
		pool.append(StringName(id))
		weights.append(maxf(float(w), 0.0001))
	if pool.is_empty():
		return &""
	return pool[_weighted_pick(weights)]

## 选兵职能回退警告去重表（每个 id 只警一次，报告口径）
var _fallback_warned: Dictionary = {}


## 当前可派的战斗单位（C4 定义）：idle 且不在巡逻/回防/建造任务中
##（is_idle_like = order NONE；正在训练的、正在别的任务中的不算）
func _available_units() -> Array:
	var out: Array = []
	for u in _army_units():
		if u != null and is_instance_valid(u) and bool(u.call("is_idle_like")):
			out.append(u)
	return out


## 数"主基地 / 出兵建筑"各几座（已完工；在建工地不算）。
## 一个函数两处用（防守下限 + 军队目标），避免两边对"什么算基地"口径漂开。
func _base_producer_counts() -> Dictionary:
	var out := {"bases": 0, "producers": 0}
	if _faction == null:
		return out
	var base_id: StringName = _main_base_id()
	var prod_ids: Array = _producer_ids()
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and not rb.is_constructed:
			continue
		if base_id != &"" and b.def.id == base_id:
			out["bases"] = int(out["bases"]) + 1
		if prod_ids.has(b.def.id):
			out["producers"] = int(out["producers"]) + 1
	return out


## 防守下限 = 5 + 2×基地数 + 1×出兵建筑数（任务书 §4.1；其他建筑不计入）
func _defense_floor() -> int:
	if _faction == null:
		return 0
	var c: Dictionary = _base_producer_counts()
	return int(_model_call("defense_floor_of", [int(c["bases"]), int(c["producers"])]))


## 军队规模目标（2C-5 P0-2 起；2C-7 P1 加人口约束；2C-8 P1 换成三段时间）：
##   new（默认，用户 2C-8 拍板）：
##     t < 480        ：12 + 3×基地 + 1×出兵建筑
##     480 ≤ t < 600  ：13 + 4×基地 + 2×出兵建筑
##     t ≥ 600        ：(14+n) + (5+n)×基地 + (3+n)×出兵建筑，n = floor((t−600)/120)
##     **不与人口挂钩**（人口卡训练机制兜住），最后 max(结果, 防守下限)。
##   old（2C-7 对照，--army-target-formula=old）：
##     min(10 + 4B + 2P, 人口上限÷2 − 1)；420 s 后取人口允许值；不传人口 → -1。
## 返回值 -1 仍表示"没有上限"（只可能出现在 old + --army-pop-cap=off 的 2C-6 对照）。
## ★ 目标不低于防守下限：钱可以再赚，家空了就没了 —— 所以最后再 max 一次。
func _army_target() -> int:
	if _faction == null:
		army_target_now = -1
		return -1
	var c: Dictionary = _base_producer_counts()
	var t: int = 0
	if AIV.army_target_formula() == "new":
		t = int(_model_call("army_target_2c8",
				[int(c["bases"]), int(c["producers"]), Game.elapsed]))
		t = maxi(t, _defense_floor())
	else:
		# 2C-7 P1：人口上限也参与约束（每个战斗单位 2 人口、留 1 点余量）。
		# `--army-pop-cap=off` 时传 0 = 不约束 → 回 2C-6 口径（420 s 后 -1 解除）。
		var pop_cap: int = _faction.food_cap() if AIV.army_pop_cap() else 0
		t = int(_model_call("army_target_of",
				[int(c["bases"]), int(c["producers"]), Game.elapsed, _defense_floor(), pop_cap]))
	army_target_now = t
	return t


## 出兵建筑 id 集（能训练战斗单位的建筑，与 _primary_producer_id 同源）
func _producer_ids() -> Array:
	var a = _model_call("production_building_ids", [_role_weights(Cfg.difficulty(Game.difficulty_index))])
	return a if a is Array else []


## 按权重随机取一个下标（加权抽签：保证多样性，又不会造出明显更差的兵）
func _weighted_pick(weights: Array) -> int:
	var total: float = 0.0
	for w in weights:
		total += float(w)
	if total <= 0.0:
		return 0
	var r: float = randf() * total
	for i in range(weights.size()):
		r -= float(weights[i])
		if r <= 0.0:
			return i
	return weights.size() - 1

## 产能规划：主产能建筑（当前 = 兵营，按"能训练多少 role 权重的兵"自动选）不足就再盖一座。
##
## 2C-6 P2：目标座数**不再跟难度档 max_army 走**（那会把 16 人的目标卡在 2 座兵营 × 1 队列上）：
##   · 固定 ≥ 2 座（一队列等兵 = 产能浪费，第二座从第 1 分钟就该在）；
##   · 军队 > 16 时加到 3 座（16 人以上单/双队列排满，第三座才开始有边际收益）。
##   7 分钟后 target_army 解除**不影响**这条：兵营数量独立判断，看的是"现在有多少兵"。
const BARRACKS_MIN: int = 2
const BARRACKS_ARMY_STEP: int = 16
const BARRACKS_AT_STEP: int = 3


func _barracks_want() -> int:
	var army_n: int = _army_units().size()
	return int(_model_call("barracks_want_of",
			[army_n, BARRACKS_MIN, BARRACKS_ARMY_STEP, BARRACKS_AT_STEP, MAX_BARRACKS]))


func _maybe_build_barracks(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	var pid: StringName = _primary_producer_id(diff)
	if pid == &"":
		return
	var want: int = _barracks_want()
	var have: int = 0
	var building_now: bool = false
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != pid:
			continue
		if not b.is_alive():
			continue
		have += 1
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and not rb.is_constructed:
			building_now = true
	if have >= want or building_now:
		return
	var bd: UnitDef = Cfg.unit(pid)
	if bd == null or not Game.can_afford(_faction, pid):
		return
	# 必须留足"新兵营一完工就能立刻出一个兵"的钱。
	# 不然产能是建出来了，但没钱排队 → 空转的兵营反而拖慢军队成型（实测踩过）。
	# ★ 这不是"保留金闸"：这笔钱在下一个 tick 就会花在兵上，不会被囤起来。
	var reserve: int = _cheapest_army_gold(diff) * MAX_QUEUE_ARMY
	if _faction.gold < bd.gold_cost + reserve:
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(bd.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, bd, spot, _build_yaw_at(spot), "economy") != null:
		_note_build(pid)
		_log("扩建%s（已有 %d / 目标 %d，当前军队 %d）" % [
			bd.display_name, have, want, _army_units().size()])

## 其余产能建筑（圣地 / 车坊）：**满编之后**才考虑，每种一座。
## 不写 id：由"谁能训练 role 权重 > 0 的兵"自动枚举。
func _maybe_build_extra_producers(diff: DifficultyDef) -> void:
	var primary: StringName = _primary_producer_id(diff)
	for id in _production_building_ids(diff):
		if StringName(id) == primary:
			continue
		_maybe_build_one(StringName(id), 1, "tech")

## 箭塔：基地需要"不动的那种兵"。目标 = 每 2 座主产能建筑 1 座塔，最多 2 座。
func _maybe_build_tower() -> void:
	if _faction == null:
		return
	var tid: StringName = _tower_id()
	if tid == &"":
		return
	var pid: StringName = _primary_producer_id(Cfg.difficulty(Game.difficulty_index))
	var want: int = clampi(_faction.count_buildings(pid) / 2, 1, 2) if pid != &"" else 1
	if _faction.count_buildings(tid) >= want:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id == tid and b is RtsBuilding and not b.is_constructed:
			return
	var td: UnitDef = Cfg.unit(tid)
	if td == null or not _can_spend(tid):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(td.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, td, spot, _build_yaw_at(spot), "economy") != null:
		_log("补箭塔（目标 %d 座）" % want)

## 通用"再盖一座 X"：目标座数 + 正在施工就不重复盖。
## 与 _maybe_build_barracks / _maybe_build_tower 同一套口径（留足出兵的钱、只挑闲置农民）。
func _maybe_build_one(id: StringName, want: int, tag: String) -> void:
	if _faction == null or want <= 0:
		return
	if _faction.count_buildings(id) >= want:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null or b.def.id != id:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and not rb.is_constructed:
			return
	var d: UnitDef = Cfg.unit(id)
	if d == null or not _can_spend(id):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, d, spot, _build_yaw_at(spot), tag) != null:
		_log("扩建%s（目标 %d 座）" % [d.display_name, want])


## 当前 role 权重下最便宜兵种的金币价（用来预留"部队口粮"，全来自 Cfg 数据）
func _cheapest_army_gold(diff: DifficultyDef) -> int:
	var cheapest: int = 0
	for id in _candidate_ids(diff):
		var d: UnitDef = Cfg.unit(StringName(id))
		if d == null or d.gold_cost <= 0:
			continue
		if cheapest == 0 or d.gold_cost < cheapest:
			cheapest = d.gold_cost
	if cheapest == 0:
		# 兜底：配置里一个可训练的战斗单位都没有时，取任意非农民 UNIT 的最低价
		for id in Cfg.units().keys():
			var d: UnitDef = Cfg.unit(StringName(id))
			if d == null or d.kind != RtsConst.Kind.UNIT or d.gold_cost <= 0:
				continue
			if d.anim_set == RtsConst.AnimSet.WORKER:
				continue
			if cheapest == 0 or d.gold_cost < cheapest:
				cheapest = d.gold_cost
	return cheapest

## 科技：**运营线**（2C-4 §4.3，与战斗并行；删 T13/T14 状态机停靠）。
##   · 前 5 分钟不科研（只战斗 + 运营）；
##   · 每 10 s 检查一次（不每 tick）；
##   · 有研究建筑 + 付得起 + 无正在研究 → 研究（入口在 _sanity_research）；
##   · 遇 base_threat ≥ 1 跳过本次，10 s 后再看（报告记"因威胁跳过 N 次"）；
##   · "最晚 7 分钟开始"（RESEARCH_LATEST_SEC）是**决策自维护的约束**，
##     时间线表（科研时间线）本轮留空 TODO，到点条件不满足就顺延——不是强制兜底。
func _manage_research(_diff: DifficultyDef) -> void:
	if Game.elapsed < RESEARCH_NOT_BEFORE_SEC:
		return
	if _research_cd > 0.0:
		return
	_research_cd = RESEARCH_CHECK_EVERY
	_research_track_completion()
	if float(metrics.get("base_threat", 0.0)) >= 1.0:
		strat_stats["research_skipped_threat"] = int(strat_stats.get("research_skipped_threat", 0)) + 1
		return
	_sanity_research()


## 研究完成跟踪：上一检查点在研究、本检查点没人研究 → 完成 +1（运营线日志）
func _research_track_completion() -> void:
	if _faction == null:
		return
	var running: bool = false
	for b in _faction.buildings:
		var rb := b as RtsBuilding
		if rb != null and rb.is_alive() and rb.is_researching():
			running = true
			break
	if _research_was_running and not running:
		strat_stats["research_done"] = int(strat_stats.get("research_done", 0)) + 1
	_research_was_running = running

## 真的去点一项研究（2C-4 默认规则，时间线表留空 TODO）：
##   · **职能相关科技优先**：attack_up↔输出 / armor_up↔承伤，按当前职能权重
##     最高的先（权重相同按成本金+木从低到高）；
##   · 经济类科技（高效搬运/修缮工艺）排其后，同样按成本。
func _sanity_research() -> bool:
	if _faction == null:
		return false
	var fw: Dictionary = _role_weights(Cfg.difficulty(Game.difficulty_index))
	var cands: Array = []
	for b in _faction.buildings:
		var rb := b as RtsBuilding
		if rb == null or not rb.is_alive() or not rb.is_constructed or rb.is_researching():
			continue
		if rb.def.researches.is_empty():
			continue
		for rid in rb.def.researches:
			if RtsCombat.research_maxed(_faction, rid):
				continue
			if String(rb.research_block_reason(rid)) != "":
				continue
			var rd: ResearchDef = Cfg.research(StringName(rid))
			var cost: float = float(rd.gold_cost + rd.wood_cost) if rd != null else 999999.0
			var related: bool = false
			var w: float = 0.0
			if rid == &"attack_up":
				related = true
				w = float(fw.get(&"输出", 0.0))
			elif rid == &"armor_up":
				related = true
				w = float(fw.get(&"承伤", 0.0))
			cands.append({"rid": rid, "b": rb, "related": related, "w": w, "cost": cost})
	if cands.is_empty():
		return false
	cands.sort_custom(func(a, b):
		if bool(a["related"]) != bool(b["related"]):
			return bool(a["related"])
		if bool(a["related"]) and not is_equal_approx(float(a["w"]), float(b["w"])):
			return float(a["w"]) > float(b["w"])
		return float(a["cost"]) < float(b["cost"]))
	for c in cands:
		var rb: RtsBuilding = c["b"]
		if rb.research(c["rid"]):
			strat_stats["research_started"] = int(strat_stats.get("research_started", 0)) + 1
			_research_was_running = true
			_log("开始研究 %s（运营线；因威胁跳过 %d 次）"
				% [String(c["rid"]), int(strat_stats.get("research_skipped_threat", 0))])
			return true
	return false

## 给反愚蠢审计用的"排一个兵"入口
func _sanity_queue(b) -> StringName:
	var rb := b as RtsBuilding
	if rb == null or not is_instance_valid(rb) or not rb.is_constructed:
		return &""
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	return _queue_one(rb, diff)

# ===========================================================================
# 军事：撤退 / 回防 / 巡逻 / 推进
# ===========================================================================

## 残血撤退：血量低于 RETREAT_HP 的战斗单位先回家，别在前线当经验包。
## 回满血后它会因为"闲着"被巡逻/进攻重新带走，不需要额外状态机。
func _manage_retreat() -> void:
	if _faction == null:
		return
	var home: Vector3 = RtsWorld.base_center(_faction)
	var wounded: Array = []
	for u in _army_units():
		if u == null or not is_instance_valid(u) or u.def == null:
			continue
		if u.def.max_hp <= 0.0:
			continue
		if u.hp > u.def.max_hp * RETREAT_HP:
			continue
		if u.global_position.distance_to(home) < 12.0:
			continue    # 已经在家的圈子里，别再刷命令
		wounded.append(u)
	if wounded.is_empty():
		return
	_sched.move(wounded, home, "retreat")

## 回防：只在"有敌人压到建筑门口"时触发，按 defend_ratio 抽人。
## 标签用 defend —— 调度器对防守命令不做重发节流（节流会直接导致基地被拆）。
##
## ★ 2C-9：拆成 `_defense_plan()`（判定）与 `_issue_defend()`（下令），判定逻辑未改；
##   防守在仲裁里**不占新增兵力**（用的是"防守锁定"那一层预留），见 §3.19。
func _manage_defense(diff: DifficultyDef) -> void:
	var p: Dictionary = _defense_plan(diff)
	if p.is_empty():
		return
	_issue_defend(p)


func _defense_plan(diff: DifficultyDef) -> Dictionary:
	if _faction == null:
		return {}
	var threats: Array = _threat_units()
	if threats.is_empty():
		return {}
	if _defend_cd > 0.0:
		return {}
	var army: Array = _army_units()
	if army.is_empty():
		return {}
	var n: int = clampi(int(ceil(float(army.size()) * clampf(diff.defend_ratio, 0.0, 1.0))),
			1, army.size())
	return {"n": n, "point": _defend_point(), "army_n": army.size(),
		"threat_n": threats.size()}


func _issue_defend(p: Dictionary) -> bool:
	if _faction == null:
		return false
	_defend_cd = DEFEND_REISSUE
	var n: int = int(p.get("n", 0))
	var army: Array = _army_units()
	if n < 1 or n > army.size():
		return false
	var point: Vector3 = p.get("point", RtsWorld.base_center(_faction))
	var before: int = int(_sched.stats().get("queued", 0))
	_sched.attack_move(army.slice(0, n), point, "defend")
	# 只在"真的登记了命令"时才打日志：否则每 4 秒一行同样的字，
	# 看起来像在疯狂下令，其实早就在路上了（到达判定已经拦掉了）。
	if int(_sched.stats().get("queued", 0)) > before:
		_log("回防：%d/%d 兵（压家敌人 %d 个）" % [
			n, army.size(), int(p.get("threat_n", 0))])
	return true

## 巡逻：没有战事时让 1~3 个兵绕着基地转，别全挤在基地里发呆。
## 顺手还能"发现自己家门口的敌人"——AI 的反应速度肉眼可见地变快。
## **确定性伪随机**：按 (标识, 序号) 直接算出 [0,1)，**不消费全局 randf 流**。
##
## 为什么要有它（M1 确定性诊断 2026-11-02）：
##   巡逻/散开/收队的落点只是"让人别挤成一坨"，与胜负无关，但它们每抽一次就移动
##   全局 RNG 游标一位。于是"某处多抽/少抽一次"会把**后面所有战斗骰子整体平移**，
##   对跑时表现为"同一帧内 RNG 流差 1 次"，把真正的分叉源藏起来。
##   把这类"纯散开"的随机从玩法流里摘出去，是**降噪**，不是修根因。
##
## 用 `hash(u.name)` 而不是 `get_instance_id()`：前者跨进程稳定（名字带自增序号），
## 后者是内存地址，换一次运行就变。
static func _dhash01(a: int, b: int) -> float:
	var h: int = a * 73856093 ^ b * 19349663 ^ 0x9E3779B9
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0x7FFFFFFF) / 2147483648.0


func _manage_patrol(_diff: DifficultyDef) -> void:
	var p: Dictionary = _patrol_plan()
	if p.is_empty():
		return
	_issue_patrol(p)


## 巡逻判定（2C-9 拆出来给扩展线报诉求用）：返回 {} 或 {n}
func _patrol_plan() -> Dictionary:
	if _patrol_cd > 0.0 or _faction == null:
		return {}
	if not bool(posture.get("allow_patrol", true)):
		return {}
	var army: Array = _army_units()
	if army.size() < 2:
		return {}
	var n: int = clampi(int(ceil(float(army.size()) * 0.25)), 1, 3)
	return {"n": n}


func _issue_patrol(p: Dictionary) -> bool:
	if _faction == null:
		return false
	_patrol_cd = PATROL_INTERVAL
	_patrol_seq += 1
	var n: int = int(p.get("n", 1))
	var army: Array = _army_units()
	var home: Vector3 = RtsWorld.base_center(_faction)
	var moved: int = 0
	for u in army:
		if moved >= n:
			break
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_idle_like():
			continue
		# 纯散开：走确定性伪随机，不动全局流（见 _dhash01）
		var seed_h: int = hash(u.name)
		var ang: float = _dhash01(seed_h, _patrol_seq) * TAU
		var r: float = 16.0 + 10.0 * _dhash01(seed_h, _patrol_seq + 7919)
		_sched.attack_move([u], home + Vector3(cos(ang) * r, 0.0, sin(ang) * r), "patrol")
		moved += 1
	return moved > 0

# ===========================================================================
# 波次记录表（2C-2 · 设计文档 §3.4）
#
# 一条记录 = 一次"出击"的完整生命周期。字段与 §3.4 一一对应；
# 派生量（survival_actual / survival_theory / roi / net_ratio）不落表，收尾时一次算好
# 存进记录里，读报告的人不用再推公式。
#
# 为什么挂在 AI 脑上而不是 bench 里：记录必须由**下令的人**写 ——
# bench 只看得到"波次号变了"，看不到"这一波是谁、花了多少、打到了谁"。
# ===========================================================================
## 环形缓冲：最多保留最近 8 条（§3.4）
const WAVE_LOG_MAX: int = 8
const VERDICT_NO_CONTACT: String = "无接敌"
const VERDICT_FAST: String = "快速被消灭"
const VERDICT_GOOD: String = "效果好"
const VERDICT_FAIR: String = "一般"
## 2C-3 新判定枚举（old 模式仍用上面四个，互不覆盖）
const VERDICT_ACHIEVED: String = "达成"
const VERDICT_BETTER: String = "好"
const VERDICT_BAD: String = "差"
const VERDICT_UNDECIDED: String = "未判"
## 击杀归属窗口（秒）：最后一击后 3 s 内死亡才算本波战果（§3.4 建议，先做最后一击）
const KILL_CREDIT_SEC: float = 3.0

## --- 目标系统（2C-3 · A5）---
## 五种规定目标 + 一个必要回退（主基地）。
## 说明：当前单位表里没有"分基地"建筑，GOAL_EXPANSION 映射到敌方外围经济建筑
## （伐木场/农场等非防御、非主基地的建筑）；主基地单独一类，不硬塞进"分基地"。
const GOAL_SCOUT: String = "侦查区域"
const GOAL_TOWER: String = "摧毁哨塔"
const GOAL_EXPANSION: String = "摧毁分基地"
const GOAL_ARROW_TOWER: String = "摧毁箭塔"
const GOAL_HIGH_THREAT: String = "摧毁高威胁目标"
const GOAL_BASE: String = "摧毁主基地（回退）"
## 侦查达成：任一存活成员进入目标 R 内并累计停留 DWELL 秒
const SCOUT_RADIUS: float = 6.0
const SCOUT_DWELL: float = 3.0
## 高威胁目标：最近 60 s 对己方伤害最多的敌方单位
const THREAT_WINDOW: float = 60.0

## --- 目标切换（2C-3 · B3/B5）---
## 换 2 次目标（方案 A）或距首次换目标 120 s（方案 C 兜底）→ 攒大波
const SWITCH_TO_BANK_N: int = 2
const SWITCH_TO_BANK_SEC: float = 120.0
## B2 紧急反击已按 2C-4 删除（任务书 §1/§3.6）：combat_hit 仍记录（输出/承伤照常累计），
## 但**不再触发换目标**。旧实现单波最多 38 次、均值 12.4 次把部队从目标上拉走（2C-3 报告 §16.10）。
## 单波最长存活时间（秒，兜底）：超时强制收尾，防止"永远在途"把状态机钉死。
## 90 s 的依据：本图一趟往返 + 一场遭遇战约 60~80 s；超过 90 s 还没回来，
## 说明它已经被别的事（回防/巡逻/下一波）接管，这一波的"生命周期"该结算了。
const WAVE_MAX_SEC: float = 120.0
## 接敌结束后多久算"这一波打完了"（秒）。
## 为什么需要它：本 AI 会在上一波还没回城时继续派增援（同一批兵可能被再次下令），
## 只等"全员回家待命"的话，一波永远收不了尾，记录表整个失效。
## 15 s 是一个"脱离接触就基本不会再打"的缓冲，比"等回城"更贴近实际存活时间。
const WAVE_QUIET_SEC: float = 15.0

## 波次记录（旧 → 新，最多 WAVE_LOG_MAX 条）
var wave_log: Array = []
## 在途波次（可以有多波同时在外面：后排增援不算"重开一波"）
var _waves_active: Array = []
## 60 秒滚动收入采样：[{t, v}]，v = 金 + 木的正向跳变（与 bench 同口径）
var _income_samples: Array = []
var _prev_gold: int = -1
var _prev_wood: int = -1


## 60 秒平均收入（金 + 木，按价值直接相加 —— 与 C1 的成本口径一致）。
## 样本不足时按实际跨度折算，不硬除以 60（否则开局前 10 秒会被低估 6 倍）。
func income_60s(now: float) -> float:
	var total: float = 0.0
	for e in _income_samples:
		total += float(e["v"])
	if _income_samples.is_empty():
		return 0.0
	var span: float = clampf(now - float(_income_samples[0]["t"]), 5.0, 60.0)
	return total / span


## 每 tick 记一次收入增量（只在正向跳变时累计：扣款不算负收入）
func _track_income(now: float) -> void:
	if _faction == null:
		return
	if _prev_gold < 0:
		_prev_gold = _faction.gold
		_prev_wood = _faction.wood
		return
	var dg: int = maxi(_faction.gold - _prev_gold, 0)
	var dw: int = maxi(_faction.wood - _prev_wood, 0)
	_prev_gold = _faction.gold
	_prev_wood = _faction.wood
	_income_samples.append({"t": now, "v": float(dg + dw)})
	while not _income_samples.is_empty() and now - float(_income_samples[0]["t"]) > 60.0:
		_income_samples.pop_front()


## 一支部队/一份编制的账面成本（C1：只金 + 木）
func _units_cost(units: Array) -> float:
	if _combat == null:
		return 0.0
	return float(_combat.call("wave_cost", units))


## 一份"id → 数量"编制的成本
func _dict_cost(d: Dictionary) -> float:
	var s: float = 0.0
	for id in d.keys():
		var def: UnitDef = Cfg.unit(StringName(id))
		if def != null and _combat != null:
			s += float(_combat.call("unit_cost", def)) * float(d[id])
	return s


## 开一波记录。`units` 只传真的派出去的那批（留守不算）。
## `goal` = A5 目标（type/target_id/pos/name）；空字典 = 没有目标（只记录位置）。
##
## ★ 允许多波同时在途：上一波还在外面打的时候又派了增援，这是两波，
##   不能把前一波"强制收尾"（那会把不完整的数据喂给状态机）。
func _open_wave(units: Array, target: Vector3, foe: RtsFaction,
		goal: Dictionary = {}) -> void:
	var by_id: Dictionary = {}
	var ids: Dictionary = {}
	for u in units:
		if u == null or not is_instance_valid(u) or u.def == null:
			continue
		by_id[u.def.id] = int(by_id.get(u.def.id, 0)) + 1
		# 2C-6：members 的值从 `true` 改成 def.id —— 收尾算"最近出过手的成员"时
		# 节点可能已经 free，读不到 def，必须开局就把 def.id 存下来。
		ids[u.get_instance_id()] = String(u.def.id)
	_wave_index += 1
	_waves_active.append({
		"wave_id": _wave_index,
		"t_start": Game.elapsed,
		# 2C-9：开波时记下"已经换过几次目标"，收尾时算这一波换了几次
		# （B3 的规则是换满 2 次进攒大波，`SWITCH_TO_BANK_N`）
		"switch_at_open": _switch_count,
		"units_out": by_id,
		"members": ids,
		"strength": ids.size(),
		"cost_out": _units_cost(units),
		"target": target,
		"target_name": foe.display_name if foe != null else "?",
		# --- 2C-3 目标 ---
		"goal_type": String(goal.get("type", "")),
		"goal_target_id": int(goal.get("target_id", 0)),
		"goal_target_pos": goal.get("pos", target),
		"goal_name": String(goal.get("name", "")),
		"goal_achieved": false,
		"t_goal": -1.0,
		"goal_damage": 0.0,
		# --- 2C-5 P1-5 达成归属（只记录，不改变判定）---
		# goal_last_hit：最后一击的攻击者是不是本波成员
		# goal_damage_ratio：本波对目标造成的伤害 ÷ 目标总生命
		"goal_last_hit": false,
		"goal_damage_ratio": -1.0,
		"goal_max_hp": 0.0,
		"goal_last_attacker": 0,
		# --- 2C-5 P0-1 承伤分母：曾作为 target 的成员（实例 id → def.id）---
		"was_target": {},
		# --- 2C-6 P0 输出分母 B：本波成员"最近一次出手"的时刻（实例 id → elapsed）---
		# 只记 mine_hit（= 本波成员当 attacker），不记被打 —— 口径是"真出过手的人"。
		"recent_attack": {},
		# --- 四样判据的原始量 ---
		"t_combat_begin": -1.0,
		"t_combat_end": -1.0,
		"t_last_hit": -1.0,
		"damage_out": 0.0,
		"damage_in": 0.0,
		# 2C-4：有效交战时间逐刀累计（断档 > COMBAT_GAP_SEC 的间隔不计）
		"combat_time_acc": 0.0,
		"scout_dwell": 0.0,
		"t_prev_check": Game.elapsed,
		"forced_timeout": false,
		# --- 旧口径（辅助记录）---
		"contacts": {},
		"t_contact_begin": -1.0,
		"t_contact_end": -1.0,
		"losses_mine": {},
		"losses_enemy": {},
		"hits": {},
		"t_last_death": -1.0,
	})


## 收一波：算判定 + 派生量 + 落表 + （可选）驱动状态机。
## `reason`：dead / home / quiet / timeout / goal —— 判定要用它区分"真的打完了"和"超时了"。
##
## 2C-3：无论 old/new，四样判据的原始量与派生量都会落表（old 只改 verdict 口径），
## 这样 old/new 对照时看的是**同一批记录**，不是两次不同口径的跑。
func _close_wave(rec: Dictionary, now: float, reason: String = "home",
		apply_transition: bool = true) -> void:
	_waves_active.erase(rec)
	var t_start: float = float(rec["t_start"])
	rec["t_return"] = now
	rec["end_reason"] = reason
	# 2C-9：这一波换过几次目标（B3 规则上限 2 次）；bench 的"每波明细"用它
	rec["retarget_n"] = maxi(_switch_count - int(rec.get("switch_at_open", 0)), 0)
	rec["survival_actual"] = maxf(now - t_start, 0.0)
	var income: float = maxf(income_60s(now), 1.0)
	rec["income_60s"] = income
	rec["survival_theory"] = float(rec["cost_out"]) / income
	rec["losses_mine_cost"] = _dict_cost(rec["losses_mine"])
	rec["losses_enemy_cost"] = _dict_cost(rec["losses_enemy"])
	var mine_cost: float = float(rec["losses_mine_cost"])
	var enemy_cost: float = float(rec["losses_enemy_cost"])
	# 投入产出比 / 净交换比 —— 2C-3 起**只作辅助记录**（不参与 new 判定）
	rec["roi"] = enemy_cost / maxf(float(rec["cost_out"]), 0.001)
	rec["net_ratio"] = (enemy_cost / mine_cost) if mine_cost > 0.0 else -1.0

	# --- 存活（判定表的一列，也是 old 模式的输入）---
	var survivors: int = 0
	for id in rec["members"].keys():
		var u = instance_from_id(int(id))
		if u != null and is_instance_valid(u) and u.is_alive():
			survivors += 1
	rec["survivors"] = survivors
	rec["wiped"] = survivors == 0

	# --- 四样判据：(a) 有效交战时间（2C-4 用户确认）---
	# 逐刀累计（相邻两刀间隔 > COMBAT_GAP_SEC 的断档不计），替换旧口径
	# "最后一次接敌 − 首次接敌"——旧口径把两场交火之间的走路/绕行也算进战斗时间，
	# 是 2C-3 实测 output_eff 71% < 0.3、"好"永远不可达的主因（2C-3 报告 §16.7）。
	# t_combat_begin/end 保留为首/末刀时刻，仅供报告对照。
	var begin: float = float(rec.get("t_combat_begin", -1.0))
	var last_hit: float = float(rec.get("t_last_hit", -1.0))
	var combat_time: float = float(rec.get("combat_time_acc", 0.0))
	rec["t_combat_begin"] = begin
	rec["t_combat_end"] = last_hit if begin >= 0.0 else -1.0
	rec["combat_time"] = combat_time
	# (b) 理论战斗时间
	var theory_time: float = float(_model_call("theory_combat_time",
			[float(rec["cost_out"]), AIV.base_sec()]))
	rec["theory_time"] = theory_time
	rec["time_ratio"] = combat_time / maxf(theory_time, 0.001)
	# (c) 理论输出 / (d) 理论承伤
	# 2C-6 P0：输出分母改 B —— 只算"最近 RECENT_ATTACK_WINDOW 秒内有过 combat_hit"的成员。
	# mode=all 时回 2C-5 旧口径（Σ全员纸面 DPS），同一构建里可对照。
	#
	# ★ 参照时刻 = **本波成员最后一次出手**（不是 t_last_hit、更不是 now）。
	#   实测两条坑（10 min seed1，20 波）：
	#   · 用 now：收尾在安静 15 s 之后 → 全员都超窗 → 分母恒 0，output_eff 退化成伤害值；
	#   · 用 t_last_hit：它含"我们被打"的那一刀，远程被白打/近战在走位时最后 3 s 无人出手
	#     → **一半的波次分母为 0**（出手人数/强度中位数 0.000），output_eff 均值飙到 85。
	#   取 max(recent_attack) 才等于"这波最后一次开火的时刻"，分母 >0 当且仅当这波真打出过伤害。
	var ref_t: float = -1.0
	var recent_attack: Dictionary = rec.get("recent_attack", {})
	for uid in recent_attack.keys():
		ref_t = maxf(ref_t, float(recent_attack[uid]))
	if ref_t < 0.0:
		ref_t = now
	var recent_counts: Dictionary = {}
	var recent_n: int = 0
	var win: float = AIV.recent_attack_window()
	var members: Dictionary = rec.get("members", {})
	for uid in recent_attack.keys():
		if ref_t - float(recent_attack[uid]) > win:
			continue
		var rdid: String = String(members.get(uid, ""))
		if rdid.is_empty():
			continue
		recent_counts[rdid] = int(recent_counts.get(rdid, 0)) + 1
		recent_n += 1
	var theory_out: float = 0.0
	if AIV.output_theory_mode() == AIV.OT_ALL:
		theory_out = float(_model_call("theory_output",
				[rec["units_out"], combat_time, AIV.output_coef()]))
	else:
		theory_out = float(_model_call("theory_output_recent",
				[recent_counts, combat_time, AIV.output_coef()]))
	# 2C-5 P0-1：承伤分母改口径 —— 只算"曾作为 target 的成员"的有效生命。
	# mode=all 时回 2C-4 旧口径（全程总有效生命），同一次构建里可对照。
	var targeted_counts: Dictionary = {}
	var was_target: Dictionary = rec.get("was_target", {})
	for uid in was_target.keys():
		var did: String = String(was_target[uid])
		targeted_counts[did] = int(targeted_counts.get(did, 0)) + 1
	var theory_hp: float = float(_model_call("damage_theory",
			[rec["units_out"], targeted_counts, AIV.damage_theory_mode()]))
	var dmg_out: float = float(rec.get("damage_out", 0.0))
	var dmg_in: float = float(rec.get("damage_in", 0.0))
	# (e)(f)(g) 实际输出/承伤 + 两个比值（各自独立，绝不相除）
	rec["output_actual"] = dmg_out
	rec["output_theory"] = theory_out
	rec["output_eff"] = dmg_out / maxf(theory_out, 1.0)
	rec["output_theory_mode"] = AIV.output_theory_mode()
	rec["recent_attack_n"] = recent_n
	rec["recent_attack_window"] = win
	rec["damage_actual"] = dmg_in
	rec["damage_theory"] = theory_hp
	rec["damage_theory_mode"] = AIV.damage_theory_mode()
	rec["targeted_n"] = was_target.size()
	rec["damage_ratio"] = dmg_in / maxf(theory_hp, 1.0)
	# --- 2C-7 P5：damage_ratio 的**归一化对照量**（只记录，不改 classify_verdict）---
	#   hp_all_out     = Σ(全员有效生命)，即 targeted 的"另一头"：这一波所有人的血量总和
	#   raw_damage_all = 实际承伤 ÷ hp_all_out
	#                    → **无量纲、与窗口 [0.4,0.9] 同量纲**，4×4 矩阵用它算
	#   raw_damage_ps  = 实际承伤 ÷ (hp_all_out × 战斗时间)
	#                    → 提示词字面公式（1/s），与窗口不同量纲，只作分布附注，不进矩阵
	# 为什么两个都存：如果只存字面公式，4×4 矩阵会得到 0.001 量级的数，
	# 无论窗口怎么扫都"0 波进窗"—— 那是量纲错误，不是数据结论。两个都落盘，报告写清用哪个。
	var hp_all: float = float(_model_call("damage_theory",
			[rec["units_out"], {}, "all"]))
	rec["hp_all_out"] = hp_all
	rec["raw_damage_all"] = float(_model_call("raw_damage_ratio", [dmg_in, hp_all]))
	rec["raw_damage_ps"] = float(_model_call("raw_damage_ratio",
			[dmg_in, hp_all * maxf(combat_time, 1.0)]))

	# --- 前后排构成（C1：按 role 标签数人头，不是成本）---
	var front_n: int = 0
	var back_n: int = 0
	var all_n: int = 0
	for id in rec["units_out"].keys():
		var d: UnitDef = Cfg.unit(StringName(id))
		if d == null:
			continue
		var n: int = int(rec["units_out"][id])
		all_n += n
		if bool(_model_call("is_frontline", [d])):
			front_n += n
		elif bool(_model_call("is_backline", [d])):
			back_n += n
	rec["front_ratio"] = float(front_n) / float(maxi(all_n, 1))
	rec["back_ratio"] = float(back_n) / float(maxi(all_n, 1))

	# --- 判定 ---
	rec["verdict_mode"] = AIV.mode()
	if AIV.is_old():
		# 2C-2 旧口径：先看有没有接敌，再看"快速被消灭"，最后看投入产出比。
		# ★ 超时收尾（timeout）不判"快速"：actual 被截断，再除理论值必然偏小。
		var contacts: Dictionary = rec["contacts"]
		if contacts.is_empty():
			rec["verdict"] = VERDICT_NO_CONTACT
		elif reason != "timeout" \
				and float(rec["survival_actual"]) / maxf(float(rec["survival_theory"]), 0.001) < 0.5:
			rec["verdict"] = VERDICT_FAST
		elif float(rec["roi"]) >= P1_ROI:
			rec["verdict"] = VERDICT_GOOD
		else:
			rec["verdict"] = VERDICT_FAIR
	else:
		var v = _model_call("classify_verdict", [
			bool(rec.get("goal_achieved", false)),
			bool(rec.get("forced_timeout", false)),
			combat_time, theory_time,
			float(rec["output_eff"]), float(rec["damage_ratio"]),
			survivors, int(rec.get("strength", 0)),
		])
		rec["verdict"] = String(v)

	# --- 构成建议（C2：只记录，不执行；禁止自动改配比）---
	var oe: float = float(rec["output_eff"])
	var dr: float = float(rec["damage_ratio"])
	if oe > 1.3 and dr < 0.5:
		rec["comp_advice"] = "补前排"
	elif oe < 0.7 and dr > 0.7:
		rec["comp_advice"] = "补后排"
	else:
		rec["comp_advice"] = "不调"

	wave_log.append(rec)
	while wave_log.size() > WAVE_LOG_MAX:
		wave_log.pop_front()
	# --- 2C-9：兵力预留制的**解锁**（波次打完 = 这一波锁的兵回来了）---
	_troop_unlock("wave:%d" % int(rec.get("wave_id", 0)), true)
	# --- 2C-9：L1 短窗口"最近 3 波判定"（固定长度，槽位覆盖）---
	_l1_verdicts.append(String(rec["verdict"]))
	while _l1_verdicts.size() > L1_VERDICT_N:
		_l1_verdicts.pop_front()
	# --- 存活撤回：达成 / 好 / 差 / 强制超时 → 把还活着的人叫回家 ---
	# 一般 → 换目标（不撤回）；未判 → 继续打（不撤回）
	if AIV.is_new():
		var verdict: String = String(rec["verdict"])
		if verdict == VERDICT_ACHIEVED or verdict == VERDICT_BETTER \
				or verdict == VERDICT_BAD or bool(rec.get("forced_timeout", false)):
			_recall_members(rec)
	if apply_transition:
		_on_wave_closed(rec)


## 把本波还活着的成员叫回基地（"存活撤回"）。标签 recall 不参与重发节流。
func _recall_members(rec: Dictionary) -> void:
	if _sched == null or _faction == null:
		return
	var home: Vector3 = RtsWorld.base_center(_faction)
	var arr: Array = []
	for id in rec["members"].keys():
		var u = instance_from_id(int(id))
		if u != null and is_instance_valid(u) and u.is_alive():
			arr.append(u)
	if not arr.is_empty():
		_sched.move(arr, home, "recall")


## 每 tick 维护在途波次：目标达成 / 全员死亡 / 全员回家 / 超时 → 收尾
func _tick_wave(now: float) -> void:
	if _waves_active.is_empty() or _faction == null:
		return
	var home: Vector3 = RtsWorld.base_center(_faction)
	var limit: float = AIV.time_limit() if AIV.is_new() else WAVE_MAX_SEC
	# duplicate()：_close_wave 会从 _waves_active 里删元素，边遍历边删会跳项
	for rec in _waves_active.duplicate():
		var members: Dictionary = rec["members"]
		var alive_units: Array = []
		var all_home_idle: bool = true
		for id in members.keys():
			var u = instance_from_id(int(id))
			if u == null or not is_instance_valid(u) or not u.is_alive():
				continue
			alive_units.append(u)
			if not bool(u.call("is_idle_like")) \
					or u.global_position.distance_to(home) > DEFENSE_RADIUS:
				all_home_idle = false
		var dt: float = maxf(now - float(rec.get("t_prev_check", now)), 0.0)
		rec["t_prev_check"] = now

		# 目标达成（侦查停留 / 目标死亡）—— 达成即收尾，不必等回家
		# ★ old 模式不做达成判定：2C-2 的波次生命周期里没有"目标"这一层，
		#   加上它会让 old 对照组的收尾时刻整体提前，失去可比性。
		if AIV.is_new() and not bool(rec.get("goal_achieved", false)):
			if _goal_reached(rec, alive_units, dt):
				rec["goal_achieved"] = true
				rec["t_goal"] = now
		# （2C-4：B2 紧急反击已删除——combat_hit 仍记录，但不触发换目标）

		if alive_units.is_empty():
			# 全员阵亡：t_return 取最后一次死亡时刻（比"发现的时候"更准）
			var t_end: float = maxf(float(rec.get("t_last_death", now)), float(rec["t_start"]))
			_close_wave(rec, t_end, "dead")
		elif AIV.is_new() and bool(rec.get("goal_achieved", false)):
			_close_wave(rec, now, "goal")
		elif AIV.is_new() and now - float(rec["t_start"]) >= limit:
			# A3：单波存活 > 180 s → 强制收尾判"一般"并撤回
			rec["forced_timeout"] = true
			_close_wave(rec, now, "timeout")
		elif all_home_idle:
			_close_wave(rec, now, "home")
		elif float(rec["t_contact_end"]) > 0.0 \
				and now - float(rec["t_contact_end"]) >= WAVE_QUIET_SEC:
			# 已脱离接触 WAVE_QUIET_SEC 秒：这一波打完了（人可能还在回城路上）
			_close_wave(rec, float(rec["t_contact_end"]) + WAVE_QUIET_SEC, "quiet")
		elif not AIV.is_new() and now - float(rec["t_start"]) >= WAVE_MAX_SEC:
			_close_wave(rec, now, "timeout")


## 目标达成判据（A5）：
##   侦查区域 —— 任一存活成员进入 6 m 并累计停留 3 s；
##   其余       —— 目标实体死亡（unit_died 已经立案的话这里直接为真）。
func _goal_reached(rec: Dictionary, alive_units: Array, dt: float) -> bool:
	var gt: String = String(rec.get("goal_type", ""))
	if gt == GOAL_SCOUT:
		var pos: Vector3 = rec.get("goal_target_pos", rec.get("target", Vector3.ZERO))
		var inside: bool = false
		for u in alive_units:
			if u.global_position.distance_to(pos) <= SCOUT_RADIUS:
				inside = true
				break
		if inside:
			rec["scout_dwell"] = float(rec.get("scout_dwell", 0.0)) + dt
		return float(rec.get("scout_dwell", 0.0)) >= SCOUT_DWELL
	var tid: int = int(rec.get("goal_target_id", 0))
	if tid == 0:
		return false
	var target = instance_from_id(tid)
	return target == null or not is_instance_valid(target) or not target.is_alive()


## combat_hit：既维护"谁在打我"账本（高威胁目标），也累计本波的实际输出/承伤。
func _on_combat_hit(attacker: Node3D, target: Node3D, damage: float, _crit: bool) -> void:
	if attacker == null or target == null:
		return
	if not is_instance_valid(attacker) or not is_instance_valid(target):
		return
	var now: float = Game.elapsed
	var dmg: float = maxf(damage, 0.0)
	# 高威胁目标账本：任何打到我方单位/建筑的刀都记（不要求本波参与）
	_note_threat(attacker, target, dmg, now)
	if _waves_active.is_empty():
		return
	var aid: int = attacker.get_instance_id()
	var tid: int = target.get_instance_id()
	for rec in _waves_active:
		var members: Dictionary = rec["members"]
		var mine_hit: bool = members.has(aid)
		var mine_taken: bool = members.has(tid)
		if not mine_hit and not mine_taken:
			continue
		# (a) 战斗时间（2C-4 有效交战口径）：首次成为 attacker/target 起表；
		# 相邻两刀间隔 > COMBAT_GAP_SEC 视为断档，走路/绕行段不计入。
		if float(rec["t_combat_begin"]) < 0.0:
			rec["t_combat_begin"] = now
		rec["combat_time_acc"] = float(rec.get("combat_time_acc", 0.0)) \
				+ float(_model_call("hit_gap_contrib",
					[float(rec["t_last_hit"]), now, AIV.combat_gap_sec()]))
		rec["t_last_hit"] = now
		if float(rec["t_contact_begin"]) < 0.0:
			rec["t_contact_begin"] = now
		rec["t_contact_end"] = now
		var other = target if mine_hit else attacker
		var od: UnitDef = other.get("def")
		if od != null and od.kind == RtsConst.Kind.UNIT:
			var contacts: Dictionary = rec["contacts"]
			var e: Dictionary = contacts.get(od.id, {"t": now, "n": 0})
			e["t"] = now
			e["n"] = int(e["n"]) + 1
			contacts[od.id] = e
		if mine_hit:
			# (e) 实际输出 + 最后一击归属（归属只是辅助记录，不参与 new 判定）
			rec["damage_out"] = float(rec.get("damage_out", 0.0)) + dmg
			rec["hits"][tid] = now
			# 2C-6 P0：给这个成员打"最近出过手"的时间戳（收尾时按 3 s 窗过滤）
			rec["recent_attack"][aid] = now
			# 数据质量：这一刀打的是不是本波的目标（用于识别"达成但没参与"）
			if tid == int(rec.get("goal_target_id", 0)):
				rec["goal_damage"] = float(rec.get("goal_damage", 0.0)) + dmg
				# 2C-5 P1-5：记"最后一个打目标的人"，目标死时用它判最后一击归属
				rec["goal_last_attacker"] = aid
		if mine_taken:
			# (e) 实际承伤（B2 已删：不再记录"谁在打我"用于反击）
			rec["damage_in"] = float(rec.get("damage_in", 0.0)) + dmg
			# 2C-5 P0-1：标记"这个成员曾经当过 target"——承伤分母只算这批人。
			# 存 def.id 而不是只存实例 id：收尾时节点可能已经 free，读不到 def。
			var tdef: UnitDef = target.get("def")
			if tdef != null:
				rec["was_target"][tid] = String(tdef.id)


## 记一笔"敌方打我方"的伤害（60 s 滚动）。只记我方被伤害的方向。
func _note_threat(attacker: Node3D, target: Node3D, dmg: float, now: float) -> void:
	if _faction == null:
		return
	var tf = target.get("faction")
	if tf == null or tf != _faction:
		return
	# 2C-9 L1：最近 30 s 受伤总量（1 s 一个环形槽，槽位覆盖，O(1)，不存事件列表）
	_l1_add_damage(dmg, now)
	var af = attacker.get("faction")
	if af == null or af == _faction:
		return
	_threat_ledger.append({
		"t": now,
		"id": attacker.get_instance_id(),
		"faction": String(af.display_name),
		"dmg": dmg,
	})
	while not _threat_ledger.is_empty() \
			and now - float(_threat_ledger[0]["t"]) > THREAT_WINDOW:
		_threat_ledger.pop_front()


## unit_died：本波成员死了记我方损失；目标死了立案"达成"；
## 3 s 内被本波打过的人死了记敌方损失（**辅助记录**，2C-3 不再拿它判好坏）。
func _on_unit_died(unit: Node3D) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var d: UnitDef = unit.get("def")
	var now: float = Game.elapsed
	# 2C-4 T10 追踪（与波次无关）：任意一个**出兵建筑**被摧毁 → 记旗标，
	# 攒大波期间触发召回。只算敌方摧毁：当前 AI/玩家都没有"自拆建筑"路径
	# （若有，需要给 unit_died 加击杀者归属——报告已标注）。
	if d != null and d.kind == RtsConst.Kind.BUILDING:
		var uf = unit.get("faction")
		if uf == _faction and _producer_ids().has(d.id):
			_producer_lost = true
	if _waves_active.is_empty():
		return
	var uid: int = unit.get_instance_id()
	for rec in _waves_active:
		var members: Dictionary = rec["members"]
		if members.has(uid):
			if d != null:
				var lm: Dictionary = rec["losses_mine"]
				lm[d.id] = int(lm.get(d.id, 0)) + 1
			rec["t_last_death"] = now
			continue
		# 目标达成：goal_target_id 死了（哨塔/箭塔/分基地/高威胁/主基地）
		# ★ 只在 new 模式立案：old 模式没有"目标"这一层，不能被它提前收尾。
		if AIV.is_new() and int(rec.get("goal_target_id", 0)) == uid:
			rec["goal_achieved"] = true
			rec["t_goal"] = now
			# 2C-5 P1-5 达成归属（**只记录，不改变达成判定**）：
			#   最后一击 = 目标临死前最后一刀的攻击者是否属于本波；
			#   伤害占比 = 本波对目标的累计伤害 ÷ 目标总生命（近似，含过量伤害）。
			if d != null:
				rec["goal_max_hp"] = float(d.max_hp)
			rec["goal_damage_ratio"] = float(_model_call("goal_damage_ratio_of",
					[float(rec.get("goal_damage", 0.0)), float(rec.get("goal_max_hp", 0.0))]))
			var last_aid: int = int(rec.get("goal_last_attacker", 0))
			rec["goal_last_hit"] = last_aid != 0 and members.has(last_aid)
		if d == null or d.kind != RtsConst.Kind.UNIT:
			continue
		var hit_t: float = float(rec["hits"].get(uid, -999.0))
		if hit_t >= now - KILL_CREDIT_SEC:
			var le: Dictionary = rec["losses_enemy"]
			le[d.id] = int(le.get(d.id, 0)) + 1


# ---------------------------------------------------------------------------
# 策略状态机（2C-2 · 设计文档 §3.3）
#
# 状态：试探 → 加强 → 攒大波 → 换目标 → 升科技换兵种（五个，不含终态）。
# 所有指令仍然只走 `_sched`，本状态机**不新增任何下令通道**。
# ---------------------------------------------------------------------------
const ST_PROBE: String = "probe"
const ST_PRESS: String = "press"
const ST_BANK: String = "bank"
const ST_RETARGET: String = "retarget"
## ST_TECH 已按 2C-4 删除（任务书 §1：科技改运营线与战斗并行）；
## 状态机最终剩四个状态：试探 / 加强 / 攒大波 / 换目标。

## P1："效果好"的投入产出比阈值（敌损成本 / 我投成本）—— 定死值
const P1_ROI: float = 0.9
## P2：净交换比不设下限，仅记录（代码里没有任何判断读 net_ratio）
## P3：连续几次"快速被消灭"触发攒大波；出现"效果好"就重置（定死值）
const P3_FAST_STREAK: int = 3
## P4：攒大波时小股骚扰的独立资金池（日常保留 ≥150 金）。
## ★ 本实现用"攒大波期间**停发小股**"替代了这条门槛：不发小股，就没有"小股被吃掉"，
##   也就没有必要给日常预算留 150 金。比 P4 更严，且不引入任何"必须留 X 金"的硬闸。
const P4_DAILY_RESERVE: int = 150
## C3（2C-4 用户覆盖）：攒大波门槛 = 当前可派战斗单位**总成本(金+木)** ≥ 1.5 × 上一次实际派出成本。
## **不封顶**（P5 的 5× 封顶删除）。旧口径"2.5× 单位数"在 max_army=10 下数学不可达（T9=0）。
const BANK_MULT: float = 1.5
## 攒大波超时：90 s 到点**直接出击**，不再转科技（删 T11a/T11b，任务书 §1）
const BANK_MAX_SEC: float = 90.0
## P6：同一目标效果递减 —— 投入产出比从 ≥1.0 掉到 <0.8，连续 N=2 波
const P6_DROP_HIGH: float = 1.0
const P6_DROP_LOW: float = 0.8
const P6_N: int = 2
## T12b：换目标 10 s 内选不出新目标 → 回试探
const T12_SEC: float = 10.0
## 2C-4 科技运营线（§4.3）：前 5 分钟不科研；每 10 s 检查一次；
## "最晚 7 分钟开始"是决策自维护的约束（时间线表 TODO 留空），不是强制兜底。
const RESEARCH_NOT_BEFORE_SEC: float = 300.0
const RESEARCH_CHECK_EVERY: float = 10.0
const RESEARCH_LATEST_SEC: float = 420.0
## 2C-4 常态出击比例（§4.2）：0.75 floor（10 派 7），且不超过"军队数 − 防守下限"
const ATTACK_RATIO_NORMAL: float = 0.75

## 当前状态（bench / 报告读它）
var strat_state: String = ST_PROBE
var _state_since: float = 0.0
## 连续"快速被消灭"次数（T3 的输入）
var _fast_streak: int = 0
## 上一次实际派出的兵力（单位数，C3）与成本（报告用）
var _last_wave_strength: int = 0
var _last_wave_cost: float = 0.0
## 当前打的那一家（加强/换目标用）
var _press_foe: String = ""
## 当前打的那个**目标**（2C-3：goal 是 Dictionary，含 type/target_id/pos/name）
var _press_goal: Dictionary = {}
## 攒大波时选定的目标（T9 打出去时转成 _press_goal）
var _bank_goal: Dictionary = {}
## 2C-3：连续"差"次数（B5）与换目标次数/首次换目标时刻（B3）
var _bad_streak: int = 0
var _switch_count: int = 0
var _first_switch_t: float = -1.0
## 最近 60 s 的"谁在打我"账本：{t, id, faction, dmg}（高威胁目标的唯一数据源）
var _threat_ledger: Array = []
## T2"换小股路线"：每次快速被消灭后换一个接近角
var _probe_seq: int = 0
## 攒大波的入场可用成本与基准（1.5× 门槛的输入；T11 采样已删）
var _bank_entry_cost: float = 0.0
var _bank_baseline_cost: float = 0.0
## 2C-4 T10：出兵建筑被敌方摧毁（攒大波期间触发召回）
var _producer_lost: bool = false
## 攒大波突围（T9）发出的那一波用 bank 出击口径（含临时防守）
var _bank_breakout: bool = false
## 2C-4 科技运营线：检查节流 / 研究完成跟踪 / 扩张线状态（0 未开始 1 进行中 2 完成）
var _research_cd: float = 0.0
var _research_was_running: bool = false
var _expand_state: int = 0
## 2C-5 P1-4：修理下令节流 + 统计（报告/bench 读 repair_stats）
var _repair_cd: float = 0.0
## 修理遥测（报告/bench 读）：issued 真下令次数；candidates 有候选的 tick 数；
## blocked_wood 木材不够修满的 tick 数；blocked_no_builder 没工位的 tick 数；
## blocked_builder_busy（2C-7）工位**正在盖房子**的 tick 数 —— 与"没工位"必须分开：
## 前者说明"建造把工位占满了"（下一轮要么加人要么让建造排队），后者说明"压根没人"。
var repair_stats: Dictionary = {
	"issued": 0, "buildings": {},
	"candidates": 0, "candidate_buildings": 0,
	"blocked_wood": 0, "blocked_no_builder": 0,
	"blocked_builder_busy": 0, "builder_role": "", "builder_swaps": 0,
	# 2C-8：工位数（目标/实际），报告画"工位数曲线"用
	"builder_slots": 0, "builder_count": 0,
}
## 2C-6：建造下单计数（id → 次数），只记**成功下达**的建造命令（报告用）。
## 为什么单独一个字典：strat_log 只记状态转移，_log 是 stdout；
## 长局要看"农场建了几次/兵营几座"必须有一个可落盘的口径。
var build_stats: Dictionary = {}
## P6 的参考高点与连续低波计数
var _p6_ref_roi: float = -1.0
var _p6_low_streak: int = 0
## 转移统计与时间线（报告/bench 读）
var strat_stats: Dictionary = {
	"T1": 0, "T2": 0, "T3": 0, "T4": 0, "T5": 0, "T6": 0, "T7": 0, "T8": 0,
	"T9": 0, "T10": 0, "T12": 0, "T12b": 0,
	# 2C-3：换目标次数达标→攒大波 / 未判（不转移）
	"T15": 0, "N0": 0,
	# 2C-4：T11a/T11b/T13/T14 删除；科技改**运营线日志**（不再算状态转移）
	"research_started": 0, "research_done": 0, "research_skipped_threat": 0,
}
var strat_log: Array = []


## 状态转移（唯一入口）：计数 + 记时间线 + 处理入场副作用
func _go(next: String, tag: String) -> void:
	strat_stats[tag] = int(strat_stats.get(tag, 0)) + 1
	strat_log.append({"t": snappedf(Game.elapsed, 0.1), "tag": tag,
		"from": strat_state, "to": next})
	while strat_log.size() > 32:
		strat_log.pop_front()
	strat_state = next
	_state_since = Game.elapsed
	if next == ST_BANK:
		var avail_now: float = _units_cost(_available_units())
		_bank_entry_cost = avail_now
		# 2C-4 §3.5：门槛基准 = 上一次**实际派出**成本（不是全部训练成本）；
		# 无历史（首波退化）= 进场时可用成本 × 0.75。
		_bank_baseline_cost = float(_model_call("bank_baseline", [_last_wave_cost, avail_now]))
		_producer_lost = false
		# B4：攒大波的目标按 0.4×距离 + 0.4×威胁 选（效果分留桩）
		_bank_goal = _choose_goal(_foe_faction(), "bank")
		# ★ 进入攒大波 = 本轮"换目标"周期结束，计数清零。
		#   不清零的话 T11b→技术→探测之后，下一波只要判"一般"就立刻再进 T15，
		#   AI 会在"攒 90 s → 技术 60 s → 打一波 → 再攒"之间循环（seed2 实测 T15×2）。
		_reset_switch()
	if next == ST_RETARGET:
		_p6_ref_roi = -1.0
		_p6_low_streak = 0
	if tag == "T2":
		_probe_seq += 1
	if tag == "T9":
		# 攒够了（或 90 s 到点）：本 tick 就允许出兵，且这一波用**攒大波出击口径**
		#（训练出来的全部战斗单位，含临时防守；只留保底 ceil(下限×2/3)）
		_bank_breakout = true
		if not _bank_goal.is_empty():
			_press_goal = _bank_goal
		_next_wave_at = Game.elapsed


## B3：换目标。换满 2 次（或距首次换目标 ≥120 s）→ 攒大波（T15）。
func _request_switch(tag: String) -> void:
	_switch_count += 1
	if _switch_count == 1:
		_first_switch_t = Game.elapsed
	var by_count: bool = _switch_count >= SWITCH_TO_BANK_N
	var by_time: bool = _first_switch_t >= 0.0 \
			and Game.elapsed - _first_switch_t >= SWITCH_TO_BANK_SEC
	if by_count or by_time:
		_go(ST_BANK, "T15")
	else:
		_go(ST_RETARGET, tag)


func _reset_switch() -> void:
	_switch_count = 0
	_first_switch_t = -1.0
	_bad_streak = 0


## T10 召回：只把"闲着且在外面"的叫回家；正在战斗的（order != NONE）等打完再回。
## 留家部队不动（正常防守由 _manage_defense 管）。
func _recall_outside_idle() -> void:
	if _sched == null or _faction == null:
		return
	var home: Vector3 = RtsWorld.base_center(_faction)
	var arr: Array = []
	for u in _army_units():
		if u == null or not is_instance_valid(u):
			continue
		if not bool(u.call("is_idle_like")):
			continue
		if u.global_position.distance_to(home) <= 12.0:
			continue
		arr.append(u)
	if not arr.is_empty():
		_sched.move(arr, home, "recall")
		_log("T10：出兵建筑被毁，召回在外部队 %d 人（战斗中的打完再回）" % arr.size())


## 一波打完：按判定推进状态机。
## old 模式 = 2C-2 原逻辑（不改）；new 模式 = 2C-3 判定表 + B1~B5 的出口。
func _on_wave_closed(rec: Dictionary) -> void:
	var verdict: String = String(rec.get("verdict", VERDICT_NO_CONTACT))
	var roi: float = float(rec.get("roi", 0.0))
	_last_wave_strength = int(rec.get("strength", 0))
	_last_wave_cost = float(rec.get("cost_out", 0.0))
	if AIV.is_old():
		# P3：只有"快速被消灭"累计；"效果好"清零（"一般/无接敌"既不累计也不清零）
		if verdict == VERDICT_FAST:
			_fast_streak += 1
		elif verdict == VERDICT_GOOD:
			_fast_streak = 0
		match strat_state:
			ST_PROBE:
				if verdict == VERDICT_GOOD:
					_press_foe = String(rec.get("target_name", ""))
					_go(ST_PRESS, "T1")
				elif verdict == VERDICT_FAST:
					if _fast_streak >= P3_FAST_STREAK:
						_go(ST_BANK, "T3")
					else:
						_go(ST_PROBE, "T2")
				elif verdict == VERDICT_FAIR:
					_go(ST_PROBE, "T4")
			ST_PRESS:
				if verdict == VERDICT_GOOD:
					# P6：曾经 ≥1.0，之后连续 2 波 <0.8 → 这个目标打不动了，换一家
					if roi >= P6_DROP_HIGH:
						_p6_ref_roi = roi
						_p6_low_streak = 0
					elif _p6_ref_roi >= P6_DROP_HIGH and roi < P6_DROP_LOW:
						_p6_low_streak += 1
					if _p6_low_streak >= P6_N:
						_go(ST_RETARGET, "T7")
					else:
						_go(ST_PRESS, "T6")
				elif verdict == VERDICT_FAST:
					_go(ST_BANK, "T8")
		return

	# ---------------- new 模式 ----------------
	# B5：连续 3 次"差"→攒大波；中间出现"达成/好"→重置。
	if verdict == VERDICT_BAD:
		_bad_streak += 1
	elif verdict == VERDICT_ACHIEVED or verdict == VERDICT_BETTER:
		_bad_streak = 0
	match strat_state:
		ST_PROBE:
			if verdict == VERDICT_ACHIEVED or verdict == VERDICT_BETTER:
				_press_foe = String(rec.get("target_name", ""))
				_press_goal = _goal_from_rec(rec)
				_reset_switch()
				_go(ST_PRESS, "T1")
			elif verdict == VERDICT_BAD:
				if _bad_streak >= P3_FAST_STREAK:
					_go(ST_BANK, "T3")
				else:
					_request_switch("T2")
			elif verdict == VERDICT_FAIR:
				_request_switch("T4")
			else:
				strat_stats["N0"] = int(strat_stats.get("N0", 0)) + 1
		ST_PRESS:
			if verdict == VERDICT_ACHIEVED or verdict == VERDICT_BETTER:
				_press_goal = _goal_from_rec(rec)
				_reset_switch()
				_go(ST_PRESS, "T6")
			elif verdict == VERDICT_FAIR:
				_request_switch("T7")        # 出口 1
			elif verdict == VERDICT_BAD:
				if _bad_streak >= P3_FAST_STREAK:
					_go(ST_BANK, "T8")
				else:
					_request_switch("T2")    # 出口 2
			else:
				strat_stats["N0"] = int(strat_stats.get("N0", 0)) + 1


## 把一条波次记录里的目标还原成 goal 字典（加强时沿用同一个目标）
func _goal_from_rec(rec: Dictionary) -> Dictionary:
	return _goal_dict(String(rec.get("goal_type", "")),
		int(rec.get("goal_target_id", 0)),
		rec.get("goal_target_pos", rec.get("target", Vector3.ZERO)),
		String(rec.get("goal_name", "")),
		String(rec.get("target_name", "")))


## 每 tick 的"看局面"转移（T5/T9/T10/T11/T12/T12b/T13/T14）
func _tick_strategy(now: float) -> void:
	match strat_state:
		ST_PROBE, ST_PRESS:
			if not _has_target():
				_go(ST_RETARGET, "T5")
		ST_BANK:
			# T10（2C-4 用户覆盖）：**出兵建筑被摧毁** → 召回在外的部队（正在战斗的
			# 等打完再回），取消攒兵回试探。base_threat 的常规回防由 _manage_defense
			# 处理，不再触发 T10（任务书 §1 覆盖表）。
			if _producer_lost:
				_recall_outside_idle()
				_go(ST_PROBE, "T10")
				return
			# T9（2C-4）：当前可派战斗单位**总成本** ≥ 1.5 × 基准 → 打出去（不封顶）；
			# 或 90 s 到点**直接出击**（删 T11a/T11b 的"继续攒/转科技"分岔）。
			var avail_cost: float = _units_cost(_available_units())
			if bool(_model_call("bank_ready", [avail_cost, _bank_baseline_cost, BANK_MULT])) \
					or now - _state_since >= BANK_MAX_SEC:
				_go(ST_PRESS, "T9")
		ST_RETARGET:
			if now - _state_since >= T12_SEC:
				_go(ST_PROBE, "T12b")        # 10 s 选不出来 → 回试探
				return
			var f: RtsFaction = _pick_foe_excluding(_press_foe)
			if f != null:
				_press_foe = f.display_name
				# 2C-3：换目标同时换"打什么"（0.4 距离 + 0.4 威胁），不只是换一家
				_press_goal = _choose_goal(f, "bank")
				_go(ST_PROBE, "T12")



## 现在还有没有"能打的目标"（敌方有基地 = 有可打的建筑）
func _has_target() -> bool:
	var foe: RtsFaction = _foe_faction()
	return foe != null


## 换目标：除当前目标外，按"距离最近"取一家（§3.3 T12 的最简实现）
func _pick_foe_excluding(name: String) -> RtsFaction:
	var home: Vector3 = RtsWorld.base_center(_faction)
	var best: RtsFaction = null
	var best_d: float = INF
	for f in _war_foes():
		if f == null or String(f.display_name) == name:
			continue
		var d: float = home.distance_squared_to(RtsWorld.base_center(f))
		if d < best_d:
			best_d = d
			best = f
	return best


# ---------------------------------------------------------------------------
# 目标系统（2C-3 · A5）
#
# 五种规定目标：侦查区域 / 摧毁哨塔 / 摧毁分基地 / 摧毁箭塔 / 摧毁高威胁目标。
# 另加一个必要回退"摧毁主基地"：当前单位表没有独立的分基地建筑，
# 主基地又不能硬塞进"分基地"（语义会错），所以单列、报告里如实标注。
#
# 目标只决定"打哪里 / 什么算达成"，不改变下令通道（仍然只走 _sched）。
# ---------------------------------------------------------------------------

func _goal_dict(type: String, target_id: int, pos: Vector3, name: String,
		faction: String = "") -> Dictionary:
	return {"type": type, "target_id": target_id, "pos": pos,
		"name": name, "faction": faction}


## 建筑 → 目标类型（按 role / 是否是主基地分类，不写 id）
func _classify_building_goal(b: Node3D, d: UnitDef) -> String:
	if String(_model_call("role_of", [d])) == "defense":
		return GOAL_ARROW_TOWER if d.attack_damage > 0.0 else GOAL_TOWER
	if d.id == _main_base_id():
		return GOAL_BASE
	# 其余（伐木场/农场/兵营/圣地/车坊…）= 敌方外围/经济建筑。
	# 本作没有独立的"分基地"建筑，这里按规格的"分基地"语义映射到外围建筑。
	return GOAL_EXPANSION


## 候选目标：敌方全部建筑（按类型分类）+ 最近 60 s 的高威胁单位 + 一个侦查区域。
func _goal_candidates(foe: RtsFaction) -> Array:
	var out: Array = []
	if foe == null or _faction == null:
		return out
	var fname: String = foe.display_name
	for b in foe.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive():
			continue
		var d: UnitDef = b.get("def")
		if d == null:
			continue
		var gt: String = _classify_building_goal(b, d)
		out.append(_goal_dict(gt, b.get_instance_id(), b.global_position,
			"%s·%s" % [fname, d.display_name], fname))
	var ht: Dictionary = _high_threat_target()
	if not ht.is_empty():
		out.append(ht)
	# 侦查区域：敌方基地中心（"到达 + 停留 3 s"）。永远有一个，保证无建筑时也有目标。
	var base: Vector3 = RtsWorld.base_center(foe)
	out.append(_goal_dict(GOAL_SCOUT, 0, base, "%s·基地周边" % fname, fname))
	return out


## 高威胁目标：最近 60 s 对己方造成伤害最多的敌方单位/建筑。
func _high_threat_target() -> Dictionary:
	if _faction == null:
		return {}
	var now: float = Game.elapsed
	var agg: Dictionary = {}
	for e in _threat_ledger:
		if now - float(e["t"]) > THREAT_WINDOW:
			continue
		var id: int = int(e["id"])
		agg[id] = float(agg.get(id, 0.0)) + float(e["dmg"])
	var best_id: int = 0
	var best_dmg: float = 0.0
	for id in agg.keys():
		var dmg: float = float(agg[id])
		if dmg <= best_dmg:
			continue
		var n = instance_from_id(int(id))
		if n == null or not is_instance_valid(n) or not n.is_alive():
			continue
		if n.get("faction") == _faction:
			continue
		best_dmg = dmg
		best_id = int(id)
	if best_id == 0:
		return {}
	var node = instance_from_id(best_id)
	var d: UnitDef = node.get("def")
	var f = node.get("faction")
	return _goal_dict(GOAL_HIGH_THREAT, best_id, node.global_position,
		"高威胁·%s" % (d.display_name if d != null else "?"),
		String(f.display_name) if f != null else "")


## 每个敌对阵营最近 60 s 打了我多少（攒大波的"威胁分"）
func _threat_by_faction() -> Dictionary:
	var out: Dictionary = {}
	var now: float = Game.elapsed
	for e in _threat_ledger:
		if now - float(e["t"]) > THREAT_WINDOW:
			continue
		var k: String = String(e["faction"])
		out[k] = float(out.get(k, 0.0)) + float(e["dmg"])
	return out


## 选目标。
##   mode="nearest"：B1 初始目标 = **最近的可攻击敌方**（只在摧毁类里挑，
##                   不把"侦查"算成"最近"，否则第一波会变成观光）；
##   mode="bank"   ：B4 攒大波目标 = 0.4×距离分 + 0.4×威胁分（效果分留桩，恒 0）。
func _choose_goal(foe: RtsFaction, mode: String = "bank") -> Dictionary:
	var cands: Array = _goal_candidates(foe)
	if cands.is_empty():
		return {}
	var home: Vector3 = RtsWorld.base_center(_faction)
	if mode == "nearest":
		var best: Dictionary = {}
		var best_d: float = INF
		for c in cands:
			if String(c["type"]) == GOAL_SCOUT:
				continue
			var d: float = home.distance_squared_to(c["pos"])
			if d < best_d:
				best_d = d
				best = c
		if not best.is_empty():
			return best
		return cands[0]
	# 加权评分
	var max_d: float = 1.0
	for c in cands:
		max_d = maxf(max_d, sqrt(home.distance_squared_to(c["pos"])))
	var threat: Dictionary = _threat_by_faction()
	var max_t: float = 1.0
	for k in threat.keys():
		max_t = maxf(max_t, float(threat[k]))
	var best2: Dictionary = {}
	var best_s: float = -1.0
	for c in cands:
		var dist: float = sqrt(home.distance_squared_to(c["pos"]))
		var ds: float = 1.0 - clampf(dist / max_d, 0.0, 1.0)
		var ts: float = 0.0
		if String(c["type"]) == GOAL_HIGH_THREAT:
			ts = 1.0
		else:
			ts = clampf(float(threat.get(String(c["faction"]), 0.0)) / max_t, 0.0, 1.0)
		# 0.4 距离 + 0.4 威胁 + 0.2 效果分（留桩：需要记忆层，恒 0）
		var s: float = 0.4 * ds + 0.4 * ts
		if s > best_s:
			best_s = s
			best2 = c
	return best2


## 目标还活着吗（侦查目标 target_id=0，恒真）
func _goal_alive(goal: Dictionary) -> bool:
	var tid: int = int(goal.get("target_id", 0))
	if tid == 0:
		return not goal.is_empty()
	var n = instance_from_id(tid)
	return n != null and is_instance_valid(n) and n.is_alive()


## 攒大波期间：把人收回基地内圈，不出去送（T3/T8 的"停止小股出击"）
func _bank_hold() -> void:
	var home: Vector3 = RtsWorld.base_center(_faction)
	var moved: int = 0
	for u in _army_units():
		if u == null or not is_instance_valid(u):
			continue
		if u.global_position.distance_to(home) <= 10.0 and bool(u.call("is_idle_like")):
			continue
		var ang: float = _dhash01(hash(u.name), _wave_index * 53 + 7) * TAU
		_sched.move([u], home + Vector3(cos(ang) * 7.0, 0.0, sin(ang) * 7.0), "bank")
		moved += 1
	if moved > 0 and Game.elapsed - _last_block_log >= 25.0:
		_last_block_log = Game.elapsed
		_log("攒大波：%d 人回基地待命（门槛 %.0f 成本 / 基准 %.0f，超时 %ds 直接出击）"
			% [moved, _bank_baseline_cost * BANK_MULT, _bank_baseline_cost, int(BANK_MAX_SEC)])


## 成波推进（2C-2：由状态机决定"发不发 / 发多少 / 打谁"）。
##
## 试探（probe）：常态出击比例（0.75 floor，且不超过 军队数−防守下限）+ 侵略性骰子；
## 加强（press）：同一目标，间隔 ×0.75，人数仍走常态口径（保底留守不动）；
## 攒大波突围（T9 后第一波）：训练出来的**全部**战斗单位（含临时防守），只留保底 ceil(下限×2/3)；
## 攒大波（bank）：**不发小股**（T3/T8 的"停止小股出击"），只把人收回内圈；
## 换目标：本 tick 不出击。
##
## 出击前仍然先过战略导演的 `allow_attack`（家里挨打 / 计划说不打 → 不出门）。
##
## ★ 2C-9：拆成 `_wave_plan()`（判定，返回一份计划）与 `_issue_wave_plan()`（下令）。
##   **判定逻辑一个字没动**，只是把"算出来的东西"从局部变量变成一份可交给主部门仲裁的计划；
##   dept=off 时两段仍按原顺序连着调，行为与 2C-8 一致。
func _manage_waves(diff: DifficultyDef) -> void:
	var p: Dictionary = _wave_plan(diff)
	if p.is_empty():
		return
	_issue_wave_plan(p)


## 出击判定（**只读 + 只改时钟**，不下任何战斗命令）。
## 返回 {} = 本 tick 不出击；否则返回 {push_n, goal, foe, target, army_n, state}。
func _wave_plan(diff: DifficultyDef) -> Dictionary:
	if _faction == null:
		return {}
	_tick_strategy(Game.elapsed)
	if Game.elapsed < _next_wave_at:
		return {}
	if strat_state == ST_BANK:
		_bank_hold()
		_next_wave_at = Game.elapsed + 5.0
		return {}
	if strat_state == ST_RETARGET:
		return {}
	if not bool(posture.get("allow_attack", false)):
		# 不是"这一波取消"，而是"10 秒后再评估" —— 兵力一到位就会打出去
		_next_wave_at = Game.elapsed + 10.0
		if Game.elapsed - _last_block_log >= 25.0:
			_last_block_log = Game.elapsed
			_log("暂不出击：%s" % _block_reason())
		return {}
	var army: Array = _army_units()
	if army.size() < maxi(diff.min_wave_size, 3):
		return {}
	var aggr: float = float(posture.get("aggression", diff.aggression))
	# 加强不掷骰：上一波已经证明"打得动"，这时候犹豫等于把战果还回去
	if strat_state == ST_PROBE and randf() > clampf(aggr, 0.0, 1.0):
		return {}

	# --- 2C-4 出击比例（任务书 §4.2）---
	var defense_floor: int = _defense_floor()
	var push_n: int = 0
	var breakout: bool = strat_state == ST_PRESS and _bank_breakout
	if breakout:
		# 攒大波突围：全部战斗单位出击（含临时防守），保底 ceil(下限×2/3) 不低于
		push_n = int(_model_call("bank_push_n", [army.size(), defense_floor]))
	else:
		# 常态（试探/加强）：0.75 floor 且不超过 军队数−防守下限（保底留守不动）
		push_n = int(_model_call("normal_push_n", [army.size(), defense_floor]))
	push_n = clampi(push_n, 0, army.size())
	if push_n < 1:
		return {}
	var foe: RtsFaction = _press_foe_by_name() if strat_state == ST_PRESS else _foe_faction()
	if foe == null:
		foe = _foe_faction()
	# --- 2C-3 目标系统 ---
	# press：沿用上一波/攒大波选定的目标（"加强"要打同一个东西）；
	# 其它：首波按 B1 取最近可攻击敌方，之后按 B4 的 0.4 距离 + 0.4 威胁评分。
	var goal: Dictionary = {}
	if strat_state == ST_PRESS and not _press_goal.is_empty() and _goal_alive(_press_goal):
		goal = _press_goal
	if goal.is_empty():
		goal = _choose_goal(foe, "nearest" if _wave_index == 0 else "bank")
	if not goal.is_empty():
		_press_goal = goal
	var target: Vector3 = goal.get("pos", Vector3.ZERO) if not goal.is_empty() else _target_for(foe)
	if target == Vector3.ZERO:
		return {}
	# T2"换小股路线"：每次快速被消灭后换一个接近角，别用同一条路再送一次
	if strat_state == ST_PROBE and _probe_seq > 0:
		var ang0: float = _dhash01(_probe_seq, 17) * TAU
		target += Vector3(cos(ang0), 0.0, sin(ang0)) * 8.0
	return {
		"push_n": push_n,
		"goal": goal,
		"foe": foe,
		"target": target,
		"army_n": army.size(),
		"state": strat_state,
		"goal_name": String(goal.get("name", "?")),
		"breakout": breakout,
	}


## 真的把一波发出去（原 `_manage_waves` 的后半段，一行未改）。
func _issue_wave_plan(p: Dictionary) -> bool:
	var push_n: int = int(p.get("push_n", 0))
	var army: Array = _army_units()
	if push_n < 1 or push_n > army.size():
		return false
	# 攒大波突围标记在**真的发出去**之后才消费（计划被驳回时不丢这个状态）
	if bool(p.get("breakout", false)):
		_bank_breakout = false
	var target: Vector3 = p.get("target", Vector3.ZERO)
	var foe = p.get("foe", null)
	var goal: Dictionary = p.get("goal", {})
	var targets: Array = _scatter_targets(army.slice(0, push_n), target)
	var home: Vector3 = RtsWorld.base_center(_faction)
	var sent: Array = []
	for i in range(army.size()):
		var u: RtsUnit = army[i]
		if u == null or not is_instance_valid(u):
			continue
		if i < push_n:
			_sched.attack_move([u], targets[i], "wave")
			sent.append(u)
		else:
			# 留守的人散在基地外圈，别全站在大本营里堵路。
			# 同样是"纯散开" → 确定性伪随机，不消费全局流（见 _dhash01）。
			var ang: float = _dhash01(hash(u.name), _wave_index * 31 + 11) * TAU
			_sched.move([u], home + Vector3(cos(ang) * 16.0, 0.0, sin(ang) * 16.0), "wave")

	# ★ 记录表在这里开（`_open_wave` 里自增 `_wave_index`，所以日志与记录同号）
	_open_wave(sent, target, foe, goal)
	# C 模式的衰减时钟在这里归零：**真的打出去了**才算"成功出击"。
	_last_attack_t = Game.elapsed
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	var interval: float = maxf(
		diff.wave_interval - diff.wave_interval_decay * float(_wave_index),
		diff.wave_interval_min)
	if strat_state == ST_PRESS:
		interval *= 0.75
	_next_wave_at = Game.elapsed + interval
	_log("第 %d 波[%s]：%d 出击 / %d 留守 → %s·%s（下一波 +%.0fs）" % [
		_wave_index, strat_state, push_n, army.size() - push_n,
		_foe_name(), String(goal.get("name", "?")), interval])
	return true


## 按名字找我打的那一家（加强时用；找不到就退回最近的一家）
func _press_foe_by_name() -> RtsFaction:
	if _press_foe.is_empty():
		return null
	for f in _war_foes():
		if f != null and String(f.display_name) == _press_foe:
			return f
	return null


# ===========================================================================
# 昼夜行为（2026-11-01 玩家口径）
#   白天：出门打敌对玩家 + 清野怪营地
#   夜里：守家（不主动出门）、造营火、农民采木
# ===========================================================================

## 夜间收队的间隔（秒）
const NIGHT_RECALL_INTERVAL := 6.0
## 清野怪的间隔（秒）：不要太频繁，否则部队一直在野区转圈
const CREEP_CLEAR_INTERVAL := 40.0
## 派出清野的兵力比例
const CREEP_CLEAR_RATIO := 0.4
## 野怪营地被判定为"值得打"的最大距离（米，从我的基地算）
const CREEP_CLEAR_RANGE := 95.0
## 开局多久之内不去招惹野怪（秒）：刚开局 3 个兵去打 4 只豺狼人 = 送经验
const CREEP_CLEAR_AFTER := 45.0
## 哨塔目标座数：随时间长大（1 → 3），但封顶 3
const WATCHTOWER_MAX := 3
## 箭塔（含升级来的）总上限：给"升级→补哨塔"的循环封顶
const MAX_ARROW_TOWERS := 4
## 每隔多少秒允许再想要一座哨塔
const WATCHTOWER_GROW_SEC := 95.0
## 营火上限定
const CAMPFIRE_MAX := 2

var _night_cd: float = 0.0
var _creep_cd: float = 0.0
var _upgrade_cd: float = 0.0
## 改造脚本（preload 常量，不依赖全局类缓存）
const REFIT := preload("res://代码/系统/建筑改造.gd")


## **夜里**：把散在外面的兵收回基地内圈，蹲在防御圈上等它们撞上来。
##
## 为什么不是"全体 hold"：hold 会把兵钉在原地，敌人绕后打农场它们不动。
## 这里用 `attack_move` 到基地外圈的一个点 —— 路上遇到敌人自动交战，
## 到了之后原地警戒，本质就是"在家门口巡逻"。
func _manage_night(_diff: DifficultyDef) -> void:
	if _faction == null:
		return
	if _night_cd > 0.0:
		_night_cd -= float(_diff.think_interval * think_scale)
		return
	_night_cd = NIGHT_RECALL_INTERVAL
	_night_seq += 1
	var home: Vector3 = RtsWorld.base_center(_faction)
	var moved: int = 0
	for u in _army_units():
		if u == null or not is_instance_valid(u):
			continue
		# 已经在家里圈内就别折腾它（不然每 6 秒重下一次命令，兵一直原地踏步）
		if u.global_position.distance_to(home) <= DEFENSE_RADIUS + 6.0:
			continue
		var ang: float = _dhash01(hash(u.name), _night_seq * 37 + 5) * TAU
		var p: Vector3 = home + Vector3(cos(ang), 0.0, sin(ang)) * (DEFENSE_RADIUS * 0.8)
		_sched.attack_move([u], p, "night")
		moved += 1
	if moved > 0:
		_log("入夜收队：%d 兵回防（基地 %.0fm 圈）" % [moved, DEFENSE_RADIUS])


## **白天清野**：派一支小队去最近的野怪营地练手。
##
## 三条硬条件（缺一条都不派）：
##   ① 家里没被打（base_threat == 0）；
##   ② 兵力 ≥ 3（1~2 个兵去打营地等于送经验）；
##   ③ 营地离基地 ≤ CREEP_CLEAR_RANGE（太远就成了"全军远征"，正面战场就空了）。
func _manage_creep_clear(_diff: DifficultyDef) -> void:
	if _faction == null:
		return
	if _creep_cd > 0.0:
		_creep_cd -= float(_diff.think_interval * think_scale)
		return
	if float(metrics.get("base_threat", 0.0)) > 0.0:
		return
	var camp: Vector3 = _nearest_creep_camp()
	if camp == Vector3.INF:
		return
	if Game.elapsed < CREEP_CLEAR_AFTER:
		return
	var army: Array = _army_units()
	# 兵力门槛：副官会用更高的值（那是玩家的兵，不能拿去白白送死）
	if army.size() < creep_clear_min_army:
		return
	_creep_cd = CREEP_CLEAR_INTERVAL
	var n: int = clampi(int(ceil(float(army.size()) * CREEP_CLEAR_RATIO)), 3, army.size())
	var targets: Array = _scatter_targets(army.slice(0, n), camp)
	for i in range(n):
		_sched.attack_move([army[i]], targets[i], "creep")
	_log("清野：%d 兵 → 营地 (%.0f, %.0f)" % [n, camp.x, camp.z])


## 最近的野怪营地：优先营地里的建筑（如果有），没有就找最近的野怪本身。
## 返回 Vector3.INF = 附近没有值得打的野怪。
func _nearest_creep_camp() -> Vector3:
	var neutral: RtsFaction = Game.neutral_faction
	if neutral == null:
		return Vector3.INF
	var home: Vector3 = RtsWorld.base_center(_faction)
	var best: Vector3 = Vector3.INF
	var best_d: float = CREEP_CLEAR_RANGE
	for b in neutral.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive():
			continue
		var d: float = b.global_position.distance_to(home)
		if d < best_d:
			best_d = d
			best = b.global_position
	if best != Vector3.INF:
		return best
	for u in neutral.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		var d2: float = u.global_position.distance_to(home)
		if d2 < best_d:
			best_d = d2
			best = u.global_position
	return best


## **日常 upkeep**：哨塔（扩视野）→ 多余哨塔升级箭塔 → 营火（夜里照明）。
##
## 顺序是有讲究的：先有哨塔才谈得上"升级多余的那几座"；
## 营火放最后 —— 它是纯功能性的照明，不能跟"能打的塔"抢资源。
## 2C-5：修理插在最前（优先级第 3 位：农(急) > 兵营 > **修理** > 哨塔 > 农(缓)）；
## 它比哨塔优先的理由是"已有的楼正在掉血"，而哨塔是"多一双眼睛"。
func _manage_upkeep(diff: DifficultyDef) -> void:
	_manage_repair()
	_maybe_build_watchtower(diff)
	_maybe_upgrade_tower()
	_maybe_build_campfire()


## 哨塔：**朝敌方方向**推到基地外圈，目的是"提前看见有人来"。
## 目标座数随时间长大（1 → 3），这样前期不浪费钱，后期基地有预警圈。
func _maybe_build_watchtower(diff: DifficultyDef) -> void:
	if _faction == null:
		return
	# 目标**哨塔**数（只数哨塔，不数箭塔）：升级掉一座哨塔之后这里会空出名额，
	# 于是 AI 会再补一座 —— 这正是玩家描述的"造哨塔扩视野、多出来的转成箭塔"。
	var want: int = clampi(1 + int(Game.elapsed / WATCHTOWER_GROW_SEC), 1, WATCHTOWER_MAX)
	var wid: StringName = _watchtower_id()
	if wid == &"":
		return
	var tid: StringName = _tower_id()
	var have: int = _faction.count_buildings(wid)
	# 总防御建筑上限：防止"升级→补哨塔→再升级"无限循环把钱烧光
	if have >= want or (tid != &"" and _faction.count_buildings(tid) >= MAX_ARROW_TOWERS):
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != wid:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and not rb.is_constructed:
			return
	var d: UnitDef = Cfg.unit(wid)
	if d == null or not _can_spend(wid):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _frontier_spot(d.footprint, 24.0, 34.0)
	if spot == Vector3.INF:
		spot = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, d, spot, _build_yaw_at(spot), "defense") != null:
		_log("造哨塔扩视野（已有 %d / 目标 %d）" % [have, want])


## "朝敌方的外圈"选点：从基地沿"我方→最近敌人"方向走 24~34m，找第一个可建点。
## 找不到就退到通用的 `_find_build_spot`（环形搜索）。
func _frontier_spot(footprint: Vector2i, r_min: float, r_max: float) -> Vector3:
	if _faction == null:
		return Vector3.INF
	var home: Vector3 = RtsWorld.base_center(_faction)
	var dir := Vector3.FORWARD
	var foe: RtsFaction = _foe_faction()
	if foe != null:
		var to: Vector3 = RtsWorld.base_center(foe) - home
		to.y = 0.0
		if to.length() > 1.0:
			dir = to.normalized()
	var r: float = r_min
	while r <= r_max:
		for sgn in [0.0, 0.5, -0.5]:
			var ang: float = atan2(dir.x, dir.z) + float(sgn)
			var raw := Vector3(home.x + sin(ang) * r, 0.0, home.z + cos(ang) * r)
			var p: Vector3 = 建筑网格.snap_point(raw, footprint)
			if 建筑网格.can_place(p, footprint) and _has_room(p, footprint):
				return p
		r += 3.0
	return Vector3.INF


## **多余哨塔 → 箭塔**（玩家口径："多余哨塔升级箭塔加强防御"）。
##
## 判定"多余"：哨塔数 > 当前想要的数量（want 见 _maybe_build_watchtower）。
## 也就是"该有的预警点已经够了，剩下的全转成火力"。
## 夜里更积极：夜幕期守家靠的就是塔。
func _maybe_upgrade_tower() -> void:
	if _faction == null:
		return
	if _upgrade_cd > 0.0:
		_upgrade_cd -= 1.0
		return
	# 要**留几座哨塔**当眼睛：至少 1 座，随时间抬到 2 座。
	# 只有"超过这个数"的哨塔才算多余，才转成箭塔 —— 否则开局唯一那座一升级，
	# 基地就彻底没有 20m 视野了（玩家口径："造哨塔扩大视野"）。
	var prefer: int = clampi(1 + int(Game.elapsed / (WATCHTOWER_GROW_SEC * 2.0)), 1, 2)
	if Game.is_night():
		# 夜里守家靠火力，但仍然至少留 1 座哨塔（预警 26m 是夜里最值钱的东西）
		prefer = maxi(1, prefer - 1)
	var old_id: StringName = _watchtower_id()
	var new_id: StringName = _tower_id()
	if old_id == &"" or new_id == &"":
		return
	var towers: Array = []
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != old_id:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not rb.is_constructed or not rb.is_alive():
			continue
		towers.append(rb)
	if towers.size() <= prefer:
		return
	if _faction.count_buildings(new_id) >= MAX_ARROW_TOWERS:
		return
	# 已经有塔在升级：等它读完（升级现在是**读条**，不是瞬变）
	for t in towers:
		if t.is_upgrading():
			return
	# 挑"最靠外"的那座升级（越靠前越先挨打，最需要火力）
	var pick: RtsBuilding = towers[0]
	var home: Vector3 = RtsWorld.base_center(_faction)
	for t in towers:
		if t.global_position.distance_to(home) > pick.global_position.distance_to(home):
			pick = t
	# ★ 走 建筑改造.start：校验 + 扣差价 + 进读条，和玩家命令卡同一个入口。
	#   读满由建筑自己 replace —— AI 不再"一瞬间换一座塔"。
	if not REFIT.start(pick, new_id):
		return
	_upgrade_cd = 12.0
	_log("哨塔开始升级箭塔 @ (%.0f, %.0f)（%.0f 秒，哨塔 %d 座，目标 %d）" % [
		pick.global_position.x, pick.global_position.z,
		RtsBuilding.upgrade_time_for(new_id), towers.size(), prefer])


## **大本营能不能建（2C-6 P4，扩张线预留接口）**：**固定 false**。
##
## 用户口径：大本营现在**有成本**（320 金 / 125 木）且玩家能建（建造页第 10 个按钮），
## 但 AI **本轮不自动建** —— 多基地会牵动资源点选择、防守下限（5+2×基地数）、
## 分矿扩张顺序，那是下一轮"扩张线"的活。先把这个判断收成一个函数，
## 下一轮接扩张线时只改这里 + 加一个 `_maybe_build_townhall()` 调用点，
## 不会散落在建造逻辑里各写一份。
##
## ★ 不许为了让 AI "看起来会扩张"把它改成 true —— 那会立刻开始拿 320 金砸第二基地，
##   而这轮的农田/兵营/修理预算都按"单基地"标定过。
func can_build_townhall() -> bool:
	return false


## **扩张线（2C-4 §4.4，只留接口 + 最小可用）**：
## 触发 = 农民到总上限（软上限+4）且木材足够 → 派 1 个农民建 1 座哨塔 → **停**
##（不接入新矿区，完整扩张不在本轮）。农民去向的 "expand" 枚举 = 建造期间的
## 建造命令（label "expand"），建造农民平常照常采集（_pick_builder 优先闲着的）。
func _maybe_expand() -> void:
	if _expand_state != 0 or _faction == null:
		return
	if _workers().size() < PEASANT_TOTAL_CAP:
		return
	var wid: StringName = _watchtower_id()
	if wid == &"":
		return
	var wd: UnitDef = Cfg.unit(wid)
	if wd == null:
		return
	# 木材也够（留 40 木 buffer，别把修理/农场的木头花光）
	if _faction.wood < wd.wood_cost + 40:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id == wid:
			var rb: RtsBuilding = b as RtsBuilding
			if rb != null and not rb.is_constructed:
				return
	if not _can_spend(wid):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _expand_spot(wd.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, wd, spot, _build_yaw_at(spot), "expand") != null:
		_expand_state = 2
		_log("扩张线：派农民建哨塔 @ (%.0f, %.0f)（最小可用：建完即停，不接新矿）"
			% [spot.x, spot.z])


## 扩张选点 = §3.5 三因子（控制区边缘 + 最近战斗 + 地图中心）。
## 候选：基地外圈 24~34m 环采样；评分 = 0.4×离最近己方建筑（推视野/控制区边缘）
## + 0.4×离 60s 威胁账本质心（最近战斗的位置值得插眼）+ 0.2×朝地图中心。
func _expand_spot(footprint: Vector2i) -> Vector3:
	if _faction == null:
		return Vector3.INF
	var home: Vector3 = RtsWorld.base_center(_faction)
	var map_center := Vector3(Cfg.game.map_size * 0.5, 0.0, Cfg.game.map_size * 0.5)
	# 最近战斗：60s 威胁账本的位置质心（没有就退化为朝地图中心方向）
	var battle := Vector3.INF
	var n: int = 0
	for e in _threat_ledger:
		var nd = instance_from_id(int(e["id"]))
		if nd == null or not is_instance_valid(nd) or not nd.is_alive():
			continue
		var pos: Vector3 = nd.global_position
		battle = pos if n == 0 else battle + pos
		n += 1
	if n > 0:
		battle = battle / float(n)
	var best: Vector3 = Vector3.INF
	var best_s: float = -1.0
	var r: float = 24.0
	var cands: Array = []
	while r <= 34.0:
		for i in range(12):
			var ang: float = TAU * float(i) / 12.0
			var raw := Vector3(home.x + cos(ang) * r, 0.0, home.z + sin(ang) * r)
			var p: Vector3 = 建筑网格.snap_point(raw, footprint)
			if 建筑网格.can_place(p, footprint) and _has_room(p, footprint):
				cands.append(p)
		r += 3.0
	for p in cands:
		var edge_nearest: float = INF
		for b in _faction.buildings:
			if b == null or not is_instance_valid(b) or not b.is_alive():
				continue
			edge_nearest = minf(edge_nearest, p.distance_to(b.global_position))
		var edge_s: float = clampf(edge_nearest / 30.0, 0.0, 1.0)
		var battle_s: float = 0.5
		if battle != Vector3.INF:
			battle_s = 1.0 - clampf(p.distance_to(battle) / 60.0, 0.0, 1.0)
		var center_s: float = 1.0 - clampf(p.distance_to(map_center) / float(Cfg.game.map_size), 0.0, 1.0)
		var s: float = 0.4 * edge_s + 0.4 * battle_s + 0.2 * center_s
		if s > best_s:
			best_s = s
			best = p
	return best


## 营火：**只在夜里考虑**，最多 CAMPFIRE_MAX 座，摆在基地朝敌方的一侧。
## 玩家口径："并会建造营火，在夜晚能看清（让火在晚上能照明）"。
func _maybe_build_campfire() -> void:
	if _faction == null or not Game.is_night():
		return
	var cid: StringName = _campfire_id()
	if cid == &"":
		return
	if _faction.count_buildings(cid) >= CAMPFIRE_MAX:
		return
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id == cid:
			var rb: RtsBuilding = b as RtsBuilding
			if rb != null and not rb.is_constructed:
				return
	var d: UnitDef = Cfg.unit(cid)
	if d == null or not _can_spend(cid):
		return
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return
	var spot: Vector3 = _frontier_spot(d.footprint, 10.0, 16.0)
	if spot == Vector3.INF:
		spot = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return
	if _sched.build(builder, d, spot, _build_yaw_at(spot), "night") != null:
		_log("夜里点营火（已有 %d 座）" % _faction.count_buildings(cid))


## 把一队人散到一个圆盘上（黄金角螺旋，间距约 2m）。
## 为什么用螺旋而不是方阵：方阵要么朝向不对、要么在野外根本放不下；
## 螺旋只依赖"到目标的距离"，任何地形都能落下，而且天然不重叠。
func _scatter_targets(units: Array, center: Vector3) -> Array:
	var out: Array = []
	var pf: GridPathfinder = RtsWorld.pathfinder()
	var n: int = units.size()
	for i in range(n):
		var ang: float = float(i) * 2.39996323
		var r: float = 0.8 + 1.9 * sqrt(float(i))
		var q := Vector3(center.x + cos(ang) * r, 0.0, center.z + sin(ang) * r)
		if pf != null:
			q = pf.standable_point(q, 0.5, 0.15)
		out.append(RtsWorld.snap_y(q))
	return out

## 进攻落点：**优先离我方最近的那座敌方建筑**，没有就扑敌方基地中心。
## 以前只会打基地中心 —— 部队从一堆防守兵中间穿过，等于白送。
func _push_target() -> Vector3:
	return _target_for(_foe_faction())


## 指定那一家 foe 的进攻落点（"加强"要打同一家，不能每波重新挑最近的）
func _target_for(foe: RtsFaction) -> Vector3:
	if foe == null or _faction == null:
		return Vector3.ZERO
	var origin: Vector3 = RtsWorld.base_center(_faction)
	var best: Vector3 = RtsWorld.base_center(foe)
	var best_d: float = INF
	for b in foe.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if not b.is_alive():
			continue
		var d: float = b.global_position.distance_to(origin)
		if d < best_d:
			best_d = d
			best = b.global_position
	return best

# ===========================================================================
# 查询辅助
# ===========================================================================

## 我打的那一家：**最近的、还有大本营的敌对阵营**（同样不含野怪）。
## （多队图里"敌人"可能有 2~3 个；全量目标选择见 _all_foes()。）
func _foe_faction() -> RtsFaction:
	if _faction == null:
		return null
	var pool: Array = _war_foes()
	if pool.is_empty():
		return null
	var mine: Vector3 = RtsWorld.base_center(_faction)
	var best: RtsFaction = pool[0]
	var best_d: float = INF
	for f in pool:
		var d: float = mine.distance_squared_to(RtsWorld.base_center(f))
		if d < best_d:
			best_d = d
			best = f
	return best


## 最能打的那个敌对阵营（按"活着的战斗单位数"排）。
## 战略层的对手口径：不打野怪、也不把三家求和（理由见 `_enemy_army()`）。
func _strongest_foe() -> RtsFaction:
	var best: RtsFaction = null
	var best_n: int = -1
	for f in _war_foes():
		if f == null:
			continue
		var n: int = _combat_units_of(f).size()
		if n > best_n:
			best_n = n
			best = f
	return best


## **会"打过来"的敌对阵营** —— 战略层口径，**剔除中立野怪**。
##
## 为什么必须分开：野怪有 8 片营地、每片 5 只，数量上远超任何一家玩家。
## 把它们算进"敌方军力/最想打的那一家"，AI 就会：
##   ① 永远觉得兵力不占优（`allow_attack` 永远 false）→ 整局不出门；
##   ② 把推进目标定成最近的野怪（`_push_target` 找"敌方建筑"）→ 全军去打野。
## 但**战术层**（索敌 `_acquire`、回防 `_threat_units`）仍然把野怪当敌人 ——
## 夜里它们真的会来拆家，那时候必须开枪。
func _war_foes() -> Array:
	var out: Array = []
	for f in _all_foes():
		if f == null:
			continue
		# team 0 = 中立敌对（野怪）。1 队是盟友，压根不在 enemies_of 里。
		if int(f.team) == 0:
			continue
		out.append(f)
	return out


## 全部敌对阵营（含中立野怪；一波兵打过去时要挑目标用）
func _all_foes() -> Array:
	if _faction == null:
		return []
	var pool: Array = Game.living_enemies_of(_faction)
	if pool.is_empty():
		pool = Game.enemies_of(_faction)
	return pool

func _foe_name() -> String:
	var f: RtsFaction = _foe_faction()
	return f.display_name if f != null else "敌方"

## 按 id 找第一座活着的**已完工**建筑
func _first_building(id: StringName) -> RtsBuilding:
	if _faction == null:
		return null
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b):
			continue
		if not b.is_alive() or b.def == null:
			continue
		if b.def.id != id:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and rb.is_constructed:
			return rb
	return null

# ===========================================================================
# 2C-9 · 三条线部门化 + 主部门动作级仲裁（dept=on）
#
# 结构（不是参数）：
#   ① 每 tick：L0 快照覆盖写 + L1 环形槽滚动 + 后台采集派工（不仲裁）
#   ② 每 2 s：三条线各自报诉求（L2 全量重建）→ 主部门按诉求分排序 → 依次扣减/锁定
#   ③ 执行按**仲裁后的顺序**，不按部门顺序；每一块的判定条件复用 2C-8 原函数
#   ④ 每 2 s 一行 L3 决策日志落盘（只落盘，不进决策）
#
# 三条线的职责边界（用户拍板，见设计文档 §3.19）：
#   运营线 —— 训练（农民/战斗单位）、建造（农场/兵营/哨塔/营火/科技建筑）、修理
#   战斗线 —— 出击（"判定→攒波→换目标→出击"闭环**原样复用**）、防守
#   扩展线 —— 侦查、巡逻、建塔（箭塔）、建分基地（`can_build_townhall()` 仍 false）
# ===========================================================================

## 造一条诉求（与本文件外的 `战斗模型.demand_make` **同一套字段**；回归会比对键集）。
## 为什么不直接 call demand_make：11 个参数超过 `_model_call` 的逐个展开分支，
## 落到 `callv` 会踩 Godot 4 对 static 函数的已知坑（见 `_model_call` 注释）。
func _demand(source: String, action: String, target: String,
		gold: int, wood: int, troops: int, requis: bool,
		score: float, basis: String, ready: bool, exec: Callable) -> Dictionary:
	return {
		"来源线": source,
		"动作类型": action,
		"目标": target,
		"金币成本": maxi(gold, 0),
		"木材成本": maxi(wood, 0),
		"兵力占用": maxi(troops, 0),
		"可被征用": requis,
		"诉求分": score,
		"依据": basis,
		"驳回原因": "",
		"可执行": ready,
		"执行": exec,
	}


# ---------------------------------------------------------------------------
# 2C-11 §3 · 紧急白名单（3 枚举，命中任一即紧急）
#
# 纯判定住在 战斗模型.urgent_reasons；这里只负责「把场景状态取成 6 个标量」
# 和「最近 60 s 被拆建筑账本」。不新增归因结构，计数复用 dept_stats。
# ---------------------------------------------------------------------------

## 被拆账本：每次思考扫一次建筑 id 集合，消失的记时刻，清掉 60 s 前的记录。
## 首次调用只建基线，不把开局建筑误记成「被拆」。
func _track_building_losses(now: float) -> void:
	if _faction == null:
		return
	var alive: Dictionary = {}
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if not b.is_alive():
			continue
		alive[int(b.get_instance_id())] = true
	if not _known_buildings.is_empty():
		for k in _known_buildings.keys():
			if not alive.has(k):
				_lost_building_t.append(now)
	_known_buildings = alive
	var cutoff: float = now - URG_LOST_WINDOW_SEC
	while not _lost_building_t.is_empty() and float(_lost_building_t[0]) < cutoff:
		_lost_building_t.remove_at(0)


## 本周期的紧急事由（空数组 = 不紧急）。
##   pop_rate 含在训人口（与 2C-10 pop_pressure 同口径）；
##   has_farm_site 用现有 _has_site_of（未完工农场工地）；
##   lost_n 由 _track_building_losses 的 60 s 窗口给出；
##   under_attack 用现有 _under_attack()（任一建筑掉血）。
func _saving_urgency() -> Array:
	if _faction == null:
		return []
	var cap: int = _faction.food_cap()
	var rate: float = 0.0
	if cap > 0:
		var used_sum: int = maxi(_faction.food_used(), 0) + maxi(_faction.food_reserved(), 0)
		rate = float(used_sum) / float(cap)
	var fid: StringName = _food_building_id()
	var has_site: bool = fid != &"" and _has_site_of(fid)
	var army_n: int = _army_units().size()
	var floor_v: int = _defense_floor()
	var lost_n: int = _lost_building_t.size()
	var attacked: bool = _under_attack()
	return _model_call("urgent_reasons",
			[rate, has_site, army_n, floor_v, lost_n, attacked])


# ---------------------------------------------------------------------------
# 2C-11 §4 · 建造停滞恢复（独立行为，不走仲裁）
#
# 每 5 s 扫一次全部未完工工地（不是每帧）；连续 20 s 无农民施工判停滞，
# 派工位接续建造（优先级高于新工地）。不设上限、不受储备线约束。
# 归因复用 2C-8 的 repair_stats["blocked_builder_busy"]，不新增归因结构；
# P2 只需在 dept_stats 里记「停滞数 / 成功接续数」两个计数。
# ---------------------------------------------------------------------------
func _site_recovery_tick(now: float) -> void:
	if _faction == null:
		return
	var sites: Array = []
	var alive_ids: Dictionary = {}
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if not b.is_alive():
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or rb.is_constructed:
			continue
		sites.append(rb)
		alive_ids[int(rb.get_instance_id())] = true
	# 有工位正在它上面施工 → 刷新时间戳；首次见到的工地先建基线（不立刻判停滞）
	var builders: Array = _builder_units()
	for s in sites:
		var sid: int = s.get_instance_id()
		var worked: bool = false
		for u in builders:
			if u == null or not is_instance_valid(u):
				continue
			if int(u.order) != RtsConst.Order.BUILD:
				continue
			var bs: Node3D = u.get("_build_site") as Node3D
			if bs != null and is_instance_valid(bs) and bs.get_instance_id() == sid:
				worked = true
				break
		if worked:
			_site_last_work[sid] = now
		elif not _site_last_work.has(sid):
			_site_last_work[sid] = now
	# 清掉已完工 / 已拆工地的记录，避免字典无限长
	for k in _site_last_work.keys():
		if not alive_ids.has(k):
			_site_last_work.erase(k)
	# 停滞 → 直接派工接续（不走仲裁、不占额度、不看储备线）
	for s2 in sites:
		var sid2: int = s2.get_instance_id()
		var last_t: float = float(_site_last_work.get(sid2, now))
		if not bool(_model_call("site_is_stalled", [now, last_t])):
			continue
		dept_stats["site_stall_detected"] = int(dept_stats["site_stall_detected"]) + 1
		var builder: RtsUnit = _pick_sanity_builder()
		if builder == null or not builder.has_method("order_build_site"):
			repair_stats["blocked_builder_busy"] = int(repair_stats["blocked_builder_busy"]) + 1
			continue
		if bool(builder.call("order_build_site", s2)):
			dept_stats["site_recovery_issued"] = int(dept_stats["site_recovery_issued"]) + 1
			_site_last_work[sid2] = now   # 派工后计时清零
		else:
			repair_stats["blocked_builder_busy"] = int(repair_stats["blocked_builder_busy"]) + 1


## 2C-12 §2.1：假待办账本。本周期**执行了**的目标 → 清零（曾经执行过就不算假）；
## 被驳回且金币成本 > 0 的目标 → 连续未执行周期数 +1。
## 只服务 `typical_unit_cost_median`，不进任何决策。
func _saving_note_stall(plan: Dictionary) -> void:
	var done_t: Dictionary = {}
	for d in (plan.get("执行", []) as Array):
		if d is Dictionary:
			done_t[String((d as Dictionary).get("目标", ""))] = true
	for k in done_t.keys():
		_saving_stall.erase(k)
	for d2 in (plan.get("驳回", []) as Array):
		if not (d2 is Dictionary):
			continue
		var t: String = String((d2 as Dictionary).get("目标", ""))
		if t.is_empty() or done_t.has(t):
			continue
		if int((d2 as Dictionary).get("金币成本", 0)) <= 0:
			continue
		_saving_stall[t] = int(_saving_stall.get(t, 0)) + 1


# ---------------------------------------------------------------------------
# 2C-12 §3 · 承诺表（占位机制，只对金币）
#
# 一张表，不新建层：key = "动作|目标" → 7 字段承诺（战斗模型.promise_make）。
# 生命周期全部在这里：生成（部门提案）→ 执行中 → 已执行（删除）；
# 或 过期 / 被抢占 / 目标已满足（释放回可自由资源）。每周期扫描，不允许泄漏。
# ---------------------------------------------------------------------------

## 每 2 s 仲裁周期调一次（只在 _dept_tick 的节拍里，不是每帧）。
func _promise_tick(now: float, diff: DifficultyDef, urgent: bool) -> void:
	if not AIV.promise_on():
		# promise=off：完全回到 2C-11（没有承诺表 → 可自由资源只有 金币 − G(t)）
		if not _promise.is_empty():
			_promise.clear()
		return
	if _faction == null:
		return
	# ① 过期扫描（「有效」和「执行中」都被 TTL 兜住 → 不会跨周期泄漏）
	var scan: Dictionary = _model_call("promise_expire", [_promise, now])
	_promise = scan["存活"]
	dept_stats["promise_expired"] = int(dept_stats["promise_expired"]) \
			+ (scan["过期"] as Array).size()
	# ② 目标已满足 → 承诺作废（不是泄漏：目的已达成，钱该回公共池）。
	#    ★ 判据必须与 §3.3 的**生成条件逐条对应**，否则会来回打转：
	#      农场是"可多座"建筑，不能用 count_buildings>=1 当达成（2C-12 首版踩过：
	#      生成 164 / 作废 160 / 执行 2，全是"已有一座农场"被当成"目标已达成"）。
	for k in _promise.keys():
		var tgt: String = String((_promise[k] as Dictionary).get("目标", ""))
		if _promise_target_done(tgt, diff):
			_promise.erase(k)
			dept_stats["promise_dropped_target_done"] = \
					int(dept_stats["promise_dropped_target_done"]) + 1
	# ③ 紧急抢占（只抢「有效」，不抢「执行中」—— 后者已经动钱）
	var pp: Dictionary = _model_call("promise_preempt", [_promise, urgent])
	_promise = pp["存活"]
	dept_stats["promise_preempted"] = int(dept_stats["promise_preempted"]) \
			+ (pp["被抢占"] as Array).size()
	# ④ 生成（"已有同类有效承诺则跳过"在 _promise_add 里判）
	_promise_spawn(now, diff)


## 承诺的"目标已满足"判据 —— **必须与 _promise_spawn 的生成条件逐条对应**。
##   农场：有工地，或者已经不再需要（不急也不想要）→ 达成
##   兵营：有工地，或者座数已经够 → 达成
##   分基地：已建成 2 座 → 达成
## 不这么写就会退化成「生成→下一周期作废→再生成」的空转（首版实测 164/160/2）。
func _promise_target_done(disp: String, diff: DifficultyDef) -> bool:
	if disp.is_empty():
		return false
	var fid: StringName = _food_building_id()
	if fid != &"":
		var fd: UnitDef = Cfg.unit(fid)
		if fd != null and String(fd.display_name) == disp:
			if _has_site_of(fid):
				return true
			return not (_farm_urgent() or _farm_wanted(diff))
	var pid: StringName = _primary_producer_id(diff)
	if pid != &"":
		var bd: UnitDef = Cfg.unit(pid)
		if bd != null and String(bd.display_name) == disp:
			return _has_site_of(pid) or _faction.count_buildings(pid) >= _barracks_want()
	var hid: StringName = _main_base_id()
	if hid != &"":
		var hd: UnitDef = Cfg.unit(hid)
		if hd != null and String(hd.display_name) == disp:
			return _faction.count_buildings(hid) >= 2
	return false


## 生成三条（任务书 §3.3）。
func _promise_spawn(now: float, diff: DifficultyDef) -> void:
	# ① 运营线·农场：人口占用率（含在训）> 85% 且农场缺口 > 0 且无农场工地
	var fid: StringName = _food_building_id()
	var farm_disp: String = ""
	if fid != &"":
		var fd: UnitDef = Cfg.unit(fid)
		if fd != null:
			farm_disp = String(fd.display_name)
			var cap: int = _faction.food_cap()
			var rate: float = 0.0
			if cap > 0:
				rate = float(maxi(_faction.food_used(), 0)
						+ maxi(_faction.food_reserved(), 0)) / float(cap)
			var gap: bool = _farm_urgent() or _farm_wanted(diff)
			if rate > BM.PROMISE_POP_RATE and gap and not _has_site_of(fid):
				_promise_add("建造", farm_disp, int(fd.gold_cost),
						int(fd.wood_cost), now, BM.PROMISE_TTL_FARM)
	# ② 兵营：数量 < 目标，且**没有农场承诺**（避免抢农场预算）
	var pid: StringName = _primary_producer_id(diff)
	if pid != &"":
		var bd: UnitDef = Cfg.unit(pid)
		if bd != null:
			var farm_key: String = ""
			if not farm_disp.is_empty():
				farm_key = "%s|%s" % ["建造", farm_disp]
			var blocked_by_farm: bool = not farm_key.is_empty() and _promise.has(farm_key)
			if not blocked_by_farm and not _has_site_of(pid) \
					and _faction.count_buildings(pid) < _barracks_want():
				_promise_add("建造", String(bd.display_name), int(bd.gold_cost),
						int(bd.wood_cost), now, BM.PROMISE_TTL_BARRACKS)
	# ③ 分基地：资源点 90 s 内枯竭 且 金币 ≥ 分基地成本 → TTL 60 s。
	#    ★ `can_build_townhall()` 仍固定 false（禁止项：AI 自动建大本营），
	#      所以本条当前**永不触发**，只保留承诺结构；开关一开即生效。
	if can_build_townhall():
		var hid: StringName = _main_base_id()
		var hd: UnitDef = Cfg.unit(hid) if hid != &"" else null
		if hd != null and _expand_due_soon() and _faction.gold >= int(hd.gold_cost):
			_promise_add("建造", String(hd.display_name), int(hd.gold_cost),
					int(hd.wood_cost), now, BM.PROMISE_TTL_EXPAND)


## 资源点"90 s 内枯竭"判据的**接口桩**。
## 分基地的生成被 `can_build_townhall()`（恒 false）挡在前面，本函数当前不会被调用；
## 2C-13 若开分基地，在这里接「剩余矿量 ÷ 最近 60 s 金币速率」即可。
func _expand_due_soon() -> bool:
	return false


## 生成一条承诺（已有同类则跳过）。返回是否真的新增。
func _promise_add(action: String, target: String, gold: int, wood: int,
		now: float, ttl: float) -> bool:
	var k: String = "%s|%s" % [action, target]
	if _promise.has(k):
		return false
	var p = _model_call("promise_make", [action, target, gold, wood, now, ttl])
	if p == null or not (p is Dictionary):
		return false
	_promise[k] = p
	dept_stats["promise_made"] = int(dept_stats["promise_made"]) + 1
	return true


## 局末清空承诺表（bench 在 _finish 前调）。
## 返回清理前的条数 → 落盘 `promise_left_at_end`（生命周期管理断言：清理后必须为 0）。
func promise_dispose() -> int:
	var n: int = _promise.size()
	_promise.clear()
	dept_stats["promise_left_at_end"] = n
	return n


# ===========================================================================
# 2C-13 · 目标层 / 计划层 / 空过（dept=on 且 goal=on 走这条；否则走 2C-12 仲裁）
#
# 流水线（每 2 s 一个决策周期）：
#   世界状态快照（每 tick 覆盖写）
#     → 三部门各报 0~N 条**目标建议**（9 字段，不带执行句柄）
#     → 主部门选 1 主 + 1 次（紧迫度 × 部门权重 × 局势修正；后两项第一版全 1.0）
#     → 计划/预算层锁预留（跟目标同生共死）
#     → 执行层按**主目标优先级**重排既有诉求并逐条扣预算 → `_dept_execute`
#     → 生命周期扫描（达成 / 过期 / 被抢占 → 释放预留）
#
# 与 2C-12 的三处结构差别（都不是参数）：
#   ① 承诺表在 goal=on 时**不参与**：预留并入目标，跟目标同生共死（§9 禁止独立承诺表）；
#   ② 预留**可花**：主/次目标覆盖的诉求直接从预留里扣 —— 2C-12 "锁住却花不出去"的死锁
#      在结构上不存在（预留是给这条目标自己用的，不是从公共池里永久挖走）；
#   ③ 空过是一等公民：所有建议紧迫度 < 阈值 → 主/次都空、预留 0、训练/建造/修理停，
#      但采集（后台）/防守/巡逻/侦查/出击照常。
# ===========================================================================

## 目标的存活时间（秒）。**不是逻辑，是场景标定值**：过期只是兜底，
## 正常路径是"达成"或被更高紧迫度目标抢占。取值 = 该动作一轮完整闭环的量级。
const GOAL_TTL_BUILD: float = 90.0
const GOAL_TTL_TRAIN: float = 60.0
const GOAL_TTL_RESEARCH: float = 240.0
const GOAL_TTL_ATTACK: float = 120.0
const GOAL_TTL_DEFEND: float = 30.0
const GOAL_TTL_SCOUT: float = 45.0
const GOAL_TTL_PATROL: float = 45.0


## 空过阈值（进卡；`AI诉求系数.tres` 里加 `目标_紧迫度阈值` 即可覆盖）。
## `--goal-thr=` 只给**机制验证局**用（默认 -1 = 不覆盖）。
func _goal_threshold() -> float:
	var ov: float = AIV.goal_threshold_override()
	if ov >= 0.0:
		return ov
	return float(BM.demand_coef("目标_紧迫度阈值", GL.URGENCY_THRESHOLD_DEFAULT))


## 时间阶段（世界状态字段"时间阶段"；只做描述，不参与任何判据）。
func _ws_phase() -> String:
	var t: float = Game.elapsed
	if t < 120.0:
		return "开局"
	if t < 300.0:
		return "前期"
	if t < 600.0:
		return "中期"
	return "后期"


## 资源点区域缓存：全图树木每帧扫不起，但区域编号不需要每帧更新
## （树被采光也不回收编号 —— 规范要求"同一区域不重复编号"，回收就等于重编号）。
func _ws_refresh_resources(now: float) -> void:
	if now < _ws_res_next_t:
		return
	_ws_res_next_t = now + WS_RESOURCE_REFRESH
	var out: Array = []
	var lv = Game.level
	if lv == null or not lv.has_method("resource_nodes"):
		_ws_res_cells = out
		return
	var seen: Dictionary = {}
	for h in lv.resource_nodes():
		if h == null or not is_instance_valid(h):
			continue
		var p: Vector3 = h.global_position
		var c: Vector2i = WS.region_cell(p)
		var k: String = "%d:%d" % [c.x, c.y]
		if seen.has(k):
			continue
		seen[k] = true
		var kind: String = "gold" \
				if int(h.get("harvest_kind")) == RtsConst.Harvest.GOLD else "tree"
		out.append({"kind": kind, "pos": p})
	_ws_res_cells = out


## 世界状态：每 tick **整份覆盖写**（不是增量更新 —— 结构上不可能累积）。
func _world_tick(now: float) -> void:
	if _faction == null:
		return
	var army_n: int = _army_units().size()
	var raw_troops: int = _troop_available_raw()
	var bld: Dictionary = {}
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if not b.is_alive():
			continue
		var bid: String = String(b.def.id)
		bld[bid] = int(bld.get(bid, 0)) + 1
	var eb: Array = []
	for f in _war_foes():
		if f == null:
			continue
		for b2 in f.buildings:
			if b2 == null or not is_instance_valid(b2) or b2.def == null:
				continue
			if not b2.is_alive():
				continue
			eb.append({"id": int(b2.get_instance_id()), "type": String(b2.def.id),
				"pos": b2.global_position, "hp": float(b2.get("hp"))})
	var allies: Array = []
	for f2 in Game.allies_of(_faction):
		if f2 == null or f2 == _faction:
			continue
		allies.append(RtsWorld.base_center(f2))
	_ws_refresh_resources(now)
	var verdicts: Array = []
	var vn: int = _l1_verdicts.size()
	for i in range(maxi(vn - L1_VERDICT_N, 0), vn):
		verdicts.append(String(_l1_verdicts[i]))
	var inp: Dictionary = {
		"gold": _faction.gold, "wood": _faction.wood,
		"pop_cap": _faction.food_cap(), "pop_used": _faction.food_used(),
		"pop_reserved": _faction.food_reserved(),
		"army_n": army_n, "defense_locked": _defense_reserved(army_n),
		"troop_locked": maxi(army_n - raw_troops, 0),
		"phase": _ws_phase(), "night": Game.is_night(),
		"threat": int(metrics.get("base_threat", 0.0)),
		"buildings": bld, "enemy_buildings": eb, "allies": allies,
		"resources": _ws_res_cells,
		"dmg_30s": float(ctx1.get("dmg_30s", 0.0)),
		"gold_60s": float(ctx1.get("gold_60s", 0.0)),
		"wood_60s": float(ctx1.get("wood_60s", 0.0)),
		"verdicts": verdicts,
		"own_base": RtsWorld.base_center(_faction),
	}
	world_state = WS.build(inp, _ws_reg)
	_ws_reg = WS.registry_of(world_state)
	_ws_writes += 1
	dept_stats["ws_writes"] = _ws_writes
	dept_stats["ws_fields_last"] = (WS.SNAPSHOT_FIELDS as Array).size() \
			- WS.missing_fields(world_state).size()
	dept_stats["ws_regions_last"] = (world_state.get("区域", []) as Array).size()


## 某个世界坐标落在哪个已知区域 id（没有登记过 → 空串）。
func _region_id_at(pos: Vector3) -> String:
	var cell: Vector2i = WS.region_cell(pos)
	var ids: Dictionary = _ws_reg.get("ids", {})
	for pre in [WS.RK_SELF, WS.RK_ENEMY, WS.RK_RESOURCE, WS.RK_ALLY]:
		var k: String = WS.region_key(String(pre), cell)
		if ids.has(k):
			return String(ids[k])
	return ""


func _enemy_buildings_in_region(rid: String) -> int:
	var n: int = 0
	for e in (world_state.get("敌方建筑", []) as Array):
		if String((e as Dictionary).get("区域", "")) == rid:
			n += 1
	return n


func _own_combat_in_region(rid: String) -> bool:
	for u in _army_units():
		if u == null or not is_instance_valid(u):
			continue
		if _region_id_at(u.global_position) == rid:
			return true
	return false


## 最靠近自己基地的敌方建筑所在区域（攻击/侦查的默认对象）。
func _goal_attack_region() -> String:
	var best: String = ""
	var best_d: float = INF
	var home: Vector3 = RtsWorld.base_center(_faction)
	for e in (world_state.get("敌方建筑", []) as Array):
		var d: Dictionary = e
		var dd: float = home.distance_squared_to(d.get("pos", Vector3.ZERO))
		if dd < best_d:
			best_d = dd
			best = String(d.get("区域", ""))
	return best


## 有没有"可以真的打出去"的条件（**不调用 `_wave_plan`**：它有副作用，
## 会把 `_next_wave_at` / `_bank_breakout` 改掉；目标建议必须是无副作用的读数）。
func _goal_can_attack(diff: DifficultyDef) -> bool:
	if _faction == null:
		return false
	if Game.elapsed < _next_wave_at:
		return false
	if strat_state == ST_BANK or strat_state == ST_RETARGET:
		return false
	if not bool(posture.get("allow_attack", false)):
		return false
	return _army_units().size() >= maxi(diff.min_wave_size, 3)


## 下一项可研究的科技（与 `_sanity_research` 同一批判据，只读不点）。
func _goal_research_candidate() -> StringName:
	if _faction == null:
		return &""
	for b in _faction.buildings:
		var rb := b as RtsBuilding
		if rb == null or not is_instance_valid(rb) or not rb.is_alive() or not rb.is_constructed:
			continue
		if rb.def == null or rb.def.researches.is_empty() or rb.is_researching():
			continue
		for r in rb.def.researches:
			if RtsCombat.research_maxed(_faction, r):
				continue
			if String(rb.research_block_reason(r)) != "":
				continue
			return r
	return &""


## 三部门提目标建议（每 2 s 各 0~N 条，9 字段）。
func _goal_proposals(diff: DifficultyDef, now: float) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var yseq: int = 0
	var zseq: int = 0
	var kseq: int = 0
	# ------------------------- 运营线 Yy：建造 / 训练 / 研发 -------------------------
	var fid: StringName = _food_building_id()
	if fid != &"" and not _has_site_of(fid):
		var fd: UnitDef = Cfg.unit(fid)
		if fd != null:
			var urgent: bool = _farm_urgent()
			if urgent or _farm_wanted(diff):
				var cap: int = _faction.food_cap()
				var rate: float = 0.0
				if cap > 0:
					rate = float(_faction.food_used() + _faction.food_reserved()) / float(cap)
				var p1: Dictionary = GL.proposal_make(GL.DEPT_OPS, yseq + 1, GL.ACT_BUILD,
						String(fid), 1, GL.urgency_build_farm(rate, urgent),
						"人口 %d/%d（含在训 %d，%s）" % [_faction.food_used(), cap,
							_faction.food_reserved(), "急建" if urgent else "预判"],
						int(fd.gold_cost), int(fd.wood_cost), GL.DONE_BUILT,
						now + GOAL_TTL_BUILD)
				if not p1.is_empty():
					yseq += 1
					out.append(p1)
	var pid: StringName = _primary_producer_id(diff)
	if pid != &"" and not _has_site_of(pid):
		var have_p: int = _faction.count_buildings(pid)
		var want_p: int = _barracks_want()
		if have_p < want_p:
			var bd: UnitDef = Cfg.unit(pid)
			if bd != null:
				var p2: Dictionary = GL.proposal_make(GL.DEPT_OPS, yseq + 1, GL.ACT_BUILD,
						String(pid), 1, GL.urgency_build_barracks(have_p),
						"兵营 %d/%d（%s）" % [have_p, want_p,
							"无产能" if have_p <= 0 else "扩建"],
						int(bd.gold_cost), int(bd.wood_cost), GL.DONE_BUILT,
						now + GOAL_TTL_BUILD)
				if not p2.is_empty():
					yseq += 1
					out.append(p2)
	var at: int = _army_target()
	var army_n: int = _army_units().size()
	var gap: int = maxi(at - army_n, 0) if at >= 0 else 0
	if gap > 0:
		var picked: StringName = &""
		for b in _army_producers(diff):
			picked = _pick_army_unit(b as RtsBuilding, diff)
			if picked != &"":
				break
		var ud: UnitDef = Cfg.unit(picked) if picked != &"" else null
		if ud != null:
			var p3: Dictionary = GL.proposal_make(GL.DEPT_OPS, yseq + 1, GL.ACT_TRAIN,
					String(picked), gap, GL.urgency_train(gap, at),
					"军队缺口 %d（目标 %d 实际 %d）" % [gap, at, army_n],
					int(ud.gold_cost), int(ud.wood_cost), GL.DONE_TRAINED,
					now + GOAL_TTL_TRAIN)
			if not p3.is_empty():
				yseq += 1
				out.append(p3)
	var ptarget: int = PEASANT_TOTAL_CAP + int(posture.get("worker_bonus", 0))
	var peasants: int = _faction.count_units(_worker_id())
	var pgap: int = maxi(ptarget - peasants, 0)
	if pgap > 0 and peasants < army_n + VILLAGER_ARMY_GAP:
		var wd: UnitDef = Cfg.unit(_worker_id())
		if wd != null:
			var p4: Dictionary = GL.proposal_make(GL.DEPT_OPS, yseq + 1, GL.ACT_TRAIN,
					String(_worker_id()), pgap, GL.urgency_train(pgap, ptarget),
					"农民缺口 %d（目标 %d 实际 %d）" % [pgap, ptarget, peasants],
					int(wd.gold_cost), int(wd.wood_cost), GL.DONE_TRAINED,
					now + GOAL_TTL_TRAIN)
			if not p4.is_empty():
				yseq += 1
				out.append(p4)
	var rid: StringName = _goal_research_candidate()
	if rid != &"":
		var rd: ResearchDef = Cfg.research(rid)
		if rd != null:
			var p5: Dictionary = GL.proposal_make(GL.DEPT_OPS, yseq + 1, GL.ACT_RESEARCH,
					String(rid), 1, GL.urgency_research(), "科技可研究：%s" % String(rid),
					int(rd.gold_cost), int(rd.wood_cost), GL.DONE_RESEARCHED,
					now + GOAL_TTL_RESEARCH)
			if not p5.is_empty():
				yseq += 1
				out.append(p5)
	# ------------------------- 战斗线 Zd：攻击区域 / 摧毁单位 / 防守地点 -------------
	var threat_n: int = int(metrics.get("base_threat", 0.0))
	if threat_n > 0:
		var p6: Dictionary = GL.proposal_make(GL.DEPT_COMBAT, zseq + 1, GL.ACT_DEFEND,
				WS.RK_SELF, 0, GL.urgency_defend(threat_n),
				"压家敌人 %d 个" % threat_n, 0, 0, GL.DONE_THREAT_CLEAR,
				now + GOAL_TTL_DEFEND)
		if not p6.is_empty():
			zseq += 1
			out.append(p6)
	var ratio: float = float(posture.get("army_ratio", 1.0))
	if _goal_can_attack(diff):
		var ar: String = _goal_attack_region()
		if not ar.is_empty():
			var p7: Dictionary = GL.proposal_make(GL.DEPT_COMBAT, zseq + 1,
					GL.ACT_ATTACK_REGION, ar, 1, GL.urgency_push(ratio),
					"兵力比 %.2f，可出击（区域 %s）" % [ratio, ar], 0, 0,
					GL.DONE_REGION_CLEAR, now + GOAL_TTL_ATTACK)
			if not p7.is_empty():
				zseq += 1
				out.append(p7)
	var ht: Dictionary = _high_threat_target()
	if not ht.is_empty():
		var p8: Dictionary = GL.proposal_make(GL.DEPT_COMBAT, zseq + 1,
				GL.ACT_DESTROY, str(int(ht.get("target_id", 0))), 1,
				GL.urgency_push(ratio), "高威胁目标（近 60 s 伤害最高）", 0, 0,
				GL.DONE_TARGET_DEAD, now + GOAL_TTL_ATTACK)
		if not p8.is_empty():
			zseq += 1
			out.append(p8)
	# ------------------------- 扩张线 Kz：侦查 / 巡逻 / 建立分基地 -------------------
	if _scout_cd <= 0.0 and threat_n <= 0 and _idle_scout_unit() != null:
		var sr: String = _goal_attack_region()
		if not sr.is_empty():
			var knows: bool = not (world_state.get("敌方建筑", []) as Array).is_empty()
			var p9: Dictionary = GL.proposal_make(GL.DEPT_EXPAND, kseq + 1,
					GL.ACT_SCOUT, sr, 1, GL.urgency_scout(knows),
					"侦查 %s（%s）" % [sr, "已有情报" if knows else "无情报"],
					0, 0, GL.DONE_ARRIVED, now + GOAL_TTL_SCOUT)
			if not p9.is_empty():
				kseq += 1
				out.append(p9)
	if not _patrol_plan().is_empty():
		var p10: Dictionary = GL.proposal_make(GL.DEPT_EXPAND, kseq + 1,
				GL.ACT_PATROL, WS.RK_SELF, 1, GL.urgency_patrol(), "基地外圈巡逻",
				0, 0, GL.DONE_PATROLLED, now + GOAL_TTL_PATROL)
		if not p10.is_empty():
			kseq += 1
			out.append(p10)
	# 建立分基地：`can_build_townhall()` 恒 false（禁止项），本轮永不提案。
	return out


## 目标达成判定（每种动作一个可观测量）。**没做"命令已发出即达成"的近似**：
## 建造/训练/研发看真实数量，区域类看区域内的实际敌我单位，防守看威胁数。
func _goal_done_map(now: float) -> Dictionary:
	var out: Dictionary = {}
	if _faction == null:
		return out
	for k in goals_active.keys():
		var g: Dictionary = goals_active[k]
		var cond: String = String(g.get("达成条件", ""))
		var obj: String = String(g.get("对象", ""))
		var base: int = int(g.get("_基数", 0))
		var obs: int = 0
		match cond:
			GL.DONE_BUILT:
				obs = _faction.count_buildings(StringName(obj)) - base
			GL.DONE_TRAINED:
				obs = _faction.count_units(StringName(obj)) - base
			GL.DONE_RESEARCHED:
				obs = 1 if RtsCombat.research_maxed(_faction, StringName(obj)) else 0
			GL.DONE_REGION_CLEAR:
				obs = _enemy_buildings_in_region(obj)
			GL.DONE_TARGET_DEAD:
				var n = instance_from_id(int(obj))
				obs = 1 if (n != null and is_instance_valid(n) and n.is_alive()) else 0
			GL.DONE_THREAT_CLEAR:
				obs = int(metrics.get("base_threat", 0.0))
			GL.DONE_ARRIVED, GL.DONE_PATROLLED:
				obs = 1 if _own_combat_in_region(obj) else 0
		out[String(k)] = GL.done_met(cond, obs)
	return out


## 把选中目标登记成活动目标（补两个运行期字段：`_基数` = 开目标时的存量，
## `_显示名` = def.id → display_name，执行层的诉求用的是显示名）。
func _goal_open(p: Dictionary, now: float) -> Dictionary:
	var g: Dictionary = GL.goal_new(p, now)
	var act: String = String(g.get("动作", ""))
	var obj: String = String(g.get("对象", ""))
	var base: int = 0
	var disp: String = ""
	if act == GL.ACT_BUILD:
		base = _faction.count_buildings(StringName(obj))
	elif act == GL.ACT_TRAIN:
		base = _faction.count_units(StringName(obj))
	if act == GL.ACT_BUILD or act == GL.ACT_TRAIN or act == GL.ACT_RESEARCH:
		var ud: UnitDef = Cfg.unit(StringName(obj))
		if ud != null:
			disp = String(ud.display_name)
	g["_基数"] = base
	g["_显示名"] = disp
	return g


## 主目标切换序列（人工看合理性用；上限 400 条，防止局末 JSON 爆掉）。
func _goal_switch(from_id: String, to_id: String, reason: String, now: float) -> void:
	if from_id == to_id:
		return
	var seq: Array = dept_stats["goal_switch_seq"]
	seq.append({"t": snappedf(now, 0.1), "from": from_id, "to": to_id, "原因": reason})
	while seq.size() > 400:
		seq.remove_at(0)


## 本周期"还没被采纳的最高分建议"——只用来判抢占（不能拿当前主/次自己来抢自己）。
func _goal_best_new(props: Array) -> Dictionary:
	var best: Dictionary = {}
	for p in props:
		if not (p is Dictionary):
			continue
		var g: Dictionary = p
		if goals_active.has(String(g.get("id", ""))):
			continue
		if not GL.proposal_valid(g):
			continue
		if best.is_empty() or float(g["紧迫度"]) > float(best["紧迫度"]) + 0.000001:
			best = g
		elif is_equal_approx(float(g["紧迫度"]), float(best["紧迫度"])) \
				and String(g["id"]) < String(best["id"]):
			best = g
	return best


## 选主/次：当前主目标还活着就**保持**（不做每周期重选，否则切换序列全是噪声）；
## 主目标没了 → 次目标晋升；都没有 → 走 `select`（含空过判定）。
func _goal_select(props: Array, now: float, prev_id: String = "",
		preempted: bool = false) -> void:
	if goal_main.is_empty() and not goal_sub.is_empty() \
			and goals_active.has(String(goal_sub["id"])):
		goal_main = goals_active[String(goal_sub["id"])]
		goal_sub = {}
		dept_stats["goal_sub_promotions"] = int(dept_stats["goal_sub_promotions"]) + 1
		_goal_switch(prev_id, String(goal_main["id"]), "次目标晋升", now)
	if not goal_main.is_empty():
		goal_main = goals_active[String(goal_main["id"])]
		if goal_noop:
			goal_noop = false
		# ★ 2026-11-07：主目标还活着时也要把次目标补上。
		#   老代码在这里直接 return，次目标一旦结束（晋升/达成/过期）就永久为空 ——
		#   实测次目标空置率 89%，就是这么来的。
		_goal_fill_sub(props, now)
		_goal_note_main()
		return
	# ★ 冷却过滤：刚结束的「动作|对象」4 秒内不再被选回来。
	#   注意：只过滤候选，不动 0.6 阈值；全被过滤 → 仍然走空过（不硬塞目标）。
	var usable: Array = []
	var skipped: int = 0
	for p in props:
		if not (p is Dictionary):
			continue
		var key: String = String((p as Dictionary).get("动作", "")) + "|" \
				+ String((p as Dictionary).get("对象", ""))
		if float(_goal_cd.get(key, -1.0)) > now:
			skipped += 1
			continue
		usable.append(p)
	if skipped > 0:
		dept_stats["goal_cd_skips"] = int(dept_stats["goal_cd_skips"]) + skipped
	var sel: Dictionary = GL.select(usable, _faction.gold, _goal_thr)
	if bool(sel["空过"]):
		if not goal_noop:
			_goal_switch(prev_id, "", "进入空过", now)
		goal_noop = true
		dept_stats["goal_noop_cycles"] = int(dept_stats["goal_noop_cycles"]) + 1
		var sv: Dictionary = GL.noop_saving(_faction.gold,
				float(dept_stats.get("saving_reserve_last", 0.0)), _noop_aggressive)
		if bool(sv["退出"]):
			dept_stats["noop_aggressive_exits"] = \
					int(dept_stats["noop_aggressive_exits"]) + 1
			_log("空过：金币 ≥1.5×G(t)，退出积极储蓄（仍不训练/建造/修理）")
		_noop_aggressive = bool(sv["积极储蓄"])
		if _noop_aggressive:
			dept_stats["noop_aggressive_cycles"] = \
					int(dept_stats["noop_aggressive_cycles"]) + 1
		else:
			dept_stats["noop_gold_ge_1p5g_cycles"] = \
					int(dept_stats["noop_gold_ge_1p5g_cycles"]) + 1
		return
	goal_noop = false
	_noop_aggressive = true
	var main_p: Dictionary = sel["主目标"]
	goal_main = _goal_open(main_p, now)
	goals_active[String(goal_main["id"])] = goal_main
	dept_stats["goal_created"] = int(dept_stats["goal_created"]) + 1
	if _faction != null and _faction.is_ai:
		dept_stats["goal_ai_created"] = int(dept_stats["goal_ai_created"]) + 1
	if int(sel.get("截断", 0)) > 0:
		dept_stats["goal_truncated_cycles"] = \
				int(dept_stats["goal_truncated_cycles"]) + 1
	_goal_switch(prev_id, String(goal_main["id"]),
			"抢占后新选" if preempted else "新选主目标", now)
	var sub_p: Dictionary = sel["次目标"]
	if not sub_p.is_empty():
		goal_sub = _goal_open(sub_p, now)
		goals_active[String(goal_sub["id"])] = goal_sub
		dept_stats["goal_created"] = int(dept_stats["goal_created"]) + 1
	_goal_note_main()


## 补一个 ≥ `_goal_thr` 的次目标（2026-11-07）。
##
## 背景：主目标存活期间老代码直接 return，次目标一旦结束就再也不补 ——
## 实测次目标空置率 89%。现在每个 2s 周期都会尝试补位：
##   · 与主目标「动作|对象」相同的不要；
##   · 与现存活动目标重复的不要（按 动作|对象 比，不靠 id）；
##   · 冷却中的不要（和主目标同一套 4s 冷却）；
##   · 分数阈值仍然是 `_goal_thr`（0.6），一个字没改。
func _goal_fill_sub(props: Array, now: float) -> void:
	if _faction == null:
		return
	# 已有次目标且还活着 → 不动
	if not goal_sub.is_empty():
		var sid: String = String(goal_sub.get("id", ""))
		if goals_active.has(sid):
			return
		goal_sub = {}
	var main_key: String = String(goal_main.get("动作", "")) + "|" + String(goal_main.get("对象", ""))
	var active_keys: Dictionary = {}
	for k in goals_active.keys():
		var g: Dictionary = goals_active[k]
		active_keys[String(g.get("动作", "")) + "|" + String(g.get("对象", ""))] = true
	var best: Dictionary = {}
	for p in props:
		if not (p is Dictionary):
			continue
		var g: Dictionary = p
		if not GL.proposal_valid(g):
			continue
		if float(g.get("紧迫度", 0.0)) < _goal_thr:
			continue
		var key: String = String(g.get("动作", "")) + "|" + String(g.get("对象", ""))
		if key == main_key or active_keys.has(key):
			continue
		if float(_goal_cd.get(key, -1.0)) > now:
			continue
		if best.is_empty() or float(g["紧迫度"]) > float(best["紧迫度"]) + 0.000001:
			best = g
	if best.is_empty():
		return
	# 用 "Sub_" 前缀另起 id：提案 id 每周期重编，直接落库可能和仍在执行的目标撞 id
	var clone: Dictionary = best.duplicate(true)
	clone["id"] = "Sub_" + String(clone.get("id", "0"))
	goal_sub = _goal_open(clone, now)
	goals_active[String(goal_sub["id"])] = goal_sub
	dept_stats["goal_sub_refilled"] = int(dept_stats["goal_sub_refilled"]) + 1
	dept_stats["goal_created"] = int(dept_stats["goal_created"]) + 1


## 修正口径的达成判定（**纯观测**）：训练/建造按**期望值**算，不是"多了 1 个就算"。
## 区域/到达/威胁三类无法回溯开目标时的状态，按原判定（返回 true）。
func _goal_strict_ok(g: Dictionary) -> bool:
	if _faction == null or g.is_empty():
		return false
	var cond: String = String(g.get("达成条件", ""))
	var obj: String = String(g.get("对象", ""))
	var want: int = maxi(1, int(g.get("期望值", 1)))
	var base: int = int(g.get("_基数", 0))
	match cond:
		GL.DONE_BUILT:
			return _faction.count_buildings(StringName(obj)) - base >= want
		GL.DONE_TRAINED:
			return _faction.count_units(StringName(obj)) - base >= want
		GL.DONE_RESEARCHED:
			return RtsCombat.research_maxed(_faction, StringName(obj))
		_:
			return true


func _goal_note_main() -> void:
	if goal_main.is_empty():
		return
	var act: String = String(goal_main.get("动作", ""))
	var dist: Dictionary = dept_stats["goal_main_dist"]
	dist[act] = int(dist.get(act, 0)) + 1
	dept_stats["goal_urgency_last"] = float(goal_main.get("紧迫度", 0.0))


## 一条诉求归谁出钱：主目标优先，其次次目标。返回活动目标（空 = 公共池）。
func _goal_covers(g: Dictionary, d: Dictionary) -> bool:
	if g.is_empty():
		return false
	var gact: String = String(g.get("动作", ""))
	var dact: String = String(d.get("动作类型", ""))
	match gact:
		GL.ACT_BUILD:
			return dact == "建造" and String(d.get("目标", "")) == String(g.get("_显示名", ""))
		GL.ACT_TRAIN:
			return dact == "训练" and String(d.get("目标", "")) == String(g.get("_显示名", ""))
		GL.ACT_ATTACK_REGION, GL.ACT_DESTROY:
			return dact == "出击"
		GL.ACT_DEFEND:
			return dact == "防守"
		GL.ACT_SCOUT:
			return dact == "侦查"
		GL.ACT_PATROL:
			return dact == "巡逻"
	return false


func _goal_owner_id(d: Dictionary) -> String:
	if _goal_covers(goal_main, d):
		return String(goal_main.get("id", ""))
	if _goal_covers(goal_sub, d):
		return String(goal_sub.get("id", ""))
	return ""


## 目标花钱：从它的预留里扣（写回 `goals_active`，再同步主/次指针）。
func _goal_consume_write(gid: String, gold: int, wood: int) -> void:
	if gid.is_empty() or not goals_active.has(gid):
		return
	goals_active[gid] = GL.goal_consume(goals_active[gid], gold, wood)
	if not goal_main.is_empty() and String(goal_main["id"]) == gid:
		goal_main = goals_active[gid]
	if not goal_sub.is_empty() and String(goal_sub["id"]) == gid:
		goal_sub = goals_active[gid]


## 一次目标层决策（`_dept_tick` 的 2 s 节拍里调）。
func _goal_tick(diff: DifficultyDef, now: float) -> void:
	_goal_thr = _goal_threshold()
	dept_stats["goal_cycles"] = int(dept_stats["goal_cycles"]) + 1
	# --- ① G(t) / 单件成本：**口径与 2C-12 完全一致**（中位数 + 假待办排除）---
	var stall_n: int = int(round(float(_model_call("demand_coef", ["储蓄_假待办周期", 30.0]))))
	var unit_cost: float = float(_model_call("typical_unit_cost_median",
			[demands_l2, _saving_stall, stall_n, _saving_last_unit_cost]))
	_saving_last_unit_cost = unit_cost
	var reserve: float = float(_model_call("saving_target", [Game.elapsed, unit_cost]))
	dept_stats["saving_reserve_last"] = reserve
	# 2C-14 纯观测修复：goal 路径补上「储备充足率」计数器（2C-13 §10.2 遗留）。
	# 口径与 2C-12 完全一致：金币 >= 本周期 G(t)；分母 cycles 由共用的 _dept_execute 累加。
	# 只写计数，不进任何决策（reserve 已在上方算好，未被改动）。
	if float(_faction.gold) >= reserve:
		dept_stats["saving_sufficient_cycles"] = int(dept_stats.get("saving_sufficient_cycles", 0)) + 1
	dept_stats["saving_unit_cost_last"] = unit_cost
	var hits: Array = _saving_urgency()
	var urgent: bool = not hits.is_empty()
	var hit_stat: Dictionary = dept_stats["saving_urgent_hits"]
	for h in hits:
		var hk: String = String(h)
		hit_stat[hk] = int(hit_stat.get(hk, 0)) + 1
	dept_stats["saving_urgent_reasons_last"] = hits
	dept_stats["saving_urgent_last"] = urgent
	dept_stats["goal_threshold_last"] = _goal_thr
	# --- ② 建议 ---
	var props: Array = _goal_proposals(diff, now)
	dept_stats["goal_proposals_last"] = props.size()
	# --- ③ 生命周期：达成 / 过期 / 被抢占 → 释放预留 ---
	var prev_main_id: String = String(goal_main.get("id", ""))
	var had_preempt: bool = false
	var done: Dictionary = _goal_done_map(now)
	var best: Dictionary = _goal_best_new(props)
	_goal_best = best
	var tick: Dictionary = GL.goal_tick(goals_active, done, now, best, _goal_thr)
	goals_active = tick["存活"]
	for r in (tick["释放"] as Array):
		var rd: Dictionary = r
		var reason: String = String(rd.get("原因", ""))
		var rel: Dictionary = dept_stats["goal_release"]
		rel[reason] = int(rel.get(reason, 0)) + 1
		# ★ 2026-11-07 空过收敛：目标结束后同一「动作|对象」冷却 4 秒，
		#   避免"结束→下一周期又选回来→再结束"的三秒进出。
		var gkey: String = String(rd.get("动作", "")) + "|" + String(rd.get("对象", ""))
		_goal_cd[gkey] = now + GOAL_COOLDOWN_SEC
		# ★ AI-only 达成率（纯观测）：副官=玩家阵营，不计入分母。
		if _faction != null and _faction.is_ai:
			dept_stats["goal_metric_total"] = int(dept_stats["goal_metric_total"]) + 1
			if reason == "达成":
				dept_stats["goal_metric_done"] = int(dept_stats["goal_metric_done"]) + 1
				if _goal_strict_ok(rd):
					dept_stats["goal_metric_strict_done"] = \
						int(dept_stats["goal_metric_strict_done"]) + 1
		match reason:
			"达成":
				dept_stats["goal_done_events"] = int(dept_stats["goal_done_events"]) + 1
			"过期":
				dept_stats["goal_expire_events"] = int(dept_stats["goal_expire_events"]) + 1
			"被抢占":
				dept_stats["goal_preempt_events"] = int(dept_stats["goal_preempt_events"]) + 1
				had_preempt = true
		_log("目标结束 %s %s·%s（%s，释放 %d 金）" % [String(rd.get("id", "")),
			String(rd.get("动作", "")), String(rd.get("对象", "")), reason,
			int(rd.get("金币", 0))])
	# 指针同步：`goals_active` 是唯一真源，主/次只指向它里面的那份。
	if not goal_main.is_empty():
		var mid: String = String(goal_main["id"])
		goal_main = goals_active.get(mid, {}) if goals_active.has(mid) else {}
	if not goal_sub.is_empty():
		var sid: String = String(goal_sub["id"])
		goal_sub = goals_active.get(sid, {}) if goals_active.has(sid) else {}
	# --- ④ 选主/次（含空过）---
	_goal_select(props, now, prev_main_id, had_preempt)
	# 2C-14 纯观测：本周期有没有次目标（只写计数，不参与选目标/预留/执行）
	if goal_sub.is_empty():
		dept_stats["goal_sub_empty_cycles"] = int(dept_stats.get("goal_sub_empty_cycles", 0)) + 1
	else:
		dept_stats["goal_sub_present_cycles"] = int(dept_stats.get("goal_sub_present_cycles", 0)) + 1
	# --- ⑤ 预留 + 计划（计划只描述，不动钱）---
	goal_reserved = GL.reserve_left(goals_active)
	dept_stats["goal_reserve_last"] = int(goal_reserved.get("金币", 0))
	if not goal_main.is_empty():
		var pact: String = String(goal_main.get("动作", ""))
		dept_stats["plan_action_last"] = pact
		dept_stats["plan_steps_last"] = PL.plan_for(pact).size()
	# --- ⑥ 执行 ---
	_goal_execute(now, reserve, urgent)


## 执行层：按主目标优先级重排既有诉求 → 逐条过预算 → `_dept_execute`。
## **不改任何执行细节**（怎么派兵、怎么选工地一律走原 `_exec_*`），
## 只决定"谁先谁后、这笔钱该不该花"。
func _goal_execute(now: float, reserve: float, urgent: bool) -> void:
	var pool: Array = []
	if goal_noop:
		for d in demands_l2:
			if not (d is Dictionary):
				continue
			var act0: String = String((d as Dictionary).get("动作类型", ""))
			if GL.blocked_by_noop(act0):
				var bl: Dictionary = dept_stats["noop_blocked"]
				bl[act0] = int(bl.get(act0, 0)) + 1
				continue
			pool.append(d)
	else:
		pool = demands_l2
	var list: Array = GL.order_demands(pool, goal_main)
	var plan: Dictionary = {"执行": [], "驳回": [], "总额": list.size(),
		"金币余": 0, "木材余": 0, "兵力余": 0, "零成本储备驳回": 0}
	var g: int = maxi(_faction.gold, 0)
	var w: int = maxi(_faction.wood, 0)
	var t: int = _troop_available_raw()
	var g0: int = g
	var w0: int = w
	var t0: int = t
	var seen: Dictionary = {}
	var per_dept: Dictionary = {}
	var caps: Dictionary = _model_call("concurrency_caps", [Game.elapsed])
	var reserved_left: int = int(goal_reserved.get("金币", 0))
	# 空过 + 已退出积极储蓄 → 不再把 G(t) 当底线（钱可以放着不动，但也不主动攒）
	var floor_reserve: float = reserve
	if goal_noop and not _noop_aggressive:
		floor_reserve = 0.0
	for d in list:
		var dd: Dictionary = d
		var src: String = String(dd.get("来源线", ""))
		var act: String = String(dd.get("动作类型", ""))
		var key: String = "%s|%s|%s" % [src, act, String(dd.get("目标", ""))]
		dd["驳回原因"] = BM.RJ_NONE
		if seen.has(key):
			dd["驳回原因"] = BM.RJ_DONE
			(plan["驳回"] as Array).append(dd)
			continue
		if not bool(dd.get("可执行", true)):
			dd["驳回原因"] = BM.RJ_COND
			(plan["驳回"] as Array).append(dd)
			continue
		if BM.concurrency_breach((plan["执行"] as Array).size(),
				int(per_dept.get(src, 0)), caps):
			dd["驳回原因"] = BM.RJ_CONCURRENT
			(plan["驳回"] as Array).append(dd)
			continue
		var ng: int = int(dd.get("金币成本", 0))
		var nw: int = int(dd.get("木材成本", 0))
		var nt: int = int(dd.get("兵力占用", 0))
		var owner: String = _goal_owner_id(dd)
		var from_res: bool = not owner.is_empty()
		if from_res:
			var og: Dictionary = goals_active.get(owner, {})
			var oleft: int = int((og.get("预留", {"金币": 0}) as Dictionary).get("金币", 0)) \
					- int((og.get("已用", {"金币": 0}) as Dictionary).get("金币", 0))
			# 预留不够而现钱够 → 走纯现金（预留是"保底"，不是天花板）
			if oleft >= ng:
				pass
			elif g >= ng:
				from_res = false
			else:
				dd["驳回原因"] = BM.RJ_GOLD
				(plan["驳回"] as Array).append(dd)
				continue
		else:
			var lack: Array = []
			if g < ng:
				lack.append("g")
			if w < nw:
				lack.append("w")
			if t < nt:
				lack.append("t")
			if not lack.is_empty():
				var outbid: bool = true
				if lack.has("g") and g0 < ng:
					outbid = false
				if lack.has("w") and w0 < nw:
					outbid = false
				if lack.has("t") and t0 < nt:
					outbid = false
				if outbid:
					dd["驳回原因"] = BM.RJ_OUTBID
				elif lack.has("g"):
					dd["驳回原因"] = BM.RJ_GOLD
				elif lack.has("w"):
					dd["驳回原因"] = BM.RJ_WOOD
				else:
					dd["驳回原因"] = BM.RJ_TROOP
				(plan["驳回"] as Array).append(dd)
				continue
			# 储备线：公共池的钱要留够 G(t)；0 成本诉求天然豁免（`saving_breach` 内保证）
			if BM.saving_breach(g - reserved_left, ng, floor_reserve, urgent):
				if ng <= 0:
					plan["零成本储备驳回"] = int(plan["零成本储备驳回"]) + 1
				dd["驳回原因"] = BM.RJ_SAVING
				(plan["驳回"] as Array).append(dd)
				continue
		dd["_owner"] = owner
		g -= ng
		w -= nw
		t -= nt
		if from_res:
			reserved_left = maxi(reserved_left - ng, 0)
		seen[key] = true
		per_dept[src] = int(per_dept.get(src, 0)) + 1
		(plan["执行"] as Array).append(dd)
	plan["金币余"] = g
	plan["木材余"] = w
	plan["兵力余"] = t
	# 执行 + 日志 + 假待办账本：**全部复用 2C-9/2C-12 的既有函数**（含兵力锁、征用）
	_dept_execute(plan)
	_dept_log(now, plan)
	_saving_note_stall(plan)
	# 预留扣减：执行成功才扣（`_dept_execute` 会把失败的从「执行」里剔掉）
	for d2 in (plan["执行"] as Array):
		var dd2: Dictionary = d2
		var oid: String = String(dd2.get("_owner", ""))
		dd2.erase("_owner")
		if oid.is_empty():
			continue
		_goal_consume_write(oid, int(dd2.get("金币成本", 0)),
				int(dd2.get("木材成本", 0)))
	goal_reserved = GL.reserve_left(goals_active)
	dept_stats["goal_reserve_last"] = int(goal_reserved.get("金币", 0))


## 局末清空目标表（bench 在 `_finish` 前调）。返回清理前的剩余预留，
## 落盘 `goal_reserve_left_at_end`（**必须为 0**：无泄漏）。
func goal_dispose() -> Dictionary:
	var left: Dictionary = GL.goal_dispose(goals_active)
	goal_main = {}
	goal_sub = {}
	goal_noop = true
	dept_stats["goal_reserve_left_at_end"] = int(left.get("金币", 0))
	return left


## 主入口：一次 dept 思考（每 tick 调，内部按 2 s 节拍仲裁）
func _dept_tick(diff: DifficultyDef, now: float) -> void:
	if _faction == null:
		return
	_dept_ctx_tick(now)
	# 2C-13 §2：世界状态快照（**每 tick 整份覆盖写**，只读适配器，不重构现有查询）。
	_world_tick(now)
	# --- 后台：采集派工 / 工地结算 / 训练归因（**不参与仲裁**，用户口径"经济在后台"）---
	_assign_workers(diff)
	_tick_build_diag()
	_tick_repair_stats()
	_sample_train_block(diff)
	# --- 战斗线里"不花资源也不抢新增兵力"的部分：残血撤退 / 入夜收队 / 清野 ---
	#   ★ 2C-9 明确**不重写**战斗线闭环，所以这三段保持原样，跑在仲裁之前。
	_manage_retreat()
	if Game.is_night():
		_manage_night(diff)
	else:
		_manage_creep_clear(diff)
	# --- 2 s 节拍：L2 重建 → 主部门仲裁 → 按分数顺序执行 ---
	if _dept_cd > 0.0:
		return
	_dept_cd = DEPT_CYCLE
	_l1_snapshot()
	demands_l2 = _ops_demands(diff)
	demands_l2.append_array(_combat_demands(diff))
	demands_l2.append_array(_expand_demands(diff))
	_dept_note_competition()
	var t_avail: int = _troop_available_raw()
	dept_stats["troop_available"] = _troop_available()
	# --- 2C-13：目标层分支（dept=on 且 goal=on）---
	# 诉求表照旧生成（它是**执行细节**的候选池），但"谁先谁后、这笔钱该不该花"
	# 改由目标层决定：主/次目标 → 优先级 → 预留。承诺表在这条分支上完全不参与。
	if AIV.goal_on():
		_goal_tick(diff, now)
		return
	# --- 2C-11 §3：紧急白名单（命中任一 → 本周期诉求不受储备线约束）---
	# ★ 2C-12：**提到承诺表之前算** —— 紧急态要能抢占非紧急承诺。
	var hits: Array = _saving_urgency()
	var urgent: bool = not hits.is_empty()
	var hit_stat: Dictionary = dept_stats["saving_urgent_hits"]
	for h in hits:
		var hk: String = String(h)
		hit_stat[hk] = int(hit_stat.get(hk, 0)) + 1
	dept_stats["saving_urgent_reasons_last"] = hits
	# --- 2C-12 §3：承诺表维护（过期 / 目标已满足 / 紧急抢占 / 按需生成）---
	# 跑在仲裁之前：本周期新生成的承诺要能影响本周期"可自由使用资源"。
	_promise_tick(now, diff, urgent)
	var committed: int = int(_model_call("promise_committed_gold", [_promise]))
	var claimed: Array = _model_call("promise_claimed_keys", [_promise])
	dept_stats["promise_committed_last"] = committed
	# --- 2C-11 §2：全局一个储备 G(t)（运营线/扩展线共用，不分池）+ 同时做事数上限 ---
	# 2C-12 §2.1：单件典型成本改成「有效待办成本的中位数」——
	#   连续 N 个周期在报却一次没执行的假待办（如神秘圣地 275）先被排除，
	#   再取中位数；无有效待办时沿用上一次的值（_saving_last_unit_cost）。
	var t_sec: float = Game.elapsed
	var stall_n: int = int(round(float(_model_call("demand_coef",
			["储蓄_假待办周期", 30.0]))))
	var unit_cost: float = float(_model_call("typical_unit_cost_median",
			[demands_l2, _saving_stall, stall_n, _saving_last_unit_cost]))
	_saving_last_unit_cost = unit_cost
	var reserve: float = float(_model_call("saving_target", [t_sec, unit_cost]))
	var caps: Dictionary = _model_call("concurrency_caps", [t_sec])
	# 2C-11 P2：储备充足率 = 金币 >= G(t) 的周期数 / 总周期数（只记录，不进决策）
	if float(_faction.gold) >= reserve:
		dept_stats["saving_sufficient_cycles"] = int(dept_stats.get("saving_sufficient_cycles", 0)) + 1
	dept_stats["saving_reserve_last"] = reserve
	dept_stats["saving_unit_cost_last"] = unit_cost
	dept_stats["saving_urgent_last"] = urgent
	dept_stats["caps_last"] = caps
	# 2C-12 §3.2：可自由使用资源 = 当前金币 − 已承诺金币 − G(t)。
	# 仲裁用 `committed` 把「已经留给某个动作的钱」从公共池里扣掉；
	# 被承诺覆盖的诉求（`claimed`）跳过储备线 —— 它那笔钱已经划走了，
	# 再判一次就会变成"承诺了却永远执行不了"的死锁。
	dept_stats["promise_free_gold_last"] = float(_model_call("promise_free_gold",
			[_faction.gold, _promise, reserve]))
	var policy: Dictionary = {"reserve": reserve, "caps": caps, "urgent": urgent,
			"committed": committed, "claimed": claimed}
	var plan: Dictionary = _model_call("arbitrate",
			[demands_l2, _faction.gold, _faction.wood, t_avail, policy])
	if plan == null:
		return
	_dept_execute(plan)
	_dept_log(now, plan)
	# 2C-12 §2.1：假待办账本（执行过的目标清零，被驳回的目标 +1）。
	# 放在 _dept_log 之后：它只影响**下一周期**的单件成本口径，不进本周期决策，
	# 也不破坏 2C-9 的「_dept_execute 紧接 _dept_log」顺序断言。
	_saving_note_stall(plan)


## L0 快照（每 tick 覆盖写）+ L1 环形槽推进（1 s 一格）
func _dept_ctx_tick(now: float) -> void:
	if _faction == null:
		return
	ctx0 = {
		"t": now,
		"gold": _faction.gold,
		"wood": _faction.wood,
		"pop_cap": _faction.food_cap(),
		"pop_used": _faction.food_used(),
		"troops": _army_units().size(),
		"peasants": _workers().size(),
		"阶段": "夜晚" if Game.is_night() else "白天",
		"threat": int(metrics.get("base_threat", 0.0)),
	}
	if _l1_dmg.size() != L1_DMG_SEC:
		_l1_dmg.resize(L1_DMG_SEC)
		_l1_dmg.fill(0.0)
	if _l1_gold.size() != L1_INCOME_SEC:
		_l1_gold.resize(L1_INCOME_SEC)
		_l1_gold.fill(0.0)
	if _l1_wood.size() != L1_INCOME_SEC:
		_l1_wood.resize(L1_INCOME_SEC)
		_l1_wood.fill(0.0)
	if _prev_gold_dept < 0:
		_prev_gold_dept = _faction.gold
		_prev_wood_dept = _faction.wood
	var sec: int = int(now)
	if sec != _l1_sec:
		_l1_sec = sec
		_l1_dmg[sec % L1_DMG_SEC] = 0.0
		# 收支速率只记**正向跳变**（采集交付），花钱不算"负收入"
		_l1_gold[sec % L1_INCOME_SEC] = float(maxi(_faction.gold - _prev_gold_dept, 0))
		_l1_wood[sec % L1_INCOME_SEC] = float(maxi(_faction.wood - _prev_wood_dept, 0))
		_prev_gold_dept = _faction.gold
		_prev_wood_dept = _faction.wood


func _l1_add_damage(dmg: float, now: float) -> void:
	if _l1_dmg.size() != L1_DMG_SEC:
		return
	_l1_dmg[int(now) % L1_DMG_SEC] = float(_l1_dmg[int(now) % L1_DMG_SEC]) + maxf(dmg, 0.0)


## L1 聚合（窗口外的旧数据直接丢弃，内存 O(1)；**不引入历史压缩参数、不存事件列表**）
func _l1_snapshot() -> void:
	var dmg30: float = 0.0
	for v in _l1_dmg:
		dmg30 += v
	var g60: float = 0.0
	var w60: float = 0.0
	for v in _l1_gold:
		g60 += v
	for v in _l1_wood:
		w60 += v
	ctx1 = {
		"dmg_30s": dmg30,
		"gold_60s": g60,
		"wood_60s": w60,
		"gold_rate": g60 / 60.0,
		"wood_rate": w60 / 60.0,
		"verdicts": _l1_verdicts.duplicate(),
	}


# ---------------------------------------------------------------------------
# 2C-10 §7.2 · 90% 人口压力响应测试（纯观测）
# ---------------------------------------------------------------------------

## 占用率 =(占用 + 在训)/上限；首次 >90% 记一次触发；结算后冷却 15 s。
## 2C-11 §7 修正口径：**触发时已有农场工地算成功**（不只看 20 s 内新开工），
## 否则 2C-10 的 8.3% 里有 43.7% 是口径假失败。仍不进任何决策，
## 也不改农场预判/人口逻辑 —— 只往 pop90 / dept_stats 里写观测值。
func _pop90_tick(now: float) -> void:
	if _faction == null:
		return
	var cap: int = _faction.food_cap()
	var used: int = _faction.food_used()
	var reserved: int = _faction.food_reserved()
	var rate: float = 0.0
	if cap > 0:
		rate = float(maxi(used, 0) + maxi(reserved, 0)) / float(cap)
	pop90["峰值"] = maxf(float(pop90["峰值"]), rate)
	# --- 农场工地开工检测：出现新的"未完工农场"实例 id 即记一次 ---
	var fid: StringName = _food_building_id()
	if fid != &"":
		for b in _faction.buildings:
			if b == null or not is_instance_valid(b) or b.def == null:
				continue
			if b.def.id != fid:
				continue
			var rb: RtsBuilding = b as RtsBuilding
			if rb == null or rb.is_constructed:
				continue
			var sid: int = rb.get_instance_id()
			if not _pop90_seen_sites.has(sid):
				_pop90_seen_sites[sid] = true
				_pop90_last_site_t = now
				pop90["农场开工"] = int(pop90["农场开工"]) + 1
				dept_stats["farm_site_starts"] = int(dept_stats["farm_site_starts"]) + 1
	# --- 等待响应：先判成功，再判 20 s 超时 ---
	if _pop90_waiting:
		if now - _pop90_trigger_t <= 20.0 and _pop90_last_site_t >= _pop90_trigger_t - 0.001:
			pop90["成功"] = int(pop90["成功"]) + 1
			# 2C-12 §5 双口径：这一条算「20 s 内新开工」（触发时没有工地，之后才开的）
			pop90["新开工成功"] = int(pop90["新开工成功"]) + 1
			_pop90_waiting = false
			_pop90_cooldown_until = now + 15.0
		elif now - _pop90_trigger_t > 20.0:
			pop90["失败"] = int(pop90["失败"]) + 1
			var rj: Dictionary = dept_stats.get("reject_by_reason", {})
			var top: Array = []
			for k in rj.keys():
				top.append("%s:%d" % [String(k), int(rj[k])])
			(pop90["失败明细"] as Array).append({
				"t": snappedf(_pop90_trigger_t, 0.1), "占用率": snappedf(rate, 0.001),
				"金币": int(_faction.gold), "木材": int(_faction.wood),
				"工位": _builder_uids.size(), "驳回原因": top,
				"农场工地": _has_site_of(fid),
			})
			_pop90_waiting = false
			_pop90_cooldown_until = now + 15.0
		return
	# --- 冷却结束 + 首次 >90% → 触发 ---
	if now >= _pop90_cooldown_until and rate > 0.90:
		pop90["触发"] = int(pop90["触发"]) + 1
		(pop90["触发时刻"] as Array).append(snappedf(now, 0.1))
		# 2C-11 §7 修正口径：触发时**已有农场工地在建** = 已经在响应，直接记成功。
		# 2C-10 §7.2.2 里 43.7% 的失败属"要求 20 s 内新开工"造成的口径假失败
		# （_demand_builds 有 `not _has_site_of(farm)` 早退，有工地时本就不会再报新农场）。
		# 不改农场预判 / 人口逻辑，只改观测判定。
		if _has_site_of(fid):
			pop90["成功"] = int(pop90["成功"]) + 1
			# 2C-12 §5 双口径：这一条只算「触发时已有工地」，**不算新开工**
			pop90["已有工地"] = int(pop90["已有工地"]) + 1
			dept_stats["pop90_site_already"] = int(dept_stats.get("pop90_site_already", 0)) + 1
			_pop90_cooldown_until = now + 15.0
			return
		_pop90_waiting = true
		_pop90_trigger_t = now


# ---------------------------------------------------------------------------
# 兵力预留制（锁定 / 解锁 / 扣减顺序）
# ---------------------------------------------------------------------------

## 防守锁定：留给"家里不空"的那部分（防守下限与压家敌人取大，且不超过现役）
func _defense_reserved(army_n: int) -> int:
	var floor_v: int = _defense_floor()
	var threat_n: int = int(metrics.get("base_threat", 0.0))
	return mini(maxi(army_n, 0), maxi(floor_v, threat_n * 2))


## P0-A（2C-10 修法 b）：**仲裁池** = 现役 − 已锁，**不扣防守下限**。
## 原来 `_troop_available` 和 `normal_push_n` 各扣一次防守下限 →
## 现役 ≤ 下限时可用兵力恒 0，巡逻/侦查/出击全被"兵力不足"驳回（副官自检 26/28）。
## 下限改由 normal_push_n / bank_push_n 在**出击规模**里扣那唯一一次。
func _troop_available_raw() -> int:
	var army_n: int = _army_units().size()
	var locks: int = 0
	for k in _troop_locks.keys():
		locks += int((_troop_locks[k] as Dictionary).get("n", 0))
	dept_stats["lock_held_last"] = _troop_locks.size()
	return maxi(army_n - locks, 0)


## 账面可用兵力 = 现役 − 防守锁定 − 已锁（**只扣一次**）。
## 2C-10 起只作诊断口径，不再传给 `arbitrate`（回归断言这个函数签名）。
func _troop_available() -> int:
	return maxi(_troop_available_raw() - _defense_reserved(_army_units().size()), 0)


func _troop_lock(key: String, n: int, ttl: float, kind: String) -> void:
	if n <= 0:
		return
	_troop_locks[key] = {"n": n, "t": Game.elapsed + maxf(ttl, 0.1), "k": kind}
	match kind:
		"wave":
			dept_stats["lock_wave_held"] = int(dept_stats["lock_wave_held"]) + 1
		"patrol":
			dept_stats["lock_patrol_held"] = int(dept_stats["lock_patrol_held"]) + 1
		"scout":
			dept_stats["lock_scout_held"] = int(dept_stats["lock_scout_held"]) + 1
	dept_stats["lock_held_max"] = maxi(int(dept_stats["lock_held_max"]), _troop_locks.size())


## 解锁。`explicit=true` = 动作正常结束（波次收尾）；false/超时 = 租约到期。
func _troop_unlock(key: String, explicit: bool = false) -> bool:
	if not _troop_locks.has(key):
		return false
	var k: String = String((_troop_locks[key] as Dictionary).get("k", ""))
	_troop_locks.erase(key)
	if explicit and k == "wave":
		dept_stats["lock_wave_released"] = int(dept_stats["lock_wave_released"]) + 1
	return true


## 租约到期清扫（**只有 `wave` 锁到期算泄漏信号** —— 波次收尾应该显式解锁）
func _troop_lock_tick(now: float) -> void:
	var dead: Array = []
	for k in _troop_locks.keys():
		if now >= float((_troop_locks[k] as Dictionary).get("t", 0.0)):
			dead.append(k)
	for k in dead:
		var kind: String = String((_troop_locks[k] as Dictionary).get("k", ""))
		_troop_locks.erase(k)
		if kind == "wave":
			dept_stats["lock_wave_timeout"] = int(dept_stats["lock_wave_timeout"]) + 1


## 2C-10 §6：**可被征用消费**。攒大波出击时把"临时防守 / 巡逻 / 侦查"的短租约锁
## 释放掉、折成出击兵力；这些锁随后由 `_dept_execute` 统一转成 wave 锁，
## 波次收尾 `_close_wave` 显式解锁。2C-9 只写 `可被征用` 从不消费（2904 写 / 0 消费）。
func _requisition_temp_defense() -> int:
	var q: Dictionary = _model_call("requisition_quota", [_troop_locks])
	if q == null or not (q is Dictionary):
		return 0
	var n: int = int((q as Dictionary).get("可征用", 0))
	if n <= 0:
		return 0
	for k in ((q as Dictionary).get("释放键", []) as Array):
		_troop_unlock(String(k), false)
	dept_stats["requisition_times"] = int(dept_stats["requisition_times"]) + 1
	dept_stats["requisitioned_units"] = int(dept_stats["requisitioned_units"]) + n
	return n


# ---------------------------------------------------------------------------
# 三条线：报诉求
# ---------------------------------------------------------------------------

## 运营线：训练 + 建造 + 修理（金币 / 木材的竞争者全在这条线上）
func _ops_demands(diff: DifficultyDef) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var threat_n: int = int(ctx0.get("threat", 0))
	var pd: Dictionary = _demand_peasant()
	if not pd.is_empty():
		out.append(pd)
	out.append_array(_demand_army_train(diff, threat_n))
	out.append_array(_demand_repairs())
	out.append_array(_demand_builds(diff, threat_n))
	return out


## 训练农民（与训练兵**同池竞争金币**，不藏在运营线内部自裁）
func _demand_peasant() -> Dictionary:
	if _faction == null:
		return {}
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	var target: int = PEASANT_TOTAL_CAP + int(posture.get("worker_bonus", 0))
	var starving: bool = _demand_pressure(diff)
	if starving:
		target = mini(target + PEASANT_EMERGENCY_BONUS, PEASANT_TOTAL_CAP)
	var peasants: int = _faction.count_units(_worker_id())
	if peasants >= target:
		return {}
	if not starving and peasants >= _army_units().size() + VILLAGER_ARMY_GAP:
		return {}
	var wid: StringName = _worker_id()
	var wd: UnitDef = Cfg.unit(wid) if wid != &"" else null
	if wd == null:
		return {}
	var hall: RtsBuilding = _first_building(_main_base_id())
	var ready: bool = hall != null and hall.train_count() < MAX_QUEUE_PEASANT
	var gap: int = target - peasants
	return _demand("运营线", "训练", "农民",
			int(wd.gold_cost), int(wd.wood_cost), 0, false,
			float(_model_call("demand_score_train", [gap, int(ctx0.get("threat", 0))])),
			"农民缺口=%d（目标 %d 现有 %d）" % [gap, target, peasants],
			ready, Callable(self, "_exec_train_peasant"))


## 训练战斗单位：每座"队列有空位"的产能建筑报一条（同部门多诉求由主部门重判）
func _demand_army_train(diff: DifficultyDef, threat_n: int) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var producers: Array = _army_producers(diff)
	if producers.is_empty():
		return out
	var target_army: int = _army_target()
	var army: int = _army_units().size()
	# 诊断字段：dept=on 时 `_manage_army` 不再被调用，这个键要在这里补上，
	# 否则 bench 的「军队目标 -1→-1」会变成假信号（army_target_now 一直是好的）
	strat_stats["army_target"] = target_army
	if not strat_stats.has("army_target_first"):
		strat_stats["army_target_first"] = target_army
	if target_army >= 0 and army >= target_army:
		return out
	var gap: int = maxi(target_army - army, 1) if target_army >= 0 else 1
	for b in producers:
		var rb: RtsBuilding = b as RtsBuilding
		if rb == null or not is_instance_valid(rb) or not rb.is_alive():
			continue
		if rb.train_count() >= MAX_QUEUE_ARMY:
			continue
		var picked: StringName = _pick_army_unit(rb, diff)
		if picked == &"":
			continue
		var ud: UnitDef = Cfg.unit(picked)
		if ud == null:
			continue
		out.append(_demand("运营线", "训练", String(ud.display_name),
				int(ud.gold_cost), int(ud.wood_cost), 0, false,
				float(_model_call("demand_score_train", [gap, threat_n])),
				"军队缺口=%d（目标 %d 实际 %d）" % [gap, target_army, army],
				true, Callable(self, "_exec_train_army").bind(rb, picked)))
	return out


## 修理：每栋"掉血 ≥200 且没人修"的建筑一条（分数 = 掉血 ÷ 200，掉血多优先）
func _demand_repairs() -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var pack: Dictionary = _repair_candidates()
	for c in (pack.get("cands", []) as Array):
		var rb: RtsBuilding = c["b"]
		if rb == null or not is_instance_valid(rb) or rb.def == null:
			continue
		var deficit: float = float(c["deficit"])
		out.append(_demand("运营线", "修理", String(rb.def.display_name),
				0, 0, 0, false,
				float(_model_call("demand_score_repair", [deficit])),
				"掉血=%.0f" % deficit, true,
				Callable(self, "_exec_repair").bind(rb, deficit)))
	return out


## 修理统计（**每 tick 采样，与 dept=off 的 `candidates` 口径对齐**；只读不派工）
func _tick_repair_stats() -> void:
	if _faction == null:
		return
	var pack: Dictionary = _repair_candidates()
	var cands: Array = pack.get("cands", [])
	if cands.is_empty():
		if bool(pack.get("wood_blocked", false)):
			repair_stats["blocked_wood"] = int(repair_stats.get("blocked_wood", 0)) + 1
		return
	repair_stats["candidates"] = int(repair_stats.get("candidates", 0)) + 1
	repair_stats["candidate_buildings"] = \
			int(repair_stats.get("candidate_buildings", 0)) + cands.size()


## 建造：农场 / 兵营 / 哨塔 / 营火 / 科技建筑（每类一 tick 最多报一条）
func _demand_builds(diff: DifficultyDef, threat_n: int) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	# ① 农场（急建走 10 分，不急 1 分 —— 刻度在系数卡里）
	var fid: StringName = _food_building_id()
	if fid != &"" and not _has_site_of(fid):
		var urgent: bool = _farm_urgent()
		if urgent or _farm_wanted(diff):
			var fd: UnitDef = Cfg.unit(fid)
			if fd != null:
				var fs: float = float(_model_call("demand_scale",
						["农场急建" if urgent else "农场不急"]))
				# 2C-10 P0-B：70% 人口压力动态系数（**只乘农场建造诉求分**）。
				# 占用率必须含在训人口（food_reserved），否则刚点兵就误判"还有空位"。
				var fcap: int = _faction.food_cap()
				var frate: float = 0.0
				if fcap > 0:
					frate = float(_faction.food_used() + _faction.food_reserved()) / float(fcap)
				var pf: float = float(_model_call("farm_pressure_factor", [frate]))
				dept_stats["farm_factor_last"] = pf
				if pf > 1.000001:
					dept_stats["farm_factor_triggers"] = \
							int(dept_stats["farm_factor_triggers"]) + 1
				out.append(_demand("运营线", "建造", String(fd.display_name),
						int(fd.gold_cost), int(fd.wood_cost), 0, false,
						float(_model_call("demand_score_build", [1, fs, 0, 1.0])) * pf,
						"农场缺口=1（%s，占用 %.0f%% 含在训，压力系数 %.2f，人口 %d/%d）" % [
							"急" if urgent else "不急", frate * 100.0, pf,
							_faction.food_used(), _faction.food_cap()],
						true, Callable(self, "_exec_build_farm")))
	# ② 兵营（主产能建筑）
	var pid: StringName = _primary_producer_id(diff)
	if pid != &"" and not _has_site_of(pid):
		var want: int = _barracks_want()
		var have: int = _faction.count_buildings(pid)
		if have < want:
			var bd: UnitDef = Cfg.unit(pid)
			if bd != null:
				var bs: float = float(_model_call("demand_scale",
						["兵营无产能" if have <= 0 else "兵营扩建"]))
				out.append(_demand("运营线", "建造", String(bd.display_name),
						int(bd.gold_cost), int(bd.wood_cost), 0, false,
						float(_model_call("demand_score_build",
							[0, 1.0, maxi(want - have, 1), bs])),
						"兵营缺口=%d（目标 %d 已有 %d）" % [
							maxi(want - have, 1), want, have],
						true, Callable(self, "_exec_build_barracks")))
	# ③ 哨塔（扩视野；运营线的"建造/哨塔"）
	var wid: StringName = _watchtower_id()
	if wid != &"" and not _has_site_of(wid):
		var wd: UnitDef = Cfg.unit(wid)
		var tid: StringName = _tower_id()
		var wwant: int = clampi(1 + int(Game.elapsed / WATCHTOWER_GROW_SEC), 1, WATCHTOWER_MAX)
		var whave: int = _faction.count_buildings(wid)
		var cap_ok: bool = tid == &"" or _faction.count_buildings(tid) < MAX_ARROW_TOWERS
		if wd != null and whave < wwant and cap_ok:
			out.append(_demand("运营线", "建造", String(wd.display_name),
					int(wd.gold_cost), int(wd.wood_cost), 0, false,
					float(_model_call("demand_score_fixed", ["建塔"])) * (1.0 + float(threat_n)),
					"哨塔 %d/%d 座" % [whave, wwant], true,
					Callable(self, "_exec_build_watchtower")))
	# ④ 营火（只在夜里，最多 CAMPFIRE_MAX 座）
	if Game.is_night():
		var cid: StringName = _campfire_id()
		if cid != &"" and not _has_site_of(cid):
			var cd: UnitDef = Cfg.unit(cid)
			if cd != null and _faction.count_buildings(cid) < CAMPFIRE_MAX:
				out.append(_demand("运营线", "建造", String(cd.display_name),
						int(cd.gold_cost), int(cd.wood_cost), 0, false,
						1.0,
						"夜营火（已有 %d）" % _faction.count_buildings(cid),
						true, Callable(self, "_exec_build_campfire")))
	# ⑤ 其余产能建筑（圣地/车坊）：每种一座，最低分
	# ★ 2C-12 §2.3：这里必须加「买得起」前置（与 dept=off 的 `_maybe_build_one` 同口径）。
	#   2C-11 是无条件报（`可执行=true`），于是"建造·神秘圣地 275 金"在
	#   866/866 个仲裁周期都在报、一次没执行。它同时是全局最贵待办，把单件成本
	#   顶成 275 → G(t) 封顶 550 → 自己（以及农场 120 / 兵营 160）都被储备线卡死，
	#   形成"报 → 顶高 G → 更过不了 → 下周再报"的三层自锁。
	#   修法分两层：生成侧只报买得起的（本条）+ 单件成本取中位数并排除假待办（§2.1）。
	for id in _production_building_ids(diff):
		var nid: StringName = StringName(id)
		if nid == pid:
			continue
		if _faction.count_buildings(nid) >= 1 or _has_site_of(nid):
			continue
		var ed: UnitDef = Cfg.unit(nid)
		if ed == null:
			continue
		if not _can_spend(nid):
			dept_stats["tech_demand_skipped"] = \
					int(dept_stats.get("tech_demand_skipped", 0)) + 1
			continue
		out.append(_demand("运营线", "建造", String(ed.display_name),
				int(ed.gold_cost), int(ed.wood_cost), 0, false,
				float(_model_call("demand_scale", ["农场不急"])),
				"科技建筑每种一座（已有 %d）" % _faction.count_buildings(nid),
				true, Callable(self, "_exec_build_extra").bind(nid)))
	return out


## 战斗线：出击 + 防守（**不花金币**，竞争的是兵力存量）
func _combat_demands(diff: DifficultyDef) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var threat_n: int = int(ctx0.get("threat", 0))
	if threat_n > 0:
		var dp: Dictionary = _defense_plan(diff)
		if not dp.is_empty():
			out.append(_demand("战斗线", "防守", "基地", 0, 0, 0, false,
					float(_model_call("demand_score_defend", [threat_n])),
					"压家敌人=%d" % threat_n, true,
					Callable(self, "_exec_defend").bind(dp)))
	var wp: Dictionary = _wave_plan(diff)
	if not wp.is_empty():
		var ratio: float = float(posture.get("army_ratio", 1.0))
		var requis: bool = bool(wp.get("breakout", false))
		out.append(_demand("战斗线", "出击", String(wp.get("goal_name", "?")),
				0, 0, int(wp.get("push_n", 0)), requis,
				float(_model_call("demand_score_push", [ratio])),
				"兵力比=%.2f 出击 %d 人" % [ratio, int(wp.get("push_n", 0))],
				true, Callable(self, "_exec_wave").bind(wp)))
	return out


## 扩展线：侦查 / 巡逻 / 建塔 / 建分基地（侦查巡逻与战斗线**同池竞争兵力**）
func _expand_demands(diff: DifficultyDef) -> Array:
	var out: Array = []
	if _faction == null:
		return out
	var threat_n: int = int(ctx0.get("threat", 0))
	# ① 巡逻
	var pp: Dictionary = _patrol_plan()
	if not pp.is_empty():
		out.append(_demand("扩展线", "巡逻", "基地外圈", 0, 0, int(pp.get("n", 1)), true,
				float(_model_call("demand_score_fixed", ["巡逻"])),
				"巡逻 %d 人" % int(pp.get("n", 1)), true,
				Callable(self, "_exec_patrol").bind(pp)))
	# ② 侦查（节流 20 s；固定分 1.0）
	if _scout_cd <= 0.0 and threat_n <= 0 and _idle_scout_unit() != null:
		out.append(_demand("扩展线", "侦查", "敌方方向", 0, 0, 1, true,
				float(_model_call("demand_score_fixed", ["侦查"])),
				"侦查 1 人", true, Callable(self, "_exec_scout")))
	# ③ 建塔（箭塔；有压家敌人时分数 ×(1+威胁)）
	var tid: StringName = _tower_id()
	if tid != &"" and not _has_site_of(tid):
		var td: UnitDef = Cfg.unit(tid)
		var pid: StringName = _primary_producer_id(diff)
		var twant: int = clampi(_faction.count_buildings(pid) / 2, 1, 2) if pid != &"" else 1
		if td != null and _faction.count_buildings(tid) < twant:
			out.append(_demand("扩展线", "建塔", String(td.display_name),
					int(td.gold_cost), int(td.wood_cost), 0, false,
					float(_model_call("demand_score_fixed", ["建塔"])) * (1.0 + float(threat_n)),
					"箭塔 %d/%d 座" % [_faction.count_buildings(tid), twant], true,
					Callable(self, "_exec_build_arrow_tower")))
	# ④ 建分基地（`can_build_townhall()` 固定 false → 本轮不会真的报出来；
	#    代码路径留着，2C-10 把开关打开就能进仲裁）
	if can_build_townhall():
		var hid: StringName = _main_base_id()
		var hd: UnitDef = Cfg.unit(hid) if hid != &"" else null
		if hd != null:
			out.append(_demand("扩展线", "建分基地", String(hd.display_name),
					int(hd.gold_cost), int(hd.wood_cost), 0, false,
					float(_model_call("demand_score_fixed", ["分基地"])),
					"分基地（接口预留）", false, Callable(self, "_exec_build_townhall")))
	return out


## 竞争计数（只记录：训练 vs 建造 / 出击 vs 巡逻 是否在同一周期里同时存在）
func _dept_note_competition() -> void:
	var has_train: bool = false
	var has_build: bool = false
	var has_push: bool = false
	var has_patrol: bool = false
	var req_written: int = 0
	for d in demands_l2:
		if not (d is Dictionary):
			continue
		match String((d as Dictionary).get("动作类型", "")):
			"训练":
				has_train = true
			"建造":
				has_build = true
			"出击":
				has_push = true
			"巡逻":
				has_patrol = true
		if bool((d as Dictionary).get("可被征用", false)):
			req_written += 1
	dept_stats["requisitionable_written"] = \
			int(dept_stats["requisitionable_written"]) + req_written
	if has_train and has_build:
		dept_stats["compete_train_build"] = int(dept_stats["compete_train_build"]) + 1
	if has_push and has_patrol:
		dept_stats["compete_push_patrol"] = int(dept_stats["compete_push_patrol"]) + 1


# ---------------------------------------------------------------------------
# 主部门：按仲裁结果顺序执行
# ---------------------------------------------------------------------------

func _dept_execute(plan: Dictionary) -> void:
	dept_stats["cycles"] = int(dept_stats["cycles"]) + 1
	dept_stats["demands"] = int(dept_stats["demands"]) + int(plan.get("总额", 0))
	# 2C-12 D 组哨兵：0 成本诉求被判「储备不足」的次数（正常恒 0）
	dept_stats["zero_cost_saving_rej"] = int(dept_stats.get("zero_cost_saving_rej", 0)) \
			+ int(plan.get("零成本储备驳回", 0))
	# 2C-11 P2：同时做事数的**实际分布**（每周期执行条数 -> 出现次数），
	# 与 caps_last 的上限表对照，回答"储蓄后真的同时做多件事了吗"。
	var done_n: int = int((plan.get("执行", []) as Array).size())
	var dist: Dictionary = dept_stats["exec_per_cycle"]
	var dk: String = str(done_n)
	dist[dk] = int(dist.get(dk, 0)) + 1
	var rej: Array = plan.get("驳回", [])
	dept_stats["rejected"] = int(dept_stats["rejected"]) + rej.size()
	var rj: Dictionary = dept_stats["reject_by_reason"]
	for d in rej:
		var r: String = String((d as Dictionary).get("驳回原因", ""))
		if not r.is_empty():
			rj[r] = int(rj.get(r, 0)) + 1
	for d in (plan.get("执行", []) as Array):
		var dd: Dictionary = d
		var action: String = String(dd.get("动作类型", ""))
		# 2C-12 §3.4：承诺生命周期 —— 执行前标「执行中」；失败回「有效」；
		# 成功标「已执行」并从表里删除（实际扣减已由 _sched.build / queue_train 完成）。
		var pkey: String = "%s|%s" % [action, String(dd.get("目标", ""))]
		var p_live: bool = _promise.has(pkey)
		if p_live:
			(_promise[pkey] as Dictionary)["状态"] = BM.PROMISE_RUNNING
		# 2C-10 §6：攒大波出击（`可被征用=true`）先征回临时防守兵，
		# 释放短租约锁 → 兵力并入本次出击 → 收尾统一转 wave 锁。
		_pending_requisition = 0
		var req_n: int = 0
		if action == "出击" and bool(dd.get("可被征用", false)):
			req_n = _requisition_temp_defense()
			_pending_requisition = req_n
		var ok: bool = true
		var cb = dd.get("执行", null)
		if cb is Callable:
			ok = bool((cb as Callable).call())
		_pending_requisition = 0
		if not ok:
			# 执行阶段失败：资源其实没花出去（下个周期按真实资源重判），按"条件不满足"记账
			rj["条件不满足"] = int(rj.get("条件不满足", 0)) + 1
			# 承诺回滚到「有效」，下个周期重试（仍受 TTL 约束，不会无限等）
			if p_live and _promise.has(pkey):
				(_promise[pkey] as Dictionary)["状态"] = BM.PROMISE_VALID
			continue
		dept_stats["executed"] = int(dept_stats["executed"]) + 1
		if p_live:
			_promise.erase(pkey)
			dept_stats["promise_consumed"] = int(dept_stats["promise_consumed"]) + 1
		match action:
			"训练":
				if String(dd.get("目标", "")) == "农民":
					dept_stats["win_train_peasant"] = int(dept_stats["win_train_peasant"]) + 1
				else:
					dept_stats["win_train"] = int(dept_stats["win_train"]) + 1
			"建造":
				dept_stats["win_build"] = int(dept_stats["win_build"]) + 1
			"出击":
				dept_stats["win_push"] = int(dept_stats["win_push"]) + 1
			"防守":
				dept_stats["win_defend"] = int(dept_stats["win_defend"]) + 1
			"巡逻":
				dept_stats["win_patrol"] = int(dept_stats["win_patrol"]) + 1
			"侦查":
				dept_stats["win_scout"] = int(dept_stats["win_scout"]) + 1
			"建塔":
				dept_stats["win_tower"] = int(dept_stats["win_tower"]) + 1
		# 兵力锁定：出击的锁跟着波次走（收尾时显式解锁），巡逻/侦查是短租约。
		# 2C-10 §6：征回来的 N 个兵一起转 wave 锁（释放 → 转锁，不重复占额度）。
		var t: int = int(dd.get("兵力占用", 0)) + req_n
		if t > 0:
			if action == "出击":
				_troop_lock("wave:%d" % _wave_index, t, DEPT_WAVE_LOCK_TTL, "wave")
			elif action == "巡逻":
				_troop_lock("patrol", t, DEPT_CYCLE * 1.5, "patrol")
			elif action == "侦查":
				_troop_lock("scout", t, DEPT_CYCLE * 1.5, "scout")
	dept_stats["reject_by_reason"] = rj
	_troop_lock_tick(Game.elapsed)


## L3 决策日志：每 2 s 一行（**只落盘，不进决策**）
func _dept_log(now: float, plan: Dictionary) -> void:
	if dept_log_path.is_empty():
		return
	var row: Dictionary = {
		"t": snappedf(now, 0.01),
		"阵营": String(_faction.display_name) if _faction != null else "?",
		"周期": int(dept_stats["cycles"]),
		"L0": {"金": int(ctx0.get("gold", 0)), "木": int(ctx0.get("wood", 0)),
			"人口": "%d/%d" % [int(ctx0.get("pop_used", 0)), int(ctx0.get("pop_cap", 0))],
			"兵力": int(ctx0.get("troops", 0)), "威胁": int(ctx0.get("threat", 0))},
		"L1": {"伤30s": snappedf(float(ctx1.get("dmg_30s", 0.0)), 0.1),
			"金速": snappedf(float(ctx1.get("gold_rate", 0.0)), 0.01),
			"木速": snappedf(float(ctx1.get("wood_rate", 0.0)), 0.01)},
		"诉求": [],
		"执行": [],
		"驳回": {},
		# 2C-11：储备线 / 同时做事数上限 / 紧急态（只落盘，不进决策）
		"储备": snappedf(float(dept_stats.get("saving_reserve_last", 0.0)), 0.1),
		"单件成本": snappedf(float(dept_stats.get("saving_unit_cost_last", 0.0)), 0.1),
		"上限": dept_stats.get("caps_last", {}),
		"紧急": bool(dept_stats.get("saving_urgent_last", false)),
		"紧急事由": dept_stats.get("saving_urgent_reasons_last", []),
		# 2C-13 §4：目标层（只落盘，不进决策）——
		# 判硬要回答"空过期间训练/建造/修理真的 0 执行"，必须有逐周期的空过标记，
		# 否则只能靠结构推断（结构性保证在回归里，观测得靠这一行）。
		"空过": goal_noop,
		"主目标": String(goal_main.get("id", "")),
		"主目标动作": String(goal_main.get("动作", "")),
		"主目标对象": String(goal_main.get("对象", "")),
		"主目标紧迫度": snappedf(float(goal_main.get("紧迫度", 0.0)), 0.01),
		"次目标": String(goal_sub.get("id", "")),
		"预留": int(goal_reserved.get("金币", 0)),
		"阈值": snappedf(float(_goal_thr), 0.01),
		# 2C-14 纯观测字段（只落盘，不进决策）：支撑 A/B/C 三组逐周期归因
		"决策路径": String(AIV.goal_mode()) if AIV.dept_on() else "dept_off",
		"次目标空": goal_sub.is_empty(),
		"次目标动作": String(goal_sub.get("动作", "")),
		"储备充足": int(ctx0.get("gold", 0)) >= float(dept_stats.get("saving_reserve_last", 0.0)),
		"承诺表条数": _promise.size(),
		# 2C-15 纯观测（只落盘）：AI-only 达成率 + 补选/冷却计数。
		# 分母只算 AI 阵营（副官是玩家阵营，这两项对它恒 0）。
		"AI达成率": snappedf(float(dept_stats.get("goal_metric_done", 0))
			/ maxf(float(dept_stats.get("goal_metric_total", 0)), 1.0), 0.01),
		"AI目标结束数": int(dept_stats.get("goal_metric_total", 0)),
		"次目标补选": int(dept_stats.get("goal_sub_refilled", 0)),
		"冷却跳过": int(dept_stats.get("goal_cd_skips", 0)),
		"世界": {"字段": int(dept_stats.get("ws_fields_last", 0)),
			"区域": int(dept_stats.get("ws_regions_last", 0))},
	}
	for d in demands_l2:
		if not (d is Dictionary):
			continue
		(row["诉求"] as Array).append({
			"线": String(d.get("来源线", "")), "动作": String(d.get("动作类型", "")),
			"目标": String(d.get("目标", "")),
			"分": snappedf(float(d.get("诉求分", 0.0)), 0.01),
			"金": int(d.get("金币成本", 0)), "木": int(d.get("木材成本", 0)),
			"兵": int(d.get("兵力占用", 0)),
		})
	for d in (plan.get("执行", []) as Array):
		(row["执行"] as Array).append("%s·%s" % [
			String((d as Dictionary).get("来源线", "")),
			String((d as Dictionary).get("动作类型", ""))])
	var rj: Dictionary = {}
	for k in (dept_stats["reject_by_reason"] as Dictionary).keys():
		rj[k] = int(dept_stats["reject_by_reason"][k])
	row["驳回"] = rj
	var fa := FileAccess.open(dept_log_path, FileAccess.READ_WRITE)
	if fa == null:
		return
	fa.seek_end()
	fa.store_line(JSON.stringify(row))
	fa.close()


# ---------------------------------------------------------------------------
# 执行器（每个都返回 bool：true = 命令/扣费真的发生了）
# ---------------------------------------------------------------------------

func _exec_train_peasant() -> bool:
	if _faction == null:
		return false
	var wid: StringName = _worker_id()
	var hall: RtsBuilding = _first_building(_main_base_id())
	if hall == null or wid == &"":
		return false
	if hall.train_count() >= MAX_QUEUE_PEASANT:
		return false
	if not hall.queue_train(wid):
		return false
	_log("排农民（部门仲裁，现有 %d）" % _faction.count_units(wid))
	return true


func _exec_train_army(b: RtsBuilding, picked: StringName) -> bool:
	if b == null or not is_instance_valid(b) or not b.is_alive():
		return false
	if b.train_count() >= MAX_QUEUE_ARMY:
		return false
	if not b.can_train(picked):
		return false
	if not b.queue_train(picked):
		return false
	var ud: UnitDef = Cfg.unit(picked)
	if ud != null:
		invest_stats["army_gold"] = int(invest_stats["army_gold"]) + int(ud.gold_cost)
		invest_stats["army_wood"] = int(invest_stats["army_wood"]) + int(ud.wood_cost)
	return true


func _exec_build_farm() -> bool:
	var fid: StringName = _food_building_id()
	if fid == &"" or _faction == null:
		return false
	var d: UnitDef = Cfg.unit(fid)
	if d == null:
		return false
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		_note_farm_fail("no_builder")
		return false
	var spot: Vector3 = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		_note_farm_fail("no_spot")
		return false
	if not _can_spend(fid):
		if _faction.wood < int(d.wood_cost):
			_note_farm_fail("no_wood")
		else:
			_note_farm_fail("no_gold")
		return false
	var site: Node3D = _sched.build(builder, d, spot, _build_yaw_at(spot), "economy")
	if site == null:
		return false
	_note_build(fid)
	_farm_sites[site.get_instance_id()] = true
	_log("造农场（部门仲裁，人口 %d/%d）" % [_faction.food_used(), _faction.food_cap()])
	return true


func _exec_build_barracks() -> bool:
	if _faction == null:
		return false
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	var pid: StringName = _primary_producer_id(diff)
	if pid == &"":
		return false
	var bd: UnitDef = Cfg.unit(pid)
	if bd == null or not Game.can_afford(_faction, pid):
		return false
	# 必须留足"新兵营一完工就能立刻出一个兵"的钱（2C-6 起的老规矩，未改）
	var reserve: int = _cheapest_army_gold(diff) * MAX_QUEUE_ARMY
	if _faction.gold < int(bd.gold_cost) + reserve:
		return false
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return false
	var spot: Vector3 = _find_build_spot(bd.footprint)
	if spot == Vector3.INF:
		return false
	if _sched.build(builder, bd, spot, _build_yaw_at(spot), "economy") == null:
		return false
	_note_build(pid)
	_log("扩建%s（部门仲裁）" % bd.display_name)
	return true


func _exec_build_watchtower() -> bool:
	if _faction == null:
		return false
	var wid: StringName = _watchtower_id()
	if wid == &"":
		return false
	var d: UnitDef = Cfg.unit(wid)
	if d == null or not _can_spend(wid):
		return false
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return false
	var spot: Vector3 = _frontier_spot(d.footprint, 24.0, 34.0)
	if spot == Vector3.INF:
		spot = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return false
	if _sched.build(builder, d, spot, _build_yaw_at(spot), "defense") == null:
		return false
	_note_build(wid)
	_log("造哨塔扩视野（部门仲裁）")
	return true


func _exec_build_arrow_tower() -> bool:
	if _faction == null:
		return false
	var tid: StringName = _tower_id()
	if tid == &"":
		return false
	var td: UnitDef = Cfg.unit(tid)
	if td == null or not _can_spend(tid):
		return false
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return false
	var spot: Vector3 = _find_build_spot(td.footprint)
	if spot == Vector3.INF:
		return false
	if _sched.build(builder, td, spot, _build_yaw_at(spot), "economy") == null:
		return false
	_note_build(tid)
	_log("补箭塔（部门仲裁）")
	return true


func _exec_build_campfire() -> bool:
	if _faction == null:
		return false
	var cid: StringName = _campfire_id()
	if cid == &"":
		return false
	var d: UnitDef = Cfg.unit(cid)
	if d == null or not _can_spend(cid):
		return false
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return false
	var spot: Vector3 = _frontier_spot(d.footprint, 10.0, 16.0)
	if spot == Vector3.INF:
		spot = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return false
	if _sched.build(builder, d, spot, _build_yaw_at(spot), "night") == null:
		return false
	_note_build(cid)
	_log("夜里点营火（部门仲裁）")
	return true


func _exec_build_extra(id: StringName) -> bool:
	if _faction == null:
		return false
	var d: UnitDef = Cfg.unit(id)
	if d == null or not _can_spend(id):
		return false
	var builder: RtsUnit = _pick_builder()
	if builder == null:
		return false
	var spot: Vector3 = _find_build_spot(d.footprint)
	if spot == Vector3.INF:
		return false
	if _sched.build(builder, d, spot, _build_yaw_at(spot), "tech") == null:
		return false
	_note_build(id)
	_log("扩建%s（部门仲裁）" % d.display_name)
	return true


func _exec_build_townhall() -> bool:
	# 接口预留：`can_build_townhall()` 固定 false，本函数当前**不可达**（回归断言守住）
	return false


func _exec_repair(rb: RtsBuilding, deficit: float) -> bool:
	if _faction == null or rb == null or not is_instance_valid(rb) or not rb.is_alive():
		return false
	var slots: Array = _builder_units()
	var free: Array = []
	for s in slots:
		var o: int = int(s.order)
		if o == RtsConst.Order.BUILD or o == RtsConst.Order.REPAIR:
			continue
		free.append(s)
	if free.is_empty():
		if slots.is_empty():
			repair_stats["blocked_no_builder"] = \
					int(repair_stats.get("blocked_no_builder", 0)) + 1
		else:
			repair_stats["blocked_builder_busy"] = \
					int(repair_stats.get("blocked_builder_busy", 0)) + 1
		return false
	if int(rb.call("repair_wood_for_full")) > _faction.wood:
		repair_stats["blocked_wood"] = int(repair_stats.get("blocked_wood", 0)) + 1
		return false
	return _do_repair(free[0], rb, deficit)


func _exec_wave(p: Dictionary) -> bool:
	# 2C-10 §6：被征用的临时防守兵并入出击规模（+N）；锁由 _dept_execute 转 wave
	if _pending_requisition > 0:
		p["push_n"] = int(p.get("push_n", 0)) + _pending_requisition
		_pending_requisition = 0
	return _issue_wave_plan(p)


func _exec_defend(p: Dictionary) -> bool:
	var ok: bool = _issue_defend(p)
	if ok:
		# 2C-10 §6：回防的兵挂"临时防守"短租约锁，攒大波时可被征用。
		# 固定 key（不是每波一个）→ 重复回防覆盖旧锁，不累积。
		_troop_lock("temp_defense", int(p.get("n", 0)), DEPT_CYCLE * 3.0, "temp_defense")
	return ok


func _exec_patrol(p: Dictionary) -> bool:
	return _issue_patrol(p)


func _idle_scout_unit() -> RtsUnit:
	for u in _army_units():
		if u != null and is_instance_valid(u) and bool(u.call("is_idle_like")):
			return u
	return null


## 侦查：派 1 个闲着的兵朝敌方方向走 45 m（纯移动，不交战；到点自动变回 idle）
func _exec_scout() -> bool:
	if _faction == null or _scout_cd > 0.0:
		return false
	var u: RtsUnit = _idle_scout_unit()
	if u == null:
		return false
	var home: Vector3 = RtsWorld.base_center(_faction)
	var dir := Vector3.FORWARD
	var foe: RtsFaction = _foe_faction()
	if foe != null:
		var to: Vector3 = RtsWorld.base_center(foe) - home
		to.y = 0.0
		if to.length() > 1.0:
			dir = to.normalized()
	_scout_seq += 1
	var off: float = (_dhash01(_scout_seq, 41) - 0.5) * 0.8
	var ang: float = atan2(dir.x, dir.z) + off
	var p: Vector3 = home + Vector3(sin(ang), 0.0, cos(ang)) * 45.0
	_sched.move([u], p, "scout")
	_scout_cd = SCOUT_INTERVAL
	return true


## "这个 id 有没有正在施工的工地"（与 `_maybe_build_one` 的"在建不重复盖"同口径）
func _has_site_of(id: StringName) -> bool:
	if _faction == null:
		return false
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		if b.def.id != id:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and rb.is_alive() and not rb.is_constructed:
			return true
	return false


## 农场"急建"通道（人口余量 <4 或占用 >90%）
func _farm_urgent() -> bool:
	if _faction == null:
		return false
	var headroom: int = _faction.food_cap() - _faction.food_used()
	return headroom < 4 or _pop_critical()


## 农场"不急"通道（人口预判：占用>70% / 60 s 训练量×2 / 连一个兵都排不下）
func _farm_wanted(diff: DifficultyDef) -> bool:
	if _faction == null:
		return false
	var headroom: int = _faction.food_cap() - _faction.food_used()
	if headroom < 4:
		return false
	return _need_farm(diff) or _need_more_farm(diff)


## 关键决策日志（带统一前缀）
func _log(msg: String) -> void:
	print("%s %s" % [log_prefix, msg])


## 2C-9：**并发修理探针**（2C-8 的 `_qa/probe_2c8_repair.gd` 转正）。
##
## 做法（与 2C-8 探针同一口径）：把两栋**已完工**的自有建筑各打到 `max_hp − 250`，
## 然后手动调一次修理派工，断言 `targets==2 && repairing==2 && distinct==2 && issued==2`。
##
## 为什么要转正：2C-8 的探针是临时挂在 `主场景.gd` 上的一个 `_qa/` 脚本（不入库、跑完撤掉），
## 于是"并发修理"这条能力每轮都要重写一遍。现在收成一个公开方法，
## 由 `--qa-repair-probe` 在基准里定点调用（见 AI基准.gd），命令固定、结果可复现。
func qa_repair_probe() -> Dictionary:
	if _faction == null:
		return {"ok": false, "why": "无阵营"}
	var two: Array = []
	for b in _faction.buildings:
		if b == null or not is_instance_valid(b) or b.def == null:
			continue
		var rb: RtsBuilding = b as RtsBuilding
		# ★ 不能先判 `can_repair()`：它的语义是"血量已经掉了"（hp < max_hp−0.5），
		#   满血的楼一律 false —— 2C-8 探针踩过同一个坑（那时候是先打血再判）。
		if rb == null or not rb.is_constructed or not rb.is_alive():
			continue
		if float(rb.def.max_hp) <= 251.0:
			continue
		two.append(rb)
		if two.size() >= 2:
			break
	if two.size() < 2:
		return {"ok": false, "why": "需要 2 栋已完工且可修的建筑（当前 %d）" % two.size()}
	for rb2 in two:
		rb2.hp = maxf(float(rb2.def.max_hp) - 250.0, 1.0)
	var pack: Dictionary = _repair_candidates()
	var list: Array = pack.get("cands", [])
	var before: int = int(repair_stats.get("issued", 0))
	# ★ 探针只测"**通路**能不能同时派 2 个工位"，不测"工位忙不忙"：
	#   2C-8 的做法是冻结副官自动思考（整局不动）；这里只把工位手上的
	#   建造/修理停掉，影响面更小、也不用改主循环。
	#   （第一版直接调 `_issue_repairs_multi`，长局里 2 个工位有 1 个正在盖农场，
	#     于是恒得 1/2 —— 那是"场景依赖"，不是通路问题，见报告 §4。）
	var slots: Array = _builder_units()
	if slots.size() < 2:
		return {"ok": false, "why": "工位数 < 2（当前 %d）" % slots.size()}
	var duo: Array = []
	for s in slots:
		if s == null or not is_instance_valid(s):
			continue
		if int(s.order) == RtsConst.Order.BUILD or int(s.order) == RtsConst.Order.REPAIR:
			_sched.stop([s], "probe")
		duo.append(s)
	_sched.flush()
	var n_pair: int = mini(list.size(), duo.size())
	for i in range(n_pair):
		var c: Dictionary = list[i]
		_do_repair(duo[i], c["b"], float(c["deficit"]))
	var issued: int = int(repair_stats.get("issued", 0)) - before
	var repairing: int = 0
	var distinct: Dictionary = {}
	for w in _workers():
		if w == null or not is_instance_valid(w):
			continue
		if int(w.order) != RtsConst.Order.REPAIR:
			continue
		var rt = w.get("_repair_target")
		if rt == null or not is_instance_valid(rt):
			continue
		repairing += 1
		distinct[rt.get_instance_id()] = true
	var ok: bool = list.size() == 2 and repairing == 2 \
			and distinct.size() == 2 and issued == 2
	return {
		"targets": list.size(), "repairing": repairing,
		"distinct": distinct.size(), "issued": issued, "ok": ok,
	}


## 2C-6：建造下单计数（成功下达才记）。报告/bench 读 build_stats。
## 2C-7 P2：顺带记"农场投资"（只记农场，用于"农场 vs 军队预算"曲线；
##   兵营/哨塔/伐木场归"其它"，不进这两条曲线 —— 口径越窄越不容易被误读）。
func _note_build(id: StringName) -> void:
	build_stats[String(id)] = int(build_stats.get(String(id), 0)) + 1
	if _faction == null or _food_building_id() == &"" or id != _food_building_id():
		return
	var d: UnitDef = Cfg.unit(id)
	if d == null:
		return
	invest_stats["farm_gold"] = int(invest_stats["farm_gold"]) + int(d.gold_cost)
	invest_stats["farm_wood"] = int(invest_stats["farm_wood"]) + int(d.wood_cost)


## 2C-7 P2：投资占比采样（**只记录，不自动调整**）。
##
## 口径（写清是为了下一轮能改）：
##   · 分子 = 本采样周期内**新花出去**的农场/军队成本（金+木合计）；
##   · 分母 = `income_60s(now) × 60` = 最近 60 s 的总资源收入（金+木，与成本同口径）；
##   · 采样间隔 60 s。`farm_ratio > 0.4 连续 3 个采样点` → `over_invest_60s` 计数（只标警）。
##
## 为什么用 60 s 增量而不是累计：累计占比从第 5 分钟起就被前期的钱锁死，
## 后面再怎么看都是同一个数 —— 看不到"这一分钟是不是全砸农场了"。
func _track_invest(now: float) -> void:
	if _faction == null or _invest_cd > 0.0:
		return
	_invest_cd = INVEST_SAMPLE_SEC
	var income: float = maxf(income_60s(now) * 60.0, 1.0)
	var farm_total: int = int(invest_stats["farm_gold"]) + int(invest_stats["farm_wood"])
	var army_total: int = int(invest_stats["army_gold"]) + int(invest_stats["army_wood"])
	var prev_farm: int = int(_invest_prev.get("farm", 0))
	var prev_army: int = int(_invest_prev.get("army", 0))
	_invest_prev = {"farm": farm_total, "army": army_total}
	var farm_ratio: float = float(farm_total - prev_farm) / income
	var army_ratio: float = float(army_total - prev_army) / income
	var samples: Array = invest_stats["samples"]
	samples.append({
		"t": snappedf(now, 0.1),
		"farm_ratio": snappedf(farm_ratio, 0.001),
		"army_ratio": snappedf(army_ratio, 0.001),
		"farm_gold": farm_total, "army_gold": army_total,
		"income_60s": snappedf(income, 0.1),
	})
	while samples.size() > 40:
		samples.pop_front()
	# "农场过度投资"告警：连续 3 个采样点 >40%
	var n: int = samples.size()
	if n >= 3 and float(samples[n - 1]["farm_ratio"]) > 0.4 \
			and float(samples[n - 2]["farm_ratio"]) > 0.4 \
			and float(samples[n - 3]["farm_ratio"]) > 0.4:
		invest_stats["over_invest_60s"] = int(invest_stats["over_invest_60s"]) + 1

## "为什么不出击"的短诊断（日志用）。
## 2C-2 起出击许可只剩两条否决，所以这里把"威胁 / 侵略性"放最前；
## 兵比仍然打出来，但标注**仅记录**（它已经不参与判断，别再据此调门槛）。
func _block_reason() -> String:
	var m: Dictionary = posture.get("metrics", metrics)
	return "威胁=%.0f 侵略=%.2f 兵比=%.2f(仅记录) 军值=%.0f 兵口=%.0f 敌静态=%.0f" % [
		float(m.get("base_threat", 0.0)), float(posture.get("aggression", 0.0)),
		float(m.get("army_ratio", 0.0)), float(m.get("my_army_value", 0.0)),
		float(m.get("army_food", 0.0)), float(m.get("enemy_static_defense", 0.0))]


## 调试/自检：一句话说清 AI 现在在想什么
func debug_string() -> String:
	var plan: String = String(posture.get("plan_id", "-"))
	var ratio: float = float(metrics.get("army_ratio", 0.0))
	var sent: int = 0
	var skipped: int = 0
	if _sched != null:
		var st: Dictionary = _sched.stats()
		sent = int(st.get("sent", 0))
		skipped = int(st.get("skipped", 0))
	var who: String = _faction.display_name if _faction != null else "?"
	return "%s 计划=%s 兵比=%.2f 军=%d 农=%d 令=%d 略=%d" % [
		who, plan, ratio,
		int(metrics.get("army_count", 0)), int(metrics.get("workers", 0)), sent, skipped]
