extends Node3D
## **野怪营地（可配置刷怪）** —— 一座中立锚点建筑 + 一圈野怪 + 全灭补满。
##
## 设计口径（2026-11-06 玩家确认）：
##   · **营地是地图内容，不是定时事件**：锚点建筑由玩家在地图编辑器里摆（owner = -1），
##     代码只负责"识别它 + 刷它配的怪"。**没有入夜总攻、没有定时补怪、没有自动撒营地**
##     （这一整套曾被玩家明令删除，别再长回来）。
##   · 配置全在 `代码/配置/卡/野怪营地/*.tres`：刷哪几种、各几只、半径、补满间隔。
##     加一种营地 = 加一个 .tres，不改代码。
##   · 判据只有一条：野怪挂在 `Game.neutral_faction`（team 0）上。
##
## 分帧刷怪：
##   一次性把 10+ 个 RtsUnit 塞进场景，会让开局第一帧掉到个位数帧率（模型加载 + 寻路注册
##   都在同一帧）。这里用 0.1s 的计时器队列，一次最多 3 只 —— 4 只的营地也就两拍。
##
## ⚠ 不写 class_name：调用方（野怪.gd / 小地图）一律 `.call("…")` 或组查询。

## 营地表（静态扫目录）
const CAMP_TABLE := preload("res://代码/配置/野怪营地表.gd")

## 检查间隔（秒）：1s 一次足够，营地的补满时间是 75~90s 量级
const CHECK_SEC: float = 1.0
## 一拍最多刷几只
const SPAWN_BATCH: int = 3
## 刷怪队列的节拍（秒）
const SPAWN_STEP: float = 0.1
## 黄金角：按序号绕锚点铺开，不重叠也不会排成一条线
const GOLDEN_ANGLE: float = 2.39996323
## 第一圈的半径（米）：必须大于锚点建筑的半对角线，否则怪会站在房子里
const RING_MIN: float = 3.9
## 相邻两只怪之间的半径增量
const RING_STEP: float = 0.55

## 中立阵营（由 setup 传入）
var faction = null
## 生成单位挂到哪个节点（关卡；没有就挂到自己下面）
var level: Node3D = null

## 营地状态表。每项：
##   def(Resource) / anchor(Node3D) / pos(Vector3) / units(Array) / pending(int)
##   total(int) / waiting(bool) / respawn_left(float) / spawn_seq(int) / seed(float)
var _camps: Array = []
## 待刷队列：[{camp: int, id: StringName}]
var _queue: Array = []
## 1s 检查节拍累计
var _tick_acc: float = 0.0
## 刷怪节拍器（只在有待刷时跑）
var _spawn_timer: Timer = null


func _ready() -> void:
	add_to_group("creep_camps")


## 由 野怪.setup 调用（中立阵营已经建好、地图对象已经落地）
func setup(p_faction) -> void:
	faction = p_faction
	level = RtsWorld.level()
	add_to_group("creep_camps")
	# 幂等：已经认领过营地的就不再扫一遍。
	# 否则第二次 setup 会把同一座营地的怪重刷一遍（旧引用还在，数量直接翻倍）。
	# 唯一的例外是"上次扫到 0 座"（玩家 / 自检随后才摆下锚点）—— 这种情况下 _camps 是空的。
	if not _camps.is_empty():
		return
	_scan_camps()
	if _camps.is_empty():
		print("[野怪营地] 没有识别到营地（任何阵营里都没有带营地配置的 creep_den/creep_gate/creep_shell —— "
			+ "在地图编辑器里摆一座锚点、再在「营地」页指派配置即可）")
		return
	var total: int = 0
	for c in _camps:
		total += int(c["total"])
	print("[野怪营地] 识别到 %d 座营地、共 %d 只野怪（分帧刷，每拍最多 %d 只）"
		% [_camps.size(), total, SPAWN_BATCH])


## 扫**所有阵营**的建筑：带 camp_id（或 id 命中营地表的锚点建筑）就是一座营地。
##
## 2026-11-07 改写（玩家口径「由我自定义这是哪个玩家的营地」）：
##   · 以前只扫中立阵营 → 锚点摆成"玩家 2"就永远不刷怪；
##   · 现在归谁由**锚点建筑的 owner** 决定：中立敌对刷野怪、玩家 N 就替 N 守家。
##   · 每座营地的配置优先读建筑上的 `camp_id`（编辑器逐实例指定），
##     没有才退回"按锚点建筑 id 反查营地表"的老口径。
func _scan_camps() -> void:
	_camps.clear()
	_queue.clear()
	var pools: Array = []
	for f in Game.factions:
		if f != null:
			pools.append(f)
	if Game.neutral_faction != null:
		pools.append(Game.neutral_faction)
	if Game.passive_faction != null:
		pools.append(Game.passive_faction)
	for fac in pools:
		var ff: RtsFaction = fac
		if ff == null:
			continue
		for b in ff.buildings:
			if b == null or not is_instance_valid(b):
				continue
			var bd = b.get("def")
			if bd == null:
				continue
			var cid: String = String(b.get_meta("camp_id", ""))
			var d: Resource = CAMP_TABLE.by_id(cid) if not cid.is_empty() else null
			if d == null:
				d = CAMP_TABLE.for_den(bd.id)
			if d == null:
				continue
			var total: int = 0
			var counts: Array = d.get("counts")
			for n in counts:
				total += int(n)
			if total <= 0:
				continue
			var first: float = maxf(float(d.get("first_spawn_min")), 0.0) * 60.0
			var camp: Dictionary = {
				"index": _camps.size(),
				"def": d,
				"anchor": b,
				"faction": ff,
				"pos": (b as Node3D).global_position,
				"units": [],
				"pending": 0,
				"total": total,
				"waiting": false,
				"respawn_left": 0.0,
				"spawn_seq": 0,
				"next_wave": first,
				"waves_done": 0,
				"seed": float(_camps.size()) * 0.7,
			}
			_camps.append(camp)
			# 开局就刷的营地立刻进队；有首次时间的等 _tick 到点
			if first <= 0.01:
				_refill(camp)
				camp["waves_done"] = 1
			print("[野怪营地]「%s」锚点 %s @ (%.0f, %.0f)，阵营 %s，配置 %s"
				% [String(d.get("display_name")), String(bd.id), camp["pos"].x, camp["pos"].z,
					ff.display_name, _preview(d)])


## 配置的简短可读串（日志用）
func _preview(d: Resource) -> String:
	var parts: Array = []
	var creeps: Array = d.get("creeps")
	var counts: Array = d.get("counts")
	for i in range(mini(creeps.size(), counts.size())):
		parts.append("%s×%d" % [String(creeps[i]), int(counts[i])])
	return "%s（补满 %.0fs）" % [", ".join(parts), float(d.get("respawn"))]


# ===========================================================================
# 刷怪（0.1s 节拍，最多 3 只/拍）
# ===========================================================================

## 按配置把所有单位塞进队列，并启动节拍器
func _refill(camp: Dictionary) -> void:
	var d: Resource = camp["def"]
	var creeps: Array = d.get("creeps")
	var counts: Array = d.get("counts")
	var idx: int = int(camp["index"])
	for i in range(mini(creeps.size(), counts.size())):
		var id: StringName = StringName(String(creeps[i]))
		for _k in range(int(counts[i])):
			_queue.append({"camp": idx, "id": id})
			camp["pending"] = int(camp["pending"]) + 1
	if _queue.is_empty():
		return
	if _spawn_timer == null:
		_spawn_timer = Timer.new()
		_spawn_timer.name = "刷怪节拍"
		_spawn_timer.wait_time = SPAWN_STEP
		_spawn_timer.autostart = false
		_spawn_timer.timeout.connect(_pump_spawn)
		add_child(_spawn_timer)
	if _spawn_timer.is_stopped():
		_spawn_timer.start()


func _pump_spawn() -> void:
	var n: int = 0
	while n < SPAWN_BATCH and not _queue.is_empty():
		var item: Dictionary = _queue.pop_front()
		var ci: int = int(item["camp"])
		if ci >= 0 and ci < _camps.size():
			var camp: Dictionary = _camps[ci]
			_spawn_one(camp, StringName(String(item["id"])))
			camp["pending"] = maxi(0, int(camp["pending"]) - 1)
		n += 1
	if _queue.is_empty() and _spawn_timer != null:
		_spawn_timer.stop()


## 在锚点外圈刷一只
func _spawn_one(camp: Dictionary, id: StringName) -> void:
	var d: Resource = camp["def"]
	var seq: int = int(camp["spawn_seq"])
	camp["spawn_seq"] = seq + 1
	var ang: float = GOLDEN_ANGLE * float(seq) + float(camp["seed"])
	var rad: float = minf(RING_MIN + RING_STEP * float(seq),
		maxf(RING_MIN, float(d.get("radius"))))
	var base: Vector3 = camp["pos"]
	var p := Vector3(base.x + cos(ang) * rad, 0.0, base.z + sin(ang) * rad)
	# 必须落可走格：营地常摆在台地边/林间空地，硬算的圆环会有一半落在崖壁或树里
	p = RtsWorld.walkable_pos(p)
	var parent: Node3D = level
	if parent == null or not is_instance_valid(parent):
		parent = self
	var cf: RtsFaction = camp.get("faction", null) as RtsFaction
	var u: Node3D = Game.spawn_unit(cf if cf != null else faction, id, p, parent)
	if u == null:
		return
	(camp["units"] as Array).append(u)


# ===========================================================================
# 全灭补满（1s 检查）
# ===========================================================================

func _process(delta: float) -> void:
	if _camps.is_empty():
		return
	_tick_acc += delta
	if _tick_acc < CHECK_SEC:
		return
	var dt: float = _tick_acc
	_tick_acc = 0.0
	_tick(dt)


func _tick(dt: float) -> void:
	for camp in _camps:
		# --- 时间点刷怪（2026-11-07）---
		# `spawn_interval_min > 0` = 每 N 分钟刷一整波；= 0 只按 first 刷一次。
		var d0: Resource = camp["def"]
		var interval: float = maxf(float(d0.get("spawn_interval_min")), 0.0) * 60.0
		var next_wave: float = float(camp.get("next_wave", 0.0))
		if float(Game.elapsed) >= next_wave and int(camp["pending"]) <= 0:
			if interval > 0.0:
				camp["next_wave"] = next_wave + interval
				if float(Game.elapsed) >= next_wave + 0.1:
					# 不清 units：老的一波可能还活着，清掉就变成"没人统计的野怪"。
					# 新一波直接追加，全灭判定仍然按 units 里所有活着的算。
					_refill(camp)
					camp["waves_done"] = int(camp.get("waves_done", 0)) + 1
					print("[野怪营地]「%s」第 %d 波刷新（%.1f 分钟）"
						% [String(d0.get("display_name")), int(camp["waves_done"]),
							float(Game.elapsed) / 60.0])
			elif int(camp.get("waves_done", 0)) == 0:
				_refill(camp)
				camp["waves_done"] = 1
		var alive: int = _alive_units(camp).size()
		# 还在分帧刷（队列没排完）时不算"全灭" —— 否则刚摆下的营地会自己进入倒计时
		if int(camp["pending"]) > 0:
			continue
		if alive > 0:
			if bool(camp["waiting"]):
				camp["waiting"] = false
				camp["respawn_left"] = 0.0
			continue
		var d: Resource = camp["def"]
		var wait: float = float(d.get("respawn"))
		# respawn <= 0 = 一次性的营地：清完就没了，不补
		if wait <= 0.0:
			continue
		if not bool(camp["waiting"]):
			camp["waiting"] = true
			camp["respawn_left"] = wait
			print("[野怪营地] 「%s」全灭，%.0f 秒后补满" % [String(d.get("display_name")), wait])
		camp["respawn_left"] = float(camp["respawn_left"]) - dt
		if float(camp["respawn_left"]) <= 0.0:
			camp["waiting"] = false
			camp["respawn_left"] = 0.0
			camp["units"] = []
			_refill(camp)
			print("[野怪营地] 「%s」补满（%d 只）"
				% [String(d.get("display_name")), int(camp["total"])])


## 这座营地还活着的怪（顺便清掉已释放/已阵亡的引用）
func _alive_units(camp: Dictionary) -> Array:
	var src: Array = camp["units"]
	var out: Array = []
	for u in src:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not bool(u.call("is_alive")):
			continue
		out.append(u)
	if out.size() != src.size():
		camp["units"] = out
	return out


# ===========================================================================
# 对外查询（小地图 / 自检）
# ===========================================================================

## 第 idx 座营地的刷怪阵营（自检/调试用）
func camp_faction_of(idx: int) -> RtsFaction:
	if idx < 0 or idx >= _camps.size():
		return null
	return _camps[idx].get("faction", null) as RtsFaction


## 每座营地一行：{pos, name, icon, alive, total, respawn_left, anchor_alive}
##
## `anchor_alive` = 营地那座锚点建筑还活着没有。小地图靠它决定"图标画不画"：
## 失落阵营的窝被拆了，图标必须跟着消失（2026-11-08 玩家口径）。
func camps() -> Array:
	var out: Array = []
	for camp in _camps:
		var d: Resource = camp["def"]
		var left: float = float(camp["respawn_left"]) if bool(camp["waiting"]) else 0.0
		var anchor: Node = camp.get("anchor", null)
		var anchor_alive: bool = anchor != null and is_instance_valid(anchor) \
				and (not anchor.has_method("is_alive") or bool(anchor.call("is_alive")))
		out.append({
			"pos": camp["pos"],
			"anchor_alive": anchor_alive,
			"name": String(d.get("display_name")),
			"icon": String(d.get("minimap_icon")),
			"alive": _alive_units(camp).size(),
			"total": int(camp["total"]),
			"respawn_left": maxf(0.0, left),
		})
	return out


## 营地数量（自检/日志用）
func camp_count() -> int:
	return _camps.size()


## 测试钩子：按秒推进检查节拍（不等真实的 75~90 秒）。
## 生产代码不会调它 —— 但少了它，补满逻辑就只能靠"真人挂机两分钟"来验。
func debug_tick(sec: float) -> void:
	var left: float = maxf(0.0, sec)
	while left > 0.0:
		var step: float = minf(CHECK_SEC, left)
		_tick(step)
		left -= step
