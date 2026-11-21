extends Node
## **全局游戏状态（自动加载单例 `游戏`）**
## 职责：
##   - 持有两个阵营（玩家 / 敌人）与游戏阶段
##   - 维护全局单位注册表（谁活着、谁死了）
##   - 提供生成单位、找敌人、扣资源等公共服务
##   - 广播全局信号（战斗命中、选择变化、游戏结束……）供 UI / 镜头 / AI 订阅
##
## 约定：**这个类只管"全局"**，不写单位的具体行为（那是 RtsUnit），
## 也不写 UI（那是 RtsHud）。这样循环依赖最少。

# ===========================================================================
# 信号（名字与签名冻结，见 Documents/作战条令.md §4.2）
# ===========================================================================
## 单位被生成
signal unit_spawned(unit: Node3D)
## 单位死亡（还没被移除）
signal unit_died(unit: Node3D)
## 击杀归因（2026-11-08）：谁打死了谁 —— 经验、掉落、击杀日志都挂这条信号
signal unit_killed(victim: Node3D, killer: Node3D)
## 建筑建造完成
signal building_completed(building: Node3D)
## 阵营资源/人口变化
signal resources_changed(faction: RtsFaction)
## 选择集合变化
signal selection_changed(units: Array)
## 对局阶段变化（规划 → 执行 → 胜利/失败）
## ★ 唯一入口是 set_phase()；不要再直接写 phase = ...
signal phase_changed(old_phase: int, new_phase: int)
## 战斗命中（伤害数字、火花、震屏都靠它）
signal combat_hit(attacker: Node3D, target: Node3D, damage: float, is_crit: bool)
## 投射物命中
signal projectile_impact(pos: Vector3, kind: int)
## 下达指令
signal order_issued(units: Array, order: int, target_pos: Vector3, target: Node3D)
## 顶部提示消息
signal notify(text: String, color: Color)
## 游戏结束
signal game_over(victory: bool)
## 请求镜头抖动
signal camera_shake(strength: float)


# ===========================================================================
# 状态
# ===========================================================================
## 游戏阶段（RtsConst.Phase）
var phase: int = RtsConst.Phase.PLANNING
## 已经进行的秒数（只在 RUNNING 阶段累加）
var elapsed: float = 0.0
## **短局模式**：规划阶段（世界暂停）+ 执行阶段（实时）+ CP 运营。
## 长局（默认）仍是原来的即时战略；短局由 `--short` 或 `--round-test` 开启。
## ★ 必须在 HUD/主场景 _ready 之前定下来（Game 是自动加载，先于主场景）。
var short_match: bool = false
## 回合控制器（短局由主场景挂载；长局为 null）
var round_control: Node = null
## **小队注册表**（全局唯一，RefCounted；见 Game/systems/小队注册表.gd）
## 小队是命令的一等公民：命令记录只存 squad_id + unit_ids，执行时按小队成员解析。
var squads = null
## 生成序号（节点名用）。必须是确定性的：同 seed 复跑要得到同一串名字。
var _spawn_seq: int = 0
## 难度下标
var difficulty_index: int = 0

## 玩家阵营（人类操作的那个；槽位 0）
var player_faction: RtsFaction = null
## "主要的"敌人阵营 —— 只为兼容旧Game/旧提示语保留，**不要再拿它当敌我判据**。
## 真正的判据是 team（见 is_enemy_of / enemies_of）。
var enemy_faction: RtsFaction = null
## **本局全部阵营**（多队图：每个出生点一个）。下标 = 槽位号。
var factions: Array[RtsFaction] = []
## **中立敌对阵营**（野怪，team 0）。故意**不放进 `factions`**：
##   · 它没有大本营，放进 factions 会让"胜负判定 / 开局布阵 / AI 接管"全部误伤；
##   · 但它必须能被 `enemies_of()` 看到，否则单位永远索不到野怪（见下面的 append）。
var neutral_faction: RtsFaction = null
## **和平中立阵营**（地图编辑器里的「中立」，`owner = -1`）。
## 和 `neutral_faction`（中立敌对，team 0 野怪）是两回事：
## 和平中立对谁都不敌对，也不进 `factions`/胜负判定；地图上的中立装饰、商人、
## 中立建筑都挂它。`passive = true` 让 `is_enemy_of()` 永远返回 false。
var passive_faction: RtsFaction = null
## 关卡（由 主场景 挂上）
var level: Node3D = null
## **短局固定布局运行时**（Game/core/布局运行时.gd；长局 / 没配布局卡时为 null）。
## 槽位（slot_id）绑定、血量继承、损毁态与复活都通过它，见 Documents/短局-布局卡.md。
var layout = null

## **日夜系统**（由 主场景 在 4.98 挂上；没有它就是白天）。
## ★ 这是"现在是不是夜里"的**唯一全局出口**：界面 / 营火 / HUD 都读这里，
##   不要再各自去 `get_parent().get("day_night")` —— 那是"谁挂谁知道"的写法，
##   换层级就静默失效（踩过：营火白天不灭）。
var day_night: Node = null
## 地图据点（资源箱）。由主场景挂在关卡里；HUD 只读它的公开方法。
var strongpoint: Node = null


## 现在是不是夜里（没有日夜系统 = 永远白天）
func is_night() -> bool:
	if day_night == null or not is_instance_valid(day_night):
		return false
	if not day_night.has_method("is_night"):
		return false
	return bool(day_night.call("is_night"))

## 全部存活单位（含建筑）。由 register/unregister 维护
var _units: Array = []
## 全部存活建筑
var _buildings: Array = []
## 全部可采集物（金矿/树），用于 AI 与小地图
var _harvestables: Array = []


func _ready() -> void:
	# 短局是**唯一玩法**（2026-11-20 转型）：`--long` 已删除，旧即时战略不再存在。
	#
	# 唯一的例外是**无窗口自检**（App.test_mode）：它要驱动单位跑逻辑，
	# 所以默认不进入规划暂停（否则所有历史自检都会冻在世界暂停里）。
	# 这不是"长局玩法"，只是测试台不按阶段暂停。
	var args := OS.get_cmdline_user_args()
	var explicit_short: bool = ("--short" in args) or ("--round-test" in args)
	var test_like: bool = App != null and bool(App.get("test_mode"))
	short_match = explicit_short or not test_like
	print("[Game] mode=", "short" if short_match else "test-unpaused")
	# 小队注册表：命令记录引用它，单位死亡时自动剔除成员。
	var sq_script := load("res://Game/systems/小队注册表.gd")
	if sq_script != null:
		squads = sq_script.new()
		squads.call("attach")

func _process(delta: float) -> void:
	if phase == RtsConst.Phase.RUNNING:
		elapsed += delta
		# ★ 2026-11-15 玩家拍板：CP 只在规划阶段出现/消耗；执行阶段不回复、不显示。
		#   每回合规划阶段由基地补满（回合控制.end_execution → begin_planning_cp）。

# ===========================================================================
# 阶段（唯一入口）
# ===========================================================================

## 切阶段。**不要直接写 phase**——规划/结束阶段必须同时冻结世界。
##
## 冻结口径：`SceneTree.paused = true`。这样单位/建筑/AI/据点/日夜/投射物/
## Timer/AnimationPlayer 默认全停；规划阶段仍然可以看、可以点、可以排命令，
## 靠的是**显式白名单**（`PROCESS_MODE_ALWAYS`）：
##   · UI：HUD / 规划阶段界面 / 说明气泡 / 镜头 / 光标术 / 头顶界面；
##   · 输入：选择系统 / 指令系统 / 战区指令输入 / 部署输入；
##   · 玩法胶水：回合控制（它负责切阶段本身）、副官（规划里只读不写）。
## **白名单只准加"不推进世界时间"的节点**：任何会移动单位、推进计时、
## 生成投射物、跑 AI 判定的脚本都不许设 ALWAYS，否则"绝对冻结"就漏了。
func set_phase(p: int) -> void:
	var old: int = phase
	phase = p
	# 即使 old == p 也要重设 paused：建局时 phase 初始就是 PLANNING，
	# 这里必须把树冻上，不能因为"值没变"就跳过。
	if is_inside_tree():
		var tree := get_tree()
		if tree != null:
			tree.paused = (p == RtsConst.Phase.PLANNING
					or p == RtsConst.Phase.VICTORY
					or p == RtsConst.Phase.DEFEAT)
	if old != p:
		phase_changed.emit(old, p)


## 规划阶段（短局：世界暂停，可排命令/建造/训练）
func is_planning() -> bool:
	return phase == RtsConst.Phase.PLANNING


## 执行阶段（短局：实时推进）
func is_executing() -> bool:
	return phase == RtsConst.Phase.RUNNING


## 对局已结束（胜利/失败）
func is_over() -> bool:
	return phase == RtsConst.Phase.VICTORY or phase == RtsConst.Phase.DEFEAT


# ===========================================================================
# 初始化
# ===========================================================================

## 建立本局的**全部阵营**（关卡初始化时调用一次）。
##
## 多队规则（用户口径）：
##   · 出生点数量 = Cfg.game.match_slots（默认 4）；
##   · 每个槽位属于哪个队 = Cfg.game.match_team_of_slot（默认 [1,1,2,3]）；
##     **同队 = 盟友**，互相不能打，共用一个队色；
##   · 队色不再是"蓝/红"两色写死，而是 match_team_colors 里的一套（蓝/红/绿/紫…）；
##   · **显示色**（faction.color）≠ 队色：你 = 队色（蓝）、盟友 = 青、
##     敌人 = 各自队色。判据仍是 team（is_ally_of），颜色只影响"长什么样"。
##     （用户口径：同队同色分不出"我的 / 盟友的"，盟友必须能一眼认出来是青色。）
##   · 显示色落到模型上走的是资产自带的染色区（建筑的 team / team_trim、
##     单位的 M_<zone>_team），所以"按模型染色区变队色"是天然成立的。
## 建本局阵营。`slots_override` / `teams` 由主场景从**地图文件**里读出来传进来：
##   · 地图编辑器现在支持 2~12 个槽位（魔兽式），只认 Cfg.match_slots=4 的话
##     12 人图进游戏只剩 4 家，剩下的槽位对象全变成"没有阵营的死单位"。
##   · 地图里的 team 是 1 起（`PlayerSlot.team`，编辑器写入）；旧图是 0 起，
##     这里统一 max(1, team) —— 0 和 1 都当 1 队，不会把旧图的盟友拆散。
func setup_factions(slots_override: int = 0, teams: Array = [], colors: Array = []) -> void:
	var cfg: GameConfig = Cfg.game
	factions.clear()
	var slots: int = maxi(2, maxi(cfg.match_slots, slots_override))
	slots = mini(slots, 12)
	var human_slot: int = clampi(cfg.match_human_slot, 0, slots - 1)
	var diff: DifficultyDef = Cfg.difficulty(difficulty_index)
	for i in range(slots):
		var f := RtsFaction.new()
		var team: int = cfg.team_of_slot(i)
		if i < teams.size():
			team = maxi(1, int(teams[i]))
		var human: bool = i == human_slot
		var wealth: int = cfg.start_gold + (0 if human else diff.bonus_gold)
		# 颜色：0~3 号仍走 `display_color_for_slot()`（它负责"盟友显示青色"这条硬规则）；
		# 4 号以后 cfg 的队表只有 4 项、会全部拿到同一个队色，这时用**地图槽位色**
		# （编辑器 12 色表）。不要一刀切改用地图色 —— 会把盟友也染成敌方红。
		var col: Color = cfg.display_color_for_slot(i)
		if i >= 4 and i < colors.size() and colors[i] is Color:
			col = colors[i]
		f.setup(i, human, cfg.slot_name(i, team), col, wealth, cfg.start_wood)
		f.setup_cp(cfg.short_cp_start, cfg.short_cp_cap, cfg.short_cp_regen)
		f.team = team
		f.slot = i
		f.is_ai = not human
		factions.append(f)
	player_faction = factions[human_slot]
	enemy_faction = null
	for f in factions:
		if f != player_faction and player_faction.is_enemy_of(f):
			enemy_faction = f
			break
	_units.clear()
	_buildings.clear()
	_harvestables.clear()
	if squads != null:
		squads.call("reset")
	phase = RtsConst.Phase.PLANNING
	elapsed = 0.0


# ===========================================================================
# 短局：小队编组 / 布局卡槽位
# ===========================================================================

## **短局开局编组**：把地图/布局卡摆的散兵按 `squad_size` 编成小队，并登记队伍人口。
## 不编组的话 `food_used()` 会按人头算，和"训练出来的小队按队算"两套口径打架。
## 幂等：已经在某支小队里的单位跳过。
func normalize_squads() -> void:
	if not short_match or squads == null:
		return
	for f in factions:
		if f == null or not is_instance_valid(f):
			continue
		var by_id: Dictionary = {}
		for u in f.units:
			if u == null or not is_instance_valid(u) or not (u is RtsUnit):
				continue
			var ru := u as RtsUnit
			if not ru.is_alive() or ru.def == null:
				continue
			if ru.def.kind != RtsConst.Kind.UNIT:
				continue
			if f.in_squad(ru):
				continue
			var key := String(ru.def.id)
			if not by_id.has(key):
				by_id[key] = []
			(by_id[key] as Array).append(ru)
		for key in by_id.keys():
			var arr: Array = by_id[key]
			var d: UnitDef = Cfg.unit(StringName(key))
			var size: int = maxi(int(d.squad_size), 1) if d != null else 1
			var pop: int = int(d.pop_cost) if d != null else 1
			var i: int = 0
			while i < arr.size():
				var chunk: Array = []
				for k in range(size):
					if i + k < arr.size():
						chunk.append(arr[i + k])
				var sq = squads.call("create", f, chunk)
				var sid: int = int((sq as Object).get("id")) if sq != null else 0
				f.commit_squad(chunk, pop, sid)
				i += size


## 槽位 → 实体（布局卡绑定；没有 / 已损毁返回 null）
func slot_entity(slot_id: String) -> Node3D:
	if layout == null or not is_instance_valid(layout) or not layout.has_method("slot_entity"):
		return null
	return layout.call("slot_entity", slot_id) as Node3D


## 全部槽位 id（布局卡；没有布局时为空）
func slot_ids() -> Array:
	if layout == null or not is_instance_valid(layout) or not layout.has_method("slot_ids"):
		return []
	return layout.call("slot_ids")


## 槽位状态：{slot_id, id, kind, destroyed, hp, initial_hp}
func slot_state(slot_id: String) -> Dictionary:
	if layout == null or not is_instance_valid(layout) or not layout.has_method("slot_state"):
		return {}
	return layout.call("slot_state", slot_id)


## **复活一个损毁槽位**（长局火堆节点调用；恢复到 initial_hp 或指定血量）。
## 返回复活出来的节点；没有这个槽位/不该复活时返回 null。
func revive_slot(slot_id: String, hp: float = -1.0) -> Node3D:
	if layout == null or not is_instance_valid(layout) or not layout.has_method("revive_slot"):
		return null
	return layout.call("revive_slot", slot_id, hp) as Node3D


# ===========================================================================
# 队伍 / 敌我（**唯一判据**：team 相同即盟友）
# ===========================================================================

## 本局全部阵营
func all_factions() -> Array:
	return factions.duplicate()


## 某个阵营的盟友（含自己；中立队为空）
func allies_of(f: RtsFaction) -> Array:
	var out: Array = []
	if f == null:
		return out
	for o in factions:
		if o != null and o.is_ally_of(f):
			out.append(o)
	return out


## 某个阵营的敌人（所有不同队且还活着的）
func enemies_of(f: RtsFaction) -> Array:
	var out: Array = []
	if f == null:
		return out
	for o in factions:
		if o != null and f.is_enemy_of(o):
			out.append(o)
	# 野怪（中立敌对）：只要还活着就算敌人 —— 玩家的兵/箭塔才会自动还手
	if neutral_faction != null and neutral_faction != f and neutral_faction.has_forces():
		out.append(neutral_faction)
	return out


## 敌方阵营里还有大本营的（胜负判定 / AI 目标选择用）
func living_enemies_of(f: RtsFaction) -> Array:
	var out: Array = []
	for o in enemies_of(f):
		if o.has_townhall():
			out.append(o)
	return out


## 该阵营是否玩家的盟友（含自己）
func is_ally_of_player(f: RtsFaction) -> bool:
	if player_faction == null or f == null:
		return true
	return player_faction.is_ally_of(f)


## 玩家的敌人是否已经全部出局（= 玩家赢了）
func all_enemies_defeated() -> bool:
	if player_faction == null:
		return false
	for o in factions:
		if o == null:
			continue
		if not player_faction.is_enemy_of(o):
			continue
		if o.has_townhall():
			return false
	return true


## 清空（重开时用）
func reset() -> void:
	_units.clear()
	_buildings.clear()
	_harvestables.clear()
	factions.clear()
	player_faction = null
	enemy_faction = null
	neutral_faction = null
	level = null
	day_night = null
	round_control = null
	layout = null
	phase = RtsConst.Phase.PLANNING
	elapsed = 0.0
	if squads != null:
		squads.call("reset")

# ===========================================================================
# 注册表
# ===========================================================================

## 登记一个单位/建筑
func register(unit: Node) -> void:
	if unit == null:
		return
	if unit is RtsBuilding:
		if not _buildings.has(unit):
			_buildings.append(unit)
		if unit.def != null and Cfg.game != null:
			pass
	elif unit is RtsHarvestable:
		if not _harvestables.has(unit):
			_harvestables.append(unit)
		return
	if not _units.has(unit):
		_units.append(unit)
	if unit.faction != null:
		var bucket: Array = unit.faction.buildings if unit is RtsBuilding else unit.faction.units
		if not bucket.has(unit):
			bucket.append(unit)


## 注销（死亡或移除后调用）
func unregister(unit: Node) -> void:
	if unit == null:
		return
	_units.erase(unit)
	_buildings.erase(unit)
	if unit is RtsHarvestable:
		_harvestables.erase(unit)
		return
	var fac: RtsFaction = unit.faction
	if fac != null:
		fac.units.erase(unit)
		fac.buildings.erase(unit)


## 全部存活单位。
##
## ⚠ **返回的是内部数组本身，不是副本 —— 调用方只许遍历，不许增删改。**
##
## 为什么去掉 `.duplicate()`（2026-11-01 性能排查）：
##   这个函数被 头顶血条 / 小地图 / HUD / 选择 / 分离 / 索敌 等
##   十几处**每帧**调用，每次都要复制 130+ 个元素并加一遍引用计数。
##   全工程 30 个调用点没有一个会改返回值，为它们每人复制一份纯属白烧 CPU + GC。
func all_units() -> Array:
	return _units


## 全部可采集物（同上：只读，别改返回值）
func all_harvestables() -> Array:
	return _harvestables


## **全单位空间哈希**（每帧最多重建一次，全工程共用一份）。
##
## 谁在用：
##   · `RtsUnit._shared_hash()` —— 单位分离（互相推开）
##   · `find_nearest_enemy()`   —— 索敌
## 以前这两条路各建一份，等于每帧把 130 个单位桶化两遍。
## 现在只留这里一份：`Engine.get_process_frames()` 当版本号，同帧直接复用。
var _unit_hash: SpatialHash = null
var _unit_hash_frame: int = -1


func unit_hash() -> SpatialHash:
	var f: int = Engine.get_process_frames()
	if _unit_hash == null:
		_unit_hash = SpatialHash.new(4.0)
	elif _unit_hash_frame == f:
		return _unit_hash
	_unit_hash_frame = f
	_unit_hash.clear()
	for u in _units:
		if u == null or not is_instance_valid(u):
			continue
		# 死掉的先不收（墓碑/正在播死亡动画的还在 _units 里）
		if u is RtsUnit and not u.is_alive():
			continue
		_unit_hash.insert(u.global_position, u)
	return _unit_hash


## 某阵营的全部单位
func faction_units(faction: RtsFaction) -> Array:
	if faction == null:
		return []
	return faction.units.duplicate()


## **最近的**敌对阵营（兼容旧接口；多队图下"敌人"可能有 2~3 个）。
## 新代码请用 enemies_of() / living_enemies_of()，它们返回全部敌人。
func enemy_of(faction: RtsFaction) -> RtsFaction:
	if faction == null:
		return null
	var best: RtsFaction = null
	var best_d: float = INF
	for o in factions:
		if o == null or not faction.is_enemy_of(o):
			continue
		var d: float = 0.0
		if level != null and level.has_method("base_center"):
			var a: Variant = level.call("base_center", faction)
			var b: Variant = level.call("base_center", o)
			if a is Vector3 and b is Vector3:
				d = (a as Vector3).distance_squared_to(b as Vector3)
		if d < best_d:
			best_d = d
			best = o
	return best


## 从某点找最近的敌人（**扫全部敌对阵营**；半径限制；没有返回 null）
##
## ★ 2026-11-01 性能重写 —— 这是"20~40fps"的头号主犯。
##   老实现：对每个敌对阵营 `append_array` 造一个 pool 数组，再把**全部敌人**
##   逐个 `is_instance_valid() / is_alive() / global_position` 看一遍。
##   137 个单位、每人每 0.3s 索敌一次 → 每秒 6 万次三元访问 + 上千次数组分配，
##   实测单这一项 ≈120ms/秒。
##   现在：先用**空间哈希**圈出半径内的候选（4m 一格，11m 半径 ≈ 49 格，
##   候选取 10~30 个，而不是 137 个），敌我判定放到内层 —— 同阵营的候选
##   一眼就跳过，连距离都不算。
##   语义完全不变：返回半径内最近的敌人（含中立野怪，口径同 enemies_of）。
func find_nearest_enemy(from: Vector3, faction: RtsFaction, radius: float) -> Node3D:
	if faction == null or radius <= 0.0:
		return null
	var best: Node3D = null
	var best_d: float = radius * radius
	for u in unit_hash().query(from, radius):
		if u == null or not is_instance_valid(u):
			continue
		if not (u is RtsUnit):
			continue
		var other: RtsUnit = u
		var of: RtsFaction = other.faction
		if of == null or of == faction:
			continue
		# 敌我判定：不同队伍就是敌人。中立野怪（team 0）单独放行 ——
		# 它**已经出现在哈希里**就说明还活着，所以不必再问 has_forces()
		# （那个函数要遍历整个阵营，放进这个每秒几百次的循环里会白烧 CPU）。
		if not faction.is_enemy_of(of) and of != neutral_faction:
			continue
		if not other.is_alive():
			continue
		# 钻进工地内部的农民不可被锁定（魔兽口径：房子才是目标）
		if other.has_method("can_be_targeted") and not bool(other.call("can_be_targeted")):
			continue
		var d: float = from.distance_squared_to(other.global_position)
		if d < best_d:
			best_d = d
			best = other
	return best


## 找最近的资源点（指定采集类型）
func find_nearest_harvestable(from: Vector3, kind: int, origin: Vector3, max_dist: float) -> Node3D:
	var best: Node3D = null
	var best_score: float = INF
	for h in _harvestables:
		if h == null or not is_instance_valid(h):
			continue
		if h.is_depleted():
			continue
		if h.harvest_kind != kind:
			continue
		var d: float = from.distance_to(h.global_position)
		if d > max_dist:
			continue
		# 优先近的，其次离基地近的（避免农民全跑远）
		var score: float = d + origin.distance_to(h.global_position) * 0.35
		if score < best_score:
			best_score = score
			best = h
	return best


## **按"往返成本"挑资源点**（2026-11-13 玩家口径「农民别被拉到地图各处」）。
##
## 与 `find_nearest_harvestable` 的差别：那个的"远近"只看到**基地中心**的直线距离，
## 于是分基地旁边 3m 的矿永远输给 20m 外的主矿；农民于是横穿地图去挖远矿，
## 一趟 20 金币要走两分钟 —— 玩家看到的就是"采矿农民满地图乱跑、然后卡金币"。
##
## 这里的成本 = 走过去 + 背回来，且"背回来"量到**离这个矿最近的自己人交汇点**
## （主城 / 分基地 / 伐木场都算）。分基地一造好，它旁边那座矿立刻变成最优解。
##
## 顺带把 crowd（同一个点上已经有几个农民）折进去：一口矿 3 个载位，
## 挤到 8 个人只是在矿边排队，不如分散到第二座矿。
##
## `crowd` 传空时**自动统计本阵营当前盯在每个点上的采集者**（读 `_gather_node`）——
## 这是"9 个采金农民全挤在离家最近那口矿"的补丁：AI 派工时不会自己维护这份表，
## 不自动统计的话 `_assign_workers` 里每个空闲农民都会算出同一个最优矿。
func find_trip_harvestable(faction: RtsFaction, from: Vector3, kind: int,
		max_dist: float, crowd: Dictionary = {}) -> Node3D:
	if faction == null:
		return null
	var used: Dictionary = crowd
	if used.is_empty():
		used = {}
		for u in faction.units:
			if u == null or not is_instance_valid(u):
				continue
			if not u.has_method("is_alive") or not bool(u.call("is_alive")):
				continue
			# 不标注 Node3D：资源点采空会 free，带类型的赋值会抛错并中断整个函数
			var n = u.get("_gather_node")
			if n != null and is_instance_valid(n):
				used[n] = int(used.get(n, 0)) + 1
	# 交汇点先取一次（每次调用最多 3~4 个建筑），别在矿的循环里反复重建列表
	var drops: Array = RtsWorld.dropoffs(faction)
	var best: Node3D = null
	var best_score: float = INF
	for h in _harvestables:
		if h == null or not is_instance_valid(h):
			continue
		if h.is_depleted() or h.harvest_kind != kind:
			continue
		var hp: Vector3 = h.global_position
		var d: float = from.distance_to(hp)
		if d > max_dist:
			continue
		var back: float = d
		var best_back: float = INF
		for dp in drops:
			if dp == null or not is_instance_valid(dp) or not dp.is_alive():
				continue
			if dp.has_method("accepts_harvest") and not bool(dp.call("accepts_harvest", kind)):
				continue
			var dd: float = hp.distance_to(dp.global_position)
			if dd < best_back:
				best_back = dd
		if best_back < INF:
			back = best_back
		# 拥挤成本按**载位**算（金矿载位 1：第二个人起就该被推去下一座矿），
		# 资源点没实现 crowd_cost 时才退回老的"每人 14 米"口径。
		var crowd_pen: float = float(used.get(h, 0)) * 14.0
		if h.has_method("crowd_cost"):
			crowd_pen = float(h.call("crowd_cost", int(used.get(h, 0))))
		var score: float = d + back + crowd_pen
		if score < best_score:
			best_score = score
			best = h
	return best


# ===========================================================================
# 资源
# ===========================================================================

## 增加资源并广播
func add_resource(faction: RtsFaction, gold: int, wood: int) -> void:
	if faction == null:
		return
	faction.add_res(gold, wood)
	resources_changed.emit(faction)


# ===========================================================================
# 击杀归因 / 经验 / 掉落（2026-11-08）
# ===========================================================================
## 击杀日志上限（环形，只留最近的）
const KILL_LOG_MAX: int = 400
## 击杀日志：[{秒, 击杀者, 击杀者阵营, 受害者, 受害者阵营, 经验, 金, 木}]
var kill_log: Array = []
## 升星口径（经验/命名/倍率）唯一出口
const STAR := preload("res://Game/systems/升星.gd")


## **谁打死了谁**（RtsUnit._die() 调用一次）。
##
## 三条口径（玩家 2026-11-08）：
##   1. 击杀者**独得**经验（不分享），每次 15 点；
##   2. 中立敌对（team 0）死亡 → 击杀方直接拿到卡上写的金/木掉落；
##   3. 记一条击杀日志（谁杀了谁），并广播 unit_killed。
##
## 塔/建筑打死人也算"击杀方"（资源归阵营），但**经验只给兵**：
## 建筑没有星级，给它攒经验没有去处。
func on_unit_killed(victim: Node3D, killer: Node3D) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	var vd: UnitDef = victim.get("def") as UnitDef
	var vf: RtsFaction = victim.get("faction") as RtsFaction
	var ku: Node3D = null
	if killer != null and is_instance_valid(killer) and killer is RtsUnit:
		ku = killer as Node3D
	var kf: RtsFaction = ku.get("faction") as RtsFaction if ku != null else null
	var kd: UnitDef = ku.get("def") as UnitDef if ku != null else null

	var got_exp: float = 0.0
	if ku != null and kd != null and kd.kind == RtsConst.Kind.UNIT:
		if ku.has_method("gain_exp"):
			ku.call("gain_exp", STAR.KILL_EXP)
		ku.set("kill_count", int(ku.get("kill_count")) + 1)
		got_exp = STAR.KILL_EXP

	var dg: int = 0
	var dw: int = 0
	# 中立敌对 = team 0（野怪）。掉落写在中立那边的卡上，谁打死归谁。
	if vf != null and int(vf.team) == 0 and kf != null and vd != null:
		dg = int(vd.drop_gold)
		dw = int(vd.drop_wood)
		if dg > 0 or dw > 0:
			add_resource(kf, dg, dw)
			if kf == player_faction:
				toast("击杀 %s　+%d 金 +%d 木" % [vd.display_name, dg, dw],
						Color(0.96, 0.82, 0.42))

	var rec: Dictionary = {
		"秒": snappedf(elapsed, 0.1),
		"击杀者": kd.display_name if kd != null else "—",
		"击杀者阵营": kf.display_name if kf != null else "—",
		"受害者": vd.display_name if vd != null else "—",
		"受害者阵营": vf.display_name if vf != null else "—",
		"经验": got_exp, "金": dg, "木": dw,
	}
	kill_log.append(rec)
	if kill_log.size() > KILL_LOG_MAX:
		kill_log.remove_at(0)
	if _kill_log_on():
		print("[击杀] %s（%s）击杀 %s（%s）+%.0f经验 +%d金 +%d木" % [
			rec["击杀者"], rec["击杀者阵营"], rec["受害者"], rec["受害者阵营"],
			got_exp, dg, dw])
	unit_killed.emit(victim, killer)


func _kill_log_on() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--kill-log":
			return true
	return false


## **阵营当前主城等级**（升本机制的唯一出口）。
##
## 取该阵营**所有建筑里最高的 tier**（大本营 1 = 一本 / 2 = 二本），
## 没有大本营时按 1 算（不至于把兵营直接锁死）。
## 兵种卡 `require_tier` 与它比大小 —— 不要在别处再写一遍这个判断。
func faction_tier(f: RtsFaction) -> int:
	if f == null:
		return 1
	var best: int = 1
	for b in f.buildings:
		if b == null or not is_instance_valid(b):
			continue
		var d: UnitDef = b.get("def") as UnitDef
		if d == null:
			continue
		best = maxi(best, maxi(int(d.tier), 1))
	return best


## 能不能造。
## **短局只认 CP + 人口**；长局仍是金 + 木 + 人口。两套资源不混。
func can_afford(faction: RtsFaction, unit_id: StringName) -> bool:
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null or faction == null:
		return false
	if short_match:
		if d.cp_cost > 0 and faction.cp + 0.0001 < float(d.cp_cost):
			return false
		return faction.has_food(d.pop_cost)
	return faction.can_afford(d) and faction.has_food(d.food_cost)


## **建造门槛**：这张建筑卡要求的主城等级够不够（2026-11-13）。
##
## 玩家口径：「车坊和神秘圣地调整到二本才能建造」。门槛写在建筑卡上
## （`BuildingCard.require_tier`，0 = 一本就能造），判断只认这一个出口：
##   · 指令系统：真正落地前拦一道，给中文提示；
##   · 命令卡：按钮灰掉 + tooltip 说明；
##   · AI：不把这个建筑报进诉求，免得反复尝试浪费预算。
## 升二本 = 大本营换成「联盟要塞」（def.tier = 2），见 `faction_tier()`。
func tier_allows(faction: RtsFaction, id: StringName) -> bool:
	var d: UnitDef = Cfg.unit(id)
	if d == null:
		return false
	if int(d.require_tier) <= 0:
		return true
	return faction_tier(faction) >= int(d.require_tier)


## 扣费（含人口检查）；失败返回 false。
## 短局走 CP，长局走金木——调用方（训练/建造）不需要知道当前是哪套。
func pay(faction: RtsFaction, unit_id: StringName) -> bool:
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null or faction == null:
		return false
	if not faction.has_food(d.pop_cost if short_match else d.food_cost):
		return false
	if short_match:
		if not faction.pay_cp(d.cp_cost):
			return false
	else:
		if not faction.pay(d):
			return false
	resources_changed.emit(faction)
	return true


## 退款。**必须和 pay 对称**：短局退 CP，长局退金木。
## 取消训练/取消工地都走这里，不要在业务里直接 add_resource。
func refund(faction: RtsFaction, unit_id: StringName) -> void:
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null or faction == null:
		return
	if short_match:
		faction.add_cp(d.cp_cost)
	else:
		faction.add_res(d.gold_cost, d.wood_cost)
	resources_changed.emit(faction)


# ===========================================================================
# 生成
# ===========================================================================

## 生成一个单位/建筑。parent 为空时挂到关卡节点。
## proc：程序化外观参数（树用，{"season","seed","yaw"}），其它单位传空字典即可。
## 返回生成出来的节点（失败返回 null）。
func spawn_unit(faction: RtsFaction, unit_id: StringName, pos: Vector3,
		parent: Node3D = null, proc: Dictionary = {}) -> Node3D:
	var d: UnitDef = Cfg.unit(unit_id)
	if d == null:
		push_warning("[游戏] 未知单位 id: %s" % unit_id)
		return null
	if parent == null:
		parent = level if level != null else get_tree().current_scene
	if parent == null:
		return null

	var node: Node3D = null
	if d.kind == RtsConst.Kind.BUILDING:
		node = RtsBuilding.new()
	elif d.kind == RtsConst.Kind.HARVESTABLE:
		node = RtsHarvestable.new()
	else:
		node = RtsUnit.new()

	# 名字里的序号用**自增计数器**，不用 Time.get_ticks_usec()：后者是墙钟，
	# 同 seed 复跑会得到不同的节点名，任何"按名字排序/查重"的地方都会跟着漂。
	_spawn_seq += 1
	node.name = "%s_%d" % [String(unit_id), _spawn_seq]
	node.position = pos
	parent.add_child(node)
	# 只有可采集物认 proc（树的品种/种子）；建筑/单位走原来的两参数 setup
	if node is RtsHarvestable:
		(node as RtsHarvestable).setup(faction, d, proc)
	else:
		node.setup(faction, d)
	register(node)
	unit_spawned.emit(node)
	return node


# ===========================================================================
# 结束 / 提示
# ===========================================================================

## 玩家胜利。set_phase 会暂停世界（HUD 是 ALWAYS，遮罩照样能显示）。
func trigger_victory() -> void:
	if phase == RtsConst.Phase.RUNNING or phase == RtsConst.Phase.PLANNING:
		if layout != null and is_instance_valid(layout) and layout.has_method("capture_and_save"):
			layout.call("capture_and_save")
		set_phase(RtsConst.Phase.VICTORY)
		game_over.emit(true)


## 玩家失败
func trigger_defeat() -> void:
	if phase == RtsConst.Phase.RUNNING or phase == RtsConst.Phase.PLANNING:
		if layout != null and is_instance_valid(layout) and layout.has_method("capture_and_save"):
			layout.call("capture_and_save")
		set_phase(RtsConst.Phase.DEFEAT)
		game_over.emit(false)


## 顶部提示（信号 notify 的便捷入口；信号与函数不能同名，所以函数叫 toast）
func toast(text: String, color: Color = Color.WHITE) -> void:
	notify.emit(text, color)


## 请求镜头抖动
func shake(strength: float) -> void:
	camera_shake.emit(strength)


## 重开一局
func restart() -> void:
	reset()
	get_tree().paused = false
	get_tree().reload_current_scene()
