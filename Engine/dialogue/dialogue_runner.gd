extends RefCounted
## 职责：对话运行时（数据驱动、无 UI）—— 节点推进 / 分支条件 / 标记效果
## 属于：Engine/dialogue
## 对外：new(data) / start(id) / current() / advance() / choose(i) / flags
## 数据格式（Content/data/dialogue/*.json）：
##   { "start": "n1",
##     "nodes": { "n1": { "speaker": "副官", "text": "ui.dlg.intro.1",
##                        "next": "n2",
##                        "choices": [ {"text":"ui.dlg.yes","goto":"n3","requires":{"met":true}} ],
##                        "set": {"met": true} } } }
## 禁改：不许在这里画 UI、不许读输入、不许直接读文件（数据由调用方传入）。

signal node_changed(node_id: String)
signal finished()

var flags: Dictionary = {}
var _data: Dictionary = {}
var _node_id: String = ""
var _done := true


func _init(data: Dictionary) -> void:
	_data = data


func start(node_id: String = "") -> bool:
	flags.clear()
	var first := node_id
	if first.is_empty():
		first = String(_data.get("start", ""))
	if not _nodes().has(first):
		push_error("[Dialogue] 起始节点不存在：%s" % first)
		return false
	_done = false
	_goto(first)
	return true


func _nodes() -> Dictionary:
	return _data.get("nodes", {})


func _goto(node_id: String) -> void:
	var node: Dictionary = _nodes().get(node_id, {})
	if node.is_empty():
		push_error("[Dialogue] 节点不存在：%s" % node_id)
		_done = true
		finished.emit()
		return
	_node_id = node_id
	var set_flags: Dictionary = node.get("set", {})
	for k in set_flags.keys():
		flags[k] = set_flags[k]
	node_changed.emit(node_id)


## 当前节点（UI 只读这个）。返回 {id, speaker, text, choices:[…], kind}
func current() -> Dictionary:
	if _done:
		return {}
	var node: Dictionary = _nodes().get(_node_id, {})
	var out := {
		"id": _node_id,
		"speaker": String(node.get("speaker", "")),
		"text": String(node.get("text", "")),
		"choices": visible_choices(),
		"kind": String(node.get("kind", "line")),
	}
	return out


## 当前可选的选项（requires 全中才显示）
func visible_choices() -> Array:
	var out: Array = []
	var node: Dictionary = _nodes().get(_node_id, {})
	for c in node.get("choices", []):
		if not (c is Dictionary):
			continue
		var req: Dictionary = c.get("requires", {})
		var ok := true
		for k in req.keys():
			if flags.get(k) != req[k]:
				ok = false
				break
		if ok:
			out.append(c)
	return out


func choose(index: int) -> bool:
	var choices := visible_choices()
	if index < 0 or index >= choices.size():
		push_error("[Dialogue] 选项越界：%d（当前 %d 个）" % [index, choices.size()])
		return false
	var c: Dictionary = choices[index]
	var set_flags: Dictionary = c.get("set", {})
	for k in set_flags.keys():
		flags[k] = set_flags[k]
	var goto := String(c.get("goto", ""))
	if goto.is_empty():
		_finish()
	else:
		_goto(goto)
	return true


## 推进到下一句；没有 next 就结束
func advance() -> void:
	if _done:
		return
	var node: Dictionary = _nodes().get(_node_id, {})
	if not visible_choices().is_empty():
		return
	var nxt := String(node.get("next", ""))
	if nxt.is_empty():
		_finish()
	else:
		_goto(nxt)


func is_done() -> bool:
	return _done


func current_id() -> String:
	return _node_id


func _finish() -> void:
	_done = true
	finished.emit()


## 校验数据（--check 与编辑器共用）：返回错误列表
static func validate(data: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var nodes: Dictionary = data.get("nodes", {})
	if nodes.is_empty():
		errs.append("没有 nodes")
		return errs
	var start := String(data.get("start", ""))
	if start.is_empty():
		errs.append("没有 start")
	elif not nodes.has(start):
		errs.append("start 指向不存在的节点：" + start)
	for id in nodes.keys():
		var node: Dictionary = nodes[id]
		var nxt := String(node.get("next", ""))
		if not nxt.is_empty() and not nodes.has(nxt):
			errs.append("%s.next 指向不存在的节点：%s" % [id, nxt])
		for c in node.get("choices", []):
			var goto := String(c.get("goto", ""))
			if not goto.is_empty() and not nodes.has(goto):
				errs.append("%s 的选项 goto 指向不存在的节点：%s" % [id, goto])
		if String(node.get("text", "")).is_empty():
			errs.append("%s 没有 text（应是 i18n key）" % id)
	return errs
