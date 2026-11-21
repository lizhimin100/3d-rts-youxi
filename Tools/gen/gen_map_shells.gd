extends SceneTree
## 职责：把底壳的初始几何（高度场 / 地表槽位 / 战术格子吸附高度 / 三块区域）与"三张卡 -> 关卡"的组装结果写回 Content/data。
## 属于：Tools/gen
## 用法：godot --headless --path . --script Tools/gen/gen_map_shells.gd
## 时机：新增底壳、改底壳尺寸、或首次生成某个 [底壳 x 布局卡 x 遭遇卡] 组合时跑一次。
## 纪律：组合关卡的字段只由 dev_data.compose_level() 生成，这里不复制第二份规则。

const DataScript := preload("res://Screens/editor/dev_data.gd")
const ShellStore := preload("res://Screens/editor/shell_store.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var d: RefCounted = DataScript.new()
	if not bool(d.call("load_all")):
		push_error("[gen] load failed: " + String(d.get("load_error")))
		quit(1)
		return
	var doc: Dictionary = d.get("shells")
	for s in (doc.get("shells", []) as Array):
		_fill_shell(s as Dictionary)
		print("[gen] shell ", String((s as Dictionary).get("id", "?")), " heights=", ((s as Dictionary).get("terrain", {}) as Dictionary).get("heights", []).size())
	for combo in (d.call("default_combos") as Array):
		var asm: Dictionary = d.call("generate_assembly", String(combo[0]), String(combo[1]), String(combo[2]))
		if asm.is_empty():
			push_error("[gen] compose failed: " + str(combo))
			quit(1)
			return
		print("[gen] assembly ", String(asm.get("id", "?")), " -> ", String(asm.get("level", "?")))
	if not bool(d.call("save_all")):
		push_error("[gen] save failed: " + String(d.get("load_error")))
		quit(1)
		return
	print("[gen] written: Content/data/{map_shells,levels,player_layouts,enemy_encounters}.json")
	quit(0)


func _fill_shell(shell: Dictionary) -> void:
	var g: Dictionary = ShellStore.grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var seed_value := int(shell.get("seed", 1))
	var heights: Array = []
	for row in rows:
		for col in cols:
			var w := ShellStore.world_of_cell(shell, col, row)
			heights.append(snappedf(ShellStore.procedural_height(seed_value, w.x, w.y), 0.001))
	var terrain: Dictionary = shell.get("terrain", {})
	terrain["heights"] = heights
	shell["terrain"] = terrain
	var surface: Dictionary = shell.get("surface", {})
	surface["index"] = ShellStore.autopaint(shell)
	shell["surface"] = surface
	# 新建底壳：三块势力区域缺了就补默认矩形（几何在 Model 里算）
	ShellStore.ensure_regions(shell)
	for p in (shell.get("tiles", []) as Array):
		var td: Dictionary = p
		var px := float(td.get("x", 0.0))
		var pz := float(td.get("z", 0.0))
		td["terrain_y"] = snappedf(ShellStore.height_at(shell, px, pz), 0.001)
		td["side"] = ShellStore.side_of(px)
	for dec in (shell.get("decorations", []) as Array):
		var dd: Dictionary = dec
		dd["y"] = snappedf(ShellStore.height_at(shell, float(dd.get("x", 0.0)), float(dd.get("z", 0.0))), 0.001)
