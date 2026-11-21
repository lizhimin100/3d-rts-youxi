extends RefCounted
## 职责：可用性判断（训练 / 研究 / 建造 / 改造）的 **GDScript 适配层**
## 属于：Game/adapters（过渡层，调用方 API 不变）
## 真正实现：`Model/Core/Availability.cs`。原因码（ASCII）在这里原样透传，界面负责翻译。

## 训练队列上限（与 C# 的 Availability.TrainQueueMax 对齐，由 --check 断言）
const TRAIN_QUEUE_MAX := 10
const OK := &"ok"

static var _mdl: Node = null


static func _bridge() -> Node:
	if _mdl != null and is_instance_valid(_mdl):
		return _mdl
	var main := Engine.get_main_loop()
	if main is SceneTree:
		_mdl = (main as SceneTree).root.get_node_or_null("Mdl")
	if _mdl == null:
		push_error("[Model] bridge Mdl missing (C# kernel not built?)")
	return _mdl


static func fail(reason: StringName, params: Dictionary = {}) -> Dictionary:
	return {"ok": false, "reason": reason, "params": params}


static func check_train(ctx: Dictionary) -> Dictionary:
	var m := _bridge()
	if m == null:
		return fail(&"no_model")
	return m.call("AvailabilityTrain", ctx)


static func check_train_permission(trains: Array, id: StringName, required_tier: int, current_tier: int) -> Dictionary:
	var m := _bridge()
	if m == null:
		return fail(&"no_model")
	return m.call("AvailabilityTrainPermission", trains, String(id), required_tier, current_tier)


static func check_research(ctx: Dictionary) -> Dictionary:
	var m := _bridge()
	if m == null:
		return fail(&"no_model")
	return m.call("AvailabilityResearch", ctx)


static func check_refit(ctx: Dictionary) -> Dictionary:
	var m := _bridge()
	if m == null:
		return fail(&"no_model")
	return m.call("AvailabilityRefit", ctx)


static func check_build(ctx: Dictionary) -> Dictionary:
	var m := _bridge()
	if m == null:
		return fail(&"no_model")
	return m.call("AvailabilityBuild", ctx)
