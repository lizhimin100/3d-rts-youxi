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
	# 最后一步：把"新加的东西 / 玩家正在找的东西"排到各自分类的最前面。
	# 为什么需要：列表一屏只露 9 行，建筑有 11 项 —— 营火正好是最后一个，
	# 玩家滚都不会滚，直接判定"编辑器里没有它"（2026-11-01 真实反馈）。
	out = _pin_first(out)
	_cache = out
	return out


## 置顶名单：**同一个分类内**这些 id 排最前（其余保持原顺序）。
## 只影响编辑器列表的显示顺序，不影响任何数据/存盘。
##
## 2026-11-01：野怪置顶是玩家明确要的（"编辑器里能正确看到野怪即可"）。
## 地牢（dungeon）已删除，玩家说他以后自己放 —— 见 单位表.gd 里那段说明。
const PIN_FIRST: Array[String] = [
	"gnoll_warrior", "gnoll_scout",              # 野怪（最容易"以为列表里没有"的两条）
	"campfire",                                  # 夜间照明
]


static func _pin_first(list: Array) -> Array:
	var picked: Array = []
	var rest: Array = []
	for a in list:
		if PIN_FIRST.has(String(a.get("id", ""))):
			picked.append(a)
		else:
			rest.append(a)
	# 按 PIN_FIRST 的顺序排，而不是原始遍历顺序（保证"豺狼人战士"永远第一个）
	var ordered: Array = []
	for id in PIN_FIRST:
		for a in picked:
			if String(a.get("id", "")) == id:
				ordered.append(a)
	ordered.append_array(rest)
	return ordered


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


## 程序化树？（tree / tree_春 / tree_夏 / tree_秋 / tree_冬）
## 这批 id **不需要任何模型文件**：外观由 树库 按种子现场长。
static func is_proc_tree(id: StringName) -> bool:
	return String(id).begins_with("tree")


## 取品种后缀："tree_秋" → "秋"；没后缀（混生树）→ 空串
static func season_suffix(id: StringName) -> String:
	var s := String(id)
	for k in ["春", "夏", "秋", "冬"]:
		if s.ends_with(k):
			return k
	return ""


## ★ 程序化树"掷骰子"：摆一棵就把种子/品种/朝向/缩放一次定好，写进对象里。
## 单独抽成纯函数（不碰会话）有两个原因：
##   ① 无头自检能覆盖到它 —— add_object 需要编辑器会话，测不了；
##   ② 以后要加"重掷这一棵"的菜单项，直接再调一次就行。
static func roll_proc_tree(o: MapObject, type_id: StringName, rng: RandomNumberGenerator) -> void:
	if o == null:
		return
	o.properties["seed"] = rng.randi()
	var season: String = season_suffix(type_id)
	if season.is_empty():
		o.properties.erase("season")
	else:
		o.properties["season"] = season
	o.rotation = rng.randf() * TAU
	o.scale = rng.randf_range(0.88, 1.14)


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


## 野怪 id（编辑器列表里要给它们打「野怪」标，否则玩家以为列表里没有野怪）
const CREEP_IDS: Array[String] = ["gnoll_warrior", "gnoll_scout"]
## 需要在列表里额外解释一句的 id（玩家最容易搞混的那几个）
const ID_TAGS: Dictionary = {
	"campfire": "夜间照明",
	"营火": "仅装饰·不发光",
	# ★ 2026-11-06 玩家反馈「地图编辑器里找不到野怪营地」：
	#   锚点建筑本来就在「建筑」页，但名字是「豺狼人巢穴 / 失落入口 / 折壳营地」，
	#   搜「野怪营地」0 条，也没人知道它必须放成中立。这里把话补全。
	"creep_den": "野怪营地·中立锚点",
	"creep_gate": "野怪营地·中立锚点",
	"creep_shell": "野怪营地·中立锚点",
}


## 卡片里显示用：「草丛 · 植被」「豺狼人战士 · 野怪」「营火 · 夜间照明」。
##
## 为什么要打标（2026-11-01 玩家反馈"编辑器里没有看到野怪模型"）：
##   资产其实都在列表里，但列表只显示名字 —— 玩家看到「豺狼人战士」
##   以为那是别的游戏的词条，或者压根没滚到那一行。加一个后缀就等于"分类说明"，
##   一眼能认出"这是野怪"。
static func list_label(a: Dictionary) -> String:
	var nm: String = String(a.get("name", a.get("id", "?")))
	var sid: String = String(a.get("id", ""))
	var g: String = String(a.get("group", ""))
	var tag: String = String(ID_TAGS.get(sid, ""))
	if tag.is_empty() and CREEP_IDS.has(sid):
		tag = "野怪"
	if not tag.is_empty():
		return "%s · %s" % [nm, tag]
	if int(a.get("category", -1)) == MapObject.Category.DOODAD and not g.is_empty():
		return "%s · %s" % [nm, g]
	return nm


## 某个分类在列表里显示的名字（带数量），例如「单位 · 7」。给类目按钮/计数行用。
static func category_count(cat: int) -> int:
	var n: int = 0
	for a in all_assets():
		if int(a["category"]) == cat:
			n += 1
	return n


static func of_category(cat: int) -> Array:
	var out: Array = []
	for a in all_assets():
		if int(a["category"]) == cat:
			out.append(a)
	return out


## **允许"中立"归属的 id 白名单**。
##
## 单位/建筑默认必须有阵营 —— `编辑会话.add_object()` 会把"中立"回落到槽位 0，
## 因为一座没有阵营的房子谁也打不到、也不参战，等于坏数据。
##
## 但**野怪必须是中立的**：玩家口径 2026-11-01
## "野怪我自己在编辑器里摆" —— 摆下来的豺狼人如果被染成玩家 1 的兵，
## 那它就成了玩家的免费军队（开局白送几个兵）。所以野怪 id 在这里放行，
## 进图后由 `地图加载器` + `野怪.gd` 落到中立阵营上。
##
## ⚠ 地牢（dungeon）已按玩家要求删除；以后自己做的巢穴若也要中立，把 id 加进来。
const NEUTRAL_OK: Array[String] = [
	"gnoll_warrior", "gnoll_scout",
	# ★ 营地锚点建筑**必须**是中立：`野怪营地.gd` 只扫中立阵营的 buildings。
	#   以前不在这份名单里 → 选「摆放归属=中立」摆下去会被回落成玩家 0，
	#   进图后一只怪都不刷（玩家口径「找不到野怪营地 / 摆了没用」）。
	"creep_den", "creep_gate", "creep_shell",
]


## 这个类型能不能以"中立"身份放下
static func allows_neutral(id: StringName) -> bool:
	return NEUTRAL_OK.has(String(id))


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