extends RefCounted
## **升星（经验 → 星级）的唯一口径**
##
## 玩家 2026-11-08 定稿：
##   · 击杀获得经验：目前所有单位击杀后**只给 15 点**；
##   · 每次升星所需经验**相同** = 该兵种价值的经验换算 `金 × 2 + 木 × 3`；
##     一星、二星、三星都消耗同一个数（**不要**给二星三星额外加价）；
##   · 击杀者**独得**经验（不分享给队友）；
##   · 命名：无星 = 新兵 / 一星 = 老兵 / 二星 = 精英 / 三星 = 王牌；
##   · 加成（累计）：
##       一星  移速 / 攻击力 / 攻速 **+15%**，血量 / 防御 **+20%**
##       二星  在一星基础上再 +15% / +20% → 累计 **+30% / +40%**
##       三星  在二星基础上再 +50% / +60% → 累计 **+80% / +100%**
##
## 这份文件只提供**数字**，状态存在 `RtsUnit.exp_value / star_level`，
## 加成通过 `RtsUnit.star_*_mult()` 被移速、攻速、伤害、护甲、血上限各自读取。
## 不要在别处再写一遍这些倍率。

## 星级上限
const STAR_CAP: int = 3
## 每次击杀给多少经验（全部单位统一）
const KILL_EXP: float = 15.0
## 星级中文名（0~3）
const NAMES: Array[String] = ["新兵", "老兵", "精英", "王牌"]
## 攻击 / 移速 / 攻速 的累计倍率（下标 = 星级）
const OFFENSE_MULT: Array[float] = [1.0, 1.15, 1.30, 1.80]
## 血量 / 防御 的累计倍率（下标 = 星级）
const TOUGH_MULT: Array[float] = [1.0, 1.20, 1.40, 2.00]


## 升一星需要多少经验 = 金 × 2 + 木 × 3（每次升星都是这个数）
static func exp_per_star(def: UnitDef) -> float:
	if def == null:
		return 60.0
	var v: float = float(def.gold_cost) * 2.0 + float(def.wood_cost) * 3.0
	# 兜底：0 成本单位（野怪卡没填钱）给一个最小值，免得"打一只就三星"
	return maxf(v, 30.0)


## 经验 → 该有多少星（封顶 3）
static func stars_of(exp_value: float, need: float) -> int:
	if need <= 0.0:
		return 0
	return clampi(int(floor(maxf(exp_value, 0.0) / need)), 0, STAR_CAP)


## 星级中文名
static func name_of(star: int) -> String:
	return NAMES[clampi(star, 0, STAR_CAP)]


## 攻击类倍率（攻击力 / 移速 / 攻速）
static func offense_mult(star: int) -> float:
	return OFFENSE_MULT[clampi(star, 0, STAR_CAP)]


## 耐久类倍率（血量 / 防御）
static func tough_mult(star: int) -> float:
	return TOUGH_MULT[clampi(star, 0, STAR_CAP)]
