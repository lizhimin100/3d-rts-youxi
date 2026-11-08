extends Node
## **野怪营地自检**：营地表 → 识别锚点 → 分帧刷怪 → 全灭补满 → camps() 计数。
##
## 启用（必须走主场景：营地依赖 Game / Cfg / 寻路 / 中立阵营这些运行时节点）：
##   godot --headless --path . --quit-after 900 -- --no-map --camp-test
## 结尾一行 `CAMPTEST {json}`，失败时退出码 1。
##
## 为什么这几条断言：
##   · "营地表 3 条" —— 少一条就是 .tres 没被扫到 / 字段名写错，表现是"地图上摆了营地但不刷怪"；
##   · "怪全在 team 0" —— 判据只有 team（`RtsFaction.team == 0` 才是中立敌对）。
##     掉到某个玩家队伍里，玩家就再也打不了它，而且肉眼完全看不出来；
##   · "全灭 → 补满" —— respawn 是这套系统唯一的定时逻辑，必须真跑一遍，
##     不能只检查配置字段（字段对、逻辑没接，是这类系统最常见的坏法）。

const CAMP_TABLE := preload("res://代码/配置/野怪营地表.gd")
const CAMP_SCRIPT := preload("res://代码/系统/野怪营地.gd")
## 野怪 id（和中立阵营的 CREEP_IDS 同口径；这里再写一份是为了"自检不依赖被测代码的常量"）
const CREEP_IDS: Array[String] = ["gnoll_warrior", "gnoll_scout"]

var _report: Dictionary = {}
var _checks: Array = []
var _ok: bool = true
## 被测锚点建筑
var _den: Node3D = null
## 被测营地系统节点
var _camps: Node3D = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _wait(0.4)

	# --- 1. 营地表：定义 + 反查命中 ---
	# 数量只做下限：玩家在编辑器里「新建」的营地卡会往里加（`camp_creep_den_1` 就是这么来的），
	# 写死 3 会让这条检查在"卡变多了"时假红。
	var defs: Array = CAMP_TABLE.all()
	_check(defs.size() >= 3, "营地表读到 ≥3 个定义（实 %d）" % defs.size())
	var summary: Array = []
	for d in defs:
		summary.append({
			"id": String(d.get("id")),
			"锚点": String(d.get("den_building")),
			"野怪": str(d.get("creeps")),
			"数量": str(d.get("counts")),
			"补满秒": float(d.get("respawn")),
		})
	_check(CAMP_TABLE.for_den(&"creep_den") != null, "for_den(creep_den) 命中")
	_check(CAMP_TABLE.for_den(&"watchtower") == null, "for_den(非营地建筑) 返回空")
	# 2026-11-07：逐实例 camp_id 的查找入口（编辑器「应用到选中锚点」就写这个）
	_check(CAMP_TABLE.by_id("camp_den") != null, "by_id(camp_den) 命中（逐实例配置入口）")
	_check(CAMP_TABLE.by_id("没有这个营地") == null, "by_id(未知 id) 返回空")

	# --- 2. 摆一座锚点建筑（模拟"玩家在编辑器里摆的"）---
	var neutral: RtsFaction = Game.neutral_faction
	_check(neutral != null, "中立阵营已建好")
	if neutral == null:
		_finish()
		return
	var den_def: UnitDef = Cfg.unit(&"creep_den")
	_check(den_def != null, "creep_den 已登记进单位表")
	if den_def == null:
		_finish()
		return
	# 摆在中央台地：离四家基地都远，不会和开局建筑抢地方；
	# 顺便让小地图上的营地图标落在圆盘中间，截图验收时看得清（不会被圆形边缘裁掉）。
	var pos: Vector3 = RtsWorld.walkable_pos(Vector3.ZERO)
	_den = Game.spawn_unit(neutral, &"creep_den", pos, Game.level)
	_check(_den != null, "中立锚点建筑生成成功")
	if _den == null:
		_finish()
		return
	if _den.has_method("set_constructed"):
		_den.call("set_constructed", true)
	if Game.level != null and Game.level.has_method("mark_footprint"):
		Game.level.call("mark_footprint", _den)

	# --- 3. 挂营地系统（复用主场景已经挂好的那个节点，验证真实接线）---
	_camps = _camp_system()
	_check(_camps != null, "营地系统节点存在")
	if _camps == null:
		_finish()
		return
	# ★ 自检要"开局就刷"才有得测：卡上的 `first_spawn_min` 是可以配到 120 分钟的
	#   （编辑器新建卡的默认值），那种营地**按设计**在开局几秒内就是空的 ——
	#   不把它拨到 0，下面"刷出 3 只"就会永远假红。改的是内存里的 Resource，
	#   不写回 .tres，跑完就没了。
	var test_def: Resource = CAMP_TABLE.for_den(&"creep_den")
	if test_def != null:
		test_def.set("first_spawn_min", 0.0)
		test_def.set("spawn_interval_min", 0.0)
	_camps.call("setup", neutral)
	_check(int(_camps.call("camp_count")) == 1, "识别到 1 座营地（实 %d）"
		% int(_camps.call("camp_count")))

	# --- 4. 分帧刷怪：等队列走完（3 只 ≈ 一拍 0.1s）---
	await _wait(1.0)
	var spawned: Array = _near_creeps(pos, 14.0)
	_check(spawned.size() == 3, "刷出 3 只野怪（实 %d）" % spawned.size())
	var all_neutral: bool = true
	for u in spawned:
		var f: RtsFaction = u.get("faction")
		if f == null or int(f.team) != 0:
			all_neutral = false
	_check(all_neutral, "刷出的野怪全部 faction.team == 0（中立敌对）")
	# 2026-11-07：营地归属跟锚点建筑走（把锚点摆成玩家 N，怪就替 N 守家）
	var camp_fac: RtsFaction = null
	for nd in get_tree().get_nodes_in_group("creep_camps"):
		if nd != null and nd.has_method("camp_faction_of"):
			camp_fac = nd.call("camp_faction_of", 0) as RtsFaction
	_check(camp_fac != null and camp_fac == _den.faction,
		"营地刷怪阵营 = 锚点建筑阵营（%s）" % (_den.faction.display_name if _den != null
			and _den.faction != null else "?"))

	var row: Dictionary = _camp_row(pos)
	_check(not row.is_empty(), "camps() 里有这座营地")
	_check(int(row.get("alive", -1)) == 3 and int(row.get("total", -1)) == 3,
		"camps() alive/total 对得上（%d/%d）"
		% [int(row.get("alive", -1)), int(row.get("total", -1))])
	_check(String(row.get("icon", "")) == "camp", "小地图图标 key = camp")

	# --- 5. 全灭 → 等 respawn 秒 → 补满 ---
	for u in spawned:
		u.call("take_damage", float(u.get("hp")) + 1.0, 0, null)
	await _wait(0.3)
	_check(_near_creeps(pos, 14.0).size() == 0, "野怪已全灭")
	# 先推进 1s：确认进入倒计时（而不是"死完立刻原地满血复活"）
	_camps.call("debug_tick", 1.0)
	var row2: Dictionary = _camp_row(pos)
	_check(float(row2.get("respawn_left", 0.0)) > 0.0,
		"进入补满倒计时（剩 %.0f 秒）" % float(row2.get("respawn_left", 0.0)))
	# 再推完剩余的 respawn 秒（配置 90s；多推 2s 留余量）
	_camps.call("debug_tick", 92.0)
	await _wait(1.0)
	var respawned: Array = _near_creeps(pos, 14.0)
	_check(respawned.size() == 3, "补满后回到 3 只（实 %d）" % respawned.size())
	var row3: Dictionary = _camp_row(pos)
	_check(int(row3.get("alive", -1)) == 3 and int(row3.get("total", -1)) == 3,
		"补满后 camps() alive/total = 3/3（实 %d/%d）"
		% [int(row3.get("alive", -1)), int(row3.get("total", -1))])

	# --- 6. 锚点被拆 → 小地图图标必须消失（2026-11-08 玩家口径）---
	#   小地图不读营地存活数，只读 `anchor_alive`（见 代码/界面/小地图.gd `_draw_creep_camps`）。
	#   这里验的就是那条契约：锚点死了，camps() 那一行必须把 anchor_alive 报成 false；
	#   否则"失落阵营的窝被拆了，小地图上还挂着一个图标"。
	var row4: Dictionary = _camp_row(pos)
	_check(bool(row4.get("anchor_alive", false)), "拆之前 camps().anchor_alive = true")
	_den.call("take_damage", float(_den.get("hp")) + 1.0, 0, null)
	await _wait(0.3)
	var row5: Dictionary = _camp_row(pos)
	_check(not row5.is_empty(), "锚点被拆后 camps() 仍然列出这座营地（由小地图按 anchor_alive 过滤）")
	_check(not bool(row5.get("anchor_alive", true)),
		"锚点被拆后 camps().anchor_alive = false（小地图图标会消失）")

	_report["营地表"] = summary
	_finish()


## 取主场景上已挂的营地系统；没有就自己造一个（自检不依赖挂载顺序）
func _camp_system() -> Node3D:
	var main: Node = get_parent()
	if main != null:
		var creeps: Node = main.get("creeps")
		if creeps != null:
			var n: Variant = creeps.get("camp_system")
			if n is Node3D and is_instance_valid(n):
				return n as Node3D
	var own: Node3D = CAMP_SCRIPT.new()
	own.name = "野怪营地自检"
	main.add_child(own)
	return own


## 锚点附近的野怪（只数活着的；野怪 id 与中立阵营一致）
func _near_creeps(center: Vector3, radius: float) -> Array:
	var out: Array = []
	if Game.neutral_faction == null:
		return out
	for u in Game.neutral_faction.units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not bool(u.call("is_alive")):
			continue
		var d: Variant = u.get("def")
		if d == null or not CREEP_IDS.has(String(d.id)):
			continue
		var n3 := u as Node3D
		if n3 == null:
			continue
		if Vector2(n3.global_position.x - center.x, n3.global_position.z - center.z).length() > radius:
			continue
		out.append(n3)
	return out


## camps() 里离 center 最近的一行（没有返回空字典）
func _camp_row(center: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = 4.0
	for c in _camps.call("camps"):
		var p: Vector3 = c.get("pos", Vector3.ZERO)
		var d: float = Vector2(p.x - center.x, p.z - center.z).length()
		if d <= best_d:
			best_d = d
			best = c
	return best


func _check(cond: bool, label: String) -> void:
	_checks.append({"检查": label, "通过": cond})
	if not cond:
		_ok = false


func _finish() -> void:
	_report["检查项"] = _checks
	_report["结果"] = "通过" if _ok else "失败"
	print("CAMPTEST " + JSON.stringify(_report))
	await _wait(0.2)
	get_tree().quit(0 if _ok else 1)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
