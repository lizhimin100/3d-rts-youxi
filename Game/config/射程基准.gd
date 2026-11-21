extends RefCounted
## **射程基准 R1 —— 全游戏唯一的换算系数（GDScript 侧出口）**
##
## 真值只有一份：`Model/Core/RtsUnits.cs` 的 `R1 = 0.015`。
## 这个文件只是给 GDScript 用的**门面**：它自己不再写 0.015，
## 而是向 C# 内核要（`--check` 会断言两边相等，且全仓库没有第二个字面量）。
##
## 卡上写的是**游戏射程数值**（三位数：步兵 125、弩兵 650、箭塔 870），
## Godot 世界里用**米**。两者之间只通过这一个系数换算：
##
##     实际米数 = 卡上数值 × R1       R1 = 0.015 米 / 单位
##
## 换算示例：
##   近战 125 × 0.015 = **1.875 米**
##   弩兵 650 × 0.015 = **9.75 米**
##   箭塔 870 × 0.015 = **13.05 米**
##
## 为什么这个值安全（实测，见 Tests/suites/射程标定.gd）：
##   对步兵跑四组行为验收（打人 / 打楼 / 四打一 / 四围楼），
##   "能打到"的**地板是 0.30 米**，而近战实际 1.875 米 —— 高出地板 6 倍以上。
##
## ⚠ **R1 定死**。想改某个单位的射程就改它卡上的数值（125 → 150 就是 2.25 米），
##   不要动内核；改 R1 = 全游戏所有射程同时缩放，一般不要动。

const BRIDGE := preload("res://Game/adapters/bridge.gd")


static var _r1_fallback: float = -1.0


static func _bridge() -> RefCounted:
	return BRIDGE.get_bridge()


## 基准系数（真值在 C# 内核；这里只转发）。
## 非 .NET 版 Godot 没有 C# 桥时，退回读 Content/data/combat.json 的 r1
## —— 那是内容真源，--check 会断言它与内核相等；这里不再刷 push_error。
static func _fallback_r1() -> float:
	if _r1_fallback >= 0.0:
		return _r1_fallback
	_r1_fallback = 0.0
	var f := FileAccess.open("res://Content/data/combat.json", FileAccess.READ)
	if f != null:
		var text := f.get_as_text()
		f.close()
		var v: Variant = JSON.parse_string(text)
		if v is Dictionary:
			_r1_fallback = float((v as Dictionary).get("r1", 0.0))
	return _r1_fallback


static func r1() -> float:
	var m := _bridge()
	if m == null:
		return _fallback_r1()
	return float(m.call("R1"))


## 游戏数值 → 米（卡 → 引擎）
static func 米(值: float) -> float:
	return 值 * r1()


## 米 → 游戏数值（引擎 → 卡；界面要用"米"时反算）
static func 值(米: float) -> float:
	var k := r1()
	if k <= 0.0000001:
		return 米
	return 米 / k
