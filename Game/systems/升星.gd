extends RefCounted
## **升星（经验 → 星级）的 GDScript 门面**
##
## 数字真值在 `Model/Core/Progression.cs`（纯 C#，零 Godot）。
## 这里只保留 GDScript 侧的函数签名，内部一律向 `Mdl` 要 —— 不许再写第二份倍率。
##
## 玩家 2026-11-08 定稿（2026-11-20 保留）：
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
## 状态存在 `RtsUnit.exp_value / star_level`，加成通过 `RtsUnit.star_*_mult()` 读取。

## 镜像常量（供 GDScript 侧循环/上限判断；`--check` 断言它们等于 C# 内核）
const STAR_CAP: int = 3
const KILL_EXP: float = 15.0

const BRIDGE := preload("res://Game/adapters/bridge.gd")


static func _bridge() -> RefCounted:
	return BRIDGE.get_bridge()

## 升一星需要多少经验 = 金 × 2 + 木 × 3（每次升星都是这个数）
static func exp_per_star(def: UnitDef) -> float:
	var gold: int = int(def.gold_cost) if def != null else 0
	var wood: int = int(def.wood_cost) if def != null else 0
	return exp_per_star_costs(gold, wood)


## 只按成本算（自检/推演用，不依赖 UnitDef）
static func exp_per_star_costs(gold_cost: int, wood_cost: int) -> float:
	var m := _bridge()
	if m == null:
		return maxf(float(gold_cost) * 2.0 + float(wood_cost) * 3.0, 30.0)
	return float(m.call("StarExpPerStar", gold_cost, wood_cost))


## 经验 → 该有多少星（封顶 3）
static func stars_of(exp_value: float, need: float) -> int:
	var m := _bridge()
	if m == null:
		return 0
	return int(m.call("StarStarsOf", exp_value, need))


## 星级中文名
static func name_of(star: int) -> String:
	var m := _bridge()
	if m == null:
		return ""
	return String(m.call("StarName", star))


## 攻击类倍率（攻击力 / 移速 / 攻速）
static func offense_mult(star: int) -> float:
	var m := _bridge()
	if m == null:
		return 1.0
	return float(m.call("StarOffenseMult", star))


## 耐久类倍率（血量 / 防御）
static func tough_mult(star: int) -> float:
	var m := _bridge()
	if m == null:
		return 1.0
	return float(m.call("StarToughMult", star))
