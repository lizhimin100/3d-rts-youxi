extends RefCounted
## 职责：把 Model 的存档 schema 接到 Engine/save（组合根在 App）
## 属于：Game/core

const SaveSchema := preload("res://Game/adapters/save_schema.gd")


func install() -> void:
	SaveSvc.set_validator(func(payload: Dictionary) -> Dictionary:
		return SaveSchema.validate(payload))
