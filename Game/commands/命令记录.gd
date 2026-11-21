extends RefCounted
## **命令记录**：把"动词"变成"名词"。
##
## 旧架构里玩家下令就是直接调 `u.order_move()` —— 没有命令对象、没有队列、
## 无法"规划阶段先排好、执行阶段再统一发"。半回合制必须先有这一层。
##
## 设计口径：
##   · 只存 **instance_id + 坐标**，不跨阶段持有 Node 引用（单位可能已 free）；
##   · `squad_id` 是**一等公民**：执行时优先按小队当前成员解析，成员死亡自动跳过；
##   · 单位 id 列表是兜底（小队被解散时仍能按原成员执行）；
##   · 不在这里做任何玩法判定（够不够钱/看不看得见/能不能到），
##     执行时由 RtsUnit.order_* 和可用性层自己判。

## RtsConst.Order
var kind: int = 0
## 小队 id（0 = 无小队）
var squad_id: int = 0
## 成员 instance_id（与 slots 同序）
var unit_ids: Array[int] = []
## 编队槽位（与 unit_ids 同序；攻击单目标时可为空）
var slots: Array = []
## 目标点（世界坐标）
var point: Vector3 = Vector3.ZERO
## 目标节点 instance_id（攻击/采集/修理/施法用；0 = 无目标）
var target_id: int = 0
## 技能 id（CAST 用）
var ability: StringName = &""
## 显示用标签（"攻击 步兵" / "移动" …）
var label: String = ""
## 下达时刻（Game.elapsed）
var issued_at: float = 0.0


static func make(p_kind: int, p_squad_id: int, p_unit_ids: Array[int],
		p_point: Vector3, p_target_id: int = 0, p_ability: StringName = &"",
		p_label: String = "", p_slots: Array = []):
	var r = load("res://Game/commands/命令记录.gd").new()
	r.kind = p_kind
	r.squad_id = p_squad_id
	r.unit_ids = p_unit_ids.duplicate()
	r.slots = p_slots.duplicate()
	r.point = p_point
	r.target_id = p_target_id
	r.ability = p_ability
	r.label = p_label
	r.issued_at = Game.elapsed if Game != null else 0.0
	return r


## 解析出仍然有效的己方单位（顺序与 unit_ids 一致；死亡/失效/换阵营的跳过）。
func resolve_units(faction: RtsFaction) -> Array:
	var out: Array = []
	for uid in unit_ids:
		var raw = instance_from_id(int(uid))
		if raw == null or not is_instance_valid(raw):
			continue
		if not (raw is RtsUnit):
			continue
		var u := raw as RtsUnit
		if not u.is_alive():
			continue
		if faction != null and u.faction != faction:
			continue
		out.append(u)
	return out


## 解析目标；目标已死/已 free 返回 null（调用方回退到坐标/跳过）。
func resolve_target() -> Node3D:
	if target_id == 0:
		return null
	var raw = instance_from_id(int(target_id))
	if raw == null or not is_instance_valid(raw):
		return null
	if not (raw is Node3D):
		return null
	return raw as Node3D


## 执行时取第 i 个成员的落点（与 resolve_units 的顺序对齐）
func slot_at(i: int, fallback: Vector3) -> Vector3:
	if i >= 0 and i < slots.size() and slots[i] is Vector3:
		return slots[i]
	return fallback


func text() -> String:
	if not label.is_empty():
		return label
	match kind:
		RtsConst.Order.MOVE:
			return "移动"
		RtsConst.Order.ATTACK:
			return "攻击"
		RtsConst.Order.ATTACK_MOVE:
			return "攻击移动"
		RtsConst.Order.STOP:
			return "停止"
		RtsConst.Order.HOLD:
			return "驻守"
		RtsConst.Order.BUILD:
			return "建造"
		RtsConst.Order.CAST:
			return "技能"
		RtsConst.Order.REPAIR:
			return "修理"
		RtsConst.Order.DEFEND:
			return "防守"
		RtsConst.Order.CAPTURE:
			return "占据"
	return "指令"


func to_dict() -> Dictionary:
	return {
		"kind": kind,
		"squad_id": squad_id,
		"units": unit_ids.size(),
		"point": {"x": point.x, "z": point.z},
		"target": target_id,
		"label": text(),
	}
