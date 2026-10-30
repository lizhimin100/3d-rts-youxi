class_name RtsCamera
extends Node3D
## **魔兽式 RTS 镜头（HAWKEYE）**
##
## 手感目标（对齐 文档/作战条令.md §7）：
##   - 屏幕边缘滚动：**带加速度 + 阻尼，绝不瞬移**（Cfg 里的 pan_accel / pan_damping）
##   - 俯角固定（Cfg.game.camera_pitch_deg，默认 50°），Q/E 每次转 45°
##   - 滚轮缩放 Cfg.game.camera_distance_min ~ max（默认 13~34m）
##   - 注视点始终贴地（跟着地形高度），并被地图边界夹紧
##   - `focus_on(pos)` 平滑飞过去（小地图点击 / 主场景开局定位）
##   - `shake(strength)` 受击抖动（由 Game.camera_shake 信号驱动）
##
## 两条"别踩"的经验：
##   1. 主场景 add_child 之后立刻就会 call("focus_on")，所以 `_ready` 里必须把相机建好；
##   2. **Game.level 可能还是 null**（关卡没建好/脚本缺失），所有取地形高度、
##      地图边界的地方都要判空，否则开局第一帧就崩。
##
## WASD 与方向键的取舍：方向键永远平移；WASD 只在"没有选中单位"时平移（否则让给玩法），
## 这是 代码/配置/输入配置.gd 里写明的约定。

# ===========================================================================
# 状态
# ===========================================================================
## 子相机（真正参与渲染的 Camera3D）
var cam: Camera3D = null

## 当前注视点（贴地）/ 目标注视点
var _focus: Vector3 = Vector3.ZERO
var _focus_target: Vector3 = Vector3.ZERO

## 平移速度（世界 XZ 平面，带加速度与阻尼）
var _pan_vel: Vector3 = Vector3.ZERO

## 相机到注视点的距离（当前 / 目标）
var _dist: float = 22.0
var _dist_target: float = 22.0

## 偏航角（弧度；当前 / 目标）
var _yaw: float = 0.0
var _yaw_target: float = 0.0

## 抖动幅度（指数衰减）
var _shake_amp: float = 0.0

## 中键拖拽旋转中
var _dragging: bool = false

## 鼠标是否已经在窗口里出现过（出现过才允许边缘滚动）
## 为什么要这个：启动瞬间光标可能停在屏幕角落（无头运行时更是固定 0,0），
## 没有这道闸，镜头会从开局第一帧就自己往角落里跑，截图与自动化全废。
var _mouse_seen: bool = false
## 上一帧鼠标位置（用来判断"动过没有"）
var _last_mouse_pos: Vector2 = Vector2(-1.0, -1.0)

## 是否已经完成第一次定位（第一次 focus_on 直接瞬移，避免开局镜头从天边飞进来）
var _placed: bool = false

## 测试夹具覆写：正式游戏留 null，自动走 Cfg/Game 单例；
## 地形自检里可以直接塞一个合成关卡/配置，不依赖 HOUND 的单位脚本。
var level_override: RtsLevel = null
var cfg_override: GameConfig = null

# ===========================================================================
# 地形高度保护（RIDGE 2026-10-18）
# ===========================================================================
## 相机最低离地高度（米）。必须大于近裁剪面（0.25m）+ 一点余量，
## 崖边看下去时才不会把近平面切进岩石里。
const TERRAIN_SAFE_HEIGHT: float = 1.5
## 相机正下方 1.2m 邻域的最低离地高度（防止崖壁从镜头侧面切进来）
const TERRAIN_NEAR_SAFE: float = 0.9
## 视线采样从这里开始计算净空（太靠近注视点的一小段允许贴地，
## 否则注视点在沟底时相机会被"要求瞬间抬到天上"）
const TERRAIN_SWEEP_MIN_T: float = 0.18


## 设置相机距离（QA / 过场用；正常游戏走滚轮）
func set_distance(d: float) -> void:
	var cfg: GameConfig = _config()
	var lo: float = cfg.camera_distance_min if cfg != null else 8.0
	var hi: float = cfg.camera_distance_max if cfg != null else 44.0
	_dist = clampf(d, lo, hi)
	_dist_target = _dist


## 记录鼠标状态。
##
## ★ 这里踩过一个坑：原来要求"鼠标动过"才允许边缘滚动（_mouse_seen），
##   结果玩家一开局就把光标怼在屏幕边缘不动 —— 直接整晚滚不动，被骂"偷懒没做完"。
##   正确判据不是"动过没有"，而是"鼠标在不在窗口里 + 窗口有没有焦点"。
func _track_mouse() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var mp: Vector2 = vp.get_mouse_position()
	_last_mouse_pos = mp
	# 鼠标坐标落在窗口内就算"可用"（无头模式下坐标为 0，不做边缘滚动）
	var vsize: Vector2 = vp.get_visible_rect().size
	if vsize.x > 1.0 and vsize.y > 1.0:
		if mp.x >= 0.0 and mp.y >= 0.0 and mp.x <= vsize.x and mp.y <= vsize.y:
			if DisplayServer.get_name() != "headless":
				_mouse_seen = true

## 缓存的兄弟节点：选择系统（判断"有没有选中单位"，决定 WASD 是否让出）
var _selection_system: Node = null


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	cam = Camera3D.new()
	cam.name = "相机"
	cam.fov = 52.0
	cam.near = 0.25
	cam.far = 520.0
	add_child(cam)
	# 显式声明当前相机：别的系统靠 get_viewport().get_camera_3d() 拿它做射线
	cam.current = true

	var cfg: GameConfig = _config()
	if cfg != null:
		_dist = cfg.camera_distance_default
		_dist_target = _dist
	if Game != null and Game.has_signal("camera_shake"):
		Game.camera_shake.connect(_on_shake_requested)


func _process(delta: float) -> void:
	var cfg: GameConfig = _config()
	if cfg == null or cam == null:
		return
	_cache_siblings()
	_track_mouse()
	_handle_home(cfg)
	_update_lock(cfg, delta)
	_update_rotation(cfg, delta)
	_update_pan(cfg, delta)
	_apply_pose(cfg, delta)


## 当前相机到注视点的距离（小地图/界面判断视野用）
func distance() -> float:
	return _dist


## 当前偏航角（度）——给自检/小地图用
func yaw_degrees() -> float:
	return rad_to_deg(_yaw)


## 当前注视点（贴地的世界坐标）
func focus_point() -> Vector3:
	return _focus


## 相机离它正下方地形的净空（米）。自检/调试用；相机没建好返回 INF。
func terrain_clearance() -> float:
	if cam == null:
		return INF
	var lv := _level()
	if lv == null:
		return INF
	return cam.global_position.y - lv.height_at(cam.global_position.x, cam.global_position.z)


## 地形高度保护是否生效（净空 >= margin）
func is_terrain_safe(margin: float = 0.6) -> bool:
	return terrain_clearance() >= margin


## 两点之间的视线是否在地形之上（按 1m 采样）。镜头/高地遮挡自检用。
func line_of_sight_clear(a: Vector3, b: Vector3, clearance: float = 0.0) -> bool:
	var lv := _level()
	if lv == null:
		return true
	var dist: float = Vector2(b.x - a.x, b.z - a.z).length()
	var n: int = clampi(int(ceil(dist)), 8, 96)
	for i in range(n + 1):
		var t: float = float(i) / float(n)
		var p: Vector3 = a.lerp(b, t)
		if p.y < lv.height_at(p.x, p.z) + clearance:
			return false
	return true


# ===========================================================================
# 对外接口（文档 §7 冻结）
# ===========================================================================

## 平滑飞到某个世界坐标（小地图点击、开局对准基地都用它）
func focus_on(pos: Vector3) -> void:
	_focus_target = _clamp_focus(Vector3(pos.x, 0.0, pos.z))
	if not _placed:
		# 第一次：直接落位，别让玩家开局看一段飞行
		_focus = _focus_target
		_placed = true
	else:
		_focus = _focus  # 保持当前位置，交给 _update_focus 平滑插值


## 镜头抖动（strength 越大越晃；duration 目前只作为注释性参数，衰减由 Cfg 控制）
func shake(strength: float, _duration: float = 0.35) -> void:
	_shake_amp = maxf(_shake_amp, strength)


## 屏幕坐标 → 地面点（带地形高度迭代）。选择/指令系统自带一份同样的数学，
## 这里提供是为了外部调试与将来的点击特效。
func screen_to_ground(screen_pos: Vector2) -> Vector3:
	if cam == null:
		return Vector3.ZERO
	return ray_ground(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos))


## 射线与地面求交：先用 y=0 平面求初值，再按地形高度迭代 3 次（不用物理引擎）
func ray_ground(from: Vector3, dir: Vector3) -> Vector3:
	if absf(dir.y) < 0.00001:
		return Vector3(from.x, 0.0, from.z)
	var lv := _level()
	var y: float = 0.0
	var p: Vector3 = Vector3(from.x, 0.0, from.z)
	for _i in range(3):
		var t: float = (y - from.y) / dir.y
		if t < 0.0:
			return Vector3(p.x, y, p.z)
		p = from + dir * t
		y = lv.height_at(p.x, p.z) if lv != null else 0.0
	return Vector3(p.x, y, p.z)


# ===========================================================================
# 内部：输入
# ===========================================================================

## 缓存选择系统引用（它是我们的兄弟节点，可能比我们晚建好）
func _cache_siblings() -> void:
	if _selection_system != null and is_instance_valid(_selection_system):
		return
	var parent := get_parent()
	if parent == null:
		return
	_selection_system = parent.get("selection_system") as Node


## 有没有选中单位（有的话 WASD 让给玩法）
func _has_selection() -> bool:
	if _selection_system == null or not is_instance_valid(_selection_system):
		return false
	var sel: Variant = _selection_system.get("selected")
	if sel is Array:
		return not (sel as Array).is_empty()
	return false


## 空格：回自家基地（有选中则回到选中单位重心）
func _handle_home(_cfg: GameConfig) -> void:
	if not Input.is_action_just_pressed(InputSetup.CAM_HOME):
		return
	if _has_selection():
		var sum := Vector3.ZERO
		var n: int = 0
		for u in _selection_system.get("selected"):
			if u != null and is_instance_valid(u) and u is Node3D:
				sum += (u as Node3D).global_position
				n += 1
		if n > 0:
			focus_on(sum / float(n))
			return
	var lv := _level()
	if lv != null and Game.player_faction != null:
		focus_on(lv.base_center(Game.player_faction))


## 滚轮/键盘缩放
func _handle_zoom(cfg: GameConfig) -> void:
	var dir: float = 0.0
	if Input.is_action_just_pressed(InputSetup.CAM_ZOOM_IN):
		dir -= 1.0
	if Input.is_action_just_pressed(InputSetup.CAM_ZOOM_OUT):
		dir += 1.0
	if absf(dir) > 0.0:
		_zoom_steps(cfg, dir)


## 缩放 n 格（负数拉近）
func _zoom_steps(cfg: GameConfig, steps: float) -> void:
	_dist_target = clampf(_dist_target + steps * cfg.camera_zoom_step,
			cfg.camera_distance_min, cfg.camera_distance_max)


## Q/E 每次转 camera_rotate_step 度
func _update_rotation(cfg: GameConfig, delta: float) -> void:
	if Input.is_action_just_pressed(InputSetup.CAM_ROTATE_L):
		_yaw_target -= deg_to_rad(cfg.camera_rotate_step)
	if Input.is_action_just_pressed(InputSetup.CAM_ROTATE_R):
		_yaw_target += deg_to_rad(cfg.camera_rotate_step)
	var k: float = 1.0 - exp(-cfg.camera_rotate_speed * delta)
	_yaw = lerp_angle(_yaw, _yaw_target, k)


## 距离插值（缩放阻尼）
func _update_lock(cfg: GameConfig, delta: float) -> void:
	_handle_zoom(cfg)
	var k: float = 1.0 - exp(-cfg.camera_zoom_damping * delta)
	_dist = lerpf(_dist, _dist_target, k)


# ===========================================================================
# 内部：平移
# ===========================================================================

## 这一帧的平移输入（x=+1 向右，y=+1 向前/屏幕上边），返回未归一化向量
func _pan_axis() -> Vector2:
	var v := Vector2.ZERO

	# --- 屏幕边缘（鼠标在窗口内、窗口有焦点、且没被界面吃掉时才生效）---
	var vp := get_viewport()
	if vp != null and _edge_scroll_allowed() and not _mouse_over_ui():
		var vsize: Vector2 = vp.get_visible_rect().size
		var mp: Vector2 = vp.get_mouse_position()
		var m: float = _config().camera_edge_margin
		# ★ 关键修正：窗口模式下 OS **不锁光标**，鼠标推到边缘时会跑到窗口外，
		#   get_mouse_position() 会给出负数或超出画面的值。原实现要求"必须在窗口内"，
		#   于是玩家把光标顶到边缘反而滚不动（被投诉成"没做完"）。
		#   现在：只要落在边缘带**或窗口外**，就按那个方向滚。
		if mp.x <= m:
			v.x -= 1.0
		elif mp.x >= vsize.x - m:
			v.x += 1.0
		if mp.y <= m:
			v.y += 1.0
		elif mp.y >= vsize.y - m:
			v.y -= 1.0

	# --- 方向键：永远可平移 ---
	if Input.is_physical_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT):
		v.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP):
		v.y += 1.0
	if Input.is_physical_key_pressed(KEY_DOWN):
		v.y -= 1.0

	# --- WASD：**永远可平移** ---
	# ★ 原来写成"没有选中单位时 WASD 才平移"，结果选中部队后 WASD 突然失灵 ——
	#   这是最典型的"反人类手感"。玩法的快捷键已经错开了：
	#   攻击移动=F / 停止=X / 保持=H / 建造=B / 技能=1,2,3，和 WASD 不冲突。
	if Input.is_physical_key_pressed(KEY_A):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		v.y += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		v.y -= 1.0

	if v.length_squared() > 1.0:
		v = v.normalized()
	return v


## 屏幕方向 → 世界 XZ 方向（跟着偏航角走）
func _screen_dir(v: Vector2) -> Vector3:
	var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))  # 镜头看向的水平方向
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	return (right * v.x + forward * v.y).normalized()


## 平移：加速 + 指数衰减 + 夹紧（"跟手但不飘"就靠这套曲线）
##
## 手感口径（踩过的坑都写在这）：
##   · 按下：move_toward 以 camera_pan_accel 逼近目标速度 → 0.1~0.2s 到满速，**不瞬移**；
##   · 松开：速度 **指数衰减** —— 溜一小段就停（约 0.12s），既不是"一松手立刻死"，
##     也不是"滑半天"（原来那版用了 accel×damping 的固定减速度，结果是一帧急刹）；
##   · 上限：camera_pan_speed 的 1.25 倍，防止叠加超速"一按就飞出去"。
func _update_pan(cfg: GameConfig, delta: float) -> void:
	var axis := _pan_axis()
	var has_input: bool = axis.length_squared() > 0.0001
	if has_input:
		var want: Vector3 = _screen_dir(axis) * cfg.camera_pan_speed * cfg.camera_key_pan_scale
		_pan_vel = _pan_vel.move_toward(want, cfg.camera_pan_accel * delta)
	else:
		_pan_vel *= exp(-cfg.camera_pan_damping * delta)
		if _pan_vel.length() < 0.05:
			_pan_vel = Vector3.ZERO
	var max_speed: float = cfg.camera_pan_speed * 1.25
	if _pan_vel.length() > max_speed:
		_pan_vel = _pan_vel.normalized() * max_speed

	_focus_target += _pan_vel * delta
	_focus_target = _clamp_focus(_focus_target)

	# 注视点跟随：
	# ★ 这里踩过大坑 —— "速度曲线 + 注视点插值"两层平滑叠在一起，
	#   实测起速要 0.52s 才到 90%，手感就是"飘、不跟手"。
	#   正解：**输入期 / 高速期直接跟住目标**（平滑已经由速度曲线负责），
	#   只有松手后的小幅收尾和 focus_on 飞行才用指数插值。
	var moving_fast: bool = has_input or _pan_vel.length() > 0.05
	if moving_fast:
		_focus = _focus_target
	else:
		var damp: float = cfg.camera_focus_damping * 2.2
		_focus = _focus.lerp(_focus_target, 1.0 - exp(-damp * delta))
	_focus.y = _ground_y(_focus.x, _focus.z)


# ===========================================================================
# 内部：落位
# ===========================================================================

## 把姿态算出来写进子相机（含抖动）
func _apply_pose(cfg: GameConfig, delta: float) -> void:
	var pitch: float = deg_to_rad(cfg.camera_pitch_deg)
	var off := Vector3(
		sin(_yaw) * cos(pitch),
		sin(pitch),
		cos(_yaw) * cos(pitch)
	) * _dist
	var pos: Vector3 = _focus + off

	# 抖动：指数衰减，位置与注视点都抖一点，看起来像"被打到"
	if _shake_amp > 0.0005:
		var s: float = _shake_amp
		pos += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0) * 0.7, randf_range(-1.0, 1.0)) * s
		_shake_amp = lerpf(_shake_amp, 0.0, 1.0 - exp(-cfg.camera_shake_decay * delta))
	else:
		_shake_amp = 0.0

	# 地形高度保护：只在最后一步抬 y，不碰俯角/距离/缩放/平移参数。
	# 抖动之后再做，免得受击时画面把镜头甩进崖壁。
	pos = _protect_from_terrain(pos)

	cam.global_position = pos
	var look := _focus + Vector3.UP * (_dist * 0.06)
	if pos.distance_squared_to(look) > 0.25:
		cam.look_at(look, Vector3.UP)


## 地形高度保护（只抬 y，不动 _dist/_yaw/_focus/手感参数）
##
## 两道保险：
##   1) **相机自身**：y >= 正下方地形 + TERRAIN_SAFE_HEIGHT；再检查 1.2m 邻域，
##      防止崖壁从镜头侧面切进近裁剪面；
##   2) **视线**：从注视点向相机做 1m 级采样。如果中间有崖/脊高出视线，
##      把相机沿 y 抬到"刚好越过"的高度。台地边缘/沟壑里看单位时，
##      近平面就不会切进岩壁，也不会被自己脚下的高地挡死。
func _protect_from_terrain(raw: Vector3) -> Vector3:
	var lv := _level()
	if lv == null:
		return raw
	var out: Vector3 = raw
	var focus_y: float = _focus.y

	# 1) 相机正下方
	out.y = maxf(out.y, lv.height_at(out.x, out.z) + TERRAIN_SAFE_HEIGHT)

	# 2) 视线采样（按水平距离 1m 一点，限制 12~56 点）
	var horiz: float = Vector2(out.x - _focus.x, out.z - _focus.z).length()
	var n: int = clampi(int(ceil(horiz)), 12, 56)
	for i in range(1, n + 1):
		var t: float = float(i) / float(n)
		if t < TERRAIN_SWEEP_MIN_T:
			continue
		var sx: float = lerpf(_focus.x, out.x, t)
		var sz: float = lerpf(_focus.z, out.z, t)
		var gy: float = lv.height_at(sx, sz)
		# 靠近注视点的净空从 0 逐渐加到满值，避免沟底注视点把镜头顶上天
		var clear: float = TERRAIN_SAFE_HEIGHT * smoothstep(TERRAIN_SWEEP_MIN_T, 0.65, t)
		var req: float = focus_y + (gy + clear - focus_y) / t
		out.y = maxf(out.y, req)

	# 3) 相机 1.2m 邻域：崖壁从侧面切进近平面也算穿模
	for k in range(8):
		var ang: float = TAU * float(k) / 8.0
		var px: float = out.x + cos(ang) * 1.2
		var pz: float = out.z + sin(ang) * 1.2
		out.y = maxf(out.y, lv.height_at(px, pz) + TERRAIN_NEAR_SAFE)

	return out


## 配置：测试夹具优先，正式游戏走 Cfg 单例
func _config() -> GameConfig:
	if cfg_override != null:
		return cfg_override
	if Cfg == null:
		return null
	return Cfg.game


## 当前关卡：测试夹具优先，正式游戏走 Game.level
func _level() -> RtsLevel:
	if level_override != null and is_instance_valid(level_override):
		return level_override
	if Game == null:
		return null
	var v: Variant = Game.get("level")
	return v as RtsLevel


## 贴地高度（关卡没建好就是 0）
func _ground_y(x: float, z: float) -> float:
	var lv := _level()
	if lv == null:
		return 0.0
	return lv.height_at(x, z)


## 夹进地图边界。
##
## ★ 关键：不能只夹"注视点"，还要扣掉**相机自己向后撤的距离**。
##   相机在注视点的正后方 dist*cos(pitch) 米处，只夹注视点的话，
##   玩家把镜头推到地图南边时，相机已经飞到地图外面 → 屏幕下半截露出"虚空"
##   （实测就是这样，虽然被远景底板挡住了，但会看到一大片死黑）。
##   所以边界要按当前缩放实时收窄：能看的地方 = 地图半宽 - 相机后撤距离。
func _clamp_focus(p: Vector3) -> Vector3:
	var cfg: GameConfig = _config()
	var out := p
	out.y = 0.0
	var lv := _level()
	if lv != null and cfg != null:
		var pitch: float = deg_to_rad(cfg.camera_pitch_deg)
		var reach: float = _dist * cos(pitch)          # 相机往后撤的水平距离
		var limit: float = lv.world_size * 0.5 - reach + cfg.camera_bounds_margin
		limit = maxf(limit, lv.world_size * 0.12)      # 兜底：至少还能在中间一小块活动
		out.x = clampf(out.x, -limit, limit)
		out.z = clampf(out.z, -limit, limit)
	out.y = _ground_y(out.x, out.z)
	return out


## 鼠标是不是压在"实心的界面面板"上（压在面板上才不做边缘滚动）。
##
## ★ 判据必须严格，否则边缘滚动会被界面整片吃掉：
##   - 只有 MOUSE_FILTER_STOP 的控件才算（IGNORE/PASS 是布局用的，不拦输入）；
##   - 尺寸接近满屏的容器也不算（那只是根节点，不是真的挡住了画面）。
func _mouse_over_ui() -> bool:
	var vp := get_viewport()
	if vp == null or not vp.has_method("gui_get_hovered_control"):
		return false
	var c: Control = vp.call("gui_get_hovered_control") as Control
	if c == null:
		return false
	if c.mouse_filter != Control.MOUSE_FILTER_STOP:
		return false
	var vs: Vector2 = vp.get_visible_rect().size
	var r: Rect2 = c.get_global_rect()
	if r.size.x >= vs.x * 0.92 and r.size.y >= vs.y * 0.92:
		return false
	return true


## 允许边缘滚动的条件：见过鼠标 + 窗口有焦点（避免开局自己乱跑 / 切出去还在滚）
func _edge_scroll_allowed() -> bool:
	if not _mouse_seen:
		return false
	var win := get_window()
	if win != null and win.has_method("has_focus") and not win.has_focus():
		return false
	return true


# ===========================================================================
# 内部：输入事件（滚轮缩放 + 中键拖拽旋转）
# ===========================================================================

func _unhandled_input(event: InputEvent) -> void:
	var cfg: GameConfig = _config()
	if cfg == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_steps(cfg, -1.0)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_steps(cfg, 1.0)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		# 中键拖拽：自由旋转（不吸附 45°）
		_yaw_target -= mm.relative.x * 0.008
		get_viewport().set_input_as_handled()


## Game.camera_shake 信号 → 抖动
func _on_shake_requested(strength: float) -> void:
	shake(strength)