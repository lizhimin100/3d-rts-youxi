extends SceneTree
## **建造自检**：农民 → 工地 → 完工 → 集结点，全链路无头验证。
##
## 运行（★ 不要加 --import）：
##   godot --headless --path . --script 代码/测试/建造自检.gd
##
## 覆盖：
##   1. 5 个随机落点吸附后都是格宽整数倍（footprint 正好压住整数格）
##   2. 越界 / 压水 / 压建筑 → 被拒
##   3. 真造一栋兵营：进度 0 → 1，is_constructed 变 true，血量补满
##   4. 造一次只扣一次钱（以前指令系统 pay 一次、order_build 再 pay 一次，80 金的农场扣 160）
##   5. 3 个农民同时进 BUILD；第 4 个再点同一落点 → 挂到同一工地、不重复扣钱
##   6. 集结点三接口 request_set_rally / is_rally_pending / cancel_rally + 地面小旗
##   7. 设集结点后训练出的农民会朝集结点走
##
## ★ 为什么满篇 call()/get() 而没有一行 `Game.xxx`：
##   `--script` 模式下主循环被本脚本接管，autoload 的**全局标识符**在本文件解析时还没注册
##   （实测报 `Identifier not found: Cfg`）。所以这里只能 load() + 鸭子调用 —— 这是运行环境的
##   硬约束，不是偷懒。自检本身仍跑在**真关卡、真单位、真寻路网格**上。

const LEVEL_SCRIPT := "res://代码/核心/关卡.gd"
const CMD_SCRIPT := "res://代码/操作/指令系统.gd"

const BARRACKS := &"barracks"
const PEASANT := &"peasant"
const TOWNHALL := &"townhall"
## RtsConst.Order.BUILD
const ORDER_BUILD := 7

var _game: Node = null
var _cfg: Node = null
var _level: Node3D = null
var _cmd: Node = null
var _pf: Object = null
var _faction: Object = null

var _pass: int = 0
var _fail: int = 0
var _lines: Array[String] = []

var _bdef: Object = null
var _anchor := Vector3.ZERO
var _site: Node3D = null
var _crew: Array = []
var _crew2: Array = []
var _gold0: int = 0
var _wood0: int = 0
var _gold1: int = 0
var _wood1: int = 0

var _phase: int = 0
var _frames: int = 0
var _phase_frames: int = 0
var _saw_working: bool = false

var _before_units: Array = []
var _newbie: Node3D = null
var _rally_point := Vector3.ZERO
var _dist0: float = 0.0
var _dist1: float = 0.0
var _walk_frames: int = 0
var _done: bool = false
var _booted: bool = false


# ===========================================================================
# 启动
# ===========================================================================

func _initialize() -> void:
	# 世界必须等第一帧再搭：_initialize() 时 root 还没真正进树，
	# 这会在 spawn_unit → mark_footprint → global_position 上炸 "!is_inside_tree()"。
	print("========== 建造自检 ==========")


## 第一帧才搭世界（此时节点树已经活了）
func _boot_once() -> void:
	_booted = true
	_boot_world()
	_test_snap()
	_test_reject()
	_test_one_charge()
	_test_crew()
	Engine.time_scale = 20.0
	print("  · 世界：地图 %.0fm，锚点 (%.1f, %.1f)，工地=%s" % [
		float(_level.get("world_size")), _anchor.x, _anchor.z,
		_site.name if _site != null else "无"])
	print("  · 开始跑帧（兵营施工中）…")


func _boot_world() -> void:
	_game = root.get_node("Game")
	_cfg = root.get_node("Cfg")
	_game.call("reset")
	_game.set("difficulty_index", 0)
	_game.call("setup_factions")

	_level = load(LEVEL_SCRIPT).new()
	root.add_child(_level)
	_level.call("build")
	_level.call("spawn_props")
	_game.set("level", _level)
	_game.set("phase", 1)  # RtsConst.Phase.RUNNING
	_faction = _game.get("player_faction")
	_faction.call("add_res", 8000, 8000)
	_pf = _level.get("pathfinder")
	_cmd = load(CMD_SCRIPT).new()

	# 给一栋大本营：人口上限 + 资源交汇点 + "压建筑"用例的靶子
	var base: Vector3 = _level.call("base_center", _faction)
	_game.call("spawn_unit", _faction, TOWNHALL, _level.call("snap_grid", base), _level)

	_bdef = _cfg.call("unit", BARRACKS)
	if _bdef == null:
		push_error("[建造自检] 取不到兵营定义")
		return
	_anchor = _find_anchor(base + Vector3(0.0, 0.0, 15.0), _bdef, 30)
	if not _anchor.is_finite():
		push_error("[建造自检] 基地附近找不到可建的 6×6 空地")


## 在 center 附近螺旋找一块"真能放"的锚点（返回 INF 表示没找到）
func _find_anchor(center: Vector3, d: Object, max_r: int) -> Vector3:
	var fp: Vector2i = d.get("footprint")
	var c0: Vector2i = _pf.call("world_to_cell", center)
	for r in range(0, max_r):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var cw: Vector3 = _pf.call("cell_to_world", Vector2i(c0.x + dx, c0.y + dz))
				var anchor: Vector3 = _cmd.call("snap_build_pos", cw, fp)
				if bool(_cmd.call("_can_place", anchor, d)):
					return anchor
	return Vector3(INF, INF, INF)


# ===========================================================================
# 1. 吸附
# ===========================================================================

func _test_snap() -> void:
	var fp: Vector2i = _bdef.get("footprint")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261018
	var all_ok: bool = true
	var detail: PackedStringArray = []
	for i in range(5):
		var p := Vector3(rng.randf_range(-50.0, 50.0), 0.0, rng.randf_range(-50.0, 50.0))
		var s: Vector3 = _cmd.call("snap_build_pos", p, fp)
		# 判据是"占地的**最小角**落在 1m 格点上"，不是"中心必须是整数"：
		# 偶数边长吸格线（中心整数）、奇数边长吸格心（中心 .5）——
		# 两种都是对的，写死"中心必须整数"会把 6×7 的兵营判成失败。
		var sx0: float = s.x - float(fp.x) * 0.5
		var sz0: float = s.z - float(fp.y) * 0.5
		var aligned: bool = absf(sx0 - roundf(sx0)) < 0.0005 and absf(sz0 - roundf(sz0)) < 0.0005
		var whole: bool = _footprint_is_whole_cells(s, fp)
		all_ok = all_ok and aligned and whole
		detail.append("(%.1f,%.1f)→(%.1f,%.1f)" % [p.x, p.z, s.x, s.z])
	_ok("5 个随机落点吸附后都是格宽整数倍（%d×%d 整格）" % [fp.x, fp.y], all_ok, " ".join(detail))

	# 朝向：90° 档（建筑资产是正交设计，斜放会破面/露底）
	var snapped_yaw: float = float(_cmd.call("snap_yaw", 0.77)) \
		if _cmd.has_method("snap_yaw") else 0.0
	var yaw_ok: bool = false
	if _cmd.has_method("snap_yaw"):
		var step: float = PI * 0.5
		var q: float = round(snapped_yaw / step) * step
		yaw_ok = absf(angle_difference(snapped_yaw, q)) < 0.001
	_ok("建造朝向吸到 90° 档（0.77 rad → %.0f°）" % rad_to_deg(snapped_yaw), yaw_ok)


## 锚点是否正好压在格子边界（偶数边长）或格子中心（奇数边长），且占地整格在图内
func _footprint_is_whole_cells(anchor: Vector3, fp: Vector2i) -> bool:
	var c: Vector2i = _pf.call("world_to_cell", anchor)
	var cw: Vector3 = _pf.call("cell_to_world", c)
	var want_x: float = 0.0 if fp.x % 2 == 1 else -0.5
	var want_z: float = 0.0 if fp.y % 2 == 1 else -0.5
	if absf((anchor.x - cw.x) - want_x) > 0.0005:
		return false
	if absf((anchor.z - cw.z) - want_z) > 0.0005:
		return false
	for dz in range(-fp.y / 2, fp.y / 2 + fp.y % 2):
		for dx in range(-fp.x / 2, fp.x / 2 + fp.x % 2):
			if not bool(_pf.call("in_bounds", Vector2i(c.x + dx, c.y + dz))):
				return false
	return true


# ===========================================================================
# 2. 非法落点被拒
# ===========================================================================

func _test_reject() -> void:
	var fp: Vector2i = _bdef.get("footprint")
	var half: float = float(_level.get("world_size")) * 0.5

	# ① 越界：贴右边界放 6×6，必然有一半在图外
	var edge: Vector3 = _cmd.call("snap_build_pos", Vector3(half - 2.0, 0.0, 0.0), fp)
	_ok("越界（贴边放占地）被拒", not bool(_cmd.call("_can_place", edge, _bdef)),
		"锚点 (%.1f, %.1f)" % [edge.x, edge.z])

	# ② 压水
	var md: Object = _level.get("map_data")
	var radius: float = float(md.get("pond_radius"))
	if radius > 0.0:
		var pc: Vector2 = md.get("pond_center")
		var water: Vector3 = _cmd.call("snap_build_pos", Vector3(pc.x, 0.0, pc.y), fp)
		_ok("压在水面上被拒", not bool(_cmd.call("_can_place", water, _bdef)),
			"水塘心 (%.1f, %.1f)，半径 %.0fm" % [pc.x, pc.y, radius])
	else:
		_ok("压在水面上被拒", true, "本局没开水体，跳过")

	# ③ 压已有建筑（大本营）
	var th := _find_building(TOWNHALL)
	var over: Vector3 = _cmd.call("snap_build_pos", th.global_position if th != null else Vector3.ZERO, fp)
	_ok("压在已有建筑（大本营）上被拒", th != null and not bool(_cmd.call("_can_place", over, _bdef)),
		"大本营 (%.1f, %.1f)" % [(th.global_position.x if th != null else 0.0), (th.global_position.z if th != null else 0.0)])


# ===========================================================================
# 3/4. 真造一栋兵营 + 只扣一次钱 + 多农民
# ===========================================================================

func _test_one_charge() -> void:
	var fp: Vector2i = _bdef.get("footprint")
	_crew = _spawn_crew(_anchor, 3)
	_gold0 = int(_faction.get("gold"))
	_wood0 = int(_faction.get("wood"))
	_site = _cmd.call("place_building", BARRACKS, _anchor, _crew, PI * 0.5)
	_gold1 = int(_faction.get("gold"))
	_wood1 = int(_faction.get("wood"))

	var cg: int = int(_bdef.get("gold_cost"))
	var cw: int = int(_bdef.get("wood_cost"))
	_ok("造一次只扣一次钱", (_gold0 - _gold1) == cg and (_wood0 - _wood1) == cw,
		"金 -%d（应 -%d）木 -%d（应 -%d）" % [_gold0 - _gold1, cg, _wood0 - _wood1, cw])
	_ok("工地已立起且 progress=0 / is_constructed=false",
		_site != null and is_instance_valid(_site) and is_zero_approx(float(_site.get("progress")))
			and not bool(_site.get("is_constructed")),
		"progress=%s" % ("-" if _site == null else "%.2f" % float(_site.get("progress"))))
	if _site != null and is_instance_valid(_site):
		var sy: float = float(_site.get("rotation").y)
		var q2: float = round(sy / (PI * 0.5)) * (PI * 0.5)
		var grid_anchor: Vector3 = _cmd.call("snap_build_pos", _site.global_position, fp)
		_ok("工地朝向在 90° 档且落点是严格网格锚点",
			absf(angle_difference(sy, q2)) < 0.001 \
				and absf(grid_anchor.x - _site.global_position.x) < 0.001 \
				and absf(grid_anchor.z - _site.global_position.z) < 0.001,
			"yaw=%.0f° anchor=(%.1f, %.1f)" % [rad_to_deg(sy),
				_site.global_position.x, _site.global_position.z])


func _test_crew() -> void:
	var in_build: int = 0
	for w in _crew:
		if w != null and is_instance_valid(w) and int(w.get("order")) == ORDER_BUILD and w.get("_build_site") == _site:
			in_build += 1
	_ok("3 个农民同时进 BUILD（挂同一块工地）", in_build == 3, "%d / 3" % in_build)

	# 第 4 个农民再点同一落点：应当"加入"，不新建、不再扣钱
	var gold_before: int = int(_faction.get("gold"))
	_crew2 = _spawn_crew(_anchor, 1)
	var again: Variant = _cmd.call("place_building", BARRACKS, _anchor, _crew2)
	var gold_after: int = int(_faction.get("gold"))
	var sites: int = _count_unfinished(BARRACKS)
	_ok("重复点击同一落点 → 挂到同一工地", again == _site, "同一工地=%s" % str(again == _site))
	_ok("第 4 个农民加入时不重复扣钱", gold_before == gold_after, "金 %d → %d" % [gold_before, gold_after])
	_ok("未完工工地只有 1 块", sites == 1, "实际 %d 块" % sites)
	for w in _crew2:
		_crew.append(w)


func _spawn_crew(anchor: Vector3, count: int) -> Array:
	var out: Array = []
	for i in range(count):
		var ang: float = TAU * float(i) / float(maxi(count, 1))
		var p := anchor + Vector3(cos(ang) * 4.5, 0.0, sin(ang) * 4.5)
		p = _level.call("walkable_pos", p)
		var u: Node3D = _game.call("spawn_unit", _faction, PEASANT, p, _level)
		if u != null:
			out.append(u)
	return out


func _count_unfinished(id: StringName) -> int:
	var n: int = 0
	for b in _game.call("all_units"):
		if b == null or not is_instance_valid(b):
			continue
		var d = b.get("def")
		if d == null or String(d.get("id")) != String(id):
			continue
		var built = b.get("is_constructed")
		if built != null and not bool(built):
			n += 1
	return n


func _find_building(id: StringName) -> Node3D:
	for b in _game.call("all_units"):
		if b == null or not is_instance_valid(b) or not (b is Node3D):
			continue
		var d = b.get("def")
		if d == null or String(d.get("id")) != String(id):
			continue
		var built = b.get("is_constructed")
		if built == null or bool(built):
			return b
	return null


# ===========================================================================
# 每帧推进
# ===========================================================================

func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _booted:
		_boot_once()
		return false
	_frames += 1
	_phase_frames += 1
	if _frames % 60 == 0:
		var diag := "  · 心跳 第 %d 帧 阶段 %d 进度 %s" % [_frames, _phase, ("%.2f" % float(_site.get("progress"))) if _site != null and is_instance_valid(_site) else "-"]
		for w in _crew:
			if w != null and is_instance_valid(w):
				diag += " | order=%d 距工地=%.1fm 有工地=%s" % [
					int(w.get("order")),
					_flat(w.global_position, _site.global_position) if _site != null else -1.0,
					str(w.get("_build_site") == _site)]
		print(diag)
	match _phase:
		0:
			_tick_constructing()
		1:
			_tick_built()
		2:
			_tick_rally()
		3:
			_tick_spawned()
		4:
			_tick_walking()
		_:
			_finish()
	if not _done and _frames > 8000:
		_ok("8000 帧预算内跑完全流程", false, "卡在第 %d 阶段" % _phase)
		_finish()
	return _done


## 阶段 0：等农民走到工地、进度从 0 涨起来
func _tick_constructing() -> void:
	if _site == null or not is_instance_valid(_site):
		_finish()
		return
	var pr: float = float(_site.get("progress"))
	if not _saw_working and pr > 0.01:
		_saw_working = true
		_ok("农民走到工地并开始施工（进度已起）", pr > 0.0 and pr < 1.0, "进度 %.2f" % pr)
		# ★ 2026-11-07 兽族苦工口径：干活的农民应该是**钻进工地里**的
		#   （模型隐藏、没有体积、不可被索敌），而不是站在墙外抡锤。
		var inside: int = 0
		var hidden: int = 0
		for w in _crew:
			if w == null or not is_instance_valid(w):
				continue
			if w.has_method("is_inside_build") and bool(w.call("is_inside_build")):
				inside += 1
			var v = w.get("visual")
			if v != null and is_instance_valid(v) and not bool(v.get("visible")):
				hidden += 1
		# ⚠ 这里以前是同一段循环写了两遍（hidden 被数成 8/4，常红）。
		_ok("农民钻进工地内部（模型隐藏、不参与碰撞）",
				inside == _crew.size() and hidden == _crew.size(),
				"内部 %d/%d，隐藏 %d/%d" % [inside, _crew.size(), hidden, _crew.size()])
	if bool(_site.get("is_constructed")) or pr >= 1.0:
		_next_phase(1)
	elif _phase_frames > 1200:
		_ok("兵营能在 1200 帧内完工", false, "卡在进度 %.2f" % pr)
		_next_phase(1)


## 阶段 1：完工校验
func _tick_built() -> void:
	var pr: float = float(_site.get("progress"))
	var built: bool = bool(_site.get("is_constructed"))
	_ok("兵营进度 0 → 1 且 is_constructed=true", built and is_equal_approx(pr, 1.0),
		"progress=%.2f is_constructed=%s（耗时 %d 帧）" % [pr, str(built), _frames])
	var hp: float = float(_site.get("hp"))
	var max_hp: float = float(_bdef.get("max_hp"))
	_ok("完工后血量补满", hp >= max_hp * 0.95, "hp %.0f / %.0f" % [hp, max_hp])
	var left: int = 0
	for w in _crew:
		if w != null and is_instance_valid(w) and int(w.get("order")) != ORDER_BUILD:
			left += 1
	_ok("完工后农民自动退出建造", left >= 1, "%d / %d 已退出" % [left, _crew.size()])
	_next_phase(2)


## 阶段 2：集结点三接口 + 地面小旗 + 排一个农民
func _tick_rally() -> void:
	var th := _find_building(TOWNHALL)
	if th == null:
		_ok("找到大本营", false)
		_finish()
		return

	var entered: bool = bool(_cmd.call("request_set_rally", th))
	_ok("request_set_rally 进入等待落点状态", entered and bool(_cmd.call("is_rally_pending")),
		"is_rally_pending=%s" % str(bool(_cmd.call("is_rally_pending"))))

	_rally_point = _level.call("walkable_pos", th.global_position + Vector3(0.0, 0.0, 11.0))
	_cmd.call("_place_rally", _rally_point)
	var flag: Node = th.get_node_or_null("集结点旗")
	_ok("点落点后地面出现集结点小旗",
		bool(th.get("has_rally")) and flag != null and (flag as Node3D).visible,
		"旗节点=%s 位置=(%.1f,%.1f)" % [str(flag != null), float(th.get("rally_point").x), float(th.get("rally_point").z)])

	var cancelled: bool = bool(_cmd.call("cancel_rally"))
	var flag_visible: bool = flag != null and is_instance_valid(flag) and (flag as Node3D).visible
	_ok("cancel_rally 拔掉集结点并藏旗",
		cancelled and not bool(th.get("has_rally")) and not flag_visible)

	# 重新设一个（这次要用来观察出兵）
	_cmd.call("request_set_rally", th)
	_cmd.call("_place_rally", _rally_point)
	_before_units = (_faction.get("units") as Array).duplicate()
	var queued: bool = bool(th.call("queue_train", PEASANT))
	_ok("大本营开始训练农民", queued, "队列 %d 个" % int(th.call("train_count")))
	_next_phase(3)


## 阶段 3：等训练完成、新农民出现
func _tick_spawned() -> void:
	for u in _faction.get("units"):
		if u == null or not is_instance_valid(u) or _before_units.has(u):
			continue
		var d = u.get("def")
		if d == null or String(d.get("id")) != String(PEASANT):
			continue
		_newbie = u
		break
	if _newbie != null:
		_dist0 = _flat(_newbie.global_position, _rally_point)
		_ok("训练完成，新农民出现在出兵点", true,
			"位置 (%.1f, %.1f)，距集结点 %.1fm，当前指令 order=%d" % [
				_newbie.global_position.x, _newbie.global_position.z, _dist0, int(_newbie.get("order"))])
		_walk_frames = 0
		_next_phase(4)
	elif _phase_frames > 1200:
		_ok("新农民在 1200 帧内训练完成", false, "队列 %d" % _faction.call("count_units", PEASANT))
		_finish()


## 阶段 4：观察新农民是否朝集结点走
func _tick_walking() -> void:
	_walk_frames += 1
	if _walk_frames < 120:
		return
	_dist1 = _flat(_newbie.global_position, _rally_point)
	_ok("训练出的农民朝集结点走", _dist1 < _dist0 - 3.0,
		"距集结点 %.1fm → %.1fm（%d 帧）" % [_dist0, _dist1, _walk_frames])
	_ok("最终站到集结点附近", _dist1 < 3.5, "最终 %.1fm" % _dist1)
	_finish()


func _flat(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return sqrt(dx * dx + dz * dz)


func _next_phase(p: int) -> void:
	_phase = p
	_phase_frames = 0


# ===========================================================================
# 汇总
# ===========================================================================

func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])


func _finish() -> void:
	if _done:
		return
	_done = true
	print("-------------------------------")
	for l in _lines:
		print(l)
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)