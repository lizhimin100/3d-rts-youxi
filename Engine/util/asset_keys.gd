extends Node
## 职责：资源 key 登记表（唯一出口）—— 音效 / 模型 / 图标 / 特效 / 着色器
## 属于：Engine/util（自动加载 Keys）
## 对外：path(kind, key) / has(kind, key) / all(kind) / reload()
## 数据：res://Content/keys/assets.json（由 Tools/gen/gen_asset_keys.gd 自动生成，不手写）
## 禁改：游戏代码不许直接拼 res://Content/art/… 路径；先登记 key 再取。

const INDEX_PATH := "res://Content/keys/assets.json"
const JsonFile := preload("res://Engine/util/json_file.gd")

var _data: Dictionary = {}
var _loaded: bool = false
var _errors: Array[String] = []


func _ready() -> void:
	reload()


func reload() -> void:
	_loaded = true
	_errors.clear()
	_data = JsonFile.read_dict(INDEX_PATH, {})
	if _data.is_empty():
		_errors.append("资源 key 表打不开或为空：" + INDEX_PATH)


func has(kind: String, key: String) -> bool:
	if not _loaded:
		reload()
	var bucket: Dictionary = _data.get(kind, {})
	return bucket.has(key)


## 取 key 对应的 res:// 路径；没有这个 key 返回空串并报错（不猜）
func path(kind: String, key: String) -> String:
	if not _loaded:
		reload()
	var bucket: Dictionary = _data.get(kind, {})
	var p := String(bucket.get(key, ""))
	if p.is_empty():
		push_error("[Keys] 未登记：%s/%s（先在 Content/keys/assets.json 里登记）" % [kind, key])
	return p


func all(kind: String) -> Dictionary:
	if not _loaded:
		reload()
	return _data.get(kind, {})


func kinds() -> Array:
	if not _loaded:
		reload()
	return _data.keys()


func errors() -> Array[String]:
	return _errors


## 供 --check 用：key 数量统计
func stats() -> Dictionary:
	if not _loaded:
		reload()
	var out := {}
	for k in _data.keys():
		if _data[k] is Dictionary:
			out[k] = (_data[k] as Dictionary).size()
	return out
