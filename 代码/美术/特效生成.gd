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
##   Vfx.blood_spray(pos, dir, amount)          ← 受击出血（血滴 + 血渍）
##   Vfx.blood_splat(pos, radius)               ← 单独一片血渍（池化）
##   Vfx.selection_burst(pos, radius, color)    ← 刚选中那一下的收束环
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


# ===========================================================================
# 受击出血
# ===========================================================================
## 血的本色。为什么要这么暗：血走的是 ALPHA 混合而不是加色 —— 加色会把暗红叠成
## 橙白一片（加法只会变亮），红就"糊屏"了。ALPHA 混合才能读出深红的重量感。
const 血色: Color = Color(0.42, 0.06, 0.06)
## 血花预算：0.25s 窗口内最多 6 次。混战里同帧几十个单位挨打，不闸就糊成红幕。
const 血花窗口: float = 0.25
const 血花上限: int = 6
## 血渍预算：0.5s 窗口内最多 2 片。血渍是"留下"的东西，比血花更该克制。
const 血渍窗口: float = 0.5
const 血渍上限: int = 2
## 血渍池容量：固定 24 片，满了顶掉最老的一片（节点数恒定，不随战斗时长涨）
const 血渍池容量: int = 24
## 血渍停留 + 淡出（秒）
const 血渍停留: float = 4.0
const 血渍淡出: float = 1.6

static var _血花时刻: Array = []
static var _血渍时刻: Array = []
## 血渍槽位：[{node, busy, stamp, tween}]，首次用到才 new，之后一辈子复用
static var _血渍槽: Array = []
static var _血滴材质: StandardMaterial3D = null
static var _血渍材质: StandardMaterial3D = null
## 选中爆发同帧上限（框选 60 人时不至于叠出 60 层半透明片）
const 选中爆发同帧上限: int = 8
static var _选中爆发帧: int = -1
static var _选中爆发数: int = 0


## 受击血花：短促的血滴喷射 + 落点一片血渍。dir = 从攻击者指向目标的水平方向。
## 为什么粒子不用贴图：项目的资产导入是硬约束（不新增 .png），所以用 QuadMesh +
## StandardMaterial3D 当粒子网格，颜色直接吃 albedo，效果一样是"小血点"。
static func blood_spray(pos: Vector3, dir: Vector3 = Vector3.ZERO,
		amount: float = 1.0) -> void:
	if not _血花预算():
		return
	var 容器 := _容器()
	if 容器 == null:
		return
	var 根 := Node3D.new()
	根.name = "血花"
	var g := GPUParticles3D.new()
	g.amount = clampi(int(4.0 + amount * 3.0), 4, 18)
	# lifetime 每次随机：同一帧多个单位挨打时，血滴不会整齐划一地同时消失
	g.lifetime = randf_range(0.35, 0.5)
	g.one_shot = true
	g.explosiveness = 1.0
	g.emitting = true
	g.draw_pass_1 = _血滴网格()

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.12
	# 顺刀口斜向上喷：纯水平会看着像"漏气"，纯竖直又读不出"从哪边打来的"
	var 方向 := Vector3(dir.x, 0.0, dir.z)
	if 方向.length_squared() < 0.0001:
		pm.direction = Vector3(0.0, 1.0, 0.0)
	else:
		pm.direction = 方向.normalized() + Vector3(0.0, 0.55, 0.0)
	pm.spread = 35.0
	pm.initial_velocity_min = 2.2
	pm.initial_velocity_max = 3.6
	pm.gravity = Vector3(0.0, -9.5, 0.0)
	pm.scale_min = 0.6
	pm.scale_max = 1.3
	pm.color = Color.WHITE
	# 尺寸随寿命收到 0.15：血滴是"缩没"而不是"啪一下消失"，ALPHA 混合下硬消失很扎眼
	var cv := Curve.new()
	cv.add_point(Vector2(0.0, 1.0))
	cv.add_point(Vector2(0.35, 1.0))
	cv.add_point(Vector2(1.0, 0.15))
	var ct := CurveTexture.new()
	ct.curve = cv
	pm.scale_curve = ct
	g.process_material = pm

	根.add_child(g)
	容器.add_child(根)
	if 根.is_inside_tree():
		根.global_position = pos
	else:
		根.position = pos
	_自动回收(根, g.lifetime + 0.35)

	# 血渍落在脚下（命中点在胸口，y 由 height_at 重新贴地，不用管传进来的高度）
	var 半径: float = clampf(0.26 + 0.24 * amount, 0.26, 0.62)
	blood_splat(Vector3(pos.x, pos.y, pos.z), 半径)


## 地面血渍：贴地 Quad + 径向渐变，停留 4s 再 1.6s 淡出。
## 池化原因：一场仗打几分钟会有上百次命中，每次 new 一个 24 节点的池会持续分配/释放，
## 这里固定 24 片槽位循环用，节点数恒定。
static func blood_splat(pos: Vector3, radius: float = 0.35) -> void:
	if not _血渍预算():
		return
	var 容器 := _容器()
	if 容器 == null:
		return
	var 槽: Dictionary = _取血渍槽(容器)
	if 槽.is_empty():
		return
	var mi := 槽["node"] as MeshInstance3D
	if mi == null:
		return
	# 复用前先掐掉上一轮的淡出 Tween，否则旧 Tween 会把新血渍提前淡掉
	var old: Variant = 槽.get("tween", null)
	if old is Tween and (old as Tween).is_valid():
		(old as Tween).kill()
	var r: float = maxf(0.08, radius)
	var y: float = RtsWorld.height_at(pos.x, pos.z) + 0.03
	mi.visible = true
	mi.transparency = 0.0
	# 和 _生成 同一个坑：--script 模式下 Window 根此刻可能还没进树，写 global_ 会刷错误日志
	if mi.is_inside_tree():
		mi.global_position = Vector3(pos.x, y, pos.z)
	else:
		mi.position = Vector3(pos.x, y, pos.z)
	# QuadMesh 是 1×1，在 XY 平面；绕 X 转 -90° 放平后，X/Y 缩放正好摊成世界 X/Z 的直径
	mi.rotation = Vector3(-PI * 0.5, randf() * TAU, 0.0)
	mi.scale = Vector3(r * 2.0, r * 2.0, 1.0)
	槽["busy"] = true
	槽["stamp"] = float(Time.get_ticks_msec()) * 0.001

	var tw: Tween = mi.create_tween()
	tw.tween_property(mi, "transparency", 1.0, 血渍淡出).set_delay(血渍停留)
	tw.tween_callback(func() -> void:
		mi.visible = false
		槽["busy"] = false
	)
	槽["tween"] = tw


## 刚被选中那一下：贴地圆环从 1.6 倍收到 1.05 倍，0.28s 内淡掉。
## 用 ImmediateMesh 现场拼 32 段三角带 —— 不依赖任何贴图或 shader，
## 选中圈本体（玩家口径定过的样式）保持不动，这里只加"被选中"的瞬时反馈。
static func selection_burst(pos: Vector3, radius: float = 0.9,
		color: Color = Color(0.32, 1.0, 0.52)) -> void:
	var 容器 := _容器()
	if 容器 == null:
		return
	# 同一帧的预算：框选 60 人时只有前 8 个"啪"一下，避免整屏半透明环叠成一团
	var 帧: int = Engine.get_process_frames()
	if 帧 != _选中爆发帧:
		_选中爆发帧 = 帧
		_选中爆发数 = 0
	if _选中爆发数 >= 选中爆发同帧上限:
		return
	_选中爆发数 += 1

	var r: float = maxf(0.25, radius)
	var 根 := Node3D.new()
	根.name = "选中爆发"
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.mesh = _选中环网格(r)
	var sm := StandardMaterial3D.new()
	sm.albedo_color = color
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.vertex_color_use_as_albedo = true
	sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mi.material_override = sm
	# 1.6 倍起步：环先从单位外面"崩"出来，再收到贴身的 1.05 倍
	mi.scale = Vector3(1.6, 1.0, 1.6)
	根.add_child(mi)
	容器.add_child(根)
	if 根.is_inside_tree():
		根.global_position = pos + Vector3(0.0, 0.04, 0.0)
	else:
		根.position = pos + Vector3(0.0, 0.04, 0.0)

	var tw: Tween = mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(1.05, 1.0, 1.05), 0.28) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(mi, "transparency", 1.0, 0.28)
	tw.chain().tween_callback(根.queue_free)


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


## 给一个临时特效挂自动回收（血花/池化血渍之外的"一次性节点"都用它）
static func _自动回收(n: Node, 存活: float) -> void:
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = maxf(0.05, 存活)
	tm.autostart = true
	n.add_child(tm)
	tm.timeout.connect(n.queue_free)


## 滑动窗口预算：窗口内条数没满就记一笔并放行。
## 写法照抄 BuildFx.allow_death_burst()（同一套口径，方便两边一起调）
static func _预算(表: Array, 窗口: float, 上限: int) -> bool:
	var now: float = float(Time.get_ticks_msec()) * 0.001
	var 留: Array = []
	for t in 表:
		if now - float(t) < 窗口:
			留.append(t)
	表.clear()
	for t in 留:
		表.append(t)
	if 留.size() >= 上限:
		return false
	表.append(now)
	return true


static func _血花预算() -> bool:
	return _预算(_血花时刻, 血花窗口, 血花上限)


static func _血渍预算() -> bool:
	return _预算(_血渍时刻, 血渍窗口, 血渍上限)


## 取一个血渍槽：先找空闲，没有就新建（≤24），再没有就顶掉最老的
static func _取血渍槽(容器: Node) -> Dictionary:
	# 场景重开时旧关卡带着池里的节点一起被释放，静态池会留下失效引用 —— 先剔掉
	var 有效: Array = []
	for s in _血渍槽:
		if s["node"] != null and is_instance_valid(s["node"]):
			有效.append(s)
	_血渍槽 = 有效
	for s in _血渍槽:
		if not bool(s["busy"]):
			return s
	if _血渍槽.size() < 血渍池容量:
		var 槽 := {"node": _造血渍(容器), "busy": false, "stamp": 0.0, "tween": null}
		if 槽["node"] == null:
			return {}
		_血渍槽.append(槽)
		return 槽
	var 最老: Dictionary = _血渍槽[0]
	for s in _血渍槽:
		if float(s["stamp"]) < float(最老["stamp"]):
			最老 = s
	return 最老


## 建一片血渍节点（只在池子扩容时调，最多 24 次）
static func _造血渍(容器: Node) -> MeshInstance3D:
	if 容器 == null:
		return null
	if _血渍材质 == null:
		# 径向渐变：中心 alpha 0.75 → 边缘 0。代码生成，不落 .png
		var grad := Gradient.new()
		grad.set_color(0, Color(1.0, 1.0, 1.0, 0.75))
		grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		grad.add_point(0.55, Color(1.0, 1.0, 1.0, 0.45))
		var gt := GradientTexture2D.new()
		gt.gradient = grad
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.5)
		gt.fill_to = Vector2(1.0, 0.5)
		gt.width = 64
		gt.height = 64
		var sm := StandardMaterial3D.new()
		sm.albedo_color = 血色
		sm.albedo_texture = gt
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED
		# 保留深度测试：血渍要按地面遮挡关系被地形/建筑挡住，而不是穿墙浮在画面上
		sm.no_depth_test = false
		_血渍材质 = sm

	var mi := MeshInstance3D.new()
	mi.name = "血渍"
	var qm := QuadMesh.new()
	qm.size = Vector2(1.0, 1.0)
	qm.material = _血渍材质
	mi.mesh = qm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	容器.add_child(mi)
	return mi


## 血滴的绘制网格：QuadMesh + UNSHADED 深红（没有贴图，全靠 albedo 上色）
static func _血滴网格() -> QuadMesh:
	if _血滴材质 == null:
		var sm := StandardMaterial3D.new()
		sm.albedo_color = 血色
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.cull_mode = BaseMaterial3D.CULL_DISABLED
		_血滴材质 = sm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.085, 0.085)
	qm.material = _血滴材质
	return qm


## 选中爆发的圆环几何：32 段三角带，半径 r、带宽 r*0.16（贴地，y=0 由根节点抬 4cm）
static func _选中环网格(r: float) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var 段: int = 32
	var 宽: float = clampf(r * 0.16, 0.03, 0.20)
	var 内: float = maxf(r - 宽 * 0.5, 0.02)
	var 外: float = r + 宽 * 0.5
	# 顶点色写成白色：材质用 vertex_color_use_as_albedo，颜色交给 albedo_color 统一管
	var c := Color(1.0, 1.0, 1.0, 1.0)
	for i in 段:
		var a0: float = TAU * float(i) / float(段)
		var a1: float = TAU * float(i + 1) / float(段)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		var p00 := Vector3(d0.x * 内, 0.0, d0.y * 内)
		var p01 := Vector3(d1.x * 内, 0.0, d1.y * 内)
		var p10 := Vector3(d0.x * 外, 0.0, d0.y * 外)
		var p11 := Vector3(d1.x * 外, 0.0, d1.y * 外)
		# ImmediateMesh 的颜色状态是"粘"的，但每次重设最稳（和移动指示同一写法）
		im.surface_set_color(c)
		im.surface_add_vertex(p00)
		im.surface_set_color(c)
		im.surface_add_vertex(p01)
		im.surface_set_color(c)
		im.surface_add_vertex(p11)
		im.surface_set_color(c)
		im.surface_add_vertex(p00)
		im.surface_set_color(c)
		im.surface_add_vertex(p11)
		im.surface_set_color(c)
		im.surface_add_vertex(p10)
	im.surface_end()
	return im


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
