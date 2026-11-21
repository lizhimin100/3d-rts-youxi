extends RefCounted
## 职责：GDScript → C# 内核的**唯一取桥入口**
## 属于：Game/adapters（过渡层）
##
## 为什么不用自动加载：Cfg/_init 在自动加载序列里跑得比某些节点早，
## 实测正常启动时 `root.get_node_or_null("Mdl")` 拿不到（--script 模式反而拿得到）。
## 改成**懒建一个 RefCounted**：谁先用到谁实例化，静态缓存一份，退出时引用计数归零。
## 桥本身不碰场景树，`DamageCompute` 之类的纯函数调用不需要进树。

const BRIDGE_PATH := "res://Screens/bridge/ModelBridge.cs"

static var _inst: RefCounted = null
static var _reported: bool = false


static func get_bridge() -> RefCounted:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	var s := load(BRIDGE_PATH) as Script
	if s == null:
		if not _reported:
			_reported = true
			push_error("[Model] bridge script not loadable: " + BRIDGE_PATH)
		return null
	_inst = s.new() as RefCounted
	if _inst == null and not _reported:
		_reported = true
		push_error("[Model] bridge instantiate failed (C# kernel not built?)")
	return _inst
