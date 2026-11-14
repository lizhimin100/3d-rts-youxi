extends Node
## 职责：存档（唯一出口）—— 槽位、原子写、版本迁移钩子、测试隔离
## 属于：Engine/save（自动加载 SaveSvc）
## 对外：save(slot,payload) / load_slot(slot) / list_slots() / delete(slot) /
##       set_validator(cb) / root() / is_test_profile()
## 禁改：
##   · 测试模式（App.test_mode）**只**能读 user://profiles/test/，不许碰玩家真实存档；
##   · 具体存档 schema 不写在这里，由游戏注册 validator（Model/save/save_schema.gd）。

const WRAP_VERSION := 1
const JsonFile := preload("res://Engine/util/json_file.gd")

## 由游戏在启动时注册：func(payload: Dictionary) -> Dictionary {ok:bool, data:Dictionary, errors:Array}
var _validator: Callable = Callable()
var _last_error: String = ""


func _ready() -> void:
	if App != null and App.test_mode:
		# 双保险：测试模式绝不落玩家目录
		App.profile = "test"


func root() -> String:
	# ★ 测试模式写**项目内**的隔离目录：不碰 player 真实存档（user://），
	#   也不依赖运行环境能不能写 AppData（无头 CI / 沙箱里常常不能）。
	#   这个目录在 .gitignore 里，跑完 --check 也不会进版本库。
	if App != null and App.test_mode:
		return "res://.test_profile/"
	var profile := "default"
	if App != null:
		profile = App.profile
	return "user://profiles/%s/" % profile


func saves_dir() -> String:
	return root() + "saves/"


func slot_path(slot: int) -> String:
	return saves_dir() + "slot_%02d.json" % slot


func is_test_profile() -> bool:
	return root().contains(".test_profile")


func set_validator(cb: Callable) -> void:
	_validator = cb


## 保存。payload 是纯数据 Dictionary。返回是否成功。
func save(slot: int, payload: Dictionary) -> bool:
	_last_error = ""
	if slot < 1 or slot > 99:
		_last_error = "槽位越界（1~99）：%d" % slot
		push_error("[Save] " + _last_error)
		return false
	if _validator.is_valid():
		var res: Dictionary = _validator.call(payload)
		if not bool(res.get("ok", false)):
			_last_error = "校验失败：%s" % str(res.get("errors", []))
			push_error("[Save] " + _last_error)
			return false
		payload = res.get("data", payload)
	var wrap := {
		"wrap_version": WRAP_VERSION,
		"slot": slot,
		"saved_at": Time.get_datetime_string_from_system(true),
		"profile": App.profile if App != null else "default",
		"payload": payload,
	}
	var err := JsonFile.write_atomic(slot_path(slot), wrap)
	if err != OK:
		_last_error = "写盘失败 %d" % err
		return false
	return true


## 读档。不存在 / 损坏 / 版本不认识 → 返回空字典（并记录错误，不抛异常）。
func load_slot(slot: int) -> Dictionary:
	_last_error = ""
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var wrap: Dictionary = JsonFile.read_dict(path, {})
	if wrap.is_empty():
		_last_error = "存档损坏：" + path
		return {}
	if int(wrap.get("wrap_version", 0)) > WRAP_VERSION:
		_last_error = "存档来自更新的版本：%d" % int(wrap.get("wrap_version", 0))
		return {}
	var payload: Dictionary = wrap.get("payload", {})
	if _validator.is_valid():
		var res: Dictionary = _validator.call(payload)
		if not bool(res.get("ok", false)):
			_last_error = "读档校验失败：%s" % str(res.get("errors", []))
			return {}
		payload = res.get("data", payload)
	return payload


func list_slots() -> Array:
	var out: Array = []
	var dir := DirAccess.open(saves_dir())
	if dir == null:
		return out
	for f in dir.get_files():
		if f.begins_with("slot_") and f.ends_with(".json"):
			var n := f.trim_prefix("slot_").trim_suffix(".json").to_int()
			out.append(n)
	out.sort()
	return out


func delete(slot: int) -> bool:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


func last_error() -> String:
	return _last_error
