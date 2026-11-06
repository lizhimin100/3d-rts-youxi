extends SceneTree
func _initialize() -> void:
	var ps := load("res://美术/特效/选中圈.tscn") as PackedScene
	print("场景=", ps)
	if ps == null:
		quit()
		return
	var n := ps.instantiate()
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		var mi := c as MeshInstance3D
		if mi != null:
			print("  网格=", mi.name, " mesh=", mi.mesh, " pos=", mi.position)
			for i in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(i)
				print("    材质=", m, " class=", m.get_class() if m else "-")
				if m is ShaderMaterial:
					print("    shader=", (m as ShaderMaterial).shader)
					for k in ["ring_radius","ring_width","halo","opacity"]:
						print("      ", k, "=", (m as ShaderMaterial).get_shader_parameter(k))
		for ch in c.get_children():
			stack.append(ch)
	quit()
