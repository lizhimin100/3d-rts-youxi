extends SceneTree
## **装饰性能自检**：量"地图装饰物"的规模与开销，给改造前后可比数字。
##
## 运行（只走无头脚本，不开窗口、不 --import）：
##   godot --headless --path . --script 代码/测试/装饰性能自检.gd
##
## 报告两项：
##   · 基线（改造前就有的东西）：树 / 金矿 / 岩石 / 水面的节点与三角面
##   · 装饰（新管线）：草丛 / 碎石 / 花 的实例数、三角面、draw call 覆盖
## 另外打印**确定性指纹**（可走性 + 树/金矿/岩石布局），改地图代码前后必须一模一样。

const MODEL_DIR := "res://美术/模型/"

var _report: Dictionary = {}


func _initialize() -> void:
	_report["autoload"] = {
		"Game": root.has_node("Game"),
		"Cfg": root.has_node("Cfg"),
	}
	var cfg := GameConfig.new()
	cfg.units = UnitTable.build_units()

	var t0: int = Time.get_ticks_usec()
	var data: MapGenerator.MapData = MapGenerator.build(cfg)
	var build_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0

	_report["地图"] = {
		"边长": data.size, "细分": data.resolution,
		"树": data.trees.size(), "金矿": data.mines.size(), "岩石": data.rocks.size(),
		"建图ms": "%.2f" % build_ms,
		"确定性指纹": _fingerprint(data),
	}

	# --- 现有模型的结构与面数（用来选装饰用哪个 GLB、算预算）---
	var models: Dictionary = {}
	for name in ["树", "岩石", "金矿"]:
		var path: String = MODEL_DIR + name + ".glb"
		var inst: Node = _instantiate(path)
		var info: Dictionary = _mesh_stats(inst)
		info["可以加载"] = inst != null
		models[name] = info
		if inst != null:
			inst.queue_free()
	_report["模型"] = models

	# 临时：验证装饰场景能加载、visible 覆写生效
	for sn in ["草丛", "碎石"]:
		var path: String = "res://美术/场景/" + sn + "_场景.tscn"
		var inst3: Node = _instantiate(path)
		if inst3 == null:
			print("SCENECHK " + sn + " 加载失败")
			continue
		var vis: Array = []
		var hid: int = 0
		var stack2: Array[Node] = [inst3]
		while not stack2.is_empty():
			var n2: Node = stack2.pop_back()
			var mi2 := n2 as MeshInstance3D
			if mi2 != null:
				if mi2.visible:
					vis.append(String(mi2.name))
				else:
					hid += 1
			for c2 in n2.get_children():
				stack2.append(c2)
		print("SCENECHK " + sn + " 可见=" + str(vis) + " 隐藏=" + str(hid)
			+ " 缩放=" + str((inst3 as Node3D).scale))
		inst3.queue_free()

	print("DECORTEST " + JSON.stringify(_report))
	quit(0)


## 确定性指纹：可走性数组 + 资源点位置（量化到 1cm），任何一处变动都会变
func _fingerprint(data: MapGenerator.MapData) -> String:
	var h: int = -2128831035   # FNV offset
	for b in data.walkable:
		h = (h ^ int(b)) * 16777619
		h = h & 0x7FFFFFFF
	for t in data.trees:
		h = _mix(h, int(round(t.x * 100.0)))
		h = _mix(h, int(round(t.y * 100.0)))
	for m in data.mines:
		h = _mix(h, int(round(m.x * 100.0)))
		h = _mix(h, int(round(m.y * 100.0)))
	for r in data.rocks:
		var p: Vector2 = r["pos"]
		h = _mix(h, int(round(p.x * 100.0)))
		h = _mix(h, int(round(p.y * 100.0)))
	return "%08X" % h


func _mix(h: int, v: int) -> int:
	h = (h ^ v) * 16777619
	return h & 0x7FFFFFFF


func _child_names(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		out.append("%s[%s]" % [String(c.name), c.get_class()])
	return out


## 逐网格：名字 + 相对根的包围盒 + 面数（按面数排序）
func _dump_meshes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [{"n": root, "xf": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var e: Dictionary = stack.pop_back()
		var n: Node = e["n"]
		var xf: Transform3D = e["xf"]
		var n3 := n as Node3D
		if n3 != null:
			xf = xf * n3.transform
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			var tris: int = 0
			for s in mi.mesh.get_surface_count():
				var arr: Array = mi.mesh.surface_get_arrays(s)
				if arr.size() > 0 and arr[Mesh.ARRAY_INDEX] != null:
					tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
				elif arr.size() > 0 and arr[Mesh.ARRAY_VERTEX] != null:
					tris += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			var b: AABB = xf * mi.mesh.get_aabb()
			out.append({
				"名": String(n.name),
				"面": tris,
				"高": "%.2f" % b.size.y,
				"宽": "%.2f" % maxf(b.size.x, b.size.z),
				"y0": "%.2f" % b.position.y,
			})
		for c in n.get_children():
			stack.append({"n": c, "xf": xf})
	out.sort_custom(func(a, b): return int(a["面"]) > int(b["面"]))
	return out


func _instantiate(path: String) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var ps: PackedScene = load(path) as PackedScene
	if ps == null:
		return null
	return ps.instantiate()


## 统计一棵树里的网格：节点数 / MeshInstance 数 / 面数 / 包围盒
func _mesh_stats(root: Node) -> Dictionary:
	var out: Dictionary = {"节点数": 0, "网格数": 0, "面数": 0, "包围盒": "0"}
	if root == null:
		return out
	var stack: Array[Node] = [root]
	var tris: int = 0
	var meshes: int = 0
	var aabb := AABB()
	var has_box: bool = false
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out["节点数"] = int(out["节点数"]) + 1
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			meshes += 1
			for s in mi.mesh.get_surface_count():
				var arr: Array = mi.mesh.surface_get_arrays(s)
				if arr.size() > 0 and arr[Mesh.ARRAY_INDEX] != null:
					tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
				elif arr.size() > 0 and arr[Mesh.ARRAY_VERTEX] != null:
					tris += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			var box: AABB = mi.mesh.get_aabb()
			if has_box:
				aabb = aabb.merge(box)
			else:
				aabb = box
				has_box = true
		for c in n.get_children():
			stack.append(c)
	out["网格数"] = meshes
	out["面数"] = tris
	if has_box:
		out["包围盒"] = "%.2f x %.2f x %.2f" % [aabb.size.x, aabb.size.y, aabb.size.z]
	return out
