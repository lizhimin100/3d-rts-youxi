class_name RtsBuilding
extends RtsUnit
## **建筑**：大本营 / 兵营 / 铁匠铺 / 农场 / 箭塔。
## 继承 RtsUnit（同一套 API、同一套战斗逻辑），额外负责：
##   · 建造进度（血量 10% → 100%，半成品就能被人拆 —— 这才是攻防博弈）
##   · 训练队列（一次一个，按 train_time × 难度倍率）
##   · 铁匠铺研究（attack_up / armor_up，各 +15%，阵营级，未来单位也吃）
##   · 箭塔自动开火（复用 RtsUnit 的索敌+攻击循环，不另起一套）
##
## 占地：放下时写进寻路网格，被摧毁时**必须清掉**，否则那块地永远走不进去。

## 建造起始血量比例（10%）
const CONSTRUCTION_START_HP: float = 0.10

## 是否已建造完成（开局建筑为 true）
var is_constructed: bool = true
## 建造进度 0~1
var progress: float = 1.0
## 训练队列（Array[StringName]）与当前进度
var train_queue: Array = []
var train_progress: float = 0.0
## 集结点
var rally_point: Vector3 = Vector3.ZERO
var has_rally: bool = false
## 集结点小旗（地面上的旗杆 + 旗面 + 落点圈，设了才出现）
var _rally_flag: Node3D = null

# 研究
var _research_id: StringName = &""
var _research_t: float = 0.0

## 上一帧的建造进度（用来算血量增量，被打掉的血不会白送回来）
var _last_progress: float = 0.0


# ===========================================================================
# 装配
# ===========================================================================

## 正常生成（开局建筑 / 直接建成）：直接是完工状态
func setup(p_faction: RtsFaction, p_def: UnitDef) -> void:
	super.setup(p_faction, p_def)
	is_constructed = true
	progress = 1.0
	_last_progress = 1.0
	# 幂等：关卡也会调 mark_footprint，重复标不影响
	RtsWorld.mark_footprint(self)


## 作为"工地"生成（农民 order_build 造出来的）：血量 10%、进度 0
func setup_construction(p_faction: RtsFaction, p_def: UnitDef) -> void:
	super.setup(p_faction, p_def)
	is_constructed = false
	progress = 0.0
	_last_progress = 0.0
	train_queue.clear()
	train_progress = 0.0
	if def != null:
		hp = maxf(1.0, def.max_hp * CONSTRUCTION_START_HP)
	global_position.y = RtsWorld.height_at(global_position.x, global_position.z)


## 关卡用来强制设完工状态
func set_constructed(v: bool) -> void:
	is_constructed = v
	progress = 1.0 if v else 0.0
	_last_progress = progress


# ===========================================================================
# 查询
# ===========================================================================

## 队列里还有几个（含正在造的那个）
func train_count() -> int:
	return train_queue.size()


## 正在训练的单位 id（空队列返回空）
func current_training() -> StringName:
	if train_queue.is_empty():
		return &""
	return train_queue[0]


## 该建筑是否在造东西
func is_training() -> bool:
	return not train_queue.is_empty()


## 该建筑能不能造这个单位
func can_train(id: StringName) -> bool:
	return def != null and def.trains.has(id)


# ===========================================================================
# 建造进度
# ===========================================================================

## 农民在工地旁调这个：推进建造进度（多个农民同时建会更快）
func advance_construction(dt: float, _builder: Node3D) -> void:
	if is_constructed or def == null:
		return
	var total: float = maxf(def.train_time, 0.5)
	progress = clampf(progress + dt / total, 0.0, 1.0)

	# 血量随进度从 10% 涨到 100%（只加增量，被打掉的血不会白送回来）
	var prev_target: float = def.max_hp * lerpf(CONSTRUCTION_START_HP, 1.0, _last_progress)
	var new_target: float = def.max_hp * lerpf(CONSTRUCTION_START_HP, 1.0, progress)
	hp = minf(hp + maxf(new_target - prev_target, 0.0), new_target)
	_last_progress = progress

	if progress >= 1.0:
		_complete_construction()


## 建造完成
func _complete_construction() -> void:
	if is_constructed:
		return
	is_constructed = true
	progress = 1.0
	_last_progress = 1.0
	hp = minf(maxf(hp, def.max_hp * CONSTRUCTION_START_HP), def.max_hp)
	if visual != null:
		visual.play("idle", 1.0)
	ArtKit.vfx_build(global_position)
	Game.building_completed.emit(self)
	if faction != null and faction.is_player:
		Game.toast("%s 建造完成" % def.display_name, Color(0.72, 1.0, 0.72))


# ===========================================================================
# 训练队列
# ===========================================================================

## 排一个单位进队列（**当场真扣钱**，扣不起返回 false）
func queue_train(id: StringName) -> bool:
	if def == null or not is_constructed:
		return false
	if not can_train(id):
		return false
	var d: UnitDef = Cfg.unit(id)
	if d == null:
		return false

	# 人口 / 资源检查，不合格给提示，别默默失败
	if faction != null and not faction.has_food(d.food_cost):
		if faction.is_player:
			Game.toast("人口不足（需要 %d）" % d.food_cost, Color(1, 0.55, 0.4))
		return false
	if not Game.can_afford(faction, id):
		if faction != null and faction.is_player:
			Game.toast("资源不足：%s" % d.display_name, Color(1, 0.5, 0.4))
		return false
	if not Game.pay(faction, id):
		return false

	train_queue.append(id)
	return true


## 取消队首（退款）
func cancel_train() -> void:
	if train_queue.is_empty():
		return
	var id: StringName = train_queue.pop_front()
	train_progress = 0.0
	var d: UnitDef = Cfg.unit(id)
	if d != null and faction != null:
		Game.add_resource(faction, d.gold_cost, d.wood_cost)


## 队列推进
func _tick_train(dt: float) -> void:
	if train_queue.is_empty():
		train_progress = 0.0
		return
	var id: StringName = train_queue[0]
	var d: UnitDef = Cfg.unit(id)
	if d == null:
		train_queue.pop_front()
		return
	var total: float = maxf(d.train_time * _train_time_multiplier(), 0.2)
	train_progress += dt / total
	if train_progress < 1.0:
		return
	train_progress = 0.0
	train_queue.pop_front()
	_spawn_trained(id)


## 训练耗时倍率（难度档只影响 AI，玩家恒 1.0）
func _train_time_multiplier() -> float:
	if faction == null or faction.is_player:
		return 1.0
	return maxf(Cfg.difficulty(Game.difficulty_index).train_time_multiplier, 0.1)


## 出兵：在建筑正面 rally_spread 半径内生成，有集结点就走过去
func _spawn_trained(id: StringName) -> void:
	if faction == null:
		return
	var pos: Vector3 = spawn_point()
	var world_parent: Node3D = RtsWorld.level()
	if world_parent == null:
		world_parent = get_parent() as Node3D
	var u: Node3D = Game.spawn_unit(faction, id, pos, world_parent)
	if u == null:
		return
	if has_rally and u.has_method("order_move"):
		u.call("order_move", RtsWorld.walkable_pos(rally_point))


## 出兵点：建筑正前方（-Z 侧）散开
func spawn_point() -> Vector3:
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3(0.0, 0.0, 1.0)
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var front: float = (def.body_radius + 1.2) if def != null else 2.0
	var lateral: float = randf_range(-1.0, 1.0) * Cfg.game.rally_spread
	var forward_extra: float = randf_range(0.0, 0.6) * Cfg.game.rally_spread
	var p: Vector3 = global_position + fwd * (front + forward_extra) + right * lateral
	return RtsWorld.walkable_pos(p)


## 设集结点：同时在地面立一面小旗（旗是建筑的孩子，建筑没了旗跟着没）
func set_rally(pos: Vector3) -> void:
	rally_point = RtsWorld.walkable_pos(pos)
	has_rally = true
	_refresh_rally_flag()


## 拔掉集结点（命令卡的"取消集结点"用；旗子跟着消失）
func clear_rally() -> void:
	has_rally = false
	rally_point = Vector3.ZERO
	_refresh_rally_flag()


## 同步小旗的显隐与位置（懒创建：没设过集结点就不花这个节点）
func _refresh_rally_flag() -> void:
	if not has_rally:
		if _rally_flag != null and is_instance_valid(_rally_flag):
			_rally_flag.visible = false
		return
	if _rally_flag == null or not is_instance_valid(_rally_flag):
		_rally_flag = _build_rally_flag()
	if _rally_flag == null:
		return
	_rally_flag.visible = true
	_rally_flag.global_position = RtsWorld.ground(rally_point)


## 地面小旗：旗杆 + 阵营色旗面 + 落点圈。纯代码生成，吃 faction.color。
## 为什么不用 GLB：它得随阵营换色，而且要能随时拔掉 —— 代码生成最省事。
func _build_rally_flag() -> Node3D:
	var root := Node3D.new()
	root.name = "集结点旗"
	add_child(root)

	var col: Color = faction.color if faction != null else Color(0.90, 0.75, 0.30)
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.30, 0.28, 0.26)
	metal.roughness = 0.85
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = col
	cloth.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	cloth.no_depth_test = false

	# 旗杆
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.045
	cyl.bottom_radius = 0.045
	cyl.height = 2.0
	cyl.radial_segments = 6
	pole.mesh = cyl
	pole.material_override = metal
	pole.position = Vector3(0.0, 1.0, 0.0)
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pole)

	# 旗面
	var flag := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.86, 0.52)
	flag.mesh = quad
	flag.material_override = cloth
	flag.position = Vector3(0.45, 1.62, 0.0)
	flag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(flag)

	# 地面落点圈：告诉玩家"兵出来会站这儿"
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.55
	torus.outer_radius = 0.76
	torus.rings = 16
	torus.ring_segments = 6
	ring.mesh = torus
	ring.material_override = cloth
	ring.position = Vector3(0.0, 0.05, 0.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	return root


# ===========================================================================
# 研究（铁匠铺）
# ===========================================================================

## 开始一项研究（attack_up / armor_up）：**当场扣费**，可以逐级升，但不能并行。
## 返回 false 的原因由调用方用 research_block_reason() 解释（界面提示用）。
func research(id: StringName) -> bool:
	if def == null or not is_constructed:
		return false
	if not def.researches.has(id):
		return false
	if _research_id != &"":
		return false
	if not RtsCombat.has_research(id):
		return false
	var rd: ResearchDef = Cfg.research(id)
	if rd == null:
		return false
	if faction != null and RtsCombat.research_level(faction, id) >= maxi(rd.max_level, 1):
		return false
	if faction != null:
		if faction.gold < rd.gold_cost or faction.wood < rd.wood_cost:
			return false
		faction.gold -= rd.gold_cost
		faction.wood -= rd.wood_cost
		Game.resources_changed.emit(faction)
	_research_id = id
	_research_t = 0.0
	return true


## 研究为什么点不了的中文原因（空串 = 可以研究）。界面/提示共用这一处判定。
func research_block_reason(id: StringName) -> String:
	if def == null or not is_constructed:
		return "建筑还没完工"
	if not def.researches.has(id):
		return "这里不能研究这项"
	var rd: ResearchDef = Cfg.research(id)
	if rd == null:
		return "未定义的研究"
	if _research_id != &"":
		return "已有研究在进行中"
	if faction != null and RtsCombat.research_level(faction, id) >= maxi(rd.max_level, 1):
		return "%s 已满级" % rd.display_name
	if faction != null and (faction.gold < rd.gold_cost or faction.wood < rd.wood_cost):
		return "资源不足：%s" % rd.display_name
	return ""


## 当前正在研究的研究 id（空闲返回空串）
func current_research() -> StringName:
	return _research_id


## 是否正在研究
func is_researching() -> bool:
	return _research_id != &""


## 研究进度（0~1）
func research_progress() -> float:
	return _research_t


## 研究推进
func _tick_research(dt: float) -> void:
	if _research_id == &"":
		return
	var rd: ResearchDef = Cfg.research(_research_id)
	var base_time: float = rd.research_time if rd != null else 25.0
	var total: float = maxf(base_time * _train_time_multiplier(), 1.0)
	_research_t += dt / total
	if _research_t < 1.0:
		return
	var done: StringName = _research_id
	_research_id = &""
	_research_t = 0.0
	RtsCombat.apply_research(faction, done)
	if faction != null and faction.is_player:
		Game.toast("研究完成：%s" % RtsCombat.research_name(done), Color(0.75, 0.95, 1.0))


# ===========================================================================
# 每帧
# ===========================================================================

## 建筑只跑队列/研究；完工的箭塔靠 RtsUnit 的战斗逻辑自动开火
func _tick_extra(dt: float) -> void:
	if not is_constructed:
		return
	_tick_train(dt)
	_tick_research(dt)


## 没建完的房子不许索敌
func _acquire(dt: float) -> void:
	if not is_constructed:
		return
	super._acquire(dt)


func _update_attack(dt: float) -> void:
	if not is_constructed:
		return
	super._update_attack(dt)


## 被摧毁：清占地（否则那块地永远走不进去）+ 更大的震屏
func _die() -> void:
	if _dying:
		return
	super._die()
	RtsWorld.clear_footprint(self)
	if RtsCombat.is_near_camera(global_position):
		Game.shake(Cfg.game.shake_on_building_destroyed)
	if faction != null and faction.is_player:
		Game.toast("%s 被摧毁！" % (def.display_name if def != null else "建筑"),
				Color(1.0, 0.35, 0.3))
