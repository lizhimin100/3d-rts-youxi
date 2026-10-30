class_name BuildSite
extends Node3D
## **工地表现**：建筑从"放下"到"完工"这段时间的施工现场（SLEDGE 名下）。
##
## 分工：本节点只负责"看起来在盖房子"，不碰任何玩法数据 ——
##   进度仍然由 RtsBuilding.advance_construction() 推进，本节点只在 set_progress() 里跟。
##
## 四层结构（自下而上）：
##   ① 地基：比占地略大的石台 + 四角角石（"这里已经放线了"）
##   ② 料堆：石料堆 / 木料堆 / 绳圈（越建越少）
##   ③ 脚手架：8 根立柱随进度长高 + 4 层横杆按高度显隐 + 平台 / 梯子 / 斜撑
##   ④ 主体：给建筑的每个材质副本塞 clip_height，墙从 0 长到层高（着色器逐片元丢弃）
##
## 锤击反馈由 RtsBuilding 在农民抡锤时调 strike()，**按工地**做 0.9s 节流，
## 所以 3 个农民同时干也只是一工地一节奏，不会变成机关枪。

## 锤击最小间隔（秒）——任务书要求 0.7~1.2s 一次
const STRIKE_INTERVAL: float = 0.9
## 脚手架横杆层数与高度比例
const RAIL_LEVELS: PackedFloat32Array = [0.26, 0.50, 0.74, 0.96]

## 宿主建筑（故意只按 Node3D 鸭子类型用：避免"建筑 ↔ 工地"两个脚本 preload 成环）
var building: Node3D = null
var _fp: Vector2i = Vector2i(4, 4)
var _height: float = 4.0
var _hx: float = 2.4
var _hz: float = 2.4
var _progress: float = 0.0
var _done: bool = false

## 脚手架零件
var _posts: Array[MeshInstance3D] = []
var _rails: Array[MeshInstance3D] = []
var _rail_levels: Array[float] = []
var _braces: Array[MeshInstance3D] = []
var _platform: Node3D = null
var _ladder: Node3D = null
var _ladder_scale_root: Node3D = null
var _piles: Array[Node3D] = []

## 剖切材质副本：{ "mi": MeshInstance3D, "i": int, "prev": Material, "mat": ShaderMaterial }
var _clip: Array = []
var _clip_ok: bool = false
var _fallback_scale: bool = false

## 锤击节流
var _last_strike_ms: int = -10000
var strike_count: int = 0

## 材质（一份够用，工地不染色）
var _wood: StandardMaterial3D
var _wood_light: StandardMaterial3D
var _rope: StandardMaterial3D
var _stone: StandardMaterial3D
var _stone_light: StandardMaterial3D
var _iron: StandardMaterial3D


# ===========================================================================
# 装配
# ===========================================================================

## 挂到一栋"工地状态"的建筑上。必须在建筑的 visual 建好之后调（setup_construction 里）。
func attach(b: Node3D, _team_color: Color) -> void:
	building = b
	name = "工地"
	if b == null:
		return
	var d: UnitDef = b.get("def")
	if d == null:
		return
	_fp = d.footprint
	if _fp == Vector2i.ZERO:
		_fp = Vector2i(1, 1)
	_height = maxf(d.height, 1.2)
	_hx = float(_fp.x) * 0.5 + 0.42
	_hz = float(_fp.y) * 0.5 + 0.42

	_make_materials()
	_build_foundation()
	_build_piles()
	_build_scaffold()
	_collect_clip()
	set_progress(0.0)
	# 工地落地的第一声（石料/木架/碎石）。完工音不在这里 —— 由 building_completed
	# 信号统一交给 Sfx._on_built()，否则同一次完工会被播两遍。
	Sfx.play_at("建造_放置", building.global_position, 0.0)


func _make_materials() -> void:
	_wood = _standard(Color(0.40, 0.28, 0.16), 0.9)
	_wood_light = _standard(Color(0.55, 0.41, 0.25), 0.88)
	_rope = _standard(Color(0.62, 0.55, 0.36), 0.95)
	_stone = _standard(Color(0.44, 0.43, 0.40), 0.92)
	_stone_light = _standard(Color(0.57, 0.55, 0.51), 0.9)
	_iron = _standard(Color(0.30, 0.30, 0.33), 0.7)


## 把料堆贴到它所在位置的地面（斜地形上不悬空）
func _snap_to_ground(n: Node3D) -> void:
	if building == null or n == null:
		return
	var wp: Vector3 = building.global_position + n.position
	n.position.y = RtsWorld.height_at(wp.x, wp.z) - building.global_position.y + 0.02


func _standard(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


## ① 地基：3×3 砌块台面 + 一圈立起来的石砌边 + 四角角石
## 为什么不做一整块大板：斜地形上大板会一边翘起来像块飞碟；
## 砌块 + 立边读起来才是"这里已经放线、基础砌了一半"。
func _build_foundation() -> void:
	# 基槽：往地下埋 1.6m 的土台，斜地形上地基边缘不会悬空（比把地基做厚更便宜）
	var earth := _standard(Color(0.30, 0.24, 0.17), 1.0)
	add_child(_box(Vector3(float(_fp.x) + 0.75, 1.6, float(_fp.y) + 0.75),
			Vector3(0.0, -0.72, 0.0), earth))

	var nx: int = 3
	var nz: int = 3
	var tw: float = float(_fp.x) / float(nx)
	var td: float = float(_fp.y) / float(nz)
	for ix in nx:
		for iz in nz:
			var c := Vector3(-float(_fp.x) * 0.5 + tw * (float(ix) + 0.5), 0.055,
					-float(_fp.y) * 0.5 + td * (float(iz) + 0.5))
			add_child(_box(Vector3(tw * 0.93, 0.11, td * 0.93), c,
					_stone_light if (ix + iz) % 2 == 0 else _stone))

	# 立起来的石砌边（四边各一条，像刚砌到勒脚）
	var rim_h: float = 0.24
	add_child(_box(Vector3(float(_fp.x) + 0.16, rim_h, 0.26),
			Vector3(0.0, rim_h * 0.5 + 0.10, -float(_fp.y) * 0.5 - 0.06), _stone_light))
	add_child(_box(Vector3(float(_fp.x) + 0.16, rim_h, 0.26),
			Vector3(0.0, rim_h * 0.5 + 0.10, float(_fp.y) * 0.5 + 0.06), _stone_light))
	add_child(_box(Vector3(0.26, rim_h, float(_fp.y) + 0.16),
			Vector3(-float(_fp.x) * 0.5 - 0.06, rim_h * 0.5 + 0.10, 0.0), _stone))
	add_child(_box(Vector3(0.26, rim_h, float(_fp.y) + 0.16),
			Vector3(float(_fp.x) * 0.5 + 0.06, rim_h * 0.5 + 0.10, 0.0), _stone))

	# 四角角石
	var cx: float = float(_fp.x) * 0.5 + 0.10
	var cz: float = float(_fp.y) * 0.5 + 0.10
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			add_child(_box(Vector3(0.46, 0.42, 0.46), Vector3(sx * cx, 0.21, sz * cz), _stone_light))

	# 施工放线：四边压一圈窄木条（"施工放线"的读感）
	add_child(_box(Vector3(float(_fp.x) + 1.0, 0.03, 0.06), Vector3(0.0, 0.03, -_hz + 0.10), _rope))
	add_child(_box(Vector3(float(_fp.x) + 1.0, 0.03, 0.06), Vector3(0.0, 0.03, _hz - 0.10), _rope))
	add_child(_box(Vector3(0.06, 0.03, float(_fp.y) + 1.0), Vector3(-_hx + 0.10, 0.03, 0.0), _rope))
	add_child(_box(Vector3(0.06, 0.03, float(_fp.y) + 1.0), Vector3(_hx - 0.10, 0.03, 0.0), _rope))


## ② 料堆：石料 / 木料 / 绳圈，进度过半后收走
func _build_piles() -> void:
	var pile_a := Node3D.new()
	pile_a.name = "石料堆"
	pile_a.position = Vector3(-_hx + 0.55, 0.0, -_hz + 0.55)
	add_child(pile_a)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261018
	for i in 7:
		var s: float = rng.randf_range(0.18, 0.34)
		var mi := _box(Vector3(s, s, s * rng.randf_range(0.7, 1.2)),
				Vector3(rng.randf_range(-0.28, 0.28), s * 0.5 + 0.02,
						rng.randf_range(-0.28, 0.28)), _stone_light if i % 2 == 0 else _stone)
		mi.rotation.y = rng.randf() * TAU
		pile_a.add_child(mi)
	_snap_to_ground(pile_a)
	_piles.append(pile_a)

	var pile_b := Node3D.new()
	pile_b.name = "木料堆"
	pile_b.position = Vector3(_hx - 0.55, 0.0, _hz - 0.65)
	add_child(pile_b)
	for i in 6:
		var beam := _box(Vector3(1.5, 0.13, 0.13),
				Vector3(0.0, 0.07 + float(i) * 0.135, 0.0), _wood if i % 2 == 0 else _wood_light)
		beam.rotation.y = (0.0 if i < 3 else PI * 0.5)
		pile_b.add_child(beam)
	_snap_to_ground(pile_b)
	_piles.append(pile_b)

	# 绳圈：一个躺着的圆环
	var coil := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.16
	tm.outer_radius = 0.26
	tm.rings = 14
	tm.ring_segments = 6
	coil.mesh = tm
	coil.material_override = _rope
	coil.position = Vector3(-_hx + 0.5, 0.06, _hz - 0.6)
	coil.rotation.x = PI * 0.5
	add_child(coil)
	_snap_to_ground(coil)
	_piles.append(coil)


## ③ 脚手架：立柱 / 横杆 / 斜撑 / 平台 / 梯子
func _build_scaffold() -> void:
	var root := Node3D.new()
	root.name = "脚手架"
	add_child(root)

	# 立柱：8 根（四角 + 四边中点），单位高度 1，靠 scale.y 长高
	var spots: Array = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			spots.append(Vector3(sx * _hx, 0.0, sz * _hz))
	spots.append(Vector3(0.0, 0.0, -_hz))
	spots.append(Vector3(0.0, 0.0, _hz))
	spots.append(Vector3(-_hx, 0.0, 0.0))
	spots.append(Vector3(_hx, 0.0, 0.0))
	for s in spots:
		var post := _box(Vector3(0.06, 1.0, 0.06), Vector3(s.x, 0.5, s.z), _wood)
		root.add_child(post)
		_posts.append(post)

	# 横杆：每层 4 根（前后左右），按进度显隐
	for lv in RAIL_LEVELS:
		var y: float = _height * float(lv)
		var a := _box(Vector3(_hx * 2.0, 0.05, 0.05), Vector3(0.0, y, -_hz), _wood_light)
		var b := _box(Vector3(_hx * 2.0, 0.05, 0.05), Vector3(0.0, y, _hz), _wood_light)
		var c := _box(Vector3(0.05, 0.05, _hz * 2.0), Vector3(-_hx, y, 0.0), _wood_light)
		var d := _box(Vector3(0.05, 0.05, _hz * 2.0), Vector3(_hx, y, 0.0), _wood_light)
		for r in [a, b, c, d]:
			root.add_child(r)
			_rails.append(r)
			_rail_levels.append(float(lv))

	# 斜撑：四个面上各一根 45° 木条（按进度显隐，避免一开工就满身线条）
	var brace_len: float = sqrt(pow(_hx * 2.0, 2.0) + pow(_height * 0.5, 2.0))
	var ba := _box(Vector3(brace_len, 0.05, 0.05), Vector3(0.0, 0.0, -_hz), _wood)
	ba.rotation.z = atan2(_height * 0.5, _hx * 2.0)
	root.add_child(ba)
	_braces.append(ba)
	var bb := _box(Vector3(brace_len, 0.05, 0.05), Vector3(0.0, 0.0, _hz), _wood)
	bb.rotation.z = -atan2(_height * 0.5, _hx * 2.0)
	root.add_child(bb)
	_braces.append(bb)

	# 平台：脚手架顶部两块跳板（一侧沿 X、一侧沿 Z，形成 L 形工作面）
	_platform = Node3D.new()
	_platform.name = "工作平台"
	root.add_child(_platform)
	_platform.add_child(_box(Vector3(_hx * 2.0, 0.05, 0.28), Vector3(0.0, 0.0, -_hz + 0.14), _wood_light))
	_platform.add_child(_box(Vector3(0.28, 0.05, _hz * 2.0), Vector3(_hx - 0.14, 0.0, 0.0), _wood_light))

	# 梯子：正面（-Z）两臂 + 6 根横档，整体随进度长高
	_ladder_scale_root = Node3D.new()
	_ladder_scale_root.name = "梯子"
	_ladder_scale_root.position = Vector3(-_hx + 0.55, 0.0, -_hz - 0.12)
	root.add_child(_ladder_scale_root)
	var lr_a := _box(Vector3(0.045, 1.0, 0.045), Vector3(-0.20, 0.5, 0.0), _wood)
	var lr_b := _box(Vector3(0.045, 1.0, 0.045), Vector3(0.20, 0.5, 0.0), _wood)
	_ladder_scale_root.add_child(lr_a)
	_ladder_scale_root.add_child(lr_b)
	for i in 6:
		var y: float = (float(i) + 0.5) / 6.0
		_ladder_scale_root.add_child(_box(Vector3(0.40, 0.032, 0.032), Vector3(0.0, y, 0.0), _wood_light))
	# 梯子要能"长高"，所以子节点用 0~1 的归一化高度，靠父节点 scale.y 拉伸
	for c in _ladder_scale_root.get_children():
		(c as Node3D).set_meta("unit_y", (c as Node3D).position.y)
	_ladder = _ladder_scale_root


## ④ 剖切：给建筑每个材质面复制一份带 clip_height 的材质
func _collect_clip() -> void:
	if building == null:
		return
	var vis := building.get("visual") as Node3D
	if vis == null:
		return
	var meshes := _meshes_of(vis)
	for mi in meshes:
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(i)
			if src == null:
				src = mi.mesh.surface_get_material(i)
			var sm := src as ShaderMaterial
			if sm == null:
				continue
			# 注意：不能拿 get_shader_parameter() 判空 —— 没写过的 uniform 返回 null，
			# 但 shader 里其实有默认值。必须查 uniform 列表。
			if not _shader_has(sm, "clip_height"):
				continue
			var dup := sm.duplicate() as ShaderMaterial
			if dup == null:
				continue
			dup.set_shader_parameter("clip_height", 0.0)
			_clip.append({"mi": mi, "i": i, "prev": mi.get_surface_override_material(i), "mat": dup})
			mi.set_surface_override_material(i, dup)
	_clip_ok = not _clip.is_empty()
	# 一个面都没剖到（美术资产不是卡通着色器）→ 退化成"整体纵向拉伸"，至少能看出在长
	_fallback_scale = not _clip_ok


# ===========================================================================
# 进度驱动
# ===========================================================================

## 每帧由 RtsBuilding 推进（0~1）；本节点只把它翻译成几何
func set_progress(p: float) -> void:
	if _done or building == null:
		return
	_progress = clampf(p, 0.0, 1.0)
	var grown: float = _height * _progress

	# 剖切高度：+0.06 让地面处也有一点厚度，否则进度 0 时连地基都看不见
	if _clip_ok:
		for e in _clip:
			var sm := e["mat"] as ShaderMaterial
			sm.set_shader_parameter("clip_height", grown + 0.06)
	elif _fallback_scale:
		var vis := building.get("visual") as Node3D
		if vis != null:
			vis.scale = Vector3(1.0, clampf(_progress, 0.02, 1.0), 1.0)

	# 立柱长高
	var post_h: float = maxf(grown + 0.35, 0.35)
	for post in _posts:
		if not is_instance_valid(post):
			continue
		post.scale.y = post_h
		post.position.y = post_h * 0.5

	# 横杆：过了那个高度才出现
	for i in _rails.size():
		var r: MeshInstance3D = _rails[i]
		if not is_instance_valid(r):
			continue
		r.visible = grown + 0.35 >= _height * _rail_levels[i]

	# 斜撑：盖到 1/3 才开始上
	for b in _braces:
		if is_instance_valid(b):
			b.visible = _progress > 0.32

	# 平台：跟着脚手架顶走
	if _platform != null and is_instance_valid(_platform):
		_platform.visible = _progress > 0.12
		_platform.position.y = grown + 0.42

	# 梯子：归一化子节点靠父节点 scale.y 拉伸
	if _ladder != null and is_instance_valid(_ladder):
		_ladder.scale.y = maxf(post_h, 0.35)
		_ladder.visible = _progress > 0.05

	# 料堆：过半之后陆续"用完"
	for k in _piles.size():
		var pile: Node3D = _piles[k]
		if pile != null and is_instance_valid(pile):
			var thresh: float = 0.55 + 0.12 * float(k)
			pile.visible = _progress < thresh
			var s: float = clampf((thresh - _progress) / 0.25, 0.35, 1.0)
			pile.scale = Vector3(s, s, s)


## 锤击反馈：返回这次是否真的出效果（节流用）
## at 是农民位置（可为空），用来把尘土放在"他正在敲的那一段墙根"
func strike(at: Vector3 = Vector3.ZERO) -> bool:
	if _done or building == null:
		return false
	var now: int = Time.get_ticks_msec()
	if now - _last_strike_ms < int(STRIKE_INTERVAL * 1000.0):
		return false
	_last_strike_ms = now
	strike_count += 1

	var base: Vector3 = building.global_position
	var side := Vector3.ZERO
	if at != Vector3.ZERO and base.distance_squared_to(at) < 400.0:
		side = (at - base)
		side.y = 0.0
		if side.length_squared() > 0.0001:
			side = side.normalized()
	if side == Vector3.ZERO:
		var ang: float = randf() * TAU
		side = Vector3(cos(ang), 0.0, sin(ang))
	# 墙根位置：占地边缘 + 当前已建高度
	var hit := base + side * Vector3(_hx, 0.0, _hz).length() * 0.62
	hit.y = base.y + clampf(_height * _progress + 0.20, 0.25, _height - 0.25)

	BuildFx.dust(hit, 5, 0.35, Color(0.66, 0.60, 0.48))
	BuildFx.chips(hit, Color(0.60, 0.44, 0.26), 6)
	Sfx.play_at("建造_锤击", hit, -5.0)
	return true


# ===========================================================================
# 完成 / 中途被拆
# ===========================================================================

## 完工：撤掉剖切 → 脚手架散落 → 尘土爆发 → 闪一下 → 自毁
func finish() -> void:
	if _done:
		return
	_done = true
	_restore_clip()
	if building != null:
		var vis: Node = building.get("visual")
		if vis != null and vis.has_method("flash"):
			vis.call("flash")
		var base: Vector3 = building.global_position
		BuildFx.dust(base + Vector3(0.0, 0.25, 0.0), 16, 1.1, Color(0.70, 0.64, 0.50))
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				BuildFx.dust(base + Vector3(sx * _hx * 0.8, 0.2, sz * _hz * 0.8), 7, 0.7,
						Color(0.64, 0.58, 0.46))
		Game.shake(0.10)
		# 完工音已由 Sfx._on_built()（building_completed 信号）统一播放，这里不再重复
	_collapse_scaffold()
	# 让散落的木头飞完再见
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 1.5
	add_child(tm)
	tm.timeout.connect(queue_free)
	tm.start()


## 工地还没完工就被拆：脚手架跟着倒
func abort() -> void:
	if _done:
		return
	_done = true
	_restore_clip()
	_collapse_scaffold()
	var base: Vector3 = building.global_position if building != null else global_position
	BuildFx.dust(base + Vector3.UP * 0.4, 14, 1.0, Color(0.66, 0.60, 0.48))
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 0.9
	add_child(tm)
	tm.timeout.connect(queue_free)
	tm.start()


## 撤掉剖切材质（还原成 MatKit 原本那份共享材质）
func _restore_clip() -> void:
	for e in _clip:
		var mi: MeshInstance3D = e["mi"]
		if mi == null or not is_instance_valid(mi):
			continue
		var i: int = int(e["i"])
		if i >= mi.mesh.get_surface_count():
			continue
		mi.set_surface_override_material(i, e["prev"])
	_clip.clear()
	if _fallback_scale and building != null:
		var vis := building.get("visual") as Node3D
		if vis != null:
			vis.scale = Vector3.ONE


## 脚手架散落：立柱向外倒、横杆掉地、平台翻下去（0.9s）
func _collapse_scaffold() -> void:
	for n in _posts:
		if is_instance_valid(n):
			_fall(n, Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(0.5, 1.3)))
	for n in _rails:
		if is_instance_valid(n):
			_fall(n, Vector3(randf_range(-0.8, 0.8), 0.0, randf_range(-0.8, 0.8)), 0.7)
	if _platform != null and is_instance_valid(_platform):
		_fall(_platform, Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-1.0, 1.0)), 1.2)
	if _ladder != null and is_instance_valid(_ladder):
		_fall(_ladder, Vector3(0.0, 0.0, -1.4), 1.1)


func _fall(n: Node3D, dir: Vector3, drop: float = 0.55) -> void:
	var tw := n.create_tween()
	tw.set_parallel(true)
	tw.tween_property(n, "rotation:z", n.rotation.z + dir.x * 1.2, 0.55)
	tw.tween_property(n, "rotation:x", n.rotation.x + dir.z * 1.2, 0.55)
	tw.tween_property(n, "position:y", n.position.y - drop, 0.55)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(n):
			n.visible = false)


# ===========================================================================
# 内部
# ===========================================================================

func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	return mi


## 这个 ShaderMaterial 的 shader 里有没有这个 uniform
func _shader_has(sm: ShaderMaterial, uniform: String) -> bool:
	if sm == null or sm.shader == null:
		return false
	for u in sm.shader.get_shader_uniform_list():
		if String(u.name) == uniform:
			return true
	return false


func _meshes_of(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			out.append(mi)
		for c in n.get_children():
			stack.append(c)
	return out


## 自检用：当前剖切高度（没有剖切材质时返回 -2）
func clip_height() -> float:
	if _clip.is_empty():
		return -2.0
	var sm := _clip[0]["mat"] as ShaderMaterial
	var v: Variant = sm.get_shader_parameter("clip_height")
	return float(v) if v != null else -2.0


## 自检用：当前"可见建筑高度"。有 clip_height 着色器走剖切；没有则走纵向压缩兜底。
## 建筑资产是 StandardMaterial3D（硬约束，不能挂自定义 shader），所以后者是常态。
func cut_height() -> float:
	if _done:
		return -2.0
	if _clip_ok:
		return clip_height()
	if _fallback_scale and building != null:
		var vis := building.get("visual") as Node3D
		if vis != null:
			return _height * vis.scale.y
	return -2.0


## 自检用：脚手架立柱当前高度（第一根）
func post_height() -> float:
	for p in _posts:
		if is_instance_valid(p):
			return p.scale.y
	return 0.0


## 自检用：当前可见的横杆数
func visible_rails() -> int:
	var n: int = 0
	for r in _rails:
		if is_instance_valid(r) and r.visible:
			n += 1
	return n