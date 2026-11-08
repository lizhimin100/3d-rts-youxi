@tool
extends Window
## **卡片编辑器**：把 `代码/配置/卡/单位/` 与 `.../建筑/` 下的 .tres 做成可视表单。
##
## 为什么要它（玩家口径「我要自己配单位/建筑，不想手改文本」）：
##   卡是数值唯一真相源（见 单位卡.gd / 建筑卡.gd），但一直是"只有写代码的人会改"的
##   纯文本 .tres。这里给出左列表 + 右表单：改完直接写回原文件。
##
## 两个窗口共用这一份脚本：主屏建两份实例，分别 setup(session, "unit"/"building")。
##
## 设计取舍：
##   · **表单按选中项现建现拆** —— 单位卡与建筑卡字段不同，留一套"隐藏/显示"很容易漏；
##   · 控件不逐键写回 Resource，**保存时统一 collect** —— 半截输入（比如把 1 删成空）
##     不会立刻污染数据，也不会有"改一个字就存一次盘"的抖动；
##   · 建筑卡的 trains 与单位卡的"由哪些建筑训练"是**同一个关系的两面**，
##     保存单位卡时在这里统一同步，避免两边各写一半后互相打架。
##
## ⚠ 本文件不写 class_name（AGENTS.md §二），调用方用 preload 常量 + .call()。

const Spec := preload("res://代码/界面/界面规格.gd")
const EDITOR_THEME := preload("res://addons/map_editor/编辑器主题.tres")
## 皮肤（深铁石底 + 金线）：在 .tres 实例上就地改写，资源路径不变
const 皮肤 := preload("res://addons/map_editor/编辑器皮肤.gd")
const UNIT_TABLE := preload("res://代码/配置/单位表.gd")
const LW := preload("res://代码/配置/定位词表.gd")

const CARD_DIR_UNIT := "res://代码/配置/卡/单位/"
const CARD_DIR_BUILDING := "res://代码/配置/卡/建筑/"

var session = null
## "unit" / "building"
var _kind: String = "unit"
var _built: bool = false
## 回填表单时挡住"改动"信号，避免一开窗就被标成脏
var _syncing: bool = false
var _dirty: bool = false
## 当前正在编辑的卡（Resource；null = 没选中）
var _card: Resource = null
## 左侧列表数据：[{path, card, name, id}]
var _cards: Array = []

var _list: ItemList
var _form: VBoxContainer
var _status: Label
var _head: Label
var _alert: AcceptDialog = null

## 表单字段：key → 控件（保存时统一取值）
var _fields: Dictionary = {}
## 多选：单位卡的"由哪些建筑训练" [{id, box}]
var _checks_build_for_unit: Array = []
## 多选：建筑卡的 trains / researches [{id, box}]
var _checks_train: Array = []
var _checks_research: Array = []


# ===========================================================================
# 构建
# ===========================================================================

func setup(p_session, kind: String = "unit") -> void:
	session = p_session
	_kind = kind
	if _built:
		return
	_built = true
	title = "单位卡编辑器" if _kind == "unit" else "建筑卡编辑器"
	exclusive = false
	transient = true
	min_size = Vector2i(640, 480)
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
	_head = Spec.editor_label("", &"EditorTitle")
	head_row.add_child(_head)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(sp)
	var hint := Spec.editor_label("左选一张卡 → 右边改 → 保存写回 .tres", &"EditorHint")
	head_row.add_child(hint)

	v.add_child(HSeparator.new())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)

	# --- 左：卡列表 + 底部按钮 ---
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(230, 0)
	left.add_theme_constant_override("separation", 6)
	body.add_child(left)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(230, 320)
	_list.item_selected.connect(_on_selected)
	left.add_child(_list)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 6)
	left.add_child(brow)
	var save := Spec.editor_button("保存")
	save.tooltip_text = "写回这张 .tres，并刷新卡缓存"
	save.pressed.connect(_save)
	brow.add_child(save)
	# ★ 2026-11-08 玩家口径：「编辑器内可新建单位/建筑配置卡，名字、各字段我自己填；
	#   卡本身就是单位数据介绍，模型/美术/音频到位直接填，新单位就出现。不用改代码。」
	var newb := Spec.editor_button("新建")
	newb.tooltip_text = "新建一张空卡（自动起 id），填完模型路径保存就进对象页"
	newb.pressed.connect(_create_card)
	brow.add_child(newb)
	var test := Spec.editor_button("测试地图")
	test.tooltip_text = "保存后启动游戏试玩（有未保存改动会先提醒）"
	test.pressed.connect(_test)
	brow.add_child(test)

	# --- 右：表单（滚动） ---
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
	_status.custom_minimum_size = Vector2(820, 0)
	v.add_child(_status)


# ===========================================================================
# 打开 / 列表
# ===========================================================================

## 快捷条按钮点进来。每次打开都重扫目录：外面（git/文本编辑器）改过也能看到。
func open() -> void:
	if not _built:
		return
	_scan()
	_sync_list()
	_popup_fit()


## 打开时才算尺寸（窗口进树前设的 size 会被引擎丢掉，只剩 min_size → 内容被裁）
func _popup_fit() -> void:
	var need: Vector2i = Vector2i(get_contents_minimum_size())
	var avail := Vector2(1600.0, 900.0)
	if get_parent() != null:
		avail = get_parent().get_viewport_rect().size
	var w: int = maxi(need.x + 24, 900)
	var h: int = maxi(need.y + 24, 700)
	if avail.y > 300.0:
		h = mini(h, int(avail.y * 0.86))
	# ⚠ 顺序：popup_centered() 会把 size 压回 min_size（实测），必须先弹再改大小再居中
	popup_centered()
	size = Vector2i(w, h)
	if get_parent() != null:
		var pr: Rect2 = get_parent().get_viewport_rect()
		position = Vector2i(pr.position + (pr.size - Vector2(size)) * 0.5)


func _dir() -> String:
	return CARD_DIR_UNIT if _kind == "unit" else CARD_DIR_BUILDING


## 读一个卡目录（按文件名排序，保证每次顺序一致）
func _load_dir(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for f in names:
		if not f.ends_with(".tres"):
			continue
		var res: Resource = load(dir_path + f) as Resource
		if res == null:
			continue
		out.append({"path": dir_path + f, "card": res})
	return out


func _scan() -> void:
	_cards.clear()
	for e in _load_dir(_dir()):
		var res: Resource = e["card"]
		_cards.append({
			"path": String(e["path"]),
			"card": res,
			"name": String(res.get("display_name")),
			"id": String(res.get("card_id")),
		})


func _sync_list() -> void:
	if _list == null:
		return
	var keep_path: String = String(_card.resource_path) if _card != null else ""
	_syncing = true
	_list.clear()
	var sel: int = -1
	for i in range(_cards.size()):
		var e: Dictionary = _cards[i]
		_list.add_item("%s  ·  %s" % [String(e["name"]), String(e["id"])])
		_list.set_item_tooltip(i, String(e["path"]))
		if not keep_path.is_empty() and String(e["path"]) == keep_path:
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
	_head.text = "（这张卡读不出来）"
	_status.text = "目录里没有可编辑的卡：%s" % _dir()


func _on_selected(index: int) -> void:
	if _syncing or index < 0 or index >= _cards.size():
		return
	if _dirty:
		# 不弹模态挡住操作，但必须说清楚：换卡 = 丢掉上一张没保存的改动
		_status.text = "上一条未保存的改动已丢弃"
	var e: Dictionary = _cards[index]
	_load_card(e["card"] as Resource)


func _load_card(res: Resource) -> void:
	if res == null:
		return
	_card = res
	_dirty = false
	_rebuild_form()


func _mark_dirty() -> void:
	if _syncing:
		return
	_dirty = true
	_update_head()


func _update_head() -> void:
	if _card == null:
		return
	var tail: String = "   ●未保存" if _dirty else ""
	_head.text = "%s  ·  %s%s" % [String(_card.get("display_name")),
		String(_card.get("card_id")), tail]


# ===========================================================================
# 表单
# ===========================================================================

func _rebuild_form() -> void:
	if _form == null:
		return
	_syncing = true
	for c in _form.get_children():
		_form.remove_child(c)
		c.queue_free()
	_fields.clear()
	_checks_build_for_unit.clear()
	_checks_train.clear()
	_checks_research.clear()
	if _card == null:
		_syncing = false
		return
	if _kind == "unit":
		_build_unit_form()
	else:
		_build_building_form()
	_syncing = false
	_update_head()
	_status.text = "编辑中：%s（保存后重开测试地图生效）" % String(_card.resource_path).get_file()


func _build_unit_form() -> void:
	_section("基本")
	var g := _grid()
	_fields["display_name"] = _line(g, "显示名", _s("display_name"), "列表 / 游戏内铭牌上的名字")
	_fields["description"] = _multiline(g, "介绍", _s("description"))
	g.add_child(Spec.editor_label("卡 id（不可改）"))
	g.add_child(Spec.editor_label(_s("card_id"), &"EditorHint"))

	_section("生命 / 法力")
	g = _grid()
	_fields["max_hp"] = _num(g, "血量 max_hp", _f("max_hp"), 1.0, 99999.0, 1.0)
	_fields["max_mana"] = _num(g, "蓝量 max_mana", _f("max_mana"), 0.0, 9999.0, 1.0)

	_section("攻击")
	g = _grid()
	_fields["attack_type"] = _opt(g, "攻击类型", LW.ATTACK_TYPES, _s("attack_type"), "参与伤害结算，只能从词表取词")
	_fields["attack"] = _num(g, "攻击力 attack", _f("attack"), 0.0, 9999.0, 1.0)
	_fields["attack_cooldown"] = _num(g, "攻击间隔（秒）", _f("attack_cooldown", 1.5), 0.05, 60.0, 0.05,
		"每次攻击之间的冷却（秒 / 次）")
	# ★ 2026-11-08 玩家实测「弩兵/步兵的攻击范围显示 80」：上限原来写死 80，
	#   650 / 90 一进表单就被夹成 80 —— 而且**保存时会把这个 80 写回卡里**。
	#   现在上限 3000（箭塔 870 的 3 倍），步进 5，提示直接算成米。
	_fields["range"] = _num(g, "攻击范围 range（游戏数值）", _f("range"), 0.0, 3000.0, 5.0,
		"游戏射程数值：米数 = 这个值 × 0.015。步兵 90 = 1.35m、火枪手 550 = 8.25m、弩兵 650 = 9.75m、箭塔 870 = 13.05m。")

	_section("防御 / 移动")
	g = _grid()
	_fields["defense_type"] = _opt(g, "防御类型", LW.DEFENSE_TYPES, _s("defense_type"), "参与伤害结算，只能从词表取词")
	_fields["defense"] = _num(g, "防御力 defense", _f("defense"), 0.0, 999.0, 1.0)
	_fields["move_speed"] = _num(g, "移动速度", _f("move_speed", 4.0), 0.0, 40.0, 0.1)

	_section("成本 / 训练")
	g = _grid()
	_fields["cost_gold"] = _num(g, "金币花费", _f("cost_gold"), 0.0, 99999.0, 5.0)
	_fields["cost_wood"] = _num(g, "木材花费", _f("cost_wood"), 0.0, 99999.0, 5.0)
	_fields["train_time"] = _num(g, "训练时间（秒）", _f("train_time", 10.0), 0.1, 600.0, 0.5)

	_section("由哪些建筑训练")
	hint_label("这张表是建筑卡 trains 的反向关系：勾上保存 = 把那座建筑的可训练列表加上这个单位；取消 = 从列表里移除。")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 4)
	_form.add_child(flow)
	var uid: String = _s("card_id")
	for e in _load_dir(CARD_DIR_BUILDING):
		var b: Resource = e["card"]
		if b == null:
			continue
		var bid: String = String(b.get("card_id"))
		var box := CheckBox.new()
		box.text = "%s（%s）" % [String(b.get("display_name")), bid]
		box.button_pressed = _array_has_str(b.get("trains"), uid)
		box.toggled.connect(func(_on: bool) -> void: _mark_dirty())
		flow.add_child(box)
		_checks_build_for_unit.append({"id": bid, "box": box})


func _build_building_form() -> void:
	_section("基本")
	var g := _grid()
	_fields["display_name"] = _line(g, "显示名", _s("display_name"), "列表 / 游戏内铭牌上的名字")
	_fields["description"] = _multiline(g, "介绍", _s("description"))
	g.add_child(Spec.editor_label("卡 id（不可改）"))
	g.add_child(Spec.editor_label(_s("card_id"), &"EditorHint"))

	_section("生命 / 防御")
	g = _grid()
	_fields["max_hp"] = _num(g, "血量 max_hp", _f("max_hp"), 1.0, 999999.0, 10.0)
	_fields["defense"] = _num(g, "防御力 defense", _f("defense"), 0.0, 999.0, 1.0)
	_fields["defense_type"] = _opt(g, "防御类型", LW.DEFENSE_TYPES, _s("defense_type"), "参与伤害结算，只能从词表取词")

	_section("占地 / 建造")
	g = _grid()
	var fp: Variant = _card.get("footprint")
	var fx: int = 1
	var fy: int = 1
	if fp is Vector2i:
		fx = (fp as Vector2i).x
		fy = (fp as Vector2i).y
	_fields["footprint_x"] = _num(g, "占地 X（格）", float(fx), 1.0, 20.0, 1.0, "1 格 = 1 米")
	_fields["footprint_y"] = _num(g, "占地 Y（格）", float(fy), 1.0, 20.0, 1.0, "1 格 = 1 米")
	_fields["train_time"] = _num(g, "建造耗时（秒）", _f("train_time", 10.0), 0.1, 600.0, 0.5)
	_fields["food_provided"] = _num(g, "提供人口", _f("food_provided"), 0.0, 200.0, 1.0)

	_section("成本")
	g = _grid()
	_fields["cost_gold"] = _num(g, "金币花费", _f("cost_gold"), 0.0, 99999.0, 5.0)
	_fields["cost_wood"] = _num(g, "木材花费", _f("cost_wood"), 0.0, 99999.0, 5.0)

	_section("攻击 / 视野")
	g = _grid()
	_fields["attack"] = _num(g, "攻击力 attack", _f("attack"), 0.0, 9999.0, 1.0, "0 = 不能攻击（如农场/哨塔）")
	_fields["range"] = _num(g, "射程 range（游戏数值）", _f("range"), 0.0, 3000.0, 5.0)
	_fields["attack_cooldown"] = _num(g, "攻击间隔（秒）", _f("attack_cooldown", 1.5), 0.05, 60.0, 0.05)
	_fields["sight_range"] = _num(g, "视野 sight_range", _f("sight_range", 10.0), 0.0, 120.0, 0.5)

	_section("可训练单位（trains）")
	hint_label("勾上 = 这座建筑能训练该单位。改单位卡里的「由哪些建筑训练」也会同步到这里。")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 4)
	_form.add_child(flow)
	for e in _load_dir(CARD_DIR_UNIT):
		var u: Resource = e["card"]
		if u == null:
			continue
		var uid: String = String(u.get("card_id"))
		var box := CheckBox.new()
		box.text = "%s（%s）" % [String(u.get("display_name")), uid]
		box.button_pressed = _array_has_str(_card.get("trains"), uid)
		box.toggled.connect(func(_on: bool) -> void: _mark_dirty())
		flow.add_child(box)
		_checks_train.append({"id": uid, "box": box})

	_section("可研究项目（researches）")
	var rflow := HFlowContainer.new()
	rflow.add_theme_constant_override("h_separation", 10)
	rflow.add_theme_constant_override("v_separation", 4)
	_form.add_child(rflow)
	var researches: Dictionary = UNIT_TABLE.build_researches()
	for key in researches:
		var r: Resource = researches[key] as Resource
		if r == null:
			continue
		var rid: String = String(key)
		var rbox := CheckBox.new()
		rbox.text = String(r.get("display_name"))
		rbox.button_pressed = _array_has_str(_card.get("researches"), rid)
		rbox.toggled.connect(func(_on: bool) -> void: _mark_dirty())
		rflow.add_child(rbox)
		_checks_research.append({"id": rid, "box": rbox})


# --- 表单小工厂 ---

func _section(text: String) -> void:
	if _form.get_child_count() > 0:
		_form.add_child(HSeparator.new())
	_form.add_child(Spec.editor_label(text, &"EditorAccent"))


func _grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 5)
	_form.add_child(g)
	return g


func hint_label(text: String) -> void:
	var l := Spec.editor_label(text, &"EditorHint")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(600, 0)
	_form.add_child(l)


func _line(parent: GridContainer, label: String, value: String, tip: String = "") -> LineEdit:
	parent.add_child(Spec.editor_label(label))
	var le := LineEdit.new()
	le.text = value
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tip.is_empty():
		le.tooltip_text = tip
	le.text_changed.connect(func(_t: String) -> void: _mark_dirty())
	parent.add_child(le)
	return le


func _multiline(parent: GridContainer, label: String, value: String) -> TextEdit:
	parent.add_child(Spec.editor_label(label))
	var te := TextEdit.new()
	te.text = value
	te.custom_minimum_size = Vector2(0, 64)
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.text_changed.connect(func() -> void: _mark_dirty())
	parent.add_child(te)
	return te


func _num(parent: GridContainer, label: String, value: float, min_v: float, max_v: float,
		step: float, tip: String = "") -> SpinBox:
	parent.add_child(Spec.editor_label(label))
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = clampf(value, min_v, max_v)
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tip.is_empty():
		sb.tooltip_text = tip
	sb.value_changed.connect(func(_v: float) -> void: _mark_dirty())
	parent.add_child(sb)
	return sb


func _opt(parent: GridContainer, label: String, words: Array, current: String,
		tip: String = "") -> OptionButton:
	parent.add_child(Spec.editor_label(label))
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tip.is_empty():
		ob.tooltip_text = tip
	for w in words:
		ob.add_item(String(w))
		ob.set_item_metadata(ob.item_count - 1, StringName(String(w)))
		if String(w) == current:
			ob.select(ob.item_count - 1)
	if ob.selected < 0 and ob.item_count > 0:
		ob.select(0)
	ob.item_selected.connect(func(_i: int) -> void: _mark_dirty())
	parent.add_child(ob)
	return ob


# ===========================================================================
# 取值 / 保存
# ===========================================================================

## 从一个控件取值（控件类型决定读法；缺失的 key 一律返回 null，由调用方兜底）
func _val(key: String) -> Variant:
	var c: Variant = _fields.get(key)
	if c == null:
		return null
	if c is LineEdit:
		return (c as LineEdit).text
	if c is TextEdit:
		return (c as TextEdit).text
	if c is SpinBox:
		return (c as SpinBox).value
	if c is OptionButton:
		var ob := c as OptionButton
		return ob.get_item_metadata(ob.selected) if ob.selected >= 0 else null
	return null


func _val_f(key: String, def: float) -> float:
	var v: Variant = _val(key)
	return float(v) if v != null else def


func _val_s(key: String, def: String) -> String:
	var v: Variant = _val(key)
	if v == null:
		return def
	var s: String = String(v)
	return s if not s.is_empty() else def


func _save() -> void:
	if _card == null:
		_status.text = "先在左边选一张卡"
		return
	var path: String = String(_card.resource_path)
	if path.is_empty():
		_status.text = "这张卡没有文件路径（不是从目录里读出来的），无法写回"
		return

	# --- 公共字段 ---
	_card.set("display_name", _val_s("display_name", String(_card.get("card_id"))))
	var desc: Variant = _val("description")
	_card.set("description", String(desc) if desc != null else "")
	_card.set("cost_gold", int(round(_val_f("cost_gold", 0.0))))
	_card.set("cost_wood", int(round(_val_f("cost_wood", 0.0))))
	_card.set("train_time", _val_f("train_time", 10.0))

	if _kind == "unit":
		var atk := _val("attack_type")
		if atk != null:
			_card.set("attack_type", StringName(String(atk)))
		var dtype := _val("defense_type")
		if dtype != null:
			_card.set("defense_type", StringName(String(dtype)))
		_card.set("max_hp", _val_f("max_hp", 100.0))
		_card.set("max_mana", _val_f("max_mana", 0.0))
		_card.set("attack", int(round(_val_f("attack", 0.0))))
		_card.set("attack_cooldown", _val_f("attack_cooldown", 1.5))
		_card.set("range", _val_f("range", 0.0))
		_card.set("defense", int(round(_val_f("defense", 0.0))))
		_card.set("move_speed", _val_f("move_speed", 4.0))
	else:
		var dtype2 := _val("defense_type")
		if dtype2 != null:
			_card.set("defense_type", StringName(String(dtype2)))
		_card.set("max_hp", _val_f("max_hp", 100.0))
		_card.set("defense", int(round(_val_f("defense", 0.0))))
		_card.set("footprint", Vector2i(
			maxi(1, int(round(_val_f("footprint_x", 1.0)))),
			maxi(1, int(round(_val_f("footprint_y", 1.0))))))
		_card.set("food_provided", int(round(_val_f("food_provided", 0.0))))
		_card.set("attack", int(round(_val_f("attack", 0.0))))
		_card.set("range", _val_f("range", 0.0))
		_card.set("attack_cooldown", _val_f("attack_cooldown", 1.5))
		_card.set("sight_range", _val_f("sight_range", 10.0))
		_card.set("trains", _checked_ids(_checks_train))
		_card.set("researches", _checked_ids(_checks_research))

	var err: int = ResourceSaver.save(_card, path)
	if err != OK:
		_status.text = "保存失败（错误码 %d）：%s" % [err, path]
		return

	# 单位卡：勾选"由哪些建筑训练" → 反向同步所有建筑卡的 trains
	var bad: int = 0
	if _kind == "unit":
		bad = _sync_unit_trains()

	# 静态缓存不清 = 改了也白改（下次进图还是旧数值）
	UNIT_TABLE.reload_cards()
	MapAssets.clear_cache()
	if session != null and session.dock != null and session.dock.has_method("refresh_after_card_edit"):
		session.dock.call("refresh_after_card_edit")

	_dirty = false
	var tail: String = "" if bad == 0 else "（有 %d 张建筑卡写回失败）" % bad
	_status.text = "已保存 %s%s" % [path.get_file(), tail]
	_update_head()
	if session != null and session.has_method("push_status"):
		session.call("push_status", "卡「%s」已保存，重开测试地图生效%s" % [
			String(_card.get("display_name")), tail])


## **新建一张卡**（玩家 2026-11-08 第 13 条）。
##
## 口径：
##   · 文件名 = id，id 自动起 `new_unit_1` / `new_building_1`，**名字和所有字段都由人填**；
##   · 只填"能让它立刻存在"的最小集合：id / 名字 / 分类 / 0 花费 / 一句说明；
##   · 模型留空 —— 美术到位之后在表单里填 `model_path`，保存即进对象页；
##   · 保存后重扫目录 + 选中新卡，并让对象页刷新（和保存走同一条链路）。
func _create_card() -> void:
	var dir_path: String = _dir()
	var prefix: String = "new_unit_" if _kind == "unit" else "new_building_"
	var n: int = 1
	while FileAccess.file_exists(dir_path + prefix + str(n) + ".tres"):
		n += 1
	var id: String = prefix + str(n)
	var res: Resource = null
	if _kind == "unit":
		res = preload("res://代码/配置/单位卡.gd").new()
		res.set("card_id", id)
		res.set("display_name", "新单位 " + str(n))
		res.set("description", "（自己写：这个兵是谁、干什么用的）")
		res.set("max_hp", 200.0)
		res.set("attack", 10)
		res.set("range", 90.0)
		res.set("attack_cooldown", 1.5)
		res.set("move_speed", 4.2)
		res.set("cost_gold", 100)
		res.set("volume", 1.0)
		res.set("race", &"联盟")
	else:
		res = preload("res://代码/配置/建筑卡.gd").new()
		res.set("card_id", id)
		res.set("display_name", "新建筑 " + str(n))
		res.set("description", "（自己写：这座楼干什么用的）")
		res.set("max_hp", 800.0)
		res.set("cost_gold", 150)
		res.set("cost_wood", 50)
		res.set("footprint", Vector2i(3, 3))
		res.set("height", 4.0)
		res.set("race", &"联盟")
	var path: String = dir_path + id + ".tres"
	var err: int = ResourceSaver.save(res, path)
	if err != OK:
		_status.text = "新建失败（错误码 %d）：%s" % [err, path]
		return
	# 重扫 + 让新卡成为当前选中的那张
	_cards = []
	for e in _load_dir(dir_path):
		_cards.append({
			"path": String(e["path"]), "card": e["card"],
			"name": String((e["card"] as Resource).get("display_name")),
			"id": String((e["card"] as Resource).get("card_id")),
		})
	_card = res
	_dirty = false
	_sync_list()
	_rebuild_form()
	UNIT_TABLE.reload_cards()
	MapAssets.clear_cache()
	if session != null and session.dock != null and session.dock.has_method("refresh_after_card_edit"):
		session.dock.call("refresh_after_card_edit")
	_status.text = "已新建 %s —— 填名字 / 数值 / 模型路径后点「保存」，对象页就能摆它了" % path.get_file()


## 把"这个单位由哪些建筑训练"同步到建筑卡的 trains 数组。
## 返回写盘失败的建筑卡数量。
func _sync_unit_trains() -> int:
	var uid: String = String(_card.get("card_id"))
	var want: Dictionary = {}
	for e in _checks_build_for_unit:
		want[String(e["id"])] = bool((e["box"] as CheckBox).button_pressed)
	var bad: int = 0
	for e in _load_dir(CARD_DIR_BUILDING):
		var b: Resource = e["card"]
		if b == null:
			continue
		var bid: String = String(b.get("card_id"))
		var cur: Array = []
		var raw: Variant = b.get("trains")
		if raw is Array:
			for x in raw:
				cur.append(String(x))
		var next: Array = []
		for s in cur:
			if s != uid:
				next.append(s)
		if bool(want.get(bid, false)) and not next.has(uid):
			next.append(uid)
		# 只比集合：勾了又取消不该把数组顺序洗一遍（diff 无意义）
		if _same_set(cur, next):
			continue
		var typed: Array[StringName] = []
		for s in next:
			typed.append(StringName(s))
		b.set("trains", typed)
		if ResourceSaver.save(b, String(e["path"])) != OK:
			bad += 1
	return bad


func _test() -> void:
	if _dirty:
		# 明确要求：有未保存改动先提醒，**不自动保存**
		_alert_popup("请先保存", "表单里有未保存的改动。\n\n先点「保存」，再点「测试地图」。")
		return
	if session != null and session.has_method("test_map"):
		session.call("test_map")


func _alert_popup(title_text: String, body: String) -> void:
	if _alert == null:
		_alert = AcceptDialog.new()
		_alert.ok_button_text = "知道了"
		_alert.exclusive = false
		add_child(_alert)
	_alert.title = title_text
	_alert.dialog_text = body
	_alert.popup_centered(Vector2i(380, 150))


# --- 小工具 ---

func _s(key: String, def: String = "") -> String:
	var v: Variant = _card.get(key)
	if v == null:
		return def
	var s: String = String(v)
	return s if not s.is_empty() else def


func _f(key: String, def: float = 0.0) -> float:
	var v: Variant = _card.get(key)
	if v == null:
		return def
	return float(v)


func _array_has_str(arr: Variant, want: String) -> bool:
	if not (arr is Array):
		return false
	for x in arr:
		if String(x) == want:
			return true
	return false


func _checked_ids(checks: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for e in checks:
		if bool((e["box"] as CheckBox).button_pressed):
			out.append(StringName(String(e["id"])))
	return out


func _same_set(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for x in a:
		if not b.has(x):
			return false
	return true
