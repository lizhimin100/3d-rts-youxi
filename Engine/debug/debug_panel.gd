extends CanvasLayer
## 职责：调试面板（F12 开关）—— 只读状态 + 两个安全按钮
## 属于：Engine/debug（发行构建不打包）
## 铁律：面板里改数值必须走 DebugTuner 写回 Content/data/*.json，不许只改内存。

const Screenshot := preload("res://Engine/debug/screenshot.gd")

var _label: Label
var _visible_panel := false


func _ready() -> void:
	layer = 200
	_build()
	visible = false
	set_process(true)


func _build() -> void:
	var panel := PanelContainer.new()
	panel.name = "调试面板"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(12, 12)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	_label = Label.new()
	_label.name = "状态"
	_label.add_theme_font_size_override("font_size", 12)
	vb.add_child(_label)
	var row := HBoxContainer.new()
	vb.add_child(row)
	var shot := Button.new()
	shot.text = I18n.t("debug.panel.shot")
	shot.pressed.connect(func() -> void:
		var p := Screenshot.capture(Screenshot.default_dir() + "panel-%d.png" % Time.get_ticks_msec())
		print("[Dbg] 截图 → " + p))
	row.add_child(shot)
	var quit_btn := Button.new()
	quit_btn.text = I18n.t("debug.panel.quit")
	quit_btn.pressed.connect(func() -> void: get_tree().quit(0))
	row.add_child(quit_btn)
	add_child(panel)


func _process(_dt: float) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		# ui_cancel 是 ESC；F12 单独判，避免和游戏暂停冲突
		pass
	if Input.is_key_pressed(KEY_F12) and not _f12_was_down:
		_f12_was_down = true
		_visible_panel = not _visible_panel
		visible = _visible_panel
	elif not Input.is_key_pressed(KEY_F12):
		_f12_was_down = false
	if visible and _label != null:
		_label.text = I18n.t("debug.panel.fps", {"fps": Engine.get_frames_per_second()}) + "\n" + _status_text()


var _f12_was_down := false


func _status_text() -> String:
	var lines: Array[String] = []
	lines.append(I18n.t("debug.panel.mode", {"mode": "test" if App.test_mode else "dev", "profile": App.profile}))
	if DbgBridge != null and DbgBridge.is_running():
		lines.append(I18n.t("debug.panel.bridge", {"url": DbgBridge.base_url()}))
	else:
		lines.append(I18n.t("debug.panel.bridge_off"))
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var game := (loop as SceneTree).root.get_node_or_null("Game")
		if game != null:
			lines.append(I18n.t("debug.panel.phase", {"phase": str(game.get("phase")), "t": "%.1f" % float(game.get("elapsed"))}))
			var faction: Variant = game.get("player_faction")
			if faction != null:
				lines.append(I18n.t("debug.panel.economy", {
					"gold": str(faction.get("gold")), "wood": str(faction.get("wood")),
					"pop": str(faction.get("food_used"))}))
	return "\n".join(lines)
