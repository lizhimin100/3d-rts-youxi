extends Node
## **部署输入（规划阶段）** —— 进攻 / 防守 / 占据 的**二段式纯地图操作**。
##
## 玩家口径（2026-11-15）：
##   ① 底部操作面板点【进攻】【防守】【占据】→ 按钮保持按下态，鼠标指针换成对应图标；
##   ② 鼠标在地图上移动时实时预览（进攻=虚线箭头 / 防守=防区块 / 占据=据点高亮）；
##   ③ 在地图上点一下 → 部署生效，指针恢复默认、按钮弹起。
##   **没有二级面板**：所有目标都在地图上点出来。
##
## 为什么单独一个节点（不塞进指令系统）：
##   · 指令系统是"单位级右键上下文"，这里是"战役级部署意图"，两套状态机互斥但不同源；
##   · 它需要在 `_input` 阶段抢在 GUI 之前处理左键（否则点地面会被选择系统当成框选起点）。
##
## 部署只做一件事：把「进攻 / 防守 / 占据」落成 `命令记录`，执行阶段统一发出。
## （旧的「战区指令」给 AI 发意图那一套已随旧自由 AI 删除，见 Game/commands/部署类型.gd）

const DT := preload("res://Game/commands/部署类型.gd")

## 防守防区默认半径（米）。
const DEFEND_RADIUS: float = 10.0
## 占据时"吸附到据点"的距离（米）：点在据点附近就自动对准据点中心
const CAPTURE_SNAP: float = 14.0

## 模式切换（HUD 按钮按下态 / 地图预览都靠它）
signal mode_changed(mode: int)

## 当前部署模式（0 = 没有；其余见 部署类型.ATTACK/DEFEND/CAPTURE）
var _mode: int = 0
## 鼠标下的地面点（无效时 Vector3.INF）
var _ground: Vector3 = Vector3.INF
## 占据模式吸附到的据点（没有就 null）
var _snap: Node3D = null
## 本帧鼠标是否在可落点的地图区域
var _ok: bool = false

var _cmd: Node = null
var _hud: Node = null
var _cursor: Node = null
## 最近一次鼠标位置（**从事件里记**，不要每帧问 get_mouse_position）：
## 自动化/录制回放用 `push_input` 灌的是合成事件，真实 OS 指针并没有动，
## `get_mouse_position()` 会一直返回旧坐标 —— 预览就会画在错的地方（或干脆不画）。
var _mouse: Vector2 = Vector2(-1.0, -1.0)


func _ready() -> void:
	# 规划阶段整棵树 paused；部署输入必须继续收输入，否则点不动。
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "部署输入"
	if Game != null:
		Game.phase_changed.connect(_on_phase_changed)


func _exit_tree() -> void:
	cancel()


# ===========================================================================
# 对外 API（HUD 按钮 / 自检）
# ===========================================================================

## 当前模式（0 = 空闲）
func mode() -> int:
	return _mode


## 进入某个部署模式（重复点同一个 = 取消，红警3 的按钮手感）
func enter(kind: int) -> void:
	if not DT.NAMES.has(kind):
		return
	if _mode == kind:
		cancel()
		return
	# 和"建造/技能/攻击移动落点"互斥：两边都吃左键，同时开着必然打架
	var cmd := _command_system()
	if cmd != null and cmd.has_method("request_cancel"):
		cmd.call("request_cancel")
	_mode = kind
	_apply_cursor()
	mode_changed.emit(_mode)
	Game.toast(_enter_hint(), Color(0.98, 0.84, 0.52))


## 退出部署模式（指针/按下态一起复位）
func cancel() -> void:
	if _mode == 0:
		return
	_mode = 0
	_ground = Vector3.INF
	_snap = null
	_ok = false
	_apply_cursor()
	mode_changed.emit(0)


## 地图预览（规划地图层每帧读它画虚线箭头/防区块/据点高亮）
## 返回：{mode, from, to, radius, ok, snap}
func preview() -> Dictionary:
	if _mode == 0:
		return {}
	var from: Vector3 = _squad_center()
	return {
		"mode": _mode,
		"from": from,
		"to": _ground,
		"radius": DEFEND_RADIUS if _mode == DT.DEFEND else 0.0,
		"ok": _ok,
		"snap": _snap,
	}


# ===========================================================================
# 每帧：算落点 + 状态自愈
# ===========================================================================

func _process(_delta: float) -> void:
	if _mode == 0:
		return
	# 阶段不对（切到执行/对局结束/长局）→ 立刻收摊，绝不留下一个"点哪都不生效"的指针
	if not _can_deploy():
		cancel()
		return
	# 指令系统进入了建造/技能落点 → 部署让位（它先点了按钮）
	var cmd := _command_system()
	if cmd != null and cmd.has_method("has_pending") and bool(cmd.call("has_pending")):
		cancel()
		return
	_poll_ground()


## 只有在"短局 + 规划阶段 + 对局没结束"时才能部署
func _can_deploy() -> bool:
	if Game == null or Game.player_faction == null:
		return false
	if Game.has_method("is_over") and bool(Game.call("is_over")):
		return false
	if not Game.short_match:
		return false
	return Game.is_planning()


func _poll_ground() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var pos: Vector2 = _mouse
	if pos.x < 0.0 or pos.y < 0.0:
		pos = vp.get_mouse_position()
	_ok = false
	_ground = Vector3.INF
	_snap = null
	if _ui_blocks(pos):
		return
	var g: Vector3 = _ground_at(pos)
	if g == Vector3.INF:
		return
	_ground = g
	_ok = true
	if _mode == DT.CAPTURE:
		# 占据：鼠标靠近中立据点就吸附（据点本体只有 8m，点边上也算点它）
		var sp: Node = Game.strongpoint
		if sp != null and is_instance_valid(sp) and sp.has_method("crate_pos"):
			var cp: Vector3 = sp.call("crate_pos")
			if Vector2(cp.x - g.x, cp.z - g.z).length() <= CAPTURE_SNAP:
				_snap = sp
				_ground = cp


# ===========================================================================
# 输入
# ===========================================================================

func _input(event: InputEvent) -> void:
	if _mode == 0:
		return
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			cancel()
			get_viewport().set_input_as_handled()
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		cancel()
		get_viewport().set_input_as_handled()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	# ★ `_input` 早于 GUI：不挡的话，点面板/按钮会被当成"对那片地面下令"
	if _ui_blocks(mb.position):
		return
	_commit(mb.position)
	get_viewport().set_input_as_handled()


func _commit(screen_pos: Vector2) -> void:
	var kind: int = _mode
	var cmd := _command_system()
	if cmd == null:
		cancel()
		return
	var g: Vector3 = _ground_at(screen_pos)
	if g == Vector3.INF:
		cancel()
		return
	# 占据：靠近据点就对准据点
	var target_pos: Vector3 = g
	if kind == DT.CAPTURE:
		var sp: Node = Game.strongpoint
		if sp != null and is_instance_valid(sp) and sp.has_method("crate_pos"):
			var cp: Vector3 = sp.call("crate_pos")
			if Vector2(cp.x - g.x, cp.z - g.z).length() <= CAPTURE_SNAP:
				target_pos = cp
	var before: int = int(cmd.call("planned_count")) \
			if cmd.has_method("planned_count") else 0
	var done: bool = false
	match kind:
		DT.ATTACK:
			cmd.call("queue_attack_move", target_pos)
			done = int(cmd.call("planned_count")) > before
			if done:
				# 只报"派了多少人"，不写坐标：规划阶段屏上不出现数字坐标（玩家口径：
				# 图上没写的东西不要加，坐标对玩家也没意义）。
				Game.toast("进攻部署：%d 个单位" % _plan_unit_count(cmd),
						Color(0.98, 0.72, 0.45))
		DT.DEFEND:
			done = bool(cmd.call("queue_defend", target_pos, DEFEND_RADIUS))
			if done:
				Game.toast("防守部署：%.0fm 防区" % DEFEND_RADIUS, Color(0.62, 0.82, 1.0))
		DT.CAPTURE:
			done = bool(cmd.call("queue_capture", target_pos))
			if done:
				Game.toast("占据部署：%s" % ("据点" if target_pos != g else "区域"),
						Color(0.98, 0.86, 0.46))
	# 部署生效：指针恢复默认、按钮弹起（无论成功与否都收，避免"卡在等待态"）
	cancel()


# ===========================================================================
# 工具
# ===========================================================================

## 选中单位（或它所属小队）的队心 —— 虚线箭头的起点
func _squad_center() -> Vector3:
	var sel := _selection_system()
	if sel == null or not sel.has_method("selected_units"):
		return Vector3.ZERO
	var arr: Array = sel.call("selected_units")
	var sum := Vector3.ZERO
	var n: int = 0
	for u in arr:
		if u == null or not is_instance_valid(u) or not (u is Node3D):
			continue
		if u.has_method("is_alive") and not bool(u.call("is_alive")):
			continue
		sum += (u as Node3D).global_position
		n += 1
	if n == 0:
		return Vector3.ZERO
	return Vector3(sum.x / float(n), 0.0, sum.z / float(n))


func _plan_unit_count(cmd: Node) -> int:
	if cmd == null or not cmd.has_method("planned_records"):
		return 0
	var recs: Array = cmd.call("planned_records")
	if recs.is_empty():
		return 0
	return int((recs[recs.size() - 1] as Dictionary).get("units", 0))


func _enter_hint() -> String:
	match _mode:
		DT.ATTACK:
			return "部署 · 进攻：在地图上点目标方向（虚线箭头跟随鼠标，右键取消）"
		DT.DEFEND:
			return "部署 · 防守：在地图上点防区中心（蓝色区域预览，右键取消）"
		DT.CAPTURE:
			return "部署 · 占据：点据点或一片区域（金圈高亮，右键取消）"
	return ""


## 换鼠标指针：三种部署各一套（图标由 光标术 代码生成，不加载外部素材）
func _apply_cursor() -> void:
	var cur := _cursor_node()
	if cur == null or not cur.has_method("set_override"):
		return
	var shape: int = -1
	match _mode:
		DT.ATTACK:
			shape = 6   # RtsGlyphCursor.Shape.ATTACK
		DT.DEFEND:
			shape = 7   # DEFEND
		DT.CAPTURE:
			shape = 8   # CAPTURE
	cur.call("set_override", shape)


func _cursor_node() -> Node:
	if _cursor != null and is_instance_valid(_cursor):
		return _cursor
	var tree := get_tree()
	if tree == null:
		return null
	_cursor = tree.get_first_node_in_group("glyph_cursor")
	return _cursor


func _command_system() -> Node:
	if _cmd != null and is_instance_valid(_cmd):
		return _cmd
	var p := get_parent()
	if p == null:
		return null
	_cmd = p.get_node_or_null("指令系统")
	return _cmd


func _selection_system() -> Node:
	var p := get_parent()
	if p == null:
		return null
	return p.get_node_or_null("选择系统")


func _hud_node() -> Node:
	if _hud != null and is_instance_valid(_hud):
		return _hud
	var p := get_parent()
	if p == null:
		return null
	_hud = p.get_node_or_null("界面")
	return _hud


## HUD 盖住了这个屏幕点吗
func _ui_blocks(pos: Vector2) -> bool:
	var hud := _hud_node()
	if hud == null:
		return false
	if hud.has_method("covers_point"):
		return bool(hud.call("covers_point", pos))
	return false


## 屏幕点 → 地面点（先与 y=0 求交，再按地形高度迭代两次）
func _ground_at(screen: Vector2) -> Vector3:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.INF
	var from: Vector3 = cam.project_ray_origin(screen)
	var dir: Vector3 = cam.project_ray_normal(screen)
	if absf(dir.y) < 1e-5:
		return Vector3.INF
	var t: float = -from.y / dir.y
	if t <= 0.0:
		return Vector3.INF
	var p: Vector3 = from + dir * t
	for _i in 2:
		var h: float = RtsWorld.height_at(p.x, p.z)
		var t2: float = (h - from.y) / dir.y
		if t2 <= 0.0:
			break
		p = from + dir * t2
	p.y = RtsWorld.height_at(p.x, p.z)
	return p


func _on_phase_changed(_old: int, new_phase: int) -> void:
	if new_phase != RtsConst.Phase.PLANNING:
		cancel()
