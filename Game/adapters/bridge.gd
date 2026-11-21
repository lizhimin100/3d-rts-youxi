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
static var _checked: bool = false
static var _unavailable: bool = false


## 取桥。非 .NET 版 Godot（例如 Steam 标准版）会安静地返回 null：
##   · 编辑器仍然能改数据/写回（dev_data 只读 JSON，不依赖 C#）；
##   · DPS 靶场会显示“需要 .NET 内核”，而不是刷一堆 No loader found。
static func get_bridge() -> RefCounted:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	if not _checked:
		_checked = true
		if not ClassDB.class_exists("CSharpScript"):
			_unavailable = true
			print("[Model] C# kernel unavailable: this Godot build has no C# support. Data editing works; DPS needs a .NET build.")
			return null
		if not FileAccess.file_exists(BRIDGE_PATH):
			_unavailable = true
			print("[Model] bridge file missing: " + BRIDGE_PATH)
			return null
		if not ResourceLoader.exists(BRIDGE_PATH, "Script"):
			_unavailable = true
			print("[Model] bridge not loadable (C# assembly not built?): " + BRIDGE_PATH)
			return null
	if _unavailable:
		return null
	var s := load(BRIDGE_PATH) as Script
	if s == null:
		_unavailable = true
		print("[Model] bridge script not loadable: " + BRIDGE_PATH)
		return null
	_inst = s.new() as RefCounted
	if _inst == null:
		_unavailable = true
		print("[Model] bridge instantiate failed (C# kernel not built?)")
	return _inst
