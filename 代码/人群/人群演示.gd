extends Node3D
## **人群演示 / 压测场** —— 独立场景，不碰主游戏的任何节点。
##
## 跑法（**必须开窗口**：headless 的 dummy 渲染器下 `MultiMesh.buffer` 长度为 0）：
##   godot --path . 场景/人群演示.tscn -- --crowd-bench=1000 --crowd-secs=10
##   godot --path . 场景/人群演示.tscn -- --crowd-bench=10000 --crowd-secs=10
## 参数：
##   --crowd-bench=N   单位数（默认 1000）
##   --crowd-secs=S    压测时长（默认 10 秒），到点打印一行 [CROWD] 并退出
##   --crowd-air=R     空中单位比例 0..1（默认 0.06）
##   --crowd-teams=T   队伍数（默认 4）
##   --crowd-cam=free  自由视角（默认是固定俯瞰）
##
## 这个场景同时是"验收场"：4 队从四角出发穿过中央障碍，互相穿越、抢同一条窄缝——
## 推挤、互让、圆角、流场、阵型、空中层全在这条路线上跑一遍。

const C := preload("res://代码/人群/人群常量.gd")
const Sim := preload("res://代码/人群/人群模拟.gd")
const Render := preload("res://代码/人群/人群渲染.gd")
const Arrow := preload("res://代码/人群/人群箭矢.gd")

var sim: Sim = null
var render: Render = null
var arrows: Arrow = null
var cam: Camera3D = null
var hud: Label = null

var _acc: float = 0.0
var _elapsed: float = 0.0
var _frames: int = 0
var _frames_total: int = 0
var _fps_sum: float = 0.0
var _fps_min: float = 9999.0
var _tick_sum: float = 0.0
var _tick_max: float = 0.0
var _tick_n: int = 0
var _steer_sum: float = 0.0
var _spatial_sum: float = 0.0
var _flow_sum: float = 0.0
var _draw_sum: float = 0.0
var _arrow_t: float = 0.0

var bench_n: int = 0
var bench_secs: float = 10.0
var air_ratio: float = 0.06
var team_n: int = 4
var free_cam: bool = false
var _thread_override: int = 0
var close_cam: bool = false
var shot_path: String = ""
var _bench_done: bool = false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--crowd-bench="):
			bench_n = int(a.get_slice("=", 1))
		elif a.begins_with("--crowd-secs="):
			bench_secs = float(a.get_slice("=", 1))
		elif a.begins_with("--crowd-air="):
			air_ratio = clampf(float(a.get_slice("=", 1)), 0.0, 0.8)
		elif a.begins_with("--crowd-teams="):
			team_n = maxi(1, int(a.get_slice("=", 1)))
		elif a.begins_with("--crowd-threads="):
			_thread_override = int(a.get_slice("=", 1))
		elif a.begins_with("--crowd-shot="):
			shot_path = a.get_slice("=", 1)
		elif a == "--crowd-close":
			close_cam = true
		elif a == "--crowd-cam=free":
			free_cam = true

	sim = Sim.new()
	sim.configure_threads(_thread_override if _thread_override > 0 else OS.get_processor_count())
	_build_world()
	_build_terrain()
	_spawn_units()

	# 压测时关垂直同步：不关的话 60Hz 显示器会把上限锁在 ~58fps，
	# 测出来的是显示器不是引擎。
	if bench_n > 0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		print("[CROWD] 开始压测 n=%d secs=%.1f air=%.2f teams=%d threads=%d" % [
			bench_n, bench_secs, air_ratio, team_n, sim._threads])
		_elapsed = 0.0
	else:
		print("[CROWD] 演示模式（--crowd-bench=N 开始压测）")


# ===========================================================================
# 建世界
# ===========================================================================

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.35, 0.52, 0.72)
	sm.sky_horizon_color = Color(0.75, 0.78, 0.80)
	sm.ground_bottom_color = Color(0.28, 0.30, 0.26)
	sm.ground_horizon_color = Color(0.55, 0.56, 0.50)
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.85
	e.fog_enabled = true
	e.fog_light_color = Color(0.72, 0.76, 0.80)
	e.fog_density = 0.0016
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = false
	add_child(sun)

	cam = Camera3D.new()
	cam.fov = 52.0
	add_child(cam)
	if free_cam:
		cam.position = Vector3(0, 26, 46)
		cam.rotation_degrees = Vector3(-30, 0, 0)
	else:
		# 俯视全图：224m 地图在 900p 下大概占满宽度；太低会看不到 +Z 侧两队
		cam.fov = 55.0
		if close_cam:
			# 近景：看个体动画/推挤（12m 高，约 20m 视野）
			cam.look_at_from_position(Vector3(0, 12, 14), Vector3(0, 0, 0), Vector3.UP)
		else:
			cam.look_at_from_position(Vector3(0, 46, 40), Vector3(0, 0, -2), Vector3.UP)
	cam.current = true

	# 地面（一大块，给个单位落脚的视觉参考；真实高度由模拟的 height 表决定）
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(256, 256)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.34, 0.38, 0.30)
	gm.roughness = 1.0
	ground.material_override = gm
	ground.position = Vector3(0, -0.06, 0)
	add_child(ground)

	var hud_layer := CanvasLayer.new()
	add_child(hud_layer)
	hud = Label.new()
	hud.position = Vector2(16, 12)
	hud.add_theme_font_size_override("font_size", 18)
	hud.add_theme_color_override("font_color", Color(1, 1, 1))
	hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	hud.add_theme_constant_override("shadow_offset_x", 1)
	hud.add_theme_constant_override("shadow_offset_y", 1)
	hud_layer.add_child(hud)


## 256×256 的 1m 地形：外圈墙 + 中央 10 根柱子 + 两道半墙（逼出窄缝和绕行）
func _build_terrain() -> void:
	var walk := PackedByteArray()
	walk.resize(C.GRID_TOTAL)
	walk.fill(1)
	var height := PackedFloat32Array()
	height.resize(C.GRID_TOTAL)
	height.fill(0.0)

	for cz in range(C.GRID_N):
		for cx in range(C.GRID_N):
			var i: int = (cz << 8) | cx
			# 外圈 5m 不可走
			if cx < 5 or cx >= 251 or cz < 5 or cz >= 251:
				walk[i] = 0
				continue
			var wx: float = float(cx) - 128.0 + 0.5
			var wz: float = float(cz) - 128.0 + 0.5
			# 轻微起伏（0..0.55m，**不取负值**：地面板在 y=-0.06，负高度会把兵埋进去）
			height[i] = (sin(wx * 0.055) * 0.5 + 0.5) * 0.34 + (cos(wz * 0.041) * 0.5 + 0.5) * 0.21

	# 中央十根柱：半径 3.2m
	# 柱子放在外围环上（r≈40–48m）：中央 30m 是"绞肉机"，
	# 四队在空地上正面相撞，推挤/互让才试得出来；柱子负责试绕行与圆角。
	var pillars: Array = [
		[-42.0, -22.0], [8.0, -46.0], [44.0, -18.0], [-46.0, 16.0],
		[22.0, 42.0], [-26.0, 44.0], [46.0, 24.0], [-44.0, -6.0],
	]
	for p in pillars:
		_blob(walk, float(p[0]), float(p[1]), 3.2, 0)

	# 两道半墙（留 3m 窄缝，专门用来验"互让 + Hold 抗推"）
	_wall(walk, -52.0, -34.0, 26.0, 1.6)
	_wall(walk, 30.0, 40.0, 30.0, 1.6)

	sim.set_terrain(walk, height)
	_build_obstacle_meshes(pillars)


func _blob(walk: PackedByteArray, wx: float, wz: float, r: float, value: int) -> void:
	var cx0: int = int(wx) + 128
	var cz0: int = int(wz) + 128
	var ri: int = int(ceil(r))
	for dz in range(-ri, ri + 1):
		for dx in range(-ri, ri + 1):
			if dx * dx + dz * dz > r * r:
				continue
			var cx: int = cx0 + dx
			var cz: int = cz0 + dz
			if cx < 1 or cx > 254 or cz < 1 or cz > 254:
				continue
			walk[(cz << 8) | cx] = value


func _wall(walk: PackedByteArray, wx: float, wz: float, length: float, thick: float) -> void:
	var cx0: int = int(wx) + 128
	var cz0: int = int(wz) + 128
	var half_l: int = int(length * 0.5)
	var half_t: int = int(thick * 0.5)
	for dz in range(-half_t, half_t + 1):
		for dx in range(-half_l, half_l + 1):
			var cx: int = cx0 + dx
			var cz: int = cz0 + dz
			if cx < 1 or cx > 254 or cz < 1 or cz > 254:
				continue
			walk[(cz << 8) | cx] = 0


## 只给柱子做可见网格（墙太薄，用地面色差表示；柱子看得见才好评判绕行）
func _build_obstacle_meshes(pillars: Array) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.40, 0.37)
	mat.roughness = 0.95
	for p in pillars:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 2.2
		cm.bottom_radius = 3.0
		cm.height = 5.0
		cm.radial_segments = 10
		mi.mesh = cm
		mi.material_override = mat
		mi.position = Vector3(float(p[0]), 2.2, float(p[1]))
		add_child(mi)


# ===========================================================================
# 生成单位
# ===========================================================================

func _spawn_units() -> void:
	var n: int = bench_n if bench_n > 0 else 400
	var per: int = maxi(1, n / team_n)
	# 胶囊体比方块像人：方块在近景是"倾斜的板砖"，胶囊至少有肩膀和头。
	# 模型中心在原点（高 1.7m），渲染时由 y_offset 抬高半身高。
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.22
	mesh.height = 1.7
	mesh.radial_segments = 6
	mesh.rings = 2

	var smat := ShaderMaterial.new()
	smat.shader = load("res://代码/人群/人群单位.gdshader")

	render = Render.new()
	render.capacity = C.MAX_UNITS
	render.model_scale = 1.0
	render.y_offset = 0.85
	add_child(render)
	render.setup(mesh, smat)
	render.camera = cam

	arrows = Arrow.new()
	add_child(arrows)
	arrows.setup()
	arrows.on_hit = _on_arrow_hit

	# 四角出发，目标在对角（穿过中央障碍区）
	# **十字对冲**：四队沿四条轴正面相撞。这是推挤/互让的最严苛编排——
	# 同一条 3m 窄缝里两队迎面过，谁也不让就会卡死，让不过去就会穿模。
	var corners: Array = [
		Vector3(-72, 0, 0), Vector3(72, 0, 0),
		Vector3(0, 0, -72), Vector3(0, 0, 72),
	]
	var goals: Array = [
		Vector3(72, 0, 0), Vector3(-72, 0, 0),
		Vector3(0, 0, 72), Vector3(0, 0, -72),
	]
	var idx: int = 0
	for t in range(team_n):
		var from: Vector3 = corners[t % corners.size()]
		var to: Vector3 = goals[t % goals.size()]
		var ids := PackedInt32Array()
		for k in range(per):
			if idx >= n:
				break
			# 出发点摆成方阵（20×20），避免一开始就重叠
			# 出发点就是方阵：cols × cols，间距 1.2m，别搞花活
			var cols: int = int(ceil(sqrt(float(per))))
			var col: int = k % cols
			var row: int = k / cols
			var sx: float = clampf(from.x + (float(col) - float(cols - 1) * 0.5) * 1.2, -112.0, 112.0)
			var sz: float = clampf(from.z + (float(row) - float(cols - 1) * 0.5) * 1.2, -112.0, 112.0)
			var is_air: bool = air_ratio > 0.0 and fmod(float(idx) * 0.37, 1.0) < air_ratio
			var si: int = sim.spawn(sx, sz, t + 1, 0.36 if not is_air else 0.30, 3.3 if not is_air else 4.6)
			if si < 0:
				break
			if is_air:
				sim.state[si] = C.ST_AIR
				sim.pos_y[si] = 9.0 + float(si % 7) * 0.4
			ids.append(si)
			idx += 1
		var g: int = sim.make_group(to.x, to.z)
		sim.assign_group(g, ids, 1.15)

	print("[CROWD] 生成 %d 单位 / %d 军团 / 线程 %d" % [sim.count, team_n, sim._threads])


func _on_arrow_hit(_target: int, _dmg: float, _slot: int) -> void:
	pass


# ===========================================================================
# 主循环
# ===========================================================================

func _process(delta: float) -> void:
	if sim == null:
		return
	_elapsed += delta

	# --- 固定步长：单帧最多补 MAX_CATCHUP 个 tick ---
	_acc += delta
	var steps: int = 0
	while _acc >= C.TICK_DT and steps < C.MAX_CATCHUP:
		sim.tick()
		_acc -= C.TICK_DT
		steps += 1
	if _acc > C.TICK_DT * float(C.MAX_CATCHUP):
		_acc = 0.0   # 卡太久就丢弃，别雪崩
	var alpha: float = clampf(_acc / C.TICK_DT, 0.0, 1.0)

	render.draw_frame(sim, alpha)

	# --- GPU 箭：每 0.25s 齐射 24 支 ---
	var now: float = arrows.now()
	_arrow_t += delta
	if _arrow_t > 0.25:
		_arrow_t = 0.0
		for k in range(24):
			if sim.count < 2:
				break
			var a: int = (k * 37 + int(_elapsed * 13.0)) % sim.count
			var b: int = (k * 53 + 11 + int(_elapsed * 7.0)) % sim.count
			var from := Vector3(sim.pos_x[a], sim.pos_y[a] + 1.4, sim.pos_z[a])
			var to := Vector3(sim.pos_x[b], sim.pos_y[b] + 0.9, sim.pos_z[b])
			arrows.fire(from, to, 0.36 + float(k % 5) * 0.04, 1.8, b, 4.0)
	arrows.update(now)

	# --- 统计 ---
	var fps: float = float(Engine.get_frames_per_second())
	_frames_total += 1
	# 前 10 帧不计：着色器编译/纹理上传都挤在开头，会把 fps_min 拉到 1
	if _elapsed > 1.0 and _frames_total > 10:
		_frames += 1
		_fps_sum += fps
		if fps < _fps_min:
			_fps_min = fps
	if sim.tick_count > _tick_n:
		var d: int = sim.tick_count - _tick_n
		_tick_sum += sim.tick_ms * float(d)
		_tick_max = maxf(_tick_max, sim.tick_ms)
		_tick_n = sim.tick_count
		_steer_sum += sim.steer_ms * float(d)
		_spatial_sum += sim.spatial_ms * float(d)
		_flow_sum += sim.flow_ms * float(d)
		_draw_sum += render._write_ms * float(d)

	if hud != null:
		hud.text = "n=%d  fps=%d  tick=%.2fms  steer=%.2f  spatial=%.2f  flow=%.2f  draw=%.2f  draw_calls=%d  线程=%s" % [
			sim.count, int(fps), sim.tick_ms, sim.steer_ms, sim.spatial_ms, sim.flow_ms,
			render._write_ms, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			("on" if sim.thread_used else "off")]

	# --- 压测到点 ---
	if bench_n > 0 and not _bench_done and _elapsed >= bench_secs:
		_bench_done = true
		_report()


func _report() -> void:
	var frames: int = maxi(1, _frames)
	var ticks: int = maxi(1, _tick_n)
	var line: Dictionary = {
		"n": sim.count,
		"secs": "%.1f" % _elapsed,
		"fps_avg": "%.1f" % (_fps_sum / float(frames)),
		"fps_min": "%.0f" % _fps_min,
		"tick_ms_avg": "%.2f" % (_tick_sum / float(ticks)),
		"tick_ms_max": "%.2f" % _tick_max,
		"steer_avg": "%.2f" % (_steer_sum / float(ticks)),
		"spatial_avg": "%.2f" % (_spatial_sum / float(ticks)),
		"flow_avg": "%.2f" % (_flow_sum / float(ticks)),
		"draw_avg": "%.2f" % (_draw_sum / float(ticks)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"visible": render._visible,
		"threads": sim._threads,
		"chunks": sim._chunk_n,
		"max_bucket": sim.space.max_bucket_load,
		"arrows_flying": arrows.flying,
	}
	# --- 行为诊断：后排为什么不动？ ---
	var moving: int = 0
	var dir_ok: int = 0
	var far: int = 0
	var sum_gap: float = 0.0
	for i in range(sim.count):
		if absf(sim.dir_x[i]) + absf(sim.dir_z[i]) > 0.02:
			dir_ok += 1
		if sim.vel_x[i] * sim.vel_x[i] + sim.vel_z[i] * sim.vel_z[i] > 0.04:
			moving += 1
		var gx: float = sim.goal_x[i] + sim.slot_x[i]
		var gz: float = sim.goal_z[i] + sim.slot_z[i]
		var gap: float = sqrt((gx - sim.pos_x[i]) * (gx - sim.pos_x[i]) + (gz - sim.pos_z[i]) * (gz - sim.pos_z[i]))
		sum_gap += gap
		if gap > 5.0:
			far += 1
	print("[CROWD] 诊断: 有方向=%d 在动=%d 距目标>5m=%d 平均距离=%.1f" % [
		dir_ok, moving, far, sum_gap / float(maxi(1, sim.count))])
	for g in range(sim._groups.size()):
		var gd: Dictionary = sim._groups[g]
		var f = sim._flows[int(gd["flow"])]
		print("[CROWD]   group%d target=(%.0f,%.0f) flow_valid=%s filled=%d build_ms=%.1f" % [
			g, float(gd["target_x"]), float(gd["target_z"]), str(f.valid), f.filled, f.build_ms])
	print("[CROWD] " + JSON.stringify(line))
	# 再打一行人能直接读的
	print("[CROWD] n=%d  FPS 均值 %.1f / 最低 %.0f  |  tick %.2fms (max %.2f)  steer %.2f  spatial %.2f  flow %.2f  draw %.2f  |  draw_call %d" % [
		sim.count, _fps_sum / float(frames), _fps_min,
		_tick_sum / float(ticks), _tick_max,
		_steer_sum / float(ticks), _spatial_sum / float(ticks), _flow_sum / float(ticks),
		_draw_sum / float(ticks),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])
	if shot_path != "":
		# Vulkan 下必须等这一帧真的画完，否则 get_image() 拿到空图
		await RenderingServer.frame_post_draw
		var img: Image = get_viewport().get_texture().get_image()
		if img != null and img.get_width() > 0:
			var err: int = img.save_png(shot_path)
			print("[CROWD] 截图 %s (err=%d, %dx%d)" % [shot_path, err, img.get_width(), img.get_height()])
		else:
			print("[CROWD] 截图失败：空图")
	get_tree().quit()
