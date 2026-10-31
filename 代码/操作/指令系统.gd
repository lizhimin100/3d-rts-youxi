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
## 资源扣费纪律：
##   · 训练：本系统在指令下达那一刻扣（request_train）。
##   · 建造：本系统**只校验、不扣钱**；钱由 RtsUnit.order_build 在工地成立那一刻扣一次。
##     （以前这里也 Game.pay 一次、order_build 再扣一次，造 80 金的农场实扣 160 —— 已修。）
## 失败一律给中文提示，绝不让玩家白点。

## 等待落点的状态
enum Pending {
	NONE = 0,
	ATTACK_MOVE = 1,
	BUILD = 2,
	CAST = 3,
	RALLY = 4,
	MOVE = 5,
}

## 编队间距（米）
const FORMATION_SPACING := 1.9
## 训练队列上限
const TRAIN_QUEUE_MAX := 5

## 当前等待状态
var pending: int = Pending.NONE
## 等待建造的建筑 id
var pending_build: StringName = &""
## 等待建造的朝向：**不允许玩家自转**，全项目统一读 建筑网格.DEFAULT_YAW。
## （默认 ±180°：模型正门在 -Z，镜头从南往北看；0° 会让玩家一直看建筑背面。）
## 用户要求"别管是地图生成还是农民建造，都默认一个角度"，所以 R 键旋转已停用。
var pending_yaw: float = 建筑网格.DEFAULT_YAW
## 等待施法的技能 id
var pending_ability: StringName = &""
## 等待设置集结点的建筑（null = 用当前选中的建筑）
var _rally_building: Node = null

## 建造预览（半透明盒子）
var _ghost: MeshInstance3D = null
var _ghost_mat: StandardMaterial3D = null
## 占格预览（建筑网格.make_grid_preview；落点或合法性变了才重建）
var _grid_preview: MeshInstance3D = null
var _grid_key: String = ""

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
			return "左键选择建造位置：%s（R 转向 %d° / 右键取消）" % [
				d.display_name if d != null else String(pending_build),
				int(round(rad_to_deg(pending_yaw)))]
		Pending.CAST:
			return "左键选择技能目标点（右键取消）"
		Pending.RALLY:
			var rb := _rally_target(_rally_building)
			return "左键选择集结点：%s（右键取消）" % (rb.def.display_name if rb != null and rb.def != null else "建筑")
		Pending.MOVE:
			return "左键选择部署点（右键取消）"
		_:
			return ""


## 取消当前等待状态
func request_cancel() -> void:
	pending = Pending.NONE
	pending_build = &""
	pending_ability = &""
	pending_yaw = 建筑网格.default_yaw()
	_rally_building = null
	_patrol_next = false
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


## 研究一项铁匠铺升级（命令卡调用）：花费/上限全部读 Cfg 的研究定义。
func request_research(research_id: StringName) -> void:
	var b := _primary_building()
	if b == null:
		return
	var rd: ResearchDef = Cfg.research(research_id)
	if rd == null:
		return
	if b.def == null or not b.def.researches.has(research_id):
		_toast("这里不能研究 %s" % rd.display_name, _warn())
		return
	var reason: String = String(b.research_block_reason(research_id))
	if reason != "":
		_toast(reason, _warn())
		return
	if b.research(research_id):
		_toast("开始研究：%s（%.0f 秒）" % [rd.display_name, rd.research_time], _accent())
	else:
		_toast("研究失败：%s" % rd.display_name, _warn())


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
	pending_yaw = 建筑网格.snap_yaw(pending_yaw)
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


## 自由部署：进入"点地面移动"的等待状态（参照图里的"自由部署"）
func request_move() -> void:
	if _selected_units().is_empty():
		return
	pending = Pending.MOVE
	_toast("自由部署：左键选择落点（右键取消）", _accent())


## 全部原地警戒
func request_hold() -> void:
	_issue_simple(RtsConst.Order.HOLD, "原地警戒")


## 全部原地**观察**（逻辑同驻守，头顶图标不同 —— 见 RtsUnit.Guard）
func request_observe() -> void:
	var units := _selected_units()
	if units.is_empty():
		return
	for u in units:
		if u.has_method("order_observe"):
			u.call("order_observe")
	Game.order_issued.emit(units, RtsConst.Order.HOLD, Vector3.ZERO, null)
	_toast("原地观察", _accent())


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
		elif k.keycode == KEY_R and pending == Pending.BUILD:
			# 朝向统一之后不再允许旋转：提示一句，别让玩家以为按坏了
			_toast("建筑朝向统一朝南，不支持旋转", _accent())
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
		Pending.RALLY:
			_place_rally(ground)
		Pending.CAST:
			var ab := pending_ability
			pending = Pending.NONE
			pending_ability = &""
			_cast_at(ab, ground, screen_pos)
		Pending.MOVE:
			pending = Pending.NONE
			_issue_move(_selected_units(), ground)
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
	# --- 0. **只选中己方建筑 → 右键直接设集结点** ---
	# RTS 的通用手势：选中兵营右击地面 = "出来的兵去那儿"。
	# 以前必须点「设置集结点」按钮再左键落点，纯属多一步。
	var only_b: RtsBuilding = null
	var has_mobile: bool = false
	for u0 in units:
		if u0 is RtsBuilding:
			var b0 := u0 as RtsBuilding
			if b0.is_alive() and only_b == null:
				only_b = b0
		elif u0 is RtsUnit and (u0 as RtsUnit).is_mobile():
			has_mobile = true
	if only_b != null and not has_mobile and only_b.has_method("set_rally"):
		var g0 := _ground_at(screen_pos)
		if g0 != Vector3.INF:
			only_b.set_rally(_walkable(g0))
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

	# --- 3. 点到自己建筑：只在"真的点在建筑上"时才当交互 ---
	#
	# 2026-10-18 修：以前这里无条件把"己方建筑"当成送回资源的目标。
	# 城镇大厅又高又宽，从俯视角点它**背后**的金矿时，射线先打中大厅的胶囊体，
	# 于是农民被派去大厅（虚线落在大厅内部、人贴墙站住），玩家以为"目的地设成了建筑内部"。
	# 现在的要求：① 射线**命中的就是建筑**（不是背后）；② 建筑在屏幕上的投影离鼠标很近；
	# ③ 选中的是农民。三条都满足才送回资源，否则一律落回"点地移动"。
	if target is RtsBuilding and target.get("faction") == pl:
		var b := target as RtsBuilding
		var workers := _selected_workers()
		var on_building: bool = _cursor_on_building(b, screen_pos)
		if _primary_unit() == null and on_building:
			b.set_rally(_walkable(ground))
			_toast("%s 集结点已设置" % (b.def.display_name if b.def != null else "建筑"), _accent())
			return
		if not workers.is_empty() and on_building:
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

## 放置建筑（命令卡/快捷键 B → 左键落点走这里）：只负责"取选中的农民 + 收尾"
func _place_building(ground: Vector3) -> void:
	var id := pending_build
	var workers := _selected_workers()
	if id == &"" or workers.is_empty():
		request_cancel()
		return
	var site := place_building(id, ground, workers, pending_yaw)
	if site != null:
		pending = Pending.NONE
		pending_build = &""
		_free_ghost()


## **建造主入口**（界面 / 快捷键 / 自检统一调它）。成功返回工地节点，失败 null。
##
## 三条纪律（都是踩过的坑）：
##   1. **本函数不扣钱**：扣费只在 RtsUnit.order_build 里发生一次。
##      以前这里先 Game.pay、order_build 又 pay，造 80 金的农场实扣 160。
##   2. **同一处已有同类未完工工地 → 不新建、不扣费**，把农民挂到那栋工地上。
##      （以前第 2/3 个农民被 is_buildable 静默拦下，不干活也不提示。）
##   3. 落点先吸到严格网格锚点，再过 _can_place；不合法就红着拒绝，绝不悄悄滑走。
func place_building(building_id: StringName, ground: Vector3, workers: Array = [],
		desired_yaw: float = 0.0) -> Node3D:
	var d: UnitDef = Cfg.unit(building_id)
	if d == null:
		return null
	if workers.is_empty():
		_toast("需要农民才能建造", _warn())
		return null

	# --- 1. 这里是否已经有一栋同类工地？有就"加入"，不重复建也不重复扣钱 ---
	var existing := _find_pending_site(building_id, ground, d.footprint)
	if existing != null:
		var joined: int = 0
		for w in workers:
			if _attach_worker(w, existing):
				joined += 1
		if joined > 0:
			Game.notify.emit("已有 %s 在施工，%d 个农民加入" % [d.display_name, joined], _accent())
			Game.order_issued.emit(workers, RtsConst.Order.BUILD, existing.global_position, existing)
		else:
			_toast("这栋 %s 已经在施工了" % d.display_name, _warn())
		return existing

	# --- 2. 吸附 + 校验（越界 / 压建筑 / 压水 / 压资源点都会被拒）---
	var pos := _snap_build_pos(ground, d.footprint)
	if not _can_place(pos, d):
		_toast("这里不能建造（越界 / 挡住已有建筑 / 水面 / 地形不可建）", _warn())
		return null
	if not Game.can_afford(Game.player_faction, building_id):
		_toast("资源不足：%s" % d.display_name, _warn())
		return null

	# --- 3. 第一个农民真的立工地（它负责扣那一次钱）---
	var first: Node = null
	for w in workers:
		if w != null and is_instance_valid(w) and w.has_method("order_build"):
			first = w
			break
	if first == null:
		_toast("需要农民才能建造", _warn())
		return null
	first.call("order_build", d, pos, 建筑网格.snap_yaw(desired_yaw))
	var site: Node3D = first.get("_build_site") as Node3D
	if site == null or not is_instance_valid(site) or not site.is_alive():
		return null   # order_build 自己失败了，它已经给过提示

	# --- 4. 其余农民挂到同一块工地（不新建、不扣费）---
	for w in workers:
		if w == first:
			continue
		_attach_worker(w, site)

	Game.order_issued.emit(workers, RtsConst.Order.BUILD, pos, site)
	_toast("建造 %s" % d.display_name, _accent())
	return site


## 把一个农民挂到已有工地：优先 order_build_site（只接活、不扣钱）；
## 旧版单位脚本没有这个接口时退化成"对着同一坐标 order_build"。
func _attach_worker(w: Node, site: Node3D) -> bool:
	if w == null or not is_instance_valid(w) or site == null or not is_instance_valid(site):
		return false
	if w.has_method("order_build_site"):
		return bool(w.call("order_build_site", site))
	if w.has_method("order_build"):
		var sd: Variant = site.get("def")
		if sd != null:
			w.call("order_build", sd, site.global_position)
			return true
	return false


## 这个落点附近是否已经有一栋"同类 + 未完工"的工地
func _find_pending_site(building_id: StringName, ground: Vector3, footprint: Vector2i) -> Node3D:
	var reach: float = maxf(float(maxi(footprint.x, footprint.y)), 2.0) * 0.85
	var best: Node3D = null
	var best_d: float = INF
	for n in Game.all_units():
		if n == null or not is_instance_valid(n) or not (n is RtsBuilding):
			continue
		var b := n as RtsBuilding
		if b.def == null or b.def.id != building_id:
			continue
		if b.is_constructed or not b.is_alive():
			continue
		var dx: float = b.global_position.x - ground.x
		var dz: float = b.global_position.z - ground.z
		var dist: float = sqrt(dx * dx + dz * dz)
		if dist <= reach and dist < best_d:
			best_d = dist
			best = b
	return best


## 能不能放：逐格的通行判定走 `建筑网格.can_place`（和寻路共用同一套格，
## 水面/岩石/已占格都不可走，关卡还在的话顺带查地形高度极差），
## 这里只额外兜一层"不与已有建筑（含工地）的占地重叠"。
func _can_place(pos: Vector3, d: UnitDef) -> bool:
	var lv := Game.level as RtsLevel
	if lv == null or d == null or lv.grid_pathfinder() == null:
		return false
	var fp: Vector2i = Vector2i(maxi(d.footprint.x, 1), maxi(d.footprint.y, 1))
	if not 建筑网格.can_place(pos, fp):
		return false
	# 再兜一层：不与已有建筑（含工地）的占地重叠
	var half := Vector2(fp) * 0.5
	for b in Game.all_units():
		if b == null or not is_instance_valid(b) or not (b is RtsBuilding):
			continue
		var other := b as RtsBuilding
		if not other.is_alive():
			continue
		var off: Vector3 = other.global_position - pos
		var bg := Vector2(off.x, off.z)
		var bh: Vector2 = Vector2(other.def.footprint) * 0.5 if other.def != null else Vector2.ONE
		if absf(bg.x) < (half.x + bh.x) and absf(bg.y) < (half.y + bh.y):
			return false
	return true


## 落点 → **严格网格锚点**：唯一入口是 `建筑网格.snap_point`，规则写在那里
## （奇数边长吸格心、偶数边长吸格线，2×2 正好盖满 4 格）。
## 这里保留函数名只因为界面 / 建造自检已经从它调起。
## ★ 仍然**不做 clamp_to_walkable**：玩家点水里，房子不会偷偷跑到岸上，宁可拒绝。
func _snap_build_pos(pos: Vector3, footprint: Vector2i) -> Vector3:
	return 建筑网格.snap_point(pos, footprint)


## 对外（界面预览 / 自检）：把落点吸到严格网格锚点。
func snap_build_pos(ground: Vector3, footprint: Vector2i) -> Vector3:
	return _snap_build_pos(ground, footprint)


## 对外（界面 / 自检）：建筑朝向吸附到 90° 档
func snap_yaw(yaw: float) -> float:
	return 建筑网格.snap_yaw(yaw)


# ===========================================================================
# 集结点（三接口：request_set_rally / is_rally_pending / cancel_rally）
# ===========================================================================

## 进入"设集结点"状态。building 为空时用当前选中的建筑。
## 成功进入返回 true；没有可设的建筑时给一句提示并返回 false。
func request_set_rally(building: Node = null) -> bool:
	var b := _rally_target(building)
	if b == null:
		_toast("先选中一座己方建筑才能设集结点", _warn())
		return false
	_rally_building = b
	pending = Pending.RALLY
	pending_build = &""
	pending_ability = &""
	_patrol_next = false
	_free_ghost()
	return true


## 是否正在等玩家点集结点落点（界面据此让出左键；自检据此断言）
func is_rally_pending() -> bool:
	return pending == Pending.RALLY


## 取消集结点：① 退出"等落点"；② 把该建筑的集结点拔掉（地面小旗跟着消失）。
## 返回是否真的取消了什么（既没在等、也没旗子时返回 false）。
func cancel_rally() -> bool:
	var did: bool = false
	var b := _rally_target(_rally_building)
	if pending == Pending.RALLY:
		pending = Pending.NONE
		did = true
	if b != null and b.has_rally and b.has_method("clear_rally"):
		b.clear_rally()
		did = true
	_rally_building = null
	return did


## 集结点落点：贴到最近可走格（集结点不必压格子中心，能被走到就行）
func _place_rally(ground: Vector3) -> void:
	# 注意：这里**不清 _rally_building**。它是"上一次设过集结点的建筑"，
	# cancel_rally() 要靠它把旗子拔掉；清掉的话，玩家设法设完再点取消就会静默失败
	# （实测：建造自检里 cancel_rally 返回 false、旗子还在）。
	var b := _rally_target(_rally_building)
	pending = Pending.NONE
	if b == null:
		return
	b.set_rally(_walkable(ground))
	_toast("%s 集结点已设置" % (b.def.display_name if b.def != null else "建筑"), _accent())


## 解析"要给哪栋建筑设集结点"：显式传入 > 待设置的 > 当前选中的
func _rally_target(building: Node = null) -> RtsBuilding:
	if building != null and is_instance_valid(building) and building is RtsBuilding:
		var rb := building as RtsBuilding
		if rb.is_alive():
			return rb
	return _primary_building()


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


## 预览跟随鼠标，颜色表示能否放；同时把**占用的那几格**画在地上（绿/红）
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
	_ghost.rotation.y = pending_yaw
	_refresh_grid_preview(pos, d.footprint, ok)


## 占格预览：只在落点或合法性变化时重建（每帧重建 SurfaceTool 是白烧 CPU）
func _refresh_grid_preview(pos: Vector3, footprint: Vector2i, ok: bool) -> void:
	var key: String = "%d,%d,%d,%d,%s" % [
		roundi(pos.x * 100.0), roundi(pos.z * 100.0), footprint.x, footprint.y, str(ok)]
	if key == _grid_key and _grid_preview != null and is_instance_valid(_grid_preview):
		return
	_free_grid_preview()
	_grid_key = key
	_grid_preview = 建筑网格.make_grid_preview(pos, footprint, ok)
	add_child(_grid_preview)


func _free_grid_preview() -> void:
	if _grid_preview != null and is_instance_valid(_grid_preview):
		_grid_preview.queue_free()
	_grid_preview = null
	_grid_key = ""


func _free_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	_ghost_mat = null
	_free_grid_preview()


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


## 鼠标是否**真的**压在建筑上（而不是点在它背后的东西）。
##
## 判据用屏幕空间：把建筑占地矩形的四个角投到屏幕上，取包围盒；
## 鼠标必须落在包围盒内（留 6px 容差）。俯视角下建筑会"遮住"背后 10~20m 的地面，
## 只靠射线命中会把"背后的金矿"判成"建筑"——这就是玩家反馈的那个 bug。
func _cursor_on_building(b: RtsBuilding, screen_pos: Vector2) -> bool:
	var cam := _camera()
	if cam == null or b == null or b.def == null:
		return false
	var d: UnitDef = b.def
	# footprint 的单位是寻路格（1m/格，见 地图生成 里 walkable 的 size×size）
	var half := Vector2(float(d.footprint.x), float(d.footprint.y)) * 0.5
	if half.x <= 0.0 or half.y <= 0.0:
		half = Vector2(2.0, 2.0)
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var w: Vector3 = b.global_position + Vector3(half.x * sx, 0.0, half.y * sz)
			var s: Vector2 = cam.unproject_position(w)
			mn = Vector2(minf(mn.x, s.x), minf(mn.y, s.y))
			mx = Vector2(maxf(mx.x, s.x), maxf(mx.y, s.y))
	return screen_pos.x >= mn.x - 6.0 and screen_pos.x <= mx.x + 6.0 \
		and screen_pos.y >= mn.y - 6.0 and screen_pos.y <= mx.y + 6.0


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
		if not n3.visible:
			continue    # 迷雾里的敌人：看不见就不能右键下令
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


## 贴到最近可站点：**带 body 净空**（0.5m），且返回连续坐标而不是格心。
##
## 老实现走 lv.walkable_pos() → 最近可走格**中心**：点到建筑边/拐角时，
## 相邻的编队格会被夹到同一格中心，一队人抢同一个点，然后靠 separation 互推。
func _walkable(p: Vector3) -> Vector3:
	var lv := Game.level as RtsLevel
	if lv == null:
		return p
	var pf: GridPathfinder = lv.grid_pathfinder()
	if pf != null and pf.has_method("nearest_standable"):
		return lv.snap_to_ground(pf.nearest_standable(p, 0.5))
	return lv.walkable_pos(p)


## 编队落点：中心网格 → 每格解析成**唯一、可站立、互相错开**的落点（确定性）。
##
## 为什么必须错开：老实现直接 _walkable() 到“最近可走格中心”，点到建筑边/拐角时
## 相邻编队格会被夹到同一格 → 多个单位抢同一个点 → separation 互推 → 到了又挤开，
## 玩家看到的就是“原地抽搐”。这里给每个点加一道最小间距闸，冲突就沿外法线让位。
const FORMATION_MIN_GAP := 1.25

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
	var used: Array = []
	for i in range(count):
		var cx: int = i % cols
		var cz: int = i / cols
		var slot := center + Vector3(start_x + float(cx) * spacing, 0.0, start_z + float(cz) * spacing)
		var p: Vector3 = _resolve_slot(slot, center, used)
		out.append(p)
		used.append(p)
	return out


## 把一格编队位解析成“可站立 + 不和已分配点抢位”的落点。
## 冲突时沿“编队中心 → 该点”的外法线让 0.75~2.25m（后 3 次改切向），
## 全程纯函数：同样的选中/落点 → 同样的分配，不会逐帧跳。
func _resolve_slot(slot: Vector3, center: Vector3, used: Array) -> Vector3:
	var p: Vector3 = _walkable(slot)
	for attempt in range(6):
		if not _too_close(p, used):
			return p
		var dir: Vector3 = p - center
		dir.y = 0.0
		if dir.length_squared() < 0.01:
			dir = Vector3(1.0, 0.0, 0.0)
		dir = dir.normalized()
		if attempt >= 3:
			dir = Vector3(-dir.z, 0.0, dir.x)
		p = _walkable(p + dir * (FORMATION_MIN_GAP * (0.6 + 0.2 * float(attempt))))
	return p


## 这个落点离已分配的点是不是太近（< FORMATION_MIN_GAP）
func _too_close(p: Vector3, used: Array) -> bool:
	for u in used:
		var q: Vector3 = u
		var dx: float = p.x - q.x
		var dz: float = p.z - q.z
		if dx * dx + dz * dz < FORMATION_MIN_GAP * FORMATION_MIN_GAP:
			return true
	return false


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