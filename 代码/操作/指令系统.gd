class_name CommandSystem
extends Node
## **指令系统（HAWKEYE）**
##
## 职责（对齐 文档/作战条令.md §7）：
##   - 右键上下文：点敌人 = 攻击；点资源 = 采集（农民）；点自己建筑 = 送资源/设集结点；
##     点空地 = 移动（带**编队偏移**，不让一队人挤在一个点上）
##   - 快捷键：攻击移动 / 停止 / 保持 / 建造 / 技能 1-3
##   - "等待落点"状态机：攻击移动、建造、施法都需要下一次左键给目标点，
##     期间界面显示提示、左键归本系统（选择系统会主动让路）
##   - 供界面调用的服务：训练单位、建造菜单、技能、取消
##
## 分工注意：本系统**只下达指令**，不实现单位行为（那是 SLEDGE 的 RtsUnit）。
## 所有调用都走 §6 冻结的 order_* 接口；对尚未实现的接口用 has_method 兜底，
## 保证在单位脚本还是骨架时也不会崩。
##
## 资源扣费纪律：训练/建造都在**下达那一刻**扣费（魔兽3 的做法），
## 失败给出中文提示，绝不让玩家白点。

## 等待落点的状态
enum Pending {
	NONE = 0,
	ATTACK_MOVE = 1,
	BUILD = 2,
	CAST = 3,
}

## 编队间距（米）
const FORMATION_SPACING := 1.9
## 训练队列上限
const TRAIN_QUEUE_MAX := 5

## 当前等待状态
var pending: int = Pending.NONE
## 等待建造的建筑 id
var pending_build: StringName = &""
## 等待施法的技能 id
var pending_ability: StringName = &""

## 建造预览（半透明盒子）
var _ghost: MeshInstance3D = null
var _ghost_mat: StandardMaterial3D = null

## 缓存的兄弟节点
var _selection_system: Node = null
var _hud: Node = null


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	Game.game_over.connect(_on_game_over)


func _process(_delta: float) -> void:
	_cache_siblings()
	_handle_hotkeys()
	_update_ghost()


# ===========================================================================
# 对外接口（界面调这些）
# ===========================================================================

## 是否在等落点（选择系统据此让出左键）
func has_pending() -> bool:
	return pending != Pending.NONE


## 当前等待状态的提示文案（界面显示在鼠标旁）
func pending_prompt() -> String:
	match pending:
		Pending.ATTACK_MOVE:
			return "左键选择攻击移动目标点（右键取消）"
		Pending.BUILD:
			var d: UnitDef = Cfg.unit(pending_build)
			return "左键选择建造位置：%s（右键取消）" % (d.display_name if d != null else String(pending_build))
		Pending.CAST:
			return "左键选择技能目标点（右键取消）"
		_:
			return ""


## 取消当前等待状态
func request_cancel() -> void:
	pending = Pending.NONE
	pending_build = &""
	pending_ability = &""
	_free_ghost()


## 训练一个单位（命令卡调用）：选中的建筑必须有这个训练项
func request_train(unit_id: StringName) -> void:
	var b := _primary_building()
	if b == null:
		return
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null:
		return
	if not b.def.trains.has(unit_id):
		_toast("这里造不了 %s" % d.display_name, _warn())
		return
	if b.train_queue.size() >= TRAIN_QUEUE_MAX:
		_toast("训练队列已满", _warn())
		return
	if not Game.can_afford(Game.player_faction, unit_id):
		_toast("资源不足：%s" % d.display_name, _warn())
		return
	if not Game.pay(Game.player_faction, unit_id):
		_toast("资源不足：%s" % d.display_name, _warn())
		return
	b.train_queue.append(unit_id)
	_toast("开始训练 %s" % d.display_name, _accent())


## 取消训练队列里的最后一个（命令卡"取消训练"用）
func request_cancel_train() -> void:
	var b := _primary_building()
	if b == null or b.train_queue.is_empty():
		return
	var id: StringName = b.train_queue.pop_back()
	var d: UnitDef = Cfg.unit(id)
	if d != null:
		Game.add_resource(Game.player_faction, d.gold_cost, d.wood_cost)
		_toast("已取消 %s" % d.display_name, _accent())


## 进入建造模式（命令卡/快捷键 B 调用）
func request_build(building_id: StringName) -> void:
	var d: UnitDef = Cfg.unit(building_id)
	if d == null:
		return
	if _selected_workers().is_empty():
		_toast("需要选中农民才能建造", _warn())
		return
	pending = Pending.BUILD
	pending_build = building_id
	pending_ability = &""
	_make_ghost(d)


## 选择技能（命令卡/数字键调用）
func request_ability(ability_id: StringName) -> void:
	pending = Pending.CAST
	pending_ability = ability_id
	pending_build = &""
	_free_ghost()


## 全部停止
func request_stop() -> void:
	_issue_simple(RtsConst.Order.STOP, "停止")


## 全部原地警戒
func request_hold() -> void:
	_issue_simple(RtsConst.Order.HOLD, "原地警戒")


## 巡逻模式是否已经武装（下一次左键点地面 = 下达巡逻）
var _patrol_next: bool = false


## 进入巡逻模式（等待玩家点落点）。在"当前位置 ↔ 点击点"之间往返，路上遇敌就打。
func request_patrol() -> void:
	if _selected_units().is_empty():
		return
	pending = Pending.ATTACK_MOVE
	pending_build = &""
	pending_ability = &""
	_patrol_next = true
	_free_ghost()


## 真的下达巡逻
func _patrol(ground: Vector3) -> void:
	var units := _selected_units()
	if units.is_empty():
		return
	var did: int = 0
	for u in units:
		if u.has_method("order_patrol"):
			u.call("order_patrol", ground)
			did += 1
	Game.order_issued.emit(units, RtsConst.Order.ATTACK_MOVE, ground, null)
	Game.notify.emit("巡逻：%d 个单位" % did, Cfg.game.hud_accent)


## 攻击移动（等待落点）
func request_attack_move() -> void:
	if _selected_units().is_empty():
		return
	pending = Pending.ATTACK_MOVE
	pending_build = &""
	pending_ability = &""
	_patrol_next = false
	_free_ghost()


# ===========================================================================
# 输入
# ===========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_on_right_click(mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and pending != Pending.NONE:
			_on_pending_left_click(mb.position)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_ESCAPE and pending != Pending.NONE:
			request_cancel()
			get_viewport().set_input_as_handled()


## 右键：要么取消等待，要么下上下文指令
func _on_right_click(screen_pos: Vector2) -> void:
	if _ui_blocks_world(screen_pos):
		return
	if pending != Pending.NONE:
		request_cancel()
		get_viewport().set_input_as_handled()
		return
	_context_order(screen_pos)
	get_viewport().set_input_as_handled()


## 等待落点时的左键
func _on_pending_left_click(screen_pos: Vector2) -> void:
	if _ui_blocks_world(screen_pos):
		return
	var ground := _ground_at(screen_pos)
	match pending:
		Pending.ATTACK_MOVE:
			pending = Pending.NONE
			if _patrol_next:
				_patrol_next = false
				_patrol(ground)
			else:
				_attack_move(ground, screen_pos)
		Pending.BUILD:
			_place_building(ground)
		Pending.CAST:
			var ab := pending_ability
			pending = Pending.NONE
			pending_ability = &""
			_cast_at(ab, ground, screen_pos)
	get_viewport().set_input_as_handled()


## 快捷键（每帧轮询 action；注意输入配置里 攻击移动 是 F，不是 A）
func _handle_hotkeys() -> void:
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	if Input.is_action_just_pressed(InputSetup.CMD_ATTACK_MOVE):
		request_attack_move()
	elif Input.is_action_just_pressed(InputSetup.CMD_STOP):
		request_stop()
	elif Input.is_action_just_pressed(InputSetup.CMD_HOLD):
		request_hold()
	elif Input.is_action_just_pressed(InputSetup.UI_BUILD):
		_toggle_build_menu()
	elif Input.is_action_just_pressed(InputSetup.ABILITY_1):
		_ability_slot(0)
	elif Input.is_action_just_pressed(InputSetup.ABILITY_2):
		_ability_slot(1)
	elif Input.is_action_just_pressed(InputSetup.ABILITY_3):
		_ability_slot(2)


## 按技能槽位施法（以主选中单位的 abilities 数组为准）
func _ability_slot(index: int) -> void:
	var u := _primary_unit()
	if u == null or u.def == null:
		return
	if index < 0 or index >= u.def.abilities.size():
		return
	request_ability(u.def.abilities[index])


# ===========================================================================
# 右键上下文
# ===========================================================================

## 右键上下文指令（魔兽3 的四种情况）
func _context_order(screen_pos: Vector2) -> void:
	var units := _selected_units()
	if units.is_empty():
		return
	var cam := _camera()
	if cam == null:
		return
	var ro: Vector3 = cam.project_ray_origin(screen_pos)
	var rd: Vector3 = cam.project_ray_normal(screen_pos)
	var target := _pick_any(ro, rd)
	var ground := _ground_at(screen_pos)
	var pl := Game.player_faction

	# --- 1. 点到可采集物 ---
	if target is RtsHarvestable:
		var node := target as RtsHarvestable
		var workers := _selected_workers()
		if not workers.is_empty():
			for w in workers:
				_order_gather(w, node)
			Game.order_issued.emit(workers, RtsConst.Order.GATHER, node.global_position, node)
			_toast("采集%s" % (node.def.display_name if node.def != null else "资源"), _accent())
			return
		# 非农民：走过去（顺手，不报错）
		_issue_move(units, _walkable(node.global_position))
		return

	# --- 2. 点到敌方单位/建筑 → 攻击 ---
	if target is RtsUnit and pl != null and target.get("faction") != pl:
		var foe := target as RtsUnit
		if foe.is_alive():
			for u in units:
				if u.has_method("order_attack"):
					u.order_attack(foe)
			Game.order_issued.emit(units, RtsConst.Order.ATTACK, foe.global_position, foe)
			_toast("攻击 %s" % (foe.def.display_name if foe.def != null else "敌人"), _warn())
			return

	# --- 3. 点到自己建筑 ---
	if target is RtsBuilding and target.get("faction") == pl:
		var b := target as RtsBuilding
		# 选中的是己方建筑 → 设集结点
		if _primary_unit() == null:
			b.rally_point = _walkable(ground)
			b.has_rally = true
			_toast("%s 集结点已设置" % (b.def.display_name if b.def != null else "建筑"), _accent())
			return
		# 选中的是农民 → 送回资源（接口没实现就先把人带到建筑旁）
		var workers := _selected_workers()
		if not workers.is_empty():
			for w in workers:
				if w.has_method("order_return_res"):
					w.call("order_return_res")
				elif w.has_method("order_move"):
					w.order_move(_walkable(b.global_position))
			Game.order_issued.emit(workers, RtsConst.Order.RETURN_RES, b.global_position, b)
			return

	# --- 4. 点到空地 / 点到自己单位 → 移动 ---
	_issue_move(units, _walkable(ground))


## 带编队偏移的移动
func _issue_move(units: Array, center: Vector3) -> void:
	if units.is_empty():
		return
	var pts := _formation_points(center, units.size(), FORMATION_SPACING)
	for i in range(units.size()):
		var u = units[i]
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_method("order_move"):
			continue
		u.order_move(pts[i])
	Game.order_issued.emit(units, RtsConst.Order.MOVE, center, null)


## 攻击移动：有 order_attack_move 就用它，否则退化成"沿途有敌人就砍，没有就走"
func _attack_move(center: Vector3, screen_pos: Vector2) -> void:
	var units := _selected_units()
	if units.is_empty():
		return
	var cam := _camera()
	var near_foe: Node3D = null
	if cam != null:
		var ro: Vector3 = cam.project_ray_origin(screen_pos)
		var rd: Vector3 = cam.project_ray_normal(screen_pos)
		var t := _pick_any(ro, rd)
		if t is RtsUnit and t.get("faction") != Game.player_faction and (t as RtsUnit).is_alive():
			near_foe = t as Node3D
	var pts := _formation_points(center, units.size(), FORMATION_SPACING)
	for i in range(units.size()):
		var u = units[i]
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("order_attack_move"):
			u.call("order_attack_move", pts[i])
		elif near_foe != null and u.has_method("order_attack"):
			u.order_attack(near_foe)
		elif u.has_method("order_move"):
			u.order_move(pts[i])
	Game.order_issued.emit(units, RtsConst.Order.ATTACK_MOVE, center, near_foe)


## 施法
func _cast_at(ability: StringName, ground: Vector3, screen_pos: Vector2) -> void:
	var units := _selected_units()
	if units.is_empty():
		return
	var cam := _camera()
	var target: Node3D = null
	if cam != null:
		var ro: Vector3 = cam.project_ray_origin(screen_pos)
		var rd: Vector3 = cam.project_ray_normal(screen_pos)
		target = _pick_any(ro, rd)
	var any: bool = false
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("order_cast"):
			u.order_cast(ability, ground, target)
			any = true
	if any:
		Game.order_issued.emit(units, RtsConst.Order.CAST, ground, target)


## 停止 / 保持
func _issue_simple(order: int, label: String) -> void:
	var units := _selected_units()
	if units.is_empty():
		return
	for u in units:
		if order == RtsConst.Order.STOP and u.has_method("order_stop"):
			u.order_stop()
		elif order == RtsConst.Order.HOLD and u.has_method("order_hold"):
			u.order_hold()
	Game.order_issued.emit(units, order, Vector3.ZERO, null)
	_toast(label, _accent())


# ===========================================================================
# 建造
# ===========================================================================

## 放置建筑：校验 → 扣费 → 让每个选中的农民去造
func _place_building(ground: Vector3) -> void:
	var d: UnitDef = Cfg.unit(pending_build)
	var workers := _selected_workers()
	if d == null or workers.is_empty():
		request_cancel()
		return

	var pos := _snap_build_pos(ground, d.footprint)
	if not _can_place(pos, d):
		_toast("这里不能建造（地形/重叠/资源不足）", _warn())
		return
	if not Game.can_afford(Game.player_faction, pending_build):
		_toast("资源不足：%s" % d.display_name, _warn())
		return
	if not Game.pay(Game.player_faction, pending_build):
		_toast("资源不足：%s" % d.display_name, _warn())
		return

	for w in workers:
		if w.has_method("order_build"):
			w.order_build(d, pos)
	Game.order_issued.emit(workers, RtsConst.Order.BUILD, pos, null)
	_toast("建造 %s" % d.display_name, _accent())
	pending = Pending.NONE
	pending_build = &""
	_free_ghost()


## 能不能放（地形可建 + 不与已有建筑重叠）
func _can_place(pos: Vector3, d: UnitDef) -> bool:
	var lv := Game.level as RtsLevel
	if lv == null:
		return false
	if not lv.is_buildable(pos, d.footprint):
		return false
	# 别和已有建筑叠在一起（is_buildable 只看地形与寻路格，够用；这里再兜一层）
	var half := Vector2(d.footprint) * 0.5
	for b in Game.all_units():
		if b == null or not is_instance_valid(b):
			continue
		if not (b is RtsBuilding):
			continue
		var off: Vector3 = (b as Node3D).global_position - pos
		var bg := Vector2(off.x, off.z)
		var bh: Vector2 = Vector2((b as RtsUnit).def.footprint) * 0.5 if (b as RtsUnit).def != null else Vector2.ONE
		if absf(bg.x) < (half.x + bh.x) and absf(bg.y) < (half.y + bh.y):
			return false
	return true


## 把落点吸到"建筑中心格"上（占地偶数时对齐半格），减少半格错位
func _snap_build_pos(pos: Vector3, footprint: Vector2i) -> Vector3:
	var p := pos
	if footprint.x % 2 == 0:
		p.x = floorf(p.x) + 0.0
	else:
		p.x = floorf(p.x) + 0.5
	if footprint.y % 2 == 0:
		p.z = floorf(p.z) + 0.0
	else:
		p.z = floorf(p.z) + 0.5
	return _walkable(p)


# ===========================================================================
# 建造预览
# ===========================================================================

func _make_ghost(d: UnitDef) -> void:
	_free_ghost()
	var box := BoxMesh.new()
	var w: float = maxf(float(d.footprint.x), 1.0)
	var h: float = maxf(float(d.footprint.y), 1.0)
	box.size = Vector3(w, maxf(d.height, 1.0) * 0.55, h)

	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.35)

	_ghost = MeshInstance3D.new()
	_ghost.name = "建造预览"
	_ghost.mesh = box
	_ghost.material_override = _ghost_mat
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ghost)


## 预览跟随鼠标，颜色表示能否放
func _update_ghost() -> void:
	if _ghost == null or pending != Pending.BUILD:
		return
	var d: UnitDef = Cfg.unit(pending_build)
	if d == null:
		return
	var pos := _snap_build_pos(_ground_at(get_viewport().get_mouse_position()), d.footprint)
	var ok: bool = _can_place(pos, d)
	if _ghost_mat != null:
		_ghost_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.35) if ok else Color(1.0, 0.35, 0.3, 0.38)
	_ghost.global_position = pos + Vector3.UP * (maxf(d.height, 1.0) * 0.275)


func _free_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	_ghost_mat = null


# ===========================================================================
# 拾取 / 数学
# ===========================================================================

## 任意单位的实体拾取（敌我单位、建筑、可采集物都参与：右键要用）
func _pick_any(ray_o: Vector3, ray_d: Vector3) -> Node3D:
	var best: Node3D = null
	var best_t: float = INF
	for n in _pickables():
		var d := _def_of(n)
		var r: float = d.selection_radius if d != null and d.selection_radius > 0.0 else 0.8
		var bottom: float = minf(r, 0.45)
		var a: Vector3 = n.global_position + Vector3.UP * bottom
		var b: Vector3 = a + Vector3.UP * maxf((d.height if d != null else 1.6) - bottom, 0.25)
		var hit := _ray_vs_segment(ray_o, ray_d, a, b)
		if hit.y <= r and hit.x < best_t:
			best_t = hit.x
			best = n
	return best


## 可拾取对象：所有单位/建筑 + 所有可采集物
func _pickables() -> Array:
	var out: Array = []
	for n in Game.all_units():
		if n == null or not is_instance_valid(n):
			continue
		var n3 := n as Node3D
		if n3 == null:
			continue
		if n3 is RtsUnit and not (n3 as RtsUnit).is_alive():
			continue
		out.append(n3)
	var lv := Game.level as RtsLevel
	if lv != null:
		for h in lv.resource_nodes():
			if h != null and is_instance_valid(h):
				out.append(h as Node3D)
	return out


## 射线到线段的最近距离：Vector2(t 沿射线, dist 垂距)（与选择系统同一套数学）
func _ray_vs_segment(ro: Vector3, rd: Vector3, a: Vector3, b: Vector3) -> Vector2:
	var ab := b - a
	var ab_len2 := ab.length_squared()
	if ab_len2 < 0.000001:
		var t0 := (a - ro).dot(rd)
		return Vector2(maxf(t0, 0.0), ro.distance_to(a))
	var w := a - ro
	var abd := ab.dot(rd)
	var denom := ab_len2 - abd * abd
	var s: float = 0.0
	if absf(denom) > 0.000001:
		s = clampf(((w.dot(rd)) * abd - w.dot(ab)) / denom, 0.0, 1.0)
	var q: Vector3 = a + ab * s
	var t: float = (q - ro).dot(rd)
	if t <= 0.0:
		var s2 := clampf((ro - a).dot(ab) / ab_len2, 0.0, 1.0)
		return Vector2(0.0, ro.distance_to(a + ab * s2))
	var d2: float = (q - ro).length_squared() - t * t
	return Vector2(t, sqrt(maxf(d2, 0.0)))


## 屏幕点 → 地面点（带地形高度迭代）
func _ground_at(screen_pos: Vector2) -> Vector3:
	var cam := _camera()
	if cam == null:
		return Vector3.ZERO
	var ro: Vector3 = cam.project_ray_origin(screen_pos)
	var rd: Vector3 = cam.project_ray_normal(screen_pos)
	if absf(rd.y) < 0.00001:
		return ro
	var lv := Game.level as RtsLevel
	var y: float = 0.0
	var p: Vector3 = ro
	for _i in range(3):
		var t: float = (y - ro.y) / rd.y
		if t < 0.0:
			break
		p = ro + rd * t
		y = lv.height_at(p.x, p.z) if lv != null else 0.0
	return Vector3(p.x, y, p.z)


## 贴到最近可站点
func _walkable(p: Vector3) -> Vector3:
	var lv := Game.level as RtsLevel
	if lv == null:
		return p
	return lv.walkable_pos(p)


## 编队落点：以落点为中心的网格（列优先取整），并逐点夹到可走区域
func _formation_points(center: Vector3, count: int, spacing: float) -> Array:
	var out: Array = []
	if count <= 0:
		return out
	if count == 1:
		out.append(_walkable(center))
		return out
	var cols: int = int(ceil(sqrt(float(count))))
	var rows: int = int(ceil(float(count) / float(cols)))
	var start_x: float = -float(cols - 1) * 0.5 * spacing
	var start_z: float = -float(rows - 1) * 0.5 * spacing
	for i in range(count):
		var cx: int = i % cols
		var cz: int = i / cols
		var p := center + Vector3(start_x + float(cx) * spacing, 0.0, start_z + float(cz) * spacing)
		out.append(_walkable(p))
	return out


# ===========================================================================
# 工具
# ===========================================================================

func _camera() -> Camera3D:
	var vp := get_viewport()
	if vp == null:
		return null
	return vp.get_camera_3d()


func _cache_siblings() -> void:
	var parent := get_parent()
	if parent == null:
		return
	if _selection_system == null or not is_instance_valid(_selection_system):
		_selection_system = parent.get("selection_system") as Node
	if _hud == null or not is_instance_valid(_hud):
		_hud = parent.get("hud") as Node


## 当前**可下令的**选中对象。
## ★ 选中集合里现在能包含敌人/友军/中立（为了能查看信息），
##   但"下令"只能对自家单位生效 —— 这里统一过滤一次，后面所有指令都安全。
func _selected_units() -> Array:
	_cache_siblings()
	var all: Array = []
	if _selection_system != null and is_instance_valid(_selection_system) and _selection_system.has_method("selected_units"):
		all = _selection_system.call("selected_units")
	var mine: Array = []
	var pl = Game.player_faction
	for u in all:
		if u == null or not is_instance_valid(u):
			continue
		if not (u is RtsUnit):
			continue
		if pl != null and u.get("faction") != pl:
			continue
		mine.append(u)
	return mine


## 选中的农民
func _selected_workers() -> Array:
	var out: Array = []
	for u in _selected_units():
		var d := _def_of(u)
		# 用 RtsWorld 的判定：UnitDef.is_worker() 会把 gather_rate 默认值(3.0)的战斗单位
		# 也算成农民（见 关卡桥.gd is_worker_def 的说明）
		if RtsWorld.is_worker_def(d):
			out.append(u)
	return out


## 选中的第一个单位（建筑不算，用于技能判断）
func _primary_unit() -> RtsUnit:
	for u in _selected_units():
		var r := u as RtsUnit
		if r != null and not (r is RtsBuilding):
			return r
	return null


## 选中的第一个建筑
func _primary_building() -> RtsBuilding:
	for u in _selected_units():
		var b := u as RtsBuilding
		if b != null and b.is_alive():
			return b
	return null


func _def_of(n: Node) -> UnitDef:
	if n == null:
		return null
	return n.get("def") as UnitDef


## 采集：优先 unit 自己的接口
func _order_gather(w: Node, node: Node3D) -> void:
	if w == null or not is_instance_valid(w):
		return
	if w.has_method("order_gather"):
		w.order_gather(node)


## 顶部提示（走全局信号，界面负责显示）
func _toast(text: String, color: Color) -> void:
	Game.notify.emit(text, color)


## 主色（配置没起来时也有兜底色，不至于崩）
func _accent() -> Color:
	return Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)


## 警示色
func _warn() -> Color:
	return Cfg.game.enemy_color if Cfg.game != null else Color(1.0, 0.32, 0.26)


## B 键：让界面切建造菜单
func _toggle_build_menu() -> void:
	_cache_siblings()
	if _hud != null and is_instance_valid(_hud) and _hud.has_method("toggle_build_menu"):
		_hud.call("toggle_build_menu")


## 鼠标是否压在界面上（按事件坐标判：模拟输入也准；判不了再退回真实鼠标位置）
func _ui_blocks_world(p: Vector2 = Vector2(-1.0, -1.0)) -> bool:
	if p.x >= 0.0 and p.y >= 0.0:
		_cache_siblings()
		if _hud != null and is_instance_valid(_hud) and _hud.has_method("covers_point"):
			return bool(_hud.call("covers_point", p))
	var vp := get_viewport()
	if vp == null or not vp.has_method("gui_get_hovered_control"):
		return false
	return vp.call("gui_get_hovered_control") != null



## 游戏结束：清掉等待状态，别让残留的左键状态咬人
func _on_game_over(_victory: bool) -> void:
	request_cancel()
