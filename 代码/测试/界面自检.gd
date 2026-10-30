extends SceneTree
## **界面自检**：不依赖主场景，直接构造节点验证"框选 / 建筑面板 / 训练计时"。
## 运行：
##   godot --headless --path . --script 代码/测试/界面自检.gd
##
## ⚠ 本文件**不许写静态类型注解**（RtsUnit / RtsBuilding / RtsFaction）、也不许在编译期引用
##   自动加载单例名。原因：--script 指定的脚本在 autoload 注册之前就编译，
##   任何对 "Game" 的编译期引用都会让整条依赖链编译失败（表现为
##   "Nonexistent function 'new' in base 'GDScript'" —— 上一版就是这么假通过的）。
##   所以一律运行时 load() + 动态调用。

var _pass: int = 0
var _fail: int = 0
var _skip: int = 0
var _lines: Array = []

var _panel_script: Script = null


func _initialize() -> void:
	# 推迟一帧：让 autoload 与场景树就绪（同 战斗自检 的处理）
	call_deferred("_run")


func _run() -> void:
	print("========== 界面自检 ==========")
	_panel_script = load("res://代码/界面/建筑面板.gd")
	var units_script: Script = load("res://代码/单位/单位.gd")
	var building_script: Script = load("res://代码/单位/建筑.gd")
	var faction_script: Script = load("res://代码/数据/阵营.gd")
	var table_script: Script = load("res://代码/配置/单位表.gd")
	if _panel_script == null or units_script == null or building_script == null \
			or faction_script == null or table_script == null:
		_fail += 1
		_lines.append("  ✗ 关键脚本加载失败（界面自检无法运行）")
		_finish()
		return

	var defs: Dictionary = table_script.call("build_units")
	var player = faction_script.call("new")
	player.call("setup", 0, true, "玩家", Color(0.30, 0.62, 1.00), 800, 600)

	# ---- 1. 框选只收己方移动单位 ----
	var sel_script: Script = load("res://代码/操作/选择系统.gd")
	if sel_script != null and sel_script.has_method("is_box_unit"):
		var own = units_script.call("new")
		own.def = defs[&"peasant"]
		own.faction = player
		var foe = units_script.call("new")
		foe.def = defs[&"footman"]
		var enemy_faction = faction_script.call("new")
		enemy_faction.call("setup", 1, false, "敌人", Color(1, 0.3, 0.26), 800, 600)
		foe.faction = enemy_faction
		var house = building_script.call("new")
		house.def = defs[&"farm"]
		house.faction = player
		var picked: Array = []
		for n in [own, foe, house]:
			if bool(sel_script.call("is_box_unit", n, player)):
				picked.append(n)
		_ok("框选只收己方移动单位（不含敌方/建筑）",
			picked.size() == 1 and picked[0] == own, "命中 %d 个" % picked.size())
		own.free()
		foe.free()
		house.free()
	else:
		_skip += 1
		_lines.append("  · 跳过：选择系统没有 is_box_unit（接口改名了？）")

	# ---- 2. 建筑面板刷新 + 训练进度 ----
	var house2 = building_script.call("new")
	house2.def = defs[&"barracks"]
	house2.faction = player
	house2.is_constructed = true
	house2.progress = 1.0
	house2.train_queue = [&"footman"]
	house2.train_progress = 0.40
	var panel = _panel_script.call("new")
	if panel == null:
		_ok("建筑面板可以实例化", false)
		_finish()
		return
	root.add_child(panel)
	panel.call("refresh", house2)
	_ok("建筑面板刷新不报错", true)

	var frac: float = float(panel.call("train_fraction"))
	_ok("训练计时条：进度读出来是 0.40", absf(frac - 0.40) <= 0.02, "实测 %.2f" % frac)

	var st: Dictionary = panel.call("debug_train_state")
	var expect: float = (1.0 - 0.40) * float(defs[&"footman"].train_time)
	_ok("训练计时条：剩余秒数 = (1-progress) × train_time",
		absf(float(st.get("remaining", -1.0)) - expect) <= 0.1,
		"实测 %s / 期望 %.1fs" % [str(st.get("remaining")), expect])

	house2.train_progress = 0.85
	var st2: Dictionary = panel.call("debug_train_state")
	_ok("训练计时条随进度推进而减少",
		float(st2.get("remaining", 99.0)) < float(st.get("remaining", 0.0)) - 0.1,
		"%s → %s" % [str(st.get("remaining")), str(st2.get("remaining"))])

	_ok("建筑面板是独立实现（有自己的训练区/集结点区）",
		panel.has_method("_build_training") and panel.has_method("_build_rally")
		and panel.has_method("_build_construction"),
		"_build_training + _build_rally + _build_construction")

	house2.free()
	panel.queue_free()

	# ---- 3. 农民命令卡：第一级只有「建造」，建筑全部进展开页 ----
	var card_script: Script = load("res://代码/界面/命令卡.gd")
	if card_script != null:
		var card: Control = card_script.call("new")
		root.add_child(card)
		await process_frame
		var worker = units_script.call("new")
		worker.def = defs[&"peasant"]
		worker.faction = player
		worker.hp = 100.0
		card.call("refresh", [worker])
		var recs: Array = card.get("_entries")
		var first_labels: Array = []
		for rec in recs:
			first_labels.append(String((rec.get("entry", {}) as Dictionary).get("label", "")))
		var extra_build: int = 0
		for nm in ["农场", "兵营", "箭塔", "铁匠铺"]:
			if first_labels.has(nm):
				extra_build += 1
		_ok("农民第一级只有「建造」一个建筑入口（建筑按钮 %d 个）" % extra_build,
			first_labels.count("建造") == 1 and extra_build == 0
				and bool(card.call("can_enter_build_page")),
			"第一级：" + ", ".join(first_labels))
		card.call("enter_build_page")
		var recs2: Array = card.get("_entries")
		var page_labels: Array = []
		for rec in recs2:
			page_labels.append(String((rec.get("entry", {}) as Dictionary).get("label", "")))
		var want: Array = card.call("build_page_ids")
		var all_in: bool = true
		for bid in want:
			var d: UnitDef = defs.get(bid, null)
			if d == null or not page_labels.has(d.display_name):
				all_in = false
		_ok("建造展开页列出全部 %d 种建筑 + 返回" % want.size(),
			all_in and page_labels.has("返回"),
			"展开页：" + ", ".join(page_labels))
		card.queue_free()
	else:
		_skip += 1
		_lines.append("  · 跳过：命令卡脚本加载失败")

	_finish()


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])


func _finish() -> void:
	print("-------------------------------")
	for l in _lines:
		print(l)
	var total: int = _pass + _fail
	var verdict := "全部通过 ✓" if _fail == 0 and total > 0 else "有失败 ✗"
	if total == 0:
		verdict = "一条断言都没跑 ✗（自检本身坏了，不算通过）"
	print("结果：通过 %d / 失败 %d / 跳过 %d  —— %s" % [_pass, _fail, _skip, verdict])
	quit(0 if _fail == 0 and total > 0 else 1)