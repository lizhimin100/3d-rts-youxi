class_name Vfx
extends RefCounted
## 运行时特效生成（ANVIL 提供）—— 命中火花 / 死亡碎裂 / 魔法爆裂 / 建造尘土 / 选中圈。
##
## 契约（玩法侧只认这五个静态方法）：
##   Vfx.hit_spark(pos, color)
##   Vfx.death_burst(pos, color)
##   Vfx.magic_blast(pos, color, radius)     ← 注意参数顺序是 (位置, 颜色, 半径)
##   Vfx.build_dust(pos)
##   Vfx.selection_ring(parent, radius, color) -> Node3D
##
## 设计要点：
## 1. **优先用 `美术/特效/*.tscn`**（美术调好的参数），
##    找不到场景就**现场用代码造粒子**——绝不让调用方拿到 null、绝不报错中断逻辑。
## 2. **用完自动 queue_free**：挂一个 one_shot Timer，不依赖调用方管生命周期。
## 3. 颜色/半径在实例化后按参数改写（同一份特效可复用于不同阵营/技能）。
## 4. 选中圈返回节点给调用方自己管（`SelectionSystem` 要跟着单位走）。

const 路径_命中火花: String = "res://美术/特效/命中火花.tscn"
const 路径_死亡碎裂: String = "res://美术/特效/死亡碎裂.tscn"
const 路径_魔法爆裂: String = "res://美术/特效/魔法爆裂.tscn"
const 路径_建造尘土: String = "res://美术/特效/建造尘土.tscn"
const 路径_选中圈: String = "res://美术/特效/选中圈.tscn"

## 特效存活上限（秒）——比粒子 lifetime 略长，留出淡出余量
const 火花存活: float = 1.1
const 碎裂存活: float = 1.9
const 爆裂存活: float = 1.4
const 尘土存活: float = 2.0

## 场景缓存（避免每次都 load）
static var _缓存: Dictionary = {}
static var 调试日志: bool = false


## 命中火花：短促喷射，加色，0.45 秒。
static func hit_spark(pos: Vector3, color: Color = Color(1.0, 0.78, 0.34)) -> void:
	var n := _生成(路径_命中火花, pos, _回退粒子(18, 0.42, 4.2, color, true), 火花存活)
	if n != null:
		_上色(n, color)


## 死亡碎裂：碎片迸发 + 烟尘上浮。
static func death_burst(pos: Vector3, color: Color = Color(0.62, 0.42, 0.24)) -> void:
	var n := _生成(路径_死亡碎裂, pos, _回退粒子(22, 0.8, 3.6, color, true), 碎裂存活)
	if n != null:
		_上色(n, color)


## 魔法爆裂：核心膨胀 + 冲击环，半径影响整体尺寸与粒子速度。
static func magic_blast(pos: Vector3, color: Color = Color(0.55, 0.86, 1.0),
		radius: float = 2.0) -> void:
	var r: float = maxf(0.4, radius)
	var n := _生成(路径_魔法爆裂, pos, _回退粒子(30, 0.55, 3.0, color, true), 爆裂存活)
	if n == null:
		return
	_上色(n, color)
	# 半径 → 缩放（0.5 是"标准半径"的基准）
	var s: float = r / 2.0
	s = clampf(s, 0.35, 3.5)
	n.scale = Vector3(s, s, s)
	# 冲击环单独放大一点，读起来更像"环在扩散"
	for c in n.get_children():
		if c is GPUParticles3D and String(c.name).contains("环"):
			(c as GPUParticles3D).scale = Vector3.ONE * 1.25


## 建造尘土：贴地的环状尘土，缓慢上浮。
static func build_dust(pos: Vector3) -> void:
	var n := _生成(路径_建造尘土, pos, _回退粒子(20, 1.3, 1.2,
		Color(0.58, 0.50, 0.38), false), 尘土存活)
	if n == null:
		return
	# 尘土不要发光：把加色材质的亮度压下来
	for mi in _收集网格(n):
		for i in maxi(1, mi.mesh.get_surface_count() if mi.mesh != null else 1):
			var m: Material = mi.get_active_material(i)
			if m is ShaderMaterial:
				var sm := m as ShaderMaterial
				if sm.get_shader_parameter("power") != null:
					sm.set_shader_parameter("power", 0.55)


## 选中圈：挂在 parent 下、贴地、由 shader 的 TIME 做脉冲呼吸。
## 返回创建出来的节点（调用方负责 queue_free），失败也返回一个空 Node3D，绝不 null。
static func selection_ring(parent: Node3D, radius: float = 1.0,
		color: Color = Color(0.32, 1.0, 0.52)) -> Node3D:
	var 空节点 := Node3D.new()
	空节点.name = "选中圈"
	if parent == null:
		return 空节点
	var ps: PackedScene = _取场景(路径_选中圈)
	if ps == null:
		# 回退：用一个扁平的柱面当"圈"，至少能看见
		var mi := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = maxf(0.05, radius * 0.86)
		tm.outer_radius = maxf(0.08, radius)
		tm.rings = 32
		tm.ring_segments = 4
		var sm := StandardMaterial3D.new()
		sm.albedo_color = color
		sm.emission_enabled = true
		sm.emission = color
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		tm.material = sm
		mi.mesh = tm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		空节点.add_child(mi)
		parent.add_child(空节点)
		空节点.position.y = 0.02
		return 空节点

	var inst := ps.instantiate() as Node3D
	if inst == null:
		return 空节点
	# 面片是 2×2，环半径在 UV 里是 0.8 → 世界半径 = 0.8 × (scale.x×2/2)
	var s: float = maxf(0.05, radius) / 0.8
	inst.scale = Vector3(s, 1.0, s)
	inst.name = "选中圈"
	# 改队伍色
	for mi in _收集网格(inst):
		var 层数: int = maxi(1, mi.mesh.get_surface_count() if mi.mesh != null else 1)
		for i in 层数:
			var m: Material = mi.get_active_material(i)
			if m is ShaderMaterial:
				var smat := m as ShaderMaterial
				if smat.get_shader_parameter("team_color") != null:
					var 副本 := smat.duplicate() as ShaderMaterial
					副本.set_shader_parameter("team_color", color)
					mi.set_surface_override_material(i, 副本)
	parent.add_child(inst)
	inst.position.y = 0.02
	return inst


# ---------------------------------------------------------------- 内部
static func _树() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


static func _容器() -> Node:
	var t := _树()
	if t == null:
		return null
	if t.current_scene != null:
		return t.current_scene
	return t.root


static func _取场景(path: String) -> PackedScene:
	if _缓存.has(path):
		return _缓存[path]
	var ps: PackedScene = null
	if ResourceLoader.exists(path):
		ps = load(path) as PackedScene
	_缓存[path] = ps
	return ps


## 生成一个特效节点并挂进当前场景；成功后挂自动回收计时器。
static func _生成(path: String, pos: Vector3, 回退: Node3D, 存活: float) -> Node3D:
	var 容器 := _容器()
	if 容器 == null:
		if 回退 != null:
			回退.queue_free()
		return null
	var n: Node3D = null
	var ps := _取场景(path)
	if ps != null:
		n = ps.instantiate() as Node3D
	if n == null:
		if 调试日志:
			print("[特效生成] 缺场景，用代码回退：", path)
		n = 回退
	elif 回退 != null:
		回退.queue_free()
	if n == null:
		return null
	容器.add_child(n)
	# 注意：某些容器（如 --script 下的 Window 根）此刻 is_inside_tree() 仍为 false，
	# 直接写 global_position 会刷 "!is_inside_tree()" 错误日志，所以先判一次。
	if n.is_inside_tree():
		n.global_position = pos
	else:
		n.position = pos
	# 单次粒子必须显式触发（instantiate 后 emitting 可能已被 last frame 关掉）
	for c in n.get_children():
		if c is GPUParticles3D:
			var g := c as GPUParticles3D
			g.emitting = true
			g.restart()
	# 自动回收
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 存活
	tm.autostart = true
	n.add_child(tm)
	tm.timeout.connect(n.queue_free)
	return n


## 代码回退：一套最简的加色粒子（不依赖任何美术资源）。
static func _回退粒子(数量: int, 寿命: float, 速度: float, color: Color,
		一次: bool) -> Node3D:
	var 根 := Node3D.new()
	根.name = "特效回退"
	var g := GPUParticles3D.new()
	g.amount = 数量
	g.lifetime = 寿命
	g.one_shot = 一次
	g.explosiveness = 0.9
	g.emitting = true
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.10
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 70.0
	pm.initial_velocity_min = 速度 * 0.4
	pm.initial_velocity_max = 速度
	pm.gravity = Vector3(0, -9.0, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	pm.color = color
	g.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.10, 0.10)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.albedo_color = color
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.material = sm
	g.draw_pass_1 = qm
	根.add_child(g)
	return 根


## 递归改色：粒子材质改 color，着色器材质改 color uniform。
static func _上色(root: Node, color: Color) -> void:
	if root == null:
		return
	for c in root.get_children():
		if c is GPUParticles3D:
			var g := c as GPUParticles3D
			if g.process_material is ParticleProcessMaterial:
				(g.process_material as ParticleProcessMaterial).color = color
		_上色(c, color)
	for mi in _收集网格(root):
		var 层数: int = maxi(1, mi.mesh.get_surface_count() if mi.mesh != null else 1)
		for i in 层数:
			var m: Material = mi.get_active_material(i)
			if m is ShaderMaterial:
				var smat := m as ShaderMaterial
				if smat.get_shader_parameter("color") != null:
					var 副本 := smat.duplicate() as ShaderMaterial
					副本.set_shader_parameter("color", color)
					mi.set_surface_override_material(i, 副本)


static func _收集网格(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var 栈: Array[Node] = [root]
	while not 栈.is_empty():
		var n: Node = 栈.pop_back()
		if n is MeshInstance3D:
			out.append(n as MeshInstance3D)
		for c in n.get_children():
			栈.append(c)
	return out
