extends RefCounted
## **命令调度器**：AI 的**唯一**下令出口。
##
## 为什么必须有它（不是"工具类"，是防命令风暴的核心）：
##   一次思考里会有 5~7 个管理器（经济/农民/生产/防守/撤退/巡逻/反愚蠢）各自下令，
##   直接调 `order_*` 会出现三种病，而且都很难查：
##     1. **同一单位同一次思考收到 2~3 条互相覆盖的命令**
##        （比如"回防"刚下完，"巡逻"又把它带走）；
##     2. **到达 → idle → 重发 → 到达** 的死循环：单位已经站在目标点上了，
##        调用方还在每个思考周期重发一条，A* 白算、动画 walk/idle 狂闪；
##     3. **撞墙 → 重发 → 再撞** 的自持循环：单位卡在墙角，管理器每 1.2 秒
##        重发一次同一条命令，永远出不来。
##
## 四条闸（顺序固定，都是"宁可不下令"）：
##   ① **控制权过滤**：玩家管着的单位直接剔除（见 代码/ai/控制权.gd）；
##   ② **到达判定**：已经站在目标点 ARRIVE_EPS 以内 → 不再下令；
##   ③ **重发节流**：同类移动命令 REISSUE 秒内不重复；
##      `defend / recall / retreat / sanity` 开头的标签**豁免**——
##      防守被节流会直接导致基地被拆（这条是拿事故换来的）；
##   ④ **卡死锁定**：连续被判定卡死的单位暂停移动命令，按 4→8→16→32 秒指数退避。
##
## 同一次思考内"后登记覆盖先登记" = 管理器执行顺序就是优先级。
## 反愚蠢审计**最后**跑，所以它的救火命令一定能覆盖前面所有命令。

## 单位已经在目标点这个距离内 → 视为"这条命令已经完成"，不再重发
const ARRIVE_EPS: float = 1.2
## 同类移动命令的重发节流（秒）
const REISSUE: float = 0.6
## 卡死锁定的基准时长（秒）与指数退避上限倍数
const STUCK_LOCK: float = 4.0
const STUCK_LOCK_MAX_MULT: float = 8.0
## 一次思考最多真发多少条命令（防御性上限，正常用不到）
const MAX_PER_TICK: int = 64
## 这些标签不参与重发节流（防守/撤退/救火）
const NO_THROTTLE := ["defend", "recall", "retreat", "sanity"]

## 移动类命令（参与卡死锁定与节流）。
## 做成 var 而不是 const：const 数组里引用"别的类的枚举常量"，
## 在部分 GDScript 版本里会退化成编译期求值失败，没必要冒这个险。
var MOVE_KINDS: Array = [RtsConst.Order.MOVE, RtsConst.Order.ATTACK, RtsConst.Order.ATTACK_MOVE]

var _now: float = 0.0
var _queue: Dictionary = {}
var _last_issue: Dictionary = {}
var _stuck_hits: Dictionary = {}
var _stuck_level: Dictionary = {}
var _stuck_until: Dictionary = {}
var _sent: int = 0
var _skipped: int = 0
var _throttled_n: int = 0
var _stuck_locked: int = 0
var _filtered: int = 0
var _dropped: int = 0
var _queued: int = 0


## 每次思考的第一件事
func begin(now: float) -> void:
	_now = now
	_queue.clear()
	_sent = 0
	_skipped = 0
	_throttled_n = 0
	_filtered = 0
	_dropped = 0
	_queued = 0
	_stuck_locked = 0


# ===========================================================================
# 过滤
# ===========================================================================

## AI 现在能不能指挥这批单位（控制权 + 卡死锁）
func available(units: Array) -> Array:
	var ok: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_method("is_alive") or not u.is_alive():
			continue
		ok.append(u)
	if Game.control != null:
		var before: int = ok.size()
		ok = Game.control.filter(ok)
		_filtered += before - ok.size()
	var out: Array = []
	for u in ok:
		var uid: int = u.get_instance_id()
		if _now < float(_stuck_until.get(uid, -1.0)):
			_stuck_locked += 1
			continue
		out.append(u)
	return out


## 这个单位是不是"已经在做这件事了"（到达判定）
func _already_doing(u, kind: int, point: Vector3, target) -> bool:
	if kind == RtsConst.Order.ATTACK and target != null:
		return u.target == target and int(u.order) == RtsConst.Order.ATTACK
	if point == Vector3.ZERO and kind != RtsConst.Order.MOVE:
		return int(u.order) == kind
	var here: Vector3 = u.global_position
	if here.distance_to(point) <= ARRIVE_EPS:
		return true
	if int(u.order) != kind:
		return false
	var cur: Vector3 = u.command_point()
	return cur.distance_to(point) <= ARRIVE_EPS


func _throttled(u, kind: int, label: String) -> bool:
	if not (kind in MOVE_KINDS):
		return false
	for tag in NO_THROTTLE:
		if label.begins_with(tag):
			return false
	var key: String = "%d|%d" % [u.get_instance_id(), kind]
	var last: float = float(_last_issue.get(key, -999.0))
	return _now - last < REISSUE


func _enqueue(units: Array, kind: int, point: Vector3, target, label: String) -> void:
	var ok: Array = available(units)
	for u in ok:
		if _already_doing(u, kind, point, target):
			_skipped += 1
			continue
		if _throttled(u, kind, label):
			_throttled_n += 1
			_skipped += 1
			continue
		_queue[u.get_instance_id()] = {
			"unit": u, "kind": kind, "point": point, "target": target, "label": label,
		}
		_queued += 1
		_last_issue["%d|%d" % [u.get_instance_id(), kind]] = _now


# ===========================================================================
# 语义化下令（管理器只调这些）
# ===========================================================================

func move(units: Array, point: Vector3, label: String = "") -> void:
	_enqueue(units, RtsConst.Order.MOVE, point, null, label)


func attack(units: Array, t: Node3D, label: String = "") -> void:
	if t == null or not is_instance_valid(t):
		return
	_enqueue(units, RtsConst.Order.ATTACK, t.global_position, t, label)


func attack_move(units: Array, point: Vector3, label: String = "") -> void:
	_enqueue(units, RtsConst.Order.ATTACK_MOVE, point, null, label)


func hold(units: Array, label: String = "") -> void:
	_enqueue(units, RtsConst.Order.HOLD, Vector3.ZERO, null, label)


func stop(units: Array, label: String = "") -> void:
	_enqueue(units, RtsConst.Order.STOP, Vector3.ZERO, null, label)


func gather(units: Array, node: Node3D, label: String = "") -> void:
	if node == null or not is_instance_valid(node):
		return
	var ok: Array = available(units)
	for u in ok:
		if int(u.order) == RtsConst.Order.GATHER and u.target == null:
			# 已经在采：只在资源点变了的时候重下（命令点判据在采集里不适用）
			# 无类型接住：资源点 free 后是悬空引用，带类型赋值会抛引擎错误（见 单位.gd 同处注释）
			var cur = u.get("_gather_node")
			if cur == node:
				_skipped += 1
				continue
		_queue[u.get_instance_id()] = {
			"unit": u, "kind": RtsConst.Order.GATHER, "point": node.global_position,
			"target": node, "label": label,
		}
		_queued += 1


## 建造是"占位"命令：立刻发出，并且把这个人从本次思考的队列里摘掉，
## 避免后面更晚登记的移动命令把他带走（农民跑去盖房子，结果被巡逻命令拉走）。
func build(builder, def: UnitDef, point: Vector3, yaw: float, label: String = "build") -> Node3D:
	if builder == null or not is_instance_valid(builder) or def == null:
		return null
	var ok: Array = available([builder])
	if ok.is_empty():
		return null
	_queue.erase(builder.get_instance_id())
	var site: Node3D = builder.order_build(def, point, yaw)
	if site != null:
		if Game.control != null:
			Game.control.claim_ai([builder])
		_sent += 1
	return site


## 修理也是"占位"命令（2C-5 P1-4）：接 REPAIR 命令口，语义与 build 相同 ——
## 立刻发出 + 从本 tick 队列摘掉，避免后面的移动命令把修理工拉走。
## 返回 true = 命令真的发出去了（调用方据此计数）。
func repair(builder, building: Node3D, label: String = "repair") -> bool:
	if builder == null or not is_instance_valid(builder) or building == null:
		return false
	if not is_instance_valid(building):
		return false
	var ok: Array = available([builder])
	if ok.is_empty():
		return false
	if not builder.has_method("order_repair"):
		return false
	_queue.erase(builder.get_instance_id())
	if not bool(builder.call("order_repair", building)):
		return false
	if Game.control != null:
		Game.control.claim_ai([builder])
	_sent += 1
	return true


## 残血撤退：走 `RtsUnit.order_retreat` 而不是普通 move。
##
## 为什么单独一个口（2026-11-07 玩家反馈「一被打就撤退，撤一半又冲回来」）：
##   普通 move 在行军途中还有 45% 索敌半径，撤退的残血兵会被路过的敌人
##   反复拽回去还手 → AI 下一轮又判它残血 → 再撤退，来回拉锯。
##   `order_retreat` 会立一个 `_retreat` 标记，撤退途中**完全不索敌**。
## 同样从本 tick 队列摘掉，避免后面的进攻/巡逻命令覆盖。
func retreat(units: Array, point: Vector3, label: String = "retreat") -> void:
	var ok: Array = available(units)
	for u in ok:
		if not u.has_method("order_retreat"):
			continue
		_queue.erase(u.get_instance_id())
		u.call("order_retreat", point)
		if Game.control != null:
			Game.control.claim_ai([u])
		_sent += 1


# ===========================================================================
# 真正发出
# ===========================================================================

func flush() -> void:
	for uid in _queue.keys():
		var e: Dictionary = _queue[uid]
		var u = e["unit"]
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		if _sent >= MAX_PER_TICK:
			_dropped += 1
			continue
		var kind: int = int(e["kind"])
		var point: Vector3 = e["point"]
		var t = e["target"]
		match kind:
			RtsConst.Order.MOVE:
				u.order_move(point)
			RtsConst.Order.ATTACK:
				if t == null or not is_instance_valid(t):
					continue
				u.order_attack(t)
			RtsConst.Order.ATTACK_MOVE:
				u.order_attack_move(point)
			RtsConst.Order.HOLD:
				u.order_hold()
			RtsConst.Order.STOP:
				u.order_stop()
			RtsConst.Order.GATHER:
				if t == null or not is_instance_valid(t):
					continue
				u.order_gather(t)
			_:
				continue
		if Game.control != null:
			Game.control.claim_ai([u])
		_sent += 1
	_queue.clear()


# ===========================================================================
# 卡死锁定（由 AI 每次思考调用一次）
# ===========================================================================

## 扫一遍自己的单位：连续被判卡死的，暂停给它们下移动命令。
## 判据用单位自己的 `_stuck_count`（0.8 秒窗口、位移 < 0.28m），
## 不另起一套检测器 —— 两套检测器一定会跑偏。
func refresh_stuck(units: Array) -> void:
	for u in units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		var uid: int = u.get_instance_id()
		var moving: bool = int(u.order) in MOVE_KINDS
		var sc: int = int(u.get("_stuck_count"))
		if moving and sc >= 2:
			var n: int = int(_stuck_hits.get(uid, 0)) + 1
			if n >= 1:
				var level: int = int(_stuck_level.get(uid, 0)) + 1
				_stuck_level[uid] = level
				var dur: float = minf(STUCK_LOCK * pow(2.0, float(level - 1)),
						STUCK_LOCK * STUCK_LOCK_MAX_MULT)
				_stuck_until[uid] = _now + dur
				n = 0
			_stuck_hits[uid] = n
		elif sc <= 0:
			_stuck_hits.erase(uid)
			# 只有"真的动起来了"才清退避等级；STOP→idle 不清，否则退避永远不生效
			if moving:
				_stuck_level.erase(uid)
				_stuck_until.erase(uid)


# ===========================================================================
# 诊断
# ===========================================================================

func stats() -> Dictionary:
	return {
		"sent": _sent,
		"skipped": _skipped,
		"throttled": _throttled_n,
		"filtered_player": _filtered,
		"stuck_locked": _stuck_locked,
		"dropped": _dropped,
		"locked_units": _stuck_until.size(),
		"queued": _queued,
	}
