extends SceneTree
## QA：量自然物（树/草丛/岩石/金矿）的三角面与网格数，用于对比程序化生成的成本。
## 用法：godot --headless --path . --script 工具/检查自然资产.gd

const 名字 := ["树", "草丛", "岩石", "金矿", "木桩", "栅栏"]


func _init() -> void:
	for n in 名字:
		var p := "res://美术/模型/%s.glb" % n
		if not ResourceLoader.exists(p):
			p = "res://美术/模型/v7_自然/%s.glb" % n
		if not ResourceLoader.exists(p):
			print("[自然检查] %s → 不存在" % n)
			continue
		var shell: Node3D = ModelFactory.load_model(p, 1.0)
		var meshes: Array[MeshInstance3D] = []
		var 栈: Array[Node] = [shell]
		while not 栈.is_empty():
			var c: Node = 栈.pop_back()
			if c is MeshInstance3D:
				meshes.append(c as MeshInstance3D)
			for k in c.get_children():
				栈.append(k)
		var 材质: Array[String] = []
		for mi in meshes:
			if mi.mesh == null:
				continue
			for i in mi.mesh.get_surface_count():
				var m: Material = mi.get_active_material(i)
				if m != null and not 材质.has(String(m.resource_name)):
					材质.append(String(m.resource_name))
		print("[自然检查] %-4s 面数=%-6d 网格=%d 材质=%s" % [
			n, ModelFactory.count_triangles(shell), meshes.size(), 材质])
		shell.queue_free()
	quit()
