extends Node
## 职责：平台服务入口（自动加载 Platform）—— 选实现、转发调用、记录版本
## 属于：Engine/platform
## 对外：platform_id() / unlock(id) / has(id) / cloud_* / impl()
## 禁改：不要在游戏代码里判断平台；只调 Platform.unlock(...) 这种能力方法。

## 平台实现（RefCounted，见 platform_*.gd）
var _impl: RefCounted = null
## 平台选择：--platform=local|steam|mobile|headless；不传则按环境自动挑
var requested: String = ""


func _ready() -> void:
	requested = _arg_value("--platform")
	_select()


func _arg_value(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix + "="):
			return a.substr(prefix.length() + 1)
	return ""


func _select() -> void:
	var want := requested
	if want.is_empty():
		if DisplayServer.get_name() == "headless" or (App != null and App.test_mode):
			want = "headless"
		elif OS.get_name() == "Android" or OS.get_name() == "iOS":
			want = "mobile"
		else:
			want = "local"
	match want:
		"steam":
			_impl = preload("res://Engine/platform/platform_steam.gd").new()
		"mobile":
			_impl = preload("res://Engine/platform/platform_mobile.gd").new()
		"headless":
			_impl = preload("res://Engine/platform/platform_headless.gd").new()
		_:
			_impl = preload("res://Engine/platform/platform_local.gd").new()
	print("[Platform] 平台 = %s（可用=%s）" % [platform_id(), str(impl().is_available())])


func impl() -> RefCounted:
	if _impl == null:
		_select()
	return _impl


func platform_id() -> String:
	return String(impl().call("id"))


func is_available() -> bool:
	return bool(impl().call("is_available"))


func display_name() -> String:
	return String(impl().call("user_display_name"))


func unlock(achievement_id: String) -> bool:
	return bool(impl().call("unlock_achievement", achievement_id))


func has(achievement_id: String) -> bool:
	return bool(impl().call("has_achievement", achievement_id))


func flush() -> void:
	impl().call("flush_achievements")


func cloud_write(key: String, bytes: PackedByteArray) -> bool:
	return bool(impl().call("cloud_write", key, bytes))


func cloud_read(key: String) -> PackedByteArray:
	return impl().call("cloud_read", key)


func cloud_delete(key: String) -> bool:
	return bool(impl().call("cloud_delete", key))


func cloud_list() -> Array:
	return impl().call("cloud_list")
