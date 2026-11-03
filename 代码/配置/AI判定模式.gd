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
##   --verdict-coef=0.7          理论输出的保守系数（默认 0.7）
##   --verdict-time-limit=180    单波存活上限（默认 180）
##
## ★ 与 `AI战略权重.gd` 同一套写法：static var + set_mode()，非法值回落默认，
##   绝不静默跑到第三个分支。

const MODE_OLD: String = "old"
const MODE_NEW: String = "new"
const MODES: Array[String] = [MODE_OLD, MODE_NEW]

## 默认值 —— 与 战斗模型.THEORY_BASE_SEC / THEORY_OUTPUT_COEF / TIME_LIMIT 保持一致
const DEFAULT_BASE_SEC: float = 40.0
const DEFAULT_COEF: float = 0.7
const DEFAULT_TIME_LIMIT: float = 180.0

static var _mode: String = MODE_NEW
static var _base_sec: float = DEFAULT_BASE_SEC
static var _coef: float = DEFAULT_COEF
static var _time_limit: float = DEFAULT_TIME_LIMIT
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


static func base_sec() -> float:
	return _base_sec


static func set_base_sec(v: float) -> void:
	_base_sec = clampf(v, 10.0, 120.0)


static func output_coef() -> float:
	return _coef


static func set_output_coef(v: float) -> void:
	_coef = clampf(v, 0.1, 1.5)


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


static func describe() -> String:
	if _mode == MODE_OLD:
		return "old 判定（2C-2：存活比 + 投入产出比）"
	return "new 判定（四样判据：%.0fs/1000 成本，输出系数 %.2f，存活上限 %.0fs）" % [
		_base_sec, _coef, _time_limit]
