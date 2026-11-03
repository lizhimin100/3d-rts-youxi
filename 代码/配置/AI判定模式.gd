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
##   --verdict-coef=0.55         理论输出的保守系数（2C-4 用户确认 0.7 → 0.55）
##   --combat-gap-sec=3.0        有效交战时间的断档阈值（相邻两刀间隔 >N s 不计）
##   --verdict-time-limit=180    单波存活上限（默认 180）
##   --damage-theory-mode=all|targeted
##                               承伤分母口径（2C-5 P0-1，默认 targeted =
##                               只算"曾作为 target 的成员"的有效生命；all = 2C-4 旧口径）
##   --repair-hp-threshold=0.7   修理触发线（血量比例低于它才派农民去修，2C-5 P1-4）
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

## 默认值 —— 与 战斗模型.THEORY_BASE_SEC / THEORY_OUTPUT_COEF / TIME_LIMIT 保持一致
const DEFAULT_BASE_SEC: float = 40.0
## 2026-11-03 用户确认：0.7 → 0.55（任务书 §1 覆盖表）
const DEFAULT_COEF: float = 0.55
## 有效交战时间：相邻两刀间隔 > COMBAT_GAP_SEC 视为"断档"，走路/绕行段不计入战斗时间
const DEFAULT_COMBAT_GAP_SEC: float = 3.0
const DEFAULT_TIME_LIMIT: float = 180.0
## 2C-5 P1-4：建筑血量比例低于该值才派农民修理（默认 70%）
const DEFAULT_REPAIR_HP: float = 0.7

static var _mode: String = MODE_NEW
static var _base_sec: float = DEFAULT_BASE_SEC
static var _coef: float = DEFAULT_COEF
static var _time_limit: float = DEFAULT_TIME_LIMIT
static var _combat_gap_sec: float = DEFAULT_COMBAT_GAP_SEC
static var _damage_theory_mode: String = DEFAULT_DAMAGE_THEORY_MODE
static var _repair_hp: float = DEFAULT_REPAIR_HP
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
		elif a.begins_with("--repair-hp-threshold="):
			_repair_hp = clampf(float(a.substr(String("--repair-hp-threshold=").length())), 0.1, 1.0)


## 承伤分母口径（"all" 旧 / "targeted" 新）。非法值回落 targeted。
static func damage_theory_mode() -> String:
	return _damage_theory_mode


static func set_damage_theory_mode(m: String) -> String:
	var u: String = m.strip_edges().to_lower()
	_damage_theory_mode = u if DT_MODES.has(u) else DT_TARGETED
	return _damage_theory_mode


## 修理触发线（血量比例）
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
	_repair_hp = DEFAULT_REPAIR_HP


static func describe() -> String:
	if _mode == MODE_OLD:
		return "old 判定（2C-2：存活比 + 投入产出比）"
	return "new 判定（四样判据：%.0fs/1000 成本，输出系数 %.2f，交战断档 %.1fs，存活上限 %.0fs，承伤分母 %s，修理线 %.0f%%）" % [
		_base_sec, _coef, _combat_gap_sec, _time_limit, _damage_theory_mode, _repair_hp * 100.0]
