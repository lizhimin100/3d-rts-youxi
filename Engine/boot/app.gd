extends Node
## 职责：启动引导（自动加载 App，**第一个**自动加载）
## 属于：Engine/boot
## 对外：test_mode / silent / profile / release / arg(name) / args / boot_report()
## 它做的四件事：
##   1. 判定"这次是不是测试运行"（无头 / --test / --check / --simulate / --shot / --autotest …）；
##   2. 测试模式**默认**就是：静音、不抢焦点、窗口挪出屏幕、存档隔离到 profiles/test/；
##   3. 装配引擎层服务（I18n / SaveSvc / AudioSvc / Platform / DbgBridge）；
##   4. 打印一行可证据化的启动横幅（--check 与调试接口都读它）。
## 禁改：不要在游戏代码里重复判定测试模式；一律读 App.test_mode。

const VERSION := "0.1.0"

## 命令行（-- 之后的用户参数）
var args: PackedStringArray = []
## 测试运行（决定存档隔离 / 静音 / 无焦点）
var test_mode := false
## 静音（测试默认 true）
var silent := false
## 存档档案名：default / test（测试强制 test）
var profile := "default"
## 发行构建（导出后 OS.is_debug_build() == false）
var release := false
## 启动时刻（毫秒）
var boot_ms := 0
var boot_id := ""

const TEST_FLAGS := ["--test", "--check", "--simulate", "--shot", "--autotest", "--interact-test",
	"--research-test", "--walk-test"]
const TEST_PREFIXES := ["--qa", "--shot", "--simulate", "--test", "--screen"]


func _init() -> void:
	boot_ms = Time.get_ticks_msec()
	boot_id = "%d-%d" % [OS.get_process_id(), boot_ms]
	release = not OS.is_debug_build()
	args = OS.get_cmdline_user_args()
	test_mode = _detect_test_mode()
	silent = test_mode or has_arg("--silent")
	profile = "test" if test_mode else _arg_value("--profile", "default")
	if test_mode:
		profile = "test"
	_configure_display()


func _detect_test_mode() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	if OS.get_environment("RTS_TEST") == "1":
		return true
	for a in args:
		if a in TEST_FLAGS:
			return true
		for p in TEST_PREFIXES:
			if a.begins_with(p):
				return true
	return false


func _configure_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# 测试运行绝不抢焦点
	if test_mode:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, false)
	# 截图/自动跑：窗口挪到屏幕外（不挡人、不抢焦点，但仍能渲染）
	if has_arg("--offscreen") or has_arg_prefix("--shot"):
		DisplayServer.window_set_position(Vector2i(-4000, -4000))


func _ready() -> void:
	call_deferred("_setup_services")


func _setup_services() -> void:
	if silent:
		var idx := AudioServer.get_bus_index("Master")
		if idx != -1:
			AudioServer.set_bus_mute(idx, true)
	# 服务都是自动加载节点；这里只做"顺序上的收尾"与平台选择确认
	print(boot_banner())
	_install_save_schema()
	if DbgBridge != null:
		DbgBridge.maybe_start()
		_install_debug_hooks()


## 存档 schema 由游戏侧提供（Engine/save 只认 {schema_version,payload} 外壳）
func _install_save_schema() -> void:
	var script: Script = load("res://Game/core/save_setup.gd")
	if script == null:
		return
	var setup: RefCounted = script.new()
	if setup != null and setup.has_method("install"):
		setup.call("install")


## 游戏侧钩子实例（必须持有引用：它注册的 Callable 绑在它身上）
var _debug_hooks: RefCounted = null


func _install_debug_hooks() -> void:
	if not DbgBridge.is_running():
		return
	var script: Script = load("res://Game/core/debug_hooks.gd")
	if script == null:
		return
	var hooks: RefCounted = script.new()
	if hooks == null or not hooks.has_method("install"):
		return
	# 游戏侧钩子：注册 /state 与 /action 的具体实现（引擎层不认识玩法）
	hooks.call("install", DbgBridge)
	_debug_hooks = hooks


func boot_banner() -> String:
	return "[Boot] 战争原岛 v%s | 模式=%s | 存档=%s | 音频=%s | Godot=%s | pid=%d | boot=%s" % [
		VERSION,
		"test" if test_mode else ("release" if release else "dev"),
		profile,
		"静音" if silent else "开",
		Engine.get_version_info().get("string", "?"),
		OS.get_process_id(),
		boot_id,
	]


func has_arg(name: String) -> bool:
	return args.has(name)


func has_arg_prefix(prefix: String) -> bool:
	for a in args:
		if a.begins_with(prefix):
			return true
	return false


func arg(name: String, fallback: String = "") -> String:
	return _arg_value(name, fallback)


func _arg_value(name: String, fallback: String) -> String:
	for a in args:
		if a.begins_with(name + "="):
			return a.substr(name.length() + 1)
	return fallback


## 测试/自检用：把当前模式打成一个字典
func boot_report() -> Dictionary:
	return {
		"version": VERSION,
		"test": test_mode,
		"silent": silent,
		"profile": profile,
		"release": release,
		"headless": DisplayServer.get_name() == "headless",
		"boot_id": boot_id,
		"pid": OS.get_process_id(),
	}
