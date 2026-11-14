extends RefCounted
## 职责：平台接口（成就 / 云存档 / 用户身份）—— **所有平台差异只在这层后面**
## 属于：Engine/platform
## 对外：见下面每个方法；子类覆盖
## 禁改：游戏代码不许出现 OS.get_name()/Steam/Android 判断；要平台能力就调这里。


## 平台 id："local" / "headless" / "steam" / "mobile"（日志与存档用）
func id() -> String:
	return "base"


## 这个平台现在能不能用（Steam 没起客户端 → false，但游戏照常跑）
func is_available() -> bool:
	return true


## 用户显示名（没有就返回空串）
func user_display_name() -> String:
	return ""


func unlock_achievement(_achievement_id: String) -> bool:
	return false


func has_achievement(_achievement_id: String) -> bool:
	return false


## 把成就批量刷到平台上（local 平台是无操作）
func flush_achievements() -> void:
	pass


## 云存档：写/读/删/列。没有云能力的平台返回 false / 空。
func cloud_write(_key: String, _bytes: PackedByteArray) -> bool:
	return false


func cloud_read(_key: String) -> PackedByteArray:
	return PackedByteArray()


func cloud_delete(_key: String) -> bool:
	return false


func cloud_list() -> Array:
	return []
