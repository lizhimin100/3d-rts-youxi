extends RefCounted
## **AI 战略权重**（纯数据 + 一个运行期开关）
##
## 存在的理由：2026-11-02 的 4 队 FFA bench 发现"三支 AI 全程 0 出击"——
## 出击许可要求"我方战力 / 敌军战力 ≥ 1.59"，而这个分母取的是**最强的那一个对手**。
## 三家互为最强、谁也攒不到 1.59，于是三家一起站着不动（114 次拒击封顶）。
##
## 本文件只回答一个问题：**分母该跟谁比**。三个模式（2.2 的 A/B/C）：
##   A `strongest` 现状：分母 = 最强对手（默认，保证不改现有对局）
##   B `second`    次强：分母 = 第二强对手（次强 ≥ 最强 × SECOND_GATE 时才换）
##   C `decay`     衰减：连续打不出去，就把"需要多少战力比"按 0.95^轮次 往下压
##
## ★ 默认必须是 A。B/C 只在 bench（`--ratio-mode=B`）或显式 `set_mode()` 时生效。
## ★ 这个开关**只影响出击门槛的分母/阈值**，不改兵种选择、不改生产、不改战术——
##   否则 A/B/C 三组数字没法归因（见第二段报告 §2 的"副作用"列）。

const MODE_STRONGEST := "A"
const MODE_SECOND := "B"
const MODE_DECAY := "C"
const MODES: Array[String] = [MODE_STRONGEST, MODE_SECOND, MODE_DECAY]

## B：次强 / 最强 ≥ 该比例才换分母。定 0.7 的意图是"两家差不多强时才敢挑软的打"；
## 定得太低会变成"专挑最弱的那家"——那是另一种送兵，不是本次要测的东西。
const SECOND_GATE: float = 0.7
## C：连续多少秒拿不到出击许可后开始递减（一轮）
const DECAY_AFTER: float = 90.0
## C：每轮把门槛乘一次（0.95 = 每 90 秒降 5%）
const DECAY_STEP: float = 0.95
## C：门槛下限。1.0 = 再怎么衰减也不允许"以少打多"
const DECAY_FLOOR: float = 1.0

static var _mode: String = MODE_STRONGEST


## 当前模式（"A"/"B"/"C"）
static func mode() -> String:
	return _mode


## 切模式（非法值回落到 A，绝不静默跑到别的分支）
static func set_mode(m: String) -> String:
	var u: String = m.strip_edges().to_upper()
	_mode = u if MODES.has(u) else MODE_STRONGEST
	return _mode


static func is_default() -> bool:
	return _mode == MODE_STRONGEST


## C 的门槛衰减：base 是难度算出来的原始门槛（简单档 1.35/0.85 ≈ 1.59），
## locked_sec 是"距上次成功出击过了多久"。A/B 恒返回 base。
static func apply_decay(base: float, locked_sec: float) -> float:
	if _mode != MODE_DECAY:
		return base
	if locked_sec < DECAY_AFTER:
		return base
	var rounds: int = int(floor(locked_sec / DECAY_AFTER))
	var need: float = base * pow(DECAY_STEP, float(rounds))
	return maxf(need, DECAY_FLOOR)


## 报告/日志用一句话
static func describe() -> String:
	match _mode:
		MODE_SECOND:
			return "B 次强分母（次强≥最强×%.2f 才换）" % SECOND_GATE
		MODE_DECAY:
			return "C 门槛衰减（每 %.0fs ×%.2f，下限 %.1f）" % [DECAY_AFTER, DECAY_STEP, DECAY_FLOOR]
		_:
			return "A 最强分母（现状）"
