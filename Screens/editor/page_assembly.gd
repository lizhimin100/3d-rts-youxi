@tool
extends Control
## 05 · 战斗节点组装（levels.json）
## 属于：Screens/editor（开发工具，不进发行版）
##
## 口径：只做三个下拉框 [地图底壳 ID] + [玩家布局卡 ID] + [敌人遭遇卡 ID]，
##       一键 compose_level 生成完整可玩关卡并写回 Content/data/levels.json；
##       当场点「跑 50 局」调 Tests/sim/run_simulate.gd --simulate --level=<id> --out=<file>，
##       用 --out 的 SIM summary 显示该组合胜率（不抓 stdout）。

const ThemeKit := preload("res://Screens/editor/dev_theme.gd")
const ShellStore := preload("res://Screens/editor/shell_store.gd")

const SIM_SCRIPT := "res://Tests/sim/run_simulate.gd"
const SIM_DIR := "res://.test_profile/sim"
const SIM_GAMES := 50

var editor: Control = null
var data: RefCounted = null

var _shell_opt: OptionButton = null
var _layout_opt: OptionButton = null
var _enc_opt: OptionButton = null
var _level_chip: PanelContainer = null
var _summary_box: VBoxContainer = null
var _asm_box: VBoxContainer = null
var _asm_count: Label = null
var _sim_label: Label = null
var _sim_bar: ProgressBar = null
var _sim_timer: Timer = null
var _sim_level := ""
var _sim_ticks := 0
var _pending := false


func setup(p_editor: Control, p_data: RefCounted) -> void:
	editor = p_editor
	data = p_data
	if get_child_count() > 0:
		return
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var head := ThemeKit.section_head(T("editor.assembly.title"), T("editor.assembly.eyebrow"), ThemeKit.GREEN)
	_level_chip = ThemeKit.chip("", ThemeKit.GREEN)
	head.add_child(_level_chip)
	root.add_child(head)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	body.add_child(_build_composer())
	body.add_child(_build_result())

	_sim_timer = Timer.new()
	_sim_timer.one_shot = false
	_sim_timer.wait_time = 0.4
	_sim_timer.timeout.connect(_poll_sim)
	add_child(_sim_timer)
	refresh()


func refresh() -> void:
	_rebuild_options()
	_refresh_preview()
	_rebuild_assemblies()


func T(key: String, params: Dictionary = {}) -> String:
	return String(editor.call("T", key, params)) if editor != null else key


# ===========================================================================
# 左：三选一组合台
# ===========================================================================
func _build_composer() -> Control:
	var panel := ThemeKit.card(ThemeKit.GREEN, 16.0, 14)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	v.add_child(ThemeKit.caption(T("editor.assembly.compose_hint"), ThemeKit.TEXT_DIM))
	v.add_child(_combo_row(T("editor.assembly.shell"), "asm_shell", true))
	v.add_child(_combo_row(T("editor.assembly.layout"), "asm_layout", false))
	v.add_child(_combo_row(T("editor.assembly.encounter"), "asm_encounter", false))

	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 8)
	var gen := ThemeKit.small_button(T("editor.assembly.generate"), ThemeKit.GREEN)
	gen.name = "asm_generate"
	gen.custom_minimum_size = Vector2(178.0, 36.0)
	gen.pressed.connect(_on_generate)
	ops.add_child(gen)
	var sim := ThemeKit.small_button(T("editor.assembly.sim_run"), ThemeKit.ACCENT)
	sim.name = "asm_sim_run"
	sim.custom_minimum_size = Vector2(196.0, 36.0)
	sim.pressed.connect(_on_run_sim)
	ops.add_child(sim)
	ops.add_child(ThemeKit.spacer())
	v.add_child(ops)

	_sim_bar = ProgressBar.new()
	_sim_bar.show_percentage = false
	_sim_bar.custom_minimum_size = Vector2(0.0, 6.0)
	_sim_bar.max_value = 1.0
	_sim_bar.value = 0.0
	_sim_bar.add_theme_stylebox_override("background", ThemeKit.box(Color("#111722"), ThemeKit.STROKE, 3, 0, 0.0, 0.0))
	_sim_bar.add_theme_stylebox_override("fill", ThemeKit.box(ThemeKit.ACCENT, Color(0, 0, 0, 0), 3, 0, 0.0, 0.0))
	v.add_child(_sim_bar)
	_sim_label = ThemeKit.caption(T("editor.assembly.sim_idle"), ThemeKit.TEXT_DIM)
	_sim_label.name = "asm_sim_result"
	_sim_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_sim_label)

	v.add_child(ThemeKit.hairline())
	var preview := ThemeKit.inset()
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(preview)
	_summary_box = VBoxContainer.new()
	_summary_box.add_theme_constant_override("separation", 6)
	preview.add_child(_summary_box)
	return panel


func _combo_row(title: String, node_name: String, is_shell: bool) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var l := ThemeKit.field_label(title)
	l.custom_minimum_size = Vector2(120.0, 0.0)
	h.add_child(l)
	var opt := OptionButton.new()
	opt.name = node_name
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.custom_minimum_size = Vector2(0.0, 36.0)
	opt.item_selected.connect(_on_option_changed.bind(is_shell))
	h.add_child(opt)
	if is_shell:
		_shell_opt = opt
	elif node_name == "asm_layout":
		_layout_opt = opt
	else:
		_enc_opt = opt
	return h


func _rebuild_options() -> void:
	var keep_shell := _selected_id(_shell_opt)
	var keep_layout := _selected_id(_layout_opt)
	var keep_enc := _selected_id(_enc_opt)
	_fill(_shell_opt, data.call("shell_list"), "id", "display_name", keep_shell)
	var shell := _selected_id(_shell_opt)
	_fill(_layout_opt, data.call("layouts_of_shell", shell), "id", "display_name", keep_layout)
	_fill(_enc_opt, data.call("encounters_of_shell", shell), "id", "display_name", keep_enc)


func _fill(opt: OptionButton, rows: Array, id_key: String, text_key: String, keep: String) -> void:
	if opt == null:
		return
	opt.clear()
	var pick := 0
	for i in rows.size():
		var d: Dictionary = rows[i]
		var id := String(d.get(id_key, ""))
		opt.add_item(String(d.get(text_key, id)) + "  ·  " + id)
		opt.set_item_metadata(i, id)
		if id == keep:
			pick = i
	if rows.is_empty():
		opt.add_item(T("editor.assembly.none"))
		opt.set_item_metadata(0, "")
	opt.select(clampi(pick, 0, maxi(opt.item_count - 1, 0)))


func _selected_id(opt: OptionButton) -> String:
	if opt == null or opt.item_count == 0 or opt.selected < 0:
		return ""
	return String(opt.get_item_metadata(opt.selected))


func _combo() -> Array:
	return [_selected_id(_shell_opt), _selected_id(_layout_opt), _selected_id(_enc_opt)]


# ===========================================================================
# 右：组合清单
# ===========================================================================
func _build_result() -> Control:
	var panel := ThemeKit.card(ThemeKit.ACCENT, 14.0, 14)
	panel.custom_minimum_size = Vector2(520.0, 0.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(ThemeKit.label(T("editor.assembly.list"), &"EditorH3"))
	head.add_child(ThemeKit.spacer())
	_asm_count = ThemeKit.caption("", ThemeKit.TEXT_DIM)
	head.add_child(_asm_count)
	v.add_child(head)
	var sub := ThemeKit.caption(T("editor.assembly.list_hint"), ThemeKit.TEXT_DIM)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_asm_box = VBoxContainer.new()
	_asm_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asm_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_asm_box)
	v.add_child(ThemeKit.hairline())
	var foot := ThemeKit.caption(T("editor.assembly.foot"), ThemeKit.TEXT_DIM)
	foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(foot)
	return panel


func _rebuild_assemblies() -> void:
	for c in _asm_box.get_children():
		c.queue_free()
	var list: Array = data.call("assemblies")
	_asm_count.text = T("editor.layouts.list_count", {"n": list.size()})
	for a in list:
		var d: Dictionary = a
		var asm_id := String(d.get("id", ""))
		var row := ThemeKit.inset(ThemeKit.INPUT, ThemeKit.STROKE, 10.0, 9)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		row.add_child(h)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 1)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(ThemeKit.label(String(d.get("display_name", asm_id)), &"EditorH3"))
		v.add_child(ThemeKit.caption(String(d.get("level", "")) + "  ·  " + asm_id, ThemeKit.TEXT_DIM))
		h.add_child(v)
		var rate := float(d.get("last_win_rate", -1.0))
		var games := int(d.get("last_games", 0))
		var chip := ThemeKit.chip(T("editor.assembly.rate_none") if rate < 0.0 else T("editor.assembly.rate_value", {
			"v": "%.1f%%" % (rate * 100.0), "n": games
		}), ThemeKit.TEXT_DIM if rate < 0.0 else (ThemeKit.GREEN if rate >= 0.5 else ThemeKit.RED))
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(chip)
		var pick := ThemeKit.small_button(T("editor.assembly.pick"), ThemeKit.ACCENT)
		pick.custom_minimum_size = Vector2(62.0, 30.0)
		pick.pressed.connect(_on_pick_assembly.bind(d))
		h.add_child(pick)
		_asm_box.add_child(row)


# ===========================================================================
# 预览
# ===========================================================================
func _refresh_preview() -> void:
	for c in _summary_box.get_children():
		c.queue_free()
	var combo := _combo()
	var lv: Dictionary = data.call("compose_level", combo[0], combo[1], combo[2])
	if lv.is_empty():
		ThemeKit.set_chip(_level_chip, T("editor.assembly.invalid"), ThemeKit.RED)
		_summary_box.add_child(ThemeKit.caption(T("editor.assembly.invalid_hint"), ThemeKit.RED))
		return
	ThemeKit.set_chip(_level_chip, String(lv.get("id", "")), ThemeKit.GREEN)
	var lane: Dictionary = lv.get("lane", {})
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 6)
	chips.add_child(ThemeKit.chip(T("editor.assembly.lane_length", {
		"v": "%.0f" % float(lane.get("length", 0.0)), "m": "%.1f" % (float(lane.get("length", 0.0)) * ShellStore.R1)
	}), ThemeKit.CYAN))
	chips.add_child(ThemeKit.chip(T("editor.assembly.lane_width", {
		"v": "%.0f" % float(lane.get("width", 0.0)), "m": "%.2f" % (float(lane.get("width", 0.0)) * ShellStore.R1)
	}), ThemeKit.CYAN))
	chips.add_child(ThemeKit.chip(T("editor.assembly.lane_zone", {
		"v": "%.0f" % float(lane.get("zone_depth", 0.0)), "m": "%.1f" % (float(lane.get("zone_depth", 0.0)) * ShellStore.R1)
	}), ThemeKit.GOLD))
	_summary_box.add_child(chips)

	var segs: Array = lane.get("segments", [])
	var bars := HBoxContainer.new()
	bars.add_theme_constant_override("separation", 2)
	var total := maxf(float(lane.get("length", 1.0)), 1.0)
	var colors := [ThemeKit.ACCENT, ThemeKit.CYAN, ThemeKit.RED]
	for i in segs.size():
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0.0, 10.0)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_stretch_ratio = maxf(float((segs[i] as Dictionary).get("length", 1.0)) / total, 0.02)
		bar.max_value = total
		bar.value = float((segs[i] as Dictionary).get("length", 0.0))
		var col: Color = colors[mini(i, colors.size() - 1)]
		bar.add_theme_stylebox_override("background", ThemeKit.box(Color("#111722"), ThemeKit.STROKE, 3, 0, 0.0, 0.0))
		bar.add_theme_stylebox_override("fill", ThemeKit.box(col, Color(0, 0, 0, 0), 3, 0, 0.0, 0.0))
		bars.add_child(bar)
	_summary_box.add_child(bars)

	var board: Dictionary = lv.get("player_board", {})
	var parts: Array[String] = []
	for idx in (board.get("active_tiles", []) as Array):
		var slot := ShellStore.slot_at(board, int(idx))
		parts.append("P%d %s" % [int(idx), String(data.call("building_display", String(slot.get("building", ""))))])
	_summary_box.add_child(ThemeKit.caption(T("editor.assembly.slots") + ": " + ", ".join(parts), ThemeKit.TEXT_SUB))

	var enemy_parts: Array[String] = []
	for row in (lv.get("enemy_buildings", []) as Array):
		var d: Dictionary = row
		enemy_parts.append("E%d %s x%.0f" % [int(d.get("tile", 0)), String(data.call("building_display", String(d.get("building", "")))), float(d.get("star", 1.0))])
	_summary_box.add_child(ThemeKit.caption(T("editor.assembly.enemy") + ": " + String(data.call("faction_display_of", String(lv.get("enemy_faction", "")))) + "  HP %.0f  |  " % float(lv.get("enemy_base_hp", 0.0)) + ", ".join(enemy_parts), ThemeKit.TEXT_SUB))

	var atk: Array[String] = []
	var dfn: Array[String] = []
	for it in (lv.get("intent_pool", []) as Array):
		var d2: Dictionary = it
		atk.append("%s %.0f" % [String(d2.get("display_name", "")), float(d2.get("weight", 0.0))])
		dfn.append("%s %.0f" % [String(d2.get("display_name", "")), float(d2.get("weight_defend", 0.0))])
	_summary_box.add_child(ThemeKit.caption(T("editor.encounters.attack") + ": " + ", ".join(atk), ThemeKit.RED))
	_summary_box.add_child(ThemeKit.caption(T("editor.encounters.defend") + ": " + ", ".join(dfn), ThemeKit.ACCENT))
	var rounds: Array = lv.get("rounds", [])
	_summary_box.add_child(ThemeKit.caption(T("editor.assembly.rounds", {
		"a": (rounds[0] as Dictionary).get("enemy_waves", []).size() if rounds.size() > 0 else 0,
		"d": (rounds[1] as Dictionary).get("enemy_waves", []).size() if rounds.size() > 1 else 0,
	}), ThemeKit.TEXT_DIM))


# ===========================================================================
# 事件
# ===========================================================================
func _on_option_changed(_index: int, is_shell: bool) -> void:
	if is_shell:
		var shell := _selected_id(_shell_opt)
		_fill(_layout_opt, data.call("layouts_of_shell", shell), "id", "display_name", "")
		_fill(_enc_opt, data.call("encounters_of_shell", shell), "id", "display_name", "")
	_refresh_preview()


func _on_pick_assembly(asm: Dictionary) -> void:
	_rebuild_options()
	var shell := String(asm.get("shell", ""))
	var layout := String(asm.get("player_layout", ""))
	var enc := String(asm.get("enemy_encounter", ""))
	_select_by_meta(_shell_opt, shell)
	_fill(_layout_opt, data.call("layouts_of_shell", shell), "id", "display_name", layout)
	_fill(_enc_opt, data.call("encounters_of_shell", shell), "id", "display_name", enc)
	_refresh_preview()
	_sim_level = String(asm.get("level", ""))
	_sim_label.text = T("editor.assembly.sim_ready", {"id": _sim_level})


func _select_by_meta(opt: OptionButton, id: String) -> void:
	if opt == null:
		return
	for i in opt.item_count:
		if String(opt.get_item_metadata(i)) == id:
			opt.select(i)
			return


func _on_generate() -> void:
	var combo := _combo()
	var asm: Dictionary = data.call("generate_assembly", combo[0], combo[1], combo[2])
	if asm.is_empty():
		_sim_label.text = T("editor.assembly.generate_failed")
		return
	editor.call("mark_dirty")
	if editor.has_method("save_now"):
		editor.call("save_now")
	_rebuild_assemblies()
	_refresh_preview()
	_sim_level = String(asm.get("level", ""))
	_sim_label.text = T("editor.assembly.generated", {"id": _sim_level})


## 确保当前组合已经生成过（否则 --level 找不到该关卡）。
func _ensure_assembly() -> String:
	var combo := _combo()
	var asm: Dictionary = data.call("generate_assembly", combo[0], combo[1], combo[2])
	if asm.is_empty():
		return ""
	editor.call("mark_dirty")
	if editor.has_method("save_now"):
		editor.call("save_now")
	return String(asm.get("level", ""))


func _on_run_sim() -> void:
	var level_id := _ensure_assembly()
	if level_id.is_empty():
		_sim_label.text = T("editor.assembly.generate_failed")
		return
	_sim_level = level_id
	var dir := ProjectSettings.globalize_path(SIM_DIR)
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var out_path := dir.path_join(level_id + ".json")
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)
	var args := PackedStringArray([
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", SIM_SCRIPT,
		"--",
		"--games=%d" % SIM_GAMES,
		"--seed=1",
		"--level=" + level_id,
		"--out=" + out_path,
	])
	var pid := OS.create_process(OS.get_executable_path(), args)
	_sim_ticks = 0
	_sim_bar.value = 0.0
	if pid <= 0:
		_sim_label.text = T("editor.assembly.sim_spawn_failed")
		return
	_sim_label.text = T("editor.assembly.sim_running", {"id": level_id, "n": SIM_GAMES})
	_sim_timer.start()


func _poll_sim() -> void:
	_sim_ticks += 1
	_sim_bar.value = clampf(float(_sim_ticks) / 150.0, 0.0, 0.95)
	var out_path := ProjectSettings.globalize_path(SIM_DIR).path_join(_sim_level + ".json")
	if FileAccess.file_exists(out_path):
		var f := FileAccess.open(out_path, FileAccess.READ)
		if f == null:
			return
		var text := f.get_as_text()
		f.close()
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			_finish_sim(parsed as Dictionary)
			return
		return
	if _sim_ticks >= 150:
		_sim_timer.stop()
		_sim_bar.value = 0.0
		_sim_label.text = T("editor.assembly.sim_timeout")


func _finish_sim(summary: Dictionary) -> void:
	_sim_timer.stop()
	_sim_bar.value = 1.0
	if not bool(summary.get("ok", false)):
		_sim_label.text = T("editor.assembly.sim_failed", {"e": String(summary.get("error", "unknown"))})
		return
	var rate := float(summary.get("win_rate", 0.0))
	var games := int(summary.get("games", 0))
	_sim_label.text = T("editor.assembly.sim_done", {
		"w": int(summary.get("wins", 0)),
		"l": int(summary.get("losses", 0)),
		"d": int(summary.get("draws", 0)),
		"r": "%.1f" % (rate * 100.0),
		"t": "%.1f" % float(summary.get("avg_seconds", 0.0)),
	})
	var combo := _combo()
	var asm_id := String(data.call("assembly_id_of", combo[1], combo[2]))
	data.call("set_assembly_win_rate", asm_id, rate, games)
	editor.call("mark_dirty")
	_rebuild_assemblies()
