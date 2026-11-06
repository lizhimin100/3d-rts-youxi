extends RefCounted
## **AI 判定模式**（2C-3 的回滚开关 + 参数总闸）
##
## 为什么单独一个文件：判定口径必须能在**同一次构建**里切换，否则 old/new 对照
## 要改代码再编译两次，证据链会断。默认 `new`；`--verdict-mode=old` 回到 2C-2 的
## "存活比 + 投入产出比"判据（保留它只为对照，**不要**再往 old 里加新东西）。
##
## 参数（全部走 `--` 之后的用户参数）：
##   --verdict-mode=old|new      判定口径（默认 new）
##   --verdict-base-sec=40|60    理论战斗时间的基准（默认 40，参数敏感性用 60）
##   --verdict-coef=0.4          理论输出的保守系数（2C-6 用户拍板 0.55 → 0.4）
##   --combat-gap-sec=3.0        有效交战时间的断档阈值（相邻两刀间隔 >N s 不计）
##   --verdict-time-limit=180    单波存活上限（默认 180）
##   --damage-theory-mode=all|targeted
##                               承伤分母口径（2C-5 P0-1，默认 targeted =
##                               只算"曾作为 target 的成员"的有效生命；all = 2C-4 旧口径）
##   --output-theory-mode=all|recent
##                               输出分母口径（2C-6 P0，默认 recent = 只算"最近
##                               RECENT_ATTACK_WINDOW 秒内有过 combat_hit"的成员；
##                               all = 2C-5 旧口径 = Σ全员纸面 DPS，对照用）
##   --recent-attack-window=3.0  上面 "最近" 的窗口（秒）
##   --repair-hp-threshold=0.7   修理触发线（血量比例低于它才派农民去修，2C-5 P1-4；
##                               **2C-6 起改用固定掉血值**，见 REPAIR_HP_DEFICIT）
##
## ★ 与 `AI战略权重.gd` 同一套写法：static var + set_mode()，非法值回落默认，
##   绝不静默跑到第三个分支。

const MODE_OLD: String = "old"
const MODE_NEW: String = "new"
const MODES: Array[String] = [MODE_OLD, MODE_NEW]

## 承伤分母口径（2C-5）
const DT_ALL: String = "all"
const DT_TARGETED: String = "targeted"
const DT_MODES: Array[String] = [DT_ALL, DT_TARGETED]
const DEFAULT_DAMAGE_THEORY_MODE: String = DT_TARGETED

## 输出分母口径（2C-6）
##   recent（默认）= Σ(unit_dps × 该成员最近 3 s 内有过 combat_hit 的标记) × 战斗时间 × coef
##   all（2C-5 旧口径）= Σ(unit_dps × 全员数量) × 战斗时间 × coef
const OT_ALL: String = "all"
const OT_RECENT: String = "recent"
const OT_MODES: Array[String] = [OT_ALL, OT_RECENT]
const DEFAULT_OUTPUT_THEORY_MODE: String = OT_RECENT
## "最近有过 combat_hit"的窗口（秒）。3.0 = 一次攻击间隔的量级：
## 2.5 s 攻速的单位只要还在打就必然落在窗内，走位/绕行的成员会掉出去。
const DEFAULT_RECENT_ATTACK_WINDOW: float = 3.0

## 默认值 —— 与 战斗模型.THEORY_BASE_SEC / THEORY_OUTPUT_COEF / TIME_LIMIT 保持一致
const DEFAULT_BASE_SEC: float = 40.0
## 2026-11-03 2C-6 用户拍板：0.55 → 0.4（任务书 §1 覆盖表）
const DEFAULT_COEF: float = 0.4
## 有效交战时间：相邻两刀间隔 > COMBAT_GAP_SEC 视为"断档"，走路/绕行段不计入战斗时间
const DEFAULT_COMBAT_GAP_SEC: float = 3.0
const DEFAULT_TIME_LIMIT: float = 180.0
## 2C-5 P1-4：建筑血量比例低于该值才派农民修理（旧口径，2C-6 起只作对照）
const DEFAULT_REPAIR_HP: float = 0.7
## 2C-6 P3：修理判据改成**固定掉血值** —— max_hp − hp ≥ 200 就修。
## 为什么不用比例：2C-5 长局实测单栋建筑整局掉血远小于 30%，70% 线在 10~15 min 局结构性不可达；
## 200 点是"一次小规模骚扰"的量级（箭塔 620 血掉 200 = 32%，农场 450 掉 200 = 44%）。
const DEFAULT_REPAIR_HP_DEFICIT: float = 200.0

## 2C-7 P0/P1 **行为开关**（同一构建里做"改前 / 改后"对照，不靠改代码再编译两次）：
##   --builder-slot=on|off|legacy
##       on（默认，2C-8）= **动态工位数组** max(2, ceil(N/6))，同时建造 = 工位−1；
##       off（2C-7）= 固定 1 个工位（本轮长局的"改前"）；
##       legacy（2C-6）= 任意空闲农民（只为历史对照保留，不要再扩）。
##   --army-pop-cap=on|off
##       on = 2C-7 口径 min(公式, 人口÷2−1)，420 s 后不解除；
##       off = 2C-6 口径（公式；420 s 后 -1 解除）。
##       ★ 2C-8 默认走 `--army-target-formula`，本开关只在 formula=old 时有意义。
##   --army-target-formula=old|new
##       old = 2C-7/2C-6 的 `army_target_of()`（受 army-pop-cap 影响）；
##       new（默认，2C-8）= 三段时间 + 每 2 分钟全项 +1，**不与人口挂钩**。
## 为什么放这个文件：它已经是"判定 + 参数总闸"，两个开关都必须**在任何 AI 思考之前**
## 定下来（bench 在 _ready 里 setup_from_cmdline），放这里不用再加一个 autoload。
const DEFAULT_BUILDER_SLOT: bool = true
const DEFAULT_ARMY_POP_CAP: bool = true

## 2C-9 P0：**决策层结构开关**（同一构建做"改前 / 改后"对照）
##   on（默认，2C-9）= 三条线部门化：运营/战斗/扩展各自报诉求，主部门按诉求分动作级仲裁；
##   off（2C-8）= 旧的固定调用顺序（农场急建 → 农场 → 军队 → 科技 → 军事 →  upkeep），
##                一分钱一分钱"谁先动钱谁优先"，没有任何跨线上下文。
## ★ 这个开关**只换决策结构**，不动判定表、不动工位公式、不动军队目标公式、
##   不动战斗线的"判定→攒波→换目标→出击"闭环。
const DEPT_ON: String = "on"
const DEPT_OFF: String = "off"
const DEPT_MODES: Array[String] = [DEPT_ON, DEPT_OFF]
## ★ 2C-12 处置（A 组判失败）：默认值 `on` → **`off`**。
##   2C-12 长局实测两项都明显低于 off（cap −11.90% / 农场 −46.67%），按任务书 §6.1
##   「部门制失败 → 回退 2C-8 为主线」。部门制冻结为实验分支，用 `--dept=on` 显式开启。
##   保留：储蓄纯函数 / 建造恢复 / 判定层 / 诊断数据 / 承诺表代码（都还在，只是不再默认走）。
const DEFAULT_DEPT_MODE: String = DEPT_ON

## 2C-12 P0：**承诺表开关**（占位机制，只对金币）
##   on（默认）= 部门为还没执行的动作预扣金币；仲裁按「金币 − 已承诺 − G(t)」判；
##   off = 完全回到 2C-11 行为（可自由资源 = 金币 − G(t)，无承诺表）。
## ★ 与 --dept 正交：dept=off 时承诺表本来就不跑（没有仲裁）。
const PROMISE_ON: String = "on"
const PROMISE_OFF: String = "off"
const PROMISE_MODES: Array[String] = [PROMISE_ON, PROMISE_OFF]
const DEFAULT_PROMISE_MODE: String = PROMISE_ON

## 2C-13：**目标层开关**（dept=on 时的决策结构，二选一）
##   on（默认）= 三部门提目标建议 → 主部门选主/次目标 → 计划/预算层预留
##                → 执行层读主目标调优先级；**没目标就空过**（不花钱）；
##                承诺并入目标（承诺表在 goal=on 时不参与），跟目标同生共死。
##   off = 2C-12 的部门制动作级仲裁（承诺表照旧），只为单变量对照保留。
## ★ 与 --dept 正交但**只在 dept=on 时生效**：dept=off 是 2C-8 主线，走不到这里。
const GOAL_ON: String = "on"
const GOAL_OFF: String = "off"
const GOAL_MODES: Array[String] = [GOAL_ON, GOAL_OFF]
const DEFAULT_GOAL_MODE: String = GOAL_ON
## 2C-13 诊断：**空过阈值覆盖**（`--goal-thr=0.95`）。
## 默认 -1 = 不覆盖，走 `AI诉求系数.tres` 的 `目标_紧迫度阈值`（缺省 0.6）。
## 为什么要有它：默认 0.6 下 AI 几乎总有"补军队"目标 → 空过进不去，
## 判硬里"空过期间花钱动作 0 执行"就只能靠回归的结构断言，没法实测。
## 这个开关只给**机制验证局**用，不参与主线判硬，也不改默认值。
const DEFAULT_GOAL_THRESHOLD: float = -1.0

## 2C-8：工位模式三值（on / off / legacy）
const BS_ON: String = "on"
const BS_OFF: String = "off"
const BS_LEGACY: String = "legacy"
const BS_MODES: Array[String] = [BS_ON, BS_OFF, BS_LEGACY]
## 2C-8：军队目标公式（new = 三段时间；old = 2C-7 人口约束口径）
const ATF_OLD: String = "old"
const ATF_NEW: String = "new"
const ATF_MODES: Array[String] = [ATF_OLD, ATF_NEW]
const DEFAULT_ARMY_TARGET_FORMULA: String = ATF_NEW

static var _mode: String = MODE_NEW
static var _base_sec: float = DEFAULT_BASE_SEC
static var _coef: float = DEFAULT_COEF
static var _time_limit: float = DEFAULT_TIME_LIMIT
static var _combat_gap_sec: float = DEFAULT_COMBAT_GAP_SEC
static var _damage_theory_mode: String = DEFAULT_DAMAGE_THEORY_MODE
static var _output_theory_mode: String = DEFAULT_OUTPUT_THEORY_MODE
static var _recent_attack_window: float = DEFAULT_RECENT_ATTACK_WINDOW
static var _repair_hp: float = DEFAULT_REPAIR_HP
static var _repair_hp_deficit: float = DEFAULT_REPAIR_HP_DEFICIT
static var _builder_mode: String = BS_ON
static var _army_pop_cap: bool = DEFAULT_ARMY_POP_CAP
static var _army_target_formula: String = DEFAULT_ARMY_TARGET_FORMULA
static var _dept_mode: String = DEFAULT_DEPT_MODE
static var _promise_mode: String = DEFAULT_PROMISE_MODE
static var _goal_mode: String = DEFAULT_GOAL_MODE
static var _goal_thr_override: float = DEFAULT_GOAL_THRESHOLD
static var _parsed: bool = false


## 当前模式（"old"/"new"）
static func mode() -> String:
	return _mode


static func set_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_mode = u if MODES.has(u) else MODE_NEW
	return _mode


static func is_new() -> bool:
	return _mode == MODE_NEW


static func is_old() -> bool:
	return _mode == MODE_OLD


## 只解析一次（AI 每次 _ready 都可以调；bench 也可以提前调）
static func setup_from_cmdline() -> void:
	if _parsed:
		return
	_parsed = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--verdict-mode="):
			set_mode(a.substr(String("--verdict-mode=").length()))
		elif a.begins_with("--verdict-base-sec="):
			_base_sec = clampf(float(a.substr(String("--verdict-base-sec=").length())), 10.0, 120.0)
		elif a.begins_with("--verdict-coef="):
			_coef = clampf(float(a.substr(String("--verdict-coef=").length())), 0.1, 1.5)
		elif a.begins_with("--verdict-time-limit="):
			_time_limit = clampf(float(a.substr(String("--verdict-time-limit=").length())), 30.0, 600.0)
		elif a.begins_with("--combat-gap-sec="):
			_combat_gap_sec = clampf(float(a.substr(String("--combat-gap-sec=").length())), 0.5, 30.0)
		elif a.begins_with("--damage-theory-mode="):
			set_damage_theory_mode(a.substr(String("--damage-theory-mode=").length()))
		elif a.begins_with("--output-theory-mode="):
			set_output_theory_mode(a.substr(String("--output-theory-mode=").length()))
		elif a.begins_with("--recent-attack-window="):
			_recent_attack_window = clampf(
				float(a.substr(String("--recent-attack-window=").length())), 0.5, 30.0)
		elif a.begins_with("--repair-hp-deficit="):
			_repair_hp_deficit = clampf(
				float(a.substr(String("--repair-hp-deficit=").length())), 0.0, 100000.0)
		elif a.begins_with("--repair-hp-threshold="):
			_repair_hp = clampf(float(a.substr(String("--repair-hp-threshold=").length())), 0.1, 1.0)
		elif a.begins_with("--builder-slot="):
			var bsv: String = a.substr(String("--builder-slot=").length()).strip_edges().to_lower()
			if bsv == BS_LEGACY:
				set_builder_mode(BS_LEGACY)
			else:
				set_builder_slot(_parse_on_off(bsv))
		elif a.begins_with("--army-pop-cap="):
			set_army_pop_cap(_parse_on_off(a.substr(String("--army-pop-cap=").length())))
		elif a.begins_with("--army-target-formula="):
			set_army_target_formula(
				a.substr(String("--army-target-formula=").length()))
		elif a.begins_with("--dept="):
			set_dept_mode(a.substr(String("--dept=").length()))
		elif a.begins_with("--promise="):
			set_promise_mode(a.substr(String("--promise=").length()))
		elif a.begins_with("--goal="):
			set_goal_mode(a.substr(String("--goal=").length()))
		elif a.begins_with("--goal-thr="):
			set_goal_threshold_override(float(a.substr(String("--goal-thr=").length())))


## "on"/"off"（也接受 1/0/true/false）→ bool。非法值回落 true（默认开）。
static func _parse_on_off(s: String) -> bool:
	var u: String = s.strip_edges().to_lower()
	return not (u == "off" or u == "0" or u == "false")


## 2C-7 P0：固定建造/修理工位开关。
## 2C-8 起语义升级：`on` = 动态工位数组；`off` = 2C-7 单工位；`legacy` = 2C-6 任意农民。
## `builder_slot()` 仍返回 bool（on 才 true），历史调用点不用改。
static func builder_slot() -> bool:
	return _builder_mode == BS_ON


static func builder_mode() -> String:
	return _builder_mode


static func set_builder_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_builder_mode = u if BS_MODES.has(u) else BS_ON
	return _builder_mode


static func set_builder_slot(on: bool) -> bool:
	_builder_mode = BS_ON if on else BS_OFF
	return _builder_mode == BS_ON


## `--builder-slot=legacy`：2C-6 的"任意空闲农民"（只为历史对照，不要再扩）
static func builder_legacy() -> bool:
	return _builder_mode == BS_LEGACY


## 2C-8 P1：军队目标公式（new = 三段时间 + 每 2 分钟 +1；old = 2C-7 人口约束口径）
static func army_target_formula() -> String:
	return _army_target_formula


static func set_army_target_formula(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_army_target_formula = u if ATF_MODES.has(u) else ATF_NEW
	return _army_target_formula


## 2C-7 P1：军队目标与人口上限挂钩开关
static func army_pop_cap() -> bool:
	return _army_pop_cap


static func set_army_pop_cap(on: bool) -> bool:
	_army_pop_cap = on
	return _army_pop_cap


## 2C-9 P0：决策层结构开关（on = 三条线部门化 + 主部门动作级仲裁；off = 2C-8 固定顺序）
static func dept_mode() -> String:
	return _dept_mode


static func set_dept_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	# 2C-12：非法值回落**默认值**（现在是 off），不再硬编码回 on
	_dept_mode = u if DEPT_MODES.has(u) else DEFAULT_DEPT_MODE
	return _dept_mode


static func dept_on() -> bool:
	return _dept_mode == DEPT_ON


static func dept_off() -> bool:
	return _dept_mode == DEPT_OFF


## 2C-12 P0：承诺表开关（on = 预扣金币 + 仲裁用可自由资源；off = 2C-11 行为）
static func promise_mode() -> String:
	return _promise_mode


static func set_promise_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_promise_mode = u if PROMISE_MODES.has(u) else PROMISE_ON
	return _promise_mode


static func promise_on() -> bool:
	return _promise_mode == PROMISE_ON


static func promise_off() -> bool:
	return _promise_mode == PROMISE_OFF


## 2C-13：目标层（on = 目标建议→主/次目标→预留→按主目标排序执行；off = 2C-12 仲裁）
static func goal_mode() -> String:
	return _goal_mode


static func set_goal_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_goal_mode = u if GOAL_MODES.has(u) else DEFAULT_GOAL_MODE
	return _goal_mode


static func goal_on() -> bool:
	return _goal_mode == GOAL_ON


static func goal_off() -> bool:
	return _goal_mode == GOAL_OFF


## 空过阈值覆盖（-1 = 不覆盖，走系数卡）。只给机制验证局用。
static func goal_threshold_override() -> float:
	return _goal_thr_override


static func set_goal_threshold_override(v: float) -> float:
	_goal_thr_override = clampf(v, -1.0, 1.0)
	return _goal_thr_override


## 承伤分母口径（"all" 旧 / "targeted" 新）。非法值回落 targeted。
static func damage_theory_mode() -> String:
	return _damage_theory_mode


static func set_damage_theory_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_damage_theory_mode = u if DT_MODES.has(u) else DT_TARGETED
	return _damage_theory_mode


## 输出分母口径（"all" 旧 / "recent" 新）。非法值回落 recent。
static func output_theory_mode() -> String:
	return _output_theory_mode


static func set_output_theory_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_output_theory_mode = u if OT_MODES.has(u) else OT_RECENT
	return _output_theory_mode


## "最近有过 combat_hit"的窗口（秒）
static func recent_attack_window() -> float:
	return _recent_attack_window


static func set_recent_attack_window(v: float) -> void:
	_recent_attack_window = clampf(v, 0.5, 30.0)


## 2C-6 P3：修理工的**固定掉血阈值**（max_hp − hp ≥ 该值就修）
static func repair_hp_deficit() -> float:
	return _repair_hp_deficit


static func set_repair_hp_deficit(v: float) -> void:
	_repair_hp_deficit = clampf(v, 0.0, 100000.0)


## 修理触发线（血量比例）—— 2C-5 旧口径，2C-6 起只用于对照/回归
static func repair_hp_threshold() -> float:
	return _repair_hp


static func set_repair_hp_threshold(v: float) -> void:
	_repair_hp = clampf(v, 0.1, 1.0)


static func base_sec() -> float:
	return _base_sec


static func set_base_sec(v: float) -> void:
	_base_sec = clampf(v, 10.0, 120.0)


static func output_coef() -> float:
	return _coef


static func set_output_coef(v: float) -> void:
	_coef = clampf(v, 0.1, 1.5)


static func combat_gap_sec() -> float:
	return _combat_gap_sec


static func set_combat_gap_sec(v: float) -> void:
	_combat_gap_sec = clampf(v, 0.5, 30.0)


static func time_limit() -> float:
	return _time_limit


static func set_time_limit(v: float) -> void:
	_time_limit = clampf(v, 30.0, 600.0)


## 测试用：恢复默认（配置回归会在每条用例后调，避免污染后面的断言）
static func reset_defaults() -> void:
	_mode = MODE_NEW
	_base_sec = DEFAULT_BASE_SEC
	_coef = DEFAULT_COEF
	_time_limit = DEFAULT_TIME_LIMIT
	_combat_gap_sec = DEFAULT_COMBAT_GAP_SEC
	_damage_theory_mode = DEFAULT_DAMAGE_THEORY_MODE
	_output_theory_mode = DEFAULT_OUTPUT_THEORY_MODE
	_recent_attack_window = DEFAULT_RECENT_ATTACK_WINDOW
	_repair_hp = DEFAULT_REPAIR_HP
	_repair_hp_deficit = DEFAULT_REPAIR_HP_DEFICIT
	_builder_mode = BS_ON
	_army_pop_cap = DEFAULT_ARMY_POP_CAP
	_army_target_formula = DEFAULT_ARMY_TARGET_FORMULA
	_dept_mode = DEFAULT_DEPT_MODE
	_promise_mode = DEFAULT_PROMISE_MODE
	_goal_mode = DEFAULT_GOAL_MODE
	_goal_thr_override = DEFAULT_GOAL_THRESHOLD


static func describe() -> String:
	if _mode == MODE_OLD:
		return "old 判定（2C-2：存活比 + 投入产出比）"
	return "new 判定（四样判据：%.0fs/1000 成本，输出系数 %.2f，交战断档 %.1fs，存活上限 %.0fs，承伤分母 %s，输出分母 %s（窗 %.1fs），修理线掉血≥%.0f HP，工位 %s，军队目标 %s，决策层 %s，承诺 %s，目标层 %s）" % [
		_base_sec, _coef, _combat_gap_sec, _time_limit, _damage_theory_mode,
		_output_theory_mode, _recent_attack_window, _repair_hp_deficit,
		_builder_mode, _army_target_formula, _dept_mode, _promise_mode, _goal_mode]
