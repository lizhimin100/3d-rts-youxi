class_name RtsProjectile
extends Node3D
## **投射物**：箭矢 / 火球。
##
## 关键设计：**真抛物线**，不是直线插值。
##   给定水平速度 v 与飞行时长 T，解出竖直初速 vy = (Δy + ½gT²)/T，
##   保证 t=T 时精确落在目标高度，同时路径是一条有重力感的弧线。
##   弓箭 g 大弧线低平；火球 g 小更飘、更像炮弹。
##
## 伤害在**落点**结算（不是出手瞬间），所以射空中目标会看到箭插进去才掉血。
## 飞行途中目标会小幅度被追踪（否则移动目标必空，手感会很差）。

## 箭的等效重力（越大弧线越"坠"）
const GRAVITY_ARROW: float = 14.0
## 火球的重力（更飘）
const GRAVITY_FIREBOLT: float = 9.0
## 飞行时长下限（极近距离时防止 vy 爆炸）
const MIN_FLIGHT_TIME: float = 0.08
## 命中点相对目标脚底的高度（打胸口，不打脚）
const AIM_HEIGHT: float = 0.9
## 火球命中震屏强度
const SHAKE_FIREBOLT: float = 0.16


var kind: int = RtsConst.Projectile.ARROW
var speed: float = 20.0

var _from: Vector3 = Vector3.ZERO
var _to: Vector3 = Vector3.ZERO
var _vy: float = 0.0
var _gravity: float = GRAVITY_ARROW
var _dur: float = 0.5
var _t: float = 0.0
var _landed: bool = false

## 施法者（可能飞行途中就死了，用 _snap 兜底）
var _attacker: Node3D = null
var _snap: Dictionary = {}
var _target: Node3D = null
var _faction: RtsFaction = null

## AOE 参数（0 = 单体）
var _aoe_radius: float = 0.0
var _aoe_damage: float = 0.0
var _aoe_type: int = RtsConst.DamageType.MAGIC
var _slow_ratio: float = 1.0
var _slow_time: float = 0.0

## 箭矢朝向用的上一帧位置
var _prev_pos: Vector3 = Vector3.ZERO
var _mesh_node: Node3D = null


# ===========================================================================
# 发射
# ===========================================================================

## 发射一枚投射物。
## to: 目标点（世界坐标）；target: 追踪目标（可空）。
## aoe_radius > 0 时按落点群体结算，否则单体结算。
static func fire(attacker: Node3D, p_kind: int, from_pos: Vector3, to_pos: Vector3,
		target: Node3D, p_speed: float, snap: Dictionary, faction: RtsFaction,
		aoe_radius: float = 0.0, aoe_damage: float = 0.0,
		slow_ratio: float = 1.0, slow_time: float = 0.0) -> void:
	var parent: Node3D = RtsWorld.level()
	if parent == null:
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null or tree.current_scene == null:
			return
		parent = tree.current_scene
	if parent == null:
		return

	var p := RtsProjectile.new()
	p.kind = p_kind
	p.speed = maxf(p_speed, 1.0)
	p._from = from_pos
	p._to = to_pos
	p._target = target
	p._attacker = attacker
	p._snap = snap
	p._faction = faction
	p._aoe_radius = aoe_radius
	p._aoe_damage = aoe_damage
	p._slow_ratio = slow_ratio
	p._slow_time = slow_time
	p.name = "投射物_%s" % ("箭" if p_kind == RtsConst.Projectile.ARROW else "火球")
	parent.add_child(p)
	p._solve_arc()
	p._build_mesh()


## 从攻击者胸口/法杖位置发射（最常用入口）
static func fire_from(attacker: Node3D, p_kind: int, to_pos: Vector3, target: Node3D,
		p_speed: float, snap: Dictionary, faction: RtsFaction,
		aoe_radius: float = 0.0, aoe_damage: float = 0.0,
		slow_ratio: float = 1.0, slow_time: float = 0.0) -> void:
	var from_pos: Vector3 = Vector3.ZERO
	if attacker != null and is_instance_valid(attacker):
		from_pos = attacker.global_position + Vector3.UP * AIM_HEIGHT
	fire(attacker, p_kind, from_pos, to_pos, target, p_speed, snap, faction,
		aoe_radius, aoe_damage, slow_ratio, slow_time)


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	_prev_pos = global_position


func _process(delta: float) -> void:
	if _landed:
		return
	if _dur <= 0.0:
		_land()
		return

	# 目标还活着就持续追踪（否则打移动目标必空，手感很差）
	if _target != null and is_instance_valid(_target):
		if not (_target.has_method("is_alive") and not bool(_target.call("is_alive"))):
			_to = _target.global_position + Vector3.UP * AIM_HEIGHT

	_t += delta
	var k: float = clampf(_t / _dur, 0.0, 1.0)
	var x: float = lerpf(_from.x, _to.x, k)
	var z: float = lerpf(_from.z, _to.z, k)
	# 真正的抛物线：匀速水平 + 匀加速竖直
	var y: float = _from.y + _vy * _t - 0.5 * _gravity * _t * _t

	_prev_pos = global_position
	global_position = Vector3(x, y, z)

	_orient()

	if k >= 1.0:
		_land()


# ===========================================================================
# 内部：弹道
# ===========================================================================

## 解抛物线：站在 _to 上解 vy，保证 t=_dur 时正好落到目标高度
func _solve_arc() -> void:
	_gravity = GRAVITY_ARROW if kind == RtsConst.Projectile.ARROW else GRAVITY_FIREBOLT
	var horiz: float = Vector2(_to.x - _from.x, _to.z - _from.z).length()
	_dur = maxf(horiz / speed, MIN_FLIGHT_TIME)
	_vy = ((_to.y - _from.y) + 0.5 * _gravity * _dur * _dur) / _dur
	_t = 0.0
	global_position = _from
	_prev_pos = _from


## 箭头沿速度方向摆正（模型长轴朝 -Z，正好对上 look_at 约定）
func _orient() -> void:
	if _mesh_node == null or kind != RtsConst.Projectile.ARROW:
		return
	var vel: Vector3 = global_position - _prev_pos
	if vel.length_squared() < 0.000001:
		return
	# ★ 这里以前写的是 `if global_position.distance_squared_to(_prev_pos + vel) > 0.0001`
	#   而 _prev_pos + vel 恒等于当前位置 → 判据永远为假 → look_at 从来没执行过，
	#   箭一直是"世界坐标默认朝向"横着飞（玩家口径「箭几乎都是歪的」）。直接对齐即可。
	var dir: Vector3 = vel.normalized()
	# 近乎垂直的箭用 UP 当上方向会退化（基向量共线 → 画面抽帧），换个参考轴
	var up: Vector3 = Vector3.UP
	if absf(dir.dot(Vector3.UP)) > 0.995:
		up = Vector3.FORWARD
	look_at(global_position + dir, up)


# ===========================================================================
# 内部：外观
# ===========================================================================

func _build_mesh() -> void:
	if kind == RtsConst.Projectile.ARROW:
		_build_arrow()
	else:
		_build_firebolt()


## 箭：细长廊形盒（代码造，不依赖美术资源）
func _build_arrow() -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.045, 0.045, 0.85)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.24, 0.14)
	mat.roughness = 0.7
	mat.metallic = 0.15
	mi.material_override = mat
	add_child(mi)
	_mesh_node = mi

	# 箭头（小锥体）与尾羽（薄片），让它一眼是"箭"不是"棍"
	var tip := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.055
	cone.height = 0.16
	cone.radial_segments = 5
	tip.mesh = cone
	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = Color(0.72, 0.72, 0.76)
	tip_mat.metallic = 0.85
	tip_mat.roughness = 0.3
	tip.material_override = tip_mat
	tip.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	tip.position = Vector3(0.0, 0.0, -0.46)
	add_child(tip)

	var tail := MeshInstance3D.new()
	var fletch := BoxMesh.new()
	fletch.size = Vector3(0.16, 0.012, 0.2)
	tail.mesh = fletch
	var tail_mat := StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.86, 0.82, 0.72)
	tail_mat.roughness = 0.9
	tail.material_override = tail_mat
	tail.position = Vector3(0.0, 0.0, 0.34)
	add_child(tail)


## 火球：自发光球 + 拖尾粒子
func _build_firebolt() -> void:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	sphere.radial_segments = 12
	sphere.rings = 6
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.55, 0.16)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.52, 0.12)
	mat.emission_energy_multiplier = 3.2
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)
	_mesh_node = mi

	# 拖尾：CPU 粒子（无头模式下也不会报错，比 shader 粒子稳）
	var trail := CPUParticles3D.new()
	trail.amount = 20
	trail.lifetime = 0.34
	trail.local_coords = false
	trail.emitting = true
	trail.gravity = Vector3.ZERO
	trail.initial_velocity_min = 0.0
	trail.initial_velocity_max = 0.3
	trail.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	trail.emission_sphere_radius = 0.14
	trail.scale_amount_min = 0.35
	trail.scale_amount_max = 0.85
	trail.color = Color(1.0, 0.5, 0.12, 0.85)
	var pmesh := SphereMesh.new()
	pmesh.radius = 0.1
	pmesh.height = 0.2
	pmesh.radial_segments = 6
	pmesh.rings = 3
	trail.mesh = pmesh
	add_child(trail)


# ===========================================================================
# 内部：落点结算
# ===========================================================================

func _land() -> void:
	if _landed:
		return
	_landed = true

	var pos: Vector3 = global_position

	# --- 1. 伤害 ---
	if _aoe_radius > 0.0:
		_resolve_aoe(pos)
	else:
		_resolve_single()

	# --- 2. 反馈 ---
	Game.projectile_impact.emit(pos, kind)
	if kind == RtsConst.Projectile.ARROW:
		ArtKit.vfx_hit(pos, Color(1.0, 0.92, 0.62))
	else:
		ArtKit.vfx_magic(pos, maxf(_aoe_radius, 0.6), Color(1.0, 0.55, 0.18))
		if RtsCombat.is_near_camera(pos):
			Game.shake(SHAKE_FIREBOLT * (2.2 if _aoe_radius > 0.0 else 1.0))

	queue_free()


## 单体结算
func _resolve_single() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	if _target.has_method("is_alive") and not bool(_target.call("is_alive")):
		return
	RtsCombat.resolve_from_snapshot(_snap, _target, _attacker)


## AOE 结算（技能火球）
func _resolve_aoe(pos: Vector3) -> void:
	if _faction == null:
		return
	RtsCombat.deal_aoe(_attacker, pos, _aoe_radius, _aoe_damage, _aoe_type, _faction)
	if _slow_time <= 0.0:
		return
	# 顺带减速：只对敌方**单位**生效（建筑没有移速概念）。
	# 多队图：对所有敌对阵营，**盟友不能被自己的火球减速**。
	var r2: float = _aoe_radius * _aoe_radius
	for foe in Game.enemies_of(_faction):
		for u in foe.units:
			if u == null or not is_instance_valid(u):
				continue
			if not u.is_alive():
				continue
			if u.global_position.distance_squared_to(pos) > r2:
				continue
			if u.has_method("apply_slow"):
				u.call("apply_slow", _slow_ratio, _slow_time)
