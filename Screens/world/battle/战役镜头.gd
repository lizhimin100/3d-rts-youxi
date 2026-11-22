extends Node3D
## 职责：三阶段动态相机（规划锁玩家区 / 进攻锁中立+敌方 / 防守锁中立+玩家）。
## 属于：Screens/world/battle（表现层）
##
## 口径（2026-11-22）：
##   · **构图靠"框矩形"算距离，不靠调参**：给定地面矩形与安全边距，二分出刚好装下的机位距离。
##     这样 1920x1080 / 1600x720 / 任何窗口比例都不会裁切（截图验收就是这么过的）。
##   · 规划阶段：镜头**锁死**在玩家区（3×6 棋盘居中），禁止平移；缩放也是固定的，
##     因为敌方意图要靠 UI 栏读，不该靠偷看。
##   · 攻防阶段：允许在"双区并集"里平移 + 缩放，但注视点**不许离开战场**，
##     而且最大拉远只够装下一个区 —— 两个区之和永远装不进一屏（这是设计约束，不是巧合）。
##   · 阶段切换是**平滑过渡**（指数趋近），不是瞬移。

const PITCH_DEG := 58.0
const YAW_DEG := 0.0
const FOV := 42.0

## 安全边距（NDC）：规划期底部要给手牌栏让位，顶部要给意图栏让位。
const MARGIN_PLAN_X := 0.90
const MARGIN_PLAN_TOP := 0.79
const MARGIN_PLAN_BOTTOM := -0.73
const MARGIN_BATTLE_X := 0.94
const MARGIN_BATTLE_Y := 0.80

const DIST_MIN := 18.0
const DIST_MAX := 420.0
const LERP_RATE := 6.5
const PAN_SPEED := 52.0
const ZOOM_STEP := 1.14
## 攻防阶段的默认机位 = "装下一个区"的距离 × 这个系数（<1 = 比全区更近，单位看得清）
const BATTLE_ZOOM := 0.85

var camera: Camera3D = null

var _arena: Dictionary = {}
var _phase := "planning"
var _focus := Vector3.ZERO          # 当前注视点（平滑值）
var _dist := 60.0                   # 当前机位距离（平滑值）
var _want_focus := Vector3.ZERO
var _want_dist := 60.0
var _locked := true
var _bounds := Rect2()              # 攻防阶段允许的注视点范围（世界 XZ）
var _dist_fit := 60.0               # "装下一个区"的距离 = 攻防阶段的最大拉远
var _ready_done := false
## 玩家多久没手动操作，就自动把镜头拉回我方小队（0 = 永远跟随）
const AUTO_FOLLOW_IDLE := 2.0
var _manual_idle := 99.0
var _follow_target: Vector3 = Vector3.ZERO
var _has_follow := false


func _ready() -> void:
	if camera == null:
		camera = Camera3D.new()
		camera.name = "Camera"
		add_child(camera)
	camera.fov = FOV
	camera.near = 0.4
	camera.far = 900.0
	camera.current = true


func setup(arena: Dictionary) -> void:
	if camera == null:
		_ready()
	_arena = arena
	_ready_done = true
	apply_phase(_phase, true)


## 阶段切换：planning / attack / defend / result
func apply_phase(phase: String, instant: bool = false) -> void:
	_phase = phase
	var min_x := float(_arena.get("min_x", -104.0))
	var max_x := float(_arena.get("max_x", 104.0))
	var min_z := float(_arena.get("min_z", -22.0))
	var max_z := float(_arena.get("max_z", 22.0))
	var pz := float(_arena.get("player_zone_x", min_x + 72.0))
	var ez := float(_arena.get("enemy_zone_x", max_x - 72.0))

	match phase:
		"planning":
			_locked = true
			var rect := _player_rect()
			_want_dist = _fit_distance(rect, MARGIN_PLAN_X, MARGIN_PLAN_TOP, MARGIN_PLAN_BOTTOM)
			_want_focus = Vector3(rect.position.x + rect.size.x * 0.5, 0.0,
				rect.position.y + rect.size.y * 0.5)
			_dist_fit = _want_dist
			_bounds = rect
		"attack":
			_locked = false
			# 允许平移的范围 = 中立区 ∪ 敌方区（整片战场，不能移出去）
			_bounds = Rect2(Vector2(pz, min_z), Vector2(max_x - pz, max_z - min_z))
			# 最大拉远只够装下**一个区**（敌方区）—— 两个区之和永远装不进一屏
			_dist_fit = _fit_region_distance(ez, max_x, min_z, max_z)
			_want_dist = _dist_fit * BATTLE_ZOOM
			# 开局看住"我方前压点 → 中立区"，而不是两区正中（正中看不到自己人）
			_want_focus = Vector3(pz + 20.0, 0.0, 0.0)
		"defend":
			_locked = false
			_bounds = Rect2(Vector2(min_x, min_z), Vector2(ez - min_x, max_z - min_z))
			_dist_fit = _fit_region_distance(min_x, pz, min_z, max_z)
			_want_dist = _dist_fit * BATTLE_ZOOM
			_want_focus = Vector3(pz - 20.0, 0.0, 0.0)
		_:
			# result：保持当前机位，只解锁
			_locked = false
			_bounds = Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))

	if instant:
		_focus = _want_focus
		_dist = _want_dist
		_apply_transform()
		print("[cam] phase=%s bounds=%s dist=%.1f focus=%s vp=%s" % [
			phase, str(_bounds), _dist, str(_want_focus),
			str(get_viewport().get_visible_rect().size)])
	else:
		# 过渡时先把注视点夹回新边界，避免从旧机位"斜着飞"
		_want_focus = _clamp_focus(_want_focus)


## 玩家区构图矩形（世界 XZ）＝ **玩家所有格子的包围盒** + 3m 留白。
##
## 为什么不是"整个玩家区"：区深 40m、棋盘只占中间 23.6m，按整区构图会让棋盘缩成一条，
## 上下全是空地。按"格子包围盒"构图，棋盘自然吃满画面核心，而区的边界仍在画面内 ——
## 于是"一个区刚好一屏、两个区装不下"这两条同时成立。
func _player_rect() -> Rect2:
	var min_x := 1e9
	var max_x := -1e9
	var min_z := 1e9
	var max_z := -1e9
	for t in _arena.get("tiles", []):
		var tile: Dictionary = t
		if String(tile.get("side", "")) != "player":
			continue
		var hw := float(tile.get("w", 4.0)) * 0.5
		var hd := float(tile.get("d", 4.0)) * 0.5
		min_x = minf(min_x, float(tile.get("x", 0.0)) - hw)
		max_x = maxf(max_x, float(tile.get("x", 0.0)) + hw)
		min_z = minf(min_z, float(tile.get("z", 0.0)) - hd)
		max_z = maxf(max_z, float(tile.get("z", 0.0)) + hd)
	if min_x > max_x:
		# 没有玩家格子（异常底壳）：退回整区
		min_x = float(_arena.get("min_x", -104.0))
		max_x = float(_arena.get("player_zone_x", min_x + 72.0))
		min_z = float(_arena.get("min_z", -22.0))
		max_z = float(_arena.get("max_z", 22.0))
	var pad := 3.0
	return Rect2(Vector2(min_x - pad, min_z - pad), Vector2((max_x - min_x) + pad * 2.0, (max_z - min_z) + pad * 2.0))


func _fit_region_distance(x0: float, x1: float, z0: float, z1: float) -> float:
	var rect := Rect2(Vector2(x0, z0), Vector2(x1 - x0, z1 - z0))
	return _fit_distance(rect, MARGIN_BATTLE_X, MARGIN_BATTLE_Y, -MARGIN_BATTLE_Y)


# ===========================================================================
# 构图：二分距离，让地面矩形的角点全部落在安全 NDC 框里
# ===========================================================================
func _fit_distance(rect: Rect2, margin_x: float, margin_top: float, margin_bottom: float) -> float:
	var cx := rect.position.x + rect.size.x * 0.5
	var cz := rect.position.y + rect.size.y * 0.5
	var center := Vector3(cx, 0.0, cz)
	var hw := rect.size.x * 0.5
	var hd := rect.size.y * 0.5
	# 采样点：四角 + 四边中点，各取"地面"与"抬高一截"两层（建筑不能顶出画面）
	var probes: Array[Vector3] = []
	for dx in [-1.0, 0.0, 1.0]:
		for dz in [-1.0, 0.0, 1.0]:
			if dx == 0.0 and dz == 0.0:
				continue
			var p := center + Vector3(hw * dx, 0.0, hd * dz)
			probes.append(p)
			probes.append(p + Vector3(0.0, 14.0, 0.0))
	var lo := DIST_MIN
	var hi := DIST_MAX
	for _i in 26:
		var mid := (lo + hi) * 0.5
		if _fits(center, probes, mid, margin_x, margin_top, margin_bottom):
			hi = mid
		else:
			lo = mid
	return clampf(hi, DIST_MIN, DIST_MAX)


func _fits(center: Vector3, probes: Array[Vector3], dist: float,
		margin_x: float, margin_top: float, margin_bottom: float) -> bool:
	_place(center, dist)
	var vp := get_viewport()
	if vp == null:
		return true
	var vs := vp.get_visible_rect().size
	if vs.x <= 1.0 or vs.y <= 1.0:
		return true
	for p in probes:
		var sp := camera.unproject_position(p)
		var nx := sp.x / vs.x * 2.0 - 1.0
		var ny := 1.0 - sp.y / vs.y * 2.0
		if absf(nx) > margin_x:
			return false
		if ny > margin_top or ny < margin_bottom:
			return false
	return true


func _place(center: Vector3, dist: float) -> void:
	var pitch := deg_to_rad(PITCH_DEG)
	var yaw := deg_to_rad(YAW_DEG)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	camera.global_position = center + dir * dist
	camera.look_at(center, Vector3.UP)


func _apply_transform() -> void:
	_place(_focus, _dist)


# ===========================================================================
# 每帧：平滑 + 平移 + 缩放
# ===========================================================================
func _process(delta: float) -> void:
	if not _ready_done or camera == null:
		return
	if not _locked:
		_handle_pan(delta)
		_manual_idle += delta
		if _has_follow and _manual_idle >= AUTO_FOLLOW_IDLE:
			_want_focus = _clamp_focus(Vector3(_follow_target.x, 0.0, _follow_target.z))
	_focus = _focus.lerp(_want_focus, 1.0 - exp(-LERP_RATE * delta))
	_dist = lerpf(_dist, _want_dist, 1.0 - exp(-LERP_RATE * delta))
	_apply_transform()


func _handle_pan(delta: float) -> void:
	var dx := (1.0 if Input.is_key_pressed(KEY_RIGHT) else 0.0) - (1.0 if Input.is_key_pressed(KEY_LEFT) else 0.0)
	var dz := (1.0 if Input.is_key_pressed(KEY_DOWN) else 0.0) - (1.0 if Input.is_key_pressed(KEY_UP) else 0.0)
	if absf(dx) < 0.01 and absf(dz) < 0.01:
		return
	_manual_idle = 0.0
	var speed := PAN_SPEED * delta * clampf(_dist / 90.0, 0.55, 1.8)
	_want_focus += Vector3(dx * speed, 0.0, dz * speed)
	_want_focus = _clamp_focus(_want_focus)


## 鼠标拖动 / 触摸平移（Screens 的输入层调它；镜头自己不算屏幕坐标）
func pan_by(world_delta: Vector3) -> void:
	if _locked:
		return
	_manual_idle = 0.0
	_want_focus = _clamp_focus(_want_focus + Vector3(world_delta.x, 0.0, world_delta.z))


func zoom_by(factor: float) -> void:
	if _locked:
		return
	_manual_idle = 0.0
	# 上限 = 装下一个区的距离；下限 = 贴脸（但别穿到单位里）
	_want_dist = clampf(_want_dist * factor, DIST_MIN, maxf(_dist_fit, DIST_MIN + 1.0))


## 截图用：直接给一个机位距离（不等平滑）。上限仍受"一个区"约束，不许把镜头拉到能看两区。
func set_distance(d: float) -> void:
	_want_dist = clampf(d, DIST_MIN, maxf(_dist_fit, DIST_MIN + 1.0))
	_dist = _want_dist


## 截图用：把平滑值立刻对齐到目标（截一帧就要到位，不能还在飞）。
func snap() -> void:
	_focus = _want_focus
	_dist = _want_dist
	_apply_transform()


func set_focus_world(x: float, z: float) -> void:
	_manual_idle = 0.0
	_want_focus = _clamp_focus(Vector3(x, 0.0, z))


## 每帧由场景喂"我方小队质心"：镜头闲置一会儿就自动跟过去（60 秒自动战斗不看着会跑丢）。
func follow_world(x: float, z: float) -> void:
	_follow_target = Vector3(x, 0.0, z)
	_has_follow = true


func stop_follow() -> void:
	_has_follow = false


func _clamp_focus(p: Vector3) -> Vector3:
	if _bounds.size.x <= 0.0 or _bounds.size.y <= 0.0:
		return p
	# 允许注视点贴到边界内侧 2m，但绝不允许离开战场
	var inset := 2.0
	var lo_x := _bounds.position.x + inset
	var hi_x := _bounds.position.x + _bounds.size.x - inset
	var lo_z := _bounds.position.y + inset
	var hi_z := _bounds.position.y + _bounds.size.y - inset
	return Vector3(
		clampf(p.x, minf(lo_x, hi_x), maxf(lo_x, hi_x)),
		0.0,
		clampf(p.z, minf(lo_z, hi_z), maxf(lo_z, hi_z)))


# ===========================================================================
# 只读查询（自检 / 截图断言用）
# ===========================================================================
func focus_point() -> Vector3:
	return _focus


func distance() -> float:
	return _dist


func is_locked() -> bool:
	return _locked


func phase_name() -> String:
	return _phase


func bounds_rect() -> Rect2:
	return _bounds


func fit_distance() -> float:
	return _dist_fit
