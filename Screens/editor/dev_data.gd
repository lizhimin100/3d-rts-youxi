@tool
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
const SHELLS_PATH := "res://Content/data/map_shells.json"
const LAYOUTS_PATH := "res://Content/data/player_layouts.json"
const ENCOUNTERS_PATH := "res://Content/data/enemy_encounters.json"
const I18N_PATH := "res://Content/i18n/ui.csv"
const ShellStore := preload("res://Screens/editor/shell_store.gd")

const ATTR_KEYS := [
	"hp", "attack_damage", "attack_cooldown", "attack_range", "attack_type",
	"armor", "armor_type", "hit", "dodge", "crit",
	"armor_pen_flat", "armor_pen_pct", "move_speed",
]

var units: Dictionary = {}
var combat: Dictionary = {}
var planning: Dictionary = {}
var levels: Dictionary = {}
var shells: Dictionary = {}
var layouts: Dictionary = {}
var encounters: Dictionary = {}
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
	shells = _read_json(SHELLS_PATH)
	layouts = _read_json(LAYOUTS_PATH)
	encounters = _read_json(ENCOUNTERS_PATH)
	_read_csv()
	for pair in [[units, UNITS_PATH], [combat, COMBAT_PATH], [planning, PLANNING_PATH],
			[levels, LEVELS_PATH], [shells, SHELLS_PATH], [layouts, LAYOUTS_PATH],
			[encounters, ENCOUNTERS_PATH]]:
		if (pair[0] as Dictionary).is_empty():
			load_error = "empty table " + String(pair[1])
			return false
	if ui_csv_missing("editor.app.title"):
		load_error = "ui.csv missing editor keys"
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
	ok = save_shells() and ok
	ok = _write_json(LAYOUTS_PATH, layouts) and ok
	ok = _write_json(ENCOUNTERS_PATH, encounters) and ok
	ok = _write_csv() and ok
	if ok:
		last_save_unix = int(Time.get_unix_time_from_system())
		last_save_paths = PackedStringArray([UNITS_PATH, PLANNING_PATH, LEVELS_PATH,
			SHELLS_PATH, LAYOUTS_PATH, ENCOUNTERS_PATH, I18N_PATH])
		var i18n := _i18n()
		if i18n != null:
			i18n.call("load_csv")
	return ok


## 三维底壳编辑器只写底壳这张表（不动卡牌/关卡）。
func save_shells() -> bool:
	var ok := _write_json(SHELLS_PATH, shells)
	if ok:
		last_save_unix = int(Time.get_unix_time_from_system())
		last_save_paths = PackedStringArray([SHELLS_PATH])
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


func tiles() -> Array:
	var shell: Dictionary = shell_list()[0] as Dictionary if not shell_list().is_empty() else {}
	if shell.is_empty():
		return []
	return ShellStore.tiles(shell)


func start_buildings() -> Array:
	return board().get("start", []) as Array


func tile_by_plot(plot: int) -> Dictionary:
	for p in tiles():
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
func ui_csv_missing(key: String) -> bool:
	return i18n_zh(key, "").is_empty()


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
# 三分离：底壳 / 玩家布局卡 / 敌人遭遇卡 / 战斗节点组装
# ===========================================================================
func shell_list() -> Array:
	return shells.get("shells", []) as Array


func shell_by_id(id: String) -> Dictionary:
	for s in shell_list():
		if String((s as Dictionary).get("id", "")) == id:
			return s as Dictionary
	return {}


func shell_ids() -> Array:
	var out: Array = []
	for s in shell_list():
		out.append(String((s as Dictionary).get("id", "")))
	return out


func levels_list() -> Array:
	return levels.get("levels", []) as Array


func level_by_id(id: String) -> Dictionary:
	for lv in levels_list():
		if String((lv as Dictionary).get("id", "")) == id:
			return lv as Dictionary
	return {}


func level_index(id: String) -> int:
	var arr := levels_list()
	for i in arr.size():
		if String((arr[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


func generated_levels() -> Array:
	var out: Array = []
	for lv in levels_list():
		if (lv as Dictionary).has("assembly"):
			out.append(lv)
	return out


func layout_list() -> Array:
	return layouts.get("layouts", []) as Array


func layout_by_id(id: String) -> Dictionary:
	for l in layout_list():
		if String((l as Dictionary).get("id", "")) == id:
			return l as Dictionary
	return {}


func layout_kinds() -> Array:
	return layouts.get("kinds", []) as Array


func kind_row(kind: String) -> Dictionary:
	for k in layout_kinds():
		if String((k as Dictionary).get("id", "")) == kind:
			return k as Dictionary
	return {}


func kind_display(kind: String) -> String:
	return String(kind_row(kind).get("display_name", kind))


func layouts_of_shell(shell_id: String) -> Array:
	var out: Array = []
	for l in layout_list():
		if String((l as Dictionary).get("shell", "")) == shell_id:
			out.append(l)
	return out


func encounter_list() -> Array:
	return encounters.get("encounters", []) as Array


func encounter_by_id(id: String) -> Dictionary:
	for e in encounter_list():
		if String((e as Dictionary).get("id", "")) == id:
			return e as Dictionary
	return {}


func encounter_factions() -> Array:
	return encounters.get("factions", []) as Array


func faction_display_of(id: String) -> String:
	for f in encounter_factions():
		if String((f as Dictionary).get("id", "")) == id:
			return String((f as Dictionary).get("display_name", id))
	return faction_display(id)


func encounters_of_shell(shell_id: String) -> Array:
	var out: Array = []
	for e in encounter_list():
		if String((e as Dictionary).get("shell", "")) == shell_id:
			out.append(e)
	return out


func assemblies() -> Array:
	return levels.get("assemblies", []) as Array


func assembly_by_id(id: String) -> Dictionary:
	for a in assemblies():
		if String((a as Dictionary).get("id", "")) == id:
			return a as Dictionary
	return {}


func assembly_id_of(layout_id: String, encounter_id: String) -> String:
	return "asm_" + layout_id.trim_prefix("layout_") + "__" + encounter_id.trim_prefix("enc_")


func combo_level_id(layout_id: String, encounter_id: String) -> String:
	return "level_" + assembly_id_of(layout_id, encounter_id)


func default_combos() -> Array:
	return [
		["shell_ridge_01", "layout_even_four", "enc_gnoll_press"],
		["shell_ridge_01", "layout_disadvantage_three", "enc_gnoll_press"],
		["shell_ridge_01", "layout_even_four", "enc_murloc_tide"],
	]


func active_tiles(layout: Dictionary) -> Array:
	return layout.get("active_tiles", []) as Array


## 某个区域多边形在 X 轴上的范围（米）。赛区分段不再读分割环，改由三块区域推出来。
func region_x_extent(shell: Dictionary, kind: String) -> Vector2:
	var pts := ShellStore.region_points(shell, kind)
	if pts.is_empty():
		return Vector2.ZERO
	var lo := pts[0].x
	var hi := pts[0].x
	for p in pts:
		lo = minf(lo, p.x)
		hi = maxf(hi, p.x)
	return Vector2(lo, hi)


func point_at_t(shell: Dictionary, t: int) -> Vector2:
	return ShellStore.point_at_t(shell, t)


## 三张卡 -> 一张完整可玩关卡（不落盘；落盘走 generate_assembly）。
func compose_level(shell_id: String, layout_id: String, encounter_id: String) -> Dictionary:
	var shell := shell_by_id(shell_id)
	var layout := layout_by_id(layout_id)
	var enc := encounter_by_id(encounter_id)
	if shell.is_empty() or layout.is_empty() or enc.is_empty():
		return {}
	if String(layout.get("shell", "")) != shell_id or String(enc.get("shell", "")) != shell_id:
		return {}
	var spine: Dictionary = shell.get("spine", {})
	var length_logic := float(spine.get("length_logic", 4000.0))
	var width_logic := float(spine.get("width_logic", 420.0))
	# 赛区分段：玩家区右缘 = 第一段结束；敌方区左缘 = 第二段结束（米 → 游戏数值）
	var zone_depth := ShellStore.logic_of(region_x_extent(shell, "player").y)
	var push := ShellStore.logic_of(region_x_extent(shell, "enemy").x)
	if push <= zone_depth or push >= length_logic:
		return {}
	var kind := String(layout.get("kind", "even"))
	var seg_width := int(floor(width_logic))
	var rounds := _rounds_of_encounter(enc)
	if rounds.is_empty():
		return {}
	var lv := {
		"id": combo_level_id(layout_id, encounter_id),
		"display_name": String(layout.get("display_name", layout_id)) + " · " + String(enc.get("display_name", encounter_id)),
		"player_faction": "alliance",
		"enemy_faction": String(enc.get("faction", "bandit")),
		"player_base_hp": 2600.0,
		"enemy_base_hp": float(enc.get("base_hp", 3200.0)),
		"round_seconds": 60.0,
		"lane": {
			"length": length_logic,
			"width": width_logic,
			"zone_depth": zone_depth,
			"zone_dps_per_squad": 9.0,
			"spawn_offset": 250.0,
			"base_stop": 120.0,
			"template": kind,
			"note": "composed from map shell; lengths are game units (x R1 = meters)",
			"segments": [
				{"name_key": "editor.level.segment_1", "length": zone_depth, "width": seg_width, "role": "player"},
				{"name_key": "editor.level.segment_2", "length": push - zone_depth, "width": seg_width, "role": "neutral"},
				{"name_key": "editor.level.segment_3", "length": length_logic - push, "width": seg_width, "role": "enemy"},
			],
		},
		"rounds": rounds,
		"intent_pool": _intent_pool_of(enc),
		"intent_templates": {},
		"enemy_buildings": _enemy_buildings_of(shell, enc),
		"camp": {
			"player": "alliance",
			"enemy": String(enc.get("faction", "bandit")),
			"start_preset": "1 keep + 2 farm + 1 barracks",
		},
		"player_board": {
			"layout": layout_id,
			"kind": kind,
			"active_tiles": active_tiles(layout),
			"slots": layout.get("slots", []),
		},
		"assembly": {
			"shell": shell_id,
			"player_layout": layout_id,
			"enemy_encounter": encounter_id,
			"r1": ShellStore.R1,
		},
	}
	return lv


func _rounds_of_encounter(enc: Dictionary) -> Array:
	var plan: Dictionary = enc.get("wave_plan", {})
	var roles: Dictionary = enc.get("unit_roles", {})
	var out: Array = []
	for kind in ["attack", "defend"]:
		var waves: Array = []
		for w in (plan.get(kind, []) as Array):
			var squads: Array = []
			for s in ((w as Dictionary).get("squads", []) as Array):
				var role := String((s as Dictionary).get("role", ""))
				var uid := String(roles.get(role, ""))
				var unit := unit_by_id(uid)
				if uid.is_empty() or unit.is_empty() or not bool(unit.get("enabled", false)):
					continue
				squads.append({"unit": uid, "count": clampi(int((s as Dictionary).get("count", 1)), 1, 6), "star": 1})
			if squads.is_empty():
				continue
			waves.append({"t": float((w as Dictionary).get("t", 0.0)), "squads": squads})
		if waves.is_empty():
			return []
		var label_key := "editor.assembly.round_attack" if kind == "attack" else "editor.assembly.round_defend"
		out.append({"kind": kind, "label": i18n_zh(label_key, kind), "enemy_waves": waves})
	return out


func _intent_pool_of(enc: Dictionary) -> Array:
	var out: Array = []
	for it in (enc.get("intent_pool", []) as Array):
		var d: Dictionary = it
		out.append({
			"id": String(d.get("id", "")),
			"display_name": String(d.get("display_name", "")),
			"weight": float(d.get("weight_attack", 0.0)),
			"weight_defend": float(d.get("weight_defend", 0.0)),
			"note": String(d.get("note", "")),
			"source_encounter": String(enc.get("id", "")),
		})
	return out


func _enemy_buildings_of(shell: Dictionary, enc: Dictionary) -> Array:
	var sz := ShellStore.size_of(shell)
	var out: Array = []
	for row in (enc.get("tile_buildings", []) as Array):
		var d: Dictionary = row
		var p := ShellStore.tile_by_index(shell, int(d.get("tile", -1)))
		if p.is_empty():
			continue
		out.append({
			"tile": int(d.get("tile", 0)),
			"building": String(d.get("building", "")),
			"star": float(d.get("star", 1)),
			"yaw": float(d.get("yaw", 0.0)),
			"x": clampf(0.5 + float(p.get("x", 0.0)) / maxf(sz.x, 0.001), 0.0, 1.0),
			"y": clampf(0.5 + float(p.get("z", 0.0)) / maxf(sz.y, 0.001), 0.0, 1.0),
		})
	return out


## 生成/刷新该组合的关卡与组装条目（写内存；写盘由 save_all 负责）。
func generate_assembly(shell_id: String, layout_id: String, encounter_id: String) -> Dictionary:
	var lv := compose_level(shell_id, layout_id, encounter_id)
	if lv.is_empty():
		return {}
	var arr := levels_list()
	var idx := level_index(String(lv["id"]))
	if idx >= 0:
		arr[idx] = lv
	else:
		arr.append(lv)
	var asm := {
		"id": assembly_id_of(layout_id, encounter_id),
		"display_name": String(lv.get("display_name", "")),
		"shell": shell_id,
		"player_layout": layout_id,
		"enemy_encounter": encounter_id,
		"level": String(lv.get("id", "")),
		"generated": true,
	}
	var list := assemblies()
	var replaced := false
	for i in list.size():
		if String((list[i] as Dictionary).get("id", "")) == String(asm["id"]):
			list[i] = asm
			replaced = true
			break
	if not replaced:
		list.append(asm)
	if not levels.has("assemblies"):
		levels["assemblies"] = list
	return asm

# ===========================================================================
# 校验
# ===========================================================================
func validate() -> Array:
	var out: Array = []
	out.append(_check("editor.check.units", _validate_units()))
	out.append(_check("editor.check.attrs", _validate_attrs()))
	out.append(_check("editor.check.buildings", _validate_buildings()))
	out.append(_check("editor.check.deck", _validate_deck()))
	out.append(_check("editor.check.shells", _validate_shells()))
	out.append(_check("editor.check.spine", _validate_spine()))
	out.append(_check("editor.check.tiles", _validate_tiles()))
	out.append(_check("editor.check.layouts", _validate_layouts()))
	out.append(_check("editor.check.encounters", _validate_encounters()))
	out.append(_check("editor.check.assemblies", _validate_assemblies()))
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


func _validate_shells() -> Array:
	var list := shell_list()
	if list.is_empty():
		return [false, "shells=0"]
	var bad: Array = []
	for s in list:
		bad.append_array(ShellStore.validate_shell(s as Dictionary))
	return [bad.is_empty(), "; ".join(bad.slice(0, 3))]


func _validate_spine() -> Array:
	var bad: Array = []
	for s in shell_list():
		var shell: Dictionary = s
		var spine: Dictionary = shell.get("spine", {})
		var width_logic := float(spine.get("width_logic", 0.0))
		if width_logic < 100.0 or width_logic > 999.0:
			bad.append(String(shell.get("id", "")) + " width_logic")
		if (spine.get("points", []) as Array).size() < 2:
			bad.append(String(shell.get("id", "")) + " spine points")
	return [bad.is_empty(), "; ".join(bad.slice(0, 3))]


func _validate_tiles() -> Array:
	var bad: Array = []
	for s in shell_list():
		var shell: Dictionary = s
		var gap := ShellStore.min_gap_meters(shell)
		if gap < ShellStore.MIN_GAP_M:
			bad.append(String(shell.get("id", "")) + " gap=%.2f" % gap)
		var keeps := {"player": 0, "enemy": 0}
		for p in ShellStore.tiles(shell):
			var d: Dictionary = p
			if String(d.get("role", "")) == "keep":
				var side := String(d.get("side", "player"))
				keeps[side] = int(keeps.get(side, 0)) + 1
		if int(keeps["player"]) != 1 or int(keeps["enemy"]) != 1:
			bad.append(String(shell.get("id", "")) + " keep tiles")
	return [bad.is_empty(), "; ".join(bad.slice(0, 3))]


func _validate_layouts() -> Array:
	var bad: Array = []
	if layout_kinds().size() != 3:
		bad.append("kinds=%d" % layout_kinds().size())
	var kinds := {}
	for l in layout_list():
		var d: Dictionary = l
		var shell := shell_by_id(String(d.get("shell", "")))
		if shell.is_empty():
			bad.append(String(d.get("id", "")) + " shell")
			continue
		var kind := String(d.get("kind", ""))
		kinds[kind] = true
		var act: Array = active_tiles(d)
		if act.is_empty():
			bad.append(String(d.get("id", "")) + " active empty")
		var counts := {"base": 0, "farm": 0, "barracks": 0}
		for idx in act:
			if ShellStore.tile_by_index(shell, int(idx)).is_empty():
				bad.append(String(d.get("id", "")) + " active " + str(idx))
			var slot := ShellStore.slot_at(d, int(idx))
			if slot.is_empty():
				bad.append(String(d.get("id", "")) + " slot " + str(idx))
				continue
			var b := building_by_id(String(slot.get("building", "")))
			if b.is_empty():
				bad.append(String(d.get("id", "")) + " building " + str(idx))
				continue
			var tag := String(b.get("tag", ""))
			if counts.has(tag):
				counts[tag] = int(counts[tag]) + 1
		if int(counts["base"]) != 1:
			bad.append(String(d.get("id", "")) + " keep slots")
		if kind == "even" and not (int(counts["farm"]) == 2 and int(counts["barracks"]) == 1):
			bad.append(String(d.get("id", "")) + " default preset")
		if String(d.get("inactive_render", "")) != "ruin":
			bad.append(String(d.get("id", "")) + " inactive_render")
	if kinds.size() != 3:
		bad.append("kinds=" + str(kinds.keys()))
	return [bad.is_empty(), "; ".join(bad.slice(0, 3))]


func _validate_encounters() -> Array:
	var bad: Array = []
	for e in encounter_list():
		var d: Dictionary = e
		var fac := String(d.get("faction", ""))
		var known := false
		for f in encounter_factions():
			if String((f as Dictionary).get("id", "")) == fac:
				known = true
		if not known:
			bad.append(String(d.get("id", "")) + " faction")
		if float(d.get("base_hp", 0.0)) <= 0.0:
			bad.append(String(d.get("id", "")) + " base_hp")
		var shell := shell_by_id(String(d.get("shell", "")))
		var seen := {}
		for row in (d.get("tile_buildings", []) as Array):
			var bd: Dictionary = row
			var idx := int(bd.get("tile", -1))
			if seen.has(idx):
				bad.append(String(d.get("id", "")) + " dup tile")
			seen[idx] = true
			var p := ShellStore.tile_by_index(shell, idx)
			if p.is_empty() or String(p.get("side", "")) != "enemy":
				bad.append(String(d.get("id", "")) + " tile " + str(idx))
			if building_by_id(String(bd.get("building", ""))).is_empty():
				bad.append(String(d.get("id", "")) + " building " + str(idx))
		var roles: Dictionary = d.get("unit_roles", {})
		for role in ["light", "line", "elite"]:
			var u := unit_by_id(String(roles.get(role, "")))
			if u.is_empty() or String(u.get("faction", "")) != fac or not bool(u.get("enabled", false)):
				bad.append(String(d.get("id", "")) + " role " + role)
		var sum_a := 0.0
		var sum_d := 0.0
		for it in (d.get("intent_pool", []) as Array):
			sum_a += float((it as Dictionary).get("weight_attack", 0.0))
			sum_d += float((it as Dictionary).get("weight_defend", 0.0))
		if absf(sum_a - 100.0) > 0.001 or absf(sum_d - 100.0) > 0.001:
			bad.append(String(d.get("id", "")) + " intents %.0f/%.0f" % [sum_a, sum_d])
	return [bad.is_empty(), "; ".join(bad.slice(0, 3))]


func _validate_assemblies() -> Array:
	var list := assemblies()
	if list.is_empty():
		return [false, "assemblies=0"]
	var bad: Array = []
	for a in list:
		var d: Dictionary = a
		var shell_id := String(d.get("shell", ""))
		var layout_id := String(d.get("player_layout", ""))
		var enc_id := String(d.get("enemy_encounter", ""))
		if shell_by_id(shell_id).is_empty() or layout_by_id(layout_id).is_empty() or encounter_by_id(enc_id).is_empty():
			bad.append(String(d.get("id", "")) + " ref")
		var lv := level_by_id(String(d.get("level", "")))
		if lv.is_empty():
			bad.append(String(d.get("id", "")) + " level")
			continue
		var asm: Dictionary = lv.get("assembly", {})
		var same := (String(asm.get("shell", "")) == shell_id
			and String(asm.get("player_layout", "")) == layout_id
			and String(asm.get("enemy_encounter", "")) == enc_id)
		if not same:
			bad.append(String(d.get("id", "")) + " level mismatch")
		if (lv.get("rounds", []) as Array).size() != 2:
			bad.append(String(d.get("id", "")) + " rounds")
	return [bad.is_empty(), "; ".join(bad.slice(0, 3))]


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
		"editor.cards.deck", "editor.tab.layouts", "editor.tab.encounters",
		"editor.tab.assembly", "editor.assembly.sim_run"]
	for key in need:
		if i18n_zh(key, "").is_empty():
			return [false, "missing " + key]
	return [true, "%d keys" % csv_rows.size()]


## 战术格子之间的最小边缘距离（米）——行军间隙的唯一口径。
func min_gap_meters(shell_id: String = "") -> float:
	var shell: Dictionary = {}
	if not shell_id.is_empty():
		shell = shell_by_id(shell_id)
	elif not shell_list().is_empty():
		shell = shell_list()[0] as Dictionary
	if shell.is_empty():
		return 0.0
	return ShellStore.min_gap_meters(shell)


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

# ===========================================================================
# 三分离：结构性修改（布局卡 / 遭遇卡 / 组装页调用）
# ===========================================================================
func unique_id(prefix: String, existing: Array) -> String:
	var n := 1
	while true:
		var cand := "%s_%d" % [prefix, n]
		var hit := false
		for v in existing:
			if String(v) == cand:
				hit = true
				break
		if not hit:
			return cand
		n += 1
	return prefix + "_1"


func new_layout() -> Dictionary:
	var ids: Array = []
	for l in layout_list():
		ids.append(String((l as Dictionary).get("id", "")))
	var id := unique_id("layout_new", ids)
	var shell: Dictionary = shell_list()[0] as Dictionary if not shell_list().is_empty() else {}
	var active: Array = []
	var slots: Array = []
	var n := 0
	for p in ShellStore.tiles(shell):
		var pd: Dictionary = p
		if String(pd.get("side", "")) != "player":
			continue
		n += 1
		active.append(int(pd.get("index", 0)))
		var tag := "keep" if n == 1 else ("farm" if n <= 3 else "barracks")
		slots.append({"tile": int(pd.get("index", 0)), "building": _building_for_tag(tag), "star": 1})
		if n >= 4:
			break
	var layout := {
		"id": id,
		"display_name": i18n_zh("editor.layouts.new_name", id),
		"kind": "even",
		"shell": String(shell.get("id", "")),
		"active_tiles": active,
		"slots": slots,
		"inactive_render": "ruin",
		"note": "",
	}
	layout_list().append(layout)
	return layout


func _building_for_tag(tag: String) -> String:
	for b in buildings():
		if String((b as Dictionary).get("tag", "")) == tag:
			return String((b as Dictionary).get("id", ""))
	var picked := buildings()
	return String((picked[0] as Dictionary).get("id", "farm")) if not picked.is_empty() else "farm"


func duplicate_layout(id: String) -> Dictionary:
	var src := layout_by_id(id)
	if src.is_empty():
		return {}
	var ids: Array = []
	for l in layout_list():
		ids.append(String((l as Dictionary).get("id", "")))
	var copy := src.duplicate(true)
	copy["id"] = unique_id("layout_copy", ids)
	copy["display_name"] = String(src.get("display_name", id)) + " " + i18n_zh("editor.common.copy", "copy")
	layout_list().append(copy)
	return copy


func remove_layout(id: String) -> bool:
	var arr := layout_list()
	for i in range(arr.size() - 1, -1, -1):
		if String((arr[i] as Dictionary).get("id", "")) == id:
			arr.remove_at(i)
			return true
	return false


func set_layout_kind(id: String, kind: String) -> bool:
	var layout := layout_by_id(id)
	if layout.is_empty() or kind_row(kind).is_empty():
		return false
	layout["kind"] = kind
	return true


func toggle_active_tile(layout_id: String, index: int) -> bool:
	var layout := layout_by_id(layout_id)
	if layout.is_empty():
		return false
	var act: Array = layout.get("active_tiles", [])
	for i in act.size():
		if int(act[i]) == index:
			act.remove_at(i)
			var slots: Array = layout.get("slots", [])
			for j in range(slots.size() - 1, -1, -1):
				if int((slots[j] as Dictionary).get("tile", -1)) == index:
					slots.remove_at(j)
			return true
	act.append(index)
	act.sort()
	var slots2: Array = layout.get("slots", [])
	slots2.append({"tile": index, "building": _default_building_for(layout), "star": 1})
	return true


func _default_building_for(layout: Dictionary) -> String:
	var counts := {"base": 0, "farm": 0, "barracks": 0}
	for row in (layout.get("slots", []) as Array):
		var b := building_by_id(String((row as Dictionary).get("building", "")))
		var tag := String(b.get("tag", ""))
		if counts.has(tag):
			counts[tag] = int(counts[tag]) + 1
	if int(counts["base"]) == 0:
		return _building_for_tag("base")
	if int(counts["farm"]) < 2:
		return _building_for_tag("farm")
	return _building_for_tag("barracks")


func set_slot_building(layout_id: String, index: int, building: String) -> bool:
	var layout := layout_by_id(layout_id)
	if layout.is_empty() or building_by_id(building).is_empty():
		return false
	var slot := ShellStore.slot_at(layout, index)
	if slot.is_empty():
		(layout.get("slots", []) as Array).append({"tile": index, "building": building, "star": 1})
		return true
	slot["building"] = building
	return true


func preset_layout(layout_id: String) -> bool:
	var layout := layout_by_id(layout_id)
	if layout.is_empty():
		return false
	var act: Array = layout.get("active_tiles", [])
	act.sort()
	var slots: Array = []
	var plan := ["keep", "farm", "farm", "barracks"]
	for i in act.size():
		var tag := String(plan[i]) if i < plan.size() else "farm"
		slots.append({"tile": int(act[i]), "building": _building_for_tag(tag), "star": 1})
	layout["slots"] = slots
	return true


func layout_counts(layout: Dictionary) -> Dictionary:
	var counts := {"base": 0, "farm": 0, "barracks": 0}
	for row in (layout.get("slots", []) as Array):
		var b := building_by_id(String((row as Dictionary).get("building", "")))
		var tag := String(b.get("tag", ""))
		if counts.has(tag):
			counts[tag] = int(counts[tag]) + 1
	return counts


func new_encounter() -> Dictionary:
	var ids: Array = []
	for e in encounter_list():
		ids.append(String((e as Dictionary).get("id", "")))
	var id := unique_id("enc_new", ids)
	var shell: Dictionary = shell_list()[0] as Dictionary if not shell_list().is_empty() else {}
	var rows: Array = []
	var n := 0
	for p in ShellStore.tiles(shell):
		var pd: Dictionary = p
		if String(pd.get("side", "")) != "enemy":
			continue
		n += 1
		rows.append({"tile": int(pd.get("index", 0)), "building": _building_for_tag("barracks"), "star": 1, "yaw": 180.0})
		if n >= 3:
			break
	var enc := {
		"id": id,
		"display_name": i18n_zh("editor.encounters.new_name", id),
		"faction": "bandit",
		"faction_display": faction_display_of("bandit"),
		"shell": String(shell.get("id", "")),
		"base_hp": 3000.0,
		"tile_buildings": rows,
		"unit_roles": {"light": "bandit_scout", "line": "bandit_marauder", "elite": "bandit_chief"},
		"intent_pool": [
			{"id": "probe", "display_name": i18n_zh("editor.encounters.intent_probe", "probe"),
				"weight_attack": 34.0, "weight_defend": 34.0, "note": ""},
			{"id": "press", "display_name": i18n_zh("editor.encounters.intent_press", "press"),
				"weight_attack": 33.0, "weight_defend": 33.0, "note": ""},
			{"id": "flank", "display_name": i18n_zh("editor.encounters.intent_flank", "flank"),
				"weight_attack": 33.0, "weight_defend": 33.0, "note": ""},
		],
		"wave_plan": {},
		"note": "",
	}
	encounter_list().append(enc)
	return enc


func duplicate_encounter(id: String) -> Dictionary:
	var src := encounter_by_id(id)
	if src.is_empty():
		return {}
	var ids: Array = []
	for e in encounter_list():
		ids.append(String((e as Dictionary).get("id", "")))
	var copy := src.duplicate(true)
	copy["id"] = unique_id("enc_copy", ids)
	copy["display_name"] = String(src.get("display_name", id)) + " " + i18n_zh("editor.common.copy", "copy")
	encounter_list().append(copy)
	return copy


func remove_encounter(id: String) -> bool:
	var arr := encounter_list()
	for i in range(arr.size() - 1, -1, -1):
		if String((arr[i] as Dictionary).get("id", "")) == id:
			arr.remove_at(i)
			return true
	return false


## 换阵营时把波次角色一起换成该阵营的兵种：遭遇卡是唯一入口，不手填单位 id。
func set_encounter_faction(id: String, faction: String) -> bool:
	var enc := encounter_by_id(id)
	if enc.is_empty() or faction_display_of(faction).is_empty():
		return false
	enc["faction"] = faction
	enc["faction_display"] = faction_display_of(faction)
	var pool: Array = []
	for u in unit_list():
		var d: Dictionary = u
		if String(d.get("faction", "")) == faction and bool(d.get("enabled", false)):
			pool.append(d)
	pool.sort_custom(func(a, b): return float(a.get("hp", 0.0)) < float(b.get("hp", 0.0)))
	var roles: Dictionary = {}
	if pool.size() >= 3:
		roles["light"] = String(pool[0].get("id", ""))
		roles["line"] = String(pool[1].get("id", ""))
		roles["elite"] = String(pool[pool.size() - 1].get("id", ""))
	enc["unit_roles"] = roles
	return true


func encounter_tile_indices(enc: Dictionary) -> Array:
	var out: Array = []
	for row in (enc.get("tile_buildings", []) as Array):
		out.append(int((row as Dictionary).get("tile", -1)))
	return out


func add_encounter_building(enc: Dictionary, tile: int, building: String) -> bool:
	if enc.is_empty():
		return false
	for row in (enc.get("tile_buildings", []) as Array):
		if int((row as Dictionary).get("tile", -1)) == tile:
			(row as Dictionary)["building"] = building
			return true
	(enc.get("tile_buildings", []) as Array).append({
		"tile": tile, "building": building, "star": 1, "yaw": 180.0,
	})
	return true


func remove_encounter_building(enc: Dictionary, tile: int) -> void:
	var rows: Array = enc.get("tile_buildings", [])
	for i in range(rows.size() - 1, -1, -1):
		if int((rows[i] as Dictionary).get("tile", -1)) == tile:
			rows.remove_at(i)


func intent_sums(enc: Dictionary) -> Vector2:
	var a := 0.0
	var d := 0.0
	for it in (enc.get("intent_pool", []) as Array):
		a += float((it as Dictionary).get("weight_attack", 0.0))
		d += float((it as Dictionary).get("weight_defend", 0.0))
	return Vector2(a, d)


func assembly_win_rate(asm: Dictionary) -> float:
	return float(asm.get("last_win_rate", -1.0))


func set_assembly_win_rate(asm_id: String, rate: float, games: int) -> void:
	var asm := assembly_by_id(asm_id)
	if asm.is_empty():
		return
	asm["last_win_rate"] = rate
	asm["last_games"] = games
