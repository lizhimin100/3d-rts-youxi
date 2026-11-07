extends RefCounted
## **射程基准表** —— 所有射程的唯一刻度。
##
## 2026-11-07 玩家口径：
## > 「只要是近战单位，其攻击范围都是 1……同时因为作为基准的 1 变了，
## >  其他单位和防御塔的攻击范围却似乎没变，它们也要对标，并写清楚。
## >  当作为标准的近战单位的攻击范围 1 变了，其他的攻击范围要同步。」
##
## 于是把"射程"拆成两个概念：
##   · **基准** `MELEE_BASE`：一个标准近战单位的边缘间隙（当前 = 1.0 米）；
##   · **档位** `TIERS`：每个兵是几个基准（弩兵 10 档、箭塔 13 档 …）。
##
## 卡上的 `range` = `档位 × 基准`。改基准时**只改这一个常量**，
## 然后跑 `配置回归`：它会逐张卡比对，把"没跟着改"的卡点名。
## 这就是"基准变了，其他要同步"的机械保证 —— 不靠人记。
##
## 为什么不做成运行时乘法：卡上的数字必须**所见即所得**（玩家在编辑器里
## 看到的就是真实米数），否则调一个兵要反推半天。基准表只做**校验**。

## 近战基准（米，边缘间隙）。玩家 2026-11-07 定为 1.0。
const MELEE_BASE: float = 1.0

## 档位：id → 几个基准。**只列有攻击的单位**；0 = 无攻击（哨塔）。
const TIERS: Dictionary = {
	# --- 近战：标准 1 档 ---
	&"peasant": 1.0,        # 农民（自卫）
	&"footman": 1.0,        # 步兵（**基准本身**）
	&"gnoll_warrior": 1.0,  # 豺狼人战士
	# --- 近战：大体型 1.5 档（原 0.45 × 1.5 的口径）---
	&"steam_guard": 1.5,
	# --- 远程 ---
	&"gnoll_scout": 9.0,    # 短弩：比弩兵近 1 档
	&"archer": 10.0,        # 标准远程（玩家 2026-11-07 定）
	&"mage": 11.0,          # 施法距离：比弩兵远 1 档
	# --- 防御塔：必须压远程，否则塔被白嫖 ---
	&"tower": 13.0,         # 比弩兵远 3 档（原口径 11 vs 8）
	&"watchtower": 0.0,     # 无攻击（只做预警）
}

## 容差（米）：卡上允许 ±0.05 的取整误差
const TOL: float = 0.05


## 某个 id 应有的射程（米）；表里没有返回 -1
static func expected(id: StringName) -> float:
	if not TIERS.has(id):
		return -1.0
	return float(TIERS[id]) * MELEE_BASE


## 校验一张卡。返回空字符串 = 通过；否则返回人话原因。
static func check_card(id: StringName, range: float) -> String:
	var want: float = expected(id)
	if want < 0.0:
		return ""  # 不在表里：不校验（新增兵种先跑起来，再补档位）
	if absf(range - want) > TOL:
		return "%s 射程 %.3f ≠ 档位 %.1f × 基准 %.2f = %.3f（差 %.3f）" % [
			id, range, float(TIERS[id]), MELEE_BASE, want, range - want]
	return ""


## 一行说清当前的基准与档位关系（日志/报告用）
static func describe() -> String:
	var parts: PackedStringArray = []
	for id in TIERS.keys():
		parts.append("%s=%.1f×%.2f" % [id, float(TIERS[id]), MELEE_BASE])
	return "近战基准 %.2fm；" % MELEE_BASE + "，".join(parts)
