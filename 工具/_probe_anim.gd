extends SceneTree
## 探针：查方块人模型的 AnimationPlayer 动作列表 + SkeletonAnim 的解析结果
func _initialize() -> void:
	call_deferred("_go")

func _go() -> void:
	for path in ["res://美术/模型/方块人/方块人_弩兵.glb",
			"res://美术/模型/方块人/方块人_联盟步兵.glb",
			"res://美术/模型/方块人/方块人_农民.glb"]:
		var ps := load(path) as PackedScene
		if ps == null:
			print("!! 载入失败 ", path)
			continue
		var n := ps.instantiate()
		var ap: AnimationPlayer = null
		var stack: Array = [n]
		while not stack.is_empty():
			var c: Node = stack.pop_back()
			if c is AnimationPlayer:
				ap = c as AnimationPlayer
			for ch in c.get_children():
				stack.append(ch)
		print("== ", path)
		if ap == null:
			print("   没有 AnimationPlayer")
			n.free()
			continue
		print("   动作=", ap.get_animation_list())
		var sa: Node = load("res://代码/美术/骨骼动画.gd").new()
		sa.call("bind", n)
		for st in ["idle", "move", "attack", "gather", "build", "cast", "hurt", "death"]:
			print("   ", st, " → ", sa.call("_resolve", StringName(st)), " has=", sa.call("has_state", st))
		n.free()
		sa.free()
	quit()
