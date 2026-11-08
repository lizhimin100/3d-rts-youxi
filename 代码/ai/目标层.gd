extends RefCounted
## **目标层**（2C-13 §4）：部门提目标建议 → 主部门选主/次目标 → 空过。
##
## 与 2C-9 的差别（这是本轮的结构改动）：
##   2C-9：三条线报"动作诉求"，主部门按**诉求分**动作级仲裁 —— 谁分高谁先动钱，
##         没有"这件事是为哪个目标做的"这层上下文，也**没法空过**（总有人报诉求）。
##   2C-13：三条线只报"目标建议"（9 字段，不含执行句柄），主部门选**一个主目标 +
##          一个次目标**；执行层读主目标决定优先级；**没有目标就不花钱**（空过）。
##
## 全部函数是 static 纯函数：不读 `Game` / 不扫场景，配置回归能直接断言。
## 目标建议里的 `对象` 用 def.id 或区域 id 原文（farm / archer / "Dr001"），
## 执行层直接读，不做二次转换。

# ---------------------------------------------------------------------------
# 枚举 / 字段
# ---------------------------------------------------------------------------

const ACT_BUILD: String = "建造"
const ACT_TRAIN: String = "训练"
const ACT_RESEARCH: String = "研发"
const ACT_ATTACK_REGION: String = "攻击区域"
const ACT_DESTROY: String = "摧毁单位"
const ACT_DEFEND: String = "防守地点"
const ACT_SCOUT: String = "侦查地点"
const ACT_PATROL: String = "巡逻地点"
const ACT_EXPAND_BASE: String = "建立分基地"
const ACTIONS: Array[String] = [
	ACT_BUILD, ACT_TRAIN, ACT_RESEARCH, ACT_ATTACK_REGION, ACT_DESTROY,
	ACT_DEFEND, ACT_SCOUT, ACT_PATROL, ACT_EXPAND_BASE,
]

const DEPT_OPS: String = "运营线"
const DEPT_COMBAT: String = "战斗线"
const DEPT_EXPAND: String = "扩张线"
const DEPTS: Array[String] = [DEPT_OPS, DEPT_COMBAT, DEPT_EXPAND]
## id 前缀：Yy / Zd / Kz（任务书 §4.1）
const DEPT_PREFIX: Dictionary = {
	DEPT_OPS: "Yy", DEPT_COMBAT: "Zd", DEPT_EXPAND: "Kz",
}
## 每条线**只能**提这三类（§7 职责边界）。越界 = 结构错误，不进选择。
const DEPT_ACTIONS: Dictionary = {
	DEPT_OPS: [ACT_BUILD, ACT_TRAIN, ACT_RESEARCH],
	DEPT_COMBAT: [ACT_ATTACK_REGION, ACT_DESTROY, ACT_DEFEND],
	DEPT_EXPAND: [ACT_SCOUT, ACT_PATROL, ACT_EXPAND_BASE],
}

## 目标建议的 9 个字段（任务书 §4.1 原文，一个不多一个不少）
const GOAL_FIELDS: Array[String] = [
	"id", "动作", "对象", "期望值", "紧迫度", "理由",
	"建议预留", "达成条件", "过期时间",
]

## 达成条件枚举
const DONE_BUILT: String = "已建成"
const DONE_TRAINED: String = "已训练"
const DONE_RESEARCHED: String = "已研发"
const DONE_REGION_CLEAR: String = "区域已清"
const DONE_TARGET_DEAD: String = "目标死亡"
const DONE_THREAT_CLEAR: String = "威胁解除"
const DONE_ARRIVED: String = "已到达"
const DONE_PATROLLED: String = "已巡逻"
const DONE_CONDITIONS: Array[String] = [
	DONE_BUILT, DONE_TRAINED, DONE_RESEARCHED, DONE_REGION_CLEAR,
	DONE_TARGET_DEAD, DONE_THREAT_CLEAR, DONE_ARRIVED, DONE_PATROLLED,
]

## 生命周期状态
const ST_RUNNING: String = "执行中"
const ST_DONE: String = "已达成"
const ST_EXPIRED: String = "已过期"
const ST_PREEMPTED: String = "被抢占"
const STATES: Array[String] = [ST_RUNNING, ST_DONE, ST_EXPIRED, ST_PREEMPTED]
const RELEASE_REASONS: Array[String] = ["达成", "过期", "被抢占"]

## 空过阈值（进卡，默认 0.6）。`>` 与 `>=` 的边界见 `empty_pass()`：
## 0.59 → 空过；0.60 → 选目标（任务书 §4.2 原文）。
const URGENCY_THRESHOLD_DEFAULT: float = 0.6
## 抢占需要"明显更高"（+0.05），否则同分目标每周期互相抢，预留反复释放。
const PREEMPT_MARGIN: float = 0.05
## 空过期间"积极储蓄"的退出倍率（§4.3）：金币 ≥ 1.5 × G(t) 就不再主动往 G 冲。
const NOOP_SAVING_EXIT_RATIO: float = 1.5

# ---------------------------------------------------------------------------
# 建议构造 / 校验
# ---------------------------------------------------------------------------

## 一条目标建议。`seq` 由调用方按"本线本周期第几条"给（从 1 起）。
## 越界动作（运营线报"出击"之类）直接返回 {} —— 结构上就不允许。
static func proposal_make(dept: String, seq: int, action: String, target: String,
		expected: int, urgency: float, reason: String, gold: int, wood: int,
		done_cond: String, expire_t: float) -> Dictionary:
	var allowed = DEPT_ACTIONS.get(dept, null)
	if allowed == null or not (allowed as Array).has(action):
		return {}
	if seq < 1:
		return {}
	if target.is_empty():
		# 对象空 = 结构错误：没有对象的"目标"执行层无从匹配，直接拒绝（不靠下游校验兜）
		return {}
	var pre: String = String(DEPT_PREFIX.get(dept, ""))
	if pre.is_empty():
		return {}
	return {
		"id": "%s%03d" % [pre, seq],
		"动作": action,
		"对象": target,
		"期望值": maxi(expected, 0),
		"紧迫度": clampf(urgency, 0.0, 1.0),
		"理由": reason,
		"建议预留": {"金币": maxi(gold, 0), "木材": maxi(wood, 0)},
		"达成条件": done_cond,
		"过期时间": expire_t,
	}


## 缺字段 / 前缀错 / 序号错 / 对象空 → 返回错误列表（空 = 合法）。
static func proposal_errors(p: Dictionary) -> Array:
	var err: Array = []
	if p.is_empty():
		return ["空建议"]
	for f in GOAL_FIELDS:
		if not p.has(f):
			err.append("缺字段:%s" % f)
	var gid: String = String(p.get("id", ""))
	if gid.length() != 5:
		err.append("id 长度≠5")
	else:
		var pre: String = gid.substr(0, 2)
		var ok_pre: bool = false
		for k in DEPT_PREFIX.keys():
			if String(DEPT_PREFIX[k]) == pre:
				ok_pre = true
		if not ok_pre:
			err.append("id 前缀非法:%s" % pre)
		var digits: String = gid.substr(2, 3)
		if not digits.is_valid_int() or int(digits) < 1:
			err.append("id 序号非法:%s" % digits)
	if String(p.get("对象", "")).is_empty():
		err.append("对象为空")
	if not ACTIONS.has(String(p.get("动作", ""))):
		err.append("动作非法:%s" % String(p.get("动作", "")))
	if not DONE_CONDITIONS.has(String(p.get("达成条件", ""))):
		err.append("达成条件非法:%s" % String(p.get("达成条件", "")))
	var rd = p.get("建议预留", null)
	if not (rd is Dictionary) or not (rd as Dictionary).has("金币") \
			or not (rd as Dictionary).has("木材"):
		err.append("建议预留不完整")
	var u: float = float(p.get("紧迫度", -1.0))
	if u < 0.0 or u > 1.0:
		err.append("紧迫度越界")
	return err


static func proposal_valid(p: Dictionary) -> bool:
	return proposal_errors(p).is_empty()


## 本线建议是否越界（回归用它断言三部门只提自己那三类）。
static func action_allowed(dept: String, action: String) -> bool:
	var a = DEPT_ACTIONS.get(dept, null)
	return a != null and (a as Array).has(action)


# ---------------------------------------------------------------------------
# 紧迫度：2C-10 的诉求分 → 0~1（第一版直觉映射，报告里列每局分布）
# ---------------------------------------------------------------------------

## 建造农场：人口占用率（含在训）分档。
##
## ★ 2026-11-08 玩家口径（防卡人口）：
##   · 占用 ≥ 90% → **直接拉满 1.0**，优先级高于一切（含训练兜底 0.95）；
##   · 占用 ≥ 70% → **0.72**，明确越过 0.6 空过阈值（旧值 0.62 只比阈值高 0.02，
##     和训练的 0.6 分档打平 → 常常抢不到主目标 → 人口走到 100% 才补农场 → 卡死 28 秒）；
##   · `urgent`（人口余量 <4 / 一个兵都排不下）→ 0.95：比"预判"高，但仍让位给 90% 拉满。
static func urgency_build_farm(pop_rate: float, urgent: bool) -> float:
	if pop_rate >= 0.90:
		return 1.0
	if urgent:
		return 0.95
	if pop_rate >= 0.70:
		return 0.72
	if pop_rate >= 0.55:
		return 0.50
	return 0.25


## 建造兵营：没有产能建筑 = 结构性缺口（0.85）；扩建 = 0.55。
##
## ★ 2026-11-08 玩家拍板「爆兵营」：金币充足（`urgent = true`）时扩建抬到 **0.82**，
##   越过空过阈值 0.60 —— 否则它永远只能"搭便车"落地，还会跟训练抢同一笔钱。
##   旧值：无产能 0.80 / 扩建 0.45（0.45 < 0.60，永远当不上主目标）。
static func urgency_build_barracks(have: int, urgent: bool = false) -> float:
	if have <= 0:
		return 0.85
	return 0.82 if urgent else 0.55


## 训练：军队缺口比例。gap=target → 0.90；gap=0.5×target → 0.625；gap=0 → 0.35。
## 为什么用比例而不是缺口绝对值：军队目标随局内时间变化，绝对值不可比。
static func urgency_train(gap: int, target: int) -> float:
	if target <= 0:
		return 0.50
	var r: float = clampf(float(maxi(gap, 0)) / float(target), 0.0, 1.0)
	return clampf(0.35 + 0.55 * r, 0.0, 0.90)


## 修理：掉血 / 200（与 `DEMAND_REPAIR_SCALE` 同尺度）。掉血 200 → 0.80。
static func urgency_repair(deficit: float) -> float:
	return clampf(0.30 + 0.50 * clampf(deficit / 200.0, 0.0, 1.0), 0.30, 0.85)


## 防守：压家敌人数。1 个 → 0.70；3 个 → 0.90；封顶 0.95。
static func urgency_defend(threat_n: int) -> float:
	return clampf(0.60 + 0.10 * float(maxi(threat_n, 1)), 0.60, 0.95)


## 出击：兵力比。打不过不报高紧迫（<1 → 0.35），优势越大越该打。
static func urgency_push(ratio: float) -> float:
	if ratio < 1.0:
		return 0.35
	if ratio < 1.3:
		return 0.55
	return 0.70


## 侦查：已经知道敌人位置 → 0.45（例行）；完全没情报 → 0.65（该去看看）。
static func urgency_scout(knows_enemy: bool) -> float:
	return 0.45 if knows_enemy else 0.65


## 巡逻：例行 0.45；有压家敌人时交给"防守地点"，巡逻不抬分（避免两条线抢同一件事）。
static func urgency_patrol() -> float:
	return 0.45


## 研发：科技是长期收益，第一版固定 0.50（低于空过线，只在别的线都闲时才当主目标）。
static func urgency_research() -> float:
	return 0.50


## 建立分基地：`can_build_townhall()` 恒 false，本轮不做（桩保持 0）。
static func urgency_expand_base() -> float:
	return 0.0


# ---------------------------------------------------------------------------
# 主部门：选主/次目标 + 空过
# ---------------------------------------------------------------------------

## 排序后的候选（分数 = 紧迫度 × 部门权重 × 局势修正；后两项第一版全 1.0，留桩）。
## 同分按 id 升序 —— 保证确定性，不吃哈希顺序。
static func ranked(proposals: Array, weights: Dictionary = {},
		situation: Dictionary = {}) -> Array:
	var out: Array = []
	for p in proposals:
		if not (p is Dictionary):
			continue
		var g: Dictionary = p as Dictionary
		if not proposal_valid(g):
			continue
		var dept: String = ""
		for k in DEPT_PREFIX.keys():
			if String(g["id"]).begins_with(String(DEPT_PREFIX[k])):
				dept = String(k)
				break
		var w: float = float(weights.get(dept, 1.0))
		var s: float = float(situation.get(String(g["动作"]), 1.0))
		var row: Dictionary = g.duplicate(true)
		row["_分"] = float(g["紧迫度"]) * w * s
		row["_线"] = dept
		out.append(row)
	out.sort_custom(func(a, b):
		if not is_equal_approx(float(a["_分"]), float(b["_分"])):
			return float(a["_分"]) > float(b["_分"])
		return String(a["id"]) < String(b["id"]))
	return out


## 空过判定：**所有**建议紧迫度 < 阈值（严格小于；0.60 本身不算空过）。
static func empty_pass(proposals: Array, threshold: float = URGENCY_THRESHOLD_DEFAULT) -> bool:
	for p in proposals:
		if not (p is Dictionary):
			continue
		if not proposal_valid(p as Dictionary):
			continue
		if float((p as Dictionary)["紧迫度"]) >= threshold:
			return false
	return true


## 选主/次目标。返回（结构固定，执行层与报告都按这几个键读）：
##   {"主目标": Dictionary|{}, "次目标": Dictionary|{},
##    "预留总额": {"金币": int, "木材": int}, "空过": bool, "依据": String,
##    "候选数": int, "截断": int}
## 预留截断规则：主目标先占，次目标只能用剩下的；金币之和 ≤ 当前金币。
static func select(proposals: Array, gold: int, threshold: float = URGENCY_THRESHOLD_DEFAULT,
		weights: Dictionary = {}, situation: Dictionary = {}) -> Dictionary:
	var rows: Array = ranked(proposals, weights, situation)
	var g: int = maxi(gold, 0)
	if rows.is_empty() or empty_pass(rows, threshold):
		var top: float = float(rows[0]["紧迫度"]) if not rows.is_empty() else 0.0
		return {
			"主目标": {}, "次目标": {},
			"预留总额": {"金币": 0, "木材": 0},
			"空过": true, "候选数": rows.size(), "截断": 0,
			"依据": "全部建议紧迫度 < %.2f（最高 %.2f，%d 条候选）→ 空过" % [
				threshold, top, rows.size()],
		}
	var main: Dictionary = (rows[0] as Dictionary).duplicate(true)
	var main_need: int = int((main["建议预留"] as Dictionary).get("金币", 0))
	var main_gold: int = mini(main_need, g)
	var cut: int = 1 if main_gold < main_need else 0
	main["预留"] = {"金币": main_gold,
			"木材": int((main["建议预留"] as Dictionary).get("木材", 0))}
	var sub: Dictionary = {}
	var sub_gold: int = 0
	var sub_wood: int = 0
	if rows.size() >= 2 and float((rows[1] as Dictionary)["紧迫度"]) >= threshold:
		sub = (rows[1] as Dictionary).duplicate(true)
		var sub_need: int = int((sub["建议预留"] as Dictionary).get("金币", 0))
		sub_gold = mini(sub_need, maxi(g - main_gold, 0))
		sub_wood = int((sub["建议预留"] as Dictionary).get("木材", 0))
		if sub_gold < sub_need:
			cut += 1
		sub["预留"] = {"金币": sub_gold, "木材": sub_wood}
	var basis: String = "主=%s·%s（紧迫度 %.2f，分数 %.2f）" % [
		String(main["id"]), String(main["动作"]), float(main["紧迫度"]), float(main["_分"])]
	if not sub.is_empty():
		basis += "；次=%s·%s（%.2f）" % [String(sub["id"]), String(sub["动作"]),
				float(sub["紧迫度"])]
	else:
		basis += "；次=空"
	if cut > 0:
		basis += "；预留被金币截断 %d 条" % cut
	return {
		"主目标": main, "次目标": sub,
		"预留总额": {"金币": main_gold + sub_gold, "木材":
				int((main["预留"] as Dictionary).get("木材", 0)) + sub_wood},
		"空过": false, "候选数": rows.size(), "截断": cut, "依据": basis,
	}


# ---------------------------------------------------------------------------
# 目标生命周期（确立 / 达成 / 过期 / 抢占 / 清理）
# ---------------------------------------------------------------------------

## 确立：把选中的目标变成"执行中"的活动目标（带上预留与已用）。
static func goal_new(p: Dictionary, now: float) -> Dictionary:
	if p.is_empty():
		return {}
	var g: Dictionary = p.duplicate(true)
	g["状态"] = ST_RUNNING
	g["开始时间"] = now
	if not g.has("预留"):
		g["预留"] = (g.get("建议预留", {"金币": 0, "木材": 0}) as Dictionary).duplicate()
	g["已用"] = {"金币": 0, "木材": 0}
	return g


## 达成条件是否满足。`observed` 由调用方按条件语义取值：
##   已建成/已训练/已研发 → 当前数量；目标死亡/威胁解除/区域已清 → 剩余数量（0 = 满足）；
##   已到达/已巡逻 → 是否完成（1/0）。
static func done_met(cond: String, observed: int) -> bool:
	match cond:
		DONE_BUILT, DONE_TRAINED, DONE_RESEARCHED:
			return observed >= 1
		DONE_TARGET_DEAD, DONE_THREAT_CLEAR, DONE_REGION_CLEAR:
			return observed <= 0
		DONE_ARRIVED, DONE_PATROLLED:
			return observed >= 1
	return false


## 一次生命周期扫描。`active` = {id: goal}；`done` = {id: bool}；
## `best` = 本周期最高分的建议（用于抢占判定，空 = 不抢）。
## 返回 {"存活": {id: goal}, "释放": [{id, 原因, 金币, 木材, 动作, 对象}],
##       "达成": n, "过期": n, "被抢占": n}
## **释放额 = 预留 − 已用**：花掉的不退（钱已经变建筑/兵），没花的回公共池。
static func goal_tick(active: Dictionary, done: Dictionary, now: float, best: Dictionary = {},
		threshold: float = URGENCY_THRESHOLD_DEFAULT) -> Dictionary:
	var alive: Dictionary = {}
	var released: Array = []
	var n_done: int = 0
	var n_exp: int = 0
	var n_pre: int = 0
	for k in active.keys():
		var g: Dictionary = (active[k] as Dictionary).duplicate(true)
		var gid: String = String(g.get("id", ""))
		var reason: String = ""
		if bool(done.get(gid, false)):
			reason = "达成"
			n_done += 1
		elif now > float(g.get("过期时间", 0.0)):
			reason = "过期"
			n_exp += 1
		elif not best.is_empty() and String(best.get("id", "")) != gid \
				and float(best.get("紧迫度", 0.0)) > float(g.get("紧迫度", 0.0)) + PREEMPT_MARGIN \
				and float(best.get("紧迫度", 0.0)) >= threshold:
			reason = "被抢占"
			n_pre += 1
		if reason.is_empty():
			alive[k] = g
			continue
		var res: Dictionary = g.get("预留", {"金币": 0, "木材": 0})
		var used: Dictionary = g.get("已用", {"金币": 0, "木材": 0})
		released.append({
			"id": gid, "原因": reason, "动作": String(g.get("动作", "")),
			"对象": String(g.get("对象", "")),
			"金币": maxi(int(res.get("金币", 0)) - int(used.get("金币", 0)), 0),
			"木材": maxi(int(res.get("木材", 0)) - int(used.get("木材", 0)), 0),
		})
	return {"存活": alive, "释放": released,
		"达成": n_done, "过期": n_exp, "被抢占": n_pre}


## 目标花钱：从预留里扣（不扣到负数）。返回新目标（纯函数，不改入参）。
static func goal_consume(g: Dictionary, gold: int, wood: int) -> Dictionary:
	var n: Dictionary = g.duplicate(true)
	var used: Dictionary = n.get("已用", {"金币": 0, "木材": 0})
	var res: Dictionary = n.get("预留", {"金币": 0, "木材": 0})
	used["金币"] = mini(int(used.get("金币", 0)) + maxi(gold, 0),
			int(res.get("金币", 0)))
	used["木材"] = mini(int(used.get("木材", 0)) + maxi(wood, 0),
			int(res.get("木材", 0)))
	n["已用"] = used
	return n


## 活动目标的剩余预留（未花掉的部分）—— 局末必须为 0。
static func reserve_left(active: Dictionary) -> Dictionary:
	var gold: int = 0
	var wood: int = 0
	for k in active.keys():
		var g: Dictionary = active[k] as Dictionary
		var res: Dictionary = g.get("预留", {"金币": 0, "木材": 0})
		var used: Dictionary = g.get("已用", {"金币": 0, "木材": 0})
		gold += maxi(int(res.get("金币", 0)) - int(used.get("金币", 0)), 0)
		wood += maxi(int(res.get("木材", 0)) - int(used.get("木材", 0)), 0)
	return {"金币": gold, "木材": wood}


## 局末清空（bench 调）。返回清理前的剩余预留，落盘 `goal_reserve_left_at_end`。
static func goal_dispose(active: Dictionary) -> Dictionary:
	var left: Dictionary = reserve_left(active)
	active.clear()
	return left


# ---------------------------------------------------------------------------
# 空过机制（§4.3）
# ---------------------------------------------------------------------------

## 空过期间**停**的动作类型（新工地 / 新开销）。
## ★ 执行层的动作名不止"建造"一个字：箭塔/分基地走的是 `建塔` / `建分基地`
##   （2C-9 的九动作表），漏一个就会在空过期间继续开新工地
##   —— 机制验证局（--goal-thr=0.95）实测漏过 3 次"扩展线·建塔"，所以这里必须列全。
const NOOP_BLOCKED_ACTIONS: Array[String] = [
	ACT_TRAIN, ACT_BUILD, "修理", ACT_RESEARCH, "建塔", "建分基地",
]

static func blocked_by_noop(action: String) -> bool:
	return NOOP_BLOCKED_ACTIONS.has(action)


## 空过期间的储蓄态：金币 ≥ 1.5 × G(t) → 退出"积极储蓄"（但**不退出空过**）。
## 返回 {"积极储蓄": bool, "退出": bool}；`退出` = 本周期刚从积极转非积极（计数用）。
static func noop_saving(gold: int, reserve: float, was_aggressive: bool) -> Dictionary:
	var g: float = maxf(float(gold), 0.0)
	var r: float = maxf(reserve, 0.0)
	var aggressive: bool = g < NOOP_SAVING_EXIT_RATIO * r
	return {"积极储蓄": aggressive, "退出": was_aggressive and not aggressive}


# ---------------------------------------------------------------------------
# 执行层优先级（§6 表；只改"谁先谁后"，不改执行细节）
# ---------------------------------------------------------------------------

## 主目标 → 有序的动作优先级表。每项 {"动作": ..., "目标": ...}；
## `目标` 非空时只匹配该对象的诉求，空 = 该动作类型全部匹配。
## 未匹配的诉求排在最后（按原诉求分降序）—— 保证"其他"永远垫底而不是消失。
static func priority_order(main: Dictionary) -> Array:
	if main.is_empty():
		return []
	var act: String = String(main.get("动作", ""))
	var obj: String = String(main.get("对象", ""))
	match act:
		ACT_BUILD:
			# 补人口 / 补建筑：先把它自己建出来，再谈兵和别的工地
			return [
				{"动作": ACT_BUILD, "目标": obj},
				{"动作": ACT_BUILD, "目标": ""},
				{"动作": ACT_TRAIN, "目标": ""},
				{"动作": ACT_RESEARCH, "目标": ""},
				{"动作": "修理", "目标": ""},
				{"动作": ACT_DEFEND, "目标": ""},
				{"动作": ACT_PUSH_ALIAS, "目标": ""},
				{"动作": ACT_PATROL, "目标": ""},
				{"动作": ACT_SCOUT, "目标": ""},
			]
		ACT_TRAIN:
			return [
				{"动作": ACT_TRAIN, "目标": obj},
				{"动作": ACT_TRAIN, "目标": ""},
				{"动作": ACT_BUILD, "目标": ""},
				{"动作": ACT_RESEARCH, "目标": ""},
				{"动作": "修理", "目标": ""},
				{"动作": ACT_DEFEND, "目标": ""},
				{"动作": ACT_PUSH_ALIAS, "目标": ""},
				{"动作": ACT_PATROL, "目标": ""},
				{"动作": ACT_SCOUT, "目标": ""},
			]
		ACT_DEFEND:
			return [
				{"动作": "修理", "目标": ""},
				{"动作": ACT_DEFEND, "目标": ""},
				{"动作": ACT_PUSH_ALIAS, "目标": ""},
				{"动作": ACT_TRAIN, "目标": ""},
				{"动作": ACT_BUILD, "目标": ""},
				{"动作": ACT_PATROL, "目标": ""},
				{"动作": ACT_SCOUT, "目标": ""},
			]
		ACT_RESEARCH:
			return [
				{"动作": ACT_RESEARCH, "目标": ""},
				{"动作": ACT_TRAIN, "目标": ""},
				{"动作": ACT_BUILD, "目标": ""},
				{"动作": "修理", "目标": ""},
				{"动作": ACT_DEFEND, "目标": ""},
				{"动作": ACT_PUSH_ALIAS, "目标": ""},
				{"动作": ACT_PATROL, "目标": ""},
				{"动作": ACT_SCOUT, "目标": ""},
			]
		ACT_ATTACK_REGION, ACT_DESTROY:
			return [
				{"动作": ACT_PUSH_ALIAS, "目标": ""},
				{"动作": ACT_TRAIN, "目标": ""},
				{"动作": ACT_BUILD, "目标": ""},
				{"动作": ACT_RESEARCH, "目标": ""},
				{"动作": "修理", "目标": ""},
				{"动作": ACT_DEFEND, "目标": ""},
				{"动作": ACT_PATROL, "目标": ""},
				{"动作": ACT_SCOUT, "目标": ""},
			]
		ACT_SCOUT, ACT_PATROL:
			return [
				{"动作": exec_action_of(act), "目标": ""},
				{"动作": ACT_TRAIN, "目标": ""},
				{"动作": ACT_BUILD, "目标": ""},
				{"动作": "修理", "目标": ""},
				{"动作": ACT_DEFEND, "目标": ""},
				{"动作": ACT_PUSH_ALIAS, "目标": ""},
			]
		ACT_EXPAND_BASE:
			return [
				{"动作": ACT_BUILD, "目标": obj},
				{"动作": ACT_TRAIN, "目标": ""},
				{"动作": ACT_BUILD, "目标": ""},
				{"动作": "修理", "目标": ""},
				{"动作": ACT_DEFEND, "目标": ""},
				{"动作": ACT_PUSH_ALIAS, "目标": ""},
			]
	return []


## 执行层的动作名里"出击"是既有枚举（`战斗模型.ACT_PUSH`），目标层叫"攻击区域/摧毁单位"。
## 这里用常量别名避免拼错；值必须与 战斗模型.ACT_PUSH 一致。
const ACT_PUSH_ALIAS: String = "出击"

## 目标动作 → 执行层动作名（执行层的诉求表用的是 2C-9 那套：建造/训练/修理/出击/防守/
## 侦查/巡逻/建塔）。两套名字**必须有一张显式映射**，否则优先级表会静默匹配不上。
const EXEC_ACTION: Dictionary = {
	ACT_BUILD: "建造", ACT_TRAIN: "训练", ACT_RESEARCH: "研发",
	ACT_ATTACK_REGION: ACT_PUSH_ALIAS, ACT_DESTROY: ACT_PUSH_ALIAS,
	ACT_DEFEND: "防守", ACT_SCOUT: "侦查", ACT_PATROL: "巡逻",
	ACT_EXPAND_BASE: "建造",
}


static func exec_action_of(goal_act: String) -> String:
	return String(EXEC_ACTION.get(goal_act, goal_act))


## 诉求在优先级表里的位次（越小越先）。未命中 → 表长（垫底）。
static func demand_rank(d: Dictionary, order: Array) -> int:
	if order.is_empty():
		return 0
	var act: String = String(d.get("动作类型", ""))
	var tgt: String = String(d.get("目标", ""))
	var fallback: int = order.size()
	for i in range(order.size()):
		var o: Dictionary = order[i]
		if String(o.get("动作", "")) != act:
			continue
		var want: String = String(o.get("目标", ""))
		if want.is_empty() or want == tgt:
			return i
	return fallback


## 按主目标优先级重排诉求（同优先级保持原诉求分降序 —— 稳定排序，不吃哈希顺序）。
static func order_demands(demands: Array, main: Dictionary) -> Array:
	var order: Array = priority_order(main)
	var rows: Array = []
	for d in demands:
		if not (d is Dictionary):
			continue
		var dd: Dictionary = d as Dictionary
		rows.append({"d": dd, "r": demand_rank(dd, order),
			"s": float(dd.get("诉求分", 0.0))})
	rows.sort_custom(func(a, b):
		if int(a["r"]) != int(b["r"]):
			return int(a["r"]) < int(b["r"])
		if not is_equal_approx(float(a["s"]), float(b["s"])):
			return float(a["s"]) > float(b["s"])
		return String((a["d"] as Dictionary).get("目标", "")) \
				< String((b["d"] as Dictionary).get("目标", "")))
	var out: Array = []
	for r in rows:
		out.append(r["d"])
	return out
