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

# --- 表现（SLEDGE）：工地 / 受击 / 倒塌 ---
## 表现层脚本用 preload 而不是全局类名：新脚本第一次进工程时 .godot 的 class 缓存可能还没扫到，
## preload 在解析期就能解析到，不会因为缓存陈旧把整个文件拖成编译错误。
const BUILD_SITE := preload("res://代码/单位/工地表现.gd")
const VFXKIT := preload("res://代码/美术/建造表现.gd")
## 倒塌用时（秒）：先晃后倒，0.9~1.4 之间最像整栋楼
const COLLAPSE_TIME: float = 1.35
## 废墟停留时间（秒）
const RUINS_LINGER: float = 5.0
## 受击尘土的最小间隔（秒）：集火时不至于每颗子弹都爆一次
const HIT_FX_GAP: float = 0.32

const PAD_SCRIPT := preload("res://代码/美术/建筑基座.gd")

## 工地表现（未完工时存在；完工/被拆后由它自己释放）
var _site_fx: Node3D = null
## 地基台（贴地夯土 + 石砌镶边；随建筑生死）
var _pad: Node3D = null
## 是否已进入倒塌（只进一次）
var _collapsing: bool = false
var _collapse_t: float = 0.0
var _collapse_tilt: Vector3 = Vector3.ZERO
var _collapse_y0: float = 0.0
var _collapse_yaw0: float = 0.0
var _collapse_dusted: bool = false
## 倒塌期间持续掉灰的节流（秒）
var _collapse_dust_t: float = 0.0
## 受击表现节流（毫秒时间戳）
var _hit_fx_ms: int = -10000
## 裂缝（血量掉到 90% / 67% / 34% 各加一条）
var _crack_root: Node3D = null
var _crack_count: int = 0


# ===========================================================================
# 装配
# ===========================================================================

## 外墙观建好之后立刻铺地基台（建筑与地形的接缝在这里闭合）
func _ensure_visual() -> void:
	super._ensure_visual()
	_install_pad()


## 地基台只建一次；没有占地数据（自检里的假建筑）就跳过
##
## 2026-10-23 停用：玩家反馈"所有建筑的地面都出了问题"——
## 程序化地台在 RTS 机位下读起来是一圈"贴上去的灰板"，比原来的接缝更难看。
## 地面问题改为在**地形着色**层解决（基地半径内不撒土斑），不再往建筑底下塞几何。
func _install_pad() -> void:
	if def == null or visual == null:
		return
	# ★ 真正要治的是"兵营前面那块训练场在闪"：
	#   资产包里的兵营自带一块几乎贴地的沙土场地（plinth_a 网格的一部分），
	#   它的顶面和地形/台阶几乎共面 → 深度值打架 → 远近切换时整块闪。
	#   整栋模型抬 4.5cm 就好了：RTS 机位看不出来，深度差足够分出前后。
	#   （不再往建筑下面塞程序化地台 —— 那在低机位下会读成"贴了一块灰板"。）
	visual.position.y = PAD_LIFT


## 模型整体抬升（米）：治 z-fighting，太小不够、太大会看出悬空
const PAD_LIFT := 0.090


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
	_spawn_site()


## 关卡用来强制设完工状态
func set_constructed(v: bool) -> void:
	is_constructed = v
	progress = 1.0 if v else 0.0
	_last_progress = progress
	# 关卡把工地"催熟"（例如脚本直接把半成品设成完工）时，工地表现也要收尾
	if v and _site_fx != null and is_instance_valid(_site_fx):
		_site_fx.call("finish")
		_site_fx = null


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


## 这个交汇点收不收某种资源（RtsConst.Harvest）：大本营金木全收，伐木场只收木材
func accepts_harvest(kind: int) -> bool:
	return def != null and def.accepts_harvest(kind)


## 这栋楼会不会主动开火（箭塔 = true，哨塔 = false）
## 判据只有一条：数据层的 attack_damage > 0 且 attack_range > 0（见 UnitDef.can_attack）
func is_armed() -> bool:
	return is_constructed and def != null and def.can_attack()


# ===========================================================================
# 建造进度
# ===========================================================================

## 农民在工地旁调这个：推进建造进度（多个农民同时建会更快）
func advance_construction(dt: float, builder: Node3D) -> void:
	if is_constructed or def == null:
		return
	var total: float = maxf(def.train_time, 0.5)
	progress = clampf(progress + dt / total, 0.0, 1.0)

	# 工地表现：墙随进度从下往上长、脚手架跟着升、农民抡锤时墙根冒土
	if _site_fx != null and is_instance_valid(_site_fx):
		_site_fx.call("set_progress", progress)
		_site_fx.call("strike", builder.global_position if builder != null and is_instance_valid(builder) else Vector3.ZERO)

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
	# 完工表现：脚手架散落 + 尘土爆发 + 相机轻震 + 高光闪一下（都在 BuildSite 里）
	if _site_fx != null and is_instance_valid(_site_fx):
		_site_fx.call("finish")
		_site_fx = null
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


## 取消队列里**指定的一项**（2026-11-01：玩家点队列格直接退这一条）。
## 退款按该条目的原价全额；退的是队首时把进度归零（当前训练作废）。
func cancel_train_at(i: int) -> bool:
	if i < 0 or i >= train_queue.size():
		return false
	var id: StringName = train_queue[i]
	train_queue.remove_at(i)
	if i == 0:
		train_progress = 0.0
	var d: UnitDef = Cfg.unit(id)
	if d != null and faction != null:
		Game.add_resource(faction, d.gold_cost, d.wood_cost)
	return true


## 取消当前研究（全额退款）。没有研究在进行时返回 false。
func cancel_research() -> bool:
	if _research_id == &"":
		return false
	var rd: ResearchDef = Cfg.research(_research_id)
	_research_id = &""
	_research_t = 0.0
	if rd != null and faction != null:
		faction.gold += rd.gold_cost
		faction.wood += rd.wood_cost
		Game.resources_changed.emit(faction)
	return true


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
	# 抬到 0.18（地形 0 + 土路 0.10 之上）：0.05 会和地面/路面共面，
	# 远看就是"兵营前面那圈训练场在闪"—— 典型的 z-fighting。
	ring.position = Vector3(0.0, 0.18, 0.0)
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
# 修理（农民右键己方受损建筑）
# ===========================================================================
#
# 规则（2026-10-31 新增，配伐木场「修缮工艺」）：
#   · 只有**已完工**且**掉血**的建筑能修；工地走建造流程，不走修理；
#   · 修理速度 = 最大血量 × REPAIR_HP_PER_SEC / 秒，多个农民叠加；
#   · 修理**要吃木材**：每修 1 点血耗 REPAIR_WOOD_PER_HP 木（1500 血楼全修 ≈ 30 木），
#     伐木场研究「修缮工艺」后消耗减半（RtsCombat.repair_cost_mult）；
#   · 木材不够就**停工**并提示，绝不"免费修好"。

## 每秒修好的血量比例（占最大血量）
const REPAIR_HP_PER_SEC: float = 0.022
## 每修 1 点血消耗的木材（未打折）
const REPAIR_WOOD_PER_HP: float = 0.02
## 未付清的木材零头（浮点累加，凑够 1 点才扣，避免每帧取整扣钱）
var _repair_debt: float = 0.0
## 上次"木材不足"提示的时间（节流，别每帧刷屏）
var _repair_warn_t: float = -999.0
## 修理尘土的节流时间戳（毫秒；**独立于受击节流**，两者互不干扰）
var _repair_fx_ms: int = -10000


## 这栋楼现在能不能修（能不能修 ≠ 修不修得起；钱在 repair_step 里算）
func can_repair() -> bool:
	if def == null or not is_alive():
		return false
	if not is_constructed:
		return false
	return hp < def.max_hp - 0.5


## 修满还差多少血
func missing_hp() -> float:
	if def == null:
		return 0.0
	return maxf(def.max_hp - hp, 0.0)


## 把整栋楼修满需要多少木材（界面用来显示"修满约需 28 木"，含研究折扣）
func repair_wood_for_full() -> int:
	if def == null or faction == null:
		return 0
	var rate: float = RtsCombat.repair_cost_mult(faction)
	return int(ceil(missing_hp() * REPAIR_WOOD_PER_HP * rate))


## 农民在建筑旁调这个：推进修理（多个农民同时修会更快）
func repair_step(dt: float, _worker: Node3D) -> void:
	if not can_repair() or faction == null:
		return
	var gain: float = def.max_hp * REPAIR_HP_PER_SEC * dt
	gain = minf(gain, missing_hp())
	if gain <= 0.0:
		return
	var rate: float = RtsCombat.repair_cost_mult(faction)
	_repair_debt += gain * REPAIR_WOOD_PER_HP * rate
	var pay: int = int(floor(_repair_debt))
	if pay > 0:
		if faction.wood < pay:
			# 木材不够：这一帧不修（不白送血），每 4 秒提示一次
			if faction.is_player and Game.elapsed - _repair_warn_t > 4.0:
				_repair_warn_t = Game.elapsed
				Game.toast("木材不足，无法修理 %s" % def.display_name, Color(1, 0.6, 0.35))
			return
		faction.wood -= pay
		_repair_debt -= float(pay)
		Game.resources_changed.emit(faction)
	hp = minf(hp + gain, def.max_hp)
	# 修理时墙根冒一点尘土：让"有人在修"看得见（不刷屏，靠节流）
	var now: int = Time.get_ticks_msec()
	if now - _repair_fx_ms > 620:
		_repair_fx_ms = now
		VFXKIT.dust(global_position + Vector3(0.0, 0.6, 0.0), 2, 0.30,
				Color(0.72, 0.66, 0.52))
	if hp >= def.max_hp - 0.05:
		_repair_debt = 0.0
		if faction.is_player:
			Game.toast("%s 已修好" % def.display_name, Color(0.72, 1.0, 0.72))


# ===========================================================================
# 每帧
# ===========================================================================

## 建筑只跑队列/研究；完工的箭塔靠 RtsUnit 的战斗逻辑自动开火
func _tick_extra(dt: float) -> void:
	if not is_constructed:
		return
	_tick_train(dt)
	_tick_research(dt)
	_tick_aura(dt)
	_tick_warning(dt)


# ===========================================================================
# 新建筑的专属逻辑
# ===========================================================================

## 预警节流（秒）
const WARN_GAP: float = 8.0
## 上一次预警的时间 / 上一次报的是哪个"邻居"
var _warn_t: float = -999.0
var _warn_seen: int = 0


## 神秘圣地的**法力之泉**：半径内的友军每秒多回 aura_mana_regen 法力。
## 为什么做成"建筑推"而不是"单位拉"：光环是建筑属性，拆了就该消失，
## 把半径判定放在建筑侧，建筑一死条件自然不成立，不用额外清理。
func _tick_aura(dt: float) -> void:
	if def == null or def.aura_radius <= 0.0 or def.aura_mana_regen <= 0.0:
		return
	if faction == null:
		return
	var r2: float = def.aura_radius * def.aura_radius
	for u in faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		if u.global_position.distance_squared_to(global_position) > r2:
			continue
		if u.has_method("add_mana"):
			u.call("add_mana", def.aura_mana_regen * dt)


## 哨塔的**预警**：敌方单位进入 detect_radius 就朝玩家报一条提示。
## 只对玩家的盟友阵营生效（AI 不需要提示，AI 的"耳朵"是它自己的威胁扫描）。
func _tick_warning(_dt: float) -> void:
	if def == null or def.detect_radius <= 0.0:
		return
	if faction == null or not Game.is_ally_of_player(faction):
		return
	if Game.elapsed - _warn_t < WARN_GAP:
		return
	var r2: float = def.detect_radius * def.detect_radius
	var seen: int = 0
	for foe in Game.enemies_of(faction):
		for u in foe.units:
			if u == null or not is_instance_valid(u) or not u.is_alive():
				continue
			if u.global_position.distance_squared_to(global_position) > r2:
				continue
			seen += 1
	if seen <= 0 or seen == _warn_seen:
		return
	_warn_seen = seen
	_warn_t = Game.elapsed
	Game.toast("哨塔预警：%d 个敌军接近 (%.0f, %.0f)" % [
		seen, global_position.x, global_position.z], Color(1.0, 0.82, 0.42))


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
##
## 表现口径（任务书 §3.3）：**不整栋沉进地里**。这里只做"死亡瞬间"这一拍：
##   ① 立刻停训练/研究、立刻清占地、立刻发 unit_died（信号语义不变，胜负判定不能等）；
##   ② 进倒塌状态，交给 _update_dead() 走"倾斜 → 落地扬尘 → 留废墟"三段。
func _die() -> void:
	if _dying:
		return
	_abort_work()
	super._die()
	RtsWorld.clear_footprint(self)
	# 还没盖完就被拆：脚手架跟着倒，别留一副好端端的架子立在那里
	if _site_fx != null and is_instance_valid(_site_fx):
		_site_fx.call("abort")
		_site_fx = null
	if RtsCombat.is_near_camera(global_position):
		Game.shake(Cfg.game.shake_on_building_destroyed)
	if faction != null and faction.is_player:
		Game.toast("%s 被摧毁！" % (def.display_name if def != null else "建筑"),
				Color(1.0, 0.35, 0.3))


# ===========================================================================
# 表现：工地 / 受击 / 倒塌（SLEDGE）
# ===========================================================================

## 建工地表现节点（只在 setup_construction 走这条；开局建筑没有工地）
func _spawn_site() -> void:
	if _site_fx != null and is_instance_valid(_site_fx):
		return
	if visual == null:
		return
	_site_fx = BUILD_SITE.new()
	add_child(_site_fx)
	var col: Color = faction.color if faction != null else Color(0.35, 0.45, 0.62)
	_site_fx.call("attach", self, col)


## 停掉所有"生产线"：建筑一死，训练队列和研究都不许再动（否则死了还能出兵）
func _abort_work() -> void:
	train_queue.clear()
	train_progress = 0.0
	_research_id = &""
	_research_t = 0.0


## 受击反馈：墙根尘土 + 石屑 + 极轻震屏（按 HIT_FX_GAP 节流）
func _damage_fx() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _hit_fx_ms < int(HIT_FX_GAP * 1000.0):
		return
	_hit_fx_ms = now
	var hx: float = float(def.footprint.x) * 0.5 if def != null else 2.0
	var hz: float = float(def.footprint.y) * 0.5 if def != null else 2.0
	var ang: float = randf() * TAU
	var at: Vector3 = global_position + Vector3(cos(ang) * hx * 0.9,
			randf_range(0.45, 1.9), sin(ang) * hz * 0.9)
	VFXKIT.dust(at, 5, 0.45, Color(0.62, 0.56, 0.46))
	VFXKIT.chips(at, Color(0.54, 0.52, 0.48), 4)
	if RtsCombat.is_near_camera(global_position):
		Game.shake(0.05)


## 血量跌破 90% / 67% / 34% 各加一条裂缝（真几何，不靠贴图）
func _maybe_crack() -> void:
	if def == null:
		return
	var ratio: float = hp / maxf(def.max_hp, 1.0)
	var want: int = 0
	if ratio < 0.34:
		want = 3
	elif ratio < 0.67:
		want = 2
	elif ratio < 0.90:
		want = 1
	while _crack_count < want:
		_add_crack()


func _add_crack() -> void:
	if _crack_root == null or not is_instance_valid(_crack_root):
		_crack_root = Node3D.new()
		_crack_root.name = "损坏"
		add_child(_crack_root)
	var hx: float = float(def.footprint.x) * 0.5 if def != null else 2.0
	var hz: float = float(def.footprint.y) * 0.5 if def != null else 2.0
	var h: float = def.height if def != null else 3.0
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var tall: float = randf_range(0.8, 1.7)
	bm.size = Vector3(0.075, tall, 0.055)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.10, 0.09, 0.08)
	m.roughness = 0.92
	mi.material_override = m
	var y: float = randf_range(0.35, maxf(0.6, h * 0.55))
	match randi() % 4:
		0:
			mi.position = Vector3(randf_range(-hx * 0.7, hx * 0.7), y, -hz - 0.02)
		1:
			mi.position = Vector3(randf_range(-hx * 0.7, hx * 0.7), y, hz + 0.02)
		2:
			mi.position = Vector3(-hx - 0.02, y, randf_range(-hz * 0.7, hz * 0.7))
			mi.rotation.y = PI * 0.5
		_:
			mi.position = Vector3(hx + 0.02, y, randf_range(-hz * 0.7, hz * 0.7))
			mi.rotation.y = PI * 0.5
	mi.rotation.z = randf_range(-0.35, 0.35)
	_crack_root.add_child(mi)
	_crack_count += 1


## 受击 → 先扣血，再补表现（顺序不能反：表现要用扣完血的血量决定裂缝数量）
func take_damage(amount: float, type: int, from: Node3D) -> void:
	var before: float = hp
	super.take_damage(amount, type, from)
	if _dying or not is_alive():
		return
	if hp < before:
		_damage_fx()
		_maybe_crack()


## 倒塌第一拍：定方向、掉一批瓦石、开始计时
func _begin_collapse() -> void:
	_collapsing = true
	_collapse_t = 0.0
	_collapse_y0 = position.y
	_collapse_yaw0 = rotation.y
	var sx: float = 1.0 if randf() > 0.5 else -1.0
	var sz: float = 1.0 if randf() > 0.5 else -1.0
	_collapse_tilt = Vector3(sx * randf_range(0.22, 0.38), 0.0, sz * randf_range(0.22, 0.38))
	var h: float = def.height if def != null else 3.0
	VFXKIT.debris(global_position + Vector3.UP * h * 0.55, Color(0.48, 0.45, 0.41), 8, 0.22)


## 死亡后的每一帧：三段式
##   ① 0~45%：只晃不掉渣（先让玩家看清"它要塌了"）
##   ② 45%~100%：倾斜加剧、开始往下沉、持续掉渣
##   ③ 100%：落地扬尘 + 碎块四散 + 震屏 + 生成废墟 → 本节点销毁（废墟留在原地淡出）
func _update_dead(dt: float) -> void:
	if not _collapsing:
		_begin_collapse()
	_collapse_t += dt
	var k: float = clampf(_collapse_t / COLLAPSE_TIME, 0.0, 1.0)
	var e: float = k * k
	rotation = Vector3(_collapse_tilt.x * e,
			_collapse_yaw0 + _collapse_tilt.x * e * 0.35,
			_collapse_tilt.z * e)
	position.y = _collapse_y0 - 0.42 * e
	if not _collapse_dusted and k > 0.45:
		_collapse_dusted = true
		VFXKIT.dust(global_position + Vector3.UP * 1.0, 10, 1.0, Color(0.60, 0.55, 0.44))
	# 倒的过程中一路掉灰：静帧和实机都能看出"它在塌"，不是单纯在转
	if k > 0.2:
		_collapse_dust_t -= dt
		if _collapse_dust_t <= 0.0:
			_collapse_dust_t = 0.22
			var hx: float = float(def.footprint.x) * 0.5 if def != null else 2.0
			var hz: float = float(def.footprint.y) * 0.5 if def != null else 2.0
			var edge: Vector3 = global_position + Vector3(randf_range(-hx, hx),
					randf_range(0.4, 1.6), randf_range(-hz, hz))
			VFXKIT.dust(edge, 4, 0.6, Color(0.62, 0.56, 0.45))
	if k >= 1.0:
		_land_and_ruins()


## 落地：扬尘 / 碎块 / 震屏 / 废墟，然后把建筑本体清掉
func _land_and_ruins() -> void:
	var base: Vector3 = global_position
	base.y = RtsWorld.height_at(base.x, base.z)
	var fp: Vector2i = def.footprint if def != null else Vector2i(4, 4)
	var h: float = def.height if def != null else 4.0
	var hx: float = float(fp.x) * 0.5
	var hz: float = float(fp.y) * 0.5
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			VFXKIT.dust(base + Vector3(sx * hx * 0.8, 0.3, sz * hz * 0.8),
					14, 1.2, Color(0.66, 0.60, 0.48))
	VFXKIT.debris(base + Vector3.UP * 0.6, Color(0.46, 0.43, 0.39), 18, 0.30)
	if RtsCombat.is_near_camera(base):
		Game.shake(0.22)
	var col: Color = faction.color if faction != null else Color(0.40, 0.50, 0.70)
	VFXKIT.make_ruins(base, fp, h, col, RUINS_LINGER)
	if visual != null:
		visual.visible = false
	queue_free()
