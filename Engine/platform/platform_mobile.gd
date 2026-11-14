extends "res://Engine/platform/platform_interface.gd"
## 职责：手机平台实现（**预留位**）
## 属于：Engine/platform
## 现状：手机上 Godot 的 OS.get_name() 是 Android/iOS；这里只提供稳定的 id，
##       成就/云存档等平台服务（Google Play Games / Game Center）留空。

func id() -> String:
	return "mobile"


func user_display_name() -> String:
	return OS.get_environment("USER")
