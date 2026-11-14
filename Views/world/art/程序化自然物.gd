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
const ROCK_VARIANTS := 8
## 草丛变体数（1 = 单批；想更花可以加到 4，代价是多 3 次 draw call）
const GRASS_VARIANTS := 1

const KIND_ROCK := "岩石"
const KIND_GRASS := "草丛"

## 岩石基色（在 2.35 的暖主光下大约出 0.5 的灰，太亮就成石膏）
## 岩石基色：**和地形崖壁、金矿的石材同一档冷灰**（调色板的 rock / rock_dark）。
##
## ⚠ 这里的数值是**albedo**，不是屏幕上看到的亮度。主光 2.35 + 天光会把它抬约 4.5 倍：
##   0.125 的 albedo 渲染出来大约就是调色板的 0.5 冷灰。
##   2026-10-31 试过直接按"想要的屏幕亮度"填 0.15~0.56，结果石头全变成石膏白 ——
##   亮度必须按 albedo 填，靠"暗部更暗"拉体积，不是靠整体提亮。
const ROCK_DARK := Color(0.046, 0.049, 0.052)
const ROCK_LIGHT := Color(0.150, 0.155, 0.160)
## 苔痕（朝上的面掺一点；饱和度压得比草低，石头才不"发绿"）
const MOSS := Color(0.062, 0.100, 0.040)
## 根部吃土色（同样按 albedo 填，0.10 渲染出来是暖褐）
const DIRT_TINT := Color(0.105, 0.088, 0.062)

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

## 石头形状的"性格表"：形状 / 位移幅度 / 细分等级。
##
## 二十面体细分 1 = 80 面、细分 2 = 320 面。**面数不是目的，棱才是**：
## 石头的美术价值全在"被敲过的棱角"上，所以：
##   · 大块纪念碑式的石头用 subdiv 2（棱更密、凿痕更细）；
##   · 小卵石用 subdiv 1（少而大的面反而更像被水冲圆的）。
## 面法线（平面着色）+ 逐角顶点色，两者叠加就是低模石头该有的"硬"。
const ROCK_SHAPES: Array[Dictionary] = [
	# 扁平石板：林地里最常见的那种"半埋的大平板"
	{"squash": Vector3(1.00, 0.52, 0.92), "amp": 0.40, "subdiv": 2, "skew": 0.30},
	# 方正块：像被切过的花岗岩
	{"squash": Vector3(1.14, 0.72, 0.98), "amp": 0.26, "subdiv": 2, "skew": 0.06},
	# 竖棱石：从地里戳出来的石刃
	{"squash": Vector3(0.74, 1.22, 0.80), "amp": 0.34, "subdiv": 2, "skew": 0.44},
	# 圆卵石：被水磨过，面少而大
	{"squash": Vector3(1.06, 0.78, 1.02), "amp": 0.18, "subdiv": 1, "skew": 0.02},
	# 尖角石：碎得比较厉害的一块
	{"squash": Vector3(0.96, 0.88, 0.92), "amp": 0.52, "subdiv": 2, "skew": 0.50},
	# 双峰石：两块挤在一起长
	{"squash": Vector3(1.20, 0.60, 1.06), "amp": 0.46, "subdiv": 2, "skew": 0.38},
	# 宽矮台：能当天然台阶
	{"squash": Vector3(1.30, 0.42, 1.10), "amp": 0.22, "subdiv": 2, "skew": 0.10},
	# 瘦长碎石：半截断在土里
	{"squash": Vector3(0.62, 1.06, 0.66), "amp": 0.30, "subdiv": 1, "skew": 0.26},
]


## 二十面体细分 → 按噪声推拉半径。
## 为什么不用球体：低模球看起来像"石头形状的球"；二十面体的三角面随机推拉之后
## 才有"被敲过的棱角"。法线按**面**算（平面着色），棱角才立得住。
static func _build_rock(variant: int) -> ArrayMesh:
	var prof: Dictionary = ROCK_SHAPES[variant % ROCK_SHAPES.size()]
	var noise := FastNoiseLite.new()
	noise.seed = 7717 + variant * 131
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 1.05
	noise.fractal_octaves = 2
	# 层理（沉积纹）：一条独立的低频噪声，只在颜色上切"石层"的暗带，
	# 不动几何 —— 动几何会把石头切成"千层饼"，看着像木纹。
	var strata := FastNoiseLite.new()
	strata.seed = 4409 + variant * 77
	strata.noise_type = FastNoiseLite.TYPE_SIMPLEX
	strata.frequency = 1.8
	strata.fractal_octaves = 1

	var squash: Vector3 = prof.get("squash", Vector3.ONE)
	var amp: float = float(prof.get("amp", 0.4))
	var skew: float = float(prof.get("skew", 0.2))

	var faces: Array = _icosphere(int(prof.get("subdiv", 2)))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	for f in faces:
		var a: Vector3 = _rock_point(f[0], noise, amp, squash, skew)
		var b: Vector3 = _rock_point(f[1], noise, amp, squash, skew)
		var c: Vector3 = _rock_point(f[2], noise, amp, squash, skew)
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
			colors.append(_rock_color(p, nrm, noise, strata))
		idx.append(base)
		idx.append(base + 1)
		idx.append(base + 2)
	return _to_mesh(verts, normals, colors, uvs, idx)


static func _rock_point(dir: Vector3, noise: FastNoiseLite, amp: float,
		squash: Vector3, skew: float = 0.0) -> Vector3:
	# 三层噪声：低频定大形（圆/扁/长），中频抠棱角（不然就是一颗鸡蛋），
	# 高频给表面一点"石屑"的碎起伏（只在近处看得见，够用）
	var n: float = noise.get_noise_3d(dir.x * 1.7, dir.y * 1.7, dir.z * 1.7)
	var n2: float = noise.get_noise_3d(dir.x * 4.6 + 19.0, dir.y * 4.6, dir.z * 4.6)
	var n3: float = noise.get_noise_3d(dir.x * 9.5 - 7.0, dir.y * 9.5, dir.z * 9.5)
	var r: float = 1.0 + amp * n + amp * 0.45 * n2 + amp * 0.14 * n3
	var p: Vector3 = dir * r
	p *= squash
	# 侧向错切：让石头不是"对称的陀螺"，而是往一边歪（skew 大的变成石刃）
	p.x += skew * p.y * 0.55
	p.z -= skew * p.y * 0.20
	# 底面压平：石头是"坐"在地上的，不是一个悬浮的球
	if p.y < -0.18:
		p.y = -0.18 + (p.y + 0.18) * 0.25
	return p


## 石头颜色：上亮下暗（顶点 AO）+ 噪声斑驳 + 层理暗带 + 朝上的面掺苔 + 根部吃土色
static func _rock_color(p: Vector3, nrm: Vector3, noise: FastNoiseLite,
		strata: FastNoiseLite) -> Color:
	var up: float = clampf(nrm.y * 0.5 + 0.5, 0.0, 1.0)
	var height: float = clampf(p.y * 0.9 + 0.55, 0.0, 1.0)
	var mott: float = 0.80 + 0.34 * (noise.get_noise_3d(p.x * 3.4, p.y * 3.4, p.z * 3.4) * 0.5 + 0.5)
	var shade: float = (0.42 + 0.58 * up) * (0.55 + 0.45 * height) * mott
	var col: Color = ROCK_DARK.lerp(ROCK_LIGHT, clampf(shade, 0.0, 1.0))
	# 层理：一条低频噪声切出来的暗带（只压 12% 亮度，多了会像"条纹木头"）
	var band: float = strata.get_noise_3d(p.x * 2.2, p.y * 3.6, p.z * 2.2)
	if band > 0.22:
		col = col.darkened(0.12)
	# 苔痕：只长在朝上且不陡的面，且要成片（噪声阈值），不要"整体发绿"
	var moss_mask: float = clampf((up - 0.62) / 0.38, 0.0, 1.0)
	var moss_noise: float = noise.get_noise_3d(p.x * 2.2 + 11.0, p.y * 2.2, p.z * 2.2)
	if moss_noise > 0.18:
		col = col.lerp(MOSS, moss_mask * 0.50)
	# 根部吃土：最底下 18% 掺一点暖土色，石头才像"从土里长出来"而不是"摆在地上"
	if p.y < -0.02:
		col = col.lerp(Color(0.235, 0.196, 0.145), clampf((-p.y - 0.02) * 2.2, 0.0, 0.42))
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
