extends Node
## **升级 / 人口自检**：验证铁匠铺研究闭环与"训练队列人口预留"。
##
## 启用：godot --headless --fixed-fps 60 --path . -- --research-test
## 输出结尾一行 `RESEARCHTEST {json}`。
##
## 为什么单独测：
##   · 研究系统以前只有后端（RtsCombat），命令卡没有入口、也不扣费 —— 等于玩家永远吃不到升级；
##   · 人口上限只看"已出队单位"时，排队能瞬间把 20/24 撑到 28/20 —— 这是数值漏洞，肉眼很难发现。

var _report: Dictionary = {}
var _checks: Array = []
var _ok: bool = true


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _wait(0.4)

	var pf: RtsFaction = Game.player_faction
	_check(pf != null, "玩家阵营存在")
	if pf == null:
		_finish()
		return

	var bs: RtsBuilding = _first(&"blacksmith", pf)
	_check(bs != null, "开局有铁匠铺")
	if bs == null:
		_finish()
		return

	# --- 1. 研究：当场扣费 + 不能并行 ---
	var rd: ResearchDef = Cfg.research(&"attack_up")
	_check(rd != null, "研究定义存在")
	if rd == null:
		_finish()
		return
	pf.gold = 2000
	pf.wood = 2000
	var gold0: int = pf.gold
	var wood0: int = pf.wood
	var started: bool = bs.research(&"attack_up")
	_check(started, "可以开始研究")
	_check(bs.is_researching(), "进入研究中状态")
	_check(pf.gold == gold0 - rd.gold_cost and pf.wood == wood0 - rd.wood_cost,
			"研究当场扣费 %d金 %d木" % [rd.gold_cost, rd.wood_cost])
	_check(bs.research(&"armor_up") == false, "同一时间只能研究一项")

	# --- 2. 完成：等级 +1、攻击倍率生效、状态复位 ---
	var lv0: int = RtsCombat.attack_up_level(pf)
	bs.call("_tick_research", 999.0)
	_check(RtsCombat.attack_up_level(pf) == lv0 + 1, "研究完成后等级 +1")
	# ★ 口径变了（2026-11-01）：铁匠铺现在是**平铺 +1 伤害/级**（最高 5 级），
	#   `attack_mult` 只剩"给 AI 估算战力"用（1.0 + 0.067 × 等级），
	#   不再是旧版的"每级 ×1.15"。断言跟着口径走，别再写死 1.15。
	var want_mult: float = 1.0 + 0.067 * float(lv0 + 1)
	_check(is_equal_approx(RtsCombat.attack_mult(pf), want_mult),
			"攻击倍率随等级上升（%.3f → %.3f）" % [1.0 + 0.067 * float(lv0), want_mult])
	_check(not bs.is_researching(), "研究结束后不再占着研究位")

	# --- 3. 满级封顶 ---
	var guard: int = 0
	while not RtsCombat.research_maxed(pf, &"attack_up") and guard < 10:
		if bs.research(&"attack_up"):
			bs.call("_tick_research", 999.0)
		guard += 1
	_check(RtsCombat.attack_up_level(pf) == rd.max_level,
			"等级封顶在 %d" % rd.max_level)
	_check(bs.research(&"attack_up") == false, "满级后拒绝继续研究")

	# --- 4. 资源不足拒绝 ---
	pf.gold = 0
	pf.wood = 0
	_check(bs.research(&"armor_up") == false, "资源不足时拒绝研究")
	_check(String(bs.research_block_reason(&"armor_up")) != "", "拒绝时能给出原因")

	# --- 4.5 界面：选中铁匠铺时命令卡必须真的出现研究按钮（不是只写了后端）---
	var sel: Node = get_parent().get_node_or_null("选择系统")
	_check(sel != null, "选择系统存在")
	if sel != null:
		if sel.has_method("select_units"):
			sel.call("select_units", [bs])
		else:
			# 与 主场景._qa_select 的兜底同一套：写 selected 再发选择信号
			sel.set("selected", [bs])
			bs.set("is_selected", true)
			Game.selection_changed.emit([bs])
		for i in 6:
			await get_tree().process_frame
		var hud: Node = get_parent().get_node_or_null("界面")
		var card: Node = hud.get("_card") if hud != null else null
		var grid: Node = card.get("_grid") if card != null else null
		var found: bool = false
		if grid != null:
			for ch in grid.get_children():
				var btn := ch as Button
				if btn == null:
					continue
				# 新版命令卡是"图标 + 子 Label"的格子，Button.text 为空；
				# 所以按钮是否存在要看自身/子节点的文本与 tooltip，不能只认 btn.text。
				if "武器锻造" in btn.text or "武器锻造" in btn.tooltip_text:
					found = true
					break
				for lb in _all_labels(btn):
					if "武器锻造" in lb.text:
						found = true
						break
				if found:
					break
		_check(found, "选中铁匠铺后命令卡出现研究按钮")

	# --- 5. 训练队列人口预留 ---
	var barracks: RtsBuilding = _first(&"barracks", pf)
	_check(barracks != null, "开局有兵营")
	if barracks == null:
		_finish()
		return
	barracks.train_queue.clear()
	pf.gold = 99999
	pf.wood = 99999
	var used: int = pf.food_used()
	var cap: int = pf.food_cap()
	var queued: int = 0
	while queued < 20 and barracks.queue_train(&"footman"):
		queued += 1
	var reserved: int = pf.food_reserved()
	_check(reserved == queued * 2, "队列预留人口 = %d（%d 个步兵）" % [queued * 2, queued])
	_check(used + reserved <= cap, "排队后占用 %d <= 上限 %d（不会预留爆表）" % [used + reserved, cap])
	_check(not barracks.queue_train(&"footman"),
			"人口预留满后再排队会被拒绝（不再出现 28/20）")

	# --- 6. 建造中的农场不提供人口 ---
	var farm_def: UnitDef = Cfg.unit(&"farm")
	var cap_before: int = pf.food_cap()
	var site: RtsBuilding = RtsBuilding.new()
	site.name = "自检农场工地"
	var parent: Node = get_parent()
	if parent != null:
		parent.add_child(site)
	site.global_position = RtsWorld.base_center(pf) + Vector3(0.0, 0.0, 16.0)
	site.setup_construction(pf, farm_def)
	Game.register(site)
	_check(pf.food_cap() == cap_before, "农场工地不立刻加人口")
	site.set_constructed(true)
	_check(pf.food_cap() == cap_before + farm_def.food_provided,
			"农场完工后才加 %d 人口" % farm_def.food_provided)
	Game.unregister(site)
	site.queue_free()

	# --- 7. 哨塔 → 箭塔（建筑改造）：只补差价、血量比例继承、占地不残留 ---
	_check_upgrade(pf)

	# --- 8. 升级要**读条**（2026-11-06 玩家口径：不能一口气变成箭塔）---
	_check_timed_upgrade(pf)
	_check_upgrade_cancel(pf)

	_finish()


## 升级=读条：进状态 / 当场扣差价 / 进度随时间涨 / 读满才换型号 / 忙时拒训练。
func _check_timed_upgrade(pf: RtsFaction) -> void:
	const REFIT := preload("res://代码/系统/建筑改造.gd")
	var wd: UnitDef = Cfg.unit(&"watchtower")
	var td: UnitDef = Cfg.unit(&"tower")
	_check(wd != null and td != null, "[读条] 哨塔/箭塔定义存在")
	if wd == null or td == null:
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	pf.gold = 2000
	pf.wood = 2000
	var bt: RtsBuilding = RtsBuilding.new()
	bt.name = "自检升级读条塔"
	parent.add_child(bt)
	bt.global_position = RtsWorld.snap_y(RtsWorld.base_center(pf) + Vector3(-16.0, 0.0, 16.0))
	bt.setup(pf, wd)
	bt.set_constructed(true)
	Game.register(bt)
	if Game.level != null and Game.level.has_method("mark_footprint"):
		Game.level.call("mark_footprint", bt)
	var at: Vector3 = bt.global_position
	var cost: Vector2i = REFIT.upgrade_cost(&"watchtower", &"tower")
	var g0: int = pf.gold
	_check(REFIT.start(bt), "[读条] 升级能开始（校验+扣差价）")
	_check(bt.is_upgrading(), "[读条] 进入升级状态")
	# ★ 2026-11-08 甲方案：升级和建造共用"施工中"状态机 ——
	#   点下去那一帧就该看到半成品哨塔，成品模型必须藏起来。
	_check(bool(bt.call("has_upgrade_stage")), "[施工中] 哨塔升级摆出半成品")
	if bt.visual != null:
		_check(not bt.visual.visible, "[施工中] 旧塔的成品模型已隐藏")
	_check(pf.gold == g0 - cost.x, "[读条] 升级费当场扣掉 %d 金" % cost.x)
	_check(bt.upgrade_progress() < 0.01, "[读条] 刚点下去进度 0（不是瞬变）")
	_check(not bt.queue_train(&"footman"), "[读条] 读条期间不能训练")
	bt.call("_tick_upgrade", 1.0)
	var p1: float = bt.upgrade_progress()
	_check(p1 > 0.0 and p1 < 1.0, "[读条] 进度随时间涨（%.2f）" % p1)
	bt.call("_tick_upgrade", 999.0)
	var found: RtsBuilding = null
	for b in pf.buildings:
		if b == null or not is_instance_valid(b):
			continue
		var rb := b as RtsBuilding
		if rb == null or rb.def == null or rb.def.id != &"tower":
			continue
		if rb.global_position.distance_to(at) < 1.5:
			found = rb
	_check(found != null, "[读条] 读满后原地换成箭塔")
	if found != null:
		_check(found.is_constructed, "[读条] 新塔是完工状态")
		_check(found.def.id == &"tower", "[读条] 施工中只显示半成品，到点才换成箭塔")
		Game.unregister(found)
		if Game.level != null and Game.level.has_method("clear_footprint"):
			Game.level.call("clear_footprint", found)
		found.queue_free()


## 取消升级：半成品必须撤掉、旧模型必须露回来（否则玩家会看到一座"永远在施工"的塔）
func _check_upgrade_cancel(pf: RtsFaction) -> void:
	const REFIT := preload("res://代码/系统/建筑改造.gd")
	var wd: UnitDef = Cfg.unit(&"watchtower")
	if wd == null:
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	pf.gold = 2000
	pf.wood = 2000
	var bt: RtsBuilding = RtsBuilding.new()
	bt.name = "自检取消升级塔"
	parent.add_child(bt)
	bt.global_position = RtsWorld.snap_y(RtsWorld.base_center(pf) + Vector3(-22.0, 0.0, -14.0))
	bt.setup(pf, wd)
	bt.set_constructed(true)
	Game.register(bt)
	if Game.level != null and Game.level.has_method("mark_footprint"):
		Game.level.call("mark_footprint", bt)
	REFIT.start(bt)
	_check(bool(bt.call("has_upgrade_stage")), "[取消] 开始后摆出半成品")
	bt.cancel_upgrade()
	_check(not bool(bt.call("has_upgrade_stage")), "[取消] 半成品已撤掉")
	if bt.visual != null:
		_check(bt.visual.visible, "[取消] 旧模型露回来")
	Game.unregister(bt)
	if Game.level != null and Game.level.has_method("clear_footprint"):
		Game.level.call("clear_footprint", bt)
	bt.queue_free()


## 哨塔升级箭塔：这是 2026-11-01 新增的玩家/AI 共用能力，
## 失败方式很隐蔽（占地没清 → 新塔被判"不能建"；血量归满 → 变成回血挂）。
## 所以按"钱 / 型号 / 血量 / 坐标"四条分别断言。
func _check_upgrade(pf: RtsFaction) -> void:
	const REFIT := preload("res://代码/系统/建筑改造.gd")
	var wd: UnitDef = Cfg.unit(&"watchtower")
	var td: UnitDef = Cfg.unit(&"tower")
	_check(wd != null and td != null, "哨塔/箭塔定义都存在")
	if wd == null or td == null:
		return
	var parent: Node = get_parent()
	if parent == null:
		return
	var home: Vector3 = RtsWorld.base_center(pf)
	var bt: RtsBuilding = RtsBuilding.new()
	bt.name = "自检哨塔"
	parent.add_child(bt)
	bt.global_position = RtsWorld.snap_y(home + Vector3(14.0, 0.0, 14.0))
	bt.setup(pf, wd)
	bt.set_constructed(true)
	Game.register(bt)
	if Game.level != null and Game.level.has_method("mark_footprint"):
		Game.level.call("mark_footprint", bt)
	# 打掉 40% 血：升级后必须还是 60%，不能偷偷回满
	bt.hp = wd.max_hp * 0.6
	var gold0: int = pf.gold
	var wood0: int = pf.wood
	var cost: Vector2i = REFIT.upgrade_cost(&"watchtower", &"tower")
	_check(cost == Vector2i(maxi(0, td.gold_cost - wd.gold_cost),
			maxi(0, td.wood_cost - wd.wood_cost)), "升级只补差价 %d金 %d木" % [cost.x, cost.y])
	_check(REFIT.pay(pf, &"watchtower", &"tower"), "付得起升级费")
	_check(pf.gold == gold0 - cost.x and pf.wood == wood0 - cost.y, "升级费当场扣掉")
	var old_pos: Vector3 = bt.global_position
	var n: Node3D = REFIT.replace(bt, &"tower", true)
	_check(n != null, "改造返回了新建筑")
	if n == null:
		return
	var nb := n as RtsBuilding
	_check(nb != null and nb.def != null and nb.def.id == &"tower", "新建筑是箭塔")
	_check(nb != null and nb.is_constructed, "新建筑直接是完工状态")
	_check(is_equal_approx(n.global_position.x, old_pos.x)
			and is_equal_approx(n.global_position.z, old_pos.z), "新塔在原地")
	_check(nb != null and absf(nb.hp - td.max_hp * 0.6) <= 1.0,
			"血量按比例继承（%.0f / %.0f）" % [nb.hp if nb != null else -1.0, td.max_hp])
	# 占地：把新塔也拆掉后，原地必须能重新建 —— 说明旧塔的占用格子真的清了，
	# 没有留下"看不见的禁建区"（旧实现忘了 clear_footprint 就是这么坏的）。
	Game.unregister(n)
	if Game.level != null and Game.level.has_method("clear_footprint"):
		Game.level.call("clear_footprint", n)
	n.queue_free()
	_check(建筑网格.can_place(old_pos, td.footprint), "改造后占地可完整回收（不残留）")


## 找某阵营的第一座指定建筑
func _first(id: StringName, faction: RtsFaction) -> RtsBuilding:
	if faction == null:
		return null
	for b in faction.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive():
			continue
		var rb: RtsBuilding = b as RtsBuilding
		if rb != null and rb.def != null and rb.def.id == id and rb.is_constructed:
			return rb
	return null


func _check(cond: bool, label: String) -> void:
	_checks.append({"检查": label, "通过": cond})
	if not cond:
		_ok = false


## 递归收集某个控件下的全部 Label（新版命令卡的文字在子节点里）
func _all_labels(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Label:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _finish() -> void:
	_report["检查项"] = _checks
	_report["结果"] = "通过" if _ok else "失败"
	print("RESEARCHTEST " + JSON.stringify(_report))
	await _wait(0.2)
	get_tree().quit(0 if _ok else 1)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
