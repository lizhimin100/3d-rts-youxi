extends Node
## 职责：只监听 127.0.0.1 的调试接口（HTTP/JSON）—— 截图 / 读状态 / 执行动作 / 关闭游戏
## 属于：Engine/debug（自动加载 DbgBridge）
## 对外：maybe_start() / stop() / is_running() / port() / register_state(cb) /
##       register_action(name, cb) / base_url()
## 安全：
##   · 只绑定 127.0.0.1（不是 0.0.0.0），外部机器连不上；
##   · 发行构建（release）永远不启动；`Engine/debug/` 整个目录在导出时被排除；
##   · 无头自检默认不启动（避免并行跑测试时抢端口），要开就 --debug-bridge。
## 协议（给 agent 与 Tools/qa 用，全部 JSON）：
##   GET  /health            进程/版本/是否测试/运行时长
##   GET  /state             当前状态（由游戏注册）
##   GET  /screenshot?save=1 存一张 PNG，返回路径
##   POST /action            {"name":"…","args":{…}}
##   POST /quit              退出游戏
##   GET  /help              端点与动作清单

const DEFAULT_PORT := 18777
const Screenshot := preload("res://Engine/debug/screenshot.gd")
const DebugTuner := preload("res://Engine/debug/debug_tuner.gd")

var _server := TCPServer.new()
var _clients: Array = []
var _running := false
var _port := DEFAULT_PORT
var _state_cb: Callable = Callable()
var _actions: Dictionary = {}
var _requests := 0


func _ready() -> void:
	set_process(false)
	_register_builtin_actions()


func _register_builtin_actions() -> void:
	register_action("screenshot", func(a: Dictionary) -> Dictionary:
		var path := String(a.get("path", Screenshot.default_dir() + "bridge-%d.png" % Time.get_ticks_msec()))
		var saved := Screenshot.capture(path)
		return {"ok": not saved.is_empty(), "path": saved})
	register_action("quit", func(_a: Dictionary) -> Dictionary:
		get_tree().quit(0)
		return {"ok": true})
	register_action("tune", func(a: Dictionary) -> Dictionary:
		var ok := DebugTuner.set_value(String(a.get("file", "")), String(a.get("pointer", "")), a.get("value"))
		return {"ok": ok})
	register_action("boot_report", func(_a: Dictionary) -> Dictionary:
		return {"ok": true, "report": App.boot_report()})


func maybe_start() -> void:
	if _running:
		return
	if App == null or App.release:
		return
	if not OS.is_debug_build():
		return
	if App.has_arg("--no-debug-bridge"):
		return
	var explicit := App.has_arg("--debug-bridge")
	var headless := DisplayServer.get_name() == "headless"
	if headless and not explicit:
		return
	if App.has_arg_prefix("--debug-port"):
		_port = App.arg("--debug-port", str(DEFAULT_PORT)).to_int()
	if _port <= 0 or _port > 65535:
		_port = DEFAULT_PORT
	var err := _server.listen(_port, "127.0.0.1")
	if err != OK:
		push_warning("[Dbg] 端口 %d 占用（%d），调试接口未启动" % [_port, err])
		return
	_running = true
	set_process(true)
	print("[Dbg] 调试接口：http://127.0.0.1:%d/ （pid=%d boot=%s）" % [_port, OS.get_process_id(), App.boot_id])


func stop() -> void:
	if not _running:
		return
	_running = false
	set_process(false)
	_server.stop()
	for c in _clients:
		var peer: StreamPeerTCP = c.get("peer")
		if peer != null:
			peer.disconnect_from_host()
	_clients.clear()


func is_running() -> bool:
	return _running


func port() -> int:
	return _port


func base_url() -> String:
	return "http://127.0.0.1:%d" % _port


func register_state(cb: Callable) -> void:
	_state_cb = cb


func register_action(action_name: String, cb: Callable) -> void:
	if action_name.is_empty() or not cb.is_valid():
		push_error("[Dbg] 注册动作失败：" + action_name)
		return
	_actions[action_name] = cb


func actions() -> Array:
	return _actions.keys()


# ===========================================================================
# 网络循环
# ===========================================================================
func _process(_dt: float) -> void:
	_accept_clients()
	_pump_clients()


func _accept_clients() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			continue
		_clients.append({"peer": peer, "buf": PackedByteArray(), "done": false, "age": 0.0})


func _pump_clients() -> void:
	var keep: Array = []
	for c in _clients:
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			continue
		# ★ 刚 accept 的连接会有一帧处于 CONNECTING：**不能丢**（丢了客户端就永远等不到响应）
		if status != StreamPeerTCP.STATUS_CONNECTED:
			c["age"] = float(c.get("age", 0.0)) + get_process_delta_time()
			if float(c["age"]) < 15.0:
				keep.append(c)
			else:
				peer.disconnect_from_host()
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			var got: Array = peer.get_data(avail)
			if int(got[0]) == OK:
				# ★ PackedByteArray 是值类型：cast 出来的是副本，必须写回字典
				var buf: PackedByteArray = c["buf"]
				buf.append_array(got[1])
				c["buf"] = buf
		if not bool(c.get("done", false)):
			_try_handle(c)
		if not bool(c.get("done", false)):
			keep.append(c)
	_clients = keep


func _try_handle(c: Dictionary) -> bool:
	var buf: PackedByteArray = c["buf"]
	if buf.is_empty():
		return false
	var text := buf.get_string_from_utf8()
	var head_end := text.find("\r\n\r\n")
	if head_end < 0:
		return false
	var head := text.substr(0, head_end)
	var lines := head.split("\r\n")
	if lines.is_empty():
		return false
	var req_line := lines[0].split(" ")
	if req_line.size() < 2:
		_send(c, 400, {"ok": false, "error": "bad request line"})
		return true
	var method := req_line[0]
	var target := req_line[1]
	var content_length := 0
	for i in range(1, lines.size()):
		var line := lines[i]
		var colon := line.find(":")
		if colon > 0 and line.substr(0, colon).to_lower().strip_edges() == "content-length":
			content_length = line.substr(colon + 1).strip_edges().to_int()
	var body_start := buf.size() - (text.length() - (head_end + 4))
	if buf.size() - body_start < content_length:
		return false
	var body_text := ""
	if content_length > 0:
		body_text = buf.slice(body_start, body_start + content_length).get_string_from_utf8()
	_requests += 1
	var query := {}
	var path := target
	var q := target.find("?")
	if q >= 0:
		path = target.substr(0, q)
		for kv in target.substr(q + 1).split("&", false):
			var eq := kv.find("=")
			if eq > 0:
				query[kv.substr(0, eq)] = kv.substr(eq + 1).uri_decode()
	var body: Variant = null
	if not body_text.is_empty():
		var parser := JSON.new()
		if parser.parse(body_text) == OK:
			body = parser.data
	else:
		body = null
	var resp := _route(method, path, query, body)
	_send(c, int(resp.get("code", 200)), resp.get("body", {}))
	return true


func _route(method: String, path: String, query: Dictionary, body: Variant) -> Dictionary:
	match path:
		"/health":
			return _ok({
				"ok": true,
				"pid": OS.get_process_id(),
				"boot_id": App.boot_id,
				"version": App.VERSION,
				"test": App.test_mode,
				"release": App.release,
				"uptime_ms": Time.get_ticks_msec() - App.boot_ms,
				"requests": _requests,
				"actions": actions(),
			})
		"/state":
			if not _state_cb.is_valid():
				return _err(503, "没有注册状态提供者")
			return _ok({"ok": true, "state": _state_cb.call()})
		"/screenshot":
			var path_out := String(query.get("path", Screenshot.default_dir() + "bridge-%d.png" % Time.get_ticks_msec()))
			var saved := Screenshot.capture(path_out)
			if saved.is_empty():
				return _err(409, "取不到画面（无头模式不能截图）")
			return _ok({"ok": true, "path": saved})
		"/help":
			return _ok({"ok": true, "endpoints": ["/health", "/state", "/screenshot", "/action", "/quit", "/help"],
				"actions": actions()})
		"/quit":
			get_tree().quit(0)
			return _ok({"ok": true, "bye": true})
		"/action":
			if method != "POST":
				return _err(405, "请用 POST")
			if not (body is Dictionary):
				return _err(400, "body 必须是 JSON 对象")
			var action_name := String(body.get("name", ""))
			if not _actions.has(action_name):
				return _err(404, "没有这个动作：" + action_name + "（现有：%s）" % ", ".join(actions()))
			var args: Dictionary = body.get("args", {})
			var result: Variant = (_actions[action_name] as Callable).call(args)
			if result is Dictionary:
				var out: Dictionary = (result as Dictionary).duplicate()
				out["ok"] = bool(out.get("ok", true))
				return _ok(out)
			return _ok({"ok": true, "result": result})
	return _err(404, "未知端点：" + path)


func _ok(data: Dictionary, code: int = 200) -> Dictionary:
	return {"code": code, "body": data}


func _err(code: int, message: String) -> Dictionary:
	return {"code": code, "body": {"ok": false, "error": message}}


func _send(c: Dictionary, code: int, body: Dictionary) -> void:
	var peer: StreamPeerTCP = c["peer"]
	var text := JSON.stringify(body)
	var reason := "OK" if code == 200 else ("Not Found" if code == 404 else "Error")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n" % [code, reason, text.to_utf8_buffer().size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(text.to_utf8_buffer())
	peer.disconnect_from_host()
	c["done"] = true
	c["buf"] = PackedByteArray()
