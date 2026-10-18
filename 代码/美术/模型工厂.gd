class_name ModelFactory
extends RefCounted
## 模型工厂（ANVIL 提供）—— 统一的 GLB 加载 / 缓存 / 兜底 / 材质替换入口。
##
## 设计要点：
## 1. **带缓存**：同一路径只 `load()` 一次；PackedScene 复用，实例化另算。
## 2. **失败兜底**：路径不存在或加载失败时返回一个「占位色块」，**绝不返回 null、绝不崩**。
##    占位块的尺寸按人类体型（0.5×0.5×1.6），并且颜色由路径哈希决定，
##    这样一眼就能在场景里认出「哪个模型没加载上」。
## 3. **缩放走外层包装**：`scale` 作用在返回的 Node3D 外壳上，不动模型内部变换，
##    这样同一份 GLB 可以被不同 UnitDef 用不同 model_scale 复用。
## 4. `apply_material` 递归给整棵子树换材质；**优先保留各部件原有基色**，
##    只覆盖 tint（队伍色）——否则整只兵会变成一坨单色，美术分区全丢。

## 加载失败的模型路径记录（调试用；正式路径不打印）
static var 失败记录: Array[String] = []
## 打开后每次兜底都会打一行日志；正式环境保持 false，避免刷屏
static var 调试日志: bool = false

static var _场景缓存: Dictionary = {}
static var _占位材质缓存: Dictionary = {}


## 加载模型。失败时返回占位色块（永不返回 null）。
static func load_model(path: String, scale: float = 1.0) -> Node3D:
	var 外壳 := Node3D.new()
	外壳.name = "模型_" + path.get_file().get_basename()
	var s: float = scale
	if not is_finite(s) or absf(s) < 0.0001:
		s = 1.0

	var ps: PackedScene = null
	if _场景缓存.has(path):
		ps = _场景缓存[path]
	else:
		if ResourceLoader.exists(path):
			ps = load(path) as PackedScene
		_场景缓存[path] = ps

	if ps == null:
		if not 失败记录.has(path):
			失败记录.append(path)
		if 调试日志:
			print("[模型工厂] 缺模型，用占位块：", path)
		外壳.add_child(_建占位块(path, s))
		return 外壳

	var inst: Node = ps.instantiate()
	if inst is Node3D:
		外壳.add_child(inst)
	else:
		# GLB 理论上必然是 Node3D；万一不是也不崩
		inst.queue_free()
		外壳.add_child(_建占位块(path, s))
	外壳.scale = Vector3(s, s, s)
	return 外壳


## 递归套材质。给了 mat 就用它覆盖；如果部件自己已经是 ShaderMaterial，
## 则只改它的 tint 参数（保住各部件原有 base_color 的美术分区）。
static func apply_material(root: Node3D, mat: Material) -> void:
	if root == null or mat == null:
		return
	var 队伍色 := Color(1, 1, 1, 1)
	var 有队伍色 := false
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		if sm.get_shader_parameter("tint") != null:
			队伍色 = sm.get_shader_parameter("tint")
			有队伍色 = true
	for mi in _收集网格(root):
		var 层数: int = mi.get_surface_override_material_count()
		if 层数 <= 0 and mi.mesh != null:
			层数 = mi.mesh.get_surface_count()
		var 已用独立材质 := false
		for i in 层数:
			var 原材质: Material = mi.get_active_material(i)
			var 新材质: Material = null
			if 原材质 is ShaderMaterial and 有队伍色:
				var 源 := 原材质 as ShaderMaterial
				if 源.get_shader_parameter("tint") != null:
					var 副本 := 源.duplicate() as ShaderMaterial
					副本.set_shader_parameter("tint", 队伍色)
					副本.set_shader_parameter("tint_strength", 1.0)
					新材质 = 副本
			if 新材质 == null:
				新材质 = mat
			mi.set_surface_override_material(i, 新材质)
			已用独立材质 = true
		if not 已用独立材质:
			mi.material_override = mat


## 只改队伍色，不动其它材质参数。faction_color 为阵营色。
static func tint_model(root: Node3D, faction_color: Color, strength: float = 1.0) -> void:
	if root == null:
		return
	for mi in _收集网格(root):
		var 层数: int = maxi(mi.get_surface_override_material_count(),
			mi.mesh.get_surface_count() if mi.mesh != null else 0)
		for i in 层数:
			var m: Material = mi.get_active_material(i)
			if m is ShaderMaterial:
				var sm := m as ShaderMaterial
				if sm.get_shader_parameter("tint") != null:
					sm.set_shader_parameter("tint", faction_color)
					sm.set_shader_parameter("tint_strength", strength)


## 统计三角面数（渲染负载自查用）
static func count_triangles(root: Node3D) -> int:
	var n: int = 0
	for mi in _收集网格(root):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			if arr.size() > 0 and arr[Mesh.ARRAY_INDEX] != null:
				n += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			elif arr.size() > 0 and arr[Mesh.ARRAY_VERTEX] != null:
				n += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## 清空缓存（切关卡/热重载时用）
static func clear_cache() -> void:
	_场景缓存.clear()
	_占位材质缓存.clear()
	失败记录.clear()


# ---------------------------------------------------------------- 内部实现
static func _收集网格(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root == null:
		return out
	var 栈: Array[Node] = [root]
	while not 栈.is_empty():
		var n: Node = 栈.pop_back()
		if n is MeshInstance3D:
			out.append(n as MeshInstance3D)
		for c in n.get_children():
			栈.append(c)
	return out


static func _建占位块(path: String, s: float) -> Node3D:
	var 根 := Node3D.new()
	根.name = "占位_" + path.get_file().get_basename()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.46, 1.55, 0.34)
	bm.material = _占位材质(path)
	mi.mesh = bm
	mi.position = Vector3(0.0, 0.775, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	根.add_child(mi)
	# 头顶一个小方块：标出"这是占位，不是模型"
	var 头 := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.30, 0.30, 0.30)
	hm.material = _占位材质(path + "_h")
	头.mesh = hm
	头.position = Vector3(0.0, 1.72, 0.0)
	头.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	根.add_child(头)
	根.scale = Vector3(s, s, s)
	return 根


static func _占位材质(键: String) -> StandardMaterial3D:
	if _占位材质缓存.has(键):
		return _占位材质缓存[键]
	var m := StandardMaterial3D.new()
	# 路径哈希 → 稳定的品红色系：一眼能看出"这不是美术资产"
	var h := float(abs(键.hash()) % 1000) / 1000.0
	m.albedo_color = Color(0.85, 0.22 + h * 0.18, 0.65, 1.0)
	m.roughness = 0.85
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_占位材质缓存[键] = m
	return m
