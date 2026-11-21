extends RefCounted
## 开发者编辑器的数据层：四张 JSON + ui.csv 的读写、查询、校验。
## 属于：Screens/editor（开发工具，不进发行版）
##
## 纪律：
##   · 唯一写入口就是这里；页面不许自己 FileAccess.open；
##   · 保存走 Godot JSON（保持插入顺序），ui.csv 走 store_csv_line（自动转义）；
##   · 改显示名同时写 JSON display_name 与 ui.csv 的 unit./building./card. key。

const UNITS_PATH := "res://Content/data/units.json"
const COMBAT_PATH := "res://Content/data/combat.json"
const PLANNING_PATH := "res://Content/data/planning.json"
const LEVELS_PATH := "res://Content/data/levels.json"
const I18N_PATH := "res://Content/i18n/ui.csv"

const ATTR_KEYS := [
	"hp", "attack_damage", "attack_cooldown", "attack_range", "attack_type",
	"armor", "armor_type", "hit", "dodge", "crit",
	"armor_pen_flat", "armor_pen_pct", "move_speed",
]

var units: Dictionary = {}
var combat: Dictionary = {}
var planning: Dictionary = {}
var levels: Dictionary = {}
var csv_header: PackedStringArray = PackedStringArray(["key", "zh", "en", "note"])
var csv_rows: Array = []

var load_error: String = ""
var last_save_unix: int = 0
var last_save_paths: PackedStringArray = PackedStringArray()


# ===========================================================================
# 读写
# ===========================================================================
func load_all() -> bool:
	load_error = ""
	units = _read_json(UNITS_PATH)
	combat = _read_json(COMBAT_PATH)
	planning = _read_json(PLANNING_PATH)
	levels = _read_json(LEVELS_PATH)
	_read_csv()
	if units.is_empty() or combat.is_empty() or planning.is_empty() or levels.is_empty():
		if load_error.is_empty():
			load_error = "one or more JSON tables are empty"
		return false
	return true


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		load_error = "cannot open " + path
		return {}
	var text := f.get_as_text()
	f.close()
	var v: Variant = JSON.parse_string(text)
	if v is Dictionary:
		return v as Dictionary
	load_error = "invalid JSON " + path
	return {}


func save_all() -> bool:
	var ok := true
	ok = _write_json(UNITS_PATH, units) and ok
	ok = _write_json(PLANNING_PATH, planning) and ok
	ok = _write_json(LEVELS_PATH, levels) and ok
	ok = _write_csv() and ok
	if ok:
		last_save_unix = int(Time.get_unix_time_from_system())
		last_save_paths = PackedStringArray([UNITS_PATH, PLANNING_PATH, LEVELS_PATH, I18N_PATH])
		var i18n := _i18n()
		if i18n != null:
			i18n.call("load_csv")
	return ok


func _write_json(path: String, data: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		load_error = "cannot write " + path
		return false
	f.store_string(JSON.stringify(data, "\t", false, false) + "\n")
	f.close()
	return true


func _read_csv() -> void:
	csv_rows.clear()
	var f := FileAccess.open(I18N_PATH, FileAccess.READ)
	if f == null:
		load_error = "cannot open " + I18N_PATH
		return
	csv_header = f.get_csv_line()
	if csv_header.size() < 3:
		csv_header = PackedStringArray(["key", "zh", "en", "note"])
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() == 1 and row[0].strip_edges().is_empty():
			continue
		var arr: Array = []
		for i in maxi(csv_header.size(), row.size()):
			arr.append(String(row[i]) if i < row.size() else "")
		csv_rows.append(arr)
	f.close()


func _write_csv() -> bool:
	var f := FileAccess.open(I18N_PATH, FileAccess.WRITE)
	if f == null:
		load_error = "cannot write " + I18N_PATH
		return false
	f.store_csv_line(csv_header)
	for row in csv_rows:
		var cells := PackedStringArray()
		for cell in row:
			cells.append(String(cell))
		f.store_csv_line(cells)
	f.close()
	return true


# ===========================================================================
# 查询
# ===========================================================================
func unit_list() -> Array:
	return units.get("units", []) as Array


func unit_by_id(id: String) -> Dictionary:
	for u in unit_list():
		if String(u.get("id", "")) == id:
			return u as Dictionary
	return {}


func faction_list() -> Array:
	var out: Array = []
	var factions: Dictionary = units.get("factions", {})
	for id in factions.keys():
		var f: Dictionary = factions[id]
		out.append({"id": String(id), "display_name": String(f.get("display_name", id)),
			"placeholder": bool(f.get("use_placeholder_mesh", false))})
	return out


func faction_display(id: String) -> String:
	var factions: Dictionary = units.get("factions", {})
	var f: Dictionary = factions.get(id, {})
	return String(f.get("display_name", id))


func attack_types() -> Array:
	return combat.get("attack_types", []) as Array


func armor_types() -> Array:
	return combat.get("armor_types", []) as Array


func attack_index(name: String) -> int:
	var arr := attack_types()
	for i in arr.size():
		if String(arr[i]) == name:
			return i
	return 0


func armor_index(name: String) -> int:
	var arr := armor_types()
	for i in arr.size():
		if String(arr[i]) == name:
			return i
	return 0


func buildings() -> Array:
	return planning.get("buildings", []) as Array


func building_by_id(id: String) -> Dictionary:
	for b in buildings():
		if String(b.get("id", "")) == id:
			return b as Dictionary
	return {}


func building_display(id: String) -> String:
	var b := building_by_id(id)
	return String(b.get("display_name", id))


func building_star(building: Dictionary, star: int) -> Dictionary:
	var arr: Array = building.get("star_output", []) as Array
	var idx := clampi(star - 1, 0, maxi(arr.size() - 1, 0))
	if arr.is_empty():
		return {}
	return arr[idx] as Dictionary


func cards() -> Array:
	return planning.get("cards", []) as Array


func card_by_id(id: String) -> Dictionary:
	for c in cards():
		if String(c.get("id", "")) == id:
			return c as Dictionary
	return {}


func card_display(id: String) -> String:
	var c := card_by_id(id)
	return String(c.get("display_name", id))


func strategies() -> Dictionary:
	return planning.get("strategies", {}) as Dictionary


func deck_start() -> Array:
	var d: Dictionary = planning.get("deck", {}) as Dictionary
	return d.get("start", []) as Array


func deck_size() -> int:
	var d: Dictionary = planning.get("deck", {}) as Dictionary
	return int(d.get("size", 12))


func board() -> Dictionary:
	return planning.get("board", {}) as Dictionary


func platforms() -> Array:
	return board().get("platforms", []) as Array


func start_buildings() -> Array:
	return board().get("start", []) as Array


func platform_by_plot(plot: int) -> Dictionary:
	for p in platforms():
		if int(p.get("plot", -1)) == plot:
			return p as Dictionary
	return {}


func start_at_plot(plot: int) -> Dictionary:
	for s in start_buildings():
		if int(s.get("plot", -1)) == plot:
			return s as Dictionary
	return {}


func camp_meters() -> Vector2:
	var m: Array = board().get("camp_m", [28.0, 16.0]) as Array
	if m.size() < 2:
		return Vector2(28.0, 16.0)
	return Vector2(float(m[0]), float(m[1]))


func level() -> Dictionary:
	var arr: Array = levels.get("levels", []) as Array
	if arr.is_empty():
		return {}
	return arr[0] as Dictionary


func lane() -> Dictionary:
	return level().get("lane", {}) as Dictionary


func segments() -> Array:
	return lane().get("segments", []) as Array


func lane_templates() -> Dictionary:
	return lane().get("templates", {}) as Dictionary


func lane_template() -> String:
	return String(lane().get("template", ""))


func intents() -> Array:
	return level().get("intent_pool", []) as Array


func intent_templates() -> Dictionary:
	return level().get("intent_templates", {}) as Dictionary


func enemy_buildings() -> Array:
	return level().get("enemy_buildings", []) as Array


func r1() -> float:
	return float(combat.get("r1", 0.015))


func meters(raw: float) -> float:
	return raw * r1()


# ===========================================================================
# 文案
# ===========================================================================
func i18n_zh(key: String, fallback: String = "") -> String:
	for row in csv_rows:
		if String(row[0]) == key:
			var zh := String(row[1])
			return zh if not zh.is_empty() else fallback
	return fallback


func set_i18n(key: String, zh: String, en: String = "", note: String = "") -> void:
	for row in csv_rows:
		if String(row[0]) == key:
			row[1] = zh
			if not en.is_empty():
				row[2] = en
			if not note.is_empty() and row.size() > 3:
				row[3] = note
			return
	while csv_rows.is_empty() or csv_rows[0].size() < 4:
		csv_rows.append(["", "", "", ""])
	csv_rows.append([key, zh, en, note])


func display_name_key(kind: String, id: String) -> String:
	match kind:
		"unit":
			return "unit." + id
		"building":
			return "building." + id
		"card":
			return "card." + id
	return kind + "." + id


func set_display_name(kind: String, id: String, zh: String) -> void:
	var key := display_name_key(kind, id)
	var row := {}
	if kind == "unit":
		row = unit_by_id(id)
	elif kind == "building":
		row = building_by_id(id)
	elif kind == "card":
		row = card_by_id(id)
	if not row.is_empty():
		row["display_name"] = zh
	set_i18n(key, zh)


func _i18n() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("I18n")
	return null


# ===========================================================================
# 校验
# ===========================================================================
func validate() -> Array:
	var out: Array = []
	out.append(_check("editor.check.units", _validate_units()))
	out.append(_check("editor.check.attrs", _validate_attrs()))
	out.append(_check("editor.check.buildings", _validate_buildings()))
	out.append(_check("editor.check.deck", _validate_deck()))
	out.append(_check("editor.check.lane", _validate_lane()))
	out.append(_check("editor.check.intent", _validate_intent()))
	out.append(_check("editor.check.platforms", _validate_platforms()))
	out.append(_check("editor.check.start", _validate_start()))
	out.append(_check("editor.check.models", _validate_models()))
	out.append(_check("editor.check.i18n", _validate_i18n()))
	return out


func _check(key: String, pair: Array) -> Dictionary:
	return {"key": key, "ok": bool(pair[0]), "detail": String(pair[1])}


func _validate_units() -> Array:
	var list := unit_list()
	if list.size() != 12:
		return [false, "units=%d" % list.size()]
	for u in list:
		if String(u.get("id", "")).is_empty():
			return [false, "empty id"]
		if not bool(u.get("use_placeholder_mesh", false)) and String(u.get("model_path", "")).is_empty():
			return [false, String(u.get("id", "")) + " model_path empty"]
	return [true, "12 units"]


func _validate_attrs() -> Array:
	for u in unit_list():
		for k in ATTR_KEYS:
			if not (u as Dictionary).has(k):
				return [false, String(u.get("id", "")) + " missing " + k]
	return [true, "13 attrs x 12"]


func _validate_buildings() -> Array:
	if buildings().size() < 4:
		return [false, "buildings=%d" % buildings().size()]
	for b in buildings():
		if String(b.get("produce_tag", "")).is_empty():
			return [false, String(b.get("id", "")) + " produce_tag empty"]
		var stars: Array = b.get("star_output", []) as Array
		if stars.size() != 3:
			return [false, String(b.get("id", "")) + " star_output=%d" % stars.size()]
		if String(b.get("model_path", "")).is_empty():
			return [false, String(b.get("id", "")) + " model empty"]
	return [true, "4 buildings x 3 stars"]


func _validate_deck() -> Array:
	var deck := deck_start()
	if deck.size() != deck_size() or deck.size() != 12:
		return [false, "deck=%d / %d" % [deck.size(), deck_size()]]
	for id in deck:
		if card_by_id(String(id)).is_empty():
			return [false, "missing card " + String(id)]
	return [true, "12 cards"]


func _validate_lane() -> Array:
	var segs := segments()
	if segs.size() != 3:
		return [false, "segments=%d" % segs.size()]
	var total := 0.0
	for s in segs:
		var length := float(s.get("length", 0.0))
		var width := float(s.get("width", 0.0))
		if length <= 0.0 or width <= 0.0:
			return [false, "segment <= 0"]
		total += length
	if absf(total - float(lane().get("length", 0.0))) > 0.001:
		return [false, "sum %.0f != %.0f" % [total, float(lane().get("length", 0.0))]]
	return [true, "%.0f" % total]


func _validate_intent() -> Array:
	var sum := 0.0
	for it in intents():
		sum += maxf(float(it.get("weight", 0.0)), 0.0)
	return [sum > 0.0, "weight=%.0f" % sum]


func _validate_platforms() -> Array:
	var list := platforms()
	if list.size() < 10:
		return [false, "platforms=%d" % list.size()]
	var gap := min_gap_meters()
	if gap < 0.5:
		return [false, "gap=%.2f m" % gap]
	return [true, "gap=%.2f m" % gap]


func _validate_start() -> Array:
	var bases := 0
	var farms := 0
	var barracks := 0
	for s in start_buildings():
		var b := building_by_id(String(s.get("building", "")))
		var tag := String(b.get("tag", ""))
		if tag == "base":
			bases += 1
		elif tag == "farm":
			farms += 1
		elif tag == "barracks":
			barracks += 1
	return [bases == 1 and farms == 2 and barracks == 1,
		"%d/%d/%d" % [bases, farms, barracks]]


func _validate_models() -> Array:
	for u in unit_list():
		var p := String(u.get("model_path", ""))
		if not p.is_empty() and not FileAccess.file_exists(p):
			return [false, String(u.get("id", "")) + " -> " + p]
	for b in buildings():
		var bp := String(b.get("model_path", ""))
		if not bp.is_empty() and not FileAccess.file_exists(bp):
			return [false, String(b.get("id", "")) + " -> " + bp]
	return [true, "all model paths exist"]


func _validate_i18n() -> Array:
	var need := ["editor.app.title", "editor.tab.units", "editor.dps.final",
		"editor.cards.deck", "editor.level.camp"]
	for key in need:
		if i18n_zh(key, "").is_empty():
			return [false, "missing " + key]
	return [true, "%d keys" % csv_rows.size()]


func min_gap_meters() -> float:
	var list := platforms()
	var camp := camp_meters()
	var best := 999.0
	for i in list.size():
		var a: Dictionary = list[i]
		for j in range(i + 1, list.size()):
			var b: Dictionary = list[j]
			var dx := (float(a.get("x", 0.0)) - float(b.get("x", 0.0))) * camp.x
			var dy := (float(a.get("y", 0.0)) - float(b.get("y", 0.0))) * camp.y
			var ra := float(a.get("radius", 0.04)) * camp.y
			var rb := float(b.get("radius", 0.04)) * camp.y
			best = minf(best, sqrt(dx * dx + dy * dy) - ra - rb)
	return best


func min_platform_gap_norm() -> float:
	var list := platforms()
	var best := 9.0
	for i in list.size():
		var a: Dictionary = list[i]
		for j in range(i + 1, list.size()):
			var b: Dictionary = list[j]
			var dx := float(a.get("x", 0.0)) - float(b.get("x", 0.0))
			var dy := float(a.get("y", 0.0)) - float(b.get("y", 0.0))
			var ra := float(a.get("radius", 0.04))
			var rb := float(b.get("radius", 0.04))
			best = minf(best, sqrt(dx * dx + dy * dy) - ra - rb)
	return best


# ===========================================================================
# 结构性修改（页面调用）
# ===========================================================================
func add_card(id: String, display_name: String, kind: String) -> Dictionary:
	var card := {
		"id": id,
		"display_name": display_name,
		"kind": kind,
		"cost_cp": 2,
		"exhaust": kind == "build",
		"count": 1,
	}
	if kind == "build":
		card["building"] = "farm"
	elif kind == "train":
		card["unit"] = "alliance_footman"
		card["tag"] = "barracks"
	else:
		card["effect"] = "focus"
	var arr := cards()
	arr.append(card)
	set_i18n("card." + id, display_name)
	return card


func remove_card(id: String) -> void:
	var arr := cards()
	for i in range(arr.size() - 1, -1, -1):
		if String((arr[i] as Dictionary).get("id", "")) == id:
			arr.remove_at(i)
	var deck := deck_start()
	for i in range(deck.size() - 1, -1, -1):
		if String(deck[i]) == id:
			deck.remove_at(i)


func add_deck_card(id: String) -> bool:
	var deck := deck_start()
	if deck.size() >= deck_size():
		return false
	if card_by_id(id).is_empty():
		return false
	deck.append(id)
	return true


func remove_deck_at(index: int) -> void:
	var deck := deck_start()
	if index >= 0 and index < deck.size():
		deck.remove_at(index)


func rename_card_id(old_id: String, new_id: String) -> bool:
	if old_id == new_id or new_id.is_empty():
		return false
	if not card_by_id(new_id).is_empty():
		return false
	var card := card_by_id(old_id)
	if card.is_empty():
		return false
	card["id"] = new_id
	var deck := deck_start()
	for i in deck.size():
		if String(deck[i]) == old_id:
			deck[i] = new_id
	# 文案 key 跟着卡 id 走
	var old_name := i18n_zh("card." + old_id, String(card.get("display_name", old_id)))
	set_i18n("card." + new_id, old_name)
	return true


func set_lane_template(name: String) -> bool:
	var templates := lane_templates()
	if not templates.has(name):
		return false
	var t: Dictionary = templates[name]
	var lengths: Array = t.get("lengths", []) as Array
	var widths: Array = t.get("widths", []) as Array
	var segs := segments()
	if lengths.size() != 3 or widths.size() != 3 or segs.size() != 3:
		return false
	for i in 3:
		var s: Dictionary = segs[i]
		s["length"] = float(lengths[i])
		s["width"] = float(widths[i])
	lane()["template"] = name
	var total := 0.0
	for s in segs:
		total += float(s.get("length", 0.0))
	lane()["length"] = total
	var weights: Array = (intent_templates().get(name, []) as Array)
	var pool := intents()
	if weights.size() == pool.size():
		for i in pool.size():
			(pool[i] as Dictionary)["weight"] = float(weights[i])
	return true


func sync_lane_total() -> float:
	var total := 0.0
	for s in segments():
		total += float(s.get("length", 0.0))
	lane()["length"] = total
	return total


func store_intent_weights() -> void:
	var tpl := lane_template()
	var pool := intents()
	var arr: Array = []
	for it in pool:
		arr.append(float(it.get("weight", 0.0)))
	intent_templates()[tpl] = arr


func preset_start() -> void:
	var start := start_buildings()
	start.clear()
	start.append({"building": "keep", "plot": 0})
	start.append({"building": "farm", "plot": 1})
	start.append({"building": "farm", "plot": 2})
	start.append({"building": "barracks", "plot": 3})


func move_start(from_plot: int, to_plot: int) -> bool:
	var entry := start_at_plot(from_plot)
	if entry.is_empty():
		return false
	if not start_at_plot(to_plot).is_empty():
		return false
	entry["plot"] = to_plot
	return true


func add_enemy_building() -> Dictionary:
	var arr := enemy_buildings()
	var idx := arr.size()
	var kinds := ["watchtower", "barracks", "tower"]
	var b := {
		"building": kinds[idx % kinds.size()],
		"x": 0.78 + 0.04 * float(idx % 3),
		"y": 0.25 + 0.18 * float(idx % 4),
		"star": 2,
	}
	arr.append(b)
	return b


func count_cards_by_kind(kind: String) -> int:
	var n := 0
	for c in cards():
		if String(c.get("kind", "")) == kind:
			n += 1
	return n
