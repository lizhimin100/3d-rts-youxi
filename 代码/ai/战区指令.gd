extends RefCounted
## **战区指令**（玩家 → 副官/盟友 AI 的高层意图）
##
## 玩家原话：「该系统加入玩家指令：进攻、防守、占据和生产。让副官和盟友
## （只要是 ai 玩家，包括玩家自己的副官系统）根据指令行动（指令可对一个区域使用，
## 也可以对某个目标使用）」。
##
## 为什么不用 `Game.order_issued` 那条老通道：那是**单位级命令**（这一队人往哪走），
## 一次只能管一队、且会被控制权保护 5–120 秒。战区指令是**战役级意图**：
## 「那片区域归我」——它不绑定具体单位，由 AI 自己决定派谁、派几个、什么时候撤。
##
## 三种作用域：
##   · 区域：`center + radius`，AI 把兵派进圈里（圈内已有多少人算数）；
##   · 目标：`target` 是具体单位/建筑，AI 围着它打/守；
##   · 全局（生产）：`center` = 新兵集结点。
##
## 四条纪律（踩过坑才写的）：
##   ① **只存意图，不下令** —— 下令统一走 CommandScheduler，否则玩家指令会绕过
##      控制权过滤，和副官抢同一批兵；
##   ② **TTL 90s** —— 不清理的话，玩家 10 分钟前点的"进攻"会一直把兵往那送；
##   ③ **同类覆盖** —— 玩家连点三次进攻，只认最后一次（不是排三条队）；
##   ④ **不跨阵营** —— 只有与玩家同 team 的 AI 才读，否则敌人会"听玩家指挥"。

## 指令种类
const ATTACK: int = 1
const DEFEND: int = 2
const CAPTURE: int = 3
const PRODUCE: int = 4

const NAMES: Dictionary = {
	ATTACK: "进攻", DEFEND: "防守", CAPTURE: "占据", PRODUCE: "生产",
}
## 指令有效期（秒）
const TTL: float = 90.0
## 重下同一条指令的最小间隔（秒）：AI 每 0.5s 思考一次，不限流会刷爆调度器
const REISSUE: float = 8.0

## kind -> {kind, center, radius, target_uid, at, last_issue, label}
##
## ⚠ 存在 `Game` 的 meta 上，**不用 `static var`**：
## 2026-11-13 实测，两个脚本各自 `preload` 同一个文件后，读到的 static 变量
## **不是同一份**（自检写入、AI 读不到，表现为"指令确实写进去了但 AI 不动"）。
## meta 挂在 autoload 单例上，全局只有一个字典，跟谁 preload 无关。
const META_KEY := &"war_orders"


## 发一条指令。target 可以是 Node3D（单位/建筑）或 null。
static func _store() -> Dictionary:
	if Game == null:
		return {}
	if not Game.has_meta(META_KEY):
		Game.set_meta(META_KEY, {})
	return Game.get_meta(META_KEY) as Dictionary


static func issue(kind: int, center: Vector3, radius: float = 12.0, target: Node3D = null, label: String = "") -> void:
	if not NAMES.has(kind):
		return
	var st: Dictionary = _store()
	st[kind] = {
		"kind": kind,
		"center": center,
		"radius": clampf(radius, 4.0, 40.0),
		"target_uid": target.get_instance_id() if target != null and is_instance_valid(target) else 0,
		"at": Game.elapsed if Game != null else 0.0,
		"last_issue": -999.0,
		"label": label,
	}
	print("[战区] %s → (%.0f, %.0f) r=%.0f%s" % [
		NAMES[kind], center.x, center.z, radius, (" · " + label) if label != "" else ""])


## 取一条仍然有效的指令；过期自动清掉。
static func get_order(kind: int) -> Dictionary:
	var st: Dictionary = _store()
	if not st.has(kind):
		return {}
	var o: Dictionary = st[kind]
	var now: float = Game.elapsed if Game != null else 0.0
	if now - float(o["at"]) > TTL:
		st.erase(kind)
		return {}
	return o


## 这个 tick 能不能对它下令（限流）。能则返回 true 并刷新时间戳。
static func try_acquire(kind: int) -> bool:
	var o: Dictionary = get_order(kind)
	if o.is_empty():
		return false
	var now: float = Game.elapsed if Game != null else 0.0
	if now - float(o["last_issue"]) < REISSUE:
		return false
	o["last_issue"] = now
	return true


## 标记这条指令已完成/放弃
static func clear(kind: int = 0) -> void:
	var st: Dictionary = _store()
	if st.is_empty():
		return
	if kind == 0:
		st.clear()
	else:
		st.erase(kind)


static func active() -> Array:
	var out: Array = []
	for k in _store().keys():
		var o: Dictionary = get_order(int(k))
		if not o.is_empty():
			out.append(o)
	return out


## 目标实体（如果还活着）
static func target_of(kind: int) -> Node3D:
	var o: Dictionary = get_order(kind)
	if o.is_empty():
		return null
	var uid: int = int(o.get("target_uid", 0))
	if uid == 0:
		return null
	var n: Object = instance_from_id(uid)
	if n is Node3D and is_instance_valid(n):
		return n as Node3D
	return null


## 调试串（自检/HUD 用）
static func debug_string() -> String:
	var parts: Array = []
	for o in active():
		parts.append("%s(%.0f,%.0f)r%.0f" % [
			NAMES[int(o["kind"])], float(o["center"].x), float(o["center"].z), float(o["radius"])])
	if parts.is_empty():
		return "[战区] 无指令"
	return "[战区] " + " ".join(parts)
