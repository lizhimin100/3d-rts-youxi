extends Node
## **战区指令输入** —— 四种战役级指令（进攻 / 防守 / 占据 / 生产）的鼠标入口。
##
## 交互（2026-11-13 玩家口径，对齐红警3）：
##   · 点 HUD 上小地图旁的按钮（或 F5–F8）→ 进入该指令的待发状态，按钮常亮；
##   · 然后在战场上**点一下**：
##       - 点到单位/建筑 → 对**那个目标**下指令（区域半径 = 目标判定圈 + 2m）；
##       - 点到空地     → 对这**片区域**下指令（半径 6m）；
##   · 右键 / ESC / 再点一次同一个按钮 = 取消。
##   **不再用拖拽画圈** —— 玩家明确要求"和点击目标一样，点了没目标就对该片区域下令"。
##
## 为什么还要留 F5–F8：按钮是给鼠标用的，快捷键是给熟手用的，两条路写同一份状态。
##
## 反馈：按钮按下态由 HUD 轮询 `pending_kind()`；顶部播报走 `Game.toast`（不抢据点条）。

const WAR := preload("res://Game/ai/战区指令.gd")

## 功能键 → 指令种类
const KEYS: Dictionary = {
	KEY_F5: WAR.ATTACK,
	KEY_F6: WAR.DEFEND,
	KEY_F7: WAR.CAPTURE,
	KEY_F8: WAR.PRODUCE,
}
## 点空地时的默认半径（米）
const TAP_RADIUS: float = 6.0
## 点到目标时，区域半径 = 目标判定圈 + 这个余量（把目标整个圈住）
const TARGET_PAD: float = 2.0

## 模式切换信号（HUD 靠它即时刷新按下态；也可以轮询 pending_kind）
signal mode_changed(kind: int)

var _pending: int = 0


func _ready() -> void:
	# 规划阶段世界暂停，战区指令仍然是要能下的"意图"。
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[战区] 指令输入就绪：按钮 / F5 进攻 · F6 防守 · F7 占据 · F8 生产；点目标或点区域，右键取消")


# ---------------------------------------------------------------------------
# 对外 API（HUD 按钮、自检都走这里，不要直接调 _enter/_cancel）
# ---------------------------------------------------------------------------

## 当前待发指令（0 = 没有）
func pending_kind() -> int:
	return _pending


## 进入某条指令的待发状态（重复点同一条 = 取消，红警3 的按钮就是这个手感）
func enter_mode(kind: int) -> void:
	if not WAR.NAMES.has(kind):
		return
	if _pending == kind:
		cancel_mode()
		return
	# 和"建造/技能落点"互斥：两边都吃左键，同时开着必然打架
	var cmd := get_parent().get_node_or_null("指令系统") if get_parent() != null else null
	if cmd != null and cmd.has_method("request_cancel"):
		cmd.call("request_cancel")
	_pending = kind
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)
	mode_changed.emit(_pending)
	Game.toast("战区指令：%s —— 点目标或点一片区域（右键取消）" % String(WAR.NAMES[kind]),
		Color(0.98, 0.84, 0.52))


func cancel_mode() -> void:
	if _pending == 0:
		return
	_pending = 0
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	mode_changed.emit(0)


# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if Game == null or Game.player_faction == null:
		return
	if Game.has_method("is_over") and bool(Game.call("is_over")):
		cancel_mode()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.keycode
		if KEYS.has(k):
			enter_mode(int(KEYS[k]))
			get_viewport().set_input_as_handled()
			return
		if k == KEY_ESCAPE and _pending != 0:
			cancel_mode()
			get_viewport().set_input_as_handled()
			return

	if _pending == 0:
		return

	# 右键 / ESC 之外，再给一个"右键取消"（红警手感）
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			cancel_mode()
			get_viewport().set_input_as_handled()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		# ★ `_input` 早于 GUI：不挡住的话，点小Content/maps/按钮/面板都会被当成"对那片地面下令"
		if _ui_blocks(mb.position):
			return
		if mb.pressed:
			# 只认"按下"：点一下就下单，没有拖拽阶段
			_commit(mb.position)
			get_viewport().set_input_as_handled()


## HUD 盖住了这个屏幕点吗（HUD 有 covers_point；没有就退回 false）
func _ui_blocks(pos: Vector2) -> bool:
	var hud := get_parent().get_node_or_null("界面") if get_parent() != null else null
	if hud == null:
		return false
	if hud.has_method("covers_point"):
		return bool(hud.call("covers_point", pos))
	return false


func _commit(screen_pos: Vector2) -> void:
	var kind: int = _pending
	var ground: Vector3 = _ground_point(screen_pos)
	if ground == Vector3.INF:
		cancel_mode()
		return
	# --- 1. 先找目标：点到了单位/建筑就围着它下指令 ---
	var target: Node3D = _pick_target(screen_pos)
	if target != null:
		var d: UnitDef = target.get("def") as UnitDef
		var r: float = TAP_RADIUS
		if d != null:
			r = clampf(maxf(d.judge_radius, d.body_radius) + TARGET_PAD, 4.0, 40.0)
		WAR.issue(kind, target.global_position, r, target, "玩家")
		Game.toast("战区指令：%s → %s" % [String(WAR.NAMES[kind]),
			d.display_name if d != null else String(target.name)], Color(0.98, 0.84, 0.52))
		cancel_mode()
		return
	# --- 2. 空地 = 对这片区域下令（半径固定 6m，不再拖拽） ---
	var radius: float = TAP_RADIUS
	# 「生产」是"新兵往哪集结"，区域大小没意义
	if kind == WAR.PRODUCE:
		radius = TAP_RADIUS
	WAR.issue(kind, ground, radius, null, "玩家")
	Game.toast("战区指令：%s → (%.0f, %.0f) 半径 %.0fm" % [
		String(WAR.NAMES[kind]), ground.x, ground.z, radius], Color(0.98, 0.84, 0.52))
	cancel_mode()


## 屏幕点 → 目标（单位/建筑/资源）。只认"活着的、可被右键的"对象。
## 用一次性射线 + 球体近似，和 选择系统/指令系统 同一套判据（那两个是私有函数，这里自带一份）。
func _pick_target(screen: Vector2) -> Node3D:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from: Vector3 = cam.project_ray_origin(screen)
	var dir: Vector3 = cam.project_ray_normal(screen)
	var best: Node3D = null
	var best_t: float = 1e20
	var world: Node = get_parent().get_node_or_null("关卡")
	var level: Node = world if world != null else Game.get("level")
	var list: Array = _all_units(level)
	for n in list:
		var u := n as Node3D
		if u == null or not is_instance_valid(u):
			continue
		var d: UnitDef = u.get("def") as UnitDef
		if d == null:
			continue
		if u.has_method("is_alive") and not bool(u.call("is_alive")):
			continue
		# 球体近似：中心抬到身高的 45%（脚底原点，抬低了贴地打不中）
		var c: Vector3 = u.global_position + Vector3(0.0, maxf(d.height, 0.6) * 0.45, 0.0)
		var radius: float = maxf(d.selection_radius, d.body_radius) * 1.15 + 0.25
		var oc: Vector3 = c - from
		var t: float = oc.dot(dir)
		if t <= 0.0 or t >= best_t:
			continue
		var closest: Vector3 = from + dir * t
		if closest.distance_to(c) <= radius:
			best = u
			best_t = t
	return best


## 场景里所有有 def 的单位/建筑（走 Game 的阵营表，不扫节点树）
func _all_units(level: Node) -> Array:
	var out: Array = []
	if Game == null:
		return out
	for f in Game.factions:
		if f == null:
			continue
		out.append_array(f.units)
		out.append_array(f.buildings)
	return out


## 屏幕点 → 地面点（吃地形高度：先与 y=0 求交，再按地形高度迭代两次）。
func _ground_point(screen: Vector2) -> Vector3:
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
