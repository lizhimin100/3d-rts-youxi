@tool
extends RefCounted
## ui.csv 的只读查表（编辑器插件里没有 I18n 自动加载，所以自己读一遍）。
## 属于：Screens/editor/map_shell
## 纪律：不在代码里写死文案；缺 key 就返回 key 本身，方便体检时一眼看出。

const CSV := "res://Content/i18n/ui.csv"

static var _table: Dictionary = {}
static var _loaded := false


static func load_table() -> void:
	_table.clear()
	_loaded = true
	var f := FileAccess.open(CSV, FileAccess.READ)
	if f == null:
		return
	var header := f.get_csv_line()
	var zh_col := 1
	for i in header.size():
		if String(header[i]) == "zh":
			zh_col = i
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() <= zh_col:
			continue
		var key := String(row[0]).strip_edges()
		if key.is_empty():
			continue
		_table[key] = String(row[zh_col])
	f.close()


static func t(key: String, params: Dictionary = {}) -> String:
	if not _loaded:
		load_table()
	var text := String(_table.get(key, key))
	for k in params.keys():
		text = text.replace("{%s}" % String(k), str(params[k]))
	return text
