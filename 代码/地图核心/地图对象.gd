@tool
class_name MapObject
extends Resource
## **地图对象**：地图上摆的一个东西的"纯数据"。
##
## 只存 type_id / 分类 / 变换 / 归属 / 附加属性，**不存节点**。
## 打开地图时由 MapLoader / 编辑器预览工厂按 type_id 现造节点，
## 所以地图文件可以随便复制、跨进程读，不会带上 Node 路径那种脏东西。

enum Category {
	UNIT = 0,      ## 单位（走 Game.spawn_unit）
	BUILDING = 1,  ## 建筑（走 Game.spawn_unit + mark_footprint）
	DOODAD = 2,    ## 装饰（纯视觉，直接实例化 GLB）
	RESOURCE = 3,  ## 资源（树 / 金矿，走可采集物流程）
}

## 类型 id：单位/建筑用 UnitDef.id（footman/barracks/...），
## 资源用 tree/goldmine，装饰用模型文件名（木桶/栅栏/...）
@export var type_id: StringName = &""
@export var category: int = Category.DOODAD
## 世界坐标（y 由地形高度决定，保存时也存，方便直接看）
@export var position: Vector3 = Vector3.ZERO
## 绕 Y 轴旋转（弧度）
@export var rotation: float = 0.0
## 统一缩放（1.0 = 原始大小）
@export var scale: float = 1.0
## 归属玩家槽位 id（-1 = 中立 / 装饰）
@export var owner: int = -1
## 附加属性（装饰的 model 路径、资源的储量覆盖、建筑的初始血量等）
@export var properties: Dictionary = {}


static func make(p_type: StringName, p_cat: int, p_pos: Vector3,
		p_rot: float = 0.0, p_scale: float = 1.0, p_owner: int = -1) -> MapObject:
	var o := MapObject.new()
	o.type_id = p_type
	o.category = p_cat
	o.position = p_pos
	o.rotation = p_rot
	o.scale = p_scale
	o.owner = p_owner
	return o


func category_name() -> String:
	match category:
		Category.UNIT:
			return "单位"
		Category.BUILDING:
			return "建筑"
		Category.DOODAD:
			return "装饰"
		Category.RESOURCE:
			return "资源"
	return "未知"


## 深拷贝（复制粘贴 / 撤销快照都用它，绝不共享引用）
func clone_obj() -> MapObject:
	var o := MapObject.new()
	o.type_id = type_id
	o.category = category
	o.position = position
	o.rotation = rotation
	o.scale = scale
	o.owner = owner
	o.properties = properties.duplicate(true)
	return o


func to_dict() -> Dictionary:
	return {
		"type_id": String(type_id),
		"category": category,
		"position": [position.x, position.y, position.z],
		"rotation": rotation,
		"scale": scale,
		"owner": owner,
		"properties": properties.duplicate(true),
	}


static func from_dict(d: Dictionary) -> MapObject:
	var o := MapObject.new()
	o.type_id = StringName(String(d.get("type_id", "")))
	o.category = int(d.get("category", Category.DOODAD))
	var p: Variant = d.get("position", [0, 0, 0])
	if p is Array and (p as Array).size() >= 3:
		o.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	o.rotation = float(d.get("rotation", 0.0))
	o.scale = float(d.get("scale", 1.0))
	o.owner = int(d.get("owner", -1))
	var pr: Variant = d.get("properties", {})
	if pr is Dictionary:
		o.properties = (pr as Dictionary).duplicate(true)
	return o
