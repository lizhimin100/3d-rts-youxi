extends Node3D
## **GPU 箭矢** —— 模拟里没有"箭"这个对象，只有一条"何时落地"的排队记录。
##
## 一次射击在 CPU 侧只占 3 个数：`from / to / 命中时刻`（外加弧高）。
## 抛物线、朝向、飞行姿态全部由顶点着色器按 `now` 现算，CPU 每帧只更新一个 uniform。
## 命中结算走**时间队列**（不是碰撞检测）——到点才读目标当前状态，所以中途目标死了
## 也能正确哑火。
##
## 为什么不做碰撞：RTS 的箭是"确定性命中"，箭飞 0.4 秒的落点早就定了。
## 做碰撞检测既贵又会因为目标移动产生"追不上"的观感问题。

const C := preload("res://Views/world/crowd/人群常量.gd")
const SHADER := preload("res://Views/world/crowd/人群箭矢.gdshader")

## 同时在飞的箭上限
const MAX_ARROWS: int = 1024

var multimesh: MultiMesh = null
var mmi: MultiMeshInstance3D = null
var material: ShaderMaterial = null

## SoA：起点 / 终点 / 时间 / 弧高 / 存活
var _sx: PackedFloat32Array = PackedFloat32Array()
var _sy: PackedFloat32Array = PackedFloat32Array()
var _sz: PackedFloat32Array = PackedFloat32Array()
var _ex: PackedFloat32Array = PackedFloat32Array()
var _ey: PackedFloat32Array = PackedFloat32Array()
var _ez: PackedFloat32Array = PackedFloat32Array()
var _t0: PackedFloat32Array = PackedFloat32Array()
var _dur: PackedFloat32Array = PackedFloat32Array()
var _arc: PackedFloat32Array = PackedFloat32Array()
var _live: PackedByteArray = PackedByteArray()
var _slot_n: int = 0

## 命中队列：{t: float, target: int, dmg: float}
var _hits: Array = []
## 命中回调（演示层注入）
var on_hit: Callable = Callable()

## 诊断
var flying: int = 0
var write_ms: float = 0.0


func setup() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.06, 0.06, 1.0)
	multimesh.mesh = mesh
	multimesh.instance_count = MAX_ARROWS

	material = ShaderMaterial.new()
	material.shader = SHADER
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = multimesh
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

	_sx.resize(MAX_ARROWS); _sy.resize(MAX_ARROWS); _sz.resize(MAX_ARROWS)
	_ex.resize(MAX_ARROWS); _ey.resize(MAX_ARROWS); _ez.resize(MAX_ARROWS)
	_t0.resize(MAX_ARROWS); _dur.resize(MAX_ARROWS); _arc.resize(MAX_ARROWS)
	_live.resize(MAX_ARROWS)
	_live.fill(0)
	for i in range(MAX_ARROWS):
		multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))


## 发射一支箭。CPU 侧只记 4 个量，画由 GPU 负责。
## target 只用于命中结算（可为 -1 表示"地格"）。
func fire(from: Vector3, to: Vector3, dur: float = 0.42, arc: float = 1.6, target: int = -1, dmg: float = 8.0) -> int:
	var s: int = _alloc_slot()
	if s < 0:
		return -1
	_sx[s] = from.x; _sy[s] = from.y; _sz[s] = from.z
	_ex[s] = to.x; _ey[s] = to.y; _ez[s] = to.z
	_t0[s] = now()
	_dur[s] = maxf(0.08, dur)
	_arc[s] = arc
	_live[s] = 1
	_write_instance(s)
	_hits.append({"t": _t0[s] + _dur[s], "slot": s, "target": target, "dmg": dmg})
	return s


## 命中队列：到点结算（读的是**落点时刻**的目标状态，不是出手时的）。
func tick_hits(t: float) -> void:
	if _hits.is_empty():
		return
	var keep: Array = []
	for h in _hits:
		var rec: Dictionary = h
		if float(rec["t"]) > t:
			keep.append(rec)
			continue
		var slot: int = int(rec["slot"])
		_live[slot] = 0
		_write_instance(slot)
		if on_hit.is_valid():
			on_hit.call(int(rec["target"]), float(rec["dmg"]), slot)
	_hits = keep


func update(t: float) -> void:
	if material == null:
		return
	var t0i: int = Time.get_ticks_usec()
	material.set_shader_parameter("now", t)
	var n: int = 0
	for i in range(MAX_ARROWS):
		if _live[i] != 0:
			n += 1
	flying = n
	write_ms = float(Time.get_ticks_usec() - t0i) / 1000.0
	tick_hits(t)


func now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


## 把一个槽位的起点/终点/时间写进 MultiMesh。
## 布局：origin = 起点；basis.x = (终点 - 起点)；custom = (t0, dur, arc, 1)
func _write_instance(s: int) -> void:
	if multimesh == null:
		return
	if _live[s] == 0:
		multimesh.set_instance_transform(s, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
		multimesh.set_instance_custom_data(s, Color(0, 0, 0, 0))
		return
	var start := Vector3(_sx[s], _sy[s], _sz[s])
	var end := Vector3(_ex[s], _ey[s], _ez[s])
	var d: Vector3 = end - start
	var b := Basis(Vector3(d.x, d.y, d.z), Vector3(0, 1, 0), Vector3(0, 0, 1))
	multimesh.set_instance_transform(s, Transform3D(b, start))
	multimesh.set_instance_custom_data(s, Color(_t0[s], _dur[s], _arc[s], 1.0))


func _alloc_slot() -> int:
	for k in range(MAX_ARROWS):
		var s: int = (_slot_n + k) % MAX_ARROWS   # 冷路径，允许一次取模
		if _live[s] == 0:
			_slot_n = (s + 1) % MAX_ARROWS
			return s
	return -1


func stats() -> Dictionary:
	return {"flying": flying, "queued": _hits.size(), "write_ms": "%.2f" % write_ms}
