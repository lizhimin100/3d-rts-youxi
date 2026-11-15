extends RefCounted
## **布局卡（Layout Card）** —— 纯逻辑：解析 / 规范化 / 校验 / 血量继承算式。
##
## 属于：Model/layout（零引擎 API、零 Node、可命令行单独跑）
## 对外：parse(data) / normalize(data) / resolve_hp(initial_hp, saved_hp) /
##       is_destroyed(saved) / state_of(hp, max_hp) / SLOT_TYPES
##
## 设计口径（2026-11-15 玩家任务书）：
##   · 布局卡是**开发工具**（与地图编辑器、单位卡同级），不暴露给最终玩家；
##   · 卡只描述"静态"：槽位 id / 类型 / 单位 id / 坐标 / 朝向 / initial_hp；
##   · **严禁把 current_hp 写进卡**：当前血量只活在运行时存档里（静态/动态分离）；
##   · 坐标支持两种原点：world（绝对）与 site（相对阵营出生点），由 origin 决定；
##     运行时把相对坐标换算成世界坐标，Model 只负责"是这个形状"。
##
## 卡结构（JSON）：
## {
##   "version": 1,
##   "id": "短局_默认",
##   "display_name": "短局 · 默认基础布局",
##   "map": "res://Content/maps/主场景地图.tres",   // 可选：给制作工具标明适用地图
##   "origin": "site",                              // site（默认，相对出生点）/ world（绝对）
##   "replace_owner_slots": [0],                    // 实例化前清掉这些槽位已有的单位/建筑
##   "slots": [
##     {"slot_id": "P0_townhall", "type": "building", "id": "townhall",
##      "owner_slot": 0, "pos": [0, 0], "yaw": 3.14159, "initial_hp": 1600},
##     {"slot_id": "P0_peasant_1", "type": "unit", "id": "peasant",
##      "owner_slot": 0, "pos": [-6, 3], "initial_hp": 190}
##   ]
## }
##
## 【为什么 initial_hp 必须写在卡上、current_hp 必须不在】
##   1. 卡是内容资产，会被 git diff / 策划反复调；运行时血量每局都在变，
##      写进卡会让"卡"变成存档，改一次布局就丢一次进度；
##   2. 血量继承要跨"短局"读上一局的存档，那张存档才是 dynamic 的真源；
##   3. 校验里直接把 current_hp 当**错误**：谁写进去谁就被 --check 拦下。

const CARD_VERSION := 1
## 允许的槽位类型（建筑 / 单位）
const SLOT_TYPES := ["building", "unit"]
## 允许的原点写法
## site = 相对阵营出生点；townhall = 相对"实例化前该阵营的大本营"（地图已经摆好基地时用）；
## world = 绝对世界坐标。
const ORIGINS := ["site", "townhall", "world"]
## 单条槽位坐标的绝对值上限（米）：防止手滑写成 1e9 把单位生成到世界外
const POS_LIMIT := 100000.0
## 单槽最多生成多少个（unit 的 count；建筑恒 1）
const COUNT_MAX := 64


## 解析一张布局卡。返回 {ok, errors, card}。
## card 永远是规范化后的副本（ok=false 时也回传，方便工具显示"读到了什么"）。
static func parse(data: Variant) -> Dictionary:
	if not (data is Dictionary):
		return {"ok": false, "errors": ["layout: not a dictionary"], "card": {}}
	var card: Dictionary = normalize(data as Dictionary)
	var errors: Array = validate(card)
	return {"ok": errors.is_empty(), "errors": errors, "card": card}


## 规范化：补默认值 / 统一类型（不改语义，不做合法性判断）。
static func normalize(data: Dictionary) -> Dictionary:
	var card := {
		"version": int(data.get("version", CARD_VERSION)),
		"id": String(data.get("id", "")),
		"display_name": String(data.get("display_name", "")),
		"map": String(data.get("map", "")),
		"origin": String(data.get("origin", "site")),
		"replace_owner_slots": [],
		"slots": [],
	}
	var owners: Variant = data.get("replace_owner_slots", [])
	if owners is Array:
		for o in owners:
			card["replace_owner_slots"].append(int(o))
	var slots: Variant = data.get("slots", [])
	if slots is Array:
		for s in slots:
			if not (s is Dictionary):
				card["slots"].append({})
				continue
			card["slots"].append(_norm_slot(s as Dictionary))
	return card


static func _norm_slot(s: Dictionary) -> Dictionary:
	var pos: Array = [0.0, 0.0]
	var raw: Variant = s.get("pos", null)
	if raw is Array and (raw as Array).size() >= 2:
		pos = [float((raw as Array)[0]), float((raw as Array)[1])]
	return {
		"slot_id": String(s.get("slot_id", "")),
		"type": String(s.get("type", "")),
		"id": String(s.get("id", "")),
		"owner_slot": int(s.get("owner_slot", 0)),
		"pos": pos,
		"yaw": float(s.get("yaw", 0.0)),
		"initial_hp": float(s.get("initial_hp", 0.0)),
		"count": maxi(int(s.get("count", 1)), 1),
		# 出现 current_hp 就是"把运行时状态写进卡"，校验会直接判错（这里只记录，不改卡）
		"has_current_hp": s.has("current_hp"),
	}


## 校验规范化后的卡。返回错误字符串数组（空 = 通过）。
static func validate(card: Dictionary) -> Array:
	var errors: Array = []
	if int(card.get("version", 0)) != CARD_VERSION:
		errors.append("layout.version: expected %d, got %s" % [CARD_VERSION, str(card.get("version"))])
	if String(card.get("id", "")).strip_edges().is_empty():
		errors.append("layout.id: empty")
	var origin := String(card.get("origin", "site"))
	if not ORIGINS.has(origin):
		errors.append("layout.origin: %s (expected site/world)" % origin)
	var slots: Array = card.get("slots", [])
	if slots.is_empty():
		errors.append("layout.slots: empty")
	var seen: Dictionary = {}
	for i in slots.size():
		var s: Dictionary = slots[i]
		var tag := "slots[%d]" % i
		var sid := String(s.get("slot_id", ""))
		if sid.strip_edges().is_empty():
			errors.append(tag + ".slot_id: empty")
		elif seen.has(sid):
			errors.append(tag + ".slot_id: duplicated (" + sid + ")")
		seen[sid] = true
		var typ := String(s.get("type", ""))
		if not SLOT_TYPES.has(typ):
			errors.append(tag + ".type: " + typ + " (expected building/unit)")
		if String(s.get("id", "")).strip_edges().is_empty():
			errors.append(tag + ".id: empty")
		var pos: Array = s.get("pos", [])
		if pos.size() < 2:
			errors.append(tag + ".pos: expected [x, z]")
		else:
			if absf(float(pos[0])) > POS_LIMIT or absf(float(pos[1])) > POS_LIMIT:
				errors.append(tag + ".pos: out of range")
		if float(s.get("initial_hp", 0.0)) <= 0.0:
			errors.append(tag + ".initial_hp: must be > 0")
		if int(s.get("count", 1)) < 1 or int(s.get("count", 1)) > COUNT_MAX:
			errors.append(tag + ".count: 1..%d" % COUNT_MAX)
		if bool(s.get("has_current_hp", false)):
			errors.append(tag + ".current_hp: runtime state must not be stored in a layout card")
	return errors


## **血量继承算式**（唯一实现）：
##   存档里有这个槽位的血量 → 用存档值（夹到 1..initial_hp）；
##   没有（第一局 / 新槽位）→ 用 initial_hp。
## 损毁态（存档 destroyed=true）不看 hp：槽位锁定，复活由 ReviveSlot 负责。
static func resolve_hp(initial_hp: float, saved_hp: float, has_saved: bool) -> float:
	var mx: float = maxf(initial_hp, 1.0)
	if not has_saved:
		return mx
	if saved_hp <= 0.0:
		return 1.0
	return clampf(saved_hp, 1.0, mx)


## 存档条目是不是"损毁态"
static func is_destroyed(saved: Dictionary) -> bool:
	if saved.is_empty():
		return false
	return bool(saved.get("destroyed", false))


## 结算一条槽位的存档：活着记当前血量，死了记损毁标记。
static func state_of(hp: float, initial_hp: float) -> Dictionary:
	if hp <= 0.0:
		return {"hp": 0.0, "destroyed": true}
	return {
		"hp": clampf(hp, 0.0, maxf(initial_hp, 1.0)),
		"destroyed": false,
	}


## 槽位在卡里的定位：world 原点直接用；site / townhall 原点加锚点（运行时算）。
## 锚点对 site = 阵营出生点，对 townhall = 实例化前大本营的位置 —— 两者的换算在运行时，
## Model 只做"原点不是 world 就加锚点"这一条纯算术。
static func world_pos(origin: String, slot_pos: Array, anchor: Vector2 = Vector2.ZERO) -> Vector2:
	var p := Vector2(float(slot_pos[0]), float(slot_pos[1]))
	if origin == "site" or origin == "townhall":
		return anchor + p
	return p
