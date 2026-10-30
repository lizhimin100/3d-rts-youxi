extends SceneTree
## **地图生成自检**：不依赖 autoload，直接生成两张图做回归。
## 运行：
##   godot --headless --path . --script 代码/测试/地图生成自检.gd
##
## 覆盖：同种子确定性 / 尺寸 / 高度极差 / 台地面积与坡道 / 沟壑存在 /
##       平地保护区（footprint 高差 <0.5m）/ walkable 连通性 /
##       金矿与树可达 / 生成耗时 / 俯视 ASCII 图（人眼可核）。

var _pass: int = 0
var _fail: int = 0
var _lines: Array[String] = []


func _initialize() -> void:
	print("========== 地图生成自检 ==========")
	var cfg := GameConfig.new()
	cfg.units = UnitTable.build_units()

	# --- 1. 同种子两次生成 ---
	var t0: int = Time.get_ticks_usec()
	var a: MapGenerator.MapData = MapGenerator.build(cfg)
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var b: MapGenerator.MapData = MapGenerator.build(cfg)

	_test_basic(a, cfg)
	_test_determinism(a, b)
	_test_height(a, cfg)
	_test_flat_zones(a, cfg)
	_test_plateau(a, cfg)
	_test_gorges(a, cfg)
	_test_connectivity(a, cfg)
	_test_props(a, cfg)
	_test_roads(a, cfg)
	_test_chokes(a, cfg)
	_test_ground_detail(a, cfg)
	_test_time(gen_ms)

	print("-------------------------------")
	for l in _lines:
		print(l)
	print("  —— 统计 ——")
	print("  地图 %.0fm / 高精度 %d / 网格 %d² / 可走 %.1f%%" % [
		a.size, a.resolution, int(a.size), float(a.stats.get("walkable_pct", 0.0))])
	print("  高度 %.2f m … %.2f m（极差 %.1f）" % [
		float(a.stats.get("min_h", 0.0)), float(a.stats.get("max_h", 0.0)),
		float(a.stats.get("max_h", 0.0)) - float(a.stats.get("min_h", 0.0))])
	print("  台地顶面 %.0f m² / 树 %d / 岩石 %d / 金矿 %d / 草 %d / 碎石 %d" % [
		a.plateau_area, a.trees.size(), a.rocks.size(), a.mines.size(), a.grass.size(), a.rubble.size()])
	print("  土路 %d 段 / %d 点 / 装饰 %d 件（%s）/ 关口 %d 处" % [
		a.roads.size(), int(a.stats.get("road_pts", 0)), a.decor_count(),
		_decor_brief(a), a.chokes.size()])
	print("  生成 %.1f ms / 连通修复 %d 次 / 砍掉够不到的树 %d 棵" % [
		gen_ms, int(a.stats.get("connect_carves", 0)), int(a.stats.get("unreachable_trees", 0))])
	print("  连通修复的目标：%s" % str(a.stats.get("connect_bad", [])))
	for i in range(a.ramps.size()):
		var rp: Dictionary = a.ramps[i]
		var m: Vector2 = rp["mouth"]
		var tp: Vector2 = rp["top_pos"]
		var seg: PackedStringArray = []
		for k in range(9):
			var q: Vector2 = tp.lerp(m, float(k) / 8.0)
			seg.append("%.1f" % a.height_at(q.x, q.y))
		print("  坡道%d：%s 高(%s) 口(%.1f,%.1f) 顶(%.1f,%.1f)" % [
			i + 1, " ".join(seg), str(a.is_walkable_at(m.x, m.y)), m.x, m.y, tp.x, tp.y])
	_print_ascii(a, cfg)
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])


# ===========================================================================
# 基础
# ===========================================================================
func _test_basic(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	_ok("地图边长 = %.0fm" % cfg.map_size, is_equal_approx(a.size, cfg.map_size), "%.1f" % a.size)
	_ok("高度场长度 = (res+1)²", a.heights.size() == (a.resolution + 1) * (a.resolution + 1),
		"%d vs %d" % [a.heights.size(), (a.resolution + 1) * (a.resolution + 1)])
	_ok("可走数组长度 = size²", a.walkable.size() == int(a.size) * int(a.size),
		"%d vs %d" % [a.walkable.size(), int(a.size) * int(a.size)])
	_ok("金矿数量 ≥ 5（双方基地 + 两富矿 + 中央）", a.mines.size() >= 5, "%d 座" % a.mines.size())
	_ok("树数量 ≥ 80", a.trees.size() >= 80, "%d 棵" % a.trees.size())


func _test_determinism(a: MapGenerator.MapData, b: MapGenerator.MapData) -> void:
	var same_h: bool = a.heights == b.heights
	var same_w: bool = a.walkable == b.walkable
	var same_t: bool = a.trees == b.trees
	var same_m: bool = a.mines == b.mines
	_ok("同种子：高度场完全一致", same_h)
	_ok("同种子：可走性完全一致", same_w, "hash=%d" % hash(a.walkable))
	_ok("同种子：树/矿落点一致", same_t and same_m,
		"树 %d/%d 矿 %d/%d" % [a.trees.size(), b.trees.size(), a.mines.size(), b.mines.size()])
	var same_r: bool = _roads_sig(a) == _roads_sig(b)
	var same_d: bool = _decor_sig(a) == _decor_sig(b)
	_ok("同种子：土路/装饰落点一致", same_r and same_d,
		"路 %d / 装饰 %d" % [a.roads.size(), a.decor_count()])


## 土路签名（坐标量化后拼串，便于确定性比较）
func _roads_sig(d: MapGenerator.MapData) -> String:
	var parts: PackedStringArray = []
	for rd in d.roads:
		var pts: PackedVector2Array = rd["pts"]
		parts.append("%s:%.1f:%d:%d,%d" % [rd["kind"], rd["width"], pts.size(),
			roundi(pts[0].x * 10.0), roundi(pts[0].y * 10.0)])
		parts.append("%d,%d" % [roundi(pts[pts.size() - 1].x * 10.0),
			roundi(pts[pts.size() - 1].y * 10.0)])
	return "|".join(parts)


## 装饰签名：种类 + 数量 + 首末点
func _decor_sig(d: MapGenerator.MapData) -> String:
	var keys: Array = d.decor.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		var arr: Array = d.decor[k]
		var p0: Vector3 = arr[0]["pos"] if arr.size() > 0 else Vector3.ZERO
		parts.append("%s=%d@%d,%d" % [k, arr.size(), roundi(p0.x * 10.0), roundi(p0.z * 10.0)])
	return "|".join(parts)


func _test_height(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	var lo: float = float(a.stats.get("min_h", 0.0))
	var hi: float = float(a.stats.get("max_h", 0.0))
	# v3.2 起外圈山脊整圈删除（用户口径："地图边缘要正常，不要一个大山谷把地图包起来"），
	# 高度极差只由台地(7.4m) + 峡谷(-6.5m) 造成 → 门槛从 20m 改到 10m。
	_ok("高度极差 ≥ 10m（台地 + 峡谷）", hi - lo >= 10.0, "%.1f m" % (hi - lo))
	_ok("台地立得起来", hi >= cfg.map_mesa_height * 0.95, "最高 %.1f m" % hi)
	_ok("峡谷是负高差", lo <= -cfg.map_gorge_depth * 0.6, "最低 %.1f m" % lo)

	# 边缘平坦：沿四边各取 9 点（距边界 3/8/16m），任意一点都不能越过"地面正常起伏"。
	# 旧实现这里会是 16~26m 的等高墙 —— 这条断言就是防止它偷偷长回来。
	var half: float = a.size * 0.5
	var worst: float = -INF
	var worst_at := Vector2.ZERO
	for d in [3.0, 8.0, 16.0]:
		var e: float = half - d
		for i in range(9):
			var t: float = -e + 2.0 * e * float(i) / 8.0
			for p in [Vector2(t, -e), Vector2(t, e), Vector2(-e, t), Vector2(e, t)]:
				var h: float = a.height_at(p.x, p.y)
				if h > worst:
					worst = h
					worst_at = p
	_ok("地图边缘不起墙（外圈最高 ≤ 4m）", worst <= 4.0,
			"最高 %.1f m @ (%.0f,%.0f)" % [worst, worst_at.x, worst_at.y])


func _test_flat_zones(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	var worst: float = 0.0
	var worst_kind: String = ""
	var bad: int = 0
	var details: PackedStringArray = []
	for z in a.flat_zones:
		var p: Vector2 = z["pos"]
		var kind: String = z["kind"]
		var r: float = 8.0 if kind == "base" else (3.5 if kind == "mine" else 4.0)
		var lo: float = INF
		var hi: float = -INF
		var n: int = 8
		for iz in range(n + 1):
			for ix in range(n + 1):
				var q := p + Vector2(lerpf(-r, r, float(ix) / n), lerpf(-r, r, float(iz) / n))
				var h: float = a.height_at(q.x, q.y)
				lo = minf(lo, h)
				hi = maxf(hi, h)
		var rng_h: float = hi - lo
		if rng_h > worst:
			worst = rng_h
			worst_kind = "%s @ (%.0f,%.0f)" % [kind, p.x, p.y]
		if rng_h > 0.5:
			bad += 1
		details.append("%s(%.0f,%.0f)=%.2f" % [kind, p.x, p.y, rng_h])
	_ok("关键点落脚区高差 < 0.5m（基地/金矿/坡道口）", bad == 0,
		"%d 处超标；最大 %.3fm（%s）" % [bad, worst, worst_kind])
	_lines.append("    · 各保护区高差：" + " ".join(details))


func _test_plateau(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	_ok("台地顶面面积 ≥ 600 m²", a.plateau_area >= 600.0, "%.0f m²" % a.plateau_area)
	_ok("台地高度 ≥ 6m", float(a.plateau.get("top", 0.0)) >= 6.0,
		"顶面 %.1f m" % float(a.plateau.get("top", 0.0)))
	# 崖壁陡：从顶面边缘向外 8m 的落差应当 > 4m
	var top_h: float = float(a.plateau.get("top", 0.0))
	var steep_drop: float = 0.0
	# 取一个避开坡道的方位（沿坡道方向转 100°），测崖壁落差
	var ang: float = deg_to_rad(100.0) + float(a.ramps[0]["angle"])
	var probe := Vector2(cos(ang), sin(ang)) * (cfg.map_mesa_radius + 6.0)
	steep_drop = top_h - a.height_at(probe.x, probe.y)
	_ok("台地崖壁陡峭（外缘 6m 内落差 > 4m）", steep_drop > 4.0, "落差 %.1f m" % steep_drop)
	_ok("坡道数量 = 2（双方各一条）", a.ramps.size() == 2, "%d 条" % a.ramps.size())
	# 坡道自身坡度可走
	for i in range(a.ramps.size()):
		var rp: Dictionary = a.ramps[i]
		var mouth: Vector2 = rp["mouth"]
		var top_pos: Vector2 = rp["top_pos"]
		var drop: float = a.height_at(top_pos.x, top_pos.y) - a.height_at(mouth.x, mouth.y)
		var run: float = mouth.distance_to(top_pos)
		var slope: float = absf(drop) / maxf(run, 0.001)
		_ok("坡道 %d 坡度可走（< 0.8）" % (i + 1), slope < 0.8,
			"落差 %.1f m / 水平 %.1f m = %.2f" % [drop, run, slope])


func _test_gorges(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	_ok("峡谷数量 = 2（点对称）", a.gorges.size() == 2, "%d 条" % a.gorges.size())
	var g: Dictionary = a.gorges[0]
	# 取 t=0.28（水潭附近，远离中间石桥）测谷底
	var a0: Vector2 = g["a"]
	var b0: Vector2 = g["b"]
	var dir: Vector2 = (b0 - a0).normalized()
	var mid: Vector2 = a0.lerp(b0, 0.28)
	var floor_h: float = a.height_at(mid.x, mid.y)
	var rim_h: float = a.height_at(mid.x + 12.0, mid.y + 12.0)
	_ok("峡谷存在负高差", floor_h < rim_h - 3.0, "谷底 %.1f m / 谷外 %.1f m" % [floor_h, rim_h])
	var bridge_h: float = a.height_at(g["bridge"].x, g["bridge"].y)
	_ok("峡谷中间的石桥能走（谷深但桥面回到地面）", bridge_h > floor_h + 3.0,
		"桥面 %.1f m / 谷底 %.1f m" % [bridge_h, floor_h])
	_ok("峡谷中有水潭（沉在谷底）", a.pond_radius > 0.0 and a.pond_level < 0.0,
		"半径 %.0f m / 水面 %.1f m" % [a.pond_radius, a.pond_level])


# ===========================================================================
# 连通性
# ===========================================================================
func _test_connectivity(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	var pf := GridPathfinder.new()
	pf.build(a.size, a.walkable)
	var base_a := Vector3(cfg.player_base_pos.x, 0.0, cfg.player_base_pos.y)
	var base_b := Vector3(cfg.enemy_base_pos.x, 0.0, cfg.enemy_base_pos.y)
	var mid := Vector3(0.0, 0.0, 0.0)
	var p_ab: PackedVector3Array = pf.find_path(base_a, base_b)
	_ok("双方基地之间可通", p_ab.size() > 0, "路点 %d" % p_ab.size())
	var p_ac: PackedVector3Array = pf.find_path(base_a, mid)
	_ok("基地 → 中央台地可通", p_ac.size() > 0, "路点 %d" % p_ac.size())
	for i in range(a.mines.size()):
		var m: Vector2 = a.mines[i]
		var p: PackedVector3Array = pf.find_path(base_a, Vector3(m.x, 0.0, m.y))
		_ok("基地 → 金矿 %d 可通" % (i + 1), p.size() > 0,
			"(%.0f,%.0f) 路点 %d" % [m.x, m.y, p.size()])
	# 树：能从基地寻到（抽样 12 棵，避免 150 次 A* 拖慢自检）
	var sample: int = mini(12, a.trees.size())
	var reach: int = 0
	for i in range(sample):
		var t: Vector2 = a.trees[i * maxi(1, a.trees.size() / sample)]
		var p: PackedVector3Array = pf.find_path(base_a, Vector3(t.x, 0.0, t.y))
		if p.size() > 0:
			reach += 1
	_ok("基地 → 树林可通（抽样 %d 棵）" % sample, reach == sample, "%d/%d" % [reach, sample])
	# 出生点可走
	_ok("玩家出生点可走", pf.is_walkable(base_a))
	_ok("敌人出生点可走", pf.is_walkable(base_b))
	# 可走面积合理（别整张图都不可走）
	var pct: float = float(a.stats.get("walkable_pct", 0.0))
	_ok("可走面积在 40%…92% 之间", pct > 40.0 and pct < 92.0, "%.1f%%" % pct)


func _test_props(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	# 树不能长在陡坡上（森林边缘可以，但树心必须平）
	var steep: int = 0
	for t in a.trees:
		var hx: float = a.height_at(t.x + 0.6, t.y) - a.height_at(t.x - 0.6, t.y)
		var hz: float = a.height_at(t.x, t.y + 0.6) - a.height_at(t.x, t.y - 0.6)
		if Vector2(hx, hz).length() > 0.9:
			steep += 1
	_ok("没有树长在陡坡/崖壁上", steep == 0, "%d 棵异常" % steep)
	var grass_ok: bool = a.grass.size() >= int(cfg.map_decor_grass * 0.5)
	_ok("地表装饰点已生成", grass_ok, "草 %d / 碎石 %d" % [a.grass.size(), a.rubble.size()])


## --- 土路 ---------------------------------------------------------------
func _test_roads(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	var kinds: Dictionary = {}
	var total_len: float = 0.0
	var bad_pts: int = 0
	var pts_total: int = 0
	for rd in a.roads:
		var k: String = rd["kind"]
		kinds[k] = int(kinds.get(k, 0)) + 1
		var pts: PackedVector2Array = rd["pts"]
		for i in range(pts.size()):
			pts_total += 1
			if not a.is_walkable_at(pts[i].x, pts[i].y):
				bad_pts += 1
			if i > 0:
				total_len += pts[i - 1].distance_to(pts[i])
	_ok("土路：主路/支路/绕行小径都在", int(kinds.get("main", 0)) >= 1
		and int(kinds.get("branch", 0)) >= 2 and int(kinds.get("trail", 0)) >= 1,
		"main=%d branch=%d trail=%d" % [kinds.get("main", 0), kinds.get("branch", 0), kinds.get("trail", 0)])
	_ok("土路总长 ≥ 240m", total_len >= 240.0, "%.0f m / %d 个点" % [total_len, pts_total])
	_ok("土路全部踩在可走地面上", bad_pts == 0 and pts_total > 0,
		"越界点 %d / %d" % [bad_pts, pts_total])
	# 主路首尾贴住双方基地（中央金矿会把主路切成两段，所以看所有 main 段）
	var near_a: bool = false
	var near_b: bool = false
	for rd in a.roads:
		if String(rd["kind"]) != "main":
			continue
		for p in rd["pts"]:
			if p.distance_to(cfg.player_base_pos) < 3.0:
				near_a = true
			if p.distance_to(cfg.enemy_base_pos) < 3.0:
				near_b = true
	_ok("主路从玩家基地通到敌人基地", near_a and near_b,
		"玩家端 %s / 敌人端 %s" % [str(near_a), str(near_b)])


## --- 关口 ---------------------------------------------------------------
func _test_chokes(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	_ok("关口数量 ≥ 3（两道石门 + 峡谷石桥）", a.chokes.size() >= 3, "%d 处" % a.chokes.size())
	var gates: Array = []
	for c in a.chokes:
		if String(c["kind"]) == "gate":
			gates.append(c)
	_ok("石门数量 = 2", gates.size() == 2, "%d 道" % gates.size())
	var worst: float = 0.0
	var widths: PackedStringArray = []
	for g in gates:
		var c: Vector2 = g["pos"]
		var pa: Vector2 = g["a"]
		var pb: Vector2 = g["b"]
		var dir: Vector2 = (pb - pa).normalized()
		# 沿脊线扫：从中心往两边找"可走"的连续区，得到净宽
		var lo: float = 0.0
		var hi: float = 0.0
		var k: float = 0.5
		while k < 14.0 and a.is_walkable_at((c - dir * k).x, (c - dir * k).y):
			lo = k
			k += 0.5
		k = 0.5
		while k < 14.0 and a.is_walkable_at((c + dir * k).x, (c + dir * k).y):
			hi = k
			k += 0.5
		var width: float = lo + hi
		widths.append("%.0fm" % width)
		if width > worst:
			worst = width
		# 两侧脊线应当真的立起来（比缺口中心高）
		var h_mid: float = a.height_at(c.x, c.y)
		var h_side: float = a.height_at((c + dir * (width * 0.5 + 2.0)).x,
			(c + dir * (width * 0.5 + 2.0)).y)
		if h_side - h_mid < 1.2:
			worst = 99.0
	_ok("石门是窄口（净宽 4…14m）且两侧有高差", worst <= 14.0 and worst < 90.0,
		"净宽 " + " / ".join(widths))


## --- 地表细节 -----------------------------------------------------------
func _test_ground_detail(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	var d: Dictionary = a.decor
	var mushroom: int = (d.get("mushroom", []) as Array).size()
	var dead: int = (d.get("dead_tree", []) as Array).size()
	var wall: int = (d.get("wall", []) as Array).size()
	var boulder: int = (d.get("boulder", []) as Array).size()
	var camp: int = 0
	for k in ["crate", "barrel", "fence", "campfire", "log"]:
		camp += (d.get(k, []) as Array).size()
	# 用户明确要求：地上不要"树桩/枯木"（看起来像地摊货）。0 是设计值，不是缺料。
	# v3.3：玩家反馈"场景里那些小东西太多了，影响观感" → 蘑菇口径归 0、杂物密度下调。
	# 断言跟着改成"新的设计值"，不是放宽：蘑菇必须 0，断墙/巨石仍在（它们是地标级装饰）。
	_ok("边角装饰：断墙/关口巨石在，蘑菇与枯木为 0（设计口径）", mushroom == 0 and dead == 0
		and wall >= 6 and boulder >= 20,
		"蘑菇 %d / 枯木 %d / 断墙 %d / 巨石 %d" % [mushroom, dead, wall, boulder])
	_ok("营地杂物 10~22 件（双方对称，密度已下调）", camp >= 10 and camp <= 22, "%d 件" % camp)
	# 每方基地 22m 内都要有营地杂物
	var near_a: int = 0
	var near_b: int = 0
	for k in ["crate", "barrel", "fence", "campfire", "log"]:
		for e in d.get(k, []):
			var p := Vector2(e["pos"].x, e["pos"].z)
			if p.distance_to(cfg.player_base_pos) < 22.0:
				near_a += 1
			if p.distance_to(cfg.enemy_base_pos) < 22.0:
				near_b += 1
	_ok("双方出生点都有营地感", near_a >= 6 and near_b >= 6, "玩家 %d / 敌人 %d" % [near_a, near_b])
	# 装饰必须贴地（没有浮空/陷地）
	var floating: int = 0
	for k in d:
		for e in d[k]:
			var v: Vector3 = e["pos"]
			if absf(v.y - a.height_at(v.x, v.z)) > 0.45:
				floating += 1
	_ok("装饰贴地（高差 ≤ 0.45m）", floating == 0, "%d 个浮空" % floating)
	# v3.3：草 2400→1500、碎石 620→360（同上：密度太高反而脏）。
	var decor_total: int = a.grass.size() + a.rubble.size() + a.decor_count()
	_ok("装饰总量 1500~2800（草/碎石/边角料，密度已下调）", decor_total >= 1500 and decor_total <= 2800,
		"%d" % decor_total)


func _test_time(gen_ms: float) -> void:
	_ok("生成耗时 < 1500ms", gen_ms < 1500.0, "%.1f ms" % gen_ms)


## 装饰种类 → 数量的短摘要
func _decor_brief(a: MapGenerator.MapData) -> String:
	var keys: Array = a.decor.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		parts.append("%s%d" % [k, (a.decor[k] as Array).size()])
	return " ".join(parts)


# ===========================================================================
# 俯视 ASCII 图（人眼复核地形形状）
# ===========================================================================
func _print_ascii(a: MapGenerator.MapData, cfg: GameConfig) -> void:
	var n: int = 48
	print("  —— 俯视图（北在上，x→右，z→下；# 崖/不可走，^ 台地，~ 水，= 土路，. 平地，, 高处）——")
	var half: float = a.size * 0.5
	var top: float = float(a.plateau.get("top", 7.0))
	for iz in range(n):
		var row_s: String = ""
		for ix in range(n):
			var wx: float = lerpf(-half + 1.0, half - 1.0, float(ix) / float(n - 1))
			var wz: float = lerpf(-half + 1.0, half - 1.0, float(iz) / float(n - 1))
			var h: float = a.height_at(wx, wz)
			var walk: bool = a.is_walkable_at(wx, wz)
			var ch: String = "."
			if a.pond_radius > 0.0 and Vector2(wx, wz).distance_to(a.pond_center) < a.pond_radius:
				ch = "~"
			elif not walk:
				ch = "#"
			elif h > top - 1.0 and Vector2(wx, wz).length() < cfg.map_mesa_radius + 2.0:
				ch = "^"
			elif h > 12.0:
				ch = ","
			elif h < -2.0:
				ch = "v"
			elif MapGenerator.road_distance(a, Vector2(wx, wz)) < 2.3:
				ch = "="
			row_s += ch
		print("  " + row_s)
