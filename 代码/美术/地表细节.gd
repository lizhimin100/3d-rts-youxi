class_name RtsGroundDetail
extends Node3D
## **地表细节层**：把 MapGenerator 产出的"纯视觉"数据变成真正的 MultiMesh / 网格。
##
## 为什么单独一层：
##   · 关卡（RtsLevel）只认树/矿/岩石这类**玩法道具**，地表叙事（土路、车辙、草丛、
##     碎石带、营地杂物、断墙遗迹）不参与寻路，也不该让关卡脚本膨胀；
##   · 这一层全部走合批（每种装饰 1 个 MultiMesh = 1 次 draw call），
##     不加碰撞、不写 walkable、不 cast shadow，对 60fps 几乎无成本。
##
## 挂载方式：
##   MapGenerator.build() 末尾调 `RtsGroundDetail.install(data)`，
##   本节点在下一帧自己找到场景里的 RtsLevel（校验 map_data 是同一份）并挂到"场景道具"下。
##   地图生成自检（无关卡）里会自动放弃，不会留垃圾节点。
##
## 不新增贴图/GLB：土路是顶点色网格，道具是基础几何（Box/Cylinder/Sphere）烘出来的。

## 土路采样步长（米）：越小越贴地形，1.3m 在 112 细分下已经贴得很紧
const ROAD_STEP: float = 1.0
## 土路抬高量（米）：贴地但不 z-fighting。
## 2026-10-23 从 0.10 提到 0.18 —— 兵营门口那段路在 26m 机位下会"闪"，
## 是路面三角与地形几乎共面导致的深度打架；0.18 从 RTS 视角看不出悬空。
const ROAD_LIFT: float = 0.18
## 横向列数（决定车辙/边缘淡出的细腻度）
const ROAD_COLS: int = 7
## 台地顶集结场半径（米）
const PLAZA_R: float = 6.8
## 装饰统一不投影（和草丛/碎石批次一致，省阴影 pass）
const DECOR_SHADOW: bool = false

## 当前这层属于哪份地图数据
var _data: MapGenerator.MapData = null
## 关卡节点（地形被 RIDGE 二次雕刻过，贴地必须问它，不能用生成器的原始高度）
var _level: Node = null
var _built: bool = false
## 合批材质（所有程序化道具共用：顶点色 × 实例色）
static var _mat: StandardMaterial3D = null
## 当前活着的这一层（建筑清占地时直接问它，比在节点树里 find_child 稳）
static var 当前实例: Node = null


# ===========================================================================
# 安装
# ===========================================================================
## 地图生成结束时调用：下一帧自己挂到关卡上（找不到关卡就自杀）
static func install(data: MapGenerator.MapData) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null or data == null:
		return
	var probe := RtsGroundDetail.new()
	probe.name = "地表细节_待挂载"
	probe._data = data
	tree.root.call_deferred("add_child", probe)


func _ready() -> void:
	_attach.call_deferred()


## 退出时清静态缓存，避免关停时报 "resources still in use"
func _exit_tree() -> void:
	if 当前实例 == self:
		当前实例 = null
	_mat = null
	RtsDecorLib.clear_cache()


func _attach() -> void:
	var level := _find_level()
	if level == null:
		queue_free()
		return
	# 只认同一份地图数据（换图重建时旧层必须走）
	var md: Variant = level.get("map_data")
	if md == null or md != _data:
		queue_free()
		return
	_level = level
	var parent: Node3D = level.find_child("场景道具", false, false) as Node3D
	if parent == null:
		parent = level
	# 清掉上一次的（重复 build）
	for c in parent.get_children():
		if String(c.name).begins_with("地表细节"):
			c.queue_free()
	if get_parent() != null:
		get_parent().remove_child(self)
	parent.add_child(self)
	name = "地表细节"
	position = Vector3.ZERO
	当前实例 = self
	_build()


func _find_level() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	# 用名字找，不写 `is RtsLevel`：自检/无 autoload 环境下也能编译，不牵连关卡脚本
	return tree.root.find_child("关卡", true, false)


## 把一块圆形范围内的装饰实例缩成 0（建筑占地清理）。
##
## 为什么必须做：草丛/碎石/营火/木箱都是 MultiMesh 批绘的，建筑落上去以后
## 它们会从墙里/台阶里穿出来 —— 玩家看到的就是"地面破了"。
## 只动 transform（缩放到 0），不重建批次，一次调用几千次读写，建一座楼几毫秒。
static func clear_around(center: Vector3, radius: float) -> int:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null or radius <= 0.0:
		return 0
	var host: Node = 当前实例
	if host == null or not is_instance_valid(host):
		host = tree.root.find_child("地表细节", true, false)
	if host == null:
		return 0
	var r2: float = radius * radius
	var n: int = 0
	var stack: Array = [host]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		var mmi := cur as MultiMeshInstance3D
		if mmi != null and mmi.multimesh != null:
			var mm: MultiMesh = mmi.multimesh
			var cnt: int = mm.instance_count
			for i in cnt:
				var xf: Transform3D = mm.get_instance_transform(i)
				var dx: float = xf.origin.x - center.x
				var dz: float = xf.origin.z - center.z
				if dx * dx + dz * dz <= r2:
					mm.set_instance_transform(i,
							Transform3D(Basis.from_scale(Vector3.ZERO), xf.origin))
					n += 1
		for c in cur.get_children():
			stack.append(c)
	return n


# ===========================================================================
# 构建
# ===========================================================================
func _build() -> void:
	if _built or _data == null:
		return
	# 调试开关：GD_OFF=1 时整层不建（排查"这块地面到底是什么"用）
	if OS.has_environment("GD_OFF"):
		return
	_built = true
	_add_roads()
	_add_plaza()
	_add_grass()
	_add_flowers()
	_add_rubble()
	_add_procedural()
	_add_boulders()


# --- 土路 -------------------------------------------------------------------
func _add_roads() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris: int = 0
	for rd in _data.roads:
		tris += _append_road(st, rd)
	if tris == 0:
		return
	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "土路"
	mi.mesh = mesh
	mi.material_override = _road_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## 把一条路写成三角形带（顶点色里带车辙 / 边缘淡出 / 斑驳）
func _append_road(st: SurfaceTool, rd: Dictionary) -> int:
	var pts: PackedVector2Array = rd["pts"]
	if pts.size() < 2:
		return 0
	var width: float = float(rd["width"])
	var kind: String = String(rd.get("kind", "main"))
	# 小径更"野"：边缘更碎、颜色更浅
	var edge_jitter: float = 0.55 if kind == "trail" else 0.32
	# 偏灰的压实土：原来偏黄，远看像一块"沙地训练场"而不是路
	var base_col := Color(0.305, 0.275, 0.217)
	var rut_col := Color(0.238, 0.212, 0.163)
	if kind == "trail":
		base_col = Color(0.37, 0.33, 0.24)
		rut_col = Color(0.30, 0.26, 0.18)
	var samples := _densify(pts, ROAD_STEP)
	if samples.size() < 2:
		return 0
	var used: int = 0
	for i in range(samples.size() - 1):
		var a: Vector2 = samples[i]
		var b: Vector2 = samples[i + 1]
		if not _road_span_ok(a, b):
			continue
		var dir: Vector2 = (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var col_a: Array = []
		var col_b: Array = []
		for j in range(ROAD_COLS):
			var u: float = float(j) / float(ROAD_COLS - 1) * 2.0 - 1.0
			# 边缘抖动：让路肩不是尺子画的
			var jit: float = sin(float(i) * 0.9 + float(j) * 2.7) * edge_jitter
			var half: float = width * 0.5 + jit
			var pa: Vector2 = a + nrm * (u * half)
			var pb: Vector2 = b + nrm * (u * half) * (1.0 + 0.02 * sin(float(i) * 1.3))
			col_a.append(_road_vertex(pa, u, base_col, rut_col, i, j))
			col_b.append(_road_vertex(pb, u, base_col, rut_col, i + 1, j))
		for j in range(ROAD_COLS - 1):
			# v3.3：带 UV 输出（世界 XZ / 2.2m 一铺），这样路面能吃到
			# ground_dirt 的 albedo + 法线：砂粒、小石子、车辙凹槽全是贴图给的，
			# 不再是"一块平色带 + 顶点色噪点"。
			_road_tri(st, col_a[j]["p"], col_b[j]["p"], col_b[j + 1]["p"],
					col_a[j]["c"], col_b[j]["c"], col_b[j + 1]["c"])
			_road_tri(st, col_a[j]["p"], col_b[j + 1]["p"], col_a[j + 1]["p"],
					col_a[j]["c"], col_b[j + 1]["c"], col_a[j + 1]["c"])
			used += 1
	return used


## 路面三角形：顶点色 + 世界空间 UV（2.2m 一铺，和地表细节贴图同一尺度）
const ROAD_UV_SCALE: float = 2.2


func _road_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ca: Color, cb: Color, cc: Color) -> void:
	var inv: float = 1.0 / ROAD_UV_SCALE
	for i in 3:
		var v: Vector3 = [a, b, c][i]
		var col: Color = [ca, cb, cc][i]
		st.set_color(col)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x * inv, v.z * inv))
		st.add_vertex(v)


## 一个路顶点的位置 + 颜色（车辙在 |u|≈0.45，边缘 alpha 淡出）
func _road_vertex(p: Vector2, u: float, base: Color, rut: Color, si: int, sj: int) -> Dictionary:
	var au: float = absf(u)
	var c: Color = base
	if au > 0.28 and au < 0.66:
		c = rut.lerp(base, 0.30)
	var mottle: float = 0.94 + 0.07 * sin(float(si) * 1.63 + float(sj) * 2.11)
	c = Color(c.r * mottle, c.g * mottle, c.b * mottle, 1.0)
	# 边缘 3 列淡出到全透明
	var alpha: float = 1.0
	if au > 0.60:
		alpha = clampf(1.0 - (au - 0.60) / 0.40, 0.0, 1.0)
	c.a = alpha * 0.86
	if au < 0.20:
		c.a = 0.86
	var y: float = _h(p.x, p.y) + ROAD_LIFT
	return {"p": Vector3(p.x, y, p.y), "c": c}


## 这一段路是否贴着可走地面（悬崖/水里不画）
func _road_span_ok(a: Vector2, b: Vector2) -> bool:
	if MapGenerator.terrain_is_water(_data, a) or MapGenerator.terrain_is_water(_data, b):
		return false
	return MapGenerator._terrain_slope(_data, a) < 0.9 \
		and MapGenerator._terrain_slope(_data, b) < 0.9


# --- 台地顶集结场 -----------------------------------------------------------
func _add_plaza() -> void:
	if _data.plazas.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg: int = 26
	for pl in _data.plazas:
		var c: Vector2 = pl["pos"]
		var r: float = float(pl["radius"])
		var center := _ground_point(c, ROAD_LIFT + 0.012)
		for i in range(seg):
			var t0: float = TAU * float(i) / float(seg)
			var t1: float = TAU * float(i + 1) / float(seg)
			var p0: Vector2 = c + Vector2(cos(t0), sin(t0)) * r
			var p1: Vector2 = c + Vector2(cos(t1), sin(t1)) * r
			var v0 := _ground_point(p0, ROAD_LIFT + 0.010)
			var v1 := _ground_point(p1, ROAD_LIFT + 0.010)
			var cc := Color(0.42, 0.35, 0.25, 0.55)
			var ce := Color(0.38, 0.32, 0.23, 0.0)
			st.set_color(cc)
			st.set_normal(Vector3.UP)
			st.add_vertex(center)
			st.set_color(ce)
			st.set_normal(Vector3.UP)
			st.add_vertex(v0)
			st.set_color(ce)
			st.set_normal(Vector3.UP)
			st.add_vertex(v1)
	var mi := MeshInstance3D.new()
	mi.name = "台地集结场"
	mi.mesh = st.commit()
	mi.material_override = _road_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## 贴地高度：优先问关卡（地形网格被二次雕刻过），退回生成器高度
func _h(x: float, z: float) -> float:
	if _level != null and _level.has_method("height_at"):
		return float(_level.call("height_at", x, z))
	return _data.height_at(x, z)


func _ground_point(p: Vector2, lift: float) -> Vector3:
	return Vector3(p.x, _h(p.x, p.y) + lift, p.y)


# --- 草丛 / 碎石 / 关口巨石（复用装饰库现成场景） ---------------------------
func _add_grass() -> void:
	if _data.grass.is_empty():
		return
	var xf: Array = []
	var cols: Array = []
	for g in _data.grass:
		# v7 草叶比 v6 的"压扁球"高，但 RTS 镜头下 20cm 仍偏小；
		# 放大 1.3 倍 + 高度多给 1.45，草才有"没过脚踝"的层次。
		var gxf := _xf_from(g)
		gxf.basis = gxf.basis.scaled(Vector3(1.28, 1.45, 1.28))
		xf.append(gxf)
		var t: float = 0.82 + 0.30 * absf(sin(float(g["rot"]) * 3.7))
		# 草必须是绿的：合批材质吃顶点色，顶点色现在是白，全靠实例色染
		cols.append(Color(0.27 * t, 0.46 * t, 0.19 * t, 1.0))
	var mmi := RtsDecorLib.make_multimesh(&"grass", xf, cols)
	if mmi != null:
		mmi.name = "草丛"
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


## 野花：草丛位置的 1/4 撒小花，白/黄/紫/红四色。
## 为什么值得单独一批：RTS 俯视时"草"是一团绿，只有 2~3px 的彩色花点
## 能把地表尺度读出来（玩家会下意识觉得"这块地是活的"）。一个 MultiMesh，一次 draw call。
func _add_flowers() -> void:
	if _data.grass.is_empty():
		return
	var mesh := _mesh_flower()
	if mesh == null:
		return
	var palette := [Color(0.95, 0.93, 0.78), Color(1.0, 0.80, 0.22),
		Color(0.70, 0.45, 0.95), Color(0.86, 0.24, 0.22)]
	var xf: Array = []
	var cols: Array = []
	var i: int = 0
	for g in _data.grass:
		i += 1
		if i % 4 != 0:
			continue
		var base_xf := _xf_from(g)
		var s: float = 0.72 + 0.55 * absf(sin(float(g["rot"]) * 7.3 + float(g["pos"].x) * 0.9))
		var basis := base_xf.basis.scaled(Vector3(1.0, 1.0, 1.0))
		var p2: Vector3 = base_xf.origin
		xf.append(Transform3D(basis.scaled(Vector3.ONE * s), p2))
		cols.append(palette[(i / 4) % palette.size()])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.use_colors = true
	mm.instance_count = xf.size()
	for k in xf.size():
		mm.set_instance_transform(k, xf[k])
		mm.set_instance_color(k, cols[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "野花"
	mmi.multimesh = mm
	mmi.material_override = _decor_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## 一朵野花：细茎 + 三片交叉花瓣（6 个三角）。颜色由实例色染。
func _mesh_flower() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stem := Color(0.22, 0.42, 0.14)
	var petal := Color(0.92, 0.92, 0.86)
	# 茎：两根交叉的细三角
	for k in 2:
		var a: float = float(k) * PI * 0.5
		var dx: float = cos(a) * 0.012
		var dz: float = sin(a) * 0.012
		_tri(st, Vector3(-dx, 0.0, -dz), Vector3(dx, 0.0, dz), Vector3(0.0, 0.24, 0.0), stem)
	# 花瓣：三片小三角绕中心
	for k in 3:
		var a2: float = TAU * float(k) / 3.0 + 0.4
		var c := Vector3(cos(a2) * 0.055, 0.235, sin(a2) * 0.055)
		var o := Vector3(cos(a2 + 1.5708) * 0.018, 0.245, sin(a2 + 1.5708) * 0.018)
		_tri(st, c - o, c + o, Vector3(0.0, 0.27, 0.0), petal)
	return st.commit()


func _add_rubble() -> void:
	if _data.rubble.is_empty():
		return
	var xf: Array = []
	var cols: Array = []
	for r in _data.rubble:
		xf.append(_xf_from(r))
		var t: float = 0.62 + 0.24 * absf(sin(float(r["rot"]) * 5.1 + float(r["pos"].x)))
		cols.append(Color(t, t * 0.98, t * 0.94, 1.0))
	var mmi := RtsDecorLib.make_multimesh(&"rubble", xf, cols)
	if mmi != null:
		mmi.name = "碎石"
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


## 关口两侧的大块碎石（复用岩石场景，放大）
func _add_boulders() -> void:
	var arr: Array = _data.decor.get("boulder", [])
	if arr.is_empty():
		return
	var xf: Array = []
	var cols: Array = []
	for e in arr:
		xf.append(_xf_from(e))
		var t: float = 0.62 + 0.20 * absf(sin(float(e["rot"]) * 2.9))
		cols.append(Color(t, t * 0.95, t * 0.86, 1.0))
	var mmi := RtsDecorLib.make_multimesh(&"rubble", xf, cols)
	if mmi != null:
		mmi.name = "关口巨石"
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


# --- 程序化装饰（基础几何烘成一份网格） -------------------------------------
func _add_procedural() -> void:
	for kind in ["mushroom", "dead_tree", "crate", "barrel", "fence", "campfire", "log", "wall", "tent"]:
		var arr: Array = _data.decor.get(kind, [])
		if arr.is_empty():
			continue
		var mesh := _mesh_for(kind)
		if mesh == null:
			continue
		var xf: Array = []
		var cols: Array = []
		for e in arr:
			xf.append(_xf_from(e))
			var tint: float = 0.86 + 0.22 * absf(sin(float(e["rot"]) * 4.3 + float(e["pos"].x) * 0.7))
			cols.append(Color(tint, tint, tint, 1.0))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.use_colors = true
		mm.instance_count = xf.size()
		for i in xf.size():
			mm.set_instance_transform(i, xf[i])
			mm.set_instance_color(i, cols[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "装饰_%s" % kind
		mmi.multimesh = mm
		mmi.material_override = _decor_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# 不设 visibility_range：整批覆盖全图，按包围盒中心算距离会整批闪没
		add_child(mmi)


## 统一变换：位置 + 绕 Y 旋转 + 轻微倾倒 + 缩放
func _xf_from(e: Dictionary) -> Transform3D:
	var basis := Basis(Vector3.UP, float(e.get("rot", 0.0)))
	var tilt: Vector2 = e.get("tilt", Vector2.ZERO)
	if tilt != Vector2.ZERO:
		basis = basis * Basis(Vector3.RIGHT, tilt.x) * Basis(Vector3.FORWARD, tilt.y)
	var s: float = float(e.get("scale", 1.0))
	basis = basis.scaled(Vector3.ONE * s)
	var p: Vector3 = e["pos"]
	# 保留生成时的贴地偏移（巨石 -0.25 / 路边碎石 +0.02），把基准换成关卡的雕刻后高度
	var dy: float = p.y - _data.height_at(p.x, p.z)
	return Transform3D(basis, Vector3(p.x, _h(p.x, p.z) + dy, p.z))


# ===========================================================================
# 材质
# ===========================================================================
func _road_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1, 1, 1, 1)
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 1.0
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# 2026-10-18：路面接上 ground_dirt 的细节层（albedo 乘顶点色 + 法线）。
	# 均值 0.9 的细节层乘上来不会改变路面基色，只是把"平色带"变成"有砂有石"。
	var ap := "res://美术/贴图/ground_dirt_albedo.png"
	var np := "res://美术/贴图/ground_dirt_normal.png"
	if ResourceLoader.exists(ap):
		m.albedo_texture = load(ap)
	if ResourceLoader.exists(np):
		m.normal_enabled = true
		m.normal_texture = load(np)
		m.normal_scale = 0.9
	return m


static func _decor_material() -> StandardMaterial3D:
	if _mat != null:
		return _mat
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1, 1, 1, 1)
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.96
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_mat = m
	return m


# ===========================================================================
# 程序化网格（基础几何 + 顶点色）
# ===========================================================================
func _mesh_for(kind: String) -> ArrayMesh:
	match kind:
		"crate":
			return _mesh_crate()
		"barrel":
			return _mesh_barrel()
		"fence":
			return _mesh_fence()
		"campfire":
			return _mesh_campfire()
		"log":
			return _mesh_log()
		"wall":
			return _mesh_wall()
		"mushroom":
			return _mesh_mushroom()
		"dead_tree":
			return _mesh_dead_tree()
		"tent":
			return _mesh_tent()
	return null


func _mesh_crate() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wood := Color(0.46, 0.34, 0.21)
	var dark := Color(0.33, 0.23, 0.14)
	var body := BoxMesh.new()
	body.size = Vector3(0.86, 0.66, 0.86)
	_bake(st, body, Transform3D(Basis.IDENTITY, Vector3(0, 0.33, 0)), wood)
	var slat := BoxMesh.new()
	slat.size = Vector3(0.92, 0.10, 0.92)
	_bake(st, slat, Transform3D(Basis.IDENTITY, Vector3(0, 0.10, 0)), dark)
	_bake(st, slat, Transform3D(Basis.IDENTITY, Vector3(0, 0.56, 0)), dark)
	var post := BoxMesh.new()
	post.size = Vector3(0.10, 0.70, 0.10)
	for sx in [-0.42, 0.42]:
		for sz in [-0.42, 0.42]:
			_bake(st, post, Transform3D(Basis.IDENTITY, Vector3(sx, 0.35, sz)), dark)
	return st.commit()


func _mesh_barrel() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wood := Color(0.45, 0.32, 0.19)
	var iron := Color(0.25, 0.24, 0.22)
	var body := CylinderMesh.new()
	body.top_radius = 0.31
	body.bottom_radius = 0.35
	body.height = 0.84
	body.radial_segments = 10
	body.rings = 1
	_bake(st, body, Transform3D(Basis.IDENTITY, Vector3(0, 0.42, 0)), wood)
	var ring := CylinderMesh.new()
	ring.top_radius = 0.375
	ring.bottom_radius = 0.375
	ring.height = 0.07
	ring.radial_segments = 10
	ring.rings = 1
	_bake(st, ring, Transform3D(Basis.IDENTITY, Vector3(0, 0.22, 0)), iron)
	_bake(st, ring, Transform3D(Basis.IDENTITY, Vector3(0, 0.66, 0)), iron)
	return st.commit()


func _mesh_fence() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wood := Color(0.42, 0.31, 0.19)
	var dark := Color(0.33, 0.24, 0.14)
	var post := BoxMesh.new()
	post.size = Vector3(0.15, 1.05, 0.15)
	_bake(st, post, Transform3D(Basis.IDENTITY, Vector3(-0.95, 0.52, 0)), wood)
	_bake(st, post, Transform3D(Basis.IDENTITY, Vector3(0.95, 0.52, 0)), dark)
	var rail := BoxMesh.new()
	rail.size = Vector3(2.0, 0.11, 0.08)
	_bake(st, rail, Transform3D(Basis.IDENTITY, Vector3(0, 0.58, 0)), wood)
	_bake(st, rail, Transform3D(Basis(Vector3.FORWARD, 0.05), Vector3(0, 0.90, 0)), dark)
	# 断掉的一截斜搭在一边
	var broken := BoxMesh.new()
	broken.size = Vector3(0.9, 0.10, 0.08)
	_bake(st, broken, Transform3D(Basis(Vector3.FORWARD, -0.55), Vector3(0.62, 0.28, 0.05)), wood)
	return st.commit()


func _mesh_campfire() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stone := Color(0.50, 0.48, 0.44)
	var char := Color(0.14, 0.12, 0.10)
	var ember := Color(0.80, 0.33, 0.10)
	var pebble := SphereMesh.new()
	pebble.radius = 0.17
	pebble.height = 0.30
	pebble.radial_segments = 6
	pebble.rings = 3
	for i in range(9):
		var a: float = TAU * float(i) / 9.0
		var p := Vector3(cos(a) * 0.78, 0.10, sin(a) * 0.78)
		_bake(st, pebble, Transform3D(Basis.IDENTITY.scaled(Vector3(1.0, 0.75, 1.1)), p), stone)
	var ash := CylinderMesh.new()
	ash.top_radius = 0.60
	ash.bottom_radius = 0.62
	ash.height = 0.07
	ash.radial_segments = 10
	ash.rings = 1
	_bake(st, ash, Transform3D(Basis.IDENTITY, Vector3(0, 0.035, 0)), char)
	var coal := CylinderMesh.new()
	coal.top_radius = 0.30
	coal.bottom_radius = 0.30
	coal.height = 0.05
	coal.radial_segments = 8
	coal.rings = 1
	_bake(st, coal, Transform3D(Basis.IDENTITY, Vector3(0, 0.075, 0)), ember)
	# 三根柴火交叉
	var stick := CylinderMesh.new()
	stick.top_radius = 0.06
	stick.bottom_radius = 0.08
	stick.height = 0.95
	stick.radial_segments = 5
	stick.rings = 1
	for i in range(3):
		var a2: float = TAU * float(i) / 3.0 + 0.3
		var b := Basis(Vector3.UP, a2) * Basis(Vector3.RIGHT, PI * 0.42)
		_bake(st, stick, Transform3D(b, Vector3(cos(a2) * 0.18, 0.30, sin(a2) * 0.18)), char.lerp(ember, 0.35))
	return st.commit()


func _mesh_log() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := Color(0.36, 0.27, 0.17)
	var cut := Color(0.56, 0.44, 0.29)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.16
	cyl.bottom_radius = 0.19
	cyl.height = 1.9
	cyl.radial_segments = 7
	cyl.rings = 1
	_bake(st, cyl, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(0, 0.18, 0)), bark)
	# 两根短柴
	var short := CylinderMesh.new()
	short.top_radius = 0.12
	short.bottom_radius = 0.13
	short.height = 1.1
	short.radial_segments = 6
	short.rings = 1
	_bake(st, short, Transform3D(Basis(Vector3.UP, 1.0) * Basis(Vector3.FORWARD, PI * 0.5),
		Vector3(0.35, 0.14, 0.3)), cut)
	return st.commit()


func _mesh_wall() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stone := Color(0.56, 0.50, 0.41)
	var dark := Color(0.42, 0.37, 0.30)
	var b1 := BoxMesh.new()
	b1.size = Vector3(2.5, 1.15, 0.62)
	_bake(st, b1, Transform3D(Basis.IDENTITY, Vector3(0, 0.57, 0)), stone)
	# 顶上一段残垛
	var b2 := BoxMesh.new()
	b2.size = Vector3(0.95, 0.55, 0.60)
	_bake(st, b2, Transform3D(Basis.IDENTITY, Vector3(-0.62, 1.40, 0)), dark)
	# 塌下来的半块
	var b3 := BoxMesh.new()
	b3.size = Vector3(1.0, 0.5, 0.55)
	_bake(st, b3, Transform3D(Basis(Vector3.FORWARD, 0.28), Vector3(1.35, 0.24, 0.18)), dark)
	# 砖缝：几块浅色小方块
	var brick := BoxMesh.new()
	brick.size = Vector3(0.45, 0.26, 0.66)
	for i in range(3):
		_bake(st, brick, Transform3D(Basis.IDENTITY,
			Vector3(-0.8 + float(i) * 0.8, 0.32 + 0.28 * float(i % 2), 0.0)), dark)
	return st.commit()


## 军用帐篷：三棱柱 + 深色门帘 + 两根撑杆
## 蘑菇（v3.3 重写：口径 0 个，但保留实现，别让编译链断）
func _mesh_mushroom() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stem := CylinderMesh.new()
	stem.top_radius = 0.045
	stem.bottom_radius = 0.07
	stem.height = 0.22
	stem.radial_segments = 6
	stem.rings = 1
	_bake(st, stem, Transform3D(Basis.IDENTITY, Vector3(0, 0.11, 0)), Color(0.86, 0.83, 0.74))
	var cap := SphereMesh.new()
	cap.radius = 0.16
	cap.height = 0.18
	cap.radial_segments = 8
	cap.rings = 4
	_bake(st, cap, Transform3D(Basis.IDENTITY, Vector3(0, 0.24, 0)), Color(0.62, 0.28, 0.22))
	return st.commit()


## 枯树（v3.3 重写：口径 0 棵，但保留实现）
func _mesh_dead_tree() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := Color(0.30, 0.24, 0.18)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.09
	trunk.bottom_radius = 0.20
	trunk.height = 2.1
	trunk.radial_segments = 6
	trunk.rings = 1
	_bake(st, trunk, Transform3D(Basis.IDENTITY, Vector3(0, 1.05, 0)), bark)
	for i in range(3):
		var br := CylinderMesh.new()
		br.top_radius = 0.03
		br.bottom_radius = 0.07
		br.height = 0.95
		br.radial_segments = 5
		br.rings = 1
		var ang: float = TAU * float(i) / 3.0 + 0.4
		var xf := Transform3D(Basis(Vector3.UP, ang) * Basis(Vector3.RIGHT, -0.9),
				Vector3(cos(ang) * 0.34, 1.75 + i * 0.12, sin(ang) * 0.34))
		_bake(st, br, xf, bark)
	return st.commit()


## 帐篷 v2：**会塌的 A 字帐**（脊线中段下垂、四角拉绳 + 地钉）。
##
## 旧版是一个 PrismMesh 三棱柱：直脊、零细节，远看像一块三角蛋糕。
## 魔兽3 的帐篷读的是"布"：脊线被自重压弯、布面有斜向的拉绳、下摆外撇。
## 这里全部用显式顶点写，脊线取 5 段做下垂，布面法线按三角面算。
func _mesh_tent() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var canvas := Color(0.50, 0.43, 0.31)
	var canvas_d := Color(0.37, 0.31, 0.22)
	var wood := Color(0.36, 0.27, 0.17)
	var dark := Color(0.10, 0.09, 0.07)

	var w: float = 1.35      # 半宽
	var ln: float = 1.45     # 半长
	var h: float = 1.62      # 脊高
	var seg: int = 5

	# 脊线（中点下垂 0.13m → 布的自重）
	var ridge: Array[Vector3] = []
	for i in range(seg + 1):
		var t: float = float(i) / float(seg)
		var z: float = -ln + 2.0 * ln * t
		var sag: float = 0.13 * sin(PI * t)
		ridge.append(Vector3(0.0, h - sag, z))

	# 两侧布面：脊线 → 底边（底边外撇 0.10m）
	for side in [-1.0, 1.0]:
		for i in range(seg):
			var a: Vector3 = ridge[i]
			var b: Vector3 = ridge[i + 1]
			var a2: Vector3 = Vector3(side * (w + 0.10), 0.02, a.z)
			var b2: Vector3 = Vector3(side * (w + 0.10), 0.02, b.z)
			var col := canvas if side > 0.0 else canvas_d
			_tri(st, a, a2, b2, col)
			_tri(st, a, b2, b, col)

	# 前后山墙（前脸留门洞：用更深的一块布 + 深色门帘）
	for zs in [-1.0, 1.0]:
		var back: bool = zs < 0.0
		var a: Vector3 = ridge[0] if back else ridge[seg]
		var l: Vector3 = Vector3(-w, 0.02, a.z)
		var r: Vector3 = Vector3(w, 0.02, a.z)
		_tri(st, a, l, r, canvas_d)
		if not back:
			# 门帘：比帐身更暗，往内凹 0.10m
			var dz: float = a.z - 0.10
			_tri(st, Vector3(0.0, a.y - 0.10, dz), Vector3(-0.44, 0.05, dz),
					Vector3(0.44, 0.05, dz), dark)

	# 四角地钉 + 拉绳
	var peg := CylinderMesh.new()
	peg.top_radius = 0.035
	peg.bottom_radius = 0.02
	peg.height = 0.26
	peg.radial_segments = 5
	peg.rings = 1
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var p := Vector3(sx * (w + 0.55), 0.11, sz * (ln + 0.25))
			_bake(st, peg, Transform3D(Basis.IDENTITY, p), wood)
			# 绳：从帐顶角拉到地钉（一根细三棱柱）
			var top := Vector3(sx * w * 0.7, h * 0.72, sz * ln * 0.75)
			_rope(st, top, p + Vector3(0, 0.1, 0), canvas_d)

	# 门口一根撑杆 + 小三角旗
	var pole := CylinderMesh.new()
	pole.top_radius = 0.035
	pole.bottom_radius = 0.045
	pole.height = 1.95
	pole.radial_segments = 5
	pole.rings = 1
	_bake(st, pole, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.97, ln + 0.14)), wood)
	_tri(st, Vector3(0.02, 1.86, ln + 0.14), Vector3(0.02, 1.54, ln + 0.14),
			Vector3(0.42, 1.70, ln + 0.14), Color(0.62, 0.20, 0.16))
	_tri(st, Vector3(0.02, 1.86, ln + 0.14), Vector3(0.42, 1.70, ln + 0.14),
			Vector3(0.02, 1.54, ln + 0.14), Color(0.52, 0.16, 0.13))
	return st.commit()


## 一根绳子：两点之间挤出一个细三棱柱（不做圆柱，省 60% 三角面）
func _rope(st: SurfaceTool, a: Vector3, b: Vector3, col: Color) -> void:
	var d: Vector3 = (b - a).normalized()
	var side: Vector3 = d.cross(Vector3.UP)
	if side.length() < 0.01:
		side = Vector3.RIGHT
	side = side.normalized() * 0.022
	var up2: Vector3 = side.cross(d).normalized() * 0.022
	_tri(st, a + side, a - side, b - side, col)
	_tri(st, a + side, b - side, b + side, col)
	_tri(st, a + up2, b + up2, a - up2, col)


## 一个带法线的三角面（法线按右手定则算，颜色写顶点色）
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length() < 0.000001:
		return
	n = n.normalized()
	for v in [a, b, c]:
		st.set_color(col)
		st.set_normal(n)
		st.add_vertex(v)


static func _bake(st: SurfaceTool, mesh: Mesh, xf: Transform3D, col: Color) -> void:
	for s in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		var has_idx: bool = idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0
		if has_idx:
			var ii: PackedInt32Array = idx
			for k in ii:
				st.set_color(col)
				st.set_normal((xf.basis * norms[k]).normalized())
				st.add_vertex(xf * verts[k])
		else:
			for k in range(verts.size()):
				st.set_color(col)
				st.set_normal((xf.basis * norms[k]).normalized())
				st.add_vertex(xf * verts[k])


## 按弧长重采样（渲染用，比生成器的 2m 更密）
static func _densify(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if pts.size() < 2:
		return pts
	out.append(pts[0])
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg: float = a.distance_to(b)
		if seg < 0.001:
			continue
		var n: int = maxi(1, int(ceil(seg / step)))
		for k in range(1, n + 1):
			out.append(a.lerp(b, float(k) / float(n)))
	return out