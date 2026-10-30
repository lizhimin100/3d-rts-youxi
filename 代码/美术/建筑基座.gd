extends MeshInstance3D
## **建筑地基台（RtsBuildingPad）** —— 每座建筑脚下那圈"被踩实的地"。
##
## 为什么必须要有它（2026-10-23）：
##   地形顶点色是 1.8m 一格的低频噪声，建筑直接落在上面时，落地线会穿过
##   一格"黄褐干草斑"，读起来像地面破了个洞 —— 玩家原话"兵营地面出现异常"。
##   这里给每座建筑铺一圈**贴地的夯土地台**（外缘 alpha 淡出到草地）+ 一圈
##   半埋的石砌镶边，把建筑与地形的接缝压成一条"人工地基"，视觉上就闭合了。
##
## 三条纪律：
##   1. 逐顶点采样地形高度（不是一块平板），坡地上不会翘起或埋进土里；
##   2. 外缘 alpha 归零 + 三层扇环，草地的绿能"渗"进土台，边缘不是硬切的圆盘；
##   3. 纯视觉：不进寻路、不投影、一份 mesh 两个 surface（地表 / 石砌），只有 1 次 draw。

## 台面抬升（米）：贴地但不 z-fighting
## 抬到 0.13：土路是抬 0.10 的，地基台必须压在它上面，否则路面从台子里穿出来
const LIFT := 0.13
## 土台外扩（米）：比占地大一圈，才有"建筑周围被清出来"的感觉
const OUTER := 2.25
## 土台内收（米）：内圈压在建筑底边里面，避免看到建筑底下漏草
const INNER := -0.35
## 每条边细分（圆角矩形的圆滑程度）
const SEG := 7
## 石砌镶边块数
const CURB_N := 14

## 两侧地表色（夯土 / 被踩实的浅土）：低饱和灰褐，比草地亮半档 ——
## 偏黄会读成"枯草"，偏红会读成"泥浆"，中性灰褐才是"压实的土地"。
## 注意：unshaded 材质下顶点色按**线性**空间写，屏幕上会亮一档。
## 想要 sRGB≈0.36 的灰褐，这里就得写 0.11 左右（不是 0.39）。
const COL_PACKED := Color(0.112, 0.094, 0.072, 1.0)
const COL_LIGHT := Color(0.148, 0.128, 0.100, 1.0)
## 石砌镶边色
const COL_STONE := Color(0.255, 0.243, 0.218, 1.0)
const COL_STONE_D := Color(0.162, 0.154, 0.138, 1.0)

static var _mat_ground: StandardMaterial3D = null
static var _mat_stone: StandardMaterial3D = null

var _footprint: Vector2i = Vector2i(4, 4)
var _hx: float = 2.0
var _hz: float = 2.0
var _built: bool = false


## 挂到建筑上（visual 建好之后调；坐标是建筑本地空间）
static func attach(host: Node3D, footprint: Vector2i) -> Node3D:
	if host == null:
		return null
	var sc: Script = load("res://代码/美术/建筑基座.gd")
	if sc == null:
		return null
	var pad: Node3D = sc.new()
	pad.name = "地基台"
	pad._footprint = footprint if footprint != Vector2i.ZERO else Vector2i(4, 4)
	pad._hx = float(pad._footprint.x) * 0.5
	pad._hz = float(pad._footprint.y) * 0.5
	host.add_child(pad)
	# 放在最前面画（不影响深度，但 2D 层序上先于建筑）
	pad.material_override = null
	pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pad.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	pad.build()
	return pad


func build() -> void:
	if _built:
		return
	_built = true
	mesh = _make_mesh()
	for i in mesh.get_surface_count():
		set_surface_override_material(i, _mat_ground if i == 0 else _mat_stone)
	if OS.has_environment("PAD_DEBUG"):
		for i in mesh.get_surface_count():
			var arr: Array = mesh.surface_get_arrays(i)
			print("[PAD] surf%d v=%d n=%d c=%d idx=%s pos=%s" % [i,
				(arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
				(arr[Mesh.ARRAY_NORMAL] as PackedVector3Array).size(),
				(arr[Mesh.ARRAY_COLOR] as PackedColorArray).size(),
				str(arr[Mesh.ARRAY_INDEX]), str(global_position)])
	# 顺带把压在占地里的营火/木箱/草丛清掉（装饰是 MultiMesh 批绘的，压进墙里很难看）。
	# ★ 必须延迟：地表细节层是下一帧才挂到关卡上的，立刻清会扑空。
	var r: float = maxf(_hx, _hz) + OUTER + 0.35
	var cleared: int = RtsGroundDetail.clear_around(global_position, r)
	if OS.has_environment("PAD_DEBUG"):
		print("[PAD] clear1=", cleared, " r=", r, " pos=", global_position)
	_clear_later(r)


func _clear_later(r: float) -> void:
	if not is_inside_tree():
		return
	for _i in 8:
		await get_tree().process_frame
		if not is_instance_valid(self):
			return
		var c: int = RtsGroundDetail.clear_around(global_position, r)
		if OS.has_environment("PAD_DEBUG") and c > 0:
			print("[PAD] clear_late=", c)


# ===========================================================================
# 几何
# ===========================================================================

## 圆角矩形轮廓：t 取 0..1 绕一圈，返回 (x, z) 的本地坐标
func _ring_point(t: float, scale: float) -> Vector2:
	var ang: float = TAU * t
	# 超椭圆（圆角矩形）：指数 4 的圆角比方盒子好看，也不像纯圆盘
	var c: float = cos(ang)
	var s: float = sin(ang)
	var p: float = 4.0
	var ax: float = signf(c) * pow(absf(c), 2.0 / p)
	var az: float = signf(s) * pow(absf(s), 2.0 / p)
	return Vector2(ax * (_hx + scale), az * (_hz + scale))


## 相对建筑的贴地高度。
##
## ★ 必须用"两点地形高度之差"，不能用 地形高度 - 建筑 global_position.y：
##   建筑 y 由关卡写入，可能比 height_at 多一个基准偏移（低地基地），
##   两者一减就会把整块台子埋进地下 1m，渲染出来是一圈黑洞。
var _base_h: float = 0.0

func _ground_y(wx: float, wz: float) -> float:
	var gy: float = RtsWorld.height_at(wx, wz) - _base_h
	return clampf(gy, -0.45, 0.45)


func _make_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n: int = SEG * 4
	# 三条环：内圈(土台主体) / 中圈 / 外圈(alpha=0)
	# 环形分带：0.0 -> INNER, 0.55 -> 中, 1.0 -> OUTER
	var rings: Array = [INNER, OUTER * 0.55, OUTER]
	var alphas: Array = [1.0, 0.94, 0.0]
	var cols: Array = [COL_PACKED, COL_PACKED, COL_LIGHT]
	var pts: Array = []
	var ys: Array = []
	var colr: Array = []
	var base: Vector3 = global_position
	_base_h = RtsWorld.height_at(base.x, base.z)
	for ri in rings.size():
		var line_pts: Array = []
		var line_col: Array = []
		for i in n + 1:
			var t: float = float(i) / float(n)
			var q := _ring_point(t, float(rings[ri]))
			var wy: float = _ground_y(base.x + q.x, base.z + q.y)
			var lift: float = LIFT if ri < 2 else LIFT * 0.62
			var wob: float = 1.0 + 0.035 * sin(t * TAU * 3.0 + base.z * 0.11) \
					+ 0.018 * sin(t * TAU * 7.0 + base.x * 0.07)
			line_pts.append(Vector3(q.x * wob, wy + lift, q.y * wob))
			var c: Color = cols[ri]
			# 斑驳：按角度做一点明度起伏，土台才不像塑料
			var m: float = 0.90 + 0.16 * absf(sin(t * TAU * 5.0 + float(ri) * 1.7))
			c = Color(c.r * m, c.g * m, c.b * m, float(alphas[ri]))
			line_col.append(c)
		pts.append(line_pts)
		colr.append(line_col)

	# 环带三角
	for ri in rings.size() - 1:
		var a: Array = pts[ri]
		var b: Array = pts[ri + 1]
		var ca: Array = colr[ri]
		var cb: Array = colr[ri + 1]
		for i in n:
			_tri(st, a[i], a[i + 1], b[i + 1], ca[i], ca[i + 1], cb[i + 1])
			_tri(st, a[i], b[i + 1], b[i], ca[i], cb[i + 1], cb[i])

	var ground := st.commit()
	# --- 石砌镶边（第二个 surface）---
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in CURB_N:
		var t2: float = (float(k) + 0.5) / float(CURB_N)
		var p2 := _ring_point(t2, INNER + 0.18)
		var hy: float = _ground_y(base.x + p2.x, base.z + p2.y)
		var sz: float = 0.34 + 0.10 * absf(sin(float(k) * 2.1 + base.x))
		var hgt: float = 0.16 + 0.07 * absf(sin(float(k) * 3.7))
		# 每块石头沿环切线转一点，读起来是"砌"出来的
		var tan := _ring_point(t2 + 0.004, INNER + 0.18) - p2
		var yaw: float = tan.angle()
		_box(st2, Vector3(sz, hgt, sz * 0.62),
				Vector3(p2.x, hy + hgt * 0.42, p2.y), yaw,
				COL_STONE if k % 3 else COL_STONE_D)
	var stone := st2.commit()

	var out := ArrayMesh.new()
	for s in [ground, stone]:
		for si in s.get_surface_count():
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.surface_get_arrays(si))
	return out


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ca: Color, cb: Color, cc: Color) -> void:
	var nrm: Vector3 = Vector3.UP
	if absf((b - a).cross(c - a).length()) < 0.000001:
		return
	for i in 3:
		st.set_color([ca, cb, cc][i])
		st.set_normal(nrm)
		st.set_uv(Vector2([a, b, c][i].x, [a, b, c][i].z) * 0.42)
		st.add_vertex([a, b, c][i])


## 一个带朝向的盒子（12 个三角，顶点色）
func _box(st: SurfaceTool, size: Vector3, pos: Vector3, yaw: float, col: Color) -> void:
	var b := Basis(Vector3.UP, yaw)
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var faces: Array = [
		[Vector3(0, 0, 1), [[-hx, -hy, hz], [hx, -hy, hz], [hx, hy, hz], [-hx, hy, hz]]],
		[Vector3(0, 0, -1), [[hx, -hy, -hz], [-hx, -hy, -hz], [-hx, hy, -hz], [hx, hy, -hz]]],
		[Vector3(1, 0, 0), [[hx, -hy, hz], [hx, -hy, -hz], [hx, hy, -hz], [hx, hy, hz]]],
		[Vector3(-1, 0, 0), [[-hx, -hy, -hz], [-hx, -hy, hz], [-hx, hy, hz], [-hx, hy, -hz]]],
		[Vector3(0, 1, 0), [[-hx, hy, hz], [hx, hy, hz], [hx, hy, -hz], [-hx, hy, -hz]]],
	]
	for f in faces:
		var ln: Vector3 = f[0]
		var vs: Array = f[1]
		var wv: Array = []
		for v in vs:
			wv.append(pos + b * Vector3(v[0], v[1], v[2]))
		var nrm: Vector3 = (b * ln).normalized()
		# 顶面亮一点，侧面压暗：低多边形石块的体积感全靠这个
		var shade: float = 1.0 if ln.y > 0.5 else (0.80 if absf(ln.y) < 0.5 and ln.x != 0.0 else 0.70)
		var c: Color = Color(col.r * shade, col.g * shade, col.b * shade, 1.0)
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_color(c)
			st.set_normal(nrm)
			st.set_uv(Vector2(wv[idx].x, wv[idx].z) * 0.5)
			st.add_vertex(wv[idx])


# ===========================================================================
# 材质
# ===========================================================================

static func _ground_material_get() -> StandardMaterial3D:
	if _mat_ground != null:
		return _mat_ground
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1, 1, 1, 1)
	m.vertex_color_use_as_albedo = true
	# ★ 无光照：这层是"画在地形上的夯土台"，和地表草丛/碎石同族。
	#   走受光材质时会被建筑投影压成一圈黑洞（实测：法线、GI 模式都不是原因，
	#   就是阴影）；而低多边形地表本来就是顶点色直接上屏，这样两层的明度才一致。
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 1.0
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# 不挂 albedo 贴图：ground_dirt 自带黄绿色偏，乘上去会把夯土台染成"枯草"。
	# 台面的细节靠顶点色斑驳 + 石砌镶边，尺度对了就不会糊。
	_mat_ground = m
	return m


static func _stone_material_get() -> StandardMaterial3D:
	if _mat_stone != null:
		return _mat_stone
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1, 1, 1, 1)
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.roughness = 1.0
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_mat_stone = m
	return m


func _init() -> void:
	pass


func _ready() -> void:
	_mat_ground = _ground_material_get()
	_mat_stone = _stone_material_get()
	if not _built:
		build()


static func clear_cache() -> void:
	_mat_ground = null
	_mat_stone = null
