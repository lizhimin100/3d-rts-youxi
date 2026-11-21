extends RefCounted
## 战斗节点组装 · 局内查询层（三分离架构的唯一读数入口）
## 属于：Game/map（运行时也读；编辑器只读同一份 Content/data）
##
## 口径：
##   · 关卡 = [地图底壳] + [玩家布局卡] + [敌人遭遇卡]，三张卡只在 levels.json 的 assembly 里汇合；
##   · 玩家侧战术格子：布局卡激活 -> build / keep，未激活 -> ruin（碎石遗迹，不可建造）；
##   · 敌方侧战术格子：遭遇卡放了固定建筑 -> build / keep，否则同样 ruining；
##   · 本层不复制规则，只读 JSON；要改数值改卡，不改这里。
##
## 对外：level / shell / layout / encounter / tiles_of_level /
##       tile_state / buildable_tiles / ruin_tiles / enemy_tiles

const JsonFile := preload("res://Engine/util/json_file.gd")

const LEVELS := "res://Content/data/levels.json"
const SHELLS := "res://Content/data/map_shells.json"
const LAYOUTS := "res://Content/data/player_layouts.json"
const ENCOUNTERS := "res://Content/data/enemy_encounters.json"

const STATE_KEEP := "keep"
const STATE_BUILD := "build"
const STATE_RUIN := "ruin"
const STATE_MISSING := "missing"

static var _cache: Dictionary = {}


static func clear_cache() -> void:
	_cache.clear()


static func _doc(path: String) -> Dictionary:
	if not _cache.has(path):
		_cache[path] = JsonFile.read_dict(path, {})
	return _cache[path] as Dictionary


static func level(level_id: String) -> Dictionary:
	for lv in (_doc(LEVELS).get("levels", []) as Array):
		if String((lv as Dictionary).get("id", "")) == level_id:
			return lv as Dictionary
	return {}


static func shell(shell_id: String) -> Dictionary:
	for s in (_doc(SHELLS).get("shells", []) as Array):
		if String((s as Dictionary).get("id", "")) == shell_id:
			return s as Dictionary
	return {}


static func layout(layout_id: String) -> Dictionary:
	for l in (_doc(LAYOUTS).get("layouts", []) as Array):
		if String((l as Dictionary).get("id", "")) == layout_id:
			return l as Dictionary
	return {}


static func encounter(encounter_id: String) -> Dictionary:
	for e in (_doc(ENCOUNTERS).get("encounters", []) as Array):
		if String((e as Dictionary).get("id", "")) == encounter_id:
			return e as Dictionary
	return {}


static func assembly_of(level_id: String) -> Dictionary:
	return (level(level_id).get("assembly", {}) as Dictionary).duplicate(true)


## 底壳上的全部战术格子（按序号升序）+ 局内状态。
static func tiles_of_level(level_id: String) -> Array:
	var lv := level(level_id)
	if lv.is_empty():
		return []
	var asm: Dictionary = lv.get("assembly", {})
	var sh := shell(String(asm.get("shell", "")))
	var out: Array = []
	for p in (sh.get("tiles", []) as Array):
		var row: Dictionary = (p as Dictionary).duplicate(true)
		row["state"] = tile_state(level_id, int(row.get("index", 0)))
		out.append(row)
	out.sort_custom(func(a, b): return int(a.get("index", 0)) < int(b.get("index", 0)))
	return out


static func tile_state(level_id: String, index: int) -> String:
	var lv := level(level_id)
	if lv.is_empty():
		return STATE_MISSING
	var asm: Dictionary = lv.get("assembly", {})
	var sh := shell(String(asm.get("shell", "")))
	var found: Dictionary = {}
	for p in (sh.get("tiles", []) as Array):
		if int((p as Dictionary).get("index", -1)) == index:
			found = p as Dictionary
			break
	if found.is_empty():
		return STATE_MISSING
	var role := String(found.get("role", STATE_BUILD))
	var side := String(found.get("side", "player"))
	if side == "player":
		var lay := layout(String(asm.get("player_layout", "")))
		var active := false
		for v in (lay.get("active_tiles", []) as Array):
			if int(v) == index:
				active = true
				break
		if not active:
			return STATE_RUIN
	else:
		var enc := encounter(String(asm.get("enemy_encounter", "")))
		var placed := false
		for row in (enc.get("tile_buildings", []) as Array):
			if int((row as Dictionary).get("tile", -1)) == index:
				placed = true
				break
		if not placed:
			return STATE_RUIN
	return STATE_KEEP if role == STATE_KEEP else STATE_BUILD


static func buildable_tiles(level_id: String) -> Array:
	var out: Array = []
	for p in tiles_of_level(level_id):
		var state := String((p as Dictionary).get("state", ""))
		if state == STATE_KEEP or state == STATE_BUILD:
			out.append(p)
	return out


static func ruin_tiles(level_id: String) -> Array:
	var out: Array = []
	for p in tiles_of_level(level_id):
		if String((p as Dictionary).get("state", "")) == STATE_RUIN:
			out.append(p)
	return out


## 敌方侧：战术格子 + 遭遇卡挂的固定建筑（外观层读这个）。
static func enemy_tiles(level_id: String) -> Array:
	var lv := level(level_id)
	var asm: Dictionary = lv.get("assembly", {})
	var enc := encounter(String(asm.get("enemy_encounter", "")))
	var out: Array = []
	for p in tiles_of_level(level_id):
		var row: Dictionary = p
		if String(row.get("side", "")) != "enemy":
			continue
		for b in (enc.get("tile_buildings", []) as Array):
			if int((b as Dictionary).get("tile", -1)) == int(row.get("index", 0)):
				var merged: Dictionary = row.duplicate(true)
				merged["building"] = String((b as Dictionary).get("building", ""))
				merged["star"] = float((b as Dictionary).get("star", 1.0))
				out.append(merged)
				break
	return out
