extends MeshInstance3D
## **贴地选中圈**（魔兽 3 手感）—— 把 2×2 的方形面片切成网格，逐顶点采样地形高度。
##
## 为什么要重做（玩家 2026-11-06 口径「像贴图，一点透视和遮挡都没有」）：
##   旧实现是一张**水平方片**贴图：单位站在斜坡上时整片悬空/切进土里，山坡挡在前面
##   也照样画在屏幕上（shader 里 `depth_test_disabled`）—— 看起来就是贴了一张纸。
##
## 现在：
##   1. 顶点高度 = `RtsWorld.height_at(世界 x, z)`，所以圈跟着坡面起伏，是"投在地上"的；
##   2. 开启深度测试（shader 去掉 depth_test_disabled），山体/建筑能挡住它；
##   3. `top_level = true`：不吃单位的倾斜旋转（单位上坡会 pitch，圈跟着歪就很难看）；
##   4. 选中瞬间从 1.35 倍收到 1.0 倍 + 淡入 0.16s（魔兽那种"圈一下收上来"）；
##   5. 单位走动超过 0.35m 才重建网格（不是每帧），静止时零开销。
##
## 网格 UV 仍然按 0..1 铺满 2×2 面片，所以 `选中圈.gdshader` 的 UV 数学一个字不用改。

## 环的**外缘**半径（米）。shader 里 ring_radius=0.8 → 网格半宽 = radius / 0.8
const RING_UV_RADIUS: float = 0.8
## 贴地抬升（米）：0.05 能压住地表层（地表偏移 0.22 是另一种网格，不冲突）
const LIFT: float = 0.05
## 重建阈值（米）：走这么远才重算顶点高度
const REBUILD_STEP: float = 0.35
## 收束动画时长（秒）
const SPAWN_TIME: float = 0.16

var target: Node3D = null
var ring_radius: float = 1.0
var team_color: Color = Color(0.32, 1.0, 0.52)
var segments: int = 16

var _last_pos: Vector3 = Vector3(1e9, 0.0, 0.0)
var _spawn: float = 0.0
var _mat: ShaderMaterial = null
## 复用同一张 ImmediateMesh：每帧新建网格会造成 GC 抖动（12 个选中单位 × 10 次/秒）
var _im: ImmediateMesh = null


## 建圈：先入树再 setup（setup 里要读 global_position，未入树会被引擎忽略）。
static func attach(p_parent: Node3D, p_target: Node3D, p_radius: float, p_color: Color) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = "选中圈"
	n.set_script(load("res://代码/美术/选中圈贴地.gd"))
	p_parent.add_child(n)
	n.call("setup", p_target, p_radius, p_color)
	return n


func setup(p_target: Node3D, p_radius: float, p_color: Color) -> void:
	target = p_target
	ring_radius = maxf(0.35, p_radius)
	team_color = p_color
	# 半径越大网格越密：大本营 5.5m 的圈用 12 段会贴着地形切出棱角
	segments = clampi(int(round(ring_radius * 7.0)), 12, 40)
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mat = _make_material()
	material_override = _mat
	_sync_position()
	_rebuild()
	_spawn = 0.0
	scale = Vector3(1.35, 1.0, 1.35)
	transparency = 1.0


func _make_material() -> ShaderMaterial:
	var sh := load("res://美术/着色器/选中圈.gdshader") as Shader
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("team_color", team_color)
	m.set_shader_parameter("ring_radius", RING_UV_RADIUS)
	# 线宽按**世界米**换算成 UV：半宽 = radius/0.8 → 0.055m 对应 0.055*0.8/radius
	m.set_shader_parameter("ring_width", clampf(0.032 * RING_UV_RADIUS / ring_radius, 0.006, 0.045))
	m.set_shader_parameter("halo", 0.16)
	m.set_shader_parameter("inner_ring", 0.0)
	m.set_shader_parameter("pulse_speed", 1.1)
	m.set_shader_parameter("pulse_amount", 0.06)
	m.set_shader_parameter("dash_count", 0.0)
	m.set_shader_parameter("dash_strength", 0.0)
	m.set_shader_parameter("opacity", 0.86)
	m.set_shader_parameter("spin_speed", 0.0)
	m.render_priority = 3
	return m


func _process(dt: float) -> void:
	if target == null or not is_instance_valid(target):
		queue_free()
		return
	if _spawn < SPAWN_TIME:
		_spawn = minf(_spawn + dt, SPAWN_TIME)
		var k: float = _spawn / SPAWN_TIME
		# ease-out：先快后慢，收束感更明显
		var e: float = 1.0 - pow(1.0 - k, 3.0)
		var s: float = lerpf(1.35, 1.0, e)
		scale = Vector3(s, 1.0, s)
		transparency = 1.0 - e
	_sync_position()
	# 目标走远了才重建（静止/小碎步零开销）
	if Vector2(global_position.x - _last_pos.x, global_position.z - _last_pos.z).length() > REBUILD_STEP:
		_rebuild()


func _sync_position() -> void:
	if target == null or not is_instance_valid(target):
		return
	var p: Vector3 = target.global_position
	global_position = Vector3(p.x, 0.0, p.z)


func _rebuild() -> void:
	if target == null or not is_instance_valid(target):
		return
	var p: Vector3 = target.global_position
	_last_pos = Vector3(p.x, 0.0, p.z)
	var half: float = ring_radius / RING_UV_RADIUS
	var n: int = segments
	var step: float = (half * 2.0) / float(n)
	if _im == null:
		_im = ImmediateMesh.new()
		mesh = _im
	_im.clear_surfaces()
	var im := _im
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in range(n):
		for ix in range(n):
			var x0: float = -half + step * float(ix)
			var z0: float = -half + step * float(iz)
			var x1: float = x0 + step
			var z1: float = z0 + step
			var u0: float = float(ix) / float(n)
			var u1: float = float(ix + 1) / float(n)
			var v0: float = float(iz) / float(n)
			var v1: float = float(iz + 1) / float(n)
			# 两个三角形；顶点 y = 世界地形高度 − 本节点 y(0) + 抬升
			var a: Vector3 = Vector3(x0, _ground_y(p.x + x0, p.z + z0), z0)
			var b: Vector3 = Vector3(x1, _ground_y(p.x + x1, p.z + z0), z0)
			var c: Vector3 = Vector3(x0, _ground_y(p.x + x0, p.z + z1), z1)
			var d: Vector3 = Vector3(x1, _ground_y(p.x + x1, p.z + z1), z1)
			_add_v(im, a, u0, v0)
			_add_v(im, b, u1, v0)
			_add_v(im, c, u0, v1)
			_add_v(im, b, u1, v0)
			_add_v(im, d, u1, v1)
			_add_v(im, c, u0, v1)
	im.surface_end()


func _ground_y(wx: float, wz: float) -> float:
	return RtsWorld.height_at(wx, wz) + LIFT


func _add_v(im: ImmediateMesh, v: Vector3, u: float, vv: float) -> void:
	im.surface_set_uv(Vector2(u, vv))
	im.surface_add_vertex(v)
