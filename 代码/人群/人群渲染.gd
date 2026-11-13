extends Node3D
## **人群渲染** —— MultiMesh + 顶点着色器动画，零节点。
##
## 三件事：
##   1. **实例缓冲一次写**：每帧把 `MultiMesh.buffer` 整块赋值（12 个变换 float + 4 个 custom），
##      不做 1000 次 `set_instance_transform()`（那是 1000 次引擎调用）。
##   2. **位置插值**：逻辑 20Hz、画面 60fps，渲染时 `prev + (cur-prev)*alpha`。
##   3. **动画在顶点着色器**：相位从 `INSTANCE_CUSTOM.x` 读，**每个单位错开**，
##      摆腿/前倾/呼吸全在 GPU 算，不吃 CPU 一帧。
##
## 已验证的 buffer 布局（Godot 4.7.2，`_qa/mm_probe.gd`）：
##   [0..2]=basis 第 0 行, [3]=origin.x, [4..6]=第 1 行, [7]=origin.y,
##   [8..10]=第 2 行, [11]=origin.z；开了 custom_data 后每实例再跟 4 个 float。
##   ⚠ headless（dummy 渲染器）下 `MultiMesh.buffer` 长度为 0，压测必须走真实渲染。

const C := preload("res://代码/人群/人群常量.gd")

const SHADER_PATH := "res://代码/人群/人群单位.gdshader"

## MultiMesh 里最多放多少个实例（= 模拟容量）
@export var capacity: int = C.MAX_UNITS
## 超过这个距离不更新变换（省 CPU；实例留在原地）
@export var cull_distance: float = 220.0
## 模型高度缩放（米 / 模型原始高）
@export var model_scale: float = 1.0
## 实例原点相对脚底的抬高量（模型中心在原点时填半身高）
@export var y_offset: float = 0.85

var multimesh: MultiMesh = null
var mmi: MultiMeshInstance3D = null
var camera: Camera3D = null

var _buf: PackedFloat32Array = PackedFloat32Array()
var _visible: int = 0
var _write_ms: float = 0.0
var _buf_ok: bool = true


func setup(mesh: Mesh, material: Material) -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = capacity
	# 全部先缩到 0，避免初始一坨堆在原点
	for i in range(capacity):
		multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
	if material != null:
		mmi = MultiMeshInstance3D.new()
		mmi.multimesh = multimesh
		mmi.material_override = material
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
	else:
		mmi = MultiMeshInstance3D.new()
		mmi.multimesh = multimesh
		add_child(mmi)
	_buf.resize(capacity * 16)
	_buf.fill(0.0)


## 每帧调。sim 只提供数据，渲染不反向写 sim。
func draw_frame(sim, alpha: float) -> void:
	if multimesh == null:
		return
	var n: int = mini(sim.count, capacity)
	# ★ 2026-11-13：只画前 n 个。不设的话 MultiMesh 会把 `instance_count`（容量 10000）
	# 全部走一遍顶点着色器 —— 缩放为 0 的实例照样跑顶点阶段。
	# 实测：VAT 网格 7336 顶点/实例，100 个兵和 1000 个兵都是 55fps，因为都在算 10000 个。
	if multimesh.visible_instance_count != n:
		multimesh.visible_instance_count = n
	var cam_pos: Vector3 = Vector3.ZERO
	var has_cam: bool = camera != null
	if has_cam:
		cam_pos = camera.global_position
	var cull2: float = cull_distance * cull_distance

	var t0: int = Time.get_ticks_usec()
	# ⚠ 不要写 `var buf = _buf` 再改 buf：Packed 数组写时复制，会每帧复制一整份缓冲。
	# 直接写成员（引用计数保持 1，零拷贝）。
	var sx: float = model_scale
	var vis: int = 0

	# 本地取别名：只读 sim 的数组，不写（写会触发 CoW）
	var px: PackedFloat32Array = sim.pos_x
	var pz: PackedFloat32Array = sim.pos_z
	var py: PackedFloat32Array = sim.pos_y
	var ppx: PackedFloat32Array = sim.prev_x
	var ppz: PackedFloat32Array = sim.prev_z
	var yaw: PackedFloat32Array = sim.yaw
	var ph: PackedFloat32Array = sim.anim_phase
	var sp: PackedFloat32Array = sim.speed
	var st: PackedInt32Array = sim.state

	var i: int = 0
	while i < n:
		var x: float = ppx[i] + (px[i] - ppx[i]) * alpha
		var z: float = ppz[i] + (pz[i] - ppz[i]) * alpha
		var o: int = i << 4
		if has_cam:
			var dx: float = x - cam_pos.x
			var dz: float = z - cam_pos.z
			if dx * dx + dz * dz > cull2:
				# 视野外：缩到 0（比留着旧变换更安全，避免"鬼影"）
				_buf[o] = 0.0; _buf[o + 1] = 0.0; _buf[o + 2] = 0.0; _buf[o + 3] = x
				_buf[o + 4] = 0.0; _buf[o + 5] = 0.0; _buf[o + 6] = 0.0; _buf[o + 7] = -50.0
				_buf[o + 8] = 0.0; _buf[o + 9] = 0.0; _buf[o + 10] = 0.0; _buf[o + 11] = z
				i += 1
				continue
			vis += 1
		var y: float = py[i] + 0.02 + y_offset
		# ★ 2026-11-13：**人群的 yaw 是 +Z 约定**（`人群模拟` 写 `atan2(vx, vz)`，
		#   yaw=0 → 朝 +Z），而所有单位模型的**正面是 -Z**（骨骼静止坐标实测：
		#   盾/武器骨的 z 全为负；引擎主线也用 `atan2(-dx,-dz)`）。
		#   两者差 180°：胶囊体看不出来，换成 VAT 真模型就是"整队背朝行进方向"。
		#   这里补 π，别改模拟层的 yaw —— 流场/转向/箭矢都按 +Z 约定算过。
		var a: float = yaw[i] + PI
		var ca: float = cos(a) * sx
		var sa: float = sin(a) * sx
		# 行主序 3×4：第 0 行 (cos, 0, sin, x)
		_buf[o] = ca
		_buf[o + 1] = 0.0
		_buf[o + 2] = sa
		_buf[o + 3] = x
		_buf[o + 4] = 0.0
		_buf[o + 5] = sx
		_buf[o + 6] = 0.0
		_buf[o + 7] = y
		_buf[o + 8] = -sa
		_buf[o + 9] = 0.0
		_buf[o + 10] = ca
		_buf[o + 11] = z
		# custom: 相位 / 移动强度 / 状态 / 队伍
		var moving: float = clampf(sqrt(sim.vel_x[i] * sim.vel_x[i] + sim.vel_z[i] * sim.vel_z[i]) / maxf(sp[i], 0.01), 0.0, 1.4)
		_buf[o + 12] = ph[i]
		_buf[o + 13] = moving
		_buf[o + 14] = float(st[i])
		_buf[o + 15] = float(sim.team[i])
		i += 1

	_visible = vis if has_cam else n
	if _buf_ok:
		multimesh.buffer = _buf
	_write_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func stats() -> Dictionary:
	return {"visible": _visible, "write_ms": "%.2f" % _write_ms, "buffer_ok": _buf_ok}
