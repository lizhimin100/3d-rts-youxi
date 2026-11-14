extends "res://Engine/platform/platform_interface.gd"
## 职责：Steam 平台实现（**预留位**）
## 属于：Engine/platform
## 现状：没有接 Steamworks SDK，所有能力都如实返回"不可用"，绝不假装成功。
## 接入时只改这一个文件 + 在 App 里把平台选择切到 steam，游戏代码一行不动。

func id() -> String:
	return "steam"


func is_available() -> bool:
	return false


func user_display_name() -> String:
	return ""


func unlock_achievement(achievement_id: String) -> bool:
	push_warning("[Platform] Steam 未接入，成就 %s 没有上报" % achievement_id)
	return false
