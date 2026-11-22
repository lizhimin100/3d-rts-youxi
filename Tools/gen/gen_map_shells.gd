extends SceneTree
## 职责：把底壳的初始几何（高度场 / 地表槽位 / 战术格子吸附高度 / 远景装饰带）与"三张卡 -> 关卡"的组装结果写回 Content/data。
## 属于：Tools/gen
## 用法：godot --headless --path . --script Tools/gen/gen_map_shells.gd [-- --force]
## 时机：新增底壳、改底壳尺寸、或首次生成某个 [底壳 x 布局卡 x 遭遇卡] 组合时跑一次。
## 纪律：
##   · 组合关卡的字段只由 dev_data.compose_level() 生成，这里不复制第二份规则；
##   · **已有的关卡默认不重算**（只补缺的）：重新组合会把波次时间/回合数按当前遭遇卡重写，
##     等于无声改玩法。要重算必须显式 --force。
##   · 远景装饰带（auto 行）每次重算，手摆装饰永远保留。

const DataScript := preload("res://Screens/editor/dev_data.gd")
const ShellStore := preload("res://Screens/editor/shell_store.gd")

var _force := false


func _initialize() -> void:
	_force = OS.get_cmdline_user_args().has("--force")
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
	var existing := {}
	for lv in (d.get("levels") as Dictionary).get("levels", []):
		existing[String((lv as Dictionary).get("id", ""))] = true
	for combo in (d.call("default_combos") as Array):
		var level_id := String(d.call("combo_level_id", String(combo[1]), String(combo[2])))
		if not _force and existing.has(level_id):
			print("[gen] assembly 跳过（已存在）: ", level_id)
			continue
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
	# 区域多边形要先就位：高度场按"三块区域外包矩形 = 平整区"生成（唯一实现在 ShellStore.terrain_height）
	ShellStore.ensure_regions(shell)
	var g: Dictionary = ShellStore.grid_of(shell)
	var cols := int(g["cols"])
	var rows := int(g["rows"])
	var heights: Array = []
	for row in rows:
		for col in cols:
			var w := ShellStore.world_of_cell(shell, col, row)
			heights.append(snappedf(ShellStore.terrain_height(shell, w.x, w.y), 0.001))
	var terrain: Dictionary = shell.get("terrain", {})
	terrain["heights"] = heights
	shell["terrain"] = terrain
	var surface: Dictionary = shell.get("surface", {})
	surface["index"] = ShellStore.autopaint(shell)
	shell["surface"] = surface
	for p in (shell.get("tiles", []) as Array):
		var td: Dictionary = p
		var px := float(td.get("x", 0.0))
		var pz := float(td.get("z", 0.0))
		td["terrain_y"] = snappedf(ShellStore.height_at(shell, px, pz), 0.001)
		td["side"] = ShellStore.side_at(shell, px, pz)
	_fill_decor_ring(shell)
	for dec in (shell.get("decorations", []) as Array):
		var dd: Dictionary = dec
		dd["y"] = snappedf(ShellStore.height_at(shell, float(dd.get("x", 0.0)), float(dd.get("z", 0.0))), 0.001)


## 远景装饰带：只往**战术区之外**的周边环境带撒树/岩石/碎石。
##
## 为什么放在生成器里而不是手摆：地图扩容后外围是几百米的坡地，手摆一百多棵树既无法维护，
## 也没法和"改尺寸就重算"的流程对齐。这里按 seed 确定性地撒，并把行标成 `auto`，
## **每次重跑先清掉上一批 auto 行**——手摆的装饰（无 auto 标记）永远不会被覆盖。
const RING_STEP_M := 16.0
const RING_KEEP := 0.30
const RING_MARGIN_M := 9.0
const RING_KINDS := ["tree", "tree", "tree", "rock", "grass", "rubble"]


func _fill_decor_ring(shell: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(shell.get("seed", 1)) * 7919 + 13
	var decos: Array = shell.get("decorations", [])
	var kept: Array = []
	var inner0: Rect2 = ShellStore.play_area(shell).grow(3.0)
	for d in decos:
		if bool((d as Dictionary).get("auto", false)):
			continue
		var dd: Dictionary = d
		# 手摆装饰也**不许压在战术区里**：岩石/树一旦落在格子上就是穿模 + 挡住棋盘。
		# 落在区内的按 z 方向推到环境带（保留 x，读起来仍像"战场边上的那排石头"）。
		var p := Vector2(float(dd.get("x", 0.0)), float(dd.get("z", 0.0)))
		if inner0.has_point(p):
			var sign_z := 1.0 if p.y >= 0.0 else -1.0
			var edge := inner0.position.y + inner0.size.y
			p.y = sign_z * (edge + 4.0 + rng.randf_range(0.0, 9.0))
			dd["z"] = snappedf(p.y, 0.01)
		kept.append(dd)
	var sz: Vector2 = ShellStore.size_of(shell)
	var area: Rect2 = ShellStore.play_area(shell)
	var hx := sz.x * 0.5 - RING_MARGIN_M
	var hz := sz.y * 0.5 - RING_MARGIN_M
	# play_area 外扩 3m：装饰绝不压在战术格子边上（格间只有 1.3m 间隙）
	var inner := area.grow(3.0)
	var y := -hz
	while y <= hz:
		var x := -hx
		while x <= hx:
			if not inner.has_point(Vector2(x, y)) and rng.randf() < RING_KEEP:
				var kind: String = RING_KINDS[rng.randi() % RING_KINDS.size()]
				kept.append({
					"kind": kind,
					"x": snappedf(x + rng.randf_range(-4.0, 4.0), 0.01),
					"z": snappedf(y + rng.randf_range(-4.0, 4.0), 0.01),
					"y": 0.0,
					"yaw": snappedf(rng.randf_range(0.0, 360.0), 0.1),
					"scale": snappedf(rng.randf_range(0.85, 1.35), 0.01),
					"auto": true,
					"batch": true,
				})
			x += RING_STEP_M
		y += RING_STEP_M
	shell["decorations"] = kept
	print("[gen] decor: 合计 %d（远景 %d）" % [kept.size(), _count_auto(kept)])


func _count_auto(rows: Array) -> int:
	var n := 0
	for r in rows:
		if bool((r as Dictionary).get("auto", false)):
			n += 1
	return n

