extends RefCounted
## 职责：调试调参写回（**只写源目录的 Content/data/*.json**）
## 属于：Engine/debug
## 对外：set_value(json_path, pointer, value) / get_value(json_path, pointer)
## 铁律（AGENTS.md）：调试面板改的数值必须写回源目录 JSON，不许写构建输出目录里的副本。
##   · 只允许 res://Content/data/ 下的文件；
##   · pointer 用 "a.b.c" 或 "a[0].b" 形式；
##   · 写完立刻回读校验（读不回来算失败）。

const JsonFile := preload("res://Engine/util/json_file.gd")

const ALLOWED_PREFIX := "res://Content/data/"


static func is_allowed(json_path: String) -> bool:
	return json_path.begins_with(ALLOWED_PREFIX) and json_path.ends_with(".json")


static func _split_pointer(pointer: String) -> Array:
	var parts: Array = []
	for seg in pointer.split(".", false):
		var name := seg
		var brackets := name.find("[")
		if brackets >= 0:
			var head := name.substr(0, brackets)
			if not head.is_empty():
				parts.append(head)
			var inner := name.substr(brackets + 1).trim_suffix("]")
			parts.append(int(inner))
		else:
			parts.append(name)
	return parts


static func get_value(json_path: String, pointer: String) -> Variant:
	if not is_allowed(json_path):
		push_error("[Tuner] 只允许写源目录 Content/data/：" + json_path)
		return null
	var data: Variant = JsonFile.read(json_path, null)
	if data == null:
		return null
	var cur: Variant = data
	for p in _split_pointer(pointer):
		if p is int:
			if not (cur is Array) or p >= (cur as Array).size():
				return null
			cur = (cur as Array)[p]
		else:
			if not (cur is Dictionary) or not (cur as Dictionary).has(p):
				return null
			cur = (cur as Dictionary)[p]
	return cur


static func set_value(json_path: String, pointer: String, value: Variant) -> bool:
	if not is_allowed(json_path):
		push_error("[Tuner] 只允许写源目录 Content/data/：" + json_path)
		return false
	var data: Variant = JsonFile.read(json_path, null)
	if not (data is Dictionary):
		push_error("[Tuner] 数据文件不存在或不是对象：" + json_path)
		return false
	var parts := _split_pointer(pointer)
	if parts.is_empty():
		return false
	var cur: Variant = data
	for i in parts.size() - 1:
		var p: Variant = parts[i]
		if p is int:
			if not (cur is Array) or int(p) >= (cur as Array).size():
				push_error("[Tuner] 路径越界：%s" % pointer)
				return false
			cur = (cur as Array)[int(p)]
		else:
			if not (cur is Dictionary) or not (cur as Dictionary).has(p):
				push_error("[Tuner] 路径不存在：%s" % pointer)
				return false
			cur = (cur as Dictionary)[p]
	var last: Variant = parts[parts.size() - 1]
	if last is int:
		if not (cur is Array) or int(last) >= (cur as Array).size():
			return false
		(cur as Array)[int(last)] = value
	else:
		if not (cur is Dictionary):
			return false
		(cur as Dictionary)[last] = value
	var err := JsonFile.write_atomic(json_path, data)
	if err != OK:
		return false
	return get_value(json_path, pointer) == value
