extends RefCounted
## **玩家指令接收器** —— 夹在「部门仲裁 / 目标层」与「执行层」之间的一层。
##
## 玩家口径（2026-11-14）：
##   "防守哪里、进攻哪里、派单位占据哪里；玩家指令**不覆盖 AI 的决策树**，
##    只作为一种**最高权重的诉求**注入。"
##
## 所以这个文件只做三件事：
##   1. 把战区指令（F5 进攻 / F6 防守 / F7 占据）翻译成**目标建议**（9 字段）；
##   2. 给这条建议打上 `权重`（比三条线的 1.0 高），让目标层排序时排在前面；
##   3. 什么都不下令 —— 派兵仍然走 `简单AI._apply_war_one()` / `战区指令.gd` 的老路。
##
## 三条纪律：
##   · **不夺权**：AI 该造农场还是造农场，玩家指令只决定"先照顾哪一头"；
##   · **不绕过预算**：权重只影响排序，金币/兵力不够照样被 `_goal_execute` 驳回；
##   · **会过期**：沿用战区指令自己的 TTL（90s），玩家不续就自动退回普通目标。
##
## 为什么单独一层而不是塞进 `_ops_demands`：诉求表是"这一周期要做什么"的全集，
## 玩家指令是**外部注入**、来源不同、权重不同，混在一起会让"谁提的"没法追溯。

const GL := preload("res://Model/ai/目标层.gd")
const WAR := preload("res://Game/ai/战区指令.gd")

## 玩家诉求的权重：三条线默认 1.0，玩家指令 3.0（排序必在前，但仍要过预算）。
const WISH_WEIGHT: float = 3.0
## 紧迫度拉满：玩家指了方向就是"现在最该干的事"。
const WISH_URGENCY: float = 1.0
## 玩家诉求的 id 序号从 900 起：三条线的建议最多十几条，绝不会撞号。
const WISH_SEQ_BASE: int = 900
## 到点判定半径（米）：我方战斗单位进这个圈就算"到了"。
const ARRIVE_RADIUS: float = 6.0


## 本周期要注入的目标建议（空 = 玩家没下指令）。
static func goal_proposals(_ai, now: float) -> Array:
	var out: Array = []
	# 理由直接用战区指令自己的动作名（"进攻/防守/占据"），本文件不新增中文串；
	# 是不是玩家提的，看建议上的 `玩家指令 = true`。
	_append(out, WAR.get_order(WAR.ATTACK), GL.ACT_ATTACK_REGION,
			String(WAR.NAMES[WAR.ATTACK]), now)
	_append(out, WAR.get_order(WAR.DEFEND), GL.ACT_DEFEND,
			String(WAR.NAMES[WAR.DEFEND]), now)
	# 占据没有独立的目标动作：它等价于"推进到那片区域并占住" → 走攻击区域。
	_append(out, WAR.get_order(WAR.CAPTURE), GL.ACT_ATTACK_REGION,
			String(WAR.NAMES[WAR.CAPTURE]), now)
	return out


## F8「生产」不产生目标建议：它是**集结点**，已经在 `副官.assembly_points()` 里生效，
## 硬塞成目标会变成"永远达不成的巡逻"，白占预留。

static func _append(out: Array, order: Dictionary, act: String, reason: String, now: float) -> void:
	if order.is_empty():
		return
	var center: Vector3 = order.get("center", Vector3.ZERO)
	# 对象用坐标串（`@x,z`）：`_goal_done_map` 认这个前缀，按"我方有人进圈"判达成。
	var obj: String = "@%.0f,%.0f" % [center.x, center.z]
	var label: String = String(order.get("label", ""))
	var why: String = reason if label.is_empty() else "%s / %s" % [reason, label]
	var p: Dictionary = GL.proposal_make(GL.DEPT_COMBAT, WISH_SEQ_BASE + out.size(),
			act, obj, 1, WISH_URGENCY, why, 0, 0, GL.DONE_ARRIVED, now + WAR.TTL)
	if p.is_empty():
		return
	# 排序权重（`目标层.ranked` 读它）；同时记一下是谁提的，日志/报告能追溯。
	p["权重"] = WISH_WEIGHT
	p["玩家指令"] = true
	p["_显示名"] = obj
	out.append(p)


## 这个"对象"是不是玩家指令的坐标串（`_goal_done_map` 用）。
static func is_wish_point(obj: String) -> bool:
	return obj.begins_with("@")


## 坐标串 → Vector3（解析失败回 (0,0,0)，调用方按"没到"处理）
static func parse_point(obj: String) -> Vector3:
	var body: String = obj.substr(1)
	var parts: PackedStringArray = body.split(",")
	if parts.size() != 2:
		return Vector3.ZERO
	return Vector3(float(parts[0]), 0.0, float(parts[1]))
