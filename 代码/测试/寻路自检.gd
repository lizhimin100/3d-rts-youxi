extends SceneTree
## **寻路自检**：不依赖 autoload，直接构造网格验证 GridPathfinder 的正确性与性能。
## 运行：
##   & 'godot.cmd' --headless --path . --script 代码/测试/寻路自检.gd
## 覆盖：空旷可达 / 绕墙 / 完全封闭不可达 / 禁止切角 / 视线 / 真实地图 / 性能。

var _pass: int = 0
var _fail: int = 0
var _lines: Array[String] = []


func _initialize() -> void:
	print("========== 寻路自检 ==========")
	_test_open_field()
	_test_wall_with_gap()
	_test_enclosed()
	_test_no_corner_cut()
	_test_line_of_sight()
	_test_real_map()
	_test_perf()
	print("-------------------------------")
	for l in _lines:
		print(l)
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])


## 造一块 size×size 全可走的网格
func _blank_grid(size: int) -> GridPathfinder:
	var w := PackedByteArray()
	w.resize(size * size)
	w.fill(1)
	var p := GridPathfinder.new()
	p.build(float(size), w)
	return p


func _test_open_field() -> void:
	var p := _blank_grid(64)
	var a := Vector3(-20.0, 0.0, -20.0)
	var b := Vector3(20.0, 0.0, 20.0)
	var path := p.find_path(a, b)
	_ok("空旷直线可达", path.size() >= 1, "路点数=%d" % path.size())
	if path.size() >= 1:
		var end: Vector3 = path[path.size() - 1]
		_ok("终点贴合目标", Vector2(end.x, end.z).distance_to(Vector2(b.x, b.z)) < 1.2,
			"终点=(%.2f,%.2f) 目标=(%.2f,%.2f)" % [end.x, end.z, b.x, b.z])
		var all_walkable := true
		for pt in path:
			if not p.is_walkable(pt):
				all_walkable = false
		_ok("路径点全部可走", all_walkable)


func _test_wall_with_gap() -> void:
	# 在 x=0 竖一道墙，中间留 3 格缺口
	var p := _blank_grid(64)
	for z in range(0, 64):
		if z >= 30 and z <= 33:
			continue
		var cell := Vector2i(32, z)
		p.mark_blocked(cell, true)
	var a := Vector3(-20.0, 0.0, 0.0)
	var b := Vector3(20.0, 0.0, 0.0)
	var path := p.find_path(a, b)
	_ok("绕墙可达", path.is_empty() == false, "路点数=%d" % path.size())
	# 沿路径逐段密集采样，验证"真的穿过了缺口"且"全程不踩阻挡格"
	var crosses_gap := false
	var all_walkable := true
	var prev := a
	for pt in path:
		for i in range(21):
			var s := prev.lerp(pt, float(i) / 20.0)
			var c := p.world_to_cell(s)
			if c.x == 32 and c.y >= 30 and c.y <= 33:
				crosses_gap = true
			if not p.is_walkable(s):
				all_walkable = false
		prev = pt
	_ok("从缺口穿过", crosses_gap)
	_ok("绕墙路径不穿墙", all_walkable)


func _test_enclosed() -> void:
	# 把目标整块围死
	var p := _blank_grid(64)
	for z in range(30, 38):
		for x in range(30, 38):
			p.mark_blocked(Vector2i(x, z), true)
	# 边界也算围死：目标在 (34,34) 全是墙，最近可走格在外圈
	var a := Vector3(-24.0, 0.0, -24.0)
	var b := Vector3(34.0 - 32.0, 0.0, 34.0 - 32.0)  # 目标就在墙里
	var path := p.find_path(a, b)
	# 目标不可走时会落到最近可走格，所以应当仍能返回一条路径
	_ok("目标在障碍内 → 落到最近可走点", path.size() >= 1, "路点数=%d" % path.size())
	# 真正不可达：目标本身可走，但被一圈厚墙彻底围死（最近可走格就在口袋内）
	var p2 := _blank_grid(32)
	for z in range(20, 30):
		for x in range(20, 30):
			var inside := x >= 24 and x <= 26 and z >= 24 and z <= 26
			if not inside:
				p2.mark_blocked(Vector2i(x, z), true)
	var goal := p2.cell_to_world(Vector2i(25, 25))
	var path2 := p2.find_path(Vector3(-10.0, 0.0, -10.0), goal)
	_ok("被围死返回空路径", path2.is_empty(), "路点数=%d" % path2.size())


func _test_no_corner_cut() -> void:
	var p := _blank_grid(32)
	# 形成 2x2 的斜角格局：(10,10) 与 (11,11) 可走，另两个阻挡
	p.mark_blocked(Vector2i(11, 10), true)
	p.mark_blocked(Vector2i(10, 11), true)
	var a := p.cell_to_world(Vector2i(10, 10))
	var b := p.cell_to_world(Vector2i(11, 11))
	var path := p.find_path(a, b)
	# 这条路径必须绕开或直接判定不可达，不能从两堵墙的缝里斜穿
	var ok := true
	if path.size() >= 2:
		var prev := a
		for pt in path:
			# 逐段采样，检查是否踩到阻挡格
			var steps := 10
			for i in range(steps + 1):
				var s := prev.lerp(pt, float(i) / float(steps))
				if not p.is_walkable(s):
					ok = false
			prev = pt
	_ok("禁止斜穿墙角", ok, "路点数=%d" % path.size())


func _test_line_of_sight() -> void:
	var p := _blank_grid(32)
	_ok("空旷视线通", p.line_of_sight(Vector3(-10, 0, -10), Vector3(10, 0, 10)))
	for z in range(0, 32):
		p.mark_blocked(Vector2i(16, z), true)
	_ok("隔墙视线断", not p.line_of_sight(Vector3(-10, 0, 0), Vector3(10, 0, 0)))


func _test_real_map() -> void:
	var cfg := GameConfig.new()
	cfg.units = UnitTable.build_units()
	var data := MapGenerator.build(cfg)
	var p := GridPathfinder.new()
	p.build(data.size, data.walkable)
	var a3 := Vector3(cfg.player_base_pos.x, 0.0, cfg.player_base_pos.y)
	var b3 := Vector3(cfg.enemy_base_pos.x, 0.0, cfg.enemy_base_pos.y)
	var path := p.find_path(a3, b3)
	_ok("真实地图：双方基地之间可通", path.is_empty() == false, "路点数=%d" % path.size())
	if not path.is_empty():
		var walkable := p.is_walkable(path[path.size() - 1])
		_ok("真实地图：终点可走", walkable)
		var dist := 0.0
		var prev := a3
		for pt in path:
			dist += prev.distance_to(pt)
			prev = pt
		_ok("真实地图：路径长度合理", dist < 200.0, "总长 %.1fm（直线 %.1fm）" % [dist, a3.distance_to(b3)])
	# 金矿位置附近应当可走到
	print("  · 地图统计：树 %d 棵，金矿 %d 座，岩石 %d 块" % [data.trees.size(), data.mines.size(), data.rocks.size()])


func _test_perf() -> void:
	var p := _blank_grid(116)
	# 随机撒 12% 的障碍
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for z in range(116):
		for x in range(116):
			if rng.randf() < 0.12:
				p.mark_blocked(Vector2i(x, z), true)
	# 保证起终点可走
	p.mark_blocked(Vector2i(10, 10), false)
	p.mark_blocked(Vector2i(105, 105), false)
	var t0 := Time.get_ticks_usec()
	var n := 40
	var found := 0
	for i in range(n):
		var path := p.find_path(p.cell_to_world(Vector2i(10, 10)), p.cell_to_world(Vector2i(105, 105)))
		if not path.is_empty():
			found += 1
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_ok("性能：116² 网格 40 次寻路 < 200ms", ms < 200.0,
		"总耗时 %.1fms，平均 %.2fms/次，成功 %d/%d" % [ms, ms / float(n), found, n])
