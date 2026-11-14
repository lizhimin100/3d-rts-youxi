extends Node
## 职责：多语言（唯一出口）—— CSV 是唯一文案来源，代码里不许写死文案
## 属于：Engine/i18n（自动加载 I18n）
## 对外：t(key, params) / set_locale(code) / locale / missing_keys() / stats()
## 数据：res://Content/i18n/ui.csv，列：key,zh,en[,note][,更多语言…]
## 禁改：不要在别的脚本里再写一份中文文案表；缺 key 要报错，不要静默返回空串。

const CSV_PATH := "res://Content/i18n/ui.csv"

## 当前语言（zh / en，后续可加 ja 等；列名就是语言码）
var locale: String = "zh"
## key -> {列名: 文案}
var _table: Dictionary = {}
## 缺过的 key（--check 会读，空集才算通过）
var _missing: Dictionary = {}
var _columns: Array[String] = []
var _loaded: bool = false
var _load_error: String = ""


func _ready() -> void:
	load_csv()


func load_csv() -> void:
	_loaded = true
	_table.clear()
	_columns.clear()
	_load_error = ""
	var f := FileAccess.open(CSV_PATH, FileAccess.READ)
	if f == null:
		_load_error = "打不开 " + CSV_PATH
		push_error("[I18n] " + _load_error)
		return
	var header := f.get_csv_line()
	if header.size() < 3 or header[0] != "key":
		_load_error = "表头必须是 key,zh,en[,note]"
		push_error("[I18n] " + _load_error)
		f.close()
		return
	for i in header.size():
		_columns.append(header[i].strip_edges())
	var line_no := 1
	while not f.eof_reached():
		var row := f.get_csv_line()
		line_no += 1
		if row.size() == 1 and row[0].strip_edges().is_empty():
			continue
		var key := row[0].strip_edges()
		if key.is_empty():
			continue
		var entry := {}
		for c in range(1, mini(row.size(), _columns.size())):
			entry[_columns[c]] = row[c]
		_table[key] = entry
	f.close()
	if _table.is_empty():
		_load_error = "一张文案都没有：" + CSV_PATH


## 取文案。params 用 {name} 占位符。
func t(key: String, params: Dictionary = {}) -> String:
	if not _loaded:
		load_csv()
	var entry: Dictionary = _table.get(key, {})
	var text := String(entry.get(locale, ""))
	if text.is_empty():
		# 回退顺序：当前语言 → zh → 英文 → key 本身（并把缺 key 记下来）
		text = String(entry.get("zh", ""))
		if text.is_empty():
			text = String(entry.get("en", ""))
		if text.is_empty():
			_missing[key] = true
			push_error("[I18n] 缺 key：%s" % key)
			return key
	for k in params.keys():
		text = text.replace("{%s}" % k, str(params[k]))
	return text


func has(key: String) -> bool:
	if not _loaded:
		load_csv()
	return _table.has(key)


func set_locale(code: String) -> bool:
	if _columns.size() > 1 and not _columns.has(code):
		push_error("[I18n] 没有这一列语言：%s（现有：%s）" % [code, ", ".join(_columns)])
		return false
	locale = code
	return true


func columns() -> Array[String]:
	return _columns.duplicate()


func missing_keys() -> Array:
	return _missing.keys()


func keys() -> Array:
	return _table.keys()


func load_error() -> String:
	return _load_error


func stats() -> Dictionary:
	return {"keys": _table.size(), "locales": _columns.size() - 1, "missing": _missing.size(), "error": _load_error}
