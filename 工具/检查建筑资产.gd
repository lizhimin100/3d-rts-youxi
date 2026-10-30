extends SceneTree
## QA：打印三座建筑当前实际使用的模型 / 材质 / 三角面 / 尺寸参数。
## 用法：godot --headless --path . --script 工具/检查建筑资产.gd
## 目的：确认"导入铁誓军团资产包之前"的旧模型确实回来了（不是资产包图集版）。

const 建筑 := [&"townhall", &"barracks", &"blacksmith"]


func _init() -> void:
	var defs: Dictionary = UnitTable.build_units()
	for id in 建筑:
		var d: UnitDef = defs.get(id, null)
		if d == null:
			print("[建筑检查] 缺定义：", id)
			continue
		print("——————————————————————————————")
		print("[建筑检查] %s（%s）" % [d.display_name, id])
		print("    model_path   = ", d.model_path)
		print("    model_scale  = ", d.model_scale)
		print("    footprint    = ", d.footprint)
		print("    height       = ", d.height)
		print("    body_radius  = ", d.body_radius, "  selection_radius = ", d.selection_radius)
		var shell: Node3D = ModelFactory.load_model(d.model_path, d.model_scale)
		var meshes := _meshes(shell)
		var tris: int = ModelFactory.count_triangles(shell)
		print("    LOD 档位     = ", _lod_count(shell))
		print("    网格数       = ", meshes.size(), "  三角面 = ", tris)
		var names: Array[String] = []
		for mi in meshes:
			if mi.mesh == null:
				continue
			for i in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(i)
				var nm := "?"
				if m != null:
					nm = String(m.resource_name)
					if nm.is_empty() and not m.resource_path.is_empty():
						nm = m.resource_path.get_file().get_basename()
				if not names.has(nm):
					names.append(nm)
		print("    材质名       = ", names)
		shell.queue_free()
	print("——————————————————————————————")
	print("[建筑检查] 铁誓资产包材质（team / team_trim / 主体 / 自发光）出现次数：",
		_count_pack_mats(defs))
	quit()


func _meshes(root: Node) -> Array[MeshInstance3D]:
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


func _lod_count(shell: Node3D) -> int:
	if shell == null:
		return 0
	var g := shell.get_node_or_null("LOD组")
	if g == null:
		return 1
	return g.get_child_count()


func _count_pack_mats(defs: Dictionary) -> int:
	var n := 0
	for id in 建筑:
		var d: UnitDef = defs.get(id, null)
		if d == null:
			continue
		var shell: Node3D = ModelFactory.load_model(d.model_path, d.model_scale)
		for mi in _meshes(shell):
			if mi.mesh == null:
				continue
			for i in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(i)
				if m == null:
					continue
				var nm := String(m.resource_name)
				if nm in ["team", "team_trim", "主体", "自发光"]:
					n += 1
		shell.queue_free()
	return n
