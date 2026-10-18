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

## 队伍色区默认强度（调色板里可以逐 zone 覆盖）
const DEFAULT_TEAM_STRENGTH := 0.9
## 卡通色阶数
const RAMP_STEPS := 4

static var _materials: Dictionary = {}      # key -> ShaderMaterial
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
static func material_for(zone: String, team_color: Color, is_team_zone: bool) -> ShaderMaterial:
	var pal := palette()
	var key := zone
	if is_team_zone:
		key += "#" + team_color.to_html(false)
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
	m.set_shader_parameter("rim_strength", 0.10)
	m.set_shader_parameter("emission_color", _emission_for(zone))
	m.set_shader_parameter("emission_energy", _emission_energy(zone))
	m.resource_name = "MK_" + key
	_materials[key] = m
	return m


static func _emission_for(zone: String) -> Color:
	if zone == "crystal":
		return Color(0.35, 0.85, 1.0)
	if zone == "ember":
		return Color(1.0, 0.42, 0.10)
	return Color(0, 0, 0)


static func _emission_energy(zone: String) -> float:
	if zone == "crystal":
		return 1.6
	if zone == "ember":
		return 2.0
	return 0.0


## 给整棵模型树换材质（幂等：已经换过的不会重复包一层）
static func apply(root: Node3D, team_color: Color) -> int:
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
			var m := material_for(zone, team_color, is_team(nm))
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
