extends RefCounted
## **控制权登记表**：谁有权给某个单位下令（Player Intent Ownership）。
##
## 为什么需要这一层（这是本项目的一个**真 bug**，不是锦上添花）：
##   副官（代码/ai/副官.gd）和人机（代码/ai/简单AI.gd）是同一套大脑，
##   而 `_manage_waves` / `_manage_defense` / `_manage_retreat` 都是
##   **对着 `_army_units()` 全员下令**的，完全不区分"这条令是谁下的"。
##   于是：玩家正在微操的 5 个步兵，会在副官下一次思考（0.8~1.0s）时被整队抓走；
##   玩家下了一条绕后命令，半路一开打就被 `_manage_retreat` 改成"回家"。
##   旧注释写的是"副官看到 order != NONE 就不会再碰它" —— 那句话只在
##   `_pick_builder` 挑农民盖房那一条路上成立，军队侧一条都没实现。
##
## 判据**不是**"玩家下过令后 N 秒内不准动"（那是 TTL，实测有四类问题：
## 长命令宽限期为 0、一条命令被从中间劈开、STOP 之后照样被拉走、
## 队列/驻守无法表达）。这里按**命令组**跟踪生命周期：
##
##   玩家下令(MOVE / ATTACK / ATTACK_MOVE / GATHER / BUILD / RETURN_RES)
##       → 整组 PLAYER_ACTIVE：直到**组内全部**单位回到 idle
##       → PLAYER_GRACE：默认 5 秒，从"命令结束"起算（不是从"下令"起算）
##       → AI_OWNED：副官/人机可以接手
##   STOP → PLAYER_HOLDING 30 秒（防"一按停止副官立刻把人拉走"）
##   HOLD → PLAYER_HOLDING 无期限（直到玩家再下令）
##   LOCK → PLAYER_LOCKED 永久（测试与将来的"锁定"按钮用）
##
## 三个关键点（每条都是踩出来的）：
##   1. **"结束"按组判定，不按单个单位** —— 否则先走到的人被立刻接管，
##      一条命令被从中间撕开，队形当场散掉；
##   2. **宽限期从命令结束起算** —— 否则 30 秒的长途奔袭会在第 8 秒被抢；
##   3. **已锁定的单位不会被普通命令降级** —— "先锁再框选移动"是很常见的操作。
##
## 状态存在**单位自己身上**（RtsUnit.order_owner / order_until / order_group /
## order_since），本表只额外保存命令组（组员数组）：
##   · 单位死了字段跟着消失，不需要清理，也不会有"野指针当字典键"的问题；
##   · 本表不持有单位引用（组里是引用，但 tick 时逐帧剔除失效项）。

# --- 归属种类（与 RtsUnit.order_owner 的取值一一对应）---
## 归 AI（人机 / 副官）指挥：默认值，也是宽限期结束后的状态
const OWNER_AI := 0
## 正在执行玩家命令（按组）
const OWNER_ACTIVE := 1
## 玩家命令刚结束，宽限中
const OWNER_GRACE := 2
## 玩家要求停住 / 驻守
const OWNER_HOLDING := 3
## 玩家显式锁定
const OWNER_LOCKED := 4

## 命令结束后的宽限（秒）。太短 = 玩家刚放手就被抢；太长 = 副官像卡住不动。
var grace_seconds: float = 5.0
## STOP 之后保持不动的时长（秒）
var hold_after_stop: float = 30.0
## 安全上限：再长的命令也不能无限 PLAYER_ACTIVE（玩家忘了松手时兜底）
var active_max_seconds: float = 120.0

## 命令组：gid -> {"units": Array, "deadline": float, "order": int, "since": float}
var _groups: Dictionary = {}
## 2C-12 §4：**宽限期观察名单**。
## 2C-11 及以前，宽限到期只让 `is_protected()` 返回 false，`order_owner` 仍是 2，
## 要等 AI 真的对它下过一条令（`claim_ai`）才回 0。dept=on 走仲裁只认领 push_n 个兵，
## 队尾那个没人认领 → 副官自检 C 组恒 owner=002（27/28）。
## 现在：进宽限就登记；到期那一刻直接把 owner 归 0（AI 空闲池），
## **不再依赖 AI 是否认领**。已被 AI 认领 / 玩家重新下令的自动退出名单。
var _grace_watch: Array = []
var _next_gid: int = 1
var _attached: bool = false
var _last_tick: float = -1.0

## 统计（诊断 / 自检断言用；只增不减）
var stats: Dictionary = {
	"player_commands": 0,
	"groups_finished": 0,
	"locks": 0,
	"unlocks": 0,
	"grants": 0,
	"ai_skipped": 0,
	"stale_groups": 0,
	"grace_expired": 0,
}


## 挂到全局信号上：**所有**玩家指令都从 Game.order_issued 走（指令系统是唯一发出点），
## 所以这里订阅一次就覆盖全部 9 条路径，不需要在每个 _issue_* 里散着写登记。
func attach() -> void:
	if _attached:
		return
	if Game == null:
		return
	if not Game.order_issued.is_connected(_on_player_order):
		Game.order_issued.connect(_on_player_order)
	_attached = true


## 复位（重开一局 / 单元测试）
func reset() -> void:
	_groups.clear()
	_grace_watch.clear()
	_next_gid = 1
	_last_tick = -1.0
	for k in stats.keys():
		stats[k] = 0


# ===========================================================================
# 玩家动作
# ===========================================================================

## 玩家下了一条令。units 是这条令覆盖的单位集合，order 是 RtsConst.Order。
func on_player_command(units: Array, order: int) -> void:
	var now: float = _now()
	stats["player_commands"] += 1

	# 施法不改变"谁在指挥"的语义（法术前摇结束后单位会自己回到原指令）
	if order == RtsConst.Order.CAST:
		return

	var live: Array = []
	var locked: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_method("is_alive") or not u.is_alive():
			continue
		if int(u.order_owner) == OWNER_LOCKED:
			locked.append(u)          # 锁定的单位不参与普通命令，也不被降级
			continue
		live.append(u)
	if live.is_empty():
		return

	# 先把这批人从旧组里摘掉（玩家改主意了，旧组不再拥有他们）
	for gid in _groups.keys():
		var arr: Array = _groups[gid]["units"]
		for u in live:
			arr.erase(u)
		if arr.is_empty():
			_groups.erase(gid)

	if order == RtsConst.Order.STOP:
		for u in live:
			_set_owner(u, OWNER_HOLDING, now + hold_after_stop, 0)
		return
	if order == RtsConst.Order.HOLD:
		for u in live:
			_set_owner(u, OWNER_HOLDING, 0.0, 0)
		return

	# 其余都是"会跑完"的命令：整组进入 ACTIVE
	var gid: int = _next_gid
	_next_gid += 1
	for u in live:
		_set_owner(u, OWNER_ACTIVE, 0.0, gid)
	_groups[gid] = {
		"units": live,
		"deadline": now + active_max_seconds,
		"order": order,
		"since": now,
	}


## 显式锁定（永久，直到 unlock / grant）
func lock(units: Array) -> void:
	stats["locks"] += 1
	_detach_from_groups(units)
	for u in _valid(units):
		_set_owner(u, OWNER_LOCKED, 0.0, 0)


## 解锁 → 进入宽限期（不是立刻交给 AI，否则"解锁瞬间被接管"很突兀）
func unlock(units: Array) -> void:
	stats["unlocks"] += 1
	var now: float = _now()
	for u in _valid(units):
		if int(u.order_owner) == OWNER_LOCKED:
			_set_owner(u, OWNER_GRACE, now + grace_seconds, 0)
			_watch_grace(u)


## 立刻交还 AI
func grant(units: Array) -> void:
	stats["grants"] += 1
	_detach_from_groups(units)
	for u in _valid(units):
		_set_owner(u, OWNER_AI, 0.0, 0)


## AI 成功对某批单位下令后调用：认领归属，避免"AI 下的令"被记成玩家的。
## （只在**确实发出去了**的单位上调用；被过滤掉的不动。）
func claim_ai(units: Array) -> void:
	for u in _valid(units):
		_set_owner(u, OWNER_AI, 0.0, 0)


# ===========================================================================
# 查询
# ===========================================================================

## 这个单位现在是不是"玩家在管"（副官/人机不许碰）
func is_protected(u) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	var k: int = int(u.order_owner)
	if k == OWNER_LOCKED or k == OWNER_ACTIVE:
		return true
	if k == OWNER_GRACE or k == OWNER_HOLDING:
		var until: float = float(u.order_until)
		return until <= 0.0 or _now() < until
	return false


## 过滤出"AI 现在可以指挥"的单位（保护中的直接剔除，并计入 ai_skipped）
func filter(units: Array) -> Array:
	var out: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if is_protected(u):
			stats["ai_skipped"] += 1
			continue
		out.append(u)
	return out


## 单位当前的归属种类（诊断 / 自检）
func owner_of(u) -> int:
	if u == null or not is_instance_valid(u):
		return OWNER_AI
	return int(u.order_owner)


func protected_count() -> int:
	var n: int = 0
	for gid in _groups.keys():
		for u in _groups[gid]["units"]:
			if is_protected(u):
				n += 1
	return n


func debug_string() -> String:
	return "[控制权] 组=%d 保护=%d 玩家令=%d 结束=%d 跳过=%d" % [
		_groups.size(), protected_count(), stats["player_commands"],
		stats["groups_finished"], stats["ai_skipped"]]


# ===========================================================================
# 每帧推进（由 游戏状态._process 调用）
# ===========================================================================

## 推进命令组状态机。**组内全部单位回到 idle 才算结束**（不是逐个判）。
## 另外还有一道 120 秒的安全上限：再长的命令也不能无限 ACTIVE。
func tick(now: float) -> void:
	_last_tick = now
	# 2C-12 §4：宽限到期必须**真正交还**（owner → OWNER_AI），不能只靠 is_protected 假装没保护。
	_tick_grace(now)
	if _groups.is_empty():
		return
	for gid in _groups.keys():
		var g: Dictionary = _groups[gid]
		var arr: Array = g["units"]
		# 剔除已死 / 已被释放的单位
		var keep: Array = []
		var busy: bool = false
		for u in arr:
			if u == null or not is_instance_valid(u) or not u.has_method("is_alive"):
				continue
			if not u.is_alive():
				continue
			# 已经被别的组或锁拿走的，不再属于本组
			if int(u.order_group) != gid:
				continue
			keep.append(u)
			var o: int = int(u.order)
			if o != RtsConst.Order.NONE and o != RtsConst.Order.STOP:
				busy = true
		g["units"] = keep
		if keep.is_empty():
			_groups.erase(gid)
			stats["stale_groups"] += 1
			continue
		var deadline: float = float(g["deadline"])
		var expired: bool = deadline > 0.0 and now >= deadline
		if busy and not expired:
			continue
		# —— 命令结束 ——
		for u in keep:
			if int(u.order_group) == gid:
				_set_owner(u, OWNER_GRACE, now + grace_seconds, 0)
				_watch_grace(u)
		_groups.erase(gid)
		stats["groups_finished"] += 1


## 2C-12 §4：宽限期结算 —— 到期就归 0，不等 AI 认领。
## 退出名单的三种情况：失效/死亡、已被 AI 认领或玩家重新下令、宽限尚未到期。
func _tick_grace(now: float) -> void:
	if _grace_watch.is_empty():
		return
	var keep: Array = []
	for u in _grace_watch:
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_method("is_alive") or not u.is_alive():
			continue
		if int(u.order_owner) != OWNER_GRACE:
			# 已被 claim_ai / grant / 玩家新命令接管 → 不必再管
			continue
		var until: float = float(u.order_until)
		if until > 0.0 and now < until:
			keep.append(u)
			continue
		_set_owner(u, OWNER_AI, 0.0, 0)
		stats["grace_expired"] += 1
	_grace_watch = keep


## 进宽限时登记（同一单位重复进入只留一份）
func _watch_grace(u) -> void:
	if not _grace_watch.has(u):
		_grace_watch.append(u)


# ===========================================================================
# 内部
# ===========================================================================

func _on_player_order(units: Array, order: int, _target_pos: Vector3, _target: Node3D) -> void:
	on_player_command(units, order)


func _set_owner(u, kind: int, until: float, gid: int) -> void:
	u.order_owner = kind
	u.order_until = until
	u.order_group = gid
	u.order_since = _now()


func _detach_from_groups(units: Array) -> void:
	for gid in _groups.keys():
		var arr: Array = _groups[gid]["units"]
		for u in units:
			arr.erase(u)
		if arr.is_empty():
			_groups.erase(gid)


func _valid(units: Array) -> Array:
	var out: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not u.is_alive():
			continue
		out.append(u)
	return out


func _now() -> float:
	return Game.elapsed if Game != null else 0.0
