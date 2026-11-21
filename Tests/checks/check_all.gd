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
const ModelDamage := preload("res://Game/adapters/damage.gd")
const ModelEconomy := preload("res://Game/adapters/economy.gd")
const SaveSchema := preload("res://Game/adapters/save_schema.gd")
const ModelTests := preload("res://Tests/model/model_tests.gd")
const LAYOUT_CARD := preload("res://Game/adapters/layout_card.gd")
const CAMP := preload("res://Game/config/野怪营地表.gd")
const SKILLS := preload("res://Game/config/技能表.gd")
const SCREENS := "res://Content/data/screens.json"
const COMBAT_JSON := "res://Content/data/combat.json"
const UNITS_JSON := "res://Content/data/units.json"
const PLANNING_JSON := "res://Content/data/planning.json"
const LEVELS_JSON := "res://Content/data/levels.json"
const SHELLS_JSON := "res://Content/data/map_shells.json"
const LAYOUTS_JSON := "res://Content/data/player_layouts.json"
const ENCOUNTERS_JSON := "res://Content/data/enemy_encounters.json"
const SHELL_STORE := preload("res://Screens/editor/shell_store.gd")
const ASSEMBLY_API := preload("res://Game/map/关卡装配.gd")
const LEVEL_ID := "level_1"
const TOP_DIRS := ["Engine", "Model", "Screens", "Game", "Content", "Tests", "Tools", "Documents"]
const LEGACY_DIRS := ["代码", "场景", "美术", "音频", "地图", "工具", "文档"]

var _pass := 0
var _fail := 0
var _names: Array[String] = []
var _cfg: Node = null
var _content_cache: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========== 地基体检（run-game --check） ==========")
	_cfg = root.get_node_or_null("Cfg")
	_check_layout()
	_check_hard_paths()
	_check_data_json()
	_check_layout_cards()
	_check_cards()
	_check_card_io()
	_check_maps()
	_check_refs()
	_check_i18n()
	_check_assets()
	_check_model_purity()
	_check_distance_law()
	_check_combat_formula()
	_check_units_data()
	_check_planning_data()
	_check_level_data()
	_check_squad()
	_check_planning_view()
	_check_dev_editor()
	_check_map_shell()
	_check_asset_manifest()
	_check_r1_config()
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
	_check_legacy_removed()
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
	_ok("自动加载已注册（%d 个）" % autoloads.size(), lack.is_empty(), "缺：" + ", ".join(lack))


# ===========================================================================
# 1b. 硬路径完整性（preload / ext_resource / project.godot）
#
# 为什么单开一条：2026-11-14 按七块砖重排目录后，`addons/map_editor/主屏.gd` 里还留着两条
# `preload("res://代码/…")`，结果**整个编辑器插件 Parse Error**：先报两条"文件不存在"，
# 再连带 13 行"类型推断失败"（const Spec / MAP_SCALE 无类型 → 所有用它们的变量都推断不出来），
# 最后由 插件.gd 报一句极具误导性的 `Nonexistent function 'new' in base 'GDScript'`。
# 搬文件的真正代价就是这种硬路径漏网：preload 指向不存在的文件**永远是 bug**，不是可选依赖。
# 所以这里把三类硬路径一次性钉死：脚本 preload、.tres/.tscn 的 ext_resource、project.godot。
# ===========================================================================
const REF_SCAN_DIRS := ["Engine", "Model", "Screens", "Game", "Content", "Tests", "Tools", "addons"]
## preload("res://…") / preload('res://…')
const RE_PRELOAD := "preload\\(\\s*[\"'](res://[^\"']+)[\"']"
## .tres / .tscn 里的 ext_resource 行；写属性用的是 `key = "…"`（有空格），不会误伤
const RE_RES_PATH := "path=\"(res://[^\"]+)\""
## project.godot 里所有 res:// 字面量（主场景 / 图标 / 自动加载 / 插件清单）
const RE_ANY_RES := "(res://[^\"',)\\s]+)"


func _check_hard_paths() -> void:
	var re_preload := RegEx.new()
	re_preload.compile(RE_PRELOAD)
	var re_res := RegEx.new()
	re_res.compile(RE_RES_PATH)
	var re_any := RegEx.new()
	re_any.compile(RE_ANY_RES)
	var problems: Array[String] = []
	var count := 0
	for d in REF_SCAN_DIRS:
		for f in _walk("res://" + d):
			var short: String = f.replace("res://", "")
			var ext: String = f.get_extension()
			if ext == "gd":
				var line_no := 0
				for line in _read(f).split("\n"):
					line_no += 1
					# 注释里的路径示例（写法教学）不算引用
					if line.strip_edges().begins_with("#"):
						continue
					for m in re_preload.search_all(line):
						count += 1
						var p := m.get_string(1)
						if not FileAccess.file_exists(p):
							problems.append("%s:%d preload → %s" % [short, line_no, p])
			elif ext == "tres" or ext == "tscn":
				for m in re_res.search_all(_read(f)):
					count += 1
					var p := m.get_string(1)
					if not FileAccess.file_exists(p):
						problems.append("%s ext_resource → %s" % [short, p])
	for m in re_any.search_all(_read("res://project.godot")):
		count += 1
		var auto_path := m.get_string(1)
		if not FileAccess.file_exists(auto_path):
			problems.append("project.godot → %s" % auto_path)
	_ok("硬路径都指向真实文件（preload / ext_resource / 自动加载 %d 条）" % count,
		problems.is_empty(), "; ".join(problems.slice(0, 6)))


# ===========================================================================
# 2. JSON 数据
# ===========================================================================

# ===========================================================================
# 布局卡（短局固定基础布局；开发工具，不暴露给玩家）
# ===========================================================================
func _check_layout_cards() -> void:
	var dir := DirAccess.open("res://Content/data/layouts")
	if dir == null:
		_ok("布局卡目录存在（Content/data/layouts）", false)
		return
	var files: Array = []
	for f in dir.get_files():
		if f.ends_with(".json"):
			files.append(f)
	_ok("布局卡目录有卡（%d 张）" % files.size(), not files.is_empty())
	var errors: Array[String] = []
	var count: int = 0
	for f in files:
		var path := "res://Content/data/layouts/" + String(f)
		var text := FileAccess.get_file_as_string(path)
		var parsed: Dictionary = LAYOUT_CARD.parse(JSON.parse_string(text))
		if not bool(parsed.get("ok", false)):
			errors.append(f + " → " + str(parsed.get("errors", [])))
			continue
		count += 1
		var card: Dictionary = parsed.get("card", {})
		# 静态/动态分离：卡里出现 current_hp = 直接把运行时状态写进了内容资产。
		if text.contains("current_hp"):
			errors.append(f + " → 写了 current_hp（当前血量只能进存档）")
		for rec in card.get("slots", []):
			var s: Dictionary = rec
			var id := StringName(String(s.get("id", "")))
			var d: UnitDef = _cfg.call("unit", id) if _cfg != null else null
			if d == null:
				errors.append(f + " → 未知 id " + String(id))
				continue
			var want_building: bool = String(s.get("type", "")) == "building"
			if want_building and d.kind != RtsConst.Kind.BUILDING:
				errors.append(f + " → " + String(id) + " 不是建筑")
			elif not want_building and d.kind != RtsConst.Kind.UNIT:
				errors.append(f + " → " + String(id) + " 不是单位")
			elif float(s.get("initial_hp", 0.0)) > d.max_hp + 0.01:
				errors.append(f + " → " + String(id) + " 的 initial_hp 超过 max_hp")
	_ok("布局卡可解析且引用闭环（%d 张）" % count, errors.is_empty(), "; ".join(errors.slice(0, 4)))
	# 配置里登记的默认布局卡必须真实存在（否则短局会静默按地图布阵）
	var cfg_path: String = String(_cfg.game.short_layout) if _cfg != null else ""
	_ok("短局默认布局卡路径有效", cfg_path.is_empty() or FileAccess.file_exists(cfg_path), cfg_path)

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
	# 2026-11-14：卡的源路径改走 meta（`CardStore.path_of`），不再 take_over_path 到 .json
	# （后者会让编辑器对 .json 做依赖扫描并报 "No loader found …(expected type: Resource)"）。
	var same := (back != null
		and String(back.get("card_id")) == String(card.get("card_id"))
		and is_equal_approx(float(back.get("max_hp")), float(card.get("max_hp")))
		and CardStore.path_of(back) == tmp
		and String(back.resource_path).is_empty())
	_ok("卡读写往返（编辑器保存路径 → JSON → 读回）", err == OK and same, "err=%d" % err)
	# 反向验证：保存出来的 JSON 里**不许**再出现 metadata/* 字段
	# （以前 set_meta("source_path") 会被 encode_resource 写进 props，读回来报"未知字段"）
	var raw: Dictionary = (load("res://Engine/util/json_file.gd") as Script).call(
		"read_dict", tmp, {})
	var props: Dictionary = raw.get("props", {})
	var meta_keys: Array[String] = []
	for k in props.keys():
		if String(k).begins_with("metadata/"):
			meta_keys.append(String(k))
	_ok("卡 JSON 不写 metadata/* 字段", meta_keys.is_empty(), "出现了：" + ", ".join(meta_keys))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.test_profile/card_io"))
	# ★ 2026-11-14 回归（玩家报「改攻击范围 → 保存 → 还是旧值」）：
	#   编辑器按钮是 FOCUS_NONE，点「保存」**不会**让 SpinBox 的输入框失焦，
	#   Godot 就不会把打进去的字写回 `value` —— 取值拿到的是改之前那个数。
	#   卡片弹窗靠 `_commit_pending()` 逐个 apply() 兜住；这里断言这个机制真的成立。
	var sb := SpinBox.new()
	sb.min_value = 0.0
	sb.max_value = 3000.0
	sb.step = 1.0
	sb.value = 90.0
	sb.get_line_edit().text = "135"
	var stuck: float = sb.value
	sb.apply()
	var applied: float = sb.value
	sb.free()
	_ok("SpinBox 未回车的文本能靠 apply() 提交（卡片弹窗保存前置）",
		is_equal_approx(stuck, 90.0) and is_equal_approx(applied, 135.0),
		"未提交=%.1f apply 后=%.1f（若 apply 失效，改数值会存不进去）" % [stuck, applied])


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
	var re_t := RegEx.new()
	re_t.compile("T\\(\\s*\"([^\"]+)\"")
	for f2 in _walk("res://Engine") + _walk("res://Screens/screens") + _walk("res://Screens/editor"):
		if not f2.ends_with(".gd"):
			continue
		var re_use := re_t if f2.begins_with("res://Screens/editor") else re
		for m in re_use.search_all(_read(f2)):
			var key := m.get_string(1)
			if key.ends_with("_"):
				continue
			used += 1
			if not bool(i18n.call("has", key)):
				missing.append("%s → %s" % [f2.get_file(), key])
	_ok("代码引用的 I18n key 都有定义（%d 处）" % used, missing.is_empty(), ", ".join(missing.slice(0, 5)))
	# 新界面必须零硬编码；旧界面用预算冻结
	var hard := 0
	for f3 in _walk("res://Screens/screens"):
		if f3.ends_with(".gd"):
			hard += _count_cjk_literals(_read(f3))
	_ok("新界面（Screens/screens）零写死中文", hard == 0, "实测 %d 处" % hard)
	var budget := JsonFile.read_dict("res://Content/i18n/legacy_budget.json", {})
	var by_dir: Dictionary = budget.get("by_dir", {})
	var over: Array[String] = []
	for dir_name in ["Game", "Screens", "addons"]:
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
# 5. 分层边界（Model = 纯 C# 内核，零 Godot）
# ===========================================================================
## Model 的 C# 源码里不许出现的引擎符号（逐行扫，注释行不算）
const MODEL_FORBIDDEN_CS := ["using Godot", "Godot.", "GodotObject", "GD.", "partial class",
	"NodePath", "[Export]", "[GlobalClass]", "Variant"]

func _check_model_purity() -> void:
	var problems: Array[String] = []
	var cs_count: int = 0
	for f in _walk("res://Model"):
		if f.ends_with(".gd"):
			problems.append("%s 是 GDScript（Model 只收 C#）" % f.replace("res://", ""))
			continue
		if not f.ends_with(".cs"):
			continue
		cs_count += 1
		var line_no := 0
		for line in _read(f).split("\n"):
			line_no += 1
			var stripped := line.strip_edges()
			if stripped.begins_with("//") or stripped.begins_with("*") or stripped.begins_with("/*"):
				continue
			for tok in MODEL_FORBIDDEN_CS:
				if line.contains(tok):
					problems.append("%s:%d 出现 %s" % [f.replace("res://", ""), line_no, tok])
			if line.contains("res://"):
				problems.append("%s:%d 出现 res:// 路径" % [f.replace("res://", ""), line_no])
	_ok("Model 零引擎 API（%d 个 C# 文件，无 GDScript）" % cs_count,
		problems.is_empty() and cs_count > 0, "; ".join(problems.slice(0, 5)))

	# 工程文件层面：内核必须是普通 net8.0 类库，不许引 Godot.NET.Sdk
	var model_proj := _read("res://Model/WarIsland.Model.csproj")
	var proj_bad: Array[String] = []
	if not model_proj.contains("<Project Sdk=\"Microsoft.NET.Sdk\">"):
		proj_bad.append("内核 csproj 不是普通 SDK")
	if model_proj.contains("<Project Sdk=\"Godot"):
		proj_bad.append("内核 csproj 引了 Godot SDK")
	if model_proj.contains("<PackageReference"):
		proj_bad.append("内核 csproj 有外部包引用")
	var host_proj := _read("res://战争原岛.csproj")
	if not host_proj.contains("WarIsland.Model.csproj"):
		proj_bad.append("宿主没有 ProjectReference 到内核")
	if not host_proj.contains("Compile Remove=\"Model/**/*.cs\""):
		proj_bad.append("宿主没有排除 Model/**/*.cs（会编两遍）")
	_ok("内核 csproj 纯 net8.0 / 宿主正确引用", proj_bad.is_empty(), "; ".join(proj_bad))

	# 产物真的编出来了（run-game 会先 dotnet build）
	var dll := "res://Model/bin/Debug/net8.0/WarIsland.Model.dll"
	_ok("C# 内核已编译（WarIsland.Model.dll）", FileAccess.file_exists(dll), dll)

	# 桥能实例化：这是"GDScript 能真的调到内核"的唯一证据
	var bridge_sc := load("res://Game/adapters/bridge.gd")
	var mdl: RefCounted = null
	if bridge_sc != null:
		mdl = bridge_sc.call("get_bridge") as RefCounted
	_ok("桥可实例化（C# → GDScript 通路）", mdl != null)
	if mdl != null:
		var r1: float = float(mdl.call("R1"))
		_ok("内核 R1 = 0.015", is_equal_approx(r1, 0.015), "%.4f" % r1)


## 距离铁律：R1 只有一份真值（C#），GDScript 只许通过 射程基准.r1() 转发。
func _check_distance_law() -> void:
	var base_script := load("res://Game/config/射程基准.gd")
	var r1: float = float(base_script.call("r1"))
	var meters: float = float(base_script.call("米", 650.0))
	var units: float = float(base_script.call("值", 9.75))
	_ok("R1 换算：650 → 9.75 米，反算回 650",
		is_equal_approx(meters, 9.75) and absf(units - 650.0) < 0.001,
		"米=%.3f 值=%.1f" % [meters, units])
	# 规则层（Game/config、Game/units、Game/systems、Game/core）不许再出现 0.015；
	# Screens/ 与音频里的 0.015 是美术/混音常数，与本铁律无关，不扫。
	var hard: Array[String] = []
	for d in ["Game/config", "Game/units", "Game/systems", "Game/core", "Game/ai"]:
		for f in _walk("res://" + d):
			if not f.ends_with(".gd"):
				continue
			var line_no := 0
			for line in _read(f).split("\n"):
				line_no += 1
				if line.strip_edges().begins_with("#"):
					continue
				if line.contains("0.015"):
					hard.append("%s:%d" % [f.replace("res://", ""), line_no])
	_ok("R1 字面量只在内核（规则层零 0.015）", hard.is_empty(), "; ".join(hard.slice(0, 5)))
	# 升星镜像常量必须等于内核
	var star := load("res://Game/systems/升星.gd")
	var bridge_sc := load("res://Game/adapters/bridge.gd")
	var mdl: RefCounted = bridge_sc.call("get_bridge") as RefCounted if bridge_sc != null else null
	if mdl != null:
		var cap_ok: bool = int(star.get("STAR_CAP")) == int(mdl.call("StarCap"))
		var exp_ok: bool = is_equal_approx(float(star.get("KILL_EXP")), float(mdl.call("StarKillExp")))
		_ok("升星镜像常量 == C# 内核（上限 3 / 击杀 15 经验）", cap_ok and exp_ok)


# ===========================================================================
# 6b. 2026-11-21 新内核：6 步公式 / 12 兵种 / 规划 / 双 90 秒
# ===========================================================================
func _mdl() -> RefCounted:
	var bridge_sc := load("res://Game/adapters/bridge.gd")
	if bridge_sc == null:
		return null
	return bridge_sc.call("get_bridge") as RefCounted


## 底板参数校验（一行调用 Model，检查里不重推公式）。返回空 = 合法。
func mdl_board_errors(depth: float, margin: float, tile_scale: float) -> Array:
	var mdl := _mdl()
	if mdl == null:
		return ["bridge=null"]
	return mdl.call("MapBoardValidate", 120.0, 63.0, depth, 0.35, margin, tile_scale) as Array


## 四张数据表只验一次，后面几条检查共用（避免重复 parse）。
func _content() -> Dictionary:
	if not _content_cache.is_empty():
		return _content_cache
	var mdl := _mdl()
	if mdl == null:
		return {}
	_content_cache = mdl.call("ContentValidate",
		JsonFile.read_dict(UNITS_JSON, {}),
		JsonFile.read_dict(COMBAT_JSON, {}),
		JsonFile.read_dict(PLANNING_JSON, {}),
		JsonFile.read_dict(LEVELS_JSON, {}))
	return _content_cache


func _err_text(v: Variant) -> String:
	var parts: Array[String] = []
	if v is Array:
		var arr: Array = v
		for i in mini(arr.size(), 5):
			parts.append(String(arr[i]))
	return " ; ".join(parts)


func _arr(v: Variant) -> Array:
	return v if v is Array else []


func _check_combat_formula() -> void:
	var mdl := _mdl()
	if mdl == null:
		_ok("新内核桥就绪（CombatCalculator）", false)
		return
	var c := _content()
	if c.is_empty():
		_ok("战斗数据可装载", false)
		return
	_ok("战斗数据校验（6×6 克制表 / 6+6 枚举）", _arr(c.get("combat_errors", [])).is_empty(), _err_text(c.get("combat_errors", [])))
	_ok("攻击枚举 6 种、护甲枚举 6 种",
		_arr(c.get("attack_types", [])).size() == 6 and _arr(c.get("armor_types", [])).size() == 6,
		"%d / %d" % [_arr(c.get("attack_types", [])).size(), _arr(c.get("armor_types", [])).size()])
	_ok("克制表恰好 6×6 = 36 项", _arr(c.get("counter_table", [])).size() == 36,
		"%d 项" % _arr(c.get("counter_table", [])).size())

	# 36 格逐格对规格（行 = 普通/穿刺/魔法/攻城/混乱/神力；列 = 无甲/轻甲/中甲/重甲/坚固甲/神圣甲）
	var expected_table := [
		1.0, 1.0, 1.0, 1.1, 0.7, 0.8,
		1.5, 1.75, 0.75, 0.6, 0.35, 0.5,
		1.25, 1.0, 0.75, 1.25, 0.5, 1.25,
		1.0, 0.9, 0.5, 1.0, 1.6, 0.5,
		1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
		1.2, 1.2, 1.2, 1.2, 1.2, 1.0,
	]
	var table: Array = _arr(c.get("counter_table", []))
	var table_bad: Array[String] = []
	for i in mini(table.size(), expected_table.size()):
		if absf(float(table[i]) - float(expected_table[i])) > 0.000001:
			table_bad.append("[%d]%.2f≠%.2f" % [i, float(table[i]), float(expected_table[i])])
	_ok("克制表 36 格逐格对规格（改错一格会红）",
		table.size() == 36 and table_bad.is_empty(), ", ".join(table_bad.slice(0, 6)))

	var combat := JsonFile.read_dict(COMBAT_JSON, {})
	var atk := {"damage": 100.0, "cooldown": 2.0, "attack_type": 0, "hit": 100.0,
		"crit": 0.0, "crit_multiplier": 0.0, "pen_flat": 0.0, "pen_pct": 0.0, "attack_mult": 1.0}
	var dfn := {"armor": 0.0, "armor_type": 0, "dodge": 0.0, "armor_mult": 1.0, "taken_mult": 1.0}

	var b0: Dictionary = mdl.call("CombatComputeProbe", atk, dfn, combat, 0.5, 0.5)
	_ok("第 6 步：100 基础 / 无甲 = 100", absf(float(b0["damage"]) - 100.0) < 0.000001, "%.4f" % float(b0["damage"]))

	dfn["armor"] = 10.0
	dfn["armor_type"] = 2
	var b1: Dictionary = mdl.call("CombatComputeProbe", atk, dfn, combat, 0.5, 0.5)
	_ok("第 4 步：10 护甲 = 1/(1+10×0.06) → 100 变 62.5", absf(float(b1["damage"]) - 62.5) < 0.000001, "%.4f" % float(b1["damage"]))

	dfn["armor"] = -10.0
	var b2: Dictionary = mdl.call("CombatComputeProbe", atk, dfn, combat, 0.5, 0.5)
	_ok("负甲：-10 → 1.6 倍伤害（100 → 160）", absf(float(b2["damage"]) - 160.0) < 0.000001, "%.4f" % float(b2["damage"]))

	dfn["armor"] = -100.0
	var b3: Dictionary = mdl.call("CombatComputeProbe", atk, dfn, combat, 0.5, 0.5)
	_ok("负甲上限：-100 仍按 3 倍（100 → 300）", absf(float(b3["damage"]) - 300.0) < 0.000001, "%.4f" % float(b3["damage"]))

	dfn["armor"] = 10.0
	dfn["armor_type"] = 3
	atk["attack_type"] = 1
	atk["pen_flat"] = 3.0
	atk["pen_pct"] = 0.35
	var b4: Dictionary = mdl.call("CombatComputeProbe", atk, dfn, combat, 0.5, 0.5)
	_ok("第 3 步：有效护甲 10×(1-35%)-3 = 3.5", absf(float(b4["effective_armor"]) - 3.5) < 0.000001, "%.4f" % float(b4["effective_armor"]))
	_ok("第 5 步：穿刺 vs 重甲 = 0.6", absf(float(b4["counter"]) - 0.6) < 0.000001, "%.3f" % float(b4["counter"]))

	atk["attack_type"] = 0
	atk["pen_flat"] = 0.0
	atk["pen_pct"] = 0.0
	atk["crit"] = 0.25
	dfn["armor"] = 0.0
	dfn["armor_type"] = 0
	var b5: Dictionary = mdl.call("CombatComputeProbe", atk, dfn, combat, 0.5, 0.1)
	var b6: Dictionary = mdl.call("CombatComputeProbe", atk, dfn, combat, 0.5, 0.9)
	_ok("第 2 步：暴击掷 0.1 < 25% → 2 倍（200）", bool(b5["crit"]) and absf(float(b5["damage"]) - 200.0) < 0.000001, "%.4f" % float(b5["damage"]))
	_ok("暴击掷 0.9 → 不暴击（100）", not bool(b6["crit"]) and absf(float(b6["damage"]) - 100.0) < 0.000001, "%.4f" % float(b6["damage"]))

	# 命中率 + 期望 DPS（必须乘命中率，且负甲封 3 倍）
	atk["hit"] = 50.0
	atk["crit"] = 0.25
	dfn["armor"] = -100.0
	var e: Dictionary = mdl.call("CombatExpect", atk, dfn, combat)
	_ok("期望伤害 = 100×50%×1.25×3 = 187.5（乘命中率 + 负甲封顶）",
		absf(float(e["damage"]) - 187.5) < 0.000001, "%.4f" % float(e["damage"]))
	_ok("期望 DPS = 187.5 / 2 秒 = 93.75", absf(float(e["dps"]) - 93.75) < 0.000001, "%.4f" % float(e["dps"]))
	_ok("命中率 60 - 闪避 20 = 40%", absf(float(mdl.call("CombatHitChance", 60.0, 20.0)) - 0.4) < 0.000001)
	_ok("护甲承伤 -100 封 3 倍", absf(float(mdl.call("CombatArmorTaken", -100.0, combat)) - 3.0) < 0.000001)
	_ok("固定/百分比穿透先乘后减", absf(float(mdl.call("CombatEffectiveArmor", 10.0, 0.35, 3.0)) - 3.5) < 0.000001)

	var lane_src := FileAccess.get_file_as_string("res://Model/Battle/LaneBattle.cs")
	var level_src := FileAccess.get_file_as_string("res://Model/Battle/LevelRunner.cs")
	_ok("新战斗层只走 CombatCalculator（不调旧 Damage.Compute）",
		lane_src.contains("CombatCalculator.Compute") and not lane_src.contains("Damage.Compute") and not level_src.contains("Damage.Compute"))

	var old_calls: Array[String] = []
	for f in _walk("res://Game"):
		if not f.ends_with(".gd") or f.ends_with("Game/adapters/damage.gd"):
			continue
		for line in _read(f).split("\n"):
			if line.strip_edges().begins_with("#"):
				continue
			if line.contains("ModelDamage.compute"):
				old_calls.append(f.replace("res://", ""))
	_ok("旧伤害入口只在旧战斗层（新增调用会红）", old_calls == ["Game/systems/战斗.gd"], str(old_calls))


func _check_units_data() -> void:
	var mdl := _mdl()
	if mdl == null:
		return
	var c := _content()
	if c.is_empty():
		return
	_ok("单位数据校验（12 兵种）", _arr(c.get("unit_errors", [])).is_empty(), _err_text(c.get("unit_errors", [])))
	_ok("单位 12 个 / 阵营 3 个（启用 11）",
		int(c.get("unit_count", 0)) == 12 and int(c.get("faction_count", 0)) == 3 and int(c.get("enabled_unit_count", 0)) == 11,
		"%d 单位 / %d 阵营 / %d 启用" % [int(c.get("unit_count", 0)), int(c.get("faction_count", 0)), int(c.get("enabled_unit_count", 0))])

	var faction_rows: Array = _arr(c.get("faction_rows", []))
	var faction_ok := faction_rows.size() == 3
	var faction_detail: Array[String] = []
	for f in faction_rows:
		faction_detail.append("%s=%d" % [String(f.get("id", "?")), int(f.get("unit_count", 0))])
		if int(f.get("unit_count", 0)) != 4:
			faction_ok = false
	_ok("三阵营各 4 兵种", faction_ok, " ".join(faction_detail))

	var rows: Array = _arr(c.get("unit_rows", []))
	var by_id := {}
	for r in rows:
		by_id[String(r["id"])] = r

	var expected := {
		"alliance_footman": {"squad": 5, "range": 95.0, "atk": "普通", "armor": "中甲", "proj": false, "enabled": true},
		"alliance_pikeman": {"squad": 4, "range": 155.0, "atk": "普通", "armor": "中甲", "proj": false, "enabled": true},
		"alliance_archer": {"squad": 4, "range": 650.0, "atk": "穿刺", "armor": "轻甲", "proj": true, "enabled": true},
		"alliance_crossbowman": {"squad": 4, "range": 850.0, "atk": "穿刺", "armor": "轻甲", "proj": true, "enabled": true},
		"bandit_scout": {"squad": 6, "range": 85.0, "atk": "普通", "armor": "轻甲", "proj": false, "enabled": true},
		"bandit_marauder": {"squad": 4, "range": 105.0, "atk": "普通", "armor": "轻甲", "proj": false, "enabled": true},
		"bandit_chief": {"squad": 4, "range": 650.0, "atk": "魔法", "armor": "轻甲", "proj": true, "enabled": true},
		"bandit_lord": {"squad": 2, "range": 105.0, "atk": "普通", "armor": "重甲", "proj": false, "enabled": false},
		"murloc_slave": {"squad": 8, "range": 65.0, "atk": "普通", "armor": "无甲", "proj": false, "enabled": true},
		"murloc_raider": {"squad": 4, "range": 95.0, "atk": "普通", "armor": "轻甲", "proj": false, "enabled": true},
		"murloc_hunter": {"squad": 4, "range": 550.0, "atk": "穿刺", "armor": "轻甲", "proj": true, "enabled": true},
		"murloc_lord": {"squad": 2, "range": 95.0, "atk": "普通", "armor": "重甲", "proj": false, "enabled": true},
	}
	var bad: Array[String] = []
	for id in expected.keys():
		if not by_id.has(id):
			bad.append(id + " 缺失")
			continue
		var r: Dictionary = by_id[id]
		var e: Dictionary = expected[id]
		if int(r["squad_size"]) != int(e["squad"]):
			bad.append("%s squad %d≠%d" % [id, int(r["squad_size"]), int(e["squad"])])
		if absf(float(r["range"]) - float(e["range"])) > 0.001:
			bad.append("%s range %.0f≠%.0f" % [id, float(r["range"]), float(e["range"])])
		if String(r["attack_type"]) != String(e["atk"]):
			bad.append("%s 攻击 %s≠%s" % [id, r["attack_type"], e["atk"]])
		if String(r["armor_type"]) != String(e["armor"]):
			bad.append("%s 护甲 %s≠%s" % [id, r["armor_type"], e["armor"]])
		if bool(r["projectile"]) != bool(e["proj"]):
			bad.append("%s 投射物 %s≠%s" % [id, r["projectile"], e["proj"]])
		if bool(r["enabled"]) != bool(e["enabled"]):
			bad.append("%s enabled %s≠%s" % [id, r["enabled"], e["enabled"]])
	_ok("12 兵种的队形/射程/攻防类型/投射物/enabled 全部对表", bad.is_empty(), " ; ".join(bad.slice(0, 6)))

	var hit_bad: Array[String] = []
	for r in rows:
		if not is_equal_approx(float(r["hit"]), 100.0) or not is_equal_approx(float(r["dodge"]), 0.0) or not is_equal_approx(float(r["crit"]), 0.0):
			hit_bad.append(String(r["id"]))
	_ok("所有单位默认 命中=100 / 闪避=0 / 暴击=0", hit_bad.is_empty(), ", ".join(hit_bad))

	var proj_bad: Array[String] = []
	for r in rows:
		var ranged := float(r["range"]) >= 300.0
		if bool(r["projectile"]) != ranged:
			proj_bad.append(String(r["id"]))
	_ok("近战无投射物、远程生成投射物（按 300 分界）", proj_bad.is_empty(), ", ".join(proj_bad))

	var xbow: Dictionary = by_id.get("alliance_crossbowman", {})
	_ok("弩兵自带破甲（35% + 3）",
		absf(float(xbow.get("pen_pct", 0.0)) - 0.35) < 0.000001 and absf(float(xbow.get("pen_flat", 0.0)) - 3.0) < 0.000001,
		"%.2f / %.1f" % [float(xbow.get("pen_pct", 0.0)), float(xbow.get("pen_flat", 0.0))])

	var murloc_bad: Array[String] = []
	for r in rows:
		if String(r["faction"]) == "murloc" and not bool(r["placeholder"]):
			murloc_bad.append(String(r["id"]))
	_ok("鱼人三兵种全部 use_placeholder_mesh=true", murloc_bad.is_empty(), ", ".join(murloc_bad))
	_ok("豺狼人领主配置保留但 enabled=false", by_id.has("bandit_lord") and not bool(by_id["bandit_lord"]["enabled"]))


func _check_planning_data() -> void:
	var mdl := _mdl()
	if mdl == null:
		return
	var c := _content()
	if c.is_empty():
		return
	_ok("规划数据校验（CP/人口/建筑/卡牌）", _arr(c.get("planning_errors", [])).is_empty(), _err_text(c.get("planning_errors", [])))
	_ok("建筑 4 种 / 卡牌 10 种 / 开局 4 座",
		int(c.get("building_count", 0)) == 4 and int(c.get("card_count", 0)) == 10 and int(c.get("start_building_count", 0)) == 4,
		"%d 建筑 / %d 卡 / %d 开局" % [int(c.get("building_count", 0)), int(c.get("card_count", 0)), int(c.get("start_building_count", 0))])
	_ok("训练牌 Tag 闭环（每张都找到会训练该兵种的建筑）",
		int(c.get("train_card_count", 0)) > 0 and int(c.get("train_tag_closure", 0)) == int(c.get("train_card_count", 0)),
		"%d/%d" % [int(c.get("train_tag_closure", 0)), int(c.get("train_card_count", 0))])

	var planning := JsonFile.read_dict(PLANNING_JSON, {})
	var build_n := 0
	var train_n := 0
	var strat_n := 0
	var exhaust_bad: Array[String] = []
	for card in planning.get("cards", []):
		var kind := String(card.get("kind", ""))
		var want := kind == "build"
		if kind == "build":
			build_n += 1
		elif kind == "train":
			train_n += 1
		elif kind == "strategy":
			strat_n += 1
		if bool(card.get("exhaust", false)) != want:
			exhaust_bad.append(String(card.get("id", "?")))
	_ok("建造牌 3 / 训练牌 4 / 策略牌 3", build_n == 3 and train_n == 4 and strat_n == 3,
		"%d/%d/%d" % [build_n, train_n, strat_n])
	_ok("建造牌 Exhaust、训练/策略牌循环", exhaust_bad.is_empty(), ", ".join(exhaust_bad))

	var st: Dictionary = mdl.call("PlanningSelfTest",
		planning, JsonFile.read_dict(UNITS_JSON, {}), JsonFile.read_dict(COMBAT_JSON, {}))
	_ok("开局预设 1 基地 + 2 农场 + 1 兵营（共 4 座、有 base）",
		int(st.get("start_buildings", 0)) == 4 and bool(st.get("has_base", false)),
		"%d 座" % int(st.get("start_buildings", 0)))
	_ok("开局人口上限 32（基地 12 + 2 农场 ×10）", int(st.get("pop_cap", 0)) == 32, str(st.get("pop_cap", 0)))
	_ok("建造牌扣 CP、落空地建 1 星",
		bool(st.get("build_ok", false)) and int(st.get("buildings_after_build", 0)) == int(st.get("start_buildings", 0)) + 1
		and int(st.get("cp_after_build", 0)) < int(st.get("cp_start", 0)) and int(st.get("new_building_star", 0)) == 1,
		"CP %d→%d，建筑 %d 座，新建筑 %d 星" % [int(st.get("cp_start", 0)), int(st.get("cp_after_build", 0)), int(st.get("buildings_after_build", 0)), int(st.get("new_building_star", 0))])
	_ok("拖同名建筑 3 合 1 升满 3 星",
		bool(st.get("merge_1", false)) and bool(st.get("merge_2", false)) and int(st.get("merged_star", 0)) == 3,
		"%d 星 / 剩 %d 座兵营" % [int(st.get("merged_star", 0)), int(st.get("barracks_count", 0))])
	_ok("训练牌按 Tag 让全场同类建筑各产 1 队",
		int(st.get("train_produced", -1)) == int(st.get("train_expected", -2)) and int(st.get("train_expected", 0)) >= 2,
		"产 %d 队 / 应 %d 队" % [int(st.get("train_produced", -1)), int(st.get("train_expected", -2))])
	_ok("3 星兵营产出 3 星兵（星级传递）", int(st.get("star3_squads", 0)) >= 1, "%d 队" % int(st.get("star3_squads", 0)))
	_ok("训练占人口（人口 > 0 且不超上限）",
		int(st.get("pop_used", 0)) > 0 and int(st.get("pop_used", 0)) <= int(st.get("pop_cap_after", 0)),
		"%d/%d" % [int(st.get("pop_used", 0)), int(st.get("pop_cap_after", 0))])


func _check_level_data() -> void:
	var c := _content()
	if c.is_empty():
		return
	_ok("关卡数据校验（两轮各 60 秒）", _arr(c.get("level_errors", [])).is_empty(), _err_text(c.get("level_errors", [])))
	var levels := JsonFile.read_dict(LEVELS_JSON, {})
	var all_levels: Array = levels.get("levels", [])
	var level_ids: Array[String] = []
	for lv0 in all_levels:
		level_ids.append(String((lv0 as Dictionary).get("id", "")))
	_ok("第 1 关存在（手工蓝图）+ 组装关卡都已生成",
		level_ids.has("level_1") and all_levels.size() >= 4,
		"levels=%s" % str(level_ids))
	var lv: Dictionary = all_levels[0] if not all_levels.is_empty() else {}
	var rounds: Array = lv.get("rounds", [])
	var kinds: Array[String] = []
	for r in rounds:
		kinds.append(String(r.get("kind", "")))
	var wave_ok := true
	for r in rounds:
		if (r.get("enemy_waves", []) as Array).is_empty():
			wave_ok = false
	# 单场限时唯一真源 = LevelDef.RoundSecondsSpec = 60；反着验：每关都必须 60，
	# 且**没有任何波次时间越界**（90 秒时代留下的 t=70/76 会在这里红）。
	var spec60 := true
	var wave_late: Array[String] = []
	for lvx in all_levels:
		var lvd: Dictionary = lvx
		var rs := float(lvd.get("round_seconds", 0.0))
		if not is_equal_approx(rs, 60.0):
			spec60 = false
		for r in (lvd.get("rounds", []) as Array):
			for w in ((r as Dictionary).get("enemy_waves", []) as Array):
				if float((w as Dictionary).get("t", 0.0)) > rs + 1e-6:
					wave_late.append(String(lvd.get("id", "?")))
	_ok("第 1 关 = 进攻 60s + 防守 60s，且两轮都有波次",
		kinds == ["attack", "defend"] and is_equal_approx(float(lv.get("round_seconds", 0.0)), 60.0) and wave_ok,
		"%s / %.0fs" % [str(kinds), float(lv.get("round_seconds", 0.0))])
	_ok("全部关卡单场 60 秒，且没有波次时间越界（90 秒遗留会被抓出来）",
		spec60 and wave_late.is_empty(), "越界=%s" % str(wave_late))
	var lane: Dictionary = lv.get("lane", {})
	_ok("横道几何完整（长/宽/敌区/抽血）",
		float(lane.get("length", 0.0)) > float(lane.get("zone_depth", 0.0)) * 2.0 and float(lane.get("width", 0.0)) > 0.0 and float(lane.get("zone_dps_per_squad", 0.0)) > 0.0,
		"长 %.0f / 宽 %.0f / 敌区 %.0f / %.0f 血每秒" % [float(lane.get("length", 0.0)), float(lane.get("width", 0.0)), float(lane.get("zone_depth", 0.0)), float(lane.get("zone_dps_per_squad", 0.0))])
	var disabled := {}
	for r in _arr(c.get("unit_rows", [])):
		if not bool(r["enabled"]):
			disabled[String(r["id"])] = true
	var wave_bad: Array[String] = []
	for rd in rounds:
		for wave in rd.get("enemy_waves", []):
			for sq in wave.get("squads", []):
				var uid := String(sq.get("unit", ""))
				if disabled.has(uid):
					wave_bad.append(uid)
	_ok("波次不刷 enabled=false 的单位", wave_bad.is_empty(), ", ".join(wave_bad))

	var mdl := _mdl()
	if mdl != null:
		var u := JsonFile.read_dict(UNITS_JSON, {})
		var cb := JsonFile.read_dict(COMBAT_JSON, {})
		var pl := JsonFile.read_dict(PLANNING_JSON, {})
		var lv2 := JsonFile.read_dict(LEVELS_JSON, {})
		var a: Dictionary = mdl.call("LevelSimulate", u, cb, pl, lv2, LEVEL_ID, 2, 42)
		var b: Dictionary = mdl.call("LevelSimulate", u, cb, pl, lv2, LEVEL_ID, 2, 42)
		_ok("推演确定性：同 seed 两跑逐字节一致（含 samples/复盘）",
			JSON.stringify(a) == JSON.stringify(b))


## ===========================================================================
## **规划阶段视角与微操口径（2026-11-21）**
##
## 玩家口径：
##   ① 进规划阶段主相机自动锁定并聚焦**玩家区**（棋盘清晰居中），敌方情报改走顶部 UI 意图栏；
##   ② 单场 60 秒、预留 1x/2x 倍速；
##   ③ 微操只剩"选中我方小队 → 集火敌方小队"。
## 这里只验"接线是否真的接上"（函数/调用点/白名单），数值本身在各自分组里反着验。
func _check_planning_view() -> void:
	var main_src := _read("res://Game/core/主场景.gd")
	var cam_src := _read("res://Screens/camera/魔兽镜头.gd")
	var map_src := _read("res://Screens/hud/规划地图层.gd")
	var hud_src := _read("res://Screens/hud/HUD.gd")
	var bar_src := _read("res://Screens/hud/敌方意图条.gd")

	_ok("规划镜头：主场景优先调用 camera_points_player + lock_planning_rect（只框玩家区）",
		main_src.contains("camera_points_player") and main_src.contains("lock_planning_rect")
		and cam_src.contains("func lock_planning_rect") and cam_src.contains("_planning_lock"),
		"主场景/镜头缺规划取景锁")

	# 反着验：取景锁必须真的夹 _clamp_focus（否则只是存了个矩形没人用）
	var clamp_fn := _slice_fn(cam_src, "_clamp_focus")
	_ok("规划取景锁真的参与 _clamp_focus（存了不用的矩形会红）",
		clamp_fn.contains("_planning_lock") and clamp_fn.contains("clampf"), "缺 clamp")

	# 敌方意图：3D 层不再画敌方牌子；数据出口给意图栏
	var draw_intents := _slice_fn(map_src, "_draw_intents")
	_ok("规划 3D 层不再画敌方意图牌（只留我方/盟友），数据改由 enemy_intent_items() 输出",
		map_src.contains("func enemy_intent_items") and not draw_intents.contains("COL_ENEMY"))
	_ok("顶部 UI 意图栏：规划阶段也显示，且在 _place_planning_hud 里真的摆位",
		bar_src.contains("_planning_items") and bar_src.contains("enemy_intent_items")
		and _slice_fn(hud_src, "_place_planning_hud").contains("_foe_intent")
		and hud_src.contains("set_source"))

	# 60 秒唯一真源 + 倍速接口
	_ok("单场 60 秒在 Model 里有唯一真源，且全仓库不再出现 90 秒规格",
		_read("res://Model/Battle/LevelDef.cs").contains("RoundSecondsSpec = 60.0")
		and not _read("res://Content/data/levels.json").contains("\"round_seconds\": 90"))
	_ok("倍速接口留在 Model（SquadBattle.TimeScale，1x/2x），桥已转发",
		_read("res://Model/Squad/SquadBattle.cs").contains("TimeScaleMax = 2.0")
		and _read("res://Screens/bridge/ModelBridge.cs").contains("SquadSetTimeScale"))
	# 反着验：小队指挥里必须有"集火"入口，但**不许**再有 H 驻守 / S 停火 键位
	var cmd_src := _read("res://Screens/input/小队指挥.gd")
	_ok("玩家微操白名单只有 attack（Model 唯一实现，界面不自己判；H/S 键位已移除）",
		_read("res://Model/Squad/SquadBattle.cs").contains("IsPlayerMicroOrder")
		and cmd_src.contains("context_order_screen")
		and not cmd_src.contains("KEY_H:") and not cmd_src.contains("KEY_S:"))


## 真小队：编制闭环 / 战场装配 / 队级指令语义 / 脊线寻路 / 推演确定性
## ===========================================================================
func _check_squad() -> void:
	var mdl := _mdl()
	if mdl == null:
		_ok("小队：C# 桥可用", false, "ModelBridge 不可用")
		return

	var units := JsonFile.read_dict(UNITS_JSON, {})
	var combat := JsonFile.read_dict(COMBAT_JSON, {})
	var planning := JsonFile.read_dict(PLANNING_JSON, {})
	var levels := JsonFile.read_dict(LEVELS_JSON, {})
	var shells := JsonFile.read_dict(SHELLS_JSON, {})
	var layouts := JsonFile.read_dict(LAYOUTS_JSON, {})
	var encounters := JsonFile.read_dict(ENCOUNTERS_JSON, {})
	var tuning := JsonFile.read_dict("res://Content/data/squad.json", {})

	# ---- 1. 兵种编制闭环（阵型槽位 = squad_size，且贴合三位数小队半径）----
	var probe: Dictionary = mdl.call("SquadFormationProbe", units, combat)
	var bad: Array[String] = []
	var formations := {}
	var rows: Array = probe.get("rows", [])
	for row in rows:
		var r: Dictionary = row
		formations[String(r.get("formation", ""))] = true
		if int(r.get("slot_count", 0)) != int(r.get("squad_size", -1)) or not bool(r.get("fits", false)):
			bad.append(String(r.get("id", "")))
		var radius := float(r.get("squad_radius", 0.0))
		if radius < 100.0 or radius > 400.0:
			bad.append(String(r.get("id", "")) + ":radius")
	_ok("12 兵种小队编制闭环（槽位 = squad_size + 贴合三位数半径）", rows.size() == 12 and bad.is_empty(),
		"rows=%d / 问题=%s" % [rows.size(), ", ".join(bad)])
	_ok("阵型模板只出现 方阵/散阵/楔形",
		formations.has("square") and formations.has("scatter") and formations.has("wedge") and formations.size() <= 3,
		str(formations.keys()))

	var broken_units: Dictionary = units.duplicate(true)
	for u0 in broken_units.get("units", []):
		var u: Dictionary = u0
		if String(u.get("id", "")) == "alliance_footman":
			u["formation"] = "banana"
			u["squad_radius"] = 5.0
	var bad_probe: Dictionary = mdl.call("SquadFormationProbe", broken_units, combat)
	_ok("反向验错：非法阵型/过小半径必须被 Model 拒绝",
		not bool(bad_probe.get("ok", true)) and not _arr(bad_probe.get("errors", [])).is_empty(),
		_err_text(bad_probe.get("errors", [])))

	# ---- 2. 战场装配：脊线 / 格子 / 势力区 / 波次 ----
	var level := _find_row(levels, "levels", "level_asm_even_four__gnoll_press")
	var asm: Dictionary = level.get("assembly", {})
	var shell := _find_row(shells, "shells", String(asm.get("shell", "")))
	var layout := _find_row(layouts, "layouts", String(asm.get("player_layout", "")))
	var encounter := _find_row(encounters, "encounters", String(asm.get("enemy_encounter", "")))
	var arena_res: Dictionary = mdl.call("SquadArenaValidate", units, combat, level, shell, layout, encounter, tuning)
	_ok("小队战场装配校验（脊线/格子/势力区/波次）", bool(arena_res.get("ok", false)),
		_err_text(arena_res.get("errors", [])))
	_ok("底壳脊线点 >= 2，战术格子 12 个",
		int(arena_res.get("ridge_points", 0)) >= 2 and int(arena_res.get("tiles", 0)) == 12,
		"脊线 %d 点 / 格子 %d" % [int(arena_res.get("ridge_points", 0)), int(arena_res.get("tiles", 0))])
	_ok("小队模式抽血口径 > 0（squad.json 覆盖生效）",
		float(arena_res.get("zone_dps_per_squad", 0.0)) > 0.0,
		"%.0f 血/秒/队" % float(arena_res.get("zone_dps_per_squad", 0.0)))

	var broken_shell: Dictionary = shell.duplicate(true)
	var spine: Dictionary = broken_shell.get("spine", {})
	spine["points"] = []
	broken_shell["spine"] = spine
	var bad_arena: Dictionary = mdl.call("SquadArenaValidate", units, combat, level, broken_shell, layout, encounter, tuning)
	_ok("反向验错：没有脊线点的战场必须被拒",
		not bool(bad_arena.get("ok", true)) and not _arr(bad_arena.get("errors", [])).is_empty(),
		_err_text(bad_arena.get("errors", [])))

	# ---- 3. 会话：训练牌 → 格子中心整队；移动 / 驻守 / 点选 / 框选 / 集火 ----
	var session: Dictionary = mdl.call("SquadSessionNew", units, combat, planning, level, shell, layout, encounter, tuning, 123, true)
	if not bool(session.get("ok", false)):
		_ok("小队会话创建", false, _err_text(session.get("errors", [])))
		return
	_ok("小队会话创建（规划阶段）", true, "")
	var h := int(session.get("handle", 0))
	var info: Dictionary = session.get("arena", {})
	mdl.call("SquadSessionBeginPlanning", h)
	var st: Dictionary = mdl.call("SquadSessionState", h)
	_ok("规划：起手 CP=16 且训练牌可打",
		int(st.get("cp", 0)) == 16 and (st.get("train_cards", []) as Array).size() >= 4,
		"CP=%d / 牌=%d" % [int(st.get("cp", 0)), (st.get("train_cards", []) as Array).size()])

	var train: Dictionary = mdl.call("SquadSessionTrain", h, "train_footman")
	_ok("训练牌 → 整队在建筑格子中心瞬间生成", int(train.get("produced", 0)) == 1,
		"produced=%d" % int(train.get("produced", 0)))
	var view: Dictionary = mdl.call("SquadView", h)
	var squads: Array = view.get("squads", [])
	_ok("训练后只有 1 支小队（5 人整队，不是 5 个散兵）",
		squads.size() == 1 and int((squads[0] as Dictionary).get("member_count", 0)) == 5,
		"队=%d" % squads.size())
	var sq: Dictionary = squads[0]
	var anchor := _tile_anchor_of_building(info, "barracks")
	var spawn_dist := Vector2(float(sq.get("x", 0.0)) - anchor.x, float(sq.get("z", 0.0)) - anchor.y).length()
	_ok("出兵点 = SquadSpawnAnchor（误差 < 0.05m）", spawn_dist < 0.05, "%.3f m" % spawn_dist)

	var start_pos := Vector2(float(sq.get("x", 0.0)), float(sq.get("z", 0.0)))
	var target := start_pos + Vector2(12.0, 0.0)
	# **玩家侧被移除的指令**：move / hold / stop / attack_move 一律返回 0（反着验一遍）
	var player_move := int(mdl.call("SquadOrder", h, [int(sq.get("id", 0))], "move", target.x, target.y, -1))
	var player_hold := int(mdl.call("SquadOrder", h, [int(sq.get("id", 0))], "hold", 0.0, 0.0, -1))
	var player_stop := int(mdl.call("SquadOrder", h, [int(sq.get("id", 0))], "stop", 0.0, 0.0, -1))
	var player_am := int(mdl.call("SquadOrder", h, [int(sq.get("id", 0))], "attack_move", target.x, target.y, -1))
	_ok("微操收敛：玩家侧 move / hold / stop / attack_move 全被 Model 拒绝（只留集火）",
		player_move == 0 and player_hold == 0 and player_stop == 0 and player_am == 0
		and bool(mdl.call("SquadPlayerOrderAllowed", "attack")),
		"move=%d hold=%d stop=%d am=%d" % [player_move, player_hold, player_stop, player_am])
	# 推进本身仍然成立：走"预设偏好/AI"入口（SquadAutoOrder），寻路与移动逻辑不变
	var moved := int(mdl.call("SquadAutoOrder", h, [int(sq.get("id", 0))], "move", target.x, target.y, -1))
	for i in range(100):
		mdl.call("SquadStep", h, 0.05)
	view = mdl.call("SquadView", h)
	sq = (view.get("squads", []) as Array)[0]
	var moved_dist := Vector2(float(sq.get("x", 0.0)), float(sq.get("z", 0.0))).distance_to(start_pos)
	_ok("移动指令：整队质心真的走了（5s >= 3m）", moved == 1 and moved_dist >= 3.0,
		"%.2f m" % moved_dist)

	mdl.call("SquadAutoOrder", h, [int(sq.get("id", 0))], "hold", 0.0, 0.0, -1)
	var hold_pos := Vector2(float(sq.get("x", 0.0)), float(sq.get("z", 0.0)))
	for i in range(40):
		mdl.call("SquadStep", h, 0.05)
	view = mdl.call("SquadView", h)
	sq = (view.get("squads", []) as Array)[0]
	var drift := Vector2(float(sq.get("x", 0.0)), float(sq.get("z", 0.0))).distance_to(hold_pos)
	_ok("驻守指令：2s 内整队质心不动（< 0.15m）", drift < 0.15, "%.3f m" % drift)

	var picked := int(mdl.call("SquadPickWorld", h, float(sq.get("x", 0.0)), float(sq.get("z", 0.0)), 0, 0.6))
	_ok("点选：点小队成员 → 返回整队 id", picked == int(sq.get("id", 0)), "id=%d" % picked)
	var box: Array = mdl.call("SquadBoxWorld", h,
		float(sq.get("x", 0.0)) - 3.0, float(sq.get("z", 0.0)) - 3.0,
		float(sq.get("x", 0.0)) + 3.0, float(sq.get("z", 0.0)) + 3.0, 0)
	_ok("框选：整队质心在框内 → id 命中", box.has(int(sq.get("id", 0))), str(box))

	var enemy_id := int(mdl.call("SquadSpawn", h, 1, "bandit_marauder", 1,
		float(sq.get("x", 0.0)) + 6.0, float(sq.get("z", 0.0))))
	var attack_ok := int(mdl.call("SquadOrder", h, [int(sq.get("id", 0))], "attack",
		float(sq.get("x", 0.0)) + 6.0, float(sq.get("z", 0.0)), enemy_id))
	view = mdl.call("SquadView", h)
	sq = (view.get("squads", []) as Array)[0]
	_ok("集火：指令落到队级 target_squad（不是单兵目标）",
		attack_ok == 1 and int(sq.get("target_squad", -1)) == enemy_id,
		"target=%d" % int(sq.get("target_squad", -1)))
	# 倍速接口：1x/2x 夹取，越界一律收进 [1,2]（反着验）
	var ts2 := float(mdl.call("SquadSetTimeScale", h, 2.0))
	var ts_hi := float(mdl.call("SquadSetTimeScale", h, 9.0))
	var ts_lo := float(mdl.call("SquadSetTimeScale", h, 0.1))
	_ok("战斗倍速接口：2.0 生效，9.0 夹到 2.0，0.1 夹回 1.0",
		is_equal_approx(ts2, 2.0) and is_equal_approx(ts_hi, 2.0) and is_equal_approx(ts_lo, 1.0),
		"%.1f / %.1f / %.1f" % [ts2, ts_hi, ts_lo])

	# ---- 4. 脊线寻路：路径点 >= 3 且比直线长（走脊线，不抄斜线）----
	var far := Vector2(float(info.get("enemy_base_x", 0.0)), 0.0)
	var straight := Vector2(float(sq.get("x", 0.0)), float(sq.get("z", 0.0))).distance_to(far)
	mdl.call("SquadAutoOrder", h, [int(sq.get("id", 0))], "move", far.x, far.y, -1)
	var path: Dictionary = mdl.call("SquadDebugPath", h, int(sq.get("id", 0)))
	var pts: Array = path.get("points", [])
	var path_m := float(path.get("length_m", 0.0))
	_ok("脊线寻路：路径点 >= 3 且长度 > 直线（走廊约束生效）",
		pts.size() >= 3 and path_m > straight * 1.005,
		"点=%d / 路径=%.1fm / 直线=%.1fm" % [pts.size(), path_m, straight])

	# 建筑不阻挡寻路：RouteGraph 源码里不许出现格子/建筑
	var route_src := FileAccess.get_file_as_string("res://Model/Squad/RouteGraph.cs")
	_ok("寻路图不引用战术格子/建筑（建筑在战斗阶段不阻挡）",
		not route_src.contains("TacticalTile") and not route_src.contains("Building"), "源码层断言")
	mdl.call("SquadSessionFree", h)

	# ---- 5. 推演：2 局可跑 + 同 seed 确定性 + DPS 报告非空 ----
	var sim_a: Dictionary = mdl.call("SquadSimulate", units, combat, planning, levels, shells, layouts, encounters, tuning,
		"level_asm_even_four__gnoll_press", 2, 42)
	var sim_b: Dictionary = mdl.call("SquadSimulate", units, combat, planning, levels, shells, layouts, encounters, tuning,
		"level_asm_even_four__gnoll_press", 2, 42)
	_ok("小队推演：2 局可跑并返回胜率",
		bool(sim_a.get("ok", false)) and int(sim_a.get("games", 0)) == 2 and float(sim_a.get("win_rate", -1.0)) >= 0.0,
		"胜率 %.0f%%" % (float(sim_a.get("win_rate", 0.0)) * 100.0))
	_ok("小队推演确定性：同 seed 两跑逐字节一致", JSON.stringify(sim_a) == JSON.stringify(sim_b))
	_ok("DPS 报告非空（逐兵种 rows + 人均 DPS）",
		(sim_a.get("player_dps_rows", []) as Array).size() >= 1 and float(sim_a.get("avg_player_dps", -1.0)) >= 0.0,
		"%d 行 / %.2f DPS" % [(sim_a.get("player_dps_rows", []) as Array).size(), float(sim_a.get("avg_player_dps", 0.0))])
	_ok("阵型/寻路指标：槽位偏离 < 1m 且路径比 > 1",
		float(sim_a.get("avg_slot_error", 9.0)) < 1.0 and float(sim_a.get("avg_path_ratio", 0.0)) > 1.0,
		"槽位 %.2fm / 路径比 %.2f" % [float(sim_a.get("avg_slot_error", 0.0)), float(sim_a.get("avg_path_ratio", 0.0))])


func _find_row(doc: Dictionary, key: String, id: String) -> Dictionary:
	for row in doc.get(key, []):
		var d: Dictionary = row
		if String(d.get("id", "")) == id:
			return d
	return {}


func _tile_anchor_of_building(info: Dictionary, def_id: String) -> Vector2:
	for b in info.get("player_buildings", []):
		var row: Dictionary = b
		if String(row.get("building", "")) != def_id:
			continue
		for t in info.get("tiles", []):
			var tile: Dictionary = t
			if int(tile.get("index", 0)) == int(row.get("tile", 0)):
				return Vector2(float(tile.get("spawn_x", 0.0)), float(tile.get("spawn_z", 0.0)))
	return Vector2.ZERO


func _check_dev_editor() -> void:
	var problems: Array[String] = []
	# 1) 脚本 / 数据层 / 场景
	var scripts := ["dev_editor.gd", "dev_theme.gd", "dev_data.gd", "page_units.gd",
		"page_build.gd", "page_layouts.gd", "page_encounters.gd", "page_assembly.gd",
		"layout_canvas.gd", "shell_store.gd", "backdrop.gd", "logo.gd",
		"compare_bars.gd", "building_glyph.gd"]
	for f in scripts:
		if not FileAccess.file_exists("res://Screens/editor/" + f):
			problems.append("缺 " + f)
	if not FileAccess.file_exists("res://Screens/scenes/dev_editor.tscn"):
		problems.append("缺开发者编辑器场景")
	for f in ["res://addons/war_island_editor/plugin.cfg", "res://addons/war_island_editor/plugin.gd"]:
		if not FileAccess.file_exists(f):
			problems.append("缺 " + f)
	_ok("开发者编辑器框架齐全（主壳/主题/数据/五页/底壳画布/场景）", problems.is_empty(), "; ".join(problems))

	var data_script: Script = load("res://Screens/editor/dev_data.gd")
	var d: RefCounted = data_script.new()
	var loaded := bool(d.call("load_all"))
	_ok("开发者编辑器数据层可装载（units/combat/planning/levels/shells/layouts/encounters + ui.csv）", loaded,
		String(d.get("load_error")))

	var rows: Array = d.call("validate")
	var fails: Array[String] = []
	for r in rows:
		if not bool((r as Dictionary).get("ok", false)):
			fails.append("%s(%s)" % [String((r as Dictionary).get("key", "")), String((r as Dictionary).get("detail", ""))])
	_ok("开发者编辑器数据自检 12 项（单位/属性/建筑/卡组/底壳/脊线/战术格子/布局/遭遇/组装/模型/文案）",
		rows.size() == 12 and fails.is_empty(), "; ".join(fails))

	# 2) 12 兵种：模型路径或占位符 + 13 项攻防穿透
	var units := JsonFile.read_dict(UNITS_JSON, {})
	var uarr: Array = units.get("units", [])
	var bad_u: Array[String] = []
	for u in uarr:
		var ud: Dictionary = u
		var pp := String(ud.get("model_path", ""))
		if not bool(ud.get("use_placeholder_mesh", false)):
			if pp.is_empty() or not FileAccess.file_exists(pp):
				bad_u.append(String(ud.get("id", "")) + " model")
		for k in ["hp", "attack_damage", "attack_cooldown", "attack_range", "attack_type",
			"armor", "armor_type", "hit", "dodge", "crit",
			"armor_pen_flat", "armor_pen_pct", "move_speed"]:
			if not ud.has(k):
				bad_u.append(String(ud.get("id", "")) + " 缺 " + k)
	_ok("12 兵种都有模型绑定/占位符 + 13 项攻防穿透", uarr.size() == 12 and bad_u.is_empty(), "; ".join(bad_u.slice(0, 6)))

	# 3) 建筑：人口 / produce_tag / 三星产出 / 模型
	var plan := JsonFile.read_dict(PLANNING_JSON, {})
	var barr: Array = plan.get("buildings", [])
	var bad_b: Array[String] = []
	for b in barr:
		var bd: Dictionary = b
		if String(bd.get("produce_tag", "")).is_empty():
			bad_b.append(String(bd.get("id", "")) + " produce_tag")
		var stars: Array = bd.get("star_output", [])
		if stars.size() != 3:
			bad_b.append(String(bd.get("id", "")) + " star_output")
		var mp := String(bd.get("model_path", ""))
		if mp.is_empty() or not FileAccess.file_exists(mp):
			bad_b.append(String(bd.get("id", "")) + " model")
	_ok("建筑都有 pop / produce_tag / 1~3 星产出 / 3D 模型", barr.size() == 4 and bad_b.is_empty(), "; ".join(bad_b))

	# 4) 12 张初始卡组 + 卡牌存在 + 张数和为 12
	var deck: Array = (plan.get("deck", {}) as Dictionary).get("start", [])
	var card_ids := {}
	var count_sum := 0
	for c in plan.get("cards", []):
		card_ids[String((c as Dictionary).get("id", ""))] = true
		count_sum += int((c as Dictionary).get("count", 1))
	var bad_deck: Array[String] = []
	for id in deck:
		if not card_ids.has(String(id)):
			bad_deck.append(String(id))
	_ok("初始卡组正好 12 张且每张卡都存在（卡面张数和 = 12）",
		deck.size() == 12 and int((plan.get("deck", {}) as Dictionary).get("size", 0)) == 12 and count_sum == 12 and bad_deck.is_empty(),
		"deck=%d size=%d count=%d 缺失=%s" % [deck.size(), int((plan.get("deck", {}) as Dictionary).get("size", 0)), count_sum, ", ".join(bad_deck)])

	# 5) 底壳：12 个战术格子 / 左右各 1 主堡位 / 格间留缝 / 三块区域多边形
	var shells_doc := JsonFile.read_dict(SHELLS_JSON, {})
	var shell_arr: Array = shells_doc.get("shells", [])
	var shell0: Dictionary = shell_arr[0] if not shell_arr.is_empty() else {}
	var tile_rows: Array = shell0.get("tiles", [])
	var keeps := {"player": 0, "enemy": 0}
	var pbad: Array[String] = []
	for p in tile_rows:
		var td: Dictionary = p
		if String(td.get("role", "")) == "keep":
			keeps[String(td.get("side", "player"))] = int(keeps.get(String(td.get("side", "player")), 0)) + 1
		if float(td.get("w", 0.0)) < 2.0 or float(td.get("d", 0.0)) < 2.0:
			pbad.append("T" + str(td.get("index", 0)) + " 尺寸过小")
	var gap := float(d.call("min_gap_meters"))
	_ok("底壳：12 个战术格子 + 左右各 1 主堡位 + 格间自然间隙 >= 1.0m",
		tile_rows.size() == 12 and int(keeps["player"]) == 1 and int(keeps["enemy"]) == 1
		and pbad.is_empty() and gap >= SHELL_STORE.MIN_GAP_M,
		"tiles=%d keeps=%s gap=%.2fm %s" % [tile_rows.size(), str(keeps), gap, ", ".join(pbad)])

	var spine: Dictionary = shell0.get("spine", {})
	var width_logic := float(spine.get("width_logic", 0.0))
	var regions: Dictionary = shell0.get("regions", {})
	_ok("通道宽度三位数 + 赛道分割环已下线（分区改由三块多边形区域负责）",
		width_logic >= 100.0 and width_logic <= 999.0 and not spine.has("dividers")
		and regions.size() == 3,
		"width=%.0f dividers=%s regions=%d" % [width_logic, str(spine.has("dividers")), regions.size()])

	# 区域多边形：三个 kind 都 >= 3 顶点；中心点必须落在中立区（Point-in-Polygon 走 Model）
	var region_bad: Array[String] = []
	for kind in ["player", "neutral", "enemy"]:
		var pts0 := SHELL_STORE.region_points(shell0, kind)
		if pts0.size() < 3:
			region_bad.append(kind + "<3")
	if not SHELL_STORE.region_contains(SHELL_STORE.region_points(shell0, "neutral"), 0.0, 0.0):
		region_bad.append("neutral@origin")
	_ok("势力区域：三块多边形（>=3 顶点）+ 中心点判定落在中立区（Model 的 Point-in-Polygon）",
		region_bad.is_empty(), ", ".join(region_bad))

	var grid := SHELL_STORE.grid_of(shell0)
	var heights_arr: Array = (shell0.get("terrain", {}) as Dictionary).get("heights", [])
	var palette_arr: Array = (shell0.get("surface", {}) as Dictionary).get("palette", [])
	_ok("地形高度场与地表槽位齐全（%d 格，4 种材质）" % heights_arr.size(),
		heights_arr.size() == int(grid["cols"]) * int(grid["rows"]) and palette_arr.size() == 4,
		"grid=%dx%d heights=%d" % [int(grid["cols"]), int(grid["rows"]), heights_arr.size()])

	# 6) 玩家态势布局卡
	var layouts_doc := JsonFile.read_dict(LAYOUTS_JSON, {})
	var lay_bad: Array[String] = []
	var even_default := false
	for l in (layouts_doc.get("layouts", []) as Array):
		var ld: Dictionary = l
		var kind := String(ld.get("kind", ""))
		if not (kind in ["even", "disadvantage", "advantage"]):
			lay_bad.append("kind=" + kind)
		var shell_of := d.call("shell_by_id", String(ld.get("shell", ""))) as Dictionary
		for idx in (ld.get("active_tiles", []) as Array):
			if SHELL_STORE.tile_by_index(shell_of, int(idx)).is_empty():
				lay_bad.append("tile " + str(idx))
		var counts: Dictionary = d.call("layout_counts", ld)
		if int(counts.get("base", 0)) != 1:
			lay_bad.append(String(ld.get("id", "")) + " keep")
		if kind == "even" and int(counts.get("farm", 0)) == 2 and int(counts.get("barracks", 0)) == 1:
			even_default = true
		if String(ld.get("inactive_render", "")) != "ruin":
			lay_bad.append(String(ld.get("id", "")) + " ruin")
	_ok("玩家布局卡：3 种态势 + 激活格子真实存在 + 每卡 1 主堡 + 平势默认 1 主堡 2 农场 1 兵营 + 未激活即遗迹",
		(layouts_doc.get("kinds", []) as Array).size() == 3 and even_default and lay_bad.is_empty(),
		"; ".join(lay_bad.slice(0, 4)))

	# 7) 敌人遭遇卡 + 组装闭环
	var enc_doc := JsonFile.read_dict(ENCOUNTERS_JSON, {})
	var faction_names := {}
	for f in (enc_doc.get("factions", []) as Array):
		faction_names[String((f as Dictionary).get("id", ""))] = String((f as Dictionary).get("display_name", ""))
	var enc_bad: Array[String] = []
	for e in (enc_doc.get("encounters", []) as Array):
		var ed: Dictionary = e
		var fac := String(ed.get("faction", ""))
		if not faction_names.has(fac):
			enc_bad.append(String(ed.get("id", "")) + " faction")
		var sums: Vector2 = d.call("intent_sums", ed)
		if absf(sums.x - 100.0) > 0.001 or absf(sums.y - 100.0) > 0.001:
			enc_bad.append(String(ed.get("id", "")) + " intents")
		var shell_e := d.call("shell_by_id", String(ed.get("shell", ""))) as Dictionary
		for row in (ed.get("tile_buildings", []) as Array):
			var bd2: Dictionary = row
			var pd2 := SHELL_STORE.tile_by_index(shell_e, int(bd2.get("tile", -1)))
			if pd2.is_empty() or String(pd2.get("side", "")) != "enemy":
				enc_bad.append(String(ed.get("id", "")) + " tile")
			if (d.call("building_by_id", String(bd2.get("building", ""))) as Dictionary).is_empty():
				enc_bad.append(String(ed.get("id", "")) + " building")
	_ok("敌人遭遇卡：豺狼人/鱼人两阵营 + 敌方格子固定建筑 + 攻防意图池两列各 100",
		String(faction_names.get("bandit", "")) == "豺狼人" and String(faction_names.get("murloc", "")) == "鱼人"
		and (enc_doc.get("encounters", []) as Array).size() >= 2 and enc_bad.is_empty(),
		"; ".join(enc_bad.slice(0, 4)))

	var levels := JsonFile.read_dict(LEVELS_JSON, {})
	var asm_list: Array = levels.get("assemblies", [])
	var asm_bad: Array[String] = []
	for a in asm_list:
		var ad: Dictionary = a
		var lvx := d.call("level_by_id", String(ad.get("level", ""))) as Dictionary
		if lvx.is_empty():
			asm_bad.append(String(ad.get("id", "")) + " level")
		elif (lvx.get("rounds", []) as Array).size() != 2:
			asm_bad.append(String(ad.get("id", "")) + " rounds")
	_ok("战斗节点组装：[底壳 × 布局卡 × 遭遇卡] 引用闭环且关卡已生成",
		asm_list.size() >= 3 and asm_bad.is_empty(), "assemblies=%d %s" % [asm_list.size(), ", ".join(asm_bad)])

	var state_bad: Array[String] = []
	var state_info: Array[String] = []
	for a_row in asm_list:
		var lid0 := String((a_row as Dictionary).get("level", ""))
		var lay0: Dictionary = ASSEMBLY_API.layout(String((a_row as Dictionary).get("player_layout", "")))
		var active0 := int((lay0.get("active_tiles", []) as Array).size())
		var build0: Array = ASSEMBLY_API.buildable_tiles(lid0)
		var ruin0: Array = ASSEMBLY_API.ruin_tiles(lid0)
		var player_build := 0
		for b0 in build0:
			if String((b0 as Dictionary).get("side", "")) == "player":
				player_build += 1
		if player_build != active0:
			state_bad.append(lid0 + " buildable=%d != active=%d" % [player_build, active0])
		for r0 in ruin0:
			if int((r0 as Dictionary).get("index", 0)) <= 0:
				state_bad.append(lid0 + " ruin index")
		state_info.append("%s 可建%d/遗迹%d" % [lid0.trim_prefix("level_asm_"), build0.size(), ruin0.size()])
	_ok("局内格子状态：布局卡未激活 = 碎石遗迹（不可建造），激活 = 可建造",
		asm_list.is_empty() == false and state_bad.is_empty(), ", ".join(state_info + state_bad.slice(0, 2)))

	var mdl := _mdl()
	if mdl != null and not asm_list.is_empty():
		var sim_ok := true
		var sim_info: Array[String] = []
		for i in mini(asm_list.size(), 3):
			var lid := String((asm_list[i] as Dictionary).get("level", ""))
			var games := 50 if i == 0 else 3
			var res: Dictionary = mdl.call("LevelSimulate", JsonFile.read_dict(UNITS_JSON, {}),
				JsonFile.read_dict(COMBAT_JSON, {}), plan, levels, lid, games, 7)
			var rate := float(res.get("win_rate", -1.0))
			if not bool(res.get("ok", false)) or rate < 0.0 or rate > 1.0:
				sim_ok = false
			sim_info.append("%s:%d局 %.0f%%" % [lid.trim_prefix("level_asm_"), int(res.get("games", 0)), rate * 100.0])
		_ok("组装关卡可跑 --simulate（首个组合 50 局 + 其余各 3 局）", sim_ok, ", ".join(sim_info))
		var sim_src := _read("res://Tests/sim/run_simulate.gd")
		_ok("run_simulate 支持 --level= 与 --out=（组装页靠 --out 拿胜率）",
			sim_src.contains("--level=") and sim_src.contains("--out="))

	# 8) 文案 / 源码硬编码 / 截图登记 / 发行排除
	var i18n := root.get_node_or_null("I18n")
	var need_keys := ["editor.app.title", "editor.tab.units", "editor.dps.final",
		"editor.cards.deck", "editor.tab.layouts", "editor.tab.encounters",
		"editor.tab.assembly", "editor.assembly.sim_run", "unit.alliance_footman",
		"building.keep", "card.build_farm", "shell.tool.terrain", "shell.tool.decor",
		"shell.tool.spine", "shell.tool.tile", "shell.tile.role_keep",
		"shell.region.player", "shell.decor.fence"]
	var lack_keys: Array[String] = []
	for k in need_keys:
		if i18n == null or not bool(i18n.call("has", k)):
			lack_keys.append(k)
	_ok("ui.csv 含编辑器框架 key 与三条术语表", lack_keys.is_empty(), ", ".join(lack_keys))

	var hard := 0
	var hard_files: Array = _walk("res://Screens/editor")
	hard_files.append("res://addons/war_island_editor/plugin.gd")
	hard_files.append("res://addons/map_shell_editor/plugin.gd")
	for f in hard_files:
		if f.ends_with(".gd"):
			hard += _count_cjk_literals(_read(f))
	_ok("编辑器源码零写死中文（连路径都用 ASCII）", hard == 0, "实测 %d 处" % hard)

	var screens := JsonFile.read_dict(SCREENS, {})
	var screen_map: Dictionary = screens.get("screens", {})
	var screen_bad: Array[String] = []
	for name in ["editor", "editor_layouts", "editor_encounters", "editor_assembly", "shell"]:
		var r: Dictionary = screen_map.get(name, {})
		var has_assert: bool = r.has("expect") or r.has("expect_scene_state")
		if r.is_empty() or not FileAccess.file_exists(String(r.get("scene", ""))) or (r.has("click") and not has_assert):
			screen_bad.append(name)
	_ok("截图画面 editor / editor_layouts / editor_encounters / editor_assembly / shell 都登记了 click+expect",
		screen_bad.is_empty(), ", ".join(screen_bad))

	var proj := _read("res://project.godot")
	_ok("Godot 主屏启用开发者编辑器 + 3D 地图底壳编辑器（旧地图编辑器已移除）",
		proj.contains("addons/war_island_editor/plugin.cfg")
		and proj.contains("addons/map_shell_editor/plugin.cfg")
		and not proj.contains("addons/map_editor/plugin.cfg"),
		"dev=" + str(proj.contains("addons/war_island_editor/plugin.cfg"))
		+ " shell=" + str(proj.contains("addons/map_shell_editor/plugin.cfg"))
		+ " old=" + str(proj.contains("addons/map_editor/plugin.cfg")))

	var rel := _read("res://Tools/build/release_exclude.txt")
	_ok("发行排除清单含开发者编辑器（Screens/editor）与编辑器插件（addons）",
		rel.contains("Screens/editor") and rel.contains("addons"))


## 资产清单：Content/docs/asset_manifest.md 里登记的每条 res:// 路径都必须真实存在。
## 这是"编辑器只准用已有资产"的第一道门禁（第二道在 _check_map_shell 的装饰注册表）。
func _check_asset_manifest() -> void:
	var src := _read("res://Content/docs/asset_manifest.md")
	if src.is_empty():
		_ok("资产清单 Content/docs/asset_manifest.md 存在", false, "缺文件")
		return
	var re := RegEx.new()
	re.compile("res://[^\\s`|）)\\]]+")
	var checked := 0
	var bad: Array[String] = []
	for m in re.search_all(src):
		var path := m.get_string(0).strip_edges()
		while path.ends_with(".") or path.ends_with(",") or path.ends_with(";"):
			path = path.substr(0, path.length() - 1)
		if path.ends_with("/") or path.ends_with("..."):
			continue
		checked += 1
		if not FileAccess.file_exists(path):
			bad.append(path)
	_ok("资产清单里的路径都真实存在（%d 条）" % checked, checked >= 20 and bad.is_empty(), ", ".join(bad.slice(0, 4)))
	_ok("资产清单覆盖树 / 地形材质 / 棋盘皮肤 / 着色器 / UI 主题（水已整层删除、清单里不许再出现水材质）",
		src.contains("树_场景.tscn") and src.contains("地形材质.tres")
		and src.contains("棋盘格子A.tres") and src.contains("地块侧面.tres")
		and src.contains("地形.gdshader") and src.contains("游戏主题.tres")
		and not src.contains("水材质.tres"))


func _check_map_shell() -> void:
	var files := [
		"res://addons/map_shell_editor/plugin.cfg",
		"res://addons/map_shell_editor/plugin.gd",
		"res://Screens/editor/map_shell/map_shell_editor.tscn",
		"res://Screens/editor/map_shell/map_shell_editor.gd",
		"res://Screens/editor/map_shell/shell_view.gd",
		"res://Screens/editor/map_shell/shell_theme.gd",
		"res://Screens/editor/map_shell/shell_text.gd",
		"res://Screens/editor/map_shell/box_overlay.gd",
		"res://Screens/editor/shell_store.gd",
		"res://Content/data/shell_decor.json",
		"res://Content/docs/asset_manifest.md",
	]
	var lack: Array[String] = []
	for f in files:
		if not FileAccess.file_exists(f):
			lack.append(f.get_file())
	_ok("3D 地图底壳编辑器（MapShellEditor）文件齐全：插件 + 场景 + 主屏 + 视口 + 框选层 + 数据层 + 装饰注册表 + 资产清单",
		lack.is_empty(), ", ".join(lack))

	var old_editor := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://addons/map_editor"))
	_ok("旧 3D 地图编辑器已移除（摆兵种 / 触发器 / A* 涂抹 / 经济面板整块下线）", not old_editor,
		"addons/map_editor 还在" if old_editor else "addons/map_editor 已删")

	var editor_src := _read("res://Screens/editor/map_shell/map_shell_editor.gd")
	var view_src := _read("res://Screens/editor/map_shell/shell_view.gd")
	var store_src := _read("res://Screens/editor/shell_store.gd")
	var tools_ok := true
	var tools_hit: Array[String] = []
	for t in ["terrain", "decor", "spine", "tile"]:
		if editor_src.contains("shell.tool." + t) and editor_src.contains("shell_tool_"):
			tools_hit.append(t)
		else:
			tools_ok = false
	for fn_key in ["_apply_brush", "add_decor", "set_spine_width", "add_tile",
			"_build_regions", "_finish_box_select", "_rebuild_selection_rings"]:
		if not view_src.contains(fn_key):
			tools_ok = false
	_ok("底壳编辑器只保留 4 个纯视觉/空间划分工具（地形笔刷 / 装饰 / 脊线 / 战术格子）+ 区域绘制 + 框选",
		tools_ok, ", ".join(tools_hit))

	# 镜头口径继承：俯角 50° / 12m 起 / 右键平移方向 / 中键旋转 / WASD / 边界夹取
	# 2026-11-21 起**上限不再写死**：地图可扩到 400m，相机必须能跟着画布拉远，
	# 所以断言"有 dist_max() 这个唯一出口"，数值本身在下面用 Model 反着验。
	var camera_ok := view_src.contains("CAM_PITCH_DEG := 50.0") \
		and view_src.contains("CAM_DIST_MIN := 12.0") \
		and view_src.contains("func dist_max()") \
		and view_src.contains("ShellStore.camera_dist_max_of") \
		and view_src.contains("0.0016 * cam_dist") \
		and view_src.contains("_clamp_target") \
		and view_src.contains("rad_to_deg(0.006)") \
		and view_src.contains("KEY_W") and view_src.contains("KEY_Q") \
		and not view_src.contains("clampf(cam_dist * 0.88, CAM_DIST_MIN, CAM_DIST_MAX)")
	_ok("底壳编辑器继承旧地图编辑器镜头口径（俯角 50 / 12m 起 / 右键平移 / 中键旋转 / WASD·QE）",
		camera_ok, "shell_view.gd 镜头常量或键位缺失")

	# 地形材质：必须是游戏里那一份 地形材质.tres + 草泥图集 + 草/泥/裂纹泥地底材。
	# 路径收敛在 RtsTerrain 常量里（编辑器不写第二份资源路径）。
	var terrain_ok := view_src.contains("RtsTerrain.MATERIAL_PATH") \
		and view_src.contains("RtsTerrain.ATLAS_PATH") \
		and view_src.contains("RtsTerrain.TEX_GRASS_PATH") and view_src.contains("RtsTerrain.TEX_DIRT_PATH") \
		and view_src.contains("RtsTerrain.TEX_CRACKED_PATH") and view_src.contains("_build_surface_decals") \
		and _read("res://Game/map/地形.gd").contains("atlas_草泥_rgba.png")
	_ok("底壳地形沿用游戏地形材质与原始贴图（草泥图集 / 草 / 泥 / 裂纹泥地，不自创配色）",
		terrain_ok, "地形材质或贴图路径缺失")

	# 装饰：只实例化登记过的现有资产；_make_decor_node 里不许现拼圆柱/球体。
	var decor_fn := _slice_fn(view_src, "_make_decor_node")
	var decor_rows: Array = JsonFile.read_dict("res://Content/data/shell_decor.json", {}).get("kinds", [])
	var decor_bad: Array[String] = []
	for row in decor_rows:
		var rd: Dictionary = row
		var rp := String(rd.get("path", ""))
		if not FileAccess.file_exists(rp):
			decor_bad.append(String(rd.get("id", "?")) + " → " + rp)
	_ok("底壳装饰 = 现有资产（RtsDecorLib 场景 / 登记 GLB），不现拼占位网格；注册表每条路径都真实存在",
		view_src.contains("DECOR_LIB_PATH") and view_src.contains("_decor_lib_script")
		and view_src.contains("lib.call(\"instantiate\"")
		and not decor_fn.contains("CylinderMesh") and not decor_fn.contains("SphereMesh")
		and decor_rows.size() >= 12 and decor_bad.is_empty(),
		"%d 种%s" % [decor_rows.size(), "" if decor_bad.is_empty() else " / " + ", ".join(decor_bad.slice(0, 3))])

	# 选中高亮圈：必须复用局内那一个资产，且只在选中时挂出来。
	var ring_ok := view_src.contains("SEL_RING_PATH") and view_src.contains("_sel_ring_scene") \
		and view_src.contains("_rebuild_selection_rings") \
		and view_src.contains("selection_root") \
		and not view_src.contains("TorusMesh")
	_ok("选中对象脚下显示 3D 高亮圈（复用 Content/art/特效/选中圈.tscn；未选中不常驻）",
		ring_ok, "SEL_RING_PATH + selection_root + 无 TorusMesh")

	# 区域绘制 + 框选 + 撤销
	var interact_ok := editor_src.contains("shell_region_") and editor_src.contains("REGION_IDS") \
		and editor_src.contains("shell_undo") \
		and view_src.contains("func begin_region") and view_src.contains("func finish_region") \
		and view_src.contains("func cancel_region") and view_src.contains("add_region_vertex") \
		and view_src.contains("KEY_ENTER") and view_src.contains("KEY_ESCAPE") \
		and view_src.contains("func undo") and view_src.contains("KEY_Z") \
		and view_src.contains("func _finish_box_select")
	_ok("区域绘制（三按钮 + 顶点模式 + 回车闭合 + 右键/Esc 取消）+ 框选 + Delete 删除 + Ctrl+Z 撤销",
		interact_ok, "区域三按钮 + 顶点/闭合/取消 + 框选 + Ctrl+Z")

	# 旧石台 / 赛道分割环：代码里不许再出现
	var stale: Array[String] = []
	for bad in ["platforms", "DIVIDER_IDS", "sorted_dividers", "divider_of"]:
		if editor_src.contains(bad) or view_src.contains(bad) or store_src.contains(bad):
			stale.append(bad)
	_ok("旧「候选石台 / 赛道分割环」代码已清空（只剩 tiles + regions）", stale.is_empty(), ", ".join(stale))

	var forbidden: Array[String] = []
	for bad in ["spawn_unit", "add_unit", "trigger", "AStar", "Pathfinder", "economy", "resource_node"]:
		if editor_src.contains(bad) or view_src.contains(bad):
			forbidden.append(bad)
	_ok("底壳编辑器源码不含摆兵种 / 触发器 / A* 寻路 / 经济入口", forbidden.is_empty(), ", ".join(forbidden))

	var shell_src := _read("res://Screens/editor/map_shell/shell_theme.gd")
	_ok("底壳编辑器主题：深岩灰 #12161F + 保留旧地图编辑器嵌入色（石色 / 金色）",
		shell_src.contains("#12161F") and shell_src.contains("LEGACY_GOLD") and shell_src.contains("STONE"))

	var allowed := ["id", "display_name", "biome", "size", "seed", "terrain", "surface",
		"spine", "regions", "tiles", "decorations", "note", "board"]
	var extra: Array[String] = []
	for s in (shells_doc_again() as Array):
		for k in (s as Dictionary).keys():
			if not (String(k) in allowed):
				extra.append(String(k))
	_ok("底壳资产是纯净底壳：只有地形/地表/脊线/三块区域/战术格子/装饰（无兵种/触发器/波次/经济字段）",
		extra.is_empty(), ", ".join(extra))

	# ── 立体地块 / 画布冗余 / 可换皮皮肤表 ──────────────────────────────
	var skin := JsonFile.read_dict("res://Content/data/shell_board.json", {})
	var skin_mats: Dictionary = skin.get("materials", {})
	var skin_bad: Array[String] = []
	for sk in ["tile_a", "tile_b", "rim", "block_side", "block_bottom"]:
		var sp := String(skin_mats.get(sk, ""))
		if sp.is_empty() or not FileAccess.file_exists(sp):
			skin_bad.append(sk)
	var board_rows: Array = (shells_doc_again() as Array)
	var no_board: Array[String] = []
	for s in board_rows:
		var bd: Variant = (s as Dictionary).get("board", null)
		if not (bd is Dictionary) or float((bd as Dictionary).get("depth", 0.0)) <= 0.0:
			no_board.append(String((s as Dictionary).get("id", "?")))
	_ok("立体地块参数齐全（每张底壳都有 board.depth > 0；皮肤表 5 个 .tres 都存在）",
		skin_bad.is_empty() and no_board.is_empty(),
		"皮肤缺:%s / 缺厚度:%s" % [", ".join(skin_bad), ", ".join(no_board)])
	# 反向验错：厚度 0 / 冗余 0.3 / 倍率 3.0 必须被 Model 拒绝
	var board_bad: int = (mdl_board_errors(0.0, 0.30, 3.0) as Array).size() \
		+ (mdl_board_errors(6.0, 0.30, 1.0) as Array).size() \
		+ (mdl_board_errors(6.0, 0.45, 3.0) as Array).size()
	var board_ok_n: int = (mdl_board_errors(6.0, 0.45, 1.0) as Array).size()
	_ok("反向验错：厚度 0 / 冗余 30% / 倍率 3.0 都被 Model 拒绝，6m+45%+1.0x 通过",
		board_bad >= 3 and board_ok_n == 0, "拒绝=%d 合法=%d" % [board_bad, board_ok_n])
	# 相机距离必须随画布放大（不许写死）
	var d_small := float(_mdl().call("MapCameraDistMax", 200.0, 200.0))
	var d_big := float(_mdl().call("MapCameraDistMax", 1100.0, 1100.0))
	_ok("相机上限随画布放大（小图 ≥200m，扩容后显著更长；写死 200 会红）",
		d_small >= 199.0 and d_big > d_small * 2.5, "%.0f / %.0f" % [d_small, d_big])

	# ── Model 反向验错：区域顶点不足 3 个必须被拒；3 个必须过 ──
	var mdl := _mdl()
	if mdl == null:
		_ok("Model 桥可实例化（区域/格子校验的前置）", false, "bridge=null")
		return
	var pts2: Array = [Vector2(0.0, 0.0), Vector2(10.0, 0.0)]
	var pts3: Array = [Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(10.0, 10.0)]
	var err2: Array = mdl.call("RegionValidate", "player", pts2) as Array
	var err3: Array = mdl.call("RegionValidate", "player", pts3) as Array
	_ok("反向验错：区域多边形顶点 < 3 个必须被 Model 拒绝（2 点报错 / 3 点通过）",
		not err2.is_empty() and err3.is_empty(),
		"2点=%s / 3点=%s" % [str(err2), str(err3)])
	_ok("Player-in-Polygon：三角形内 (1,1) 判内、外 (20,20) 判外",
		bool(mdl.call("RegionContains", pts3, 1.0, 1.0)) and not bool(mdl.call("RegionContains", pts3, 20.0, 20.0)))

	# ── 战术格子锚点：10×10 → 建筑位左上角 (-5,-5)，出兵位中心 (0,0) ──
	var anc: Dictionary = mdl.call("TileAnchors", {
		"index": 1, "x": 0.0, "z": 0.0, "w": 10.0, "d": 10.0, "yaw": 0.0,
	}) as Dictionary
	var anchor_ok := is_equal_approx(float(anc.get("building_x", 99.0)), -5.0) \
		and is_equal_approx(float(anc.get("building_z", 99.0)), -5.0) \
		and is_equal_approx(float(anc.get("spawn_x", 99.0)), 0.0) \
		and is_equal_approx(float(anc.get("spawn_z", 99.0)), 0.0)
	_ok("战术格子锚点：建筑位 = 左上角 (-5,-5)，出兵位 = 正中心 (0,0)", anchor_ok, str(anc))

	# ── 反向验错：两个重叠格子必须被 Model 拒绝；默认一组必须过 ──
	var bad_tiles: Array = [
		{"index": 1, "side": "player", "role": "build", "x": 0.0, "z": 0.0, "w": 8.0, "d": 8.0, "yaw": 0.0, "terrain_y": 0.0},
		{"index": 2, "side": "player", "role": "build", "x": 1.0, "z": 0.0, "w": 8.0, "d": 8.0, "yaw": 0.0, "terrain_y": 0.0},
	]
	var overlap_err: Array = mdl.call("TileValidate", bad_tiles, 120.0, 63.0, 1.0) as Array
	var defaults: Array = mdl.call("TileDefaults", 120.0, 63.0) as Array
	var default_err: Array = mdl.call("TileValidate", defaults, 120.0, 63.0, 1.0) as Array
	_ok("反向验错：重叠 / 间距不足的战术格子必须被 Model 拒绝；默认一组格子必须合法",
		not overlap_err.is_empty() and default_err.is_empty(),
		"重叠=%d 条 / 默认=%s" % [overlap_err.size(), str(default_err)])


## 取一段函数源码（从 `func name(` 到下一个 `func `），用于"这个函数里不许出现 X"这类断言。
func _slice_fn(src: String, name: String) -> String:
	var start := src.find("func " + name + "(")
	if start < 0:
		return ""
	var end := src.find("\nfunc ", start + 6)
	return src.substr(start, end - start) if end > start else src.substr(start)


func shells_doc_again() -> Array:
	return JsonFile.read_dict(SHELLS_JSON, {}).get("shells", [])


func _check_r1_config() -> void:
	var c := _content()
	if c.is_empty():
		return
	var mdl := _mdl()
	var kernel_r1: float = float(mdl.call("R1")) if mdl != null else -1.0
	_ok("R1 配置完整（combat.json 声明 == 内核 R1 = 0.015）",
		is_equal_approx(float(c.get("r1", 0.0)), kernel_r1) and is_equal_approx(kernel_r1, 0.015),
		"json=%.4f / 内核=%.4f" % [float(c.get("r1", 0.0)), kernel_r1])
	_ok("战斗规格常数（护甲 0.06 / 负甲 3 倍 / 暴击 2 倍）",
		is_equal_approx(float(c.get("armor_scale", 0.0)), 0.06)
		and is_equal_approx(float(c.get("negative_armor_cap", 0.0)), 3.0)
		and is_equal_approx(float(c.get("crit_multiplier", 0.0)), 2.0))

	var rows: Array = _arr(c.get("unit_rows", []))
	var bad: Array[String] = []
	for r in rows:
		var rg := float(r["range"])
		if rg < 10.0 or rg > 2000.0 or absf(rg - roundf(rg)) > 0.000001:
			bad.append("%s=%.1f" % [r["id"], rg])
	_ok("12 兵种射程都是整数游戏数值（10..2000）", bad.is_empty(), ", ".join(bad))

	var by_id := {}
	for r in rows:
		by_id[String(r["id"])] = r
	var foot: Dictionary = by_id.get("alliance_footman", {})
	var pike: Dictionary = by_id.get("alliance_pikeman", {})
	var geometry := 0.0
	if not foot.is_empty() and not pike.is_empty():
		geometry = (float(pike["range"]) - float(foot["range"])) - (float(foot["body_radius"]) + float(pike["body_radius"])) / 0.015
	_ok("隔排几何：155 - 95 = (0.45+0.45)/0.015 = 60（长枪刚好在步兵身后）",
		not foot.is_empty() and not pike.is_empty() and absf(geometry) < 0.000001,
		"差 %.6f 游戏数值" % geometry)
	_ok("射程 650 → 9.75 米（走 射程基准，不写第二份 0.015）",
		is_equal_approx(float(load("res://Game/config/射程基准.gd").call("米", 650.0)), 9.75))


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
	var dirs := ["Game", "Screens", "Model", "Engine", "Tests", "Tools", "Content/data",
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
		and _read("res://Screens/hud/命令卡.gd").contains("可用性查询")
		and _read("res://Screens/input/指令系统.gd").contains("可用性查询"))
	_ok("建筑/命令卡/指令系统走同一套可用性判断", src_ok)


## 音效：合成器就绪 + 游戏侧真的走合成映射（不是只放了个模块没人用）
func _check_audio() -> void:
	var svc := root.get_node_or_null("AudioSvc")
	if svc == null:
		_ok("AudioSvc 自动加载就绪", false)
		return
	var st: Dictionary = svc.call("synth_stats")
	# 2026-11-14：全局只剩一条音效（UI 更新提示音"叮"），其余按玩家要求整批删除。
	_ok("合成音效器只有 1 个预设（ui_ding）", int(st.get("presets", 0)) == 1,
		"presets=%d" % int(st.get("presets", 0)))
	_ok("提示音可被 AudioSvc 接受（未知 key 拒绝）",
		bool(svc.call("play_synth", "ui_ding")) and not bool(svc.call("play_synth", "no_such_key")))
	var src := _read("res://Game/audio/音效管理.gd")
	_ok("UI 提示音走 AudioStreamGenerator（音效不依赖文件）",
		src.contains("ui_ding") and src.contains("play_synth") and not src.contains("SYNTH_KEYS"))
	var no_wav := true
	for f in _walk("res://Content/audio"):
		if String(f).get_extension().to_lower() == "wav":
			no_wav = false
			break
	_ok("音效 wav 已全部删除（只留 BGM）", no_wav)


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
	var need := ["Engine/debug", "Tests", "Tools", "addons", "Content/legacy", "Screens/editor"]
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
		var scene := String(r.get("scene", "res://Screens/scenes/主场景.tscn"))
		if not ResourceLoader.exists(scene):
			problems.append("%s 场景不存在：%s" % [name, scene])
		var has_assert: bool = r.has("expect") or r.has("expect_scene_state")
		if r.has("click") and not has_assert:
			problems.append("%s 有 click 但没有 expect / expect_scene_state（点了不算成功，要验状态）" % name)
	_ok("截图画面表（%d 个画面）" % screens.size(), problems.is_empty(), "; ".join(problems))


func _check_docs() -> void:
	var agents := FileAccess.get_file_as_bytes("res://AGENTS.md")
	_ok("AGENTS.md 存在且 <= 20KB", agents.size() > 0 and agents.size() <= 20 * 1024, "%d 字节" % agents.size())
	var claude := _read("res://CLAUDE.md").strip_edges()
	_ok("CLAUDE.md 只有一行 @AGENTS.md", claude == "@AGENTS.md", claude)
	var concept := _read("res://Documents/concept.md")
	var has3 := concept.contains("已确认") and concept.contains("建议") and concept.contains("待决定")
	_ok("Documents/concept.md 三栏", has3)
	var formula := _read("res://Documents/combat_formula.md")
	_ok("Documents/combat_formula.md 存在且写了 R1", formula.contains("R1") and formula.contains("0.015"))


## 2026-11-20 转型：旧 RTS 系统必须**真的不在**了。
## 这一条是"反向验错"的靶子：把任何一处旧引用加回来，它立刻变红。
func _check_legacy_removed() -> void:
	var problems: Array[String] = []

	# 1) 旧 AI 决策链：目录与引用都不许在
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://Game/ai")):
		problems.append("Game/ai/ 目录还在")
	for d in ["Game", "Screens", "Tests", "addons"]:
		for f in _walk("res://" + d):
			if not (f.ends_with(".gd") or f.ends_with(".tscn")):
				continue
			if f.ends_with("Tests/checks/check_all.gd"):
				continue
			var text := _read(f)
			for bad in ["res://Game/ai/", "SimpleAI", "class_name Adjutant"]:
				if text.contains(bad):
					problems.append("%s 含 %s" % [f.replace("res://", ""), bad])
					break

	# 2) 战争迷雾
	if FileAccess.file_exists("res://Game/systems/战争迷雾.gd"):
		problems.append("战争迷雾.gd 还在")
	for f in _walk("res://Game") + _walk("res://Screens"):
		if not f.ends_with(".gd"):
			continue
		var ft := _read(f)
		if ft.contains("fog_system") or ft.contains("class_name RtsFog"):
			problems.append("%s 还引用迷雾节点" % f.replace("res://", ""))

	# 2b) 旧测试也不许再引用已删掉的迷雾类（2026-11-21 性能探针就是这样红的）
	for f in _walk("res://Tests"):
		if not f.ends_with(".gd") or f.ends_with("check_all.gd"):
			continue
		if _read(f).contains("RtsFog"):
			problems.append("%s 还引用已删除的 RtsFog" % f.replace("res://", ""))

	# 3) 全图 A*：RtsStandGrid 里不许再有寻路入口/堆
	var nav := _read("res://Game/map/站立网格.gd")
	for bad in ["func find_path", "_heap_push", "MAX_EXPAND", "HEURISTIC_WEIGHT"]:
		if nav.contains(bad):
			problems.append("占格网格.gd 还含 %s" % bad)

	# 4) 用户入口不再有长局
	var runner := _read("res://Tools/run-game.ps1")
	if runner.contains('"--long"'):
		problems.append("run-game.ps1 还认 --long")

	# 5) 采集：玩家侧零入口（点树/命令卡/规划记录都不许再发 GATHER）
	for f in _walk("res://Screens"):
		if not f.ends_with(".gd"):
			continue
		var text := _read(f)
		for bad in ["queue_gather", "Order.GATHER", "_order_gather("]:
			if text.contains(bad):
				problems.append("%s 还含采集入口 %s" % [f.replace("res://", ""), bad])
				break
	_ok("旧系统已移除（AI / 副官 / 迷雾 / 全图A* / 长局 / 采集入口）",
		problems.is_empty(), "; ".join(problems.slice(0, 6)))


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
		if name.begins_with(".") or name in ["bin", "obj", "__pycache__"]:
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