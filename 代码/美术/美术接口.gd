class_name ArtKit
extends RefCounted
## **美术接口门面（Lead 提供，签名冻结）**
## 为什么要有这一层：美术资产（模型/动画/特效）由「铁砧 ANVIL」独立开发，
## 而玩法代码要在美术到位之前就能跑起来、就能测。所以玩法侧**只调用 ArtKit**，
## ArtKit 内部用**动态加载**去找真正的美术实现；文件还没到位时退化成占位图形，
## 绝不因为美术缺文件而崩。
##
## 美术侧需要保证的实现（名字逐字一致）：
##   代码/美术/模型工厂.gd  → `static func load_model(path: String, scale: float) -> Node3D`
##   代码/美术/程序动画.gd  → 挂到角色根节点，`func set_state(state: String, speed_ratio: float = 1.0)`
##   代码/美术/特效生成.gd  → `static func hit_spark/death_burst/magic_blast/build_dust/selection_ring`

const PATH_MODEL_FACTORY := "res://代码/美术/模型工厂.gd"
const PATH_PROC_ANIM := "res://代码/美术/程序动画.gd"
const PATH_VFX := "res://代码/美术/特效生成.gd"
const PATH_ENV := "res://美术/环境/战斗环境.tres"
const PATH_THEME := "res://美术/主题/游戏主题.tres"
const PATH_MAT_CHAR := "res://美术/材质/角色主材质.tres"
## 清空静态缓存（退出时调用，避免引擎报 "resources still in use at exit"）
static func clear_cache() -> void:
	_cache.clear()


## 是否开启反向外壳描边（每 surface 多一次 draw call，性能敏感时关掉）
const OPEN_OUTLINE: bool = true
const PATH_MAT_BUILDING := "res://美术/材质/建筑主材质.tres"

## 动态加载缓存（避免每次都 ResourceLoader.exists）
static var _cache: Dictionary = {}


## 动态取一个脚本资源（找不到返回 null）
static func _script(path: String) -> Script:
	if _cache.has(path):
		return _cache[path]
	var s: Script = null
	if ResourceLoader.exists(path):
		s = load(path) as Script
	_cache[path] = s
	return s


## 取一个非脚本资源（材质/环境/主题）
static func _res(path: String) -> Resource:
	if _cache.has(path):
		return _cache[path]
	var r: Resource = null
	if ResourceLoader.exists(path):
		r = load(path)
	_cache[path] = r
	return r


# ===========================================================================
# 模型
# ===========================================================================

## 生成一个模型实例（找不到模型时返回占位盒，保证游戏可玩、可测）
## fallback_size: 占位盒尺寸（米），用来让占位图形看起来别太离谱
static func build_model(model_path: String, model_scale: float = 1.0,
		fallback_size: Vector3 = Vector3(0.7, 1.7, 0.5)) -> Node3D:
	# ① 优先走美术侧的模型工厂（它带缓存、材质处理、队伍色等增强）
	var s := _script(PATH_MODEL_FACTORY)
	if s != null:
		var out: Variant = s.call("load_model", model_path, model_scale)
		var n := out as Node3D
		if n != null:
			return n
	# ② 模型工厂还没就绪时，直接实例化 GLB —— 保证美术资产一落地就能看见
	var direct := _load_glb_direct(model_path, model_scale)
	if direct != null:
		return direct
	# ③ 最后才退化成占位盒
	return _fallback_model(fallback_size, model_path)


## 直接把 res://.../*.glb 实例化成一个 Node3D（失败返回 null）
static func _load_glb_direct(model_path: String, model_scale: float) -> Node3D:
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return null
	var cache_key := "glb::" + model_path
	var cached: Variant = _cache.get(cache_key, null)
	var ps: PackedScene = null
	if cached is PackedScene:
		ps = cached as PackedScene
	else:
		ps = load(model_path) as PackedScene
		_cache[cache_key] = ps
	if ps == null:
		return null
	var inst: Node = ps.instantiate()
	var node := inst as Node3D
	if node == null:
		if inst != null:
			inst.queue_free()
		return null
	node.scale = Vector3.ONE * model_scale
	return node


## 占位模型：一个带锥形顶的盒子（不是最终美术，只是让流程能跑）
static func _fallback_model(size: Vector3, model_path: String) -> Node3D:
	var root := Node3D.new()
	root.name = "占位模型"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.52, 0.48)
	mat.roughness = 0.85
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	body.mesh = bm
	body.material_override = mat
	body.position.y = size.y * 0.5
	root.add_child(body)
	# 用一个朝 -Z 的小楔子提示朝向（调试用）
	var nose := MeshInstance3D.new()
	var nm := PrismMesh.new()
	nm.size = Vector3(size.x * 0.4, size.y * 0.16, size.z * 0.5)
	nose.mesh = nm
	nose.material_override = mat
	nose.position = Vector3(0.0, size.y * 0.72, -size.z * 0.5)
	root.add_child(nose)
	root.set_meta("fallback_for", model_path)
	return root


## 递归套材质（美术侧通常已在 GLB 里带材质，这里是兜底）
static func apply_material(root: Node3D, mat: Material) -> void:
	if root == null or mat == null:
		return
	_walk_apply(root, mat)


static func _walk_apply(n: Node, mat: Material) -> void:
	var mi := n as MeshInstance3D
	if mi != null:
		mi.material_override = mat
	for c in n.get_children():
		_walk_apply(c, mat)


## 递归套队伍色（给卡通着色器的 tint uniform 用）
static func apply_team_color(root: Node3D, color: Color) -> void:
	if root == null:
		return
	# 只给"角色"开描边（角色根下有 Body 关节节点）。
	# 建筑/道具不开：它们网格多、面积大，开描边会让 draw call 翻倍且黑边过粗。
	var is_character: bool = root.get_node_or_null("Body") != null
	_walk_tint(root, color, is_character and OPEN_OUTLINE)


## 递归给每个网格实例套"队伍色 + 描边"。
##
## ★ 这里原来只改 material_override 上的 ShaderMaterial，
##   而 GLB 里自带的是内嵌 StandardMaterial3D、material_override 一直是 null
##   —— 结果队伍色一次都没生效，敌我同色（截图里被一眼看出来的问题）。
##   现在改成：逐 surface 复制一份材质（避免污染其它实例），把 albedo 往队伍色拉，
##   再把描边材质挂到 next_pass 上（黑边就是这么来的）。
static func _walk_tint(n: Node, color: Color, outline: bool = false) -> void:
	var mi := n as MeshInstance3D
	if mi != null:
		var count: int = 0
		if mi.mesh != null:
			count = mi.mesh.get_surface_count()
		for i in count:
			var src: Material = mi.get_surface_override_material(i)
			if src == null and mi.mesh != null:
				src = mi.mesh.surface_get_material(i)
			var dup: Material = src.duplicate() if src != null else null
			if dup is BaseMaterial3D:
				var bm := dup as BaseMaterial3D
				# 只给"中性色"表面吃队伍色（石/布/铁这些本来就发灰的），
				# 木料/金/草这些高饱和部件保留本色 —— 否则整座基地会被染成一坨蓝。
				var c0: Color = bm.albedo_color
				var mx: float = maxf(maxf(c0.r, c0.g), c0.b)
				var mn: float = minf(minf(c0.r, c0.g), c0.b)
				if mx - mn < 0.16:
					bm.albedo_color = c0.lerp(color, 0.30)
			elif dup is ShaderMaterial:
				var sm := dup as ShaderMaterial
				if _has_uniform(sm, "tint"):
					sm.set_shader_parameter("tint", color)
			if dup == null:
				continue
			# 无头渲染器（dummy）不支持 ShaderMaterial 的实例参数，会刷 ERROR；
			# 真实窗口下才挂描边（这也是"零 ERROR"验收的一部分）。
			# ★ 描边用 NEXT_PASS 会让每个 surface 的 draw call 翻倍（实测 49k draw call 的主因之一）。
			#   这里默认关闭，需要时把 OPEN_OUTLINE 改 true 就能整体打开。
			if outline and DisplayServer.get_name() != "headless":
				dup.next_pass = _outline_material()
			mi.set_surface_override_material(i, dup)
	for c in n.get_children():
		_walk_tint(c, color, outline)


## 材质上有没有这个 uniform
static func _has_uniform(mat: ShaderMaterial, uniform: String) -> bool:
	if mat == null or mat.shader == null:
		return false
	for u in mat.shader.get_shader_uniform_list():
		if String(u.name) == uniform:
			return true
	return false


## 描边材质（反向外壳）。取不到就返回 null（不影响主体渲染）
static func _outline_material() -> Material:
	var key := "outline_mat"
	if _cache.has(key):
		return _cache[key]
	var script_path := "res://美术/着色器/描边.gdshader"
	if not ResourceLoader.exists(script_path):
		_cache[key] = null
		return null
	var sh := load(script_path) as Shader
	if sh == null:
		_cache[key] = null
		return null
	var m := ShaderMaterial.new()
	m.shader = sh
	if _has_uniform(m, "outline_color"):
		m.set_shader_parameter("outline_color", Color(0.09, 0.08, 0.07))
	if _has_uniform(m, "outline_width"):
		m.set_shader_parameter("outline_width", 0.016)
	if _has_uniform(m, "width_scale"):
		m.set_shader_parameter("width_scale", 0.016)
	_cache[key] = m
	return m


# ===========================================================================
# 动画
# ===========================================================================

## 给角色根节点挂上程序动画器，返回动画节点（找不到实现返回 null）
static func attach_anim(root: Node3D) -> Node:
	if root == null:
		return null
	var s := _script(PATH_PROC_ANIM)
	if s == null:
		return null
	var inst: Variant = s.call("new")
	var n := inst as Node
	if n == null:
		return null
	root.add_child(n)
	if n.has_method("bind"):
		n.call("bind", root)
	return n


## 安全地切换动画状态（动画节点为 null 时静默跳过）
static func set_anim(anim_node: Node, state: String, speed_ratio: float = 1.0) -> void:
	if anim_node == null or not is_instance_valid(anim_node):
		return
	if anim_node.has_method("set_state"):
		anim_node.call("set_state", state, speed_ratio)


# ===========================================================================
# 特效
# ===========================================================================

static func _vfx_api() -> Script:
	return _script(PATH_VFX)


## 命中火花
static func vfx_hit(pos: Vector3, color: Color = Color(1, 0.85, 0.4)) -> void:
	var s := _vfx_api()
	if s != null:
		s.call("hit_spark", pos, color)


## 死亡碎裂
static func vfx_death(pos: Vector3, color: Color = Color(0.8, 0.2, 0.15)) -> void:
	var s := _vfx_api()
	if s != null:
		s.call("death_burst", pos, color)


## 魔法爆裂
static func vfx_magic(pos: Vector3, radius: float, color: Color = Color(0.4, 0.7, 1)) -> void:
	var s := _vfx_api()
	if s != null:
		s.call("magic_blast", pos, color, radius)


## 建造尘土
static func vfx_build(pos: Vector3) -> void:
	var s := _vfx_api()
	if s != null:
		s.call("build_dust", pos)


## 选中圈（返回节点，由调用方管理生命周期）
static func vfx_ring(parent: Node3D, radius: float, color: Color) -> Node3D:
	var s := _vfx_api()
	if s != null:
		var out: Variant = s.call("selection_ring", parent, radius, color)
		var n := out as Node3D
		if n != null:
			return n
	return null


# ===========================================================================
# 全局资源
# ===========================================================================

## 战斗环境（Environment），找不到返回 null 由调用方兜底
static func load_environment() -> Environment:
	return _res(PATH_ENV) as Environment


## UI 主题，找不到返回 null
static func load_theme() -> Theme:
	return _res(PATH_THEME) as Theme
