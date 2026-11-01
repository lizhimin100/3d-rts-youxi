class_name RtsCreeps
extends Node
## **中立野怪系统** —— 地牢 / 豺狼人 / 夜晚总攻。
##
## 玩家口径（2026-11-01）：
##   "新增中立敌对野怪：豺狼人战士、豺狼人斥候、地牢，新增机制：地牢会不断刷新野怪，
##    每到晚上（日夜系统）更是会出现一大批野怪进攻所有玩家。"
##
## 设计：
##   · 一个**中立阵营**（team 0）承载全部野怪。它不在 `Game.factions` 里 ——
##     没有大本营、不造建筑、没有 AI 经济，所以不参与胜负判定（见 游戏状态.enemies_of）；
##   · 地图上撒 3~4 座 **地牢**（`RtsDungeonVisual` 拼出来的巢穴，带营火光源）；
##   · 每座地牢每 `SPAWN_INTERVAL` 秒刷 1 只（本地牢存活数上限 `PER_LAIR_CAP`）；
##   · **入夜**（`RtsDayNight.night_started`）时，每座地牢一次放 `NIGHT_WAVE` 只，
##     并让它们直接去打最近的玩家基地；天亮后恢复平常节奏。
##
## 三条纪律：
##   1. 刷怪只能用 `Game.spawn_unit`（走注册表，索敌/小地图/迷雾才认得它）；
##   2. 刷出来的兵**必须**`order_hold()` 或 `order_attack_move()`，
##      否则默认 Order.NONE 会站在那儿一动不动；
##   3. 数量上限是硬约束：夜里放完一波要等天亮才回落到常规刷新，别让地图被塞爆。

## 常规刷新间隔（秒）
const SPAWN_INTERVAL := 42.0
## 每座地牢平时的存活上限
const PER_LAIR_CAP := 5
## 入夜时每座地牢一次放出的数量
## ★ 2026-11-01 从 5 降到 3：地牢数量从 4 涨到 8 之后，5×8=40 只一次性扑家
##   直接把三家人机全推平（玩家还没反应过来就"胜利"了）。3×8=24 只才是"压力"。
const NIGHT_WAVE := 3
## 开局每座地牢的守家小队（魔兽的 creep camp 也是 2~4 只一站）
const GUARDS := 3
## 地牢离任意基地的最小距离（米）：太近了开局就被玩家推掉
const MIN_BASE_DIST := 34.0
## 两座地牢之间的最小间距（米）：太挤就变成"一窝"，失去"到处都有"的感觉
const MIN_LAIR_GAP := 26.0
## 野怪游荡半径（米）
const WANDER_RADIUS := 13.0
## **目标地牢数量**（玩家口径 2026-11-01："和魔兽争霸一样到处都有，七到八处"）。
## 只在"地图上没有编辑器摆的地牢"时才自动撒这么多。
const WANT_LAIRS := 8


var faction: RtsFaction = null
## [{ "node": Node3D, "units": Array, "t": float }]
var _lairs: Array = []
var _timer: float = 0.0
var _day: Node = null
var _night_done: bool = false
var _level: Node3D = null


## 主场景在关卡建好之后调用。`day` 可以是 null（没有日夜系统也能跑常规刷新）。
##
## ★ **地牢从哪来**（2026-11-01 玩家口径："地牢我来在编辑器放置"）：
##   1. 先收编**地图里已经有**的地牢（编辑器放的，归属中立 owner=-1）；
##   2. 一座都没有 → 才按 WANT_LAIRS（8 座）自动撒到全图。
##   两条路的结果都写进同一份 `_lairs`，后面的刷怪/夜袭逻辑完全不区分来源。
func setup(level: Node3D, day: Node = null) -> void:
	_level = level
	_day = day
	if Cfg == null or Cfg.unit(&"dungeon") == null:
		return
	_make_faction()
	_adopt_editor_lairs()
	if _lairs.is_empty():
		_place_lairs()
	if _day != null and _day.has_signal("night_started"):
		_day.connect("night_started", _on_night)
	if _day != null and _day.has_signal("day_started"):
		_day.connect("day_started", _on_day)
	print("[野怪] 就绪：%d 座地牢 / 中立阵营「%s」" % [_lairs.size(),
			faction.display_name if faction != null else "-"])
	# 编辑器摆的地牢**有几座就算几座**（不会再自动补到 8 座 —— 那是玩家在设计地图）。
	# 太少的话提醒一句，别让人以为"野怪系统没生效"。
	if _lairs.size() < 4:
		print("[野怪] 提示：地图上只有 %d 座地牢，建议 7~8 座（见 文档/编辑器资产同步.md）"
			% _lairs.size())


## 中立阵营：team 0，对任何队伍都敌对，但没有大本营
func _make_faction() -> void:
	faction = RtsFaction.new()
	faction.setup(99, false, "豺狼人", Color(0.72, 0.28, 0.18), 0, 0)
	faction.team = 0
	faction.slot = -1
	faction.is_ai = true
	Game.neutral_faction = faction


## 阵营的基地中心。
## ★ 优先用**大本营的真实坐标**：`RtsWorld.base_center()` 读的是 `_base_pos`，
##   而 `--map=` / MapDef 那条路不一定灌过它（会返回 (0,0)）——
##   第一版就因此把地牢摆到了玩家基地门口。
func _base_of(f: RtsFaction) -> Vector3:
	if f == null:
		return Vector3.ZERO
	for b in f.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive():
			continue
		if b.def != null and String(b.def.id) == "townhall":
			return (b as Node3D).global_position
	return RtsWorld.base_center(f)


## **收编编辑器摆好的地牢**（玩家口径："地牢我来在编辑器放置"）。
##
## 判定只有一条：`UnitDef.id == "dungeon"` 且**归属中立**（编辑器里 owner = -1）。
## 收编动作 = 把 faction 从 null 换成中立野怪阵营 + 登记进该阵营的 buildings，
## 否则它是个"没有阵营的死建筑"：单位索敌打不到它、小地图不显示、夜袭也不认它。
func _adopt_editor_lairs() -> void:
	for n in Game.all_units():
		if n == null or not is_instance_valid(n):
			continue
		var b := n as RtsBuilding
		if b == null or b.def == null or String(b.def.id) != "dungeon":
			continue
		if not b.is_alive():
			continue
		if b.faction != null and b.faction != faction:
			# 有人把地牢摆成了自己家建筑：不当巢穴，但**要说一声**，
			# 否则玩家会问"我摆的地牢为什么不刷怪"。
			print("[野怪] 跳过归属「%s」的地牢 @ (%.0f, %.0f)"
				% [b.faction.display_name, b.global_position.x, b.global_position.z])
			continue
		if b.faction == null:
			b.faction = faction
			if not faction.buildings.has(b):
				faction.buildings.append(b)
		_register_lair(b)
		print("[野怪] 收编编辑器地牢 %d @ (%.0f, %.0f)" % [_lairs.size(),
				b.global_position.x, b.global_position.z])


## 把一座地牢登记成巢穴：补占地/完工状态、起名、发守家小队。
## 自动撒点和编辑器收编共用这一段，保证两条路的表现完全一致。
func _register_lair(b: Node3D) -> void:
	if b == null:
		return
	if _level != null and _level.has_method("mark_footprint"):
		_level.call("mark_footprint", b)
	if b.has_method("set_constructed"):
		b.call("set_constructed", true)
	b.name = "地牢_%d" % (_lairs.size() + 1)
	_lairs.append({"node": b, "units": [], "t": randf_range(2.0, SPAWN_INTERVAL)})
	for i in GUARDS:
		_spawn_one(_lairs.size() - 1, false)


## 在地图上撒 WANT_LAIRS 座"离所有基地都远"的巢穴（没有编辑器地牢时的兜底）。
##
## 算法：**可行点网格 + 最远点采样**（确定性，不掷骰子）。
##   ① 以地图中心为原点铺 9m 网格，滤掉"贴基地 / 出岛 / 放不下 5×5"的点；
##   ② 第一个点取"离所有基地最远"的候选，之后每次取"离已选点最远"的候选。
## 为什么不用"几个圆环按角度摆"（前一版）：地图是 224m 的岛、四家基地在对角线上，
## 圆环半径一大，整圈点就都落进基地的 34m 圈里，最多只撒出 4 座。
## 最远点采样与基地/地形的具体分布无关，**要几座都能均匀铺满**。
func _place_lairs() -> void:
	var size: float = float(Cfg.game.map_size)
	var bases: Array = []
	for f in Game.factions:
		if f == null:
			continue
		var c: Vector3 = _base_of(f)
		bases.append(Vector2(c.x, c.z))
		print("[野怪] 基地 %s @ (%.0f, %.0f)" % [f.display_name, c.x, c.z])
	# ★ 世界坐标是**以地图中心为原点**的（-size/2 .. +size/2），
	#   不是 0..size。第一版按 0..size 算，地牢全被摆到地图外面去了。
	#   地图中心 = 各基地的形心（四周基地天然对称，比读配置稳）。
	var center := Vector2.ZERO
	for b in bases:
		center += b as Vector2
	if not bases.is_empty():
		center /= float(bases.size())

	# ① 候选点网格（同时算好"离最近基地多远"，后面选第一个点要用）
	var cands: Array[Vector2] = []
	var cand_d: Array[float] = []
	var half: float = size * 0.5 - 26.0
	var fp: Vector2i = Cfg.unit(&"dungeon").footprint
	const GRID_STEP := 9.0
	var gx: float = -half
	while gx <= half:
		var gz: float = -half
		while gz <= half:
			var p := Vector2(center.x + gx, center.y + gz)
			var db: float = _min_base_dist(p, bases)
			if db >= MIN_BASE_DIST and _lair_spot_ok(p, fp):
				cands.append(p)
				cand_d.append(db)
			gz += GRID_STEP
		gx += GRID_STEP
	if cands.is_empty():
		push_warning("[野怪] 找不到可放地牢的空地（一座地牢都没生成）")
		return

	# ② 最远点采样
	var first: int = 0
	for i in cands.size():
		if cand_d[i] > cand_d[first]:
			first = i
	var picked: Array[Vector2] = [cands[first]]
	while picked.size() < WANT_LAIRS:
		var best: int = -1
		var best_d: float = -1.0
		for i in cands.size():
			var p: Vector2 = cands[i]
			var d: float = INF
			for q in picked:
				d = minf(d, p.distance_to(q))
			if d > best_d:
				best_d = d
				best = i
		if best < 0 or best_d < MIN_LAIR_GAP:
			break
		picked.append(cands[best])

	# ③ 落位（_try_lair_at 再做一次终检，含与已有建筑/资源的关系）
	for p in picked:
		if _lairs.size() >= WANT_LAIRS:
			break
		_try_lair_at(p, center, bases, size)


## 到最近基地的（平面）距离
func _min_base_dist(p: Vector2, bases: Array) -> float:
	var d: float = INF
	for b in bases:
		d = minf(d, (b as Vector2).distance_to(p))
	return d


## 这个点能不能放下一座地牢（只看地形/寻路/已有建筑，不管基地距离和地牢间距）
func _lair_spot_ok(p: Vector2, fp: Vector2i) -> bool:
	# 必须在可行走区内：地形岛边缘以外是虚空，摆在那里既看不见也走不到
	var probe: Vector3 = RtsWorld.walkable_pos(Vector3(p.x, 0.0, p.y))
	if Vector2(probe.x, probe.z).distance_to(p) > 6.0:
		return false
	# 5×5 占地必须全都可走（walkable_pos 只保证中心点）
	return 建筑网格.can_place(Vector3(p.x, 0.0, p.y), fp)


## 在 p 处试着摆一座地牢；合格就摆下并返回 true。
func _try_lair_at(p: Vector2, center: Vector2, bases: Array, size: float) -> bool:
	# 越界保护（留 24m 边距给地图边界墙）
	var half: float = size * 0.5 - 24.0
	if absf(p.x - center.x) > half or absf(p.y - center.y) > half:
		return false
	if not _lair_spot_ok(p, Cfg.unit(&"dungeon").footprint):
		return false
	for b in bases:
		if (b as Vector2).distance_to(p) < MIN_BASE_DIST:
			return false
	for l in _lairs:
		var n: Node3D = l["node"]
		if Vector2(n.global_position.x, n.global_position.z).distance_to(p) < MIN_LAIR_GAP:
			return false
	_spawn_lair(p)
	return true


func _spawn_lair(p2: Vector2) -> void:
	var pos: Vector3 = RtsWorld.walkable_pos(Vector3(p2.x, 0.0, p2.y))
	if _level != null and _level.has_method("snap_to_ground"):
		pos = _level.call("snap_to_ground", pos)
	var b: Node3D = Game.spawn_unit(faction, &"dungeon", pos, _level if _level != null else null)
	if b == null:
		return
	b.rotation = Vector3(0.0, 建筑网格.snap_yaw(建筑网格.default_yaw()), 0.0)
	_register_lair(b)
	print("[野怪] 自动撒地牢 %d @ (%.0f, %.0f)" % [_lairs.size(), pos.x, pos.z])


## 刷一只：战士 2 : 斥候 1
func _spawn_one(lair_idx: int, aggressive: bool) -> Node3D:
	if lair_idx < 0 or lair_idx >= _lairs.size():
		return null
	var l: Dictionary = _lairs[lair_idx]
	var node: Node3D = l["node"]
	if node == null or not is_instance_valid(node) or not node.is_alive():
		return null
	var id: StringName = &"gnoll_warrior" if randf() < 0.66 else &"gnoll_scout"
	var ang: float = randf() * TAU
	var dist: float = randf_range(3.2, 6.0)
	var pos: Vector3 = node.global_position + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
	pos = RtsWorld.walkable_pos(pos)
	var u: Node3D = Game.spawn_unit(faction, id, pos, _level if _level != null else null)
	if u == null:
		return null
	var arr: Array = l["units"]
	arr.append(u)
	l["units"] = arr
	if aggressive:
		_march_to_base(u)
	else:
		_wander(u, node.global_position)
	return u


## 让它在地牢附近晃（会顺手打路过的单位）
func _wander(u: Node3D, home: Vector3) -> void:
	if u == null or not is_instance_valid(u) or not u.has_method("order_attack_move"):
		return
	var ang: float = randf() * TAU
	var r: float = randf_range(4.0, WANDER_RADIUS)
	var p: Vector3 = RtsWorld.walkable_pos(home + Vector3(cos(ang) * r, 0.0, sin(ang) * r))
	u.call("order_attack_move", p)


## 夜里：去打最近的非中立基地
func _march_to_base(u: Node3D) -> void:
	if u == null or not is_instance_valid(u) or not u.has_method("order_attack_move"):
		return
	var best: Vector3 = Vector3.ZERO
	var best_d: float = INF
	for f in Game.factions:
		if f == null or f == faction:
			continue
		if not f.has_townhall():
			continue
		var c: Vector3 = _base_of(f)
		var d: float = u.global_position.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = c
	if best_d == INF:
		return
	u.call("order_attack_move", RtsWorld.walkable_pos(best))


func _on_night() -> void:
	_night_done = true
	var total: int = 0
	for i in _lairs.size():
		for k in NIGHT_WAVE:
			if _spawn_one(i, true) != null:
				total += 1
	if total > 0:
		Game.toast("夜幕降临：豺狼人从地牢里涌出来了（%d 只）" % total, Color(0.95, 0.45, 0.30))


func _on_day() -> void:
	_night_done = false


func _process(delta: float) -> void:
	if faction == null or _lairs.is_empty():
		return
	_timer += delta
	if _timer < SPAWN_INTERVAL:
		# 平时也每 ~7 秒让闲着的野怪换个站位（不然一窝站着像雕像）
		if _timer > 7.0 and int(Engine.get_process_frames()) % 7 == 0:
			_repick_wander()
		return
	_timer = 0.0
	for i in _lairs.size():
		var l: Dictionary = _lairs[i]
		var arr: Array = l["units"]
		# 清掉死掉/失效的引用
		var alive: Array = []
		for u in arr:
			if u != null and is_instance_valid(u) and u.is_alive():
				alive.append(u)
		l["units"] = alive
		var cap: int = PER_LAIR_CAP * (2 if _night_done else 1)
		if alive.size() < cap:
			_spawn_one(i, _night_done)


func _repick_wander() -> void:
	for l in _lairs:
		var node: Node3D = l["node"]
		if node == null or not is_instance_valid(node):
			continue
		for u in (l["units"] as Array):
			if u == null or not is_instance_valid(u) or not u.is_alive():
				continue
			# 只在"站着没事干"的时候换点（正在打/正在走的别打断）
			if int(u.get("order")) == RtsConst.Order.NONE:
				_wander(u, node.global_position)


# ===========================================================================
# 自检 / 调试
# ===========================================================================

## 地牢数量（验收用）
func lair_count() -> int:
	return _lairs.size()


## 当前活着的野怪数量（验收用）
func alive_count() -> int:
	var n: int = 0
	if faction == null:
		return 0
	for u in faction.units:
		if u != null and is_instance_valid(u) and u.is_alive():
			n += 1
	return n


## 手动触发一次夜袭（--qa-creeps 用）
func debug_night_wave() -> int:
	var before: int = alive_count()
	_on_night()
	return alive_count() - before
