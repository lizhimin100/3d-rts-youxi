extends SceneTree
## **表现自检**：工地生长 / 单位死亡 / 建筑倒塌三件事的无头验证（SLEDGE）。
##
## 运行（★ 不要加 --import）：
##   godot --headless --path . --script 代码/测试/表现自检.gd
##
## 顺带出四张实机阶段图（窗口模式才拍得到；无头下自动跳过）：
##   godot --path . --resolution 1600x900 --script 代码/测试/表现自检.gd -- --shots=user://present_qc
##
## 覆盖：
##   1. 工地节点真的挂上了（地基 / 料堆 / 脚手架 ≥ 25 个网格）
##   2. 进度 0 时建筑被剖切到地面（不会一放下就是整栋房子）
##   3. 进度 35% / 90%：剖切高度、脚手架高度、横杆数量同步上涨
##   4. 锤击按"工地"节流（3 个农民同时干也只有一条节奏）
##   5. 完工：剖切材质还原、工地 1.5s 内自毁
##   6. 单位死亡：unit_died 只发一次、尸体留一会儿、下沉后释放
##   7. 建筑死亡：占地**立刻**清、unit_died 立刻发、训练队列清空
##   8. 建筑倒塌：进入倾斜、旋转真的动了、落地后生成"废墟"、废墟会自动淡出
##   9. 批量死亡节流：一次死 8 个，大特效不超过 4 次
##  10. 受击：掉血会加裂缝
##
## ★ 满篇 call()/get() 的原因见 建造自检.gd 开头：--script 模式下 autoload 的全局标识符
##   在本文件解析时还没注册，只能 load() + 鸭子调用。跑的仍是真关卡、真单位、真寻路网格。

const LEVEL_SCRIPT := "res://代码/核心/关卡.gd"
const CMD_SCRIPT := "res://代码/操作/指令系统.gd"
const BUILD_FX := "res://代码/美术/建造表现.gd"
const ARTKIT := "res://代码/美术/美术接口.gd"

const BARRACKS := &"barracks"
const PEASANT := &"peasant"
const FOOTMAN := &"footman"

var _game: Node = null
var _cfg: Node = null
var _level: Node3D = null
var _cmd: Node = null
var _pf: Object = null
var _faction: Object = null
var _bdef: Object = null
var _cam: Camera3D = null

var _anchor := Vector3.ZERO
var _site: Node3D = null
var _site_node: Node3D = null
var _crew: Array = []
var _barracks: Node3D = null

var _pass: int = 0
var _fail: int = 0
var _lines: Array[String] = []

var _phase: int = 0
var _build_step: int = 0
var _timer: float = 0.0
var _frames: int = 0
var _booted: bool = false
var _done: bool = false

var _died: int = 0
var _dying_unit: Node3D = null
var _deaths_at_kill: int = 0
var _rot_before := Vector3.ZERO
var _walk_before: bool = false
var _walk_after: bool = false
var _dead_pos := Vector3.ZERO
var _batch: Array = []

## 截图（--shots=<目录> 才启用）
var _shot_dir: String = ""
var _shot_pending: String = ""
var _shot_wait: int = 0
var _shots: Array[String] = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var s: String = String(a)
		if s.begins_with("--shots="):
			_shot_dir = s.substr(8)
	if not _shot_dir.is_empty():
		if _shot_dir.begins_with("user://") or _shot_dir.begins_with("res://"):
			_shot_dir = ProjectSettings.globalize_path(_shot_dir)
		elif not _shot_dir.is_absolute_path():
			_shot_dir = ProjectSettings.globalize_path("res://").path_join(_shot_dir)
		DirAccess.make_dir_recursive_absolute(_shot_dir)
		print("========== 表现自检（含阶段截图） ==========")
	else:
		print("========== 表现自检（工地 / 死亡 / 倒塌） ==========")


func _boot_once() -> void:
	_booted = true
	Engine.time_scale = 1.4 if not _shot_dir.is_empty() else 3.0
	_boot_world()
	_test_site()
	Engine.time_scale = 1.4 if not _shot_dir.is_empty() else 3.0
	_next(0)


func _boot_world() -> void:
	_game = root.get_node("Game")
	_cfg = root.get_node("Cfg")
	_game.call("reset")
	_game.set("difficulty_index", 0)
	_game.call("setup_factions")
	_game.connect("unit_died", _on_unit_died)

	_level = load(LEVEL_SCRIPT).new()
	root.add_child(_level)
	_level.call("build")
	_level.call("spawn_props")
	_game.set("level", _level)
	_game.set("phase", 1)
	_faction = _game.get("player_faction")
	_faction.call("add_res", 20000, 20000)
	_pf = _level.get("pathfinder")
	_cmd = load(CMD_SCRIPT).new()

	var base: Vector3 = _level.call("base_center", _faction)
	_game.call("spawn_unit", _faction, &"townhall", _level.call("snap_grid", base), _level)

	_bdef = _cfg.call("unit", BARRACKS)
	_anchor = _find_anchor(base + Vector3(0.0, 0.0, 15.0), _bdef, 30)
	_crew = _spawn_crew(_anchor, 3)
	_site = _cmd.call("place_building", BARRACKS, _anchor, _crew)
	if not _shot_dir.is_empty():
		_setup_view()
	print("  · 世界：地图 %.0fm，工地 (%.1f, %.1f)，农民 %d 个" % [
		float(_level.get("world_size")), _anchor.x, _anchor.z, _crew.size()])


## 截图模式：借关卡地形 + ANVIL 的环境，摆一台固定机位的相机
func _setup_view() -> void:
	var ak: Script = load(ARTKIT)
	if ak != null:
		var env: Environment = ak.call("load_environment")
		if env != null:
			var we := WorldEnvironment.new()
			we.environment = env
			root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.95, -0.62, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(-0.4, 2.2, 0.0)
	fill.light_energy = 0.35
	fill.light_color = Color(0.62, 0.74, 1.0)
	root.add_child(fill)
	_cam = Camera3D.new()
	_cam.fov = 42.0
	root.add_child(_cam)
	_cam.current = true
	_focus_on(_anchor, 0.95)


## 把相机摆到某个点上方 3/4 视角（截图用）；dist 越大拉得越远
func _focus_on(p: Vector3, dist: float = 1.0) -> void:
	if _cam == null:
		return
	var target: Vector3 = p + Vector3(0.0, 1.5, 0.0)
	_cam.global_position = target + Vector3(7.6, 6.4, 10.2) * dist
	_cam.look_at(target)


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


func _spawn_crew(anchor: Vector3, count: int) -> Array:
	var out: Array = []
	for i in range(count):
		var ang: float = TAU * float(i) / float(maxi(count, 1))
		var p := anchor + Vector3(cos(ang) * 4.5, 0.0, sin(ang) * 4.5)
		var u: Node3D = _game.call("spawn_unit", _faction, PEASANT, _level.call("walkable_pos", p), _level)
		if u != null:
			out.append(u)
	return out


# ===========================================================================
# 1~5. 工地
# ===========================================================================

func _test_site() -> void:
	if _site == null or not is_instance_valid(_site):
		_ok("工地已立起", false, "place_building 返回 null")
		return
	_site_node = _site.get_node_or_null("工地")
	var meshes: int = _count_meshes(_site_node)
	_ok("工地节点挂上了（地基 / 料堆 / 脚手架）", _site_node != null and meshes >= 25,
		"工地网格 %d 个" % meshes)
	if _site_node == null:
		return

	_site_node.call("set_progress", 0.0)
	var clip0: float = float(_site_node.call("cut_height"))
	var post0: float = float(_site_node.call("post_height"))
	var height: float = float(_bdef.get("height"))
	_ok("进度 0：建筑被裁到近地面（clip 或纵向压缩兜底）", clip0 >= 0.0 and clip0 < 0.25,
		"clip=%.2f（层高 %.1f）" % [clip0, height])
	_ok("进度 0：脚手架只到脚踝", post0 <= 0.5, "立柱 %.2f m" % post0)
	_ok("进度 0：一根横杆都不该出现", int(_site_node.call("visible_rails")) == 0,
		"可见 %d 根" % int(_site_node.call("visible_rails")))

	_site_node.call("set_progress", 0.35)
	var clip1: float = float(_site_node.call("cut_height"))
	var post1: float = float(_site_node.call("post_height"))
	var rails1: int = int(_site_node.call("visible_rails"))
	_ok("进度 35%：可见高度到一层楼", clip1 > height * 0.30 and clip1 < height * 0.45,
		"clip=%.2f（应 ≈%.2f）" % [clip1, height * 0.35 + 0.06])
	_ok("进度 35%：脚手架跟着长高", post1 > post0 + 0.8, "%.2f m → %.2f m" % [post0, post1])
	_ok("进度 35%：横杆逐层出现", rails1 >= 4, "可见 %d 根" % rails1)

	_site_node.call("set_progress", 0.90)
	var rails2: int = int(_site_node.call("visible_rails"))
	_ok("进度 90%：横杆基本到顶", rails2 > rails1, "%d 根 → %d 根" % [rails1, rails2])

	# 锤击节流：同一帧连点 5 次只成功 1 次
	var hits: int = 0
	for i in 5:
		if bool(_site_node.call("strike", Vector3.ZERO)):
			hits += 1
	_ok("锤击按工地节流（连点 5 次只出 1 次）", hits == 1, "实际 %d 次" % hits)

	# 截图用：停在"盖到一层半"的样子（农民先停手，否则他们每帧会把进度推回 0）
	_site_node.call("set_progress", 0.42)
	_site.set("progress", 0.42)
	_site.set("_last_progress", 0.42)
	if not _shot_dir.is_empty():
		for w in _crew:
			if w != null and is_instance_valid(w):
				w.call("order_stop")
		_focus_on(_anchor)


# ===========================================================================
# 每帧
# ===========================================================================

func _process(delta: float) -> bool:
	if _done:
		return true
	if not _booted:
		_boot_once()
		return false
	_frames += 1
	_timer += delta
	_tick_shot()
	match _phase:
		0:
			_tick_build_stage()
		1:
			_tick_site_free()
		2:
			_tick_unit_death()
		3:
			_tick_corpse()
		4:
			_tick_building_death()
		5:
			_tick_collapse()
		6:
			_tick_ruins()
		7:
			_tick_batch()
		_:
			_finish()
	if not _done and _frames > 30000:
		_ok("30000 帧预算内跑完全流程", false, "卡在第 %d 阶段" % _phase)
		_finish()
	return _done


## 阶段 0：先给"建造中"拍一张，再快进完工拍第二张
func _tick_build_stage() -> void:
	if _build_step == 0:
		if not _shot_dir.is_empty() and _site_node != null and is_instance_valid(_site_node):
			_site_node.call("set_progress", 0.42)
		# 截图模式多等 2 秒：让刚才 strike() 打的木屑粒子散干净，不然半空中挂着一堆方块
		if _timer >= (2.0 if not _shot_dir.is_empty() else 0.25):
			_request_shot("01_建造中")
			_build_step = 1
			_timer = 0.0
		return
	if _build_step == 1:
		if _timer < 0.9:
			return
		# 快进到完工（真农民太慢；建造自检已经覆盖了"农民慢慢盖"的链路）
		var guard: int = 0
		while not bool(_site.get("is_constructed")) and guard < 20:
			_site.call("advance_construction", 10.0, null)
			guard += 1
		_ok("工地能被推进到完工", bool(_site.get("is_constructed")),
			"progress=%.2f" % float(_site.get("progress")))
		var clip_done: float = float(_site_node.call("cut_height"))
		_ok("完工：裁切已还原（不再剖/不再压）", clip_done <= -1.5,
			"clip=%.2f（-2 = 已经没有剖切材质）" % clip_done)
		_request_shot("02_完工", 22)
		_build_step = 2
		_timer = 0.0
		return
	# _build_step == 2：等工地自毁
	if _timer >= 2.8:
		_ok("完工后工地节点自动释放（1.5s 内）", not is_instance_valid(_site_node),
			"仍存在" if is_instance_valid(_site_node) else "已释放")
		_next(1)


## 阶段 1：杀一个步兵看死亡链路
func _tick_site_free() -> void:
	if _timer < 0.35:
		return
	_dying_unit = _game.call("spawn_unit", _faction, FOOTMAN,
			_level.call("walkable_pos", _anchor + Vector3(6.0, 0.0, -4.0)), _level)
	# 受击反馈：先打 10 点，检查"暖色 / 低强度 / 不是整片白"
	if _dying_unit != null:
		var vis: Node = _dying_unit.get("visual")
		_dying_unit.call("take_damage", 10.0, 0, _site)
		var dbg: Dictionary = vis.call("flash_debug") if vis != null else {}
		var uc: Color = dbg.get("color", Color.WHITE)
		_ok("单位受击是暖橙低强度脉冲（不是白闪）",
			not bool(dbg.get("white", true)) and float(dbg.get("peak", 1.0)) <= 0.20 \
				and bool(dbg.get("blend_add", false)) and uc.r > uc.g and uc.g > uc.b,
			"color=(%.2f, %.2f, %.2f) peak=%.2f add=%s" % [uc.r, uc.g, uc.b,
				float(dbg.get("peak", 0.0)), str(dbg.get("blend_add", false))])
	_deaths_at_kill = _died
	_dying_unit.call("take_damage", 99999.0, 0, null)
	_ok("单位死亡立刻发 unit_died（只一次）", _died == _deaths_at_kill + 1,
		"信号计数 %d" % (_died - _deaths_at_kill))
	_ok("死亡当帧 state=DEAD", int(_dying_unit.get("state")) == 5,
		"state=%d" % int(_dying_unit.get("state")))
	_next(2)


## 阶段 2：尸体先留着
func _tick_unit_death() -> void:
	if _timer < 1.0:
		return
	_ok("尸体不会原地消失（1s 后仍在场上）", is_instance_valid(_dying_unit),
		"存在" if is_instance_valid(_dying_unit) else "已消失")
	_ok("死亡只发了一次信号", _died == _deaths_at_kill + 1, "计数 %d" % (_died - _deaths_at_kill))
	_next(3)


## 阶段 3：尸体沉完释放，然后拿一栋"已完工"的兵营做倒塌测试
func _tick_corpse() -> void:
	if _timer < 5.0:
		return
	_ok("尸体停留 + 下沉后释放", not is_instance_valid(_dying_unit),
		"仍存在" if is_instance_valid(_dying_unit) else "已释放")

	_barracks = _game.call("spawn_unit", _faction, BARRACKS,
			_level.call("walkable_pos", _anchor + Vector3(-13.0, 0.0, 0.0)), _level)
	if _barracks != null:
		_focus_on(_barracks.global_position, 1.5)
	if _barracks == null:
		_ok("造一栋完工兵营", false, "spawn 失败")
		_next(6)
		return
	# 建筑受击：不许整栋泛白；只靠尘土/裂缝/顿挫
	var bvis: Node = _barracks.get("visual")
	_barracks.call("take_damage", 5.0, 0, null)
	var bdbg: Dictionary = bvis.call("flash_debug") if bvis != null else {}
	_ok("建筑受击不做整面墙泛白（无 overlay 脉冲）",
		bool(bdbg.get("building_no_overlay", false)) and not bool(bdbg.get("white", true)),
		"peak=%.2f white=%s" % [float(bdbg.get("peak", -1.0)), str(bdbg.get("white", true))])
	# 排一个兵，等会儿验证"死的时候队列被清"
	_barracks.call("queue_train", PEASANT)
	var cell: Vector2i = _pf.call("world_to_cell", _barracks.global_position)
	_walk_before = bool(_level.call("is_walkable_grid", cell))
	# 打到 50% 血：验裂缝
	_barracks.call("take_damage", float(_barracks.get("hp")) * 0.5, 0, null)
	var cracks: int = int(_barracks.get("_crack_count"))
	_ok("受击掉血会加裂缝", cracks >= 1, "裂缝 %d 条" % cracks)

	_deaths_at_kill = _died
	_dead_pos = _barracks.global_position
	_rot_before = _barracks.rotation
	_barracks.call("take_damage", 999999.0, 0, null)
	_walk_after = bool(_level.call("is_walkable_grid", cell))
	_ok("建筑一死：占地立刻清空（不等沉完）", _walk_before == false and _walk_after == true,
		"死前可走=%s 死后可走=%s" % [str(_walk_before), str(_walk_after)])
	_ok("建筑一死：unit_died 立刻发", _died == _deaths_at_kill + 1, "信号 +%d" % (_died - _deaths_at_kill))
	_ok("建筑一死：训练队列被清空", int(_barracks.call("train_count")) == 0,
		"队列 %d" % int(_barracks.call("train_count")))
	_next(4)


## 阶段 4：进入倒塌
func _tick_building_death() -> void:
	if _timer < 0.30:
		return
	_ok("建筑进入倒塌状态", bool(_barracks.get("_collapsing")),
		"_collapsing=%s" % str(bool(_barracks.get("_collapsing"))))
	_next(5)


## 阶段 5：倒塌中（旋转真的动了）→ 截图 → 落地
func _tick_collapse() -> void:
	if _timer < 0.75:
		return
	if is_instance_valid(_barracks):
		_request_shot("03_倒塌")
	if _timer < 0.95:
		return
	if not is_instance_valid(_barracks):
		_next(6)
		return
	var moved: float = absf(_barracks.rotation.x - _rot_before.x) + absf(_barracks.rotation.z - _rot_before.z)
	_ok("倒塌：整栋楼真的倾斜了（不是整栋沉进地里）", moved > 0.15, "倾角变化 %.2f rad" % moved)
	_next(6)


## 阶段 6：建筑本体消失、废墟出现 → 截图
func _tick_ruins() -> void:
	if _timer < 2.2:
		return
	var n: int = _count_named("废墟")
	_ok("落地后留下废墟（断墙 / 瓦砾 / 焦木）", n > 0, "废墟节点 %d 个" % n)
	_focus_on(_dead_pos, 1.0)
	# ★ 只判"节点存在"抓不到沉默 bug：废墟可能已经全透明了，画面上只剩影子。
	#   这里必须落到网格级：至少一个 MeshInstance3D 可见、且透明度还没被拉起。
	var shown: int = _count_solid_ruins()
	_ok("废墟真的渲染得出来（不是只剩影子）", shown >= 8, "不透明网格 %d 个" % shown)
	_request_shot("04_废墟")
	_next(7)


## 阶段 7：废墟淡出 + 批量死亡节流
func _tick_batch() -> void:
	if _timer < 7.5:
		return
	_ok("废墟停留后自动淡出消失", _count_named("废墟") == 0,
		"还剩 %d 个" % _count_named("废墟"))

	# 批量死亡：同一帧杀 8 个，大特效最多 4 次
	var fx: Script = load(BUILD_FX)
	fx.call("reset_counters")
	_batch.clear()
	for i in 8:
		var p := _anchor + Vector3(-6.0 + float(i) * 1.2, 0.0, 8.0)
		var u: Node3D = _game.call("spawn_unit", _faction, FOOTMAN, _level.call("walkable_pos", p), _level)
		if u != null:
			_batch.append(u)
	for u in _batch:
		if is_instance_valid(u):
			u.call("take_damage", 99999.0, 0, null)
	var st: Dictionary = fx.call("stats")
	_ok("批量死亡：大特效被节流（8 个最多 4 次）", int(st["death"]) <= 4,
		"大特效 %d 次 / 节流掉 %d 次 / 死亡 %d 个" % [int(st["death"]), int(st["skipped"]), _batch.size()])
	_ok("批量死亡：每个都真的死了", _died >= _deaths_at_kill + 1 + _batch.size(),
		"累计信号 %d" % _died)
	_finish()


# ===========================================================================
# 截图
# ===========================================================================

func _request_shot(base_name: String, wait: int = 3) -> void:
	if _shot_dir.is_empty():
		return
	_shot_pending = base_name
	_shot_wait = maxi(wait, 1)


func _tick_shot() -> void:
	if _shot_pending.is_empty():
		return
	_shot_wait -= 1
	if _shot_wait > 0:
		return
	var name: String = _shot_pending
	_shot_pending = ""
	var img: Image = root.get_texture().get_image()
	if img == null or img.is_empty():
		print("  ! 截图失败：", name)
		return
	var path: String = _shot_dir.path_join(name + ".png")
	var err: int = img.save_png(path)
	if err == OK:
		_shots.append(path)
		print("  · 截图 → ", path, " (%dx%d)" % [img.get_width(), img.get_height()])
	else:
		print("  ! 截图保存失败：", path, " err=", err)


# ===========================================================================
# 杂项
# ===========================================================================

func _on_unit_died(_u: Node) -> void:
	_died += 1


func _count_meshes(n: Node) -> int:
	if n == null:
		return 0
	var count: int = 0
	var stack: Array = [n]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		if x is MeshInstance3D:
			count += 1
		for c in x.get_children():
			stack.append(c)
	return count


## 废墟里"可见且还没淡出"的网格数（transparency < 0.2）
func _count_solid_ruins() -> int:
	var count: int = 0
	for r in _ruins_roots():
		var stack: Array = [r]
		while not stack.is_empty():
			var x: Node = stack.pop_back()
			var mi := x as MeshInstance3D
			if mi != null:
				var tr: Variant = mi.get("transparency")
				if mi.visible and (tr == null or float(tr) < 0.2):
					count += 1
			for c in x.get_children():
				stack.append(c)
	return count


## 所有名字以"废墟"开头的根节点（不往它们的子树里再找根）
func _ruins_roots() -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		if String(x.name).begins_with("废墟"):
			out.append(x)
			continue
		for c in x.get_children():
			stack.append(c)
	return out


func _count_named(prefix: String) -> int:
	var count: int = 0
	var stack: Array = [root]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		if String(x.name).begins_with(prefix):
			count += 1
		for c in x.get_children():
			stack.append(c)
	return count


func _next(p: int) -> void:
	_phase = p
	_timer = 0.0


func _ok(n: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [n, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [n, detail])


func _finish() -> void:
	if _done:
		return
	_done = true
	Engine.time_scale = 1.0
	print("-------------------------------")
	for l in _lines:
		print(l)
	if not _shots.is_empty():
		print("截图：", ", ".join(_shots))
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)