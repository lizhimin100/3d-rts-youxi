extends RefCounted
## **小队（Squad）**：命令与编队的一等公民。
##
## 设计口径（2026-11-14）：
##   · 小队**不是节点**、不进场景树、不参与碰撞/迷雾/空间哈希；
##   · 它只是 `Game.squads` 注册表里的一条记录：成员引用 + 编队槽位 + 共享目标；
##   · 单位完全不知道自己在哪个小队里 —— 这样不用改 RtsUnit 的 4000 行；
##   · **不做士气**（用户明确要求）。成员死亡只影响 `alive_count()`，
##     小队继续存在；全死光才由注册表回收。
##
## 为什么不做成 Node3D 父节点：`Game.spawn_unit` 固定把单位挂在 `level` 下，
## 迷雾/空间哈希/AI 全部假设单位是平铺的；reparent 会打穿这些系统。

## 小队 id（注册表自增，从 1 开始；0 = 不属于任何小队）
var id: int = 0
## 所属阵营
var faction: RtsFaction = null
## 显示名（"小队1" / 玩家可改）
var name: String = "小队"
## 成员（Array[Node]，RtsUnit；每次访问前先 prune）
var members: Array = []
## 编队槽位（Array[Vector3]，与 members 同序；命令时算一次，不逐帧算）
var slots: Array = []
## 队心（最后一次命令点；没有命令时是成员平均位置）
var anchor: Vector3 = Vector3.ZERO
## 共享目标（攻击命令用；目标死了就清空，不自动换目标）
var shared_target: Node3D = null
## 最近一次命令语义（RtsConst.Order；只记录，不驱动行为）
var stance: int = 0
## 最近一次命令时刻（Game.elapsed 口径）
var last_order_at: float = 0.0
## 控制权命令组 id（由 控制权.on_player_command 维护；0 = 未登记）
var order_group: int = 0


func setup(p_id: int, p_faction: RtsFaction, p_members: Array, p_name: String = "") -> void:
	id = p_id
	faction = p_faction
	members = p_members.duplicate()
	name = p_name if not p_name.is_empty() else "小队%d" % id
	anchor = _center()


## 剔除失效/死亡/换阵营的成员。返回是否还有活人。
func prune() -> bool:
	var live: Array = []
	for u in members:
		if u == null or not is_instance_valid(u):
			continue
		if not (u is RtsUnit):
			continue
		var r := u as RtsUnit
		if not r.is_alive():
			continue
		if faction != null and r.faction != faction:
			continue
		live.append(r)
	members = live
	if shared_target != null:
		if not is_instance_valid(shared_target):
			shared_target = null
		elif shared_target is RtsUnit and not (shared_target as RtsUnit).is_alive():
			shared_target = null
	return not members.is_empty()


func is_empty() -> bool:
	return members.is_empty()


func alive_count() -> int:
	return members.size()


## 队长 = 第一个活着的成员。**不加任何 buff**，只是 UI/调试的读取口径。
func leader() -> Node3D:
	prune()
	return members[0] as Node3D if not members.is_empty() else null


## 当前队心（成员平均；空队返回 anchor）
func center_now() -> Vector3:
	if members.is_empty():
		return anchor
	return _center()


func contains(unit: Node) -> bool:
	return members.has(unit)


## 把指定单位从本队摘掉（玩家把一部分人拉去新队时用）。
func detach(units: Array) -> void:
	for u in units:
		members.erase(u)


## 成员 id 列表（给命令记录用；不持有 Node 引用）
func member_ids() -> Array[int]:
	var out: Array[int] = []
	for u in members:
		if u != null and is_instance_valid(u):
			out.append(int((u as Node).get_instance_id()))
	return out


func set_slots(points: Array) -> void:
	slots = points.duplicate()


## 第 i 个成员的落点；越界回退到队心
func slot_for(i: int, fallback: Vector3) -> Vector3:
	if i >= 0 and i < slots.size() and slots[i] is Vector3:
		return slots[i]
	return fallback


func _center() -> Vector3:
	var sum := Vector3.ZERO
	var n: int = 0
	for u in members:
		if u == null or not is_instance_valid(u):
			continue
		sum += (u as Node3D).global_position
		n += 1
	return sum / float(n) if n > 0 else anchor


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"faction": faction.display_name if faction != null else "",
		"alive": alive_count(),
		"anchor": {"x": anchor.x, "z": anchor.z},
		"stance": stance,
	}
