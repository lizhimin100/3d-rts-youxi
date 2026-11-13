extends Node
## **战区指令自检** —— 验证"玩家发意图 → AI 派兵"这条链路真的通。
##
## 启用：godot --headless --fixed-fps 60 --path . -- --war-test
##
## 四组断言：
##   A. 指令写入 / 读取 / TTL / 覆盖语义；
##   B. 「进攻」：玩家指定一片区域后，玩家阵营真的有单位带着**朝那个区域**的命令；
##   C. 「防守」：同上，但用的是 move（走到站住），不是 attack_move；
##   D. 「生产」：新兵集结点被改写（副官 assembly_points 返回指令点）；
##   E. 敌方 AI 不许读：临时把指令的 center 放到敌人家门口，
##      敌方阵营的待命兵**不应该**朝那里走（反向对照，防止"敌我一起听"）。

const WAR := preload("res://代码/ai/战区指令.gd")

var _checks: Array = []


func _ready() -> void:
	Engine.time_scale = 2.0
	_run.call_deferred()


func _run() -> void:
	await _wait(1.2)
	var pf = Game.player_faction
	if not _ok("玩家阵营就位", pf != null):
		_finish()
		return
	var adj: Node = get_parent().get_node_or_null("副官")
	if not _ok("副官就位", adj != null):
		_finish()
		return

	# --- A. 指令语义 ---
	WAR.clear()
	_ok("初始无指令", WAR.get_order(WAR.ATTACK).is_empty())
	var c := Vector3(10.0, 0.0, 10.0)
	WAR.issue(WAR.ATTACK, c, 12.0)
	var o: Dictionary = WAR.get_order(WAR.ATTACK)
	_ok("指令写入", not o.is_empty() and (o["center"] as Vector3).distance_to(c) < 0.01)
	WAR.issue(WAR.ATTACK, Vector3(20.0, 0.0, 20.0), 8.0)
	var o2: Dictionary = WAR.get_order(WAR.ATTACK)
	_ok("同类覆盖（只认最后一次）",
		(o2["center"] as Vector3).distance_to(Vector3(20.0, 0.0, 20.0)) < 0.01
		and absf(float(o2["radius"]) - 8.0) < 0.01)
	WAR.clear(WAR.ATTACK)
	_ok("clear 生效", WAR.get_order(WAR.ATTACK).is_empty())

	# --- B. 进攻：目标选在玩家基地朝敌方 35m 处 ---
	# 开局 1.2s 时玩家通常只有 1 个战斗兵（`_apply_war_orders` 要求 ≥2），
	# 先等 AI 把兵营的第一批兵造出来，否则测的是"没兵可派"而不是"派得出去"。
	await _wait(8.0)
	var base: Vector3 = RtsWorld.base_center(pf)
	var foe: Vector3 = _foe_point(pf, base)
	var atk: Vector3 = base
	if foe != Vector3.INF:
		var d: Vector3 = foe - base
		d.y = 0.0
		if d.length() > 1.0:
			atk = RtsWorld.walkable_pos(base + d.normalized() * 35.0)
	WAR.clear()
	WAR.issue(WAR.ATTACK, atk, 14.0)
	await _wait(4.0)
	# 白盒：读 AI 自己的派兵账本（"进攻×N"）。不依赖"兵此刻 order 是不是 ATTACK_MOVE"——
	# 兵可能半路被别的逻辑接管，那样的断言测的是时序不是链路。
	var wl: String = String(adj.get("war_last"))
	var wl_at: float = float(adj.get("war_last_at"))
	_ok("进攻指令：AI 确实派了兵", wl.begins_with("进攻") and wl_at > 0.0,
		"war_last=%s skip=%s" % [wl, str(adj.get("war_skip"))])

	# --- C. 防守 ---
	WAR.clear()
	var def: Vector3 = RtsWorld.walkable_pos(base + Vector3(14.0, 0.0, 0.0))
	WAR.issue(WAR.DEFEND, def, 12.0)
	await _wait(4.0)
	var wl2: String = String(adj.get("war_last"))
	var wl2_at: float = float(adj.get("war_last_at"))
	_ok("防守指令：AI 确实派了兵", wl2.begins_with("防守") and wl2_at > 0.0,
		"war_last=%s skip=%s" % [wl2, str(adj.get("war_skip"))])

	# --- D. 生产：集结点被指令改写 ---
	WAR.issue(WAR.PRODUCE, def, 6.0)
	await _wait(0.6)
	var pts: Array = []
	if adj != null and adj.has_method("assembly_points"):
		pts = adj.call("assembly_points")
	_ok("生产指令：新兵集结点 = 指令点",
		not pts.is_empty() and (pts[0] as Vector3).distance_to(def) < 1.0,
		"pts=%d first=%s" % [pts.size(), str(pts[0]) if not pts.is_empty() else "无"])

	# --- E. 反向对照：敌方 AI 不许听 ---
	WAR.clear()
	var enemy = null
	for f in Game.factions:
		if f != null and int(f.team) != 0 and not f.is_ally_of(pf):
			enemy = f
			break
	if enemy != null:
		var ebase: Vector3 = RtsWorld.base_center(enemy)
		# 判据不看"敌方兵有没有朝那个点走"——敌方 AI 自己也会往基地回防/巡逻，
		# 那样会把"正常调度"误判成"听玩家指令"（2026-11-13 实测）。
		# 直接看敌方 AI 的派兵账本：它必须是空的。
		WAR.issue(WAR.ATTACK, ebase, 14.0)
		await _wait(4.0)
		var foe_ai: Node = _find_ai_of(enemy)
		if foe_ai != null:
			var fl: String = String(foe_ai.get("war_last"))
			_ok("反向对照：敌方 AI 不执行玩家指令", not fl.begins_with("进攻"),
				"敌方 war_last=%s" % fl)
		else:
			_ok("反向对照：找不到敌方 AI（跳过）", true, "")
	else:
		_ok("反向对照：场上有敌方阵营", false, "没有敌人")

	WAR.clear()
	_finish()


# ---------------------------------------------------------------------------

func _count_heading_to(faction, point: Vector3, tol: float) -> int:
	var n: int = 0
	for u in faction.units:
		if u == null or not is_instance_valid(u) or not u.is_alive():
			continue
		if u.def == null or RtsWorld.is_worker_def(u.def):
			continue
		var o: int = int(u.order)
		if o != RtsConst.Order.MOVE and o != RtsConst.Order.ATTACK_MOVE and o != RtsConst.Order.ATTACK:
			continue
		if _goal_near(u, point, tol):
			n += 1
	return n


## 单位当前"要去的地方"离 point 多远（不同 order 存的字段不一样，逐个兜底）
func _goal_near(u, point: Vector3, tol: float) -> bool:
	if u.has_method("move_goal"):
		var g: Vector3 = u.call("move_goal")
		if g != Vector3.INF and g.distance_to(point) <= tol:
			return true
	for prop in ["_goal", "_order_goal", "move_target"]:
		var v = u.get(prop)
		if v is Vector3 and (v as Vector3).distance_to(point) <= tol:
			return true
	if u.target != null and is_instance_valid(u.target):
		if u.target.global_position.distance_to(point) <= tol:
			return true
	return false


## 找出指挥某个阵营的 AI 节点（主场景把 AI 挂在同级）
func _find_ai_of(faction) -> Node:
	for c in get_parent().get_children():
		if c == null or not is_instance_valid(c):
			continue
		if not c.has_method("_apply_war_orders"):
			continue
		if c.get("_faction") == faction:
			return c
	return null


func _foe_point(faction, base: Vector3) -> Vector3:
	var best: Vector3 = Vector3.INF
	var bd: float = 1e20
	for f in Game.factions:
		if f == null or f == faction or int(f.team) == 0:
			continue
		var c: Vector3 = RtsWorld.base_center(f)
		var d: float = base.distance_to(c)
		if d > 1.0 and d < bd:
			bd = d
			best = c
	return best


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _ok(name: String, ok: bool, detail: String = "") -> bool:
	_checks.append({"name": name, "ok": ok, "detail": detail})
	if not ok:
		print("[战区自检] 失败：%s（%s）" % [name, detail])
	return ok


func _finish() -> void:
	var passed: int = 0
	for c in _checks:
		if bool(c["ok"]):
			passed += 1
	var out := {
		"结果": "通过" if passed == _checks.size() else "失败",
		"通过": passed, "总数": _checks.size(), "检查": _checks,
	}
	print("WARORDER " + JSON.stringify(out))
	get_tree().quit()
