@tool
class_name RegionDef
extends Resource
## **区域定义**：出生区 / 进攻集结点 / 镜头限制区 / 氛围区。
##
## 形状只有三种：矩形（两个对角点）、圆（中心 + 半径）、多边形（顶点序列）。
## 点坐标一律是世界 XZ（Vector2），不存 y —— 区域是"地面上的圈"，不是立体盒子。

enum Shape {
	RECT = 0,
	CIRCLE = 1,
	POLYGON = 2,
}

enum Purpose {
	SPAWN = 0,    ## 出生区
	ATTACK = 1,   ## 进攻 / 集结区
	CAMERA = 2,   ## 镜头限制区
	AMBIENT = 3,  ## 氛围 / 装饰区
}

@export var id: String = "区域"
@export var shape: int = Shape.CIRCLE
## 矩形：points[0]=左下 points[1]=右上；圆：points[0]=中心 points[1]=中心+(r,0)；多边形：全部顶点
@export var points: PackedVector2Array = PackedVector2Array()
@export var purpose: int = Purpose.ATTACK
## 区域归属玩家槽位 id（-1 = 公共/中立）。出生区用它决定"这块地是谁家的颜色"。
@export var owner: int = -1


## 圆心（非圆形状返回中心点）
func center() -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	if shape == Shape.CIRCLE:
		return points[0]
	if shape == Shape.RECT and points.size() >= 2:
		return (points[0] + points[1]) * 0.5
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(maxi(1, points.size()))


## 圆半径
func radius() -> float:
	if shape != Shape.CIRCLE or points.size() < 2:
		return 0.0
	return points[0].distance_to(points[1])


## 是否包含某世界点
func contains(p: Vector2) -> bool:
	match shape:
		Shape.CIRCLE:
			return points.size() >= 2 and p.distance_to(points[0]) <= radius()
		Shape.RECT:
			if points.size() < 2:
				return false
			var r := Rect2(points[0], Vector2.ZERO).expand(points[1])
			return r.has_point(p)
		Shape.POLYGON:
			if points.size() < 3:
				return false
			var inside := false
			var n := points.size()
			var j := n - 1
			for i in n:
				var a := points[i]
				var b := points[j]
				if ((a.y > p.y) != (b.y > p.y)) \
						and (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y + 0.000001) + a.x):
					inside = not inside
				j = i
			return inside
	return false


## 静态版形状名（界面在还没有实例时也要显示）
static func shape_name_of(shape_value: int) -> String:
	match shape_value:
		Shape.RECT:
			return "矩形"
		Shape.CIRCLE:
			return "圆形"
		Shape.POLYGON:
			return "多边形"
	return "?"


func shape_name() -> String:
	match shape:
		Shape.RECT:
			return "矩形"
		Shape.CIRCLE:
			return "圆形"
		Shape.POLYGON:
			return "多边形"
	return "?"


func purpose_name() -> String:
	match purpose:
		Purpose.SPAWN:
			return "出生"
		Purpose.ATTACK:
			return "进攻"
		Purpose.CAMERA:
			return "镜头"
		Purpose.AMBIENT:
			return "氛围"
	return "?"


func clone_region() -> RegionDef:
	var r := RegionDef.new()
	r.id = id
	r.shape = shape
	r.points = points.duplicate()
	r.purpose = purpose
	r.owner = owner
	return r


func to_dict() -> Dictionary:
	var pts: Array = []
	for p in points:
		pts.append([p.x, p.y])
	return {"id": id, "shape": shape, "points": pts, "purpose": purpose, "owner": owner}


static func from_dict(d: Dictionary) -> RegionDef:
	var r := RegionDef.new()
	r.id = String(d.get("id", "区域"))
	r.shape = int(d.get("shape", Shape.CIRCLE))
	r.purpose = int(d.get("purpose", Purpose.ATTACK))
	r.owner = int(d.get("owner", -1))
	var raw: Variant = d.get("points", [])
	if raw is Array:
		for p in raw:
			if p is Array and (p as Array).size() >= 2:
				r.points.append(Vector2(float(p[0]), float(p[1])))
			elif p is Vector2:
				r.points.append(p)
	return r
