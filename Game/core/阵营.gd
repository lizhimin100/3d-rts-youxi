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
## 浮点存储，避免 0.8/秒 的回复被整数截断；显示时取整。
var cp: float = 0.0
var cp_cap: float = 24.0
var cp_regen: float = 0.8

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


## 每帧回复（只在执行阶段由 Game 调用；准备阶段冻结）
func tick_cp(dt: float) -> void:
	if cp_regen <= 0.0 or cp >= cp_cap:
		return
	cp = minf(cp + cp_regen * maxf(dt, 0.0), cp_cap)


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


## 当前人口占用（所有存活单位的 food_cost 之和）
func food_used() -> int:
	var total: int = 0
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


## 训练队列已经"预定"的人口。
## 只看已出队单位会漏掉排队中的部队：上限 20 / 已用 18 时还能连排 5 个 2 人口的兵，
## 出队瞬间直接 28/20。把队列里的 food_cost 一起算进占用，排队时就该卡住。
func food_reserved() -> int:
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
				total += d.food_cost
	return total


## 人口是否够用（已用 + 队列预定 + 本次申请）
func has_food(amount: int) -> bool:
	return Economy.has_food(food_used(), food_reserved(), amount, food_cap())


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
