extends "res://Engine/platform/platform_interface.gd"
## 职责：本地平台实现（无 Steam 也能玩）—— 成就与"云存档"落在本机档案目录
## 属于：Engine/platform
## 数据：user://profiles/<profile>/platform.json（测试模式下自动隔离）

const JsonFile := preload("res://Engine/util/json_file.gd")

var _state: Dictionary = {"achievements": {}, "cloud": {}}


func _init() -> void:
	_load()


func id() -> String:
	return "local"


func _state_path() -> String:
	return SaveSvc.root() + "platform.json"


func _load() -> void:
	_state = JsonFile.read_dict(_state_path(), {"achievements": {}, "cloud": {}})
	if not _state.has("achievements"):
		_state["achievements"] = {}
	if not _state.has("cloud"):
		_state["cloud"] = {}


func _flush() -> void:
	JsonFile.write_atomic(_state_path(), _state)


func unlock_achievement(achievement_id: String) -> bool:
	if achievement_id.is_empty():
		push_error("[Platform] 成就 id 为空")
		return false
	var list: Dictionary = _state["achievements"]
	if list.has(achievement_id):
		return true
	list[achievement_id] = Time.get_datetime_string_from_system(true)
	_flush()
	print("[Platform] 解锁成就 %s" % achievement_id)
	return true


func has_achievement(achievement_id: String) -> bool:
	return (_state["achievements"] as Dictionary).has(achievement_id)


func cloud_write(key: String, bytes: PackedByteArray) -> bool:
	if key.is_empty():
		return false
	(_state["cloud"] as Dictionary)[key] = Marshalls.raw_to_base64(bytes)
	_flush()
	return true


func cloud_read(key: String) -> PackedByteArray:
	var b64 := String((_state["cloud"] as Dictionary).get(key, ""))
	if b64.is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(b64)


func cloud_delete(key: String) -> bool:
	var cloud: Dictionary = _state["cloud"]
	if not cloud.has(key):
		return false
	cloud.erase(key)
	_flush()
	return true


func cloud_list() -> Array:
	return (_state["cloud"] as Dictionary).keys()
