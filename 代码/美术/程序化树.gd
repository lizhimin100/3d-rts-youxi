@tool
class_name ProcTree
extends RefCounted
## **程序化树**：给定 (品种/季节, LOD 档, 变体种子)，现场长出一棵树的 ArrayMesh。
##
## 算法来源与取舍（参考 procedural-tree 的球形法线方案，重写而非拷贝）：
##   ① 骨架：逐步前进，每步用 3D Perlin 噪声扰动**并剔除沿枝方向的分量**——
##      不剔的话噪声会让枝条忽快忽慢地伸缩，看起来是"抽搐"而不是"弯曲"；
##      再叠两个方向相反的力：向光性(tropism, 向上) 与 重力(gravity, 向下)，比值即树格。
##   ② 管道：每根枝扫成 n 边圆管，用**平行传输标架**（不是 Frenet）——
##      Frenet 在曲率突变处会突然翻转，管子表面出现麻花状扭曲。
##   ③ 叶片：每片叶是一张四边卡片，**法线 = 叶位 − 所属分杈的球心**。
##      几千张卡片各自按自己的朝向打光，冠内会碎成胡椒面；按"一杈一团球"打光，
##      明暗连续铺过去，才有体积感。这也是本项目"树冠一坨"的解法。
##   ④ 顶点色当 AO + 单色叶片：形体完全交给法线的光照梯度，不靠多材质分区。
##
## 性能设计（手游 RTS 视角，单局 150~250 棵）：
##   · **一棵树只有一个 surface / 一个材质** → 1 次 draw call（旧管线 5 个材质 = 5 次）；
##   · 三档 LOD 是同一份顶点预算的两个数量级：近 ~1.5k / 中 ~0.5k / 远 ~80 面；
##   · 网格全部走 TreeLibrary 的池化缓存，同 (品种, 档, 变体) 只生成一次、全场景共享；
##   · LOD 切换交给 GeometryInstance3D.visibility_range，**零脚本、零逐帧计算**。
##
## 确定性：所有随机都来自 (种子, 层级, 枝编号, 盐) 的哈希，不用全局 RNG 流——
## 这样近/中/远三档在切换时仍是同一棵树（骨架前几级完全一致），不会"跳脸"。

# ===========================================================================
# 参数表
# ===========================================================================

## 品种（= 装饰品名后缀）。季节点决定叶色、叶量、姿态。
##   density    叶量倍率      leaf_size 叶片尺寸倍率
##   branch_angle 子枝张开角(度)  ternary  三分叉概率
##   gravity / tropism 向下 / 向上 的拉力，比值决定树格
##   blossom    春花比例（"春"专用：一部分叶子换成花）
const SEASONS: Dictionary = {
	"春": {
		"leaf": Color(0.24, 0.38, 0.15), "leaf2": Color(0.30, 0.44, 0.18),
		"blossom": Color(0.38, 0.26, 0.29), "blossom_ratio": 0.07,
		"bark": Color(0.15, 0.12, 0.09), "bark2": Color(0.20, 0.16, 0.12),
		"density": 0.85, "leaf_size": 0.92,
		"branch_angle": 42.0, "ternary": 0.70,
		"gravity": 0.55, "tropism": 1.05, "child_rise": 0.10,
		"length_ratio": 0.72, "radius_ratio": 0.62, "wander": 1.0,
	},
	"夏": {
		"leaf": Color(0.11, 0.21, 0.08), "leaf2": Color(0.16, 0.28, 0.10),
		"blossom": Color(0.15, 0.28, 0.10), "blossom_ratio": 0.0,
		"bark": Color(0.12, 0.10, 0.08), "bark2": Color(0.17, 0.14, 0.12),
		"density": 1.0, "leaf_size": 1.0,
		"branch_angle": 38.0, "ternary": 0.78,
		"gravity": 0.45, "tropism": 1.15, "child_rise": 0.12,
		"length_ratio": 0.74, "radius_ratio": 0.62, "wander": 0.95,
	},
	"秋": {
		"leaf": Color(0.33, 0.16, 0.05), "leaf2": Color(0.42, 0.23, 0.07),
		"blossom": Color(0.36, 0.13, 0.05), "blossom_ratio": 0.06,
		"bark": Color(0.15, 0.11, 0.09), "bark2": Color(0.20, 0.16, 0.13),
		"density": 0.80, "leaf_size": 1.02,
		"branch_angle": 40.0, "ternary": 0.72,
		"gravity": 0.85, "tropism": 0.90, "child_rise": 0.04,
		"length_ratio": 0.72, "radius_ratio": 0.62, "wander": 1.05,
	},
	"冬": {
		"leaf": Color(0.26, 0.24, 0.21), "leaf2": Color(0.32, 0.30, 0.26),
		"blossom": Color(0.60, 0.62, 0.66), "blossom_ratio": 0.0,
		"bark": Color(0.16, 0.15, 0.14), "bark2": Color(0.21, 0.20, 0.19),
		"density": 0.10, "leaf_size": 1.08,
		"branch_angle": 33.0, "ternary": 0.62,
		"gravity": 0.60, "tropism": 1.25, "child_rise": 0.16,
		"length_ratio": 0.70, "radius_ratio": 0.60, "wander": 0.85,
	},
}

const DEFAULT_SEASON := "夏"
const SEASON_ORDER: Array[String] = ["春", "夏", "秋", "冬"]

## 三档细节。levels = 递归层数，segs = 每根枝的采样段数，ring = 圆管的截面边数。
## 面数由"枝数 × 段数 × 边数 × 2"决定，枝数又按 ternary 次方涨 —— 真正的成本大头是
## **圆管**，不是叶片（叶片一张卡才 2 个三角面）。所以砍面数先砍层级/边数，别急着砍叶子。
##
## ★ 叶片尺寸三档必须**一致**：以前远档把叶片放大到 2.6m 去保剪影，结果切档时
##   树像换了一棵（玩家原话"品种随镜头刷新"）。现在只在叶量/边数上做减法。
##
## 2026-10-31：近档 leaf_per 12 → 15、leaf_size 0.86 → 0.92。
## 原参数下一棵 5.5m 的树只有 300 来张叶卡，冠里能透过去看到天空，
## 远看就是"几团分开的绿球"。加量之后冠是**连通**的，轮廓才立得住；
## 代价是单树 ~1.3k → ~1.6k 面（150 棵 +4.5 万面），在 71466 面的地形面前可以忽略。
const TIERS: Array[Dictionary] = [
	{"levels": 3, "segs": 3, "ring": 4, "leaf_per": 15, "leaf_size": 0.92,
		"leaf_start": 0.18, "shadow": true},
	{"levels": 3, "segs": 2, "ring": 4, "leaf_per": 9, "leaf_size": 0.92,
		"leaf_start": 0.18, "shadow": true},
	{"levels": 2, "segs": 2, "ring": 3, "leaf_per": 4, "leaf_size": 0.92,
		"leaf_start": 0.15, "shadow": false},
]

## 球形法线的分组层级（level 达到这一级的子枝各自领一个"球"）。
## 取 2：近/中/远三档都能分出 3~9 个球，冠内明暗才不是一个整球。
const CLUSTER_LEVEL := 2

## 纹理图集：UV 里两块区域 —— 叶片轮廓 / 全不透明（树干取色）
const ATLAS_SIZE := 256
const UV_LEAF := Rect2(0.015, 0.515, 0.47, 0.47)
const UV_OPAQUE := Vector2(0.75, 0.25)
## 草丛的一小撮草叶（左上象限）。给 程序化自然物 的草丛用，和树共用同一张图、同一个材质。
const UV_GRASS := Rect2(0.015, 0.015, 0.47, 0.47)

static var _atlas: ImageTexture = null


# ===========================================================================
# 对外：生成
# ===========================================================================

## 长一棵树。season = 品种（春/夏/秋/冬），tier = 0近 / 1中 / 2远，
## seed_val = 变体种子（同一个种子永远长出同一棵树）。
static func build(season: String, tier: int, seed_val: int, target_height: float = 5.5) -> ArrayMesh:
	var sp: Dictionary = SEASONS.get(season, SEASONS[DEFAULT_SEASON])
	var prof: Dictionary = TIERS[clampi(tier, 0, TIERS.size() - 1)]
	var st := {
		"noise": _make_noise(seed_val),
		"seed": seed_val,
		"sp": sp,
		"tier": prof,
		"max_level": int(prof["levels"]),
		"branches": [],
		"leaves": [],
		"gid": [0],          # 用单元素数组当可变计数器（GDScript 静态函数里好传）
		"pid": [0],          # 枝编号：给每根枝一个稳定的随机流
	}
	# 主干：长度/半径按目标高度估，最后整体归一化到 target_height
	var trunk_len: float = target_height * 0.42
	var trunk_rad: float = maxf(0.045, target_height * 0.032)
	_grow(st, Vector3.ZERO, Vector3.UP, trunk_len, trunk_rad, 0, 0)

	var centers: Dictionary = _cluster_centers(st)
	var out := {
		"v": PackedVector3Array(), "n": PackedVector3Array(),
		"c": PackedColorArray(), "uv": PackedVector2Array(),
		"i": PackedInt32Array(),
	}
	_emit_trunk(st, out)
	_emit_leaves(st, centers, out)

	var mesh := ArrayMesh.new()
	if out["v"].is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _fit_height(out["v"], target_height)
	arrays[Mesh.ARRAY_NORMAL] = out["n"]
	arrays[Mesh.ARRAY_COLOR] = out["c"]
	arrays[Mesh.ARRAY_TEX_UV] = out["uv"]
	arrays[Mesh.ARRAY_INDEX] = out["i"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 叶片纹理图集（程序化画，无图片资源）。
## 左下半张 = **一小枝树叶**（6 片小叶 + 细枝），右上大块 = 全不透明（树干 UV 取那里）。
##
## ★ 为什么画"一簇"而不是"一片"：一张卡片贴一整片大叶子，在 RTS 机位下就是
##   "树上挂了一堆西瓜大的叶子"。真实叶片才 10~20cm，游戏里靠**一簇**表达体积——
##   一张卡片画 6 片小叶，卡片尺寸 0.6~0.9m，看上去才是树叶而不是荷叶。
##
## 为什么树干要"借"叶子的贴图：一棵树只用一个材质才有 1 次 draw call；
## alpha scissor 材质对不透明区域没有副作用，所以两块几何可以共用一张图。
static func atlas() -> ImageTexture:
	if _atlas != null:
		return _atlas
	var img := Image.create(ATLAS_SIZE, ATLAS_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.0))
	# —— 右上：全不透明块（树干取样区，越大越抗 mip 混合）
	img.fill_rect(Rect2i(ATLAS_SIZE / 2, 0, ATLAS_SIZE / 2, ATLAS_SIZE / 2),
		Color(1.0, 1.0, 1.0, 1.0))
	# —— 左下：一小枝树叶
	_draw_leaf_cluster(img, Rect2i(0, ATLAS_SIZE / 2, ATLAS_SIZE / 2, ATLAS_SIZE / 2))
	# —— 左上：一小撮草叶（程序化草丛用）
	_draw_grass_tuft(img, Rect2i(0, 0, ATLAS_SIZE / 2, ATLAS_SIZE / 2))
	_atlas = ImageTexture.create_from_image(img)
	return _atlas


## 在 rect 里画"一小枝树叶"：一根细枝 + 6 片交替生长的小叶。
## 小叶用椭圆近似（u,v 归一化后 x²/a² + y²/b² ≤ 1），尖端略收 —— 这个精度在
## 手机屏幕上足够读成"叶子"，而且整张图只有 alpha 0/1 两态，scissor 判定干净。
static func _draw_leaf_cluster(img: Image, rect: Rect2i) -> void:
	var W: float = float(rect.size.x)
	var H: float = float(rect.size.y)
	var ox: float = float(rect.position.x)
	var oy: float = float(rect.position.y)
	# 叶片：中心点（相对 rect，0..1）、长半轴、短半轴、倾角（弧度）
	var leaves: Array = []
	var n := 9
	for k in n:
		var t: float = 0.18 + 0.62 * (float(k) / float(n - 1))     # 沿枝从下往上
		var side: float = -1.0 if k % 2 == 0 else 1.0
		var spread: float = 0.30 + 0.10 * float(k % 3)             # 横向张开
		var cx: float = 0.5 + side * spread * (0.55 + 0.45 * (1.0 - t))
		var cy: float = 0.92 - t * 0.80
		# 倾角：叶子从枝上斜着往外长
		var ang: float = side * (0.62 + 0.18 * float(k % 2)) - 0.06
		var a_len: float = 0.20 - 0.035 * float(k)                 # 越靠梢越小
		var b_len: float = a_len * 0.40
		leaves.append({"c": Vector2(cx, cy), "a": a_len, "b": b_len, "ang": ang})
	for py in rect.size.y:
		for px in rect.size.x:
			var u: float = (float(px) + 0.5) / W
			var v: float = (float(py) + 0.5) / H
			var lum: float = 1.0
			var alpha: float = 0.0
			# 细枝：竖向一条，越往上越细
			var stem_w: float = lerpf(0.030, 0.012, clampf(v, 0.0, 1.0))
			if absf(u - 0.5) <= stem_w and v > 0.04 and v < 0.96:
				alpha = 1.0
				lum = 0.62
			for lf in leaves:
				var c: Vector2 = lf["c"]
				var a: float = lf["a"]
				var b: float = lf["b"]
				var ang: float = lf["ang"]
				var dx: float = u - c.x
				var dy: float = v - c.y
				var ca: float = cos(ang)
				var sa: float = sin(ang)
				# 转到叶子的局部坐标（长轴 = x）
				var lx: float = dx * ca + dy * sa
				var ly: float = -dx * sa + dy * ca
				var q: float = (lx * lx) / (a * a) + (ly * ly) / (b * b)
				if q <= 1.0:
					alpha = 1.0
					# 叶子边缘压暗一点、中脉提亮，纯看 RGB 也需要一点层次
					var rim: float = clampf((1.0 - q) * 2.6, 0.0, 1.0)
					lum = 0.80 + 0.20 * rim
			if alpha <= 0.0:
				continue
			img.set_pixel(rect.position.x + px, rect.position.y + py,
				Color(lum, lum, lum, 1.0))


## 在 rect 里画"一小撮草叶"：7 根从底部中心散开的尖叶。
## 用"点到线段距离 < 半宽"来判定，比逐像素求贝塞尔便宜，也够手游视距看。
static func _draw_grass_tuft(img: Image, rect: Rect2i) -> void:
	var W: float = float(rect.size.x)
	var H: float = float(rect.size.y)
	var blades: Array = []
	var n := 7
	for k in n:
		var f: float = float(k) / float(n - 1)
		# 从左到右铺开；中间的草叶最高，两侧矮一点
		var base_x: float = 0.16 + 0.68 * f
		var lean: float = (f - 0.5) * 0.42
		var tip_x: float = base_x + lean
		var tip_y: float = 0.10 + 0.22 * absf(f - 0.5) * 2.0
		var half_w: float = 0.030 - 0.012 * absf(f - 0.5) * 2.0
		blades.append({"a": Vector2(base_x, 0.99), "b": Vector2(tip_x, tip_y),
			"w": half_w})
	for py in rect.size.y:
		for px in rect.size.x:
			var p := Vector2((float(px) + 0.5) / W, (float(py) + 0.5) / H)
			for bl in blades:
				var a: Vector2 = bl["a"]
				var b: Vector2 = bl["b"]
				var ab: Vector2 = b - a
				var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
				var d: float = p.distance_to(a + ab * t)
				# 宽度从叶根到叶尖线性收到 15%
				var w: float = float(bl["w"]) * lerpf(1.0, 0.15, t)
				if d <= w:
					# 叶根暗、叶尖亮，给一点层次
					var lum: float = 0.62 + 0.38 * t
					img.set_pixel(rect.position.x + px, rect.position.y + py,
						Color(lum, lum, lum, 1.0))
					break


# ===========================================================================
# 骨架
# ===========================================================================

static func _make_noise(seed_val: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_val
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.frequency = 0.9
	n.fractal_octaves = 2
	return n


## 确定性哈希 → [0,1)。同一 (种子, 层级, 枝号, 盐) 永远同一个数。
## 用哈希而不是单条 RNG 流：近/中/远三档的骨架前几级必须完全一致，否则 LOD 切换会跳脸。
static func _hash01(seed_val: int, level: int, pid: int, salt: int) -> float:
	var h: int = seed_val & 0x7fffffff
	h = (h ^ ((level + 1) * 374761393)) & 0x7fffffff
	h = (h ^ ((pid + 7) * 668265263)) & 0x7fffffff
	h = (h ^ ((salt + 13) * 1274126177)) & 0x7fffffff
	h = (h ^ (h >> 13)) & 0x7fffffff
	h = (h * 2246822519) & 0x7fffffff
	h = (h ^ (h >> 15)) & 0x7fffffff
	return float(h % 1000003) / 1000003.0


## 长一根枝（递归）
static func _grow(st: Dictionary, origin: Vector3, dir: Vector3, length: float,
		radius: float, level: int, gid: int) -> void:
	var noise: FastNoiseLite = st["noise"]
	var sp: Dictionary = st["sp"]
	var max_level: int = int(st["max_level"])
	st["pid"][0] = int(st["pid"][0]) + 1
	var pid: int = int(st["pid"][0])
	var seed_val: int = int(st["seed"])

	var segs: int = maxi(2, int(st["tier"]["segs"]) - (1 if level >= max_level - 1 else 0))
	var lf: float = float(level) / float(max_level)
	var pts := PackedVector3Array()
	pts.append(origin)
	var p := origin
	var d := dir.normalized()
	var step: float = length / float(segs)
	for i in range(1, segs + 1):
		# ① 噪声弯曲：剔除沿枝分量，只留垂直分量
		var ns: float = 1.0 + lf * 0.9
		var nv := Vector3(
			noise.get_noise_3d(p.x * ns + 31.7, p.y * ns, p.z * ns),
			noise.get_noise_3d(p.x * ns + 7.1, p.y * ns, p.z * ns + 53.9) * 0.55,
			noise.get_noise_3d(p.x * ns, p.y * ns + 17.3, p.z * ns))
		nv -= d * nv.dot(d)
		d += nv * (float(sp["wander"]) * (0.45 + lf * 0.95) * 0.085)
		# ② 向光性：越往冠外越往天上长
		d.y += float(sp["tropism"]) * 0.020 * (0.35 + lf)
		# ③ 重力：越细的枝垂得越厉害
		d.y -= float(sp["gravity"]) * (1.0 - lf * 0.35) * 0.030
		d = d.normalized()
		p += d * step
		pts.append(p)
		if p.y < 0.06:
			break

	(st["branches"] as Array).append({
		"pts": pts, "r0": radius, "r1": radius * 0.55, "level": level,
	})

	# --- 撒叶：末梢满密度，往上两级补缝隙（只撒末梢会变成"光杆挂绒球"）
	var leaf_density: float = -1.0
	if level >= max_level:
		leaf_density = 1.0
	elif level == max_level - 1:
		leaf_density = 0.55
	elif level == max_level - 2:
		leaf_density = 0.12
	if leaf_density > 0.0:
		_scatter_leaves(st, pts, radius, level, gid, pid, leaf_density)

	# --- 子枝
	if level >= max_level:
		return
	var count: int = 2
	if _hash01(seed_val, level, pid, 1) < float(sp["ternary"]):
		count = 3
	var pcount: int = pts.size()
	for k in count:
		var t: float = lerpf(0.34, 0.98, _hash01(seed_val, level, pid, 10 + k))
		var idx: int = clampi(int(round(t * float(pcount - 1))), 0, pcount - 1)
		var base: Vector3 = pts[idx]
		var tan: Vector3 = (pts[mini(idx + 1, pcount - 1)] - pts[maxi(idx - 1, 0)]).normalized()
		if tan.length_squared() < 0.001:
			tan = d
		var ax: Vector3 = tan.cross(Vector3.UP)
		if ax.length_squared() < 0.001:
			ax = tan.cross(Vector3.RIGHT)
		ax = ax.normalized()
		var ay: Vector3 = tan.cross(ax).normalized()
		# 方位均分 + 黄金角偏移：同一根母枝上的子枝不会挤在一侧，
		# 不同层级偏移量不同，避免所有层级在同一个方向排成一条线
		var azim: float = (float(k) / float(count)) * TAU \
			+ 2.39996323 * float(level) * 1.7 \
			+ _hash01(seed_val, level, pid, 20 + k) * 0.85
		var pitch: float = deg_to_rad(float(sp["branch_angle"]) * (0.72
			+ _hash01(seed_val, level, pid, 30 + k) * 0.62))
		var dir_c: Vector3 = tan * cos(pitch) \
			+ ax * sin(pitch) * cos(azim) \
			+ ay * sin(pitch) * sin(azim)
		dir_c.y += float(sp["child_rise"])
		var child_len: float = length * float(sp["length_ratio"]) * (0.85
			+ _hash01(seed_val, level, pid, 40 + k) * 0.30)
		var child_rad: float = radius * float(sp["radius_ratio"])
		# 到"分杈层"时给每个子树领新的球编号，之后所有后代都继承它
		var child_gid: int = gid
		if level == CLUSTER_LEVEL - 1:
			st["gid"][0] = int(st["gid"][0]) + 1
			child_gid = int(st["gid"][0])
		_grow(st, base, dir_c, child_len, child_rad, level + 1, child_gid)


## 沿枝撒叶（位置 + 球编号 + 尺寸 + 滚转都先记下来，法线第 2 遍再算）
static func _scatter_leaves(st: Dictionary, pts: PackedVector3Array, radius: float,
		level: int, gid: int, pid: int, density: float) -> void:
	var sp: Dictionary = st["sp"]
	var tier: Dictionary = st["tier"]
	var seed_val: int = int(st["seed"])
	var n: int = int(round(float(tier["leaf_per"]) * float(pts.size() - 1)
		* density * float(sp["density"])))
	if n <= 0:
		return
	var start: float = float(tier["leaf_start"])
	for i in n:
		var t: float = lerpf(start, 1.0, _hash01(seed_val, level, pid, 100 + i))
		var fi: float = t * float(pts.size() - 1)
		var i0: int = clampi(int(fi), 0, pts.size() - 1)
		var i1: int = mini(i0 + 1, pts.size() - 1)
		var base: Vector3 = pts[i0].lerp(pts[i1], fi - float(i0))
		var out_dir := Vector3(
			_hash01(seed_val, level, pid, 200 + i) - 0.5,
			_hash01(seed_val, level, pid, 300 + i) * 0.55,
			_hash01(seed_val, level, pid, 400 + i) - 0.5).normalized()
		var pos: Vector3 = base + out_dir * maxf(radius * 1.2, 0.16)
		var size: float = float(tier["leaf_size"]) * float(sp["leaf_size"]) \
			* (0.78 + _hash01(seed_val, level, pid, 500 + i) * 0.44)
		(st["leaves"] as Array).append({
			"pos": pos, "gid": gid, "size": size,
			"roll": _hash01(seed_val, level, pid, 600 + i) * TAU,
		})


## 每一"杈"叶子的球心 + 球半径。
## 球心给球形法线用；半径给"冠内越往里越暗"的顶点 AO 用（见 _emit_leaves）。
static func _cluster_centers(st: Dictionary) -> Dictionary:
	var acc: Dictionary = {}
	var cnt: Dictionary = {}
	for lf in (st["leaves"] as Array):
		var key: int = int(lf["gid"])
		acc[key] = (acc.get(key, Vector3.ZERO) as Vector3) + (lf["pos"] as Vector3)
		cnt[key] = int(cnt.get(key, 0)) + 1
	var centers: Dictionary = {}
	for key in acc:
		centers[key] = (acc[key] as Vector3) / float(maxi(1, int(cnt[key])))
	var radius: Dictionary = {}
	for lf in (st["leaves"] as Array):
		var key2: int = int(lf["gid"])
		var d: float = (lf["pos"] as Vector3).distance_to(centers[key2] as Vector3)
		radius[key2] = maxf(float(radius.get(key2, 0.0)), d)
	return {"c": centers, "r": radius}


# ===========================================================================
# 几何
# ===========================================================================

static func _emit_trunk(st: Dictionary, out: Dictionary) -> void:
	var sp: Dictionary = st["sp"]
	var ring: int = maxi(3, int(st["tier"]["ring"]))
	var v: PackedVector3Array = out["v"]
	var nn: PackedVector3Array = out["n"]
	var cc: PackedColorArray = out["c"]
	var uv: PackedVector2Array = out["uv"]
	var idx: PackedInt32Array = out["i"]
	var bark_dark: Color = sp["bark"]
	var bark_light: Color = sp["bark2"]
	for br in (st["branches"] as Array):
		var pts: PackedVector3Array = br["pts"]
		var n: int = pts.size()
		if n < 2:
			continue
		var r0: float = float(br["r0"])
		var r1: float = float(br["r1"])
		var level: int = int(br["level"])
		var level_dark: float = minf(0.42, float(level) * 0.085)
		var vbase: int = v.size()
		var prev_nrm := Vector3.ZERO
		for i in n:
			var tan: Vector3
			if i == 0:
				tan = (pts[1] - pts[0]).normalized()
			elif i == n - 1:
				tan = (pts[n - 1] - pts[n - 2]).normalized()
			else:
				tan = (pts[i + 1] - pts[i - 1]).normalized()
			# 平行传输标架：把上一圈的法线投影到当前切平面，标架"尽量不转"地延续
			var nrm: Vector3
			if i == 0:
				var ref := Vector3.UP if absf(tan.y) < 0.9 else Vector3.RIGHT
				nrm = tan.cross(ref).normalized()
			else:
				nrm = prev_nrm - tan * prev_nrm.dot(tan)
				if nrm.length_squared() < 1e-8:
					var ref2 := Vector3.UP if absf(tan.y) < 0.9 else Vector3.RIGHT
					nrm = tan.cross(ref2)
				nrm = nrm.normalized()
			prev_nrm = nrm
			var bin: Vector3 = tan.cross(nrm).normalized()
			var t: float = float(i) / float(n - 1)
			var r: float = lerpf(r0, r1, pow(t, 0.72))
			for j in ring:
				var a: float = TAU * float(j) / float(ring)
				var radial: Vector3 = nrm * cos(a) + bin * sin(a)
				v.append(pts[i] + radial * r)
				nn.append(radial)
				# 顶点色当 AO：层级越深越暗；圆周背光面更暗（ca 就是法线朝向的近似）
				var shade: float = (0.55 * (1.0 - level_dark) \
					+ 0.45 * (1.0 - absf(cos(a)) * 0.35)) * 0.88
				var col: Color = bark_dark.lerp(bark_light, clampf(shade * (0.75 + 0.25 * (1.0 - t)), 0.0, 1.0))
				cc.append(col)
				uv.append(UV_OPAQUE)
		for i in n - 1:
			var a0: int = vbase + i * ring
			var b0: int = vbase + (i + 1) * ring
			for j in ring:
				var j2: int = (j + 1) % ring
				idx.append(a0 + j)
				idx.append(b0 + j)
				idx.append(a0 + j2)
				idx.append(a0 + j2)
				idx.append(b0 + j)
				idx.append(b0 + j2)


static func _emit_leaves(st: Dictionary, centers: Dictionary, out: Dictionary) -> void:
	var sp: Dictionary = st["sp"]
	var v: PackedVector3Array = out["v"]
	var nn: PackedVector3Array = out["n"]
	var cc: PackedColorArray = out["c"]
	var uv: PackedVector2Array = out["uv"]
	var idx: PackedInt32Array = out["i"]
	var leaf_a: Color = sp["leaf"]
	var leaf_b: Color = sp["leaf2"]
	var blossom: Color = sp["blossom"]
	var blossom_ratio: float = float(sp["blossom_ratio"])
	var seed_val: int = int(st["seed"])
	var leaves: Array = st["leaves"]
	var corner_uv := [
		Vector2(UV_LEAF.position.x, UV_LEAF.position.y),
		Vector2(UV_LEAF.position.x + UV_LEAF.size.x, UV_LEAF.position.y),
		Vector2(UV_LEAF.position.x + UV_LEAF.size.x, UV_LEAF.position.y + UV_LEAF.size.y),
		Vector2(UV_LEAF.position.x, UV_LEAF.position.y + UV_LEAF.size.y),
	]
	var cmap: Dictionary = centers.get("c", {})
	var rmap: Dictionary = centers.get("r", {})
	for li in leaves.size():
		var lf: Dictionary = leaves[li]
		var pos: Vector3 = lf["pos"]
		var gid: int = int(lf["gid"])
		var c: Vector3 = cmap.get(gid, pos + Vector3.UP)
		# ★ 球形法线：法线 = 叶位 − 球心。整丛叶子因此像一个球被打光
		var nrm: Vector3 = (pos - c)
		if nrm.length_squared() < 1e-6:
			nrm = Vector3.UP
		nrm = nrm.normalized()
		var right: Vector3 = nrm.cross(Vector3.UP)
		if right.length_squared() < 1e-6:
			right = nrm.cross(Vector3.RIGHT)
		right = right.normalized()
		var up2: Vector3 = right.cross(nrm).normalized()
		# 绕自身法线随机滚转，避免所有卡片一个方向（"刷卡"感）
		var roll: float = float(lf["roll"])
		var rr: Vector3 = right * cos(roll) + up2 * sin(roll)
		var uu: Vector3 = up2 * cos(roll) - right * sin(roll)
		var s: float = float(lf["size"]) * 0.5
		var col: Color = leaf_a.lerp(leaf_b, _hash01(seed_val, li, 7, 3))
		if blossom_ratio > 0.0 and _hash01(seed_val, li, 11, 5) < blossom_ratio:
			col = blossom
		# ★ 把"受光程度"直接烘进顶点色（项目一贯的"顶点色当 AO"口径）：
		#   ① 球面朝向：朝上的叶子亮、朝下的暗 —— 补上强光下被压平的体积；
		#   ② 冠内深度：离球心越近越暗（自遮挡的廉价近似），冠心才不会一片死平。
		#   动态光照只负责方向与高光，明暗梯度本来就该在顶点里。
		var ny: float = clampf(0.5 + 0.5 * nrm.y, 0.0, 1.0)
		var shade: float = 0.55 + 0.45 * ny
		var cr: float = maxf(float(rmap.get(gid, 1.0)), 0.001)
		var inner: float = clampf((pos - c).length() / cr, 0.0, 1.0)
		shade *= 0.74 + 0.26 * inner
		# 叶色微微抖动（±4%），只用明度不用色相 —— 单色是球形法线成立的前提
		var lum: float = (0.97 + _hash01(seed_val, li, 17, 9) * 0.06) * shade
		col = Color(col.r * lum, col.g * lum, col.b * lum, 1.0)
		var base_idx: int = v.size()
		var p0: Vector3 = pos - rr * s - uu * s
		var p1: Vector3 = pos + rr * s - uu * s
		var p2: Vector3 = pos + rr * s + uu * s
		var p3: Vector3 = pos - rr * s + uu * s
		for k in 4:
			var pt: Vector3 = [p0, p1, p2, p3][k]
			v.append(pt)
			nn.append(nrm)
			cc.append(col)
			uv.append(corner_uv[k])
		# 双面可见（材质 cull_disabled），绕序无所谓
		idx.append(base_idx)
		idx.append(base_idx + 1)
		idx.append(base_idx + 2)
		idx.append(base_idx)
		idx.append(base_idx + 2)
		idx.append(base_idx + 3)


## 把整棵树归一化到目标高度，并且根部落在 y = 0
static func _fit_height(verts: PackedVector3Array, target_height: float) -> PackedVector3Array:
	var lo := INF
	var hi := -INF
	for p in verts:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	var h: float = hi - lo
	if h <= 0.001:
		return verts
	var s: float = target_height / h
	var out := PackedVector3Array()
	out.resize(verts.size())
	for i in verts.size():
		var p: Vector3 = verts[i]
		out[i] = Vector3(p.x * s, (p.y - lo) * s, p.z * s)
	return out
