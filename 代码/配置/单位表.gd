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
	peasant.model_path = MODEL_DIR + "农民.glb"
	peasant.anim_set = RtsConst.AnimSet.WORKER
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
	peasant.food_cost = 1
	peasant.train_time = 11.0
	peasant.height = 1.62
	peasant.gather_rate = 3.0
	peasant.carry_capacity = 10
	out[&"peasant"] = peasant

	# =======================================================================
	# 步兵 —— 前排肉盾，重甲高血，打建筑慢
	# =======================================================================
	var footman := UnitDef.new()
	footman.id = &"footman"
	footman.display_name = "步兵"
	footman.kind = RtsConst.Kind.UNIT
	footman.model_path = MODEL_DIR + "步兵.glb"
	footman.anim_set = RtsConst.AnimSet.MELEE
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
	archer.model_path = MODEL_DIR + "弓箭手.glb"
	archer.anim_set = RtsConst.AnimSet.ARCHER
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
	out[&"mage"] = mage

	# =======================================================================
	# 大本营 —— 资源交汇点 + 农民产地 + 人口来源；被拆即败
	# =======================================================================
	var townhall := UnitDef.new()
	townhall.id = &"townhall"
	townhall.display_name = "大本营"
	townhall.kind = RtsConst.Kind.BUILDING
	townhall.model_path = MODEL_DIR + "大本营.glb"
	townhall.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	townhall.max_hp = 2600.0
	townhall.armor = 6.0
	townhall.armor_type = RtsConst.ArmorType.FORTIFIED
	townhall.footprint = Vector2i(8, 8)
	townhall.height = 9.0
	townhall.is_dropoff = true
	townhall.food_provided = 24
	townhall.trains = [&"peasant"]
	townhall.train_time = 11.0
	townhall.sight_range = 15.0
	townhall.body_radius = 4.2
	townhall.selection_radius = 5.4
	out[&"townhall"] = townhall

	# =======================================================================
	# 兵营 —— 出步兵/弓手/法师
	# =======================================================================
	var barracks := UnitDef.new()
	barracks.id = &"barracks"
	barracks.display_name = "兵营"
	barracks.kind = RtsConst.Kind.BUILDING
	barracks.model_path = MODEL_DIR + "兵营.glb"
	barracks.anim_set = RtsConst.AnimSet.MILITARY_BUILDING
	barracks.max_hp = 1500.0
	barracks.armor = 5.0
	barracks.armor_type = RtsConst.ArmorType.FORTIFIED
	barracks.footprint = Vector2i(6, 6)
	barracks.height = 4.6
	barracks.trains = [&"footman", &"archer", &"mage"]
	barracks.train_time = 18.0
	barracks.sight_range = 12.0
	barracks.body_radius = 3.2
	barracks.selection_radius = 4.2
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
	blacksmith.anim_set = RtsConst.AnimSet.MILITARY_BUILDING
	blacksmith.max_hp = 1300.0
	blacksmith.armor = 4.0
	blacksmith.armor_type = RtsConst.ArmorType.FORTIFIED
	blacksmith.footprint = Vector2i(6, 6)
	blacksmith.height = 4.2
	blacksmith.researches = [&"attack_up", &"armor_up"]
	blacksmith.sight_range = 11.0
	blacksmith.body_radius = 3.0
	blacksmith.selection_radius = 4.0
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
	farm.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	farm.max_hp = 750.0
	farm.armor = 3.0
	farm.armor_type = RtsConst.ArmorType.FORTIFIED
	farm.footprint = Vector2i(4, 4)
	farm.height = 2.6
	farm.food_provided = 8
	farm.sight_range = 8.0
	farm.body_radius = 2.0
	farm.selection_radius = 2.8
	farm.gold_cost = 80
	farm.wood_cost = 20
	farm.train_time = 20.0
	out[&"farm"] = farm

	# =======================================================================
	# 箭塔 —— 自动射击的防御塔
	# =======================================================================
	var tower := UnitDef.new()
	tower.id = &"tower"
	tower.display_name = "箭塔"
	tower.kind = RtsConst.Kind.BUILDING
	tower.model_path = MODEL_DIR + "箭塔.glb"
	tower.anim_set = RtsConst.AnimSet.TOWER
	tower.max_hp = 1050.0
	tower.armor = 6.0
	tower.armor_type = RtsConst.ArmorType.FORTIFIED
	tower.footprint = Vector2i(4, 4)
	tower.height = 8.0
	tower.attack_damage = 18.0
	tower.attack_spread = 4.0
	tower.attack_cooldown = 1.5
	tower.attack_range = 12.0
	tower.attack_type = RtsConst.DamageType.PIERCE
	tower.projectile = RtsConst.Projectile.ARROW
	tower.projectile_speed = 28.0
	tower.acquire_range = 12.0
	tower.sight_range = 14.0
	tower.body_radius = 1.6
	tower.selection_radius = 2.4
	tower.gold_cost = 110
	tower.wood_cost = 60
	tower.train_time = 25.0
	out[&"tower"] = tower

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

	var tree := UnitDef.new()
	tree.id = &"tree"
	tree.display_name = "树木"
	tree.kind = RtsConst.Kind.HARVESTABLE
	tree.model_path = MODEL_DIR + "树.glb"
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
	easy.composition = {&"footman": 5, &"archer": 3, &"mage": 1}
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
	normal.composition = {&"footman": 5, &"archer": 4, &"mage": 2}
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
	hard.composition = {&"footman": 6, &"archer": 5, &"mage": 3}
	arr.append(hard)

	return arr
