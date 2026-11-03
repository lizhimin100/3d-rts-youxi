@tool
class_name UnitTable
extends RefCounted
## **全部数值表**：单位、建筑、可采集物的定义 + 三档难度参数。
## 这里是唯一的数值来源（GameConfig 只是容器）。想让游戏更难/更快/更肉，改这里。
##
## 调用：
##     var cfg := GameConfig.new()
##     cfg.units = UnitTable.build_units()
##     cfg.difficulties = UnitTable.build_difficulties()

# 模型目录（美术由 Blender 程序化生成）
const MODEL_DIR := "res://美术/模型/"


## 搭建全部单位定义
static func build_units() -> Dictionary:
	var out: Dictionary = {}

	# =======================================================================
	# 农民 —— 经济核心，能采集、能建造、能修，弱鸡战斗力
	# =======================================================================
	var peasant := UnitDef.new()
	peasant.id = &"peasant"
	peasant.display_name = "农民"
	peasant.kind = RtsConst.Kind.UNIT
	# 2026-11-01：农民换成「方块人」v2（带骨骼 + 9 段动作：walk/idle/attack/carry_gold/carry_wood/hurt/death…）
	peasant.model_path = MODEL_DIR + "方块人/方块人_农民.glb"
	peasant.anim_set = RtsConst.AnimSet.WORKER
	peasant.role = &"worker"
	peasant.max_hp = 230.0
	peasant.armor = 0.0
	peasant.armor_type = RtsConst.ArmorType.LIGHT
	peasant.attack_damage = 6.0
	peasant.attack_spread = 1.0
	peasant.attack_cooldown = 1.8
	peasant.attack_range = 1.1
	peasant.attack_type = RtsConst.DamageType.NORMAL
	peasant.move_speed = 4.3
	peasant.turn_speed = 9.0
	peasant.body_radius = 0.42
	peasant.selection_radius = 0.72
	peasant.sight_range = 9.0
	peasant.acquire_range = 5.0
	peasant.gold_cost = 75
	peasant.wood_cost = 0
	# 农民**不占人口**：副官/玩家可以放心爆农，人口永远留给军队。
	# （农场只服务战斗单位，这条改动让"多造农民"不再是经济自杀。）
	peasant.food_cost = 0
	peasant.train_time = 11.0
	peasant.height = 1.62
	peasant.gather_rate = 3.0
	peasant.carry_capacity = 10
	out[&"peasant"] = peasant

	# =======================================================================
	# 步兵 —— 前排肉盾，重甲高血，打建筑慢
	# =======================================================================
	# 2026-10-31：模型换成「方块人_v2」（E:\美术资源\个人资产\方块人_v2 导出）。
	# 它的三颗材质名正好是 主体 / team / team_trim —— 和铁誓军团建筑资产同一套契约，
	# 所以染色、队色、图集过滤（NEAREST）全部走 WarbandStyle（建筑那条路），
	# 单位不再过 MatKit 卡通 shader。
	var footman := UnitDef.new()
	footman.id = &"footman"
	footman.display_name = "步兵"
	footman.kind = RtsConst.Kind.UNIT
	footman.model_path = MODEL_DIR + "方块人/方块人_联盟步兵.glb"
	footman.anim_set = RtsConst.AnimSet.MELEE
	footman.role = &"frontline"
	footman.tags = [&"heavy"]
	footman.max_hp = 430.0
	footman.armor = 5.0
	footman.armor_type = RtsConst.ArmorType.HEAVY
	footman.attack_damage = 15.0
	footman.attack_spread = 3.0
	footman.attack_cooldown = 1.3
	footman.attack_range = 1.35
	footman.attack_type = RtsConst.DamageType.NORMAL
	footman.move_speed = 4.6
	footman.turn_speed = 10.0
	footman.body_radius = 0.5
	footman.selection_radius = 0.82
	footman.sight_range = 11.0
	footman.acquire_range = 11.0
	footman.gold_cost = 135
	footman.food_cost = 2
	footman.train_time = 18.0
	footman.height = 1.78
	out[&"footman"] = footman

	# =======================================================================
	# 弓箭手 —— 远程穿刺，脆皮，克制轻甲
	# =======================================================================
	var archer := UnitDef.new()
	archer.id = &"archer"
	archer.display_name = "弓箭手"
	archer.kind = RtsConst.Kind.UNIT
	# 2026-11-01：弩手（archer）换成「方块人_弩兵」（shoot/reload/idle_b 三段远程动作齐全）
	archer.model_path = MODEL_DIR + "方块人/方块人_弩兵.glb"
	archer.anim_set = RtsConst.AnimSet.ARCHER
	archer.role = &"ranged"
	archer.tags = [&"light"]
	archer.max_hp = 310.0
	archer.armor = 2.0
	archer.armor_type = RtsConst.ArmorType.LIGHT
	archer.attack_damage = 19.0
	archer.attack_spread = 4.0
	archer.attack_cooldown = 1.7
	archer.attack_range = 11.0
	archer.attack_type = RtsConst.DamageType.PIERCE
	archer.projectile = RtsConst.Projectile.ARROW
	archer.projectile_speed = 26.0
	archer.move_speed = 4.4
	archer.turn_speed = 10.0
	archer.body_radius = 0.44
	archer.selection_radius = 0.75
	archer.sight_range = 13.0
	archer.acquire_range = 12.0
	archer.gold_cost = 130
	archer.wood_cost = 15
	archer.food_cost = 2
	archer.train_time = 20.0
	archer.height = 1.72
	out[&"archer"] = archer

	# =======================================================================
	# 法师 —— 魔法远程 + 火球 AOE 技能，最能出特效的单位
	# =======================================================================
	var mage := UnitDef.new()
	mage.id = &"mage"
	mage.display_name = "法师"
	mage.kind = RtsConst.Kind.UNIT
	mage.model_path = MODEL_DIR + "法师.glb"
	mage.anim_set = RtsConst.AnimSet.MAGE
	mage.role = &"caster"
	mage.tags = [&"light", &"support"]
	mage.max_hp = 270.0
	mage.armor = 0.0
	mage.armor_type = RtsConst.ArmorType.NONE
	mage.attack_damage = 20.0
	mage.attack_spread = 3.0
	mage.attack_cooldown = 2.0
	mage.attack_range = 10.0
	mage.attack_type = RtsConst.DamageType.MAGIC
	mage.projectile = RtsConst.Projectile.FIREBOLT
	mage.projectile_speed = 18.0
	mage.move_speed = 4.0
	mage.turn_speed = 8.0
	mage.body_radius = 0.44
	mage.selection_radius = 0.75
	mage.sight_range = 13.0
	mage.acquire_range = 11.0
	mage.gold_cost = 155
	mage.wood_cost = 45
	mage.food_cost = 3
	mage.train_time = 28.0
	mage.height = 1.80
	mage.abilities = [&"fireball"]
	mage.ability_cooldown = 9.0
	# 法力（界面上那条"蓝条"）：没有法力的单位 max_mana = 0，UI 就不画蓝条。
	mage.max_mana = 120.0
	mage.mana_regen = 3.2
	mage.mana_cost = 45.0
	out[&"mage"] = mage

	# =======================================================================
	# 大本营 —— 资源交汇点 + 农民产地 + 人口来源；被拆即败
	# =======================================================================
	var townhall := UnitDef.new()
	townhall.id = &"townhall"
	townhall.display_name = "大本营"
	townhall.kind = RtsConst.Kind.BUILDING
	townhall.model_path = MODEL_DIR + "大本营.glb"
	# ★ 铁誓军团资产包 v1：模型按"1 unit = 1 m"做但整体大一号（实测 18.1 × 9.0 × 25.2），
	#   统一 ×0.5 落到游戏尺度：高 12.6m、占地 9×5。
	townhall.model_scale = 0.5
	townhall.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	townhall.max_hp = 2600.0
	townhall.armor = 6.0
	townhall.armor_type = RtsConst.ArmorType.FORTIFIED
	townhall.footprint = Vector2i(9, 5)
	townhall.height = 12.6
	townhall.is_dropoff = true
	townhall.food_provided = 24
	townhall.trains = [&"peasant"]
	townhall.train_time = 11.0
	townhall.sight_range = 15.0
	townhall.body_radius = 3.0
	townhall.selection_radius = 5.6
	out[&"townhall"] = townhall

	# =======================================================================
	# 兵营 —— 出步兵/弓手/法师
	# =======================================================================
	var barracks := UnitDef.new()
	barracks.id = &"barracks"
	barracks.display_name = "兵营"
	barracks.kind = RtsConst.Kind.BUILDING
	barracks.model_path = MODEL_DIR + "兵营.glb"
	# 资产包实测 11.1 × 14.7 × 11.6 → ×0.5
	barracks.model_scale = 0.5
	barracks.anim_set = RtsConst.AnimSet.MILITARY_BUILDING
	barracks.max_hp = 1500.0
	barracks.armor = 5.0
	barracks.armor_type = RtsConst.ArmorType.FORTIFIED
	barracks.footprint = Vector2i(6, 7)
	barracks.height = 5.8
	# 法师移到「神秘圣地」—— 一座建筑只管一件事，兵营不再什么都出。
	barracks.trains = [&"footman", &"archer"]
	barracks.train_time = 18.0
	barracks.sight_range = 12.0
	barracks.body_radius = 2.8
	barracks.selection_radius = 4.4
	barracks.gold_cost = 180
	barracks.wood_cost = 60
	barracks.train_time = 30.0
	out[&"barracks"] = barracks

	# =======================================================================
	# 铁匠铺 —— 攻防升级
	# =======================================================================
	var blacksmith := UnitDef.new()
	blacksmith.id = &"blacksmith"
	blacksmith.display_name = "铁匠铺"
	blacksmith.kind = RtsConst.Kind.BUILDING
	blacksmith.model_path = MODEL_DIR + "铁匠铺.glb"
	# 资产包实测 9.9 × 11.8 × 11.8 → ×0.5
	blacksmith.model_scale = 0.5
	blacksmith.anim_set = RtsConst.AnimSet.MILITARY_BUILDING
	blacksmith.max_hp = 1300.0
	blacksmith.armor = 4.0
	blacksmith.armor_type = RtsConst.ArmorType.FORTIFIED
	blacksmith.footprint = Vector2i(5, 6)
	blacksmith.height = 5.9
	blacksmith.researches = [&"attack_up", &"armor_up"]
	blacksmith.sight_range = 11.0
	blacksmith.body_radius = 2.6
	blacksmith.selection_radius = 4.2
	blacksmith.gold_cost = 140
	blacksmith.wood_cost = 50
	blacksmith.train_time = 25.0
	out[&"blacksmith"] = blacksmith

	# =======================================================================
	# 农场 —— 提供人口
	# =======================================================================
	var farm := UnitDef.new()
	farm.id = &"farm"
	farm.display_name = "农场"
	farm.kind = RtsConst.Kind.BUILDING
	farm.model_path = MODEL_DIR + "农场.glb"
	# 资产包实测 15.4 × 12.8 × 10.1 → ×0.5
	farm.model_scale = 0.5
	farm.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	farm.max_hp = 750.0
	farm.armor = 3.0
	farm.armor_type = RtsConst.ArmorType.FORTIFIED
	farm.footprint = Vector2i(8, 7)
	farm.height = 5.1
	farm.food_provided = 8
	farm.sight_range = 8.0
	farm.body_radius = 3.2
	farm.selection_radius = 4.6
	farm.gold_cost = 80
	farm.wood_cost = 20
	farm.train_time = 20.0
	out[&"farm"] = farm

	# =======================================================================
	# 箭塔 —— **有攻击**的防御塔，但视野比哨塔小（它是"箭"，不是"哨"）
	# =======================================================================
	var tower := UnitDef.new()
	tower.id = &"tower"
	tower.display_name = "箭塔"
	tower.kind = RtsConst.Kind.BUILDING
	tower.model_path = MODEL_DIR + "箭塔.glb"
	# 资产包实测 7.1 × 7.0 × 17.5 → ×0.5
	tower.model_scale = 0.5
	tower.anim_set = RtsConst.AnimSet.TOWER
	tower.role = &"defense"
	tower.max_hp = 1050.0
	tower.armor = 6.0
	tower.armor_type = RtsConst.ArmorType.FORTIFIED
	tower.footprint = Vector2i(4, 4)
	tower.height = 8.7
	tower.attack_damage = 22.0
	tower.attack_spread = 4.0
	tower.attack_cooldown = 1.5
	tower.attack_range = 13.0
	tower.attack_type = RtsConst.DamageType.PIERCE
	tower.projectile = RtsConst.Projectile.ARROW
	tower.projectile_speed = 28.0
	tower.acquire_range = 13.0
	# ★ 视野必须**小于哨塔（20）**：两座塔的分工是"看得远"和"打得着"，
	#   数值再不区分开，玩家只会觉得多花 40 金买了个更差的哨塔。
	tower.sight_range = 12.0
	tower.body_radius = 1.6
	tower.selection_radius = 2.4
	tower.gold_cost = 130
	tower.wood_cost = 70
	tower.train_time = 25.0
	out[&"tower"] = tower

	# =======================================================================
	# 铁誓资产包 v1 新增的四座（美术已就位，玩法待定）
	# =======================================================================
	# 这四座是本次资产包带来的**新建筑**。玩法数值先按"同类建筑的合理量级"给一套，
	# 不接任何生产/研究（trains / researches 留空）—— 先把美术塞进游戏能看、能摆，
	# 等设计定下来再往这里填功能，不用再动美术资源。
	# ---- 哨塔：**只负责看**的自卫建筑（大视野 + 预警，一箭不放）----
	# 2026-10-31 定调（用户口径）：哨塔"视野宽阔，无攻击"；箭塔"视野没哨塔大，但有攻击"。
	# 所以这里把攻击数值全部清零 —— can_attack() 立刻变 false，
	# 索敌循环（_acquire）也不会再给它找目标，等于天然"不打架"。
	var watchtower := UnitDef.new()
	watchtower.id = &"watchtower"
	watchtower.display_name = "哨塔"
	watchtower.kind = RtsConst.Kind.BUILDING
	watchtower.model_path = MODEL_DIR + "哨塔.glb"
	watchtower.model_scale = 0.5
	watchtower.anim_set = RtsConst.AnimSet.TOWER
	watchtower.role = &"defense"
	watchtower.max_hp = 820.0
	watchtower.armor = 5.0
	watchtower.armor_type = RtsConst.ArmorType.FORTIFIED
	watchtower.footprint = Vector2i(4, 4)
	watchtower.height = 8.7
	# 无攻击：攻/射程/索敌全 0（不靠 UI 遮掩，是数据层就不打）
	watchtower.attack_damage = 0.0
	watchtower.attack_range = 0.0
	watchtower.acquire_range = 0.0
	watchtower.projectile = RtsConst.Projectile.NONE
	# 视野 20m：比箭塔（12）宽 2/3，是全场最远的静态视野（这也是它存在的理由）
	watchtower.sight_range = 20.0
	# 预警半径 > 视野：先看到、先报，打不打得到是另一回事（这就是"哨"的意义）
	watchtower.detect_radius = 26.0
	watchtower.body_radius = 2.0
	watchtower.selection_radius = 3.0
	watchtower.gold_cost = 90
	watchtower.wood_cost = 55
	watchtower.train_time = 22.0
	out[&"watchtower"] = watchtower

	# ---- 神秘圣地：法师产地 + 法力之泉光环 ----
	var sanctum := UnitDef.new()
	sanctum.id = &"sanctum"
	sanctum.display_name = "神秘圣地"
	sanctum.kind = RtsConst.Kind.BUILDING
	sanctum.model_path = MODEL_DIR + "神秘圣地.glb"
	sanctum.model_scale = 0.5
	sanctum.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	sanctum.max_hp = 950.0
	sanctum.armor = 4.0
	sanctum.armor_type = RtsConst.ArmorType.FORTIFIED
	sanctum.footprint = Vector2i(7, 8)
	sanctum.height = 8.1
	sanctum.trains = [&"mage"]
	sanctum.sight_range = 13.0
	sanctum.body_radius = 3.4
	sanctum.selection_radius = 5.0
	sanctum.gold_cost = 150
	sanctum.wood_cost = 90
	sanctum.train_time = 30.0
	# 法力之泉：半径 14m 内的友军每秒多回 2.2 法力（见 建筑._tick_extra）
	sanctum.aura_radius = 14.0
	sanctum.aura_mana_regen = 2.2
	out[&"sanctum"] = sanctum

	# ---- 蒸汽车坊：重工 —— 出蒸汽重步兵 + 提供人口 ----
	var workshop := UnitDef.new()
	workshop.id = &"workshop"
	workshop.display_name = "蒸汽车坊"
	workshop.kind = RtsConst.Kind.BUILDING
	workshop.model_path = MODEL_DIR + "蒸汽车坊.glb"
	workshop.model_scale = 0.5
	workshop.anim_set = RtsConst.AnimSet.MILITARY_BUILDING
	workshop.max_hp = 1150.0
	workshop.armor = 6.0
	workshop.armor_type = RtsConst.ArmorType.FORTIFIED
	workshop.footprint = Vector2i(7, 8)
	workshop.height = 5.0
	workshop.trains = [&"steam_guard"]
	workshop.food_provided = 10
	workshop.sight_range = 11.0
	workshop.body_radius = 3.4
	workshop.selection_radius = 5.0
	workshop.gold_cost = 170
	workshop.wood_cost = 130
	workshop.train_time = 34.0
	out[&"workshop"] = workshop

	# ---- 伐木场：木材交汇点（农民背木头优先送这里）+ 两项木材经济研究 ----
	var lumbercamp := UnitDef.new()
	lumbercamp.id = &"lumbercamp"
	lumbercamp.display_name = "伐木场"
	lumbercamp.kind = RtsConst.Kind.BUILDING
	lumbercamp.model_path = MODEL_DIR + "伐木场.glb"
	lumbercamp.model_scale = 0.5
	lumbercamp.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	lumbercamp.max_hp = 700.0
	lumbercamp.armor = 3.0
	lumbercamp.armor_type = RtsConst.ArmorType.FORTIFIED
	lumbercamp.footprint = Vector2i(9, 6)
	lumbercamp.height = 3.9
	lumbercamp.is_dropoff = true
	# **只收木材**：大本营金木全收（dropoff_kinds 空 = 全收），伐木场专收木头。
	# 背木头时"大本营 / 伐木场"都在候选里，农民**只按距离**挑最近的送。
	lumbercamp.dropoff_kinds = [RtsConst.Harvest.WOOD]
	lumbercamp.researches = [&"wood_haul", &"repair_tech"]
	lumbercamp.sight_range = 9.0
	lumbercamp.body_radius = 3.9
	lumbercamp.selection_radius = 5.2
	lumbercamp.gold_cost = 90
	lumbercamp.wood_cost = 0
	lumbercamp.train_time = 20.0
	out[&"lumbercamp"] = lumbercamp

	# ---- 蒸汽重步兵：蒸汽车坊出的重装单位（复用步兵模型，改尺寸/数值/定位）----
	var steam_guard := UnitDef.new()
	steam_guard.id = &"steam_guard"
	steam_guard.display_name = "蒸汽重步兵"
	steam_guard.kind = RtsConst.Kind.UNIT
	steam_guard.model_path = MODEL_DIR + "步兵.glb"
	steam_guard.model_scale = 1.12
	steam_guard.anim_set = RtsConst.AnimSet.MELEE
	steam_guard.role = &"frontline"
	steam_guard.tags = [&"heavy", &"siege"]
	steam_guard.max_hp = 640.0
	steam_guard.armor = 9.0
	steam_guard.armor_type = RtsConst.ArmorType.HEAVY
	steam_guard.attack_damage = 26.0
	steam_guard.attack_spread = 4.0
	steam_guard.attack_cooldown = 1.7
	steam_guard.attack_range = 1.6
	steam_guard.attack_type = RtsConst.DamageType.SIEGE
	steam_guard.move_speed = 3.9
	steam_guard.turn_speed = 7.0
	steam_guard.body_radius = 0.58
	steam_guard.selection_radius = 0.92
	steam_guard.sight_range = 10.0
	steam_guard.acquire_range = 10.0
	steam_guard.gold_cost = 190
	steam_guard.wood_cost = 45
	steam_guard.food_cost = 3
	steam_guard.train_time = 26.0
	steam_guard.height = 1.98
	out[&"steam_guard"] = steam_guard

	# =======================================================================
	# 中立野怪（2026-11-01）—— 豺狼人（战士 / 斥候）
	# =======================================================================
	# 它们属于**中立敌对阵营**（team 0，见 代码/系统/野怪.gd）：
	# 对任何玩家/盟友都敌对，但没有大本营 → 不参与胜负判定。
	# 材质走 M_tribe 换色位（调色板里的 tribe），所以这里不需要 model_scale。
	var gnoll_warrior := UnitDef.new()
	gnoll_warrior.id = &"gnoll_warrior"
	gnoll_warrior.display_name = "豺狼人战士"
	gnoll_warrior.kind = RtsConst.Kind.UNIT
	gnoll_warrior.model_path = MODEL_DIR + "野怪/豺狼人战士.glb"
	gnoll_warrior.anim_set = RtsConst.AnimSet.MELEE
	gnoll_warrior.role = &"frontline"
	gnoll_warrior.tags = [&"light"]
	gnoll_warrior.max_hp = 340.0
	gnoll_warrior.armor = 2.0
	gnoll_warrior.armor_type = RtsConst.ArmorType.LIGHT
	gnoll_warrior.attack_damage = 15.0
	gnoll_warrior.attack_spread = 2.0
	gnoll_warrior.attack_cooldown = 1.5
	gnoll_warrior.attack_range = 1.4
	gnoll_warrior.attack_type = RtsConst.DamageType.NORMAL
	gnoll_warrior.move_speed = 4.1
	gnoll_warrior.turn_speed = 8.0
	gnoll_warrior.body_radius = 0.55
	gnoll_warrior.selection_radius = 0.9
	gnoll_warrior.sight_range = 10.0
	gnoll_warrior.acquire_range = 9.0
	gnoll_warrior.height = 1.98
	out[&"gnoll_warrior"] = gnoll_warrior

	# 斥候：更快、更脆、远程投掷（用箭矢逻辑，短射程）
	var gnoll_scout := UnitDef.new()
	gnoll_scout.id = &"gnoll_scout"
	gnoll_scout.display_name = "豺狼人斥候"
	gnoll_scout.kind = RtsConst.Kind.UNIT
	gnoll_scout.model_path = MODEL_DIR + "野怪/豺狼人斥候.glb"
	gnoll_scout.anim_set = RtsConst.AnimSet.ARCHER
	gnoll_scout.role = &"ranged"
	gnoll_scout.tags = [&"light"]
	gnoll_scout.max_hp = 240.0
	gnoll_scout.armor = 1.0
	gnoll_scout.armor_type = RtsConst.ArmorType.LIGHT
	gnoll_scout.attack_damage = 11.0
	gnoll_scout.attack_spread = 3.0
	gnoll_scout.attack_cooldown = 1.3
	gnoll_scout.attack_range = 8.0
	gnoll_scout.attack_type = RtsConst.DamageType.PIERCE
	gnoll_scout.projectile = RtsConst.Projectile.ARROW
	gnoll_scout.projectile_speed = 22.0
	gnoll_scout.move_speed = 4.8
	gnoll_scout.turn_speed = 11.0
	gnoll_scout.body_radius = 0.48
	gnoll_scout.selection_radius = 0.8
	gnoll_scout.sight_range = 13.0
	gnoll_scout.acquire_range = 11.0
	gnoll_scout.height = 1.86
	out[&"gnoll_scout"] = gnoll_scout

	# ★ 2026-11-01：**地牢（dungeon）已整体删除** ——玩家口径"地牢删除即可，
	#   相关功能不用，到时直接用上"。野怪的刷怪点改成 `代码/系统/野怪.gd` 里
	#   一批纯坐标营地（`_camps`），不再需要一座 5×5 占地、1500 血的建筑。
	#   想加回来：照着 `campfire` 那样写一个 UnitDef，再把
	#   `野怪.gd` 的 `camp_positions()` 接到它身上即可。

	# ---- 营火：**给玩家/人机用的"夜间照明点"**（2026-11-01 玩家口径）----
	# "农民有意识的建造哨塔扩大视野……并会建造营火，在夜晚能看清（让火在晚上能照明）"
	# 它是一座建筑而不是装饰：要有血量、能被拆、能进建造栏、能上小地图 ——
	# 装饰（Doodad）那套是纯视觉，AI 没法"建造"它，玩家也没法点。
	# 数值刻意很轻：20 木、8 秒、1×1 格，不占人口、不加护甲，纯粹当灯用。
	var campfire := UnitDef.new()
	campfire.id = &"campfire"
	campfire.display_name = "营火"
	campfire.kind = RtsConst.Kind.BUILDING
	# `combo:` = 由 代码/美术/营火外观.gd 现场拼（营火.glb + 一盏会呼吸的 OmniLight）
	campfire.model_path = "combo:campfire"
	campfire.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	campfire.tags = [&"light"]
	campfire.max_hp = 260.0
	campfire.armor = 0.0
	campfire.armor_type = RtsConst.ArmorType.LIGHT
	campfire.footprint = Vector2i(1, 1)
	campfire.height = 1.4
	# 视野给一点：火堆旁边总是看得见东西的（也让哨兵塔之外多一个"点"）
	campfire.sight_range = 8.0
	campfire.body_radius = 0.45
	campfire.selection_radius = 1.1
	campfire.gold_cost = 0
	campfire.wood_cost = 20
	campfire.train_time = 8.0
	out[&"campfire"] = campfire

	# =======================================================================
	# 金矿 / 树木 —— 可采集物
	# =======================================================================
	var goldmine := UnitDef.new()
	goldmine.id = &"goldmine"
	goldmine.display_name = "金矿"
	goldmine.kind = RtsConst.Kind.HARVESTABLE
	goldmine.model_path = MODEL_DIR + "金矿.glb"
	goldmine.anim_set = RtsConst.AnimSet.GOLD_MINE
	goldmine.max_hp = 99999.0
	goldmine.footprint = Vector2i(4, 4)
	goldmine.height = 3.2
	goldmine.harvest_kind = RtsConst.Harvest.GOLD
	goldmine.resource_amount = 3200
	goldmine.body_radius = 2.0
	goldmine.selection_radius = 2.8
	goldmine.sight_range = 6.0
	out[&"goldmine"] = goldmine

	# =======================================================================
	# 树 —— **程序化生成**，不吃任何 glb 资产
	# =======================================================================
	# 为什么 model_path 留空：外观由 代码/美术/树库.gd（TreeLibrary）按"每棵树的种子"
	# 现场长出来（骨架 + 三档 LOD + 球形法线），一棵树的顶点数据在池子里共享。
	# 以后美术做真树，把 model_path 填回 "树.glb" 就能整体盖掉程序化树 —— 这是留的退路。
	var tree := UnitDef.new()
	tree.id = &"tree"
	tree.display_name = "树（混生）"
	tree.kind = RtsConst.Kind.HARVESTABLE
	tree.model_path = ""
	tree.anim_set = RtsConst.AnimSet.TREE
	tree.max_hp = 99999.0
	tree.footprint = Vector2i(2, 2)
	tree.height = 5.5
	tree.harvest_kind = RtsConst.Harvest.WOOD
	tree.resource_amount = 260
	tree.body_radius = 0.9
	tree.selection_radius = 1.4
	tree.sight_range = 4.0
	out[&"tree"] = tree

	# --- 四季品种：id 后缀 = 品种，形状/叶色/叶量都不同 ---
	# 装饰面板里看到的就是这四条：春·树 / 夏·树 / 秋·树 / 冬·树。
	# 统计口径（血量/木材/占地/半径）和混生树完全一致，只有外观不同 —— 免得玩家为了
	# 一棵好看的树去挑资源分布。
	var 四季 := [["春", "春·树"], ["夏", "夏·树"], ["秋", "秋·树"], ["冬", "冬·树"]]
	for pair in 四季:
		var t: UnitDef = tree.duplicate(true) as UnitDef
		t.id = StringName("tree_" + String(pair[0]))
		t.display_name = String(pair[1])
		out[t.id] = t

	return out


## 铁匠铺 / 伐木场研究项（阵营级升级）。花费/耗时/上限全在这里，RtsCombat 只负责效果。
##
## 2026-10-31 口径（用户指定）：
##   · 铁匠铺：步兵 / 弩手 **攻击 +1 / 级**、**防御 +1 / 级**，各最高 5 级（平铺加成，不是百分比）；
##   · 伐木场：农民运回的木材 +50%、建筑修理消耗的木材 -50%（各一级）。
static func build_researches() -> Dictionary:
	var out: Dictionary = {}

	var atk := ResearchDef.new()
	atk.id = &"attack_up"
	atk.display_name = "武器锻造"
	atk.description = "步兵 / 弩手 攻击 +1 / 级（最高 5 级，对已存在与后续单位同时生效）"
	atk.gold_cost = 100
	atk.wood_cost = 40
	atk.research_time = 22.0
	atk.max_level = 5
	out[&"attack_up"] = atk

	var arm := ResearchDef.new()
	arm.id = &"armor_up"
	arm.display_name = "护甲锻造"
	arm.description = "步兵 / 弩手 防御 +1 / 级（最高 5 级，对已存在与后续单位同时生效）"
	arm.gold_cost = 90
	arm.wood_cost = 50
	arm.research_time = 22.0
	arm.max_level = 5
	out[&"armor_up"] = arm

	# ---- 伐木场：木材经济 ----
	var haul := ResearchDef.new()
	haul.id = &"wood_haul"
	haul.display_name = "高效搬运"
	haul.description = "农民每趟运回的木材 +50%（一次研究，永久生效）"
	haul.gold_cost = 120
	haul.wood_cost = 0
	haul.research_time = 28.0
	haul.max_level = 1
	out[&"wood_haul"] = haul

	var rep := ResearchDef.new()
	rep.id = &"repair_tech"
	rep.display_name = "修缮工艺"
	rep.description = "建筑修理消耗的木材 -50%（农民可右键修理己方建筑）"
	rep.gold_cost = 100
	rep.wood_cost = 0
	rep.research_time = 24.0
	rep.max_level = 1
	out[&"repair_tech"] = rep

	return out


## 三档难度
static func build_difficulties() -> Array[DifficultyDef]:
	var arr: Array[DifficultyDef] = []

	var easy := DifficultyDef.new()
	easy.id = &"easy"
	easy.display_name = "简单"
	easy.think_interval = 1.4
	easy.first_wave_delay = 100.0
	easy.wave_interval = 52.0
	easy.wave_interval_decay = 2.0
	easy.wave_interval_min = 28.0
	easy.max_army = 10
	easy.target_peasants = 6
	easy.min_wave_size = 4
	easy.gather_multiplier = 0.85
	easy.train_time_multiplier = 1.15
	easy.bonus_gold = 0
	easy.aggression = 0.55
	easy.defend_ratio = 0.5
	# 旧 5:3:1 → role 权重（frontline:ranged:caster）。siege 目前无对应兵种，留 1 给用户以后加兵。
	easy.role_weights = {&"frontline": 5.0, &"ranged": 3.0, &"caster": 1.0, &"siege": 1.0}
	arr.append(easy)

	var normal := DifficultyDef.new()
	normal.id = &"normal"
	normal.display_name = "普通"
	normal.think_interval = 1.0
	normal.first_wave_delay = 75.0
	normal.wave_interval = 40.0
	normal.wave_interval_decay = 2.5
	normal.wave_interval_min = 22.0
	normal.max_army = 16
	normal.target_peasants = 8
	normal.min_wave_size = 6
	normal.gather_multiplier = 1.0
	normal.train_time_multiplier = 1.0
	normal.bonus_gold = 100
	normal.aggression = 0.75
	normal.defend_ratio = 0.6
	# 旧 5 步 + 4 弓 + 2 法 + 1 蒸汽 → 6 前排 / 4 远程 / 2 法师（蒸汽重步兵 role=frontline）。
	normal.role_weights = {&"frontline": 6.0, &"ranged": 4.0, &"caster": 2.0, &"siege": 1.0}
	arr.append(normal)

	var hard := DifficultyDef.new()
	hard.id = &"hard"
	hard.display_name = "困难"
	hard.think_interval = 0.7
	hard.first_wave_delay = 55.0
	hard.wave_interval = 30.0
	hard.wave_interval_decay = 3.0
	hard.wave_interval_min = 16.0
	hard.max_army = 24
	hard.target_peasants = 10
	hard.min_wave_size = 8
	hard.gather_multiplier = 1.25
	hard.train_time_multiplier = 0.85
	hard.bonus_gold = 250
	hard.aggression = 0.9
	hard.defend_ratio = 0.75
	# 旧 6 步 + 5 弓 + 3 法 + 2 蒸汽 → 8 前排 / 5 远程 / 3 法师。
	hard.role_weights = {&"frontline": 8.0, &"ranged": 5.0, &"caster": 3.0, &"siege": 1.0}
	arr.append(hard)

	return arr