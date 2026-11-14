extends SceneTree
## 职责：run-game --check 的全部无窗口体检（一个入口）
## 属于：Tests/checks
## 用法：godot --headless --path . --script Tests/checks/check_all.gd
## 纪律：
##   · 检查调用**真实代码**（Cfg / CardStore / Model / SaveSvc），不在检查里重推公式；
##   · 每条检查都能被"故意改坏"打红（见 Tools/checks/negative_demo.ps1）；
##   · 失败退出码非 0；通过也要打印计数，避免"0 条断言算通过"。

const JsonFile := preload("res://Engine/util/json_file.gd")
const CardStore := preload("res://Game/config/card_store.gd")
const ModelDamage := preload("res://Model/core/damage.gd")
const ModelEconomy := preload("res://Model/core/economy.gd")
const SaveSchema := preload("res://Model/save/save_schema.gd")
const ModelTests := preload("res://Tests/model/model_tests.gd")
const CAMP := preload("res://Game/config/野怪营地表.gd")
const SKILLS := preload("res://Game/config/技能表.gd")
const SCREENS := "res://Content/data/screens.json"
const TOP_DIRS := ["Engine", "Model", "Views", "Game", "Content", "Tests", "Tools", "Documents"]
const LEGACY_DIRS := ["代码", "场景", "美术", "音频", "地图", "工具", "文档"]

var _pass := 0
var _fail := 0
var _names: Array[String] = []
var _cfg: Node = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========== 地基体检（run-game --check） ==========")
	_cfg = root.get_node_or_null("Cfg")
	_check_layout()
	_check_data_json()
	_check_cards()
	_check_card_io()
	_check_maps()
	_check_refs()
	_check_i18n()
	_check_assets()
	_check_model_purity()
	_check_engine_pin()
	_check_manifest()
	_check_model_tests()
	_check_availability()
	_check_audio()
	_check_integration()
	_check_save()
	_check_release_gate()
	_check_screens()
	_check_docs()
	_finish()

# ===========================================================================
# 1. 目录与自动加载
# ===========================================================================
func _check_layout() -> void:
	var missing: Array[String] = []
	for d in TOP_DIRS:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://" + d)):
			missing.append(d)
	_ok("七块砖目录齐全（%s）" % ", ".join(TOP_DIRS), missing.is_empty(), "缺：" + ", ".join(missing))
	var legacy: Array[String] = []
	for d in LEGACY_DIRS:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://" + d)):
			legacy.append(d)
	_ok("旧目录已清空（代码/场景/美术/音频/地图/工具/文档）", legacy.is_empty(), "残留：" + ", ".join(legacy))
	var text := _read("res://project.godot")
	var autoloads := ["App=", "Keys=", "I18n=", "SaveSvc=", "AudioSvc=", "Platform=", "Cfg=", "Game=", "DbgBridge="]
	var lack: Array[String] = []
	for a in autoloads:
		if not text.contains(a):
			lack.append(a.trim_suffix("="))
	_ok("引擎层自动加载已注册（9 个）", lack.is_empty(), "缺：" + ", ".join(lack))


# ===========================================================================
# 2. JSON 数据
# ===========================================================================
func _check_data_json() -> void:
	var files := _walk("res://Content/data")
	var count := 0
	var bad: Array[String] = []
	for f in files:
		if f.get_extension() != "json":
			continue
		count += 1
		var parser := JSON.new()
		if parser.parse(_read(f)) != OK:
			bad.append("%s:%d %s" % [f.replace("res://", ""), parser.get_error_line(), parser.get_error_message()])
	_ok("Content/data 下 JSON 全部可解析（%d 个）" % count, bad.is_empty(), "; ".join(bad))


func _check_cards() -> void:
	var problems: Array[String] = []
	var counts := {}
	for pair in [[CardStore.DIR_UNITS, "unit"], [CardStore.DIR_BUILDINGS, "building"],
			[CardStore.DIR_SKILLS, "skill"], [CardStore.DIR_CAMPS, "camp"]]:
		var entries = CardStore.list(pair[0])
		counts[pair[1]] = entries.size()
		for e in entries:
			var card: Resource = e["card"]
			var file := String(e["file"])
			if card == null:
				problems.append(file + " 读不出来")
				continue
			var id := _card_id(card, file)
			if id.is_empty():
				problems.append(file + " 没有 id")
				continue
			if file.get_basename() != id:
				problems.append("%s 文件名与 id 不一致（%s）" % [file, id])
			if not _is_ascii(id):
				problems.append(file + " id 非 ASCII")
			if String(card.get("display_name")).strip_edges().is_empty():
				problems.append(file + " display_name 为空")
			if pair[1] in ["unit", "building"] and float(card.get("max_hp")) <= 0.0:
				problems.append(file + " max_hp <= 0")
			if pair[1] == "unit":
				if float(card.get("range")) < 0.0 or int(card.get("attack")) < 0:
					problems.append(file + " 攻击/射程为负")
				if float(card.get("volume")) < 0.0:
					problems.append(file + " volume 为负")
			if pair[1] == "building":
				var fp: Vector2i = card.get("footprint")
				if fp.x < 1 or fp.y < 1:
					problems.append(file + " footprint < 1")
				if float(card.get("train_time")) <= 0.0:
					problems.append(file + " train_time <= 0")
			if pair[1] == "skill":
				var kind := String(card.get("kind"))
				if not (kind in ["主动", "开关", "被动", "采集", "受击"]):
					problems.append(file + " kind 非法：" + kind)
			if pair[1] == "camp":
				if String(card.get("den_building")).is_empty():
					problems.append(file + " den_building 为空")
				var creeps: Array = card.get("creeps")
				var counts_arr: Array = card.get("counts")
				if creeps.size() != counts_arr.size():
					problems.append(file + " creeps 与 counts 长度不一致")
	_ok("内容卡结构（单位 %d / 建筑 %d / 技能 %d / 营地 %d）" % [counts.get("unit", 0), counts.get("building", 0), counts.get("skill", 0), counts.get("camp", 0)],
		problems.is_empty(), "; ".join(problems.slice(0, 6)))


func _check_refs() -> void:
	if _cfg == null:
		_ok("Cfg 自动加载就绪", false)
		return
	var cfg: GameConfig = _cfg.get("game")
	var units: Dictionary = cfg.units
	var researches: Dictionary = cfg.researches
	var skills: Dictionary = SKILLS.all()
	var problems: Array[String] = []
	for entry in CardStore.list(CardStore.DIR_BUILDINGS):
		var card: Resource = entry["card"]
		for uid in card.get("trains"):
			if not units.has(StringName(uid)):
				problems.append("%s trains → 未定义单位 %s" % [entry["file"], uid])
		for rid in card.get("researches"):
			if not researches.has(StringName(rid)):
				problems.append("%s researches → 未定义研究 %s" % [entry["file"], rid])
	for entry in CardStore.list(CardStore.DIR_UNITS):
		var card: Resource = entry["card"]
		for sid in card.get("skills"):
			if not skills.has(StringName(sid)):
				problems.append("%s skills → 未定义技能 %s" % [entry["file"], sid])
		var mp := String(card.get("model_path"))
		if not mp.is_empty() and not ResourceLoader.exists(mp):
			problems.append("%s model_path 不存在：%s" % [entry["file"], mp])
	for camp in CAMP.all():
		var den := String(camp.get("den_building"))
		if not units.has(StringName(den)):
			problems.append("营地 %s 的 den_building 未定义：%s" % [str(camp.get("id")), den])
		for cid in camp.get("creeps"):
			if not units.has(StringName(cid)):
				problems.append("营地 %s 刷未定义单位：%s" % [str(camp.get("id")), cid])
	# game.json 里的开局编成
	var gdata := JsonFile.read_dict("res://Content/data/game.json", {})
	var props: Dictionary = gdata.get("props", {})
	for key in ["player_buildings", "enemy_buildings", "player_units", "enemy_units"]:
		var d: Variant = props.get(key, {})
		if d is Dictionary:
			for uid in (d as Dictionary).keys():
				if not units.has(StringName(uid)):
					problems.append("game.json %s → 未定义 id：%s" % [key, uid])
	# sim.json 的编制
	var sim := JsonFile.read_dict("res://Content/data/sim.json", {})
	for si in (sim.get("sides", []) as Array).size():
		for entry in (sim["sides"][si] as Dictionary).get("roster", []):
			var uid := String((entry as Dictionary).get("id", ""))
			if not units.has(StringName(uid)):
				problems.append("sim.json sides[%d] → 未定义单位：%s" % [si, uid])
	_ok("数据引用闭环（训练/研究/技能/模型/营地/开局/推演）", problems.is_empty(), "; ".join(problems.slice(0, 6)))

func _check_card_io() -> void:
	## 真人用编辑器改卡 = CardStore.save_card 写回 JSON。这里做一次真实往返。
	var entries = CardStore.list(CardStore.DIR_UNITS)
	if entries.is_empty():
		_ok("卡读写往返（编辑器保存路径）", false, "没有单位卡")
		return
	var card: Resource = entries[0]["card"]
	var tmp := "res://.test_profile/card_io/footman.json"
	var err := CardStore.save_card(card, tmp)
	var back := CardStore.load_card(tmp)
	var same := (back != null
		and String(back.get("card_id")) == String(card.get("card_id"))
		and is_equal_approx(float(back.get("max_hp")), float(card.get("max_hp")))
		and String(back.resource_path) == tmp)
	_ok("卡读写往返（编辑器保存路径 → JSON → 读回）", err == OK and same, "err=%d" % err)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.test_profile/card_io"))


func _check_maps() -> void:
	var store: Script = load("res://Game/map/地图存储.gd")
	if store == null:
		_ok("地图存储可加载", false)
		return
	var def: Resource = store.call("load_tres", "res://Content/maps/主场景地图.tres")
	_ok("主场景地图能被 MapStore 读回（编辑器同一入口）", def != null)
	if def != null:
		var size := float(def.get("size"))
		var objs: Array = def.get("objects")
		_ok("地图数据有效（尺寸/对象数）", size > 0.0 and objs.size() > 0, "size=%.0f objects=%d" % [size, objs.size()])


# ===========================================================================
# 3. 多语言
# ===========================================================================
func _check_i18n() -> void:
	var i18n := root.get_node_or_null("I18n")
	if i18n == null:
		_ok("I18n 自动加载就绪", false)
		return
	i18n.call("load_csv")
	var st: Dictionary = i18n.call("stats")
	_ok("ui.csv 可装载（%d 条 / %d 种语言）" % [int(st.get("keys", 0)), int(st.get("locales", 0))],
		int(st.get("keys", 0)) > 0 and String(st.get("error", "")).is_empty(), String(st.get("error", "")))
	# 两列齐全 + 重复 key
	var f := FileAccess.open("res://Content/i18n/ui.csv", FileAccess.READ)
	var rows_bad: Array[String] = []
	var dup: Array[String] = []
	var seen := {}
	if f != null:
		var header := f.get_csv_line()
		if header.size() < 3 or header[0] != "key" or header[1] != "zh" or header[2] != "en":
			rows_bad.append("表头必须是 key,zh,en")
		while not f.eof_reached():
			var row := f.get_csv_line()
			if row.size() == 1 and row[0].strip_edges().is_empty():
				continue
			if row.size() < 3:
				rows_bad.append(row[0] + " 列数不足")
				continue
			if row[1].strip_edges().is_empty() or row[2].strip_edges().is_empty():
				rows_bad.append(row[0] + " 的 zh/en 有空列")
			if seen.has(row[0]):
				dup.append(row[0])
			seen[row[0]] = true
		f.close()
	_ok("文案两列齐全（zh+en）、无重复 key", rows_bad.is_empty() and dup.is_empty(), "; ".join(rows_bad.slice(0, 4) + dup.slice(0, 4)))
	# 代码里用到的 key 必须存在
	var missing: Array[String] = []
	var used := 0
	var re := RegEx.new()
	re.compile("I18n\\.t\\(\\s*\"([^\"]+)\"")
	for f2 in _walk("res://Engine") + _walk("res://Views/screens"):
		if not f2.ends_with(".gd"):
			continue
		for m in re.search_all(_read(f2)):
			used += 1
			var key := m.get_string(1)
			if not bool(i18n.call("has", key)):
				missing.append("%s → %s" % [f2.get_file(), key])
	_ok("代码引用的 I18n key 都有定义（%d 处）" % used, missing.is_empty(), ", ".join(missing.slice(0, 5)))
	# 新界面必须零硬编码；旧界面用预算冻结
	var hard := 0
	for f3 in _walk("res://Views/screens"):
		if f3.ends_with(".gd"):
			hard += _count_cjk_literals(_read(f3))
	_ok("新界面（Views/screens）零写死中文", hard == 0, "实测 %d 处" % hard)
	var budget := JsonFile.read_dict("res://Content/i18n/legacy_budget.json", {})
	var by_dir: Dictionary = budget.get("by_dir", {})
	var over: Array[String] = []
	for dir_name in ["Game", "Views", "addons"]:
		var base: Dictionary = by_dir.get(dir_name, {})
		for f4 in _walk("res://" + dir_name):
			if not f4.ends_with(".gd"):
				continue
			var rel: String = f4.replace("res://", "")
			var n := _count_cjk_literals(_read(f4))
			var base_n := int(base.get(rel, 0))
			if n > base_n:
				over.append("%s %d>%d" % [rel, n, base_n])
	_ok("旧界面写死文案不增长（预算冻结）", over.is_empty(), "; ".join(over.slice(0, 5)))


# ===========================================================================
# 4. 资源 key
# ===========================================================================
func _check_assets() -> void:
	var keys := root.get_node_or_null("Keys")
	if keys == null:
		_ok("Keys 自动加载就绪", false)
		return
	var data := JsonFile.read_dict("res://Content/keys/assets.json", {})
	if data.is_empty():
		_ok("资源 key 表可读", false)
		return
	var bad: Array[String] = []
	for kind in data.keys():
		if kind in ["version", "note"] or not (data[kind] is Dictionary):
			continue
		for key in (data[kind] as Dictionary).keys():
			var p := String(data[kind][key])
			if not FileAccess.file_exists(p):
				bad.append("%s/%s → %s" % [kind, key, p])
	_ok("登记的 key 都指向真实文件", bad.is_empty(), "; ".join(bad.slice(0, 5)))
	var mapped := {}
	for kind in ["audio", "models", "icons", "shaders", "fx"]:
		for key in (data.get(kind, {}) as Dictionary).keys():
			mapped[String(data[kind][key])] = true
	var uncovered: Array[String] = []
	var scans := [
		["res://Content/audio", [".ogg", ".wav", ".mp3"]],
		["res://Content/art/模型", [".glb", ".gltf"]],
		["res://Content/art/图标", [".svg", ".png", ".jpg", ".webp"]],
		["res://Content/art/着色器", [".gdshader", ".shader"]],
		["res://Content/art/特效", [".tscn"]],
	]
	for pair in scans:
		for f in _walk(pair[0]):
			if f.get_extension() in pair[1]:
				var res: String = f
				if not mapped.has(res):
					uncovered.append(res.replace("res://", ""))
	_ok("内容资产全部已登记（%d 个 key）" % mapped.size(), uncovered.is_empty(), "未登记：" + ", ".join(uncovered.slice(0, 6)))

# ===========================================================================
# 5. 分层边界
# ===========================================================================
const MODEL_FORBIDDEN := ["extends Node", "Node3D", "SceneTree", "ResourceLoader", "FileAccess",
	"DirAccess", "OS.", "Engine.", "Input.", "Time.", "push_error", "print(", "get_tree("]

func _check_model_purity() -> void:
	var problems: Array[String] = []
	for f in _walk("res://Model"):
		if not f.ends_with(".gd"):
			continue
		var text := _read(f)
		var line_no := 0
		for line in text.split("\n"):
			line_no += 1
			var stripped := line.strip_edges()
			if stripped.begins_with("#"):
				continue
			for tok in MODEL_FORBIDDEN:
				if line.contains(tok):
					problems.append("%s:%d 出现 %s" % [f.replace("res://", ""), line_no, tok])
			var idx := line.find("res://")
			while idx >= 0:
				if not line.substr(idx).begins_with("res://Model/"):
					problems.append("%s:%d 引用 Model 之外的 res:// 路径" % [f.replace("res://", ""), line_no])
				idx = line.find("res://", idx + 1)
	_ok("Model 零引擎 API、只引用 Model 内部脚本", problems.is_empty(), "; ".join(problems.slice(0, 5)))


func _check_engine_pin() -> void:
	var pin := JsonFile.read_dict("res://Engine/pin.json", {})
	var files: Dictionary = pin.get("files", {})
	if files.is_empty():
		_ok("Engine/pin.json 存在且非空", false)
		return
	var problems: Array[String] = []
	for rel in files.keys():
		var path := "res://Engine/" + String(rel)
		if not FileAccess.file_exists(path):
			problems.append("缺文件 " + String(rel))
			continue
		if _sha256(path) != String((files[rel] as Dictionary).get("sha256", "")):
			problems.append("被改过 " + String(rel))
	for f in _walk("res://Engine"):
		var rel2: String = f.replace("res://Engine/", "")
		if rel2 == "pin.json" or rel2.ends_with(".uid"):
			continue
		if not files.has(rel2):
			problems.append("未登记 " + rel2)
	_ok("共享引擎层与 pin.json 一致（%d 个文件）" % files.size(), problems.is_empty(), "; ".join(problems.slice(0, 5)))


func _check_manifest() -> void:
	var man := JsonFile.read_dict("res://Content/manifest.json", {})
	var listed := {}
	for e in man.get("files", []):
		listed[String(e.get("path", ""))] = true
	var dirs := ["Game", "Views", "Model", "Engine", "Tests", "Tools", "Content/data",
		"Content/i18n", "Content/keys", "addons"]
	var current := {}
	for d in dirs:
		for f in _walk("res://" + d):
			if f.ends_with(".import") or f.ends_with(".tmp"):
				continue
			current[f.replace("res://", "")] = true
	var added: Array[String] = []
	var removed: Array[String] = []
	for p in current.keys():
		if not listed.has(p):
			added.append(p)
	for p in listed.keys():
		if not current.has(p):
			removed.append(p)
	_ok("源文件清单与磁盘一致（新增/删除要走 Tools/gen/gen_manifest.py）",
		added.is_empty() and removed.is_empty(),
		"新增 %d（如 %s）／缺失 %d" % [added.size(), added.slice(0, 3), removed.size()])

# ===========================================================================
# 6. Model 自测 + 游戏侧集成
# ===========================================================================
func _check_model_tests() -> void:
	var r: Dictionary = ModelTests.run_all()
	_pass += int(r["pass"])
	_fail += int(r["fail"])
	if int(r["fail"]) > 0:
		_names.append("Model 自测")
		for line in r["lines"]:
			if String(line).contains("✗"):
				print(line)
	print("  · Model 自测：通过 %d / 失败 %d" % [int(r["pass"]), int(r["fail"])])


## 可用性：P0 回归（一本出二本兵 / 升级中训练 / 队列满 / 没钱）+ 三个调用点同源
func _check_availability() -> void:
	var A: Script = load("res://Game/config/可用性查询.gd")
	var b_script: Script = load("res://Game/units/建筑.gd")
	var f_script: Script = load("res://Game/core/阵营.gd")
	if A == null or b_script == null or f_script == null or _cfg == null:
		_ok("可用性适配器可加载", false)
		return
	var b: Node3D = b_script.new()
	var f: RefCounted = f_script.new()
	f.call("setup", 0, true, "测试阵营", Color.WHITE, 500, 500)
	var defs: Dictionary = (_cfg.get("game")).units
	b.set("def", defs.get(&"barracks", null))
	b.set("faction", f)
	b.set("is_constructed", true)

	var t1: Dictionary = A.call("train", b, &"dwarf_musketeer", f)
	_ok("P0：一本不能出二本兵（tier_locked）", String(t1.get("reason", "")) == "tier_locked", String(t1.get("reason", "")))

	b.set("_upgrade_id", &"tower")
	var t2: Dictionary = A.call("train", b, &"footman", f)
	_ok("P0：升级中不能训练（upgrading）", String(t2.get("reason", "")) == "upgrading", String(t2.get("reason", "")))
	b.set("_upgrade_id", &"")

	var q: Array = b.get("train_queue")
	for i in 10:
		q.append(&"footman")
	var t3: Dictionary = A.call("train", b, &"footman", f)
	_ok("P0：队列满不能训练（queue_full）", String(t3.get("reason", "")) == "queue_full", String(t3.get("reason", "")))
	q.clear()

	# 给假阵营一座已完工大本营，否则 food_cap=0 会先报 no_food（测不到金币分支）
	var th: Node3D = b_script.new()
	th.set("def", defs.get(&"townhall", null))
	th.set("faction", f)
	th.set("is_constructed", true)
	var buildings: Array = f.get("buildings")
	buildings.append(th)
	f.set("gold", 0)
	f.set("wood", 0)
	var t4: Dictionary = A.call("train", b, &"footman", f)
	buildings.erase(th)
	th.free()
	_ok("P0：没钱不能训练（no_gold/no_wood）", String(t4.get("reason", "")) in ["no_gold", "no_wood"], String(t4.get("reason", "")))
	f.set("gold", 500)
	f.set("wood", 500)

	b.set("def", defs.get(&"blacksmith", null))
	b.set("_upgrade_id", &"tower")
	var r1: Dictionary = A.call("research", b, &"attack_up", f)
	_ok("P0：升级中不能研究（upgrading）", String(r1.get("reason", "")) == "upgrading", String(r1.get("reason", "")))
	b.free()

	var src_ok := (_read("res://Game/units/建筑.gd").contains("可用性查询")
		and _read("res://Views/hud/命令卡.gd").contains("可用性查询")
		and _read("res://Views/input/指令系统.gd").contains("可用性查询"))
	_ok("建筑/命令卡/指令系统走同一套可用性判断", src_ok)


## 音效：合成器就绪 + 游戏侧真的走合成映射（不是只放了个模块没人用）
func _check_audio() -> void:
	var svc := root.get_node_or_null("AudioSvc")
	if svc == null:
		_ok("AudioSvc 自动加载就绪", false)
		return
	var st: Dictionary = svc.call("synth_stats")
	_ok("合成音效器有 12 个预设", int(st.get("presets", 0)) == 12, "presets=%d" % int(st.get("presets", 0)))
	_ok("合成音效可被 AudioSvc 接受（未知 key 拒绝）",
		bool(svc.call("play_synth", "ui_click")) and not bool(svc.call("play_synth", "no_such_key")))
	var src := _read("res://Game/audio/音效管理.gd")
	_ok("游戏音效走 AudioStreamGenerator 映射", src.contains("SYNTH_KEYS") and src.contains("_play_synth"))


func _check_integration() -> void:
	if _cfg == null:
		return
	var combat: Script = load("res://Game/systems/战斗.gd")
	var cfg: GameConfig = _cfg.get("game")
	if combat == null or cfg == null:
		_ok("战斗脚本可加载", false)
		return
	var rules: Dictionary = combat.call("damage_rules", cfg)
	var diffs: Array[String] = []
	for at in 4:
		for arm in 5:
			for roll in [0.0, 0.25, 0.5, 0.75, 0.99]:
				var a: Variant = combat.call("compute", 12.0, 2.0, at, 3.0, arm, 1.2, roll, 0.3)
				var b := ModelDamage.compute(12.0, 2.0, at, 3.0, arm, rules, roll, 0.3, 1.2)
				if absf(float(a.get("damage")) - float(b["damage"])) > 0.000001:
					diffs.append("%d/%d/%.2f" % [at, arm, roll])
	_ok("游戏侧伤害 == Model 伤害（4×5×5 组合）", diffs.is_empty(), "不一致：" + ", ".join(diffs.slice(0, 5)))
	# 经济：阵营 pay 与 Model 一致
	var faction_script: Script = load("res://Game/core/阵营.gd")
	var def_script: Script = load("res://Game/config/单位定义.gd")
	var fac: RefCounted = faction_script.new()
	fac.set("gold", 100)
	fac.set("wood", 50)
	var def: Resource = def_script.new()
	def.set("gold_cost", 60)
	def.set("wood_cost", 20)
	var paid: bool = bool(fac.call("pay", def))
	var st := {"gold": 100, "wood": 50}
	var mpaid := ModelEconomy.pay(st, 60, 20)
	_ok("游戏侧扣费 == Model 扣费", paid == mpaid and int(fac.get("gold")) == int(st["gold"]) and int(fac.get("wood")) == int(st["wood"]),
		"游戏 %d/%d ｜ Model %d/%d" % [int(fac.get("gold")), int(fac.get("wood")), int(st["gold"]), int(st["wood"])])


# ===========================================================================
# 7. 存档隔离
# ===========================================================================
func _check_save() -> void:
	var save := root.get_node_or_null("SaveSvc")
	var app := root.get_node_or_null("App")
	if save == null or app == null:
		_ok("SaveSvc/App 自动加载就绪", false)
		return
	_ok("测试模式默认开启（--check 自动）", bool(app.get("test_mode")))
	var root_path := String(save.call("root"))
	_ok("存档根目录是隔离的测试目录", root_path.contains(".test_profile"), root_path)
	var payload := SaveSchema.new_profile(1)
	var wrote: bool = bool(save.call("save", 99, payload))
	var back: Dictionary = save.call("load_slot", 99)
	_ok("测试档写入/读回（schema 校验后）", wrote and int(back.get("version", 0)) == SaveSchema.CURRENT_VERSION, String(save.call("last_error")))
	save.call("delete", 99)
	_ok("真实档案目录未被触碰（slot 路径在隔离目录下）", String(save.call("slot_path", 1)).contains(".test_profile"))

# ===========================================================================
# 8. 发行 / 截图 / 文档
# ===========================================================================
func _check_release_gate() -> void:
	var text := _read("res://Tools/build/release_exclude.txt")
	var need := ["Engine/debug", "Tests", "Tools", "addons", "Content/legacy"]
	var lack: Array[String] = []
	for n in need:
		if not text.contains(n):
			lack.append(n)
	_ok("发行排除清单齐全（调试接口/测试/工具/编辑器/旧卡）", lack.is_empty(), "缺：" + ", ".join(lack))
	var bridge := _read("res://Engine/debug/debug_bridge.gd")
	_ok("调试接口有发行构建门禁", bridge.contains("App.release") and bridge.contains("OS.is_debug_build") and bridge.contains("127.0.0.1"))


func _check_screens() -> void:
	var data := JsonFile.read_dict(SCREENS, {})
	var screens: Dictionary = data.get("screens", {})
	if screens.is_empty():
		_ok("截图画面表 screens.json 存在", false)
		return
	var problems: Array[String] = []
	for name in screens.keys():
		var r: Dictionary = screens[name]
		var scene := String(r.get("scene", "res://Views/scenes/主场景.tscn"))
		if not ResourceLoader.exists(scene):
			problems.append("%s 场景不存在：%s" % [name, scene])
		if r.has("click") and not r.has("expect"):
			problems.append("%s 有 click 但没有 expect（点了不算成功，要验状态）" % name)
	_ok("截图画面表（%d 个画面）" % screens.size(), problems.is_empty(), "; ".join(problems))


func _check_docs() -> void:
	var agents := FileAccess.get_file_as_bytes("res://AGENTS.md")
	_ok("AGENTS.md 存在且 <= 20KB", agents.size() > 0 and agents.size() <= 20 * 1024, "%d 字节" % agents.size())
	var claude := _read("res://CLAUDE.md").strip_edges()
	_ok("CLAUDE.md 只有一行 @AGENTS.md", claude == "@AGENTS.md", claude)
	var concept := _read("res://Documents/concept.md")
	var has3 := concept.contains("已确认") and concept.contains("建议") and concept.contains("待决定")
	_ok("Documents/concept.md 三栏", has3)


# ===========================================================================
# 工具
# ===========================================================================
func _walk(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var child := dir_path + "/" + name
		if dir.current_is_dir():
			out.append_array(_walk(child))
		else:
			out.append(child)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _sha256(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


func _card_id(card: Resource, file: String) -> String:
	var v: Variant = card.get("card_id")
	if v is String and not (v as String).is_empty():
		return v
	v = card.get("id")
	if v is String and not (v as String).is_empty():
		return v
	return file.get_basename()


func _is_ascii(s: String) -> bool:
	for i in s.length():
		if s.unicode_at(i) > 127:
			return false
	return true


## 数一段代码里有几个"含中文的字符串字面量"（注释里的不算）
func _count_cjk_literals(text: String) -> int:
	var count := 0
	var i := 0
	var n := text.length()
	var in_str := false
	var in_comment := false
	var has_cjk := false
	var escaped := false
	while i < n:
		var ch := text[i]
		if in_comment:
			if ch == "\n":
				in_comment = false
			i += 1
			continue
		if in_str:
			if escaped:
				escaped = false
			elif ch == "\\":
				escaped = true
			elif ch == "\"":
				in_str = false
				if has_cjk:
					count += 1
					has_cjk = false
			else:
				var cp := text.unicode_at(i)
				if cp >= 0x4E00 and cp <= 0x9FFF:
					has_cjk = true
			i += 1
			continue
		if ch == "\"":
			in_str = true
			has_cjk = false
			i += 1
			continue
		if ch == "#":
			in_comment = true
			i += 1
			continue
		i += 1
	return count


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ✓ " + name + (("  " + detail) if not detail.is_empty() else ""))
	else:
		_fail += 1
		_names.append(name)
		print("  ✗ " + name + (("  " + detail) if not detail.is_empty() else ""))


func _finish() -> void:
	print("---------------------------------------------------------------")
	if _fail == 0:
		print("CHECK 通过 %d 项 / 失败 0  —— 地基体检全部通过 ✓" % _pass)
		quit(0)
	else:
		print("CHECK 通过 %d 项 / 失败 %d  —— 失败项：%s ✗" % [_pass, _fail, ", ".join(_names)])
		quit(1)