class_name RtsFaction
extends RefCounted

## 经济规则（能不能付 / 扣多少 / 人口够不够）的唯一实现在 Model 层
const Economy := preload("res://Model/core/economy.gd")
## **阵营**：一个玩家（或 AI）的全部资产与资源。
## 玩家与 AI 都只有一个 RtsFaction，经济/军队全挂在这里。
## 由 Lead 提供，其他人只读/调用，不要改这个文件。

# 阵营索引 = **出生点槽位号**（0..N-1）。0 号是玩家，其它是 AI / 盟友。
var index: int = RtsConst.Faction.PLAYER
## 是否人类玩家（否则是 AI）。**只表示"由人操作"**，
## 盟友 AI 也是 false —— 提示语/训练倍率都靠它区分，不能拿它当敌我判据。
var is_player: bool = true
## 名字（界面显示）
var display_name: String = "玩家"
## **显示色**（模型染色 / 小地图点 / 选中圈 / 血条都吃它）。
## 由 Cfg.game.display_color_for_slot() 定：**你 = 队色（蓝）/ 盟友 = 青 / 敌人 = 各自队色**。
## 队色本身仍然是"队伍"属性（同队同色），但显示层把盟友单独拎成青色，
## 否则"一圈蓝点"里分不出自己的兵和盟友的兵（用户明确要求盟友改青）。
var color: Color = Color.WHITE

# ---------------------------------------------------------------------------
# 队伍（多队图的核心字段）
# ---------------------------------------------------------------------------
## 运行时取配置单例（**不要写裸 `Cfg`**，理由见 战斗.gd:cfg_node）
static func cfg_node() -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Cfg")
	return null


## 队伍编号（1 起）。**同号 = 盟友**：不许互相攻击、可以共用一个队色。
var team: int = 1
## 出生点槽位号（和 index 同值，语义上更明确）
var slot: int = 0
## 是否 AI 指挥（is_player 的补集）
var is_ai: bool = true
## **和平中立**（地图编辑器里的「中立」）：对任何人不敌对，也不参与胜负。
## 和「中立敌对」（team 0 野怪）是两回事：
##   · 中立：装饰性营地/商人/中立建筑，谁都别打它；
##   · 中立敌对：野怪，所有人都能打，它也会打所有人。
var passive: bool = false


## 是不是"我方阵营"（人类玩家本人的那个阵营）
func is_human() -> bool:
	return is_player


## 与另一个阵营是否同队（同队 = 盟友；自己和自己也算同队）
func is_ally_of(other: RtsFaction) -> bool:
	if other == null:
		return false
	return team == other.team


## 与另一个阵营是否敌对（不同队 = 敌人；中立（team 0）对所有人敌对）
func is_enemy_of(other: RtsFaction) -> bool:
	if other == null or other == self:
		return false
	# 和平中立：双向不敌对（`passive` 只在地图编辑器摆的「中立」阵营上为真）
	if passive or other.passive:
		return false
	return team != other.team

# --- 资源 ---
var gold: int = 0
var wood: int = 0

# --- 短局指挥点（CP）---
## 浮点存储（以后如果要加"半 CP"也不用改口径）；显示时取整。
## 2026-11-15 玩家拍板：CP **只在规划阶段出现并消耗**；每回合规划阶段由基地补满，
## 上回合剩余清零；执行阶段不回复、不显示、不能花。
var cp: float = 0.0
var cp_cap: float = 24.0
## 已停用（保留字段只为旧 JSON 能读）：CP 不再按秒回复。
var cp_regen: float = 0.0

# --- 单位集合（由 游戏 维护）---
## Array[RtsUnit]
var units: Array = []
## Array[RtsBuilding]
var buildings: Array = []


## 装配初始资源
func setup(p_index: int, p_is_player: bool, p_name: String, p_color: Color, p_gold: int, p_wood: int) -> void:
	index = p_index
	is_player = p_is_player
	display_name = p_name
	color = p_color
	gold = p_gold
	wood = p_wood


## 装配短局 CP（开局/上限/每秒回复）
func setup_cp(p_start: int, p_cap: int, p_regen: float) -> void:
	cp_cap = maxf(float(p_cap), 1.0)
	cp = clampf(float(p_start), 0.0, cp_cap)
	cp_regen = maxf(p_regen, 0.0)


## **每回合规划阶段由基地补满 CP**（上回合剩余清零，不是累加）。
## 唯一调用点：回合控制.end_execution() / 开局 setup_factions()。
func begin_planning_cp(grant: int = -1) -> void:
	var v: float = cp_cap if grant < 0 else float(grant)
	cp = clampf(v, 0.0, cp_cap)


## 兼容旧调用名：不再按秒回复（执行阶段 CP 冻结且不可花）。
func tick_cp(_dt: float) -> void:
	pass


## 付 CP（不够一分不扣）
func pay_cp(amount: int) -> bool:
	var need: float = maxf(float(amount), 0.0)
	if cp + 0.0001 < need:
		return false
	cp = maxf(cp - need, 0.0)
	return true


## 退 CP
func add_cp(amount: int) -> void:
	cp = clampf(cp + float(amount), 0.0, cp_cap)


# --- 短局小队人口账本（2026-11-15）---
## 每支已出生小队一条：{"pop": 8, "members": [RtsUnit...], "squad_id": 3}
## 人口按**小队**算（步兵 5 人一队占 8，不是每人 1.6）：成员减员不退还，
## 整队打光才释放。"留一个残兵也占着一队人口"是明确的战场代价。
var squad_commits: Array = []
# --- 短局建造订单（规划阶段下单，执行阶段只认这些单）---
## 每条：{"id": StringName, "site_id": int}；site_id = 0 表示工地已取消、可重新选址。
var build_orders: Array = []


## 取自动加载 `Game`（**不要写裸 `Game`**：--script 自检在 autoload 注册前编译依赖链，
## 裸引用会整条编译失败 → RtsFaction 退化成 RefCounted，setup/pay 全部不存在）。
static func game_node() -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("Game")
	return null


## 是不是短局（CP/人口/小队口径只在短局生效；长局保持旧经济）
func is_short() -> bool:
	var g := game_node()
	return g != null and bool(g.get("short_match"))


## 登记一支刚出生/刚编组的小队（训练出队、开局编组都走这里）
func commit_squad(members: Array, pop: int, squad_id: int = 0) -> void:
	if members.is_empty() or pop <= 0:
		return
	squad_commits.append({"pop": int(pop), "members": members.duplicate(), "squad_id": squad_id})


## 小队人口剪枝：整队死光/失效才释放。返回释放的人口。
func prune_squads() -> int:
	var kept: Array = []
	var released: int = 0
	for rec in squad_commits:
		var alive: bool = false
		for m in rec.get("members", []):
			if m != null and is_instance_valid(m) and m.has_method("is_alive") and bool(m.call("is_alive")):
				alive = true
				break
		if alive:
			kept.append(rec)
		else:
			released += int(rec.get("pop", 0))
	squad_commits = kept
	return released


## 这个单位是否已经被某支小队登记过（避免"小队人口 + 单兵 food_cost"重复计）
func in_squad(u: Node) -> bool:
	for rec in squad_commits:
		if (rec.get("members", []) as Array).has(u):
			return true
	return false


## 当前**已用人口**。
## 短局 = 小队人口 + 不在小队里的单兵 food_cost + 存活建筑的 pop_cost；
## 长局 = 所有存活单位的 food_cost（旧口径，一行没改）。
## UI 不要直接拿它当"已用"显示 —— 用 `food_committed()`（含在训）。
func food_used() -> int:
	var total: int = 0
	if is_short():
		prune_squads()
		for rec in squad_commits:
			total += int(rec.get("pop", 0))
		for u in units:
			if u == null or not is_instance_valid(u) or not u.is_alive():
				continue
			if in_squad(u):
				continue
			var d: UnitDef = u.def
			if d != null:
				total += d.food_cost
		# 建筑占人口（基地 / 农场 pop_cost = 0，不占；兵营/铁匠铺等占）
		for b in buildings:
			if b == null or not is_instance_valid(b) or not b.is_alive():
				continue
			var bd: UnitDef = b.def
			if bd != null:
				total += bd.pop_cost
		return total
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive():
			continue
		var d: UnitDef = u.def
		if d != null:
			total += d.food_cost
	return total


## 人口上限（**已完工**建筑的 food_provided 之和）。
## 工地不算：农场刚放下就立刻 +8 人口的话，"建造过程"等于不存在，
## 而且会把"人口满了再造农场"这条博弈直接抹掉。
func food_cap() -> int:
	var total: int = 0
	for b in buildings:
		if b == null or not is_instance_valid(b):
			continue
		var built: Variant = b.get("is_constructed")
		if built is bool and not bool(built):
			continue
		var d: UnitDef = b.def
		if d != null:
			total += d.food_provided
	return total


## **在训人口**：训练队列里已下单、还没出队的单位占的 food_cost 之和。
##
## 2026-11-15 口径（玩家拍板）：**取消"预留人口"这个说法** ——
## 规划阶段点下训练的那一瞬间就扣 CP、同时**立刻算进"已用人口"**。
## 所以这个函数只是 `food_used()` 的一个增量项，对外统一走 `food_committed()`。
func food_queued() -> int:
	var total: int = 0
	for b in buildings:
		if b == null or not is_instance_valid(b):
			continue
		var q: Variant = b.get("train_queue")
		if q == null or not (q is Array):
			continue
		# ★ 同 战斗.gd：不写裸 `Cfg`（`--script` 自检模式下会在 autoload 之前编译整个依赖链）
		var cn: Node = cfg_node()
		for id in (q as Array):
			var d: UnitDef = cn.call("unit", id) if cn != null else null
			if d != null:
				# 短局：一次下单 = 一支小队，按队伍人口算（不是人头）
				total += d.pop_cost if is_short() else d.food_cost
	return total


## **已用人口 = 存活单位 + 在训队列**。界面上那个 `当前已用/上限` 的唯一出口。
## 为什么把队列算进"已用"：规划阶段下单即占，玩家看到 6/30 就是"这 6 人口已经被我花掉了"，
## 不需要再理解"预留"这层概念。
func food_committed() -> int:
	return food_used() + food_queued()


## 人口是否够用（已用（含在训）+ 本次申请 <= 上限）。
## 申请 0 人口（农场/大本营）永远放行：否则"被拆光了农场、人口超上限"时
## 连 0 人口的农场都造不出来 —— 玩家会被永久卡死（2026-11-15 自查发现）。
func has_food(amount: int) -> bool:
	if amount <= 0:
		return true
	return Economy.has_food(food_committed(), 0, amount, food_cap())


# ===========================================================================
# 短局建造订单（规划阶段下单 → 执行阶段只能施工这些单）
# ===========================================================================

## 记一条建造订单。`site` 为空 = 只下单还没落地（执行阶段可"只订单不选址"）。
func plan_build_order(id: StringName, site: Node = null) -> void:
	build_orders.append({
		"id": id,
		"site_id": int((site as Node).get_instance_id()) if site != null else 0,
	})


## 把某个工地绑到已有订单上（工地落地时调用）。没有对应订单返回 false。
func bind_build_site(site: Node) -> bool:
	if site == null or not is_instance_valid(site):
		return false
	var sd: Variant = site.get("def")
	var id: StringName = StringName(String(sd.get("id"))) if sd != null else &""
	for i in range(build_orders.size() - 1, -1, -1):
		var rec: Dictionary = build_orders[i]
		if StringName(rec.get("id", &"")) != id:
			continue
		if int(rec.get("site_id", 0)) != 0:
			continue
		build_orders[i] = {"id": id, "site_id": int(site.get_instance_id())}
		return true
	return false


## 工地在列表里的下标（没有返回 -1）
func find_build_order(site: Node) -> int:
	if site == null or not is_instance_valid(site):
		return -1
	var sid: int = int(site.get_instance_id())
	for i in build_orders.size():
		if int((build_orders[i] as Dictionary).get("site_id", 0)) == sid:
			return i
	return -1


## 规划阶段撤销工地（退了 CP）：订单整条删掉，不能靠它白嫖第二座。
func drop_build_site(site: Node) -> bool:
	var i: int = find_build_order(site)
	if i < 0:
		return false
	build_orders.remove_at(i)
	return true


## 工地被取消：订单不消失，回到"可重新选址"（不退 CP）
func release_build_site(site: Node) -> bool:
	var i: int = find_build_order(site)
	if i < 0:
		return false
	var rec: Dictionary = build_orders[i]
	build_orders[i] = {"id": rec.get("id", &""), "site_id": 0}
	return true


## 还有几条"已下单、未落地/被取消"的某建筑订单（执行阶段允许落地的数量）
func open_build_orders(id: StringName = &"") -> int:
	var n: int = 0
	for rec in build_orders:
		var r: Dictionary = rec
		if int(r.get("site_id", 0)) != 0:
			continue
		if id == &"" or StringName(r.get("id", &"")) == id:
			n += 1
	return n


## 消耗一条未落地订单（执行阶段重新选址时用）。成功返回 true。
func take_open_build_order(id: StringName) -> bool:
	for i in build_orders.size():
		var r: Dictionary = build_orders[i]
		if int(r.get("site_id", 0)) != 0:
			continue
		if StringName(r.get("id", &"")) != id:
			continue
		return true
	return false


## 资源是否够
func can_afford(def: UnitDef) -> bool:
	if def == null:
		return false
	return Economy.can_afford(gold, wood, def.gold_cost, def.wood_cost)


## 扣除资源（先检查再扣；成功返回 true）
func pay(def: UnitDef) -> bool:
	if def == null:
		return false
	var state := {"gold": gold, "wood": wood}
	if not Economy.pay(state, def.gold_cost, def.wood_cost):
		return false
	gold = int(state["gold"])
	wood = int(state["wood"])
	return true


## 增加资源
func add_res(p_gold: int, p_wood: int) -> void:
	var state := {"gold": gold, "wood": wood}
	Economy.add(state, p_gold, p_wood)
	gold = int(state["gold"])
	wood = int(state["wood"])


## 存活单位数量（可选按 id 过滤）
func count_units(id: StringName = &"") -> int:
	var n: int = 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.is_alive():
			continue
		if id == &"" or u.def.id == id:
			n += 1
	return n


## 存活建筑数量
func count_buildings(id: StringName = &"") -> int:
	var n: int = 0
	for b in buildings:
		if b == null or not is_instance_valid(b):
			continue
		if not b.is_alive():
			continue
		if id == &"" or b.def.id == id:
			n += 1
	return n


## 还有没有主城（胜负判定用）。
##
## ★ 2026-11-13 修：旧实现只数 `townhall`，而**升二本**会把主城换成 `townhall_2`
##   （见 建筑改造.ROUTES）。于是"升级读完的那一瞬间 → has_townhall() = false →
##   主场景立刻判负"——玩家花钱升级等于自杀。AI 自动升本那天一局 33 秒就结束了。
## 口径改成**按能力认主城**：是资源交汇点、金木全收、还提供人口。
## 不写任何 id，所以以后加"三本城堡"也不用回来改这里。
func has_townhall() -> bool:
	for b in buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		if not b.def.is_dropoff:
			continue
		if not b.def.dropoff_kinds.is_empty():
			continue    # 伐木场这类"只收一种"的不算主城
		if b.def.food_provided <= 0:
			continue
		return true
	return false


## 还有没有任何活着的兵力/建筑（野怪阵营用：全清完就不再算"敌人"）
func has_forces() -> bool:
	if count_units() > 0:
		return true
	return count_buildings() > 0


## 玩家阵营的调试字符串
func debug_string() -> String:
	return "[%s] 金=%d 木=%d 人口=%d/%d 单位=%d 建筑=%d" % [
		display_name, gold, wood, food_used(), food_cap(), count_units(), count_buildings()
	]
