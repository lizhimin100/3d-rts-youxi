extends RefCounted
## 职责：把游戏对象（建筑/阵营/Cfg）适配成 Model 可用性判断的纯字典
## 属于：Game/config
## 对外：train / research / build / train_permission / QUEUE_MAX
## 铁律：
##   · 判据只在 Model/core/可用性.gd；这里只负责取字段，不写"够不够"的公式；
##   · UI（命令卡）、输入（指令系统）、玩法（建筑）都走这里，禁止再各写一套。

const A := preload("res://Model/core/可用性.gd")

## 训练队列上限（唯一来源 = Model）
const QUEUE_MAX := A.TRAIN_QUEUE_MAX


static func _food_free(faction) -> int:
	if faction == null:
		return 0
	return maxi(int(faction.food_cap()) - int(faction.food_used()) - int(faction.food_reserved()), 0)


static func _tier(faction) -> int:
	if faction == null:
		return 1
	if Game.has_method("faction_tier"):
		return int(Game.call("faction_tier", faction))
	return 1


## 训练一个单位能不能点（UI/指令/AI 共用）
static func train(b: Node, id: StringName, faction) -> Dictionary:
	var d: UnitDef = Cfg.unit(id)
	if d == null:
		return A.fail(&"not_defined")
	if b == null:
		return A.fail(&"not_constructed")
	var bdef: UnitDef = b.get("def")
	var trains: Array = bdef.trains if bdef != null else []
	var queue: Array = b.get("train_queue") if b.get("train_queue") != null else []
	return A.check_train({
		"constructed": bool(b.get("is_constructed")),
		"upgrading": bool(b.call("is_upgrading")),
		"trains": trains,
		"id": id,
		"require_tier": int(d.require_tier),
		"current_tier": _tier(faction),
		"queue_size": queue.size(),
		"queue_max": QUEUE_MAX,
		"food_cost": int(d.food_cost),
		"food_free": _food_free(faction),
		"gold": int(faction.gold) if faction != null else 0,
		"wood": int(faction.wood) if faction != null else 0,
		"gold_cost": int(d.gold_cost),
		"wood_cost": int(d.wood_cost),
	})


## 研究一项能不能点
static func research(b: Node, id: StringName, faction) -> Dictionary:
	var rd: ResearchDef = Cfg.research(id)
	if rd == null:
		return A.fail(&"not_researchable")
	if b == null:
		return A.fail(&"not_constructed")
	var bdef: UnitDef = b.get("def")
	var has := bdef != null and bdef.researches.has(id) and RtsCombat.has_research(id)
	var level := int(RtsCombat.research_level(faction, id)) if faction != null else 0
	return A.check_research({
		"constructed": bool(b.get("is_constructed")),
		"researchable": has,
		"upgrading": bool(b.call("is_upgrading")),
		"busy": bool(b.call("is_researching")),
		"level": level,
		"max_level": maxi(int(rd.max_level), 1),
		"gold": int(faction.gold) if faction != null else 0,
		"wood": int(faction.wood) if faction != null else 0,
		"gold_cost": int(rd.gold_cost),
		"wood_cost": int(rd.wood_cost),
	})


## 建造一项能不能开始（放置合法性不在这里）
static func build(id: StringName, faction, has_worker: bool = true) -> Dictionary:
	var d: UnitDef = Cfg.unit(id)
	if d == null:
		return A.fail(&"not_defined")
	return A.check_build({
		"has_worker": has_worker,
		"require_tier": int(d.require_tier),
		"current_tier": _tier(faction),
		"gold": int(faction.gold) if faction != null else 0,
		"wood": int(faction.wood) if faction != null else 0,
		"gold_cost": int(d.gold_cost),
		"wood_cost": int(d.wood_cost),
	})


## 建筑改造/升本：补差价能不能付（哨塔→箭塔、大本营→联盟要塞）
static func refit(cost: Vector2i, faction, busy: bool, constructed: bool) -> Dictionary:
	return A.check_refit({
		"constructed": constructed,
		"busy": busy,
		"gold": int(faction.gold) if faction != null else 0,
		"wood": int(faction.wood) if faction != null else 0,
		"gold_cost": int(cost.x),
		"wood_cost": int(cost.y),
	})


## 只判"这栋楼有没有资格造它"（trains + 主城等级），给 建筑.can_train 用
static func train_permission(trains: Array, id: StringName, required_tier: int, current_tier: int) -> Dictionary:
	return A.check_train_permission(trains, id, required_tier, current_tier)