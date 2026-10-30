class_name MatKit
extends RefCounted
## **材质库**：把 GLB 里的 "M_<zone>" 材质换成统一的卡通着色器，并按 zone 上色。
##
## 为什么要有这一层（而不是在 Blender 里就定死颜色）：
##   1. 改配色不用重导模型 —— 调 联盟调色板.tres 就全场生效（用户明确要求"改色直接调参出结果"）；
##   2. 队伍色（_team 后缀的 zone）在运行时注入，同一份资产敌我共用；
##   3. 材质按 (zone, 队伍色) 缓存共享 —— 100 个步兵只占一份 ShaderMaterial 内存，
##      而不是每个单位 duplicate 一份（老实现是逐 surface 复制，内存和 draw call 都被吃掉）。
##
## 命名协议（与工具/建模/v3/kit3.py 对齐）：
##   M_<zone>       普通部件
##   M_<zone>_team  队伍色区（布/旗帜/屋面）
## 识别不到 M_ 前缀的材质一律**原样保留**（兼容旧资产，绝不把模型弄花）。

const SHADER_PATH := "res://美术/着色器/卡通.gdshader"
const PALETTE_PATH := "res://美术/调色板/联盟调色板.tres"
## 角色描边（反向外壳）。只给带骨骼的角色挂 —— 建筑面积大、网格多，
## 全挂会让 draw call 翻倍且黑边过粗（v1.1 已踩过这个坑）。
const OUTLINE_PATH := "res://美术/着色器/描边.gdshader"
const OUTLINE_WIDTH := 0.012
## 是否给角色开描边。**默认关**，原因（实测，别轻易改回去）：
##   这套描边是"按视距加粗"的反向外壳，RTS 镜头离地 30m 时单位只有约 40px 高，
##   描边一挂就把整个人糊成一坨黑边，蓝披风/钢甲的层次全丢（截图对比一眼可见）。
##   近景/过场/头像台想要描边时，运行时把 MatKit.outline_enabled 置 true 再刷新即可。
static var outline_enabled: bool = false

## 队伍色区默认强度（调色板里可以逐 zone 覆盖）
const DEFAULT_TEAM_STRENGTH := 0.9
## 卡通色阶数
const RAMP_STEPS := 4
## 贴图细节层增益：贴图均值 0.9，乘 1.06 拉回中性（不改变调色板明度语义）
const DETAIL_GAIN := 1.06
## 法线总强度倍率：Blender 侧法线节点 strength × 这个系数 = 引擎侧强度。
## 1.15 是在 RTS 镜头高度（约 26m）下"看得见凹凸、又不炸成噪点"的实测值。
const NORMAL_BOOST := 1.15

# --- 角色（单位）与建筑分开的两档曝光 ---------------------------------------
# 为什么必须分开：建筑是"大面积浅色石材"，按 0.94 压一档才对；
# 单位是"深色军装 + 亮钢盔"，同一档压下去中间调全死，远看就是黑白剪影
# （老板原话"多多少少都有毛病、材质各玩各的"）。
# 角色提亮 + 减 AO + 加强边缘光，才有"深色但看得清层次"的读法。
## 建筑 / 道具
const GAIN_PROP := 0.94
const AO_PROP := 0.55
const RIM_PROP := 0.10
## 角色（走 is_char 那条路时用）
const GAIN_CHAR := 1.12
const AO_CHAR := 0.30
const RIM_CHAR := 0.20

static var _materials: Dictionary = {}      # key -> ShaderMaterial
static var _outline: ShaderMaterial = null
static var _shader: Shader = null
static var _palette: RtsPalette = null
static var _enabled: bool = true


## 取（并在需要时加载）调色板
static func palette() -> RtsPalette:
	if _palette != null:
		return _palette
	if ResourceLoader.exists(PALETTE_PATH):
		_palette = load(PALETTE_PATH) as RtsPalette
	if _palette == null:
		_palette = RtsPalette.new()
	return _palette


## 解析材质名 → zone（返回空串表示"不是我们的材质"）
static func zone_of(mat_name: String) -> String:
	if not mat_name.begins_with("M_"):
		return ""
	var s := mat_name.substr(2)
	var cut := s.find("_team")
	if cut >= 0:
		s = s.substr(0, cut)
	return s


static func is_team(mat_name: String) -> bool:
	return mat_name.find("_team") >= 0


static func _get_shader() -> Shader:
	if _shader != null:
		return _shader
	if ResourceLoader.exists(SHADER_PATH):
		_shader = load(SHADER_PATH) as Shader
	return _shader


## 取一个 zone 的材质（缓存共享）。team_color 只在 _team 区被用到。
##
## v5：把 GLB 里带出来的手绘贴图 + 法线接进卡通着色器。
##   贴图**不进调色板语义** —— 它只是乘算在 base_color 上的细节层（均值 0.9），
##   但不同贴图组合必须分开缓存，所以 key 里带贴图资源路径。
static func material_for(zone: String, team_color: Color, is_team_zone: bool,
		outline: bool = false, alb_tex: Texture2D = null, nrm_tex: Texture2D = null,
		nrm_scale: float = 1.0, is_char: bool = false) -> ShaderMaterial:
	var pal := palette()
	var key := zone
	if is_team_zone:
		key += "#" + team_color.to_html(false)
	if outline:
		key += "|o"
	# 角色档必须进 key：同一个 steel zone 在建筑和单位上是两份参数，
	# 不进 key 会互相顶掉（后建的那份覆盖前面所有实例）。
	if is_char:
		key += "|char"
	if alb_tex != null:
		key += "|a:" + alb_tex.resource_path
	if nrm_tex != null:
		key += "|n:" + nrm_tex.resource_path + "@%.2f" % nrm_scale
	if _materials.has(key):
		return _materials[key]
	var sh := _get_shader()
	if sh == null:
		return null
	var m := ShaderMaterial.new()
	m.shader = sh
	var base: Color = pal.colors.get(zone, pal.fallback)
	var strength: float = 0.0
	if is_team_zone:
		strength = float(pal.team_zones.get(zone, DEFAULT_TEAM_STRENGTH))
	m.set_shader_parameter("base_color", base)
	m.set_shader_parameter("roughness", float(pal.roughness.get(zone, 0.82)))
	m.set_shader_parameter("metallic", float(pal.metallic.get(zone, 0.0)))
	m.set_shader_parameter("tint", team_color if is_team_zone else Color(1, 1, 1, 1))
	m.set_shader_parameter("tint_strength", strength)
	m.set_shader_parameter("ramp_steps", RAMP_STEPS)
	# 顶点 AO 只压到 55%：v7 单位的护肩/披风叠层更多，Cycles AO 烘出来比 v6 更深，
	# 全强度会把钢甲压成黑块（walk-test 实拍）。留住轮廓阴影，但让固有色读得出来。
	# 角色再放宽到 30% —— 单位的深色军装在 0.55 下就是纯黑剪影。
	m.set_shader_parameter("ao_strength", AO_CHAR if is_char else AO_PROP)
	m.set_shader_parameter("rim_strength", RIM_CHAR if is_char else RIM_PROP)
	m.set_shader_parameter("albedo_gain", GAIN_CHAR if is_char else GAIN_PROP)
	# 角色暗部环境补偿：
	#   diffuse_toon 只有 4 阶，背光面直接掉到接近 0 —— 深色军装的腿/躯干在
	#   RTS 俯视角度下就是一团纯黑（截图实拍：蓝披风+银甲+黑腿的剪影）。
	#   这里给角色一份 **等于自身基色×16%** 的极弱自发光，等价于"补一点环境光"：
	#   不发亮、不改色相，只把暗部从 0 拉到能读出布料褶皱。
	#   建筑不这么做（大面积浅色石材+0.16 会整体发灰、发飘）。
	var em_col: Color = _emission_for(zone)
	var em_energy: float = _emission_energy(zone)
	if is_char and em_energy <= 0.001:
		em_col = base
		em_energy = 0.16
	m.set_shader_parameter("emission_color", em_col)
	m.set_shader_parameter("emission_energy", em_energy)
	if alb_tex != null:
		m.set_shader_parameter("detail_albedo", alb_tex)
		m.set_shader_parameter("detail_on", 1.0)
		m.set_shader_parameter("detail_gain", DETAIL_GAIN)
	if nrm_tex != null:
		m.set_shader_parameter("detail_normal", nrm_tex)
		m.set_shader_parameter("normal_on", 1.0)
		m.set_shader_parameter("normal_strength", clampf(nrm_scale * NORMAL_BOOST, 0.0, 2.0))
	if outline and outline_enabled:
		var op := _outline_pass()
		if op != null:
			m.next_pass = op
	m.resource_name = "MK_" + key
	_materials[key] = m
	return m


## 描边 pass（全模型共用一份材质，别再按 zone 复制）
static func _outline_pass() -> ShaderMaterial:
	if _outline != null:
		return _outline
	if not ResourceLoader.exists(OUTLINE_PATH):
		return null
	var sh := load(OUTLINE_PATH) as Shader
	if sh == null:
		return null
	_outline = ShaderMaterial.new()
	_outline.shader = sh
	_outline.set_shader_parameter("outline_width", OUTLINE_WIDTH)
	_outline.set_shader_parameter("outline_color", Color(0.055, 0.060, 0.095))
	_outline.resource_name = "MK_outline"
	return _outline


static func _emission_for(zone: String) -> Color:
	if zone == "crystal":
		return Color(0.35, 0.85, 1.0)
	if zone == "ember":
		return Color(1.0, 0.42, 0.10)
	if zone == "ore":
		# 金矿的金块：一点暖金自发光，矿洞在阴影里也"值钱"
		return Color(1.0, 0.70, 0.20)
	return Color(0, 0, 0)


static func _emission_energy(zone: String) -> float:
	if zone == "crystal":
		return 1.6
	if zone == "ember":
		return 2.0
	if zone == "ore":
		return 0.8
	return 0.0


## 给整棵模型树换材质（幂等：已经换过的不会重复包一层）
## is_char = 带骨骼的角色：走另一档曝光（见 GAIN_CHAR / AO_CHAR），
## 让深色军装也读得出层次，而不是一团黑白剪影。
static func apply(root: Node3D, team_color: Color, outline: bool = false,
		is_char: bool = false) -> int:
	if root == null or not _enabled:
		return 0
	var sh := _get_shader()
	if sh == null:
		return 0
	var changed := 0
	for mi in _collect_meshes(root):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(i)
			if src == null:
				src = mi.mesh.surface_get_material(i)
			if src == null:
				continue
			if src is ShaderMaterial and String((src as ShaderMaterial).resource_name).begins_with("MK_"):
				continue
			var nm := String(src.resource_name)
			var zone := zone_of(nm)
			if zone.is_empty():
				continue          # 不是 M_ 协议里的材质：原样保留
			# v5：从 GLB 材质里取出手绘贴图 / 法线。glTF 导入后是 BaseMaterial3D，
			# 贴图就挂在 albedo_texture / normal_texture 上；normal_scale 是 Blender
			# 法线节点的强度，原样带进着色器，保证 Blender 里调好的凹凸在引擎里一致。
			var alb: Texture2D = null
			var nrm: Texture2D = null
			var nsc := 1.0
			var bm := src as BaseMaterial3D
			if bm != null:
				alb = bm.albedo_texture
				if bm.normal_enabled:
					nrm = bm.normal_texture
					nsc = bm.normal_scale
			var m := material_for(zone, team_color, is_team(nm), outline, alb, nrm, nsc, is_char)
			if m == null:
				continue
			mi.set_surface_override_material(i, m)
			changed += 1
	return changed


## 运行时改一个 zone 的颜色：所有已缓存材质一起变（不需要重建场景）
static func set_zone_color(zone: String, color: Color) -> void:
	palette().colors[zone] = color
	for key in _materials.keys():
		var m: ShaderMaterial = _materials[key]
		if key == zone or key.begins_with(zone + "#"):
			m.set_shader_parameter("base_color", color)


## 重新读盘（调色板 .tres 改过之后调用）
static func reload_palette() -> void:
	_palette = null
	_materials.clear()
	palette()


static func clear_cache() -> void:
	_materials.clear()
	_shader = null
	_palette = null


static func _collect_meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root == null:
		return out
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n as MeshInstance3D)
		for c in n.get_children():
			stack.append(c)
	return out