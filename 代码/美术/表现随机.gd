extends RefCounted
## **表现层随机（与玩法 RNG 完全隔离）**
##
## 为什么必须单独一条流：音效/粒子/裂纹/镜头抖动这些"看不看得到都不影响胜负"的随机，
## 触发时机由**墙钟**决定（节流、并发上限、帧率）。只要它们从全局 RNG 上抽一次，
## 全局流的消费次数就会随机器快慢漂移 —— AI 骰子、暴击、巡逻落点全部跟着移位，
## 同 seed 复跑对不上（2026-11-02 确定性事故的根因）。
##
## 规则（改代码时照这条判）：
##   · 影响胜负/位置/经济的随机 → 全局 `randf()` / `randi()`（玩法流，**不要动**）；
##   · 只影响看到/听到什么的随机 → 本模块（表现流，随便怎么抖都行）。
##
## 本模块内部用固定种子：同一局同一台机器上，视觉表现也可复现，
## 调试"这次爆炸为什么长这样"时不用怀疑随机。
const DEFAULT_SEED: int = 20261102

static var _rng: RandomNumberGenerator = null


static func rng() -> RandomNumberGenerator:
	if _rng == null:
		reset()
	return _rng


## 重置表现流（自检/截图脚本想要完全一致的画面时调它）
static func reset(s: int = DEFAULT_SEED) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = s


static func rand() -> float:
	return rng().randf()


static func rand_range(a: float, b: float) -> float:
	return rng().randf_range(a, b)


## [0, n) 的整数（n <= 0 时返回 0，避免取模除零）
static func rand_index(n: int) -> int:
	if n <= 0:
		return 0
	return rng().randi() % n
