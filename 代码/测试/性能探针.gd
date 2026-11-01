extends Node
## **性能探针（长跑采样）** —— 每 N 秒打一行 PERF2，用来看"内存有没有一路涨"。
##
## 启用：`godot --path . --quit-after 6000 -- --perf-long`
##       `--perf-long=5` 改采样间隔（秒）
##
## 为什么不用 `--perf`：那个是**冷启动单点**（2.5s 一拍就退出），
## 看得出来"多重"，看不出来"会不会一直涨"——而后者才是泄漏。
##
## 记的口径（全部来自 Performance 监视器，不自己估）：
##   fps / 绘制调用 / 图元 / 渲染对象 / 节点数 / 静态内存 / 单位与野怪数 / 树矿数

## 采样间隔（秒）；命令行 --perf-long=秒 可覆盖
var interval: float = 4.0
var _t: float = 0.0
var _n: int = 0
## 上一拍的寻路计数（用来算"这 8 秒里算了多少次路、平均每次多贵"）
var _pc: int = 0
var _pu: int = 0
## 各子系统上一拍的累计微秒（用来算"这一秒里它们各吃了多少 CPU"）
var _sys: Dictionary = {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--perf-long="):
			interval = maxf(1.0, float(a.get_slice("=", 1)))
	print("[探针] 每 %.1fs 采样一次（PERF2 行）" % interval)


func _process(delta: float) -> void:
	_t += delta
	if _t < interval:
		return
	_t = 0.0
	_n += 1
	var pc: int = RtsWorld.dbg_path_calls
	var pu: int = RtsWorld.dbg_path_usec
	var dcalls: int = pc - _pc
	var dusec: int = pu - _pu
	_pc = pc
	_pu = pu
	# 各系统这一段的毫秒/秒（累计差值 ÷ 采样间隔）
	var sys := {
		"unit": RtsUnit.dbg_usec,
		"u.order": RtsUnit.dbg_order,
		"u.move": RtsUnit.dbg_move,
		"u.sep": RtsUnit.dbg_sep,
		"u.ground": RtsUnit.dbg_ground,
		"ai": SimpleAI.dbg_usec,
		"fog": RtsFog.dbg_usec,
		"hud": RtsHud.dbg_usec,
		# u.order 的子项：把"这一大块到底谁在吃"拆开
		"o.acq": RtsUnit.dbg_acquire,
		"o.gather": RtsUnit.dbg_gather,
		"o.atk": RtsUnit.dbg_atk,
		"o.amove": RtsUnit.dbg_amove,
		"o.goto": RtsUnit.dbg_goto,
		"o.sgoal": RtsUnit.dbg_sgoal,
	}
	var sys_ms := {}
	for k in sys.keys():
		var prev: int = int(_sys.get(k, 0))
		sys_ms[k] = "%.1f" % (float(int(sys[k]) - prev) / 1000.0 / maxf(interval, 0.01))
		_sys[k] = int(sys[k])
	var m := {
		"n": _n,
		"t": "%.0f" % Game.elapsed,
		"fps": int(Performance.get_monitor(Performance.TIME_FPS)),
		"draw": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"prim": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"robj": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"mem_mb": "%.1f" % (Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0),
		# CPU 侧：process/physics 的每帧耗时（毫秒）。和 vsync 无关，
		# 才知道"60fps 是真有余量还是刚好卡在 16.6ms"
		"proc_ms": "%.2f" % (Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0),
		"phys_ms": "%.2f" % (Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0),
		"obj": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"res_obj": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"units": Game.all_units().size(),
		"creeps": Game.neutral_faction.count_units() if Game.neutral_faction != null else 0,
		"res": Game.all_harvestables().size(),
		"night": Game.is_night(),
		# 寻路：这一段里算了几次 / 平均每次多少微秒 / 一共占了多少毫秒每秒
		"path_n": dcalls,
		"path_us": (dusec / maxi(dcalls, 1)),
		"path_ms_per_s": "%.2f" % (float(dusec) / 1000.0 / maxf(interval, 0.01)),
		# 各子系统"每秒吃掉多少毫秒 CPU"：unit=全部单位逻辑 / ai=四个大脑 / fog / hud
		"sys": sys_ms,
	}
	# 指令分布普查：每拍重算一次，看"到底有多少单位在做贵的事"
	var hist: Dictionary = {}
	var mobile: int = 0
	var idle: int = 0
	for u in Game.all_units():
		if u == null or not is_instance_valid(u) or not u is RtsUnit:
			continue
		var ru: RtsUnit = u
		if not ru.is_alive():
			continue
		var k: String = str(int(ru.order))
		hist[k] = int(hist.get(k, 0)) + 1
		if ru.is_mobile():
			mobile += 1
		if int(ru.order) == RtsConst.Order.NONE:
			idle += 1
	m["goto_n"] = RtsUnit.dbg_goto_n
	m["hist"] = hist
	m["mobile"] = mobile
	m["idle"] = idle
	print("PERF2 " + JSON.stringify(m))
