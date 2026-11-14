extends SceneTree
## 职责：把旧的 .tres 卡**一次性**导出成 Content/data 下的 JSON（迁移工具，保留备查）
## 用法：godot --headless --path . --script Tools/gen/export_content.gd
## 产出：
##   Content/data/game.json                  全局配置 + 难度三档
##   Content/data/harvestables.json          金矿 / 树 / 四季树（UnitDef）
##   Content/data/researches.json            铁匠铺研究（ResearchDef）
##   Content/data/ai_demand.json             AI 诉求分系数（平铺字典）
##   Content/data/cards/{units,buildings,skills,camps}/*.json
## 校验：每一张卡导出后立刻读回，逐字段比对；有差异就退出码 1。

const JsonCodec := preload("res://Engine/util/json_codec.gd")
const JsonFile := preload("res://Engine/util/json_file.gd")
const CardStore := preload("res://Game/config/card_store.gd")

const SRC := [
	["res://Game/config/卡/单位", CardStore.DIR_UNITS],
	["res://Game/config/卡/建筑", CardStore.DIR_BUILDINGS],
	["res://Game/config/卡/技能", CardStore.DIR_SKILLS],
	["res://Game/config/卡/野怪营地", CardStore.DIR_CAMPS],
]

var _problems: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========== 内容数据导出（.tres → JSON） ==========")
	CardStore.ensure_dirs()
	_export_cards()
	_export_game()
	_export_harvestables()
	_export_researches()
	_export_ai_demand()
	print("-------------------------------")
	if _problems.is_empty():
		print("导出完成：0 个问题 ✓")
		quit(0)
	else:
		for p in _problems:
			print("  ✗ " + p)
		print("导出完成：%d 个问题 ✗" % _problems.size())
		quit(1)


func _export_cards() -> void:
	var total := 0
	for pair in SRC:
		var src_dir: String = pair[0]
		var dst_dir: String = pair[1]
		var dir := DirAccess.open(src_dir)
		if dir == null:
			_problems.append("源目录打不开：" + src_dir)
			continue
		var names: PackedStringArray = dir.get_files()
		names.sort()
		for f in names:
			if not f.ends_with(".tres"):
				continue
			var src_path := src_dir + "/" + f
			var card: Resource = load(src_path)
			if card == null:
				_problems.append("读不了：" + src_path)
				continue
			var id := _card_id(card, f)
			if not _is_ascii(id):
				_problems.append("卡 id 不是 ASCII，文件名会不稳：%s（%s）" % [id, src_path])
			var dst := CardStore.path_for(dst_dir, id)
			var data := JsonCodec.encode_resource(card)
			var err := JsonFile.write_atomic(dst, data)
			if err != OK:
				_problems.append("写失败：%s" % dst)
				continue
			var back := CardStore.load_card(dst)
			var diffs := _diff(card, back)
			if not diffs.is_empty():
				_problems.append("%s 字段不一致：%s" % [dst, ", ".join(diffs)])
			total += 1
	print("  卡：%d 张 → %s" % [total, ", ".join([CardStore.DIR_UNITS.get_file(), CardStore.DIR_BUILDINGS.get_file(), CardStore.DIR_SKILLS.get_file(), CardStore.DIR_CAMPS.get_file()])])


func _export_game() -> void:
	var cfg: GameConfig = GameConfig.new()
	cfg.difficulties = UnitTable.build_difficulties()
	var data := JsonCodec.encode_resource(cfg)
	var path := "res://Content/data/game.json"
	if JsonFile.write_atomic(path, data) != OK:
		_problems.append("写失败：" + path)
		return
	var back: GameConfig = JsonCodec.restore("res://Game/config/游戏配置.gd", JsonFile.read_dict(path, {})) as GameConfig
	var diffs := _diff(cfg, back)
	if not diffs.is_empty():
		_problems.append("game.json 字段不一致：%s" % ", ".join(diffs))
	print("  全局配置：%s（%d 个字段，难度 %d 档）" % [path, (data["props"] as Dictionary).size(), cfg.difficulties.size()])


func _export_harvestables() -> void:
	var all: Dictionary = UnitTable.build_units()
	var out := {}
	for id in all.keys():
		var d: UnitDef = all[id]
		if d.kind == RtsConst.Kind.HARVESTABLE:
			out[String(id)] = JsonCodec.encode_resource(d)
	var path := "res://Content/data/harvestables.json"
	if JsonFile.write_atomic(path, out) != OK:
		_problems.append("写失败：" + path)
		return
	print("  可采集物：%d 种 → %s" % [out.size(), path])


func _export_researches() -> void:
	var out := {}
	var all: Dictionary = UnitTable.build_researches()
	for id in all.keys():
		out[String(id)] = JsonCodec.encode_resource(all[id])
	var path := "res://Content/data/researches.json"
	if JsonFile.write_atomic(path, out) != OK:
		_problems.append("写失败：" + path)
		return
	print("  研究：%d 项 → %s" % [out.size(), path])


func _export_ai_demand() -> void:
	var script: Script = load("res://Game/config/AI诉求系数.gd")
	if script == null:
		_problems.append("AI诉求系数.gd 读不到")
		return
	var out: Dictionary = script.call("defaults")
	var path := "res://Content/data/ai_demand.json"
	if JsonFile.write_atomic(path, out) != OK:
		_problems.append("写失败：" + path)
		return
	print("  AI 诉求系数：%d 项 → %s" % [out.size(), path])


func _diff(a: Resource, b: Resource) -> Array[String]:
	var diffs: Array[String] = []
	if b == null:
		diffs.append("读回为空")
		return diffs
	for p in a.get_property_list():
		if not (int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
			continue
		var nm := String(p.name)
		if nm.begins_with("resource_") or nm == "script":
			continue
		var ea := JSON.stringify(JsonCodec.encode(a.get(nm)))
		var eb := JSON.stringify(JsonCodec.encode(b.get(nm)))
		if ea != eb:
			diffs.append(nm)
	return diffs


func _card_id(card: Resource, file_name: String) -> String:
	var v: Variant = card.get("card_id")
	if v is String and not (v as String).is_empty():
		return v
	v = card.get("id")
	if v is String and not (v as String).is_empty():
		return v
	return file_name.get_basename()


func _is_ascii(s: String) -> bool:
	for i in s.length():
		if s.unicode_at(i) > 127:
			return false
	return true