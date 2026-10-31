class_name WarbandStyle
extends RefCounted
## **铁誓军团建筑材质层**
##
## 资产包（铁誓军团_资产包_v1）的三座建筑是 4 材质 / 4 网格：
##   team / team_trim  —— 纯色阵营材质（只改这两个）
##   主体             —— 512² 图集 + ORM（R=AO / G=粗糙度 / B=金属度）
##   自发光           —— 窗光 / 炉火 / 门缝
##
## v3.7 起**不再挂任何自定义 shader**（原 铁誓主体.gdshader / 铁誓自发光.gdshader 已删除）：
##   · 图集是 5×5 的**纯色格**，格与格之间有黑间隙，面 UV 钉在格心（u,v∈{0.1..0.9}）；
##   · 三平面细节层把 1~2m 一铺的砌石/瓦垄压在纯色格上，RTS 机位下高频细节先糊成
##     "橙黑噪点"，机位一动就跳 —— 玩家报的"所有建筑都闪"有一半是它；
##   · 资产包本体只要 StandardMaterial3D + 图集 + ORM 就能成立，加法反而是负债。
##
## 资产包 README 的硬要求（照做）：
##   · 换阵营只改 team / team_trim —— 主体图集一点不染；
##   · ORM 的 R 通道是 AO —— glTF 没写 occlusionTexture，Godot 导入后 ao_texture 是空的；
##     这里补上，否则石缝/屋檐的接触阴影全丢，模型会"贴纸感"；
##   · 自发光 = emissiveTexture × emissiveStrength 1.8（KHR_materials_emissive_strength），
##     底色 0.02 近黑。窗玻璃因此是暗蓝微光、炉火才是亮的，不需要按格子分能量。
##
## 缓存按 (建筑, 材质种, 阵营色) 共享，同阵营 100 座只占一份材质。

const TEX_DIR := "res://美术/模型/"
## 自发光专用 shader（BaseMaterial3D 的 emission_texture 在本工程里不调制颜色）
const GLOW_SHADER := "res://美术/着色器/铁誓自发光.gdshader"
const AO_LIGHT_AFFECT := 0.42
## 自发光强度。
##
## 资产包原值 1.8（KHR_materials_emissive_strength），那是按"夜景资产"标的；
## 而我们的自发光图集是**纯色格**：窗玻璃那一格本身是 (0.72,0.53,0.28) 的暖白，
## ×1.8 再走 ACES 之后直接烧成一片白纸（玩家报的"窗户泛白"就是这个）；
## 铁匠铺里那口炉/砧也是同理，变成一坨白色。
## 实测（同一机位/A-B 截图）：过曝像素占比 1.8 时 8.5%、0.9 时 7.95%、0.45 时 1.8%。
## 取 0.5：窗户回到"暗玻璃 + 一点点暖光"，炉火还剩一点余温，不再糊成白块。
const EMIT_ENERGY := 0.85
## 自发光层的底材（玻璃底）。0.02 近乎纯黑会让窗户在暗处变成黑洞；
## 给一点冷调蓝灰，白天看是玻璃、有微光时是窗。
const GLOW_BASE := Color(0.030, 0.036, 0.052)
## 玻璃的高光。★ 不要做得太"亮"：窗户正对天空，粗糙度低 + 镜面高
## 会把整片天光反射进玻璃，白天看又是一块白（第一次调成 0.30/0.55 就翻车了）。
## 0.62 / 0.20 = 只有一眼"玻璃感"，不会反成白板。
const GLOW_ROUGHNESS := 0.88
const GLOW_SPECULAR := 0.12
## team_trim 保留资产包的金作为骨架，只吃 38% 阵营色：
## 全染阵营色会把三座建筑共有的金线/门钉/腰线一起洗掉，远景就只剩两块色。
const TRIM_GOLD := Color(0.95, 0.78, 0.42)
const TRIM_TEAM_MIX := 0.38
## ★ 图集必须 Nearest（等价于"不采 mipmap"）：
##   格心取色 + 格间黑缝，任何线性/分级过滤都会把邻格和缝混进来 —— 也就是"串色"。
const ATLAS_FILTER := BaseMaterial3D.TEXTURE_FILTER_NEAREST

static var _cache: Dictionary = {}
static var _tex_cache: Dictionary = {}


static func apply(root: Node3D, team_color: Color) -> int:
	if root == null:
		return 0
	var base := _base_name(root)
	if base.is_empty():
		return 0
	# ★ 大小写先试对的那个：磁盘上是 `_ORM.png`（大写）。
	#   先请求 `_orm.png` 在 Windows 上能"侥幸"命中，但会刷一条
	#   `Case mismatch opening requested file` 警告（而且导出到大小写敏感平台会真的找不到）。
	var orm := _tex(base + "_ORM.png")
	if orm == null:
		orm = _tex(base + "_orm.png")
	var changed := 0
	for mi in _collect(root):
		if mi.mesh == null:
			continue
		# 地板 UV 已在 GLB 里烘焙（9 个近/中/远网格），运行时不再复制网格。
		var n := mi.mesh.get_surface_count()
		for i in n:
			var src: Material = mi.get_surface_override_material(i)
			if src == null:
				src = mi.mesh.surface_get_material(i)
			if src == null:
				continue
			var kind := _kind_of(src)
			if kind.is_empty():
				continue
			var mat := _make(kind, base, team_color, src, orm)
			if mat == null:
				continue
			# 调试：WB_HIDE=glow / main / team / trim 可以单独关掉一层看结构
			var hide_tag := OS.get_environment("WB_HIDE")
			if not hide_tag.is_empty() and hide_tag == kind:
				mi.visible = false
			mi.set_surface_override_material(i, mat)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			changed += 1
	return changed


## 只认资产包这四颗材质。别的模型（旧 v5/v6 资产）原样返回 0，
## 让 ArtKit 继续走它原来的 MatKit / 染色兜底，互不干扰。
static func _kind_of(src: Material) -> String:
	var nm := String(src.resource_name)
	if nm.is_empty() and not src.resource_path.is_empty():
		nm = src.resource_path.get_file().get_basename()
	if nm == "team":
		return "team"
	if nm == "team_trim":
		return "trim"
	if nm == "主体":
		return "main"
	if nm == "自发光":
		return "glow"
	return ""


static func _base_name(root: Node3D) -> String:
	var p := String(root.get_meta("model_path", ""))
	if p.is_empty():
		if root.name.begins_with("模型_"):
			p = String(root.name).substr(3) + ".glb"
	if p.is_empty():
		return ""
	var b := p.get_file().get_basename()
	for suf in ["_中", "_远", "_近"]:
		if b.ends_with(suf):
			b = b.substr(0, b.length() - suf.length())
	return b


## 按文件名加载并缓存（细节贴图已停用，这里只作 ORM/自发光的兜底）
static func _tex(file: String) -> Texture2D:
	if _tex_cache.has(file):
		return _tex_cache[file] as Texture2D
	var t: Texture2D = null
	var p := TEX_DIR + file
	if ResourceLoader.exists(p):
		t = load(p) as Texture2D
	_tex_cache[file] = t
	return t


## 从导入后的材质里取 ORM 图：glTF 的 metallicRoughnessTexture 被拆到
## metallic_texture / roughness_texture 两张槽（同一张图），优先用它们，
## 免得靠文件名猜（美术/模型 下同时存在 _orm.png 与 _ORM.png 两份）。
static func _orm_of(bm: BaseMaterial3D, base: String) -> Texture2D:
	if bm.metallic_texture != null:
		return bm.metallic_texture
	if bm.roughness_texture != null:
		return bm.roughness_texture
	# 同上：磁盘上是 `_ORM.png`，先按正确大小写找
	var t := _tex(base + "_ORM.png")
	return t if t != null else _tex(base + "_orm.png")


static func _make(kind: String, base: String, team_color: Color, src: Material,
		orm: Texture2D) -> Material:
	var key := "%s|%s|%s" % [base, kind, team_color.to_html(false)]
	if _cache.has(key):
		return _cache[key] as Material
	var bm := src.duplicate() as BaseMaterial3D
	if bm == null:
		return null
	bm.resource_name = "WB_%s_%s" % [base, kind]
	bm.texture_filter = ATLAS_FILTER
	match kind:
		"team":
			bm.albedo_color = team_color
			bm.albedo_texture = null
			bm.metallic = 0.0
			bm.roughness = 0.68
			bm.metallic_specular = 0.45
			bm.emission_enabled = false
		"trim":
			bm.albedo_color = TRIM_GOLD.lerp(team_color, TRIM_TEAM_MIX)
			bm.albedo_texture = null
			bm.metallic = 0.42
			bm.roughness = 0.32
			bm.metallic_specular = 0.6
			bm.emission_enabled = true
			bm.emission = bm.albedo_color
			bm.emission_energy_multiplier = 0.06
		"main":
			# 只用资产包给的图集 + ORM。glTF 里 metallicFactor / roughnessFactor 缺省 = 1，
			# 也就是"全交给贴图"；旧版写死 roughness=1.0 / metallic=0.55 等于把 ORM 的 B 通道废掉。
			bm.albedo_color = Color(1, 1, 1, 1)
			# ★ 2026-10-31：`metallic = 1.0` 只在**真有 ORM 图**时才成立（B 通道给金属度）。
			#   方块人（单位资产）没有 ORM 图：写死 1.0 等于"整只兵纯金属"，实机是一条黑影。
			#   没有 ORM 就保留 glb 里带的 metallicFactor / roughnessFactor（方块人是 0 / 0.88）。
			if orm == null:
				orm = _orm_of(bm, base)
			if orm != null:
				bm.metallic = 1.0
				bm.roughness = 1.0
			if orm != null:
				# ORM.R = AO。glTF 的 occlusionTexture 缺省，这一步是补回来的。
				bm.ao_enabled = true
				bm.ao_texture = orm
				bm.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
				bm.ao_light_affect = AO_LIGHT_AFFECT
			# 派生的 _normal.png 是"格心纯平"的图集，钉在格心上采样恒为 (0,0,1)，没有信息。
			bm.normal_enabled = false
		"glow":
			# ★ 这一层不走 BaseMaterial3D：实测它的 emission_texture 不参与调制
			#   （见 美术/着色器/铁誓自发光.gdshader 顶部），整层会变成纯色加亮 = 泛白。
			#   改由专用 shader 采样图集，窗/炉/旗各按自己的格子发光。
			var sm := _glow_material(base)
			if sm == null:
				# 兜底：贴图或 shader 缺失时**关掉自发光**，只留暗底材。
				# 宁可没有窗光，也绝不能回退到"整片白"（那正是玩家报的 bug）。
				bm.albedo_color = GLOW_BASE
				bm.metallic = 0.0
				bm.roughness = GLOW_ROUGHNESS
				bm.metallic_specular = GLOW_SPECULAR
				bm.emission_enabled = false
				sm = bm
			_cache[key] = sm
			return sm
	_cache[key] = bm
	return bm


# ===========================================================================
# 地板 UV 归一（B 版）——"院子/训练场"那块马赛克
# ---------------------------------------------------------------------------
# 三座建筑的院子是一块 y≈0 的**单面板**（法线朝下，靠 doubleSided 双面渲染），
# 被切成上百个三角形，每个三角形钉在**不同的图集格心**上（兵营/铁匠铺各 5 格、
# 大本营 1 格）。于是每个三角形在自己的 UV 跨度里横跨大半张图集：屏幕上放大缩小
# 就换一次 mip，颜色跟着跳 —— 玩家看到的就是"地面在闪 / 橙黑噪点"。
#
# 归一口径：取这块板**自己用得最多的那个格心**，把板上全部顶点的 UV 指过去。
# 用最多的那个而不是写死格子，是因为三座房子用途不同（土院 / 铺装 / 石台），
# 谁的主色就该是谁的主色；写死 (0.5,0.5) 会把院子染成深褐。
# 只动 y≈0 且法线竖直的顶点：院缘、台阶、环形构件、墙裙全部不动。
# 开关：WB_YARD_UV=0 / off / false 可关掉，用来做 A/B 对比截图。
# ===========================================================================

const YARD_Y_EPS := 0.06
const YARD_N_Y := 0.6
const YARD_MIN_VERTS := 8

static var _yard_meshes: Dictionary = {}

static func _yard_uv_enabled() -> bool:
	var v := OS.get_environment("WB_YARD_UV").to_lower()
	return v != "0" and v != "off" and v != "false"


static func _yard_fix(mi: MeshInstance3D) -> void:
	var src := mi.mesh as ArrayMesh
	if src == null:
		return
	# 缓存键 = 网格名 + 顶点总数。
	# ★ 不能用纯网格名：近/中/远三个 LOD 的网格**同名**（都叫 兵营_plinth_a_001），
	#   只按名字缓存会把远 LOD 换成近 LOD 的网格（建筑在远景里突然变精细/变形）。
	#   加上顶点数就能区分 LOD，同时让我方/敌方同款建筑共用一份修好的网格。
	var vsum := 0
	for sj in src.get_surface_count():
		var arr_j: Array = src.surface_get_arrays(sj)
		if arr_j.is_empty() or arr_j[Mesh.ARRAY_VERTEX] == null:
			continue
		var vj: PackedVector3Array = arr_j[Mesh.ARRAY_VERTEX]
		vsum += vj.size()
	var key: Variant = "%s|%d" % [String(src.resource_name), vsum]
	if _yard_meshes.has(key):
		mi.mesh = _yard_meshes[key] as ArrayMesh
		return
	# 先扫一遍：不是铁誓建筑（没有"主体"面）就直接放过，别给单位多复制一份网格
	var has_main := false
	for si in src.get_surface_count():
		var m0: Material = src.surface_get_material(si)
		if m0 != null and _kind_of(m0) == "main":
			has_main = true
			break
	if not has_main:
		_yard_meshes[key] = src
		return
	var out := ArrayMesh.new()
	out.resource_name = String(src.resource_name) + "_yardfix"
	var touched := 0
	for si in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(si)
		var mat: Material = src.surface_get_material(si)
		if mat != null and _kind_of(mat) == "main":
			touched += _unify_yard_surface(arrays)
		out.add_surface_from_arrays(src.surface_get_primitive_type(si), arrays)
		out.surface_set_material(out.get_surface_count() - 1, mat)
	if touched <= 0:
		_yard_meshes[key] = src
		return
	_yard_meshes[key] = out
	mi.mesh = out
	print("[建筑] 地板 UV 归一：%s（%d 个顶点）" % [src.resource_name, touched])


## 就地改 arrays 里的 TEX_UV，返回改掉的顶点数
static func _unify_yard_surface(arrays: Array) -> int:
	if arrays.is_empty() or arrays[Mesh.ARRAY_TEX_UV] == null:
		return 0
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if nrm.size() != pos.size():
		return 0
	var hits: Array[int] = []
	var tally: Dictionary = {}
	for i in pos.size():
		if absf(pos[i].y) > YARD_Y_EPS or absf(nrm[i].y) < YARD_N_Y:
			continue
		hits.append(i)
		var c := Vector2(snappedf(uv[i].x, 0.01), snappedf(uv[i].y, 0.01))
		tally[c] = int(tally.get(c, 0)) + 1
	if hits.size() < YARD_MIN_VERTS:
		return 0
	var best: Vector2 = uv[hits[0]]
	var best_n := -1
	for c in tally:
		var n: int = int(tally[c])
		if n > best_n:
			best_n = n
			best = c
	for i in hits:
		uv[i] = best
	arrays[Mesh.ARRAY_TEX_UV] = uv
	return hits.size()


## 自发光层的专用材质（采样图集，按格子发光）。
## 图集取不到时返回 null → 调用方跳过这一层（宁可没有窗光，也不给一块白板）。
static var _glow_mat_cache: Dictionary = {}

static func _glow_material(base: String) -> Material:
	if _glow_mat_cache.has(base):
		return _glow_mat_cache[base] as Material
	var tex := _tex(base + "_自发光.png")
	if tex == null:
		_glow_mat_cache[base] = null
		return null
	var sh := load(GLOW_SHADER) as Shader
	if sh == null:
		_glow_mat_cache[base] = null
		return null
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("glow_tex", tex)
	m.set_shader_parameter("base_col", GLOW_BASE)
	m.set_shader_parameter("energy", EMIT_ENERGY)
	m.set_shader_parameter("rough", GLOW_ROUGHNESS)
	m.set_shader_parameter("spec", GLOW_SPECULAR)
	_glow_mat_cache[base] = m
	return m


static func _collect(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n as MeshInstance3D)
		for c in n.get_children():
			stack.append(c)
	return out


static func clear_cache() -> void:
	_cache.clear()
	_tex_cache.clear()
	_glow_mat_cache.clear()