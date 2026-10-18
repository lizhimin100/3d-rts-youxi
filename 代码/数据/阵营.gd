class_name RtsFaction
extends RefCounted
## **阵营**：一个玩家（或 AI）的全部资产与资源。
## 玩家与 AI 都只有一个 RtsFaction，经济/军队全挂在这里。
## 由 Lead 提供，其他人只读/调用，不要改这个文件。

# 阵营索引（RtsConst.Faction）
var index: int = RtsConst.Faction.PLAYER
## 是否人类玩家（否则是 AI）
var is_player: bool = true
## 名字（界面显示）
var display_name: String = "玩家"
## 队伍色
var color: Color = Color.WHITE

# --- 资源 ---
var gold: int = 0
var wood: int = 0

# --- 单位集合（由 游戏 维护）---
## Array[RtsUnit]
var units: Array = []
## Array[RtsBuilding]
var buildings: Array = []


## 装配初始资源
func setup(p_index: int, p_is_player: bool, p_name: String, p_color: Color, p_gold: int, p_wood: int) -> void:
	index = p_index
	is_player = p_is_player
	display_name = p_name
	color = p_color
	gold = p_gold
	wood = p_wood


## 当前人口占用（所有存活单位的 food_cost 之和）
func food_used() -> int:
	var total: int = 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive():
			continue
		var d: UnitDef = u.def
		if d != null:
			total += d.food_cost
	return total


## 人口上限（所有建筑 food_provided 之和）
func food_cap() -> int:
	var total: int = 0
	for b in buildings:
		if b == null or not is_instance_valid(b):
			continue
		var d: UnitDef = b.def
		if d != null:
			total += d.food_provided
	return total


## 人口是否够用
func has_food(amount: int) -> bool:
	return food_used() + amount <= food_cap()


## 资源是否够
func can_afford(def: UnitDef) -> bool:
	if def == null:
		return false
	return gold >= def.gold_cost and wood >= def.wood_cost


## 扣除资源（先检查再扣；成功返回 true）
func pay(def: UnitDef) -> bool:
	if def == null or not can_afford(def):
		return false
	gold -= def.gold_cost
	wood -= def.wood_cost
	return true


## 增加资源
func add_res(p_gold: int, p_wood: int) -> void:
	gold = maxi(0, gold + p_gold)
	wood = maxi(0, wood + p_wood)


## 存活单位数量（可选按 id 过滤）
func count_units(id: StringName = &"") -> int:
	var n: int = 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive():
			continue
		if id == &"" or u.def.id == id:
			n += 1
	return n


## 存活建筑数量
func count_buildings(id: StringName = &"") -> int:
	var n: int = 0
	for b in buildings:
		if b == null or not is_instance_valid(b):
			continue
		if not b.is_alive():
			continue
		if id == &"" or b.def.id == id:
			n += 1
	return n


## 是否还有大本营（胜负判定用）
func has_townhall() -> bool:
	return count_buildings(&"townhall") > 0


## 玩家阵营的调试字符串
func debug_string() -> String:
	return "[%s] 金=%d 木=%d 人口=%d/%d 单位=%d 建筑=%d" % [
		display_name, gold, wood, food_used(), food_cap(), count_units(), count_buildings()
	]
