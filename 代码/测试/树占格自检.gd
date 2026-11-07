extends SceneTree
## **树占格自检**：证明"挡格口径"在 编辑器校验 / 游戏内寻路 / 砍树释放 三处完全一致。
##
## 运行（★ 不要加 --import）：
##   godot --headless --path . --script 代码/测试/树占格自检.gd
##
## 覆盖（对应 Lead 给的三条硬断言）：
##   1. 掩码一致：`MapLoader.build_walkable_mask(主场景地图, false)` 与真关卡的
##      `pathfinder._walk` 逐格相同；差值只能来自 `_prepare_walkability` 的坡度过滤，
##      且**不能有任何一格是"道具占格被坡度过滤以外的东西打开"**。
##      另附：编辑器口径（include_buildings=true）与游戏口径只差建筑占地。
##   2. 没有"可走但被树占"的格：随便抽 200 个可走格心，到任一棵树心的距离必须 > 树半径。
##   3. 砍树释放精确：放开的格子 ⊆ 这棵树自己的格子；该树的格子（没被别的道具/地形占的）
##      必须全部恢复可走；别的格子一格都不许变。
##
## ★ 为什么满篇 call()/get()：`--script` 模式下主循环被本脚本接管，
##   autoload 的全局标识符在本文件解析时还没注册（实测 Identifier not found: Game）。
##   所以这里只 load() + 鸭子调用；跑的还是**真地图、真关卡、真寻路网格**。

const LEVEL_SCRIPT := "res://代码/核心/关卡.gd"
const LOADER_SCRIPT := "res://代码/地图核心/地图加载器.gd"
const RULES_SCRIPT := "res://代码/寻路/占格规则.gd"
const MAP_PATH := "res://地图/主场景地图.tres"

## MapObject.Category
const CAT_BUILDING := 1
const CAT_RESOURCE := 3

var _pass: int = 0
var _fail: int = 0
var _lines: Array[String] = []
var _done: bool = false
var _booted: bool = false
var _frames: int = 0

var _game: Node = null
var _cfg: Node = null
var _level: Node3D = null
var _pf: Object = null
var _def: Object = null
var _loader: Object = null
var _rules: Object = null
var _w: int = 0
var _half: float = 0.0
var _tree_r: float = 0.95
var _mine_cells := Vector2i(4, 4)
var _walk0: PackedByteArray = PackedByteArray()


func _initialize() -> void:
	print("========== 树占格自检 ==========")


func _process(_delta: float) -> bool:
	if _done:
		return true
	if not _booted:
		_booted = true
		_boot()
		return false
	_frames += 1
	if _frames > 4:
		_finish()
		return true
	return false


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])


func _boot() -> void:
	_game = root.get_node_or_null("Game")
	_cfg = root.get_node_or_null("Cfg")
	if _game == null or _cfg == null:
		_fail += 1
		_lines.append("  ✗ 取不到 Game / Cfg 自动加载")
		_finish()
		return
	_loader = load(LOADER_SCRIPT).new()
	var rule_script: GDScript = load(RULES_SCRIPT)
	_rules = rule_script.new()
	var consts: Dictionary = rule_script.get_script_constant_map()
	_tree_r = float(consts.get("TREE_RADIUS", 0.95))
	_mine_cells = consts.get("MINE_CELLS", Vector2i(4, 4))
	_def = load(MAP_PATH)
	if _def == null:
		_fail += 1
		_lines.append("  ✗ 加载不到 %s" % MAP_PATH)
		_finish()
		return
	_game.call("reset")
	_game.call("setup_factions")
	_level = load(LEVEL_SCRIPT).new()
	root.add_child(_level)
	_level.call("build_from_map_def", _def)
	_level.call("spawn_props")
	_game.set("level", _level)
	_pf = _level.get("pathfinder")
	if _pf == null:
		_fail += 1
		_lines.append("  ✗ 关卡没有寻路器")
		_finish()
		return
	_w = maxi(8, int(_def.get("size")))
	_half = float(_w) * 0.5
	_walk0 = (_level.get("map_data").get("walkable") as PackedByteArray).duplicate()

	_test_mask_parity()
	_test_no_tree_on_walkable()
	_test_tree_release()


# ===========================================================================
# 1. 掩码一致
# ===========================================================================

func _test_mask_parity() -> void:
	var raw: PackedByteArray = _loader.call("build_walkable_mask", _def, false)
	var info: Dictionary = _level.get("_walk_info")
	var slope_blocked: int = int(info.get("blocked_by_slope", 0))
	var pf_walk: PackedByteArray = _pf.get("_walk")

	_ok("掩码尺寸 = 关卡网格尺寸", raw.size() == _walk0.size() and raw.size() == _w * _w,
		"%d / %d / %d²" % [raw.size(), _walk0.size(), _w])
	var same: bool = pf_walk == _walk0
	_ok("寻路器网格 == 关卡最终 walkable（逐格相同）", same,
		"hash %d vs %d" % [hash(pf_walk), hash(_walk0)])

	var raw_n: int = _count_nonzero(raw)
	var walk_n: int = _count_nonzero(_walk0)
	_ok("可走格数差 = 被坡度过滤掉的格数", raw_n - walk_n == slope_blocked,
		"raw=%d 关卡=%d 差=%d 坡度过滤=%d" % [raw_n, walk_n, raw_n - walk_n, slope_blocked])

	# 坡度过滤只许"关门"，不许"开门"：raw 里是 0 的格，关卡里必须还是 0
	var opened: int = 0
	for i in range(mini(raw.size(), _walk0.size())):
		if raw[i] == 0 and _walk0[i] != 0:
			opened += 1
	_ok("没有任何道具占格被反向打开（raw=0 → 关卡=1 的格数必须为 0）", opened == 0, "%d 格" % opened)

	# 编辑器校验口径（含建筑）与游戏口径只差建筑占地
	var with_b: PackedByteArray = _loader.call("build_walkable_mask", _def, true)
	var building_cells := _collect_cells(CAT_BUILDING)
	var extra: int = 0
	var wrong: int = 0
	for i in range(mini(with_b.size(), raw.size())):
		if with_b[i] == 0 and raw[i] != 0:
			extra += 1
			if not building_cells.has(i):
				wrong += 1
	_ok("编辑器口径(含建筑) 与 游戏口径 只差建筑占地", wrong == 0,
		"多挡 %d 格，其中不属于建筑的 %d 格" % [extra, wrong])
	print("  · 口径统计：树 %d 棵 / 矿 %d 座 / 建筑 %d 座 / 道具总占格 %d 格 / 树平均 %.2f 格/棵" % [
		_count_kind("tree"), _count_kind("goldmine"), _count_kind("building", CAT_BUILDING),
		_collect_union_cells().size(),
		float(_collect_tree_cells().size()) / maxf(1.0, float(_count_kind("tree")))])


func _count_nonzero(a: PackedByteArray) -> int:
	var c: int = 0
	for v in a:
		if v != 0:
			c += 1
	return c


func _count_kind(prefix: String, cat: int = CAT_RESOURCE) -> int:
	var n: int = 0
	for o in _def.get("objects"):
		if o == null or int(o.get("category")) != cat:
			continue
		if prefix == "building" or String(o.get("type_id")).begins_with(prefix):
			n += 1
	return n


## 全部对象的占格（按 category 过滤；cat < 0 = 全部）
func _collect_cells(cat: int) -> Dictionary:
	var out: Dictionary = {}
	for o in _def.get("objects"):
		if o == null:
			continue
		if cat >= 0 and int(o.get("category")) != cat:
			continue
		var cells: PackedInt32Array = _loader.call("object_block_cells", o, _w, true)
		for i in cells:
			out[i] = true
	return out


## 全部树的占格（cell 索引 → 树序号，仅用于统计）
func _collect_tree_cells() -> Dictionary:
	var out: Dictionary = {}
	var idx: int = 0
	for o in _def.get("objects"):
		if o == null or int(o.get("category")) != CAT_RESOURCE:
			continue
		if not String(o.get("type_id")).begins_with("tree"):
			continue
		var p: Vector3 = o.get("position")
		var cells: PackedInt32Array = _rules.call("tree_cells", _w, Vector2(p.x, p.z))
		for i in cells:
			if not out.has(i):
				out[i] = idx
		idx += 1
	return out


## 所有道具占格的并集（树 / 矿 / 岩石 / 建筑），只用于打印规模
func _collect_union_cells() -> Dictionary:
	var out: Dictionary = {}
	for o in _def.get("objects"):
		if o == null:
			continue
		for i in _loader.call("object_block_cells", o, _w, true):
			out[i] = true
	for rk in _level.get("map_data").get("rocks"):
		for i in _rules.call("rock_cells", _w, rk["pos"], float(rk.get("scale", 1.0))):
			out[i] = true
	return out


# ===========================================================================
# 2. 可走格上没有树
# ===========================================================================

func _test_no_tree_on_walkable() -> void:
	var r: float = _tree_r
	var trees: Array = []
	for o in _def.get("objects"):
		if o == null or int(o.get("category")) != CAT_RESOURCE:
			continue
		if not String(o.get("type_id")).begins_with("tree"):
			continue
		var p: Vector3 = o.get("position")
		trees.append(Vector2(p.x, p.z))
	var walk_cells: Array = []
	for z in range(_w):
		for x in range(_w):
			if _walk0[z * _w + x] != 0:
				walk_cells.append(z * _w + x)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261107
	var bad: int = 0
	var checked: int = 0
	var limit: int = mini(200, walk_cells.size())
	for k in range(limit):
		var i: int = int(walk_cells[rng.randi_range(0, walk_cells.size() - 1)])
		var x: int = i % _w
		var z: int = i / _w
		var c := Vector2(-_half + float(x) + 0.5, -_half + float(z) + 0.5)
		checked += 1
		for t in trees:
			if c.distance_to(t) <= r:
				bad += 1
				break
	_ok("抽查 %d 个可走格心：没有一个落在树半径 %.2fm 内" % [checked, r], bad == 0,
		"违规 %d 个（共 %d 棵/ %d 可走格）" % [bad, trees.size(), walk_cells.size()])


# ===========================================================================
# 3. 砍树释放
# ===========================================================================

func _test_tree_release() -> void:
	var md: Object = _level.get("map_data")
	var trees_pos: Array = md.get("trees")
	var harvest: Array = _level.get("_harvestables")
	# 金矿先刷，树按 map_data.trees 顺序跟在后面
	var mine_n: int = (md.get("mines") as Array).size()
	if trees_pos.is_empty() or harvest.size() < mine_n + 1:
		_ok("找得到树节点", false, "树 %d / 可采集物 %d" % [trees_pos.size(), harvest.size()])
		return
	var ti: int = 0
	var node: Node3D = harvest[mine_n + ti] as Node3D
	var tp: Vector2 = trees_pos[ti]
	_ok("树节点的 XZ 与地图数据一致",
		absf(node.global_position.x - tp.x) < 0.01 and absf(node.global_position.z - tp.y) < 0.01,
		"节点(%.2f,%.2f) 数据(%.2f,%.2f)" % [node.global_position.x, node.global_position.z, tp.x, tp.y])

	var cells: PackedInt32Array = _rules.call("tree_cells", _w, tp)
	_ok("这棵树在网格上挡了 %d 格（0.95m 精确圆）" % cells.size(), cells.size() > 0)

	# 别的道具/地形是否也占这格
	var others: Dictionary = {}
	for k in range(trees_pos.size()):
		if k == ti:
			continue
		var q: Vector2 = trees_pos[k]
		for i in _rules.call("tree_cells", _w, q):
			others[i] = true
	for q in md.get("mines"):
		for i in _rules.call("rect_cells", _w, q, _mine_cells.x, _mine_cells.y):
			others[i] = true
	for rk in md.get("rocks"):
		for i in _rules.call("rock_cells", _w, rk["pos"], float(rk.get("scale", 1.0))):
			others[i] = true

	var expect_open: Dictionary = {}
	for i in cells:
		var x: int = i % _w
		var z: int = i / _w
		var c := Vector2(-_half + float(x) + 0.5, -_half + float(z) + 0.5)
		if others.has(i) or _is_terrain_blocked(c):
			continue
		expect_open[i] = true

	var before: PackedByteArray = (_pf.get("_walk") as PackedByteArray).duplicate()
	var blocked_before: int = 0
	for i in cells:
		if before[i] == 0:
			blocked_before += 1
	_ok("砍之前这棵树自己的格子都是挡着的", blocked_before == cells.size(),
		"%d / %d 格" % [blocked_before, cells.size()])

	# 真砍：consume → _deplete → _free_footprint（走 RtsWorld.release_prop）
	node.call("consume", 999999)
	var after: PackedByteArray = _pf.get("_walk")

	var changed: Dictionary = {}
	for i in range(mini(before.size(), after.size())):
		if before[i] != after[i]:
			changed[i] = true
	var over: int = 0
	for i in changed:
		if not cells.has(int(i)):
			over += 1
	_ok("释放只影响这棵树自己的格子（没有误开邻树/岩石/建筑）", over == 0,
		"变了 %d 格，其中不属于本树的 %d 格" % [changed.size(), over])

	var missed: int = 0
	for i in expect_open:
		var idx: int = int(i)
		if idx < after.size() and after[idx] == 0:
			missed += 1
	_ok("该恢复的格子全部恢复可走（不留隐形墙）", missed == 0,
		"应恢复 %d 格，仍挡着 %d 格" % [expect_open.size(), missed])
	_ok("放开格数 = 应恢复格数", changed.size() == expect_open.size(),
		"实放 %d / 应放 %d" % [changed.size(), expect_open.size()])

	# 清理：把树的节点删掉，避免 tween 在退出时报警
	if is_instance_valid(node):
		node.queue_free()


func _is_terrain_blocked(c: Vector2) -> bool:
	if not bool(_def.call("in_bounds", c, float(_def.get("edge_keep_out")))):
		return true
	if float(_def.call("slope_degrees_at", c.x, c.y, 0.75)) > 40.0:
		return true
	if bool(_def.call("is_water_at", c)):
		return true
	return false


func _finish() -> void:
	if _done:
		return
	_done = true
	print("-------------------------------")
	for l in _lines:
		print(l)
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)
