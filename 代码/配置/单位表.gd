@tool
class_name UnitTable
extends RefCounted
## **配置装载 + 卡索引层**（2C-4 改造）。
##
## 2C-4 起**卡（.tres）是数值唯一真相源**（任务书 §2.1：卡不存任何实例状态）：
##   · `build_units()` = 读 代码/配置/卡/ 下的 17 张卡 → 逐字段重建 UnitDef
##     + 可采集物（金矿/树，非单位/建筑，不走卡，见 `_build_harvestables`）；
##   · `_build_units_legacy()` = 2C-3 之前的硬编码数值（**只供 `--card-verify` 比对**，
##     零差异通过后按 C5 单独 commit 删除）；
##   · 索引/搜索接口：`get_card / find_by_class / find_by_role / find_by_counter /
##     find_by_range_tier`；`attack_range_tier` 由 range+阈值派生，**卡上不存**，
##     索引层预计算一份。其他系统一律引用卡或走索引，不得持有数值副本。
##
## 调用：
##     var cfg := GameConfig.new()
##     cfg.units = UnitTable.build_units()
##     cfg.difficulties = UnitTable.build_difficulties()

const MODEL_DIR := "res://美术/模型/"
## 卡目录（2C-4）
const CARD_DIR_UNIT := "res://代码/配置/卡/单位/"
const CARD_DIR_BUILDING := "res://代码/配置/卡/建筑/"
## 比对开关：默认开；`--card-verify=false` 关（任务书 §2.5 C4）
const CARD_VERIFY_DEFAULT: bool = true

## 词表（词 → 引擎枚举映射 + 校验的唯一来源）
const LW := preload("res://代码/配置/定位词表.gd")
## 选兵权重公式（find_by_role 排序用；不用 power —— power 全 -1 未测）
const CBM := preload("res://代码/ai/战斗模型.gd")

## 卡索引（card_id → EntityCard）与范围档索引（懒建）
static var _cards: Dictionary = {}
static var _tier_index: Dictionary = {}
static var _verify_ran: bool = false


# ===========================================================================
# 卡装载与索引层（2C-4 · C4）
# ===========================================================================

## 读两张卡目录里的全部 .tres，按 card_id 建索引
static func load_cards() -> Dictionary:
	var out: Dictionary = {}
	for dir_path: String in [CARD_DIR_UNIT, CARD_DIR_BUILDING]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for f in dir.get_files():
			if not f.ends_with(".tres"):
				continue
			var res: Resource = load(dir_path + f)
			if res is EntityCard:
				var card := res as EntityCard
				out[card.card_id] = card
	return out


static func ensure_index() -> void:
	if not _cards.is_empty():
		return
	_cards = load_cards()
	for id: String in _cards.keys():
		var card: EntityCard = _cards[id]
		if card is UnitCard:
			var tier: StringName = LW.range_tier((card as UnitCard).range)
			if not _tier_index.has(tier):
				_tier_index[tier] = []
			_tier_index[tier].append(id)


## 按卡 id（= 单位 id）取卡；查不到返回 null
static func get_card(id: StringName) -> EntityCard:
	ensure_index()
	return _cards.get(String(id), null)


## 词表·兵种（陆军/空军/海军）筛选
static func find_by_class(cls: StringName) -> Array:
	ensure_index()
	var out: Array = []
	for id: String in _cards.keys():
		var card: EntityCard = _cards[id]
		if card is UnitCard and (card as UnitCard).unit_class == cls:
			out.append(card)
	return out


## 词表·职能筛选（roles 含该词）。排序按 **战斗模型.selection_weight**
## （每金战力 × 职能权重 ÷ 过载），**不按 power**（power 全 -1 未测）。
static func find_by_role(role: StringName, function_weight: float = 1.0) -> Array:
	ensure_index()
	var hits: Array = []
	for id: String in _cards.keys():
		var card: EntityCard = _cards[id]
		if card is UnitCard and (card as UnitCard).roles.has(role):
			hits.append(card)
	# 中性画像（不依赖场景/Cfg）：selection_weight 的分母与画像只影响倍率，不影响排序方向
	var neutral: Dictionary = {
		"armor": 0.0, "armor_mix": {RtsConst.ArmorType.LIGHT: 1.0},
		"dmg_mix": {RtsConst.DamageType.NORMAL: 1.0}, "hp": 1.0,
	}
	hits.sort_custom(func(a, b):
		var wa: float = float(CBM.selection_weight(_def_of_card(a), function_weight, 0, neutral))
		var wb: float = float(CBM.selection_weight(_def_of_card(b), function_weight, 0, neutral))
		return wa > wb)
	return hits


## 词表·克制筛选（counters 含该词；克制**不参与伤害结算**，纯标注）
static func find_by_counter(type: StringName) -> Array:
	ensure_index()
	var out: Array = []
	for id: String in _cards.keys():
		var card: EntityCard = _cards[id]
		if card is UnitCard and (card as UnitCard).counters.has(type):
			out.append(card)
	return out


## 词表·攻击范围档筛选（tier 由 range+阈值派生，索引层预计算）
static func find_by_range_tier(tier: StringName) -> Array:
	ensure_index()
	var out: Array = []
	for id in _tier_index.get(tier, []):
		if _cards.has(id):
			out.append(_cards[id])
	return out


# ===========================================================================
# build_units：卡 → UnitDef（数值唯一真相源）
# ===========================================================================

## 搭建全部单位定义。**数值只从卡来**；可采集物（金矿/树）不是单位/建筑，不走卡。
static func build_units() -> Dictionary:
	ensure_index()
	var out: Dictionary = {}
	for id: String in _cards.keys():
		var d := _def_of_card(_cards[id])
		if d != null:
			out[d.id] = d
	_build_harvestables(out)
	_card_verify(out)
	return out


## 卡 → UnitDef（逐字段映射；卡字段名与 UnitDef 一一对应，方便比对）
static func _def_of_card(card: EntityCard) -> UnitDef:
	if card == null:
		return null
	var d := UnitDef.new()
	d.id = StringName(card.card_id)
	d.display_name = card.display_name
	d.gold_cost = card.cost_gold
	d.wood_cost = card.cost_wood
	d.model_path = card.model_path
	d.model_scale = card.model_scale
	d.anim_set = card.anim_set
	d.role = card.def_role
	d.tags = card.def_tags
	d.design_power = card.design_power
	if card is UnitCard:
		var c := card as UnitCard
		d.kind = RtsConst.Kind.UNIT
		d.max_hp = c.max_hp
		d.armor = float(c.defense)
		d.armor_type = LW.defense_type_of(c.defense_type)
		d.attack_damage = float(c.attack)
		d.attack_spread = c.attack_spread
		d.attack_cooldown = c.attack_cooldown
		d.attack_range = c.range
		d.attack_type = LW.attack_type_of(c.attack_type)
		d.projectile = c.projectile
		d.projectile_speed = c.projectile_speed
		d.acquire_range = c.acquire_range
		d.sight_range = c.sight_range
		d.move_speed = c.move_speed
		d.turn_speed = c.turn_speed
		d.body_radius = c.body_radius
		d.selection_radius = c.selection_radius
		d.food_cost = c.food_cost
		d.train_time = c.train_time
		d.height = c.height
		d.gather_rate = c.gather_rate
		d.carry_capacity = c.carry_capacity
		d.abilities = c.skills
		d.max_mana = c.max_mana
		d.mana_regen = c.mana_regen
		d.mana_cost = c.mana_cost
		d.ability_cooldown = c.ability_cooldown
	elif card is BuildingCard:
		var b := card as BuildingCard
		d.kind = RtsConst.Kind.BUILDING
		d.max_hp = b.max_hp
		d.armor = float(b.defense)
		d.armor_type = LW.defense_type_of(b.defense_type)
		d.attack_damage = float(b.attack)
		d.attack_spread = b.attack_spread
		d.attack_cooldown = b.attack_cooldown
		d.attack_range = b.range
		d.attack_type = LW.attack_type_of(b.attack_type)
		d.projectile = b.projectile
		d.projectile_speed = b.projectile_speed
		d.acquire_range = b.acquire_range
		d.footprint = b.footprint
		d.height = b.height
		d.is_dropoff = b.is_dropoff
		d.dropoff_kinds = b.dropoff_kinds
		d.food_provided = b.food_provided
		d.trains = b.trains
		d.researches = b.researches
		d.sight_range = b.sight_range
		d.body_radius = b.body_radius
		d.selection_radius = b.selection_radius
		d.detect_radius = b.detect_radius
		d.aura_radius = b.aura_radius
		d.aura_mana_regen = b.aura_mana_regen
		d.train_time = b.train_time
	return d


## 可采集物（金矿 / 树 / 四季树）：地图资源，不是"单位/建筑"，不走卡。
static func _build_harvestables(out: Dictionary) -> void:
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

	var 四季 := [["春", "春·树"], ["夏", "夏·树"], ["秋", "秋·树"], ["冬", "冬·树"]]
	for pair in 四季:
		var t: UnitDef = tree.duplicate(true) as UnitDef
		t.id = StringName("tree_" + String(pair[0]))
		t.display_name = String(pair[1])
		out[t.id] = t


# ===========================================================================
# --card-verify（默认开）：卡重建 vs legacy 硬编码 逐字段零差异比对
# ===========================================================================

static func _card_verify_enabled() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--card-verify="):
			return a.substr(String("--card-verify=").length()).to_lower() != "false"
	return CARD_VERIFY_DEFAULT


## 每次进程只跑一次。零差异 → 一行 PASS；有差异 → 逐项列出 + 落盘 _qa/card_verify.json。
static func _card_verify(built: Dictionary) -> void:
	if _verify_ran:
		return
	_verify_ran = true
	var legacy := _build_units_legacy()
	var diffs: Array = []
	for id in legacy.keys():
		var a: UnitDef = legacy[id]
		var b: UnitDef = built.get(id, null)
		if b == null:
			diffs.append({"id": String(id), "问题": "卡缺失"})
			continue
		for f in _compare_fields(a.kind):
			var va = a.get(f)
			var vb = b.get(f)
			if va != vb:
				diffs.append({"id": String(id), "字段": f, "legacy": str(va), "card": str(vb)})
	# 只查"卡里有、legacy 没有"：built 里的可采集物（金矿/树，不走卡）不参与比对
	for id in _cards.keys():
		if not legacy.has(id):
			diffs.append({"id": id, "问题": "legacy 无此 id（多余卡？）"})
	# 词表校验：卡上取词必须在词表内
	var word_errs: Array = []
	for id in _cards.keys():
		var card: EntityCard = _cards[id]
		if card is UnitCard:
			var c := card as UnitCard
			for e in LW.validate_words(c.unit_class, c.roles, c.counters, c.attack_type, c.defense_type):
				word_errs.append({"id": id, "错误": e})
		elif card is BuildingCard:
			for e in LW.validate_functions((card as BuildingCard).functions):
				word_errs.append({"id": id, "错误": e})
	var report := {
		"卡总数": _cards.size(), "差异": diffs, "词表错误": word_errs,
		"结果": "零差异" if diffs.is_empty() and word_errs.is_empty() else "有差异",
	}
	# 报告始终落盘（C5 删 legacy 前必须留档；_qa/ 不入库，摘要进报告正文）
	var path := ProjectSettings.globalize_path("res://_qa/card_verify.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa != null:
		fa.store_string(JSON.stringify(report, "  "))
		fa.close()
	print("[卡校验] %s（卡 %d 张，差异 %d，词表错误 %d）"
		% [report["结果"], _cards.size(), diffs.size(), word_errs.size()])


## 参与比对的字段（按 kind）
static func _compare_fields(kind: int) -> PackedStringArray:
	var common := PackedStringArray(["display_name", "gold_cost", "wood_cost", "model_path",
		"model_scale", "anim_set", "role", "tags", "design_power", "max_hp", "armor",
		"armor_type", "attack_damage", "attack_spread", "attack_cooldown", "attack_range",
		"attack_type", "projectile", "projectile_speed", "acquire_range", "sight_range",
		"train_time", "height", "food_cost"])
	if kind == RtsConst.Kind.UNIT:
		common.append_array(PackedStringArray(["move_speed", "turn_speed", "body_radius",
			"selection_radius", "gather_rate", "carry_capacity", "abilities", "max_mana",
			"mana_regen", "mana_cost", "ability_cooldown"]))
	else:
		common.append_array(PackedStringArray(["footprint", "is_dropoff", "dropoff_kinds",
			"food_provided", "trains", "researches", "body_radius", "selection_radius",
			"detect_radius", "aura_radius", "aura_mana_regen"]))
	return common


# ===========================================================================
# legacy（2C-3 之前的硬编码数值；**只供 --card-verify 比对**，C5 零差异后删除）
# ===========================================================================

## 2C-3 版硬编码单位/建筑（比对基线，不含可采集物）
static func _build_units_legacy() -> Dictionary:
	var out: Dictionary = {}

	var peasant := UnitDef.new()
	peasant.id = &"peasant"
	peasant.display_name = "农民"
	peasant.kind = RtsConst.Kind.UNIT
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
	peasant.food_cost = 0
	peasant.train_time = 11.0
	peasant.height = 1.62
	peasant.gather_rate = 3.0
	peasant.carry_capacity = 10
	out[&"peasant"] = peasant

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

	var archer := UnitDef.new()
	archer.id = &"archer"
	archer.display_name = "弓箭手"
	archer.kind = RtsConst.Kind.UNIT
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
	mage.max_mana = 120.0
	mage.mana_regen = 3.2
	mage.mana_cost = 45.0
	out[&"mage"] = mage

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

	var townhall := UnitDef.new()
	townhall.id = &"townhall"
	townhall.display_name = "大本营"
	townhall.kind = RtsConst.Kind.BUILDING
	townhall.model_path = MODEL_DIR + "大本营.glb"
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

	var barracks := UnitDef.new()
	barracks.id = &"barracks"
	barracks.display_name = "兵营"
	barracks.kind = RtsConst.Kind.BUILDING
	barracks.model_path = MODEL_DIR + "兵营.glb"
	barracks.model_scale = 0.5
	barracks.anim_set = RtsConst.AnimSet.MILITARY_BUILDING
	barracks.max_hp = 1500.0
	barracks.armor = 5.0
	barracks.armor_type = RtsConst.ArmorType.FORTIFIED
	barracks.footprint = Vector2i(6, 7)
	barracks.height = 5.8
	barracks.trains = [&"footman", &"archer"]
	barracks.train_time = 18.0
	barracks.sight_range = 12.0
	barracks.body_radius = 2.8
	barracks.selection_radius = 4.4
	barracks.gold_cost = 180
	barracks.wood_cost = 60
	barracks.train_time = 30.0
	out[&"barracks"] = barracks

	var blacksmith := UnitDef.new()
	blacksmith.id = &"blacksmith"
	blacksmith.display_name = "铁匠铺"
	blacksmith.kind = RtsConst.Kind.BUILDING
	blacksmith.model_path = MODEL_DIR + "铁匠铺.glb"
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

	var farm := UnitDef.new()
	farm.id = &"farm"
	farm.display_name = "农场"
	farm.kind = RtsConst.Kind.BUILDING
	farm.model_path = MODEL_DIR + "农场.glb"
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

	var tower := UnitDef.new()
	tower.id = &"tower"
	tower.display_name = "箭塔"
	tower.kind = RtsConst.Kind.BUILDING
	tower.model_path = MODEL_DIR + "箭塔.glb"
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
	tower.sight_range = 12.0
	tower.body_radius = 1.6
	tower.selection_radius = 2.4
	tower.gold_cost = 130
	tower.wood_cost = 70
	tower.train_time = 25.0
	out[&"tower"] = tower

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
	watchtower.attack_damage = 0.0
	watchtower.attack_range = 0.0
	watchtower.acquire_range = 0.0
	watchtower.projectile = RtsConst.Projectile.NONE
	watchtower.sight_range = 20.0
	watchtower.detect_radius = 26.0
	watchtower.body_radius = 2.0
	watchtower.selection_radius = 3.0
	watchtower.gold_cost = 90
	watchtower.wood_cost = 55
	watchtower.train_time = 22.0
	out[&"watchtower"] = watchtower

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
	sanctum.aura_radius = 14.0
	sanctum.aura_mana_regen = 2.2
	out[&"sanctum"] = sanctum

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
	lumbercamp.dropoff_kinds = [RtsConst.Harvest.WOOD]
	lumbercamp.researches = [&"wood_haul", &"repair_tech"]
	lumbercamp.sight_range = 9.0
	lumbercamp.body_radius = 3.9
	lumbercamp.selection_radius = 5.2
	lumbercamp.gold_cost = 90
	lumbercamp.wood_cost = 0
	lumbercamp.train_time = 20.0
	out[&"lumbercamp"] = lumbercamp

	var campfire := UnitDef.new()
	campfire.id = &"campfire"
	campfire.display_name = "营火"
	campfire.kind = RtsConst.Kind.BUILDING
	campfire.model_path = "combo:campfire"
	campfire.anim_set = RtsConst.AnimSet.CIVIC_BUILDING
	campfire.tags = [&"light"]
	campfire.max_hp = 260.0
	campfire.armor = 0.0
	campfire.armor_type = RtsConst.ArmorType.LIGHT
	campfire.footprint = Vector2i(1, 1)
	campfire.height = 1.4
	campfire.sight_range = 8.0
	campfire.body_radius = 0.45
	campfire.selection_radius = 1.1
	campfire.gold_cost = 0
	campfire.wood_cost = 20
	campfire.train_time = 8.0
	out[&"campfire"] = campfire

	return out


# ===========================================================================
# 研究（未走卡：阵营级升级项，2C-3 现状原样保留）
# ===========================================================================

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


## 三档难度。2C-4 追加 `function_weights`（承伤:输出 配比，TODO 待实测细调）。
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
	easy.role_weights = {&"frontline": 5.0, &"ranged": 3.0, &"caster": 1.0, &"siege": 1.0}
	# 2C-4 选兵配比（承伤:输出）。TODO 难度档给简单权重，用户口径"当前兵种少，不需要复杂加权"
	easy.function_weights = {&"承伤": 5.0, &"输出": 5.0}
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
	normal.role_weights = {&"frontline": 6.0, &"ranged": 4.0, &"caster": 2.0, &"siege": 1.0}
	normal.function_weights = {&"承伤": 6.0, &"输出": 4.0}
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
	hard.role_weights = {&"frontline": 8.0, &"ranged": 5.0, &"caster": 3.0, &"siege": 1.0}
	hard.function_weights = {&"承伤": 7.0, &"输出": 5.0}
	arr.append(hard)

	return arr
