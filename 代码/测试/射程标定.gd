extends SceneTree
## **射程标定（无头）**：实测「近战要多少实际距离才能正常打人/打楼/多打一不卡」，
## 把通过的那个**实际米数**找出来 —— 它就是「攻击范围 = 1」的锚。
##
## 跑法：godot --headless --fixed-fps 60 --path . --script 代码/测试/射程标定.gd
## 结尾一行 RANGECAL {json}。
##
## 为什么用行为判据而不是几何判据：
##   `_target_gap <= reach` 只回答"够不够得着"，回答不了"会不会被挡在墙外、
##   四个人会不会只有一个在打"。所以四组用例全部看 `dbg_swings`：真挥了才算过。

const 步长: float = 1.0 / 60.0
## 候选值：0.70 ~ 1.20，步进 0.05
const 候选: Array[float] = [0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

var 游戏: Node = null
var 关卡: Node3D = null
var 行: Array = []


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	游戏 = root.get_node_or_null("Game")
	if 游戏 == null:
		push_error("[射程标定] 找不到 Game")
		quit(1)
		return
	var 通过值: float = -1.0
	for r in 候选:
		var 结果 := _试一个(r)
		行.append(结果)
		print("[标定] R=%.2f 打人=%s 打楼=%s 四打一=%s 四围楼=%s  -> %s" % [
			r, _y(结果["打人"]), _y(结果["打楼"]), _y(结果["四打一"]), _y(结果["四围楼"]),
			"通过" if bool(结果["通过"]) else "不过"])
		if bool(结果["通过"]) and 通过值 < 0.0:
			通过值 = r
	print("RANGECAL " + JSON.stringify({"锚": 通过值, "明细": 行}))
	quit(0 if 通过值 > 0.0 else 1)


func _y(v: Variant) -> String:
	return "Y" if bool(v) else "n"


## 跑四组用例。每组都重建世界，避免上一轮的尸体/状态污染。
func _试一个(r: float) -> Dictionary:
	_建世界()
	var 兵种 = 游戏.call("cfg").call("unit", &"footman") if 游戏.has_method("cfg") else null
	var d: UnitDef = null
	var 表: Script = load("res://代码/配置/单位表.gd")
	var 全部: Dictionary = 表.call("build_units")
	d = 全部.get(&"footman", null)
	if d == null:
		return {"R": r, "通过": false, "错": "没有 footman"}
	var 原: float = d.attack_range
	d.attack_range = r
	var 打人: bool = _用例打人(r)
	_建世界()
	var 打楼: bool = _用例打楼(r)
	_建世界()
	var 四打一: bool = _用例四打一(r)
	_建世界()
	var 四围楼: bool = _用例四围楼(r)
	d.attack_range = 原
	return {"R": r, "打人": 打人, "打楼": 打楼, "四打一": 四打一,
		"四围楼": 四围楼, "通过": 打人 and 打楼 and 四打一 and 四围楼}


func _建世界() -> void:
	for c in root.get_children():
		if c.name == "关卡":
			c.queue_free()
	游戏.call("reset")
	游戏.set("difficulty_index", 0)
	游戏.call("setup_factions")
	var s: Script = load("res://代码/核心/关卡.gd")
	关卡 = s.new()
	关卡.name = "关卡"
	root.add_child(关卡)
	关卡.call("build")
	游戏.set("level", 关卡)
	var 常量脚本: Script = load("res://代码/核心/常量.gd")
	var 阶段: Dictionary = 常量脚本.get_script_constant_map().get("Phase", {}) if 常量脚本 != null else {}
	游戏.set("phase", int(阶段.get("RUNNING", 1)))


func _造(阵营: String, id: StringName, 位置: Vector3):
	var 派 = 游戏.get(阵营)
	var n = 游戏.call("spawn_unit", 派, id, 位置, 关卡)
	if n == null:
		return null
	n.set_process(false)
	var v = n.get("visual")
	if v != null and is_instance_valid(v):
		v.set_process(false)
	return n


func _一步() -> void:
	var s: Script = load("res://代码/单位/单位.gd")
	if s != null:
		s.set("_sep_frame", -1)
	游戏.set("_unit_hash_frame", -1)
	for u in 游戏.call("all_units"):
		if u == null or not is_instance_valid(u) or u.is_queued_for_deletion():
			continue
		if not u.call("is_alive"):
			continue
		u._process(步长)


func _走(秒: float) -> void:
	for i in int(round(秒 / 步长)):
		_一步()


func _基() -> Vector3:
	return 关卡.call("base_center", 游戏.get("player_faction"))


func _用例打人(r: float) -> bool:
	var 心: Vector3 = 关卡.call("walkable_pos", _基() + Vector3(0.0, 0.0, 14.0))
	var 兵 = _造("player_faction", &"footman", 心)
	var 靶 = _造("enemy_faction", &"footman", 关卡.call("walkable_pos", 心 + Vector3(0.0, 0.0, 6.0)) - Vector3(0, 0, 6.0) + Vector3(0, 0, 6.0))
	if 兵 == null or 靶 == null:
		return false
	(靶 as Node3D).global_position = (兵 as Node3D).global_position + Vector3(0.0, 0.0, 6.0)
	靶.set("hp", 100000.0)
	兵.set("dbg_swings", 0)
	兵.call("order_attack", 靶)
	_走(6.0)
	return int(兵.get("dbg_swings")) > 0


func _用例打楼(r: float) -> bool:
	var 心: Vector3 = 关卡.call("walkable_pos", _基() + Vector3(0.0, 0.0, 30.0))
	var 楼 = _造("enemy_faction", &"barracks", 心)
	if 楼 == null:
		return false
	var 兵 = _造("player_faction", &"footman", 关卡.call("walkable_pos", 心 + Vector3(6.0, 0.0, 0.0)))
	if 兵 == null:
		return false
	兵.set("dbg_swings", 0)
	兵.call("order_attack", 楼)
	_走(12.0)
	return int(兵.get("dbg_swings")) > 0


func _用例四打一(r: float) -> bool:
	var 心: Vector3 = 关卡.call("walkable_pos", _基() + Vector3(0.0, 0.0, 16.0))
	var 靶 = _造("enemy_faction", &"footman", 心)
	if 靶 == null:
		return false
	靶.set("hp", 100000.0)
	var 兵们: Array = []
	for off in [Vector3(5, 0, 0), Vector3(-5, 0, 0), Vector3(0, 0, 5), Vector3(0, 0, -5)]:
		var b = _造("player_faction", &"footman", 关卡.call("walkable_pos", 心 + (off as Vector3)))
		if b == null:
			continue
		b.set("dbg_swings", 0)
		b.call("order_attack", 靶)
		兵们.append(b)
	_走(10.0)
	var 全员: bool = true
	for b in 兵们:
		if int(b.get("dbg_swings")) <= 0:
			全员 = false
	return 全员 and 兵们.size() == 4


func _用例四围楼(r: float) -> bool:
	var 心: Vector3 = 关卡.call("walkable_pos", _基() + Vector3(0.0, 0.0, -34.0))
	var 楼 = _造("enemy_faction", &"barracks", 心)
	if 楼 == null:
		return false
	var 兵们: Array = []
	for off in [Vector3(6, 0, 0), Vector3(-6, 0, 0), Vector3(0, 0, 6), Vector3(0, 0, -6)]:
		var b = _造("player_faction", &"footman", 关卡.call("walkable_pos", 心 + (off as Vector3)))
		if b == null:
			continue
		b.set("dbg_swings", 0)
		b.call("order_attack", 楼)
		兵们.append(b)
	_走(14.0)
	var 全员: bool = true
	for b in 兵们:
		if int(b.get("dbg_swings")) <= 0:
			全员 = false
	return 全员 and 兵们.size() == 4

