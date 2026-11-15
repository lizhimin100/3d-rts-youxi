@tool
class_name UnitTable
extends RefCounted
## **配置装载 + 卡索引层**（2C-4 改造）。
##
## ★ 2026-11-14 起**卡是 JSON 数据**（Content/data/cards/*.json），JSON 是数值唯一真相源：
##   · `build_units()` = 读 units/buildings 两张目录的 JSON → 逐字段重建 UnitDef
##     + 可采集物（Content/data/harvestables.json，非单位/建筑，见 `_build_harvestables`）；
##   · .tres 卡已退役到 Content/legacy/cards/（只作迁移留档，运行时不读）；
##   · 2C-3 之前的硬编码数值已按 C5 删除（删除前字段级零差异 17卡/0差异/0词表错误）；
##   · 索引/搜索接口：`get_card / find_by_class / find_by_role / find_by_counter /
##     find_by_range_tier`；`attack_range_tier` 由 range+阈值派生，**卡上不存**，
##     索引层预计算一份。其他系统一律引用卡或走索引，不得持有数值副本。
##
## 调用：
##     var cfg := GameConfig.new()
##     cfg.units = UnitTable.build_units()
##     cfg.difficulties = UnitTable.build_difficulties()

const MODEL_DIR := "res://Content/art/模型/"
const CardStore := preload("res://Game/config/card_store.gd")
const JsonFile := preload("res://Engine/util/json_file.gd")
const JsonCodec := preload("res://Engine/util/json_codec.gd")
## 卡目录（JSON；内容数据唯一来源）
const CARD_DIR_UNIT := CardStore.DIR_UNITS + "/"
const CARD_DIR_BUILDING := CardStore.DIR_BUILDINGS + "/"
const HARVEST_JSON := "res://Content/data/harvestables.json"
const RESEARCH_JSON := "res://Content/data/researches.json"
## 比对开关：默认开；`--card-verify=false` 关（任务书 §2.5 C4）
const CARD_VERIFY_DEFAULT: bool = true

## 词表（词 → 引擎枚举映射 + 校验的唯一来源）
const LW := preload("res://Game/config/定位词表.gd")
## ★ 射程换算：卡上的"游戏数值" → 引擎用的米。全游戏只此一处（见 Game/config/射程基准.gd）
const RANGE_BASE := preload("res://Game/config/射程基准.gd")
## ★ 体积派生：体积 → 模型缩放 / 碰撞半径 / 判定圈半径。全游戏只此一处
##   （见 Game/config/体积派生.gd；三种候选公式在那里切）
const VOL := preload("res://Game/config/体积派生.gd")
## 选兵权重公式（find_by_role 排序用；不用 power —— power 全 -1 未测）
const CBM := preload("res://Game/ai/战斗模型.gd")

## 卡索引（card_id → EntityCard）与范围档索引（懒建）
static var _cards: Dictionary = {}
static var _tier_index: Dictionary = {}
static var _verify_ran: bool = false


# ===========================================================================
# 卡装载与索引层（2C-4 · C4）
# ===========================================================================

## 读两张卡目录里的全部 JSON 卡，按 card_id 建索引
static func load_cards() -> Dictionary:
	var out: Dictionary = {}
	for dir_path: String in [CardStore.DIR_UNITS, CardStore.DIR_BUILDINGS]:
		for entry in CardStore.list(dir_path):
			var res: Resource = entry["card"]
			if res is EntityCard:
				var card := res as EntityCard
				if out.has(card.card_id):
					push_error("[单位表] card_id 重复：%s（%s）" % [card.card_id, entry["file"]])
					continue
				out[card.card_id] = card
	return out


static func ensure_index() -> void:
	if not _cards.is_empty():
		return
	_cards = load_cards()
	for id: String in _cards.keys():
		var card: EntityCard = _cards[id]
		if card is UnitCard:
			# ★ 2026-11-08：卡上的 range 是**游戏数值**（125/650…），
			#   档位阈值（1.5/3/6 米）是米制 —— 换算完再分档，否则步兵会被判成"超远程"。
			var tier: StringName = LW.range_tier(RANGE_BASE.米((card as UnitCard).range))
			if not _tier_index.has(tier):
				_tier_index[tier] = []
			_tier_index[tier].append(id)


## 让卡缓存失效（编辑器改完 .tres 之后调；运行时不用管）。
## 没有它，改完数值必须重启 Godot 才生效 —— 卡本来就是编辑期数据。
## 索引（_tier_index）也要一起清：range 一改，范围档可能就变了。
static func reload_cards() -> void:
	_cards.clear()
	_tier_index.clear()
	ensure_index()


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
	# 中性画像（不依赖Views/scenes/Cfg）：selection_weight 的分母与画像只影响倍率，不影响排序方向
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
	# 短局成本直接来自卡；长局金/木由 `配置入口._apply_long_costs()` 从金木价表补。
	d.cp_cost = card.cp_cost
	d.pop_cost = card.pop_cost
	d.model_path = card.model_path
	d.model_scale = card.model_scale
	d.anim_set = card.anim_set
	d.role = card.def_role
	d.tags = card.def_tags
	d.design_power = card.design_power
	if card is UnitCard:
		var c := card as UnitCard
		d.kind = RtsConst.Kind.UNIT
		d.anim_walk_mps = c.anim_walk_mps
		d.max_hp = c.max_hp
		d.armor = float(c.defense)
		d.armor_type = LW.defense_type_of(c.defense_type)
		d.attack_damage = float(c.attack)
		d.attack_spread = c.attack_spread
		d.attack_cooldown = c.attack_cooldown
		d.attack_range_value = c.range
		d.attack_range = RANGE_BASE.米(c.range)
		d.attack_type = LW.attack_type_of(c.attack_type)
		d.projectile = c.projectile
		d.projectile_speed = c.projectile_speed
		d.acquire_range = c.acquire_range
		d.sight_range = c.sight_range
		d.move_speed = c.move_speed
		d.turn_speed = c.turn_speed
		# ★ 体积是主参数（2026-11-08）：模型缩放 / 碰撞半径 / 判定圈全从它派生。
		#   volume = 0 的老卡（或建筑）走回退：照抄卡上原来那几个数，行为不变。
		d.volume = c.volume
		d.drop_gold = c.drop_gold
		d.drop_wood = c.drop_wood
		if c.volume > 0.0:
			# ★ 2026-11-13：卡上的 `model_scale` 现在是**乘数**（默认 1.0 = 只吃体积派生）。
			#   为什么改：体积同时管"碰撞半径"和"模型缩放"，而精模资产是按真实尺寸建模的
			#   （魔金傀儡 4.30 m 高、2.65 m 宽）。它的碰撞半径要 1.3（体积 2.4），
			#   但模型再乘 2.4 就变成 10 m。需要"原生尺寸"的单位在卡上填 1/体积。
			#   现有 7 张卡的 model_scale 全是默认 1.0 → 行为一个字节没变。
			d.model_scale = c.model_scale * VOL.model_scale(c.volume)
			d.body_radius = VOL.body_radius(c.volume, c.body_radius)
			d.judge_radius = VOL.judge_radius(c.volume, c.selection_radius)
			# 拾取半径跟着体积走（旧数据里 selection ≈ body × 1.65，保持同一手感）
			d.selection_radius = maxf(d.body_radius * 1.65, 0.45)
		else:
			d.body_radius = c.body_radius
			d.selection_radius = c.selection_radius
			d.judge_radius = c.body_radius
		d.food_cost = c.food_cost
		d.squad_size = maxi(int(c.squad_size), 1)
		d.require_tier = c.require_tier
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
		d.attack_range_value = b.range
		d.attack_range = RANGE_BASE.米(b.range)
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
		d.tier = b.tier
		d.require_tier = b.require_tier
		d.sight_range = b.sight_range
		d.body_radius = b.body_radius
		d.selection_radius = b.selection_radius
		# 建筑没有"判定圈"：它的身体**就是 footprint 占地矩形**，
		# 打楼一律量到墙面（distance_to_footprint），不要给建筑再加一圈半径。
		d.judge_radius = 0.0
		d.detect_radius = b.detect_radius
		d.aura_radius = b.aura_radius
		d.aura_mana_regen = b.aura_mana_regen
		d.train_time = b.train_time
		# 建筑一次订单 = 一座，永远不按小队计数。
		d.squad_size = 1
	return d


## 可采集物（金矿 / 树 / 四季树）：地图资源，不是"单位/建筑"，不走卡。
static func _build_harvestables(out: Dictionary) -> void:
	var data := JsonFile.read_dict(HARVEST_JSON, {})
	if data.is_empty():
		push_error("[单位表] 可采集物数据打不开：" + HARVEST_JSON)
		return
	for id in data.keys():
		var value: Variant = data[id]
		if not (value is Dictionary):
			push_error("[单位表] 可采集物条目不是对象：" + String(id))
			continue
		var d := JsonCodec.restore("res://Game/config/单位定义.gd", value) as UnitDef
		if d == null:
			push_error("[单位表] 可采集物重建失败：" + String(id))
			continue
		out[d.id] = d


# ===========================================================================
# --card-verify（默认开）：卡结构校验（legacy 已按 C5 删除，见 _card_verify 注释）
# ===========================================================================

static func _card_verify_enabled() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--card-verify="):
			return a.substr(String("--card-verify=").length()).to_lower() != "false"
	return CARD_VERIFY_DEFAULT


## 每次进程只跑一次。**C5 起 legacy 硬编码已删除**，比对基线不复存在 ——
## 校验改为结构校验：17 张卡全部能重建出 UnitDef、id 无重复、取词全在词表内。
## （删除前的最后一次字段级零差异报告：卡 17 张 / 差异 0 / 词表错误 0，见
##   `_qa/card_verify.json` 与 2C-4 报告正文摘要。）
static func _card_verify(built: Dictionary) -> void:
	if _verify_ran:
		return
	_verify_ran = true
	var problems: Array = []
	var seen: Dictionary = {}
	for id in _cards.keys():
		if seen.has(id):
			problems.append({"id": id, "问题": "card_id 重复"})
		seen[id] = true
		if not built.has(StringName(id)):
			problems.append({"id": id, "问题": "重建 UnitDef 失败"})
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
		"卡总数": _cards.size(), "问题": problems, "词表错误": word_errs,
		"结果": "通过" if problems.is_empty() and word_errs.is_empty() else "不通过",
		"说明": "C5 起为结构校验（legacy 已删）；删除前最后一次字段级零差异=17卡/0差异/0词表错误",
	}
	# 2C-9：第 18 张卡 = 诉求分系数卡（不是 UnitDef 卡的子类，单独校验）
	var coef_problems: Array = []
	var coef_script: Script = load("res://Game/config/AI诉求系数.gd")
	var coef_card: Resource = coef_script.call("load_from_json") if coef_script != null else null
	if coef_card == null:
		coef_problems.append("加载失败")
	else:
		var names: Array = [
			"训练_威胁系数", "训练_缺口系数", "建造_农场缺口系数", "建造_农场紧迫系数",
			"建造_兵营缺口系数", "建造_兵营紧迫系数", "修理_掉血系数", "出击_兵力比系数",
			"防守_威胁系数", "侦查_固定分", "巡逻_固定分", "建塔_固定分", "分基地_固定分",
		]
		for nm in names:
			var v = coef_card.get(nm)
			# 2C-9 要求全部 =1.0；2C-10 标定一轮后不再有这个约束，只校验"在且为有限正数"
			if v == null or not is_finite(float(v)) or float(v) <= 0.0:
				coef_problems.append("%s 缺失/非正数" % nm)
		var cyc = coef_card.get("周期秒")
		if cyc == null or absf(float(cyc) - 2.0) > 0.000001:
			coef_problems.append("周期秒≠2.0")
	report["系数卡"] = {
		"卡数": 1, "问题": coef_problems,
		"结果": "通过" if coef_problems.is_empty() else "不通过",
		"说明": "2C-10：13 个系数已标定一轮（不再要求 =1.0），只校验存在且为有限正数；刻度只在卡里改",
	}
	# 报告始终落盘（_qa/ 不入库，摘要进报告正文）
	var path := ProjectSettings.globalize_path("res://_qa/card_verify.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa != null:
		fa.store_string(JSON.stringify(report, "  "))
		fa.close()
	print("[卡校验] %s（卡 %d 张，问题 %d，词表错误 %d）；系数卡 %s（1 张，问题 %d）"
		% [report["结果"], _cards.size(), problems.size(), word_errs.size(),
			report["系数卡"]["结果"], coef_problems.size()])




# 研究（未走卡：阵营级升级项，2C-3 现状原样保留）
# ===========================================================================

static func build_researches() -> Dictionary:
	var out: Dictionary = {}
	var data := JsonFile.read_dict(RESEARCH_JSON, {})
	if data.is_empty():
		push_error("[单位表] 研究数据打不开：" + RESEARCH_JSON)
		return out
	for id in data.keys():
		var value: Variant = data[id]
		if not (value is Dictionary):
			push_error("[单位表] 研究条目不是对象：" + String(id))
			continue
		var r := JsonCodec.restore("res://Game/config/研究定义.gd", value) as ResearchDef
		if r == null:
			push_error("[单位表] 研究重建失败：" + String(id))
			continue
		out[r.id] = r
	return out



## 三档难度。2C-4 追加 `function_weights`（承伤:输出 配比，TODO 待实测细调）。
static func build_difficulties() -> Array[DifficultyDef]:
	## 难度三档住在 Content/data/game.json（game.json 的 difficulties 字段）。
	## 不走代码默认值：改难度只改 JSON。
	var out: Array[DifficultyDef] = []
	var game_data := JsonFile.read_dict("res://Content/data/game.json", {})
	var props: Dictionary = game_data.get("props", {})
	var list: Variant = props.get("difficulties", [])
	if not (list is Array):
		push_error("[单位表] game.json 里没有 difficulties 数组")
		return out
	for item in list:
		if not (item is Dictionary):
			continue
		var d := JsonCodec.restore("res://Game/config/难度定义.gd", item) as DifficultyDef
		if d != null:
			out.append(d)
	if out.is_empty():
		push_error("[单位表] 一档难度都没读出来")
	return out

