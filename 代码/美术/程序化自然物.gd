@tool
class_name ProcProp
extends RefCounted
## **程序化自然物**：岩石 / 草丛。和树同一套思路 —— 给种子，长出网格，不占资源文件。
##
## 为什么岩石和草丛值得程序化（而木桶/栅栏/帐篷不值得）：
##   · 岩石和草是**自然物**，本来就"每块都不一样"；模型复用到第 5 块时，
##     玩家一眼就能看出是一片复制粘贴（尤其 26 块石头同一轮廓）；
##   · 木桶/栅栏/帐篷是人造物，**同一个样式才是对的**（铁匠铺的桶就该长一个样），
##     给它们上算法只会让场景变得不可控。
##
## 两个都和树**共用一张图集、一个材质**（TreeLibrary.material()）：
##   · 岩石 → UV 取不透明区，靠顶点色出颜色 + 顶点 AO；
##   · 草丛 → UV 取图集左上的"草叶区"，**顶点色只放明暗（白/灰）**，
##     绿色由合批的实例色染（沿用 地表细节 现有的染色管线，不改它的口径）。
##
## 变体数就是 draw call 数（每种变体一次合批），所以刻意压小：
##   岩石 4 个变体（形状差别大，值得分 4 批）／草丛 1 个变体（靠旋转+实例色出变化）。

## 岩石变体数 → 岩石合批的 draw call 数
const ROCK_VARIANTS := 4
## 草丛变体数（1 = 单批；想更花可以加到 4，代价是多 3 次 draw call）
const GRASS_VARIANTS := 1

const KIND_ROCK := "岩石"
const KIND_GRASS := "草丛"

## 岩石基色（在 2.35 的暖主光下大约出 0.5 的灰，太亮就成石膏）
const ROCK_DARK := Color(0.042, 0.043, 0.045)
const ROCK_LIGHT := Color(0.125, 0.127, 0.130)
## 苔痕（朝上的面掺一点）
const MOSS := Color(0.072, 0.118, 0.044)

static var _cache: Dictionary = {}
static var _gen_ms: float = 0.0
static var _rock_mat: StandardMaterial3D = null


# ===========================================================================
# 对外
# ===========================================================================

static func variants(kind: String) -> int:
	return ROCK_VARIANTS if kind == KIND_ROCK else GRASS_VARIANTS


## 取（并缓存）一份自然物网格。variant 取模到合法范围，调用方不用管。
static func mesh(kind: String, variant: int) -> ArrayMesh:
	var n: int = maxi(1, variants(kind))
	var v: int = ((variant % n) + n) % n
	var key := "%s|%d" % [kind, v]
	if _cache.has(key):
		return _cache[key]
	var t0: int = Time.get_ticks_usec()
	var m: ArrayMesh
	match kind:
		KIND_ROCK:
			m = _build_rock(v)
		_:
			m = _build_grass(v)
	_gen_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	_cache[key] = m
	return m


## 岩石专用材质：**不贴图、不 alpha scissor**。
## 石头是实心的，借树那张带镂空的图集只会给自己找麻烦（远处 mip 一混，
## alpha 掉到阈值以下是整块消失、只剩影子）；顶点色已经带了颜色和 AO。
static func rock_material() -> StandardMaterial3D:
	if _rock_mat != null:
		return _rock_mat
	var m := StandardMaterial3D.new()
	m.resource_name = "程序化岩石"
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1, 1, 1, 1)
	m.cull_mode = BaseMaterial3D.CULL_BACK
	m.roughness = 0.92
	m.metallic = 0.0
	m.metallic_specular = 0.14
	_rock_mat = m
	return m


static func stats() -> Dictionary:
	return {"种类": _cache.size(), "生成耗时ms": snappedf(_gen_ms, 0.01)}


static func clear_cache() -> void:
	_cache.clear()
	_gen_ms = 0.0


# ===========================================================================
# 岩石
# ===========================================================================

## 二十面体细分一次 → 80 面，按噪声推拉半径。
## 为什么不用球体：低模球看起来像"石头形状的球"；二十面体的三角面随机推拉之后
## 才有"被敲过的棱角"。法线按**面**算（平面着色），棱角才立得住。
static func _build_rock(variant: int) -> ArrayMesh:
	var noise := FastNoiseLite.new()
	noise.seed = 7717 + variant * 131
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 1.05
	noise.fractal_octaves = 2

	# 每个变体的性格：扁平 / 方正 / 瘦高 …（石头最忌"全都一样高宽比"）
	var shapes: Array[Vector3] = [
		Vector3(1.0, 0.62, 0.94), Vector3(1.14, 0.50, 0.86),
		Vector3(0.86, 0.78, 1.10), Vector3(1.0, 0.44, 1.0)]
	var amps: Array[float] = [0.44, 0.34, 0.54, 0.30]
	var squash: Vector3 = shapes[variant % 4]
	var amp: float = amps[variant % 4]

	var faces: Array = _icosphere(1)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	for f in faces:
		var a: Vector3 = _rock_point(f[0], noise, amp, squash)
		var b: Vector3 = _rock_point(f[1], noise, amp, squash)
		var c: Vector3 = _rock_point(f[2], noise, amp, squash)
		var nrm: Vector3 = (b - a).cross(c - a)
		if nrm.length_squared() < 1e-8:
			continue
		nrm = nrm.normalized()
		var base: int = verts.size()
		# ★ 顶点顺序 a, c, b：Godot 的正面是**顺时针**，按 a,b,c 排会让所有外表面
		#   变成背面被 CULL_BACK 剔掉，只剩远端内侧薄壳 —— 表现就是"一块黑月牙"。
		for p in [a, c, b]:
			verts.append(p)
			normals.append(nrm)          # 法线仍按 (b-a)×(c-a) 朝外，与绕序无关
			uvs.append(ProcTree.UV_OPAQUE)
			colors.append(_rock_color(p, nrm, noise))
		idx.append(base)
		idx.append(base + 1)
		idx.append(base + 2)
	return _to_mesh(verts, normals, colors, uvs, idx)


static func _rock_point(dir: Vector3, noise: FastNoiseLite, amp: float,
		squash: Vector3) -> Vector3:
	# 两层噪声：低频定大形（圆/扁/长），高频抠棱角（不然就是一颗鸡蛋）
	var n: float = noise.get_noise_3d(dir.x * 1.7, dir.y * 1.7, dir.z * 1.7)
	var n2: float = noise.get_noise_3d(dir.x * 4.6 + 19.0, dir.y * 4.6, dir.z * 4.6)
	var r: float = 1.0 + amp * n + amp * 0.45 * n2
	var p: Vector3 = dir * r
	p *= squash
	# 底面压平：石头是"坐"在地上的，不是一个悬浮的球
	if p.y < -0.18:
		p.y = -0.18 + (p.y + 0.18) * 0.25
	return p


## 石头颜色：上亮下暗（顶点 AO）+ 噪声斑驳 + 朝上的面掺苔
static func _rock_color(p: Vector3, nrm: Vector3, noise: FastNoiseLite) -> Color:
	var up: float = clampf(nrm.y * 0.5 + 0.5, 0.0, 1.0)
	var height: float = clampf(p.y * 0.9 + 0.55, 0.0, 1.0)
	var mott: float = 0.80 + 0.34 * (noise.get_noise_3d(p.x * 3.4, p.y * 3.4, p.z * 3.4) * 0.5 + 0.5)
	var shade: float = (0.42 + 0.58 * up) * (0.55 + 0.45 * height) * mott
	var col: Color = ROCK_DARK.lerp(ROCK_LIGHT, clampf(shade, 0.0, 1.0))
	# 苔痕：只长在朝上且不陡的面，且要成片（噪声阈值），不要"整体发绿"
	var moss_mask: float = clampf((up - 0.62) / 0.38, 0.0, 1.0)
	var moss_noise: float = noise.get_noise_3d(p.x * 2.2 + 11.0, p.y * 2.2, p.z * 2.2)
	if moss_noise > 0.18:
		col = col.lerp(MOSS, moss_mask * 0.55)
	return col


## 二十面体（subdiv=0 是 20 面，1 是 80 面）。返回每个面的三个单位方向（Vector3 三元组）。
static func _icosphere(subdiv: int) -> Array:
	var t: float = (1.0 + sqrt(5.0)) * 0.5
	var v: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in v.size():
		v[i] = v[i].normalized()
	var raw: Array = [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]
	var tris: Array = []
	for f in raw:
		tris.append([v[int(f[0])], v[int(f[1])], v[int(f[2])]])
	for _s in subdiv:
		var nxt: Array = []
		for tr in tris:
			var a: Vector3 = tr[0]
			var b: Vector3 = tr[1]
			var c: Vector3 = tr[2]
			var ab: Vector3 = ((a + b) * 0.5).normalized()
			var bc: Vector3 = ((b + c) * 0.5).normalized()
			var ca: Vector3 = ((c + a) * 0.5).normalized()
			nxt.append([a, ab, ca])
			nxt.append([b, bc, ab])
			nxt.append([c, ca, bc])
			nxt.append([ab, bc, ca])
		tris = nxt
	return tris


# ===========================================================================
# 草丛
# ===========================================================================

## 3 张交叉卡片 + 顶上一点高度差。
## 顶点色只放明暗（根部暗、叶尖亮），**颜色留给合批实例色** ——
## 地表细节 那套"实例色染绿"的管线一行都不用改。
static func _build_grass(_variant: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	var cards := 3
	var width: float = 0.86
	var height: float = 0.72
	for k in cards:
		var ang: float = TAU * float(k) / float(cards) + 0.35
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var side := Vector3(-dir.z, 0.0, dir.x) * (width * 0.5)
		var base_h: float = height * (0.9 + 0.1 * float(k % 2))
		# 稍微外倾，草才不会像一堵墙
		var lean: Vector3 = dir * 0.10
		var p0: Vector3 = -side
		var p1: Vector3 = side
		var p2: Vector3 = side + Vector3(0.0, base_h, 0.0) + lean
		var p3: Vector3 = -side + Vector3(0.0, base_h, 0.0) + lean
		var nrm: Vector3 = (Vector3.UP + dir * 0.35).normalized()
		var base_i: int = verts.size()
		var quad := [p0, p1, p2, p3]
		var quad_uv := [
			Vector2(ProcTree.UV_GRASS.position.x,
				ProcTree.UV_GRASS.position.y + ProcTree.UV_GRASS.size.y),
			Vector2(ProcTree.UV_GRASS.position.x + ProcTree.UV_GRASS.size.x,
				ProcTree.UV_GRASS.position.y + ProcTree.UV_GRASS.size.y),
			Vector2(ProcTree.UV_GRASS.position.x + ProcTree.UV_GRASS.size.x,
				ProcTree.UV_GRASS.position.y),
			Vector2(ProcTree.UV_GRASS.position.x, ProcTree.UV_GRASS.position.y),
		]
		# 根暗尖亮：0.55 → 1.0（乘以实例色之后就是"草根压暗"）
		var lums := [0.55, 0.55, 1.0, 1.0]
		for i in 4:
			verts.append(quad[i])
			normals.append(nrm)
			uvs.append(quad_uv[i])
			colors.append(Color(lums[i], lums[i], lums[i], 1.0))
		idx.append(base_i)
		idx.append(base_i + 1)
		idx.append(base_i + 2)
		idx.append(base_i)
		idx.append(base_i + 2)
		idx.append(base_i + 3)
	return _to_mesh(verts, normals, colors, uvs, idx)


# ===========================================================================
# 组装
# ===========================================================================

static func _to_mesh(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array,
		idx: PackedInt32Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
