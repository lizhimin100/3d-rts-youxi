@tool
class_name MapAssets
extends RefCounted
## **资产目录**：可放置对象清单，从「单位表 + 美术/模型目录」现场算出来。
##
## 只做清单，不做导入 UI（明确非目标）：美术换模型了，这里自动跟上；
## 以后接 manifest 也只是换个数据源，调用方不用改。

## 自然物目录：**装饰只从这一个目录来**。
## 根目录 美术/模型/ 里同时躺着单位（农民/步兵…）和建筑（兵营/大本营…），
## 以前扫根目录会把它们全塞进「装饰」列表，用户点开装饰看到一堆房子和兵 ——
## 这不是分类偏好，是数据源选错了。现在装饰永远只读 v7_自然。
const DOODAD_DIR := "res://美术/模型/v7_自然/"
## Godot 实际可加载的模型目录。注意 v7_自然 目前带 .gdignore（Blender 源目录），
## ResourceLoader 看不到它；真正能 load 的是根目录同名 GLB（导入产物）。所以：
##   清单/分类只认 v7_自然 的名单（绝不把单位/建筑混进来），路径优先取根目录。
const MODEL_DIR := "res://美术/模型/"
## 资源类模型：树/金矿属于「资源」层，不进装饰。
const RESOURCE_MODEL_NAMES: Array[String] = ["树", "金矿"]
## 装饰白名单（顺序就是面板里的顺序）。全部是**非建筑、非单位**的环境道具。
const DOODAD_NAMES: Array[String] = [
	"树", "草丛", "岩石", "木桶", "木箱", "栅栏", "旗帜", "帐篷",
	"断墙", "路标", "木桩", "营火", "尸骨",
]
## 装饰子分类（魔兽 Doodad 面板也是按类别分页的）：顺序即下拉框顺序
const DOODAD_GROUP_ORDER: Array[String] = ["植被", "岩石", "营地", "残迹", "杂物"]
const DOODAD_GROUPS: Dictionary = {
	"树": "植被", "草丛": "植被",
	"岩石": "岩石",
	"帐篷": "营地", "旗帜": "营地", "路标": "营地", "营火": "营地", "栅栏": "营地", "木桩": "营地",
	"断墙": "残迹", "尸骨": "残迹",
	"木桶": "杂物", "木箱": "杂物",
}

static var _cache: Array = []


## 全部资产：[{id, name, category, model, scale, def}]
static func all_assets() -> Array:
	if not _cache.is_empty():
		return _cache
	var out: Array = []
	var units: Dictionary = UnitTable.build_units()
	for id in units:
		var d: UnitDef = units[id]
		var cat: int = MapObject.Category.DOODAD
		match d.kind:
			RtsConst.Kind.UNIT:
				cat = MapObject.Category.UNIT
			RtsConst.Kind.BUILDING:
				cat = MapObject.Category.BUILDING
			RtsConst.Kind.HARVESTABLE:
				cat = MapObject.Category.RESOURCE
		out.append({
			"id": String(d.id),
			"name": d.display_name,
			"category": cat,
			"model": d.model_path,
			"scale": d.model_scale,
			"group": "",
		})
	# 装饰：**只**从 v7_自然 目录来；先白名单排序，再扫目录补齐（跳过资源/LOD）
	var seen: Dictionary = {}
	for a in out:
		seen[String(a["id"])] = true
	for n in DOODAD_NAMES:
		if n in RESOURCE_MODEL_NAMES:
			continue
		var p: String = _model_path_for(n)
		if p.is_empty():
			continue
		out.append({
			"id": n, "name": n, "category": MapObject.Category.DOODAD,
			"model": p, "scale": 1.0, "group": doodad_group(n),
		})
		seen[n] = true
	_scan_dir(DOODAD_DIR, out, seen)
	_cache = out
	return out


## 一个自然物到底从哪加载：根目录优先（可 load），v7_自然 兜底（若哪天去掉 .gdignore）
static func _model_path_for(base: String) -> String:
	if base in RESOURCE_MODEL_NAMES:
		return ""
	var rooted: String = MODEL_DIR + base + ".glb"
	if ResourceLoader.exists(rooted):
		return rooted
	var natural: String = DOODAD_DIR + base + ".glb"
	if ResourceLoader.exists(natural):
		return natural
	return ""


## 这个 id 是否属于自然物白名单/目录（给自检和"装饰边界"用）
static func is_natural_id(id: String) -> bool:
	if id in DOODAD_NAMES or id in RESOURCE_MODEL_NAMES:
		return true
	var d := DirAccess.open(DOODAD_DIR)
	if d == null:
		return false
	var files: PackedStringArray = d.get_files()
	return files.has(id + ".glb") or files.has(id + ".glb.import")


static func _scan_dir(dir: String, out: Array, seen: Dictionary) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if not f.ends_with(".glb") and not f.ends_with(".glb.import"):
			continue
		var base: String = f.get_basename().get_basename()
		if base.ends_with("_中") or base.ends_with("_远"):
			continue
		if base.begins_with("_"):
			continue
		if base in RESOURCE_MODEL_NAMES:
			continue
		if seen.has(base):
			continue
		var path: String = _model_path_for(base)
		if path.is_empty():
			continue
		seen[base] = true
		out.append({"id": base, "name": base, "category": MapObject.Category.DOODAD,
			"model": path, "scale": 1.0, "group": doodad_group(base)})


## 装饰子分类（找不到的给「杂物」；树/金矿会被资源层挡住，不会走到这里）
static func doodad_group(id: String) -> String:
	return String(DOODAD_GROUPS.get(id, "杂物"))


## 卡片里显示用：「草丛 · 植被」；非装饰只返回名字
static func list_label(a: Dictionary) -> String:
	var nm: String = String(a.get("name", a.get("id", "?")))
	var g: String = String(a.get("group", ""))
	if int(a.get("category", -1)) == MapObject.Category.DOODAD and not g.is_empty():
		return "%s · %s" % [nm, g]
	return nm


static func of_category(cat: int) -> Array:
	var out: Array = []
	for a in all_assets():
		if int(a["category"]) == cat:
			out.append(a)
	return out


static func find(id: StringName) -> Dictionary:
	for a in all_assets():
		if StringName(a["id"]) == id:
			return a
	return {}


static func display_name(id: StringName) -> String:
	var a: Dictionary = find(id)
	if a.is_empty():
		return String(id)
	return String(a.get("name", String(id)))


static func category_name(cat: int) -> String:
	match cat:
		MapObject.Category.UNIT:
			return "单位"
		MapObject.Category.BUILDING:
			return "建筑"
		MapObject.Category.DOODAD:
			return "装饰"
		MapObject.Category.RESOURCE:
			return "资源"
	return "?"


## 清缓存（美术重导入后用）
static func clear_cache() -> void:
	_cache.clear()