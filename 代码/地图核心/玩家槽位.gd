@tool
class_name PlayerSlot
extends Resource
## **玩家槽位**：阵营、颜色、队伍、出生点、初始资源。
##
## 游戏目前只有"玩家 / 敌人"两个运行时阵营，但地图数据允许多槽位（2/4 人图），
## MapLoader 取 id=0 当玩家，取第一个不同队伍的槽位当敌人；其余槽位先当数据保存。

@export var id: int = 0
## 阵营标识（player / enemy / neutral，或以后的自定义阵营 key）
@export var faction: String = "player"
@export var color: Color = Color(0.30, 0.62, 1.00)
@export var team: int = 0
## 出生点（世界 XZ）
@export var start_pos: Vector2 = Vector2.ZERO
## 主基地朝向（弧度，模型 -Z 为正面；默认 PI = 面向南边镜头）
@export var start_yaw: float = PI
## 初始资源：{"gold": 620, "wood": 380}
@export var start_resources: Dictionary = {"gold": 620, "wood": 380}


static func make(p_id: int, p_faction: String, p_color: Color, p_team: int,
		p_pos: Vector2, p_gold: int = 620, p_wood: int = 380) -> PlayerSlot:
	var s := PlayerSlot.new()
	s.id = p_id
	s.faction = p_faction
	s.color = p_color
	s.team = p_team
	s.start_pos = p_pos
	s.start_resources = {"gold": p_gold, "wood": p_wood}
	return s


func gold() -> int:
	return int(start_resources.get("gold", 620))


func wood() -> int:
	return int(start_resources.get("wood", 380))


func clone_slot() -> PlayerSlot:
	var s := PlayerSlot.new()
	s.id = id
	s.faction = faction
	s.color = color
	s.team = team
	s.start_pos = start_pos
	s.start_yaw = start_yaw
	s.start_resources = start_resources.duplicate(true)
	return s


func to_dict() -> Dictionary:
	return {
		"id": id,
		"faction": faction,
		"color": [color.r, color.g, color.b, color.a],
		"team": team,
		"start_pos": [start_pos.x, start_pos.y],
		"start_yaw": start_yaw,
		"start_resources": start_resources.duplicate(true),
	}


static func from_dict(d: Dictionary) -> PlayerSlot:
	var s := PlayerSlot.new()
	s.id = int(d.get("id", 0))
	s.faction = String(d.get("faction", "player"))
	var c: Variant = d.get("color", [0.3, 0.62, 1.0, 1.0])
	if c is Array and (c as Array).size() >= 3:
		s.color = Color(float(c[0]), float(c[1]), float(c[2]),
			float(c[3]) if (c as Array).size() >= 4 else 1.0)
	s.team = int(d.get("team", 0))
	var p: Variant = d.get("start_pos", [0, 0])
	if p is Array and (p as Array).size() >= 2:
		s.start_pos = Vector2(float(p[0]), float(p[1]))
	s.start_yaw = float(d.get("start_yaw", PI))
	var rs: Variant = d.get("start_resources", {})
	if rs is Dictionary:
		s.start_resources = (rs as Dictionary).duplicate(true)
	return s
