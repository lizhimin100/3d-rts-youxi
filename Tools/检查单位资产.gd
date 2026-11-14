extends SceneTree
## QA：打印单位模型的实际尺寸 / 材质名 / 骨骼 / 动画。
## 用法：
##   godot --headless --path . --script Tools/检查单位资产.gd
##   godot --headless --path . --script Tools/检查单位资产.gd -- --glb=res://Content/art/模型/精模/破法者.glb
##   （`--glb=` 可重复；不给就检查默认的联盟步兵）

const PATH := "res://Content/art/模型/方块人/方块人_联盟步兵.glb"


func _init() -> void:
	var paths: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--glb="):
			paths.append(String(a).substr(6))
	if paths.is_empty():
		paths.append(PATH)
	for p in paths:
		_inspect(p)
	quit()


func _inspect(PATH_: String) -> void:
	print("——————————————————————————————")
	print("[单位检查] ", PATH_, "  exists=", ResourceLoader.exists(PATH_))
	var ps := load(PATH_) as PackedScene
	if ps == null:
		print("[单位检查] 载入失败")
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
		var b: AABB = (mi.global_transform if mi.is_inside_tree() else mi.transform) * mi.get_aabb()
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
	for sk in skins:
		var bn: Array[String] = []
		for i in sk.get_bone_count():
			bn.append(sk.get_bone_name(i))
		print("    骨名 = ", bn)
	for ap in aps:
		print("    动画 = ", ap.get_animation_list())
	print("    本地包围盒 = ", aabb, "  size = ", aabb.size)
	print("    根缩放 = ", root.scale)
	root.free()
	print("——————————————————————————————")


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
