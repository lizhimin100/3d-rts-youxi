extends RefCounted
## **建筑改造** —— 把一座已完工的建筑"原地换成另一种建筑"（哨塔 → 箭塔）。
##
## 为什么用"替换"而不是给 UnitDef 加一个 upgrade 字段：
##   建筑的外观/占地/训练项/攻击全在 UnitDef 里，运行时换 def 要重建模型、
##   重算占地、重建基座 —— 等于把一座楼拆了重建。既然这样，**老老实实重建**最简单：
##   清占地 → 注销 → 生成新建筑（同一坐标/朝向/阵营/血量比例）→ 重新占格。
##   玩家看到的只是"塔顶上多了一圈箭垛"，数据层是一次干净的替换。
##
## 三条纪律：
##   1. **必须 clear_footprint + unregister**：不清占地，新塔会被自己压住（永远判不能建）；
##   2. **血量按比例继承**：打了一半的哨塔升级后还是半血，不能当回血手段；
##   3. 只负责"换"，**不负责收钱**：花费由调用方（指令系统 / AI）先扣，
##      这样玩家路径和 AI 路径用的是同一套价格口径。

## 反向操作也走这里（暂时没有降级需求，但函数本身是通用的）


## 把 `old` 换成 `new_id` 建筑。成功返回新节点，失败返回 null。
## `keep_hp` = 血量比例是否继承（默认 true）。
static func replace(old: Node3D, new_id: StringName, keep_hp: bool = true) -> Node3D:
	if old == null or not is_instance_valid(old):
		return null
	var old_b := old as RtsBuilding
	if old_b == null or old_b.def == null:
		return null
	var new_def: UnitDef = Cfg.unit(new_id)
	if new_def == null or not new_def.is_building():
		return null
	var lv: Node3D = RtsWorld.level()
	var parent: Node = old.get_parent()
	if parent == null:
		return null

	var pos: Vector3 = old.global_position
	var yaw: float = old.rotation.y
	var faction: RtsFaction = old_b.faction
	var frac: float = 1.0
	if keep_hp and old_b.def.max_hp > 0.0:
		frac = clampf(old_b.hp / old_b.def.max_hp, 0.05, 1.0)

	# ① 退场：先放开占地（寻路格），再注销注册表，最后删节点
	if lv != null and lv.has_method("clear_footprint"):
		lv.call("clear_footprint", old)
	Game.unregister(old)
	old.queue_free()

	# ② 进场：同一坐标 / 朝向 / 阵营
	var n: Node3D = Game.spawn_unit(faction, new_id, pos, parent)
	if n == null:
		return null
	n.rotation.y = yaw
	if lv != null and lv.has_method("mark_footprint"):
		lv.call("mark_footprint", n)
	if n.has_method("set_constructed"):
		n.call("set_constructed", true)
	var nb := n as RtsBuilding
	if nb != null:
		nb.hp = maxf(1.0, new_def.max_hp * frac)
	return n


## 升级要花多少（金, 木）= 新建筑造价 − 旧建筑造价，负数按 0 计。
## 口径：升级只补差价，不是"再买一座"。
static func upgrade_cost(old_id: StringName, new_id: StringName) -> Vector2i:
	var a: UnitDef = Cfg.unit(old_id)
	var b: UnitDef = Cfg.unit(new_id)
	if a == null or b == null:
		return Vector2i.ZERO
	return Vector2i(maxi(0, b.gold_cost - a.gold_cost),
			maxi(0, b.wood_cost - a.wood_cost))


## 能不能付得起（不扣钱，只判断）
static func can_pay(faction: RtsFaction, old_id: StringName, new_id: StringName) -> bool:
	if faction == null:
		return false
	var c: Vector2i = upgrade_cost(old_id, new_id)
	return faction.gold >= c.x and faction.wood >= c.y


## 扣钱（按差价）。失败返回 false，且**一分不扣**。
static func pay(faction: RtsFaction, old_id: StringName, new_id: StringName) -> bool:
	if not can_pay(faction, old_id, new_id):
		return false
	var c: Vector2i = upgrade_cost(old_id, new_id)
	faction.add_res(-c.x, -c.y)
	Game.resources_changed.emit(faction)
	return true
