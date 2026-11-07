@tool
extends Window
## **营地弹窗**：在视口里点一座「野怪营地锚点建筑」→ 就地弹出这份配置。
##
## 为什么要有它（玩家原话「我不知道去哪儿点」）：
##   营地配置本来只住在右侧停靠面板的「营地」页：玩家得先在视口选中锚点，
##   再切到那一页、选一份配置、点「应用到选中锚点」—— 三步，而且没有任何指路。
##   这里把同一条链路收成"点建筑 → 弹窗 → 改 → 保存"，配置入口就在建筑身上。
##
## 数据口径（和停靠面板完全一致，两边编辑同一份 .tres）：
##   · 锚点有 camp_id      → 用 by_id 那一份（逐实例配置）；
##   · 没有 camp_id 但有默认 → 用 for_den(锚点类型) 那一份；
##   · 两份都没有          → 按模板新建 代码/配置/卡/野怪营地/camp_<锚点id>_<n>.tres。
##   保存后把 camp_id 写进**这一座**锚点的 properties，并让静态表 reload ——
##   同一种锚点摆多座时，各座才可能配各自的怪（运行时 野怪营地.gd 已经读 camp_id）。
##
## ⚠ 本文件不写 class_name（AGENTS.md §二：别碰全局类缓存），
##   调用方用 preload 常量 + .call() 拿它。

const Spec := preload("res://代码/界面/界面规格.gd")
const EDITOR_THEME := preload("res://addons/map_editor/编辑器主题.tres")
const CAMP_TABLE := preload("res://代码/配置/野怪营地表.gd")
const CAMP_DEF := preload("res://代码/配置/野怪营地定义.gd")

var session = null
## 正在配置的那一座锚点（MapObject）
var _obj: MapObject = null
## 正在编辑的营地 Resource（已有卡就是磁盘上那份；没有就是还没落盘的草稿）
var _camp: Resource = null

var _built: bool = false
var _syncing: bool = false

# --- 表单控件 ---
var _name: LineEdit
var _id: LineEdit
var _owner: OptionButton
var _first: SpinBox
var _interval: SpinBox
var _respawn: SpinBox
var _radius: SpinBox
var _icon: LineEdit
var _creep_list: ItemList
var _count_box: VBoxContainer
var _hint: Label
var _status: Label

## 界面上的"真相"：勾了哪些野怪、各几只（保存时才写回 Resource）
var _creeps: Array = []
var _counts: Array = []


# ===========================================================================
# 构建
# ===========================================================================

## 幂等装配：主屏只调一次；重复调用什么也不做
func setup(p_session) -> void:
	session = p_session
	if _built:
		return
	_built = true
	title = "野怪营地配置"
	# 非阻塞：编辑器里改配置时还能继续看视口（exclusive = false 才不挡主窗口）
	exclusive = false
	transient = true
	min_size = Vector2i(520, 460)
	close_requested.connect(func() -> void: hide())
	_build()


func _build() -> void:
	theme = EDITOR_THEME
	var panel := PanelContainer.new()
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	v.add_child(Spec.editor_label("野怪营地", &"EditorTitle"))
	_hint = Spec.editor_label("", &"EditorHint")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(500, 0)
	v.add_child(_hint)

	# 表单放进滚动容器：小屏幕（1024×768）也不会把「保存」按钮顶到窗口外面。
	# 按钮留在滚动区外 —— 滚到一半找不到保存是更糟的体验。
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 6)
	body.add_child(g)

	g.add_child(_label("显示名"))
	_name = LineEdit.new()
	_name.placeholder_text = "豺狼人营地"
	g.add_child(_name)

	g.add_child(_label("营地 id"))
	_id = LineEdit.new()
	_id.placeholder_text = "camp_creep_den_1"
	_id.tooltip_text = "新营地用它拼文件名（代码/配置/卡/野怪营地/<id>.tres）。\n已存在的营地按原本的路径写回，id 只作标识。"
	g.add_child(_id)

	g.add_child(_label("所属玩家"))
	_owner = OptionButton.new()
	_owner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_owner.tooltip_text = "野怪 = 中立敌对；改成玩家 N 就是替那一家守营地（AI 会当自己人）。\n进图后以锚点建筑的归属为准，这里保存时会一起改掉锚点归属。"
	g.add_child(_owner)

	g.add_child(_label("首刷（分钟）"))
	_first = _spin(0.0, 120.0, 0.5)
	_first.tooltip_text = "开局后第几分钟第一次刷。0 = 开局立刻刷。"
	g.add_child(_first)

	g.add_child(_label("间隔（分钟）"))
	_interval = _spin(0.0, 60.0, 0.5)
	_interval.tooltip_text = "每隔几分钟再刷一整波。0 = 只刷一次（之后只靠补满秒）。"
	g.add_child(_interval)

	g.add_child(_label("补满（秒）"))
	_respawn = _spin(0.0, 600.0, 5.0)
	_respawn.tooltip_text = "全灭后多久补满。0 = 永不补（打完就没了）。"
	g.add_child(_respawn)

	g.add_child(_label("半径（米）"))
	_radius = _spin(1.0, 40.0, 0.5)
	_radius.tooltip_text = "野怪在锚点建筑周围这个半径内出生。"
	g.add_child(_radius)

	g.add_child(_label("小地图图标"))
	_icon = LineEdit.new()
	_icon.placeholder_text = "camp"
	g.add_child(_icon)

	body.add_child(HSeparator.new())
	body.add_child(Spec.editor_label("刷什么怪（点一下勾上，右侧填只数）", &"EditorCaption"))

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 8)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(split)

	_creep_list = ItemList.new()
	_creep_list.select_mode = ItemList.SELECT_MULTI
	_creep_list.custom_minimum_size = Vector2(200, 190)
	_creep_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_creep_list.multi_selected.connect(_on_creep_multi)
	# ItemList(多选) 默认单击 = "只留这一个"（多选要按 Ctrl）。
	# 玩家勾野怪的心智是"点一下勾上、再点取消"，所以自己接一手点击：
	# gui_input 比 C++ 的默认处理先跑，accept_event() 之后默认行为不再执行。
	_creep_list.gui_input.connect(_on_creep_input)
	split.add_child(_creep_list)
	for a in MapAssets.of_category(MapObject.Category.UNIT):
		_creep_list.add_item(MapAssets.list_label(a))
		_creep_list.set_item_metadata(_creep_list.item_count - 1, String(a["id"]))
		_creep_list.set_item_tooltip(_creep_list.item_count - 1, MapAssets.list_label(a))

	_count_box = VBoxContainer.new()
	_count_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_count_box)

	_status = Spec.editor_label("", &"EditorHint")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(500, 0)
	# 状态放在滚动区外：保存结果必须一眼能看见，不能留在滚走的表单底部
	v.add_child(_status)

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 8)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brow.add_child(spacer)
	var cancel := Spec.editor_button("取消")
	cancel.pressed.connect(func() -> void: hide())
	brow.add_child(cancel)
	var save := Spec.editor_button("保存并应用")
	save.pressed.connect(_save)
	brow.add_child(save)
	v.add_child(brow)


func _label(t: String) -> Label:
	return Spec.editor_label(t)


func _spin(min_v: float, max_v: float, step: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sb


# ===========================================================================
# 打开 / 回填
# ===========================================================================

## 视口点中锚点时调用。o 必须是建筑（视口已经判过营地锚点）
func open_for(p_session, o: MapObject) -> void:
	setup(p_session)
	if o == null:
		return
	_obj = o
	_camp = _resolve_card(o)
	_fill_form()
	_popup_fit()


## 弹窗尺寸在"打开时"才算：窗口没进树之前设的 size 会被引擎丢掉（只会剩 min_size），
## 结果就是内容比窗口大、底部按钮被裁掉。这里按内容最小尺寸 + 当前视图大小现算一次。
func _popup_fit() -> void:
	var need: Vector2i = Vector2i(get_contents_minimum_size())
	var avail := Vector2(1600.0, 900.0)
	if get_parent() != null:
		avail = get_parent().get_viewport_rect().size
	var w: int = maxi(need.x + 24, 560)
	var h: int = maxi(need.y + 24, 620)
	if avail.y > 300.0:
		h = mini(h, int(avail.y * 0.82))
	# ⚠ 顺序很重要：popup_centered() 内部会把 size 压回 min_size（实测 headless 与编辑器一致），
	#   所以必须先弹、再改大小，最后按新的 size 居中一次。
	popup_centered()
	size = Vector2i(w, h)
	if get_parent() != null:
		var pr: Rect2 = get_parent().get_viewport_rect()
		position = Vector2i(pr.position + (pr.size - Vector2(size)) * 0.5)


## 停靠面板保存了同一份 .tres 之后调这里，把窗体上的值刷成磁盘上的新值。
## 为什么需要：两边编辑同一份数据，如果弹窗还开着、显示的是旧值，
## 玩家再点一次「保存」就会拿旧表单把面板刚改的内容盖回去。
func reload_if(path: String) -> void:
	if _camp == null or not visible:
		return
	if String(_camp.resource_path) != path:
		return
	# 优先换成缓存里那份（ResourceLoader 可能给了新实例；换掉才不会显示旧值）
	var fresh: Resource = CAMP_TABLE.by_id(String(_camp.get("id")))
	if fresh != null:
		_camp = fresh
	_fill_form()


## 这座锚点该用哪份营地卡：
##   ① 锚点上已有 camp_id → 用那一份（逐实例配置，玩家上次保存的结果）；
##   ② 该类型有默认卡、且这张图里还没有别的锚点占用它 → 复用默认卡；
##   ③ 否则按模板新建一份草稿。
##
## 为什么②要看"有没有别人占用"（玩家要求"同种锚点各自不同配置"）：
##   同一种巢穴摆两座时，如果两座都无脑复用默认卡，改 A 就等于改 B，
##   camp_id 形同虚设。这里把"第一座用默认、后面的各自开新卡"做成确定行为，
##   玩家第二次点同类锚点就会看到"新建配置"，不会莫名其妙改到别座。
func _resolve_card(o: MapObject) -> Resource:
	var cid: String = String(o.properties.get("camp_id", ""))
	if not cid.is_empty():
		var by_id: Resource = CAMP_TABLE.by_id(cid)
		if by_id != null:
			return by_id
	var def_card: Resource = CAMP_TABLE.for_den(o.type_id)
	if def_card != null and not _claimed_by_other(o, String(def_card.get("id"))):
		return def_card
	# 没有可复用的卡 → 按模板造一份草稿（保存时才落盘）
	var res: Resource = CAMP_DEF.new()
	res.set("id", StringName(_unique_id(String(o.type_id))))
	res.set("den_building", o.type_id)
	res.set("display_name", "%s（自定义）" % MapAssets.display_name(o.type_id))
	return res


## 这张图里是否已经有**别的**锚点用 camp_id 指到这份营地卡
func _claimed_by_other(o: MapObject, camp_id: String) -> bool:
	if camp_id.is_empty() or session == null or session.def == null:
		return false
	for other in session.def.objects:
		if other == null or other == o:
			continue
		if int(other.category) != MapObject.Category.BUILDING:
			continue
		if String(other.properties.get("camp_id", "")) == camp_id:
			return true
	return false


## 新营地的 id：camp_<锚点id>_<n>，n 从 1 起找第一个没被占用的文件名
func _unique_id(den: String) -> String:
	var base: String = "camp_%s_" % den.validate_filename()
	var n: int = 1
	while FileAccess.file_exists(CAMP_TABLE.CARD_DIR + base + str(n) + ".tres"):
		n += 1
	return base + str(n)


func _fill_form() -> void:
	if _camp == null:
		return
	_syncing = true
	_rebuild_owner_options()
	_name.text = _safe_str("display_name", "野怪营地")
	_id.text = _safe_str("id", "camp_creep_den_1")
	_first.value = _safe_float("first_spawn_min", 0.0)
	_interval.value = _safe_float("spawn_interval_min", 0.0)
	_respawn.value = _safe_float("respawn", 90.0)
	_radius.value = _safe_float("radius", 6.0)
	_icon.text = _safe_str("minimap_icon", "camp")
	_select_owner(int(_safe_float("owner_slot", -2.0)))
	# 归属兜底：卡片上是"建议归属"，玩家点的是哪座就以那座现状为准，
	# 否则弹窗一开就把锚点归属改了（那是保存才该发生的事）。
	if _obj != null:
		_select_owner(_obj.owner)
	_creeps.clear()
	_counts.clear()
	var raw: Variant = _camp.get("creeps")
	if raw is Array:
		for c in raw:
			_creeps.append(StringName(String(c)))
	var counts: Variant = _camp.get("counts")
	var cl: Array = counts if counts is Array else []
	for i in range(_creeps.size()):
		_counts.append(int(cl[i]) if i < cl.size() else 1)
	_sync_creep_list()
	_rebuild_counts()
	_syncing = false
	var path: String = String(_camp.resource_path)
	if path.is_empty():
		_status.text = "新建配置：点「保存并应用」才会写盘，并落到这一座锚点上"
	else:
		var used: String = String(_obj.properties.get("camp_id", "")) if _obj != null else ""
		_status.text = "正在编辑 %s%s" % [path.get_file(),
			"" if used.is_empty() else "（这座锚点已指定 camp_id=%s）" % used]
	_hint.text = "点中的是 %s（%s）。保存后这座锚点改用这份配置；同种锚点的其它实例下次点开时会自动新建自己的一份。" % [
		MapAssets.display_name(_obj.type_id) if _obj != null else "锚点",
		String(_obj.type_id) if _obj != null else "?"]


## 归属下拉：中立敌对 / 中立 / 地图上的每个玩家槽位
func _rebuild_owner_options() -> void:
	_owner.clear()
	_owner.add_item("中立敌对（野怪）")
	_owner.set_item_metadata(0, -2)
	_owner.add_item("中立（和平）")
	_owner.set_item_metadata(1, -1)
	var n: int = 0
	if session != null and session.def != null:
		n = session.def.players.size()
	if n <= 0:
		n = 12
	for i in range(mini(n, 12)):
		_owner.add_item("玩家 %d" % (i + 1))
		_owner.set_item_metadata(_owner.item_count - 1, i)


func _select_owner(slot: int) -> void:
	for i in range(_owner.item_count):
		if int(_owner.get_item_metadata(i)) == slot:
			_owner.select(i)
			return
	_owner.select(0)


func _owner_id() -> int:
	if _owner == null or _owner.selected < 0:
		return -2
	return int(_owner.get_item_metadata(_owner.selected))


func _sync_creep_list() -> void:
	if _creep_list == null:
		return
	for i in range(_creep_list.item_count):
		var uid := StringName(String(_creep_list.get_item_metadata(i)))
		if _creeps.has(uid):
			_creep_list.select(i, false)
		else:
			_creep_list.deselect(i)


func _rebuild_counts() -> void:
	if _count_box == null:
		return
	for c in _count_box.get_children():
		_count_box.remove_child(c)
		c.free()
	if _creeps.is_empty():
		_count_box.add_child(Spec.editor_label("勾左边的野怪 → 这里出现只数", &"EditorHint"))
		return
	for i in range(_creeps.size()):
		var row := HBoxContainer.new()
		var nm: Label = Spec.editor_label(MapAssets.display_name(_creeps[i]))
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.clip_text = true
		nm.tooltip_text = MapAssets.display_name(_creeps[i])
		row.add_child(nm)
		var sb := _spin(1, 12, 1)
		sb.custom_minimum_size = Vector2(66, 0)
		sb.size_flags_horizontal = Control.SIZE_SHRINK_END
		sb.value = clampi(int(_counts[i]) if i < _counts.size() else 1, 1, 12)
		# 循环变量落成局部量：lambda 按值捕获，不落的话回调里拿到的是循环结束后的同一个 i
		var idx: int = i
		sb.value_changed.connect(func(v: float) -> void:
			if idx < _counts.size():
				_counts[idx] = int(v))
		row.add_child(sb)
		_count_box.add_child(row)


func _on_creep_input(event: InputEvent) -> void:
	if _syncing or _creep_list == null:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var idx: int = _creep_list.get_item_at_position(mb.position, true)
	if idx < 0:
		return
	_creep_list.accept_event()
	var on: bool = not _creep_list.is_selected(idx)
	_syncing = true
	if on:
		_creep_list.select(idx, false)
	else:
		_creep_list.deselect(idx)
	_syncing = false
	_toggle_creep(idx, on)


func _on_creep_multi(index: int, selected: bool) -> void:
	if _syncing:
		return
	_toggle_creep(index, selected)


func _toggle_creep(index: int, selected: bool) -> void:
	if _creep_list == null or index < 0 or index >= _creep_list.item_count:
		return
	var uid := StringName(String(_creep_list.get_item_metadata(index)))
	if selected:
		if not _creeps.has(uid):
			_creeps.append(uid)
			_counts.append(1)
	else:
		var at: int = _creeps.find(uid)
		if at >= 0:
			_creeps.remove_at(at)
			if at < _counts.size():
				_counts.remove_at(at)
	_rebuild_counts()


# ===========================================================================
# 保存
# ===========================================================================

func _save() -> void:
	if _camp == null or _obj == null:
		_status.text = "没有可保存的锚点（先在视口里点一座营地建筑）"
		return
	var nm: String = _name.text.strip_edges()
	if nm.is_empty():
		_status.text = "显示名不能为空"
		return
	var cid: String = _id.text.strip_edges().validate_filename()
	if cid.is_empty():
		_status.text = "营地 id 不能为空（只允许文件名用的字符）"
		return
	if _creeps.is_empty():
		_status.text = "至少要勾一种野怪（不然这座营地什么也不刷）"
		return
	# 草稿才按 id 拼路径；已有卡一律写回它原本的文件（id 和文件名允许不一致）
	var path: String = String(_camp.resource_path)
	if path.is_empty():
		path = CAMP_TABLE.CARD_DIR + cid + ".tres"
		if FileAccess.file_exists(path):
			_status.text = "已有 id 为「%s」的营地卡，换一个营地 id 再存" % cid
			return

	var creeps: Array[StringName] = []
	var counts: Array[int] = []
	for i in range(_creeps.size()):
		creeps.append(StringName(String(_creeps[i])))
		counts.append(int(_counts[i]) if i < _counts.size() else 1)
	_camp.set("id", StringName(cid))
	_camp.set("display_name", nm)
	_camp.set("den_building", _obj.type_id)
	_camp.set("creeps", creeps)
	_camp.set("counts", counts)
	_camp.set("radius", _radius.value)
	_camp.set("respawn", _respawn.value)
	_camp.set("minimap_icon", _icon.text.strip_edges())
	_camp.set("owner_slot", _owner_id())
	_camp.set("first_spawn_min", _first.value)
	_camp.set("spawn_interval_min", _interval.value)

	var err: int = ResourceSaver.save(_camp, path)
	if err != OK:
		_status.text = "保存失败（错误码 %d）：%s" % [err, path]
		return
	# 草稿第一次落盘后必须认领这个路径：否则第二次点保存会走"新建"分支，
	# 撞上"已有同名营地卡"的提示，等于刚存的这份再也改不了。
	if String(_camp.resource_path) != path:
		_camp.take_over_path(path)
	# 必须清缓存：营地表是静态缓存，不然刚存的配置要重启 Godot 才看得到
	CAMP_TABLE.reload()

	# 逐实例配置：只改被点的这一座，并把归属一起落下去
	if session != null and session.has_method("apply_camp_to_object"):
		session.call("apply_camp_to_object", _obj, cid, _owner_id())
	# 停靠面板的「营地」页编辑的是同一份数据，保存完让它重扫
	if session != null and session.dock != null and session.dock.has_method("refresh_camp_page"):
		session.dock.call("refresh_camp_page")
	_status.text = "已保存 %s（野怪：%s）" % [path.get_file(), "、".join(_creep_summary())]
	if session != null and session.has_method("push_status"):
		session.call("push_status", "营地「%s」已保存，重开测试地图生效" % nm)


func _creep_summary() -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(_creeps.size()):
		out.append("%s×%d" % [MapAssets.display_name(_creeps[i]),
			int(_counts[i]) if i < _counts.size() else 1])
	return out


# ===========================================================================
# 安全取值（卡片可能被手改坏 / 缺字段，不能因为空值就崩）
# ===========================================================================

func _safe_float(key: String, def: float) -> float:
	var v: Variant = _camp.get(key)
	if v == null:
		return def
	return float(v)


func _safe_str(key: String, def: String) -> String:
	var v: Variant = _camp.get(key)
	if v == null:
		return def
	var s: String = String(v)
	return s if not s.is_empty() else def
