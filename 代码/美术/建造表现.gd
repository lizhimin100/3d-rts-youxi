class_name BuildFx
extends RefCounted
## **建造 / 死亡 / 摧毁的运行时表现工具箱**（SLEDGE 名下）。
##
## 为什么单独一层：工地、尸体、倒塌三件事都只需要「一次性碎屑 / 尘土 / 废墟 / 节流」，
## 塞进 RtsUnit 或 Vfx 会让那两个文件继续变胖，而且 Vfx 是 ANVIL 的资产门面，
## 不该承担"批量死亡要不要刷屏"这种玩法侧预算。
##
## 契约（只增不改，别的模块可以放心调）：
##   BuildFx.dust(pos, ...)            小尘土（锤击 / 落地 / 尸体下沉）
##   BuildFx.chips(pos, ...)           木屑 / 石屑（建造锤击）
##   BuildFx.debris(pos, ...)          大碎块（建筑倒塌 / 掉落瓦石）
##   BuildFx.death_puff(pos, color)    单位死亡：小尘土必给，血雾按全局预算节流
##   BuildFx.allow_death_burst()       全局节流闸（0.4s 窗口内最多 4 次大特效）
##   BuildFx.make_ruins(...) -> Node3D 程序化废墟（断墙 / 瓦砾 / 焦木），自带停留+淡出+自毁
##
## 全部纯代码生成（StandardMaterial3D + GPUParticles3D），不依赖任何美术文件；
## 找不到场景树时安全地什么都不做，绝不抛错打断玩法。

## 单位死亡大特效的预算：窗口内最多几次（超了只留小尘土）
const DEATH_WINDOW: float = 0.4
const DEATH_BUDGET: int = 4

## 统计口径（自检与调优用）：大特效实际放了几次、被节流掉几次
static var death_burst_count: int = 0
static var death_burst_skipped: int = 0
static var _death_stamps: Array = []


# ===========================================================================
# 节流
# ===========================================================================

## 现在能不能再放一次"死亡大特效"（0.4 秒窗口，最多 4 次）
static func allow_death_burst() -> bool:
	var now: float = float(Time.get_ticks_msec()) * 0.001
	var keep: Array = []
	for t in _death_stamps:
		if now - float(t) < DEATH_WINDOW:
			keep.append(t)
	_death_stamps = keep
	if keep.size() >= DEATH_BUDGET:
		death_burst_skipped += 1
		return false
	_death_stamps.append(now)
	death_burst_count += 1
	return true


## 清零计数器（自检每次开跑前调一次）
static func reset_counters() -> void:
	death_burst_count = 0
	death_burst_skipped = 0
	_death_stamps = []


## 自检用：把节流计数一次性读出来（--script 模式下直接读静态变量不可靠）
static func stats() -> Dictionary:
	return {"death": death_burst_count, "skipped": death_burst_skipped}


# ===========================================================================
# 对外特效
# ===========================================================================

## 小尘土：0.8 秒的贴地烟团，用来看"有人在干活 / 有东西落地"
static func dust(pos: Vector3, amount: int = 8, spread: float = 0.55,
		color: Color = Color(0.62, 0.56, 0.44)) -> Node3D:
	return burst(pos, amount, 0.85, 1.5, color, 0.24, -1.2, 0, spread)


## 木屑 / 石屑：小方粒，锤击时从墙根弹出来
static func chips(pos: Vector3, color: Color = Color(0.62, 0.44, 0.24),
		amount: int = 7) -> Node3D:
	return burst(pos, amount, 0.55, 3.4, color, 0.055, -9.5, 1, 0.16)


## 大碎块：倒塌时掉瓦掉石（带旋转、重力大）
static func debris(pos: Vector3, color: Color = Color(0.46, 0.44, 0.40),
		amount: int = 14, size: float = 0.26) -> Node3D:
	return burst(pos, amount, 1.35, 5.2, color, size, -15.0, 1, 0.8)


## 单位死亡：小尘土永远给（廉价），血雾/碎裂走全局预算（同屏多死不会刷屏）
static func death_puff(pos: Vector3, color: Color = Color(0.55, 0.18, 0.14)) -> void:
	dust(pos, 6, 0.4, Color(0.58, 0.52, 0.42))
	if not allow_death_burst():
		return
	# 大特效仍然交给 ANVIL 的 Vfx（它有自己的场景与回退），坏掉也不会中断
	var v: Script = _script("res://代码/美术/特效生成.gd")
	if v != null:
		v.call("death_burst", pos, color)


# ===========================================================================
# 废墟
# ===========================================================================

## 程序化废墟：断墙（按占地四边随机留残高）+ 瓦砾堆 + 焦木，停留 linger 秒后淡出自毁。
## 返回节点（挂到关卡下，不跟建筑一起沉）；失败返回 null。
static func make_ruins(pos: Vector3, footprint: Vector2i, height: float,
		team_color: Color = Color(0.35, 0.45, 0.62), linger: float = 5.0) -> Node3D:
	var host := _host()
	if host == null:
		return null
	var root := Node3D.new()
	root.name = "废墟"
	host.add_child(root)
	root.global_position = pos

	# 石料要够亮：上一条版本 0.40/0.24 在实际光照+阴影里会读成一条条黑板。
	var stone := _mat(Color(0.56, 0.54, 0.50))
	var stone_dark := _mat(Color(0.36, 0.34, 0.31))
	var charred := _mat(Color(0.13, 0.11, 0.09))
	# 屋面：青灰瓦 + 打过仗的队伍蓝瓦（压暗），让废墟一眼能认出"是刚才那栋房子"
	var roof_dark := _mat(Color(0.38, 0.40, 0.44))
	# 队伍色要"沾过灰"：直接乘个系数还是一块亮蓝布，往瓦灰里 lerp 掉 2/3 才像塌下来的旧瓦
	# 队伍色只留一丝（0.10）：这个场景的 ACES 色调映射会把蓝通道拉爆，掺多了就是一块荧光布
	var roof_team := _mat(Color(0.40, 0.42, 0.45).lerp(team_color, 0.10))
	# 破旗：也压暗、也吃光（unshaded 在这种亮场景里会跳成一块荧光布）
	# 破旗：队伍色直接压到 0.35 左右（这个场景会把亮蓝拉到荧光），读作"烧焦的军旗"
	var cloth := _mat(Color(team_color.r * 0.34, team_color.g * 0.37, team_color.b * 0.42))

	var hx: float = maxf(float(footprint.x), 2.0) * 0.5
	var hz: float = maxf(float(footprint.y), 2.0) * 0.5
	var top: float = maxf(height, 1.0)

	# ① 断墙：四边各留 2~3 段残墙，高 0.35~1.3m（"还有半截墙"才像废墟）
	var sides: Array = [
		[Vector3(0.0, 0.0, -hz), Vector3(1.0, 0.0, 0.0), hx * 2.0],
		[Vector3(0.0, 0.0, hz), Vector3(1.0, 0.0, 0.0), hx * 2.0],
		[Vector3(-hx, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), hz * 2.0],
		[Vector3(hx, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), hz * 2.0],
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(pos.x * 73.0 + pos.z * 131.0) & 0x7fffffff
	for side in sides:
		var origin: Vector3 = side[0]
		var dir: Vector3 = side[1]
		var length: float = side[2]
		var segs: int = 4
		for i in segs:
			if rng.randf() < 0.18:
				continue
			var t: float = (float(i) + 0.5) / float(segs)
			var seg_len: float = length / float(segs) * rng.randf_range(0.72, 1.02)
			var h: float = clampf(top * rng.randf_range(0.10, 0.26), 0.32, 1.45)
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(seg_len, h, 0.34)
			mi.mesh = bm
			mi.material_override = stone if rng.randf() > 0.25 else stone_dark
			mi.position = origin + dir * (t * length - length * 0.5) + Vector3(0.0, h * 0.5 - 0.06, 0.0)
			if dir.z != 0.0:
				mi.rotation.y = PI * 0.5
			mi.rotation.y += rng.randf_range(-0.10, 0.10)
			mi.rotation.z = rng.randf_range(-0.06, 0.06)
			root.add_child(mi)

	# ② 瓦砾：散落在占地里的碎石块
	for i in 14:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var s: float = rng.randf_range(0.16, 0.46)
		bm.size = Vector3(s, s * rng.randf_range(0.4, 0.9), s * rng.randf_range(0.7, 1.3))
		mi.mesh = bm
		if i % 5 == 0:
			# 碎瓦：扁一点、用屋面色
			bm.size = Vector3(s * 1.5, s * 0.18, s * 1.1)
			mi.material_override = roof_team if i % 10 == 0 else roof_dark
		else:
			mi.material_override = stone_dark if rng.randf() > 0.5 else stone
		mi.position = Vector3(rng.randf_range(-hx * 0.92, hx * 0.92),
				bm.size.y * 0.4, rng.randf_range(-hz * 0.92, hz * 0.92))
		mi.rotation = Vector3(rng.randf_range(-0.4, 0.4), rng.randf() * TAU,
				rng.randf_range(-0.4, 0.4))
		root.add_child(mi)

	# ②.5 塌下来的屋面：2~3 片斜插的屋面板 + 一条瓦垄（薄 box，随机角度）
	for i in 3:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(rng.randf_range(1.15, 1.95), 0.08, rng.randf_range(0.75, 1.25))
		mi.mesh = bm
		mi.material_override = roof_dark if i % 2 == 0 else roof_team
		mi.position = Vector3(rng.randf_range(-hx * 0.62, hx * 0.62),
				rng.randf_range(0.10, 0.30), rng.randf_range(-hz * 0.62, hz * 0.62))
		# 更陡一点、半埋进瓦砾：读作"整片屋面塌下来插进地里"，不是平放的桌子
		mi.rotation = Vector3(rng.randf_range(-0.95, -0.55), rng.randf() * TAU,
				rng.randf_range(-0.28, 0.28))
		root.add_child(mi)
	# 一条还连着的瓦垄（三块小薄板排一行，斜压在瓦砾上）
	for i in 3:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.34, 0.07, 0.9)
		mi.mesh = bm
		mi.material_override = roof_dark
		mi.position = Vector3(-hx * 0.25 + float(i) * 0.36, 0.34, hz * 0.30)
		mi.rotation = Vector3(-0.45, 0.22, 0.0)
		root.add_child(mi)

	# ③ 焦木：几根烧黑的梁斜插在瓦砾里
	for i in 3:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.13, 0.13, rng.randf_range(1.2, 2.4))
		mi.mesh = bm
		mi.material_override = charred
		mi.position = Vector3(rng.randf_range(-hx * 0.7, hx * 0.7), 0.22,
				rng.randf_range(-hz * 0.7, hz * 0.7))
		mi.rotation = Vector3(rng.randf_range(-0.35, 0.35), rng.randf() * TAU, 0.0)
		root.add_child(mi)

	# ④ 半截旗面 / 破布：一眼能认出这是谁家被拆了
	var flag := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.9, 0.5)
	flag.mesh = qm
	flag.material_override = cloth
	flag.position = Vector3(hx * 0.35, 0.55, -hz * 0.3)
	flag.rotation = Vector3(-PI * 0.5, rng.randf_range(-0.6, 0.6), 0.0)
	flag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(flag)

	# ⑤ 余烟：细长的上浮粒子，3 秒后自己停
	_smoke(root, Vector3(0.0, 0.4, 0.0), top * 0.25)

	# ⑥ 停留 → 淡出 → 自毁（tween 挂在废墟自己身上，关卡被换掉也不会漏节点）
	#
	# ★ 这里踩过一个坑：tween_interval() 之后直接 tw.parallel().tween_property()，
	#   parallel() 是"和**上一个**步骤并行"，于是淡出会跟 5 秒的 interval 同时从 0 开始 ——
	#   废墟落地就透明了，只剩影子。正确写法：先起一个顺序步骤（下沉），其余用 parallel 跟它并行。
	var tw := root.create_tween()
	tw.tween_interval(maxf(linger, 0.5))
	tw.tween_property(root, "position:y", root.position.y - 0.35, 0.85)
	if _supports_transparency():
		for c in _meshes_of(root):
			tw.parallel().tween_property(c, "transparency", 1.0, 0.85)
	tw.chain().tween_callback(root.queue_free)
	return root


# ===========================================================================
# 内部：粒子
# ===========================================================================

## 一次性碎屑/尘土。mesh_kind: 0=朝向相机的片，1=小方粒
static func burst(pos: Vector3, amount: int, lifetime: float, speed: float,
		color: Color, size: float, gravity: float, mesh_kind: int = 0,
		spread_radius: float = 0.3) -> Node3D:
	var host := _host()
	if host == null:
		return null
	var root := Node3D.new()
	root.name = "碎屑"
	host.add_child(root)
	root.global_position = pos

	var g := GPUParticles3D.new()
	g.amount = maxi(amount, 1)
	g.lifetime = maxf(lifetime, 0.2)
	g.one_shot = true
	g.explosiveness = 0.92
	g.emitting = true
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = maxf(spread_radius, 0.02)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 68.0
	pm.initial_velocity_min = speed * 0.35
	pm.initial_velocity_max = speed
	pm.gravity = Vector3(0.0, gravity, 0.0)
	pm.scale_min = 0.65
	pm.scale_max = 1.45
	pm.angular_velocity_min = -220.0
	pm.angular_velocity_max = 220.0
	pm.damping_min = 0.4
	pm.damping_max = 1.8
	pm.color = color
	g.process_material = pm

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.96
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if mesh_kind == 1:
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * maxf(size, 0.02)
		bm.material = mat
		g.draw_pass_1 = bm
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		var qm := QuadMesh.new()
		qm.size = Vector2(maxf(size, 0.04), maxf(size, 0.04))
		qm.material = mat
		g.draw_pass_1 = qm
	root.add_child(g)
	_auto_free(root, maxf(lifetime, 0.2) + 0.7)
	return root


## 余烟：连续发射的上浮片粒子（挂在废墟下，跟废墟一起消失）
static func _smoke(parent: Node3D, offset: Vector3, rise: float) -> void:
	var g := GPUParticles3D.new()
	g.amount = 12
	g.lifetime = 2.2
	g.one_shot = false
	g.emitting = true
	g.position = offset
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.35
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 14.0
	pm.initial_velocity_min = 0.35
	pm.initial_velocity_max = 0.9
	pm.gravity = Vector3(0.25, 0.35, 0.0)
	pm.scale_min = 1.2
	pm.scale_max = 3.4
	pm.color = Color(0.22, 0.21, 0.20, 0.55)
	pm.damping_min = 0.2
	pm.damping_max = 0.5
	g.process_material = pm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(0.24, 0.23, 0.22, 0.42)
	var qm := QuadMesh.new()
	qm.size = Vector2(0.55, 0.55)
	qm.material = mat
	g.draw_pass_1 = qm
	parent.add_child(g)
	# 烟只冒一小会儿：rise 秒后关掉发射，寿命到了粒子自己消失
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = maxf(rise, 0.6)
	parent.add_child(tm)
	tm.timeout.connect(func() -> void:
		if is_instance_valid(g):
			g.emitting = false)
	tm.start()


# ===========================================================================
# 内部：杂项
# ===========================================================================

## 当前场景（没有 current_scene 时退回 root；都没有返回 null）
static func _host() -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return null
	if loop.current_scene != null:
		return loop.current_scene
	return loop.root


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.88
	return m


static func _script(path: String) -> Script:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Script


static func _auto_free(n: Node, delay: float) -> void:
	if n == null:
		return
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = maxf(delay, 0.05)
	n.add_child(tm)
	tm.timeout.connect(n.queue_free)
	tm.start()


static func _meshes_of(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


static func _supports_transparency() -> bool:
	if not ClassDB.class_exists("GeometryInstance3D"):
		return false
	for info in ClassDB.class_get_property_list("GeometryInstance3D"):
		if String(info.get("name", "")) == "transparency":
			return true
	return false
