extends SceneTree
## QA：打印新方块人步兵模型的实际尺寸 / 材质名 / 骨骼 / 动画。
## 用法：godot --headless --path . --script 工具/检查单位资产.gd

const PATH := "res://美术/模型/方块人/方块人_联盟步兵.glb"


func _init() -> void:
	print("——————————————————————————————")
	print("[单位检查] ", PATH, "  exists=", ResourceLoader.exists(PATH))
	var ps := load(PATH) as PackedScene
	if ps == null:
		print("[单位检查] 载入失败")
		quit()
		return
	var root := ps.instantiate() as Node3D
	var meshes: Array[MeshInstance3D] = []
	var skins: Array[Skeleton3D] = []
	var aps: Array[AnimationPlayer] = []
	_collect(root, meshes, skins, aps)
	var aabb := AABB()
	var first := true
	var names: Array[String] = []
	var tris: int = 0
	for mi in meshes:
		if mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.get_aabb()
		if first:
			aabb = b
			first = false
		else:
			aabb = aabb.merge(b)
		for i in mi.mesh.get_surface_count():
			var m: Material = mi.get_active_material(i)
			var nm := "?"
			if m != null:
				nm = String(m.resource_name)
				if nm.is_empty() and not m.resource_path.is_empty():
					nm = m.resource_path.get_file().get_basename()
				if m is BaseMaterial3D:
					nm += "|tex=%s|metal=%.2f|rough=%.2f" % [
						"有" if (m as BaseMaterial3D).albedo_texture != null else "无",
						(m as BaseMaterial3D).metallic, (m as BaseMaterial3D).roughness]
			if not names.has(nm):
				names.append(nm)
			var arr: Array = mi.mesh.surface_get_arrays(i)
			if arr.size() > 0 and arr[Mesh.ARRAY_INDEX] != null:
				tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	print("    网格数 = ", meshes.size(), "  三角面 = ", tris)
	print("    材质 = ", names)
	print("    骨骼 = ", skins.size(), "  动画播放器 = ", aps.size())
	for ap in aps:
		print("    动画 = ", ap.get_animation_list())
	print("    本地包围盒 = ", aabb, "  size = ", aabb.size)
	print("    根缩放 = ", root.scale)
	root.free()
	print("——————————————————————————————")
	quit()


func _collect(n: Node, meshes: Array[MeshInstance3D], skins: Array[Skeleton3D],
		aps: Array[AnimationPlayer]) -> void:
	if n is MeshInstance3D:
		meshes.append(n as MeshInstance3D)
	elif n is Skeleton3D:
		skins.append(n as Skeleton3D)
	elif n is AnimationPlayer:
		aps.append(n as AnimationPlayer)
	for c in n.get_children():
		_collect(c, meshes, skins, aps)
