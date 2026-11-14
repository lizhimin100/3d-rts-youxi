extends RefCounted
## 职责：可用性判断（训练 / 研究 / 建造）—— **全游戏唯一实现**
## 属于：Model/core
## 对外：check_train / check_research / check_build / check_train_permission / fail
## 铁律：
##   · 只收 Dictionary/数值，不读 Cfg/Game，不碰 Node；
##   · 返回 {ok, reason, params}，reason 用 ASCII code（界面负责翻译成文案）；
##   · 判断顺序 = 玩家看到的第一个原因（建筑没盖好 > 没这个选项 > 升级中 > 门槛 > 队列 > 人口 > 金币 > 木材）。

const OK := &"ok"
## 训练队列上限（唯一来源；指令系统/命令卡都引用这里）
const TRAIN_QUEUE_MAX := 10


static func fail(reason: StringName, params: Dictionary = {}) -> Dictionary:
	return {"ok": false, "reason": reason, "params": params}


static func _ok() -> Dictionary:
	return {"ok": true, "reason": OK, "params": {}}


## 训练：ctx 字段见下面注释；缺省值按"最宽松"处理，方便调用方只传关心的项。
static func check_train(ctx: Dictionary) -> Dictionary:
	if not bool(ctx.get("constructed", true)):
		return fail(&"not_constructed")
	var trains: Array = ctx.get("trains", [])
	if not trains.has(ctx.get("id", &"")):
		return fail(&"not_in_trains")
	if bool(ctx.get("upgrading", false)):
		return fail(&"upgrading")
	var required := int(ctx.get("require_tier", 0))
	var current := int(ctx.get("current_tier", 1))
	if required > current:
		return fail(&"tier_locked", {"required": required, "current": current})
	var qmax := int(ctx.get("queue_max", TRAIN_QUEUE_MAX))
	var qsize := int(ctx.get("queue_size", 0))
	if qmax > 0 and qsize >= qmax:
		return fail(&"queue_full", {"max": qmax})
	var need_food := int(ctx.get("food_cost", 0))
	var free_food := int(ctx.get("food_free", 0))
	if need_food > free_food:
		return fail(&"no_food", {"need": need_food, "free": free_food})
	# 短局：金木不参与支付，只看 CP。`short` 由适配层传，Model 不读 Game。
	if bool(ctx.get("short", false)):
		var cp := int(ctx.get("cp", 0))
		var cost_cp := int(ctx.get("cp_cost", 0))
		if cp < cost_cp:
			return fail(&"no_cp", {"need": cost_cp, "have": cp, "short": cost_cp - cp})
		return _ok()
	var gold := int(ctx.get("gold", 0))
	var cost_gold := int(ctx.get("gold_cost", 0))
	if gold < cost_gold:
		return fail(&"no_gold", {"need": cost_gold, "have": gold, "short": cost_gold - gold})
	var wood := int(ctx.get("wood", 0))
	var cost_wood := int(ctx.get("wood_cost", 0))
	if wood < cost_wood:
		return fail(&"no_wood", {"need": cost_wood, "have": wood, "short": cost_wood - wood})
	return _ok()


## 只判"这栋楼有没有资格造它"（trains + 主城等级）；不判资源/队列/完工。
## 给 建筑.can_train / AI 用，行为与旧版一致。
static func check_train_permission(trains: Array, id: StringName, required_tier: int, current_tier: int) -> Dictionary:
	if not trains.has(id):
		return fail(&"not_in_trains")
	if int(required_tier) > int(current_tier):
		return fail(&"tier_locked", {"required": required_tier, "current": current_tier})
	return _ok()


## 研究：ctx 字段见下面注释
static func check_research(ctx: Dictionary) -> Dictionary:
	if not bool(ctx.get("constructed", true)):
		return fail(&"not_constructed")
	if not bool(ctx.get("researchable", false)):
		return fail(&"not_researchable")
	if bool(ctx.get("upgrading", false)):
		return fail(&"upgrading")
	if bool(ctx.get("busy", false)):
		return fail(&"research_busy")
	var level := int(ctx.get("level", 0))
	var max_level := int(ctx.get("max_level", 1))
	if level >= max_level:
		return fail(&"max_level", {"level": level, "max": max_level})
	var gold := int(ctx.get("gold", 0))
	var cost_gold := int(ctx.get("gold_cost", 0))
	if gold < cost_gold:
		return fail(&"no_gold", {"need": cost_gold, "have": gold, "short": cost_gold - gold})
	var wood := int(ctx.get("wood", 0))
	var cost_wood := int(ctx.get("wood_cost", 0))
	if wood < cost_wood:
		return fail(&"no_wood", {"need": cost_wood, "have": wood, "short": cost_wood - wood})
	return _ok()


## 建筑改造/升本：ctx 字段：
##   constructed / busy / gold / wood / gold_cost / wood_cost
## （哨塔→箭塔、大本营→联盟要塞都走它；只判"能不能开始"，不判改造目标是否存在）
static func check_refit(ctx: Dictionary) -> Dictionary:
	if not bool(ctx.get("constructed", true)):
		return fail(&"not_constructed")
	if bool(ctx.get("busy", false)):
		return fail(&"upgrading")
	var gold := int(ctx.get("gold", 0))
	var cost_gold := int(ctx.get("gold_cost", 0))
	if gold < cost_gold:
		return fail(&"no_gold", {"need": cost_gold, "have": gold, "short": cost_gold - gold})
	var wood := int(ctx.get("wood", 0))
	var cost_wood := int(ctx.get("wood_cost", 0))
	if wood < cost_wood:
		return fail(&"no_wood", {"need": cost_wood, "have": wood, "short": cost_wood - wood})
	return _ok()


## 建造：ctx 字段：
##   has_worker / require_tier / current_tier / gold / wood / gold_cost / wood_cost
## 放置合法性（越界/挡格/水面）不在这里 —— 那是地图网格的活，见 建筑网格.can_place。
static func check_build(ctx: Dictionary) -> Dictionary:
	if not bool(ctx.get("has_worker", true)):
		return fail(&"no_worker")
	var required := int(ctx.get("require_tier", 0))
	var current := int(ctx.get("current_tier", 1))
	if required > current:
		return fail(&"tier_locked", {"required": required, "current": current})
	# 短局：只看 CP（金木不参与支付）
	if bool(ctx.get("short", false)):
		var cp := int(ctx.get("cp", 0))
		var cost_cp := int(ctx.get("cp_cost", 0))
		if cp < cost_cp:
			return fail(&"no_cp", {"need": cost_cp, "have": cp, "short": cost_cp - cp})
		return _ok()
	var gold := int(ctx.get("gold", 0))
	var cost_gold := int(ctx.get("gold_cost", 0))
	if gold < cost_gold:
		return fail(&"no_gold", {"need": cost_gold, "have": gold, "short": cost_gold - gold})
	var wood := int(ctx.get("wood", 0))
	var cost_wood := int(ctx.get("wood_cost", 0))
	if wood < cost_wood:
		return fail(&"no_wood", {"need": cost_wood, "have": wood, "short": cost_wood - wood})
	return _ok()
