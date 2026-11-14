extends RefCounted
## **小队注册表**：`Game.squads` 的唯一实现。
##
## 职责：创建/查找/回收小队，并在单位死亡时自动剔除成员（空队回收）。
## 不参与移动/战斗/寻路：这些仍由单位自己的 order_* 执行。
##
## 为什么放在 Game 上而不是场景节点：命令记录要跨"准备 → 执行"存活，
## 而场景节点在重开时会被 reload；注册表跟着 Game.reset() 清空，生命周期更清楚。

const SquadScript := preload("res://Game/systems/小队.gd")

## id -> 小队
var _squads: Dictionary = {}
var _next_id: int = 1
var _attached: bool = false


## 订阅死亡信号（幂等）。Game._ready 调用一次。
func attach() -> void:
	if _attached:
		return
	if Game == null:
		return
	if not Game.unit_died.is_connected(_on_unit_died):
		Game.unit_died.connect(_on_unit_died)
	_attached = true


func reset() -> void:
	_squads.clear()
	_next_id = 1


func count() -> int:
	return _squads.size()


func all() -> Array:
	var out: Array = []
	for k in _squads.keys():
		var s = _squads[k]
		if s != null:
			out.append(s)
	return out


func get_squad(id: int):
	return _squads.get(id, null)


## 创建一支小队。会先剔除无效/死亡/非本阵营成员；空队返回 null。
func create(faction: RtsFaction, units: Array, p_name: String = ""):
	var live: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not (u is RtsUnit):
			continue
		var r := u as RtsUnit
		if not r.is_alive():
			continue
		if faction != null and r.faction != faction:
			continue
		if not live.has(r):
			live.append(r)
	if live.is_empty():
		return null
	var s = SquadScript.new()
	s.call("setup", _next_id, faction, live, p_name)
	_squads[_next_id] = s
	_next_id += 1
	return s


## 找包含指定单位的队伍（没有返回 null）
func find_by_member(unit: Node):
	if unit == null or not is_instance_valid(unit):
		return null
	for k in _squads.keys():
		var s = _squads[k]
		if s == null:
			continue
		if bool(s.call("prune")) and bool(s.call("contains", unit)):
			return s
	return null


## 找一支**包含这组单位全部成员**的队伍（用于"这批人还是原来那队"）
func find_containing(units: Array):
	if units.is_empty():
		return null
	for k in _squads.keys():
		var s = _squads[k]
		if s == null:
			continue
		if not bool(s.call("prune")):
			continue
		var ok: bool = true
		for u in units:
			if u == null or not is_instance_valid(u) or not bool(s.call("contains", u)):
				ok = false
				break
		if ok:
			return s
	return null


func dissolve(id: int) -> void:
	_squads.erase(id)


## 把一批单位从所有队伍里摘掉（新建队伍前调用，保证一个单位只属于一支队）。
func detach_units(units: Array) -> void:
	for k in _squads.keys():
		var s = _squads[k]
		if s == null:
			_squads.erase(k)
			continue
		s.call("detach", units)
		if not bool(s.call("prune")):
			_squads.erase(k)


## 全量剪枝：空队回收。命令执行前后/每帧刷新都可以调（O(队伍数×成员数)，
## 队伍通常个位数，开销可忽略）。
func prune_all() -> void:
	for k in _squads.keys():
		var s = _squads[k]
		if s == null:
			_squads.erase(k)
			continue
		if not bool(s.call("prune")):
			_squads.erase(k)


func _on_unit_died(_unit: Node3D) -> void:
	prune_all()
