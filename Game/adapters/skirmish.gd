extends RefCounted
## 职责：--simulate 推演的 **GDScript 适配层**
## 属于：Game/adapters（过渡层，调用方 API 不变）
## 真正实现：`Model/Battle/Skirmish.cs`。配置用纯 Dictionary 传进来，结果形状不变。

const BRIDGE := preload("res://Game/adapters/bridge.gd")


static func _bridge() -> RefCounted:
	return BRIDGE.get_bridge()

## 返回错误字符串数组（空 = 合法）
static func validate(config: Dictionary) -> Array:
	var m := _bridge()
	if m == null:
		return ["Mdl missing"]
	return m.call("SimValidate", config)


static func run(config: Dictionary) -> Dictionary:
	var m := _bridge()
	if m == null:
		return {"ok": false, "errors": ["Mdl missing"]}
	return m.call("Simulate", config)
