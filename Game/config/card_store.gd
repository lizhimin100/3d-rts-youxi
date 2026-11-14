extends RefCounted
## 职责：内容卡的读写（唯一出口）—— JSON 是唯一真源，Godot 的 Resource 只是内存对象
## 属于：Game/config
## 对外：list(dir) / load_card(path) / save_card(card, path) / path_for(dir, id) / unique_path(dir, base)
## 目录：Content/data/cards/{units,buildings,skills,camps}/*.json
## 禁改：
##   · 不要再用 ResourceLoader/ResourceSaver 读写卡（.tres 已退役，见 Content/legacy/cards/）；
##   · 保存前必须过 JsonCodec（字段拼错会报错，不会静默丢字段）。

const JsonCodec := preload("res://Engine/util/json_codec.gd")
const JsonFile := preload("res://Engine/util/json_file.gd")

const DIR_UNITS := "res://Content/data/cards/units"
const DIR_BUILDINGS := "res://Content/data/cards/buildings"
const DIR_SKILLS := "res://Content/data/cards/skills"
const DIR_CAMPS := "res://Content/data/cards/camps"

const SCRIPT_UNIT := "res://Game/config/单位卡.gd"
const SCRIPT_BUILDING := "res://Game/config/建筑卡.gd"
const SCRIPT_SKILL := "res://Game/config/技能卡.gd"
const SCRIPT_CAMP := "res://Game/config/野怪营地定义.gd"


static func script_for_dir(dir_path: String) -> String:
	match dir_path.trim_suffix("/"):
		DIR_UNITS, "res://Game/config/卡/单位":
			return SCRIPT_UNIT
		DIR_BUILDINGS, "res://Game/config/卡/建筑":
			return SCRIPT_BUILDING
		DIR_SKILLS, "res://Game/config/卡/技能":
			return SCRIPT_SKILL
		DIR_CAMPS, "res://Game/config/卡/野怪营地":
			return SCRIPT_CAMP
	push_error("[CardStore] 不认识的卡目录：" + dir_path)
	return ""


## 列目录下的全部卡。返回 [{path, file, card}]，按文件名排序（结果稳定）。
static func list(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for f in names:
		if not f.ends_with(".json"):
			continue
		var path := dir_path + "/" + f
		var card := load_card(path)
		if card == null:
			continue
		out.append({"path": path, "file": f, "card": card})
	return out


static func load_card(path: String) -> Resource:
	var data: Dictionary = JsonFile.read_dict(path, {})
	if data.is_empty():
		push_error("[CardStore] 读不到卡：" + path)
		return null
	var script_path := String(data.get("$script", ""))
	if script_path.is_empty():
		# 老格式兼容不了就明确报错，别猜
		push_error("[CardStore] 卡里没有 $script：" + path)
		return null
	var card := JsonCodec.restore(script_path, data)
	if card != null:
		# 让编辑器/旧代码里的 resource_path 继续可用（指向 .json 源文件）
		card.take_over_path(path)
		card.set_meta("source_path", path)
	return card


static func save_card(card: Resource, path: String) -> Error:
	if card == null:
		push_error("[CardStore] 保存失败：card 为空")
		return ERR_INVALID_PARAMETER
	var data := JsonCodec.encode_resource(card)
	return JsonFile.write_atomic(path, data)


## 卡 id → 文件路径（ASCII 文件名；id 非 ASCII 时退化为原 id）
static func path_for(dir_path: String, id: String) -> String:
	return dir_path + "/" + id + ".json"


static func unique_path(dir_path: String, base: String) -> String:
	var path := dir_path + "/" + base + ".json"
	var n := 2
	while FileAccess.file_exists(path):
		path = dir_path + "/" + base + "_" + str(n) + ".json"
		n += 1
	return path


static func ensure_dirs() -> void:
	for d in [DIR_UNITS, DIR_BUILDINGS, DIR_SKILLS, DIR_CAMPS]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
