@tool
extends Window
## **技能编辑器（配方卡）**：把 `代码/配置/卡/技能/*.tres` 做成"按模板出表单"的可视窗。
##
## ★ 三层积木 + 一张配方卡（玩家 2026-11-08 口径，详见 代码/配置/技能卡.gd 文件头）：
##   第 1 层 技能原子（代码/配置/原子/*.gd）—— 只描述效果
##   第 2 层 单位姿势（clip 名）—— 只描述动作
##   第 3 层 技能特效（代码/系统/技能特效.gd）—— 只描述光效
##   本窗口 = 编辑那张"配方卡"。
##
## 四条硬规矩（对应玩家第 26~29 条）：
##   ① **不暴露原子的原始字段**：表单按"技能模板"出（防御姿态 / 连发 / 特效触发），
##      模板到原子的翻译只写在 `_collect_atoms()` 一处；
##   ② **保存前校验**：动画 clip 在某个单位模型里存在、特效 id 已注册、数值范围、
##      单位归属、互斥组合 —— 有问题**红字**写进状态条，不许保存；
##   ③ **实时预览**：选中技能 → 在编辑器视口里摆一个临时模型，播该动作 + 该特效；
##   ④ **.tres 版本化**：保存就是写回原文件（git 能 diff / 能回滚），不做二进制打包。
##
## ⚠ 本文件不写 class_name（AGENTS.md §二），调用方用 preload 常量 + .call()。

const Spec := preload("res://代码/界面/界面规格.gd")
const EDITOR_THEME := preload("res://addons/map_editor/编辑器主题.tres")
const 皮肤 := preload("res://addons/map_editor/编辑器皮肤.gd")
const CARD_SCRIPT := preload("res://代码/配置/技能卡.gd")
const SKILL_TABLE := preload("res://代码/配置/技能表.gd")
const SKILL_FX := preload("res://代码/系统/技能特效.gd")
const UNIT_TABLE := preload("res://代码/配置/单位表.gd")

const DIR := "res://代码/配置/卡/技能/"
## 模板 id → 显示名
const TEMPLATES: Array = [
	["defense", "防御姿态（减伤 / 移速 / 攻速）"],
	["burst", "连发（发数 / 间隔 / 装填）"],
	["vfx", "特效触发（特效 id / 触发时机）"],
]
## 伤害类型词表（和 定位词表.ATTACK_TYPES 一致；这里只做下拉，不参与结算）
const DMG_TYPES: Array = ["无", "普通", "穿刺", "魔法", "攻城"]

var session = null
var _built: bool = false
var _syncing: bool = false
var _dirty: bool = false
var _card: Resource = null
var _cards: Array = []
var _tpl: String = "defense"

var _list: ItemList
var _form: VBoxContainer
var _status: Label
var _head: Label
var _tpl_pick: OptionButton
var _fields: Dictionary = {}
## 预览节点（编辑器视口里的临时模型）。名字不能叫 _preview —— 会和函数撞名
var _preview_root: Node3D = null
## 模型 → 动作名数组（glb 里真实存在的 clip；校验"动画白名单"用）
static var _anim_cache: Dictionary = {}


# ===========================================================================
# 构建
# ===========================================================================

func setup(p_session) -> void:
	session = p_session
	if _built:
		return
	_built = true
	title = "技能编辑器（配方卡：三层积木 + 触发）"
	exclusive = false
	transient = true
	min_size = Vector2i(720, 520)
	close_requested.connect(func() -> void: hide())
	_build()


func _build() -> void:
	皮肤.apply(EDITOR_THEME)
	theme = EDITOR_THEME
	var panel := PanelContainer.new()
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 10)
	v.add_child(head_row)
	_head = Spec.editor_label("技能卡", &"EditorTitle")
	head_row.add_child(_head)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(sp)
	head_row.add_child(Spec.editor_label(
			"三层积木（原子 / 动作 / 特效）+ 一张配方卡 → 保存校验 → 写回 .tres", &"EditorHint"))
	v.add_child(HSeparator.new())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)

	# --- 左：技能列表 + 按钮 ---
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(250, 0)
	left.add_theme_constant_override("separation", 6)
	body.add_child(left)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(250, 320)
	_list.item_selected.connect(_on_selected)
	left.add_child(_list)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 6)
	left.add_child(brow)
	var save := Spec.editor_button("保存")
	save.tooltip_text = "先校验，通过才写回这张 .tres（有问题下面红字列出来）"
	save.pressed.connect(_save)
	brow.add_child(save)
	var preview := Spec.editor_button("预览")
	preview.tooltip_text = "在编辑器视口里摆个临时模型，播这个动作 + 特效"
	preview.pressed.connect(_preview)
	brow.add_child(preview)

	# --- 右：表单 ---
	var right := ScrollContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(right)
	_form = VBoxContainer.new()
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_theme_constant_override("separation", 6)
	right.add_child(_form)

	_status = Spec.editor_label("", &"EditorHint")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(860, 0)
	v.add_child(_status)


func open() -> void:
	if not _built:
		return
	_scan()
	_sync_list()
	_popup_fit()


func _popup_fit() -> void:
	var need: Vector2i = Vector2i(get_contents_minimum_size())
	var avail := Vector2(1600.0, 900.0)
	if get_parent() != null:
		avail = get_parent().get_viewport_rect().size
	var w: int = maxi(need.x + 24, 980)
	var h: int = maxi(need.y + 24, 720)
	if avail.y > 300.0:
		h = mini(h, int(avail.y * 0.88))
	popup_centered()
	size = Vector2i(w, h)
	if get_parent() != null:
		var pr: Rect2 = get_parent().get_viewport_rect()
		position = Vector2i(pr.position + (pr.size - Vector2(size)) * 0.5)


# ===========================================================================
# 列表
# ===========================================================================

func _scan() -> void:
	_cards.clear()
	var dir := DirAccess.open(DIR)
	if dir == null:
		return
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for f in names:
		if not f.ends_with(".tres"):
			continue
		var res: Resource = load(DIR + f) as Resource
		if res == null:
			continue
		_cards.append({"path": DIR + f, "card": res})
	# 技能表也要看到新文件（它自己缓存了 defs）
	SKILL_TABLE.reload()


func _sync_list() -> void:
	if _list == null:
		return
	var keep: String = String(_card.resource_path) if _card != null else ""
	_syncing = true
	_list.clear()
	var sel: int = -1
	for i in range(_cards.size()):
		var e: Dictionary = _cards[i]
		var c: Resource = e["card"]
		_list.add_item("%s  ·  %s" % [String(c.get("display_name")), String(c.get("id"))])
		_list.set_item_tooltip(i, String(e["path"]))
		if keep != "" and String(e["path"]) == keep:
			sel = i
	if sel < 0 and not _cards.is_empty():
		sel = 0
	if sel >= 0:
		_list.select(sel)
		_syncing = false
		_load_card(_cards[sel]["card"] as Resource)
		return
	_syncing = false
	_card = null
	_head.text = "（读不到技能卡）"
	_status.text = "目录里没有技能卡：%s" % DIR


func _on_selected(index: int) -> void:
	if _syncing or index < 0 or index >= _cards.size():
		return
	if _dirty:
		_status.text = "上一条未保存的改动已丢弃"
	_load_card(_cards[index]["card"] as Resource)


func _load_card(res: Resource) -> void:
	if res == null:
		return
	_card = res
	_dirty = false
	_tpl = _infer_template(res)
	_rebuild_form()


## 从卡上的原子反推它属于哪个模板（用户不直接编辑原子，所以这里必须能认回来）
func _infer_template(card: Resource) -> String:
	var atoms: Array = card.get("atoms")
	for a in atoms:
		if a == null:
			continue
		if not (a.call("to_burst") as Dictionary).is_empty():
			return "burst"
		if not (a.call("to_block") as Dictionary).is_empty():
			return "defense"
	for a in atoms:
		if a != null and not (a.call("to_mods") as Array).is_empty():
			return "defense"
	return "vfx"


func _mark_dirty() -> void:
	if _syncing:
		return
	_dirty = true
	_update_head()


func _update_head() -> void:
	if _card == null:
		return
	var mark: String = " ●" if _dirty else ""
	_head.text = "%s%s" % [String(_card.get("display_name")), mark]
	title = "技能编辑器 · %s%s" % [String(_card.get("id")), mark]


# ===========================================================================
# 表单（按模板现建现拆）
# ===========================================================================

func _rebuild_form() -> void:
	if _form == null:
		return
	_syncing = true
	for c in _form.get_children():
		c.queue_free()
	_fields.clear()

	if _card == null:
		_syncing = false
		return

	# 模板选择（换模板 = 按新模板重建原子，旧的丢）
	var row0 := HBoxContainer.new()
	row0.add_theme_constant_override("separation", 8)
	_form.add_child(row0)
	row0.add_child(Spec.editor_label("技能模板", &"EditorSection"))
	_tpl_pick = OptionButton.new()
	_tpl_pick.custom_minimum_size = Vector2(320, 30)
	for t in TEMPLATES:
		_tpl_pick.add_item(String(t[1]))
		_tpl_pick.set_item_metadata(_tpl_pick.item_count - 1, String(t[0]))
	_tpl_pick.select(_tpl_index(_tpl))
	_tpl_pick.item_selected.connect(_on_template_picked)
	row0.add_child(_tpl_pick)

	_section("身份")
	_field_text("display_name", "名称", String(_card.get("display_name")))
	_field_text("id", "id（= 文件名，改它不会改文件名）", String(_card.get("id")))
	_field_multiline("note", "说明", String(_card.get("note")))

	_section("触发（这是卡的事，不是原子的事）")
	_field_option("kind", "触发方式", ["主动", "开关", "被动", "采集", "受击"], String(_card.get("kind")))
	_field_option("target", "对谁", ["无", "点", "单位", "资源"], String(_card.get("target")))
	_field_num("cooldown", "冷却（秒）", float(_card.get("cooldown")), 0.0, 120.0, 0.1)
	_field_text("hotkey", "快捷键（空 = 自动）", String(_card.get("hotkey")))

	match _tpl:
		"defense":
			_build_defense_form()
		"burst":
			_build_burst_form()
		_:
			_build_vfx_form()

	_syncing = false
	_update_head()


func _tpl_index(id: String) -> int:
	for i in range(TEMPLATES.size()):
		if String(TEMPLATES[i][0]) == id:
			return i
	return 0


func _on_template_picked(i: int) -> void:
	if _syncing or i < 0 or i >= TEMPLATES.size():
		return
	_tpl = String(TEMPLATES[i][0])
	_mark_dirty()
	_rebuild_form()


## 防御姿态：只出"减伤 / 移速 / 攻速 / 动作"这几个数（玩家点名要的表单）
func _build_defense_form() -> void:
	_section("效果（技能原子：属性倍率）")
	var dt: Dictionary = _stat_of("damage_taken")
	var mv: Dictionary = _stat_of("move_speed")
	var cd: Dictionary = _stat_of("attack_cooldown")
	_field_num("dmg_cut", "受到伤害 -%", (1.0 - float(dt.get("mul", 1.0))) * 100.0,
			0.0, 90.0, 1.0)
	_field_option("dmg_when", "只对某种伤害生效",
			DMG_TYPES, String(dt.get("when", "无")) if String(dt.get("when", "")) != "" else "无")
	_field_num("move_pct", "移速 %（负数 = 变慢）",
			(float(mv.get("mul", 1.0)) - 1.0) * 100.0, -90.0, 50.0, 5.0)
	_field_num("atkspd_pct", "攻速 %（负数 = 变慢）",
			(1.0 / maxf(float(cd.get("mul", 1.0)), 0.01) - 1.0) * 100.0, -90.0, 100.0, 5.0)
	_section("动作（三层积木第 2 层）")
	_field_text("anim_hold", "持续动作 clip（空 = 不覆盖待机）", String(_card.get("anim_hold")))
	_field_text("anim_on", "开启时播一次（可空）", String(_card.get("anim_on")))
	_field_text("anim_off", "关闭时播一次（可空）", String(_card.get("anim_off")))
	_section("特效（三层积木第 3 层）")
	_field_vfx("vfx_on", "开启特效", String(_card.get("vfx_on")))
	_field_vfx("vfx_off", "关闭特效", String(_card.get("vfx_off")))


## 连发：只出"发数 / 间隔 / 装填"
func _build_burst_form() -> void:
	_section("效果（技能原子：连发）")
	var b: Dictionary = _burst_of()
	_field_num("burst_shots", "一次打几发", float(b.get("shots", 3)), 2.0, 10.0, 1.0)
	_field_num("burst_interval", "两发间隔（秒）", float(b.get("interval", 0.12)), 0.02, 2.0, 0.02)
	_field_num("burst_reload", "打完装填（秒）", float(b.get("reload", 0.0)), 0.0, 10.0, 0.1)
	_section("动作 / 特效")
	_field_text("anim_on", "攻击时附带的动作（常填 reload，可空）", String(_card.get("anim_on")))
	_field_vfx("vfx_on", "开火特效", String(_card.get("vfx_on")))


## 特效触发：只出"特效 id / 触发时机"
func _build_vfx_form() -> void:
	_section("效果（这张卡不带数值原子）")
	_form.add_child(Spec.editor_label(
			"空卡 = 只挂表现。要让它在单位身上「有效果」，把触发方式改成 受击/开关 并换成别的模板。",
			&"EditorHint"))
	_section("特效（三层积木第 3 层）")
	_field_vfx("vfx_on", "开启/触发特效", String(_card.get("vfx_on")))
	_field_vfx("vfx_off", "关闭特效", String(_card.get("vfx_off")))
	_section("动作")
	_field_text("anim_on", "触发时播一次（可空）", String(_card.get("anim_on")))


func _section(title_text: String) -> void:
	var h := HSeparator.new()
	_form.add_child(h)
	_form.add_child(Spec.editor_label(title_text, &"EditorSection"))


func _row() -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	_form.add_child(r)
	return r


func _field_text(key: String, label: String, value: String) -> void:
	var r := _row()
	var lb := Spec.editor_label(label, &"EditorHint")
	lb.custom_minimum_size = Vector2(280, 0)
	r.add_child(lb)
	var le := LineEdit.new()
	le.text = value
	le.custom_minimum_size = Vector2(340, 30)
	le.text_changed.connect(func(_t: String) -> void: _mark_dirty())
	r.add_child(le)
	_fields[key] = le


func _field_multiline(key: String, label: String, value: String) -> void:
	var r := _row()
	var lb := Spec.editor_label(label, &"EditorHint")
	lb.custom_minimum_size = Vector2(280, 0)
	r.add_child(lb)
	var te := TextEdit.new()
	te.text = value
	te.custom_minimum_size = Vector2(340, 64)
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.text_changed.connect(func() -> void: _mark_dirty())
	r.add_child(te)
	_fields[key] = te


func _field_num(key: String, label: String, value: float,
		lo: float, hi: float, step: float) -> void:
	var r := _row()
	var lb := Spec.editor_label(label, &"EditorHint")
	lb.custom_minimum_size = Vector2(280, 0)
	r.add_child(lb)
	var se := SpinBox.new()
	se.min_value = lo
	se.max_value = hi
	se.step = step
	se.value = clampf(value, lo, hi)
	se.custom_minimum_size = Vector2(140, 30)
	se.value_changed.connect(func(_v: float) -> void: _mark_dirty())
	r.add_child(se)
	_fields[key] = se
	# 范围提示（校验同源，改这里就两端一起变）
	r.add_child(Spec.editor_label("（%.0f ~ %.0f）" % [lo, hi], &"EditorHint"))


func _field_option(key: String, label: String, items: Array, value: String) -> void:
	var r := _row()
	var lb := Spec.editor_label(label, &"EditorHint")
	lb.custom_minimum_size = Vector2(280, 0)
	r.add_child(lb)
	var ob := OptionButton.new()
	ob.custom_minimum_size = Vector2(180, 30)
	var sel: int = 0
	for i in range(items.size()):
		ob.add_item(String(items[i]))
		if String(items[i]) == value:
			sel = i
	ob.select(sel)
	ob.item_selected.connect(func(_i: int) -> void: _mark_dirty())
	r.add_child(ob)
	_fields[key] = ob


## 特效下拉：只列已注册的 id（`技能特效.ids()`），外加"空"
func _field_vfx(key: String, label: String, value: String) -> void:
	var items: Array = ["（空）"]
	for id in SKILL_FX.ids():
		items.append(String(id))
	var shown: String = value if value != "" else "（空）"
	_field_option(key, label, items, shown)


# ===========================================================================
# 表单 → 原子（**模板到原子的翻译只在这一个函数里**）
# ===========================================================================

func _stat_of(stat: String) -> Dictionary:
	for a in _card.get("atoms"):
		if a == null:
			continue
		for m in a.call("to_mods"):
			if String(m.get("stat", "")) == stat:
				var out: Dictionary = m.duplicate()
				out["when"] = String(m.get("when", ""))
				return out
	return {}


func _burst_of() -> Dictionary:
	for a in _card.get("atoms"):
		if a == null:
			continue
		var b: Dictionary = a.call("to_burst")
		if not b.is_empty():
			return b
	return {}


## 按当前模板把表单值翻译成原子数组。**这里是唯一的翻译点。**
func _collect_atoms() -> Array:
	var out: Array = []
	match _tpl:
		"defense":
			var cut: float = float(_field_value("dmg_cut", 15.0)) / 100.0
			var when: String = String(_field_value("dmg_when", "无"))
			if cut > 0.001:
				out.append(_stat_atom("damage_taken", 1.0 - cut,
						"" if when == "无" else when))
			var mv: float = float(_field_value("move_pct", 0.0)) / 100.0
			if absf(mv) > 0.001:
				out.append(_stat_atom("move_speed", 1.0 + mv, ""))
			var sp: float = float(_field_value("atkspd_pct", 0.0)) / 100.0
			if absf(sp) > 0.001:
				out.append(_stat_atom("attack_cooldown", 1.0 / maxf(1.0 + sp, 0.05), ""))
		"burst":
			var a: SkillAtom = _new_atom("res://代码/配置/原子/原子_连发.gd")
			a.set("atom_id", &"连发")
			a.set("shots", int(_field_value("burst_shots", 3)))
			a.set("interval", float(_field_value("burst_interval", 0.12)))
			a.set("reload", float(_field_value("burst_reload", 0.0)))
			out.append(a)
		_:
			pass
	return out


func _stat_atom(stat: String, mul: float, when: String) -> SkillAtom:
	var a: SkillAtom = _new_atom("res://代码/配置/原子/原子_属性.gd")
	a.set("atom_id", StringName("减伤") if stat == "damage_taken" else StringName("属性"))
	a.set("stat", StringName(stat))
	a.set("mul", mul)
	if when != "":
		a.set("when", StringName(when))
	return a


func _new_atom(path: String) -> SkillAtom:
	var s: Script = load(path)
	return s.new() as SkillAtom


func _field_value(key: String, fallback: Variant) -> Variant:
	var c: Variant = _fields.get(key)
	if c == null:
		return fallback
	if c is LineEdit:
		return (c as LineEdit).text
	if c is TextEdit:
		return (c as TextEdit).text
	if c is SpinBox:
		return (c as SpinBox).value
	if c is OptionButton:
		var ob := c as OptionButton
		return ob.get_item_text(ob.selected)
	return fallback


# ===========================================================================
# 保存 + 校验
# ===========================================================================

func _save() -> void:
	if _card == null:
		return
	var errs: Array = []
	var warns: Array = []
	_collect_into_card()
	errs.append_array(_validate(warns))

	if not errs.is_empty():
		_status.text = "保存被拒绝：\n· " + "\n· ".join(errs)
		_status.add_theme_color_override("font_color", Color(1.0, 0.42, 0.36))
		return

	var path: String = String(_card.resource_path)
	if path == "":
		path = DIR + String(_card.get("id")) + ".tres"
	var e: int = ResourceSaver.save(_card, path)
	if e != 0:
		_status.text = "写盘失败（err=%d）：%s" % [e, path]
		_status.add_theme_color_override("font_color", Color(1.0, 0.42, 0.36))
		return
	_dirty = false
	_update_head()
	SKILL_TABLE.reload()
	var warn_txt: String = "" if warns.is_empty() else "\n提醒：\n· " + "\n· ".join(warns)
	_status.text = "已保存 %s%s" % [path, warn_txt]
	_status.add_theme_color_override("font_color", Color(0.62, 0.92, 0.62))



## 把表单值写回 Resource（不落盘）
func _collect_into_card() -> void:
	_card.set("display_name", String(_field_value("display_name", "")))
	_card.set("id", StringName(String(_field_value("id", ""))))
	_card.set("note", String(_field_value("note", "")))
	_card.set("kind", String(_field_value("kind", "主动")))
	_card.set("target", String(_field_value("target", "无")))
	_card.set("cooldown", float(_field_value("cooldown", 0.0)))
	_card.set("hotkey", String(_field_value("hotkey", "")))
	_card.set("anim_on", StringName(String(_field_value("anim_on", ""))))
	_card.set("anim_hold", StringName(String(_field_value("anim_hold", ""))))
	_card.set("anim_off", StringName(String(_field_value("anim_off", ""))))
	_card.set("vfx_on", _vfx_of("vfx_on"))
	_card.set("vfx_off", _vfx_of("vfx_off"))
	var atoms: Array = _collect_atoms()
	var typed: Array[SkillAtom] = []
	for a in atoms:
		typed.append(a)
	_card.set("atoms", typed)


func _vfx_of(key: String) -> StringName:
	var s: String = String(_field_value(key, "（空）"))
	if s == "" or s == "（空）":
		return &""
	return StringName(s)


## **保存前校验**（玩家第 27 条）。返回错误列表（红字），warns 里放"提醒但不拦"的。
func _validate(warns: Array) -> Array:
	var errs: Array = []
	var id: String = String(_card.get("id"))
	if id.strip_edges() == "":
		errs.append("id 不能为空")
	for e in _cards:
		var other: Resource = e["card"]
		if other == _card:
			continue
		if String(other.get("id")) == id:
			errs.append("id 撞车：%s 已经被另一张卡用了" % id)
			break

	# 数值范围（和表单的 SpinBox 同一组上下限）
	var cd: float = float(_card.get("cooldown"))
	if cd < 0.0 or cd > 120.0:
		errs.append("冷却 %.1fs 超出 0~120" % cd)
	var kind: String = String(_card.get("kind"))
	if not ["主动", "开关", "被动", "采集", "受击"].has(kind):
		errs.append("触发方式「%s」不在词表里" % kind)

	# 原子参数
	var cut: float = 0.0
	var move_pct: float = 0.0
	var atk_pct: float = 0.0
	var shots: int = 0
	for a in _card.get("atoms"):
		if a == null:
			continue
		for m in a.call("to_mods"):
			var st: String = String(m.get("stat", ""))
			var mul: float = float(m.get("mul", 1.0))
			if mul <= 0.0 or mul > 5.0:
				errs.append("%s 的倍率 %.2f 超出 0.01~5.00" % [st, mul])
			if st == "damage_taken":
				cut = maxf(cut, (1.0 - mul) * 100.0)
			elif st == "move_speed":
				move_pct = (mul - 1.0) * 100.0
			elif st == "attack_cooldown":
				atk_pct = (1.0 / maxf(mul, 0.01) - 1.0) * 100.0
			elif st == "armor":
				if absf(mul) > 20.0:
					errs.append("护甲加成 %.1f 太大（上限 ±20）" % mul)
			elif st not in ["damage_dealt", "attack_range"]:
				errs.append("未知属性「%s」（词表见 技能运行时）" % st)
		var b: Dictionary = a.call("to_burst")
		if not b.is_empty():
			shots = int(b.get("shots", 0))
			if shots < 2 or shots > 10:
				errs.append("连发发数 %d 超出 2~10" % shots)
			var iv: float = float(b.get("interval", 0.12))
			if iv < 0.02 or iv > 2.0:
				errs.append("连发间隔 %.2fs 超出 0.02~2.00" % iv)
			var rl: float = float(b.get("reload", 0.0))
			if rl < 0.0 or rl > 10.0:
				errs.append("装填 %.1fs 超出 0~10" % rl)
	if cut > 90.0:
		errs.append("减伤 %.0f%% 太大（上限 90%%，否则等于无敌）" % cut)
	if move_pct < -90.0:
		errs.append("移速惩罚 %.0f%% 太狠（下限 -90%%）" % move_pct)
	if atk_pct < -90.0 or atk_pct > 100.0:
		errs.append("攻速修正 %.0f%% 超出 -90%%~+100%%" % atk_pct)

	# 互斥组合：同一张卡既减伤又连发 —— 举盾降攻速 + 连发会互相打架
	if cut > 0.0 and shots > 0:
		errs.append("互斥：同一张卡不能既「减伤姿态」又「连发」（一个降攻速、一个要连打）")

	# 动画白名单：clip 必须在**某个单位模型**里真的存在
	for key in ["anim_on", "anim_hold", "anim_off"]:
		var clip: StringName = _card.get(key)
		if clip == &"":
			continue
		if not _clip_exists_anywhere(String(clip)):
			errs.append("动作「%s」在美术/模型 的所有单位 glb 里都找不到（%s）" % [String(clip), key])

	# 特效必须注册过
	for key in ["vfx_on", "vfx_off"]:
		var fx: StringName = _card.get(key)
		if fx == &"":
			continue
		if not bool(SKILL_FX.has(fx)):
			errs.append("特效「%s」没在 代码/系统/技能特效.gd 注册" % String(fx))

	# 单位归属：谁挂了这个技能（提示，不拦）
	var owners: Array = _owners_of(id)
	if owners.is_empty():
		warns.append("还没有任何单位卡挂这个技能（UnitCard.skills 里加 id 才会生效）")
	else:
		warns.append("挂着这张卡的单位：%s" % ", ".join(owners))

	# 跨卡互斥：同一单位挂两个开关技能 → 会抢同一个姿态
	var map: Dictionary = _skill_map_by_unit()
	for uname in map.keys():
		var n: int = 0
		for sid in map[uname]:
			if SKILL_TABLE.is_toggle(StringName(sid)):
				n += 1
		if n >= 2:
			warns.append("单位「%s」挂了 %d 个开关技能（同一次只能开一个姿态，确认是有意的）"
					% [String(uname), n])
	return errs


## 单位名 → [技能 id]
func _skill_map_by_unit() -> Dictionary:
	var out: Dictionary = {}
	var cards: Dictionary = UNIT_TABLE.load_cards()
	for cid in cards.keys():
		var c: Resource = cards[cid]
		var sk: Variant = c.get("skills")
		if sk is Array:
			out[String(c.get("display_name"))] = sk
	return out


## 哪些单位卡挂了这张技能
func _owners_of(id: String) -> Array:
	var out: Array = []
	var cards: Dictionary = UNIT_TABLE.load_cards()
	for cid in cards.keys():
		var c: Resource = cards[cid]
		var sk: Variant = c.get("skills")
		if sk is Array and (sk as Array).has(StringName(id)):
			out.append(String(c.get("display_name")))
	return out


## 动作名在**任意一个单位模型**里存在 → 算合法。
## 直接读 glb 的 JSON chunk（不解码网格），第一次扫完缓存。
func _clip_exists_anywhere(clip: String) -> bool:
	if _anim_cache.is_empty():
		_scan_all_anims()
	for path in _anim_cache.keys():
		if (_anim_cache[path] as Array).has(clip):
			return true
	return false


func _scan_all_anims() -> void:
	var roots: Array = ["res://美术/模型/", "res://美术/模型/方块人/", "res://美术/模型/野怪/"]
	for r in roots:
		var d := DirAccess.open(String(r))
		if d == null:
			continue
		for f in d.get_files():
			if not f.ends_with(".glb"):
				continue
			_anim_cache[String(r) + f] = _glb_anims(String(r) + f)


## 读 glb 里的动画名（纯 JSON chunk，不碰二进制）
func _glb_anims(path: String) -> Array:
	var out: Array = []
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return out
	var data: PackedByteArray = fa.get_buffer(fa.get_length())
	fa.close()
	if data.size() < 20:
		return out
	# GLB 头 12 字节；第 1 个 chunk 是 JSON
	var clen: int = data.decode_u32(12)
	var ctype: int = data.decode_u32(16)
	if ctype != 0x4E4F534A:
		return out
	var txt: String = data.slice(20, 20 + clen).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return out
	for a in (parsed as Dictionary).get("animations", []):
		if a is Dictionary:
			out.append(String((a as Dictionary).get("name", "")))
	return out


# ===========================================================================
# 实时预览（玩家第 28 条）
# ===========================================================================

## 在编辑器视口里摆一个临时模型，播这个动作 + 特效，2.5 秒后自动清掉。
func _preview() -> void:
	if _card == null:
		_clear_preview()
		return
	_collect_into_card()
	var model_path: String = _pick_preview_model()
	if model_path == "":
		_status.text = "预览失败：找不到可用模型"
		return
	var art: Script = load("res://代码/美术/美术接口.gd")
	var model: Node3D = art.call("build_model", model_path, 1.0)
	if model == null:
		_status.text = "预览失败：%s 实例化不出来" % model_path
		return
	_clear_preview()
	_preview_root = Node3D.new()
	_preview_root.name = "技能预览"
	var root: Node = _editor_root()
	if root == null:
		_status.text = "预览失败：编辑器视口还没就绪"
		return
	root.add_child(_preview_root)
	_preview_root.add_child(model)
	_preview_root.global_position = _preview_pos()
	var sk: Node = art.call("attach_anim", model) as Node
	var clip: StringName = _card.get("anim_hold")
	if clip == &"":
		clip = _card.get("anim_on")
	if sk != null and clip != &"" and sk.has_method("has_state") \
			and bool(sk.call("has_state", String(clip))):
		sk.call("play", String(clip), 1.0, false)
	# 特效：vfx 层只认位置，这里用模型胸口高度
	var fx: StringName = _card.get("vfx_on")
	if fx != &"":
		var vfx: Script = load("res://代码/美术/特效生成.gd")
		vfx.call("weapon_glint", _preview_root.global_position + Vector3.UP * 1.1)
	# 2.5 秒后清掉（预览不该留在地图上）
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 2.5
	_preview_root.add_child(tm)
	tm.timeout.connect(_clear_preview)
	tm.start()
	_status.text = "预览：%s ｜ 动作 %s ｜ 特效 %s" % [
		model_path.get_file(), String(clip) if clip != &"" else "（无）",
		String(fx) if fx != &"" else "（无）"]
	_status.add_theme_color_override("font_color", Color(0.86, 0.86, 0.80))


func _clear_preview() -> void:
	if _preview_root != null and is_instance_valid(_preview_root):
		_preview_root.queue_free()
	_preview_root = null


## 预览用哪只模型：优先"挂了这张卡的单位"，否则用步兵
func _pick_preview_model() -> String:
	var id: String = String(_card.get("id"))
	var cards: Dictionary = UNIT_TABLE.load_cards()
	for cid in cards.keys():
		var c: Resource = cards[cid]
		var sk: Variant = c.get("skills")
		if sk is Array and (sk as Array).has(StringName(id)):
			var mp: String = String(c.get("model_path"))
			if mp != "" and ResourceLoader.exists(mp):
				return mp
	var fallback: Resource = cards.get("footman")
	if fallback != null:
		return String(fallback.get("model_path"))
	return ""


func _editor_root() -> Node:
	if session == null:
		return null
	var vp: Variant = session.get("viewport")
	if vp == null or not is_instance_valid(vp):
		return null
	var r: Variant = vp.get("objects_root")
	return r as Node


func _preview_pos() -> Vector3:
	# 摆在地图中心附近（视口相机默认也看那儿），不污染真实对象
	return Vector3(0.0, 0.0, 0.0)
