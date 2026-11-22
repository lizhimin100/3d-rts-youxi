class_name RtsTerrainAssets
extends RefCounted
## 职责：地表材质 / 图集 / 贴图 / 一格米数的**唯一真源**（资源路径常量）。
## 属于：Screens/world/art（表现层）
##
## 为什么单独一个文件：这些路径原本挂在旧的 `RtsTerrain`（整块程序化地形渲染器）上，
## 2026-11-22 旧单兵系统下线时那个渲染器被物理删除，但**底壳编辑器还在用同一份材质与贴图**
## —— 编辑器看到的地表必须等于局内看到的地表。所以把"路径"从"渲染器"里拆出来单独存一份，
## 谁也不许再写第二份路径字面量。

const MATERIAL_PATH := "res://Content/art/材质/地形材质.tres"
const ATLAS_PATH := "res://Content/art/贴图/地形/材质/草泥/atlas_草泥_rgba.png"
const ATLAS_N_PATH := "res://Content/art/贴图/地形/材质/草泥/atlas_草泥_n.png"
const TEX_GRASS_PATH := "res://Content/art/贴图/地形/草地.png"
const TEX_DIRT_PATH := "res://Content/art/贴图/地形/泥土.png"
const TEX_CRACKED_PATH := "res://Content/art/贴图/地形/裂纹泥地.png"
const ROCK_DETAIL_PATH := "res://Content/art/贴图/rock_albedo.png"
## 一格多少米（地表材质平铺距离；改它等于改所有地表花纹的密度）。
const TILE_M: float = 8.0
## 地块/棋盘皮肤表：**可换皮的唯一开关**（编辑器与局内都读这一份）。
const BOARD_SKIN_PATH := "res://Content/data/shell_board.json"
static var _skin: Dictionary = {}
static var _skin_loaded := false


## 皮肤表里的材质路径（tile_a / tile_b / rim / block_side / block_bottom）。
## 数据缺失时返回空串，调用方自己兜底；**不在代码里写第二份路径**。
static func skin_path(key: String) -> String:
	if not _skin_loaded:
		_skin_loaded = true
		var f := FileAccess.open(BOARD_SKIN_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				var mats: Variant = (parsed as Dictionary).get("materials", {})
				if mats is Dictionary:
					_skin = mats as Dictionary
	return String(_skin.get(key, ""))


## 取皮肤材质（带缓存；不存在返回 null）。
static func skin_material(key: String) -> Material:
	var path := skin_path(key)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Material

## 生态换色：[基色, 混合量 0~1]。底壳的 biome 字段只影响**观感**，不影响任何判定。
const BIOME_TINT: Dictionary = {
	"temperate": [Color(0.55, 0.72, 0.46), 0.00],
	"arid": [Color(0.74, 0.61, 0.38), 0.62],
	"snow": [Color(0.86, 0.90, 0.95), 0.72],
	"volcanic": [Color(0.30, 0.23, 0.21), 0.66],
	"swamp": [Color(0.26, 0.34, 0.22), 0.55],
}


## 生态换色参数：[基色, 混合量]；未知生态按温带。
static func biome_tint(id: String) -> Array:
	var raw: Variant = BIOME_TINT.get(id, BIOME_TINT["temperate"])
	if raw is Array and (raw as Array).size() >= 2:
		return [(raw as Array)[0] as Color, float((raw as Array)[1])]
	return [Color(0.55, 0.72, 0.46), 0.0]


# ===========================================================================
# 地形外观（**唯一实现**：编辑器与局内共用，不接受第二份拷贝）
# ===========================================================================
#
# 为什么把这三件事从 shell_view 搬到这里：地形材质的三件套 —— ①顶点色口径
# ②mat_map 格点表 ③材质参数绑定 —— 原本只写在编辑器里，局内另起一份"顶点色 + 平涂"，
# 于是同一块地在编辑器里是草地贴图、进游戏变成纯色塑料布（2026-11-22 的真实现象）。
# 现在只有这一份：谁画地形都调它，观感不可能再分叉。

## 地块格点表的边长（格点数）。着色器里 map_half 是**同一个值管两轴**，
## 所以 z 方向并不是从 -map_half 开始：多留几行/列，按整数格点索引填。
static func mat_lattice_n(size_x: float) -> int:
	return maxi(17, int(ceil(size_x / TILE_M)) + 2)


## 把 surface 槽位翻译成魔兽 3 口径的 mat_map（R8，1 texel = 1 个 8m 格点）。
## 草丛=0 / 泥土=255；岩石、沙地在地块体系里没有对应材质，走覆盖层贴花。
static func mat_map_texture(index: Array, cols: int, rows: int, origin_x: float,
		origin_z: float, cell: float, size_x: float, size_z: float) -> ImageTexture:
	var n := mat_lattice_n(size_x)
	var map_half := size_x * 0.5
	var bytes := PackedByteArray()
	bytes.resize(n * n)
	for j in n:
		var wz := -map_half + float(j) * TILE_M
		var inside_z := wz >= (-size_z * 0.5 - TILE_M) and wz <= (size_z * 0.5 + TILE_M)
		for i in n:
			var wx := -map_half + float(i) * TILE_M
			var v := 0
			if inside_z and wx >= (-size_x * 0.5 - TILE_M) and wx <= (size_x * 0.5 + TILE_M):
				var c := clampi(int(round((wx - origin_x) / maxf(cell, 0.01))), 0, maxi(cols - 1, 0))
				var r := clampi(int(round((wz - origin_z) / maxf(cell, 0.01))), 0, maxi(rows - 1, 0))
				var k := r * cols + c
				if k >= 0 and k < index.size() and int(index[k]) == 1:
					v = 255
			bytes[j * n + i] = v
	var img := Image.create(n, n, false, Image.FORMAT_R8)
	img.set_data(n, n, false, Image.FORMAT_R8, bytes)
	return ImageTexture.create_from_image(img)


## 顶点色口径：rgb = 1.0 附近的乘法染色（大尺度冷暖 ±3.5% / 营地压暗 / 陡面偏灰），a = 干度。
## **顶点色在 Godot 里按线性解释**，而这里算的是 sRGB 语义的乘法系数 —— 系数乘的是着色器里
## 已经 sRGB 解码过的贴图颜色，所以不要在这里 srgb_to_linear（那是纯色直出的口径）。
##
## `variation` = 大尺度冷暖起伏的倍率（数据 `look.terrain.variation`）。
## 为什么要有这个旋钮：底材贴图本身的对比只有 0.9%（见 `地形.gdshader` 里 base_contrast 的说明），
## 大尺度上再没有起伏，整片地就是一整块色板。这里给的是**米级的低频冷暖**，
## 和贴图的高频细节叠在一起，地形才像"一块地"而不是"一张纸"。
static func vertex_tint(pos: Vector3, normal: Vector3, h_min: float, h_max: float,
		camps: Array, variation: float = 1.0) -> Color:
	var rng_h := maxf(h_max - h_min, 0.001)
	var alt := clampf((pos.y - h_min) / rng_h, 0.0, 1.0)
	var up := clampf(normal.y, 0.0, 1.0)
	var vk := clampf(variation, 0.0, 3.0)
	var warm := sin(pos.x * 0.052 + pos.z * 0.031) * 0.55 \
		+ sin(pos.z * 0.074 - pos.x * 0.021 + 1.7) * 0.45
	# 第二层更低频、幅度更小的冷暖：破掉第一层 120m 级的对称感
	var warm2 := sin(pos.x * 0.017 - pos.z * 0.013 + 0.6) * 0.6
	var k := 1.0 + (warm * 0.030 + warm2 * 0.022) * vk
	var tr := k * 1.014
	var tg := k
	var tb := k * 0.974
	var dry := smoothstep(0.30, 0.95, alt) * 0.85 + warm * 0.12
	var steep := 1.0 - up
	if steep > 0.06:
		var st := clampf((steep - 0.06) / 0.30, 0.0, 1.0)
		tr = lerpf(tr, 0.92, st * 0.7)
		tg = lerpf(tg, 0.94, st * 0.7)
		tb = lerpf(tb, 1.02, st * 0.7)
		dry *= 1.0 - st * 0.6
	var camp := 0.0
	var p2 := Vector2(pos.x, pos.z)
	for bp in camps:
		camp = maxf(camp, 1.0 - smoothstep(15.0, 34.0, p2.distance_to(bp)))
	if camp > 0.001:
		var dark := lerpf(1.0, 0.925, camp)
		tr *= dark
		tg *= dark
		tb *= dark
		dry *= lerpf(1.0, 0.45, camp)
	return Color(clampf(tr, 0.0, 1.6), clampf(tg, 0.0, 1.6), clampf(tb, 0.0, 1.6),
		clampf(dry, 0.0, 1.0))


## 把"一块地"需要的贴图/图集/格点表全绑到材质上（**必须传 duplicate 过的材质**：
## 底壳会按自己的尺寸改 map_half，改共享资源会污染下一张图）。
static func bind_terrain_material(mat: ShaderMaterial, size_x: float, size_z: float,
		index: Array, cols: int, rows: int, origin_x: float, origin_z: float,
		cell: float, biome: String = "temperate") -> void:
	if mat == null:
		return
	mat.set_shader_parameter("tile_m", TILE_M)
	mat.set_shader_parameter("map_half", size_x * 0.5)
	mat.set_shader_parameter("mat_cells", mat_lattice_n(size_x))
	var bt := biome_tint(biome)
	mat.set_shader_parameter("biome_color", bt[0])
	mat.set_shader_parameter("biome_mix", bt[1])
	var slots := {
		"atlas_rgba": ATLAS_PATH,
		"atlas_n": ATLAS_N_PATH,
		"tex_grass": TEX_GRASS_PATH,
		"tex_dirt": TEX_DIRT_PATH,
		"tex_cracked": TEX_CRACKED_PATH,
		"rock_detail": ROCK_DETAIL_PATH,
	}
	for key in slots:
		var path: String = slots[key]
		if not ResourceLoader.exists(path):
			continue
		var t := load(path) as Texture2D
		if t != null:
			mat.set_shader_parameter(key, t)
	mat.set_shader_parameter("mat_map",
		mat_map_texture(index, cols, rows, origin_x, origin_z, cell, size_x, size_z))


## 载入地形材质的**独立副本**（共享资源只读；每个地块自己一份参数）。
static func make_terrain_material() -> ShaderMaterial:
	if not ResourceLoader.exists(MATERIAL_PATH):
		return null
	var base := load(MATERIAL_PATH)
	if base is ShaderMaterial:
		return (base as ShaderMaterial).duplicate(true) as ShaderMaterial
	return null


# ===========================================================================
# 观感数据 → 着色器参数（数据化：观感只改 map_shells.json 的 look.terrain）
# ===========================================================================
#
# 类型：f = 浮点 / i = 整数 / c = 颜色（"#RRGGBB" 字符串或 Color）。
# **表里没有的 key 一律不写** —— 少写一个参数就是"退回材质默认值"，
# 所以这张表就是"哪些旋钮允许美术从数据里调"的清单。
const LOOK_UNIFORMS := {
	"albedo_gain": "f",
	"base_contrast": "f",
	"base_sat": "f",
	"base_tile_m": "f",
	"detail_tile_m": "f",
	"detail_gain": "f",
	"tint_strength": "f",
	"dry_strength": "f",
	"atlas_n_strength": "f",
	"band_edge": "f",
	"band_soft": "f",
	"shadow_strength": "f",
	"ambient_flat": "f",
	"rock_detail_gain": "f",
	"rock_scale": "f",
	"max_lod": "f",
	"variant_count": "i",
	"mat_a_tint": "c",
	"mat_b_tint": "c",
	"base_mean": "c",
	"shadow_color": "c",
	"rock_tint": "c",
}


## 把 `look.terrain` 里的旋钮写进材质。返回真正写进去的条数（自检读它）。
static func apply_look(mat: ShaderMaterial, look: Dictionary) -> int:
	if mat == null or look.is_empty():
		return 0
	var n := 0
	for key in LOOK_UNIFORMS.keys():
		if not look.has(key):
			continue
		var kind := String(LOOK_UNIFORMS[key])
		var v: Variant = look[key]
		match kind:
			"f":
				mat.set_shader_parameter(StringName(key), float(v))
			"i":
				mat.set_shader_parameter(StringName(key), int(v))
			"c":
				var c := color_of(v, Color.WHITE)
				mat.set_shader_parameter(StringName(key), c)
			_:
				continue
		n += 1
	return n


## 数据里的颜色：既接受 "#RRGGBB" 字符串，也接受 Color（Color 直传，不走 sRGB 换算）。
static func color_of(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v as Color
	if v is String and not String(v).is_empty():
		return Color(String(v))
	return fallback


## 地表链路探针（自检 / 截图断言用）：**读的是材质上真的绑了什么**，不是读源码有没有写。
## 返回 {shader: bool, tex: int, atlas: int, mat_map_px: int, contrast: float, detail: float}
static func probe(mat: ShaderMaterial) -> Dictionary:
	if mat == null:
		return {"shader": false, "tex": 0, "atlas": 0, "mat_map_px": 0,
			"contrast": 0.0, "detail": 0.0}
	var tex := 0
	for key in ["tex_grass", "tex_dirt", "tex_cracked", "rock_detail"]:
		if mat.get_shader_parameter(StringName(key)) is Texture2D:
			tex += 1
	var atlas := 0
	for key in ["atlas_rgba", "atlas_n"]:
		if mat.get_shader_parameter(StringName(key)) is Texture2D:
			atlas += 1
	var px := 0
	var mm: Variant = mat.get_shader_parameter(&"mat_map")
	if mm is Texture2D and (mm as Texture2D).get_width() > 0:
		px = (mm as Texture2D).get_width()
	return {
		"shader": true,
		"tex": tex,
		"atlas": atlas,
		"mat_map_px": px,
		"contrast": float(mat.get_shader_parameter(&"base_contrast")),
		"detail": float(mat.get_shader_parameter(&"detail_gain")),
	}
