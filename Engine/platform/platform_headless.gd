extends "res://Engine/platform/platform_interface.gd"
## 职责：无头/自检平台实现 —— 一切能力都是内存里的，不落盘、不联网
## 属于：Engine/platform
## 用途：run-game --check / --simulate / --shot 与 CI；保证测试永远不会写玩家真实数据

var _achievements: Dictionary = {}


func id() -> String:
	return "headless"


func user_display_name() -> String:
	return "headless"


func unlock_achievement(achievement_id: String) -> bool:
	if achievement_id.is_empty():
		push_error("[Platform] 成就 id 为空")
		return false
	_achievements[achievement_id] = true
	return true


func has_achievement(achievement_id: String) -> bool:
	return _achievements.has(achievement_id)


func flush_achievements() -> void:
	# 反复调用不该重复上报：这里就是幂等空操作
	pass
